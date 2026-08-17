# Chapter 12 coverage

Source: `docs/VAMS-LRM/ch12-vpi-routines.html`, read section by section.

HTML section-ID audit: `s12-1` `s12-2` `s12-3` `s12-4` `s12-5` `s12-6` `s12-7` `s12-8` `s12-9` `s12-10` `s12-11` `s12-12` `s12-13` `s12-14` `s12-15` `s12-16` `s12-17` `s12-18` `s12-19` `s12-20` `s12-21` `s12-22` `s12-22-1` `s12-22-2` `s12-23` `s12-24` `s12-25` `s12-26` `s12-27` `s12-28` `s12-29` `s12-30` `s12-31` `s12-31-1` `s12-31-2` `s12-31-3` `s12-31-4` `s12-32` `s12-32-1` `s12-32-2` `s12-32-3` `s12-33` `s12-33-1` `s12-33-2` `s12-34` `s12-35` `s12-36`. 47 ids; 38 have a fixture, 9 do not.

Every routine in this chapter is a C function in a simulator's VPI host. Only
three things in the whole clause are written in Verilog-A and therefore
testable from a `.va` file: the `$resistor()` task call of §12.22.2, the
`sampnhold` module of §12.32.3, and the "each time it is invoked" rule of
§12.33.1 that §12.32 imports for the analog domain. Fixtures `01`, `02` and
`48` are those three. Everything else in the table below is one atomic
fixture per routine pinning a single negative fact — that the C routine's
name is not a callable Verilog-A function — and nothing about what the
routine does.

| Documentation id | Fixture | What is actually pinned |
|---|---|---|
| `s12-1` | — | Prose conventions for the C prototype write-ups (Synopsis/Syntax/Returns/Arguments/Related routines). No language rule. |
| `s12-2` | `03_chk_error_not_va.va` | `vpi_chk_error` in expression position is E0512, with the name in the message. |
| `s12-3` | `14_compare_objects_not_va.va` | `vpi_compare_objects` is E0512. |
| `s12-4` | `15_free_object_not_va.va` | `vpi_free_object` is E0512. |
| `s12-5` | `16_get_not_va.va` | `vpi_get` is E0512. |
| `s12-6` | `17_get_cb_info_not_va.va` | `vpi_get_cb_info` is E0512. |
| `s12-7` | `18_get_analog_delta_not_va.va` | `vpi_get_analog_delta` is E0512. |
| `s12-8` | `19_get_analog_freq_not_va.va` | `vpi_get_analog_freq` is E0512. |
| `s12-9` | `20_get_analog_time_not_va.va` | `vpi_get_analog_time` is E0512. |
| `s12-10` | `21_get_analog_value_not_va.va` | `vpi_get_analog_value` is E0512. |
| `s12-11` | `22_get_delays_not_va.va` | `vpi_get_delays` is E0512. |
| `s12-12` | `23_get_str_not_va.va` | `vpi_get_str` is E0512. |
| `s12-13` | `24_get_analog_systf_info_not_va.va` | `vpi_get_analog_systf_info` is E0512. |
| `s12-14` | `25_get_systf_info_not_va.va` | `vpi_get_systf_info` is E0512. |
| `s12-15` | `26_get_time_not_va.va` | `vpi_get_time` is E0512. |
| `s12-16` | `27_get_value_not_va.va` | `vpi_get_value` is E0512. |
| `s12-17` | `28_get_vlog_info_not_va.va` | `vpi_get_vlog_info` is E0512. |
| `s12-18` | `29_get_real_not_va.va` | `vpi_get_real` is E0512. |
| `s12-19` | `30_handle_not_va.va` | `vpi_handle` is E0512. |
| `s12-20` | `31_handle_by_index_not_va.va` | `vpi_handle_by_index` is E0512. |
| `s12-21` | `32_handle_by_name_not_va.va` | `vpi_handle_by_name` is E0512. |
| `s12-22` | `33_handle_multi_not_va.va` | `vpi_handle_multi` is E0512. |
| `s12-22-1` | — | `vpi_handle_multi(vpiDerivative, ...)` and the derivtf phase are C-side only. No derivative handle is reachable from source, and `01` does not mention one. |
| `s12-22-2` | `01_analog_systf_resistor_call.va` | The LRM's own `$resistor(curr, V(p,n), r)` call form is accepted in statement position, and §5.3.1 runs the enclosing block straight through it (`seq == 3`). The output argument's value is NOT asserted — with no host it is unreachable. |
| `s12-23` | `34_iterate_not_va.va` | `vpi_iterate` is E0512. |
| `s12-24` | `35_mcd_close_not_va.va` | `vpi_mcd_close` is E0512. |
| `s12-25` | `36_mcd_name_not_va.va` | `vpi_mcd_name` is E0512. |
| `s12-26` | `37_mcd_open_not_va.va` | `vpi_mcd_open` is E0512. |
| `s12-27` | `38_mcd_printf_not_va.va` | `vpi_mcd_printf` is E0512. |
| `s12-28` | `39_printf_not_va.va` | `vpi_printf` is E0512. |
| `s12-29` | `40_put_delays_not_va.va` | `vpi_put_delays` is E0512. |
| `s12-30` | `41_put_value_not_va.va` | `vpi_put_value` is E0512. |
| `s12-31` | `42_register_cb_not_va.va` | `vpi_register_cb` is E0512. |
| `s12-31-1` | — | `cbValueChange`/`cbForce`/… reason codes are host queue state. No source-observable consequence in a single compiled device. |
| `s12-31-2` | — | `cbAtStartOfSimTime`/`cbReadWriteSynch`/… are host time-queue state. |
| `s12-31-3` | — | `acbInitialStep`/`acbFinalStep`/`acbConvergenceTest`/… are solver callbacks. The *source-level* `initial_step`/`final_step` events are a different construct and belong to Chapter 5, not here. |
| `s12-31-4` | — | Action and feature reasons, including `cbUnresolvedSystf`. Not fixtured deliberately: the clause calls features "possible" and says they "might not exist in all VPI-compliant products", so no `.va` verdict follows from them. `02`'s header records why this cannot be cited as licence to reject an unknown systf. |
| `s12-32` | `43_register_analog_systf_not_va.va`, `48_systf_name_repeated_call_sites.va` | `vpi_register_analog_systf` is E0512. `48` additionally pins the *reading* of the uniqueness sentence: it constrains the registration, not the number of call sites. |
| `s12-32-1` | — | `type`/`sysfunctype`/`compiletf`/`calltf`/`sizetf`/`derivtf`/`user_data` are `s_vpi_analog_systf_data` fields. The only sentence with a source consequence is the one importing §12.33.1, which `48` tests there. |
| `s12-32-2` | — | `t_vpi_stf_partials` and the derivtf declaration protocol are C structures. Nothing is written in Verilog-A. |
| `s12-32-3` | `02_analog_systf_sampler_call.va` **XFAIL** | The LRM's `sampnhold` module verbatim: an unregistered analog system *function* in expression position is legal source. Asserts only the `1e-3` parameter — §12.32.3's own listing never initialises `sampler->value` before the first callback, so no digits for `V(out)` exist to assert. |
| `s12-33` | `44_register_systf_not_va.va` | `vpi_register_systf` is E0512. |
| `s12-33-1` | `48_systf_name_repeated_call_sites.va` | "Callbacks … shall occur *each time* the system task or function is invoked": two call sites of one `$name` are two invocations, not a redefinition, and §5.3.1 sequences both (`seq == 7`). |
| `s12-33-2` | — | `vlog_startup_routines` is a host link-time array. Not source. |
| `s12-34` | `45_remove_cb_not_va.va` | `vpi_remove_cb` is E0512. |
| `s12-35` | `46_scan_not_va.va` | `vpi_scan` is E0512. |
| `s12-36` | `47_sim_control_not_va.va` | `vpi_sim_control` is E0512. |

## Debt ledger — `//! xfail`

One fixture in this chapter states a rule VerA does not meet.

| Fixture | Section | Reason on the `//! xfail` line |
|---|---|---|
| `02_analog_systf_sampler_call.va` | §12.32.3 | VerA has no VPI host: an unregistered analog system function has no value, and codegen will not invent one for a contribution, so the unit collapses to `@compileError` carrying `$sampler`. |

The marker points the run-fixture way round: the LRM *prints* this module, so
it must compile and run green, and VerA cannot get there. It is not a pass.
The day VerA compiles an unregistered analog system function, the run FAILs as
an XPASS and the line must go — at which point the fixture will have proved
only that the §12.32.3 source form is accepted. Sample-and-hold *behaviour*
needs a registered host, and this suite has no form for one.

Note the polarity, because the previous revision of `02` got it backwards. It
demanded `//! reject` on a construct the LRM prints as its own worked example:
a conforming compiler failed that fixture and only VerA passed it. `01` had
the same inversion and lost it the same way. Neither is a `reject` fixture now.

## What the 35 atomic fixtures do and do not prove

Each is four lines of directive over a three-line module:

```verilog
//! lrm 4.7
//! lrm 12.5
//! reject E0512
//! reject `vpi_get`
```

The §4.7 cite is the operative one — E0512 is "unknown function", and the
Chapter 12 cite only names which routine is being ruled out. What they prove
is that the 35 VPI routine names are not silently absorbed as Verilog-A
callables and that the diagnostic names the offending identifier. What they do
not prove is anything whatsoever about arguments, return types, error codes,
`vpi_user.h` structures, ownership, or callback ordering. Those need a C
conformance suite against a VPI host; recording the boundary here is what
keeps the 35 files from reading as 35 sections of real coverage.

They are also uniform on purpose. One template, one substitution, so a new
routine added to the clause is one file and a reader can diff any two of them
to zero.

## Not covered

`s12-1`, `s12-22-1`, `s12-31-1`, `s12-31-2`, `s12-31-3`, `s12-31-4`,
`s12-32-1`, `s12-32-2`, `s12-33-2`. Every one is C-side: prototype-write-up
conventions, derivative handles, callback reason tables, `s_vpi_*` struct
fields, and `vlog_startup_routines`. None has a `.va` spelling, so none is
reachable by a fixture in this tree. This is a real gap in *conformance to
Clause 12*, not merely a gap in this directory — it is closed by a VPI host
implementation and a C test suite, neither of which exists.

## Literal fixture inventory

38 fixtures. Every one appears in the table above.

- `01_analog_systf_resistor_call.va`
- `02_analog_systf_sampler_call.va` (xfail)
- `03_chk_error_not_va.va`
- `14_compare_objects_not_va.va`
- `15_free_object_not_va.va`
- `16_get_not_va.va`
- `17_get_cb_info_not_va.va`
- `18_get_analog_delta_not_va.va`
- `19_get_analog_freq_not_va.va`
- `20_get_analog_time_not_va.va`
- `21_get_analog_value_not_va.va`
- `22_get_delays_not_va.va`
- `23_get_str_not_va.va`
- `24_get_analog_systf_info_not_va.va`
- `25_get_systf_info_not_va.va`
- `26_get_time_not_va.va`
- `27_get_value_not_va.va`
- `28_get_vlog_info_not_va.va`
- `29_get_real_not_va.va`
- `30_handle_not_va.va`
- `31_handle_by_index_not_va.va`
- `32_handle_by_name_not_va.va`
- `33_handle_multi_not_va.va`
- `34_iterate_not_va.va`
- `35_mcd_close_not_va.va`
- `36_mcd_name_not_va.va`
- `37_mcd_open_not_va.va`
- `38_mcd_printf_not_va.va`
- `39_printf_not_va.va`
- `40_put_delays_not_va.va`
- `41_put_value_not_va.va`
- `42_register_cb_not_va.va`
- `43_register_analog_systf_not_va.va`
- `44_register_systf_not_va.va`
- `45_remove_cb_not_va.va`
- `46_scan_not_va.va`
- `47_sim_control_not_va.va`
- `48_systf_name_repeated_call_sites.va`

Numbers `04`-`13` are absent. They were group-representative files —
`04_object_property_not_va.va` called `vpi_get_str` but was credited for the
whole object/property group, `12_mcd_not_va.va` called `vpi_mcd_open` and was
credited for all four `mcd` sections — carried no `//! lrm` cite, and are now
duplicated exactly by `23` and `37` in the one-routine-per-file set `14`-`47`.
Deleted, not renumbered: renumbering would break every citation of the
surviving files to spare a cosmetic gap.
