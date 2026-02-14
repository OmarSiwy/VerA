#!/usr/bin/env python3
"""Reproduce visually checked Annex E figure/table crops from AMS-2023."""
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
# Physical page; left, top, width, height in PDF points from top left.
CROPS = {
    "figure-e-1": (415, 220, 584, 175, 120),
    "table-e-1-a": (417, 78, 242, 455, 400),
    "table-e-1-b": (418, 78, 68, 455, 555),
    "table-e-1-c": (419, 78, 68, 455, 590),
}

def main():
    source = ROOT / "docs/VAMS-LRM-2023.pdf"
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Source changed: visually re-audit rectangles")
    destination = ROOT / "docs/figures"
    destination.mkdir(exist_ok=True)
    for name, (page, left, top, width, height) in CROPS.items():
        subprocess.run([
            "pdftoppm", "-f", str(page), "-l", str(page), "-singlefile",
            "-r", "216", "-x", str(left * 3), "-y", str(top * 3),
            "-W", str(width * 3), "-H", str(height * 3), "-png",
            str(source), str(destination / f"annex-e-{name}"),
        ], check=True)
        print(f"{name}: physical {page}; rectangle {left} {top} {width} {height}")

if __name__ == "__main__":
    main()
