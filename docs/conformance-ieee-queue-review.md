# Inherited stochastic queue source/evidence review

Reviewed 2026-09-23: IEEE 1364-2005 §17.6, **Stochastic analysis tasks**,
complete introduction and §§17.6.1–17.6.6, printed 307–308 / physical
337–338. Read all extracted text and visually inspected both pages, including
every Table 17-14, 17-15 and 17-16 cell and all argument directions. Physical
337 was rendered at 1400 pixels during the preceding PLA boundary review;
338 was rendered at 1500 pixels for this review. Source provenance remains in
`conformance-ieee1364.md`; no source PDF/text is redistributed.

AMS §9.9 expressly leaves these inherited tasks unextended. AMS Table 9-6's
context permissions remain distinct from their digital runtime semantics.
The Chapter 9 worker confirmed no overlapping digital queue fixture work.
This audit inventories source rules and failing runtime evidence, not measure-B
closure, full atomic enumeration or a conformance percentage.

## Source-derived obligations

| ID | IEEE clause | Obligation and evidence boundary |
|---|---|---|
| QUEUE-001 | 17.6.1 / Table 17-14 | Integer queue ID uniquely names a new queue; type1 FIFO, type2 LIFO. Order/payload test uses two independently named queues and distinct jobs. |
| QUEUE-002 | 17.6.1 | Integer maximum length bounds entries; status reports creation success/error. Capacity test fills then attempts overflow. Positive capacity1 and larger values remain separate witnesses. |
| QUEUE-003 | 17.6.2 | Add takes queue ID, job ID and user-defined integer information; association must survive retrieval. Order test checks distinct payloads, not job IDs alone. |
| QUEUE-004 | 17.6.3 | Remove writes job ID, original information and status. FIFO/LIFO test interleaves removals from separate queues. Output values on failed removal are not specified here and are not asserted. |
| QUEUE-005 | 17.6.4 | `$q_full` is a function, returning0 when another entry fits and1 when full, plus output status. Capacity test samples both normal states. Return value after an undefined-ID failure is deliberately ignored. |
| QUEUE-006 | 17.6.5 / Table 17-15 | Code1 requests current length; code3 requests maximum length. Capacity test observes full/drained length and maximum2. It does not distinguish configured limit from observed historical maximum because both equal2 in this witness. |
| QUEUE-007 | 17.6.5 / Table 17-15 | Codes2/4/5/6 request mean interarrival, shortest-ever wait, longest wait among still-queued jobs and average wait respectively. Timing-statistic source labels are recorded, but units/rounding/empty-population accounting and precise populations need further justification before portable numeric oracles. |
| QUEUE-008 | 17.6.6 / Table 17-16 | Success status0; full-add status1; unknown-ID status2; empty-remove status3. Capacity and status-boundary fixtures use runtime transcript assertions, not compile rejection. |
| QUEUE-009 | 17.6.6 / Table 17-16 | Invalid type status4, nonpositive length status5, duplicate ID status6. Boundary fixture separates these conditions so error precedence is not invented. |
| QUEUE-010 | 17.6.6 / Table 17-16 | Insufficient memory status7 prevents creation. Deterministic host allocation-failure injection is needed; do not consume arbitrary system memory merely to force this status. |
| QUEUE-011 | 17.6.1–6 | Integer inputs and writable outputs need argument-shape/type validation. Missing/extra arguments and non-lvalue status/job/info are not currently isolated by these runtime cases. |
| QUEUE-012 | AMS 9.9 / Table 9-6 | Digital behavior is required separately from analog prohibition. The combined analog rejection's earlier timescale failure does not isolate any queue task. |

## Correcting historical claims without inventing new requirements

`ch09_system_tasks/d09_SPEC.md` lists a “total queued” statistic in both its
general and count-based inventory. Table 17-15 contains no such selector:
do not invent code7 or claim its absence is a compiler defect. The table names
six statistic selectors, with the longest-wait selector specifically referring
to jobs still present. Shortest, average and interarrival statistics must not
silently borrow an undocumented simulator's denominators or default values.

The source gives no status entry for an out-of-range statistic selector.
Consequently this audit adds no test requiring status8 or a particular compile
error for that case. Likewise it does not assume failed remove/exam/function
calls leave all other outputs unchanged. Those are open interpretation or
dependency questions, not permission to fabricate golden outputs.

The existing combined analog file calls `$q_initialize` as an expression with
three arguments, despite the inherited task's four-argument signature. Earlier
timescale calls already trigger its broad analog-context expectation. Its queue
line cannot be reused as a legal digital neighbor or independent arity oracle.
No existing fixture expectation was silently changed in this handoff.

## New independently derived runtime cases

All files are under `tests/fixtures/digital/`, with matching `.expected.txt`.

- `audit_queue_order_payload.v`: two capacity2 queues receive `(13,130)` then
  `(27,270)`. FIFO returns the first pair first; LIFO returns the second pair
  first. Interleaving removals checks independent queues and payload identity.
- `audit_queue_capacity_stats.v`: capacity2 accepts jobs8/9, reports full,
  refuses job10 with status1, remains length2, drains the original pairs, then
  reports length0, maximum2 and empty-remove status3. Failed output payloads
  are never compared. The maximum query here is intentionally a bounded case,
  not a complete statistical-definition oracle.
- `audit_queue_status_boundaries.v`: distinct fresh IDs isolate unsupported
  type3, zero/negative lengths, duplicate legal ID and undefined ID for add,
  remove, exam and full. The expected status sequence is derived directly
  from Table 17-16: 4,5,5,0,6,2,2,2,2. These are legal invocations testing
  runtime errors; they must execute and report statuses, not be rejected by
  the compiler. Memory exhaustion is excluded for safety and reproducibility.

Directly executed all three with the current root `zig-out/bin/vera --run`
from the separate agent worktree. Each exits1 with E1100 reporting
`$q_initialize` unimplemented at the first call, before any transcript output.
This is actual positive/runtime-status evidence debt. The later task behavior
is masked by the initial unimplemented call and is not independently observed.
No rejection directive or expected-failure escape was added to disguise it.

Only this report and these three fixture/transcript pairs are part of this
handoff. Shared runners, historical fixture specification and analog fixture
were left unchanged for main integration. No full build/suite was run; final
integration must compare FAIL/XFAIL names and keep new digital failures
separate from analog fixture measurements.

Main review checkpoint (2026-09-23): independently read the source clauses,
reviewed this report and all proposed fixtures/transcripts. The fixture batch
is now integrated and the full root digital runner reproduces the reported
intended failures; the delay-rounding positive passes. Exact FAIL-name diff
against the prior math-fixes batch adds only the new PLA, queue, timeformat
and finish-expression names. These are newly exposed required behavior gaps,
not regressions hidden by changing expectations. The historical specification's
false readmemb prerequisite, fixed PLA fixture-count claim and nonexistent
"total queued" selector have been corrected with source references.
