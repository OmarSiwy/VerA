# Chapter 6 coverage

Source: `docs/VAMS-LRM/ch6-hierarchy.html`, read section by section.

HTML section-ID audit: `s6.1` `s6.2` `s6.2.1` `s6.2.2` `s6.3` `s6.3.1` `s6.3.2` `s6.3.3` `s6.3.4` `s6.3.5` `s6.3.6` `s6.4` `s6.4.1` `s6.4.2` `s6.4.3` `s6.5` `s6.5.1` `s6.5.2` `s6.5.2.1` `s6.5.2.2` `s6.5.3` `s6.5.4` `s6.5.5` `s6.5.6` `s6.5.7` `s6.5.7.1` `s6.5.7.2` `s6.5.8` `s6.6` `s6.6.1` `s6.6.2` `s6.6.2.1` `s6.6.3` `s6.7` `s6.7.1` `s6.8` `s6.9` `s6.9.1` `s6.9.2` `s6.9.3` `s6.9.4`.

Twenty-nine of the forty-one sections carry a fixture that asserts something about
that section. Twelve do not, and their rows are empty rather than filled with a
plausible name. Eighty-two `.va` files live here; **forty of them are
`//! xfail`**, which is the highest ratio in the suite and is the honest reading of
this chapter: Clause 6 is about *hierarchy*, and VerA compiles exactly one flat
module. Every fixture that needs a second module instance fails at the module
instantiation, before the rule it was written for is ever reached.

An `//! xfail` here is a fixture the LRM says should pass and this compiler fails.
A plain `//! reject` is a fixture whose *rejection* is correct conformance and
which VerA already gets right — nine of them do, and several say in their own
headers that they arrive at the right verdict by the wrong road (a parse boundary
rather than the semantic rule). The table below marks the road where it differs
from the rule.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s6.1` | overview: modules embedded in modules, communicating through ports | — no fixture. Every normative sentence here is restated in 6.2–6.5 and tested there; the section itself has no separate oracle |
| `s6.2` | `module`/`endmodule`, module items, the two header forms | `module_definition.va` (no port list at all), `nonansi_ports.va` (bare `list_of_ports` + body direction declarations), `output_port.va` (ANSI header), `multiple_analog_blocks.va`, `port_direction_not_a_port_rejected.va` (`//! reject E0206` — a direction declaration may only name a header port; VerA diagnoses this *at the rule*), `ansi_port_redeclared_rejected.va` — **`//! xfail`**: VerA silently folds a body redeclaration of an ANSI port onto the header one. Both remaining header forms are green: `parameter_port_list.va` (A.1.3 `module_parameter_port_list`, two header parameters at their declared defaults with `$param_given` 0) and `macromodule_unsupported.va` (§6.2's interchangeable keyword — the name is now a misnomer) |
| `s6.2.1` | top-level modules and `$root` | `top_level_module.va` (nothing instantiates it: `$mfactor` = 1.0, `$param_given` = 0), `root_reference_unsupported.va` — **`//! xfail`**: no `hierarchical_identifier`, the `.` after `$root` is E0207, and the two instantiations the path names are E0204 anyway |
| `s6.2.2` | module instantiation, instance arrays, several instances per statement | all nine **`//! xfail`** for the same reason — E0204 "module instantiation is not supported": `module_instantiation_unsupported.va`, `multiple_instances_unsupported.va` (`first(p,n), second(n,p)` in one statement), `instance_array_unsupported.va` (`u[0:1]`), `named_port_instantiation_unsupported.va`, `parameterized_instantiation_unsupported.va`, `named_parameter_instantiation_unsupported.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va` |
| `s6.3` | the three override mechanisms | `three_dependent_parameters.va` is the only run-and-pass fixture citing it, and it covers the *dependence* half. `defparam_unsupported.va`, `parameterized_instantiation_unsupported.va`, `named_parameter_instantiation_unsupported.va` — all **`//! xfail`** at E0204. `parameter_default.va` is the no-override baseline but cites `3.4`, not this clause |
| `s6.3.1` | `defparam`, and its precedence over an instance assignment | `defparam_unsupported.va` — **`//! xfail`**: the instantiation the `defparam` targets is E0204 first; a bare `defparam` is E0205 |
| `s6.3.2` | assignment by order follows parameter declaration order | `parameterized_instantiation_unsupported.va` (`#(2.0, 3.0)` onto `gain`, `offset`) — **`//! xfail`** at E0204. It cites `6.3`, not this id; credited on content |
| `s6.3.3` | assignment by name links parameter name to value | `named_parameter_instantiation_unsupported.va` (`#(.offset(3.0))`, asserts `gain` keeps its default and `$param_given(gain)` stays 0) — **`//! xfail`** at E0204. Also cites `6.3`, not this id |
| `s6.3.4` | a parameter's default may be an expression over earlier parameters | `dependent_parameters.va` (two levels, `width`→`area`→`conductance`), `three_dependent_parameters.va`, `localparam_dependency.va` (a `localparam` tracks the overridden parameter), `dependent_parameter_transcendental.va` (`exp(a)`, asserted beside a `2.0*a` control — the clause puts no restriction on which operators a dependent default may use, and `codegen`'s `f64Const` now renders the whole of Table 4-14 and Table 4-15, not only arithmetic) |
| `s6.3.5` | `$param_given` | `param_given.va` (with `//! param gain = 2.0`), `param_given_absent.va` (same source shape, no override) |
| `s6.3.6` | hierarchical system parameters: `$mfactor` and the geometry set | `mfactor.va`, `mfactor_flow_contribution.va`, `mfactor_flow_probe.va`, `mfactor_conditional_only.va` (the LRM's own `r/$mfactor` short-out guard), `geometric_system_parameters.va` (`$xposition`, `$yposition`, `$angle`, `$hflip`, `$vflip`); `mfactor_propagation_unsupported.va` — **`//! xfail`** at E0204, `mfactor_double_scaling_rejected.va` — **`//! xfail`**: VerA emits no diagnostic at all for a model that multiplies its own contribution by `$mfactor`. See the boundary note below: the passing `mfactor_*` files pin only the top-level identity |
| `s6.4` | paramsets | `paramset_unsupported.va` — **`//! xfail`**: the paramset instantiation is E0204 and the `paramset` declaration itself E0201 |
| `s6.4.1` | the `.module_parameter_identifier = expr;` assignment form | `paramset_unsupported.va` writes `.k = 2.0 * gain;` — **`//! xfail`**, same two diagnostics. No fixture cites this id; credited on content |
| `s6.4.2` | overload selection by parameter range | `paramset_overload_unsupported.va` (two paramsets on one module, `l = 0.5` admitted by exactly one) — **`//! xfail`**, E0204/E0201 |
| `s6.4.3` | paramset output variables | `paramset_output_unsupported.va` — **`//! xfail`**, E0204/E0201 |
| `s6.5` | ports interconnect module instances | — parent sentence; it is about instantiation, so nothing here reaches it. Carried in part by 6.5.2–6.5.6 below |
| `s6.5.1` | Syntax 6-5: `port_expression` may be a net, a bit select, a part select or a concatenation; `.port_id(expr)` in the header | — no fixture. Every header in this folder uses the simple-identifier form. The concatenation, sub-range and `.name(expr)` header forms are written nowhere |
| `s6.5.2` | type and direction of each header port are declared in the body | `nonansi_ports.va`, `ansi_ports.va` (the other header form), `port_direction_not_a_port_rejected.va` (`//! reject E0206`) |
| `s6.5.2.1` | a port's type is its discipline; an undeclared-discipline port is structural-only | `typed_ports.va` (`electrical` and `thermal` on one module, `V()` and `Temp()`), `ansi_ports.va`, `input_port.va`, `inout_port.va`; `untyped_port_behavioral_use_rejected.va` — **`//! xfail`**: VerA accepts `V(q)` on a port that has a direction but no discipline, with no diagnostic |
| `s6.5.2.2` | `input`/`output`/`inout`; Syntax 6-7's direction-declaration shape; identical ranges across the two declarations | `port_directions.va` (all three in one module), `input_port.va`, `output_port.va`, `inout_port.va`, `ansi_ports.va`; `real_port_unsupported.va` (`//! reject E0208` — `real` is neither a `net_type` nor `wreal`, so the source has no production even in full AMS), `vector_ports.va` (`//! reject E0350` — the clause's own printed error case, `[3:0]` against `[0:3]`), `vector_ports_range_equal.va` (the clause's own printed VALID case, `[0:3]` against `[0:4-1]`, which passes because both bounds are FOLDED before they are compared). The two together are the whole clause, and they differ only in whether the folded bounds agree |
| `s6.5.3` | real-valued ports via net type `wreal` | — no fixture, deliberately. `real_port_unsupported.va` says in its own header that it does *not* reach this clause: pinning it needs `input wreal x;`, which is legal AMS, so a rejection fixture would be inverted for any AMS compiler |
| `s6.5.4` | connection by ordered list follows the definition's port order | `module_instantiation_unsupported.va`, `port_connected.va`, `multiple_instances_unsupported.va`, `instance_array_unsupported.va`, `blank_ordered_connection_unsupported.va` (a blank element, `u(p, , n)`) — all **`//! xfail`** at E0204. None cites this id; credited on content |
| `s6.5.5` | connection by name; the expression is optional; order and name may not be mixed | `named_port_instantiation_unsupported.va` (`.b(n), .a(p)` — name beats position), `empty_named_connection_unsupported.va` (`.mid()`), `omitted_named_connection_unsupported.va` — all **`//! xfail`** at E0204. The *mixing* prohibition is written nowhere |
| `s6.5.6` | `$port_connected` | `port_connected.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va` — all **`//! xfail`** at E0204. The three ways a port can be left unconnected are each written down; none of them runs |
| `s6.5.7` | ports on one net shall be of compatible disciplines | — no fixture. Needs two instances on a shared net |
| `s6.5.7.1` | matching size rule: port width equals net width at the connection | — no fixture. `vector_ports.va` is *not* this rule: it compares a port's own two declarations against each other (6.5.2.2), not a port against the net it is connected to. The previous version of this file credited it here; that was wrong |
| `s6.5.7.2` | discipline of an undeclared interconnect signal | — no fixture. The resolution machinery is `tests/fixtures/annex_f_resolution/`, and it needs instantiation to reach |
| `s6.5.8` | a node's abstol is the smallest over all disciplines on it | — no fixture. `typed_ports.va` has two disciplines but on two *separate* ports, with no shared node and no abstol assertion, so it does not reach this rule either |
| `s6.6` | generate regions, and what a generate block may contain | `generate_region.va` (`//! reject E0221` — Syntax 6-8 has no bare `generate_block` directly in a region; rejection at the rule). Green behavioural coverage: `generate_if*.va`, `generate_loop*.va`, `generate_implicit_localparam.va`, `generate_direct_nesting.va` (a generate block holds `module_or_generate_item`s, so `analog` inside one is fine), and `generate_implicit_region_unsupported.va`, which is `generate_if.va` with the two keywords deleted and pins §6.6's "no semantic difference". `generate_parameter_declaration_rejected.va` — **`//! xfail`**: VerA accepts a `parameter` inside a generate block, which Syntax 6-8 forbids. `generate_nested_region_rejected.va` — **`//! xfail`**: a `generate` inside a `generate` elaborates silently. `generate_nonconstant_rejected.va` — **`//! xfail`**: no constant-expression check on an if-generate scheme |
| `s6.6.1` | loop generate: genvar, the three-part scheme, the implicit localparam, the instance array name | `generate_mismatched_genvar_rejected.va` (`//! reject E0419`), `generate_nonconstant_init_rejected.va` (E0417), `generate_nonconstant_condition_rejected.va` (E0418), `genvar_init_self_reference_rejected.va` (E0417), `generate_nonterminating_rejected.va` (E0420), `genvar_outside_loop_rejected.va` (E0314 — right verdict, adjacent reason: VerA never puts a genvar in the analog scope). Green: `generate_loop.va`, `generate_loop_descending.va`, `generate_two_loops.va`, `generate_implicit_localparam.va` — the last pins the implicit localparam, which falls out of `Lower.tryUnrollFor` binding the genvar as a constant for the duration of each unrolled copy. `generate_array_name_conflict_rejected.va` — **`//! xfail`**: a named block's instance array is not declared in module scope, so `begin : g` and `real g;` coexist. This row is the one place in the chapter where the reject side is genuinely healthy: five E04xx codes fire at the rule |
| `s6.6.2` | conditional generate, `if`/`case`, one alternative selected | `external_genblk_reference_unsupported.va` (`//! reject DiagnosticsReported` — an unnamed generate block's declarations are not hierarchically reachable from module scope; correct rejection, reached at the `.` in E0207). Green: `generate_if.va`, `generate_if_true.va`, `generate_if_false.va`, `generate_direct_nesting.va` (`else if` chain, all three arms named `selected`; the chain needs no grammar of its own — an if_generate_construct is itself a `module_or_generate_item`). `generate_case_unsupported.va` — **`//! xfail`**: case_generate_construct is the one scheme still missing, E0205 "unsupported module item: found `case`"; `generate_block_name_collision_rejected.va` and `generate_block_shadows_declaration_rejected.va` — **`//! xfail`**: a conditional generate block's name is not registered in the enclosing scope at all |
| `s6.6.2.1` | dynamic (swept) parameters and structure-affecting conditions | — no fixture. The clause is permissive ("an implementation *may* choose to limit"), so there is no rule to fail |
| `s6.6.3` | external names `genblk1`, `genblk02` for unnamed blocks | `external_genblk_reference_unsupported.va`. It pins the reachable half — that the HDL path built from those names is illegal — and says so; the names themselves are a VPI/user-interface property with no in-HDL oracle |
| `s6.7` | hierarchical names | `root_reference_unsupported.va`, `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va` — all **`//! xfail`**: VerA's parser has no `hierarchical_identifier`, so every `.` is E0207, and every instantiation these paths refer to is E0204 |
| `s6.7.1` | branches, parameters and analog functions may be referenced hierarchically; analog *variables* may not; parameter declarations may not make OOMRs | the three prohibitions are all covered and all pass: `oomr_variable_read_rejected.va` (`//! reject E0207`), `oomr_variable_assign_rejected.va` (E0214), `oomr_in_parameter_declaration_rejected.va` (E0207). The three permissions are all **`//! xfail`**: `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va`. Today one parser gap produces both verdicts — see the note below |
| `s6.8` | six scope-creating constructs; one declaration per identifier per scope; upward search stopping at a module boundary | `local_scope_shadow.va` (inner block reads the enclosing variable), `local_scope_declaration_shadow.va` (inner declaration shadows it, and the outer value survives the block). The uniqueness half is all **`//! xfail`**: `duplicate_declaration_rejected.va` (two `real value;` in one scope, silently accepted), `generate_array_name_conflict_rejected.va`, `generate_block_shadows_declaration_rejected.va` |
| `s6.9` | elaboration binds instances, computes parameters, resolves names | — parent definition; nothing single-module asserts it |
| `s6.9.1` | multiple analog blocks concatenate in source order, after generate evaluation | `multiple_analog_blocks.va` covers the plain case (three blocks, an accumulator threaded through them) but cites `6.2`/`4.5.3`, not this id. The two files that *do* cite it are the after-generate half and both are green: `generate_two_loops.va` (two loops, region order, no interleaving), `generate_loop_descending.va` (unroll order determines concatenation order) |
| `s6.9.2` | paramset selection happens after generate evaluation | — no fixture. Needs a paramset instantiated inside a generate construct, i.e. both of this chapter's largest gaps at once |
| `s6.9.3` | connect-module insertion is post-elaboration | — no fixture; the clause defers to 7.8 and belongs to `tests/fixtures/ch07_mixed_signal/` |
| `s6.9.4` | the defparam/generate elaboration-order algorithm | `oomr_in_parameter_declaration_rejected.va` (`//! reject E0207`) pins the one consequence reachable from a single module: a parameter default may not read another instance, because parameter values are computed during elaboration. The algorithm itself needs a hierarchy |

## The xfail ledger

Forty of the eighty-two fixtures run and fail. They are not forty
independent defects — they are five, and the fixtures are the receipts. Each group
disappears in one commit.

| Cause | Count | Fixtures |
|---|---|---|
| **E0204 — no module instantiation.** VerA compiles one flat module. Everything hierarchical in Clause 6 stops on the first instantiation statement, before the rule under test. The three `paramset_*` files additionally hit E0201 on the `paramset` keyword itself; `defparam_unsupported.va` additionally has E0205 for a bare `defparam`. | 15 | `module_instantiation_unsupported.va`, `multiple_instances_unsupported.va`, `instance_array_unsupported.va`, `named_port_instantiation_unsupported.va`, `parameterized_instantiation_unsupported.va`, `named_parameter_instantiation_unsupported.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va`, `port_connected.va`, `defparam_unsupported.va`, `mfactor_propagation_unsupported.va`, `paramset_unsupported.va`, `paramset_overload_unsupported.va`, `paramset_output_unsupported.va` |
| **Missing semantic check — VerA accepts what the LRM forbids.** No diagnostic at all is produced. The worst failure mode in the set: a wrong model compiles clean. | 10 | `duplicate_declaration_rejected.va` (two declarations, one scope), `ansi_port_redeclared_rejected.va` (ANSI port redeclared in the body), `untyped_port_behavioral_use_rejected.va` (`V()` on a discipline-less port), `generate_array_name_conflict_rejected.va`, `generate_block_name_collision_rejected.va`, `generate_block_shadows_declaration_rejected.va` (generate block names never enter the enclosing scope), `generate_nested_region_rejected.va` (region inside a region), `generate_nonconstant_rejected.va` (no constant check on a generate scheme), `generate_parameter_declaration_rejected.va` (`parameter` inside a generate block), `mfactor_double_scaling_rejected.va` (a model that multiplies its own contribution by `$mfactor`) |
| **E0207 — no `hierarchical_identifier`.** The parser has no production for a dotted name, so every out-of-module reference stops at the `.`. | 4 | `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va`, `root_reference_unsupported.va` |
| **Assorted single parser/codegen gaps**, one fixture each. | 2 | `generate_case_unsupported.va` (E0205: no case_generate_construct), `dependent_parameter_transcendental.va` (`codegen`'s `f64Const` has no `exp`, so a transcendental dependent parameter stays frozen at its default) |

## Reject polarity: the right verdict by the wrong road

Nine fixtures carry `//! reject` without `//! xfail` — VerA already gets them
right. Four of those nine reach the verdict through a diagnostic that has nothing to
do with the rule, and each says so in its own header:

- `real_port_unsupported.va` — E0208 at the port direction declaration: `real` is neither a `net_type` nor `wreal`, so the parser has no shape there and everything else stops.
- `external_genblk_reference_unsupported.va` — §6.6.2 forbids the hierarchical path; VerA refuses the `.` (E0207).
- `oomr_in_parameter_declaration_rejected.va` and `oomr_variable_read_rejected.va` — also E0207 on the `.`, which is exactly why they must sit next to `oomr_parameter_unsupported.va` and `oomr_branch_probe_unsupported.va`: today *one* diagnostic covers both the permitted and the forbidden case, and the day hierarchical names resolve, these two must keep failing while their three siblings start passing.

The ones that diagnose at the rule are `port_direction_not_a_port_rejected.va`
(E0206), `vector_ports.va` (E0350 — §6.5.2.2's own comparison, on folded bounds;
it used to die at E0208 for the unparsed range and its header records the move),
`generate_region.va` (E0221 — Syntax 6-8 reaches a `generate_block` only
through a `for` or an `if`, never directly; it used to die at the `analog` keyword
instead and its header records the move) and, in 6.6.1, the E04xx family (`generate_mismatched_genvar_rejected.va`,
`generate_nonconstant_init_rejected.va`, `generate_nonconstant_condition_rejected.va`,
`genvar_init_self_reference_rejected.va`, `generate_nonterminating_rejected.va`).
Loop-generate scheme validation is the one part of this chapter VerA implements
properly. `genvar_outside_loop_rejected.va` is adjacent: E0314 "unknown identifier"
is the same answer a compiler with no genvar concept at all would give.

## `$mfactor`: what the passing fixtures do and do not pin

VerA lowers `$mfactor` to the constant 1.0. It carries no instance multiplicity and
performs no automatic scaling of flow contributions, flow probes, or noise. At the
top of the hierarchy Table 9-29 fixes `$mfactor` at exactly 1.0, so the run
fixtures — `mfactor.va`, `mfactor_flow_contribution.va`, `mfactor_flow_probe.va`,
`mfactor_conditional_only.va`, `mfactor_flow_noise.va`, `mfactor_potential_noise.va`
— assert the correct conformant answers *for a top-level instance*, and would keep
asserting them under a tool that implements multiplicity fully. They pin the
identity case, not the scaling rule. The scaling rule is
`mfactor_propagation_unsupported.va` (1.0 × 2.0 × 7.0 = 14.0 down a three-deep
chain) and it is **`//! xfail`** at E0204.

## Fixtures in this folder that cite another chapter

Three files live here for topical reasons but their `//! lrm` cites are elsewhere,
and they are not counted against any row above:

- `parameter_default.va` (`3.4`) — the un-overridden declared default, the baseline the 6.3 override fixtures are measured against.
- `mfactor_flow_noise.va`, `mfactor_potential_noise.va` (`9.18`, `4.6.4`) — they assert Table 9-29's top-level `$mfactor` = 1.0 and that `white_noise` returns 0 outside a noise analysis. The `$mfactor`-scales-noise rule of 6.3.6 needs a noise analysis *and* a non-unit multiplicity, and neither exists here.
