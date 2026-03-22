# Chapter 7 coverage

Audit checkpoint, 2026-09-23: `docs/conformance-mixed-signal.md` supersedes
the historical oracle claims below where explicitly identified. MIX-LOCAL-001
corrects `lrm_7_4_4_3.va` to preserve the electrical child's own V/I accesses;
its former passing expectation required the wrong discipline. The corrected
positive and separate invalid Va/Ia reads expose implementation failures and
are XFAIL, not behavioral coverage. MIX-TOL-001 and MIX-MODE-001 remain open.

Full-AMS status: a boundary rejection below documents a limitation, not support
for a legal mixed-signal feature. Execution, synchronization and insertion rows
remain open until behavioral host tests establish them.

Source: `docs/ch7-mixed-signal.html`, read section by section.

HTML section-ID audit: `s7-1` `s7-2` `s7-2-1` `s7-2-2` `s7-2-3` `s7-2-4` `s7-3` `s7-3-1` `s7-3-2` `s7-3-2-1` `s7-3-3` `s7-3-4` `s7-3-5` `s7-3-6` `s7-3-6-1` `s7-3-6-2` `s7-3-6-3` `s7-3-6-4` `s7-3-6-5` `s7-3-7` `s7-4` `s7-4-1` `s7-4-2` `s7-4-3` `s7-4-4` `s7-4-4-1` `s7-4-4-2` `s7-4-4-3` `s7-4-5` `s7-5` `s7-6` `s7-7` `s7-7-1` `s7-7-2` `s7-7-2-1` `s7-7-3` `s7-7-4` `s7-8` `s7-8-1` `s7-8-2` `s7-8-3` `s7-8-3-1` `s7-8-3-2` `s7-8-4` `s7-8-5` `s7-8-5-1` `s7-8-6` `s7-9`. Forty-eight ids.

The historical inventory associates thirteen of the forty-eight sections with
a fixture verdict. Unsupported-feature rejections in that inventory do not prove
the required behavior. Uncovered rows use a leading `—`
rather than a plausible file name. This was the chapter Annex C.9 deleted
outright — "Clause 7 only applies to Verilog-AMS HDL" — while VerA was a
Verilog-A compiler; under the AMS direction the 7.7 family is parsed and
consumed (annex F.2 resolution), and the boundary that remains is the
INSERTION phase (7.8), which needs the discrete kernel the artifact does not
contain.

Ninety-eight `.va` files: fifty-four run and assert, thirty-three are `//! reject`, and
eleven are `//! xfail` — all eleven in the `m03_01`–`m03_11` insertion family. Those three
numbers are grep-MEASURED (`grep -l '^//! xfail' *.va` and the same
for `reject`), not carried over — the sentence that stood here said ten xfail, then two,
then NONE, and each count was true of the tree that wrote it and false of the next. The
`m03_` wave is why the last one moved: those files state §7.8's rules and VerA does not meet
them, which is a different fact from the refusal fixtures this folder mostly holds. The
credit rule used below, stated once so it can be checked:

- **asserted** — a run fixture computes a value the clause fixes. Credited.
- **boundary** — a rejection whose diagnostic lands *on the clause's own
  construct*, pinning where Verilog-A stops. Credited.
- **masked** — the diagnostic fires on an unrelated earlier module item, so the
  clause's rule is never reached. Not credited; the fixture is still named, with
  what actually fires.
- **xfail** — the suite states the rule and VerA does not meet it. Not credited;
  every one is in the ledger below with its reason.

Every diagnostic quoted in this file was produced by running
`zig-out/bin/vera` on the fixture, not inferred from its header.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s7-1` | overview of mixed-signal terminology and connect modules | — non-normative prose; no fixture cites it |
| `s7-2` | parent: continuous and discrete together | — carried by 7.2.1–7.2.4 |
| `s7-2-1` | domain of a value; potentials/flows continuous, regs discrete | `custom_disciplines.va` (`//! lrm 3.6.2`, `7.2.1`) — `domain continuous` on a user discipline makes `p` a conservative node and `access = V` reads it, asserted at 2.5 V. `discrete_discipline.va` is the `domain discrete` half: it defines one, binds a net to it, and asserts the binding is accepted and leaves the electrical node beside it at 0.75 V |
| `s7-2-2` | assignment context fixes a variable's domain | `continuous_context.va` (`//! lrm 7.2.2`, `3.2`) — the analog-block assignment takes the probe value, 1.25, not the §3.2 initial 0. The discrete half is `digital_initial_accepted.va` — green now, and asserting the clause's first sentence directly: a variable assigned only in the `initial` block is read as 1 from the analog block. The `always` half is `m02_10_macro_process_runs_after_nba.va`, green on the mixed-signal runner (`digital_always_unsupported.va` is withdrawn to it). `both_contexts_assignment_rejected.va` is green: E0432, reported at the analog assignment that collides with the `initial` one. The clause is decidable from the source — a variable's domain is fixed by WHERE its assignment is written — so the block still being unexecutable does not mask it |
| `s7-2-3` | nets, ports, signals; a port with two analog connections is an analog port | `analog_port.va` (`//! lrm 7.2.3`, `4.2`) — both ports read through `V()` regardless of direction, checked to the last bit (`-0.49999999999999994`). Only the analog-port row of the classification: digital and mixed ports need two connections, i.e. hierarchy. `hierarchy_unsupported.va` is that shape, and it is refused at E0904 — the child it names is defined nowhere, which is the fixture's own point now that instantiation elaborates |
| `s7-2-4` | node abstol = smallest abstol over the signal's continuous nets | — no fixture. `compatible_disciplines.va` and `custom_disciplines.va` declare `abstol` but never span two disciplines with *different* abstols on one node, and nothing reads back a resolved tolerance |
| `s7-3` | parent: read across domains, write only in your own | — carried by 7.3.1–7.3.7 |
| `s7-3-1` | Table 7-1, discrete types read from a continuous context | `m01_01_onebit_dac_reads_a_discrete_wire.va` — green: a 4-bit discrete net driven by `assign` reads as the integer 10, and its bit-select as 1 (`discrete_scalar_bit_unsupported.va`, which pinned E0315 on the same read as C.9 conformance, is withdrawn to it). The `real` row is checked too: `discrete_real_from_analog.va` is green and asserts the row's own words — read "with no conversion", 1.25 exactly. Both legal-width bus fixtures (`discrete_bus_narrow.va`, `discrete_bus_31.va`) are green, and `discrete_bus_over31_rejected.va` still pins the >31 prohibition, so the boundary is now checked from both sides with nothing masked. `analog_reads_integer.va` cites 7.3.1 but its `integer` is assigned *inside* the analog block, so by 7.2.2 it is a continuous variable and no Table 7-1 row applies — what it asserts is §4.2.12 ternary truthiness |
| `s7-3-2` | four features that carry x/z into the analog context | The strongest coverage in the chapter, because half of it is an error in AMS too. `x_literal_unsupported.va`, `z_literal_unsupported.va`, `xz_contribution_rejected.va` and `xz_ordinary_equality_rejected.va` reproduce the four lines the clause's own `converter` example annotates `// error`; all four land on E0130, "x/z digit in a number literal", on the literal itself. `case_equality.va` is the operator alone on two-state integers, ACCEPTED and asserted (it used to pin E0323 on the Verilog-A subset's C.5; the list above makes `===`/`!==` full-AMS analog features). `x_case_equality_unsupported.va` and `z_case_inequality_unsupported.va` pin `===`/`!==` over an x and a z, refused at E0130 on the literal. `xz_case_statement_unsupported.va` is the `case` form. `xz_casex_statement_unsupported.va` and `xz_casez_statement_unsupported.va` are refused, but only as ``E0209: expected an expression: found `casex` `` — see the code gaps below |
| `s7-3-2-1` | inf and NaN may not reach a branch through contribution | — `inf_contribution.va`, `neg_inf_contribution_rejected.va`, `nan_contribution_rejected.va` are all three green: each pins the message of the rule (`contribution of an infinite value`, `contribution of a NaN`) rather than a code, so the check landing needed no fixture edit. The clause is stated three times and met three times |
| `s7-3-3` | continuous nets probed from a discrete context; interpolation | — no fixture cites it. `digital_probe_unsupported.va` is the clause's `sampler` shape (`always @(p) sampled = V(p);`) but cites 7.3.6.3. The `always` block parses now and its body is judged for the four rules §7.2.2/§4.5.15/§4.7.3/§5.2.1 state, but not against this clause: nothing checks a probe read from a discrete statement, and the block is refused by lowering (E0437, the §8.5 kernel) |
| `s7-3-4` | discrete events detected in a continuous context (Syntax 7-2) | green, all three digital alternatives: `m01_04_posedge_in_an_analog_event_control.va` (`posedge`), `m01_05_bare_signal_change_event_in_analog.va` (the bare `expression`, both edges), `m01_07_named_event_from_digital_reaches_analog.va` (a digitally triggered named event). `digital_event_unsupported.va`, which pinned E0704 on `@(posedge d)` as C.7 conformance, is withdrawn to m01_04: C.7 is the Verilog-A subset, and this is Verilog-AMS. E0704 now fires only on an edge of something with no digital domain (`annex_c_analog_subset/21_digital_event_control_rejected.va`, `posedge V(p)`) |
| `s7-3-5` | continuous events detected in a discrete context (Syntax 7-3) | — `digital_cross_unsupported.va` has the clause's exact `always @(cross(...))` shape but cites 7.3.6.1. The event expression is parsed now; nothing judges it against this clause, and the block is refused by lowering (E0437, the §8.5 kernel) |
| `s7-3-6` | parent: synchronization across the digital tick | — host/kernel property, and 8.2 is where the algorithm lives |
| `s7-3-6-1` | analog event in a digital event control, scheduled at the nearest tick | — `digital_cross_unsupported.va`. The `always @(cross(...))` parses and is refused by lowering (E0437); the SCHEDULING rule is what is missing, and no digital tick exists in this dialect to schedule onto |
| `s7-3-6-2` | digital event in an analog event control, executed at the promoted time | `m01_04` (the ramp sampled at exactly 10.0e-9, not the next or previous point), `m01_07` (delivered once per trigger), `m02_03` and `m02_09` (ch8's guard and region-1b rules on the same mechanism) |
| `s7-3-6-3` | analog primary in a digital expression | — `digital_probe_unsupported.va` and `cross_domain_function_unsupported.va`, both E0437 now: the `always` process is refused by lowering, not by the grammar. Nothing judges an analog primary against this clause. The second is here to record that it is *not* a 7.3.7 violation, contrary to what the file used to claim |
| `s7-3-6-4` | analog event variables driving a continuous assign | — `continuous_assign_unsupported.va` is masked twice over, and not where its header suggests: the diagnostic is `E0205: unsupported module item: found wreal` on the *declaration*, so the `assign` on the next line is never reached either |
| `s7-3-6-5` | digital primary in an analog expression, at the last tick ≤ analog time | — no fixture. `analog_reads_integer.va` was credited here and must not be: its `integer` is written in the analog block, which makes it continuous by 7.2.2, and its own header says so |
| `s7-3-7` | no digital function from analog, no analog function from digital | one of the two sentences is checked, and now pinned as the RULE: `analog_function_from_digital_rejected.va` (was `_unsupported`) pins E0430, the §4.7.3/§7.3.7 calling-context rule, reported at the call in its `initial` block — the block itself is accepted, so nothing masks it. The other half is still masked — `digital_function_from_analog_unsupported.va` is E0205 on the non-analog `function` declaration, so no caller is analysed |
| `s7-4` | parent: assign disciplines to undeclared nets | — needs elaborated hierarchy |
| `s7-4-1` | `resolveto` over an undeclared interconnect's lower connections | — `compatible_disciplines.va` cites 7.4.1 and runs green, but what its `V(p, q)` asserts is the §3.11 Self Rule the clause is *built on*, inside one flat module. The resolution rule proper needs ports, undeclared interconnect and a `connect ... resolveto` statement, none of which are here |
| `s7-4-2` | discrete-time port connections; 1364 rules plus §3.7 for `wreal` | `discrete_discipline.va` cites it for the resolution of a discrete-domain net, but asserts only that the binding is accepted; port connections themselves have no fixture |
| `s7-4-3` | error to connect incompatible continuous disciplines | `incompatible_disciplines_rejected.va` (E0355) against `compatible_disciplines.va`, the positive twin. The clause proper is about a port CONNECTION and needs hierarchy; what the pair states is the §3.11 rule it delegates to, inside one flat module — "ports of continuous-time disciplines … shall obey the rules imposed in 3.11" |
| `s7-4-4` | conflicting discipline declarations for one segment are an error | — `conflicting_discipline_declaration_rejected.va`, green: `//! reject more than one discipline declaration`, the clause's own wording |
| `s7-4-4-1` | basic mode: continuous and discrete propagate up, continuous wins | — no fixture here. `annex_f_resolution/hierarchy_resolution.va` is the closest thing in the tree |
| `s7-4-4-2` | detail mode: continuous up then back down, `resolveto` ignored | — no fixture, and none is possible, which is a stronger statement than the one that stood here. §7.4.4 says of the two modes "The selection of these discipline resolution modes shall be vendor-specific", so NO source file has a computed result that differs between a conforming and a non-conforming compiler: a compiler that implements only `basic` is conforming, and a fixture pinning Figure 7-4's four lines would fail it. There is a second and independent reason the modes are unreachable here: they differ only where a DISCRETE discipline meets an undeclared net, and that is the insertion phase (§7.8), which VerA does not have. §7.4.5 is the case where the modes cannot disagree — nothing discrete — and it IS testable; its row says so |
| `s7-4-4-3` | coercion: a declared interconnect discipline wins unless `resolveto` overrides | `lrm_7_4_4_3.va` cites this id and is green: `ch7443_alt shared;` is a DECLARED interconnect, reached by a child through an `electrical` port, and the child's `Va(shared)` reads 0.5 while the same child's sibling on an UNDECLARED net reads `V(plain)` = 0.25 — so the declared discipline governs, and a compiler that let the port's discipline coerce it reads through the wrong access function and does not compile at all. The clause's second half ("unless the `resolveto` connect statement overrides the discipline") is NOT reached: it needs connect-module insertion, and the `m03_` family is where that is measured. The fixture also records, in its header, why the harness could not bias the net: `//!` names accept only `V()`/`I()`, so a user-discipline accessor in a directive generates a testbench that does not build, and the node is fixed by the model instead. `resolution_connect_accepted.va` remains the statement that coercing a declared discipline by `resolveto` is unimplemented |
| `s7-4-5` | continuous signals resolve identically under both algorithms | `lrm_7_4_5.va` cites this id and is green. The clause's second sentence — "Both algorithms will give the same result as there are no discrete disciplines to propagate upwards" — is what makes it testable where §7.4.4.2 is not: with nothing discrete in the design the two modes CANNOT disagree, so writing down the answer does not pick a mode. The answer is a number because §5.5.3 Syntax 5-4 reads a nature attribute: the undeclared net `undec` meets one `ch745_alt` port, and `undec.potential.abstol` reads 1e-9 against electrical's default 1e-6 — three orders of magnitude, so a compiler that short-circuited "undeclared means electrical" is caught, and one that left the net undisciplined has no nature to read. The header explicitly disclaims §6.5.8: this reads ONE net's own nature, not a minimum over a node's associations |
| `s7-5` | connect modules; Syntax 7-4 adds `connectmodule` to `module_keyword` | green, via the row below: the keyword parses as A.1.2's third `module_keyword` and is cited to 7.6, not counted twice |
| `s7-6` | connect module descriptions; port disciplines define what is bridged | `connectmodule_accepted.va` (`//! lrm 7.6`, `C.9`, `C.16`) — **green, and the verdict is INVERTED from what this row used to say.** It pinned ``E0201: construct is not in the supported subset: `connectmodule` `` on an annex C argument; annex C describes the Verilog-A subset and A.1.2 leaves an AMS compiler no way to refuse the spelling, so the file now asserts ACCEPTANCE (`V(p)` from the ordinary module, which only runs if the whole file elaborated) plus the §7.6 corollary that a connect module is not a design root — it is written FIRST, and nothing instantiates either module, so a compiler picking "the first uninstantiated module" would elaborate the bridge. `supply_hierarchical_connectmodule.va` is the same acceptance plus §6.7.1's `$root` terminal. Table 7-2's direction combinations are still untouched |
| `s7-7` | connect specification statements | `connectrules_accepted.va` (`//! lrm 7.7`, `7.7.1`) — **green and INVERTED from the E0201 wall this row used to be** (see below): the block parses (A.1.8), its insertion is validated against a real connect module, and the `V(p)` assertion exists only if the whole file elaborated |
| `s7-7-1` | `connect <module>;` auto-insertion statement | `connectrules_accepted.va` — the form in its bare shape, plus elaboration's name check: an insertion naming a non-`connectmodule` is E0915 (unit-tested in `lib/ir/elaborate.zig`; no fixture pins the code because the check is VerA hygiene — 7.7.1 states the identifier's kind, not a diagnostic). The overrides shapes are `connect_mode_accepted.va` |
| `s7-7-2` | `connect a, b resolveto c;` | `resolution_connect_accepted.va` — the form over annex D disciplines, accepted (an unknown discipline in the list is E0916). The SEMANTICS — a two-candidate net resolved by its matching statement, and the `exclude` refusal — are `annex_f_resolution/resolveto_resolution.va` and `exclude_resolution.va`, where the topology exists to exercise them |
| `s7-7-2-1` | connect rule resolution mechanism | — partly, from `annex_f_resolution/`: exact-set match and "the resolved discipline need not be one of the disciplines specified" are `resolveto_resolution.va`. Subset fallback, exact-match precedence and ambiguous exact/subset warnings are implemented in `Elaborate.matchResolution` and exercised by the elaboration unit tests (W0950) |
| `s7-7-3` | parameter passing attribute, `connect m #(.p(v));` | `connect_parameter_accepted.va` (numeric override) and `connect_supply_accepted.va` (string override) — accepted in the A.1.8 grammar slot, parsed by the same A.4.1 production an instance's `#(...)` is, and never APPLIED: they parameterize the insertion phase VerA does not have, and both headers say so |
| `s7-7-4` | `connect_mode` | `connect_mode_accepted.va` — both spellings in their grammar position, with the directed override shapes. Segregation itself is uncredited (no insertion) |
| `s7-8` | automatic insertion at mixed ports | — post-elaboration; no fixture. Its converse, §7.1's MANUAL insertion ("can be manually inserted (by the user)"), is `connect_module_manually_inserted.va`, an xfail: VerA refuses it with E0913 because the flatten carries analog blocks and drops `discrete` ones, so inlining a bridge would stamp its continuous half with its digital half silently absent. The refusal is VerA's limit, not the LRM's |
| `s7-8-1` | connect module selection per hierarchy level | — no fixture. Selection is the insertion phase's first step, and there is no insertion phase |
| `s7-8-2` | signal segmentation; never more than one analog node per signal | — no fixture |
| `s7-8-3` | `connect_mode` parameter, default `merged` | — `connect_mode_accepted.va` writes both values and they PARSE now, but the mode has no consumer (no insertion to segregate), so the default rule is unreached — `Ast.ConnectInsertion` keeps `.unspecified` rather than applying `merged`, deliberately |
| `s7-8-3-1` | `merged`: one shared instance per signal/module/discipline | — same file, parsed and unconsumed |
| `s7-8-3-2` | `split`: one instance per port | — same file, parsed and unconsumed |
| `s7-8-4` | driver-receiver segregation and insertion rules | — no fixture; five rules, all about elaborated signals |
| `s7-8-5` | generated instance names, `SigName__ModuleName__BottomDiscipline` | — `connect_generated_defparam_unsupported.va` gets `E0907`: the `defparam` parses now (§6.3.1), and what refuses the file is that the generated instance the path names does not exist, there being no auto-insertion. That is the clause's own precondition, not its naming scheme. The scheme lives entirely in identifier text no compiler interprets, so it is untestable by construction; `connect_generated_split_name_unsupported.va` was the same test with a different identifier and was deleted |
| `s7-8-5-1` | port names for built-in primitives, six gate families | — `primitive_generated_ports_unsupported.va` stops at `E0205 ... found and`, the A.3 gate instance, which is the module item VerA has no production for; the `defparam` beside it is a legal §6.3.1 item now and its own verdict is pinned by the file above. Neither says anything about `in1`. Only the N-input family is written; the other five (N-output, 3- and 4-port MOS, pass switches, single-port) differ by identifier text alone and are recorded here rather than duplicated |
| `s7-8-6` | supply sensitive connect modules | partly. `connect_supply_accepted.va` — the clause's parameterization channel, a §7.7.3 string override naming the supply, accepted against a connect module that declares it. `supply_hierarchical_connectmodule.va` pins the other writable piece — `V($root.global_supply.vdd)`, a `$root`-prefixed hierarchical name as an access-function TERMINAL (§6.7 Syntax 6-9, §6.7.1), which was E0208 before. The supply sensitivity itself is still unreached: nothing instantiates a bridge, so no connect module's analog body is ever evaluated. Both headers say so |
| `s7-9` | driver-receiver segregation | the cite EXISTS and the evidence does not: `m04_13_receiver_value_set_by_connectmodule.va` and `m04_14_receiver_default_bypass.va` both carry `//! lrm 7.9`. This row said "— no fixture" while they sat in the folder. `m04_13` genuinely exercises the clause — its ordinary receiver must read the connect module's value and NOT the ordinary driver's, which is the segregation made observable, and a compiler that propagates the driver straight through fails a line its `//! reject`-less transcript prints. `m04_14`'s cite is weaker and its own header is the authority: it records that its transcript is "EXACTLY what a simulator with no connect-module insertion, no driver-receiver segregation and no §9.22.5 handling prints", because §9.22.6's default answer and the feature-absent answer necessarily coincide. BOTH FILES ARE DEAD IN THE SUITE: each carries `//! timescale 1ns/1ns`, which is not in `lib/backend/tb.zig`'s directive vocabulary, so both fail at `UnknownDirective` before the compiler is invoked (benchmark: `compile ... 0`) — as do `m04_10`, `m04_11`, `m04_12` and `m04_15`, the §9.22/§9.23 driver-access family. §7.9 therefore has a written-down rule and no measurement until that directive is removed from the six files; that edit belongs to whoever owns the `m04_` row, not to this table |

## The xfail ledger

ELEVEN, and they are one gap wearing eleven hats: the `m03_01`–`m03_11` insertion family
(grep-measured; the sentence that stood here said NONE, one wave ago). They are not eleven
defects — they are §7.8's missing insertion phase, written down eleven times against eleven
different consequences of its absence, and they XPASS together the day it lands, which is why
they are xfail rather than `//! reject`. Their own `//! xfail` lines give the reasons:
`m03_01`/`m03_02`/`m03_03` solve with no bridge and read 1 where the LRM's answer is 0.5, 1/3
and 0.8; `m03_04`, `m03_05` and `m03_08` reach the §7.8.5 generated name, find it absent, and
land on E0907; `m03_06` and `m03_07` pin that §7.7.3's parameter and port overrides are parsed
into `ast.ConnectInsertion` with nothing to consume them; `m03_09` has no analog segment to
keep whole; `m03_10` never instantiates the connect module whose `$analog_node_alias` call is
the point; and `m03_11` has no digital kernel in the emitted device, so neither half of a
bridge can run.

Eight rows have closed and are kept
below, because six of them closed in the way this section said they would — flat single-module
defects that needed no new feature — and because each names a rule that must not silently
regress.

| Fixture | Section | Disposition |
|---|---|---|
| `inf_contribution.va` | `s7-3-2-1` | Green. `I(p) <+ 1.0/0.0` used to be accepted with only W0650, "unit is not provably finite"; §7.3.2.1's ban is a diagnostic now, pinned by its own message |
| `neg_inf_contribution_rejected.va` | `s7-3-2-1` | Green, `-1.0/0.0`. Kept a separate file because a compiler may well diagnose one sign and not the other |
| `nan_contribution_rejected.va` | `s7-3-2-1` | Green, `0.0/0.0`. No run-side check was ever possible here — every comparison against a NaN is false — which is why this had to be a compile-time refusal |
| `conflicting_discipline_declaration_rejected.va` | `s7-4-4` | Green, `//! reject more than one discipline declaration`. `ch7_conf_a w; ch7_conf_b w;` used to overwrite the first declaration silently. Note the clause's own wording: conflicting means "more than one discipline regardless of whether the disciplines are compatible", and these two ARE compatible, so a compatibility-only check would still not catch it |
| `discrete_bus_narrow.va` (was `_unsupported`) | `s7-3-1` | Green. What blocked it was never a capability: four green fixtures pinned `reject E0205` on a constant assignment in an `initial` block, three of them arguing under C.7/C.9 that the refusal *was* conformance. The owner re-verdicted all four (`13_digital_initial_accepted.va`, `digital_initial_accepted.va`, `discrete_real_from_analog.va`, `ch08_scheduling/analog_digital_initial_order.va`) — annex C states the Verilog-A SUBSET and VerA targets Verilog-AMS — and `reg` plus a constant `initial` block are accepted now. 8'hff reads +255, zero-extended |
| `discrete_bus_31.va` (was `_unsupported`) | `s7-3-1` | Green at the legal boundary: 31 ones read +2147483647 with the integer's sign bit zero. The WIDTH half is judged separately, by the parser — E0222 stays silent at 31 and fires at 32 |

## The E0201 wall, demolished

Five fixtures — now `connectrules_accepted.va`, `connect_mode_accepted.va`,
`connect_parameter_accepted.va`, `connect_supply_accepted.va`,
`resolution_connect_accepted.va` (each `was *_unsupported.va`) — used to differ
only in the text inside a `connectrules ... endconnectrules` block while
producing byte-identical ``E0201 ... `connectrules` `` diagnostics at column 1
of the block header, with nothing inside parsed. This file called them *source
inventories* and refused to credit them for the clauses inside the block; that
refusal is why the inversion was cheap. The block parses now (A.1.8;
`Parser.parseConnectRules`), its names are judged at elaboration (E0915 for an
insertion naming no connect module, E0916 for a resolution naming no
discipline — so each fixture had to grow a REAL connect module or use annex D
disciplines), and the five bodies are five different grammar paths rather than
one test five times. What they still do not credit is anything the INSERTION
phase would do: the mode, the parameter overrides and the port overrides are
parsed into `Ast.ConnectInsertion` and consumed by nothing, each header names
that ceiling, and the resolution statements — the one 7.7 form with a consumer
(annex F.2.1 step 4.b, `Elaborate.resolveMultiCandidates`) — have their
semantics pinned in `annex_f_resolution/`, not here.

## Code gaps this chapter exposes

Distinct from the xfail ledger: passing rejection fixtures can record missing
full-AMS behavior. More specific diagnostics alone do not close the gaps below.

- `casex`/`casez` (required by full AMS; C.7 only excludes them from Verilog-A) get three cascading
  `E0209: expected an expression` errors apiece, because the parser has no such
  keyword. `===` is accepted on two-state operands; `casex` is not parsed at all.
- `x_case_equality_unsupported.va` and `z_case_inequality_unsupported.va` are
  refused at E0130 for the x/z literal; the operator itself is accepted
  (`case_equality.va`), so the literal is the whole remaining gap.
- `discrete_bus_over31_rejected.va` left this list. §7.3.1 Table 7-1's ">31 bits
  is illegal" is now its own diagnostic, E0222, alongside the E0205 that refuses
  the `reg`; the file pins the rule's wording rather than the code, because what
  separates it from its two legal-width siblings is the presence of that second
  diagnostic and not the fact of a rejection.

## Fixtures here that cite other chapters

`analog_event.va` has no Chapter 7 cite at all — `//! lrm 5.10.3.1`,
`5.10.3.2`, `3.2` — and its own header spends a paragraph explaining that
`cross()` is an *analog* event, so nothing in it crosses a domain and it does
not pin 7.3.4. It lives here for historical reasons and is counted against
Chapter 5.

`custom_disciplines.va` (`3.6.2`) and `compatible_disciplines.va` (`3.11`) each
lead with a Chapter 3 cite; the Chapter 7 cite is secondary and, for
`compatible_disciplines.va`, aspirational — see the `s7-4-1` row.
`analog_port.va` and `analog_reads_integer.va` both do real IEEE-754 work
(`4.2`, `4.2.12`) alongside their Clause 7 claim.

## What a Verilog-AMS compiler would add

This section used to say all of 7.4.4 through 7.9 "stays empty until this is a
Verilog-AMS compiler with an elaborator". The elaborator exists
(`ir/elaborate.zig` flattens the hierarchy), discipline propagation is annex
F's and covered there, and the 7.7 connect specification family is parsed,
validated and — for resolution statements — consumed. What remains empty is
exactly the INSERTION half: 7.8's selection/segmentation/auto-insertion and
7.9's driver-receiver segregation need a discrete kernel for the bridge's
digital side to run on, and VerA's artifact is one analog device. Those rows
remain full-AMS implementation and validation debt. The connect-statement
fields with no consumer (`mode`, `#(...)`, port overrides) likewise remain
unimplemented behavior. The standalone scheduler core does not supply bridge
execution, insertion or driver-receiver segregation.
