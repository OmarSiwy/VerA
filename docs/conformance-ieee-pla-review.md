# Inherited PLA task source and evidence review

Review date: 2026-09-23. The edition-correct title is IEEE 1364-2005
§17.5, **Programmable logic array (PLA) modeling system tasks**. AMS §9.8
inherits these tasks without extensions; AMS Table 9-5 separately restricts
their context. This report does not convert analog rejection into digital
behavioral evidence or close measure B.

## Source boundary

Read all extracted §17.5 introductory text and §§17.5.1–17.5.4, printed
303–307 / physical 333–337, including both examples and the transcript ending
immediately before §17.6. Individually inspected renderings of every one of
those physical pages (`pdftoppm -scale-to 1400 -png`). Checked Syntax 17-13's
argument categories and separators, every entry in Table 17-13, ascending
ranges, all personality symbols and the example continuation/output.
Read AMS §9.8 text and current system-task fixture specification. Read complete
extracted IEEE §5.1.10, printed 50–51 / physical 80–81, including Tables
5-12 through 5-16; those bitwise tables have text review only here, not a
separate visual certification. Source provenance/hash is in
`conformance-ieee1364.md`; no licensed source is redistributed.

## Source fidelity and previous oracle corrections

- IEEE printed page 306 labels its example synchronous, but its clocked task
  call spells `$async$and$array`. Visually confirmed source inconsistency:
  normative §17.5.1 controls the interpretation. Do not copy this example to
  derive an asynchronous subscription on every clock edge as required behavior.
- The historical `ch09_system_tasks/d09_SPEC.md` says PLA tests depend on
  `$readmemb`. Section 17.5.3 explicitly permits procedural memory assignment
  as an alternative; direct-initialization tests isolate PLA from file loading.
- That specification's assertion that two fixtures suffice is not an exhaustive
  evidence argument. Memory changes, input changes, ordering, four-state values,
  argument legality and every logic/representation/timing combination need
  independently identified evidence. There is no fixed fixture-count shortcut.
- Combined analog rejection `154_timescale_pla_queue_analog_rejected.va`
  starts with timescale tasks; its broad `analog context` expectation can pass
  before its PLA call is examined. Its PLA argument is also an integer rather
  than a personality memory. Keep the historical citation as a claim, not
  isolated PLA context evidence. No existing expectation was silently changed.

## Obligation register

These are bounded source-derived rule groups, not an exhaustive denominator.

| ID | IEEE clause | Obligation and remaining evidence |
|---|---|---|
| PLA-001 | 17.5, Syntax 17-13, Table 17-13 | Names form the sync/async × and/or/nand/nor × array/plane product. Arguments are memory identifier, input expression and variable lvalue. Three new fixtures reach only their first implemented-name boundary; no all-name claim. |
| PLA-002 | 17.5 | Input terms may be nets or variables; outputs must be variables. New tests use variables. Net input, output concatenation/selects, invalid net output and non-lvalue output remain open. |
| PLA-003 | 17.5.1 | Sync evaluation/update occurs upon invocation; changing inputs alone does not reinvoke it. Async evaluates on any input-term or personality-word change. New timing test distinguishes input and memory triggers from reinvocation. |
| PLA-004 | 17.5.1 | Both forms update without modeled delay. Positive-time-separated observations in the new async test avoid active-region races, but do not prove exact same-time scheduling or zero-delay compliance. |
| PLA-005 | 17.5.2 | Each timing/format family supports the four logic types; nand/nor complement the corresponding reductions. Array test derives all four for known and uncertain inputs. Later calls are masked by first-call failure today. |
| PLA-006 | 17.5.3 | Personality is a reg memory: packed width equals input-term count, memory depth equals output-term count. New tests use two inputs with one, two or three output rows. Mismatched widths/depths need isolated invalid tests after valid task execution exists. No mandated diagnostic text is supplied here. |
| PLA-007 | 17.5.3 | Inputs, outputs and personality memory are specified in ascending order. Tests use explicit [1:N] declarations, distinct rows and asymmetric values. Descending-range rejection, alternate nonunit bounds and concatenation ordering need separate investigation. |
| PLA-008 | 17.5.3 | Load via readmemb/readmemh or procedural assignment; dynamic memory edits affect the next evaluation. Direct writes are exercised; file parsing/loading remains a separate dependency. |
| PLA-009 | 17.5.4 | Array personality 1 selects an input, 0 omits it. Input x differs from a personality x. New array oracle tests selected unknowns and a controlling zero, not unknown personality behavior. |
| PLA-010 | 17.5.4 | Plane personality 0 complements input, 1 selects true input, z/? ignores it. New plane test isolates complement and ignore, including ignored x input and an all-ignore AND row. Other logic types and asynchronous plane updates remain open. |
| PLA-011 | 17.5.4 | Plane personality x invokes the source's worst-case rule. This subsection gives no expanded four-state truth table for that encoding. Do not substitute ignore, always-x or a simulator's current behavior without a justified derivation. Explicit source/reference interpretation and fixtures remain open. |
| PLA-012 | AMS 9.8 / Table 9-5 | Digital availability and analog prohibition are distinct requirements. Combined analog fixture is not an isolated prohibition oracle, and prohibition cannot prove digital availability. |

## Independent four-state and ordering derivations

For two inputs ordered `(input1,input2)`, array rows `11` and `10` select,
respectively, both inputs and only input1. At input `10`, their AND result is
`01`; OR is `11`; inversion gives NAND `10`, NOR `00`. At input `x0`, the
controlling zero makes the first AND result 0, the second remains x; OR is
unknown in both rows. Thus AND `0x`, OR `xx`, NAND `1x`, NOR `xx`.
These values follow the ordinary bitwise logic tables, not a measured compiler
output. Selected z input, all-empty array rows and the complete input-state
cross-product remain untested.

Plane rows `0z`, `?1`, `zz` implement `~input1`, `input2` and the empty AND
identity, respectively. The last stays 1 even for unknown inputs because all
inputs are ignored; this agrees with the source's all-ignore AND example.
Input `10` therefore gives `001`; `0x` gives `1x1`. The `?` literal is the
z encoding here, not a wildcard comparison operator. Unknown *personality*
bits are deliberately not folded into this input-uncertainty derivation.

For the async/sync witness, a single row initially selects both inputs and
input `11` produces 1. Change input to `10`: async becomes 0, sync holds 1.
Change row to `10`: async becomes 1, sync still holds 1. Change input to `00`:
async becomes 0 while sync holds 1. Explicit sync reinvocation finally yields 0.
Each delayed observation separates stimulus from observation; no exact callback
order or scheduler-region claim is made.

## New fixtures and actual results

| Digital fixture and sibling expected transcript | Direct root `vera --run` result |
|---|---|
| `audit_pla_sync_array_logic.v` | Exit 1, E1100: `$sync$and$array` not implemented, before first transcript line. |
| `audit_pla_plane_ignore.v` | Exit 1, E1100: `$sync$and$plane` not implemented, before first transcript line. |
| `audit_pla_async_personality.v` | Exit 1, E1100: `$async$and$array` not implemented, before first transcript line. |

Each legal fixture reaches the intended PLA task: these are observed positive
behavioral failures, not unrelated parse failures. Each committed expected
transcript is independently derived above and in its header. No `reject`
directive was added to bless unsupported behavior. The digital transcript
runner does not currently support XFAIL accounting; these remain explicit
failing positive cases for main integration, not passing analog torture rows.

Invalid argument/dimension/order fixtures were not promoted to the measured
suite: the legal neighbor is already refused as unimplemented, so rejection
alone would not demonstrate the relevant validation rule. Needed invalid
boundaries include non-memory first argument, missing/extra arguments, net or
expression output, incompatible memory shape and prohibited descending order.
The cited clauses do not prescribe exact error codes or authorize inventing
specific out-of-range runtime behavior.

Only this report and the three new digital fixture/transcript pairs were
changed in this handoff. Shared runners and the historical specification were
left to main integration. No full builds/suites or measured conformance update
were run; remaining inheritance and source ambiguities stay open.

Main review checkpoint (2026-09-23): independently read the source clauses,
reviewed this report and all proposed fixtures/transcripts. The fixture batch
is now integrated and the full root digital runner reproduces the reported
intended failures; the delay-rounding positive passes. Exact FAIL-name diff
against the prior math-fixes batch adds only the new PLA, queue, timeformat
and finish-expression names. These are newly exposed required behavior gaps,
not regressions hidden by changing expectations. The historical specification's
false readmemb prerequisite, fixed PLA fixture-count claim and nonexistent
"total queued" selector have been corrected with source references.
