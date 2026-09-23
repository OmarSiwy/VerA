# Inherited timescale and simulation-control review

Reviewed 2026-09-23 against the licensed IEEE 1364-2005 source recorded in
`conformance-ieee1364.md`. Exact titles are §17.3 **Timescale system tasks**
and §17.4 **Simulation control system tasks**, not simulation-time functions
(those are §17.7). AMS §§9.6–9.7 add applicability/context and analog behavior;
their rules are not interchangeable with the inherited digital lifecycle.

## Read/visual boundaries

Read complete extracted §§17.3–17.4, printed 298–303 / physical 328–333,
from the timescale introduction through the final stop paragraph before §17.5.
Visually inspected physical329–332 for Syntax17-9 through17-12, all Table17-10
unit mappings, Table17-11 defaults, Table17-12 verbosity distinctions, examples
and surrounding prose. Physical333 stop paragraph was visually inspected in
the preceding PLA review. Physical328 introductory heading/list has text review
only. Followed the explicit §19.8 reference and read that complete subsection,
printed358–360 / physical388–390, including its rounding example and Table19-1;
that dependency has text review only here, not visual certification.

The Chapter9 worker's AMS control handoff distinguishes analog accepted/rejected
iterations and initial-step diagnostics from digital stop/finish. In particular,
an analog initialization error exit policy cannot supply a mandated digital
host exit-code oracle.

## Obligation/evidence register

| ID | IEEE source | Obligation and bounded evidence |
|---|---|---|
| CTRL-TIME-001 | 17.3.1 | `$printtimescale` selects current module if argument omitted, otherwise the named module. Specified output structure includes scope, unit and precision. Hierarchical targets and an isolated legal print witness remain open. |
| CTRL-TIME-002 | 17.3.2 Syntax17-10 | `$timeformat` permits omitted argument list. New legal no-argument fixture is refused as requiring four arguments. This source permission is not a malformed-call negative. |
| CTRL-TIME-003 | 17.3.2 Table17-10 | Integer unit code0 through-15 maps to decimal powers of seconds. Existing d09_07 covers only selected scales; legal boundary endpoints and invalid outside-range requests remain to isolate. |
| CTRL-TIME-004 | 17.3.2 | Settings apply at invocation to later formatting until another invocation; integer settings are not declared constant-only. New runtime-variable test changes a variable between calls, distinguishing reading settings once from tracking it continuously. |
| CTRL-TIME-005 | 17.3.2 | Unit, fractional precision, suffix and minimum field width govern `%t` in display/write/strobe/monitor and file variants. Existing d09_07 gives explicit conversions; complete family, global multi-module and suffix/width evidence remain open. |
| CTRL-TIME-006 | 17.3.2 Table17-11 | Defaults use finest source timescale precision, zero fraction digits, empty suffix, width20. New no-argument witness uses one explicit timescale, eliminating simulator-specific absent-timescale defaults. Multi-module finest precision is not covered. |
| CTRL-TIME-007 | 17.3.2 | Interactive delays use the selected time unit. Needs host command interface, not a batch source transcript. |
| CTRL-TIME-008 | 19.8 | Round each delay using local precision before scheduling, even when another module has finer precision. New two-delay witness passes single-module rounding; finer-global/local separation remains open. |
| CTRL-TIME-009 | 19.8 | Directive persists until replaced; absent/reset defaults are simulator-specific. Mixed explicitly scaled/unscaled modules require an error. Valid magnitude/unit set and precision no coarser than unit require separate invalid cases. |
| CTRL-TIME-010 | 17.4.1 | Finish terminates simulation and returns control to host. Argument is an expression selecting diagnostic verbosity, not process exit status. New runtime-expression0 positive is refused; existing literal0 cases do not cover it. |
| CTRL-TIME-011 | 17.4.1 Table17-12 | Level0 emits no finish diagnostic, default/level1 include time/location, level2 adds memory/CPU statistics. Legal level2 control is refused. Exact resource numbers and diagnostic wording are not standardized by this table. |
| CTRL-TIME-012 | 17.4.2 | Stop suspends rather than terminates; optional0/1/2 governs increasing diagnostics. Legal stop0 control is unimplemented. Resume needs a host lifecycle witness; terminating a batch process cannot prove suspension. |

These are source/evidence groups, not a closed atomic denominator. All missing
positive/invalid/environmental counterparts remain explicit debt.

## Independent fixtures and observations

New `.v`/`.expected.txt` pairs under `tests/fixtures/digital/`:

- `audit_timeformat_default_call`: `1ns/1ps`, literal2 is2000ps under default
  formatting; width20 gives sixteen spaces then four digits. Direct root
  `vera --run` exits1/E1100, `$timeformat takes exactly four arguments`.
- `audit_timeformat_runtime_arguments`: unit variable-9, precision variable1,
  width variable0, suffix `ns`; literal2 prints2.0ns. Merely assigning precision2
  leaves installed settings unchanged; reinvocation gives2.00ns. Final test
  exits1/E1100 at the intended call because units/precision are required constant.
  Initial draft accidentally used AMS keyword `units` as an identifier and was
  corrected to `unit_code` before recording this intended failure.
- `audit_timescale_delay_round_each`: each0.26 local unit at10ns/1ns rounds
  from2.6ns to3ns. Two delays yield3ns then6ns, so `$realtime` is0.3 then0.6.
  This rejects rounding accumulated5.2ns once to5ns; no midpoint tie is involved.
  Direct run exits0 and exactly prints the expected two lines.
- `audit_finish_expression_zero`: variable verbosity0, print `before`, finish,
  unreachable `after`. Expected transcript contains only `before`; no finish
  diagnostic is allowed at0. Direct run exits1/E1100 because only literal0/1
  and omitted argument are implemented. It fails before execution, so no
  lifecycle behavior is falsely credited.

Two controls remain outside the measured fixture tree under
`tools/control-audit-controls/`: `finish_statistics.v` and `stop_resume.v`.
Both were run against the real root compiler under a three-second timeout,
and both returned normally with exit1/E1100 before any timeout: finish2 is
unsupported; stop is unimplemented. They have no byte golden for implementation-
dependent statistics or host suspension/resumption. Their rejection is failure
of legal input, never a passing rejection oracle.

## Boundaries preventing false expectations

The digital implementation's comment says computed timeformat settings would
ask the format to track a value. That conflates evaluation at a task invocation
with continuous tracking; the new fixture explicitly distinguishes them. The
source imposes no constant-only restriction on these integer settings.

Do not equate `$finish(1)` with process status1 or `$finish(2)` with status2:
the values choose diagnostic detail. No specific OS exit-code mapping is
derived here. Likewise do not infer a portable line/byte spelling or exact
resource statistic from Table17-12. No argument-range rejection fixture was
added without a rule-specific diagnostic and a legal matching neighbor.

Source §17.3.2 describes both later invocation effects and modules following
in the source description. This report does not silently replace that wording
with a stronger cross-module scheduling claim. Concurrent initial-call ordering
would need race-free fixtures. A no-argument call before any custom setting
does not establish what an omitted call does after custom settings.

No shared runner, compiler or existing fixture was changed by this handoff.
No full builds/suites were run. Main integration owns name-list comparisons;
new digital failures do not automatically change analog torture measurements.

Main review checkpoint (2026-09-23): independently read the source clauses,
reviewed this report and all proposed fixtures/transcripts. The fixture batch
is now integrated and the full root digital runner reproduces the reported
intended failures; the delay-rounding positive passes. Exact FAIL-name diff
against the prior math-fixes batch adds only the new PLA, queue, timeformat
and finish-expression names. These are newly exposed required behavior gaps,
not regressions hidden by changing expectations. The historical specification's
false readmemb prerequisite, fixed PLA fixture-count claim and nonexistent
"total queued" selector have been corrected with source references.
