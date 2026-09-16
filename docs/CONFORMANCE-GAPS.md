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
| Digital execution | Implicit sensitivity (`@*`), named events, remaining control forms, intra-assignment controls, tasks/functions, continuous assignments, gates, switches, UDPs and timing checks. |
| Digital values and hierarchy | Remaining expression forms/conversions, nets/drivers/strength resolution, memories, ports, elaboration and directive semantics. |
| Mixed-signal simulation | Connect processes to the scheduler and analog solver; implement synchronization, time conversion, discipline resolution and connectmodule insertion. |
| VPI | Standard C API, object handles/traversal, values, callbacks, analog derivatives and accepted-point notifications. |
| Analog operators | Remaining table modes and runtime file loading, tabulated noise, complete delay/timer histories, and stateful-operator validation. |
| Analog language | Branch/current equations, topology aliases, net initialization, paramset content, held state and event-controlled `disable`. |
| Parameters and arrays | Final host/sweep range checks, complete conversions and constant-function derivation, array slices, invalid-index behavior and output/inout writeback. |
| Runtime facilities | Distribution limits, host queries, remaining formatting/file I/O, identifier identity, and side effects across rejected trials. |
| Qualification | Complete the inherited-Verilog clause audit, add missing behavioral tests, and resolve compiler/host regression failures. |

## Verified so far

- VerA build, **370 unit tests** and **1,301/1,301 strict fixtures pass**.
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
