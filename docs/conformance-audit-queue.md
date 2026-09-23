# Remaining conformance audit work queue

Assignment checkpoint: 2026-09-23. This is a work queue, not a coverage
measurement or a declaration that unlisted requirements are closed.
The source-review ledger and individual rule/evidence reports remain authoritative
for what has actually been inspected and tested.

The session permits three worker agents alongside the integrating main agent.
Each worker uses its own worktree; patches are reviewed and tested in the main
tree. Queue order does not imply that a whole chapter can be closed in one pass.

| Owner | Active source scope | Next queued scope |
|---|---|---|
| Main | Positive warning observer; file-I/O/display/configuration integration | Remaining Chapter9 and inherited fixture handoffs; atomic obligation reconciliation |
| Worker `audit_ch5` | IEEE17.2.9 memory-load warning/range repair | Primitives, Clause4/5/9/11/16 handoffs await integration |
| Worker `audit_ch6` | IEEE26.6 object-diagram continuation | Clause10/19/20/26 handoffs await integration; phase-correct host probes remain blocked by missing APIs |
| Worker `audit_ch7` | Remaining IEEEAnnexA grammar | Clause3/14/15/28 and AnnexB handoffs await integration |

Every scope includes source-to-HTML corrections, rule-level evidence review,
and targeted behavioral/invalid-input tests where an executable path exists.
Missing simulator or host facilities remain open obligations, not exclusions.
Compiler acceptance alone does not close a behavior requirement. Existing
chapter reviews, including Chapters 2–8 and 10 and Annexes B–D, still need their
recorded residual gaps and atomic-rule completeness checked; a first source
reading does not certify exhaustive tests.

Workers hand off coherent patches with exact source pages, fixture derivations,
known limitations and local checks. Main verifies outcomes, compares exact
FAIL/XFAIL names, and uses `tools/conformance.sh` for measures A and C.
Newly discovered defects are recorded explicitly rather than counted as closed.

Latest completed gate checkpoint includes Chapter12, Annex E/F/G/H, the bounded
VCD semantic comparator, AnnexA and the digital-negative runner plus inherited
time/plusargs/math/scope batches. The digital-negative strict name list matched
its AnnexA predecessor. Main unit gate passed; new digital failures are recorded
in the inherited-task report. `docs/conformance-measurement.md` was generated
from the subsequent scan/minmax/wait strict and coverage logs. That checkpoint's
unit gate passes and strict failure-name membership is unchanged from math-fixes.
The digital failure list remains identical to the PLA/queue/control baseline,
with all new scheduling witnesses passing. The earlier math checkpoint removed
only the wide-clog2 failure. The digital gate remains
failing; no whole-language conformance claim follows from this checkpoint.

Subsequent Chapter9 HTML/figure integration passed all source-document Python
guards; regenerated figures 9-1 through 9-4 matched the reviewed worker crops
byte for byte. The math typing and wide-clog2 repairs are measured. Scanner
destination preservation, min/max derivative selection and constant-wait fixes
are integrated with root runtime checks and completed full gates. Remaining
strict/digital failures are explicit debt, not a green conformance claim.
Chapter6 source figures are integrated with reproduced crops. The PLA/queue/
control-time digital batch adds the explicitly recorded legal-input failures;
it does not bless unsupported behavior as passing rejection evidence.

Pending handoffs are not presumed applied. Remaining Chapter9 fixture groups,
Chapter4 function evidence, and inherited file-I/O/UDP/task/assignment batches
still need root integration and fresh gates. A finite regression suite,
static clause citations and first-pass source reads do not establish an
exhaustive atomic-rule denominator.

## Remaining inherited source traversal

Read-only cross-report inventory by worker `audit_ch7`, 2026-09-23, includes
unintegrated worker handoffs. These are source-review boundaries, not closed
obligations or measured coverage. Main has not independently reread every
source scope in this inventory.

| Scope | Remaining source-review work |
|---|---|
| IEEE1–2 | Atomic authority/dependency dispositions; Clause1 text traversal is recorded, not complete visual/obligation accounting. |
| IEEE3 | Only escaped-identifier dependency had a complete inherited read; remainder now assigned. AMS Chapter2 is not a substitute. |
| IEEE4 | Outside bounded4.8 and4.10.1/.2 dependencies, datatype chapter traversal remains open. |
| IEEE5 | Equality, bitwise, reductions and conditional dependencies read; remaining operators, operands, min:typ:max, widths, signed evaluation and truncation require complete accounting. Prioritize5.4–5.6. |
| IEEE9 | Remaining9.1,9.2.1,9.4–9.6,9.7.1–.4/.7 and9.9.1/.2. NBA, procedural-continuous, implicit sensitivity/wait and blocks have separate bounded reviews. Prioritize intra-assignment timing. |
| IEEE12 | Worker reports together traverse chapter text; latest12.3–12.5 report and evidence still await integration. No whole-chapter behavioral closure. |
| IEEE16 | Currently assigned. Full SDF grammar references IEEE1497-2001, not supplied; source dependency remains open. |
| IEEE17.1 | Remaining display subsections/formats beyond field sizing and full strobe/monitor dependency reads. |
| IEEE19 | Remaining19.4–.7 and19.9–.11; full inherited directive review cannot be inferred from AMS Chapter10. |
| IEEE20,26,27,AnnexG | Full inherited PLI/VPI source traversal, atomic obligations and executable host/ABI witnesses remain open beyond bounded AMS reviews. |
| IEEE28 | Protected-envelope source review and mandatory/optional capability distinctions remain open. |
| IEEEAnnexA/B | Full inherited normative grammar/keyword review; selected syntax boxes and AMS annexes are partial cross-reference evidence. |
| Other IEEE annexes/removed clauses | Informative C/D/H/I need disposition; removed21–25/E/F require explicit applicability and historical-dependency decisions, not invented requirements. |

Full-text worker/root reports exist for6–8,10–11,13–15,17.2–17.11 and18.
Every one still records open behavioral, diagnostic, cross-product or host
requirements. In particular,17.9 already includes a full algorithm-source read;
do not repeatedly queue it as unread. Clause18's synthetic VCD comparator is
not live production artifact evidence. Reading a whole chapter is one audit
stage, not evidence that its atomic denominator or tests are exhaustive.

Subsequent worker handoffs now record full IEEE3 and16 source reads and the
bounded5.4–5.6 expression review. They remain unintegrated evidence, not automatic
closure of the inventory rows above. The IEEE12 and13 reports are now retained
at root with explicit pending-fixture boundaries. The current root batch repairs
codegen failure reporting and multi-bit continuous-assignment delay selection;
unit/source guards and targeted transcripts pass. Final strict/digital/coverage
runs follow the digital-negative routing correction. The measurement script
completed successfully against `/tmp/vera-status-vector-final-{strict,coverage}.log`
and replaced `conformance-measurement.md`. Unit gate passes; digital gate remains
failing. Strict adds only the new maxdelay XFAIL versus scan/minmax/wait, and the
digital list adds the seven newly exposed assignment/task-disable obligations.
Every pre-existing FAIL/XFAIL name is preserved.

The subsequent root batch integrates UDP and hierarchy fixtures, repairs
UDP transition-count validation and empty named-parameter defaults, and makes
the expression shift oracle independent of native integer width. Expression
width fixtures are integrated too. Targeted parser/elaboration checks and the
explicit analog executable observations pass. Full unit gate passes; strict
FAIL/XFAIL names are identical to status/vector. Digital additions are precisely
the new expression/hierarchy/UDP legal positives. The measurement script exited
zero using `/tmp/vera-udp-parameter-{strict,coverage}.log`; its generated file now
records that completed checkpoint. The empty-localparam control
is outside the fixture intake with its interpretation explicitly unresolved.

The next unmeasured batch adds file-I/O/display/configuration fixtures and a
positive digital warning observer. Memory count mismatch is being repaired as
a warning with continued loading, not the previously asserted error. Header-only
warning matching has a passing focused test. The two hierarchy port fixtures
now suppress default finish statistics so exact stdout observes their intended
behavior only. Fresh full gates follow compiler integration.

Latest source-traversal supersession: worker reports now include full inherited
Clause3–5, residual9,16,17.1,19,20,28 and AnnexB readings. This supersedes earlier
unread-scope rows only for their named subsections; integration/evidence remain
separate. Clause26 source is reviewed through26.6.6, with26.6.7 onward active;
Clause27 and AnnexG remain substantially unreviewed beyond selected dependencies.
IEEEAnnexA A.1–A.5.4 handoff is ready and its remaining productions/details are
under review. IEEE2005 ends atA.9.4 plus unnumbered Details1–5, unlike AMSA.10.
Chapters1–2 and informative/removed annex applicability still need reconciliation.

Latest handoffs supersede those traversal boundaries: IEEEAnnexA text and all
source pages are reviewed through A.9.4 and unnumbered Details1–5 in the worker
report; root integration remains pending. IEEE26.6 graph review reaches26.6.12;
remaining graphs are assigned. Workers now cover remaining26.6, Clause27, and
AnnexG separately in their own worktrees. None of these handoffs establishes
atomic-rule or executable host closure.

The memory-load implementation is now integrated: W1150 observes address-free
count mismatches while retaining loaded values; explicit file addresses outside
the requested task range produce a distinct error. Root focused readmem tests
pass (three discovered tests). The pre-fix digital baseline exited one and adds
only the seven newly introduced file-I/O/display/configuration obligations to
the prior failure-name list; all prior failure names are preserved. Source
guards pass (32 tests). Fresh unit and digital gates are running against the
integrated implementation; no new A/C measurement is claimed yet.

Root readmem follow-up: the unit gate exits zero. Digital exits one; exact
FAIL/XFAIL name comparison against the pre-fix baseline removes only the
historical overflow positive and adds no failures. Newly added memory-load
fixtures pass. Strict is running in `/tmp/vera-readmem-strict.log`; no measure
is updated until that run and coverage are complete.

The primitive and completed IEEE grammar reports are now retained at root as
`conformance-ieee-primitives-review.md` and
`conformance-ieee-grammar-review.md`. Their new fixtures remain unintegrated
while the checkpoint runs. Main independently checked the strength-reduction
rules and the empty-port grammar derivation; full worker source traversals
remain attributed as worker evidence, not duplicated main certification.

Main completed text traversal of IEEEClauses1–2 and retained authority and
dependency dispositions in `conformance-ieee-authority-review.md`. Visual
verification and rule-level dependency/profile reconciliation remain open.
Notably, IEEE1497-2001 is a Clause16 bibliography reference, not a Clause2
normative-reference entry; its unresolved SDF source role is recorded without
silently expanding or excluding the required behavior.

The readmem strict run has now finished (exit one): exact name comparison
against the UDP/parameter checkpoint removes only the old overflow row and
adds no failures. That row's intake migration is distinguished from the
positive digital warning/value evidence in the fix report. Coverage exits
zero. `tools/conformance.sh` is generating the new checkpoint from these logs;
its own gate results must still be checked before calling it measured.

Measurement generation completed successfully from the readmem logs and
replaced `conformance-measurement.md`. Its unit gate passes and digital gate
remains failing. This supersedes the UDP/parameter measurement, without
claiming that static citation coverage is verified rule coverage.

Next batch integrates primitive and grammar witnesses and fixes inaccurate
legacy headers without changing their executable expectations. Source guards
pass (32 tests); root unit gate exits zero. Digital exits one: exact failure
membership adds only the newly exposed grammar parameter-header, primitive
array, bidirectional tran, ambiguous-strength and pull-polarity obligations.
No pre-existing failure name changes. The remaining new cases pass. Logs are
`/tmp/vera-primitives-grammar-{unit,devices}.log`. Strict is running; the
generated measurement still belongs to the completed readmem checkpoint.

The primitive/grammar strict run has completed with failure-name membership
identical to the readmem checkpoint. Coverage exits zero. Measurement is being
regenerated from `/tmp/vera-primitives-grammar-{strict,coverage}.log`.
AnnexG review, symbol inventory and compile probes are now integrated:
root reproduces three passing extractor tests and the baseline-pass/six-fail
required-positive header results. Informative/deprecated applicability review
is retained too; the normative reset API's dependency on informative C.7
remains explicitly in scope. No runtime VPI closure follows from these tools.

Primitive/grammar measurement generation completed successfully: unit pass,
digital FAIL, and A/C unchanged from readmem. The next unmeasured batch
integrates readmem start-only arguments and formfeed separators. Header
compatibility fixes are being prepared in the worker worktree; root header
and its reproduced AnnexG inventory remain unchanged at this checkpoint.

Readmem start/formfeed root unit gate passes; both new digital fixtures pass,
with exact pre-existing failure membership unchanged. The following task and
function batch integrates eight fixtures plus legacy-header corrections;
digital adds only those eight expected unsupported-context/specific-diagnostic
failures. Existing bodies/expected transcripts are unchanged. Header repair is
also integrated: signed vector fields, shared guard, mutable name declaration
and alias provenance. Strict C/C++ checks pass for the repaired interface;
missing strength/callback/value APIs remain failed required-positive probes.
The symbol inventory is regenerated against the repaired header. Combined
unit/strict gates are running; the last generated measurement still describes
the primitive/grammar checkpoint.

The combined task/header unit gate now passes; coverage completes successfully
and strict remains running. IEEE20/26/27 reports are retained at root, including
all26.6 object-diagram source-review installments. Their host probes still
await integration and real host execution. Main identified an equal-current-
value event-handle assumption in the Clause27 cancellation probe and records
its required distinct-value replacement before accepting that oracle. Source
review completion is not promoted to behavior or atomic-denominator closure.

Task/header strict completed with failure-name membership identical to the
primitive/grammar checkpoint. Measurement generation is running from
`/tmp/vera-task-header-{strict,coverage}.log`. The existing VPI compile runner
has a recorded pre-integration baseline in `/tmp/vera-ieee-pli-before.log`.
Pending host probes will enter compile-only visibility separately from actual
simulation evidence; paired HDL must not be scored independently.

The draft machine-readable rule ledger is under main review, not yet integrated.
Review found that digital fixture context had been used to exclude the
underlying memory-load obligations from Verilog-A. That inference is rejected:
source applicability must be established independently of evidence selection.
Uncertain analog applicability remains unresolved. The address-digit case
rule also needs an explicit upper/lower-case discriminator before handoff.

The task/header measurement script completed successfully (unit pass, digital
FAIL); generated A/C remain unchanged. The corrected rule-ledger candidate,
validator and tests are now integrated: structural validation and all15 tests
pass. Verilog-A applicability remains unresolved; independent completeness
review remains pending. The inherited host probes are also integrated and
visible to the existing compile-only VPI runner. Its exact failure-name diff
adds only the eight new clients, preserving all earlier failures. No callback
was simulated and no new runtime coverage is claimed by that compile census.

The ledger/PLI unit gate passes. Validator follow-up adds conflict and blank-
artifact safeguards; all17 validator tests pass. Four residual IEEE11 scheduling
witnesses are now integrated with their source-reviewed report, including an
allowed-result-set race oracle rather than a fixed active-event ordering.
Fresh digital comparison is running. Independent workers are reviewing the
readmem decomposition and building bounded AMS min/max and lexical candidates.

The scheduling digital comparison adds only its indexed-blocking-target and
timed-task positives; its constant-port and permitted-race witnesses pass.
The next batch integrates the IEEE datatype report and five fixtures, including
complete equal-strength two-driver table cells and a uwire legal/invalid pair.
New digital and strict/coverage runs are active under `/tmp/vera-types-*.log`;
the generated measurement still describes the completed task/header tree.

Datatype digital comparison adds only the negative-bound and multidimensional
array positives; equal-strength table cells and the uwire pair pass. Ledger
validation now also requires an explicit PDF-to-HTML mapping, separating direct
text from inherited reference. Missing/unresolved mappings cannot be verified.
The seed maps IEEE memory rules to AMS9.1 incorporation without claiming those
rules are fully transcribed there. All19 validator tests pass; no seed row is
verified and source completeness remains pending.

Independent readmem source review is integrated: Table9-2/C.11/C.7 now resolve
the execution-profile exclusion, without changing partial/open statuses or
HTML incorporation traces. Decomposition/diagnostic/warning-evidence cautions
remain open. The bounded AMS min/max candidate and review are also retained;
all20 ledger tests pass, including validation of every retained candidate.
Datatype/PLI strict finished with the same failure-name list as task/header;
measurement generation is running from `/tmp/vera-types-pli-*` logs.

That datatype/PLI measurement generation has now completed: the generated
report records unit pass and digital FAIL. Strict failure-name membership is
unchanged from task/header. The report, not a handwritten percentage here,
is the authority for A/C.

The bounded AMS lexical candidate is integrated, still without verified rows.
Optional ledger HTML-link validation checks real anchors and rejects paths
outside the specified root; all23 validator tests pass at this checkpoint.
Independent lexical decomposition review is assigned separately. The escaped
identifier normalization repair and four digital witnesses are now integrated;
focused parser tests pass, while full root regression gates are in progress.

Escaped-name gates subsequently completed: unit pass; digital and strict
FAIL/XFAIL name lists identical to their datatype baselines. Direct execution
of the four new lexical cases matches exact transcripts with empty stderr;
the patched analog escaped-period regression has both checks ok=1. Coverage
has completed and measurement generation is running from the escaped logs.

The independent lexical-ledger review is retained. Its corrections explicitly
separate source token categories from compiler-internal token representations,
pin terminator evidence per transcript field, and limit whitespace movement
to preserved token boundaries. Remaining collision, escaped-length, legal-
neighbor and tab-position witnesses are assigned. All23 ledger tests pass;
completeness remains pending. The readmem reviewer has identified malformed
high-order input hidden by destination-width truncation and owns that repair
in an isolated worktree. No new runtime closure is inferred from these reviews.

Syntax2-1 typography is now repaired after main inspected physical24: only
literal comment delimiters are bolded, not newline notation or repetition/
alternative symbols. All33 source-document tests pass. Two additional digital
identity fixtures are integrated and pass exact transcripts with empty stderr:
punctuation collisions and escaped1024-character final-position distinctness.
Their bounded cases are linked in the lexical ledger, still partial; all23
ledger tests pass. Legal-neighbor/tab fixtures and the readmem validation repair
are ready in worker handoffs but are not yet integrated.

The first escaped measurement invocation completed, but reused strict logs
lacked the script's exit marker and therefore displayed unknown strict status.
The actual process status was1 (observed from the original process handle).
That explicit status is now recorded in the log; measurement regeneration is
running. The new identity fixtures affect the digital run only, not the reused
analog strict/coverage inputs. No source/fixture percentage is entered by hand.

Measurement regeneration completed successfully with the actual strict exit1
recorded. Unit passes and digital remains failing; the generated report retains
the same A/C readings. Main subsequently reviewed and integrated the minimal
readmem full-token validation repair; its root focused tests are running.
Associated fixture/report handoffs and rebuilt-CLI/full regression checks remain
pending, so the generated measurement still describes the escaped checkpoint.

The readmem diagnostic/repair reports and full new warning, malformed-input
and legal-control batch are now integrated, as are the lexical comment-neighbor
and literal-tab fixtures. Root readmem focused tests pass. Rebuilt CLI observes
the required errors for the formerly accepted forbidden prefixes/high invalid
digits, while valid oversized data still passes. Full digital failure names
are unchanged; unit/strict/coverage runs are active under readmem-token logs.
Ledger diagnostics cite IEEE1.2(a) without inventing mandated CLI termination.

Readmem-token unit and coverage now exit0; strict exits1 and its failure-name
list is identical to escaped. The three new analog lexical fixtures pass and
their explicit executable runs show all five checks ok=1. Their ledger cases
now include actual root observations, remaining partial. Measurement generation
is running from the completed readmem-token logs. The next source-derived
readmem audit identifies separate question-mark, underscore and excess-token
validation obligations; these are not claimed fixed by the preceding repair.

Readmem-token measurement generation completed. The generated report now
includes the three passing analog lexical additions and their citation effects;
strict failure-name membership remains unchanged, unit passes, digital fails.
The remaining IEEE expression/operator fixture batch is subsequently integrated
and its full digital run is active. Its expected source-derived failures are
kept visible rather than classified as valid implementation refusals.

Expression/operator digital comparison adds only the two source-reviewed legal
failures for min:typ:max expression context and numeric strings; all prior names
are preserved. The attributes candidate/report is now integrated, all rows open
and completeness pending. Three existing fixture headers no longer claim that
unchanged arithmetic verifies default/last-wins/report semantics or universal
attribute inertness; those claims move to explicit ledger obligations without
changing fixture bodies. All23 ledger tests pass.

String-literal candidate/report integrated with independent review pending.
Review identified a2.7 single-line versus AnnexA.8.8/AnnexG2535 conflict; the
candidate now marks that rule ambiguous rather than certifying rejection.
No existing multiline fixture or compiler behavior was changed on that basis.
Readmem edge repair and controls are integrated; nine focused tests pass,
full root gates are active. These new changes are not yet in the generated
measurement, which remains the completed readmem-token checkpoint.

Readmem-edge direct rebuilt-CLI observations now pass: question-mark z values,
legal underscore/address/excess controls, and required malformed-input errors.
Full digital names remain identical to expression/operator; unit now exits0,
strict remains running. The ledger guide now lists each retained candidate and
its scope limits. Attribute follow-up links mandatory3.2.1 output-variable
access separately from optional parameter help and corrects none/absent scaling
discriminators. All23 ledger tests pass; no new verified status is claimed.

Readmem-edge strict subsequently finishes with identical failure names, and
measurement generation completes. Independent string/attribute reviews are
retained with concrete corrections and unresolved source conflicts. Optional
evidence-file authentication now hashes explicit fixture/runner/artifact paths,
rejecting missing/changed/escaping bundle files. All26 validator tests pass;
the current readmem candidate authenticates zero bundles (its partial historical
records are not silently upgraded). No row is promoted to verified.
