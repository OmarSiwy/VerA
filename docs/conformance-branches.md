# Branch and namespace source/evidence worklist

Review date: 2026-09-23. Complete §§3.12–3.13.4 text (physical pages 61–63)
read against HTML. Syntax 3-9 was visually checked on page 61; literal
parentheses, port angle brackets, index/range brackets, commas and semicolons
now have explicit HTML markup, unlike optional/repeated grammar notation.
Figures 3-1/3-2 were restored and visually checked in the earlier figure pass.
No complete branch/namespace behavioral matrix is claimed.

| ID | Source | Obligation / evidence boundary |
|---|---|---|
| BR-001 | 3.12 | Conservative branches have potential and flow; signal-flow branches have only their applicable quantity. One-terminal branches reference ground. Both explicit terminals require compatible disciplines. Cross-discipline access checks do not alone establish branch-declaration validation. |
| BR-002 | 3.12 | Named branches and the single unnamed branch between a pair coexist. Reversed orientation must not silently create an independent unnamed branch. Voltage equality alone cannot distinguish independent parallel branch currents; observations must exercise branch identity and flow. |
| BR-003 | 3.12 | Vector terminals must have equal size unless the other terminal is scalar; corresponding elements connect. `33_vector_branches.va` observes distinct values with shifted terminal bounds and default branch indices. `44_vector_branch_size_mismatch.va` isolates the negative and pins E0353. |
| BR-004 | 3.12 | Scalar/vector branches fan each vector element to the scalar endpoint. Unspecified branch ranges start at zero. Ascending/descending explicit ranges, sliced terminals, declared branch ranges and hierarchy require independent mapping. |
| BR-005 | 3.12.1 | Port branches measure flow into ports across upper/lower connections and preserve scalar/vector shape. `22_port_branch.va` solves the port-flow unknown rather than prescribing it and expects 2/1000 from a resistive load. Vector ports, hierarchical references and reactive port flow need separate cases. |
| NS-001 | 3.13.1 | Nature/discipline names have global scope shared across modules. Acceptance within one module does not establish multi-module visibility, declaration-order behavior or namespace collisions. |
| NS-002 | 3.13.2 | Previously defined access names enter module scope unless another identifier there has that name; base-nature access names must be unique. Hiding, ordering and uniqueness are separate obligations. |
| NS-003 | 3.13.3 | Nets belong to module/port scope, not block scope, and use access functions determined by their disciplines. `48_net_local_to_block.va` pins parser E0214; its moved-to-module control compiles. Dedicated scope diagnostics and the full valid-local-declaration matrix remain open. |
| NS-004 | 3.13.4 | Branch names follow module-only scope and discipline-specific access. `49_branch_local_to_block.va` pins parser E0209 and is distinct from the net case because the grammar productions differ; its moved-to-module control compiles. |
| NS-005 | 3.13.3–3.13.4 | Hierarchical net and branch references follow inherited IEEE rules. A flat module's local access cannot prove those rules or their access/scope errors. |

Fixture names without a chapter prefix are under `tests/fixtures/ch03_data_types`.
The source's port-branch example omits an explicit port-direction declaration;
the executable fixture supplies one. Treat examples as illustrations in their
context rather than importing every omission as a standalone grammar exception.

The vector fixture's header formerly used wording from an editorial diagram
description as if it were a direct §3.12 quotation. It now paraphrases the
source's corresponding scalar nets without quotation marks. Derived values
are unchanged.

## Rejection isolation follow-up

`44_vector_branch_size_mismatch.va` now pins E0353 and removes unnecessary
reads of the invalid branch, which previously generated cascading E0351
diagnostics. Direct execution reports only the terminal-size mismatch.
`48_net_local_to_block.va` pins E0214 at the forbidden net declaration, and
`49_branch_local_to_block.va` pins E0209 at the branch keyword. These last
two remain parser diagnostics, not dedicated scope explanations. A future
replacement must be verified against the intended declaration rather than
loosening the oracle to a generic failed phase.

Temporary controls change only the vector size to match, move the net
declaration to module scope, or move the branch declaration to module scope.
Each compiles with exit 0. These controls verify that the isolated syntactic
change removes the rejection; they are not credited as behavioral evidence
for branch currents, scope lookup or the full grammar.

Validation: the full strict run after these diagnostic changes retains exactly
the previous FAIL/XFAIL name list (compared with the compatibility checkpoint).
All three edited rejection rows pass. The generated measurement report records
the unit gate and the still-failing strict/digital suites; strengthening these
oracles does not increase the A/C numerator or close B/D obligations.
