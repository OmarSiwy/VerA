# Future plans

The continuing v1.0.0 work. Its definition is `docs/ROADMAP.md` §1 and its
standing open-item list is `docs/ROADMAP.md` §5. Passing the existing fixtures
does not close the unmarked implementation gaps in that list.

## 1. Where v1.0.0 stands (main, 2026-09-29)

| Req | State |
|---|---|
| A | AMS strict and digital fixture gates pass at `9c97b205`; the original digital XFAIL name list is retired. VPI `vpi_runs` still carries known gaps, partly implemented on the queued `wave23/vpi-*` branches. Unmarked AMS defects in ROADMAP §5 remain open. |
| B | No unclassified citation gaps in the fresh `tools/conformance.sh` report at `9c97b205`. This is a static inventory; VPI runtime obligations remain. |
| C | No unclassified citation gaps in the same report. This does not close ROADMAP §5's implementation defects. |
| D | All nine phases, read against `git show 297e97d^:ARCHITECTURE.md` §6/§8 on 2026-09-29. |
| E | Closed: `docs/IMPLEMENTATION.md` §4 reads "None". |
| F | All five targets cross-compile; the VPI runtime does not build on Windows (Zig 0.16 `@cVaStart`). |
| G | Written at release time. |

Release: `tools/conformance.sh --changelog v1.0.0`, fill D by hand, commit,
tag, push (AGENTS.md §3). ABI 5 is unchanged since v0.9.0 apart from additive
optional decls, and `.v` devices, new VPI routines and new diagnostics make it
a minor over v0.9.0 in any case.

## 2. Branch integration queue (in this order)

The original branches are pushed to origin. Their original worktrees were
removed; review and integration work uses separate worktrees. "Gated" means
the AGENTS.md §9 gates passed at the commit named in that row.

| Order | Branch | Head | What it does | State |
|---|---|---|---|---|
| 1 | `wave18/bvpi` | 33a64b20 | Generate-block nets scoped per iteration; null and select ports; instance-array split (§7.1.6); hierarchical task enable; `-incdir`; task/function parameters and events. | Merged by `f8501782`, integrated and fully gated through `4e90fcdd`. Review fixes preserve automatic subroutine constants, validate combined null-port forms and array-width products, parse PATHPULSE mintypmax limits, and copy recursive task outputs into the restored caller. |
| 2 | `wave22/iter` | 18ea1499 | ARPice: `$discontinuity(-1)` becomes `limit`'s `converged` verdict (device stays GPU-eligible); `$simparam("reltol"/"abstol"/"vntol")` as optional host-written Model fields. | Merged and fully gated at `78c53446`; strict and digital FAIL/XFAIL name lists are unchanged. Consumer integration point: write `reltol__`, `abstol__`, `vntol__` in `builder.zig` `deriveModel` next to `nom_temp__`, guarded by `@hasField`. |
| 3 | `wave22/vdev2` | 91138be4 | `.v` devices: locate only A2D crossings some process wakes on; default A2D ttol `min(trise, tfall)/50`; up to 256 pins. | Merged and fully gated at `15bb97ca`; strict and digital FAIL/XFAIL name lists are unchanged. The host tests run the wide counter across packed-plane word boundaries and refuse the first pin count above the limit. |
| 4 | `wave24/tt` | 2dd16b69 | TinyTapeout report: `cross()` fires on a `//! time` grid with no `//! analysis` line; W0750 for events the fixed grid fires late; omitted `--contract` uses the compiler's embedded contract and engine sources. | Merged by `cecf3118`, fully gated through `2cc078b1`. Generated `.log`/`.dat` files were excluded. The reviewed CLI fix stops denied W0750 before execution, and the latch fixture now asserts literal expectations derived from its sample times. TinyTapeout integration hash: `2cc078b1`. |
| 5 | `wave23/vpi-engine` | 3be48ade | User systf calltf overriding built-ins (§20.3/§20.4, sizetf once), cbStmt, cbError/cbPLIError, HDL `$fopen` mcds shared with VPI. | Merged by `1f3a9358`, fully gated through `e13f339f`. Review fixes evaluate retained function arguments on request and observe callbacks registered during an already-running process. Strict and digital FAIL/XFAIL name lists are unchanged. |
| 6 | `wave23/vpi-objs` | 24545fbf | Small VPI object-model rows (timescale, types, iterators, ports, net/reg bits and arrays, parameters, name search), 28 Annex G names. | Merged through `434e7906` by `777b5e18`, then integrated reviewed `288a11c2` as `c0e9b469`; fully gated there. Superseded engine/parser changes from the original final WIP were excluded. The structural fixture runs generated scalar/vector nets, bit relationships and enclosing scopes. |
| 7 | `wave23/vpi-behav` | 62875a50 | Behavioural VPI model: forever, disable, indexed part select, concatenation operands, const type, decompile, vpiUse, delay list ops, net decl assigns. | Merged by `cc55db17`, reviewed through `9c97b205`, and fully gated there. Subroutine storage, recursive/forward calls, callback traversal and the active time-format call now run in host fixtures. Statement callback traversal preserves the integrated engine's associations. Both FAIL/XFAIL name lists are unchanged. |
| 8 | `wave23/vpi-prim` | 53693967 | Primitives, UDP tables, path and timing-check terms, values and strengths. Annex G numbering of `vpiPolarity`=34, `vpiDataPolarity`=35, `vpiTchkType`=38 (were 38, 39, 40): a C ABI change for VPI apps. | Review `cdb2d5ca` fixes active procedural driver identity and UDP ASCII vectors. Focused host checks pass; integration and full gates remain. |

The four VPI branches all edit `src/vpi` and `build.zig`'s `vpi_runs`; merge one
at a time and re-run `zig build test` (which runs `vpi_runs`) after each.

The first merge passed `zig build`, `test`, `test-devices`,
`test-vpi-fixtures`, `test-1364` in the interpreter and native FIFO/static/four
modes, and `--fuzz 1000`. Direct suite captures show no new FAIL/XFAIL names.
`tools/conformance.sh` measured the integrated tree; it leaves the static
citation inventories unchanged. The mintypmax delay fixture now samples after
the update time, avoiding an IEEE §11.4.2 active-region race.

Additional reviewed work waiting for its queue position:

- `e96792cb` validates AMS `cross`/`absdelta` arguments; `3171287e` implements
  the mixed runner's `absdelta` enable, tolerances, direction changes and
  dynamic controls. `9a98b0d2` transports effective real parameters to mixed
  event expressions, including instance overrides and parameter sweeps.
  Focused emitted-host and simulator checks pass; integrated gates remain.
  Interpolated A2D-to-D2A rollback remains open.
- `f291b258` preserves the unsigned source width of analog `$clog2` operands
  and the zero extension of packed regs read in analog code. Focused tests
  pass; nested narrow arithmetic is a separate follow-up.
- `922268bb` corrects the array diagnostics' clause references and scope of
  their constant-index restrictions, and the analog conversion explanation.
  `7ffb7aa8` corrects stale fixture explanations; `57b9de27` adds an emitted
  host test distinguishing null nodesets from explicit zero.
- `e6e4598d` replaces repeated addition in emitted periodic timers and
  preserves representable future breakpoints for tiny periods. Focused host
  tests pass. A follow-up implements between-event control changes and mixed
  timer monitors; its fresh embedded-suite capture supersedes the earlier
  raw after-list, which reused an older suite binary. Integrated gates remain.

The node-tolerance draft is under review on `v1/node-abstol-review`.
It reproduces the missing AMS §7.2.4 minimum across connected continuous
segments; its strengthened fixture also checks each segment's §5.5.3 local
nature attributes. Neither is counted as gated yet.

The second merge passed the same gate matrix, including the generated
Newton-verdict and host-tolerance fixtures, and was measured by
`tools/conformance.sh` at `78c53446`.

The third merge passed the same gate matrix and was measured by
`tools/conformance.sh` at `15bb97ca`. The `.v` contract-device extension is
implemented; additional consumer requests remain in §4.

The fourth merge passed the same gate matrix and was measured by
`tools/conformance.sh` at `2cc078b1`. The initial strict run caught the new
latch fixture deriving its expectation from the tested clock expression;
the corrected fixture passes, and both final name lists match the third merge.

The fifth merge passed the same gate matrix and was measured by
`tools/conformance.sh` at `e13f339f`. Its retained-argument fix is `939a5cd0`
(review commit `9631ad93`); preserve its expression-scope metadata when the
behaviour branch changes the expression wrapper. Its callback regression
registers, removes and re-registers `cbStmt` within one running process and
checks each callback before the next assignment.

The sixth merge passed the same gate matrix and was measured by
`tools/conformance.sh` at `c0e9b469`. Its Annex G expected transcript was
regenerated by running the fixture against the combined header. Both final
FAIL/XFAIL name lists match the fifth merge.

The seventh merge passed the same gate matrix and was measured by
`tools/conformance.sh` at `9c97b205`. The integration tests distinguish
module-wide and direct statement callbacks, retain iterator metadata, and
perform new VPI design walks after end-of-compilation. Annex G's expected
output was regenerated from the combined header. Both final FAIL/XFAIL
name lists match the sixth merge.

Each merge: `git merge --no-ff`, then the AGENTS.md §9 gates (`zig build`,
`test`, `test-devices`, `test-vpi-fixtures`, `test-1364` in the interpreter
and `--native`, `=static`, `=four`, `--fuzz 1000`, the strict-suite name list),
then retire any XPASS marker after re-checking its derivation.

Two older user worktrees remain untouched after read-only review:

- `timerfix`: adapt `65e39ac8`'s base/count periodic scheduling with a runtime
  drift/changed-period regression. Do not merge `9a9023db` unchanged: its
  widened due window can make `zNextTimer(1, epsilon, 1)` report no future
  breakpoint even though later representable fires exist. Neither saved
  commit adds fixtures.
- `agent-ab4223a4613f06e12`: leave its uncommitted held-array optimization
  pending. It has no tests, still contains a `VDBG` debug print, and needs
  adaptation to the current setup/scalar-family code. This optimization is
  not a v1 conformance prerequisite.

## 3. Conformance work left

- **VPI gaps in `vpi_runs`** (`build.zig`): the rows not closed by the
  `wave23/vpi-*` branches. Causes and estimates per row are in each branch's
  report and in the area table below.
  - `b_26_6_behaviour` now passes its host assertions at `9c97b205`;
    subroutine arrays and time variables still need complete object metadata;
  - Annex G constant names: the executable `b_G_vpi_user` fixture still
    reports undefined names, each waiting on the object it names;
  - whole-design rows: `b_26_6_11_event_array` (`event e[0:1]`),
    `b_26_6_42_attributes` (stops at vpiAttribute);
  - nested/conditional generate metadata and generated net arrays; ordinary
    generated scalar/vector nets and their enclosing scopes are gated at
    `c0e9b469`.
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
- **Reported flake:** `ch12_vpi_routines/p03_05_convergence_test_rejection`
  failed in the prior session. At `4e90fcdd`, 32 successive host runs exited
  successfully with the exact expected transcript; the old failure did not
  reproduce. Keep investigating if it recurs.
- **Deliberate simplifications** marked `ponytail:` in the code (harvest with
  `grep -rn 'ponytail:' lib src tools tests`), among them: `-incdir` directories
  apply to every library's files; VPI ranges beyond an array's first dimension;
  nested and conditional generates in the VPI model; reg arrays inside
  automatic tasks.
- **Library maps:** `.va` compiles read no map (W0253); VPI refuses a second
  top module; an instance rule cannot reach inside a generate; UDPs bind by
  name, not library.
- **ROADMAP §5.1 decisions** (the remaining open readings) and
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
