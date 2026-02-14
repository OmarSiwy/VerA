#!/usr/bin/env python3
"""Documentation integrity, not primitive simulation evidence."""
import hashlib
import struct
import unittest
from extract_annex_e_figures import CROPS, ROOT, SOURCE_SHA256

class AnnexEFigures(unittest.TestCase):
    def test_source_links_and_dimensions(self):
        self.assertEqual(hashlib.sha256((ROOT / "docs/VAMS-LRM-2023.pdf").read_bytes()).hexdigest(), SOURCE_SHA256)
        html = (ROOT / "docs/annex-e-spice.html").read_text()
        for name, (_, _, _, width, height) in CROPS.items():
            relative = f"figures/annex-e-{name}.png"
            self.assertIn(f'src="{relative}"', html)
            data = (ROOT / "docs" / relative).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), (width * 3, height * 3))

if __name__ == "__main__":
    unittest.main()
