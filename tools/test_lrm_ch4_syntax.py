#!/usr/bin/env python3
"""Guard rendered Chapter4 syntax, parsing entities before collecting text.

Baseline is the syntax text from root HTML SHA256
c452aae6c5868af5538ce84d989bb3ae83b51e3047b9157784190688dca188fe.
This guards typography-only edits; it is not proof of full LRM fidelity.
"""
from html.parser import HTMLParser
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASELINE_SYNTAX_SHA256 = "c206b78ed2fa1dbba040bb45b5056ecb6ce58f10dfce7c977f8f595a0f6f4ff3"


class SyntaxText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.parts = []
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        if tag == "div":
            if self.depth:
                self.depth += 1
            elif "syntax" in dict(attrs).get("class", "").split():
                self.depth = 1
                self.parts = []

    def handle_endtag(self, tag):
        if tag == "div" and self.depth:
            self.depth -= 1
            if not self.depth:
                self.blocks.append("".join(self.parts))

    def handle_data(self, data):
        if self.depth:
            self.parts.append(data)


def syntax_text(source):
    parser = SyntaxText()
    parser.feed(source)
    parser.close()
    if parser.depth:
        raise ValueError("Unclosed syntax display")
    return parser.blocks


def digest(blocks):
    return hashlib.sha256(json.dumps(blocks, ensure_ascii=False).encode()).hexdigest()


class Chapter4Syntax(unittest.TestCase):
    def test_rendered_syntax_matches_pre_markup_root(self):
        source = (ROOT / "docs/ch4-expressions.html").read_text()
        blocks = syntax_text(source)
        self.assertTrue(blocks)
        self.assertEqual(digest(blocks), BASELINE_SYNTAX_SHA256)

    def test_entities_are_not_split_by_markup(self):
        for path in sorted((ROOT / "docs").glob("*.html")):
            with self.subTest(path=path.name):
                source = path.read_text()
                self.assertIsNone(re.search(r"&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9a-fA-F]+)<", source))

    def test_regression_rejects_tag_stripping_before_entity_decode(self):
        good = '<div class="syntax">&zeta;</div>'
        broken = '<div class="syntax">&zeta<b>;</b></div>'
        self.assertEqual(syntax_text(good), ["ζ"])
        self.assertNotEqual(syntax_text(good), syntax_text(broken))


if __name__ == "__main__":
    unittest.main()
