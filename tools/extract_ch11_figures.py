#!/usr/bin/env python3
"""Restore Chapter 11 source graphs; requires Poppler, not a drawing library.

Rectangles are PDF points (left, top, width, height), physical pages 1-based.
All source pages were visually checked on 2026-09-23. Broad model-page crops
retain the original notes as well as edges; HTML also transcribes those notes.
"""
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
CROPS = {"figure-11-1": (288, 110, 493, 390, 158),
         "legend-11-5-1-2": (293, 85, 68, 475, 660),
         "legend-11-5-3": (294, 85, 68, 475, 660)}
CROPS.update({f"model-page-{p}": (p, 60, 60, 500, 668)
              for p in range(296, 322)})

def main():
    source = ROOT / "docs/VAMS-LRM-2023.pdf"
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Source PDF changed: re-audit every crop first")
    destination = ROOT / "docs/figures"
    destination.mkdir(exist_ok=True)
    for name, (page, left, top, width, height) in CROPS.items():
        subprocess.run([
            "pdftoppm", "-f", str(page), "-l", str(page), "-singlefile",
            "-r", "216", "-x", str(left * 3), "-y", str(top * 3),
            "-W", str(width * 3), "-H", str(height * 3), "-png",
            str(source), str(destination / f"ch11-{name}"),
        ], check=True)
        print(f"{name}: physical {page}; rectangle {left} {top} {width} {height}")

if __name__ == "__main__":
    main()
