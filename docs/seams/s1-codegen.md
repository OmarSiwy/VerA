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

## Memory

Audit of every type and container the codegen unit defines or allocates,
2026-10-03, on top of `5b00f09f`. Sizes from `@sizeOf` on x86_64; counts
from an instrumented Debug `vera --emit-zig` on ARPice `psp103.va`
(nv = 23869 MIR values, nb = 4234 blocks, 27760 insts, 18 units, 53 jobs;
hisimhv_va: nv = 125531, nb = 6507). Codegen allocates on the compilation
arena (`BigArena`), which lives until `CompileResult.deinit`, so scratch
left there is held through the rest of the compile. Most of the waste was
scratch of that kind, not oversized rows.

Peak RSS, ReleaseFast `vera --emit-zig`, min of 9 runs (3 × best-of-3):

| model | before (5b00f09f) | after | change |
|---|---|---|---|
| psp103 | 34712 KB | 32692 KB | −2020 KB (−5.8%) |
| bsim4va | 26044 KB | 23472 KB | −2572 KB (−9.9%; typical run −1.7 MB) |
| hisimhv_va | 54632 KB | 49692 KB | −4940 KB (−9.0%) |

Time, hyperfine 20 runs each, before → after, min (median): psp103 139.6 →
139.0 ms (146.0 → 141.8), bsim4va 101.0 → 99.8 ms (112.1 → 115.0),
hisimhv_va 228.3 → 225.7 ms (240.1 → 232.8). The machine was shared with
other builds, so σ was 7-48 ms; there is no regression beyond that noise.

| type / container | size before → after | count on psp103 | bytes saved (psp103) | what changed or why not |
|---|---|---|---|---|
| `setup_chunk` working text (`Piece`, `State`, dedent/indent/rename copies) | — | 1 call (psp103's `setup` is over `chunk_bytes`) | ~6.5 MB of arena churn (allocation counter) | Was on the compilation arena; now an `ArenaAllocator` on the gpa scoped to `emitSetup`'s split, freed once `c.text` is copied into `out`. `chunk`'s signature is unchanged (the orchestrator test calls it). |
| `unit.namesIdent` source copy | body size → 0 | 3 core decls (275 KB + 202 KB + …) | ~0.5 MB | Tokenized `out` in place behind a pushed-and-popped 0 sentinel instead of `dupeSentinel` of the whole body. |
| `setup.valueNumbers` `seen` hash map (Key 56 B + Value 4 B) | — | one per setup candidate, 12 doublings | ~2.0 MB arena churn | Moved to the gpa with `defer deinit`: a pass-local table. |
| `setup.valueNumbers` `same` and `planSetup` `root` | nv × 4 B, nv × 1 B | 1 each | 119 KB (hisimhv 628 KB) | Pass-local; gpa + `defer free`. |
| `family.constant` `host` / `aff` | nv × 1 B each | 1 each | 48 KB (hisimhv 251 KB) | Pass-local; gpa + `defer free`. |
| `plan/setup.controlDeps` per-block `ArrayList(Cd)` | 16 B list header per block + doublings → 2 exact arrays | nb = 4234 lists, 2596 entries | ~0.45 MB (353 KB of list growth + 135 KB of headers → 54 KB) | Count-then-fill (CSR): `off`, `cd`, a cursor column; same order. |
| `plan/setup.Cd` | 8 → 8 | 2596 (hisimhv 4824) | 0 | Already minimal (`u32` block + `bool`); pinned `@sizeOf == 8`. Packing `then` into the high bit would save 10 KB; not worth the decoding. |
| `unit.Place` | 24 → 16 | 6854 per probed body (hisimhv 10097) | 55 KB (hisimhv 81 KB) | `defs`/`uses` `u32` → saturating `u8`: every reader asks 0, 1 or more. Pinned `@sizeOf == 16`. |
| `plan/noise.NoiseRow` | 48 → 40 | 16 | 128 B | `source: usize` → `u32` (a dense row id). Not pinned: not hot. |
| `UnitPlan` per-value columns (`needed`, `eager_use`, `arm_use`, `inlined`, `inl_depth`, `slot`, `file_dep`) | 1/4/4/1/2/4/1 B per value | nv each, allocated once, cleared per unit | 0 | Already SoA, one allocation each for the compilation, reused per unit. `eager_use`/`arm_use` stay `u32`: a value's use count is bounded by operands (~3 × insts, over `u16`). |
| `UnitPlan` (struct) | 352 | 1 | 0 | One instance. |
| `unit.sliceCore` `lo_idx` per slice | nv × 4 B | one per core reader that slices it (`state`, `noise`, `iter`): 2 on psp103 and hisimhv_va | 0 (191 KB; hisimhv 1.0 MB) | Left: derivable as `remap[core.lo_idx[v]]`, but 49 sites read `core.lo_idx[v]` as a column, and the slices coexist until the state machine is written. Step-3 candidate: store the remap and index through the full core. |
| `Gen` | 2576 | 1 | 0 | One instance; its tables are what count. Regrouped last pass. |
| `Output` | 120 | 1 | 0 | Frozen boundary; see seam 3. |
| `file.UnitFile` (MultiArrayList row) | 32 | 3 (units in the split form) | 0 | Already SoA (`Gen.files`). |
| `dispatch.Jac` | 160 | 1 | 0 | One instance. `pat`/`dpat` are n_u × u64 (n_u = 12), `lin` 2 × n_u² f64 (≤ 64 KiB at n_u = 64). |
| `unit.Uses` | 5 | 1 | 0 | Five bools, one instance; a packed struct buys nothing. |
| `unit.Probe` lists `sc_end`/`sc_open` | 4 B per scope | 2486 scopes | 0 | Cleared and reused per body (retain capacity). |
| `unit.Hoist` columns | idx 4 B/slot, mask 8 B + grp 4 + pos 4 per element, gmask 8 + glen 4 per group | 6881 slots, 2380 elements, 8 groups | 0 | Already columnar; cleared and reused per body. |
| `Gen.fam_masks` | 8 B per real declared | 1553 (hisimhv 5013) | 0 | Read once by `emitLaneMasks`; 40 KB at most. |
| `Gen.f64_cache` (u64 → slice) | 24 B per entry + map | 168 | 0 | Hits on repeated constants; small. |
| `Gen.out` (gpa) | — | 1.42 MB text, 1.51 MB capacity (hisimhv 4.26 / 4.73 MB) | 0 | Pre-sized to `insts × 24 + 4 KiB`; one remap-doubling, on the gpa so it grows in place. |
| host-expression strings (`f64Const`, `slotRefStr`, `renderToArena`) | — | ~57k `arena.print` calls | 0 | Each is the arena's latest allocation while it grows, so the arena grows and trims it in place; the counter's 9.9 MB is grow traffic, not retention. |
| `setup.Setup` | 72 | 1 | 0 | One instance; `idx` is nv × u32, read per value by every body. |
| `plan/setup.Sinv` | 96 | 1 | 0 | Per-value `val` bool, per-block `blk`, `home` nv × u32: all read by value index. |
| `plan/core.Core` | 184 | 1 + 3 slices | 0 | See `sliceCore`. |
| `plan/names.Names` | 136 | 1 | 0 | Per-unit and per-param name slices; tens to hundreds of rows. |
| `plan/jobs.Job` | 64 | 53 (hisimhv 99) | 0 | Two strings and a `?[]const u8` in a row read whole by the emitter; < 7 KB. |
| `plan/topology.FreeFlow` / `CollapsePair` / `Retention` | 12 / 20 / 8 | 0 / 0 (bsim4va 7 pairs) | 0 | Already `u32`/`u16` fields. |
| `plan/qsite.QSites`, `Stamp` | 32, 16 | 9 sites, 17 stamps | 0 | `sign: f64` is data. |
| `plan/limit.*` (`Limits` 80, `LimitCall` 32, `Decline` 40, `SeedStep`/`Rung`/`Ladder` 12) | — | 0 on psp103 (hisimhv 3 calls) | 0 | Per-`$limit`-site rows; at most tens. |
| `plan/jac.Entry` / `JacConst` | 32 / 24 | 0 guarded (bsim4va 28) | 0 | Built once, small. |
| `plan/noise.Noise` | 112 | 1 | 0 | Container of the rows above. |
| `cg_filters.FilterPlan` | 120 | 18 (one optional per unit) | 0 | `?FilterPlan` per unit, most null; < 3 KB. |
| `cg_display.Spec` / `PrintArg` | 32 / 40 | per print argument (0 in a solver device) | 0 | `width: usize` holds a parsed field width before the E1011 refusal, so narrowing would change overflow behaviour. |
| `opcode_zig.Row`/`Spell`, `op_zig.Row`/`Slot` | 48/24, 40/48 | comptime tables | 0 | Static data in `.rodata`, no runtime instances. |
| `file.Features`, `state.Accept`, `plan/core.Mark`, `setup_chunk.Arms`/`Idents`, `plan/setup.Scan`/`Frame`, `family.Lattice` | — | one per call | 0 | Stack locals of one pass. |
