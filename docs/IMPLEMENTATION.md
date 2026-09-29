# Implementation-defined choices and resource limits

This is the list `docs/ROADMAP.md` §1 E asks for and `CLAUSE-AUDIT.md` §5
defines: every choice the LRM leaves to the tool, what VerA picks and the
fixture that pins it; every engine limit, the diagnostic that fires when a
design crosses it and the fixture that crosses it; and the limits that still
fail badly, with enough detail to fix each one.

Fixture paths are relative to `tests/fixtures/`. "AMS" clauses are the
Verilog-AMS LRM; "1364" clauses are IEEE 1364-2005.

## 1. Implementation-defined choices

A fixture here tests VerA's choice, not the clause. A tool that chooses
differently also conforms.

| Clause | What the LRM leaves open | VerA's choice | Code | Fixture |
|---|---|---|---|---|
| AMS 2.7 | an error for an octal escape above `\377` is optional | accepted, low 8 bits kept, no diagnostic | `lib/frontend/lexer.zig:532-539` | `ch02_lexical/octal_escape_above_377_keeps_low_byte.va` |
| AMS 2.8 | the identifier length limit, at least 1024 | no limit; a long or escaped module name gets a hashed file stem for its build files | `src/main.zig` `fileStem` | `ch02_lexical/28_identifier_1024_chars.va`, `ch02_lexical/identifier_1024_char_module_name.va` |
| AMS 2.9 | vendor attributes | `vera_lte`, `vera_interp`, `vera_nodiff` (AGENTS.md §6); every other attribute is parsed and ignored | `lib/ir/lower/stmt.zig:57-76` | `ch05_analog_behavior/charge_sites_lte_attribute.va`, `ch04_expressions/absdelay_vera_interp_quadratic.va`, `ch04_expressions/ddx_vera_nodiff_assignment.va`, and their `reject_*` neighbours |
| AMS 4.5.4, 4.5.5 | `idt(x)` and `idtmod(x)` start at "c ... as determined by the simulator" | c = 0 | `lib/ir/lower/analog_op.zig:198-209` | `exhaustive/062_idt_integral.va`, `ch04_expressions/idtmod_one_argument_starts_at_zero.va` |
| AMS 4.5.5 | where `idtmod` integrates | inside the device, wrapping each accepted step | `lib/backend/codegen/kernel_text.zig:434` | `ch04_expressions/17_idtmod.va`, `ch04_expressions/a04_08_idtmod_offset_window_negative_integrand.va` |
| AMS 4.5.7 | interpolation between stored points of `absdelay` | linear by default; `(* vera_interp = 2 *)` gives quadratic | `lib/backend/codegen/kernel_text.zig:685,769` | `ch04_expressions/absdelay_vera_interp_linear.va`, `absdelay_vera_interp_quadratic.va` |
| AMS 4.6.1 | analysis names beyond Table 4-21 | none: any other name is false | `lib/backend/codegen/call.zig` `analysis` | `ch04_expressions/143_analysis_transient.va` |
| AMS 4.6.3 | the small-signal analysis name | `"ac"` | `lib/ir/lower/contrib.zig:1320` | `ch04_expressions/a06_ac_stim_ac_analysis.va` |
| AMS 5.10.3.1 | the `time_tol` of a `.v` contract device's A2D bridge (7.8 supplies no connect module) | card `ttol`, by default min(trise, tfall)/50; only a step where some process wakes is held to it | `src/sim/rt/device.zig` `ttol` | `tests/vdev_host.zig`, "v_edge and v_any" |
| AMS 5.10.3.1, 5.10.3.3 | `cross`/`above` tolerances and `timer` time_tol when the tool sets them | the fixed-grid testbench (`--run`, `--emit-exe`, no discrete half) inserts no timepoint: the event fires at the first `//! time` point past its time (W0750); a `//! time` grid with no `//! analysis` line is `tran` | `lib/backend/tb/runner.zig` `warnGridEvents`, `lib/backend/tb/directive.zig` | `ch05_analog_behavior/event_cross_fires_on_a_time_grid.va` |
| AMS 7.4.4.2 | discipline resolution mode | basic only | `lib/ir/elaborate/resolve.zig:128` | `ch07_mixed_signal/lrm_7_4_4_1.va` |
| AMS 9.5.7, 1364 17.2.7 | `$ferror` codes | C errno values (2, 5, 9, 13, 21, 22, 24, 28); fixtures assert only nonzero | `lib/backend/file_kernels.zig:216` | `ch09_system_tasks/053_ferror.va`, `write_mode_path_65_fails_open.va` |
| AMS 9.7.2 | what `$stop` does in a batch run | prints and exits 0 | `lib/backend/cg_display.zig:247` | `ch09_system_tasks/174_stop_terminates.va` |
| AMS 9.13.1 | the seed of a seedless analog `$random` | one per call site, `1 + 7919·k` | `lib/backend/codegen/file.zig:751` | `ch09_system_tasks/115_random_no_seed.va` (width only) |
| AMS 9.15 | which `$simparam` names exist ("There is no fixed list of simulation parameters") | Table 9-27's `gmin` (1e-12), `tnom`, `scale`, `shrink` and `sourceScaleFactor` (1), `iteration`, and `timeUnit`/`timePrecision` when a `` `timescale `` is given; beyond the table, SPICE's `reltol`, `abstol` and `vntol`. `tnom` and the three tolerances are host-written `Model` fields (`nom_temp__`, `reltol__`, `abstol__`, `vntol__`) defaulting to 27, 1e-3, 1e-12 and 1e-6; any other name without a fallback is E0811 | `lib/ir/lower/sysfunc.zig` `simparamValueIn`, `host_simparams` | `ch09_system_tasks/simparam_newton_tolerances_host_written.va`, `simparam_spice_option_not_known_rejected.va`, `147_simparam_unknown_no_fallback_rejected.va`, `exhaustive/120_environment.va` |
| AMS 9.17.3 | the `$limit` built-ins | `pnjlim`, `pnjlimds`, `fetlim`, `fetlimds`, `limvds`, `steplim`; any other name, or a bare `$limit(x)`, returns the probe | `lib/backend/codegen/plan/limit.zig:108-153` | `annex_e_spice/limit_pnj.va`, `limit_fet.va`, `limit_vds.va`, `limit_pnjlimds_bulk_rung.va`, `ch09_system_tasks/limit_steplim_internal_node_honoured.va`, `227_limit_unknown_algorithm_returns_probe.va` |
| AMS 9.17.3 | arguments past the algorithm's own | an optional frame sign, then an optional seed; more declines the site (W0853) | `lib/backend/codegen/plan/limit.zig:257-290` | `ch09_system_tasks/231_limit_polarity_sign_argument_honoured.va`, `230_limit_too_few_arguments_returns_probe.va`, `limit_too_many_arguments_returns_probe.va` |
| AMS 9.17.3 | the starting value of a limited branch (SPICE MODEINITJCT) | seeds solved into node values from a 0 V root (ground, else lowest port, else lowest net); an unseeded pnjlim leg starts at vcrit; fetlimds vgd and pnjlimds vbd legs are never seeded; a seed reading the solution is E0527, one the tree cannot take W0854 | `lib/backend/codegen/plan/limit.zig:332-460` | `annex_e_spice/limit_seed_mos1_initjct.va`, `limit_seed_bsim3_pmos_initjct.va`, `limit_seed_explicit_beats_default.va`, `reject_limit_seed_reads_solution.va` |
| AMS 12.36 | the number of `vpiRejectTransientStep` | 730 | `src/vpi/vpi_user.h:786` | `ch12_vpi_routines/p03_12_sim_control_reject_step.c` |
| AMS E.1, E.2 | the SPICE flavour and primitive behaviour | `.MODEL` and `.SUBCKT` cards only; primitives per each `primitive_*.va` header | `lib/frontend/spice_cards.zig` | `annex_e_spice/spice_model.va`, `spice_subcircuit.va`, `primitive_*.va` |
| AMS 2.8.3 | `$` names VerA uses internally | `$held_int`, `$held_real`, `$idx`, `$limit$old`, `$str$cat`, the `$rng$` family and the others after `$held_int` in `Callee` are reserved (E1014) | `lib/ir/callee.zig` `synthetic` | `ch09_system_tasks/reserved_system_function_name_rejected.va` |
| 1364 8.1.2 | the UDP input limit, at least 9 sequential and 10 combinational | 64 inputs for both (E1017) | `lib/frontend/parser/source.zig` `max_udp_inputs` | `ieee1364/08_udp/b_8_1_2_input_minimums.v`, `b_8_1_2_sequential_64_inputs.v`, `b_8_1_2_udp_more_than_64_inputs_rejected.v` |
| 1364 11.4.2 | the order of active events | processes start in source order from a FIFO queue; woken processes resume in the order they suspended; the interpreter and native code agree | `src/sim/scheduler.zig:155`, `src/sim/digital/exec.zig:835` | `ieee1364/11_scheduling/audit_sched_fork_arm_chain_order.v`, `audit_sched_fork_arm_wake_order.v`, `audit_sched_node_wake_order.v` (no clause cite) |
| 1364 13.4.4 | which of several configs configures the design | the config no other config references | not implemented | `ieee1364/13_configuration/b_13_3_2_hierarchical_config.v` (xfail) |
| 1364 17.2.4.1 | how many characters `$ungetc` can push back | 16 per descriptor; the 17th returns EOF | `lib/backend/file_kernels.zig:74` | `ieee1364/17_system_tasks/b_17_2_4_1_ungetc_pushback_limit.v` |
| 1364 17.2.1, 27.25 | which bit an mcd `$fopen` returns | 1 << k for the lowest free slot k from 1; under a VPI application, the lowest free channel from 4, one table with `vpi_mcd_open` (channels 2 and 3 are AMS 12.26's stderr and log) | `lib/backend/file_kernels.zig` `zFOpen`, `src/vpi/print.zig` `share` | `ieee_pli/b_27_mcd.c` |
| 1364 17.9.1 | the stream of a seedless `$random` | one hidden seed per run, starting at 0 | `src/sim/digital/root.zig:425` | `ieee1364/17_system_tasks/b_17_9_1_seedless_random_starts_at_seed_0.v` |
| 1364 19.8 | time unit and precision with no `` `timescale `` | 1 s / 1 s | `src/sim/digital/root.zig:2002` | `ieee1364/19_compiler_directives/b_19_8_no_timescale_is_1s_1s.v` |
| none (CLI) | `--state=auto` | runs 4-state until a time step starts with no live x or z, then 2-state; an x or z stored later reruns the design 4-state | `src/sim/rt/root.zig:106-130` | `ieee1364/11_scheduling/auto_state_two.v`, `auto_state_rerun.v`, `auto_state_never_written.v` |
| none (host ABI) | numeric parameter bindings carry a value without HDL type/width metadata | `$clog2` retains the final elaborated declaration's operand width and signedness for host bindings; HDL instance overrides supply their own before code generation; declared `integer` remains signed 32 bits | `lib/ir/lower/constfold.zig` `clog2Width`, `clog2Signed` | `ch09_system_tasks/clog2_inferred_parameter_width.va`, `clog2_nested_contexts.va` |

## 2. Resource limits

Each limit is stated here and fails with a named diagnostic. A run-time
limit ends the run with exit status 1; the LRM gives none of these a
truncation rule, so a shorter answer would be a wrong one.

| Limit | Value | Diagnostic | Code | Fixture |
|---|---|---|---|---|
| parser nesting, and binary operators in one chain | 1024 levels | E0241 | `lib/frontend/parser.zig:20` | `annex_a_syntax/nesting_past_the_parser_limit_rejected.va`, `sum_chain_past_the_parser_limit_rejected.va`, `long_sum_under_the_nesting_limit.va` |
| macro expansion depth | 128 | E0119 | `lib/frontend/preprocessor.zig:77` | `ch10_directives/macro_expansion_past_128_rejected.va` |
| `` `include `` depth | 32 | E0125 | `lib/frontend/preprocessor.zig:76` | `ch10_directives/include_cycle_rejected.va` |
| real literal length | 512 bytes | E0134 | `lib/frontend/lexer.zig:484` | `ch02_lexical/real_literal_over_512_bytes_rejected.va` |
| `` `include `` file, `$table_model` and `noise_table` data file | 16 MiB | E1013 | `lib/frontend/preprocessor.zig:79`, `lib/ir/lower/table_model.zig:240` | `ch10_directives/include_file_over_16mib_rejected.va`, `ch09_system_tasks/table_model_file_over_16mib_rejected.va` |
| source file and `--spice` netlist | 64 MiB | E1013 | `src/main.zig` `max_source_bytes` | `build.zig`: `vera --lint /dev/zero`, and `/dev/zero` as the `--spice` netlist, under `zig build test` |
| instance tree | 64 nested instances | E1018 | `lib/ir/elaborate.zig:40` | `ch06_hierarchy/instance_tree_64_levels.va`, `instance_tree_deeper_than_64_rejected.va` |
| nets, ports, branch flows and operator states in one module; one vector range | 65535 | E1015 | `lib/ir/lower/node.zig` `max_nodes` | `ch03_data_types/vector_net_over_65535_elements_rejected.va`, `nets_over_65535_rows_rejected.va` |
| analog-context array or assignment pattern | 2^20 elements | E1016 | `lib/ir/lower/param.zig` `max_cells` | `ch03_data_types/array_over_2_20_elements_rejected.va` |
| loop generate unrolling | 4096 iterations | E0420 | `lib/ir/lower/control.zig:536` | `ch06_hierarchy/generate_nonterminating_rejected.va` |
| solver unknowns | 256 | E1003 | `lib/backend/codegen/file.zig:308` | `ch06_hierarchy/vector_port_unknown_ceiling_rejected.va` |
| `.v` contract device pins (one per top-module port bit) | 256 | E1103, "more than 256 pins" | `src/sim/digital/emit.zig` `deviceRoot` | `build.zig`: `vera --emit-zig tests/vdev/v_pins.v` (257 pins) under `zig build test`; `tests/vdev_host.zig` runs the wide counter (`v_wide`) across packed-plane word boundaries |
| conversions in one display or format call | 32 | E1010 | `lib/backend/cg_display.zig:137` | `ch09_system_tasks/sformat_32_conversions.va`, `sformat_33_conversions_rejected.va` |
| text of one format call, string concatenation, field width or precision | 4096 bytes | E1011 | `lib/backend/str_kernels.zig:767`, `lib/backend/cg_display.zig:41` | `ch09_system_tasks/string_concat_overrun_is_fatal.va`, `sformat_field_width_over_4096_rejected.va` |
| number literal size | 2^24 bits | E1019 | `lib/frontend/integer.zig` `max_width` | `ieee1364/03_lexical_conventions/b_3_5_1_literal_size_65536.v`, `b_3_5_1_literal_size_over_2_24_rejected.v` |
| analog number literal carrier | 64 bits; wider literals require an exact signed value in the i64 carrier | E0130 | `lib/frontend/integer.zig` `asExactInt` | `ch09_system_tasks/reject_clog2_wide_unsigned_carrier.va`; legal neighbour `clog2_unsigned_width.va` |
| analog `$clog2` expression carrier | arithmetic, unary negation and shifts retain at most 32 bits per intermediate; bitwise/conditional/comparison contexts retain at most 64 bits; above 64 bits only exact wide literals and parameter aliases preserving their width retain proven high bits | E0893 | `lib/frontend/constfold.zig` `intPlan`, `lib/ir/lower/constfold.zig` `clog2WideCarrier` | `ch09_system_tasks/reject_clog2_wide_arithmetic.va`, `reject_clog2_wide_arithmetic_default.va`, `reject_clog2_wide_widening.va`; legal neighbours `clog2_nested_contexts.va`, `clog2_unsigned_width.va` |
| a constant string replication | 4096 bytes | E1011 | `lib/ir/lower/expr.zig:344` | `ch03_data_types/string_replication_4096_bytes.va`, `string_replication_over_4096_bytes_rejected.va` |
| one `$fgets` line, one `$fscanf` look-ahead | 4096 bytes | E1011 | `lib/backend/file_kernels.zig:68,137` | `ch09_system_tasks/fgets_line_over_4096_is_fatal.va`, `fscanf_window_over_4096_is_fatal.va`, `s01_13_long_record_is_not_truncated.va` |
| open file channels | 30 | `$fopen` returns 0, `$ferror` 24 (§9.5.1) | `lib/backend/file_kernels.zig:88` | `ch09_system_tasks/222_mcd_channels_exhausted_at_bit_31.va`, `224_two_instances_hold_distinct_channels.va` |
| distinct paths opened for writing in one run | 64 | `$fopen` returns 0, `$ferror` 24 (§9.5.1) | `lib/backend/file_kernels.zig:108` | `ch09_system_tasks/write_mode_path_65_fails_open.va` |
| `absdelay` history | 1024 samples | E1012 | `lib/backend/codegen.zig:596` (`hist_len`) | `ch04_expressions/absdelay_history_underrun_is_fatal.va`, `a04_05_absdelay_history_beyond_capacity.va` |
| random distribution count | 1..2147483647, integral | the RNG diagnostics | `lib/backend/rng_kernels.zig:78` | `ch09_system_tasks/189_rng_*_rejected.va` |
| UDP inputs | 64 | E1017 | `lib/frontend/parser/source.zig` | `ieee1364/08_udp/b_8_1_2_udp_more_than_64_inputs_rejected.v` |
| digital: `$readmemb`/`$readmemh` file | 4 MiB | E1100, naming the bound | `src/sim/digital/display.zig:273` | `ieee1364/17_system_tasks/b_17_2_9_readmem_file_over_4mib_rejected.v` |
| digital: field width or precision | 4096 | E1011 | `src/sim/digital/display.zig` `max_field` | `ieee1364/17_system_tasks/b_17_1_1_2_real_precision_100.v`, `b_17_1_1_2_field_width_over_4096_rejected.v` |
| digital: `%d` of a known value | 64 bits | E1100 | `src/sim/digital/display.zig:588` | `ieee1364/17_system_tasks/b_17_1_1_4_decimal_over_64_bits_rejected.v` |
| digital: expression and statement depth | 256 levels | E1100 | `src/sim/digital/compile.zig:511,803` | `ieee1364/05_expressions/b_5_expression_deeper_than_256_rejected.v` |
| digital: hierarchy depth | 64 levels | E1100 | `src/sim/digital/root.zig:954` | `ieee1364/12_hierarchy/b_12_hierarchy_deeper_than_64_rejected.v` |
| digital: loop generate | 65536 iterations | E1100 | `src/sim/digital/root.zig:1465` | `ieee1364/12_hierarchy/b_12_generate_past_65536_iterations_rejected.v` |
| digital: nested task and function activations | 1024, or 4 MiB of stack | E1100 | `src/sim/digital/exec.zig:1433` (`max_sync_stack`) | `ieee1364/10_tasks_functions/b_10_4_recursion_past_the_stack_bound_rejected.v` |
| digital: array dimensions | 16 | E1100 | `src/sim/digital/root.zig:1766` (`declareArray`) | `ieee1364/04_data_types/b_4_9_net_array_17_dimensions_rejected.v` |
| digital: events in one time step | 10,000,000, or `--event-budget=N` | E1100 | `src/sim/digital/root.zig:186` | `ieee1364/11_scheduling/b_11_zero_delay_loop_rejected.v` (at a budget of 1000: the default takes minutes to reach) |
| testbench `//! sweep` product | 4096 points | a `//!` directive error | `lib/backend/tb.zig:259` | none (harness input, not source) |
| VPI derivative handles; analog value strings | 64; 64 bytes | `vpiNoMem`, `vpiBadFormat` | `src/vpi/analog.zig:414`, `src/vpi/root.zig:2223` | none |

## 3. Unspecified behaviour

`CLAUSE-AUDIT.md` §5.5: no test asserts one outcome where the LRM permits
several. The `unspecified` rows in `ieee1364/CLAUSES.tsv` are 5.1.4, 11.4.2,
11.5, 12.3.10.1 and 12.3.10.2. Their fixtures assert membership in the
permitted set (`ieee1364/11_scheduling/audit_sched_allowed_active_race.v`) or
choose inputs where every permitted outcome agrees
(`ieee1364/12_hierarchy/b_12_3_10_net_type_warning.v`). The three
`audit_sched_*_order.v` fixtures pin VerA's documented order (§1 above) and
cite no clause. The `$ferror` fixtures assert only a nonzero code.

## 4. Open defects

None. Every limit above fails loudly, and these are gone rather than named:
the `absdelay` history counts steps in a u64; unit names count collisions in
a u32; digital `%b`/`%h`/`%s`/`%t`, `%m` and real conversions, `vpi_printf`'s
reals and the testbench's noise, AC-stimulus, charge-site and mixed-signal
name rows are written whole; a mixed-signal crossing the secant cannot close
is bisected to its `time_tol` (`src/sim/mixed.zig` `max_secant`).

The testbench's comptime loops over constant Jacobian entries and charge
stamps were measured, not changed: a 40-node resistor mesh (1600 constant
entries) and 200 charge sites build and run, and `tools/contract.zig` sets its
own evaluation quota where it computes those tables.
