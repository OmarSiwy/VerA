# Digital event scheduler core

`src/sim/scheduler.zig`, exported by the `sim` build module, implements event
queue infrastructure. `zig build test-sim` runs its independent trace and
allocation-failure tests. The shared-frontend [source runner](digital-source-execution.md)
now connects initial processes, assignments, integral delays and finish to this
queue. General digital execution and analog integration still leave D05 open.

## Standards and interpretation

The scheduling basis is [Verilog-AMS 2023 §8.5](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf)
and inherited [IEEE 1364-2005 §11](https://ieeexplore.ieee.org/document/1620780).
The current-time priority is active, explicit D2A, inactive, NBA, analog
macro-process, then monitor. Future events form the seventh logical region,
with inactive and NBA categories. Promotion moves an entire region into active.
Feedback creates additional work at the same time before monitors or advancement.
Analog requests for the same macro-process that are already active are consumed
together, following §8.5.3.7. A later request can cause another solve.

There is an unresolved conflict in VAMS-2023: §8.5.1 requires explicit D2A before
inactive, and §8.5.3.6 places it after active processing, while §8.5.2's pseudocode
checks inactive first. This implementation follows the explicit region
requirements. The D2A-before-inactive trace pins that interpretation pending
standards clarification; it does not claim the text is internally consistent.

FIFO is this implementation's choice where active ordering is unspecified.
It also preserves the required NBA order (IEEE §11.4.1). The trace tests do not
assert that every conforming simulator must choose this order for racing work.
No SystemVerilog-only scheduling regions are included.

## Ownership and dispatch

The caller supplies an allocator and owns the scheduler until `deinit`. Event
payloads are u32 indices into caller-owned execution records, not callbacks or
owned HDL values. Pending slots use separate columns for links, payloads,
regions, generations, and lifetime state. Cancelled entries keep their slots
until their FIFO or heap entries are removed; generation-checked handles cannot
cancel a replacement event. Generation exhaustion permanently retires a slot.
There are at most `maxInt(u32)` slots, with a reserved index sentinel.

`schedule` posts work at `now`; `scheduleAt` and `scheduleAfter` take the two
future categories. At zero delay they post inactive or NBA work at the current
time. Time is an unsigned 64-bit integer tick count at the design's finest
precision. Past scheduling, delay overflow, and exhausted future sequence
numbers return errors instead of wrapping. Cancelled future minima are removed
before choosing a new time, including when all remaining work is cancelled.

`next` finishes the preceding dispatch and returns one event. Its region field
records where the event originated; removal is always from active. The caller
must execute that event before calling `next` again. During a monitor dispatch,
scheduling and cancellation return `MonitorMutation`; another `next` completes
that read-only interval. This is an API contract for the future driver, not a
sandbox against a caller that prematurely calls `next`.

An empty queue returns null while retaining the current time; a coordinator may
subsequently supply external work. `finish` is terminal and suppresses further
dispatches and scheduling. `deinit` releases retained storage. Neither operation
invents analog `final_step` processing or other language-level finalization.

## Integration still required

The first source runner implements statement order, whole-variable blocking/NBA
updates, suspension and resumption, and integral delay scaling for one portless
module. Remaining work includes general elaborated processes, real delays,
sensitivities, named events, net resolution and complete four-state expressions.
Cancellation still needs language-level ownership for
process disable, delayed assignments, and event replacement. Persistent monitor
registrations and their per-time-step enabling, PLI/VPI callbacks, stop/finish
system tasks beyond the runner's finish subset, and complete
initialization/finalization remain open.

The mixed-signal coordinator must map explicit and implicit D2A dependencies to
analog requests, evaluate the analog event-controlled statements and solver,
and publish A2D notifications as ordinary active events. Accepted/rejected
analog solutions, synchronization/look-ahead, and rollback remain governed by
§§8.4–8.5 and are not simulated by this queue. Analog payload identity must name
a macro-process so duplicate active requests refer to the same solve.

The analog duplicate scan is linear in the active wave; a per-macro index can
replace it if measurements warrant that complexity. Event causality is serial;
this change adds no SIMD kernel or performance claim.
