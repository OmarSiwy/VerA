# Chapter 7 coverage

Source: `docs/VAMS-LRM/ch7-mixed-signal.html`, read section by section.

HTML section-ID audit: `s7-1` `s7-2` `s7-2-1` `s7-2-2` `s7-2-3` `s7-2-4` `s7-3` `s7-3-1` `s7-3-2` `s7-3-2-1` `s7-3-3` `s7-3-4` `s7-3-5` `s7-3-6` `s7-3-6-1` `s7-3-6-2` `s7-3-6-3` `s7-3-6-4` `s7-3-6-5` `s7-3-7` `s7-4` `s7-4-1` `s7-4-2` `s7-4-3` `s7-4-4` `s7-4-4-1` `s7-4-4-2` `s7-4-4-3` `s7-4-5` `s7-5` `s7-6` `s7-7` `s7-7-1` `s7-7-2` `s7-7-2-1` `s7-7-3` `s7-7-4` `s7-8` `s7-8-1` `s7-8-2` `s7-8-3` `s7-8-3-1` `s7-8-3-2` `s7-8-4` `s7-8-5` `s7-8-5-1` `s7-8-6` `s7-9`. Forty-eight ids.

Eight of the forty-eight carry a fixture whose verdict turns on that section's
own rule. The other forty do not, and the table says so with a leading `—`
rather than a plausible file name. This is the chapter Annex C.9 deletes
outright — "Clause 7 only applies to Verilog-AMS HDL" — so most of what is here
is a boundary marker, not a semantic check, and the count reflects that.

Forty-seven `.va` files: six run and assert, ten are `//! xfail`, thirty-one are
plain `//! reject`. The credit rule used below, stated once so it can be
checked:

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
| `s7-2-2` | assignment context fixes a variable's domain | `continuous_context.va` (`//! lrm 7.2.2`, `3.2`) — the analog-block assignment takes the probe value, 1.25, not the §3.2 initial 0. The discrete half is inventoried by `digital_initial_unsupported.va` and `digital_always_unsupported.va`, both E0205 on the block itself, which *is* the construct 7.2.2 names. `both_contexts_assignment_rejected.va` is **`//! xfail`** |
| `s7-2-3` | nets, ports, signals; a port with two analog connections is an analog port | `analog_port.va` (`//! lrm 7.2.3`, `4.2`) — both ports read through `V()` regardless of direction, checked to the last bit (`-0.49999999999999994`). Only the analog-port row of the classification: digital and mixed ports need two connections, i.e. hierarchy. `hierarchy_unsupported.va` is that shape, and it is refused at E0904 — the child it names is defined nowhere, which is the fixture's own point now that instantiation elaborates |
| `s7-2-4` | node abstol = smallest abstol over the signal's continuous nets | — no fixture. `compatible_disciplines.va` and `custom_disciplines.va` declare `abstol` but never span two disciplines with *different* abstols on one node, and nothing reads back a resolved tolerance |
| `s7-3` | parent: read across domains, write only in your own | — carried by 7.3.1–7.3.7 |
| `s7-3-1` | Table 7-1, discrete types read from a continuous context | `discrete_scalar_bit_unsupported.va` — `I(p) <+ d` on a `wire` is the legal AMS bit-row read; with 7.3.1 gone it is E0315, "net must be read through an access function". That is the boundary and it is exact. Everything else in the row is masked or failing: `discrete_real_from_analog_unsupported.va` dies at E0205 on `initial`, and the three bus-width fixtures are **`//! xfail`**. `analog_reads_integer.va` cites 7.3.1 but its `integer` is assigned *inside* the analog block, so by 7.2.2 it is a continuous variable and no Table 7-1 row applies — what it asserts is §4.2.12 ternary truthiness |
| `s7-3-2` | four features that carry x/z into the analog context | The strongest coverage in the chapter, because half of it is an error in AMS too. `x_literal_unsupported.va`, `z_literal_unsupported.va`, `xz_contribution_rejected.va` and `xz_ordinary_equality_rejected.va` reproduce the four lines the clause's own `converter` example annotates `// error`; all four land on E0130, "x/z digit in a number literal", on the literal itself. `case_equality.va` pins the operator alone as E0323 with no literal to mask it. `x_case_equality_unsupported.va` and `z_case_inequality_unsupported.va` pin `===`/`!==` over an x and a z, where the lexer wins the race and E0323 never appears. `xz_case_statement_unsupported.va` is the `case` form. `xz_casex_statement_unsupported.va` and `xz_casez_statement_unsupported.va` are refused, but only as ``E0209: expected an expression: found `casex` `` — see the code gaps below |
| `s7-3-2-1` | inf and NaN may not reach a branch through contribution | — `inf_contribution.va`, `neg_inf_contribution_rejected.va`, `nan_contribution_rejected.va` are all three **`//! xfail`**. The clause is stated three times and met zero |
| `s7-3-3` | continuous nets probed from a discrete context; interpolation | — no fixture cites it. `digital_probe_unsupported.va` is the clause's `sampler` shape (`always @(p) sampled = V(p);`) but cites 7.3.6.3 and dies at E0205 on `always`, so neither the probe nor the interpolation rule is reached |
| `s7-3-4` | discrete events detected in a continuous context (Syntax 7-2) | `digital_event_unsupported.va` — `@(posedge d)` inside an `analog` block is the discrete-event-in-continuous-context construct, and the parser refuses the `posedge` token itself: `E0209: expected an expression: found posedge`. On-construct, so credited, but the fixture cites 7.3.6.2 and the diagnostic names no rule — see the code gaps |
| `s7-3-5` | continuous events detected in a discrete context (Syntax 7-3) | — `digital_cross_unsupported.va` has the clause's exact `always @(cross(...))` shape but cites 7.3.6.1, and E0205 lands on `always` before the event expression is read |
| `s7-3-6` | parent: synchronization across the digital tick | — host/kernel property, and 8.2 is where the algorithm lives |
| `s7-3-6-1` | analog event in a digital event control, scheduled at the nearest tick | — `digital_cross_unsupported.va`, masked at `always` (E0205). No digital tick exists in this dialect to schedule onto |
| `s7-3-6-2` | digital event in an analog event control, executed at the promoted time | — `digital_event_unsupported.va` is credited to 7.3.4 above: it pins the refusal of the *construct*, and the timing rule this clause states is never reached |
| `s7-3-6-3` | analog primary in a digital expression | — `digital_probe_unsupported.va` and `cross_domain_function_unsupported.va`, both E0205 on `always`. The second is here to record that it is *not* a 7.3.7 violation, contrary to what the file used to claim |
| `s7-3-6-4` | analog event variables driving a continuous assign | — `continuous_assign_unsupported.va` is masked twice over, and not where its header suggests: the diagnostic is `E0205: unsupported module item: found wreal` on the *declaration*, so the `assign` on the next line is never reached either |
| `s7-3-6-5` | digital primary in an analog expression, at the last tick ≤ analog time | — no fixture. `analog_reads_integer.va` was credited here and must not be: its `integer` is written in the analog block, which makes it continuous by 7.2.2, and its own header says so |
| `s7-3-7` | no digital function from analog, no analog function from digital | — `digital_function_from_analog_unsupported.va` (E0205 on the `function` declaration) and `analog_function_from_digital_unsupported.va` (E0205 on `initial`). One sentence each, both masked: the declaration that makes the call illegal is refused before any caller is analysed |
| `s7-4` | parent: assign disciplines to undeclared nets | — needs elaborated hierarchy |
| `s7-4-1` | `resolveto` over an undeclared interconnect's lower connections | — `compatible_disciplines.va` cites 7.4.1 and runs green, but what its `V(p, q)` asserts is the §3.11 Self Rule the clause is *built on*, inside one flat module. The resolution rule proper needs ports, undeclared interconnect and a `connect ... resolveto` statement, none of which are here |
| `s7-4-2` | discrete-time port connections; 1364 rules plus §3.7 for `wreal` | `discrete_discipline.va` cites it for the resolution of a discrete-domain net, but asserts only that the binding is accepted; port connections themselves have no fixture |
| `s7-4-3` | error to connect incompatible continuous disciplines | `incompatible_disciplines_rejected.va` (E0355) against `compatible_disciplines.va`, the positive twin. The clause proper is about a port CONNECTION and needs hierarchy; what the pair states is the §3.11 rule it delegates to, inside one flat module — "ports of continuous-time disciplines … shall obey the rules imposed in 3.11" |
| `s7-4-4` | conflicting discipline declarations for one segment are an error | — `conflicting_discipline_declaration_rejected.va` is **`//! xfail`** |
| `s7-4-4-1` | basic mode: continuous and discrete propagate up, continuous wins | — no fixture here. `annex_f_resolution/hierarchy_resolution.va` is the closest thing in the tree |
| `s7-4-4-2` | detail mode: continuous up then back down, `resolveto` ignored | — no fixture in this tree distinguishes the two modes |
| `s7-4-4-3` | coercion: a declared interconnect discipline wins unless `resolveto` overrides | — no fixture. `resolution_connect_unsupported.va` mentions the clause in prose and pins `connectrules` |
| `s7-4-5` | continuous signals resolve identically under both algorithms | — no fixture; both algorithms agreeing is a statement about hierarchy |
| `s7-5` | connect modules; Syntax 7-4 adds `connectmodule` to `module_keyword` | — the keyword refusal exists but is cited to 7.6, not counted twice. See the row below |
| `s7-6` | connect module descriptions; port disciplines define what is bridged | `connectmodule_unsupported.va` (`//! lrm 7.6`, `C.9`, `C.16`) — ``E0201: construct is not in the supported subset: `connectmodule` ``, on the keyword, with an ordinary module present so the file cannot be refused merely for declaring none. `supply_hierarchical_connectmodule_unsupported.va` produces the identical diagnostic. Table 7-2's direction combinations are untouched |
| `s7-7` | connect specification statements | `connectrules_unsupported.va` (`//! lrm 7.7`, `C.9`, `C.16`) — ``E0201 ... `connectrules` ``, on the keyword. This one row is the whole of 7.7's coverage; see "the E0201 wall" below |
| `s7-7-1` | `connect <module>;` auto-insertion statement | — the form is inside `connectrules_unsupported.va` and is never parsed |
| `s7-7-2` | `connect a, b resolveto c;` | — `resolution_connect_unsupported.va`, same E0201 on the enclosing `connectrules` |
| `s7-7-2-1` | connect rule resolution mechanism | — no fixture; a selection algorithm needs a hierarchy to select in |
| `s7-7-3` | parameter passing attribute, `connect m #(.p(v));` | — `connect_parameter_unsupported.va`, same E0201 |
| `s7-7-4` | `connect_mode` | — `connect_mode_unsupported.va`, same E0201 |
| `s7-8` | automatic insertion at mixed ports | — post-elaboration; no fixture |
| `s7-8-1` | connect module selection per hierarchy level | — no fixture. Previously credited to `connectrules_unsupported.va`, which selects nothing |
| `s7-8-2` | signal segmentation; never more than one analog node per signal | — no fixture |
| `s7-8-3` | `connect_mode` parameter, default `merged` | — `connect_mode_unsupported.va` writes both values but they sit behind the `connectrules` keyword |
| `s7-8-3-1` | `merged`: one shared instance per signal/module/discipline | — same file, unreached text |
| `s7-8-3-2` | `split`: one instance per port | — same file, unreached text |
| `s7-8-4` | driver-receiver segregation and insertion rules | — no fixture; five rules, all about elaborated signals |
| `s7-8-5` | generated instance names, `SigName__ModuleName__BottomDiscipline` | — `connect_generated_defparam_unsupported.va` gets `E0907`: the `defparam` parses now (§6.3.1), and what refuses the file is that the generated instance the path names does not exist, there being no auto-insertion. That is the clause's own precondition, not its naming scheme. The scheme lives entirely in identifier text no compiler interprets, so it is untestable by construction; `connect_generated_split_name_unsupported.va` was the same test with a different identifier and was deleted |
| `s7-8-5-1` | port names for built-in primitives, six gate families | — `primitive_generated_ports_unsupported.va` stops at `E0205 ... found and`, the A.3 gate instance, which is the module item VerA has no production for; the `defparam` beside it is a legal §6.3.1 item now and its own verdict is pinned by the file above. Neither says anything about `in1`. Only the N-input family is written; the other five (N-output, 3- and 4-port MOS, pass switches, single-port) differ by identifier text alone and are recorded here rather than duplicated |
| `s7-8-6` | supply sensitive connect modules | — `connect_supply_unsupported.va` (E0201 on `connectrules`) and `supply_hierarchical_connectmodule_unsupported.va` (E0201 on `connectmodule`). Both refusals are about the enclosing keyword; the supply sensitivity is unreached |
| `s7-9` | driver-receiver segregation | — no fixture. Segregation is a property of an elaborated mixed net |

## The xfail ledger

Eight fixtures in this folder state a rule the compiler does not meet. This is the
most useful thing in the file: each row is a rule the suite asserts and VerA
answers wrongly, and the row disappears the day the defect does. Four are flat
single-module defects VerA could fix without growing a new feature; four need
machinery it does not have.

| Fixture | Section | Reason |
|---|---|---|
| `inf_contribution.va` | `s7-3-2-1` | `I(p) <+ 1.0/0.0` is accepted. VerA emits only W0650, "unit is not provably finite", and stamps the value. 7.3.2.1 makes contributing an infinity illegal |
| `neg_inf_contribution_rejected.va` | `s7-3-2-1` | Same for `-1.0/0.0`. A separate file because a compiler may well diagnose one sign and not the other |
| `nan_contribution_rejected.va` | `s7-3-2-1` | Same for `0.0/0.0`. No run-side check is possible: every comparison against a NaN is false |
| `conflicting_discipline_declaration_rejected.va` | `s7-4-4` | No redeclaration diagnostic: `ch7_conf_a w; ch7_conf_b w;` silently overwrites the first declaration. The clause says conflicting means "more than one discipline regardless of whether the disciplines are compatible", and here they *are* compatible, so a compatibility-only check would not catch it either |
| `both_contexts_assignment_rejected.va` | `s7-2-2` | Masked, not wrong: the `initial` block is refused at E0205 before `sampled` has two domains to conflict over. Unreachable until a digital context exists |
| `discrete_bus_narrow_unsupported.va` | `s7-3-1` | No discrete context. `reg [7:0] r` is E0205 and so is the `initial` driver, so the zero-extension rule (8 ones read as +255, not -1) has no net to be evaluated on |
| `discrete_bus_31_unsupported.va` | `s7-3-1` | Same E0205 wall at the legal boundary: 31 ones must read as +2147483647 with the integer's sign bit forced to zero. The WIDTH half of the rule is now checked — E0222 stays silent at 31 and fires at 32 — so what is left here is the mapping, not the limit |

## The E0201 wall

Five fixtures — `connectrules_unsupported.va`, `connect_mode_unsupported.va`,
`connect_parameter_unsupported.va`, `connect_supply_unsupported.va`,
`resolution_connect_unsupported.va` — differ only in the text inside a
`connectrules ... endconnectrules` block, and all five produce byte-identical
diagnostics: ``E0201: construct is not in the supported subset: `connectrules` ``
pointing at column 1 of the block header. Nothing inside is parsed. That means
7.7.1, 7.7.2, 7.7.3, 7.7.4, 7.8.3 and 7.8.6 are *source inventories*: they
record the spelling of a form the LRM defines, and they pin a verdict that would
be unchanged if the block's body were deleted. They are worth keeping — the
inventory is what stops someone reinventing the syntax when AMS support is
attempted — but crediting them as coverage of the clauses inside the block, as
this file previously did, was false five times over. Each fixture carries a
plain host module so the refusal cannot be about an empty file.

## Code gaps this chapter exposes

Distinct from the xfail ledger: these are rejections with the right verdict and
the wrong message. None fails a test, so none appears above as a debt, but each
is a diagnostic that names no rule.

- `casex`/`casez` (C.7 removes them by name) get three cascading
  `E0209: expected an expression` errors apiece, because the parser has no such
  keyword. `===` has a proper E0323; `casex` has nothing of the shape.
- `posedge` inside an analog event control gets `E0209: expected an expression`.
  E0704, "posedge/negedge is digital-only", exists in `src/diag_code.zig` and
  never fires here — the parser reaches the token first. E0704 is pinned nowhere
  in this folder.
- `x_case_equality_unsupported.va` and `z_case_inequality_unsupported.va` want
  E0323 for the operator but get E0130 for the literal, because the lexer wins.
  That is why `case_equality.va` exists with no x/z literal in it.
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

Almost all of 7.4.4 through 7.9 is unreachable from a single flat module: it is
about elaborated hierarchy, discipline propagation and post-elaboration
insertion. Those empty rows are the shape of the language boundary, not a debt
against VerA, and they stay empty until this is a Verilog-AMS compiler with an
elaborator. The rows that *are* debt and not boundary are the ten in the ledger
— and of those, the three in 7.3.2.1 need nothing from AMS at all: a finiteness
check on a contributed value is a flat, single-module rule that VerA currently
answers with a warning.
