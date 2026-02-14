# Chapter 1 coverage

## Source-review correction (2026-09-23)

This correction supersedes the historical counts, blanket green claims and
`DiagnosticsReported` rationale below. Source: complete AMS Chapter 1,
printed pages 1–10 / physical PDF pages 14–23; see
[the review register](../../../docs/conformance-introduction-review.md).

- `lrm_1_2.va` now exists: a narrow initial-to-analog value-transfer assertion,
  not evidence for every mixed-context access and contribution rule.
- `lrm_1_3.va` now exists and instantiates a child. It checks one all-analog
  port connection; mixed-signal and arbitrary interspersed hierarchy remain open.
- `20_probe_branch_both_quantities.va` belongs to §5.4.2.1, not a quotation
  from §1.3.1. Its withdrawn claim is retained as INTRO-PROBE-001.
  The source-branch simultaneous-source restriction is §5.4.2.2; that clause
  permits switching source kind, so merely containing both contributions is
  not sufficient to derive an invalid fixture.
- Rejection rows 14, 17, 18, 19, 20 and 22 now match the observed rule-specific
  diagnostic text. Direct checks reject each for its intended rule; corresponding
  one-change legal controls compile. This is diagnostic-isolation evidence, not
  positive runtime closure.
- The absence of a node-level KFL oracle in the historical fixture `04`
  remains important. Contribution accumulation is not node conservation.
- Figure and syntax-color repairs improve source fidelity, not measured A/C.

## Historical ledger (not a current suite measurement)

Source: `docs/ch1-intro.html`, read section by section against the 25 `.va` files
actually in this directory.

HTML section-ID audit: `s1-1` `s1-2` `s1-3` `s1-3-1` `s1-3-1-1` `s1-3-1-2` `s1-3-2` `s1-3-3`
`s1-3-4` `s1-3-4-1` `s1-3-4-2` `s1-3-5` `s1-4` `s1-5`.

Eight of the fourteen carry a normative rule this suite executes. Three (`s1-1`, `s1-4`,
`s1-5`) state no rule. Three (`s1-2`, `s1-3`, `s1-3-3`) state rules this chapter's fixtures do
not reach; they are listed with their disposition and nothing is credited to them.

25 `.va` files: 8 carry a `//! reject` arm, 17 run and assert, and NONE is `//! xfail`
(grep-measured over this directory). The signal-flow half of the chapter — every clause of
§1.3.4, §1.3.4.1, §1.3.4.2 and §1.3.5 — was xfail in its entirety and is now green; so are
the two §1.3.1/§1.3.1.2 rows and the §1.3.5 read rule. The ledger below records which
defect closed each row and the code that landed, and every one of its fourteen lines is now
struck. This paragraph used to warn that rows still reading **xfail** were stale; they were,
and they are corrected here.

| LRM section/rule | Fixture or disposition |
|---|---|
| 1.1 overview: conservative and signal-flow descriptions over nets/nodes/branches/ports | descriptive prose, no normative rule; the terms it introduces are executed by the §1.3 rows |
| 1.2 analog potentials and flows receive contributions only inside an `analog` block | **no fixture here.** Every `<+` in this folder is inside `analog`, but nothing places one *outside* one, so the rule is never tested; the whole list in 1.2 is mixed-signal and belongs to `ch07_mixed_signal` |
| 1.3 signal/port/node terminology; one node per analog-or-mixed signal regardless of net count | **no fixture.** Needs instantiation and port connection to be observable; no fixture in this directory instantiates anything. `ch06_hierarchy` territory |
| 1.3.1 two values per node; branch potential is the node difference | `01_conservative_resistor.va` (V(p,n) = 1.25, Ohm's law over the `//! param` override), `05_potential_and_flow.va` (the mirror: flow probed, potential contributed), `09_potential_probe.va` (probe drives a source in another branch) |
| 1.3.1 probe/source approach; source-branch flow readable | `07_current_source.va` (the retained 1 mA read back at all three sweep points, so the source value does not drift with the bias), `04_kirchhoff_flow_sum.va` (two flow contributions read back as their sum, 1.4 mA); `10_flow_probe.va` (named-branch flow probe, plus the alias claim `I(measured) == I(p,n)`) |
| 1.3.1 "the potential and flow of a probe branch may not both appear in expressions" | `20_probe_branch_both_quantities.va` — green, **E0423**: the two accesses of one uncontributed node pair are correlated now, so probing both quantities of a probe branch is diagnosed instead of silently lowered |
| 1.3.1 "nor is it allowed to specify both the potential and flow of a source branch" | **no fixture here.** `ch05_analog_behavior/source_probe_both.va` is the near-miss and is *legal*; the illegal double-source form is uncovered |
| 1.3.1 a probed branch flow forces the branch potential to zero | **no fixture.** Requires observing a forced residual the runner cannot inspect |
| 1.3.1.1 the reference node is always zero; any continuous net can be `ground` | `02_reference_ground.va` (gnd biased to 3.0 and asserted 0 anyway — the bias is what makes it a test), `24_two_ground_nets.va` (two `ground` nets are one global node), `26_ground_non_electrical.va` (`thermal`/`Temp`/`Pwr`: `ground` is not electrical-specific) |
| 1.3.1.2 associated reference directions, potential half | `03_named_branch.va` (`branch (a,b)`; V(b,a) == -V(a,b)), `06_voltage_source.va` (V(n,p) == -V(p,n)) |
| 1.3.1.2 associated reference directions, flow half | `23_flow_antisymmetry.va` — green: the reversed terminal order negates the one branch-flow unknown instead of minting a second, so `I(n,p) == -I(p,n)` |
| 1.3.2 KPL: algebraic sum of branch potentials around a loop is zero | `08_series_potentials.va` (two branches traversed the same way — telescoping), `25_kpl_loop.va` (Figure 1-3's signed four-branch sum, two branches declared reversed, so a dropped sign moves the total by 1.5) |
| 1.3.2 KFL: algebraic sum of flows out of a node is zero | **no fixture.** `04_kirchhoff_flow_sum.va` is named for it and is *not* it — its header disowns the claim; it pins §5.6.1.3 contribution accumulation onto one branch. Node-level flow conservation is a solver property with no probe in this harness |
| 1.3.2 constitutive relationships | `01_conservative_resistor.va` (cites 1.3.2 for the flow the branch equation produces) |
| 1.3.3 natures, disciplines, nets; access-function names; compatibility rules | **no fixture here.** No file in this directory declares a `nature` or a `discipline`; all four disciplines used (`electrical`, `voltage`, `current`, `thermal`) are Annex D's. Declaration syntax and compatibility are `ch03_data_types` |
| 1.3.4 flow contribution to a potential-only node is illegal | `14_signal_flow_illegal_quantity.va` — green, **E0501**: `checkAccessMatch`'s `want.len == 0` early return became a diagnostic arm, so a discipline binding no flow nature refuses every flow access |
| 1.3.4 potential contribution to a flow-only node is illegal (the "conversely" half) | `19_potential_contribution_to_flow_only.va` — green, **E0501**, the mirrored half of the same arm |
| 1.3.4.1 `shiftPlus5`, the clause's own worked example | `11_potential_signal_flow.va` (V(out) reads the 6.25 the source imposes: `//! bias V(in)` is what the `input` means and `//! solve` is what the `output` means) |
| 1.3.4.1 potential signal-flow nets may not bind to `inout` ports | `15_sf_potential_on_inout.va` (E0360, `lower.zig` below the net loop — the first point at which both the direction and the discipline are known) |
| 1.3.4.1 potential contributions may not be made to `input` ports | `17_sf_potential_contribution_to_input.va` — green, **E0425**: the front end distinguishes an `input` from an `output` contribution target now, so the refusal is a named rule at the contribution rather than a generic codegen failure |
| 1.3.4.1 a potential signal-flow net bound to a conservative node behaves as a voltage source to ground | **no fixture.** Needs instantiation across a discipline boundary; `ch07_mixed_signal`/`annex_f_resolution` territory |
| 1.3.4.2 `currmir`, the clause's own worked example | `12_flow_signal_flow.va` (I(out) reads the mirrored -0.125; `//! bias I(in)` now binds the §5.4.2 flow unknown and not the node) |
| 1.3.4.2 flow signal-flow nets may not bind to `inout` ports | `16_sf_flow_on_inout.va` (E0360, the flow-only half of the same rule) |
| 1.3.4.2 flow contributions may not be made to `input` ports | `18_sf_flow_contribution_to_input.va` — green, **E0425**, the flow half of the same check |
| 1.3.4.2 a flow signal-flow net bound to a conservative node behaves as a current source | **no fixture.** Same instantiation requirement as the 1.3.4.1 row above |
| 1.3.5 conservative and signal-flow components can be freely mixed | `13_mixed_conservative_signal_flow.va` (conservative `a`/`b` stated by the host, signal-flow `out` solved for: V(out) = 20.0 and the retained I(a,b) = 2.0e-3 in one module) |
| 1.3.5 only signal types declared on the ports are accessible in the body | `22_undeclared_quantity_read.va` — green, **E0501**: the READ side of the same arm, so `I(vonly)` is refused |
| 1.3.5 nets used only structurally need no natures | **no fixture.** Requires instances; nothing here instantiates |
| 1.4 BNF notation conventions | documentation convention, no rule to execute; the productions themselves are `annex_a_syntax` |
| 1.5 contents | index only, no rule |

## The xfail ledger

EMPTY — grep finds no `//! xfail` in this directory. It held fourteen rows over nine
distinct defects, grouped by root cause so that closing one line closed every fixture on
it; all nine are closed and the grouping is kept as the record of which line each was on:

| Defect | Fixtures | Where |
|---|---|---|
| ~~codegen refuses any contribution to a single-nature directional port~~ CLOSED | `11`, `12`, `13` | the `signalFlowNet` refusal is gone. §1.3.4.1's potential-only net needed no special case — the ordinary branch relation reduces to it, the KCL row at the net being `ib = 0` — and §1.3.4.2's flow-only net gets `codegen.zig flowOnlySignalFlowNet`: the node's one unknown IS its flow, so the row is `x[n] − c` and not a KCL injection |
| ~~a discipline binding no nature for a quantity accepts every access to it, read or write~~ CLOSED | `14`, `19`, `22` | `lower.zig checkAccessMatch`: the `if (want.len == 0) return;` is an E0501 arm whose note reads "binds no *half* nature, so *net* has no *half* to access". §4.4's generic `potential()`/`flow()` are exempt from the name match only and still go through it |
| ~~nothing rejects declaring a single-nature discipline on an `inout` port~~ CLOSED | `15`, `16` | E0360, in `lower.zig` after the net loop and the §10.2 defaults — `inout p; voltage p;` splits the direction and the discipline across two declarations, so the port loop cannot ask the question |
| ~~no front-end diagnostic distinguishes an `input` from an `output` contribution target~~ CLOSED | `17`, `18` | E0425, at the contribution. Neither fixture pins `GeneratedCompileError`, which is why closing it needed no fixture edit |
| ~~the two quantities of one probe branch are never correlated~~ CLOSED | `20` | E0423 |
| ~~reversed terminal order mints a second branch-flow unknown instead of negating~~ CLOSED | `23` | one unknown per node pair, negated on the reversed read |
| ~~the testbench forces every node unknown to its bias rather than solving~~ CLOSED | `11`, `13` | `tb.zig` runs a real Newton-Raphson; `//! solve` says which unknowns are the device's to determine. A POTENTIAL read is the node difference (§5.4.1) and has no retained value to substitute, which is why this one needed the solver and the flow-source read did not |
| ~~a port flow is not expressible as a precondition~~ CLOSED | `12` | `tb.zig unknownName` maps `I(a)` to `flow(a,gnd)`, `I(a,b)` to `flow(a,b)` and `I(<a>)` to `flow(<a>)` — §5.4.2/§5.4.3's own unknowns — instead of stripping to the node's potential |

The previous defense of generic `DiagnosticsReported` matching has been
withdrawn. Codes and rule-specific messages now exist and were reproduced.
Rows 15/16 already use E0360; six other rejection fixtures are tightened by the
2026-09-23 review. An unrelated rejection must not count as evidence.

## Structural notes

**Numbering.** There is no `21_*.va`; the gap is real, not a missing file listing.

**Three unportable fixtures, and the runner change that unblocked them.**
`05_potential_and_flow.va`, `10_flow_probe.va` and `23_flow_antisymmetry.va` sweep the
branch-flow unknown by its mangled codegen spelling, `//! sweep flowZ28pZ2cnZ29 = …`. That
name has no basis in the LRM, and it was never `xfail` — xfail means VerA fails the fixture,
and VerA passes; it is other compilers the spelling locks out. The fix named here was a
runner change, not a fixture change, and **it landed**: `tb.zig unknownName` takes `I(p,n)`,
`I(a)` and `I(<a>)` and maps them onto §5.4.2/§5.4.3's own unknowns. So the three files are
now writing a spelling they no longer need. Grep counts **17 fixtures across five folders**
still on the mangled form (`ch01_intro` ×3, `ch04_expressions/34`, `ch05_analog_behavior` ×9,
`ch06_hierarchy/mfactor_flow_probe.va`, `ch11_vpi` ×3); rewriting them is behaviour-neutral
portability work, not a conformance change, which is why no wave has spent a fixture edit on
it. `26_ground_non_electrical.va` rests on the adjacent undocumented form: bare net names in
`//! bias`, the only spelling that works for a non-electrical access.

**Filename that lies.** `04_kirchhoff_flow_sum.va` tests §5.6.1.3 contribution accumulation
onto one branch, not KFL. Its header says so in full. It is credited to §5.6.1.3 above and to
nothing in §1.3.2.

**Ground is covered four times over.** `02` (one ground, biased away from zero), `24` (two
grounds are one node), `26` (thermal, so a compiler special-casing `electrical` fails), and
outside this chapter `annex_h_glossary/08_reference_node.va` and `ch03_data_types/13`. `24`
is not the only plural-ground test in the tree; the Annex H file predates it.

**Assertions read back, they do not retype.** Every fixture here asserts a value the compiler
computed, not the right-hand side of a nearby `<+` restated. That was not true of the previous
generation of these files: several asserted expressions arithmetically derived from the line
above, and passed on compilers that dropped the contribution entirely. Where a plumbing read
is kept (`04` line 45, `05` line 48, `09` line 21) the header says it is plumbing.

**CHECKX unless the arithmetic is inexact.** `09_potential_probe.va` is the chapter's only
`CHECK` with a tolerance, and its header marks the tolerance load-bearing: 0.8-0.1 is one ulp
above `double(0.7)`. Do not promote it in a chapter-wide sweep.
