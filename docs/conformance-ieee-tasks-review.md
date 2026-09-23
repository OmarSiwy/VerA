# Inherited task/function audit: bounded evidence groups

## Digital diagnostic runner correction

Main integration checkpoint (2026-09-23): the runner, time/plusargs fixtures and
review are integrated. `zig build test` exited0. Main explicitly ran each of
the three argument negatives, the time/stime wrap positive and the unsigned
clog2 positive through the built suite; each selected exactly one case and
exited0. The full digital gate exits1. Its nonempty sorted FAIL-name diff adds
only the newly integrated legal positives: `audit_realtime_stored_operand`,
`audit_test_plusargs_absent`, `audit_value_plusargs_absent`,
`audit_scope_lexical_shadow`, `audit_ieee_math_clog2_wide`,
`audit_ieee_math_constant_expression`, and `audit_ieee_math_real_result`.
Existing failure membership is unchanged. These additions expose missing
behavior; they are not unsupported XFAIL markers or negative coverage.

The subsequent full strict run exited1 with a nonempty FAIL/XFAIL name list
byte-identical to the completed AnnexA checkpoint. The new digital route did
not alter legacy analog verdicts or double-count the opted-in files. The
prescribed measurement script owns the refreshed A/C snapshot.
`git diff --check` passes. `zig fmt --check tests/bench.zig` still flags
pre-existing table/argv layout; comparison with HEAD's formatter diff confirms
the same unrelated regions. They were not reformatted into this runner patch.

Integration review found that a `.v` rejection with no transcript was previously
collected by the analog torture runner (`compileSourceOpts` / device generation),
not by `vera --run`. The direct digital diagnostics recorded below were valid
bounded observations but **not ordinary-suite digital negative coverage**.
The CLI's `--check` analog route cannot substitute for this digital phase.

The three new time-query argument negatives now explicitly carry
`// digital-runner: reject`. This is runner metadata, not an analog `//!`
directive. `test-devices` collects these cases, runs the real `vera --run`, and
requires normal exit 1, a rendered diagnostic and every nonempty `//! reject`
substring in diagnostic header lines beginning `error[`. Echoed source and
comments cannot supply a matching phrase. Other diagnostic layouts fail closed
in this bounded runner. Missing/wrong diagnostics, success, abnormal termination, bare reject,
or an additional positive transcript fail. XFAIL metadata is unsupported in
this bounded path and cannot silently pass. Existing transcript cases retain
their byte-exact oracle. Existing unmarked `.v` negatives retain their legacy
analog path; their expectations were not changed or reclassified as digital
evidence. The opted-in cases are excluded from analog collection, avoiding
double scoring. They are consequently digital-runner evidence, not newly
verified measure-A torture rows or automatically expanded measure-C citations.

Focused tests use real temporary files to verify collection exclusions and
unchanged analog/legacy/transcript membership. Independent matcher tests cover
all-pattern matching, wrong diagnostic, exit 0/255, missing/bare reject and
unsupported XFAIL. This change does not claim full digital harness feature
parity or validation of every inherited task input.

Recorded validation: focused `zig test` with filter `digital ` passed all four
selected tests (two import anchors and two substantive runner tests), exit 0.
A separately compiled suite executable in the agent worktree ran each opted-in
time/stime/realtime rejection against the actual root compiler; each filtered
`devices` invocation exited 0. Direct compiler invocations each exited 1 with
E1100 and respectively `$time and $stime take no arguments` (two cases) or
`$realtime takes no arguments`. The neighboring positive
`audit_time_stime_wrap` transcript also passed through that same suite executable,
exit 0. No fake compiler was used. This is targeted runner verification, not a
full suite gate or a historical FAIL-name-list comparison.

Review date2026-09-23. IEEE1364-2005 licensed source SHA256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Full §§17–18 remain in scope and incomplete. This register starts with a
coherent source-verified group, not a claim to have read or closed both chapters.
The main IEEE provenance, scheduling, monitor and display ledgers remain
authoritative for their separately reviewed portions. No licensed PDF or
substantial source transcription is included here.

## Group1: §17.7 simulation-time queries

Read complete extracted text, syntax and examples for §17.7 introduction and
§§17.7.1–17.7.3, printed309–310/physical339–340. Syntax17-14–16 each consists
of the named zero-argument function; rendered typography was not separately
certified in this group. AMS§9.10 inherits these digital queries. Analog-only
refusals do not close their digital behavior, and `$abstime` is a separate AMS
extension rather than another IEEE17.7 entry.

| ID | Source | Atomic obligation | Evidence / remaining limit |
|---|---|---|---|
| TIME-IEEE-001 | 17.7.1 | `$time` retains a64-bit time value | New `audit_time_stime_wrap.v` observes bit32 and distinct values above2^32; passes directly. Does not exhaust all64bits or overflow. |
| TIME-IEEE-002 | 17.7.1 | Scale to the invoking module's time unit | Existing `d09_05_time_queries.v` uses10ns/1ns; its transcript is a lead. Mixed-module local timescale evidence remains open. |
| TIME-IEEE-003 | 17.7.1 | Round scaled time to integer rather than precision ticks | Existing `d09_06_time_rounding.v` distinguishes fractional local units. Wider rounding matrix and hierarchy not newly verified here. |
| TIME-IEEE-004 | 17.7.2 | `$stime` is unsigned32-bit | New boundary fixture prints positive2^31 and compares greater than0; passes. Its unsigned comparison and decimal text discriminate a signed result. |
| TIME-IEEE-005 | 17.7.2 | Return low32bits when simulation time exceeds that width | New fixture observes2^32-1,2^32,2^32+3; passes with4294967295,0,3. Higher wrap periods remain open. |
| TIME-IEEE-006 | 17.7.2 | `$stime` uses invoking module's units | Existing scaled fixture is a lead; the new wrap test uses equal unit/precision and does not independently test scaling. |
| TIME-IEEE-007 | 17.7.3 | `$realtime` returns real-valued local-unit time | Existing display-only cases observe fractional values; new `audit_realtime_stored_operand.v` checks stored value and arithmetic, but fails before execution at unsupported real declaration. |
| TIME-IEEE-008 | 17.7.1–3 syntax | Each function takes no arguments | Three isolated argument-rejection fixtures directly report the specific no-argument diagnostic; legal bare calls in the positive fixtures remain the neighbors. |

Paths in this table are relative to `tests/fixtures/digital`. These are atomic
claims within the reviewed sentences, not an exhaustive argument-context,
width, module/hierarchy or full inherited-expression cross-product.

### Corrected historical claim

`d09_05_time_queries.v` used to say assigning `$time=7` into a64-bit register
proves the return width, even while admitting32-bit zero-extension yields the
same string. That assertion cannot distinguish those implementations. Its
header now limits the observation to storage/formatting and moves the width
claim to TIME-IEEE-001's actual high-bit observation. No executable expectation
or output changes in the old fixture.

Historical `CLAUSE-AUDIT.md` row17.7-01's width rationale should receive the same
correction. Row17.7-02's statement that no fixture exceeds2^32 is superseded by
the new boundary case, but do not change its whole-row status to verified:
module-local scaling and other conditions remain independent. No manual measure
B total is updated by this report.

### Independent derivations and direct results

`audit_time_stime_wrap.v` uses1ns unit/precision and only four scheduled delays.
It does not iterate through all intervening ticks. At2^31, `$stime` is unsigned
2147483648; immediately below2^32 it is4294967295; at2^32 it is0; three units
later it is3. `$time` retains4294967296 and4294967299, with right-shift32 giving1.
The exact expected transcript was written from these binary boundaries before
execution. Direct `vera --run` exits0 and matches every expected line.

`audit_realtime_stored_operand.v` uses10ns/100ps. After0.25local units, save the
real0.25; multiplying by4 gives1. After another0.5units, current time times4 is3,
while the saved value remains0.25. These binary-exact values distinguish local
units, stored values and ordinary arithmetic from display-only special casing.
Direct execution exits1 with E1100 at `real saved`, before any transcript.
This is a legal positive failing case, not negative conformance coverage.
No expectation was changed to match the rejection, and no compiler change was
made. Even once declarations work, storage/arithmetic still require execution.

`audit_time_argument_rejected.v` and `audit_stime_argument_rejected.v` each
exit1 with E1100 and the specific diagnostic substring `take no arguments`.
`audit_realtime_argument_rejected.v` exits1 with E1100 and
`$realtime takes no arguments`; its `%g` format ensures the real-aware display
path reaches that argument check. An initial `%0d` diagnostic experiment instead
failed on unsupported expression handling; that incidental diagnostic was not
accepted as proof of the argument rule. The final fixture isolates the intended
no-argument diagnostic and pins its distinctive text, not generic E1100 alone.

All commands use the current root `zig-out/bin/vera --run` with this agent's
worktree as cwd. No full Zig build, main-tree write or compiler edit was made.
Main must integrate and run its digital name-list regression gate and generated
measurements. Digital positive failures are not hidden behind analog XFAILs.

## Group 2: §17.10 digital command-line queries

Read the complete §17.10 introduction, §§17.10.1–17.10.2 and all examples,
printed pages 320–323 / physical pages 350–353. This is text review; there is
no numbered syntax box or table in this group requiring a new visual claim.
AMS §9.12 supplies the context relationship. The parallel Chapter 9 owner
independently read this source and owns analog plusargs fixtures and runtime
argument plumbing; this group does not edit that harness or duplicate them.

| ID | Source | Atomic obligation | Digital evidence / remaining limit |
|---|---|---|---|
| PLUS-IEEE-001 | 17.10 introduction | Simulator invocation exposes plus-prefixed arguments to queries | Present-argument digital CLI forwarding remains unverified; new analog harness plumbing is a separate handoff. |
| PLUS-IEEE-002 | 17.10.1 | Literal or nonreal packed-variable string query, without leading plus | New literal absent-query fixture fails at the function call. Packed-variable input and invalid real/leading-plus cases remain separate. |
| PLUS-IEEE-003 | 17.10.1 | Complete query matches an argument prefix, with ordered search | No digital present/prefix/nonprefix behavioral result yet. A nonzero success result must not be overconstrained to exactly 1. |
| PLUS-IEEE-004 | 17.10.1 | No match returns integer zero | `audit_test_plusargs_absent.v` expects `literal=0`, but current digital execution fails before output. |
| PLUS-IEEE-005 | 17.10.2 | No match returns zero, preserves destination and generates no warning | `audit_value_plusargs_absent.v` uses integer 37 and packed a5 sentinels; current execution fails at first query. Expected stdout alone does not validate the no-warning stderr obligation. |
| PLUS-IEEE-006 | 17.10.2 | First matching argument supplies conversion input | Requires explicit duplicate matching invocation arguments; not established by no-match tests. |
| PLUS-IEEE-007 | 17.10.2 | Supported conversion letters, uppercase/lowercase and leading-zero forms | Decimal/octal/hex/binary/real/string forms need independent cases; unsupported format and malformed signature rejection require intended-rule diagnostics. |
| PLUS-IEEE-008 | 17.10.2 | Empty remaining input yields zero or empty string | Present-argument digital case still open; absence is not empty remainder. |
| PLUS-IEEE-009 | 17.10.2 | Pad/truncate to destination width, including negative conversion rule | Width/signedness observations pending, independent of prefix discovery. |
| PLUS-IEEE-010 | 17.10.2 | Illegal conversion character writes unknown value | Four-state digital oracle required; not interchangeable with no-match preserving an old destination. |

These are clause-local atomic rules, not exhaustive cross-products or a new B
denominator. Invalid-input evidence remains open; unimplemented-function failure
is not rejection coverage for invalid arguments.

### New digital derivation and observed results

Both fixtures are legal positive transcripts under an invocation with no
plusargs. `audit_test_plusargs_absent.v` expects zero for a literal query.
`audit_value_plusargs_absent.v` initializes destinations independently, then
expects both zero status values and unchanged 37/a5. The sentinels distinguish
preservation from an erroneous zero writeback. Expected transcripts were
derived before execution. Direct root `vera --run` from the isolated worktree
exits 1 at `$test$plusargs` / `$value$plusargs`, respectively, with E1100
`this digital expression form is not implemented`, before any output. These
are positive failures, not negative cases and not declared passing/XFAIL here.

Initial drafting included a packed query variable with a computed width and
string assignment. The digital engine rejected the computed bound and then
the string assignment before reaching the target function. Those orthogonal
features were removed from the final bounded witnesses, leaving literal query
calls as the first failing operation. Packed-query acceptance/behavior is still
recorded in PLUS-IEEE-002, not silently withdrawn or credited.

At the time of inspection root `lib/backend/codegen.zig` lowered both analog
queries to constant zero. Analog fixtures 065/066 observed only absence and
unchanged destinations. Historical rows 17.10-01/-02's broad “verified analog”
labels therefore cannot establish present-list behavior. The Chapter 9 worker
has separate positive present/prefix/duplicate/empty cases and `//! plusargs`
runtime plumbing in flight; main should reconcile that handoff before updating
any ledger status. No analog files or shared harness are changed by this group.

Main integration should run the digital gate and compare failure names. No full
Zig suite, compiler edit, A/C measurement or whole-row B closure was performed.

## Remaining §§17–18 work

The historical inventory remains a lead, not an atomic denominator. File I/O,
timescale tasks, simulation control, PLA, queues, conversions, probabilistic
functions, plusargs, math and VCD/extended-VCD require further independent source
reads and artifact/behavior tests. Existing scheduling/monitor/display reviews
must not be duplicated or promoted to full closure by this time-query group.
