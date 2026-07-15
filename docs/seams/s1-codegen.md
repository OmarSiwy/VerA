# Seam notes: s1-codegen (UNITS.md U67 + U00, U01, U58-U63, U65, U66)

Step-1 agent for `lib/backend/codegen.zig`, `lib/backend/codegen/**` and
`lib/backend/cg_{display,filters,limit}.zig`. Base `1d3618f8`. Nothing
outside that set was edited; every proposal below is for the seam agents.

## Spine and ownership after step 1

`generate` (codegen.zig) -> `Gen.prepare` (the `plan/` planners, each a
value: names, topo, filters, limits, noise, sinv, qs, jobs, core, setup
roots) -> `file.emitFile`, the emission spine, one line per emitter in
device.zig order: kernel text, `U`/`Model`/`derive`, `Setup`, `Instance`
(`instance.zig`), `setup`, units (`unit.zig`, with `cfg`/`render`/`call`/
`host_expr` below it), `eval`/`q` (`dispatch.zig`), source tables
(`noise.zig`), `systf_calls`, the state machine (`state.zig`), `limit`
(`cg_limit`), collapse/breakpoints/delays, `deriv_reads`/`jac_const`,
batch decls, `contract.validate`.

`Gen` is grouped by writer: inputs, device plans (written once by
`prepare`), output (`out`, `files`), the declaration being written
(`uses`, `fatal`, `probe`, `hoist`, ...), and accumulated evidence
(`jac`, `fam_masks`, `hist`, the core slices).

## Seam proposals

1. **Move `cg_display.zig`, `cg_filters.zig`, `cg_limit.zig` under
   `lib/backend/codegen/`.** They are codegen sub-files in every respect
   (they import `codegen.zig`, take `*Gen`, and are only called by it), but
   `lib/backend/root.zig:14-18` re-exports them by path and `lib/root.zig:32-33,584`
   names two in its refAllDecls list, so step 1 could not move them.
   Better: `codegen/display.zig`, `codegen/filters.zig`, `codegen/limit.zig`;
   `backend/root.zig` drops the three re-exports (codegen.zig's own `test`
   block reaches them) and `lib/root.zig` drops `cg_display`/`cg_filters`
   from the refAllDecls tuple. The `Gen` aliases `renderVal`, `f64Const`,
   `f64Expr`, `abort`, `strArg`, `fmtF64`, `probeInstance`, `rootRef`
   exist only for these three files and could then become direct imports.

2. **Drop `backend.UnitPlan`.** `lib/backend/root.zig:12` re-exports
   `codegen/plan/unit.zig` only so `lib/root.zig:31,584` can refAllDecls it.
   It is codegen-internal per-unit scratch; codegen.zig's `test` block
   already references it. Callers: `lib/root.zig` only.

3. **`Output`'s unit columns as one table.** `names`/`unit_lo`/`unit_fn`/
   `unit_hi` are four parallel slices with a tiling invariant stated in prose.
   They are now built from one `std.MultiArrayList(file.UnitFile)`. Sketch:
   `units: std.MultiArrayList(UnitFile).Slice` (or `[]const UnitFile`) on
   `Output`, with `UnitFile` public from `codegen.zig`. Callers:
   `orchestrator.zig:211-252` (`writeTree`), `:836-901` (`splitOutput` and
   its test), `:1219`.

4. **`pruneHeld` belongs to `ir`.** `codegen.pruneHeld` (from
   `codegen/plan/setup.zig`) mutates `Mir`/`Lowered` and `lib/root.zig:330`
   runs it between lowering and if-conversion, so a backend module performs
   an IR pass. Better: `ir` owns it (next to `ifconv`), reading the same
   `Analysis` facts; codegen keeps `Sinv`. Callers: `lib/root.zig:330`,
   `codegen/test.zig`.

5. **`naming.zig` imports a codegen test fixture.** `lib/backend/naming.zig:235`
   imports `codegen/plan/fixture.zig` (test-only). The fixture is a
   generic "hand-built Mir + Lowered + Analysis" and would sit better in
   `ir` (or a shared `testing` file) so naming's tests do not depend on
   codegen's directory layout.

## Bugs found

None confirmed. Observed while reading, not reproduced:

- `float/lanes.zig` (before step 1): `leadLanes` had no doc comment; its
  doc sat merged into `perPoint`'s. Fixed as a doc-only change (no code).
- `file.recordUnitFile` stores output offsets as `u32`; a device whose text
  passes 4 GiB traps on `@intCast` in a safe build (undefined behaviour in
  ReleaseFast). Not reachable by any fixture; stated on `UnitFile`.
