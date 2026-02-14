# Real-net source and evidence worklist

Review date: 2026-09-23. Complete AMS §3.7 text and example (physical page
57) read against the HTML. Syntax 3-8 was visually checked on that page;
literal semicolons now have explicit markup, distinct from optional range
and discipline notation. This is not a completed real-net behavioral audit.

| ID | Source | Obligation / evidence boundary |
|---|---|---|
| WR-001 | 3.7 | Undriven wreal values and initial values are zero, not four-state z. `digital/m04_01_wreal_undriven_zero.v` compares an undriven real net with an undriven wire at time zero and later. Its initial process is not literally an observation before any process runs; driven initialization needs separate scheduling analysis. |
| WR-002 | 3.7 | A wreal is a single-driver real-valued connection, not storage. `digital/m04_02_wreal_single_driver_tracks.v` changes the driving variable and another operand in its expression, then samples later. Its six-digit output is fractional-propagation evidence, not a precision proof. |
| WR-003 | 3.7 | Compatible wire/tri/wreal interconnect resolves as wreal across ports. `digital/m04_05_wreal_wire_port_resolves_wreal.v` observes fractional wire/tri values, a further connected sink and an undriven promoted net. Reversed hierarchy/directions, bus ranges and all resolution combinations remain open. |
| WR-004 | 3.7 | Other net-type connections are errors. `digital/m04_21_reject_wreal_connected_to_wand.v` requests a net-type diagnostic; its old comments about missing diagnostics require fresh verification. One wand case is not the whole prohibited-type set. |
| WR-005 | 3.7 | Real expressions may connect, with explicit bit-conversion tasks for 64-bit wires. Port connection, exact bit round-trips, declaration assignments and range forms require independent mapping and execution. |
| WR-006 | 3.7; inherited event semantics | Changes and unchanged assignments must interact correctly with digital event controls. `digital/m04_03_wreal_event_on_change.v` is a mapping lead, not yet fully audited here; its signed-zero expectation requires inherited-source verification, and a real-event test does not prove mixed-signal synchronization. |
| WR-007 | C.4 | Verilog-A excludes wreal; full Verilog-AMS includes it. `annex_c_analog_subset/08_wreal_rejected.va` is profile-specific negative evidence, not a positive implementation of §3.7. Its §3.7 citation must not inflate a full-AMS coverage claim. |

## Precision overclaim withdrawn

The single-driver fixture said default `%g` output of 1/3 distinguishes full
double precision from float. It does not: both commonly round to `0.333333`
at six significant digits. That header claim is corrected without changing
source behavior or its historical transcript label. Full inherited real-type
precision requires a value or operation whose reduced-precision outcome differs
at the asserted observation, with an independently derived oracle.

## Initialization and source scope still open

The undriven fixture also samples a declaration-driven wreal in an immediate
initial block. Its expected initialized driver value must be checked against
inherited time-zero scheduling; this read alone does not establish that all
permitted orderings yield the same immediate sample. Do not credit that line
as proof of a pre-process initial value. The no-driver observations are a
separate rule and should remain independently tested.

Existing fixture headers cite the older 2.4 edition. The obligations mapped
above are checked against the supplied VAMS-2023 §3.7; that does not certify
every incidental historical assertion in those headers. Numeric expectations,
negative diagnostics and full current transcripts still need focused review.
