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
| 2 | `base` | leaf | `lib/base/` | `deep_stack.zig` (from `frontend/`), `interner.zig` (`StringInterner`/`StrId`, from `frontend/ast.zig:135`), `big_arena.zig` (from `lib/`) | — |
| 3 | `kernels` (= `rt`) | runtime | `lib/kernels/` | `kernels/*.zig` (from `lib/backend/kernels/`, bytes unchanged); `integer.zig` + `ref4.zig` (from `frontend/`); `fold.zig` (the value folds of `frontend/constfold.zig:16-445`, with the operator enums from `ast_expr.zig`); `fmt.zig` (from `src/sim/fmt.zig`); `strToInt` (from `lower.zig:985`); `text.*`, the `@embedFile` exports | `contract` |
| 4 | `diag` | compiler | `lib/diag*` | Unchanged. Already a leaf, and it owns `Span`. | — |
| 5 | `dynlib` | leaf | `lib/dynlib.zig` | Unchanged | — |
| 6 | `frontend` (= `syntax`) | compiler | `lib/frontend/` | `pp/`, preprocessor, lexer, token, `parser/`, `ast*`, the `constfold` AST walker, libmap, spice_cards, wreal | `base`, `diag`, `kernels` |
| 7 | `sim` | runtime | `src/sim/` | Everything except the emitter (row 14), then the interpreter (B4) | `contract`, `base`, `kernels`, **[A: `diag`, `frontend` until B4]** |
| 8 | `elab` | compiler | `lib/elab/` | `ir/elaborate.zig` + `elaborate/`, `dist.zig`, `discipline_rules.zig`, `hier_param.zig` | `base`, `diag`, `frontend`, `kernels` |
| 9 | `ir` | compiler | `lib/ir/` | `mir`, `callee`, `opcode`, `op` (+ the `enable_arg`/`needs_input` columns of `codegen/op_zig.zig`); `lowered.zig` (= `lower/tables.zig`); the `Lower` types downstream code sees (`ground`, `HeldVar`, `NoiseSrc`, `Contribution`, `ParamInfo`, …); `simparam.zig` (`sysfunc.zig:646-667`); `names.zig` (= `backend/naming.zig` plus the `__xz`/`__w{k}`/`__1b`/`__held__` spellers) | `base`, `diag`, `kernels`, **[A: `frontend`, `elab` until Phase 11]** |
| 10 | `analog` | compiler | `lib/analog/` | `lower.zig` + `lower/` (minus `tables.zig`), `ssa.zig` | `base`, `diag`, `frontend`, `elab`, `ir`, `kernels` |
| 11 | `prove` | compiler | `lib/prove/` | `analysis`, `ifconv`, `proof` + `proof/`, `verify` (it needs `Analysis`, `verify.zig:24`); `prune_held.zig` and the setup-tier `solve` (`codegen/plan/setup.zig`, `input.zig`, the argument facts in `args.zig`) | `base`, `diag`, `ir`, `kernels`, `contract`, `analog` (tests only) |
| 12 | `zigbuild` | tool | `lib/zigbuild/` | `orchestrator.zig` build policy, `driver/server.zig`, `driver/shim.zig`, `codegen.Output` (`codegen.zig:61`), the build-exe half of `tb/exe.zig` | `dynlib` (tests). No compiler module. |
| 13 | `device` | backend | `lib/device/` | `codegen.zig` + `codegen/`, `cg_*.zig`, `kernel_text.zig` | `base`, `diag`, `ir`, `prove`, `kernels` (text), `zigbuild` (`Output`); tests: `frontend`, `analog` |
| 14 | `digital` | backend | `lib/digital/` | `src/sim/digital/{emit,emit_expr,plan}.zig` + `emitDevice` (`digital/root.zig:1425-1434`). Until B4 this is the emitter over the interpreter's `Run`; after B4 it is the lowering to digital IR. | `sim`, `frontend`, `diag`, `contract`, `kernels`, `base` |
| 15 | `verilog` | backend | `lib/verilog/` | `beh_verilog.zig` | `diag`, `ir`, `kernels`, **[A: `frontend` until Phase 11]** |
| 16 | `exe` | backend | `lib/exe/` | `tb.zig`, `tb/directive.zig`, `tb/runner.zig`, `tb/runner_text.zig` | `base`, `diag`, `frontend` (the `//!` lexer), `ir`, `zigbuild` |
| 17 | `vera` | compiler | `lib/root.zig` | The spine, plus `compileAnalog`'s target lines and the OSDI checks from `main.zig`. Pub names stay frozen: `vera.codegen`, `vera.tb`, `vera.orchestrator`, `vera.beh_verilog` become re-exports. | everything above |
| 18 | `vpi` | tool | `src/vpi/` | Unchanged | `frontend`, `ir`, `vera`, `sim` |

These stay outside `module_specs`, as today: `src/main.zig` + `src/cli/`,
`tools/osdi_dyn.zig` (the rewrite's `osdi_shim`), and `tools/zrunner.zig`.

**Where the target cannot hold without a behaviour change:**

- **`sim` → `frontend`/`diag`.** The interpreter, the interpreted fallback (`emit.zig:174-190`, `rt/root.zig:47-71`) and the mixed testbench (`tb/runner_text.zig:1432-1433`) all parse at run time. Only B4 removes this.
- **Devices that never print.** Needs B2.
- **Device-published names.** Needs B1, an ABI change.
- **A mixed design elaborated once.** Needs B4.
- **An `ir` that imports only `base`/`kernels`.** Holds only after Phase 11, because until then `Lowered` carries `*const Ast.SourceFile` (`tables.zig:692`) and `Elaborate` rows (`:674`, `:712`).

## 2. Blockers, per invariant

**I1. A runtime never imports the compiler.**
- `build.zig:42`: `sim` imports `diag` and `frontend`.
- Through `Integer`: `src/sim/rt/logic.zig:8`, `src/sim/fmt.zig:8`.
- Through `deep_stack`: `rt/root.zig:24`, `digital/compile.zig:15`, `exec.zig:17`, `digital/root.zig:22`, `emit.zig:79`.
- The whole interpreter (`digital/*.zig`).
- Emitted text: `emit.zig:181`, `runner_text.zig:1432-1433`.
- **Fix:** Phases 2–3 remove the `Integer`/`fmt`/`deep_stack` edges, Phase 9 removes the emitter, and B4 removes the rest. `vpi` is reclassified as a tool rather than fixed (§5.3).

**I2. Backend import closures are disjoint.** There is one `backend` row (`build.zig:35`), so the build cannot see this rule. The file-level violations are:
- `tb/exe.zig:6` → `orchestrator.zig:19` → `codegen.zig`.
- `driver/shim.zig:9` ↔ `orchestrator.zig:23`. The `Part` enum duplicates `contract.DevicePart`, and `tests/test_all.zig:119` keeps the two equal.
- `naming.zig` is read by both `codegen/plan/names.zig` and `tb/runner.zig:15`.
- Test-only: `naming.zig:256` and `beh_verilog.zig:614` → `codegen/plan/fixture.zig`.
- `orchestrator.zig:188`/`:293` take `codegen.Output`.
- **Fix:** Phases 7–8.

**I3. `ir` holds types only.**
- `lib/ir/root.zig:16-27` exports logic: `Elaborate`, `Lower`, `Ssa`, `Analysis`, `ifconv`, `proof`.
- `mir.zig:9,47,311` takes `StrId` and the interner from the Ast.
- `opcode.zig:8-9,45-47,194` takes the Ast operator enums and `constfold`.
- `lower/tables.zig:23-30` imports Lexer, Preprocessor, Elaborate and `sysfunc`; `:878-889` is logic.
- Downstream code calls lowering logic: `codegen/call.zig:35,269,697,704`, `host_expr.zig:337`, `plan/setup.zig:245`, `file.zig:542`, `render.zig:105`, `analysis.zig:1097`.
- **Fix:** Phases 3, 4, 5, 6 and 11.

**I4. `elab` never writes the Ast.**
- Elaboration writes it: `elaborate/clone.zig:61,450,495,516,519,546,569,680`, `insert.zig:447`, `names.zig:618,774`, `instance.zig:170,360`, `elaborate.zig:788`, `hier_param.zig:113`, `discipline_rules.zig:186,189`.
- `src/sim/digital/root.zig:1571-1575` writes it too.
- There are 16 mutable `*Ast.SourceFile` signatures and 434 `exprs.` reader sites.
- Interning is allowed: the interner becomes a `base` table that several stages write.
- **Fix:** Phase 12.

**I5. A device never prints or exits.**
- `codegen/plan/args.zig:12-23` (`Display.emit`).
- Emitted `std.debug.print` at `cg_display.zig:252,328,549`.
- The `zHalt` → `process.exit` kernel (`cg_display.zig:1437`).
- Kernel prints and exits in `table_kernels.zig:41-60`, `rng_kernels.zig:169-170`, `file_kernels.zig:161-162,338,346`, `str_kernels.zig:770-776,1037-1038`, `hist_kernels.zig:122`.
- The public `--display=emit` (`src/cli/args.zig:263,266`).
- **Fix:** B2. `contract.Say` carries only `f64` arguments today (`contract.zig:165`), so B2 extends the ABI first.

**I6. Operator semantics live once, in `rt`.** There are five copies:
1. `frontend/integer.zig`
2. `frontend/constfold.zig:241,263,393` (via `opcode.zig:194`)
3. `src/sim/rt/logic.zig:288`
4. `kernels/wide_kernels.zig:349-403` (device text)
5. `src/sim/digital/evaluate.zig:393`, plus the emitted operator text (`codegen/op_zig.zig`, `opcode_zig.zig`)

**Fix:** Phase 3 moves copies 1 and 2 into `kernels`. Copies 3–5: see §5.5.

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
- **R2:** backend closures are pairwise disjoint. Until Phase 8 this is checked at file level: the closure of `lib/backend/tb/**` must not reach `codegen.zig` ∪ `codegen/**` ∪ `cg_*`. An allowlisted edge is cut from the walk. Allowlist: `tb/exe.zig` → `orchestrator.zig` until Phase 7, and `naming.zig` → `codegen/plan/fixture.zig` until Phase 8.
- **R3:** no Ast writes outside `lib/frontend`. A write is a call to an Ast appender (`exprs.add*`, `addStmt`, `seqBlockMut`, `seedFrom`) or an assignment to a `SourceFile` field other than `strings` through a receiver spelled `…file`. Allowlist: per-file counts in `elaborate.zig`, `elaborate/{clone,fixture,insert,instance,names}.zig`, `hier_param.zig`, `lower.zig` (its test harness), `lib/root.zig` (the five caller-set fields) and `src/sim/digital/root.zig`, until Phase 12.
- **R4:** no `*Lowered` mutated outside lowering. Checked as a mutable `*Lowered` on a `pub` line or in a struct field outside `lib/ir/lower{.zig,/}`. Allowlist: `pruneHeld` (`plan/setup.zig:742`) until Phase 6.
- **R5:** each of the `__xz`/`__w{d}`/`__1b`/`__held__` literals has one owner: `lower/context.zig` for the first three, `plan/names.zig` for `__held__`. Allowlist: `lower/expr.zig` (three) and `tb/runner.zig` (four) until Phase 8.
- **R6:** no emitted `debug.print(`/`process.exit(` in device-emitting files (`codegen.zig`, `codegen/**`, `cg_*`, `kernels*`). Allowlist: per-file counts in `cg_display.zig`, `kernel_text.zig`, `render.zig` and five kernel files until B2.
- **R7:** a per-file ceiling on `std.mem.eql(u8` in `lib/` and `src/`; a line with `// str: <LRM data>` does not count. The ceilings are the counts of 2026-10-17 (479 sites in 81 files); they have no deleting phase.

Sharpened on 2026-10-17 against the tree at `1518183f`, because a rule the test reads
from text has to say which text: R2's `beh_verilog.zig` → `fixture.zig` row is gone,
since nothing under `tb/` reaches `beh_verilog.zig` (it returns at Phase 8, when R2
becomes module-level and `verilog` is its own row); R2 names `codegen.zig`, which
`orchestrator.zig:19` reaches, beside `codegen/**`; R3 and R4 say what counts as a write;
R6 matches the kernels' `std` aliases (`zstd.`, `zhs.`); the `setup.zig:700` and I4/I5
line numbers had moved.

**Behaviour changes come last.** Each is its own commit series and its own minor release.

- **B1: name tables in `contract`.** The device publishes `pub const` tables: x/z shadows, word slices, held fields, status. `contract` declares them and `validate` checks them. `tb/runner.zig:522-585` resolves them at comptime against `@import("device")`. Every golden moves and `abi_version` is bumped. Gate: the `test-devices` and VERDICTS name lists are unchanged.
- **B2: devices record `Say`.** First extend `Say` with string and file operands. Testbenches then build `.record` devices, and the runner formats them with `contract.formatSay` (`contract.zig:209`). Kernel exits become status records. `--display=emit` warns in this minor and is removed in the next. Device goldens move; transcripts stay identical, or each one that moves is listed per fixture before landing.
- **B3: bench as a compiled library.** The fixed solver bodies of `runner_text.zig` move to `src/sim/bench/`, beside `sim.spice`, which the text already calls (`tb/test.zig:918`). The generated `main` passes plan data at comptime. Goldens stay unchanged. The Phase 0 runner snapshot is re-based deliberately, and transcripts and VERDICTS names gate the move. `mixed_body` stays until B4.
- **B4: digital lowering to digital IR.** `digital` lowers elaboration's `Design` to IR tables, and `sim` executes the IR. Then `digital/{elab,compile,bind}.zig`, `rt.interpret`, the fallback at `emit.zig:174-190` and `mixed`'s `Run` are deleted, and VPI's model moves to the IR. The first-vs-last `findModule` split (W1152) is unified, so diagnostics and `.v` goldens move. B4 lands in slices, in the order of slice 3 in §8 of the rewrite's ARCHITECTURE.md, one release each. Afterwards R1's allowlist is empty.

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
2. **A separate `osdi` module.** The OSDI checks are two diagnostics (`main.zig:254,267`), and they go into the spine. A module for them fails §11.4.
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
| 1 | written 2026-10-17 on branch `phase1-fitness` (`ModuleSpec.role`, `tests/import_graph.zig`, `tests/fitness.zig`); awaits its gate, `zig build test` |
| 0, 2–12, B1–B4 | not started (2026-10-17) |
