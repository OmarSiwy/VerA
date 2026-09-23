"""Bounded source-reviewed comment typography guard, not grammar completeness."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CommentSyntax(unittest.TestCase):
    def test_comment_delimiters_are_literals_not_repetition_notation(self):
        page = (ROOT / "docs/ch2-lexical.html").read_text()
        block = re.search(r'<div class="syntax">(.*?)</div>', page, re.S).group(1)
        # AMS2023 physical24/printed11, visually reviewed2026-09-23.
        self.assertEqual(re.findall(r"<b>(.*?)</b>", block), ["//", "/*", "*/"])
        self.assertIn("one_line_comment ::= <b>//</b> comment_text \\n", block)
        self.assertIn("block_comment ::= <b>/*</b> comment_text <b>*/</b>", block)
        self.assertIn("comment_text ::= { Any_ASCII_character }", block)
        self.assertIn("      | block_comment", block)


if __name__ == "__main__":
    unittest.main()
