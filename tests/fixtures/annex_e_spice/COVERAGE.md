# Annex E coverage

## Source-audit correction (2026-09-23)

The historical census and green/closed assertions below are not a current
conformance measurement. See [the Annex E/F audit](../../../docs/conformance-annex-ef-review-draft.md)
for the PDF review, remaining obligations and targeted new results.

In particular, a parsed `.MODEL`/`.SUBCKT` interface is not execution of its
model parameters or body. E.1.1 is conditional on the supported SPICE flavor,
but silently dropping a supported subcircuit body does not establish its
behavior. The supported dialect and its unsupported constructs need a precise
contract; the existing H04 body/parameter tests remain relevant open evidence.

The rotational parent declarations in the existing primitive attribute fixtures
can supply the same discipline through E.3.2.2 when the attribute is ignored.
Those tests establish legal examples, not a discriminating proof of attribute
precedence. The attribute-only `primitive_segment_scan.va` is stronger and
remains explicitly limited.

New `audit_attribute_ignored_on_ordinary_instances.va` tests the required
ignore-on-ordinary-module/connection boundary behaviorally. The three new
`audit_primitive_attribute_*_rejected.va` cases separately test numeric,
undeclared and discrete-domain values on analog primitives; elaboration refuses
each with E0358 (`elab_names.checkPortDiscipline`). Each pins a distinct
diagnostic phrase, not the attribute name alone: echoed source lines can contain
that name even when an unrelated diagnostic caused rejection.

Source: `docs/annex-e-spice.html`, read section by section.

HTML section-ID audit: `sE-1` `sE-1-1` `sE-1-2` `sE-2` `sE-2-1` `sE-2-2` `sE-2-2-1`
`sE-2-2-2` `sE-2-2-3` `sE-3` `sE-3-1` `sE-3-2` `sE-3-2-1` `sE-3-2-2` `sE-3-3` `sE-3-4`
`sE-4` `sE-4-1` `sE-4-2`, plus the two table anchors `table-e-1` and `table-e-2`.
Nineteen sections. Annex E is normative.

Fifty-six fixtures live in this folder. (`spice_digit_names.va` was the newest before the
`h04_*` family; `.MODEL 2N2222` and a `.SUBCKT` with a numeric node, the names SPICE spells
that §2.7 has no bare form for, carried as §2.8.1 escaped identifiers — the card
reader used to drop the model silently and truncate the port list at the `1`.) Two more
arrived on 2026-09-20, both citing `E.3.2.2` for the first time in the tree:
`primitive_segment_discipline.va` (green) and `primitive_segment_scan.va` (this folder's
only `//! xfail`).
Measured the same day: `zig build benchmark -- annex_e_spice` reports **45 of 56 behaving
as they say they do, 10 failing, 1 `//! xfail`**. All ten failures are in the `h04_*`
netlist-body family; nothing else here is red. (The 9/31 and the 21/40 this paragraph used
to quote were written when nothing here could elaborate, and then when the row-map fixtures
elaborated but asserted nothing. Every `primitive_*.va` now carries digits from Table E.1's
own Behavior column or, for the rows whose Behavior column is blank, from the interface the
table does fix. Counts elsewhere in this file may still be stale; the ROWS say what is
true.)

Almost every sentence in this annex is about *instantiating* something (a primitive, a
model, a subcircuit, a paramset bin) inside a Verilog-AMS module, and all three layers of
that now work: §6.2.2 flattens the instance tree (`ir/elaborate.zig`, E0204 retired), §6.7
resolves a dotted probe against the flattened design, and **Table E.1 ships as a prelude of
ordinary module declarations** — `Preprocessor.spice_primitives`, prepended exactly like
annex D's `disciplines.vams`, so a primitive is a module and gets §6.3 overrides, §6.5.5
named connection, §6.7.1 hierarchical access and their diagnostics from the code that
already implements them. `{attribute_instance}` in a connection list (A.4.1.1) parses, so
E.3.2.1's per-port `port_discipline` form is accepted too.

The last three closed by making E.1.1's ANTECEDENT true rather than by arguing about it.
`spice_model.va`, `spice_subcircuit.va` and `spice_case_lookup.va` each name an object
defined in a SPICE NETLIST, and E.1.1 conditions the whole family on the tool: "if a
simulator which supports Verilog-AMS HDL is also able to read SPICE netlists of a particular
flavor". VerA now is, for one flavor: `//! spice <one netlist line>` hands a fixture's cards
to the compiler verbatim (`lib/backend/tb.zig`), and `lib/frontend/spice_cards.zig` reads
`.MODEL` and `.SUBCKT` out of them and emits a Verilog-AMS module for each into the same
prepended-text channel Table E.1 already uses. So E.2's "the subcircuits and models contained
within the SPICE netlist are treated as module definitions" is met by them BEING module
definitions, and every clause about a module applies to them from the code that already
implements it.

**What that does and does not buy.** E.2's noun phrase is "subcircuits and models", and the
reader reads exactly those two declarations: device cards, `.TRAN`, `.PARAM` and `.INCLUDE`
are skipped in silence rather than diagnosed, because a reader that mines a netlist for
interfaces is not claiming to simulate it. A `.MODEL` wrapper takes its ports from the Table
E.1 primitive its type names, which is E.2.2.1 verbatim ("the ports and parameters of the
bjt are determined by the bjt primitive itself and not by the model statement"), and drops
the card's `BF`/`IS`/`VAF` — Table E.1 declares no such parameters and its bjt Behavior
column is empty, so this annex writes down no equation for them to enter. A `.SUBCKT` module
has an EMPTY body, because a subcircuit body is device cards in SPICE; it contributes no
equations, so under `//! solve` an instance of one is an open circuit. E.1.2's first bullet
is what makes all of this a choice rather than a shortfall: SPICE compatibility "is solely
determined by the authors of the simulator", and the flavor chosen here is named at the site.

SPICE has no reserved words, so a card is free to name a node `INPUT` or a model `WIRE`, and
both are annex B keywords once they are written as Verilog-AMS. The reader spells such a name
as a §2.8.1 escaped identifier (`spice_keyword_names.va`): §2.8.2 says an escaped identifier
is never a keyword, and neither the `\` nor its terminating space is part of the name, so the
module is still `wire` for E.2.1's match and the ports are still `input`/`output` for §6.7.1 —
while E.3 connects them by order, so the escape never has to be typed to make a connection.
The alternative was E0208 on a line of `spice_netlist.vams`, a file with no author.

Ingest lower-cases every identifier (E.2.1 first sentence: SPICE is case-insensitive), which
is what lets `elaborate.findModule` implement E.2.1's second sentence as one
`eqlIgnoreCase` pass scoped to the netlist-derived range and reached only after both exact
passes fail — E.3.3's "in case of a name match with differences in case, the module or
paramset does not interfere with the SPICE primitive ... but the resolution method described
in E.2.1 shall apply". Whether a netlist `.MODEL resistor` should shadow Table E.1's own
`resistor` is UNSPECIFIED by the annex (E.3.3 orders user-module against SPICE object, not
two SPICE objects); primitive-first is chosen and commented, and no fixture pins it.

### How a fixture that cannot elaborate still states a requirement

An `//! xfail` on a fixture that asserts nothing is worthless: the day the primitives ship
it XPASSes by merely COMPILING, the marker is deleted, and no one has checked that the
`resistor` actually stamped 1 kΩ. That day came, the sixteen row-map fixtures spent one
release green-and-empty being reported as such on every run, and they now carry digits.
The way in is **§6.7.1**, cited by twenty-nine files here:

> Potential and flow access for named and unnamed branches (including port branches) can
> be done hierarchically. […] Access of parameters can be done hierarchically.

That makes `I(r1.p, r1.n)` the flow of the primitive's own branch — the branch Table E.1's
Behavior column describes — and `r1.r` the parameter a `#(.r(1k))` override landed on,
both reachable from the instantiating module's analog block. Table E.1 (E.1.2, E.3) is
what gives those two names. Combined with `//! bias`, that turns "the annex says this must
elaborate" into "the annex says this must carry 1.0e-3 A", and the XPASS then means VerA
got it RIGHT rather than that VerA compiled it.

Where the LRM fixes no value the observable is chosen to match the rule instead of faked:
a **port association** (a potential the connection forces, against a bias that makes every
net distinct, with the named list written in reverse table order so a positional fallback
moves a digit), a **parameter binding** (every value distinct, so no permutation survives),
or a **resolved discipline** (asserted through the ACCESS FUNCTION it supplies — `Theta`
and `Tau` for `rotational`, `Omega` for `rotational_omega` — which does not type-check on
any other discipline). Each fixture's header says which of these it uses and why the
others were unavailable.

Sixteen of the nineteen sections have at least one fixture. The three that do not —
`sE-1`, `sE-2-2`, `sE-4` — are a motivation, a heading over three examples and a
one-sentence frame, and none of them states a rule. `sE-1-1` left that list when the three
SPICE-netlist fixtures started citing it: the section it was missing a fixture for is the
section that settles their verdict, so it is cited where the verdict is recorded. `sE-3-2-2`
left it on 2026-09-20, and the two fixtures that closed it are rows in the table below.
The annex TITLE is its own clause to `tests/harness.zig` (the bare `E` of `Annex E
(normative) SPICE compatibility`) and is the fourth id in this folder that no fixture cites
— it has no body text at all.

| HTML id | Rule | Fixtures |
|---|---|---|
| `E` (the annex title itself) | none — the title carries no body text | none, and none is owed. `tests/harness.zig` reads the bare letter out of `Annex E (normative) SPICE compatibility` as a clause, which is why it appears in `--coverage`; there is nothing under it to exercise, and no fixture cites bare `E` |
| `sE-1` | motivation for SPICE compatibility | none, and none is owed. The section states no requirement — it explains why the annex exists. No fixture carries `//! lrm E.1` |
| `sE-1-1` | if a tool reads a flavor of SPICE, anything instantiable in that flavor is instantiable in a module | `spice_model.va`, `spice_subcircuit.va`, `spice_case_lookup.va` — all three now cite it, and it is the section that decides their verdict rather than one they fail. The sentence is a single implication and VerA falsifies its antecedent, and all three are now **green**: each carries the annex's own cards on `//! spice` lines, which is a fixture MAKING the antecedent true rather than asserting it. The clause is met for the flavor named in `spice_cards.zig` — `.MODEL` and `.SUBCKT` declarations — and for no other |
| `sE-1-2` | four axes of incompatibility; the testable one is "primitives **shall**, and parameters and ports **can**, be named", and Table E.1 fixes the names | 20 fixtures cite it: the 16 `primitive_bjt/capacitor/diode/iexp/inductor/ipulse/ipwl/isine/jfet/mesfet/tline/vccs/vcvs/vexp/vpulse/vpwl.va`, plus `passive_named_ports.va`, `spice_semiconductor_primitives.va`, `spice_source_primitives.va`, `primitive_named_ports.va`. **All green.** The last four read every named parameter back through the instance (6.7.1) against its own literal, and write their named port lists in REVERSE Table E.1 order, so a tool that silently connected by position moves a digit; the seventeen `primitive_*.va` do the same for their own row, and each also evaluates its Behavior column (or, for a blank one, its port order) against a literal |
| `sE-2` | SPICE primitives behave like built-in primitives; models and subcircuits are treated as module definitions; all aspects implementation-dependent | `primitive_*.va` (the 17 above), `spice_model.va`, `spice_subcircuit.va`, `spice_network_primitives.va`, `spice_passive_primitives.va`. All **green**: the primitive half through the Table E.1 prelude, and the "defined within SPICE netlists" half through the `//! spice` cards, which become module declarations in the same channel. The subcircuit's BODY is still not read, and `spice_subcircuit.va` says so at the site |
| `sE-2-1` | exact-case match first; on no exact match, match the SPICE name regardless of case | `spice_case_lookup.va` — `VeRtNpN mixed_case(c1, b1, e1);`, with the three nets biased apart and the resolved object's `c`/`b`/`e` read back, so a successful fallback has to land on E.2.2.1's NPN and not merely on something. **green**: the exact-match arm is two passes (a module, then a shipped primitive — see `sE-3-3`) and the fallback is a third, `eqlIgnoreCase` over the netlist-derived modules only. It carries the same `//! spice` card as `spice_model.va` on purpose, so the two files differ in exactly one thing: the case of the name written in Verilog-AMS |
| `sE-2-2` | "This subsection shows some examples." | none, and none is owed — the heading carries no text of its own. The three numbered examples below it are each covered |
| `sE-2-2-1` | the `vertNPN` model instantiated by order (`Q1`) and by name (`Q2`), with the optional `s` port defaulted by omission | `spice_model.va` (`vertNPN q1(c1, b1, e1)` — ordered, three ports, `s` omitted) and `primitive_named_ports.va` (`bjt #(.area(2.0)) q1(.s(s1), .e(e1), .b(b1), .c(c1))` — named, and deliberately not in table order). Both **green**: `primitive_named_ports.va` against the shipped `bjt`, and `spice_model.va` against a `vertNPN` synthesized from its `//! spice` card, whose ports are the `bjt` primitive's exactly as this section requires. The named form with `s` *omitted*, which is literally what `Q2` does, has no fixture |
| `sE-2-2-2` | subcircuit `ecpOsc` referenced from a module; instance name not constrained to start with `X` | `spice_subcircuit.va` — `ecpOsc osc1(out, gnd);`, and `osc1` is the NOTE's point. The `.SUBCKT ECPOSC (OUT GND)` interface is asserted: `V(osc1.out, osc1.gnd)` against a bias that makes a reversed ordered connection read the opposite sign. **green** — `ecpOsc` resolves to the module synthesized from this fixture's own `.SUBCKT` card, case-insensitively per E.2.1 |
| `sE-2-2-3` | the `ecpOsc` body rewritten with native primitives: `vsine`, `isine`, `inductor`, `capacitor`, `resistor` | `primitive_capacitor.va`, `primitive_inductor.va`, `primitive_isine.va`, `primitive_vsine.va`, `passive_named_ports.va`, `spice_passive_primitives.va`, `spice_source_primitives.va` — one per primitive the example uses. **All green.** The example as a *whole module* is not reproduced anywhere |
| `sE-3` | Table E.1 names are required; connection by order follows the listed order; port default discipline `electrical`, direction `inout`; diode/bjt/mosfet/jfet/mesfet usable directly in a `paramset` | 27 fixtures cite it — the 17 `primitive_*.va`, the four `spice_*_primitives.va`, `passive_named_ports.va`, `primitive_named_ports.va`, the three `port_discipline` files, and `spice_binning.va` (whose `paramset annex_e_bin mosfet;` is the last paragraph's rule). **All green.** The ordering half has digits behind it: `spice_passive_primitives.va` and `spice_network_primitives.va` bias their nets apart and read the primitive's own branch back, so a transposed positional list fails instead of elaborating quietly. Neither the `electrical` default nor the `inout` default is asserted by anything — see the gap list |
| `sE-3-1` | `ccvs`, `cccs` and mutual inductors are **not** supported, because instance names cannot be passed as parameters | `unsupported_ccvs.va`, `unsupported_cccs.va`, `unsupported_mutual_inductor.va` — all three `//! reject E0904`, all three **green**, and now for the RIGHT reason: the prelude ships every supported row and deliberately ships none of these three, so E0904 here is E.3.1's rule and not a blanket refusal |
| `sE-3-2` | three-level precedence: `port_discipline` attribute, then resolution, then `electrical` | `primitive_discipline.va`, `primitive_mixed_discipline_override.va`. Both **green**, and observable through the ACCESS FUNCTIONS the discipline supplies — `Theta`/`Tau` for `rotational`, `Omega` for `rotational_omega`, `V`/`I` for `electrical` — since a spelling that belongs to the wrong discipline does not type-check. HOW: after the flatten a connected port IS the parent's net (Ruling E), so the discipline is that net's and the prelude's nature-neutral `V`/`I` is rewritten to its access functions (`Elaborate.primitiveAccess`). That collapses levels 1 and 2 of the precedence into one answer, which is why both files declare the attribute and the net together; an attribute on an UNCONNECTED primitive port still falls to level 3 |
| `sE-3-2-1` | `port_discipline` string attribute on a primitive instance, on a primitive port, or both; **ignored** on non-primitive modules and their ports | instance form: `primitive_discipline.va`. Port form: `primitive_port_discipline.va`. Combined form, the LRM's `vcvs` motor: `primitive_mixed_discipline_override.va`. All three **green**; the per-port form needed A.4.1.1's `{attribute_instance}` in a connection list, which the parser now skips. The ignore-on-other-modules half: `port_discipline_ignored_on_module.va` — **green**, and the half that is structural rather than checked: `Unit.primitive` is what gates the rewrite, and it is false for every module the user wrote. Nothing checks that the value must be a valid discipline of domain `continuous` |
| `sE-3-2-2` | with no attribute, take the discipline from `vpiLoConn` of other instances on the net segment; incompatible → 3.11 error; none continuous → `electrical` | `primitive_segment_discipline.va` — **green**, four of the clause's sentences pinned on one net pair: an attributed `r1` (E.3.2.1) and an attribute-less `r2` on the same declared `rotational` segment, probed through `Theta`/`Tau`, with the §5.4.1 pair flow 3.0e-3 = 2.0/1000 + 2.0/2000 proving both primitives ride ONE segment; plus an undeclared `u`/`v` pair whose primitive takes the clause's last sentence, the `electrical` default (1.5/4000 = 3.75e-4 through `V`/`I`). `primitive_segment_scan.va` — **`//! xfail`**, the arm no declaration can stand in for: the same circuit with the declarations removed, so `r1`'s attribute is the segment's only discipline and E.3.2.2's scan over the other instances is the only way `Theta(r2.p, r2.n)` can exist. What is pinned, what is honestly not, and the two ways a wrong tool prints something else are in each header. The §3.11 pairwise-incompatibility arm has no fixture — see the gap list |
| `sE-3-3` | an HDL module or paramset always wins over a SPICE object of the *exact* same name; a case-differing name does not interfere; a warning shall be issued | `spice_name_shadow.va` — **green**: a module actually *named* `resistor`, with `r` and `V(p,n)` read out of it, proving the Table E.1 name is not reserved. Its own header states how far that reaches: the harness compiles one `.va` with no companion SPICE netlist, so there is no second definition to be preferred over and no instantiation site to observe the preference at. It is now also the live test of the RULE and not just of the name: the prelude declares `resistor`, the fixture declares its own, and `Elaborate.findModule` searches the user's modules before the prelude — so a regression here silently swaps one module for another. `spice_case_lookup.va` covers the case-differing half and is **green**: it supplies a netlist, so there is a namespace for E.2.1's fallback to search, and `findModule` searches it strictly last. The mandated warning has no fixture, and E.3.3 says `may` for the primitive case |
| `sE-3-4` | Table E.2 names `fetlim`, `pnjlim`, `vdslim` usable as the string argument of `$limit()` (9.17.3) | `limit_fet.va`, `limit_pnj.va`, `limit_vds.va` — all three **green**, all three `//! bias` with a `CHECK` on the returned value. Arity: `limit_fetlim_missing_vth.va` and `limit_pnjlim_missing_args.va`, both `//! reject DiagnosticsReported`, both **green** |
| `sE-4` | "This section highlights some other issues" | none, and none is owed |
| `sE-4-1` | multiplicity factor on module-defined subcircuits via `$mfactor` (6.3.6) | `mfactor_subcircuit.va` — **green**. Pins Table 9-29's top-level value, `$mfactor == 1.0` exactly, in a module declaring no parameters. Partial by construction: `$mfactor_specified * $mfactor_hier` needs a hierarchy, and the header says so |
| `sE-4-2` | binning and libraries; the Verilog-AMS analogue is several same-named `paramset`s selected by 6.4.2 | `spice_binning.va` — two `paramset annex_e_bin mosfet` blocks with disjoint `l` ranges and an instance at `l = 180n`. WHICH bin was selected is asserted, and that is the whole point of the clause: the two bins give `w` different defaults (1u, 2u) and the instance overrides only `l`, so `m1.w == 1e-6` holds if and only if 6.4.2 chose the first. **Green.** Both halves shipped: §6.4.2 selection, and the `mosfet` the two bins specialize |
| `table-e-1` | 19 primitive rows, each with its port names, parameter names and behavior | all 19 rows have a fixture — see the row map below — and all 19 elaborate. The *Behavior* column is IMPLEMENTED for the 13 rows that have one (the 6 empty-column rows ship as interface only, with the reason at each site in `Preprocessor.spice_primitives`) and is ASSERTED by a fixture for exactly two rows: `resistor` in `spice_passive_primitives.va` (tc1 = tc2 = 0, so V = I·r·(1+tc1·T+tc2·T²) collapses to I = 1.0/1000 with no reading of T left open) and `vcvs` in `spice_network_primitives.va` (V(p,n) = gain·V(ps,ns) = 2.0·0.5), with `primitive_discipline.va` and `primitive_port_discipline.va` reading the resistor row in the rotational natures. The other 17 rows are unevaluated — see the gap list |
| `table-e-2` | `fetlim(vth)`, `pnjlim(vte, vcrit)`, `vdslim()` | `limit_fet.va`, `limit_pnj.va`, `limit_vds.va` — all three green. All three rows, including the "(none)" arity of `vdslim`, are spelled |

## Table E.1, row by row

Nineteen rows, nineteen fixtures, every port name and every parameter name of every row
written out in source, and every one elaborating against the shipped prelude.

| Row | Ports / parameters spelled | Fixture |
|---|---|---|
| `resistor` | `p, n` / `r, tc1, tc2` | `passive_named_ports.va` (named), `spice_passive_primitives.va` (ordered) |
| `capacitor` | `p, n` / `c, ic` | `primitive_capacitor.va` |
| `inductor` | `p, n` / `l, ic` | `primitive_inductor.va` |
| `iexp` | `p, n` / all 9 | `primitive_iexp.va` |
| `ipulse` | `p, n` / all 10 | `primitive_ipulse.va` |
| `ipwl` | `p, n` / `dc, mag, phase, wave` | `primitive_ipwl.va` |
| `isine` | `p, n` / all 14 | `primitive_isine.va` |
| `vexp` | `p, n` / all 9 | `primitive_vexp.va` |
| `vpulse` | `p, n` / all 10 | `primitive_vpulse.va` |
| `vpwl` | `p, n` / `dc, mag, phase, wave` | `primitive_vpwl.va` |
| `vsine` | `p, n` / all 14 | `spice_source_primitives.va` |
| `tline` | `t1, b1, t2, b2` / `z0, td, f, nl` | `primitive_tline.va` |
| `vccs` | `sink, src, ps, ns` / `gm` | `primitive_vccs.va` |
| `vcvs` | `p, n, ps, ns` / `gain` | `primitive_vcvs.va` (named), `spice_network_primitives.va` (ordered) |
| `diode` | `a, c` / `area` | `primitive_diode.va` |
| `bjt` | `c, b, e, s` / `area` | `primitive_bjt.va`, `primitive_named_ports.va` |
| `mosfet` | `d, g, s, b` / `w, l, ad, as, pd, ps, nrd, nrs` | `spice_semiconductor_primitives.va`; `spice_binning.va` uses the row as a paramset target |
| `jfet` | `d, g, s` / `area` | `primitive_jfet.va` |
| `mesfet` | `d, g, s` / `area` | `primitive_mesfet.va` |

The two connection *forms* are both present and deliberately split: named connection in
the `primitive_*.va` set and in `passive_named_ports.va`, ordered connection
in `spice_passive_primitives.va`, `spice_network_primitives.va`
and `spice_model.va`. E.3's "for connection by order instead of by name, the
ports and parameters shall be given in the order listed" therefore has both sides written
down, and both sides compile.

## The xfail ledger

**One entry, and it is new — `primitive_segment_scan.va`, added 2026-09-20.** The three
entries this section held before it were all one reason wearing three hats — the object the
instance names is defined in a SPICE netlist, and VerA read none — and the reason is now
false rather than excused. `//! spice` plus `lib/frontend/spice_cards.zig` make E.1.1's
antecedent true for `.MODEL` and `.SUBCKT` declarations, so:

| Was blocked on | Sections | Now |
|---|---|---|
| the `vpiLoConn` scan over other instances on the segment, where no declaration supplies the discipline | `sE-3-2-2` | **OPEN.** `primitive_segment_scan.va` dies on `E0501` at the `Theta` access, because an undeclared net takes §3.8's `electrical` before any primitive discipline is resolved. Its assertions are already written, so the XPASS that closes this row means the resolved discipline was checked, not that the file compiled |
| no `.MODEL` input, so the model name was declared nowhere (E0904) | `sE-2-2-1`, `sE-2` | `spice_model.va` green: the card synthesizes `vertnpn` with the `bjt` primitive's ports |
| no `.SUBCKT` input, so the subcircuit name was declared nowhere (E0904) | `sE-2-2-2`, `sE-2` | `spice_subcircuit.va` green on the INTERFACE; the body is still not read, and it says so |
| E.2.1's fallback matches "the same name defined within SPICE", with no SPICE namespace to match in | `sE-2-1`, `sE-3-3` | `spice_case_lookup.va` green: one `eqlIgnoreCase` pass over the netlist-derived modules, after both exact passes |

What is genuinely still out of scope is one line down from those: a netlist SIMULATOR. No
device card is read, no `.SUBCKT` body, no `.PARAM` expression, no `.INCLUDE`/`.LIB`, no
dialect tokenizer. Each ceiling is written at its site in `spice_cards.zig`, and the two
fixtures that stand closest to one (`spice_subcircuit.va`'s silent internal nodes,
`spice_model.va`'s dropped `BF`/`IS`) name it in their own headers rather than leaving a
reader to infer it from a green run.

The `$limit` arity pair (`limit_fetlim_missing_vth.va`, `limit_pnjlim_missing_args.va`)
carries `//! reject DiagnosticsReported` and is green; it was the other debt in this folder
and it is paid.

## E.3.1 now passes for the right reason

`unsupported_ccvs.va`, `unsupported_cccs.va` and `unsupported_mutual_inductor.va` are
green, and this is the day the previous revision of this file was waiting for: E0904 used
to fire on *every* Table E.1 name here, so `resistor r1(p, n)` and `ccvs h1(p, n, sense,
2.0)` were indistinguishable and the three fixtures said nothing about the reason. The
prelude ships every supported row and deliberately ships none of these three — E.3.1:
"Verilog-AMS HDL does not support the concept of passing an instance name as a parameter.
As such, the following primitives are not supported: ccvs, cccs, and mutual inductors" —
so the absence is now a decision recorded at the site and E0904 is its diagnostic.

Note also that the controlling-instance argument in both source-controlled fixtures is a
bare identifier `sense` with no declaration behind it — nothing in this folder builds a
real controlling branch, and nothing needs to while the instantiation itself is refused.

## What this annex needs that no fixture supplies

An empty cell above is a real gap, and these are the gaps:

- **E.1.1 is no longer on this list.** It is cited now, by the three fixtures whose verdict
  it settles (`spice_model.va`, `spice_subcircuit.va`, `spice_case_lookup.va`), and it was
  never a gap in the sense the rest of this list means: the sentence is guarded by "if a
  simulator which supports Verilog-AMS HDL is also able to read SPICE netlists of a
  particular flavor", VerA reads none, so the antecedent is false and the rule is vacuous
  rather than violated. Closing it means a `.MODEL`/`.SUBCKT` parser — a second front end and
  a separate project — and no fixture here can be green on it, because passing would require
  a SPICE netlist to instantiate FROM. It is recorded as a verdict, on the fixtures, and not
  as work.
- **E.3.2.2's `vpiLoConn` scan, and that half only.** The clause was PARTLY implemented
  without a fixture, which was the worse of the two states; the two fixtures above were
  written before trusting the code rather than after. What exists and is now measured: the
  connected net's discipline is what a primitive's ports take
  (`Elaborate.primitiveAccess`), which is the clause's outcome for the single-discipline
  case, and `electrical` remains the default because that is what the prelude declares —
  both in `primitive_segment_discipline.va`. What does not, and is now measured as a gap
  rather than described as one: the scan over OTHER instances on the segment. VerA gives an
  undeclared net §3.8's `electrical` during elaboration, before any primitive discipline is
  resolved, so `primitive_segment_scan.va` dies on `E0501 unknown access function: Theta is
  not an access function of s1` and is `//! xfail` — the day the scan lands, that file
  compiles and its assertions are the evidence. Still open with no fixture at all: the
  pairwise COMPATIBILITY test and the §3.11 error when two attributes disagree. VerA
  compiles the incompatible case in silence today, so there is no diagnostic to pin and
  guessing one would be a claim about code that does not exist; recorded here as work, not
  as a verdict.
- **E.3's port defaults.** "The default discipline of the ports for these primitives shall
  be `electrical` and their descriptions shall be `inout`." The prelude declares both on
  every row, so VerA meets the sentence — but every fixture also declares its OWN nets
  `electrical` and its own ports `inout`, so nothing here would notice a tool that
  defaulted differently, and nothing would notice the prelude losing an `inout` either.
- **The Behavior column of Table E.1 — thirteen of the thirteen non-blank rows are now
  evaluated, and what is left is what the LRM does not say.** `resistor`
  (`spice_passive_primitives.va`, and again in the rotational natures in the two
  `port_discipline` files) and `vcvs` (`spice_network_primitives.va`, and
  `primitive_vcvs.va`) were first; `capacitor`, `inductor`, `iexp`, `vexp`, `ipulse`,
  `vpulse`, `ipwl`, `vpwl`, `isine`, `vsine` and `vccs` followed, each in its own
  `primitive_*.va`, each with a want a reader can derive from the printed row. A voltage
  row needs `//! solve` — a harness that imposed every unknown would read back its own
  `//! bias` — and a piecewise row needs several INSTANCES at one `//! time`, because two
  unnamed branches over one net pair still share an accumulator here
  (`ch05_analog_behavior/two_named_branches.va`). Three residues, all of them the LRM's:
  the `diode`/`bjt`/`mosfet`/`jfet`/`mesfet` and `tline` rows have an EMPTY Behavior column
  and E.2 makes them "implementation dependent", so those fixtures pin port order and
  parameter names and say in their headers why they pin nothing else; the `inductor` row is
  printed as `I = l * integral(V)` where the physics divides, so `primitive_inductor.va`
  uses l = 1 — the one value at which both readings agree — and declines to decide it; and
  `resistor` with nonzero tc1/tc2 is blocked because the annex writes a bare `T` and fixes
  no reference temperature, so `passive_named_ports.va` asserts naming and not current.
  One mechanical gap is named at the site instead of papered over: `ipwl`/`vpwl` pin the
  pairing of `wave` but not that `i` STRIDES by two, since a one-at-a-time walk lands on
  the same segment last (see the headers).
- **E.2.2.1's named form with the optional port omitted.** The LRM's `Q2` is
  `vertNPN Q2 (.c(c2), .b(b2), .e(e));` — named *and* defaulting `s`. Both fixtures on
  this example supply all four names or drop to ordered connection. The interaction of
  named connection with an omitted optional port is unwritten.
- **E.2.2.3 as a whole.** The six-primitive `ecpOsc` translation is covered
  primitive-by-primitive but never assembled, so nothing checks that a module can hold
  eleven primitive instances sharing internal nets.
- **E.3.2.1's value constraint.** "The value shall be of type string and the value must be
  a valid discipline of domain continuous." No fixture supplies an invalid
  `port_discipline` value — not a non-string, not a discipline of domain `discrete`, not
  an undeclared name.
- **E.3.3's warning.** "The Verilog-AMS simulator **shall** issue an warning message
  stating that the Verilog-AMS module or paramset is used instead of the SPICE model or
  subcircuit." A `shall` on a diagnostic with no fixture behind it. Unreachable without a
  companion SPICE input, which the torture harness does not have.
- **E.4.1 beyond the top level.** `mfactor_subcircuit.va` pins `$mfactor == 1.0` at the
  root. The clause is about a factor *on a subcircuit instance* — `$mfactor_specified *
  $mfactor_hier` — and that product needs two levels of hierarchy.
- **E.4.2 beyond a range test.** `spice_binning.va` now asserts WHICH bin was selected —
  the two bins carry different `w` defaults, so the width that reaches the mosfet names the
  winner. What is still unwritten is the rest of 6.4.2's ordering: two bins whose ranges
  BOTH admit the instance, where the tie is broken by specificity rather than by range.

## Fixture-name audit

The forty-one files this audit was written for, plus the two added on 2026-09-20, all mapped
above: `limit_fet.va`, `limit_fetlim_missing_vth.va`,
`limit_pnj.va`, `limit_pnjlim_missing_args.va`, `limit_vds.va`, `mfactor_subcircuit.va`,
`passive_named_ports.va`, `port_discipline_ignored_on_module.va`,
`primitive_bjt.va`, `primitive_capacitor.va`, `primitive_diode.va`,
`primitive_discipline.va`, `primitive_iexp.va`, `primitive_inductor.va`,
`primitive_ipulse.va`, `primitive_ipwl.va`, `primitive_isine.va`, `primitive_jfet.va`,
`primitive_mesfet.va`, `primitive_mixed_discipline_override.va`,
`primitive_named_ports.va`, `primitive_port_discipline.va`,
`primitive_segment_discipline.va`, `primitive_segment_scan.va`,
`primitive_tline.va`, `primitive_vccs.va`, `primitive_vcvs.va`, `primitive_vexp.va`,
`primitive_vpulse.va`, `primitive_vpwl.va`, `primitive_vsine.va`, `spice_binning.va`,
`spice_case_lookup.va`, `spice_model.va`, `spice_name_shadow.va`,
`spice_network_primitives.va`, `spice_passive_primitives.va`,
`spice_semiconductor_primitives.va`, `spice_source_primitives.va`,
`spice_subcircuit.va`, `unsupported_cccs.va`, `unsupported_ccvs.va`,
`unsupported_mutual_inductor.va`.

Thirty-two fixtures carry `//! bias`, ten `//! analysis`, ten `//! time` and six
`//! solve` — the last three are what evaluating a source row costs. None carries
`//! temp`, which is the `resistor` tc1/tc2 gap above. Five carry a `//! reject` line:
three `E0904` (E.3.1's unsupported trio) and two `DiagnosticsReported` (the `$limit` arity
pair). All five are green.

No fixture in this folder asserts nothing. The pattern every `primitive_*.va` follows is
`spice_passive_primitives.va`'s: `//! bias` (plus `//! time`/`//! solve` where the row is a
waveform or a potential), then §6.7.1 out-of-module access to the primitive's OWN branch and
parameters, with the want a literal derived from Table E.1. Each one was checked by mutating
the prelude equation it covers and confirming the fixture goes red; the one mutation that
did NOT show up, an `ipwl` stride, is written down in the gap list rather than left implied.
