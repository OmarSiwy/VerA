# Inherited IEEE Clause11 scheduling: residual evidence audit

2026-09-23. Complete extracted §§11.1–11.6.7 read, printed158–162 /
physical188–192, from docs/1364-2005.pdf SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Visual checks at physical189 and191 confirm region-list/pseudocode nesting
and the differing blocking/NBA target-selection sentences. Remaining pages
received text review, not a new visual certification.

Existing conformance-scheduling.md, conformance-ieee1364.md and
conformance-ieee-scheduling-review.md were consulted first. This supplements
SCH-024/028/029/030 and NBA-006 rather than duplicating implicit sensitivity,
wait, ordered NBA delivery, or the mixed-signal host audit. No new claim is
made that queue-kernel tests establish production analog/digital integration.

## Source and documentation boundaries

IEEE's abstract reference algorithm permits different implementation
algorithms only when user-visible effects remain consistent. Active events
have arbitrary order. Inactive events follow active work; NBA updates follow
both; monitor work follows all three. #0 is an inactive suspension, not an
NBA-completion barrier. Begin/end statements retain source order even though
other processes may interleave; ordered NBA statements produce ordered
updates. A legal race is not an invalid source program.

AMS HTML §8.5.3.3 retains blocking target selection at resumption; §8.5.3.4
retains NBA target/value capture when queued. No correction to those faithful
paragraphs is needed. The inherited time-zero continuous-assignment rule,
port connection rules, and task-copy rule are not fully repeated in AMS's
shortened scheduling sections; the existing SCH-028/029/030 ledger correctly
keeps them in scope. This report supplies evidence, not replacement source
prose inserted into an AMS transcription.

| Rule group | Source | New evidence or explicit remaining boundary |
|---|---|---|
| SCHED11-EVENT | 11.1–11.4 | Value/named-event updates awaken sensitive processes; region ordering and future advancement. Existing timing/NBA ledgers remain authoritative; PLI callback placement and full repeated-region feedback remain open. |
| SCHED11-ORDER | 11.4.1 | Statement execution order and ordered NBA updates. Existing audit_nba_same_time_updates observes intermediate edges; no duplicate fixture added. |
| SCHED11-RACE | 11.4.2–11.5 / NBA-006 | New allowed-active-race fixture accepts either permitted immediate value, then separately requires the settled value. It does not require every permitted interleaving to occur. |
| SCHED11-INIT | 11.6.1 / SCH-028 | New constant-port fixture observes explicit constant assignment and implicit constant input connection propagation at time0 after active events. |
| SCHED11-PCA | 11.6.2 | assign/force sensitivity, deassign/release deactivation remain linked to the inherited assignments review and its legal unsupported positives. |
| SCHED11-BLOCKTARGET | 11.6.3 / SCH-024 | New indexed blocking target changes during delay, while RHS is captured before delay; legal positive rejects before execution. |
| SCHED11-NBATARGET | 11.6.4 / NBA-003 | Existing indexed NBA target-snapshot fixture freshly rerun, still E1100 unsupported indexed lvalue. Contrasts with blocking target timing, not duplicate coverage. |
| SCHED11-SWITCH | 11.6.5 / SCH-025 | Bidirectional network requires joint resolution. Unknown-control solutions agree=>known value, otherwise x. Existing primitive audit remains separate; one-switch truth tables do not close network solution semantics. |
| SCHED11-PORT | 11.6.6 / SCH-029 | New constant input/output path executes. Strength-preserving inout and primitive direct-terminal semantics remain open; port hierarchy alone does not close these. |
| SCHED11-COPY | 11.6.7 / SCH-030 | New delayed task call discriminates input capture and output copy-out timing; legal task declaration rejected before execution. Aliased actuals and indexed output destinations remain additional obligations. |

## Independently derived fixtures and direct execution

Files are tests/fixtures/digital/audit_sched_NAME.v with sibling exact
expected transcripts. Commands used the current root zig-out/bin/vera --run
and own-worktree fixture paths; no compiler changes or build were performed.

- constant_ports: direct constant1010 and constant0110 passed through a child
  xor0011 produce1010 and0101. #0 allows the active propagation chain to drain
  without advancing time. Exit0, exact `t=0 direct=1010 port=0101`.
- allowed_active_race: after settledq=1, q becomes0 and p may immediately be
  old1 or new0. A case-equality membership expression prints1 for either;
  #0 then requires settledp=0. Exit0, exact `permitted=1`, `settled=0`.
  This checks membership for one run; it does not sample a distribution or
  require a nondeterministic implementation to vary its chosen ordering.
- blocking_target_return: at1 capture source1; at2 change source0/index2;
  at5 resume and deposit captured1 in bit2. Expected `pending=0000`,
  `returned=0100`. Exit1/E1100 only whole-variable lvalues implemented.
  Original positive expectation remains; this is not negative evidence.
- task_copy_timing: invoke at1 with input3, local output assigned before
  suspension; caller input changes9 at2. Caller output must remain0 at3;
  at5 copy capturedinput3+1 to caller output4 before following display.
  Expected `pending=0`, `returned=4`. Exit1/E0205 unsupported task declaration,
  with subsequent parser recovery errors; no runtime copy behavior established.

Fresh existing d06_intra_assign_delay exits0 with its five expected lines,
including inactive-region pre-NBA observation. Existing d04_09_task_argument_passing
still rejects task syntax, and audit_nba_index_snapshot still rejects indexed
targets. Their intended positive oracles were not converted into rejections.

No new invalid-input fixture is invented for permissible event order, legal
delayed tasks, or legal indexed targets. These scheduling paragraphs primarily
specify behavior; receiver-kind and primitive-terminal legality require their
declaration/connection clauses and independent isolated negatives. They remain
open in the relevant hierarchy/primitive registers, not excused from scope.

## Existing false claim discovered

d04_09_task_argument_passing says assigning `o = i + 1` would reach back into
input actual p if inputs were passed by reference. That assignment writes o,
not i, and cannot distinguish input copy from a reference. Its untimed body
also does not observe caller output while the task is executing, so final
values alone do not distinguish eager output reference writes from copy-out.
Its final input/output/inout arithmetic remains a valid intended oracle.
Withdraw those stronger claims into SCHED11-COPY; the new delayed fixture
provides the missing discrimination without changing its expected result.
Existing file and transcript are left untouched for coordinated integration.

No exhaustive denominator, measure percentage, source closure or full gate is
claimed. Passing cases add bounded runtime evidence; rejected legal cases add
visible debt. Integration must run the full gates and compare failure names.

Root integration, 2026-09-23: main read this complete report, the four new
fixtures, and independently reread11.6.1–11.6.7. New fixtures are integrated;
fresh root digital results are pending. The false task-header claim identified
above was already corrected by the task/function batch, with its stronger
obligation linked to TF-EVID-001. These scheduling witnesses supplement that
evidence rather than restoring the withdrawn claim.

Root digital gate exits one. Exact failure-name comparison against the prior
task/function run adds only `audit_sched_blocking_target_return` and
`audit_sched_task_copy_timing`; the constant-port and allowed-active-race
cases pass. No prior failure name changes. Recorded log:
`/tmp/vera-scheduling-ledger-devices.log`. This confirms bounded passing
observations and unsupported legal cases, not complete scheduling behavior.
