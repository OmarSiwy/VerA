# Inherited IEEE 1364-2005 VCD review

Reviewed 2026-09-23 against the user-supplied licensed PDF, SHA256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Read the complete extracted Chapter 18 text, printed pages 325–348 / physical
pages 355–378, including all examples, tables and syntax text. This is **text
review**, not visual certification of Figures 18-1/2, Tables 18-1/2/3 or Syntax
18-1–29. The neighboring Chapter 17 math text and Chapter 19 are not included.
No licensed source text/PDF is redistributed here.

## Oracle correction: VCD-ORACLE-001

Main integration checkpoint (2026-09-23): main read this report, the entire
comparator and tests, and the fixture/specification diffs. Integrated source
files retain their executable bodies, directives and goldens. The scope-stack
question was sent back for source review; the explicit semantic boundary below
records the result instead of inventing a rejection requirement. All 12 Python
tests pass in the main tree. The historical `$vcdopen` row is corrected to
`$vcdclose` without changing its missing status. No actual VCD artifact or
production-gate integration is claimed.

The two existing digital VCD witnesses retain their executable bodies and
their implementation-specific `.expected.vcd` snapshots. Several historical
claims in their headers and `ch09_system_tasks/d09_SPEC.md` were too strong:

- Four-state identifier codes may use arbitrary printable ASCII characters;
  sequential IDs from `!` are not normative (§18.2.1, printed 331).
- §18.2's free format does not require one command per line or fixed whitespace
  around all header fields. Scalar adjacency and vector prefix separation
  remain actual constraints (§18.2.2).
- Independent variable declarations/changes need not occur in the snapshot's
  chosen declaration order. Scope membership, types, widths, timing and values
  remain observable requirements. An empty timestamp is not a forbidden value
  change during a suspended interval.
- The initial checkpoint begins after the current time unit (§18.1.3); this is
  not a general rule mandating exactly one textual record per time step.
- The former inference that `$dumpflush` mandates an exact final `$finish` line
  was not established by these clauses and is withdrawn.
- Removing every `$version` section destroys evidence for §18.2.3.8's dumpfile
  task/expression information. Removing every `$comment` destroys the limit
  indication required by §18.1.5. Date/version payloads vary, but the required
  metadata cannot simply disappear from a conformance check.

No regression is deleted to hide those differences. The old normalization recipe
is now explicitly an implementation snapshot convention, not a normative oracle.
The historical `CLAUSE-AUDIT.md` row 18.4-01 also names `$vcdopen`; the source
keyword is `$vcdclose` (§18.3.6.1). That inherited ledger needs a targeted main
integration correction, not a claim of implemented close-record support.

## Bounded semantic artifact comparison

`tools/vcd_semantics.py` parses the existing four-state scalar/vector profile.
It resolves IDs to scoped references, retains scope type, width and variable
type, expands legal shortened four-state vectors, preserves checkpoints and
per-variable update sequences, and compares independent variable records without
requiring their arbitrary serialization order. Repeated or empty timestamps do
not invent value changes. Aliased references sharing one code are represented.
Names and codes remain case-sensitive; X/Z value spelling is normalized where
the grammar explicitly permits either case.

Metadata is retained separately, including body-comment time. `compare_artifacts`
requires actual output to contain nonempty date/version metadata and can check
the test's required dumpfile task/expression text and limit-marker substring.
The marker substring is a caller-selected diagnostic expectation, not a mandated
IEEE wording. The semantic-only projection intentionally excludes run-varying
metadata; callers must use the combined API for actual conformance evidence.

This is not a full-file conformance validator. Real values, event-value markers
and extended VCD explicitly raise unsupported-profile errors. Unusual reference
identifier syntax, full declaration legality, every grammar edge and all
serialization constraints still need further review/tests. The parser does not
prove that dumping was invoked at a legal time or that a simulator selected the
correct variables: those require source plus actual generated artifacts.

Scope-boundary follow-up: IEEE §§18.2.1, 18.2.3.3, 18.2.3.4 and
18.2.3.6 (printed 330, 333–334) were reread. The declaration grammar is
a repetition of commands; `$upscope` changes the current scope, and
`$enddefinitions` ends declarations. No final empty-scope-stack requirement
was located. Consequently the comparator does not reject omission of a trailing
scope exit when all declared variable paths are identical. A synthetic test
records that deliberate semantic boundary; the balanced example is not used
to invent a normative requirement. Scope underflow remains rejected.

Do not generalize arbitrary-ID handling to extended VCD: §18.4.2 mandates
sequential `<0`, `<1`, ... identifiers in module declaration order. Extended
strength/direction records require a distinct oracle, not reuse of four-state
normalization that would erase those obligations.

## Clause-local obligation register

These IDs inventory the reviewed sentences and distinguish independently
observable obligations. They are not a percentage denominator or a completed
input/context cross-product. All simulator behavior below remains open unless
explicitly described as a finite witness. Parser unit tests are tool evidence,
not closure of these language obligations.

| ID | IEEE clause / printed pages | Obligation / evidence boundary |
|---|---|---|
| VCD-001 | 18.1.1 / 325–326 | Explicit filename accepts literal/variable/expression; omitted filename defaults. Existing literal case blocked at `$dumpfile`; other forms absent. |
| VCD-002 | 18.1.2 / 326–327 | Repeated `$dumpvars` calls must execute at the same simulation time. Need legal same-time combination and distinct-time invalid case. |
| VCD-003 | 18.1.2 / 326 | No-argument selection includes all model variables. Not tested by explicit-scope witness. |
| VCD-004 | 18.1.2 / 326–327 | Positive hierarchy depth bounds selection; zero selects all descendants of module arguments. Mixed explicit variable/module list and zero's limited applicability need separate artifacts. |
| VCD-005 | 18.1.3 / 327 | Initial dump starts at end of current time unit. Existing settled-zero checkpoint is a pending witness. |
| VCD-006 | 18.1.3 / 327 | `$dumpoff` emits all-selected-unknown checkpoint and suppresses subsequent value changes. Existing second witness pending. |
| VCD-007 | 18.1.3 / 327 | `$dumpon` emits current values, not last visible values, and resumes changes. Pending second witness distinguishes 0 from old 1. |
| VCD-008 | 18.1.4 / 328 | `$dumpall` emits selected state even unchanged; ordinary dumps omit unchanged variables. Pending second witness includes unchanged checkpoint. |
| VCD-009 | 18.1.5 / 328 | Byte limit stops dumping and records limit comment. No actual artifact witness; metadata now preserved by new oracle. |
| VCD-010 | 18.1.6 / 328–329 | Flush makes buffered data available without losing later changes. Requires an external mid-run reader, not just final-file comparison. |
| VCD-011 | 18.2–18.2.1 / 329–331 | Header/declarations precede changes; timestamps are absolute. Scalar/vector artifacts, not task-name acceptance, required. |
| VCD-012 | 18.2.1 / 330–331 | Four-state codes use printable ASCII; references resolve consistently. New synthetic oracle covers arbitrary/reused codes, not a production writer. |
| VCD-013 | 18.2.1 / 330 | Real serialization has specified precision; strength/memory exclusion. Real and event oracle support still open. |
| VCD-014 | 18.2.1 / 331 | No arbitrary expression/partial-vector dump. Reconcile separate individual-vector-net-bit permission in 18.2.3.7; do not overgeneralize into a ban on all individual net bits. |
| VCD-015 | 18.2.2 / 331–332 | Scalar adjacency, binary prefix adjacency and vector separator constraints. New synthetic invalid scalar-spacing test only; complete lexical matrix open. |
| VCD-016 | 18.2.2 / 331 | Shortest vector encoding and four-state left extension. New oracle tests X10/ZX0/0X10 and rejects redundant zero prefix; actual writer still absent. |
| VCD-017 | 18.2.2 / 331 | Event code occurrence marks trigger, not the numeric value. Explicitly unsupported by new oracle. |
| VCD-018 | 18.2.3.1–3 / 332–333 | Comments/date payload and end-of-definitions record. Metadata presence separate from nondeterministic bytes. |
| VCD-019 | 18.2.3.4–6 / 333–334 | Scope type/nesting and timescale number/unit syntax. Synthetic parser tests support bounded cases; nested simulation witness pending. |
| VCD-020 | 18.2.3.7 / 334–335 | Variable type/width/reference/range declarations, alias IDs and uwire serialized as wire. Aliasing synthetic only; uwire writer case missing. |
| VCD-021 | 18.2.3.8 / 335 | Version identifies writer and dumpfile task; variable/expression filename retains its unevaluated spelling. New metadata API permits independent assertion; no production witness. |
| VCD-022 | 18.2.3.9–12 / 335–336 | Distinct dumpall/off/on/vars sections with their required state semantics. New parser preserves rather than merges checkpoint kinds. |
| EVCD-001 | 18.3 introduction / 338 | Inherit four-state rules unless explicitly changed; do not assume all normalizations carry over. |
| EVCD-002 | 18.3.1 / 338–339 | Scope arguments are unique module identifiers, not variable names or literal strings; select ports at specified scope, not children. |
| EVCD-003 | 18.3.1 / 338–339 | Optional scope defaults to caller; omitted pathname defaults to cwd dumpports.vcd; prescribed overwrite and I/O diagnostics need isolated files. |
| EVCD-004 | 18.3.1 / 339 | Empty/no parentheses accepted for omitted arguments; null first argument requires comma. Positive/invalid grammar matrix open. |
| EVCD-005 | 18.3.1 / 339 | Repeated calls need unique scopes/pathnames and same execution time; coexistence with `$dumpvars` allowed. |
| EVCD-006 | 18.3.1 / 339 | Initial port dumping starts at end of current time unit. |
| EVCD-007 | 18.3.2 / 339–340 | File-specific off/on checkpoints; absent file argument acts on all; redundant already-off/on call ignored. |
| EVCD-008 | 18.3.3 / 340 | Port checkpoint includes unchanged values, optionally all files. |
| EVCD-009 | 18.3.4 / 340 | Required size argument limits named/all files; stop and record limit comment. |
| EVCD-010 | 18.3.5 / 341 | Flush named/all buffers, requiring external observation. |
| EVCD-011 | 18.3.6.1 / 341 | `$vcdclose` records final simulation time even without a final signal change. |
| EVCD-012 | 18.3.7 / 341–342 | Unknown pathname control is ignored; optional-only task forms accept bare/empty parentheses with default actions. |
| EVCD-013 | 18.4.1–2 / 342–345 | Port-only declarations, module scopes, scalar/index size and sequential IDs tied to declaration order. No four-state arbitrary-ID projection allowed. |
| EVCD-014 | 18.4.2 / 345 | Port range preferred over matching net/reg range; scalar fallback; concatenated ports become separate entries. |
| EVCD-015 | 18.4.3 / 346 | Port record prefix adjacency and strength0/strength1 components with numeric strength mapping. |
| EVCD-016 | 18.4.3.1 / 346–347 | Input/output/unknown-direction state character distinctions, including multiple-driver and conflict states. |
| EVCD-017 | 18.4.3.2 / 347 | Driver-kind restriction and relative strength-range resolution. The prose parenthetical labeling strength 5 “large” conflicts with the numeric strength list (5 pull, 4 large); preserve source ambiguity for targeted derivation rather than silently change constants. |

Examples in §§18.2.4/18.4.4 were read as illustrations, not additional mandatory
exact strings. Syntax 18-1's required-looking filename conflicts with nearby
explicit optional-filename prose; derive valid omitted forms carefully rather
than declaring any absent argument invalid solely from the box.

## Results and integration

`python3 -m unittest discover -s tools -p test_vcd_semantics.py` exited 0 with
eleven tests. They exercise alternative printable IDs including `$end` in its
identifier position, ordering/layout equivalence, alias IDs, preserved metadata,
missing required version/comment information, changed values, checkpoint kinds,
case-sensitive IDs, vector extension, same-variable intermediate sequence,
malformed records, explicitly unsupported profiles and both retained snapshots.
An initial synthetic test accidentally concatenated `$end#6` without whitespace;
the parser rejected that malformed test, and the test delimiter was corrected.

Direct current root `vera --run` of both existing VCD source fixtures still exits
1 at `$dumpfile`, E1100 not implemented. No actual generated artifact is thereby
validated. The new parser is not wired into the production gate; main must
integrate separately and decide the artifact-runner interface. Source files
remain positive requirements, not converted to expected unsupported rejection.

Changed paths: this report, `tools/vcd_semantics.py`,
`tools/test_vcd_semantics.py`, both digital VCD fixture headers, and a superseding
section in `ch09_system_tasks/d09_SPEC.md`. Goldens and executable fixture bodies
are unchanged. No compiler/shared harness edit, full build or A/C measurement;
main owns full gates and FAIL/XFAIL name-list comparison. Complete Chapter 18
text review is not semantic/visual or runtime closure of Chapter 18 or measure B.
