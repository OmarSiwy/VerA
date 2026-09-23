"""Synthetic and retained-snapshot tests; no simulator conformance credit."""

from pathlib import Path
import unittest

from vcd_semantics import VcdError, compare_artifacts, parse_vcd

ROOT = Path(__file__).resolve().parents[1]
GOLDENS = ROOT / "tests/fixtures/ch09_system_tasks"


def header(declarations, metadata=""):
    return (metadata + "$timescale 1 ns $end $scope module top $end "
            + declarations + " $upscope $end $enddefinitions $end ")


class SemanticVcd(unittest.TestCase):
    def test_trailing_scope_exit_does_not_change_declared_paths(self):
        # 18.2.1's declaration repetition and 18.2.3.3/.6 do not prescribe
        # an empty current scope at enddefinitions. This is a bounded path
        # equivalence check, not certification of the complete file grammar.
        balanced = header('$var reg 1 ! a $end') + '#0 0!'
        unexited = balanced.replace('$upscope $end ', '')
        self.assertEqual(parse_vcd(balanced).semantic_projection(),
                         parse_vcd(unexited).semantic_projection())

    def test_comparison_checks_metadata_independently_of_semantics(self):
        reference = header('$var reg 1 ! a $end') + '#0 $dumpvars 0! $end'
        actual = ('$date today $end $version Writer $dumpfile(path_expr) $end '
                  + reference + ' $comment size limit reached $end')
        compare_artifacts(actual, reference, dumpfile_text='$dumpfile(path_expr)',
                          comment_text='limit reached')
        for broken in (actual.replace('$dumpfile(path_expr)', 'Writer'),
                       actual.replace('size limit reached', 'unrelated comment')):
            with self.assertRaises(VcdError):
                compare_artifacts(broken, reference,
                                  dumpfile_text='$dumpfile(path_expr)',
                                  comment_text='limit reached')

    def test_legal_codes_order_and_layout_do_not_change_meaning(self):
        first = header('$var reg 1 ! a $end $var reg 4 " v [3:0] $end')
        first += '#0 $dumpvars 0! b0 " $end #1 1! b1010 "'
        # '$end' is a legal printable identifier code in its grammar position.
        second = header('$var reg 4 $end v[3:0] $end $var reg 1 xy a $end')
        second += '# 0\n$dumpvars B0 $end 0xy $end #1 B1010 $end 1xy #2'
        self.assertEqual(parse_vcd(first).semantic_projection(),
                         parse_vcd(second).semantic_projection())

    def test_metadata_is_retained_not_discarded(self):
        metadata = ('$date today $end $version ExampleWriter '
                    '$dumpfile(name_expression) $end ')
        doc = parse_vcd(header('$var reg 1 ! a $end', metadata)
                        + '#0 $dumpvars 0! $end #1 '
                        '$comment dump limit was reached $end')
        doc.require_metadata()
        self.assertEqual(doc.metadata_text("$version"),
                         ["ExampleWriter $dumpfile(name_expression)"])
        self.assertEqual(doc.metadata_text("$comment"), ["dump limit was reached"])
        self.assertEqual(doc.metadata[-1][0], 1)
        missing = parse_vcd(header('$var reg 1 ! a $end'))
        with self.assertRaisesRegex(VcdError, "missing nonempty"):
            missing.require_metadata()

    def test_comments_cannot_hide_a_changed_value(self):
        base = header('$var reg 1 ! a $end') + '#0 $dumpvars 0! $end #1 '
        correct = parse_vcd(base + '$comment limit reached $end')
        wrong = parse_vcd(base + '$comment limit reached $end 1!')
        self.assertNotEqual(correct.semantic_projection(), wrong.semantic_projection())

    def test_checkpoints_remain_distinct(self):
        base = header('$var reg 1 ! a $end')
        body = '#0 $dumpvars 0! $end #2 $dumpoff x! $end #4 $dumpon 0! $end'
        doc = parse_vcd(base + body + ' #6 $dumpall 0! $end')
        self.assertEqual([event[1] for event in doc.events],
                         ["$dumpvars", "$dumpoff", "$dumpon", "$dumpall"])
        self.assertNotEqual(doc.semantic_projection(),
                            parse_vcd(base + body).semantic_projection())

    def test_aliases_follow_the_same_code(self):
        doc = parse_vcd(header('$var wire 1 ! a $end $var wire 1 ! alias $end')
                        + '#0 $dumpvars 1! $end')
        self.assertEqual(len(doc.events[0][2]), 2)
        self.assertEqual({value for _, value in doc.events[0][2]}, {"1"})

    def test_case_sensitive_names_and_codes(self):
        good = header('$var reg 1 A net $end')
        with self.assertRaisesRegex(VcdError, "undeclared identifier"):
            parse_vcd(good + '#0 1a')

    def test_vector_unknown_extension_and_same_variable_history(self):
        doc = parse_vcd(header('$var reg 4 ! v [3:0] $end')
                        + '#0 $dumpvars bX10 ! $end #1 bZX0 ! b0X10 !')
        self.assertEqual(doc.events[0][2][0][1], "xx10")
        self.assertEqual(doc.events[1][2][0][1], ("zzx0", "0x10"))

    def test_invalid_structure_rejected(self):
        base = header('$var reg 1 ! a $end')
        for body in ('#2 0! #1 1!', '#0 0 !', '#0 1missing',
                     '#0 $dumpvars 0! 1! $end', '#0 b001 !'):
            with self.subTest(body=body), self.assertRaises(VcdError):
                parse_vcd(base + body)
        with self.assertRaisesRegex(VcdError, "shortest"):
            parse_vcd(header('$var reg 4 ! v [3:0] $end') + '#0 b0000 !')

    def test_unsupported_profiles_fail_loudly(self):
        for kind, body in (("real", "r1 !"), ("event", "1!")):
            with self.subTest(kind=kind), self.assertRaises(NotImplementedError):
                parse_vcd(header(f'$var {kind} 1 ! a $end') + '#0 ' + body)
        with self.assertRaises(NotImplementedError):
            parse_vcd(header('$var port 1 <0 a $end'))

    def test_retained_goldens_are_semantic_examples_not_complete_headers(self):
        first = parse_vcd((GOLDENS / "d09_11_vcd_dumpvars.expected.vcd").read_text())
        second = parse_vcd((GOLDENS / "d09_12_vcd_dumpoff_on.expected.vcd").read_text())
        self.assertEqual(first.timescale, (1, "ns"))
        self.assertEqual(len(first.variables), 2)
        self.assertEqual([e[0] for e in first.events], [0, 1, 2, 3])
        self.assertEqual([e[1] for e in second.events],
                         ["$dumpvars", "change", "$dumpoff", "$dumpon", "change", "$dumpall"])
        for doc in (first, second):
            with self.assertRaises(VcdError):
                doc.require_metadata()


if __name__ == "__main__":
    unittest.main()
