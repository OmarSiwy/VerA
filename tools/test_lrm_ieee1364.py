import unittest

from ieee1364_audit import worklist


class InheritedWorklistTests(unittest.TestCase):
    def test_namespace_page_anchor_and_informative_distinction(self):
        text = ("Contents\n1. Overview ........ 1\n1.1 Scope ........ 1\n"
                "Annex I (informative) Bibliography ........ 2\f"
                "1. Overview\n1.1 Scope\fAnnex I\n(informative)\f")
        rows = worklist(text)
        self.assertEqual([r["id"] for r in rows],
                         ["IEEE1364-2005:1", "IEEE1364-2005:1.1", "IEEE1364-2005:I"])
        self.assertEqual(rows[0]["pdf_page"], 2)
        self.assertEqual(rows[-1]["classification"], "informative")
        self.assertTrue(all(r["heading_located"] for r in rows))
        self.assertTrue(all(r["rule_review"] == "not-assessed" for r in rows))

    def test_missing_anchor_is_not_verified(self):
        text = ("Contents\n1. Overview ........ 1\n1.2 Missing ........ 1\n"
                "Annex I (informative) Bibliography ........ 2\f"
                "1. Overview\fAnnex I\f")
        self.assertFalse(worklist(text)[1]["heading_located"])

    def test_incomplete_toc_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            worklist("Contents\n1. Overview ........ 1\f1. Overview\f")

    def test_known_contents_error_keeps_original_page(self):
        pages = [""] * 215
        pages[0] = ("Contents\n1. Overview ........ 1\n"
                    "14.2.1 Module path restrictions ........ 212\n"
                    "Annex I (informative) Bibliography ........ 214")
        pages[1] = "1. Overview"
        pages[213] = "14.2.1 Module path restrictions"
        pages[214] = "Annex I"
        row = worklist("\f".join(pages))[1]
        self.assertEqual(row["toc_printed_page"], 212)
        self.assertEqual(row["printed_page"], 213)
        self.assertEqual(row["pdf_page"], 214)
        self.assertTrue(row["heading_located"])

    def test_deprecated_is_not_silently_normative_or_closed(self):
        text = ("Contents\n1. Overview ........ 1\n21. Removed ........ 2\n"
                "Annex I (informative) Bibliography ........ 3\f"
                "1. Overview\f21. Removed\fAnnex I\f")
        self.assertEqual(worklist(text)[1]["classification"], "deprecated-removed")


if __name__ == "__main__":
    unittest.main()
