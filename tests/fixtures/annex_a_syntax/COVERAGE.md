# Annex A coverage

Source: `docs/VAMS-LRM/annex-a-syntax.html`, read as the normative grammar, production by
production. Annex A states no semantics: every row below is a claim that some fixture's
source text is *derivable from* the named production, not that the construct means
anything in particular. Meaning lives in the numbered clauses, and the fixtures cite
those too.

HTML section-ID audit: `a-1` `a-1-1` `a-1-2` `a-1-3` `a-1-4` `a-1-5` `a-1-6` `a-1-7`
`a-1-8` `a-1-9` `a-2` `a-2-1` `a-2-1-1` `a-2-1-2` `a-2-1-3` `a-2-2` `a-2-2-1` `a-2-2-2`
`a-2-2-3` `a-2-3` `a-2-4` `a-2-5` `a-2-6` `a-2-7` `a-2-8` `a-3` `a-3-1` `a-3-2` `a-3-3`
`a-3-4` `a-4` `a-4-1` `a-4-2` `a-5` `a-5-1` `a-5-2` `a-5-3` `a-5-4` `a-6` `a-6-1` `a-6-2`
`a-6-3` `a-6-4` `a-6-5` `a-6-6` `a-6-7` `a-6-8` `a-6-9` `a-6-10` `a-7` `a-7-1` `a-7-2`
`a-7-3` `a-7-4` `a-7-5` `a-7-5-1` `a-7-5-2` `a-7-5-3` `a-8` `a-8-1` `a-8-2` `a-8-3`
`a-8-4` `a-8-5` `a-8-6` `a-8-7` `a-8-8` `a-8-9` `a-9` `a-9-1` `a-9-2` `a-9-3` `a-9-4`
`a-10`.

Seventy-four ids. Eight are bare parent headings that carry no production of their own
(`a-1` `a-2` `a-2-1` `a-2-2` `a-4` `a-6` `a-8` `a-9`). Of the sixty-six that do carry
productions, **thirty-nine** have a fixture and **twenty-seven** do not. The
twenty-seven are listed at the bottom by name; none of them is papered over with a
plausible-looking file in the table.

Forty-four `.va` files: **sixteen run green**, **fourteen carry a `//! reject` arm**, and
**fourteen carry `//! xfail`**. No file here carries both — unlike `ch02_lexical`, every
xfail in this directory is a *positive* construct VerA cannot accept, never a rule it
fails to enforce. That is what makes this chapter's xfail set a clean debt ledger:
fourteen rows, fourteen named parser or backend gaps, each retiring the day its gap closes.

Every row was checked against the file's source, not its filename or its `//! lrm`
cites. Where a fixture contains a construct but cites a different section for it, the row
says so. Where a cite claims a section the source does not reach, the row says that too.

| HTML id | Production area | Fixtures |
|---|---|---|
| `a-1` | heading | parent of A.1.1–A.1.9 |
| `a-1-1` | `library_text`, `library_declaration`, `include_statement`, `config` binding | — no fixture. The `library` and `include` *keywords* of A.1.1 are a compilation-unit facility; the only `` `include `` in this directory is the preprocessor directive of 10.3, which is a different thing with the same word |
| `a-1-2` | `source_text ::= { description }`; `description` seven ways; `module_keyword ::= module \| macromodule` | `01_source_text.va` — four descriptions in one file (two `nature`, one `discipline`, two `module`), which is the only place the `{ description }` repetition is proved at all; the trailing `module annex_a_first(); endmodule` is a second, port-free module declaration. `43_macromodule.va` takes the second arm of `module_keyword`, and takes it as a RUN fixture: §6.2's "an implementation may choose to treat module definitions beginning with the macromodule keyword differently" is a licence to optimize, not to refuse, so the two spellings arrive at one arm of the top-level dispatch and nothing downstream can tell them apart |
| `a-1-3` | `list_of_ports`, `list_of_port_declarations`, `port`, `port_expression`, `port_reference`, `module_parameter_port_list` | Non-ANSI `list_of_ports` plus separate `inout`: `01`, `03`, and most of the directory. ANSI `list_of_port_declarations` with all three directions and a discipline on each: `02_module_ports.va` (`input electrical sense, output electrical drive, inout electrical common`) — the only file in the directory that takes that arm. All three of the remaining arms are green: `13_parameter_port_list.va` (`module_parameter_port_list`, with one header parameter overridden and one left at its default), `41_named_port.va` (`port ::= . port_identifier ( [ port_expression ] )` — the body probes the INTERNAL name), `42_concatenated_port.va` (`port_expression ::= { port_reference { , port_reference } }`, two nets keeping their own identities). A concatenated port becomes N terminals rather than one N-bit terminal, which is the same scalarisation §6.5.2 vector ports get and which only an instantiation could tell apart |
| `a-1-4` | `module_item`, `module_or_generate_item`, `non_port_module_item`, `parameter_override` | The reachable arms are spread across the directory: `analog_construct` and the declaration arms everywhere, `aliasparam_declaration` in `03_declarations.va`, `loop_generate_construct`/`conditional_generate_construct` in `09`/`14`/`15`, `module_instantiation` in `11`/`12`, the `{ attribute_instance }` prefix in `08_attributes_comments_identifiers.va`. `parameter_override ::= defparam list_of_defparam_assignments ;` is `12_defparam.va` alone, and cites A.1.4 for it — **`//! xfail`** |
| `a-1-5` | `config_declaration`, `design_statement`, `cell_clause`, `liblist_clause` | — no fixture, no cite anywhere in the suite. Configurations select which library cell binds an instance; VerA has no instances |
| `a-1-6` | `nature_declaration`, `nature_item`, `nature_attribute`, `nature_attribute_identifier` | `01_source_text.va` declares two full natures (`annex_a_voltage`, `annex_a_current`), each with `units`, `access` and `abstol`, and the module's nets bind to them rather than to the built-in `electrical` — so a parse-and-discard would fail the `CHECKX`. The file cites A.1.2/A.1.3 and 3.6.2.1/3.13.2, not A.1.6; the construct is unambiguously here |
| `a-1-7` | `discipline_declaration`, `discipline_item`, `nature_binding`, `domain_binding` | `01_source_text.va` — `domain continuous;` plus both `potential` and `flow` bindings. Its header records why the flow binding is load-bearing rather than decorative: with a single nature the discipline is signal-flow and `I(p, n)` names an access function it does not define |
| `a-1-8` | `connectrules_declaration`, `connect_insertion`, `connect_resolution` | — no fixture. Mixed-signal automatic insertion; `ch07_mixed_signal` owns the clause, and VerA is analog-only |
| `a-1-9` | `paramset_declaration`, `paramset_item_declaration`, `paramset_statement` | `10_paramset.va` — a full `paramset … endparamset` with a `parameter` item and a `.gain = 2.0 * scale;` override statement, applied by instantiating it. **`//! xfail`** — the declaration itself is no longer refused (it is read past and dropped, since §6.4 gives one effect only through an instance), so nothing here checks the ITEM and STATEMENT productions; the instantiation is E0204 |
| `a-2` | heading | parent; `03_declarations.va` cites the bare `A.2` |
| `a-2-1` | heading | parent of A.2.1.1–A.2.1.3 |
| `a-2-1-1` | `parameter_declaration`, `local_parameter_declaration`, `aliasparam_declaration`, `specparam_declaration` | `03_declarations.va` carries three of the four in one module: `parameter real gain = 2.0 from (0:inf)`, `localparam real offset = 1.0`, `aliasparam amplification = gain`, and reads the alias back through an override. Also `parameter real coefficients[0:1]` in `07`, `parameter integer` in `14`/`15`. `specparam` has no fixture and is not in Verilog-A |
| `a-2-1-2` | `inout_declaration`, `input_declaration`, `output_declaration` | `01`, `03` and nearly everything else for the bare `inout`; `02_module_ports.va` for all three directions carrying a `discipline_identifier`; `04`/`23`/`37`/`38` for `input` inside an analog function |
| `a-2-1-3` | `branch_declaration`, `event_declaration`, `integer_declaration`, `real_declaration`, `net_declaration`, `reg`/`time`/`realtime` | `03_declarations.va` (the `discipline_identifier list_of_net_identifiers` arm of `net_declaration`, plus `integer`, `real`, and a named `branch (p, n) path;`), `23_expression_primaries.va` (branch plus `real array[0:1]`), `05` (`integer`, `real`). `event_declaration` is `17_named_event_trigger.va` (`event tick;`, one identifier — the comma list has no fixture). `reg`, `time`, `realtime` and the eleven digital `net_type` spellings: nothing, and nothing should — see A.2.2.1 |
| `a-2-2` | heading | parent |
| `a-2-2-1` | `net_type`, `output_variable_type`, `real_type`, `variable_type` | `real_type` and `variable_type` with a `dimension`: `07_expressions.va` (`coefficients[0:1] = '{1.0, 2.0}`) and `23_expression_primaries.va` (`real array[0:1]`). The `net_type` list (`supply0 … wor`) and `output_variable_type` have no fixture: they are the digital half, withdrawn from Verilog-A by Annex C |
| `a-2-2-2` | `drive_strength`, `strength0`, `strength1`, `charge_strength` | — no fixture. Digital-only; `grep -l 'strong0\|pull1\|supply0' *.va` is empty |
| `a-2-2-3` | `delay3`, `delay2`, `delay_value` | — no fixture. Net delays are digital. `34_delay_control_in_analog_rejected.va` looks adjacent but is not: `#5` there is A.6.5 `delay_control`, a statement prefix, not a declaration delay |
| `a-2-3` | `list_of_branch_identifiers`, `list_of_param_assignments`, `list_of_port_identifiers`, `list_of_real_identifiers`, `list_of_variable_identifiers`, `list_of_net_identifiers` | `03_declarations.va` — `electrical p, n, internal;` is a three-element `list_of_net_identifiers`, `inout p, n;` a two-element `list_of_port_identifiers`. `39_branch_array.va` cites A.2.3 for the `branch_identifier [ range ]` arm (`pair[0:1]`) and is green: the range folds in lowering and the elements are registered under `pair[0]`/`pair[1]`, the same scalarised keying a §3.12 vector branch uses. The other seven list productions have no fixture; each belongs to a construct that has none either |
| `a-2-4` | `param_assignment` (both arms), `net_decl_assignment`, `defparam_assignment`, `specparam_assignment` | Arm one of `param_assignment` with a trailing `{ value_range }`: `03_declarations.va`. Arm two, `parameter_identifier range = constant_assignment_pattern`: `07_expressions.va` (`parameter real coefficients[0:1] = '{1.0, 2.0}`) — the only file in the suite that takes it, and it runs green. `defparam_assignment ::= hierarchical_parameter_identifier = …`: `12_defparam.va` (`child.gain`), the directory's only hierarchical identifier — **`//! xfail`**. `net_decl_assignment` and `specparam_assignment`: nothing |
| `a-2-5` | `dimension`, `range`, `value_range`, `value_range_type`, `value_range_expression` | `03_declarations.va` cites A.2.5 and takes three of the six `value_range` arms — `from (0:inf)` (open/open) and `from (-inf:0]` (open/closed), including both `inf` and `-inf` as `value_range_expression`, and it checks the negative default survives. `dimension`: `07`, `23`. `range`: `39` (**`//! xfail`**). The `'{ string { , string } }` arm and the `exclude` arm of `value_range_type` have no fixture here |
| `a-2-6` | `analog_function_declaration`, `analog_function_type`, `analog_function_item_declaration` | `04_analog_function.va` (explicit `real` type, `input`/`real` item declarations, assignment to the function's own name), `37_analog_function_default_type.va` (the `[ analog_function_type ]` bracket *omitted* — the other half of the same production), `38_analog_function_integer_string.va` (the `integer` and `string` arms of `analog_function_type`, both of the two spellings nothing else reaches), `23_expression_primaries.va` (a function declared alongside a branch and called from a word select). The digital `function_declaration` and its `function_port_list` have no fixture and are not Verilog-A |
| `a-2-7` | `task_declaration`, `task_item_declaration`, `tf_input_declaration`, `task_port_type` | `20_task_enable.va` declares `task record; input real x; … endtask` and calls it — `//! reject E0214`. A user task is legal Verilog-AMS grammar and outside the analog subset, so the reject is the conforming answer, not debt |
| `a-2-8` | `analog_block_item_declaration`, `block_item_declaration` | — **no fixture**. Two files open a named block (`05_behavioral_statements.va`'s `begin : behavior`, `14_if_generate.va`'s `begin : on` / `: off`) and neither declares anything inside it. A.2.8 is the only place in all of Annex A where `string_declaration` appears — see the prose below |
| `a-3` | heading | parent; nothing under it has a fixture |
| `a-3-1` | `gate_instantiation`, `n_input_gate_instance`, `pass_switch_instance`, … | — no fixture |
| `a-3-2` | `pulldown_strength`, `pullup_strength` | — no fixture |
| `a-3-3` | `input_terminal`, `output_terminal`, `enable_terminal`, … | — no fixture |
| `a-3-4` | `cmos_switchtype`, `gate_type`, `n_input_gatetype`, … | — no fixture |
| `a-4` | heading | parent |
| `a-4-1` | `module_instantiation`, `parameter_value_assignment`, `named_parameter_assignment`, `list_of_port_connections`, `named_port_connection` | `11_module_instantiation.va` — `annex_a_child #(.gain(2.0)) child_instance(p, n);` covers `parameter_value_assignment` with a `named_parameter_assignment` and an ordered `list_of_port_connections` in one line, against a second module in the same file that checks the override arrived. `12_defparam.va` and `10_paramset.va` each instantiate too, as the carrier for their own production. All three **`//! xfail`**, all three on the same defect |
| `a-4-2` | `generate_region`, `genvar_declaration`, `analog_loop_generate_statement`, `if_generate_construct`, `case_generate_construct` | `09_generate.va` (`generate … endgenerate` with `genvar index;` and a `for` loop unrolled three times, checked by accumulation), `14_if_generate.va` (both arms, named `begin : on` / `begin : off`), `15_case_generate.va` (three items including a `1, 2:` multi-expression item and a `default:`). All three are green — a generate block parses as a run of `module_or_generate_item`s, so `analog_construct` inside one is derivable, and `case_generate_construct` shares A.6.7's `case_statement` parser, the two productions differing only in what an arm body is |
| `a-5` | heading | parent; nothing under it has a fixture |
| `a-5-1` | `udp_declaration`, `udp_ansi_declaration` | — no fixture |
| `a-5-2` | `udp_port_list`, `udp_output_declaration`, `udp_input_declaration` | — no fixture |
| `a-5-3` | `udp_body`, `combinational_entry`, `sequential_entry`, `edge_indicator` | — no fixture |
| `a-5-4` | `udp_instantiation`, `udp_instance` | — no fixture |
| `a-6` | heading | parent |
| `a-6-1` | `continuous_assign ::= assign [ drive_strength ] [ delay3 ] list_of_net_assignments ;` | — **no fixture**. `grep -n '^\s*assign' *.va` is empty. Digital continuous assignment; the analog counterpart is A.6.10's `<+`, which is everywhere |
| `a-6-2` | `analog_construct`, `analog_procedural_assignment`, `blocking_assignment`, `nonblocking_assignment`, `procedural_continuous_assignments`, `initial_construct`, `always_construct` | Arm one, `analog analog_statement`: every module here. Arm two, `analog initial analog_function_statement`: `16_analog_initial.va` alone, which checks the initialization is visible to the later block. `scalar_analog_variable_assignment`: `05`, `06`, `07`, `24`, `40`. The digital arms are pinned negatively: `31_nonblocking_in_analog_rejected.va` (`x <= 1.0`, `//! reject E0214`) and `30_force_in_analog_rejected.va` (`force x = 1.0`, `//! reject E0209`). `initial_construct`/`always_construct` without `analog`: nothing |
| `a-6-3` | `analog_seq_block`, `analog_function_seq_block`, `analog_event_seq_block`, `seq_block`, `par_block` | `05_behavioral_statements.va` takes the `begin [ : analog_block_identifier ]` arm of `analog_seq_block`; `04`/`37`/`38` the `analog_function_seq_block`. `par_block` is refused by `32_fork_in_analog_rejected.va` (`fork … join`, `//! reject E0209`). The `{ analog_block_item_declaration }` slot that all three block productions share is unreached — see A.2.8 |
| `a-6-4` | `analog_statement`, `analog_function_statement`, `statement`, `statement_or_null` | The chapter's busiest row. Positives: `05_behavioral_statements.va` (six statement forms in one block), `22_null_attributed_statements.va` (`{ attribute_instance } ;` — the null statement, attributed, as the true arm of an `if`, with a second attribute on the `else` arm's contribution). Boundaries, one file each, all `//! reject`: `26` contribution inside an event statement (E0406), `27` indirect contribution inside one (E0411), `28` nested event control (E0703), `30` `force` (E0209), `31` `<=` (E0214), `32` `fork` (E0209), `33` `wait` (E0209), `34` `#5` (E0209), `18` `disable` (E0401), `19` `break`/`continue`/`return` (E0403), `20` task enable (E0214). Eleven of the fourteen rejects in the directory hang off this one production |
| `a-6-5` | `analog_event_control`, `analog_event_expression`, `analog_event_functions`, `event_control`, `event_trigger`, `disable_statement`, `jump_statement`, `wait_statement`, `delay_control`, `procedural_timing_control` | `06_event_control.va` is the only green one: `@(initial_step)` and `@(cross(V(p, n), 1))` in one block, with the second checked to *not* fire in a non-transient analysis. `17_named_event_trigger.va` covers `event_trigger ::= -> hierarchical_event_identifier ;` and the `@ hierarchical_event_identifier` arm, both green — though the identifier is a flat name in both, since a `hierarchical_` one has nothing to resolve in (E0901). Negatives: `28` (nesting), `33` (`wait_statement`), `34` (`delay_control`), `18` (`disable_statement`), `19` (all three arms of `jump_statement`). `posedge`/`negedge`, `final_step`, `above`, `timer`, `absdelta` and the `or`/`,` event composition: no fixture in this directory |
| `a-6-6` | `analog_conditional_statement`, `analog_function_conditional_statement`, `if_else_if_statement` | `05_behavioral_statements.va` (`if`/`else`), `22_null_attributed_statements.va` (both arms non-trivial: an attributed null and an attributed contribution), `18` and `19` as carriers. The `{ else if }` repetition itself has no fixture |
| `a-6-7` | `analog_case_statement`, `analog_case_item`, `casex`, `casez` | `05_behavioral_statements.va` — `case (index)` with a single-expression item, a `0`/`1, 2` multi-expression item, and a `default` written *without* its optional colon, which is the `default [ : ]` bracket. No `casex` or `casez` anywhere in the directory |
| `a-6-8` | `analog_loop_statement`, `analog_function_loop_statement`, `loop_statement` | `05_behavioral_statements.va` — all three analog arms (`for`, `while`, `repeat`) in one block, and it checks the *interaction*: `index` ends at 3 because the `while` continues where the `for` stopped. `19_jump_statements.va` puts `break`/`continue` inside a `for`. No fixture cites A.6.8 by number, and `forever` (digital-only) has none |
| `a-6-9` | `analog_system_task_enable`, `system_task_enable`, `task_enable` | `44_system_task_null_arguments.va` — `$strobe;` with no parentheses at all and `$strobe("a",,"b")` with an omitted middle argument, which is exactly the `[ ( [ analog_expression ] { , [ analog_expression ] } ) ]` bracket nesting and nothing else in the suite exercises it. `20_task_enable.va` takes the user `task_enable` arm — `//! reject E0214` |
| `a-6-10` | `contribution_statement`, `indirect_contribution_statement` | `contribution_statement ::= branch_lvalue <+ analog_expression ;` is in nearly every file. The indirect form is `21_indirect_contribution.va` — a two-resistor node with `V(out) : V(in) == 0.0`, checked both for the constraint and for the value it forces — **`//! xfail`**, and the only xfail here whose cause is the *backend* rather than the parser. `29_contribution_to_variable_rejected.va` pins that `branch_lvalue` is not a variable (`//! reject E0408`) |
| `a-7` | heading | parent; nothing under it has a fixture |
| `a-7-1` | `specify_block`, `specify_item` | — no fixture |
| `a-7-2` | `path_declaration`, `simple_path_declaration`, `edge_sensitive_path_declaration` | — no fixture |
| `a-7-3` | `specify_input_terminal_descriptor`, `specify_output_terminal_descriptor` | — no fixture |
| `a-7-4` | `path_delay_value`, `list_of_path_delay_expressions` | — no fixture |
| `a-7-5` | `system_timing_check` | — no fixture |
| `a-7-5-1` | `$setup`, `$hold`, `$recovery`, … | — no fixture |
| `a-7-5-2` | `timing_check_limit`, `notifier`, `delayed_reference` | — no fixture |
| `a-7-5-3` | `timing_check_event`, `controlled_reference_event` | — no fixture |
| `a-8` | heading | parent; `07_expressions.va` cites the bare `A.8` |
| `a-8-1` | `analog_concatenation`, `analog_multiple_concatenation`, `assignment_pattern`, `constant_assignment_pattern` | `24_expression_composites.va` (`{4'b1010, 4'b0101}` checked as 165, so the pack order is asserted and not assumed), `07_expressions.va` (`'{1.0, 2.0}` — the `constant_assignment_pattern`, which the file reads back element by element). `25_replication.va` is `analog_multiple_concatenation` (`{2{4'b0011}}` checked as 51, so the repeat count and the pack order are both asserted) |
| `a-8-2` | `analog_function_call`, `analog_system_function_call`, `analog_built_in_function_call`, `analog_filter_function_call`, `branch_probe_function_call`, `port_probe_function_call`, `analog_small_signal_function_call`, `analysis_function_call` | `23_expression_primaries.va` cites A.8.2 and holds four of these: a user `analog_function_call`, a `$pow` `analog_system_function_call`, a `branch_probe_function_call` over a named branch, and `I(<p>)` — the `port_probe_function_call`, whose angle brackets appear nowhere else in the directory. `07_expressions.va` adds `sin`/`cos` from `analog_built_in_function_name`. `analog_filter_function_call` is only `ddt` in `40_abstol_nature_identifier.va`, green; `ddx`, `idt`, `idtmod`, `absdelay`, `transition`, `slew`, `last_crossing`, `limexp`, the four `laplace_*` and the four `zi_*` names have no fixture here, nor do the small-signal or `analysis()` calls. `ch05_analog_behavior` owns those |
| `a-8-3` | `analog_expression`, `analog_conditional_expression`, `constant_expression`, `abstol_expression`, `indirect_expression` | `07_expressions.va` (binary, `**` precedence against `*` checked numerically, and `?:`), `24_expression_composites.va` (the `unary_operator analog_primary` arm via `~`, plus `?:`). `abstol_expression ::= … | nature_identifier` is `40_abstol_nature_identifier.va`, which cites A.8.3 and is the only file that writes a bare nature name in expression position — green, and it asserts both arms give the same value. `indirect_expression` is `21` (also xfail). The `{ attribute_instance }` slot on operators is `ch02_lexical`'s, not here; `mintypmax` and the `module_path_*` family have nothing |
| `a-8-4` | `analog_primary`, `constant_primary`, `primary` | `23_expression_primaries.va` cites A.8.4 and reaches `number`, `variable_reference` with a word select, `analog_function_call` and `analog_system_function_call` in adjacent statements. `24` adds `analog_concatenation` and parenthesized subexpressions; `07` adds `parameter_reference` with an index. `genvar_identifier` as a primary is `09` (xfail); `nature_attribute_reference` (`net.potential.abstol`) has no fixture anywhere in the directory |
| `a-8-5` | `analog_variable_lvalue`, `branch_lvalue`, `variable_lvalue`, `net_lvalue`, `array_analog_variable_assignment` | `29_contribution_to_variable_rejected.va` cites A.8.5 and pins the boundary: `x <+ 1.0` where `x` is `real` is `//! reject E0408`, because `branch_lvalue ::= branch_probe_function_call` and nothing else. The indexed arm of `analog_variable_lvalue` is `23` (`array[0] = …`, `array[1] = …`). `net_lvalue`, the braced concatenation lvalue, and `array_analog_variable_assignment` from an `assignment_pattern` rvalue: no fixture |
| `a-8-6` | `unary_operator`, `binary_operator`, `unary_module_path_operator` | `07_expressions.va` (`+`, `*`, `**`, `>`, `?:`) and `24_expression_composites.va` (`~`, `<<`, `&`, `>`), each with a numeric check rather than a parse. No fixture cites A.8.6, and none should: Clause 4 defines what the operators mean and `ch04_expressions` proves it production by production. What is asserted here is only that they parse in analog context |
| `a-8-7` | `number`, `decimal_number`, `real_number`, `hex_number`, `sign`, `size`, `unsigned_number` | `24_expression_composites.va` (`4'b1010`, `4'b0101`, `8'h0f` — sized based numbers in three bases), `03`/`07` (real and integer decimals), `01` (`1u` and `1p` scale factors in the nature attributes). `36_real_embedded_space_rejected.va` cites A.8.7 and pins the negative: `1.5 e3` is `//! reject E0207`. The full number grammar is `ch02_lexical`'s `s2-6`, sixty files of it |
| `a-8-8` | `string` | `03_declarations.va` (`string label = "declarations";`), `38_analog_function_integer_string.va` (a `string`-typed analog function returning `"hi"`, compared for equality), `20` (`$display("%g", x)`), `01` (`units = "V"`). No fixture cites A.8.8; see the prose on `string_declaration` below |
| `a-8-9` | `branch_reference`, `analog_port_reference`, `analog_net_reference`, `variable_reference`, `parameter_reference`, `net_reference`, `nature_attribute_reference` | `23_expression_primaries.va` cites A.8.9: `V(path)` is `nature_access_function ( branch_reference )`, `I(<p>)` an `analog_port_reference`, `array[0]` an indexed `variable_reference`. `V(p, n)` — the two-`analog_net_reference` arm — is in nearly every file. `39_branch_array.va` takes `branch_reference ::= hierarchical_branch_identifier [ constant_expression ]`, is the only file that does, and is green. `hierarchical_unnamed_branch_reference` and `nature_attribute_reference` have no fixture: both need hierarchy |
| `a-9` | heading | parent |
| `a-9-1` | `attribute_instance ::= (* attr_spec { , attr_spec } *)`, `attr_spec`, `attr_name` | `08_attributes_comments_identifiers.va` (`(* annex = "A.9" *)` prefixing a module declaration — the `attr_name = constant_expression` arm), `22_null_attributed_statements.va` (two valueless attributes, `(* conditional_null *)` on a null statement and `(* contribution_attr *)` on a contribution, which is the bare `attr_name` arm in statement position). The exhaustive attribute placement work is `ch02_lexical`'s `s2-9`, which has eight files to these two |
| `a-9-2` | `comment`, `one_line_comment`, `block_comment`, `comment_text` | `08_attributes_comments_identifiers.va` — both forms, inside a module body, one after the other. Every other file uses `//` in its header, but `08` is the one that puts a comment where a statement could go and proves it vanishes |
| `a-9-3` | `identifier`, `simple_identifier`, `escaped_identifier`, the hierarchical family, `system_*_identifier` | `08_attributes_comments_identifiers.va` (`\punctuated+identifier` declared, assigned and read — an `escaped_identifier` whose body contains a character `simple_identifier` cannot hold), `35_escaped_system_identifier_rejected.va` (`\$vt` — `//! reject E0314`, conforming: an escaped `$vt` is an ordinary user name and resolves to nothing). `hierarchical_identifier` is `12`'s `child.gain`, xfail. Simple identifiers are everywhere and asserted nowhere here; `ch02_lexical`'s `s2-8` owns them |
| `a-9-4` | `white_space ::= space \| tab \| newline \| eof` | — **no fixture asserts it**. Every file separates tokens with it, which proves nothing a broken lexer would fail. The nearest thing is `36_real_embedded_space_rejected.va`, but that pins A.10's "Embedded spaces are illegal", not A.9.4's character set. `ch02_lexical`'s `s2-3` is where this is actually tested, form feed and all |
| `a-10` | Details: the five footnote rules — function statements limited by 4.7.1, embedded spaces illegal, `simple_identifier` shape, `$` not followed by white space, system identifiers not escapable | `35_escaped_system_identifier_rejected.va` and `36_real_embedded_space_rejected.va` both cite A.10 and take one sentence each (the fifth and the second). `04`/`37`/`38` exercise the first through 4.7.1 without citing A.10. The third sentence (`simple_identifier` shape) and the fourth (`$` followed by white space) have no fixture here — `ch02_lexical` has `17`, `47`, `18` and `60` for exactly those |

## The xfail ledger

Six of the forty-four fixtures state a rule VerA does not meet. Reasons are verbatim
from the file headers; each names the construct and, where known, the file that must
change. Every one is a *missing acceptance*: the source is legal Verilog-AMS in the
analog subset, and VerA refuses or mis-evaluates it. None is a missing check, so no row
here is at risk of freezing on an impossible diagnostic.

| Fixture | Section | Reason |
|---|---|---|
| `10_paramset.va` | `a-1-9` | VerA reads past a `paramset` declaration and drops it; applying one needs module instantiation, which is E0204 |
| `11_module_instantiation.va` | `a-4-1` | VerA does not implement module instantiation — an instance in a module body is rejected with E0204 |
| `12_defparam.va` | `a-1-4`, `a-2-4` | VerA implements neither module instantiation (E0204, reported first) nor defparam (E0205) |
| `21_indirect_contribution.va` | `a-6-10` | Green. The LRM's own ideal opamp closed around a 1:1 feedback pair, so the §5.6.7 constraint `V(out): V(in) == 0` has a unique solution `V(out) = -V(p)`; `//! solve` leaves `out` and `in` to the testbench's Newton loop, and the tolerance is annex D's `VOLTAGE_ABSTOL` |

Grouped by the defect rather than by the fixture, the five rows are **two** problems. Four
more are kept below, struck as closed, because each was a prediction this document made
about how the fixtures would fall and each turned out to be right:

1. **No hierarchy.** `10`, `11`, `12` — all three instantiate, and E0204 is reported before
   anything else in the file can be judged. `12`'s `defparam` and `10`'s `paramset` are
   downstream of that same wall; each also carries its own second gap, so closing
   instantiation alone XPASSes none of them but makes all three fail for their real reason.
2. **No case generate.** Closed. `15` alone, and it was one production: the arms of a
   `case_generate_construct` are `generate_block_or_null` where A.6.7's are
   `analog_statement_or_null`, so one parameter on the existing `case` parser covers both.
   `case` is still E0205 at module scope with no `generate` above it, which is what the rest
   of the suite pins.
3. **The module header parser.** Closed. `13`, `41` and `42` were three arms of A.1.3 that
   `src/frontend/parser.zig` did not have, each dying at the same point in the header with a
   different token, and one header rewrite retired all three — as this list predicted.
4. **Missing expression forms.** Closed. `25` (`{n{…}}`) and `39` (`branch id[range]`) were
   two independent parser gaps that happened to produce the same E0207 shape, and were
   closed independently.
5. **Nature identifiers in argument position.** Closed. `40` alone, and A.8.3's
   `abstol_expression ::= constant_expression | nature_identifier` now has both arms:
   `Lower.abstolSlot` names the tolerance slot of `ddt`/`idt`/`idtmod` and only that slot
   consults the nature scope. The file's second observation still stands and is still the
   more alarming half — in *contribution* position the tolerance argument is dropped
   before name resolution runs, so `ddt(V(p,n), Zorkmid)` is accepted there. That is why
   the fixture assigns to a variable instead of contributing; no fixture demands the
   contribution path resolve it.
6. **The testbench does not solve.** `21` alone, and it is not a frontend bug at all —
   `src/backend/tb.zig` writes `//! bias` values directly into `x[]`, so no indirect
   contribution's constraint is ever enforced. This is the one xfail here that a parser
   change cannot touch, and the one that silently weakens other files: any fixture whose
   check depends on the solver reaching a fixed point is checking the bias it was handed.

`43` (macromodule) was deliberately left out of that list as a one-keyword alias for
`module` whose fix was one token in the dispatch. It was.

## Reject is not debt

Fourteen files carry `//! reject`, and none of them is a bug ledger entry. Eleven pin
A.6.4's boundary between `statement` and `analog_statement` — `force`, `<=`, `fork…join`,
`wait`, `#5`, `disable`, `break`/`continue`/`return`, a user task enable, a contribution
inside an event statement, an indirect contribution inside one, and a nested event
control. Every one of those is legal Verilog-AMS grammar that Annex C withdraws from
Verilog-A or that 5.10 forbids in event context; a compiler that accepted them would be
wrong. The remaining three are `29` (`<+` to a variable, which `branch_lvalue` forbids
outright), `35` (`\$vt`, where 2.8.1 makes the escaped form an ordinary name), and `36`
(`1.5 e3`, A.10's embedded-space sentence).

Four of the eleven collapse to the same E0209 — `force`, `fork`, `wait` and `#5`. That is
the parser's generic "expected an expression" and not a considered diagnosis of what the
construct is. The fixtures pin the code that fires today; if VerA ever grows a "not in the
analog subset" diagnosis for these, four expected codes change together.

## What is not covered

Twenty-seven ids have no fixture. By group:

**Digital-only, correctly absent (nineteen).** All of A.3 (`a-3`, `a-3-1` … `a-3-4`), all
of A.5 (`a-5`, `a-5-1` … `a-5-4`), all of A.7 (`a-7`, `a-7-1` … `a-7-5-3`), plus `a-2-2-2`
(strengths), `a-2-2-3` (net delays) and `a-6-1` (`assign`). Gate and switch primitives,
UDPs, specify blocks, drive strengths and continuous assignment are withdrawn from
Verilog-A by Annex C and are not in VerA's subset. A fixture for any of them would test
that a reject happens, which the A.6.4 reject files already do for the statement-level
cases; for the rest there is nothing a device dump could assert.

**Compilation-unit constructs (three).** `a-1-1` (library source text), `a-1-5`
(configurations), `a-1-8` (connectrules). Libraries and configurations select which cell
binds an instance — a facility that presupposes instances. Connect rules are mixed-signal
insertion, owned by `ch07_mixed_signal`.

**A real gap (`a-2-8`).** Block item declarations. The `{ analog_block_item_declaration }`
slot exists in all three of A.6.3's block productions and in A.2.6's function body, and
nothing in this directory declares anything inside a block. Two files open a named block
and neither uses it. This is the one uncovered id that VerA might well support today and
that nobody has checked. `ch02_lexical`'s `55_attribute_block_item_and_function_port.va`
reaches the *attributed* form of the same slot, so the construct is not entirely
unproved in the suite — but Annex A's own production has no fixture that cites it.

**White space (`a-9-4`).** Used by every file, asserted by none. Filed to
`ch02_lexical`'s `s2-3`, which does test it (form feed and all) rather than merely
relying on it.

## Structural notes

**`string_declaration` has no home in Annex A.** `03_declarations.va` writes
`string label = "declarations";` at module level and it compiles. Grep the annex: the
token `string_declaration` occurs exactly once, as an arm of `analog_block_item_declaration`
in A.2.8. A.2.1.3's `module_or_generate_item_declaration` list does not include it, and
neither does `non_port_module_item`. So a module-level string variable is not derivable
from this grammar at all — it is either an annex defect or a construct Clause 3.9 grants
that Annex A never wired up. The fixture is not marked xfail because VerA accepting it is
almost certainly the intended behaviour; the row is recorded here so the discrepancy is
not mistaken for coverage. `38_analog_function_integer_string.va` uses the string
*function type*, which A.2.6 does grant explicitly.

**The `//! bias` caveat applies past `21`.** `src/backend/tb.zig` writing bias values
straight into `x[]` is filed as `21`'s xfail reason, but it is a property of the whole
harness. Any fixture whose `CHECK` reads a node voltage is reading the bias it declared,
not a solved operating point. That is fine for the fifteen green files, which only probe
their own biased ports — and it is exactly why `21` cannot pass, since an indirect
contribution's entire content is a value the solver must find.

**One violation per reject file.** A `//! reject` fixture stops at its first diagnostic,
so A.6.4's eleven boundaries cannot share a module. That is why `26` through `34` are nine
near-identical one-line modules; the differences are the single illegal statement and the
expected code. Reading them side by side is the fastest way to see where the analog
subset's edge actually is.

**Positive/negative pairs.** Several productions are only closed by both halves, and the
files are written to be read together: `04` ↔ `37` (the `[ analog_function_type ]` bracket
present and absent), `04`/`37` ↔ `38` (the `real` default against the `integer` and
`string` arms), `03` ↔ `07` (the two arms of `param_assignment`), `23` ↔ `39` (a scalar
branch reference against an indexed one), `24` ↔ `25` (concatenation against replication),
`21` ↔ `27`/`29` (indirect contribution where it is legal, and the two places it is not),
`06` ↔ `28`/`17` (event control that works, nesting that must not, and the named-event
declare/trigger/detect form, which works too), `08` ↔ `35` (an escaped identifier that names something against one
that cannot).

**Where this directory deliberately stops.** Annex A is a grammar, so the temptation is to
write one fixture per production and end up with a parser test suite that asserts nothing.
The rule followed here is that a fixture must *check a value* (`CHECK`, `CHECKX`, `CHECKI`,
`CHECKEQ`) or *pin a diagnostic* (`//! reject`); nothing is credited for merely parsing.
That is why the operator, number and identifier rows point at `ch02_lexical` and
`ch04_expressions` rather than duplicating them: those chapters own the semantics, and
this one owns only the question of whether the analog grammar admits the form at all.
