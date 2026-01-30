# Chapter 12 coverage

Source: `docs/ch12-vpi-routines.html`, read section by section.

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
| `s12-32-3` | `02_analog_systf_sampler_call.va` | The LRM's `sampnhold` module verbatim: an unregistered analog system *function* in expression position is legal source, and VerA now compiles it — the call reads 0.0 under a `W0852` naming the name. Asserts only the `1e-3` parameter — §12.32.3's own listing never initialises `sampler->value` before the first callback, so no digits for `V(out)` exist to assert. |
| `s12-33` | `44_register_systf_not_va.va` | `vpi_register_systf` is E0512. |
| `s12-33-1` | `48_systf_name_repeated_call_sites.va` | "Callbacks … shall occur *each time* the system task or function is invoked": two call sites of one `$name` are two invocations, not a redefinition, and §5.3.1 sequences both (`seq == 7`). |
| `s12-33-2` | — | `vlog_startup_routines` is a host link-time array. Not source. |
| `s12-34` | `45_remove_cb_not_va.va` | `vpi_remove_cb` is E0512. |
| `s12-35` | `46_scan_not_va.va` | `vpi_scan` is E0512. |
| `s12-36` | `47_sim_control_not_va.va` | `vpi_sim_control` is E0512. |

## Fixture ledger — `//! xfail`

**Empty.** No fixture in this chapter carries `//! xfail` any more. This does
not close the standard VPI C API or its host integration requirements.

`02_analog_systf_sampler_call.va` was the one, and it closed the way its own
header predicted: §2.8.3 makes a `$name` grammatical and lists the VPI as one
of the places a system function may be defined, §12.32 hands the *application*
a compiletf routine, and no clause makes an unregistered one an error — so
refusing it was refusing legal source. VerA reads 0.0 and emits `W0852` at
every call site.

A warned zero fallback is not evidence of the registered function's behavior.
`--deny=W0852` can reject a build without the needed host binding; neither the
warning nor rejection establishes the standard VPI call contract.

What the fixture proves is therefore that the §12.32.3 source *form* is
accepted, and nothing about the value. Sample-and-hold *behaviour* needs a
registered host, and this suite has no form for one.

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
Clause 12*, not merely a gap in this directory. Completion requires the
standard VPI host API and C-level behavioral tests; a system-function bridge
or scheduler-core unit tests do not establish those contracts.

### The nine, re-examined clause by clause

"No `.va` spelling" is the claim a later reader is most likely to want to
overturn, so here is the evidence rather than the verdict — re-checked on
2026-09-20 against HEAD `0984a12`, not against the plan. No fixture was added,
and the reason is structural in both directions.

**The VPI host is back, and it still does not pin these nine.** The paragraph
that stood here said the three files that would have been the pattern —
`tests/vpi_app.c`, `tests/vpi_host.zig`, `tests/vpi_design.va` — had been
deleted in `2cc1c08` ("docs: the 2023 LRM replaces 2.4, and the stale prose goes
with it"). That was true when it was written. They have since been restored from
`2cc1c08^`, `build.zig` now compiles `vpi_app.c` against `src/vpi/vpi_user.h`
and links it to the `export fn`s in `src/vpi/root.zig`, and `zig build test-vpi`
runs the 14 Zig tests AND the C application, which asserts exit 0 and the census
line `vpi: scopes=5 ports=11 nets=6 regs=2 params=8 checks=711`.

What that buys is the **§11.6 object model over a lint-only elaboration** — 711
ABI checks that the header's constants and the implementation's agree. What it
does NOT buy is any of the nine clauses below, and the distinction is the whole
point of this section: those clauses are about VALUES, SCHEDULING and
CALLBACKS, and `vpi_host.zig` stops at `.lint` (`compileSource(..., .lint)`), so
there is no running simulation for a value to be read out of or a callback to
fire in. A `.va` fixture still cannot stand in for a C application, and the 13
`p02_*.c` files in `ch11_vpi/` remain uncompiled by anything.

**And the host the suite DOES bind is a stub by construction.** The generated
testbench binds `inst.systf = &no_vpi_app` for any device that declares
`systf_calls` (`lib/backend/tb.zig:670`), and `noVpiApp` returns `0` with
every partial `0` (`lib/backend/tb.zig:1082`). That binding is written into the
emitted runner, so no `.va` file can reach past it — not to a nonzero value,
not to a nonzero derivative, not to a callback of any kind. This is why `01`
and `02` assert what they assert and no more, and it is why a `//! lrm 12.22.1`
here could only ever be a claim about a crossing that no run in this suite
reaches.

Per clause:

- `s12-1` **Overview.** The write-up conventions (Synopsis / Syntax / Returns
  / Arguments / Related routines) and the two tags. Its only normative
  sentence — "All arguments shall be considered mandatory unless specifically
  noted in the definition of the PLI routine" — is a rule about reading the C
  prototypes that follow. Nothing in it constrains a `$name`, an argument
  count, or any source text. Nothing to draft either: a C suite would test
  arity, which is the routine's own clause.
- `s12-22-1` **Derivatives for analog system task/functions.** A `.va` file has
  no handle surface: it writes `$name(args)` and receives a value, while the
  derivative objects are C handles an application allocates in `derivtf`. The
  one source-visible consequence — a declared partial reaching the Jacobian —
  is unreachable for the `no_vpi_app` reason above.
- `s12-31-1` **Simulation-event reasons.** `cbValueChange`, `cbStmt`,
  `cbForce`/`cbRelease`, `cbAssign`/`cbDeassign`, `cbDisable` are discrete
  simulation events and a host's queue state. The only argument for a `.va`
  fixture is the `always @(...)` text that produces them, and that is a §7/§8
  rule with its own clause; citing `12.31.1` for it would credit this clause
  with an event it only *reacts to*.
- `s12-31-2` **Simulation-time reasons.** The five reasons, their time fields,
  and the `cbNextSimTime` exception ("the time structure is ignored"). Host
  time-queue state throughout.
- `s12-31-3` **Analog and related reasons.** The six `acb*` entries. The
  source-level `initial_step` / `final_step` events are a Chapter 5 construct
  that ch05's fixtures pin; the LRM does not connect the two, and `12.31.3`'s
  text is about registering a callback, not about an event keyword.
- `s12-31-4` **Action and feature reasons.** `cbUnresolvedSystf` is the one
  that touches this directory, and the clause's own words are why it cannot be
  cited: features "might not exist in all VPI-compliant products", unlike
  actions which "shall occur in all". An implementation may therefore never
  deliver it, and no `.va` verdict follows.
- `s12-32-1` **System task and function callbacks.** The one near miss — see
  below.
- `s12-32-2` **Declaring derivatives.** `t_vpi_stf_partials` and the `derivtf`
  protocol are C structures; the `.va`-visible half is again the crossing, and
  the crossing is the stub's blind spot.
- `s12-33-2` **Initializing callbacks.** Not merely unpinned — it HAS coverage
  in this tree, just not here: `src/vpi/root.zig:1520`, `test "§12.33.2 runs
  every entry of the table, in order, and stops at the 0"`, passing under
  `zig build test-vpi`. It drives `runStartupTable` with a table handed to it
  and pins what the clause says — a null table is a no-op, both entries run in
  order, the entry after the `0` is not reached. That is the right kind of test
  for it and needs no fixture. The clause's other half — the `@extern`
  reference to the link-time symbol and the vendor-defined linking procedure —
  was unpinned while `tests/vpi_host.zig` was deleted, and is pinned again now
  that it is restored: `vpi_host.zig` calls `runStartupRoutines()`, which
  resolves `vlog_startup_routines` at LINK time against the table
  `tests/vpi_app.c` defines. A table that failed to link, or linked and was
  never walked, fails the step's census assertion rather than passing quietly.
  This is the one clause of the nine the host restore actually closed.

### The near miss: `12.32.1` is already pinned, under `12.33.1`

`12.32.1` is the only one of the nine with a sentence that has a source-level
consequence, and it is the sentence `12.33.1` states in the same words:
"Callbacks to the application pointed to by the calltf routine shall occur
each time the system task or function is invoked during simulation execution."
`12.32.1` then imports `12.33.1` wholesale for the analog domain — "The usage
of the compiletf, sizetf, and calltf routines for the analog system
task/function are identical to those of digital system task/functions
registered with `vpi_register_systf()`" — which is why `48`'s header cites
`12.33.1`, where that content lives.

A `//! lrm 12.32.1` line on `48` was considered and deliberately NOT added.
What `48` observes is the number of INVOCATIONS (which §5.3.1 sequences), and
the calltf callback the cite would be crediting is a C object this suite
cannot construct. Adding it would mark a `s_vpi_*`-structure clause covered on
the strength of a source-level call form — the same inflation the 35 atomic
fixtures disclaim one section above. The clause's other content (`type`
"shall be an integer constant of `vpiAnalogSysTask` or `vpiAnalogSysFunction`",
`sysfunctype`, the NULL-able `sizetf`/`derivtf` pointers, `user_data`) is C and
stays in the row above.

### Drafted, and not yet wired

Neither directory that owns the C half has a build step, so every `.c` below
is compiled by nothing and the row it belongs to is red by construction.

- here: `p03_01`–`p03_11`, `p03_90`, `p03_91` — `12.22.1`, `12.31.3`,
  `12.32.2`, `12.33.2`, plus `12.7`–`12.9`, `12.13`, `12.34` and `12.32`'s
  uniqueness rule. `p03_SPEC.md` is their specification, and its "Build and
  run" section is the missing step: compile the plugin, compile the design
  through the engine to a linked host that can actually solve, install the
  elaborated design as the VPI object model, call `vlog_startup_routines`
  before the first analysis, run the analyses in one process, diff stdout.
  Every one of those is a C-side obligation a `.va` fixture has no spelling
  for.
- `tests/fixtures/ch11_vpi/p02_01`–`p02_13` — `12.31.1`, `12.31.2`, `12.31.4`
  and the `vpi_get_value`/`vpi_put_value` family. Those are that directory's
  clauses; they are named here only so the two halves of one C surface are not
  mistaken for one another.

Until that step exists the nine stay uncited. Seven of them are named by a `.c`
above, none of which any step compiles; `12.33.2` additionally has a passing
Zig unit test in `src/vpi/root.zig`; and `12.1` and `12.32.1` have nothing at
all — `12.1` is the write-up conventions, and `12.32.1`'s one source-level
sentence is `12.33.1`'s, already pinned by `48`.

## Literal fixture inventory

38 fixtures, all `.va`: 35 carry a `//! reject` arm, 3 run and assert, and NONE
is `//! xfail` (grep-measured over this directory). Every one appears in the
table above. The directory holds 43 `.va` files — the other five are the P03
design decks, below.

- `01_analog_systf_resistor_call.va`
- `02_analog_systf_sampler_call.va`
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

The five `p03_*.va` files are designs, not fixtures, and are not in the table:
`p03_ramp_load.va`, `p03_dc_divider.va`, `p03_rc_ac.va`, `p03_sampnhold.va`,
`p03_systf_devices.va`. They are the decks the C plugins in this directory are
written against — the analysable half of the P03 plan, each with a closed-form
solution named in `p03_SPEC.md` — and they carry no `//! lrm` cite because
nothing in them is being asserted. The walk collects them anyway and reports
all five `unasserted`, which is the correct verdict for source that compiles
and asserts nothing, and a FAIL under `--strict`. They are recorded here so the
43/38 split is not mistaken for 43 fixtures.
