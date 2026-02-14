#!/usr/bin/env python3
"""Reproduce Chapter 6 diagrams directly from the pinned source PDF.

Coordinates are PDF points from the top-left of physical pages. Captions
are included. Poppler pdftoppm is required; no redrawing or resampling.
"""

import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
SCALE = 3
FIGURES = {
    "6-1": (151, 190, 247, 232, 132),
    "6-2": (174, 103, 300, 423, 110),
}


def main():
    source = ROOT / "docs/VAMS-LRM-2023.pdf"
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Source PDF changed: re-audit crop coordinates first")
    destination = ROOT / "docs/figures"
    destination.mkdir(exist_ok=True)
    for figure, (page, left, top, width, height) in FIGURES.items():
        output = destination / f"lrm-figure-{figure}"
        subprocess.run([
            "pdftoppm", "-f", str(page), "-l", str(page), "-singlefile",
            "-r", str(72 * SCALE), "-x", str(left * SCALE),
            "-y", str(top * SCALE), "-W", str(width * SCALE),
            "-H", str(height * SCALE), "-png", str(source), str(output),
        ], check=True)
        print(f"Figure {figure}: PDF page {page}, box {left} {top} {width} {height}")


if __name__ == "__main__":
    main()
