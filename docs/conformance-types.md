# Data-type source and evidence inventory

Review date: 2026-09-23. Initial scope: AMS §§3.1–3.2.1, physical PDF pages 37–38,
complete extracted text read against the HTML; Syntax 3-1 and numeric
superscripts visually checked on page 37. This is a partial Chapter 3 review,
not a complete rule denominator. The earlier chapter-level token comparison
did not establish these semantic or typographic distinctions.

## Source fidelity

Prose, examples, initialization-context distinctions and the output-variable
scope rule correspond to the supplied source. Syntax 3-1 previously bolded
only the declaration keywords. It now distinguishes all literal terminals:
semicolons, commas, assignment signs and the array dimension's brackets/colon.
Optional-initializer brackets and repeated-dimension braces remain grammar
notation, not literal characters. The distinction was checked against the
colored source rather than inferred from plain extracted text.

The source's sentence about arrays of `parameter` inside §3.2 is retained as
published; it has not been silently rewritten to `real`. Any intended broader
interpretation must be tied to the other declaration/parameter clauses.

## Requirement groups and present evidence

| ID | Clause | Obligation / evidence boundary |
|---|---|---|
| TYPE-001 | 3.1 | Inherited integer/genvar/real/parameter semantics, SystemVerilog-derived string semantics, wreal and net disciplines require distinct inventories. Mentioning a type does not close its syntax, values, operations or host behavior. Resolve incorporated-source editions and AMS modifications explicitly. |
| TYPE-002 | 3.2 / Syntax 3-1 | Declaration lists, dimensions, constant expressions and assignment-pattern alternatives require both valid and isolated invalid cases. `01_integer_real_variables.va` observes scalar declaration initializers, not every grammar alternative. |
| TYPE-003 | 3.2 | Integer range and two's-complement arithmetic require width/sign/boundary evidence, not just a small positive value. Reconcile inherited sizing with AMS §2.6.1; do not infer one universal expression width from an implementation carrier. |
| TYPE-004 | 3.2 | Real storage follows the stated double-precision model. A correctly computed 2.5 or 7.5 does not establish representation boundaries, precision, subnormals or exceptional values. Independent boundary oracles remain open. |
| TYPE-005 | 3.2 | Array bounds are constant integer expressions and may be positive, negative or zero. `02_variable_arrays.va` observes negative, zero and singleton bounds and nonaliasing writes; `61_nonconstant_array_dimension.va` rejects a runtime bound with E0308. Descending/multidimensional forms and all invalid-bound variants require further mapping. |
| TYPE-006 | 3.2 | Integers assigned in analog context start at zero. `55_integer_real_default_init.va` reads the default before assigning in analog context, then observes a nonzero product. It does not prove initialization across restarts, every array element or repeated solver evaluations. |
| TYPE-007 | 3.2 | Integers assigned in digital context start at x. Analog default tests cannot cover this obligation. Digital scalar/array observations and declaration-initializer overrides need explicit mapping, with no assumption of zero. |
| TYPE-008 | 3.2 | Reals start at zero. The default fixture observes an analog scalar; digital reals, arrays, instance independence and reset/sweep behavior remain separate cases. |
| TYPE-009 | 3.2.1 | Module-scope desc-only, units-only or combined attributes create simulator-accessible output variables. `lrm_3_2_1.va` covers all three declarations and internal values but does not query exported metadata or values through a simulator/host interface. This is incomplete evidence for accessibility. |
| TYPE-010 | 3.2.1 | Block-local descriptions/units are ignored by the simulator. Need a negative exposure test proving no exported local entry, alongside an accessible module-level control. Merely accepting the attributes does not demonstrate scope filtering. |

Fixture names above refer to `tests/fixtures/ch03_data_types`. Existing coverage
inventories and implementation tests are leads, not inherited verified status.
In particular, contract shape checks on `op_vars`/`opValues` would not alone
prove desc-only/units-only selection, correct metadata or current host values.

## Oracle constraints

- Initialization claims refer to simulation start, not an invented reset on
  every analog evaluation. A first-evaluation test cannot settle persistent
  variable behavior across iterations or accepted timepoints.
- The assignment context matters even when a value is read before its first
  write. Tests must establish that context rather than infer it from the file
  extension or the spelling `integer`.
- Range examples and displayed operating-point examples do not impose the
  example's numeric value or a particular simulator UI on all implementations.
- Output-variable access needs an external observer. Asserting a model's own
  assignment back inside that model cannot detect omitted export metadata.

The initial §§3.1–3.2.1 pass changed source fidelity and evidence classification
only. It added no runtime coverage or change to A/C, historical B, or
architecture D. The subsequent §3.3 work and added fixtures are recorded below;
the remaining Chapter 3 sections and source dependencies stay open.

## String follow-up: §3.3

On 2026-09-23 the complete §3.3 text (physical pages 38–40) was read against
the HTML, including rendered pages 39–40 and every Table 3-3 row. The table
preserves the operand-context distinctions and the examples retain the
different treatment of an empty literal in integral versus string contexts.
The declaration syntax now marks literal equals/semicolon tokens in bold;
its optional-initializer brackets remain grammar notation. Typographic quote
normalization in the example's `8'b0` is editorial, not a changed value.

| ID | §3.3 obligation | Evidence / remaining work |
|---|---|---|
| STR-001 | String variables have dynamic length, default empty, and no truncation merely from assignment to string. | Existing variable/array fixtures are leads; changing lengths, long values and instance independence need systematic review. Fixed-size scratch buffers must not silently establish a language bound. |
| STR-002 | Conversion of a literal to string removes every NUL rather than terminating at the first. | `25_string_nul_removal.va` distinguishes removal from truncation and an all-NUL literal from nonempty text. Multiple positions/lengths and arrays remain separate cases. |
| STR-003 | Literal assignment to integral types right-justifies with left truncation/zero extension. | `73_string_literal_to_integral.va` observes truncation, extension and the integral empty-literal byte. Its declaration-width assumption needs the companion integer-width review; it is not a width-independent proof for all targets. |
| STR-004 | A string-typed value cannot be assigned to an integral target. | `52_string_to_integral_rejected.va` pins E0354; the independent legal literal fixture prevents treating all string spellings as invalid. Other string-producing expressions and target contexts need isolated rejection cases. |
| STR-005 | Two literal equality operands use integer semantics; a string-typed operand selects string conversion/comparison. | New typed-context comparisons pass, but `audit_string_literal_equality.va` fails as STR-LITERAL-001. Neither context may substitute for the other. |
| STR-006 | String relationals are lexicographical and inequality negates equality. | `audit_string_comparison_context.va` independently observes empty/prefix/equal boundaries and typed NUL conversion. The older `26` sums operators, allowing some compensating errors; the new assertions do not. Reverse false cases, character ranges and all operand combinations remain open. |
| STR-007 | Concatenation selects string or integral semantics from operand/context types. | `27_string_concatenation.va` observes mixed typed/literal operand order, not the complete all-literal/context matrix. |
| STR-008 | Integral replication multipliers may be nonconstant for string results; constant literal replication follows numeric replication before string conversion. | `28_string_replication.va` covers a fixed variable value and constant copies. Changing runtime counts, invalid multiplier types, integral-target prohibition and bounds need further independent cases. |
| STR-009 | Arrays, multidimensional arrays and declaration initialization are supported. | Existing `23`/`24` fixtures require full semantic review, including nonaliasing, default values and mutation. Acceptance is not closure. |

### STR-LITERAL-001: literal-only equality loses context

The new isolated literal fixture derives `"A\0"` as unsigned 0x4100 and
`"A"` as unsigned 0x41. Zero-extending the latter does not make them equal.
Actual execution instead reports equality true and inequality false. The
positive fixture is retained as an XFAIL, not rewritten as a rejection.

The independent passing fixture compares a string-typed `"A"` value with the
literal containing NUL. In that context removal is required and equality is
correct. Its remaining lexicographical checks each have their own observation,
and both new fixtures declare expected check counts.

`lowerBinary` currently keeps two string-typed operands in the string family,
and `foldStrBinary` also orders string constants as text. These are relevant
sites to review for lost literal/context distinctions; this audit has not
implemented a fix or established that changing either site alone is sufficient.
No passing result is credited for the isolated failure or the whole §3.3 clause.

The full strict run exits 1. Its nonempty normalized FAIL/XFAIL name-list diff
against the preceding default-width checkpoint adds only
`XFAIL ch03_data_types/audit_string_literal_equality.va`; all prior names remain.
The separate comparison fixture passes. These observations strengthen A's
evidence while exposing an additional limitation; C is still a static citation
inventory. No new historical B or architecture D closure is claimed. The
aggregate measurements are regenerated solely by `tools/conformance.sh`.
