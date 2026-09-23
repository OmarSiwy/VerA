# Chapter 6 source-figure reproduction checkpoint

2026-09-23. This supersedes only the Figure6-1/6-2 link-only limitation in
conformance-hierarchy.md. It does not close behavioral or remaining source
obligations. Figure6-3 remains the existing explicitly labeled transcription.

Current-root HTML base SHA256:
2c1441d6e279752da4fa26dfb748ced919f575eadf27b3dd447aa74554e6d3ec.
Only the opening figure description and two figure callouts were changed.
No grammar, example or semantic prose was altered.

Source: docs/VAMS-LRM-2023.pdf, SHA256
e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134.
Reviewed complete rendered physical151/174 (printed138/161), then directly
inspected both generated crops, checking labels, lines, complete borders and
original captions. Source Figure6-1's wiring is reproduced as printed, not
inferred from nearby example code. Figure6-2 retains both op1/op2 children.

Coordinates are PDF points from the top-left of physical pages. Poppler
pdftoppm rasterizes directly at216dpi (scale3), lossless PNG, no resampling.

| Figure | page,left,top,width,height | PNG dimensions | SHA256 |
|---|---|---|---|
|6-1|151,190,247,232,132|696×396|b2ab2a48804f33f73922d24b89e4a2e85ac381149658a5acd16e86f8cc0378f2|
|6-2|174,103,300,423,110|1269×330|e8c52478da531e9d9d15de6866e0ba7c18ba8d6f2f2ac35a1e1b65fc4b1c5306|

Reproduce: `python3 tools/extract_ch6_figures.py`. Source hash mismatch aborts
before writing. Check: `python3 tools/test_ch6_figures.py`. Tests check pinned
PDF identity, bounds, PNG sizes and accessible HTML associations; they do not
replace the visual comparison. Dedicated tools avoid shared figure-script
ownership conflicts. No compiler, fixture or measured conformance changed.

Main integration checkpoint: inspected both supplied crops, reviewed the HTML
diff and extractor, regenerated both crops, and confirmed byte equality with
the worker assets. All three dedicated source-figure tests pass in the root.
