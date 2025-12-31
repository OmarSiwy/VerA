# Chapter 9 coverage

Source: `docs/VAMS-LRM/ch9-system.html`, read section by section.

HTML section-ID audit: `s9.1` `s9.2` `s9.3` `s9.4` `s9.4.1` `s9.4.2` `s9.4.3` `s9.4.4` `s9.4.5` `s9.4.6` `s9.4.7` `s9.5` `s9.5.1` `s9.5.1.1` `s9.5.1.2` `s9.5.2` `s9.5.3` `s9.5.4` `s9.5.4.1` `s9.5.4.2` `s9.5.5` `s9.5.6` `s9.5.7` `s9.5.8` `s9.5.9` `s9.6` `s9.7` `s9.7.1` `s9.7.2` `s9.7.3` `s9.8` `s9.9` `s9.10` `s9.11` `s9.12` `s9.13` `s9.13.1` `s9.13.2` `s9.13.3` `s9.14` `s9.15` `s9.16` `s9.17` `s9.17.1` `s9.17.2` `s9.17.3` `s9.18` `s9.19` `s9.20` `s9.21` `s9.21.1` `s9.21.2` `s9.21.3` `s9.21.4` `fn9.21.4-1` `s9.21.5` `s9.22` `s9.22.1` `s9.22.2` `s9.22.3` `s9.22.4` `s9.22.5` `s9.22.6` `s9.23` `s9.23.1` `s9.23.2` `s9.23.3` `s9.23.4`.

Sixty-eight ids, forty-six of them carrying a fixture that exercises the
construct. The other twenty-two get an empty cell and a sentence saying why,
never a plausible file name.

164 `.va` files and one data file (`ch09_table_model_2d.tbl`). **Eighty of the
164 are `//! xfail`** — this is by a wide margin the most indebted chapter in
the suite, and that ratio is the honest headline, not a footnote. Thirty-six
fixtures carry `//! reject`; thirty-two of those thirty-six are *also* xfail,
which is to say VerA currently accepts nine tenths of what this chapter forbids.
The four rejects it does meet are `136`/`137` (`$bound_step` E0803/E0802) and
`138`/`139` (`$discontinuity` E0804/E0805).

Reading the table: **xfail** on a fixture means the file runs and fails, and the
reason on that row is the defect. A row whose fixtures are *all* xfail is a
section the suite states and the compiler does not meet — there is no passing
evidence behind it. §9.4.2, §9.4.3, §9.5.1, §9.5.4.1, §9.5.4.2, §9.5.5, §9.5.6,
§9.5.7, §9.5.8, §9.6, §9.8, §9.9, §9.13.1, §9.13.2, §9.16, §9.21, §9.21.1,
§9.21.5, §9.22.x and §9.23.x are all in that state.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s9.1` | overview; the clause is organised by the 9.2 categories | — umbrella, no rule to test |
| `s9.2` | Tables 9-1…9-20, the analog-context Yes/No column | Yes rows: `05_display_debug.va`, `059_warning.va`, `060_info.va`, `063_realtobits.va`, `064_bitstoreal.va`, `065_test_plusargs.va`, `066_value_plusargs.va`. No rows: `061`, `062`, `134`, `135`, `148`, `149`, `153` — all **xfail**, *VerA implements no analog-context check for any Chapter 9 system task; a grep across `src/` finds none* |
| `s9.3` | how a task behaves across accepted vs. rejected solver iterations | — no fixture. Accept/reject is a kernel property the generated device cannot observe |
| `s9.4` | display task family | — parent; carried by 9.4.1–9.4.3 below |
| `s9.4.1` | `$strobe` `$display` `$write` `$monitor` `$debug` in the analog context | `01_display_strobe.va`, `02_display_display.va`, `03_display_write.va`, `04_display_monitor.va`, `05_display_debug.va` (each pins the argument *value*, since the transcript is not observable from inside the model); `06_display_formats.va` — **xfail**, *`%c` does not compile: `cg_display.zig` appendConv maps it to Zig verb `c` with `want=.int` and hands `std.fmt` an i64 where `{c}` takes a u8, so any `$display` carrying a Table 9-22 `%c` kills the generated testbench*; `152_display_radix_variants_analog_rejected.va` (`$displayb/h/o`, `$strobeb`, `$writeh`, `$monitorb`, `$monitoron/off`) — **xfail**, *no Table 9-1 analog-context restriction*; `161_display_argument_pairing_rejected.va` — **xfail**, *VerA does not check the `%` count in a format string against the argument list* |
| `s9.4.2` | Table 9-21 escapes `\ddd` `\t` `\\` `\"` | `06_display_formats.va` — **xfail**, see above; nothing else carries a single-backslash escape outside a file-I/O path name |
| `s9.4.3` | Table 9-22/9-23 format specifications and `width.precision` | `06_display_formats.va`, `09_string_formatting.va`, `161_…_rejected.va` — **all three xfail**. `06`'s `%h`/`%o` round trips through `$sformat`+`$sscanf` are the only digit-level assertions on a base in the chapter, and `void_tasks` lowers both halves to `S.con(0.0)` |
| `s9.4.4` | `%m` prints the hierarchical name and takes no argument | — no fixture cites it. `%m` appears in `06_display_formats.va`'s second `$display` and in `161`, both unasserted (a transcript is not a value), and `06` does not compile |
| `s9.4.5` | `%s` prints ASCII codes as characters | — same: `%s` sits in `06`'s first `$display` and in `162`'s scan string, neither asserting the right-justification/leading-zero rule this subclause is actually about |
| `s9.4.6` | no display output except `$debug` unless the iteration is accepted | — no fixture. `043_fdebug.va` quotes the rule in its header and does not test it; the harness runs one accepted solve |
| `s9.4.7` | `%r`/`%R` on reals **in the digital context** | — no fixture. The `%r` in `03_display_write.va` and `06` is the Table 9-23 *analog* engineering-notation specifier; Verilog-A has no digital context for this extension to apply to |
| `s9.5` | file-I/O family, Table 9-2 | `153_file_io_digital_only_analog_rejected.va` (`$fdisplayb`, `$fwriteh`, `$fstrobeo`, `$fmonitorb`, `$swriteh`, `$fgetc`, `$ungetc`, `$fread`, `$readmemb`, `$sdf_annotate`) — **xfail**, *no Table 9-2 analog-context restriction* |
| `s9.5.1` | `$fopen` descriptor forms, `$fclose` | `07_file_open_close.va`, `08_file_output.va`, `039_fdisplay.va`, `047_fscanf.va`, `052_fflush.va`, `053_ferror.va`, `10_file_read_scan.va`, `11_file_position_status.va`, `158_fopen_multichannel_descriptor.va` — **all nine xfail**, one shared cause: *`codegen.zig` `void_tasks` lowers the whole §9.5 family to the constant `S.con(0.0)`, so `$fopen` answers 0 — bit 31 clear and channel 0. `lower.zig:2362` states the reason: the file family "needs a descriptor the compiled device has no way to own"* |
| `s9.5.1.1` | reopening a write-mode file across analyses appends | — no fixture. Needs two analyses in one process, which the harness does not run |
| `s9.5.1.2` | analog/digital descriptor sharing | — no fixture; mixed-signal runtime policy, no Verilog-A source form |
| `s9.5.2` | `$fdisplay` `$fwrite` `$fstrobe` `$fmonitor` `$fdebug` | `040_fwrite.va`, `041_fstrobe.va`, `042_fmonitor.va`, `043_fdebug.va` pass — but each pins only the *argument value* handed to `%g`, never a byte in a file; `039_fdisplay.va` and `08_file_output.va` — **xfail**, *same `void_tasks` constant; `lower.zig:2365` excludes them from `isDisplayTask` so unlike `$display` they never reach `cg_display.zig` at all* |
| `s9.5.3` | `$swrite` and `$sformat` | `044_swrite.va`, `045_sformat.va` pass on the argument value only; `06_display_formats.va` and `09_string_formatting.va` — **xfail**, *`$swrite`/`$sformat` lower to `S.con(0.0)`, so the destination string is never written* |
| `s9.5.4` | files are readable only if opened `r`/`r+` | — no fixture; there is no descriptor to open in the wrong mode |
| `s9.5.4.1` | `$fgets` | `046_fgets.va` — **xfail**, *`$fopen` answers 0 and `$fgets` reads nothing and returns 0* |
| `s9.5.4.2` | `$fscanf` and `$sscanf` | `047_fscanf.va`, `048_sscanf.va`, `162_sscanf_conversion_rules.va`, `06`, `09`, `10_file_read_scan.va` — **all six xfail**. `048`/`162` isolate the formatter from the descriptor: they touch no filesystem, and *`$sscanf` still lowers to `S.con(0.0)`, returning 0 and never writing its output argument*. `047` notes that its missing-file half passes by accident |
| `s9.5.5` | `$ftell` `$fseek` `$rewind` | `049_ftell.va`, `050_fseek.va`, `051_rewind.va`, `11_file_position_status.va` — **all four xfail**, *every positioning answer is the same constant 0, so a moved and an unmoved pointer are indistinguishable* |
| `s9.5.6` | `$fflush` | `052_fflush.va` — **xfail**, *no-op returning 0* |
| `s9.5.7` | `$ferror` | `053_ferror.va` — **xfail**, *`$fopen` reports failure (fd 0) while `$ferror` simultaneously reports no error — a file that could not be opened raising none* |
| `s9.5.8` | `$feof` | `054_feof.va`, `11_file_position_status.va` — **xfail**, *0 whether or not a read has hit the end* |
| `s9.5.9` | file position rolled back on a rejected iteration; `$fdebug` excepted | — no fixture. Requires a rejected iteration and a real descriptor; neither exists |
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
| `s9.13.1` | `$random` and `$arandom`, seeded and unseeded | `32_random.va`, `33_arandom.va`, `115_random_no_seed.va`, `116_arandom_no_seed.va`, `117_arandom_parameter_seed.va`, `118_arandom_negative_seed.va` — **xfail**, *VerA refuses the whole §9.13 family with E0801 rather than stubbing a seeded RNG stream; Table 9-10 marks all seventeen names analog-context Yes*. `132_arandom_type_string_outside_paramset_rejected.va` — **xfail**, *E0801 fires at the name, so the paramset-only `type_string` scope rule is never reached* |
| `s9.13.2` | seven `$dist_*` and six `$rdist_*` names | `34_distribution.va`, `35_real_distribution.va`, `119`–`130` (one file per name) — **all xfail on the same E0801**. Argument-rule negatives `150_rdist_domain_rejected.va`, `151_rdist_uniform_start_end_rejected.va`, `166_rdist_real_seed_rejected.va`, `133_rdist_type_string_outside_paramset_rejected.va` — **xfail**, *E0801 fires at the function name, so no argument is ever examined and the domain, start/end and integer-seed rules are not reached* |
| `s9.13.3` | Table 9-26 cross-listing to the 1364 C algorithms | — no fixture claims a distribution's shape. Nothing could: every call is refused at the name |
| `s9.14` | math system functions | Twenty-seven atomics `067`–`093` plus `17_math_unary.va`, `18_math_trig.va`, `19_math_binary.va`, `20_math_2023.va`. Two of the atomics are **xfail**: `092_ln1p.va` — *`codegen.zig` `zLn1p` is `a.addC(1.0).log()`, so `$ln1p(5e-16)` returns 4.440892098500625e-16, 11% low — precisely the naive value Table 4-14's C `log1p` exists to replace* — and `093_expm1.va` — *`zExpm1` is `a.exp().addC(-1.0)`, same 11% error for the same reason* |
| `s9.15` | `$temperature` `$vt` `$simparam` `$simparam$str` | `21_temperature_vt.va`, `094_temperature.va`, `095_vt_ambient.va`, `096_vt_temperature.va` (all `//! temp`-driven), `22_simparam.va` (unknown name returns its fallback verbatim), `23_simparam_string.va`. Two **xfail**: `147_simparam_unknown_no_fallback_rejected.va` — *VerA answers every unknown `$simparam` with a default instead of diagnosing the missing-fallback case* — and `157_simparam_timescale.va` — *`` `timescale `` is not threaded into `$simparam`; `"timeUnit"`/`"timePrecision"` have no fallback here and both come back 0.0* |
| `s9.16` | `$simprobe(inst_name, param_name [, expr])` | `36_simprobe.va` — **xfail**, *E0801: no sibling-instance host to probe; Table 9-13 marks it analog-context Yes* |
| `s9.17` | analog kernel control family | — parent; carried by 9.17.1–9.17.3 |
| `s9.17.1` | `$discontinuity`, degree `0` and `-1` | `24_discontinuity.va`; `138_discontinuity_arity_rejected.va` (E0804) and `139_discontinuity_nonconstant_rejected.va` (E0805) — **rejects VerA already meets** |
| `s9.17.2` | `$bound_step` | `25_bound_step.va` (`//! analysis tran`); `136_bound_step_negative_rejected.va` (E0803) and `137_bound_step_arity_rejected.va` (E0802) — **rejects VerA already meets** |
| `s9.17.3` | `$limit`, all three Syntax 9-12 forms | Forms one and two pass: `26_limit.va` (`$limit(V(p,n))`), `27_limit_named.va` (`$limit(V(p,n), "pnjlim", $vt, 0.7)`). Form three does not: `156_limit_user_function.va` — **xfail**, *an `analog_function_identifier` as the second argument is E0314 `unknown identifier`, because the name is looked up as a value rather than as the limiter* — and its negative `164_limit_user_function_output_arg_rejected.va` — **xfail**, *the same E0314 fires at the call site, so the "shall all be declared input" rule on the limiter's formals is never examined* |
| `s9.18` | `$mfactor` `$xposition` `$yposition` `$angle` `$hflip` `$vflip` | `28_hierarchical_parameters.va` plus atomics `097`–`102`, one per name. `163_aliasparam_mfactor.va` — **xfail**, *`aliasparam m = $mfactor;` is E0208 `expected an identifier`, so §3.4.7's own printed example does not parse* |
| `s9.19` | `$param_given` and `$port_connected` | `29_binding_detection.va`, `103_param_given.va` (overridden), `159_param_given_not_overridden.va` (the 0 direction, one deleted `//! param` line away), `165_param_given_override_equals_default.va` (override *equal to* the default is still an override — the input that separates a flag from a value comparison, and VerA now carries a real `__given` flag, `codegen.zig:867`), `104_port_connected.va` |
| `s9.20` | `$analog_node_alias` / `$analog_port_alias` | `30_node_alias_calls.va`, `105_analog_node_alias.va`, `106_analog_port_alias.va` pass — see the note below on *why* they pass. Six negatives, **all xfail**: `141` (outside `analog initial`), `142` (first argument a port), `144` (non-constant string), `145` (duplicate target), `146` (inside a conditional) — *VerA lowers both functions to a constant 0 with no inspection of the call site, the arguments, the guard, or any other call* — and `143` (bit-select) — *`electrical [3:0] bus;` is E0208 at the declaration, so the §9.20 bit-select rule is never reached at all* |
| `s9.21` | `$table_model` | `37_table_model.va` (file-backed, with `ch09_table_model_2d.tbl`), `131_table_model_array_control.va` (array-backed), `155_table_model_lrm_sample_set.va` — **all three xfail**, *E0801: VerA has no isoline interpolator; Table 9-18 marks `$table_model` analog-context Yes* |
| `s9.21.1` | data source: file or real arrays | Both forms present and both **xfail**: `37` supplies `"ch09_table_model_2d.tbl"`, `131` supplies independent/dependent real arrays |
| `s9.21.2` | control-string grammar | — the strings are in the source (`"1LL,1LL;1"` in `37`, `"1LL;1"` in `131`) but E0801 fires at the function name first, so no substring, dimension order or dependent selector is ever parsed |
| `s9.21.3` | Table 9-32 example control strings | — same. `37`'s `"1LL,1LL;1"` is verbatim a Table 9-32 row; nothing reads it |
| `s9.21.4` | closest-point, linear and cubic-spline interpolation | — no interpolation is performed anywhere in this folder. `155` is the fixture that *would* serve this row: it recomputes Figure 9-2's `f(3.5, 0.25) = 2.0` by hand from the printed twelve-row sample set under the default linear rule. It never runs |
| `fn9.21.4-1` | bibliography footnote for cubic splines | — informative; no language rule |
| `s9.21.5` | the LRM's own worked example | `155_table_model_lrm_sample_set.va` — **xfail**, same E0801. This is the only place in the chapter where the LRM supplies its own oracle (data, query point *and* answer), and it is the only place the compiler cannot reach |
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
before reading it as debt.

**No descriptor table (17 fixtures).** `codegen.zig` `void_tasks` lowers every
§9.5 name — `$fopen`, `$fclose`, the five output tasks, `$fgets`, `$fscanf`,
`$sscanf`, `$swrite`, `$sformat`, `$ftell`, `$fseek`, `$rewind`, `$fflush`,
`$ferror`, `$feof` — to the constant `S.con(0.0)`. `lower.zig:2362` writes the
reason down: the family "needs a descriptor the compiled device has no way to
own". One change closes §9.5.1 through §9.5.8 at once. Note that `048_sscanf.va`
and `162_sscanf_conversion_rules.va` are *behind a different wall wearing the
same coat*: they touch no filesystem, so what they need is a formatter, not a
descriptor table, and they would still fail the day descriptors land.

**No RNG (25 fixtures).** `$random`, `$arandom`, seven `$dist_*` and six
`$rdist_*` are all E0801 at the function name. Because the refusal is at the
name, the four argument-rule negatives (`150`, `151`, `166`, and the paramset
scope pair `132`/`133`) are xfail for a *second-order* reason: they are waiting
on the family to be accepted before their own rule can be tested. Fixing E0801
without fixing the argument checks converts four xfails into four failures.

**No analog-context table (11 fixtures).** Tables 9-1, 9-2, 9-3, 9-5, 9-6, 9-7,
and 9-8 each have a "No" column, and VerA implements none of it — `061`, `062`,
`134`, `135`, `148`, `149`, `152`, `153`, `154` are the inventory, plus `140`
(`$stop` by block kind) and `161` (format/argument pairing). This is the
cheapest wall in the chapter: it is a lookup table and a diagnostic, not a
runtime feature, and it retires eleven rows.

**No hierarchy (19 fixtures).** VerA compiles one flat module. That takes out
§9.22/§9.23 wholesale (`31`, `107`, `109`–`114`, `38`), `$simprobe` (`36`),
`$table_model`'s three (`37`, `131`, `155`, which need an interpolator rather
than hierarchy but are equally out of reach), and the six §9.20 negatives, whose
alias functions return a constant 0 without looking at anything.

The tail is eight single-cause fixtures: `06` (`%c` type error in
`cg_display.zig`), `092`/`093` (naive `log1p`/`expm1`), `156`/`164`
(`$limit` form three), `157` (`` `timescale `` not threaded into `$simparam`),
`147` (no missing-fallback diagnostic) and `163` (`aliasparam` will not take a
system function). Each is a single edit in a single file.

## Two places where "passes" is narrower than it looks

**The file-output atomics.** `040_fwrite.va`, `041_fstrobe.va`,
`042_fmonitor.va`, `043_fdebug.va`, `044_swrite.va` and `045_sformat.va` are not
xfail, and they call `$fopen` on a descriptor that is a constant zero. They pass
because what each one asserts is the *argument value* handed to the format —
`V(p,n)` at the operating point — and never a byte reaching a file or a string.
That is a deliberate, stated choice in each header, not an oversight, but it
means §9.5.2 and §9.5.3 have six green fixtures and no evidence that either task
produces output.

**The node-alias positives.** `30_node_alias_calls.va`, `105` and `106` pass
while `141`–`146` fail on the same lowering. The reason is that all three
positives use hierarchical reference strings (`"$root.top.n"`) that cannot
resolve in a single-module compilation, so §9.20's "shall be zero otherwise"
answer *is* zero — which is also what VerA's unconditional constant-0 stub
returns. The right answer for the wrong reason. `30`'s own header says so, and
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
