# Device build levers, second pass

Measured 2026-10-01 on branch `perf/device-build-2` (base `3a7b4d24`, rebased
onto `45022040`), Zig 0.16.0, LLVM, i9-14900HX. Follows
[codegen-levers-2026-09-30.md](codegen-levers-2026-09-30.md) and uses its
method: build cost is retired user instructions of the `zig` process tree
(Gi = 10^9, `perf_event_open`), from a fresh cache, `-j1` where a single
process is compared; runtime identity is the bench host's output hash at 64
bias points plus the `.text` bytes of the built library. The `.v` digital
engine (lever 6 of the earlier study) landed separately and is not repeated.

Measures A/B/C/D: none moved. Strict suite 2178 pass / 0 FAIL / 0 XFAIL
before and after; FAIL/XFAIL name lists empty on both sides.

## Result

| Rank | Lever | Effect | Runtime | Status |
|---|---|---|---|---|
| 1 | `RefFamily.Of(m)` checks its mask in O(1) instead of a 64-step comptime loop | psp103 eval part 23.36 → 14.31 Gi (sema of `evalQ` 2.4 s → 0.28 s), bsim4va eval 13.36 → 8.25, mos1 3.66 → 2.60 | `.text` identical | landed `95210e29` |
| 2 | Strict suite: plain analog testbenches built 8 per binary, dispatched on `argv[0]` | strict suite wall 180.8 → 97.9 s (-j4, 10 GB cgroup); 1292 of 1403 testbenches batched | transcripts byte-identical | landed `1ba6f3bc` |
| 3 | Strict suite: strip the Debug fixture testbenches | per testbench 8.51 → 6.28 Gi, 6.70 → 6.20 Gi | transcripts identical (30-fixture sample, all 1403 in the suite) | landed `f934df52` |
| 4 | Pub-decl allowlist as an enum (`@hasField`) instead of a comptime `StaticStringMap` | mos1 2.60 → 2.46 Gi, psp103 eval 14.31 → 14.19, a fixture testbench −0.12 Gi | `.text` identical | landed `9f7168e6` |
| 5 | Suite fan-out sized from RAM (one build per 2 GiB, capped at CPUs) | no build-time change; stops a 3-agent host from freezing (peak 4.0 GB RSS) | — | landed `48997683` |
| ✗ | Contract checks opt-in (`vera_validate_contract` in the root) | 0.4-1.8% of a build (mos1 2.454 → 2.417, bsim4va eval 8.100 → 7.958, psp103 eval 14.183 → 14.125) | — | rejected: a host would lose `validateHost`'s obligations by default for <2% |
| ✗ | psp103 `setup` slots back to one local per slot (undo grouping, setup only) | setup part 22.5 → 20.7 Gi, but its sema doubles (1.2 → 2.8 s) | not timed | rejected: mixed, and it is emitted-text shape the runtime agent owns |
| ✗ | psp103 core slots as locals | eval part 14.32 → 14.43 Gi | — | rejected |
| ✗ | VerA-level content-addressed `.so` cache | unchanged psp103 rebuild is 0.44 s of which VerA's emission is 0.27 s; mos1 0.09 s | — | rejected: ≤0.17 s to win, and the key would have to hash every transitive host input Zig's manifest already checks (ARPice already keys its work dir by device text) |
| — | Fewer entry instantiations (`eval`/`q` from `evalQ`) | not re-measured: the `--emit-so` bench host instantiates `core` once already; earlier study measured +14% mos1 `evalQ` cycles for the variant | — | host-side decision (ARPice), unchanged |

## End to end (`vera --emit-so`, stripped, bench host with `exportDevicePart`)

Two interleaved rounds, load ≈ 12, min wall, Gi of the first round:

| Model | Wall base → now | Total Gi | Longest part Gi |
|---|---|---|---|
| resistor | 0.30 → 0.19 s | 0.62 → 0.41 | 0.62 → 0.41 |
| mos1 | 1.02 → 0.62 s | 3.68 → 2.47 | 3.68 → 2.47 |
| bsim4va | 3.34 → 2.58 s | 26.85 → 21.30 | 13.02 → 11.44 |
| psp103 | 5.05 → 4.49 s | 46.01 → 36.55 | 23.47 → 21.24 |
| coupled_ltra | 3.98 → 4.39 s (noise) | 34.64 → 32.92 | 18.18 → 16.18 |
| txl | 1.75 → 1.61 s | 8.78 → 7.71 | 8.78 → 7.71 |

Bench hash and `.text` SHA-256 identical for all six models (`hashes.py`), so
cycles per `evalQ` are unchanged by construction.

## What the profile shows now

* **The mask check was the sema hot spot.** Zig 0.16 evaluates
  `S.Of(m)` at every call site whose return type names it (`Join(@TypeOf(b))`
  on every `add`/`mul`/`sub`/`div`, `zOf` on every `zTo`), so a comptime loop
  inside `Of` is paid per operation, not per distinct mask. A micro-benchmark
  of 2,000 chained ops: `mul` 7.35 → 0.63 Gi per 1,000, `zTo` 7.17 → 0.47.
  Any host family (ARPice's `eval.zig` `Of` calls `lanesOf`, a loop over its
  lane table) pays the same; ARPice should precompute it the same way.
* **psp103's critical path is now the setup object** (21.2 Gi), not eval
  (≈13 Gi). Setup LLVM time is spread over InstCombine, greedy RA, global
  splitting and SROA on one 10,000-line function; `setup` runs once per card,
  so splitting it into separately compiled chunks would cost nothing at run
  time and is the next lever. It is an emission change in
  `codegen/setup.zig`, left for after the runtime agent's work there.
* **Testbench builds** are the compiler's fixed cost: an empty Debug `main`
  is ~1.7 Gi warm, a fixture testbench ~2.2 Gi. Batching amortises it;
  `simple_panic` + `allow_stack_tracing = false` also cut the std work
  (8.71 → 6.90 Gi unstripped) but overlap with stripping and change what a
  panic prints, so they were not pursued.

## Reproduction

Scripts are in the session scratch (`b2/`): `meas.py` (end-to-end with
per-process Gi), `gi.py`/`tr.py` (one logged zig invocation, fresh cache,
`--time-report`), `micro.py` (sema cost per emitted construct), `hashes.py`,
`tbs.py` (testbench builds and transcript hashes), the same as the
2026-09-30 study's `codegen-levers-2026-09-30/` with paths relocated.
