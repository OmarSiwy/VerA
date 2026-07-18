# s1-sim: the simulator (`src/sim/`)

Step-1 notes for the seam agents. Units U16, U17, U46, U47, U50, U52, U54
(docs/UNITS.md). Base 1d3618f8.

## Spine and ownership (after step 1)

- `digital/root.zig` `elaborate`: preprocess, parse, §19.8 timescales ->
  `elab.zig` pass one (scopes, slots, nets, driver rows, ports, generate,
  parameters, UDPs) -> pass two (drivers, switches, net driver runs, subroutine
  bodies, processes, disables) -> `waiters.buildFanout`. `run` then drains the
  scheduler through `Run.runUntil`.
- `Run.runUntil` (root.zig) dispatches each `exec.Pending` row; `exec.zig`
  runs a process (`execute`), calling `evaluate.zig` for every expression,
  `waiters.zig` for every store and the waiters it wakes, `resolution.zig` for
  every net.
- Tables and owners: `Run.code`/`code_scope` compile.zig; `values`, `nets`,
  `net_cold`, `signals`, `scope_info`, `names` elab.zig (pass one) and
  root.zig (pass two: `drivers`, `net_drivers`, `trans`); `susps`, `terms`,
  `fan`, `armed`, `watch` waiters.zig; `pending`, `free_rows`, `acts`
  exec.zig; `transitions` and `nets[].resolved` resolution.zig.
- `emit.zig` reads a finished `Run` and writes Zig text for `rt/`; `rt/root.zig`
  `State` is the native executable's engine (`rt/net.zig` its nets).

## Seam proposals

1. **`digital.exec` is the VPI's write API.** `src/vpi/value.zig` calls
   `exec.address`, `exec.store`, `exec.trigger`, `exec.release`,
   `exec.forceValue` and `exec.enqueue`. Those now live in `evaluate.zig` and
   `waiters.zig`; exec.zig keeps five aliases so the path still resolves.
   Better: a narrow `Run` write surface (`r.put(slot, planes)`,
   `r.putLater(slot, value, delay)`, `r.trigger(slot)`, `r.release(slot,
   force)`, `r.force(slot, planes)`, `r.elementOf(expr)`), and the VPI stops
   importing the interpreter. Callers: src/vpi/value.zig:714-797.
2. **The VPI scans and mutates `Run.drivers` by (tok, scope).**
   src/vpi/value.zig:153 and src/vpi/code.zig:2096 walk every driver to find
   the one a statement made, and code.zig writes `drv.delay` in place. That
   pins `Driver`'s field names and makes it an AoS row forever. Better:
   `Run.driverOf(scope, tok) ?u32` (an index built once) and
   `Run.setDriverDelay(i, Delay)`, after which `Driver` can go SoA (its hot
   fields are `current`, `or_z`, `s0`/`s1`; `sensitivity`, `scope`, `tok` are
   cold).
3. **`Run.values: []Int.Literal`** is read by src/vpi, src/main.zig and the
   generated mixed runner (`r.values[at].width`, `.asInt()`, `.values()[0]`).
   Each slot is a 24-byte Literal plus its own planes allocation. A plane
   pool with a `Run.valueOf(slot) Int.Literal` view would save about 24 bytes
   and one allocation per slot (12 MB on a 2^19-element net array) but needs
   every outside reader on the accessor first.
4. **`Run.scope_info` rows** are read field by field by src/vpi/root.zig
   (`.parent`, `.lexical`, `.name`, `.index.?`, `.implicit`). `index: ?i64`
   costs 16 bytes per scope (65536 scopes in the generate-limit fixture).
   Better: accessors (`r.scopeParent(s)`, `r.scopeIndex(s) ?i64`), then
   a SoA scope table.
5. **`Run` is one ~130-field struct the VPI reaches into** (`code`,
   `code_scope`, `drivers`, `net_of`, `reals`, `subs`, `sub_base`,
   `call_subs`, `scope_info`, `values`, `file_io`, `vpi_change`, ...). A
   read-only query surface for the VPI (and `lib/backend/tb`'s generated
   mixed runner, which uses `slotOf`, `values`, `watchAnalog`, `a2dWrite`,
   `watchEvent`) would let the engine's tables change shape.

## Bugs found

None confirmed. Hazards worth a step-2 test:

- src/sim/digital/waiters.zig `termsOf`: a far slot's term list
  (`Run.far_terms`, a hash map of lists) is returned as a pointer into the
  map. `wake` holds it across `selectedEvent`, which may call an HDL
  function; if anything reached from there filed a term on a NEW far slot
  (`driver_update` keys and monitor slots are far), the map could rehash
  and the pointer dangle. No path doing that is known.
- src/sim/digital/elab.zig `generate`, `.for_stmt`: the repeated-genvar check
  is a linear scan of every value so far, O(n^2) up to the 65536-iteration
  limit (0.27 s on the limit fixture, ReleaseFast).
- src/sim/digital/elab.zig `mintNet` now refuses (E1100, "too many digital
  net bits") a design whose nets total more than 2^32 - 1 bits, where it
  would have run out of memory: the per-net signal pool is indexed by u32.

## Memory

Sizes from `@sizeOf` (x86_64, ReleaseFast). The suite's workload is the
transcript fixtures, not psp103 (an analog model the simulator never runs),
so counts are on the two heaviest digital fixtures: the 2^19-element net
array of `b_5_2_2_scalar_element_part_select_rejected.v` (524288 nets, 0
drivers) and the 10^7-event `b_11_zero_delay_loop_rejected.v`.

| type | size before -> after | count (part-select / zero-delay) | bytes saved | what changed or why not |
|---|---|---|---|---|
| `digital.net.Net` | 72 -> 48 | 524288 / 1 | 12.6 MB + 524288 allocations | drivers: a slice per net -> one CSR table (`Run.net_drivers`); signal: a slice per net -> a `u32` into one pool (`Run.signals`). Pinned at 48. |
| `digital.net.Driver` | 176 -> 144 | 0 / 0 (one per assign, gate, switch) | 32 B per driver | the 40 B `Inertial` moved to `Run.transitions`, made on a delayed driver's first transition. Pinned. Further SoA blocked by the VPI (proposal 2). |
| `digital.net.NetCold` | 120 | only delayed, trireg, switch-terminal nets | 0 | already the cold half of `Net`. |
| `digital.net.Signal` | 2 | 524288 | 0 | already minimal (two `i8`). |
| `digital.net.Source` / `Gate` | 48 / 40 | per driver | 0 | `Gate.lane`/`out_bit` are `?u32` (8 B each); sentinels would save 8 B per driver. Not done: no workload has enough drivers to measure. |
| `digital.net.Udp` | 72 | per UDP instance | 0 | heap-allocated per instance (`Source.udp: *Udp`); a `u32` into a UDP table would be the DOD form. Counts are small. |
| `digital.net.Tran` | 72 | per pass switch | 0 | few per design. |
| `compile.Instruction` | 40 | one per pc | 0 | largest payloads are two slices (`task`, `switch_ctrl`); VPI matches `.override_eval`. Pinned at 40. |
| `exec.Row` (`Pending`) | 88 (64) | events in flight, recycled | 0 | `write` carries a Literal and `?Sel`; rows are recycled so the count is the queue's high water. Pinned. |
| `waiters.Susp` | 16 | suspended processes, recycled | 0 | pinned. |
| `waiters.Term` | 48 | waiting terms | 0 | 24 B are select-term fields most terms leave zero; `rt` keeps them out of line (`rt.Rec`). Not done: no measurable workload. Pinned. |
| `scheduler.Slot` (SoA) | 14 per slot across 5 columns | queue high water | 0 | already a MultiArrayList. |
| `scheduler.Future` | 24 | future events | 0 | `order: u64` is the FIFO sequence; narrowing changes the overflow limit. Pinned. |
| `scheduler.Event` | 24 | one per dispatch (value) | 0 | returned by value, not stored. |
| `Run.terms` | 8 per slot | 524288 slots | 0 (2 MB possible) | a `?*ArrayList(Term)` per slot; a `u32` index into a list table would save 4 B per slot but adds a dependent load to every `wake`. Not done. |
| `Run.values` | 24 + planes per slot | 524288 | 0 | frozen by outside readers (proposal 3). |
| `Run.fan_start` / `net_of` / `watch` | 4 / 4 / 1 per slot | 524288 | 0 | already dense columns. |
| `Run.scope_info` row | 32 | 65536 (generate limit) | 0 | `index: ?i64` read by the VPI (proposal 4). |
| `digital.Sub` | 144 | per task/function per instance | 0 | cold; counts small. |
| `digital.Array` / `Span` / `VecRange` | 56 / 24 / 16 | per array / declared vector | 0 | elaboration-time metadata in hash maps. |
| `exec.Act` | 48 | timed-task activations | 0 | rare. |
| `rt.State` | 67560 | 1 | 0 | one per run; 64 KiB is its stdout buffer. Its layout is hashed into `engine.tag`. |
| `rt.Sense` | 16 | per (slot, node) read | 0 | pinned. |
| `rt.net.Net` / `Driver` | 80 / 72 | resolved nets of a native design | 0 | emitted as constants; shape is part of the generated text (goldens). |
| `rt.net.Nets` | 464 | 1 | 0 | already SoA columns. |
| `vcd.Var` / `vcd.Vcd` | 48 / 192 | dumped variables / 1 | 0 | `head`/`tail` strings per variable; dump-time only. |

Measurements (ReleaseFast `vera`, fresh binary copies, best of 9 interleaved,
before = 28ed476d (the split, byte-identical code), after = this change):

| fixture | time before -> after | peak RSS before -> after |
|---|---|---|
| b_11_zero_delay_loop_rejected | 1.65 s -> 1.65 s | 3.4 -> 2.9 MB |
| b_12_generate_past_65536_iterations_rejected | 0.26 s -> 0.27 s | 17.3 -> 16.8 MB |
| b_5_2_2_scalar_element_part_select_rejected | 0.07 s -> 0.06 s | 79.3 -> 63.4 MB |
| b_18_1_5_dumplimit_stops_with_comment | 0.01 s -> 0.01 s | 4.0 -> 3.5 MB |
| b_18_3_4_dumpportslimit_stops_with_comment | 0.01 s -> 0.01 s | 4.0 -> 3.7 MB |
| suite `devices` (996 cases), best of 5, two rounds | 1850, 1848 -> 1715, 1835 ms | |
| suite `ieee1364` (976 cases), best of 5, two rounds | 1853, 1923 -> 1758, 1751 ms | |

Small-run RSS moves by up to 0.9 MB with the page-cache state of the binary
alone (`vera --help`: 1360 vs 1816 KB for two binaries, 1300 vs 1304 KB for
fresh copies of the same two), so only the part-select row is a signal.
