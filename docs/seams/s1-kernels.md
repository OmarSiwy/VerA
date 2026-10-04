# s1-kernels: runtime kernels and the device contract (U02-U07, U19, U21, U34)

Step-1 notes for `lib/backend/kernels.zig`, the seven `lib/backend/*_kernels.zig`
files and `tools/contract.zig`, written 2026-10-03 against base `64357568`.

## The constraint that shapes this unit

The kernel files are not ordinary modules. `lib/backend/codegen/kernel_text.zig`
(codegen's) `@embedFile`s each one and splices its bytes into every device that
uses it: str in 74 of the 3228 goldens, rng 28, filter 25, table 21, limit 12,
the timer body 29 (measured on the base snapshot). So **any byte of
`str/rng/filter/table/limit_kernels.zig` is golden text**, comments and tests
included, and so is `timer_kernels.zig` after its first blank line
(`kernel_text.timer_txt` drops the `//!` header up to the first `"\n\n"`).
`file_kernels.zig` reaches only `--display=emit` testbench devices, which no
golden captures, so its bytes move no golden, but its code runs in every
file-I/O fixture. The `../*_kernels.zig` embed paths are also codegen's, so the
files cannot move into `lib/backend/kernels/` without editing `kernel_text.zig`.

Step 1 therefore leaves every kernel file byte-identical. Doc and layout
findings in them are recorded below for a step that is allowed to move goldens.

`tools/contract.zig` is installed alone as `share/vera/contract.zig` and is the
file a host passes to `vera --contract`, so it cannot be split into siblings
either (a sibling import would not be installed).

## Spine and ownership after step 1

There is no runtime spine in this unit: each kernel is a leaf a device calls,
and the contract's spine is the host's call order, written out in `validate`'s
doc comment (derive, checkShape, setup, setupInstance, collapse, initState,
seed, eval/q/evalQ, limit, iteration hooks, updateState, stateCtl, display,
noisePsd/acStim/acDyn, breakpoints).

| Table | Owner (file) | Written by | Read by | Capacity | Lifetime |
|---|---|---|---|---|---|
| `zf_slots` | file_kernels.zig | `zFOpen`, `zFGets`, `zFWindow`, `zFTake`, `zFSeek`, `zFUngetc`, `zFClose` | the same, `zFLine`, `contract.FileIo` users (mixed digital half, `sim/digital/system.zig` `own`) | 30 channels (§9.5.1 mcd) | device image (file scope) |
| `zf_written` | file_kernels.zig | `zfWriteBase` (via `zFOpen` "w") | `zfWriteBase` | 64 paths | device image |
| `zSBuf(site)` rows | str_kernels.zig | `$sformat`/`$swrite`/`zStrCat`/`zStrRepeat` at that site | the string slot it returns | 4096 B per site | device image |
| `zMonitorLatch(site)` | str_kernels.zig | `zMonitor`, `zMonitorArm` | `zMonitor` | 64 values per site | device image |
| `zFRes(site)` | file_kernels.zig | display unit | eval core | one i64 per site | device image |
| filter `__u`/`__y` histories, timer `__next/__start/__per`, rng seeds | codegen (`Instance` fields) | the kernel each is passed to | the same | per call site | instance |
| `gm` tables (`exp_tab`, `pow_log_tab`, `log_*`) | contract.zig | comptime | `gm.exp/log/pow` | 256 u64, 128x3, 4x128 f64 | static |
| `SimState` | the host | the host | every entry point | one per call, by value | call |

The kernels read and write only the slots they are passed; the
`Instance`/`Model` fields holding filter, timer and rng state are emitted by
codegen, now s1-device's.

## What changed

- `lib/backend/kernels.zig`: the header now carries the ownership map above and
  the rules a kernel file obeys (compiles alone, `//` not `//!`, private `std`
  alias, its bytes are device text). Fixed a misattached doc comment: the
  `str_kernels` summary sat on `abi_version`. Each alias says which non-device
  caller uses it.
- `tools/contract.zig`:
  - deleted 12 dead `gm` constants (`P1`-`P5`, `Lg1`-`Lg7`, never read) and
    their stale "musl exp.c / log.c ports" heading;
  - moved `armExp`'s doc line off `expSmall`, where it had been merged into
    another comment;
  - inlined the single-use `powLog` wrapper into `armPow`;
  - inlined the single-use `validateSimState` and `validateMcParam` into
    `validate` as commented blocks;
  - documented `gm.log/pow/tanh/sinh/cosh/sin/cos/expm1/atan` (what differs
    between host and GPU), the `gm` consumers (constant folds and the prover
    fold `exp/log/pow` to device bits), `RefDense`/`RefSparse`'s layouts, and
    the file's section map and its single-file rule;
  - pinned size budgets: `UpdateResult <= 16`, `PsdTerm <= 48`,
    `AcPhasor == 16` (`SimState == 24` was already pinned).

Machine code: a ReleaseFast object exporting every `gm` path (scalar and
`@Vector(4, f64)` exp/log/pow, the GPU-port wrappers), both `RefFamily`
layouts, `LeadState` and `noiseTableAt` emits the same instruction stream
before and after (`diff` of the assembly identical after renumbering
`__anon_N` symbols). No executed code changed, so device runtime speed cannot
have moved.

## Memory

Sizes on x86_64 from a throwaway `zig test` over copies of the files. "psp103"
counts what the generated psp103 device holds or produces (it embeds no kernel
file: no file I/O, rng, table, filter, timer or `$limit`).

| type | size before -> after | count on psp103 | bytes saved | what changed or why not |
|---|---|---|---|---|
| `contract.SimState` | 24 -> 24 (extern, pinned) | 1 per call, by value | 0 | ABI, frozen; already asserted |
| `contract.UpdateResult` | 16 -> 16 | 1 per instance per accepted point | 0 | ABI; budget pinned |
| `contract.PsdTerm` | 48 -> 48 | 16 per `noisePsd` call (768 B) | 0 | ABI; `corr_with: ?u8` pads 2 B to 8. Narrowing `white/flicker/ef/corr/coeff` would change what hosts read. Budget pinned |
| `contract.AcPhasor` | 16 -> 16 | 0 | 0 | ABI; pinned |
| `contract.FileIo` | 80 -> 80 | 0 (one comptime value per printing device) | 0 | ABI fn-pointer table |
| `contract.NoiseGen(D)` | 32 -> 32 | 16 (comptime) | 0 | comptime table, pub shape. `name` slice is 16 of the 32 |
| `contract.NoiseTable` | 24 | 0 | 0 | comptime |
| `contract.AcGen(D)` | 24 | 0 | 0 | comptime |
| `contract.QStamp(U)` | 16 | 17 (comptime) | 0 | comptime; `sign: f64` is +-1 in every VerA device but the type admits any finite factor |
| `contract.JacConst(U)` | 56 | 0 | 0 | comptime; `?JacWhen` (24 + tag) is most of it |
| `contract.LaneUse` | 16 | 21 (comptime) | 0 | comptime |
| `contract.StatusSite`, `Systf`, `SystfHost`, `Constant`, `JacWhen`, `LimitResult(2)` | 40, 16, 16, 2, 24, 24 | 0 | 0 | comptime or ABI |
| `contract.LeadState(4, sig)` | 96 (align 32) / 3 without `sig` | 1 per batched call (stack) | 0 | the two `@Vector(W, u64)` hashes are the region signature; already minimal |
| `RefFamily` values | dense f64 2-lane 24, f32 16; sparse `Of(3)` 24 | SSA values in eval | 0 | register types, never stored in a table |
| `gm` dead constants | 12 x f64 comptime | 0 | 0 at run time | deleted (comptime-only, never emitted) |
| `file_kernels.ZFSlot` | 4152 (align 8) | 0 | 0 | 30 slots = 124,560 B per printing device image. The 4096-byte `line` is 98.7% of it; packing the five bools and `err` saves under 1%. See proposal 3 |
| `file_kernels.ZFWritten` | 24 | 0 | 0 | 64 rows, 1.5 KB; a hash/base pair per remembered path |
| `str_kernels.ZScan` | 48 | 0 | 0 | returned by value per scan call; golden text |
| `str_kernels.ZCDec` | 816 | 0 | 0 | stack scratch for exact decimal formatting (800 digits); golden text |
| `str_kernels.ZCOut` | 24 | 0 | 0 | stack; golden text |
| `zSBuf(site)` | 4096 per site | 0 | 0 | file-scope row per `$sformat` site; size is the E1011 limit (`Vague_Decisions.md`) |
| `zMonitorLatch(site)` | 512 + 10 per site | 0 | 0 | `cnt: usize` holds <= 64; golden text |
| `filter_kernels.ZSs` | 16 | 0 | 0 | two `usize` that fit `u8` (section degree); golden text |
| `table_kernels.zTabVD` / `zTabRes(2)` | 16 / 24 | 0 | 0 | value and gradient; minimal |
| table lookup `order` scratch | `NP x 8` per lookup | 0 | 0 | `[]usize`; `u32` would halve it. Golden text, see proposal 2 |

ReleaseFast `vera --emit-zig`, time and peak RSS, best of 10. Base
(`64357568`, built from `git archive`) and after ran interleaved, run by run,
on the same machine (load average about 20 from other agents):

| model | base | after |
|---|---|---|
| psp103 | 0.136 s, 30.8 MB | 0.133 s, 30.4 MB |
| bsim4va | 0.095 s, 21.8 MB | 0.093 s, 22.1 MB |
| hisimhv_va | 0.225 s, 46.6 MB | 0.230 s, 46.8 MB |

Flat within noise: the same base binary's psp103 minimum RSS read 27.5 MB in
one 7-run pass and 30.8 MB in the next. That is expected, because nothing on
the compile path changed (the `gm` code `constfold` calls is
instruction-identical).

## Seam proposals

1. **Kernel test blocks and headers ship inside devices.** `kernel_text.zig`
   splices the whole file, so `filter_kernels.zig`'s 7 tests (6,131 bytes) and
   `limit_kernels.zig`'s oracle test (4,473 bytes) are in the text of 37
   goldens and every device that uses a filter or `$limit`, and every
   kernel's prose header is too. Better: move the tests to
   `lib/backend/kernels/test.zig` (it reaches the kernels through `kernels.zig`
   as codegen's tests already do), and move the seven files to
   `lib/backend/kernels/` in the same change, with `kernel_text.zig`'s
   `@embedFile` paths updated. Callers: `kernel_text.zig` (7 paths), the doc
   paths in `Vague_Decisions.md`/`CLAUSE-AUDIT.md`. This moves goldens by
   deleting bytes, so it is a separate golden-moving commit owned jointly with
   codegen (s1-device).
2. **`$table_model` permutation as `usize`.** `zTabEnd/zTabLess/zTabSort/zTabAt`
   take `order: []usize`; `NP` is a comptime sample count that fits `u32`
   (`u16` for any table a model ships). `[]u32` halves the stack scratch and
   the sort's traffic. Golden text, so it rides with proposal 1. The
   `zTabSort` ponytail (sorting per lookup) is a step-3 performance item.
3. **The descriptor table's line buffers.** 30 x 4096 B of file-scope `line`
   is 120 KB of `.bss` (`.data` in Debug, where `undefined` is 0xaa) in every
   printing device that calls §9.5. A latch is read only by the readers of
   the call that filled it, so one shared 4 KB window keyed by descriptor
   would do, if no emitted unit interleaves two descriptors' `zFGets` and
   `zFLine`. That needs a check of `cg_display.zig`'s ordering first, and it
   changes behaviour if the check fails, so it is not a step-1 change.
4. **`gm` is a separate data domain inside the ABI file.** About 1,350 of the
   contract's 4,476 lines are the transcendental ports and their tables, which
   change for accuracy reasons on a different cadence from the ABI. Splitting
   them into `contract/gm.zig` needs `build.zig` to install a directory and
   `--contract` (`src/main.zig`, the emitted `build.zig` of `--emit-exe/-so`) to
   accept a module directory. Worth it only if the ABI file is reviewed
   separately from the math; otherwise leave it whole.

## Bugs found

Doc slips only; none changes behaviour. The first two are in golden text.

- `lib/backend/table_kernels.zig:43-52`: two doc comments merged. The §9.21
  duplicate-point paragraph ("If there are two or more data points ...") sits
  on `ztMissingSource`; it belongs to `ztDuplicateError` (line 57), which has
  no doc. Trigger: read the file. Expected: one doc per function.
- `lib/backend/filter_kernels.zig:189-191`: the paragraph above `ZSs`
  describes what `zSsForm` computes; `zSsForm` itself has no doc.
- `lib/backend/str_kernels.zig:681`: `zMonitor`'s doc cites
  `src/sim/digital.zig`, which is now `src/sim/digital/root.zig`.
- `lib/backend/codegen/kernel_text.zig:675` (codegen's): the filter block's
  device-text banner says `(src/filter_kernels.zig)`; the file is
  `lib/backend/filter_kernels.zig`. In 25 goldens.
- Fixed here: `lib/backend/kernels.zig:9` carried `str_kernels`' doc on
  `abi_version`; `tools/contract.zig` carried `armExp`'s doc on `expSmall`.

## Not done

- No kernel file was edited (see the constraint above). Their doc comments are
  already dense and clause-cited; the gaps found are listed under Bugs found.
- No comptime size assert went into a kernel file, for the same reason.
- The `RefDense`/`RefSparse` method bodies repeat the same eleven
  transcendental rules; Zig cannot generate the method decls from a table, so
  folding them saves a few lines at the cost of an indirection on the hottest
  path in a reference family. Left.
