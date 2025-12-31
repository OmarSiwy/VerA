# Chapter 8 coverage

Source: `docs/VAMS-LRM/ch8-scheduling.html`, read section by section.

HTML section-ID audit: `s8-1` `s8-2` `s8-3` `s8-3-1` `s8-3-2` `s8-3-3` `s8-4` `s8-4-1` `s8-4-2` `s8-4-3` `s8-4-3-1` `s8-4-3-2` `s8-4-3-3` `s8-4-4` `s8-4-5` `s8-4-6` `s8-4-7` `s8-5` `s8-5-1` `s8-5-2` `s8-5-3` `s8-5-3-1` `s8-5-3-2` `s8-5-3-3` `s8-5-3-4` `s8-5-3-5` `s8-5-3-6` `s8-5-3-7`.

Eight of the twenty-eight sections carry a fixture that asserts something. The
other twenty do not, and the table says so with an empty column rather than a
plausible name. Two thirds of this chapter — 8.4's mixed-signal cycle and all of
8.5's digital engine — is put outside Verilog-A by Annex C.10 ("The mixed-signal
simulation cycle from 8.2 is only applicable to Verilog-AMS HDL") and C.7 ("No
digital behavior or events are supported in Verilog-A"). Eleven `//! reject`
fixtures inventory those source forms. They pin the diagnostic and nothing else:
VerA refuses the `always`/`initial`/`assign` module item before reading its body,
so the queue regions, delays and boundary rounding that are the actual content of
those clauses are never reached. A reject fixture is not coverage of the clause
its construct belongs to, and it is not credited as such below.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s8-1` | analog macro-process = nodes solved together, read as one branch | `analog_macro_process.va` (`//! lrm 8.1`) |
| `s8-2` | elaboration, declaration assignments, then `analog initial`, then the cycle | `declaration_assignment_order.va` (decl-assign before `analog initial`), `analog_initial_order.va` (`analog initial` before the ordinary block), `elaboration_parameter_sweep.va` (derived parameter re-elaborated per sweep sub-task), `analog_initial_parameter_sweep.va` — **`//! xfail`** |
| `s8-3` | iterative solve of the nodal equations | parent summary; carried entirely by 8.3.1–8.3.3 below |
| `s8-3-1` | `f(v,t) = dq/dt + i(v,t) = 0`, KFL row per node | `static_nodal.va` (static half), `dynamic_nodal.va` (dynamic half), `multi_branch_kfl.va` (three branches, rows sum to zero), `multiple_analog_blocks.va` (two blocks summed into one row), `integrator_state.va` |
| `s8-3-2` | time derivative replaced by a finite difference over discrete points | `transient_derivative.va` (`//! analysis tran`, four points, constant history); `dynamic_nodal.va` pins only the dc corner where 4.5.3 zeroes `ddt` |
| `s8-3-3` | models must behave under unreasonable iterate values | `nonlinear_safe.va` (`limexp` equals `exp` at the reported solution) |
| `s8-4` | mixed-signal cycle | — AMS only (Annex C.10) |
| `s8-4-1` | circuit initialization, analog and digital | — `analog_digital_initial_order_unsupported.va` is a `//! reject` source inventory; the digital `initial` item is refused, so no relative order is observed |
| `s8-4-2` | iterated analog DC + time-0 digital to A/D steady state | — AMS only |
| `s8-4-3` | mixed-signal transient | — AMS only |
| `s8-4-3-1` | concurrency without shared-memory reordering | `multiple_analog_blocks.va` (`//! lrm 8.4.3.1`): the earlier block's write is visible to the later one |
| `s8-4-3-2` | early self-wakeup by timer; sensitivity limited by event guards | `timer_wakeup.va` (`//! lrm 8.4.3.2`, `//! analysis tran`, fires at `start_time` and only there), `explicit_guard.va` (`//! lrm 8.4.3.2`, guarded probe does not leak) |
| `s8-4-3-3` | A/D time quantization and the zero-delay round trip | — `digital_boundary_unsupported.va` says in its own header that it pins nothing here: the `always` item is refused before the `cross()` threshold or the rounding is read |
| `s8-4-4` | synchronization loop, wake-up scheduling, event cancellation | — host/kernel property; no generated device code |
| `s8-4-5` | synchronization and communication algorithm | — host/kernel property |
| `s8-4-6` | `absdelta()` interpolated A2D events | — no fixture here. 5.10.3.4 allows `absdelta()` only in an `initial`/`always` block, which C.7 excludes; the rejection lives in `ch05_analog_behavior/absdelta_digital_only.va` |
| `s8-4-7` | digital granularity, analog solution accept/reject | — host/kernel contract |
| `s8-5` | digital engine scheduling semantics | — Verilog-A has no digital engine (C.7); `digital_process_unsupported.va` records the source form |
| `s8-5-1` | the seven stratified event-queue regions | — |
| `s8-5-2` | digital reference-model loop | — |
| `s8-5-3` | scheduling implication of assignments | — |
| `s8-5-3-1` | continuous assignment lands in the active region | — `digital_assignment_unsupported.va` refuses the `assign` module item |
| `s8-5-3-2` | procedural continuous assign/deassign/force/release | — `procedural_assign_unsupported.va`, `procedural_deassign_unsupported.va`, `procedural_force_unsupported.va`, `procedural_release_unsupported.va`, `procedural_continuous_unsupported.va`; all masked at the `reg`/`initial`/`always` module item |
| `s8-5-3-3` | blocking assignment delay and event control timing | — `blocking_timing_unsupported.va`; the three timing forms are inside a refused `initial` block |
| `s8-5-3-4` | nonblocking update region | — `nonblocking_unsupported.va`; refused at `always` |
| `s8-5-3-5` | bidirectional switch processing | — `switch_primitive_unsupported.va` is **`//! xfail`** for a *Clause 6* instantiation gap, not for this clause; switch processing is digital-cycle and stays out of scope even once instantiation lands |
| `s8-5-3-6` | explicit D2A events, region 1b | — |
| `s8-5-3-7` | analog macro-process events, region 3b | — queue placement is a host property; `analog_macro_process.va` covers only the 8.1 definition |

## The xfail ledger

Three fixtures in this folder run and fail. Each names a concrete defect with a
file, so the row disappears the day the defect does.

| Fixture | Section it would serve | Reason |
|---|---|---|
| `analog_initial_parameter_sweep.va` | `s8-2` (with 5.2.1) | `src/ir/lower.zig` lowers `analog initial` as its body guarded on a synthetic `initial_step`, so the block never re-executes per dc-sweep sub-task. 5.2.1 says it *shall* re-execute when a parameter it reads changes. VerA answers `seeded = 10` at the first sub-task and then **0** — the declaration default, not a stale value — because module variables are re-initialised from their declarations each evaluation and nothing re-seeds them. |
| `above_initial_event.va` | none in this chapter (`//! lrm 5.10.3.2`) | `src/backend/codegen.zig` lowers `above()` as a stateless level test (`if (expr.val() > 0.0)`), so it re-fires at every solution instead of only on an upward zero crossing. The latch tracks `V(p)` down to 0.25 at t = 1 ns where a conformant tool holds 0.75. |
| `switch_primitive_unsupported.va` | none (`//! lrm A.4.1`, `C.8`) | VerA rejects gate/switch primitive instantiation with E0205 — it is a flat single-module compiler with no instance or primitive instantiation at all. A.4.1 admits `tran`, so a conforming Verilog-A compiler accepts the source; the earlier `//! reject E0205` form of this file had the polarity inverted. |

## Fixtures in this folder that cite Chapter 5, not Chapter 8

Four run fixtures live here because the analog cycle is what wakes on them, but
their `//! lrm` cites are event-function clauses and their content is the
event-function rule. They are counted against Chapter 5, not against any row
above:

- `analog_event.va` (`5.10.3.1`) — `cross()` is silent in dc.
- `cross_wakeup.va` (`5.10.3.1`) — same, with explicit `time_tol`/`expr_tol`; the timestep control it names is a transient service and is not exercised at a dc operating point.
- `event_state.va` (`5.10.2`, `5.10.1`) — `initial_step` carries an or-list at the dc point.
- `above_initial_event.va` (`5.10.3.2`) — see the ledger.

`ch05_analog_behavior/` already holds `ch05_analog_behavior/event_cross.va`,
`ch05_analog_behavior/event_timer.va`, `ch05_analog_behavior/event_above.va`,
`ch05_analog_behavior/event_or.va` and their siblings, so these four are the
scheduling-flavoured duplicates, not the primary coverage of those clauses.

## What a mixed-signal-capable tool would add

Nothing in 8.4.4–8.4.7 or 8.5 is reachable from Verilog-A source, so these are
not debts against VerA — they are the shape of the language boundary. The rows
stay empty until this compiler is a Verilog-AMS compiler. The one row that *is*
a debt disguised as a boundary is `s8-4-3-3`: A/D boundary timing is AMS-only by
C.10, but `digital_boundary_unsupported.va` was previously credited with covering
it, which it never did.
