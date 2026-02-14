# Chapter 2 requirement worklist

Source read: PDF physical pages 24–36 and `ch2-lexical.html`, 2026-09-23.
This is a decomposition worklist, **not a claim that Chapter 2 is complete**.
Groups with multiple cases must be expanded into individual evidence records
before closing them. Read with [the audit contract](CONFORMANCE.md).

`Both` means AMS and Verilog-A, `AMS` means digital/mixed-signal behavior
excluded from the Verilog-A profile. A fixture name is a lead unless its source,
observable and actual execution have been reviewed. References abbreviated to
numbers below are files in `tests/fixtures/ch02_lexical/`; digital references
are in `tests/fixtures/digital/`.

## Rules and required cases

| ID | Clause / profile | Obligation and case partitions | Evidence or next action |
|---|---|---|---|
| LEX-001 | 2.2 / Both | Free token layout; each legal separator and repeated combinations; token adjacency where unambiguous | 27 covers formfeed; audit spacing, tabs and newlines independently. |
| LEX-002 | 2.2, 2.4 / Both | A comment separates adjacent tokens; deleting it must not weld identifiers or numbers | 39 is the numeric negative; add a legal identifier/keyword separation neighbor. |
| LEX-003 | 2.3 / Both | Space, tab, newline and formfeed are ignored between tokens | Cross-check LEX-001 rather than duplicate a closed obligation. |
| LEX-004 | 2.3, 2.7 / Both | Spaces and tabs inside strings remain significant, including order and leading/trailing bytes | 08 covers a single space/escaped tab; 68 adds literal tab, ordered pairs and boundary spaces with independent integer wants. |
| LEX-005 | 2.4 / Both | `//` starts a comment that ends at newline; compiler-directive text inside it has no effect | 01 is a candidate; inspect end-of-file and newline boundaries. |
| LEX-006 | 2.4 / Both | `/*` ends at the first `*/`; `//` inside it is inert; nesting is unsupported | 01, 12, 13; add/inspect adjacency and minimal empty comments. |
| LEX-007 | 2.5 / Both | Unary left operand, binary infix, two-character conditional across three operands | 65; individual operator semantics belong to Clause 4. |
| LEX-008 | 2.5 / AMS | Three-character operators are tokenized as single operators | Positive digital `===`/`!==` cases needed; analog-subset rejection cannot close this. |
| LEX-009 | 2.6 Syntax 2-2 / Both | Decimal, binary, octal, hexadecimal and real number alternatives work in constant and runtime expressions | 66 plus 04/06/07; review every grammar arm and malformed neighbor. |
| LEX-010 | 2.6.1 / Both | Simple decimal is signed; optional unary signs are operators | Include zero, positive, negative and expression-context signedness discriminators. |
| LEX-011 | 2.6.1 / Both | Based constants have optional size and separately substitutable size/base/digit tokens | 37 substitutes only base and digits; size-token substitution and each token combination remain to test. |
| LEX-012 | 2.6.1 / Both | Size is a nonzero unsigned decimal bit count | 51, 64; verify malformed size tests fail for this reason and test exact-width boundaries. |
| LEX-013 | 2.6.1 / Both | d/D, h/H, o/O, b/B and s/S spellings; hex a–f/A–F case equivalence | 04, 23, 35; upper S and individual digit/base partitions need explicit audit. |
| LEX-014 | 2.6.1 / Both | Apostrophe/base have no whitespace; whitespace before digits and between size/base is legal | 36, 37, 41; enumerate all separator kinds, not space alone. |
| LEX-015 | 2.6.1 / Both | Digits are legal for their base | Audit binary 2, octal 8/9, non-hex letters and empty digits as independent negatives with legal neighbors. |
| LEX-016 | 2.6.1 / Both | s changes interpretation without changing bits; unsigned/signed high-bit cases; two's complement | 23 and 40 observe values; add upper-S and expression-width interactions. |
| LEX-017 | 2.6.1 / Both | Unary sign before a based constant is legal; sign between base and digits is illegal | 23 and 25; both plus and minus need individual accounting. |
| LEX-018 | 2.6.1 / Both | Short two-state values zero-pad; excess digits truncate from the left | 40 has explicit independent wants; include size 1, exact fit and width-boundary transitions. |
| LEX-019 | 2.6.1 / Both | Unsized constants provide at least 32 bits, not necessarily exactly 32 | 22's value fits below the minimum and does not establish the floor. Add a bit-31 discriminator without assuming an implementation's maximum width. |
| LEX-020 | 2.6.1 / Both | Underscores are ignored except as a first character; grammar restricts digit-token starts | 04; audit repeated/trailing underscores and distinguish an identifier from an invalid numeric token. |
| LEX-021 | 2.6.1 / AMS | x/z fill bits by radix, case-insensitively; ? means z | New digital `lexical_four_state_constants.v` covers representative radix and case partitions. Decimal x/z/? and full case matrix remain. |
| LEX-022 | 2.6.1 / AMS | Leading x/z pads left with x/z; leading known bits zero-pad; truncation preserves the low bits | New digital fixture observes both extension forms and mixed-state truncation. Expand each radix and boundary. |
| LEX-023 | 2.6.1 / AMS | Unsized leading x/z extends to expression width beyond 32 bits | New digital fixture observes 40-bit results; add concatenation/arithmetic expression contexts. |
| LEX-024 | 2.6.1 / AMS | Decimal x/z/? form has one special digit with optional underscores; no mixed/multiple digits | 42 is a rejection lead; valid decimal forms still need direct evidence. |
| LEX-025 | 2.6.1 / AMS | Sized signed/negative constants sign-extend into reg regardless of destination signedness | New digital fixture covers signed-to-unsigned destination; negative constants and signed destination remain. |
| LEX-026 | 2.6.1 / AMS | Default x/z length equals default integer length | Requires a width observation that does not hard-code a permissible implementation choice. |
| LEX-027 | 2.6.2 / Both | Real representation is IEEE double precision; decimal, exponent and scaled forms | 06; independent bit-pattern or exact binary-value boundary oracle needed, not merely two decimal spellings parsed by the same converter. |
| LEX-028 | 2.6.2 / Both | Digits on both sides of a decimal point; optional decimal point in exponent/scaled forms | 06, 07; 14–16 and 43–45 cover malformed neighbors. |
| LEX-029 | 2.6.2 / Both | e/E and optional exponent signs; underscores ignored except first character/first after dot | 06, 34, 57; include plus exponent, repeated/trailing underscores and exponent-digit boundaries. |
| LEX-030 | 2.6.2 Table 2-1 / Both | T/G/M/K/k/m/u/n/p/f/a have the table's values | 07 has independent per-symbol checks; rounding-policy assumptions for fractional mantissas need separate review. |
| LEX-031 | 2.6.2 / Both | No whitespace before scale symbol; exponent and scale are different grammar arms | 46, 58; invalid alphabet 56. |
| LEX-032 | 2.6.2 / AMS | Scale symbols may not define digital delays | Needs a digital rejection and a legal timescale-based delay neighbor. |
| LEX-033 | 2.7 / Both | Double-quoted literal is on one line; delimiters are not characters | 19, 38 are rejection leads; empty and single-character positive cases need review. |
| LEX-034 | 2.7 / Both | Numeric string operand uses unsigned 8-bit ASCII characters in order | 08 covers AB and AA; 67 adds high-byte and NUL boundaries. String-typed parameters follow 3.4.6 separately. |
| LEX-035 | 2.7 Table 2-2 / Both | newline, tab, backslash, quote escape meanings | 08 has individual ASCII wants; inspect numeric and display byte-output contexts separately. |
| LEX-036 | 2.7 Table 2-2 / Both | Octal escapes consume 1–3 digits; short escape's following character is non-octal | 67 observes one/two/three digits and a fourth octal digit as an ordinary character. |
| LEX-037 | 2.7 Table 2-2 / Both, optional | Implementations may error for a character above octal 377 | Do not require acceptance or rejection absent a documented chosen policy. Test the mandatory boundary 377 independently. |
| LEX-038 | 2.8 / Both | Simple identifier alphabet; first character is letter/underscore; case sensitivity | 02, 17, 47, 59; audit full character classes and source-context ambiguity of `$` names. |
| LEX-039 | 2.8 / Both, allowed limit | Identifier limit, if present, is at least 1024; exceeding declared limit reports error | 28 tests exactly the floor; shorter control, boundary+1 and the actual documented maximum remain. |
| LEX-040 | 2.8.1 / Both | Escaped identifier includes printable ASCII 33–126 and ends on any permitted whitespace | 03 covers space/tab and several punctuation characters; newline/formfeed and the complete printable alphabet remain. |
| LEX-041 | 2.8.1 / Both | Neither backslash nor terminating whitespace is part of the name | 03 reads escaped declaration through plain spelling; reverse spelling and each terminator need audit. |
| LEX-042 | 2.8.2 / Both | Escaped keyword is an identifier; keywords are lowercase | 26, 59; Annex B requires checking the whole reserved-word set, including non-Verilog-A constructs. |
| LEX-043 | 2.8.3 Syntax 2-3 / Both | System name starts `$`, followed immediately by its allowed characters, and is not escaped | 18, 48, 60 plus 09; the grammar allows digit/underscore/dollar after `$`, so ordinary-identifier restrictions must not be imported. |
| LEX-044 | 2.8.3 / Both | Standard, PLI/VPI and implementation system names have their defined registration/dispatch routes | Requires appropriate host registrations and inherited-source review; an unknown-name refusal alone is insufficient. |
| LEX-045 | 2.8.3 / Both | Keyword spellings may be used as system names | Needs registered keyword-named host task/function; arbitrary unregistered acceptance is not required here. |
| LEX-046 | 2.8.3 Syntax 2-3 / Both | Argument-list alternatives, including analog null arguments and bare task/function forms where allowed | Clause 9 task-specific arity/semantics must be kept separate from syntactic permission. |
| LEX-047 | 2.8.4 / Both | Grave accent introduces directive; effect is immediate, persists and can cross description files until changed | 10 proves macro use only; cross-file persistence requires preprocessing driver cases under Clause 10/IEEE 1364 Clause 19. |
| LEX-048 | 2.8.4 / Both | Valid identifiers including keywords may name directives through the specified extension mechanisms | Requires source/host policy evidence; no invented guarantee for an unregistered directive. |
| LEX-049 | 2.9 Syntax 2-4 / Both | Attribute list has one or more specs; optional constant value; identifier attribute names | Positive list forms 11, 29; malformed empty/list/separator cases need audit. |
| LEX-050 | 2.9 / Both | Attribute prefixes on declarations/module items/statements/port connections; suffixes on operators/function names | 11, 21, 31–33; enumerate placement slots in Syntax 2-5–2-10, with profile exclusions. |
| LEX-051 | 2.9 / Both | Omitted attribute value is 1 | 29 observes only unrelated model arithmetic. **Needs attribute metadata observation.** |
| LEX-052 | 2.9 / Both | Last duplicate attribute value wins; warning is permitted | 20 observes parameter value, not selected attribute. **Needs attribute metadata observation.** |
| LEX-053 | 2.9 / Both | Attribute instances cannot nest, including inside their constant-expression value | 30; isolate direct nesting and expression-mediated nesting. |
| LEX-054 | 2.9 / Both | Attribute value is a constant expression | 53; positive folded constants and each relevant scope need audit. |
| LEX-055 | 2.9.1 Syntax 2-5–2-10 / Both/AMS by production | Each `{attribute_instance}` position accepts repeated instances; unlisted positions do not | 55 covers block declarations, not the entire production matrix. UDP/task/digital slots remain AMS obligations. |
| LEX-056 | 2.9.2 / Both | desc is a string and supplies help for parameter/variable/net declarations | 69 isolates integer rejection; positive type acceptance and generated help are separate cases. |
| LEX-057 | 2.9.2 / Both | units is a string and describes parameter/variable units | 70 isolates real rejection; metadata output still needs a host observation. |
| LEX-058 | 2.9.2 / Both | op accepts only yes/no; no omits from short report, otherwise includes | 52 rejects invalid string; 71 rejects numeric truth value. Reporting yes/no/absent is untested by those refusals. |
| LEX-059 | 2.9.2 / Both | multiplicity domain is multiply/divide/none | 72 rejects an invalid string. Numeric value and each legal spelling remain separately accountable. |
| LEX-060 | 2.9.2 / Both | multiplicity multiply/divide applies instance mfactor to reported value; none/absent does not scale | Requires a report oracle with non-unit mfactor, parameter and variable cases; 11's parameter default does not observe it. |
| LEX-061 | 2.9.2 / Both | Report scaling does not change automatic contribution scaling of 6.3.6 | Requires simultaneous report and electrical behavior observations. |

## Evidence recorded this session

`zig build benchmark -- ch02 --strict` exited 0 after adding fixtures 67–72
(log: `/tmp/vera-conformance-lexical.log`, local run 2026-09-23). The new
expectations were derived from the PDF and are in the fixture headers.
This records execution, **not mutation verification or complete rule closure**.
The broader run is required again after the remaining edits.

The digital `lexical_four_state_constants.v` has an independently written exact
transcript; `vera --run` exited 0 and produced its expected eight lines on
2026-09-23. The separate `lexical_unsized_context_fill.v` is legal full AMS but
fails with E1100 (unsized four-state context fill is not implemented). Keeping
it separate prevents that refusal from hiding the sized-literal observations.
These belong to `test-devices`, not measure A's fixture population. The digital
runner has other failures; no claim that its complete suite passes is made.

## Corrections to earlier coverage claims

The old chapter coverage table said fixture 52 covers all standard attribute
value domains. Its body contains only `op="maybe"`; the other violations were
comments suggesting future fixtures. Fixtures 69–72 now exercise those cases
independently. The former claims about attribute defaults and duplicate
selection are narrowed to legal placement/acceptance until metadata is observed.
No existing expectation has been weakened to manufacture a pass.

The unsized literal in fixture 22 fits in fewer than 32 bits. Its passing value
does not establish the mandatory minimum width despite its assertion label.
The four-state extension test must not be replaced by an analog capability
rejection: full AMS and the Annex C subset are different profiles.
