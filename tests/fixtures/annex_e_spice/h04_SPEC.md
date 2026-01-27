# H04 — SPICE interoperability (Annex E)

Eleven fixtures: ten positive, one reject. Every expected value is hand-derived
in the fixture's own header — except fixture 03, which deliberately writes no
current at all because Table E.1's `T` is not fixed by any clause; see
*Corrected after review*.

## Ground truth: what already exists

The plan's H04 bullet and `tests/fixtures/annex_e_spice/COVERAGE.md` both need
correcting in opposite directions, so read this before the fixtures.

**More is implemented than "a parsed placeholder primitive."** Table E.1 ships
as real module declarations in a prelude (`Preprocessor.spice_primitives`,
`lib/frontend/preprocessor.zig:2586`), with working equations for `resistor`,
`capacitor`, `inductor`, `iexp`, `ipulse`, `ipwl`, `isine`, `vexp`, `vpulse`,
`vpwl`, `vsine`, `vccs`, `vcvs`; interface-only (Behavior column empty in the
LRM) for `tline`, `diode`, `bjt`, `mosfet`, `jfet`, `mesfet`. E.3.1's `ccvs`,
`cccs` and mutual inductor are deliberately absent. E.3.2's access-function
substitution is implemented (`Flatten.primitiveAccess`,
`lib/ir/elaborate.zig:1803`) and E.3.3's ordering plus E.2.1's case-insensitive
fallback live in `Flatten.findModule` (`lib/ir/elaborate.zig:1748`). Forty-three
fixtures in `tests/fixtures/annex_e_spice/` are green. Port disciplines
(E.3.2.1/E.3.2.2) are covered there with digits — `primitive_discipline.va`,
`primitive_port_discipline.va`, `primitive_mixed_discipline_override.va` — so
this row adds nothing there.

**Less is implemented at the netlist boundary.** `lib/frontend/spice_cards.zig`
reads `.MODEL` and `.SUBCKT` *headers only*:

- a `.MODEL` card becomes `module <name>(<primitive's ports>); inout …;
  electrical …; <primitive> prim(…); endmodule` — **no parameter list at all**.
  The card's `R=10K` / `BF=80` are discarded; `isSpiceName` rejects any token
  containing `=`, so the value half of a `k=v` pair is never even tokenised.
  The file says so at the site: *"the card's `BF=80 IS=1E-18` parameters are NOT
  passed"*.
- a `.SUBCKT` card becomes a module with **an empty body**. Device cards,
  `.TRAN`, `.PARAM`, `.INCLUDE` are skipped in silence. The file says so:
  *"under `//! solve` an instance of it is an open circuit"*, and
  `tests/fixtures/annex_e_spice/spice_subcircuit.va` sits on that ceiling and
  explicitly declines to assert any internal node.
- Table E.1's `dc`, `mag`, `phase` are declared on every independent-source row
  and enter **no** equation (*"declared, in Table E.1's order, and unused"*).
- `$mfactor` is carried through elaboration (`Unit.mfactor`,
  `lib/ir/elaborate.zig:382`) but does **not** scale a child instance's
  contributions. Measured, not inferred: `runit #(.$mfactor(4)) x1(c,b);` over a
  1 kΩ Table E.1 resistor at 1 V reports `I(x1.p,x1.n) got=0.001 want=0.004` and
  `res[c] = 1.000000e-3`.

So the plan's *"some netlist model parameters are currently dropped"* is an
understatement: **all** of them are, and the subcircuit body goes with them.

## LRM clauses covered

Read from `docs/annex-e-spice.html` (checked against VAMS-2023 PDF pp. 414–422)
and `docs/ch4-expressions.html`.

| Clause | What it says that these fixtures use |
|---|---|
| **E.1** | "there is a huge legacy of SPICE netlists" — the motive for reading values, not just names |
| **E.1.1** | the conditional: IF the tool reads netlists of a flavor, THEN its objects are referenceable |
| **E.1.2** (bullets 2, 3, 4) | unsupported primitives; differing parameter names, remedied by "wrapper modules to map names" — a remedy the **user** applies, with no `shall` and no diagnostic in the bullet (see *Corrected after review*); differing model equations |
| **E.2** | "the subcircuits and models contained within the SPICE netlist are **treated as module definitions**" |
| **E.2.1** | case-insensitive fallback match for netlist-defined names |
| **E.2.2.1** | "the ports and parameters of the bjt are determined by the bjt primitive itself and not by the model statement" |
| **E.2.2.2** | the `ECPOSC` subcircuit — eleven device cards called an oscillator |
| **E.2.2.3** | its card-by-card translation to Table E.1 primitives, incl. `vsine #(.dc(5))` for `VA VCC GND 5` and `resistor #(.r(10k))` for `R1 B1 GND 10K` |
| **E.3** / Table E.1 | required primitive/parameter/port names and the Behavior column for `resistor`, `capacitor`, `vsine` |
| **E.3.3** | a Verilog-AMS module "will always be selected in favor of a SPICE primitive, model, or subcircuit using exactly the same name" |
| **E.4.1** | `$mfactor` on subcircuits defined as modules — "as if there are a specified number of copies in parallel" |
| **E.4.2** | binning/corners enter "via the instance line by default" |
| **§4.6.1 / Table 4-21, §4.6.2, §4.6.3** | what `"dc"`, `"ac"` name — i.e. what Table E.1's `dc`/`mag`/`phase` are for |
| **§6.3.3, §6.3.6, §9.18** | "The name shall be the name specified in the instantiated module" — instance parameter override by name, and the rule fixture 11 now rejects against; `$mfactor` scaling of flow; its resolution |
| **§4.5.4** Table 4-18 | "idt(expr,ic) Returns ∫ x(τ)dτ + c, where in this case c is the value of ic at t0" — Table E.1's capacitor `+ ic` |
| **§2.6.2** Table 2-1 | `10k` = 10000, the Verilog-AMS side of SPICE's `10K` |
| **§6.7.1** | hierarchical potential/flow/parameter access — how every fixture observes |
| **§9.15** | `$temperature` "returns the circuit's ambient temperature in Kelvin units" — the only thing the LRM fixes about the `T` of Table E.1's resistor polynomial, which is why fixture 03 writes no current |

## One line per fixture

| File | Pins | Expected value and derivation | Kind |
|---|---|---|---|
| `01_model_card_r_binds_table_e1_r.va` | a `.MODEL RMOD R R=2000` card's value reaches Table E.1's `r` | `r1.r = 2000`; `I(r1.p,r1.n) = V/r = 1.0/2000 = 5.0e-4 A` (no tc1/tc2 ⇒ polynomial factor exactly 1) | positive |
| `02_model_card_spice_scale_suffix.va` | SPICE scale suffixes on card values — the annex writes `10K`, `3PF`, `1UH` in its own netlists | `r1.r = 10000`; `I = 1.0/10000 = 1.0e-4 A`. Reading `10K` as bare 10 gives 0.1 A — a factor of 1000, not a rounding | positive |
| `03_model_card_tc1_enters_the_equation.va` | binding is general, not a special case for the headline parameter | `r1.r = 1000`, `r1.tc1 = 1e-3`, `r1.tc2 = 0` as literals; then **no current digits** — Table E.1's bare `T` is not fixed by any clause, so the claim is the `CHECKEQ` identity `I(r1.p,r1.n) == I(ref.p,ref.n)` at 1e-14 A against a longhand `resistor #(.r(1k),.tc1(1e-3),.tc2(0))` on its own node pair | positive |
| `04_model_card_capacitor_c_and_ic.va` | a second primitive type, and an initial-condition parameter | 1 mA forced into a `C=1E-3` cap ⇒ integrand `I/c = 1e-3/1e-3 = 1.0` exactly ⇒ `V = 1.0·t + 2.5`; asserts `V − 1.0·$abstime = 2.5` at t = 0, 0.5, 1.0 | positive |
| `05_instance_override_beats_the_model_card.va` | E.2.2.1 — the instance's parameters *are* the primitive's, so `#(.r(2500))` is legal and §6.3.3 makes it win over the card's `R=10K` | `r1.r = 2500`; `I = 1.0/2500 = 4.0e-4 A`. Card-wins would give 1.0e-4 | positive |
| `06_subckt_body_contributes_equations.va` | E.2's "module **definitions**" — device cards inside `.SUBCKT` become equations | 1k/3k divider from 1.0 V: `V(out,gnd) = 3000/4000 = 0.75 V`, `V(in,out) = 0.25 V`. Unequal resistors so a swap of the two cards is also caught; empty body gives 0.0 | positive |
| `07_subckt_source_card_drives_the_node.va` | a source card inside a subcircuit drives its node *and* sources current | `V1 OUT GND 2.5` ⇒ `V(out,gnd) = 2.5 V`; external 1 kΩ load draws `2.5/1000 = 2.5e-3 A` | positive |
| `08_vsine_dc_is_the_operating_point_value.va` | Table E.1's `dc`, isolated from any netlist | under `//! analysis dc`, `V(v1.p,v1.n) = dc = 2.5 V`, load current `2.5e-3 A`. Run today: `v1.dc got=2.5 ok=1` beside `V got=0 want=2.5 ok=0` | positive |
| `09_mfactor_on_a_netlist_subckt.va` | E.4.1 + §6.3.6 on a netlist subcircuit, with an unscaled control instance | control `I(x2.a,x2.b) = 1.0/1000 = 1.0e-3 A`; scaled `I(x1.a,x1.b) = 4 × 1.0e-3 = 4.0e-3 A`. Measured today on the Verilog-AMS equivalent: 1.0e-3 | positive |
| `10_verilog_module_wins_over_netlist_subckt.va` | E.3.3 name scoping, *with both candidates present*, **plus an in-file control with no Verilog-AMS rival** | shadowed: Verilog-AMS `rdiv` is 1k/1k ⇒ `V(out,gnd) = 0.5 V` (netlist `RDIV` 1k/3k ⇒ 0.75; neither ⇒ 0.0). Control: `.SUBCKT RNET`, one `R1 A B 4K` card, `I(x2.a,x2.b) = 1.0/4000 = 2.5e-4 A` — 0 if the netlist is unread. Both halves required; **red today** on the control | positive |
| `11_reject_parameter_name_not_in_table_e1.va` | E.3 makes Table E.1's `r, tc1, tc2` the resistor's complete parameter list and E.2.2.1 puts that list on the instance, so §6.3.3's "the name shall be the name specified in the instantiated module" refuses `resistor #(.rsh(50))` | must not compile; `//! reject E0907`. **Green today**, for the right reason (message names `rsh` and `resistor`) — kept as the guard on the change fixtures 01–05 request, which would otherwise be implemented by accepting any name | **reject** |

Ratio: 10 positive to 1 reject.

## Deliberately NOT covered

- **Whether a model card carrying a parameter Table E.1 does not declare must be
  diagnosed.** This was fixture 11's original claim and it is **withdrawn**, not
  relocated — see *Corrected after review*. No row owns it, because no clause in
  the shipped LRM states it.

- **ngspice numerical agreement.** X01's row. No fixture here compares against a
  reference simulator; every number is derived from Table E.1's own algebra.
- **Port disciplines (E.3.2, E.3.2.1, E.3.2.2).** Already pinned with digits by
  three green fixtures in `tests/fixtures/annex_e_spice/`. The one genuine
  remaining hole — an *unconnected* primitive port carrying `port_discipline`,
  which `Flatten.primitiveAccess` documents as its ceiling — has no observable
  circuit value to assert, so it gets no fixture rather than a vacuous one.
- **The five semiconductor rows' equations** (`diode`, `bjt`, `mosfet`, `jfet`,
  `mesfet`) and `tline`. Table E.1's Behavior column is empty for all six and
  E.2 makes them implementation dependent; a digit would be invented. Which is
  also why every model-card fixture here uses an `R`/`C` card: those are the
  rows whose parameters Table E.1 *does* name, so the expected value is derivable.
- **`.SUBCKT … PARAMS: k=v` and `{expr}` values inside a body.** Dialect syntax
  the annex never prints. Needs a decision on which SPICE flavor VerA claims
  (E.1.2 bullet 1 leaves it to "the authors of the simulator") before a fixture
  can state a right answer.
- **The E.3.3 *warning*** ("shall issue an warning message"). It is a `shall`,
  but `//! reject` means "must not compile" and this one must compile. Needs a
  warning-assertion directive.
- **E.3.4 `$limit` with `"pnjlim"`/`"fetlim"`/`"vdslim"`.** Five green fixtures
  already in `tests/fixtures/annex_e_spice/`.
- **E.1.2 bullet 2 (an unsupported primitive referenced by a netlist).** Today a
  `.MODEL X SW` is skipped and the user's instantiation line gets E0904, which
  blames the wrong line. Fixing it needs a dedicated diagnostic code, and
  `unsupported_ccvs.va` already records the same complaint for E.3.1.
- **Multi-level netlists** (`.SUBCKT` containing another `.SUBCKT` or a
  model-referenced device such as `R1 A B RMOD`), and `.INCLUDE`/`.LIB`.

## How to run these

**They cannot be run as-is today — the `//! spice` channel is not reachable from
the CLI.** `Preprocessor.Options.spice_netlist` is set in exactly one place,
`tests/torture.zig:166` and `:307`; `src/main.zig` has no `--spice` flag, so
`vera --run` silently ignores every `//! spice` line and **nine** of these eleven
fixtures die with `E0904: instance names no module` (it was eight before the
review; fixture 10 gained a netlist control).

Two independent blockers, both outside this row's write scope:

1. **The suite root is hardcoded.** `build.zig:428`:
   ```zig
   suite_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
   ```
   Either that becomes a list including `tests/pending`, or these files move into
   `tests/fixtures/annex_e_spice/` when they go green.
2. **No CLI netlist flag**, so the fixtures cannot be debugged one at a time the
   way every other fixture can.

Once (1) is wired, the command is the ordinary one:

```
cd /home/omare/Documents/Projects/Zig/VerA
zig build torture -- H04            # this row only
zig build torture -- --strict       # the whole gate, 1323 + 11
```

**Exactly two fixtures carry no `//! spice` line and therefore run singly today:
08 and 11.** (Fixture 10 used to be counted here; since the review it carries a
second netlist as its control, so it no longer does.) Captured, not typed:

```
$ zig build install
$ P=$(./zig-out/bin/vera --emit-exe --contract tools/contract.zig \
      -I tests/fixtures tests/pending/H04/08_vsine_dc_is_the_operating_point_value.va 2>/dev/null)
$ "$P"
=== 08_vsine_dc_is_the_operating_point_value ===
--- point 0 ---
  x[n] = 0.000000e0
  x[p] = 0.000000e0
  x[flowZ28nZ2cpZ29] = 0.000000e0
the dc override reaches Table E.1's dc got=2.5 want=2.5 ok=1
4.6.1: at the operating point an independent source holds its dc got=0 want=2.5 ok=0
so the 1 kohm load draws 2.5/1000 got=-0 want=0.0025 ok=0

$ ./zig-out/bin/vera --check --contract tools/contract.zig -I tests/fixtures \
      tests/pending/H04/11_reject_parameter_name_not_in_table_e1.va
error[E0907]: override names no parameter of the module: `rsh` is not a parameter of `resistor`
   --> tests/pending/H04/11_reject_parameter_name_not_in_table_e1.va:104:14
    = note: LRM 6.3
error: could not compile due to 1 previous error(s)          # rc=1, i.e. 11 is green
```

The other nine stop at `E0904: instance names no module` for their netlist-defined
name, which is the blocker above and not a fixture defect:

```
$ ./zig-out/bin/vera --check --contract tools/contract.zig -I tests/fixtures \
      tests/pending/H04/10_verilog_module_wins_over_netlist_subckt.va
error[E0904]: instance names no module: `rNet`
```

Nothing under `src/`, `build.zig` or `tests/fixtures/` was touched; `zig build
torture -- --strict` is still 1323/1323.

## Corrected after review

The adversarial review named H04 in §5.2 (citations), §5.4 (no teeth) and §5.5
(build spill). All of it is actioned here, plus one Class-A defect the review did
not name.

**1. Three wrong subclauses, all load-bearing (§5.2).** Each was opened in
`docs/` before being replaced.

| Was | Is | Why |
|---|---|---|
| `//! lrm 9.10` in fixture 03, for `$temperature` | `//! lrm 9.15` | §9.10 is *Simulator Time System Functions*. `$temperature` is in §9.15 *Analog Kernel Parameter System Functions*, Syntax 9-10. |
| `//! lrm 4.5.5` in fixture 04, for `idt`'s `ic` | `//! lrm 4.5.4` | §4.5.5 is the *circular integrator* `idtmod`. The `idt(expr,ic)` row is Table 4-18 in §4.5.4 *Time integral operator*. |
| `//! lrm 6.3.1` in fixture 05, for `#(.r(2500))` | `//! lrm 6.3.3` | §6.3.1 is *Defparam statement*; no `defparam` appears anywhere in this row. §6.3.3 is *Module instance parameter value assignment by name*, which is the construct written. |

The prose and the `CHECKX` label that repeated each number were corrected with
the directive, and the SPEC clause table above with them.

**2. Fixture 11's normative claim was invented, and is withdrawn (§5.2).** The
old `11_reject_unmapped_model_card_parameter.va` demanded a diagnostic for
`.MODEL RBAD R RSH=50`. Opening the clause: E.1.2's third bullet ends "This
level of incompatibility can be overcome by using wrapper modules to map names"
— no `shall`, no diagnostic, and the remedy is the user's. E.2 says "All aspects
of SPICE primitives are implementation dependent" and E.4.2 says "Support of
SPICE model cards is implementation specific". The review is right that refusing
the card makes the tool *less* able to read the netlists E.1 exists for.

*Where the claim went:* nowhere. It is withdrawn, not relocated, and no row owns
it, because no clause in the shipped LRM states it. What would bring it back: a
future LRM edition making the netlist reader's behaviour normative, or a VerA
policy document declaring a house rule — in which case it belongs to whichever
row owns that document, not to Annex E.

*What replaced it,* rather than leaving the row with no reject:
`11_reject_parameter_name_not_in_table_e1.va` moves the same name `rsh` from the
netlist, where Annex E is permissive, into Verilog-AMS source, where it is not.
E.3 makes Table E.1's `r, tc1, tc2` required and closed; E.2.2.1 puts that list
on the instance; §6.3.3 says "The name shall be the name specified in the
instantiated module". `resistor #(.rsh(50))` violates that `shall`. It is green
today at `E0907` and disclosed as green — it is the guard on the change fixtures
01–05 request, whose cheapest wrong implementation (accept any card name,
create the parameter on demand) would make `#(.rsh(50))` legal on the primitive
too. `//! reject E0907` rather than the old `//! reject rsh`, so the substring
names a minted code (`tests/torture.zig:223` accepts *any* diagnostic for a bare
`//! reject`).

**3. Fixture 10 had no teeth (§5.4).** Its only assertion, `V(x1.out,x1.gnd) =
0.5`, is the answer a tool with no netlist reader at all gives — measured, it
printed `got=0.5 want=0.5 ok=1` against HEAD, where `//! spice` is unreachable
from the CLI. Pairing it with fixture 06 in prose is not a fix; the control is
now *in the file*: a second `.SUBCKT RNET` with a name nothing shadows, whose
single `R1 A B 4K` card must carry `1.0/4000 = 2.5e-4 A`. A tool that ignores
netlists now fails that; a tool that lets the netlist win the name race fails the
0.5; only a tool with both halves passes. The file is red today for a stated
reason. H04 therefore no longer keeps a fixture that passes for the
feature-absent reason. (It keeps one that passes for the *right* reason —
fixture 11 — which is stated in its row above and in its header.)

**4. Build spill (§5.5).** `tests/pending/H04/.zig-cache` (18 MB) is deleted;
`git status --porcelain` is one line, `?? tests/pending/`.

**5. A Class-A defect the review did not name: fixture 03 wrote digits the LRM
does not fix.** Table E.1's resistor row is
`V = I · r · (1 + tc1 · T + tc2 · T²)` with a bare `T`, and the clause fixes
neither a reference temperature nor whether the polynomial is in absolute
temperature or in the rise above nominal. §9.15 only says `$temperature` returns
the ambient temperature in Kelvin. The two defensible readings disagree by 30%
at this fixture's stimulus:

```
T = absolute 300 K       factor = 1 + 1e-3·300 = 1.3   I = 1.0/1300 = 7.6923e-4 A
T = rise above tnom=300  factor = 1 + 1e-3·0   = 1.0   I = 1.0/1000 = 1.0e-3   A
```

The old fixture asserted `7.692307692307692e-4` at `1e-14` relative, which a
conforming tool taking the second reading fails, and the cheapest way to make it
pass is to force VerA's `T` convention onto the netlist boundary — a change this
row has no clause to demand. Per the rule for implementation-defined latitude,
the digits are **not** written. The card's three literals keep their `CHECKX`
(1000, 1e-3, 0 — those are round-trips of the card, not consequences of any
equation), and the equation claim is now the identity Annex E does state: a
card-derived instance and a longhand `resistor #(.r(1k),.tc1(1e-3),.tc2(0))` are
the same device and must carry the same current, `CHECKEQ` at `1e-14` A
(~1e-11 relative on either reading). Dropping the card's TC1 separates the two
sides by 2.3e-4 A, eleven orders above the band.

*Measured while building that control, and worth recording:* two primitive
instances placed between the **same** two nodes both report the aggregate branch
flow, so a `CHECKEQ` across a parallel pair is vacuous — at `.r(1k)` against
`.r(2k)` both sides read `1.269e-3` and `ok=1`. The control therefore sits on its
own node pair `(c, b)` with `c` biased to 1.0 V; the same experiment then reads
`7.692e-4` against `1.0e-3`, `ok=0`. Fixture 09's control was already built this
way; fixture 10's new control is on `(in, gnd)`, a branch pair the shadowed
divider does not touch, and was verified to read `2.5e-4` on a Verilog-AMS
stand-in.

**Where this row disagrees with nothing.** Every value the review disputed for
other rows is absent here; §5.3 names no H04 number and §5.6 names no H04
reproduction defect. The transcripts in this document were re-captured by
running the commands above, not edited.
