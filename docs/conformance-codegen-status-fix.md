# Code-generation refusal must not report success

Root investigation, 2026-09-23. The legal AMS §4.5.14 capture fixture
`audit_absdelay_dynamic_maxdelay_sampled.va` exposed a reporting defect
independent of its unsupported analog behavior. Before this repair, `--check`
printed E0515 twice and a compilation-failed summary but exited zero.
Logs: `/tmp/vera-dynamic-maxdelay.out` and `.err`.

The control-expression renderer set the current unit's fatal message while
emitting metadata. A later unit reset that field, losing the failure before
the aggregate flag was set. The torture harness also checked diagnostic
failure only before code generation and searched generated text for
`@compileError`; a metadata error need not emit that text.

The repair makes control-expression and generic abort failures sticky across
units, includes error diagnostics in the aggregate codegen failure flag, and
checks post-generation diagnostics and that flag in the torture harness.
The public flag retains its existing name but now documents metadata failures;
the CLI no longer incorrectly claims every refusal contains `@compileError`.
Generated output with a fatal flag is not usable. Warnings alone are not errors.

A regression generates the unsupported maxdelay program both with and without
a diagnostic bag and requires a fatal result in both cases. This test does
not call the legal source invalid or establish §4.5.14 support. Its behavioral
fixture remains XFAIL, requiring first-use capture, not refusal.

After a successful root install, the same `--check --contract tools/contract.zig`
command exits one; `/tmp/vera-status-after.err` retains the source diagnostic.
The first full-unit attempt terminated with status143 and is not a passed gate.
A bounded-parallelism rerun (`zig build test -j2`) exits zero, including the
new metadata regression; `/tmp/vera-status-vector-unit.log` records the result.
The first strict name comparison preserves all previous FAIL/XFAIL names and
adds only the new dynamic-maxdelay XFAIL and the new strength-negative routing
failure. The latter is corrected by selecting the digital runner, without
changing its expected rejection. Final strict run exits one and its name list,
compared with the scan/minmax/wait checkpoint, adds only the new dynamic-maxdelay
XFAIL. No previous FAIL or XFAIL name changed membership. Logs and sorted lists
use `/tmp/vera-status-vector-final-strict`. `tools/conformance.sh` completed
with exit zero using those strict and coverage logs; its unit gate passes and
digital gate remains failing. `conformance-measurement.md` is its output.
This repair protects measure A's reporting integrity; it does not itself close
an AMS clause, inherited obligation in measure B, or architecture phase D.
