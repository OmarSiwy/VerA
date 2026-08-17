# Annex H coverage

Source: `docs/VAMS-LRM/annex-h-glossary.html`, read term by term.

HTML section-ID audit: `glossary-a` `glossary-b` `glossary-c` `glossary-f`
`glossary-i` `glossary-k` `glossary-l` `glossary-m` `glossary-n` `glossary-p`
`glossary-r` `glossary-s` `glossary-t` `glossary-v`. Fourteen letter sections
holding 38 terms, and **Annex H is informative**. That is the first thing to say
about it: a glossary defines vocabulary, it does not state conformance rules, so
a fixture here can only pin the *normative* clause a term points at. Every
fixture in this folder does exactly that — nine files, each carrying `//! lrm H`
plus the chapter cite that actually decides the number it asserts.
`08_reference_node.va` is the exception that proves it: "Nets declared as ground
shall be bound to the reference node" is the only `shall` in the whole annex,
and that fixture still leans on §3.6.4 for its normative footing.

**There are no `//! xfail` fixtures in this folder.** Nine files, nine expected
passes. That is not a claim that Annex H is fully met — it is a consequence of
how the folder was built: the two places where VerA demonstrably breaks a
glossary sentence are pinned in `ch01_intro/`, and two headers here point at
them rather than restating the claim, which would have turned green assertions
into an XFAIL verdict for a defect already written down. Those two are the
ledger below.

| HTML id | Terms | Fixtures |
|---|---|---|
| `glossary-a` | AMS | — a bare cross-reference to *Verilog-AMS*, no definition of its own. Nothing a source file can assert |
| `glossary-b` | behavioral description, behavioral model, block, branch | `01_behavioral_description.va` (§4.4, §5.7) — the *intermediate variables* half of the definition: `intermediate = 2.0*V(p,n)` must hold 1.0 at a 0.5 V bias before the contribution reads it. `02_behavioral_model.va` (§3.4, §2.6.2) — "a version of a module with a unique set of parameters", shown as `//! param resistance = 2k` overriding a 1k default, with the §2.6.2 `k` scale factor pinned at 2000 exactly. `03_block_control_flow.va` (§5.3) — one named `begin : constitutive_block`. `04_branch_flow_potential.va` (§3.12, §5.4.1) — a named `branch (p,n) b` alongside the unnamed pair, both required to read 0.5, which is the distinct-branches/same-potential claim and not an aliasing one |
| `glossary-c` | compact model, component, constitutive relationships, control flow, child module | `03_block_control_flow.va` (§5.8, §4.2.5) — the **conditional half only** of "control flow"; the file says so in its own header. `02_behavioral_model.va` — the constitutive relationship as an *assertion*, `V(p,n)/resistance` = 2.5e-4, not merely as a contribution. `09_nonlinear_nr_relationship.va` — the folder's only semiconductor device, hence the only thing here resembling a *compact model*, though no assertion claims that framing. **child module: no fixture** |
| `glossary-f` | flow | **No fixture asserts a flow.** All nine contribute one, and `05_module_parameter.va` asserts the *expression* `gain*V(p,n)` = 0.625 that its contribution then uses, but `I()` never appears outside the left of a `<+` anywhere in this folder. Deliberate: `04_branch_flow_potential.va`'s header explains that reading a flow back drags the file into the xfail below. (The previous revision credited `04` with "flow quantity"; `04` asserts three potentials and no flow.) |
| `glossary-i` | instance, instantiation | **No fixture.** Nothing here instantiates anything. `05_module_parameter.va`'s header is explicit that `//! param` is a *compilation-time* override under §3.4 and not the per-instance one this term defines, which is why its assertion reads "override" and not "instance override" |
| `glossary-k` | Kirchhoff's Laws | **No fixture asserts a conservation law.** `06_node_port_terminal.va` is the closest: its bias is a genuine solution of the module — the value source demands `V(internal_node,terminal_n)` = 0.1875, so the branch residual is zero rather than merely arithmetically consistent. That is one satisfied constitutive relation, not KCL and not KVL |
| `glossary-l` | level | `03_block_control_flow.va` (§5.3) — the `begin`-`end` half. The definition says "a pair of matching keywords **such as** `begin`-`end` **or** `discipline`-`enddiscipline`"; `discipline` occurs in no code line in this folder |
| `glossary-m` | model, module | "module": all nine files, each one definition of an interface plus behavior. "model" as the LRM means it — a named instance with its own parameter group, i.e. a netlist model card — **has no fixture**. `02_behavioral_model.va` is named for the *behavioral model* of `glossary-b` and is a compile-time override, not a model card |
| `glossary-n` | nesting level, node, node declaration, NR method | "node": `06_node_port_terminal.va` (§3.6, §4.4) — `internal_node` is in no port list yet is a solver unknown `V()` can read, at 0.1875 rather than either terminal's value, so a compiler that aliased it onto a port is caught. "node declaration": the same file's local `electrical internal_node;`, and `08_reference_node.va`'s `ground g1; ground g2;`. "NR method": `09_nonlinear_nr_relationship.va` (§9.15, §4.5.13, D.2) pins the *nonlinear relationship* — `$vt` at 300 K and the diode law at 100 mV, both `CHECKR` — while `limexp` stays in the contribution where §4.5.13 wants it. **The method itself is not observable from source and has no fixture.** **nesting level: no fixture** — `03` has exactly one `begin`-`end`, nothing nested inside it |
| `glossary-p` | parameter, parameter declaration, port, potential, primitive, probe | "parameter" / "parameter declaration": `05_module_parameter.va` (§3.4) and `02_behavioral_model.va`, both asserting the overridden value replaces the declared default. "port": `06_node_port_terminal.va`. "potential": `01`, `04`, `06`, `07`, `08` — every `V()` assertion in the folder. "probe": `07_probe.va` (§1.3.1, §5.4.2.1) — the **potential half only**, and the header argues why: §5.4.2.1 makes using both quantities of one probe branch illegal, so one fixture pins one half. **primitive: no fixture** |
| `glossary-r` | reference direction, reference node, run time binding | "reference direction": `04_branch_flow_potential.va` (§4.4, §5.4.1) — the **value half**, `V(n,p)` = -0.5 against `V(p,n)` = 0.5. The definition also covers the flow through a branch; that half is the xfail below and lives in `ch01_intro/`. "reference node": `08_reference_node.va` (§3.6.4) — two `ground` declarations with both nets biased *off* zero, so `V(g1,g2)` = 0 and both `V(p,g*)` = 0.5 only if the compiler binds them to the one global node, and the one-argument `V(p)` is checked to agree. **run time binding: no fixture** |
| `glossary-s` | scope, structural definitions | "scope": `03_block_control_flow.va` — one named block, with `result` surviving the rejoin of the `if`/`else` arms at 0.4. **structural definitions: no fixture**, same cause as `glossary-i` |
| `glossary-t` | terminal | `06_node_port_terminal.va` — a cross-reference to *port*, and the fixture names its ports `terminal_p`/`terminal_n` for it |
| `glossary-v` | Verilog-A, Verilog-AMS | — language-scope definitions naming the standard itself. Nothing a source file can assert |

Fixture-name audit, 9 files, all mapped above:
`01_behavioral_description.va`, `02_behavioral_model.va`,
`03_block_control_flow.va`, `04_branch_flow_potential.va`,
`05_module_parameter.va`, `06_node_port_terminal.va`, `07_probe.va`,
`08_reference_node.va`, `09_nonlinear_nr_relationship.va`.

Nine covered sections, five uncovered: `glossary-a`, `glossary-f`, `glossary-i`,
`glossary-k`, `glossary-v`. Two of those five — `a` and `v` — are a
cross-reference and two language-scope definitions, with no testable content at
all; the other three are real gaps and are itemised below.

## The xfail ledger, which lives elsewhere

Zero fixtures in this folder are `//! xfail`. The two glossary sentences VerA
does not meet are pinned in `ch01_intro/`, and both are cited by name from the
headers here.

| Glossary term | Fixture carrying the xfail | Reason |
|---|---|---|
| `glossary-r` reference direction, the *flow through a branch* half | `ch01_intro/23_flow_antisymmetry.va` | VerA mints a **second** unknown, `flowZ28nZ2cpZ29`, for the reversed terminal order instead of negating the branch flow, so `I(n,p)` reads 0 rather than `-I(p,n)`. Cited in `04_branch_flow_potential.va`, which asserts only the potential half for this reason |
| `glossary-p` probe, the *"potential **or** flow"* disjunction | `ch01_intro/20_probe_branch_both_quantities.va` (`//! reject DiagnosticsReported`) | `lower.zig` never correlates the two accesses of an uncontributed node pair: `V(prb)` and `I(prb)` are lowered independently, so nothing observes that both quantities of one probe branch were read. Both `vera --lint` and `--emit-zig` exit 0 on source §5.4.2.1 calls illegal. Cited in `07_probe.va`, which pins the potential half only |

The flow half of *probe* is `ch01_intro/10_flow_probe.va` and is not xfail.

## What this annex needs that no fixture supplies

An empty cell above is a real gap, and these are the gaps:

- **`glossary-i` instance and instantiation, `glossary-c` child module,
  `glossary-s` structural definitions, `glossary-m` model.** Four terms, one
  cause: nothing in this folder instantiates a module. The entire vocabulary of
  hierarchy — instance, submodule, model card, structural definition — is
  unexercised here. VerA elaborates a hierarchy now (`ir/elaborate.zig`), so this
  is a fixture gap and no longer a compiler one, and the fixtures themselves
  belong in `ch06_hierarchy/` regardless. The note here is only that
  Annex H's hierarchy vocabulary has no representative in its own folder.
- **`glossary-f` flow, as a value read back.** Nine contributions, zero
  assertions. Reading `I()` in an expression is what makes a branch a *flow
  probe* under §5.4.2.1, and doing it here collides with the antisymmetry xfail.
  The term is demonstrated only as the left side of a `<+`.
- **`glossary-k` Kirchhoff's Laws.** No fixture sums flows at a node or values
  around a loop. The laws are induced by every contribution here and asserted by
  none of them.
- **`glossary-c` control flow, the iterative half.** The definition says
  "conditional **and** iterative". Only the conditional is here;
  `ch05_analog_behavior/for_loop.va`, `while_loop.va`, `repeat_loop.va` and
  `analog_genvar_loop.va` carry the other half, and `03_block_control_flow.va`
  names them. No `for`, `while` or `repeat` appears in any code line in this
  folder.
- **`glossary-l` level and `glossary-n` nesting level, the
  `discipline`-`enddiscipline` half.** Both terms define a level as a pair of
  matching keywords "such as `begin`-`end` **or** `discipline`-`enddiscipline`".
  Neither `discipline` nor `nature` occurs in any code line here; that form is
  §3.6/§7 and lives in `ch03_data_types/`.
- **`glossary-n` nesting level, as actual nesting.** `03_block_control_flow.va`
  has one `begin`-`end`. Nothing here nests a block inside a block, so the
  distinction between *level* and *nesting level* — the only thing separating
  two otherwise word-for-word identical definitions — is not observable.
- **`glossary-n` NR method.** Newton-Raphson is a solver strategy, not source
  syntax. `09_nonlinear_nr_relationship.va` pins the nonlinear relationship it
  operates on and is careful not to claim more: its header explains at length
  why no pointwise want is written on `limexp` at all, since §4.5.13 makes the
  `limexp` = `exp` identity a property of the *converged* point while the runner
  evaluates the residual once, cold.
- **`glossary-p` primitive** and **`glossary-r` run time binding.** Both are
  simulator-implementation notions. "The conditional introduction and removal of
  value and flow sources during a simulation" is what §5.6.4 switch branches do;
  nothing in this folder switches a branch between the value and flow forms.

## Shape of the folder

All nine are dc: nine `//! bias` lines, no `//! analysis`, one `//! temp 300.0`
on `09_nonlinear_nr_relationship.va`. Two carry a `//! param` override
(`02`, `05`). No `//! reject` and no `.expected-error.txt` — the glossary states
no rule a source file can violate, so there is nothing here for a compiler to
refuse.

Eighteen of the twenty-one assertions are `CHECKX` on exact binary64 values and
the headers justify that individually rather than assuming it —
`02_behavioral_model.va` argues that 0.5/2000.0 lands on the same double the
literal `2.5e-4` parses to, because both operands are exact and IEEE-754
division is correctly rounded. One is `CHECKI`, on a comparison result that
§4.2.5 makes an integer. Only `09_nonlinear_nr_relationship.va` uses `CHECKR`,
and only because Annex D offers four constant sets (plus VerA's NIST2018
default) and a conforming compiler may pick any of them; its two tolerances are
the next round number above the worst-case relative error across that window,
not round numbers chosen for comfort.
