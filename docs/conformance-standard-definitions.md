# Annex D standard definitions: source and evidence worklist

Reviewed 2026-09-23 against the supplied VAMS-2023 PDF, physical pages
406–413, and all of `annex-d-stddefs.html`. This is an incomplete obligation
worklist, not an atomic denominator or a completed-conformance claim.

## Source fidelity

`python3 tools/lrm_audit.py --section D --diff` reports matching D.1 text
tokens. D.2 differs at the PDF's left quotation marks on the fallback `P_U0`
definition; D.3 differs at right quotation marks in based literals and comments.
Rendered pages 412–413 were inspected. The HTML now explicitly identifies its
ASCII punctuation normalization rather than claiming verbatim reproduction.
Annex headings, pagination and editorial notes account for the other displayed
differences. No numeric constant discrepancy was identified in this comparison.
This is not a certification of every source glyph or inherited macro semantics.

## Requirement groups

| ID | Source | Required evidence and current limitation |
|---|---|---|
| STD-001 | D.1, pages 406–410 | Standard nature names, units, access names, default tolerances and derivative/integral relationships. Existing fixtures cover some name binding; units and relationships are not observed. Split every declaration and attribute into atomic rows. |
| STD-002 | D.1 | Each `_ABSTOL` override must be effective when defined before inclusion. `abstol_override_branches.va` explicitly cannot observe the standard override branches under VerA's prepended prelude. Its unrelated potential checks do not discharge this rule. |
| STD-003 | D.1 | Every conservative, signal-flow and discrete discipline has its specified domain and nature bindings. Existing literal fixtures and isolated mismatched-access rejections supply partial evidence, not every binding/context. Apply C.17 separately for the analog profile. |
| STD-004 | D.1–D.3 | Include guards: first inclusion, repeated inclusion and predefined-guard suppression. Repeating an include without observing suppression is insufficient; the automatic prelude confounds first inclusion for disciplines/constants. Driver guard behavior needs dedicated evidence. |
| STD-005 | D.2, page 411 | Every mathematical and physical base macro is available under its published name and has the published expression/value. `mathematical_constants.va`, `vacuum_constants.va`, `celsius_constant.va`, and the new `audit_physical_base_names.va` provide direct observations. The latter checks each vintage-specific physical name, not only selector aliases. |
| STD-006 | D.2, page 412 | Selector precedence and fallback: NIST2018, then SPICE, then OLD, then NIST2010, otherwise NIST1998. Existing five selector fixtures exercise branches and some overlaps, not all combinations, absence/presence transitions or complete macro-expansion semantics. |
| STD-007 | D.2 | `P_U0` selects NIST2018 only in that outer arm, otherwise `P_U0_OLD`. Check both selection and the published parenthesized product expression; exact identity checks share arithmetic with the implementation and cannot independently establish rounding. |
| STD-008 | D.3, page 413 | Each public driver flag has its own published bit, width and unsigned based-literal form. `driver_access_include.va` reads the supplied macros and tests values separately. The low/high fixtures redefine their own masks and cannot establish the supplied definitions. Width/signedness and consumers in driver-access functions remain separate gaps. |

The new base-name fixture fixes its expected observation total with `//! checks`.
An implementation that substitutes correct values directly into `P_Q` etc. but
omits `P_Q_SPICE` now cannot pass this fixture. Decimal literals are transcribed
from the PDF, not obtained from emitted code. Shared literal parsing errors,
sub-ULP differences, and host behavior remain outside this oracle's strength.

## Misleading inherited claims to avoid

The historical fixture coverage file says tolerance values are not readable
from the language because a particular attribute form was rejected by VerA.
That is an implementation limitation, not a language prohibition. It also
mentions nature identifiers in tolerance positions; the complete §5.5.3
attribute-access rules must be used when designing a positive observation.
Do not make compiler non-support the reason to remove an obligation.

The standard-file redistribution permission is not an executable language
requirement. Preserve attribution/license comments in transcriptions, but do
not inflate behavioral coverage by adding an unrelated test citing bare D.
No invalid-input test is needed for a constant merely existing; malformed
macro/directive inputs belong to their actual lexical/preprocessor rules.

Measure impact: additional behavioral evidence contributes to A; D.2 already
has positive citations, so adding another does not establish new rule-level
completeness through C. B and architecture measure D are unchanged. Current
measured results belong only in the script-generated measurement report.

Execution, 2026-09-23: `zig build benchmark -- --strict
annex_d_standard_definitions` exits 0, including the new base-name fixture.
Use a substring filter, not a narrower `--fixture-root`, so the normal
`tests/fixtures` include path still supplies `check.vh`. The full strict run
after this addition exits 1 with the same nonempty normalized FAIL/XFAIL
name list as the preceding keyword checkpoint. No compiler behavior changed.
