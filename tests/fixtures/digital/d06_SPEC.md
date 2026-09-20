# D06 — Continuous assignment and delay semantics

Greenfield row. Fixtures are digital source-execution tests (`vera --run`), the
same shape as `tests/digital/*.v` + `*.expected.txt`.

## Ground truth as of this writing (read from source, not from COVERAGE.md)

Verified by reading `lib/frontend/parser.zig`, `lib/frontend/ast.zig`,
`src/sim/digital.zig` and by running the compiler.

**Implemented.**

- `assign <net> = <expr>;` — parsed at `lib/frontend/parser.zig:965`
  (`.kw_assign` arm), lowered to `Ast.ContAssign` (`lib/frontend/ast.zig:654`),
  executed as one driver per `net_assignment` in `src/sim/digital.zig:1078`.
- Reevaluation on operand change, with the update queued as an active event
  (`src/sim/digital.zig:792`, `:908`). In-tree unit tests at
  `src/sim/digital.zig:1260` and `:1371`.
- Multi-driver resolution and `supply` strength (`src/sim/digital.zig:778`).
- Procedural delay control `#N stmt`, including `#0` → inactive region
  (`src/sim/digital.zig:662`, `:977`).

**Not implemented — every D06 delay surface.**

The `.kw_assign` arm goes straight from the keyword to `parseExpr`: it parses
neither `drive_strength` nor `delay3`, both of which annex A.6.1 puts there.
The parser's own comment at `lib/frontend/parser.zig:961` quotes the full
`continuous_assign` production it does not implement.

| surface | today |
| --- | --- |
| `assign #5 y = a;` | `E0209 expected an expression: found #` |
| `assign #(3,7) y = a;` | `E0209` |
| `assign #(2,4,6) y = a;` | `E0209` |
| `assign (pull1,pull0) y = a;` | `E0209 expected an expression: found pull1` |
| `wire #4 y;` | `E0208 expected an identifier: found #` |
| `wire #3 y = ~a;` | `E0208` |
| `r = #5 b;` / `s <= #7 b;` | `E0209` |
| inertial pulse cancellation | unreachable — no delayed driver exists |

## LRM clauses covered

Read from the offline HTML in `docs/`.

- **§8.5.3.1 Continuous assignment** (`ch8-scheduling.html`) — the assignment is
  a process sensitive to the source elements of its expression; a change queues
  an *active update event*. Cites 6.1 of IEEE Std 1364.
- **§8.5.3.3 Blocking assignment** — a delayed blocking assignment computes the
  RHS from current values, then suspends the process; a zero delay schedules an
  *inactive* event for the current time. Cites 9.2.1 of IEEE Std 1364.
- **§8.5.3.4 Non blocking assignment** — computes the value and schedules an NBA
  update event; the values in effect *when the update is queued* determine both
  the RHS and the target. Cites 9.2.2 of IEEE Std 1364.
- **§9.22.3 `$driver_strength`**, Figure 9-3 *Strength value mapping* —
  Su(7) St(6) Pu(5) La(4) We(3) Me(2) Sm(1) HiZ(0), referring to 7.10/7.11 of
  IEEE Std 1364-2005. This is the offline source for "pull outranks weak".
- **§6.2.2 Module instantiation** — used only by `hier_delay.v`.
- **annex A.6.1** — `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
  list_of_net_assignments ;` and `net_assignment ::= net_lvalue = expression`.
- **annex A.6.2** — `blocking_assignment ::= variable_lvalue =
  [ delay_or_event_control ] expression`, ditto `nonblocking_assignment`.
- **annex A.6.5** — `delay_control ::= # delay_value | # ( mintypmax_expression )`.
- **annex A.2.1.3** — `net_declaration`, all four alternatives carry `[ delay3 ]`.
- **annex A.2.2.2 Strengths** — `drive_strength` and the `strength0`/`strength1`
  vocabularies.
- **annex A.2.2.3 Delays** — `delay3` with at most three `mintypmax_expression`s.
- **annex A.2.4** — `net_decl_assignment ::= ams_net_identifier = expression`.

## Observation technique

`$display` in this compiler implements only `%b` and `%%`
(`src/sim/digital.zig:713`); `$time` is not an implemented digital expression.
So timestamps are pinned by a *literal label* on each line plus the structure of
the sampling walk, not by printing the clock.

Every sampled read is taken in the **inactive region** of its time, via the
`#N #0 $display(...)` idiom. §8.5.3.3 puts a zero delay in the inactive region
of the current time, and the inactive region is drained only after the active
region is empty — so an inactive-region read sees every active update of that
same timestamp. A read at `t-1` showing the old value and a read at `t` showing
the new one therefore brackets the delivery to **exactly** `t`, which is what
makes the asserted numbers pin a delay value rather than merely "some lag".
Stimulus is applied in the active region (plain `#N`, no `#0`) from the same
sequential process as the samples, so no two events of the fixture ever race.

The idiom was verified to work today against `tests/digital/scheduling.v`
semantics and by direct execution.

## Fixtures

Ten positive, two reject.

| file | pins | expected |
| --- | --- | --- |
| `cont_assign_reeval.v` | §8.5.3.1: sensitivity is to *every* source element of `sel ? a : b`, and the update is *queued*, not applied in place. **This is the one fixture that passes today** — it exists so the shipped behaviour has evidence. | `t1 y=1` / `t1-stale y=1` (read in the same active region after `sel=1`, still old) / `t1-settled y=0` (inactive region of t=1) / `t2 y=0` (b changes, but `sel` selects `a`) / `t3 y=1` (sensitive to `a`) |
| `assign_delay_single.v` | annex A.6.1 `delay3` single-value form on a continuous assignment; one delay for every direction. | `a:=1` at t=10 → update queued for 10+5=15; `t14 y=0`, `t15 y=1`. `a:=0` at t=20 → 20+5=25; `t24 y=1`, `t25 y=0`. Baseline `t9 y=0`. |
| `assign_delay_rise_fall.v` | annex A.2.2.3 two-value `delay3`: first = transition to 1, second = transition to 0, transition to x takes the smaller. Delay chosen by the *destination* value. | `#(3,7)`: rise at t=20 → 23 (`t22 y=0`, `t23 y=1`); fall at t=40 → 47 (`t46 y=1`, `t47 y=0`); to x at t=50 → min(3,7)=3 → 53 (`t52 y=0`, `t53 y=x`). |
| `assign_delay_turnoff.v` | annex A.2.2.3 three-value `delay3`: third value times the transition to z. Source `en ? d : 1'bz` is what makes z reachable. | `#(2,4,6)`: rise t=20→22; turn-off t=30→36 (`t35 y=1`, `t36 y=z`); fall from z t=40→44 (`t43 y=z`, `t44 y=0`). If turn-off fell back to the fall delay, t=35 would already read z. |
| `assign_delay_inertial.v` | One `net_assignment` is one driver (annex A.6.1) holding one value, so a newly queued update supersedes an outstanding one — inertial delay. | `#5`, pulse 10→12 (width 2 < 5): the y=1@15 event is cancelled by y=0@17, so `t14/t15/t17` are all `0` — no glitch. Pulse 20→30 (width 10 > 5) passes: `t24 y=0`, `t25 y=1`, `t34 y=1`, `t35 y=0`. |
| `net_delay.v` | annex A.2.1.3 `delay3` on the *net declaration* — a distinct object from the assignment delay; both `assign`s here are undelayed. | `wire #4 y` and `wire #(2,6) z` off one source. Rise at t=20: z@22, y@24 (`t21 00`, `t22 01`, `t23 01`, `t24 11`). Fall at t=30: y@34, z@36 (`t34 01`, `t35 01`, `t36 00`). The edge ordering *inverts* between the two transitions — unreachable with a single averaged net delay. |
| `net_decl_assign_delay.v` | annex A.2.1.3 + A.2.4: a net declaration assignment is a continuous assignment on the declaration and may carry `delay3`. | `wire #3 y = ~a;` — `a:=1` at t=10 → `~a`=0 delivered at 13 (`t12 y=1`, `t13 y=0`); `a:=0` at t=20 → 23 (`t22 y=0`, `t23 y=1`). Baseline `t6 y=1`. |
| `intra_assign_delay.v` | annex A.6.2 + §8.5.3.3/§8.5.3.4: the RHS of both forms is sampled when the statement *executes*; only the blocking form suspends. | At t=0: `s <= #7 b` samples b=1, then `b=0`, then `r = #5 b` samples b=0 and suspends. `t4 r=1 s=0` (peer process — blocking assignment has not landed early), `t5 r=0`, `t7-inactive s=0` (inactive precedes the NBA region of the same time), `t8 s=1` — the delivered 1 is the b sampled at t=0, not the 0 held since. |
| `assign_drive_strength.v` | annex A.6.1 `drive_strength` + §9.22.3 Figure 9-3 ordering Pu(5) > We(3); equal opposing strengths resolve to x; a z-valued driver contributes HiZ regardless of its declared strength. | `t1 y=1` (Pu1 beats We0), `t11 y=0` (`a:=1'bz` at t=10, so the Pu driver contributes HiZ), `t21 y=0` (`a:=1'b0, b:=1'b1` at t=20 — **both** polarities swapped and Pu0 still beats We1). `w=x` on all three lines. The discriminating lines are `t1` and `t21`; see *Corrected after review*. |
| `hier_delay.v` | §8.5.3.1 is per-instance: delays *accumulate* along a path, because the second stage cannot queue until the first has changed its source. | Two `assign #5` stages. `a:=1` at t=20 → mid@25 → y@30. `t24 0 0`, `t25 1 0`, `t29 1 0`, `t30 1 1`. A flattened sensitivity list would deliver y at 25. |
| `reject_delay4.v` | annex A.2.2.3: `delay3`'s bracket nesting caps the parenthesised form at three expressions. `assign #(1,2,3,4)` has no derivation. | `//! reject E0210` — *expected `')'`*. After the third `mintypmax_expression` the production admits only `)`, so a missing `)` is the diagnostic the grammar itself dictates. |
| `reject_intra_assign_on_net.v` | annex A.6.1: `net_assignment ::= net_lvalue = expression`, with no `delay_or_event_control` — unlike annex A.6.2's `blocking_assignment`. `assign y = #5 a;` must not be re-read as `assign #5 y = a;`. | `//! reject E0209` — *expected an expression*, at the `#`. `#` cannot begin an `expression`, now or after `delay3` lands. |

Reject state today — captured, see *Observed today* below, not typed:

- `reject_intra_assign_on_net.v` already emits **exactly** its demanded E0209.
  That is not an accident of the missing feature: `delay3` sits *before* the
  lvalue list, so `#` on the right of `=` is unparseable now and stays
  unparseable after the feature lands. The directive's job is to forbid the
  future "fix" of silently re-reading the line as `assign #5 y = a;`.
- `reject_delay4.v` emits E0209 today and its directive demands E0210, so it is
  correctly **unmet** until the parser has a `delay3` production to run out of
  slots in. A bare `//! reject` would have scored today's wrong-reason error as
  a pass, and would keep scoring any future wrong-reason error as a pass.

Neither directive is *enforced* yet: `build.zig:428` points the torture runner's
`fixture_root` at `tests/fixtures`, and the runner walks `.va`, so no `.v` file
in this tree is read by `lib/backend/tb.zig`'s directive parser at all. Today
they are documented intent, checked by hand. They become live the moment these
files are moved onto a diagnostics step (see *How to run*).

## Deliberately not covered

- **Net value before the first delayed delivery.** No fixture samples a net
  while its only driver's first update is still outstanding. Whether that reads
  `z` (annex A.2.1.3 net default) or `x` (first driver evaluation) is not
  settled by any clause in the offline text, so asserting it would be inventing
  a rule. Every fixture's first sample is taken after settling.
- **`min:typ:max` delays.** `delay3` takes `mintypmax_expression`s; only the
  single-value spelling is exercised. Selecting among the three needs a CLI
  knob that does not exist.
- **`trireg` charge decay** (the `delay3` third slot means decay time, not
  turn-off, on a `trireg`) — belongs with charge storage, not with this row.
- **Delay composition on one net**: an `assign #d` driving a `wire #e` net.
  Each is pinned alone first; composing them is a follow-up once both parse.
- **Vector nets and part-select targets** under delay. All fixtures are scalar.
- **Gate/primitive delays** (annex A.3.x `delay3` on a gate instance) — D08.
- **`$time` / `%t` readout.** The whole timestamp technique here is a
  workaround for its absence; it is D09's to add.

## Blocked

- `hier_delay.v` is blocked on **D07**: digital execution currently accepts
  "exactly one ordinary module" (`src/sim/digital.zig`), so the file fails
  elaboration before the delay path is reached. It is written now because the
  semantics it pins (delays accumulate per instance) are D06's, not D07's.
- Everything else is blocked only on the parser learning `drive_strength` and
  `delay3`, and on the digital scheduler learning delayed, inertial drivers.

## How to run

Today, one file at a time:

```
cd /home/omare/Documents/Projects/Zig/VerA
zig build
./zig-out/bin/vera --run tests/pending/D06/<name>.v | diff - tests/pending/D06/<name>.expected.txt
```

Only `cont_assign_reeval.v` passes; the rest report `E0208`/`E0209` at the
`delay3` or `drive_strength` they need.

To wire them up once the feature lands, move the pair into `tests/digital/` and
add the same four lines `build.zig:141-146` already uses per file:

```zig
const d06 = b.addRunArtifact(exe);
d06.addArg("--run");
d06.addFileArg(b.path("tests/digital/<name>.v"));
d06.expectStdOutEqual(@embedFile("tests/digital/<name>.expected.txt"));
digital_step.dependOn(&d06.step);
```

then `zig build test-digital`. The two `reject_*.v` files have no
`.expected.txt`: they belong on the diagnostics path — nonzero exit plus the
code named in each file's `//! reject` line (E0210 and E0209 respectively) —
not on `expectStdOutEqual`.

## Observed today

Captured, not typed. `zig build install` then the loop below, on the tree as it
stands after this correction.

```
$ for f in tests/pending/D06/*.v; do ./zig-out/bin/vera --run "$f"; done
assign_delay_inertial.v:45:10    error[E0209]: expected an expression: found `#`
assign_delay_rise_fall.v:38:10   error[E0209]: expected an expression: found `#`
assign_delay_single.v:45:10      error[E0209]: expected an expression: found `#`
assign_delay_turnoff.v:42:10     error[E0209]: expected an expression: found `#`
assign_drive_strength.v:76:11    error[E0209]: expected an expression: found pull1
cont_assign_reeval.v             t1 y=1 / t1-stale y=1 / t1-settled y=0 / t2 y=0 / t3 y=1   (PASS)
hier_delay.v:41:10               error[E0209]: expected an expression: found `#`
intra_assign_delay.v:62:10       error[E0209]: expected an expression: found `#`
net_decl_assign_delay.v:37:8     error[E0208]: expected an identifier: found `#`
net_delay.v:44:8                 error[E0208]: expected an identifier: found `#`
reject_delay4.v:48:10            error[E0209]: expected an expression: found `#`
reject_intra_assign_on_net.v:49:14  error[E0209]: expected an expression: found `#`
```

Full form of the two rejects, verbatim:

```
$ ./zig-out/bin/vera --run tests/pending/D06/reject_delay4.v; echo "exit=$?"
error[E0209]: expected an expression: found `#`
  --> tests/pending/D06/reject_delay4.v:48:10
   |
48 |   assign #(1, 2, 3, 4) y = a;
   |          ^
   |
   = note: LRM annex A.8.3
   = help: run `vera --explain E0209` for a detailed explanation

error: could not compile due to 1 previous error(s)
exit=1

$ ./zig-out/bin/vera --run tests/pending/D06/reject_intra_assign_on_net.v; echo "exit=$?"
error[E0209]: expected an expression: found `#`
  --> tests/pending/D06/reject_intra_assign_on_net.v:49:14
   |
49 |   assign y = #5 a;
   |              ^
   |
   = note: LRM annex A.8.3
   = help: run `vera --explain E0209` for a detailed explanation

error: could not compile due to 1 previous error(s)
exit=1
```

So: `reject_intra_assign_on_net.v` meets its `E0209` today (and for the right
reason — see *Fixtures*), `reject_delay4.v` does not meet its `E0210` and will
not until `delay3` parses, and `assign_drive_strength.v` is refused at the
`drive_strength` it is about. Score on the twelve: one positive passing
(`cont_assign_reeval.v`), nine positives unmet at `E0208`/`E0209`, one reject
met (`reject_intra_assign_on_net.v`), one reject unmet (`reject_delay4.v`).
This correction does not change that count — it changes what two of the entries
would have to do to earn their score.

## Corrected after review

Two defects were charged to this row. Both are fixed here; nothing was
withdrawn, so no claim moved to another row.

**1. `assign_drive_strength.v`'s stated discriminator was wrong** (review §5.4).
The old header said the `t=11` line "is what separates a real strength model
from 'last driver wins' or 'any conflict is x'". It is not. At `t=11` the
drivers are `a = 1'bz` (HiZ) and `b = 0` (We0), and four-state resolution with
no strength model whatsoever already gives `0` for z-vs-0 — z loses to any
driven value. The line therefore had no teeth against either named failure
model, and the fixture's only real discriminator was `t1 y=1`.

Fixed by re-deriving what each line rules out and by adding a line that carries
the weight the `t=11` line was falsely credited with. Stimulus `a := 1'b0,
b := 1'b1` at t=20, sampled `t21`, gives the **same two drivers with both
polarities reversed**:

| line | drivers | Fig 9-3 levels | correct | strength-blind | last-driver-wins | value-biased (wired-or / "1 wins") |
| --- | --- | --- | --- | --- | --- | --- |
| `t1 y=1`  | Pu1 vs We0 | 5 vs 3 | **1** | x | 0 | 1 |
| `t11 y=0` | HiZ vs We0 | 0 vs 3 | **0** | 0 | 0 | 0 |
| `t21 y=0` | Pu0 vs We1 | 5 vs 3 | **0** | x | 1 | 1 |
| `w=x` ×3  | St1 vs St0 | 6 vs 6 | **x** | x | 0 | 1 |

No wrong model reproduces the `t1`/`t21` pair: any rule that picks by *value*
must give the same answer to both, and only a rule that picks by *strength*
flips with the polarity. `t11` is kept, with its role restated honestly — it
pins that a z **value** overrides a non-HiZ declared **strength**, which is a
real claim, just not a claim about the ordering. `.expected.txt` gains the one
line `t21 y=0`.

The §9.22.3 paraphrase in the header was also tightened: the old text said
Figure 9-3 "lays the levels out from bit 7 down", conflating the eight strength
*levels* with the bit positions. The clause's own sentence is "bits 5-3 for
strength0 and bits 2-0 for strength1", i.e. three bits encoding a level 0..7.
The ordering the fixture depends on — Pu 5 above We 3 — is unchanged; only the
description of the encoding is corrected.

**2. Both reject fixtures carried a bare `//! reject`** (review §5.1). A bare
`reject` is worse than weak here: `lib/backend/tb.zig:264` treats an empty rest
as `error.BadSyntax`, and the `DiagnosticsReported` fallback at
`tests/torture.zig:223` returns true for *any* diagnostic, so both files scored
as satisfied by today's incidental "expected an expression: found `#`" and would
have gone on scoring as satisfied after `delay3` landed no matter what the
parser complained about.

- `reject_intra_assign_on_net.v` → `//! reject E0209`. Derived from the grammar,
  not from the current output: `net_assignment ::= net_lvalue = expression`
  admits an `expression` after the `=` and `#` cannot begin one. Because
  `delay3` sits before the lvalue list, this stays true after the feature lands,
  which is exactly why it is worth pinning — the directive now forbids the
  plausible future "fix" of re-reading the line as `assign #5 y = a;`.
- `reject_delay4.v` → `//! reject E0210` (*expected `')'`*). A.2.2.3's innermost
  bracket pair closes after the third `mintypmax_expression`, so the only
  terminal admitted at the fourth comma is `)`. VerA already emits E0210 for a
  group that is not closed (`lib/frontend/parser.zig:1911`), so this states the
  rule without inventing a diagnostic code. The fixture is consequently unmet
  today (it gets E0209), which is the correct score for a feature that does not
  exist.

  **Judgement recorded, since it is a prediction rather than an observation:** an
  implementation that parses an unbounded comma list and then emits a dedicated
  "at most three delay values" diagnostic is equally conforming and would fail
  this directive. `E0210` was chosen over the safer `ParseError` because
  `ParseError` still admits a wrong-reason parse error, which is the defect being
  repaired. Each file's header instructs the implementer to retarget the
  directive to that dedicated code if they take that route — and never to
  weaken it back to a bare `reject`.

Nothing in `src/`, `build.zig` or `tests/fixtures/` was touched; the
`zig build torture` 1323/1323 gate is unaffected by this row, which contains no
`.va` file and is not walked by the torture runner.
