"""Bounded regression guards, not proof of whole-chapter source fidelity."""
from html import unescape
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Chapter12Source(unittest.TestCase):
    def test_literal_source_entities_and_editorial_boundary(self):
        page = (ROOT / "docs/ch12-vpi-routines.html").read_text()
        rendered = unescape(page)
        self.assertIn("systf_data_p = &amp;(systf_data_list[0]);", rendered)
        self.assertIn("while (systf_data_p-&gt;type)", rendered)
        for name in ("callback-layout", "resistor-source-defects",
                     "sampler-source-defects", "startup-source-defects",
                     "control-source-count"):
            self.assertIn('id="editorial-' + name + '"', page)
        self.assertEqual(page.count("Editorial source note (not LRM text)."), 5)

    def test_no_numbered_hdl_fixture_claims_vpi_execution(self):
        fixtures = ROOT / "tests/fixtures/ch12_vpi_routines"
        for path in fixtures.glob("[0-9]*.va"):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r"(?m)^//! lrm 12(?:\.|$)")


if __name__ == "__main__":
    unittest.main()
