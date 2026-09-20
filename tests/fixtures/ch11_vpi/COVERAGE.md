# Chapter 11 coverage

Source: `docs/ch11-vpi.html`, read section by section.

HTML section-ID audit: `s11-1` `s11-2` `s11-2-1` `s11-2-2` `s11-2-3` `s11-3` `s11-3-1` `s11-3-2` `s11-4` `s11-5` `s11-5-1` `s11-5-2` `s11-5-3` `s11-6` `s11-6-1` `s11-6-2` `s11-6-3` `s11-6-4` `s11-6-5` `s11-6-6` `s11-6-7` `s11-6-8` `s11-6-9` `s11-6-10` `s11-6-11` `s11-6-12` `s11-6-13` `s11-6-14` `s11-6-15` `s11-6-16` `s11-6-17` `s11-6-18` `s11-6-19` `s11-6-20` `s11-6-21` `s11-6-22` `s11-6-23` `s11-6-24` `s11-6-25`. 39 ids, 19 with a fixture.

VPI is a C API. Nothing in this clause has a Verilog-A spelling, so no fixture
here can test VPI. What a fixture *can* test is the language-level fact each
object-model diagram describes — that a port reaches its own node, that a
branch carries two distinct quantities, that a case item groups several
conditions. Each row below says which fixture pins that fact and which
`//! lrm` cite makes the connection; where no fixture does, the cell is empty
on purpose.

27 `.va` files: 2 carry a `//! reject` arm, 25 run and assert, and NONE is `//! xfail`
(grep-measured over this directory). A 28th, `p02_analog.va`, is not a fixture
but the design the compiled-C rows register against — it carries no `//! lrm`
cite and no assertion, and is counted here only so the grep above reconciles.

| Documentation id | Fixture or disposition |
|---|---|
| `s11-1` | Scope statement for Clauses 11 and 12. No rule. |
| `s11-2` | Names the two functional areas. No rule. |
| `s11-2-1` | `10_c_vpi_register_cb_not_va.va` (`//! lrm 11.2.1`, `//! reject E0512`) pins the one thing source can observe: `vpi_register_cb` has no Verilog-A spelling, so it is an undeclared function call per §4.7. Registration itself is C-side and untestable here. `08_callback_call_site.va` is the nearest language analogue (see below), but it cites §11.6.25, not this section. |
| `s11-2-2` | Instance-unique access (`m1.w` vs `m2.w`) needs an instantiated design; every fixture here is a single uncompiled module. |
| `s11-2-3` | `vpi_chk_error()`. C-only; belongs to `ch12_vpi_routines`, where `03_chk_error_not_va.va` (`//! lrm 4.7`, `//! lrm 12.2`) rejects the name. The clause's own requirement — a nonzero return after a failed call — is what the routine *does*, and no source text can observe it. |
| `s11-3` | Explains what a data model diagram is. No rule. |
| `s11-3-1` | `vpiHandle`, `vpi_handle()`, `vpi_handle_by_name()`, `vpi_get()`, `vpi_get_str()`, `vpi_iterate()`, `vpi_scan()` — C-only. Every routine in the section's examples has its own one-routine `//! reject` fixture in `ch12_vpi_routines` (`30`, `32`, `16`, `23`, `34`, `46`; `//! lrm 12.19`/`12.21`/`12.5`/`12.12`/`12.23`/`12.35`), so the section is *deferred* to §12 and not uncovered — but no fixture cites §11.3.1, and none should: the section states no rule of its own. `09_c_vpi_get_not_va.va` rejects the same *name* under §11.4. |
| `s11-3-2` | `vpi_get_delays()`, `vpi_put_delays()`, `vpi_get_value()`, `vpi_put_value()`, `vpi_handle_multi()` — C-only, and likewise deferred: `22`, `40`, `27`, `41` and `33` in `ch12_vpi_routines` reject each name under its §12 cite. The clause's one normative-looking sentence — "Properties are of type integer, boolean, real or string" — describes C structure members, not source types. |
| `s11-4` | `09_c_vpi_get_not_va.va` (`//! lrm 11.4`, `//! reject E0512`, `//! reject \`vpi_get\``). Tables 11-1/11-4 name `vpi_get` as a C routine; the fixture proves a compiler does not silently accept it as a Verilog-A function. The routine tables themselves are inventoried in `ch12_vpi_routines/COVERAGE.md`. |
| `s11-5` | Diagram legend. No rule. |
| `s11-5-1` | Legend for object/class boxes. No rule. |
| `s11-5-2` | Legend for `->` property rows. No rule. |
| `s11-5-3` | Legend for relationship arrows. No rule. |
| `s11-6` | Parent of the 25 diagrams. No rule of its own. |
| `s11-6-1` | `01_module_port_node.va` (`//! lrm 11.6.1`) — module with a header port list; the module-to-ports edge, read as "each header port binds to its own node" via §5.4.1. |
| `s11-6-2` | `11_nature_discipline_objects.va` (`//! lrm 11.6.2`) — `electrical` from `disciplines.vams`, its potential nature's `access V` and the antisymmetry of `V(n,p)`. The `vpiPotentialNature`/`vpiFlowNature` edges have no source spelling; the access functions they lead to do. |
| `s11-6-3` | `12_function_io_objects.va` (`//! lrm 11.6.3`) — `taskfunc` -> `io decl` one-to-many: two declared inputs bound in order, plus the NOTE's implicit function-name variable. The `scope` half is exercised by the named blocks in `07_process_statement_objects.va` (`: process_block`) and `24_named_process_object.va` (`: behavior`), though both cite §11.6.21. No `task`, no `def param`, no `named event` in scope. |
| `s11-6-4` | `01_module_port_node.va`, `13_port_node_objects.va` (both `//! lrm 11.6.4`). `13` is the one that pins `vpiDirection`: an `input sense` alongside `inout p, n`, three distinct biases, so mis-binding the directional port fails a number. No port bits, no `vpiHighConn`/`vpiLowConn` (nothing is instantiated), no vector ports. |
| `s11-6-5` | `01_module_port_node.va`, `13_port_node_objects.va` (both `//! lrm 11.6.5`) — the ports-to-nodes edge. Node *bits*, `vpiBit`/`vpiParent` and the range relations are untouched: every net here is scalar. |
| `s11-6-6` | `14_branch_object.va` (`//! lrm 11.6.6`) — `branch (p,n) path`, whose `vpiPosNode`/`vpiNegNode` show up as §5.4.1's `V(p) - V(n)`. `02` and `15` also declare named branches but cite §11.6.7. Bit-level branches unexercised. |
| `s11-6-7` | `02_branch_quantity.va`, `15_quantity_objects.va` (both `//! lrm 11.6.7`) — the diagram's `vpiFlow`/`vpiPotential` pair as two *different* objects. Both drive the branch as a potential source so the flow is a genuine solve unknown (§5.4.2.2), held by `//! sweep flowZ28pZ2cnZ29`, and both assert a value the potential cannot supply. Both headers record that an earlier revision asserted the potential twice and so passed on a compiler with no flow quantity at all. |
| `s11-6-8` | No fixture, and no `.va` can be one: the section's requirements are its fifteen `->` rows (`vpiNetType`, `vpiImplicitDecl`, `vpiExpanded`, `vpiNetDeclAssign`, `vpiStrength0`/`vpiStrength1`/`vpiChargeStrength`, `vpiDomain`, …) and NOTES 1–8, and every one of them is a sentence about what a VPI routine shall return. The language facts the diagram is drawn over are pinned under their own clauses — drive-strength resolution in `digital/d03_*` (D03), net delay and `wire w = expr` in `digital/d06_net_delay.v` and `d06_net_decl_assign_delay.v` (D06) — and neither SPEC names §11.6.8, because neither is evidence for it. |
| `s11-6-9` | No fixture. `reg r;` parses, but the section's content is `vpi_get_value()`/`vpi_put_value()` on a reg bit, the `vpiPortInst`/`vpiHighConn`/`vpiLowConn`/`vpiDriver`/`vpiLoad` edges, and NOTES 1–3 governing what `vpiLoad` and `vpiDriver` return. A `.va` file reads no handle, so there is nothing here for such a fixture to be wrong about. |
| `s11-6-10` | `03_parameters_variables.va`, `16_variable_objects.va` (both `//! lrm 11.6.10`) — `integer var` and `real var` as distinct objects, separated by §4.2.1.3 arithmetic conversion (truncating to the integer's type gives a different number). No `time var`, no `var select`, no arrays, and the section's `named event` half is absent. |
| `s11-6-11` | No fixture. A memory is `reg [range] name [range]`; the second range does not parse (E0207), which is consistent with the module items annex A.1.4 admits. Both NOTES are `vpiSize` return values — the word count, then the bits per word. The nearest analog-subset construct, `var select`, belongs to §11.6.10 and is unexercised there too. |
| `s11-6-12` | `17_parameter_object.va` (`//! lrm 11.6.12`) for the un-overridden default, `03_parameters_variables.va` (`//! lrm 11.6.12`, `//! param gain = 3.0`) for the overridden value. `21_simple_expression_object.va` reuses a parameter as its leaf operand. `specparam` never appears. |
| `s11-6-13` | No fixture, and the construct is outside the analog subset: `and g1(o,a,b);` is E0205 (`unsupported module item`, annex A.1.4). The subject matter — gate, switch, udp and device instantiation, and their term directions and indices — is `digital/d08_*` (D08, gates/switches/UDPs), cited to that row's own clauses. NOTES 1–2 are a `vpiSize` return and a restriction on when `vpi_put_value()` may be used. |
| `s11-6-14` | No fixture. A UDP is a `primitive` definition carrying a table, and `primitive` is not an item annex A.1.4 admits; D08 carries the UDP language fixtures under its own clauses. The section's properties (`vpiDefName`, `vpiLineNo`/`vpiFile`, `vpiSize`, `vpiProtected`, `vpiPrimType`) and the table entry's `vpiSize` are all C, and the single NOTE constrains what `vpi_get_value()` may return for a table entry. |
| `s11-6-15` | No fixture, and none anywhere in the tree. `specify`/`endspecify` is E0205, and no file under `tests/fixtures/` defines a timing check: the only trace of the family is `annex_b_keywords/09_specify_keywords.va`, which censuses the reserved spellings (`edge`, `ifnone`, `pulsestyle_onevent`, …) under `//! lrm B` and never opens the block. The section's three diagrams (mod path, tchk, inter mod path) are reached only through C, and its two NOTES are about `vpiTchkRefTerm` order under `$setup` and `vpi_handle_multi(vpiInterModPath, …)`. Nothing can be cited here until a `specify` front end exists to have a behaviour. |
| `s11-6-16` | Six fixtures, all `//! lrm 11.6.16`, split three ways. `func call`: `04_function_call_object.va` and `18_function_call_object_atomic.va` (§4.7.1/§4.7.2.1, return via the function-name variable; `18` adds a literal argument). `tf call` on the statement side: `05_system_task_call_object.va` (`$display`) and `19_system_task_call_object_atomic.va` (`$strobe`) — both pin §5.3.1 order across a valueless call. `sys func call` in operand position: `06_system_function_call_object.va` (`$mfactor`, §9.18) and `20_system_function_call_object_atomic.va` (`$temperature` at `//! temp 350.25`, §9.15, which pins the `real` return the diagram's `vpiSysFuncType` implies). `05`, `06` and `08` all record that earlier revisions used unregistered `$fixture_*` names, which §2.8.3 neither requires a compiler to accept nor to reject. |
| `s11-6-17` | No fixture. `assign` is E0205 (annex A.1.4), and its rejection is already pinned under C.7 in `annex_c_analog_subset/23_continuous_assign_rejected.va`. The semantics the diagram is drawn over are D06's, in `digital/d06_*`, whose SPEC cites §11.6.17 nowhere. Three properties (`delay`, `location`, `strength`) are `vpi_get_delays()`, a source position and the strength pair; the fourth, `net decl assign`, is the `wire w = expr;` form D06 also covers. |
| `s11-6-18` | `21_simple_expression_object.va` (`//! lrm 11.6.18`) — the leaf, name-bearing operand, here a parameter. Its header is explicit that `gain + 1.0` is *not* a simple expr but §11.6.19's operation above it, correcting an earlier revision that labelled it so. `net`/`reg`/`memory`/`var select`/`memory word` leaves and the `vpiUse` edge are all absent. |
| `s11-6-19` | `21_simple_expression_object.va` (`//! lrm 11.6.19`) for `operation` over a `simple expr` and a `constant`; `22_operation_access_objects.va` (`//! lrm 11.6.19`) for `accessfunc` operands under `abs()` and multiplication, at a negative bias so `abs` is separable from identity. `part select` and `analog oper` are not exercised here. |
| `s11-6-20` | `23_contribution_object.va` (`//! lrm 11.6.20`) is the `flow` contribution; `27_potential_contribution_object.va` (`//! lrm 11.6.20`) is the `potential` one and is the only fixture that discriminates `vpiFlow`, via the §5.4.2.2 consequence that a potential source leaves its flow a free unknown (0.125 A) where a flow source would fix it at the source value (1.25 A). The class's `ind flow`/`ind potential` members — indirect contribution — appear in no fixture here. |
| `s11-6-21` | `24_named_process_object.va` (`//! lrm 11.6.21`) for `analog` process + `named begin`; `07_process_statement_objects.va` (`//! lrm 11.6.21`) for a named block containing `for`, `if else` and `case` from the `atomic stmt` list. `08_callback_call_site.va`'s `@(initial_step)` is the only `event control` in the folder. `initial`, `always`, `fork`, and the section's `event stmt ->` object are absent here and remain required full-AMS object-model coverage. |
| `s11-6-22` | `25_assignment_loop_objects.va` (`//! lrm 11.6.22`) — `assignment` plus the §5.9.2 `for`, pinning both the trip count and the value `k` is left at. `07` repeats the same shape. `delay control` (`#`) and `repeat control` never appear; `event control` (`@`) appears only in `08`, which cites §11.6.25. |
| `s11-6-23` | `26_conditional_case_objects.va` (`//! lrm 11.6.23`) is the thorough one: `if else` on a false relation (§4.2.5's integer 0), `case` falling to `default`, and a second `case` whose item `1, 2, 3:` pins NOTE 1's one-to-many case-item-to-expr edge — a compiler reading only an item's first expression lands on a different number. `07_process_statement_objects.va` (`//! lrm 11.6.23`) covers the matching-item path. No `casex`/`casez`. |
| `s11-6-24` | No fixture. `disable` is the one of the five keywords the analog subset keeps — it is real and tested, under `//! lrm 5.3`/`5.10`/`5.10.2` in `ch05_analog_behavior/a03_01…a03_03` and under A.6.4/A.6.5 in `annex_a_syntax/18_disable_statement.va` — but those cite the statement's semantics, not this object. `force` inside an `analog` block is E0209 (`annex_a_syntax/30_force_in_analog_rejected.va`, `//! lrm A.6.4`/`A.6.2`), `assign w = 1'b1;` is E0205, and `deassign`/`release` are the same procedural-continuous-assignment path. The diagram's content is two unnamed classes' `vpiLhs`/`vpiRhs` edges and the `disable` object's `vpiScope`, plus one property, `location`. |
| `s11-6-25` | `08_callback_call_site.va` (`//! lrm 11.6.25`) — the class's callback-to-`stmt` edge. There is no Verilog-A way to register a callback, so the fixture substitutes the other kind of simulator-invoked call site: `@(initial_step)`, a statement the kernel runs on the first analysis point (§5.10.2) rather than in program order, with `seq` pinning that §5.3.1 order still holds around it. `10_c_vpi_register_cb_not_va.va` covers the C-name rejection. The `time queue` object has no source-observable counterpart. |

## The xfail ledger is empty

No fixture in this folder carries `//! xfail`. All 25 positive fixtures are
expected to pass today, and the two negative ones —
`09_c_vpi_get_not_va.va` and `10_c_vpi_register_cb_not_va.va`, both
`//! reject E0512` plus a `//! reject` on the routine name — are expected to be
diagnosed. These results do not assess conformity of the standard C API,
its object model or callbacks.

That is not the same as the chapter being clean. The debt here is
*uncovered*, not *failing*: eight object-model sections have no fixture at all
(below), and every section that does have one covers the language fact behind
the diagram, never the diagram's VPI properties or traversals, which no
Verilog-A source can reach.

## What is not covered

Eight object-model sections are empty above, and all eight are empty for the
same reason. It is not this folder's omission: the declarations a diagram
names are ordinary Verilog-AMS (`wire w;` and `reg r;` both parse), but the
statements that give the section its content are outside the module items
annex A.1.4 admits, so the compiler refuses the construct before any
object-model question can be asked of it. This is a full-AMS coverage gap,
not a target exclusion:

- `s11-6-8` **Nets** — no fixture declares a `wire`. The old file credited
  `01_module_port_node.va` here; `01` declares `electrical p, n`, which are
  disciplined nodes (`s11-6-5`), not net objects. Grep it: the only `wire` in
  this folder is inside the word "hard-wired", in a comment in `20`.
- `s11-6-9` **Regs** — no `reg` declaration anywhere.
- `s11-6-11` **Memory** — no array declaration, no memory word select.
- `s11-6-13` **Primitive, prim term** — gate primitives; nothing instantiates
  anything in this folder.
- `s11-6-14` **UDP** — no `primitive` definition or table.
- `s11-6-15` **Module path, timing check, intermodule path** — no `specify`
  block.
- `s11-6-17` **Continuous assignment** — no `assign` statement. The old file
  credited `02_branch_quantity.va`; `02` contains a branch contribution
  (`<+`), which is `s11-6-20`'s `contribs`, a different class in a different
  diagram.
- `s11-6-24` **Assign statement, deassign, force, release, disable** — no
  fixture here, and the earlier form of this bullet ("none of the five
  keywords occurs in any fixture") was false: `disable` is implemented and
  asserted in `ch05_analog_behavior/a03_01…a03_03` under
  `//! lrm 5.3`/`5.9.3`/`5.10.2` (and §6.7 in `a03_03`), `force` inside an
  `analog` block is rejected in
  `annex_a_syntax/30_force_in_analog_rejected.va` under A.6.2/A.6.4, and
  `assign` under C.7 in `annex_c_analog_subset/23_continuous_assign_rejected.va`.
  What is absent is a citation of *this object*: none of those fixtures can
  reach `vpiLhs`/`vpiRhs`/`vpiScope`, so none is evidence for §11.6.24.

Twelve further sections carry no Verilog-A-observable rule at all and are
marked as such rather than left blank: `s11-1`, `s11-2`, `s11-2-2`, `s11-2-3`,
`s11-3`, `s11-3-1`, `s11-3-2`, `s11-5`, `s11-5-1`, `s11-5-2`, `s11-5-3`,
`s11-6`. They are overview prose, C-API mechanics, or diagram legend.

For three of those twelve the absence is a *deferral* and not a hole, and the
distinction is worth keeping: every routine `s11-2-3`, `s11-3-1` and `s11-3-2`
name — `vpi_chk_error`, `vpi_handle`, `vpi_handle_by_name`, `vpi_get`,
`vpi_get_str`, `vpi_iterate`, `vpi_scan`, `vpi_get_delays`, `vpi_put_delays`,
`vpi_get_value`, `vpi_put_value`, `vpi_handle_multi` — has a one-routine
`//! reject` fixture in `ch12_vpi_routines` under the §12 clause that defines
it. The routines are covered there; the chapter's own sections add no rule on
top, which is why a §11.3.1 citation would be padding.

The eight diagram sections are a different kind of gap and no `.va` can ever
close them. `tests/harness.zig` collects
`*.va` only, so a `.c` fixture is invisible to `zig build benchmark`; the VPI
host application the object model would be asserted against —
`tests/vpi_app.c`, `tests/vpi_host.zig`, `tests/vpi_design.va` — is not in the
tree at `0984a12`; and no build step compiles the 26 `.c` rows filed under
this folder and `ch12_vpi_routines` (`grep -c vpi build.zig` finds the
compiler module and nothing else). Closing them needs a running VPI host plus
one `vpi_iterate`/`vpi_get` assertion per property — `vpiStrength0` on a net,
`vpiSize` on a memory, `vpiPrimType` on a primitive, `vpiTchkType` on a timing
check, `vpiLineNo` on a cont assign — and not another `.va` file.

Within the 19 covered sections, the same limit recurs and is worth stating
once: a fixture reaches the *language* fact a diagram is drawn over, never the
diagram itself. No `vpiName` is read, no relationship is traversed, no
property is fetched. Bit-level objects (`vpiBit`/`vpiParent`), range relations
(`vpiLeftRange`/`vpiRightRange`), and `vpiHighConn`/`vpiLowConn` are absent
throughout, since every net here is scalar and nothing is instantiated.
Indirect contribution (`s11-6-20`'s `ind flow`/`ind potential`) and delay and
repeat control (`s11-6-22`) are named by covered sections but exercised by no
fixture in this folder.

## Fixture inventory

25 positive, 2 negative, 0 xfail.

- `01_module_port_node.va` — `s11-6-1`, `s11-6-4`, `s11-6-5`
- `02_branch_quantity.va` — `s11-6-7`
- `03_parameters_variables.va` — `s11-6-10`, `s11-6-12`
- `04_function_call_object.va` — `s11-6-16`
- `05_system_task_call_object.va` — `s11-6-16`
- `06_system_function_call_object.va` — `s11-6-16`
- `07_process_statement_objects.va` — `s11-6-21`, `s11-6-23`
- `08_callback_call_site.va` — `s11-6-25`
- `09_c_vpi_get_not_va.va` — `s11-4` (reject)
- `10_c_vpi_register_cb_not_va.va` — `s11-2-1` (reject)
- `11_nature_discipline_objects.va` — `s11-6-2`
- `12_function_io_objects.va` — `s11-6-3`
- `13_port_node_objects.va` — `s11-6-4`, `s11-6-5`
- `14_branch_object.va` — `s11-6-6`
- `15_quantity_objects.va` — `s11-6-7`
- `16_variable_objects.va` — `s11-6-10`
- `17_parameter_object.va` — `s11-6-12`
- `18_function_call_object_atomic.va` — `s11-6-16`
- `19_system_task_call_object_atomic.va` — `s11-6-16`
- `20_system_function_call_object_atomic.va` — `s11-6-16`
- `21_simple_expression_object.va` — `s11-6-18`, `s11-6-19`
- `22_operation_access_objects.va` — `s11-6-19`
- `23_contribution_object.va` — `s11-6-20`
- `24_named_process_object.va` — `s11-6-21`
- `25_assignment_loop_objects.va` — `s11-6-22`
- `26_conditional_case_objects.va` — `s11-6-23`
- `27_potential_contribution_object.va` — `s11-6-20`
