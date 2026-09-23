# Parameter core candidate ledger review

Reviewed 2026-09-23. Scope: AMS 2023 §3.4 introduction, Syntax 3-2,
§3.4.1 and §3.4.2 only (printed 27–29, PDF pages 40–42).
The full selected text and all three rendered source pages were inspected.
Source SHA-256: `e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.

The accompanying `rules/ams-parameter-core.json` is an open candidate
decomposition, not a certified atomic denominator. Every row is open, every
evidence array is empty, and no production execution or independent completeness
review is asserted. Boundary sketches must become separately observable cases;
mixed valid/invalid sketches currently remain under one candidate and are not
closure-ready. No compiler, fixture, HTML or build changes were made.

## HTML and profile trace

The current root `docs/ch3-datatypes.html` has actual anchors `s3-4`,
`s3-4-1` and `s3-4-2`. The selected prose corresponds to the source, including
final-value type inference, mandatory defaults, conversion restrictions, strict
range-bound ordering, and instance-only range checking. Syntax 3-2 has an existing
editorial source-fidelity note for the PDF's spaced `:: =` delimiter; this review
does not silently treat that as a different production. No new HTML discrepancy
was found in the selected material. This is not a review of the rest of Clause 3.

Annex C.4 (printed 390) includes Clause 3 for Verilog-A and lists exceptions for
discrete domain binding, wreal and default discipline, not parameter declarations.
Both profiles therefore apply to these rules. This does not authorize a digital
testbench in Verilog-A: Annex C.7/C.8 restrictions and legal observation mechanisms
still apply. Neither digital fixture selection nor existing implementation support
determines profile applicability.

## Required distinctions

- Type inference uses the final assigned value after overrides. An untyped default
  `2` overridden by `2.5` must not be permanently typed from the original default.
- Explicit integer and explicit real conversions are separate obligations.
  Proposed non-tie numeric examples avoid silently choosing a rounding rule;
  full conversion boundaries belong to §4.2.1.1.
- A typed string value and an ordinary packed string literal are not interchangeable
  test inputs. Missing-type and string-to-real cases need those dependencies settled
  before becoming negative tests. Explicit-real and derived-real error paths need
  separate concrete cases.
- The introductory reference to previously defined parameters is recorded separately
  as an ambiguous candidate pending reconciliation with inherited dependency rules;
  no forward-reference rejection is newly asserted.
- Two-bound ranges require strict increasing order; equal bounds are not the same
  construct as a permitted single-value exclusion.
- Each endpoint follows its own delimiter. A mixed interval must not receive only
  an interior-value test.
- A default outside a range can be replaced by a legal instance value. Conversely,
  a legal default does not excuse an out-of-range final instance value. Merely
  accepting a declaration or rejecting a default cannot establish the simulation rule.

## Deliberately open dependencies and decomposition debt

§3.4.2 is itself the range subsection, so its direct rule families are recorded,
not omitted from the requested traversal. Detailed range conversion/composition,
multiple inclusion semantics, all endpoint cross-products, invalid-input diagnostic
authority and simulation timing remain open. Source examples support the listed
multiple-exclusion oracle but do not alone settle arbitrary inclusion composition.

Array shape, sizing and overrides (§3.4.4), string behavior (§3.3/§3.4.6), alias
parameters (§3.4.7), local/specparams, mintypmax, signed/ranged inherited parameter
types, §4.2.14 assignment patterns and §6.3 override resolution remain dependencies.
Syntax 3-2 mentions these constructs; reading the production is not semantic closure.
The three-extension introductory list is explanatory context, not three execution
proofs. Multi-instance/override-mechanism cases and string range cases need further
atomic splitting before denominator certification.

Existing fixture names are not evidence for this ledger until their source,
assertions, runner, actual outputs and build provenance are inspected and recorded.
No previous conformance result is promoted into this seed. Measures A and C were
not run or changed; this adds traceability and candidate obligations only.

Root integration: main read this complete report, every candidate obligation/
class/expected-case projection and complete3.4 introduction through3.4.2 source
text. Candidate and report are retained with all rows open and empty evidence;
all26 ledger tests pass, including actual HTML anchors. Neither complete
transitive grammar review nor independently approved atomic completeness is
claimed. Combined legal/invalid sketches still require separate executable cases.
