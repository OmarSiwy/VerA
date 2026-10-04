# Seam notes: s1-device (the emitted device text)

Step-1 agent for what VerA *emits*, the Zig device a host links: `Instance`,
`State`, `Model`/`Setup`, the entry points, the state machine and the spliced
kernels. Files: `lib/backend/codegen.zig`, `lib/backend/codegen/**`,
`lib/backend/cg_{display,filters,limit}.zig`, `lib/backend/kernels.zig` and
`lib/backend/kernels/*` (moved from `lib/backend/*_kernels.zig`). Base
`0d89c842`, merged with `zig-0.17` at `e7e7895b`. Unlike every other step-1
unit, the goldens move here. Each class of change is listed below with the
fixtures it touches.

## Spine and ownership (emitted device)

Host call order (`contract.validate`'s doc): `derive` → `setup` (fills
`Model.su`) → `setupInstance` → `initState` → per Newton iterate `eval`/`q`/
`evalQ` (read `Model`, `Model.su`, `Instance`; write nothing) → `limit` →
per accepted point `updateState`/`acceptQ` (writes `Instance` history and
held values, and `State` staging) → `stateCtl(.commit|.revert)`.

| Table (emitted) | Written by | Read by | Per | Hot? |
|---|---|---|---|---|
| `Model` card fields | host | `derive`, `setup`, a few in `eval` | card | cold |
| `Model.su` (`Setup.r/i/b`) | `setup` | every `eval` | card | hot, shared by all instances of a row |
| `Instance` | host (`mfactor`), `updateState`, `stateCtl` | `eval` every iterate | instance | **hot** |
| `State` | `updateState` (staging), `stateCtl` | `stateCtl` only | instance | cold |

After this pass, `State` holds everything per-instance that `eval` never
reads, so `Instance` is eval's hot set.

## Classes of emitted-text change (goldens before → after)

All are measured against `0d89c842`'s goldens (3228 fixtures). Final:
1396 fixtures differ, all in the classes below; nothing unexplained.

1. **Staged path latches move to `State`** (`e5eca689`). `wb__k`/`wq__k`
   (written by `updateState`/`acceptQ`, read by `stateCtl(.commit)`) leave
   `Instance`; `eval` reads only `pb__k`/`pq__k`. `updateState`/`acceptQ`
   name their `state` parameter. Fixtures: `ch05_analog_behavior/batch_per_instance_state.va`
   (the only one with path latches); ARPice mos1 and bsim4va.
2. **No `State` twins for §9.17 fields no operator moves** (`85db1d73`,
   `e176e3ab`). `updateState` resets `bound_step`/`discontinuity_order` every
   accepted point; only `absdelay`, `zi`, `$bound_step`, `$discontinuity`
   move them. Without one, the two `State` twins and their four `stateCtl`
   copies were dead. 209 fixtures lose those lines. A
   device whose `State` would then be empty (the 7 §9.7.3 status devices)
   keeps them: an empty `State` is comptime-known, and `tests/status_host.zig`'s
   `.{ inst, st }` broke on it, so the first commit was fixed by the second.
3. **Doc comments on the host-facing declarations** (`5d8c4881`):
   `num_ports`, `u_kinds`, `initState`, `updateState`, `state_class`,
   `stateCtl`, `batch_ok`/`batch_lead`/`batch_inst`, `Model.su`/`su_ok`,
   `Setup.r/i/b`, and a sentence each on `Instance`/`State` saying which is
   eval's hot half. Doc lines only, in every device (1396 fixtures). Costs
   +375 B in the smallest device, which moved the `tests/bench.zig` size
   goldens (`85ebe292`, re-measured, with the coordinator's approval).
4. **Kernel tests out of device text; kernel files under `lib/backend/kernels/`**
   (`1713e63e`). `filter_kernels.zig`'s 7 tests and `limit_kernels.zig`'s
   differential test plus its 4 test-only ngspice oracles moved to
   `kernels/test.zig`, which `kernels.zig`'s `test` block pulls in. The kernel
   banners carry the new path, and the stale `src/filter_kernels.zig` banner is
   fixed by the same move. 158 fixtures: 25 filter and 12 limit devices lose
   the blocks; the str (74), rng (28) and table (21) banners change.
5. **Kernel doc slips** (`c2b99a24`): `ztDuplicateError`'s doc moved off
   `ztMissingSource`; `ZSs` and `zSsForm` each have their own doc; `zMonitor`
   cites `src/sim/digital/display.zig`; rng's header no longer says "the tests
   below"; docs on `zRng*Next`, `zRngRandNext`, `zScanR`, `zScanS`. 147
   fixtures, comment lines only.
6. **`$table_model` row permutation `u32`** (`c8703e67`): `order: []usize` →
   `[]u32` (with a compile error past 2^32 samples). The 21 table devices.

## Device speed and memory (gate 4)

Harness: `docs/measurements/batched-lead-2026-10-02/batch_host.zig` and
`device-runtime-2026-10-01/dyn_rt.zig`, ported to Zig 0.17 in the scratchpad
(`**` → `@splat`, `.Debug` → `.debug`, `@typeInfo(..).fields` →
`field_names/field_types`, the unused set/signature exports dropped), plus a
`bench_sizes` export. Ir is callgrind's per-instance marginal (Ir at 1024
minus Ir at 512 instances, divided by 512), driven by a C dlopen driver.
`W=1` is `bench_scalar` and `W=4` is `bench_coherent` (one run per batch)
and `bench_batch` (mixed points), built `-mcpu=x86_64_v2` unstripped. `native`
is the `--emit-so` dyn_rt build: evalQ and the transient step (3 evalQ +
updateState + stateCtl). Both trees are built against the same
`tools/contract.zig`. Outputs are bit-identical before and after on all four
models (the FNV hashes of every evalQ and transient output: `bench_hash`,
`bench_hash_tran`), and the batch checks report 0 mismatches.

| model | Ir W=1 | Ir W=4 coherent | Ir W=4 mixed | native evalQ | native tran step |
|---|---|---|---|---|---|
| diode | 198.0 → 198.0 | 147.8 → 147.8 | 149.0 → 149.0 | 181.0 → 181.0 | 932.8 → 932.8 |
| mos1 | 729.1 → 729.1 | 599.0 → 599.0 | 1996.2 → 1996.2 | 592.9 → 595.1 (+0.4%) | 1770.0 → 1756.5 (−0.8%) |
| bsim4va | 8408.9 → 8408.9 | 6430.8 → 6439.8 (+0.1%) | 18849.0 → 18859.3 (+0.05%) | 6071.8 → 6071.8 | 21205.7 → 21199.7 |
| psp103 | 9824.8 → 9824.8 | 7832.1 → 7832.1 | 16135.1 → 16135.1 | 6637.2 → 6637.2 | 20934.4 → 20930.4 |

No device is more than 1% slower on any column. Struct sizes, emitted text
(`device.zig` + `u/*.zig` + `h.zig`) and stripped native `.so`:

| model | `Instance` | `State` | Instance+State | `Model` | `Setup` | text | `.so` |
|---|---|---|---|---|---|---|---|
| diode | 32 → 32 | none | 32 → 32 | 480 | 216 | 115081 → 108380 | 44184 → 44184 |
| mos1 | 368 → **224** | 64 → 192 | 432 → 416 | 720 | 368 | 160100 → 154472 | 58016 → 57648 |
| bsim4va | 200 → **120** | 24 → 88 | 224 → 208 | 10728 | 3312 | 879965 → 881904 | 293336 → 293768 |
| psp103 | 104 → 104 | 88 → 72 | 192 → 176 | 10584 | 3760 | 1446060 → 1447761 | 463928 → 463768 |

What `eval` touches per instance (`Instance`) drops from 6 to 4 cache lines
on mos1 and from 4 to 2 on bsim4va. Callgrind counts instructions, not
misses, so the gain is a cache-footprint gain that Ir cannot show. It matters
when a host's instance count overflows L1/L2.

### The compiler itself

ReleaseFast `vera --emit-zig`: the merged base `e7e7895b` against HEAD, both
built from `git archive`, interleaved run by run on a loaded machine. Twenty
runs each over four passes. Time min (median) / peak RSS min (median):

| model | base | head |
|---|---|---|
| psp103 | 0.12 s (0.155), 26.9 MB (27.8) | 0.13 s (0.15), 25.8 MB (27.9) |
| bsim4va | 0.09 s (0.11), 20.4 MB (21.1) | 0.09 s (0.125), 20.5 MB (21.3) |
| hisimhv_va | 0.22 s (0.27), 43.0 MB (43.6) | 0.22 s (0.295), 42.4 MB (44.0) |

Flat within noise: median RSS moves by at most 1%, inside the 2% rule. One pattern
looked like a +0.8 MB RSS regression: the binary in the *second* slot of each
round read about 0.8 MB high, whichever binary it was. Running `base, c3,
head` and then `head, base` showed it moving with the slot.

## Memory

Emitted types (what a host allocates), plus the kernel types now owned here.
"count" is per host instance unless stated. The compiler-side codegen tables
were audited by s1-codegen (`docs/seams/s1-codegen.md`, Memory) and are
unchanged here.

| type | size before → after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `Instance` (mos1 / bsim4va / psp103) | 368/200/104 → 224/120/104 | 1 per instance | 144/80/0 per instance off eval's hot set | staged latches → `State` |
| `State` | 64/24/88 → 192/88/72 | 1 per instance | psp103 −16; mos1/bsim4va +128/+64 (moved, not new) | dead §9.17 twins gone; staging moved in |
| `Setup` (`Model.su`) | 3760 (psp103) | 1 per Model row | 0 | Every `r` slot is read by the core (454/454 on psp103), so there is no cold half to split. `b: [127]bool` as a bitset would save 111 B per row and add a bit-extract per read. It is per row, not per instance. Left. |
| `Model` card | 10584 (psp103) | 1 per row | 0 | Host-written by field name (`contract.host_model_fields`, `bench_param`). Integer parameters are `i64` where §3.2 says 32 bits: a seam proposal. The core reads 1 card field on psp103 and 16 on bsim4va directly; copying those into `Setup` would make eval's Model reads contiguous. Per row, so it stays warm across instances: step 3. |
| `zSetupZ` (setup's slots) | 12.6 KB + (psp103) | 1 per `setup` call, stack | 0 | setup-time only |
| core `h<k>` hoist arrays | locals | per eval, registers/stack | 0 | Liveness-coloured slots were measured and lost 33% (AGENTS §5); not redone. |
| `ZFSlot` (kernel) | 4152 (pinned ≤ 4160) | 30 per printing device image | 0 | Sharing one 4 KB line window was asked for only if provably identical. It is not: `zFLine` is a pure reader emitted where its destination is used, and `zFRes` latches a count in the display unit for the eval core, so another descriptor's `zFGets` can run between a read and its use. The digital engine uses the same kernel. Declined; see proposal 4. |
| `ZFWritten` | 24 | 64 rows | 0 | small |
| `$table_model` `order` scratch | 8·NP → 4·NP | per lookup, stack | 4·NP | `usize` → `u32` |
| `ZSs` (filter) | 16 | 1 per call, by value | 0 | two `usize` that fit `u8`; returned in registers, nothing stored |
| `ZScan`/`ZCDec`/`ZCOut`/`zTabVD` | 48/816/24/16 | stack per call | 0 | already minimal for what they carry |
| `zSBuf(site)` | 4096 per site | 0 on psp103 | 0 | the E1011 limit (`Vague_Decisions.md`) |
| limit oracles + test, filter tests | text | 12 / 25 devices | ~10.6 KB of text per such device | out of device text |

## Seam proposals

1. **Stale kernel paths in documents I don't own.** After the move,
   `docs/CLAUSE-AUDIT.md`, `docs/Vague_Decisions.md` and `docs/UNITS.md`
   (regenerate with `zig build archmap`) cite `lib/backend/<x>_kernels.zig`. So do
   two fixture comments
   (`ch09_system_tasks/171_random_ieee1364_digits.va`,
   `s01_13_long_record_is_not_truncated.va`) and
   `ieee1364/17_system_tasks/d09_08_readmemh.v`. The files are now
   `lib/backend/kernels/<x>_kernels.zig`, with the same names. Their `:line`
   citations have drifted too.
2. **Model integer parameters as `i32`.** VerA emits every `integer`
   parameter as `i64`, and §3.2 says 32 bits. Hosts write them by name
   (`bench_param` uses `lossyCast` to the field type), so narrowing changes
   what a host's assignment compiles against. That makes it an ABI decision
   for `tools/contract.zig` (`host_model_fields`), not a step-1 one.
3. **Batched instances as SoA.** `zInst` gathers each per-instance field from
   W `instLane(T, w)` pointers: W pointer chases per field, +28 Ir per
   instance on mos1 (`batched-lead-2026-10-02.md` §1b). A host-owned SoA
   instance block (one `[W]f64` per field) would turn that into one vector
   load. This changes `contract.instLane`, the frozen batch ABI, so it is
   step 3.
4. **One shared `$fgets` line window** (s1-kernels' proposal 3) needs an
   emission rule first: copy the line at the `zFLine` site, or emit every
   reader right after its `zFGets`. Only then can 30 × 4 KB of `.bss` become
   4 KB.
5. **The 2026-10 measurement harnesses do not build under Zig 0.17**
   (`docs/measurements/device-runtime-2026-10-01/dyn_rt.zig`,
   `batched-lead-2026-10-02/batch_host.zig`): `** n` array repetition,
   `.Debug`, `std.meta.fields`, `StaticBitSet.initEmpty`. The ports used here
   are in this session's scratchpad. Whoever owns `docs/measurements` should
   land them.

## Step-3 opportunities seen (not done: SIMD, branchless and numerics are step 3)

- Dual arithmetic inlined from `tools/contract.zig` is about 70% of psp103's
  and bsim4va's evalQ Ir. armPow/armExp/armLog together are about 20%.
  Constant-argument math (`S.con(c).pow(k)`) already constant-folds (0 Ir in
  callgrind's line view).
- psp103's 9 held values are loaded at the top of the core and, on the ARPice
  card, overwritten on every path before use (batched-lead §1b).
- `updateState` stores `bound_step = inf` / `discontinuity_order = -1` on
  every accepted point even when nothing else writes them. That is a contract
  statement ("written by `updateState`"), so it stays.

## Bugs found

None in behaviour. The one regression this pass introduced (an empty `State`
breaking `tests/status_host.zig`) was caught by `zig build test` and fixed in
`e176e3ab`.

## Gates

- Fixture suite (the suite binary run directly, §0 rule 3): 2189/2189 before
  and after. FAIL/XFAIL name lists are both empty, and the tally line confirms
  the empty list is real (`pass 2189 fail 0 xfail 0`), not a broken capture.
- `zig build`, `test`, `test-backend`, `test-spice`, `test-devices`,
  `test-vpi-fixtures`, `test-kernels`: all exit 0 at the final commit (each
  run alone, `$?` checked).
