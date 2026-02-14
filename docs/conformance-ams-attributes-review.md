# AMS2.9 attributes candidate ledger

Reviewed2026-09-23. `rules/ams-attributes.json` is a bounded candidate, not an
approved requirement denominator. Complete2.9–2.9.2 text and examples read;
all original physical32–36 / printed19–23 visually inspected, including every
Syntax2-4 through2-10 production and literal/metasyntax distinctions. PDF SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
Corresponding current HTML sections read. Latest root HTML SHA256 at handoff:
`18895b02032089133182fda149c0f3dae000973bcebc621fd207d718f71a5597`.
Selected dependencies read: complete3.4.3;6.3.6 introductory rules through
double-scaling warning and example context; AnnexC.3/C.7/C.8/C.16.
These do not constitute complete Chapter3/6 or AnnexA review for this handoff.

## Source-to-HTML and rule boundary

Every row links to s2-9, s2-9-1 or s2-9-2 in ch2-lexical.html. No omitted
normative prose or grammar alternative found in these sections. Syntax2-4..10
still lack the PDF's systematic literal/metasyntax typography; text correspondence
is not presentation fidelity. Source blue extension markings also carry context
not reproduced by plain syntax text. No HTML edits made here.

The JSON array contains87 candidate rows (counted when generated): generic
attribute shape, constant values, defaults, duplicates, warning permission,
nesting/placement, each explicit prefixed grammar alternative, and standard
attribute domains/reporting effects. Alternative enumeration does not exhaust
zero/one/multiple instance combinations, every expression form, ownership scope,
repetition position or absent syntactic alternative. Structural acceptance rows
cannot become runtime verification. Independent atomicity/completeness review
remains pending; overlap between general placement prose and concrete syntax
rows is explicit source traceability, not a measured denominator.

Syntax2-7's bare generate_region, specify_block and aliasparam alternatives do
not themselves add an attribute prefix. Whether attributes enter through a
referenced production requires AnnexA resolution; the ledger does not turn
their omission here into a universal rejection. Similarly Syntax2-8's digital
function-port production must not be mistaken for an analog function input
declaration: existing fixture55 explicitly explains this distinction.

## Mandatory rules versus optional use

General attributes may be used by tools **including simulators** to influence
tool behavior. The source does not establish a universal rule that arbitrary
attributes must be inert. Required syntax/metadata rules remain: default1 when
omitted, last repeated value on the same element, constant expressions and no
nested attributes. Duplicate warning is optional, not mandatory and not grounds
for rejecting otherwise legal repeated metadata.

Standard desc/units require strings; op requires explicit yes/no; multiplicity
requires multiply/divide/none. Their domain restrictions cannot be bypassed by
generic default1. Syntax-defined illegality is recorded separately from exact
diagnostic phase/severity/code: E0357/E0358 are current fixture expectations,
not codes supplied by the LRM.

3.4.3 explicitly makes parameter descriptions/units documentary, permits
simulator help use, forbids inferring dimensional analysis from the units, and
requires simulator disregard of these attributes on block-level parameters.
Those dependencies constrain the candidate; their separate source clauses still
need complete own-ledger decomposition. Description metadata is not a mandate
for a particular help UI or transcript.

When an operating-point report is produced, op selection and multiplicity
scaling have specified meaning. A missing reporting interface is an open host
requirement, not permission to call declaration acceptance runtime coverage.
Raw12 with effective mfactor2 independently gives multiply24, divide6, none12
or absent-multiplicity12. Multiplicity reporting policy must not disable the
automatic circuit scaling of6.3.6. The absent-op interpretation of “otherwise”
is separately marked ambiguous pending independent review rather than hidden
in a guessed oracle. No exact report format or compulsory report invocation
mechanism is invented.

## Profile applicability

AnnexC.3 retains Clause2 generally in Verilog-A. Analog declarations, module
metadata and legal analog expressions keep these rules. C.7 excludes digital
behavior; initial/always, continuous digital assignment, UDP and digital task
placements are outside that profile, not failures caused by the chosen runner.
Inherited declaration/port alternatives whose full Verilog-A reachability was
not settled by this bounded read remain explicitly unresolved (e.g. task/function
declarations, time/realtime/reg/event variants). No inference is made that a
reserved keyword automatically makes its construct legal in Verilog-A.

## Existing fixture claims requiring narrower evidence credit

These fixtures were read, not executed or modified. JSON references are
not-run/citation records; all rules remain open.

| Fixtures under ch02_lexical | What their actual assertions establish / do not establish |
|---|---|
|11_attributes|Decorated parameter keeps0.001; no help/units/op-report/multiplicity output is observed. “Tools OTHER than compiler” is narrower than the source's including-simulators statement.|
|20_duplicate_attributes|Decorated parameter remains2.5; does not distinguish first versus last metadata value or wrong owner. “An attribute carries no semantics for compiler” is not a source rule.|
|29_attribute_default_and_multiple|Analog arithmetic gives3; default1 versus missing/0 metadata is not observed. Filename/comments mention multiple forms, but source has one instance containing three specs, not separate adjacent instances.|
|21_operator_attribute,31_analog_statement_attributes,32_function_call_attribute,33_conditional_attribute|Useful syntax-and-computation regressions for decorated slots; cannot establish arbitrary tool attribute inertness or metadata attachment.|
|55_attribute_block_item_and_function_port|Tests analog block/function-body declarations, not ANSI digital function ports; current header already acknowledges that distinction. Unchanged arithmetic is not description/units reporting.|
|30_nested_attribute_rejected|Outer attribute is in a legal prefix slot and inner operator attribute isolates nesting; appropriate source prohibition. Needs matching no-inner legal case in the same obligation for closure.|
|53_attribute_value_not_constant_rejected|Analog variable-dependent value isolates nonconstant expression; not metadata consumer evidence. Literal and parameter-constant legal controls remain required.|
|54_attribute_illegal_placement_rejected|Attribute between type and identifier isolates absent grammar slot; does not reject every possible unlisted location without following dependencies.|
|52_standard_attribute_domain_rejected,69–72|Separate invalid string/numeric standard-attribute domains. Existing fixture11 is a legal-declaration neighbor, not positive evidence for reporting effects or all valid enum branches.|

Parser inspection reinforces the need for a consumer oracle: parseAttributes
collects names/values and omitted values use ExprId.none; this alone neither
proves nor disproves correct eventual default1/last-wins behavior. A metadata
database, VPI attribute traversal or actual report consumer must observe the
value and its owning element. No compiler change is proposed in this handoff.
The attr_name identifier grammar versus standard reserved spelling units is
also marked ambiguous; parser acceptance of every keyword is not treated as
source authority for that broad extension.

## Validation

Current root validator with `--check-html-root` exits0 on the new JSON,
including real HTML anchor checks. This validates shape/links only. No fixture
was rerun, no compiler/shared files changed, no full builds/gates run, no
verified rows or conformance percentages supplied. Independent review and
source-derived consumer/diagnostic controls remain required.

## Root integration boundary

Main read this full report and every candidate obligation/profile/HTML-anchor
projection, and checked the generic tool-use/default/duplicate source passages.
The report and candidate are retained with completeness pending, not independently
approved as exhaustive. All23 ledger tests pass, including candidate shape and
HTML-anchor validation. No runtime result was inferred from these checks.

Main narrowed headers in11_attributes,20_duplicate_attributes and
29_attribute_default_and_multiple: blanket inertness claims are withdrawn;
missing help/report, last-wins and default metadata observations are explicitly
moved to the named candidate rows. Executable bodies, assertions and directives
are unchanged. Historical assertion labels remain implementation-regression
labels, not proof of universal language semantics.

Independent-review follow-up: main read complete3.2.1 and linked its mandatory
module-scope output-variable value access and block-variable attribute disregard
to DESC-HELP/UNITS-DOC. Optional parameter help under3.4.3 must not obscure
these separate variable obligations. MULT-NONE/MULT-ABSENT proposed mutants
now use erroneous scaling to24/6, not always reporting12 (which satisfies those
individual cases). No consumer execution or completeness promotion follows.
