# M01 — Reading and triggering across domains

Row M01 of `/home/omare/Documents/Projects/Zig/ARPice/docs/verilog-ams-conformance-plan.md`:

> - Implement legal discrete values read by analog expressions, X/Z-sensitive
>   case constructs, analog probes read by digital expressions and domain ownership.
> - Implement digital edges/named events in analog blocks and analog events in
>   digital processes, including `absdelta`.
> - Test conversion tables, event timing, interpolation and illegal cross-domain
>   assignments/function calls using an executing digital engine.

Greenfield: no `w2/*` branch covers it. 13 `.va` fixtures are written here —
**11 positive, 2 rejections**. **All 13 fail today**, each with the FIRST
diagnostic the compiler reports recorded in its own header.

Those headers have now been re-captured, by running

```
for f in tests/pending/M01/*.va; do
  echo "== $(basename $f)"
  ./zig-out/bin/vera --lint -I tests/fixtures "$f" 2>&1 | head -4
done
```

and pasting back what it printed, line numbers and all. The first version of
this document made the same claim and it was not true of three files: **05** and
**08** recorded their *second* blocker (E0705 and E0205 respectively) as though
it were the first, where the compiler in fact stops on `error[E0209]: expected
an expression: found #` in the stimulus of each; **10** listed E0513 ahead of
the E0205 on `always` that actually comes first. All three now carry the
captured text, and 05 additionally carries the reduced probe module that does
produce E0705 once the `#` delays are stripped — captured the same way, not
inferred. The other ten were checked against the same run and were already
right.

## LRM clauses covered

Read from the offline HTML in `/home/omare/Documents/Projects/Zig/VerA/docs/`.

| clause | title | source |
|---|---|---|
| §7.3 | Behavioral interaction — read from both, write only your own | `ch7-mixed-signal.html` |
| §7.3.1 | Table 7-1, discrete net/reg/variable access from a continuous context | `ch7-mixed-signal.html` |
| §7.3.2 | Accessing X and Z bits of a discrete net in a continuous context | `ch7-mixed-signal.html` |
| §7.3.3 | Accessing continuous nets and variables from a discrete context | `ch7-mixed-signal.html` |
| §7.3.4 | Detecting discrete events in a continuous context (Syntax 7-2) | `ch7-mixed-signal.html` |
| §7.3.5 | Detecting continuous events in a discrete context (Syntax 7-3) | `ch7-mixed-signal.html` |
| §7.3.6.1 | Analog event appearing in a digital event control | `ch7-mixed-signal.html` |
| §7.3.6.2 | Digital event appearing in an analog event control | `ch7-mixed-signal.html` |
| §7.3.6.3 | Analog primary appearing in a digital expression | `ch7-mixed-signal.html` |
| §7.3.6.5 | Digital primary appearing in an analog expression | `ch7-mixed-signal.html` |
| §7.3.7 | Function calls across the domain boundary | `ch7-mixed-signal.html` |
| §5.10.3.3 | `timer` analog event function, and where it forces a time point | `ch5-analog.html` |
| §5.10.3.4 | `absdelta` analog event function | `ch5-analog.html` |
| §5.10.4 | Named events, triggered from either domain | `ch5-analog.html` |
| §5.10.5 | Digital events in analog behavior | `ch5-analog.html` |

Supporting, cited inside headers and not pinned on their own: §7.2.1 (domain of
a value), §7.2.2 (a variable's domain is that of its writer), §5.10.3.1 (the
`cross` direction argument and its tolerance box), §5.10.3.3 (`timer`
start_time/period, and the sentence that makes the firing instant a reported
analog point), §4.7 ("Each function can be an analog user-defined function or a
digital function"), §3.2 (uninitialised defaults).

§4.7.2 used to appear on that list, described as "digital function
declarations". It is not: §4.7.2 is *Returning a value from an analog
user-defined function*, and its four subclauses are about the implicit
function-identifier variable, `return`, and output/inout arguments. The sentence
fixture 90 needs is the third of §4.7's opening paragraph. Corrected in the
fixture body and in its `//! lrm` line.

## Ground truth established before writing

Established by running the compiler on probe files, not from `COVERAGE.md`.

**VerA has two disjoint dialects, chosen by FILE EXTENSION.**
`src/main.zig:332` sets `Parser.digital = true` only for a `.v` input, and
`lib/frontend/parser.zig` gates on that flag in at least five places:

| gate | line | consequence for a `.va` file |
|---|---|---|
| `always` as a module item | `parser.zig:1265` | `E0205: unsupported module item` |
| `assign` (continuous assign) | `parser.zig:966` | `E0205: unsupported module item` |
| `#` delay control | `parser.zig:2324` | `E0209: expected an expression: found #` |
| non-blocking `<=` | `parser.zig:2619` | not reachable |
| net declaration assignment / dims | `parser.zig:992-993` | not reachable |

Verilog-AMS is the union of the two. **There is today no file in which an
`analog` block and a `#` delay can both be written**, which is why eight of the
eleven positive fixtures below die on `E0209` at the `#` before any clause-7
rule is reached. That single fact, not any individual clause, is the shape of
this row's work.

**What IS already implemented, and was not obvious from the docs:**

| claim | evidence |
|---|---|
| Table 7-1's bit-grouping row, for a reg written by a *constant* `initial` assignment | `reg [3:0] d; initial d = 4'b1010; analog y = d;` runs and prints `got=10 want=10 ok=1` under `vera --run --contract tools/contract.zig` |
| Table 7-1's `real` and `integer` rows | `tests/fixtures/ch07_mixed_signal/discrete_real_from_analog.va`, `discrete_bus_31.va`, `discrete_bus_narrow.va` — all green |
| a plain `case` over non-four-state labels, in an analog block, over a discrete reg | probe `r3`, compiles clean |
| §7.2.2's both-contexts refusal | `E0432`, reported at the analog assignment that collides with an `initial` one |
| §7.3.7's *second* sentence (analog function from a digital context) | `E0430`, at the call site, block accepted — genuinely pinned |
| named events *within* the analog block (`-> ev`, `@(ev)`) | `tests/fixtures/annex_a_syntax/17_named_event_trigger.va`, green |
| a real digital engine, with 4-state `case`/`casez`/`casex`, NBA regions, `#` delays and `$display` | `src/sim/digital.zig`, `tests/ieee1364/09_behavioral_modeling/control.v` |

**What is NOT implemented.** Each was confirmed by running a probe:

1. `always` in a module that is not a digital-only `.v` — `E0205`. This alone
   blocks §7.3.3, §7.3.5, §7.3.6.1, §7.3.6.3, §5.10.3.4 and the digital half of
   §5.10.4.
2. Reading a `wire`/discrete net by name in an analog expression — `E0315: net
   must be read through an access function`. §7.3.1's own `onebit_dac` example
   does not compile.
3. `===` / `!==` in an analog block — `E0323: case equality is not in the analog
   subset`. §7.3.2 lists these two operators first among the four features it
   provides for exactly this purpose.
4. `x`/`z` digits in a literal reachable from an analog block — `E0130`.
   §7.3.2 lists them fourth.
5. Syntax 7-2's first alternative, a bare `expression` event — `@(d)` on a reg
   is misread as a named event: `E0705: not a declared named event: d`. Not a
   refusal of the construct, a misparse of it as a different one.
6. `posedge`/`negedge` in an analog event control — `E0704: posedge/negedge is
   digital-only`, refused on an annex C (Verilog-A subset) rule that
   Verilog-AMS does not have.
7. `absdelta` — `E0513: absdelta() is not implemented`, VerA's own title.
8. `wreal` — `E0205` on the declaration (M04's row; noted so no one credits it
   here).
9. §7.3.7's *first* sentence — masked. The non-`analog` `function` declaration
   is `E0205`, so no caller is analysed.

The existing chapter-7 fixtures that name these constructs are almost all
`//! reject` files arguing from annex C.3/C.7/C.9, which are rules of the
**Verilog-A subset**. VerA targets Verilog-AMS, where C.9 ("Clause 7 only
applies to Verilog-AMS HDL") does not apply, so several of them are inversions:
they demand a diagnostic a conforming AMS compiler must not emit. Fixtures 03,
04, 05, 08 and 09 below are the positive replacements for
`xz_case_statement_compared.va` (was `_unsupported`), `digital_event_unsupported.va`,
`digital_probe_unsupported.va` and `digital_cross_unsupported.va`.
**Nothing under `tests/fixtures/` was touched.**

## Fixtures

Every `want` is hand-derived in the file's own header. `CHECKEQ` is used where
the expected value varies over the run and the oracle is the same partition
written from `$abstime` — the convention
`tests/fixtures/ch05_analog_behavior/event_timer_one_shot.va` already uses.

| file | clause | pins | expected value, and where it comes from |
|---|---|---|---|
| `01_onebit_dac_reads_a_discrete_wire.va` | §7.3.1 | Table 7-1's `bit` row for a `wire`, both halves: the exact bit-grouping mapping on a 4-bit net, and the clause's own `onebit_dac` | `code = 10`, from `reg [3:0] b = 4'b1010` driven onto `wire [3:0] code` — the row's "lowest bit of the bit grouping is mapped to the zeroth bit of the integer". Reversed order reads 5, an unwired net reads 0. Then `x = 3.0`: `in` is `code[1]` = 1, so `in == 0` is false and the else arm runs |
| `02_a2d_case_equality_over_x_and_z.va` | §7.3.2 | `===` against `1'b1`, `1'bx`, `1'bz` — the clause's `a2d` example | `avar` = 5.0, 5.0, 5.0 (held by the x arm), 2.5 at t = 0, 10n, 30n, 50n. `dnet` is 1 from t=0, x from 20n, z from 40n; oracle `($abstime < 40n) ? 5.0 : 2.5` |
| `03_a2d_case_statement_four_state_labels.va` | §7.3.2 | the same as a `case` with `1'bx:`/`1'bz:` arms, which the clause states is an alternative to 02 | identical numbers to 02, by the clause's own equivalence claim |
| `04_posedge_in_an_analog_event_control.va` | §7.3.4, §7.3.6.2 | `@(posedge clk1)` inside `analog`, sampled at "a real promotion of the digital time" | `vout` = 0.0 before 10n, 1.0 after. V(in) is the ramp `$abstime/10n` volts, so sampling at tick 10 reads exactly 1.0; sampling one analog point late reads 2.0, one early reads 0.5 |
| `05_bare_signal_change_event_in_analog.va` | §7.3.4, §5.10.5 | Syntax 7-2's first alternative, a bare `expression` event; fires on the falling edge `posedge` ignores | `held` = 0.0, 1.0, 2.0 at the ramp values for t = 0, 10n, 20n. A posedge-only tool reads 1.0 at t = 25n |
| `06_named_event_from_analog_reaches_digital.va` | §5.10.4, §7.3.6.1, §5.10.3.3 | `-> ana_event` under an analog `@(timer)` waking `always @(ana_event)` | `hits` = 0, 1, 2, 3 at t = 0, 10n, 20n, 30n, oracle `($abstime>=5n)+($abstime>=15n)+($abstime>=25n)`, **band 1.0**. `timer(5n, 10n)` fires at 5n, 15n, 25n and §5.10.3.3 makes each of those a reported analog point, so the check IS evaluated at a firing instant and the delivery order there is unfixed — one firing of slack, no more |
| `07_named_event_from_digital_reaches_analog.va` | §5.10.4, §5.10.5, §7.3.6.2 | `initial #10 -> dig_event` waking `analog @(dig_event)` — the clause's own snippet | `n` = 0, 1, 2 at t = 5n, 15n, 25n. Two triggers, ten ticks apart; a level-like implementation reads 1 at t = 25n |
| `08_analog_probe_in_a_digital_expression.va` | §7.3.3, §7.3.6.3 | `always @(posedge clk) out = V(in);` — the clause's `sampler` | `out` = 0.0, 0.0, 1.0, 1.0, 3.0 at t = 0, 5n, 15n, 25n, 35n. V(in) is flat at 1.0 across the 10n edge and flat at 3.0 across the 30n edge, and is 2.0 at the 20n *negative* edge, so a both-edge or negedge tool reads 2.0 at t = 25n |
| `09_cross_event_in_a_digital_always.va` | §7.3.5, §7.3.6.1, §5.10.3.1 | `always @(cross(V(clk) - 2.5, 1))` — the clause's `sampler2` | `n` = 0 at t = 0 and 5n, 1 at t = 10n, 15n, 20n; oracle `($abstime<=5n) ? 0 : ($abstime>=10n) ? 1 : n`, so the open interval (5n, 10n) asserts nothing. V(clk) goes 0→4→0, so `V(clk) - 2.5` crosses rising at 6.25n and falling at **13.75n**; `dir = 1` admits only the first, and a tool ignoring `dir` reads 2 at t = 15n and 20n |
| `10_absdelta_samples_an_analog_signal.va` | §5.10.3.4, §7.3.4 | the two latitude-free claims: `delta = 0` samples every timestep, and any `delta` bounds the drift | `tracked - $abstime*1e8` = 0 within 0.6 (one reported step 0.5 + window 0.1; the rule really is equality, and the file says what has to land in M02 before the band can close to 1e-12); `held - V(e_in)` = 0 within 0.5 = `delta` 0.3 + scheduling window 0.2. `delta` is **0.3**, strictly below the ramp's 0.5 step, because §5.10.3.4 fires on a change of "more than delta" |
| `11_digital_primary_uses_the_last_tick.va` | §7.3.6.5 | "the greatest digital time tick which is less than or equal to the analog time" — both halves | `code` = 1, 5, 5, 9, 9 at t = 5n, 10n, 15n, 20n, 25n. Values change at ticks 0/10/20; t = 10n and t = 20n exist only to separate `<=` from `<`, and an interpolating tool reads 3 at t = 5n |
| `90_digital_function_from_analog_rejected.va` | §7.3.7 | "Digital functions cannot be called from within the analog context" — must fire at the CALL, not at the declaration | refusal citing `LRM 7.3.7`. Today: `E0205` on the `function` keyword, which masks the rule |
| `91_analog_net_written_from_a_digital_process_rejected.va` | §7.3, §7.2.1 | "Write operations of nets and variables are only allowed from the context of their domain" — a contribution inside an `always` | refusal citing `LRM 7.3`. Distinct from `E0432`, which needs *two* writers; here there is one, in the wrong domain |

Two rejections against eleven positives, as required.

## Deliberately NOT covered

- **Rounding and delta-cycle placement.** §7.3.6.1's "nearest digital time tick"
  and "may appear to be in a delta cycle belonging to a tick started at an
  earlier or later time" are **M02's**, and mixing them in here would make a
  failure ambiguous between the two rows. Fixtures 04, 07 and 11 avoid the
  question outright — every event time in them is already on a whole tick under
  the declared `timescale`, so there is nothing to round. Fixtures 06 and 09
  cannot avoid it, because the analog event times they need (a `timer` firing, a
  `cross` at 6.25n) are points the simulator itself places, and this analog block
  is evaluated there. **They do not write digits at those points.** 06 states
  the count identity with a one-firing band; 09 states the exact integer outside
  the rounding window and makes the want the got inside it. Both say so in their
  headers with the sentence of §5.10.3.1/§5.10.3.3 that grants the latitude, and
  both name the digit to write once M02 settles the ordering.
- **Zero-delay feedback across the boundary**, trial-point rejection, and
  "shall not be scheduled earlier than the last or current digital event" —
  M02.
- **§7.3.6.4** (analog variables driving a continuous `assign`) and **`wreal`**
  — **M04**. `wreal` is `E0205` at the declaration today and fixture 10 uses a
  plain `real` instead of the LRM example's `wreal r_out` for exactly this
  reason.
- **§7.3.2's error cases** — `var1 = 1'bx`, `V(anet) <+ dnet` after `dnet` goes
  to z. Four fixtures in `tests/fixtures/ch07_mixed_signal/` already pin these
  as `E0130`, and their verdict is correct for AMS as well as for Verilog-A
  ("It is an error if these operands return x or z bit values when solved").
- **`casex` / `casez` in an analog context.** §7.3.2 lists them, but their
  wildcard semantics add a second axis that is fully covered on the digital side
  by `tests/ieee1364/09_behavioral_modeling/control.v`; fixture 03 pins the `case` form, which is the
  one the clause actually demonstrates.
- **`absdelta` event *timing*.** The clause grants an explicit scheduling
  window, so no firing time here is asserted — only the two consequences that
  hold whatever the simulator picks inside it.
- **Interpolation of a continuous variable read at a digital time** (§7.3.3's
  last paragraph, §7.3.6.3's). Fixture 08 reads a *probe*, not a continuous
  variable, and holds V(in) flat across each sampling edge on purpose, so the
  interpolation-vs-last-assignment distinction is neither asserted nor
  accidentally depended on.
- **Hierarchy.** Every fixture is one flat module. Cross-module domain crossing
  is M03's insertion problem.

## Running these

They are not wired into any build step yet — `zig build torture` walks only
`tests/fixtures/`, which this row does not touch.

Once the fixtures move (or `suite_options` grows a second directory):

```
zig build torture -- M01            # the whole row
zig build torture -- M01 -j1        # one at a time, streaming
```

Today, to reproduce the recorded diagnostics file by file:

```
cd /home/omare/Documents/Projects/Zig/VerA
for f in tests/pending/M01/*.va; do
  echo "== $f"; zig-out/bin/vera --lint -I tests/fixtures "$f" 2>&1 | head -3
done
```

and to run one that has been made to compile:

```
zig-out/bin/vera --run --contract tools/contract.zig -I tests/fixtures \
  --display=emit tests/pending/M01/<file>.va
```

The `--contract` flag is required for `--run`; `--display=emit` is what makes
the `CHECK` macros' `$strobe` lines reach stdout instead of being dropped with
`W0850`.

## Corrected after review

An adversarial review of the pending tree found six defects attributed to this
row. All six are fixed here; each is also explained where it happened, in the
fixture's own header, so the file is readable without this document.

1. **Fixture 10's `delta` was the wave step (fixed by hand before this pass).**
   `delta = 0.5` against a ramp that steps by exactly 0.5 per declared timepoint
   meant `|0.5 − 0.0|` was never "more than delta" (§5.10.3.4), so a literally
   conforming implementation generated no event after initialization and failed
   by 2.0 at t = 20n — the fixture tested for a `>=` bug. `delta` is now 0.3,
   strictly below the step, and both bands are stated as delta + the clause's own
   scheduling window rather than as bare digits.

2. **Fixture 90 cited §4.7.2 for "digital function declarations".** §4.7.2 is
   *Returning a value from an analog user-defined function*. The sentence the
   fixture needs — "Each function can be an analog user-defined function or a
   digital function (as defined in IEEE Std 1364 Verilog)" — is the third of
   §4.7's opening paragraph, and is now quoted verbatim in the header. `//! lrm
   4.7.2` → `//! lrm 4.7`, here and in the supporting-clause list above.

3. **Fixture 06 carried an unearned `//! lrm 7.3.5`.** §7.3.5 is *Detecting
   continuous events in a discrete context*; its content is Syntax 7-3's
   `analog_event_functions` alternative. Fixture 06's `always` waits on a named
   event, i.e. the inherited `hierarchical_event_identifier`, and exercises none
   of §7.3.5's own rule — the cite would have shown as covered under
   `--coverage` without anything covering it. **Withdrawn, and it does not
   vanish: §7.3.5 is owned in this row by fixture 09**, which is the clause's own
   `sampler2`. It comes back to 06 only if 06 grows an analog event function in
   its sensitivity list, which would duplicate 09 and is why it will not.
   `//! lrm 5.10.3.3` replaces it, and is earned: 06 depends on `timer`'s
   start_time/period and on the sentence that makes its firing a reported point.

4. **Fixture 09's falling-crossing time was arithmetically wrong.** Re-derived:
   on (10n, 15n) the expression `V(clk) − 2.5` runs +1.5 → −0.5, a span of 2.0,
   and zero is reached after 1.5 of it, so 1.5/2.0 = 0.75 and the crossing is
   10n + 5n·0.75 = **13.75n**. The header said 11.25n, which is 5n·0.25 — the
   complement of the right fraction. The reviewer's number is the one the
   arithmetic gives; recorded as agreed rather than copied. The want does not
   move: `dir = 1` discards the falling crossing either way.

5. **Fixture 06's and 09's rationales assumed the check is never evaluated at an
   event instant, and both were false.** 06's said "the observations are the
   midpoints between firings, so … the delivery order inside one timepoint never
   matters". §5.10.3.3 says the opposite: "The analog simulator places a time
   point within `time_tol` of an event", defaulting to "at, or just beyond, the
   time of the event". So 5n/15n/25n are reported analog points, this analog
   block runs there, and at a point placed exactly at 5n §7.3.6.1 (schedule at
   the nearest tick) and §7.3.6.5 (read the greatest tick ≤ the analog time) land
   on the same tick with no order fixed between them. 09 has the same problem
   around the 6.25n crossing, where §5.10.3.1's tolerance box and §7.3.6.1's
   rounding jointly put the delivery anywhere in roughly [6n, 7n].
   **Neither is repaired by writing a digit**, because the LRM supplies none:
   06 keeps the exact count identity and admits one undelivered firing (band
   1.0 — still failing a never-delivering tool at 20n and 30n, a latch-once tool
   at 30n, and an every-timestep tool immediately); 09 keeps the exact integer
   at t ≤ 5n and t ≥ 10n and makes the want the got on the open interval
   (5n, 10n), asserting nothing there on purpose. The `dir` discriminator is
   untouched: a tool that fires on the 13.75n falling crossing reads 2 at both
   t = 15n and t = 20n, outside the window.

6. **Fixture 01 had no teeth.** Its only assertion was `x == 3.0`, the
   fall-through arm of `if (in == 0)` — passed by any implementation reading the
   net as anything nonzero, including uninitialised storage and a net that was
   never wired. Table 7-1's actual content went untested. The fixture now leads
   with that content: a `wire [3:0]` carrying 4'b1010 must read as the integer
   **10**, per the row's "the lowest bit of the bit grouping is mapped to the
   zeroth bit of the integer … if the bus width is less than 31 bits, the higher
   bits of the integer are set to zero". 4'b1010 is not a palindrome, so a
   reversed mapping reads 5, an unwired net reads 0, and a sign-extending one
   leaves [0, 15]. `in` is now `code[1]` — the part-select the same row names —
   so the `onebit_dac` check is kept and the two assertions are no longer the
   same claim. It has to be a net: the `reg` half of the `bit` row is already
   green under `tests/fixtures/ch07_mixed_signal/`.

7. **This document claimed every diagnostic was reproduced by running the
   compiler, and that was false for three files.** See the re-capture block at
   the top: 05 and 08 recorded their second blocker as their first, and 10 had
   E0513 and E0205 the wrong way round. Re-run, re-pasted, line numbers
   included; the other ten were already right.

Not changed, and why: `//! reject LRM 7.3.7` (fixture 90) and `//! reject LRM 7.3`
(fixture 91) are left alone. `tests/torture.zig`'s `failureContains` matches a
non-code pattern against the diagnostic message, its point, the catalogue title
and the notes — so these name the specific rule each rejection is about rather
than accepting any diagnostic, which is what a bare `DiagnosticsReported` would
have done. Today both fixtures correctly fail, on an `E0205` that contains
neither string.
