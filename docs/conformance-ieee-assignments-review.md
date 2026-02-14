# Inherited IEEE assignments source and evidence audit

2026-09-23. Full IEEE1364-2005 Clause6, Assignments, printed68–73
(physical98–103), and its procedural-continuous dependency §9.3–9.3.2,
printed122–125 (physical152–155), read against supplied licensed PDF SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Visual checks: physical98 Table6-1,99 Syntax6-1,103 Syntax6-2,153 Syntax9-3.
This bounded audit does not newly audit all Clause7 delay/strength resolution,
§9.2 blocking/nonblocking scheduling, or sizing/casting dependencies.

Clause6 explicitly distinguishes continuous net driving, procedural variable
writes, and procedural-continuous assign/deassign/force/release governed by9.3.
Their common spelling does not justify substituting one kind's restrictions
or execution behavior for another. No analog contribution claim follows from
these digital tests.

## New measured evidence

All files below are in tests/fixtures/digital. Run current root executable
with --run from the fixture directory. Normative expected transcripts remain
unchanged when unsupported syntax or wrong values are observed. Digital
transcripts do not support XFAIL inversion.

| ID / fixture stem | Normative oracle | Current observed result |
|---|---|---|
| ASSIGN-VECTOR-001 / audit_assignment_vector_delay | §6.1.3: whole-vector01→10 uses rising2, nonzero→zero falling7, all-z turnoff4. Samples avoid update-time races. | Exit0 but two wrong lines: nonzero_to_nonzero and before_fall are01, expected10. Other four lines match. Scalar gate delay rules cannot replace this vector rule. |
| ASSIGN-PENDING-001 / audit_assignment_pending_same_value | §6.1.3(b): changing another operand while RHS remains the already-pending value must not postpone its propagation. | Exact two-line transcript passes, exit0. |
| ASSIGN-INIT-001 / audit_assignment_variable_initializer | §6.2.1 constant-expression declaration write7, then procedural write12; net declaration follows both. No competing time-zero writes. | E1100 rejects initialized declaration before behavior. Initial draft parameter introduced unrelated module-item restriction; final fixture uses literal constant expression2*3+1 to isolate initialization. |
| ASSIGN-PROC-001 / audit_assignment_assign_deassign | §9.3.1 active assign overrides ordinary writes and tracks RHS; deassign retains last value, next ordinary write replaces it. | Parser E0209 rejects legal assign/deassign statements. Five-line positive oracle retained. |
| ASSIGN-FORCE-001 / audit_assignment_force_release | §9.3.2 force tracks RHS; released variable holds value until next write, released net restores drivers. | Parser E0209 rejects legal force/release statements. Four-line positive oracle retained. |
| ASSIGN-STRENGTH-001 / audit_assignment_highz_pair_rejected | §6.1.4 forbids(highz1,highz0). Isolated invalid pair must not be accepted. | --run exit0, no diagnostic. Distinctive desired reject substring is an explicitly pending diagnostic contract, not an observed implementation message. |

Existing current-root oracle transcripts compared byte-for-byte against fresh
runs of d06_assign_delay_rise_fall, d06_net_decl_assign_delay,
d06_assign_delay_inertial and d06_assign_drive_strength: each exits0 and
matches its expected file. Their bodies and derivations were inspected.
These scalar cases do not close ASSIGN-VECTOR-001 or all strength combinations.

## Existing claim corrections needed (not silently changed)

- d06_assign_delay_inertial.v claims every new pending update supersedes any
  earlier update. §6.1.3(b) conditions cancellation on a changed pending RHS;
  the new ASSIGN-PENDING-001 fixture isolates that distinction and passes.
  Its claimed no-op y=0 event at17 also contradicts step(c), which schedules
  no event when the new RHS equals current LHS. Existing sampled values remain
  right, so this is false rationale, not authority to change the transcript.
- d06_net_decl_assign_delay.v says the declaration spelling is not sugar for
  a following assign. A declaration with assignment delay is not equivalent
  to adding a net delay; it can be equivalent to declaring the net separately
  and putting the delay on its assign. The one-declaration rule does not ban
  additional separate drivers on that net. Existing single-driver transcript
  does not establish that broader wording.
- d06_assign_drive_strength.v cites AMS9.22.3 for driver_strength; the source
  subsection is9.22.4 (9.22.3 is driver_state). Its measured strength resolution
  remains useful; the reference should be corrected during scoped cleanup.
- Source itself has an informative numerical typo in6.2.1 Example4: prose
  says300,000 but literal3E6 means3,000,000. Do not derive a numeric oracle
  from that mismatched prose. Source6.1.1's alternative-numbering prose also
  does not align simply with the expanded eight-alternative Syntax6-1.

## Atomic worklist, not a completeness denominator

| Group | Distinct remaining requirements |
|---|---|
| ASSIGN-LVALUE | Table6-1 scalar/vector net; constant bit/part/indexed selects; nested concatenations. Procedural reg/integer/time runtime bit/indexed selects, constant parts, memory words and concatenations. Isolate kind and index-constancy errors. |
| ASSIGN-CONT | RHS sensitivity, evaluate whole expression, drive only changed result; declaration versus separate assign; explicit/implicit nets; multiple drivers and comma-list assignments. |
| ASSIGN-DELAY | Scalar gate-delay cross-reference versus vector whole-value choice; one/two/three delays, old scheduled versus actual current value; changed-pending cancellation; current-value return no event; net delay versus declaration-assignment delay and other-driver independence. |
| ASSIGN-STRENGTH | Both polarity orders, all allowed levels, defaultstrong1/strong0, scalar/net-kind restrictions and both forbidden dual-highz orders. Strength grammar placement before delay. Resolution Clause7 dependency separate. |
| ASSIGN-VAR | Triggered procedural writes persist; constant module-level initialization only, forbidden array initialization, forbidden nonmodule initialization; unspecified order when competing initial/declaration writes must not get one deterministic golden. |
| ASSIGN-PROC | Assign/deassign allowed whole variables/concatenations, forbidden memory/selects; override writes, new assign replaces old assign, deassign hold. |
| ASSIGN-FORCE | Force valid variable/net/net-select/concatenation targets; invalid memory/variable-select; overrides net drivers and procedural/activeassign; variable release hold or immediate activeassign restoration; net release immediate driver restoration; RHS reevaluation throughout force lifetime. |

No compiler implementation changed and no full gates run in the original worker checkpoint.
Source traversal and four existing passing transcripts do not establish
exhaustive assignment conformance. Failing positives and pending invalid
diagnostic remain visible obligations, not acceptance-based coverage credit.

Root integration (2026-09-23): all listed fixtures plus the unknown-vector
delay witness are integrated. The bounded vector repair is documented in
`conformance-vector-delay-fix.md`; its original failure above is historical.
Root independently confirmed vector, pending-value and existing scalar-delay
transcripts after installing the repair. The three existing header/reference
corrections are applied without changing their bodies or expected values.
Cancellation-with-unchanged-RHS is assigned to ASSIGN-PENDING-001, not withdrawn;
per-bit net delays and multi-driver independence remain open worklist entries.
Root unit gate exits zero. A digital run with merged output captured through
a pipe preserves complete FAIL lines; its exact name-list comparison adds only
the new assign/deassign, force/release and initializer positives plus three new
task-disable positives. No pre-existing failure changed membership. The invalid
dual-highz fixture initially lacked explicit digital-runner selection and the
analog harness reported an unknown directive. Root added the digital marker;
the same required rejection is now assigned to the actual digital runner, not
withdrawn. The final digital run now reports its accepted invalid input as a
failure in the correct runner. Compared with scan/minmax/wait, seven new names
are present: the four assignment cases above and three task-disable cases;
every pre-existing failure name is unchanged. Final strict adds only the new
maxdelay XFAIL. Coverage command exits zero; `tools/conformance.sh` completed
with exit zero and wrote `conformance-measurement.md`. Logs use
`/tmp/vera-status-vector-final-{strict,devices,coverage}.log`.
