#!/usr/bin/env python3
"""Documentation integrity only: this is not an executed VPI conformance test."""
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import struct
import unittest

from extract_ch11_figures import CROPS, ROOT, SOURCE_SHA256

class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images = []
        self.ids = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "img":
            self.images.append(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])

class Chapter11Figures(unittest.TestCase):
    def test_source_and_assets(self):
        self.assertEqual(hashlib.sha256((ROOT / "docs/VAMS-LRM-2023.pdf").read_bytes()).hexdigest(), SOURCE_SHA256)
        parsed = Images()
        parsed.feed((ROOT / "docs/ch11-vpi.html").read_text())
        self.assertEqual(len(parsed.ids), len(set(parsed.ids)))
        expected = {f"figures/ch11-{name}.png" for name in CROPS}
        self.assertEqual({item["src"] for item in parsed.images}, expected)
        for item in parsed.images:
            self.assertTrue(item.get("alt"))
            data = (ROOT / "docs" / item["src"]).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            name = Path(item["src"]).stem.removeprefix("ch11-")
            width, height = CROPS[name][-2:]
            self.assertEqual(struct.unpack(">II", data[16:24]), (width * 3, height * 3))
        for clause in range(1, 26):
            self.assertIn(f"s11-6-{clause}", parsed.ids)

if __name__ == "__main__":
    unittest.main()
