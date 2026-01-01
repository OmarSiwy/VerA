# Annex D coverage — standard definitions

Source: `docs/VAMS-LRM/annex-d-stddefs.html`, read in full. Annex D is normative and
publishes three files verbatim: `disciplines.vams`, `constants.vams` and
`driver_access.vams`. There is no prose to conform to — the conformance question is
whether the implementation supplies those files and whether their text compiles and
means what it says.

HTML section-ID audit: `sD-1` `sD-2` `sD-3`. Three IDs, one per file; the annex has no
subsections, so the table below is cut on the annex files' own comment-delimited blocks
and macro families instead.

| Annex D construct | Fixture or disposition |
|---|---|
| **D.1** `DISCIPLINES_VAMS` multiple-inclusion guard | `disciplines_vams_guard_idempotent.va` (double `include`, `electrical` and `P_CELSIUS0` still usable after) |
| D.1 `discipline \logic` — escaped name, `domain discrete`, natureless | `literal_logic_discipline.va` — **xfail**: VerA accepts an analog access function on a natureless `\logic` net; the escaped name resolves to the prelude's discipline, which binds no natures, and nothing then constrains which access name is legal on it |
| D.1 `discipline ddiscrete` — `domain discrete`, natureless | `discrete_disciplines.va` — **xfail**: VerA accepts an analog access function on a natureless `ddiscrete` net, same root cause |
| D.1 `_ABSTOL` override arms (16 `ifdef`/`else` pairs) | `abstol_override_branches.va` defines all sixteen before `include "disciplines.vams"` and re-declares the shape locally so the `ifdef` arm is provably taken even on a prepending compiler |
| D.1 electrical natures `Current` `Charge` `Voltage` `Flux` (`I` `Q` `V` `Phi`) | `electrical_definitions.va` writes the block in the annex's own §3.6.1/§3.6.2 syntax under prefixed names; `literal_electrical_disciplines.va` reads the implementation's `V`/`I`; `Phi` is exercised as magnetic's flow in `literal_magnetic_discipline.va`; `Q` only through the reject in `unbound_nature_charge_rejected.va` |
| D.1 `discipline electrical` (conservative) | `literal_electrical_disciplines.va`, plus every fixture in this directory that carries an `electrical` port |
| D.1 `discipline voltage` / `discipline current` (signal-flow) | `literal_electrical_disciplines.va` (positive: `V` on a `voltage` net); `electrical_definitions.va` (`voltage_d`/`current_d`, user-written); rejects below |
| D.1 signal-flow half-binding — no flow nature on `voltage` | `signal_flow_flow_access_rejected.va` — **xfail**: VerA accepts `I` on a `voltage` net; `checkAccessMatch` (`src/ir/lower.zig`) returns early when the discipline binds no nature for that half |
| D.1 signal-flow half-binding — no potential nature on `current` | `signal_flow_potential_access_rejected.va` — **xfail**: same early return, so `V` on a `current` net resolves silently |
| D.1 access name must match the *net's* discipline | `unbound_nature_access_rejected.va` (`Temp` on `electrical` — nature bound into another discipline) and `unbound_nature_charge_rejected.va` (`Q` — nature bound into none). Both reject E0501 today, no xfail |
| D.1 magnetic: `Magneto_Motive_Force` (`MMF`), `discipline magnetic` with `flow Flux` | `literal_magnetic_discipline.va` — pins that magnetic reuses the *electrical* `Flux`/`Phi`, there being no separate magnetic flux nature |
| D.1 thermal: `Temperature` (`Temp`), `Power` (`Pwr`), `discipline thermal` | `literal_thermal_discipline.va` (implementation's copy) and `thermal_definitions.va` (user-written, prefixed, crosses into D.2 via `P_CELSIUS0`) |
| D.1 kinematic `Position` (`Pos`), `Velocity` (`Vel`), `Force` (`F`) | `literal_kinematic_disciplines.va` |
| D.1 kinematic `Acceleration` (`Acc`), `Impulse` (`Imp`) | *nothing* — neither nature is bound into a standard discipline, and no fixture probes `Acc` or `Imp` |
| D.1 `discipline kinematic` / `kinematic_v` | `literal_kinematic_disciplines.va` — two potential natures over one shared flow nature, both probed |
| D.1 rotational `Angle` (`Theta`), `Angular_Velocity` (`Omega`), `Angular_Force` (`Tau`) | `literal_rotational_disciplines.va` |
| D.1 rotational `Angular_Acceleration` (`Alpha`) | *nothing* — bound into no standard discipline, never probed |
| D.1 `discipline rotational` / `rotational_omega` | `literal_rotational_disciplines.va` — the same shared-flow shape as kinematic |
| D.1 `idt_nature` / `ddt_nature` cross-links | `electrical_definitions.va` declares the four-way `Current`↔`Charge` / `Voltage`↔`Flux` links and they must parse for the file to run; no fixture asserts the *relationship*, because no language construct reads it back |
| D.1 nature identifier as `ddt`/`idt`/`idtmod` tolerance argument (§5.5.3) | `nature_as_ddt_abstol_argument.va` — green. The nature scope is consulted in the tolerance slot only (`Lower.abstolSlot` names the slot for each of the three operators), so a variable named after a nature still shadows it everywhere, including there |
| D.1 `units` attribute values | *nothing asserted* — transcribed in `electrical_definitions.va`, `thermal_definitions.va`, `abstol_override_branches.va`, never read back |
| D.1 `abstol` attribute values | *nothing asserted* — see "What is not covered" |
| **D.2** `CONSTANTS_VAMS` guard | `disciplines_vams_guard_idempotent.va` |
| D.2 the fourteen `M_*` mathematical constants | `mathematical_constants.va` — all fourteen, exact binary64, read from the implementation's `constants.vams` |
| D.2 `P_C` and `P_U0_OLD` | `vacuum_constants.va` — including the parenthesisation of ``(4.0e-7 * `M_PI)`` under §10.4 textual expansion |
| D.2 `P_CELSIUS0` | `celsius_constant.va` (with `$temperature`), `thermal_definitions.va`, `disciplines_vams_guard_idempotent.va` |
| D.2 selector chain, `PHYSICAL_CONSTANTS_NIST2018` arm | `physical_constants_nist2018.va` — outermost, wins with every lower-priority selector also defined; the only arm that moves `P_U0` |
| D.2 selector chain, `PHYSICAL_CONSTANTS_SPICE` arm | `physical_constants_spice.va` — with `OLD` and `NIST2010` also set |
| D.2 selector chain, `PHYSICAL_CONSTANTS_OLD` arm | `physical_constants_old.va` — with `NIST2010` also set |
| D.2 selector chain, `PHYSICAL_CONSTANTS_NIST2010` arm | `physical_constants_nist2010.va` |
| D.2 selector chain, innermost `else` (NIST1998 fallback) | `physical_constants_nist1998.va` — the one arm needing no `undef` plumbing |
| D.2 the twenty `P_{Q,K,H,EPS0}_{SPICE,OLD,NIST1998,NIST2010,NIST2018}` base macros | *not read directly* — every fixture reads them through `P_Q`/`P_K`/`P_H`/`P_EPS0` after selection. A `constants.vams` that omitted a base name but inlined the right value in the chain would pass |
| **D.3** the implementation must *supply* `driver_access.vams` | `driver_access_include.va` — **xfail**: VerA ships `constants.vams` and `disciplines.vams` as builtin includes but not D.3, so `` `include "driver_access.vams" `` is E0126 `cannot find include file` (`src/frontend/preprocessor.zig` `builtin_includes` has two entries, not three) |
| D.3 the twelve `DRIVER_*` bit positions | `driver_flags_low.va` (UNKNOWN…BEHAVIORAL) and `driver_flags_high.va` (SDF…WAND) pin each mask and the two disjointness sums 31 and 2016 — but they `define` the masks themselves, so what runs is the lexer's `32'b` conversion, not D.3. `driver_access_include.va` is the half that reads the annex file |
| D.3 `DRIVER_ACCESS_VAMS` guard | *nothing* — `driver_flags_low.va`/`_high.va` deliberately do **not** wrap in it (with the guard, an implementation that does ship D.3 erases the whole module and the fixture asserts nothing), and `driver_access_include.va` cannot reach it while the include fails |

Fixture-name audit, 27 files, all mapped above: `abstol_override_branches.va`,
`celsius_constant.va`, `disciplines_vams_guard_idempotent.va`, `discrete_disciplines.va`,
`driver_access_include.va`, `driver_flags_high.va`, `driver_flags_low.va`,
`electrical_definitions.va`, `literal_electrical_disciplines.va`,
`literal_kinematic_disciplines.va`, `literal_logic_discipline.va`,
`literal_magnetic_discipline.va`, `literal_rotational_disciplines.va`,
`literal_thermal_discipline.va`, `mathematical_constants.va`,
`nature_as_ddt_abstol_argument.va`, `physical_constants_nist1998.va`,
`physical_constants_nist2010.va`, `physical_constants_nist2018.va`,
`physical_constants_old.va`, `physical_constants_spice.va`,
`signal_flow_flow_access_rejected.va`, `signal_flow_potential_access_rejected.va`,
`thermal_definitions.va`, `unbound_nature_access_rejected.va`,
`unbound_nature_charge_rejected.va`, `vacuum_constants.va`.

There is no `.vh` in this directory. Every fixture that needs the check macros includes
the suite-wide `tests/fixtures/check.vh`. The four `*_rejected.va` files and the two
discrete-discipline files include nothing but `disciplines.vams`, because a rejected file
never reaches an assertion.

## The xfail ledger

Five fixtures state an Annex D rule the compiler under test does not yet meet. They are
the honest debt of this chapter, and they fall into three groups.

1. **Natureless disciplines are not enforced** — `literal_logic_discipline.va`,
   `discrete_disciplines.va`. §3.6.3 says a net with a natureless discipline cannot appear
   in an analog behavioral description at all. VerA lets any access name through.
2. **Half-bound signal-flow disciplines are not enforced** —
   `signal_flow_flow_access_rejected.va`, `signal_flow_potential_access_rejected.va`.
   Same root cause, one level up: `checkAccessMatch` in `src/ir/lower.zig` returns early
   when the discipline binds no nature for the half being accessed, so the mismatch is
   never diagnosed. Both directions are pinned separately because a lookup keyed on "all
   natures the discipline mentions" would pass one and fail the other. Fixing the early
   return plausibly clears all four of groups 1 and 2 at once.
3. **One thing simply absent** — `driver_access_include.va` (D.3's file is not shipped,
   E0126). Independent of groups 1–2. `nature_as_ddt_abstol_argument.va` used to sit
   here and no longer does: §5.5.3's "the abstol attribute of a nature may also be
   accessed simply by using the nature's identifier" is implemented.

The two reject fixtures that are *not* xfail — `unbound_nature_access_rejected.va` and
`unbound_nature_charge_rejected.va` — are the cases where the nature exists somewhere,
so the access name reaches the discipline-mismatch check and E0501 fires correctly. That
is the boundary of what VerA currently gets right: it rejects a *wrong* nature, and
accepts anything when there is *no* nature.

## What is not covered, and why

- **`abstol` values.** Nothing in the suite compares a selected tolerance against its
  number. §5.5.3's `p.potential.abstol` is not parsed by VerA (E0207) and no other
  construct reads the attribute back, so `abstol_override_branches.va` can only show that
  an overridden nature still *elaborates* and still binds its access function — which is
  what distinguishes a taken `ifdef` arm from a syntax error, and is all that is
  observable. Same for `units`: transcribed everywhere, asserted nowhere.
- **`Acceleration`/`Impulse`/`Angular_Acceleration`.** D.1 declares sixteen natures but
  binds only twelve into disciplines. Four are leftovers that exist to give another
  nature an `idt_nature`/`ddt_nature`. `Charge` is pinned as a reject
  (`unbound_nature_charge_rejected.va`); the other three — `Acc`, `Imp`, `Alpha` — are
  not touched at all. The same reject shape would apply to each.
- **The `idt_nature`/`ddt_nature` relationships.** Declared and parsed, never asserted.
  A compiler that discarded the links entirely passes this directory.
- **The twenty `P_*_<VINTAGE>` base macro names.** Reachable only through the selector
  output. See the table row.
- **`DRIVER_ACCESS_VAMS`.** Untestable while D.3 is not shipped, and deliberately not
  wrapped around the two flag fixtures.
- **Guard suppression.** `disciplines_vams_guard_idempotent.va` covers only one direction
  — that a second include costs nothing. The other direction, `` `define DISCIPLINES_VAMS 1 ``
  ahead of the include so `electrical` is never declared, cannot be expressed: VerA's
  prelude runs before any user text and has set the guard already, so the `` `define `` is
  a no-op and no diagnostic can be provoked.
- **User-written `domain discrete`.** Both discrete fixtures bind the *prelude's*
  `\logic`/`ddiscrete`. No fixture declares a natureless discipline of its own.
- **Copyright and distribution terms.** D.1–D.3 open with license text permitting verbatim
  redistribution. Not a language rule; nothing to test.

## The prepend problem

VerA prepends `disciplines.vams` and `constants.vams` before any user text, which changes
what an `` `include `` of either file *means* and is the single largest confounder in this
directory. Three consequences, all handled explicitly in the fixtures:

- An `` `include "disciplines.vams" `` is a no-op under VerA (the guard is already set) but
  is the first pass on a compiler that does not prepend. Fixtures include it anyway, so
  they run on both.
- `abstol_override_branches.va`'s sixteen `ifdef` arms are therefore only exercised on a
  non-prepending compiler. Its locally declared `annex_d_override_voltage` is the half
  that is observable everywhere. Forcing the arms under VerA would need
  `` `undef DISCIPLINES_VAMS `` plus a re-include, which re-declares all sixteen natures —
  something a conforming compiler may reject as duplicates, the guard existing precisely
  to prevent it. Not portable, so not done.
- The four non-fallback selector fixtures *do* use `` `undef CONSTANTS_VAMS `` before
  re-including, because the prepended pass already took the NIST1998 arm and the macros
  must move. That the `P_*` values move is what makes those fixtures observable at all.
  `physical_constants_nist1998.va` needs no plumbing: the already-run chain is the arm it
  wants.

## Literal versus user-written

Several D.1 blocks are covered twice on purpose, and the two halves test different things:

- `literal_*.va` bind the **implementation's** standard names to nets and probe them.
  They fail on a compiler that ships no `disciplines.vams`. Earlier revisions of these
  files re-declared the standard natures locally, which made them pass against their own
  text — that is why the current files declare nothing.
- `electrical_definitions.va` and `thermal_definitions.va` write the annex's blocks out in
  the §3.6.1/§3.6.2 declaration syntax under **prefixed** names (`annex_d_voltage`,
  `thermal_d`, …), so a compiler that dropped the re-declaration and silently resolved to
  the prelude cannot pass. The prefixes are load-bearing, not cosmetic.

Only electrical and thermal have the user-written half. Magnetic, kinematic and rotational
are covered by the literal fixtures alone.

## Assertion discipline

Every potential access is probed against a testbench bias that is stored into the unknown
vector and loaded straight back, so the difference is exactly 0.0 and `CHECKX` is honest.
No flow *probe* is ever asserted: a flow contribution makes `(p, gnd)` a flow source
(§5.4.2.2) and what a flow probe of one reads back is not a value Annex D fixes. The flow
half is instead exercised by naming the flow nature's access in a contribution, which is
the thing D.1 actually fixes. The two arithmetic checks that are not exact —
``$temperature - `P_CELSIUS0`` and its thermal twin — use `CHECK` with 1e-12, because 273.15
is not representable in binary64 and the subtraction loses 2.8e-14.
