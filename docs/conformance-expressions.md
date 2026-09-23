# Expression source/evidence worklist

Review date: 2026-09-23. Complete §§4.1–4.2.3 text and examples, physical
pages 64–68, read against HTML. Table 4-3 visually checked on pages 66–67;
its HTML precedence-direction cell now spans the full continued table.
This is a partial obligation grouping, not a certified atomic denominator.

| ID | Source | Obligation / evidence boundary |
|---|---|---|
| EXPR-001 | 4.1 | Expressions include standalone operands; constant-expression contexts restrict operands while admitting the referenced operator/function sets. Each context and inherited constant-expression exception needs separate enumeration. |
| EXPR-002 | 4.2–4.2.1, Tables 4-1/2 | Real operands admit only the listed operators, including modulus; logical/relational results are integer boolean values. A numeric equality check alone cannot establish result type. Every prohibited operator family needs an isolated rejection and legal neighbor. |
| EXPR-003 | 4.2.1 | A real replication factor converts to integer before replication. This requires its own rounding-boundary evidence, not merely assignment-conversion tests. |
| EXPR-004 | 4.2.1.1 | Real-to-integer conversion rounds to nearest with half ties away from zero. `02_numeric_conversions.va` observes positive/negative ties; near-tie, non-tie and runtime-derived cases remain separate. `$rtoi` truncation must not be substituted for implicit conversion. |
| EXPR-005 | 4.2.1.2 | Assignment converts integers to real; x/z bits require an error, with §7.3.2 cross-reference. Known-value conversion cannot close four-state diagnostics. |
| EXPR-006 | 4.2.1.3 | Mixed operand types convert before the operation. The printed nested integer-division example must remain integer before the surrounding real addition. `02_numeric_conversions.va` distinguishes `1/2` from `1/2.0` but does not exercise that nested example; its tags omit this subsection. |
| EXPR-007 | 4.2.2, Table 4-3 | Precedence, left associativity except conditional, and parentheses are distinct requirements. `03_precedence_associativity.va` derives discriminating adjacent-boundary values; representative operators do not establish every spelling, event operator, concatenation or associativity case. Its referenced companion fixtures still need their own audit. |
| EXPR-008 | 4.2.3 | Logical and/or and conditional suppress unnecessary operands when no analog operators are present; other operators preserve observable evaluation effects. `123_short_circuit_side_effects.va` uses inout counters for logical and bitwise cases; `125_short_circuit_ternary.va` tests a constant-false conditional only (its overbroad comment is corrected). `audit_short_circuit_dynamic.va` adds input-derived true/false conditional and logical cases. Runtime errors, x/z conditions and analog-operator exceptions remain open. Optimization may omit work only while preserving observable behavior. |
| EXPR-009 | 4.2.4 | Integer division discards fractional parts toward zero. Negative non-integral quotients must distinguish truncation from floor; unsigned-positive examples alone do not. Width, signedness and overflow need inherited-source reconciliation. |
| EXPR-010 | 4.2.4, Tables 4-4–6 | Modulus follows the dividend's sign, including real operands with the stated ceil/floor formula. `45_modulo.va` observes positive/negative real dividends and most printed examples; `118_modulo_negative_divisor.va` observes the negative integer divisor. `audit_modulus_sign_combinations.va` independently checks all real sign combinations using input-derived dividends and constant divisors. Dynamic divisors and other boundaries remain open. |
| EXPR-011 | 4.2.4 | Zero modulus divisor must produce an error. `111_modulus_by_zero_rejected.va` now isolates the integer error; its formerly combined real expression moves to `audit_real_modulus_zero_rejected.va`. Each independently reports E0601 at its sole invalid expression. Dynamic-zero diagnostics remain separate. Unsupported real-division/infinity commentary was removed, not turned into a conformance claim. |
| EXPR-012 | 4.2.5–4.2.8 | Relational, equality and logical operations produce the specified boolean results and follow their precedence ordering. Negation handles nonzero values, not just one. Case equality inherits IEEE semantics and the analog limits in §7.3.2; the separate Annex C exclusion must not be applied to full AMS. The two-state AMS prose is not sufficient evidence for inherited x/z behavior. Operand-type, signedness, four-state and boundary matrices remain open. |
| EXPR-013 | 4.2.9, Tables 4-9–13 | Bitwise operations apply independently to corresponding bits; both XNOR spellings are listed. Mixed unsigned operands require zero extension; both-signed operands require sign extension. Truth-table values do not establish width/context extension or inherited four-state behavior. The source's odd description of these as “comparison” is retained, not interpreted as booleanizing bitwise results. |
| EXPR-014 | 4.2.10 | All reduction spellings are prohibited inside analog blocks. The seven isolated negative cases below distinguish each spelling. Digital reduction behavior and permissible non-analog contexts require separate positive evidence; analog rejection alone cannot close them. |
| EXPR-015 | 4.2.11 | Arithmetic shifts are prohibited in analog blocks; `05_bitwise_shift.va` and `117_arithmetic_shift_left_rejected.va` separately pin E0324 for right and left arithmetic shifts. `61_shift_right.va` distinguishes logical zero fill from sign extension with a negative integer. `157_shift_negative_count.va` derives unsigned negative-count and over-wide cases; assigning literals to variables alone does not prove they remain runtime operations. Digital arithmetic shifts remain a separate inherited obligation. |
| EXPR-016 | 4.2.12, Syntax 4-1 | Conditional expressions associate right-to-left and select using zero versus nonzero truth, including real conditions. `08_conditional_operator.va` chooses a discriminating nested value and noncanonical true values. Input-derived side effects are in the dynamic evaluation fixture above. Attribute placement, width/type selection and inherited unknown-condition merging remain separate. |
| EXPR-017 | 4.2.13 | Concatenation joins operand bits and excludes unsized numeric constants. Replication counts are constant, nonnegative and known; replicas cannot be assignment targets or output/inout connections. `31_replication.va` derives repeated/nested/zero-count values; `137_replication_lhs_rejected.va` isolates assignment-target rejection. These do not establish every prohibited count or connection. |
| EXPR-018 | 4.2.13 | Zero-count replication is allowed only with a positive-size sibling in its owning concatenation; operands are evaluated exactly once even at zero count. The passing numeric value in `31_replication.va` does not observe width directly or side effects. Its claim that any erroneous one-bit zero replication must change the value is too strong: an extra leading zero can preserve the integer value. Discriminating width and evaluation-count cases remain required. |

Fixture paths above are relative to `tests/fixtures/ch04_expressions`.
Existing fixture headers and the historical COVERAGE table are leads, not
verified results. In particular, the table's “full table” description cannot
replace a per-operator/pair evidence map. B/D are unchanged; A/C updates come
only from the generated measurement report.

## Dynamic evaluation evidence

`audit_short_circuit_dynamic.va` directly executes with fourteen passing checks:
four logical expressions each observe the counter and result; each of two
conditional expressions observes both counters and the selected result. Its
condition comes from a biased net difference, and generated device inspection
confirms conditional branches remain dependent on that input, rather than
being replaced by a constant fixture condition. No claim about transient
history or four-state conditional merging follows from this operating point.

A temporary source mutation replaces the skipped logical `&&` with eager
bitwise `&`. The result remains zero, but the skipped-call counter becomes one
and its assertion prints `ok=0`. This verifies why the side-effect observation
is needed: the numeric result alone would pass the mutant. This is a fixture
sensitivity control, not a compiler mutation or proof of all optimizations.

Tables 4-1/4-2 were subsequently visually checked against physical pages
64–65. Operator spellings, legal-real subset, descriptions and the continued
table entries agree with HTML. This closes their earlier text-only review
limit, not their executable operator/type matrix.

Follow-up reads the complete §4.2.4 text and Tables 4-4–6 against HTML
(physical pages 68–69). Subsequent visual review checks every table row and
the ceil/floor formula, including Table 4-6's continuation. HTML uses ASCII
minus for the source's typographic subtraction dash. The modulus fixtures'
historical “cannot compile” comments have been corrected to describe the old
split, not a current limitation; the latest strict log is authoritative.

The full strict run after adding the dynamic short-circuit fixture passes
that fixture and retains the previous FAIL/XFAIL name list unchanged. Its
nonzero overall exit remains expected from the recorded outstanding failures.

## Isolated modulus evidence

Direct checks of the integer and real zero-divisor fixtures each exit 1 and
report E0601 at the intended modulus expression, without another invalid
operation to satisfy the oracle. The moved real obligation is explicitly named
in the old fixture's header. `audit_modulus_sign_combinations.va` directly
executes with five passing observations, including positive-divisor legal
neighbors and the negative real divisor with both dividend signs. Its header
derives the exact binary-representable remainders independently of VerA.

No assertion is made here that requiring a statically provable nonzero divisor
is itself permitted for every otherwise legal input. That broader implementation
restriction is not the normative zero-divisor rule and needs separate review.

The first full strict rerun after this split was terminated with exit 143
before completion. Its partial rows are not a regression gate or a source
for A/C. A fresh run was started only after confirming that process stopped.
That retry completed with the same FAIL/XFAIL names as the preceding dynamic
short-circuit checkpoint. Both isolated rejection rows and the new sign fixture
pass. The unit gate independently exited 0, and the audit-tool self-tests pass.
The refreshed generated report is the authority for A/C; no B/D obligation is
closed by this fixture split.

The complete §§4.2.5–4.2.8 text/examples were subsequently read against HTML
(physical pages 69–70). No substantive text omission was identified. Inherited
four-state semantics and §7.3.2 need their own reconciled evidence map.

## EXPR-XZ-001 — conflicting case-comparison annotation

AMS §7.3.2, physical pages 181–182, was read completely against HTML. Its
opening permits analog case comparison of discrete x/z values and demonstrates
`dnet === 1'bx`. The later converter example marks the same comparison as an
error. A rendered physical page 182 confirms that the annotation is in the PDF,
not a transcription error. HTML retains it with an explicitly editorial warning.

The referenced IEEE 1364-2005 §5.1.8, printed page 49 / physical page 79,
requires case equality/inequality to compare x/z states explicitly and return
a known boolean. Logical equality instead can produce unknown when the
relation is ambiguous. Width extension, signedness and real conversion are
separate provisions and cannot be inferred from one scalar case comparison.

The explicit AMS permission and its first example support case comparison as
the conversion mechanism; the conflicting error annotation is not a sound
standalone rejection oracle. Ordinary x/z-valued arithmetic/assignment and
contribution remain distinct from comparison producing a known boolean. Keep
the annotation discrepancy recorded; do not claim all mixed-signal conversion
rules or the inherited equality matrix verified by reading these passages.

§7.3.2.1 was also read: special floating-point values in digital expressions
are distinguished from prohibited nonfinite analog branch contributions.
That paragraph does not validate every division-by-zero expression in every
context, reinforcing withdrawal of the old modulus header's broader claim.

## Reduction spelling isolation

The source review reads complete §§4.2.9–4.2.12 (physical pages 70–72),
visually checks Tables 4-9–13 and Syntax 4-1, and restores bold literal `?`
and `:` terminals in HTML separately from grammar repetition braces.

| Spelling | Isolated analog rejection fixture | Diagnostic |
|---|---|---|
| `\|` | `06_reduction_rejected.va` | E0348 |
| `&` | `audit_reduction_and_rejected.va` | E0348 |
| `~\|` | `audit_reduction_nor_rejected.va` | E0348 |
| `~&` | `audit_reduction_nand_rejected.va` | E0348 |
| `^` | `07_reduction_xor_rejected.va` | E0320 |
| `~^` | `audit_reduction_xnor_tilde_caret_rejected.va` | E0320 |
| `^~` | `audit_reduction_xnor_caret_tilde_rejected.va` | E0320 |

The three non-OR operations formerly combined in `06` move to the named
independent fixtures. Each new fixture directly reports its expected diagnostic
at the sole forbidden expression. `07`'s claim that Annex C.5 independently
excludes xor reductions is withdrawn: the PDF's C.5 only excludes case equality.
Its citation is removed and the reduction obligation remains under §4.2.10.
E0320 itself still cites Annex C broadly; that diagnostic attribution is not
evidence of a xor-specific C.5 rule. No existing XFAIL marker was removed.

Legal binary operators sharing these tokens and digital unary reductions must
not be conflated with the prohibited analog unary forms. Their positive
context matrix is not established by this rejection split. B/D are unchanged;
A/C are remeasured by the script rather than inferred from the new file count.

Inherited follow-up: complete IEEE §5.1.11 text/tables (printed pages 51–52)
was read. `digital/expressions.v` has known reductions for AND/NAND, OR/NOR
and XOR/XNOR, plus zero-dominant AND, one-dominant OR and unknown XOR cases.
Its transcript gives the independently justified rows `1 0 0 1 1 0` and
`0 1 x` for those inputs. This is useful existing positive evidence, but does
not cover both XNOR spellings or every table combination, operand width and
single-bit x/z case. `digital/d08_strength_reduction.v` concerns electrical
drive strength, not unary reduction operators, despite the matching filename.
Direct execution of `digital/expressions.v` exits 0 and its complete stdout
matches the committed expected transcript. Only the reduction rows above were
source-audited in this follow-up; a matching transcript does not validate the
independent derivation of every other expectation in that file.

Complete §4.2.13 text/examples on physical pages 72–73 were read against HTML.
The zero-count legality examples and exactly-once sentence are retained. This
reading identifies separate width and side-effect gaps, rather than promoting
the existing constant-value fixture to full replication coverage.

The replication fixture's width-proof claim is now withdrawn in its header
and assigned to open EXPR-018; no executable expectation was changed.

Validation of the reduction split: the full strict run passes all seven
isolated rows and its FAIL/XFAIL names match the preceding modulus checkpoint.
The unit gate exits 0 and audit-tool tests pass. The generated report records
A/C; its static citations are not proof of behavioral completeness.

## REPL-EVAL-001 — zero replication drops operand evaluation

`audit_replication_zero_effect.va` isolates the explicit §4.2.13 requirement
to evaluate the operand once even when the replication count is zero. An
analog function increments a separate inout counter; a positive-size prefix
and suffix make the zero replication legal. The expected counter is one,
independently of the absent result bits. Direct execution produces the correct
concatenated value but a zero counter. The fixture records this as XFAIL,
not a passing behavior or a rejection of an illegal construct.

Inspection of `lib/frontend/parser.zig`, `braceOperands`, locates the loss:
the analog literal-count path appends the operand group in a `0..n` loop.
At zero it retains no operand expression for lowering to evaluate. The digital
path explicitly preserves grouping and the multiplier for this reason. A
correct repair must preserve evaluation and width/context semantics together;
merely special-casing the counter or changing the fixture expectation is invalid.
No compiler change is made in this checkpoint.

`audit_replication_zero_width.va` separately passes one exact observation:
placing the zero replication between a set prefix bit and suffix `0101`
produces 21, whereas inserting an erroneous zero bit there produces 37.
This strengthens the former leading-zero value test without hiding the
independent evaluation failure. Nonzero replication evaluation counts and
all zero-replication placement restrictions remain separate open cases.

The completed strict retry confirms the width fixture passes and adds exactly
one new XFAIL name, `audit_replication_zero_effect.va`; all prior FAIL/XFAIL
names remain unchanged. This is newly exposed nonconformance, not a compiler
regression or verified behavioral coverage. The initial run terminated with
exit 143 and is excluded from measurements. The independent unit run exits 0.

## EXPR-019 — assignment-pattern contexts and repeated groups

Reviewed 2026-09-23: complete §4.2.14 text on physical pages 73–74 against
the HTML; Syntax 4-2 visually checked on physical page 73. Prose, both grammar
alternatives and the six permitted context bullets are retained. Literal
terminals now have bold markup, preserving the distinction between literal
replication braces and grammar repetition notation without changing text.

`audit_assignment_pattern_group.va` covers the repeated comma-separated group
alternative, separately for a constant parameter initializer and a signal-valued
array-variable assignment. Every element of both four-element arrays is checked:
two repeats of `[0.75, 2.5]` give `[0.75, 2.5, 0.75, 2.5]`. Main emitted and ran
the fixture; all eight observations report `ok=1`. This distinguishes grouping
from independently repeating each element. It does not establish side-effect
evaluation count, which is not imported from concatenation replication by
assumption. Existing `144_assignment_pattern_replication.va` samples only ends
of the zero-filled array and one nonzero element, not all elements/alternatives.

The six allowed contexts must remain separately accountable: analog-operator
array arguments, `$table_model` data source, instantiation parameter arrays,
declaration/default assignments, procedural array assignments, and user-defined
function array arguments. The direct result above covers only two contexts.
Boundary sizes, nested arrays, element conversions and isolated context
restrictions remain open. The clause additionally imports IEEE 1800 restrictions
without specifying an edition here; supplied IEEE 1364 is not a substitute
source for those inherited restrictions. No exhaustive atomic denominator or
complete §4.2.14 closure follows from this checkpoint.

Full strict verification of the repeated-group fixture completed with exit 1
due to existing suite debt; its FAIL/XFAIL name list is byte-identical to the
preceding local-discipline checkpoint. The new fixture passes. Evidence logs:
`/tmp/vera-pattern-group-strict.log`, `/tmp/vera-pattern-group-strict.names`,
and `/tmp/vera-pattern-group-coverage.log`. The independent unit gate
(`/tmp/vera-pattern-group-unit.log`) exits 0. A/C refresh is generated by
`tools/conformance.sh`, not entered in this report.
