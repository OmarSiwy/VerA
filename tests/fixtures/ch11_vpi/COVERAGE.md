# Chapter 11 evidence boundary

Reviewed against the complete AMS-2023 Chapter 11 (printed 274–308), including
all object graphs, on 2026-09-23. See
[the source/evidence audit](../../../docs/conformance-ch11-review-draft.md).

## What the HDL fixtures establish

The numbered `.va` fixtures in this folder assert language semantics, not VPI.
They do not invoke a C API, retrieve a handle, inspect an object property,
traverse a relationship, register a callback, or inspect the time queue.
Their former `//! lrm 11.*` tags have therefore been withdrawn. Their language
citations, inputs, assertions and expected diagnostics are retained unchanged.

In particular, `08_callback_call_site.va` checks `initial_step`, not
§11.6.25 callback registration or dispatch. The C-name rejection fixtures
`09` and `10` establish undeclared-function rejection under §4.7, not the
existence, validity, or behavior of any VPI routine. Arithmetic on a branch
cannot establish its `vpiFlow`, `vpiPotential`, or `vpiDirection` properties.

Withdrawn Chapter 11 claims remain open obligations in the audit's rule-group
table. They are not outside the full-AMS target and are not closed by moving
a citation to Chapter 12.

## Actual C evidence infrastructure

- `tests/vpi_app.c`, `tests/vpi_host.zig`, and `tests/vpi_design.va` exist.
  `zig build test-vpi` compiles/links a C application against the real header
  and exported routines; the host lint-elaborates the design, opens its object
  model and invokes `vlog_startup_routines`. Build assertions require success
  and the expected census transcript. This is real API execution for the
  declaration subset, not HDL acceptance alone.
- That host does not run a simulation. It cannot establish value-change,
  time-region, analog-solver, end-of-simulation, force/release, or time-queue
  behavior. Registration/startup invocation does not substitute for those.
- `zig build test-vpi-fixtures` is wired in current `build.zig`. It compiles
  the P02/P03 C rows only: it does not link them to a host or execute them.
  Historical statements that no build step exists are obsolete.
- `p02_SPEC.md` is a proposed host/API scenario inventory, not a record that
  its assertions ran. Missing headers or an absent simulation adapter leave
  the obligations open; syntax-checking against a stub is not ABI evidence.

No execution result is claimed by this source-review update. Main-session
gates and dated evidence records must provide any later run results.

## C host limitations requiring separate classification

The existing C application deliberately asserts some current implementation
limitations as successful rejections: for example a module's `vpiLineNo`
and an in-range vector bit lookup. These are not invalid input cases in a
fully conformant object model. They must not count as negative conformance
coverage or prevent a correct implementation from improving. Split such
implementation-regression checks from normative API cases, then express the
missing positive behavior as expected failures with XPASS enforcement.

All source-diagram properties, forward/reverse traversal cardinalities,
inherited class properties, bit-level objects, and source NOTES need individual
host assertions. The rule groups in the audit are a decomposition backlog,
not a completed atomic-rule manifest.
