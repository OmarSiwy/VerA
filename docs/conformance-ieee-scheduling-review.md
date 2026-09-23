# Inherited implicit sensitivity and wait review

Reviewed 2026-09-23. Selected IEEE 1364-2005 §§9.7.5–9.7.6 because current
scheduling/source ledgers separately cover NBA ordering and Chapter11, while
basic implicit-sensitivity fixtures leave important inclusion/exclusion cases
unobserved. This is a bounded subsection review, not complete IEEE Chapter9,
Chapter5, AMS scheduling or measure-B closure.

## Source and runtime read boundaries

Read full extracted §9.7.5, printed134–136 / physical164–166, including all
exceptions and all six examples; read complete §9.7.6 on printed136 / physical166.
Individually inspected physical164–166 at1400-pixel rendering, checking the
exception bullets, indexed targets, nested implicit/explicit events, case labels,
example continuation and Syntax9-11's mandatory expression/optional null body.
Adjacent named-event/event-or and intra-assignment content was visible but is
not claimed as a full new review. Source provenance is recorded separately in
`conformance-ieee1364.md`.

Inspected current root `src/sim/digital.zig` production paths `compileStmt`,
`readSlots`, `sensitivity`, `execute` wait_slots/wait_level, and the existing
digital d04_01/d04_02 fixtures/specification. No production code was changed.
AMS8.5 inherits digital procedural behavior; this report does not confuse
digital `@*` with analog implicit sensitivity and solver reevaluation.

## Rule/evidence register

| ID | IEEE clause | Rule and evidence |
|---|---|---|
| ISENS-001 | 9.7.5 | All read net/variable identifiers contribute to implicit sensitivity, not merely the currently selected expression arm. Existing d04_01 covers two RHS identifiers; full conditional/function/task argument matrix remains open. |
| ISENS-002 | 9.7.5 | Identifiers appearing only in explicit wait/event expressions are excluded from the outer implicit list. New nested explicit-event exclusion transcript passes; a separate wait-only exclusion case is still needed. |
| ISENS-003 | 9.7.5 | Write-only assignment target identifiers do not enter the list. New independent destination-poke fixture passes and directly distinguishes erroneous target sensitivity. |
| ISENS-004 | 9.7.5 | LHS index expressions are reads and must enter the list. New memory-target index-change fixture passes. Packed bit/part selects and multiple nested indexing dimensions remain open. |
| ISENS-005 | 9.7.5 | Case/conditional expressions and case-item expression variables enter the list. Production walker visits them; code inspection is not a complete runtime matrix. |
| ISENS-006 | 9.7.5 | A variable read elsewhere in the same block is not excluded merely because also assigned. Source temporary-variable example includes both temporaries. Runtime external-mutation witness remains open. |
| ISENS-007 | 9.7.5 | Nested statement bodies contribute their reads; explicit event expressions themselves remain excluded. New event fixture observes both exclusion and later correctly armed body execution. Nested implicit controls remain distinct debt. |
| WAIT-001 | 9.7.6 | A true condition continues without awaiting a future transition. Source syntax permits an expression, not only expressions with variable dependencies. New constant1/constant0 fixture is incorrectly rejected during preflight. |
| WAIT-002 | 9.7.6 | A false condition blocks until it becomes true. Constant0 therefore cannot resume; a separate process may still terminate simulation. Constant fixture leaves this later half masked by constant1 rejection today. |
| WAIT-003 | 9.7.6 Syntax9-11 | Parenthesized condition expression is required; body can be statement or null. New empty-expression negative gets specific E0209; matching legal variable-expression control executes. Null-body and expression-type boundaries remain open. |

## Fixture derivations and actual outcomes

New digital positives each have a sibling expected transcript:

- `audit_sched_implicit_write_only`: copy source1, independently write target0,
  observe target still0, then change source. Incorrect inclusion of the target
  would restore1 at the poke observation. Direct root `vera --run` exits0,
  exactly `copied=1`, `poked=0`, `changed=0`.
- `audit_sched_implicit_event_exclusion`: data change arms nested gate event,
  gate change completes copy. Poke destination0, change gate twice without
  changing data: destination must remain0 because only data belongs to outer
  list. Poke destination1, then change data0 and gate: destination becomes0.
  Direct run exits0 with `gate-only=0`, `data-then-gate=0`. Both final writes
  are observable; the expected last zero is not merely a retained old zero.
- `audit_sched_implicit_lhs_index`: initialize memory words0; copy payload7
  to index0, then change only index to1. Direct run exits0 with `first=7/0`,
  `second=7/7`, proving the index contributes a trigger in this shape.
- `audit_sched_wait_constant`: wait1 should print `ready`; subsequent wait0
  never prints its body; another process prints `end` and finishes at time1.
  Direct run instead exits1/E1100: constant wait would never be reconsidered.
  This is rejection of legal behavior, not valid negative evidence.

Initial drafts of the first three omitted explicit timescales and hit the
runner's unrelated timescale preflight. Final versions use `1ns/1ns` and yield
the intended passing observations above. Stimulus starts at time1 to avoid
time-zero waiter-registration races. Observations are separated from writes;
no FIFO ordering among simultaneous active processes is asserted.

`audit_sched_wait_empty_rejected.v` uses the digital-negative opt-in marker and
requires both E0209 and `expected an expression` in diagnostic headers. Direct
run exits1 with that exact syntax diagnostic at `wait ()`. Matching
`tools/scheduling-audit-controls/wait_expression_legal.v` differs in the
condition being `flag`, set1; direct run exits0 and prints `ready`. This is
parser-phase rejection of missing syntax, not runtime proof of wait wakeups.
It must run through the reviewed digital runner, never analog compilation.

## Existing claims needing qualification

The existing d04_02 header says adding its own target to sensitivity would
necessarily produce an infinite zero-delay self-loop. That conclusion is not
established: the process is executing rather than suspended when it writes,
and writing an unchanged value cannot create a value-change event. Its cascade
observations are useful, but do not isolate the claimed target exclusion.
The withdrawn strength of that claim is tracked here as ISENS-003; the new
external-poke fixture supplies the distinguishing observation. Existing source
and expectations were left unchanged for main integration.

Production `compileStmt` currently rejects wait conditions whose collected
dependency set is empty before executing the level test. That explains the
constant1 failure: it confuses a need for future wakeups with immediate truth
evaluation. `wait_level` already distinguishes a true current condition from
blocking, but the legal constant source never reaches it. Fixing that code is
outside this docs/tests handoff.

Production also rejects implicit event controls with no read dependencies.
The reviewed §9.7.5 syntax/prose states no corresponding prohibition. A quiet
empty-list process requires a separate source-derived fixture and termination
control; this review does not silently count that rejection as conformant.

No full suite/build or compiler changes were performed. Main integration owns
FAIL/XFAIL name-list comparisons and measured outputs. Host/solver coordination,
continuous assignments, NBA scheduling, function-body sensitivity and complete
four-state wait-expression behavior remain separate obligations, not exclusions.

Main integration supersession (2026-09-23): all new fixtures are integrated,
and the source-backed constant-wait fix is recorded in
`conformance-ieee-wait-fix.md`. Root runtime now matches every positive
transcript; the specific empty-expression negative also passes. This supersedes
the constant-wait failure above without claiming broader scheduling closure.
The old d04_02 explanation is corrected in comments only; its executable body
and expected transcript are unchanged. The withdrawn claim is assigned to
ISENS-003 and the distinguishing independent-poke fixture.
