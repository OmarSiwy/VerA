#!/usr/bin/env python3
"""Validate explicit rule evidence; never infer coverage or run a simulator.

Schema v1 is specified in docs/conformance-rule-ledger.md. This validator
checks consistency, not source truth, artifact contents, or completeness.
"""
import argparse
import hashlib
import json
from html.parser import HTMLParser
from pathlib import Path


class LedgerError(ValueError):
    pass


def validate_evidence_files(ledger, root):
    """Authenticate declared bundle bytes, not their meaning or execution."""
    root = Path(root).resolve()
    checked = 0
    for rule in ledger['rules']:
        for case in rule['cases']:
            for item in case['evidence']:
                bundle_keys = ('artifact', 'artifact_sha256', 'fixture_sha256',
                               'runner_sha256', 'runner_path')
                if not any(key in item for key in bundle_keys):
                    require(rule['status'] != 'verified',
                            f"{rule['id']}: verified evidence lacks file bundle")
                    continue
                for path_key, hash_key in (
                        ('fixture', 'fixture_sha256'),
                        ('runner_path', 'runner_sha256'),
                        ('artifact', 'artifact_sha256')):
                    nonempty(item, [path_key, hash_key], rule['id'])
                    spelling = Path(item[path_key])
                    require(not spelling.is_absolute(),
                            f"{rule['id']}: bundle path must be relative")
                    path = (root / spelling).resolve()
                    require(path.is_relative_to(root),
                            f"{rule['id']}: bundle path outside root")
                    require(path.is_file(), f"{rule['id']}: missing bundle file {path_key}")
                    with path.open('rb') as stream:
                        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                    require(digest == item[hash_key],
                            f"{rule['id']}: {hash_key} mismatch")
                checked += 1
    return checked


def validate_html_links(ledger, root):
    """Check resolved link targets only, not whether their prose proves a rule."""
    class Anchors(HTMLParser):
        def __init__(self):
            super().__init__()
            self.ids = set()

        def handle_starttag(self, tag, attrs):
            self.ids.update(value for key, value in attrs if key == 'id')

    root = Path(root).resolve()
    cache = {}
    for rule in ledger['rules']:
        trace = rule['html_trace']
        if trace['relation'] in ('missing', 'unresolved'):
            continue
        path = (root / trace['path']).resolve()
        require(path.is_relative_to(root), f"{rule['id']}: HTML path outside root")
        require(path.is_file(), f"{rule['id']}: missing HTML file")
        if path not in cache:
            parser = Anchors()
            parser.feed(path.read_text())
            cache[path] = parser.ids
        require(trace['anchor'] in cache[path], f"{rule['id']}: missing HTML anchor")
    return True


def require(condition, message):
    if not condition:
        raise LedgerError(message)


def nonempty(obj, fields, where):
    for field in fields:
        require(isinstance(obj.get(field), str) and obj[field].strip(),
                f"{where}: missing {field}")


def validate(ledger):
    require(ledger.get('schema_version') == 1, 'unsupported schema_version')
    nonempty(ledger, ['scope'], 'ledger')
    require(ledger.get('denominator') == 'uncertified',
            'v1 cannot certify a denominator')
    require(ledger.get('completeness_review') in ('pending', 'independent-review-recorded'),
            'missing completeness_review')
    if ledger['completeness_review'] != 'pending':
        nonempty(ledger, ['completeness_review_record'], 'ledger')
    require(isinstance(ledger.get('rules'), list) and ledger['rules'], 'empty rules')
    seen = set()
    for rule in ledger['rules']:
        nonempty(rule, ['id', 'obligation', 'class', 'status'], 'rule')
        rid = rule['id']
        require(rid not in seen, f'duplicate rule {rid}')
        seen.add(rid)
        require(rule['class'] in ('mandatory', 'prohibition', 'optional',
                'implementation-defined', 'unspecified', 'informative', 'ambiguous'),
                f'{rid}: invalid class')
        require(rule['status'] in ('open', 'partial', 'verified', 'disposition'),
                f'{rid}: invalid status')
        source = rule.get('source', {})
        nonempty(source, ['document', 'edition', 'sha256', 'clause', 'passage'], rid)
        require(len(source['sha256']) == 64 and all(c in '0123456789abcdef'
                for c in source['sha256']), f'{rid}: invalid source hash')
        for key in ('printed_page', 'pdf_page'):
            require(type(source.get(key)) is int and source[key] > 0,
                    f'{rid}: missing {key}')
        html = rule.get('html_trace', {})
        nonempty(html, ['path', 'anchor', 'relation', 'limits'], rid)
        require(html['relation'] in ('direct-text', 'inherited-reference',
                                    'missing', 'unresolved'),
                f'{rid}: invalid HTML relation')
        profiles = rule.get('profiles', {})
        require(set(profiles) == {'verilog-ams', 'verilog-a'}, f'{rid}: profiles required')
        for profile in profiles.values():
            require(profile.get('applicability') in ('applies', 'outside', 'unresolved'),
                    f'{rid}: invalid applicability')
            nonempty(profile, ['reason', 'source'], rid)
        nonempty(rule, ['preconditions', 'cross_references', 'residuals'], rid)
        negative = rule.get('invalid_input', {})
        require(negative.get('disposition') in ('required', 'not-applicable', 'unresolved'),
                f'{rid}: invalid-input disposition required')
        nonempty(negative, ['reason'], rid)
        cases = rule.get('cases')
        require(isinstance(cases, list) and cases, f'{rid}: missing cases/oracles')
        case_ids = set()
        for case in cases:
            nonempty(case, ['id', 'kind', 'boundary', 'analysis', 'state_transition',
                           'expected', 'derivation', 'wrong_implementation',
                           'mutation_status'], rid)
            require(case['id'] not in case_ids, f'{rid}: duplicate case')
            case_ids.add(case['id'])
            require(case['kind'] in ('behavior', 'diagnostic', 'acceptance'),
                    f'{rid}: bad case kind')
            evidence = case.get('evidence')
            require(isinstance(evidence, list), f'{rid}: evidence list required')
            for item in evidence:
                nonempty(item, ['fixture', 'assertion', 'runner', 'revision',
                               'result', 'level', 'provenance', 'limits'], rid)
                require(item['level'] in ('citation', 'compile', 'unit-execution',
                        'production-execution'), f'{rid}: bad evidence level')
                require(item['result'] in ('pass', 'fail', 'blocked', 'not-run'),
                        f'{rid}: bad result')
            if rule['status'] == 'verified':
                # A verified rule needs actual production behavior for EVERY
                # identified case, never mere citations/acceptance/kernel tests.
                require(case['kind'] != 'acceptance', f'{rid}: acceptance is not closure')
                passing = [e for e in evidence if e['result'] == 'pass'
                           and e['level'] == 'production-execution'
                           and e.get('artifact_sha256') and e.get('artifact')
                           and e.get('fixture_sha256') and e.get('runner_sha256')]
                require(passing, f'{rid}: missing production runtime evidence')
                require(all(e['result'] == 'pass' for e in evidence
                            if e['level'] == 'production-execution'),
                        f'{rid}: conflicting or unresolved production evidence')
                for item in passing:
                    nonempty(item, ['artifact'], rid)
                    for key in ('artifact_sha256', 'fixture_sha256', 'runner_sha256'):
                        value = item[key]
                        require(len(value) == 64 and all(c in '0123456789abcdef'
                                for c in value), f'{rid}: bad {key}')
        if rule['status'] == 'verified':
            require(html['relation'] not in ('missing', 'unresolved'),
                    f'{rid}: unresolved HTML trace')
            require(rule['class'] not in ('informative', 'ambiguous'),
                    f'{rid}: cannot verify informative/ambiguous row')
            require(all(p['applicability'] != 'unresolved' for p in profiles.values()),
                    f'{rid}: unresolved profile')
            require(any(p['applicability'] == 'applies' for p in profiles.values()),
                    f'{rid}: no applicable profile')
            require(negative['disposition'] != 'unresolved', f'{rid}: unresolved negative')
            nonempty(rule, ['independent_review'], rid)
            if negative['disposition'] == 'required':
                require(any(c['kind'] == 'diagnostic' for c in cases),
                        f'{rid}: missing diagnostic case')
                require(any(c['kind'] == 'behavior' for c in cases),
                        f'{rid}: missing legal neighbor')
        if rule['status'] == 'disposition':
            require(rule['class'] == 'informative' or
                    all(p['applicability'] == 'outside' for p in profiles.values()),
                    f'{rid}: mandatory applicable row cannot be disposition-only')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ledger', type=Path)
    parser.add_argument('--check-html-root', type=Path,
                        help='also check resolved HTML file/anchor targets under this root')
    parser.add_argument('--check-evidence-root', type=Path,
                        help='verify declared fixture/runner/artifact bundles under this root')
    args = parser.parse_args()
    try:
        ledger = json.loads(args.ledger.read_text())
        validate(ledger)
        if args.check_html_root is not None:
            validate_html_links(ledger, args.check_html_root)
        if args.check_evidence_root is not None:
            checked = validate_evidence_files(ledger, args.check_evidence_root)
            print(f'Authenticated {checked} declared evidence bundles; contents not interpreted.')
    except (LedgerError, ValueError, TypeError, KeyError, AttributeError, OSError) as exc:
        parser.exit(1, f'invalid ledger: {exc}\n')
    print('Ledger structure valid; source completeness and conformance NOT certified.')


if __name__ == '__main__':
    main()
