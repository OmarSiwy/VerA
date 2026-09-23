#!/usr/bin/env python3
"""Reproduce selected LRM figures from the checked-in PDF, without redrawing.

Requires Poppler's pdftoppm. Coordinates are PDF points measured from the
top-left of a physical page. Crops include the original figure caption.
Adding an entry requires visual comparison against the source page.
"""

import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
# figure: (physical page, left, top, width, height), all coordinates in points.
FIGURES = {
    "1-1": (15, 152, 349, 310, 150),
    "1-2": (16, 163, 403, 285, 104),
    "1-3": (17, 88, 312, 436, 262),
    "3-1": (62, 180, 78, 252, 154),
    "3-2": (62, 184, 293, 244, 150),
    "4-3": (81, 135, 78, 345, 290),
    "4-4": (85, 88, 175, 437, 220),
    "4-5": (85, 127, 565, 359, 137),
    "4-6": (86, 136, 103, 340, 130),
    "4-7": (87, 150, 439, 310, 154),
    "4-8": (88, 150, 140, 310, 154),
    "4-9": (88, 150, 332, 310, 153),
    "4-10": (89, 150, 90, 310, 152),
    "4-11": (89, 150, 280, 310, 150),
    "4-12": (90, 150, 90, 310, 152),
    "4-13": (91, 148, 590, 316, 114),
    "4-14": (104, 125, 202, 360, 352),
    "5-1": (113, 130, 404, 352, 131),
    "5-2": (114, 130, 79, 352, 210),
    "5-3": (124, 105, 551, 402, 143),
    "5-4": (125, 119, 127, 374, 146),
    "5-5": (126, 128, 79, 355, 225),
    "5-6": (140, 88, 93, 436, 144),
    "7-1": (178, 105, 390, 402, 206),
    "7-2": (187, 111, 294, 390, 242),
    "7-3": (188, 87, 463, 500, 258),
    "7-4": (189, 87, 258, 500, 258),
    "7-5": (190, 87, 162, 500, 260),
    "7-6": (197, 87, 150, 500, 262),
    "7-7": (199, 152, 78, 308, 600),
    # One source drawing has an empty 7-8 caption above and the 7-9 caption
    # below. Keep both captions in this single crop, not duplicate drawings.
    "7-9": (201, 119, 67, 374, 465),
    "7-10": (202, 117, 210, 378, 458),
    "7-11": (212, 87, 78, 438, 380),
    "8-1": (214, 158, 78, 296, 469),
    "8-2": (216, 158, 78, 296, 516),
    "8-3": (220, 130, 78, 352, 202),
    "8-4": (221, 90, 238, 470, 310),
    "8-5": (222, 90, 90, 471, 309),
    "8-6": (224, 90, 90, 470, 292),
    "8-7": (225, 88, 98, 474, 280),
    "9-1": (268, 160, 86, 305, 214),
    "9-2": (268, 137, 463, 370, 222),
    "9-3": (276, 64, 403, 484, 141),
    "9-4": (277, 150, 417, 312, 216),
}


def main():
    source = ROOT / "docs/VAMS-LRM-2023.pdf"
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Source PDF changed: re-audit page and crop coordinates first")
    destination = ROOT / "docs/figures"
    destination.mkdir(exist_ok=True)
    # Direct PDF rasterization preserves patterned guide lines that were lost
    # in a pdftocairo-SVG/librsvg round trip during visual validation.
    scale = 3  # 216 dpi; lossless PNG, no resampling or generative processing.
    for figure, (page, left, top, width, height) in FIGURES.items():
        output = destination / f"lrm-figure-{figure}"
        subprocess.run([
            "pdftoppm", "-f", str(page), "-l", str(page), "-singlefile",
            "-r", str(72 * scale), "-x", str(left * scale),
            "-y", str(top * scale), "-W", str(width * scale),
            "-H", str(height * scale), "-png", str(source), str(output),
        ], check=True)
        print(f"Figure {figure}: PDF page {page}, box {left} {top} {width} {height}")


if __name__ == "__main__":
    main()
