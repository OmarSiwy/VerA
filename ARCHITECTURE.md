# VerA: target architecture and in-place migration

This is VerA's own migration to the module DAG of `../VerAReWrite/ARCHITECTURE.md`, done
in place under AGENTS.md §4: one phase is one branch, the goldens stay byte-identical,
and no two phases run in `lib/` at once. Behaviour changes ship last, in their own
releases. Every edge cited here was checked against the tree on 2026-10-17. The previous
architecture document, whose nine phases all landed, is `git show 297e97d^:ARCHITECTURE.md`.

**A release rule shapes every phase.** AGENTS.md §3 says a change to a `module_specs`
row is a **minor** release. A phase that adds, retargets or removes a row is
byte-identical *and* a minor release. So all row changes (Phases 2–5, 7–9) land on `main`
before one tag, `0.10.0`. A phase that moves files only inside an existing module is a
patch.

**The golden gate covers less than it looks like.** `zig build golden` snapshots only
`vera --emit-zig` stdout and stderr (`tests/harness/golden.zig:10-14`). It does not cover
the testbench runner text, the shim and engine text (`driver/shim.zig:4-5`), or the
digital `program` executable text. Phase 0 closes that gap first.

## 1. Target tree

VerA keeps a module's name wherever the rewrite only renames it, because a rename is a
row change and breaks embedders (§5.1). Each row carries a role, and the fitness test
(Phase 1) reads it:

- `runtime`: ships as source.
- `leaf`: may be imported by any tier, and imports only `std`.
- `compiler`
- `backend`
- `tool`: an embedder of the compiler.

The table is in final `module_specs` order. **[A]** marks an import that sits on the
fitness allowlist until the bracketed phase removes it.

| # | Module (rewrite name) | Role | Path | Contents (moved from) | Imports |
|---|---|---|---|---|---|
| 1 | `contract` | runtime | `tools/contract.zig` | Unchanged. Its path is installed to `share/vera/`, so it never moves. | — |
| 2 | `base` | leaf | `lib/base/` | `deep_stack.zig` (from `frontend/`), `interner.zig` (`StringInterner`/`StrId`, from `frontend/ast.zig:135`), `big_arena.zig` (from `lib/`); Phase 11: `syntax.zig` (`ExprId`, `Type`, `Direction`, from `frontend/ast.zig`), `directive.zig` (`Region`, `Timescale`, from `preprocessor.zig`), `design.zig` (`Inserted`, `ParamOverride`, `DisciplineResolution` from `elaborate.zig`, `SystemParam` = `hier_param.Kind`) | — |
| 3 | `kernels` (= `rt`) | runtime | `lib/kernels/` | `kernels/*.zig` (from `lib/backend/kernels/`, bytes unchanged); `integer.zig` + `ref4.zig` (from `frontend/`); `fold.zig` (the value folds of `frontend/constfold.zig:16-445`, with the operator enums from `ast_expr.zig`); `fmt.zig` (from `src/sim/fmt.zig`); `strToInt` (from `lower.zig:985`); `text.*`, the `@embedFile` exports | `contract` |
| 4 | `diag` | compiler | `lib/diag*` | Unchanged. Already a leaf, and it owns `Span`. | — |
| 5 | `dynlib` | leaf | `lib/dynlib.zig` | Unchanged | — |
| 6 | `frontend` (= `syntax`) | compiler | `lib/frontend/` | `pp/`, preprocessor, lexer, token, `parser/`, `ast*`, the `constfold` AST walker, libmap, spice_cards, wreal | `base`, `diag`, `kernels` |
| 7 | `sim` | runtime | `src/sim/` | Everything except the emitter (row 14), then the interpreter (B4) | `contract`, `base`, `kernels`, **[A: `diag`, `frontend` until B4]** |
| 8 | `elab` | compiler | `lib/elab/` | `ir/elaborate.zig` + `elaborate/`, `dist.zig`, `discipline_rules.zig`, `hier_param.zig` | `base` (Phase 11: the rows it publishes), `diag`, `frontend`, `kernels` |
| 9 | `ir` | compiler | `lib/ir/` | `mir`, `callee`, `opcode`, `op` (+ the `enable_arg`/`needs_input` columns of `codegen/op_zig.zig`); `lowered.zig` (= `lower/tables.zig`); the `Lower` types downstream code sees (`ground`, `HeldVar`, `NoiseSrc`, `Contribution`, `ParamInfo`, …); `simparam.zig` (`sysfunc.zig:646-667`); `names.zig` (= `backend/naming.zig` plus the `__xz`/`__w{k}`/`__1b`/`__held__` spellers) | `base`, `diag`, `kernels` (~~[A: `frontend`, `elab` until Phase 11]~~ Phase 11) |
| 10 | `analog` | compiler | `lib/analog/` | `lower.zig` + `lower/` (minus `tables.zig`), `ssa.zig` | `base`, `diag`, `frontend`, `elab`, `ir`, `kernels` |
| 11 | `prove` | compiler | `lib/prove/` | `analysis`, `ifconv`, `proof` + `proof/`, `verify` (it needs `Analysis`, `verify.zig:24`); `setup.zig` (the setup-tier `solve` and `pruneHeld`, from `codegen/plan/setup.zig`), `input.zig` (+ `strArg`, the argument fact the tiers read, from `args.zig`), the planner test `fixture.zig` | `base`, `diag`, `ir`, `kernels`, `contract`, `analog` (tests only) |
| 12 | `zigbuild` | tool | `lib/zigbuild/` | `orchestrator.zig` build policy, `driver/server.zig`, `driver/shim.zig`, `codegen.Output` (`codegen.zig:61`), the build-exe half of `tb/exe.zig` | `contract` (`Part` = `DevicePart`), `dynlib` (tests). No compiler module. |
| 13 | `device` | backend | `lib/device/` | `codegen.zig` + `codegen/`, `cg_*.zig`, `kernel_text.zig` | `diag`, `ir`, `prove`, `kernels` (text), `zigbuild` (`Output`), ~~[A: `frontend` until Phase 11] (`call.zig`'s `` `default_transition `` table)~~ (Phase 11: `Lowered.default_transitions`); tests: `frontend` (`codegen/test.zig` parses source), `analog`, `dynlib` |
| 14 | `digital` | backend | `lib/digital/` | `src/sim/digital/{emit,emit_expr,plan}.zig` + `emitDevice` (`digital/root.zig:1425-1434`). Until B4 this is the emitter over the interpreter's `Run`; after B4 it is the lowering to digital IR. | `sim`, `frontend`, `diag`, `contract`, `kernels`, `base` |
| 15 | `verilog` | backend | `lib/verilog/` | `beh_verilog.zig` (the module root) | `ir`, ~~[A: `frontend` until Phase 11] (`constfold`)~~ (Phase 11: `Lowered.decl_attrs`); tests: `prove` (`Fixture`) |
| 16 | `exe` | backend | `lib/exe/` | `tb.zig` (the module root), `tb/directive.zig`, `tb/runner.zig`, `tb/runner_text.zig`, `tb/test.zig` | `diag`, `frontend` (the `//!` lexer), `ir`, `zigbuild` |
| 17 | `vera` | compiler | `lib/root.zig` | The spine, plus `compileAnalog`'s target lines and the OSDI checks from `main.zig`. Pub names stay frozen: `vera.codegen`, `vera.tb`, `vera.orchestrator`, `vera.beh_verilog` become re-exports. | everything above |
| 18 | `vpi` | tool | `src/vpi/` | Unchanged | `frontend`, `ir`, `vera`, `sim` |

These stay outside `module_specs`, as today: `src/main.zig` + `src/cli/`,
`tools/osdi_dyn.zig` (the rewrite's `osdi_shim`), and `tools/zrunner.zig`.

**Where the target cannot hold without a behaviour change:**

- **`sim` → `frontend`/`diag`.** The interpreter, the interpreted fallback (`rt/root.zig:47-71`, which the text of `lib/digital/emit.zig:174-191` calls) and the mixed testbench (`tb/runner_text.zig:1432-1433`) all parse at run time. Only B4 removes this.
- **Devices that never print.** Needs B2.
- **Device-published names.** Needs B1, an ABI change.
- **A mixed design elaborated once.** Needs B4.
- **The `.v` orchestration in `vera.compile`.** `vera` imports neither `sim` nor `digital`, and both rows come after it in `module_specs`, so moving `src/cli/digital.zig` into the spine is a row change (a minor), not Phase 10's patch.
- ~~**An `ir` that imports only `base`/`kernels`.** Holds only after Phase 11, because until then `Lowered` carries `*const Ast.SourceFile` (`tables.zig:692`) and `Elaborate` rows (`:674`, `:712`).~~ Phase 11: `ir` imports `base`, `diag` and `kernels`; the AST stays with `vera.CompileResult`. `prove` and `device` still import `frontend`, for the tests that parse source (`proof/test.zig`, `codegen/test.zig`), which Zig cannot scope to tests.

## 2. Blockers, per invariant

**I1. A runtime never imports the compiler.**
- `build.zig:42`: `sim` imports `diag` and `frontend`.
- ~~Through `Integer`: `src/sim/rt/logic.zig:8`, `src/sim/fmt.zig:8`.~~ Phase 3: `fmt.zig` moved to `kernels`, and every `src/sim` file reads `kernels.Integer`.
- ~~Through `deep_stack`: `rt/root.zig:24`, `digital/compile.zig:15`, `exec.zig:17`, `digital/root.zig:22`, `emit.zig:79`.~~ Phase 2: these and `digital/elab.zig:29` read `base`.
- The whole interpreter (`digital/*.zig`).
- ~~The emitter: `src/sim/digital/{emit,emit_expr,plan}.zig` and `emitDevice` sat in `sim`'s closure, so every `--emit-exe` executable shipped them (`sim_sources`).~~ Phase 9: they are the `digital` row (`lib/digital/`), a backend over `sim`; `Reach` is defined in `rt` (`rt/root.zig:282`), which the planner reads.
- Emitted text: `lib/digital/emit.zig:182`, `runner_text.zig:1432-1433`.
- **Fix:** Phases 2–3 removed the `Integer`/`fmt`/`deep_stack` edges, Phase 9 removed the emitter, and B4 removes the rest. `vpi` is reclassified as a tool rather than fixed (§5.3).

**I2. Backend import closures are disjoint.** ~~There is one `backend` row (`build.zig:35`), so the build cannot see this rule.~~ Phase 8: the `device`, `verilog` and `exe` rows replace it, and fitness R2 checks the rows. The file-level violations were:
- ~~`tb/exe.zig:6` → `orchestrator.zig:19` → `codegen.zig`.~~ Phase 7: the testbench build is `lib/zigbuild/exe.zig`, and `tb.zig` re-exports it from `zigbuild`, which imports no compiler module.
- ~~`driver/shim.zig:9` ↔ `orchestrator.zig:23`. The `Part` enum duplicates `contract.DevicePart`, and `tests/test_all.zig:119` keeps the two equal.~~ Phase 7: `zigbuild/shim.zig` and `zigbuild/orchestrator.zig` are one module, `Part` is `contract.DevicePart`, and the guard test is gone with the duplicate.
- ~~`naming.zig` is read by both `codegen/plan/names.zig` and `tb/runner.zig:15`.~~ Phase 8: it is `lib/ir/names.zig` (`ir.names`), with the one speller of each shared field name.
- ~~Test-only: `naming.zig:256` and `beh_verilog.zig:614` → `codegen/plan/fixture.zig`.~~ Phase 8: `ir/names.zig`'s tests build their own `Mir` + `Lowered`, `beh_verilog.zig` and `device`'s planner tests read `prove.Fixture`, and `codegen/plan/fixture.zig` is deleted.
- ~~`orchestrator.zig:188`/`:293` take `codegen.Output`.~~ Phase 7: `Output` is `zigbuild`'s and `codegen.Output` aliases it. **The spine passes bytes:** `vera.buildArtifact` (`lib/root.zig`) hands `generate`'s `Output` to `zigbuild.compileRelease`, and `vera.compile` (Phase 10) hands runner text to `zigbuild.buildExe` (as `tb.buildExe`); `zigbuild` never calls a stage.
- **Fix:** Phase 7 (done), Phase 8 (done). What is left of §11.8 is B1: the testbench still derives the field names from the IR (through `ir.names`) rather than reading a table the device publishes.

**I3. `ir` holds types only.**
- ~~`lib/ir/root.zig:16-27` exports logic: `Elaborate`, `Lower`, `Ssa`, `Analysis`, `ifconv`, `proof`.~~ Phase 4: `Elaborate` is a re-export of `elab`. Phase 5: lowering and SSA are `analog`'s, the passes `prove`'s, and `vera` re-exports them.
- ~~`mir.zig:9,47,311` takes `StrId` and the interner from the Ast.~~ Phase 2: it reads `base`.
- ~~`opcode.zig:8-9,45-47,194` takes the Ast operator enums and `constfold`.~~ Phase 3: it reads `kernels.fold` and no longer imports `frontend`.
- ~~`plan/setup.zig:742` `pruneHeld` writes `Lowered` (`held_vars`, `mem_arrays[].held`) from the backend.~~ Phase 6: `prove.setup.pruneHeld` takes `*const Lowered`, rewrites the MIR and returns a held-row mask; lowering's `Lower.dropHeld` applies it at the same spine point. Codegen reads the tiers as a value (`Gen.sinv`, `prove.Input`), and the `needs_input`/`enable_arg` operator columns are `ir.op.needsInput`/`enableArg`.
- `lower/tables.zig:23-30` imports Lexer, Preprocessor, Elaborate and ~~`sysfunc`~~; `:878-889` is logic. Phase 5: it is `ir/lowered.zig`, and the §9.15 rows it read from `sysfunc` are `ir/simparam.zig`. ~~Lexer, Preprocessor and Elaborate stay until Phase 11.~~ Phase 11: `lowered.zig` imports `base`, `diag` and `kernels` only; `tokenSpan` calls the lexer's through `Lowered.token_span`, which lowering sets.
- ~~Downstream code calls lowering logic: `codegen/call.zig:35,269,697,704`, `host_expr.zig:337`, `plan/setup.zig:245`, `file.zig:542`, `render.zig:105`, `analysis.zig:1097`.~~ Phase 5: `call.zig:35` (`unaryMathOp`) was gone already; the `simparam` calls read `ir.Lowered`'s aliases of `ir/simparam.zig`, and `render.zig:109`/`file.zig:805` call `kernels.fold`. Every file after lowering binds `const Lower = @import("ir").Lowered`; only `codegen/test.zig` and `prove/proof/test.zig` import `analog`, to lower source in tests.
- **Fix:** Phases 3, 4, 5, 6 and 11 (all done).

**I4. `elab` never writes the Ast.**
- ~~Elaboration writes it (Phase 4 moved these files to `lib/elab/`, line numbers unchanged): `elaborate/clone.zig:61,450,495,516,519,546,569,680`, `insert.zig:447`, `names.zig:618,774`, `instance.zig:170,360`, `elaborate.zig:788`, `hier_param.zig:113`, `discipline_rules.zig:186,189`.~~ Phase 12: they write an overlay of the parse (`Ast.SourceFile.overlay`), never the parse.
- ~~`src/sim/digital/root.zig:1571-1575` writes it too.~~ Phase 12: the digital runner makes its own overlay.
- There are 16 mutable `*Ast.SourceFile` signatures and 436 `exprs.` reader sites outside `lib/frontend` (plus 234 `&….exprs` aliases and 171 `stmt`/`stmtTok` reads; counted at 751160c1). Phase 12 changed none of them: they read the overlay, whose accessors route a parse id to the parse.
- Elaboration also clones statements (`addStmt`) and interns names, so the overlay continues three id spaces, not one: the interner's, the expressions' (rows, list offsets and the three side tables) and the statements' (rows and blocks).
- **Fix:** Phase 12 (done). R3 still counts the overlay writes, because the text cannot tell an overlay from a parse; those seven rows are permanent ceilings (2026-10-18).

**I5. A device never prints or exits.**
- `codegen/plan/args.zig:12-23` (`Display.emit`).
- Emitted `std.debug.print` at `cg_display.zig:252,328,549`.
- The `zHalt` → `process.exit` kernel (`cg_display.zig:1437`).
- Kernel prints and exits in `table_kernels.zig:41-60`, `rng_kernels.zig:169-170`, `file_kernels.zig:161-162,338,346`, `str_kernels.zig:770-776,1037-1038`, `hist_kernels.zig:122`.
- The public `--display=emit` (`src/cli/args.zig:263,266`).
- **Fix:** B2. `contract.Say` carries only `f64` arguments today (`contract.zig:165`), so B2 extends the ABI first.

**I6. Operator semantics live once, in `rt`.** There are five copies:
1. ~~`frontend/integer.zig`~~ Phase 3: `kernels/integer.zig`
2. ~~`frontend/constfold.zig:241,263,393` (via `opcode.zig:194`)~~ Phase 3: `kernels/fold.zig`, which `constfold` and `opcode.zig` both call
3. `src/sim/rt/logic.zig:288`
4. `kernels/wide_kernels.zig:349-403` (device text)
5. `src/sim/digital/evaluate.zig:393`, plus the emitted operator text (`codegen/op_zig.zig`, `opcode_zig.zig`)

**Fix:** Phase 3 moved copies 1 and 2 into `kernels`. Copies 3–5: see §5.5.

**I7. No pass recurses on input depth.** `deep_stack.run`/`runGuarded` sit at `parser.zig:728,739`, `preprocessor.zig:688`, `libmap.zig:150`, `lib/root.zig:226,377`, and the `sim` sites listed under I1. This one is not copied (§5.4).

**I8. No string compare decides what code does.**
- `std.mem.eql(u8` sites outside tests: `lib/ir/lower` 162, `lib/backend` 100, `lib/frontend` 106, `elaborate` 38, `sim/digital` 25, `vpi` 19.
- Real dispatch: `analog_op.zig:50,90,206-210,327-329,449-462,616-657` (callee names that should be `Mir.Callee`), `codegen/call.zig:37`, `dispatch.zig:1030`, and production-pass P2's list.
- LRM string data is not dispatch, for example `plan/setup.zig:574` (`$simparam("dt")`) and `call.zig:986-1019`. Those lines get a `// str: <why>` annotation.

## 3. Phases

**Gates:**
- **G** = `zig build golden` IDENTICAL + `zig build test` + the `test-devices` name list.
- **G+T** = G + the Phase 0 text snapshot + the `benchmark` VERDICTS name-list diff.

Sizes come from `wc`. The previous plan's estimates were optimistic (its §8), so re-measure each one when its phase starts.

| # | Phase | What moves or changes | Why it is byte-identical | Release | Gate | Size | Risk | Unblocks |
|---|---|---|---|---|---|---|---|---|
| 0 | Gates | `golden` also snapshots, in-process: `tb.renderRunner` text per `//!` fixture, `sim.digital.emit.program` text per `.v` file, the `driver/shim` text | Touches the harness only | patch | `golden diff` of a tree against itself | ~80 lines | low | every phase touching tb/, driver/, emit.zig |
| 1 | Fitness test | `ModuleSpec.role` (`build.zig:12`); the rows passed through `repo_options`; `tests/fitness.zig` in the `test_all` root, reusing `archmap.buildGraph`/`normPath` (`archmap.zig:133,200`, moved to `tests/import_graph.zig`) | Tests only | patch | `zig build test` | ~250 lines | low | measurable progress for every later phase |
| 2 | `base` | `deep_stack`, the interner and `big_arena` move to `lib/base/`; `frontend.deep_stack` and `Ast.StringInterner` stay as aliases | Pure move | **minor** | G | ~700 lines | low | 3, 5, I1 |
| 3 | `kernels` grows into `rt` | Move the kernels directory to `lib/kernels/` **without editing a byte**, since kernel comments are device text. Add `integer`/`ref4`, `fold`, `fmt`, `strToInt`. `kernel_text.zig:656-697,1044` switch to `kernels.text.*`, because an embed cannot leave its module root. | Kernel bytes unchanged; the folds are the same functions behind aliases | **minor** | G+T, `test-rng-reference`, `test-printf-reference` | ~10k lines moved | medium | 5, I1, I6 |
| 4 | `elab` | The elaboration closure moves to `lib/elab/` (`ir/root.zig:3-6` already says it is isolated). The `dist` test that reads `callee.zig` (`dist.zig:102`) moves to `ir`. `ir` → `elab` is allowlisted. | Pure move | **minor** | G | 8.8k lines | low | 5, 12 |
| 5 | `analog` / `prove` split | First, inside `ir`: the downstream `Lower` types and `simparam` move to `ir`, and `unaryMathOp` becomes a callee table. Then `lower/` + `ssa.zig` → `lib/analog/`, and analysis/ifconv/proof/verify → `lib/prove/`. | Same functions, new homes; `vera.*` re-exports | **minor** | G | 22.7k + 6.3k lines | medium | 6, 11 |
| 6 | Setup tiers into `prove` | `pruneHeld` + `solve` + `plan/input.zig` + the argument facts of `plan/args.zig`; the `op_zig.zig:241,258` columns move to `ir/op.zig`. Codegen reads the tiers as a value, so no backend writes `Lowered` any more. | Same algorithm, same spine point (`lib/root.zig:432`) | patch | G | ~1.4k lines | medium | 8 |
| 7 | `zigbuild` | `orchestrator` + `driver/` + `Output` + the build-exe half of `tb/exe.zig` → `lib/zigbuild/`. `Part` becomes an alias of `contract.DevicePart`. The `setup_chunk` test (`orchestrator.zig:1030`) moves to the device tests. | Argv, policy and text unchanged; the whole-file tests of `shim.zig` pin it | **minor** | G+T, `test-tools` | ~2.2k lines | low | 8, I2 |
| 8 | Split `backend` | `naming.zig` + the four name spellers → `ir/names.zig`. Then `backend` becomes the `device` / `verilog` / `exe` rows, and the `backend` row is deleted. Fitness R2 becomes module-level. | Pure move; one speller per name | **minor** (a row removed) | G+T | 26.4k + 1k + 5.5k lines | medium | B1, I2 |
| 9 | Emitter out of `sim` | `emit`, `emit_expr`, `plan`, `emitDevice` → `lib/digital/`. `plan.zig:16` reads `sim.rt.Reach`; `digital/root.zig:30` drops `pub const emit`; `cli/digital.zig:114` changes callee. `sim_sources` shrinks. | Text generators unchanged; `.v` goldens + Phase 0 pin them | **minor** | G+T, `test-devices`, `test-vpi` | ~4.1k lines | medium | B4 |
| 10 | Spine into `vera` | `compileAnalog` (`main.zig:152-430`), E1099/W1098 (`:254`, `:267`) and the `cli/digital` orchestration → `vera.compile`. `main.zig` keeps argument parsing and exit codes. | Streams and exit codes unchanged; `test-cli` pins them | patch | G+T, `test-cli` | ~600 lines | medium | the §3 spine of the rewrite |
| 11 | `Lowered` drops the Ast | What backends read through `Lowered.file`/`.module`/`.directives` becomes precomputed `Lowered` rows (`beh_verilog.zig:109-115`, `call.zig:1422`, `instance.zig` ×2, `tb/runner.zig` ×2, `prover.zig` ×1). `vpi` (9 reads) takes the Ast from `CompileResult`. `Ast.Type`/`Direction`/`ValueRange` move to `base`; `ir` drops `frontend`/`elab`. | Same values, computed earlier | patch | G | ~1k lines | medium-high | I3 |
| 12 | Elaboration overlay | The parser's `Ast` becomes `*const`. Elaboration appends to a `Design.exprs` overlay whose `ExprId`s continue after the parser's, so the ids keep their numbers. `ExprStore` accessors take the pair; `sim` uses the same overlay. | The id space and append order are kept exactly | patch | G+T, `fuzz` replay | 16 signatures, ~434 sites | **high**: stop and re-scope if any golden moves | I4 |

**Fitness rules (Phase 1).** `tests/fitness.zig` checks them under `zig build test`
(the `test_all` root). Every allowlist row names the phase that deletes it, and a
row whose violation no longer exists **fails**, as does a per-file count that fell
below its row, so the allowlist can only shrink. A phase deletes or lowers its rows in
the commit that removes the violation. R3–R7 read production lines: outside top-level
`test` blocks and `test.zig` files, comment lines skipped; R5 and R6 also read `\\`
(emitted) lines.

- **R1:** a runtime row's closure contains no compiler row. Allowlist: `sim` → {`diag`, `frontend`} until B4.
- **R2:** backend closures are pairwise disjoint: no `backend` row's closure (`device`, `verilog`, `exe`, `digital`) contains another `backend` row, read from the rows as R1 is. ~~Until Phase 8 this is checked at file level: the closure of `lib/backend/tb/**` must not reach `codegen.zig` ∪ `codegen/**` ∪ `cg_*`.~~ Allowlist: ~~`tb/exe.zig` → `orchestrator.zig` until Phase 7~~ (deleted with the edge), ~~`naming.zig` → `codegen/plan/fixture.zig` until Phase 8~~ (deleted with the edge); empty since Phase 8.
- **R3:** no Ast writes outside `lib/frontend`. A write is a call to an Ast appender (`exprs.add*`, `addStmt`, `seqBlockMut`, `seedFrom`) or an assignment to a `SourceFile` field other than `strings` through a receiver spelled `…file`. Allowlist: per-file counts in `elaborate.zig`, `elaborate/{clone,insert,instance,names}.zig`, `hier_param.zig` and `src/sim/digital/root.zig` (18 sites). Since Phase 12 each writes an overlay of the parse, not the parse, which the text cannot tell apart, so these rows are permanent ceilings with no deleting phase (decided 2026-10-18; retargeting R3 would rename about 259 `ctx.file` uses in `lib/elab`); ~~`elaborate/fixture.zig`, `lower.zig` (its test harness) and `lib/root.zig` (the five caller-set fields)~~ were deleted with Phase 12, which passes the caller-set fields to `SourceFile.overlay`.
- **R4:** no `*Lowered` mutated outside lowering. Checked as a mutable `*Lowered` on a `pub` line or in a struct field outside `lib/analog/lower{.zig,/}` (`lib/ir/lower{.zig,/}` until Phase 5). Allowlist: ~~`pruneHeld` (`plan/setup.zig:742`) until Phase 6~~ empty since Phase 6.
- **R5:** each of the `__xz`/`__w{d}`/`__1b`/`__held__` literals has one owner: ~~`lower/context.zig` for the first three, `plan/names.zig` for `__held__`~~ `ir/names.zig` for all four since Phase 8 (`snapField`, `wordField`, `xzField`, `heldField`). Allowlist: ~~`lower/expr.zig` (three) and `tb/runner.zig` (four) until Phase 8~~ empty since Phase 8.
- **R6:** no emitted `debug.print(`/`process.exit(` in device-emitting files (`lib/device/**`, `kernels*`). Allowlist: per-file counts in `cg_display.zig`, `kernel_text.zig`, `render.zig` and five kernel files until B2.
- **R7:** a per-file ceiling on `std.mem.eql(u8` in `lib/` and `src/`; a line with `// str: <LRM data>` does not count. The ceilings are the counts of 2026-10-17 (479 sites in 81 files); they have no deleting phase.

Sharpened on 2026-10-17 against the tree at `e0c92073`, because a rule the test reads
from text has to say which text: R2's `beh_verilog.zig` → `fixture.zig` row is gone,
since nothing under `tb/` reaches `beh_verilog.zig` (it returns at Phase 8, when R2
becomes module-level and `verilog` is its own row); R2 names `codegen.zig`, which
`orchestrator.zig:19` reaches, beside `codegen/**`; R3 and R4 say what counts as a write;
R6 matches the kernels' `std` aliases (`zstd.`, `zhs.`); the `setup.zig:700` and I4/I5
line numbers had moved.

**Behaviour changes come last.** Each is its own commit series and its own minor release.

- **B1: name tables in `contract`.** The device publishes `pub const` tables: x/z shadows, word slices, held fields, status. `contract` declares them and `validate` checks them. `tb/runner.zig:522-585` resolves them at comptime against `@import("device")`. Every golden moves, and it ships in a VerA release (`contract.vera_version`). Gate: the `test-devices` and VERDICTS name lists are unchanged.
- **B2: devices record `Say`.** First extend `Say` with string and file operands. Testbenches then build `.record` devices, and the runner formats them with `contract.formatSay` (`contract.zig:209`). Kernel exits become status records. `--display=emit` warns in this minor and is removed in the next. Device goldens move; transcripts stay identical, or each one that moves is listed per fixture before landing.
- **B3: bench as a compiled library.** The fixed solver bodies of `runner_text.zig` move to `src/sim/bench/`, beside `sim.spice`, which the text already calls (`tb/test.zig:918`). The generated `main` passes plan data at comptime. Goldens stay unchanged. The Phase 0 runner snapshot is re-based deliberately, and transcripts and VERDICTS names gate the move. `mixed_body` stays until B4.
- **B4: digital lowering to digital IR.** `digital` lowers elaboration's `Design` to IR tables, and `sim` executes the IR. Then `digital/{elab,compile,bind}.zig`, `rt.interpret`, the fallback at `lib/digital/emit.zig:174-191` and `mixed`'s `Run` are deleted, and VPI's model moves to the IR. The first-vs-last `findModule` split (W1152) is unified, so diagnostics and `.v` goldens move. B4 lands in slices, in the order of slice 3 in §8 of the rewrite's ARCHITECTURE.md, one release each. Afterwards R1's allowlist is empty.

## 4. The production pass (`docs/dev/reviews/2026-10-17-production-pass.md`)

**Land these before Phase 1:**
- P0 (the ReleaseSafe failure) and P1 (deletions).
- P2 (string dispatch). It absorbs `call.zig:37`, which Phase 5 would otherwise move.
- P8 (move tests next to their code). This lets Phase 5's moves carry their tests.
- P9 (emitted text). It lands before Phase 3, so the kernel move copies settled bytes.
- P10's `kernel_text` inline kernels → `kernels/*.zig`. It lands before Phase 3, so `@embedFile` is rewritten once.

**Re-scoped:**
- P3 keeps only `float/mode` ↔ `plan/jobs`, `digital/plan` → `rt` (`Reach`), `cli/digital` → `main`, and `bench` ↔ `sweep`. Phases 7 and 8 take over the `Backend`/`fileStem`/`strip`, `Part` and `cg_*` moves.
- P4 keeps only `Gen.poison`. `pruneHeld` becomes Phase 6 (it goes to `prove`, and needs `solve`, `input` and the `args` facts). The spellings become Phase 8.
- P5 keeps its merges, but each lands on the side that survives B4 (`rt/net.zig`, `rt/evcd.zig`).
- P10 keeps both `src/sim` splits.

**Unchanged:**
- P6 (behaviour fixes in `src/`). Not while Phase 9 is in flight, since both touch `digital/root.zig`.
- P7 (asserts). It lands before Phase 2 or per module after that module's move, never alongside a move phase.

## 5. What VerA deliberately does not copy

1. **Renaming modules to the rewrite's names** (`frontend` → `syntax`, `kernels` → `rt`, `backend` → `device`). A rename is a row change and breaks embedders' `dep.module(...)`, and it gains no import boundary. Rows are added or removed only where an import edge must change.
2. **A separate `osdi` module.** The OSDI checks are two diagnostics, and since Phase 10 they sit in the spine (`vera.compile`, `lib/root.zig`). A module for them fails §11.4.
3. **`vpi` as a runtime over `sim`.** VerA's VPI hosts compile the design (`tests/vpi_host.zig` imports `vera`). It stays a tool-tier embedder; revisit after B4.
4. **Explicit work stacks everywhere.** `deep_stack` already bounds nesting by memory, and fuzzing covers it. Rewriting every recursive pass risks reordering diagnostics, which breaks byte identity. It moves to `base` and stays.
5. **"Operator semantics once" as one implementation.** Devices must be self-contained Zig files that build for PTX/SPIR-V, so `wide_kernels` and the emitted operator text stay device text. VerA keeps one reference (`Integer`, checked by `ref4`) plus a differential test per copy (like `rng_reference.c`, `printf_reference`), and merges only the host-side copies.
6. **`device` without `rt`.** VerA splices kernel text into each device, which is a host-visible property: one file plus `contract.zig`.
7. **`diag` importing `base` for `Span`.** `diag` is already a leaf that owns `Span`.
8. **Rewrite fitness rule 3 (the conformance judge imports only std).** VerA's harness links `vera` on purpose (golden, archmap).
9. **Removing `codegen.Gen`.** `codegen/plan/*.zig` already return values, and none of them imports `codegen.zig`. `Gen` is the emitter's cursor, and no invariant names it. It is reconsidered only if a change drill shows a cost.
10. **Hiding row changes in patches.** Phases 2–9 batch into `0.10.0` (AGENTS.md §3).

## 6. Status

| Phase | Status |
|---|---|
| 0 | landed 2026-10-17 (e0c92073): `golden` also snapshots the runner text (`.runner.txt`), the `--emit-so` tree (`.so/`) and the `.v` program text (`.program.txt`), root-free on disk; gate: wave 5 |
| 1 | written 2026-10-17 on branch `phase1-fitness` (`ModuleSpec.role`, `tests/import_graph.zig`, `tests/fitness.zig`); awaits its gate, `zig build test` |
| 2 | written 2026-10-17 on branch `phase2-base` (`lib/base/`: `deep_stack`, `interner`, `big_arena`; `sim`'s six `deep_stack` sites and `mir.zig`'s interner read `base`); awaits its gate, G |
| 3 | written 2026-10-17 on branch `phase3-kernels` (`lib/kernels/`: the kernel files byte for byte, `root.zig`, `text.*`; `integer`/`ref4`, `fold` with `strToInt`, `fmt`; `frontend` imports `kernels` and drops `contract`; `opcode.zig` and `src/sim` read `kernels`); awaits its gate, G+T, `test-rng-reference`, `test-printf-reference` |
| 4 | written 2026-10-17 on branch `phase4-elab` (`lib/elab/`: `elaborate.zig` + `elaborate/`, `dist`, `discipline_rules`, `hier_param`, byte for byte but `dist.zig`, whose callee test moved to `callee.zig`; the row imports `diag`, `frontend`, `kernels`, since no file needs `base` yet; `ir` re-exports `Elaborate`, and `lower/` and `vera` read `elab`); awaits its gate, G |
| 5 | written 2026-10-17 on branch `phase5-analog-prove`: (a) inside `ir`, `lower/tables.zig` → `lowered.zig` and the §9.15 rows of `sysfunc.zig` → `simparam.zig`, with `ParamOverride` and the `simparam` names on `Lowered`, so backend and `src/vpi` bind `Lower = ir.Lowered`; (b) `lower.zig` + `lower/` + `ssa.zig` → `lib/analog/`, `analysis`, `ifconv`, `proof` + `proof/`, `verify` → `lib/prove/`, and the `ssa` random-program test, which needs `verify`, → `prove/ssa_test.zig`. Rows: `ir` drops `contract`; `analog` imports `diag`, `frontend`, `elab`, `ir`, `kernels`; `prove` imports `diag`, `frontend` [A until Phase 11], `ir`, `contract`, and `analog` for `proof/test.zig` and `ssa_test.zig` only (§1 row 11); `backend` gains `analog` (codegen's tests only) and `prove`; `vera` gains both and re-exports the six names `ir` dropped. Awaits its gate, G |
| 6 | written 2026-10-17 on branch `phase6-setup`: (a) the `needs_input`/`enable_arg` columns of `codegen/op_zig.zig` → `ir.op.needsInput`/`enableArg` (exhaustive switches); (b) `codegen/plan/setup.zig` → `prove/setup.zig`, `plan/input.zig` → `prove/input.zig` (+ `strArg` from `plan/args.zig`; `Display`, `callArgIsValue` and `enableArgIdx` stay), `plan/fixture.zig` → `prove/fixture.zig` (the old path re-exports it until Phase 8 deletes R2's `naming.zig` row). `pruneHeld` takes `*const Lowered` and returns a held-row mask that the spine hands to `Lower.dropHeld` (`analog/lower/var.zig`); R4's allowlist is empty. No `module_specs` row changes: a patch. Awaits its gate, G |
| 7 | written 2026-10-17 on branch `phase7-zigbuild`: `lib/zigbuild/` (role `tool`, imports `contract` and `dynlib`): `orchestrator.zig` (from `lib/backend/`, with `Output` from `codegen.zig`, which now aliases it), `shim.zig` and `server.zig` (from `driver/`), `exe.zig` (from `tb/`, the whole file: argv, module files, batch root; the runner text stays in `tb/runner*.zig`). `Part` = `contract.DevicePart`; `tests/test_all.zig`'s equality guard is deleted. The `setup_chunk` build test moved to `codegen/setup_chunk.zig`. Rows: `zigbuild` added above `backend`; `backend` and `vera` import it; `backend` drops `orchestrator` and `vera.orchestrator` is `@import("zigbuild")`; `tb.buildExe` and friends re-export it. R2's `tb/exe.zig` row is deleted, R7's three rows follow their files. Awaits its gate, G+T, `test-tools` |
| 8 | written 2026-10-18 on branch `phase8-backend`: (a) `lib/backend/naming.zig` → `lib/ir/names.zig` (`ir.names`; its tests build their own `Mir` + `Lowered`), with `snapField` (`__1b`), `wordField` (`__w<k>`), `xzField` (`__xz`) and `heldField` (`__held__`, sanitizing both leaves); `analog/lower/{context,expr}.zig`, `codegen/plan/names.zig` and `tb/runner.zig` call them, same format strings, and R5 has one owner, `ir/names.zig`, and no allowlist; (b) the `backend` row becomes `device` (`lib/device/`: `codegen.zig` + `codegen/`, `cg_*.zig`, a `root.zig` that re-exports `codegen` and `cg_*`), `verilog` (`lib/verilog/beh_verilog.zig`, its own root) and `exe` (`lib/exe/tb.zig` + `tb/`, its own root), every file by `git mv` with only import lines edited; `codegen/plan/fixture.zig` is deleted (its readers take `prove.Fixture`). Rows: `device` imports `diag`, `dynlib` (tests), `frontend`, `ir`, `analog` (tests), `prove`, `kernels`, `zigbuild`; `verilog` imports `frontend`, `ir`, `prove` (tests); `exe` imports `diag`, `frontend`, `ir`, `zigbuild`; `vera` takes all three and `vera.codegen`/`vera.beh_verilog`/`vera.tb` re-export them; `test_all` imports them. R2 is module-level (no backend row's closure holds another) with an empty allowlist; R6/R7 rows follow their files. No moved file is in `sim`'s closure, so `sim_sources` is unchanged. A row change: a minor, batched for `0.10.0`. Awaits its gate, G+T |
| 9 | written 2026-10-17 on branch `phase9-digital`: `lib/digital/` (role `backend`, imports `sim`, `frontend`, `diag`, `contract`, `kernels`, `base`): `emit.zig`, `emit_expr.zig`, `plan.zig` (from `src/sim/digital/`, bytes unchanged but their imports: the interpreter's files are `sim.digital.for_emitter.*`, a namespace since `net`/`vcd`/`evcd` name locals in `digital/root.zig`), and `root.zig` with `emitDevice` (from `digital/root.zig`) and the `program`/`Schedule`/`Logic` aliases. `Reach` is defined in `rt/root.zig`; `plan.zig` aliases `sim.rt.Reach`. `sim.digital.emit` and `sim.digital.emitDevice` are gone; `src/cli/args.zig`, `src/cli/digital.zig` and `tests/harness/golden.zig` call `digital`. Rows: `digital` added after `sim`; the CLI takes it with every row but `vpi`, the suite runner and `test_all` import it. `sim_sources` no longer holds the three files. R7's `emit.zig` row follows its file. Awaits its gate, G+T, `test-devices`, `test-vpi` |
| 10 | written 2026-10-17 on branch `phase10-spine`, the `.va` half: `vera.compile` (`lib/root.zig`) takes a `Request` (the compile `Options`, `--spice`, and one field per target: `verilog`, `osdi`, `expect_module`, `check`, `exe`, `so`, `zig`, `out_path`, `build`), runs `compileAnalog`'s body (SPICE netlist, `//!` directives, the shape-card recompile, the `--param` check, E1099/W1098, then one block per target) and fills an `Outcome` (`status`, stdout's `path` and `text`, the testbench `exe`, the refusal `err`, and `report`: where the bag goes relative to `err`). It prints nothing. `main.zig` keeps argument parsing, the contract tree (`simTree`, which needs the CLI-only `sim_sources`), the `--run` child and the printing, in the old order. `typeCheck` moved to `lib/zigbuild/check.zig` (`zigbuild.typeCheck`), `readFailed` to `vera.readFailed`. **Not moved:** the `cli/digital` orchestration, since `vera` would have to import `sim` and `digital`, which sit after it in `module_specs`: a row change, so a minor release (§1 row 17's "everything above" needs the rows reordered). No row changes: a patch. Awaits its gate, G+T, `test-cli`, `tools/doctest.py` |
| 11 | written 2026-10-18 on branch `phase11-lowered`: (a) `base` gains `syntax.zig` (`ExprId`, `Type`, `Direction`), `directive.zig` (`Region`, `Timescale`, with `Region`'s test from `pp/test.zig`) and `design.zig` (`Inserted`, `ParamOverride`, `DisciplineResolution`, and `SystemParam`, `hier_param.Kind`'s enum with its two tests; `compose` stays in `hier_param` as a free function); `Ast`, `Preprocessor`, `Elaborate` and `hier_param` alias them; (b) lowering fills new `Lowered` rows where it finishes (`Lower.lowered`): `default_transitions` (codegen's `defaultTransition`, the `call.zig` read), `timescale` (`simparamValue`, `tb/runner.zig`'s mixed plan), `decl_attrs` (every declaration attribute spec folded over literals: `beh_verilog`'s `vera_pin`/`vera_delay` loop), `token_span` (the lexer's `tokenSpan`, a cold function pointer) and `ParamInfo.ranges` as `Range` rows whose bounds `lower_param.paramRanges` folds (the prover's `foldBound`, deleted); (c) `Lower.lower` returns `Lower.Output` (`lowered`, `module`, `unit_paths`), `vera.CompileResult` carries `file`, `module` and `unit_paths`, and `vpi.open`/`model/analog.build` take the `CompileResult`; (d) `Lowered` drops `file`, `directives`, `module` and `unit_paths` (lowering keeps the last two as `Lower` fields), `ir.Elaborate` is gone (`vera.Elaborate`, for the VPI), and the `dist`→`Callee` test moves from `callee.zig` to `analog/lower/random.zig`. The `instance.zig` ×2 and second `tb/runner.zig` reads the row named were already gone at 8c364177. Rows: `ir` imports `base`, `diag`, `kernels`; `elab` gains `base`; `verilog` drops `frontend`; `device` and `prove` keep `frontend`, for `codegen/test.zig` and `proof/test.zig`, which parse source. Fitness allowlists unchanged (no row's count moved). `sim_sources` gains the three `base` files. Row changes: a minor, batched for `0.10.0`, not the patch §3 planned. Awaits its gate, G |
| 12 | written 2026-10-18 on branch `phase12-overlay`: (a) `StringInterner`, `ExprStore` and `SourceFile`'s statement columns can continue a base (`base`, set by `StringInterner.continuing`, `ExprStore.continuing` and `SourceFile.overlay`): the base's ids, list offsets, side-table indices and block ids read through the overlay, and its own number on from the base's, so a row copied from the parse keeps working; the five readers of a whole column (`lowerFile`'s E0130 scan, `reserveMir`, `markDiscreteExprs`, `markMemArrays`, the digital runner's per-expression tables) count with `ExprStore.len()`, the three pool-offset guards with `poolLen()`; (b) the spine (`lib/root.zig`), the digital runner (`src/sim/digital/root.zig`) and the four test harnesses (`elaborate/fixture.zig`, `lower.zig`, `codegen/test.zig`, `proof/test.zig`) bind the parse `*const` and hand every later stage an overlay of it, so elaboration's appends and `spiceCase`'s `modules` land in the overlay; the five caller-set fields are `SourceFile.overlay`'s `Compilation` argument. **Not the planned shape:** no `Design.exprs` beside the Ast and no `{ base, over }` view threaded through the readers. Elaboration also clones statements and interns names, so a view would have carried three tables, and the 436 `exprs.` readers, 234 aliases and 171 statement reads would all have changed; the pair lives inside each store instead, and no reader signature changed. Fitness: R3 loses the `fixture.zig`, `lower.zig` and `lib/root.zig` rows (7 sites); the 7 elaboration and runner rows (18 sites) stay, relabelled, because they now write the overlay and the text cannot tell it from the parse. No row changes: a patch. Awaits its gate, G+T, `fuzz` replay |
| B1–B4 | not started (2026-10-18) |
