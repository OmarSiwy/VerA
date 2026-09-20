# M02 — Mixed-signal synchronization

Pending fixtures for the analog/digital synchronization row. Every file here is
expected to FAIL today; see "Ground truth" below for exactly where.

## Ground truth (read from source, not from COVERAGE.md)

What actually exists:

- `src/sim/scheduler.zig` — a real implementation of §8.5.1's stratified queue.
  Six current-time regions (`active, explicit_d2a, inactive, nba, analog,
  monitor`) plus a future heap, lazy cancellation that cannot create phantom
  timesteps, generation-tagged handles, and `consumeAnalog`, which implements
  §8.5.3.7's "a single evaluation of the analog macro-process shall consume all
  of these events from the queue". It carries 12 Zig unit tests. **It is a
  standalone data structure.** Nothing posts `.analog` or `.explicit_d2a` events
  to it: `grep -n '\.analog\|explicit_d2a' src/sim/digital.zig` finds only
  `m.analog.len != 0` in a *rejection* predicate.
- `src/sim/digital.zig` — the `vera --run` source executor. Line 1023 refuses any
  module that has ports, parameters, instances, branches, events, functions **or
  an analog block**. So no mixed-signal source can reach the digital engine at
  all.
- The analog side of `cross`/`timer`/`above` fires inside the testbench harness
  (`tests/fixtures/ch05_analog_behavior/event_cross_fires.va` is green), but the
  events terminate in analog-context variables. There is no A2D delivery to a
  digital process, no D2A, and no quantization of an analog time to a tick.
- `absdelta` parses and is refused with E0513 ("absdelta() is not implemented").
- Host side: `ARPice/src/analysis/tran/tran.zig` has genuine step acceptance and
  rejection (LTE, device state-flip, `$bound_step`, breakpoints), but no
  cross/A2D/D2A concept and no digital engine to synchronize with.

Net: M02 is greenfield above the queue. The queue itself is implemented without
source-level evidence, which is why 09 and 10 pin its two ordering rules from a
`.va` fixture rather than trusting the Zig unit tests.

Confirmed current failure of each fixture — captured from the loop in
*Build / run*, re-run after the post-review edits:

| file | today |
| --- | --- |
| 01 | `E0205 unsupported module item: found 'assign'` |
| 02, 03, 09, 10, 11 | `E0209 expected an expression: found '#'` (no delay in `initial`) |
| 04–08, 12, 13 | `E0205 unsupported module item: found 'always'` |

## LRM clauses covered

- **§8.4.1** circuit initialization (nodeset, `analog initial`, time-zero `initial`)
- **§8.4.2** mixed-signal DC analysis — iterate analog DC and time-zero digital
  until the A/D boundaries reach steady state
- **§8.4.3.2** analog macro-process scheduling: acceptance time, wake-up events,
  implicit sensitivity to digital signals, the `d2a` / `d2aC` examples,
  re-evaluation at any time
- **§8.4.3.3** A/D boundary timing: quantization to half the precision base, the
  zero-delay D2A round trip, Figures 8-3/8-4/8-5
- **§8.4.4** the synchronization loop and event cancellation (Figure 8-6)
- **§8.4.6** absdelta interpolated A2D events
- **§8.4.7** assumptions about the analog and digital algorithms: digital
  granularity, no events for an already-executed earlier time, accept/reject of
  analog solutions, A2D events rejected with their solution, D2A events forcing a
  solution
- **§8.5** explicit and implicit D2A events, analog macro-process events
- **§8.5.1** the seven-region stratified event queue
- **§8.5.2** the digital engine reference model — an update event drained from a
  region "update[s] the modified object; add[s] evaluation events for sensitive
  processes to event queue" (07)
- **§8.5.3.1** continuous assignment as a process
- **§8.5.3.4** non blocking assignment — "always computes the updated value and
  schedules the update as a nonblocking assign update event"; no same-target
  merge (07)
- **§8.5.3.6** processing explicit D2A events (region 1b)
- **§8.5.3.7** processing analog macro-process events (region 3b)
- **§5.10.3.1** `cross` (timestep control, the crossing box)
- **§5.10.3.4** `absdelta` (trigger list, interpolation, no forced timesteps)
- **§3.2** integer default value — "Integer variables whose values are assigned in
  an analog context default to … zero (0). Integer variables whose values are
  assigned in a digital context default to … x." Every fixture that counts events
  from an `always` block (04–08, 11, 13) therefore carries an `initial` seed; the
  earlier drafts assumed a digital-context `integer` starts at 0 and would have
  been "fixable" by making VerA zero-initialize them, which §3.2 forbids.

## Fixtures

All voltage waveforms are piecewise linear between the declared `//! time`
points; every crossing time below is read off that line and stated in the
fixture header too.

1. **`01_dc_time_zero_settle.va`** (§8.4.2, §8.4.1, §8.5.3.1) — `initial a=1`
   feeding two continuous assignments. Time-zero digital activity must be
   iterated to steady state before the DC solve: `a=1 → b=0 → c=1`, so the D2A
   output is **1.0 V** and the intermediate **0.0 V**. Two inverters, not one, so
   "iterated" is distinguishable from "evaluated once". Continuous assignments
   rather than `always @(a)` to remove the IEEE 1364 §11 time-zero start race.
2. **`02_implicit_d2a_bus.va`** (§8.4.3.2, §8.5) — the LRM's own 16-bit `d2a`,
   `Vgain = 2^-16`. Codes `16'h4000/8000/C000` = 16384/32768/49152 give exactly
   **0.25 / 0.50 / 0.75 V** on [0,4 ns), [4,12), [12,∞). Pins implicit
   sensitivity: the analog block must re-solve when any bit of the bus changes.
3. **`03_guarded_d2a_holds.va`** (§8.4.3.2) — the LRM's `d2aC`. `val` changes at
   6 ns with no clock edge, so the output must **hold 0.25 V** through 6/8/10 ns
   and only become **0.75 V** at the 12 ns posedge; **0.0 V** before the first
   edge. The falsifying direction of 02.
4. **`04_a2d_tick_quantization.va`** (§8.4.3.3, §8.5.1, §5.10.3.1) — 0.1 V/ns
   ramp. `cross(V−0.52)` at 5 + 0.02/0.1 = **5.2 ns → `$time` == 5** (rounds
   down); `cross(V−0.76)` at 7 + 0.06/0.1 = **7.6 ns → `$time` == 8** (rounds
   up). Both errors ≤ 0.5 ns. `$abstime` at the first crossing stays
   **5.2e-9 s**, which is what makes "5" mean "rounded".
5. **`05_zero_delay_d2a_roundtrip.va`** (§8.4.3.3, §8.4.4, §8.5) — Figure 8-4's
   own numbers. Crossing at 5.2 ns: **tick_a == 5**, the zero-delay inverter's
   output **tick_b == 5** (same tick), but the analog kernel sees B at
   **5.2e-9 s**, not 5.0e-9. B falls from 1 to 0 there.
6. **`06_unit_delay_tick_alignment.va`** (§8.4.3.3, §8.4.4, §8.4.7) — Figure 8-5.
   Same 5.2 ns crossing, `b <= #1 ~a`. The delay applies to the *quantized* time:
   **tick_b == 6** and the analog kernel sees B at **6.0e-9 s**, not
   5.2e-9 + 1e-9 = 6.2e-9. Mirror image of 05. Tolerance **1e-18 s**, not 0.0:
   6e-9 and 6 * 1e-9 are one ULP apart in IEEE double (0x1.9c511dc3a41dfp-28 vs
   0x1.9c511dc3a41e0p-28, 8.3e-25 s), so a tool that forms the D2A time as
   `tick × time_unit` — which is what this fixture is *for* — failed it. 1e-18 is
   1.2e6 ULP wide and still 2e8 times narrower than the 2e-10 s error it rejects.
   The arm selector moved from `$abstime < 6n` to `< 5.5n` for the same reason;
   there is no reported timepoint between 5 ns and 6 ns, so nothing else changes.
7. **`07_glitch_absorbed_at_one_tick.va`** (§8.4.4, §8.4.3.3, §8.5.1, §8.5.2,
   §8.5.3.4, §5.10.3.1) — Figure 8-6. Triangle across 0.52 V: rising crossing at
   5 + 0.02/0.2 = **5.1 ns**, falling at 5.2 + 0.02/0.2 = **5.3 ns**, both round
   to tick 5, so both `b_dig <= #1 ~a_dig` executions queue an NBA update for
   tick 6. §8.5.3.4 says a nonblocking assignment *always* schedules an update
   event — there is no same-target merge — and §8.5.2's reference model says each
   update event drained from region 3 updates the object and "add[s] evaluation
   events for sensitive processes". So `b_dig` transits 1 → 0 → 1 inside region 3
   and the file asserts both halves of that:

   - **`n_fall == 1` from 7 ns** — a `always @(negedge b_dig)` counter sees the
     first update. Bounded 0..1 everywhere.
   - **`b_dig` net value == 1 at every reported timepoint** — the second update
     put it back; the transit is interior to region 3.
   - guard, shared with 08: both A2D edges delivered (`n_a == 2` from 5.4 ns).

   *Corrected twice.* The **first** draft asserted the second NBA *cancels* the
   first and that `ana_b == 0.0` with tolerance 0.0. Neither is 1364: nothing
   coalesces same-time NBAs to one target, and an implementer could have
   satisfied the file by teaching VerA to do so — a real standard violation.
   Figure 8-6's "canceling" is the D2A **connectmodule driver's** transition
   filter, which this SPEC defers to M04, so the wake-up claim moved there.
   `ana_b` is still captured and kept live through V(vo) with a nonzero
   coefficient, so M04 can pin it without rebuilding the stimulus.

   The **second** correction is `n_fall`. Review found that after the first
   correction the file had no teeth: a tool implementing none of this clause
   leaves `b_dig` at its `initial` 1'b1 forever and passes the value check
   trivially, and the only surviving content, `n_a == 2`, is cross()-to-digital
   counting that 08 already owns outright. `n_fall` is the missing observable and
   it is entirely digital — no connectmodule, no transition filter. The two
   checks now fail in opposite directions: no-delivery *and* NBA-coalescing both
   read `n_fall == 0`; delivering only the rising crossing reads `n_fall == 1`
   but leaves `b_dig == 0`. Only performing both updates in order passes both.
   `negedge` rather than any-change because IEEE 1364 §11 leaves the time-zero
   `initial`/`always` start order unspecified and x → 1 is not a negedge; pinned
   from 7 ns rather than 6 ns because the reported 6 ns point is a declared
   observation, not a D2A-forced one, so §8.5.1's region 3 → 3b order does not
   fix its position relative to the drain.
8. **`08_closely_spaced_crossings.va`** (§8.4.7, §8.4.3.3, §8.5.1) — same
   stimulus, digital side. **`n_a == 2`** (each crossing exactly once, bounded
   ≤ 2 at every timepoint), **both timestamps == 5**, **rise executed before
   fall**, **final level 0**. Catches same-tick coalescing, dropping an event at
   an already-executed tick, and out-of-order delivery.
9. **`09_explicit_d2a_reads_post_active.va`** (§8.5.3.6, §8.5.1, §8.5, §8.4.7) —
   region 1b. The digital process writes `da=3, db=4` blockingly and queues
   `da<=9`. The analog block's `@(posedge clk) s = da + db` must read
   **s == 7.0** — not 0 (before region 1) and not 13 (just before region 3b,
   which is the reading the clause explicitly rules out). Three distinguishable
   values by construction.
10. **`10_macro_process_runs_after_nba.va`** (§8.5.1, §8.5.3.7, §8.5, §8.4.7) —
    region 3 before region 3b. `q <= d` is a region-3 update; the analog block
    reads `q` unguarded, so the implicit D2A posts a region-3b macro-process
    event at the same tick. The 4 ns solve must already read **1.0 V**. Same tick
    as 09, opposite rule, different number.
11. **`11_rejected_trials_deliver_once.va`** (§8.4.7, §8.4.3.2, §8.5, §5.10.3.1)
    — monotone ramp, one crossing at **5.2 ns → tick 5**. `kick` toggles at ticks
    6/7/8, each forcing another macro-process solve after the crossing is past.
    **`n_cross` ∈ [0,1] at every timepoint and == 1 from 6 ns**;
    **`tick_first == tick_last == 5`**; the sampled value is inside §5.10.3.1's
    box (≥ 0.52, ≤ 0.6). Catches A2D events escaping from rejected trials and
    re-firing of a consumed event on re-evaluation.
12. **`12_comparator_dac_feedback.va`** (§8.4.3.3, §8.5.1, §5.10.3.1) — the
    comparator/DAC loop. Trips at **5.2 ns** and **7.6 ns**, each `code <= code+1`
    (zero delay) driving a 0.25 V/step DAC, so the settled output is the exact
    staircase **0.00 / 0.25 / 0.50 V** partitioned on the comparator input. The
    zero-delay round trip must complete inside one digital time, so the 5.2 ns
    solution already reads 0.25 V.
13. **`13_absdelta_interpolated_a2d.va`** (§8.4.6, §5.10.3.4) — 0.1 V/ns ramp to
    **1.2 V**, `absdelta(V, 0.25, 1p, 1u)` in an `always` block. Events at **0,
    2.5, 5, 7.5, 10 ns** (initialization event plus one per 0.25 V) and no sixth
    (it would need 1.25 V at 12.5 ns), so **`n` = 1/2/3/4/5** and **`sampled` =
    0.00/0.25/0.50/0.75/1.00 V** (tolerance 1u = `expr_tol`). The declared analog
    grid is **0/4/8/11/12 ns** precisely so all four non-initialization events
    must be *interpolated* between analog solutions — absdelta may not force a
    timestep. Voltage tolerance **4u**, derived below.

    *Corrected after review, twice.* The grid used to end at 10 ns / 1.00 V, which put
    the fifth event exactly on the last declared timepoint and left it unforced
    twice over: the trigger is "changes … by **more than** delta" and 0.75 → 1.00
    is exactly delta, and §5.10.3.4's expr_tol placement window
    (1e-6 V / 0.1 V/ns = ±1e-5 ns, i.e. [9.99999, 10.00001] ns) had half its
    width past the end of the run. `n = 4, sampled = 0.75` was as conforming as
    `n = 5`; the fixture failed a correct implementation. Running to 12 ns puts
    the fifth event and its whole window 2 ns inside the run and the sixth 0.5 ns
    outside it. The arm selectors did not have to move — they were already at
    2.5/5/7.5/10 ns, all ≥ 0.5 ns clear of every observation.

    The **second** correction is the voltage tolerance, found while re-deriving
    the first. §5.10.3.4 lets the simulator place an event anywhere between the
    interpolated change of `delta − expr_tol` and `delta + expr_tol`, and
    measures that change **"relative to the previous `absdelta()` event"** — so
    the ±1e-6 V of slack is spent *afresh on every event* and the errors add:
    ±1/±2/±3/±4 × `expr_tol` on events 1–4. The file wrote **1u** on all four
    arms and justified it in the header as "expr_tol, not a fudge factor"; that
    justification is only true of the first event, and a conforming tool that
    lands each event at the `delta + expr_tol` end of its window read 1.000004 V
    at the fifth and **failed**. Now **4u**, still derived from `expr_tol` rather
    than widened to taste, and still 12 500× narrower than the 0.05 V gap to the
    nearest wrong arm and 200 000× narrower than the 0.8 V a non-interpolating
    tool reads at 8 ns. The count arms are untouched: the same slack moves an
    event *time* by only `1e-6 V / 0.1 V/ns` = 1e-5 ns per event, 4e-5 ns
    cumulative, against selectors ≥ 0.5 ns clear of every observation.

No reject fixtures. The one obvious candidate (§5.10.3.4's "only allowed in an
`initial` or `always` block") would today match E0513 "absdelta() is not
implemented", i.e. it would pin VerA's ceiling rather than the LRM rule, so it is
deliberately omitted.

## Deliberately NOT covered

- **Exactly-half-tick rounding** (an A2D event at exactly *n*.5 ticks). §8.4.3.3
  bounds the error at half the precision base but does not name a tie-break, so
  either neighbour conforms. 04 stays at 0.2 ns and 0.4 ns errors on purpose.
- **§8.5.3.7's "a single evaluation consumes all active events"** as a *count* of
  macro-process solves. The number of analog evaluations is not observable from
  source — an NR iteration is an evaluation too. `scheduler.zig`'s
  `consumeAnalog` test covers it at the Zig level; a source-level version needs
  VPI `acbAcceptedPoint` (row P03).
- **`$driver_update` / `$driver_next_state` / `$driver_delay`**, used by
  §8.4.3.3's `d2a` connectmodule. That is row M04; 03 reaches the same guarded-
  sensitivity rule through `@(posedge clk)` instead.
- **Whether the analog block's explicit `@(b_dig)` wake-up fires during tick 6's
  interior 1 → 0 → 1 transit in 07.** Withdrawn from this row; **row M04 owns
  it**, because the answer is Figure 8-6's transition filter
  (`$driver_update`/`$driver_next_state`/`$driver_delay` plus `transition()`),
  which is M04's machinery and is listed one bullet up. It can come back here the
  day a fixture can express the filter without a connectmodule — i.e. once M04
  has landed the driver access functions and M03 the insertion. 07 still captures
  `ana_b` and keeps it live through `V(vo)` with a nonzero coefficient, so M04
  can pin it without rebuilding the stimulus.
- **Connectmodule insertion** — every fixture here keeps both domains inside one
  module, so nothing depends on automatic bridge insertion (row M03).
- **Repeated delta cycles driven by `#0`** across the A/D boundary, and
  `$monitor`/region-4 interaction with analog solves.
- **Multiple independent analog macro-processes** and the implementation-defined
  choice of solving them jointly (§8.4.3.2 note 1). Every fixture has exactly one
  macro-process.
- **Non-transient analyses.** Only 01 is DC; the rest are `//! analysis tran`.
  AC/noise A/D synchronization is untouched.
- **Host-side (ARPice) coverage.** Nothing is written under
  `ARPice/tests/pending/M02/`: the host has no digital engine, so there is no
  observable at that layer yet that is not already covered by the existing
  transient accept/reject tests.

## Corrected after review

An adversarial review of this row found four defects; re-deriving the fourth
turned up a fifth. All five are fixed here; nothing outside `tests/pending/M02/`
was touched.

1. **Seven fixtures assumed a digital-context `integer` starts at 0** (04, 05, 06,
   07, 08, 11, 13). §3.2 says it starts at **x**, so `n = n + 1` evaluated
   `x + 1 = x` forever and the headline `CHECKI` in 07, 08, 11 and 13 failed at
   *every* timepoint on a perfect implementation. The cheap "fix" would have been
   to make VerA zero-initialize digital integers — a spec violation. Each of the
   seven now carries one `initial` seed and a comment naming §3.2. Fixed already;
   listed here for completeness.
2. **Fixture 07 asserted NBA cancellation, which IEEE 1364 §9.2.2 does not do**,
   and after that was corrected it had **no teeth**. Both fixed: the file now
   pins §8.5.3.4's "always schedules an update event" and §8.5.2's "add
   evaluation events for sensitive processes" through a `negedge b_dig` counter,
   which fails on a coalescing tool, on a no-delivery tool and on a
   one-edge-only tool. The withdrawn `ana_b == 0.0` claim went to **row M04** —
   see the *Deliberately NOT covered* bullet for what would bring it back. The
   file was renamed `07_glitch_absorbed_at_one_tick.va`.
3. **Fixture 06's tolerance was exactly 0.0 on a floating-point time.** The
   asserted *value* (6.0e-9 s) was right; the tolerance was not. 6e-9 and
   6 * 1e-9 differ by one ULP in IEEE double, so a conforming tool that computes
   the D2A time as `tick × time_unit` failed. Now 1e-18 s, with the two-sided
   derivation (1.2e6 ULP wide, 2e8 narrower than the 2e-10 s error it rejects) in
   the fixture header. The arm selector `$abstime < 6n` carried the same hazard
   and moved to `< 5.5n`.
4. **Fixture 13's fifth `absdelta` event was not forced.** 0.75 → 1.00 V is
   exactly `delta`, not "more than" it, and §5.10.3.4's ±`expr_tol` placement
   window straddled the end of the run, so `n = 4` was as conforming as `n = 5`.
   The ramp now runs to 1.2 V on a 0/4/8/11/12 ns grid; the fifth event and its
   whole window sit 2 ns inside the run and the sixth 0.5 ns outside it.
5. **Fixture 13's voltage tolerance was too tight by up to 4×** — found by this
   pass, not by the review, while re-deriving (4). §5.10.3.4's ±`expr_tol`
   placement window is measured "relative to the previous `absdelta()` event", so
   it is spent once per event and the errors accumulate; the uniform `1u` on all
   four arms was correct only for the first. A conforming tool reading
   1.000004 V at the fifth event failed. Now `4u` = 4 × `expr_tol`, with the
   per-event table in the fixture header. This is the only *new* fixture change
   in this pass; 1–4 were applied earlier and are verified here, not redone.

Not disputed with the reviewer. Three notes on the *degree* of each fix:

- On 06 the review suggested only that the tolerance was wrong. Re-deriving it
  showed the same 1-ULP hazard in the arm **selector**, which the review also
  flagged in passing; both are fixed, and the `CHECKI` on `tick_b` and the
  `CHECKX` on `b_dig` were moved to the 5.5 ns selector too even though only the
  `CHECK` on `ana_b` compares a float.
- On 13 the review said "extend the ramp past 1.0 V". Extending the ramp alone
  is not enough: the *observation* grid also had to move off 10 ns, or the
  `$abstime < 10n` selector would itself have sat inside the event's placement
  window. Grid is now 0/4/8/11/12 ns. And extending the ramp does not touch the
  tolerance defect in (5), which the review did not raise at all.
- Every number and every quotation in (1)–(5) was re-derived rather than copied.
  Two spot-checks worth recording because they are the ones that could have gone
  the other way: `6e-9` really is `0x1.9c511dc3a41dfp-28` and `6 * 1e-9` really
  is `0x1.9c511dc3a41e0p-28`, 8.271806125530277e-25 s apart, so 06's 1e-18 band
  is 1 208 925 ULP; and §8.4.4's Figure 8-6 table, §8.5.2's reference model, and
  §8.5.3.4's "always computes the updated value" all read in `docs/` exactly as
  07 quotes them.

### Still open, and deliberately not touched here

**The `(V(vi) > 0.52) ? … : …` arm selector in 04, 05, 06 and 12 is a knife edge
under a simulator that inserts its own crossing timepoint.** §5.10.3.1 allows
that insertion and §9.4.6 makes `$strobe` fire at the end of every accepted
timestep, so a conforming tool strobes at ≈5.2 ns with `V(vi) − 0.52` somewhere
inside the crossing box — either sign — while the A2D event it triggered has not
yet been consumed by the digital engine (§8.4.7 rejects A2D events along with
their solution, so delivery follows acceptance). Both arms are therefore
reachable with the wrong `tick_*` value. Fixture 07 already avoids this by
bounding its counters everywhere and pinning them only from a time 0.5 ns clear
of every event (`(n_a >= 0 && n_a <= 2) && (($abstime >= 5.4n) ? (n_a == 2) : 1)`)
and 11 uses the same idiom; 04/05/06/12 do not. It is **not** live against
today's `tb.zig`, which is a fixed-grid evaluator that solves only at the
declared `//! time` points, none of which sits on a crossing. It is recorded
rather than fixed because the review did not raise it and the repair is a
four-file rewrite of derivations the review *did* verify; it should be done in
one pass, to 07's idiom, when the row is unblocked and the fixtures can first be
run against a solver that actually inserts timepoints.

**Inventory count.** `tests/pending/MANIFEST.md` §4 lists M02 as `13 (12/1)`.
There is no reject fixture in this row and never was — the count is `13 (13/0)`.
See the note under *Fixtures* for why the one candidate is omitted.

The row's failure table above was re-run against `zig-out/bin/vera` after these
edits (see *Build / run*); all thirteen files still stop at the same diagnostic
they stopped at before, which is the whole point — none of these fixtures is
satisfiable today. That table is captured output, not typed: it is the literal
first line of each file's `--check` run through the loop printed in *Build /
run*.

## Build / run

These are ordinary torture fixtures and need no new harness — only a directory
the scanner walks. Once `tests/pending/M02/*.va` is moved (or the scan root is
widened) they run under:

```sh
zig build torture -- M02          # this row only
zig build torture -- --strict     # the full gate, 1323/1323 today
```

To reproduce the current failure of a single file without wiring anything up:

```sh
zig build install
./zig-out/bin/vera --check --contract tools/contract.zig -I tests/fixtures \
    tests/pending/M02/04_a2d_tick_quantization.va
```

`--contract` and `-I tests/fixtures` are both required: `check.vh` lives under
`tests/fixtures`. The whole table above is one loop:

```sh
for f in tests/pending/M02/*.va; do
  printf '%s: ' "$(basename "$f")"
  ./zig-out/bin/vera --check --contract tools/contract.zig -I tests/fixtures "$f" 2>&1 |
    head -1
done
```
