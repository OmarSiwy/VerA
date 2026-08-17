# Chapter 3 coverage

Source: `docs/VAMS-LRM/ch3-datatypes.html`, read in full through Section 3.13.4.

HTML section-ID audit: `s3-1` `s3-2` `s3-2-1` `s3-3` `s3-4` `s3-4-1` `s3-4-2` `s3-4-3` `s3-4-4` `s3-4-5` `s3-4-6` `s3-4-7` `s3-4-8` `s3-5` `s3-6` `s3-6-1` `s3-6-1-1` `s3-6-1-2` `s3-6-1-3` `s3-6-2` `s3-6-2-1` `s3-6-2-2` `s3-6-2-3` `s3-6-2-4` `s3-6-2-5` `s3-6-2-6` `s3-6-2-7` `s3-6-3` `s3-6-3-1` `s3-6-3-2` `s3-6-4` `s3-6-5` `s3-7` `s3-8` `s3-9` `s3-10` `s3-11` `s3-11-1` `s3-12` `s3-12-1` `s3-13` `s3-13-1` `s3-13-2` `s3-13-3` `s3-13-4` — 45 IDs, of which 3 (`s3-1`, `s3-6`, `s3-13`) are bare parent headings with no rule of their own.

95 `.va` files: 31 run and assert, 23 are green rejections, 41 are `//! xfail`.
`xf:` in the table is an `//! xfail` and names the gap; the full ledger is below.

| LRM section | Fixtures |
|---|---|
| 3.1 Overview | parent heading; the type inventory it lists is exercised by the sections below |
| 3.2 Integer and real data types | `01_integer_real_variables.va`, `02_variable_arrays.va` (negative lower bound, `[4:4]`), `15_dynamic_array_index.va`, `55_integer_real_default_init.va`, `61_nonconstant_array_dimension.va`; `18_multidimensional_array.va` (xf: parser takes one array dimension, second `[` is E0207), `72_integer_overflow_wrap.va` (xf: `integer` lowers to i64, so neither 32-bit endpoint wraps) |
| 3.2.1 Output variables | — no fixture. The rule is an attribute instance (`(* desc=…, units=… *) real cgs;`) and no `.va` in this directory contains a single `(*`. Chapter 2's `11_attributes.va` parses attribute syntax but says nothing about module-scope variables becoming output variables. |
| 3.3 String data type | `03_string_variables.va`, `23_string_arrays.va`, `25_string_nul_removal.va`, `26_string_comparisons.va`, `27_string_concatenation.va`, `28_string_replication.va` (§3.3's own `{5{"Hi"}}` and `{i{"Hi"}}`), `52_nonconstant_replication_to_integral.va` and `52_string_to_integral_rejected.va` (both E0354); `73_string_literal_to_integral.va` (the literal→integral conversion: truncated on the left, zero filled on the left, and Table 3-3's `""` == 8'b0); `24_multidimensional_strings.va` (xf: second `[` is E0207) |
| 3.4 Parameters | `29_time_realtime_parameters.va`, `51_parameter_assigned_at_runtime.va`, `58_forward_parameter_reference.va`, `58_variable_in_parameter_initializer.va` |
| 3.4.1 Type specification | `04_parameter_types.va`, `59_parameter_without_default.va`, `74_untyped_parameter_type_derivation.va`; `53_real_parameter_from_string.va` and `53_string_parameter_from_numeric.va` (xf: no string/numeric parameter type check), `60_parameter_array_untyped.va` and `60_string_parameter_untyped.va` (xf: no mandatory-type check). The derived-type half of the string sentence needs a string override; `//! param` carries only numbers, so it has no fixture. |
| 3.4.2 Value range specification | `05_parameter_ranges.va` (inclusive/exclusive, `inf`, `-inf`, multiple `exclude`), `17_string_parameter_range.va` (both LRM string-set examples), `45_parameter_range_legal_endpoints.va`; `45_parameter_range_below_lower_bound.va`, `45_parameter_range_excluded_interior.va`, `45_parameter_range_excluded_closed_endpoint.va`, `45_parameter_range_above_inclusive_upper.va` (all xf: no module instantiation, so no override is ever range-checked), `71_range_first_expression_larger.va` (xf: no bound-ordering check) |
| 3.4.3 Parameter units and descriptions | — no fixture. Same reason as 3.2.1: the construct is an attribute instance and none exists here. The clause itself disclaims dimensional analysis. |
| 3.4.4 Parameter arrays | `08_parameter_array.va` (fill order, bound from a previously-declared parameter); `60_parameter_array_untyped.va` (xf) |
| 3.4.5 Local parameters | `06_local_parameter.va` — derivation after override, and an override aimed at the localparam that must not stick |
| 3.4.6 String parameters | `03_string_variables.va` and `04_parameter_types.va` declare and read a `parameter string`; `17_string_parameter_range.va` adds the value-set forms; `53_string_parameter_from_numeric.va` (xf) and `60_string_parameter_untyped.va` (xf) are the negatives. Only the last cites §3.4.6 in its `//! lrm`; the rest cite §3.3/§3.4.1/§3.4.2 and are credited here on what they contain. |
| 3.4.7 Parameter aliases | `56_alias_identifier_collision.va`; `07_parameter_alias.va` (the LRM's own `nmos2` arrangement: the override names the alias, the equations read the original — codegen now gives the alias its own `Model` field plus a `__given` flag, and `derive` folds it onto the original before any §6.3.4 dependent reads it), `75_aliasparam_mfactor.va` (xf: `aliasparam m = $mfactor` — parser takes only an identifier after `=`, E0208), `78_alias_double_override.va` (xf: no module instantiation) |
| 3.4.8 Multidimensional parameter array examples | `77_assignment_pattern_variable.va` (whole-array pattern of non-constant probes); `77_assignment_pattern_replication.va` (xf: no two-dimensional arrays; the replication itself unrolls) |
| 3.5 Genvars | `09_genvar.va`, `50_genvar_assigned_outside_loop.va`, `50_genvar_nonstatic_loop_control.va` |
| 3.6 Net_discipline | parent heading |
| 3.6.1 Natures | `10_nature_declarations.va`, `39_nature_discipline_namespace_collision.va`, `57_base_nature_missing_access.va`, `57_base_nature_missing_units.va`, `69_nature_inside_module.va`; `67_duplicate_nature_name.va` (xf: same-kind duplicate silently keeps the last) |
| 3.6.1.1 Derived natures | `10_nature_declarations.va`, `36_derived_nature_inheritance.va` |
| 3.6.1.2 Attributes | `10_nature_declarations.va`, `11_discipline_declarations.va`, `20_derived_nature_from_discipline.va`, `35_base_nature_required_attributes.va` (abstol), `36_derived_nature_inheritance.va`, `37_derived_units_immutable.va`, `38_derived_access_immutable.va`, `57_base_nature_missing_access.va`, `57_base_nature_missing_units.va`, `66_idt_nature_self_reference.va` (the permitted self-reference, valued through §4.5.4's DC rule); `65_nature_access_as_string.va` and `65_nature_units_as_identifier.va` (xf: attribute values not type-checked), `66_idt_nature_not_a_nature.va` (xf: attribute references not resolved), `66_idt_nature_unrelated_override.va` (xf: overrides not related to the parent's) |
| 3.6.1.3 User-defined attributes | `68_duplicate_user_attribute.va` (xf: no uniqueness check within a nature), `68_nonconstant_user_attribute.va` (xf: values not required constant). Both halves of the clause are xfail; nothing green states it. |
| 3.6.2 Disciplines | `11_discipline_declarations.va`; `67_duplicate_discipline_name.va` (xf: same-kind duplicate silently keeps the last) |
| 3.6.2.1 Nature binding | `11_discipline_declarations.va` (conservative, potential-only, flow-only), `64_flow_on_potential_only_net.va`; `46_same_nature_both_bindings.va` (xf: no same-nature check on a conservative discipline) |
| 3.6.2.2 Domain binding | `47_discrete_domain_with_natures.va` (xf: no domain-versus-nature-binding check). The legal `domain continuous` form appears in `11_discipline_declarations.va`; a bare `domain discrete` with no natures lives in `annex_c_analog_subset`. |
| 3.6.2.3 Natureless and domainless disciplines | `30_natureless_discipline.va`, `31_domainless_discipline.va`; `79_natureless_net_behavioral.va` and `80_domainless_net_behavioral.va` (xf: no access-function-not-found check) |
| 3.6.2.4 Discipline of nets and undeclared nets | `34_implicit_nets.va` (xf: no module instantiation, the instance is E0204, so the undeclared net is never reached) |
| 3.6.2.5 Overriding nature attributes from discipline | `19_discipline_override.va` — the LRM's `flow.abstol` form; the assertion is that the binding survives, not the tolerance value |
| 3.6.2.6 Deriving natures from disciplines | `20_derived_nature_from_discipline.va` — `nature x : disc.potential`, observable through inherited `access` |
| 3.6.2.7 User-defined attributes (discipline) | — no fixture. No `.va` here declares a user attribute inside a `discipline`; `11_discipline_declarations.va` declares three disciplines and none carries one. |
| 3.6.3 Net_discipline declaration | `12_scalar_nets.va` (undeclared-as-port internal nets), `64_flow_on_potential_only_net.va`; `32_vector_nets.va` (§3.6.3 vector nets, scalarised: `V(p[0])`…`V(p[3])` on one four-bit bus), `79_natureless_net_behavioral.va` and `80_domainless_net_behavioral.va` (xf) |
| 3.6.3.1 Net descriptions | — no fixture. `(* desc="drain terminal" *) electrical d;` is an attribute instance; none exists here, and the duplicate-on-port-and-declaration rule has no fixture either. |
| 3.6.3.2 Net Discipline Initial (Nodeset) Values | `21_net_nodeset.va` (xf: no `net_decl_assignment`, the `=` is E0207). The non-continuous half of the sentence has no fixture. |
| 3.6.4 Ground declaration | `13_ground_declaration.va`; `62_ground_non_continuous.va` (xf: `ground` does not check the discipline's domain) |
| 3.6.5 Implicit nets | `34_implicit_nets.va` (xf, as above). It cites §3.6.2.4; §3.6.5 restates the same rule for the structural case, which is exactly the shape the file writes — an undeclared net appearing only as an instance actual. |
| 3.7 Real net declarations (`wreal`) | — no fixture. No `.va` here contains `wreal`. Annex C puts it outside the Verilog-A subset, and the exclusion is stated in `annex_c_analog_subset`, not here. |
| 3.8 Default discipline | — no fixture. No `.va` here contains `` `default_discipline ``. Directive handling belongs to Chapter 10 and discipline resolution to Annex F. |
| 3.9 Disciplines of primitives | — no fixture. Needs `vpiLoConn`, simulator primitives and a mixed-signal resolution pass; nothing a single generated device can state. |
| 3.10 Discipline precedence | — no fixture. Needs an out-of-module reference declaring another module's net, which requires hierarchy. |
| 3.11 Net compatibility | `76_nature_compatibility_rules.va` is the positive side; `54_incompatible_nets_access.va` (E0355 on `I(elec, shaft)`) and `63_branch_incompatible_terminals.va` (E0355 on the branch declaration) are the two shapes 3.11 and 3.12 state the requirement in, and both diagnose at the rule |
| 3.11.1 Discipline and Nature Compatibility | `76_nature_compatibility_rules.va` states all three nature rules — Base Nature, Derived Nature, and the surprising Units Value Rule — one net pair each; `54_incompatible_nets_access.va` and `65_nature_units_as_identifier.va` (xf) are the negatives. All six discipline-level rules are implemented (`Lower.disciplineConflict`), but only the Potential Incompatibility Rule has a fixture: the Domain Incompatibility Rule, the Domainless Rule and the Natureless Rule have none here, and the Flow Incompatibility Rule needs a pair that agrees on potential and differs on flow, which no fixture writes. |
| 3.12 Branches | `14_named_branches.va` (two-terminal, one-terminal-defaults-to-ground, two named branches plus the unnamed one over the same pair), `44_vector_branch_size_mismatch.va` (E0353), `33_vector_branches.va` (the LRM's own `[3:5]`/`[1:3]` pair, indexed from 0); `63_branch_incompatible_terminals.va` (E0355 — “the disciplines for the specified nets shall be compatible”) |
| 3.12.1 Port Branches | `22_port_branch.va` — the declaration parses and `I(probe_p)` resolves to the same §5.4.3 port-flow unknown `I(<p>)` reads; still **xfail**, because the harness forces every unknown to its operating point instead of solving, so the KCL value the file asserts never appears |
| 3.13 Namespace | parent heading |
| 3.13.1 Nature and discipline | `39_nature_discipline_namespace_collision.va` (E0336), `69_nature_inside_module.va` (E0205); `67_duplicate_nature_name.va` and `67_duplicate_discipline_name.va` (xf) |
| 3.13.2 Access functions | `41_duplicate_access_name.va` (E0335); `40_access_name_shadow.va` — green: the shadowing declaration takes the name and §4.4's generic `potential()` still reaches the net |
| 3.13.3 Net | `42_wrong_access_function.va` (E0501), `48_net_local_to_block.va`, `64_flow_on_potential_only_net.va`, `70_bare_net_name_not_a_value.va` (E0315) |
| 3.13.4 Branch | `49_branch_local_to_block.va` |

## What is not covered

Eight normative sections have no fixture, and the reasons split three ways.

- **Attribute-instance clauses — 3.2.1, 3.4.3, 3.6.3.1.** All three hang on `(* desc=…, units=… *)`, and grep finds no `(*` anywhere in this directory. Nothing structural blocks them: Chapter 2's `11_attributes.va` already parses attribute syntax. What is missing is any fixture that attaches one to a module-scope variable, a parameter, or a net and then observes it. The observable side is operating-point reporting, which a static Zig dump does not have — but the *acceptance* of the attribute in those three positions is testable and is not tested.
- **Hierarchy and resolution clauses — 3.8, 3.9, 3.10.** Default discipline, primitive disciplines, and discipline precedence all decide the discipline of a net from outside the module that declares it. They need an instance tree and a resolution pass; `ch06_hierarchy` and `annex_f_resolution` are where they can live.
- **Out of subset — 3.7.** `wreal` is a digital net type Annex C excludes from Verilog-A. The exclusion belongs in `annex_c_analog_subset`, and stating it here would duplicate it.

Two smaller holes inside covered sections, recorded so they are not read as covered: §3.4.1's derived-type-then-string-override case needs a string `//! param`, which `src/backend/tb.zig` does not support; §3.6.3.2's "nets of non-continuous disciplines are not [allowed initializers]" has no fixture, only the positive half.

## The xfail ledger

36 of 95 fixtures state a rule the compiler does not yet meet. They are the honest debt, and they cluster:

**No module instantiation (6).** The instance is rejected at E0204, so nothing downstream of an override is ever reached. `34_implicit_nets.va`, `45_parameter_range_below_lower_bound.va`, `45_parameter_range_excluded_interior.va`, `45_parameter_range_excluded_closed_endpoint.va`, `45_parameter_range_above_inclusive_upper.va`, `78_alias_double_override.va`. Every one of these is written as an instantiation deliberately: §3.4.2 says "range checking applies to the value of the parameter for the instance and not against the default values", and §3.4.7 rule 4 is about how many names one storage location was written through. Neither rule can be stated without an override, and `//! param` is consumed by the testbench generator, which never runs on a reject fixture. This single gap is the largest block of Chapter 3 debt.

**Grammar not implemented (7).** Each names the token that fails.

| Fixture | Gap |
|---|---|
| `16_paramset.va` | E0201 refuses the whole compilation unit for containing a `paramset`. Annex C.8 keeps Clause 6 in Verilog-A, so this is a subset decision, not a conformance rule. |
| `18_multidimensional_array.va` | Parser takes one dimension; the second `[` is E0207 |
| `21_net_nodeset.va` | No `net_decl_assignment`; the `=` of `electrical node = 5.0;` is E0207 |
| `24_multidimensional_strings.va` | Second `[` of a string array declaration is E0207 |
| `75_aliasparam_mfactor.va` | Only a `parameter_identifier` after `aliasparam … =`; `$mfactor` is E0208 |
| `77_assignment_pattern_replication.va` | No two-dimensional arrays; the second `[` of `real fill[0:1][0:2]` is E0207, and `dimBounds` refuses a second dimension anyway (E0307). Its replication half works |

**Missing semantic check in `lower.zig` (19).** These parse, lower and run; the compiler simply never objects.

| Fixture | Rule stated, check absent |
|---|---|
| `46_same_nature_both_bindings.va` | One nature bound to both halves of a conservative discipline |
| `47_discrete_domain_with_natures.va` | `domain discrete` alongside a nature binding |
| `53_real_parameter_from_string.va` | String literal initializing a `parameter real` |
| `53_string_parameter_from_numeric.va` | Numeric initializer on a `parameter string` |
| `60_parameter_array_untyped.va` | Untyped parameter array gets a real type by inference |
| `60_string_parameter_untyped.va` | Untyped parameter derives `string` from its initializer |
| `62_ground_non_continuous.va` | `ground` on a net of a discrete-domain discipline |
| `65_nature_access_as_string.va` | `access = "AccessStr"` — attribute values are not type-checked |
| `65_nature_units_as_identifier.va` | `units = Volt` — the mirror, and it undermines §3.11.1's Units Value Rule |
| `66_idt_nature_not_a_nature.va` | `idt_nature` naming an undefined identifier; references are not resolved |
| `66_idt_nature_unrelated_override.va` | Derived nature overriding `idt_nature` with an unrelated base nature |
| `67_duplicate_nature_name.va` | Two natures of one name: the last wins, silently. E0336 only fires across kinds. |
| `67_duplicate_discipline_name.va` | Same, for disciplines |
| `68_duplicate_user_attribute.va` | Two user attributes of one name in one nature |
| `68_nonconstant_user_attribute.va` | A bare identifier stored as a user attribute value |
| `71_range_first_expression_larger.va` | `from [10:1]` — bounds stored unordered |
| `79_natureless_net_behavioral.va` | `V(link)` resolved on a net whose discipline binds no potential nature |
| `80_domainless_net_behavioral.va` | `V(link)` resolved on a net of a domainless discipline |

**The harness does not solve (1).** `22_port_branch.va`: the §3.12.1 declaration parses and `I(probe_p)` resolves to exactly the port-flow unknown `I(<p>)` reads — forcing that unknown from the operating point makes the file green — but `src/backend/tb.zig` writes `//! bias` values straight into `x[]` and never solves, so the 0.002 KCL puts on the port never appears and the read returns 0. Same wall as `ch05_analog_behavior/indirect_contribution.va` and `annex_a_syntax/21`.

**Backend width (1).** `72_integer_overflow_wrap.va`: §3.2 fixes `integer` at -2^31…2^31-1 with 2's complement wrap, and `src/backend/codegen.zig` lowers it to "plain i64", so `2147483647 + 1` evaluates to 2147483648. Both directions are asserted, so a 64-bit type is wrong at both ends. `73_string_literal_to_integral.va` does NOT depend on VerA's storage width and is green: §3.3 justifies the literal against the DECLARED type, so `Lower.coerceTo` passes §3.2's 32 to `strToInt` and "hello" loses its leading 'h' whatever the i64 underneath does. The two meet only at a literal with the top bit of its last 32 set, which no fixture writes: `strToInt` answers the unsigned value there, where a real 32-bit `integer` would be negative.

## Notes on structure

- **Same sentence, separate files.** §3.13.3 and §3.13.4 word the block-scope ban identically, but a net declaration and a branch declaration are different A.2.1.3 productions, so `48_net_local_to_block.va` and `49_branch_local_to_block.va` are separate. Same reasoning splits `67_duplicate_nature_name.va` from `67_duplicate_discipline_name.va`, `65_nature_access_as_string.va` from `65_nature_units_as_identifier.va`, `57_base_nature_missing_access.va` from `57_base_nature_missing_units.va` and from `35_base_nature_required_attributes.va` (three required attributes, three files), and `53_real_parameter_from_string.va` from `53_string_parameter_from_numeric.va`.
- **Phase-label pins.** Many rejections pin `DiagnosticsReported` rather than a code. That is deliberate where VerA has no diagnostic for the rule: pinning today's incidental code would pin the parser's recovery path, and would stop matching on the day the right check lands — which is exactly when the fixture starts being worth something. The `45_parameter_range_*` family pins the substring `range` and `78_alias_double_override.va` pins `alias` for the same reason, one notch stronger than a bare phase label.
- **Legal side, error side.** Most negatives name their positive twin in the header: `09_genvar` against the two `50_genvar_*`, `13_ground_declaration` against `62_ground_non_continuous`, `33_vector_branches` against `44_vector_branch_size_mismatch`, `11_discipline_declarations` against `46_same_nature_both_bindings` and `64_flow_on_potential_only_net`, `30_natureless_discipline`/`31_domainless_discipline` against `79`/`80`, `08_parameter_array` against `60_parameter_array_untyped` and `61_nonconstant_array_dimension`, `28_string_replication` against `52_nonconstant_replication_to_integral`, `66_idt_nature_self_reference` against `66_idt_nature_not_a_nature`.
- **Files that belong to another clause.** `16_paramset.va` cites §6.4 and C.8, not Chapter 3; it sits here only because the paramset rejection was found while reading this chapter. Its override behaviour is observable only through an instance and belongs with the Clause 6 fixtures.
