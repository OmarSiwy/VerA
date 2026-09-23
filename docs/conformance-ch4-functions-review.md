# Chapter 4 functions and operators: source and evidence review

Reviewed 2026-09-23: complete AMS §§4.3–4.7.3, printed pages 61–96,
physical pages 74–109. Every page was read as extracted text and visually
inspected at 1700-pixel width, including every table, equation, syntax display,
example and Figure 4-3 through Figure 4-14. This continues, not replaces,
`conformance-expressions.md`'s §§4.1–4.2 review.

HTML base SHA-256:
`c452aae6c5868af5538ce84d989bb3ae83b51e3047b9157784190688dca188fe`.
The reviewed source is the supplied `VAMS-LRM-2023.pdf`; the full source hash
and provenance remain in the source inventory. This is not an exhaustive
atomic-rule census or a runtime-conformance closure claim.

## Source fidelity repairs and retained source discrepancies

No additional missing substantive paragraph was established in this range.
The remaining syntax displays had lost the literal-versus-meta distinction.
Restored bold literals in Syntax 4-3 (p.65), Syntax 4-4 (p.89), Syntax 4-5
(pp.92–93), Syntax 4-6 (p.95), and the intervening general-form displays.
In particular, array-selection brackets in Syntax 4-3 are literal; its
optional-argument brackets are not. Every syntax-block text remains unchanged
when parsed with HTMLParser (entities decoded during parsing, before text
collection). The initial strip-tags-then-decode check was insufficient: it
missed entity terminators incorrectly wrapped as grammar semicolons in the
Laplace/Z syntax displays. Those entities are now restored intact. The new
`tools/test_lrm_ch4_syntax.py` compares all 26 parsed displays against the
pre-markup root baseline and checks all docs HTML for split entities, with
an explicit regression proving the former check's failure mode. All three
tests pass. Fixed HTML SHA-256 is
`4c781e81f1bcac7c952862ff992daa15c66753bef35f28dbe4e10452d71a2d5c`.
Pre-4.3 bytes and all existing figure blocks remain unchanged.
No shared figure assets or extractor were modified.

| ID | Clause / printed page | Editorial annotation, not a silent normative rewrite |
|---|---|---|
| FUNC-SOURCE-001 | 4.3.1 / 62 | Source abs equivalence lacks `?`. Preserved; neighboring min/max equivalents are well-formed. |
| FUNC-SOURCE-002 | 4.5.5 / 68–69 | Table 4-19's omitted-IC wording is simulator-determined, whereas prose specifies zero; concluding `[0,1]` conflicts with the explicit strict upper bound. Both forms retained. |
| FUNC-SOURCE-003 | 4.5.7 / 72 | Figure 4-4 has a nonzero initial input, while prose says `input(max(t-td,0))` returns zero. Formula returns input(0), not necessarily zero. Both original forms retained. |
| FUNC-SOURCE-004 | 4.5.12.1–4 / 83–84 | Z-filter coefficient prose says powers of s despite displayed negative powers of z. Zero-root prose specifies z and compares against `1-z/r`, unlike displayed `1-z^-1*r`. Retained and flagged before deriving zero-root boundary oracles. |
| FUNC-SOURCE-005 | 4.5, 4.5.14 / 65,85–86 | Syntax4-3 calls transition's final argument constant, Table4-20 calls time_tol dynamic. Z rows print t, earlier description uses tau. Preserved with note. Sampling paragraph must not be turned into blanket rejection. |
| FUNC-SOURCE-006 | 4.7.3 / 96 | Explanation says arrayinit although example defines/calls arrayadd. Retained with note. |

Other source quirks remain visible: §4.5.8 refers to “Figure 4” before
Figures 4-10/11, and Table4-22 labels NOISE subcolumns “OP AC”. Neither
was silently corrected. Source defects do not authorize inventing an oracle.

## Rule-group worklist

Each row below requires finer partitioning and recorded tests before closure.
Fixture names refer to `tests/fixtures/ch04_expressions`; examples listed as
existing evidence were inspected selectively, not all executed in this review.

| ID | Clause | Independently accountable obligations and evidence boundary |
|---|---|---|
| FUNC-001 | 4.3–4.3.1 | Both syntax families; numeric operand types; integer preservation for min/max/abs; mixed-real conversion; each Table4-14 function/domain. `10`, `11`, `65`–`85` contain value cases, but integer-valued CHECKI does not establish expression type. New quotient fixtures distinguish it. |
| FUNC-002 | 4.3.1 | Tie derivatives follow the specified conditional branch. Equal value tests in `82`/`83` cannot discriminate branch selection. New ddx fixture exposes wrong tie behavior. ln1p/expm1 small-argument accuracy text says “can”, not a quantified universal error bound. |
| FUNC-003 | 4.3.2 | Each Table4-15 mapping, radians, domain error, atan2 argument order and (0,0)=0; both function spellings, constant/runtime invalid values and legal boundaries. Existing `113` and `a01_08` are leads; one rejected function does not establish the family. IEEE17.11 review is a separate inherited boundary. |
| FUNC-004 | 4.4 | Branch/net/port and generic access, orientation/ground, same-terminal errors, correct discipline, scalar/genvar indexing, exactly one own-module port, no port access on contribution LHS. Existing `13`, `13b`, `34`, `86`, `87`, `110`, `115`, `140`, `141` partition some cases; aliases and hierarchical elaboration need independent observations. |
| FUNC-005 | 4.5–4.5.2 | Stateful evaluation; permitted array representations; per-equation tolerance association and contextual versus explicit tolerance. `145`'s DC value cannot establish that changing tolerance affects host convergence correctly. Array acceptance alone cannot establish shape/argument capture. |
| FUNC-006 | 4.5.3 | ddt transient derivative, DC zero, optional explicit/nature tolerance applied to output. Time-grid numerical agreement is not adaptive-error control or rollback verification. |
| FUNC-007 | 4.5.4 | idt initial point/DC/IC, specified IC, absent-IC feedback, assert-held reset, release at last assert, input tolerance. `15`, `16`, `a04_07` are distinct leads. Undefined output without required feedback is not a fixed zero oracle. |
| FUNC-008 | 4.5.5 | Positive dynamic modulus; omitted modulus gives unbounded integration; dynamic offset, default offset, strict upper interval, integral congruence at all times, tolerance and IC source discrepancy. `17`, `126`, `a04_08` are not all cross-products. |
| FUNC-009 | 4.5.6 | Symbolic partials holding other unknowns fixed; potential scalar probe versus branch-flow unknown; explicit independence gives zero; internal implicit unknowns unavailable; no tolerance argument. `18`, `131`, `132`, `147`, `158` identify distinct obligations. New tie fixture tests a derivative boundary, not a host Newton solution. |
| FUNC-010 | 4.5.7 | Positive td, maxdelay cap, frozen td without maxdelay, dynamic td with maxdelay, DC passthrough, AC phase, transport history/linear interpolation/clamped initial query. Existing `audit_absdelay_*` and `a04_03`–`06` cover different pieces. New dynamic-maxdelay fixture targets the separate §4.5.14 capture rule. |
| FUNC-011 | 4.5.8 | Piecewise-linear transitions; all optional defaults/sign restrictions; explicit versus default corner scheduling; DC pass and AC approximation; snapshot controls on input changes; pending-event order/cancellation; four interruption directions and repeated interruptions. `a04_01`/`02` do not establish the complete queue and interruption matrix. Fixed declared time points cannot prove solver-chosen corners. |
| FUNC-012 | 4.5.9 | Both rate signs; missing negative rate symmetry; no rates passes through; below-limit tracking; dynamic rates; DC passthrough; small-signal gain one versus zero while slewing. `21`, `129`, `a04_09` require separate runtime interpretation. |
| FUNC-013 | 4.5.10 | Integer direction -1/0/+1, rising/falling/either histories, interpolation, any negative value before first crossing, no timestep control. Do not require exactly -1 or import cross's timestep guarantees. `22`, `130`, `146` are bounded cases. |
| FUNC-014 | 4.5.11.1–4 | Four rational transfer forms, coefficient order, real/imaginary root pairs, conjugates, origin special cases, null zeros, parameter/literal vectors and tolerances. `23`, `35`, `133`, `136`, `151`–`154` use mainly DC; H(0) cannot distinguish transfer functions that share DC gain. New zero/denominator unpaired-zero negative separates `133`'s pole case. |
| FUNC-015 | 4.5.12.1–4 | Four discrete transfer forms plus positive sampling period, optional transition/t0 defaults, initial and later sampling, corner control, no direct branch assignment with zero transition, complex roots, arrays/null zeros. `24`, `134`, `135`, `155`, `156`, `a04_10` need per-form mapping. Zero-root source contradiction remains unresolved. |
| FUNC-016 | 4.5.13 | limexp iteration history limits change and prevents convergence while limiting; converged value equals exp. `25` samples below its described knee; agreement there cannot establish the convergence veto or high-argument equivalence. Limiting threshold itself is not fixed by this clause. |
| FUNC-017 | 4.5.14 | Every Table4-20 argument slot independently classified; dynamic values supplied to constant slots sampled at analysis start, later changes ignored; new analysis recaptures. Existing COVERAGE row suggesting dynamic-slot rejection contradicts final paragraph. New maxdelay capture fixture isolates one slot and exposes E0515. |
| FUNC-018 | 4.5.15 | Dynamic if/case/conditional prohibition versus constant guard; event and repeat/while/runtime-for bans versus genvar; analog-only contexts; null exceptions; no pre-zero history. ddx's stated state exception must not erase independent user-function access/filter bans in4.7.1. Existing `36`, `88`–`94`, `119`–`122` are useful isolated restrictions, not every operator/context combination. |
| FUNC-019 | 4.6–4.6.1 | analysis is OR over strings, unsupported names do not match, required names for comparable analyses, full Table4-22 phase matrix. A DC or tran fixture alone cannot establish pre-AC/noise/IC/nodeset phases. Simulator extensions are not rejected just because absent from the table. |
| FUNC-020 | 4.6.2 | DC sweep preserves variable end values to next point, independent analyses reinitialize, digital-assigned integers use x, nodesets only permitted first-point phase. Requires a host lifecycle spanning points and independent sweeps, not multiple unrelated DC runs. |
| FUNC-021 | 4.6.3 | ac_stim defaults, matched-name activation, radians/magnitude/phase, large-signal and mismatched-analysis zero. `37`'s DC zero does not establish complex stimulus behavior; `a06_*` host leads need their own active-phase results. |
| FUNC-022 | 4.6.4.1–2 | White/flicker PSD, flicker normalization at1Hz/exponent, zero outside noise, name grouping scoped to instance. Same names combine reports, not independent random sources into correlated ones. |
| FUNC-023 | 4.6.4.3–4 | Array/file forms, constant filename, whitespace/newlines/comments/numbers, sorting, uniqueness, interpolation exact knots/interiors, endpoint clamping, log-log formula and labels. `183` rejects duplicate frequencies; `181`/`182` topology is not frequency-dependent PSD. a06 noisetable netlists are leads, not certified by this review. |
| FUNC-024 | 4.6.4.5–6 | Diode composition, independent source calls, shared source perfect correlation, partially shared source covariance, reuse across branches. Scalar deterministic zero in non-noise analysis proves none of covariance/topology/PSD. |
| FUNC-025 | 4.7–4.7.1 | Scope and return type/default, required argument/type/direction, allowed locals/module parameters and shadowing, banned access/filter/contribution/event/named block. `95`–`105`, `142`, `157_function_local_parameter_shadow` partition some cases; inherited digital functions remain separately required. |
| FUNC-026 | 4.7.2.1–2 | Numeric/string default return, reset on each invocation, last assignment, explicit return overrides, scalar-only and correct expression type. `40` distinguishes override and numeric default but not complete string/per-call behavior. |
| FUNC-027 | 4.7.2.3–4 | Output initialization/read/write/copy-out versus inout copy-in/preserve-unassigned; numeric/string/array/pattern forms, equivalent sizes and assignable actuals. `124` distinguishes unassigned scalar directions; `108`/`109` cover arrays. Same actual in different output/inout positions is undefined, not a deterministic alias-order test. |
| FUNC-028 | 4.7.3 | Declaration-order association versus unspecified argument evaluation order; direct/indirect recursion ban; analog context and nested function calls; legal expressions versus variable-only outputs. `104`–`107`, `138`, `139` are leads. No left-to-right side-effect oracle is permitted. |

## New executable evidence

Existing root binary SHA-256:
`306285380ce47f95c1a8dba3db2378b2e9396bbb5e8a558c4887dee516535a75`.
Targeted execution uses `--emit-exe --contract` with root contract and fixture
include directory plus owned fixture directory. These generated executables
exit zero even when observations print `ok=0`; the observation values, not
that process status alone, determine the result.

| Fixture | Derived oracle / observed result |
|---|---|
| `audit_minmax_tie_derivatives.va` | At equal independent node potentials, source min/max condition is false, selecting second operand. Required partials first=0, second=1; initially observed first=1, second=0 for both functions. The testbench Dual used non-strict comparisons. Production derivative behavior also depended on the external host; codegen's embedded P helper is value-only, not a dual implementation. See the superseding repair checkpoint below. |
| `audit_math_result_type_division.va` | Integer result3 / integer2 must be1; mixed/real result3 / integer2 must be1.5. All six traditional/mixed-real observations pass. These observe type before integer assignment could hide a real result. |
| `audit_system_math_result_type_division.va` | Same type rule applies to $min/$max/$abs style. All three integer quotients are observed1.5 instead of1. XFAIL. Traditional neighbors remain separate passing evidence. |
| `audit_absdelay_dynamic_maxdelay_sampled.va` | maxdelay starts1ns then changes4ns; captured1ns caps td2ns throughout analysis. Input t/ns gives0,0,1,2,3 at0..4ns. Compilation instead rejects E0515. XFAIL; no waveform was executed. No compile rejection is relabeled as valid behavior. |
| `audit_laplace_zd_unpaired_zero_rejected.va` | Sole complex zero -1+j lacks -1-j. Check/emit-exe exits1 with generated compile-error refusal. Expected substring `no conjugate partner` comes from cg_filters' root-validation message; torture.failureContains examines generated code, unlike CLI's shortened refusal. Full harness confirmation remains pending. |

These are isolated additions; existing fixture expectations were not weakened
and existing XFAILs were not removed. No full build or suite was run here.
Main must measure A/C and compare exact FAIL/XFAIL names after integration.
This bounded source/evidence work refines the AMS rule inventory and evidence
supporting A/C. Inherited IEEE math and measure B are separately reviewed; this
does not close all B obligations or change architecture measure D. No exhaustive denominator
or conformance percentage is asserted.

Main integration checkpoint (2026-09-23): read this full report and final HTML
diff, independently checked the math typing/tie and constant-slot sampling
passages, and integrated the syntax/editorial repairs. The parsed-syntax
regression passes against both the original root HTML and the corrected HTML;
the source-document suite passes. The rejected intermediate entity markup was
never integrated into the root tree.

Math typing and tie-derivative fixtures are now implemented and root-verified;
see `conformance-system-math-fix.md` and
`conformance-minmax-derivative-fix.md`. Their earlier failing observations above
are historical, not current dispositions. The traditional quotient fixture is
now integrated and all six observations independently pass at root. The
unpaired-zero fixture is integrated with a new same-form conjugate-zero legal
neighbor, `audit_laplace_zd_conjugate_zeros.va`: its DC transfer value is derived
in the header. Both pass the focused strict harness, exit zero.

The dynamic-maxdelay fixture is integrated with five required observations and
remains an implementation gap. Root discovered that its E0515 diagnostics had
incorrectly accompanied a successful `--check` status. The reporting repair in
`conformance-codegen-status-fix.md` restores failure status without claiming
the required analog behavior works. Full-batch measurements remain pending.
