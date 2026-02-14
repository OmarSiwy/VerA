# Genvar source and evidence worklist

Review date: 2026-09-23. Complete AMS §3.5 text (physical pages 46–47)
was read against the HTML. Syntax 3-3 was visually checked on physical page
46; literal semicolon/comma tokens now have explicit bold markup in the HTML,
distinct from the repetition braces. This is a partial rule ledger, not a
claim that all analog or digital generate semantics have been verified.

| ID | Source | Obligation and evidence boundary |
|---|---|---|
| GEN-001 | 3.5, Syntax 3-3 | Genvars are integer-valued static variables; comma-separated declarations use the illustrated grammar. The nested dependency fixture declares several genvars. Integer limits, redeclarations and all scope contexts need separate mapping. |
| GEN-002 | 3.5 | Assignments belong in for-loop control, not ordinary statements. `50_genvar_assigned_outside_loop.va` now pins E0313 at the assignment and has no distracting read of the same name. Loop-body assignments and distinct initialization/iteration misuse remain separate cases. |
| GEN-003 | 3.5 | Assignment expressions may contain static parameters, literals and other genvars. `audit_genvar_static_dependencies.va` exercises parameter bounds and inner-loop initialization/bounds from an outer genvar, observing the weighted sum and count separately. Other arithmetic forms, negative/decreasing bounds and overrides remain open. |
| GEN-004 | 3.5 | Nonstatic assignment expressions are forbidden. `50_genvar_nonstatic_loop_control.va` pins E0419 for a solution-dependent probe in iteration. Initialization and guard expressions need independent evidence and their §5.9.3 grammar constraints. |
| GEN-005 | 3.5; 5.9.3 | Static loop expansion preserves iterations and zero-trip behavior. `09_genvar.va` observes the literal-bound sum; the new dependency fixture also observes an initially false guard. Neither proves all loop-control semantics or termination diagnostics. |
| GEN-006 | 3.5; 5.5.2; 4.5.15 | Genvars permit indexed analog access and analog operators in unrolled contexts. `ch05_analog_behavior/analog_genvar_loop.va` observes a nonuniform bus sum. Its DC derivative checks do not distinguish separate per-instance operator histories. Time-varying independent-state evidence remains open. |

Fixture paths without a chapter prefix are under `tests/fixtures/ch03_data_types`.
IEEE digital generate semantics and implicit local parameters are distinct
inherited obligations; do not infer their closure from these analog loops.

## Corrected evidence claims

The original `09_genvar.va` header incorrectly called its accumulator the LRM's
own example and referred to §5.7.3. The §3.5 example instead contributes through
indexed signals, and analog_for is §5.9.3. The header now identifies its own
derived sum and explicitly does not claim an observable post-loop genvar value.
The arithmetic expectation is unchanged; an expected observation count is added.

The outside-loop negative previously accepted a generic failed-compilation phase
and also read the genvar in a contribution, producing an independent E0314.
Direct inspection showed E0313 at the assignment itself. Removing the read and
pinning that assignment diagnostic isolates the claimed prohibition. E0313 is
currently a namespace diagnostic, not a genvar-specific explanation; any future
replacement must be reviewed rather than loosening the oracle to any error.

The nested case derives (i,j) pairs (1,1), (1,2), (2,2), (2,3). Summing 10*i+j
gives 68 across four iterations. A separate loop starts at 3 with condition
less than 1 and must execute no body. These assertions add independent static
dependency observations; simply accepting the syntax would not establish them.

Direct self-checking execution reports `ok=1` for the weighted sum, nested
trip count and empty-loop count. Rechecking the isolated illegal assignment
reports only E0313 at that target, with process exit 1; the unrelated E0314 is
gone. These targeted results do not close the remaining rule matrix.

The full strict run exits 1 with the same nonempty normalized FAIL/XFAIL name
list as the array checkpoint. The added positive and both strengthened existing
fixtures pass. The measurement script refreshes A/C from this run; no inherited
B or architecture D closure is claimed.
