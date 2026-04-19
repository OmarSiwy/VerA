# Chapter 8 coverage

The [source-led scheduling worklist](../../../docs/conformance-scheduling.md)
records the current partial review, figure repairs and solved-node oracle.
Counts and execution claims below are historical, not fresh measurements;
references to removed documents do not supply current evidence.

Full-AMS status: the digital and mixed-signal rows below are open requirements.
Historical analog-subset exclusions and passing unsupported-feature rejection
fixtures do not close them. See `docs/CONFORMANCE-GAPS.md` and the cross-repository
implementation plan for the execution work and required evidence.

Source: `docs/ch8-scheduling.html`, read section by section.

HTML section-ID audit: `s8-1` `s8-2` `s8-3` `s8-3-1` `s8-3-2` `s8-3-3` `s8-4` `s8-4-1` `s8-4-2` `s8-4-3` `s8-4-3-1` `s8-4-3-2` `s8-4-3-3` `s8-4-4` `s8-4-5` `s8-4-6` `s8-4-7` `s8-5` `s8-5-1` `s8-5-2` `s8-5-3` `s8-5-3-1` `s8-5-3-2` `s8-5-3-3` `s8-5-3-4` `s8-5-3-5` `s8-5-3-6` `s8-5-3-7`.

In the historical `.va` inventory, eight of the twenty-eight sections carry a fixture that asserts something. The
other twenty do not, and the table says so with an empty column rather than a
plausible name. Two thirds of this chapter — 8.4's mixed-signal cycle and all of
8.5's digital engine — requires digital process execution and mixed-signal integration, which remain open. Ten `//! reject`
fixtures inventory those source forms, and they pin the diagnostic and nothing else: the
queue regions, delays and boundary rounding that are the actual content of those clauses
are never reached by those rejection fixtures.

Additional execution evidence: `zig build test-sim` passes 39 tests: fourteen
scheduler tests, nine time-conversion tests and sixteen source-runner tests.
`zig build test-digital` checks the actual CLI scheduling transcript in
`tests/ieee1364/11_scheduling/scheduling.v`. Initial processes now exercise captured NBA values,
lexical NBA order, inactive-region resumption, integral delays and finish.
General processes and analog synchronization remain open; see the
[source scope](../../../docs/digital-source-execution.md) and
[scheduler contract](../../../docs/simulator-scheduler.md).
The core follows the D2A-before-inactive order in §§8.5.1 and 8.5.3.6;
§8.5.2 reverses those two regions in its pseudocode. This interpretation remains
subject to standards clarification and does not close D05.

WHAT THOSE TEN PIN HAS CHANGED, and the header of each says so. They used to rest on Annex
C.7 ("No digital behavior or events are supported in Verilog-A") and C.10 ("The
mixed-signal simulation cycle from 8.2 is only applicable to Verilog-AMS HDL"). Annex C
states the Verilog-A SUBSET; VerA targets Verilog-AMS, so a verdict resting on it was
demanding a diagnostic a conforming AMS compiler must not emit. `reg` and a constant
`initial` block are accepted now, `analog_digital_initial_order.va` has been re-verdicted
into a positive fixture, and the procedural/timing files that pinned E0209 are withdrawn:
`blocking_timing_unsupported.va` to ch07 m01_11 (its timed `initial` runs on the
mixed-signal kernel), and `procedural_{assign,deassign,force,release,continuous}_unsupported.va`
to the two positive §8.5.3.2 fixtures below, since the discrete context now parses the
four procedural continuous statements (2026-09-24).
An `always` block stays E0205 for a reason that is not dialect: it re-runs on an event, so
its value is a function of §8.5's simulation cycle. None of the ten is credited below as
coverage of the clause its construct belongs to.

27 `.va` files: 1 carries a `//! reject` arm, 25 run and assert, and 1 is `//! xfail`
(grep-measured over this directory, 2026-09-24).

| HTML id | Rule | Fixtures |
|---|---|---|
| `s8-1` | analog macro-process = nodes solved together, read as one branch | `analog_macro_process.va` (`//! lrm 8.1`) |
| `s8-2` | elaboration, declaration assignments, then `analog initial`, then the cycle | `declaration_assignment_order.va` (decl-assign before `analog initial`), `analog_initial_order.va` (`analog initial` before the ordinary block), `elaboration_parameter_sweep.va` (derived parameter re-elaborated per sweep sub-task), `analog_initial_parameter_sweep.va` (green: the block re-executes per sub-task, off its own `Instance.is_analog_initial` flag rather than `initial_step`) |
| `s8-3` | iterative solve of the nodal equations | parent summary; carried entirely by 8.3.1–8.3.3 below |
| `s8-3-1` | `f(v,t) = dq/dt + i(v,t) = 0`, KFL row per node | `static_nodal.va` (static half), `dynamic_nodal.va` (dynamic half), `multi_branch_kfl.va` (three branches, rows sum to zero), `multiple_analog_blocks.va` (two blocks summed into one row), `integrator_state.va` |
| `s8-3-2` | time derivative replaced by a finite difference over discrete points | `transient_derivative.va` (`//! analysis tran`, four points, constant history); `dynamic_nodal.va` pins only the dc corner where 4.5.3 zeroes `ddt` |
| `s8-3-3` | models must behave under unreasonable iterate values | `nonlinear_safe.va` (`limexp` equals `exp` at the reported solution) |
| `s8-4` | mixed-signal cycle | — open full-AMS integration requirement |
| `s8-4-1` | circuit initialization, analog and digital | partly. `analog_digital_initial_order.va` (was `_unsupported`, was a `//! reject` inventory) is green and asserts acceptance of both forms: the §5.2.1 `analog initial` and the A.6.2 digital `initial` are both accepted in one module and the analog block reads 1.0 + 1. Their relative order is unobserved; this fixture does not establish the mixed-signal initialization algorithm. §5.2.1 separately forbids digital-value access from `analog initial` (`ch05_analog_behavior/analog_initial_digital_access_rejected.va`, E0431) |
| `s8-4-2` | iterated analog DC + time-0 digital to A/D steady state | — open full-AMS integration requirement |
| `s8-4-3` | mixed-signal transient | the clause's first sentence, "Analog processes that share conservative nodes are 'solved' jointly", is `shared_conservative_node.va` (`//! lrm 8.4.3`): two instances, one node, two contributions whose sum fixes it at 1.25 with each contribution asserted separately. The rest of the sentence is either the implementation's choice ("single matrix, multiple matrices or uses other techniques") or the node-tolerance rule, which no expression reports. The clause as a *mixed-signal transient* remains an open full-AMS integration requirement |
| `s8-4-3-1` | concurrency without shared-memory reordering | `multiple_analog_blocks.va` (`//! lrm 8.4.3.1`): the earlier block's write is visible to the later one |
| `s8-4-3-2` | early self-wakeup by timer; sensitivity limited by event guards | `timer_wakeup.va` (`//! lrm 8.4.3.2`, `//! analysis tran`, fires at `start_time` and only there), `explicit_guard.va` (`//! lrm 8.4.3.2`, guarded probe does not leak) |
| `s8-4-3-3` | A/D time quantization and the zero-delay round trip | ch07 `m02_04_a2d_tick_quantization.va` (green): a 5.2 ns crossing rounds to tick 5 and a 7.6 ns one to tick 8, while the analog kernel keeps 5.2 ns to 1 ps; `m02_05` (green): the zero-delay D2A returns at 5.2 ns, not at the tick (Figure 8-4); `m02_06` (green): a `#1` lands on 6.0 ns exactly. `digital_boundary_unsupported.va` (E0437) is withdrawn to m02_04 |
| `s8-4-4` | synchronization loop, wake-up scheduling, event cancellation | — open host integration; scheduler cancellation tests alone do not establish synchronization |
| `s8-4-5` | synchronization and communication algorithm | — open host integration requirement |
| `s8-4-6` | `absdelta()` interpolated A2D events | ch07 `m02_13_absdelta_interpolated_a2d.va` (green): on a 0/4/8/11/12 ns grid the events at 2.5, 5, 7.5 and 10 ns are interpolated, not snapped, and each samples 0.25 V more; ch07 `m01_10` (green) is the delta = 0 and delta = 0.3 samplers. The two-way half is `ch05_analog_behavior/absdelta_digital_only.va` (E0513, now the 5.10.3.4 placement rule by name). Open: an A2D interpolated before the step's end whose D2A needs the analog at that earlier time is re-solved at the step's end, not rolled back (8.4.6 case a) |
| `s8-4-7` | digital granularity, analog solution accept/reject | — open host integration requirement |
| `s8-5` | digital engine scheduling semantics | partial: scheduler tests plus the initial-process CLI transcript. `digital_process_unsupported.va` is withdrawn — an `always` process in a compiled module runs on the mixed-signal kernel (`src/sim/mixed.zig`; ch07 m02_10) |
| `s8-5-1` | the seven stratified event-queue regions | partial: `test-sim` checks region traces and future promotion; see the ordering interpretation above |
| `s8-5-2` | digital reference-model loop | partial: queue tests and source initial-process execution check re-entry, cancellation, time advance and termination; general processes and mixed-signal integration remain open |
| `s8-5-3` | scheduling implication of assignments | — lead-in sentence, "Assignments are translated into processes and events as follows"; every rule it announces is in 8.5.3.1–8.5.3.7 below |
| `s8-5-3-1` | continuous assignment lands in the active region | — `digital_assignment_unsupported.va` refuses the `assign` module item |
| `s8-5-3-2` | procedural continuous assign/deassign/force/release | the two sentences of the clause are `procedural_continuous_semantics.va` (`//! lrm 8.5.3.2`, green): the force is a process sensitive to its source, and the release deactivates it; its literals separate a compiler whose release works from one whose release does nothing. `procedural_assign_deassign_semantics.va` (green) is the assign/deassign half: the assign follows its source over a procedural write, and the deassign leaves the value in place. The five `procedural_*_unsupported.va` E0209 pins are withdrawn to these two. The invalid-input half is `annex_a_syntax/30_force_in_analog_rejected.va` (E0209: no procedural continuous assignment in an analog block) |
| `s8-5-3-3` | blocking assignment delay and event control timing | the clause's first sentence, "computes the right-hand side value using the current values", is `blocking_assignment_delay.va` (`//! lrm 8.5.3.3`, green): `y = #5 x;` followed by `x = 2;` leaves y at 1, so a compiler that samples the right-hand side at resume time reads 2 and fails it. Also partial: source tests execute blocking assignments and statement delays. Intra-assignment delays and event controls remain open |
| `s8-5-3-4` | nonblocking update region | partial: queue and source tests check NBA order, captured RHS values and inactive-before-NBA behavior. the region-3-before-3b rule is ch07 `m02_10_macro_process_runs_after_nba.va` (green; `nonblocking_unsupported.va` is withdrawn to it) |
| `s8-5-3-5` | bidirectional switch processing | `switch_network_resolved_as_a_whole.va`: two `tran`s on discrete wires, one listed against its terminal order, and the analog block reads the driven value on both far nodes. A switch on a discrete net makes the module mixed, and the kernel resolves the switch-connected net as a whole (`src/sim/digital/exec.zig` `resolveJoined`). `switch_primitive_accepted.va` is the other case: a `tran` between two ELECTRICAL nets — legal only with a `` `default_discipline `` naming its discrete side (§3.9, else E0960) and a connect statement — has no discrete half to run on and is warned about (W0250, "stamps nothing") |
| `s8-5-3-6` | explicit D2A events, region 1b | ch07 `m02_09_explicit_d2a_reads_post_active.va` (green): the guarded statement reads `da + db` = 7, the values after region 1, not the 13 region 3b sees after `da <= 9`; `src/sim/mixed.zig` pins the same ordering against a fake analog. `m02_03_guarded_d2a_holds.va` (green) is the §8.4.3.2 half: a read only under `@(posedge clk)` does not re-latch on a bus change |
| `s8-5-3-7` | analog macro-process events, region 3b | partial: `test-sim` checks analog queue placement and duplicate pending-event suppression; no analog solver integration. `analog_macro_process.va` covers only the 8.1 definition |

## The xfail ledger

Empty. §8.5.3.2's `procedural_continuous_semantics.va` was the last entry: it
carried `//! xfail` while the parser had no statement production for `force`
(E0209), and `procedural_release_unsupported.va` pinned that refusal beside it.
It is green since the discrete context parses the procedural continuous
statements, and the pin is withdrawn to it. `blocking_assignment_delay.va`
(§8.5.3.3) was the other; it is green since its `y` stopped being x while the
analog block reads it (§7.3.2; see its header).

The rest of this ledger is the record. `switch_primitive_*.va` used to
sit here and does not any more: A.4.1's `pass_switchtype` parses, and a `tran`
instance is accepted with a W0250 saying it contributes nothing to the device —
A switch on discrete nets now runs on the mixed kernel
(`switch_network_resolved_as_a_whole.va`); W0250 is left for a module with no
discrete half. `above_initial_event.va`
used to sit here for §5.10.3.2 and does not any more: `above()` is edge-
triggered now, and the clause's initialisation case is the `__prev = 0.0` the
history field starts at. `analog_initial_parameter_sweep.va` used to sit here for
§5.2.1's "shall be re-executed" and does not any more: the `analog initial` guard
is its own predicate, set on the first evaluation of every sub-task, where
`initial_step` is Table 5-1's first point of the whole analysis.

## Fixtures in this folder that cite Chapter 5, not Chapter 8

Four run fixtures live here because the analog cycle is what wakes on them, but
their `//! lrm` cites are event-function clauses and their content is the
event-function rule. They are counted against Chapter 5, not against any row
above:

- `analog_event.va` (`5.10.3.1`) — `cross()` is silent in dc.
- `cross_wakeup.va` (`5.10.3.1`) — same, with explicit `time_tol`/`expr_tol`; the timestep control it names is a transient service and is not exercised at a dc operating point.
- `event_state.va` (`5.10.2`, `5.10.1`) — `initial_step` carries an or-list at the dc point.
- `above_initial_event.va` (`5.10.3.2`) — `above()` fires at the initial condition preceding a transient and the latch then holds.

`ch05_analog_behavior/` already holds `ch05_analog_behavior/event_cross.va`,
`ch05_analog_behavior/event_timer.va`, `ch05_analog_behavior/event_above.va`,
`ch05_analog_behavior/event_or.va` and their siblings, so these four are the
scheduling-flavoured duplicates, not the primary coverage of those clauses.

## Remaining full-AMS integration

Sections 8.4.4–8.4.7 and 8.5 require the mixed-signal and digital engines. They
are implementation debts against the full Verilog-AMS target, even though the
analog-subset runner cannot execute them. The one row that was
a debt disguised as a boundary is `s8-4-3-3`: A/D boundary timing is AMS-only by
C.10, but `digital_boundary_unsupported.va` (withdrawn; see s8-4-3-3) was previously credited with covering
it, which it never did.


## 2026-09-24 — rejections for 8.5.1 and 8.5.3.x, and CLAUSES.tsv

| Clause | Fixture | Verdict |
|---|---|---|
| 8.5.1, 7.3.5 | `a2d_event_on_a_probe_rejected.va` | new E0484: "A2D events must be analog event controlled statements" — `@(posedge (V(in) > 2.5))` in an `always` (was accepted) |
| 8.5.3.1, A.6.1 | `continuous_assignment_to_a_variable_rejected.va` | E0438: `assign` to a `reg` |
| 8.5.3.2, A.6.2 | `procedural_assign_to_a_net_rejected.va` | new E0482: procedural `assign` to a `wire` (was accepted) |
| 8.5.3.3, A.6.2 | `blocking_assignment_to_a_net_rejected.va` | E0482: delayed blocking write to a `wire` (was accepted in a mixed module; E0313 "unknown variable" in a constant one) |
| 8.5.3, 8.5.3.4, A.6.2 | `nonblocking_assignment_to_a_net_rejected.va` | E0482: nonblocking write to a `wire` (was accepted) |
| 8.5.3.5, A.3.3 | `switch_terminal_is_a_variable_rejected.va` | new E0483: `tran` terminal is a `reg` (was accepted) |

Parent cites added where a fixture here already asserts the parent's content:
§8.3 on `transient_derivative.va`, §8.4 on `analog_digital_initial_order.va`,
§8.5.3 on `blocking_assignment_delay.va`. The simulator-obligation clauses are
classified, with their sentences and positive fixtures, in `CLAUSES.tsv`.
