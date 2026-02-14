"""Regression checks for the source worklist (not language conformance)."""

import unittest
from unittest.mock import patch
from types import SimpleNamespace

from lrm_audit import ChapterHTML, heading, pdf_sections, tokens


class WorklistTests(unittest.TestCase):
    def test_heading_forms(self):
        for title, expected in (("2. Lexical conventions", "2"),
                                ("2.6.1 Integer constants", "2.6.1"),
                                ("Annex C (normative)", "C"),
                                ("C.3 Lexical conventions", "C.3"),
                                ("Table 2-2: Escapes", None)):
            self.assertEqual(heading(title), expected)

    def test_tokens_preserve_semantically_significant_symbols(self):
        self.assertEqual(tokens("first\n word"), tokens("first word"))
        self.assertNotEqual(tokens("a <= b"), tokens("a < b"))
        self.assertNotEqual(tokens("1M"), tokens("1m"))
        self.assertNotEqual(tokens("x ** 2"), tokens("x * 2"))

    def test_no_lossy_hyphen_or_compatibility_folding(self):
        self.assertEqual(tokens("Verilog-\nAMS"), tokens("Verilog-AMS"))
        self.assertNotEqual(tokens("Verilog-\nAMS"), tokens("VerilogAMS"))
        self.assertNotEqual(tokens("a-\nb"), tokens("ab"))
        self.assertNotEqual(tokens("x²"), tokens("x2"))
        self.assertNotEqual(tokens("ﬁ"), tokens("fi"))
        self.assertNotEqual(tokens("a\u00adb"), tokens("ab"))

    def test_html_excludes_navigation_but_keeps_tables_and_subheadings(self):
        parser = ChapterHTML()
        parser.feed('<head><title>ignored</title></head><nav>ignored</nav>'
                    '<h1>2. Lexical conventions</h1><h2>2.7 Strings</h2>'
                    '<p>A &lt; B</p><h3>Table 2-2</h3>'
                    '<table><tr><td>escape</td><td>value</td></tr></table>')
        text = parser.sections['2.7']['text']
        self.assertIn('A < B', text)
        self.assertIn('Table 2-2', text)
        self.assertIn('escape value', text)
        self.assertNotIn('ignored', text)

    def test_duplicate_html_heading_is_visible(self):
        parser = ChapterHTML()
        parser.feed('<h2>2.7 Strings</h2><p>first</p>'
                    '<h2>2.7 Strings again</h2>')
        self.assertEqual(parser.duplicates, ['2.7'])

    @patch('lrm_audit.subprocess.run')
    def test_pdf_front_matter_footer_and_numeric_table_cells(self, run):
        run.return_value = SimpleNamespace(stdout=(
            'Contents\n2. Lexical conventions .... 11\f'
            '1. Verilog-AMS introduction\n1.1 Scope\nsource text\n'
            '2. Lexical conventions\n2.7 Strings\n377\nbyte boundary\n'
            '12\nCopyright © 2024 Accellera\f'))
        sections, _ = pdf_sections('source.pdf')
        self.assertEqual(list(sections), ['1', '1.1', '2', '2.7'])
        self.assertIn('377', sections['2.7']['text'])
        self.assertNotIn('12\n', sections['2.7']['text'])
        self.assertEqual(sections['2.7']['page'], 2)


if __name__ == '__main__':
    unittest.main()
