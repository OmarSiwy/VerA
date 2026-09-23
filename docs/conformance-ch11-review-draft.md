# Chapter 11 source fidelity and VPI evidence audit

Main integration status, 2026-09-23: HTML, source images and fixture metadata
corrections are integrated. Main read the full report and patch, inspected the
relationship legend and representative corrected graphs (physical pages 297,
299, 300, 302, 309 and 321), and regenerated all assets from the hash-checked
PDF. Every generated asset is byte-identical to the parallel reviewer's copy.
Main independently confirmed that all 27 edited fixtures retain identical
executable text and non-Chapter-11 directives. Only the invalid API citations
and explanatory comments change. The documentation test is integrated as
`tools/test_lrm_ch11_figures.py` so existing discovery includes it. Full-suite
metadata verification is pending; no VPI runtime closure is claimed.

Reviewed 2026-09-23. This is a complete first source-reading pass, not an
exhaustive closure claim or a simulation result. Full Verilog-AMS includes
these obligations; absence of a host adapter is not a target exclusion.

## Review boundary and provenance

- Read the complete AMS-2023 Chapter 11, printed pages 274–308, physical PDF
  pages 287–321, against current `docs/ch11-vpi.html`.
- Visually inspected Figure 11-1 (physical 288), all routine tables 11-1
  through 11-10 (290–292), all diagram-legend graphics (293–294), and every
  object-model page (296–321). No diagram page was inferred from extracted
  text alone. The second page of §11.6.22 is physical 318.
- Source SHA-256:
  `e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
- HTML patch baseline SHA-256:
  `f7215c5bd8e0aa086d1267352054dcef3a4ad80462065149f23c1cc681e3adea`.
- Read existing `CONFORMANCE.md` and source-review records first. This adds
  the previously unreviewed Chapter 11 graphs, not a new full-AMS exclusion.
- Inspected current `tests/vpi_host.zig`, `tests/vpi_app.c`, relevant
  `src/vpi/root.zig` exported traversal/property implementations and unit
  tests, `build.zig` VPI wiring, Chapter 11 COVERAGE and P02 specification,
  and numbered HDL-fixture headers/tags. Did not execute Zig suites.

## Repaired source fidelity

The former HTML substituted hand-written prose for every §11.6 graph. The
replacement restores direct rasterizations of the original source, including
class boundaries, arrowheads, edge tags, properties, and notes. Notes also
remain transcribed below their diagrams. These are source reproductions, not
AI redrawings. A graph may state a normative requirement even when its adjacent
prose contains no word `shall`.

| ID | Anchor; printed / physical page | Confirmed defect in former paraphrase |
|---|---|---|
| VPI-GRAPH-001 | `s11-6-2`; 284 / 297 | Nature-to-discipline and nature-to-child are one-to-many, not one-to-one. |
| VPI-GRAPH-002 | `s11-6-3`; 285 / 298 | Scope/taskfunc statement edges and their attachment points were incompletely described; generic double-headed wording obscured reverse cardinality. |
| VPI-GRAPH-003 | `s11-6-4`; 286 / 299 | Ports-to-nodes is one-to-one, not one-to-many; module edge attaches to port, not indiscriminately to the ports class. |
| VPI-GRAPH-004 | `s11-6-5`; 287 / 300 | Nodes-to-branches/nets is one-to-many; reverse edges are one-to-one, not many both ways. |
| VPI-GRAPH-005 | `s11-6-7`; 289 / 302 | Quantities-to-contribs is one-to-many; reverse is one-to-one, not many both ways. |
| VPI-GRAPH-006 | `s11-6-8`–`s11-6-10`; 290–292 / 303–305 | High/low connection paraphrases reversed arrows by describing them as traversal from nets/regs/variables to ports; actual arrows point from ports toward those classes. Unnamed driver/load class boundaries also require preservation. |
| VPI-GRAPH-007 | `s11-6-14`; 296 / 309 | Top-level UDP-definition access uses a double arrow (iteration), not one-to-one from NULL. |
| VPI-GRAPH-008 | `s11-6-25`; 308 / 321 | Reverse traversal from related objects to callbacks is one-to-many, not one-to-one. |
| VPI-GRAPH-009 | `s11-3`, `s11-5`, entire `s11-6` | Restore original graphical notation and all graphs, including otherwise ambiguous inheritance/property attachment points, rather than treat an unverified summary as the normative diagram. |

`tools/extract_ch11_figures.py` validates the source hash and reproduces the
assets with Poppler at 216 dpi. Its rectangles are PDF points from top left:

| Asset | Physical page | Left, top, width, height |
|---|---|---|
| Figure 11-1 | 288 | 110, 493, 390, 158 |
| Object/class/property legend | 293 | 85, 68, 475, 660 |
| Relationship legend | 294 | 85, 68, 475, 660 |
| Each complete model-page content area | 296–321 | 60, 60, 500, 668 |

Wide model-page crops intentionally preserve source headings and notes. Some
pages consequently contain substantial white space. They are not diagrams
reconstructed from the HTML. `tools/test_ch11_figures.py` checks PDF identity,
PNG dimensions, complete asset links, nonempty alt text, unique HTML IDs and
all object-model subsection anchors. This is documentation integrity only.
Accessible, fully structured edge/property tables remain desirable; generic
alt text is not an exhaustive machine-readable graph transcription.

## Source inconsistencies retained, not silently corrected

The HTML editorial note explicitly separates these issues from source text.

| Clause | Issue and consequence |
|---|---|
| 11.3.1, 11.3.2, 11.4 | References to IEEE Verilog section 22 are stale relative to IEEE 1364-2005's removal of deprecated clauses 21–25. Consult the inherited-source ledger; do not silently substitute an older licensed edition. |
| 11.4 | Introductory table range stops at 11-9 although Table 11-10 follows. Retained as source wording. |
| 11.5.2 | Source example spells `vpivector` and `vpi_get_size`, unlike the defined API/property spellings; its string example does not store the returned pointer. These examples must not generate bogus API declarations or fixture requirements. |
| 11.6.1 NOTE 2 | The source says NULL queries of either time-unit or time-precision return the smallest time precision. Preserve this wording and reconcile with routine-specific rules explicitly. |
| 11.6.10 | Note denying real arrays conflicts with AMS §3.2. Do not turn it into a rejection fixture for valid real-array declarations. The figure itself omits real-var-to-var-select membership; this requires interpretation, not silent diagram editing. |
| 11.6.15 | Intermodule-path diagram uses singular delay-routine names, while routine definitions use plural. Source image retains the defect. |
| 11.6.25 NOTE 5 | Current-queue eligibility is qualified by events after read-only synchronization. A future-times-only walk cannot close that boundary. |

## Evidence defects and changes

VPI-EVIDENCE-001: All numbered Chapter 11 HDL-only fixtures formerly claimed
Chapter 11 coverage by analogy. Their Chapter 11 machine tags are withdrawn;
their source, behavioral assertions, language tags and diagnostics are otherwise
unchanged. They remain useful language tests. Withdrawn API claims transfer to
the open groups below, not to a claim that the chapter is out of scope.

VPI-EVIDENCE-002: Existing COVERAGE prose claimed the C host did not exist and
the C rows were unwired. Current `build.zig` contradicts both. The rewritten
COVERAGE distinguishes linked startup-time object-model execution from the
separate compile-only P02/P03 step.

VPI-EVIDENCE-003 (OPEN): `tests/vpi_app.c:check_failures` expects a module
`vpiLineNo` request and an in-range vector-bit lookup to fail because they are
unimplemented. These are required positive capabilities, not invalid-input
conformance tests. The test would reject an implementation that added them.
Separate implementation-limit regression checks from normative tests; represent
the missing positive cases using a host-level expected-failure/XPASS mechanism.
No behavior expectation was changed here without such a mechanism.

VPI-EVIDENCE-004 (OPEN): Existing host opens a lint-elaborated design and runs
startup routines only. Its actual C calls provide useful ABI/object-model
evidence, but no simulation is driven. Dynamic value access, callbacks, time
queues, analog accepted points and solver coupling remain unexecuted by this
host. P02/P03 C compilation cannot close them.

VPI-EVIDENCE-005 (OPEN): The C application currently models disciplined nets
under its limited declaration categories; its scalar/vector checks do not
establish separate node, branch and quantity object identities, nor the graph
relations linking them. The source implementation advertises only a small
object-type set and explicitly rejects bit-level lookup.

## Rule-group decomposition backlog

For each group, enumerate each property, directed edge, type/class inheritance
and adjacent NOTE separately. Test every valid edge through the specified
handle/iterator API, both cardinalities where present, empty-set versus invalid
request behavior, stable identity through `vpi_compare_objects`, and property
values from an independently derived design. This table is not yet an atomic
rule manifest and none of its rows is declared closed.

| Clause group | Required discriminating host evidence |
|---|---|
| 11.1–11.2.1 | Dynamic callbacks: registration, reason/user data, actual dispatch at specified events/time/actions/system-task execution. |
| 11.2.2 | Same-definition sibling instances yield distinct handles and separately derived properties; simulation objects exist in addition to hierarchy. Existing C host partially addresses instance uniqueness. |
| 11.2.3 | Failed real API call sets nonzero error status; details observable; callbacks for errors where specified. Existing C host exercises synchronous error reporting only. |
| 11.3–11.5 | Class inheritance, handle lookup, scalar properties versus specialized delay/value access, iterator exhaustion, NULL top-level traversal; routine tables cross-link to Chapter 12 and inherited API requirements. |
| 11.6.1 | Every module property and child category; top-level iteration and NULL time queries; nested scopes and source/definition locations. |
| 11.6.2 | Multiple disciplines sharing a nature, multiple children of one nature, parent identity, potential/flow natures and parameter assignments. |
| 11.6.3 | Tasks/functions/named blocks, statement-to-scope, IO declarations, function-name object matching type/size/name, scoped declarations and internal scope iteration. |
| 11.6.4 | Port versus port-bit, named/unnamed/explicit port names, port order/direction, parent, high/low connections, own width independent of connection width. |
| 11.6.5 | Node vectors/bits, node/branch/net identity and directed cardinalities, ranges, discipline, implicit declaration/source location. |
| 11.6.6 | Branch vectors/bits, positive/negative nodes, flow/potential quantities, ranges/indices and discipline. |
| 11.6.7 | Quantity/nature/branch/contribution relationships, source/equation-target flags, real/imaginary solved values. |
| 11.6.8 | Expanded/unexpanded net bits, cross-hierarchy loads/drivers on scalar/bit handles, vector versus bit ports, implicit source location, active force/assign filtering, non-net-driven ports. |
| 11.6.9 | Reg bits and parent, active force/assign loads/drivers, hierarchical cont-assign/terminal access, range/index and value APIs. |
| 11.6.10 | Integer/time/real/named-event properties and scope; array selects, domain, value get/put; resolve real-array source conflict explicitly. |
| 11.6.11 | Memory size counts words, word size counts bits; independent array/word ranges and select indices. |
| 11.6.12 | Final parameter value after instance overrides and defparams, override-LHS handle identity, specparam properties and expressions. Existing C host tests declaration classification, not value retrieval. |
| 11.6.13 | Each primitive kind, ordered terminals, input-count size, direction, domain/strength/delays; sequential-UDP-only value mutation boundary. |
| 11.6.14 | Top-level UDP definitions, IO/table/initial relationships; table-entry ASCII vector and string formats, symbol count. |
| 11.6.15 | Module/intermodule paths, delays/conditions/polarity, path terminals, notifier; `$setup` terminal-order exception and multi-handle path lookup. |
| 11.6.16 | Task/function/call identities, ordered arguments, current system-function value, user-defined registration info, NULL current-call and registration iteration. |
| 11.6.17 | Continuous-assignment LHS/RHS/delay and source/strength/net-declaration properties. |
| 11.6.18 | `vpiUse` vector closure includes part/bit uses; bit closure includes parent-vector and containing part-select uses, excluding noncontaining parts. |
| 11.6.19 | Every expression subtype, operand order with multi-concat multiplier first, access-function branch/discipline, parent/range/type/value properties. |
| 11.6.20 | Direct versus indirect flow/potential contribution kinds, LHS/RHS graph differences, branch/value/direct/flow properties. |
| 11.6.21 | Initial/always/analog process graphs, all block/atomic members, statement scope and triggered named-event identity. |
| 11.6.22 | Blocking/nonblocking assignment properties; delay/event/repeat control, NULL statement when attached to assignment; loop condition/init/increment/body relationships. |
| 11.6.23 | If/else edges, all case types, multiple expressions per case-item, default item empty expression iterator. |
| 11.6.24 | Force/assign LHS/RHS, release/deassign LHS, disable target scope and exact source locations. |
| 11.6.25 | Multiple callbacks per related object, registration info, parent queue, top-level unassociated callbacks, increasing queue order, exhausted queue NULL and current-queue eligibility boundary. |

## Verification and measures

Documentation integrity test passed during this patch. Source crops were
generated directly from the hash-checked PDF, with representative final crops
reopened after coordinate adjustment; all original source graph pages were
visually reviewed. Reproduction hashes should be compared again by the main
session before integration. The agent's second extraction produced identical
hashes for all 29 assets. A mechanical comparison against current root confirmed
unchanged executable HDL and unchanged non-Chapter-11 machine directives in all
27 edited numbered fixtures; `git diff --check` exited successfully.

Fixture edits change metadata/comments only, not executable HDL or checks.
They correct the evidence inputs to measure C; only `tools/conformance.sh`
may report the resulting measure. No A/B/C/D improvement or new runtime pass
is claimed here. Full tests and FAIL/XFAIL name-list comparison belong to
main-session integration, not this isolated documentation audit.
