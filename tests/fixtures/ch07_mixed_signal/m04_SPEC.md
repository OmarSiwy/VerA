# M04 — Driver/receiver access and real nets

Pending fixtures for the two halves of M04: `wreal` (LRM §3.7, §6.5.3) and
driver/receiver segregation plus the connectmodule driver-access family
(§7.9, §9.22, §9.23). Both halves are greenfield. No unmerged branch covers
this row.

## Ground truth (audited against `src/`, not taken from the plan or COVERAGE)

Grepped, then confirmed against the built binary at
`/home/omare/Documents/Projects/Zig/VerA/zig-out/bin/vera`.

### `wreal` — reserved and rejected, nothing more

| probe | result today |
|---|---|
| `wreal w;` | `E0205 unsupported module item: found wreal` |
| `input wreal a;` | `E0208 expected an identifier: found wreal` |
| `real r;` inside a `--run` module | `E1100 only uninitialized scalar/packed reg and integer declarations are implemented` |
| `$display("%g", …)` under `--run` | `E1100 only %b and %% display conversions are implemented` |

`src/frontend/token.zig:760-763` puts `wreal` in the `kw_reserved` list beside
`net_resolution`; `src/frontend/lexer.zig:726` is the unit test that pins it as
reserved. `src/ir/lower.zig:2428` states it outright: *"VerA has no
`real`/`wreal` net declarations at all (E0205)"*. `src/sim/digital.zig` carries
a four-state `Int` and nothing else — there is no real-valued net, no real
variable and no real formatting in the digital execution engine, so the whole
wreal half is new machinery and not a parser gap.

`wreal` does appear in two places that are **not** the data type and must not be
mistaken for it: `src/frontend/preprocessor.zig:142-148` and `:1948` implement
`` `default_discipline ``'s qualifier list (§10.2), where `wreal` is one of the
qualifier *names*; and `src/sim/digital.zig:1066` mentions "wreal-initialized
nets" in a refusal that is really about net initializers in general.

There is one existing fixture, `tests/fixtures/annex_c_analog_subset/08_wreal_rejected.va`,
and it pins the **Verilog-A subset** rule (C.4: "the wreal data type is not
supported in Verilog-A"), not the Verilog-AMS rule. It is not evidence of §3.7
support in either direction. Note that its argument is in tension with the one
`tests/fixtures/ch07_mixed_signal/connectmodule_accepted.va` makes at length —
that annex C describes the subset and VerA targets full Verilog-AMS, so a
subset-only prohibition is not a licence to refuse in AMS mode. Resolving that
is not this row's business; it is flagged here because the day §3.7 lands, that
fixture has to move behind a `--std=verilog-a` gate or be re-scoped, and it will
look like a regression otherwise.

### Driver access — parsed, fenced, never executed

| probe | result today |
|---|---|
| `$driver_count(p)` in an ordinary module | `E0818 driver access function outside a connect module` |
| `connectmodule` with `always @(driver_update d)` and `$driver_count(d)` | **parses and elaborates past the frontend** |
| `assign d = out;` inside a connectmodule | `E0205 unsupported module item: found` `assign` |
| a design with more than one ordinary module under `--run` | `E1100 digital execution requires exactly one ordinary module` |

So the state is:

- `driver_update` is a real token (`src/frontend/token.zig:253`), a real AST node
  (`src/frontend/ast.zig:209-214`), and is parsed **only** inside a connect
  module (`src/frontend/parser.zig:2556-2565`). It is cloned by elaboration
  (`src/ir/elaborate.zig:2024-2028`) and refused by lowering with `E0701`
  (`src/ir/lower.zig:7012-7015`) — which is unreachable in practice, because
  `elaborate.pickTop` never picks a connect module and nothing lowers its body.
- `$driver_count`, `$receiver_count`, `$driver_state`, `$driver_strength`,
  `$driver_delay`, `$driver_next_state`, `$driver_next_strength`,
  `$driver_type` are a name list in `isConnectModuleOnlySysFunc`
  (`src/ir/lower.zig:6889-6893`) whose only effect is `E0818` at every call site
  lowering reaches. `src/backend/codegen.zig:5628-5640` records that codegen
  used to answer them with the constant 0 and deliberately no longer does.
- `connectrules` / `connect` statements parse
  (`tests/fixtures/ch07_mixed_signal/connectrules_accepted.va`) but insert
  nothing.

**The functions are therefore implemented as a refusal, not as a feature.** The
comment at `src/ir/lower.zig:6874-6880` says as much: "a driver call written
inside a connect module is therefore accepted and never reached, which is the
right answer to the wrong half of the clause." Existing fixtures 31, 107, 109
and 111 in `ch09_system_tasks` all pin the refusing side; `38_driver_update_connectmodule.va`
pins acceptance only and says in its own header that "the positive semantics of
§9.22.6 … need a driven connectmodule and still have no fixture." These files
are that design.

### Already implemented, pinned here anyway

`$realtobits` / `$bitstoreal` are real code in `src/backend/codegen.zig` (`@bitCast`
on the f64, i.e. the exact IEEE-754 pattern, not an approximation) for the
**analog** context, which is what §9.11 extends. Nothing pins the §3.7 use — the
sanctioned wreal-to-64-bit-wire bridge in the *digital* context — and
`$realtobits` is not reachable from `--run` at all (`E1100 this digital
expression form is not implemented`). Fixture 06 pins it there.

## Clauses covered

Quoted from the offline VAMS 2.4 HTML in `docs/`; every `//! lrm` tag below
names a section that exists in those files.

- **§3.7 Real net declarations** — the zero-not-z rule, "shall not store its
  value", the single-driver rule, the closed compatible-interconnect list
  (wire/tri/wreal), the wreal-wins port merge, the `$realtobits`/`$bitstoreal`
  escape to a 64-bit wire, and Syntax 3-8's two `wreal` productions.
- **§6.5.2** — `input`/`output`/`inout _declaration ::= … [ net_type | wreal ] …`,
  i.e. the net type on the port direction line.
- **§6.5.3 Real valued ports** — "There can be a maximum of one driver of a
  real-valued net."
- **§7.9 Driver-receiver segregation** — drivers and receivers of ordinary
  modules segregated within digital segments of a mixed net; connect module
  drivers and receivers oppositely segregated.
- **§7.8.4** — the rules that decide a signal is mixed and place one connect
  module instance per `merged` group. Used as the topology the driver counts are
  derived from; not itself the subject of any assertion (that is M03).
- **§9.11 Conversion System Functions**.
- **§9.22 / §9.22.1 / §9.22.2 / §9.22.4 / §9.22.5 / §9.22.6** — the call-site
  fence, `$driver_count`, `$driver_state`, `driver_update`, receiver net
  resolution and the worked connect module.
- **§9.23 / §9.23.1 / §9.23.2** — `$driver_delay`, `$driver_next_state`.
- **§1.1** — the hook that makes net event semantics IEEE Std 1364 Verilog's
  (fixture 03 only).
- **§9.4.3 Format Specifications (Table 9-22)** and **§3.2** — not asserted as
  subjects, but load-bearing for every transcript in the driver group and for
  fixture 03: Table 9-22 gives `%b` no width modifier, IEEE Std 1364 (via §1.1)
  makes its field width the size of the expression, and §3.2 makes an `integer`
  32 bits wide (`-2**31 .. 2**31-1`). See "How the integer columns are spelled"
  below.

## Fixtures

Each fixture has a matching `.expected.txt` holding the exact `$display`
transcript. The two reject fixtures have none: the expected outcome is a
diagnostic and empty stdout.

### How the integer columns are spelled

`src/sim/digital.zig` implements exactly one integer conversion, `%b`. §9.4.3
Table 9-22 gives `%b` no width modifier, and IEEE Std 1364 — reached through
§1.1 — makes the printed field width of `%b` **the size of the expression**, not
the number of significant digits. §3.2 makes an `integer` 32 bits wide. So every
`integer` column in fixtures 03, 10, 11, 12 and 14 is **exactly 32 binary
digits**, zero-padded on the left:

| decimal | printed |
|---|---|
| 0 | `00000000000000000000000000000000` |
| 1 | `00000000000000000000000000000001` |
| 2 | `00000000000000000000000000000010` |
| 3 | `00000000000000000000000000000011` |
| 4 | `00000000000000000000000000000100` |

The `ok=` columns are `==` results, which IEEE Std 1364 self-determines at one
bit, so they stay a single `1`. The tables below therefore give the **decimal**
value; the `.expected.txt` files hold the 32-digit spelling, and the two must be
read together.

### wreal (§3.7, §6.5.2, §6.5.3) — files `01`–`06`, `20`, `21`

| # | file | pins | expected, and where it comes from |
|---|---|---|---|
| 01 | `01_wreal_undriven_zero.v` | §3.7's two zero rules, against the `wire` contrast in the same module | `0 / z / 2.5 / 0 / 2.5`. Undriven wreal is 0.0 at t=0 and at t=10; the `wire` beside it is `z`, which is the "Unlike other digital nets" sentence; `wreal seeded = 2.5;` has a driver (Syntax 3-8's `list_of_net_decl_assignments`) so 0.0 is wrong for it. Line 2 is what separates "zero because §3.7 says so" from "everything starts at zero". |
| 02 | `02_wreal_single_driver_tracks.v` | "shall not store its value" — the net is a window on its driver | `1.5 3 / -0.25 -0.5 / -0.25 -1 / 0.333333 1.33333`. Line 3 moves `gain` but not `src`, so `w` must not move while `z` does. `1.0/3.0` is included because it is not representable: %g at six significant digits reads `0.333333` for a true double and something else for a float or a fixed point. |
| 03 | `03_wreal_event_on_change.v` | a wreal event is a change in the REAL VALUE; `count` is %b | counts, in decimal, `0,1,1,2,3,3` — each printed as 32 binary digits per the table above. Rewriting 1.5 over 1.5 fires nothing; 1.5→1.25 fires (a tool truncating to integer would not); **0.0→-0.0 fires nothing**, because `-0.0 == 0.0` in IEEE-754 — the line that separates comparing the value from comparing the 64 bits. `latched` proves the event delivers the new value. |
| 04 | `04_wreal_port_round_trip.v` | both §6.5.2 spellings of a real-valued port in one child; bit-exact crossing; undriven output port | `0.2` and the two 64-bit patterns `0x3FB999999999999A` (0.1 in) and `0x3FC999999999999A` (0.2 out), which differ only in the exponent field — the mantissa survived. `dangling` is a wreal output port nothing drives, so §3.7 gives `0`. |
| 05 | `05_wreal_wire_port_resolves_wreal.v` | "the resulting single net will be assigned as wreal" — the merge is asymmetric and wreal wins | `2.5 / 2.5 / 5 / 0`. A parent `wire` and a parent `tri` both carry a real after the merge; the promotion reaches a *third* connection (`echo` = 2.5×2 = 5); and a merged net with no driver anywhere reads `0`, not `z`. That last line is the one a "merge accepted, type unchanged" implementation fails. |
| 06 | `06_realtobits_bitstoreal_bridge.v` | §3.7's only sanctioned wreal↔bus path, asserted on all 64 bits | `0.1` → `0x3FB999999999999A`, sign `0`, biased exponent `01111111011` (= −4 + 1023 = 1019); `-0.25` → `0xBFD0000000000000`, sign `1`, exponent `01111111101` (= −2 + 1023 = 1021). The round trip re-encodes to the identical pattern. The bit-select lines are properties of the *encoding*, which a shim returning the right real cannot fake. |
| 20 | `20_reject_wreal_two_drivers.v` | **reject** (`//! reject one driver`). §6.5.3 "There can be a maximum of one driver of a real-valued net." | a diagnostic whose message, point or catalogue title contains `one driver`, and empty stdout. There is no resolution function to fall back on: 1.5 and 2.5 have no resolved value, no `x` and no strength order. Guards a compiler that reuses its `wire` driver-grouping path and silently takes the last driver. |
| 21 | `21_reject_wreal_connected_to_wand.v` | **reject** (`//! reject net type`). §3.7's compatible list is closed — wire, tri, wreal — and "Connection to other net types will result in an error." | a diagnostic whose message, point or catalogue title contains `net type`, and empty stdout. Positive twin is 05, which pins wire and tri being accepted, so the two state the list's membership from both sides. Guards a merge written as "if either side is wreal, the net is wreal", which would delete the wand's resolution function. |

### Driver / receiver (§7.9, §9.22, §9.23) — files `10`–`15`

Every assertion in this group is **topological or logical**, never numerical: the
expected values follow from the elaborated netlist and from four-state logic, and
no line depends on the 1 kΩ load, the timestep or a threshold. That is
deliberate — a driver-access fixture whose answer moves with a tolerance cannot
be a conformance test.

| # | file | pins | expected, and where it comes from |
|---|---|---|---|
| 10 | `10_driver_count_excludes_connectmodule.va` | §9.22 ¶3: the functions report drivers "found in ordinary modules and not … in connect modules", while being callable only from one | `got` = 2 (decimal), `ok=1`, twice. The net genuinely has three drivers — two ordinary output ports plus the connect module's own `assign d = out;` — and the clause says the answer is 2. The `ear` input port is a receiver and is not counted. The second sample at t=40, after both drivers have moved twice, pins that the count is an elaboration property, not an activity tally. |
| 11 | `11_driver_state_histogram.va` | §9.22.2's four return values, asserted as an order-independent histogram because §9.22.1 numbers drivers "arbitrarily" | `got` = 4, `ok=1`, and `ones, zeros, xs, zs` = `1, 1, 1, 1`; after the x and z drivers resolve at t=30, `got` = 4, `ok=1` again and `ones, zeros, xs, zs` = `2, 2, 0, 0`. All decimal; see the spelling table above. Four distinct states is the only arrangement where the histogram determines each driver uniquely. The z driver is the trap: it contributes nothing to a resolved wire value, so a list built from "drivers that affect the result" reports N = 3. |
| 12 | `12_driver_update_without_resolved_change.va` | **the headline clause.** §9.22.4: "an update is defined as the addition of a new pending value to the driver. This is true whether or not there is a change in the resolved value of the signal." | `updates` = 1, 2, 3, 4 at t = 15, 25, 35, 55, against `ones` = 1, 2, 2, 1 (all decimal; see the spelling table above). The t=25/t=35 pair is the assertion: the counter moves 2 → 3 while the driver-state histogram does not move at all, because driver `a` was re-assigned the 1 it already held and driver `b` still holds 1. A `driver_update` implemented as `@(the resolved net)` reads 2 on both lines. `ok=1` on all four lines is the check that actually fails on a wrong count. |
| 13 | `13_receiver_value_set_by_connectmodule.va` | §7.9 segregation + §9.22.5's explicit case: with `assign d = out;` the receivers see a value "determined in the connect module … potentially different from the value of the drivers" | `1 / 0 / 1` at t = 5, 20, 40, against a driver holding `x`, `1`, `0`. The connect module drives the receivers with the logical inverse of `$driver_state(d,0)`. Line 1 is the sharpest: `1` is not reachable from the driver's `x` by any resolution function, so no propagation path can produce it. |
| 14 | `14_receiver_default_bypass.va` | §9.22.5's default: with no `assign` on the digital port, "the default is equivalent of assign d_receivers = d_drivers … without delay or any impact from analog connections to the net" | `got` = 1, `ok=1` at t=1, then `x / 1 / 0` at t = 5, 20, 40. The three receiver lines are fixture 13 with `reg out; assign d = out;` and its process deleted, so the two transcripts are exact complements on lines 2 and 3 — that relationship is one claim. The t=1 line is the other, and it is why this file now has independent force: `x / 1 / 0` on its own is also the transcript of a simulator with **no** insertion, no segregation and no §9.22.5 handling, because §9.22.5's default *is* the bypass. `$driver_count(d) == 1`, called from inside the connect module (§9.22 ¶3 permits it nowhere else), cannot be produced without insertion: 1 ordinary driver, 1 receiver that is not a driver, and no driver of the connect module's own because the `assign` is absent. |
| 15 | `15_driver_delay_and_next_state.va` | §9.23.1 and §9.23.2 | `delay = -1, 15, 5, -1` and `next = 0, 1, 1, 1` at t = 25, 35, 45, 55, with `state = 0, 0, 0, 1`. `o <= #20 1'b1` at t=30 matures at t=50, so the delay is *from current simulation time* — 15 at t=35 and 5 at t=45, where a tool returning the scheduled delay prints 20 on both. `-1.0` is the no-pending sentinel and is a real, not 0. `next_state` falls back to the current state on lines 1 and 4 and reports the pending value on 2 and 3, which is why it cannot be an alias of `$driver_state`. |

**12 positive fixtures, 2 rejects.**

## Deliberately NOT covered

- **`$driver_strength` and `$driver_next_strength` (§9.22.3, §9.23.3).** Their
  return is the packed strength0/strength1 encoding of Figure 9-3, which is
  IEEE Std 1364 clause 7's strength model — D03's row, and not implemented at
  all (`src/sim/digital.zig:103-114`: "every driver here is at the SAME
  strength"). A fixture here would be asserting D03's model through a second
  front door. When D03 lands, the missing case is a `(weak1, weak0)` and a
  `(strong1, strong0)` ordinary driver on one mixed net, read back through
  `$driver_strength` as `6'o06` and `6'o60`.
- **`$driver_type` (Table 9-19) and `$receiver_count`.** `$driver_type` has no
  subclause in the offline document — only the name in
  `isConnectModuleOnlySysFunc` — and `$receiver_count` is explicitly marked
  *"Non-normative: $receiver_count is not a subclause of 9.22 in Verilog-AMS
  2.4"*. There is no clause text to derive an expected value from, so no
  fixture invents one. `tests/fixtures/annex_g_change_history/08_new_receiver_count.va`
  already covers what can be said about the latter.
- **Analog registration of a pending digital event.** §9.23's stated purpose is
  "analog waveforms which cross a specified threshold at the same time the
  digital event matures". Fixture 15 pins the *queries*; using their answers to
  place a `transition()` and asserting the crossing time is an M01/M02
  synchronization test whose answer depends on the timestep.
  **Inherited from M02 by the same review.** M02 withdrew one claim and named
  this row as its owner: whether an analog block's explicit `@(b_dig)` wake-up
  fires during the interior 1 → 0 → 1 transit of a single tick
  (`M02/07_glitch_absorbed_at_one_tick.va`, and `M02/SPEC.md`'s *Deliberately
  NOT covered*). The answer is Figure 8-6's transition filter —
  `$driver_update` / `$driver_next_state` / `$driver_delay` feeding a
  `transition()` — which is exactly the machinery fixture 15 queries and which
  no fixture here yet wires to an analog waveform. It is **not** covered today
  for the reason in the paragraph above: the asserted quantity is a crossing
  *time*, so it moves with the timestep. What would let it be pinned here is a
  connectmodule (M03 insertion) that reads `$driver_delay`/`$driver_next_state`
  and drives `transition(next, delay, 0, 0)` with **zero** rise/fall time, which
  makes the crossing instant exactly `$abstime + $driver_delay` and therefore
  timestep-independent. M02's 07 keeps `ana_b` live through `V(vo)` with a
  nonzero coefficient so the stimulus does not have to be rebuilt.
- **`split` mode, generated connect-module instance names and `defparam` onto
  them (§7.8.3.2, §7.8.5).** M03's row. Every design here uses one `merged`
  connect statement, and no fixture names a generated instance.
- **Vector `wreal` (`wreal [range] …`, Syntax 3-8).** The range production is
  real but adds no semantic rule this row does not already state per element;
  it is the same scalarization every other vector net gets.
- **wreal in the analog context / a wreal-to-electrical connect module.** §3.7
  places wreal in the discrete domain; bridging one to an `electrical` net is a
  connect-module question (M03) on top of a real-valued A2D, and the LRM gives
  no numeric rule for it that could be hand-derived here.
- **`wreal` special *state* values (`` `wrealZState ``, X/Z propagation through a
  real net).** The offline VAMS 2.4 HTML set contains no such identifier —
  grepped across all twelve chapter files and all eight annexes. The only
  "standard special-value handling" §3.7 defines is the 0.0 for an undriven net
  (fixtures 01, 04, 05) and the `$realtobits`/`$bitstoreal` bridge (06). No
  fixture invents a state model the document does not contain.
- **Time-zero and delta-cycle ordering.** Every sample in every fixture is at
  least 5 ticks clear of the assignment that determines it. Ordering within a
  timestep is M02's row.

## Build / run

Nothing under `tests/pending/` is wired into `zig build`. Once the features
exist, each pair runs the way `tests/digital/*.v` does:

    zig build
    ./zig-out/bin/vera --run tests/pending/M04/01_wreal_undriven_zero.v

compared against the matching `.expected.txt`. The reject fixtures must exit
non-zero with empty stdout:

    ./zig-out/bin/vera --run tests/pending/M04/20_reject_wreal_two_drivers.v

To adopt them, move the pairs into `tests/digital/` and add an
`expectStdOutEqual(@embedFile(...))` run step to the `digital_step` block in
`build.zig` (`build.zig:141-164` is the pattern), or add them as
`expectRun`/`expectRejected` cases in `src/sim/digital.zig`'s test block.

The `//! lrm` tags are written in the `tests/fixtures/**/*.va` vocabulary
(`tests/harness.zig`, `src/backend/tb.zig`) so that any fixture which later
turns out to be expressible as a single analog device can be moved under
`tests/fixtures/` unchanged. None of them is today: `--run` is the runner for
all fourteen.

### Prerequisites, and what each fixture fails on right now

Verified against `zig-out/bin/vera` on 2026-09-19. All fourteen fail.

| files | current diagnostic |
|---|---|
| 01, 02, 03, 05, 06, 20, 21 | `E0205 unsupported module item: found wreal` |
| 04 | `E0208 expected an identifier: found wreal` (the port-direction spelling) |
| 10, 11, 12, 13, 15 | `E0205 unsupported module item: found` `assign` (inside the connectmodule) |
| 14 | `E0209 expected an expression: found` `#` |

Beyond `wreal` itself and `assign` as a module item, the wreal group also needs
**`real` variables and the `%g` conversion in `src/sim/digital.zig`** (today:
"only uninitialized scalar/packed reg and integer declarations are implemented"
and "only %b and %% display conversions are implemented"), and fixtures 04, 05,
10–15 need **module instantiation under `--run`** (today: "digital execution
requires exactly one ordinary module"). The driver group needs, on top of that,
M03's connect module insertion and an M01/M02 mixed kernel; its assertions were
written to be independent of the analog numerics precisely so that they become
checkable as soon as insertion works, without waiting for the solver to be
accurate.

**Caveat on the two rejects.** `20` and `21` are refused today, but for the wrong
reason — `E0205` on the `wreal` keyword itself, not the rule each cites. They
are worthless as tests until `wreal` parses, at which point they become the
real assertions their headers describe. Same property as
`tests/pending/D03/12`–`13`. Since the review they at least *say* so: each
`//! reject` now carries a substring, and neither substring matches today's
E0205 (checked — its message is "unsupported module item: found wreal", its
point is `wreal`, its note is "LRM annex A.1.4"), so neither file can go green
on the wrong-reason diagnostic.

## Corrected after review

An adversarial review of this row (`tests/pending/MANIFEST.md` §5.3, §5.4)
found two defects. Both are fixed here; nothing outside `tests/pending/M04/`
was touched. The review recorded **no** Class A, Class B (citations "verified
clean"), Class E or reproduction defect against this row, and re-checking
below did not turn up a new one.

1. **16 of the row's 32 asserted transcript lines carried the wrong string
   (§5.3).** Fixtures 03, 10, 11 and 12 printed `integer` values with `%b` at
   *minimum* width — `"1"`, `"10"`, `"100"`. That is not conformant and not
   what VerA does. §9.4.3 Table 9-22 gives `%b` no width modifier (re-opened:
   the table lists `%h %d %o %b %c %l %m %s` and nothing else; the width
   language for reals is the *next* table, 9-23), IEEE Std 1364 — reached
   through §1.1's "Verilog-AMS HDL consists of the complete IEEE Std 1364
   Verilog specification" — makes the field width of `%b` the size of the
   expression, and §3.2 gives an `integer` the range −2³¹..2³¹−1, i.e. 32 bits.
   VerA's own green regression at `src/sim/digital.zig:1163-1177` prints
   `integer 11111111111111111111111111111111`. So the old transcripts failed a
   conforming implementation, and the cheap repair — making `%b` minimum-width
   — would have broken that regression. All 16 lines now hold the 32-digit
   zero-padded spelling; fixture 12, the row's headline fixture, was the worst
   case. Each of the four headers records the change and the derivation, and a
   new *How the integer columns are spelled* section above gives the decimal ↔
   32-digit table once. The `ok=` columns stay one digit: they are `==`
   results, self-determined at one bit.
2. **Fixture 14's whole transcript was the feature-absent transcript (§5.4).**
   `x / 1 / 0` is what a simulator with no insertion, no driver-receiver
   segregation and no §9.22.5 handling prints, because §9.22.5's default *is*
   the bypass — the conforming answer and the do-nothing answer necessarily
   coincide, so no rewording of those three lines can give them teeth. Rather
   than delete the file (its complement relationship to 13 is a real claim, and
   it is the only fixture for the default half of §9.22.5), it gained a line
   that cannot be produced without insertion: `$driver_count(d)` read from
   **inside** the connect module, which §9.22 ¶3 permits nowhere else, over a
   design with exactly one ordinary driver, one ordinary receiver and — because
   the `assign d = out;` is absent — no driver of the connect module's own.
   `got=1, ok=1`. A tool that inserted nothing never runs that `initial` block
   and prints no such line; a tool that counted its own port or the receiver
   prints `ok=0`. The header now states plainly that the three bypass lines
   hang off that one, and discloses the residual window the sample times leave
   open (delays under ~5 ns are not excluded, because excluding them would be
   asserting intra-timestep delivery order, which is M02's row).

Re-verified while here, since the review's "citations verified clean" is a
claim about a moving file: every `//! lrm` tag in the row was opened in
`docs/` — §1.1, §3.2, §3.7 (including Syntax 3-8 and the closed
wire/tri/wreal list), §6.5.2's three `[ net_type | wreal ]` productions,
§6.5.3's "There can be a maximum of one driver of a real-valued net", §7.8.4,
§7.9, §9.4.3, §9.11, §9.22 and §9.22.1/.2/.4/.5/.6, §9.23/.1/.2, and
Annex A.2.1.3's two `wreal` net declarations. All survive. The IEEE-754
patterns in 04 and 06 were re-derived (`0.1` = `0x3FB999999999999A`,
`0.1 + 0.1` = exactly `0.2` = `0x3FC999999999999A`, `−0.25` =
`0xBFD0000000000000`; biased exponents 1019 = `01111111011` and
1021 = `01111111101`). The *Prerequisites* table above was re-captured by
running `zig-out/bin/vera --run` on all fourteen files after the edits: the
diagnostics are unchanged, including fixture 14, whose new `#1;` inside the
connect module still lands on `E0209 expected an expression: found #`.
