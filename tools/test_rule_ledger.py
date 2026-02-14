import copy
import json
import hashlib
from pathlib import Path
import unittest
import tempfile

from rule_ledger import LedgerError, validate, validate_html_links, validate_evidence_files


class RuleLedgerTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / 'docs/rules/ieee-readmem.json'
        self.ledger = json.loads(path.read_text())

    def test_candidate_valid_without_claiming_closure(self):
        self.assertTrue(validate(self.ledger))
        self.assertEqual(self.ledger['completeness_review'], 'pending')
        self.assertNotIn('verified', {r['status'] for r in self.ledger['rules']})

    def test_evidence_bytes_not_just_hash_shape(self):
        item = self.verified_shape()['cases'][0]['evidence'][0]
        item['runner_path'] = 'runner.bin'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path_key, hash_key in [('fixture', 'fixture_sha256'),
                                       ('runner_path', 'runner_sha256'),
                                       ('artifact', 'artifact_sha256')]:
                payload = ('synthetic ' + path_key).encode()
                (root / item[path_key]).write_bytes(payload)
                item[hash_key] = hashlib.sha256(payload).hexdigest()
            self.assertEqual(validate_evidence_files(self.ledger, root), 1)
            (root / item['artifact']).write_text('changed')
            with self.assertRaisesRegex(LedgerError, 'artifact_sha256 mismatch'):
                validate_evidence_files(self.ledger, root)
            (root / item['artifact']).unlink()
            with self.assertRaisesRegex(LedgerError, 'missing bundle file'):
                validate_evidence_files(self.ledger, root)

    def test_bundle_path_and_missing_runner_are_rejected(self):
        item = self.verified_shape()['cases'][0]['evidence'][0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / item['fixture']).write_text('fixture')
            item['fixture_sha256'] = hashlib.sha256(b'fixture').hexdigest()
            with self.assertRaisesRegex(LedgerError, 'runner_path'):
                validate_evidence_files(self.ledger, root)
            item['fixture'] = '../outside.v'
            with self.assertRaisesRegex(LedgerError, 'outside root'):
                validate_evidence_files(self.ledger, root)

    def test_unbundled_open_evidence_is_not_authenticated(self):
        self.assertEqual(validate_evidence_files(self.ledger, '.'), 0)

    def test_all_retained_candidates_validate(self):
        directory = Path(__file__).resolve().parents[1] / 'docs/rules'
        for path in sorted(directory.glob('*.json')):
            with self.subTest(path=path.name):
                self.assertTrue(validate(json.loads(path.read_text())))

    def test_retained_html_links_exist(self):
        root = Path(__file__).resolve().parents[1]
        for path in sorted((root / 'docs/rules').glob('*.json')):
            with self.subTest(path=path.name):
                self.assertTrue(validate_html_links(json.loads(path.read_text()), root))

    def test_html_target_is_not_inferred_from_prose(self):
        self.ledger['rules'] = self.ledger['rules'][:1]
        trace = self.ledger['rules'][0]['html_trace']
        trace.update(path='chapter.html', anchor='rule', relation='direct-text')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'chapter.html'
            with self.assertRaisesRegex(LedgerError, 'missing HTML file'):
                validate_html_links(self.ledger, directory)
            path.write_text('<p>The string id="rule" is not an anchor.</p>')
            with self.assertRaisesRegex(LedgerError, 'missing HTML anchor'):
                validate_html_links(self.ledger, directory)
            path.write_text('<h2 id="rule">Rule</h2>')
            self.assertTrue(validate_html_links(self.ledger, directory))

    def test_html_path_cannot_escape_root(self):
        self.ledger['rules'] = self.ledger['rules'][:1]
        self.ledger['rules'][0]['html_trace']['path'] = '../outside.html'
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(LedgerError, 'outside root'):
                validate_html_links(self.ledger, directory)

    def test_missing_source_rejected_even_when_open(self):
        del self.ledger['rules'][0]['source']['passage']
        with self.assertRaisesRegex(LedgerError, 'passage'):
            validate(self.ledger)

    def test_missing_or_empty_scope_rejected(self):
        for value in (None, '', '   '):
            self.ledger['scope'] = value
            with self.subTest(value=value), self.assertRaisesRegex(LedgerError, 'scope'):
                validate(self.ledger)

    def test_missing_oracle_rejected(self):
        del self.ledger['rules'][0]['cases'][0]['derivation']
        with self.assertRaisesRegex(LedgerError, 'derivation'):
            validate(self.ledger)

    def test_missing_html_mapping_rejected(self):
        del self.ledger['rules'][0]['html_trace']
        with self.assertRaisesRegex(LedgerError, 'path'):
            validate(self.ledger)

    def test_unresolved_html_mapping_cannot_close(self):
        for relation in ('missing', 'unresolved'):
            rule = self.verified_shape()
            rule['html_trace']['relation'] = relation
            with self.subTest(relation=relation), self.assertRaisesRegex(
                    LedgerError, 'HTML trace'):
                validate(self.ledger)

    def test_tags_do_not_close_rule(self):
        rule = self.ledger['rules'][0]
        rule['status'] = 'verified'
        with self.assertRaisesRegex(LedgerError, 'runtime evidence'):
            validate(self.ledger)

    def verified_shape(self):
        # Synthetic validator inputs ONLY, never execution evidence.
        rule = self.ledger['rules'][0]
        self.ledger['rules'] = [rule]
        rule['status'] = 'verified'
        rule['independent_review'] = 'synthetic unit-test review placeholder'
        rule['profiles']['verilog-a'] = {
            'applicability': 'outside', 'reason': 'synthetic profile decision only',
            'source': 'synthetic source; not a real applicability decision',
        }
        rule['cases'][0]['evidence'] = [{
            'fixture': 'synthetic.v', 'assertion': 'synthetic transcript',
            'runner': 'synthetic --run', 'revision': 'synthetic-revision',
            'result': 'pass', 'level': 'production-execution',
            'provenance': 'synthetic test only', 'limits': 'not real evidence',
            'artifact': 'synthetic.log', 'artifact_sha256': 'a' * 64,
            'fixture_sha256': 'b' * 64, 'runner_sha256': 'c' * 64,
        }]
        return rule

    def test_shape_accepts_explicit_runtime_bundle(self):
        self.verified_shape()
        self.assertTrue(validate(self.ledger))

    def test_compile_and_kernel_results_cannot_close(self):
        for level in ('citation', 'compile', 'unit-execution'):
            rule = self.verified_shape()
            rule['cases'][0]['evidence'][0]['level'] = level
            with self.subTest(level=level), self.assertRaisesRegex(LedgerError, 'runtime'):
                validate(self.ledger)

    def test_acceptance_case_cannot_close(self):
        self.verified_shape()['cases'][0]['kind'] = 'acceptance'
        with self.assertRaisesRegex(LedgerError, 'acceptance'):
            validate(self.ledger)

    def test_missing_runtime_artifact_cannot_close(self):
        del self.verified_shape()['cases'][0]['evidence'][0]['artifact']
        with self.assertRaisesRegex(LedgerError, 'runtime'):
            validate(self.ledger)

    def test_failed_runtime_cannot_close(self):
        self.verified_shape()['cases'][0]['evidence'][0]['result'] = 'fail'
        with self.assertRaisesRegex(LedgerError, 'runtime'):
            validate(self.ledger)

    def test_no_legal_neighbor_cannot_close_prohibition(self):
        rule = self.verified_shape()
        rule['class'] = 'prohibition'
        rule['invalid_input']['disposition'] = 'required'
        rule['cases'][0]['kind'] = 'diagnostic'
        with self.assertRaisesRegex(LedgerError, 'legal neighbor'):
            validate(self.ledger)

    def test_pass_cannot_hide_conflicting_production_result(self):
        for result in ('fail', 'blocked', 'not-run'):
            rule = self.verified_shape()
            conflicting = copy.deepcopy(rule['cases'][0]['evidence'][0])
            conflicting['result'] = result
            rule['cases'][0]['evidence'].append(conflicting)
            with self.subTest(result=result), self.assertRaisesRegex(
                    LedgerError, 'conflicting or unresolved'):
                validate(self.ledger)

    def test_whitespace_artifact_cannot_close(self):
        self.verified_shape()['cases'][0]['evidence'][0]['artifact'] = '   '
        with self.assertRaisesRegex(LedgerError, 'artifact'):
            validate(self.ledger)

    def test_one_pass_cannot_hide_unexecuted_case(self):
        rule = self.verified_shape()
        extra = copy.deepcopy(rule['cases'][0])
        extra['id'] = 'boundary'
        extra['evidence'] = []
        rule['cases'].append(extra)
        with self.assertRaisesRegex(LedgerError, 'runtime'):
            validate(self.ledger)

    def test_no_certified_denominator(self):
        self.ledger['denominator'] = 'certified'
        with self.assertRaisesRegex(LedgerError, 'denominator'):
            validate(self.ledger)

    def test_unresolved_profile_cannot_close(self):
        rule = self.verified_shape()
        rule['profiles']['verilog-a']['applicability'] = 'unresolved'
        with self.assertRaisesRegex(LedgerError, 'profile'):
            validate(self.ledger)

    def test_duplicate_ids_rejected(self):
        self.ledger['rules'].append(copy.deepcopy(self.ledger['rules'][0]))
        with self.assertRaisesRegex(LedgerError, 'duplicate rule'):
            validate(self.ledger)


if __name__ == '__main__':
    unittest.main()
