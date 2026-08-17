# Combined coverage

The documentation `index.html` is a navigation/index page and defines no
language rules of its own. These fixtures deliberately combine rules that
are tested atomically in the per-document folders.

22 `.va` files, all of them run-and-assert: none carries `//! reject`, none
carries `//! xfail`, and every one contains at least two `CHECK` macros
(grep-measured). That was not true when the rows below were first written —
this folder used to be judged by diffing a frozen "expected Zig" dump, and
several rows still described what that snapshot contained rather than what the
fixture asserts. The framing is corrected here and the individual claims that
the intervening waves falsified are marked *was:*.

| Fixture | Cross-chapter coverage |
|---|---|
| `01_resistor_with_directives.va` | Macro expansion, parameter range, SI literal, access functions, and contribution. *Was: "`$bound_step` is currently erased to a zero placeholder."* §9.17.2 is a real kernel-control request now — an `Instance.bound_step` field reset to `inf` before each accepted step — and the timestep it asks for is the host's to honour, so no fixture inside a module can read it back. |
| `02_temperature_diode.va` | Parameters, `$temperature`, `$vt`, `limexp`, local variables, nonlinear contribution. |
| `03_piecewise_param_model.va` | Multiple parameters, conditional arithmetic, and contribution. *Was: "`$param_given` is approximated by comparing against the default, which is wrong for an explicit override equal to that default."* §9.19 reads a real `model.<p>__given` flag set by elaboration, so an override equal to the default is reported given. |
| `04_macro_function_math.va` | Formal macro arguments, analog user function, system-style `$min`/`$max`/`$exp`, return assignment, call lowering. |
| `05_loop_case_system_message.va` | Integer loop, case/default, `$abstime`, and the accumulated analog expression. *Was: "`$strobe` and `$warning` calls are erased and no message behavior is tested."* The §9.4 tasks are sequenced through the optional `display` contract decl; the transcript still is not a value a module can read, so this file asserts the argument and `ch09_system_tasks/{01–05}` own the task itself. |
| `06_noise_and_analysis.va` | Standard include, physical macro, analysis selection, temperature, and resistor law. *Was: "the expected Zig has an empty `noise_gens` array and a zero noise contribution."* Noise topology is exported through `noise_gens`; what this file still does not pin is a noise ANALYSIS, because §4.6.4 makes every noise call zero outside one and `//! analysis noise` belongs to the `ch04_expressions` fixtures that own the generators. |
| `07_limit_and_discontinuity.va` | `$vt`, `limexp`, and the nonlinear contribution. *Was: "`$discontinuity` is erased and named `$limit` is pass-through."* Both are implemented — `$discontinuity` as a kernel-control request beside `$bound_step`, `$limit` in `src/backend/cg_limit.zig` with a `limit()`/`seed()` pair on the contract — and both are decided by the HOST, so their semantics are asserted in `ch09_system_tasks/{136–139,156,164}` and not here. |
| `08_file_and_display_side_effects.va` | Absolute time, the analog contribution AND the descriptor are observable: §9.5.1's "a zero is returned" is reserved for failure, so `fd != 0` is a real assertion about a real open. What is still not readable from inside the model is what `$fdisplay` put in the file — a transcript is not a value — which is why the sibling §9.5 fixtures write with `$fwrite` and read the bytes back instead. |
| `09_optional_port_environment.va` | Parameter/fallback arithmetic, and §9.15's own precedence: `$simparam` answers a KNOWN name from `Lower.simparamValue` and takes the fallback only for a name this engine does not have. *Was: "`$simparam` always chooses the source fallback."* `$port_connected` is still constant 1, and that is the conforming answer rather than a stub: every port of an elaborated device instance IS connected, and an unconnected one is the host's business (§6.5.6). The three source-level ways to leave a port unconnected are pinned in `ch06_hierarchy`. |
| `10_nested_preprocessor_model.va` | Nested `ifdef`/`ifndef`, macro state, `$pow`, conditional source selection. |
| `11_controlled_source_named_branches.va` | Four-terminal controlled source, named branch probing/contribution, parameter range, and control-port loading. |
| `12_multi_branch_nonlinear_device.va` | Three-terminal nonlinear device, guarded parameter, local operating value, `max`, `tanh`, and multiple branch contributions. |
| `13_noise_temperature_analysis.va` | Constants include, bounded parameters, analysis selection, temperature arithmetic, deterministic conductance. *Was: "both noise calls become zero and `noise_gens` is empty, so white/flicker noise generation is an implementation gap."* Same correction as `06`: the generators exist and are exported; this file runs outside a noise analysis, where §4.6.4 makes them zero by rule. |
| `14_macro_alias_parameter_ranges.va` | Formal macro and parameter declarations, and §3.4.7's alias. *Was: "the expected Zig multiplies by zero instead of `scale`: `aliasparam gain = scale` is not implemented. The snapshot records this gap rather than correct alias semantics."* The alias has its own `Model` field plus a `__given` flag and `derive` folds it onto the original before any dependent parameter reads it. |
| `15_electrothermal_dual_discipline.va` | Electrical and thermal ports, Joule heating, two disciplines' access functions, and dual-domain contributions. |
| `16_file_display_diagnostics.va` | The source contains the complete open/write/flush/close lifecycle and it runs — but the `$fdisplay`/`$warning` pair sits under a conditional ON PURPOSE (W0851 drops it, which the header explains), so what this file asserts is §4.2.5's integer-valued relational, §9.7.1's `$abstime` and Ohm's law. The lifecycle itself is pinned by `ch09_system_tasks/{07,08,052}`; here it is context. |
| `17_optional_port_hierarchy.va` | The controlled-source arithmetic, and §9.18's Table 9-29 top-level values. *Was: "`$mfactor` is constant one, placement values are zero, and the environment term is multiplied by zero."* `$mfactor` is carried as an instance expression and multiplied down the chain by the flatten (`ch06_hierarchy/mfactor_propagation_unsupported.va` pins 1.0 × 2.0 × 7.0). The placement queries — `$xposition`, `$yposition`, `$angle` at 0 and `$hflip`/`$vflip` at +1 — are Table 9-29's *Top-Level Value* column, which is EXACT for a device that is the top level, not a placeholder. `$port_connected` is constant 1 for the reason given under `09`. |
| `18_analysis_modes_and_severity.va` | Multiple analysis names, piecewise conductance, and the guarded parameter. *Was: "`$info` is erased, so informational diagnostic behavior is not covered."* `$info` goes through the same `display` decl as the rest of §9.4; the transcript is still not a value, so severity behaviour is `ch09_system_tasks`' to assert. |
| `19_named_limiter_nonlinear.va` | Thermal voltage, `limexp`, and nonlinear current. *Was: "named `$limit` is pass-through and `$bound_step` is erased."* Corrected as under `01` and `07`. |
| `20_function_branch_system_math.va` | Named branch, analog function, system-style hyperbolic/min/max math, and contribution. |
| `21_three_terminal_piecewise_device.va` | Three-terminal piecewise conductance selected by `case`, local state, and multiple branch loads. |
| `22_parameter_binding_environment.va` | Ternary/local-gain arithmetic and contribution. *Was: "override detection uses the default-value comparison heuristic and optional-port detection is constant true, so explicit-default and disconnected cases are not covered."* The heuristic is gone (`__given`); `$port_connected` is constant 1 by rule. The explicit-default case is covered in `ch09_system_tasks`' §9.19 fixtures and the disconnected case in `ch06_hierarchy`. |

Combined cases are regression fixtures, not substitutes for the literal
section-by-section inventories in each chapter or annex `COVERAGE.md`. Where a
row above says a behaviour is decided by the HOST — a timestep bound, a
convergence limiter, a transcript, an unconnected port — that is a boundary and
not a gap: nothing inside a module can read it back, so the fixture asserts what
the model computes and the owning chapter asserts the rule.
