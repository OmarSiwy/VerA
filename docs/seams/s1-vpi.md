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
- `Design.objects` / `Design.scopes` rows: written by `model/analog.zig`, `model/digital.zig`, `model.zig`, `code.zig`, `attributes.zig` during `open` only; afterwards only `delays.zig` (vpi_put_delays rewrites `Obj.delays`) and `iterate.zig` (`Design.iters`).
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
- `docs/IMPLEMENTATION.md:277`: `src/vpi/analog.zig:414`, `src/vpi/root.zig:2223`.
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
`tests/vpi_app.c` checks only the ones it names. Proposal (step 2, it is a
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

## Data-layout notes (measured or reasoned, not changed)

- `Obj` is one struct for every class (a Fleury megastruct: about 55 fields,
  most of them per-class and defaulted). The handle ABI depends on it: a
  `vpiHandle` is a `*Obj` into `Design.objects`, and `asObj` validates a handle
  by address arithmetic on `@sizeOf(Obj)`. A hot/cold split (a dense
  `kind`/`slot`/`size`/`vtype` column for the value path, the rest cold) is
  possible without touching the C ABI, because the handle is opaque: encode
  the row index in the pointer (`base + index` over a byte-sized column) and
  keep `asObj`'s bounds check. Not done: the value path's cost is the engine
  read, not the row, and no profile says otherwise.
- Per-call O(objects) scans, all already marked `ponytail:`: `iterate.uses`,
  `iterate.driversLoads`, and at `open` `model/analog.zig`'s named-branch
  match (contributions x objects) and `nodeOfRow`. Each becomes an index
  built in `freeze` if a design is large enough to matter.
- `iterate.zig` allocates one heap `Iter` per `vpi_iterate`, registered in a
  hash map keyed by address. A pool with generation counters would make the
  stale-handle check exact (today a freed iterator's address can be reused by
  a new one, and the old handle then validates as the new iterator).

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
