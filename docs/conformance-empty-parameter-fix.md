# Empty named parameter associations: bounded implementation fix

## Source and root cause

AMS6.3.3 / IEEE1364-2005 12.2.2.2 explicitly permit `.name()` without a
value and require retention of its default. AMS6.3.4 retains dependency
recomputation;9.19 reports whether a value was overridden, not whether its
name occurred. AMS9.18's unspecified multiplicity is1, propagating the
parent's product. AMS6.4.2 selects paramsets using defaults and actual
overrides; empty associations cannot reduce the un-overridden count.
These clauses were reread against the local source on2026-09-23.

Current-root `lib/ir/elaborate.zig` was copied before editing. Base SHA256:
`a27f936276901d055d2124ffdac3aa51b871f04d29e8dacdd32efdaf8ac7a4ec`.
Final SHA256:
`3c6c7cd738a0043024870a2ae59a8a268a7225d4a404b9a541d84d498d556857`.
No other compiler file was edited. Architecture/import guidance in the file
and IR facade was read; no dependency/module-graph changes were necessary.

Previously `collectOverrides` cloned a missing expression as `.none`, stored
it as a real override and marked the parameter given. Downstream execution
then observed zero instead of the default. The same value could enter a
multiplicity product. Paramset admission also replaced defaults with missing
expressions, while override counting treated a documented name as a value.

The bounded repair skips missing named values **after** ordinary name,
alias-target and localparam validation. Empty `$mfactor` keeps the inherited
product. Paramset admission retains the default and tie counting excludes
missing expressions. The existing shared paramset-override path already uses
`collectOverrides`, so a separate replacement algorithm was not introduced.
Defparam processing remains afterward and still overrides a retained default.
Two actual value assignments still diagnose the prior E0908; its misleading
alias wording for duplicate ordinary names remains an independent issue.

## Focused evidence

Direct unit command:

```sh
zig test --dep diag --dep frontend --dep kernels -Mroot=lib/ir/root.zig \
  -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig \
  -Mkernels=lib/backend/kernels.zig --test-filter 'empty named associations'
```

All five new elaboration tests pass (plus the root import test). They inspect
default retention through direct/alias names, the actual rewritten
`$param_given` expression, unknown/localparam errors, defparam precedence/given
state, multiplicity propagation, and paramset admission/counting. Focused
existing defparam and paramset selection test filters also pass. `zig fmt
--check lib/ir/elaborate.zig` passes. No full suite was run.

A CLI-only `zig build-exe` used the owned worktree's existing module graph,
with output `zig-out/bin/vera-empty-association`, SHA256
`c743795bf41a14e9cfce40c4879b01ec990543afcfcc2f8b469c1716efbb818c`.
This is an isolated-tree check, not proof against all currently integrated
root compiler changes. Parent integration must independently rerun it.

| Runtime/check fixture, under ch06_hierarchy | Observed result with proposed fix |
|---|---|
| audit_hierarchy_empty_named_parameter | Both default3 and explicit offset7 checks pass; prior root baseline reported default0. Normative fixture retained; XFAIL removed together with implementation and replaced by checks2. |
| audit_hierarchy_empty_named_semantics | Six checks pass: dependent default5, given0 for empty target, given1 for explicit a and explicit-equal-default offset, inherited mfactor4, offset7. |
| audit_hierarchy_empty_paramset_tie | Both candidates leave one parameter un-overridden; second wins ranged-localparam tie breaker and emits20, as independently derived in header. Check passes. |
| audit_hierarchy_defparam_source_order | Existing last-same-file result7 still passes. |
| audit_hierarchy_empty_unknown_rejected | Exit1 E0907 unknown parameter. |
| audit_hierarchy_empty_localparam_rejected | Exit1 E0907 localparam. |
| audit_hierarchy_duplicate_parameter_rejected | Existing two-value duplicate remains exit1 E0908. |

Runtime commands used the owned CLI `--run --contract <root>/tools/contract.zig`
with root fixture and owned ch06 include paths; negatives used `--check` with
the same flags. Every individual observation was read. W0650 strict-float
warnings were not treated as failures. Removing XFAIL records implemented
support for this case, not deletion of the normative test.

Open boundaries include paramset alias/range interactions beyond omitted
values, all inherited parameter width/type conversions, source-order matrices,
and the broader hierarchy ledger. No claim of full conformance or measured
A/C improvement is made before parent gates/name-list comparison.

## Root review corrections and integration

Root integrated the bounded compiler patch and hierarchy fixtures and passed
the focused elaboration tests. On rereading3.4.5/6.3.3, main challenged the new
empty-localparam negative; the worker agreed that no prohibition was established.
An empty association is expressly not an assignment, while the localparam rule
forbids direct modification. That new fixture is moved out of conformance intake
to `tools/parameter-audit-controls/empty_localparam_unresolved.va`, without LRM
or rejection tags. Its unit assertion is labeled implementation compatibility,
not a normative obligation. The existing localparam check is preserved by this
bounded repair; the interpretation remains open, not certified by E0907.

Root's first analog `--run` attempts exited zero but emitted no check observations;
they are not runtime evidence. Independent `--emit-exe` execution is required
before promoting the worker's runtime claims or updating measured conformance.

The subsequent `--emit-exe` runs and explicit executable launches each exit zero.
Their checks are printed on **stderr**, not stdout; main inspected that stream
and confirmed all observations: original empty-default pair, six semantic checks,
paramset tie20, defparam7, dependency4/11/44, and zero-loop current2. The first
verification shell looked only at stdout and correctly failed its assertion-
presence guard; no empty transcript was counted as a pass. Worker confirmed its
recorded CLI invocation really emitted observations, with different surrounding
CLI provenance. Root's explicit-executable checks are independent evidence.
