# Annex E coverage

Source: `docs/VAMS-LRM/annex-e-spice.html`, read section by section.

HTML section-ID audit: `sE-1` `sE-1-1` `sE-1-2` `sE-2` `sE-2-1` `sE-2-2` `sE-2-2-1`
`sE-2-2-2` `sE-2-2-3` `sE-3` `sE-3-1` `sE-3-2` `sE-3-2-1` `sE-3-2-2` `sE-3-3` `sE-3-4`
`sE-4` `sE-4-1` `sE-4-2`, plus the two table anchors `table-e-1` and `table-e-2`.
Nineteen sections. Annex E is normative.

Forty fixtures live in this folder. `zig build torture -- annex_e_spice` reports
**9/40 behaving as they say they do and 31 `//! xfail`** — nothing fails. That ratio is
the headline and it has one cause: almost every sentence in this annex is about
*instantiating* something (a primitive, a model, a subcircuit, a paramset bin) inside a
Verilog-AMS module, and VerA is a flat single-module compiler that answers every
instantiation with **E0204, "module instantiation is not supported"**. Thirty of the
thirty-one xfails are that wall. The thirty-first is a `$limit()` arity check VerA writes
into a comment instead of a diagnostic.

### How a fixture that cannot elaborate still states a requirement

An `//! xfail` on a fixture that asserts nothing is worthless: the day E0204 goes away it
XPASSes by merely COMPILING, the marker is deleted, and no one has checked that the
`resistor` actually stamped 1 kΩ. So the fixtures here assert the ELECTRICAL requirement,
and the way in is **§6.7.1**, which is cited by thirteen of them:

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

Fourteen of the nineteen sections have at least one fixture. Of the five that do not,
three (`sE-1`, `sE-2-2`, `sE-4`) are prose or bare headings that state no rule; two
(`sE-1-1`, `sE-3-2-2`) are real gaps and are listed at the bottom.

| HTML id | Rule | Fixtures |
|---|---|---|
| `sE-1` | motivation for SPICE compatibility | none, and none is owed. The section states no requirement — it explains why the annex exists. No fixture carries `//! lrm E.1` |
| `sE-1-1` | if a tool reads a flavor of SPICE, anything instantiable in that flavor is instantiable in a module | **no fixture.** `spice_model.va` argues E.1.1 in its header prose but does not cite it on a `//! lrm` line. See the gap list — the rule is conditional on an implementation choice VerA has not made |
| `sE-1-2` | four axes of incompatibility; the testable one is "primitives **shall**, and parameters and ports **can**, be named", and Table E.1 fixes the names | 20 fixtures cite it: the 16 `primitive_bjt/capacitor/diode/iexp/inductor/ipulse/ipwl/isine/jfet/mesfet/tline/vccs/vcvs/vexp/vpulse/vpwl.va`, plus `passive_named_ports.va`, `spice_semiconductor_primitives.va`, `spice_source_primitives.va`, `primitive_named_ports.va`. **All `//! xfail`** — E0204. The last four now read every named parameter back through the instance (6.7.1) against its own literal, and write their named port lists in REVERSE Table E.1 order so a tool that silently connected by position moves a digit |
| `sE-2` | SPICE primitives behave like built-in primitives; models and subcircuits are treated as module definitions; all aspects implementation-dependent | `primitive_*.va` (the 16 above), `spice_model.va`, `spice_subcircuit.va`, `spice_network_primitives.va`, `spice_passive_primitives.va`. **All `//! xfail`** — E0204 |
| `sE-2-1` | exact-case match first; on no exact match, match the SPICE name regardless of case | `spice_case_lookup.va` — `VeRtNpN mixed_case(c1, b1, e1);`, with the three nets biased apart and the resolved object's `c`/`b`/`e` read back, so a successful fallback has to land on E.2.2.1's NPN and not merely on something. **`//! xfail`**: E0204, so the case-insensitive fallback is never attempted |
| `sE-2-2` | "This subsection shows some examples." | none, and none is owed — the heading carries no text of its own. The three numbered examples below it are each covered |
| `sE-2-2-1` | the `vertNPN` model instantiated by order (`Q1`) and by name (`Q2`), with the optional `s` port defaulted by omission | `spice_model.va` (`vertNPN q1(c1, b1, e1)` — ordered, three ports, `s` omitted) and `primitive_named_ports.va` (`bjt #(.area(2.0)) q1(.s(s1), .e(e1), .b(b1), .c(c1))` — named, and deliberately not in table order). Both **`//! xfail`** — E0204. The named form with `s` *omitted*, which is literally what `Q2` does, has no fixture |
| `sE-2-2-2` | subcircuit `ecpOsc` referenced from a module; instance name not constrained to start with `X` | `spice_subcircuit.va` — `ecpOsc osc1(out, gnd);`, and `osc1` is the NOTE's point. The `.SUBCKT ECPOSC (OUT GND)` interface is asserted: `V(osc1.out, osc1.gnd)` against a bias that makes a reversed ordered connection read the opposite sign. **`//! xfail`** — E0204 |
| `sE-2-2-3` | the `ecpOsc` body rewritten with native primitives: `vsine`, `isine`, `inductor`, `capacitor`, `resistor` | `primitive_capacitor.va`, `primitive_inductor.va`, `primitive_isine.va`, `passive_named_ports.va`, `spice_passive_primitives.va`, `spice_source_primitives.va` — one per primitive the example uses. **All `//! xfail`** — E0204. The example as a *whole module* is not reproduced anywhere |
| `sE-3` | Table E.1 names are required; connection by order follows the listed order; port default discipline `electrical`, direction `inout`; diode/bjt/mosfet/jfet/mesfet usable directly in a `paramset` | 26 fixtures cite it — the 16 `primitive_*.va`, the four `spice_*_primitives.va`, `passive_named_ports.va`, `primitive_named_ports.va`, the three `port_discipline` files, and `spice_binning.va` (whose `paramset annex_e_bin mosfet;` is the last paragraph's rule). **All `//! xfail`**. The ordering half now has digits behind it: `spice_passive_primitives.va` and `spice_network_primitives.va` bias their nets apart and read the primitive's own branch back, so a transposed positional list fails instead of elaborating quietly. Neither the `electrical` default nor the `inout` default is asserted by anything — see the gap list |
| `sE-3-1` | `ccvs`, `cccs` and mutual inductors are **not** supported, because instance names cannot be passed as parameters | `unsupported_ccvs.va`, `unsupported_cccs.va`, `unsupported_mutual_inductor.va` — all three `//! reject E0204`, all three **green**. Read the caveat below: the diagnostic is right for the wrong reason |
| `sE-3-2` | three-level precedence: `port_discipline` attribute, then resolution, then `electrical` | `primitive_discipline.va`, `primitive_mixed_discipline_override.va`. Both **`//! xfail`** — E0204. Level 1 is now observable through the ACCESS FUNCTIONS the resolved discipline supplies — `Theta`/`Tau` for `rotational`, `Omega` for `rotational_omega`, `V`/`I` for `electrical` — since a spelling that belongs to the wrong discipline does not type-check. Levels 2 and 3 stay unobservable while level 1 cannot compile |
| `sE-3-2-1` | `port_discipline` string attribute on a primitive instance, on a primitive port, or both; **ignored** on non-primitive modules and their ports | instance form: `primitive_discipline.va` (**`//! xfail`**). Port form: `primitive_port_discipline.va` (**`//! xfail`**). Combined form, the LRM's `vcvs` motor: `primitive_mixed_discipline_override.va` (**`//! xfail`**). The ignore-on-other-modules half: `port_discipline_ignored_on_module.va` — **green**, and the only sentence of E.3.2 that VerA currently meets. Nothing checks that the value must be a valid discipline of domain `continuous` |
| `sE-3-2-2` | with no attribute, take the discipline from `vpiLoConn` of other instances on the net segment; incompatible → 3.11 error; none continuous → `electrical` | **no fixture.** No file in this folder cites `E.3.2.2` on a `//! lrm` line or anywhere in prose |
| `sE-3-3` | an HDL module or paramset always wins over a SPICE object of the *exact* same name; a case-differing name does not interfere; a warning shall be issued | `spice_name_shadow.va` — **green**: a module actually *named* `resistor`, with `r` and `V(p,n)` read out of it, proving the Table E.1 name is not reserved. Its own header states how far that reaches: the harness compiles one `.va` with no companion SPICE netlist, so there is no second definition to be preferred over and no instantiation site to observe the preference at. `spice_case_lookup.va` covers the case-differing half and is **`//! xfail`** (E0204). The mandated warning has no fixture |
| `sE-3-4` | Table E.2 names `fetlim`, `pnjlim`, `vdslim` usable as the string argument of `$limit()` (9.17.3) | `limit_fet.va`, `limit_pnj.va`, `limit_vds.va` — all three **green**, all three `//! bias` with a `CHECK` on the returned value. Arity: `limit_fetlim_missing_vth.va` and `limit_pnjlim_missing_args.va`, both `//! reject DiagnosticsReported`, both **`//! xfail`** — VerA renders the arity complaint as a comment in the emitted device and exits 0 |
| `sE-4` | "This section highlights some other issues" | none, and none is owed |
| `sE-4-1` | multiplicity factor on module-defined subcircuits via `$mfactor` (6.3.6) | `mfactor_subcircuit.va` — **green**. Pins Table 9-29's top-level value, `$mfactor == 1.0` exactly, in a module declaring no parameters. Partial by construction: `$mfactor_specified * $mfactor_hier` needs a hierarchy, and the header says so |
| `sE-4-2` | binning and libraries; the Verilog-AMS analogue is several same-named `paramset`s selected by 6.4.2 | `spice_binning.va` — two `paramset annex_e_bin mosfet` blocks with disjoint `l` ranges and an instance at `l = 180n`. WHICH bin was selected is asserted, and that is the whole point of the clause: the two bins give `w` different defaults (1u, 2u) and the instance overrides only `l`, so `m1.w == 1e-6` holds if and only if 6.4.2 chose the first. **`//! xfail`**: the `paramset` declarations are read past and dropped and the instance is E0204, so no bin is ever selected |
| `table-e-1` | 19 primitive rows, each with its port names, parameter names and behavior | all 19 rows have a fixture — see the row map below. **All 19 are `//! xfail`.** The *Behavior* column is evaluated for exactly two rows: `resistor` in `spice_passive_primitives.va` (tc1 = tc2 = 0, so V = I·r·(1+tc1·T+tc2·T²) collapses to I = 1.0/1000 with no reading of T left open) and `vcvs` in `spice_network_primitives.va` (V(p,n) = gain·V(ps,ns) = 2.0·0.5), with `primitive_discipline.va` and `primitive_port_discipline.va` reading the resistor row in the rotational natures. The other 17 rows are unevaluated — see the gap list |
| `table-e-2` | `fetlim(vth)`, `pnjlim(vte, vcrit)`, `vdslim()` | `limit_fet.va`, `limit_pnj.va`, `limit_vds.va` — all three green. All three rows, including the "(none)" arity of `vdslim`, are spelled |

## Table E.1, row by row

Nineteen rows, nineteen fixtures, every port name and every parameter name of every row
written out in source. Every one is xfail.

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
down — and neither side compiles.

## The xfail ledger

Thirty-one of forty fixtures run and fail. Fourteen distinct reasons; the wording below
is the fixture's own `//! xfail` text.

| Reason | Sections it blocks | Fixtures (31) |
|---|---|---|
| VerA rejects module instantiation (E0204), so no Table E.1 primitive can be instantiated at all | `sE-3`, `sE-1-2`, `sE-2`, `table-e-1` | `primitive_bjt.va`, `primitive_capacitor.va`, `primitive_diode.va`, `primitive_iexp.va`, `primitive_inductor.va`, `primitive_ipulse.va`, `primitive_ipwl.va`, `primitive_isine.va`, `primitive_jfet.va`, `primitive_mesfet.va`, `primitive_tline.va`, `primitive_vccs.va`, `primitive_vcvs.va`, `primitive_vexp.va`, `primitive_vpulse.va`, `primitive_vpwl.va` (16) |
| E0204, so a named primitive connection cannot be reached | `sE-1-2`, `sE-2-2-1`, `sE-2-2-3`, `sE-3` | `primitive_named_ports.va`, `passive_named_ports.va` (2) |
| E0204, so an ordered primitive connection cannot be reached | `sE-3`, `sE-2`, `sE-2-2-3` | `spice_passive_primitives.va` |
| E0204, so a Table E.1 source primitive cannot be reached | `sE-3`, `sE-1-2`, `sE-2-2-3` | `spice_source_primitives.va` |
| E0204, so a Table E.1 controlled source cannot be reached | `sE-3`, `sE-2` | `spice_network_primitives.va` |
| E0204, so the Table E.1 mosfet row cannot be reached | `sE-3`, `sE-1-2` | `spice_semiconductor_primitives.va` |
| E0204, so a SPICE model cannot be instantiated | `sE-2-2-1`, `sE-2` | `spice_model.va` |
| E0204, so a SPICE subcircuit cannot be instantiated | `sE-2-2-2`, `sE-2` | `spice_subcircuit.va` |
| E0204, so the case-insensitive SPICE fallback is never attempted | `sE-2-1`, `sE-3-3` | `spice_case_lookup.va` |
| E0204, so a primitive carrying `port_discipline` cannot be reached | `sE-3-2-1`, `sE-3-2` | `primitive_discipline.va` |
| E0204, so a primitive port carrying `port_discipline` cannot be reached | `sE-3-2-1` | `primitive_port_discipline.va` |
| E0204, so the combined discipline override cannot be reached | `sE-3-2-1`, `sE-3-2` | `primitive_mixed_discipline_override.va` |
| VerA reads past a `paramset` declaration and drops it, and refuses module instantiation (E0204), so no bin is ever selected | `sE-4-2`, `sE-3` | `spice_binning.va` |
| VerA silently **declines** an under-supplied `$limit` — `cg_limit.zig` appends "too few arguments for the algorithm named" to a list rendered as a **comment** in the emitted device, and exits 0 with no diagnostic | `sE-3-4`, `table-e-2` | `limit_fetlim_missing_vth.va`, `limit_pnjlim_missing_args.va` (2) |

The `$limit` pair is the only debt in this folder that is *not* E0204, and it is the
only one a flat compiler could pay today: both fixtures probe an internal net rather than
a port precisely so that arity is the only thing left to object to. They ask for
`DiagnosticsReported` rather than a code because 9.17.3 fixes that this is an error and
not what a tool calls it.

## E.3.1 passes for the wrong reason

`unsupported_ccvs.va`, `unsupported_cccs.va` and `unsupported_mutual_inductor.va` are
green, and they are the only green fixtures in the E.1–E.3.3 range. They should not be
read as VerA implementing E.3.1. E0204 is "module instantiation is not supported" and
it fires on *every* instantiation in this folder — `resistor r1(p, n)` gets the same
diagnostic as `ccvs h1(p, n, sense, 2.0)`. The three fixtures are correct about the
outcome and say nothing about the reason. The day E0204 disappears these three become
the real test of E.3.1, and until then they are the annex's cheapest green.

Note also that the controlling-instance argument in both source-controlled fixtures is a
bare identifier `sense` with no declaration behind it — nothing in this folder builds a
real controlling branch, and nothing needs to while the instantiation itself is refused.

## What this annex needs that no fixture supplies

An empty cell above is a real gap, and these are the gaps:

- **E.1.1, the scope rule.** Nothing cites it. The sentence is guarded by "if a simulator
  which supports Verilog-AMS HDL is also able to read SPICE netlists of a particular
  flavor" — VerA reads no SPICE netlist, so the antecedent is false and the rule is
  vacuous rather than violated. That is a language boundary, not debt, but it should be
  written down rather than papered over with a fixture that cites `E.2` and hopes.
- **E.3.2.2 in full.** Discipline resolution from the net segment — the `vpiLoConn` scan,
  the compatibility test, the 3.11 error on incompatibility, the `electrical` default when
  no continuous discipline is present. Zero fixtures, zero cites. This is the largest
  single hole in the annex and it is not blocked by E0204 alone: it also needs the
  elaborated net segments that Annex F's fixtures are waiting on.
- **E.3's port defaults.** "The default discipline of the ports for these primitives shall
  be `electrical` and their descriptions shall be `inout`." Every fixture declares its own
  nets `electrical` and its own ports `inout` explicitly, so nothing would notice a tool
  that defaulted differently.
- **The Behavior column of Table E.1, seventeen rows of it.** Two rows are evaluated:
  `resistor` (`spice_passive_primitives.va`, and again in the rotational natures in the
  two `port_discipline` files) and `vcvs` (`spice_network_primitives.va`). The rest are
  not — the `iexp` piecewise exponential, the `ipulse`/`vpulse` five-segment waveform with
  its `t0..t4` definitions, the `ipwl`/`vpwl` interpolation, the fourteen-parameter AM/FM
  sine, the `capacitor`/`inductor` integrals, the `tline` (blank in the LRM anyway).
  Two reasons, and they are different. The `diode`/`bjt`/`mosfet`/`jfet`/`mesfet` rows
  have an EMPTY behavior column and E.2 makes them "implementation dependent", so there is
  nothing to evaluate and those fixtures assert port association and parameter binding
  instead. The source rows are blocked by the HARNESS: a `vsine`, `vexp`, `vpulse` or
  `vpwl` forces a potential, and a harness that imposes every unknown rather than solving
  reads back its own `//! bias` — the waveform needs a solver, not an operating point.
  The one temperature-dependent row that is left, `resistor` with nonzero tc1/tc2, is
  blocked by the LRM: the annex writes a bare `T` and fixes no reference temperature, so
  `passive_named_ports.va` deliberately asserts naming and not current.
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

Forty files, all mapped above: `limit_fet.va`, `limit_fetlim_missing_vth.va`,
`limit_pnj.va`, `limit_pnjlim_missing_args.va`, `limit_vds.va`, `mfactor_subcircuit.va`,
`passive_named_ports.va`, `port_discipline_ignored_on_module.va`,
`primitive_bjt.va`, `primitive_capacitor.va`, `primitive_diode.va`,
`primitive_discipline.va`, `primitive_iexp.va`, `primitive_inductor.va`,
`primitive_ipulse.va`, `primitive_ipwl.va`, `primitive_isine.va`, `primitive_jfet.va`,
`primitive_mesfet.va`, `primitive_mixed_discipline_override.va`,
`primitive_named_ports.va`, `primitive_port_discipline.va`,
`primitive_tline.va`, `primitive_vccs.va`, `primitive_vcvs.va`, `primitive_vexp.va`,
`primitive_vpulse.va`, `primitive_vpwl.va`, `spice_binning.va`,
`spice_case_lookup.va`, `spice_model.va`, `spice_name_shadow.va`,
`spice_network_primitives.va`, `spice_passive_primitives.va`,
`spice_semiconductor_primitives.va`, `spice_source_primitives.va`,
`spice_subcircuit.va`, `unsupported_cccs.va`, `unsupported_ccvs.va`,
`unsupported_mutual_inductor.va`.

Nineteen fixtures carry `//! bias`; none carries `//! analysis` or `//! temp`. Five carry
a `//! reject` line — three `E0204` (green) and two `DiagnosticsReported` (xfail).

Sixteen fixtures still assert nothing, and they are exactly the `primitive_*.va` row-map
set for the rows whose Behavior column is empty or whose value only a solver can produce.
They are not reported by a plain run — E0204 refuses them before a transcript exists — but
`zig build torture -- annex_e --strict` names every one. Closing that is the next piece of
work in this folder, and the pattern to copy is in `spice_passive_primitives.va`:
`//! bias`, then `6.7.1` out-of-module access to the primitive's own branch and parameters,
with the want derived from Table E.1.
