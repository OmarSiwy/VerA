# Chapter 3 coverage

Branch/scope rejection follow-up, 2026-09-23: `44_vector_branch_size_mismatch.va`
now pins E0353 with cascading invalid-branch reads removed. The block-local
net/branch fixtures `48` and `49` pin their actual parser diagnostics E0214 and
E0209, not generic failed phases. Temporary controls with matching sizes or
module-scope declarations compile. The branch ledger retains the distinction
between parser rejection and dedicated semantic scope diagnostics.

Compatibility audit, 2026-09-23: the potential-incompatibility rejection `54`
now pins E0355. `audit_incompatible_flow_natures_rejected.va` independently
tests incompatible flows while both potentials permit V access; the legal
`audit_compatible_flow_units.va` uses unrelated flow bases with equal units.
The nature ledger keeps these access cases separate from full connection and
discipline-resolution coverage.

Ground/implicit-net audit, 2026-09-23: `62_ground_non_continuous.va` now pins
E0344 rather than a generic failed phase. New solved-node cases observe ground
identity and the implicit structural net through a declared child port. Removing
the ground declaration in a temporary control makes both ground assertions
fail with the independently derived floating-reference solution. See the
[net ledger](../../../docs/conformance-nodesets.md) for remaining resolution gaps.

Nodeset audit, 2026-09-23: `audit_nodeset_unclamped_solution.va` passes a
free-node KCL solution distinct from the declared nodeset. The older `21` case
prescribes that node and is not solver evidence. Both a08 cubic regressions
currently pass, but their final roots depend on harness policy; their null-bus
case cannot distinguish an explicit zero from a zero cold start. See the
[nodeset ledger](../../../docs/conformance-nodesets.md) for independent
consumption, null-preservation and hierarchy-precedence obligations still open.

Missing-attribute isolation follow-up, 2026-09-23: fixtures `35` and the two
`57_base_nature_missing_*` now use legal output signal-flow ports, removing
incidental inout errors. Each still reports its intended E0332. Temporary
controls adding only the omitted attribute all compile; this validates the
rejection setup, not behavioral coverage of the attributes.

Nature audit, 2026-09-23: `65_nature_access_as_string.va`,
`65_nature_units_as_identifier.va` and `68_nonconstant_user_attribute.va` now
pin E0340; `68_duplicate_user_attribute.va` pins E0343. Direct diagnostics
supersede the historical generic-phase rationale below. The
[nature ledger](../../../docs/conformance-natures.md) separates inherited access
probes from unobserved metadata, compatibility and tolerance requirements.

Genvar audit, 2026-09-23: `50_genvar_assigned_outside_loop.va` now isolates
the illegal assignment and pins E0313 rather than accepting any failed phase.
The positive nested-static-dependency case independently observes values and
trip counts, including zero iterations. See
[the genvar ledger](../../../docs/conformance-genvars.md) for the scope and
analog-operator-state limitations of these tests.

Array-size audit, 2026-09-23: the exact-size override case independently observes
each replacement element. Three isolated rejection fixtures expose accepted
short/long overrides and resizing without a replacement as
PARAM-ARRAY-SIZE-001/002/003; elaboration now refuses all three with E0921. The existing Chapter 6
`h01_11_dependent_range_and_array_override.va` is the legal resize counterpart.
These failures must not be hidden by the existing declaration/pattern tests;
see the parameter ledger for shape and override-path gaps.

Local-parameter audit, 2026-09-23: `06_local_parameter.va` now claims only
host-bound dependency evaluation. Its former ignored localparam host binding
did not establish illegal HDL override rejection; that claim moves to
`audit_localparam_override_rejected.va` (E0907). The duplicate original/alias
HDL override fixture `78_alias_double_override.va` now pins E0908, superseding
the historical broad-substring rationale below. See the parameter worklist
for separate array, alias and simulator-output obligations still open.

Parameter-inference audit, 2026-09-23: `74_untyped_parameter_type_derivation.va`
now uses an integer denominator, removing a promotion that could hide the wrong
inferred type. `audit_parameter_override_type.va` passes both override-direction
and dependent-type observations. Removing its HDL overrides in a temporary
source copy makes every assertion fail. See
[the parameter worklist](../../../docs/conformance-parameters.md) for limits.

Source-audit follow-up, 2026-09-23: see
[the type ledger](../../../docs/conformance-types.md) for §§3.1–3.3 rule and
evidence boundaries. `audit_string_comparison_context.va` passes independent
typed-string/NUL and lexicographical boundary observations.
`audit_string_literal_equality.va` (STR-LITERAL-001, closed) passes the
literal-only context: two literals compare as zero-extended integers, NULs
included, so `"A\0" == "A"` is 0.

Runtime multidimensional element reads and writes are covered by
`89_dynamic_multidim_numeric.va`, `89_dynamic_multidim_scope.va`,
`89_dynamic_multidim_parameter_index.va`, `89_dynamic_multidim_order.va`, and
`89_dynamic_multidim_guards.va`. They exercise independent 2D/3D
indices, mixed literal/parameter/runtime subscripts, signed descending ranges,
initialization order, real-cell derivatives, string elements, scope restoration,
parameter-index overrides, a nine-dimensional array, whole-array assignment,
opposite-direction `$table_model` columns, and guarded invalid indices in
conditionals and loops. Invalid writes do not alias neighboring cells. Constant invalid reads still reject with E0310; runtime invalid
reads terminate with `VerA: out-of-range array read is not implemented`. Their
complete inherited Verilog value semantics remain unimplemented, including
four-state integer results; no real-array zero/NaN fallback is claimed. These
tests cover scalar elements, not partial-array slices or dynamic scalar
output/inout arguments.

String value-set validation for constant instance overrides is covered by
`84_string_range_overrides.va`, `85_string_range_outside_rejected.va`,
`86_string_range_excluded_rejected.va` and `87_string_range_empty_excluded.va`.
These test unions, case-sensitive membership, exclusion precedence and the empty
string. Host-written values and string-aware paramset selection remain open.

Exact integral parameter initialization and derivation are exercised by
`88_integer_parameter_precision.va`, `88_integer_parameter_precision_override.va`
`88_integer_parameter_precision_host.va` and `88_integer_parameter_precision_derive.va`.
They cover bits beyond f64's exact
range, high-bit patterns, dependent copies and masks, HDL instance overrides,
host model-card writes, and declared `integer` wrapping before division.
`88_integer_parameter_precision_real_dependents.va` and
`88_integer_parameter_precision_real_dependents_host.va` also cover real
parameters derived from converted integer scalars and descending array elements.
Declared-type conversions are retained in MIR as well as folded metadata;
integer arithmetic completes before a dependent value converts to real. A
codegen unit test checks the Model field initializers before `derive()` runs.
`88_integer_parameter_precision_control.va` also covers integer Model references
in host-rendered delay controls and alternating real/integer conversions.
The existing i64 carrier preserves up to 64 bits; complete expression width and
signedness propagation, wider integral values, and changing an untyped
parameter's width through the host card ABI remain open. Parameter derivation
supports dynamic nonzero integer divisors. A selected zero divisor terminates
with an explicit unsupported-value diagnostic; a guarded untaken division or
remainder is never evaluated. Their i65 intermediate
prevents host integer-division overflow before applying the MIR result width.
The AST and MIR constant folds use the same widened division/remainder
intermediate; typed 32-bit assignments from the minimum i64 literal are tested.
`88_integer_parameter_precision_conditional.va` checks all eight bytes of an
equal-width conditional localparam after a host override, including numeric `%s`.
Nonfinite/out-of-i64-range real-to-integer conversion retains
the existing saturation policy and still needs a separate consistency audit.

`90_dependent_control_host.va`, `90_dependent_control_guarded.va`,
`90_dependent_control_divisor.va`, `90_dependent_control_operators.va`, and
`90_dependent_control_rg.va` exercise
host derivation of `?:`, `&&` and `||`: nested branches, real comparisons before
integer conversion, selected-arm integer arithmetic, declared-type rounding,
descending parameter arrays, dependency order, explicit override precedence and
skipped unsafe arms. The RG fixture uses the transmission-line model's actual
`wave` and `ok` expressions. Codegen unit coverage also reconstructs unconverted
pure two-way phi merges, whose branch need not be the last instruction.
The operator fixture covers dependent logical shifts (`<<`, `>>`) with signed operands and negative
or oversized counts, exact real remainder, and HiSIMHV's version-dependent
conditional defaults after an override. Selected zero-divisor real remainders
fail explicitly; guarded untaken remainders are skipped.
`90_dependent_control_mixed_guard.va` checks select-arm proof evidence when a
real comparison widens an integer literal, including untaken remainder by zero.
`90_dependent_control_shift_sign.va` preserves signed and unsigned zero-shift
identity in folded defaults, host derivation and runtime real/comparison uses.
The two `shift_mixed` fixtures diagnose E0364 for known mixed-signedness shift
comparisons, including constant expressions. General expression context typing
is still missing: the analogous direct comparison `a > 32'h1` with signed
integer `a = -1` also needs unsigned conversion, and the narrow diagnostic does
not cover every compound expression. Wider shifts and arithmetic shifts remain
separate gaps.
Unsupported known numeric defaults and unsupported numeric localparams diagnose
E1004; `90_dependent_control_unsupported.va` and
`90_dependent_control_unknown_local.va` pin that limitation. Loop-carried or
multiway constant-function control flow, unhandled system functions such as
host-rendered `$clog2`, string derivation and complete expression sizing remain
open. Non-local defaults with no compile-time value retain W1050's explicit
host-supplied-value contract.

Source: `docs/ch3-datatypes.html`, read in full through Section 3.13.4.

HTML section-ID audit: `s3-1` `s3-2` `s3-2-1` `s3-3` `s3-4` `s3-4-1` `s3-4-2` `s3-4-3` `s3-4-4` `s3-4-5` `s3-4-6` `s3-4-7` `s3-4-8` `s3-5` `s3-6` `s3-6-1` `s3-6-1-1` `s3-6-1-2` `s3-6-1-3` `s3-6-2` `s3-6-2-1` `s3-6-2-2` `s3-6-2-3` `s3-6-2-4` `s3-6-2-5` `s3-6-2-6` `s3-6-2-7` `s3-6-3` `s3-6-3-1` `s3-6-3-2` `s3-6-4` `s3-6-5` `s3-7` `s3-8` `s3-9` `s3-10` `s3-11` `s3-11-1` `s3-12` `s3-12-1` `s3-13` `s3-13-1` `s3-13-2` `s3-13-3` `s3-13-4` — 45 IDs, of which 3 (`s3-1`, `s3-6`, `s3-13`) are bare parent headings with no rule of their own.

139 `.va` files: 78 execution fixtures, 61 rejection fixtures, and no `//! xfail`
(grep-measured over this directory).
Counts were measured after integrating the dependent-parameter fixtures; recount
after adding or removing files. Rejection of a legal unsupported feature is not
positive conformance coverage.
No `xf:` marker is left in the table: every row that carried one is green, and each says
what it pins. The full ledger is below.

| LRM section | Fixtures |
|---|---|
| 3.1 Overview | parent heading; the type inventory it lists is exercised by the sections below |
| 3.2 Integer and real data types | `01_integer_real_variables.va`, `02_variable_arrays.va` (negative lower bound, `[4:4]`), `15_dynamic_array_index.va`, `55_integer_real_default_init.va`, `61_nonconstant_array_dimension.va`, `18_multidimensional_array.va` (green: `{ dimension }` loops, and the array is scalarized row-major over the whole shape); `72_integer_overflow_wrap.va` (green: both endpoints wrap 2's complement, the width imposed on the operation — `Lower.wrap32`) |
| 3.2.1 Output variables | — no fixture. The rule is an attribute instance (`(* desc=…, units=… *) real cgs;`) and no `.va` in this directory contains a single `(*`. Chapter 2's `11_attributes.va` parses attribute syntax but says nothing about module-scope variables becoming output variables. |
| 3.3 String data type | `03_string_variables.va`, `23_string_arrays.va`, `25_string_nul_removal.va`, `26_string_comparisons.va`, `27_string_concatenation.va`, `28_string_replication.va` (§3.3's own `{5{"Hi"}}` and `{i{"Hi"}}`), `52_nonconstant_replication_to_integral.va` and `52_string_to_integral_rejected.va` (both E0354); `73_string_literal_to_integral.va` (the literal→integral conversion: truncated on the left, zero filled on the left, and Table 3-3's `""` == 8'b0), `24_multidimensional_strings.va` (green: §3.3's own three-by-two `paths` declaration, initializer included), `string_comparison_in_a_constant_expression.va` (Table 3-3's equality and lexicographic relational in a CONSTANT expression — a §5.9.3 genvar bound, which is folded at elaboration and never reaches the runtime comparison `26_string_comparisons.va` pins; `Lower.foldBinary` used to reach `Const.asReal`, which is 0 for every string, so `"slow" == "fast"` folded TRUE and the loop unrolled three times) |
| 3.4 Parameters | `29_time_realtime_parameters.va`, `51_parameter_assigned_at_runtime.va`, `58_forward_parameter_reference.va`, `58_variable_in_parameter_initializer.va`, `81_parameter_default_over_parameter.va` (the whole of §4.2 in a default over an earlier parameter — shifts, relationals, remainder, bitwise, `?:`; every one answered 0 before wave 9) |
| 3.4.1 Type specification | `04_parameter_types.va`, `59_parameter_without_default.va`, `74_untyped_parameter_type_derivation.va`; `53_real_parameter_from_string.va` and `53_string_parameter_from_numeric.va` (green, `DiagnosticsReported` — was: no string/numeric parameter type check), `60_parameter_array_untyped.va` and `60_string_parameter_untyped.va` (green, `DiagnosticsReported` — was: no mandatory-type check). The derived-type half of the string sentence needs a string override; `//! param` carries only numbers, so it has no fixture. |
| 3.4.2 Value range specification | `05_parameter_ranges.va` (inclusive/exclusive, `inf`, `-inf`, multiple `exclude`), `17_string_parameter_range.va` (both LRM string-set examples), `45_parameter_range_legal_endpoints.va`; `45_parameter_range_below_lower_bound.va`, `45_parameter_range_excluded_interior.va`, `45_parameter_range_excluded_closed_endpoint.va`, `45_parameter_range_above_inclusive_upper.va` (all green: the instance elaborates, the override becomes the flattened parameter's default, and E0361 judges it against the declared range), `71_range_first_expression_larger.va` (green, `DiagnosticsReported` — was: no bound-ordering check), `81_from_range_without_bracket.va` (green, E0207 — was: `from 5` hit `std.debug.assert(kind == .exclude)` in the parser, i.e. `unreachable` in ReleaseFast) |
| 3.4.3 Parameter units and descriptions | — no fixture. Same reason as 3.2.1: the construct is an attribute instance and none exists here. The clause itself disclaims dimensional analysis. |
| 3.4.4 Parameter arrays | `08_parameter_array.va` (fill order, bound from a previously-declared parameter); `60_parameter_array_untyped.va` (green) |
| 3.4.5 Local parameters | `06_local_parameter.va` — derivation after override, and an override aimed at the localparam that must not stick |
| 3.4.6 String parameters | `03_string_variables.va` and `04_parameter_types.va` declare and read a `parameter string`; `17_string_parameter_range.va` adds the value-set forms; `53_string_parameter_from_numeric.va` (green) and `60_string_parameter_untyped.va` (green) are the negatives. Only the last cites §3.4.6 in its `//! lrm`; the rest cite §3.3/§3.4.1/§3.4.2 and are credited here on what they contain. |
| 3.4.7 Parameter aliases | `56_alias_identifier_collision.va`; `07_parameter_alias.va` (the LRM's own `nmos2` arrangement: the override names the alias, the equations read the original — codegen now gives the alias its own `Model` field plus a `__given` flag, and `derive` folds it onto the original before any §6.3.4 dependent reads it), `75_aliasparam_mfactor.va` (green: a `system_identifier` is a legal `aliasparam` target now, and §3.4.7's form gives the ALIAS the storage), `78_alias_double_override.va` (green: E0908, §3.4.7's "both the original parameter and its alias") |
| 3.4.8 Multidimensional parameter array examples | `77_assignment_pattern_variable.va` (whole-array pattern of non-constant probes), `77_assignment_pattern_replication.va` (green: the nested `'{ 2{ '{3{2.5}}}}` form, flattened row-major over the declared shape) |
| 3.5 Genvars | `09_genvar.va`, `50_genvar_assigned_outside_loop.va`, `50_genvar_nonstatic_loop_control.va` |
| 3.6 Net_discipline | parent heading |
| 3.6.1 Natures | `10_nature_declarations.va`, `39_nature_discipline_namespace_collision.va`, `57_base_nature_missing_access.va`, `57_base_nature_missing_units.va`, `69_nature_inside_module.va`; `67_duplicate_nature_name.va` (green, `DiagnosticsReported` — was: same-kind duplicate silently keeps the last) |
| 3.6.1.1 Derived natures | `10_nature_declarations.va`, `36_derived_nature_inheritance.va` |
| 3.6.1.2 Attributes | `10_nature_declarations.va`, `11_discipline_declarations.va`, `20_derived_nature_from_discipline.va`, `35_base_nature_required_attributes.va` (abstol), `36_derived_nature_inheritance.va`, `37_derived_units_immutable.va`, `38_derived_access_immutable.va`, `57_base_nature_missing_access.va`, `57_base_nature_missing_units.va`, `66_idt_nature_self_reference.va` (the permitted self-reference, valued through §4.5.4's DC rule); `65_nature_access_as_string.va` and `65_nature_units_as_identifier.va` (green, `DiagnosticsReported` — was: attribute values not type-checked), `66_idt_nature_not_a_nature.va` (green, `DiagnosticsReported` — was: attribute references not resolved), `66_idt_nature_unrelated_override.va` (green, `DiagnosticsReported` — was: overrides not related to the parent's) |
| 3.6.1.3 User-defined attributes | `68_duplicate_user_attribute.va` (green, `DiagnosticsReported` — was: no uniqueness check within a nature), `68_nonconstant_user_attribute.va` (green, `DiagnosticsReported` — was: values not required constant). Both halves of the clause are now stated by a green negative; nothing POSITIVE states it — no fixture declares a legal user attribute and reads it back, because no construct reads one back. |
| 3.6.2 Disciplines | `11_discipline_declarations.va`; `67_duplicate_discipline_name.va` (green, `DiagnosticsReported` — was: same-kind duplicate silently keeps the last) |
| 3.6.2.1 Nature binding | `11_discipline_declarations.va` (conservative, potential-only, flow-only), `64_flow_on_potential_only_net.va`; `46_same_nature_both_bindings.va` (green, `DiagnosticsReported` — was: no same-nature check on a conservative discipline) |
| 3.6.2.2 Domain binding | `47_discrete_domain_with_natures.va` (green, `DiagnosticsReported` — was: no domain-versus-nature-binding check). The legal `domain continuous` form appears in `11_discipline_declarations.va`; a bare `domain discrete` with no natures lives in `annex_c_analog_subset`. |
| 3.6.2.3 Natureless and domainless disciplines | `30_natureless_discipline.va`, `31_domainless_discipline.va`; `79_natureless_net_behavioral.va` and `80_domainless_net_behavioral.va` (green, `DiagnosticsReported` — was: no access-function-not-found check) |
| 3.6.2.4 Discipline of nets and undeclared nets | `34_implicit_nets.va` (green: the instance elaborates and the net bound only to a child port needs no declaration) |
| 3.6.2.5 Overriding nature attributes from discipline | `19_discipline_override.va` — the LRM's `flow.abstol` form; the assertion is that the binding survives, not the tolerance value |
| 3.6.2.6 Deriving natures from disciplines | `20_derived_nature_from_discipline.va` — `nature x : disc.potential`, observable through inherited `access` |
| 3.6.2.7 User-defined attributes (discipline) | `lrm_3_6_2_7.va` — `max_voltage = 48.0;` inside a discipline, accepted and retained on the declaration exactly as a nature's user attributes are. The LRM contradicts itself here (A.1.7's discipline_item omits the production the §3.6.2.7 prose grants); the fixture's header records the decision: prose governs, the annex grammar is treated as a non-exhaustive erratum. |
| 3.6.3 Net_discipline declaration | `12_scalar_nets.va` (undeclared-as-port internal nets), `64_flow_on_potential_only_net.va`; `32_vector_nets.va` (§3.6.3 vector nets, scalarised: `V(p[0])`…`V(p[3])` on one four-bit bus), `79_natureless_net_behavioral.va` and `80_domainless_net_behavioral.va` (green) |
| 3.6.3.1 Net descriptions | — no fixture. `(* desc="drain terminal" *) electrical d;` is an attribute instance; none exists here, and the duplicate-on-port-and-declaration rule has no fixture either. |
| 3.6.3.2 Net Discipline Initial (Nodeset) Values | `21_net_nodeset.va` — green: `electrical node = 5.0;` parses (A.2.4 `net_decl_assignment`) and the initializer is a solver HINT, so the fixture asserts the net carries the potential the rest of the circuit gives it and is not clamped to 5.0. `91_nodeset_over_parameter.va` pins the same for the two spellings the clause does not print — the initializer on a net that is also a module port, and one written over a parameter. The value now leaves the compiler: lowering folds it and codegen exports `u_nodeset`, an optional `[|U|]?f64` on the device contract that a host reads as its starting x, which is what gives the clause's other two rules a consumer — "shall be a constant_expression" is `91_nodeset_not_constant.va` (E0365) and the ban on non-continuous disciplines is `91_nodeset_non_continuous.va` (E0366). The bus form (`'{2.3,4.5,,6.0}`) is still uncovered and still dropped; its null element has no A.8.3 operand. |
| 3.6.4 Ground declaration | `13_ground_declaration.va`; `62_ground_non_continuous.va` (green, `DiagnosticsReported` — was: `ground` does not check the discipline's domain) |
| 3.6.5 Implicit nets | `34_implicit_nets.va` (green, as above). It cites §3.6.2.4; §3.6.5 restates the same rule for the structural case, which is exactly the shape the file writes — an undeclared net appearing only as an instance actual. The clause's OFF switch lives with the directive that operates it: `ch10_directives/52` and `53` are this file under `` `default_nettype none `` (E0367), and `55`/`56`/`57` scope the region. |
| 3.7 Real net declarations (`wreal`) | `93_wreal_net_undriven_zero_and_driven.va` — an undriven wreal reads 0.0, a singly driven one reads its driver, both from the analog block. |
| 3.8 Default discipline | — no fixture. No `.va` here contains `` `default_discipline ``. Directive handling belongs to Chapter 10 and discipline resolution to Annex F. |
| 3.9 Disciplines of primitives | — no fixture. Needs `vpiLoConn`, simulator primitives and a mixed-signal resolution pass; nothing a single generated device can state. |
| 3.10 Discipline precedence | — no fixture. Needs an out-of-module reference declaring another module's net, which requires hierarchy. |
| 3.11 Net compatibility | `76_nature_compatibility_rules.va` is the positive side; `54_incompatible_nets_access.va` (E0355 on `I(elec, shaft)`) and `63_branch_incompatible_terminals.va` (E0355 on the branch declaration) are the two shapes 3.11 and 3.12 state the requirement in, and both diagnose at the rule |
| 3.11.1 Discipline and Nature Compatibility | `76_nature_compatibility_rules.va` states all three nature rules — Base Nature, Derived Nature, and the surprising Units Value Rule — one net pair each; `54_incompatible_nets_access.va` and `65_nature_units_as_identifier.va` (green) are the negatives. All six discipline-level rules are implemented (`Lower.disciplineConflict`), but only the Potential Incompatibility Rule has a fixture: the Domain Incompatibility Rule, the Domainless Rule and the Natureless Rule have none here, and the Flow Incompatibility Rule needs a pair that agrees on potential and differs on flow, which no fixture writes. |
| 3.12 Branches | `14_named_branches.va` (two-terminal, one-terminal-defaults-to-ground, two named branches plus the unnamed one over the same pair), `44_vector_branch_size_mismatch.va` (E0353), `33_vector_branches.va` (the LRM's own `[3:5]`/`[1:3]` pair, indexed from 0); `63_branch_incompatible_terminals.va` (E0355 — “the disciplines for the specified nets shall be compatible”) |
| 3.12.1 Port Branches | `22_port_branch.va` — green: the declaration parses, `I(probe_p)` resolves to the same §5.4.3 port-flow unknown `I(<p>)` reads, and `//! solve` leaves that unknown to the testbench's Newton loop, so the 0.002 is the value KCL puts on the port and not one the fixture supplied |
| 3.13 Namespace | parent heading |
| 3.13.1 Nature and discipline | `39_nature_discipline_namespace_collision.va` (E0336), `69_nature_inside_module.va` (E0205); `67_duplicate_nature_name.va` and `67_duplicate_discipline_name.va` (green) |
| 3.13.2 Access functions | `41_duplicate_access_name.va` (E0335); `40_access_name_shadow.va` — green: the shadowing declaration takes the name and §4.4's generic `potential()` still reaches the net |
| 3.13.3 Net | `42_wrong_access_function.va` (E0501), `48_net_local_to_block.va`, `64_flow_on_potential_only_net.va`, `70_bare_net_name_not_a_value.va` (E0315) |
| 3.13.4 Branch | `49_branch_local_to_block.va` |

## What is not covered

Seven normative sections have no fixture, and the reasons split three ways.

- **Attribute-instance clauses — 3.2.1, 3.4.3 and 3.6.3.1.** All three hang on `(* desc=…, units=… *)`, and grep finds no `(*` anywhere in this directory. Nothing structural blocks them: Chapter 2's `11_attributes.va` already parses attribute syntax. What is missing is any fixture that attaches one to a module-scope variable, a parameter, or a net and then observes it. The observable side is operating-point reporting, which a static Zig dump does not have — but the *acceptance* of the attribute in those three positions is testable and is not tested. (3.6.2.7, which used to sit in this bullet, closed: it is not an attribute *instance* but a bare `attr = value;` discipline item, and `lrm_3_6_2_7.va` now pins its acceptance.)
- **Hierarchy and resolution clauses — 3.8, 3.9, 3.10.** Default discipline, primitive disciplines, and discipline precedence all decide the discipline of a net from outside the module that declares it. They need an instance tree and a resolution pass; `ch06_hierarchy` and `annex_f_resolution` are where they can live.

One smaller hole inside a covered section, recorded so it is not read as covered: §3.4.1's derived-type-then-string-override case needs a string `//! param`, which `lib/backend/tb.zig` does not support. (§3.6.3.2's "nets of non-continuous disciplines are not [allowed initializers]" used to sit here; it closed as E0366 — see its row above. What is left of that clause is the BUS initializer, also in that row.)

## The xfail ledger

EMPTY — no fixture in this folder is `//! xfail` any more. The clusters below are
kept as the record of what each group of rows was and how it closed; the counts in
their headings are the counts they HELD, not current ones:

**No module instantiation — CLOSED (was 6).** These six were all blocked at E0204, which is retired: `ir/elaborate.zig` flattens the instance tree, so an override reaches the parameter it names. `34_implicit_nets.va`, `45_parameter_range_below_lower_bound.va`, `45_parameter_range_excluded_interior.va`, `45_parameter_range_excluded_closed_endpoint.va`, `45_parameter_range_above_inclusive_upper.va`, `78_alias_double_override.va` are green. Every one of them is written as an instantiation deliberately: §3.4.2 says "range checking applies to the value of the parameter for the instance and not against the default values" (E0361 is that check), and §3.4.7 rule 4 is about how many names one storage location was written through (E0908). Neither rule can be stated without an override, and `//! param` is consumed by the testbench generator, which never runs on a reject fixture.

**Grammar not implemented — CLOSED (was 7).** The last row was
`21_net_nodeset.va` (A.2.4 `net_decl_assignment`), and `parseNetNames` takes the
`=` now. Five rows had left this table before it: `75_aliasparam_mfactor.va` (a `system_identifier` is now a legal `aliasparam` target, and §3.4.7's form gives the ALIAS the storage — `$mfactor` has none on a model card, being an `Instance` field the host writes, so the alias becomes the parameter and `$mfactor` reads it); `16_paramset.va` (a `paramset` is parsed and instantiated now, so the target module's parameter reads the value the paramset computed); and `18_multidimensional_array.va`, `24_multidimensional_strings.va`, `77_assignment_pattern_replication.va` (A.2.2.1's `{ dimension }` is a loop now, and lowering scalarizes the whole shape).

**Missing semantic check in `lower.zig` — CLOSED (was 19).** Every fixture in the
table below is green: each `//! reject` now fires. The rows are left standing as
the inventory of WHICH rule each file states, not as open debt — re-stating the
diagnostic each one landed on is the per-chapter re-census's job, and none of them
was closed by this batch.

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

**The harness solves (0).** `22_port_branch.va` was the one entry here. `lib/backend/tb.zig` now runs Newton-Raphson on the residual the device stamps, so an unknown the fixture deliberately does NOT declare — the port-flow unknown `I(probe_p)` reads — is determined by the device's own KCL row rather than by the operating point. Forcing it would have made the file green while deleting what it asserts. Same close as `ch05_analog_behavior/indirect_contribution.va` and `annex_a_syntax/21`.

**Backend width (0).** `72_integer_overflow_wrap.va` was the one and is green. §3.2 fixes `integer` at -2^31…2^31-1 with 2's complement wrap; an `integer` still lives in an i64 slot, and the WIDTH is imposed on the operation instead — `Lower.wrap32` is the definition, and the three sites that implement it (the §4.2 constant fold, `analysis.foldConst` for parameter defaults, and `codegen.intBin32` for the device) are pinned against each other by a codegen test, because a fold that disagreed with the runtime would answer one expression two ways. `73_string_literal_to_integral.va` never depended on the storage width and is still green: §3.3 justifies the literal against the DECLARED type, so `Lower.coerceTo` passes §3.2's 32 to `strToInt`. The two meet only at a literal with the top bit of its last 32 set, which no fixture writes: §2.7 calls that operand an unsigned constant and `strToInt` answers it as one, and the first arithmetic done to it wraps into range.

## Notes on structure

- **Same sentence, separate files.** §3.13.3 and §3.13.4 word the block-scope ban identically, but a net declaration and a branch declaration are different A.2.1.3 productions, so `48_net_local_to_block.va` and `49_branch_local_to_block.va` are separate. Same reasoning splits `67_duplicate_nature_name.va` from `67_duplicate_discipline_name.va`, `65_nature_access_as_string.va` from `65_nature_units_as_identifier.va`, `57_base_nature_missing_access.va` from `57_base_nature_missing_units.va` and from `35_base_nature_required_attributes.va` (three required attributes, three files), and `53_real_parameter_from_string.va` from `53_string_parameter_from_numeric.va`.
- **Phase-label pins.** Many rejections pin `DiagnosticsReported` rather than a code. That is deliberate where VerA has no diagnostic for the rule: pinning today's incidental code would pin the parser's recovery path, and would stop matching on the day the right check lands — which is exactly when the fixture starts being worth something. The `45_parameter_range_*` family pins the substring `range` and `78_alias_double_override.va` pins `alias` for the same reason, one notch stronger than a bare phase label.
- **Legal side, error side.** Most negatives name their positive twin in the header: `09_genvar` against the two `50_genvar_*`, `13_ground_declaration` against `62_ground_non_continuous`, `33_vector_branches` against `44_vector_branch_size_mismatch`, `11_discipline_declarations` against `46_same_nature_both_bindings` and `64_flow_on_potential_only_net`, `30_natureless_discipline`/`31_domainless_discipline` against `79`/`80`, `08_parameter_array` against `60_parameter_array_untyped` and `61_nonconstant_array_dimension`, `28_string_replication` against `52_nonconstant_replication_to_integral`, `66_idt_nature_self_reference` against `66_idt_nature_not_a_nature`.
- **Files that belong to another clause.** `16_paramset.va` cites §6.4 and C.8, not Chapter 3; it sits here only because the paramset rejection was found while reading this chapter. Its override behaviour is observable only through an instance and belongs with the Clause 6 fixtures.
