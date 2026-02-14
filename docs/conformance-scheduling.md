# Scheduling and analog-host evidence worklist

Source review, 2026-09-23: VAMS Chapter 8, physical PDF pages 213–230,
read against the HTML. Figures 8-1 through 8-7 and convergence equations were
checked visually. This is a source review and partial requirement mapping,
not a certified atomic rule denominator. Full AMS includes the mixed-signal/digital host obligations;
the Annex C analog profile does not excuse those from the full-AMS inventory.

## Source fidelity

Figures 8-1 and 8-2 now use direct PDF crops. The former HTML phase list lost
the nesting of parameter evaluation/generate expansion inside hierarchical
instantiation. The latter SVG lacked the horizontal connection from the
convergence decision to its nonconvergence return path. Both redraws were
replaced, not used as normative substitutes. Figures 8-3 through 8-7 have also
been replaced by visually checked direct source crops. These preserve the
nonblocking inverter assignment, timing guides, physical versus reported event
times, and all numbered handoffs of the sample run. Added descriptions are
explicitly editorial; the original captions remain visible in the crops.

The two convergence inequalities on physical page 217 match the HTML's
indices, iteration superscripts, absolute-value bars, strict inequalities,
relative terms and absolute tolerances. Text extraction alone obscured some
bars/symbols and cannot establish that correspondence. This visual check does
not establish that the fixture host implements the criteria.

## Requirement groups and evidence limits

| ID | Source | Requirement / present evidence |
|---|---|---|
| SCH-001 | 8.1 / p213 | Full mixed-signal simulation needs both the specified analog and digital engines. Separate successful engine unit tests do not establish their integration. |
| SCH-002 | 8.1 / p213 | Connected continuous nodes form jointly solved analog macro-processes. `shared_conservative_node.va` observes two instances sharing one solved node; arbitrary networks, separated macro-processes and cross-domain interaction remain open. |
| SCH-003 | 8.2 / pp213–214 | Elaboration evaluates parameter declarations and expands module-level generate constructs during hierarchical instantiation. `elaboration_parameter_sweep.va` observes derived parameter values, not generated topology changes. |
| SCH-004 | 8.2 / p213 | Variable declaration assignments precede analog initial blocks. `declaration_assignment_order.va` reads the initialized variable from analog initial; `analog_initial_order.va` checks analog initialization before ordinary analog evaluation. |
| SCH-005 | 8.2 / p213 | Analog net assignments/nodesets follow analog initial in this initialization description. Evidence for the complete ordering remains open. §8.4.1's mixed-signal description places nodesets first; resolve the contexts before asserting one universal order. Preserve both source passages. |
| SCH-006 | 8.2 / p214 | Parametric sweep points re-evaluate elaboration and pre-simulation so changed parameters are captured. The two parameter-sweep fixtures observe derived parameters and analog initial respectively; they now require their full expected observation totals. Generate topology, variable declaration initializers and nodeset changes remain separate cases. |
| SCH-007 | 8.3.1 / p215 | Static and dynamic contributions form the nodal equations. `audit_coupled_nodal_solution.va` solves two free nodes with independently derived static solutions and reversed branch orientation. Existing `static_nodal.va`/`multi_branch_kfl.va` assertions calculate expressions at pinned voltages; they do not themselves observe assembled residual rows. |
| SCH-008 | 8.3.1 / p215 | Initial conditions and dynamic terms participate in the differential-algebraic system. `dynamic_nodal.va` checks the DC-zero derivative; it cannot prove transient integration, initial-state restoration or charge-history handling. |
| SCH-009 | 8.3.1 / p215 | Pure signal-flow nodes eliminate unnecessary flow unknowns, whose flows are zero by definition. Binding/access fixtures alone do not establish elimination or zero-flow behavior. Dedicated observations remain open. |
| SCH-010 | 8.3.2 / p215 | Transient integration discretizes time and controls intervals for accuracy while solving nonlinear equations. The testbench's declared time grid supplies cases, not adaptive-timepoint selection evidence. No particular numerical integration method should be required where the source permits alternatives. |
| SCH-011 | 8.3.3 / pp216–217 | Model evaluation iterates from approximate, potentially unreasonable values. Robust-model discussion does not license arbitrary incorrect final solutions or impose an invented finite value on every out-of-domain expression. Separate model-author guidance from simulator obligations. |
| SCH-012 | 8.3.3 / p217 | Both solution-change and flow-residual criteria must be satisfied. Boundary cases for both inequalities and rejection of false convergence remain open. `tb.zig`'s solver checks step size and device convergence; that alone is not independent evidence for both published criteria. |
| SCH-013 | 8.3.3 / p217 | Tolerances must reflect the signal quantity and negligible scale; the typical numerical examples are not universal required defaults. Nature/default/override metadata and host use need linked evidence. |
| SCH-014 | 8.3.3 and 4.5.13 | `nonlinear_safe.va` observes limexp's final exponential value at a prescribed voltage. It does not force limiting iterations or establish refusal to accept a limited intermediate value. A plain exponential implementation could satisfy those assertions. |
| SCH-015 | 8.4.1–8.4.2 | Mixed-signal initialization and steady-state solution require cross-engine coordination. Independent analog and digital initialization checks do not demonstrate the specified sequence or coupled operating point. The nodeset ordering scope in SCH-005 remains open. |
| SCH-016 | 8.4.3.1–8.4.3.2 | Analog provisional solutions are not communicated before acceptance. Wake-up events, earlier disturbing events, cancellation of obsolete wake-ups, acceptance and recomputation need observable host traces. Evaluating a device at prescribed times does not establish these transitions. |
| SCH-017 | 8.4.3.2 | Guarded digital reads do not create implicit sensitivity; unguarded reads do. Permitted joint evaluation of analog processes prevents an oracle from simply forbidding every extra evaluation. Test the externally observable value and event contract. |
| SCH-018 | 8.4.3.3 | Reported digital times may be rounded while a zero-delay A2D/D2A path retains the physical analog event time. Separate assertions must observe both time representations and the returning analog change. Figures 8-4/8-5 are source examples, not executed tests. |
| SCH-019 | 8.4.4 | Conservative synchronization must not invalidate already communicated values or move global time backward. Cancellation of speculative future work is distinct from deleting ordinary queued nonblocking assignments; see the discrepancy below. |
| SCH-020 | 8.4.5 | The sample-run handoffs distinguish digital progress, analog solution look-ahead and interrupted acceptance. Kernel unit tests alone do not demonstrate the illustrated cross-engine protocol. |
| SCH-021 | 8.4.6–8.4.7 | Interpolated analog events must remain associated with the solution that generated them; unconsumed events invalidated by an intervening D2A event are rejected. Need interruption-before-consumption and consumption/commit cases, not just event counts on an uninterrupted grid. |
| SCH-022 | 8.5 / 8.5.1 | Explicit D2A events and analog macro-process events augment digital scheduling. Implicit D2A changes directly cause macro-process events. Queue-region unit coverage is not production integration evidence. |
| SCH-023 | 8.5.1–8.5.2 | Region ordering, zero-delay suspension, NBA updates, monitors and time advance require behavioral traces. Published region descriptions and pseudocode disagree about inactive versus explicit D2A priority; preserve the discrepancy and record any implementation interpretation. |
| SCH-024 | 8.5.3.1–8.5.3.4; IEEE 1364-2005 9.2.2 | Continuous/procedural continuous assignments, blocking assignments and NBAs have distinct sensitivity, value-sampling and target-selection times. Each requires separate runtime cases, including changes to an indexed target while an update is pending. |
| SCH-025 | 8.5.3.5; IEEE 1364-2005 11.6.5 | Bidirectional switch-connected networks require joint resolution, including uncertain gate states. IEEE supplies the missing final x value in the AMS paragraph. Primitive acceptance alone cannot close this rule. |
| SCH-026 | 8.5.3.6 | Explicitly sensitive analog statements observe digital values after the active region, rather than delayed sampling at the analog macro-process region. A discriminating trace must change the value between those regions. |
| SCH-027 | 8.5.3.7 | A macro-process solve consumes all active requests for that same process. Need duplicate-request coalescing and distinct-process separation evidence through the production host, not merely queue unit tests. |
| SCH-028 | IEEE 1364-2005 11.6.1 / AMS 8.5.3.1 | Inherited continuous assignments are evaluated at time zero, including constant and implicit assignments. The AMS paragraph's shorter description is not evidence excluding this initialization rule. Independent constant-net and implicit-port observations remain to be reviewed. |
| SCH-029 | IEEE 1364-2005 11.6.6 | Port directions imply specified continuous or bidirectional connections; primitive terminals have distinct direct-connection and strength-preservation rules. This obligation is inherited even though AMS Chapter 8 does not repeat a corresponding subsection. Hierarchy acceptance alone is insufficient. |
| SCH-030 | IEEE 1364-2005 11.6.7 | Task/function arguments copy in on invocation and out on return, with copy-out behaving like a blocking assignment. Separate invocation/return observations and aliasing cases remain to be reviewed against the declaration rules. |

Fixture names above are under `tests/fixtures/ch08_scheduling` unless stated
otherwise. The historical directory coverage inventory contains useful leads
but stale counts and references to removed documents; no closure is inherited
from a “green” label or a source-form rejection.

## Coupled-node oracle and controlled fault

The new solved circuit imposes p=5 and n=0, with unit conductances on p–a,
a–b, b–n and n–a. KFL gives `3a-b=5` and `2b-a=0`, so the expected voltages
are a=2 and b=1. Neither free node is assigned by a bias directive. The two
observations and their count are fixed independently of emitted device code.
The targeted strict fixture run exits 0.

In a temporary copy, removing only the n–a contribution changes the equations
to `2a-b=5`, `2b-a=0`. Direct execution produced a=3.33333 and b=1.66667,
with both `ok=0` verdicts as predicted. Its process still exits 0, demonstrating
why the assertion transcript, not process exit alone, is the behavioral oracle.
This is a source-circuit mutation checking the discriminator; it is not a
compiler implementation mutation and does not prove every stamping fault is
caught. The repository fixture retains all four contributions.
Running the strict suite on that isolated temporary fixture also exits 1 and
reports both failed assertions, confirming that the runner consumes the oracle.

## Digital NBA evidence, 2026-09-23

The inherited §9.2.2 extracted text (printed pages 118–122) has now been read
in full, including its syntax and examples, alongside AMS §8.5.3.4. Syntax 9-2
was also checked on rendered physical page 149, distinguishing optional/repeated
grammar notation from literal delimiters and the bold keyword terminals.
The following are rule groups,
not a complete atomic denominator; no entire clause is marked verified.

| ID | Obligation | Executed evidence / remaining gap |
|---|---|---|
| NBA-001 | Queueing an NBA does not suspend the procedural flow or immediately deposit its value. | `audit_nba_pending_updates.v` observes the old value after queueing and later deliveries. Exact transcript passes. Existing `d04_07_intra_assignment_delay_nonblocking.v` also separates immediate continuation and later RHS delivery. |
| NBA-002 | An NBA captures its right-hand value when evaluated. | The existing delayed-RHS fixture changes the source before delivery and passes in the digital suite. This is whole-variable evidence, not all value types or widths. |
| NBA-003 | Evaluated left-hand targets are captured with the RHS. | `audit_nba_index_snapshot.v` changes both the bit index and RHS after queueing. It is valid source but currently fails E1100: only whole-variable lvalues are implemented. Expected behavior is retained, not replaced by a rejection expectation. |
| NBA-004 | Additional queued assignments do not erase earlier pending assignments. | `audit_nba_pending_updates.v` observes all three distinct-time updates to one variable and passes. This does not establish all same-time update visibility. |
| NBA-005 | Defined execution order of assignments determines their resulting update order, including ordered scheduling from different processes. | `audit_nba_same_time_updates.v` passes: posedge flags show intermediate updates occurred, and settled values show the subsequent updates occurred. It covers same-process source order and different-process scheduling at distinct times. It does not constrain the arbitrary interleaving of active callbacks or enumerate every event-control form. |
| NBA-006 | Concurrent unordered assignments may leave the final value indeterminate. | Do not require a chosen active-process order. Need an allowed-outcomes oracle and tests that avoid mistaking nondeterminism for failure; not closed by these deterministic fixtures. |
| NBA-007 | Context distinguishes relational <= from assignment <=; grammar permits specified timing controls and variable targets. | Full grammar alternatives, event/repeat controls, lvalue forms and isolated invalid-input diagnostics remain unmapped here. Legal unsupported forms must not count as negative conformance evidence. |

New files reside in `tests/fixtures/digital`, with hand-derived
`.expected.txt` transcripts. The digital runner checks both successful process
exit and exact stdout, not a success substring. The passing fixture's expected
sequence is derived from deliveries at times 2, 4 and 6, with observations at
times 3, 5 and 7. The failing fixture would distinguish a late target (bit 2
instead of bit 0), late RHS (zero instead of one), or premature write. It fails
before those observations today, so it supplies **no runtime evidence** for
target capture.

Full digital runs before and after this addition both exit 1. Comparing sorted,
nonempty FAIL name lists adds exactly `audit_nba_index_snapshot`; every previous
failure name is retained. The new queued-update fixture passes its direct run
with the expected transcript. No compiler or executor behavior was changed.
The bit-select refusal is tracked as **NBA-TARGET-001**, rooted in
`src/sim/digital.zig`'s whole-variable/array-element target restriction. Do not
generalize the diagnostic into a language prohibition.

## Source discrepancies and oracle policy

### STROBE-ORDER-001: withdrawn fixture claim

Reading IEEE §§11.3–11.4.2 and §17.1.2 established that end-of-time-step
sampling is required, but the fixture's claimed FIFO ordering of separate
same-time strobe callbacks is not guaranteed by those clauses. Source-order
execution of calls is not a guarantee of callback execution order: unlike NBA
updates, monitor callbacks have no equivalent explicit source-order rule here.
The former `s1`/`s2` transcript therefore overconstrained the conformance oracle.

`d09_03_strobe_scheduling.v` now uses identical `repeat` labels for its two
same-time calls. Either callback ordering produces the same expected transcript,
while a dropped call still loses a line and early sampling still gives the
wrong value. The expected settled values and required observation multiplicity
are unchanged. This withdrawn FIFO claim is owned by this row, not silently
moved to another supposed coverage case. The historical `CLAUSE-AUDIT.md`
17.1-10 entry has been corrected to describe only the retained evidence; its
historical status is not promoted or used as a new B measurement.

The header's assertion that `#0` exposes a settled NBA was also incorrect:
inactive events precede NBA updates under IEEE §11.3. Its explanatory reference
has been corrected without changing the fixture's actual source timing.
The term `monitor` now follows the inherited standard rather than importing a
different standard's `postponed` terminology.

### Same-time update discriminator

In `audit_nba_same_time_updates.v`, q starts at zero, receives ordered updates
to one and then zero at time 2, and is observed at time 3. An independently
armed posedge waiter records the first transition without reading q's possibly
already-restored value. Thus `(q=0, seen=1)` distinguishes both updates from
dropping the first, dropping the second or reversing them. The second case
queues r=1 at time 1 for time 5 and r=0 at time 2 for time 5, then observes
`(r=0, crossed=1)` at time 6. Scheduling order comes from different times, not
an assumed order among concurrent initial blocks. Initialization precedes
waiter registration and registration precedes both delivery times.

Both the new fixture and revised strobe transcript pass direct execution and
the digital suite. Its before/after nonempty FAIL name lists are identical.
This is source-level production execution evidence, not just a scheduler unit
test. It does not prove mixed-signal region integration or every NBA target.
The fresh analog strict run also retains the preceding nonempty FAIL/XFAIL
name list exactly. These digital transcript cases are outside its population;
no A/C increase is claimed from their addition or corrected expectations.

### Remaining source issues

- **Region priority:** §8.5.1 puts explicit D2A before inactive events;
  §8.5.2's pseudocode does the reverse and omits a closing brace. The HTML
  preserves both and labels the discrepancy. The scheduler's existing choice
  of D2A-first follows the region descriptions, but is an interpretation, not
  evidence that the source is internally consistent. A definitive resolution
  still needs an authoritative clarification.
- **Cancellation:** §8.4.4's glitch example describes canceling a prior queued
  assignment. IEEE 1364-2005 §9.2.2, printed pages 121–122, preserves ordered
  queued NBA updates and explicitly illustrates repeated assignments without
  canceling earlier ones. Do not create a general NBA-cancellation expectation
  from the AMS example. Driver look-ahead and transition-filter behavior must
  be isolated from assignment execution; the example's reconciliation remains
  open, not silently treated as an inherited-language override.
- **Switch uncertainty:** the final sentence of AMS §8.5.3.5 omits its value.
  IEEE 1364-2005 §11.6.5, printed pages 161–162, supplies `x`. Preserve the AMS
  transcription and record the inherited requirement rather than concealing
  a source repair.
- **Legacy PLI:** §8.5.1's `tf_synchronize` reference depends on deprecated PLI
  material removed from IEEE 1364-2005 and referred back to the 2001 edition.
  Possessing the 2005 PDF does not close that source dependency; see
  [the IEEE source inventory](conformance-ieee1364.md).

These are source-review findings, not newly verified runtime obligations.
The production integration gaps described in AGENTS.md remain material:
mixed-signal scheduler regions have no production posting callers, and the
generated fixture testbench uses declared timepoints rather than an adaptive
cross-engine coordinator. Neither a direct PDF image nor a cited fixture can
stand in for the missing execution evidence.

## Scope of this progress

This adds a discriminating static-solution case to A and strengthens sweep
observation completeness. C still counts citations rather than these rules.
B's historical IEEE §§17–18 tally and architecture measure D are unchanged.
Source reproduction is separate from all four implementation measures.

After the sweep observation-count edits, a fresh full strict run exits 1 with
an unchanged, nonempty normalized FAIL/XFAIL name list relative to the macro
checkpoint. The targeted sweep run passes. The measurement report is generated
by `tools/conformance.sh`, not by the rule-group table above.
