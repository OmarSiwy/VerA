# Clause audit — Q01 complete requirement inventory

Owner: Q01 in [the implementation plan](../../ARPice/docs/verilog-ams-conformance-plan.md).
Status: **open**. This document is the inventory, not the result.

This is an audit artifact. It records what was checked, against what, and with
what evidence. It does not change the compiler and it does not close anything.
Where it disagrees with another document in this repository, the disagreement is
written down here with a `file:line` citation so the other document can be fixed
rather than argued with.

**Nothing in this file is a conformance percentage.** Fixture counts are counts
of files. 1301 fixtures behaving as they say they do is a statement about 1301
files, 452 of which assert that the compiler *refuses* something.

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

Run on the `conf/audit` worktree at branch head, 2026-09-16.

```
$ zig build torture -- --strict
vera: 1301/1301 fixtures behave as they say they do          (exit 0)

$ zig build torture -- --coverage
455 of 611 LRM clauses cited, by 1231 of 1301 fixtures
  148 tested both ways · 208 accepted only · 99 refused only · 156 uncited
```

Measured over the fixture tree, not quoted from any document:

| Quantity | Value |
|---|---|
| `.va` fixtures | 1301 |
| carrying `//! reject` | 452 (34.7%) |
| carrying `//! xfail` | 0 |
| carrying `//! lrm` | 1232 |
| AMS LRM clauses the harness knows about | 611 |
| clauses with a positive *and* a negative fixture | 148 |
| clauses whose only fixture is a rejection | 99 |
| clauses no fixture names | 156 |

### 1.1 Three facts about that baseline that change what it means

**a. `zig build test` does not run the fixture suite.** `build.zig:462` puts the
fixture walk behind its own `torture` step; `build.zig:464-468` adds only the
*runner's unit tests* to `test`, and says so in a comment:

> the runner's own unit tests (the assertion lint, the verdict tally) DO belong
> in `test`

`grep -n 'test_step' build.zig` confirms no dependency on `run_torture`. Any
"1,301 fixtures pass" claim sourced from a `zig build test` summary is
unsupported. The number above is real, but it came from `zig build torture`.

**b. A third of the suite is refusal.** 452 of 1301 fixtures assert that the
compiler emits a diagnostic. Per the plan's completion rules, a rejection
fixture must not count as positive coverage. Section 6 separates the ones that
pin an LRM prohibition from the ones that pin VerA's ceiling.

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

This deepens the D09 table in the plan, which has one row per clause group and
marks every row "open". Here each row is one independently reviewable
obligation with a verdict and a reason.

**Caveat on numbering.** IEEE 1364-2005 is not in this worktree. Two subclause
numbers are confirmed by the AMS LRM's own cross-references — **17.2.7**
(`$ferror`, `docs/ch9-system.html`) and **17.9.3** (the distribution C listing,
`docs/ch9-system.html`, Table 9-26). The rest are from the inherited standard's
structure and must be re-checked against a copy of 1364-2005 before this table
gates anything. Clause and subclause *content* below is stated only where the
AMS LRM restates it or where the source settles it.

**Context matters and is a separate axis.** Every AMS Chapter 9 table has a
"supported in analog context" column. A name with `No` in that column is
correctly refused inside an `analog` block *and* is still required in the digital
context. `src/ir/lower.zig:6586-6635` (`isDigitalOnlySysFunc`) is the refusal
list; its doc comment is explicit that VerA has no context flag because "every
statement it ever sees is in the analog context". So for every name on that list,
**the analog verdict and the digital verdict are different rows**, and the digital
one is `missing` without exception.

The whole digital dispatcher is three names plus two casts:
`src/sim/digital.zig:58` (`$signed`, `$unsigned`), `:60` (`$display`, `$finish`),
and `:557` — "`$display` requires literal formats; only `%b` and `%%` are
implemented".

### 4.1 §17.1 — Display system tasks

| # | Obligation | Analog context | Digital context | Verdict | Reason / reference |
|---|---|---|---|---|---|
| 17.1-01 | `$display`, `$write` base spellings | present (`src/ir/lower.zig:5928-5932`) | `$display` only (`src/sim/digital.zig:60`) | **partial** | `$write` has no digital path; AMS §9.4.1 syntax 9-1 |
| 17.1-02 | `$displayb/o/h`, `$writeb/o/h` radix variants | refused, correctly (`lower.zig:6589-6592`, Table 9-1 `No`) | absent | **missing (digital)** / **verified (analog prohibition)** | two rows, not one; §9.2 Table 9-1 |
| 17.1-03 | 17.1.1.1 escape sequences | present; exact bytes pinned by `zig build test-literal-output` incl. NUL and octal | absent | **verified (analog)** / **missing (digital)** | AMS §9.4.2 Table 9-21 |
| 17.1-04 | 17.1.1.2 format specifications | present; `%e`, `%10.4e`, `%05d`, `%+05d`, `%+d`, `% d`, `%h` of a negative pinned against hand-derived C output by `171_display_c_format_flags.va` | `%b` and `%%` only (`digital.zig:557`) | **verified (analog)** / **missing (digital)** | AMS §9.4.3 Tables 9-22/9-23 |
| 17.1-05 | 17.1.1.3 automatic sizing of displayed data | n/a for real | absent | **missing** | needs D01/D03 packed values |
| 17.1-06 | 17.1.1.4 unknown / high-impedance display | `x`/`z` cannot reach a display operand (E0130) | absent | **missing** | §7.3.2 makes x/z legal operands in AMS |
| 17.1-07 | 17.1.1.5 strength format `%v` | absent | absent | **missing** | needs D03 drivers/strengths |
| 17.1-08 | 17.1.1.6 hierarchical name `%m`, takes no argument | compiles; `06_display_formats.va` and `161` use it unasserted | absent | **implemented-without-evidence** | `ch09_system_tasks/COVERAGE.md:37`; AMS §9.4.4 is in the UNCITED list |
| 17.1-09 | 17.1.1.7 `%s` ASCII-code output | pinned by `188_numeric_string*.va` and `test-literal-output` for byte order, widths, leading-zero suppression, interior/trailing NUL | absent | **verified (analog, integer operands)** / **partial overall** | real operands and packed digital expressions untested; AMS §9.4.5 |
| 17.1-10 | 17.1.2 `$strobe` at converged solution | present, `01_display_strobe.va` pins the accepted branch potential | absent | **verified (analog)** / **missing (digital)** | AMS §9.4.1 |
| 17.1-11 | 17.1.2 `$strobeb/o/h` | refused (`lower.zig:6590`) | absent | **missing (digital)** | |
| 17.1-12 | 17.1.3 `$monitor` re-displays only on a changed argument | **not implemented** — unconditional print at every accepted point (`codegen.zig:5562-5572`, `:2863-2872`) | absent | **missing** | AMS §9.4.1 states the rule verbatim, including the `$abstime`/`$realtime` exception and the "only one display" rule for simultaneous changes |
| 17.1-13 | 17.1.3 one active `$monitor`; `$monitoron`/`$monitoroff` | refused (`lower.zig:6593`) | absent | **missing** | |
| 17.1-14 | `$debug` displays per solver iteration | **not implemented** — same accepted-point unit as `$strobe` | absent | **missing** | AMS §9.4.1 and §9.4.6; `s9.4.6` row correctly says "no fixture" |
| 17.1-15 | §9.4.6 no display output except `$debug` unless the iteration is accepted | holds vacuously (all display is in the accepted-point unit) | n/a | **implemented-without-evidence** | the mechanism is right for the wrong half — nothing prints per-iteration at all, including `$debug` |
| 17.1-16 | Null argument (`,,`) produces one space | not checked | absent | **implemented-without-evidence** | AMS §9.4.1 states it; no fixture found |
| 17.1-17 | `$strobe` with no arguments prints a newline | not checked | absent | **implemented-without-evidence** | AMS §9.4.1 states it |

### 4.2 §17.2 — File I/O

| # | Obligation | Verdict | Reason / reference |
|---|---|---|---|
| 17.2-01 | 17.2.1 `$fopen` multichannel descriptor encoding | **verified** | `file_kernels.zig:130-133`; `158_fopen_multichannel_descriptor.va` pins bit 31 clear, one bit set, not bit 0 |
| 17.2-02 | 17.2.1 `$fopen` file-descriptor encoding, channels from 3 | **verified** | same; and 0 for a missing `r`/`r+` file |
| 17.2-03 | 17.2.1 `$fclose` frees a channel for reuse | **verified** | `158` observes the reuse |
| 17.2-04 | 17.2.1 at most 31 output channels via mcd | **resource limit**, stated | `file_kernels.zig:64-66`, `zf_max = 30`; exhaustion returns 0 and sets `EMFILE` (`:98-100`) — loud, not silent |
| 17.2-05 | 17.2.1 descriptor table is per *device image*, shared by instances | **resource limit**, stated, **untested** | `file_kernels.zig:69-73` ponytail comment names the ceiling and the upgrade path. No fixture runs two instances that both open files |
| 17.2-06 | 17.2.2 `$fdisplay`/`$fwrite`/`$fstrobe`/`$fmonitor`/`$fdebug` | **partial** | argument values pinned; bytes pinned only indirectly via write-then-read (`046`/`049`/`050`/`051`/`054`/`11`). `$fmonitor` inherits 17.1-12's missing change detection; `$fdebug` inherits 17.1-14 |
| 17.2-07 | 17.2.2 `$fdisplayb/o/h`, `$fwriteb/o/h`, `$fstrobeb/o/h`, `$fmonitorb/o/h` | **missing (digital)** | refused in analog (`lower.zig:6596-6600`), Table 9-2 `No` |
| 17.2-08 | 17.2.3 `$sformat`, `$swrite` | **verified** | `06`/`09` round-trip the text through `$sscanf`; lowering makes both an assignment, so a writer that wrote nothing fails |
| 17.2-09 | 17.2.3 `$swriteb/o/h` | **missing (digital)** | `lower.zig:6600-6601` |
| 17.2-10 | 17.2.4 `$fgets` returns the count *including* the newline | **verified** | `046_fgets.va`; four-byte line returns 4 |
| 17.2-11 | 17.2.4 `$fscanf`/`$sscanf` conversion rules, suppression, max field width, early match failure, EOF | **verified** | `048`, `162`, `047`; one scanner (`zScan`) for both spellings per §9.5.4.2 |
| 17.2-12 | 17.2.4 scan conversion codes are lower case | **verified** | `169_sscanf_uppercase_conversion_rejected.va`, E0813 — a genuine illegal-source rejection |
| 17.2-13 | 17.2.4 `$fgetc`, `$ungetc`, `$fread` | **missing (digital)** | `lower.zig:6601-6602`; `$ungetc` interaction with `$fseek` untestable while absent |
| 17.2-14 | 17.2.4 scan input line buffer | **resource limit**, stated | `file_kernels.zig:59` `line: [512]u8`. Behavior on a longer line is **not pinned by any fixture** — needs one |
| 17.2-15 | 17.2.3 formatted-string scratch buffer | **resource limit**, stated | `str_kernels.zig:245-248`, `[512]u8` per site |
| 17.2-16 | 17.2.5 `$ftell`, `$fseek`, `$rewind` | **verified** | `049`/`050`/`051`/`11`, each asserting a moved *and* an unmoved pointer, plus the status return separately |
| 17.2-17 | 17.2.6 `$fflush` | **verified (vacuously)** + **implementation-defined** | `file_kernels.zig:384-389`; unbuffered positional writes make it a conforming no-op. The *choice* to be unbuffered is implementation-defined and is documented here |
| 17.2-18 | 17.2.6 `$fflush` with no argument flushes all open files | **implemented-without-evidence** | same reason; no fixture calls the zero-argument form |
| 17.2-19 | **17.2.7** `$ferror` returns an error code and a description | **verified** | `053_ferror.va` pins both directions; the numeric errno is deliberately **unspecified** (§9.5.7 says only "an error code is returned") and correctly unasserted |
| 17.2-20 | 17.2.8 `$feof` | **verified** | `054_feof.va` puts the descriptor in both states; two `$fgets` are needed to reach EOF |
| 17.2-21 | 17.2.9 `$readmemb`/`$readmemh`: comments, addresses, ranges, direction, x/z, malformed and excess data | **missing** | `lower.zig:6602-6603` refuses in analog; no digital path. Blocked on D03 memories |
| 17.2-22 | 17.2.10 `$sdf_annotate` | **missing** | `lower.zig:6603`. Blocked on D07/D09 specify blocks |
| 17.2-23 | §9.5.1.1 reopening a write-mode file across analyses appends | **missing (untestable today)** | AMS-specific; the harness runs one analysis per process. In the UNCITED list |
| 17.2-24 | §9.5.1.2 descriptor sharing between analog and digital contexts | **missing** | no digital context to share with. In the UNCITED list |
| 17.2-25 | §9.5.9 file position rolled back on a rejected iteration, `$fdebug` excepted | **implemented-without-evidence** | `codegen.zig:2863-2872` sequences every §9.5 call in the accepted-point unit, so nothing writes during a rejected iteration. The *`$fdebug` exception* is therefore also not implemented — see 17.1-14 |

### 4.3 §17.3–§17.11

| # | Obligation | Verdict | Reason / reference |
|---|---|---|---|
| 17.3-01 | `$printtimescale`, `$timeformat`: scope, rounding, formatted output | **missing** | `lower.zig:6606-6607` refuses in analog per §9.6 ("Verilog-AMS HDL does not extend the timescale tasks"); no digital implementation. `src/sim/time.zig` validates decimal scales but no source-level task reaches it |
| 17.4-01 | `$finish` and its optional diagnostic level | **partial** | analog: `172_finish_terminates.va` proves termination and `cg_display.zig` derives the level (`finishLevel`, default 1). Digital: `digital.zig:537-542` accepts zero or one argument and **explicitly refuses level 2** — "only `$finish(0)`, `$finish(1)`, and `$finish` are implemented". The level's *diagnostic output* is not implemented in either context |
| 17.4-02 | `$stop` host behavior | **partial** | `174_stop_terminates.va` pins print-and-exit-0, which `cg_display.zig:249` names as a deliberate simplification with "a debugger hook" as the upgrade path. **implementation-defined and documented**, but the LRM's suspension semantics are absent |
| 17.4-03 | Scheduler and resource cleanup on `$finish`/`$stop` | **missing** | no test observes cleanup |
| 17.5-01…16 | PLA: 16 spellings of `$async`/`$sync` × `and`/`nand`/`or`/`nor` × `array`/`plane` | **missing** ×16 | `lower.zig:6612-6617`. §9.8: AMS "does not extend" them, which places them in the digital context only, where nothing implements them. `154_timescale_pla_queue_analog_rejected.va` pins the analog refusal and is **not** coverage of the tasks |
| 17.5-17 | PLA personality data, four-state logic, update timing | **missing** | |
| 17.6-01…05 | `$q_initialize`, `$q_add`, `$q_remove`, `$q_full`, `$q_exam` | **missing** ×5 | `lower.zig:6620-6622`; §9.9 same structure as PLA |
| 17.6-06 | Queue discipline (FIFO/LIFO), status codes, capacity, time statistics | **missing** | |
| 17.7-01 | `$time` — 64-bit, scaled to the caller's timescale | **missing** | `lower.zig:6626`; §9.10 Table 9-7 `No` in analog |
| 17.7-02 | `$stime` — 32-bit | **missing** | same |
| 17.7-03 | `$realtime` | **missing**; note §9.10 **deprecates** `$realtime` in the analog context, so the analog refusal is correct | same |
| 17.7-04 | `$abstime` (AMS addition, `Yes` in both columns) | **verified (analog)** / **missing (digital)** | `14_abstime.va`; §9.10 |
| 17.8-01 | `$rtoi`, `$itor` | **missing (digital)** / **verified (analog prohibition)** | `lower.zig:6630`; §9.11 extends only `$bitstoreal`/`$realtobits` |
| 17.8-02 | `$realtobits`, `$bitstoreal` | **partial** | analog path exists (`063`, `064`); `lower.zig:6030` fixes the width at 64 for `$realtobits`. Digital typing, x/z and overflow untested |
| 17.8-03 | `$signed`, `$unsigned` | **partial** | refused in analog (`lower.zig:6631`), correct; digital casts exist (`digital.zig:58, 213`) but only for "exactly one integral argument" |
| 17.9-01 | `$random` with no seed | **verified (analog)** | `115_random_no_seed.va`, `171_random_ieee1364_digits.va` |
| 17.9-02 | `$random` typed `inout` seed, mutated in place | **partial** | four argument rules pinned by E0816 rejections; seed mutation checked against compiled C by `zig build test-rng-reference` |
| 17.9-03…09 | `$dist_uniform/normal/exponential/poisson/chi_square/t/erlang` | **verified (analog, integral counts)** ×7 | `lower.zig:6250-6256`; `zig build test-rng-reference` compares values *and* final seeds against `tests/rng_reference.c` |
| 17.9-10 | **17.9.3** algorithm identity | **verified** | the C listing is transcribed and differentially tested; `docs/RNG-REFERENCE-LIMITS.md` |
| 17.9-11 | AMS real-valued `$rdist_*` (Table 9-26) | **verified (analog)** | ditto |
| 17.9-12 | Fractional and out-of-range counts | **missing**, explicitly | `docs/RNG-REFERENCE-LIMITS.md:26-29` — refused with a named diagnostic rather than substituted. A *good* `missing`: loud, documented, and pinned by `189_rng_fractional_count_rejected.va` |
| 17.9-13 | Reference Erlang/Student-t overflow to inf/NaN, Poisson precision loss | **unspecified, preserved deliberately** | `RNG-REFERENCE-LIMITS.md:29-34`; the listed operations are preserved rather than "fixed". No fixture may assert a different value |
| 17.9-14 | Digital `$random`/`$dist_*`: default streams, call-order behavior | **missing** | no digital dispatch |
| 17.10-01 | `$test$plusargs` | **verified (analog)** | `065_test_plusargs.va`; §9.12 Table row `Yes` |
| 17.10-02 | `$value$plusargs` | **verified (analog)** | `066_value_plusargs.va` |
| 17.11-01 | `$clog2` | **implemented-without-evidence → verified (analog)** | `lower.zig:8937` types it integer; `074_clog2.va` asserts |
| 17.11-02…23 | Real math: `$ln $log10 $exp $sqrt $pow $floor $ceil $abs $min $max $sin $cos $tan $asin $acos $atan $atan2 $hypot $sinh $cosh $tanh $asinh $acosh $atanh` | **verified (analog)** | `codegen.zig:5573-5582` aliases each to the bare operator per §9.14; fixtures `067`–`093` |
| 17.11-24 | Digital typing and argument conversion for the math functions | **missing** | AMS §9.14 says "extends … so that they can be used from the analog context" — the digital context is the inherited one, and nothing dispatches there |
| 17.11-25 | Domain behavior on out-of-range arguments | **implemented-without-evidence** | no fixture found asserting `$ln(-1)` or `$sqrt(-1)` |

### 4.4 §18 — Value change dump

**Every row here is `missing`, and the absence is total.** `grep -rn 'dump' src/`
returns exactly one hit, in an unrelated comment at `src/backend/codegen.zig:701`.
`grep -rln 'dumpvars\|dumpfile' tests/` returns nothing. There is no VCD code, no
VCD fixture, and no VCD rejection fixture — a `$dumpvars` in source would reach
E0512 "unknown function" (`src/diag_code.zig:3034-3037`), which is the wrong
diagnostic for a task §2.8.3 makes part of this standard.

| # | Obligation | Verdict |
|---|---|---|
| 18.1-01 | `$dumpfile` — name the dump file, once per simulation | **missing** |
| 18.1-02 | `$dumpvars` — no args = whole design; depth argument; scope/variable arguments | **missing** |
| 18.1-03 | `$dumpoff` / `$dumpon` — suspend and resume, with the `$dumpoff` all-x checkpoint | **missing** |
| 18.1-04 | `$dumpall` — checkpoint of all selected variables | **missing** |
| 18.1-05 | `$dumplimit` — byte limit, and the limit-reached behavior | **missing** (also a **resource limit** once implemented) |
| 18.1-06 | `$dumpflush` — flush the buffer without interrupting the dump | **missing** |
| 18.2-01 | Four-state VCD syntax: header, `$date`, `$version`, `$timescale`, `$enddefinitions` | **missing** |
| 18.2-02 | `$scope` / `$upscope` nesting and scope types | **missing** |
| 18.2-03 | `$var` declarations and identifier-code assignment, including aliasing | **missing** |
| 18.2-04 | Scalar value changes (`0`/`1`/`x`/`z` prefixed to the identifier code, no space) | **missing** |
| 18.2-05 | Vector value changes (`b`/`B`, `r`/`R`), leading-zero suppression | **missing** |
| 18.2-06 | `#` timestamp records and their ordering | **missing** |
| 18.2-07 | `$comment` | **missing** |
| 18.3-01 | `$dumpports` — file name and port list | **missing** |
| 18.3-02 | `$dumpportsoff` / `$dumpportson` | **missing** |
| 18.3-03 | `$dumpportsall` | **missing** |
| 18.3-04 | `$dumpportslimit` | **missing** |
| 18.3-05 | `$dumpportsflush` | **missing** |
| 18.3-06 | General rules for the extended VCD tasks (multiple files, repeated calls) | **missing** |
| 18.4-01 | Extended VCD `$vcdopen`/node-information records and `$scope` handling | **missing** |
| 18.4-02 | Extended VCD port direction encoding | **missing** |
| 18.4-03 | Extended VCD strength encoding (`D`/`U`/`N`/`Z`/`d`/`u`/`L`/`H`/`0`/`1`/`x`) | **missing** |
| 18.4-04 | Extended VCD value-change records | **missing** |

Dependency: 18.2-03 through 18.2-06 and all of 18.3/18.4 are blocked on **D03**
(packed nets, registers, drivers, strengths) and **D05** (a digital time axis).
18.1-01 and 18.1-06 are not — they are file handling, which already exists.

### 4.5 AMS additions to the inherited facilities, which need their own audit

The plan's D09 note says "AMS additions to digital system facilities still need
their own audit". Recorded here so they are not lost:

| # | Obligation | Verdict | Reference |
|---|---|---|---|
| AMS-01 | §9.3 task behavior across accepted vs rejected solver iterations | **implemented-without-evidence** | UNCITED; `ch09_system_tasks/COVERAGE.md:32` says a generated device cannot observe accept/reject. That makes it a *host* obligation, not an untestable one |
| AMS-02 | §9.4.7 `%r`/`%R` on reals in the **digital** context | **missing** | `ch09_system_tasks/COVERAGE.md:40`; the `%r` that works is the Table 9-23 analog engineering-notation specifier |
| AMS-03 | §9.22.1–§9.22.3 driver access (`$driver_count`, `$driver_state`, `$driver_strength`) | **missing** | `lower.zig:6666-6677` refuses at every call site lowering reaches, because a connect module is never the elaborated top (`elaborate.pickTop`). The refusal is correct for the *wrong half* of the clause; the right half needs §7.8 insertion |
| AMS-04 | §9.23.1–§9.23.4 (`$driver_delay`, `$driver_next_state`, `$driver_next_strength`, `$driver_type`) | **missing** | same |
| AMS-05 | §9.22.1 `$receiver_count` | **non-normative**, treated as family member | the clause marks it "Non-normative"; `lower.zig:6661-6665` documents the reasoning for fencing it anyway. Correct call, recorded so it is not re-opened |
| AMS-06 | §9.22.4 `driver_update` operator | **missing** | needs insertion |
| AMS-07 | §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log` PSD export | **partial** | The **zero residual is correct** per §4.6.4 — noise sources contribute only in small-signal noise analysis (`codegen.zig:5228-5236`). The gap is that `lower.zig:4964-4968` deliberately excludes both from `noise_gens` because `contract.NoiseGen` has no kind for a piecewise PSD, so the host never sees the source at all. Source carries the TODO. **Do not re-report the zero residual as the gap.** |
| AMS-08 | §4.6.4.4 `noise_table_log` | additionally **UNCITED** — no fixture names it | coverage report |
| AMS-09 | §9.21 `$table_model` quadratic/cubic spline modes and fatal extrapolation | **missing**, loudly | `src/backend/table_kernels.zig:25`: "Unsupported spline and fatal-extrapolation modes reject in IR" |

---

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

| Limit | Value | Where | Fails loudly? | Tested? |
|---|---|---|---|---|
| Output channels via mcd | 30 | `file_kernels.zig:66` | yes — `EMFILE`, returns 0 | no fixture exhausts it |
| Scan/`$fgets` line buffer | 512 bytes | `file_kernels.zig:59` | **unknown** | **no** — needs a longer-line fixture |
| Formatted-string scratch buffer | 512 bytes per site | `str_kernels.zig:245-248` | **unknown** | **no** |
| Descriptor table scope | one per device image, shared by instances | `file_kernels.zig:69-73` | n/a | **no** — needs a two-instance fixture |
| Distribution count range | 1..2147483647, integral only | `RNG-REFERENCE-LIMITS.md:25-28` | yes — named diagnostic, never truncation | yes, `189_rng_*_rejected.va` |
| Stateful-operator history capacity | — | plan A04 | plan states "silently forgetting history is not a valid implementation-defined limit" | **open** |

The RNG row is the template: a stated bound, a loud failure, and a fixture. The
three untested buffer rows are the outstanding work.

### 5.5 Unspecified — a test may not assert one outcome

| Item | Reference |
|---|---|
| `$ferror` errno numeric value | §9.5.7 "an error code is returned" |
| Reference Erlang/Student-t inf/NaN production, Poisson precision loss | 1364 §17.9.3 listing preserved verbatim; `RNG-REFERENCE-LIMITS.md:29-34` |
| Digital race outcomes | plan: "Test nondeterministic digital behavior against the permitted outcomes; do not assert one arbitrary race order" |
| §2.8.3 acceptance of unregistered `$fixture_*` names | neither required to accept nor to reject; `ch11_vpi/COVERAGE.md` records three fixtures that were corrected for assuming otherwise |

### 5.6 Non-normative

`annex_g_change_history` in its entirety (informative), `annex_h_glossary`,
the §1.x overview prose, §11.5.x diagram legends, §11.1–11.3 C-API mechanics
narrative, and §9.22.1's `$receiver_count` paragraph (marked "Non-normative" in
the LRM itself). These correctly carry no obligation. 12 of `ch11_vpi`'s 39
sections are already marked this way in its `COVERAGE.md` and that is right.

---

## 6. Rejection-fixture audit

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

### 7.1 Obligations classified in this document

Rows in Section 4 (inherited 1364 §§17–18 plus the AMS additions that extend
them). Where a row splits analog/digital, the **weaker** context sets the
verdict, and the split is noted in the row.

| Verdict | Count | Largest concentrations |
|---|---|---|
| **missing** | 63 | all 22 VCD rows (§18), 16 PLA, 5 stochastic queues, 3 simulator-time, driver access ×6 |
| **partial** | 11 | `$display`/`$write` family, `$fdisplay` family, `$realtobits`/`$bitstoreal`, `$signed`/`$unsigned`, `$finish`, `$stop`, `%s`, `$random` seed, `noise_table` |
| **implemented-without-evidence** | 9 | `%m`, null argument, zero-argument `$strobe`, zero-argument `$fflush`, §9.5.9 rollback, §9.3 accept/reject, §9.4.6, math domain behavior, E.3.2.2 |
| **verified** | 30 | file I/O positioning and status, format specifications, escape sequences, the 7+7 distributions and the 17.9.3 algorithm, 22 real math functions (counted as one row group), plusargs |
| **optional** | 3 | Annex C subset, 1364 Annex C utilities, SystemVerilog |
| **implementation-defined** | 6 | Section 5.3 |
| **non-normative** | 5 | Section 5.6 |
| — **resource limit** (orthogonal) | 6 | Section 5.4; 3 of 6 untested |
| — **unspecified** (orthogonal) | 4 | Section 5.5 |

Section 4 total: **119 obligation rows**, of which **63 missing, 11 partial,
9 implemented-without-evidence, 30 verified**.

Reading of that: the inherited digital facilities are essentially unimplemented
(the digital dispatcher is 3 tasks and 2 casts), and the analog facilities are
genuinely well covered — the `verified` rows are not generous, they are backed by
differential C oracles, byte-level output checks, and both-directions file-status
assertions.

### 7.2 Independent measure, from the LRM side

611 AMS clauses known to the harness:

| | Count | Meaning for this audit |
|---|---|---|
| tested both ways | 148 | the only category that can support a `verified` |
| accepted only | 208 | nothing pins what the clause rules out |
| **refused only** | **99** | **cannot be positive coverage** — Section 6.1 worklist |
| uncited | 156 | unexamined; per the plan, therefore open |

These two measures do not add up to each other and should not be made to. The
611 are AMS clauses; the 119 are inherited-1364 obligations the AMS clause list
does not contain.

### 7.3 Immediate worklist, cheapest first

1. **Recount five `COVERAGE.md` headers** (3.1) and add the 52 unmentioned
   fixtures to their chapter tables. `ch04`'s noise and Laplace groups are real
   evidence the doc currently does not credit.
2. **Fix `ch09_system_tasks/COVERAGE.md:37`** — "`06` does not compile" is false.
3. **Qualify the `$monitor` and `$debug` credits** at `ch09_system_tasks/COVERAGE.md:34`
   with the two `missing` rows 17.1-12 and 17.1-14.
4. **Fix `annex_e_spice/COVERAGE.md:274,290-292`** — 43 not 41 files, and a
   `//! temp` fixture exists, which undercuts the tc1/tc2 argument built on its
   absence.
5. **Rename the seven `annex_c_analog_subset/*_rejected.va` files** whose
   constructs are legal AMS (6.3) to `_unsupported`, matching the convention
   `ch07`/`ch08` already use.
6. **Add the three missing resource-limit fixtures** (5.4): a >512-byte input
   line, a >512-byte formatted string, two instances opening files.
7. **E0323 is the one stale analog-subset exemption inside the compiler** (6.2).
   Closing it is D-track work, not audit work; recording it is this document's
   job and it is recorded.
8. **Add IEEE 1364-2005 to `docs/`** or confirm §§17–18 numbering another way,
   so Section 4's references become citable rather than structural.
9. **Teach `--coverage` about the inherited clauses**, or accept permanently that
   the 611-clause denominator excludes everything §§17–18 requires. Today a
   complete VCD implementation and no VCD implementation produce the same
   coverage report.

### 7.4 What this audit did not do

- No `.zig` source was modified. No fixture was added, renamed, or deleted.
- ARPice host numbers in `docs/CONFORMANCE-GAPS.md` were not re-measured; they
  are not measurable from this worktree.
- Chapters 1–8 and 10 were reconciled for counts and for every claim the source
  could settle. A clause-by-clause re-read of their `COVERAGE.md` tables against
  the LRM HTML — the full Q01 obligation expansion for the *AMS* clauses, as
  opposed to the inherited ones — is not done. Section 7.2's 156 uncited and 99
  refused-only clauses are the entry points for it.
- X01 native-device compatibility is deliberately out of scope, per Q01.
