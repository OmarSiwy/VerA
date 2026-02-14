# Source figures

`lrm-figure-*.png` files are mechanically extracted from the repository's
`VAMS-LRM-2023.pdf`, not redrawn or AI-generated. Copyright © 2024 Accellera
Systems Initiative. The original figure captions are included in the crops.
The PDF remains authoritative.

Chapter 1 figures were visually compared with physical pages 15–17 on
2026-09-23. Direct crops restore the module boundary, branch reference arrows,
and signed loop diagram previously replaced by prose. Original captions remain
inside all three images. Section 1.4's red literals and blue extension production
were separately checked against physical page 21 before restoring HTML colors.

Regenerate with `python3 tools/extract_lrm_figures.py` (requires Poppler's
`pdftoppm`). The script pins the source SHA256 and lists physical PDF page
numbers and crop coordinates in PDF points. It renders directly at 216 dpi
into lossless PNG, without redrawing or resampling. A tested SVG conversion
round trip lost the patterned vertical guides in Figure 4-5, so those converted
vectors were not used. Poppler versions may change rasterization slightly.

Each crop must be visually checked for omitted labels, arrowheads, legends and
caption content. This asset set is partial; absence of a figure here means
its reproduction has not been completed, not that it is unimportant.

Chapter 5 figures were compared with physical source pages 113, 114, 124,
125, 126 and 140 on 2026-09-23. Direct crops replace SVG redraws that closed
the potential-probe gaps in Figures 5-2, 5-3 and 5-5 and moved Figure 5-6's
event dot to the tolerance-box boundary. The original dot is inside the box;
neither the figure nor the accompanying rule requires waiting to its boundary.
Figures 5-3 and 5-4 include their model code in the image. Separately labeled
HTML code transcripts are editorial accessibility aids. Original captions and
the source legends remain inside every crop.

Chapter 7 figures were compared with physical pages 178, 187–190, 197, 199,
201–202 and 212 on 2026-09-23. Direct crops replace PDF-link-only callouts,
preserving hierarchy connections, segmentation and driver/receiver arrowheads.
The PDF places an empty “Figure 7-8:” caption above the same drawing that has
the “Figure 7-9: Connector insertion using merged” caption below it. Both
captions are intentionally retained in `lrm-figure-7-9.png`; the HTML provides
anchors for both numbers, without inventing or duplicating a separate drawing.
Figure code is retained inside the crops; separately labeled HTML transcripts
are editorial accessibility aids, not substitute source diagrams.

Chapter 11 diagrams and legends are generated separately by
`tools/extract_ch11_figures.py`, using the same pinned source hash and 216-dpi
Poppler rendering. The parallel reviewer visually inspected all graph pages;
main inspected the relationship legend and representative corrected graphs,
then regenerated and byte-compared every asset against the reviewed handoff.
Broad page-content crops intentionally retain headings, source notes and white
space. `tools/test_lrm_ch11_figures.py` checks source identity, dimensions,
links and subsection anchors; it does not execute the VPI API or certify each
relationship's implementation. Detailed source/evidence limits are recorded
in `../conformance-ch11-review-draft.md`.

Annex E's schematic and three Table E.1 pages are reproduced with
`tools/extract_annex_e_figures.py`. Main visually inspected all four crops,
regenerated them from the pinned PDF and byte-compared the handoff. Original
clipped sine-equation glyphs and missing grouping remain visible; readable
HTML grouping is explicitly editorial, not a correction to the standard.

Chapter 9 Figures 9-1 through 9-4 are direct source crops at 216 dpi from physical
pages 268, 276, and 277. The sampled isolines, intermediate interpolation construction,
strength encoding and driver/receiver circuit are not editorial redraws.
All original captions are inside the crops; the HTML retains an explicitly
labeled accessible transcription of Figure 9-3. Coordinates and SHA256 hashes
are recorded in `../conformance-ch9-review.md`; literal source typography and
separate behavioral obligations are audited there, without claiming closure.
