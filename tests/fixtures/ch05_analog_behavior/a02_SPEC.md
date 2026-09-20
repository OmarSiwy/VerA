# A02 — Branch equations and topology

Greenfield row: no `w2/*` branch covers it. Twelve positive fixtures and one
refusal, all under `tests/pending/A02/`. Nothing outside this directory was
touched.

## LRM clauses covered

Read out of the offline HTML in `docs/` (`ch5-analog.html`, `ch9-system.html`).

| clause | title | what it contributes to this row |
|---|---|---|
| **§5.4.1** | Access functions | "There can only be one unnamed branch between any two nets or between a net and implicit ground (in addition to any number of named branches)." Example 4: `I(<p1>)` is the flow into the module through port p1. |
| **§5.4.2.1** | Probes | "The branch potential of a flow probe is zero (0). The branch flow of a potential probe is zero (0)." Figure 5-1 draws them as an ammeter and a voltmeter. |
| **§5.4.2.2** | Sources | "Both the potential and the flow of a source branch are accessible in expressions anywhere in the module." |
| **§5.4.3** | Accessing flow through a port | The port access function, its Example 1 diode (`I(<a>)` over a conduction branch and a charge branch), and the prohibition on `V(<p>)` / on `I(<p>)` as an lvalue. |
| **§5.4.4** | Unassigned sources | "If a value is not assigned to a branch, and it is not a probe branch, the branch flow is set to zero (0)." |
| **§5.5.1** | Accessing net and branch signals | Syntax 5-3: `nature_access_function ::= nature_attribute_identifier \| potential \| flow`. |
| **§5.6.1.1** | Relations | "The branch is directed from the first net of the access function to the second net." |
| **§5.6.1.2** | Evaluation | The three-step retain-and-assign rule; "the simulator adds the value of the right-hand side to any previously retained value of the branch". |
| **§5.6.1.3** | Value retention | Additive for like kinds; contributing the other kind discards what was retained. |
| **§5.6.5** | Switch branches | Contributions are allowed inside conditionals; a zero-order discontinuity is assumed when the branch switches. |
| **§5.6.6** | Implicit Contributions | "The underlying implementation of the simulator will find the value of I(diode) that equals the sum of the contributions made to it, even if the contributions are a function of I(diode) itself." |
| **§5.6.8.1** | Contributions to branches between hierarchical nets | "In these cases, a new unnamed branch is created in the module containing the direct contribution statements." |
| **§5.6.8.2** | Hierarchical direct contributions to branches | Allowed to named and unnamed branches; NOT allowed when "the hierarchical contribution changes the branch into a switch branch". |
| **§9.20** | Analog Node Alias System Functions | "…shall be re-evaluated each sweep point of a dc sweep as needed"; the conditional restriction; "shall refer to the same circuit matrix position". |
| **§5.2.1** | Analog initial block | "If a parameter or variable that is referenced from an analog initial block is changed during a sub-task of a parameter sweep analysis, then the analog initial block shall be re-executed." |
| **A.8.9 / Syntax 5-3** | — | `hierarchical_unnamed_branch_reference ::= hierarchical_inst_identifier.branch ( branch_terminal [ , branch_terminal ] )`. |

## Ground truth, established by reading source and running the compiler

The plan's A02 line and the ch05 `COVERAGE.md` overstate the state of this row.
What is actually there, checked by grep and by running `vera --run
--display=emit` on probe models written for the purpose:

**Already implemented, no fixture anywhere (so pinned here):**

- Port-flow probes have a real defining row in DC. For a delta network the
  testbench prints `res[flowZ28Z3cpZ3eZ29]` with a full Jacobian and solves it to
  the KCL value. `tests/fixtures/ch05_analog_behavior/port_flow_probe.va` never
  tests this — it FORCES the unknown with `//! sweep flowZ28Z3cpZ3eZ29 =
  0.0625`. → fixture 05.
- The generic `potential`/`flow` names work on both sides of `<+`, including
  §5.6.1's own `measure2` example, and unnamed-branch identity holds across
  spellings and across terminal order. → fixture 12.
- Hierarchical PROBES (§5.5.4/§5.5.5) resolve and read the child's solved node
  values. `hierarchical_access_unsupported.va` only `$strobe`s them.
- Hierarchical contribution to a child's NAMED branch accumulates (§5.6.8.2
  first example). → fixture 08.
- Two-branch conditional topology (SPDT) solves correctly in both states. →
  fixture 11.
- `ddt(I(b))` and `ddt(I(<p>))` — a reactive operator applied TO a branch or port
  current — work in transient when the current is a forced unknown.
- Hierarchical contribution to an indirectly-contributed branch is already
  refused (`E0409`), so no fixture is written for that bullet of §5.6.8.2.

**Not implemented (the deliverable):**

1. **Implicit contributions are not solved.** `I(b) <+ gm*(V(b) - rs*I(b))` emits
   a branch-flow unknown with **no defining row at all** — the testbench prints
   `res[flowZ28sZ2cmZ29] = 0` with zero Jacobian entries — so the unknown holds
   its seed of 0 and the right-hand side is silently linearised. The existing
   `implicit_fixed_point.va` is green only because `//! sweep` supplies the fixed
   point by hand. This is the plan's "each introduced unknown needs a defining
   equation", and it silently mis-solves every implicit device model including
   §5.6.6's own series-resistance diode.
2. **A flow probe is not a zero-volt source.** `k = I(a,b)` leaves a and b
   unconnected; the introduced unknown again has an empty row and is stamped into
   neither node's KCL.
3. **A branch-flow probe drops the reactive term.** `I(cap) <+ c*ddt(V(cap))`
   then reading `I(cap)` returns 0 in transient. The node equation is right (the
   charge tape carries `q[p] = 1e-9` with the correct derivative); the probe read
   is compiled from the resistive half only.
4. **A port-flow probe drops the reactive term** for the same reason, plus a
   second, named limitation: `lib/backend/tb.zig`'s `solve` carries a `ponytail:`
   note reading *"the RESISTIVE residual only … Fold q in when a fixture needs a
   transient solve"*. Fixture 06 is that fixture.
5. **§5.6.8.1 is implemented as a merge.** A parent's `V(drv.x, drv.y) <+ 1.2`
   does not create a new branch in the parent; it merges with the child's unnamed
   branch and §5.6.1.3 value retention then **deletes the child's own
   constitutive law** — the 1 mS conductance vanishes from the Jacobian entirely.
6. **A.8.9's `drv.branch(x,y)` does not parse** (`E0208`). The production is
   absent, so the child's existing unnamed branch is unreachable from a parent.
7. **Node aliases are bound once at elaboration.** Under a parameter sweep the
   second sub-task reuses the first point's binding, in violation of §9.20 and
   §5.2.1 — and `status` still reads 1, so the model's own return-value check
   (which §9.20 encourages) cannot see it.
8. **§5.6.8.2's switch-branch prohibition is unchecked.** A parent flow
   contribution to a branch the child potential-sources is accepted silently.

## Fixtures

Positive: 12. Refusal: 1.

| fixture | pins | expected value and derivation | today |
|---|---|---|---|
| `01_implicit_flow_equation_is_solved.va` | §5.6.6 — the simulator FINDS the fixed point; the introduced unknown has a defining equation. | `I(b) = 0.125 A`, `V(m,g) = 0.5 V`. Two equations: `I = gm(V(s)−V(m)−rs·I)` and `I = V(m)/rl`. With `gm·rs = 1`, `2I = 0.5(1−V(m))`; substituting `V(m) = 4I` gives `4I = 0.5`, so `I = 1/8` and `V(m) = 1/2`, both exact in binary. Feeding the RHS occurrence a zero instead gives `I = 1/6`, `V(m) = 2/3`. | **FAIL** `0.16666666666666669` / `0.6666666666666666` |
| `02_flow_probe_is_a_zero_volt_source.va` | §5.4.2.1 + Figure 5-1 — a flow probe is a short with an ammeter in it. | `V(a) = V(b) = 2.0 V`, probe reads `1.0 mA`. 1 k in series with 2 k across 3.0 V: `I = 3/3000 = 1 mA`, `V(a) = 3 − 1e-3·1000 = 2.0`. Exact. An open answers 3.0 / 0.0 / 0. | **FAIL** `3` / `3` / `0` |
| `03_potential_probe_draws_no_flow.va` | §5.4.2.1's dual — a potential probe is an open. The guard rail that stops 02 from being fixed as "probes always short". | `V(a) = 2.0 V`, `V(c) = 0.0 V`, `V(a,c) = 2.0 V`. 1 k/2 k divider off 3.0 V, untouched; c's only path is its 10 k, carrying no current. Shorting the probe instead gives 1.875 V and 0. | pass |
| `04_branch_flow_probe_includes_the_reactive_part.va` | §5.4.2.2 + §5.6.1.2 — the flow of a source branch is its whole retained value. | `I(cap) = 1.0 A` at every `t > 0`, `0` at `t = 0`. 1 nF on a 1 V/ns ramp: `c·dV/dt = 1e-9 · 1e9 = 1.0`; §4.5.3 makes `ddt` zero at the opening DC point. Folded on `($abstime > 0)`. | **FAIL** `0` at all three transient points |
| `05_port_flow_is_kirchhoff_at_the_port.va` | §5.4.3/§5.4.1 — `I(<p>)` is KCL over every branch touching p. | `I(<p>) = 1.5 mA`, `I(<n>) = −1.5 mA`, sum `0`, `V(m,n) = 1.0 V`. Delta at `V(p) = 2`: symmetric 1 k/1 k arm carries `1/1000 = 1 mA` and fixes `V(m) = 1`; 4 k arm carries `2/4000 = 0.5 mA`. Exact. | pass (pinning evidence) |
| `06_port_flow_includes_the_reactive_part.va` | §5.4.3 Example 1 — the port probe must see the charge branch, which is what its `imax` guard is watching for. | `I(<p>) = 0, 1.001, 1.002, 1.003 A`. Capacitive `1e-9 · 1e9 = 1.0 A`; resistive `(t/1ns)/1000`. `want` is built from `$abstime` alone so it cannot cancel against the probe. The two terms are three decades apart so the transcript says which half survived. | **FAIL** `0.001 / 0.002 / 0.003` — resistive only |
| `07_hierarchical_contribution_creates_a_new_branch.va` | §5.6.8.1 — "a new unnamed branch is created in the module containing the direct contribution statements"; the child's branch is a SEPARATE parallel branch. | child's `I(x,y) = 1.2 mA`, parent's `I(drv.x,drv.y) = 0.6 mA`, `V(y) = 1.8 V`. Parent's source pins `V(x,y) = 1.2` and the child pins `V(x) = 3`, so `V(y) = 1.8` under either reading; the child's 1 k branch then carries 1.2 mA, the 1 k load at y carries 1.8 mA, and KCL leaves 0.6 mA for the parent's branch. A merged network carries 1.8 mA in one branch and neither number appears. | **FAIL** `0` / `0` (merged; child's conductance deleted from the Jacobian) |
| `08_hierarchical_named_branch_accumulates.va` | §5.6.8.2 first example + §5.6.1.2 — naming the child's BRANCH reaches the branch it already owns, so the two contributions add. The guard rail against fixing 07 as "hierarchy always creates a new branch", which would make this file a voltage-source loop. | `V(br) = V(x) = 2.3 V`, `I(br) = −2.3 mA`. `0.5 + 1.8 = 2.3`; the 1 k load is the branch's only path, and the sign is §5.6.1.1 — `br` is declared `(x, b)` and the return current traverses it b→x. **Tolerance 1e-12 on all three** — the previous 1e-15/1e-18 were 2.25 and 2.31 ulp; see "Corrected after review". | pass (pinning evidence) |
| `09_hierarchical_unnamed_branch_reference.va` | A.8.9 / §5.6.8.2 second example — `V(top.drv.branch(x,y))`, the only spelling that reaches a child's existing unnamed branch. | `V(y) = 2.0 V`, child's `I(x,y) = 2.0 mA`. Contributions add: branch flow `= V(x,y)/1000 + 1e-3`. KCL at y with `V(x) = 3`: `(3−v)/1000 + 1e-3 = v/1000` → `v = 2.0`, flow `= 1 mA + 1 mA`. `V(y)` is 2.0 under the §5.6.8.1 reading too; `I(x,y)` is 1 mA there, which is what separates them. | **FAIL** `error[E0208]: expected an identifier: found \`branch\`` |
| `10_node_alias_reevaluated_when_a_parameter_changes.va` | §9.20 + §5.2.1 — re-evaluation of the alias when a parameter a sub-task changed is referenced from the `analog initial` block; also §9.20's "unless the conditional expression … can not change during the course of a simulation". | `V(n1) = 2.0 V` at `sel = 0`, `5.0 V` at `sel = 1`, `status = 1` at both. The child's two sources are 2.0 and 5.0 and `n1` is otherwise isolated (would read 0), so the alias is the only path to either number. Folded as `V(n1) − sel·3.0 = 2.0`. | **FAIL** at point 1: `got=-1 want=2` (V(n1) still 2.0) |
| `11_double_throw_switch_topology.va` | §5.6.5 + §5.4.4 — two branches switching in complementary arms, i.e. two matrix structures, not one structure with two row contents. | closed: `V(a) = 4.0`, `V(b) = 3.0`; open: `V(a) = 2.0`, `V(b) = 4.0`. 4 V through 1 k into a 1 k load (divider 2.0) and through 1 k into a 3 k load (divider 3.0), each shorted in turn. Folded onto the single literal 4.0 per line. Shorting both arms reads 4.0/4.0; shorting neither reads 2.0/3.0. | pass (pinning evidence) |
| `12_one_unnamed_branch_under_every_spelling.va` | §5.4.1 "only one unnamed branch between any two nets" × §5.5.1's generic names × §5.6.1.1's direction. | All four spellings read back: `I(m,g) = flow(m,g) = 0.5 mA`, `flow(g,m) = I(g,m) = −0.5 mA`, `V(m) = potential(m,g) = 2.5 V`. `1 mA − 0.5 mA` accumulate on one branch; KCL through the 1 k from a 3.0 V source gives `V(m) = 3 − 0.5 = 2.5`. `V(m)` is 2.5 even if the spellings made separate branches — the probe reading 0.5 mA rather than 1.0 mA is the part that discriminates. | pass (pinning evidence) |
| `90_hierarchical_switch_branch_rejected.va` | §5.6.8.2 — "the hierarchical contribution changes the branch into a switch branch" is a reason the contribution is not allowed. The illegal twin of fixture 08: one access function apart. | refusal. | **FAIL** — accepted silently, exit 0, no diagnostic |

`90`'s `//! reject` line carries prose, not an `Exxxx` code, because none is
allocated for this rule. The implementer should allocate one and rewrite the
directive; the harness matches the directive as a plain substring, so the
message has to contain the clause's own phrase either way.

### Observed today, verbatim

Captured, not typed: the block below is the literal stdout+stderr of the loop in
"Build / run" below, with only the `x[...]`, `res[...]`, `d res.../d x...` and
`t = ...` solver-dump lines filtered out for length. Re-captured after the
corrections in this document were applied.

```
##### 01_implicit_flow_equation_is_solved   (exit 0)
=== 01_implicit_flow_equation_is_solved ===
--- point 0 ---
the solver finds the fixed point, not the linearised value got=0.16666666666666669 want=0.125 ok=0
and the load node follows it got=0.6666666666666666 want=0.5 ok=0
at the solution the right-hand side reproduces the target got=0 want=0.125 ok=0
##### 02_flow_probe_is_a_zero_volt_source   (exit 0)
=== 02_flow_probe_is_a_zero_volt_source ===
--- point 0 ---
a flow probe is a zero-volt source, so it shorts a to b got=3 want=0 ok=0
and the series divider then sits at 2.0 V got=3 want=2 ok=0
the ammeter reads the 1 mA the 3 kohm series string carries got=0 want=0.001 ok=0
##### 03_potential_probe_draws_no_flow   (exit 0)
=== 03_potential_probe_draws_no_flow ===
--- point 0 ---
the probe loads nothing, so the 1k/2k divider is untouched got=2 want=2 ok=1
and it connects nothing, so c is left at the reference got=0 want=0 ok=1
the voltmeter reads the full divider output got=2 want=2 ok=1
##### 04_branch_flow_probe_includes_the_reactive_part   (exit 0)
=== 04_branch_flow_probe_includes_the_reactive_part ===
--- point 0 ---
the flow of a source branch is its whole retained value, reactive term included got=0 want=0 ok=1
--- point 1 ---
the flow of a source branch is its whole retained value, reactive term included got=0 want=1 ok=0
--- point 2 ---
the flow of a source branch is its whole retained value, reactive term included got=0 want=1 ok=0
--- point 3 ---
the flow of a source branch is its whole retained value, reactive term included got=0 want=1 ok=0
##### 05_port_flow_is_kirchhoff_at_the_port   (exit 0)
=== 05_port_flow_is_kirchhoff_at_the_port ===
--- point 0 ---
the divider arm and the shunt arm both leave p got=0.0015 want=0.0015 ok=1
and the same current arrives at n got=-0.0015 want=-0.0015 ok=1
so the module conserves flow got=0 want=0 ok=1
the symmetric divider fixes the interior node got=1 want=1 ok=1
##### 06_port_flow_includes_the_reactive_part   (exit 0)
=== 06_port_flow_includes_the_reactive_part ===
--- point 0 ---
the port probe measures the charge current as well as the conduction current got=0 want=0 ok=1
--- point 1 ---
the port probe measures the charge current as well as the conduction current got=0.001 want=1.001 ok=0
--- point 2 ---
the port probe measures the charge current as well as the conduction current got=0.002 want=1.002 ok=0
--- point 3 ---
the port probe measures the charge current as well as the conduction current got=0.003 want=1.003 ok=0
##### 07_hierarchical_contribution_creates_a_new_branch   (exit 0)
=== 07_hierarchical_contribution_creates_a_new_branch ===
--- point 0 ---
the child's own branch keeps its own constitutive law got=0 want=0.0012 ok=0
and the parallel source fixes the node either way got=1.8 want=1.8 ok=1
the branch this statement created carries what KCL leaves for it got=0 want=0.0006 ok=0
##### 08_hierarchical_named_branch_accumulates   (exit 0)
=== 08_hierarchical_named_branch_accumulates ===
--- point 0 ---
the parent reaches the child's own branch, so the two add got=2.3 want=2.3 ok=1
and the node it drives follows got=2.3 want=2.3 ok=1
the load current returns through the branch, against its declared direction got=-0.0023 want=-0.0023 ok=1
##### 09_hierarchical_unnamed_branch_reference   (exit 1)
error[E0208]: expected an identifier: found `branch`
  --> tests/pending/A02/09_hierarchical_unnamed_branch_reference.va:63:11
   |
63 |     I(drv.branch(x, y)) <+ 1m;
   |           ^^^^^^
   |
   = note: LRM 2.8
   = help: run `vera --explain E0208` for a detailed explanation

error: could not compile due to 1 previous error(s)
##### 10_node_alias_reevaluated_when_a_parameter_changes   (exit 0)
=== 10_node_alias_reevaluated_when_a_parameter_changes ===
--- point 0 ---
both hierarchical references resolve, at both sweep points got=1 want=1 ok=1
the alias is re-evaluated, so it follows the swept parameter got=2 want=2 ok=1
--- point 1 ---
both hierarchical references resolve, at both sweep points got=1 want=1 ok=1
the alias is re-evaluated, so it follows the swept parameter got=-1 want=2 ok=0
##### 11_double_throw_switch_topology   (exit 0)
=== 11_double_throw_switch_topology ===
--- point 0 ---
arm a is shorted to the source, or left as a 1k/1k divider got=4 want=4 ok=1
and arm b is the other way round, on a 1k/3k divider got=4 want=4 ok=1
--- point 1 ---
arm a is shorted to the source, or left as a 1k/1k divider got=4 want=4 ok=1
and arm b is the other way round, on a 1k/3k divider got=4 want=4 ok=1
##### 12_one_unnamed_branch_under_every_spelling   (exit 0)
=== 12_one_unnamed_branch_under_every_spelling ===
--- point 0 ---
the reversed, generically spelled contribution subtracts on the same branch got=0.0005 want=0.0005 ok=1
read back the other way round it is the negation, not a second branch got=-0.0005 want=-0.0005 ok=1
the generic flow name in the declared direction is the same value again got=0.0005 want=0.0005 ok=1
and the discipline access function reversed is its negation, not a third branch got=-0.0005 want=-0.0005 ok=1
and the 1 kohm drops 0.5 V carrying it got=2.5 want=2.5 ok=1
the generic potential name is the same quantity got=2.5 want=2.5 ok=1
##### 90_hierarchical_switch_branch_rejected   (exit 0)
=== 90_hierarchical_switch_branch_rejected ===
--- point 0 ---
```

Five of the thirteen pass today and are deliberately kept: 03 guards 02, 08
guards 07, and 05/11/12 are the regression floor under the matrix-assembly
changes that 01, 02 and 07 all require.

**The row's real pressure is 8 of 13, not 13.** Eight fixtures go red against
HEAD for the reason claimed (01, 02, 04, 06, 07, 09, 10, 90); five already pass.
Counting all thirteen as delivered coverage would overstate this row, so the
headline number to use is eight.

### What each already-passing fixture would reject

Disclosure is not a fix, so each of the five is stated here as the concrete
wrong implementation it refuses, with the single assertion that does the
refusing. Any fixture that could not be given a line in this table would have no
teeth and would have been deleted instead.

| fixture | the wrong implementation it rejects | the assertion that rejects it | what it answers instead |
|---|---|---|---|
| `03` | "a probe branch shorts its terminals" — the cheapest wrong way to make 02 pass | `V(a) == 2.0` **and** `V(c) == 0.0` (two independent facts; the third, `v_meas == 2.0`, is `V(a) − V(c)` and is a precondition, not a claim — see the file header) | `1.875` and `1.875` |
| `05` | no defining equation for `I(<p>)` at all — the port unknown keeps its seed | `I(<p>) == 1.5e-3` and `I(<n>) == −1.5e-3`. The conservation line `I(<p>)+I(<n>) == 0` is **not** independent: a tool answering 0 for both ports satisfies it. It only discriminates a per-port bookkeeping error, jointly with the two above. | `0` / `0` |
| `08` | "a hierarchical contribution always creates a new branch in the parent" — the cheapest wrong way to make 07 pass, which turns this file into a 0.5 V ∥ 1.8 V source loop | `V(br) == 2.3` and `I(br) == −2.3e-3` | refusal, or an arbitrary pick of `0.5` / `1.8` |
| `11` | one matrix structure with two row contents — both switch arms stamped unconditionally, or neither | one line per sweep point, and not the same line at both. Both arms shorted: line 2 reads `5.0` at `V(c)=1.0`, line 1 reads `6.0` at `V(c)=0.0`. Neither shorted: line 1 reads `2.0` at `V(c)=1.0`, line 2 reads `3.0` at `V(c)=0.0`. (The file's header used to name the wrong point; re-derived, see below.) | as listed, against a want of `4.0` |
| `12` | branch identity recovered per spelling rather than per terminal pair | `I(m,g) == 0.5e-3`, `flow(g,m) == −0.5e-3`, `flow(m,g) == 0.5e-3`, `I(g,m) == −0.5e-3` — all four, since two of the four were unasserted before this revision | `1.0e-3` on whichever spelling got its own branch |

## Deliberately NOT covered

- **Voltage-source loop detection.** §5.6.8.1 and §5.6.8.2 both end with "the
  simulator shall check if the contribution produces a solvable set of
  equations, e.g. no voltage source loops created". That is a structural check
  over the assembled matrix, not a value, so it belongs with the host's DC
  analysis rather than with a `CHECK` in a device — and it cannot be written
  honestly until §5.6.8.1 stops merging branches (fixture 07), because under the
  merge the loop never forms.
- **`$analog_port_alias` into a child instance's port.** §9.20's own example
  aliases to `"top.r1.p"` and expects `I(<n2>)` to read 5 mA. VerA flattens
  instances, so a child terminal's flow is not a quantity the flat design still
  carries; `tests/fixtures/ch09_system_tasks/191_port_alias_resolves.va` already
  documents that and aliases to a top-level port instead. Fixture 10 sweeps the
  node-alias form only. Revisit when instances survive elaboration.
- **Vector branches and vector node aliases.** §5.5.2 and §9.20's "if the
  analog_net_reference is a vector node, it shall reference the full vector
  node". `ch03_data_types/33_vector_branches.va` covers the declaration side;
  the topology side is a separate row's worth of work.
- **AC and noise views of any of this.** Every reactive assertion here is
  transient (`//! analysis tran`); the small-signal transfer of a port probe is
  A06's territory.
- **`$discontinuity` around switch events.** §5.6.5 says one of order zero is
  assumed and no `$discontinuity` call is needed; asserting that requires
  observing the timestep controller, which this harness does not expose.
- **The refusal side of most of the row.** Only one reject fixture is written.
  `V(<p>)`, `I(<p>)` as an lvalue, probing both quantities of a probe branch,
  filters under a non-constant conditional, contributions inside event controls,
  and the four `$analog_node_alias` misuse rules all already have green fixtures
  under `tests/fixtures/`; duplicating them here would be noise.
- **The host.** No ARPice fixture. Every defect above is observable inside
  VerA's own testbench, and three of them (01, 02, 07) are missing matrix rows
  that the host could not compensate for even in principle.

## Build / run

These live outside `tests/fixtures/`, so `zig build torture` does not see them.

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build                                   # refresh zig-out/bin/vera
for f in tests/pending/A02/*.va; do
  b=$(basename "$f" .va)
  echo "##### $b"
  ./zig-out/bin/vera --run --display=emit \
    --contract tools/contract.zig \
    -I tests/fixtures \
    --work-dir "/tmp/a02/$b" "$f"
done
```

Every `ok=` column must read `ok=1`, and `90_…` must produce a diagnostic
containing `changes the branch into a switch branch`.

To wire them into the green gate once the clauses are implemented, move
01–04, 11 and 12 and 90 into `tests/fixtures/ch05_analog_behavior/`, 05–09 into
`tests/fixtures/ch05_analog_behavior/` as well (they are all Clause 5), and 10
into `tests/fixtures/ch09_system_tasks/`; add each file's one-liner to that
directory's `COVERAGE.md`, then:

```sh
zig build torture -- --strict ch05
zig build torture -- --strict ch09
```

## Corrected after review

An adversarial review of `tests/pending/MANIFEST.md` attributed defects to this
row in its Class C (§5.3) and Class D (§5.4) sections. This is what changed and
why. Nothing outside `tests/pending/A02/` was touched; the row's clause coverage
and its eight failing fixtures are unchanged, so nothing has moved to another
row and no claim was withdrawn.

1. **Fixture 08's tolerances were at the ULP floor** (MANIFEST §5.3). `I(br)` was
   asserted `-2.3e-3` at `1e-18` and `V(br)`/`V(x)` were asserted `2.3` at
   `1e-15`. Re-derived: `ulp(2.3) = 2^-51 = 4.440892098500626e-16`, so `1e-15`
   is **2.25 ulp**; `ulp(2.3e-3) = 2^-61 = 4.336808689942018e-19`, so `1e-18` is
   **2.31 ulp**. The reviewer's arithmetic is right. All three are now `1e-12`,
   which is `4.3e-13` relative on a potential and leaves every wrong answer the
   fixture exists to reject (0.5 V, 1.8 V, 0 V; -0.5 mA, -1.8 mA, 0) more than
   `5e8` tolerances away. This matters more than usual here because 08 is the
   file this SPEC designates as the regression floor for the matrix-assembly
   rewrite that 01, 02 and 07 all require.
2. **Fixture 08's stated reason for those tolerances was false, which the review
   did not catch.** The header said "`0.5 + 1.8` and the literal `2.3` differ in
   the last ulp". They do not: in IEEE-754 double `0.5 + 1.8 == 2.3` bit-for-bit,
   and `2.3/1000.0 == 2.3e-3` bit-for-bit, which is precisely why the fixture
   passed at 2 ulp. The header now says so and shows the ulp arithmetic.
3. **Fixture 11's documented discriminator named the wrong sweep point.** The
   header claimed a compiler shorting both arms "misses the second line by a volt
   at the open point". Substituting the wrong topologies into the two folded
   expressions at both points shows otherwise: shorting both arms reds line 2
   (reads 5.0) at the `V(c)=1.0` point and line 1 (reads 6.0) at the `V(c)=0.0`
   point; shorting neither reds line 1 (reads 2.0) at the first point and line 2
   (reads 3.0) at the second. The full table is in the file header and in "What
   each already-passing fixture would reject" above. The assertions themselves
   were correct and are unchanged — only the prose describing what they catch.
4. **Fixture 12 asserted two of the four spellings its own title claims.**
   `flow(m,g)` and `I(g,m)` — the two crossed cases — were never read back, so an
   implementation that recovered branch identity correctly for the two written
   forms and wrongly for the two crossed ones passed. All four are now asserted
   (six checks, all `ok=1` today). Its two weakest assertions, `V(m)` and
   `potential(m,g)`, are now labelled in the file as what they are: a pin on
   §5.5.1's generic *name*, not on §5.4.1's one-branch rule, since `V(m) = 2.5`
   holds even under the multiple-branch reading.
5. **The five already-passing fixtures now state what they reject, not just that
   they pass** (MANIFEST §5.4: "disclosure is not a fix"). The new table above
   gives, per fixture, the concrete wrong implementation it refuses, the single
   assertion that does the refusing, and the number that implementation answers
   instead. Two assertions were audited as non-independent and are labelled as
   preconditions rather than claims, in the files and in the table: 03's
   `v_meas == 2.0` is `V(a) − V(c)` and exists only so that `(a,c)` is a
   potential probe at all, and 05's `I(<p>)+I(<n>) == 0` is satisfied by a tool
   that answers 0 at both ports. Neither was deleted, because neither is the only
   content of its file and both are load-bearing jointly with the assertions
   above them — but neither is counted as coverage.
6. **The headline count is stated as 8 of 13, not 13.** Added above the table.
7. **The "Observed today" block was re-captured, not edited.** It is now the
   literal output of the documented loop with only solver-dump lines filtered,
   which also fixes two omissions in the old block: fixture 07 has three
   assertions and the old transcript showed two, and fixture 90 emits a solver
   point rather than nothing.

Citations were re-checked against `docs/ch5-analog.html`, `docs/ch9-system.html`
and `docs/annex-a-syntax.html` by opening each clause. MANIFEST §5.2's verdict
("citations verified clean") holds — §5.4.1, §5.4.2.1, §5.4.2.2, §5.4.3, §5.4.4,
§5.5.1, §5.6.1.1, §5.6.1.2, §5.6.1.3, §5.6.5, §5.6.6, §5.6.8.1, §5.6.8.2, §5.2.1,
§9.20 and A.8.9 all exist with the titles and the sentences quoted. Two quotation
hygiene fixes were made anyway:

- Fixture 08 quoted §5.6.1.3 as "multiple contributions to the same potential
  branch will be additive"; the clause reads "...to the same potential branch **or
  same flow branch** will be additive". Now verbatim.
- Fixture 11 quoted "it shall be treated as a flow source with a value of 0"
  under a `//! lrm 5.4.4` directive. That sentence is §5.6.1.3's; §5.4.4's own
  wording is "the branch flow is set to zero (0)". Both clauses are relevant, so
  both are now quoted verbatim and `//! lrm 5.6.1.3` was added so the recorded
  cite and the quoted text agree.

The refusal fixture `90` already carries a specific `//! reject` substring
(`changes the branch into a switch branch`, the clause's own phrase) rather than
a bare `//! reject`, so MANIFEST §5.4's D06/D08 finding does not apply to it. It
stays prose rather than an `Exxxx` code because no code is allocated for this
rule; see the note under the fixture table.
