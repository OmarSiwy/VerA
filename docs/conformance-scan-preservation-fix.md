# SCAN-EXCESS-001 implementation checkpoint

Source: AMS2023 §9.5.4.2, printed232–233; IEEE1364-2005 §17.2.4.3,
printed291–293. Excess destinations after format exhaustion are ignored;
only successful nonsuppressed conversions assign destinations. The earlier
source audit and normative oracle are preserved in conformance-ch9-review.md.

Root cause inspected: lowerScan writes every synthetic scan result without
checking whether its assigned-item index was reached. The scanner's default
zero/empty payload is not an assignment. lowerFileRead repeats this mistake
for fscanf. No kernel-only change can recover the prior destination because
that value is absent from its inputs.

Proposed fix: evaluate scan count from original source/format once, then for
each destination choose its scan value only when count > assigned index;
otherwise retain the incoming SSA variable. Read that incoming variable at
each assignment so repeated destination aliases retain the last successful
write, not the value preceding the entire scan. File scanning uses its
already sequenced count; do not perform another read/window/advance, and do
not change fgets/ferror behavior.

## Pre-fix observations

Targeted root executable, emitted fixture executables, process exit0 in all
cases; failing CHECK lines are failures regardless of that exit status.

| Fixture | Checks passing / failing | Scope |
|---|---|---|
| audit_sscanf_literal_and_excess_arguments.va | 3 / 1 | One unused destination overwritten. Existing XFAIL retained until implementation verified. |
| audit_scan_destination_preservation.va | 9 / 6 | All three destination types; initial literal mismatch; suppression; partial conversion; repeated output alias; input/output and format/output string aliases. |
| audit_fscanf_destination_preservation.va | 5 / 3 | Partial/excess and EOF preservation; offset6, retry conflicting word, and count semantics already correct. |

## Implementation and focused verification

Compiler base: current root lib/ir/lower.zig SHA256
b91439183f119fb3355ba4401524a255ec940f353014fb19098e2537aed5734e,
including the separately reviewed system-math typing patch. Only lowerScan,
the fscanf branch of lowerFileRead, and one focused test were changed.
The test verifies one count call per string/file scan and one integer
count>index guard for each of the six int/real/string destination writes.

Focused command (exit0, two tests including root import test):

```sh
zig test --dep diag --dep frontend --dep kernels -Mroot=lib/ir/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig -Mkernels=lib/backend/kernels.zig --test-filter 'scan destinations'
```

Global gates remain integration work. Main corrected codegen/str_kernels
commentary about unassigned scanner payloads: kernels still return default
payloads, but lowering must not assign them. No kernel or emitter behavior was
changed by the scanner repair. `zig fmt --check` reports the
file both on the root baseline and after this patch; broad unrelated formatting
was intentionally not included. `git diff --check` passes.

Main checkpoint (2026-09-23): independently read complete AMS9.5.4.2 and
IEEE17.2.4.3, reviewed both guarded-write loops and the aliasing oracles.
The rebuilt root CLI passes all fifteen string-preservation, eight file-
preservation and four original excess-argument checks. The full unit gate
exits0, and strict-suite FAIL/XFAIL membership is unchanged from the math-fixes
baseline. These runtime results do not close all formatted-input rules.

Own CLI-only `zig build -Doptimize=ReleaseFast` completed with exit0. New
runtime results: original excess-argument fixture4/4 ok=1; destination
preservation15/15 ok=1; file preservation8/8 ok=1, all executable exits0.
The original XFAIL is removed only alongside this implemented fix, with its
normative values unchanged. Existing162_sscanf_conversion_rules has7/7
ok=1; s01_09_fscanf_directive_spans_lines has7/7 ok=1. The focused existing
backend scanner test also passes (two tests including root import test).
Existing file-scan regressions additionally pass: s01_08 successive scans13/13,
s01_10 failed match6/6, and s01_11 real destination4/4, each emit/run exit0.

Final lower.zig SHA256:
7365fcafcb0e8ba9f5935fb720f137069fda2314510fc0ea69cbb205007291a9.
Only bounded scanner evidence is closed; no global FAIL/XFAIL name-list or
conformance measure is claimed before root integration gates.
