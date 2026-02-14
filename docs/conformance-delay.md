# Absolute-delay rule/evidence audit

Source: VAMS-2023 §4.5.7, physical pages 84–85, read with the HTML on
2026-09-23. Table 4-20 and A.8.2 provide argument classifications and grammar;
§4.5.15 and host lifecycle clauses add cross-cutting obligations. Both full AMS
and the Annex C analog profile include this operator. This is a rule worklist,
not a complete Chapter 4 denominator or a conformance score.

Paths below are under `tests/fixtures/ch04_expressions/` unless stated otherwise.
Existing candidates were read, but their historical SPEC results are not
substituted for current execution. `audit_*` cases below were run together on
2026-09-23 with the current `vera-suite` runner and installed `vera`: exit 0,
all four cases passed. The controlled interpolation mutations below provide
additional discrimination evidence; other rules remain unmutated.

| ID | Obligation | Evidence / remaining work |
|---|---|---|
| DLY-001 | Required input and td; optional maxdelay; no extra arguments | `19_absdelay.va` exercises legal forms. New `audit_absdelay_missing_td_rejected.va` independently checks missing td (E0505). Fixture 159 also contains invalid `ddt()`, so its failure alone cannot establish this rule. Missing input, empty positions, extra arguments still need isolated audit. |
| DLY-002 | td must be positive, including the optional-maxdelay form | Existing 127 combines two violations. New `audit_absdelay_three_arg_negative_rejected.va` isolates the three-argument case. New `audit_absdelay_zero_delay_rejected.va` tests zero in the two-argument form. Zero in the three-argument form and dynamic transitions across the bound remain separate cases. |
| DLY-003 | Without maxdelay, use td at first evaluation and ignore subsequent changes | `a04_03_absdelay_td_frozen_without_maxdelay.va` is a source-level behavioral candidate with independent ramp oracle. Audit first evaluation during OP versus transient initialization and restart; do not infer coverage from constant-delay fixture 19. |
| DLY-004 | With maxdelay, td may vary | `a04_04_absdelay_maxdelay_substitution.va` changes td in both directions. Confirm the compiler/host executes all transitions rather than merely accepting the source. |
| DLY-005 | Substitute maxdelay if td exceeds it | Same a04_04 candidate separates substitution from honoring the excessive delay. Figure 4-4 itself does not test this: its maxdelay is 5 and its largest td is 4. Equality and adjacent boundary cases remain. |
| DLY-006 | DC returns input | Fixture 19's transient starting point is not sufficient evidence that every required DC entry route selects the operator's DC semantics. Need explicit nonzero DC and swept-input observations. |
| DLY-007 | Operating-point analysis returns input | Need an explicit OP host observation, distinct from ordinary transient history initialization. |
| DLY-008 | AC output multiplies input by exp(-jωtd) | Need complex gain/phase observations at several frequencies, including nonzero phase and a unit-magnitude check; source compilation or a transient delayed ramp does not observe this. |
| DLY-009 | Other small-signal analyses have the same phase-shift behavior | Enumerate supported host analysis entry points and their applicable inherited obligations; do not silently equate “other” with AC only. |
| DLY-010 | Small-signal td is constant at the analysis's particular time | Need operating-point/time changes between analysis invocations and observations that distinguish a stale globally frozen value from per-analysis evaluation. |
| DLY-011 | Transient output is Input(max(t-td,0)) | 19 observes an ordinary ramp with exact historical query times. New `audit_absdelay_linear_interpolation.va` observes a nonuniform, nonmonotonic sampled input. No runtime oracle calls absdelay on its expected side. |
| DLY-012 | Before the delay elapses, return Input(0), not zero | `a04_06_absdelay_initial_output_is_input_at_zero.va` uses a nonzero initial input. The new interpolation case also starts at 3. The formula takes precedence over an interpretation of the Figure 4-4 explanatory sentence that would contradict the plotted nonzero initial input. |
| DLY-013 | Linearly interpolate input history when necessary | New interpolation fixture independently derives 7 at queries 4ns and 8ns using unequal source intervals and opposite slopes, then 9 at a query between two already accepted samples. It discriminates previous-sample hold, nearest-sample selection and fixed-index stepping. Need controlled implementation mutations and additional precision/boundary cases. |
| DLY-014 | Retain enough correct history to implement the requested delay | `a04_05_absdelay_history_beyond_capacity.va` targets ring exhaustion; inspect actual resource policy and test it without treating silent shortening as allowed. Generalizing a fixed-capacity stress case remains necessary. |
| DLY-015 | maxdelay has constant-per-analysis semantics; input and td are dynamic arguments | Table 4-20 classifies maxdelay as constant, but the paragraph following its continuation explicitly says a supplied dynamic expression is sampled at the analysis start and subsequent changes ignored. Do **not** infer blanket rejection from the table's column name. A.8.2 uses a constant-expression grammar slot, whose interaction with this semantic permission needs source reconciliation. Add a dynamic-maxdelay freeze oracle and record any refusal as an unresolved conformance question, not automatically a conforming rejection. |
| DLY-016 | Operator state obeys accepted/rejected point lifecycle and analysis restarts | Cross-reference §4.5.15 and simulation clauses. A fixed time-grid fixture alone cannot verify rollback, rejected Newton evaluations or host-chosen points. Audit host tests, their production call paths and actual execution separately. |

## Source fidelity

The equations' variable placement and the transport-delay figure were checked
against rendered source pages. Figure 4-4 has now been restored as a direct PDF
crop alongside its labeled editorial description. Source fidelity observations are
recorded in `conformance-source-review.md`. Do not turn its illustrative ramp
into an arbitrary implementation restriction.

## Changes to earlier claims

The new isolated negative tests strengthen evidence without changing any old
expectation or modifying compiler behavior. An error from an earlier statement
in fixture 127 or 159 cannot be credited to every later invalid statement.
The numerical interpolation test observes behavior that the integer-grid ramp
tests cannot distinguish. These additions move fixture evidence (A), not inherited
source closure (B) or architecture (D); C remains only a static citation count.

## Controlled mutation evidence, 2026-09-23

Emitted the interpolation fixture with `vera --emit-exe --contract
tools/contract.zig -I tests/fixtures -I tests/fixtures/ch04_expressions`, then
copied its generated `.device.zig` and `.tb.zig` into an isolated temporary
directory. No compiler source or canonical generated artifact was mutated.
The unchanged testbench was compiled against the altered device with
`zig build-exe -OReleaseSafe`, binding its `device` and `contract` modules.

In `zHistAt`, replacing
`vs[older] + (vs[newer] - vs[older]) * f` with
`vs[older] + (vs[newer] - vs[older]) * (f * 0.0)` introduces a previous-sample
hold while preserving compilation. The unchanged fixture then reports `ok=0`
at 3ns (error -2) and 11ns (error -6). The unmutated control reports `ok=1` at
every declared point. Both executables exit 0: these testbenches communicate
assertion results through `ok=` columns, which the suite must inspect; process
success alone is not the oracle.

A second independent mutant replaces `vin.scale(f).addC(vs[newest] * (1.0 - f))`
in `zAbsdelay` with the same expression using `f * 0.0` in both places. This
holds the newest accepted sample instead of interpolating toward the current
trial input. It compiles and reports `ok=0` at 6ns (error +2) and 10ns (error -4),
while the 11ns accepted-history observation still passes. Together the mutants
show that the fixture distinguishes both interpolation paths, not just one.
