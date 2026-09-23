import contextlib
import io
import os
import pathlib
import unittest

from inventory_vpi_annex_g import clean, macros, render


class InventoryTests(unittest.TestCase):
    def test_comments_and_empty_macro(self):
        self.assertEqual(macros(clean("#define GUARD\n/* #define FAKE 3 */\n#define ALIAS OTHER\n")),
                         [("GUARD", ""), ("ALIAS", "OTHER")])

    def test_conditional_alternatives_retained(self):
        self.assertEqual(macros("#define PORT __declspec(dllimport)\n#define PORT\n"),
                         [("PORT", "__declspec(dllimport)"), ("PORT", "")])

    @unittest.skipUnless(os.environ.get("IEEE_PDF") and os.environ.get("VPI_HEADER"),
                         "licensed PDF and comparison header supplied explicitly")
    def test_licensed_source_inventory(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            render(pathlib.Path(os.environ["IEEE_PDF"]), pathlib.Path(os.environ["VPI_HEADER"]))
        text = output.getvalue()
        for name in ("vpiBitXnorOp", "vpiBitXNorOp", "vpiSysFuncSized",
                     "s_vpi_value.value.strength", "s_vpi_time.high", "s_vpi_time.low",
                     "s_cb_data.cb_rtn", "s_cb_data.index", "vpi_handle_multi",
                     "vpi_handle_by_multi_index", "vlog_startup_routines"):
            self.assertIn(f"| `{name}` |", text)
        # Commented repeats must not manufacture duplicate symbol obligations.
        self.assertEqual(text.count("| `vpiNoChange` |"), 1)
        self.assertEqual(text.count("| `vpiLargeCharge` |"), 1)
        self.assertEqual(text.count("| `s_vpi_value.value.strength` |"), 1)


if __name__ == "__main__":
    unittest.main()
