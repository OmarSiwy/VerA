"""Source-review guards for informative annex content, not compiler coverage."""

from html.parser import HTMLParser
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Content(HTMLParser):
    def __init__(self):
        super().__init__()
        self.terms = []
        self.tables = []
        self.in_term = False
        self.term = ""
        self.in_cell = False
        self.cell = ""
        self.row = []

    def handle_starttag(self, tag, attrs):
        if tag == "dt":
            self.in_term, self.term = True, ""
        elif tag == "table":
            self.tables.append([])
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.in_cell, self.cell = True, ""

    def handle_data(self, data):
        if self.in_term:
            self.term += data
        if self.in_cell:
            self.cell += data

    def handle_endtag(self, tag):
        if tag == "dt":
            self.terms.append(self.term)
            self.in_term = False
        elif tag in ("td", "th"):
            self.row.append(self.cell)
            self.in_cell = False
        elif tag == "tr":
            self.tables[-1].append(self.row)


class InformativeSource(unittest.TestCase):
    def test_glossary_exact_term_inventory(self):
        expected = [
            "AMS", "behavioral description", "behavioral model", "block",
            "branch", "compact model", "component", "constitutive relationships",
            "control flow", "child module", "flow", "instance", "instantiation",
            "Kirchhoff’s Laws", "level", "model", "module", "net declaration",
            "node", "NR method", "parameter", "parameter declaration", "port",
            "potential", "primitive", "probe", "reference direction",
            "reference node", "scope", "structural definitions", "terminal",
            "Verilog-A", "Verilog-AMS",
        ]
        parsed = Content()
        parsed.feed((ROOT / "docs/annex-h-glossary.html").read_text())
        self.assertEqual(parsed.terms, expected)

    def test_history_preserves_source_gaps_and_table_cells(self):
        html = (ROOT / "docs/annex-g-changes.html").read_text()
        parsed = Content()
        parsed.feed(html)
        self.assertEqual(len(parsed.tables), 7)
        for index, table in enumerate(parsed.tables):
            for row in table:
                self.assertEqual(len(row), 4 if index == 0 else 3)
        # Printed 415 omits item 14; printed 416 omits item 13.
        self.assertNotIn("14", [row[0] for row in parsed.tables[1][1:]])
        self.assertNotIn("13", [row[0] for row in parsed.tables[2][1:]])
        # Printed 423 contains a genuinely blank Mantis row, not lost HTML.
        self.assertIn(["7893", "", ""], parsed.tables[6])
        self.assertIn("Editorial context (not LRM text)", html)
        self.assertIn("$roi()", html)  # source typo; do not silently rewrite


if __name__ == "__main__":
    unittest.main()
