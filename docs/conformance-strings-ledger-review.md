# AMS2.7 string-literal candidate ledger

New file `rules/ams-strings.json`; source, HTML, oracle and historical evidence
are explicit. Schema validation is not conformance evidence. Independent
completeness review remains pending and no row is verified.

## Source/HTML review boundary

Read the COMPLETE2.7 text and every Table2-2 cell on2026-09-23, printed16 /
physical29, including original PDF rendering at1450 pixels. Source SHA256:
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
Compared against current root `docs/ch2-lexical.html#s2-7`. All escape pairs,
octal digit bound, short-escape continuation condition, and optional error
wording are present. The HTML table retains literal backslashes rather than
turning `\n`/`\t` into layout controls. The source's `\ddd` is a notation
for one to three octal digits, not a literal three-letter escape namedddd.
The two table columns must stay distinct: source spelling versus decoded
character. No missing bounded prose/table cell was found and no HTML was edited.

Supplementary source read:3.3 representation/context paragraphs, conversion
steps and Table3-3;3.4.6 paragraph; AnnexC.3 applicability from the earlier
source review. These dependency readings do NOT expand this candidate into
a complete typed-string/parameter ledger.2.7 itself points to3.3 and3.4.6.
General string-literal rules apply to both profiles independently of which
runner is selected. AnnexC.3's numeric mixed-signal/keyword exceptions do not
exclude string-literal syntax or ASCII byte interpretation.

## Decomposition and key distinctions

The candidate separates quote/single-line restrictions, ordinary integral
expression versus integral assignment, byte representation/order/unsignedness,
NUL preservation in numeric context, each named escape row, each octal length,
short-form continuation, the three-digit stop, mandatory byte boundaries,
and the optional over377 diagnostic.3.3 and3.4.6 are explicit dependency
edges rather than an implied integer-only interpretation of every quoted token.

Source restrictions have isolated proposed negatives AND named legal neighbors;
diagnostic details remain unresolved where not established. Existing E0138
multiline rejection is a source-inspected fixture lead, not a newly executed
result. An actual newline in source differs from backslash-n on one physical
line, which produces a newline character value after decoding.

Important source qualifier:2.3 explicitly permits significant literal tabs
inside strings. Table2-2's backslash-t mapping does not authorize rejecting
an actual tab. Do not read2.7's introductory “certain characters” paragraph
as a requirement to escape every occurrence of every resulting byte. Existing
literal-tab cases are legal; escaped-tab and literal-tab tests serve distinct
lexical branches.

The octal parser must consume one to three octal digits. For example,
`\7A` decodes byte7 followed byA, `\77A` byte63 followed byA, and
`\1012` byte65 followed by the ordinary character2. The last observation
distinguishes the three-digit maximum from unlimited greedy octal decoding.
Following-octal-digit and nonoctal boundaries must both be retained; this is
not an arbitrary-choice parser length.

Octal377 is255 and is in the mandatory8-bit range. Above377 the source
permits an error; it does NOT mandate an error or explicitly prescribe
modulo256 for accepted overflow here. Therefore no required-error fixture
is invented for400/777. Actual implementation policy and inherited behavior
must be reviewed separately. Likewise backslashq/backslash8 and raw non-ASCII
input do not acquire invented diagnostics merely because Table2-2 lacks a row;
an ambiguous/open interpretation row records that dependency boundary.

## Literal bytes versus typed strings

`"A\0"` in ordinary numeric interpretation contains bytes0x41,0x00 and
has value0x4100; `"A"` has value0x41. A literal-only equality cannot remove
the NUL as though both operands were already typed strings. In3.3 string
context, however, NUL removal is required on conversion. The paired equality
and typed-comparison fixtures are distinct evidence leads. A leading NUL
numeric test such as `"\000A" == 65` cannot by itself distinguish byte
preservation from stripping, so trailing/interior controls remain explicit.

Existing `73_string_literal_to_integral.va` also exercises3.3 truncation and
zero extension, with an integer-width assumption questioned in the type
review. It is not used to certify all widths or to turn3.3 resizing rules
into2.7 obligations. An explicitly sufficiently wide AB assignment is the
proposed width-safe core control. Empty literal sizing and concatenation
context are addressed by3.3/its examples and inherited rules, not inferred
solely from2.7's word “sequence.” Their detailed atomic enumeration remains
outside this candidate and must not disappear when dependencies are linked.

## Evidence provenance and limits

Read current root fixture sources `08_string_escapes`,
`67_octal_escape_boundaries`, `19_multiline_string_rejected`,
`73_string_literal_to_integral`, `audit_string_literal_equality`,
`25_string_nul_removal`, the typed-context review, and the recently integrated
literal-tab report. Existing unexecuted fixtures are citation/not-run leads.
The octal three-digit fixture has a related A-plus-octal101 example, not the
proposed opposite-order example; the evidence assertion explicitly says so.

The only imported passing execution is the bounded literal-tab byte-order
case from `conformance-lexical-legal-neighbors.md`: cached CLI6b6e9b…,
actual emitted executable, three independently derived observations. It is
PARTIAL, not reexecuted in this ledger task and not a complete artifact bundle.
The historical literal-only equality defect/XFAIL remains in its source
report; this task does not assert a fresh current failure or erase history.
No pass is inferred from a tag, expected transcript or fixture's mere existence.

Remaining dependencies include exact grammar for empty/unclosed literals,
unknown escapes, source character encoding, arbitrary-length/width conversion,
mixed signed operands, constant-folding versus runtime context, all escape
positions/repetitions, and typed-string/parameter transitions. Proposed
discriminators are not claimed executed mutations. Some structural/dependency
rows may need further splitting or reclassification during independent review;
their presence does not certify a denominator.

## Validation

```sh
PYTHONDONTWRITEBYTECODE=1 python3 \
  /home/omare/Documents/Projects/Zig/VerA/tools/rule_ledger.py \
  docs/rules/ams-strings.json \
  --check-html-root /home/omare/Documents/Projects/Zig/VerA
```

Exit0: schema and actual root HTML anchor checks pass. Scoped diff whitespace
check passes. No shared file, compiler/header or fixture edits; no builds,
new simulation runs, A/C measurements or verified rules in this handoff.

## Root integration boundary

Main read this full report, every candidate obligation/class/case projection,
and complete2.7 source text/Table2-2 against the HTML. The candidate is retained
with completeness pending; all23 ledger validation tests pass. Imported
observations retain their historical execution attribution. Independent review
is assigned separately, including raw-character and inherited-grammar conflicts;
no complete string-literal conformance is asserted by this integration.

Independent-review alert: AnnexA.8.8 uses `Any_ASCII_Characters`, and AnnexG
change2535 describes a multiline-string definition correction, while2.7 says
single line. Main confirmed those source/HTML passages. The SINGLE-LINE row
is provisionally ambiguous pending reconciliation; its earlier unconditional
diagnostic characterization above is superseded. Existing multiline rejection
is not promoted to proof that the standards conflict is resolved. No fixture
expectation or compiler behavior was changed by this classification correction.

The independent review is now retained in
`conformance-strings-ledger-independent-review.md`. Main withdrew the earlier
categorical supersession statement in the IEEE grammar review, removed the
unconditional raw-newline mutant, and replaced the mandatory short-octal777
control with in-range177. Unlisted escape diagnostics are unresolved rather
than implicitly legal. Raw-tab execution remains historical evidence but
cannot reconcile2.3 with2.7's escape-only introduction; the earlier unqualified
legality conclusion above is superseded by that explicit source tension.
No raw-tab or raw-newline compiler behavior/fixture expectation is changed.
