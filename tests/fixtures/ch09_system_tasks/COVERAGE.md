# Chapter 9 coverage

Source: `docs/VAMS-LRM/ch9-system.html`, read section by section.

HTML section-ID audit: `s9.1` `s9.2` `s9.3` `s9.4` `s9.4.1` `s9.4.2` `s9.4.3` `s9.4.4` `s9.4.5` `s9.4.6` `s9.4.7` `s9.5` `s9.5.1` `s9.5.1.1` `s9.5.1.2` `s9.5.2` `s9.5.3` `s9.5.4` `s9.5.4.1` `s9.5.4.2` `s9.5.5` `s9.5.6` `s9.5.7` `s9.5.8` `s9.5.9` `s9.6` `s9.7` `s9.7.1` `s9.7.2` `s9.7.3` `s9.8` `s9.9` `s9.10` `s9.11` `s9.12` `s9.13` `s9.13.1` `s9.13.2` `s9.13.3` `s9.14` `s9.15` `s9.16` `s9.17` `s9.17.1` `s9.17.2` `s9.17.3` `s9.18` `s9.19` `s9.20` `s9.21` `s9.21.1` `s9.21.2` `s9.21.3` `s9.21.4` `fn9.21.4-1` `s9.21.5` `s9.22` `s9.22.1` `s9.22.2` `s9.22.3` `s9.22.4` `s9.22.5` `s9.22.6` `s9.23` `s9.23.1` `s9.23.2` `s9.23.3` `s9.23.4`.

Sixty-eight ids, forty-six of them carrying a fixture that exercises the
construct. The other twenty-two get an empty cell and a sentence saying why,
never a plausible file name.

164 `.va` files and one data file (`ch09_table_model_2d.tbl`). **Seventy-eight
of the 164 are `//! xfail`** — this is by a wide margin the most indebted
chapter in the suite, and that ratio is the honest headline, not a footnote.
Thirty-six fixtures carry `//! reject`, and VerA still accepts most of what this
chapter forbids. The rejects it does meet are `136`/`137` (`$bound_step`
E0803/E0802), `138`/`139` (`$discontinuity` E0804/E0805), `147` (§9.15
`$simparam` on an unknown name with no fallback, E0811), `161` (§9.4.3
format/argument pairing, E0810) and all six §9.20 alias negatives `141`–`146`
(E0812). The aggregate counts in this file predate those and are known stale; a
single re-census is scheduled.

Reading the table: **xfail** on a fixture means the file runs and fails, and the
reason on that row is the defect. A row whose fixtures are *all* xfail is a
section the suite states and the compiler does not meet — there is no passing
evidence behind it. §9.6, §9.8, §9.9, §9.16, §9.22.x and §9.23.x are all in that
state. §9.4.2, §9.4.3 and §9.5.4.2 left it when the string formatter and scanner
landed; §9.21 and its five subclauses left it when the table interpolator did;
§9.13.1 and §9.13.2 left it when the probabilistic distributions did; and
§9.5.1, §9.5.2, §9.5.4.1, §9.5.5, §9.5.6, §9.5.7 and §9.5.8 left it when the
descriptor table did.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s9.1` | overview; the clause is organised by the 9.2 categories | — umbrella, no rule to test |
| `s9.2` | Tables 9-1…9-20, the analog-context Yes/No column | Yes rows: `05_display_debug.va`, `059_warning.va`, `060_info.va`, `063_realtobits.va`, `064_bitstoreal.va`, `065_test_plusargs.va`, `066_value_plusargs.va`. No rows: `061`, `062`, `134`, `135`, `148`, `149`, `153` — all **xfail**, *VerA implements no analog-context check for any Chapter 9 system task; a grep across `src/` finds none* |
| `s9.3` | how a task behaves across accepted vs. rejected solver iterations | — no fixture. Accept/reject is a kernel property the generated device cannot observe |
| `s9.4` | display task family | — parent; carried by 9.4.1–9.4.3 below |
| `s9.4.1` | `$strobe` `$display` `$write` `$monitor` `$debug` in the analog context | `01_display_strobe.va`, `02_display_display.va`, `03_display_write.va`, `04_display_monitor.va`, `05_display_debug.va` (each pins the argument *value*, since the transcript is not observable from inside the model); `06_display_formats.va` — **xfail**, *`%c` does not compile: `cg_display.zig` appendConv maps it to Zig verb `c` with `want=.int` and hands `std.fmt` an i64 where `{c}` takes a u8, so any `$display` carrying a Table 9-22 `%c` kills the generated testbench*; `152_display_radix_variants_analog_rejected.va` (`$displayb/h/o`, `$strobeb`, `$writeh`, `$monitorb`, `$monitoron/off`) — **xfail**, *no Table 9-1 analog-context restriction*; `161_display_argument_pairing_rejected.va` — **xfail**, *VerA does not check the `%` count in a format string against the argument list* |
| `s9.4.2` | Table 9-21 escapes `\ddd` `\t` `\\` `\"` | `06_display_formats.va` passes, but the escapes in it are a rendering a reader checks by eye — the two assertions it carries are the `%h`/`%o` round trips, not the escapes. Nothing else carries a single-backslash escape outside a file-I/O path name |
| `s9.4.3` | Table 9-22/9-23 format specifications and `width.precision` | `06_display_formats.va`, `09_string_formatting.va` pass; `161_…_rejected.va` rejects at E0810. `06`'s `%h`/`%o` round trips through `$sformat`+`$sscanf` are the only digit-level assertions on a base in the chapter, and they are now real: the formatter writes into `zSBuf(<site>)` and `zScan` reads the digits back (`src/backend/str_kernels.zig`) |
| `s9.4.4` | `%m` prints the hierarchical name and takes no argument | — no fixture cites it. `%m` appears in `06_display_formats.va`'s second `$display` and in `161`, both unasserted (a transcript is not a value), and `06` does not compile |
| `s9.4.5` | `%s` prints ASCII codes as characters | — same: `%s` sits in `06`'s first `$display` and in `162`'s scan string, neither asserting the right-justification/leading-zero rule this subclause is actually about |
| `s9.4.6` | no display output except `$debug` unless the iteration is accepted | — no fixture. `043_fdebug.va` quotes the rule in its header and does not test it; the harness runs one accepted solve |
| `s9.4.7` | `%r`/`%R` on reals **in the digital context** | — no fixture. The `%r` in `03_display_write.va` and `06` is the Table 9-23 *analog* engineering-notation specifier; Verilog-A has no digital context for this extension to apply to |
| `s9.5` | file-I/O family, Table 9-2 | `153_file_io_digital_only_analog_rejected.va` (`$fdisplayb`, `$fwriteh`, `$fstrobeo`, `$fmonitorb`, `$swriteh`, `$fgetc`, `$ungetc`, `$fread`, `$readmemb`, `$sdf_annotate`) — **xfail**, *no Table 9-2 analog-context restriction* |
| `s9.5.1` | `$fopen` descriptor forms, `$fclose` | `07_file_open_close.va`, `08_file_output.va`, `039_fdisplay.va`, `047_fscanf.va`, `052_fflush.va`, `053_ferror.va`, `10_file_read_scan.va`, `11_file_position_status.va`, `158_fopen_multichannel_descriptor.va` — **all nine pass**, and both descriptor shapes are pinned at the bit: an fd with bit 31 set and a channel number above the three pre-opened streams, an mcd with bit 31 clear and exactly one bit set that is not bit 0, and 0 for a missing file opened `r`/`r+`. `$fclose` frees the channel, which `158` observes through the reuse §9.5.1 requires |
| `s9.5.1.1` | reopening a write-mode file across analyses appends | — no fixture. Needs two analyses in one process, which the harness does not run |
| `s9.5.1.2` | analog/digital descriptor sharing | — no fixture; mixed-signal runtime policy, no Verilog-A source form |
| `s9.5.2` | `$fdisplay` `$fwrite` `$fstrobe` `$fmonitor` `$fdebug` | `040_fwrite.va`, `041_fstrobe.va`, `042_fmonitor.va`, `043_fdebug.va`, `039_fdisplay.va`, `08_file_output.va` all pass. Each of the atomics still pins only the *argument value* handed to `%g` — a byte in a file is not readable from inside the model — but the BYTES are now pinned indirectly, and exactly where they can be: `046`/`049`/`050`/`051`/`054`/`11` write with `$fwrite` and read the result back, so the four-byte line and the positions after it are assertions about what the writer actually put there. §9.5.2's "the same type of arguments as the tasks upon which they are based" is literal in the emitter: the formatter is `emitDisplayTask`'s, over the arguments after the descriptor, with §9.4.1's newline rule applied to the base name so `$fwrite` does not end the line |
| `s9.5.3` | `$swrite` and `$sformat` | `044_swrite.va`, `045_sformat.va` pass on the argument value only (their `text` is never read back); `06_display_formats.va` and `09_string_formatting.va` pass on the TEXT, by sending it back through `$sscanf` — lowering makes both writers an assignment to the named string variable, not a void call, so a formatter that wrote nothing would now fail them |
| `s9.5.4` | files are readable only if opened `r`/`r+` | — no fixture; there is no descriptor to open in the wrong mode |
| `s9.5.4.1` | `$fgets` | `046_fgets.va` passes on the sentence that distinguishes it from C: the newline is "read AND transferred to str", so a four-byte line returns 4 and not 3. `049`/`051`/`054`/`11` read the same line for its side effect on the position |
| `s9.5.4.2` | `$fscanf` and `$sscanf` | `048_sscanf.va`, `162_sscanf_conversion_rules.va`, `06`, `09`, `10_file_read_scan.va` pass — `$sscanf` is `zScan` (suppression `*`, maximum field width, early matching failure, EOF, and the ten conversion codes), and each output argument is its own assignment from a `$sscanf$<ty>` item call. `047_fscanf.va` passes too, on both halves it was written to separate: 0 for the missing file, and `code == 1` with `value == 42` for a file it writes itself. `$fscanf` is the SAME scanner — `zScan` over one line the file kernels read — because §9.5.4.2 states one set of conversion rules for both spellings |
| `s9.5.5` | `$ftell` `$fseek` `$rewind` | `049_ftell.va`, `050_fseek.va`, `051_rewind.va`, `11_file_position_status.va` — **all four pass**, and each asserts a MOVED and an unmoved pointer so the two cannot be confused: 0 then 4 across a `$fgets`, 4 after `$fseek(fd,0,2)` on a four-byte file, 0 after `$rewind`, and the status half separately (0, not the new position). The position is the kernels' own quantity and every read is positional, which is what makes `$ftell` exact after a read that stopped at a newline |
| `s9.5.6` | `$fflush` | `052_fflush.va` passes on what §9.5.6 leaves observable — the descriptor it is handed. The task itself is genuinely a no-op and says so: every write goes positionally straight to the descriptor, so there is never buffered output to flush |
| `s9.5.7` | `$ferror` | `053_ferror.va` passes in both directions, which is the point of it: zero errno and an EMPTY description after a successful open, a nonzero errno after one that failed. The errno's numeric value is deliberately unasserted — §9.5.7 says only "an error code is returned" |
| `s9.5.8` | `$feof` | `054_feof.va`, `11_file_position_status.va` pass. `054` puts the descriptor in both states in turn — zero until a read detects EOF, nonzero after the read that runs off the end — and it takes TWO `$fgets` to get there, because the first stops at the newline and need not have touched the end |
| `s9.5.9` | file position rolled back on a rejected iteration; `$fdebug` excepted | — no fixture. The descriptor is real now, but the harness runs one accepted solve per point, so there is no rejected iteration to roll back. The rule is nevertheless what the implementation is BUILT on: every §9.5 call is sequenced in the per-accepted-point phase (`codegen.Gen.emitting_display`) and none of them runs inside `eval`, so a rejected Newton iteration cannot have written anything to undo |
| `s9.6` | `$printtimescale` `$timeformat`, analog "No" | `154_timescale_pla_queue_analog_rejected.va` — **xfail**, *no Table 9-3 analog-context restriction* |
| `s9.7` | simulation control family | — parent; carried by 9.7.1–9.7.3 |
| `s9.7.1` | `$finish` and its optional diagnostic level | `055_finish.va`, `12_finish_stop.va` |
| `s9.7.2` | `$stop` and its optional diagnostic level | `056_stop.va`, `12_finish_stop.va`; `140_stop_in_analog_initial_rejected.va` — **xfail**, *VerA does not restrict `$stop` by block kind; it lowers it the same way in `analog initial` as in `analog`* |
| `s9.7.3` | `$fatal` `$error` `$warning` `$info` | `057_fatal.va`, `058_error.va`, `059_warning.va`, `060_info.va`, `13_severity_tasks.va`. These have no return value, so what is pinned is that the run *continues past* the call — the assertion sits after it |
| `s9.8` | PLA tasks not extended to analog | `154_…_rejected.va` (`$async$and$array`) — **xfail**, *no Table 9-5 restriction*. There is no positive side: the table has no analog "Yes" row |
| `s9.9` | stochastic queue tasks not extended to analog | `154_…_rejected.va` (`$q_initialize`) — **xfail**, *no Table 9-6 restriction*; likewise no positive side |
| `s9.10` | `$abstime` in seconds; `$realtime` deprecated in analog | `14_abstime.va` (`//! analysis tran`, `//! time 2.5e-9`); `148_realtime_analog_rejected.va` and `149_time_stime_analog_rejected.va` — **xfail**, *no Table 9-7 restriction; VerA answers `$realtime`/`$time`/`$stime` in an analog block like any time query* |
| `s9.11` | conversion functions; only `$bitstoreal`/`$realtobits` extend to analog | `15_conversion_functions.va` (the pair is the identity on 3.7, bit-exact), `063_realtobits.va`, `064_bitstoreal.va`; the four Table 9-8 "No" rows are `061_rtoi`, `062_itor`, `134_signed`, `135_unsigned` — **all xfail**, *no Table 9-8 analog-context check; `$rtoi` even emits a truncation* |
| `s9.12` | `$test$plusargs` and `$value$plusargs` | `065_test_plusargs.va`, `066_value_plusargs.va`, `16_plusargs.va` |
| `s9.13` | probabilistic distribution family | — parent; carried by 9.13.1–9.13.2 |
| `s9.13.1` | `$random` and `$arandom`, seeded and unseeded | `32_random.va`, `33_arandom.va`, `115_random_no_seed.va`, `116_arandom_no_seed.va`, `117_arandom_parameter_seed.va`, `118_arandom_negative_seed.va`. Scope negative `132_arandom_type_string_outside_paramset_rejected.va` — E0816 |
| `s9.13.2` | seven `$dist_*` and six `$rdist_*` names | `34_distribution.va`, `35_real_distribution.va`, `119`–`130` (one file per name). Argument-rule negatives `150_rdist_domain_rejected.va`, `151_rdist_uniform_start_end_rejected.va`, `166_rdist_real_seed_rejected.va`, `133_rdist_type_string_outside_paramset_rejected.va` — all E0816 |
| `s9.13.3` | Table 9-26 cross-listing to the 1364 C algorithms | — no fixture claims a distribution's VALUE, and none can: this clause defers the algorithms to IEEE 1364 §17.9.3 and no clause of *this* LRM requires a tool to reproduce that stream. What the family's fixtures pin instead is §9.13.1/§9.13.2's own two sentences — repeatability on a seed, and the inout seed coming back different |
| `s9.14` | math system functions | Twenty-seven atomics `067`–`093` plus `17_math_unary.va`, `18_math_trig.va`, `19_math_binary.va`, `20_math_2023.va`. Two of the atomics are **xfail**: `092_ln1p.va` — *`codegen.zig` `zLn1p` is `a.addC(1.0).log()`, so `$ln1p(5e-16)` returns 4.440892098500625e-16, 11% low — precisely the naive value Table 4-14's C `log1p` exists to replace* — and `093_expm1.va` — *`zExpm1` is `a.exp().addC(-1.0)`, same 11% error for the same reason* |
| `s9.15` | `$temperature` `$vt` `$simparam` `$simparam$str` | `21_temperature_vt.va`, `094_temperature.va`, `095_vt_ambient.va`, `096_vt_temperature.va` (all `//! temp`-driven), `22_simparam.va` (unknown name returns its fallback verbatim), `23_simparam_string.va`. All three branches of the clause's `$simparam` sentence are now green: `147_simparam_unknown_no_fallback_rejected.va` is a **reject VerA meets** (E0811 — the unknown name with no fallback), and `157_simparam_timescale.va` pins Table 9-27's two source-derived rows, `"timeUnit"`/`"timePrecision"` in seconds, which the preprocessor now parses out of `` `timescale `` and publishes for `Lower.simparamValue` |
| `s9.16` | `$simprobe(inst_name, param_name [, expr])` | `36_simprobe.va` — **xfail**, *E0801: no sibling-instance host to probe; Table 9-13 marks it analog-context Yes* |
| `s9.17` | analog kernel control family | — parent; carried by 9.17.1–9.17.3 |
| `s9.17.1` | `$discontinuity`, degree `0` and `-1` | `24_discontinuity.va`; `138_discontinuity_arity_rejected.va` (E0804) and `139_discontinuity_nonconstant_rejected.va` (E0805) — **rejects VerA already meets** |
| `s9.17.2` | `$bound_step` | `25_bound_step.va` (`//! analysis tran`); `136_bound_step_negative_rejected.va` (E0803) and `137_bound_step_arity_rejected.va` (E0802) — **rejects VerA already meets** |
| `s9.17.3` | `$limit`, all three Syntax 9-12 forms | All three: `26_limit.va` (`$limit(V(p,n))`), `27_limit_named.va` (`$limit(V(p,n), "pnjlim", $vt, 0.7)`), `156_limit_user_function.va` (an `analog_function_identifier` is resolved as the limiter, not looked up as a value) and its negative `164_limit_user_function_output_arg_rejected.va` (E0814, "shall all be declared input"). The limiting REQUEST is declined for form three — §4.5.15 permits that, and the return is then the clause's converged answer, the probe itself; a non-identity limiter would be able to tell the difference |
| `s9.18` | `$mfactor` `$xposition` `$yposition` `$angle` `$hflip` `$vflip` | `28_hierarchical_parameters.va` plus atomics `097`–`102`, one per name. `163_aliasparam_mfactor.va` — **xfail**, *`aliasparam m = $mfactor;` is E0208 `expected an identifier`, so §3.4.7's own printed example does not parse* |
| `s9.19` | `$param_given` and `$port_connected` | `29_binding_detection.va`, `103_param_given.va` (overridden), `159_param_given_not_overridden.va` (the 0 direction, one deleted `//! param` line away), `165_param_given_override_equals_default.va` (override *equal to* the default is still an override — the input that separates a flag from a value comparison, and VerA now carries a real `__given` flag, `codegen.zig:867`), `104_port_connected.va` |
| `s9.20` | `$analog_node_alias` / `$analog_port_alias` | `30_node_alias_calls.va`, `105_analog_node_alias.va`, `106_analog_port_alias.va` pass — see the note below on *why* they pass. All six negatives now reject at E0812, one code for the clause's whole validity list: `141` (outside `analog initial`), `142` (first argument a port), `143` (bit select), `144` (non-constant string), `145` (target is another call's `analog_net_reference`), `146` (inside a conditional the simulation can move). All six are checked in `lower.zig` `checkAliasCall`, because every one of them is a property of the CALL — the block, the guard, the argument's shape — and none of a value. The topology edit itself is still not performed; see the note below |
| `s9.21` | `$table_model` | `37_table_model.va` (file-backed, with `ch09_table_model_2d.tbl`), `131_table_model_array_control.va` (array-backed), `155_table_model_lrm_sample_set.va` — **all three green**. The isoline interpolator is `src/backend/table_kernels.zig`, emitted into the device like the §4.5.11 filter kernels; the call is rewritten into a self-describing one by `Lower.lowerTableModel`, which is also where a scheme VerA does not implement is refused (E0815) |
| `s9.21.1` | data source: file or real arrays | Both forms present and both green: `37` supplies `"ch09_table_model_2d.tbl"` (read at COMPILE time and emitted as constants — "The state of the data source is captured on the first call ... Any change after this point is ignored" is what makes that exact, and a residual has no business re-reading a file per Newton iteration), `131` supplies independent/dependent real arrays. The clause's sort-into-isolines sentence is honoured (`zTabSort`), pinned by the reversed-row row of the codegen test |
| `s9.21.2` | control-string grammar | `37`'s `"1LL,1LL;1"` and `131`'s `"1LL;1"` are parsed by `Lower.parseTableCtl`: per-dimension sub-strings outermost-first, the one-character and two-character extrapolation forms, the defaults for an absent character or an absent string, and the dependent selector. Table 9-30's `D`/`2`/`3`/`I` and Table 9-31's `E` are refused at E0815, not approximated. No fixture pins a refusal — the five malformed strings are in the CLI checks only |
| `s9.21.3` | Table 9-32 example control strings | `37`'s `"1LL,1LL;1"` is verbatim the table's fourth row and is now read as such; `131`'s `"1LL;1"` is that row in one dimension. The `"D,1,3"`, `"I,..."` and `"3,D,I,1;3"` rows name schemes VerA refuses |
| `s9.21.4` | closest-point, linear and cubic-spline interpolation | LINEAR only, and the other three are refused rather than substituted. `155` serves the linear half: it recomputes Figure 9-2's `f(3.5, 0.25) = 2.0` by hand from the printed twelve-row sample set under the default rule, and that is the number it now reads back. Both Table 9-31 extrapolations work, per end, which the codegen test pins with an asymmetric `"CL"` |
| `fn9.21.4-1` | bibliography footnote for cubic splines | — informative; no language rule |
| `s9.21.5` | the LRM's own worked example | `155_table_model_lrm_sample_set.va` — green. This is the only place in the chapter where the LRM supplies its own oracle (data, query point *and* answer), and the compiler now agrees with it |
| `s9.22` | connectmodule driver access | `31_driver_access.va` (`$driver_count`, `$driver_state`, `$driver_strength` in an ordinary module) and atomics `107`, `109`–`114` — **all xfail**, *VerA compiles one flat analog device and lowers the whole §9.22/§9.23 family to a constant (`codegen.zig` `driver_queries`) instead of refusing the call site*. Note the numbering gap at `108`: the spec's own text says "$receiver_count is not a subclause of 9.22 in Verilog-AMS 2.4", so no fixture claims one |
| `s9.22.1` | `$driver_count` | `107_driver_count_connectmodule_rejected.va` (+ `31`) — **xfail**, as above |
| `s9.22.2` | `$driver_state` | `109_driver_state_connectmodule_rejected.va` (+ `31`) — **xfail** |
| `s9.22.3` | `$driver_strength` | `110_driver_strength_connectmodule_rejected.va` (+ `31`) — **xfail** |
| `s9.22.4` | `driver_update` event | `38_driver_update_connectmodule.va` — **xfail**, *VerA has no connectmodule support at all: the file stops at `NoModule` before reaching the ordinary module below, so the one context in which `@(driver_update)` is legal is refused* |
| `s9.22.5` | receiver net resolution via `assign d_receivers = d_drivers;` | — no fixture. Needs a connectmodule with a digital port and a continuous assignment, neither of which VerA parses |
| `s9.22.6` | the Figure 9-4 worked connectmodule | — no fixture; the whole example is mixed-signal |
| `s9.23` | supplementary driver access | — parent; carried by the four children below, which cite them directly |
| `s9.23.1` | `$driver_delay` | `111_driver_delay_connectmodule_rejected.va` — **xfail**, same `driver_queries` constant. Not covered by `31`, whose body has only the three §9.22 names |
| `s9.23.2` | `$driver_next_state` | `112_driver_next_state_connectmodule_rejected.va` — **xfail** |
| `s9.23.3` | `$driver_next_strength` | `113_driver_next_strength_connectmodule_rejected.va` — **xfail** |
| `s9.23.4` | `$driver_type` | `114_driver_type_connectmodule_rejected.va` — **xfail** |

## The four walls

Eighty xfails is not eighty defects. It is four walls and a short tail —
17 + 25 + 11 + 19 + 8 = 80 — and it is worth knowing which wall a row is behind
before reading it as debt. TWO of the four are now down (the RNG wall, 25, and
the descriptor wall, 14), so that arithmetic is stale in the same direction as
the counts in the header and waits on the same single re-census; what each
paragraph says about its own wall is current.

**Descriptors: the wall is down (14 fixtures).** Every §9.5 name that needs a
FILE — `$fopen`, `$fclose`, the five output tasks, `$fgets`, `$fscanf`, `$ftell`,
`$fseek`, `$rewind`, `$fflush`, `$ferror`, `$feof` — used to lower to the constant
`S.con(0.0)`, and `lower.zig` gave the reason: the family "needs a descriptor the
compiled device has no way to own". It still does not own one, and that turned out
to be the answer rather than the obstacle.

The table is a HOST facility (`src/backend/file_kernels.zig`), carried only by the
printing artifact, and every §9.5 call is sequenced in that artifact's
per-accepted-point phase — the same optional `display` decl §9.4's prints go
through, which §9.5.2 ("$fdisplay … the same as $display", with a descriptor
prepended) and §9.5.9 ("the file write operations shall not be performed unless
the iteration is accepted") both point at. `eval` therefore never opens, reads or
writes anything, which is what keeps the residual a pure function of x and the
host's Newton iteration convergent. A device compiled for a solver has no such
phase, so its `$fopen` answers 0 — and §9.5.1 reserves exactly that for a file
that cannot be opened, so the degraded path is conformant and not a stub.

The three names that need no descriptor were OUT of this wall and landed first:
`$swrite`, `$sformat` and `$sscanf` write into and read out of a string
variable, so `048_sscanf.va`, `162_sscanf_conversion_rules.va`, `06`, `09` and
`10_file_read_scan.va` went green with the formatter — and `$fscanf` is now the
same scanner over a line the file kernels read, which is what §9.5.4.2 states one
set of conversion rules for both spellings in order to mean.

**RNG: the wall is down (25 fixtures).** `$random`, `$arandom`, seven `$dist_*`
and six `$rdist_*` used to be one blanket E0801 at the function name, on the
argument that a draw changing between Newton iterations makes the residual
non-deterministic so the solve never converges. The premise was right and the
conclusion was wrong. §9.13.1/§9.13.2 make the seed a SOURCE VARIABLE — "a value
is passed to the function and a different value is returned" — so a variate is a
pure function of that variable's incoming value and is automatically fixed for
the whole Newton loop at one operating point. Lowering splits one source call
into two pure calls over the seed (the variate, and the write-back), exactly as
`$sscanf` is split into one call per out-parameter. The seedless forms have no
such variable, so their §9.13.1 "internal seed" is a latch in `Instance` advanced
by `updateState` on the ACCEPTED step and only read by `eval` — the same
discipline, with the boundary the contract already had. The four argument-rule
negatives (`150`, `151`, `166`, and the paramset scope pair `132`/`133`) reject
on E0816, which is per-argument and therefore fires whether or not the family is
otherwise supported.

**No analog-context table (11 fixtures).** Tables 9-1, 9-2, 9-3, 9-5, 9-6, 9-7,
and 9-8 each have a "No" column, and VerA implements none of it — `061`, `062`,
`134`, `135`, `148`, `149`, `152`, `153`, `154` are the inventory, plus `140`
(`$stop` by block kind) and `161` (format/argument pairing). This is the
cheapest wall in the chapter: it is a lookup table and a diagnostic, not a
runtime feature, and it retires eleven rows.

**No hierarchy (19 fixtures).** VerA compiles one flat module. That takes out
§9.22/§9.23 wholesale (`31`, `107`, `109`–`114`, `38`) and `$simprobe` (`36`).
`$table_model`'s three (`37`, `131`, `155`) used to be counted here, on the
honest note that they needed an interpolator rather than hierarchy; they now
have one. The six §9.20 negatives used to be
counted here; they are not hierarchy at all — every one of their rules is about
the CALL — and they now reject at E0812.

The tail is a handful of single-cause fixtures: `092`/`093` (naive
`log1p`/`expm1`), `156`/`164`
(`$limit` form three), `157` (`` `timescale `` not threaded into `$simparam`),
`147` (no missing-fallback diagnostic) and `163` (`aliasparam` will not take a
system function). Each is a single edit in a single file.

## Two places where "passes" is narrower than it looks

**The file-output atomics.** `040_fwrite.va`, `041_fstrobe.va`,
`042_fmonitor.va`, `043_fdebug.va`, `044_swrite.va` and `045_sformat.va` are not
xfail, and the four file ones call `$fopen` on a descriptor that is a constant
zero. They pass because what each one asserts is the *argument value* handed to
the format — `V(p,n)` at the operating point — and never a byte reaching a file.
That is a deliberate, stated choice in each header, not an oversight, so §9.5.2
still has four green fixtures and no evidence that the task produces output.
§9.5.3 is no longer in that position: `044`/`045` still assert only the argument,
but `06` and `09` read the formatted TEXT back through `$sscanf`.

**The node-alias positives.** `30_node_alias_calls.va`, `105` and `106` pass,
and `141`–`146` now reject, but the positives still pass for a reason narrower
than the rule. All three
positives use hierarchical reference strings (`"$root.top.n"`) that cannot
resolve in a single-module compilation, so §9.20's "shall be zero otherwise"
answer *is* zero — which is also what VerA's constant-0 return gives. The right
answer for the wrong reason, and the reason the matrix-position merge itself is
not implemented: a flat elaboration has no instance hierarchy for a
`hierarchical_reference_string` to resolve INTO, so there is no second position
to merge with and no fixture that can observe one. `30`'s own header says so, and
explicitly disclaims the last-call-wins precedence rule that its two sequential
assignments might be misread as testing.

## What the previous file claimed that is not true

Recorded so it is not re-derived. The old table credited `03_display_write.va`
with §9.4.7 (its `%r` is the analog Table 9-23 specifier, not the digital-context
extension); credited `31_driver_access.va` with §9.23.1–§9.23.4 (its body has
only the three §9.22 names); credited `15_conversion_functions.va` with `$rtoi`,
`$itor`, `$signed` and `$unsigned` (the file now tests only the
`$bitstoreal`/`$realtobits` pair and says so); invented a subclause "9.22.2
`$receiver_count`" and a "9.22.7", neither of which exists — the real §9.22.2 is
`$driver_state`; and described `$param_given` as comparing a value against its
default, which `codegen.zig` no longer does. Its two closing inventories listed
several dozen file names that no longer exist under those names, and duplicated
the ones that do.
