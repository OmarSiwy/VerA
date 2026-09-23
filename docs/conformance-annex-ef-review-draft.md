# Annex E/F source and behavioral evidence audit

Reviewed 2026-09-23. Complete first source review, not exhaustive rule closure.
No conformance percentage or suite-wide result is claimed.

## Main integration checkpoint

Integrated 2026-09-23. Main read the complete report, reviewed the HTML/fixture
patches, independently read E.3.2.1 and inspected every new crop. All four assets
were regenerated from the hash-pinned PDF and byte-compared against the handoff.
Direct main execution reproduced all three ordinary-module `ok=1` assertions;
each invalid primitive attribute still exited0 from `--check`, exposing missing
validation. Rule-specific future diagnostic phrases replace the handoff's
overbroad attribute-name substring. Documentation tests passed (26 tests).
Full strict-suite integration results are a separate pending checkpoint.

Subsequent strict integration exited1 with exactly three new XFAIL names:
`audit_primitive_attribute_discrete_rejected.va`,
`audit_primitive_attribute_numeric_rejected.va`, and
`audit_primitive_attribute_unknown_rejected.va` under `annex_e_spice`.
The nonempty name-list diff against the Chapter12 checkpoint contained no other
change. The ordinary-module positive passes in the full suite as well. These
new names expose debt, not a conformance improvement from missing validation.

## Source boundary

- Annex E, normative SPICE compatibility: all printed pages 401–409 / physical
  PDF pages 414–422, compared with current `annex-e-spice.html`.
- Annex F, normative Discipline resolution methods: all printed pages 410–412 /
  physical pages 423–425, compared with current `annex-f-resolution.html`.
- Visually inspected Figure E.1 (415), all Table E.1 pages (417–419), Table E.2
  (421), and every F page (423–425), including list nesting and conditions.
- Source PDF SHA-256:
  `e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
- Existing E/F HTML already contains earlier full prose transcription and
  explicit notes on several source defects. Those repairs are retained, not
  claimed anew. No further Annex F prose omission was found in this pass.

## Documentation repairs

EF-SOURCE-001: Restore Figure E.1 rather than leave a link in place of its
schematic. The common emitter and separate base/collector labels are visible.

EF-SOURCE-002: Add original Table E.1 images beside the searchable transcription.
Its sine cells have clipped leading glyphs and missing opening grouping
parentheses; HTML had silently made the grouping readable. An editorial warning
now distinguishes the readable transcription from a literal facsimile.

Already documented source issues remain: the inductor multiplies rather than
divides by `l`; sine definition lines associate `fmmodfreq` with `f_AM`;
the voltage-PWL tail starts with `I`; the semiconductor-paramset cross-reference
points to 7.5 instead of 6.4. Additional oracle caveats: the PWL bound `i<n`
does not by itself prevent `i+3` exceeding the array, nor explicitly supply
the paired-index stride; the initial expressions of `iexp` and `vexp` differ.
These must not be silently normalized into universal numerical oracles.

The reproducible extractor `tools/extract_annex_e_figures.py` checks source hash
and uses 216-dpi direct Poppler rasterization. All four final crops were opened
and visually checked. Rectangles, in PDF points from top left:

| Asset | Physical page | Left, top, width, height |
|---|---|---|
| Figure E.1 | 415 | 220, 584, 175, 120 |
| Table E.1 first page | 417 | 78, 242, 455, 400 |
| Table E.1 second page | 418 | 78, 68, 455, 555 |
| Table E.1 third page | 419 | 78, 68, 455, 590 |

## Targeted fixture changes and observed results

EF-TEST-001: `audit_attribute_ignored_on_ordinary_instances.va` tests E.3.2.1's
ignored-attribute boundary on an ordinary module instance and a port connection.
The numeric instance value and nonexistent discipline string must not be
validated as analog-primitive attributes. Explicit electrical ports remain
electrical. The independently derived observations are a 0.5-V drop at each
child and total current 0.001 A through two parallel 1000-ohm behavioral children.

Using the existing root `zig-out/bin/vera`, `--check --contract ...` exited 0.
`--emit-exe --contract ...` exited 0; the generated executable exited 0 and
printed all three `ok=1` lines with `got=want`: 0.5, 0.5, and 0.001. This is
targeted generated-device execution, not just compiler acceptance. It says
nothing about analog-primitive attribute validation.

EF-TEST-002: Three separate negative fixtures test analog-primitive attributes
that are numeric, name an undeclared discipline, or name a declared discrete
discipline. E.3.2.1 requires a string naming a valid continuous discipline.
The handoff used `//! reject port_discipline` and an explicit XFAIL for missing
validation. Main tightened these to rule-specific future diagnostic phrases:
the bare attribute name could match a source excerpt in an unrelated error.
These are intended future diagnostics, not claimed existing messages. Running
the existing root compiler's `--check` on each exited 0 (only an unrelated
strict-float warning), demonstrating the missing diagnostic. These are observed
limitations, not newly passing conformance rules. No XFAIL was deleted.

The command form used absolute root compiler/contract/include paths, with the
owned worktree fixture directory also on the include path. No full Zig build or
benchmark suite was run in this worktree. Main must run the integrated harness
and compare FAIL/XFAIL name membership; the new XFAIL names are intentional debt.

## Existing fixture/evidence risks

EF-EVIDENCE-001: Existing primitive-attribute positive fixtures declare the
parent nets rotational as well as writing a rotational attribute. If the
attribute is ignored, E.3.2.2 can derive the same discipline from connectivity.
These remain legal examples, but their claimed discrimination of attribute
precedence is not established. `primitive_segment_scan.va` removes those parent
declarations and is stronger; keep its existing XFAIL until implementation and
behavior agree.

EF-EVIDENCE-002: Parsing a model/subcircuit interface does not demonstrate its
equations, model-card parameter values, internal device cards, source behavior,
or hierarchical multiplicity. E.1.1 is conditional on a declared SPICE flavor,
not permission to count silent body dropping as model execution. The H04 family
exists to expose this distinction. A precise supported-dialect contract and
observable unsupported-input handling are still needed.

EF-EVIDENCE-003: Table E.1 names/order are more portable than numerical behavior:
E.1.2 and E.2 explicitly acknowledge implementation differences. Blank behavior
cells cannot justify fabricated semiconductor/transmission-line equations.
`primitive_inductor.va` deliberately uses `l=1`, where both readings agree;
that is a bounded test, not resolution of the source defect. PWL fixtures use a
VerA-specific `nwave` parameter and explicitly leave index-stride discrimination
open; that extension must not become a universal conformance requirement.

EF-EVIDENCE-004: F.1 allows other algorithms with the same semantics. A passing
end-result fixture cannot prove the compiler's internal post-order traversal.
Current `lib/ir/elaborate.zig:resolveMultiCandidates` explicitly collapses the
default and alternate passes after flattening; its comments retain a first
discipline in the legal-unknown case. Those are implementation choices requiring
independent semantic tests, not proofs that the two modes are interchangeable.

EF-EVIDENCE-005: Annex F COVERAGE called the simulator option a language boundary
but not a debt. F.2.2 explicitly requires option-controlled selection. This has
been corrected: a missing HDL spelling does not remove the host/tool-interface
obligation. Shared step-3/step-4 cases do not test expanded-mode selection or its
top-down step 5. No new F fixture is claimed to exercise those absent controls.

Both COVERAGE files now prominently mark historical green/closed prose as not a
current measurement. They link this audit and its open obligations. Existing
fixture counts and results must be refreshed by measurement, not guessed.

## Rule/evidence decomposition backlog

Each row below contains several atomic obligations that still require separate
IDs, assertions and results. This is not a completed exhaustive ledger.

| Source | Required discriminating evidence / remaining boundary |
|---|---|
| E.1.1–E.2 | Explicit supported SPICE flavor; instantiate every supported primitive/model/subcircuit; distinguish interface recognition from actual model and body execution. |
| E.2.1 | Exact HDL match beats case-insensitive SPICE fallback; case-only HDL difference does not block fallback; distinguish model, primitive, subcircuit and paramset names. |
| E.2.2.1 | Primitive-defined BJT ports, arbitrary instance prefix, positional and named omission of optional substrate. Named omission is still separate from the existing fully named-port case. |
| E.2.2.2–E.2.2.3 | Arbitrary subcircuit instance prefix, native primitive expansion, actual connected oscillator/body behavior rather than only external pin order. |
| E.3 / Table E.1 | Every required primitive/port/parameter name; positional order independently of named order; default electrical/inout; each documented behavior subject to explicit source-ambiguity/dialect contract. |
| E.3.1 | Direct unsupported current-controlled/mutual forms; positive supported SPICE-subcircuit wrapper containing these elements. Direct rejection alone is one-way. |
| E.3.2–E.3.2.1 | Instance attribute, connection attribute, per-port override over instance; string/name/domain checks; ignored ordinary-module attributes; unconnected primitive ports and conflicting but compatible discipline choices. New fixtures address only the validity/ignore boundaries. |
| E.3.2.2 | Scan other lower connections on the same segment independent of declarations/order; continuous-compatible choice, incompatible error, electrical fallback only with no continuous candidate. |
| E.3.3 | Module and paramset exact-name shadowing separately for primitive/model/subcircuit; mandatory warning for model/subcircuit, optional warning for primitive; case-difference noninterference. |
| E.3.4 / Table E.2 | Available limiter names and argument signatures; availability is conditional. Numerical limiter formulas need their own implementation contract, not inference from this naming table. |
| E.4.1–E.4.2 | Multiplicity through instantiated module/subcircuit hierarchy; supported model-card binning/corners; several same-name paramsets selected by 6.4.2. |
| F.1–F.2 | Semantically equivalent implementation permitted; upper/lower parent-child relations retained; top-down versus post-order definitions; continuous precedence at each level, not only across one flattened signal. |
| F.2.1 steps 1–3 | Elaborated upper/lower connections; in-context applicability per instance; out-of-context override at proper scope; conflicting declarations at equal precedence rejected even if compatible. Existing fixtures address parts, not every placement. |
| F.2.1 step 4.a | Digital behavioral use dominates classification; all children digital; mixed continuous/discrete children; repeated/permuted instance order and multi-level hierarchy. |
| F.2.1 step 4.b | Same-domain candidate filtering; zero candidates with matching/mismatching default discipline; one candidate; multiple candidates with resolution statement; unknown legal without crossing versus illegal mixed-port crossing. |
| F.2.1 final step | Observable converter selection/insertion after resolution with correct hierarchy locations and parameter application; acceptance of connectrules is not insertion. |
| F.2.2 mode selection | Explicit simulator option with both basic and expanded settings on one distinguishing topology; record how the fixture driver supplies the option. |
| F.2.2 step 4 | Preserve the alternate classification's unknown case and full candidate rules; its text is not identical to default step 4.a in every branch. |
| F.2.2 step 5 | Revisit both unassigned and previously digital nets; digital behavioral use stays digital; parent-domain classification; parent candidate filtering/default/single/resolution/unknown cases; lower converter placement. |

## Verification and measurement boundary

Source figures/table cells were visually checked, not inferred from text
extraction. Documentation integrity tests check asset links, PNG dimensions and
source identity. Targeted runtime and rejection-check results above are bounded
to the existing root executable. They do not constitute a fresh compiler build,
full-suite gate, or no-regression statement. Only the prescribed measurement
tool may update measures A/C; this patch adds evidence and records open gaps.
