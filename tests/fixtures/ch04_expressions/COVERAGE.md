# Chapter 4 coverage

Audit checkpoint, 2026-09-23: the historical counts and coverage claims below
are not a rule-level completeness certificate. Current measurements are generated
in `docs/conformance-measurement.md`; source review and evidence limits for
§§4.1–4.2.3 are in `docs/conformance-expressions.md`. The full-table precedence
claim below covers representative cases, not every operator combination.
`audit_short_circuit_dynamic.va` adds input-derived logical/conditional
evaluation counters with an exact observation count; a temporary eager-operator
mutation fails its skipped-call assertion while preserving the numeric result.
The zero-modulus rejection now has isolated integer and real fixtures
(`111_modulus_by_zero_rejected.va`, `audit_real_modulus_zero_rejected.va`),
so one diagnostic cannot stand in for both paths. The new
`audit_modulus_sign_combinations.va` supplies independently derived sign cases
and legal nonzero neighbors; dynamic-divisor semantics remain unclosed.
Reduction negatives now isolate each spelling (EXPR-014 in the expression
ledger). The xor fixture's erroneous C.5 citation is withdrawn; its rule is
§4.2.10. This is stronger invalid-input evidence, not digital positive coverage.
Replication follow-up adds `audit_replication_zero_width.va` (a discriminating
middle-bit width observation) and `audit_replication_zero_effect.va`
(REPL-EVAL-001: XFAIL because the operand's side effect is erased). These
separate a passing value/width case from the unmet exactly-once obligation.

Source: `docs/ch4-expressions.html`, read in full through Section 4.7.3.
219 `.va` fixtures, of which 61 are `//! reject`, 158 run and assert, and NONE is
`//! xfail` (grep-measured over the directory; the "31 xfail, 19 of them also rejects"
this line used to give was measured before waves 1–6, and the "176 / 59 / 117" that
replaced it before the `a01_*`, `a04_*`, `a06_*` and 151–161 waves).

HTML section-ID audit: `s4-1` `s4-2` `s4-2-1` `s4-2-1-1` `s4-2-1-2` `s4-2-1-3`
`s4-2-2` `s4-2-3` `s4-2-4` `s4-2-5` `s4-2-6` `s4-2-7` `s4-2-8` `s4-2-9`
`s4-2-10` `s4-2-11` `s4-2-12` `s4-2-13` `s4-2-14` `s4-3` `s4-3-1` `s4-3-2`
`s4-4` `s4-5` `s4-5-1` `s4-5-2` `s4-5-3` `s4-5-4` `s4-5-5` `s4-5-6` `s4-5-7`
`s4-5-8` `s4-5-9` `s4-5-10` `s4-5-11` `s4-5-11-1` `s4-5-11-2` `s4-5-11-3`
`s4-5-11-4` `s4-5-11-5` `s4-5-12` `s4-5-12-1` `s4-5-12-2` `s4-5-12-3`
`s4-5-12-4` `s4-5-13` `s4-5-14` `s4-5-15` `s4-6` `s4-6-1` `s4-6-2` `s4-6-3`
`s4-6-4` `s4-6-4-1` `s4-6-4-2` `s4-6-4-3` `s4-6-4-4` `s4-6-4-5` `s4-6-4-6`
`s4-7` `s4-7-1` `s4-7-2` `s4-7-2-1` `s4-7-2-2` `s4-7-2-3` `s4-7-2-4` `s4-7-3`.
Sixty-seven anchors for sixty-seven printed subsections — this chapter's
extraction kept its anchors, so the audit is exact and needs no recovery from
body text. **Sixty-six are cited by some fixture in the suite; one, 4.1, is
not** — `zig build benchmark -- --coverage`, which counts a cite from any
directory and not only this one. The "forty-five … twenty-two" pair this line
used to carry was measured several waves earlier.

Every row below is a `//! lrm` cite grepped out of the fixtures themselves, not
a judgement about what a fixture is "really" testing. A file that runs a
construct but cites its parent clause is credited on the parent and said so in
the prose, never silently promoted.

| LRM section | Fixtures / disposition |
|---|---|
| 4.1 Overview | — no fixture cites it, and this is the only Clause 4 anchor in that state. The clause defines "expression" and "constant expression"; its one operative sentence ("The operands of a constant expression consists of constant numbers and parameter names, but they can use any of the operators defined in Table 4-1, Table 4-14, and Table 4-15") summarises A.8.4's `constant_primary` and §3.4's constancy rule, and both halves are pinned under those clauses — `ch03_data_types/82_parameter_default_not_constant_rejected.va` for the operand restriction, `ch03_data_types/90_dependent_control_guarded.va` for operators and functions in a default. A cite here would be a summary citing itself |
| 4.2 Operators | — no fixture cites the parent; Table 4-1 is the inventory and each entry is a child clause below |
| 4.2.1 Operators with real operands | `63_unary_plus.va`, `64_unary_minus.va` (Table 4-2 legal); `112_real_operand_illegal_operator_rejected.va` (E0322 — the closed-list half); `29_case_equality.va` (E0369 — `===`/`!==` on a real operand) |
| 4.2.1.1 Real to integer conversion | `02_numeric_conversions.va` (35.5→36, −1.5→−2: rounding, away from zero at the half) |
| 4.2.1.2 Integer to real conversion | — **no fixture.** The clause's own content is the x/z error case, which needs a four-state value system VerA does not have |
| 4.2.1.3 Arithmetic conversion | — no fixture cites it. `02_numeric_conversions.va` runs this clause's printed examples (`1/2` integer, `1/2.0` real) but cites them to 4.2.4 |
| 4.2.2 Operator precedence | `01_arithmetic_operators.va`, `03_precedence_associativity.va` (the full table, plus parenthesization) |
| 4.2.3 Expression evaluation order | `123_short_circuit_side_effects.va` (`&&`, `\|\|` and Example 1's non-short-circuiting bitwise `&`, each operand a counter so evaluation is observable). `125_short_circuit_ternary.va` — the clause's third operator, green: `?:` lowers to a CFG diamond (`Lower.lowerTernary`), so the call in the unselected arm never runs its side effect |
| 4.2.4 Arithmetic operators | `01_arithmetic_operators.va`, `02_numeric_conversions.va`, atomics `41_add.va` `42_subtract.va` `43_multiply.va` `44_divide.va` `45_modulo.va` `46_power_operator.va` `63_unary_plus.va` `64_unary_minus.va`; `111_modulus_by_zero_rejected.va` (E0601). `186_divisor_unproven_accepted.va` — the other direction: a parameter divisor (integer `/`, and real `%` on Table 4-6's `10 % 3.75`) is legal source; E0601 is only the provably-zero case. `118_modulo_negative_divisor.va` — green: the range analysis folds unary minus on an integer literal now, so the legal `11 % -3` is not raises a false E0601 with a full-i64 divisor range |
| 4.2.5 Relational operators | `04_relational_logical.va`; atomics `47_less_than.va` `48_greater_than.va` `49_less_equal.va` `50_greater_equal.va` |
| 4.2.6 Case equality operators | — **deliberately not cited.** `29_case_equality.va` runs `===`/`!==` on REAL operands and rejects them at E0369, citing 4.2.1 alone: read whole, 4.2.6 grants these operators "limited support in the analog block" and 7.3.2 prints `if (dnet === 1'b1)` inside `analog begin` as legal. Citing 4.2.6 would demand a diagnostic the clause forbids. The header says so in full |
| 4.2.7 Logical equality operators | `04_relational_logical.va`, `51_logical_equal.va`, `52_logical_unequal.va` |
| 4.2.8 Logical operators | `04_relational_logical.va`, `53_logical_and.va`, `54_logical_or.va`, `55_logical_not.va` |
| 4.2.9 Bitwise operators | `56_bitwise_and.va`, `57_bitwise_or.va`, `58_bitwise_xor.va`, `59_bitwise_xnor.va` (both `^~` and `~^`), `62_bitwise_not.va` |
| 4.2.10 Reduction operators | both fixtures are green (`06` on the substrings `reduction`/`analog block`, `07` on E0320). `06_reduction_rejected.va` — VerA lowers unary `&`, `\|`, `~&`, `~\|` in the analog block as IEEE 1364 32-bit reductions instead of diagnosing them; `lib/diag_code.zig` has E0319/E0320 but no code for the 4.2.10 analog-block ban itself. `07_reduction_xor_rejected.va` — the expression parser has no unary `^` at all, so `^bits` dies at E0215 before any subset check; E0320 exists and nothing raises it |
| 4.2.11 Shift operators | positive: `60_shift_left.va`, `61_shift_right.va`. Negative, both halves of the arithmetic-shift ban: `05_bitwise_shift.va` (`>>>`, E0324 — the filename is stale, it is a reject) and `117_arithmetic_shift_left_rejected.va` (`<<<`, E0324) |
| 4.2.12 Conditional operator | `08_conditional_operator.va` (nesting, right association). `125_short_circuit_ternary.va`, as under 4.2.3 — "expression3 is evaluated and used as the result" names one arm, and only that arm is evaluated |
| 4.2.13 Concatenations | `30_concatenation.va` (the joining form); `116_concatenation_unsized_rejected.va` (E0216, unsized constant); `31_replication.va` — three of the clause's four replication rules, `{4{2'b10}}`, the nested `{b, {3{a, b}}}` and the zero count, all unrolled in the parser where the operand widths still exist; `137_replication_lhs_rejected.va` (E0317, "expressions containing replications shall not appear on the left-hand side") |
| 4.2.14 Assignment patterns | `09_assignment_pattern.va` (parameter initialization), `32_array_assignment.va` (post-declaration), `144_assignment_pattern_replication.va` (samples single-element repeats); `audit_assignment_pattern_group.va` checks every element of repeated two-element groups in constant and signal-valued assignments. Other contexts/restrictions remain open as EXPR-019 in `docs/conformance-expressions.md`. |
| 4.3 Built-in mathematical functions | — no fixture cites the parent. Its one rule is that both syntax styles are supported; `10_standard_math_traditional.va` and `11_standard_math_system.va` are the two styles and both cite 4.3.1 |
| 4.3.1 Standard mathematical functions | `10_standard_math_traditional.va`, `11_standard_math_system.va` (`$sqrt`/`$ln`/`$exp`/`$pow`); atomics `65_sqrt.va` `66_exp.va` `67_ln.va` `68_log10.va` `69_floor.va` `70_ceil.va` `82_min.va` `83_max.va` `84_abs.va` `85_pow.va`; `114_standard_math_domain_rejected.va` (E0602, E0604). `33_ln1p_expm1.va` — green; codegen no longer emits the cancelling forms (it used to compute `zLn1p` as `a.addC(1.0).log()` and `zExpm1` as `a.exp().addC(-1.0)`), so `ln1p(1e-12)` carries the 8.9e-5 relative error Table 4-14's C `log1p`/`expm1` exist to avoid; `ir/proof.zig` already folds the constants correctly, only the emitted device is wrong |
| 4.3.2 Transcendental functions | `12_transcendental_math.va`; atomics `71_sin.va` `72_cos.va` `73_tan.va` `74_asin.va` `75_acos.va` `76_atan.va` `77_sinh.va` `78_cosh.va` `79_tanh.va` `80_hypot.va` `81_atan2.va`; `113_transcendental_domain_rejected.va` (E0605/E0606/E0607), `114_standard_math_domain_rejected.va` |
| 4.4 Signal access functions | positive: `13_signal_access.va` (one- and two-net, named branch), `34_port_access.va` (`I(<p>)` as a distinct quantity from `V(p)` and `I(p)`, both forced separately), `110_custom_discipline_access.va` (`CustomV`/`CustomI` from a renamed nature access). Negative: `115_port_access_lhs_rejected.va` (E0407, port access left of `<+`, with 5.4.3), `140_access_three_nets_rejected.va` (E0207), `141_port_access_not_a_port_rejected.va` (E0508), `87_wrong_discipline_access.va` (E0501). `13b_generic_access.va` adds §4.4's generic spelling — `potential(p,n)` against a written-down 1.0, and `potential`/`flow` against `V`/`I` as identities. One negative, now green: `86_same_flow_terminals.va` (`//! reject E0315`) — `I(n,n)`/`V(n,n)` are refused rather than accepted as a self-referential branch folded away, though E0315's own explain text already claims the rule |
| 4.5 Analog operators | `185_limexp_not_a_constant_expression_rejected.va` (`//! reject E0363`) is the parent's own sentence made observable: "One special analog operator is the limexp() function, which is a version of the exp() function" — so limexp is STATEFUL and cannot sit in a constant expression, and `parameter real bad = limexp(1.0);` is refused while §4.3's `exp(1.0)` in the same slot compiles (`ch06_hierarchy/dependent_parameter_transcendental.va` is the accept side in the tree). What the refusal is the whole of: the definition sentence ("they maintain their internal state") is what 4.5.15's restriction paragraph presupposes and cites, the family list is Syntax 4-3 whose every arm has a section above, and the file's header says both. So `--coverage` files 4.5 under REFUSED ONLY — accurate here rather than a gap: the clause's one source-level consequence is a classification error you can only catch in the negative |
| 4.5.1 Vector or array arguments | `35_filter_parameter_arrays.va` (parameter-array coefficients into `laplace_nd`) |
| 4.5.2 Analog operators and equations | `145_ddt_idt_nature_tolerance.va` carries the cite and earns it: the clause's third paragraph — "Occasionally, analog operators require new equations and new unknowns … ALTERNATIVELY, THESE OPERATORS CAN BE USED TO SPECIFY TOLERANCES" — is precisely the `ddt(expr, nature)` / `idt(expr, ic, assert, nature)` forms that file accepts, with the nature resolved in the tolerance slot. Its first paragraph ("each equation, at a minimum, shall have a tolerance defined and associated with it") constrains the solver and has no source text that can violate it; the file's header says so. This row used to read "**no fixture**" |
| 4.5.3 Time derivative operator | `14_ddt.va` (DC returns zero), `92_operator_in_genvar_for.va` (both unrolled `ddt` instances give zero at a nonzero argument). `145_ddt_idt_nature_tolerance.va` — the `ddt(expr, nature)` form of Table 4-17, green: the nature is resolved in the tolerance slot only and its `abstol` is taken |
| 4.5.4 Time integral operator | `15_idt.va`, `16_idt_reset_rejected.va`. `145_ddt_idt_nature_tolerance.va`, the `idt(expr, ic, assert, nature)` form of Table 4-18, green |
| 4.5.5 Circular integrator operator | `17_idtmod.va`. `126_idtmod_modulus_rejected.va` — green (`//! reject modulus`, `positive`); Table 4-19's argument bounds are validated, so `idtmod(x, 0.0, -2.0, 0.0)` and the zero-modulus form both compile with only W0650, and no diag code covers a non-positive modulus |
| 4.5.6 Derivative operator | `18_ddx.va` (potential unknown), `147_ddx_flow_unknown.va` (the flow half of the sentence, off a potential-source branch where `I(p,n)` is the solver unknown), `186_ddx_flow_column_in_eval.va` (the flow half again, with the result in a contribution so the testbench's wide-vs-narrow Jacobian gate compares the `ddxAt` lane), `132_ddx_nonprobe_argument_rejected.va` (E0504). `131_ddx_two_node_probe_rejected.va` — green: E0504 asks more than whether the second argument is an access-function call, so `ddx(expr, V(p,n))` with two nets passes it and compiles with only W0650 |
| 4.5.7 Absolute delay operator | `19_absdelay.va`. `127_absdelay_negative_delay_rejected.va` — green (`//! reject td`, `positive`): `absdelay(x, -2n)` and the three-argument form are refused rather than compiled with only W0650, and no diag code covers a non-positive transport delay |
| 4.5.8 Transition filter | `20_transition.va`. `128_transition_negative_time_rejected.va` — green; each of the negative `td`, `rise_time`, `fall_time` and `time_tol` variants all compile with only W0650 |
| 4.5.9 Slew filter | `21_slew.va`. `129_slew_rate_sign_rejected.va` — green; both rate-sign bounds are checked, so `slew(x, -1e6, -2e6)` and `slew(x, 1e6, 2e6)` no longer compile with only W0650 |
| 4.5.10 last_crossing function | `22_last_crossing.va` (rising edge over a five-point transient), `146_last_crossing_directions.va` (the −1 and 0 queries; the −1 one never leaves the negative sentinel because this input never falls). One negative, now green: `130_last_crossing_direction_rejected.va` — the direction indicator is checked, `last_crossing(x, 2)` and `last_crossing(x, -2)` compile with only W0650 |
| 4.5.11 Laplace transform filters | `23_laplace_filters.va` (all four forms), `35_filter_parameter_arrays.va`, `94_operator_null_argument.va` (E0502), `136_filter_null_zeros_argument.va` (the null zeros vector, `,,`, as the empty product 1 — E0505 is now scoped to the slots 4.5.15's "except" does NOT carve out) |
| 4.5.11.1 laplace_zp | `133_laplace_unpaired_complex_root_rejected.va` (a complex root with no conjugate partner) |
| 4.5.11.2 laplace_zd | — no fixture cites it; `23_laplace_filters.va` runs the form under the 4.5.11 cite |
| 4.5.11.3 laplace_np | — as 4.5.11.2 |
| 4.5.11.4 laplace_nd | — as 4.5.11.2; also run by `35_filter_parameter_arrays.va` and `96_function_filter_ban.va` under other cites. `laplace_transcendental_coefficient.va` cites it: H(0) = n0/d0 with n0 = sin(π/6), and a laplace_zp whose conjugate roots are written with sin() |
| 4.5.11.5 Examples | — no fixture cites it. `136_filter_null_zeros_argument.va` quotes this clause's band-limited-noise example as its source but cites 4.5.11 |
| 4.5.12 Z-transform filters | `24_z_transform_filters.va` (all four forms), `94_operator_null_argument.va` (E0502), `134_z_filter_period_rejected.va` (non-positive period), `136_filter_null_zeros_argument.va` (null zeros, above), `135_z_filter_zero_transition_branch_rejected.va` (E0518 — a zero-transition-time Z-filter contributed straight to a branch; the zero itself is legal and reading it into a variable still compiles). VerA implements the τ = 0 / t0 = 0 form only, and refuses a nonzero τ rather than emitting a different waveform silently |
| 4.5.12.1 zi_zp | — no fixture cites it; `24_z_transform_filters.va` runs the form under the 4.5.12 cite |
| 4.5.12.2 zi_zd | — as 4.5.12.1; also `134_z_filter_period_rejected.va` |
| 4.5.12.3 zi_np | — as 4.5.12.1 |
| 4.5.12.4 zi_nd | — as 4.5.12.1 |
| 4.5.13 Limited exponential | `25_limexp.va` |
| 4.5.14 Constant versus dynamic arguments | `audit_absdelay_dynamic_maxdelay_sampled` requires analysis-start sampling and later freezing of a dynamic maxdelay expression. The source explicitly permits this; blanket dynamic-slot rejection is a defect, not the negative oracle previously suggested here. Other argument slots and analysis restarts remain open. |
| 4.5.15 Restrictions on analog operators | the legal side: `119_operator_under_constant_condition.va` (a `parameter`-selected filter under `if`/`case`/`?:`, plus an `analysis("dc")` guard — the only fixture that can catch over-rejection) and `92_operator_in_genvar_for.va` (the analog_for that must keep compiling). Rejects that reject: `36_operator_in_conditional.va`, `88_operator_in_event.va`, `89_operator_in_repeat.va`, `90_operator_in_while.va`, `91_operator_in_runtime_for.va` (all E0514), `121_operator_in_ternary_rejected.va` (E0514 — the arms of a `?:` raise the same two conditional counters an `if` body does, so the clause's third named form is checked by the same test as the first two), `92_operator_in_function.va` (E0422), `94_operator_null_argument.va` (E0502), `93_operator_in_initial.va` and `122_operator_in_always_rejected.va` (both E0422 — the clause names `initial` and `always` explicitly, and both now reach it: the block is still refused as an item VerA cannot execute, but its body is parsed and judged, so 4.5.15 fires at the operator). Nothing in this row is xfail |
| 4.6 Analysis dependent functions | `27_noise_sources.va` cites the parent alongside 4.6.4 |
| 4.6.1 Analysis | `26_analysis.va` (multi-argument call as an OR; `"static"` is not a synonym for `"ic"`), `143_analysis_transient.va` (the three names that disagree between dc and tran, plus an unsupported name returning 0) |
| 4.6.2 DC analysis | — **no fixture.** The clause's rules are that `analysis("dc")`/`("static")` are true at every point of a sweep and that `analysis("nodeset")` is true only during the nodeset phase. `26_analysis.va` and `143_analysis_transient.va` exercise `"dc"`/`"static"`/`"ic"` at a single point under the 4.6.1 cite; `"nodeset"` appears in no fixture in this directory |
| 4.6.3 AC stimulus | `37_ac_stim.va` — zero in a large-signal analysis and zero for a name that matches nothing. VerA's residual is real, so a MATCHING small-signal analysis contributes the phasor's real part; the whole phasor leaves through `ac_gens`/`acStim(x, model, inst)`, whose `x` is there because A.8.2 gives the magnitude and phase as `analog_expression` (see `a06_ac_stim_dynamic_magnitude.va`) |
| 4.6.4 Noise | `27_noise_sources.va` (all four functions, with and without the optional name) |
| 4.6.4.1 white_noise | — no fixture cites it; run by `27_noise_sources.va`, `38_correlated_noise.va` and `136_filter_null_zeros_argument.va` under other cites |
| 4.6.4.2 flicker_noise | — as 4.6.4.1, run by `27_noise_sources.va` |
| 4.6.4.3 noise_table | `181_noise_table_topology.va` (the `table` row in the §4.6.4 export, and the clause's own "the simulator shall internally sort the pairs into ascending frequency" — the pairs are written descending), `183_noise_table_duplicate_frequency_rejected.va` (E0519, "Each frequency value must be unique"). The interpolation itself is graded in `tools/contract.zig`, where `noiseTableAt` is evaluated between the knots against hand-computed values; a dc fixture cannot see a PSD (§4.6.2). VerA takes all four of A.8.2's `noise_table_input_arg` spellings (since 2026-09-20): the file form is read at compile time, because 4.6.4.3 makes the name constant, and an array parameter exports its declared defaults in `noise_tables` plus the card's own knots in `noiseTablePoints`. `lrm_4_6_4_3.va` writes the file form and compiles while exporting NOTHING, which is not that rule being lenient: its source reaches the branch through a variable DECLARATION initializer, a path `var_noise` does not track, so the generator never reaches the export at all |
| 4.6.4.4 noise_table_log | `182_noise_table_log_topology.va` — the clause's own `'{1,1, 1e6,1e-6}` example, exported as a `.log` table beside a `white_noise` generator on the same branch. Figure 4-14's difference from 4.6.4.3 is the table's `interp` field and nothing else, and is graded by the log-log line tests in `tools/contract.zig` |
| 4.6.4.5 Noise model for diode | — **no fixture.** The clause's diode expression — a `white_noise` of the port flow plus a `flicker_noise` of its power, both on an exponential branch — is written nowhere here; `25_limexp.va` has the diode without the noise and `27_noise_sources.va` the noise without the diode |
| 4.6.4.6 Correlated noise | `38_correlated_noise.va` (one `white_noise` result reused by two sources, which is the clause's own Example 1) |
| 4.7 User-defined functions | — no fixture cites the parent; two sentences of introduction |
| 4.7.1 Defining an analog user-defined function | positive: `28_user_function.va`, `142_function_implicit_real_return.va` (the optional `analog_function_type`: omitted defaults to real, not to 1364's integer; and the explicit `integer` form). Body/formal bans that fire: `95_function_access_ban.va` (E0421), `96_function_filter_ban.va` (E0422), `97_function_contribution_ban.va` (E0405), `98_function_event_ban.va` (E0702), `92_operator_in_function.va` (E0422), `103_function_nonlocal_variable.va` (E0314). The formal and body bullets of the list are now checked at the DECLARATION, which is where 4.7.1 states them and the only place a function nobody calls can be reached at all: `100_function_no_arguments.va` and `102_function_undirected_argument.va` (E0224, the minimum of one formal — a block item declaration with no direction is a local variable, not a formal), `101_function_untyped_argument.va` (E0225, the block-item-declaration requirement; 4.7.1's "if unspecified, the default is real" is about the RETURN type and does not reach a formal), `99_function_named_block_ban.va` (E0226) |
| 4.7.2 Returning a value | *nothing* — `102_function_undirected_argument.va` used to be credited here for E0511's arity check, and is now refused one clause earlier, at 4.7.1's minimum of one formal (E0224) |
| 4.7.2.1 Function identifier variable | `28_user_function.va`, `40_function_return.va` |
| 4.7.2.2 Analog function return statement | `40_function_return.va` is the legal side including the override rule; `139_function_bare_return_rejected.va` is E0227, "the function shall specify an expression" |
| 4.7.2.3 Output arguments | `39_function_output_inout.va`, `124_function_unassigned_output_inout.va` (the initialize-to-zero half of the output/inout difference), `106_function_output_nonvariable.va` (E0316), `108_function_array_output_pattern.va` (green: `output [0:1] out` is an array formal and `'{a,b}` its assignment-pattern actual, copied out element by element) |
| 4.7.2.4 Inout arguments | `39_function_output_inout.va`, `124_function_unassigned_output_inout.va` (the left-untouched half), `107_function_inout_nonvariable.va` (E0316), `109_function_array_inout_pattern.va` (green: §4.7.1's own `arrayadd` example, copy-in and copy-out both asserted) |
| 4.7.3 Calling an analog user-defined function | `104_function_direct_recursion.va`, `105_function_indirect_recursion.va` (both E0510), `109_function_array_inout_pattern.va` (§4.7.3's own call of `arrayadd`), `138_function_called_outside_analog_rejected.va` (E0430 — the call from an `initial` block, i.e. from outside the analog context; the block is refused as an item but its body is still judged). Nothing in this row is xfail |

## The debt ledger

EMPTY — grep finds no `//! xfail` in this directory. It held twenty-three rows, fourteen of
them also carrying `//! reject` (rules this chapter states that the compiler did not
enforce). The grouping is kept because it is the record of what KIND of defect each was,
and because three of the groups were wrong in an instructive way.

**Five were missing checks that could be written today, and were written.** All five
analog-operator argument-bound families were here and were the largest single block in the
chapter: `126_idtmod_modulus_rejected.va` (non-positive modulus),
`127_absdelay_negative_delay_rejected.va` (negative transport delay),
`128_transition_negative_time_rejected.va` (negative `td`/`rise_time`/`fall_time`/
`time_tol`), `129_slew_rate_sign_rejected.va` (wrongly-signed rates) and
`130_last_crossing_direction_rejected.va` (direction outside {+1, −1, 0}). Every one used
to compile with only W0650 and `lib/diag_code.zig` had no code to give them; each now
refuses, and each pins the message substrings of Table 4-19/4-20's own bound rather than a
code, so the diagnostic can be renumbered without touching a fixture. The four 4.7.1/4.7.2.2
function rules that sat beside them — the named-block ban, the minimum of one formal, the
formal's data type and the bare `return;` — closed earlier as E0226, E0224, E0225 and E0227.

**Two were checks that existed but were too weak, and both were one edit.**
`131_ddx_two_node_probe_rejected.va` — E0504 asked only "is the second argument an
access-function call", so a two-net probe slipped through. `86_same_flow_terminals.va` —
E0315's own explain text already printed the rule ("LRM 4.4 also forbids V(n1, n1)") and
nothing raised it. `121_operator_in_ternary_rejected.va` was the third: E0514 walked `if`
and `case` statements only, and the arms of a `?:` raise the same counters now.

**Five never reached the rule: something earlier refused, or mis-lowered.** This group is
the one worth reading, because the pattern in it recurred four times.
`93_operator_in_initial.va`, `122_operator_in_always_rejected.va` and
`138_function_called_outside_analog_rejected.va` were masked by E0205: the block is still
refused as an item VerA cannot execute, but the refusal RECOVERS now, so the body is parsed
and judged and 4.5.15 fires as E0422 and 4.7.3 as E0430. `137_replication_lhs_rejected.va`
died at E0207 for want of a replication form on a left-hand side and pins E0317 now.
`07_reduction_xor_rejected.va` was the same shape — no unary `^` in the parser, so E0215
arrived before the analog-subset check — and pins E0320. `06_reduction_rejected.va` was its
opposite and the worst of the group: the four non-parity reductions DID parse, and lowered
as IEEE 1364 32-bit reductions, which is a wrong answer rather than a missing one; it pins
the substrings `reduction` and `analog block`.

**Three rejected something legal.** `135_z_filter_zero_transition_branch_rejected.va` and
`136_filter_null_zeros_argument.va` were over-rejections: the first because codegen refused
the entire optional `t`/`t0` tail of a `zi_*` filter and so could not distinguish the legal
non-zero transition from the illegal zero one; the second because E0505, which is 4.5.15's
null-argument ban, fired on the 4.5.11/4.5.12 null-zeros carve-out that ban's own "except"
clause points at. `136` runs and asserts now, with no reject arm at all — which is the
correct shape for an over-rejection closing. `118_modulo_negative_divisor.va` was the third
and the smallest, and its stated reason was WRONG in a way worth recording: it was filed as
a modulo bug and was really unary-minus folding in the range analysis, so `11 % -3` was
reported as a possible division by zero.

**Some got the wrong answer or could not be reached, with no reject to carry.**
`108_function_array_output_pattern.va` and `109_function_array_inout_pattern.va` were the
parser boundary and A.2.6's array formals pass element-wise in both directions now.
`33_ln1p_expm1.va` was the semantic one: codegen emitted the cancelling forms, which is
exactly the precision loss §4.3.1 has these two functions for.
`146_last_crossing_directions.va`, `37_ac_stim.va` and `125_short_circuit_ternary.va` left
this list earlier.

## Where a fixture is credited, and where it is not

Ten rows above are empty because a fixture runs the construct but cites the
*parent* clause, and a row is credited on the cite the file actually carries,
not on what it can be argued to test. `23_laplace_filters.va` exercises all four
Laplace forms and `24_z_transform_filters.va` all four Z forms, but each cites
its parent (4.5.11, 4.5.12), so 4.5.11.2–.5 and 4.5.12.1–.4 show empty above.
`27_noise_sources.va` runs `white_noise`, `flicker_noise`, `noise_table` and
`noise_table_log` under a 4.6.4 cite, so 4.6.4.1 and .2 show empty (.3 and .4
have fixtures of their own). This is a bookkeeping gap, not a testing one;
splitting the cites would close ten rows without writing a line of Verilog-A.
An eleventh, 4.2.1.3, is the same story:
`02_numeric_conversions.va` runs that clause's printed examples under a 4.2.4
cite. (4.3's two-syntax-styles rule is likewise satisfied by
`10_standard_math_traditional.va` and `11_standard_math_system.va` under 4.3.1
cites, but 4.3 is counted below as an introduction.)

**4.2.6 is different and should not be "closed".** `29_case_equality.va`
rejects `===`/`!==` and deliberately does not cite 4.2.6, because 4.2.6 grants
those operators limited support in the analog block and 7.3.2 prints a legal
example of one. The reject stands on 4.2.1's real-operand rule alone; on
integer operands VerA now accepts both operators (`annex_a_syntax/66`). Adding
a 4.2.6 cite here would be claiming conformance to a rule this fixture
contradicts.

The accounting that used to close this file — twenty-four uncovered sections
split into a thirteen-clause "bookkeeping gap", 4.2.6's deliberate abstention,
five pure introductions and five clauses "with genuinely nothing behind them" —
is deleted rather than renumbered, because two waves have walked through every
entry in it. **4.1** is the only Clause 4 anchor no fixture cites at all, and
the four clauses the last list named are cited now: **4.2.1.2** by
`a01_10_itor_widens_an_integer.va`, **4.5.2** by `145` above, **4.5.14** by
`159_operator_missing_mandatory_argument.va`, **4.6.2** by
`annex_e_spice/h04_07_subckt_source_card_drives_the_node.va`. Of the introductions, **4.1**, **4.2**, **4.3** and
**4.7** remain pure introductions that state no rule of their own; **4.5** is
now cited on its limexp sentence. 4.2.6's abstention is explained in its own
row, which is where it belongs.

## Fixture layout

The atomic operator fixtures `41_add.va` through `64_unary_minus.va` and the
atomic mathematical-function fixtures `65_sqrt.va` through `85_pow.va` are one
construct per file, so each produces an independent dump and a regression in
one cannot be masked by a neighbour in an omnibus expression. The omnibus
files they sit under (`01`, `04`, `05`, `10`, `11`, `12`) remain, because
precedence and conversion rules only exist between operators.

Ninety-seven of the 149 fixtures include `check.vh` and assert numeric values;
the rest are rejects, which assert a diagnostic instead.

Two naming defects, neither worth an edit on its own: `92_operator_in_function.va`
and `92_operator_in_genvar_for.va` share a number, and `13b_generic_access.va`
carries a letter suffix nothing else in the tree uses. `05_bitwise_shift.va` is
named for a value test and is in fact a `>>>` reject; its own header says so.
