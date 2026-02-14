"""Tests for the independent keyword inventory/fixture generator."""

import unittest

from lrm_keywords import KeywordTable, fixture


class KeywordInventory(unittest.TestCase):
    def test_editorial_notes_do_not_add_keywords(self):
        parser = KeywordTable()
        parser.feed('<table><tr><td><code>if</code></td>'
                    '<td><code>module</code></td></tr></table>'
                    '<p>Not a keyword: <code>negedgenmos</code></p>')
        self.assertEqual(parser.words, ['if', 'module'])

    def test_escaped_generation_terminates_names_and_pins_observation_count(self):
        source = fixture(['analog', 'if'], 'escaped')
        self.assertIn('//! checks 2\n', source)
        self.assertIn('real \\analog ;', source)
        self.assertIn('observed = \\if ;', source)
        self.assertLess(source.index('\\if  = 2.0;'), source.index('observed ='))
        self.assertIn('`CHECKX("escaped if", observed, 2.0);', source)
        self.assertEqual(source.count('`CHECKX('), 2)

    def test_case_variants_have_independent_values(self):
        source = fixture(['analog', 'if'], 'case')
        self.assertIn('//! checks 4\n', source)
        for name, value in [('ANALOG', 1), ('Analog', 2), ('IF', 3), ('If', 4)]:
            self.assertIn(f'{name} = {value}.0;', source)
            self.assertIn(f'observed = {name};', source)
        self.assertLess(source.index('If = 4.0;'), source.index('observed ='))
        self.assertEqual(source.count('`CHECKX('), 4)


if __name__ == '__main__':
    unittest.main()
