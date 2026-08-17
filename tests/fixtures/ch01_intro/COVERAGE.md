# Chapter 1 coverage

Source: `docs/VAMS-LRM/ch1-intro.html`, read section by section against the 25 `.va` files
actually in this directory.

HTML section-ID audit: `s1-1` `s1-2` `s1-3` `s1-3-1` `s1-3-1-1` `s1-3-1-2` `s1-3-2` `s1-3-3`
`s1-3-4` `s1-3-4-1` `s1-3-4-2` `s1-3-5` `s1-4` `s1-5`.

Eight of the fourteen carry a normative rule this suite executes. Three (`s1-1`, `s1-4`,
`s1-5`) state no rule. Three (`s1-2`, `s1-3`, `s1-3-3`) state rules this chapter's fixtures do
not reach; they are listed with their disposition and nothing is credited to them.

No fixture in this directory is `//! xfail` any more (`grep -l '^//! xfail' *.va` is empty).
The signal-flow half of the chapter — every clause of §1.3.4, §1.3.4.1, §1.3.4.2 and §1.3.5 —
was xfail in its entirety, and the ledger below the table now records what closed those and
where. Rows and ledger lines still reading **xfail** are stale in the other direction: the
fixture passes and the row has not caught up. Only the four signal-flow defects were this
change's to close, so only those are struck through; the rest wait on the scheduled re-census.

| LRM section/rule | Fixture or disposition |
|---|---|
| 1.1 overview: conservative and signal-flow descriptions over nets/nodes/branches/ports | descriptive prose, no normative rule; the terms it introduces are executed by the §1.3 rows |
| 1.2 analog potentials and flows receive contributions only inside an `analog` block | **no fixture here.** Every `<+` in this folder is inside `analog`, but nothing places one *outside* one, so the rule is never tested; the whole list in 1.2 is mixed-signal and belongs to `ch07_mixed_signal` |
| 1.3 signal/port/node terminology; one node per analog-or-mixed signal regardless of net count | **no fixture.** Needs instantiation and port connection to be observable; no fixture in this directory instantiates anything. `ch06_hierarchy` territory |
| 1.3.1 two values per node; branch potential is the node difference | `01_conservative_resistor.va` (V(p,n) = 1.25, Ohm's law over the `//! param` override), `05_potential_and_flow.va` (the mirror: flow probed, potential contributed), `09_potential_probe.va` (probe drives a source in another branch) |
| 1.3.1 probe/source approach; source-branch flow readable | `07_current_source.va` (the retained 1 mA read back at all three sweep points, so the source value does not drift with the bias), `04_kirchhoff_flow_sum.va` (two flow contributions read back as their sum, 1.4 mA); `10_flow_probe.va` (named-branch flow probe, plus the alias claim `I(measured) == I(p,n)`) |
| 1.3.1 "the potential and flow of a probe branch may not both appear in expressions" | `20_probe_branch_both_quantities.va` **xfail** — the two accesses of an uncontributed node pair are lowered independently and never correlated; lint and `--emit-zig` both exit 0 |
| 1.3.1 "nor is it allowed to specify both the potential and flow of a source branch" | **no fixture here.** `ch05_analog_behavior/source_probe_both.va` is the near-miss and is *legal*; the illegal double-source form is uncovered |
| 1.3.1 a probed branch flow forces the branch potential to zero | **no fixture.** Requires observing a forced residual the runner cannot inspect |
| 1.3.1.1 the reference node is always zero; any continuous net can be `ground` | `02_reference_ground.va` (gnd biased to 3.0 and asserted 0 anyway — the bias is what makes it a test), `24_two_ground_nets.va` (two `ground` nets are one global node), `26_ground_non_electrical.va` (`thermal`/`Temp`/`Pwr`: `ground` is not electrical-specific) |
| 1.3.1.2 associated reference directions, potential half | `03_named_branch.va` (`branch (a,b)`; V(b,a) == -V(a,b)), `06_voltage_source.va` (V(n,p) == -V(p,n)) |
| 1.3.1.2 associated reference directions, flow half | `23_flow_antisymmetry.va` **xfail** — VerA mints a second unknown `flowZ28nZ2cpZ29` for the reversed terminal order instead of negating, so I(n,p) reads 0 |
| 1.3.2 KPL: algebraic sum of branch potentials around a loop is zero | `08_series_potentials.va` (two branches traversed the same way — telescoping), `25_kpl_loop.va` (Figure 1-3's signed four-branch sum, two branches declared reversed, so a dropped sign moves the total by 1.5) |
| 1.3.2 KFL: algebraic sum of flows out of a node is zero | **no fixture.** `04_kirchhoff_flow_sum.va` is named for it and is *not* it — its header disowns the claim; it pins §5.6.1.3 contribution accumulation onto one branch. Node-level flow conservation is a solver property with no probe in this harness |
| 1.3.2 constitutive relationships | `01_conservative_resistor.va` (cites 1.3.2 for the flow the branch equation produces) |
| 1.3.3 natures, disciplines, nets; access-function names; compatibility rules | **no fixture here.** No file in this directory declares a `nature` or a `discipline`; all four disciplines used (`electrical`, `voltage`, `current`, `thermal`) are Annex D's. Declaration syntax and compatibility are `ch03_data_types` |
| 1.3.4 flow contribution to a potential-only node is illegal | `14_signal_flow_illegal_quantity.va` **xfail** — `checkAccessMatch` returns early on `want.len == 0`, so a discipline binding no flow nature accepts every flow access silently |
| 1.3.4 potential contribution to a flow-only node is illegal (the "conversely" half) | `19_potential_contribution_to_flow_only.va` **xfail** — same `want.len == 0` early return, mirrored; module lints *and* emits clean |
| 1.3.4.1 `shiftPlus5`, the clause's own worked example | `11_potential_signal_flow.va` (V(out) reads the 6.25 the source imposes: `//! bias V(in)` is what the `input` means and `//! solve` is what the `output` means) |
| 1.3.4.1 potential signal-flow nets may not bind to `inout` ports | `15_sf_potential_on_inout.va` (E0360, `lower.zig` below the net loop — the first point at which both the direction and the discipline are known) |
| 1.3.4.1 potential contributions may not be made to `input` ports | `17_sf_potential_contribution_to_input.va` **xfail** — no front-end diagnostic distinguishes an input from an output contribution target; `--lint` is silent and only codegen refuses, generically |
| 1.3.4.1 a potential signal-flow net bound to a conservative node behaves as a voltage source to ground | **no fixture.** Needs instantiation across a discipline boundary; `ch07_mixed_signal`/`annex_f_resolution` territory |
| 1.3.4.2 `currmir`, the clause's own worked example | `12_flow_signal_flow.va` (I(out) reads the mirrored -0.125; `//! bias I(in)` now binds the §5.4.2 flow unknown and not the node) |
| 1.3.4.2 flow signal-flow nets may not bind to `inout` ports | `16_sf_flow_on_inout.va` (E0360, the flow-only half of the same rule) |
| 1.3.4.2 flow contributions may not be made to `input` ports | `18_sf_flow_contribution_to_input.va` **xfail** — same missing front-end direction check as 17 |
| 1.3.4.2 a flow signal-flow net bound to a conservative node behaves as a current source | **no fixture.** Same instantiation requirement as the 1.3.4.1 row above |
| 1.3.5 conservative and signal-flow components can be freely mixed | `13_mixed_conservative_signal_flow.va` (conservative `a`/`b` stated by the host, signal-flow `out` solved for: V(out) = 20.0 and the retained I(a,b) = 2.0e-3 in one module) |
| 1.3.5 only signal types declared on the ports are accessible in the body | `22_undeclared_quantity_read.va` **xfail** — the read side of the rule; `checkAccessMatch`'s `want.len == 0` early return makes `I(vonly)` silent |
| 1.3.5 nets used only structurally need no natures | **no fixture.** Requires instances; nothing here instantiates |
| 1.4 BNF notation conventions | documentation convention, no rule to execute; the productions themselves are `annex_a_syntax` |
| 1.5 contents | index only, no rule |

## The xfail ledger

Fourteen xfails, but only nine distinct defects. Grouped by root cause, so closing one line
closes every fixture on it:

| Defect | Fixtures | Where |
|---|---|---|
| ~~codegen refuses any contribution to a single-nature directional port~~ CLOSED | `11`, `12`, `13` | the `signalFlowNet` refusal is gone. §1.3.4.1's potential-only net needed no special case — the ordinary branch relation reduces to it, the KCL row at the net being `ib = 0` — and §1.3.4.2's flow-only net gets `codegen.zig flowOnlySignalFlowNet`: the node's one unknown IS its flow, so the row is `x[n] − c` and not a KCL injection |
| a discipline binding no nature for a quantity accepts every access to it, read or write | `14`, `19`, `22` | `lower.zig checkAccessMatch`, `if (want.len == 0 …) return;` |
| ~~nothing rejects declaring a single-nature discipline on an `inout` port~~ CLOSED | `15`, `16` | E0360, in `lower.zig` after the net loop and the §10.2 defaults — `inout p; voltage p;` splits the direction and the discipline across two declarations, so the port loop cannot ask the question |
| no front-end diagnostic distinguishes an `input` from an `output` contribution target | `17`, `18` | only codegen refuses, and generically — which is why neither pins `GeneratedCompileError` |
| the two quantities of one probe branch are never correlated | `20` | `V(prb)` and `I(prb)` lowered independently; lint and emit both exit 0 |
| reversed terminal order mints a second branch-flow unknown instead of negating | `23` | `flowZ28nZ2cpZ29` alongside `flowZ28pZ2cnZ29` |
| ~~the testbench forces every node unknown to its bias rather than solving~~ CLOSED | `11`, `13` | `tb.zig` runs a real Newton-Raphson; `//! solve` says which unknowns are the device's to determine. A POTENTIAL read is the node difference (§5.4.1) and has no retained value to substitute, which is why this one needed the solver and the flow-source read did not |
| ~~a port flow is not expressible as a precondition~~ CLOSED | `12` | `tb.zig unknownName` maps `I(a)` to `flow(a,gnd)`, `I(a,b)` to `flow(a,b)` and `I(<a>)` to `flow(<a>)` — §5.4.2/§5.4.3's own unknowns — instead of stripping to the node's potential |

Eight of the fourteen are `//! reject DiagnosticsReported` (`14`–`20`, `22`). None pins a
numeric code, deliberately: the codes previously written here — E0337, E0423, E0424 — are
unallocated (`src/diag_code.zig` stops at E0336 for class 3 and E0422 for class 4), so a
diagnostic VerA can emit could never have matched and the XPASS could never have fired. The
phase label matches whichever code each rule eventually gets. E0501 is specifically *wrong*
for the `checkAccessMatch` group: it is §3.6.1.4's access-function name *mismatch*, and these
disciplines bind no nature to mismatch against.

## Structural notes

**Numbering.** There is no `21_*.va`; the gap is real, not a missing file listing.

**Three unportable fixtures.** `05_potential_and_flow.va`, `10_flow_probe.va` and
`23_flow_antisymmetry.va` sweep the branch-flow unknown by its mangled codegen spelling,
`//! sweep flowZ28pZ2cnZ29 = …`. That name has no basis in the LRM. It is not marked `xfail` —
xfail means VerA fails the fixture, and VerA passes; it is other compilers the spelling locks
out. The fix is a runner change (teach the `//!` grammar `I(p,n)`), not a fixture change, and
the same shape appears in `ch05_analog_behavior/{flow_probe,port_flow_probe,source_probe_both}.va`,
so it is suite-wide debt. `26_ground_non_electrical.va` rests on the adjacent undocumented
form: bare net names in `//! bias`, the only spelling that works for a non-electrical access.

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
