# Chapter12 VPI routine evidence ledger

Reviewed 2026-09-23 against AMS2023 printed pages309–354; see
`docs/conformance-ch12-review-draft.md` for source review and source anomalies.
This supersedes the earlier section-ID census: a clause tag is not execution.

## Existing evidence and withdrawn claims

The numbered HDL files remain language regression tests. The `*_not_va.va`
files reject unknown ordinary function names under §4.7. Files01,02,48 check
source-example acceptance, a local parameter, or surrounding block sequencing;
they do not observe a registered C callback. Their `//! lrm 12.*` tags were
withdrawn, with executable HDL and other directives unchanged. Their filenames
and leading source citations retain the structural link to Chapter12; the
behavioral obligations move to the rows below. No capability was excluded.

The startup-linked `tests/vpi_app.c`/`tests/vpi_host.zig` test exercises C ABI
and a bounded hierarchy surface. The host compiles in lint mode and calls the
startup table; it does not run a simulator. The separate required-positive
XFAIL probes distinguish missing instance location, valid vector-bit handles,
and valid empty net-to-port iteration from invalid API requests. XPASS exits
nonzero. Passing these bounded probes would not close their entire clauses.

`zig build test-vpi-fixtures` compiles P02/P03 C sources, but does not link
them to a solving host or compare their expected transcripts. Their compilation
and source decks are not callback, value, scheduling, derivative, or analysis
execution evidence. This supersedes older claims that no build step compiles
them, and older claims that the whole startup clause was closed by a table walk.
No linked P03 execution was performed during this review.

## Open rule groups (each requires atomic expansion and recorded execution)

| Group | Clauses | Required behavioral and boundary evidence |
|---|---|---|
| VPI12-ARGS |12.1|Each routine's mandatory arguments, declared types, optional/NULL exceptions; ABI test against resolved header.|
| VPI12-ERR |12.2|Every severity, error fields/state, NULL information pointer, repeated non-clearing reads, reset by other calls. Existing C test covers only a subset.|
| VPI12-HANDLES |12.3–12.4,12.19–12.23,12.35|Identity across aliases/instances, object versus iterator release, all graph relationships, valid/empty iteration, iterator reference via vpiUse, exhaustion, in-range bit/memory indices, hierarchical scope search, many-to-one equal-width ports.|
| VPI12-PROP |12.5,12.12,12.18|All integer/boolean/string/real properties; object-specific legality, location/definition distinction, NULL timescale and analysis-global properties, string-copy lifetime, undefined/error cases.|
| VPI12-INFO |12.6,12.13–12.14,12.17|Callback/task registration round-trip into caller storage; invocation argv/argc/product/version and success/failure. Resolve differing callback layouts explicitly.|
| VPI12-ANALOG |12.7–12.10|DC/timezero/transient attempted versus accepted time and delta, AC frequency, real+imaginary quantities, every value format, format reset, memory ownership and next-call lifetime.|
| VPI12-DELAY |12.11,12.29|Primitive/path/timing-check/intermodule counts; mtm/pulse Cartesian combinations, order and buffer size; replace/append, pulse-limit preservation, user allocation and time_type overriding element type.|
| VPI12-TIME |12.15|Object timescale and NULL simulation scale, scaled real/simulation/analog time formats, high/low rollover, caller allocation.|
| VPI12-VALUE |12.16|Every format, integer X/Z conversion, real rounding, mixed octal/hex X/Z case, strength, vector32-bit boundaries, string/time/vector ownership and callback lifetime, UDP entry representation (source ambiguity recorded).|
| VPI12-DERIV |12.22.1–12.22.2,12.32.2|Declared derivative handles only, returned value index0/argument indices1+, derivative_of/wrt distinction, declarative derivtf versus numeric calltf contribution, actual Jacobian propagation.|
| VPI12-MCD |12.24–12.28|Open/reopen/error, filenames and buffer lifetime, bitmask channels, simultaneous write/close, protected channels, failed-close mask, character counts/EOF, stdout plus log. Resolve source descriptor/channel terminology.|
| VPI12-PUT |12.30|All delay modes and cancellation sets, force/release resultant value, scheduled-event handle/flag predicates, cancellation after occurrence, canceled-event side effects, free-handle without cancel, sequentialUDP no-delay, active-only function result, object timescale.|
| VPI12-EVENTCB |12.31–12.31.1|Event reasons and before/after ordering, expression/terminal/statement handles, NULL global force/release, suppressed time/value, changed index/value, separate callback data and preserved user_data.|
| VPI12-TIMECB |12.31.2|Every queue-relative reason, absolute/delay interpretation, empty timequeues, read-only write/schedule prohibition, scaling object, ignored next-time structure, callback current-time and user_data.|
| VPI12-ANACB |12.31.3|First/last/accepted solutions, absolute/elapsed forced solver points, convergence rejection and rollback, not fixed-grid analog events.|
| VPI12-ACTIONCB |12.31.4|All required action callbacks including runtime/PLI/timing-check errors; feature callbacks conditional on implemented feature, with reason-specific object/user_data. Optional features do not exempt required actions.|
| VPI12-SYSTF |12.32–12.33.1|Analog/digital registration domains, same-name cross-domain and duplicate same-domain rules, type/result types, compiletf/sizetf/derivtf/calltf phases, each invocation, NULL callbacks, user_data, sized-function default32, independent corrected resistor/sampler oracles.|
| VPI12-STARTREMOVE |12.33.2–12.34|Linked startup table null termination, startup timing, vendor linking procedure, dynamic registration/removal from callbacks, remove result and invalidated handle. Existing startup walk is bounded evidence only.|
| VPI12-CONTROL |12.36|Deferred stop/finish/reset and argument propagation, immediate interactive scope, transient rejection timestep, continued convergence iterations, return/failure; source says three but lists six operations.|

Missing simulator/host integration is an open implementation and verification
obligation, not a reason to remove a row. Rule groups are not an exhaustive
atomic count or a conformance percentage.
