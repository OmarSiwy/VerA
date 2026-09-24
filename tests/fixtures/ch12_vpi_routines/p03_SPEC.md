# P03 — Analog VPI and accepted-point callbacks

**Landed 2026-09-24** for everything but a user analog `$systf` and `ac`:
01–05, 08, 10, 11, 91 and the new 92 run under `zig build test`
(`build.zig`'s `vpi_runs`). The host builds the design's device and solver
as a shared library (`vera.tb.renderVpiLib`) and drives the time walk from
`src/vpi/analog.zig`. Still compile-only: 06, 07 and 90 (an analog systf's
calltf — the device calls it through `contract.SystfHost`, which the host
does not bind yet) and 09 (no small-signal analysis runs in-process). The
ground-truth section below is the state before this landed.

Pending fixtures. **Every one of them fails today**, and it fails at the C
compiler, not at an assertion: the surface they call does not exist.

## Ground truth, established by reading the source and not the plan

Verified at `ddt-capform` HEAD (45b505d):

* `src/vpi/root.zig` (1542 lines) contains exactly eleven `export fn`s:
  `vpi_handle`, `vpi_handle_by_name`, `vpi_handle_by_index`, `vpi_iterate`,
  `vpi_scan`, `vpi_get`, `vpi_get_str`, `vpi_compare_objects`,
  `vpi_free_object`, `vpi_release_handle`, `vpi_chk_error`. No value routine,
  no callback routine, no analog routine.
* A tree-wide grep for `acbAcceptedPoint|acbInitialStep|acbFinalStep|acbAbsTime|
  acbElapsedTime|acbConvergenceTest|vpi_get_analog_*|vpi_register_cb|
  vpi_remove_cb|vpi_handle_multi|vpiDerivative|stf_partials|
  vpi_register_analog_systf` outside `src/vpi/vpi_user.h` returns **only prose
  hits** — five comments in `lib/backend/codegen.zig`, two in
  `lib/diag_code.zig`. Zero code.
* `src/vpi/vpi_user.h` says so itself: P02 values and P03 callbacks are listed
  as "WHAT IS NOT HERE YET".
* `tests/fixtures/ch12_vpi_routines/` is 38 `.va` files. Two (`01_analog_systf_
  resistor_call.va`, `02_analog_systf_sampler_call.va`) pin that an unregistered
  `$name` is legal source and does not break the surrounding block; the other 36
  are `*_not_va.va` rejections pinning that a VPI ROUTINE name is not a
  Verilog-AMS function. **None of them exercises a VPI routine at runtime.**
  `tests/vpi_app.c` is the only runtime-behavioural VPI artifact in the tree and
  it belongs to the merged P01 `vpi` worktree; it uses none of the P03 surface.
* Branch `w2/vpi2` is a provisioned, unstarted work slot: 0 commits ahead of and
  behind HEAD, clean worktree, one reflog entry. It contributes nothing.

**One thing IS implemented and is spec'd here anyway**, because it was
implemented without evidence: `tools/contract.zig` declares `Systf` and
`SystfHost`, and `lib/backend/codegen.zig:emitSystfCall` emits a
value-plus-partials crossing that reconstructs the dual —
`zsr.add(arg.addC(-arg.val()).scale(partial))` — explicitly citing §12.22.1 and
§12.32's `derivtf`. So VerA's *generated device* side of partial-derivative
propagation exists. What does not exist is (a) any VPI layer above it, and (b)
any host that binds it: `ARPice/src/analysis/eval.zig:2697` declares *"This
simulator's VPI application, and it deliberately has no `systf`."* Fixture 07 is
the first executable check that the crossing computes the right number; nothing
today does.

## LRM clauses covered

Read from the offline HTML in `docs/ch11-vpi.html` and `docs/ch12-vpi-routines.html`.

| Clause | What it fixes |
|---|---|
| 11.6.6 | Branches; bit-level branch → Quantity via `vpiFlow` / `vpiPotential` |
| 11.6.7 | Quantities; "real value"/"imaginary value" via `vpi_get_analog_value()` |
| 11.6.25 | Callback object; `cb info` via `vpi_get_cb_info()` |
| 12.2 | Error status: level, `vpiPLI` state, code, message |
| 12.6 | `vpi_get_cb_info()` |
| 12.7 | `vpi_get_analog_delta()`; "shall return zero (0) during DC or the time zero transient solution" |
| 12.8 | `vpi_get_analog_freq()`; "shall return zero (0) during DC or transient analysis" |
| 12.9 | `vpi_get_analog_time()` |
| 12.10 + Table 12-2 | `vpi_get_analog_value()`, Figure 12-3, the four formats, both buffer rules |
| 12.13 | `vpi_get_analog_systf_info()` |
| 12.22.1 / 12.22.2 | `vpi_handle_multi(vpiDerivative, …)`; the `$resistor` example |
| 12.30 | `vpi_put_value()` on a derivative object and on a systf output argument |
| 12.31 + Figure 12-17 | `vpi_register_cb()`, `s_cb_data` |
| 12.31.3 | `acbInitialStep`, `acbFinalStep`, `acbAbsTime`, `acbElapsedTime`, `acbConvergenceTest`, `acbAcceptedPoint` |
| 12.32 + Figure 12-18 | `vpi_register_analog_systf()`, name uniqueness per domain |
| 12.32.2 | `derivtf`, `s_vpi_stf_partials` |
| 12.32.3 | the `$sampler` sample-and-hold example |
| 12.33.2 | `vlog_startup_routines` |
| 12.34 | `vpi_remove_cb()` |
| 8.4.7 | accept/reject ordering: the engine cannot advance before accepting |

## Files

`p03_vpi_analog.h` is not a fixture. It is the P03 delta over
`src/vpi/vpi_user.h` — Figures 12-3, 12-17, 12-18, §12.32.2's partials, and the
routine declarations — without which no plugin compiles. **When P03 lands it is
deleted and its contents move into `src/vpi/vpi_user.h`.** It records three
inconsistencies inside the LRM's own text (Figure 12-17's `p_vpi_time time`
pointer vs §12.32.3's `cb_data.time.real`; §12.32.2's `derivative_wrt` vs
§12.22.2's `derivative_to`; `calltf(int, int)` vs `compiletf(p_cb_data)`) and
resolves each in favour of the normative structure definition. Constants with no
standard number (`acb*`, `vpiDerivative`, `vpiExpStrVal`, …) are in one fenced
block; **no fixture asserts any of their values.**

### Designs

| File | Solution, in closed form |
|---|---|
| `p03_ramp_load.va` | `V(out) = 1000·t` exactly (ideal ramp source, 1 kΩ load) |
| `p03_dc_divider.va` | `V(a) = 1.25 V`, `I = 1.25/500 = 2.5e-3 A` exactly |
| `p03_rc_ac.va` | 1 A into R‖C, `C = 1e-3/(2π·1e3)`, so at 1 kHz `V(a) = 1000/(1+j) = 500 − 500j` |
| `p03_sampnhold.va` | §12.32.3's own `sampnhold` module + the 1000 V/s ramp |
| `p03_systf_devices.va` | §12.22.2's `$resistor` at 1 V / 1 kΩ, and `$cube` with `(V+1)³−1 = 7 ⇒ V = 1` |

All five lint clean under `./zig-out/bin/vera --lint` today (two W0650
finite-range speed warnings, no errors).

### Fixtures — one line each, with the expected value and where it comes from

| Fixture | Pins | Expected value and derivation |
|---|---|---|
| `01_time_delta_freq_at_zero.c` | 12.7/12.8/12.9 at the time-zero transient solution | `time == 0`, `delta == 0`, `freq == 0`, **exact equality**, all three literal in the clause text. Plus: at a later accepted point both `time > 0` and `delta > 0`, so the zeros are a property of t=0 and not of a stub that returns zero always. `acbInitialStep` count 1 |
| `02_accepted_point_sequence.c` | 12.31.3 sequence shape + 12.7's identity | `acbInitialStep` 1×, before every accepted point; `acbFinalStep` 1×, after; accepted times strictly increasing (8.4.7); at every accepted point `vpi_get_analog_delta() == t_k − t_{k−1}` to 1e-15 relative; last accepted time `== 5.0e-3` (= the deck's `tstop`). The *count* of accepted points is deliberately never asserted — no clause fixes it |
| `03_forced_solution_points.c` | 12.31.3 "shall force a solution at that time" | `acbAbsTime` at 2.5e-3 → `time == 2.5e-3`, `V(out) == 1000·2.5e-3 == 2.5 V`. `acbElapsedTime` interval 1.5e-3 from t=0 → 1.5e-3 / 1.5 V, re-armed from inside itself → 3.0e-3 / 3.0 V. All three are also delivered to a separate `acbAcceptedPoint` callback (a forced point is an accepted point). 2.5e-3 is coprime to the 1.5e-3 grid and not a round fraction of `tstop`, so no natural schedule hits it by accident |
| `04_remove_cb_during_dispatch.c` | 12.34 removal from inside a callback | Four `acbAbsTime` armed at 1,2,3,4 ms. An `acbAcceptedPoint` removes the 3 ms one when dispatched at exactly 2 ms → hit counts **1, 1, 0, 1**. The 4 ms one removes *itself* mid-dispatch → `vpi_remove_cb` returns 1 and the routine still completes. An `acbConvergenceTest` removes an `acbAcceptedPoint` at the same instant → suppressed at that instant too, because 12.31.3 orders "prior acceptance" strictly before "upon acceptance" |
| `05_convergence_test_rejection.c` | 12.31.3 `acbConvergenceTest` + 8.4.7 | Exactly 1 rejection issued, at the first attempt with t ≥ 2e-3. The next convergence test is at a **strictly earlier** time ("backup to an earlier time"); no acceptance happens in between; every `acbAcceptedPoint` at t is preceded by a convergence test at the same t; the run still reaches `acbFinalStep` at `t == 5.0e-3` |
| `06_sampler_plugin.c` | 12.32.3's sample-and-hold, made to build and to assert | Capture grid 0…5 ms at 1 ms → **6 captures**, values **0, 1, 2, 3, 4, 5** V (V(in)=1000·t at t=k·1e-3 is k). Held output probed at two non-capture instants: `V(out)(2.50e-3) == 2` and `V(out)(4.25e-3) == 4`. A pass-through sampler gives 2.5 and 4.25 and fails |
| `07_derivtf_partials.c` | 12.22.1/12.22.2/12.32.2 — a declared partial reaches the Jacobian | `$resistor` (LRM's own): `V == 1`, `curr == 1e-3`, `d(curr)/dV == 1e-3`, and the derivative object reads back what `calltf` put. `$cube`: `(V+1)³ = 8` ⇒ `V(q) == 1.0` exactly, branch current `== 7 A`, `d/dV == 3·(1+1)² == 12.0`. `$cube` is the discriminator — a host that drops the declared partial has a singular column and cannot converge at all, where `$resistor` alone would still land on the right answer |
| `08_analog_value_formats.c` | 12.10 + Table 12-2, all four formats, both buffer rules | `vpiRealVal`: 1.25 and 2.5e-3, imaginary 0.0. `vpiExpStrVal`: `"1.250000e+00"`, `"0.000000e+00"`, `"2.500000e-03"` (C's own %e). `vpiStringVal`: `"1.25"` (%g) **and the format field is reset** to `vpiExpStrVal`/`vpiDecStrVal`. `vpiDecStrVal`: `strtod` round-trips to 1.25. Buffer rule 1: an intervening `vpi_get_str()` must not disturb the analog string. Buffer rule 2: the next `vpi_get_analog_value()` must overwrite it |
| `09_ac_freq_and_imaginary.c` | 12.8 + 12.10's imaginary union | At 1 kHz: `freq == 1000.0` exactly, `Re V(a) == +500.0`, `Im V(a) == −500.0`. At the large-signal solution of the same deck: `freq == 0.0` and both parts 0. The 45° point is chosen so a swapped or sign-flipped pair has the right magnitude and still fails |
| `10_repeated_analyses.c` | 12.31.3 across two transients in one run | `acbInitialStep` 2×, `acbFinalStep` 2×; at each initial `t == 0` and `V(out) == 0`; at each final `t == 2e-3` and `V(out) == 2`; and an `acbAbsTime` at 1.5e-3 armed *between* analyses (from the first `acbFinalStep`) fires **exactly once**, in the second transient, at 1.5e-3, `V(out) == 1.5` |
| `11_registration_roundtrip.c` | 12.13, 12.6, 12.32's uniqueness | Every field of Figure 12-18 written distinct and read back identical (`vpiAnalogSysFunc`, `vpiRealFunc`, `"$p03_probe"` by `strcmp`, four distinct function pointers, one `user_data` pointer); every field of Figure 12-17 likewise, with `time->real == 2.5e-3` and the callback actually delivered once at 2.5e-3. A second analog registration of the same name is refused with 12.2's error |
| `90_reject_underivative_handle.c` | **reject** — 12.22.1 "can only be called for those derivatives allocated during the derivtf phase" | `derivtf` declares only `of={1}, wrt={2}`. `vpi_handle_multi(vpiDerivative, arg1, arg2)` → non-NULL; `(arg2, arg3)` and `(arg1, arg3)` → **NULL + `vpiError`** with a state, code and message — `(arg1, arg3)` is `d(curr)/dr`, mathematically real, which is the point: the rule is about what `derivtf` *allocated*. `vpi_put_value(NULL, …)` must fail, not dereference. 3 errors reported, and the analysis still converges to `V == 1` |
| `91_reject_stale_callback_handle.c` | **reject** — 12.34 "the handle is no longer valid" | `vpi_remove_cb` on a live callback → **1**; on the same handle again → **0** + `vpiError`; on `NULL` → **0** + `vpiError`; on a module handle → **0** + `vpiError`; `vpi_get_cb_info` on the removed handle → error, not a crash. 4 errors reported. And the removed `acbFinalStep` routine runs **0 times** — the check none of the return values can make |

Ten positive fixtures, two rejections.

## Deliberately open, and why

* **The `acbConvergenceTest` return encoding.** Figure 12-17 types `cb_rtn` as
  returning `int`; §12.31.3 gives the callback the power to reject; no clause
  spells the encoding. `05` **fixes** it as 0 = accept, non-zero = reject, to
  match every other callback where 0 is the uneventful return. An implementation
  that picks the other polarity must change the fixture and say so in this file
  — it may not leave the question open, because an application cannot be written
  against an unspecified return.
* **Whether the first solution is also an `acbAcceptedPoint`.** §12.31.3 gives
  it its own reason ("acbInitialStep — Upon acceptance of the first analog
  solution") and does not say whether acbAcceptedPoint fires for it too. `02`
  seeds `prev_t = 0` in acbInitialStep and requires every accepted time to be
  strictly greater, which fixes the reading VerA implements
  (`src/vpi/analog.zig`): the first solution is delivered as acbInitialStep
  only; every later one — the final one included — is an accepted point.
* **Dispatch order among same-reason callbacks.** Neither Verilog-AMS §12.31 nor
  IEEE 1364 §27 fixes the order of two `acbAcceptedPoint` routines at one point.
  Nothing here asserts it. The only ordering asserted is the one the clause text
  supports: `acbConvergenceTest` ("prior acceptance") strictly before
  `acbAcceptedPoint` ("upon acceptance") at the same time, and `acbInitialStep`
  / `acbFinalStep` bracketing the rest.
* **The numeric values of `acb*`, `vpiDerivative`, `vpiExpStrVal`, `vpiFlow`,
  `vpiPotential`.** Verilog-AMS prints no header listing and IEEE 1364's Annex G
  has no AMS names. Allocated in `p03_vpi_analog.h`; asserted nowhere.
* **A per-frequency callback reason.** §12.31.3 defines none. `09` therefore
  identifies a small-signal solution by calling `vpi_get_analog_freq()`, which is
  what §12.8 is for, rather than inventing `acbFrequencyPoint`.
* **`vpi_register_systf()` and the digital half of §12.32's uniqueness rule**
  ("the same name can be shared ... provided that one set is registered in the
  digital domain") — P02's routine, not declared here.
* **`vpi_get_value`/`vpi_put_value` format coverage beyond `vpiRealVal`**, delays
  and delayed writes, force/release, MCD, `vpi_sim_control` — P02.
* **`sizetf` behaviour.** `11` round-trips the pointer; nothing calls it. A sized
  analog function has no fixture here.
* **ARPice host fixtures.** None written, deliberately. The host-side gap is real
  (`eval.zig` binds no `SystfHost`), but there is no standard netlist spelling
  for "load this VPI application" — that is a simulator CLI decision, not an LRM
  one — so it cannot be pinned by an LRM-derived fixture in the `.sp` +
  `expected.json` format that `ARPice/tests/pending/A09` uses. The numerical
  content that would have gone there (partial-derivative propagation producing
  `V(q) == 1.0` and `d/dV == 12.0`) is asserted from inside `07` instead, which
  is where a C plugin can actually observe it.
* **Rejected transient points are exercised but not *counted*.** `05` forces one
  rejection and pins the backup; `02` pins that `delta` reflects accepted points
  rather than attempted ones. How many rejections a given engine makes on its own
  is not a language property. `ARPice/tests/pending/A09` covers the source-level
  accept/reject obligations.

## Build and run

Nothing wires these up yet. The step to add, modelled on `test-vpi` in
`build.zig:572-626`:

```
zig build test-vpi-p03
```

For each `NN_*.c` in this directory it must:

1. read the `*!` tag block in the C file's banner comment:

   ```
    *! design   <file>.va          exactly one
    *! analysis <op | tran 0 <tstop> | ac <fstart> <fstop> <npoints>>
    *!                             one or more, run in order, in ONE process
    *! expect   <file>.expected.txt
   ```

2. compile the plugin with `-std=c99 -Wall -Wextra`, `-I tests/pending/P03`
   and `-I src/vpi` (all thirteen compile clean today under `zig cc`; they do
   not *link*, which is the deliverable);
3. compile the named design through the ordinary engine and link the generated
   device into a host that can actually solve it — unlike `tests/vpi_host.zig`,
   which stops at `.lint`, P03 needs a real transient/DC/AC solve, so this step
   is the ARPice path;
4. install the elaborated design as the VPI object model and call
   `vlog_startup_routines` (§12.33.2) **before the first analysis**;
5. run the listed analyses in order in one process;
6. require **exit code 0** and **stdout byte-identical** to the named
   `.expected.txt`. A plugin exits 1 at its first failed check with the clause
   on stderr; the single census line is what proves the startup routine ran at
   all.

Until step 3 exists the whole row is red, which is correct: the row is not
implemented.
