# D03 — drive strengths, net-type strengths, trireg charge and port conversion

Pending fixtures for the part of D03 that does **not** exist yet: the strength
model. Nets, independent drivers, wired-logic resolution, `assign` and
one-dimensional memories are already integrated (`src/sim/digital.zig`) and are
not re-specified here except where the strength model changes their answer.

## Ground truth (audited, not taken from COVERAGE/plan text)

`src/sim/digital.zig:103-114` says it itself:

> every driver here is at the SAME strength, so §7.10's eight drive strengths
> and §7.11's strength resolution are not implemented — two drivers that
> disagree conflict to x whether or not one of them would have won. The declared
> strength of `supply0`/`supply1`/`tri0`/`tri1` is the only part of that model
> which survives, and it survives as the special cases in `resolve`, not as a
> strength.

Verified against the built compiler (`zig-out/bin/vera --run`), not just the
comment:

| probe | result today |
|---|---|
| `assign (strong1, strong0) w = a;` | `E0209 expected an expression: found strong1` — `drive_strength` is not parsed at all |
| `trireg (large) c;` | `E0208 expected an identifier: found '('` — `charge_strength` is not parsed |
| `trireg #(0,0,50) c;` | `E0208` — a net `delay3`, and so charge decay, is not parsed |
| `module child(...); ... module top(...)` | `E1100 digital execution requires exactly one ordinary module` — no instances |
| trireg drive-then-float | **works**: retention is implemented, held indefinitely, covered only by a unit test inside `digital.zig` |
| `tri0`/`tri1`/`supply0`/`supply1` undriven | **works**: `undriven()` returns the pull/supply value |
| `wand`/`wor` value tables | **works**: `wired()` matches this spec's derivations on values |

So: the strength model is greenfield (no tokens reach the parser, no strength
state exists), charge *retention* is implemented-without-fixture-evidence, and
charge *decay* and *charge strength* do not exist.

## Clauses covered

Quoted from the offline VAMS 2.4 HTML in `docs/`, which is what these fixtures
cite in their `//! lrm` tags:

- **annex A.2.1.3 `net_declaration`** — the `net_type [drive_strength] …` and
  `trireg [charge_strength] … [delay3] …` alternatives, including the fact that
  they are *separate* alternatives.
- **annex A.2.2.1 `net_type`** — the eleven net types; `trireg` is not one of
  them.
- **annex A.2.2.2 Strengths** — `drive_strength`, `strength0`, `strength1`,
  `charge_strength ::= ( small ) | ( medium ) | ( large )`.
- **annex A.2.2.3 `delay3`**.
- **annex A.6.1** — `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
  list_of_net_assignments ;`
- **annex A.4.1** — `module_instantiation` (fixtures 10 and 11).
- **§6.5.7.1 *Matching size rule*** — "A scalar port can be connected to a
  scalar net and a vector port can be connected to a vector net or concatenated
  net expression of the matching width. The sizes of the ports and net must
  match." (fixture 10). This is a *narrowing* of the inherited clause 12, and
  where the two disagree the shipped document governs — see "Deliberately NOT
  covered".
- **§1.1** — "Verilog-AMS HDL consists of the complete IEEE Std 1364 Verilog
  specification", which is the hook that makes the *semantics* of all of the
  above IEEE Std 1364-2005 clause 7 (gate- and switch-level modeling: logic
  strength modeling, strengths and values of combined signals, strength
  reduction, strengths of net types), clause 3 (net types, trireg capacitive
  state and charge decay) and clause 12 (port connections as connections between
  nets rather than value copies — fixture 11). Port *sizing* is not taken from
  clause 12: §6.5.7.1 states it directly and more narrowly.

**Clause-number caveat.** The offline HTML set is the Verilog-AMS *delta*
document: it contains no clause 7 and no net-type/strength prose, only the
Annex A grammar. So the strength semantics are cited in prose as "IEEE Std 1364
Verilog clause 7 / clause 3 / clause 12" without sub-clause numbers, exactly as
`tests/pending/D06/assign_delay_single.v` cites "6.1.3 of IEEE Std 1364
Verilog". Note also that the repo's shorthand (`docs/CONFORMANCE-GAPS.md:25` and
`src/sim/digital.zig:103`) calls these "§7.9 wired logic / §7.10 the eight
levels / §7.11 the resolution table", while IEEE Std 1364-2005 as printed heads
7.9 "Logic strength modeling", 7.10 "Strengths and values of combined signals"
(wired-logic nets are a subclause of it) and 7.11 "Strength reduction by
nonresistive devices". Nothing here depends on which numbering is used; no
fixture tag claims a clause number that is not in the offline document.

## The model every derivation uses

IEEE Std 1364 clause 7 orders eight levels:

    supply(7) > strong(6) > pull(5) > large(4) > weak(3) > medium(2) > small(1) > highz(0)

Each driver contributes a level on the 0 side and a level on the 1 side —
value 1 → `(0, strength1)`, value 0 → `(strength0, 0)`, value x → `(strength0,
strength1)`, value z → `(0, 0)`. A net's own type contributes too: `tri0` adds
pull on the 0 side, `tri1` pull on the 1 side, `supply0`/`supply1` supply on
their side. The net takes the maximum of each side over all contributions and
collapses: `s1 > s0` → 1, `s0 > s1` → 0, `s0 == s1 ≠ 0` → x, both 0 → z. This
is the same resolution the `digital.zig` comment names as the upgrade path, and
it reproduces the standard's tables on every case asserted here.

## Fixtures

Each `NN_*.v` has an `NN_*.expected.txt` holding the exact `$display`
transcript. Reject fixtures have no `.expected.txt`: the expected outcome is a
diagnostic and **empty stdout** (the shape `expectRejected` in
`src/sim/digital.zig` already checks).

| # | file | pins | expected, and where it comes from |
|---|---|---|---|
| 01 | `01_drive_strength_dominance.v` | a stronger driver wins outright; only *equal* sides give x | `1 / 0 / 1 / 0 / x`: strong(6) vs weak(3) both polarities; then the strong driver goes z and the weak 1 shows; then both drive 0; then strong-x puts 6 on *both* sides so the tie is 6=6 → x. Today lines 1–2 are `x`. |
| 02 | `02_highz_half_strength.v` | strength is per *value*: a `(strong1, highz0)` driver's 0 is z | `0 / 1 / 1 / z`: the highz0 half contributes nothing, so the weak driver alone decides lines 1 and 3, the strong 1 wins line 2, and with the weak driver at z the net has no contribution at all → z. Today: `0 / x / x / 0`. |
| 03 | `03_three_drivers_strength_removal.v` | an x from an equal-strength tie is a value *at that strength*, overridable, and the tie returns when the overriding driver is removed | `x / 0 / 1 / x / 1`: two weak(3) drivers tie; strong(6) wins both polarities; strong → z restores the 3=3 tie; two weak drivers agreeing stay 1 (max(3,3)=3 does not change the value). Today lines 2–3 are `x`. |
| 04 | `04_ambiguous_strength_range.v` | an x-valued driver is an ambiguous *range*; an unambiguous signal above the range replaces it, one inside it does not | `x x / 1 x / 0 x / 0 1`: pull(5) x asserts 5 on both sides; strong(6) beats both halves on `w`; weak(3) loses to both halves on `v`; the last line is the same pull 1 losing to strong 0 and beating weak 0. Today every line is `x x`. |
| 05 | `05_tri0_tri1_pull_strength.v` | `tri0`/`tri1` pull at pull(5) *permanently*, not only when undriven | `0 1 0 0 / 0 1 x 1 / 0 1 0 0 / 0 1 x x`: a weak(3) driver can never move a tri0/tri1; a pull(5) driver ties with the pull → x; strong(6) wins. Line 4 is the sharp one: a weak **x** on a tri0 is a known 0. Today lines 2–4 read the driver's value on every column. |
| 06 | `06_supply_net_strength.v` | supply nets are level supply(7), and a `(supply1, supply0)` driver is its equal | `1 0 1 0 / 1 0 1 1 / 1 0 x 0`: strong(6) cannot move a supply net; a supply-strength driver of the opposite value ties with it → x; a supply-strength driver beats strong(6) on a plain wire. Today the supply-vs-supply column is 1 on every line — drivers of a supply net are ignored outright. |
| 07 | `07_wired_logic_under_strength.v` | strengths do not change the wired-logic *value* tables, except that a `highz0`-suppressed 0 is z and z is their identity | `0 1 / 1 1 / 0 0 / 1 1`: wand/wor applied to the driver values, with the `(strong1, highz0)` driver invisible when it holds 0. Line 2's wand is 1 for that reason; today it is 0. Lines 1, 3, 4 already pass and are here as regression pins (verified against today's binary). |
| 08 | `08_trireg_charge_decay.v` | the third `delay3` value is the charge decay time, and the countdown restarts on each entry into the capacitive state | `1 / 1 / 1 / x / 0 / 0 / x`: `#(0,0,50)`, released at t=10, so decay at t=60 — sampled at 49 and 59 (still 1) and 61 (x), never *at* 60, so no intra-timestep ordering is asserted. Re-driven 0 at t=61, released at t=62 → decay at 112, sampled at 72 (0) and 117 (x). Today the charge is held forever. |
| 09 | `09_trireg_capacitive_hold.v` | a trireg holds its last driven value when all drivers go to z, a plain wire does not, and with no `delay3` the charge never decays; `charge_strength` is legal and changes no stored value | `x x x x / 1 1 1 1 / 1 1 1 z / 1 1 1 z / 0 0 0 0 / 0 0 0 z` — the fourth column is a plain `wire` carrying the identical `assign`, so three of the six lines state trireg-vs-wire. Fails an implementation that parses `(large)` and then treats the net as a wire, one that lets fixture 08's decay fire without a `delay3` (the `held` line is 1000 ns after release), and one that stores the first driven value instead of the last. Transcript captured from `vera --run` with the two charge strengths deleted and nothing else changed (the run is quoted in the fixture header). |
| 10 | `10_port_concat_matching_width.v` | §6.5.7.1's matching-size rule, testable half: a vector port connects to a **concatenated net expression of the matching width**, bit-for-bit, in both directions | `in_concat 1001` (`h=2'b10`, `l=2'b01`, port `i = {h,l} = 1001`) and `out_concat 11 00` (`o = 4'b1100` split across `{oh, ol}`). Discriminates a port-side concatenation assembled in operand order rather than bit order (`0110` / `00 11`) and one that connects only the first operand. Replaces `10_port_width_conversion.v` — see "Corrected after review". |
| 11 | `11_port_driver_resolution.v` | an `output` port contributes a driver to the outer net and an `input` port is a receiver; two instances are two independently resolved drivers | `1 / 0 / 0 / z`: strong(6) instance beats weak(3); driving the strong instance's *input* to z removes its driver and the weak 0 shows; then the weak instance is silenced; then neither drives and the plain wire is z. |
| 12 | `12_reject_same_polarity_drive_strength.v` | **reject.** `(strong0, pull0)` is not derivable from A.2.2.2 — every alternative pairs one 0-side spec with one 1-side spec | `//! reject drive strength pairs one 0-side with one 1-side`, empty stdout. The substring is required: a bare `//! reject` is satisfied by today's incidental `E0209 expected an expression: found strong0` and by any later wrong-reason refusal. Guards the implementation that lexes two strength keywords and takes a maximum. |
| 13 | `13_reject_charge_strength_on_wire.v` | **reject.** `charge_strength` appears only in A.2.1.3's `trireg` alternatives; `wire (small)` parses as a `drive_strength`, and `small` is not a `strength0`/`strength1` | `//! reject charge strength is only legal on a trireg`, empty stdout. Same reasoning: bare would be satisfied by today's `E0208 expected an identifier: found '('`. Guards a uniform "parenthesised strength after any net type" parser. |

11 positive fixtures, 2 rejects.

## Deliberately NOT covered

- **`%v` strength formatting.** No fixture prints a strength. `%v` is missing
  (`docs/CLAUSE-AUDIT.md` row 17.1-07) and the runner accepts only `%b`. Every
  assertion here is a resolved four-state value.
- **The observable effect of `small`/`medium`/`large`.** A *driven* trireg takes
  its drivers' value and strength outright, so the stored charge's *level* only
  becomes visible through a switch primitive (D08) or `%v`. Fixture 09's three
  trireg columns therefore assert only that the declaration is legal and changes
  no value; its teeth are in the fourth (`wire`) column and in the no-decay
  line, not in the strengths. When D08 lands, the missing case is: a `large`
  trireg in the capacitive state driving through a `tran` against a `weak`
  source.
- **Port connections of mismatched width.** §6.5.7.1 says "The sizes of the
  ports and net must match", so under the shipped document there is no legal
  mismatched connection to specify a value for. The permissive low-order-bit
  rule (surplus outer bits idle, surplus port bits z) is IEEE Std 1364-2005
  §12.3.6, which is **not** in `docs/` — `grep -ri "low-order bit" docs/` is
  empty — and which §6.5.7.1 narrows. **No row owns that claim now.** It can
  come back only if 1364-2005 clause 12 is added to `docs/` *and* the conflict
  with §6.5.7.1 is resolved in favour of the base standard. Nor does D03 assert
  that a mismatch is *diagnosed*: §6.5.7.1 states a constraint and names no
  diagnostic, and §12.3.6 permits the mismatch with at most a warning, so a
  reject fixture would pin a rule neither document states.
- **Strength reduction (nonresistive and resistive devices).** Reduction is a
  property of `nmos`/`pmos`/`rtran`/`rcmos`/… — D08's row. There is no
  reduction path reachable from `assign` alone.
- **`` `unconnected_drive pull1 `` .** Its pull is stated in strengths
  (`docs/CONFORMANCE-GAPS.md:25`) but needs an unconnected instance port, i.e.
  D07; it belongs with fixtures 10/11 once those run.
- **Net `delay3` rise/fall.** Fixture 08 uses `#(0, 0, 50)` precisely so that
  only the decay value matters; delayed net updates are D06.
- **Vector strengths per bit, and `scalared`/`vectored`.** Every strength
  fixture here is scalar; the per-bit rule is the same fold applied bitwise and
  adds no new clause.
- **Ambiguous-against-ambiguous combination.** Fixture 04 combines an ambiguous
  signal with unambiguous ones only. Two overlapping ambiguous ranges produce
  the range results of clause 7's tables, which cannot be distinguished by a
  four-state `%b` print.

## Build / run

Not wired into `zig build` (nothing under `tests/pending/` is). Once the
strength model exists, each pair runs the way `tests/digital/*.v` does:

    zig build
    ./zig-out/bin/vera --run tests/pending/D03/01_drive_strength_dominance.v

compared against the matching `.expected.txt`; the reject fixtures must exit
non-zero with empty stdout:

    ./zig-out/bin/vera --run tests/pending/D03/12_reject_same_polarity_drive_strength.v

To adopt them, move the pairs into `tests/digital/` and add a
`expectStdOutEqual(@embedFile(...))` run step to the `digital_step` block in
`build.zig` (`build.zig:141-164` is the pattern), or add them as
`expectRun`/`expectRejected` cases in `src/sim/digital.zig`'s test block.

Today all eleven positive fixtures fail. Captured with the built binary, first
diagnostic per file (`for f in *.v; do vera --run $f; done`):

| files | first diagnostic today |
|---|---|
| 01–07, 11 | `E0209: expected an expression: found strong1` / `weak1` / `pull1` / `strong0` — the strength tokens are not expression syntax |
| 08, 09, 13 | `E0208: expected an identifier: found '('` — `(` after a net type |
| 10 | `E1100: digital execution requires exactly one ordinary module` |
| 12 | `E0209: expected an expression: found strong0` |

Note that 12 and 13 **do not pass today** even though they are reject fixtures:
their `//! reject` substrings name the reason the line must be refused, and
today's parse errors do not contain it. That is the intent — see the table.

## Corrected after review

- **Fixture 10 rewritten and renamed** (`10_port_width_conversion.v` →
  `10_port_concat_matching_width.v`). The old fixture pinned mismatched-width
  port connections (truncation one way, z-extension the other) citing only
  A.4.1 and §1.1, and never mentioned **§6.5.7.1**, which says in the shipped
  document: "The sizes of the ports and net must match." Adopting it would have
  forced a conforming implementation to accept, and produce a specific value
  for, a connection this LRM calls illegal. The claim is withdrawn, not moved:
  it belongs to IEEE Std 1364-2005 §12.3.6, which is not in `docs/` and which
  §6.5.7.1 narrows, so **no row owns it** (conditions for its return are in
  "Deliberately NOT covered"). The replacement pins the other half of the same
  sentence — a vector port connected to a concatenated net expression of the
  matching width — which is positively testable and discriminates concatenation
  bit order in both port directions. The disputed `extended zz01` digit is gone
  with the stimulus that produced it; for the record, the reviewer was right
  that `pair` was a `reg [1:0]`, i.e. a variable on an input port, which 1364
  lowers as a continuous assignment and zero-extends to `0001` — the old file's
  own header named `0001` as the *wrong* answer. Neither number is asserted now
  because the connection is not legal here in the first place.
- **Fixture 09 given teeth.** It was the row's one wholly-already-passing
  fixture: three trireg columns that agree on every line assert nothing a
  compiler can get wrong once the declaration parses. A fourth column, a plain
  `wire` carrying the identical `assign` from the identical stimulus, now
  differs on three of the six lines, so the file fails an implementation that
  parses `(large)` and treats the net as an ordinary wire — the cheapest wrong
  way to make the new syntax "work" — and fails one that lets fixture 08's decay
  fire on a trireg with no `delay3`. The expected transcript was **re-captured**
  from `vera --run` on the body with only the two charge strengths deleted; the
  run is quoted verbatim in the fixture header.
- **Both reject fixtures now name their diagnostic.** `//! reject` was bare in
  12 and 13, which matches any failure; today each is satisfied by an incidental
  parse error that proves only that the syntax does not exist. They now carry
  `//! reject drive strength pairs one 0-side with one 1-side` and
  `//! reject charge strength is only legal on a trireg`. No E-code is named
  because none is allocated for either rule; the substring convention is the one
  `src/sim/digital.zig:1392-1429` already uses for digital rejections.
- **§6.5.7.1 added to "Clauses covered"**, and the §1.1 bullet no longer claims
  clause 12 for port *sizing* — it is claimed only for "a port connection is a
  connection, not a value copy", which is what fixture 11 actually uses.
- **The "today" section is now a captured table** rather than prose, and names
  `E1100` for fixture 10 only (11 reaches `E0209` first, not `E1100`).
