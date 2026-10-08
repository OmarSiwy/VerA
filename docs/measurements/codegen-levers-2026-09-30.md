# Source-to-native build levers for generated devices

Measured 2026-09-30 at VerA `64d275e9` (main), Zig 0.16.0, LLVM backend,
ReleaseFast, Intel i9-14900HX. This is a measurement study: no compiler change
is landed. It follows [BUILD-SPEED.md](../BUILD-SPEED.md) (2026-09-29, not yet
committed on main) and asks which levers shrink the Zig sema + LLVM time spent
on VerA's *generated* code, at what cost to the compiled device's runtime and
numerics.

Measures A/B/C/D: none moved. No fixture, compiler or golden changed.

## Result in one table

Build cost is **retired user-space instructions of the whole `zig` process
tree (Gi = 10^9)**, median of 2-4 fresh-cache builds; it is load-invariant
(repeat builds agree to 0.1%). Wall seconds are the least-disturbed sample and
are only indicative (see *Noise*). Runtime is instructions and cycles per
`evalQ` call over a 64-point bias sweep; "bit-exact" means the FNV hash of every
residual, charge and Jacobian entry at all 64 points (setup results included,
since they feed `evalQ`) is identical to the baseline device.

| Rank | Lever | psp103 build | bsim4va build | Small models | Runtime delta | Bit-exact | Cost |
|---|---|---:|---:|---|---|---|---|
| 1 | `-fstrip` the `--emit-so` device (lever 1) | 132.6 → 68.2 Gi (−49%); 12.0 → 6.2 s | 72.7 → 37.4 Gi (−49%); 6.5 → 3.5 s | coupled_ltra −76% (14.5 → 4.6 s), txl −25%, mos1 −8%, diode −5%, v_* −13% | 0 (identical `.text` bytes for every analog model but coupled_ltra, +80 B; all bit-exact) | yes | trivial: one argv flag + an opt-in to keep DWARF |
| 2 | Group hoisted slots by mask: `[k]zOf(S,m)` arrays instead of one `@Tuple` field per slot (lever 5) | 132.6 → 110.9 Gi (−16%); sema 2.80 → 1.42 s | 72.7 → 63.9 Gi (−12%); sema 1.47 → 0.95 s | txl −4%, others ≈0 | 0 (psp103 `.text` byte-identical; bsim4va same size, identical instructions/eval) | yes | low-medium: slot allocation in `codegen/plan`, device text changes (minor version) |
| 3 | Split the device into setup / state / eval objects built by parallel `zig build-obj`, then link (levers 3+1) | wall 6.2 → 3.3-3.4 s (stripped); CPU +12 Gi | wall 3.5 → 2.0 s | coupled_ltra 4.6 → 2.5 s; mos1 no gain; resistor 2.9x CPU | 0 (instructions/eval within 0.4%) | yes | medium-high: orchestrator + dyn host contract must export per part; gate on device size |
| 4 | Skip the preflight `build-obj -fno-emit-bin` on `--emit-so` (lever 7) | −0.23 s, −0.8 Gi | −0.11 s | resistor/diode −0.05 s of ~0.25-0.4 s | 0 | yes | trivial; run it only after a failed build to keep `.va`-attributed errors |
| 5 | Prebuild the digital engine once (lever 6) | — | — | v_count 17.0 → 4.9 Gi, v_inv 22.2 → 5.1 Gi (stripped, engine cached; Lever 6) | instructions/point +0.0% (v_count), +0.3% (v_inv) | yes | **landed** for `.v` `--emit-so` (LLVM); not for `.v` executables (Lever 6) |
| 6 | `eval` delegates to `evalQ` (`.res`) in a 3-entry host (lever 2, middle ground) | 172.0 → 141.6 Gi (−18%) | 90.8 → 77.1 Gi (−15%) | mos1 −13% | evalQ unchanged on psp103/bsim4va but **mos1 evalQ +14% cycles**; eval +4% (psp103), +24% (bsim4va) | yes | low, but host-dependent; no gain for the `--emit-so` host |
| 7 | setup/derive object at ReleaseSmall (lever 4) | −33% without strip; **−2.5% once stripped** | ≈0 once stripped | — | evalQ +0.4% instr | yes | small on top of lever 3; not worth it |
| — | `-flto` on the device build (re-enables loop vectorisation) | +6.8% Gi | +6.5% | coupled_ltra +1.6%, txl +5% | evalQ −1 to −4% cycles, −2% instr (psp103) | yes (strict sites unaffected) | trivial flag; gain unproven on the array loops (see below) |
| ✗ | Out-of-line `core` (`.never_inline`) everywhere (lever 2) | +1% (1-entry host); −15% (3-entry host) | +0.6% / −12% | — | **evalQ cycles +4% psp103, +7-9% bsim4va, +36-47% mos1; mos1 eval +150%, q +262%** | yes | rejected, confirms the 2026 mos6 note |
| ✗ | Drop `zTo(S, 0x0, …)` wrappers textually | **+270%** (debug info blow-up: X86 Assembly Printer 3.2 → 25.8 s) | +76% | — | 0 | yes | rejected unless stripped, and then no gain beyond rank 2 |
| — | `S.con(x).val()` → `x`, `@as(i64,@intFromBool(...)) != 0` chain folding | 0% | 0% | — | 0 | yes | not worth doing for build time |
| — | Shared/warm local `.zig-cache` | 0% (std ZIR already comes from the global cache) | 0% | resistor 4.82 Gi either way | — | — | no lever |

**Headline wall-clock** (`head.spec`/`headsplit.spec`, 3 rounds started only
when load average < 60; min wall, Zig build only):

| Source | Today | Strip | Strip + grouped slots | + 3 parallel objects | Total CPU (Gi) today → combined |
|---|---:|---:|---:|---:|---|
| psp103 | 11.99 s | 6.09 s | 5.17 s | **2.90 s** | 132.6 → 60.8 |
| bsim4va | 6.45 s | 3.53 s | 3.07 s | **2.02 s** | 72.7 → 40.2 |
| coupled_ltra | 14.75 s | 4.68 s | 4.93 s | **2.48 s** | 161.8 → 50.9 |
| mos1 | 0.72 s | 0.63 s | 0.62 s | 0.69 s (split loses) | 8.6 → 7.9 (single object) |

Combined devices: bench hash bit-exact, `evalQ` instructions identical
(psp103 7,867, bsim4va 6,506, coupled_ltra 318, mos1 612); cycles −2% to +10%
in a loaded interleaved run (`results/combo_runtime.jsonl`), i.e. within noise
for identical instruction streams.

No lever measured here changed numerics: every bench hash is bit-exact with
its baseline. Two levers must be flagged anyway:

* **ReleaseSmall for a whole `.v` executable** (the native digital path) costs
  +12-28% cycles at runtime for a −7.5% build: do not use it for the hot part.
* The **`zTo` textual removal** is numerically neutral but multiplies debug
  information cost; any emitter "simplification" must be measured with DWARF on.

### Can the generated phase get below VerA's own ~0.2 s?

Not for the large models, and the measurement says why:

* The **floor of any `zig build-lib` of a device is ≈0.21 s wall / 4.7 Gi**:
  that is the stripped resistor (2.7 KB `.text`), all of it fixed Zig
  process/std overhead (552 reachable files, compiler_rt link). A split build
  pays this floor once per object.
* psp103's **eval part alone** (stripped, its own process) is 31 Gi: sema 1.38
  s + LLVM 1.49 s. Its setup part is 40-43 Gi (sema 1.35 s before slot
  grouping, 0.26 s after; LLVM 1.6-1.8 s). With all three levers the critical
  path is ≈ the eval object: **2.90 s measured (min of 3, load < 60), 14.5×
  the 0.2 s target**; bsim4va 2.02 s, coupled_ltra 2.48 s. Getting there would need LLVM -O3 on psp103's `evalQ`
  to be ~10× cheaper, which no flag or emission shape measured here comes
  close to (stripped, there is no single superlinear LLVM pass: greedy RA 1.7 s,
  SROA 1.4 s, ISel 1.2 s, global splitting 1.2 s, inliner 1.1 s of 3.3 s).
* What does reach it: resistor/diode-class models. Their Zig build is
  0.21-0.33 s stripped (mos1 0.65 s), plus a 0.05 s preflight that lever 4
  removes. The remaining way to "0.2 s" for a big model is
  not compiling — the unchanged-rebuild path measured 0.63 s for psp103 on
  2026-09-29 and a content-addressed artifact cache would make it a lookup.

## Method

### Workloads

ARPice `16781d6e` models (same SHA-256 as BUILD-SPEED.md for the first five):
resistor, diode, mos1, bsim4va, psp103, `native/coupled_ltra.va`,
`native/txl.va`; VerA `tests/vdev/v_inv.v`, `v_count.v` (now in `tests/fixtures/ch07_mixed_signal/`). Device trees were
emitted once by `vera --emit-so` (ReleaseFast VerA) and then rebuilt by hand so
each lever touches only the Zig side. Emitted Zig: psp103 1.44 MB (units:
`core` 279 KB, `core__noise` 205 KB, `core__state` 42 KB, `device.zig` 917 KB
of which `setup` is lines 1451-12380), bsim4va 0.85 MB, coupled_ltra 5.8 MB
(`core` and `core__state` 2.7 MB each, 62% whitespace), txl 0.6 MB.

### Hosts

* `dyn_bench.zig` = the BUILD-SPEED `dyn_speed.zig` host (setup, `evalQ` with a
  sparse f64 `RefFamily`, init/update/control/breakpoint) plus a bench loop that
  calls the exported `device_eval` through `@call(.never_inline)` and a hash
  over all outputs. This is the `--emit-so` shape: **the model body reaches LLVM
  once per entry family** — `setup(V)` ×1, `core` ×1 (always-inlined into
  `evalQ(S)`), `core__state(V)` ×1 (`updateState`), `core__noise` ×0.
* `dyn_arp.zig` adds `eval(S)` and `q(V)` (value family): `core` ×3, the
  multi-entry shape of a simulator host. ARPice's own `src/device/eval.zig`
  goes further: `evalQ` is `@call(.always_inline)`d into `evalRange` per
  (narrow × skip_const) sink instantiation (up to 4 copies), plus `q(Real)`,
  `eval(Real)` for idt devices, `core__state`, `core__noise`, `setup` and the
  GPU path — ≈5-7 copies of a model body per device in that build.

### Measures

* `zt.py` drives `zig build-lib --listen=- --time-report` over the compiler
  protocol and decodes the time report (phase wall times, per-declaration sema
  time, LLVM pass table). Note the decl record is `name\0, file u32, count u32,
  sema u64, codegen u64, link u64` (32 bytes after the name), not the 28 bytes
  `std/Build/abi.zig`'s comment implies.
* Build wall/Gi cover the `zig build-lib` (or split `build-obj`s + link) of an
  already-emitted tree: they exclude VerA's own emission (≈0.2 s for the large
  models, BUILD-SPEED.md) and the preflight (lever 7, measured separately).
* `pc.py` counts retired user instructions over the process tree with
  `perf_event_open` (inherit, both hybrid PMUs `cpu_core` + `cpu_atom`); no
  `perf` binary is installed.
* Runtime: `rb.py` loads a `.so` with ctypes, calls `bench_setup`, hashes the
  outputs at 64 bias points, then times `bench_loop(n)` pinned to P-core 4
  (`taskset`); cycles and instructions per call come from per-thread counters.
  `rbcmp.py` interleaves variants over rounds; the first `.so` of a group is the
  baseline.

### Noise

Other agents kept the 32-thread machine at load average 25-146 throughout.
Wall time of the *same* build varied 2-3x (psp103 base: 11.96-31.2 s), and
CPU-seconds inflated with it (SMT/cache contention), while the instruction count
of the same build repeated within 0.1% (psp103: 132.61, 132.49, 132.55,
132.56 Gi). Rankings therefore use instructions; walls quoted are the minimum
over all samples of a variant. Runtime cycles drifted up to ±30% between groups
under load (the same `evalQ` code measured 4036 and 4829 cycles in two
groups), so a runtime claim here rests on instructions/eval, identical `.text`
bytes where they are identical, and cycles only *within* one interleaved group.

## Baseline (dyn host, ReleaseFast, DWARF on)

| Source | Gi | Wall | Zig sema | LLVM | `.text` | evalQ instr | evalQ cycles |
|---|---:|---:|---:|---:|---:|---:|---:|
| resistor | 4.82 | 0.23 | 0.05 | 0.06 | 2,697 | — | — |
| diode | 5.99 | 0.37 | 0.10 | 0.16 | 9,225 | 220 | 77 |
| mos1 | 8.60 | 0.71 | 0.24 | 0.36 | 16,985 | 612 | 196 |
| bsim4va | 72.65 | 6.54 | 1.47 | 4.93 | 150,873 | 6,506 | 2,660 |
| psp103 | 132.58 | 11.95 | 2.81 | 8.93 | 294,041 | 7,867 | 4,036 |
| coupled_ltra | 161.81 | 14.47 | 0.61 | 13.64 | 174,045 | 318 | 101 |
| txl | 17.93 | 1.77 | 0.26 | 1.38 | 66,077 | 177 | 47 |
| v_inv | 27.80 | 3.68 | 0.25 | 3.31 | 132,505 | — | — |
| v_count | 21.93 | 2.93 | 0.25 | 2.56 | 102,185 | — | — |

(`coupled_ltra`/`txl` do their work in `updateState`, which this bench does not
time; their `evalQ` numbers are only a numerics and code-identity check.)

The psp103 time report: sema per declaration `setup` 1.35 s + `evalQ` 1.18 s
of 2.8 s; LLVM 9.0 s of which X86 Assembly Printer 3.2 s and Live DEBUG_VALUE
analysis 1.7 s are debug-info work.

## Lever 1 — debug information

Zig 0.16 has `-fstrip` / `-fno-strip` and no line-tables-only mode (no `-g1`,
no `-mllvm` passthrough), so the choice is all or nothing.

| Source | Gi default → strip | Wall | LLVM | `.text` |
|---|---|---|---|---|
| resistor | 4.82 → 4.73 (−2%) | 0.23 → 0.21 | 0.06 → 0.05 | identical |
| diode | 5.99 → 5.71 (−5%) | 0.37 → 0.33 | 0.16 → 0.13 | identical |
| mos1 | 8.60 → 7.91 (−8%) | 0.71 → 0.65 | 0.36 → 0.29 | identical |
| bsim4va | 72.65 → 37.38 (−49%) | 6.54 → 3.52 | 4.93 → 2.00 | identical |
| psp103 | 132.58 → 68.16 (−49%) | 11.95 → 6.18 | 8.93 → 3.27 | identical |
| coupled_ltra | 161.81 → 38.82 (−76%) | 14.47 → 4.57 | 13.64 → 3.83 | +80 B, hash differs |
| txl | 17.93 → 13.49 (−25%) | 1.77 → 1.23 | 1.38 → 0.85 | identical |
| v_inv | 27.80 → 24.26 (−13%) | 3.68 → 3.13 | 3.31 → 2.80 | +32 B |
| v_count | 21.93 → 19.17 (−13%) | 2.93 → 2.58 | 2.56 → 2.16 | +32 B |

Every analog bench hash is bit-exact and instructions/eval are identical; for
all analog models except coupled_ltra the `.text` bytes are identical
(`texthash.py`). coupled_ltra's debug cost is extreme (Assembly Printer 18.7 s
of 39.6 s LLVM in a loaded sample). The native `.v` executable path already
passes `-fstrip`. What is lost: symbolized stack traces and source-level
profiling of the device. A `--debug-info` (or `-fno-strip`) opt-in keeps that
available.

## Lever 2 — how many times the model body reaches LLVM

`core` is `@call(.always_inline)`d into `eval`, `q` and `evalQ`; each is a
separate instantiation per scalar family. Variants, emitted by text edits of
`device.zig`:

* `noinl`: every `@call(.always_inline, core, …)` → `.never_inline`.
* `evaldel`: `eval(S)` body becomes `return @call(.never_inline, evalQ, …).res;`
  so the S-family body exists once (inside `evalQ`); `q(V)` stays.

Build (Gi):

| Source | 1-entry host: base / noinl | 3-entry host: inline / noinl / evaldel |
|---|---|---|
| diode | 5.99 / 5.98 | 6.67 / 6.34 / 6.21 |
| mos1 | 8.60 / 8.65 | 10.48 / 9.57 / 9.14 |
| bsim4va | 72.65 / 73.11 | 90.81 / 79.70 (−12%) / 77.08 (−15%) |
| psp103 | 132.58 / 134.24 | 172.04 / 145.51 (−15%) / 141.59 (−18%) |

Runtime per call, `results/runtime.jsonl` (instructions; cycle delta within
the interleaved group in brackets):

| Source, entry | inline | noinl | evaldel |
|---|---:|---:|---:|
| psp103 evalQ (1-entry host) | 7,867 (4,041 cyc) | +7.5% (+4.1%) | — |
| bsim4va evalQ (1-entry host) | 6,506 (2,658 cyc) | +7.1% (+7.1%) | — |
| mos1 evalQ (1-entry host) | 612 (194 cyc) | +50% (+47%) | — |
| psp103 evalQ / eval / q (3-entry) | 7,871 / 7,231 / 4,232 | +8.1% (+4.3%) / +15.0% (+7.6%) / +15.0% (+5.4%) | 0 (−0.2%) / +6.9% (+3.9%) / 0 (0) |
| bsim4va evalQ / eval / q | 6,451 / 5,053 / 2,242 | +9.7% (+9.3%) / +38% (+35%) / +58% (+32%) | 0 (0) / +28% (+24%) / 0 (0) |
| mos1 evalQ / eval / q | 612 / 401 / 156 | +50% (+36%) / +105% (+150%) / +169% (+262%) | **+23% (+14%)** / +63% (+63%) / 0 (0) |

Conclusion: out-of-line `core` is a straight runtime loss and buys nothing for
the `--emit-so` host, which instantiates `core` once anyway; it reproduces the
2026 "inline is +43% on mos6" note in kind. `evaldel` keeps the fused hot path
at identical instructions on the big models and cuts multi-entry-host builds
15-18%, but on mos1 LLVM stopped inlining the now twice-called `evalQ` into the
host's loop (+23% instructions). It belongs to hosts that call all three
entries (ARPice), behind a host-side measurement, not to the `--emit-so` path.

`core__state` repeats much of `core` (coupled_ltra: 2.69 MB each, 3,533 of
11,287 lines differ) and is compiled once per device in every host; the split
in lever 3 at least puts it in its own process (coupled_ltra: state 22.6 Gi,
eval 22.2 Gi, in parallel).

## Lever 3 — parallel objects

`zsplit.py` builds each part with its own `zig build-obj -fPIC` in parallel
(`dyn_setup2.zig`: setup/derive/init/control/breakpoint; `dyn_state.zig`:
updateState; `dyn_eval.zig`: `evalQ` + bench, calling `device_setup` through an
extern), then `zig build-lib -dynamic a.o b.o c.o`. The `Model`/`Instance`
layouts agree across objects because every part compiles the same source with
the same compiler (the property VerA's `layoutHash` already relies on).

| Source | Variant | Total Gi | Wall (min) | Parts: Gi (sema / LLVM s) | Link |
|---|---|---:|---:|---|---:|
| psp103 | 1 object, stripped | 68.2 | 6.18 | — | — |
| psp103 | 3 objects, stripped | 80.3 | 3.31-3.43 | setup 42.6 (1.35/1.76), state 6.5, eval 31.1 (1.38/1.49) | 0.05 |
| psp103 | + grouped slots | 60.8 | 2.90 | setup 26.7, state 6.4, eval 27.7 | 0.05 |
| bsim4va | 1 object, stripped | 37.4 | 3.52 | — | — |
| bsim4va | 3 objects, stripped | 47.5 | 2.04 | setup 22.2, state 6.4, eval 18.8 | 0.05 |
| coupled_ltra | 1 object, stripped | 38.8 | 4.57 | — | — |
| coupled_ltra | 3 objects, stripped | 51.7 | 2.49 | setup 6.8, state 22.6, eval 22.2 | 0.05 |
| mos1 | 3 objects, stripped | 17.2 | 0.66 (vs 0.65) | 5.3 / 4.8 / 7.0 | 0.05 |
| resistor | 3 objects, stripped | 13.7 (vs 4.7) | — | 4.6 each | 0.4 |

Each extra process pays the ≈4.5 Gi floor, so the split is a loss below
roughly mos1 size and a 45-55% wall gain for bsim4va/psp103/coupled_ltra.
Runtime: bench hash bit-exact for every split; evalQ instructions unchanged
(psp103 7,867, bsim4va 6,506, mos1 612, coupled_ltra 318). Zig's own `-j` does
not help: LLVM emission of one module is single-threaded.

## Lever 4 — optimisation mix

Only ReleaseSmall can be mixed with ReleaseFast parts: Debug/ReleaseSafe turn
`std.debug.runtime_safety` on, which changes `Instance` (`su_ok:
if (runtime_safety) bool else void`) and so the ABI between parts.

| Source | setup at ReleaseFast | setup at ReleaseSmall |
|---|---:|---:|
| psp103, DWARF on (2 objects) | 138.7 Gi | 93.1 Gi (−33%) |
| psp103, stripped (3 objects) | 80.3 Gi | 78.3 Gi (−2.5%) |
| bsim4va, stripped | 47.5 Gi | 47.0 Gi |
| coupled_ltra, stripped | 51.7 Gi | 51.5 Gi |

Most of what ReleaseSmall saved was debug-info work on the huge setup body; once
stripped it is noise. Bit-exact (setup is `@setFloatMode(.strict)`). The setup
call's own runtime was not timed.

## Lever 5 — emitted-text shape

Hand-edited trees (`simplify.py`, one rule at a time, psp103):

| Rule | Gi | Sema | Notes |
|---|---:|---:|---|
| base | 132.6 | 2.80 | `var h: zSlots(S, &.{1576 masks})` in setup, a 553-field tuple in `core` |
| `slotarr`: an all-`0x0` slot tuple → `[N]zOf(S, 0x0)` (setup only) | 117.3 | 1.70 | setup decl sema 1.35 s → 0.26 s |
| `slotgroup`: one array per distinct mask, `h[i]` → `h<g>[j]` (psp103 `core`: 553 slots, 9 masks; bsim4va 291 slots, 22 masks) | **110.9** | **1.42** | subsumes `slotarr` |
| `conval`: `S.con(X).val()` → `(X)` | 132.5 | 2.84 | no effect |
| `boolchain`: fold `@as(i64,@intFromBool((@as(i64,@intFromBool(E))) != 0))` | 132.6 | 2.84 | no effect |
| `zto0`: `zTo(S, 0x0, X)` → `(X)` | **490.1** | 1.65 | LLVM 9 → 50 s, all in debug-info emission; stripped: 48.8 Gi, no better than `slotgroup` + strip (49.3) |

`slotgroup` on the other models: bsim4va 72.65 → 63.86 (−12%), txl 17.93 →
17.30, mos1 8.60 → 8.54, diode and coupled_ltra unchanged. With strip: psp103
49.3 Gi (−63%, 5.15 s), bsim4va 30.2 Gi (−58%, 3.14 s). `.text` bytes are
identical to base for psp103, diode, coupled_ltra; bsim4va and mos1 produce the
same size and identical instructions/eval with a different hash; every bench
hash is bit-exact.

The 1,576-field `@Tuple` is the sema hot spot, not the wrapper calls: the
slot-type tuple is built from a per-slot mask list, and grouping by mask keeps
exactly the same per-slot types (so the change is type-preserving and needs no
new prover reasoning). The number of distinct comptime family types is small
(9-22 masks per body); `zOf`/`zTo` instantiation counts are not the problem.

## Lever 6 — digital `.v` devices

The `--emit-so` of `v_count.v` (3.8 KB of emitted Zig) compiles the whole
reachable engine: the largest `.text` symbols are `rt.root.loop` (21 KB),
`sort.block` (29 KB), `rt.snapshot.load` (16 KB), `SmpAllocator`, `printFloat`
and VCD dumping. An object exporting only the device's `dispatch` (its process
code plus every `State` method it calls, `codegen-levers-2026-09-30/disp_root.zig`) costs
**6.1 Gi / 0.66 s LLVM vs 21.9 Gi for the full device**, 4.5 Gi of which is the
per-process floor. A prebuilt engine keyed on (VerA version, target, optimize)
would therefore take v_count from ≈2.9 s to ≈0.5 s wall. The runtime cost is
not measured: `rt.root.loop(s, comptime four: Dispatch, …)` currently gets
`dispatch` at comptime, and a prebuilt engine would call it through a pointer
(process bodies are already reached through a `procs[pc]` function-pointer
table), and engine `State` methods would no longer inline into the device.
This needs a prototype before a recommendation; implementation is a C-ABI seam
in `src/sim/rt/device.zig` + `root.zig`.

**Landed 2026-10-01 for `--emit-so` (LLVM) of a `.v` device**
(`src/sim/rt/engine.zig`, `orchestrator.buildEngine`). Measured against
e6d9ab3a, fresh work directory, `perf_event` user instructions over vera
and every child:

| `--emit-so` | e6d9ab3a | engine cached | first build (engine too) |
|---|---:|---:|---:|
| v_count | 17.03 Gi | 4.93 Gi (−71%) | 20.77 Gi |
| v_inv | 22.16 Gi | 5.11 Gi (−77%) | 20.95 Gi |

v_inv's extra 5 Gi was `std.mem.sort`'s block sort of the A2D edges (28 KB
of `.text`), now an insertion sort (stable, same order). Runtime, 100k 1 ns
transient points of `updateState` + `commit` (bit-identical hashes):
v_count 1721.2 → 1721.1 instructions per point, v_inv 881.3 → 883.8
(+0.3%); cycles within run-to-run noise. A first version that also moved
`State.initIn` across the seam cost +7% instructions per point (the
design's table lengths stop being comptime-known), so `initIn` stays on the
device side.

The seam was tried for native `.v` executables too and **not landed**:
count8 (8 × 32-bit counters) built 34.1 → 27.5 Gi (−19%, the design's
own code dominates), and the executable exited 1 with no output when its
stdout was a pipe (it printed correctly to a file or terminal). That is
consistent with Zig numbering error values per compilation: an engine-built
`File.Writer.drain` cannot match the `error.Unseekable` the design's `std.Io`
returns, so it fails the write. An executable's engine does I/O
through `std.Io` and writers on both sides; a contract device's does none
(it is always `quiet`, which `engine.cLoop` checks), so only devices cross.
The self-hosted backend (Debug) builds the whole v_inv engine in the same
5.9 Gi as a cache check plus the device, so it links nothing prebuilt.

## Lever 7 — preflight type check

`typeCheck` (src/main.zig) runs `zig build-obj -fno-emit-bin` over the flat
device. Measured alone (median of 3; fresh and std-warm local caches agree):

| Source | Wall | Gi |
|---|---:|---:|
| resistor | 0.048 | 0.10 |
| diode | 0.058 | 0.09 |
| mos1 | 0.050 | 0.07 |
| bsim4va | 0.110 | 0.28 |
| psp103 | 0.233 | 0.82 |
| coupled_ltra | 0.272 | 0.70 |
| txl | 0.069 | 0.04 |

It is sequential before the real build, so it is pure wall: ≈13-17% of a
diode/resistor `--emit-so`, 2% of psp103 today and ≈7% after levers 1-3. The
real build reports the same errors; running the preflight only when the real
build fails keeps the `.va`-attributed message.

## Lever 8 — profile leftovers and the native `.v` executable

* Stripped psp103 LLVM has no dominant pass (greedy RA 1.74 s, SROA 1.38,
  ISel 1.25, global splitting 1.21, inliner 1.13, InstCombine 0.71, SLP 0.65 of
  3.3 s). Chunking `setup` into outlined cold pieces is not needed for build
  time once setup is in its own object (setup LLVM 1.6-1.8 s); the 2026-09-23
  "chunking 2.8x slower" note was about `eval`.
* Native `.v` executable, 128-bit gate ripple adder (`tools/bench-v/
  ripple_adder.sh 128 200 gates`, now `ripple_adder(128, 200, gates=True)`
  in `tools/conformance.py`, 640 KB `.tb.zig`, already `-fstrip`):
  sema 4.3 s (the 900 `settleN` functions, ~70-130 ms each), LLVM 32 s (85%;
  ISel 4.2, InstCombine 3.3, SROA 2.6 s). `--state=auto` 61.4 Gi, `--state=4`
  52.0 Gi, `--state=2` 45.5 Gi: the second phase adds 18%, not 2x as
  FUTURE_PLANS §5 (since removed) said. ReleaseSmall: 56.8 Gi (−7.5%) but runtime cycles
  +12-28% (0.102 → 0.113-0.131 Gcyc for 20,000 vectors; same checksum). The
  lever here is the emitted `settle` shape, not flags; not explored further.

## Stack frames (coordinator follow-up 1)

Claim checked: Zig 0.16 does not share stack slots between arrays in
sequential scopes. `stk/s.zig` (four 4 KiB `[512]f64` in `B0: {}`, `B1: {}`
and two plain blocks, each passed to an extern) compiles at ReleaseFast to
`sub $0x4008,%rsp` (16 KiB) with or without DWARF: confirmed, no colouring.

It does not explain the large device frames measured here (`frames.py`, first
`sub $imm,%rsp` per function):

| Device | Largest frames |
|---|---|
| psp103 | `setup` 6,816 B, `evalQ` 5,920 B |
| bsim4va | `setup` 8,096 B, `evalQ` 4,992 B |
| coupled_ltra | `core__state` 157,952 B, `eval` 156,768 B, `device_update` 153,048 B |
| txl | `device_update` 166,496 B, `device_eval` 83,552 B |

In all seven analog trees **every array local is declared at function top
level** (662 `var x: [N]…` at 4-space indent, 0 inside nested blocks), and in
coupled_ltra/txl the locals (160,160 / 82,784 B) are almost exactly the arrays
the core returns in its result struct (152,832 / 82,544 B): they are live until
the return, so no slot sharing could remove them. The 150 KB frames come from
the core returning whole arrays by value in its result struct (`f57: [2048]f64`,
`f58..f61: [4096]f64` in coupled_ltra), and each caller that receives that
struct (`eval`, `updateState`) gets a frame of the same size. The PSP103 NQS dense-Dual overflow
and hisimhv's 288 KB amdgcn frame were not rebuilt here; for those the slot
tuple `h` (one field per hoisted value, live for the whole function) is the
likelier term, and slot grouping (lever 5) does not change its size. Splitting
phases into functions helps only where disjoint phases each own a large array;
the measured frames are dominated by values that are live to the end.

## `-flto` (coordinator follow-up 2)

`-flto` (single-module, `-fstrip` both sides, 2 rounds, `results/lto.jsonl`):

| Source | Gi strip → strip+LTO | `.text` | evalQ instr | evalQ cycles |
|---|---|---|---:|---:|
| psp103 | 68.1 → 72.8 (+6.8%) | 294,041 → 294,011 | 7,867 → 7,711 (−2.0%) | −1.8% |
| bsim4va | 37.4 → 39.8 (+6.5%) | 150,873 → 150,875 | 6,506 → 6,493 | −0.9% |
| coupled_ltra | 38.8 → 39.4 (+1.6%) | 174,125 → 139,691 | 318 → 311 | −4.0% |
| txl | 13.5 → 14.2 (+5.3%) | 66,077 → 63,947 | 177 → 173 | −2.1% |
| mos1 | 7.91 → 8.08 (+2.2%) | 16,985 → 17,083 | 612 → 612 | (noise) |

Every bench hash is bit-exact. Packed double ops (`v{add,sub,mul,div,fmadd}pd`)
rise only slightly (coupled_ltra 361 → 402, txl 149 → 155, psp103 5,116 →
5,132), and the array/filter loops of coupled_ltra and txl live in
`updateState`, which this bench does not time, so the loop-vectoriser gain the
Trial/ZvsRust experiment saw is **not demonstrated on device code**. Given the
documented LLVM miscompile caveat, LTO is not recommended until a bench of
`updateState` shows a gain worth the +2-7% build and the risk; `optimized`
float-mode sites are where a vectorised reduction could reassociate, so that
bench must also check bit-exactness.

## The test suite

`zig build benchmark` builds each runnable fixture's testbench with
`zig build-exe -ODebug -fno-llvm` (self-hosted backend). Sampled sequentially
(`tbsample.py`, 30 runnable `.va` and 16 `.v` fixtures, fresh work dir each):

* `.va`: zig build median 0.31 s per fixture (max 2.65 s); **zig = 91.9% of
  per-fixture wall**, the testbench run 0.1% (1 ms), the rest VerA.
* `.v` (10 of 16 accepted): build median 0.35 s; 32% of wall here only because
  one fixture runs to its event budget (7.8 s).
* Inside one testbench build (ch04 `68_log10`): sema 0.22 s of which the
  device's `eval` is 4.5 ms; the rest is std formatting, DWARF/panic support
  and the runner. Device codegen shape is therefore irrelevant to suite time;
  the suite lever is amortising the fixed runner/std work (several fixtures
  per testbench build, or a prebuilt runner), not anything above.
* With 32 jobs, `ch10_directives` (117 fixtures, 61 testbench builds) took
  3.6 s wall / 92 CPU-s; nothing is cached between suite runs.

## Recommended implementation order

1. **Strip `--emit-so` device builds by default**, `--debug-info` to opt back
   in (`lib/backend/orchestrator.zig` `buildArgv`). Biggest win, zero runtime
   or numerics risk, one line. Device text is unchanged, so a patch release.
2. **Skip the preflight on `--emit-so`**, re-running it only on a failed build.
3. **Group hoisted slots by mask** in the emitter. −12-16% on the large models,
   −50% of their sema; changes device text (minor version, goldens move).
4. **Parallel setup / state / eval objects for large devices** (gate on emitted
   size, e.g. > 200 KB). Needs the dyn host to export per part; the host owns
   `exportDevice`, so this is a contract change. Combined with 1+3 it takes
   psp103 from 12.0 s to 2.9 s wall (critical path = the eval object).
5. **Prototype the prebuilt digital engine** and measure its runtime before
   committing to it.
6. For multi-entry hosts (ARPice), measure `evaldel` in the host's own loop;
   do not apply it on the `--emit-so` path.

Do not do: out-of-line `core`, ReleaseSmall for hot code, textual `zTo`
removal, or `S.con().val()` / boolean-chain cleanups for build time.

## Reproduction

Scripts and raw records are in
[codegen-levers-2026-09-30/](codegen-levers-2026-09-30/) (paths inside them
point at the original scratch and worktree and must be relocated):

```sh
# emit a tree once
vera MODEL.va --emit-so --contract tools/contract.zig --dyn dyn_bench.zig \
  --work-dir trees/MODEL --optimize=ReleaseFast --zig-backend=llvm
# build matrix, interleaved rounds, fresh cache per build, instruction counts
python3 run.py out.jsonl 2 @l1.spec          # label:tree:host[:zigflags]
python3 runsplit.py out.jsonl 2 l34.spec     # parallel build-obj parts + link
python3 simplify.py trees/psp103 trees5/psp103.grp slotgroup
# runtime + bit-exact check, first .so is the baseline
python3 rbcmp.py 3 bench_loop so/psp103.base.so so/psp103.grp.so
python3 pf.py 3 resistor psp103              # preflight cost
python3 tbsample.py sample.txt out.jsonl     # suite: build vs run per fixture
```

`results/*.jsonl` hold every build sample (phase timers, top declarations, top
LLVM passes, instructions, `.text` size) and `results/runtime.jsonl` every
runtime comparison.
