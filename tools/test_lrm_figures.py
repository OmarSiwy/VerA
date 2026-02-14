"""Structural guards for PDF figure assets; visual fidelity is reviewed separately."""

import hashlib
from html.parser import HTMLParser
import struct
import unittest

from extract_lrm_figures import FIGURES, ROOT, SOURCE_SHA256


class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images = []
        self.ids = []
        self.svg_count = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "img":
            self.images.append(attrs)
        if tag == "svg":
            self.svg_count += 1
        if "id" in attrs:
            self.ids.append(attrs["id"])


class SourceFigures(unittest.TestCase):
    def test_chapter_one_figures_and_convention_colors(self):
        expected = {"1-1", "1-2", "1-3"}
        self.assertEqual({key for key in FIGURES if key.startswith("1-")}, expected)
        html = (ROOT / "docs/ch1-intro.html").read_text()
        self.assertIn('.syntax b { color: #c00000; }', html)
        self.assertIn('.syntax.extension { color: #2020b0; }', html)
        self.assertIn('<div class="syntax extension">connectrules_declaration', html)

    def test_chapter_seven_preserves_shared_figure_captions(self):
        expected = {f"7-{n}" for n in range(1, 12)} - {"7-8"}
        self.assertEqual({key for key in FIGURES if key.startswith("7-")},
                         expected)
        parser = Images()
        parser.feed((ROOT / "docs/ch7-mixed-signal.html").read_text())
        self.assertEqual(parser.svg_count, 0)
        # 7-8 is a source caption above the same drawing captioned 7-9 below.
        # Both remain addressable, without fabricating a separate image.
        for n in range(1, 12):
            self.assertEqual(parser.ids.count(f"figure-7-{n}"), 1)
        matches = [i for i in parser.images
                   if i.get("src") == "figures/lrm-figure-7-9.png"]
        self.assertEqual(len(matches), 1)

    def test_chapter_five_uses_all_source_figures(self):
        # These redraws previously changed open probe paths into wires and
        # moved the timing-event dot. Guard against silently reintroducing
        # inline substitutes; visual comparison remains a separate review.
        expected = {f"5-{n}" for n in range(1, 7)}
        self.assertEqual({key for key in FIGURES if key.startswith("5-")},
                         expected)
        parser = Images()
        parser.feed((ROOT / "docs/ch5-analog.html").read_text())
        self.assertEqual(parser.svg_count, 0)
        for key in expected:
            self.assertEqual(parser.ids.count(f"figure-{key}"), 1)

    def test_source_revision(self):
        self.assertEqual(hashlib.sha256((ROOT / "docs/VAMS-LRM-2023.pdf")
                                       .read_bytes()).hexdigest(), SOURCE_SHA256)

    def test_chapter_nine_source_figures(self):
        expected = {f"9-{n}" for n in range(1, 5)}
        self.assertEqual({key for key in FIGURES if key.startswith("9-")}, expected)
        parser = Images()
        parser.feed((ROOT / "docs/ch9-system.html").read_text())
        for key in expected:
            self.assertEqual(parser.ids.count(f"figure-{key}"), 1)
            filename = f"figures/lrm-figure-{key}.png"
            matches = [item for item in parser.images if item.get("src") == filename]
            self.assertEqual(len(matches), 1)
            self.assertTrue(matches[0].get("alt"))
            data = (ROOT / "docs" / filename).read_bytes()
            _, _, _, width, height = FIGURES[key]
            self.assertEqual(struct.unpack(">II", data[16:24]), (width * 3, height * 3))

    def test_crops_are_inside_source_pages(self):
        for figure, (page, x, y, width, height) in FIGURES.items():
            with self.subTest(figure=figure):
                self.assertGreater(page, 0)
                self.assertLessEqual(page, 442)
                self.assertGreaterEqual(x, 0)
                self.assertGreaterEqual(y, 0)
                self.assertGreater(width, 0)
                self.assertGreater(height, 0)
                self.assertLessEqual(x + width, 612)
                self.assertLessEqual(y + height, 792)

    def test_assets_and_html_references(self):
        for figure, (_, _, _, width, height) in FIGURES.items():
            with self.subTest(figure=figure):
                filename = f"figures/lrm-figure-{figure}.png"
                data = (ROOT / "docs" / filename).read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(data[12:16], b"IHDR")
                self.assertEqual(struct.unpack(">II", data[16:24]),
                                 (width * 3, height * 3))
                chapter = figure.split("-")[0]
                paths = list((ROOT / "docs").glob(f"ch{chapter}-*.html"))
                self.assertEqual(len(paths), 1)
                parser = Images()
                parser.feed(paths[0].read_text())
                matches = [i for i in parser.images if i.get("src") == filename]
                self.assertEqual(len(matches), 1)
                self.assertTrue(matches[0].get("alt"))
                self.assertEqual(parser.ids.count(f"figure-{figure}"), 1)


if __name__ == "__main__":
    unittest.main()
