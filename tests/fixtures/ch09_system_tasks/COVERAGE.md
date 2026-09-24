# Chapter 9 coverage

Audit checkpoint, 2026-09-23: `docs/conformance-ch9-review.md` supersedes
blanket conversion and binding claims below. New source-level named, ordered
and defparam overrides (including equal-to-default values), and nested
omitted/connected ports, have direct behavioral checks. Invalid variable/net
argument kinds are wrongly accepted and recorded as BIND-ARG-001/002 XFAILs.
Runtime signed conversion passes the new observations; legal constant defaults
fail as CONV-CONST-001. The 063 bit-pattern oracle now compares explicitly
sized patterns and checks Boolean results, avoiding unsized-width assumptions.
These bounded tests do not close every rule of §9.11 or §9.19.

Source: `docs/ch9-system.html`, read section by section.

HTML section-ID audit: `s9.1` `s9.2` `s9.3` `s9.4` `s9.4.1` `s9.4.2` `s9.4.3` `s9.4.4` `s9.4.5` `s9.4.6` `s9.4.7` `s9.5` `s9.5.1` `s9.5.1.1` `s9.5.1.2` `s9.5.2` `s9.5.3` `s9.5.4` `s9.5.4.1` `s9.5.4.2` `s9.5.5` `s9.5.6` `s9.5.7` `s9.5.8` `s9.5.9` `s9.6` `s9.7` `s9.7.1` `s9.7.2` `s9.7.3` `s9.8` `s9.9` `s9.10` `s9.11` `s9.12` `s9.13` `s9.13.1` `s9.13.2` `s9.13.3` `s9.14` `s9.15` `s9.16` `s9.17` `s9.17.1` `s9.17.2` `s9.17.3` `s9.18` `s9.19` `s9.20` `s9.21` `s9.21.1` `s9.21.2` `s9.21.3` `s9.21.4` `fn9.21.4-1` `s9.21.5` `s9.22` `s9.22.1` `s9.22.2` `s9.22.3` `s9.22.4` `s9.22.5` `s9.22.6` `s9.22.7` `s9.23` `s9.23.1` `s9.23.2` `s9.23.3` `s9.23.4`.

Sixty-nine ids, forty-six of them carrying a fixture that exercises the
construct. The other twenty-three get an empty cell and a sentence saying why,
never a plausible file name. (`s9.22.7` was missing from this audit until the
chapter HTML was corrected against the 2023 PDF; the 2.4 text numbered §9.22
without it. That same renumbering left three fixtures' `//! lrm` lines one
number BEHIND the row they belong to — `38` cited 9.22.4, `109` cited 9.22.2 and
`110` cited 9.22.3 while this file, and the corrected chapter, already had them
at 9.22.5, 9.22.3 and 9.22.4. All three `//! lrm` lines are corrected; their
header prose, which quotes the same numbers in the 2.4 index, is left as written
and says so in the rows below.)

213 `.va` fixtures: 161 execute, 52 expect rejection, and 4 are marked xfail. (The
number was 208 before `061`/`062` were deleted; the a05/d09/s01 fixtures
arriving in this folder from the table-model and format work are theirs to
count, and this line does not. The four xfails are new, they are the last four
rows of the table, and they are not walls — each names the single missing piece
it waits on and turns hard XPASS the day that piece lands.)
This is a fixture inventory, not a conformance percentage. Unsupported-feature
rejections and untested legal forms leave their requirements open.

Rejection fixtures exercise these diagnostics: `136`/`137` (`$bound_step` E0803/E0802), `138`/`139`
(`$discontinuity` E0804/E0805), `147` (§9.15 `$simparam` on an unknown name with no
fallback), `161` (§9.4.3 format/argument pairing), the six §9.20 alias negatives `141`–`146`
(E0812), the seven analog-context negatives `134`/`135`/`148`/`149`/`152`/`153`/
`154` (each pinning the substring `analog context`), `140` (`$stop` by block kind), the four
`$random` argument rules (E0816), `164` (E0814) and the eight §9.22/§9.23 driver-access
call-site refusals (E0818), and `169` (E0813 — §9.5.4.2's scan codes are lower case, so
`%D` is refused rather than silently scanning nothing). `193` is the one rejection
fixture here whose substring is `digital context` rather than `analog context`, and it
is xfail because VerA's refusal comes from §7.2.2's `initial`-block model (E0433) and
never says so.

A passing row records only the behavior its assertions exercise. It does not
close all of the cited clause. Runtime facilities, accepted/rejected side effects,
digital-context tasks and the distribution limits below still need work.

| HTML id | Rule | Fixtures |
|---|---|---|
| `s9.1` | overview; the clause is organised by the 9.2 categories | — umbrella, no rule to test, and its one assertable sentence cannot be pinned without contradicting the clause it cites. "Verilog-AMS HDL is a superset of IEEE Std 1364 Verilog and hence all the system tasks in IEEE Std 1364 Verilog are supported" is a claim about the §9.2 TABLES, and every one of them answers No for at least one 1364 name in the analog context — so the fixture would be `153`'s file, not this one |
| `s9.2` | Tables 9-1…9-20, the analog-context Yes/No column | Yes rows: `05_display_debug.va`, `059_warning.va`, `060_info.va`, `063_realtobits.va`, `064_bitstoreal.va`, `065_test_plusargs.va`, `066_value_plusargs.va`. No rows: `134`, `135`, `148`, `149`, `153` — all green, each pinning the substring `analog context`. The check exists now; it was the cheapest wall in the chapter and it is down. Two rows left this inventory when the chapter HTML was corrected against the 2023 PDF — `061`/`062` pinned analog "No" cells for `$rtoi`/`$itor` that Table 9-8 does not have. See `s9.11` below |
| `s9.3` | how a task behaves across accepted vs. rejected solver iterations | — no fixture, and neither paragraph leaves one to write. The iteration half is a property of the KERNEL: the rule is that a rejected iteration must leave no side effect, and a generated device cannot see a rejection to assert about (the same ceiling `s9.4.6` and `s9.5.9` sit under). The multiple-analyses half needs two analyses in one process, and this harness runs one per file — `Directives.analysis` is a single enum, so a second `//! analysis` line is silently overwritten rather than refused, which makes a fixture that tried it WORSE than no fixture |
| `s9.4` | display task family | — parent; carried by 9.4.1–9.4.3 below |
| `s9.4.1` | `$strobe` `$display` `$write` `$monitor` `$debug` in the analog context | `01_display_strobe.va`, `02_display_display.va`, `03_display_write.va`, `04_display_monitor.va`, `05_display_debug.va` (each pins the argument *value*, since the transcript is not observable from inside the model); `06_display_formats.va` — green; Table 9-22's `%c` compiles (it used to be mapped to Zig verb `c` with `want=.int`, handing `std.fmt` an i64 where `{c}` takes a u8, which killed the generated testbench); `152_display_radix_variants_analog_rejected.va` (`$displayb/h/o`, `$strobeb`, `$writeh`, `$monitorb`, `$monitoron/off`) — green, `analog context`; `161_display_argument_pairing_rejected.va` — green, `format specifier`: the `%` count in a format string is checked against the argument list; `170_display_argument_runs.va` — green, the argument-list model itself at digit level: every string argument is its own format run, literal-only runs preserve subsequent formats, and explicit %0d conversions concatenate without inserted separators; bare-operand/default-width claims moved to `audit_integer_default_fields.va` (FMT-WIDTH-001) (each pinned by `$sformat` + a string comparison, so the transcript IS the `ok=` value) |
| `s9.4.2` | Table 9-21 display escapes | `test-literal-output` checks exact generated-host bytes, including NUL, octal escapes and included macros. `188` verifies literal file bytes through numeric character reads. Direct output preserves NUL; string storage removes it. Other escape/format combinations still need systematic qualification. |
| `s9.4.3` | Table 9-22/9-23 format specifications and `width.precision` | `06_display_formats.va`, `09_string_formatting.va` pass; `161_…_rejected.va` rejects at E0810. `06`'s `%h`/`%o` round trips through `$sformat`+`$sscanf` are the only digit-level assertions on a base in the chapter, and they are now real: the formatter writes into `zSBuf(<site>)` and `zScan` reads the digits back (`lib/backend/str_kernels.zig`). `168_display_library_binding.va` uses that same round trip to pin the third member of the no-argument set, `%l`: an operand eaten for it shifts every later conversion left by one, which the two integers either side of it now catch. `171_display_c_format_flags.va` pins Table 9-23's "full formatting capabilities available in the C language" with string comparisons against hand-derived C output: `%e`'s default `1.500000e+00` (precision 6, signed two-digit exponent), `%10.4e`, `%05d`/`%+05d` zero-fill AFTER the sign, `%+d`/`% d` sign flags, and `%h` of a negative as the operand's 64-bit two's-complement pattern |
| `s9.4.4` | `%m` prints the hierarchical name and takes no argument | `192_m_format_hierarchical_name.va` — **green**, and it pins the EXPANSION rather than a transcript: `$sformat` (§9.5.3) puts it in a `string` and the `ok=` is a comparison against the literal, the trick `170` and `168` use. Three assertions, one per half of the clause: `%m` alone is the invoking module's own name; `%m%d` with `7` gives the name followed by `7`, so `%m` ate no operand; and `%d%m` gives `7` followed by the name, which is the direction that separates "takes no argument" from "swallows the argument after it" — the failure mode `168` catches for `%l`. `06_display_formats.va`'s second `$display` carries a `%m` too and is still unasserted (a transcript is not a value) |
| `s9.4.5` | `%s` prints ASCII codes as characters | `188` and `test-literal-output` verify numeric byte order, supported widths, leading-only zero suppression, raw interior/trailing NUL, padding and file/string output. String storage removes NUL after formatting under §3.3; former stored-NUL expectations were incorrect and are replaced with raw-output checks. Real operands and general digital packed expressions remain open. |
| `s9.4.6` | no display output except `$debug` unless the iteration is accepted | — no fixture. `043_fdebug.va` quotes the rule in its header and does not test it; the harness runs one accepted solve |
| `s9.4.7` | `%r`/`%R` on reals **in the digital context** | — no fixture. The `%r` in `03_display_write.va` and `06` is the Table 9-23 *analog* engineering-notation specifier; digital-context formatting remains an open full-AMS coverage requirement |
| `s9.5` | file-I/O family, Table 9-2 | `153_file_io_digital_only_analog_rejected.va` (`$fdisplayb`, `$fwriteh`, `$fstrobeo`, `$fmonitorb`, `$swriteh`, `$fgetc`, `$ungetc`, `$fread`, `$readmemb`, `$sdf_annotate`) — green, `analog context` |
| `s9.5.1` | `$fopen` descriptor forms, `$fclose` | `07_file_open_close.va`, `08_file_output.va`, `039_fdisplay.va`, `047_fscanf.va`, `052_fflush.va`, `053_ferror.va`, `10_file_read_scan.va`, `11_file_position_status.va`, `158_fopen_multichannel_descriptor.va` — **all nine pass**, and both descriptor shapes are pinned at the bit: an fd with bit 31 set and a channel number above the three pre-opened streams, an mcd with bit 31 clear and exactly one bit set that is not bit 0, and 0 for a missing file opened `r`/`r+`. `$fclose` frees the channel, which `158` observes through the reuse §9.5.1 requires |
| `s9.5.1.1` | reopening a write-mode file across analyses appends | — no fixture, and the reason is stronger than "not written yet": the rule's whole subject is the SECOND analysis, the harness runs one per file, and the second `//! analysis` line is dropped in silence (`Directives.analysis` is a single enum) — so a file written for this row would test one analysis and call the answer two. It needs a host that runs two analyses in one process, which is `Directives`' shape to change and not this folder's |
| `s9.5.1.2` | analog/digital descriptor sharing | `194_file_descriptor_shared_across_contexts.va` — **xfail**, and the previous cell's claim ("mixed-signal runtime policy, no Verilog-A source form") is WITHDRAWN: the clause is one sentence of permission with a source form, and the smallest design that needs the permission is an `initial` block (the digital context, §7.2.2) opening a file for writing and an `analog` block writing through the descriptor it was handed. Neither half exists: `fd = $fopen(...)` in an `initial` block is E0433 (§7.2.2's constant-assignment model), and `src/sim/digital.zig` implements none of §9.5, so there is no digital file table for a descriptor to be portable between. The assertions are the ones the analog-only half of the file already produces — `$fgets` returns 2 for the two bytes `42` with no newline, and the string comparison reads them back — so what the xfail records is the sharing and not a number |
| `s9.5.2` | `$fdisplay` `$fwrite` `$fstrobe` `$fmonitor` `$fdebug` | `040_fwrite.va`, `041_fstrobe.va`, `042_fmonitor.va`, `043_fdebug.va`, `039_fdisplay.va`, `08_file_output.va` all pass. Each of the atomics still pins only the *argument value* handed to `%g` — a byte in a file is not readable from inside the model — but the BYTES are now pinned indirectly, and exactly where they can be: `046`/`049`/`050`/`051`/`054`/`11` write with `$fwrite` and read the result back, so the four-byte line and the positions after it are assertions about what the writer actually put there. §9.5.2's "the same type of arguments as the tasks upon which they are based" is literal in the emitter: the formatter is `emitDisplayTask`'s, over the arguments after the descriptor, with §9.4.1's newline rule applied to the base name so `$fwrite` does not end the line |
| `s9.5.3` | `$swrite` and `$sformat` | `044_swrite.va`, `045_sformat.va` pass on the argument value only (their `text` is never read back); `06_display_formats.va` and `09_string_formatting.va` pass on the TEXT, by sending it back through `$sscanf` — lowering makes both writers an assignment to the named string variable, not a void call, so a formatter that wrote nothing would now fail them |
| `s9.5.4` | files are readable only if opened `r`/`r+` | — no fixture; there is no descriptor to open in the wrong mode |
| `s9.5.4.1` | `$fgets` | `046_fgets.va` passes on the sentence that distinguishes it from C: the newline is "read AND transferred to str", so a four-byte line returns 4 and not 3. `049`/`051`/`054`/`11` read the same line for its side effect on the position |
| `s9.5.4.2` | `$fscanf` and `$sscanf` | `048_sscanf.va`, `162_sscanf_conversion_rules.va`, `06`, `09`, `10_file_read_scan.va` pass — `$sscanf` is `zScan` (suppression `*`, maximum field width, early matching failure, EOF, and the ten conversion codes), and each output argument is its own assignment from a `$sscanf$<ty>` item call. `047_fscanf.va` passes too, on both halves it was written to separate: 0 for the missing file, and `code == 1` with `value == 42` for a file it writes itself. `$fscanf` is the SAME scanner — `zScan` over one line the file kernels read — because §9.5.4.2 states one set of conversion rules for both spellings. `169_sscanf_uppercase_conversion_rejected.va` pins the CASE of those codes: Table 9-22 spells the display conversions twice (`%h or %H`), §9.5.4.2's code table spells the scan codes once, and `zScan` compares the raw byte |
| `s9.5.5` | `$ftell` `$fseek` `$rewind` | `049_ftell.va`, `050_fseek.va`, `051_rewind.va`, `11_file_position_status.va` — **all four pass**, and each asserts a MOVED and an unmoved pointer so the two cannot be confused: 0 then 4 across a `$fgets`, 4 after `$fseek(fd,0,2)` on a four-byte file, 0 after `$rewind`, and the status half separately (0, not the new position). The position is the kernels' own quantity and every read is positional, which is what makes `$ftell` exact after a read that stopped at a newline |
| `s9.5.6` | `$fflush` | `052_fflush.va` passes on what §9.5.6 leaves observable — the descriptor it is handed. The task itself is genuinely a no-op and says so: every write goes positionally straight to the descriptor, so there is never buffered output to flush |
| `s9.5.7` | `$ferror` | `053_ferror.va` passes in both directions, which is the point of it: zero errno and an EMPTY description after a successful open, a nonzero errno after one that failed. The errno's numeric value is deliberately unasserted — §9.5.7 says only "an error code is returned" |
| `s9.5.8` | `$feof` | `054_feof.va`, `11_file_position_status.va` pass. `054` puts the descriptor in both states in turn — zero until a read detects EOF, nonzero after the read that runs off the end — and it takes TWO `$fgets` to get there, because the first stops at the newline and need not have touched the end |
| `s9.5.9` | file position rolled back on a rejected iteration; `$fdebug` excepted | — no fixture. The descriptor is real now, but the harness runs one accepted solve per point, so there is no rejected iteration to roll back. The rule is nevertheless what the implementation is BUILT on: every §9.5 call is sequenced in the per-accepted-point phase (`codegen.Gen.emitting_display`) and none of them runs inside `eval`, so a rejected Newton iteration cannot have written anything to undo |
| `s9.6` | `$printtimescale` `$timeformat`, analog "No" | `154_timescale_pla_queue_analog_rejected.va` — green, `analog context`. This section is no longer all-negative-and-unmet |
| `s9.7` | simulation control family | `193_severity_task_digital_context_rejected.va` — **xfail**. The parent is no longer only a pointer: §9.7's third paragraph and Table 9-4 give the four severity tasks a digital "Yes" and an analog "No", so a source that calls `$fatal`/`$error`/`$warning`/`$info` from the DIGITAL context is asking for the one column the table grants — the exact mirror of `153`, which pins the analog "No" with the substring `analog context`. VerA refuses the file, but by neither rule: the `initial` block is E0433 (§7.2.2's constant-assignment model), which names no context and cites §9.2/§9.7 nowhere, so the fixture pins the LRM's vocabulary (`digital context`) and stays xfail rather than freezing VerA's own wording as a conformance requirement. `9.7.1`–`9.7.3` still carry the family's accepted side |
| `s9.7.1` | `$finish` and its optional diagnostic level | `055_finish.va`, `12_finish_stop.va` (the guarded, not-reached half); `172_finish_terminates.va` executes it — the run exits after the accepted point, before the sweep's second point can print its deliberate `ok=0` |
| `s9.7.2` | `$stop` and its optional diagnostic level | `056_stop.va`, `12_finish_stop.va`; `140_stop_in_analog_initial_rejected.va` — green, pinning `analog initial`: `$stop` is restricted by block kind. `174_stop_terminates.va` executes it: a batch artifact implements suspension as print-and-exit-0, and nothing after the call runs |
| `s9.7.3` | `$fatal` `$error` `$warning` `$info` | `057_fatal.va`, `058_error.va`, `059_warning.va`, `060_info.va`, `13_severity_tasks.va`. The non-fatal three have no return value, so what is pinned is that the run *continues past* the call — the assertion sits after it. `173_fatal_terminates.va` executes `$fatal`: the message prints, the run terminates with a nonzero errorcode (the exit code itself is pinned by cg_display.zig's §9.7 emitter test), and the sweep's second point never prints |
| `s9.8` | PLA tasks not extended to analog | `154_…_rejected.va` (`$async$and$array`) — green, `analog context`. There is no positive side: the table has no analog "Yes" row |
| `s9.9` | stochastic queue tasks not extended to analog | `154_…_rejected.va` (`$q_initialize`) — green, `analog context`; likewise no positive side |
| `s9.10` | `$abstime` in seconds; `$realtime` deprecated in analog | `14_abstime.va` (`//! analysis tran`, `//! time 2.5e-9`); `148_realtime_analog_rejected.va` and `149_time_stime_analog_rejected.va` — both green, `analog context`: `$realtime`/`$time`/`$stime` are no longer answered in an analog block like any other time query |
| `s9.11` | conversion functions: §9.11 extends the family into the analog context | `15_conversion_functions.va` (the `$bitstoreal`/`$realtobits` pair is the identity on 3.7, bit-exact), `063_realtobits.va`, `064_bitstoreal.va`; the two Table 9-8 analog "No" rows are `134_signed` and `135_unsigned` — **both green**, `analog context`. **`061_rtoi_analog_rejected.va` and `062_itor_analog_rejected.va` are REMOVED, and the claim they pinned is WITHDRAWN, not moved.** Both were authored from an HTML transcription of this chapter that had been contaminated with Verilog-AMS 2.4 text, and both asserted that `$rtoi`/`$itor` are illegal call sites in an `analog` block. The 2023 clause reads "Verilog AMS HDL extends the conversion functions defined in IEEE Std 1364 Verilog so that $bitstoreal and $realtobits, $rtoi and $itor can be used in the analog context", and Table 9-8 (printed p.221, physical p.234) reads `$rtoi Yes Yes` and `$itor Yes Yes`. Legal in both contexts means there was never a call site to refuse, so there is no rule-shaped hole here. What is left is a hole in VerA and not in the LRM — neither name is implemented — and that is pinned by the M04 row, which claims §9.11 (`tests/fixtures/ch07_mixed_signal/m04_SPEC.md` — the pending fixtures were moved into the chapter folders after this removal) |
| `s9.12` | `$test$plusargs` and `$value$plusargs` | `065_test_plusargs.va`, `066_value_plusargs.va`, `16_plusargs.va` |
| `s9.13` | probabilistic distribution family | — parent; carried by 9.13.1–9.13.2 |
| `s9.13.1` | `$random` and `$arandom`, seeded and unseeded | `32_random.va`, `33_arandom.va`, `115_random_no_seed.va`, `116_arandom_no_seed.va`, `117_arandom_parameter_seed.va`, `118_arandom_negative_seed.va`. Scope negative `132_arandom_type_string_outside_paramset_rejected.va` — E0816. The legal in-paramset `type_string` is `175_dist_type_string_inside_paramset.va` |
| `s9.13.2` | seven `$dist_*` and six `$rdist_*` names | `34_distribution.va`, `35_real_distribution.va`, `119`–`130` (one file per name). Argument-rule negatives `150_rdist_domain_rejected.va`, `151_rdist_uniform_start_end_rejected.va`, `166_rdist_real_seed_rejected.va`, `133_rdist_type_string_outside_paramset_rejected.va`, `176_dist_type_string_misspelled_rejected.va` — all E0816. `175_dist_type_string_inside_paramset.va` is the legal side: `"global"`/`"instance"` accepted within a paramset and selecting nothing outside a host's Monte-Carlo loop |
| `s9.13.3` | Table 9-26 cross-listing to the 1364 C algorithms | `171_random_ieee1364_digits.va` — the clause BINDS the family to IEEE 1364 §17.9.3's C listing, so the stream is pinnable and pinned: `$random`, `$arandom`, `$rdist_uniform` and `$dist_uniform` digits from seed 7, two draws deep (the second draw passes only if the inout write-back walked the seed exactly as the listing's `long *seed` did). Digits produced by compiling and running the listing (Icarus `vpi/sys_random.c`, cross-checked against Verilator `verilated_probdist.cpp`; URLs in `lib/backend/rng_kernels.zig`), never hand-computed. The rest of the family's fixtures pin §9.13.1/§9.13.2's own two sentences — repeatability on a seed, and the inout seed coming back different |
| `s9.14` | math system functions | Twenty-seven atomics `067`–`093` plus `17_math_unary.va`, `18_math_trig.va`, `19_math_binary.va`, `20_math_2023.va`. Two of the atomics were the last debt here and both are green: `092_ln1p.va` — `zLn1p` used to be `a.addC(1.0).log()`, returning 4.440892098500625e-16 for `$ln1p(5e-16)`, 11% low, which is precisely the naive value Table 4-14's C `log1p` exists to replace — and `093_expm1.va`, `zExpm1` as `a.exp().addC(-1.0)`, the same 11% error for the same reason |
| `s9.15` | `$temperature` `$vt` `$simparam` `$simparam$str` | `21_temperature_vt.va`, `094_temperature.va`, `095_vt_ambient.va`, `096_vt_temperature.va` (all `//! temp`-driven), `22_simparam.va` (unknown name returns its fallback verbatim), `23_simparam_string.va`. All three branches of the clause's `$simparam` sentence are now green: `147_simparam_unknown_no_fallback_rejected.va` is a **reject VerA meets** (E0811 — the unknown name with no fallback), and `157_simparam_timescale.va` pins Table 9-27's two source-derived rows, `"timeUnit"`/`"timePrecision"` in seconds, which the preprocessor now parses out of `` `timescale `` and publishes for `Lower.simparamValue` |
| `s9.16` | `$simprobe(inst_name, param_name [, expr])` | `36_simprobe.va` — green. The pair resolves as ONE flat name, `inst_name.param_name`, against the elaborated design, which is the identity every §6.7 reference rides on; a name that does not resolve takes the clause's fallback expression, and with no fallback it is E0817. A name built at run time cannot resolve here — that is the piece Ruling E gave up, and the fallback is the LRM's own cover for it |
| `s9.17` | analog kernel control family | — parent; carried by 9.17.1–9.17.3. Its own prose introduces the family and names no task, so it has no call site to accept and no shape to refuse; the three children hold every rule it points at |
| `s9.17.1` | `$discontinuity`, nonnegative degree or `-1` | `24_discontinuity.va`; `138_discontinuity_arity_rejected.va` (E0804) and `139_discontinuity_nonconstant_rejected.va` (E0805), and `185_discontinuity_negative_degree_rejected.va` (E0820) |
| `s9.17.2` | `$bound_step` | `25_bound_step.va` (`//! analysis tran`); `136_bound_step_negative_rejected.va` (E0803) and `137_bound_step_arity_rejected.va` (E0802) — **rejects VerA already meets** |
| `s9.17.3` | `$limit`, all three Syntax 9-12 forms | All three: `26_limit.va` (`$limit(V(p,n))`), `27_limit_named.va` (`$limit(V(p,n), "pnjlim", $vt, 0.7)`), `156_limit_user_function.va` (an `analog_function_identifier` is resolved as the limiter, not looked up as a value) and its negative `164_limit_user_function_output_arg_rejected.va` (E0814, "shall all be declared input"). Fixtures 177–183 exercise per-access history, iteration initialization, unused constant returns, derivative history and nonlinear convergence rejection. `tests/limiter_host.zig` checks generated commit/revert and solve initialization; consuming hosts must implement the separate iteration hooks |
| `s9.18` | `$mfactor` `$xposition` `$yposition` `$angle` `$hflip` `$vflip` | `28_hierarchical_parameters.va` plus atomics `097`–`102`, one per name. `163_aliasparam_mfactor.va` — green: a `system_identifier` is a legal `aliasparam` target, so §3.4.7's own printed example parses, and the ALIAS holds the storage (`$mfactor` has none on a model card, being an `Instance` field the host writes) |
| `s9.19` | `$param_given` and `$port_connected` | `29_binding_detection.va`, `103_param_given.va` (overridden), `159_param_given_not_overridden.va` (the 0 direction, one deleted `//! param` line away), `165_param_given_override_equals_default.va` (override *equal to* the default is still an override — the input that separates a flag from a value comparison, and VerA now carries a real `__given` flag, `codegen.zig:867`), `104_port_connected.va` |
| `s9.20` | `$analog_node_alias` / `$analog_port_alias` | `30_node_alias_calls.va`, `105_analog_node_alias.va`, `106_analog_port_alias.va` pass — see the note below on *why* they pass. The topology edit IS performed now: `191_node_alias_resolves.va`, `191_port_alias_resolves.va` and `191_node_alias_last_call_wins.va` are the clause's positive half, over a real two-module hierarchy, and each asserts the identity rather than the flag — the aliased net reads the hierarchical node's potential, the port-aliased net is legal as `I(<n>)` and reads that PORT's flow unknown, and two calls on one net leave the LAST alias standing. All six negatives now reject at E0812, one code for the clause's whole validity list: `141` (outside `analog initial`), `142` (first argument a port), `143` (bit select), `144` (non-constant string), `145` (target is another call's `analog_net_reference`), `146` (inside a conditional the simulation can move). All six are checked in `lower.zig` `checkAliasCall`, because every one of them is a property of the CALL — the block, the guard, the argument's shape — and none of a value. The alias itself is `lower.zig` `bindAlias`: a `node_voltages` write, which is what node identity IS here. `167_node_alias_status_is_integer.va` pins the RETURN TYPE rather than the value: the three positives above assign the status into an `integer` variable, where a §4.2.1.1 conversion hides a `real`, so `167` puts the call under `<<` and `~` where nothing can hide it |
| `s9.21` | `$table_model` | `37_table_model.va` (file-backed, with `ch09_table_model_2d.tbl`), `131_table_model_array_control.va` (array-backed), `155_table_model_lrm_sample_set.va` — **all three green**. The isoline interpolator is `lib/backend/table_kernels.zig`, emitted into the device like the §4.5.11 filter kernels; the call is rewritten into a self-describing one by `Lower.lowerTableModel`, which is also where a scheme VerA does not implement is refused (E0815) |
| `s9.21.1` | data source: file or real arrays | `187_table_snapshot*.va` and `test-table-snapshot-host` check first-call array capture, guarded execution, ignored mutations, independent instances and rejected-trial persistence. Source-order effects retain unused calls. Repeated calls to one analog-function body share its syntactic table site: this is an inference from §§4.7 and 9.21.1, not an explicit LRM example. File sources (`37`) are still read at compile time; changes before the first runtime call remain a conformance gap. `zTabSort` handles unsorted isolines. |
| `s9.21.2` | control-string grammar | `37`'s `"1LL,1LL;1"` and `131`'s `"1LL;1"` are parsed by `Lower.parseTableCtl`: per-dimension sub-strings outermost-first, the one-character and two-character extrapolation forms, the defaults for an absent character or an absent string, and the dependent selector. Table 9-30's `D`/`2`/`3`/`I` and Table 9-31's `E` are refused at E0815, not approximated. No fixture pins a refusal — the five malformed strings are in the CLI checks only |
| `s9.21.3` | Table 9-32 example control strings | `37`'s `"1LL,1LL;1"` is verbatim the table's fourth row and is now read as such; `131`'s `"1LL;1"` is that row in one dimension. The `"D,1,3"`, `"I,..."` and `"3,D,I,1;3"` rows name schemes VerA refuses |
| `s9.21.4` | closest-point, linear and cubic-spline interpolation | LINEAR only, and the other three are refused rather than substituted. `155` serves the linear half: it recomputes Figure 9-2's `f(3.5, 0.25) = 2.0` by hand from the printed twelve-row sample set under the default rule, and that is the number it now reads back. Both Table 9-31 extrapolations work, per end, which the codegen test pins with an asymmetric `"CL"` |
| `fn9.21.4-1` | bibliography footnote for cubic splines | — informative; no language rule |
| `s9.21.5` | the LRM's own worked example | `155_table_model_lrm_sample_set.va` — green. This is the only place in the chapter where the LRM supplies its own oracle (data, query point *and* answer), and the compiler now agrees with it |
| `s9.22` | connectmodule driver access | `31_driver_access.va` (`$driver_count`, `$driver_state`, `$driver_strength` in an ordinary module) and atomics `107`, `109`–`114` — **all green**: paragraph 3 ("Driver access functions can only be called from connect modules") makes the call SITE alone decide, and every call site LOWERING reaches is inside the elaborated device — a connect module is never that, because §7.6 makes it the insertion phase's to place and `elaborate.pickTop` skips it — so all of them are outside one and are refused at lowering (E0818, `isConnectModuleOnlySysFunc`). Since wave 6 `connectmodule` parses (§7.6, `s9.22.5` below); a driver call written INSIDE one is therefore accepted and never reached, which is the clause's other half and needs the insertion phase, not a diagnostic. These eight were xfail on the claim that the rule needed digital driver state; it needs none, and the `codegen.zig` `driver_queries` constant 0 they were xfail *for* is deleted. Note the numbering gap at `108`, and note that the reason recorded for it here was a quotation from contaminated text — see `s9.22.2` below. `195` and `196` now cite the section as well, and they cite it from the INSIDE: both write a connect module, which is paragraph 3's legal side, and both are xfail on what has to happen once it parses |
| `s9.22.1` | `$driver_count` | `107_driver_count_connectmodule_rejected.va` (+ `31`) — green, E0818 |
| `s9.22.2` | `$receiver_count` | — **no fixture, and the claim that there is nothing here to pin was WITHDRAWN.** `annex_g_change_history/08_new_receiver_count.va` was REMOVED. It was authored from an HTML transcription contaminated with Verilog-AMS 2.4 text, and it argued from a paragraph the corrected chapter does not contain — "Non-normative: $receiver_count is not a subclause of 9.22 in Verilog-AMS 2.4" — concluding that the function had no clause to cite. In the 2023 document `$receiver_count` is a NORMATIVE subclause with its own syntax box: §9.22.2 (printed p.262, physical p.275) "`$receiver_count` returns an integer representing the number of receivers associated with the signal in question. The syntax is shown in Syntax 9-18", `receiver_count_function ::= $receiver_count ( signal_name )`. This is also why the four rows below it are numbered one higher than they used to be, and why the audit at the top of this file gained `s9.22.7`. What is left is a hole in VerA and not in the LRM — the function is not implemented — and that is pinned by the M04 driver/receiver row, which owns §9.22 (`tests/fixtures/ch07_mixed_signal/m04_SPEC.md`) |
| `s9.22.3` | `$driver_state` | `109_driver_state_connectmodule_rejected.va` (+ `31`) — green, E0818. Its `//! lrm` line read `9.22.2`, this subclause's index in the 2.4 numbering, and is **corrected to `9.22.3`** (it was citing `$receiver_count`'s row). The header prose above it — "§9.22.2 defines driver_index as …" — is the same 2.4 number and is deliberately left as written: read it as `s9.22.3` |
| `s9.22.4` | `$driver_strength` | `110_driver_strength_connectmodule_rejected.va` (+ `31`) — green, E0818. The same one-behind `//! lrm` line, `9.22.3` → **`9.22.4`**; its header's "§9.22.3 defines driver_index" sentence is left as written for the same reason |
| `s9.22.5` | `driver_update` event | `38_driver_update_connectmodule.va` — **green**. A.6.5's `driver_update expression` and the `connectmodule` that is its only legal home (§9.22 paragraph 3) both parse and are accepted; the fixture asserts ACCEPTANCE (`V(p,n)` in a separate ordinary module in the same file), not the trigger, because how often the event fires is a property of the elaborated netlist. Nothing digital executes: §7.6 makes a connect module the insertion phase's to place, `elaborate.pickTop` never picks one, so the body is recorded and never lowered. Its `//! lrm` line read `9.22.4` and is **corrected to `9.22.5`** — the third of the three; its prose ("§9.22.4 driver_update", "§9.22.4 in full") and its CHECK label still carry the 2.4 number, deliberately. `196_connectmodule_driver_access_example.va` cites this subclause too, from the LRM's own worked example (`always @(driver_update(d))`), which is the only place the chapter prints the event form itself |
| `s9.22.6` | receiver net resolution via `assign d_receivers = d_drivers;` | `195_receiver_net_resolution_assign.va` — green (the `assign` parses; see below), rule 2's spelling quoted from the clause's own snippet (`reg out;` then `assign d = out;`) inside a connectmodule. Rule 1 is the ABSENCE of an assignment and is what a VerA design always gets, which is not the rule — "the default is always taken" and "the default is taken when nothing is assigned" are different claims, so the row stays open. The continuous `assign` USED to be E0205 everywhere in VerA; it is a module item of every module now (A.1.4), so rule 2 can be written. A connect module is still not inserted (§7.8), so the receiver value it sets reaches nothing yet |
| `s9.22.7` | the Figure 9-4 worked connectmodule | `196_connectmodule_driver_access_example.va` — **green** (it compiles; nothing in the connect module runs), carrying the clause's `c2e` example line for line. It is the densest source the chapter prints: `always @(driver_update(d))` (§9.22.5), `$driver_count` (§9.22.1) and `$driver_state` (§9.22.3) in a loop where one driver function is indexed by another's return, `assign d=out;` (§9.22.6 rule 2), three `branch` declarations, a `ground` terminal and three `cross()` events. Once refused twice over — `assign d=out;` at E0205, then `out = 1'bx;` at E0130, because lowering refused every x/z literal in the file, the four-state kernel's included; both are fixed — and what remains is the fact that a connect module is never inserted (§7.8) and never lowered, so nothing in the example can run even once it parses |
| `s9.23` | supplementary driver access | — parent; carried by the four children below, which cite them directly. §9.23's fence is one step tighter than §9.22's — these four are "supported in the digital context of connectmodules" — so E0818 refuses them for the same reason |
| `s9.23.1` | `$driver_delay` | `111_driver_delay_connectmodule_rejected.va` — green, E0818; the -1.0 no-pending-value sentinel it used to answer went with the rest of the family. Not covered by `31`, whose body has only the three §9.22 names |
| `s9.23.2` | `$driver_next_state` | `112_driver_next_state_connectmodule_rejected.va` — green, E0818 |
| `s9.23.3` | `$driver_next_strength` | `113_driver_next_strength_connectmodule_rejected.va` — green, E0818 |
| `s9.23.4` | `$driver_type` | `114_driver_type_connectmodule_rejected.va` — green, E0818 |

## The four walls

This was the most useful section in the file and it is now entirely history: the sixty-five
xfails this chapter carried were never sixty-five defects, they were four walls and a short
tail, and **all four walls are down**. The paragraphs are kept because each records WHY the
wall was a wall, and three of the four turned out to rest on an argument that was wrong at
its first step — which is the failure mode worth being able to recognise again. Counts in the
paragraph headings are the counts each wall HELD, not current ones.

**Descriptors: the wall is down (14 fixtures).** Every §9.5 name that needs a
FILE — `$fopen`, `$fclose`, the five output tasks, `$fgets`, `$fscanf`, `$ftell`,
`$fseek`, `$rewind`, `$fflush`, `$ferror`, `$feof` — used to lower to the constant
`S.con(0.0)`, and `lower.zig` gave the reason: the family "needs a descriptor the
compiled device has no way to own". It still does not own one, and that turned out
to be the answer rather than the obstacle.

The table is a HOST facility (`lib/backend/file_kernels.zig`), carried only by the
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

**RNG implementation and reference-stream evidence (partial).**
`$random`, `$arandom`, seven `$dist_*`
and six `$rdist_*` used to be one blanket E0801 at the function name, on the
argument that a draw changing between Newton iterations makes the residual
non-deterministic so the solve never converges. The premise was right and the
conclusion was wrong. §9.13.1/§9.13.2 make the seed a SOURCE VARIABLE — "a value
is passed to the function and a different value is returned" — so a variate is a
pure function of that variable's incoming value and is automatically fixed for
the whole Newton loop at one operating point. Lowering splits one source call
into two pure calls over the seed (the variate, and the write-back), exactly as
`$sscanf` is split into one call per out-parameter. The write-back is each
kernel's own `_next` twin, not a generic step, because §17.9.3's routines
consume a data-dependent number of LCG draws and the updated seed must land
exactly where the reference's `long *seed` did — `171` asserts precisely that. The seedless forms have no
such variable, so their §9.13.1 "internal seed" is a latch in `Instance` advanced
by `updateState` on the ACCEPTED step and only read by `eval` — the same
discipline, with the boundary the contract already had. The argument-rule
negatives (`150`, `151`, `166`, the paramset scope pair `132`/`133`, and the
misspelled `type_string` `176`) reject on E0816, which is per-argument and
therefore fires whether or not the family is otherwise supported. The
`type_string`'s legal side is `175`: inside a §6.4 paramset the call is folded
at elaboration (`elaborate.rewriteParamsetDist`, the same `rng_kernels.zig` a
device embeds), where a valid `type_string` selects nothing because the
Monte-Carlo trials it partitions are the HOST's loop, not a compilation's.

**Analog-context table: the wall is down (11 fixtures).** Tables 9-1, 9-2, 9-3, 9-5, 9-6,
9-7 and 9-8 each have a "No" column and VerA implemented none of it. `061`, `062`, `134`,
`135`, `148`, `149`, `152`, `153`, `154` were the inventory, plus `140` (`$stop` by block
kind) and `161` (format/argument pairing). This was called the cheapest wall in the chapter —
a lookup table and a diagnostic, not a runtime feature — and it was: all eleven are green,
the nine table rows pinning the substring `analog context`, `140` pinning `analog initial`
and `161` pinning `format specifier`. None pinned a code, so none needed an edit.
Two of the nine table rows were later removed rather than repaired: `061` and `062` pinned
analog "No" cells for `$rtoi`/`$itor` that the corrected 2023 Table 9-8 does not have. The
wall they belonged to was real and is still down for the seven rows that remain; those two
were never part of it, they were part of a transcription error. See `s9.11`.

**No hierarchy (0 fixtures).** The last one, `38_driver_update_connectmodule.va`,
is green: `connectmodule` PARSES now (§7.6, A.1.2's third `module_keyword`), and
that was the whole of what it needed — its own header says the assertion is
acceptance and not the trigger, and its `CHECK` is on a branch potential in a
separate ordinary module in the same file. The
§9.22/§9.23 QUERIES (`31`, `107`, `109`–`114`) used to be counted here and are
green: the rule they state is about the call SITE and not about drivers, so an
engine with no drivers enforces it exactly (E0818). `$simprobe` (`36`) used to be counted here and is green: §9.16's resolution is a name lookup in the flattened design, not a walk of a live netlist.
`$table_model`'s three (`37`, `131`, `155`) used to be counted here, on the
honest note that they needed an interpolator rather than hierarchy; they now
have one. The six §9.20 negatives used to be
counted here; they are not hierarchy at all — every one of their rules is about
the CALL — and they now reject at E0812.

The tail was a handful of single-cause fixtures and every one was, as predicted, a single
edit in a single file: `092`/`093` (naive `log1p`/`expm1` — the cancelling forms), `156`/`164`
(`$limit` form three; `164` pins E0814), `157` (`` `timescale `` not threaded into
`$simparam`), `147` (no missing-fallback diagnostic, now pinning `simulation parameter is not
known`) and `163` (`aliasparam` would not take a system function, until a `system_identifier`
became a legal target).

**The four new xfails are one hill, not four (4 fixtures).** `193`–`196` are the
first xfails this chapter has carried since the walls came down, and every one of
them waits on the same two facts. A connect module is never inserted (§7.8) and
never lowered, so no digital statement inside one executes — that alone holds
`195` and `196`, and the absence of a digital file table holds `194`. And VerA's
only vocabulary for "not in this context" is §7.2.2's `initial`-block model,
which refuses the STATEMENT rather than the call site and cites no clause: that
is `193`'s xfail and half of `194`'s. Each file's reason names its own line and
its own next step, so when the piece lands the marker turns hard XPASS and the
file has to be re-judged instead of quietly going green.

## Two places where "passes" is narrower than it looks

**The file-output atomics.** `040_fwrite.va`, `041_fstrobe.va`,
`042_fmonitor.va`, `043_fdebug.va`, `044_swrite.va` and `045_sformat.va` all pass,
and the four file ones call `$fopen` on a descriptor that is a constant
zero in a device compiled for a solver. They pass because what each one asserts is the *argument value* handed to
the format — `V(p,n)` at the operating point — and never a byte reaching a file.
That is a deliberate, stated choice in each header, not an oversight, so §9.5.2
still has four green fixtures and no evidence that the task produces output.
§9.5.3 is no longer in that position: `044`/`045` still assert only the argument,
but `06` and `09` read the formatted TEXT back through `$sscanf`.

**The node-alias positives — the narrow reason is gone.** `30_node_alias_calls.va`,
`105` and `106` used to be the whole positive story, and all three pass for a
reason narrower than the rule: their reference strings (`"$root.top.n"`) cannot
resolve in a single-module compilation, so §9.20's "shall be zero otherwise"
answer *is* zero, which was also what a compiler answering a constant 0 gave.
The right answer for the wrong reason. The reason given for the missing
matrix-position merge — "a flat elaboration has no instance hierarchy for a
`hierarchical_reference_string` to resolve INTO" — was wrong at its first step:
elaboration FLATTENS a hierarchy, and a flattened child's net keeps its path as
its name (`Elaborate.sep` is a period), so the string and the design's own name
for the node are the same bytes and resolution is a map lookup. The `191_*`
trio is the observable half that follows, and it is what retires `30`'s explicit
disclaimer of the last-call-wins precedence rule.

Two ceilings remain, both named at `lower.zig` `bindAlias`. A reference to a
child INSTANCE's port — the clause's own `"top.r1.p"`, whose promise is that
`I(<n2>)` measures the flow through *that instance's* terminal — takes the
honest 0 instead of a nearby number: flattening binds the port to the parent net
it was connected to, and one instance's terminal flow is not a quantity the flat
design still has. And the resolution happens at compile time, so a
`hierarchical_reference_string` that is a string PARAMETER is frozen at its
declared default; a host override that would resolve elsewhere cannot move the
topology of an emitted `U`.

## What the previous file claimed that is not true

Recorded so it is not re-derived. The old table credited `03_display_write.va`
with §9.4.7 (its `%r` is the analog Table 9-23 specifier, not the digital-context
extension); credited `31_driver_access.va` with §9.23.1–§9.23.4 (its body has
only the three §9.22 names); credited `15_conversion_functions.va` with `$rtoi`,
`$itor`, `$signed` and `$unsigned` (the file now tests only the
`$bitstoreal`/`$realtobits` pair and says so); invented a subclause "9.22.7", which
does not exist in the 2.4 numbering (it exists in the 2023 one, and `196` now
carries its example — the old claim was right about the text it was read from and
wrong about the LRM); and described `$param_given` as comparing a value against its
default, which `codegen.zig` no longer does. Its two closing inventories listed
several dozen file names that no longer exist under those names, and duplicated
the ones that do.

`186_table_model_discrete.va` exercises Table 9-30 `D`, signed midpoint ties,
endpoint behavior and mixed discrete/linear dimensions. Kernel tests also check
zero derivatives in discrete coordinates and retained inner-dimension slopes.

`188_numeric_string_local_width.va` now verifies all eight bytes from a 64-bit
localparam. Its previous width rejection was removed after parameter model
initialization and derivation stopped passing the integral value through f64.
General expression sizing and host-overridden untyped widths remain rejected
for numeric `%s`.

The `189_rng_*` cases cover counts above 4096, reference value/seed progression,
and explicit unsupported-count/paramset conversion diagnostics. The compiled C
oracle and both runtime error paths run under `zig build test-rng-reference`.
`test-rng-effects` additionally executes generated-device checks for unused values,
skipped branches, short-circuit operands, loops and source-ordered errors.
Fractional real counts, large-mean Poisson precision, and reference nonfinite
results remain limits; see [RNG-REFERENCE-LIMITS](../../../docs/RNG-REFERENCE-LIMITS.md).

### Source audit follow-up, 2026-09-23

`audit_real_format_fields.va` compares e/f output strings directly, including
leading spaces, fixed fractional digits, exponent width and negative-sign
placement. Its targeted strict run passes. It strengthens the older numeric
round-trip evidence, which cannot detect formatting-preserving numeric changes
such as omitted padding. The complete format/type/flag matrix remains open.
See [the display-format worklist](../../../docs/conformance-display.md) for
FMT-G-001 and FMT-WIDTH-001. The latter is now a positive XFAIL in
`audit_integer_default_fields.va`; `170` uses explicit minimal-width formats
and no longer requires the deviation. The new fixture retains its former
bare-operand claims with independently derived default-field expectations.

Digital monitor failures are separately recorded in
[the monitor worklist](../../../docs/conformance-monitor.md); analog accepted-
step comparisons must not substitute for inherited digital event semantics.
