# Device runtime: cycles per call of the emitted device

Measured 2026-10-01, VerA `45022040` (base) → `9ec91ab6` (three commits
below), Zig 0.16.0, LLVM, ReleaseFast stripped `--emit-so`, Intel i9-14900HX,
pinned to P-core 4. Measures A/B/C/D: none moved (the strict suite is
2178/2178 before and after, FAIL/XFAIL name lists both empty). Device text
changes, so this is a minor version (AGENTS.md §3).

## Result

| Rank | Change (commit) | Model / entry | Cycles before → after | Instr before → after | Bit-exact | Build (fresh, Gi) |
|---|---|---|---:|---:|---|---|
| 1 | updateState stores held arrays in place (`708edf39`) | txl updateState | 20825 → 254* | 22256 → 1070* | yes | txl 8.69 → 7.74, coupled_ltra 34.2 → 31.9 (all three) |
| | | coupled_ltra updateState | 40739 → 2005* | 49815 → 8748* | yes | |
| 2 | stateCtl copies only the written range of a ≥ 64-element held array (`9ec91ab6`) | txl tran step | 7399 → 958 | 10116 → 3059 | yes (incl. revert) | |
| | | coupled_ltra tran step | 19684 → 14783 | 46990 → 39673 | yes | |
| | 1+2 together | txl tran step | 28148 → 913 (−96.8%) | 31507 → 3065 | yes | |
| | | coupled_ltra tran step | 59793 → 15054 (−74.8%) | 88384 → 39697 | yes | |
| 3 | memory-backed arrays start with `zFill`, not `@memset` (`10d41586`) | bsource evalQ | 1084 → 549 (−49%) | 3376 → 1822 | yes | bsource 7.04 → 7.03 |
| | | bsource eval | 1104 → 583 | 3373 → 1819 | yes | |
| | | bsource (`st` "uninit") evalQ | 835 → 523 (−37%) | 2585 → 1790 | yes | |
| — | all three | resistor, diode, mos1, bsim4va, psp103 (every entry) | ±1% (noise) | identical | yes, device text byte-identical | 0 |

\* updateState after 1+2; 2 adds the range bookkeeping (txl 210 → 245 cy).
"tran step" = 3 evalQ + updateState + stateCtl(.commit) at an advancing
`$abstime` (the host's accepted-step cost). Full final table: `final.txt`;
every run: `results.jsonl`.

### Where the remaining time goes (final, per call, cycles)

| Model | evalQ | eval | q | updateState | tran step |
|---|---:|---:|---:|---:|---:|
| resistor | 8 | 8 | — | — | 70 |
| diode | 77 | 76 | 53 | — | 304 |
| mos1 | 195 | 116 | 35 | 325 | 1049 |
| bsim4va | 2624 | 2160 | 1396 | 1439 | 8838 |
| psp103 | 4045 | 3806 | 3225 | 272 | 11704 |
| txl | 68 | 69 | — | 254 | 913 |
| coupled_ltra | 104 | 110 | — | 2005 | 15054 |
| bsource (13-op tape) | 549 | 583 | — | — | 1977 |

The evalQ column at a fixed `t` hits txl/coupled_ltra's DC branch; their
convolution work is in the tran step.

### Reference: OpenVAF on the same models

OpenVAF-r (`/nix/store/gg38…-openvaf-r-unstable-2026`, `-O 3`, native) via
a small OSDI 0.4 host (`scratchpad/osdi/host.c`, not committed), same 64 bias
points, same counters. Not like for like: OSDI `eval` with all four `CALC_*`
flags, then the four `load_*` calls into a dense matrix; limiting off; mos1
patched (`$prev(x)` → `x`, OpenVAF has no `$prev`); psp103's module line
un-macro'd.

| Model | OpenVAF eval | OpenVAF eval+load | VerA evalQ (sparse duals, written out) |
|---|---:|---:|---:|
| diode | 86 | 135 | 77 |
| mos1 | 286 | 405 | 195 |
| bsim4va | 3896 | 4247 | 2624 |
| psp103 | 5214 | 5298 | 4045 |

VerA's evalQ is at or below OpenVAF's eval alone on all four.

## The changes

**1. In-place held arrays in updateState.** The `<core>__state` slice copied
each copy-on-write §5.10 held array three times per accepted step: into a
local on the first store (`zArrW`), out through the slice's return struct,
and back into `Instance`. updateState stores every held value back
unconditionally, so the slice now takes `*Instance` and stores through
`p<id>: *[n]T`; no array field is returned or written back. Excluded: a
slice that runs on a §9.21.1 `table_probe` copy, and an array a
`vera_timepoint` cache re-points at its `tp` slot. eval/q/acceptQ keep
copy-on-write (their stores must not persist). A slice whose only work is
in-place arrays leaves `m` unread; the call becomes `_ = …` (the suite caught
9 fixtures failing on `unused local constant` before that fix landed in the
same commit).

**2. Range-copy stateCtl.** With (1), txl's tran step was 7.4k cycles of
which ~6.5k was `stateCtl(.commit)` copying 5 × 2048 × 8 B. A held array
stored in place with ≥ 64 elements gets `<field>__dirty: [2]i64`;
`zArrStD` widens it on every in-place store, `zArrSync` copies just that
range on commit or revert and empties it. Invariant: `inst` and `State`
differ only inside the range; the `Instance` default, `initState` and
acceptQ's whole-array write-back set it to the whole array. Tracking every
held array (no threshold) cost coupled_ltra updateState +27% (1881 → 2384)
for 20% less tran; the 64-element threshold gives −25% tran at +2.5%
update. The transient hash rejects a perturbed step every 7th point
(updateState, revert, updateState, commit), so revert is covered.

**3. `zFill`.** Zig 0.16's compiler_rt `memset` stores one byte per
iteration (`compiler_rt.zig` `memset`), and LLVM turns a large `@memset` into
that call: 46% of bsource's evalQ (perf). `zFill` writes the start value with
explicit 4-lane `@Vector` stores for plain f64/i64 arrays, one element per
store for duals, reading the value through a volatile so LLVM cannot fold the
loop back into a `memset` call; ≤ 128 B keeps `@memset` (inline stores).
After it, plain `vera_scratch` costs what `"uninit"` does (549 vs 523).

## stdpp (the user's suggestion)

Lanewise loops in emitted devices, checked one by one:

* **Held-array copies** (the biggest): eliminated by (1) and (2), not
  vectorised. Nothing left to copy.
* **Array zeroing**: (3) is the stdpp shape inlined into the kernel text
  (explicit `@Vector(4, T)` blocks plus a tail, no reordering, no new host
  dependency). Importing stdpp would make every host (ARPice, ESPice) carry the
  module for one fill loop.
* **History search** (`while (j + 1 < nh && ht[j] < ta) j++`): a `position`
  search, bit-exact if vectorised, but emitted from MIR control flow, so it
  would need loop-idiom recognition in codegen. After (1)+(2) txl's whole tran
  step is 913 cycles; the walk is not worth that.
* **Convolution sums**: 3-6 fixed terms, unrolled; reordering them is not
  bit-exact.

## Measured and not built

| Lever | Result | Why not |
|---|---|---|
| Link glibc libm (`-lc`) | diode evalQ 78 → 43 cy (−44%), mos1 198 → 172 (−13%) | not bit-exact (glibc vs compiler_rt `exp`), and it is the host's link choice: `RefFamily`'s `@exp` becomes whatever libm the host links. exp+ldexp+log+pow are 22-31% of mos1/psp103 evalQ under compiler_rt. |
| Device-side copy of compiler_rt `exp` with a cheaper `scalbn` | not built | bit-exact only against compiler_rt; a glibc-linked host would change numerics |
| Division by a setup constant → reciprocal multiply (mos1 `/ su.r[0]`) | not built | not bit-exact |
| Repeated transcendentals on the same argument (psp103) | none found | 26 `exp` sites, 26 distinct operands; LLVM already CSEs identical ones |

Profiles (`perf record -e cycles:u`, `--debug-info` builds) of mos1 and psp103
evalQ are flat apart from libm; no single emitted region dominates.

## Method

* Host `device-runtime-2026-10-01/dyn_rt.zig`: the `--emit-so` entry points
  (codegen-levers `dyn_bench.zig`) plus loops for evalQ (sparse f64 duals),
  eval(S), q(V), updateState(V) and the tran step, and two FNV hashes: every
  output at 64 bias points (evalQ, eval, q), and 1074 tran steps including the
  revert path. Workload cards: txl from ARPice X01 `txl_tran_matched_step`,
  coupled_ltra from `cpl_op_dc_decoupled` (cmod), bsource a 13-op tape
  (`c0*c1 + exp(c0-c1) - 2*c2 + sin(c3)`). The tran timeline re-initialises
  every 512 steps so the history stays bounded.
* `emit.sh VERA OUT` emits every workload with a given `vera` binary;
  `cmp.py ROUNDS MODELS ENTRIES BASE VARIANT…` interleaves variants
  (`rb.py`, `pc.py` per-thread counters, `taskset -c 4`), min cycles and
  median instructions per call; `buildcost.py` is a fresh-cache build's
  retired instructions.
* Models: ARPice `models/{resistor,diode,mos1,bsim4va,psp103,bsource}.va`,
  `models/native/{txl,coupled_ltra}.va` at ARPice `e01774ac`.
* Noise: load 5-75 during runs. Cycles are compared only within one
  interleaved group; a change with identical instructions and identical
  device text (bsim4va q −15%, txl evalQ +30% in one group) is noise.
