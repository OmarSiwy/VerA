# Verilog-AMS conformance status

Target: **full Verilog-AMS 2023**, including digital simulation and VPI.
**Not yet fully conformant.** Passing tests is not a conformance percentage.

## Done

These are implemented pieces; the remaining work below still applies.

- Limiter/Newton hooks, convergence vetoes and rollback, including direct/JFNK integration.
- Wide four-state values, nested expression typing, arithmetic/power, shifts, reductions, casts and concatenation/replication.
- Digital initial and always processes, assignments/NBA, integral delays, if/case/loops, binary display and finish.
- Explicit `@` event control: value, `posedge`/`negedge` and `or` terms, resuming from the active or NBA region.
- Exact integral defaults and supported dependent parameters; runtime multidimensional element access and string ranges.
- Supported numeric `%s`, exact literal escapes and correct NUL conversion into string storage.
- Linear/closest-point tables and first-call mutable-array snapshots.
- Reference distributions without the 4096-count substitution; guarded runtime errors and host overrides.
- Discipline precedence, event queues, timescale conversion, isolated HDL builds and stable CPU error statuses.

## Remaining

| Area | Work still needed |
|---|---|
| Digital execution | Implicit sensitivity (`@*`), named events, remaining control forms, intra-assignment controls, tasks/functions, net delays, gates, switches, UDPs and timing checks. |
| Digital values and hierarchy | Remaining expression forms/conversions, bit/part selects, multidimensional arrays, ports and elaboration. Nets now carry state, independent drivers and §7.9 wired-logic resolution, so what stays missing here is the STRENGTH model: the eight §7.10 levels, strength reduction and the §7.11 resolution table. §10.1's IEEE 1364 directive carry-overs are no longer accepted-and-ignored — `default_nettype` reaches implicit-net creation, `celldefine` tags modules, `unconnected_drive` drives unconnected inputs — but §19.10's pull is stated in strengths, so it lands as a value until that model exists. |
| Mixed-signal simulation | Connect processes to the scheduler and analog solver; implement synchronization, time conversion, discipline resolution and connectmodule insertion. |
| VPI | Values (`vpi_get_value`/`vpi_put_value`, §12.10's analog family), callbacks, system task/function registration, analog derivatives and accepted-point notifications. The OBJECT MODEL and its handle/traversal/property routines now exist in `src/vpi/`: §11.6 module/port/net/reg/parameter over an elaborated design, and §12.2–§12.35's `vpi_handle`, `vpi_handle_by_name`, `vpi_handle_by_index`, `vpi_iterate`, `vpi_scan`, `vpi_get`, `vpi_get_str`, `vpi_compare_objects`, `vpi_free_object`, `vpi_release_handle`, `vpi_chk_error`, entered through §12.33.2's `vlog_startup_routines` and exercised by a compiled C application (`zig build test-vpi`). Nodes, branches, expressions and bit-level objects are not modelled, so `vpi_handle_by_index` answers nothing yet. |
| Analog operators | Remaining table modes and runtime file loading, tabulated noise from a file or an array parameter (the constant-vector form of §4.6.4.3/.4 exports as `noise_tables`), complete delay/timer histories, and stateful-operator validation. |
| Analog language | Branch/current equations, topology aliases, net initialization, paramset content, held state and event-controlled `disable`. |
| Parameters and arrays | Final host/sweep range checks, complete conversions and constant-function derivation, array slices, invalid-index behavior and output/inout writeback. |
| Runtime facilities | Distribution limits, host queries, remaining formatting/file I/O, identifier identity, and side effects across rejected trials. |
| Qualification | Complete the inherited-Verilog clause audit, add missing behavioral tests, and resolve compiler/host regression failures. |

## Verified so far

- VerA build, **375 unit tests** and **1,313/1,313 strict fixtures pass**.
- Scheduler/time/source execution: **44 tests**, plus four CLI transcripts, pass in Debug/ReleaseFast. General digital execution remains incomplete.
- An edge-triggered D flip-flop with a clock generator simulates through `vera --run`, with correct NBA sampling.
- Host build and **295 unit tests pass**; full circuit suite: **494/616 pass, 122 fail**. Six focused JFNK circuits also pass.

**Native-device migration is not done:** LTRA/TXL/CPL still use Zig. Five of
eleven checked waveform comparisons remain failing; AC and history limitations
also remain. Approximate Verilog-A replacements do not satisfy the migration.

The **1,301/1,301** figure above is `zig build torture -- --strict`; `zig build
test` does not run the fixture suite (`build.zig:462-468`). 452 of those 1301
fixtures assert a *refusal*. The [clause audit](CLAUSE-AUDIT.md) reconciles the
chapter `COVERAGE.md` files against the source, expands the inherited IEEE 1364
§§17–18 obligations, and lists where this file and those files overstate what is
implemented.

See the [detailed implementation backlog](../../ARPice/docs/verilog-ams-conformance-plan.md),
[transmission-line audit](../../ARPice/docs/native-transmission-line-migration.md),
the [clause audit](CLAUSE-AUDIT.md),
chapter `COVERAGE.md` files and the
[Verilog-AMS standard](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf)
for scope, evidence and acceptance criteria.
