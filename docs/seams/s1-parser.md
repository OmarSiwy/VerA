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
   the lexer's output would make it O(1). Owner: the lexer/token unit.
   Measured 2026-10-03 (debug counters, callgrind on a ReleaseFast
   `-Dcpu=x86_64_v2` vera): psp103 makes 37,125 `tokenText` calls against
   107,512 tokens, hisimhv_va 49,937 against 131,468. All of `Lexer.next`
   is 19.6 M of the 923 M instructions of `--lint psp103`, so the re-scans
   are at most a few M (well under 1 %). The cost of the fix is 4 B per
   token (430 KB on psp103) unless the length fits a `u8`/`u16` column with
   an escape for long tokens. Expected saving: small; do it only together
   with a lexer change that needs the end column anyway.
6. **`access_names` is a string-keyed hash map.** `Parser.access_names`
   (`StringHashMapUnmanaged(void)`, 16 entries on every model) is hashed by
   string on every `name(` in an expression. The names are interned, so a
   `StrId` set (a 16-entry `u32` array scanned linearly) would answer it
   without hashing. Frozen: `pp/prelude.zig:177` iterates its keys to build
   `Seed.access_names`. Proposal: an `accessNames()` accessor the prelude
   calls, after which the field can change shape. Expected saving: one
   string hash per call site (1,453 call lists on psp103), negligible.
7. **The seven mode flags.** `Parser` carries `failed`, `in_analog_fn`,
   `digital`, `in_discrete`, `in_digital_delay`, `in_connect_module` and
   `gen_loop_body` as separate `bool`s. One parser exists per parse, so
   packing them saves nothing measurable; it is listed only because seam 1's
   `atRest()` is what would let them become one save/restore value.
8. **AST lists the parser builds with slack it cannot reclaim.** Every
   `ModuleDecl` slice is the `Body` list's `.items`, grown by doubling in the
   compile arena; below `BigArena.large` (64 KiB) each growth leaves the old
   buffer behind. On psp103 the `ParamDecl` lists (64 B rows) requested
   230 KB for about 58 KB of rows, `VarDecl` 147 KB. Exact-size slices need
   either a reusable parser-side buffer the AST copies from (one more copy of
   the final rows) or a non-arena allocator for the growing phase; both
   change who owns the slices `ast.zig` hands downstream. Expected saving:
   about 300 KB of dead arena bytes on psp103.
4. **Stale path in a doc I do not own.** `docs/Vague_Decisions.md` lines 51 and
   265 cite `lib/frontend/parser/source.zig` for `max_udp_inputs` (E1017). The
   constant now lives in `lib/frontend/parser/udp.zig`.
5. **Comments that name parser functions as `Parser.x`.** `ast.zig:585`
   (`parseWrealDecl`, now net.zig), `ast.zig:1132` (`parseDiscipline`, now
   discipline.zig), `ast.zig:1173` (`parseConnectRules`, now connectrules.zig),
   `ir/lower/param.zig:422` (`parseAttributes`, parser.zig), `token.zig:192`
   (`switch_arms`, inst.zig). The names are unchanged, so grep still finds
   them; the `Parser.` prefix was never a literal path.

## Memory

Data-oriented audit of everything the parser owns, 2026-10-03, base
`0f3602b1`. Sizes are `@sizeOf` on x86_64; counts come from throwaway debug
counters on psp103 (`--lint`), removed before commit. `std.ArrayList` is
32 B here.

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `Parser` | 648 → 744 B | 1 per parse (+1 for the prelude) | −96 B | Gained `attr_at` and two scratch stacks (3 lists). One instance; its bools and `u32` depths are frozen API (`pp/prelude.zig` asserts them, `sim/digital` sets `digital`), see seams 1 and 7. |
| `Body` copy in `parseModuleItem` | 744 B copied per item → 17 × 8 B lengths | 1,407 items | 1.05 MB of `memcpy` per parse | The item now records the 17 list lengths it diffs, not the whole `Body`. |
| `Body` | 744 B, unchanged | 1 per module or generate block | 0 | One per scope, never in a hot loop. Its list slack is AST-owned; see seam 8. |
| `file.attributes` scans (`copyAttributes`, `statementAttributes`) | O(bindings) per call → O(log n + rows since the cursor reached the owner) | 2,148 bindings; 5,050 + 8,235 calls | 24.3 M → 3.2 k row visits | New `attr_at: ArrayList(u32)`, the cursor at each append, kept sorted and parallel to `file.attributes` by its one writer `appendBinding`. `bindingsFrom` binary-searches it. |
| `attr_at` row | new, 4 B | 2,148 | −8.6 KB (−16 KB with growth) | The price of the index above. |
| call-argument lists (`parseCallArgs`) | arena `ArrayList(ExprId)` per call, copied into the pool → `scratch_exprs` | 1,453 lists | 192 KB of dead arena (capacity) | Arguments go from one parse-long stack straight into the expression pool. Only `$task(...)` statements, which keep the slice, dupe it exactly. |
| block bodies (`parseSeqBlock`) | arena `ArrayList(StmtId)` stored with slack → `scratch_stmts` + exact dupe | 1,806 blocks | about 220 KB of slack (247 KB capacity for 26 KB of rows) | Exact-size slice from the scratch stack. |
| case labels (`parseCase`) | arena `ArrayList(ExprId)` per arm → `scratch_exprs` + exact dupe | per arm | small on these models | Same pattern as block bodies. |
| `AttrMark` | 24 → 12 B | stack only | 12 B per speculative read | `usize` lengths narrowed to `u32` (bounded by the token count). Pinned. |
| `GenAuto` / `GenBlock` | 8 / 12 B, unchanged | 0 on psp103 | 0 | `u32` handles only. Pinned. |
| `StrengthWord` | 2 B, unchanged | 13 (static table) | 0 | Pinned. |
| `SwitchArm` | 24 B, unchanged | 12 (static table) | 0 | The 16 B `shape` slice could be a `u8` index into four strings, but it is a 12-row comptime table that is never iterated. |
| `specify.timing_checks` value | 2 B, unchanged | 12 (static table) | 0 | Already two `u8`s. |
| UDP entry columns (`parseUdpEntry`) | 3 × 80 B stack buffer | per UDP row, 0 on these models | 0 | Stack scratch with a stated capacity (`max_udp_inputs`), no heap. |
| `Parser.attrs` (`NatureAttr`, 12 B) | unchanged | 2,148 specs, 100 KB requested | 0 | Per-module scratch, cleared at `endmodule` and duped into `ModuleDecl.attrs`. Handing the list over would save the ~26 KB dupe; not worth losing the reuse across modules. |
| `access_names` | unchanged | 16 | 0 | Frozen; see seam 6. |
| `kw_stack` | unchanged | 0 on these models | 0 | Grows only under `begin_keywords. |

Parser-requested bytes (a counting allocator around `parseSourceFile`,
debug build, the user parse only):

| model | before | after | allocations before → after |
|---|---|---|---|
| psp103 | 6,652,489 B | 6,273,409 B (−5.7 %) | 4,937 → 3,509 |
| bsim4va | 5,220,418 B | 4,986,310 B (−4.5 %) | 5,070 → 4,480 |
| hisimhv_va | 10,116,583 B | 9,620,879 B (−4.9 %) | 11,023 → 9,721 |
| 20,000-statement synthetic | 51,057,949 B | 48,498,085 B (−5.0 %) | 120,095 → 100,097 |

The remaining bytes are AST stores: `exprs.nodes` (3.25 MB requested on
psp103), `stmts` (1.2 MB), the string interner (0.58 MB) and the real pool
(0.23 MB), all owned by `ast.zig`.

Instructions (callgrind, ReleaseFast `-Dcpu=x86_64_v2`, `vera --lint`;
`parseSourceFile` inclusive, prelude parse included):

| model | total before → after | `parseSourceFile` before → after |
|---|---|---|
| psp103 | 1,104.6 M → 923.3 M (−16.4 %) | 222.6 M → 41.3 M |
| bsim4va | 968.3 M → 827.3 M (−14.6 %) | 169.7 M → 28.6 M |
| hisimhv_va | 1,788.2 M → 1,567.0 M (−12.4 %) | 273.9 M → 52.8 M |

Wall time and peak RSS (ReleaseFast native, `vera --emit-zig -I $M $M/<m>.va`,
six runs each, interleaved; time is the best run, RSS the median, because
the same binary at two paths measured 4.3 MB and 5.3 MB on an empty module,
so ±1 MB is mapping noise):

| workload | before | after |
|---|---|---|
| psp103 | 0.14 s, 34.3 MB | 0.13 s, 33.6 MB |
| bsim4va | 0.10 s, 25.2 MB | 0.09 s, 24.9 MB |
| hisimhv_va | 0.23 s, 54.3 MB | 0.21 s, 53.9 MB |
| 20,000-statement synthetic, `--lint` | 4.86 s, 328.5 MB | 4.90 s, 326.1 MB |
| `--lint` over all 3228 fixtures | 1.107 s | 1.085 s |

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
