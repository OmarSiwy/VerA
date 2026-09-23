# Verilog-AMS conformance audit

Status: **in progress; the requirement denominator is not yet certified**.
Parallel assignments and residual source scopes are recorded in
[`conformance-audit-queue.md`](conformance-audit-queue.md).
The [Chapter 1 review](conformance-introduction-review.md) records its source
figures, notation conventions and rule-specific diagnostic corrections.
This is the rule-level audit requested on 2026-09-23, clarified by the user to
target **full Verilog-AMS**, with Verilog-A as a separately tracked profile.
Its source is the
checked-in `VAMS-LRM-2023.pdf`, not the compiler's present behavior.

The completion criterion is coverage of every applicable normative obligation,
including grammar alternatives, table entries, numerical conditions, state
transitions and interactions. Passing a finite test suite cannot logically prove
correctness for every possible program or continuous waveform. The deliverable
is a reviewable requirements inventory with discriminating executable evidence,
explicit residual uncertainty, and no silently excluded requirements.

## Scope and authority

The HTML must faithfully represent the entire supplied AMS PDF. The primary
**Verilog-AMS profile** includes analog, digital, mixed-signal, VPI and inherited
IEEE 1364 obligations. The separate **Verilog-A profile** is selected by normative
Annex C. Do not use a subset exclusion to discharge an AMS obligation.

`ROADMAP.md` and `CLAUSE-AUDIT.md` also target full AMS. Their historical results
are not measurements of the separate Verilog-A profile, nor a certified
rule-level completeness result. `CHANGELOG.md`, `ARCHITECTURE.md` and `TODO.md` are
absent from the current tree; their last pre-deletion versions were read at
`297e97d^`. The old audit recovery object `55e5117` is unavailable in this clone;
the restored `docs/CLAUSE-AUDIT.md` is available and was read instead.

The following table selects the Verilog-A profile only; the excluded behaviors
remain requirements of the full AMS profile.

| Source | Verilog-A applicability decision |
|---|---|
| C.3 | Clause 2 applies with the stated mixed-signal x/z limitations; all AMS keywords remain reserved. |
| C.4 | Clause 3 applies subject to the discrete-domain, wreal and default-discipline exceptions. |
| C.5 | Clause 4 applies except case equality/inequality. |
| C.6–C.7 | Analog signals and behavior apply; digital behavior/events and casex/casez do not. |
| C.8 | Hierarchy applies except real-valued ports of 6.5.3. |
| C.9 | Clause 7 is AMS-only. Its analog-independent dependencies still require examination when referenced elsewhere. |
| C.10 | Analog simulation cycle applies; mixed-signal scheduling does not. The source's reference to 8.2 must be reconciled with that chapter, not silently rewritten. |
| C.11–C.12 | Analog-context Clause 9 tasks/functions and Clause 10 directives apply, subject to specific Annex C exceptions. |
| C.13–C.14 | Analog VPI behavior applies. A source-only compiler test cannot discharge a C API or callback obligation. |
| C.15–C.16 | Annex A supplies grammar; Annex B keywords remain reserved even when their constructs are excluded. |
| C.17 | Annex D applies with its explicit instruction to silently ignore discrete discipline definitions. Reconcile this with C.4's error rule when constructing individual cases. |
| C.18 | Annex E applies, with its own conditional compatibility and implementation-dependent clauses. |
| C.19–C.20 | Annex G describes history/removals; identify the present normative rule instead of treating historical prose as an independent requirement. |

IEEE 1364-2005 is incorporated by reference (1.1, 2.8.3, 9.1 and other
clauses). The user supplied a licensed copy on 2026-09-23, now available locally
as `docs/1364-2005.pdf` and excluded from Git. Its provenance, edition and
review status are recorded in [the inherited-source audit](conformance-ieee1364.md).
Source acquisition is resolved; individual inherited obligations remain
**unreviewed** until their normative text and executable evidence are examined.
The historical §§17–18 table is a lead, not the entire inherited surface.

The [IEEE authority review](conformance-ieee-authority-review.md) records
edition, normative/informative and external-reference rules. The
[informative-material disposition](conformance-ieee-informative-disposition.md)
preserves normative dependencies such as VPI reset behavior even when their
referenced description occurs in an informative annex. The
[Annex G header review](conformance-ieee-annex-g-review.md) and reproducible
[symbol inventory](conformance-ieee-annex-g-symbols.md) distinguish declaration
presence, C type compatibility and runtime semantics. Required-positive C
clients that fail compilation remain open obligations; they are not successful
invalid-input tests and are not included in the HDL citation measure.

Source acquisition check, 2026-09-23: the
[official IEEE 1364-2005 entry](https://standards.ieee.org/ieee/1364/3641/)
offers purchase/subscription access; the
[IEEE Xplore record](https://ieeexplore.ieee.org/document/1620780) returned a
browser-verification page to this session. No normative IEEE text was obtained
from those pages. The subsequent user-supplied copy resolves this acquisition
gap without relying on the inaccessible web text. Do not
substitute a newer SystemVerilog edition for the edition incorporated by VAMS.

## What the measures mean

Measure A still measures whether fixtures behave as their own expectations say.
It does not certify those expectations or the completeness of the test set.

Measure C is a **static clause-citation inventory**. `--coverage` reads headers
without compiling or running fixtures. XFAIL fixtures contribute citations;
rejections of legal-but-unsupported features contribute rejection citations.
One positive and one rejection citation can leave other rules within the same
clause entirely untested. The report and `tools/conformance.sh` now label this
precisely. The numerator/denominator algorithm is unchanged by that relabeling.
Only `tools/conformance.sh` writes A/C measurements.

Measure B's inherited-source audit remains necessary, with analog/digital
applicability recorded separately. Measure D tracks project architecture; it is
not a language-conformance obligation.

The new rule ledger is incomplete. **Do not publish a rule-conformance
percentage while source review or rule enumeration remains open.** A heading
count, a search for `shall`, or a count of passing files is not its denominator.

The ledger guide lists the retained bounded candidates and their review limits,
including lexical, string and attribute rules. A row marked ambiguous is an
unresolved source interpretation, not permission to select whichever behavior
the compiler currently implements. In particular, the string single-line rule
must be reconciled with AnnexA.8.8 and the source's change-history entry.

Initial [machine-readable ledger infrastructure](conformance-rule-ledger.md)
now retains a candidate IEEE17.2.9 decomposition, explicit source locators,
oracles, applicability and evidence limits. Its validator checks structure,
not source truth or runtime success. The candidate's independent completeness
review remains pending; no denominator is certified. Readmem's Verilog-A
exclusion is now source-resolved by Table9-2, not inferred from the runner.
The [min/max candidate](conformance-minmax-ledger-review.md) adds a bounded
AMS-native decomposition, with finite-value/type/derivative cases separated
from unresolved nonfinite behavior and unexecuted external-host observations.

## Evidence required for each rule

Each rule needs a stable ID, source clause and PDF page, the exact source
passage/table/grammar arm, a paraphrased obligation, profile applicability with
reason, and an obligation class. Split compound requirements and enumerate
branches of tables and grammars. Preserve cross-references and preconditions.

For every mandatory behavior record legal cases, boundaries, applicable analysis
modes, relevant parameter/instance/state transitions, the expected observable
with independent derivation, fixture path, assertion or transcript location,
runner, source revision, and actual result. Also record a plausible wrong
implementation that the assertion distinguishes; validate that discriminator
with a controlled mutation where feasible. A passing unrelated assertion,
compile-only check, or failure before the targeted feature earns no behavioral
credit. A kernel unit test alone does not establish compiler-to-host behavior.

For a prohibition, isolate the invalid construct and verify the relevant
diagnostic. Exercise a legal neighbor to distinguish a correct restriction from
blanket refusal. A rule with no invalid form does **not** need an invented
rejection; record why that evidence direction is inapplicable.

Keep these dispositions distinct:

- **Mandatory:** all identified cases need passing, discriminating evidence.
- **Optional:** cite the permission; test semantics if the feature is provided.
- **Implementation-defined:** cite the latitude, publish the choice, and test it.
- **Unspecified:** check only the permitted outcome set or invariant, not an
  arbitrary preferred outcome.
- **Resource limit:** document the bound and test the boundary/failure behavior;
  a loud refusal does not automatically make a limit allowed by the standard.
- **Informative or outside profile:** cite the reason; do not inflate verified
  behavior with these rows.
- **Ambiguous or missing source:** keep open with the competing readings.

A host obligation stays in scope even when VerA exports the right metadata.
Transient rollback, adaptive event placement, AC/noise response, analysis
restarts, report attributes and analog VPI require an appropriate host oracle.
Pairing a SPICE deck with a JSON file or compiling a C test is not execution.

For fixed-workload behavioral fixtures, `//! checks N` pins the exact total
number of runtime `ok=` observations. Use a positive integer derived from the
fixture's assertions and declared points, not an observed buggy transcript.
Missing or extra observations fail; the directive is incompatible with rejection
fixtures. It is not a count per timepoint and does not infer coverage from source
macro count. Without this directive, the historical runner still only requires
a nonempty passing transcript. A verdict must now be the whole token `ok=1`,
not merely start with it (`ok=10` and `ok=1garbage` fail).

## Source review workflow

`python3 tools/lrm_audit.py` builds a section worklist directly from the PDF
and HTML. `--section 2 --diff` shows token differences; `--json` preserves the
extracted text and physical PDF page anchors for review. It requires Python's
standard library and Poppler's `pdftotext`.

The comparison is deliberately conservative. Equal text tokens are only text
evidence: superscripts, subscripts, diagram connections, table columns and
typography that defines grammar can change semantics without changing those
tokens. Differences include list markers, table continuation captions, PDF
extraction artifacts and labeled editorial notes as well as real defects.
Review equations, figures and tables against rendered PDF pages. Do not
auto-repair or auto-certify from token differences.

The extractor is specific to this edition; missing/extra headings are review
items, not automatic verdicts. The source hash and review records live in
[the source-review log](conformance-source-review.md). Detailed obligation
worklists start with [Chapter 2](conformance-lexical.md). Neither is a substitute
for reviewing the remaining chapters.

The [absolute-delay worklist](conformance-delay.md) demonstrates the operator-level
split between argument validity, time-domain behavior, frequency-domain behavior
and host lifecycle evidence. Those cannot be closed by one passing ramp fixture.
The [keyword worklist](conformance-keywords.md) tracks the complete Table B.1
spelling inventory separately from identifier-context and construct behavior.
The [standard-definitions worklist](conformance-standard-definitions.md) separates
public macro values from include guards, selector branches and nature metadata.
The [macro worklist](conformance-macros.md) expands inherited IEEE §19.3 into
individual behaviors and records source-backed defects, including a unit-test
expectation that contradicts the standard.
The [data-type worklist](conformance-types.md) distinguishes initialization
contexts, declaration syntax and internal-value tests from host export evidence.
The [parameter worklist](conformance-parameters.md) separates declaration
errors, inferred types, override paths and instance-value range checking.
The [genvar worklist](conformance-genvars.md) separates static controls and
iteration evidence from inherited digital generation and operator-state history.
The [nature worklist](conformance-natures.md) separates attribute validity and
inheritance from access-function, compatibility and solver-tolerance evidence.
The [nodeset worklist](conformance-nodesets.md) separates initial-guess use,
null preservation, non-clamping and hierarchical precedence, and limits
solver-specific root expectations to the harness policy they actually test.
The [real-net worklist](conformance-wreal.md) separates full-AMS wreal behavior
from the analog profile's exclusion, and fractional output from precision proof.
The [branch worklist](conformance-branches.md) separates branch identity and
port-flow observations from voltage arithmetic, grammar and namespace checks.
The [expression worklist](conformance-expressions.md) separates conversion,
precedence and observable evaluation effects from representative arithmetic.
The [hierarchy review](conformance-hierarchy.md) records the parallel Chapter 6
source pass, bounded repairs, remaining transcription gaps and weak fixture
claims. Its proposed repairs are not presumed applied or behaviorally verified.
The [analog-behavior review](conformance-analog-behavior.md) records Chapter 5
source discrepancies, integrated figure corrections and event-oracle
risks. Its source inspections are not fresh runtime conformance verdicts.
The [mixed-signal review](conformance-mixed-signal.md) records Chapter 7's
local-discipline, node-tolerance and host-mode evidence gaps, alongside integrated
figure and grammar repairs. Corrected local-discipline fixtures expose defects;
they are not closure.
The [Chapter 9 review](conformance-ch9-review.md) distinguishes source binding
from host override policy and runtime conversion from constant evaluation.
The [VPI source/evidence review](conformance-ch11-review-draft.md) records
Chapter 11 diagram transcription defects and false API-coverage claims in
HDL-only fixtures. Its source/metadata patch is integrated; the report explicitly
separates startup-time host execution from untested simulation callbacks.
The [VPI routine review](conformance-ch12-review-draft.md) records Chapter 12
source anomalies and the withdrawn API claims in HDL-only tests. Its linked
required-positive probes explicitly expose missing capabilities as XFAIL;
callback scheduling, solver interaction and most routine boundaries remain open.
The [Annex E/F review](conformance-annex-ef-review-draft.md) records SPICE
source ambiguities, primitive-attribute validity/ignore boundaries and untested
discipline-resolution mode selection. The [informative-annex review](conformance-informative-review.md)
separates history/glossary fidelity from current normative requirements and
withdraws phantom glossary terms from the old coverage ledger.
The [Annex A review](conformance-annex-a-review.md) separates presentation
grammar, lexical restrictions and observable semantics. Its corrected legacy
library-map claim and timing-event negatives demonstrate why parser acceptance
and clause citation counts cannot define the conformance denominator.
The [VCD review](conformance-vcd-review.md) supplies a bounded semantic artifact
comparator and retains required metadata separately from run-varying strings.
Its synthetic tests are not simulator evidence; production artifact execution
and real/event/extended formats remain open.
The [inherited task review](conformance-ieee-tasks-review.md) records time-query
and command-line obligations, including an explicit digital diagnostic runner.
The [inherited math review](conformance-ieee-math-review.md) separates unsigned
and wide-vector semantics, constant evaluation and real-valued execution.
The [scope/elaboration review](conformance-ieee-scope-review.md) distinguishes
legal lexical shadowing from masked defparam diagnostics and records the
remaining inherited-source inventory.
The [scheduling worklist](conformance-scheduling.md) distinguishes prescribed
voltage arithmetic from solved-node evidence and records host-level gaps.
The [monitor worklist](conformance-monitor.md) separates inherited digital
event triggers from analog accepted-step comparisons, with isolated transcripts
for setup, time exceptions, transient changes and enable-state behavior.
The [display-format worklist](conformance-display.md) records exact-text
evidence separately from numeric round trips and flags source/fixture issues
in general-format precision and default integer field widths.

## Execution checkpoint, 2026-09-23

Base revision: `5c099cfdb3a9cb62bcf1b0185e96daf4194446e0`, plus this audit's
uncommitted documentation, harness-label and fixture changes. This is not a
release or a complete conformance claim.

[`conformance-measurement.md`](conformance-measurement.md) was generated by
`tools/conformance.sh`, using the completed strict and static-citation logs;
the script reran the unit and digital gates. B/D rows are unfilled template
rows, not newly verified results. The strict suite exits 1; the unit gate passes;
the digital gate fails. The new unsized four-state digital test exposes a legal
construct refused with E1100. Its failing expectation was not weakened.

The original combined strict logs lost leading diagnostics when the build
driver wrote its own failure summary. An empty extracted name list is invalid
regression evidence, even when `diff` exits 0. To recover the baseline, the
untouched `HEAD:tests/fixtures` tree was extracted into a temporary directory
and run with the cached pre-change suite executable and unchanged compiler,
using `--fixture-root=... --strict`. The current fixture tree was then run
directly with the current suite executable. Stdout and stderr were captured
separately, without the build driver. Both runs exited 1. Normalized, sorted,
**nonempty** FAIL/XFAIL name lists are identical. This establishes no new
strict-suite failure membership; it is not a claim that the digital suite or
the full language conforms.

The source-worklist regression tests pass with
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p test_lrm_audit.py`.
The nonuniform delay fixture also detects two isolated mutations of generated
interpolation code; details and actual observations are in the delay worklist.
Source enumeration, inherited-source review and most rule-level evidence remain
open. Do not treat this checkpoint as closing the completion gate below.

The subsequent source-fidelity/keyword pass restored the Chapter 3 and Chapter 4
figures listed in the source-review log, checked Annex B against both rendered
PDF pages, and added complete escaped/case spelling fixtures. The regenerated
figure assets are byte-identical on a repeat extraction with the same Poppler
installation. Python audit tests and the Zig unit gate pass. A fresh full strict
run after the expected-check-count and verdict-token changes still exits 1;
its nonempty normalized FAIL/XFAIL name list is identical to the preceding
checkpoint's list. Both new keyword fixtures pass. The measurement file is
regenerated by `tools/conformance.sh`; source fidelity and keyword-context gaps
remain separate from its A/C counters.

The subsequent Annex D/inherited-source pass obtained the user's licensed
IEEE PDF, recorded its hash and review boundaries, and added a reproducible
heading worklist. The new physical-base-name fixture passes; the Annex D-only
strict run exits 0. A full run after that addition preserved the preceding
nonempty failure-name list. Source review then established KEY-MACRO-001 and
added `ch10_directives/audit_macro_escaped_actual.va` as a positive XFAIL.
The final full strict run exits 1; its name-list diff contains exactly that
new XFAIL and no removed or changed existing names. This is newly exposed
missing behavior, not an implementation regression and not passing evidence.
The targeted direct compilation fails with E0207 after the macro expansion
loses the identifier terminator. The unit gate and Python audit tests pass.
The script-generated report is refreshed from that final strict run; its B/D
placeholders now say they are unmeasured instead of implying zero open work.

A further IEEE §19.3 fixture review found that `resetall` removes user macros,
and an existing unit test incorrectly requires that behavior. MAC-RESET-001
now has an isolated positive XFAIL with actual wrong-value observations; see
the macro worklist. Independent late-binding and spacing cases and isolated
recursion/argument-count rejections pass. Chapter 10's full text comparison
and syntax-box visual review are recorded in the source-review log. These
findings do not close the inherited rule inventory or justify a conformance
claim from the unit gate.

The scheduling-source pass restored Figures 8-1/8-2 from direct PDF crops,
made source tokenization preserve hard hyphens and compatibility distinctions,
and added a solved two-node KFL fixture with independent expected values.
An isolated missing-branch mutation fails both its observations and the strict
runner. Existing parameter-sweep fixtures now require the expected observation
total; their targeted run passes. The final full strict run still exits 1 and
its nonempty FAIL/XFAIL name list is identical to the preceding macro checkpoint.
This is static nodal evidence, not a claim of adaptive transient or mixed-signal
host completeness. The source/host distinctions are in the scheduling worklist.

The continuation of the scheduling review read the remaining Chapter 8 source
and HTML, restored Figures 8-3 through 8-7 directly from the PDF, and recorded
additional mixed-signal host obligations. Cross-reading IEEE §§9.2.2 and
11.6.5 exposed why the AMS cancellation example cannot become a general NBA
oracle and supplied the missing switch-uncertainty value. The contradictory
D2A/inactive ordering is also explicitly retained and flagged. This continuation
changes source documentation and its asset-extraction tool only: it does not
move A, historical B, C or architecture D, nor claim new passing runtime
evidence. The preceding measured report and failure-name comparison remain
the fixture checkpoint; the unresolved source issues are closure blockers for
the affected obligations, not a reason to stop auditing other clauses.

The subsequent digital scheduling pass added independently derived NBA
transcripts. Ordinary queued updates survive later assignments and the new
positive case passes. A variable-index bit-target case is valid under the
inherited source but is rejected with E1100; NBA-TARGET-001 remains a positive
failure, not negative coverage. The digital suite's nonempty failure-name diff
adds only that new case. A fresh analog strict run retains exactly the preceding
FAIL/XFAIL names, and the measured report is refreshed through the conformance
script. These digital transcripts are outside A's fixture population; neither
their passing case nor the exposed gap changes the A/C measures. Historical B
and architecture D are unchanged. See the scheduling ledger for the rule-level
evidence, source-read boundaries and remaining timing/control alternatives.

The same-time scheduling follow-up adds a passing fixture that observes an
intermediate NBA transition through an armed edge waiter, even though the
final value returns to its initial value. It also checks ordered queueing from
different processes at distinct times. IEEE scheduling and strobe source review
identified an overconstrained callback-order expectation in the existing strobe
fixture; identical output labels now preserve sampling and multiplicity checks
without requiring an unspecified order. STROBE-ORDER-001 records the withdrawn
claim and the historical clause-audit row has been corrected. Digital failure
membership remains unchanged. This improves oracle validity and behavioral
evidence, not the A/C score or a newly measured B/D tally.

The monitor follow-up separates the inherited digital change-trigger rule from
AMS analog accepted-step comparison. Four isolated positive transcripts expose
premature installation output, loss of a change that returns to its previous
value, unwanted time-only triggers and missing output on already-enabled
monitoron calls. Their names are the only additions to the digital failure
list; the analog strict FAIL/XFAIL list is unchanged. Existing digital monitor
expectations are unchanged, but their analog-rule attribution is corrected.
Historical B rows 17.1-12/13 no longer claim complete digital verification;
this is an evidence correction, not a new aggregate B measurement. A/C are
unchanged and D is untouched. See `conformance-monitor.md` for source clauses,
expected versus observed results and still-uncovered variants.

The display-format follow-up compares §§9.4.2–9.4.7 and their tables against
the PDF, restores a dropped connective, and records the g-precision wording
discrepancy with a primary C-source cross-check. A new positive fixture checks
exact e/f strings, including padding and precision, instead of numeric scanning
that would erase those distinctions. It passes the targeted strict run. The
known default-integer-width deviation in `170` remains explicitly open rather
than being credited from its green result. This strengthens A's evidence;
C remains a citation inventory, and no B/D closure is claimed.

The default-width follow-up replaces deviation-based expectations in the
argument-run fixture with explicit minimal-width conversions, preserving its
passing purpose. Bare-operand and default field-width claims move to a new
positive fixture using sized literals; direct execution exposes FMT-WIDTH-001
and the strict runner records an XFAIL. This is a newly measured limitation,
not an implementation regression or a reason to weaken the source-derived
expectations. The full inherited sizing subsection and exact derivation are
recorded in the display worklist; no B/D closure is inferred.

The data-type source pass reviews §§3.1–3.2.1 and restores the literal-token
distinctions in Syntax 3-1. Its evidence map separates analog zero initialization
from digital x initialization, and internal output-variable values from actual
simulator access. No new behavioral closure or A/C change is claimed: the
output-variable fixture does not itself exercise the export interface. The
remaining data-type rules and host observations are tracked in the new worklist.

The string follow-up reviews §3.3 and Table 3-3 against the PDF. Independent
typed-string and lexicographical assertions pass, while literal-only equality
incorrectly removes a NUL byte and is isolated as STR-LITERAL-001. The new
positive XFAIL preserves the integer-context expectation; the passing fixture
does not hide it inside an aggregate comparison score. Remaining string
operator/context matrices and invalid-input cases stay open in the type ledger.

The parameter source pass reviews §3.4 and §§3.4.1–3.4.2, restores literal
syntax-token distinctions and tightens five rejection fixtures from generic
phase failure to the actual E0345/E0346/E0347 diagnostics. The full strict
FAIL/XFAIL name list is unchanged. The untyped-real fixture's promoted
denominator and absent overrides are recorded as evidence gaps rather than
credited as complete inference coverage. A/C totals are unchanged; the work
strengthens negative evidence without claiming B/D closure.

The inference follow-up strengthens the default-type fixture with an integer
denominator and adds a passing HDL override case that reverses default types
without changing numeric magnitudes. Dependent parameter types are observed
separately. Removing the overrides in a temporary source copy makes every new
assertion fail, confirming that the fixture distinguishes default-only behavior.
This adds positive evidence for PAR-003, not closure of every override API,
type category or dependency graph; historical B and architecture D are unchanged.

The parameter follow-up reviews §§3.4.3–3.4.7 and separates metadata, array
resizing, local-parameter override paths, string flags and alias obligations.
An ignored host binding is no longer credited as an illegal HDL override test:
that claim moves to an independent E0907 rejection fixture. Duplicate alias
overrides now pin E0908. The ledger explicitly leaves untested override paths
and simulator parameter listings open; no B/D closure is claimed.

The inherited parameter pass identifies PARAM-HEADER-001: an illegal override
of a body parameter is accepted when the module declares header parameters.
The IEEE source makes those body declarations local. A new rejection XFAIL
preserves that requirement; a separate legal dependency fixture prevents
confusing override protection with value propagation. The AMS hierarchy HTML
now points to this inherited requirement in an explicitly editorial note.
This adds a known gap, not B closure or a conformance claim.

The array follow-up finishes the §3.4.8 example text comparison and labels its
source-internal threshold discrepancy without changing it. Existing legal
dependent resizing is mapped separately from exact-size replacement. Three
new rejection XFAILs expose accepted short/long replacements and resizing
without a replacement. These are additional known obligations, not evidence
that passing declaration and assignment-pattern fixtures closes array rules.

The genvar pass reads §3.5, restores Syntax 3-3 literal punctuation markup and
corrects a fixture's example attribution. Its negative assignment test no longer
accepts an unrelated genvar-read failure. The new static dependency case checks
parameters, nested genvars and zero iterations; the
[genvar ledger](conformance-genvars.md) keeps inherited digital generation and
independent analog-operator history separate and open.

## Completion gate

Completion requires all of the following at the same source and code revision:
all PDF content accounted for in the HTML review; all applicable source units
classified and expanded into rules; inherited sources resolved; no unreviewed
or ambiguous mandatory rule; all required evidence executed and passing; no
XFAIL or capability refusal credited as implementation; documented allowed
choices and bounds; and all existing regression gates passing with FAIL/XFAIL
name lists compared. Publish the supported host/API/analysis configuration with
the claim. Changes to source, fixtures, harness or compiler invalidate affected
evidence and require rechecking.
