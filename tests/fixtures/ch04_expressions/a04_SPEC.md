# A04 — Stateful analog operators

Greenfield row: no `w2/*` branch covers it. Twelve positive `.va` fixtures plus
one host driver (`rollback/`), all under `tests/pending/A04/`. No reject
fixtures — every file here asserts a value. Nothing outside this directory was
touched.

This SPEC was written *after* the fixtures, from what is actually in them and
from re-running every one of them against `zig-out/bin/vera` built at
`45b505d`. The quoted clause text in each header was re-checked against the
offline LRM HTML in `docs/ch4-expressions.html`.

**Revised after adversarial review.** The three items previously parked in a
**DISPUTED** section were defects, not disputes, and have been fixed in the
fixtures rather than recorded around. See *Corrected after review* at the
bottom for what changed and why. There is no DISPUTED section any more.

## LRM clauses covered

All from `docs/ch4-expressions.html` (Clause 4.5, "Analog operators").

| clause | title | what it contributes to this row |
|---|---|---|
| **§4.5.3** | Time derivative operator | "In DC analysis, `ddt()` returns zero (0)." Used as the second, independent operator in the rollback driver. |
| **§4.5.4** | Time integral operator | Table 4-18 `idt(expr,ic,assert)`: "Returns ∫ta..t x(τ)dτ + c, where c is the value of ic at ta, which is the time when assert was last nonzero or t0 if assert was never nonzero"; and "Once assert becomes zero, idt() returns the integral of the argument starting from the last instant where assert was nonzero." |
| **§4.5.5** | Circular integrator operator | Table 4-19's `offset` form; "The output of the idtmod() function shall remain in the range offset <= idtmod < offset+modulus"; "The default for offset shall be zero (0)"; and the `y = n * modulus + z` identity against `idt()`. |
| **§4.5.6** | Derivative operator (`ddx`) | The operator that makes §4.5.9's small-signal *transfer function* an observable number in a transient run. |
| **§4.5.7** | Absolute delay operator | `absdelay(input, td [, maxdelay])`; "If the optional maxdelay is specified, then td can vary. If td becomes greater than maxdelay, maxdelay will be used as a substitute for td. If maxdelay is not specified, the value of td when the absdelay() is first evaluated shall be used and any future changes to td shall be ignored."; `Output(t) = Input(max(t − td, 0))`; Figure 4-4's worked transport-delay example. |
| **§4.5.8** | Transition filter | The general form with `td`; "transition() forces all positive transitions of expr to occur over rise_time and all negative transitions to occur in fall_time (after an initial delay of td). Thus, td models transport delay…"; "A transition is created when the input expression changes"; and the four interruption paragraphs with Figures 4-7…4-12. |
| **§4.5.9** | Slew filter | "In DC analysis, slew() simply passes the value of the destination to its output. In small-signal analyses, the slew() function has a transfer function from the first argument to the output of 1.0 when not slewing … and 0.0 when slewing." |
| **§4.5.11 / §4.5.11.4** | Laplace transform filters / `laplace_nd` | "The Laplace transform filters implement lumped linear continuous-time filters."; `H(s) = Σ nk s^k / Σ dk s^k`. |
| **§4.5.12 / §4.5.12.4** | Z-transform filters / `zi_nd` | "A filter with unity transfer function acts like a simple sample-and-hold which samples every T seconds and exhibits no delay."; "T specifies the period of the filter, is mandatory, and shall be positive. τ specifies the transition time, is optional, and shall be nonnegative."; "If it is not specified, the transition time is taken to be one (1) unit of time … If the transition time is specified as zero (0), then the output is abruptly discontinuous. A Z-filter with zero (0) transition time shall not be directly assigned to a branch."; `H(z) = Σ nk z^−k / Σ dk z^−k`. All four re-checked verbatim against `docs/ch4-expressions.html`. |
| **§4.5.15** | Restrictions on analog operators | "All analog operators are considered to have no state history prior to time t == 0."; "It is important to ensure that all analog operators are evaluated every iteration of a simulation to ensure that the internal state is maintained … These restrictions help prevent usage which could cause the internal state to be corrupted or become out-of-date." The evaluate-every-iteration sentence is fixture 12's whole content. Note what the restriction paragraph does **not** say: it names `if`, `case` and `?:` and nothing else, so it does not make an analog operator in the right operand of a `||` illegal — which is why fixture 12 asserts a value and not a refusal. |
| **Table 4-20** | Analog operator arguments | `absdelay`: constant = `maxdelay`, dynamic = `expr, td`. `idt`: constant = `abstol`, dynamic = `expr, ic, assert`. `idtmod`: dynamic = `expr, ic, modulus, offset`. Verified verbatim; this table is what makes fixtures 03/04/07 *legal programs* rather than abuses. |

## Ground truth, established by reading `src/` and running the compiler

The plan's A04 paragraph reads as if the whole operator family needed auditing.
Re-running the fixtures says otherwise: five of the twelve pass today. What is
actually there:

**Already correct, and previously untested anywhere (so pinned here as a
regression floor):**

- **`absdelay` initialisation.** `zHistPush`'s first push seeds the *whole* ring
  with `(t0, Input(0))`, so `Output(t) = Input(max(t−td,0))` already answers
  `Input(0)` — not 0 — for `t < td` with a nonzero input at t = 0. Fixture 06
  passes, 10/10 checks.
- **`idtmod` offset window with a negative integrand.** `zWrap` is
  `x − modulus*@floor((x − offset)/modulus)`, which is Table 4-19's definition
  including the offset. Fixture 08 passes, 36/36 checks, including the closed
  end (`z = −1` at `y = −1`) and the re-entry from below.
- **`laplace_nd` in the time domain.** The bilinear/trapezoidal realisation
  (`filter_kernels.zBilin` + `zSec`) tracks the exact ramp response of
  `1/(1+sτ)` to well inside 1e-3 over 41 points. Fixture 11 passes, 82/82. Every
  `laplace_*` fixture under `tests/fixtures/` only ever evaluates a DC point, so
  the pole was unpinned until now.
- **`slew` small-signal transfer.** `ddx(slew(...), V(in))` already reads exactly
  1.0 at the DC point and when not slewing and exactly 0.0 while rate-limited —
  §4.5.9's two numbers. Fixture 09 passes 12/12. §4.5.9 is, as far as this row
  can see, fully implemented: the rate limit, both default-rate spellings and
  the rate-sign refusal are already covered by
  `tests/fixtures/ch04_expressions/21_slew.va` and `129_…`, and the transfer
  function is what 09 adds. 09 is therefore a **disclosed regression floor**,
  not a claim that HEAD is wrong — see *Corrected after review*, item 4.

**Not implemented (the deliverable):**

1. **`transition()`'s `td` argument is dropped.** `Gen.transitionTimes`
   (`src/backend/codegen.zig:6077`) reads `args[2]` and `args[3]` only; argument
   1 is never consulted in either the eval arm or the `zTransStep` update arm.
   Every `transition(x, td, …)` behaves as `td = 0`.
2. **The transition ramp is armed at the previous accepted timepoint**, not at
   the timepoint where the input changed, so even with `td = 0` the output is one
   step early (visible as the whole failure set of fixture 01 and the first three
   failures of 02).
3. **An interrupted transition restarts from the current output over the full
   rise/fall time.** §4.5.8's four paragraphs pick the *original* origin or
   destination for the new slope; `zTransStep` picks neither.
4. **`absdelay`'s `maxdelay` argument is dropped.** `Gen.emitOperator`'s
   `.absdelay` arm (`src/backend/codegen.zig:5980`) passes `argF64(args, 1)` and
   never looks at argument 2 — no clamp, no "td can vary" mode.
5. **Dynamic control arguments are refused outright.** `argF64`/`f64Const` fold
   literals and `model.<p>` arithmetic only, so a node probe as `absdelay`'s `td`
   or `idt`'s `assert` is rejected with **E0515** — the exact opposite of Table
   4-20, which lists both as *dynamic* arguments. This refuses three legal
   programs (fixtures 03, 04, 07) and makes the §4.5.4 assert-release rule
   unobservable in any spelling.
6. **The `absdelay` history ring silently shortens the delay.** `hist_len` is a
   fixed 512 (`src/backend/codegen.zig:7759`) and `zHistAt` ends with
   `return vs[head]` — "Query older than the whole ring: clamp to the OLDEST
   sample." A delay spanning more than 512 accepted steps is answered as a
   512-step delay with no diagnostic. This is the plan's "silently forgetting
   history is not a valid implementation-defined limit" bullet, as a number.
7. **Z-filter output is one sample period late.** The eval arm is
   `zZiHold(…, inst.<n>__out)` (`src/backend/codegen.zig:5958`) and `<n>__out` is
   written in `updateState`, which runs *after* the timepoint is evaluated. At
   `t = k·T` the operator reports `y[k−1]`.
8. **An analog operator in the right operand of a short-circuit `||` is fed a
   branch-local input.** VerA lowers the right operand into the `else` arm of a
   short-circuit branch, and `updateState` then hands that operator site the
   branch-local value — 0.0 on every step where the left operand was already
   true — so its history is stranded and it diverges from an identical site
   outside the `||`. §4.5.15 requires every analog operator to be evaluated
   every iteration. Fixture 12 is this defect, 3 of its 12 checks failing.
9. **No revert hook exists for §4.5 operator state.** `Gen.emitsStateCtl`
   (`src/backend/codegen.zig:2495`) is `fsmStateCtl() or pathLatches() or
   uses_newton_iter or limit_slots.len != 0` — analog-operator history is not in
   the list. Confirmed empirically: `vera --emit-zig` on `a04_rollback_ops.va`
   emits **zero** `pub fn stateCtl`. Even were the hook emitted, `emitStateCtl`'s
   `.revert` arm restores no `__acc`/`__prev`/`__from`/`__t0`/`__u`/`__y`/`__t`/
   `__v`/`__head` field and does not restore `State.t_prev`, which is what `dt` is
   measured against.

## Fixtures

Positive: 12 `.va` + 1 host driver. Refusals: 0.

| fixture | pins | expected value and derivation | today |
|---|---|---|---|
| `01_transition_transport_delay.va` | §4.5.8 — `td` shifts the ramp later, it does not stretch it. | Input steps 0→1 at t = 1ns; `td = tr = tf = 2ns`. The transition is created at the change (1ns), starts ramping at 1ns + td = 3ns and arrives one `rise_time` later at 5ns, so `out = clamp((t/1ns − 3)/2, 0, 1)` = 0,0,0,0,0.5,1,1 at t = 0…6ns. The oracle is written in `$abstime`, not `V(p,n)`, so a shared error cannot cancel. The 0.5 at t = 4ns is strictly inside the delayed ramp, which "round the delay to the next timepoint" cannot fake. | **FAIL** 7/14 checks. The residual `out − want` reads 0.5, 1, 1, 0.5, 0 at t = 1…5ns instead of 0. |
| `02_transition_interrupted_rising.va` | §4.5.8 — an interrupted *rising* transition whose new destination is *below* the interruption value: slope from the ORIGINAL DESTINATION, applied from the interruption point. | `tr = 4ns`, `tf = 2ns`, `td = 0`; input 0 → 4 at 1ns → 0 at 4ns. Rising leg (1ns,0)→(5ns,4), slope +1 V/ns, so `vi = 3` at the interruption `ti = 4ns`. v3 = 0 < vi, so slope = (v3−v2)/tf3 = (0−4)/2ns = **−2 V/ns** from (4ns, 3), arriving at t3 = 4 + (0−3)/(−2) = **5.5ns**. Output 0,0,1,2,3,**1**,0,0,0 at t = 0…8ns. The naive reading (restart from vi over the full fall time, −1.5 V/ns) puts 1.5 at t = 5ns and arrives at exactly 6ns; **t = 5ns is the only point on this grid where the two readings differ** — both are 0 at 6, 7 and 8ns. The discriminating CHECKI is therefore `\|out − 1.0\| ≤ 0.25` inside the window 4.5 < t/1ns < 5.5 (0.25 is the midpoint of 1.0 and 1.5, so each reading is rejected by the margin it is wrong by); the arrival check `out == 0 for t ≥ 5.5ns` is kept as a separate, weaker claim that rejects a re-arming exponential decay and nothing else. | **FAIL** 6/27 checks, at t = 1,2,3,4,5ns plus the t = 5ns discriminator — three of them from defect 2 (early ramp) before the interruption rule is even reached. |
| `03_absdelay_td_frozen_without_maxdelay.va` | §4.5.7 + Table 4-20 — a *signal-valued* `td` without `maxdelay` is legal, and its later changes are ignored. | Input is the 1 V/ns ramp; `td = V(d)·1ns` with V(d) = 2,2,2,5,5,5. Frozen at its first-evaluation value (2ns), `Output(t) = Input(max(t−2ns,0))` = 0,0,0,1,2,3 at t = 0…5ns. Re-reading `td` every step answers 0 at t = 3,4,5ns. | **FAIL** `error[E0515]` — the module does not compile. |
| `04_absdelay_maxdelay_substitution.va` | §4.5.7 — the three-argument form: `td` may vary, and `maxdelay` substitutes once exceeded. Figure 4-4's own worked example. | Ramp input, `maxdelay = 3ns`, `td = V(d)·1ns` with 2,2,2,4,4,1,1,1 ns. Effective delay `min(td, 3ns)` = 2,2,2,3,3,1,1,1, so `out = max(t/1ns − eff, 0)` = 0,0,0,0,**1**,**4**,5,6. t = 4ns separates "clamped" (1) from "honoured td" (0); t = 5ns is the forward jump 1 → 4 that Figure 4-4's prose describes, which no first-order lag and no frozen `td` can produce. **Figure 4-4 does not illustrate the substitution rule** — its `maxdelay` is 5 and its `td` never exceeds it; the figure supplies only the varying-`td` shape and the forward jump, and the substitution comes from the normative sentence alone. This fixture uses `maxdelay = 3` and so departs from the figure at t = 4ns (figure: `input(0)` = 0; here: `input(1ns)` = 1). | **FAIL** `error[E0515]`. |
| `05_absdelay_history_beyond_capacity.va` | §4.5.7 + §4.5.15 — a delay spanning more accepted steps than the implementation's ring is still that delay; a capacity failure may be reported but not silently rewritten. | Ramp input, `td = 515ns`, uniform 1ns grid to 520ns (521 points). `out = max(t/1ns − 515, 0)`: 0 through t = 515ns, then 1,2,3,4,5. A 512-sample ring answers `max(t/1ns − 512, 0)` from t = 513ns on — 8 instead of 5 at the end, and **3 instead of 0 at t = 515ns** (the operator is evaluated before the current point is pushed, so the oldest retained sample at t = 515ns is t = 3ns and the clamp returns `Input(3ns)` = 3). | **FAIL** 11/1042 checks; deviation 1 at t = 513ns, 2 at 514ns, a flat 3 from 515ns to 520ns. Exactly the predicted underrun, and the first 513 points pass under both readings, so the failure localises to the sample where the ring gives out. |
| `06_absdelay_initial_output_is_input_at_zero.va` | §4.5.7 + §4.5.15 — before `t = td` the output is `Input(0)`, not zero. | Input `3 + t/1ns` (so `Input(0) = 3`), `td = 2ns`: out = 3,3,3,4,5 at t = 0…4ns, i.e. `3 + max(t/1ns − 2, 0)`. Distinguishable from a zero-filled history only because the input is nonzero at t = 0, which no `absdelay` fixture under `tests/fixtures/` arranges. | **pass** (10/10) — regression floor for defect 6's fix. |
| `07_idt_assert_release_resumes.va` | §4.5.4 — the RELEASE edge of `assert`: integration resumes from the last instant `assert` was nonzero, not from t0. | Integrand `1e9` (exactly 1.0 per ns), `ic = 7.0`, `assert = V(a)` = 1,1,0,0,0, so `ta = 1ns`, `c = 7`. `idt` = 7,7,8,9,10 at t = 0…4ns = `7 + max(t/1ns − 1, 0)`. Restarting from t0 gives 9 and 12; ignoring `assert` entirely gives 8 at t = 1ns. The three post-release points separate all three readings. | **FAIL** `error[E0515]`. `tests/fixtures/ch04_expressions/16` holds `assert` nonzero for the whole run, so the release half has never been exercised. |
| `08_idtmod_offset_window_negative_integrand.va` | §4.5.5 — nonzero `offset` with a negative integrand, i.e. the wrap that must *add* a multiple of the modulus, plus the `y = n·modulus + z` identity. | `expr = −1e9`, `ic = 0`, `modulus = 2`, `offset = −1` (window [−1, +1)). `y = −t/1ns`; `z = y − 2·floor((y+1)/2)` = 0, −1, 0, −1, 0 at t = 0…4ns with n = 0,0,−1,−1,−2. At t = 1ns `y = −1` lands on the CLOSED end, so z = −1 and not +1. Four checks per point: `idt` exactness, the window bounds, `(y−z)/2` integral, and z itself; half-steps sampled too. | **pass** (36/36) — the first evidence that `zWrap`'s offset handling is right. |
| `09_slew_small_signal_transfer.va` | §4.5.9 + §4.5.6 — the small-signal transfer from the first argument is exactly 1.0 when not slewing and exactly 0.0 when slewing, made observable in a transient through `ddx`. **Regression floor, disclosed:** §4.5.9 is already right at HEAD and this number is pinned nowhere else. | Rates ±3e8 V/s on a 1ns grid = 0.3 V per step; unit step at t = 1ns. Output 0, 0.3, 0.6, 0.9, 1, 1; `d out/d in` = 1 (DC), 0, 0, 0, 1, 1. t = 4ns steps from 0.9 (not 1.0), so the last slewing point is strictly inside the limit and the "reached destination" / "still limited" boundary does not decide the fixture. Not vacuous: a first-order-lag lowering of `slew()`, or a `ddx` that did not see through the limiter, reads an intermediate slope and fails at 1e-15. | **pass** (12/12). The `\|\|` check that used to fail here has moved to fixture 12. |
| `10_zi_nd_output_at_sample_instant.va` | §4.5.12.4 — the Z recurrence actually running: the sample taken at `t = k·T` is the output *of* that sample, not the previous one. | `H(z) = 1/(1 − 0.5 z⁻¹)`, i.e. `y[k] = u[k] + 0.5·y[k−1]`; `T = 1ns` on the sample grid; **τ passed explicitly as 0**; u = 0,1,1,1,1; §4.5.15 fixes `y[−1] = 0`. y = 0, 1, 1.5, 1.75, 1.875 = `2·(1 − 0.5^k)`. t = 0 is deliberately ambiguity-free: both defensible operating-point readings give 0 there because u(0) = 0. τ = 0 is what makes the other four unambiguous — see *Corrected after review*, item 3. | **FAIL** 5/10 checks. Observed 0, **0**, 1, 1.5, 1.5 — `y[k−1]`, one whole sample period late (the 1.5 at k = 4 is the recurrence also missing a sample at the end). τ = 0 is itself dropped: the run is bit-identical with and without it. |
| `11_laplace_nd_ramp_response.va` | §4.5.11.4 — a Laplace filter *responding in time*; the pole, which is invisible at s = 0 where every existing `laplace_*` fixture stops. | `H(s) = 1/(1 + sτ)`, τ = 10ns, driven by the unit ramp from rest: `y(t) = t/1ns − 10·(1 − exp(−t/10ns))`. y(5ns) = 1.0653066, y(10ns) = 3.6787944, y(20ns) = 11.3533528. Tolerance 1e-3 derived: 41 uniform points at dt = τ/20, trapezoidal local error O(dt²), worst deviation 7.67e-4 at t = 10ns; a DC-gain-only reading is out by 8.6 at t = 20ns and a τ = 9ns filter by 0.09. | **pass** (82/82) — first evidence the filter is more than its DC gain. |
| `12_analog_operator_in_short_circuit_operand.va` | §4.5.15 — "It is important to ensure that ALL analog operators are evaluated EVERY ITERATION of a simulation to ensure that the internal state is maintained." Two identical `slew()` sites, one unconditional and one in the right operand of a `\|\|`, shall read the same number. | Same ±3e8 V/s stimulus as 09, so site A is 0, 0.3, 0.6, 0.9, 1, 1. The `\|\|`'s left operand is `$abstime < 3n` — pure time, safe to evaluate, true for the first three points. A short-circuiting lowering skips site B there, so B starts its ramp three steps late and reads 0.3, 0.6, 0.9 where A reads 0.9, 1, 1. The claim is an IDENTITY the clause states with no value to write down (`\|B − A\| ≤ 1e-15`), plus a literal pin of A against the hand-derived rate limit so the two sides cannot be equally wrong. | **FAIL** 3/12 checks, at t = 3, 4, 5ns — exactly the three points the derivation predicts. |
| `rollback/a04_rollback_ops.va` + `rollback/rollback_host.zig` | §4.5.4 + §4.5.3 + §4.5.15 — operator state across a REJECTED timestep. Not expressible in the `//!` directive language, which walks time forward and calls `updateState` once per entry; modelled on `tests/limiter_host.zig` and `tests/table_snapshot_host.zig`. | Integrand `1e9` (1.0 per ns) and a 1 V/ns ramp on V(p). DC: idt = 0, ddt = 0 (§4.5.3). Trial step to 2ns: idt = 2.0, ddt = 1e9 — then REJECTED. Retry to 1ns: idt = **1.0**, not 2.0 (leftover state) and not 0.0 (what `zIdtAcc`'s `if (dt <= 0.0) return ic` yields once `state.t_prev` has been left at 2ns). Then 2ns for real: 2.0 again, the identical number the discarded attempt produced. Second test: three shrinking rejected attempts, each followed by `expectEqualDeep(accepted, inst)` and `expectEqualDeep(accepted_state, state)`. | **FAIL** both tests, `error.NoRevertHookForAnalogOperatorState` — the device exports no `stateCtl` at all. |

### Observed today, verbatim

```
01_transition_transport_delay              ok=1 x7     ok=0 x7
02_transition_interrupted_rising           ok=1 x21    ok=0 x6
03_absdelay_td_frozen_without_maxdelay     REFUSED error[E0515]
04_absdelay_maxdelay_substitution          REFUSED error[E0515]
05_absdelay_history_beyond_capacity        ok=1 x1031  ok=0 x11   (first at t = 513ns)
06_absdelay_initial_output_is_input_at_zero ok=1 x10    ok=0 x0
07_idt_assert_release_resumes              REFUSED error[E0515]
08_idtmod_offset_window_negative_integrand ok=1 x36    ok=0 x0
09_slew_small_signal_transfer              ok=1 x12    ok=0 x0
10_zi_nd_output_at_sample_instant          ok=1 x5     ok=0 x5
11_laplace_nd_ramp_response                ok=1 x82    ok=0 x0
12_analog_operator_in_short_circuit_operand ok=1 x9     ok=0 x3
rollback/rollback_host.zig                 0 passed; 2 failed (NoRevertHookForAnalogOperatorState)
```

Captured on 2026-09-19 from `zig-out/bin/vera` at `45b505d`, by the loop under
*Build / run* below with the `ok=` lines counted; the rollback line is the last
line of the `zig test` invocation printed there.

`a04_rollback_ops.va` also emits a benign `warning[W0650]` (strict float mode,
speed not correctness).

## Corrected after review

An adversarial review found six defects in this row. All six are fixed in the
fixtures; nothing in `src/`, `build.zig` or `tests/fixtures/` was touched.

1. **A fabricated quotation in `10_zi_nd_output_at_sample_instant.va`**
   (Class B). The header put in quotation marks *"the filter acts like a simple
   sample-and-hold which samples every T seconds and holds the value in
   between."* That sentence is not in the LRM. §4.5.12 reads *"A filter with
   **unity transfer function** acts like a simple sample-and-hold which samples
   every T seconds and **exhibits no delay**."* The header dropped the
   precondition and replaced the load-bearing half with invented text. The
   previous revision of this SPEC recorded the discrepancy in a DISPUTED
   section and shipped the file unchanged; that was the wrong call — a
   fabricated quote is a defect, not a dispute. The header now carries the
   sentence verbatim, with its precondition, plus the τ paragraph it needs.

2. **An unearned appeal to Figure 4-4 in `04_absdelay_maxdelay_substitution.va`**
   (Class B). The header called Figure 4-4 *"a worked example with exactly this
   shape"* for the **substitution** rule. Figure 4-4's `maxdelay` is 5 and its
   `td` runs 2 → 4 → 1, so it never exceeds `maxdelay` and illustrates nothing
   about substitution. The header now states exactly what the figure supplies
   (the varying-`td` shape and the forward jump at the downward step), quotes
   the figure's own prose, says in capitals that the figure does not illustrate
   the substitution rule, and points out that `maxdelay = 3` is precisely what
   makes this fixture *depart* from the figure at t = 4ns. The asserted values
   are unchanged and were re-derived: at t = 4ns the figure reads `input(0)` = 0
   and this fixture reads `input(1ns)` = 1.

3. **`10_…` asserted a contestable instant** (Class C). The fixture asserted
   `y[k]` at exactly `t = k·T` while leaving τ unspecified. §4.5.12: *"If it is
   not specified, the transition time is taken to be one (1) unit of time."*
   Under a τ-aware implementation the k-th transition *begins* at `t = k·T`, so
   `y[k−1]` there is a legal reading — and it is exactly what HEAD prints, so
   four of the five failures did not discriminate a defect from a conforming
   reading. Fixed by passing **τ = 0** explicitly: §4.5.12 then makes the output
   *"abruptly discontinuous"* at the sample instant, and the sample-and-hold
   sentence's *"exhibits no delay"* fixes which side of the discontinuity
   `t = k·T` is on. The same paragraph's *"A Z-filter with zero (0) transition
   time shall not be directly assigned to a branch"* is respected — the only
   contribution in the module is `I(in,n) <+ 0.0`. The wants are unchanged;
   HEAD still fails 5 of 10, and now every one of those five is unambiguous.
   A half-sample probe grid (`k·T + T/2`) was considered as a belt-and-braces
   alternative and rejected: it would need a `floor()` in the want and would
   change the accepted-step count the kernel under test is driven on.

4. **`09_slew_small_signal_transfer.va` was an active trap** (Class D). Its two
   §4.5.9 checks pass at HEAD at all six points; the only failing check put an
   analog operator in the right operand of a short-circuit `||`, so its failure
   was a lowering defect and an implementer chasing green could have "fixed" it
   by breaking `slew()`. The third check is **removed from 09** and the file
   keeps only what §4.5.9 licenses.
   **The claim did not disappear.** It is re-homed, still in this row, as
   `12_analog_operator_in_short_circuit_operand.va`, cited to §4.5.15's *"It is
   important to ensure that all analog operators are evaluated every iteration
   of a simulation"*, and rewritten so it fails for that reason and no other:
   an unconditional site A and a site B inside the right operand of a `||` whose
   left operand is `$abstime < 3n`, asserted equal to 1e-15. It fails 3/12 at
   HEAD, at t = 3, 4 and 5ns, exactly as derived. It is deliberately **not** a
   reject fixture: §4.5.15's restriction paragraph names `if`, `case` and `?:`
   and nothing else, so nothing in the clause makes a `||` operand illegal and
   nothing in it authorises a diagnostic.
   What remains in 09 is a disclosed regression floor. §4.5.9's rate limit, its
   two default-rate spellings and its rate-sign refusal are already green in
   `tests/fixtures/ch04_expressions/21_slew.va` and `129_…` (verified by
   probing all three `slew()` shapes at HEAD: all correct), so the transfer
   function is the only part of the clause 09 adds, and it is pinned nowhere
   else. It is not a non-claim: a first-order-lag lowering of `slew()`, or a
   `ddx` that did not see through the limiter, fails it at 1e-15.

5. **Two documented discriminators in 02 and 05 did not discriminate**
   (Class C). Both are re-derived in the fixture headers:
   - `02`'s CHECKI comment claimed *"the full-fall-time reading is still at 0.5
     at t = 6ns"*. It is not: the naive fall from (4ns, 3) at −1.5 V/ns reaches
     zero at 4 + 3/1.5 = **exactly 6ns**, so both readings are 0 at t = 6, 7 and
     8ns and the check passed under both. The comment is corrected, the check is
     kept but downgraded to what it actually rejects (a re-arming exponential
     decay, which never reaches exactly 0), and a **new** CHECKI carries the
     discrimination: `|out − 1.0| ≤ 0.25` inside `4.5 < t/1ns < 5.5`. 0.25 is the
     midpoint of the clause reading (1.0) and the naive reading (1.5), so each
     is rejected by the margin it is wrong by, and the time window avoids
     comparing a float for equality. That check fails at HEAD, taking 02 from
     5/18 to 6/27.
   - `05`'s comment claimed a short ring *"answers 4 here"* and named 511ns. Both
     are off by one. Derived: the operator is evaluated before the current point
     is pushed, so at t = 515ns the oldest sample a 512-deep ring still holds is
     t = 515 − 512 = 3ns; the query for t − td = 0ns is older than that, and the
     clamp returns `Input(3ns)` = **3**. Confirmed by running: the residual the
     CHECK prints reads `got=3` at t = 515ns and at every point after. The
     fixture's asserted values were already right and are unchanged.

6. **The documented `zig test` command did not compile** (5.6, reproduction).
   `--dep` is positional and attaches to the next `-M`; the emitted device
   `@import`s `contract` itself, so both `--dep` flags before `-Mroot` gave
   `root` two dependencies and `device` none. Both this SPEC (below) and
   `rollback_host.zig`'s own header now print the form that works, together with
   the error the broken form produces, and it has been run:

   ```
   1/2 …§4.5.4 the integral at an accepted time…FAIL (NoRevertHookForAnalogOperatorState)
   2/2 …§4.5.15 a revert leaves no half-advanced operator history…FAIL (…)
   0 passed; 0 skipped; 2 failed.
   ```

   The review's second half is also fixed: both tests opened with
   `if (!@hasDecl(D, "stateCtl")) return error.…`, whose condition is comptime
   true today, so Zig folded the branch and **never analysed the rest of either
   body** — `D.initState`, `D.updateState`, `D.eval`, the `D.Instance` field set
   and the `D.Model` shape would have been type-checked for the first time on
   the day someone implemented the hook. The guard now sits inside a
   `fn stateCtl(…) !void` shim, so both bodies are compiled and executed today
   up to the first revert (the DC assertions `idt = 0`, `ddt = 0` now actually
   run and pass), and the only thing still unanalysed is the single
   `D.stateCtl` call — which is irreducible.

7. **Two header prose slips, previously only disclosed.** The old DISPUTED
   section recorded them and edited nothing; that section is gone, so they are
   fixed at source. `01`'s "MEASURED, this reads 0.5 / 1 / 1 / 0.5 / 0" was the
   *residual* `out − want`, not the operator output (which is 0.5, 1, 1, 1, 1);
   the header now says which is which. `08`'s aside had the two readings the
   wrong way round — re-derived for y = −2.5, modulus 2, offset −1: the correct
   offset-aware wrap `y − 2·floor((y+1)/2)` = −0.5, the offset-forgotten
   `y − 2·floor(y/2)` = +1.5. The header now shows that arithmetic. Neither
   fixture's asserted values change.

### Where the reviewer and this row disagree

Nowhere on the numbers: every value the review disputed was re-derived here and
the review was right each time (3 for fixture 05, exactly-6ns for fixture 02,
the τ default for fixture 10). One matter of framing: the review calls fixture
09's *"net coverage from this file zero"*. With the trap removed that is too
strong — the `ddx`-of-`slew` transfer is a real §4.5.9 number that no fixture
under `tests/fixtures/` asserts, and a wrong implementation fails it. It is a
regression floor, which this row now says out loud instead of burying in a
DISPUTED note. If a reviewer disagrees, the file to delete is 09 and the file to
keep is 12; the coverage that would be lost is named above.

### Withdrawn, and where it went

| withdrawn from | what | where it is now |
|---|---|---|
| `09`, third CHECKI | analog operator in the right operand of `\|\|` | `12_analog_operator_in_short_circuit_operand.va`, same row, cited §4.5.15 |
| `10`, header | the "holds the value in between" quote | nowhere — it is not in the LRM. The real sentence, with its unity-transfer-function precondition, is quoted in its place. |
| `04`, header | "Figure 4-4 is a worked example of the substitution rule" | nowhere — Figure 4-4's `maxdelay` is 5 and its `td` never exceeds it. The substitution rule now rests on §4.5.7's normative sentence alone; the figure is cited only for the shape it does show. |
| `02`, CHECKI comment | "the full-fall-time reading is still at 0.5 at t = 6ns" | nowhere — it is 0 there. The discrimination moved to a new CHECKI at t = 5ns. |

## Deliberately NOT covered

- **`last_crossing()` (§4.5.10)** — named in the plan's A04 bullet, no fixture
  here. It needs an interpolated time value and a `cross()` interaction, which is
  D05/M01 territory as much as §4.5's.
- **`ddt` (§4.5.3) in its own right** — it appears only as the second operator in
  the rollback driver. `abstol`/`nature` forms of `ddt`, `idt` and `idtmod` are
  untouched throughout: §4.5.2 tolerance association is not a value this harness
  can read back.
- **The other six filter spellings** — `laplace_zp`, `laplace_zd`, `laplace_np`,
  `zi_zp`, `zi_zd`, `zi_np`. Fixture 11 and fixture 10 pin the `_nd` forms only.
  Complex-conjugate pole pairs, the "root is zero ⇒ implement as s" rule
  (§4.5.11.1), and the null-argument spelling `,,` are all unpinned.
- **The Z filters' `τ` and `t0` arguments** (§4.5.12): the transition time, the
  "shall not be directly assigned to a branch" rule for τ = 0, and a first
  transition at t0 ≠ 0.
- **`transition()`'s `time_tol`, multiple pending transitions, and the three
  other interruption cases.** §4.5.8 defines four interruption cases (Figures
  4-7…4-12); fixture 02 pins the first only. The "arbitrary number of pending
  transitions" case (`transition(clk, 5.1n, 1p)` against a 5ns clock) needs a
  digital driver and belongs with D05/M01.
- **AC and small-signal views.** §4.5.7's `Output(ω) = Input(ω)·e^(−jωtd)`,
  §4.5.8's "unity transmission for all frequencies" AC approximation, and the
  filters under `.ac` are A06's row. Fixture 09 reaches §4.5.9's *small-signal*
  sentence through `ddx` at a transient operating point precisely to avoid
  needing an AC analysis here.
- **`$discontinuity` / timestep control.** §4.5.8's "causes the simulator to
  place time points at both corners of a transition" and `absdelay`'s
  `bound_step` request are observable only in the host's step controller, not in
  a `CHECK`.
- **Refusals.** Zero reject fixtures, deliberately. The one refusal this row was
  once thought to want — an analog operator in a short-circuit `||` — is not a
  refusal: §4.5.15's restriction paragraph names `if`, `case` and `?:` and
  nothing else, so the clause does not authorise a diagnostic there. It is
  fixture 12, and it asserts a value. §4.5.15's *actual* conditional
  restriction (an operator under an `if`/`?:` whose condition can change during
  the simulation) has no fixture here and would be a genuine reject fixture —
  `//! reject` with the specific code, once one exists — for whoever implements
  the check.
- **The host.** No ARPice fixture. Everything above is observable inside VerA's
  own testbench or in the standalone `zig test` driver below. The one host-shaped
  requirement (a rejected step) is covered by `rollback/`, which drives the
  emitted device directly rather than going through ARPice's engine.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them.

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build install                           # refresh zig-out/bin/vera

# the twelve .va fixtures. --emit-exe prints the binary path on STDOUT and
# diagnostics on STDERR, so the two are captured separately.
for f in tests/pending/A04/*.va; do
  b=$(basename "$f" .va)
  echo "##### $b"
  P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
        -I tests/fixtures "$f" 2>/tmp/a04_$b.err) \
    && [ -n "$P" ] && "$P" || head -3 /tmp/a04_$b.err
done
```

Every `ok=` column must read `ok=1`; fixtures 03, 04 and 07 must compile at all.
This is the loop the *Observed today* transcript above was captured from.

The rollback driver needs no `build.zig` change to run — emit the device and
point `zig test` at it as a module named `device`:

```sh
./zig-out/bin/vera --emit-zig -I tests/fixtures \
  tests/pending/A04/rollback/a04_rollback_ops.va -o /tmp/a04_rollback.zig
zig test --dep device -Mroot=tests/pending/A04/rollback/rollback_host.zig \
         --dep contract -Mdevice=/tmp/a04_rollback.zig \
         -Mcontract=tools/contract.zig
```

`--dep` is POSITIONAL: it attaches to the NEXT `-M`. The emitted device does
`@import("contract")` itself, so `contract` must be a dependency of the `device`
module and not only of `root`. Putting both `--dep` flags before `-Mroot` — as
an earlier revision of this file did — fails before either test runs with
`/tmp/a04_rollback.zig:7:26: error: no module named 'contract' available within
module 'device'`.

Both tests must pass. (To wire it into `zig build` permanently, copy the
`limiter_host` block at `build.zig:181` / the `table_snapshot_host` block at
`build.zig:202` and add a `test-a04-rollback` step; the header of
`rollback_host.zig` sketches it.)

To fold these into the green gate once the clauses are implemented, move 01, 02
and 05–12 into `tests/fixtures/ch04_expressions/` (03, 04 and 07 too, once
dynamic control arguments are accepted), add each file's one-liner to that
directory's `COVERAGE.md`, then:

```sh
zig build torture -- --strict ch04
```
