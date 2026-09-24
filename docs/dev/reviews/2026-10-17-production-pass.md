# Design review: production pass over the whole tree

- **Change**: bring `lib/`, `src/`, `tools/` and the harness up to AGENTS.md §10/§11 and `PRINCIPLES.md`, block by block (`codebase-improvement`).
- **Domain skills**: `compiler-construction` (lib/), `spice-engine` (src/sim/spice, tb solver), `api-design` (contract, VPI C ABI), IEEE 1364 semantics (src/sim/digital, rt).
- **Hot/cold**: every compiler block is cold (no profile; `docs/measurements/` was deleted in 6e59b3d4). Only `src/sim/rt/` has numbers (commits 0ab7e423, 040f3bd7, 688bc1cf), on gate_adder/ripple_adder designs that are not in the repo, so its verdict is "hot, not reproducible": benchmark first, no layout work until then. `tools/contract.zig` `gm` and `RefFamily` carry in-comment measurements and are left alone (public ABI, tested).
- **Stages run**: R10 per package below; R4/R6 for the architecture and containment packages.

## Step 1: inventory (2026-10-17, six read-only sweeps)

~189k lines, 227 files in lib/ and src/, in 64 blocks. Every file has a `//!` header. No dead whole declarations except those listed under P1. No file-scope `var` in lib/ except the documented `prelude_snapshot` cache and `deep_stack.refuse_for_test`; VPI's globals are forced by the C ABI (no Clause 12 routine takes a context).

Blocks examined and **left alone** (cold, tested, documented, no flag): frontend tokens/lexer, four-state integers, AST facts (constfold, wreal) except asserts, MIR core, SSA, MIR analyses, finiteness proof, codegen device plans, $limit, small-signal, kernels (eval-path and side-effect), the device ABI (`tools/contract.zig`), OSDI host, scheduler/time, SPICE Newton/LU and analyses, contract host drivers, in-process test roots.

## Step 2–3: the plan (packages, in order)

Each package is one branch, one worktree, its own commits; refactor packages keep `zig build golden -- diff` IDENTICAL.

| # | Package | Kind | Goldens | Est. lines |
|---|---|---|---|---|
| P0 | `zig build test -Doptimize=ReleaseSafe` fails: `status_host` exits 1 (Debug passes). Diagnose before anything else | bug (`diagnosing-bugs`) | ? | ? |
| P1 | Delete and de-publish: 7 dead aliases + `assert` re-export in `lower.zig`, 3 unused imports in `lower/wide.zig`, 5 dead VPI/harness aliases, `proof.prove` wrapper, ~80 `pub` items used only in their own file, inline `@import`s folded, 0.16 std names in compiler-side code (~15 sites), stale `docs/measurements` citations | refactor | identical | −60 |
| P2 | String dispatch → typed values (`render.zig:1081`, `dispatch.zig:1030` + 13 callers, `unit.zig:134/333`, `render.zig:799`, `call.zig:37`): AGENTS §4 violation | refactor | identical | −10 |
| P3 | Import cycles and the module edge: pp ↔ parser/spice_cards; `tb/exe` → orchestrator → codegen (move `Backend`/`fileStem`/`strip` to `driver/`); shim ↔ orchestrator and duplicate `Part`/`tb.Analysis` enums (alias the contract's); `float/mode` ↔ `plan/jobs`; `digital/plan` → `rt` (`Reach`); `cli/digital` → `main`; `bench` ↔ `sweep`; `cg_*.zig` into `codegen/` | refactor | identical | −50 |
| P4 | One writer per table: `codegen/plan/setup.zig:700` `pruneHeld` mutates `Lowered` (move to ir); `__xz`/`__w{k}`/`__1b` spellings get one owner (ir tables), used by lowering and `tb/runner.zig`; `Gen.poison` for the five fatal-flag copies | refactor | identical | −15 |
| P5 | Duplicated knowledge: switch-path search (`digital/resolution.zig:156` = `rt/net.zig:572`), EVCD writer (`digital/evcd.zig` = `rt/evcd.zig`), §9.4.3 scanner twice in `systask.zig`, parser/preprocessor segment bookkeeping, `isIdent` twice | refactor | identical | −190 |
| P6 | Contained failure (each a behaviour change with its own fixture, Vague_Decisions row and issue): unbounded crossing-cut loop `mixed.zig:540`, no instruction budget `exec.zig:504`, unbounded `vpiReset` loop `vpi/run.zig:88`, `catch unreachable` reachable from C `vpi/callback.zig:485`, per-call child arenas on the run arena `digital/root.zig:780`, `resolution.zig:124`, per-step EVCD dupes | bug fixes | moves | +80 |
| P7 | Contracts: progress asserts on the ~70 token `while (true)` loops, then asserts where density is 0 (spice_cards, constfold, libmap, parser/*, elaborate/names+insert+resolve, verify, codegen render/cfg/family, sim elab/driver/tchk, dense_lu `n*n == a.len`) | refactor | identical | +250 |
| P8 | Tests move with the code: split `lower/test.zig` (51 tests) into the files they test; VPI `vpi_user.h` ↔ Zig constant parity test (347 hand-copied constants) | tests | identical | +30 |
| P9 | Emitted-text changes (minor version): deprecated `std.fmt.bufPrint`/`std.mem.indexOfScalar` in device text, dead `zwWord` kernel | behaviour | moves | −5 |
| P10 | Grab-bag splits: `sim.digital.Run` VPI helpers → `digital/vpi.zig`; `rt.State` file I/O + format scan → `rt/system.zig`; `kernel_text.zig` inline kernels → `kernels/*.zig` via `@embedFile` | refactor | identical | 0 |
| — | Commit the gate_adder/ripple_adder benchmarks so `rt/` can be ranked hot | measurement | — | +? |

Not planned (recorded): `Ast.ExprStore` has writers in elaboration and `src/sim` (a full R4 review, not a cleanup); the codegen `Gen` table written by every sub-file (same); the ReleaseFast vs ReleaseSafe release-mode conflict (§11.5, user decision).

## Against the rewrite's target architecture

`../VerAReWrite/ARCHITECTURE.md` (read 2026-10-17) is the rewrite's target, not VerA's. This pass takes the parts that are cleanups in VerA's layout and records the parts that are the rewrite itself.

| Target (rewrite ARCHITECTURE.md) | VerA today | Here |
|---|---|---|
| Backends never import each other (§2) | `tb/exe` → `orchestrator` → `codegen` | P3 |
| Device-spelled names published as `contract` tables (§2) | `__xz`/`__w{k}`/`__1b` spelled by lowering and `tb/runner.zig` | P4: one owner in `ir`, goldens identical. Contract tables change the ABI: recorded |
| No string compare decides what code does (§6) | 4 codegen sites | P2 |
| Plans are values, no god object (§3) | `codegen.Gen`, imported by 22 files | P4 `Gen.poison` only; recorded |
| No stage mutates an earlier stage's output (§6) | codegen writes `Lowered`; elab and `src/sim` append to `Ast.ExprStore` | P4 fixes `Lowered`; `ExprStore` recorded |
| Runtime never imports compiler (§2 fitness test) | `sim` → `frontend`; `vpi` → `ir`, `vera` | recorded (rewrite slices 3, 6) |
| Operator semantics once, in `rt` (§6) | five copies | P5 merges the two duplicate pairs found |
| No input-depth recursion; explicit work stacks (§6) | `deep_stack` threads sized to depth | recorded |

**Re-scoped 2026-10-17** by `ARCHITECTURE.md` §4: P3 keeps only the four cycles no phase covers; P4 keeps only `Gen.poison` (pruneHeld → Phase 6, spellings → Phase 8); P5 merges onto the `rt/` side; P9 and P10's kernel_text item land before Phase 3.

## Results

### Wave 1 — P0, P1, P6 (gate 670b9254 against base 7ab21937)

Built once, after merging (the user's rule: agents check syntax with `zig ast-check` + `zig fmt --check`; the gate builds).

| Check | Result |
|---|---|
| `zig build check` | exit 0 |
| `zig build test` (Debug) / `-Doptimize=ReleaseSafe` | exit 1 / exit 1: the same single step, P6's new `b7_sim_control_reset_every_run_rejected.c`, registered `cbEndOfReset` at startup, which §26.2.4 forbids (the fixture was wrong) → fixed in 59520d45. ReleaseSafe otherwise green: P0's #40 holds |
| golden diff | 46 of 7542 files differ: 37 `.v` goldens move only by #36's `try s.loopIteration();` on loop back-edges (and `repeat` re-entry), 9 are new fixtures. Nothing else |
| fixture suite | 2604/2604 → 2604/2605: the one FAIL is P6's new `cross_time_tol_below_time_resolution.va`, which lacked `//! solve` (the testbench read V = 0) → fixed in 76611ff8, 43/43 checks ok by hand-run; without the #35 guard it hangs, so it pins the bug |
| `test-devices`, `test-vpi-fixtures`, `suite-exe` | exit 0 |

P1: −10 net lines over 119 files (152 `pub` made private, 116 std renames, dead aliases). Issues: #35–#39 (P6), #40 (P0).
