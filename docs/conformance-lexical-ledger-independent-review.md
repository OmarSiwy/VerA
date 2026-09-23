# Independent review: bounded AMS lexical-core candidate

Reviewed2026-09-23. Target: current root
`docs/rules/ams-lexical-core.json`, SHA256
`e04c46a6fe799482ed53720be5a8663164e2e6b5619ef1106ac52201fe2375d6`.
HTML snapshot `docs/ch2-lexical.html` SHA256
`57f908645c240926e1a0a4181648817bb890188dc7ee36b242019456a5adb64f`.
This review does not modify either file or certify a denominator.

## Exact review boundary

Read complete source2.2–2.4 and2.8–2.8.2, printed11/17, original PDF
physical24/30; visually inspected both pages at1400 pixels, including every
Syntax2-1 production and its font distinctions. Source PDF SHA256 is the
ledger's `e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
Read corresponding HTML sections and the lexical candidate review report.
Reviewed every rule's source locator, obligation, profile, case, discriminator,
evidence classification and residuals through structured projections of the
JSON; the initial raw output was truncated and was not relied on as complete.
Read referenced existing whitespace, string, identifier, escaped-identifier,
comment-separation and nonnesting fixtures, plus the three new digital
fixtures in the owning ch7 worktree where they were not yet in root.

Not reviewed as complete source units:2.5–2.7,2.8.3 onward, AnnexA/B,
preprocessor/scope semantics, or every character/keyword context. This is an
independent review of the stated candidate, not permission to broaden its
denominator or assert closure of these dependencies.

## Actionable corrections

| ID | Affected rows | Finding and concrete correction |
|---|---|---|
| LEX-REVIEW-001 | ESC-END-SPACE | Proposed mutant “only recognize ordinary space as terminator” is conforming for THIS row. Replace it with “do not terminate at ordinary space” or “retain space in identifier key.” Pin this row's assertion to the first value1 in the four-name fixture, not the whole1/2/3/4 transcript. Keep tab/newline/formfeed rows independently pinned to their values. A failure elsewhere in the aggregate transcript is not evidence for the space rule. |
| LEX-REVIEW-002 | ESC-ASCII | A single name containing all allowed characters proves bounded acceptance/resolution, not preservation of every character in identity. Consistently stripping punctuation from declaration and references can still print9. Retain this fixture, but add independently valued names that would collide after dropping/changing punctuation: e.g. escaped `a.b` versus simple `ab`, escaped `a/b` versus `ab`, escaped `a+b` versus `ab`, and corresponding first/last-character controls. A proposed mutant must distinguish stripping/collision from the current undeclared-variable defect. Do not turn the historical failure into a current failing verdict after the pending fix. |
| LEX-REVIEW-003 | all Syntax2-1 HTML traces | Prose and production text are present, but actual HTML syntax display has no literal/metasyntax markup. Source PDF bold-red literal `//`, `/*`, `*/` differs from unbold alternative/repetition notation. The trace's broad “syntax compared” limit should explicitly retain this typography gap until fixed. Preserve the source's unbold newline notation; do not bold all punctuation mechanically. `direct-text` remains reasonable for textual correspondence, not full grammar-presentation fidelity. |
| LEX-REVIEW-004 | TOKEN-STREAM, TOKEN-KINDS | Source describes the language's token stream, not the compiler's internal token objects. Internal zero-width EOF sentinels or discarding comments after lexing can be conforming. “No invented zero-length lexical token” is not currently an external observable, and “drop comment category” need not be a wrong implementation. Keep these as structural/source-accounting rows with explicit nonbehavioral limits, or derive an actual source→result mis-tokenization oracle. Do not require an internal lexer architecture to close them. |
| LEX-REVIEW-005 | FREE-SPACE, FREE-NEWLINE, WS-* | Preconditions need “between complete tokens, outside string/comment/escaped-identifier contents, and preserving required token boundaries.” Generic whitespace movement can change string content, line-comment termination or escaped identity, and directive lines are another explicit dependency. “Same token sequence” already helps FREE-* cases; make that boundary explicit in the obligations/preconditions and WS-* cases too. Never derive a blanket whitespace-stripping oracle. |
| LEX-REVIEW-006 | BLOCK-NONNEST, COMMENT-SEPARATOR, identifier-start prohibitions | Candidate correctly leaves diagnostic authority open, but each currently has only its invalid case. Add legal cases in the SAME evidence obligation before closure. Nonnesting legal neighbor: a second `/*` inside comment followed by its first `*/`, then an executed assignment, with no stray later closer. Separator legal neighbor: two normally separated tokens such as `real/*c*/x` and a value observation; invalid `1/*c*/2` remains separate. Identifier-start restrictions pair with legal letter/underscore declarations and escaped digit/dollar spellings under2.8.1. |
| LEX-REVIEW-007 | ID-LIMIT-MIN, ESC-IDENTITY | Identifier limit applies to identifiers generally, not just the new simple-name fixture. Add an escaped identifier with1024 content characters and differing final character; leading slash/terminator are not part of identity. This catches implementations charging delimiter bytes against the minimum. Do not invent rejection at1025: the chosen finite limit is still unknown and source permits larger/unbounded support. |
| LEX-REVIEW-008 | STRING-TAB | Existing fixture has literal tab at the beginning and escaped tab at the end; it does not supply the proposed literal-tab beginning/interior/end matrix. Either narrow the represented evidence boundary to the actual assertions or add missing literal positions. Escaped-tab decoding also depends on2.7, outside this bounded clause decomposition. Citation/not-run status is honest but does not repair the mismatch between proposed case and actual assertion. |

## Completeness and atomicity decisions

All paragraphs and the listed token categories in the bounded source have
representation. This is not the same as a complete atomic rule/case set.
Specific in-scope boundaries still need explicit disposition before the
candidate's completeness review can be approved:

- Syntax2-1 repeats `Any_ASCII_character` zero or more times: explicitly
  account for empty line comments and empty block comments, versus one
  character and multiline block contents. This is a direct grammar branch,
  not new scope. BLOCK-START/END alone do not name the zero-repetition case.
- The grammar's end delimiters need EOF/unterminated dispositions. Whether
  line comment at EOF is accepted via another source convention requires
  dependency resolution; do not manufacture an arbitrary refusal. Block
  missing-closer behavior and isolated diagnostic need an explicit open case.
- Escaped identifier termination/start rules need empty spelling and missing
  whitespace boundary dispositions. Exact nonempty identifier grammar is
  an AnnexA dependency; flag it rather than deciding from current parser.
- Escaped printable-character permission is position-independent. A single
  ascending-ASCII name places only `!` first and `~` last; first-position
  digit/dollar/backslash and embedded delimiter-like sequences deserve
  distinct cases. Outside-range bytes need a separate source/diagnostic
  decision, not a Unicode or control-byte rejection invented from lack of
  implementation support.
- KEYWORD-INVENTORY currently names a dependency rather than enumerating
  each AnnexB word; this is explicitly and appropriately out of the bounded
  detailed denominator. Preserve an open edge to the AnnexB ledger, including
  unescaped reserved-word rejection versus escaped/case-distinct legality.
  Keyword reservation in Verilog-A does not depend on whether that keyword's
  construct is usable in the analog profile.
- General unique-object naming in2.8 depends on scopes; do not construe
  ID-NAMING as global-name uniqueness or reject legal names in distinct
  scopes. Source-level naming form is represented, scope closure is not.

FREE-SPACE/NEWLINE and WS-SPACE/NEWLINE overlap in their current expected
observables. Retain separate source locators if useful, but either share a
single behavioral obligation with multiple provenance links or document why
each row contributes a distinct case. TOKEN-KINDS and KEYWORD-INVENTORY are
structural inventory nodes, not atomic runtime claims. The report already
warns about these issues; this review confirms they block an independent
completeness approval rather than silently accepting the raw row count.

## Source, HTML and profile checks that hold

The source hash, physical/printed page offsets and the section anchors
`s2-2`, `s2-3`, `s2-4`, `s2-8`, `s2-8-1`, `s2-8-2` match the inspected
root source/HTML. No dropped normative prose was found in these bounded
sections; Syntax2-1 typography is the separate issue above. Sentence locators
identify the intended clauses, including the limit permission versus its
minimum and over-limit error rule.

Both-profile applicability of whitespace/comments/identifier spelling is
source-grounded in AnnexC.3, independent of the chosen digital or analog
runner. No correction to those broad applicability decisions is needed.
Keyword reserved spelling remains distinct from permitted analog constructs.
Keeping ID-LIMIT-CHOICE as optional permission and ID-LIMIT-ERROR conditional
on an actually specified finite limit avoids inventing a universal bound.

## Evidence and integration limits

The candidate's historical digital passes/failure have a named CLI hash and
report, but no durable complete source/runner/artifact bundle. Partial/open
statuses are appropriate; neither the escaped-name repair in progress nor
these inspections upgrade them to verified. Earlier failed observations must
remain explicitly historical after root integration, with the new run kept
as a separate checkpoint rather than unexplained simultaneous evidence.

At inspection the three new digital fixture paths were absent from root but
present in the owner's ch7 worktree. This is a pending integration/artifact
availability issue, not proof the proposed source or earlier run is invalid.
Link the integrated files before treating the root ledger as a reproducible
inventory. I did not run those programs, alter their expected results, edit
the ledger/HTML, or run builds. No measurements or runtime closure claimed.

Recommendation: retain `completeness_review: pending`, address the concrete
oracle/trace issues, and explicitly enumerate or defer the bounded grammar
branches above. Only then record independent decomposition approval, still
separate from implementation verification and full-language completeness.

## Root integration follow-up

Main read the entire review and retained it without promoting completeness.
The ledger now separates structural token accounting from implementation
architecture, constrains whitespace movement to preserved token boundaries,
and maps each escaped terminator to its own transcript field and meaningful
mutant. ASCII identity, escaped minimum-length, literal-tab matrix and syntax
typography limitations are explicit. The validator suite passes all23 tests;
this confirms schema/link consistency, not adequacy of these discriminators.
Legal-neighbor, collision and escaped-length fixture work is assigned separately.
The four earlier lexical digital fixture pairs are now integrated at root;
their actual patched executions are recorded in conformance-escaped-name-fix.md.
