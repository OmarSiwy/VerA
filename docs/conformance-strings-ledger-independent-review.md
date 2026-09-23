# Independent review: AMS string-literal candidate

Reviewed 2026-09-23. This is a review report only: no shared ledger, fixture,
compiler, or measurement was changed. No simulation or full suite was run.
The candidate is useful, but its denominator is not certified and no rule is
promoted to verified. This work concerns evidence quality for measures B/C,
not a measured change to A/C.

## Source and snapshot

Reviewed every candidate rule, proposed oracle, residual, and evidence lead in
`docs/rules/ams-strings.json`. The root snapshot after the parent's provisional
SINGLE-LINE correction has SHA256
`1bcf531f7675009a8531e7cac9127178618b8ce76127faf1ad10c532a99a8fdb`.
Read `conformance-strings-ledger-review.md` and the relevant prior grammar report.

Authoritative source: supplied VAMS-2023 PDF, SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
Complete text and rendered-page review of 2.7/Table 2-2, printed16/physical29;
complete 3.3 text and Table 3-3, printed25–27/physical38–40. Supplementary
rendered checks: A.8.8 printed383/physical396; G.5 item2535 printed419/physical432;
G.7 item7891 printed423/physical436. Section2.3 and Chapter1 conventions were
read for context, not certified here as a fresh complete visual review.
HTML locations are `ch2-lexical.html#s2-7`, `#s2-3`, and
`annex-a-syntax.html#a-8-8`; the conflicting source statements are faithfully
present, rather than a demonstrated HTML transcription error.

## Findings requiring disposition

### STR-REVIEW-01: raw newline remains a source conflict

Section2.7 requires a literal on one source line. Normative A.8.8 instead uses
`Any_ASCII_Characters` without the inherited newline exclusion. Informative
G.5 records a multiline-string correction; G.7 records a nonterminal rename,
not another multiline semantic change. The history supports an intentional
grammar difference but does not itself establish precedence over contradictory
normative prose. No such precedence rule was established in this review.
Nor can the generic ASCII placeholder alone erase quote/backslash processing.

The parent's provisional ambiguous/open SINGLE-LINE classification is
appropriate. Its `wrong_implementation` still calls raw-newline acceptance
wrong unconditionally; revise that discriminator to say no raw-newline
acceptance/rejection mutant is certified until reconciliation. Escaped newline
remains independently specified and can retain its own behavioral oracle.
Add exact A.8.8 and G.5 source locations to this row, not only generic AnnexA
cross-reference text.

Prior contrary claims are precisely `conformance-ieee-grammar-review.md`,
GRAM-42 (line136 in the inspected root) and the first paragraph of
"Source anomalies and supersession" (lines143–146). My earlier wording there
asserted that AMS supersedes the restriction and that multiline evolution is
settled. That was too categorical: replace it with the explicit 2.7/A.8.8
conflict and historical evidence, without choosing acceptance or rejection.

Preserve `ch02_lexical/19_multiline_string_rejected.va` pending reconciliation.
It is an implementation regression grounded in one conflicting passage, not
closure of reconciled AMS syntax. Separately, its `//! lrm 2.7` rejection tag
can still contribute to static clause coverage despite the ambiguous ledger
classification: static C output must not be interpreted as source-certified
two-way evidence for this interpretation. No proposed deletion or silent
expectation reversal is part of this report.

### STR-REVIEW-02: raw tab tension must remain explicit

Section2.3 treats literal spaces/tabs as significant. Section2.7 introduces
Table2-2 by saying certain characters require an escape; the table includes
tab. These passages create an interpretive tension. The author's unqualified
statement that literal tabs are legal and that 2.7 cannot require escaping
goes beyond a reconciled reading. Record both passages and the unresolved
interpretation, even if one interpretation is judged more plausible.

BYTE-ORDER imports actual historical raw-tab execution. Preserve that history
and provenance, but do not use successful execution to settle the source
conflict. Add an unambiguous ordinary-printable discriminator, e.g. explicit
wide integral destinations for AB=16706 and BA=16961; if retaining partial
status, state that raw-tab applicability is conditional/unresolved. Escaped
tab mapping to9 is a separate unambiguous Table2-2 obligation.

### STR-REVIEW-03: isolate octal overflow from mandatory continuation

OCTAL-SHORT-STOP includes `\777` alongside ordinary continuation examples.
It does demonstrate three lexically octal digits, but its value exceeds377,
for which a diagnostic is permitted. Replace this proposed mandatory
behavioral control with an in-range three-digit sequence such as `\177`.
Keep400/777 only under OCTAL-OVERFLOW-PERMISSION. Do not require their rejection
or an accepted modulo256 value. The existing optional classification correctly
preserves this boundary; its case is a policy/disposition probe, not a fixed
portable numeric transcript.

### STR-REVIEW-04: ambiguity and dependency rows are not atomic closure units

UNLISTED-ESCAPES groups unknown escapes, a terminal backslash, raw controls,
and non-ASCII bytes. These need separate interpretation cases. A terminal
backslash before a quote may instead escape the delimiter, leaving an
unterminated literal; spell the exact bytes before deriving that diagnostic.
Its current `invalid_input: not-applicable` explanation calls these legal
representation behavior despite their ambiguous classification: use unresolved
until those cases are distinguished. No required error or drop-backslash
interpretation for backslash-q/backslash-8 is established here.

STRING-PARAMETER-EDGE correctly admits it is a dependency pointer, but a
mandatory rule phrased merely as "separately specified semantics" is not an
atomic behavioral obligation. Keep it explicitly non-closure metadata or
decompose under3.4.6 before denominator certification. STRING-CONTEXT-EDGE
combines conversion trigger and NUL removal; link separate3.3 obligations
for assignment-triggered conversion, typed-operand conversion, and removal
of all NULs. Empty literals, integral empty concatenation, and typed empty
concatenation must remain explicit dependency edges, not disappear under
the broad word "sequence".

QUOTES currently packs legal delimiters and a missing closing delimiter into
one diagnostic case. Separate legal behavioral neighbor and rejection case.
Other rows bundle standalone/embedded/repeated forms into one proposed case;
split before treating evidence for one form as fulfillment of them all.
This is not a demand to invent invalid programs for ordinary legal value rules.

## Oracle checks that withstand this bounded review

The named escapes map to newline10, tab9, backslash92 and quote34. The octal
proposals `\7A`=1857, `\77A`=16193, `\101A`=16705 and `\1012`=16690
are independently consistent with octal decoding followed by byte packing.
The maximum in-range escape377 is255; permission to diagnose overflow does
not extend down to this value. The ledger honestly labels proposed mutations
as unexecuted. Its three-digit evidence lead uses A followed by octal101,
not the opposite order; both happen to encode AA. That fixture cannot prove
byte order, so retain the stated limitation and use distinct characters.

The literal-only A-NUL versus A inequality is sound: numeric values0x4100
and0x41 differ. A leading NUL comparison alone cannot detect stripping.
In typed-string context3.3 removes NULs; the paired existing
`audit_string_literal_equality.va` and `audit_string_comparison_context.va`
sources express the distinction correctly. The latter's prefix/equality
checks do not prove every conversion position or operator. Their fixture
presence/XFAIL text is not a fresh execution result.

`73_string_literal_to_integral.va` still asserts that integer width is fixed
at32 and relies on truncating hello. The candidate correctly flags this
existing portability dependency instead of certifying it. An explicitly
wide AB control avoids truncation but does not close arbitrary-width resizing.
UNSIGNED's377=255 discriminator catches signed-byte interpretation, not every
mixed-sign expression bug; the residuals must retain that distinction.

## Handoff and limits

Recommended next changes are source-disposition/atomic-case corrections above,
followed by independently executed unambiguous value/diagnostic neighbors.
This report does not authorize changing either raw-newline or raw-tab compiler
behavior. It does not complete3.3,3.4.6, inherited sizing, character encoding,
or typed-string runtime coverage. No external standard was fetched, no test
oracle was copied from implementation output, and no coverage measure changed.
