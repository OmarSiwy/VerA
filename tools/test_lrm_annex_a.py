"""Bounded Annex A source/evidence guards, not grammar completeness proof."""
from html import unescape
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AnnexASource(unittest.TestCase):
    def test_signed_base_separates_terminals_from_meta_symbols(self):
        page = (ROOT / "docs/annex-a-syntax.html").read_text()
        for base in "dDbBoOhH":
            spelling = "<b>'</b>[<b>s</b>|<b>S</b>]<b>" + base + "</b>"
            self.assertIn(spelling, page)
            self.assertEqual(unescape(re.sub(r"<[^>]*>", "", spelling)),
                             "'[s|S]" + base)
        self.assertIn("lexical character classes", page)
        self.assertIn("Editorial source note", page)


if __name__ == "__main__":
    unittest.main()
