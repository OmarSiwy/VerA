# Inherited hierarchy source/evidence review

## Source boundary and prior work

Read complete IEEE1364-2005 §§12.1–12.2.3, including examples, printed163–173
/ physical193–203. Visually checked Syntax12-1 on physical194 and Syntax12-2
on physical195, including literal versus optional parentheses/brackets and
the optional named-parameter expression. Review date: 2026-09-23. Licensed
source pages are not redistributed.

The existing `conformance-ieee-scope-review.md` already reads §§12.6–12.8,
including scope and elaboration order. This installment does not repeat or
supersede those evidence boundaries. The second installment below reads
§§12.3–12.5. Clause12 behavioral evidence remains incomplete; reading the
entire source is not implementation closure.

AMS Chapter6 carries corresponding module/parameter rules, but its analog
extension and discipline/connection-insertion obligations remain additional.
The reviewed current HTML already states the named-empty/default requirement
at §6.3.3; the observed defect is implementation behavior, not missing prose.
IEEE Syntax12-1's `(From A.1.3` parenthetical lacks a closing parenthesis in
the supplied source. This is an editorial source anomaly, not grammar syntax
to require from HDL programs.

## Rule groups

These are tracked obligations, not a measured coverage denominator. A bounded
passing fixture is not complete closure of its row.

| ID | Source | Requirement and remaining evidence boundary |
|---|---|---|
| IH-001 | 12.1 p163 | Module declaration delimiters/name, ordered parameter/port lists, separate-body versus ANSI-port declaration constraints. Redeclaration and mixed syntax matrices remain. |
| IH-002 | 12.1 p163 | `macromodule` can replace `module`; implementation may treat it differently. Dedicated parsing/behavior/disposition still needed. |
| IH-003 | 12.1.1 p165 | Top modules do not appear in instantiation statements, including instantiations in unselected generate blocks; at least one top required. New digital positive is blocked before runtime. |
| IH-004 | 12.1.2 pp165–167 | Module definitions do not nest; instances create named copies; multiple instances per declaration and arrays permitted. Array semantics also require IEEE7.1, not reviewed here. |
| IH-005 | 12.1.2 pp165–167 | Instance parentheses mandatory; connection list only for modules with ports; positional order, expressions for inputs, explicit blank and omitted named disconnections. Detailed type/direction semantics deferred to12.3. |
| IH-006 | 12.2 pp167–168 | Untyped/unranged overrides replace type/range; ranged untyped becomes unsigned; typed and signed/ranged conversions obey declaration; signed-unranged follows final override range. Full signedness/width/real conversion matrix remains. |
| IH-007 | 12.2 p168 | Defparam wins over conflicting instance parameter override. Existing analog defparam row tests one case; no universal precedence claim. |
| IH-008 | 12.2.1 pp168–169 | Defparam may use hierarchical target, but cannot escape its enclosing generate-instance or instance-array hierarchy, including sibling iteration/array elements. Scope restrictions still need isolated paired controls. |
| IH-009 | 12.2.1 p169 | RHS is constant, using numbers and parameters declared in the same module. Runtime variables and foreign-parameter references need contextual negatives. |
| IH-010 | 12.2.1 p169 | Multiple same-file defparams: last encountered text assignment wins. Cross-source-file winner undefined. New positive covers only the defined same-file case. |
| IH-011 | 12.2.2 p170 | A single instance must not mix named/ordered parameter overrides; different instances may use different styles. Independent legal/invalid cases remain. |
| IH-012 | 12.2.2 p170 | Named-block/task/function parameters can be directly redefined only by defparam; dependency updates remain possible. Requires supported digital scopes; not tested here. |
| IH-013 | 12.2.2.1 pp170–171 | Ordered values follow declaration order, allow only prefix subset, cannot skip entries, and exclude localparams. Existing analog localparam-skip fixture is one useful case, not every source arrangement. |
| IH-014 | 12.2.2.2 pp171–173 | Named association must use parameter name; arbitrary subset allowed; empty parentheses keep default; repeated assignment to same name forbidden. New empty-positive fails; duplicate-negative rejects with misleading alias diagnostic. |
| IH-015 | 12.2.3 p173 | Override replaces a parameter's defining expression; unaffected dependents recompute from final values. New explicit-dependent-override case passes. |

No test asserts a winner for defparams in separate source files. Generation
hierarchy restrictions are not inferred from parsing a generate keyword.

## Existing fixture scope

`ordered_override_skips_localparam.va` asserts each ordered binding and its
dependent localparam separately. `three_dependent_parameters.va` tests a
propagating chain when only its root changes. The new dependency fixture
adds the different case where an intermediate parameter is explicitly
overridden, breaking its old dependency while downstream expressions update.

`defparam_unsupported.va` already tests defparam versus inline precedence;
the new same-file ordering row also distinguishes multiple defparams from
that one-defparam case. `named_parameter_instantiation_unsupported.va` is a
legal named-association/default control despite its historical filename.
Direct execution reproduced all five checks passing, including `$param_given`
for an explicitly changed parameter and an omitted parameter. None of these
existing fixture bodies or expectations was changed.

## New fixtures and observed results

| Fixture | Independent expected behavior | Observation |
|---|---|---|
| `ch06_hierarchy/audit_hierarchy_empty_named_parameter.va` | Empty `.gain()` retains3; distinct `.offset(7.0)` becomes7. | Runtime gain0 `ok=0`; offset7 `ok=1`. Required positive retained with XFAIL. |
| `ch06_hierarchy/audit_hierarchy_defparam_source_order.va` | Last same-file defparam7 wins over earlier5 and inline2. | Runtime7 `ok=1`. |
| `ch06_hierarchy/audit_hierarchy_override_breaks_dependency.va` | Override a4 and b11; b no longer follows a+1; c=a*b becomes44. | All three checks `ok=1`. |
| `ch06_hierarchy/audit_hierarchy_duplicate_parameter_rejected.va` | Two nonempty assignments to gain must reject; no aliasparam exists. | Exit1 E0908; pinned to observed code, but message falsely alleges aliasparam conflict. |
| `ieee1364/12_hierarchy/audit_hierarchy_unselected_instance_not_top.v` | Leaf mentioned only inside generate-if0 is not a top; only top prints. | Exit1 E1100 unsupported module contents, before runtime. Expected transcript remains `top-only`. |

Analog positives were compiled with `--emit-exe`, root contract and fixture
include paths, then the returned executable was run. Individual `ok` values,
not process exit alone, determine the observation. The first probe mistakenly
used an unsupported analog `//! inherited` directive and failed runner parsing;
that metadata was corrected to an ordinary source comment before behavioral
results were recorded. Digital source inheritance comments are inert metadata.

The initial batch used root CLI SHA256
`28bc440e46b31048097aabb9473f96a542b56332db765c4985d378508209b843`.
Root was subsequently rebuilt during parallel integration, so analog positives
were rerun with before/after binary hash checks for reproducibility; final
confirmation is recorded below. The digital case has no effective XFAIL
mechanism and remains an honest required failure, not an excluded rule.

The final analog rerun reproduced every tabled value, with SHA256
`a659034f48b58fb04762791085af5fb54e48267eeb693a9e04102d23f097ef99`
unchanged before and after that batch. Warning W0650 only selects legal strict
floating-point mode; it is not counted as a rule rejection.

No compiler files were modified. Full suite/name-list comparison and measured
A/C changes remain root integration tasks. No conformance percentage or
exhaustive hierarchy coverage is claimed.

## Second installment: ports, generation and hierarchical names

Read all IEEE1364-2005 §§12.3–12.5, including examples, printed173–193 /
physical203–223. Visual checks covered physical203/204 (Syntax12-3/4),
210 (the entire Table12-1), 212/213 (Syntax12-5 and loop rules), 217
(conditional-name/direct-nesting rules), 220 (external unnamed-block naming),
222 (Syntax12-6), and 223 (Figures12-1/2). Other pages were text-reviewed,
not individually visually inspected. Review date: 2026-09-23.

The current AMS Chapter6 HTML already includes the zero-iteration named-array
rule, conditional direct nesting, and external unnamed-block
naming distinctions. No additional verified HTML defect was established in
this inherited-clause pass. That statement does not make the AMS HTML a
replacement for every inherited digital net/strength or configuration rule.
In particular, the current HTML's port syntax includes `signed`, but does not
itself spell out IEEE12.3.11's cross-boundary signedness rule. IH-023 below
explicitly records that inherited requirement and its executable evidence gap;
the missing inherited detail must not be mistaken for an AMS source omission.

| ID | Source | Requirement and evidence boundary |
|---|---|---|
| IH-016 | 12.3.1–12.3.2 pp173–176 | Ordered implicit ports may use identifiers, selects or concatenations; explicit external naming separates internal expressions from instance connection names. Empty port expressions represent no internal connection. New explicit-concatenation runtime oracle fails before execution. Selected/concatenated implicit ports cannot acquire an invented name for named connections. |
| IH-017 | 12.3.3 pp176–177 | Every internal port identifier needs direction. Type-complete declarations forbid redeclaration; type-incomplete forms permit separate net/reg declarations with identical range. Signedness on either declaration applies to both; default implicit nets are unsigned unless port signed. Minimum port capacity256 remains unmeasured. |
| IH-018 | 12.3.4 p177 | ANSI header completes all declarations, allows only simple identifiers and forbids body redeclarations; styles cannot mix inside a module, but separate modules may differ. Legal controls plus each distinct malformed style remain open. |
| IH-019 | 12.3.5–12.3.6 pp177–178 | Ordered connections use declaration order; named connections use external names, may omit expression but retain parentheses, prohibit duplicate connections and cannot mix with ordered entries within one instance. New explicit-name case adds only one positive obligation. |
| IH-020 | 12.3.7 p178 | IEEE real values require conversion for transfer through ordinary ports. AMS real-valued net extensions must be considered before introducing a blanket real-port rejection. No such invalid oracle was added here. |
| IH-021 | 12.3.8–12.3.9 pp178–179 | Connection direction and continuous-assignment/transfer semantics; receiving side structural-net expression; wrong-direction coercion or required warning; output/inout external connections cannot be variables. Unmerged uwire requires warning. Independent direction, sink-expression, strength and warning controls remain open. |
| IH-022 | 12.3.10–12.3.10.2 pp179–181 | Net dominance/type-resolution matrix, warnings, dominant delay and trireg strength. All table cells were source-inspected, not behaviorally verified. Nine net-type groups and their pairings require actual digital network/strength execution, not analog compile acceptance. |
| IH-023 | 12.3.11 p181 | Each side retains its own signedness. New equal-bit-pattern/opposite-signedness positive produces incorrect signed-child result; no claim to the entire width/conversion matrix. |
| IH-024 | 12.4 pp181–182 | Generate scheme expressions are elaboration constants; generated contents exclude ports/parameters/specify/specparams while permitting localparams. Optional generate/endgenerate region does not change semantics, must match, is module-level and cannot nest. Distinct illegal-content and nonconstant-expression controls remain. |
| IH-025 | 12.4.1 pp182–186 | Declared genvar; same index in initialization/update; initialization RHS cannot reference its own genvar; loop termination, unique indices, no x/z, no nested index reuse. Snapshot implicit integer localparam is hierarchy-addressable in each generated scope; sparse indices are legal. Existing sequential genvar fixture does not test sparse hierarchical snapshots. |
| IH-026 | 12.4.1 p183 | Named loop declares an array even with zero instances; ordinary declaration namespace conflicts are errors. New zero-iteration negative rejects E0230, while a distinct-name legal control executes and verifies no body contribution. This does not cover every collision ordering or namespace. |
| IH-027 | 12.4.2 pp186–190 | At most one conditional arm instantiates. Same name allowed across alternatives of one construct, forbidden against other declarations/constructs even if unselected. Direct conditional nesting without begin/end adds no intermediate scope; loops do not qualify. Nearest else and terminating recursive module generation require separate tests. |
| IH-028 | 12.4.3 pp190–191 | Unnamed-block external names are not HDL hierarchical references. Textual numbering counts named constructs too, restarts by enclosing scope and adds leading zeroes to avoid collisions. Actual VPI enumeration/name lookup is still required. |
| IH-029 | 12.5 pp191–193 | Hierarchical paths identify scopes and objects; escaped names terminate at whitespace; automatic task/function objects are excluded; intermediate array/generate instance selects are mandatory constant legal indices. Root/downward paths and cross-scope access are not closed by parser acceptance. |

### Source subtleties preserved

The source's port-name uniqueness wording coexists with its explicitly legal
`same_input(a,a)` example (printed175–176). A blanket duplicate-header-name
rejection would therefore be an unsafe oracle; this review does not add one.
Table12-1's warning markings and the prose in12.3.10.1/12.3.10.2 must be
kept visible when deriving the connection-resolution matrix, rather than
silently replacing them with a simplified always-external rule.

Existing `generate_implicit_localparam.va` checks sequential elaboration values
inside generated analog statements, not hierarchical sparse-array access.
`generate_direct_nesting.va` checks the selected branch, not all observable
scope paths. `external_genblk_reference_unsupported.va` rejects using the broad
`DiagnosticsReported` marker; that can only establish rejection of this input,
not that the intended unnamed-scope restriction caused it. It supplies no VPI
name-enumeration evidence. Existing bodies and expectations remain unchanged.

### Added fixtures and direct results

| Fixture | Independent expected result | Observed result |
|---|---|---|
| `ieee1364/12_hierarchy/audit_hierarchy_port_signedness.v` | Identical ff bits interpreted by signed child as -1 and unsigned child as255; comparisons to0 print `signed=1 unsigned=0`. | Exit0 prints `signed=0 unsigned=0`: runtime mismatch. |
| `ieee1364/12_hierarchy/audit_hierarchy_explicit_port_concat.v` | External joined input1001 splits a10/b01, output concatenation b,a is0110. | Exit1 E1100: instantiated module has no such port. Required positive, not a rejection test. |
| `ch06_hierarchy/audit_hierarchy_zero_generate_control.va` | Empty loop contributes nothing; sole current contribution2 at V(p)=1 gives I(p)=2. | Exit0, current check got2/want2 `ok=1`. |
| `ch06_hierarchy/audit_hierarchy_zero_generate_collision.va` | Empty array name still collides with ordinary real declaration. | Exit1 E0230 naming the colliding array. |

Digital cases include an explicit1ns/1ps timescale; the initial signedness
probe lacked that harness requirement and was corrected before recording the
runtime result. Each digital positive has its `.expected.txt` transcript;
unsupported positives are not mislabeled as negative tests or given ineffective
digital XFAIL markers. The two new analog cases have a shared legal structural
control, and the negative pins the actual rule-specific diagnostic.

Commands were direct root CLI `--run <digital-file>`, analog `--run --contract
<root>/tools/contract.zig -I <root>/tests/fixtures -I <owned>/tests/fixtures/
ch06_hierarchy <control.va>`, and the same flags with `--check` for the negative.
The root CLI SHA256 was unchanged before/after the digital batch and analog
launch: `dd35079b9e3696f29280ceffdbf9d0082870d87f50d6d0f21dc47d1c56aef854`.
No builds or compiler changes were made. Full fixture name-list comparison and
measured A/C consequences remain parent integration work. These new tests
expose required behavior and strengthen a bounded paired check, not full
hierarchy conformance.

## Root integration boundary

Main read this report on 2026-09-23 and retained its source/evidence register.
The new hierarchy fixtures are now integrated, together with the bounded
empty-association repair in `conformance-empty-parameter-fix.md`. Main reviewed
the patch and independently executed generated analog testbenches, inspecting
their stderr checks: original empty-default, semantic/dependency/multiplicity,
paramset tie, defparam ordering, dependency replacement and zero-loop cases all
pass their observations. The earlier empty-default failure above is historical.
An additional empty-localparam negative from the fix handoff was quarantined
outside conformance intake because its normative prohibition was not established.
Full gates and current digital hierarchy failures remain to be recorded; worker
observations are not silently promoted to measured root results.

The first full root digital run exposes an additional fixture-harness issue:
the two port fixtures use bare `$finish`, which requests default diagnostic
information and can add implementation-dependent text to stdout. Their exact
transcript controls should use `$finish(0)`; the signedness observation itself
is still wrong (`0` instead of `1`) independently of that extra output. This
control correction is queued for the next fixture batch, not blamed on the
compiler or counted as a new language defect.
