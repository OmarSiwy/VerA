# Inherited IEEE lexical source and evidence review

Reviewed2026-09-23 against licensed `docs/1364-2005.pdf`, SHA-256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Read complete Clause3, **Lexical conventions**, printed8–20 / physical38–50,
including every example, Table3-1 and Syntax3-1–9. Visually checked physical39,
40,42,43,44,45,46: numeric grammar/widths, real constants/conversion, packed
strings/escapes, identifiers/system-call grammar and attribute rules. Remaining
attribute syntax boxes/pages were text-read, not visually certified.

This is inherited IEEE source, distinct from the already reviewed AMS Chapter2.
AMS extensions (including typed strings, additional escapes and analog-profile
four-state restrictions) need separate applicability accounting. A Verilog-A
four-state rejection is not positive full-AMS digital behavior. This report
does not add to the narrow §§17–18 measure B denominator or manually alter A/C.

## Obligation register

Rows are independently actionable groups, not exhaustive cross-products. OPEN
means not closed with sufficient positive, invalid-input and recorded evidence.
Printed source pages below use IEEE numbering, not the AMS chapter numbers.

| ID | Source | Requirement and evidence boundary |
|---|---|---|
| ILEX-001 | 3.1–3.2, p8 | Free token layout; space/tab/newline/formfeed separators; space/tab inside strings significant. Existing AMS lexical fixtures are leads; token adjacency and all contexts remain OPEN. Escaped identifier termination is separately constrained. |
| ILEX-002 | 3.3, p8 | // ends at newline; block comments stop at first closing delimiter, cannot nest; // inside block has no special meaning. Existing comment tests do not certify all boundary/include combinations. OPEN. |
| ILEX-003 | 3.4, p8 | Unary/binary/conditional token placement; operator semantics belong to Clause5. No expression-wide closure follows from lexical recognition. OPEN. |
| ILEX-004 | 3.5.1, pp10–11 | Based constants comprise up to three substitutable tokens: nonzero decimal size, contiguous apostrophe/base with optional s, digit token. Whitespace allowed between tokens, forbidden inside base; sign between base/digits illegal. Existing AMS36/37/25/41/51 cover selected paths; their individual observations, not whole grammar, may be reused. |
| ILEX-005 | 3.5.1, pp10–12 | Base/s/x/z case insensitive; plain decimal signed, based unsigned unless s. Signedness changes interpretation, not literal pattern. Existing digital four-state fixture observes signed/unsigned extension; Clause5 context rules remain necessary. |
| ILEX-006 | 3.5.1, pp10–11 | x/z/? expand by base digit width, pad matching leading unknown/high-impedance state or zero, truncate excess left bits. Existing sized digital fixture freshly PASS; not all bases/widths covered. |
| ILEX-007 | 3.5.1, pp10–12 | Unsized integer at least32 bits; leading x/z unsized unsigned extends to containing expression width. Existing40-bit context-fill positive freshly FAILs E1100. Do not pin all implementations' unsized width to exactly32. |
| ILEX-008 | 3.5.1/Syntax3-1, pp9–11 | Decimal x/z/? must be the sole value digit, with trailing underscores permitted. New decimal-unknown positive PASS; new extra-digit invalid gets specific E0133 with legal neighbor. Other invalid-base/digit cases OPEN. |
| ILEX-009 | 3.5.1, p11 | Underscores ignored, not allowed as first character of a numeric token. Numeric grammar still constrains token boundaries. New trailing-underscore cases cover only decimal unknown arm; other placements OPEN. |
| ILEX-010 | 3.5.2, p12 | Real decimal/scientific syntax, required digits both sides of decimal point, case-insensitive exponent, signed exponent and underscores. IEEE754-1985 double-precision representation dependency remains explicitly unresolved beyond selected values. Existing AMS real-number cases are not full inherited representation certification. |
| ILEX-011 | 3.5.3, p12 | Implicit real-to-integer rounds nearest, ties away from zero, distinct from $rtoi truncation. Existing analog conversion cases do not establish all digital assignments, signs, overflow or contexts. OPEN. |
| ILEX-012 | 3.6–3.6.2, pp12–13 | Literal strings in expressions/assignments are unsigned packed8-bit ASCII; right-justify, left-zero-pad or truncate left on assignment; operators manipulate packed value. New packed-string positive FAILs before behavior. Typed AMS string tests are different storage semantics. |
| ILEX-013 | 3.6.3/Table3-1, pp13–14 | Escape newline/tab/backslash/quote and1–3 octal digits; shorter escape ends before nonoctal; error above octal377 is permitted, not mandatory. New independently derived stored-byte test is blocked by packed-string expression support; no byte decoding credited. |
| ILEX-014 | 3.7, p14 | Simple names include letters/digits/$/underscore but first cannot be digit/$; case sensitive; implementation length limit at least1024, excess over chosen limit must error. Existing1024-character fixture proves lower bound only; no universal1025 rejection. |
| ILEX-015 | 3.7.1/.2, pp14–15 | Escaped printable ASCII name ends at whitespace, excludes delimiters from name, aliases equivalent simple spelling, escapes keywords; ordinary keywords lowercase. Existing AMS identifier/macro evidence is bounded; complete ASCII/termination/keyword contexts OPEN. |
| ILEX-016 | 3.7.3/Syntax3-2, p15 | $ immediately followed by system name, no escaped system name; system-task optional/null argument grammar differs from function grammar. Standard/PLI/implementation extensions distinct. Unknown system task refusal is not proof that its lexical name is illegal. OPEN lexical versus registered-host call evidence. |
| ILEX-017 | 3.7.4, pp15–16 | Directive effects immediate and persist across description files until changed; standard and tool-specific names. Existing macro/reset ledger covers subsets. Multi-file driver and residual Clause19 source work OPEN. |
| ILEX-018 | 3.8–3.8.2, pp16–20 | Prefix declaration/item/statement/port positions; suffix operator/function-name positions; grammar gives exact permitted placement. Default attribute value1; last duplicate wins, warning optional. Need metadata/host observation for retained value, not just unaffected circuit output. OPEN. |
| ILEX-019 | 3.8, p16 | Attribute values constant; nested attributes, including inside constant expression, illegal. Existing AMS30/53 negatives are leads with distinct legal neighbors; all expression shapes/context restrictions remain OPEN. |

## New and reused independently checked evidence

Direct actual root `vera --run` calls from the worker directory on the review
date; no compiler changes or full suites. New files are in
`tests/fixtures/digital/`:

- `audit_lexical_decimal_unknown.v` and expected transcript:12'D X__ yields
  twelve x bits;12'dz_ and12'sd? each yield twelve z bits. Source grammar
  explicitly permits those trailing underscores. Exit0, exact transcript PASS.
- `audit_lexical_decimal_z_digit_rejected.v`:12'dz1 adds a forbidden second
  digit. Direct exit1/E0133, header `invalid number literal`. Explicit digital
  rejection mode and both specific patterns are supplied. Neighbor is the
  passing legal12'dz_ above; this is not an analog-unsupported shortcut.
- `audit_lexical_packed_strings.v` and expected transcript: AZ into32 bits is
  0000415a; ABC into16 bits is4243. Octal escapes1/Q,12/R,101/8 form bytes
  01,51,0a,52,41,38; newline/tab/backslash/quote form0a,09,5c,22. Hex rendering
  checks packed bytes rather than scanning back through a shared decoder.
  Actual exit1/E1100 at the first string assignment. Every later obligation
  remains unobserved; the legal expected transcript is retained, not converted
  to a rejection or split into false passing claims.

Existing root `lexical_four_state_constants.v` freshly exits0 and matches its
eight-line transcript: base-specific expansion, question-mark z, mixed case,
left truncation and signed/unsigned assignment extension. Its distinct
`lexical_unsized_context_fill.v` freshly exits1/E1100 explicitly unsupported
unsized context fill. The latter remains an honest required-positive failure;
no duplicate new unsized fixture was added. Existing AMS macro-based-number
and1024-character tests were inspected as leads, not rerun or re-counted here.

## False-coverage cautions and dependencies

Existing `ch02_lexical/20_duplicate_attributes.va` observes an unchanged
parameter value, not which duplicate metadata value survives. Its statement
that attributes carry no compiler semantics is too broad: Clause3 intentionally
permits tool properties without standardizing their meanings, and AMS defines
specific metadata attributes elsewhere. Default1/last-wins metadata obligations
remain ILEX-018 until a retained-attribute/VPI query distinguishes them. No
existing expected value or fixture was changed.

Do not infer a universal unsized32-bit width from selected32-bit examples, or
apply the analog-profile x/z exclusion to these digital tests. The examples of
negative sized constants also need Clause5 expression sizing/context before
deriving larger arithmetic or assignment oracles; this review does not amend
root signedness fixes or bless the old analog negative-literal rationale as a
universal digital evaluation rule.

The supplied source's escaped-name termination list explicitly names
space/tab/newline, while general whitespace includes formfeed. Keep that
boundary visible before asserting a formfeed-terminated identifier oracle.
An octal escape greater than377 allows an implementation error; do not use a
required-error fixture for that permission. AMS escape extensions are not
forbidden merely because IEEE Table3-1 is shorter.

Required external dependencies include IEEE754-1985 representation details,
Clause5 context widths/signs, Clause19 compilation state, and PLI/VPI metadata
for actual attribute values. No external standard was fetched or purchased.
Root integration must compare FAIL names and run its actual digital-negative
gate. This complete source-text read is not exhaustive lexical conformance;
the groups above retain untested dimensions and distinct host obligations.

## Root integration checkpoint

Main read this complete report and all three fixture/oracle pairs, checked
the inherited decimal unknown/underscore provisions, and integrated the report
and fixtures. Full digital execution exits1; exact failure-name comparison
adds only `audit_lexical_packed_strings` to the preceding readmem-edge list.
The legal decimal-unknown case and isolated invalid extra-digit case pass;
the packed-string positive remains unsupported before its byte observations.
Logs: `/tmp/vera-ieee-lexical-devices.{log,names}`. The earlier attribute-header
overclaim has separately been corrected at root; metadata observations remain
open. Complete worker source traversal above is not independent main visual
certification or exhaustive lexical closure.
