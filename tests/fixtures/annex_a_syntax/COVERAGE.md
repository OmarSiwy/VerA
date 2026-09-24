# Annex A coverage

## Source/evidence correction (2026-09-23)

See [the Annex A review](../../../docs/conformance-annex-a-review.md) for the
complete worker source/visual inventory, source anomalies and remaining rule
coverage. Historical counts and green/closed claims below are not current
measurements. A.10 states mandatory restrictions; this annex is not purely
syntax without semantics. Its presentation grammar also requires the applicable
chapter restrictions.

Fixture46 combines two incompatible source kinds and is not a valid required
positive. It is now a `//! reject E0232` regression (its xfail, which wanted the
mixed file to compile, is withdrawn). The missing map-reader obligation moves to
A-EVID-001: separate map and design inputs with actual binding evidence. The
new isolated design-input negative checks E0232; accepting the combined file
would not close the map-reader gap. Measure A includes legacy regression rows,
not a denominator of valid atomic normative requirements.

New `$width`/`$period` negative fixtures pin the mandatory event control of a
`controlled_reference_event`: the parser refuses a bare reference with E0207.
Acceptance of a discarded specify block does not prove timing behavior.

## Historical fixture inventory, superseded where corrected above

Source: `docs/annex-a-syntax.html`, read as the normative grammar, production by
production. Each historical row below was intended as a claim that some fixture's
source text is *derivable from* the named production, not that the construct means
anything in particular. A.10 and the numbered clauses also impose restrictions;
derivability alone is insufficient, and the former fixture46 claim was invalid.

HTML section-ID audit: `a-1` `a-1-1` `a-1-2` `a-1-3` `a-1-4` `a-1-5` `a-1-6` `a-1-7`
`a-1-8` `a-1-9` `a-2` `a-2-1` `a-2-1-1` `a-2-1-2` `a-2-1-3` `a-2-2` `a-2-2-1` `a-2-2-2`
`a-2-2-3` `a-2-3` `a-2-4` `a-2-5` `a-2-6` `a-2-7` `a-2-8` `a-3` `a-3-1` `a-3-2` `a-3-3`
`a-3-4` `a-4` `a-4-1` `a-4-2` `a-5` `a-5-1` `a-5-2` `a-5-3` `a-5-4` `a-6` `a-6-1` `a-6-2`
`a-6-3` `a-6-4` `a-6-5` `a-6-6` `a-6-7` `a-6-8` `a-6-9` `a-6-10` `a-7` `a-7-1` `a-7-2`
`a-7-3` `a-7-4` `a-7-5` `a-7-5-1` `a-7-5-2` `a-7-5-3` `a-8` `a-8-1` `a-8-2` `a-8-3`
`a-8-4` `a-8-5` `a-8-6` `a-8-7` `a-8-8` `a-8-9` `a-9` `a-9-1` `a-9-2` `a-9-3` `a-9-4`
`a-10`.

Seventy-four ids. **Sixty-four are cited and ten are not**, and the ten are headings that
state no requirement of their own: the nine section parents — `a-1`, `a-2-1`, `a-2-2`,
`a-3`, `a-4`, `a-5`, `a-6`, `a-7`, `a-9` — and `a-7-5`, a sub-heading, which is the same
case one level down. The annex's own title line is an eleventh uncited heading: it carries
no `id`, so it is not one of the seventy-four, but it is a heading and the coverage tool
counts it. Three more ids — `a-2`, `a-8`, `a-10` — carry no production either, but a
fixture already cites each as context for a construct it reaches through a subsection.
Every uncited heading is named at the bottom with the reason it has no fixture.

Sixty-eight `.va` files: **fifty-one run and assert**, **fifteen carry a `//! reject`
arm**, and **two carry `//! xfail`** (grep-measured over this directory). The xfail
ledger was empty until the A.1.1/A.1.5/A.1.8, A.3, A.5, A.7 and A.8.6 rows were written,
it then held fifteen, and thirteen of those fifteen closed in one pass. Every row of it
is a *missing acceptance* — legal full-AMS source VerA refuses — never a missing check,
so nothing here freezes on a diagnostic that is itself the bug. The closed rows are kept
below as the record of which gap closed each one.

Twenty-four of the sixty-eight files were written after the first census (45–68), and
every one of them takes a clause that census had listed as uncovered. Twenty-one are now
green (`45`, `47`–`59`, `60`, `61`, `63`–`65`, `67`, `68`), one is a `//! reject` (`62`),
and two are `//! xfail` (`46`, `66`). The fifteen that began as xfails all made the same
argument in their own words and cited §1.1 for it: the complete IEEE Std 1364 Verilog is
part of Verilog-AMS HDL, Annex C.16 does not exempt these keywords from the full
language, so a full-AMS compiler must ACCEPT the source rather than refuse it as
out-of-subset. Each carried an assertion, so the day VerA accepted the construct the file
XPASSed and named its own gap — which is how thirteen of them closed.

ACCEPTED IS NOT MODELLED, and four of the thirteen say so with a warning rather than
silence. A `specify` block (W0251), a gate or pull or UDP primitive (W0252) and a
`config_declaration` (W0253) are read in full and reach no device: their content is §8
scheduling or a library map, and a compiled analog device has neither an event queue nor
a library table. Each is `--deny`-able into a refusal for a design that cannot afford the
omission. The rows below say which is which, because "green" over one of those four means
the GRAMMAR is covered and not the behaviour.

Every row was checked against the file's source, not its filename or its `//! lrm`
cites. Where a fixture contains a construct but cites a different section for it, the row
says so. Where a cite claims a section the source does not reach, the row says that too.

| HTML id | Production area | Fixtures |
|---|---|---|
| `a-1` | heading | parent of A.1.1–A.1.9 |
| `a-1-1` | `library_text`, `library_declaration`, `include_statement`, `config` binding | A-EVID-001: fixture46's mixed map/design input is not derivable from either start symbol; its former positive claim is withdrawn and it is now `//! reject E0232`. `audit_library_declaration_in_design_rejected.va` independently pins E0232 in design context. Positive map parsing, includes, binding and host invocation require separate valid map/design files and observable selection; these remain open. |
| `a-1-2` | `source_text ::= { description }`; `description` seven ways; `module_keyword ::= module \| macromodule` | `01_source_text.va` — five descriptions in one file (two `nature`, one `discipline`, two `module`), a selected witness of `{ description }` repetition, not exhaustive alternative or repetition coverage; the trailing `module annex_a_first(); endmodule` is a second, port-free module declaration. `43_macromodule.va` takes the second arm of `module_keyword`, and takes it as a RUN fixture: §6.2's "an implementation may choose to treat module definitions beginning with the macromodule keyword differently" is a licence to optimize, not to refuse, so the two spellings arrive at one arm of the top-level dispatch and nothing downstream can tell them apart |
| `a-1-3` | `list_of_ports`, `list_of_port_declarations`, `port`, `port_expression`, `port_reference`, `module_parameter_port_list` | Non-ANSI `list_of_ports` plus separate `inout`: `01`, `03`, and most of the directory. ANSI `list_of_port_declarations` with all three directions and a discipline on each: `02_module_ports.va` (`input electrical sense, output electrical drive, inout electrical common`) — the only file in the directory that takes that arm. All three of the remaining arms are green: `13_parameter_port_list.va` (`module_parameter_port_list`, with one header parameter overridden and one left at its default), `41_named_port.va` (`port ::= . port_identifier ( [ port_expression ] )` — the body probes the INTERNAL name), `42_concatenated_port.va` (`port_expression ::= { port_reference { , port_reference } }`, two nets keeping their own identities). A concatenated port becomes N terminals rather than one N-bit terminal, which is the same scalarisation §6.5.2 vector ports get and which only an instantiation could tell apart |
| `a-1-4` | `module_item`, `module_or_generate_item`, `non_port_module_item`, `parameter_override` | The reachable arms are spread across the directory: `analog_construct` and the declaration arms everywhere, `aliasparam_declaration` in `03_declarations.va`, `loop_generate_construct`/`conditional_generate_construct` in `09`/`14`/`15`, `module_instantiation` in `11`/`12`, the `{ attribute_instance }` prefix in `08_attributes_comments_identifiers.va`. `parameter_override ::= defparam list_of_defparam_assignments ;` is `12_defparam.va` alone, and cites A.1.4 for it — green: `defparam` is a `kw_defparam` token and a module-item arm, and elaboration applies the override to the flattened child |
| `a-1-5` | `config_declaration`, `design_statement`, `cell_clause`, `liblist_clause` | A-EVID-002: fixture47 spells default/liblist, instance/use and cell/liblist, not all five rule arms. Instance/liblist and cell/use are separate missing variants. Its carrier voltage does not depend on configuration binding; W0253 reports ignored configuration. Accepted syntax is bounded evidence, not configured-design execution. |
| `a-1-6` | `nature_declaration`, `nature_item`, `nature_attribute`, `nature_attribute_identifier` | `45_nature_declaration.va` — the cite-by-number fixture, and the only place `nature_identifier : parent_nature` (the derived form) is written: two parents, two declaring children, an alias that declares nothing, and a discipline binding the derived natures. It asserts §3.6's inheritance both ways — the child's `abstol` override (0.001) and the alias's inherited one (1e-12) — so a parser that dropped the `: parent` clause reads the wrong tolerance. `01_source_text.va` also declares two full natures (`annex_a_voltage`, `annex_a_current`), each with `units`, `access` and `abstol`, and the module's nets bind to them rather than to the built-in `electrical` — so a parse-and-discard would fail the `CHECKX`. The file cites A.1.2/A.1.3 and 3.6.2.1/3.13.2, not A.1.6; the construct is unambiguously here |
| `a-1-7` | `discipline_declaration`, `discipline_item`, `nature_binding`, `domain_binding` | `01_source_text.va` — `domain continuous;` plus both `potential` and `flow` bindings. Its header records why the flow binding is load-bearing rather than decorative: with a single nature the discipline is signal-flow and `I(p, n)` names an access function it does not define |
| `a-1-8` | `connectrules_declaration`, `connect_insertion`, `connect_resolution` | `60_connectrules_declaration.va` — **green**. The directory's only `connectrules` block, and both `connect_insertion` arms are spelled in it: `connect annex_a_a2d merged;` (module, `connect_mode`) and `connect annex_a_ra, annex_a_rb resolveto annex_a_rc;` (`connect_resolution`). The three disciplines are declared with `domain discrete` and no natures, so the block is derivable without dragging in §7.4's resolution algorithm, and the host module asserts its own node. §7.7.2 and §3.11.1 are cited alongside — this is the one row in the table where the syntactic claim and an observable value are in the same file |
| `a-1-9` | `paramset_declaration`, `paramset_item_declaration`, `paramset_statement` | `10_paramset.va` — a full `paramset … endparamset` with a `parameter` item and a `.gain = 2.0 * scale;` override statement, applied by instantiating it. green: the declaration is parsed, so both the ITEM production (a `parameter` with a `from` range) and the STATEMENT production (`.gain = 2.0 * scale;`) are checked by the value the module reads back, 3.0. A.1.9's two other statement forms — an output-variable assignment and an analog_function_statement — are read and dropped; `ch06_hierarchy/paramset_output_unsupported.va` is where that is recorded |
| `a-2` | heading | parent; `03_declarations.va` cites the bare `A.2` |
| `a-2-1` | heading | parent of A.2.1.1–A.2.1.3 |
| `a-2-1-1` | `parameter_declaration`, `local_parameter_declaration`, `aliasparam_declaration`, `specparam_declaration` | `03_declarations.va` carries three of the four in one module: `parameter real gain = 2.0 from (0:inf)`, `localparam real offset = 1.0`, `aliasparam amplification = gain`, and reads the alias back through an override. Also `parameter real coefficients[0:1]` in `07`, `parameter integer` in `14`/`15`. `48_parameter_declarations.va` is the census of the other three: `parameter integer/real/realtime/time/string`, a `[ signed ]` parameter, `localparam` twice, and an `aliasparam` read back through its target — nine value assertions, and the string parameter's `from '{ "NPN", "PNP" }` range read back by comparing the parameter against the first allowed value. `49_specparam_declaration_unsupported.va` is `specparam tdr = 1.5;` as a `non_port_module_item` (§6.2's Syntax 6-1 lists it there) — green: it becomes a `localparam`, which is what A.2.4's mandatory constant default with no overrider makes it. `50_ranged_parameter_unsupported.va` is the FIRST arm's `[ range ]` — `parameter [3:0] nib = 4'h5;` — green, the width carried on `ParamDecl.packed_range` and the type still inferred from the value per §3.4.1 |
| `a-2-1-2` | `inout_declaration`, `input_declaration`, `output_declaration` | `01`, `03` and nearly everything else for the bare `inout`; `02_module_ports.va` for all three directions carrying a `discipline_identifier`; `04`/`23`/`37`/`38` for `input` inside an analog function. The third arm of `output_declaration` — `output [ output_variable_type ] …`, where A.2.2.1 gives `output_variable_type ::= integer \| time` — is `51_output_variable_type_unsupported.va`: `output integer o;` with `o` in the port list, so the diagnostic was the TYPE and not the already-taken `output` arm (E0208 "expected an identifier: found `integer`"). Green: both variable arms are read by one branch, and the name list becomes VARIABLES as well as ports, which is what A.2.3's `list_of_variable_port_identifiers` is a list of. The header records the `output reg` arm as the second spelling of the same production |
| `a-2-1-3` | `branch_declaration`, `event_declaration`, `integer_declaration`, `real_declaration`, `net_declaration`, `reg`/`time`/`realtime` | `03_declarations.va` (the `discipline_identifier list_of_net_identifiers` arm of `net_declaration`, plus `integer`, `real`, and a named `branch (p, n) path;`), `23_expression_primaries.va` (branch plus `real array[0:1]`), `05` (`integer`, `real`). `event_declaration` is `17_named_event_trigger.va` (`event tick;`, one identifier — the comma list has no fixture). `52_net_and_variable_types.va` takes `net_declaration` (all eleven `net_type` spellings, and `wire [3:0] wbus = 4'h5;`), `reg_declaration` (`reg [7:0] rbus;`), `time_declaration` (`time tv = 3;`) and `realtime_declaration` (`realtime rtv = 2.5;`), each read back and asserted; the nets are declared and deliberately never read, and the header says why (E0315/E0337). `53_variable_initializer_unsupported.va` is the same `reg_declaration` with a vector INITIALIZER — green: A.2.2.1's `variable_type` is read whole for `reg` as it already was for its four siblings, and the initialized 0x5a reads back 90. `wire signed` and `wreal` are refused by VerA and the `52` header names them as gaps rather than spelling them |
| `a-2-2` | heading | parent |
| `a-2-2-1` | `net_type`, `output_variable_type`, `real_type`, `variable_type` | `real_type` and `variable_type` with a `dimension`: `07_expressions.va` (`coefficients[0:1] = '{1.0, 2.0}`) and `23_expression_primaries.va` (`real array[0:1]`). `52_net_and_variable_types.va` declares all eleven `net_type` spellings and takes the `variable_type` second arm (`= constant_expression`) four times, checking each initializer's value; `53_variable_initializer_unsupported.va` is the VECTOR form of that arm and is green. `output_variable_type` is `51`, green. The `[ = constant_assignment_pattern ]` arm of `real_type`/`variable_type` — an array initializer on a variable rather than a parameter — has no fixture |
| `a-2-2-2` | `drive_strength`, `strength0`, `strength1`, `charge_strength` | `54_drive_strength_unsupported.va` — `wire (strong1, pull0) w = 1'b1;`, the `( strength1 , strength0 )` bracket on a net declaration, green. A comma after the first strength word is what tells A.2.2.2's pair from A.2.2.1's single-word `charge_strength` in one token. The header carries a correction to its own earlier probe: `trireg (small) tr;` never failed — `charge_strength` has been read at this position all along — so the two brackets were never one gap. `57_primitive_strengths_unsupported.va` covers A.3.2's `pulldown (strong0)`, the other place a `strength0` is spelled, and A.3.2 is deliberately NOT this clause |
| `a-2-2-3` | `delay3`, `delay2`, `delay_value` | `55_net_delay_unsupported.va` — `wire #5 w;`, green. `delay3` was parsed at this position all along; what refused the line was E0207 "a net delay has no meaning outside a digital design element", a verdict on the semantics written as a refusal of the syntax, and the header carries that correction to its own marker text. The delay is carried on `NetDecl.delay` and reaches no device, which is a §8 question ch08_scheduling owns. `34_delay_control_in_analog_rejected.va` looks adjacent but is not: `#5` there is A.6.5 `delay_control`, a statement prefix, not a declaration delay, and the `55` header makes the distinction |
| `a-2-3` | `list_of_branch_identifiers`, `list_of_param_assignments`, `list_of_port_identifiers`, `list_of_real_identifiers`, `list_of_variable_identifiers`, `list_of_net_identifiers` | `03_declarations.va` — `electrical p, n, internal;` is a three-element `list_of_net_identifiers`, `inout p, n;` a two-element `list_of_port_identifiers`. `39_branch_array.va` cites A.2.3 for the `branch_identifier [ range ]` arm (`pair[0:1]`) and is green: the range folds in lowering and the elements are registered under `pair[0]`/`pair[1]`, the same scalarised keying a §3.12 vector branch uses. The other four list productions closed later and close here: `list_of_param_assignments` is `48`'s `parameter integer gain = 3;`, `list_of_variable_identifiers` is `52`'s `time tv = 3;` and `53`'s `reg [7:0] rbus = 8'h5a, spare;` (the only two-element list in the directory whose members have different fates — `rbus` is read back, `spare` is not), and `list_of_real_identifiers` is `52`'s `realtime rtv = 2.5;`. With `list_of_branch_identifiers` in `39`, all six have a fixture |
| `a-2-4` | `param_assignment` (both arms), `net_decl_assignment`, `defparam_assignment`, `specparam_assignment` | Arm one of `param_assignment` with a trailing `{ value_range }`: `03_declarations.va`. Arm two, `parameter_identifier range = constant_assignment_pattern`: `07_expressions.va` (`parameter real coefficients[0:1] = '{1.0, 2.0}`) — the only file in the suite that takes it, and it runs green. `defparam_assignment ::= hierarchical_parameter_identifier = …`: `12_defparam.va` (`child.gain`), the directory's only hierarchical identifier — green, and the path is interned as ONE dotted string, which is the flat name elaboration gives the parameter. `net_decl_assignment` is `52`'s `wire [3:0] wbus = 4'h5;` and `specparam_assignment` is `63`'s `specparam tplh = 1.5, tphl = 2.5;` (inside a `specify` block, where A.7.1 also admits the declaration — green, and scoped to a block that is discarded, unlike `49`'s module-item form). `48` takes arm one four more times, once per parameter type |
| `a-2-5` | `dimension`, `range`, `value_range`, `value_range_type`, `value_range_expression` | `03_declarations.va` cites A.2.5 and takes three of the six `value_range` arms — `from (0:inf)` (open/open) and `from (-inf:0]` (open/closed), including both `inf` and `-inf` as `value_range_expression`, and it checks the negative default survives. `dimension`: `07`, `23`. `range`: `39` (green — `branch id[range]` parses) and `50`, which is the `[ msb : lsb ]` range in A.2.1.1's FIRST arm (not a `parameter_type`, which the production makes the other alternative) and is green. The `'{ string { , string } }` arm is `48`'s `parameter string mode = "NPN" from '{ "NPN", "PNP" };`, green and read back; only the `exclude` arm of `value_range_type` has no fixture here |
| `a-2-6` | `analog_function_declaration`, `analog_function_type`, `analog_function_item_declaration` | `04_analog_function.va` (explicit `real` type, `input`/`real` item declarations, assignment to the function's own name), `37_analog_function_default_type.va` (the `[ analog_function_type ]` bracket *omitted* — the other half of the same production), `38_analog_function_integer_string.va` (the `integer` and `string` arms of `analog_function_type`, both of the two spellings nothing else reaches), `23_expression_primaries.va` (a function declared alongside a branch and called from a word select). The digital `function_declaration` and its `function_port_list` have no fixture and remain required full-AMS coverage |
| `a-2-7` | `task_declaration`, `task_item_declaration`, `tf_input_declaration`, `task_port_type` | `20_task_enable.va` declares `task record; input real x; … endtask` and calls it — `//! reject E0214`. E0214 diagnoses the invalid analog-context task enable. The positive half is `69_task_declaration_enabled_from_initial.va` (green): both A.2.7 forms declared and enabled from a digital `initial` block, the analog block reading the result (10) |
| `a-2-8` | `analog_block_item_declaration`, `block_item_declaration` | No fixture IN THIS DIRECTORY declares anything inside a block — two files open a named block (`05_behavioral_statements.va`'s `begin : behavior`, `14_if_generate.va`'s `begin : on` / `: off`) and neither uses the slot. It is cited elsewhere: `ch02_lexical/55_attribute_block_item_and_function_port.va` names A.2.8 and spells the attributed form of the same production inside a named analog block and an analog function body. A.2.8 is also the only place in all of Annex A where `string_declaration` appears — see the prose below |
| `a-3` | heading | parent; no fixture cites it, and the four rows under it move together |
| `a-3-1` | `gate_instantiation`, `n_input_gate_instance`, `pass_switch_instance`, … | `56_gate_instantiation_unsupported.va` — `and nand_g1 (c, a, b);`, one `n_input_gate_instance` with its `n_input_gatetype`. GREEN AS GRAMMAR, W0252 as behaviour: the production was already implemented for `vera --run` over a `.v`, and what refused this line was a gate on the ARTIFACT being built. §8.5.3.5 puts gate-level modeling in the event-driven half of the language and a compiled analog device has no queue, so `c` keeps whatever the continuous solver leaves it — which is why the three nets here are connected to nothing. The header lists the arms NOT spelled (switch primitives, `buf`/`not`, enable gates, pull gates) and their `a-3-4`/`a-3-2` spellings |
| `a-3-2` | `pulldown_strength`, `pullup_strength` | `57_primitive_strengths_unsupported.va` — `pulldown (strong0) pd (o);`, green (W0252 for the gate). The parenthesised `( strength )` bracket is the whole clause and the only place a `strength0` is written outside `54`'s drive-strength declaration, and BOTH of its differences from A.2.2.2 are enforced rather than folded into it: the single-strength arm exists here, and it names the side the gate pulls toward, so `pulldown (strong1)` is derivable from neither production and says so. `highz0`/`highz1` are A.2.2.2's and are refused here |
| `a-3-3` | `input_terminal`, `output_terminal`, `enable_terminal`, … | `56` (`c`, `a`, `b` as `input_terminal`/`output_terminal`) and `59` (`b`, `a`), both green and both now reaching the terminals: an `output_terminal` is parsed as a `net_lvalue` and an `input_terminal` as an expression, which is the distinction A.3.3 draws. The `enable_terminal` and `[ drive_strength ]` forms have no fixture |
| `a-3-4` | `cmos_switchtype`, `gate_type`, `n_input_gatetype`, … | `56` — `and` is one of the ten `n_input_gatetype` spellings; the other nine, the four `gate_type` spellings and every switch type are not spelled, and the `56` header says so |
| `a-4` | heading | parent |
| `a-4-1` | `module_instantiation`, `parameter_value_assignment`, `named_parameter_assignment`, `list_of_port_connections`, `named_port_connection` | `11_module_instantiation.va` — `annex_a_child #(.gain(2.0)) child_instance(p, n);` covers `parameter_value_assignment` with a `named_parameter_assignment` and an ordered `list_of_port_connections` in one line, against a second module in the same file that checks the override arrived. `12_defparam.va` and `10_paramset.va` each instantiate too, as the carrier for their own production. All three are green: `ir/elaborate.zig` flattens the instance tree, and the second gap behind each (a `defparam` production, a `paramset` parser) closed too |
| `a-4-2` | `generate_region`, `genvar_declaration`, `analog_loop_generate_statement`, `if_generate_construct`, `case_generate_construct` | `09_generate.va` (`generate … endgenerate` with `genvar index;` and a `for` loop unrolled three times, checked by accumulation), `14_if_generate.va` (both arms, named `begin : on` / `begin : off`), `15_case_generate.va` (three items including a `1, 2:` multi-expression item and a `default:`). All three are green — a generate block parses as a run of `module_or_generate_item`s, so `analog_construct` inside one is derivable, and `case_generate_construct` shares A.6.7's `case_statement` parser, the two productions differing only in what an arm body is |
| `a-5` | heading | parent; no fixture cites it, and the four rows under it move together |
| `a-5-1` | `udp_declaration`, `udp_ansi_declaration` | `58_udp_declaration_unsupported.va` — `primitive annex_a_udp_pulse (o, a); … endprimitive` as a top-level `description`, green: A.1.2's `description` list contains `udp_declaration`, which is the argument that settles it. The non-ANSI arm is taken; the second A.5.1 arm (declarations inside the header parenthesis) parses too but is not spelled here |
| `a-5-2` | `udp_port_list`, `udp_output_declaration`, `udp_input_declaration` | `58` — `(o, a)` is the `udp_port_list` and the body's `output o;`/`input a;` are the port declarations. Green; the `udp_reg_declaration` arm parses and is not spelled here |
| `a-5-3` | `udp_body`, `combinational_entry`, `sequential_entry`, `edge_indicator` | `58` — a `table … endtable` body with two `combinational_entry`s (`0 : 1;`, `1 : 0;`). Green, and the table is VALIDATED rather than skipped: A.5.3's symbols are characters and not tokens (`(01)` is four symbols and three tokens), so entries are judged over the characters of their tokens, column by column, against the clause's three alphabets. E0233 is a symbol outside its column's alphabet and E0234 a table that is not one `udp_body` — the two codes `digital/d08_reject_udp_z_output.v` and `digital/d08_reject_udp_comb_edge.v` asked in writing to be allocated, and both of those files now get the wording they demand. No `edge_indicator` here, so no `sequential_entry`; `a-5-3`'s sequential half is covered by those two `.v` rows and not by a `.va` |
| `a-5-4` | `udp_instantiation`, `udp_instance` | `59_udp_instantiation_unsupported.va` — `annex_a_udp_pulse (b, a);` inside a module, green (W0252 for the primitive). The UDP is declared AFTER the module on purpose, and the probe recorded in the header shows why: the diagnostic used to change with the declaration order. It is told from A.4.1's `module_instantiation` by ONE token and no name lookup — `module_instance`'s name is mandatory and `udp_instance`'s is not, so an identifier followed directly by `(` derives from A.5.4 alone. The NAMED form is indistinguishable at parse time and stays a module instantiation; the header says so |
| `a-6` | heading | parent |
| `a-6-1` | `continuous_assign ::= assign [ drive_strength ] [ delay3 ] list_of_net_assignments ;` | — **no fixture here**. `grep -n '^\s*assign' *.va` is empty. This is the one production the directory leaves to the rest of the suite: `annex_c_analog_subset/23_continuous_assign_accepted.va` cites `//! lrm A.6.1` and asserts `wire w; assign w = 1'b1;` reads 1 in the analog block; `ch08_scheduling/digital_assignment_unsupported.va` pins E0438 on an `assign` to a variable. Digital continuous assignment; the analog counterpart is A.6.10's `<+`, which is everywhere |
| `a-6-2` | `analog_construct`, `analog_procedural_assignment`, `blocking_assignment`, `nonblocking_assignment`, `procedural_continuous_assignments`, `initial_construct`, `always_construct` | Arm one, `analog analog_statement`: every module here. Arm two, `analog initial analog_function_statement`: `16_analog_initial.va` alone, which checks the initialization is visible to the later block. `scalar_analog_variable_assignment`: `05`, `06`, `07`, `24`, `40`. The digital arms are pinned negatively: `31_nonblocking_in_analog_rejected.va` (`x <= 1.0`, `//! reject E0214`) and `30_force_in_analog_rejected.va` (`force x = 1.0`, `//! reject E0209`). `initial_construct`/`always_construct` without `analog`: nothing |
| `a-6-3` | `analog_seq_block`, `analog_function_seq_block`, `analog_event_seq_block`, `seq_block`, `par_block` | `05_behavioral_statements.va` takes the `begin [ : analog_block_identifier ]` arm of `analog_seq_block`; `04`/`37`/`38` the `analog_function_seq_block`. `par_block` is refused by `32_fork_in_analog_rejected.va` (`fork … join`, `//! reject E0209`). The `{ analog_block_item_declaration }` slot that all three block productions share is unreached — see A.2.8 |
| `a-6-4` | `analog_statement`, `analog_function_statement`, `statement`, `statement_or_null` | The chapter's busiest row. Positives: `05_behavioral_statements.va` (six statement forms in one block), `22_null_attributed_statements.va` (`{ attribute_instance } ;` — the null statement, attributed, as the true arm of an `if`, with a second attribute on the `else` arm's contribution). Boundaries, one file each, all `//! reject`: `26` contribution inside an event statement (E0406), `27` indirect contribution inside one (E0411), `28` nested event control (E0703), `30` `force` (E0209), `31` `<=` (E0214), `32` `fork` (E0209), `33` `wait` (E0209), `34` `#5` (E0209), `18` `disable` (E0401), `19` `break`/`continue`/`return` (E0403), `20` task enable (E0214). Twelve of the fifteen rejects in the directory hang off this one production — `62_forever_in_analog_rejected.va` is the twelfth, and it pins the boundary from the other side: `forever` is a `statement` and `analog_loop_statement` is the closed list `repeat \| while \| for`, so an analog `forever` is not derivable at all and MUST be refused. `61_looping_statements.va` is the positive half of the same clause |
| `a-6-5` | `analog_event_control`, `analog_event_expression`, `analog_event_functions`, `event_control`, `event_trigger`, `disable_statement`, `jump_statement`, `wait_statement`, `delay_control`, `procedural_timing_control` | `06_event_control.va` is the only green one: `@(initial_step)` and `@(cross(V(p, n), 1))` in one block, with the second checked to *not* fire in a non-transient analysis. `17_named_event_trigger.va` covers `event_trigger ::= -> hierarchical_event_identifier ;` and the `@ hierarchical_event_identifier` arm, both green — though the identifier is a flat name in both, since a `hierarchical_` one has nothing to resolve in (E0901). Negatives: `28` (nesting), `33` (`wait_statement`), `34` (`delay_control`), `18` (`disable_statement`), `19` (all three arms of `jump_statement`). `posedge`/`negedge`, `final_step`, `above`, `timer`, `absdelta` and the `or`/`,` event composition: no fixture in this directory — the `posedge` in `64` is A.7.5.3's timing-check event, inside a block VerA refuses before it reads one, not this production |
| `a-6-6` | `analog_conditional_statement`, `analog_function_conditional_statement`, `if_else_if_statement` | `05_behavioral_statements.va` (`if`/`else`), `22_null_attributed_statements.va` (both arms non-trivial: an attributed null and an attributed contribution), `18` and `19` as carriers. The `{ else if }` repetition itself has no fixture |
| `a-6-7` | `analog_case_statement`, `analog_case_item`, `casex`, `casez` | `05_behavioral_statements.va` — `case (index)` with a single-expression item, a `0`/`1, 2` multi-expression item, and a `default` written *without* its optional colon, which is the `default [ : ]` bracket. No `casex` or `casez` anywhere in the directory |
| `a-6-8` | `analog_loop_statement`, `analog_function_loop_statement`, `loop_statement` | `05_behavioral_statements.va` — all three analog arms (`for`, `while`, `repeat`) in one block, and it checks the *interaction*: `index` ends at 3 because the `while` continues where the `for` stopped. `19_jump_statements.va` puts `break`/`continue` inside a `for`. `61_looping_statements.va` is the cite-by-number fixture and takes the clause's SECOND production, `analog_function_loop_statement`: all three loop forms inside one analog function, in grammar order, with the arithmetic derived step by step (15 + 5 + 2*0.5 = 21.0, and 25 arguments later 326.0, which is what proves the `for`'s post-test and the `while`'s entry test). `62_forever_in_analog_rejected.va` is the digital `loop_statement`'s `forever`, refused — see A.6.4 |
| `a-6-9` | `analog_system_task_enable`, `system_task_enable`, `task_enable` | `44_system_task_null_arguments.va` — `$strobe;` with no parentheses at all and `$strobe("a",,"b")` with an omitted middle argument, which is exactly the `[ ( [ analog_expression ] { , [ analog_expression ] } ) ]` bracket nesting and nothing else in the suite exercises it. `20_task_enable.va` takes the user `task_enable` arm — `//! reject E0214` |
| `a-6-10` | `contribution_statement`, `indirect_contribution_statement` | `contribution_statement ::= branch_lvalue <+ analog_expression ;` is in nearly every file. The indirect form is `21_indirect_contribution.va` — a two-resistor node with `V(out) : V(in) == 0.0`, checked both for the constraint and for the value it forces — green, and the only xfail here whose cause is the *backend* rather than the parser. `29_contribution_to_variable_rejected.va` pins that `branch_lvalue` is not a variable (`//! reject E0408`) |
| `a-7` | heading | parent; no fixture cites it, and the rows under it move together |
| `a-7-1` | `specify_block`, `specify_item` | `63_specify_block_unsupported.va` — one `specify … endspecify` carrying four of the five `specify_item` arms (`specparam`, `path_declaration` twice, `pulsestyle_onevent`). GREEN AS GRAMMAR, W0251 as behaviour. ONE FILE FOR FOUR CLAUSES, and the header's reason for that has now changed: when the block was declined whole, every inner production reported the same code and the four clauses were four names on one refusal. All five arms are read now — A.7.2's three path declarations over both descriptions and both edge-sensitive forms included — so `(p = y) = 1;` is an error inside a block that used to accept any text at all between its keywords. Nothing is RECORDED: the content is §8 scheduling and an analog device has no event queue to schedule a path delay on |
| `a-7-2` | `path_declaration`, `simple_path_declaration`, `edge_sensitive_path_declaration` | `63` — both `simple_path_declaration` arms, `(p => y) = (tplh, tphl);` (parallel) and `(n *> y) = 1;` (full). No `edge_sensitive_path_declaration` |
| `a-7-3` | `specify_input_terminal_descriptor`, `specify_output_terminal_descriptor` | `63` — `p`, `n` and `y` as the descriptors, on both sides of the path |
| `a-7-4` | `path_delay_value`, `list_of_path_delay_expressions` | `63` — both `path_delay_value` arms, the parenthesised `(tplh, tphl)` rise/fall list and the bare `1` |
| `a-7-5` | `system_timing_check` | `64_timing_checks_unsupported.va` — four of the twelve commands, chosen so every optional bracket of the three clauses below is taken at least once. Green: what a parser can check here is the NAME and the ARITY, and both are checked — A.7.1 admits no system task inside a specify block other than these twelve, and each fixes how many arguments are mandatory. The ARGUMENT union over-accepts, and the header says where: `$width`'s `controlled_reference_event` has a mandatory event control that nothing enforces |
| `a-7-5-1` | `$setup`, `$hold`, `$recovery`, … | `64` — `$setup(d, posedge clk, 1.5, notifier_flag);`, `$hold(posedge clk, d &&& (q == 1'b0), 1.5);`, `$width(posedge clk, 2.0);`, `$period(posedge clk, 4.0);`. The other eight commands are not spelled |
| `a-7-5-2` | `timing_check_limit`, `notifier`, `delayed_reference` | `64` — `timing_check_limit` is the `1.5`/`2.0`/`4.0` every command shares, and `notifier` is the declared `reg notifier_flag` in the `[ , [ notifier ] ]` bracket. `delayed_reference` has no fixture |
| `a-7-5-3` | `timing_check_event`, `controlled_reference_event` | `64` — `posedge clk` as a `timing_check_event_control`, a bare descriptor (`d`) with the control bracket omitted, the `[ &&& timing_check_condition ]` bracket (`d &&& (q == 1'b0)`), and the mandatory-control `controlled_reference_event` of `$width`/`$period`. `edge_control_specifier` is not spelled |
| `a-8` | heading | parent; `07_expressions.va` cites the bare `A.8` |
| `a-8-1` | `analog_concatenation`, `analog_multiple_concatenation`, `assignment_pattern`, `constant_assignment_pattern` | `24_expression_composites.va` (`{4'b1010, 4'b0101}` checked as 165, so the pack order is asserted and not assumed), `07_expressions.va` (`'{1.0, 2.0}` — the `constant_assignment_pattern`, which the file reads back element by element). `25_replication.va` is `analog_multiple_concatenation` (`{2{4'b0011}}` checked as 51, so the repeat count and the pack order are both asserted) |
| `a-8-2` | `analog_function_call`, `analog_system_function_call`, `analog_built_in_function_call`, `analog_filter_function_call`, `branch_probe_function_call`, `port_probe_function_call`, `analog_small_signal_function_call`, `analysis_function_call` | `23_expression_primaries.va` cites A.8.2 and holds four of these: a user `analog_function_call`, a `$pow` `analog_system_function_call`, a `branch_probe_function_call` over a named branch, and `I(<p>)` — the `port_probe_function_call`, whose angle brackets appear nowhere else in the directory. `07_expressions.va` adds `sin`/`cos` from `analog_built_in_function_name`. `analog_filter_function_call` is only `ddt` in `40_abstol_nature_identifier.va`, green; `ddx`, `idt`, `idtmod`, `absdelay`, `transition`, `slew`, `last_crossing`, `limexp`, the four `laplace_*` and the four `zi_*` names have no fixture here, nor do the small-signal or `analysis()` calls. `ch05_analog_behavior` owns those |
| `a-8-3` | `analog_expression`, `analog_conditional_expression`, `constant_expression`, `abstol_expression`, `indirect_expression` | `07_expressions.va` (binary, `**` precedence against `*` checked numerically, and `?:`), `24_expression_composites.va` (the `unary_operator analog_primary` arm via `~`, plus `?:`). `abstol_expression ::= … | nature_identifier` is `40_abstol_nature_identifier.va`, which cites A.8.3 and is the only file that writes a bare nature name in expression position — green, and it asserts both arms give the same value. `indirect_expression` is `21` (green). The `{ attribute_instance }` slot on operators is `ch02_lexical`'s, not here; `mintypmax` and the `module_path_*` family have nothing |
| `a-8-4` | `analog_primary`, `constant_primary`, `primary` | `23_expression_primaries.va` cites A.8.4 and reaches `number`, `variable_reference` with a word select, `analog_function_call` and `analog_system_function_call` in adjacent statements. `24` adds `analog_concatenation` and parenthesized subexpressions; `07` adds `parameter_reference` with an index. `genvar_identifier` as a primary is `09` (green); `nature_attribute_reference` (`net.potential.abstol`) has no fixture anywhere in the directory |
| `a-8-5` | `analog_variable_lvalue`, `branch_lvalue`, `variable_lvalue`, `net_lvalue`, `array_analog_variable_assignment` | `29_contribution_to_variable_rejected.va` cites A.8.5 and pins the boundary: `x <+ 1.0` where `x` is `real` is `//! reject E0408`, because `branch_lvalue ::= branch_probe_function_call` and nothing else. The indexed arm of `analog_variable_lvalue` is `23` (`array[0] = …`, `array[1] = …`). `net_lvalue`, the braced concatenation lvalue, and `array_analog_variable_assignment` from an `assignment_pattern` rvalue: no fixture |
| `a-8-6` | `unary_operator`, `binary_operator`, `unary_module_path_operator` | `07_expressions.va` (`+`, `*`, `**`, `>`, `?:`) and `24_expression_composites.va` (`~`, `<<`, `&`, `>`). `65_operators.va` is the census that cites the clause by number: every legal spelling in the four lists, 25 value assertions, and the three that read NEGATIVE (`~4'b0101` is -6, `^~`/`~^` are -7) explained line by line — the destination fixes the width the right-hand side is evaluated at, so the 4-bit answer is the wrong answer in a 32-bit context. The reduction and arithmetic-shift spellings are absent because §4.2.10/§4.2.11 forbid them in analog; the module-path lists are absent because no analog production reaches `module_path_expression`. `66_case_equality_in_analog.va` is `===`/`!==`, which §7.3.2 lists as SUPPORTED in the analog context and VerA refuses — `//! xfail`. Clause 4 still owns what the operators mean; what these two files pin is the list |
| `a-8-7` | `number`, `decimal_number`, `real_number`, `hex_number`, `sign`, `size`, `unsigned_number` | `24_expression_composites.va` (`4'b1010`, `4'b0101`, `8'h0f` — sized based numbers in three bases), `03`/`07` (real and integer decimals), `01` (`1u` and `1p` scale factors in the nature attributes). `36_real_embedded_space_rejected.va` cites A.8.7 and pins the negative: `1.5 e3` is `//! reject E0207`. The full number grammar is `ch02_lexical`'s `s2-6`, sixty files of it |
| `a-8-8` | `string` | `67_string_literal.va` cites it by number and is what the production MEANS: §2.7's "unsigned integer constants represented by a sequence of 8-bit ASCII values" is not a parse claim, so every row of Table 2-2 is assigned to an `integer` and checked — `"A"` = 65, `"AB"` = 0x4142 = 16706 (the pack order, which no single-character check would catch), `""` = 0, `\n` = 10, `\t` = 9, `\\` = 92, `\"` = 34, `\101` = 65, `\1` = 1, and `"A" == "\101"` as the round trip. The other users are `03_declarations.va` (`string label = "declarations";`), `38_analog_function_integer_string.va` (a `string`-typed analog function returning `"hi"`), `20` (`$display("%g", x)`), `01` (`units = "V"`); see the prose on `string_declaration` below |
| `a-8-9` | `branch_reference`, `analog_port_reference`, `analog_net_reference`, `variable_reference`, `parameter_reference`, `net_reference`, `nature_attribute_reference` | `23_expression_primaries.va` cites A.8.9: `V(path)` is `nature_access_function ( branch_reference )`, `I(<p>)` an `analog_port_reference`, `array[0]` an indexed `variable_reference`. `V(p, n)` — the two-`analog_net_reference` arm — is in nearly every file. `39_branch_array.va` takes `branch_reference ::= hierarchical_branch_identifier [ constant_expression ]`, is the only file that does, and is green. `hierarchical_unnamed_branch_reference` and `nature_attribute_reference` have no fixture: both need hierarchy |
| `a-9` | heading | parent |
| `a-9-1` | `attribute_instance ::= (* attr_spec { , attr_spec } *)`, `attr_spec`, `attr_name` | `08_attributes_comments_identifiers.va` (`(* annex = "A.9" *)` prefixing a module declaration — the `attr_name = constant_expression` arm), `22_null_attributed_statements.va` (two valueless attributes, `(* conditional_null *)` on a null statement and `(* contribution_attr *)` on a contribution, which is the bare `attr_name` arm in statement position). The exhaustive attribute placement work is `ch02_lexical`'s `s2-9`, which has eight files to these two |
| `a-9-2` | `comment`, `one_line_comment`, `block_comment`, `comment_text` | `08_attributes_comments_identifiers.va` — both forms, inside a module body, one after the other. Every other file uses `//` in its header, but `08` is the one that puts a comment where a statement could go and proves it vanishes |
| `a-9-3` | `identifier`, `simple_identifier`, `escaped_identifier`, the hierarchical family, `system_*_identifier` | `08_attributes_comments_identifiers.va` (`\punctuated+identifier` declared, assigned and read — an `escaped_identifier` whose body contains a character `simple_identifier` cannot hold), `35_escaped_system_identifier_rejected.va` (`\$vt` — `//! reject E0314`, conforming: an escaped `$vt` is an ordinary user name and resolves to nothing). `hierarchical_identifier` is `12`'s `child.gain`, green. Simple identifiers are everywhere and asserted nowhere here; `ch02_lexical`'s `s2-8` owns them |
| `a-9-4` | `white_space ::= space \| tab \| newline \| eof` | `68_white_space.va` — the file whose separators ARE the test: runs of tabs across every keyword/identifier boundary of the module header (where white space is mandatory and a dropped separator would fuse two tokens), a form feed on its own line before `analog`, and **no trailing newline**, so the last token abuts `eof`, the fourth alternative. It asserts a value, so a lexer that stopped at a form feed or swallowed a separator would have to do it while still computing 120. The header records that A.9.4's own list says `eof` and §2.3's prose says form feed — two different lists of one thing — and that §2.3's "spaces and tabs are significant in strings" is A.10's, which `36_real_embedded_space_rejected.va` owns |
| `a-10` | Details: the five footnote rules — function statements limited by 4.7.1, embedded spaces illegal, `simple_identifier` shape, `$` not followed by white space, system identifiers not escapable | `35_escaped_system_identifier_rejected.va` and `36_real_embedded_space_rejected.va` both cite A.10 and take one sentence each (the fifth and the second). `04`/`37`/`38` exercise the first through 4.7.1 without citing A.10. The third sentence (`simple_identifier` shape) and the fourth (`$` followed by white space) have no fixture here — `ch02_lexical` has `17`, `47`, `18` and `60` for exactly those |

## The xfail ledger

The clause rows that used to say "no fixture" did not all become green fixtures; fifteen
of them became `//! xfail` files, because the source they spell is derivable from Annex A,
is required by §1.1, and VerA refused it. Each of the fifteen carried an assertion so the
day the gap closed the file would XPASS and name itself rather than decaying into
`unasserted`. **Fourteen have.** The fifteenth, `46_library_source_text.va` (`a-1-1`), was
withdrawn: its want was unmeetable (below) and it is now `//! reject E0232`. None is open.

`46` is not an unimplemented production: its
`library_declaration` is reachable from `library_text` and from nothing else — the annex
preamble gives a library map file its own starting symbol, and A.1.2's `description` list
does not contain a `library_description` — so the text is read in full and then refused by
a code that names the starting symbol rather than the subset. What is missing is a library
map READER, a second front end; no growth of the analog subset makes this legal in a
`.va`, which is why E0201 was the wrong verdict in both directions.

The fourteen that closed, and what each does instead:

| Fixture | Section | Was | Is now |
|---|---|---|---|
| `47_configuration_source_text.va` | `a-1-5` | E0201 `config` | Accepted. A.1.2 lists `config_declaration` as a `description`. W0253 — no library map, so it binds nothing |
| `49_specparam_declaration_unsupported.va` | `a-2-1-1` | E0205 `specparam` | Accepted as a `localparam`: A.2.4 gives it a mandatory constant default no parameter value assignment can name |
| `50_ranged_parameter_unsupported.va` | `a-2-1-1`, `a-2-5` | E0208 at `[` | Accepted. The width reaches `ParamDecl.packed_range`; §3.4.1's type inference is unchanged, so `nib` is 5 |
| `51_output_variable_type_unsupported.va` | `a-2-1-2`, `a-2-2-1` | E0208 at `integer` | Accepted, both variable arms. The name list becomes VARIABLES as well as ports |
| `53_variable_initializer_unsupported.va` | `a-2-2-1`, `a-2-3` | E0207 at `=` | Accepted. A.2.2.1's `variable_type` is read whole for `reg`, as it already was for its four siblings |
| `54_drive_strength_unsupported.va` | `a-2-2-2` | E0207 at the `,` | Accepted. A comma after the first strength word tells A.2.2.2's pair from A.2.2.1's single-word `charge_strength` |
| `55_net_delay_unsupported.va` | `a-2-2-3` | E0207 "no meaning outside a digital design element" | Accepted. `delay3` was already parsed; the rule that refused it was a semantic verdict written as a syntax one |
| `56_gate_instantiation_unsupported.va` | `a-3-1`, `a-3-3`, `a-3-4` | E0205 `and` | Accepted. W0252 — §8.5.3.5 puts gate-level modeling in the event-driven half, and an analog device has no queue |
| `57_primitive_strengths_unsupported.va` | `a-3-2` | E0205 `pulldown` | Accepted, with both of A.3.2's differences from A.2.2.2 enforced. W0252 |
| `58_udp_declaration_unsupported.va` | `a-5-1`, `a-5-2`, `a-5-3` | E0201 `primitive` | Accepted. A.1.2 lists `udp_declaration`. The table is validated as a CHARACTER alphabet (E0233/E0234) and dropped |
| `59_udp_instantiation_unsupported.va` | `a-5-4` | E0205 at the identifier | Accepted. Told from A.4.1 by one token: `module_instance`'s name is mandatory, `udp_instance`'s is not. W0252 |
| `63_specify_block_unsupported.va` | `a-7-1` … `a-7-4` | E0205 `specify` | Accepted, all five `specify_item` arms read. W0251 — its whole content is §8 scheduling |
| `64_timing_checks_unsupported.va` | `a-7-5` … `a-7-5-3` | E0205 `specify` | Accepted. The name and the arity of A.7.5.1's twelve commands are checked; the argument union over-accepts and `64`'s header says where |
| `66_case_equality_in_analog.va` | `a-8-6` | E0323 "case equality is not in the analog subset" (lowering) | Accepted. On two-state operands `===`/`!==` lower as `==`/`!=` (IEEE 1364 §5.1.8); the real-operand case is E0369 (§4.2.1); E0323 is retired |

They were three shapes of one problem, and the closures split the same way. Nine were an
unrecognised CONSTRUCT — `library`/`config`/`primitive` at the top level,
`specparam`/`and`/`pulldown`/`specify`/a UDP instance as a module item — and eight of
those needed a real parser arm, which they have; the ninth is `46`, which needs a
subsystem and still does. Five were a missing optional part of a declaration VerA
otherwise parsed — a parameter range, an `output` variable type, a drive strength, a net
delay, an initializer — where the fix was a production rather than a subsystem, and all
five closed. One — `66` — was neither.

Twelve of the fifteen cited §1.1 as the reason they must eventually pass: the complete
IEEE Std 1364 Verilog is part of Verilog-AMS HDL, and Annex C.16's nine exemptions do not
cover gates, UDPs, specify blocks or library/config text. The other three (`50`, `53`,
`66`) are analog-subset questions and cite only the clause they exercise.

WHAT THE THIRTEEN CLOSURES DO NOT CLAIM. Four of them are grammar coverage over a
construct that reaches no device — `47` (W0253), `56`/`57`/`59` (W0252), `63`/`64`
(W0251) — so a green row there is evidence that the production is derivable and read, and
not that the timing, the resolution or the library binding it describes is honoured.
PLAN.md §5's point about one-way evidence applies to those six exactly as it does to a
refusal-only clause: the warning is the marker that used to be an `//! xfail` line, moved
from the fixture into the compiler where every compile has to see it.

The rows below are the last ones this ledger used to hold, kept as the record of what
closed them. The six numbered groups after them are kept too: each was a prediction this
document made about how the fixtures would fall, and each turned out to be right.

| Fixture | Section | Disposition |
|---|---|---|
| `10_paramset.va` | `a-1-9` | Green. The paramset is parsed and instantiated; §6.4's own `pickTop` consequence is that the module it specializes is not a root |
| `11_module_instantiation.va` | `a-4-1` | — green now; `ir/elaborate.zig` flattens the instance tree and E0204 is retired |
| `12_defparam.va` | `a-1-4`, `a-2-4` | Green. §6.3.1's override is applied at elaboration, keyed by the dotted path |
| `21_indirect_contribution.va` | `a-6-10` | Green. The LRM's own ideal opamp closed around a 1:1 feedback pair, so the §5.6.7 constraint `V(out): V(in) == 0` has a unique solution `V(out) = -V(p)`; `//! solve` leaves `out` and `in` to the testbench's Newton loop, and the tolerance is annex D's `VOLTAGE_ABSTOL` |

Grouped by the defect rather than by the fixture, the fourteen rows were six problems, and
all six are closed:

1. **No hierarchy — closed.** `10`, `11`, `12` all instantiate and all three are green.
   E0204 used to be reported before anything else in the file could be judged; `12`'s
   `defparam` and `10`'s `paramset` were downstream of that same wall, each with its own
   second gap behind it, which is why closing instantiation alone XPASSed none of them.
   Both second gaps are closed now: a `defparam` production and a `paramset` parser.
2. **No case generate.** Closed. `15` alone, and it was one production: the arms of a
   `case_generate_construct` are `generate_block_or_null` where A.6.7's are
   `analog_statement_or_null`, so one parameter on the existing `case` parser covers both.
   `case` is still E0205 at module scope with no `generate` above it, which is what the rest
   of the suite pins.
3. **The module header parser.** Closed. `13`, `41` and `42` were three arms of A.1.3 that
   `lib/frontend/parser.zig` did not have, each dying at the same point in the header with a
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
6. **The testbench does not solve.** Closed. `21` alone, and it was never a frontend bug:
   `lib/backend/tb.zig` used to write `//! bias` values directly into `x[]`, so no
   indirect contribution's constraint was ever enforced. It runs Newton-Raphson on the
   device residual now, and `//! solve` frees the unknowns the fixture does not pin — which
   is the only way `21` could go green without deleting what it asserts. This was the one
   row a parser change could not have touched.

`43` (macromodule) was deliberately left out of that list as a one-keyword alias for
`module` whose fix was one token in the dispatch. It was.

## Rejection evidence depends on context

Fifteen files carry `//! reject`. Their passing status alone does not establish
full-AMS conformance. Twelve exercise
A.6.4's boundary between `statement` and `analog_statement` — `force`, `<=`, `fork…join`,
`wait`, `#5`, `disable`, `break`/`continue`/`return`, a user task enable, a contribution
inside an event statement, an indirect contribution inside one, a nested event
control, and `forever`. An invalid analog or event-context use must be rejected by its
grammar or §5.10 rule. Annex C’s exclusion of a construct from Verilog-A, however, does
not justify rejecting its legal full-AMS use; those uses need positive coverage — the
fifteen rows that began as `//! xfail` above are exactly that coverage, written as xfails instead of
being spelled as rejections the LRM does not support. The remaining three are `29` (`<+`
to a variable, which `branch_lvalue` forbids outright), `35` (`\$vt`, where 2.8.1 makes
the escaped form an ordinary name), and `36` (`1.5 e3`, A.10's embedded-space sentence).

Five of the twelve collapse to the same E0209 — `force`, `fork`, `wait`, `#5` and
`forever`. That is the parser's generic "expected an expression" and not a considered
diagnosis of what the construct is. The fixtures pin the code that fires today. A better
diagnostic should identify the invalid context, while legal digital uses need
implementation and behavioral tests rather than a subset rejection.

## What is not covered

Eleven headings have no fixture, and every one of them states no requirement a compiler
can be held to — ten that carry an id, and the annex's own title line:

**The parent headings (ten).** `a-1` (A.1 Source text), `a-2-1` (A.2.1 Declaration
types), `a-2-2` (A.2.2 Declaration data types), `a-3` (A.3 Primitive instances), `a-4`
(A.4 Module instantiation and generate construct), `a-5` (A.5 UDP declaration and
instantiation), `a-6` (A.6 Behavioral statements), `a-7` (A.7 Specify section) and `a-9`
(A.9 General) — nine ids — plus the annex's own `<h1>`, which carries no `id` at all.
Each is the title line above a numbered section of productions; the productions are what a
fixture can exercise, and every one of them has a fixture. Writing a file to "cover"
`a-6`, say, would mean citing it from a fixture that
reaches `a-6-4`, which is a citation bought with nothing behind it — the thing this
document's own rule forbids.

**The sub-headings (one).** `a-7-5` (A.7.5 System timing checks) is a bare `<h4>` between
`a-7-4` and `a-7-5-1`, the same case one level down; `64_timing_checks_unsupported.va`
cites its three children.

Three more ids carry no production either and are cited anyway, as context, by fixtures
that reach the construct through a subsection: `a-2` (cited by `03_declarations.va`),
`a-8` (`07_expressions.va`) and `a-10` (`35`, `36`). They are counted as covered because
those citations are honest — a file that exercises `a-2-3` does exercise A.2 — but the
distinction is worth keeping: being cited is not the same as being pinned.

**Every other row in this table is backed by a file**, here or elsewhere in the suite: the
one row this directory writes nothing for is `a-6-1`, and `annex_c_analog_subset/23_
continuous_assign_rejected.va` is the file that cites it. That includes `a-2-8` (block item
declarations), which earlier revisions of this document listed as an uncovered id: no
fixture in THIS directory declares anything inside a block, but `ch02_lexical/55_
attribute_block_item_and_function_port.va` cites A.2.8 by number and spells the attributed
form of the same slot in a named analog block and in an analog function body. That is one
file elsewhere in the suite, not a gap here. The uncovered set is exactly the eleven
headings named above.

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

**The `//! bias` caveat, and where it stops.** A `//! bias` line still pins the unknown it
names: `lib/backend/tb.zig` loads it and, absent `//! solve`, leaves it there, so a `CHECK`
that reads a biased node reads the bias it declared and not a solved operating point. That
is fine for the fifty-one run fixtures here, which only probe their own biased ports. It is no
longer a ceiling on the directory: `//! solve` frees the rest of the vector to Newton-Raphson
on the device's own residual, which is what let `21` — an indirect contribution, whose entire
content is a value the solver must find — go green without weakening its check.

**One violation per file.** A `//! reject` fixture stops at its first diagnostic, so
A.6.4's twelve boundaries cannot share a module. That is why `26` through `34` are nine
near-identical one-line modules; the differences are the single illegal statement and the
expected code. Reading them side by side is the fastest way to see where the analog
subset's edge actually is. The files that began as `//! xfail`s obey the same rule for the
same reason, one construct each — which is why `63`/`64` are two files for one section and
why `56`/`57` are two files for one family of primitives. Now that all four are green the
split earns something it could not before: they no longer share a diagnostic, so each
measures its own clause.

**Positive/negative pairs.** Several productions are only closed by both halves, and the
files are written to be read together: `04` ↔ `37` (the `[ analog_function_type ]` bracket
present and absent), `04`/`37` ↔ `38` (the `real` default against the `integer` and
`string` arms), `03` ↔ `07` (the two arms of `param_assignment`), `23` ↔ `39` (a scalar
branch reference against an indexed one), `24` ↔ `25` (concatenation against replication),
`21` ↔ `27`/`29` (indirect contribution where it is legal, and the two places it is not),
`06` ↔ `28`/`17` (event control that works, nesting that must not, and the named-event
declare/trigger/detect form, which works too), `08` ↔ `35` (an escaped identifier that names something against one
that cannot). The later files add their own set, and in each the pair is what separates
"the grammar admits this form" from "the form means something": `61` ↔ `62` (three analog
loop forms accepted against the digital `forever` refused), `52` ↔ `53` (a vector variable
declared bare against the same variable with an initializer), `50`/`53`/`54`/`55` (the four
declaration brackets against the same declarations written without them, which `52` runs),
`54` ↔ `57` (the `strength` bracket on a net declaration and on a pull gate, two spellings
of `strong0`/`pull0` — and, since A.3.2 is read as itself rather than as A.2.2.2, the pair
that shows the two clauses are not one), `58` ↔ `59` (the UDP declaration and its
instantiation, which used to be refused by different stages in different words and are now
told apart by one token), `56`/`57` ↔ `63`/`64` (three module-item families that shared one
E0205 and now share one §8 reason for reaching no device), `65` ↔ `66`
(`===` refused where §7.3.2 supports it, against the rest of the operator list evaluated),
`46` ↔ `47` (the two A.1.1/A.1.5 arms that used to be refused as one family and now part
company — A.1.2's `description` list holds one of them and not the other, which is the
whole of why one is green and one is still an xfail), and
`67`/`68` standing alone as the two rows that are about what a LITERAL and a SEPARATOR are
rather than about a construct.

**Where this directory deliberately stops.** Annex A is a grammar, so the temptation is to
write one fixture per production and end up with a parser test suite that asserts nothing.
The rule followed here is that a fixture must *check a value* (`CHECK`, `CHECKX`, `CHECKI`,
`CHECKEQ`) or *pin a diagnostic* (`//! reject`); nothing is credited for merely parsing,
and an `//! xfail` is a third case with the same discipline, because it states what the
compiler does today and what the LRM requires instead. That is why the number and
identifier rows still point at `ch02_lexical` and `ch04_expressions`: those chapters own
the semantics. Where this directory does now duplicate them — `65` (operators), `67`
(string literals) and `68` (white space) — the ground is different on purpose: those three
are A.8.6, A.8.8 and A.9.4's own rows, and what they pin is the list of spellings and the
value each one produces, not the fifty conversions and precedences `ch04` proves.

**One VerA observation this directory found and did not pin.** `65` was first written with
a `reg [3:0]` on the left of the three negating operators, so that the destination and the
operand would agree on 4 bits and the values would be the operators' own truth tables. It
failed, and the transcript is in that file's history: `nib = ~4'b0101;` read back as -6,
`nib = 4'b1100 ^~ 4'b1010;` as -7, while `nib = 4'b1100 & 4'b1010;` read 8. A 4-bit
destination storing -6 is not truncation to four bits, and since `&` gave the unsigned 8
the values are not being sign-extended on read either. The most economical explanation is
that the assignment does not truncate to the destination's width — but that has not been
isolated, and it is `ch03_data_types`' question, not Annex A's. The fixture therefore uses
`integer` destinations, where the 32-bit answers (-6, -7) are the correct ones and are what
the header derives; the observation is recorded here so it is not rediscovered as a bug in
one of the operator checks.
