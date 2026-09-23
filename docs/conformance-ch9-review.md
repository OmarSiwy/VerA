# Chapter 9 source and behavioral evidence review

Main checkpoint: the §9.19 source text and syntax were independently checked,
and both new positives were independently emitted and run (eight and three
successful observations). Both wrong-kind negatives were independently accepted
with check exit 0, confirming the reported defects. The HTML repair and four
binding fixtures are integrated; their full-suite comparison is pending.
Main also read complete AMS §9.11 and IEEE §17.8, and independently ran both
new conversion fixtures and the repaired 063 fixture. Runtime conversion's
five checks and the sized bit-pattern checks pass; all three constant defaults
emit W1050 and fail with zero values. Those fixtures and the explanatory header
repairs are integrated. The subsequent §9.10 source checkpoint remains the
parallel reviewer's record rather than new runtime evidence.

Status: in progress. First coherent group: AMS §9.19 explicit binding detection,
reviewed 2026-09-23. This ledger supplements the existing display, scheduling,
parameter and inherited-source audits; it does not replace their results.
The full remaining Chapter9 scope is owned by this audit, with AnnexA grammar
and cross-links queued afterward. Neither chapter is declared complete.

## Source checkpoint

Full-suite integration correction: the first binding/conversion run added the
three expected XFAILs but also rejected both binding positives because their
CHECKI expected operands were parameters, not literals. Direct runtime success
had not established harness validity. The two fixtures now use separate child
definitions with literal expected 0/1 values, preserving the named/ordered/
defparam and omitted/explicitly-connected scenarios. Main independently reran
the corrected fixtures and observed all eight and three checks passing. The
initial full log is `/tmp/vera-binding-conversion-strict.log`; it is retained
as evidence of the test-oracle failure, not reported as a clean regression run.
A corrected full run is required before closing this integration checkpoint.

That corrected run completed: `/tmp/vera-vpi-binding-strict.log` exits 1 for
remaining known debt. Relative to the initial run, exactly the two erroneous
binding FAIL names disappear; every other FAIL/XFAIL name is unchanged.
The simultaneous Chapter 11 metadata correction changes no fixture outcome.
`tools/conformance.sh` regenerated the measurement report using this log and
its matching coverage log; unit tests pass and the digital gate remains FAIL.

Read all §9.19 text, Syntax9-14 and the full myclk/twoclk/top example from
physical PDF264–265 (printed251–252) against root `ch9-system.html`.
Rendered physical264 and visually inspected Syntax9-14 and macro punctuation.
`tools/lrm_audit.py --section 9.19 --diff` reports line-wrap differences and
the punctuation normalizations noted below, not omitted requirements.

HTML changes preserve text: literal function names and parentheses in
Syntax9-14 now have bold markup corresponding to the PDF's red terminals.
A labeled editorial paragraph documents the existing curly macro-introducer
to ASCII backtick and possessive-apostrophe normalizations. The source's
`vout_q1b` declaration in twoclk and awkward “because it vout_q” wording
remain untouched; no inferred source repair was inserted.

Source authority is `VAMS-LRM-2023.pdf`, SHA256
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.
No IEEE text is needed to establish the binding predicates themselves;
the legal elaboration mechanisms they observe have inherited requirements.

## §9.19 rule/evidence inventory

Paths in this section are under `tests/fixtures/`. New results below use the
existing root-built VerA executable, not a newly built compiler; full harness
and regression gates remain for integration. Eight and three check counts
are counts of observed ok=1 output lines, not conformance percentages.

| ID | Obligation / independently derived evidence | Disposition |
|---|---|---|
| BIND-001 | `$param_given` is zero for a declaration not overridden. New `ch09_system_tasks/audit_binding_source_overrides.va` untouched child reports0 with gain1. Existing159 and ch06 instance fixtures are additional leads. | New direct runtime observation passes. |
| BIND-002 | Named instance override reports1 even when value equals default. Same new fixture named child has gain1 before/after, expected1. | Runtime passes; differs from value-comparison implementation. |
| BIND-003 | Ordered instance override reports1 even when value equals default. Same fixture ordered child, gain1 expected1. | Runtime passes. |
| BIND-004 | Defparam override reports1 even when value equals default. Same fixture deferred child, gain1 expected1. | Runtime passes. All four children also assert gain remains1, totaling eight observed checks. |
| BIND-005 | `$param_given` accepts exactly one parameter identifier, not a variable. `audit_param_given_variable_rejected.va` declares a real variable and calls the predicate on it. | DEFECT BIND-ARG-001: direct --check exits0. New isolated rejection is XFAIL; `$param_given requires a parameter identifier` is the intended distinctive diagnostic contract, pending implementation, not an observed message. Legal neighbor is the source-overrides fixture. |
| BIND-006 | `$port_connected` is determined at the instance connection list, not by ultimate use of the net. New `audit_binding_unused_parent_port.va` omits outer at parent instantiation but explicitly connects child.inner to outer. Parent expected0, child expected1. An explicit blank named connection in another child gives0. | Runtime passes all three checks. Neither expected1 nor expected0 is derived from a forced voltage or top-level host convention. |
| BIND-007 | Connection by order or name counts; blank and omitted forms do not. The new hierarchy case covers named and omitted/blank named forms. Existing `ch06_hierarchy/port_connected.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va`, and `named_port_instantiation_unsupported.va` cover other forms by intent. | New case observed; existing fixtures are inspected leads, not rerun here. |
| BIND-008 | Connected-to-net with no other connections still reports1. Existing ch06 `port_connected.va` explicitly connects lone to dangle and asserts1. New hierarchy case separates local binding from a missing upstream binding. | Existing source inspected; fresh result pending. |
| BIND-009 | `$port_connected` takes one port identifier, not an internal net. New `audit_port_connected_internal_net_rejected.va` uses a declared electrical internal net, removing undeclared-name/discipline confounders. | DEFECT BIND-ARG-002: direct --check exits0. New XFAIL rejection uses `$port_connected requires a port identifier` as the intended distinctive diagnostic contract, pending implementation, not an observed message. New hierarchy fixture supplies legal port neighbors. |
| BIND-010 | Both values are fixed at elaboration and constant during simulation; legal in genvar expressions controlling analog operators. | Open: no new temporal/stability or operator-guard discriminator. Acceptance of simple calls does not discharge this. |
| BIND-011 | Exactly one argument: zero/excess arity, nonidentifier expression/string, wrong object kind; resolve scalar-port grammar versus prose for indexed/vector forms before asserting rejection. | Partially covered by new wrong-kind cases; remaining alternatives open, not one rejection per clause. |

## Important existing-evidence limits

`ch09_system_tasks/29_binding_detection.va`, `103_param_given.va`,
`159_param_given_not_overridden.va`, `165_param_given_override_equals_default.va`
use the runner's top-level override convention. Those can test the generated
device/host interface but do not by themselves distinguish source-level
named, ordered and defparam elaboration. The new source-overrides fixture
exercises all three explicitly.

`104_port_connected.va` asserts the host binds top-level ports. Its header
calls a flow contribution `V(p,n)=0.5`; that is not what its `I(p,n)<+V(p,n)`
statement says. More importantly, the LRM predicate concerns a source instance
connection, so top-level host policy must not be counted as the full rule.
The existing ch06 port_connected fixture already documents and repairs that
problem for its own test; the new nested case extends its binding-depth evidence.

These new fixtures do not certify arbitrary hierarchical resolution, all
parameter types, all arrayed instances, genvar-loop legality, or runtime
constancy under every analysis. No compiler code was changed in this checkpoint.
MeasureA/C refresh is reserved for `tools/conformance.sh` at integration;
this ledger introduces no measured percentage and closes no architecture phase.

## Conversion follow-up: §9.11 and inherited IEEE §17.8

Read complete AMS §9.11 (physical250, printed237) against HTML and the complete
IEEE1364-2005 §17.8 text/example (physical340–341, printed310–311). AMS grants
analog-context use of $bitstoreal/$realtobits/$rtoi/$itor; IEEE supplies the
conversion behavior and explicitly allows constant expressions. The AMS token
diff shows only a wrapped $bitstoreal spelling; no HTML text repair needed.
IEEE conversion-function text was read in extraction, not visually certified.

| ID | Obligation and discriminator | Evidence |
|---|---|---|
| CONV-001 | $rtoi truncates rather than performing ordinary real-to-integer rounding. For runtime ±1.75, $rtoi gives±1 while ordinary assignment gives±2. | New `audit_conversion_truncation_signed.va` observes both signs and both paths. |
| CONV-002 | $itor converts signed integers to real. Runtime integer−2 becomes real−2.0 exactly. | Fifth check in the same new fixture; does not certify every integer width or boundary. |
| CONV-003 | Conversion system functions are valid in constant expressions. Parameter $rtoi(±1.75) must be±1; $itor(−2147483647) must be exactly−2147483647.0. | New `audit_conversion_constant_expressions.va`: W1050 replaces all three defaults with0, all three assertions fail. XFAIL records CONV-CONST-001; no compiler change or weakened expected value. |
| CONV-004 | $realtobits maps real values to their64-bit IEEE representation. | Existing063 repaired: explicitly sized64'h3FF0000000000000 and64'h3FE0000000000000 comparisons for1.0/0.5, asserting Boolean1. This removes the admitted unsized-decimal-width assumption without changing the intended pattern. |
| CONV-005 | $bitstoreal reverses the representation. | Existing064 and15 round-trip source inspected; their previous runtime results are not reasserted by this new reading. Round-trip identity alone cannot rule out matching inverse bugs. |
| CONV-006 | Conversion permits constant forms and port transport of representation; real-number representation and rounding follow inherited IEEE requirements. | Other constant paths, module-port bit transport, subnormal/sign-bit/nontrivial-mantissa patterns, signed-zero observability and argument invalidity remain separate open cases. Do not invent an out-of-range $rtoi rejection without source authority. |

The063 oracle repair is justified before any compiler change: its own previous
header admitted a legal narrow-unsized implementation could fail the test.
A Boolean comparison to a sized pattern retains every expected bit while its
numeric expected value fits the harness. The064 cross-reference now describes
that repaired form. The15 header's blanket “$rtoi/$itor unimplemented” claim
is superseded: runtime works for the observed cases, constant evaluation does
not. All expectations retain independently derived source values.

## Simulator-time source checkpoint: §9.10

Read complete AMS §9.10 physical250 against HTML; only the source list marker
differs. $abstime is an absolute real-valued time in seconds, in both contexts.
Existing14_abstime.va observes2.5e−9 in analog context; that is not a digital
context result or proof of time across module timescales. No new time fixture
or runtime result here. Existing148_realtime_analog_rejected.va correctly
distinguishes the deprecation note from Table9-7's analog-context No cell;
do not claim the note alone makes deprecated usage illegal. Table9-7 and the
complete inherited IEEE17.7 time-function obligations remain to be audited.

## Command-line group: §9.12 and inherited IEEE §17.10

Read the complete AMS §9.12 text (physical250, printed237) and IEEE
§17.10 including §§17.10.1–17.10.2 and examples (physical350–353,
printed320–323). AMS extends these functions to analog context; IEEE defines
the actual search/conversion contract. No AMS HTML text discrepancy found.

The existing065/066 fixtures exercise only absent arguments. The runner
previously invoked each executable with argv0 alone, so they could not test
successful searches. New test-only `//! plusargs` plumbing preserves supplied
argument order and duplicates. Lines may repeat; ASCII space/tab separates
tokens, each of which must begin with+ and have another byte. Only printable
ASCII is supported and quotes/backslashes are rejected, not interpreted.
Shell metacharacters are ordinary argument bytes; the runner passes argv
directly, never through a shell. Embedded spaces and Unicode argument strings
remain explicitly unsupported by this fixture directive, not by the LRM.
Invalid directives fail setup through the existing parser-error path.

| ID | Obligation / discriminator | Evidence |
|---|---|---|
| PLUS-001 | $test$plusargs matches an argument prefix, not necessarily its entire name; successful return is nonzero, not necessarily1. | New `audit_plusargs_prefix.va` supplies+HELLO, expects HEL and HELLO matched after Boolean normalization; HELLOx and hello absent. |
| PLUS-002 | $value$plusargs uses first matching argument in supplied order and converts the remainder. | New `audit_plusargs_value_order.va` supplies+gain=7 then+gain=8 and expects7, with successful status normalized. |
| PLUS-003 | Empty numeric remainder converts to zero. | Same new fixture supplies+empty= and expects status nonzero, value0 rather than retained99. |
| PLUS-004 | No matching value argument returns0 without changing destination. | Same new fixture expects missing query0 and preserved42; existing066 is additional absence-only evidence. |
| PLUS-005 | String/non-real argument interpretation, all legal conversion formats/case/leading0, width padding/truncation, negative values, illegal conversion toX and string destinations. | Open; not certified by the decimal scalar cases above. |

Measured on the existing root executable with explicit argv: prefix fixture
prints two failing and two passing checks; value fixture prints four failing
and two passing checks. XFAILs PLUSARGS-001/002 retain the source-derived
expectations. Both programs exit0, illustrating why their exit status alone
is not a passing result. To run the old executable before the new directive
parser is built, scratch copies changed only `//! plusargs` into ordinary
comments and the same argv was supplied directly. The checked-in fixture
directives await the integrated runner gate. Code inspection identifies the
codegen branch that returns0 for both functions; production code is unchanged.

Focused `zig test` of tb.zig passes both new plusargs-parser tests and both
existing expected-exit/check-count tests. `zig fmt --check` and diff-whitespace
checks pass. Full harness compilation, regression name-list comparison and
measurement remain integration tasks; no A/C number is inferred here.

Main integration: read complete IEEE §17.10 text/examples (physical350–353)
and AMS §9.12; reviewed both new fixture oracles and runner/parser changes.
The runtime-argv plumbing and fixtures are integrated. The independent
capture-level test uses a fixed shell probe with quoted positional arguments;
the runner itself directly spawns argv, never interpolates fixture text into
a shell command. Integrated unit and full-harness gates remain pending.

Main independently reran both plusargs parser tests and the capture-level
argv probe: all pass. The complete `zig build test` gate exits 0 in
`/tmp/vera-plusargs-intro-unit.log`. The full fixture run is still pending;
passing argv plumbing is not evidence that the generated model implements
either plusarg function.

To supply fixture arguments, use e.g. `//! plusargs +HELLO +gain=7`; repeat
the directive to append arguments in source order. This narrowly scoped
test-runner directive accepts only printable ASCII tokens beginning with `+`,
split by spaces/tabs, without quotes or escapes. It is not a restriction on
the Verilog-AMS language. Direct `vera --emit-exe` produces an executable;
when running that executable manually, pass the arguments explicitly.

## Remaining Chapter 9 handoff boundary

Main read the complete following source/evidence handoff on 2026-09-23. Its
HTML/figure/typography patch is integrated; the new and revised fixtures in
these remaining groups are still pending separate integration and verification.
Worker direct observations below are not a main full-suite result. Earlier
main binding-oracle corrections and plusargs checkpoints above remain intact.

## Analog alias group: §9.20

Read complete text, syntax and example on physical265–267 (printed252–254).
Visually inspected physical265 Syntax9-15; marked red function names and
parentheses as bold literals, leaving the source's black commas unchanged.
Stripping the new markup preserves the grammar text. Restored missing () after
$analog_node_alias in the prose prohibiting alias targets that are another
call's first argument; this is present in the PDF. Remaining example source
and conditional/validity requirements are retained without inferred repair.

| ID | Obligation / evidence | Status |
|---|---|---|
| ALIAS-001 | Local first argument must be a declared continuous scalar or full vector; not select, port, or involved in port connections. | Existing142/143 isolate port/bit-select violations. Part-select, full-vector legal behavior, undeclared/wrong-kind and involved-in-connection distinctions remain open. |
| ALIAS-002 | Target must be constant literal/string parameter; cannot identify another alias call's first argument. | Existing144/145 inspected; no fresh runtime result claimed. |
| ALIAS-003 | Only analog initial; reevaluated at DC sweep points as needed; conditional guard invariant during simulation. | Existing141/146 and ch05/a02_10 are leads; parameter-controlled if/case/?: legal neighbors and changed topology across sweeps remain unclosed. |
| ALIAS-004 | Valid target gives1 and identical matrix position; invalid gives0 and leaves ordinary local node. | Existing191_node_alias_resolves and30 inspect both sides but not every validity branch. Source explicitly requires compatible disciplines and scalar target or vector element. |
| ALIAS-005 | Alias to a valid child-instance port exposes that instance's port flow, not aggregate parent-net flow. | New audit_port_alias_child_flow.va: selected1kOhm branch at5V gives5mA; another2kOhm branch on same net gives2.5mA. Expected child current is5mA, not7.5mA. Root executable rejects valid source at E0508 before checks execute; XFAIL ALIAS-CHILD-001 records this. |
| ALIAS-006 | Last evaluated call on a particular local node takes precedence. | Existing191_node_alias_last_call_wins separates two valid targets; invalid-last reset and mixed node/port calls remain open. |
| ALIAS-007 | For port alias the target must really be a port; incompatible disciplines and nonscalar targets return0, not an arbitrary language rejection. | Additional targeted validity-branch fixtures needed; invalidity of target is distinct from structurally illegal first argument. |

Corrected existing191_port_alias_resolves.va's unsupported prose: inability
to retain a child port through compiler flattening does not make the source
reference invalid under §9.20. Returning0 is not conformant merely because
the compiler cannot honor a valid reference. Its top-level forced-flow test
is unchanged; the new child-instance fixture supplies the missing distinction.
New fixture expected values follow the PDF example's5V/1kOhm derivation and
add a second branch to distinguish selected-port from aggregate flow. No
compiler semantics were changed. Full harness gates remain integration work.

## Thermal-parameter checkpoint within §9.15

Read complete §9.15 physical254–256 (printed241–243), including the simulation
parameter tables and string example. Behavioral follow-up here is limited to
$temperature/$vt; $simparam and $simparam$str require their own inventory.

§9.15 defines thermal voltage as kT/q but does not bind kernel constants to
AnnexD's source macros. A finite window spanning the AnnexD sets therefore
does not establish an exhaustive conformance oracle. Withdraw those windows
in ch09/21_temperature_vt.va,095_vt_ambient.va,096_vt_temperature.va and
annex_h_glossary/09_nonlinear_nr_relationship.va. Replace them with explicit
CHECKEQ identities: bare versus ambient-explicit form, linearity inT and
argument-versus-ambient scaling. The AnnexH expression test now checks an
exponential reciprocal identity instead of a current computed from assumed
kernel constants; remove its D.2 citation. Its limexp contribution and warning
that this does not prove Newton convergence remain intact.

Observed runtime checks:21 threeok1;095 twook1;096 twook1;AnnexH09 threeok1,
using existing root executable. No tolerance is widened to retain numerical
claims. Absolute physical-scale verification moves to open obligation
THERM-SCALE-001: these identities alone cannot reject a common wrong scale
or uniformly-zero implementation. Broader independent physical requirements
and supported implementation constants need a justified oracle before closure.
Argument arity/type constraints, digital-context behavior and all simulation
parameter name/value/error/string scope obligations remain open in this group.

## Simulation-parameter follow-up within §9.15

Visually checked Syntax9-10 on physical254 and restored literal/meta typography
without changing stripped grammar text. Added an editorial source note to the
source's general real-valued-result sentence: the later text expressly makes
$simparam$str string-valued. The source sentence is not silently rewritten.

| ID | Obligation / discriminator | Evidence |
|---|---|---|
| SIMPAR-001 | String variable names are permitted; a known parameter beats fallback and also works without fallback. | New audit_simparam_string_variable.va queries timeUnit via variable with/without fallback; timescale1ns/1ps independently implies1e−9seconds. Both checks pass. |
| SIMPAR-002 | Unknown name plus fallback returns the expression, without error. | Third case in new variable fixture passes2.5; uses the existing suite's deliberately absent vera_no_such_simparam name. This depends on that name remaining absent from this implementation's extension table, not a universal ban on vendor names. |
| SIMPAR-003 | Unknown name without fallback errors; every numeric result is real, including integer-valued parameters. | Existing147 rejection and157 source inspected. Declaring a real destination alone cannot distinguish implicit conversion from correct function type; a dedicated type discriminator remains open. |
| SIMPAR-004 | Table9-28 module is lexical module name; instance is hierarchical instance name. | New audit_simparam_string_hierarchy.va instantiates one module twice and checks same module name, different fully qualified instance names. Four checks pass. |
| SIMPAR-005 | Required string names include analysis_name/type,cwd,module,instance,path; numeric table names required only when supporting the parameter. | Existing23/a10_07 cover analysis_type by intent. Task-level path, cwd, host-selected analysis name, runtime-varying names and cross-version monotonic version numbers remain open. |

The new variable fixture can be constant-folded; it must not be claimed as
runtime-varying string-name evidence. Existingch05/a10_07 explicitly addresses
solution-chosen names and should be retained as its separate discriminator.
The new hierarchy fixture uses CHECKI literal1 wants, with name comparison
inside the actual expression, avoiding the harness's nonliteral-oracle trap.
All seven new checks observedok1 on the root executable; full suite pending.

Plusargs follow-up verification: added capture-level independent POSIX argv
probe to tests/torture.zig. A fixed /bin/sh script prints quoted positional
arguments; supplied entries are never interpolated into script source. Exact
captured bytes prove duplicate/order/empty remainder preservation and literal
$HOME,*,semicolon and command-substitution text; absent argv produces empty
output. The filtered capture test passes; Windows explicitly skips this POSIX
probe. This isolates argv plumbing from the generated model's known stub.

## Dynamic probe checkpoint: §9.16

Read full source physical256–257 (printed243–244), including syntax and both
monitor/SPICE examples, against HTML. No substantive text omission found;
syntax typography is not yet visually certified for this production.

New audit_simprobe_missing_instance_rejected.va isolates absent sibling with
no fallback: direct --check exits1 with E0817, the pinned diagnostic. Existing36
is its fallback-positive neighbor. New audit_simprobe_missing_quantity_fallback.va
instantiates a real empty sibling, so only the quantity is absent; expected3.25
is returned and the sole runtime assertion passes. This separates the clause's
two lookup-failure alternatives rather than testing only a wholly absent pair.

The source requires lookup in the caller's parent (sibling scope), output
variable access, string literal/parameter/variable names and dynamic monitoring.
Existingch05/a10_09 and a10_10 inspect those positive scope/value obligations;
their bodies were read, not freshly executed here. Their parameter-query
extensions must not substitute for the required output-variable case.
Missing quantity without fallback, runtime-changing target/name, updates of
observed quantities and non-sibling shadowing remain separate open cases.
The existing ch09COVERAGE claim that runtime-name failure is covered by the
fallback is unjustified: inability to implement a valid name does not make
the name unresolved under the standard. The new evidence does not close that
gap or prove all sibling-scope behavior.

### §9.16 existing-oracle repair, subsequent checkpoint

Repaired ch05/a10_09 and a10_10 after the preceding inspection. a10_09 now
probes attributed output variables id and twice_id; bias0.75−0.25 and gain2
give1.0 and2.0 independently. a10_10 publishes attributed gain_value=3.0,
retaining the nested hierarchy: sibling query gives3.0; invalid top-style
string still gives−1.0. Both fixtures compile and all four checks printok1
on the existing root executable. No XFAIL is needed for these observed cases.

Withdraw the old parameter-access “strict subset” claim and historical
failure prose; §9.16 does not make parameter-query extensions obligatory.
The old parameter-path observations in a10_SPEC.md are historical, not current
normative coverage for these revised fixtures. This checkpoint supersedes
the preceding not-rerun status for these two fixtures only. Remaining dynamic
name/update requirements are not discharged by these fixed-point observations.

## Hierarchical parameter checkpoint: §9.18

Read complete source physical261–264 (printed248–251), visually inspected
Syntax9-13 and Table9-29 on261–262. HTML table rules agree with source;
restore red function terminals as bold, preserving stripped syntax. Restore
source Example1/Example2 labels and add editorial notes about missing starting
overrides: source comments assume mfactor3 and xposition1.1u, neither supplied
in the displayed examples. Do not infer42 or4.1u from that incomplete source
alone or silently insert overrides into the transcription.

New audit_hierarchical_geometry_composition.va derives nested geometry values
from explicit settings: offsets2−3=−1 and−4+6=2; angle(300+100)mod360=40;
two horizontal−1 flips multiply to+1; omitted vertical override retains−1.
A final fully unspecified child tests inheritance without reset. No rotation
of coordinate offsets is inferred beyond the table's addition rule. All wants
are literals. Current compiler rejects the valid overrides with E0907 before
execution; XFAIL HIER-GEOM-001 retains all five expected results.

Existingch06/geometric_system_parameters and ch09/097–102 cover only top-level
defaults by intent; ch06/mfactor_propagation_unsupported explicitly tests
product14, not the source example's unstatedfactor3. New geometry case does
not close automatic mfactor current/noise scaling, aliasparam/paramset binding,
all allowed-value boundaries or isolated invalid-values diagnostics. These
remain separate obligations, as do other legal override mechanisms.

## Analog kernel-control checkpoint: §9.17

Read complete §§9.17.1–9.17.3 on physical257–261 (printed244–248), including
relay/triangle/sine/diode examples and all three limiter-argument rules.
Visually inspected physical259 for bound-step signature and Syntax9-12;
restore red terminals as bold without changing stripped syntax. Source's
second-alternative comma after string is black; preserve that typography
rather than silently infer a different source grammar rendering.

| ID | Atomic group / evidence boundary | Disposition |
|---|---|---|
| KERNEL-001 | Discontinuity degree constant/nonnegative, special−1, default spelling; automatic handling for switched branches/filters. | Existing24,138,139,185 are leads. Callback timing/solver reaction not proved by acceptance. |
| KERNEL-002 | Bound step required nonnegative expression, minimum-step floor, smallest active bound, ignored outside time-domain analysis. | Existing136/137 negative/arity leads.25 checks argument arithmetic and a forced waveform point only; it cannot prove inserted timepoints or minimum active bound. Adaptive-step behavior remains open. |
| KERNEL-003 | Limiter may choose algorithm or bypass limiting when other convergence methods suffice; accepted solution must satisfy access-value closeness. | Existing26/27/156 inspect accepted-point expressions, not arbitrary first-iterate trajectories. Their convergence/tolerance assumptions require host evidence. |
| KERNEL-004 | Named unsupported limiter must use simulator-selected algorithm, not necessarily error; pnjlim/fetlim have specified required tail arguments. | Existing named/annexE arity fixtures are leads; no required algorithm/output trajectory may be inferred solely from suggested name. |
| KERNEL-005 | User callback first arg current access, second appropriate internal state (only generally previous return), subsequent args forwarded; all declared input; callback shall announce−1 when not close. | Existing164 rejection is one direction. Exact callback/state/iteration obligations need conditional host instrumentation, not mandatory invocation assumptions. |

High-risk existing oracle assumptions:177/178 require fixed initialstate0,
cross-call shared access-function state and exactly one prescribed clamp update
per declared timepoint;180 requires exact history0→3;179 equates solver
iteration to$abstime+1 and assumes vendor iniLim absence;184 mandates exactly
two iterations. These are implementation regression expectations, not universal
conformance requirements of the read source. Moreover getold/previous callbacks
can return unlike their first argument without required$discontinuity(-1).
No expectation was weakened to conceal this; migration of those regression
contracts out of normative credit is pending coordinated scope decision.

### KERNEL-REG-001: implementation-oracle quarantine

Following scope approval, remove unsupported machine-readable lrm tags from
177,178,179,180,181,182,184 and prepend explicit implementation-regression
headers. Assertions, models, stimuli and expected outputs are unchanged.
They remain in the suite to detect VerA regressions but do not contribute
normative clause citations. Headers identify fixed trajectory/iteration/state
assumptions and, for177–180, the getold/previous callback announcement issue.
No discontinuity call was silently added to change those regression programs.

183_limit_newton_convergence remains a separately valid positive neighbor:
its limiter announces−1 when not close; the assertion concerns the solved
equation exp(V)−exp(2)=0, not an obligatory number of iterations or invocation
of the suggested callback. Fresh existing-root executable run prints oneok1.
This is a host-tolerance-bounded result, not proof of all limiting policies.

## Probabilistic-function AMS checkpoint: §9.13

Read full AMS physical251–254 (printed238–241); visually inspected Syntax9-8
and9-9 on251–252. Restore red terminals as bold without changing stripped
grammar. Editorial note explicitly records pre-existing normalization of
source production name “random seed” to random_seed and missing initialT in
“he system functions”; repeated introductory sentence remains preserved.
Table9-26's existing caption-correction note is retained. Inherited IEEE17.9
algorithm review is assigned here next, not presumed satisfied by this reading.

Twelve new isolated invalid fixtures audit_rdist_*_{zero,negative}_rejected
cover each expressly positive argument separately: exponential mean, Poisson
mean, chi-square degrees, t degrees, Erlang k_stage and Erlang mean. Every
direct --check exits1 with E0816 and “greater than zero”. Existing150 bundles
two violations, which cannot independently establish both. Existing126–130
are legal-domain leads; new rejects do not certify positive distributions.

New audit_arandom_constant_seed_stream.va compares one repeatedly evaluated
constant-seed$arandom(7) site with an explicitly initialized variable-seed
$random stream. §9.13.1 specifies hidden initialseed7 and subsequent updates,
and upward compatibility. All three comparisons currently fail; XFAIL
RNG-CONST-001 records the defect without demanding successive draws always
differ (random collisions are legal). Existing117 only checks unchanged
parameter and result width, insufficient for hidden-state advancement.

Remaining obligations include seed argument kinds/context restrictions,
32-bit signed result before assignment conversion, same-seed algorithms and
writeback for all distributions, real-valued shape arguments, every arity,
uniform endpoint order, paramset-only type strings and Monte-Carlo trial versus
instance resampling. Existing175's assertion that a compilation is a trial
and three type spellings necessarily share a draw needs host/trial evidence;
do not count its acceptance as Monte-Carlo scheduling closure. Source171's
open-source algorithm reproductions are leads until checked against the supplied
IEEE listing. No frequency-sample statistics can replace deterministic algorithm
conformance or prove a distribution exhaustively.

### Inherited IEEE17.9 source verification

Read complete IEEE1364-2005§17.9.1–17.9.3, physical341–350
(printed311–320), including Table17-17 and every C algorithm/wrapper.
Visually inspected physical347 (printed317), confirming the extra closing
parenthesis in the full-range rtl_dist_uniform normalization is in the PDF,
not extraction damage. The listing assumes traditional32-bit long behavior;
literal compilation on an LP64 host or reliance on C signed-overflow semantics
is not a portable independent oracle. Record32-bit wrapping interpretation
and the parenthesis correction when constructing a reference.

Checked the existing171 fixture's selected uniform/random values directly
from the supplied listing in an independent JavaScript calculation using
explicit32-bit multiplication/bit-punned binary32 mantissa and binary64
arithmetic. Seed7 updates483484 then−965981971; uniform(0,10) returns
0.0011265279204053513 then7.750899523603607; full-range random returns
−2146999808 then1181502348. These agree with171's existing expected digits.
This verifies those selected paths, not every branch/distribution. Source
kernel inspection compared the core formulas but does not certify the emitted
call/seed-state plumbing (new RNG-CONST-001 fails there).

Source tensions requiring explicit accounting: AMS Table9-26 names erlang
but IEEE's underlying helper is named erlangian; AMS permits real shape/count
arguments, while the inherited C count algorithms accept long. Fractional
degrees/stages are therefore legal AMS input whose numerical algorithm needs
an explicitly justified extension; the current kernel rejects them as an
implementation limitation. IEEE integer uniform says start should be smaller
than end, and its wrapper returns start unchanged when start>=end; AMS real
uniform instead says start shall be smaller. Do not transfer the stricter
real-uniform rejection to all integer uniform calls.

Algorithm obligations still needing discriminating references include zero
seed escape, signed-width folding, both integer extreme-end branches,
normal rejection-loop consumption, exponential zero guard, Poisson stopping,
odd/even chi-square paths, t's chi-square-before-normal order, Erlang product
order, wrapper rounding on both signs and nonfinite/overflow boundaries.
Per-distribution seed writeback must consume the same variable number of
draws as the selected algorithm; matching only the first returned value is
insufficient. No full algorithm closure is claimed.

## Math extension checkpoint: §9.14

Read complete AMS§9.14 physical254 against HTML; no substantive difference.
Inherited IEEE§17.11 inventory is coordinated with conformance-ieee-math-review.md,
not duplicated here. Also read physical353–354 for the needed runtime claim:
$clog2 accepts integer/arbitrary-width vector and interprets argument unsigned,
zero gives0. IEEE§4.8 allows native integer width at least32, not exactly32.

New audit_clog2_unsigned_runtime_integer.va feeds runtime$rtoi(V(p,n))=−1
to$clog2. At native widthW>=32 its unsigned value is2^W−1, hence resultW>=32.
The Boolean CHECKI want1 deliberately avoids a nonportable exact32 oracle.
Current runtime printsok0; XFAIL CLOG2-SIGN-001 records this independently of
the constant evaluator and digital arbitrary-width cases in the inherited
audit. Numeric identities and alias spelling alone do not establish all math
domains, constant contexts, result types or C-library equivalence.

## Table-model checkpoint: §9.21

Read complete§9.21–9.21.5 physical267–274 (printed254–261), including
all examples, Table9-30/31/32 and interpolation footnote. Visually inspected
Figures9-1/9-2 on268 and fullSyntax9-16 on269–270. Replace HTML's prose-only
figure stand-ins with source PNGs, retaining captions/labels. Restore literal
syntax typography with stripped text unchanged; explicitly label spacing
normalization and the source's printed2N (not exponent) notation. Do not
silently turn a transcription into an inferred formula repair.

Reproducible crops use tools/extract_lrm_figures.py convention, physical page
and top-left PDF points, at216dpi:

| Figure | page,left,top,width,height | SHA256 |
|---|---|---|
|9-1|268,160,86,305,214|73a8c9e41d6e10a785fda7cc0f8ea96cd5344cfc9179946650b1cbc2f771145f|
|9-2|268,137,463,370,222|ded4a6164b2a4132ee95d6fd6e630d299a63d5682e52bb94449f9a364cbb71c9|

Both own-worktree assets were visually checked against the full source page.
Extraction-manifest/test/README integration remains for main alongside9-3.

New audit_table_duplicates_and_end_controls.va has unordered rows with an
identical duplicate and three distinct samples onf(x)=2x. Lookup1.5=>3 proves
the legal duplicate does not force rejection. Four independent calls test1CL
and1LC below/above range:2,8,0,6. All five direct runtime checks pass. This
does not claim arbitrary-order multidimensional sorting or conflicting-data
error handling.

Open atomic groups: ragged isolines and intermediate minimum points; identical
versus conflicting duplicates in every dimension; file whitespace/comments/
blank lines and integer/real data; arrays/concatenations/2-D-array forms;
first-evaluated-call snapshots; ignored columns and dependent selector bounds;
null/omitted dimension substrings; discrete ties away fromzero; quadratic/cubic
endpoint constraints; extrapolation fatal-error phase; mixed dimensional
interpolation and real input derivatives. Existing155/186/187 fixtures address
some cases by intent but were not exhaustively rerun here. Conflicting
duplicates and E-extrapolation are runtime errors in this implementation;
a compile-reject fixture would demand the wrong phase and does not replace
a specifically diagnosed runtime-error oracle. Snapshot helper-call ownership
in187_table_snapshot_function is explicitly an inference, not an LRM example.

## Driver-access checkpoint: §§9.22–9.23

Read complete physical275–280 (printed262–267), including all examples,
driver/receiver segregation cases, pending-event warning and SDF footnote.
Visually inspected all Syntax9-17–9-24 on275/276/279/280, including page
continuations. Restore literal functions/punctuation without changing stripped
syntax. Normalize the source's curly DRIVER_UNKNOWN macro introducer to ASCII
backtick with an explicit editorial note; label source caption-spacing repairs.
Keep source next-strength range0..7 distinct from current-strength two3-bit
fields; no silent harmonization of that wording tension.

Complete the Chapter9 source figures with crops9-3/9-4, independently inspected:

| Figure | page,left,top,width,height | SHA256 |
|---|---|---|
|9-3|276,64,403,484,141|4bed8f2844ae7c16dde6172d2b1bae5b633fe2acfba6f3fbad1985986c09bc2a|
|9-4|277,150,417,312,216|e96cd234d4adab864821348a885db7ad0a87582d694713725fb9f47f90c30a7d|

All four crop records now prepared in extract_lrm_figures.py, with Chapter9
structural test/README addition based on current root versions. Focused tests
for Chapter9 images, all crop bounds and pinned source identity pass. No
redrawing or generated imagery is involved. The previous Figure9-3 table
remains as explicitly editorial accessible transcription below the source crop.

New digital/audit_driver_strength_encoding.v and expected transcript construct
one ordinary strong1 continuous driver and a connectmodule observation after
settling. Only index0 is legal, avoiding arbitrary numbering assumptions.
Expected count1, state1, current strength6*8+6=54, no-pending delay−1 and
next-state1 are source-derived. For next-strength it asserts only the expressly
specified0..7 range, not an inferred packed interpretation. Direct --run exits1
with E1100 (ordinary-modules/no-analog-declarations restriction), before any
behavior; DRIVER-CM-001 remains an unresolved positive failure. The digital
transcript runner does not implement XFAIL inversion, so no machine marker
pretends to excuse that result. Expected transcript is retained, not replaced
by the observed rejection. --check on.v is itself unsupported by the CLI and
is not used as semantic evidence for this fixture.

Atomic groups still open: exclusion of CM-origin drivers; ordinary receiver
enumeration; arbitrary driver ordering and all4state values; current strength
range encoding; driver_update on a newly pending value without resolved-net
change; default receiver bypass versus explicit CM assignment; timed pending
values, cancellation and caller-timescale fractional delays; next-state and
next-strength fallback; driver-type bit flags for wired nets/kernel drivers
and implementation-dependent lookahead. Existingm04_10–16 source inspected
in part supplies stronger topology/scheduling leads, not newly certified
runtime results here. Existing107/109–114 ordinary-module rejections cover
call-site restrictions, not these positive behaviors, and their analog call
context does not isolate§9.23's digital-only restriction inside a legal CM.

## §§9.1–9.3 and §§9.6–9.9: context and simulation control

Read the complete AMS source §§9.1–9.3 on printed218–225 (PDF231–238),
including all20 context tables and continuation rows, and §§9.6–9.9 on
printed235–237 (PDF248–250). Compared all table task/function names and
digital/analog Yes/No cells to HTML: no content difference found. This is
source fidelity, not behavioral coverage. The two connectmodule tables have
context-of-connectmodule qualifications, not ordinary-module permission.
IEEE inherited timescale, PLA and stochastic semantics are not newly closed
by their AMS statements that they are not extended.

Visually reviewed PDF248–249 for Syntax9-5/6/7 and Table9-25. Restored bold
literal distinctions without changing stripped grammar tokens; preserved the
source's black opening parenthesis in9-5 and explained its inconsistent
coloring. The existing explicit editorial repair of the malformed nonfatal
production remains labeled rather than passed off as literal source grammar.

| Atomic group | Evidence and boundary |
|---|---|
| CONTEXT-001 | Every Table9-1–20 entry needs separate valid context evidence and forbidden-context rejection where specified. Matching HTML cells alone do not supply either. |
| ITER-SIDE-001 | §9.3 rejected-iteration side-effect goal requires the task-specific exceptions, particularly $debug, $fdebug and $fatal; no blanket rollback inference is justified. |
| CONTROL-INIT-001 | New audit_initial_warning_info_continue.va executes both severity tasks in analog initial and checks a subsequent assignment survives into simulation: one ok=1, no ok=0. Observed messages also printed, but their transcript/initialization-location reporting is not asserted. |
| CONTROL-INIT-002 | Existing140_stop_in_analog_initial_rejected.va freshly checked: exit1, E0807 and the precise forbidden-location diagnostic. This rejects only this one source condition. |
| CONTROL-INIT-003 | $finish must prevent simulation after initialization; $error must finish initialization but prevent simulation; $fatal may abort initialization and must prevent simulation. Dedicated lifecycle/transcript evidence remains open. |
| CONTROL-ITER-001 | Accepted/rejected iteration termination/suspension and appropriate final_step behavior remain open; fixed requested points do not establish rollback or suspension/resumption. |
| CONTROL-MSG-001 | Optional diagnostic levels/default1, time versus DC sweep value versus initialization location, and nonfatal/fatal reporting formats remain separately open. |

Existing172/173 source shows actually executed termination tests, unlike
guarded055/056/057/058/12 fixtures. Their host exit conventions and exact
transcript prefixes are implementation choices, not literal LRM mandates;
this checkpoint does not certify those conventions as universal conformance.
The new initialization fixture is a narrow positive addition, not completion
of the task family or proof that the two messages were not dropped.

## §9.5: complete analog file-I/O source review

Read all AMS §9.5–9.5.9, printed228–235 (PDF241–248), including the
previously truncated multi-analysis/sharing paragraphs and complete scanning
conversion table. Visually inspected PDF241–244 for Syntax9-2/3/4 and all
Table9-24 mode rows. Restored literal/meta typography, preserving all stripped
grammar tokens. Existing source's misnamed file_open_function in9-3 remains
explicitly noted. Added editorial note beside9.5.4: its r/r+-only sentence
conflicts with Table9-24 update descriptions for w+/a+ and refers to9.5.2
instead of the opening-files clause9.5.1. Both source statements remain;
neither this audit nor a fixture silently chooses a new forbidden mode.

New audit_sscanf_literal_and_excess_arguments.va derives four checks directly
from9.5.4.2. Literal prefix matching, %% nonassignment and initial literal
mismatch behave as expected. The extra destination after format exhaustion
is overwritten with0 instead of retaining73: three ok=1, one ok=0, process
exit0. This is SCAN-EXCESS-001, explicitly XFAIL with unchanged normative
expectation. No external file or simulator iteration assumption is involved.

Atomic evidence groups requiring additional work:

| Group | Remaining independent obligations |
|---|---|
| FILE-DESC-001 | 32-bit MCD one-hot/bit31 clear, OR fanout, fd bit31 set and preopened descriptor identities, failure0, closed-channel reuse; filename expressions and all mode spellings need independent matrix evidence. |
| FILE-LIFE-001 | Write reopening in later analyses appends; cross-context write/append descriptors shared; no post-close access; none follows from an ordinary single-analysis file test. |
| FILE-FMT-001 | Only second sformat argument interpreted; dynamic formats; mismatch warning/continuation versus permitted static error; file strobe/monitor scheduling and debug exceptions. |
| FILE-SCAN-001 | New excess-destination failure above; existing162 supplies suppression/width/string/float leads, not all directives. Null whitespace, sign/underscore, overflow, %m, EOF versus mismatch, unread offending bytes and trailing whitespace remain separate cases. Invalid conversion is implementation-dependent, not a universal rejection target; insufficient destinations are undefined. |
| FILE-POS-001 | Signed offsets/all origins; rewind equivalence; unread cancellation; seek beyond EOF without extending, zero-filled gap after writing; append ignores seek; error return values. |
| FILE-STATUS-001 | Flush one/all descriptors, ferror string/code/reset, feof only after detected EOF; positive results do not establish all error paths. |
| FILE-ITER-001 | Rejected-iteration read rewind, deferred writes, immediate fdebug and fatal unsupported rollback require accepted/rejected iteration observation; current fixed-grid acceptance is not that evidence. |

This checkpoint reviews AMS file-I/O text, not all inherited IEEE17.2
requirements or every existing filesystem fixture. Existing s01 scanner
fixtures are behavioral leads and should be mapped per directive/stream state,
not counted as blanket closure by their broad §9.5.4.2 tags.

Final typography checkpoint: visually inspected the unnumbered
$discontinuity general form on PDF257 (printed244), then restored its red
literal/black metasyntax distinction using bold literals in HTML. No grammar
token changed. This completes the previously queued9.17.1 visual check;
it does not change the KERNEL-REG-001 behavioral-evidence limitations.

SCAN-EXCESS-001 implementation supersession (2026-09-23): the source-backed
guarded-write repair and additional alias/partial/file-position oracles are now
integrated. Main rebuilt the compiler and reproduced all passing observations;
see `conformance-scan-preservation-fix.md`. This supersedes that specific
pending fixture/fix status only, not the remaining Chapter9 handoffs or the
host rollback and general formatted-I/O obligations above.
