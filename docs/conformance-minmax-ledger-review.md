# Min/max machine-readable rule candidate

`rules/ams-minmax.json` uses the current root v1 ledger validator, including
its conflicting-production-evidence and nonempty-artifact guards. No shared
validator, compiler, fixture or existing review file was edited.

Every row has an explicit `html_trace`. Numeric/type/derivative rules map to
`docs/ch4-expressions.html#s4-3-1`; context rules map to
`docs/ch9-system.html#s9.2`, which contains Table9-11 (the table is under9.2,
not the9.1 overview). These anchors exist in current root HTML and the
relevant text/table cells were inspected. They are section anchors, not
per-rule anchors. The nonfinite/signed-zero row maps to the same source
section with relation `unresolved`: source placement is known, but the
claimed universal behavior is not established. No mapping grants runtime
credit or resolves that ambiguity.

## Source boundary and correction

Reread complete AMS4.3 and4.3.1 on2026-09-23, with original PDF pages74–75
(printed61–62) visually inspected at1400 pixels. Checked Table4-14 columns,
the paragraph continuing across the page, and the strict conditional
identities. Source SHA256:
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
The task initially named4.5.15; that section is analog-operator restrictions,
not min/max. The candidate uses4.3/4.3.1 instead. It does not promote these
stateless math functions to restricted stateful analog operators.

Supplementary complete9.14 text and4.5.6 derivative-definition paragraphs
were reread. Table9-11's continued page, physical236/printed223, was both
read and visually checked: `$min` and `$max` explicitly support BOTH digital
and analog contexts. The inherited IEEE math list alone is not sufficient
to decide these AMS-added names' context. AnnexC.5 applies Clause4 to the
analog profile with only the stated case-equality exception; C.11 includes
analog-context system tasks/functions, and C.7 excludes digital behavior.
Thus analog cases apply to both profiles; the separately defined DIGITAL
execution obligations are outside Verilog-A by source, not by fixture choice.

Scoped search of the min/max derivative/system-math reports and the four
audit min/max/type fixtures found no erroneous4.5.15 locator. Existing
82_min/83_max correctly cite4.3.1. Their integer CHECKI assertions cannot
establish result type, and equal numeric values cannot establish the selected
partial derivative. The new ledger preserves those evidence limitations.

## Decomposition and independent oracles

For each function, the candidate separates x<y, x>y and equal numeric
values; integer results; each mixed operand position; two-real results;
tie first/second partials; swapped arguments; constant operands; unequal
partials; digital/analog context; numeric operand restriction; and arity.
Case-level variants retain both spellings. These are a decomposition
candidate, not an independently certified atomic denominator: some grouped
variants may need further splitting and full grammar dependencies remain.

The integer-result discriminator uses a result of3 divided by integer2,
observed before assignment can convert it. Integer typing gives1, while
incorrect real typing gives1.5. Mixed inputs require1.5 even if the selected
source operand happened to be integer. This distinguishes selection value
from result type.

At equal independent probes the source's strict comparison is false, so the
second operand supplies the derivative: first partial0, second partial1.
Swapping operands or placing a constant second changes the dependency,
exposing implementations that return the right numeric minimum/maximum but
carry the wrong derivative. Unequal neighbors guard against an overbroad
always-second derivative repair.

External-host/Jacobian transition cases remain explicitly unexecuted: sweep
below/equal/above, swap, and revisit after restart, observing the production
contribution's partials. A prescribed-bias ddx check cannot substitute for
that solver integration. The production generated-helper tests in the old
report are useful bounded implementation tests, not full external-host proof.

Numeric-operand and arity negatives have independent legal-neighbor
requirements but no invented production diagnostic code. A string literal
may undergo integral conversion and is not automatically a nonnumeric
negative. Aggregate source legality and full AnnexA grammar must be checked
before turning those candidate cases into new fixtures. Historical E0506
lowering unit tests are not reclassified as production runtime diagnostics.

## Evidence provenance and residuals

Read current root `conformance-system-math-fix.md`,
`conformance-minmax-derivative-fix.md`, the superseding checkpoint in
`conformance-ch4-functions-review.md`, and the actual fixtures. Imported
evidence refers to the reported root integration runs after the repairs,
not the earlier failed observations. The earlier failures stay in historical
reports, not mixed into the current checkpoint as unexplained contradictory
production evidence. None of those runs was repeated by this ledger task.

Recorded fixture/runtime passes are PARTIAL only. They lack a complete
durable runner/fixture/transcript hash bundle and do not cover every case.
Numeric legacy fixture inspection is only citation/not-run evidence here.
Digital system-function execution, two-real quotient cases, exact malformed
operand controls and external-host transitions remain OPEN. No row is marked
verified merely because an existing fixture passed.

The source supplies conditional identities specifically to resolve derivative
discontinuities, and separately lists equivalent C fmin/fmax names. It does
not justify treating every host NaN/signed-zero behavior as a universal AMS
oracle. A separate AMBIGUOUS row retains unordered/nonfinite and bit-level
signed-zero authority/implementation-path questions. Helper tests of those
values remain implementation regressions pending source reconciliation.
Other residuals include integer-width/signedness boundaries, constant
folding, arbitrary expression nesting, alias arity, numeric-conversion
precision and a full cross-context/analysis matrix. None is silently excluded.

Validation command, executed with the current ROOT validator against the
isolated new ledger:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 \
  /home/omare/Documents/Projects/Zig/VerA/tools/rule_ledger.py \
  docs/rules/ams-minmax.json
```

Exit0, structural validity only. No full builds, compiler edits, simulation
reruns or A/C measurements. Independent completeness review remains pending.

Root integration: main read this full review and inspected every rule's
obligation, source clause, HTML anchor, expected result and status. Candidate
and report are retained; root validation passes. Imported observations remain
historical partial evidence, with no new simulation or verified status claimed.
