#!/usr/bin/env python3
"""Bounded source provenance, crop bounds and Chapter 6 integration checks."""

import hashlib
from html.parser import HTMLParser
import struct
import unittest

import extract_ch6_figures as source


class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images = {}
        self.figures = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "figure":
            self.figures.add(attrs.get("id"))
        if tag == "img":
            self.images[attrs.get("src")] = attrs


class ChapterSixFigures(unittest.TestCase):
    def test_source_revision(self):
        pdf = source.ROOT / "docs/VAMS-LRM-2023.pdf"
        self.assertEqual(hashlib.sha256(pdf.read_bytes()).hexdigest(), source.SOURCE_SHA256)

    def test_crop_bounds(self):
        self.assertEqual(set(source.FIGURES), {"6-1", "6-2"})
        for page, left, top, width, height in source.FIGURES.values():
            self.assertIn(page, (151, 174))
            self.assertGreaterEqual(min(left, top), 0)
            self.assertGreater(min(width, height), 0)
            self.assertLessEqual(left + width, 612)
            self.assertLessEqual(top + height, 792)

    def test_png_and_accessible_html(self):
        parser = Images()
        parser.feed((source.ROOT / "docs/ch6-hierarchy.html").read_text())
        for figure, (_, _, _, width, height) in source.FIGURES.items():
            path = f"figures/lrm-figure-{figure}.png"
            data = (source.ROOT / "docs" / path).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), (width * source.SCALE, height * source.SCALE))
            self.assertIn(f"figure-{figure}", parser.figures)
            attrs = parser.images[path]
            self.assertIn(f"Source Figure {figure}", attrs["alt"])
            self.assertEqual(int(attrs["width"]), width * source.SCALE)
            self.assertEqual(int(attrs["height"]), height * source.SCALE)


if __name__ == "__main__":
    unittest.main()
