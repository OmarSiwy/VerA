# Chapter 5 coverage

Source: `docs/VAMS-LRM/ch5-analog.html`, read in full through Section 5.11.
111 `.va` fixtures, of which 31 are `//! reject` and 20 are `//! xfail`.

HTML section-ID audit: `s5.2` `s5-2-1` `s5-4-3`. Three IDs for fifty-seven
printed sections — this chapter is a layout-preserving extraction and its
headings are text, not anchors — so the audit below is over the printed
numbering, recovered from the body text: 5.1; 5.2; 5.2.1; 5.3; 5.3.1; 5.3.2;
5.4; 5.4.1; 5.4.2; 5.4.2.1; 5.4.2.2; 5.4.3; 5.4.4; 5.5; 5.5.1; 5.5.2; 5.5.3;
5.5.4; 5.5.5; 5.6; 5.6.1; 5.6.1.1; 5.6.1.2; 5.6.1.3; 5.6.2; 5.6.2.1; 5.6.3;
5.6.4; 5.6.5; 5.6.6; 5.6.7; 5.6.7.1; 5.6.7.2; 5.6.8; 5.6.8.1; 5.6.8.2; 5.7;
5.8; 5.8.1; 5.8.2; 5.8.3; 5.8.4; 5.9; 5.9.1; 5.9.2; 5.9.3; 5.10; 5.10.1;
5.10.2; 5.10.3; 5.10.3.1; 5.10.3.2; 5.10.3.3; 5.10.3.4; 5.10.4; 5.10.5; 5.11.
Forty-five have a fixture, twelve do not.

Every row below is a `//! lrm` cite grepped out of the fixtures themselves, not
a judgement about what a fixture is "really" testing. A file that discusses a
clause in its header but does not cite it is not credited here.

| LRM section | Fixtures / disposition |
|---|---|
| 5.1 Overview | — no fixture; the clause is a table of contents for the chapter and states no rule |
| 5.2 Analog procedural block | `analog_block.va` (sequential execution), `multiple_analog_blocks.va` (concatenation order, jointly with §6.2) |
| 5.2.1 Analog initial block | positive: `analog_initial.va`, `analog_initial_real.va`, `analog_initial_integer.va`. The four restrictions: `analog_initial_contribution.va` (E0405), `analog_initial_access_rejected.va` (E0421), `analog_initial_operator_rejected.va` (E0422), `analog_initial_event_rejected.va` (E0702). `analog_initial_digital_access_rejected.va` **xfail** — VerA has no digital-owned values: `reg` is refused at E0205 (unsupported module item) long before §5.2.1's analog-initial read is reached |
| 5.3 Block statements | — no fixture cites the parent; its one sentence (statements execute in order) is what 5.3.1 asserts |
| 5.3.1 Sequential blocks | `sequential_block.va`, `nested_sequential_blocks.va` |
| 5.3.2 Block names | `named_block_locals.va` (block-local parameter); `named_block_scope_rejected.va` (E0314 — the bare name, not the lifetime; §6.8 searches upward only) |
| 5.4 Analog signals | — no fixture cites the parent; it is an introduction pointing at Clause 6 |
| 5.4.1 Access functions | `access_one_node.va`, `access_two_nodes.va`, `named_branch_probe.va`, `single_terminal_branch.va`, `direct_flow.va`, `direct_potential.va`, `flow_source.va`, `potential_probe.va`, `conductor.va`, `derivative_contribution.va`, `controlled_sources.va`, `controlled_voltage_source.va`, `implicit_zero_contribution.va`, `unassigned_switch_arm.va`. `two_named_branches.va` **xfail** — VerA collapses two named branches over one net pair into a single unnamed branch with one shared flow unknown, so `I(a)` and `I(b)` both read 0 instead of their own contributed values |
| 5.4.2 Probes and sources | `flow_probe.va`, `controlled_sources.va`, `current_controlled_current.va`, `current_controlled_voltage.va` |
| 5.4.2.1 Probes | `probe_both_quantities_invalid.va` **xfail** — VerA does not classify an unnamed branch as a probe, so it never notices that both quantities of one were read; the module compiles |
| 5.4.2.2 Sources | `source_probe_both.va`, `constant_current_source.va`, `two_named_branches.va` (**xfail**, above) |
| 5.4.3 Accessing flow through a port | `port_flow_probe.va` (legal `I(<p>)`); `port_potential_invalid.va` (E0507, `V(<p>)`); `port_flow_contribution_invalid.va` (E0407, `I(<p>)` on the left of `<+`) |
| 5.4.4 Unassigned sources | `unassigned_switch_arm.va`, `retained_conditional_contribution.va`, `implicit_zero_contribution.va` — all three pin the observable half only: which arm ran and what the branch potential is. None reads the implied zero flow, and each says so in its own header |
| 5.5 Accessing net and branch signals and attributes | — no fixture cites the parent; one sentence of introduction |
| 5.5.1 Accessing net and branch signals | `generic_access.va` — green: Syntax 5-3's `potential`/`flow` are parsed as the access functions they are and lowering maps them onto the same `Access` as `V`/`I`, so the file exercises the generic spelling on both sides of `<+`. The one exemption they get is §3.6.1.4's NAME match; a natureless or half-bound discipline still refuses them (E0501) |
| 5.5.2 Signal access for vector branches | `vector_access.va` — the clause's own DAC8 example, eight literal bit selects weighted 1/2 … 1/256 |
| 5.5.3 Accessing attributes | `nature_attribute_unsupported.va` — green: Syntax 5-4 parses, and `a.potential.abstol` resolves through the net's discipline (so §3.6.2.3's tolerance override is what it reads). `nature_attribute_nonconstant_invalid.va` is the negative half and pins the clause's own ban on `.access` at E0359, not a parse boundary |
| 5.5.4 Creating unnamed branches using hierarchical net references | `hierarchical_access_unsupported.va` **xfail** — VerA's parser has no hierarchical net reference: the `.` in `V(drv.a)` dies at E0207 (expected `)`), and the instantiation the path resolves through is refused at E0204 anyway |
| 5.5.5 Accessing nets and branch signals hierarchically | — **no fixture.** The clause's own rules (a hierarchical read of a *named* branch; the two error conditions — branch absent in the instance, wrong access function for it; `V(top.drv.branch(a,b))` for an existing unnamed branch; the hierarchical port branch) are uncovered. §5.5.4's fixture borrows this clause's *shape* to stay resolvable in one file, but cites 5.5.4 and tests unnamed-branch creation, not these rules |
| 5.6 Contribution statements | — no fixture cites the parent |
| 5.6.1 Direct branch contribution statements | — no fixture cites the parent. Syntax 5-5's own restriction (a conditionally executed contribution may not contain an analog filter) is cited from §5.8.1 by `conditional_filter_invalid.va` |
| 5.6.1.1 Relations | `potential_probe.va`, `single_terminal_branch.va` |
| 5.6.1.2 Evaluation | `potential_source.va`, `rlc.va` |
| 5.6.1.3 Value retention | `value_retention.va` **xfail** — the clause's own Example 2, answer 7.0, and the only fixture in the tree that carries the numeric rule. The retention ARITHMETIC is now implemented (`lower.zig discardOpposite`: a contribution of the opposite kind zeroes the other accumulator, and a zeroed accumulator emits no row, so the device carries one potential source of 0+3+4 and no flow source — 8.0 and the stray 2.0 are both gone). What is left is the READ: `V(p,n)` is the node difference (§5.4.1), which needs a converged solution, and `tb.zig` writes the operating point into `x[]` without a Newton loop |
| 5.6.2 Examples | `constant_current_source.va` |
| 5.6.2.1 The four controlled sources | `voltage_controlled_current.va` cites the clause. The other three of the four are written against §5.4.1/§5.4.2 instead: `controlled_voltage_source.va`, `current_controlled_voltage.va`, `current_controlled_current.va`, and `controlled_sources.va` (all four off one sensed branch) |
| 5.6.3 Resistor and conductor | `resistor.va`, `conductor.va` |
| 5.6.4 RLC circuits | `rlc.va` (three contributions into one branch, read at the dc operating point where §4.5.3/§4.5.4 fix the reactive terms at zero) |
| 5.6.5 Switch branches | `switch_branch.va`, `unassigned_switch_arm.va`, `retained_conditional_contribution.va`, `implicit_zero_contribution.va` |
| 5.6.6 Implicit Contributions | `implicit_fixed_point.va` (`I(b)` on both sides; the operating point is placed on the fixed point so the right-hand side must return it) |
| 5.6.7 Indirect branch contribution statements | `indirect_equation_lhs_invalid.va` (E0414, a variable left of `==`); `conditional_indirect_invalid.va` (E0412, indirect under a non-constant guard). `indirect_contribution.va` **xfail** — VerA's generated testbench forces every unknown to its declared operating point instead of solving, so an indirect contribution's target cannot move: `V(p,n)` reads 0 |
| 5.6.7.1 Multiple indirect contributions | `multiple_indirect.va` **xfail** — same root cause: the testbench forces every unknown to its declared operating point instead of solving, so `V(x)`, `V(y)` and `V(z)` all read 0. The fixture is a nonsingular 3×3 system with the pairings rotated, which is what the clause is about |
| 5.6.7.2 Indirect and direct contribution | `indirect_and_direct.va` (E0409) |
| 5.6.8 Contributing hierarchically | — heading only in the LRM; no body text and no fixture |
| 5.6.8.1 Contributions to branches between hierarchical nets | `hierarchical_contribution_unsupported.va` **xfail** — VerA's parser has no hierarchical net reference: the `.` in `V(drv.x) <+ 1.8` dies at E0207 (expected `)`), and the instantiation the path resolves through is refused at E0204 anyway |
| 5.6.8.2 Hierarchical direct contributions to branches | — **no fixture.** Contribution to a hierarchical *named* branch (`V(top.drv.br_v)`), to an existing hierarchical unnamed branch (`V(top.drv.branch(x,y))`), the two "not allowed" reasons (invalid access function; the contribution turns the branch into a switch branch), the solvability check, and the ban on contributing hierarchically to an indirectly-assigned branch are all uncovered |
| 5.7 Analog procedural assignments | `procedural_assignments.va` (positive); `assignment_concatenation_invalid.va` (E0317); `assignment_hierarchical_invalid.va` (E0316, quoting the clause's hierarchical-assignment sentence); `assignment_array_mismatch_invalid.va` (E0429 — `A = B` copies element-wise and `A = C` is refused, which is the clause's own worked pair) |
| 5.8 Analog conditional statements | — no fixture cites the parent; it is a two-bullet list of the kinds and states no rule |
| 5.8.1 if-else-if statement | `if_else.va` (first match wins); `conditional_filter_invalid.va` (E0514 — an analog operator under a guard that is not an `analysis_or_constant_expression`) |
| 5.8.2 Examples | `conditional_no_else.va`, `conditional_contribution.va`, and the dangling-else pair `dangling_else.va` / `dangling_else_begin_end.va` — the clause's own example run twice, with mirrored answers, so a compiler with either binding hard-wired fails exactly one |
| 5.8.3 Case statement | `case_statement.va` (order of comparison, comma-separated labels), `case_default_only.va`. `case_duplicate_default_invalid.va` **xfail** — VerA does not check for a duplicate `default` arm; the case statement compiles and the second default is silently unreachable |
| 5.8.4 Restrictions on conditional statements | `conditional_contribution.va` (contributions ARE allowed); `conditional_event_control_invalid.va` (E0707 — an event under a non-constant guard, stricter than §5.8.1's rule for operators) |
| 5.9 Looping statements | the three blanket restrictions on runtime loops: `loop_filter_invalid.va` (E0514), `loop_event_control_invalid.va` (E0707), and `loop_contribution_invalid.va` **xfail** — VerA allows a contribution inside a runtime `for`/`while`/`repeat`; it unrolls nothing and stamps the branch once per iteration, warning only W0650 |
| 5.9.1 Repeat and while statements | `repeat_loop.va`, `repeat_single.va`, `while_loop.va`, `while_false.va`, and `repeat_count_evaluated_once.va` — the count is a variable the body decrements, which is the only way "evaluated once" parts company with "re-evaluated each pass" |
| 5.9.2 For statements | `for_loop.va`, `for_zero_iterations.va`; the loop host for `jump_break.va` and `jump_continue.va` |
| 5.9.3 Analog For Statements | `jump_in_analog_for_invalid.va` (E0404). `analog_genvar_loop.va` — the clause's own genvarexp example: the genvar indexes `V(dt[k])` and the loop is unrolled at elaboration |
| 5.10 Analog event control statements | the restrictions on statements inside an event control block: `event_contribution_rejected.va` and `event_block_contribution_invalid.va` (E0406, reached through a monitored and a global event respectively so neither can be masked), `nested_event_control_invalid.va` (E0703) |
| 5.10.1 Event OR operator | `event_or.va` (timer or-ed with a cross that cannot fire, so the or-list is distinguishable from a conjunction), `event_initial_or_cross.va` |
| 5.10.2 Global events | `initial_step.va`, `final_step.va` (with §8.4.7), `initial_final_analysis_lists.va`, `event_initial_or_cross.va`, and `initial_step_unknown_analysis.va` — four rows of Table 5-1 read off the Sweep column, the only column where "first point" and "last point" are distinct places |
| 5.10.3 Monitored events | — no fixture cites the parent; two sentences of introduction, with the rules in the four children |
| 5.10.3.1 cross function | positive: `event_cross_fires.va` (the event must fire and something must change), `event_cross.va`, `event_cross_any.va`, `event_cross_falling.va`, `event_cross_enable.va`, `event_or.va`, `event_initial_or_cross.va`. Three argument rules are **xfail**: `cross_dir_noninteger_invalid.va` — VerA does not type-check `cross()`'s `dir` argument; a real literal in the direction slot compiles. `cross_tolerance_negative_invalid.va` — VerA does not range-check `cross()`'s `time_tol`/`expr_tol`; a negative tolerance compiles. `event_null_argument_invalid.va` — VerA does not check that a tolerance is accompanied by a direction: `cross(expr, , 1n)` compiles with the `dir` slot elided |
| 5.10.3.2 above function | `event_above_enable.va`, `event_above_tolerance.va`, `event_above.va` (one upward crossing of zero across a three-point dc sweep is one event, not one per positive point) |
| 5.10.3.3 timer function | `event_timer.va` (start_time and period, as a partition of the run on `$abstime`), `event_timer_one_shot.va` (`period <= 0` fires once, at start_time), `event_timer_enable.va`, `event_or.va` |
| 5.10.3.4 absdelta function | `absdelta_digital_only.va` — rejecting `absdelta()` in an `analog` block is conformance, not a limitation. The clause's other constraints (non-negative delta and tolerances, integer enable) need a legal call site and have none here |
| 5.10.4 Named events | `named_event_unsupported.va` — the name is now historical: `event tick;`, `@(initial_step) -> tick;` and `@(tick)` all work. An event is a per-timepoint flag, not retained state, so a detection that lexically PRECEDES its trigger still reads 0 — no fixture yet (it needs a scheduler queue) |
| 5.10.5 Digital events in analog behavior | — **no fixture.** Analog behavior sensitive to `posedge`/`negedge`, state-change and named digital events is entirely uncovered; VerA is a Verilog-A compiler with no digital-owned values, so there is nothing for such a fixture to be written against yet |
| 5.11 Jump statements | positive: `jump_break.va`, `jump_continue.va` (both inside a §5.9.2 `for`, both passing). Negative: `jump_outside_loop_invalid.va` and `jump_in_analog_for_invalid.va`, both E0404 — VerA counts only runtime loops as loops, so the analog_for case reaches the right verdict with the wrong wording |

## The debt ledger

Twenty fixtures carry `//! xfail`. They split into two kinds, and the split is
the interesting part.

**Eight state a rule the compiler does not enforce** — they are `//! reject`
fixtures that compile anyway, so each one is a missing diagnostic:
`probe_both_quantities_invalid.va` (both quantities of a probe branch),
`case_duplicate_default_invalid.va` (two `default` arms),
`cross_dir_noninteger_invalid.va`, `cross_tolerance_negative_invalid.va` and
`event_null_argument_invalid.va` (the three `cross()` argument rules),
`loop_contribution_invalid.va` (contribution in a runtime loop) and
`analog_initial_digital_access_rejected.va` (which is refused, but for the
wrong reason and too early). Of these, only the last is a *reachability*
problem; the others are checks that could be written today.

**The rest get the wrong answer, or cannot be reached at all.** Three are parser
boundaries — `hierarchical_access_unsupported.va` and
`hierarchical_contribution_unsupported.va` at the `.` in a hierarchical net
reference (the dot PARSES now; what is missing is the instance tree it resolves
in, E0901). `named_event_unsupported.va` was the third and is now green. The rest
are semantic:
`two_named_branches.va` (two named branches over one net pair are collapsed
into one), and `value_retention.va` / `indirect_contribution.va` /
`multiple_indirect.va`, which now share one root cause: the generated testbench
forces every unknown to its declared operating point instead of solving, so no
indirect target can move and no retained POTENTIAL reaches the nodes it is
imposed on. (§5.6.1.3's arithmetic itself is implemented; a retained FLOW needs
no solve, because a flow source's branch flow has no node-derived value and
§5.6.1.2's accumulator IS the answer — which is what closed
`ch01_intro/{04,07}`.)

That last group is the one entry here that is a *harness* limitation rather than
a compiler one, and it is worth keeping separate: all three files describe
systems with unique exact solutions in dyadic rationals, so the day the testbench
solves instead of forcing, they turn green without being touched.

## Where a fixture is credited, and where it is not

Three clauses print the same equivalence — §5.4.4, §5.6.1.3 Example 1 and
§5.6.5's switch branch — and `unassigned_switch_arm.va`,
`retained_conditional_contribution.va` and `implicit_zero_contribution.va` all
illustrate it. None of them observes the implied zero flow; nothing inside a
module can, and each header says so in a SCOPE paragraph. They are credited
under §5.4.4 and §5.6.5 for what they do assert (which arm ran, and the branch
potential), and §5.6.1.3's numeric rule is `value_retention.va` alone.

Four of the twelve uncovered sections (5.1, 5.4, 5.5, 5.6) are pure
introductions, 5.6.8 is a bare heading with no body, and 5.3, 5.8 and 5.10.3
state only what their children restate normatively. That leaves three real
holes: **5.5.5** (hierarchical access to named and existing unnamed branches,
and its two error conditions), **5.6.8.2** (hierarchical contribution to named
and unnamed branches, and the conditions under which it is disallowed) and
**5.10.5** (digital events in analog behavior). All three sit behind the same
two unimplemented features — hierarchical references and digital values — and
no fixture in this directory is written against them.
