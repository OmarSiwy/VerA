# IEEE VPI interface review — bounded26.2–26.5 installment

Read complete IEEE1364-2005 §§26.2–26.5.3, including examples, all category
tables and diagram keys: printed375–386 / physical405–416. Visual review:
physical406–407 (phase rules),408–409 (Figures26-1/2),411–413 (Tables26-1
through26-9),414–415 (all diagram keys). Other pages were text-reviewed.
Review date2026-09-23. Prior `conformance-ieee-pli-overview-review.md` covers
26.1–26.1.4 as bounded direct dependencies. **26.6's full object models remain
pending**; AMS11 diagrams do not substitute for IEEE-specific digital objects.

Current production header is `src/vpi/vpi_user.h`; no `include/vpi_user.h`
was found in the root inventory. Inspected that header, `src/vpi/root.zig`,
`tests/vpi_host.zig`, `tests/vpi_app.c`, VPI build wiring and AMS11/12 reports.
No compiler/header changes, full builds or linked-host reruns were performed.

## Phase defect in existing evidence

26.2.4 permits only vpi_register_systf/vpi_register_cb inside startup routines.
The latter is restricted there to cbEndOfCompile, cbStartOfSimulation,
cbEndOfSimulation, cbUnresolvedSystf, cbError and cbPLIError. The early sizetf
phase provides no additional access. Full functionality starts when
cbEndOfCompile callbacks are called, continuing through tool execution.

Current `tests/vpi_app.c` places its entire declaration walker directly in
`vlog_startup_routines`. `tests/vpi_host.zig` runs that array after lint
compilation and model construction. This demonstrates the actual C/Zig linkage
and implemented traversal properties in an implementation-specific late-startup
environment. It does **not** demonstrate legal IEEE startup-phase use. The
earlier Clause20 report now explicitly qualifies its evidence statement.
Existing regression bodies are not deleted or silently moved: a real lifecycle
host must call registration early and schedule traversal at cbEndOfCompile.

The standard restricts early availability but these paragraphs alone do not
specify one universal diagnostic for every forbidden early API. A test must
not invent a particular early-call error or mistake success of an illegal
startup traversal for a required positive.

## Source/evidence groups

| ID | Source | Requirement and remaining boundary |
|---|---|---|
| VPI26-001 | 26.2.1 pp375–376 | Dynamic registered callbacks for simulation events, time, simulator actions and user systf execution. Registration, delivery, reason data and lifecycle need actual host evidence; startup-array invocation is only a separate mechanism. |
| VPI26-002 | 26.2.2 p376 | Access applies to unique instantiated objects, including simulation objects. Current declaration-instance traversal is partial; runtime values/events and omitted digital object classes remain open. |
| VPI26-003 | 26.2.3 p376 | vpi_chk_error reports previous routine failure nonzero and detailed errors/error callbacks are available. Existing checks validate a subset of immediate error state, not callback delivery, all levels or every routine transition. |
| VPI26-004 | 26.2.4 pp376–377 | Startup/sizetf/end-of-compile availability boundary described above. New phase-correct probe registers early and queries only at end compile; currently blocked before linking by missing callback declarations. |
| VPI26-005 | 26.2.5 p377 | Traverse arbitrary HDL expressions through operation/operand graph; outer operation has least precedence. Need source-versus-optimized graph, null operation, operand order and each operation kind; expression evaluation alone supplies none of this API evidence. |
| VPI26-006 | 26.3–26.3.1 pp377–379 | Object/class membership inherits properties/relationships; tags disambiguate multiple edges to same class; one-to-one handle versus one-to-many iterator/scan. Part-select generic vpiExpr traversal is illegal where left/right tags are required. New objects/paired legal-tag controls remain open. |
| VPI26-007 | 26.3.1 p379 | Integer/boolean properties use PLI_INT32, booleans exactly0/1; strings use PLI_BYTE8 pointer. Existing cross-language linked tests check some properties, not all header declarations or ABI layouts. |
| VPI26-008 | 26.3.2 pp379–380 | All objects have numeric vpiType AND string type-constant name; additional type properties likewise have numeric/string forms. Root vpi_get_str switch only handles name/fullname/defname, omitting vpiType. New callback probe requires vpiModule string, but runtime remains blocked by host lifecycle. |
| VPI26-009 | 26.3.3 p380 | Source-backed objects carry file/line properties affected by line directives; explicit exceptions are callback, delay term/device, intermodule path, iterator, time queue, generate scope array and generate scope. Do not require locations on these exceptions. Existing instance-line XFAIL covers one required object only. |
| VPI26-010 | 26.3.4 p380 | Delay/value structures need specialized API. Declared delay expressions versus actual simulator delays are different views; multiple declared delays use vpiListOp. Read/write, lifetime and event effects require Clause27 routine audit and simulation host evidence, not header carriers alone. |
| VPI26-011 | 26.3.5 p381 | Protected-state property applies to all objects; protected access generally errors except type/protected-state queries and specified exceptions. Missing-name discrepancy with AnnexG below requires resolution before numeric ABI oracle. Unprotected and protected controls, real envelope behavior remain open. |
| VPI26-012 | 26.4 pp381–383 | Callback, systf, hierarchy, property/index, delay, value, time and utility families are required surface inventory. Tables are not function prototypes or exhaustive runtime specifications; individual Clause27 rules govern signatures/behavior. |
| VPI26-013 | 26.5 pp383–386 | Solid/dotted borders, bold/italic definitions/references, unnamed groups, single/double arrowheads, tags and NULL-origin circles carry access semantics. Complete graphical review of26.6 remains required; keyword matches cannot certify relationships/cardinalities. |

## Source anomalies, not silently normalized

26.2.5's example switches on `vpi_get(vpiExpr,expr)`, while26.3.2 defines
vpiType as the property returning object type. Treat the example as suspect,
not authority to require vpiExpr as an integer property.26.5.2's sample uses
lowercase `vpivector` although its property box names vpiVector.26.4's table
uses vpi_sim_control; subsequent routine-level control naming needs explicit
edition reconciliation rather than guessed declarations.

26.3.5 names `vpiIsProtected`; searching the supplied AnnexG header text finds
`vpiProtected` with a source-protected-module comment instead, and no
vpiIsProtected definition. These cannot simply be equated for every object
without source/errata resolution. This report does not fabricate a numeric
constant or add a compiler/header alias. The behavioral protection obligation
stays open rather than being dropped because the listing is inconsistent.

## New phase-correct required-positive host probe

`tests/fixtures/ieee_pli/audit_end_compile_objects.c` registers only an
end-of-compile callback at startup. That callback performs top lookup and
checks numeric vpiType equals vpiModule, string vpiType equals `vpiModule`,
and no error after each valid operation. Its paired HDL merely finishes with
argument0. The mandatory stderr marker proves the callback ran; exit0 without
it is not success. No mocked callback invocation is an acceptable substitute.

Production-header probe using C99 Wall/Wextra/Werror and syntax-only exits1:
p_cb_data, s_cb_data, cbEndOfCompile and vpi_register_cb are absent. The exact
command is the Clause20 probe command with this C filename. Thus no ABI
execution, callback phase or string-type result has yet been observed. These
remain required positive expectations, not accepted invalid-input fixtures.

The earlier built-in override HDL now uses `$finish(0)` so its expected
application transcript does not depend on simulator finish-statistics output.
Both probes remain explicitly outside any claimed executed conformance
denominator until production host integration is available. No A/C measure or
complete Clause26 conformance claim is made.

## Root handoff boundary

Main read this complete report on 2026-09-23 and retained it at root.
The source traversals and visual inspections above are attributed to the
worker, not claimed as a new independent main-agent full-source pass.
Named host probes remain pending root integration and cannot be credited
as executed conformance evidence. Later object-model installments complete
the source traversal formerly listed as pending, not the behavioral rules.
Public-header type/guard repairs are recorded separately in the AnnexG report;
runtime registration, callbacks and value APIs remain missing.
