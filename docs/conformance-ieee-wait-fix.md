# Constant-condition digital wait repair

Source: IEEE 1364-2005 §9.7.6, printed136 / physical166, complete text and
Syntax9-11 visually reviewed on 2026-09-23 as recorded in
`conformance-ieee-scheduling-review.md`. A wait evaluates its condition first;
true continues, false blocks until true. Neither syntax nor semantics requires
the expression to contain a variable dependency.

Root cause: preflight collected condition dependencies and rejected an empty
list before the runtime level test could execute. This incorrectly rejected
both immediately true constants and valid permanently false constants.

The minimal fix removes that rejection. Existing execution already evaluates
truth before suspending: a true result advances to the body; otherwise it
registers its dependency waiters and returns from process dispatch. With an
empty list it registers none and returns, so it cannot busy-loop and never
spontaneously resumes. Other processes remain runnable. Dependent expressions
continue to re-evaluate after their operands change.

Only `src/sim/digital.zig` is changed. Base is current root including the
integrated wide-clog2 repair, SHA256
`7a5f050eae66d96bed7e6f67b16b14ecc1a7e464dbe4155e55655f5fcf743b98`.
Scheduling handoff fixtures/report and shared runners remain unchanged.

Focused verification command from the isolated worktree:

```
zig test --dep frontend --dep diag -Mroot=src/sim/digital.zig \
  --dep diag -Mfrontend=lib/frontend/root.zig -Mdiag=lib/diag.zig \
  --test-filter 'wait '
```

Exit0: three tests pass through the actual digital source executor.

- Literal1, arithmetic/comparison constant true, and a null wait body all
  continue at simulation time0.
- Literal0 and constant comparison false never execute their bodies or following
  statements; an independent process reaches time2 and finishes normally.
- A dependent comparison stays blocked through count1, resumes when count2 at
  time2, and an independent process subsequently completes.

These observations distinguish immediate continuation, permanent suspension
without spinning, and dependency-driven reconsideration. They do not establish
all four-state expression behavior, process-disable interactions or implicit
event-list semantics. In particular the separate empty `@*` rejection is not
changed by this repair. No full suite/build or conformance measurement was run;
main integration owns rebuilt CLI transcripts and complete FAIL-name comparison.

Main checkpoint (2026-09-23): independently read §§9.7.5–9.7.6, reviewed
preflight and the truth-first dispatch path, and integrated the minimal repair.
All three focused tests pass in the root tree. Rebuilt CLI transcripts match
all four scheduling positives exactly, including `ready` followed by `end`
for constant wait; the matching legal-expression control prints `ready`.
The opt-in empty-expression negative passes in the full digital runner.
Full digital FAIL-name membership is unchanged from the PLA/queue/control
batch; no new scheduling failure enters it. `zig build test` exits0.
The completed analog strict-suite FAIL/XFAIL names are unchanged from the
math-fixes baseline; existing debt keeps that suite at exit1.
