# Chapter 6 coverage

Source: `docs/VAMS-LRM/ch6-hierarchy.html`, read section by section.

HTML section-ID audit: `s6.1` `s6.2` `s6.2.1` `s6.2.2` `s6.3` `s6.3.1` `s6.3.2` `s6.3.3` `s6.3.4` `s6.3.5` `s6.3.6` `s6.4` `s6.4.1` `s6.4.2` `s6.4.3` `s6.5` `s6.5.1` `s6.5.2` `s6.5.2.1` `s6.5.2.2` `s6.5.3` `s6.5.4` `s6.5.5` `s6.5.6` `s6.5.7` `s6.5.7.1` `s6.5.7.2` `s6.5.8` `s6.6` `s6.6.1` `s6.6.2` `s6.6.2.1` `s6.6.3` `s6.7` `s6.7.1` `s6.8` `s6.9` `s6.9.1` `s6.9.2` `s6.9.3` `s6.9.4`.

Thirty-three of the forty-one sections carry a fixture that asserts something about
that section (row-counted from the table below). Eight do not, and their rows are empty rather than filled with a
plausible name. Eighty-two `.va` files live here: **24 carry a `//! reject` arm, 58 run
and assert, and NONE is `//! xfail`** (grep-measured over this directory). This paragraph
used to say forty of the eighty-two were xfail — "the highest ratio in the suite" — on the
grounds that Clause 6 is about *hierarchy* and VerA compiled exactly one flat module, so
every fixture needing a second instance died at the instantiation before its rule was
reached. That is dead: `ir/elaborate.zig` flattens the instance tree, E0204 is retired, and
this is now the largest single closure in the suite. Note also that the forty was never
measured — 28 was the number in the tree when the claim was written.

One fixture here is CANNOT RUN rather than pass: `module_definition.va`, which has no port
list at all (A.1.2 permits it), so the device contract has nothing to stamp. That is a host
limitation and not a conformance result; `--strict` fails on it so it cannot be carried
quietly.

A `//! reject` fixture here is one whose *rejection* is correct conformance, and several
say in their own headers that they arrive at the right verdict by the wrong road (a parse
boundary rather than the semantic rule). The table below marks the road where it differs
from the rule.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s6.1` | overview: modules embedded in modules, communicating through ports | — no fixture. Every normative sentence here is restated in 6.2–6.5 and tested there; the section itself has no separate oracle |
| `s6.2` | `module`/`endmodule`, module items, the two header forms | `module_definition.va` (no port list at all), `nonansi_ports.va` (bare `list_of_ports` + body direction declarations), `output_port.va` (ANSI header), `multiple_analog_blocks.va`, `port_direction_not_a_port_rejected.va` (`//! reject E0206` — a direction declaration may only name a header port; VerA diagnoses this *at the rule*), `ansi_port_redeclared_rejected.va` — green (`//! reject E0218`): a body redeclaration of an ANSI port is refused rather than silently folded onto the header one. Both remaining header forms are green: `parameter_port_list.va` (A.1.3 `module_parameter_port_list`, two header parameters at their declared defaults with `$param_given` 0) and `macromodule_unsupported.va` (§6.2's interchangeable keyword — the name is now a misnomer) |
| `s6.2.1` | top-level modules and `$root` | `top_level_module.va` (nothing instantiates it: `$mfactor` = 1.0, `$param_given` = 0), `root_reference_unsupported.va` — green: `$root.` parses as part 0 of a `hier_ident` and `Lower.flatName` drops it (plus the top module's own name, §6.7's "absolute name" spelling), which is what makes the unprefixed path take the LOCAL scope and the prefixed one the root |
| `s6.2.2` | module instantiation, instance arrays, several instances per statement | all nine GREEN now that `ir/elaborate.zig` flattens the instance tree: `module_instantiation_unsupported.va`, `multiple_instances_unsupported.va` (`first(p,n), second(n,p)` in one statement), `instance_array_unsupported.va` (`u[0:1]`), `named_port_instantiation_unsupported.va`, `parameterized_instantiation_unsupported.va`, `named_parameter_instantiation_unsupported.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va`. The two last-named files say in their own headers what they still do NOT assert: the instance COUNT, which needs a read-back of what a child stamped |
| `s6.3` | the three override mechanisms | `three_dependent_parameters.va` is the only run-and-pass fixture citing it, and it covers the *dependence* half. `parameterized_instantiation_unsupported.va` and `named_parameter_instantiation_unsupported.va` are green (order and name); `defparam_unsupported.va` is green too: §6.3.1's precedence over an instance assignment holds. `parameter_default.va` is the no-override baseline but cites `3.4`, not this clause |
| `s6.3.1` | `defparam`, and its precedence over an instance assignment | `defparam_unsupported.va` — green, and it is the precedence that is asserted: the instance says `#(.gain(2.0))` and the defparam says 5.0, so 5.0 is the only conforming answer. `annex_a_syntax/12_defparam.va` is the plain case. A path that names no parameter of the elaborated design is E0907 (`ch07_mixed_signal/connect_generated_defparam_unsupported.va`) |
| `s6.3.2` | assignment by order follows parameter declaration order | `parameterized_instantiation_unsupported.va` (`#(2.0, 3.0)` onto `gain`, `offset`) — green. It cites `6.3`, not this id; credited on content |
| `s6.3.3` | assignment by name links parameter name to value | `named_parameter_instantiation_unsupported.va` (`#(.offset(3.0))`, asserts `gain` keeps its default and `$param_given(gain)` stays 0) — green. Also cites `6.3`, not this id |
| `s6.3.4` | a parameter's default may be an expression over earlier parameters | `dependent_parameters.va` (two levels, `width`→`area`→`conductance`), `three_dependent_parameters.va`, `localparam_dependency.va` (a `localparam` tracks the overridden parameter), `dependent_parameter_transcendental.va` (`exp(a)`, asserted beside a `2.0*a` control — the clause puts no restriction on which operators a dependent default may use, and `codegen`'s `f64Const` now renders the whole of Table 4-14 and Table 4-15, not only arithmetic) |
| `s6.3.5` | `$param_given` | `param_given.va` (with `//! param gain = 2.0`), `param_given_absent.va` (same source shape, no override) |
| `s6.3.6` | hierarchical system parameters: `$mfactor` and the geometry set | `mfactor.va`, `mfactor_flow_contribution.va`, `mfactor_flow_probe.va`, `mfactor_conditional_only.va` (the LRM's own `r/$mfactor` short-out guard), `geometric_system_parameters.va` (`$xposition`, `$yposition`, `$angle`, `$hflip`, `$vflip`); `mfactor_propagation_unsupported.va` — green: the three-deep `.$mfactor` chain is carried as an EXPRESSION down the flatten, so §9.18's product needs no folding. `mfactor_double_scaling_rejected.va` — green: E0912, whose predicate is the clause's own sentence, a FLOW contribution whose contributed value is a product with `$mfactor` as a factor. That is what keeps `mfactor_conditional_only.va` (the read is in a guard) and `mfactor.va` (`V(p) + 0.0*$mfactor` — the factor multiplies an addend, not the current) legal |
| `s6.4` | paramsets | `paramset_unsupported.va` — green: the declaration is parsed (`Parser.parseParamset`) and an instance naming it elaborates the module it specializes, with the paramset's own parameters flattened in one level below the instance as localparams |
| `s6.4.1` | the `.module_parameter_identifier = expr;` assignment form | `paramset_unsupported.va` writes `.k = 2.0 * gain;` and asserts 6.0 with the instance overriding `gain` to 3.0 — green, and it is the two-level order that is pinned (the instance overrides the paramset, the paramset computes the module's). No fixture cites this id; credited on content |
| `s6.4.2` | overload selection by parameter range | `paramset_overload_unsupported.va` (two paramsets on one module, `l = 0.5` admitted by exactly one) — green. Two of the clause's criteria are applied: an override must name a parameter the paramset declares, and every value must lie in that paramset's declared ranges. A set where nothing survives is E0911; the rest of §6.4.2's tie-breaking is unimplemented and a tie takes the first |
| `s6.4.3` | paramset output variables | `paramset_output_unsupported.va` — green on everything it asserts, which is everything §6.4.3's rule is computed FROM (the module's own output variable and the parameter the paramset set). The output variable itself is parsed and DROPPED: it is a value a host REPORTS for the instance and there is no operating-point reporting path to put it in. The file says so in its own header |
| `s6.5` | ports interconnect module instances | — parent sentence, now reached: 6.5.4–6.5.6 below all run |
| `s6.5.1` | Syntax 6-5: `port_expression` may be a net, a bit select, a part select or a concatenation; `.port_id(expr)` in the header | — no fixture. Every header in this folder uses the simple-identifier form. The concatenation, sub-range and `.name(expr)` header forms are written nowhere |
| `s6.5.2` | type and direction of each header port are declared in the body | `nonansi_ports.va`, `ansi_ports.va` (the other header form), `port_direction_not_a_port_rejected.va` (`//! reject E0206`) |
| `s6.5.2.1` | a port's type is its discipline; an undeclared-discipline port is structural-only | `typed_ports.va` (`electrical` and `thermal` on one module, `V()` and `Temp()`), `ansi_ports.va`, `input_port.va`, `inout_port.va`; `untyped_port_behavioral_use_rejected.va` — green (`//! reject DiagnosticsReported`): `V(q)` on a port that has a direction but no discipline is diagnosed |
| `s6.5.2.2` | `input`/`output`/`inout`; Syntax 6-7's direction-declaration shape; identical ranges across the two declarations | `port_directions.va` (all three in one module), `input_port.va`, `output_port.va`, `inout_port.va`, `ansi_ports.va`; `real_port_unsupported.va` (`//! reject E0208` — `real` is neither a `net_type` nor `wreal`, so the source has no production even in full AMS), `vector_ports.va` (`//! reject E0350` — the clause's own printed error case, `[3:0]` against `[0:3]`), `vector_ports_range_equal.va` (the clause's own printed VALID case, `[0:3]` against `[0:4-1]`, which passes because both bounds are FOLDED before they are compared). The two together are the whole clause, and they differ only in whether the folded bounds agree |
| `s6.5.3` | real-valued ports via net type `wreal` | — no fixture, deliberately. `real_port_unsupported.va` says in its own header that it does *not* reach this clause: pinning it needs `input wreal x;`, which is legal AMS, so a rejection fixture would be inverted for any AMS compiler |
| `s6.5.4` | connection by ordered list follows the definition's port order | `module_instantiation_unsupported.va`, `port_connected.va`, `multiple_instances_unsupported.va`, `instance_array_unsupported.va`, `blank_ordered_connection_unsupported.va` (a blank element, `u(p, , n)`) — all green. None cites this id; credited on content |
| `s6.5.5` | connection by name; the expression is optional; order and name may not be mixed | `named_port_instantiation_unsupported.va` (`.b(n), .a(p)` — name beats position), `empty_named_connection_unsupported.va` (`.mid()`), `omitted_named_connection_unsupported.va` — all green. The *mixing* prohibition is diagnosed (E0906) but written in no fixture |
| `s6.5.6` | `$port_connected` | `port_connected.va`, `blank_ordered_connection_unsupported.va`, `empty_named_connection_unsupported.va`, `omitted_named_connection_unsupported.va` — all green. The three ways a port can be left unconnected are each written down and each runs; the 1 for a net with no other connections is pinned separately |
| `s6.5.7` | ports on one net shall be of compatible disciplines | — no fixture. Needs two instances on a shared net |
| `s6.5.7.1` | matching size rule: port width equals net width at the connection | — no fixture. `vector_ports.va` is *not* this rule: it compares a port's own two declarations against each other (6.5.2.2), not a port against the net it is connected to. The previous version of this file credited it here; that was wrong |
| `s6.5.7.2` | discipline of an undeclared interconnect signal | — no fixture here. The resolution machinery is `tests/fixtures/annex_f_resolution/`; instantiation reaches it now and `annex_f_resolution/hierarchy_resolution.va` is green on the §7.4 traversal itself |
| `s6.5.8` | a node's abstol is the smallest over all disciplines on it | — no fixture. `typed_ports.va` has two disciplines but on two *separate* ports, with no shared node and no abstol assertion, so it does not reach this rule either |
| `s6.6` | generate regions, and what a generate block may contain | `generate_region.va` (`//! reject E0221` — Syntax 6-8 has no bare `generate_block` directly in a region; rejection at the rule). Green behavioural coverage: `generate_if*.va`, `generate_loop*.va`, `generate_implicit_localparam.va`, `generate_direct_nesting.va` (a generate block holds `module_or_generate_item`s, so `analog` inside one is fine), and `generate_implicit_region_unsupported.va`, which is `generate_if.va` with the two keywords deleted and pins §6.6's "no semantic difference". The three validation rules of the clause now diagnose at the rule: `generate_parameter_declaration_rejected.va` (`//! reject E0229` — `module_or_generate_item` admits `localparam` and no `parameter`; the gate is keyed on the keyword so the permitted form still elaborates), `generate_nested_region_rejected.va` (E0228 — one counter over regions AND construct bodies, so "may only occur directly within a module" is checked in both directions, and the inner region is then parsed transparently so the file reports this rule alone), `generate_nonconstant_rejected.va` (E0428 — the scheme must be a constant expression; a `parameter` is one, a module variable is not) |
| `s6.6.1` | loop generate: genvar, the three-part scheme, the implicit localparam, the instance array name | `generate_mismatched_genvar_rejected.va` (`//! reject E0419`), `generate_nonconstant_init_rejected.va` (E0417), `generate_nonconstant_condition_rejected.va` (E0418), `genvar_init_self_reference_rejected.va` (E0417), `generate_nonterminating_rejected.va` (E0420), `genvar_outside_loop_rejected.va` (E0314 — right verdict, adjacent reason: VerA never puts a genvar in the analog scope). Green: `generate_loop.va`, `generate_loop_descending.va`, `generate_two_loops.va`, `generate_implicit_localparam.va` — the last pins the implicit localparam, which falls out of `Lower.tryUnrollFor` binding the genvar as a constant for the duration of each unrolled copy. `generate_array_name_conflict_rejected.va` (`//! reject E0230` — the instance array name is a declaration of the module scope, so it collides with `real g;`; checked at the end of the module, because the colliding declaration may follow the construct). This row is the one place in the chapter where the reject side is genuinely healthy: six codes fire at the rule |
| `s6.6.2` | conditional generate, `if`/`case`, one alternative selected | `external_genblk_reference_unsupported.va` (`//! reject DiagnosticsReported` — an unnamed generate block's declarations are not hierarchically reachable from module scope; correct rejection, reached at the `.` in E0207). Green: `generate_if.va`, `generate_if_true.va`, `generate_if_false.va`, `generate_direct_nesting.va` (`else if` chain, all three arms named `selected`; the chain needs no grammar of its own — an if_generate_construct is itself a `module_or_generate_item`). `generate_case_unsupported.va` — green: case_generate_construct parses (gated on being inside a generate, since `case` is also A.6.7's statement keyword) and lowers as the same runtime chain an if-generate over a parameter does, so a `//! param` override selects the arm. `generate_block_name_collision_rejected.va` and `generate_block_shadows_declaration_rejected.va` (`//! reject E0230`) pin the prohibition; `generate_direct_nesting.va` pins the permission beside it, and one identity stamped on the OUTERMOST enclosing construct is what tells them apart |
| `s6.6.2.1` | dynamic (swept) parameters and structure-affecting conditions | — no fixture. The clause is permissive ("an implementation *may* choose to limit"), so there is no rule to fail |
| `s6.6.3` | external names `genblk1`, `genblk02` for unnamed blocks | `external_genblk_reference_unsupported.va`. It pins the reachable half — that the HDL path built from those names is illegal — and says so; the names themselves are a VPI/user-interface property with no in-HDL oracle |
| `s6.7` | hierarchical names | `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va` — all green: the flatten renames a child's entity to `path.name`, so a §6.7 reference resolves by joining the parts and looking the name up (`Lower.flatName`, `Elaborate.Design.names` for the port aliases). `root_reference_unsupported.va` is green too, including §6.2.1's disambiguation: `u.gain` takes the local scope and `$root.top.u.gain` the root |
| `s6.7.1` | branches, parameters and analog functions may be referenced hierarchically; analog *variables* may not; parameter declarations may not make OOMRs | the three prohibitions are all covered and all pass: `oomr_variable_read_rejected.va` (`//! reject E0207`), `oomr_variable_assign_rejected.va` (E0214), `oomr_in_parameter_declaration_rejected.va` (E0207). The three permissions are all green too: `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va`. The prohibition now has its OWN code, E0910, so the two verdicts no longer come from one parser gap — `oomr_variable_read_rejected.va` still pins E0901 only because its path names no instance at all |
| `s6.8` | six scope-creating constructs; one declaration per identifier per scope; upward search stopping at a module boundary | `local_scope_shadow.va` (inner block reads the enclosing variable), `local_scope_declaration_shadow.va` (inner declaration shadows it, and the outer value survives the block). The uniqueness half holds only for the sentence's generate-block clause — `generate_array_name_conflict_rejected.va` and `generate_block_shadows_declaration_rejected.va` (E0230), which also carry "regardless of whether the generate block is instantiated". The plain case is green now too: `duplicate_declaration_rejected.va` (two `real value;` in one scope) is E0362, checked over one declaration LIST — which is what keeps the two shadow fixtures legal, since a list is the declarations of exactly one scope |
| `s6.9` | elaboration binds instances, computes parameters, resolves names | — parent definition. All three halves are now asserted by the 6.2.2, 6.3.x and 6.7 rows above; `ir/elaborate.zig` is the pass |
| `s6.9.1` | multiple analog blocks concatenate in source order, after generate evaluation | `multiple_analog_blocks.va` covers the plain case (three blocks, an accumulator threaded through them) but cites `6.2`/`4.5.3`, not this id. The two files that *do* cite it are the after-generate half and both are green: `generate_two_loops.va` (two loops, region order, no interleaving), `generate_loop_descending.va` (unroll order determines concatenation order) |
| `s6.9.2` | paramset selection happens after generate evaluation | — no fixture. Needs a paramset instantiated inside a generate construct, i.e. both of this chapter's largest gaps at once |
| `s6.9.3` | connect-module insertion is post-elaboration | — no fixture; the clause defers to 7.8 and belongs to `tests/fixtures/ch07_mixed_signal/` |
| `s6.9.4` | the defparam/generate elaboration-order algorithm | `oomr_in_parameter_declaration_rejected.va` (`//! reject E0207`) pins the one consequence reachable from a single module: a parameter default may not read another instance, because parameter values are computed during elaboration. The algorithm itself needs a hierarchy |

## The xfail ledger

EMPTY — grep finds no `//! xfail` in this directory. It held the largest count in the suite
and its own headline claim was that those rows were not independent defects but five, "and
the fixtures are the receipts". That prediction held: all five closed, and eleven to fifteen
fixtures went green per commit rather than one at a time. Kept as the record, with the
measured counts rather than the ones the rows carried:

| Cause | Fixtures it held | How it closed |
|---|---|---|
| **E0204 "module instantiation is not supported."** The wall the whole chapter stood behind. | 15 | `ir/elaborate.zig` flattens the instance tree and E0204 is RETIRED (never to be reused). Eleven went green on that alone; the other four had a second gap behind the same wall, each of which closed too — the paramset declaration is parsed and selected (§6.4/§6.4.2) and `defparam` has a production. E0904 now means only what it says: an instance naming a module the file never declares |
| **Missing semantic check — VerA accepted what the LRM forbids.** A wrong model compiling clean, the worst failure mode in the set. | 4 + 6 | All green. `ansi_port_redeclared_rejected.va` (E0218), `untyped_port_behavioral_use_rejected.va` (`DiagnosticsReported`), `duplicate_declaration_rejected.va` (E0362, §6.8), `mfactor_double_scaling_rejected.va` (E0912, §6.3.6). The six generate rules that shared this row — the two block-name collisions, the instance-array collision, the nested region, the non-constant scheme and the `parameter` declaration — diagnose at E0228/E0229/E0230/E0428 |
| **E0207 — no `$root` prefix.** | 4 | `$root` is one arm in `parsePrimary`'s system-identifier case and one prefix strip in `Lower.flatName`, which is also where §6.2.1's local-scope-first rule lives: `root_reference_unsupported.va`, `oomr_branch_probe_unsupported.va`, `oomr_parameter_unsupported.va`, `oomr_function_unsupported.va` |
| **Assorted single parser/codegen gaps**, one fixture each. | 1 | `dependent_parameter_transcendental.va` — `codegen`'s `f64Const` had no `exp`, so a transcendental dependent parameter stayed frozen at its default. It runs and asserts now |

**Twenty-three filenames in this folder still end in `_unsupported`** and none of the
constructs they name is unsupported any more — every one of the twenty-three is green
(grep-counted: `ls *_unsupported.va | wc -l` is 23). Two are `//! reject` fixtures whose
rejection is correct conformance — `real_port_unsupported.va` (E0208) and
`external_genblk_reference_unsupported.va` (`DiagnosticsReported`) — and the other
twenty-one run and assert. The names are the largest remaining misinformation in this folder; renaming
them is behaviour-neutral and touches every header that cross-references them, which is why
no wave has spent the edit.

## Reject polarity: the right verdict by the wrong road

**Twenty-four** fixtures carry `//! reject` (grep-measured), and every one of them passes:
their rejection IS the conformance. One reaches the verdict through a diagnostic that has
nothing to do with the rule, and says so in its own header:

- `real_port_unsupported.va` — E0208 at the port direction declaration: `real` is neither a `net_type` nor `wreal`, so the parser has no shape there and everything else stops.

Three used to be in that list and no longer are, and the reason is the prediction this
section made. `external_genblk_reference_unsupported.va`,
`oomr_in_parameter_declaration_rejected.va` and `oomr_variable_read_rejected.va` all
refused the `.` itself (E0207), which is why they had to sit next to
`oomr_parameter_unsupported.va` and `oomr_branch_probe_unsupported.va`: *one* diagnostic
covered both the permitted and the forbidden case, and "the day hierarchical names resolve,
these two must keep failing while their three siblings start passing." That day came. All
three now fail at **E0901** — the name does not resolve in the instance tree — which is the
rule, while the three siblings run. `external_genblk_...` pins the phase label rather than
E0901 and so needed no edit.

The ones that diagnose at the rule are `port_direction_not_a_port_rejected.va`
(E0206), `vector_ports.va` (E0350 — §6.5.2.2's own comparison, on folded bounds;
it used to die at E0208 for the unparsed range and its header records the move),
`generate_region.va` (E0221 — Syntax 6-8 reaches a `generate_block` only
through a `for` or an `if`, never directly; it used to die at the `analog` keyword
instead and its header records the move) and, in 6.6.1, the E04xx family (`generate_mismatched_genvar_rejected.va`,
`generate_nonconstant_init_rejected.va`, `generate_nonconstant_condition_rejected.va`,
`genvar_init_self_reference_rejected.va`, `generate_nonterminating_rejected.va`),
joined by 6.6's own four (`generate_nested_region_rejected.va` E0228,
`generate_parameter_declaration_rejected.va` E0229, the three E0230 name
collisions, `generate_nonconstant_rejected.va` E0428).
Generate validation is the one part of this chapter VerA implements
properly. `genvar_outside_loop_rejected.va` is adjacent: E0314 "unknown identifier"
is the same answer a compiler with no genvar concept at all would give.

## `$mfactor`: what the passing fixtures do and do not pin

VerA carries `$mfactor` as an instance expression, not as the constant 1.0 — the flatten
multiplies it down the chain, which is what `mfactor_propagation_unsupported.va` pins. What
it still does NOT do is automatically scale flow contributions, flow probes or noise by it;
that is left to the host. At the
top of the hierarchy Table 9-29 fixes `$mfactor` at exactly 1.0, so the run
fixtures — `mfactor.va`, `mfactor_flow_contribution.va`, `mfactor_flow_probe.va`,
`mfactor_conditional_only.va`, `mfactor_flow_noise.va`, `mfactor_potential_noise.va`
— assert the correct conformant answers *for a top-level instance*, and would keep
asserting them under a tool that implements multiplicity fully. They pin the
identity case, not the scaling rule. The scaling rule is
`mfactor_propagation_unsupported.va` (1.0 × 2.0 × 7.0 = 14.0 down a three-deep
chain), and it is green: the flatten carries `$mfactor` as an expression, so the
product is exact without folding. What is still unasserted anywhere is §6.3.6's
first rule, the automatic scaling of the stamp, which VerA leaves to the host.

## Fixtures in this folder that cite another chapter

Three files live here for topical reasons but their `//! lrm` cites are elsewhere,
and they are not counted against any row above:

- `parameter_default.va` (`3.4`) — the un-overridden declared default, the baseline the 6.3 override fixtures are measured against.
- `mfactor_flow_noise.va`, `mfactor_potential_noise.va` (`9.18`, `4.6.4`) — they assert Table 9-29's top-level `$mfactor` = 1.0 and that `white_noise` returns 0 outside a noise analysis. The `$mfactor`-scales-noise rule of 6.3.6 needs a noise analysis *and* a non-unit multiplicity, and neither exists here.
