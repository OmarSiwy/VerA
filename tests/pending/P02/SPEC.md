# P02 — VPI values, scheduling and system tasks

Thirteen compiled-C VPI applications plus four designs. Every one of them fails
today, for the reason given under "Ground truth" below: none of the routines
they call exists.

## Ground truth, established by reading the source and not the plan

`src/vpi/root.zig` is 1542 lines and exports exactly eleven routines:

    vpi_chk_error  vpi_compare_objects  vpi_free_object  vpi_get  vpi_get_str
    vpi_handle     vpi_handle_by_index  vpi_handle_by_name  vpi_iterate
    vpi_release_handle  vpi_scan

A grep for `vpi_get_value|vpi_put_value|vpi_register_cb|vpi_register_systf|
vpi_printf|vpi_mcd_|vpi_sim_control|vpi_get_time|vpi_remove_cb|
vpi_get_cb_info|vpi_handle_multi` over that file returns nothing but a comment.
`src/vpi/vpi_user.h` (255 lines) says so itself, in the header comment: P02 is
listed as "WHAT IS NOT HERE YET". `s_vpi_value` and `s_vpi_time` are declared
there and nothing consumes them.

So **nothing in this row is implemented**, and none of the fixtures below are
"pin an implemented-without-evidence behaviour" — they are all genuinely new
coverage. The branch `w2/vpi2` contributes nothing: it is the same commit as
`ddt-capform` HEAD.

What *does* exist and is reused: `tests/vpi_app.c` (the P01 application, and the
style every file here copies), `tests/vpi_host.zig` (the simulator half), the
build wiring at `build.zig:600-626`, and a working digital scheduler with
timescales at `src/sim/scheduler.zig` and `src/sim/time.zig`. The existing
`tests/fixtures/ch11_vpi/**` and `tests/fixtures/ch12_vpi_routines/**` files are
compiler accept/reject fixtures — they say what `.va` source is legal, never
what a routine returns — so nothing here duplicates them. `01_analog_systf_
resistor_call.va` already pins the *compiler's* treatment of an unregistered
`$resistor`; `p02_analog.va` deliberately uses the name `$p02_resistor` so the
two cannot be confused.

## LRM clauses covered

| Clause | Subject |
|---|---|
| 2.6.2 + Table 2-1 | scaled notation: `1k`/`2k` in `p02_analog.va` are 1e3/2e3 |
| 11.6.16 | tf call / sys task call / sys func call: `vpiArgument`, `vpiSysTfCall`, `vpiUserSystf`, `vpiUserDefn`, `vpiSysFuncType`, `vpiName` |
| 11.6.25 | callback and time queue objects; NOTE 3's increasing-time ordering |
| 12.2 | error status after every call (reused from P01) |
| 12.6 | `vpi_get_cb_info()` |
| 12.13 | `vpi_get_analog_systf_info()` |
| 12.14 | `vpi_get_systf_info()` |
| 12.15 | `vpi_get_time()`, `vpiSimTime` vs `vpiScaledRealTime`, NULL object |
| 12.16 + Table 12-4 | `vpi_get_value()` and every value format |
| 12.22.1, 12.22.2 | `vpi_handle_multi(vpiDerivative, ...)` and the `$resistor` example |
| 12.24–12.28 | `vpi_mcd_close/name/open/printf`, `vpi_printf` |
| 12.30 | `vpi_put_value()`, the six delay modes, `vpiReturnEvent`, `vpiCancelEvent`, `vpiSchedEvent`/`vpiScheduled` |
| 12.31, 12.31.1, 12.31.2, 12.31.4 | `vpi_register_cb()` and the event, time and action reasons |
| 12.32, 12.32.1 | `vpi_register_analog_systf()`, `derivtf`, the domain-uniqueness rule |
| 12.32.2 | only its `t_vpi_stf_partials` definition and its "declarative only" sentence, which `11` quotes; the derivative *values* reaching a solution are P03's |
| 12.33, 12.33.1, 12.33.2 | `vpi_register_systf()`, `compiletf`/`calltf`/`sizetf`, `vlog_startup_routines` |
| 12.34 | `vpi_remove_cb()` |
| 12.36 | `vpi_sim_control()`, `vpiFinish` |

Verilog-AMS 2.4 §12.2 and §12.31 both defer constant numbering to "the
vpi_user.h file listing in Annex G of the IEEE Std 1364 Verilog specification",
so every constant these files name is spelled by NAME and never by literal —
exactly the discipline `tests/vpi_app.c` already states. See "Header additions
required" below.

## Designs

| File | What it is for |
|---|---|
| `p02_design.v` | `timescale 1ns/1ns. The digital timeline fixtures 01–08 read. Documented event-by-event in its own header. |
| `p02_systf.v` | Two call sites of `$p02_sum`, one of them in a 3-iteration loop, so per-call-site and per-execution callback rates differ. |
| `p02_analog.va` | LRM 12.22.2's `$resistor` shape, two call sites, `r1 = 1k` and `r2 = 2k`. |
| `p02_scales.v` | Two modules, `timescale 1ns/1ps and 1us/1ps, one 1 ps precision. |

What the four designs do at HEAD today, captured rather than described
(`zig build install`, then the commands shown):

    $ ./zig-out/bin/vera --run tests/pending/P02/p02_design.v
    p02_design: t=20 reached

    $ ./zig-out/bin/vera --run tests/pending/P02/p02_systf.v
    error[E1100]: digital source execution failed: this digital expression form
    is not implemented
      --> tests/pending/P02/p02_systf.v:30:9

    $ ./zig-out/bin/vera --run tests/pending/P02/p02_scales.v
    error[E1100]: digital source execution failed: digital execution requires
    exactly one ordinary module
      --> tests/pending/P02/p02_scales.v:15:1

    $ ./zig-out/bin/vera --check --contract tools/contract.zig \
          -I tests/fixtures tests/pending/P02/p02_analog.va
    (no output, exit 0)

So `p02_design.v` — the design eight of the thirteen applications use — already
runs on the digital kernel, and its `t=20 reached` line is genuinely emitted,
which is what makes `08`'s "this line must NOT appear" a real assertion rather
than an absence that is free. `p02_systf.v` needs a `$systf` call form the
digital expression lowering does not have, and `p02_scales.v` needs multi-module
`--run`; both are listed under "Build and run" as work `10` and `13` are blocked
on beyond the VPI routines themselves.

## Fixtures

Each line is: what it pins — expected value — where the number comes from.

1. **`01_get_value_formats.c`** — `vpi_get_value()` over a fully-known value in
   eight formats. `p02_design.known` = `12'b1010_0111_0001`, so bin
   `"101001110001"`, oct `"5161"` (4 groups of 3 from the lsb: 101/001/110/001,
   cross-checked 5·512+1·64+6·8+1 = 2673), dec `"2673"`, hex `"a71"`,
   `vpiIntVal` 2673, `vpiRealVal` exactly 2673.0 (2673 < 2^53), `vpiVectorVal`
   one element with aval 0xa71 / bval 0, and `vpiObjTypeVal` rewriting `format`
   to `vpiVectorVal`. `p02_design.wide` = `64'h00000001FFFFFFFF` gives
   array_size ((64-1)/32+1) = 2 with `vector[0].aval = 0xFFFFFFFF` and
   `vector[1].aval = 0x00000001`, which is 12.16's "the 33rd bit ... shall be
   represented by the lsb of the 1-indexed element" stated as a number.
   `p02_design.text` = `40'h5665724121` gives `vpiStringVal` "VerA!" (0x56 'V',
   0x65 'e', 0x72 'r', 0x41 'A', 0x21 '!') and hex `"5665724121"` — the same
   bits read two ways. Also pins 12.16's two buffer rules: the value-string
   buffer is overwritten by the next `vpi_get_value()` and is a *different*
   buffer from `vpi_get_str()`'s.

2. **`02_get_value_unknown.c`** — the same routine over `12'b1010_zzzz_01x1`.
   bin `"1010zzzz01x1"`; hex `"azX"` because nibble [7:4] is *all* z (lowercase)
   and nibble [3:0] is only *partly* x (uppercase), which is Table 12-4's
   four-character rule and cannot be seen without a mixed group; oct `"5ZZX"`
   for the same reason over 3-bit groups; `vpiIntVal` 2565 = 0xa05 because "any
   bits x or z ... are mapped to a 0"; `vpiVectorVal` aval 0xa07 / bval 0x0f2
   from Figure 12-10's `ab: 00=0, 10=1, 11=X, 01=Z`. Note aval (0xa07) differs
   from the vpiIntVal answer (0xa05) at bit 1, the x bit — asserting both is
   what catches an implementation that computes one from the other. Scalar `z`:
   `vpiScalarVal` → `vpiZ`, bin `"z"`, int 0, vector aval 0 / bval 1.

3. **`03_put_value_delays.c`** — the delay modes of 12.30, as a three-column
   table. Each of `qi`/`qt`/`qp` receives 0xAA@+5 and 0xBB@+20 pure-transport,
   then 0xCC@+10 in inertial / transport / pure-transport respectively. Sampled
   at t = 5, 10, 20, 27, 30 the hand-derived answers are
   `qi` = 0x00, 0xCC, 0xCC, 0xCC→0x5A; `qt` = 0xAA, 0xCC, 0xCC, 0xCC, 0xCC;
   `qp` = 0xAA, 0xCC, 0xBB, 0xEE, 0xEE. Inertial removes *all* events including
   the earlier 0xAA (which is the only thing separating it from transport here);
   transport removes only the later 0xBB. Also pins: `vpiReturnEvent` yields a
   `vpiSchedEvent` handle reading `vpiScheduled` 1 before and 0 after it fires;
   the same call without the mask returns NULL and is not an error;
   `vpiCancelEvent` on an already-fired event is not an error; `vpi_free_object`
   on an event handle frees the handle and the event still fires (that is why
   `qp` is 0xEE and not 0xBB at t=27); `vpiNoDelay` takes effect immediately and
   returns NULL even with `vpiReturnEvent` set.

4. **`04_force_release.c`** — `vpiForceFlag`/`vpiReleaseFlag` on a net driven by
   `assign w = a + 8'd1`. At t=2 the driver says 11; the force writes 240; at
   t=6 the design sets `a = 20` so the driver says 21 while `w` still reads 240;
   at t=10 the release makes `value_p` come back holding **21**, which is
   12.30's "value_p shall contain the current value of the object" and 12.31.1's
   "in the case of a release, the value field shall contain the value after the
   release has occurred". Callback census with `obj = NULL` ("every force and
   release shall generate a callback"): exactly 1 force and 1 release.

5. **`05_cb_time_regions.c`** — the five time-related reasons. `p02_design.s` is
   0x01 before the t=7 queue and 0x42 after, so `cbAtStartOfSimTime(7)` and
   `cbAfterDelay(+7)` must read **0x01** and `cbReadWriteSynch(7)` and
   `cbReadOnlySynch(7)` must read **0x42**; each fires exactly once; a
   `vpi_put_value` from `cbReadOnlySynch` is refused with NULL + `vpiError` and
   leaves the object alone. `cbNextSimTime` registered at t=0 fires at **t=1**,
   because all six initial blocks reach their first delay in the t=0 queue and
   the pending set is {1,5,6,7,40}. `cbAfterDelay`'s delivered time is
   `low = 7`; `cbAtStartOfSimTime` registered with `vpiScaledRealTime` and
   `obj = p02_design` delivers `real = 7.0`. A sixth registration, a
   `cbAtStartOfSimTime` at **t=33** — a time `p02_design` never visits — fires
   exactly once, which is 12.31.2's "A callback can be set for any time, even if
   no event is present" as a test. 11.6.25 NOTE 3: iterating `vpiTimeQueue` from
   NULL at `cbAtStartOfSimTime(2)` yields strictly increasing times whose
   subsequence above 2 is exactly **5, 6, 7, 33, 40** — the design's four
   pending times plus this application's own eventless callback time, because
   11.6.25's data model gives a callback a one-to-one relationship to a time
   queue tagged `vpiParent`. The n-block's t=3 step does *not* appear: it is
   created when the t=2 event runs. **t=999 must not appear**: the
   `cbNextSimTime` registration passes `time->low = 999` and 12.31.2 says that
   structure is ignored, and the exact-set match is the only way this file can
   observe the sentence was obeyed. The census runs from `cbEndOfSimulation`
   (12.31.4), not from a time callback, so the census registration adds no time
   queue for the walk to trip over.

6. **`06_cb_value_change.c`** — how many times `cbValueChange` fires and what it
   carries. `p02_design.n` is written at t = 0, 1, 2, 3, 4 but *changes* only at
   0, 1, 2, 4, so **exactly four** callbacks carrying **0, 5, 9, 2** — the t=3
   write is `9 → 9` and must not produce one, and the t=0 write is `4'bxxxx → 0`
   and must. `p02_design.mem` gives **five** callbacks: four time-0
   initialisations with `index` 0,1,2,3 and value 0, then `index = 2`,
   value 0x7E at t=1, which is 12.31.1's memory-word `index` rule as a number.
   Also pins that `time->type` and `value->format` come back as registered and
   `user_data` is "equivalent to the user_data field passed to
   `vpi_register_cb()`".

7. **`07_cb_remove_and_info.c`** — reentrancy and removal. A `cbValueChange` on
   `n` removes **itself** during its second dispatch → exactly **2**
   invocations; from that same dispatch it registers an heir, which then sees
   the t=2 and t=4 changes → exactly **2** invocations carrying **9** and **2**.
   A `cbValueChange` on `g` removed at t=2 (after g's t=0 change, before its
   t=5 one) → exactly **1** invocation. `vpi_remove_cb` returns **1** the first
   time and **0** the second, because "after `vpi_remove_cb()` is called with a
   handle to the callback, the handle is no longer valid". `vpi_get_cb_info()`
   round-trips reason, `cb_rtn`, `obj` (via `vpi_compare_objects`), `user_data`
   by pointer, `time->type` and `value->format`.

8. **`08_cb_action_sim_control.c`** — 12.31.4 defines **six** action-related
   reasons (`cbEndOfCompile`, `cbStartOfSimulation`, `cbEndOfSimulation`,
   `cbError`, `cbPLIError`, `cbTchkViolation`), all of which "shall occur in all
   VPI-compliant products". This fixture covers the three a clean run reaches by
   existing; the other three are listed under "Deliberately NOT covered". They
   arrive once each in the order
   `cbEndOfCompile`, `cbStartOfSimulation`, `cbEndOfSimulation` (order string
   **"CSE"**), registered with `time` and `value` left NULL per 12.31.4.
   `vpi_get_time` reads **0** inside `cbStartOfSimulation`. A
   `vpi_sim_control(vpiFinish, 0)` from t=12 returns **1** and ends the run at
   **t=12**, so `g`'s t=20 change is never delivered: exactly **3**
   `cbValueChange` callbacks on `g` (t=0, 5, 10) and the design's
   `"p02_design: t=20 reached"` never appears on stdout.

9. **`09_printf_mcd.c`** — `vpi_printf("p02 printf %d %s\n", 7, "ok")` returns
   **16**, the length of the expansion. `vpi_mcd_close(0x7)` returns **0x7**
   because channels 1–3 "can not be closed" and the failure return is "the mcd
   value of the unclosed channels". The first user file gets mcd **8** and the
   second **16** (channels 4 and 5; 12.27 fixes channel N to bit N-1 and 12.26
   reserves 1–3). Reopening an open file returns **the same** descriptor.
   `vpi_mcd_printf(a, "alpha\n")` returns **6**, `vpi_mcd_printf(a|b, "both\n")`
   returns **5**. After closing both, the two files on disk hold exactly
   `"alpha\nboth\n"` (11 bytes) and `"both\n"` (5 bytes) — the only check that
   distinguishes "wrote to one channel" from "wrote to both". Closing an open
   channel returns **0**, closing it again returns **its own mcd**, and
   `vpi_mcd_name` on a closed channel returns **NULL**.

10. **`10_systf_digital.c`** — `vpi_register_systf()` rates and values against
    `p02_systf.v`. `$p02_sum` has two call sites, one in a 3-iteration loop:
    **compiletf 2, calltf 4**, and every compiletf precedes every calltf.
    `$p02_note` 1/1, `$p02_wide` 1/1 with **sizetf 1**, `$p02_plain` 1/1 with
    **sizetf 0**. `vpi_get(vpiSize)` on the `$p02_wide` call is **40** (what the
    sizetf returned) and on `$p02_plain` is **32** ("if no sizetf is provided, a
    user-defined system function of vpiSizedFunc shall return 32-bits"). The
    return values, by hand: `$p02_sum(3,4)=7`, then `10, 11, 12` from the loop
    (the second argument is the loop variable `i`, so a calltf that cached its
    arguments at build time would produce 10, 10, 10), leaving
    `p02_systf.r == 12`. `$p02_wide` stores `40'h0123456789` and `$p02_plain`
    stores `32'hDEADBEEF`, read back as hex strings. `vpi_put_value` from
    *compiletf* (the function is not active) must be **ignored** — 0x7777 never
    appears. `vpi_iterate(vpiUserSystf, NULL)` yields **4**.
    `vpi_get_systf_info` round-trips type, sysfunctype, tfname and both function
    pointers.

11. **`11_systf_analog.c`** — `vpi_register_analog_systf()` and the derivtf
    phase against `p02_analog.va`. **compiletf 2** and **derivtf 2** (one per
    call site, both build-phase), every one of them before the first calltf.
    The third argument reads exactly **1000.0** at site 1 and **2000.0** at
    site 2 (LRM 2.6.2 Table 2-1: the symbol "K, k" is 1e3, and 2.6.2's own
    example list prints `7k`), so the conductances are exactly **0.001** and
    **0.0005** — both `1.0/1000.0 == 0.001` and `1.0/2000.0 == 0.0005` hold in
    binary64 because IEEE division is correctly rounded and the literals parse
    to the same values. derivtf declares `count = 1, of = {1}, to = {2}`, so
    `vpi_handle_multi(vpiDerivative, arg1, arg2)` must be **non-NULL** and
    `vpi_handle_multi(vpiDerivative, arg1, arg3)` must be **NULL with
    `vpiError`**, because 12.22.1 permits the call "only ... for those
    derivatives allocated during the derivtf phase".
    `vpi_get_analog_systf_info` round-trips type, tfname and all three function
    pointers.

12. **`12_systf_domains.c`** — the four corners of 12.32's uniqueness rule for
    one name `$p02_both`: digital registration **succeeds**, a second digital
    registration **is refused** (NULL + `vpiError`), an analog registration of
    the same name **succeeds**, a second analog registration **is refused**. The
    two live handles are two objects, so `vpi_compare_objects(d, a) == 0`. The
    refused duplicates must leave the successful registrations untouched, which
    is read back through `vpi_get_systf_info`/`vpi_get_analog_systf_info` — a
    check the return value alone cannot make. Also: a `tfname` whose first
    character is not `$` is refused. **This is the only fixture in the set whose
    subject is refusals**, and it carries four positive registrations of its
    own; the other twelve are positive coverage.

13. **`13_get_time_scaling.c`** — one instant, three answers. At 3 ns in a
    design whose precision is 1 ps: `vpi_get_time(NULL, vpiSimTime)` is
    **3000**, `vpi_get_time(p02_scales_top, vpiScaledRealTime)` is exactly
    **3.0** (1 ns unit), `vpi_get_time(p02_scales_top.u, vpiScaledRealTime)` is
    **0.003** to 1e-12 (1 us unit), and `vpi_get_time(NULL,
    vpiScaledRealTime)` is **3000.0**. The 1000x gap between the two scaled
    readings is the discriminator: a tool that ignores the object answers the
    same number twice.

Twelve positive fixtures, one refusal-centred fixture. The refusal checks
sprinkled through 05, 10 and 11 (`vpi_put_value` from `cbReadOnlySynch`, a put
to an inactive function, an undeclared derivative pair) each sit inside a
fixture whose main body is positive.

## Header additions required before any of this compiles

`src/vpi/vpi_user.h` currently declares neither the routines nor most of the
constants. Its own comment says P02 "adds routines rather than changing the ABI"
— that is true of `s_vpi_value`/`s_vpi_time`, which these files use unchanged.
What must be added, all with IEEE 1364-2005 Annex G's numbering (the header's
existing rule, and §12.2/§12.31's explicit deferral):

- **types**: `s_vpi_strengthval`, `s_cb_data`/`p_cb_data`, `s_vpi_systf_data`/
  `p_vpi_systf_data`, `s_vpi_analog_systf_data`/`p_vpi_analog_systf_data`,
  `t_vpi_stf_partials`/`p_vpi_stf_partials` (`count`, `derivative_of`,
  `derivative_to`, per 12.22.2's printed example — **not** per 12.32.2's
  structure definition, which spells the third field `derivative_wrt` and makes
  `t_vpi_stf_partials` a struct tag rather than a type name; see the two-
  spellings bullet under "Ambiguities resolved by convention"). The header must
  therefore `typedef` the name `t_vpi_stf_partials` itself, or
  `11_systf_analog.c:149` (`static t_vpi_stf_partials derivs;`, copied from the
  LRM's own example) does not compile.
- **value formats**: `vpiBinStrVal vpiOctStrVal vpiDecStrVal vpiHexStrVal
  vpiScalarVal vpiIntVal vpiRealVal vpiStringVal vpiVectorVal vpiStrengthVal
  vpiTimeVal vpiObjTypeVal vpiSuppressVal`.
- **scalar values**: `vpi0 vpi1 vpiZ vpiX vpiH vpiL`.
- **put_value flags**: `vpiNoDelay vpiInertialDelay vpiTransportDelay
  vpiPureTransportDelay vpiForceFlag vpiReleaseFlag vpiCancelEvent
  vpiReturnEvent`.
- **callback reasons**: `cbValueChange cbForce cbRelease cbAtStartOfSimTime
  cbReadWriteSynch cbReadOnlySynch cbNextSimTime cbAfterDelay cbEndOfCompile
  cbStartOfSimulation cbEndOfSimulation`.
- **objects/properties**: `vpiSchedEvent vpiScheduled vpiArgument vpiSysTfCall
  vpiUserSystf vpiUserDefn vpiSysFuncType vpiTimeQueue vpiDerivative
  vpiRealVar`.
- **systf constants**: `vpiSysTask vpiSysFunction vpiIntFunc vpiRealFunc
  vpiTimeFunc vpiSizedFunc vpiAnalogSysTask vpiAnalogSysFunction`.
- **sim_control**: `vpiStop vpiFinish vpiReset vpiSetInteractiveScope`.
- **routines**: `vpi_get_value vpi_put_value vpi_get_time vpi_register_cb
  vpi_remove_cb vpi_get_cb_info vpi_register_systf vpi_register_analog_systf
  vpi_get_systf_info vpi_get_analog_systf_info vpi_handle_multi vpi_printf
  vpi_mcd_open vpi_mcd_close vpi_mcd_name vpi_mcd_printf vpi_sim_control`.

## Ambiguities resolved by convention, and flagged as such

These are places where the fixture asserts something the LRM does not state in
so many words. If an implementer disagrees, the fixture is the thing to change,
not the implementation.

- **First user MCD is 8.** 12.26 reserves channels 1–3 and 12.27 maps channel N
  to bit N-1; "the first free channel is 4" is a derivation from those two
  sentences, not a quotation. `09` separately asserts the part that is beyond
  argument — that a user channel never aliases 0x7.
- **`vpi_mcd_printf` returns the length of the expansion, not the expansion
  times the number of channels.** 12.27 says "the number of characters printed"
  without qualifying it for the multi-channel case.
- **`vpi_get_cb_info`'s `time`/`value` sub-structures are the caller's.** 12.6
  puts "the memory for this structure" on the user and is silent about the two
  pointers; `07` supplies both and expects them filled.
- **`vpiAnalogSysTask` spelling.** 12.32.1's prose says "vpiAnalogSysTask or
  vpiAnalogSysFunction", Figure 12-18's comment says
  "vpiAnalogSysTask,vpiAnalogSysFunc", and Figure 12-6's comment (in 12.13) says
  "vpiSys[Task,Function]". The fixtures use the prose spelling.
- **`t_vpi_stf_partials`: two spellings, and the LRM prints both.** 12.32.2
  defines `typedef struct t_vpi_stf_partials { int count; int *derivative_of;
  int *derivative_wrt; } s_vpi_stf_partials, *p_vpi_stf_partials;` — third field
  `derivative_wrt`, and `t_vpi_stf_partials` only a struct **tag**. 12.22.2's
  example, the only executable code the LRM prints for this structure, declares
  `static t_vpi_stf_partials derivs;` (not legal C against that typedef) and
  assigns `derivs.derivative_to`. `11_systf_analog.c` follows the example, in
  its own header and at lines 149/159, because that is what an implementer
  copies. This is a convention, not a reading: an implementer who prefers
  12.32.2's `derivative_wrt` changes `11_systf_analog.c:159` and the header
  bullet above, and nothing else in the row moves. Recorded here because the
  cost of getting it wrong is a file that will not compile, which reads like a
  fixture defect and is not one.
- **The systf callback signatures.** The LRM's structure definitions spell every
  one of them `int (*calltf)()` — an unprototyped function pointer — and its own
  examples disagree with each other: 12.22.2 passes `p_cb_data` to
  `resistor_compiletf`/`resistor_derivtf` but declares
  `resistor_calltf(int data, int reason)`. These fixtures use
  `PLI_INT32 fn(PLI_BYTE8 *user_data)` for the digital callbacks (Annex G's
  prototype, and what 12.33.1's user_data sentence describes) and
  `PLI_INT32 fn(p_cb_data)` / `p_vpi_stf_partials fn(p_cb_data)` for the analog
  ones (12.22.2's own spelling). The header must pick one and these files must
  follow it.
- **Relative order within a t=7 region.** 12.31.2 does not order
  `cbAtStartOfSimTime` against `cbAfterDelay`, nor `cbReadWriteSynch` against
  `cbReadOnlySynch`. `05` asserts only the partial order the clause does state:
  both "before" reasons precede both "after" ones.
- **The current time queue in a `vpiTimeQueue` iteration.** 11.6.25 NOTE 5
  qualifies whether the current queue is returned in a way that does not have a
  single reading, so `05` asserts only the times strictly greater than the
  current one.
- **A callback wake-up at an eventless time IS a `vpiTimeQueue` entry.** `05`
  asserts that its own `cbAtStartOfSimTime(33)` shows up in the walk at t=2.
  The argument is 11.6.25's data model — callback has a one-to-one relationship
  to time queue tagged `vpiParent`, and NOTE 4 speaks of "the simulation queue"
  undivided — plus 12.31.2's "A callback can be set for any time, even if no
  event is present", which makes t=33 a time the simulator must wake at. The
  clause never says it in one sentence, so it is flagged. **This is the one
  assertion in `05` an implementer may contest**; contest it here and not by
  deleting the t=33 registration, because an implementation that keeps callback
  wake-ups out of `vpiTimeQueue` is exactly what the previous revision of this
  fixture would have rewarded (see "Corrected after review").
- **`vpi_get_value(vpiIntVal)` on a 64-bit object** is not asserted anywhere;
  truncation to `PLI_INT32` is standard practice but 12.16's Table 12-4 does not
  say it.

## Deliberately NOT covered

- **`vpiStrengthVal` and `s_vpi_strengthval`.** Table 12-4 defines the format
  but defers the encoding to "strength coding in the LRM", and no strength
  number in this row would be derived rather than copied from a vendor header.
  The struct is still listed as a required header addition.
- **`vpi_put_delays` / `vpi_get_delays` (12.29, 12.11)** and the whole
  `s_vpi_delay` surface. They need gate and module-path objects, which are D06's
  and H-row material; adding them here would be a fixture about primitives
  wearing a VPI costume.
- **`cbStmt`, `cbAssign`, `cbDeassign`, `cbDisable`** (12.31.1). They need
  statement objects and procedural `assign`/`deassign`, neither of which exists
  in the object model P01 built.
- **The feature-related callbacks** of 12.31.4 (`cbStartOfSave`,
  `cbEnterInteractive`, `cbUnresolvedSystf`, ...). The clause itself says
  "features might not exist in all VPI-compliant products", so they are not
  conformance obligations.
- **Three of 12.31.4's six ACTION reasons** — `cbError`, `cbPLIError` and
  `cbTchkViolation`. These are conformance obligations (actions "shall occur in
  all VPI-compliant products") and their absence here is a gap, not a judgement.
  `cbError`/`cbPLIError` need an application that provokes a run-time error,
  which cannot coexist in one file with `p02_check.h`'s `expect_no_error`
  discipline; they want a fixture whose subject is error recovery, and that
  fixture would own the claim `08` used to make loosely. `cbTchkViolation`
  needs a timing check and therefore a specify block — no design in this row has
  one and no clause in the coverage table above reaches them.
- **`vpi_sim_control(vpiStop, ...)`, `vpiReset`, `vpiSetInteractiveScope`.**
  `vpiStop` enters interactive mode, which a batch acceptance test cannot
  observe without inventing a convention for what interactive means here.
- **`vpi_get_vlog_info` (12.17), `vpi_get_real` (12.18)**, and `vpiObjectVal`'s
  spelling discrepancy with `vpiObjTypeVal` in Table 12-4.
- **All of P03**: `vpi_get_analog_value` (12.10), `vpi_get_analog_time` (12.9),
  `vpi_get_analog_freq` (12.8), `vpi_get_analog_delta` (12.7), the `acb*`
  reasons of 12.31.3, `vpiRejectTransientStep`/`vpiTransientFailConverge`, and
  the propagation of the partial derivatives `11_systf_analog.c` writes into the
  ARPice matrix. `11` stops at "the derivative handle exists, is writable, and
  the undeclared one is not"; whether writing it changes a DC solution is a P03
  host fixture.
- **The analog `calltf` invocation count.** A solver calls it once per Newton
  iteration, so the count is the solver's property and not the LRM's. `11`
  asserts only `>= 2` (both call sites evaluated) and the build-before-call
  ordering.
- **A host circuit fixture for `$p02_resistor`.** The obvious one — 2 V across
  `p02_analog`, expect 2 mA + 1 mA = 3 mA — needs ARPice to load a C VPI plugin,
  which no mechanism in either tree provides yet. Nothing was written under
  `ARPice/tests/pending/P02/`; this row's deliverable is entirely in the VerA
  tree.

## Build and run

These compile against a `vpi_user.h` that does not yet declare most of what they
call, so today they fail at the C compiler. Once the header and the routines
land, wire them the way `tests/vpi_app.c` is already wired at
`build.zig:600-626` — one executable per `.c`, each pairing the application with
its design:

    zig build test-vpi

with, per fixture, a module built from an extended `tests/vpi_host.zig` that
(a) compiles the named design, (b) installs it as the object model, (c) calls
`vlog_startup_routines`, and (d) — the part `vpi_host.zig` does not do today —
**runs the simulation**, driving `src/sim/scheduler.zig` so the time and event
callbacks have something to fire on. Fixtures 09 and 12 do all their work at
`cbEndOfCompile`/startup and would pass under the existing lint-only host once
the routines exist; the other eleven need step (d).

Design pairing:

| Application | Design |
|---|---|
| 01, 02, 03, 04, 05, 06, 07, 08 | `p02_design.v` |
| 09 | `p02_design.v` (any design; it only needs a run to happen) |
| 10 | `p02_systf.v` |
| 11 | `p02_analog.va` |
| 12 | `p02_analog.va` (nothing is invoked; only the table is exercised) |
| 13 | `p02_scales.v` |

Each application prints exactly one census line, `p02: <name> checks=<N>`, and
exits non-zero at the first failed check — the same contract `build.zig` already
asserts for `vpi_app.c` with `expectExitCode(0)` and `expectStdOutEqual`. The
`<N>` is read off the first green run, as the existing `checks=711` was. Two
applications have extra expected stdout:

- **09** — `vpi_printf` writes to stdout, and the design runs to t=20, so the
  full expected transcript is, in order:
  `p02 printf 7 ok`, `p02: 09_printf_mcd checks=<N>`,
  `p02_design: t=20 reached`.
- **08** — the design's `p02_design: t=20 reached` must **not** appear; the
  expected transcript is the single census line. That absence is half the
  assertion that `vpi_sim_control(vpiFinish, 0)` worked.

`09` writes and then removes `p02_mcd_a.log` and `p02_mcd_b.log` in the working
directory; give it a cache-relative cwd if the build runs fixtures in parallel.

## Corrected after review

Three defects were attributed to this row by the review; all three are fixed
here, and a second pass over the citations found a fourth. Nothing in `src/`,
`build.zig` or `tests/fixtures/` was touched to accommodate any of them.

1. **`05_cb_time_regions.c` measured a time queue it had polluted itself.**
   (Class A — a fixture a conforming implementation fails.) It asserted that the
   pending times above 2 were exactly `{5, 6, 7, 40}` while itself registering a
   `cbReadOnlySynch` at **t=30**, a time `p02_design` never visits. 11.6.25's
   data model gives a callback a one-to-one relationship to a time queue tagged
   `vpiParent`, so if that callback can fire at all, t=30 is a queue entry and
   the walk sees `{5, 6, 7, 30, 40}`. The cheapest way to satisfy the old
   assertion was to hide callback wake-ups from `vpiTimeQueue` — the wrong
   direction.

   The repair does not delete the callback-only time; deleting it would leave
   the only thing 11.6.25 says about callbacks and queues untested. Instead:

   - the census moved from `cbReadOnlySynch(30)` to `cbEndOfSimulation`, an
     *action* reason (12.31.4), which schedules no time queue at all;
   - one callback-only time is now **declared**: a `cbAtStartOfSimTime` at
     **t=33**, which 12.31.2 licenses in as many words — "A callback can be set
     for any time, even if no event is present";
   - it is asserted to fire exactly once, at 33, with `s == 0x42`;
   - the walk's expected set is now exactly `{5, 6, 7, 33, 40}` — the design's
     four, plus this file's one — and the header derives each member by source.

   Every other time this application registers (1 via `cbNextSimTime`, 2, and
   the four at 7) coincides with a `p02_design` event, so nothing else is
   double-counted. The exact-set form additionally makes **t=999 asserted
   absent**, which is the only way this file can observe 12.31.2's "For reason
   `cbNextSimTime`, the time structure is ignored" — a `cbNextSimTime` that
   scheduled at its passed time would land at 999 and fail the walk, where
   before it could only be caught by firing at the wrong moment. The walk also
   now checks `time->high == 0`.

   The t=33-is-visible reading is the one contestable assertion and is listed
   under "Ambiguities resolved by convention" with its argument and with the
   reason it must be contested there rather than by removing the registration.

2. **`p02_analog.va:21`, `11_systf_analog.c:48` and SPEC.md cited "LRM 2.5" for
   scale factors.** (Class B.) Opened: `docs/ch2-lexical.html` §2.5 is
   *Operators* and contains no scale factor. Scaled notation is **§2.6.2 Real
   constants**, whose Table 2-1 ("Scaled Symbols and notation") gives `T 1e12,
   G 1e9, M 1e6, K/k 1e3, m 1e-3, u 1e-6, n 1e-9, p 1e-12, f 1e-15, a 1e-18`,
   and whose own example list prints `7k` as a valid real constant — which is
   also the authority for `1k` being well-formed without a decimal point. All
   three sites now cite §2.6.2 + Table 2-1, and §2.6.2 is added to the clause
   coverage table.

3. **`08_cb_action_sim_control.c` presented three of 12.31.4's six action
   reasons as the whole list.** (Class B.) The header closed its quotation after
   `cbEndOfSimulation` and then wrote "which is why only these three are
   asserted", against a clause that defines **six**: `cbEndOfCompile`,
   `cbStartOfSimulation`, `cbEndOfSimulation`, `cbError`, `cbPLIError`,
   `cbTchkViolation` — all of them things that "shall occur in all VPI-compliant
   products". The quotation is now complete and the header says explicitly that
   covering three is a scope decision, with a reason per omitted reason.

   The withdrawn claim did not evaporate: `cbError`, `cbPLIError` and
   `cbTchkViolation` are now named in **"Deliberately NOT covered"** as a real
   gap in this row, not as a judgement about the clause. They come back when
   (a) a P02 fixture whose subject is error recovery exists — `cbError` and
   `cbPLIError` require provoking a run-time error, which cannot coexist in one
   file with `p02_check.h`'s `expect_no_error` after every call — and (b) a
   design in this row has a specify block, which `cbTchkViolation` needs and
   which no clause in this row's coverage list reaches.

Also corrected while in the files, not review findings: `p02_design.v`'s section
comments referenced the applications by the wrong ordinal throughout
(`05_force_release`, `06_cb_time_regions`, `07/08_cb_value_change*`,
`09_cb_action_sim_control` — each one off by one against the actual filename),
and its future-queue census now states that the times listed are the ones *the
design* contributes and that an application registering a callback elsewhere
adds its own.

### Second pass — verification, and one miscite the review did not catch

4. **`11_systf_analog.c` attributed 12.32.2's "declarative only" sentence to
   12.32.1.** Found by opening both while re-checking the row's citations, not
   by the review. `docs/ch12-vpi-routines.html` §12.32.1 is *System task and
   function callbacks* (it carries the compiletf/derivtf field and build-phase
   sentences the same header quotes, correctly, further up); the sentence "The
   purpose of this function is declarative only, it does not assign any value to
   the derivative being declared" is in §12.32.2 *Declaring derivatives for
   analog system task/functions*, which also holds the `t_vpi_stf_partials`
   definition. Header fixed, and §12.32.2 added to the clause table with its
   scope stated so it is not read as a claim on P03's territory.

5. **The `derivative_to`/`derivative_wrt` conflict is now stated instead of
   assumed.** While compiling the row against a stub header (below) `11` was the
   one file that failed, on `static t_vpi_stf_partials derivs;`. That is not a
   fixture bug: the LRM contradicts itself, 12.32.2's typedef against 12.22.2's
   example, and this row has to pick one. It picks the example, and now says so
   in the fixture header, in "Ambiguities resolved by convention" and in the
   header-additions list, with the one line to change if an implementer picks
   the other. Previously the SPEC asserted `derivative_to` "per 12.22.2's
   printed example" without mentioning that the clause which *defines* the
   structure disagrees.

6. **Every clause this row cites was opened.** All 28 (`11.6.16 11.6.25 12.2
   12.3 12.6 12.13 12.14 12.15 12.16 12.21 12.22.1 12.22.2 12.24 12.25 12.26
   12.27 12.28 12.30 12.31.1 12.31.2 12.31.4 12.32 12.32.1 12.32.2 12.33
   12.33.1 12.33.2 12.34 12.36`, plus `2.6.2`) resolve to a heading whose title
   matches the use made of it, and every quoted sentence was matched against
   `docs/*.html` with punctuation and whitespace normalised away. Two
   deliberate departures from verbatim survive and are correct: `10`'s "The
   sizetf application shall only [be] called" brackets an insertion into the
   LRM's own dropped word, and `08`'s "the three action reasons that shall occur
   in all VPI-compliant products" is this file quoting its own withdrawn
   revision, not the LRM.

7. **Build spill removed.** Four `.o` files left behind by the compile check
   (`05`, `06`, `08`, `13`, ~275 KB) were deleted from this directory.

### Reproducing the two claims this document makes about running things

The design transcripts under "Designs" were captured from
`zig build install && ./zig-out/bin/vera …`, not typed.

The "fails at `cc`" claim is reproducible without any stub:

    $ cc -fsyntax-only -Isrc/vpi -Itests/pending/P02 tests/pending/P02/01_get_value_formats.c
    tests/pending/P02/01_get_value_formats.c:77:24: error: unknown type name 'p_cb_data'

— and the same for the other twelve, first error being an unknown `p_cb_data`,
`vpiIntVal`, `vpiArgument`, `vpiRealVal` or `vpi_get_time`. That is the whole
row's status today, and it is what "13 (all at `cc`)" in the manifest means.

To check that the thirteen are *C*-correct rather than merely unbuildable, write
a throwaway header that `#include`s `src/vpi/vpi_user.h` and adds exactly the
types, constants and prototypes listed under "Header additions required" (the
constant values are irrelevant to a syntax check; use sequential placeholders),
put it first on the include path, and compile with `-fsyntax-only -Wall
-Wextra`. All thirteen then compile; the only diagnostics are
`unused function 'expect_error'` / `'p02_by_name'` from `p02_check.h`, which are
`static` helpers not every application uses. Do **not** commit such a header:
the real one is the row's deliverable and must carry Annex G's numbering.

Not changed, and why: no fixture in this row carries a `//!` directive — the
four designs are compiled as designs by the C applications' host, not by
`tests/torture.zig` — so the bare-`//! reject` finding does not apply here.
