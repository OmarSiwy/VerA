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

    def test_invalid_legacy_positive_is_not_normative_evidence(self):
        fixture = (ROOT / "tests/fixtures/annex_a_syntax/46_library_source_text.va").read_text()
        self.assertIn("NOT a normative positive", fixture)
        self.assertIn("A-EVID-001", fixture)
        self.assertIn("//! xfail", fixture)
        self.assertNotRegex(fixture, r"(?m)^//! lrm ")


if __name__ == "__main__":
    unittest.main()
