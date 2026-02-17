# Clause audit — Q01 complete requirement inventory

Owner: Q01 in [the implementation plan](../../ARPice/docs/verilog-ams-conformance-plan.md).
Status: **open**. This document is the inventory, not the result.

This is an audit artifact. It records what was checked, against what, and with
what evidence. It does not change the compiler and it does not close anything.
Where it disagrees with another document in this repository, the disagreement is
written down here with a `file:line` citation so the other document can be fixed
rather than argued with.

**Nothing in this file is a conformance percentage.** Fixture counts are counts
of files. 1558 fixtures behaving as they say they do is a statement about 1558
files, 477 of which assert that the compiler *refuses* something.

---

## Provenance — read this before quoting any number below

Incremental source/evidence review, 2026-09-23: the new inherited task/math,
scope and VCD reports linked from `CONFORMANCE.md` supersede affected historical
claims. Rows17.7-01/-02 and17.11-01 are corrected below; the old aggregate
status tallies are historical and have **not** been recomputed as an atomic
measure B. In particular, a previously verified label contradicted by a new
source-derived failure cannot remain a current closure claim. No new B total
is inferred from the handful of corrected rows.

This document was written **2026-09-16** against a 1301-fixture tree, deleted in
`2cc1c08`, and restored and partly re-derived at **2026-09-21** for release
v0.0.2 (`ROADMAP.md §4`). **It is two documents in one and the sections are
dated separately.**

> **The re-derivation read a moving tree, and four citations were wrong because
> of it.** The rows below were re-read while seven commits were landing on
> `ddt-capform` between tag `v0.0.1` (`2e7cfaa`, 09:19) and `a99a37f` (09:50) —
> a parser change of +142 lines, a merge, and a 9-line change to
> `src/sim/digital.zig`, the file most of §4.1 and §4.3 cite. The baseline
> FAIL/XFAIL name list was taken at `f692b3b` and the verifying one at
> `a99a37f`; they are **identical**, 35 and 28, and this release changed no
> `.zig`, `.va` or `.vh` file, so measure A is untouched either way.
>
> Every line citation was then re-checked against `a99a37f`. **Four had
> drifted** and are corrected here: `lib/frontend/parser.zig:4812` → `:5043`,
> `src/sim/digital.zig:3477` → `:3478`, `:3414` → `:3421`, `:3515` → `:3522`.
> The rest were spot-checked and land. `ROADMAP.md` Appendix A item 8 already
> warns that line citations drift and concludes "cite sections and symbols, not
> line numbers" — this document still cites lines, because a verdict needs the
> exact site, and that is the maintenance cost of doing so.
>
> This is `AGENTS.md §8`'s first rule — **own worktree per agent** — and it was
> not followed: five readers ran in the shared checkout while it was being
> committed to. The findings survived because this release changes no code and
> the drift was mechanical, but the *next* re-derivation should take a worktree.

| Section | State | As of |
|---|---|---|
| §1 measured baseline | **re-measured at HEAD** | 2026-09-21 |
| §2 classification vocabulary | unchanged; definitions, not measurements | 2026-09-16 |
| §3 `COVERAGE.md` reconciliation | **NOT re-derived.** Its counts are against 1301 fixtures and 22 `COVERAGE.md` files totalling 3694 lines; the tree now has 1558 and 4174. Treat every count in §3 as stale | 2026-09-16 |
| §4 obligation inventory | **fully re-derived at HEAD**, row by row | 2026-09-21 |
| §5 separation of obligation kinds | §5.4 and §5.6 corrected; §5.1–§5.3, §5.5 unchanged | mixed, marked per table |
| §6 rejection-fixture audit | **NOT re-derived.** Its 452-of-1301 is now 477-of-1558 | 2026-09-16 |
| §7 tally and worklist | **fully re-derived at HEAD** | 2026-09-21 |

**The §4 re-derivation changed a majority of the rows**, because the tree moved
14 795 lines between the two dates. Two structural facts drive almost all of it:

1. **The compiler moved `src/` → `lib/`.** Every `src/ir/lower.zig`,
   `src/backend/*.zig` and `src/diag_code.zig` citation in the 2026-09-16 text
   was wrong in path *and* in line. The runtime did not move: `src/sim/`,
   `src/vpi/` and `src/main.zig` are still `src/`.
2. **`src/sim/digital.zig` grew by 2766 lines.** The 2026-09-16 claim that "the
   whole digital dispatcher is three names plus two casts" is **false at HEAD**,
   and it was load-bearing for roughly thirty `missing (digital)` verdicts. The
   task table at `src/sim/digital.zig:596-617` now carries the full
   `$display`/`$write`/`$strobe`/`$monitor` family in all four radix spellings,
   `$monitoron`/`$monitoroff`, `$timeformat`, `$readmemb`/`$readmemh` and
   `$finish`; `$time`/`$stime`/`$clog2` are at `:460-462` and the
   `$signed`/`$unsigned` casts at `:437`.

### The deletion that this restoration uncovered

`2cc1c08` is titled *"docs: the 2023 LRM replaces 2.4, and the stale prose goes
with it"*. It added one file — `docs/VAMS-LRM-2023.pdf` — and deleted
**thirty-nine**, of which **fourteen are tests and one is a 295-line tool**:

```
tests/rng_reference.c          tests/rng_reference.zig      tests/rng_domains.zig
tests/rng_effects.va           tests/rng_effects_host.zig   tests/rng_default_domain.va
tests/literal_nul.va           tests/literal_nul.vh         tests/literal_nul_host.zig
tests/vpi_app.c                tests/vpi_design.va          tests/vpi_host.zig
tests/limiter_host.zig         tests/table_snapshot_host.zig
tools/source_guards.zig
```

That commit re-homed nothing — `git show --diff-filter=A 2cc1c08` returns the
PDF alone. **Three of the fifteen have since been restored**, by `6f2e1c5`
(2026-09-20, before `v0.0.1`), whose subject names the cause exactly: *"tests:
restore the VPI acceptance test a docs commit deleted, and renumber to 2023"*.
`tests/vpi_app.c`, `tests/vpi_design.va` and `tests/vpi_host.zig` are back and
`build.zig:206` links them again.

**Twelve are still gone:** the six RNG files, the three `literal_nul` files,
`limiter_host.zig`, `table_snapshot_host.zig` and `tools/source_guards.zig`.
With them went two build steps this document cited as evidence —
**`zig build test-rng-reference` and `zig build test-literal-output` no longer
exist** — and that is the whole of the differential C oracle for §17.9.3 and the
whole of the byte-level NUL/octal check for §17.1.1.1.

That one of the fifteen was noticed and the other twelve were not is the point,
not a mitigation. The VPI three were noticed because `build.zig` still referenced
them and the build broke; the twelve took their build steps down with them, so
nothing broke and nothing complained. **A deleted test that removes its own gate
is silent by construction.**

The five *fixtures* deleted alongside them were a different case and were deleted
*correctly* — `08_new_receiver_count.va`, `061_rtoi_analog_rejected.va` and
`062_itor_analog_rejected.va` were authored from a 2.4-contaminated HTML
transcription, which is exactly what the commit set out to remove.

This is the failure mode `AGENTS.md §8` already warns about — *"a docs commit
once swept in three unrelated test-file deletions and nothing noticed for a
session"* — recurring at five times the size, in the same commit that deleted the
audit that would have caught it. **No release on the ladder currently owns
restoring it.** Recorded in §7.3 item 10; it is not v0.0.2 work, which changes no
code.

---

## 0. How to use this document

Work it in this order; each part is independently completable.

| Part | Question it answers | State |
|---|---|---|
| [1](#1-measured-baseline) | What was actually run, and what did it say? | done, dated below |
| [2](#2-classification-vocabulary) | What do the seven verdicts mean here? | done |
| [3](#3-coveragemd-reconciliation) | Which `COVERAGE.md` claims are stale or contradicted? | done for counts and for every claim reachable from the source; row-level clause re-reads remain |
| [4](#4-inherited-ieee-1364-1718-obligation-inventory) | The inherited system-task and VCD obligations, one row each | drafted; needs an IEEE 1364-2005 copy to confirm subclause numbering |
| [5](#5-separation-of-obligation-kinds) | Resource limit vs unspecified vs implementation-defined vs optional vs mandatory | done for the cases the source actually contains |
| [6](#6-rejection-fixture-audit) | Which rejections are "illegal source" and which are "legal but unsupported"? | done at the diagnostic level; per-fixture re-reads listed |
| [7](#7-tally-and-worklist) | Counts by classification, and what to do next | done |

---

## 1. Measured baseline

Re-measured on **2026-09-21** at `a99a37f`; every figure below reproduces unchanged at `05ae554`, where this text lands. **Not at tag `v0.0.1` (`2e7cfaa`)** — see the provenance block. The step is
`benchmark`; **`zig build torture` no longer exists** and every citation of it in
this document has been corrected.

```
$ zig build benchmark -- --strict
pass    fail    unasserted      xfail
1495    35      0               28                               (exit 1)

$ zig build benchmark -- --coverage
529 of 612 LRM clauses cited, by 1488 of 1558 fixtures
  196 tested both ways · 257 accepted only · 76 refused only · 83 uncited
```

Measured over the fixture tree, not quoted from any document. The 2026-09-16
column is kept so the movement is legible; **the 2026-09-21 column is the live
one.**

| Quantity | 2026-09-16 | **2026-09-21** |
|---|---|---|
| `.va` fixtures | 1301 | **1558** |
| carrying `//! reject` | 452 (34.7%) | **477 (30.6%)** |
| carrying `//! xfail` | 0 | **28** |
| carrying `//! lrm` | 1232 | **1488** |
| AMS LRM clauses the harness knows about | 611 | **612** |
| clauses with a positive *and* a negative fixture | 148 | **196** |
| clauses whose only fixture is a rejection | 99 | **76** |
| clauses no fixture names | 156 | **83** |

**`--strict` now exits 1, and that is not a regression.** On 2026-09-16 the suite
reported `1301/1301` because no fixture carried `//! xfail` — the marker did not
exist. 28 do now, and `--strict` exits 0 only when FAIL, unasserted *and* XFAIL
are all 0. The 63 rows behind that exit code are named in `CHANGELOG.md`'s
v0.0.1 entry and are `ROADMAP.md`'s measure A, not this document's subject.

**These clause numbers are measure C and this document no longer owns them.**
`tools/conformance.sh` writes them into `CHANGELOG.md` and `publish.yaml`
re-measures them on a clean runner. §7.2 below is kept only as the cross-check it
always was. This document owns **measure B** — §7.1 — which has no command.

### 1.1 Three facts about that baseline that change what it means

**a. `zig build test` does not run the fixture suite.** Still true at HEAD, with
new line numbers and a new step name. `build.zig:149` puts the fixture walk
behind the **`benchmark`** step (the `torture` step this document was written
against is gone; `build.zig:14` now says "THERE IS ONE SUITE STEP, `benchmark`").
`build.zig:141` adds only the *suite runner's own unit tests* to `test`. Any
"N fixtures pass" claim sourced from a `zig build test` summary is unsupported —
`ROADMAP.md` Appendix A item 9 settles this. **Measure A is always
`zig build benchmark -- --strict`.**

**b. Refusal is 30.6% of the suite.** 477 of 1558 fixtures assert that the
compiler emits a diagnostic. Per the plan's completion rules, a rejection
fixture must not count as positive coverage. Section 6 separates the ones that
pin an LRM prohibition from the ones that pin VerA's ceiling — **on the 2026-09-16
tree; §6 was not re-derived.** The share fell from 34.7% because the 257 fixtures
added since are mostly positive.

**b′. There is a second fixture population this document kept missing.**
On 2026-09-21 `collect` walked `*.va` **only**, so the 81 `.v` digital fixtures,
26 `.c` VPI fixtures and 7 `.sp` decks were outside measure A entirely.
**Release v0.0.3 changed that and the numbers here move with it:**

| Population | Then | Now |
|---|---|---|
| `.va` | 1558, measure A | 1558 |
| `.v` | 81, none in measure A | **12 joined measure A** (denominator **1570**); 66 remain `test-devices`'; 3 are VPI support material |
| `.c` | 26, read by nothing | **`zig build test-vpi-fixtures`** — 13/26 compile |
| `.sp` | 7, read by nothing | **`zig build test-spice`** — 7/7 paired and compiling |

A `.v` joins measure A when it carries a directive and has no `.expected.txt`;
it stays `test-devices`' when it has one (`tests/bench.zig`'s `digitalCases`).
`test-devices` **reports 48/66 and still FAILs** — `ROADMAP.md` Appendix A item 5
records 47/66, which was measured before the port-net-type fix landed.

Several §4 rows below are carried by `tests/fixtures/digital/d09_*.v` evidence
that is executable and byte-exact against committed transcripts but sits in the
`test-devices` register rather than measure A. Where that is so, the row says
which harness proves it.

**c. The coverage tool is structurally blind to the inherited clauses.** It
walks `docs/ch*.html` and `docs/annex-*.html`, which are the AMS LRM. IEEE 1364
Clause 17 and Clause 18 are not in that set, so they can never appear in the
"uncited" list — they are outside the denominator entirely. This is exactly the
blind spot D09 names, and it is why Section 4 exists.

The normative hook that makes them in scope, twice over:

- **§2.8.3** (`docs/ch2-lexical.html`): "The system tasks and functions described
  in Clause 17 and Clause 18 of IEEE Std 1364 Verilog **are part of this
  standard**."
- **§9.1** (`docs/ch9-system.html`): "Verilog-AMS HDL is a superset of IEEE Std
  1364 Verilog and hence **all the system tasks in IEEE Std 1364 Verilog are
  supported**."

Neither sentence is conditioned on the analog subset. Annex C (§C.11) narrows
the *Verilog-A* subset to "Clause 9 tasks applicable in the analog context"; it
does not narrow this target, and Annex G is historical change history.

---

## 2. Classification vocabulary

The seven verdicts required by Q01, defined so two reviewers reach the same one.

| Verdict | Definition |
|---|---|
| **missing** | No code path. A conforming input is refused, ignored, or answered with a fabricated value. |
| **partial** | Some of the clause's behavior exists and some does not, and the boundary is nameable. |
| **implemented-without-evidence** | Code exists and reads correct, but no executable test would fail if it were wrong. A compile-time acceptance is not evidence of runtime behavior. |
| **verified** | An executable test pins an observable the clause fixes, and the test was demonstrated to fail when the behavior is broken. |
| **optional** | The LRM says *may*. Absence is conforming. |
| **implementation-defined** | The LRM requires a choice and requires the choice be documented. Needs a document *and* a test, not just a value. |
| **non-normative** | Overview prose, notes, examples, informative annexes. Nothing to implement. |

Two further kinds the plan requires be kept separate from the above, because
they are not verdicts on a clause but properties of this implementation:

| Kind | Definition |
|---|---|
| **resource limit** | A bound this implementation sets (buffer size, channel count). Must be stated and must fail loudly, not silently. |
| **unspecified** | The LRM fixes no outcome. A test may not assert one arbitrary outcome as the required one. |

A rule of application, used throughout: **"the compiler refuses it" is never
`verified`.** It is `missing` if the construct is legal, or `verified` on the
*prohibition* if the construct is illegal — and those two are different rows.

---

## 3. `COVERAGE.md` reconciliation

> **NOT re-derived at HEAD — this section is 2026-09-16.** It counts 22
> `COVERAGE.md` files totalling 3694 lines against 1301 fixtures; the tree now
> has 22 files totalling **4174** lines against **1558** fixtures. Every count
> below is stale, and the §7.3 worklist items that act on it (1–4) are re-scoped
> accordingly. The *claims* it settles about compiler behaviour were checked
> against the source and mostly still hold; the §4 re-derivation found four that
> no longer do and they are named in §7.3 item 12.

22 `COVERAGE.md` files, 3694 lines. Every numeric inventory claim was recounted
against the directory. Every claim about compiler behavior that the source can
settle was checked against the source.

### 3.1 Stale inventory counts

Measured with `ls *.va | wc -l` and `grep -l '^//! reject' *.va | wc -l`.

| File | Claim | Measured | Verdict |
|---|---|---|---|
| `ch01_intro/COVERAGE.md:13` | "25 `.va` files: 8 reject, 17 run" | 27 files, 8 reject, 19 run | **stale** — `lrm_1_2.va`, `lrm_1_3.va` are unmentioned anywhere in the file |
| `ch02_lexical/COVERAGE.md:9` | "Sixty-three `.va` files. Thirty-four carry a `//! reject` arm, twenty-nine run" | 64 files, 35 reject, 29 run | **stale** — and 21 fixtures, all rejections, are named nowhere in the file (list below) |
| `ch04_expressions/COVERAGE.md:4` | "149 `.va` fixtures, of which 52 are `//! reject`, 97 run and assert" | 172 files, 53 reject, 119 run | **badly stale** — 24 fixtures unmentioned, including whole feature groups (below) |
| `ch05_analog_behavior/COVERAGE.md:4` | "123 `.va` fixtures, of which 33 are `//! reject`, 90 run and assert" | 124 files, 33 reject, 91 run | **stale** — 7 fixtures unmentioned |
| `annex_e_spice/COVERAGE.md:274` | "Forty-one files, all mapped above" | 43 files | **stale** — `spice_digit_names.va` and `spice_keyword_names.va` are absent from the fixture-name audit list (both *are* named in table rows above it) |
| `annex_e_spice/COVERAGE.md:290-292` | "Thirty-two fixtures carry `//! bias` … six `//! solve` … **None carries `//! temp`**" | 34 bias, 8 solve, **1 temp** (`spice_name_shadow.va`) | **stale, and the `temp` claim is used as an argument** — the sentence justifies the `resistor` tc1/tc2 gap by the absence of `//! temp`, and a `//! temp` fixture exists |

All 17 other `COVERAGE.md` inventory claims recount correctly:
`annex_a` 44/14/30, `annex_b` 27/24/3, `annex_c` 31/22/9, `annex_d` 27/6/21,
`annex_f` 11/4/7, `annex_g` 23/14/9, `annex_h` 9/0/9, `ch03` 133/58/75,
`ch06` 97/31/66, `ch07` 50/29/21, `ch08` 30/10/20, `ch09` 207/53/154,
`ch10` 50, `ch11` 27/2/25, `ch12` 38/35/3, `combined` 22/0/22,
`exhaustive` 45/0/45.

`annex_e_spice/COVERAGE.md:16-18` pre-emptively warns "Counts elsewhere in this
file may still be stale; the ROWS say what is true." That warning is accurate
and should be read as a defect, not as a disclaimer that discharges one.

#### Fixtures named nowhere in their chapter's `COVERAGE.md`

`ch04_expressions` (24) — the significant ones are whole groups, not strays:

- noise topology: `148_white_noise_topology.va`, `149_flicker_noise_topology.va`,
  `150_noise_source_through_variable.va`, `160_noise_kinds_in_ternary.va`,
  `161_partially_correlated_noise.va`, `lrm_4_6_4_3.va`, `lrm_4_6_4_5.va`
- Laplace / Z-transform: `151_laplace_zd_dc_gain.va`, `152_laplace_np_dc_gain.va`,
  `153_laplace_nd_dc_gain.va`, `154_laplace_zp_lrm_example.va`,
  `155_zi_dc_gains.va`, `156_zi_sampling_period.va`
- numeric edges: `157_punctured_divisor_accepted.va`, `157_shift_negative_count.va`,
  `158_ddx_unprobed_flow_is_zero.va`, `158_pow_even_exponent_accepted.va`,
  `158_pow_negative_base_runtime_exponent.va`,
  `159_hypot_fmod_extreme_magnitude.va`, `180_pow_parameter_derivative.va`
- other: `120_operator_in_case_rejected.va`, `157_function_local_parameter_shadow.va`,
  `159_operator_missing_mandatory_argument.va`, `lrm_4_7_2.va`

Direction of the error matters: for §4.6.4 and §4.5.11/§4.5.12 the doc
**understates** — evidence exists that the doc does not credit. For the header
count it **overstates** internal consistency. Both are defects, but the fix is
different: the first is a table edit, the second is a recount.

`ch02_lexical` (21), all rejection fixtures:
`05_xz_integer_rejected`, `14_real_leading_dot_rejected`,
`15_real_trailing_dot_rejected`, `16_real_dot_exponent_rejected`,
`24_question_digit_rejected`, `25_base_sign_between_base_and_digits_rejected`,
`41_base_apostrophe_whitespace_rejected`, `42_decimal_xz_multidigit_rejected`,
`43_real_leading_dot_exponent_rejected`, `44_real_leading_dot_scale_rejected`,
`45_real_trailing_dot_scale_rejected`, `46_scale_factor_whitespace_rejected`,
`49_illegal_base_letter_rejected`, `50_hex_without_base_rejected`,
`56_scale_factor_alphabet_rejected`, `57_real_underscore_after_dot_rejected`,
`58_exponent_and_scale_factor_rejected`, `61_long_digits_truncate`,
`62_wide_literal_backend_boundary`, `63_unknown_decimal_backend_boundary`,
`64_leading_zero_size_rejected`.
(Several *are* referenced by number only — "`25` (sign between base and digits)"
at `ch02_lexical/COVERAGE.md:28` — which is why they do not grep. That is a
readability defect rather than a coverage one, but it defeats the mechanical
cross-check the file elsewhere relies on.)

`ch05_analog_behavior` (7): `absdelay_short_delay.va`,
`event_cross_param_direction.va`, `inductor_dc_short.va`,
`jump_in_function_binds_function_loop.va`,
`jump_in_function_outside_loop_invalid.va`, `lrm_5_6_8_2.va`,
`static_switch_elision.va`.

### 3.2 Claims contradicted by the source or by the suite

| Claim | Where | What the evidence says |
|---|---|---|
| "`06` does not compile" | `ch09_system_tasks/COVERAGE.md:37` (row `s9.4.4`) | `06_display_formats.va` is not a `//! reject` fixture, carries 4 `CHECK` macros, and is inside the 1301/1301 strict pass. It compiles and asserts. The same `COVERAGE.md` says so twice, at rows `s9.4.3` and `s9.5.3`. **Self-contradictory; the `s9.4.4` half is stale.** |
| `s9.4.1` credits `04_display_monitor.va` for the `$monitor` row without qualification | `ch09_system_tasks/COVERAGE.md:34` | §9.4.1 requires `$monitor` to display **only when an argument changed value compared with the last accepted step**. `src/backend/codegen.zig:5562-5572` puts `$monitor` in the same `void_tasks` list as `$display`, and `src/backend/codegen.zig:2863-2872` emits every display task into the per-accepted-point display unit unconditionally. There is no change-detection state anywhere in `src/backend/`. The fixture pins an argument value, which a `$display` would also satisfy. **`$monitor` semantics are `missing`; the row reads as covered.** |
| `s9.4.1` credits `05_display_debug.va` in the same list | `ch09_system_tasks/COVERAGE.md:34` | §9.4.1: "`$debug` … displays its arguments **for each iteration of the analog solver**." `$debug` is in the same `void_tasks` list and the same accepted-point unit. Its defining difference from `$strobe` is not implemented. The `s9.4.6` row is honest about this ("no fixture"); the `s9.4.1` row is not. |
| ch07 `s7-3-2` credits `case_equality.va` (E0323) as "the strongest coverage in the chapter" | `ch07_mixed_signal/COVERAGE.md:49` | §7.3.2 (`docs/ch7-mixed-signal.html`) lists the case equality operator `===`, the case inequality operator `!==`, and the `case`/`casex`/`casez` statements as **features Verilog-AMS supports in the analog context**, with a worked `a2d` example using `===` four times. The `// error` lines in the clause's `converter` example are the x/z *literal and value* lines, not the operators. Refusing `===` is over-rejection of legal AMS source. See 6.2. |
| `annex_e_spice` E.3.2.2 | `annex_e_spice/COVERAGE.md:216-224` | Already self-classified as "PARTLY implemented without one, which is the worse of the two states". **Correct, and adopted here as `implemented-without-evidence`.** Kept as the template for how a row should read. |
| `docs/CONFORMANCE-GAPS.md:44-46` host numbers ("295 unit tests", "494/616", "370 unit tests") | — | Not verifiable from this worktree; they describe ARPice. Flagged as **unverifiable-here**, not as wrong. They must carry the command and date that produced them or be moved to the repository that can re-run them. |
| `docs/CONFORMANCE-GAPS.md:44` "**1,301/1,301 strict fixtures pass**" | — | The number is correct (§1). The surrounding bullet lists it beside "VerA build, 370 unit tests", which invites sourcing it from `zig build test`, where it does not come from. Add the command. |

### 3.3 Claims checked and found accurate

Recorded so they are not re-litigated:

- `ch10_directives/COVERAGE.md:13-18` — `` `default_discipline ``/`` `default_transition ``
  parsed and consumed, and the five 1364 directives accepted-and-ignored. Confirmed
  at `src/frontend/preprocessor.zig:205-214` (`.ignored` for `default_nettype`,
  `celldefine`, `endcelldefine`, `unconnected_drive`, `nounconnected_drive`) and
  `:1095-1096` for the two that are applied.
- `ch11_vpi/COVERAGE.md:61-66` — "These results do not assess conformity of the
  standard C API, its object model or callbacks." Accurate and correctly scoped.
- `ch09_system_tasks/COVERAGE.md:51` (`s9.5.6`) — `$fflush` "is genuinely a no-op
  and says so". Confirmed: `src/backend/file_kernels.zig:384-389`, every write is
  positional and unbuffered, so there is no buffer to flush.
- `ch09_system_tasks/COVERAGE.md:42` (`s9.5.1`) — descriptor bit encodings.
  Confirmed at `src/backend/file_kernels.zig:130-133` (mcd `1 << (k+1)`, fd
  `(1<<31) | (k+3)`) and the mcd fan-out on write at `:193-203`; `zfSlot` at `:161-170` documents that the lowest set bit above bit 0 names the channel for every single-channel operation.
- `annex_c_analog_subset/COVERAGE.md:13-15` — "Annex C defines the optional
  Verilog-A subset, not VerA's full-AMS target. Rejection of a legal AMS construct
  records an implementation gap, not conformance." This is the correct framing and
  every other chapter should adopt it verbatim. One place in the **compiler** still
  does not: see 6.2.

---

## 4. Inherited IEEE 1364 §§17–18 obligation inventory

**Re-derived row by row at `a99a37f` on 2026-09-21.** This deepens the D09
table in the plan, which has one row per clause group and marks every row "open".
Here each row is one independently reviewable obligation with a verdict and a
reason.

**Caveat on numbering.** IEEE 1364-2005 is still not in this worktree. Two
subclause numbers are confirmed by the AMS LRM's own cross-references —
**17.2.7** (`$ferror`, `docs/ch9-system.html`) and **17.9.3** (the distribution C
listing, `docs/ch9-system.html`, Table 9-26). The rest are from the inherited
standard's structure and must be re-checked against a copy of 1364-2005 before
this table gates anything (§7.3 item 8). Clause and subclause *content* below is
stated only where the AMS LRM restates it or where the source settles it.

**The AMS §9.22 subclause numbers were re-read and shifted by one.** The 2023
chapter makes §9.22.2 `$receiver_count`, so `$driver_state` is §9.22.3,
`$driver_strength` §9.22.4 and the `driver_update` operator §9.22.5. The
2026-09-16 numbering came from the 2.4 transcription `2cc1c08` removed.

**Context matters and is a separate axis.** Every AMS Chapter 9 table has a
"supported in analog context" column. A name with `No` in that column is
correctly refused inside an `analog` block *and* is still required in the digital
context. `lib/ir/lower.zig:7521` (`isDigitalOnlySysFunc`) is the refusal list,
raised as E0806 at `:6454`. So for every name on that list, **the analog verdict
and the digital verdict are different rows**.

**What is no longer true:** the 2026-09-16 text closed with "the whole digital
dispatcher is three names plus two casts", and used it to make every digital row
`missing` "without exception". At HEAD the dispatcher is the 22-entry task table
at `src/sim/digital.zig:596-617`, the casts at `:437`, the `$time`/`$stime`/`$clog2`
expression table at `:460-462`, and a printer at `:1461`. **That single stale
sentence was the sole support for roughly thirty verdicts**, and re-deriving it is
most of what changed below.

**Where the evidence lives.** A row marked `verified` names a passing executable
test. Two harnesses can supply one, and the row says which: the 1558-fixture
`.va` walk (measure A, `zig build benchmark -- --strict`), and the 66-case `.v`
transcript runner (`zig build test-devices`, currently 47/66 — **no `d09_*` case
is among its failures**, each was re-diffed individually). The `.v` harness is
outside measure A; see §1.1 b′.

### 4.1 §17.1 — Display system tasks

| # | Obligation | Analog context | Digital context | Verdict | Reason / reference |
|---|---|---|---|---|---|
| 17.1-01 | `$display`, `$write` base spellings | present (`lib/ir/lower.zig:6849` `isDisplayTask`, `lib/backend/cg_display.zig:174`, `:196` "`$write` is the family member that does NOT end the line"); `02`, `03` pass | both present (`src/sim/digital.zig:596`, `:600`); `d09_01_display_radix.v` pins `$write`'s missing newline | **verified** | Table 9-1 Yes/Yes; §9.4.1 Syntax 9-1. Both halves now have a passing executable test |
| 17.1-02 | `$displayb/o/h`, `$writeb/o/h` radix variants | refused, correctly — `lib/ir/lower.zig:7521-7527` → E0806 at `:6454`; `152_display_radix_variants_analog_rejected.va` emits all eight in one run | implemented (`src/sim/digital.zig:597-599`, `:601-603`); `d09_01` pins `$displayh`→`a5`, `$displayo`→`245`, `$displayb`→`10100101`. **No fixture uses `$writeb/o/h`** | **implemented-without-evidence (digital `$write*`)** / verified (`$display*` digital; analog prohibition) | Table 9-1 `Yes/No`. No longer `missing`: the code path is named. Caveat — `//! reject` passes on any diagnostic, so `152` pins the family, not each name |
| 17.1-03 | 17.1.1.1 escape sequences | present — `lib/frontend/lexer.zig:624`, `lib/ir/lower.zig:10367` ("direct output literals retain their lexical bytes (§9.4.2)"); `lexer.zig:918` and `188_numeric_string.va`'s `"\377"`/`"\001A"` | present (`lib/frontend/parser.zig:5043` keeps octal NUL); **no d09 golden contains an escape** | **implemented-without-evidence (digital)** / verified (analog) | §9.4.2 Table 9-21. **`zig build test-literal-output` no longer exists** — deleted in `2cc1c08`; the old citation is dead and survives only in `ch09_system_tasks/COVERAGE.md:50` |
| 17.1-04 | 17.1.1.2 format specifications | full C prefix `%[flags][width][.prec]conv` via `lib/backend/cg_display.zig:641`; `171_display_c_format_flags.va` plus `s01_01`–`s01_04` all pass (`%g` significant digits, sign before zero fill, round-half-to-even, `%r` engineering notation) | Table 9-22 radix only, `%e/%f/%g` restricted to `$realtime` (`src/sim/digital.zig:1548`), `%t` (`:1516`); `%c %l %m %s %r` refused (`:1525-1528`); bare width, no flags, no precision (`:1499-1503`) | **partial (digital)** / verified (analog) | Boundary nameable: digital has Table 9-22's radix rows, a width and `%t`; it lacks `%c %l %m %s`, C flags/precision, and **§9.4.7's `%r` on reals in the digital context** (row AMS-02) |
| 17.1-05 | 17.1.1.3 automatic sizing of displayed data | documented **deviation** — `cg_display.zig:136-141`: a bare integer prints minimal-width where 1364 auto-sizes `%d` to 20 columns for 64-bit | implemented — `src/sim/digital.zig:1683` `width orelse autoWidth(v, radix)`, `:1693`; `d09_01` pins `%d` of an 8-bit 7 as `[  7]`, `%0d` as `[7]`, `%h`→2, `%o`→3, `%b`→8 | **partial** | was `missing`. Digital half verified; analog half deviates deliberately and the deviation is in-source |
| 17.1-06 | 17.1.1.4 unknown / high-impedance display | `x`/`z` cannot reach a display operand — E0130 at `lib/ir/lower.zig:1310` | implemented — `src/sim/digital.zig:1716` `groupText`, `:1739-1744` ("all unknown prints lowercase, partly unknown prints uppercase"); `d09_02_display_unknown_radix.v` pins `ax`/`2Xx`, `z3`/`zZ3`, LSB-first octal grouping | **partial** | was `missing`. Digital verified. **The analog half is contested inside this repo — see §7.5 item 1; not settled here** |
| 17.1-07 | 17.1.1.5 strength format `%v` | **fabricated value** — `cg_display.zig:725` maps `'t','u','z','v' => "d"`, so `$display("%v", 65)` silently prints `65` | refused, E1100 (`src/sim/digital.zig:1525`) | **missing** | Verdict unchanged, reason sharper: analog does not refuse `%v`, it *answers* it with a decimal. Needs D03 drivers/strengths |
| 17.1-08 | 17.1.1.6 hierarchical name `%m`, takes no argument | **verified** — `cg_display.zig:560-571` (`%m`/`%l` consume no operand); `192_m_format_hierarchical_name.va` passes 3/3: the name prints, `%m` consumes no argument so a following `%d` still takes 7 | **refused** (`src/sim/digital.zig:1525`) — a conforming input rejected | **missing (digital)** / verified (analog) | §9.4.4 is explicit and Table 9-1 gives `$display` digital Yes, so this refuses a legal construct. The old `implemented-without-evidence` conflated the halves; `COVERAGE.md:37` is superseded by `192` |
| 17.1-09 | 17.1.1.7 `%s` ASCII-code output | **verified** — `cg_display.zig:669`; seven `188_numeric_string*.va` files pin byte order, width, leading-zero suppression, interior/trailing NUL, signed carriers | **refused** (`src/sim/digital.zig:1525`) | **missing (digital)** / verified (analog, integer operands) | §9.4.5. Real operands and packed digital expressions still untested; the digital half is now a measured refusal, not an absence |
| 17.1-10 | 17.1.2 `$strobe` at converged solution | **verified** — `01_display_strobe.va`; `s01_07_strobe_writes_once_per_accepted_solution.va` **now passes**, pinning exactly 2 bytes per accepted solution against a per-iteration counterfactual of ≥4 | **verified** — `src/sim/digital.zig:604`, `:2396` ("the arguments are NOT captured, the call is"); `d09_03_strobe_scheduling.v` pins post-NBA sampling and delivery of both same-time calls, without constraining their order | **verified** | §9.4.1 + inherited §17.1.2. Both contexts have a passing fixture asserting the observable. The former callback-order claim is withdrawn as STROBE-ORDER-001 in `conformance-scheduling.md`; this row is not evidence for that claim. |
| 17.1-11 | 17.1.2 `$strobeb/o/h` | refused (`lib/ir/lower.zig:7525`), pinned by `152` | implemented (`src/sim/digital.zig:605-607`); **no committed fixture uses them** | **implemented-without-evidence (digital)** / verified (analog prohibition) | was `missing`. Code path named; evidence absent |
| 17.1-12 | 17.1.3 `$monitor` re-displays only on a changed argument | mechanism **now exists** — `cg_display.zig:207-213` emits `if (zMonitor(site, …))`, kernel at `lib/backend/str_kernels.zig:692`, unit-tested at `cg_display.zig:996-1005`. **No fixture observes it at an accepted step**: `s01_05` and `s01_06` both **FAIL** on the separate `fd == 0`-outside-the-display-unit defect | **partial** — `d09_04_monitor.v` covers unchanged assignments, coalescing and off→on resumption, but new source-derived fixtures fail installation settling, return-to-previous triggering and the $time exception; see `conformance-monitor.md` | **implemented-without-evidence (analog)** / partial (digital) | Follow-up source audit, 2026-09-23: MON-INSTALL-001, MON-RETURN-001 and MON-TIME-001 supersede the former complete digital verification claim. Analog $abstime/$realtime exceptions still require separate evidence; the digital exceptions are those in IEEE 17.1.3. |
| 17.1-13 | 17.1.3 one active `$monitor`; `$monitoron`/`$monitoroff` | mode switches refused (`lib/ir/lower.zig:7528`), pinned by `152`. **One-active-monitor deliberately deviated from**: `zMonitor` latches per call site (`cg_display.zig:1003` "a DISTINCT site is a distinct latch"), so two analog `$monitor`s both print | **partial** — `d09_04_monitor.v` observes replacement and off→on resumption; `audit_monitoron_already_enabled.v` exposes MON-ENABLE-001. Replacement while disabled and pending callbacks remain open | **partial** | Follow-up source audit, 2026-09-23: `conformance-monitor.md` records the passing replacement/off→on subset and failing already-enabled monitoron case. Analog mode-switch prohibition and single-list behavior remain separate obligations. |
| 17.1-14 | `$debug` displays per solver iteration | **not implemented** — same accepted-point unit as `$strobe`; `s01_SPEC.md` records under "Deliberately NOT covered" that every counting statement is itself an accepted-point statement | correctly absent — Table 9-1 gives `$debug` digital **No**; `src/sim/digital.zig:1407` refuses it | **missing** | §9.4.1 and §9.4.6. Needs a runner-side oracle counting records between two accepted points, not a `.va` fixture |
| 17.1-15 | §9.4.6 no display output except `$debug` unless the iteration is accepted | the no-output-unless-accepted half is **verified** — `s01_07` passes and its counterfactual is exact | n/a (§9.4.6 is an analog-block clause) | **partial** | was `implemented-without-evidence`. Half the sentence is now pinned; the `$debug` exception is 17.1-14's `missing`, so the mechanism is still right for the wrong reason — nothing prints per iteration at all |
| 17.1-16 | Null argument (`,,`) produces one space | **not implemented** — `lib/ir/lower.zig:6504` `if (a == .none) continue; // A.6.9 empty argument slot` drops it before codegen. Measured: `$display("[", , "]")` prints `[]` | **verified** — `src/sim/digital.zig:1466-1471` quotes §9.4.1 and writes one space; `d09_01` pins the golden line `[ ]` | **missing (analog)** / verified (digital) | was `implemented-without-evidence`. §9.4.1 states the rule verbatim. **A real, newly-measured analog defect** |
| 17.1-17 | `$strobe` with no arguments prints a newline | present and measured correct (`cg_display.zig:196-198`), no fixture asserts it | present and measured correct; `d09_01`'s golden ends with the blank line a bare `$display;` produced — the `$strobe` spelling itself is unpinned | **implemented-without-evidence** | §9.4.1. Unchanged verdict; the digital half is one spelling short of verified |

**§4.1 tally, by the governing (weaker) context:** missing 5 · partial 5 ·
implemented-without-evidence 5 · verified 2 = **17 rows**.
Was: missing 11 · partial 2 · implemented-without-evidence 4 · verified 0.

### 4.2 §17.2 — File I/O

| # | Obligation | Verdict | Reason / reference |
|---|---|---|---|
| 17.2-01 | 17.2.1 `$fopen` multichannel descriptor encoding | **verified** | `lib/backend/file_kernels.zig:135-136`; `158_fopen_multichannel_descriptor.va:48-50` pins bit 31 clear, exactly one bit set, not bit 0 |
| 17.2-02 | 17.2.1 `$fopen` file-descriptor encoding, channels from 3 | **verified** | `file_kernels.zig:138` (`(1 << 31) \| (k + 3); // 0..2 are the std streams`); `07_file_open_close.va:34-35` pins bit 31 set and channel > 2; `053_ferror.va:47` pins **0** for a missing `r` file. **Not `158`** — that fixture covers only the mcd shape |
| 17.2-03 | 17.2.1 `$fclose` frees a channel for reuse | **implemented-without-evidence** | `file_kernels.zig:101-102` free-slot scan, `:444` `zFClose`. **No fixture observes the reuse**: `158` opens one channel, closes it, never reopens; `s01_13` does four open/close pairs but never compares two descriptors. The 2026-09-16 claim that "158 observes the reuse" (repeated at `COVERAGE.md:57`) is not supported by the file |
| 17.2-04 | 17.2.1 at most 31 output channels via mcd | **resource limit**, stated, **untested** | `file_kernels.zig:71` `zf_max = 30`; exhaustion is loud — `:103-105` sets `zf_last_err = 24 // EMFILE` and returns 0. No fixture opens 31 channels |
| 17.2-05 | 17.2.1 descriptor table is per *device image*, shared by instances | **resource limit**, stated, **untested** | `file_kernels.zig:73-77` ponytail comment names the ceiling and the upgrade path; `:78` `var zf_slots: [zf_max]ZFSlot`. No fixture runs two instances that both open files |
| 17.2-06 | 17.2.2 `$fdisplay`/`$fwrite`/`$fstrobe`/`$fmonitor`/`$fdebug` | **partial** | `lib/backend/cg_display.zig:437` `emitFileWrite`. Bytes now pinned **directly**, not only by round-trip: `s01_13:86` asserts `$fdisplay(fd,"%600.2f",3.5)` writes 601 bytes, `:90` that six `$fwrite` fields + newline are 600; `s01_07:88` pins `$fstrobe` at one record per accepted solution. **`$fmonitor` change detection now exists** (`cg_display.zig:481-485`, `str_kernels.zig:692`) but the two fixtures asserting the §9.4.1/§9.5.2 observable **FAIL** — `s01_05`, `s01_06`. Boundary: the latch compares records, but a `$fmonitor` registered in `@(initial_step)` is not re-run per step and `$fopen` outside the display unit answers 0 (W0850, `lib/ir/lower.zig:6531`). `$fdebug` inherits 17.1-14 |
| 17.2-07 | 17.2.2 `$fdisplayb/o/h`, `$fwriteb/o/h`, `$fstrobeb/o/h`, `$fmonitorb/o/h` | **missing (digital)** | Analog refusal **correct and pinned** — `lib/ir/lower.zig:7531-7535`, E0806 at `:6455`, `153_file_io_digital_only_analog_rejected.va` passes; that is *verified on the prohibition*, a different row. **The digital runner has no file I/O at all**: `src/sim/digital.zig:596-617` holds no `f`-prefixed name and no `$fopen`. Measured: `$fopen` in an `initial` block gives E1100. Table 9-2 `Yes/No` |
| 17.2-08 | 17.2.3 `$sformat`, `$swrite` | **verified** | `lib/backend/str_kernels.zig:743-748` `zSBuf`; `044_swrite.va`, `045_sformat.va`, `06`, `09` round-trip the text through `$sscanf`; lowering makes both an assignment, so a writer that wrote nothing fails |
| 17.2-09 | 17.2.3 `$swriteb/o/h` | **missing (digital)** | `lib/ir/lower.zig:7535-7536`. Refused in analog per Table 9-2; the digital table has no `$swrite` in any radix |
| 17.2-10 | 17.2.4 `$fgets` returns the count *including* the newline | **verified** | `file_kernels.zig:243` `zFGets`; `046_fgets.va` (four-byte line → 4), reinforced by `s01_10:68` and `s01_13:87` (601-byte line in one call) |
| 17.2-11 | 17.2.4 `$fscanf`/`$sscanf` conversion rules, suppression, max field width, early match failure, EOF | **verified** | One scanner for both spellings per §9.5.4.2 — `str_kernels.zig:55` `zScan`, windowed by `file_kernels.zig:316` `zFWindow`, consumed by `:348` `zFTake`. `048`, `162`, `047`, plus **five new passing fixtures**: `s01_08` (successive scans, newline ≠ EOF, then EOF), `s01_09` (a directive spanning two lines), `s01_10` (early match failure returns 0 and leaves the character unread), `s01_11` (real destinations, sign and exponent), `s01_12` (`%r` engineering scale factors per §2.6.2, `%m` reads no data) |
| 17.2-12 | 17.2.4 scan conversion codes are lower case | **verified**; **unspecified** on the invalid-code half | `lib/ir/lower.zig:7400` `checkScanFormat`, accepting exactly `"dohxbcfegsrm"` at `:7419`; exercised by `162`/`047`/`048`/`s01_12`. But §9.5.4.2 says "if an invalid conversion character follows the %, the results … are **implementation dependent**" — so `169_sscanf_uppercase_conversion_rejected.va` (E0813) pins VerA's *documented choice*, **not** a prohibition the LRM states. It is not "verified on the prohibition" |
| 17.2-13 | 17.2.4 `$fgetc`, `$ungetc`, `$fread` | **missing (digital)** | `lib/ir/lower.zig:7536-7537`. No implementation anywhere; the only other mentions are a comment at `file_kernels.zig:28-29` and prose at `:390`. `$ungetc`/`$fseek` interaction still untestable |
| 17.2-14 | 17.2.4 scan input line buffer | **resource limit**, stated, **now tested** | `file_kernels.zig:64` `line: [4096]u8` — **was 512** — and `:59-63` says why ("§9.5.4.1 puts no length limit on a line … a short row does not truncate a record — it silently splits it across two reads"). `s01_13_long_record_is_not_truncated.va` **passes**, pinning a 601-byte `$fgets` in one call. The bound *itself* (a 4097-byte line) is still unpinned |
| 17.2-15 | 17.2.3 formatted-string scratch buffer | **resource limit**, stated, **now tested** | `str_kernels.zig:743-748`, `var b: [4096]u8` per site — **was 512**; `:736-742` records the reason. Overrun formats to the empty string, not a truncation (§9.5.3 gives no truncation rule). `s01_13:86` pins a 601-byte record through this buffer |
| 17.2-16 | 17.2.5 `$ftell`, `$fseek`, `$rewind` | **verified** | `file_kernels.zig:359` `zFTell`, `:371` `zFSeek`; `049`/`050`/`051`/`11` each assert a moved *and* an unmoved pointer plus the status return; strengthened by exact byte offsets in `s01_08`, `s01_09`, `s01_10`, `s01_13` |
| 17.2-17 | 17.2.6 `$fflush` | **verified (vacuously)** + **implementation-defined** | `file_kernels.zig:433-440`, `pub fn zFFlush(_: i64) i64 { return 0; }` — unbuffered positional writes make it a conforming no-op; `052_fflush.va:26` pins the only observable. The *choice* to be unbuffered is implementation-defined and documented at `:433-437` |
| 17.2-18 | 17.2.6 `$fflush` with no argument flushes all open files | **implemented-without-evidence** | Same kernel; the zero-argument form lowers (`cg_display.zig:441-443` supplies `Mir.Value.zero`) and compiles. No fixture calls it — every `$fflush` in the tree is `$fflush(fd)` |
| 17.2-19 | **17.2.7** `$ferror` returns an error code and a description | **verified**; the numeric errno **unspecified** | `file_kernels.zig:411` `zFError`, `:419` `zFErrorStr`, values from `:142-152`; `053_ferror.va:45-48` pins both directions. §9.5.7 says only "an error code is returned" and `:141-143` records that no fixture may assert the value — correctly unasserted |
| 17.2-20 | 17.2.8 `$feof` | **verified** | `file_kernels.zig:399` `zFEof`, flag set in `:348` `zFTake`; `054_feof.va` puts the descriptor in both states, and `s01_08:91,95` adds the discrimination the clause turns on — stopping on a newline is **not** EOF, input ending before a conversion **is** |
| 17.2-21 | 17.2.9 `$readmemb`/`$readmemh`: comments, addresses, ranges, direction, x/z, malformed and excess data | **partial** | **A digital loader now exists** — `src/sim/digital.zig:615-616` task table, `:1565-1621` `readMemory`, `:1626-1634` `readSideFile`, `:2423` dispatch. Verified halves: `tests/fixtures/digital/d09_08_readmemh.v` (comments ignored, load starts at the left declared index, `@<hex>` relocates, untouched addresses keep their X) and `d09_09_readmemb_range.v` (four-argument form, `start > finish` loads **downward**, `x`/`z` digits) both reproduce their `.expected.txt` exactly. **Missing half — excess data**: `:1611-1618` breaks on reaching `last` and never counts the surplus; measured, five words into `reg [7:0] m [0:3]` prints four and **exits 0, silently**. Left-index rule holds only for ascending declarations (`:1587-1590` sorts `arr.low`/`.high`). Analog correctly refused (`lib/ir/lower.zig:7537-7538`, pinned by `153`). Table 9-2 `Yes/No`. **See §7.5 item 3 — its refusal fixture `d09_91` is run by nothing** |
| 17.2-22 | 17.2.10 `$sdf_annotate` | **missing** | `lib/ir/lower.zig:7538`. No implementation in `lib/` or `src/`; not in the digital task table. Blocked on D07/D09 specify blocks |
| 17.2-23 | §9.5.1.1 reopening a write-mode file across analyses appends | **missing (untestable today)** | The append machinery exists (`file_kernels.zig:132-133`) but the rule's subject is the SECOND analysis, and `lib/backend/tb.zig:98` `analysis: Analysis = .dc` is a single enum — one analysis per process, and a second `//! analysis` line is dropped in silence. Remains UNCITED |
| 17.2-24 | §9.5.1.2 descriptor sharing between analog and digital contexts | **missing**, now **cited** | A digital context now exists and **still has no file table** — measured, `$fopen` in an `initial` block is E1100, and on the analog path the assignment is refused by E0433 first. `194_file_descriptor_shared_across_contexts.va` is **XFAIL**, which is the right verdict and leaves the row missing. **No longer in the UNCITED list** |
| 17.2-25 | §9.5.9 file position rolled back on a rejected iteration, `$fdebug` excepted | **implemented-without-evidence** | `lib/backend/codegen.zig:438-447` `emitting_display`, whose doc quotes §9.5.9 verbatim: every §9.5 call runs in the one unit `planCommon` keeps out of the shared core, so nothing writes during a rejected iteration. Enforced negatively by W0850 (`lib/ir/lower.zig:6531`). The *`$fdebug` exception* is therefore also not implemented — see 17.1-14 |

**§4.2 tally:** missing 6 · partial 2 · implemented-without-evidence 3 ·
verified 10 · resource-limit-only 4 = **25 rows**.
Resource limits **now tested**: 17.2-14, 17.2-15 (both by `s01_13`). Still
untested: 17.2-04, 17.2-05. Orthogonal flags: **unspecified** on 17.2-19's errno
value and 17.2-12's invalid-code half; **implementation-defined** on 17.2-17.

### 4.3 §17.3–§17.11

Source-verified supersession, 2026-09-23: the inherited control/time, PLA and
queue reports (`conformance-ieee-control-time-review.md`,
`conformance-ieee-pla-review.md`, `conformance-ieee-queue-review.md`) take
precedence over broader claims in the historical rows below. Main read complete
IEEE §§17.3–17.6 and §19.8 and independently ran the new digital batch.
Argumentless and runtime-argument `$timeformat` calls, expression-valued
`$finish`, and the legal PLA/queue witnesses fail at their intended unsupported
feature boundaries. Per-delay rounding passes. Thus `$timeformat` is not
generally verified. The source supplies `$printtimescale`'s format; missing
licensed source is no longer the reason its behavior lacks evidence. The
combined analog fixture154 does not isolate PLA or queue refusals. These
findings expand the evidence ledger, not a certified atomic denominator or
an automatically recomputed historical B tally.

The digital wide-clog2 defect found during this audit is now repaired; root
wide/unsigned transcripts and all-limb focused tests pass. See
`conformance-ieee-clog2-fix.md`. Constant-expression and remaining math-family
obligations are still open; no whole-row upgrade is inferred.

| # | Obligation | Verdict | Reason / reference |
|---|---|---|---|
| 17.3-01 | `$printtimescale`, `$timeformat`: scope, rounding, formatted output | **partial** | `$timeformat` is **implemented and pinned**: `src/sim/digital.zig:614`, the clause's defaults at `:620-623`, argument rules at `:1420-1426`, `%t` at `:1516`/`:1638-1640`. `tests/fixtures/digital/d09_07_timeformat.v` passes and pins the `units_number` conversion at −9/−6/−12, precision, suffix, min field width, and that `%t` formats its **argument** rather than the clock. `$printtimescale` remains a name on `lib/ir/lower.zig:7541`'s refusal list — `d09_SPEC.md:209-211` declares its banner text non-derivable from the offline chapter and deliberately unfixtured. Analog refusal correct (§9.6 Table 9-3), pinned by `154`. **Boundary: `$timeformat` verified (digital), `$printtimescale` missing** |
| 17.4-01 | `$finish` and its optional diagnostic level | **partial** | The 2026-09-16 claim that "the level's diagnostic output is not implemented in either context" is **false at HEAD**. Analog: `lib/backend/cg_display.zig:239` `finishLevel` (default 1 per §9.7.1), `:269-271` prints accepted time and module for level ≥ 1, `:255-258` documents level 2 collapsing to level 1 with a named ceiling. Digital: `src/sim/digital.zig:617`, arity at `:1445`, **level 2 refused** at `:1449`, `:2424-2431` prints for level ≥ 1 and nothing for 0. `172_finish_terminates.va` pins analog termination; `digital.zig:3421` pins the level-2 refusal inside the test at `:3408`. **Boundary: Table 9-25's level-2 memory/CPU statistics exist nowhere, and the level-1 text is asserted by no test in either context** |
| 17.4-02 | `$stop` host behavior | **partial** | `174_stop_terminates.va` pins print-and-exit-0, which `cg_display.zig:266-269` names as a deliberate simplification with "a debugger hook" as the upgrade path — **implementation-defined and documented** — but the LRM's suspension semantics are absent. Digital half added at this re-derivation: `$stop` appears nowhere in `src/sim/digital.zig:596-617`; the digital engine has no `$stop` at all |
| 17.4-03 | Scheduler and resource cleanup on `$finish`/`$stop` | **partial** | Pending-process discard **is** observed: `src/sim/digital.zig:3522` `test "unknown delay is zero and finish discards pending later processes"` — a sibling `initial begin #2 $display("not run"); end` never runs — and it is on `zig build test`. Implementation at `:2431` `self.scheduler.finish()`. Nothing observes file-descriptor or memory release, and the analog context has no cleanup observation at all |
| 17.5-01…16 | PLA: 16 spellings of `$async`/`$sync` × `and`/`nand`/`or`/`nor` × `array`/`plane` | **missing** ×16 | `lib/ir/lower.zig:7547-7552`, refused at `:6454`/`:9230` via E0806. §9.8: AMS "does not extend" them, placing them in the digital context only, where nothing implements them — no PLA name appears in `src/sim/digital.zig`. `154_timescale_pla_queue_analog_rejected.va` pins the analog refusal and is **not** coverage of the tasks |
| 17.5-17 | PLA personality data, four-state logic, update timing | **missing** | |
| 17.6-01…05 | `$q_initialize`, `$q_add`, `$q_remove`, `$q_full`, `$q_exam` | **missing** ×5 | `lib/ir/lower.zig:7555-7557`; §9.9 same structure as PLA; no name in `src/sim/digital.zig` |
| 17.6-06 | Queue discipline (FIFO/LIFO), status codes, capacity, time statistics | **missing** | |
| 17.7-01 | `$time` — 64-bit, scaled to the caller's timescale | **partial (2026-09-23 source review)** | The old 64-character rendering of value7 did not prove return width: a narrower value zero-extends identically. `audit_time_stime_wrap.v` now observes bit32 and passes; existing scaled/rounding witnesses remain bounded evidence. Mixed-module scaling, full width/context boundaries and invalid-input matrices remain open. See `conformance-ieee-tasks-review.md`, TIME-IEEE-001–008. |
| 17.7-02 | `$stime` — unsigned32-bit local-unit time | **partial (2026-09-23 source review)** | `audit_time_stime_wrap.v` now observes unsigned2^31 and truncation at2^32 and2^32+3, superseding the old absence claim. It passes with equal unit/precision; hierarchy-local scaling and wider boundary combinations remain separate. See `conformance-ieee-tasks-review.md`. |
| 17.7-03 | `$realtime` | **partial**; §9.10's NOTE **deprecates** `$realtime` in the analog context, so the analog refusal is correct and is pinned by `148_realtime_analog_rejected.va` | `src/sim/digital.zig:541` `realtime_name` and `:1549-1560` — recognised **only as a real display argument**, because `:537-540` records that there are no real variables to put it in yet. Values pinned by `d09_05` and `d09_06` (the sub-unit instants where `$time` and `$realtime` must disagree), plus `digital.zig:3478`. **Boundary: printable, not storable, not an operand** |
| 17.7-04 | `$abstime` (AMS addition, `Yes` in both columns) | **missing (digital)** / verified (analog) | `14_abstime.va`; §9.10. No `$abstime` in `src/sim/digital.zig`. Weaker context sets the row |
| 17.8-01 | `$rtoi`, `$itor` | **missing (digital)** / **implemented-without-evidence (analog)** | The analog-prohibition claim is **withdrawn**: the 2023 Table 9-8 reads `$rtoi Yes Yes` and `$itor Yes Yes`, and fixtures `061`/`062` were deleted in `2cc1c08` as 2.4-contaminated. Both names **are** implemented — `lib/backend/codegen.zig:6043` (`lossyCast(i64, @trunc(...))`, §17.8's truncation) and `:6049` — with `$rtoi` typed integer at `lib/ir/lower.zig:10496`. **No fixture exists.** `ch09_system_tasks/COVERAGE.md:78`'s "neither name is implemented" is stale |
| 17.8-02 | `$realtobits`, `$bitstoreal` | **partial** | Analog path exists (`063`, `064`, `15_conversion_functions.va`) at `lib/backend/codegen.zig:6057`/`:6063`; `lib/ir/lower.zig:6953` fixes the width at 64 for `$realtobits`. Digital typing, x/z and overflow untested — `tests/fixtures/digital/m04_06_realtobits_bitstoreal_bridge.v` FAILS on `wreal` (E0205) |
| 17.8-03 | `$signed`, `$unsigned` | **partial** | Refused in analog (`lib/ir/lower.zig:7567`), correct per Table 9-8 `Yes/No`, pinned by `134`/`135`. Digital casts exist (`src/sim/digital.zig:437`, `:972-976`) but the cast only re-labels the operand's `.signed` bit; **the §17.8 sign-extension observable is asserted by no test** — the evidence is arity/type refusals (`digital.zig:3639-3641`) and one replication-count use |
| 17.9-01 | `$random` with no seed | **verified (analog)** | `115_random_no_seed.va`, `171_random_ieee1364_digits.va`; the digital half is 17.9-14 |
| 17.9-02 | `$random` typed `inout` seed, mutated in place | **partial** | **`zig build test-rng-reference`, `tests/rng_reference.c` and `tests/rng_reference.zig` were deleted in `2cc1c08`; no such build step exists at HEAD.** What survives: the four argument rules on E0816 rejections, and `171_random_ieee1364_digits.va:46-50,58,61,67`, which pins the seed write-back digit-exactly for `$random`/`$rdist_uniform`/`$dist_uniform` two draws deep. `119`–`130` pin only `sa != 7` and `sa == sb` |
| 17.9-03…09 | `$dist_uniform/normal/exponential/poisson/chi_square/t/erlang` | **verified (analog, integral counts)** ×7 | `lib/backend/rng_kernels.zig:102-266` transcribes §17.9.3; `119`–`124` plus `34_distribution.va` pin §9.13.2's repeatability and inout mutation, and `119` the closed `start`..`end` range. The **value-identity** evidence moved to 17.9-10 |
| 17.9-10 | **17.9.3** algorithm identity | **partial** | The C listing is transcribed verbatim (provenance URLs at `rng_kernels.zig:18-24`) but is **no longer differentially tested** — the oracle was deleted in `2cc1c08`. What remains is `171_random_ieee1364_digits.va`, which pins the listing's `rtl_dist_uniform`/`uniform` to the last bit, values and seed steps, two draws deep, plus `189_rng_reference_large_count.va`. **Boundary: `uniform` pinned; `normal`, `exponential`, `poisson`, `chi_square`, `t`, `erlangian` are pinned by nothing** |
| 17.9-11 | AMS real-valued `$rdist_*` (Table 9-26) | **verified (analog)** | `125`–`130`, `35_real_distribution.va`; `$rdist_uniform` additionally bit-exact in `171`. Same value-identity narrowing as 17.9-10 |
| 17.9-12 | Fractional and out-of-range counts | **missing**, explicitly | `lib/backend/rng_kernels.zig:78-81` — the listing's positive signed-32 domain, "**without a substitute count** … those legal inputs are explicitly unsupported". A *good* `missing`: loud, documented, pinned by `189_rng_fractional_count_rejected.va`, `189_rng_count_range_rejected.va` and two `paramset` siblings. Citation moved: `docs/RNG-REFERENCE-LIMITS.md` was deleted in `2cc1c08` |
| 17.9-13 | Reference Erlang/Student-t overflow to inf/NaN, Poisson precision loss | **unspecified, preserved deliberately** | `lib/backend/rng_kernels.zig:80-81` — "Reference overflow/underflow remains observable". The listed operations are preserved rather than "fixed". No fixture may assert a different value |
| 17.9-14 | Digital `$random`/`$dist_*`: default streams, call-order behavior | **missing** | No `$random`, `$arandom`, `$dist_*` or `$rdist_*` name appears anywhere in `src/sim/digital.zig` |
| 17.10-01 | `$test$plusargs` | **missing (digital)** / verified (analog) | `065_test_plusargs.va`, `16_plusargs.va`; `lib/backend/codegen.zig:6005`, `lib/ir/lower.zig:10494`. §9.12 **Table 9-9 reads `Yes Yes`** — the digital column is `Yes` and `src/sim/digital.zig` has no such name. Weaker context sets the row. **See §7.5 item 2** |
| 17.10-02 | `$value$plusargs` | **missing (digital)** / verified (analog) | `066_value_plusargs.va`; `lib/ir/lower.zig:10495`. Table 9-9 `Yes Yes`; same digital hole |
| 17.11-01 | `$clog2` | **partial (2026-09-23 source review)** | Small values are insufficient for the full requirement. Digital unsigned and arbitrary65/129-bit transcripts now pass after the all-limb repair; focused tests also cover257-bit boundaries. A constant-expression declaration is still rejected. Analog negative-input behavior is separately under review. The former both-contexts verified claim remains withdrawn; see `conformance-ieee-math-review.md`, IMATH-CONST/UNSIGNED/WIDE and the superseding `conformance-ieee-clog2-fix.md`. |
| 17.11-02…23 | Real math: `$ln $log10 $exp $sqrt $pow $floor $ceil $abs $min $max $sin $cos $tan $asin $acos $atan $atan2 $hypot $sinh $cosh $tanh $asinh $acosh $atanh` | **verified (analog)** | `lib/backend/codegen.zig:6120-6131` `mathOpByName` aliases each to the bare operator per §9.14; fixtures `067`–`093` and `17`–`20`. Counted as **one row group** — see §7.1. Digital half is 17.11-24 |
| 17.11-24 | Digital typing and argument conversion for the math functions | **partial** | `$clog2` **does** dispatch digitally and `d09_10_clog2.v` pins its digital typing and assignment width. The other 22 do not: `src/sim/digital.zig:439-462`'s `sys_fns` is exactly three names, and `:537-540` states the engine has no real variables at all. **Boundary: integral `$clog2` yes, every real-valued math function no** |
| 17.11-25 | Domain behavior on out-of-range arguments | **implemented-without-evidence** | Re-searched the 1558-fixture tree: no fixture asserts `$ln(-1)`, `$sqrt(-1)`, `$log10(0)` or `$acos(2)` in either context |

**§4.3 tally.** 29 table rows expand to **54** under the row-counting convention
(`17.5-01…16` = 16, `17.6-01…05` = 5, `17.9-03…09` = 7, **`17.11-02…23` = 1 row
group**):

| verdict | rows | arithmetic |
|---|---|---|
| missing | **27** | 17.5-01…16 (16) + 17.5-17 + 17.6-01…05 (5) + 17.6-06 + 17.7-04 + 17.8-01 + 17.9-12 + 17.9-14 |
| partial | **13** | 17.3-01, 17.4-01, 17.4-02, 17.4-03, 17.7-02, 17.7-03, 17.8-02, 17.8-03, 17.9-02, 17.9-10, 17.10-01, 17.10-02, 17.11-24 |
| implemented-without-evidence | **1** | 17.11-25 |
| verified | **12** | 17.7-01 + 17.9-01 + 17.9-03…09 (7) + 17.9-11 + 17.11-01 + 17.11-02…23 (1) |
| unspecified (orthogonal) | **1** | 17.9-13 |
| **total** | **54** | 27 + 13 + 1 + 12 + 1 |

Movement from 2026-09-16 on the same 54 denominator: missing 33 → 27, partial
5 → 13, implemented-without-evidence 1 → 1, verified 14 → 12, unspecified 1 → 1.
**The −2 on `verified` is entirely `2cc1c08`'s deletions** (17.9-10 lost its
differential oracle) **and §9.12's digital column** (17.10-01/-02), offset by
17.7-01 arriving. The −6 on `missing` is the digital time/timeformat/clog2 work.

### 4.4 §18 — Value change dump

**Every row here is still `missing`, and the absence is still total — but all
three greps that proved it in 2026-09-16 now say something different, and none of
the differences is code.**

```
$ grep -rn 'dump' src/
                                        (no output)
$ grep -rn 'dump' lib/
lib/ir/mir.zig:345:/// library cell, and the tools that care (a timing library, a dump filter, a
lib/backend/codegen.zig:728:    //   calls to the core (`objdump | grep -c core` = 30), because it cannot
lib/frontend/preprocessor.zig:289:/// timing library, a `$dumpvars` filter), not a change to what the module
$ grep -rln 'dumpvars\|dumpfile' tests/
tests/fixtures/ch09_system_tasks/d09_11_vcd_dumpvars.expected.vcd
tests/fixtures/ch09_system_tasks/d09_12_vcd_dumpoff_on.expected.vcd
tests/fixtures/ch09_system_tasks/d09_SPEC.md
tests/fixtures/digital/d09_11_vcd_dumpvars.v
tests/fixtures/digital/d09_12_vcd_dumpoff_on.v
tests/fixtures/digital/d09_90_dumpfile_twice_rejected.v
tests/fixtures/MANIFEST.md
```

All three `lib/` hits are prose. There is still no VCD code. The 22-entry task
table at `src/sim/digital.zig:596-617` contains no `$dump*` name, and
`lib/ir/lower.zig` contains the string `dump` zero times — so `$dump*` is not
even on `isDigitalOnlySysFunc`'s refusal list.

**The 2026-09-16 diagnostic claim was wrong, and the truth is worse on one path
and better on the other.** E0512 is unreachable: `unknownCall`
(`lib/ir/lower.zig:8594`) is reached only from the bare-identifier path, and every
`$`-prefixed name falls through `lowerSysTask` (`:6453`) to `self.call(name, vals)`
at `:6521` **with no diagnostic at all**. Measured at HEAD, an analog block
containing `$dumpfile("x.vcd");` compiles clean and exits 0 — the *ignored* arm of
`missing`, not the refused one, and it is generic: `$notarealtask("x");` exits 0
too. On the digital path the refusal is honest and named — `E1100 … digital
system task '$dumpfile' is not implemented` (`src/sim/digital.zig:1407`,
`lib/diag_code.zig:4988`) — but that is an executor-subset code, not a VCD one,
and no catalogue code exists for §18.

**Three `.v` fixtures exist, and since v0.0.3 all three are read — and all three
FAIL.** They carry full hand derivations and `//! expect vcd` /
`//! reject called more than once` directives. None has an `.expected.txt`, so
`test-devices` still skips them (`tests/bench.zig`'s `digitalCases`); the
widened `collect` now takes them instead, and the suite reports:

```
FAIL digital/d09_11_vcd_dumpvars.v:          `//!` directive: BadLrmSection
FAIL digital/d09_12_vcd_dumpoff_on.v:        `//!` directive: BadLrmSection
FAIL digital/d09_90_dumpfile_twice_rejected.v: `//!` directive: UnknownDirective
```

Neither failure is about VCD, and the two causes are different from each other.
`BadLrmSection` is `validSection` (`lib/backend/tb.zig:428-435`) refusing
`//! lrm inherited IEEE 1364-2005 18.1` — and **the fixtures are right**: an
inherited clause must not enter `--coverage`'s AMS denominator (§1.1 c), and the
directive language has no word for that citation. `UnknownDirective` on `d09_90`
is **`//! rule`**, the prose statement of the obligation — **not `//! expect
vcd`**, which sits on `d09_11`/`d09_12` and is never reached because their `lrm`
line fails first. (`//! expect vcd` is still interpreted by no `.zig` file in the
tree; it is simply not what fails here.) The two goldens also sit in a
*different* directory from their producers, under names the directives do not
spell.

Per §2, **none of this moves a row**: an `.expected.vcd` nothing generates is not
evidence, and a fixture that fails on its own header asserts nothing about §18.
What changed at v0.0.3 is that the failure is now *reported* instead of silent.

| # | Obligation | Verdict |
|---|---|---|
| 18.1-01 | `$dumpfile` — name the dump file ("once per simulation" withdrawn 2026-09-23: §18.1.1 states no such limit, and `d09_90`, which refused a second call, is deleted) | **missing** — digital: E1100 not-implemented; analog: silently accepted, exit 0 |
| 18.1-02 | `$dumpvars` — no args = whole design; depth argument; scope/variable arguments | **missing** — `d09_11_vcd_dumpvars.v` pins it; nothing runs the file |
| 18.1-03 | `$dumpoff` / `$dumpon` — suspend and resume, with the `$dumpoff` all-x checkpoint | **missing** — `d09_12_vcd_dumpoff_on.v` pins it; nothing runs the file |
| 18.1-04 | `$dumpall` — checkpoint of all selected variables | **missing** — same fixture, same non-execution |
| 18.1-05 | `$dumplimit` — byte limit, and the limit-reached behavior | **missing** (also a **resource limit** once implemented) |
| 18.1-06 | `$dumpflush` — flush the buffer without interrupting the dump | **missing** |
| 18.2-01 | Four-state VCD syntax: header, `$date`, `$version`, `$timescale`, `$enddefinitions` | **missing** — both goldens fix a header; no writer exists |
| 18.2-02 | `$scope` / `$upscope` nesting and scope types | **missing** — goldens cover single-level scope only; nesting is unwritten (`d09_SPEC.md:220`) |
| 18.2-03 | `$var` declarations and identifier-code assignment, including aliasing | **missing** |
| 18.2-04 | Scalar value changes (`0`/`1`/`x`/`z` prefixed to the identifier code, no space) | **missing** |
| 18.2-05 | Vector value changes (`b`/`B`, `r`/`R`), leading-zero suppression | **missing** |
| 18.2-06 | `#` timestamp records and their ordering | **missing** |
| 18.2-07 | `$comment` | **missing** — the goldens' normaliser *deletes* `$comment`, so it is explicitly out of the pinned surface |
| 18.3-01 | `$dumpports` — file name and port list | **missing** — `$dumpports` appears nowhere in the tree, fixtures included |
| 18.3-02 | `$dumpportsoff` / `$dumpportson` | **missing** |
| 18.3-03 | `$dumpportsall` | **missing** |
| 18.3-04 | `$dumpportslimit` | **missing** |
| 18.3-05 | `$dumpportsflush` | **missing** |
| 18.3-06 | General rules for the extended VCD tasks (multiple files, repeated calls) | **missing** |
| 18.4-01 | Extended VCD node-information records and `$scope` handling; final-time `$vcdclose` is defined in §18.3.6.1, not `$vcdopen` (source correction 2026-09-23; see `conformance-vcd-review.md`) | **missing** |
| 18.4-02 | Extended VCD port direction encoding | **missing** |
| 18.4-03 | Extended VCD strength encoding (`D`/`U`/`N`/`Z`/`d`/`u`/`L`/`H`/`0`/`1`/`x`) | **missing** |
| 18.4-04 | Extended VCD value-change records | **missing** |

**§4.4 tally:** missing 22 · partial 0 · implemented-without-evidence 0 ·
verified 0 = **22 rows**. Unchanged from 2026-09-16.

**Dependency, re-checked and corrected.** 18.2-03 through 18.2-06 and all of
§18.3/§18.4 remain blocked on **D03** (packed nets, registers, drivers,
strengths) and **D05** (a digital time axis); `d09_SPEC.md:510-511` reaches the
same conclusion independently. The claim that **18.1-01 and 18.1-06 are unblocked
"because file handling already exists" does not survive contact**: the file
handling that exists is the analog one (`lib/backend/file_kernels.zig`, emitted
into a generated device), and both committed fixtures are digital `.v` run by
`src/sim/digital.zig`, whose task table has no `$fopen`, no `$fclose` and no file
handle of any kind (row 17.2-07). They are not blocked on D03 or D05, but they
are blocked on **digital-side file I/O** — a smaller prerequisite, and a real one.
`ROADMAP.md:447` still asserts the old reading and `MANIFEST.md:59` still claims
the grep returns zero hits; both are recorded in §7.3 item 11.

### 4.5 AMS additions to the inherited facilities, which need their own audit

The plan's D09 note says "AMS additions to digital system facilities still need
their own audit". Recorded here so they are not lost.

| # | Obligation | Verdict | Reference |
|---|---|---|---|
| AMS-01 | §9.3 task behavior across accepted vs rejected solver iterations | **implemented-without-evidence** | No longer UNCITED. `lib/ir/lower.zig:6522-6527` defers every display-family and §9.7 simulation-control call into the per-accepted-point display phase — "both clauses tie the task to the SOLVE" — which is §9.3's "a call … during an iteration that is rejected should cause no side-effects on the next iteration". `ch09_system_tasks/COVERAGE.md:47` still holds: a generated device cannot observe a rejection, and §9.3's second paragraph needs two `//! analysis` lines the harness cannot express (row 17.2-23). A **host** obligation, not an untestable one |
| AMS-02 | §9.4.7 `%r`/`%R` on reals in the **digital** context | **missing** | `src/sim/digital.zig:1505-1527`: the conversion switch admits `b o h d e f g t` and falls through to "only the §9.4.3 Table 9-22 conversions … are implemented" — `%r` is refused by name. §9.4.7 is one sentence of permission ("**may be used** on real expressions in the digital context"), so refusing it is `missing`. The `%r` that works is the Table 9-23 analog engineering-notation specifier (`lib/backend/cg_display.zig:643-650`). Upstream, the whole digital context is walled: XFAIL `193_severity_task_digital_context_rejected.va` and `194_file_descriptor_shared_across_contexts.va` both record that **E0433** (§7.2.2, "statement in an initial block is not a constant assignment") refuses digital-context statements before their own clause is consulted |
| AMS-03 | §9.22.1/§9.22.3/§9.22.4 driver access (`$driver_count`, `$driver_state`, `$driver_strength`) | **missing** | The `pickTop` claim **re-checked and it holds**: `lib/ir/elaborate.zig:240` `if (m.is_connect) continue;`, under the §7.6 comment "picking one as the device would elaborate a bridge as if the user had asked for it". Refusal at `lib/ir/lower.zig:9237-9243` (E0818, "can only be called from a connect module") over `isConnectModuleOnlySysFunc` at `:7602-7612`. Correct for the *wrong half* of §9.22 ¶3; the right half needs §7.8 insertion. **New evidence**: XFAIL `196_connectmodule_driver_access_example.va` carries §9.22.7's `c2e` example line for line and is refused twice over — `assign d=out;` is E0205 and behind it `out = 1'bx;` is E0130 — and its header adds that a connect module "is never inserted (§7.8) and never lowered, so nothing in the example can RUN even once it parses" |
| AMS-04 | §9.23.1–§9.23.4 (`$driver_delay`, `$driver_next_state`, `$driver_next_strength`, `$driver_type`) | **missing** | Same list, same site (`lib/ir/lower.zig:7608-7609`, refused at `:9237`). Table 9-20 fences these one step tighter than §9.22 — "supported in the digital context of connectmodules", analog No. Rejection atomics `111`–`114` pin only the prohibition |
| AMS-05 | §9.22.2 `$receiver_count` | **missing** | **The "Non-normative" reading is withdrawn.** That string does not occur anywhere in `docs/ch9-system.html` at HEAD: `:1621-1625` is a normative subclause with its own syntax box (Syntax 9-18), and Table 9-19 at `:278` gives it `Yes`/`Yes` — **the only member of the five supported in the analog context of a connect module**. The fixture that argued otherwise, `annex_g_change_history/08_new_receiver_count.va`, was deleted in `2cc1c08`; `ch09_system_tasks/COVERAGE.md:103` records why ("authored from an HTML transcription contaminated with Verilog-AMS 2.4 text"). `lib/ir/lower.zig:7597-7600` **still repeats the withdrawn claim and still cites the deleted fixture**, and its blanket E0818 is now wrong in kind for the one row Table 9-19 marks analog-Yes. `ch07_mixed_signal/m04_16_receiver_count_reports_ordinary_receivers.va` is a hard **FAIL** |
| AMS-06 | §9.22.5 `driver_update` operator | **missing** | A.6.5's `driver_update expression` parses and survives elaboration's cloner (`lib/ir/elaborate.zig:2283-2287`, "Unreachable in practice — it only occurs in a connect module, which is never instantiated"); in value position it is E0701 (`lib/ir/lower.zig:7736-7740`). `38_driver_update_connectmodule.va` is green on **acceptance only**. Zero of the clause's obligation — "causes the `statement` to execute any time a driver of the signal is updated … whether or not there is a change in the resolved value" — exists: the event is accepted and can never fire. **New**: XFAIL `195_receiver_net_resolution_assign.va` pins §9.22.6, whose only spelling for the receiver value is `assign d = out;`, and `assign` is E0205 everywhere in VerA, connect module or not. **See §7.5 item 4** |
| AMS-07 | §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log` PSD export | **verified** | **The gap named on 2026-09-16 is closed.** `contract.NoiseGen.kind` is now `enum { thermal, shot, flicker, table }` with a `table: ?u16` back-reference (`tools/contract.zig:681,687`), and `contract.NoiseTable` (`:724-740`) carries `interp: enum { linear, log }` plus ascending knots. `lib/ir/lower.zig:5875-5878` classifies both calls into `.table`/`.table_log` instead of dropping them; `lib/backend/codegen.zig:7285-7320` emits `noise_tables`. Executable: `lib/backend/tb.zig:212` parses `//! noise table(<row>,<col>)#<src> … interp=linear\|log points=…` and the generated testbench asserts the topology byte-exact — `181_noise_table_topology.va`, `182_noise_table_log_topology.va` and two `a06_ntab` fixtures, none in the FAIL/XFAIL list. **The zero residual remains correct and untouched** (`lib/backend/codegen.zig:5754-5762`); §4.6.4 sources contribute in small-signal noise analysis only — **do not re-report it as the gap.** The residual gap is now *downstream of VerA*: `a06_noisetables_SPEC.md` documents that the host never reads `noise_tables`, so `onoise_spectrum == 0.0` on all four `.sp` decks — which are outside measure A (§1.1 b′) |
| AMS-08 | §4.6.4.4 `noise_table_log` | **verified** | No longer UNCITED. `182_noise_table_log_topology.va` and `a06_ntab_log.va` both pass; `lib/backend/tb.zig:502-503` rejects any `interp` but `linear`/`log`, so the log spelling is pinned and not merely present. `a06_ntab_log_interior.expected.json` states the discrimination: applying §4.6.4.3's linear rule to the same knots is "a factor of 2 off, so this fixture separates the two clauses rather than merely exercising a lookup" |
| AMS-09 | §9.21 `$table_model` quadratic/cubic spline modes and fatal extrapolation | **verified** | **The "missing, loudly" citation no longer exists.** `lib/backend/table_kernels.zig` is 476 lines (was 192) and `:23-26` now reads "interpolation (Table 9-30 `D`, `1`, `2` or `3` … then the low and the high extrapolation character (Table 9-31 `C`, `L` or `E`)". `zTabSpline1` (`:158`) implements §9.21.4's cubic (Thomas sweep on the moments) and quadratic splines with `L`→natural and `C`→zero end derivative; `zTabSplineDim` (`:294`) recovers the gradient so the Jacobian gets the spline slope, not a secant. `ztExtrapError` (`:40-43`) is Table 9-31 `E` as a **runtime fatal**, `ztDuplicateError` (`:57`) is §9.21's conflicting-duplicate rule. `lib/ir/lower.zig:9841` accepts `D123` and `:9850` accepts `CLE`; the dependent column is Table 9-32's sub-string arithmetic (`col + sel - 1`, `:9876`) — the recorded `nd + sel - 1` defect is gone. Thirteen fixtures `a05_01`…`a05_13` plus `a05_two_dependents.tbl`, **none in the FAIL/XFAIL list**. **`ch09_system_tasks/COVERAGE.md:96-98` is stale** — it still says `D`/`2`/`3`/`I`/`E` are refused at E0815 |

**§4.5 tally:** missing 5 · partial 0 · implemented-without-evidence 1 ·
verified 3 = **9 rows**.
Was: missing 6 · partial 1 · implemented-without-evidence 1 · non-normative 1 ·
verified 0.

## 5. Separation of obligation kinds

The plan requires these five be classified differently from one another. They
are mixed together in the current documents; this is the separation.

### 5.1 Mandatory

Everything in Section 4 not listed in 5.2–5.5. §2.8.3 and §9.1 make the whole of
1364 Clauses 17 and 18 mandatory for this target. **Annex C does not reduce
this set** — C.11 narrows the *Verilog-A subset*, which is a different, optional
language. **Annex G is historical** and creates no obligations; the three
`annex_g_change_history` rejection fixtures that cite G.2 (`04_obsolete_forever`,
`06_obsolete_generate`, `G.2.4`) pin removals whose normative force is in the
grammar (Annex A), not in G.

### 5.2 Optional

| Item | Why | Reference |
|---|---|---|
| The Verilog-A analog subset as a whole | Annex C is a subset definition for tools that choose it. VerA does not. | Annex C |
| IEEE 1364 Annex C additional utilities | informative in the inherited standard; their presence elsewhere does not make them mandatory | plan D09 note, adopted |
| SystemVerilog additions | explicitly a separate target | plan preamble |

### 5.3 Implementation-defined — requires a document *and* a test

| Item | Choice made | Documented? | Tested? |
|---|---|---|---|
| `$fflush` is a no-op because writes are unbuffered and positional | unbuffered | yes, `file_kernels.zig:384-389` | yes, `052_fflush.va` (on the descriptor, which is all §9.5.6 leaves observable) |
| `$ferror` errno values | C errno where an obvious match exists | yes, `file_kernels.zig:139-151` | deliberately **not** asserted — correct, §9.5.7 fixes no value |
| `$stop` implemented as print-and-exit-0 in a batch artifact | print-and-exit | yes, `cg_display.zig:249`, with the upgrade path named | yes, `174_stop_terminates.va` — but the test pins the *simplification*, not the clause |
| Table E.1 primitive Behavior for `diode`/`bjt`/`mosfet`/`jfet`/`mesfet`/`tline` | E.2 makes these "implementation dependent" | yes, in each `primitive_*.va` header | port order and parameter names only, correctly |
| Table E.1 `inductor` row printed as `I = l * integral(V)` where physics divides | fixture uses `l = 1`, the one value where both readings agree | yes, `annex_e_spice/COVERAGE.md` | declines to decide — correct |
| SPICE flavor read by `src/frontend/spice_cards.zig` | one flavor, `.MODEL`/`.SUBCKT` | partly | E.1.1's antecedent is made true for one flavor; the flavor is not named in a support statement |

Gap: there is no single published list of implementation-defined choices. Q04
requires the published support statements to match the shipped combination.
**This table should become that list.**

### 5.4 Resource limits — must be stated and must fail loudly

**Re-derived at HEAD, 2026-09-21.** Two bounds moved from 512 to 4096 and gained
fixtures, a fifth limit was found unenumerated, and one citation died with
`2cc1c08`.

| Limit | Value | Where | Fails loudly? | Tested? |
|---|---|---|---|---|
| Output channels via mcd | 30 | `lib/backend/file_kernels.zig:71` | yes — `EMFILE`, returns 0 (`:103-105`) | **no** — no fixture opens 31 channels |
| Scan/`$fgets` line buffer | **4096** bytes (was 512) | `lib/backend/file_kernels.zig:64`, rationale `:59-63` | splits a record across two reads rather than truncating — documented, not loud | **partly** — `s01_13_long_record_is_not_truncated.va` passes and pins a 601-byte `$fgets` in one call; the bound itself (4097) is unpinned |
| Formatted-string scratch buffer | **4096** bytes per site (was 512) | `lib/backend/str_kernels.zig:743-748`, rationale `:736-742` | overrun formats to the empty string, not a truncation — §9.5.3 gives no truncation rule | **partly** — `s01_13:86` pins a 601-byte record through this buffer |
| Scan leading-white-space window | 4096 bytes | `lib/backend/file_kernels.zig:313-315` | **unknown** | **no** — a fifth limit, unenumerated before this re-derivation |
| Descriptor table scope | one per device image, shared by instances | `lib/backend/file_kernels.zig:73-77` | n/a | **no** — needs a two-instance fixture |
| Distribution count range | 1..2147483647, integral only | `lib/backend/rng_kernels.zig:78-81` — **was `RNG-REFERENCE-LIMITS.md:25-28`, deleted in `2cc1c08`** | yes — named diagnostic, never truncation | yes, `189_rng_*_rejected.va` ×4 |
| Stateful-operator history capacity | — | plan A04 | plan states "silently forgetting history is not a valid implementation-defined limit" | **open** |

The RNG row is still the template: a stated bound, a loud failure, and a fixture.
The outstanding work is **the 31-channel exhaustion, the two-instance descriptor
table, and the newly-enumerated white-space window**. The two buffer rows are no
longer untested, but "partly" is the honest word — `s01_13` pins that a long
record *survives*, not what happens at the bound.

### 5.5 Unspecified — a test may not assert one outcome

| Item | Reference |
|---|---|
| `$ferror` errno numeric value | §9.5.7 "an error code is returned" |
| Reference Erlang/Student-t inf/NaN production, Poisson precision loss | 1364 §17.9.3 listing preserved verbatim; `lib/backend/rng_kernels.zig:80-81` (**was `RNG-REFERENCE-LIMITS.md:29-34`, deleted in `2cc1c08`**) |
| Digital race outcomes | plan: "Test nondeterministic digital behavior against the permitted outcomes; do not assert one arbitrary race order" |
| §2.8.3 acceptance of unregistered `$fixture_*` names | neither required to accept nor to reject; `ch11_vpi/COVERAGE.md` records three fixtures that were corrected for assuming otherwise |

### 5.6 Non-normative

`annex_g_change_history` in its entirety (informative), `annex_h_glossary`,
the §1.x overview prose, §11.5.x diagram legends, and §11.1–11.3 C-API mechanics
narrative. These correctly carry no obligation. 12 of `ch11_vpi`'s 39
sections are already marked this way in its `COVERAGE.md` and that is right.

**Withdrawn 2026-09-21: `$receiver_count` is not non-normative.** The 2026-09-16
text listed "§9.22.1's `$receiver_count` paragraph (marked 'Non-normative' in the
LRM itself)" here. The string does not occur anywhere in `docs/ch9-system.html`
at HEAD. §9.22.2 — the subclause renumbered, see §4's preamble — is normative,
carries its own Syntax 9-18 box at `docs/ch9-system.html:1621-1625`, and Table
9-19 at `:278` marks it `Yes`/`Yes`, making it **the only driver-access function
supported in the analog context of a connect module**. The reading came from the
2.4 transcription that `2cc1c08` removed, and the fixture built on it
(`annex_g_change_history/08_new_receiver_count.va`) went with it;
`ch09_system_tasks/COVERAGE.md:103` records the contamination. The row is now
`missing` — see **AMS-05**, and §7.3 item 12 for the two source comments that
still repeat the withdrawn claim.

---

## 6. Rejection-fixture audit

> **NOT re-derived at HEAD — this section is 2026-09-16.** Its population is 452
> rejection fixtures of 1301; at HEAD it is **477 of 1558**, and the share fell
> from 34.7% to 30.6%. The 25 rejection fixtures added since have not been
> classified illegal-source vs legal-but-unsupported. The §4 re-derivation did
> settle one row §6.2 left open — E0323 — and one it did not have: **17.2-12's
> `169_sscanf_uppercase_conversion_rejected.va` is neither kind.** §9.5.4.2 makes
> an invalid conversion character "implementation dependent", so that fixture
> pins a *documented choice*, not a prohibition. §6's two-way split has no box
> for that and needs a third.

Q02: "distinguish illegal source from legal-but-unsupported source. A rejection
fixture must not count as positive coverage of that feature."

### 6.1 The suite already measures this — use it

`zig build torture -- --coverage` partitions cited clauses into
**tested both ways** (148), **accepted only** (208) and **refused only** (99).
The harness's own report text names the hazard:

> REFUSED ONLY — every fixture citing these is a `//! reject`. The compiler is
> held to what the clause FORBIDS and to nothing it requires, which a passing
> score reads exactly like implementing it.

**The 99 refused-only clauses are the Q02 worklist.** They are not all defects —
a clause that states only a prohibition belongs there. But these do not:

- **§4.2.6 Case equality operators** — see 6.2. Over-rejection.
- **§7.3.2 / §7.3.2.1 / §7.3.4 / §7.3.5 / §7.3.6.1–.4 / §7.3.7** — nine
  mixed-signal clauses whose only evidence is a refusal. §7.3.2 *requires*
  `===`, `!==`, `case`/`casex`/`casez` and x/z digits.
- **§3.7 Real net declarations** (`wreal`) — legal in AMS, refused as E0205.
- **§5.10.3.4 absdelta** — see 6.3.
- **§5.10.5 Digital events in analog behavior**, **§5.10 Analog event control**,
  **§5.6 Contribution statements**, **§5.6.7.2**, **§5.6.8.2**.
- **§6.5.3 Real valued ports**, **§6.5.7.1**, **§6.6.3**, **§6.9.4**.
- **§8.5 and §8.5.3.4** — the digital scheduling clauses.
- **§9.5, §9.6, §9.8, §9.9** — file I/O, timescale, PLA, stochastic queues: the
  refusal is the correct *analog-context* verdict and is **no evidence at all**
  about the digital context these clauses actually govern.
- **§9.22.1–.3, §9.23.1–.4** — driver access; see AMS-03/04.
- **§11.2.1, §11.4, §12.2–§12.36** — 38 VPI clauses. Every one of them is
  `refused only`, and `ch11_vpi/COVERAGE.md:61-66` already states the correct
  conclusion: the results "do not assess conformity of the standard C API".
  **38 refused-only rows is the single largest block and it is 100% `missing`.**
- **§A.2.4, §A.2.7, §A.6.1, §A.8.5** — declaration assignments, task
  declarations, continuous assignments, expression lvalues.
- **§C.3, §C.5** — Annex C clauses whose refusal encodes the *subset*, not this
  target. See 6.2.

By contrast the following refused-only clauses are correct and complete as
prohibitions and need no positive side: §2.2 (lexical tokens), §2.9.2 (standard
attributes), §3.13.1/§3.13.3/§3.13.4 (namespace collisions), §E.3.1
(unsupported primitives — the LRM itself says these are not supported),
§G.2.1/§G.2.3/§G.2.4 (obsolete functionality).

### 6.2 The naming convention holds, with one exception in the *compiler*

The fixture tree already distinguishes the two cases by filename:
`*_rejected.va` for illegal source, `*_unsupported.va` for legal-but-unsupported
(`ch07_mixed_signal/COVERAGE.md:27-34` states the credit rule explicitly and
`ch08_scheduling` uses it consistently). Fixture headers argue the distinction
in prose — `annex_a_syntax/18_disable_statement.va` and
`annex_a_syntax/19_jump_statements.va` are model examples. **This is good and
should be kept.**

The exception is not a fixture, it is a diagnostic:

> `src/diag_code.zig:1754-1757`
> ```
> .E0323 => .{
>     .title = "case equality is not in the analog subset",
>     .lrm = "C.5",
> ```

E0323 refuses `===` and `!==` outright, titled after the **Verilog-A subset**
and referenced to **Annex C**. But:

- **§4.2.6**: "The case equality operators … have **limited support** in the
  analog block (see 7.3.2)." Limited support is support.
- **§7.3.2**: lists "the case equality operator (`===`)" and "the case
  inequality operator (`!==`)" among the features "Verilog-AMS HDL supports … 
  within the analog context", with a worked `a2d` module using `===` four times.

This is the stale analog-subset exemption Q01 says to remove, and it is in the
compiler, not only in a document. Four fixtures pin it as though it were the
rule: `ch04_expressions/29_case_equality.va`,
`annex_c_analog_subset/10_case_equality_rejected.va`,
`annex_c_analog_subset/17_case_inequality.va`,
`ch07_mixed_signal/case_equality.va`. Of these, only the two under
`annex_c_analog_subset/` are defensible — they test the *subset*'s rule, which
Annex C really does state. The other two credit §4.2.6 and §7.3.2 with a
refusal of what those clauses require.

The same shape, one level milder, applies to **E0130** (`diag_code.zig:892-895`,
"literal requires digital value support in the execution backend"). Refusing
`1'bx` in an analog *value* position is correct — §7.3.2's `converter` example
annotates exactly those lines `// error`. But refusing `4'b0x1z` as a *case item*
or as a `===` operand is over-rejection of §7.3.2's second and fourth bullets.
`ch07_mixed_signal/xz_case_statement_unsupported.va` is named correctly;
`ch02_lexical/05_xz_integer_rejected.va` and `24_question_digit_rejected.va` are
named as prohibitions and cite C.3.

### 6.3 Fixtures that blur the line

These pass, are honest in their headers, and still credit a clause with a
refusal. Each needs either a rename, a re-cite, or a companion positive fixture.

| Fixture | Pinned diagnostic | Blur |
|---|---|---|
| `ch05_analog_behavior/absdelta_digital_only.va` | E0513, whose title is literally **"absdelta() is not implemented"** (`diag_code.zig:3043-3044`) | The header is candid: "VerA's E0513 currently reads 'absdelta() is not implemented', which is the right verdict reached by the shorter route." A capability message is pinned in place of §5.10.3.4's placement rule, and the coverage report scores §5.10.3.4 as `refused only`. The fixture is fine; **the clause must not be counted.** |
| `annex_a_syntax/20_task_enable.va` | E0214 at the enable | The header records that VerA **also** emits E0205 "unsupported module item: found task" on a `task … endtask` declaration that A.2.7 makes **legal**. The fixture was corrected to pin E0214 so it stops asserting the wrong thing — but the incidental E0205 on legal source is a live over-rejection riding inside a green fixture. **The canonical example of the blur.** |
| `annex_c_analog_subset/14_digital_always_rejected.va` | E0205 on `always` | `always` is legal AMS. The `COVERAGE.md` says so ("pins VerA's ceiling"), the filename does not. Rename to `_unsupported`. |
| `annex_c_analog_subset/23_continuous_assign_rejected.va` | E0205 on `assign` | same |
| `annex_c_analog_subset/25_digital_procedural_rejected.va` | E0209 on `fork`/`join`/`wait` | same |
| `annex_c_analog_subset/22_nonblocking_assign_rejected.va` | `<=` | same |
| `annex_c_analog_subset/21_digital_event_control_rejected.va` | `posedge`/`negedge` | same |
| `annex_c_analog_subset/08_wreal_rejected.va` | E0205 on `wreal` | §3.7 makes `wreal` legal AMS; `COVERAGE.md:26` already says "full-AMS `wreal` remains open". Rename. |
| `annex_b_keywords/12_escaped_keyword_is_not_the_keyword.va`, `15_uppercase_keyword_rejected.va` | E0205 "unsupported module item" | These prove a *permissive* rule — that an escaped or uppercase keyword is an ordinary identifier — but reach it through an unsupported-feature error. A tool that lexed it correctly *and* supported the item would fail them. Weak evidence for a rule that is otherwise well covered. |
| `ch02_lexical/62_wide_literal_backend_boundary.va`, `63_unknown_decimal_backend_boundary.va` | E0130 | Named honestly as boundaries; the names carry no `_rejected`, so they read as positive fixtures in a file listing. |

### 6.4 One structural note on `//! reject` semantics

`//! reject <code>` pins a diagnostic code or a message substring. It does **not**
pin that the diagnostic is the *first* one, or the only one — which is how
`20_task_enable.va` can pass while an incidental E0205 fires on legal source.
A harness option to assert "no other diagnostic fired" would turn 6.3's whole
class into a mechanical check. Not proposed as work here; recorded because it is
the cheapest way to close this section permanently.

---

## 7. Tally and worklist

### 7.1 Obligations classified in this document — **measure B**

**Re-derived row by row at `a99a37f` on 2026-09-21.** This is the only
one of `ROADMAP.md`'s four measures with no command behind it. It cannot be
measured, so the next best thing is an arithmetic a reader can redo: **every
number below is a count of rows in §4, and each §4 subsection carries its own
tally that sums to its own row count.**

Where a row splits analog/digital, the **weaker** context sets the verdict and
the split is noted in the row.

| Section | Rows | missing | partial | impl-without-evidence | verified | resource-limit only | unspecified only |
|---|---|---|---|---|---|---|---|
| §4.1 §17.1 display | 17 | 5 | 5 | 5 | 2 | — | — |
| §4.2 §17.2 file I/O | 25 | 6 | 2 | 3 | 10 | 4 | — |
| §4.3 §17.3–§17.11 | 54 | 27 | 13 | 1 | 12 | — | 1 |
| §4.4 §18 VCD | 22 | 22 | — | — | — | — | — |
| §4.5 AMS additions | 9 | 5 | — | 1 | 3 | — | — |
| **Total** | **127** | **65** | **20** | **10** | **27** | **4** | **1** |

65 + 20 + 10 + 27 + 4 + 1 = **127**. Row counts expand the ranges:
`17.5-01…16` = 16, `17.6-01…05` = 5, `17.9-03…09` = 7, and **`17.11-02…23`, the
22 real math functions, counts as one row group** — the convention the 2026-09-16
text set, preserved so the two are comparable.

**Closed and open.** A row is *closed* when nothing further is owed: an
executable test pins the observable (`verified`), or the row is a resource limit
that is both stated and tested, or it is `unspecified` and correctly left
unasserted. Everything else is open.

| | Rows | Which |
|---|---|---|
| **closed** | **30** | 27 `verified` + 2 tested resource limits (17.2-14, 17.2-15) + 1 `unspecified` (17.9-13) |
| **open** | **97** | 65 `missing` + 20 `partial` + 10 `implemented-without-evidence` + 2 untested resource limits (17.2-04, 17.2-05) |

> ### Measure B at v0.0.2 — **30 / 127 closed, 97 open**
> Hand-read against this section, 2026-09-21, at `a99a37f`.
> Of the 30 closed, 27 are `verified`. Of the 97 open, **65 are `missing`** and
> 22 of those 65 are the whole of §18.

#### Why this is not "36 / 119", and why that number could not be reproduced

`ROADMAP.md §2`, `CHANGELOG.md`'s v0.0.1 entry and `AGENTS.md §2` all quote
measure B as **36 / 119** from this document's 2026-09-16 text. **That
arithmetic does not close, and restoring the file is what revealed it.** The old
§7.1 verdict table read missing 63 · partial 11 · implemented-without-evidence 9
· verified 30 · optional 3 · implementation-defined 6 · non-normative 5, which
sums to **127** — while its own closing sentence said "Section 4 total: **119**
obligation rows, of which 63 missing, 11 partial, 9 implemented-without-evidence,
30 verified", and *that* sums to 113. Three different totals in one table.

The 119 is reconstructible as 127 − 3 optional − 5 non-normative, with 36 closed
as 30 `verified` + 6 `implementation-defined`. That is a coherent reading and it
is probably what was meant. **It is not adopted here**, for one reason: those 14
optional / implementation-defined / non-normative counts are drawn from the §5
tables, and §5's members are *not* §4 rows — §5.2's three items are "the
Verilog-A analog subset as a whole", "IEEE 1364 Annex C additional utilities" and
"SystemVerilog additions", none of which is an obligation row in §4. The old
§7.1 mixed §5 into a table whose header says "Rows in Section 4". A denominator
that needs that much reconstruction is not checkable, which is the one thing
release v0.0.2 exists to fix.

**So the denominator changed from 119 to 127 and the rule for "closed" changed
with it. B did not regress; it was re-based.** Comparing like with like, on the
127-row denominator and the rule above, the 2026-09-16 tree scored **31 closed**
(30 `verified` + 1 `unspecified`; no resource limit was tested then) against
**30** today. The one-row net conceals real movement in both directions:

| | Rows | Cause |
|---|---|---|
| gained | +2 | `s01_13` tested two resource limits (17.2-14, 17.2-15) |
| gained | +8 | digital work landed — 17.1-01, 17.1-10, 17.7-01, 17.11-01 upgraded; AMS-07, AMS-08, AMS-09 closed on splines and noise tables |
| lost | −5 | verdicts that were **wrong on 2026-09-16**, not regressions: 17.2-03 (the cited fixture does not observe channel reuse), 17.1-08/17.1-09 (analog/digital halves conflated), 17.10-01/17.10-02 (Table 9-9's digital column is `Yes`) |
| lost | −6 | **`2cc1c08` deleted the evidence.** 17.9-10 lost the differential C oracle; 17.1-03 lost `test-literal-output`; 17.8-01's prohibition was withdrawn with the 2.4-contaminated fixtures; AMS-05 with them |

**The second loss column is the finding of this release.** Six closed rows were
opened by a docs commit, not by a code change. See the provenance block at the
top of this file.

### 7.2 Independent measure, from the LRM side — **measure C**

**This document no longer owns these numbers.** `tools/conformance.sh` writes
them into `CHANGELOG.md` from `zig build benchmark -- --coverage`, and
`publish.yaml` re-measures them on a clean runner. Reproduced here as the
cross-check they have always been, measured 2026-09-21 at `a99a37f` and re-confirmed at `05ae554`:

| | 2026-09-16 | **2026-09-21** | Meaning for this audit |
|---|---|---|---|
| clauses known to the harness | 611 | **612** | the denominator |
| tested both ways | 148 | **196** | the only category that can support a `verified` |
| accepted only | 208 | **257** | nothing pins what the clause rules out |
| **refused only** | 99 | **76** | **cannot be positive coverage** — §6.1 worklist |
| uncited | 156 | **83** | unexamined; per the plan, therefore open |

`ROADMAP.md` Appendix A item 1 settles this conflict in favour of the measured
run and records that the widely quoted "463 clauses remaining" is **416**. Do not
re-litigate it from this document's 2026-09-16 column.

**The two measures still do not add up to each other and must not be made to.**
The 612 are AMS clauses; the 127 are inherited-1364 obligations the AMS clause
list does not contain. §1.1 c is the reason, and it is unchanged: `--coverage`
walks `docs/ch*.html` and `docs/annex-*.html`, so Clause 17 and Clause 18 are
outside its denominator entirely. **A complete VCD implementation and no VCD
implementation still produce the same coverage report** (§7.3 item 9).

### 7.3 Immediate worklist, cheapest first

**Walked at HEAD 2026-09-21.** Items 1–4 act on §3, which was not re-derived, so
their targets moved; each says how. Items 10–12 are new and come from the §4
re-derivation.

| # | Item | State at HEAD |
|---|---|---|
| 1 | **Recount five `COVERAGE.md` headers** (§3.1) and add the unmentioned fixtures to their chapter tables | **open, re-scoped.** The "52 unmentioned fixtures" was against 1301; the tree is 1558 and the 22 `COVERAGE.md` files grew 3694 → 4174 lines. The count must be retaken before the work is done, not after |
| 2 | **Fix `ch09_system_tasks/COVERAGE.md:37`** — "`06` does not compile" is false | **open, citation dead.** That file was rewritten since 2026-09-16 and `:37` is now other text. The underlying claim is still worth fixing; find it by content, not line |
| 3 | **Qualify the `$monitor` and `$debug` credits** at `ch09_system_tasks/COVERAGE.md:34` | **open, re-scoped.** 17.1-12 is no longer `missing` — it is `implemented-without-evidence` in analog and `verified` in digital. 17.1-14 `$debug` is still `missing`. The qualification is now *narrower* than the item asks for |
| 4 | **Fix `annex_e_spice/COVERAGE.md:274,290-292`** — "43 not 41 files" | **open, both numbers stale.** The directory holds **56** `.va` files at HEAD. The `//! temp` argument the item raises is unaffected and still stands |
| 5 | **Rename the seven `annex_c_analog_subset/*_rejected.va`** whose constructs are legal AMS (§6.3) to `_unsupported` | **open, not started.** 16 `_rejected.va` and **0** `_unsupported.va` in that directory at HEAD |
| 6 | **Add the three missing resource-limit fixtures** (§5.4) | **partly done, and the list grew to four.** `s01_13_long_record_is_not_truncated.va` covers the long input line and the long formatted string — both bounds also moved 512 → 4096. Still open: two instances opening files, 31-channel exhaustion, and the newly-enumerated white-space window |
| 7 | **E0323, the stale analog-subset exemption inside the compiler** (§6.2) | **open, now named in measure A.** `lib/ir/lower.zig:8120`. It is XFAIL `annex_a_syntax/66_case_equality_in_analog.va` — "§7.3.2 lists both case operators as supported there". D-track work; recording it is this document's job and it is recorded |
| 8 | **Add IEEE 1364-2005 to `docs/`** or confirm §§17–18 numbering another way | **open.** `2cc1c08` swapped the AMS LRM 2.4 PDF for the 2023 one; the *inherited* standard is still absent, so §4's subclause numbers remain structural rather than citable |
| 9 | **Teach `--coverage` about the inherited clauses** | **open, and it is the reason measure B has no command.** Until it is done, §7.1 is hand-read and this document is the only artifact that can move B |
| **10** | **Restore the twelve tests `2cc1c08` deleted that are still gone** | **NEW, and owned by no release.** Fourteen test files and `tools/source_guards.zig` went in one docs commit. `6f2e1c5` restored the VPI three — because `build.zig` still referenced them and the build broke. The other **twelve took their own build steps down with them**, so nothing broke: the six RNG files, the three `literal_nul` files, `limiter_host.zig`, `table_snapshot_host.zig`, `source_guards.zig`. `zig build test-rng-reference` and `zig build test-literal-output` no longer exist. It cost six closed rows in §7.1. **Not v0.0.2 work** — v0.0.2 changes no code — and there is no row for it on the ladder |
| **11** | **Three documents still assert the pre-re-derivation reading of §18** | **NEW.** `ROADMAP.md:447` says 18.1-01/18.1-06 are unblocked file handling (they are blocked on digital-side file I/O — §4.4); `MANIFEST.md:59` says `grep -rn 'dumpvars\|dumpfile' tests/` returns 0 hits (it returns 7). Both are cheap corrections |
| **13** | **492 lines of new accept-surface landed with zero two-way evidence** | **NEW.** Between tag `v0.0.1` and `a99a37f`, `lib/frontend/parser.zig` (+401), `ast.zig`, `token.zig`, `diag_code.zig` and `src/sim/digital.zig` changed — "A.3.1's other three switch arms, which were E0205 for a grammar that has them", "A.5.3's table was validated and then thrown away", §3.7 `wreal`. **Measure C did not move**: 612 clauses split 196/257/76/83 at both endpoints, both measured. Source VerA newly accepts is by `AGENTS.md`'s own rule a **minor**, and the grammar arms it opened are pinned by no fixture. Chasing them is measure-C work and belongs at v0.2.1 or later (`ROADMAP.md §5`); recording it is this document's job. See also `fixture_fixes.md`, added in `a99a37f` |
| **14** | **The `.v` tree writes four directives the `.va` tree never taught the parser** | **NEW, from v0.0.3. Corrected 2026-09-21 — the first version of this row got the causes wrong and is restated here.** Eight of the twelve `.v` fixtures the widened walk now reads FAIL on their own header, and they do it for **four** reasons, not one. Measured, not inferred: <br>• **`lrm annex A.2.2.2`** — 4 rows (`d03_12`, `d03_13`, `d06_reject_delay4`, `d06_reject_intra_assign_on_net`). `validSection` (`lib/backend/tb.zig:428-435`) takes a single letter `A`–`H` then digit parts, so `A.2.2.2` is **valid** and the word `annex` in front of it is not. **107 `.va` fixtures write the bare form and none writes `annex`** — this is a spelling divergence between the two trees, and the cheapest of the four to close. <br>• **`lrm inherited IEEE 1364-2005 18.1`** — 2 rows (`d09_11`, `d09_12`). This one *is* a real vocabulary gap: an inherited clause must not enter `--coverage`'s AMS denominator (§1.1 c), so these cannot use the AMS spelling, and there is no other. Same hole as item 9 from the fixture side. <br>• **`//! rule`** — 2 rows (`d09_90`, `d09_91`), prose stating the obligation. <br>• **`//! data`** — `d09_91` also. <br>**`//! expect vcd` is not among the causes.** It sits on `d09_11`/`d09_12`, which fail on the `lrm` line before the parser reaches it |
| **15** | **Every `.sp` deck's `.hdl` reference is dangling** | **NEW, from v0.0.3.** All 7 decks name models through an `.assets/` subdirectory that does not exist — `a10_host.assets/a10_vsine.va` is filed as `a10_host.assets_a10_vsine.va`, `/` turned into `_`. That is `collect`'s slug rule applied to the *tree*, so a nested layout was flattened and the decks were not updated with it. `test-spice` resolves it with a documented fallback rather than renaming six fixtures on a guess about the old layout; un-flattening the tree makes the fallback dead code, which is the tell that it should be un-flattened |
| **12** | **Four in-tree claims the §4 re-derivation found false** | **NEW.** `lib/ir/lower.zig:7597-7600` still calls `$receiver_count` "Non-normative" and cites a fixture deleted in `2cc1c08` (AMS-05); `ch09_system_tasks/COVERAGE.md:96-98` still says §9.21's splines and `E` extrapolation are refused at E0815 (AMS-09 — they are implemented); `COVERAGE.md:78` still says `$rtoi`/`$itor` are unimplemented (17.8-01 — both are, at `lib/backend/codegen.zig:6043`/`:6049`); `COVERAGE.md:50` still cites the deleted `zig build test-literal-output` (17.1-03) |

### 7.4 What this audit did not do

- **No `.zig` source was modified, and no fixture was added, renamed or deleted** —
  by either pass. Release v0.0.2 changes no code; `ROADMAP.md §4` scopes it that
  way deliberately.
- **§3 and §6 were not re-derived at HEAD.** Both carry a banner saying so. §3's
  counts are against 1301 fixtures and 3694 lines of `COVERAGE.md`; §6's
  population is 452 rejection fixtures of 1301, now 477 of 1558.
- **The `.v`, `.c` and `.sp` populations were outside measure A when §4 was
  re-derived, and release v0.0.3 changed that.** See §1.1 b′ for the new shape.
  Twelve `.v` joined measure A (1558 → 1570); the 26 `.c` and 7 `.sp` got their
  own steps. **No §4 verdict below was re-read against the widened suite**, and
  two rows are known to be affected: §4.4's three VCD fixtures now FAIL visibly
  on their own directive headers, and 17.2-21's `d09_91` is still scored by
  nothing (§7.5 item 3). Neither changes a verdict — a fixture that fails on its
  header asserts nothing — but a re-read is owed.
- **ARPice host numbers were not re-measured.** They are not measurable from this
  worktree, and `docs/CONFORMANCE-GAPS.md` — which held them — is deleted. Its
  disposition is settled in §7.6 below.
- A clause-by-clause re-read of chapters 1–8 and 10 against the LRM HTML — the
  full Q01 obligation expansion for the *AMS* clauses, as opposed to the
  inherited ones — is still not done. §7.2's 83 uncited and 76 refused-only
  clauses are the entry points, and `ROADMAP.md` schedules them as v0.2.1,
  v0.6.2 and v0.9.1.
- X01 native-device compatibility is deliberately out of scope, per Q01.

### 7.5 Questions the re-derivation could not settle

Recorded rather than guessed. Each would change a §7.1 row.

1. **17.1-06's analog half — a contradiction inside this repository.** §4.1 as
   written says §7.3.2 makes `x`/`z` legal analog display operands, which makes
   E0130 a refusal of a legal construct (`missing`).
   `tests/fixtures/ch09_system_tasks/s01_SPEC.md` says the refusal is *correct*
   because Table 9-1 does not make four-state values an analog-context concept
   (`verified on the prohibition`). Under §2's own rule those are different rows.
   Settling it needs §7.3.2 read in `docs/ch7-mixed.html`.
2. **17.10-01/17.10-02 are a convention consequence, not a regression.** Nothing
   about `$test$plusargs`/`$value$plusargs` got worse; the "weaker context sets
   the verdict" rule was applied to Table 9-9's `Yes Yes` digital column, which
   the 2026-09-16 pass did not do. If §17.10 is meant to be analog-scoped the way
   §17.9 and §17.11 are — each of which has an explicit separate digital row
   (17.9-14, 17.11-24) — then §17.10 needs a `17.10-03 digital` row, those two go
   back to `verified`, and the total becomes 128.
3. **`tests/fixtures/digital/d09_91_readmem_overflow_rejected.v` is now scored,
   and fails for a reason that is not §17.2.9.** v0.0.3's widened `collect`
   takes it — it carries `//! reject` and has no `.expected.txt` — and it FAILs
   on `UnknownDirective`, not on excess data. Its data file also still sits in
   `ch09_system_tasks/` while `readSideFile` looks beside the `.v`, so even a
   fixture whose header parsed could not load it. **17.2-21's `partial` is
   unchanged**: the row rests on `d09_08`/`d09_09`, which pass under
   `test-devices`, and on excess data being silently dropped, which no fixture
   pins either way. Whether §17.2.9 *requires* an error on excess data still
   cannot be settled without IEEE 1364-2005 (item 8).
4. **AMS-06 `driver_update`: `missing` vs `partial` is a judgement, not a
   measurement.** It parses, survives elaboration's cloner, and is E0701 only in
   value position. `missing` was chosen because §9.22.5's whole obligation is that
   the statement *executes* on a driver update and none of that exists; parsing
   is not "some of the clause". If the house rule counts a surviving AST path as
   partial, the row flips.
5. **Whether a kernel unit test can support `verified`.** `zMonitor` (17.1-12)
   and `zCReal` (17.1-04) have runtime unit tests at the exact boundary the
   emitted device calls. They were treated as sufficient where the observable is
   rendered text and insufficient where it is per-accepted-step. §2 does not say
   which side of that line a kernel test falls on.
6. **Whether `.v` transcript evidence may support `verified` at all.** Four
   upgrades (17.3-01, 17.7-01, 17.11-01's digital half, 17.11-24) rest on
   `zig build test-devices`, which is outside measure A and **currently FAILs at
   47/66** — though no `d09_*` case is among its failures and each was re-diffed
   individually. If "executable test" is meant to mean "inside `zig build test`",
   those four weaken. 17.7-01, 17.7-03 and 17.4-03 survive it on
   `src/sim/digital.zig:3478`/`:3522`, which *are* in `zig build test`.

### 7.6 `docs/CONFORMANCE-GAPS.md` — retired, not rebuilt

`ROADMAP.md` Appendix B and §7 decision 7 leave this open. **Decided 2026-09-21:
retire it.** It was 57 lines, deleted in `2cc1c08`, and `TODO.md §3.6` already
described it as stale before the deletion — 375 units, 1313 fixtures, 295 host
units, none of which survives contact with a 1558-fixture tree.

Rebuilding it would recreate a fourth place where a conformance number lives,
which is the precise failure this ladder exists to end: `AGENTS.md §0` rule 1
says numbers are measured, not typed, and `CHANGELOG.md` is the output. Its two
distinct contents are better homed elsewhere and both already have owners:

- **The published list of implementation-defined choices** — its one obligation
  nothing else carries — is **§5.3 of this document**, which already says "this
  table should become that list". `ROADMAP.md` schedules publishing it as
  **v0.9.2**, together with the stated resource limits in §5.4.
- **ARPice host gap counts** are not measurable from this worktree and never
  were. They belong to ARPice, and `ROADMAP.md §6` already tracks what is
  blocked on it.

What is lost is the ARPice plan's inbound link. That is a broken link in another
repository, not a reason to carry a stale document in this one. **Anything that
cited `CONFORMANCE-GAPS.md` should now cite §5.3 and §5.4 of this file.**
