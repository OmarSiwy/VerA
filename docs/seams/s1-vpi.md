# s1-vpi: the VPI unit (U73, `src/vpi/`)

Step-1 notes from the architecture pass over `src/vpi/`, written for the seam
agents (proposals) and step 3 (bugs). Base `1d3618f8`. Nothing here was
changed in code; each item names its callers.

## The unit after step 1

Spine, in the order a host drives it (`tests/vpi_host.zig`):

    open(lowered) | openDigital(run)   model/analog.zig | model/digital.zig -> model.zig freeze -> root.design
    runStartupRoutines                 the application registers: systf.zig, callback.zig
    callback.endOfCompile ...          callback.zig dispatch; run.zig (digital) / analog.zig (analog) walk time
    the C routines                     handle.zig, iterate.zig, property.zig, value.zig, delays.zig, print.zig
    close                              frees the model, resets every registry

Ownership (table: owning file; writers; readers):

- vpi_user.h constants, `Obj`/`Scope`/`Iter`/`Design`, `design`, error status: `root.zig`; every sibling reads.
- `Design.objects` / `Design.cold` / `Design.scopes` rows: appended to a `model.Rows` by `model/analog.zig`, `model/digital.zig`, `model.zig`, `code.zig`, `attributes.zig` during `open` only, then taken by `model.freeze`; afterwards only `delays.zig` (vpi_put_delays rewrites `Obj.delays`) and `iterate.zig` (`Design.iters`, and `Design.relations` built on first use) write.
- callback registry: `callback.zig`. systf registry and the active call: `systf.zig`. analog solution and time walk: `analog.zig`. digital run, time queues: `run.zig`. mcd channels: `print.zig`. scheduled events, value-change state: `value.zig`.

Files: `root.zig` 941 lines (was 4289), `code.zig` 1684 (was 2214). New:
`model.zig`, `model/analog.zig`, `model/digital.zig`, `handle.zig`,
`iterate.zig`, `property.zig`, `delays.zig`, `decompile.zig`, `test.zig`.
`vpi_get_analog_value` moved into `analog.zig` beside `quantityValue`.

## Seam proposals

### 1. Doc references outside `src/vpi/` that the split made stale

These files are not mine; the references should follow the code.

- `tests/fixtures/ieee1364/CLAUSES.tsv:303` (§13.6): "a unit test in
  src/vpi/root.zig". The test (`IEEE 1364-2005 §13.6: vpiLibrary, vpiCell and
  vpiConfig of a configured module`) is now in `src/vpi/test.zig`; the
  property it checks is answered in `src/vpi/property.zig` (`vpi_get_str`).
- `docs/Vague_Decisions.md:277`: `src/vpi/analog.zig:414`, `src/vpi/root.zig:2223`.
  The 64-entry derivative table is `derivs` in `src/vpi/analog.zig`; the
  64-byte analog value strings are `analog_buf` in `src/vpi/analog.zig`
  (`vpi_get_analog_value`). Cite by name, not line: both line numbers were
  already stale before this pass.

### 2. The host protocol lives only in `tests/vpi_host.zig`

A host must call, in order: `open` (or `openDigital`), `analog_run.attach`
(analog only), `runStartupRoutines`, `callback.endOfCompile`,
`callback.startOfSimulation`, `analog_run.run` per analysis (or
`run.simulate`), `callback.endOfSimulation`, `analog_run.detach`, `close`.
Nothing in `src/vpi/` states or checks this order; a host that skips
`endOfCompile` silently never runs the build-time `compiletf`/`sizetf` calls
(`systf.buildCalls` hangs off it).

Proposal: one entry per design kind that owns the sequence, e.g.
`vpi.hostAnalog(gpa, lowered, lib, analyses) !void` and
`vpi.hostDigital(gpa, run) !void`, with the individual steps kept for tests.
Callers today: `tests/vpi_host.zig` (`runApp`, `runAnalog`, `runDigital`).

### 3. Process-global session state

`root.design`, the error status, `run.engine`, `analog.zig`'s solution and
derivative tables, the callback and systf registries, `print.zig`'s channels
and `value.zig`'s events are all file-level `var`s. The C ABI takes no
context, so some global is required, but today it is eight of them, reset by
`close` one call each. Proposal: one `Session` struct owning all of them and
a single `var session: ?*Session`, so `close` is one free and a second design
(or parallel unit tests) is one more `Session`. The C routines keep their
signatures. Callers: every `src/vpi` file; externally `tests/vpi_host.zig`
through `open`/`close`.

### 4. Errors reported through globals

`systf.misuse` (a `pub var`) is how `run.simulate` explains
`error.DigitalFailed` to `tests/vpi_host.zig`. Proposal: `simulate` returns a
diagnostic payload (or the host reads it from the session of proposal 3).

### 5. `vpi_user.h` and the Zig constants have no shared source of truth

The constants are written twice: `src/vpi/vpi_user.h` and `root.zig`,
`callback.zig`, `code.zig`, `value.zig`, `systf.zig`, `run.zig`, `analog.zig`.
`tests/fixtures/ch11_vpi/vpi_app.c` checks only the ones it names. Proposal (step 2, it is a
new test): a test that `@cImport`s `vpi_user.h` and compares every `vpi*`,
`cb*`, `acb*` constant the Zig side declares, so drift fails the build.

### 6. The `vpi` module's Zig surface is wider than its callers

External Zig callers (`tests/vpi_host.zig`, `tests/test_all.zig`) use
`open`, `close`, `openDigital`, `runStartupRoutines`, `setInvocation`, `run`,
`callback`, `systf`, `analog_run`. `root.zig` also has `pub` everything its
siblings share (`asObj`, `enter`, `object`, `typeOf`, `Scope`, `Iter`, ...)
because Zig has no file-group visibility; `test_all.zig`'s `refAllDecls`
analyses them all. No action proposed beyond knowing that a `pub` in
`root.zig` is not necessarily API.

## Memory

The data-oriented pass (commits `56329558`, `ee6a6c8a`). Sizes are
`@sizeOf` in ReleaseFast. Counts are from psp103 opened by `vpi_host` with
no analyses (the analog model), and from `big3000.v`, a generated digital
design with 3000 instances in a loop generate, each with a wire, two regs,
an integer and two continuous assignments (the digital model). "Steady" is
what the open design holds; "transient" is what only the build held.

| type | size before → after | count psp103 / big3000 | bytes saved psp103 / big3000 | what changed or why not |
|---|---|---|---|---|
| `root.Obj` | 472 → 224 | 33,802 / 120,015 | 8.1 MB / 29.8 MB steady, plus 16.0 MB / 56.6 MB transient | Hot/cold split: analog topology, array members/range, attributes, `constant_bits`, `event_ref`, `override_expr` moved to `Cold`. `owner`, `slot`, `parent`, `index`, `expr_scope`, `src_engine` are `OptU32` (a `?u32` in 4 bytes). `freeze` takes the builder's list instead of duplicating it (the duplicate was the transient). Pinned: `@sizeOf(Obj) == 224`. |
| `root.Cold` (new) | 240 | 1,179 / 0 | costs 0.28 MB / 0 | One row per object that sets a cold field: psp103's attribute rows and analog topology. `delays`, `def_name`, `port_index` and `src_engine` stayed hot: ports, gates, continuous assignments and generated nets are numerous, and §12.29 can give any gate delays after `open`, when `Design.cold` is fixed. |
| `root.OptU32` (new) | 4 (was `?u32`, 8) | 6 per `Obj` | in `Obj` | An enum, so a missed read or write is a compile error, never a silent `?u32` coercion. |
| `model.Building`, `code.ScopeLists` | 888, 384 (unchanged) | 1 / 3,001 | 0 / 77 MB transient | Unchanged shape. Their 25 growable lists per scope (and every other builder table) moved from the host's allocator to a scratch arena freed when the build returns. With the hosts' page allocator, each nonempty list had been a 4 KiB page: big3000's model build (already with the `Obj` split) peaked 126 MB over the elaborated run, now 49 MB. |
| `model.Rows` (new) | 80 | 1 per build | n/a | The hot and cold lists plus the `Design`'s allocator; replaces `std.ArrayList(Obj)` in every builder. |
| `model.Decls` (new) | 32 + 4 per declaration | 1 per build | n/a | Each scope's attribute-decorated declarations, bucketed by owner once. Replaces a scan of every object per scope (scopes x objects: big3000 spent 89% of its time there). |
| `attributes.ByOwner` (new) | 40 + 4 per binding | 1 per build | n/a | The source's attribute bindings by owner. `attach` scanned every binding for every element it was asked about: 59% of psp103's run. |
| `iterate.Relations` (new) | 128 + 4 per row and per index entry | 0 until a vpiUse, vpiDriver or vpiLoad iterate | n/a | Reverse indexes for §26.6.43 vpiUse and §26.6.22/§26.6.23 drivers and loads, built on first use; each query was a scan of every object. Driver candidates are a superset tested with the old predicate, so answers are unchanged. |
| `root.Design` | 208 → 360 | 1 | -152 B | `cold` slice and the optional `relations`. |
| `root.Scope` | 320 (unchanged) | 1 / 3,001 | 0 | 17 slices; `u32` start/len pairs into one pool would make it ~150 B, 0.5 MB at 3000 instances. Not worth the churn of every `Scope` reader. |
| `root.Iter` | 56 (unchanged) | one per live iterator | 0 | Heap-allocated per `vpi_iterate` and keyed by address; `at: usize` could be `u32` (48 B). Left: its address is the handle identity, which carries the known stale-handle bug. |
| `code.Edge`, `code.Prop` | 8, 8 (unchanged) | on 10,356 / 51,006 and 22,122 / 48,004 rows | 0 | Already a tag and a `u32`. |
| `code.List` | 24 (unchanged) | on 16,402 / 24,003 rows | 0 | A tag and a slice. See the next step below. |
| `code.Builder` | 144 → 152 | one per scope, on the stack | -8 B | `attrs`, the shared `ByOwner`. |
| `callback.Cb`, `systf.Systf`, `value.Event`, `run.Queue` | 120, 136, 24, 8 (unchanged) | one per registration / scheduled event / queue handle | 0 | Heap-allocated one at a time and keyed by address in a `live` map, like `Iter`: the address is the C handle. Few per run. |
| `callback.CbData`, `Time`, `Value`, `VecVal`, `StrengthVal`, `systf.SystfData`, `AnalogSystfData`, `Partials`, `delays.Delay`, `analog.AnalogValue`, `root.ErrorInfo`, `VlogInfo` | 56, 24, 16, 8, 12, 48, 56, 24, 32, 24, 48, 32 | per call | 0 | `extern`, C-visible: frozen. |
| `analog.Row`, `analog.Deriv`, `analog.Lib` | 16, 24 (x64 static), 88 | per contribution row / fixed / one | 0 | Few; read per solve. |
| `root.Kind` | 1 | in `Obj` | 0 | Already `enum(u8)`. |
| `run.Harness` | 3088 | tests only | 0 | Test fixture. |

Measured, ReleaseFast `vpi_host` apps, best of 3 wall and peak RSS, base
`2ea64496` vs `ee6a6c8a`. The machine had a load average of 20-80 from other
agents throughout, so wall times are noisy; user-space instruction counts
(`perf stat -e instructions:u`, one run) are given as the stable measure.

| workload | wall before → after | peak RSS before → after | instructions before → after |
|---|---|---|---|
| psp103.va, model only (`vpi_app`, no analyses) | 0.23 s → 0.11 s | 57.3 MB → 35.1 MB | 8.10 G → 2.76 G |
| hisimhv_va.va, model only | 0.33 s → 0.17 s | 78.9 MB → 48.0 MB | 10.32 G → 1.88 G |
| big1000.v (p04_01 app) | 0.20 s → 0.02 s | 83.0 MB → 30.2 MB | 0.60 G → 0.10 G |
| big3000.v (p04_01 app) | 1.97 s → 0.07 s | 238.1 MB → 80.2 MB | 9.70 G → 0.42 G |
| flat3000.v, 3000 instances written in the top module | 3.61 s → 0.10 s | 233.0 MB → 79.8 MB | 10.97 G → 0.76 G |
| the 53 digital `vpi_runs` apps, summed | under 10 ms each, both | 253.7 → 284.0 MB summed (see below) | 39.0 M → 35.1 M |
| the 19 analog `vpi_runs` apps, summed | 5.70 s → 5.60 s | 149 MB → 149 MB max | (dominated by the `zig build-lib` child) |
| p03_sampnhold.va (largest analog VPI fixture), model only | 0.00 s, both | 6.4 MB → 6.8 MB | 2.64 M → 2.63 M |
| p02_design.v (largest digital VPI fixture) | 0.00 s, both | 5.5 MB → 5.3 MB | |

The small apps' peak RSS is 4-6 MB and is mostly the 41 MB static binary's
text pages: it moves by a few hundred KB between builds that do not touch
the data layout (min of 7 runs of one app across this pass's builds: 3.8 to
5.1 MB), and the new binary is 0.3 MB larger. Their data did not grow: peak
anonymous mappings (strace of mmap/munmap/mremap) fell from 536 to 404 KB
for p02_01 on p02_design.v and from 324 to 308 KB for p03_sampnhold.va. The
instruction counts, which do not vary, fell 10%.

Next step, not taken: the six slices left in `Obj` (`name`, `full`, `edges`,
`lists`, `props`, `delays`, `def_name`: 112 of its 224 bytes) as `u32`
start/len pairs into per-`Design` pools would make it ~168 B. It touches
roughly 300 read sites across every routine file, and two of the pools
(`delays`, written by vpi_put_delays) must stay growable after `open`.

Remaining per-call scans, all small or rare: `handle.zig`'s
vpiActiveTimeFormat lookup (every object, once per such `vpi_handle`),
cbStmt registration on a module (every object, once per registration),
`code.Builder.analogBlocks` (every analog block per scope), and
`model.addModuleArrays` (a parent's children squared, only for children
whose names are array elements).

Found while measuring, in another unit: `sim.digital.exec.resolve` is
quadratic in the number of drivers of one vector net (a 3000-bit wire with a
driver per bit spent 99.8% of a 120 s run there). Reported here for the sim
seam; `src/sim` is not this unit's.

## Bugs found

1. `src/vpi/analog.zig` `attempt`: `_ = l.solve(t, dt, first, last);`
   discards the converged flag that `vera_vpi_solve` returns
   (`lib/backend/tb/runner.zig`, `g_solved = solve(...)`). A Newton failure is
   accepted as a solution and delivered as acbAcceptedPoint;
   `Error.DidNotConverge` is declared and never returned. Trigger: an analog
   design whose solve fails at some step, run through `vpi_host` (for
   instance a diode driven past its pnjlim range in one step). Expected:
   `error.DidNotConverge`, or a backup as for a rejected point. Actual: the
   unconverged `x` is accepted and reported.
2. `src/vpi/iterate.zig` `vpi_scan`/`destroyIter` with `root.asIter`: an
   iterator handle is validated by membership of its address in
   `Design.iters`. After an iterator is freed, the allocator may return the
   same address for the next `vpi_iterate`, so a stale handle the application
   kept is accepted as the new iterator (no generation check). Trigger: free
   iterator A with `vpi_free_object`, call `vpi_iterate` again, then
   `vpi_scan(A)`. Expected: BADHANDLE (§12.35 "no longer valid"). Actual: it
   may scan the new iterator. Same pattern for callback handles
   (`callback.live`).
