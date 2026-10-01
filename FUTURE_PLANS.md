# Future plans

The continuing v1.0.0 work. Its definition is `docs/ROADMAP.md` §1 and its
standing open-item list is `docs/ROADMAP.md` §5. Passing the existing fixtures
does not close the unmarked implementation gaps in that list.

## 1. Where v1.0.0 stands (main, 2026-09-29)

| Req | State |
|---|---|
| A | AMS strict and digital fixture gates pass at `b033ac35`; the original digital XFAIL name list is retired. The original branch queue and VPI event arrays are integrated. VPI attributes and unmarked AMS defects in ROADMAP §5 remain open. |
| B | No unclassified citation gaps in the fresh `tools/conformance.sh` report at `b033ac35`. This is a static inventory; VPI runtime obligations remain. |
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
| 8 | `wave23/vpi-prim` | 53693967 | Primitives, UDP tables, path and timing-check terms, values and strengths. Annex G numbering of `vpiPolarity`=34, `vpiDataPolarity`=35, `vpiTchkType`=38 (were 38, 39, 40): a C ABI change for VPI apps. | Merged by `12c2d4d9`, reviewed and fully gated through `8bfbc528` (review `cdb2d5ca`). Host checks cover active procedural driver identity, UDP ASCII vectors and register strengths. Both FAIL/XFAIL name lists are unchanged. |

The four VPI branches all edit `src/vpi` and `build.zig`'s `vpi_runs`; merge one
at a time and re-run `zig build test` (which runs `vpi_runs`) after each.

The first merge passed `zig build`, `test`, `test-devices`,
`test-vpi-fixtures`, `test-1364` in the interpreter and native FIFO/static/four
modes, and `--fuzz 1000`. Direct suite captures show no new FAIL/XFAIL names.
`tools/conformance.sh` measured the integrated tree; it leaves the static
citation inventories unchanged. The mintypmax delay fixture now samples after
the update time, avoiding an IEEE §11.4.2 active-region race.

Additional analog and parser work is integrated and fully gated through
`6dca90a7` (2026-09-29), measured by `tools/conformance.sh`. The raw strict and
digital FAIL/XFAIL name lists are unchanged from the preceding numeric gate
at `c76b158f`.

- `c76b158f` includes unsigned and nested `$clog2` operand contexts, packed-reg
  analog conversion, source-seeded hidden random streams and the cached
  builtin-constant rendering fix. Integration moved the packed-width limit
  to actual analog reads, preserving digital-only wide registers, and
  remeasured every generated-device size golden.
- `86843c23`, `14113145` and `06657d25` validate `cross`/`absdelta` arguments,
  implement mixed `absdelta` controls and transport effective real parameters
  to mixed event expressions. Interpolated A2D-to-D2A rollback remains open.
- `157f843d` through `26cc41d5` use absolute periodic schedules and final timer
  controls, including arrays and pure functions. `274a322d` preserves packed
  widths and `$clog2` dependencies when those controls change. Emitted-host
  checks cover deadlines, one body execution and rollback/retry. E0528 and
  `docs/IMPLEMENTATION.md` document effectful calls whose changed inputs cannot be
  recomputed safely; precomputing the call remains supported.
- `8bf8b5ff` and `0ac482f7` correct diagnostic and fixture explanations;
  `0ed50b1a` checks null versus explicit-zero nodesets through an emitted host.
  `92fa96d5` publishes the smallest node potential tolerance across continuous
  segments, including intermediate resolution results, while retaining each
  segment's local nature attributes.
- `eff0e2ac` enforces nonempty parameter headers and override lists, excludes
  header `localparam`, and rejects mixed named/ordered overrides in both
  languages. Legal defaults and named empty values run in neighboring tests.
- `6dca90a7` composes all hierarchical geometry controls through named values,
  aliases, defparams and paramsets. Host-dependent domain checks retain the
  documented implementation boundary.

The next combined checkpoint is fully gated at `b033ac35` (2026-09-29).
`tools/conformance.sh` measured it; both raw FAIL/XFAIL name lists are
unchanged from `6dca90a7`. It includes:

- E0247 for scaled literals in digital delays (`f959eea4`), E0373 for
  aliasparam equation reads (`256eafcc`), and E0926 for a defparam in the
  selected paramset hierarchy (`7bed3930`). Legal neighbors execute.
- Named event arrays, including indexed triggers and automatic activation
  isolation, plus their VPI objects and runtime assertions (`c2930d63`).
  Native indexed-event emission remains on the fallback list below.
- The ordinary duplicate-override E0908 explanation (`e11553ca`) and the
  fixture claim/citation corrections in `b033ac35` (ROADMAP §5.5).

Next integration work: VPI attributes, probe-dependent analog integer
remainder, outer defparams in paramset overload selection, and SPICE name
precedence/warnings are being checked in isolated worktrees.

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

The eighth merge passed the same gate matrix and was measured by
`tools/conformance.sh` at `8bfbc528`. Integration preserves lazy expression
reads, statement callback metadata and multi-value delays alongside the new
primitive objects. Annex G's expected output was regenerated from the combined
header. Both final FAIL/XFAIL name lists match the seventh merge.

Each merge: `git merge --no-ff`, then the AGENTS.md §9 gates (`zig build`,
`test`, `test-devices`, `test-vpi-fixtures`, `test-1364` in the interpreter
and `--native`, `=static`, `=four`, `--fuzz 1000`, the strict-suite name list),
then retire any XPASS marker after re-checking its derivation.

Two older user worktrees remain untouched after read-only review:

- `timerfix`: its base/count periodic-scheduling idea is implemented and
  tested by `157f843d` and the timer follow-ups above. The original worktree
  remains untouched. Its `9a9023db` widened due window is excluded: that
  version can lose representable future breakpoints for tiny periods.
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
  - `b_26_6_11_event_array` executes and passes at `c2930d63`; the remaining
    whole-design marker is `b_26_6_42_attributes` (stops at vpiAttribute);
  - nested/conditional generate metadata and generated net arrays; ordinary
    generated scalar/vector nets and their enclosing scopes are gated at
    `c0e9b469`.
- **Constant select event terms** (`@(posedge v[0])`, `@(v[3:2])`) watch
  their bits of the vector directly in both engines (`compile.selectTerm`,
  `rt.State.watchBits`), so a zero-width pulse inside one pass is seen
  (`b_9_7_2_select_edge_glitch`). Left: a select wider than 64 bits, out of
  range, or of an array element keeps the hidden-slot term one pass later;
  under `--schedule=static` a process waiting on a select term is general,
  not triggered.
- **Compile and run Verilog:** `test-1364 -- --native`, `--native=static`
  and `--native=four` build executables, run them and check their transcripts.
  `zig build test` also executes generated `.v` contract devices in host
  tests. Keep these as runtime gates and inspect each `FALLBACK` entry:
  an embedded interpreter result does not establish native code generation.
  Mark native regression fixtures `// native-required` so a fallback fails
  the native gate; the forced two-state report retains its separate policy.
  On `feat/native-activation` (2026-10-01) no case of `test-1364` falls
  back in `--native`, `=static` or `=four` (607 native). §10.2.3 timed
  tasks that reach themselves run natively: each out-of-line body is a
  process, `rt.State` carries activation contexts (`ctx`, resume rows,
  per-suspension contexts, `act_events`), and the three former fallbacks
  are `// native-required`. Contract devices still refuse them.
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
