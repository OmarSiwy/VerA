# Machine-readable rule ledger, schema v1

This is initial infrastructure for the per-rule evidence requirements in
`CONFORMANCE.md`, not a certified requirement denominator. New files only;
the existing citation/fixture measures and historical audit reports are not
rewritten. Do not derive a conformance percentage from this ledger.

## Schema

JSON documents have `schema_version: 1`, `denominator: "uncertified"`,
`completeness_review` (`pending` or `independent-review-recorded`), optional
review-record path, a scope explanation, and a nonempty `rules` array.
`tools/rule_ledger.py` implements the validation contract using only the
Python standard library. No fixture-header scanning or simulator execution
occurs during validation.

Each rule contains:

- Stable `id`; `source` document, edition, PDF SHA256, clause, printed and
  physical page, and exact paragraph/sentence/list/grammar-arm locator.
  The locator identifies the passage without redistributing licensed text.
- `html_trace` with path, anchor, relation and limits. Relations distinguish
  direct text from an inherited reference, missing coverage or unresolved
  mapping. Missing/unresolved mappings cannot close a rule. An inherited
  reference does not claim the external standard is reproduced in the HTML.
- `profiles` entries for full Verilog-AMS and Verilog-A, each with explicit
  applicability (`applies`, `outside`, `unresolved`), source and reason.
- Paraphrased `obligation`, `preconditions`, `cross_references`, and class:
  mandatory, prohibition, optional, implementation-defined, unspecified,
  informative or ambiguous. Resource limits require their actual source
  authority; unsupported implementation is not an exclusion.
- `invalid_input` disposition and reason. Legal behavior need not acquire
  an invented rejection. Prohibitions require a legal neighbor for closure.
- `cases`: stable local ID, kind (behavior, diagnostic, acceptance), boundary,
  analysis, state transition, expected observable, independent derivation,
  plausible wrong implementation and mutation status. Proposed mutants are
  not executed mutation evidence.
- Each case's explicit `evidence` list: fixture, assertion/transcript,
  runner, revision, actual result, evidence level, provenance and limits.
  Empty lists mean unexecuted; they are not implicit failures or passes.
- `status` (open, partial, verified, disposition), residual uncertainty and,
  for verified rows, independent review reference.

Verified rows require a passing production-execution record for EVERY
identified case, with artifact path and SHA256 plus fixture/runner hashes.
Citation, compilation, acceptance-only and isolated kernel execution cannot
close a rule. Diagnostic cases and legal behavioral neighbors are both
required when invalid-input evidence applies. Missing source/oracle fields
are rejected even for open rows. Informative/ambiguous/outside-only rows
cannot inflate verified behavior. V1 refuses a certified denominator even
if all entered rows were verified.

A passing result cannot conceal a failing, blocked or unexecuted production
record in the same case: verified status rejects that conflicting evidence.
V1 does not infer supersession by list order or guess which revision is current.
Keep the rule partial until the evidence conflict is explicitly reviewed; retain
historical failures in the audit reports rather than deleting their provenance.
Artifact paths must be nonempty, not merely present as whitespace.

These checks establish structural consistency only. A fabricated hash or
incorrect oracle can still satisfy a schema; independent review must inspect
the actual artifacts, source, executable configuration, revision manifest,
and causal discriminator. With `--check-html-root .`, the validator checks
resolved HTML paths remain inside that root, exist, and contain the referenced
anchor as an actual HTML id attribute. This checks links, not source fidelity.
Optional `--check-evidence-root ROOT` authenticates declared bundles: fixture,
explicit `runner_path` (not a parsed command string), and output `artifact`
must be relative files within ROOT and match their declared SHA256 values.
Partial bundle metadata fails instead of silently skipping a missing member.
Unbundled open/partial citation records are skipped and never counted as
authenticated; the command reports the number actually checked. This does not
establish that output came from that runner/fixture, interpret assertions, or
authenticate includes, runtime libraries, configuration or source correctness.
Durable artifact packaging, dependency-driven
invalidation, source-rule completeness review, optional-feature choice and
resource-bound review remain future infrastructure. Do not interpret a
successful validator run as actual execution or conformance certification.

Evidence-file validation tests use synthetic files only. They detect changed
bytes, missing files, missing runner paths and root escapes. All26 validator
tests pass at this checkpoint; retained candidates have no authenticated full
bundle merely by passing the structural tests.

## Initial clause candidate

Retained candidates (none has a certified denominator):

| Ledger | Bounded source scope | Review/evidence limits |
|---|---|---|
| `rules/ieee-readmem.json` | IEEE17.2.9 and named dependencies | Independent review and several runtime repairs; remaining input/address/width cases open. |
| `rules/ams-minmax.json` | AMS4.3/4.3.1 min/max and named contexts | Bounded values/derivatives; external-host and nonfinite questions open. |
| `rules/ams-lexical-core.json` | AMS2.2–2.4,2.8–2.8.2 | Independent review corrections and bounded runtime cases; completeness pending. |
| `rules/ams-strings.json` | AMS2.7 and explicit3.3/3.4.6 edges | Independent review pending; multiline source conflict marked ambiguous. |
| `rules/ams-attributes.json` | AMS2.9–2.9.2 and named dependencies | All candidate rows open; metadata/report consumers not established by arithmetic-only fixtures. |
| `rules/ams-parameter-core.json` | AMS3.4 introduction through3.4.2 | All rows open; mixed boundary sketches and range/type/override dependencies need independent decomposition. |

Use `--check-html-root .` with each ledger to check resolved links. Validation
does not approve source interpretation, settle conflicting clauses, execute
cases, or turn the number of candidate rows into measured conformance.

`rules/ieee-readmem.json` decomposes the complete text of IEEE17.2.9,
printed296–297 / physical326–327, freshly reread on2026-09-23. It separates
the two syntax arms, execution timing, each whitespace/comment form, radix
and four-state characters, file address format/restarts, default and explicit
directions, range errors, and warning preconditions. The locator fields pin
each rule to a particular passage rather than just the clause heading.
Independent atomicity and completeness review is PENDING: dependencies such
as numeric padding/truncation, dynamic expressions and invalid bound values
are explicitly not certified by this clause decomposition.

The seed's initial Verilog-A applicability was unresolved. Independent source
review now establishes the boundary: AMS9.2 Table9-2 lists readmemb/readmemh
as digital-only; AnnexC.11 includes analog-applicable tasks and C.7 excludes
digital behavior. These execution rules are therefore outside Verilog-A,
while remaining full-AMS obligations. This decision comes from the source,
not from digital fixture selection; it does not invent a required diagnostic
for analog extension use. See `conformance-readmem-ledger-review.md`.
Unresolved profiles still prevent verified status. Malformed input rows retain pending review of exact
diagnostic authority/severity; expected implementation diagnostic codes are
not invented from the existing compiler.

Diagnostic-authority follow-up: independent review of IEEE1.2(a), then main
source inspection, establishes required errors for17.2.9 mandatory file-content,
prefix and radix violations. The corresponding candidate rows now cite that
dependency; exact wording, process exit and whole-simulation termination are
not standard-mandated. Binary invalid-digit behavior is a separate diagnostic
case, not mixed into its positive radix case. See
`conformance-readmem-diagnostic-refinement.md` and the subsequent token-validation
repair report. This resolves that authority question, not full input coverage.

Historical root reports and real fixture paths are linked for bounded
low-address, start-only/formfeed, relocation, range-error and word-count
cases. The two readmem implementation reports record actual root integration
runs, partial source hashes and temporary log paths. No run was repeated by
this ledger task. Those records lack a durable complete fixture/runner/log
hash bundle and cover only some boundaries, so imported rows are PARTIAL,
never VERIFIED. Uncovered grammar/malformed/timing/value cases remain OPEN.
Later reports supersede earlier start-only/formfeed limitations explicitly;
the old historical checkpoints are not silently rewritten.

## Validation and tests

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/rule_ledger.py docs/rules/ieee-readmem.json
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools -p test_rule_ledger.py
```

Tests include missing source/oracle, duplicate IDs, uncertified denominator,
missing artifacts, failed/unexecuted cases, compile/kernel-only false closure,
acceptance mislabeled as behavior, unresolved profiles, and a diagnostic
without legal-neighbor evidence. Synthetic positive records test schema
shape only and are clearly not actual evidence. These new test names need
explicit invocation; they do not match the existing `test_lrm_*.py` discovery
pattern. No compiler/header edits, full builds or A/C measurements are part
of this handoff.

Root integration: structural validation passes, and the expanded validator
suite passes all17 tests. Added checks reject conflicting production records
and whitespace-only artifact paths. No seed row is verified. The surrounding
unit gate also passes (`/tmp/vera-ledger-pli-unit.log`); this does not execute
or certify the seed's source obligations.
