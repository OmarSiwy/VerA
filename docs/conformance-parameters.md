# Parameter source and evidence worklist

Review date: 2026-09-23. Complete text of AMS §3.4 and §§3.4.1–3.4.2
(physical pages 40–42) was read against the HTML. Syntax 3-2's continuation
was visually checked on page 41; its beginning was seen on the preceding
string-review rendering of page 40. Literal delimiters, comma/assignment signs
and assignment-pattern braces now have explicit bold markup, distinct from
optional/repeated grammar notation. The source's spaced `:: =` is already
identified as a transcription normalization. No entire parameter chapter is
declared verified. Follow-up reading covers the complete text and HTML of
§§3.4.3–3.4.7 (physical pages 43–45). A subsequent complete text/HTML read
covers §3.4.8 on physical pages 45–46; its example discrepancies are recorded
below rather than silently repaired.

## Partial requirement groups

| ID | Source | Obligation / evidence limit |
|---|---|---|
| PAR-001 | 3.4 | Initializers are constant expressions with previously defined parameters. `58_forward_parameter_reference.va` pins E0314 for declaration order; independent permitted dependency and runtime-expression cases remain to be mapped. |
| PAR-002 | 3.4 | Parameter values cannot be assigned at runtime; source overrides customize instances. Distinguish elaboration overrides from host sweep/model-card APIs and verify each supported path independently. |
| PAR-003 | 3.4.1 | Untyped scalar type follows the final value after overrides. `74_untyped_parameter_type_derivation.va` now uses integer denominators to distinguish default type inference. `audit_parameter_override_type.va` reverses integer/real defaults through HDL overrides and observes both overridden and dependent parameter types. Both targeted fixtures pass; other override paths and value categories remain open. |
| PAR-004 | 3.4.1 | Explicit integer/real types control conversion. `04_parameter_types.va` uses an integer denominator with the declared-real parameter, independently distinguishing promotion from integer division. Other conversions, signs, boundaries and overrides remain open. |
| PAR-005 | 3.4.1 | String and array parameter declarations require explicit types. Both `60_*_untyped` fixtures now pin E0346, verified against actual diagnostics, instead of a generic phase label. Valid typed counterparts are still required for two-way rule evidence. |
| PAR-006 | 3.4.1 | Numeric-to-string and string-to-real parameter assignment are errors. The two `53_*` fixtures now pin E0345 independently. Derived-type and overridden-value forms remain separate cases. |
| PAR-007 | 3.4.2 | Open/closed endpoints, single-value exclusion, infinities and multiple ranges define permissible values. Test each boundary and combination, not just an interior default. Malformed bounds are distinct from a valid declaration with an invalid instance value. |
| PAR-008 | 3.4.2 | The first numeric range bound is smaller than the second. `71_range_first_expression_larger.va` now pins E0347 for reversed bounds. Equal-bound behavior still needs an independently isolated fixture; range endpoint inclusion does not waive bound ordering. |
| PAR-009 | 3.4.2 | Range checking applies to actual instance values, not unused defaults. An out-of-range declaration default overridden by a legal instance must not be rejected merely for that unused value. Source/host override paths require independent execution evidence. |
| PAR-010 | 3.4.2 | String valid/invalid sets use assignment-pattern lists. Numeric interval rules cannot substitute for string membership, exact comparison, empty-string exclusions or overrides. |
| PAR-011 | 3.4.3 | Units/descriptions document parameters without dimensional analysis; block-level metadata is ignored by the simulator. Valid/invalid attribute types belong also to §2.9.2. Metadata acceptance alone does not establish unchanged numeric behavior or host presentation. |
| PAR-012 | 3.4.4 | Parameter arrays require initializers and explicit types. `08_parameter_array.va` observes distinct indexed values and a parameter-dependent bound; it does not resize that bound through an override. PAR-005 covers the explicit-type rejection. |
| PAR-013 | 3.4.4 | Overrides must have exactly the declared array size. Resizing a dependent bound requires a replacement array of the new size from the same overriding module. Exact-size and legal resize cases are mapped below; short/long replacements and missing replacement expose PARAM-ARRAY-SIZE-001/002/003. Different-module provenance and other override/shape paths remain open. |
| PAR-014 | 3.4.5 | Local parameters follow dependencies but cannot be directly overridden. `06_local_parameter.va` observes host-bound dependency evaluation; `audit_localparam_override_rejected.va` independently pins E0907 for a source-level named override. `ch06_hierarchy/ordered_override_skips_localparam.va` separately asserts both ordered bindings, dependent local value and their sum. Defparam and other declaration contexts remain open. |
| PAR-015 | 3.4.6 | String flags support allowed-value sets and Table 3-3 operators. Exercise each legal flag and invalid membership through source overrides; the transistor example is not a substitute for operator and membership evidence. See PAR-010 and the string worklist. |
| PAR-016 | 3.4.7 | Aliases inherit original type and range, and multiple aliases are legal. `07_parameter_alias.va` observes host alias binding through the original name, not HDL instance binding or every inherited constraint. |
| PAR-017 | 3.4.7 | Alias names must not collide or be used in equations. Name collision and expression-use prohibitions are distinct rejection obligations; legal override use must remain independently tested. |
| PAR-018 | 3.4.7 | Original-plus-alias and multiple-alias overrides are errors even for equal values. `78_alias_double_override.va` pins E0908 for the first case through named HDL binding; multiple aliases and defparam/mixed paths remain open. |
| PAR-019 | 3.4.7 | Simulator parameter-value listings use only original names. Internal value checks cannot establish this host-output requirement. Aliases for hierarchical parameter functions additionally require §9.18 evidence. |
| PAR-020 | IEEE 1364-2005 4.10.1; AMS 1.1, 6.2 | A nonempty module parameter header makes body parameter declarations local. PARAM-HEADER-001 exposes an accepted illegal named body override. The independent legal header-override fixture observes dependent body evaluation. Defparam, ordered and host binding paths remain separate obligations. |
| PAR-021 | IEEE 1364-2005 4.10.1–4.10.2 | Declared ranges and signedness constrain override-derived type/width; unsized inferred widths have an implementation-dependent minimum. Non-real parameters and locals support bit/part selects. Existing real/integer division observations do not close these inherited width, sign and select matrices. |
| PAR-022 | 3.4.8; 3.4.4; A.8.1 | The multidimensional example combines nested constant overrides, real/string replication, variable assignment patterns and indexed behavior. `77_assignment_pattern_replication.va` independently checks nonzero nested real replication and a constant parameter pattern, but not replicated strings or multidimensional parameter overrides. The example is not an atomic requirement denominator. |

Fixture names are under `tests/fixtures/ch03_data_types`. This inventory is
partial and does not close the remaining parameter-array, alias, string,
metadata or inherited declaration obligations.

## Rejection-oracle correction

The following existing fixtures previously accepted `DiagnosticsReported`,
which identifies only a failed compilation phase, not the intended rule:

- `60_string_parameter_untyped.va`, `60_parameter_array_untyped.va`: E0346.
- `53_real_parameter_from_string.va`, `53_string_parameter_from_numeric.va`: E0345.
- `71_range_first_expression_larger.va`: E0347.

Each was run through the installed compiler with `--check --contract` and its
include directories, and the diagnostic points to the intended declaration.
The changes strengthen what rejection counts as success without changing valid
language expectations or compiler behavior. Stale comments claiming no specific
diagnostic exists were removed. This is stronger negative evidence, not positive
coverage or exhaustive verification of the enclosing clause.

The full strict run after tightening the tags exits 1 with exactly the same
nonempty normalized FAIL/XFAIL name list as the preceding string checkpoint.
No new rejection failure entered that list. The conformance report is refreshed
by the measurement script; these stronger pins do not change A/C totals or
close historical B or architecture D.

## Type-inference discriminator follow-up

The default-type fixture previously divided `measured` by `3.0`. A wrong
integer type for `measured` would still be promoted by that real denominator,
so the old expression could not establish its claimed inference behavior.
The denominator is now integer `3`; the expected real value is unchanged and
the fixture still passes. Its header explains the discriminator and the runner
requires the expected observation count. No compiler behavior was changed.

`audit_parameter_override_type.va` supplies real `4.0` to an integer-default
untyped parameter and integer `4` to a real-default untyped parameter. Their
numeric magnitudes stay equal while their types reverse. Division by integer
3 must respectively yield 4/3 and 1; dependent untyped parameters must yield
the same respective results. The passing assertions observe the final type,
not merely that the override's numeric value reached the instance.

These are source-level named instantiation overrides. They do not prove host
model-card/sweep binding semantics, positional or defparam overrides, signed
width inference, string exclusions or every dependency shape. The new case
adds positive evidence to PAR-003 without closing the complete parameter matrix.

A temporary source copy with only the two overrides removed fails every new
observation: integer-default paths yield 1 instead of 4/3, and real-default
paths retain real division instead of integer truncation. The CHECKI format
prints those latter wrong real values as integers, but its independent equality
expression correctly reports `ok=0`; rendered `got` text is not the verdict.
The process still exits successfully, so the assertion transcript remains the
behavioral oracle. This source mutation checks the test's discriminator, not
the compiler's internal inference implementation. Repository overrides remain.

After the inference edits, the full strict run exits 1 with the same nonempty
normalized FAIL/XFAIL name list as the diagnostic-pin checkpoint. Both changed
and new targeted cases pass. The measurement script refreshes A/C from that
run; new passing evidence does not make static clause citations a conformance
proof.

## Local-parameter and alias follow-up

The old `06_local_parameter.va` also supplied a host binding directly to the
local parameter and credited its being ignored as proof of the HDL prohibition.
That binding is removed: the fixture now claims only dependency evaluation and
requires both observations. The withdrawn prohibition claim moves to
`audit_localparam_override_rejected.va`, whose actual named HDL override reports
E0907. The existing duplicate-alias rejection reports E0908; its broad `alias`
substring and obsolete claim that no diagnostic exists are replaced by that pin.
No compiler behavior or source-derived expected value is changed.

The reviewed HTML retains the requirements and examples of §§3.4.3–3.4.7.
Its repaired missing space after `types.` and normalized macro introducer in
the alias example are now explicitly labeled editorial transcription changes.
Neither normalization resolves or changes a language requirement.

The full strict run passes the updated dependency fixture, both pinned
rejections and the existing ordered-override fixture. Its exit remains 1 and
its nonempty normalized FAIL/XFAIL name list is identical to the preceding
inference checkpoint. The measurement script refreshes A/C; the new negative
case strengthens PAR-014 without closing all local-parameter override paths.

## Inherited header/body distinction: PARAM-HEADER-001

IEEE §4.10.1 makes body parameters local when a module parameter port list
contains parameter assignments. AMS §6.2 supplies that header syntax without
removing the inherited restriction. The existing header-default fixture never
declares a body parameter, so it cannot exercise this distinction.

`ch06_hierarchy/audit_header_body_parameter_override_rejected.va` is accepted
by the installed compiler despite its illegal named override. It retains the
required E0907 rejection expectation with an explicit XFAIL. Its legal sibling
`audit_header_body_parameter_dependency.va` overrides only the header value
from 2 to 3 and independently expects header 3 and dependent body 6.
The latter is positive dependency evidence, not proof of override protection.

Parser inspection locates a likely missing classification: `parseModule` appends
header and body declarations to the same parameter list without promoting body
declarations to locals when the header is present. That observation is a repair
lead, not a verified complete fix; host parameter exposure and every elaboration
override path must agree with the classification. No compiler change is made
in this audit checkpoint.

The inherited §12.2.2.1 text also explicitly excludes local parameters from
ordered assignment positions. This independently supports the existing ordered
override fixture, whose earlier header derived the same result from AMS clauses.

The full strict run passes the legal header/dependency fixture and reports the
illegal body override as XFAIL. Comparing normalized FAIL/XFAIL names against
the preceding local-parameter checkpoint adds only that new rejection fixture;
no previous name is removed or replaced. The script-generated report measures
the resulting A/C changes. B remains incomplete and D is unchanged.

## Array size restrictions and source example

`ch06_hierarchy/h01_11_dependent_range_and_array_override.va` already exercises
a legal dependent resize: count changes from two to three and a replacement
array is supplied by the same instance statement. It observes the newly added
element and an order-sensitive weighted sum. This fills a positive mapping gap
in PAR-013; its separate numeric-range assertions do not establish invalid-array
rejection. `audit_parameter_array_exact_override.va` adds independent observations
of all elements for a legal same-size replacement.

Direct `--check --contract` execution accepts all three new invalid inputs:

- PARAM-ARRAY-SIZE-001: two replacement elements for a declared size of three.
- PARAM-ARRAY-SIZE-002: three replacement elements for a declared size of two.
- PARAM-ARRAY-SIZE-003: count increased from two to three without a replacement.

The corresponding `audit_parameter_array_*_rejected.va` fixtures preserve the
required rejection and carry XFAIL markers. Their provisional nonempty `array`
diagnostic substring is not a verified diagnostic code: no rejection currently
occurs. When checks are implemented, verify their locations and pin a specific
code or distinctive rule message before treating the negative side as closed.
Same-module provenance, defparam paths, multidimensional shape and host binding
remain independently open even after these cases are eventually implemented.

The §3.4.8 PDF and HTML both use a comparison threshold of 0.1 while the flag
name and output heading refer to 0.5. The source example also depends on `gen`
and `sink` modules not defined in that example. An editorial HTML note preserves
these facts; the audit does not silently alter the code or treat the incomplete
example as a standalone numeric oracle. Pattern syntax and shape rules still
need independent Annex A and array-section verification.

The full strict run passes both the exact-size fixture and the existing legal
resize fixture. Its normalized FAIL/XFAIL name-list diff adds only the three
new invalid-array XFAILs; existing names are unchanged. This exposes additional
negative-evidence gaps without changing compiler behavior. The measurement
script refreshes A/C from the run; inherited B and architecture D are not closed.
