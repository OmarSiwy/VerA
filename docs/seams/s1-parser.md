# s1-parser: the parser unit (U40)

Step-1 notes for `lib/frontend/parser.zig` and `lib/frontend/parser/*.zig`,
written 2026-10-03 against base `1d3618f8`.

## Spine and ownership after step 1

`Parser.parseSourceFile` (source.zig) is the spine. It dispatches each A.1.2
description to the file that owns its grammar; `parseModule` (module.zig)
dispatches each A.1.4 item the same way into the scope's `Body`.

| File | Owns (writes) | Grammar |
|---|---|---|
| parser.zig | cursor, `attrs`, `file.attributes`, `kw_set`, diagnostics funnel | tokens, §2.9 attributes |
| source.zig | `file.modules`/`natures`/... lists at end of parse; `kw_stack` | A.1.2, A.1.1, A.1.5 |
| module.zig | `Body` (one per scope), `ModuleDecl` | A.1.2 module, A.1.3 ports, A.1.4 items |
| discipline.zig | `NatureDecl`, `DisciplineDecl`; grows `access_names` | A.1.6, A.1.7 |
| paramset.zig / connectrules.zig | `ParamsetDecl` / `ConnectRulesDecl` | A.1.9 / A.1.8 |
| udp.zig | `UdpDecl`, UDP rows of `Body.instances` | A.5 |
| decl.zig | `ParamDecl`, `AliasParam`, `VarDecl`, `EventDecl`, `Dim` | A.2.1.1, A.2.1.3, A.2.5 |
| net.zig | `Body.ports` completion, `Body.nets`, `Body.branches`, variable ports | A.2.1.2, A.2.1.3, A.2.2 |
| hier.zig | interned hierarchical names | §6.7, A.9.3 |
| function.zig | `Body.functions`, `Body.tasks` | A.2.6, A.2.7 |
| inst.zig | `Body.instances`, `.gates`, `.pulls`, `.switches`, `.discrete` | A.4.1, A.3, A.6.2 |
| generate.zig | scratch `Body` per generate block, `gen_*` counters | A.4.2 |
| specify.zig | `Body.paths`, `Body.timing_checks` | A.7 |
| stmt.zig / expr.zig / concat.zig / literal.zig | `file.stmts` / `file.exprs` | A.6 / A.8.2-A.8.4 / A.8.1 / §2.6-§2.7 |

Every file appends to `file` (the `Ast.SourceFile` stores); `ast.zig` owns
their layout, so the parser is a writer, not the owner.

## Seam proposals

1. **The prefix-parse rest state is asserted from outside.**
   `lib/frontend/pp/prelude.zig:168-174` asserts on a dozen `Parser` fields
   (`kw_stack`, `attrs`, `attr_depth`, `in_analog_fn`, `in_connect_module`,
   `in_discrete`, `in_digital_delay`, `gen_depth`, `gen_construct_depth`, ...)
   to prove a prefix parse left nothing dirty, and `Parser.Seed` lists the
   fields it may leave dirty. A new field has to be remembered in both files.
   Better: `pub fn atRest(self: *const Parser) bool` in parser.zig, which
   prelude.zig asserts. Callers: `pp/prelude.zig` only. Once that lands the
   seven mode bools stop being API and the parser can pack them into one
   save/restore `Context` value (the save/restore pattern repeats at about
   ten sites: `in_analog_fn`, `in_discrete`, `in_digital_delay`,
   `in_connect_module`, `gen_loop_body`).
2. **Mode set by poking fields after `init`.** `src/sim/digital/root.zig:3009-3011`
   sets `parser.digital = true` and calls `setLanguage`; `lib/root.zig:280-281`
   calls `setLanguage`; `parser/test.zig` sets `digital`. Better: an options
   argument, `init(arena, src, tags, starts, bag, .{ .digital = true, .language = l })`
   (and the same on `initSeeded`), so a parse's language and grammar are fixed
   before the first token. Callers: the three above plus the five test
   helpers (`ir/lower/test.zig`, `ir/proof/test.zig`, `backend/codegen/test.zig`,
   `ir/elaborate.zig:1501,1560`, `pp/test.zig`), all of which take the defaults.
3. **`tokenText` re-lexes.** Tokens store `{tag, start}`, so every
   `tokenText`, `internTok`, `reservedIs` and `found` re-scans the lexeme
   (documented in parser.zig). The parser calls it for every identifier and
   every annex B `.kw_reserved` dispatch. A token end column (or length) in
   the lexer's output would make it O(1). Owner: the lexer/token unit. Step 3
   to measure.
4. **Stale path in a doc I do not own.** `docs/IMPLEMENTATION.md` lines 51 and
   265 cite `lib/frontend/parser/source.zig` for `max_udp_inputs` (E1017). The
   constant now lives in `lib/frontend/parser/udp.zig`.
5. **Comments that name parser functions as `Parser.x`.** `ast.zig:585`
   (`parseWrealDecl`, now net.zig), `ast.zig:1132` (`parseDiscipline`, now
   discipline.zig), `ast.zig:1173` (`parseConnectRules`, now connectrules.zig),
   `ir/lower/param.zig:422` (`parseAttributes`, parser.zig), `token.zig:192`
   (`switch_arms`, inst.zig). The names are unchanged, so grep still finds
   them; the `Parser.` prefix was never a literal path.

## Performance observations (not changed in step 1)

- `Parser.copyAttributes` scans every attribute binding of the file per call
  and again per match, and `parseModuleItem` calls it for each row it added
  to each of 17 `Body` lists; `statementAttributes` scans all bindings per
  statement. Both are linear-to-quadratic in the file's attribute count,
  harmless for attribute-light compact models and quadratic for an
  attribute-heavy one. A per-owner-token index would make both O(1).
- `parseModuleItem` copies the whole `Body` (23 list headers) per item to
  diff list lengths afterwards.

## Bugs found

1. **A task closes on `endfunction`.** `lib/frontend/parser/function.zig`
   `parseSubroutine` (the body loop and the close test, lines 269-274)
   accept `.kw_endfunction` whatever `is_function` is. Trigger
   (`vera --run`):

   ```verilog
   module m;
     reg r;
     task t; begin r = 1; end endfunction
     initial begin t; $display("ok r=%0d", r); end
   endmodule
   ```

   Expected E0207 "no `endtask` closes the declaration"; actual: prints
   `ok r=1`, exit 0.
2. **An empty named port is refused.** `lib/frontend/parser/module.zig`
   `parsePortList` reads `.name(` and then requires an identifier. IEEE
   1364-2005 A.1.3 writes `port ::= [ port_expression ] | . port_identifier
   ( [ port_expression ] )`, so `.a()` is a legal port that connects nothing.
   Trigger: `module m(.a(), .b(x)); input x; initial $display("ok"); endmodule`
   with `vera --run`. Expected: `ok`; actual: E0208 "expected an identifier:
   found `)`" at the `)`.
