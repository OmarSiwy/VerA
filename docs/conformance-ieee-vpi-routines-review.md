# IEEE Clause 27 VPI routine source/evidence review

Reviewed 2026-09-23 against `docs/1364-2005.pdf`, SHA256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Complete Clause 27 text, routine tables, examples and numbered tables traversed:
printed418–466 / physical448–496. Visual checks cover printed419,425,430–431,
439,449,451,455,457–459,462, including every numbered table27-1 through27-6.
Other pages are text-reviewed, not independently visually certified. Rendering:
`pdftoppm -f PAGE -l PAGE -scale-to 1550 -singlefile -png docs/1364-2005.pdf PREFIX`.

This is a systematic source traversal and bounded probe handoff, not exhaustive
atomic closure or a conformance measurement. Existing AMS Chapter12 review is
`conformance-ch12-review-draft.md`. Clause26 interface/object reviews and AnnexG
header audit are separately owned; their API phase and ABI findings apply here.

## Routine obligation register

Rows enumerate independent work groups, not completed tests. Each still needs
applicable positive, invalid-input, boundary, lifetime and phase cases. A header
declaration or keyword count does not discharge a row.

| Clause / printed pages | Required behavior and discriminating boundaries |
|---|---|
|27 introduction /418|Arguments mandatory unless expressly optional; exact routine argument and return contracts matter.|
|27.1 /418–419|Previous-call severity; zero for no error; every other VPI call resets status; repeated chk_error preserves it; NULL information pointer allowed; state/level/message/product/code/file/line information.|
|27.2 /420|Compare object identity through routine, not C pointer equality; same/different objects.|
|27.3 /420–421|Stop/finish/reset deferred until application returns with required diagnostic/reset arguments; interactive scope changes immediately; success1/failure0. Stop/reset depend on applicable simulator features.|
|27.4 /421|Flush simulator output and current log; success0, nonzero failure.|
|27.5 /421|Explicit iterator cleanup when abandoning traversal; automatic cleanup at scan NULL/error; success1/failure0; other object allocation is implementation-dependent.|
|27.6 /422|Integer/boolean properties, boolean0/1; NULL time unit/precision returns simulation unit; protected objects generally error; error return vpiUndefined.|
|27.7 /422–423|Read registered simulation callback fields into application-allocated structure, including index.|
|27.8 /423|Restart-only get_data, sequential per-ID cursor independent of read chunk sizes; excess request warns, zero-fills remainder, returns actual bytes; shorter retrieval legal; allocated destination.|
|27.9 /424–426|Delay/pulse read; delay structure time_type controls format, individual time.type ignored; primitive/intermodule2or3, path1/2/3/6/12, timing-check actual limits; Table27-2 array sizes1/3/9 times count, per-delay ordering.|
|27.10 /426|Shared temporary property-string buffer; copy before next call; distinct buffer from get_value; protected-object error.|
|27.11 /427|Read system task/function registration into application-owned structure; correct function type and callbacks/user data.|
|27.12 /428|Current time scaled by object, NULL uses simulation unit; time-queue handle returns scheduled future time; requested real/simulation format.|
|27.13 /429|Per-call-site user data; absent/failure NULL; reset/restart clears and application restores via save/restart callbacks.|
|27.14 /429–435|All Table27-3 formats and ObjType format rewriting; x/z→0 for IntVal; real conversion uses4.8.2 rounding, real StringVal decimal at most16digits; vector32-bit chunks/LSB ordering/aval-bval four-state encoding; interface owns returned pointer storage until next get_value, callback vector storage until return; variable strengths strong; independent property/value buffers; UDP symbol encoding requires source-anomaly resolution.|
|27.15 /435–436|argc/argv/product/version; argv0 tool name; nested option-file array representation if vendor supports option files; success1/failure0.|
|27.16 /436–437|One-to-one model edges; protected-object errors; distinguish valid absent edge from unsupported access.|
|27.17 /437|Access-by-index objects; legal selections yield handles; illegal Verilog selections NULL; protected error.|
|27.18 /438|Multi-index order follows left-to-right dimensions, optional final bit index; legal selection handle, illegal selection NULL; protected error.|
|27.19 /438–439|Fullname objects; NULL scope top-level lookup; supplied scope restricts lookup to that scope; protected scope/path error. See AMS distinction below.|
|27.20 /439|Intermodule path via equal-width output/input ports, including different hierarchy levels.|
|27.21 /439–440|One-to-many iterator type; vpiUse recovers creation reference; empty set NULL; protected error.|
|27.22 /440–441|Close channel set or fopen fd; success0, unclosed-channel mask on failure; descriptor1 cannot close.|
|27.23 /441|Flush specified channel buffers; success0/nonzero failure.|
|27.24 /441|Single-channel/fd name; NULL on error; buffer overwritten by next call, copy if retained.|
|27.25 /442|Open writable MCD, zero error; existing file open returns existing descriptor; shared HDL descriptors; reserved low stdout/log and high fd bits.|
|27.26 /443|Write selected MCD channels using C fprintf formatting; count or EOF; compatible HDL MCDs but not high-bit fd; log/stdout channel semantics.|
|27.27 /444|Same MCD output contract with already-started va_list.|
|27.28 /444|C printf formatting, output plus current log; count or EOF.|
|27.29 /445–447|Save-only put_data with positive byte count, per-ID concatenation independent of call ordering and future retrieval chunks; bytes written or0 error. Feature applicability is distinct from ignoring an API call.|
|27.30 /447–449|Delay/pulse writes use same ordering/count expansion as27.9; changing only delay preserves pulse limits; append flag and time format need further inherited cross-reference cases.|
|27.31 /450|Per-call-site user data store success1/failure0; reset/restart clears.|
|27.32 /450–453|Inertial cancels all object events; modified transport cancels later events; pure transport preserves; no-delay/force/release/cancel modes; return-event handle only with delayed scheduled event; release returns released value; cancel does not undo earlier cancellations and frees event handle; free_object frees handle without cancelling event; elapsed-event cancellation legal; net override lasts until driver change; real StringVal/vector StrengthVal illegal; UDP and system-function writes require no-delay; inactive function write ignored, absent return defaults0; named event permits NULL value.|
|27.33 /453–454|Registration/returned handle; simulator-owned callback structures and pointed data, copy before return.|
|27.33.1 /454–456|Value/statement/force/release/assign/deassign/disable reasons; requested time/value; NULL force/release object means global; array changed member/rightmost index; strength-only changes; event statements have NULL value; certain variable bit-select callback registrations illegal.|
|27.33.1.1–.3 /456–458|Statement callbacks before specified action; suppress time→NULL; valueNULL/index0; duplicate registration causes duplicate callbacks; Table27-6 per-statement timing; module-wide single removable callback, protected statements excluded.|
|27.33.2 /458–459|Start-time/NBA/read-write/end-time/read-only/next-time/after-delay phases; read-write may be before or after NBA (do not assert one); time required even when next-time ignores magnitude; suppress/NULL time errors; prohibited zero-delay start/read-write registrations; allowed recursive start callback in same slice; object real-time scaling; callback reports actual current time.|
|27.33.3 /460–461|Required action versus optional feature reasons; action payloads including timing-check object/unresolved name; OS signal safe-point handling; restart retains only start/end restart callbacks; user-data pointer portability caveat.|
|27.34.1 /461–463|Task/function types; identifier name rules; compile/call/size phases; optional callbacks; sizetf only sized functions, default32bits if omitted; user_data sole argument.|
|27.34.2–.3 /463–464|Vendor startup table/location/link procedure; NULL sentinel; multiple registrations; dynamic registration/removal allowed during application. Clause26 limits what startup may actually call.|
|27.35 /465|Remove simulation callback success1/failure0; handle invalid afterward.|
|27.36 /465–466|Scan instantiated hierarchy; NULL invalidates iterator, never reuse it.|
|27.37 /466|Simulator/log printf contract using already-started va_list.|

## Existing evidence and source distinctions

`src/vpi/root.zig` exports a small hierarchy/property/identity/error/iterator
subset. The production header explicitly excludes runtime values, callbacks and
system-task registration. `tests/vpi_app.c` and `tests/vpi_host.zig` exercise real
C linkage but invoke traversal within startup after installing an elaborated
design. Clause26.2.4 permits only registration calls there. Keep those tests as
implementation regression evidence, not valid-phase coverage of every routine.
The Clause26 agent supplies end-of-compile traversal probes separately.

IEEE27.19 and AMS12.21 differ: IEEE supplied-scope search is local only; AMS
expressly uses HDL scope-search rules. Current upward-search assertions in
`tests/vpi_app.c` are not automatically invalid AMS tests, but cannot receive
standalone IEEE27.19 credit. Do not fix the implementation by erasing the AMS
extension. Likewise, analog extensions add routines/formats/callbacks absent
from this inherited digital chapter.

Source anomalies remain explicit rather than copied into new oracles:

- 27.14 scalar ObjType prose says vpiScalar/vpiStrength, while the format table
  uses Val-suffixed constants; Table27-5 prints vpiObjectVal rather than
  vpiObjTypeVal. AnnexG must resolve ABI spelling.
- 27.14 describes constant type using vpiStringVal; its UDP byte description,
  example decode and two differing outputs for the same displayed input require
  separate resolution before a precise UDP oracle. Its prefix-search example
  actually uses strcmp equality.
- 27.29 save/restart sample has unsafe/uninitialized pointer/count operations;
  it is not a valid executable oracle for chunked data preservation.
- 27.34.2 calls the startup array a C function; use its actual array declaration,
  while preserving source prose in a transcription.

The implementation comment describing vpi_release_handle as IEEE1364-2005's
later spelling is not established by this chapter: Clause27 defines
vpi_free_object, and AnnexG ownership should verify that extra symbol separately.

## New bounded host probes

Files are under `tests/fixtures/ieee_pli/`; each has separate C application,
Verilog design and exact expected application transcript. They are not ordinary
HDL-only digital fixtures. A future host must link one C application, invoke its
startup table in the legal phase, execute callbacks and the HDL, and require
exit zero plus the transcript. No startup-only shim or local replacement header
is used. Suppressed callbacks must fail by missing expected output.

| Probe | Independently derived oracle | Observed current result |
|---|---|---|
|audit_vpi_value_formats|35-bit vector chunks preserve aval/bval and upper101; low1xz0 gives integer8; value string survives get_str; real-2.5 converts to integer-3. Runs in start-of-simulation callback.|C syntax check fails: missing callback types, value constants and get/put/register prototypes. No runtime execution claimed.|
|audit_vpi_event_handles|Free a scheduled-event handle yet observe update; explicit cancellation prevents another update; cancelling a new inertial event must not resurrect its previously cancelled predecessor. Observe at tick5 after last event tick4.|C syntax check fails on missing callbacks, value APIs, delay/event constants. No runtime execution claimed.|
|audit_vpi_invalid_time_callback|After legal start callback, cbAfterDelay with suppress-time or NULL time must return NULL plus error; invalid callback must never run.|C syntax check fails on missing callback structures/constants/prototype. No runtime execution claimed.|

Reproduction (each command exits1 against current production header):

```sh
cc -std=c11 -Wall -Wextra -Werror -Wno-unused-command-line-argument -fsyntax-only -I src/vpi tests/fixtures/ieee_pli/audit_vpi_value_formats.c
cc -std=c11 -Wall -Wextra -Werror -Wno-unused-command-line-argument -fsyntax-only -I src/vpi tests/fixtures/ieee_pli/audit_vpi_event_handles.c
cc -std=c11 -Wall -Wextra -Werror -Wno-unused-command-line-argument -fsyntax-only -I src/vpi tests/fixtures/ieee_pli/audit_vpi_invalid_time_callback.c
```

These failures expose missing positive API capability; they are not expected
conforming rejection tests, successful negative coverage, or working XFAIL
integration. Source-derived probes remain reviewable but need complete-header
compilation and a real simulation host before they can become runtime evidence.
No compiler/header edits, full builds, measured percentages or closure claims.

## Root review and pending integration

Main read the complete report and all three C clients on 2026-09-23 and
independently reread section27.32's delay, cancellation and returned-handle
rules. The complete chapter traversal remains worker evidence. Host fixtures
are not yet integrated or executed. One probe needs strengthening before
integration: its replacement inertial event assigns the current value zero,
but the source permits a null handle when no event is scheduled. Use a
two-bit object and replacement value two, distinct from both current zero
and predecessor one, before requiring a returned event handle. Cancellation
must still leave zero; this isolates non-resurrection without relying on an
equal-value scheduling assumption. Public-header provenance and compatible
type repairs have since landed; missing runtime APIs remain open.

Root host-probe integration is now complete. The event probe uses a two-bit
object with replacement two as described above; no runtime expectation was
changed to match current implementation behavior. All eight inherited host
clients are visible to `zig build test-vpi-fixtures` as compile-only positives.
The root run exits one and adds exactly their eight failure names to the
pre-integration list, with every existing failure preserved. Logs:
`/tmp/vera-ieee-pli-{before,after}.log`. Missing callback/value declarations
still prevent compilation; no linked simulation or host coverage is claimed.
