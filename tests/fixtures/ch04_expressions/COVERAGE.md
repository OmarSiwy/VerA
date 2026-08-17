# Chapter 4 coverage

Source: `docs/VAMS-LRM/ch4-expressions.html`, read in full through Section 4.7.3.
149 `.va` fixtures, of which 52 are `//! reject` and 31 are `//! xfail`
(19 files are both — a reject that does not reject).

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
body text. **Forty-three have a fixture that cites them, twenty-four do not.**

Every row below is a `//! lrm` cite grepped out of the fixtures themselves, not
a judgement about what a fixture is "really" testing. A file that runs a
construct but cites its parent clause is credited on the parent and said so in
the prose, never silently promoted.

| LRM section | Fixtures / disposition |
|---|---|
| 4.1 Overview | — no fixture cites it; the clause defines "expression" and "constant expression" and states no testable rule of its own |
| 4.2 Operators | — no fixture cites the parent; Table 4-1 is the inventory and each entry is a child clause below |
| 4.2.1 Operators with real operands | `63_unary_plus.va`, `64_unary_minus.va` (Table 4-2 legal); `112_real_operand_illegal_operator_rejected.va` (E0322 — the closed-list half); `29_case_equality.va` (E0323, jointly with C.5) |
| 4.2.1.1 Real to integer conversion | `02_numeric_conversions.va` (35.5→36, −1.5→−2: rounding, away from zero at the half) |
| 4.2.1.2 Integer to real conversion | — **no fixture.** The clause's own content is the x/z error case, which needs a four-state value system VerA does not have |
| 4.2.1.3 Arithmetic conversion | — no fixture cites it. `02_numeric_conversions.va` runs this clause's printed examples (`1/2` integer, `1/2.0` real) but cites them to 4.2.4 |
| 4.2.2 Operator precedence | `01_arithmetic_operators.va`, `03_precedence_associativity.va` (the full table, plus parenthesization) |
| 4.2.3 Expression evaluation order | `123_short_circuit_side_effects.va` (`&&`, `\|\|` and Example 1's non-short-circuiting bitwise `&`, each operand a counter so evaluation is observable). `125_short_circuit_ternary.va` **xfail** — VerA evaluates both arms of `?:` and selects afterwards, so `0 ? bump(e) : 0` leaves `e` at 1 instead of 0 |
| 4.2.4 Arithmetic operators | `01_arithmetic_operators.va`, `02_numeric_conversions.va`, atomics `41_add.va` `42_subtract.va` `43_multiply.va` `44_divide.va` `45_modulo.va` `46_power_operator.va` `63_unary_plus.va` `64_unary_minus.va`; `111_modulus_by_zero_rejected.va` (E0601). `118_modulo_negative_divisor.va` **xfail** — VerA's range analysis does not fold unary minus on an integer literal, so the legal `11 % -3` raises a false E0601 with a full-i64 divisor range |
| 4.2.5 Relational operators | `04_relational_logical.va`; atomics `47_less_than.va` `48_greater_than.va` `49_less_equal.va` `50_greater_equal.va` |
| 4.2.6 Case equality operators | — **deliberately not cited.** `29_case_equality.va` runs `===`/`!==` and rejects them at E0323, but cites C.5 and 4.2.1: read whole, 4.2.6 grants these operators "limited support in the analog block" and 7.3.2 prints `if (dnet === 1'b1)` inside `analog begin` as legal. Citing 4.2.6 would demand a diagnostic the clause forbids. The header says so in full |
| 4.2.7 Logical equality operators | `04_relational_logical.va`, `51_logical_equal.va`, `52_logical_unequal.va` |
| 4.2.8 Logical operators | `04_relational_logical.va`, `53_logical_and.va`, `54_logical_or.va`, `55_logical_not.va` |
| 4.2.9 Bitwise operators | `56_bitwise_and.va`, `57_bitwise_or.va`, `58_bitwise_xor.va`, `59_bitwise_xnor.va` (both `^~` and `~^`), `62_bitwise_not.va` |
| 4.2.10 Reduction operators | both fixtures are **xfail**. `06_reduction_rejected.va` — VerA lowers unary `&`, `\|`, `~&`, `~\|` in the analog block as IEEE 1364 32-bit reductions instead of diagnosing them; `src/diag_code.zig` has E0319/E0320 but no code for the 4.2.10 analog-block ban itself. `07_reduction_xor_rejected.va` — the expression parser has no unary `^` at all, so `^bits` dies at E0215 before any subset check; E0320 exists and nothing raises it |
| 4.2.11 Shift operators | positive: `60_shift_left.va`, `61_shift_right.va`. Negative, both halves of the arithmetic-shift ban: `05_bitwise_shift.va` (`>>>`, E0324 — the filename is stale, it is a reject) and `117_arithmetic_shift_left_rejected.va` (`<<<`, E0324) |
| 4.2.12 Conditional operator | `08_conditional_operator.va` (nesting, right association). `125_short_circuit_ternary.va` **xfail**, as under 4.2.3 |
| 4.2.13 Concatenations | `30_concatenation.va` (the joining form); `116_concatenation_unsized_rejected.va` (E0216, unsized constant). Two **xfail**: `31_replication.va` — VerA's parser has no replication form, `{4{2'b10}}` stops at E0207, so none of 4.2.13's four replication rules is implemented; `137_replication_lhs_rejected.va` — the LHS ban is behind that same gap, `{2{a}}` dies at E0207 and E0317 never fires |
| 4.2.14 Assignment patterns | `09_assignment_pattern.va` (parameter initialization), `32_array_assignment.va` (post-declaration). `144_assignment_pattern_replication.va` **xfail** — no replication inside an assignment pattern either: `'{5{0.0}}` stops at E0207, the same parser gap |
| 4.3 Built-in mathematical functions | — no fixture cites the parent. Its one rule is that both syntax styles are supported; `10_standard_math_traditional.va` and `11_standard_math_system.va` are the two styles and both cite 4.3.1 |
| 4.3.1 Standard mathematical functions | `10_standard_math_traditional.va`, `11_standard_math_system.va` (`$sqrt`/`$ln`/`$exp`/`$pow`); atomics `65_sqrt.va` `66_exp.va` `67_ln.va` `68_log10.va` `69_floor.va` `70_ceil.va` `82_min.va` `83_max.va` `84_abs.va` `85_pow.va`; `114_standard_math_domain_rejected.va` (E0602, E0604). `33_ln1p_expm1.va` **xfail** — codegen emits the cancelling forms (`zLn1p` is `a.addC(1.0).log()`, `zExpm1` is `a.exp().addC(-1.0)`), so `ln1p(1e-12)` carries the 8.9e-5 relative error Table 4-14's C `log1p`/`expm1` exist to avoid; `ir/proof.zig` already folds the constants correctly, only the emitted device is wrong |
| 4.3.2 Transcendental functions | `12_transcendental_math.va`; atomics `71_sin.va` `72_cos.va` `73_tan.va` `74_asin.va` `75_acos.va` `76_atan.va` `77_sinh.va` `78_cosh.va` `79_tanh.va` `80_hypot.va` `81_atan2.va`; `113_transcendental_domain_rejected.va` (E0605/E0606/E0607), `114_standard_math_domain_rejected.va` |
| 4.4 Signal access functions | positive: `13_signal_access.va` (one- and two-net, named branch), `34_port_access.va` (`I(<p>)` as a distinct quantity from `V(p)` and `I(p)`, both forced separately), `110_custom_discipline_access.va` (`CustomV`/`CustomI` from a renamed nature access). Negative: `115_port_access_lhs_rejected.va` (E0407, port access left of `<+`, with 5.4.3), `140_access_three_nets_rejected.va` (E0207), `141_port_access_not_a_port_rejected.va` (E0508), `87_wrong_discipline_access.va` (E0501). Two **xfail**: `13b_generic_access.va` — VerA's parser does not know the generic access functions, `potential(b)`/`flow(b)` die at E0209; `86_same_flow_terminals.va` — `I(n,n)`/`V(n,n)` are accepted and the self-referential branch folded away, though E0315's own explain text already claims the rule |
| 4.5 Analog operators | — no fixture cites the parent; it is the definition of "maintains internal state" and a pointer at its children |
| 4.5.1 Vector or array arguments | `35_filter_parameter_arrays.va` (parameter-array coefficients into `laplace_nd`) |
| 4.5.2 Analog operators and equations | — **no fixture.** The clause's rule is that each equation carries a tolerance and that some operators introduce new unknowns. `22_last_crossing.va` and `146_last_crossing_directions.va` lean on it in prose (the history may advance on an untested point) but neither cites it, and nothing asserts a tolerance or a new unknown |
| 4.5.3 Time derivative operator | `14_ddt.va` (DC returns zero), `92_operator_in_genvar_for.va` (both unrolled `ddt` instances give zero at a nonzero argument). `145_ddt_idt_nature_tolerance.va` **xfail** — VerA does not resolve a nature identifier as an operator argument: `ddt(1p*V(p,n), Current)` raises E0314, with or without an explicit `disciplines.vams` |
| 4.5.4 Time integral operator | `15_idt.va`, `16_idt_reset_rejected.va`. `145_ddt_idt_nature_tolerance.va` **xfail**, same E0314 for `idt(I(p,n), 5.0, 0, Current)` |
| 4.5.5 Circular integrator operator | `17_idtmod.va`. `126_idtmod_modulus_rejected.va` **xfail** — VerA validates none of Table 4-19's argument bounds: `idtmod(x, 0.0, -2.0, 0.0)` and the zero-modulus form both compile with only W0650, and no diag code covers a non-positive modulus |
| 4.5.6 Derivative operator | `18_ddx.va` (potential unknown), `147_ddx_flow_unknown.va` (the flow half of the sentence, off a potential-source branch where `I(p,n)` is the solver unknown), `132_ddx_nonprobe_argument_rejected.va` (E0504). `131_ddx_two_node_probe_rejected.va` **xfail** — E0504 only asks whether the second argument is an access-function call, so `ddx(expr, V(p,n))` with two nets passes it and compiles with only W0650 |
| 4.5.7 Absolute delay operator | `19_absdelay.va`. `127_absdelay_negative_delay_rejected.va` **xfail** — no argument-bound validation: `absdelay(x, -2n)` and the three-argument form both compile with only W0650, and no diag code covers a non-positive transport delay |
| 4.5.8 Transition filter | `20_transition.va`. `128_transition_negative_time_rejected.va` **xfail** — no argument-bound validation: the negative `td`, `rise_time`, `fall_time` and `time_tol` variants all compile with only W0650 |
| 4.5.9 Slew filter | `21_slew.va`. `129_slew_rate_sign_rejected.va` **xfail** — neither rate-sign bound is checked: `slew(x, -1e6, -2e6)` and `slew(x, 1e6, 2e6)` both compile with only W0650 |
| 4.5.10 last_crossing function | `22_last_crossing.va` (rising edge over a five-point transient). Two **xfail**: `146_last_crossing_directions.va` — VerA's `last_crossing` ignores its direction argument for anything but +1, so the −1 and 0 queries both return a flat 0.0 at every time point; `130_last_crossing_direction_rejected.va` — no check on the direction indicator either, `last_crossing(x, 2)` and `last_crossing(x, -2)` compile with only W0650 |
| 4.5.11 Laplace transform filters | `23_laplace_filters.va` (all four forms), `35_filter_parameter_arrays.va`, `94_operator_null_argument.va` (E0502). `136_filter_null_zeros_argument.va` **xfail** — the legal null zeros vector is rejected at E0505 ("analog operator does not accept an empty argument"): that code is 4.5.15's null-argument ban and it over-fires on the 4.5.11/4.5.12 carve-out the ban's own "except" points at |
| 4.5.11.1 laplace_zp | `133_laplace_unpaired_complex_root_rejected.va` (a complex root with no conjugate partner) |
| 4.5.11.2 laplace_zd | — no fixture cites it; `23_laplace_filters.va` runs the form under the 4.5.11 cite |
| 4.5.11.3 laplace_np | — as 4.5.11.2 |
| 4.5.11.4 laplace_nd | — as 4.5.11.2; also run by `35_filter_parameter_arrays.va` and `96_function_filter_ban.va` under other cites |
| 4.5.11.5 Examples | — no fixture cites it. `136_filter_null_zeros_argument.va` quotes this clause's band-limited-noise example as its source but cites 4.5.11 |
| 4.5.12 Z-transform filters | `24_z_transform_filters.va` (all four forms), `94_operator_null_argument.va` (E0502), `134_z_filter_period_rejected.va` (non-positive period). `136_filter_null_zeros_argument.va` **xfail** (E0505, above) and `135_z_filter_zero_transition_branch_rejected.va` **xfail** — VerA's codegen refuses the whole optional `t`/`t0` tail of a `zi_*` filter, so the legal non-zero transition is rejected alongside the illegal zero one and the rule that distinguishes them is never reached |
| 4.5.12.1 zi_zp | — no fixture cites it; `24_z_transform_filters.va` runs the form under the 4.5.12 cite |
| 4.5.12.2 zi_zd | — as 4.5.12.1; also `134_z_filter_period_rejected.va` |
| 4.5.12.3 zi_np | — as 4.5.12.1 |
| 4.5.12.4 zi_nd | — as 4.5.12.1 |
| 4.5.13 Limited exponential | `25_limexp.va` |
| 4.5.14 Constant versus dynamic arguments | — **no fixture.** Table 4-20 splits every operator's arguments into constant and dynamic; nothing in this directory asserts that a dynamic expression in a constant slot is refused, or that a constant one is held fixed for the analysis |
| 4.5.15 Restrictions on analog operators | the legal side: `119_operator_under_constant_condition.va` (a `parameter`-selected filter under `if`/`case`/`?:`, plus an `analysis("dc")` guard — the only fixture that can catch over-rejection) and `92_operator_in_genvar_for.va` (the analog_for that must keep compiling). Rejects that reject: `36_operator_in_conditional.va`, `88_operator_in_event.va`, `89_operator_in_repeat.va`, `90_operator_in_while.va`, `91_operator_in_runtime_for.va` (all E0514), `92_operator_in_function.va` (E0422), `94_operator_null_argument.va` (E0502). Three **xfail**: `121_operator_in_ternary_rejected.va` — E0514's check walks `if` and `case` only, an operator in a `?:` arm under a probe condition compiles with W0650; `93_operator_in_initial.va` and `122_operator_in_always_rejected.va` — `initial` and `always` are refused wholesale at E0205 (unsupported module item), so the parse dies before 4.5.15 is reached and E0422 never fires |
| 4.6 Analysis dependent functions | `27_noise_sources.va` cites the parent alongside 4.6.4 |
| 4.6.1 Analysis | `26_analysis.va` (multi-argument call as an OR; `"static"` is not a synonym for `"ic"`), `143_analysis_transient.va` (the three names that disagree between dc and tran, plus an unsupported name returning 0) |
| 4.6.2 DC analysis | — **no fixture.** The clause's rules are that `analysis("dc")`/`("static")` are true at every point of a sweep and that `analysis("nodeset")` is true only during the nodeset phase. `26_analysis.va` and `143_analysis_transient.va` exercise `"dc"`/`"static"`/`"ic"` at a single point under the 4.6.1 cite; `"nodeset"` appears in no fixture in this directory |
| 4.6.3 AC stimulus | `37_ac_stim.va` **xfail** — VerA's codegen emits `@compileError` for `ac_stim`; the small-signal source functions of 4.6 have no lowering at all |
| 4.6.4 Noise | `27_noise_sources.va` (all four functions, with and without the optional name) |
| 4.6.4.1 white_noise | — no fixture cites it; run by `27_noise_sources.va`, `38_correlated_noise.va` and `136_filter_null_zeros_argument.va` under other cites |
| 4.6.4.2 flicker_noise | — as 4.6.4.1, run by `27_noise_sources.va` |
| 4.6.4.3 noise_table | — as 4.6.4.1 |
| 4.6.4.4 noise_table_log | — as 4.6.4.1 |
| 4.6.4.5 Noise model for diode | — **no fixture.** The clause's diode expression — a `white_noise` of the port flow plus a `flicker_noise` of its power, both on an exponential branch — is written nowhere here; `25_limexp.va` has the diode without the noise and `27_noise_sources.va` the noise without the diode |
| 4.6.4.6 Correlated noise | `38_correlated_noise.va` (one `white_noise` result reused by two sources, which is the clause's own Example 1) |
| 4.7 User-defined functions | — no fixture cites the parent; two sentences of introduction |
| 4.7.1 Defining an analog user-defined function | positive: `28_user_function.va`, `142_function_implicit_real_return.va` (the optional `analog_function_type`: omitted defaults to real, not to 1364's integer; and the explicit `integer` form). Body/formal bans that fire: `95_function_access_ban.va` (E0421), `96_function_filter_ban.va` (E0422), `97_function_contribution_ban.va` (E0405), `98_function_event_ban.va` (E0702), `92_operator_in_function.va` (E0422), `102_function_undirected_argument.va` (E0511), `103_function_nonlocal_variable.va` (E0314). Three **xfail**: `99_function_named_block_ban.va` — a labelled sequential block inside `analog function` parses and lowers, no diag code exists for the ban; `100_function_no_arguments.va` — an empty formal list is accepted because E0511 only checks that the two counts agree and 0 == 0 passes, nothing enforces the minimum of one formal; `101_function_untyped_argument.va` — an undeclared formal is silently typed real, nothing enforces the block-item-declaration requirement |
| 4.7.2 Returning a value | `102_function_undirected_argument.va` (E0511) |
| 4.7.2.1 Function identifier variable | `28_user_function.va`, `40_function_return.va` |
| 4.7.2.2 Analog function return statement | `40_function_return.va`. `139_function_bare_return_rejected.va` **xfail** — a bare `return;` is accepted inside an analog function and falls back on the 4.7.2.1 default; no diag code covers a return with no expression |
| 4.7.2.3 Output arguments | `39_function_output_inout.va`, `124_function_unassigned_output_inout.va` (the initialize-to-zero half of the output/inout difference), `106_function_output_nonvariable.va` (E0316). `108_function_array_output_pattern.va` **xfail** — VerA's parser has no array formals in an analog function: `output [0:1] out` and the `'{a,b}` actual are both ParseErrors |
| 4.7.2.4 Inout arguments | `39_function_output_inout.va`, `124_function_unassigned_output_inout.va` (the left-untouched half), `107_function_inout_nonvariable.va` (E0316). `109_function_array_inout_pattern.va` **xfail** — same array-formal parser gap, `inout [0:1] a` and `'{y,z}` |
| 4.7.3 Calling an analog user-defined function | `104_function_direct_recursion.va`, `105_function_indirect_recursion.va` (both E0510). Two **xfail**: `138_function_called_outside_analog_rejected.va` — `initial` is refused wholesale at E0205, so the parse dies before the calling-context rule is reached; `109_function_array_inout_pattern.va` — the array-formal parser gap, above |

## The debt ledger

Thirty-one fixtures carry `//! xfail`. Nineteen of them also carry
`//! reject`, which is the interesting number: nineteen rules this chapter
states that the compiler does not enforce.

**Nine are missing checks that could be written today** — the construct is
parsed, lowered and run, and nothing complains. All five analog-operator
argument-bound families are here and they are the largest single block in the
chapter: `126_idtmod_modulus_rejected.va` (non-positive modulus),
`127_absdelay_negative_delay_rejected.va` (negative transport delay),
`128_transition_negative_time_rejected.va` (negative `td`/`rise_time`/
`fall_time`/`time_tol`), `129_slew_rate_sign_rejected.va` (wrongly-signed
rates) and `130_last_crossing_direction_rejected.va` (direction outside
{+1, −1, 0}). Every one compiles with only W0650, and `src/diag_code.zig` has
no code to give them. The other four are
`99_function_named_block_ban.va`, `100_function_no_arguments.va` and
`101_function_untyped_argument.va` (three of 4.7.1's formal and body rules),
and `139_function_bare_return_rejected.va` (bare `return;`).

**Three are checks that exist but are too weak.** `131_ddx_two_node_probe_rejected.va`
— E0504 asks only "is the second argument an access-function call", so a
two-net probe slips through. `121_operator_in_ternary_rejected.va` — E0514
walks `if` and `case` statements and not `?:`. `86_same_flow_terminals.va` —
E0315's own explain text already prints the rule ("LRM 4.4 also forbids
V(n1, n1)") and nothing raises it. These are three edits, not three features.

**Six never reach the rule: something earlier refuses, or mis-lowers.**
`93_operator_in_initial.va`, `122_operator_in_always_rejected.va` and
`138_function_called_outside_analog_rejected.va` all die at E0205 (unsupported
module item) because VerA refuses `initial` and `always` wholesale, so 4.5.15
and 4.7.3 are never consulted. `137_replication_lhs_rejected.va` dies at E0207
because there is no replication form to put on a left-hand side.
`07_reduction_xor_rejected.va` is the same shape — no unary `^` in the parser,
so E0215 arrives before the analog-subset check — and
`06_reduction_rejected.va` is its opposite: the four non-parity reductions do
parse, and lower as IEEE 1364 32-bit reductions, which is worse than not
parsing.

That is nine plus three plus six, and the nineteenth is an over-rejection.

**Three reject something legal.** `135_z_filter_zero_transition_branch_rejected.va`
and `136_filter_null_zeros_argument.va` are over-rejections: the first because
codegen refuses the entire optional `t`/`t0` tail of a `zi_*` filter and so
cannot distinguish the legal non-zero transition from the illegal zero one;
the second because E0505, which is 4.5.15's null-argument ban, fires on the
4.5.11/4.5.12 null-zeros carve-out that ban's own "except" clause points at.
`118_modulo_negative_divisor.va` is the third and the smallest — the range
analysis does not fold unary minus on an integer literal, so `11 % -3` is
reported as a possible division by zero.

**Twelve get the wrong answer or cannot be reached, with no reject to carry.**
Five are parser boundaries: `31_replication.va` and
`144_assignment_pattern_replication.va` (no replication form, in a
concatenation or an assignment pattern), `108_function_array_output_pattern.va`
and `109_function_array_inout_pattern.va` (no array formals in an analog
function), `13b_generic_access.va` (no generic `potential()`/`flow()`).
`145_ddt_idt_nature_tolerance.va` is a name-resolution boundary — a nature
identifier in an operator's tolerance slot raises E0314. The remaining six are
semantic: `125_short_circuit_ternary.va` (`?:` evaluates both arms),
`146_last_crossing_directions.va` (`last_crossing` honours only +1),
`33_ln1p_expm1.va` (`ln1p`/`expm1` emitted as the cancelling forms),
`37_ac_stim.va` (`ac_stim` lowers to `@compileError`), and the two
over-rejections already counted above.

## Where a fixture is credited, and where it is not

Twelve rows above are empty because a fixture runs the construct but cites the
*parent* clause, and a row is credited on the cite the file actually carries,
not on what it can be argued to test. `23_laplace_filters.va` exercises all four
Laplace forms and `24_z_transform_filters.va` all four Z forms, but each cites
its parent (4.5.11, 4.5.12), so 4.5.11.2–.5 and 4.5.12.1–.4 show empty above.
`27_noise_sources.va` runs `white_noise`, `flicker_noise`, `noise_table` and
`noise_table_log` under a 4.6.4 cite, so 4.6.4.1–.4 show empty. This is a
bookkeeping gap, not a testing one; splitting the cites would close twelve rows
without writing a line of Verilog-A. A thirteenth, 4.2.1.3, is the same story:
`02_numeric_conversions.va` runs that clause's printed examples under a 4.2.4
cite. (4.3's two-syntax-styles rule is likewise satisfied by
`10_standard_math_traditional.va` and `11_standard_math_system.va` under 4.3.1
cites, but 4.3 is counted below as an introduction.)

**4.2.6 is different and should not be "closed".** `29_case_equality.va`
rejects `===`/`!==` and deliberately does not cite 4.2.6, because 4.2.6 grants
those operators limited support in the analog block and 7.3.2 prints a legal
example of one. The reject is correct for the Verilog-A subset and cites C.5,
which is the clause that says so categorically. Adding a 4.2.6 cite here would
be claiming conformance to a rule this fixture contradicts.

Of the twenty-four uncovered sections, thirteen are the bookkeeping gap just
described, one is 4.2.6's deliberate abstention, and five (**4.1**, **4.2**,
**4.3**, **4.5**, **4.7**) are pure introductions that state no rule of their
own.

That leaves five clauses with genuinely nothing behind them: **4.2.1.2**
(integer-to-real conversion, whose content is the x/z error case and needs a
four-state value system VerA does not have), **4.5.2** (tolerances and
simulator-introduced unknowns), **4.5.14** (Table 4-20's
constant-versus-dynamic argument split — no fixture asserts that a dynamic
expression in a constant slot is refused), **4.6.2** (`analysis("nodeset")`,
and dc truth across a sweep rather than at a single point), and **4.6.4.5**
(the diode noise model: `25_limexp.va` has the diode without the noise,
`27_noise_sources.va` the noise without the diode). Only the first is blocked
on an unimplemented feature; the other four could be written today.

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
