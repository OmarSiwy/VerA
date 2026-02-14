# IEEE Clause20 PLI overview: source and host-evidence audit

Read complete IEEE1364-2005 Clause20 (§§20.1–20.8), printed366–368 /
physical396–398, and visually inspected all three pages on2026-09-23. There
are no syntax figures/tables in this chapter. Read direct dependencies
26.1–26.1.4 (printed374–375) and27.34–27.34.2 (printed461–464) as text;
these are bounded dependencies, not a full Clause26/27/AnnexG source review.
The licensed source remains local and is not reproduced in this report.

Reviewed current AMS11/12 source reports, `tests/vpi_host.zig`, VPI build
wiring, the production header/API boundary, and existing P02/P03 systf probes.
The existing linked startup/hierarchy evidence is real but does not establish
system-task registration or simulation callbacks. No compiler/header changes
or full builds were performed in this pass.

## Obligations and actual evidence boundaries

| ID | Source | Requirement and disposition |
|---|---|---|
| PLI20-001 | 20.1 p366 | VPI accesses/modifies instantiated structural and behavioral objects dynamically. Existing C-host hierarchy traversal observes only the implemented elaborated declaration subset. Illustrative GUI/hardware applications are examples, not mandated products. |
| PLI20-002 | 20.1 p366 | TF/ACC interfaces were deprecated and their bodies removed from2005. Do not invent current obligations from empty21–25 headings or treat VPI as optional because older interfaces are deprecated. AMS11's stale clause22 references require explicit reconciliation, already logged. |
| PLI20-003 | 20.2 p367 | Names start with dollar; remainder letters/digits/underscore/dollar; case-sensitive; all characters significant. Actual registration/dispatch tests need case pairs, embedded dollars, long shared prefixes and invalid names with valid controls. Parser token acceptance alone is not dispatch evidence. |
| PLI20-004 | 20.3 p367 | User tasks occupy task contexts, can read/write arguments and return no value. User functions occupy function contexts, can read/write arguments and return a value with vector width from sizetf. Existing P02 digital systf draft is a lead, not executed host evidence. User system functions must not inherit HDL-function input-only assumptions blindly. |
| PLI20-005 | 20.4 p367 | User PLI registration overrides matching built-in names. New required-positive built-in override plugin/deck specifies this behavior but cannot compile against production header yet. User registration priority must precede hardwired builtin lowering. |
| PLI20-006 | 20.4 p367 | Timing checks such as setup are not system tasks and cannot be overridden. Needs actual registered-name plus timing-check behavior/disposition test; merely rejecting unsupported timing syntax cannot establish this boundary. |
| PLI20-007 | 20.4 p367 | Signed/unsigned may be overridden; override return width is fixed by sizetf across every call, not by each argument. New unsigned override probe uses1-bit and64-bit inputs with a40-bit registered return. Signed counterpart remains open. |
| PLI20-008 | 20.5–20.6 pp367–368 | Applications are linked C functions called by the product during compilation/execution, not standalone main programs. Current C host really links and calls startup, but compiles at lint before startup and never executes a systf call. Callback phase/call frequency requires actual simulation integration. |
| PLI20-009 | 20.7 p368 | HDL tfargs are not callback C parameters; obtain/read/write them through PLI routines. New probe uses argument iterator and verifies distinct source widths; it does not substitute passing HDL arguments directly to C. Argument mutation remains separate coverage. |
| PLI20-010 | 20.8 p368 | Applications include normative vpi_user.h declarations/constants/structures. Production header is deliberately incomplete; header existence and overlapping constant checks cannot establish full AnnexG ABI. New probe fails on missing required declaration families; no shim hides the gap. |

## Direct dependency findings

IEEE26.1 requires registration before elaboration/reference resolution. The
current `tests/vpi_host.zig` first compiles at lint, opens the object model,
then runs the startup table. That is adequate for its declaration-walking
application but cannot serve unchanged as a conformant system-function host.
The ordering must be redesigned when registration is implemented; calling
startup after an unknown function was already rejected cannot repair that
compilation. Subsequent26.2.4 review additionally found that traversal is not
allowed inside startup at all: only registration APIs are available until
later phases. Existing tests therefore provide implementation-specific late
startup ABI/traversal regression evidence, not legal startup-phase conformance.
See `conformance-ieee-vpi-interface-review.md` for the phase restriction and
the phase-correct required-positive probe.

26.1.1 specifies at-most-once sizetf for a function present in the design;
26.1.2 requires compiletf once per source instance when provided;26.1.3
requires calltf for every execution;26.1.4 passes user_data as the callback's
single argument.27.34 permits NULL callbacks and confines sizetf to sized
function types, with default32 when no sizing callback is supplied. Tests must
not require all optional callbacks on every registration. The new probe
provides callbacks explicitly, so their prescribed invocation is observable.

27.34.2 provides a NULL-terminated startup array and vendor-defined linking
procedure. This does not impose a particular dynamic-library flag or mandate
one loader format. Its example prose calls the array a C function; preserve
the source anomaly without converting it into an invalid C declaration.
Full ABI layout/constant census and remaining lifecycle/object rules remain
owned by the uncompleted Clause26/27/AnnexG audit.

## New required-positive artifact

`tests/fixtures/ieee_pli/audit_builtin_override.c` registers `$unsigned` with
fixed40-bit width and returns hexadecimal8000000001. Its paired `.v` uses
arguments1'b1 and64'h0: built-in behavior would instead return1 and0. C also
checks call-handle width, argument widths, user_data and callback counts.
The end-of-simulation callback demands exactly both runtime calls and emits
a mandatory stderr marker. This avoids matching return values while silently
skipping a call or the final checker. The `.expected.txt` and
`.expected.stderr.txt` files are both required by the documented future host
runner. No existing runner is falsely declared to execute these files.

Initial production-header probe:

```sh
cc -std=c99 -Wall -Wextra -Werror -Wno-unused-command-line-argument \
  -fsyntax-only -I <root>/src/vpi \
  tests/fixtures/ieee_pli/audit_builtin_override.c
```

Exit1 reports missing vpiSysTfCall/vpiArgument/value-format constants,
vpi_put_value, s_vpi_systf_data, vpiSysFunc/vpiSizedFunc and registration
declarations. After adding the mandatory final callback, the same probe also
reports the missing callback declaration family. This is a missing header/API
surface, **not** a successful invalid-input test. No linker/runtime result is
claimed and no unsupported compilation is counted as correct behavior.

The new host probe uses APIs already covered by the prior AMS12 source audit
for argument iteration, function return writes and end-of-simulation callback;
it does not claim Clause20 itself supplies every routine-level ABI detail.
It remains an open executable specification until a production host can run
it. Rejected unknown HDL functions, manually invoked C callbacks, mocked APIs
or a syntax-only plugin compile cannot close PLI20-005/007/008/009.

No A/C measurement is supplied. Parent integration gates and future actual
host execution remain required. Clause20 source review is complete; its
behavioral obligations, and full inherited VPI conformance, are not.

## Root handoff boundary

Main read this complete report on 2026-09-23 and retained it at root.
The source traversals and visual inspections above are attributed to the
worker, not claimed as a new independent main-agent full-source pass.
Named host probes remain pending root integration and cannot be credited
as executed conformance evidence. Later object-model installments complete
the source traversal formerly listed as pending, not the behavioral rules.
Public-header type/guard repairs are recorded separately in the AnnexG report;
runtime registration, callbacks and value APIs remain missing.
