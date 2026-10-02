# Batched instances: W operating points per evalQ, re-measured

Measured 2026-10-01 on the VerA tree with VerA's own vector exp/log/pow
(`contract.gm.hexp`, `hlog`, `powV`), i9-14900HX (AVX2 + FMA + AVX-VNNI, no
AVX-512), P-core 4. It re-runs AGENTS.md §5's "instance lanes" line, which
was measured on AVX2 only, with scalar transcendentals and hand-converted
devices (diode 1.07-1.22×, mos1 0.78-0.86× at W = 4/8). This is a
measurement: no codegen default changed.

## Setup

* Devices: ARPice diode, mos1, bsim4va, psp103, emitted by VerA as they
  are. None of the four is `batch_ok` (each steers on a value or collapses
  one to a scalar), so no family may legally batch them today.
* `batched-instances-2026-10-01/batch_family.zig`: `RefSparse`'s
  numerics with V = `@Vector(W, f64)` and each derivative lane a W-vector
  (a P × W tile stored lane-major); comparisons and `sel` per point; exp, log
  and pow on the whole vector. `val()` returns one point's value (the
  "leader"), so a device that steers follows that point's branches in
  every lane.
* `batch_host.zig`: evalQ over W points per call, gathering the W
  instances' unknowns into lanes and scattering every residual, charge
  and Jacobian entry back per instance (a host pays both), against scalar
  evalQ (the sparse `RefFamily`) on the same points in the same `.so`.
  `bench_check`: with all W points equal, every batched output equals the
  scalar one bit for bit (0 mismatches on all 24 builds).

## Coherent batches: per-instance cycles

W distinct bias points per call, steering on point 0: the cost when every
point of a batch takes the same path. Cycles per instance, min of 5
(`results1.jsonl`; this machine was shared, ±10%):

| Model | x86_64 (SSE2) W=2 | v3 W=2 | v3 W=4 | v3 W=8 (2 regs/op) | native W=4 | native W=8 | scalar (v3), new math | scalar, glibc math |
|---|---|---|---|---|---|---|---|---|
| diode | 43 (1.21×) | 39 (1.24×) | 36 (1.35×) | 34 (1.44×) | 35 (1.36×) | 34 (1.45×) | 49 | +1% |
| mos1 | 149 (1.18×) | 138 (1.32×) | 112 (1.42×) | 110 (1.42×) | 125 (1.51×) | 114 (1.61×) | 158 | +21% |
| bsim4va | 2824 (1.28×) | 2014 (1.26×) | 1688 (1.58×) | 1993 (1.38×) | 1639 (1.73×) | 1948 (1.39×) | 2664 | −1% |
| psp103 | 2807 (1.36×) | 1960 (1.62×) | 1495 (2.11×) | 1764 (1.92×) | 1498 (2.09×) | 1765 (1.81×) | 3159 | −7% |

(×: against scalar evalQ in the same build. "glibc math": the scalar
evalQ with glibc's exp/log/pow linked instead, measurement only.)

Coherent, batching wins at every W on every model; W = 4 is the best
or close to it on AVX2, and W = 8 loses to it on bsim4va and psp103 because
the P × 8 tiles spill (mos1 W=8: 680 stack stores in 3369 instructions of
`evalBatch`, against 373 in 2482 at W = 4).

## Divergence: what a correct batched host would pay

`bench_groups` counts how many batched evaluations a correct host needs
for the host's 64 bias points in batches of W: steer on the first point not
yet answered, keep every point whose outputs then equal its scalar ones,
repeat. A point also mismatches when the device collapses a value to a
scalar (`S.con(x.val())`, e.g. mos1's), which a batched codegen would have
to emit per lane.

| Model | W=4 runs (coherent: 16) | effective per point | W=8 runs (coherent: 8) | effective per point |
|---|---:|---|---:|---|
| diode | 16 | 36 cy (1.35×) | 8 | 34 cy (1.44×) |
| mos1 | 47 | 328 cy (0.48×) | 31 | 427 cy (0.37×) |
| bsim4va | 46 | 4853 cy (0.55×) | 24 | 5978 cy (0.46×) |
| psp103 | 32 | 2990 cy (1.06×) | 16 | 3527 cy (0.96×) |

The 64 points sweep every region (they are the dyn host's spread, not a
circuit's); a circuit whose instances sit in one region batches like the
coherent table, one whose instances straddle regions like this one.

## The old mos1 slowdown, root-caused

* **Not the math.** With per-lane scalar exp/log/pow in the batch family
  (`results_sm.jsonl`), coherent mos1 still batches at 1.37× (W=4) and
  1.41× (W=8); the vector math adds 0.05×. diode: 1.21× → 1.35×, psp103
  1.64× → 2.11×.
* **Divergence and per-lane collapses.** mos1's region branches (cutoff,
  linear, saturation, the drain/source swap) and its `S.con(h.val())`
  collapse make 47 of 64 points need their own run at W = 4: 0.48×. A
  hand conversion that turns those branches into compute-both-sides
  selects pays every arm's arithmetic in every lane instead; that is the
  0.78-0.86× of 2026-09.
* **Tile spills** cost W = 8 its advantage on AVX2 (see above), independent
  of divergence.

## Other ISAs: llvm-mca estimates (not measured)

`asm.sh` cross-compiles `evalScalar` and `evalBatch`; `mca.py` runs
llvm-mca 21 on each function body as one straight line (every branch arm
counted) and compares per-instance throughput (`mca.txt`). Calibrated
against this host: at W = 4 (v3, `-mcpu=alderlake`) llvm-mca's ratio is
+16% high (mos1 1.66 vs 1.42 measured, diode 1.57 vs 1.35); at W = 8 it is
2.1× high (diode 3.01 vs 1.44), because it models neither the spills'
latency nor the branch structure. The calibrated column scales by the
same-W factor measured here (W = 8 by 0.48, W = 2 by 0.80-0.84 from the
SSE2 build). Treat these as rough.

| Model | target | W | llvm-mca ratio | calibrated |
|---|---|---:|---:|---:|
| diode | x86_64_v4 (AVX-512) | 8 | 3.74 | ≈1.8× |
| diode | znver4 | 8 | 3.35 | ≈1.6× |
| diode | sapphirerapids | 8 | 3.76 | ≈1.8× |
| mos1 | x86_64_v4 | 8 | 2.63 | ≈1.3× |
| mos1 | znver4 | 8 | 2.49 | ≈1.2× |
| mos1 | sapphirerapids | 8 | 2.43 | ≈1.2× |
| diode | neoverse_n1 (NEON) | 2 | 1.26 | ≈1.0× |
| diode | apple_m1 | 2 | 1.06 | ≈0.9× |
| diode | neoverse_v1 (SVE, NEON width) | 2 | 1.09 | ≈0.9× |
| mos1 | neoverse_n1 | 2 | 0.98 | ≈0.8× |
| mos1 | apple_m1 | 2 | 1.17 | ≈1.0× |
| mos1 | neoverse_v1 | 2 | 1.27 | ≈1.1× |

(These are coherent-batch ratios; divergence divides them as in the table
above. Native widths per stdpp's `lanes.width(f64)`: SSE2/NEON 2,
AVX2 4, AVX-512 8 at 512 bits.)

## Break-even W

Coherent: every model breaks even at W = 2 on x86 (1.18-1.62×) and is best
at W = 4 on AVX2. With this host's mixed-region bias set: diode at any W,
psp103 only around W = 4 (1.06×), mos1 and bsim4va never (0.37-0.55×).
NEON (W = 2) is estimated at or below break-even for diode and mos1.

So batching pays for devices that do not steer per point, or circuits
whose instances share an operating region; for the compact models as
emitted it needs per-lane collapses and divergence handling (run each path
group once, with masks) before it beats scalar evalQ.
