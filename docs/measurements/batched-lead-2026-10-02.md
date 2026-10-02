# Batched instances with the lead protocol (2026-10-02)

What: diode, mos1, bsim4va and psp103 are `batch_ok` and `batch_lead`
(commit "feat(device): batch_lead ..."). A family whose `V` holds W
operating points evaluates them with the lead protocol (`contract.LeadState`).
The leader point steers every decision, a point that disagrees is re-run,
and every result is bit for bit the scalar family's for that point. This
file measures what that costs and gains, and how often real circuits
diverge. Machine: i9-14900HX (AVX2, no AVX-512), pinned to P-core 4,
ReleaseFast, `-mcpu=x86_64_v3`. The machine was shared (load 14-20), so
**instructions are the stable column**; cycles moved up to 1.7× between
runs of the same library and are given for orientation only.

Harness in `batched-lead-2026-10-02/`: `batch_family.zig` (a W-point
family with the protocol), `batch_host.zig` (exports the bench and check
entry points; packs W instances' unknowns into lanes and scatters every
residual, charge and Jacobian entry back, so pack/unpack is inside every
number), `build.sh`, `bench.py`, `analyze.py` (real-bias divergence).

## 1. Scalar evalQ: unchanged

A comparison is `zCmp`, which folds to the same compare in a scalar
family; a stripped value is `zStrip`, the same `S.con(a.val())`. A
derivative-free operand that differs per point (a `ddx`-stripped probe, a
`$prev` latch) is no longer folded into an f64 expression through `.val()`:
it stays an `S` value (`zMulP`/`zAddP`/`zSubP`, which are `scale`/`addC`
in a scalar family). Base e96948cd vs this branch, the
`device-runtime-2026-10-01` harness (`cmp.py`, hash of every output over
the bias set): **bit-identical on all four models**. Instructions per call,
base → this:

| model | evalQ | eval | q | tran step |
|---|---|---|---|---|
| diode | 186.0 → 186.0 | 170.0 → 170.0 | 101.0 → 101.0 | 947.2 → 947.2 |
| mos1 | 586.2 → 595.8 (+1.6%) | 364.0 → 364.0 | 156.2 → 160.9 (+3.0%) | 1775.8 → 1795.3 (+1.1%) |
| bsim4va | 6025.9 → 6040.4 (+0.2%) | 4692.9 → 4693.0 | 1256.7 → 1257.0 | 21070 → 21114 (+0.2%) |
| psp103 | 6613.5 → 6615.5 | 5808.0 → 5815.0 (+0.1%) | 2780.6 → 2780.7 | 20865 → 20871 |

Re-measured after rebasing onto ABI 6 (main 83f40577, setup cache and
temperature in the `Model` row): still bit-identical on all four models;
evalQ instructions diode 181.0 → 181.0, mos1 588.5 → 589.8 (+0.2%),
bsim4va 6041.0 → 6055.4 (+0.2%), psp103 6617.3 → 6619.3; q: mos1 156.2 →
160.9 (+3.0%), the others unchanged. In a batch every point shares one
`Model` row (the batch key), so the setup values the core reads stay
scalar. The batched numbers below are unchanged by the rebase
(`results_nosig.jsonl` is the ABI 6 run).

mos1's increase is its `$prev`-averaged gate capacitances (`capgs = chgs +
$prev(chgs)`, a stripped `vgs` times a latch difference): those values are
per point, and folding them was the collapse that made a batch inexact.
Cycles moved within run-to-run noise (mos1 evalQ +0.8% and +1.6% in two
runs).

## 2. Batched evalQ per instance (instructions; `results_nosig.jsonl`)

`coherent`: W copies of one point (one run). `mixed`: W consecutive points
of a 64-point bias set spread over regions. `runs` = device runs per
batched call on the mixed set. Ratio = scalar / batched per instance.

| model | W | scalar | coherent | × | mixed | runs | × |
|---|---|---|---|---|---|---|---|
| diode | 4 | 182 | 104 | 1.75 | 104 | 1.00 | 1.75 |
| diode | 8 | 182 | 104 | 1.76 | 104 | 1.00 | 1.75 |
| mos1 | 4 | 601 | 366 | 1.65 | 1174 | 3.00 | 0.51 |
| mos1 | 8 | 601 | 347 | 1.73 | 1512 | 4.25 | 0.40 |
| bsim4va | 4 | 5806 | 3235 | 1.79 | 9621 | 2.88 | 0.60 |
| bsim4va | 8 | 5806 | 3130 | 1.86 | 9677 | 3.00 | 0.60 |
| psp103 | 4 | 6375 | 3444 | 1.85 | 7654 | 2.00 | 0.83 |
| psp103 | 8 | 6375 | 3484 | 1.83 | 7741 | 2.00 | 0.82 |

Cycles, same run: coherent 1.26× / 1.41× (diode), 1.34× / 1.25× (mos1),
1.61× / 1.47× (bsim4va), 1.87× / 1.70× (psp103); mixed 0.32-1.41×.
W = 8 spills (AVX2 has 16 registers of 4 doubles) and gains little or
nothing over W = 4. Bit mismatches against scalar: **0 on every row**, for
coherent batches, mixed batches, and mixed batches under five analysis
states (static iteration 1 and 4, transient iteration 1 and 3, initial
step; `bad_sims`), which exercise mos1's `$prev`/`analysis` paths.

**A divergent batch is slower than scalar** for mos1, bsim4va and psp103:
each extra run costs about a coherent batch. So a host batches only
instances that take the same path, and section 3 shows how often that is
possible.

## 3. The region signature

`contract.region(D, x, model, inst, sim) u16` hashes the outcome of every
decision `eval` makes at `x`. Equal decisions give equal signatures, so a
batch of equal signatures runs once (a collision costs a re-run, never a
wrong value). A device without `batch_lead` never diverges: its signature
is the comptime constant 0 and a host skips the call.

Cost (instructions, `region` vs scalar evalQ):

| model | region | scalar evalQ | fraction |
|---|---|---|---|
| diode | 101 | 182 | 0.55 |
| mos1 | 161 | 601 | 0.27 |
| bsim4va | 1566 | 5806 | 0.27 |
| psp103 | 3167 | 6375 | 0.50 |

It reads setup values from `inst` (the setup split) and recomputes no
setup term. The optimizer keeps only the decisions' cone, but that cone
is large. The diode decides `I > 0` on a current that needs `exp`, and
psp103 has 796 comparison sites, many on late intermediates. A cheaper
hash of the early decisions only would lose "equal signature means one
run". So the signature is not cheap enough to call before every batch.

**It comes free from the batched call instead.** `LeadState(W, true)`
hashes each point's outcomes as it runs: a point kept from a run took its
own path through it, so `regions()` after the call equals `region` at
every point. The testbench asserts this on every `batch_lead` fixture, and
`analyze.py` asserts it on the decks. Cost on the batched call: +15%/+10%
instructions for diode, +16%/+14% mos1, +3%/+4% bsim4va, +2%/+2% psp103
(W = 4/8, coherent; `results_sig.jsonl` vs `results_nosig.jsonl`).
`LeadState(W, false)` does not hash and costs nothing.

## 4. Divergence on real bias (`divergence.txt`)

The decks come from ARPice `tests/benchmark/postlayout/gen.py`: ring, chain
and logic on psp103 (LEVEL=1040), and ring and logic on bsim4 (LEVEL=54),
about 1k MOSFETs each. Each deck was simulated by espice (`.tran 5p 1000p`).
`analyze.py` flattens the deck and groups MOSFETs by (card, instance
parameters). At every second accepted timepoint, it batches each group's
instances W at a time with their real terminal voltages. Internal nodes are
taken as their terminal: no series resistance in these cards. SRAM was not
run. fetch.sh's real extractions were not attempted.

Runs per batch (1.00 = no divergence) and the fraction of coherent batches:

| deck | W | netlist order | grouped by fresh `region` | by last timepoint's signature |
|---|---|---|---|---|
| ring psp103 | 4 | 1.82 (28%) | 1.01 (99%) | 1.30 (71%) |
| chain psp103 | 4 | 1.85 (26%) | 1.01 (99%) | 1.29 (72%) |
| logic psp103 | 4 | 1.83 (35%) | 1.03 (97%) | 1.19 (82%) |
| ring bsim4 | 4 | 2.13 (0%) | 1.02 (98%) | 1.06 (94%) |
| logic bsim4 | 4 | 2.57 (11%) | 1.07 (93%) | 1.19 (84%) |
| ring psp103 | 8 | 2.05 (22%) | 1.03 (97%) | 1.45 (57%) |
| chain psp103 | 8 | 2.13 (19%) | 1.03 (97%) | 1.46 (58%) |
| logic psp103 | 8 | 2.32 (16%) | 1.07 (93%) | 1.35 (70%) |
| ring bsim4 | 8 | 2.38 (0%) | 1.04 (96%) | 1.11 (89%) |
| logic bsim4 | 8 | 3.47 (3%) | 1.17 (86%) | 1.36 (72%) |

Mismatches against scalar (values and signatures, first timepoint): 0.
"Last timepoint" is two accepted steps back, so it is pessimistic for
Newton iterates within one step.

## 5. What a host should do

1. **Never batch in netlist order.** 1.8-3.5 runs per batch makes every
   compact model slower than scalar.
2. **Bucket on the signatures the previous batched call returned**
   (`LeadState(W, true).regions()`, or the testbench's family). At the next
   Newton iterate, instances with equal signatures go in one batch. New
   instances, and the first iterate, have no signature: batch them in any
   order, or call `region` once. For bsim4 this gives 1.06-1.19 runs at
   W = 4. For psp103 it gives 1.19-1.30, because psp103's comparisons
   flip with small bias changes.
3. **Fresh `region` per iterate** gives 1.01-1.07 runs at W = 4. It costs
   0.27 (bsim4va) to 0.50 (psp103) of a scalar evalQ, more than the batch
   saves for psp103 (coherent saves 0.46 of scalar per instance). It is
   worth it only for bsim4va, and only marginally.
4. Keep W = 4 on AVX2: W = 8 adds divergence and spills.
5. A batch is exact whatever the bucketing, so a stale signature or a hash
   collision costs only time. There is no per-lane divergence mask: the
   guarantee (exact per point, divergent batches included) holds instead.

Net at W = 4 with rule 2, from instructions (coherent cost × runs vs
scalar): bsim4 ring about 1.6×, bsim4 logic about 1.5×, psp103 about
1.4-1.6×. A real host's speedup also depends on its own pack/unpack and
its iterate-to-iterate signature stability.
