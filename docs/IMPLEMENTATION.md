# Implementation-defined choices and resource limits

This is the list `CLAUSE-AUDIT.md` §5
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
| AMS 2.7 | an error for an octal escape above `\377` is optional | refused, E0148 (`docs/Vague_Decisions.md` VD-053) | `lib/frontend/lexer.zig` `badEscape`, `lib/frontend/parser/source.zig` `checkEscapes` | `ch02_lexical/octal_escape_above_377_rejected.va`; legal neighbour `octal_escape_377_largest_byte.va` |
| AMS 2.7, 1364 3.6.3 | a backslash before a character Table 2-2 does not list (`"\q"`) | the character is kept and the backslash dropped (`"\q"` is `"q"`), with warning W0149 (`docs/Vague_Decisions.md` VD-036) | `lib/frontend/lexer.zig` `stringContents`, `badEscape`; `lib/frontend/parser/source.zig` `checkEscapes` | `ch02_lexical/undefined_escape_keeps_character.va`; legal neighbour `08_string_escapes.va` (`//! nowarn`) |
| AMS 2.7, A.8.8; 1364 3.6 | a string byte above 0x7F (A.8.8 says `Any_ASCII_Characters`, 3.6 stores "8-bit ASCII values") | accepted with no diagnostic; each byte is one opaque 8-bit character, so UTF-8 `"°C"` is three characters, 0xC2B043 (`docs/Vague_Decisions.md` VD-014) | `lib/frontend/lexer.zig` `lexString`, `stringContents` (bytes copied as they are) | `ch02_lexical/string_bytes_above_7f.va` |
| AMS 10.1, 1364 19.5 | where a relative `` `include `` file name is looked for (19.5: "The filename can be a full or relative path name", and nothing more) | a full path is opened as written. A relative one is tried, first hit wins: (1) the directory of the file that holds the `` `include `` (the path it was opened by, `.` for a bare name; a unit that names no file, `<source>`, has none); (2) each `-I` directory in command-line order; (3) the built-in annex D `constants.vams` / `disciplines.vams` by basename. Not found: E0126, whose note lists the directories in that order (`docs/Vague_Decisions.md` VD-091) | `lib/frontend/pp/directive.zig` `readInclude`, `includerDir` | `ch10_directives/include_searches_the_including_files_directory.va` (nested include beside its includer; includer before `-I`), `include_including_dir_is_per_file_rejected.va` |
| AMS 2.8 | the identifier length limit, at least 1024 | no limit; a long or escaped module name gets a hashed file stem for its build files | `lib/backend/orchestrator.zig` `fileStem` | `ch02_lexical/28_identifier_1024_chars.va`, `ch02_lexical/identifier_1024_char_module_name.va` |
| AMS 2.9 | vendor attributes | `vera_lte`, `vera_interp`, `vera_nodiff`, `vera_timepoint`, `vera_scratch` (AGENTS.md §6) affect device behavior; `vera_interp = 2` (quadratic, `kernel_text.zig` `zAbsdelayQ`) departs from §4.5.7 when set, which requires linear interpolation (`ch04_expressions/absdelay_vera_interp_linear.va`); IEEE §26.6.42 VPI queries expose attribute names, constant values and parsed owners on modeled source objects | `lib/ir/lower/stmt.zig`, `src/vpi/attributes.zig` | `ch05_analog_behavior/charge_sites_lte_attribute.va`, `ch04_expressions/absdelay_vera_interp_quadratic.va`, `ch04_expressions/ddx_vera_nodiff_assignment.va`, `ch05_analog_behavior/vera_timepoint_cache.va`, their `reject_*` neighbours, and `ieee_pli/b_26_6_42_attributes.c` / `b_26_6_42_analog_attributes.c` |
| AMS 2.9 | `(* vera_timepoint *)`: what a per-timepoint cache is keyed on, and what drops it | one cache per statement in `Instance`, keyed on `$abstime`, `analysis()` and the two §5.10.2 step flags; filled by `eval`/`evalQ` when the statement ran on a stale cache; dropped by `initState`, `setupInstance`, `updateState` and `stateCtl` commit and revert. A statement may assign scalars, scalarized arrays and memory-backed arrays (held or not); only what a later statement reads is cached. Refused: E0529 (value), E0530 (construct inside), E0531 (reads a value an iteration moves), E0532 (in a loop, analog function or `analog initial`). A device with one declares `mutable_eval` and drops `batch_ok` | `lib/ir/lower/stmt.zig` `lowerTimepoint`, `lib/backend/codegen/plan/setup.zig` `timepointVarying`, `lib/backend/codegen/instance.zig` `emitTpHelpers` | `ch05_analog_behavior/vera_timepoint_cache.va`, `reject_vera_timepoint_parameter.va`, `reject_vera_timepoint_probe.va`, `reject_vera_timepoint_contribution.va`, `reject_vera_timepoint_operator.va`, `reject_vera_timepoint_event.va`, `reject_vera_timepoint_reads_iterate.va`, `reject_vera_timepoint_in_loop.va` |
| AMS 2.9 | `(* vera_scratch *)` on a variable declaration: what it starts each evaluation at, and where it is refused | never held (no `held_vars` row, no `Instance` field, no copy in `eval`/`stateCtl`): every evaluation, and every entry to a named block for that block's locals, starts it at its declaration's initializer, the §3.2 zero when there is none. On a string variable it drops the §5.10 hold too. Refused: E0534 (value does not fold without the card), E0535 (on a parameter, net, genvar or statement), E0536 (an `analog initial` or `@(...)` body assigns it and a read may see that value before the same evaluation assigns it again: §5.2.1/§5.10 values exist to be read on other evaluations), E0537 (an `initial` or `always` block or a task assigns it: §7.2.2 makes it digital-owned, and the digital kernel, not an analog evaluation, keeps its value). `= "uninit"`: a memory-backed (runtime-indexed) array starts each evaluation with NO store; the author promises every element is written before it is read in that evaluation, and **a read-before-write is the author's bug**: under runtime safety (Debug, ReleaseSafe) the array is filled with NaN in the value and every derivative lane (`minInt(i64)` for an integer array), so it reads NaN; in ReleaseFast/ReleaseSmall nothing is stored and the value is unspecified but stable, never illegal behaviour: after the `undefined` declaration an empty `asm volatile ("" : : [p] "r" (&a) : .{ .memory = true })` (no instructions; accepted by nvptx64 and amdgcn too) may have written the array, so LLVM must treat its contents as defined. It costs the array's SROA: 201 Ir/eval against 116 without it and 233 for the zero start (4-op tape, `st[0:63]`, 8 lanes). A scalar or scalarized array keeps the zero start. Any other string: E0538; an initializer with `"uninit"`: E0539 | `lib/ir/lower/var.zig` `scratchOn`, `scratchMode`, `checkScratchOwners`, `refuseDigitalScratch`, `markHeldVars` (`State.carried`); `lib/backend/codegen/render.zig` `emitArrayStmt` | `ch03_data_types/vera_scratch_starts_each_evaluation.va`, `vera_scratch_uninit_tape.va`, `vera_scratch_uninit_reads_nan_when_safe.va`, `reject_vera_scratch_unknown_string.va`, `reject_vera_scratch_uninit_initializer.va`, `reject_vera_scratch_parameter_value.va`, `reject_vera_scratch_on_parameter.va`, `reject_vera_scratch_on_net.va`, `reject_vera_scratch_on_genvar.va`, `reject_vera_scratch_event_value.va`, `reject_vera_scratch_analog_initial.va`, `ch07_mixed_signal/reject_vera_scratch_digital_variable.va` |
| AMS 2.8.3 | `$vera_reject_step(t_retry)`, a VerA system task | in a transient, the accepted step whose solution called it with `t_retry < $abstime` is rejected through `contract.UpdateResult.request_reject_at`; several calls in one evaluation: the earliest wins; ignored in a static solve; no `acceptQ` is emitted, since it cannot carry the request; the analog testbench retries at `t_retry` with the forced unknowns held at the rejected time's values, and the mixed and VPI runners refuse a request; in `analog initial` or an analog function, E0533 | `lib/ir/lower/systask.zig` `lowerKernelCtl`, `lib/backend/codegen/state.zig` `emitStateMachine`, `lib/backend/tb/runner_text.zig` `retry` | `ch05_analog_behavior/vera_reject_step_retry.va`, `reject_vera_reject_step_analog_initial.va` |
| AMS 4.3.1 (Table 4-14) | the accuracy of `exp`, `ln`, `pow` (the table gives each a C equivalent and a domain, no accuracy; 4.3.2's Table 4-15 functions are unchanged) | faithful: max error ≤ 0.52 ulp (exp, ln) and ≤ 0.55 ulp (pow) against the exactly rounded result over every finite input, IEEE 754 special values, identical bits on every target; the only implementation (the previous compiler_rt/`std.math.pow` path and the GPU musl ports are gone). See "Host math" below | `tools/contract.zig` `gm` (`armExp`, `armLog`, `armPow`, `hexp`, `hlog`, `powV`) | `tools/contract.zig` tests "exp/log/pow stay within the documented bound of an f128 oracle", "... fold at comptime to the bits they run to", "armExp/armPow: the contract's special cases ..." |
| AMS 9.7.3 | what `$fatal`/`$error` do in a DEVICE (`--display=drop`), which cannot print or stop its host | the status channel: each call in the analog context (the analog block, `analog initial`, a `vera_timepoint` statement, an analog function) is a `contract.StatusSite` in `status_sites`, in source order. The first one an evaluation reaches, under its own guards, latches `Instance.vera_status__ = (severity << 24) \| (site + 1)` (severity 1 fatal, 2 error; `contract.statusCode`) and up to four numeric arguments after its format string in `vera_status_args__` (a string argument reads 0; `$fatal`'s finish_number is not one). The status is sticky: a later site changes nothing until `initState` or `setupInstance` clears it. While it is set, `eval`, `q` and `evalQ` return all-zero rows and charges (value and every derivative lane; checked before and after the core), and `updateState` returns `.ok` without touching the state; the device declares `mutable_eval`, drops `batch_ok` and emits no `acceptQ`. `contract.formatStatus` renders `<file>:<line>: fatal\|error: <message>`. `$warning`/`$info` stay dropped (W0850); the printing artifact prints all four and exits on `$fatal` as before. Additive: ABI 5 | `lib/ir/lower/systask.zig` `lowerStatus`, `lib/backend/codegen/instance.zig` `emitStatusHelpers`, `lib/backend/codegen/dispatch.zig`, `tools/contract.zig` `StatusSite`, `formatStatus` | `tests/status_host.zig` over `tests/fixtures/ch09_system_tasks/status_ops.va` (analog, `analog initial`, `vera_timepoint`, first-wins, the zero plane, `updateState`), `tests/status_gpu.zig` (NVPTX IR and AMDGCN object, under `zig build test`) |
| AMS 4.2.4 | how a required integer-modulus zero-divisor error is reported | a provably evaluated zero is E0601 at compile time; a runtime zero reports E0601 and exits 1 in the executable, and traps in a solver device without host I/O, including GPU targets | `lib/ir/proof/prover.zig`, `lib/backend/codegen/render.zig` `imodFn` | `ch04_expressions/111_modulus_by_zero_rejected.va`, `modulo_integer_dynamic_zero.va`, `modulo_integer_unused_zero.va`; legal neighbours `modulo_integer_dynamic.va`, `modulo_integer_short_circuit.va`, `modulo_integer_parameter.va` |
| AMS 4.5.4 | `idt(x)` with no `ic` starts at "c ... as determined by the simulator" | argument reads an unknown: the static solve forces it to zero (c from the loop); otherwise c = 0. (`idtmod`'s c = 0 is not listed: §4.5.5's prose requires it.) | `lib/ir/lower/analog_op.zig` `opIdt`, `readsUnknown` | `exhaustive/062_idt_integral.va`, `ch04_expressions/idt_no_ic_dc_feedback.va` |
| AMS 4.5.5 | where `idtmod` integrates | inside the device, wrapping each accepted step | `lib/backend/codegen/kernel_text.zig` `zIdtmod` | `ch04_expressions/17_idtmod.va`, `ch04_expressions/a04_08_idtmod_offset_window_negative_integrand.va` |
| AMS 4.5.11 | the DC value of a `laplace_*` filter whose H(s) has a pole at s = 0 (the clause gives H(s) and no DC rule) | 0, the integrator state starting at 0 as for `idt` above; a power of s common to both sides cancels first, so `s/(s + s²)` is 1; a transient starts from the static point with every past sample of each section equal to it | `lib/backend/kernels/filter_kernels.zig` `zH0`, `zLaplaceStep` | `ch04_expressions/laplace_nd_pole_at_origin.va` |
| AMS 4.5.11, 4.5.12 | a `*_zp`/`*_zd`/`*_np` root vector whose parts the model card sets (a parameter array), where "its conjugate shall also be present" cannot be checked at compile time | a vector whose imaginary parts all fold without the card, and whose card-set real parts pair by their text, keeps the compile-time pairing (one section per real root, one quadratic per conjugate pair). Otherwise its section structure is fixed at `(M + 1) / 2` real sections of degree ≤ 2, filled on every `__sec` read by `zRootSecs`: a root with imaginary part exactly 0 is real and real roots combine two at a time in vector order (a leftover one is a degree-1 section, the runtime degree trim runs it as one); a zero root is §4.5.11's `s` / §4.5.12's z⁻¹; a complex root a + jb pairs with the first unused root within 1e-9·\|a + jb\| of a − jb (`zroot_tol`). A complex root with no such partner makes every coefficient of the cascade NaN, so the filter's output is NaN in every analysis: never a different filter reported as this one. An odd-length root vector is E0540 at compile time | `lib/backend/cg_filters.zig` `filterSide`, `runtimeRoots`; `lib/backend/kernels/filter_kernels.zig` `zRootSecs` | `ch04_expressions/laplace_zp_parameter_roots_step.va`, `laplace_zp_parameter_roots_ac.va`, `laplace_np_parameter_roots_unpaired_is_nan.va`, `zi_np_parameter_roots_dc_gain.va`, `reject_4_5_11_1_laplace_zp_parameter_roots.va` |
| AMS 4.5.11 | how a `laplace_*` section is integrated in a transient (the clause gives H(s) only) | the trapezoidal rule (bilinear transform, s = (2/dt)(1 − z⁻¹)/(1 + z⁻¹)), realised for a proper section (numerator degree ≤ denominator degree, after common powers of s cancel) as the controllable canonical states of the monic denominator stepped in increment form, (I − (dt/2)A)Δx = (dt/2)(2(Ax + Bu_prev) + B(u − u_prev)), solved along the companion chain in O(degree). Mathematically the same discrete filter as direct form on the bilinear coefficients, which VerA used until 2026-10-01; numerically, a held input leaves a state with Ax + Bu = 0 where it is, so the steady output is H(0) to rounding. Direct form made the fixed point Σb/Σa, which is roundoff when a pole is slow against the step (Σa ~ (ω·dt)^degree of its terms): a degree-6 section with ω·dt = 1e-5 drifted 5.3e-7 off H(0) in 200 steps, and a fitted line with a 3 kHz pole settled 0.6% low at dt = 0.1 ns. The states are continuous-time, so a step size change needs no history rewrite. An improper section (s/1) keeps direct form I on its bilinear coefficients | `lib/backend/kernels/filter_kernels.zig` `zSsForm`, `zSsStep`, `zSsRest`, `zLaplace`, `zLaplaceStep` | `ch04_expressions/laplace_nd_slow_pole_holds_dc_gain.va`; the transient laplace fixtures (`a04_11_laplace_nd_ramp_response.va`, `23_laplace_filters.va`, ...) within their stated tolerances |
| AMS 4.6.1 | analysis names beyond Table 4-21 | none: any other name is false | `lib/backend/codegen/call.zig` `analysisMatch` | `ch04_expressions/143_analysis_transient.va` |
| AMS 4.6.3 | the small-signal analysis name | `"ac"` | `lib/ir/lower/contrib.zig` `acAnalysisName` | `ch04_expressions/a06_ac_stim_ac_analysis.va` |
| AMS 5.10.3.1 | the `time_tol` of a `.v` contract device's A2D bridge (7.8 supplies no connect module) | card `ttol`, by default min(trise, tfall)/50; only a step where some process wakes is held to it | `src/sim/rt/device.zig` `ttol` | `tests/vdev_host.zig`, "v_edge and v_any" |
| AMS 5.10.3.1, 5.10.3.3 | `cross`/`above` tolerances and `timer` time_tol when the tool sets them | the fixed-grid testbench (`--run`, `--emit-exe`, no discrete half) inserts no timepoint: the event fires at the first `//! time` point past its time (W0750); a `//! time` grid with no `//! analysis` line is `tran` | `lib/backend/tb/runner.zig` `warnGridEvents`, `lib/backend/tb/directive.zig` | `ch05_analog_behavior/event_cross_fires_on_a_time_grid.va` |
| AMS 5.10.3.4 | absent or zero `absdelta` tolerances and interpolation within the event window | `time_tol` defaults to 1 ps and is at least the digital precision; `expr_tol` defaults to 1e-12 in expression units; delta events use the interpolated delta crossing when eligible, otherwise the first time outside the time-tolerance exclusion; significant reversals use the observed point | `src/sim/mixed.zig` `absdeltaArgs`, `nextAbsdelta` | `ch07_mixed_signal/absdelta_runtime_default_tolerances.va`, `absdelta_runtime_time_precision.va`, `absdelta_runtime_time_tol.va`, `absdelta_runtime_reversal.va` |
| AMS 7.4.4.2 | discipline resolution mode | basic only | `lib/ir/elaborate/resolve.zig` `resolveDiscipline` | `ch07_mixed_signal/lrm_7_4_4_1.va` |
| AMS 9.5.7, 1364 17.2.7 | `$ferror` codes | C errno values (2, 5, 9, 13, 21, 22, 24, 28); fixtures assert only nonzero | `lib/backend/kernels/file_kernels.zig` `zfErrno` | `ch09_system_tasks/053_ferror.va`, `write_mode_path_65_fails_open.va` |
| AMS 9.7.2 | what `$stop` does in a batch run | prints and exits 0 | `lib/backend/cg_display.zig` `emitSimCtl` | `ch09_system_tasks/174_stop_terminates.va` |
| AMS 9.13.1 | the seed of an omitted-seed analog `$random` or `$arandom` | one per omitted-seed site, `1 + 7919·k`; `k` counts all non-variable-seed sites in lowering order, including constant/parameter sites | `lib/ir/lower/random.zig` `lowerRandom` | `tests/revert_host.zig` (numbering/trajectory); `ch09_system_tasks/115_random_no_seed.va` (width) |
| AMS 9.15 | which `$simparam` names exist ("There is no fixed list of simulation parameters") | Table 9-27's `gmin` (1e-12), `tnom`, `scale`, `shrink` and `sourceScaleFactor` (1), `iteration`, and `timeUnit`/`timePrecision` when a `` `timescale `` is given; beyond the table, SPICE's `reltol`, `abstol` and `vntol`, and `dt`: the host's `SimState.dt` unchanged (the step since the last accepted point, 0 in a static solve; no derivative, never hoisted into `setup`, readable inside `vera_timepoint`). `tnom`, the three tolerances, `gmin` and `sourceScaleFactor` are host-written `Model` fields (`nom_temp__`, `reltol__`, `abstol__`, `vntol__`, `gmin__`, `source_scale__`) defaulting to 27, 1e-3, 1e-12, 1e-6, 1e-12 and 1, since a host steps gmin and the source factor during a run (`docs/Vague_Decisions.md` VD-072); `scale` and `shrink` are 1, because geometry scaling is applied when the card is built; any other name without a fallback is E0811; `$simparam$str` knows Table 9-28's six names and refuses any other literal with E0811 (it has no fallback), and its `"cwd"` and `"analysis_name"` are host-written `Instance` fields (`cwd`, `analysis_name`), which the testbench fills from its working directory and `//! analysis <kind> [<name>]` | `lib/ir/lower/sysfunc.zig` `simparamValueIn`, `host_simparams`, `simparam_str_names` | `ch09_system_tasks/simparam_newton_tolerances_host_written.va`, `simparam_gmin_source_scale_host_written.va`, `simparam_spice_option_not_known_rejected.va`, `147_simparam_unknown_no_fallback_rejected.va`, `simparam_dt_is_the_host_step.va`, `exhaustive/120_environment.va`, `simparam_str_cwd_and_analysis_name.va`, `simparam_str_unknown_name_rejected.va` |
| AMS 9.17.3 | the `$limit` built-ins | `pnjlim`, `pnjlimds`, `fetlim`, `fetlimds`, `limvds`, `steplim`; any other name, or a bare `$limit(x)`, returns the probe | `lib/backend/codegen/plan/limit.zig` `Alg` | `annex_e_spice/limit_pnj.va`, `limit_fet.va`, `limit_vds.va`, `limit_pnjlimds_bulk_rung.va`, `ch09_system_tasks/limit_steplim_internal_node_honoured.va`, `227_limit_unknown_algorithm_returns_probe.va` |
| AMS 9.17.3 | arguments past the algorithm's own | an optional frame sign, then an optional seed; more declines the site (W0853) | `lib/backend/codegen/plan/limit.zig` `plan` | `ch09_system_tasks/231_limit_polarity_sign_argument_honoured.va`, `230_limit_too_few_arguments_returns_probe.va`, `limit_too_many_arguments_returns_probe.va` |
| AMS 9.17.3 | the starting value of a limited branch (SPICE MODEINITJCT) | seeds solved into node values from a 0 V root (ground, else lowest port, else lowest net); an unseeded pnjlim leg starts at vcrit; fetlimds vgd and pnjlimds vbd legs are never seeded; a seed reading the solution is E0527, one the tree cannot take W0854 | `lib/backend/codegen/plan/limit.zig` `planSeed` | `annex_e_spice/limit_seed_mos1_initjct.va`, `limit_seed_bsim3_pmos_initjct.va`, `limit_seed_explicit_beats_default.va`, `reject_limit_seed_reads_solution.va` |
| AMS 9.20 | a whole-vector analog_net_reference: the clause admits one, but its validity rules make the target "a scalar continuous node or a scalar element of a continuous vector node" and the alias "the same circuit matrix position" | every element is aliased to the one target node, status 1; a vector target string violates the scalar rule, status 0, and the vector stays local | `lib/ir/lower/hier_name.zig` `checkAliasCall`, `aliasVector` | `ch09_system_tasks/node_alias_whole_vector_reference.va`; bit select refused, `143_node_alias_bit_select_rejected.va` |
| AMS 12.36 | the number of `vpiRejectTransientStep` | 730 | `src/vpi/vpi_user.h` `vpiRejectTransientStep` | `ch12_vpi_routines/p03_12_sim_control_reject_step.c` |
| AMS E.1, E.2 | the SPICE flavour and primitive behaviour | `.MODEL` and `.SUBCKT` cards only; primitives per each `primitive_*.va` header. A `.MODEL` whose type is no Table E.1 row (`sw`, `ltra`, ...) declares nothing, and an instance of it is E0952 (E.1.2's unsupported primitive) | `lib/frontend/spice_cards.zig`; `lib/ir/elaborate/names.zig` `unknownModule` | `annex_e_spice/spice_model.va`, `spice_subcircuit.va`, `primitive_*.va`, `spice_unsupported_model_type_rejected.va`, `spice_supported_model_type_neighbour.va` |
| AMS E.3.3 | a warning when an HDL module or paramset shadows an always-available SPICE primitive is optional | no warning for primitive shadowing; W0951 for the required same-name model/subcircuit warning | `lib/ir/elaborate/names.zig` `warnSpiceShadows`, `findModule` | `annex_e_spice/spice_paramset_primitive_shadow.va`, `spice_module_shadow_warning.va`, `spice_paramset_shadow_warning.va`, `spice_shadow_case_neighbour.va`, `h04_10_verilog_module_wins_over_netlist_subckt.va` |
| AMS 2.8.3 | `$` names VerA uses internally | `$held_int`, `$held_real`, `$idx`, `$limit$old`, `$str$cat`, the `$rng$` family and the others after `$held_int` in `Callee` are reserved (E1014) | `lib/ir/callee.zig` `synthetic` | `ch09_system_tasks/reserved_system_function_name_rejected.va` |
| 1364 8.1.2 | the UDP input limit, at least 9 sequential and 10 combinational | 64 inputs for both (E1017) | `lib/frontend/parser/udp.zig` `max_udp_inputs` | `ieee1364/08_udp/b_8_1_2_input_minimums.v`, `b_8_1_2_sequential_64_inputs.v`, `b_8_1_2_udp_more_than_64_inputs_rejected.v` |
| 1364 11.4.2 | the order of active events | processes start in source order from a FIFO queue; woken processes resume in the order they suspended; the interpreter and native code agree | `src/sim/scheduler.zig` `Scheduler.next`, `src/sim/digital/waiters.zig` `wake` | `ieee1364/11_scheduling/audit_sched_fork_arm_chain_order.v`, `audit_sched_fork_arm_wake_order.v`, `audit_sched_node_wake_order.v` (no clause cite) |
| 1364 13.4.4 | which of several configs configures the design | the config no other config references | not implemented | `ieee1364/13_configuration/b_13_3_2_hierarchical_config.v` (xfail) |
| 1364 17.2.4.1 | how many characters `$ungetc` can push back | 16 per descriptor; the 17th returns EOF | `lib/backend/kernels/file_kernels.zig` `ZFSlot.back` | `ieee1364/17_system_tasks/b_17_2_4_1_ungetc_pushback_limit.v` |
| 1364 17.2.1, 27.25 | which bit an mcd `$fopen` returns | 1 << k for the lowest free slot k from 1; under a VPI application, the lowest free channel from 4, one table with `vpi_mcd_open` (channels 2 and 3 are AMS 12.26's stderr and log) | `lib/backend/kernels/file_kernels.zig` `zFOpen`, `src/vpi/print.zig` `share` | `ieee_pli/b_27_mcd.c` |
| 1364 17.9.1 | the stream of a seedless `$random` | one hidden seed per run, starting at 0 | `src/sim/digital/root.zig` `Run.random_seed` | `ieee1364/17_system_tasks/b_17_9_1_seedless_random_starts_at_seed_0.v` |
| 1364 19.8 | time unit and precision with no `` `timescale `` | 1 s / 1 s | `src/sim/digital/root.zig` `default_quantum` | `ieee1364/19_compiler_directives/b_19_8_no_timescale_is_1s_1s.v` |
| none (CLI) | `--state=auto` | runs 4-state until a time step starts with no live x or z, then 2-state; an x or z stored later reruns the design 4-state | `src/sim/rt/root.zig` `auto` | `ieee1364/11_scheduling/auto_state_two.v`, `auto_state_rerun.v`, `auto_state_never_written.v` |
| none (CLI) | debug information in a native artifact | a ReleaseFast/ReleaseSmall `--emit-so` (analog or `.v` device) and `--emit-exe`/`--run` are built `-fstrip`; `--debug-info` keeps DWARF. Debug and ReleaseSafe always keep it (their safety panics print stack traces). Stripping leaves the analog devices' `.text` identical and halves psp103's and bsim4va's build (`docs/measurements/codegen-levers-2026-09-30.md` lever 1) | `lib/backend/orchestrator.zig` `strip` | `lib/backend/orchestrator.zig` test "an optimized build strips unless debug information is asked for" |
| none (CLI) | how `--emit-so` builds a large device | an LLVM build of at least 768 KiB of device text runs one `zig build-obj` per `contract.DevicePart` (setup, state, eval) in parallel and links them; a `dyn` host with `exportDevicePart` exports each part's entry points from its own object, one without it gets `exportDevice` in the setup object. Smaller devices and the native backend build one object (below it, the split measured no gain for mos1 and a code-layout eval slowdown for txl) | `lib/backend/orchestrator.zig` `splits`, `split_min_bytes` | `lib/backend/orchestrator.zig` test "a split build links one object per part into a library that runs" |
| none (CLI) | how a large `setup` is emitted and built | a `setup` of at least 256 KiB of emitted text is emitted as `zSetup<k>` chunks of about that size (`setup_chunks.n`), its top-level statements cut where the relooper's shape allows (a labelled block whose `break`s are all in tail position is opened; a two-armed `if` whose arms jump only inside themselves becomes a stored condition guarding each arm statement), values crossing a cut kept in a scratch struct `setup` passes along. Every statement runs once, in order, on the same values: the roots are bit-identical. A split build compiles each chunk in its own object when the `dyn` host declares `SetupValue(D)`, the value scalar it passes `setup`; otherwise `setup` calls the chunks directly. No balanced cut (more than 3/4 in one chunk) keeps one function | `lib/backend/codegen/setup_chunk.zig` `chunk_bytes`; `lib/backend/orchestrator.zig` `pieceNames` | `lib/backend/codegen/setup_chunk.zig` test |
| none (CLI) | how `--emit-so` builds a `.v` device | an LLVM build links the digital engine's design-independent half (`src/sim/rt/engine.zig`: the event loop and the tick-boundary snapshot) as one object built once per engine sources, compiler, target, CPU and flags, in `vera-engine` under Zig's global cache directory (`ZIG_GLOBAL_CACHE_DIR`, `XDG_CACHE_HOME/zig`, `HOME/.cache/zig`; else the work directory's cache). The key is the compiler's own cache manifest; the object's symbols carry a hash of `State`'s layout and the root options, so a mismatched object fails to link. v_count 17.0 → 4.9 Gi, v_inv 22.2 → 5.1 Gi once the object exists (the first build also builds it, ≈16 Gi); the native backend compiles the whole engine (no gain measured) | `lib/backend/orchestrator.zig` `buildEngine`, `src/main.zig` `engineCache` | `lib/backend/orchestrator.zig` test "buildEngine reuses its object only while every key component is unchanged", `tests/vdev_so_host.zig` |
| none (host ABI) | numeric parameter bindings carry a value without HDL type/width metadata | a card value is an unsized integer (1364 3.5.1, 4.10.1): `$clog2` of a non-local parameter with no type or range, when the card sets it (`$param_given`), reads it as a signed 32-bit integer, or 64-bit when some such card value in the operand does not fit 32 bits; unset, the final elaborated declaration's width and signedness apply as before. A declared range or `integer` keeps its width under a card value; HDL instance overrides supply their own width before code generation (`docs/Vague_Decisions.md` VD-089). Ceiling: one set/unset and one fits-32 decision covers all such parameters of one operand | `lib/ir/lower/sysfunc.zig` `lowerClog2`, `hostSized`; `lib/ir/lower/constfold.zig` `hostSizedParam`, `clog2Width`, `clog2Signed` | `ch09_system_tasks/clog2_inferred_parameter_width.va`, `clog2_nested_contexts.va` |
| none (host ABI) | how a host supplies top-level geometric system parameters | a declared §3.4.7 alias supplies a real model-card slot, shared by additional aliases of the same system parameter; defaults are Table 9-29's identities and descendants retain the host dependency | `lib/ir/hier_param.zig`, `lib/ir/lower/param.zig` `aliasSystemParam` | `ch09_system_tasks/geometry_top_alias_host.va` |
| none (host ABI) | what a batch of several operating points (a family whose `V` is a vector of W points) returns when the device decides on a per-point value (a real comparison, a real→integer conversion, a `$limit`/`ddx`-stripped value, a pow with a varying exponent) | exact per point: bit for bit what a scalar family returns for that point alone, divergent batches included. The batch key is the `Model` row (card, temperature, setup cache, port mask) and the `SimState`; nothing else is shared. Each point has its own `Instance`: a device whose `eval` reads per-instance state as a value (a §5.10 held variable, a `$prev` path latch, `$mfactor`) declares `batch_inst` and reads it per point through the batch family's `instLane(T, w)` (`zInst`; an integer field is a lead-protocol decision, `zInstI`); every value computed from such a field is per point too (`Analysis.pointDep`), never folded through `.val()`. Per-instance state no point can carry that way (operator history, a held array, `$limit`'s previous value, plusargs, a host system function) drops `batch_ok`. `updateState`, `stateCtl`, `setupInstance` and `initState` have no batched form: the host calls them per instance. Such a device declares `batch_ok` and `batch_lead`, and its `eval`, `q` and `evalQ` run the lead protocol (`contract.LeadState`). The leader point's outcome steers every decision. Points that disagree are re-run under the next leader, and each point's result comes from a run it never diverged in. A divergent batch costs one run per distinct path, never a wrong value. A vector family without the protocol is a compile error (`zLeads`). `contract.region(D, x, model, inst, sim)` returns a `u16` hash of a point's decision outcomes. Equal decisions give equal signatures, so a batch of equal signatures runs once (a collision costs a re-run, never a wrong value). A scalar family's results are unchanged. Measured in `docs/measurements/batched-lead-2026-10-02.md` | `lib/backend/codegen/float/lanes.zig` `leadLanes`, `lib/backend/codegen/dispatch.zig` `writeLead`, `lib/backend/codegen/kernel_text.zig` `zCmp`, `zRoundI`, `zStrip`, `zPowL`, `zLeads`, `zInst`, `zInstI`, `lib/backend/codegen/float/lanes.zig` `instLanes`, `instPin`, `tools/contract.zig` `LeadState`, `leadMergeInto`, `region` | `tools/contract.zig` test "LeadState: ..."; the testbench's batch family (`lib/backend/tb/runner_text.zig` `laneCheck`) runs every `batch_ok` fixture at points 1e-3 apart, and every `batch_lead` fixture also at points 0.37 apart, each point on its own instance (every real and integer field moved apart), against scalar, bit for bit; `ch05_analog_behavior/batch_per_instance_state.va` (held real and integer, `$prev`, a nonlinear-capacitance latch) failed this before `batch_inst`; codegen test "a batch reads each point's own Instance, or the device is not batch_ok" |

### Host math: exp, ln, pow

A device's `exp`, `ln`/`log`-based and `pow` values come from the host's
scalar family (`contract.RefFamily`, the testbench's, a host's own), and
its scalar paths (`$limit`, `limexp`'s clamp) from `contract.gm`. VerA's
own families and `contract.gm` use, on every target (host, NVPTX, AMDGCN):

* `exp`: ARM optimized-routines' design (musl `pow.c` `exp_inline`,
  `exp_data.c`): 2^(k/128) table, degree-5 polynomial, exact scaling; plus
  1 + (x + x²/2) below |x| = 2^-28 and direct +0/+inf past the rounding
  thresholds. 
* `ln`: ARM's `log.c` (as Zig's compiler_rt carries it; identical results
  to the previous routine).
* `pow`: ARM's `pow.c`, double-double log then exp; replaces
  `std.math.pow`, whose error grew with |y| (20 ulp measured).

**Correct** here means, and each is checked:

1. Max error ≤ 0.52 ulp (exp, ln) and ≤ 0.55 ulp (pow) of the exactly
   rounded result, over every finite input (faithful rounding; LRM Tables
   4-14 sets no accuracy, so this is VerA's choice). Measured below
   against an f128 oracle; `zig build test` checks a fixed sample.
2. IEEE 754 / C99 Annex F special values: exp(±0) = 1, exp(+inf) = +inf,
   exp(−inf) = +0, +inf above ln(DBL_MAX), gradual underflow and +0 below
   −1075 ln 2; ln(±0) = −inf, ln(x < 0) = NaN, ln(+inf) = +inf, ln(1) = +0;
   pow's F.10.4.4 rows (pow(x, ±0) = 1, pow(1, y) = 1, odd/even integer
   exponents of negative and signed-zero bases, NaN for a negative base and
   non-integer exponent); NaN propagates.
3. Derivatives use the value returned: d exp = exp(x)·dx with the same
   exp(x), d ln = dx/x, d pow = c·p/x with the same p (`RefFamily`).
4. One implementation everywhere: no fma (a fused and an unfused build
   round differently; `@mulAdd` is a libcall on baseline x86-64), so host,
   NVPTX and AMDGCN give the same bits. NVPTX `sm_80` PTX of the three
   routines has no `fma`; AMDGCN `gfx90a` has `v_fma` only inside f64
   division's IEEE expansion (`docs/measurements/device-runtime-2026-10-01/gpu_probe.sh`). The comptime fold of the routines (target
   independent) equals their run on the host (`zig build test`). Cost of
   no-fma, measured: ln +2.4 and pow +4.3 ticks per call.
5. The `@Vector(n, f64)` form (`hexp`, `hlog`; the testbench's batch
   family) is the scalar's arithmetic lane for lane; a vector with a
   special lane takes the scalar call for every lane.

These are the only implementation: the previous host path (`@exp`/`@log`,
i.e. compiler_rt or a linked libc, and `std.math.pow`) and the GPU's musl
ports (`softExp`/`softLog`) were removed, so no flag reproduces the
pre-2026-10 bits. The table below is the record of what changed.

Measured 2026-10-01, i9-14900HX (AVX2, no AVX-512), f128 oracle,
200 000 samples per row; ticks are TSC ticks per call (scalar, throughput)
or per element of `@Vector(4, f64)`
(`docs/measurements/device-runtime-2026-10-01/mathtable.zig`):

| function, inputs | before (compiler_rt, std): max / mean ulp / ticks | glibc 2.42 (measurement only) | VerA now | VerA `@Vector(4)` ticks/elem |
|---|---|---|---|---|
| exp, x in [−745, 709] | 0.8811 / 0.2638 / 29.2 | 0.5034 / 0.2502 / 22.8 | 0.5054 / 0.2502 / 20.3 | 22.2 |
| exp, x in [−80, 45] (the compact models) | 0.8480 / 0.2638 / 24.8 | 0.5044 / 0.2499 / 9.1 | 0.5064 / 0.2499 / 9.1 | 4.1 |
| exp, \|x\| < 2^−28 (decay factors) | 0.5329 / 0.2194 / 5.1 | 0.5000 / 0.2194 / 13.1 | 0.5000 / 0.2194 / 8.9 | 7.4 |
| ln, x random bits in (0, inf) | 0.5000 / 0.2500 / 9.5 | 0.5000 / 0.2500 / 9.2 | 0.5000 / 0.2500 / 9.5 | 5.2 |
| ln, subnormal x | 0.5000 / 0.2506 / 116.6 | 0.5000 / 0.2506 / 115.7 | 0.5000 / 0.2506 / 120.2 | — |
| ln, x in [0.9, 1.1] | 0.5175 / 0.2493 / 15.5 | 0.5175 / 0.2493 / 16.5 | 0.5175 / 0.2493 / 15.9 | 17.5 |
| pow, x in [1e−3, 1e12], y in [−3, 18] | 20.34 / 1.7565 / 147.6 | 0.5054 / 0.2498 / 23.1 | 0.5058 / 0.2498 / 29.3 | — |
| pow, psp103's own (x, y) pairs | 8.734 / 0.6904 / 55.1 | 0.4985 / 0.2143 / 22.2 | 0.5057 / 0.2144 / 27.5 | — |

A vector row over a range with special lanes (|x| > 512 for exp, the band
around 1 for ln) falls back to scalar calls, so it costs more than the
scalar row.

For a digital real/realtime array read with an out-of-range or x/z index,
IEEE §5.2.2 specifies an x reference but gives no real unknown encoding.
VerA applies §4.8.2's x/z-to-zero conversion at the real evaluation boundary,
so the read yields +0.0. It does not reinterpret the integer unknown plane
as an IEEE 754 NaN. Valid elements retain their real bit patterns, including
NaNs explicitly supplied by `$bitstoreal`. `ieee1364/04_data_types/native_real_arrays.v`
checks invalid indices beside valid elements in both the interpreter and
native executable.

For AMS §9.18, E0890 diagnoses specified values that fold over literals
outside Table 9-29's domains. A value that depends on model-card parameters
(an instance override over a parameter, or a top-level system alias the card
writes) is checked when the card is written: the device's `checkCard(model)`,
called after `derive`, returns the first such value's name (`path$mfactor`,
or the alias) outside its domain, and null otherwise; it costs `eval`
nothing. The testbench stops with E0890; another host decides what to do with
the name (`docs/Vague_Decisions.md` VD-079). `geometry_parameter_sweep.va`
exercises valid host-dependent values, `geometry_card_mfactor_outside_domain_is_fatal.va`
an invalid card, and `geometry_*_rejected.va` isolates literal domain
errors. The top-level `$mfactor` alias retains its existing ABI: a host using
it must also keep `Instance.mfactor`, which controls automatic scaling,
consistent with the alias's model-card value.

For AMS §4.2.4 integer `%`, zero-divisor checks remain observable even when
the remainder is discarded. Checks in a display-task argument run in that
task's accepted-point phase; `modulo_integer_display_zero.va` exercises an
inlined function that discards the value there. Solver devices that drop
display tasks omit those checks too. A real `%` by a run-time zero is the
same error (the §4.2.4 sentence names no operand type): the executable
reports E0601 and exits 1, a solver device traps (`kernel_text.zig`
`zFmod`, `zModZero`; `ch04_expressions/modulo_real_dynamic_zero.va`).

The device/host contract's conformance checks are opt-in (no clause; a VerA
choice). `tools/contract.zig`'s `validate`, `validateHost`'s host obligations,
`checkFamily` and a Debug device's `su_ok` assert (`setup` ran before `eval`)
run only in a program whose root module declares
`pub const vera_validate_contract = true` (`contract.validating`). VerA turns
them on in `zig build test` (`tools/zrunner.zig`), in every fixture-suite
testbench, in `vera --emit-exe`/`--run` with `--validate-contract`, and always
in `vera --check`. `validateHost`'s ABI check (`contract_abi == abi_version`)
always runs: it is what refuses a stale device. A host that wants the
obligation checks must opt in: the decl in its program's root module, or, for
`vera --emit-so`/`orchestrator.compileRelease`, in its `dyn` module, which the
generated shim (the build's root) forwards. Off, a device build spends
0.4-1.8% fewer instructions (2026-10-01: mos1 2.454 -> 2.417 Gi, bsim4va
eval 8.100 -> 7.958, psp103 eval 14.183 -> 14.125).

### Device ABI 6: the setup cache and the temperature are per Model row

§9.15 leaves where a simulator keeps a device's temperature to the
implementation, and VerA chooses the `Model` row (`contract.abi_version` 6,
2026-10-02; ABI 5 kept it per instance). Every value `setup` computes reads only
the card, the temperature and card-time `$simparam`s, so with the temperature on
the row the whole solve-invariant cache is a function of the row, and instances
that share a row share it. Measured on the emitted devices (bytes, ReleaseFast):

| Device | `Instance` ABI 5 -> 6 | `Model` ABI 5 -> 6 |
|---|---|---|
| mos1 | 744 -> 368 | 344 -> 720 |
| bsim4va | 3,520 -> 200 | 7,408 -> 10,728 |
| psp103 | 3,872 -> 104 | 6,816 -> 10,584 |

Bench outputs (residual, charges, Jacobian at 64 points) are bit-identical on
resistor, diode, mos1, bsim4va, psp103, coupled_ltra and txl, and `evalQ`
cycles moved -0.5% to +0% (in noise).

Host migration from ABI 5:

- **Moved, `Instance` -> `Model`:** `su: Setup` (the solve-invariant cache)
  and, in a Debug program that validates, `su_ok`. Same types, same element
  order; they are the last fields of `Model`.
- **Removed:** `Instance.temperature`. **New:** `Model.temperature__: f64 =
  300.15`, kelvin, host-written, in every device (`contract.host_model_fields`).
  `$temperature` and `$vt` read it, in `setup` and in `eval` alike. A host that
  simulates an instance at its own temperature (`dtemp`, a per-instance `temp`)
  gives that instance its own Model row. There is no per-instance fallback: one
  would need the per-instance cache this removes, and a host still writing
  `inst.temperature` fails to compile instead of running at a stale value.
- **`setup(comptime V: type, model: *Model) void`** (was `(V, *const Model,
  *Instance)`): once per Model row. Call order per row: write the card and
  `temperature__` (and any `nom_temp__`-style host fields), `derive(S,
  &model)`, `checkShape(&model)`, `setup(V, &model)`. Call `setup` again after
  any card, `temperature__` or `setup_simparams` write; `derive` first when the
  card changed.
- **New, optional `setupInstance(model: *const Model, inst: *Instance) void`**,
  emitted only when an instance caches something from the card (VerA's
  `vera_timepoint` caches, a latched §9.7.3 status). Call it for every instance
  of the row after each `setup`, and after an instance write.
- `setup_chunks.exportChunk` chunks now take `(*Model, *anyopaque)`.
- **New, only in a device that calls §9.19 `$port_connected` on one of its own
  ports: `Model.port_connected__: u64`**, all ones by default (every port
  connected, which is what ABI 5 answered), bit p = port p in the module's port
  declaration order. `$port_connected(p)` reads bit p. The host writes it with
  the card, BEFORE `derive`: `derive` and `checkShape` read it if a parameter
  expression calls `$port_connected`, and `setup` and every eval entry read it
  wherever the model does. An instance whose card connects a different set of
  ports (a 4-terminal card on HiSIM_HV's 6-port module) gets its own Model row.
- `contract.validateHost`'s `calls_setup` covers both entries.
- `$mfactor` (still `Instance.mfactor`) is no longer a solve-invariant input:
  instances of one row may differ in it, so a value that reads it is computed
  in `eval`.
- Instance parameters: VerA declares every §3.4 parameter, instance ones (L,
  W, M, NF...) included, as a `Model` field, so there is no per-instance card
  value to cache; a host binds per-instance parameters by giving the instance
  its own row, as for the temperature.

## 2. Resource limits

Each limit is stated here and fails with a named diagnostic. A run-time
limit ends the run with exit status 1; the LRM gives none of these a
truncation rule, so a shorter answer would be a wrong one.

| Limit | Value | Diagnostic | Code | Fixture |
|---|---|---|---|---|
| parser nesting, and binary operators in one chain | 1024 levels | E0241 | `lib/frontend/parser.zig` `max_depth` | `annex_a_syntax/nesting_past_the_parser_limit_rejected.va`, `sum_chain_past_the_parser_limit_rejected.va`, `long_sum_under_the_nesting_limit.va` |
| macro expansion depth | 128 | E0119 | `lib/frontend/preprocessor.zig` `max_expansion_depth` | `ch10_directives/macro_expansion_past_128_rejected.va` |
| `` `include `` depth | 32 | E0125 | `lib/frontend/preprocessor.zig` `max_include_depth` | `ch10_directives/include_cycle_rejected.va` |
| real literal length | 512 bytes | E0134 | `lib/frontend/lexer.zig` `parseReal` | `ch02_lexical/real_literal_over_512_bytes_rejected.va` |
| `` `include `` file, `$table_model` and `noise_table` data file | 16 MiB | E1013 | `lib/frontend/preprocessor.zig` `max_include_bytes`, `lib/ir/lower/table_model.zig` `max_table_bytes` | `ch10_directives/include_file_over_16mib_rejected.va`, `ch09_system_tasks/table_model_file_over_16mib_rejected.va` |
| source file and `--spice` netlist | 64 MiB | E1013 | `src/main.zig` `max_source_bytes` | `build.zig`: `vera --lint /dev/zero`, and `/dev/zero` as the `--spice` netlist, under `zig build test` |
| instance tree | 64 nested instances | E1018 | `lib/ir/elaborate.zig` `max_depth` | `ch06_hierarchy/instance_tree_64_levels.va`, `instance_tree_deeper_than_64_rejected.va` |
| nets, ports, branch flows and operator states in one module; one vector range | 65535 | E1015 | `lib/ir/lower/node.zig` `max_nodes` | `ch03_data_types/vector_net_over_65535_elements_rejected.va`, `nets_over_65535_rows_rejected.va` |
| analog-context array or assignment pattern | 2^20 elements | E1016 | `lib/ir/lower/shape.zig` `max_cells` | `ch03_data_types/array_over_2_20_elements_rejected.va` |
| loop generate unrolling | 4096 iterations | E0420 | `lib/ir/lower/control.zig` `max_unroll` | `ch06_hierarchy/generate_nonterminating_rejected.va` |
| solver unknowns | 256 | E1003 | `lib/backend/codegen/file.zig` `emitTopology` | `ch06_hierarchy/vector_port_unknown_ceiling_rejected.va` |
| `.v` contract device pins (one per top-module port bit) | 256 | E1103, "more than 256 pins" | `src/sim/digital/emit.zig` `deviceRoot` | `build.zig`: `vera --emit-zig tests/fixtures/ch07_mixed_signal/v_pins.v` (257 pins) under `zig build test`; `tests/vdev_host.zig` runs the wide counter (`v_wide`) across packed-plane word boundaries |
| conversions in one display or format call | 32 | E1010 | `lib/backend/cg_display.zig` `max_format_args` | `ch09_system_tasks/sformat_32_conversions.va`, `sformat_33_conversions_rejected.va` |
| text of one format call, string concatenation, field width or precision | 4096 bytes | E1011 | `lib/backend/kernels/str_kernels.zig` `zSOver`, `lib/backend/cg_display.zig` `Spec.max_field` | `ch09_system_tasks/string_concat_overrun_is_fatal.va`, `sformat_field_width_over_4096_rejected.va` |
| number literal size | 2^24 bits | E1019 | `lib/frontend/integer.zig` `max_width` | `ieee1364/03_lexical_conventions/b_3_5_1_literal_size_65536.v`, `b_3_5_1_literal_size_over_2_24_rejected.v` |
| analog number literal carrier | 64 bits; wider literals require an exact signed value in the i64 carrier | E0130 | `lib/frontend/integer.zig` `asExactInt` | `ch09_system_tasks/reject_clog2_wide_unsigned_carrier.va`; legal neighbour `clog2_unsigned_width.va` |
| analog `$clog2` expression carrier | arithmetic, unary negation and shifts retain at most 32 bits per intermediate; bitwise/conditional/comparison contexts retain at most 64 bits; above 64 bits only exact wide literals and parameter aliases preserving their width retain proven high bits | E0893 | `lib/frontend/constfold.zig` `intPlan`, `lib/ir/lower/constfold.zig` `clog2WideCarrier` | `ch09_system_tasks/reject_clog2_wide_arithmetic.va`, `reject_clog2_wide_arithmetic_default.va`, `reject_clog2_wide_widening.va`; legal neighbours `clog2_nested_contexts.va`, `clog2_unsigned_width.va` |
| a constant string replication | 4096 bytes | E1011 | `lib/ir/lower/expr.zig` `lowerConcat` | `ch03_data_types/string_replication_4096_bytes.va`, `string_replication_over_4096_bytes_rejected.va` |
| one `$fgets` line, one `$fscanf` look-ahead | 4096 bytes | E1011 | `lib/backend/kernels/file_kernels.zig` `ZFSlot.line`, `zfOver` | `ch09_system_tasks/fgets_line_over_4096_is_fatal.va`, `fscanf_window_over_4096_is_fatal.va`, `s01_13_long_record_is_not_truncated.va` |
| open file channels | 30 | `$fopen` returns 0, `$ferror` 24 (§9.5.1) | `lib/backend/kernels/file_kernels.zig` `zf_max` | `ch09_system_tasks/222_mcd_channels_exhausted_at_bit_31.va`, `224_two_instances_hold_distinct_channels.va` |
| distinct paths opened for writing in one run | 64 | `$fopen` returns 0, `$ferror` 24 (§9.5.1) | `lib/backend/kernels/file_kernels.zig` `zf_written` | `ch09_system_tasks/write_mode_path_65_fails_open.va` |
| `absdelay` history, per site, in accepted samples | 1024; with a §4.5.7 `maxdelay` that folds (a parameter's declared default counts), `ceil(maxdelay / 1ps) + 2`, clamped to [1024, 16384]: a 1-5 ns line at a 1 ps step fits, 16 B of `Instance` per sample (256 KiB at the cap). A signal-valued `maxdelay` keeps 1024. A card that raises `maxdelay` past the compiled default can still underrun | E1012 at run time | `lib/backend/codegen/instance.zig` (`hist_len`, `hist_min_step`, `hist_max`, `histLen`) | `ch04_expressions/absdelay_history_underrun_is_fatal.va`, `a04_05_absdelay_history_beyond_capacity.va`, `absdelay_maxdelay_sizes_history.va` |
| random distribution count | 1..2147483647, integral | the RNG diagnostics | `lib/backend/kernels/rng_kernels.zig` `zRngDf` | `ch09_system_tasks/189_rng_*_rejected.va` |
| UDP inputs | 64 | E1017 | `lib/frontend/parser/udp.zig` `max_udp_inputs` | `ieee1364/08_udp/b_8_1_2_udp_more_than_64_inputs_rejected.v` |
| digital: `$readmemb`/`$readmemh` file | 4 MiB | E1100, naming the bound | `src/sim/digital/display.zig` `side_file_limit` | `ieee1364/17_system_tasks/b_17_2_9_readmem_file_over_4mib_rejected.v` |
| digital: field width or precision | 4096 | E1011 | `src/sim/digital/display.zig` `max_field` | `ieee1364/17_system_tasks/b_17_1_1_2_real_precision_100.v`, `b_17_1_1_2_field_width_over_4096_rejected.v` |
| digital: `%d` of a known value | 64 bits | E1100 | `src/sim/digital/display.zig` `emitValue` | `ieee1364/17_system_tasks/b_17_1_1_4_decimal_over_64_bits_rejected.v` |
| digital: expression and statement depth | 256 levels | E1100 | `src/sim/digital/compile.zig` `infer`, `compileStmt` | `ieee1364/05_expressions/b_5_expression_deeper_than_256_rejected.v` |
| digital: hierarchy depth | 64 levels | E1100 | `src/sim/digital/elab.zig` `declare` | `ieee1364/12_hierarchy/b_12_hierarchy_deeper_than_64_rejected.v` |
| digital: loop generate | 65536 iterations | E1100 | `src/sim/digital/elab.zig` `generate` | `ieee1364/12_hierarchy/b_12_generate_past_65536_iterations_rejected.v` |
| digital: nested task and function activations | 1024, or 4 MiB of stack | E1100 | `src/sim/digital/exec.zig` `max_sync_stack` | `ieee1364/10_tasks_functions/b_10_4_recursion_past_the_stack_bound_rejected.v` |
| digital: array dimensions | 16 | E1100 | `src/sim/digital/elab.zig` `declareArray` | `ieee1364/04_data_types/b_4_9_net_array_17_dimensions_rejected.v` |
| `$simprobe` name (AMS 9.16) | resolved at compile time only: a literal or a string parameter; a name that does not fold (a string variable the analog block sets) is refused, fallback or not, since the fallback would answer a valid name wrongly (`docs/Vague_Decisions.md` VD-030) | E0823 | `lib/ir/lower/hier_name.zig` `lowerSimprobe` | `ch09_system_tasks/reject_simprobe_runtime_name.va`; legal neighbour `simprobe_string_parameter_name_resolves.va` |
| analog device: named event arrays | not yet executed; scalar analog events and digital event arrays are supported | E0235, naming AMS §5.10.4 | `lib/ir/lower.zig` `lowerModule` | `ch05_analog_behavior/event_array_device_limit_rejected.va`; legal neighbors `ch05_analog_behavior/named_event_unsupported.va`, `ieee1364/09_behavioral_modeling/b_9_7_3_event_arrays.v` |
| digital: events in one time step | 10,000,000, or `--event-budget=N` | E1100 | `src/sim/digital/root.zig` `max_events_per_tick` | `ieee1364/11_scheduling/b_11_zero_delay_loop_rejected.v` (at a budget of 1000: the default takes minutes to reach) |
| testbench `//! sweep` product | 4096 points | a `//!` directive error | `lib/backend/tb.zig` `max_points` | none (harness input, not source) |
| VPI derivative handles; analog value strings | 64; 64 bytes | `vpiNoMem`, `vpiBadFormat` | `src/vpi/analog.zig` `derivs`, `analog_buf` | none |
| VPI: automatic named events and dynamic event references in automatic tasks | declaration metadata is available; triggering through VPI requires unimplemented §26.6.20 frame handles | `AUTOMATIC`, naming the activation frame | `src/vpi/value.zig` `vpi_put_value` | `ieee_pli/b_26_6_11_event_array.c`; static-task event references are the legal neighbor |

### Host changes to paramset selection inputs

AMS §§6.3 and 6.4.2 require overload selection to use the effective parameter
values, including outer `defparam` bindings. VerA selects the module during
elaboration, after applying compile-time card overrides. Parameters read to
admit or exclude members of an overloaded paramset name are shape inputs:
the emitted `checkShape` returns the name of a changed input and the host
must recompile before evaluating that card. This includes numeric and string
inputs, and conservatively includes changes that remain within the same bin.
It is a host execution limit, not an AMS restriction on parameter values.

Parameters used only to supply values through a single-member paramset remain
live through `derive`. `lib/ir/elaborate/paramset.zig` records the selection
dependencies; `tests/paramset_host.zig` executes both kinds of host changes
against `ch06_hierarchy/paramset_outer_defparam_shape.va`.

### Timer controls with effects

AMS §5.10.3.3 requires the next event to use the final `start_time` and
`period`. VerA recomputes arithmetic, array reads and analog functions proved
free of effects. A function with output/inout arguments, random/file activity,
or an unproved nested call keeps its original result. If one of that call's
inputs changes afterwards, E0528 reports the unsupported combination instead
of silently retaining an old schedule or repeating effects. This is a limit
on legal AMS, not a prohibition in the LRM.

Compute such a call into a variable before `timer()`, then use or update that
variable as the control. An unchanged effectful leaf remains supported even
when another operand changes; a constant return also needs no recomputation
when an input changes. `lib/ir/lower/event.zig` owns this check;
`ch05_analog_behavior/timer_changed_effectful_*_rejected.va` pins the refusals,
`timer_effectful_file_leaf.va` checks one file write per accepted point, and
`tests/timer_host.zig` with `tests/fixtures/ch05_analog_behavior/timer_body_precomputed_controls.va` checks
final deadlines and output/inout effects through an emitted device, including
a rejected trial followed by a retry.

## 3. Unspecified behaviour

`CLAUSE-AUDIT.md` §5.5: no test asserts one outcome where the LRM permits
several. This covers every `unspecified` row of `ieee1364/CLAUSES.tsv`, and
each row's last column names its fixture policy. 5.1.4, 11.4.2, 11.5,
12.3.10.1 and 12.3.10.2 permit several outcomes: their fixtures assert
membership in the permitted set
(`ieee1364/11_scheduling/audit_sched_allowed_active_race.v`) or choose inputs
where every permitted outcome agrees
(`ieee1364/12_hierarchy/b_12_3_10_net_type_warning.v`). 20.2, 26.1, 26.2.4,
26.6.16, 26.6.21, 27.20, 27.34 and 27.34.1 bind the application, name no
failure value, or say no design must produce the object, so no fixture
asserts a refusal or a required object for them. The three
`audit_sched_*_order.v` fixtures pin VerA's documented order (§1 above) and
cite no clause. The `$ferror` fixtures assert only a nonzero code.

## 4. Open defects

**Direct reads of host-written integer parameters.** The generated Model uses
an i64 carrier for a declared `integer`. Writing `4294967297` to a parameter
declared `integer word=1` still makes a direct `word` expression read that raw
carrier, rather than the required low-32-bit value 1. Compile-time card
conversion, paramset selection, `checkShape`, and width-aware `$clog2` use 1;
the direct emitted read remains an independent gap. The wide-card paramset
fixture uses a representable integer control and does not claim this read is
fixed. `tests/paramset_host.zig` checks the effective integer selection only.

**Upward defparams bind in instance order on the analog path.** A defparam
path whose first identifier names the declaring instance or a module above it
(IEEE 1364-2005 §12.6, Syntax 12-7) is resolved from that scope
(`lib/ir/elaborate/override.zig` `defparamKey`), but the flatten binds each
instance's parameters as it inlines it. A target that is an ancestor, the
declaring instance itself, or a sibling written before the declaring one is
already bound, so the defparam is refused with E0907 naming that cause
(`boundEarlier`) instead of being applied as §12.8.1's collect-first order
would. The digital engine applies them (`src/sim/digital/root.zig`
`bindDefparam`). Fixture: `ch06_hierarchy/defparam_upward_module_name_path.va`
(a later sibling, applied).

The earlier limit defects below are gone rather than named:
the `absdelay` history counts steps in a u64; unit names count collisions in
a u32; digital `%b`/`%h`/`%s`/`%t`, `%m` and real conversions, `vpi_printf`'s
reals and the testbench's noise, AC-stimulus, charge-site and mixed-signal
name rows are written whole; a mixed-signal crossing the secant cannot close
is bisected to its `time_tol` (`src/sim/mixed.zig` `max_secant`).

The testbench's comptime loops over constant Jacobian entries and charge
stamps were measured, not changed: a 40-node resistor mesh (1600 constant
entries) and 200 charge sites build and run, and `tools/contract.zig` sets its
own evaluation quota where it computes those tables.
