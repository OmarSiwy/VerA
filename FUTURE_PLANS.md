# Future plans

What the 2026-09-26 to 2026-09-29 session left open. The v1.0.0 definition is
`docs/ROADMAP.md` §1; its standing open-item list is `docs/ROADMAP.md` §5 (some
rows there were fixed during this session and need a staleness pass).

## 1. Where v1.0.0 stands (main, 2026-09-29)

| Req | State |
|---|---|
| A | AMS strict suite 2038/2038, 0 XFAIL. IEEE 1364 suite: 18 fixture XFAILs after the fixfe merge, retired by `wave18/bvpi` (§2). VPI `vpi_runs`: about 88 pinned xfail lines, partly closed on the `wave23/vpi-*` branches (§2, §3). |
| B | Closed: 365 two-way + 443 classified of 808 (`zig build test-1364 -- --coverage`). |
| C | Closed: 488 two-way + 124 classified of 612 (`zig build benchmark -- --coverage`). |
| D | 9/9 phases. |
| E | Closed: `docs/IMPLEMENTATION.md` §4 reads "None". |
| F | All five targets cross-compile; the VPI runtime does not build on Windows (Zig 0.16 `@cVaStart`). |
| G | Written at release time. |

Release: `tools/conformance.sh --changelog v1.0.0`, fill D by hand, commit,
tag, push (AGENTS.md §3). ABI 5 is unchanged since v0.9.0 apart from additive
optional decls, and `.v` devices, new VPI routines and new diagnostics make it
a minor over v0.9.0 in any case.

## 2. Branches not yet on main (merge queue, in this order)

All eight branches are pushed to origin; their worktrees were removed. "Gated" means
the AGENTS.md §9 gates passed on the branch itself.

| Order | Branch | Head | What it does | State |
|---|---|---|---|---|
| 1 | `wave18/bvpi` | 33a64b20 | Closes measure B on the fixture side: 20 1364 markers (18 Annex A, 2 ch 4); generate-block nets scoped per iteration; null and select ports; instance-array split (§7.1.6); hierarchical task enable; `-incdir`; task/function parameters and events. | Gated on 4bb378b0. Overlaps `wave18/fixfe` (now on main) in `lib/frontend/parser/{module,stmt,decl,specify,generate}.zig` and `ast.zig`; then retire the 5 Annex A markers fixfe's fixes pass (`b_A_2_2_3`, `b_A_3_3`, `b_A_7_4`, `b_A_7_5_3`, `b_A_9_1`). Expect the 1364 suite at 0 fixture XFAIL after. About 1–2 h. |
| 2 | `wave22/iter` | 18ea1499 | ARPice: `$discontinuity(-1)` becomes `limit`'s `converged` verdict (device stays GPU-eligible); `$simparam("reltol"/"abstol"/"vntol")` as optional host-written Model fields. | Gated on c964f644. Goldens change for the 9 fixtures using `$discontinuity(-1)`. Tell ARPice the hash: it writes `reltol__`, `abstol__`, `vntol__` in `builder.zig` `deriveModel` next to `nom_temp__`, guarded by `@hasField`; nothing else changes for them. |
| 3 | `wave22/vdev2` | 91138be4 | `.v` devices: locate only A2D crossings some process wakes on; default A2D ttol `min(trise, tfall)/50`; up to 256 pins. | Not gated (stopped mid-gate). |
| 4 | `wave24/tt` | 2dd16b69 | TinyTapeout report: `cross()` fires on a `//! time` grid with no `//! analysis` line; W0750 for events the fixed grid fires late; `--contract` defaults to the installed `share/vera/contract.zig`. Last commit is WIP: the README `--emit-so` example fix and untracked `.log` files in `ch09_system_tasks` (drop those). | Not gated. Tell the TinyTapeout session the hash. |
| 5 | `wave23/vpi-engine` | 3be48ade | User systf calltf overriding built-ins (§20.3/§20.4, sizetf once), cbStmt, cbError/cbPLIError, HDL `$fopen` mcds shared with VPI. | Not gated as a whole. |
| 6 | `wave23/vpi-objs` | 24545fbf | Small VPI object-model rows (timescale, types, iterators, ports, net/reg bits and arrays, parameters, name search), 28 Annex G names. Last commit is WIP (a generate-net attempt that `wave18/bvpi` supersedes: drop it). | Not gated. |
| 7 | `wave23/vpi-behav` | 62875a50 | Behavioural VPI model: forever, disable, indexed part select, concatenation operands, const type, decompile, vpiUse, delay list ops, net decl assigns. Last commit is WIP (uncommitted edits in `src/vpi` and `b_26_6_behaviour.c` when stopped). | Not gated. |
| 8 | `wave23/vpi-prim` | 53693967 | Primitives, UDP tables, path and timing-check terms, values and strengths. Annex G numbering of `vpiPolarity`=34, `vpiDataPolarity`=35, `vpiTchkType`=38 (were 38, 39, 40): a C ABI change for VPI apps. | Not gated. |

The four VPI branches all edit `src/vpi` and `build.zig`'s `vpi_runs`; merge one
at a time and re-run `zig build test` (which runs `vpi_runs`) after each.

Each merge: `git merge --no-ff`, then the AGENTS.md §9 gates (`zig build`,
`test`, `test-devices`, `test-vpi-fixtures`, `test-1364` in the interpreter
and `--native`, `=static`, `=four`, `--fuzz 1000`, the strict-suite name list),
then retire any XPASS marker after re-checking its derivation.

Two older worktrees predate this session and were left untouched:
`timerfix` (2 unmerged commits: §5.10.3.3 periodic timer fire counting, and a
fire within 4 ulps is due) and `agent-ab4223a4613f06e12` (uncommitted
held-array edits in `lib/backend/codegen/{plan/setup,render,setup,unit}.zig`).
Decide whether to merge or drop each.

## 3. Conformance work left

- **VPI gaps in `vpi_runs`** (`build.zig`): the rows not closed by the
  `wave23/vpi-*` branches. Causes and estimates per row are in each branch's
  report and in the area table below.
  - behavioural object model (`b_26_6_behaviour`): internal scopes, uses,
    decompile, cont-assign values, function sizes, callback iteration, active
    time format;
  - Annex G constant names: 131 of 441 still undefined, each waiting on the
    object it names;
  - whole-design rows: `b_26_6_11_event_array` (`event e[0:1]`),
    `b_26_6_42_attributes` (stops at vpiAttribute);
  - a generate block's nets reachable through VPI (`gen[0].gw`), after
    `wave18/bvpi` scopes them in the engine.
- **`@(posedge v[0])`** wakes one active-region pass later than `@(posedge v)`
  (§11.4.2 allows it, but a glitch inside one pass is missed). An exact per-bit
  event term for constant selects is 2–3 h.
- **Native fallbacks** (named, correct, but run in the embedded interpreter):
  force/release of net selects, concatenation targets of `assign`/`force`,
  pass-switch inout joins in select/concatenation ports, extended VCD. Native
  versions need per-bit force layers and strength tracking in `src/sim/rt`.
- **`test-1364 -- --native=two-state`** reports XPASS for xfails whose defect
  is 4-state only. Decide: a per-fixture `native-state: 4` marker, or treat them
  as not applicable.
- **Flake:** `ieee_pli/p03_05_convergence_test_rejection` failed 1 of 4 runs.
- **Deliberate simplifications** marked `ponytail:` in the code (harvest with
  `grep -rn 'ponytail:' lib src tools tests`), among them: `-incdir` directories
  apply to every library's files; VPI ranges beyond an array's first dimension;
  nested and conditional generates in the VPI model; reg arrays inside
  automatic tasks.
- **Library maps:** `.va` compiles read no map (W0253); VPI refuses a second
  top module; an instance rule cannot reach inside a generate; UDPs bind by
  name, not library.
- **ROADMAP §5.1 decisions** (sixteen questions that need a call, not code) and
  the §5.2/§5.3 tables: re-verify each row against main first.

## 4. Consumer requests deferred (ARPice, TinyTapeout)

- `$vera_prev_iter(expr)` (previous Newton iterate, usable only in a
  `$discontinuity(-1)` condition), about 1 week. ARPice no longer needs it.
  Design: `scratchpad/design/arpice-iter.md` (session scratchpad; the summary
  is here).
- Parameter-dependent collapse of PSP103's NQS nodes at SWNQS=0: about 2 weeks
  plus a contract change. ARPice ships QS and NQS as two devices instead.
- dt history in `SimState`: needs an ABI bump; ARPice predicts on the host.
- `.v` devices: a host-supplied timescale option, ideal (not 1 ps) output
  ramps, and `--state=2`, `assign`/`force`, `$readmem` and §17.6 queues inside
  a device (refused today with E1103).
- ARPice host work that is theirs: `.v` device P4, writing `reltol__`,
  `abstol__`, `vntol__` next to `nom_temp__`.

## 5. Performance and build

- Edit loop: `zig build --watch -fincremental` (AGENTS.md §4). A plain rebuild
  bottoms out near 3 s of single-threaded sema; `zig build test` cannot beat
  its slowest test binary.
- Native `.v` builds: LLVM dominates (a 512-bit gate adder took 54 s against
  Verilator's 3.3 s); `--state=auto` compiles both phases, doubling it. Levers:
  one object per phase so LLVM runs in parallel, a smaller emitted text.
- GPU: hisimhv overflows the amdgcn stack (288 KB > 262 KB); CI builds nvptx
  only and should build amdgcn too.
- Testbench: a dense 48-wide Dual overflows the 8 MB stack on PSP103 NQS; use
  the sparse `RefFamily` or heap-allocate.
- Instance batching: declined for now (ARPice census: whole-run 1.00x on most
  decks). Revisit with sparse lanes on AVX-512; the ABI keeps `S.V` and
  `batch_ok` for it.
- Measured and not built (keep in AGENTS.md §5): liveness-coloured hoist
  slots, no-inline core on GPU, `strict` to `optimized` float mode, limit
  argument stash.

## 6. Housekeeping

- Commits `976b527f`..`d28ed595` on main do not build in between (a deletion
  swept into the earlier commit); `git bisect skip` them.
- `docs/CLAUSE-AUDIT.md` (over 1000 lines) and ROADMAP §5 need a trim against
  what this session closed.
- Old systemd core dumps from Zig (about 4 GB in `/var/lib/systemd/coredump`)
  can be removed with root.
