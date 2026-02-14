# Informative annexes G and H source review

Reviewed 2026-09-23 against the supplied AMS-2023 PDF, SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.

## Exact boundary and method

Main integration checkpoint (2026-09-23): the report, HTML editorial note,
coverage corrections, obsolete-generate header and structural tests are now
integrated. Main read the full handoff and independently checked A.6.4/A.6.8,
the source glossary N/R entries and the target HTML anchors. Main did not repeat
the worker's complete visual pass. Combined documentation tests passed (26).
The fixture's executable body and rejection expectations are unchanged.

- Annex G: printed 413–425, physical pages 426–438, from the annex heading
  through the complete G.2.4 compiler-directive paragraph.
- Annex H: printed 426–429, physical pages 439–442, from the annex heading
  through the final Verilog-AMS glossary definition (end of document).
- Read all extracted source text and both current root HTML files. Viewed all
  physical pages 426–442, not only token comparisons. Table G.1–G.7 row/cell
  associations, continuations and Figure G-1 literal/optional syntax were
  checked against those renders. H has no tables or numbered figures.
- Mechanical `lrm_audit.py --section G --diff` / `--section H --diff` were
  additional worklists; the large combined G output was truncated by the tool.
  The full source text and every source page were independently read, so the
  review does not depend on assuming that truncated diff was complete.

No missing source paragraph, history row or glossary term was found in these
HTML files. Table continuations are merged into one HTML table per source
table; row membership and empty cells are retained. Fonts and page layout are
not facsimiles: many source bold keywords are merely monospaced in HTML.
Figure G-1 is a syntax box, faithfully transcribed including literal commas
and parentheses versus optional brackets; no diagram was replaced by prose.
No new image asset was necessary.

## Preserved source oddities (not invented repairs)

| Source location | Observation / disposition |
|---|---|
| Table G.1, printed 413 | Historical brace-only array example is incomplete as printed; preserve history, derive modern grammar from Chapter 3 / Annex A. |
| Table G.2, printed 415 | Item 14 absent in the PDF; do not invent a missing HTML row. |
| Table G.3, printed 416 | Item 13 absent in the PDF; same disposition. |
| Table G.3 item 23, printed 417 | `$R` is printed in the historical change description. This is not a license to replace current format-specifier rules. |
| Table G.6, printed 420–422 | Historical spelling errors such as “flownodes” and “anaog” retained; old clause numbers retained, not silently renumbered to current clauses. |
| Table G.7, printed 423 | Mantis 7893 has genuinely empty description and clause cells. Mantis 7920 actually prints `$roi()`; do not rewrite source text to `$rtoi()` without an editorial label. |
| G.2.3, printed 424–425 | Describes obsolete analog generate syntax. It is not the current module-level generate grammar. Bounds/index descriptions are historical, not new execution obligations. |
| H, printed 427–429 | “an component”, “globalanalog”, and scope's reference to braces are printed source wording. They remain in the HTML rather than silently redefining the glossary. |

## Corrections implemented

INFO-G-SCOPE-001: An explicitly labeled editorial context note now distinguishes
G.2's historical analog forms from current digital `forever` (A.6.8) and current
generate constructs (§6.6). The original annex wording remains untouched.
Independently read source A.6.4 (printed 368–369 / physical 381–382) and A.6.8
(printed 372 / physical 385)
to verify this distinction. A.6.4 has no obsolete generate-statement alternative;
A.6.8 includes digital `forever` but not analog `forever`.

INFO-G-EVIDENCE-001: The G fixture ledger claimed the supersession sentence
converted informative history into requirements. Corrected that premise:
history can motivate a test, but current normative clauses must derive it.
The ledger's old pass/count assertions are explicitly historical, not rerun
measurements. Its obsolete claim that fixtures 02/03/22 still cite nonexistent
section G.7 is superseded; current root files already cite G.1. Table numbers
must not be treated as clause IDs.

INFO-G-GENERATE-001: Fixture `06_obsolete_generate.va` previously carried only
G.1/G.2.3 references despite the ledger's assertion that all fixtures also cited
a current normative clause. Added A.6.4, corrected the old loop-generate clause
reference to §6.6, and removed stale unsupported-modern-generate prose. The
fixture body and expected E0209 / `generate` diagnostics are unchanged. A direct
`vera --check` after the header repair exited 1 with E0209 at the intended
obsolete analog `generate` token. This does not establish modern generate
behavior, and no new positive runtime test was invented for retired syntax.

INFO-H-INVENTORY-001: H's ledger claimed 38 terms and included “nesting level”,
“node declaration” and “run time binding”; none is a glossary term in the source.
`rg -c '^<dt>' docs/annex-h-glossary.html` measured 33 terms, independently
confirmed term-by-term against all four source pages. Corrected the count and
N/R inventories, withdrew the phantom-term gaps, and removed the inference that
two historically green tests imply no outstanding related normative debt.
The actual N terms are net declaration, node and NR method; R contains reference
direction and reference node. No runtime rules were inferred from informative
definitions.

INFO-H-VT-001 remains OPEN, handed to the Chapter 9 owner: fixture
`annex_h_glossary/09_nonlinear_nr_relationship.va` derives a narrow `$vt` window
from Annex D constant sets. This source-fidelity review does not validate that
normative §9.15 requires those sets. No numerical fixture expectation was changed
here. Its diode-law assertion must be re-derived if the `$vt` premise changes.

## Tests and scope

Added `tools/test_lrm_informative.py`: exact glossary-term inventory, seven
history tables with preserved cell shape, historical row gaps, the genuine blank
7893 row, explicit editorial labeling, and preservation of source `$roi()`.
These structural checks guard the reviewed representation, not compiler behavior
or independent semantic conformance. The targeted unittest command exited 0
with two tests. `git diff --check` exited 0.

Only the obsolete-generate fixture's cite/header changed. No compiler code,
numeric oracle, runtime transcript, broad-suite result or measured A/C percentage
was changed or claimed. Main integration owns the full test gate and FAIL/XFAIL
name-list comparison. Annex G/H source fidelity is now reviewed end-to-end;
their related normative obligations remain with the owning chapters and inherited
IEEE clauses, not a new denominator made from historical rows/glossary terms.

Handoff paths: this report, `docs/annex-g-changes.html`, both G/H fixture
`COVERAGE.md` files, `annex_g_change_history/06_obsolete_generate.va`, and
`tools/test_lrm_informative.py`. `annex-h-glossary.html` required no content edit.
