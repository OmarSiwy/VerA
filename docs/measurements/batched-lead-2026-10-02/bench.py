#!/usr/bin/env python3
"""bench.py LIB.so...: per-instance cycles of scalar evalQ vs batched evalQ
(W points per call through the device's lead protocol), min over 5 reps,
pinned by the caller. Batches are W consecutive bias points of the host's
spread set (mixed regions); `coherent` repeats one point W times. Also: bit
mismatches against scalar (coherent and mixed) and device runs per batch."""
import ctypes, json, sys, time
sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__file__), "../device-runtime-2026-10-01"))
import pc
def timeit(f, w):
    f.argtypes = [ctypes.c_uint64]
    n = 64 * w
    while True:
        t = time.perf_counter_ns(); f(n); dt = time.perf_counter_ns() - t
        if dt > 5e7: break
        n *= 4
    n = max(64 * w, int(n * 1e8 / dt) // w * w)
    cc = pc.Counter(0, inherit=False); ci = pc.Counter(1, inherit=False)
    cy = []; ins = []
    for _ in range(5):
        cc.start(); ci.start(); f(n)
        cy.append(cc.read() / n); ins.append(ci.read() / n)
    return round(min(cy), 1), round(sorted(ins)[2], 1)
for so in sys.argv[1:]:
    lib = ctypes.CDLL(so)
    for f in ("bench_check", "bench_check_mixed", "bench_check_sims", "bench_groups"): getattr(lib, f).restype = ctypes.c_uint64
    lib.bench_w.restype = ctypes.c_uint32
    lib.bench_setup()
    w = lib.bench_w()
    out = {"so": so.split("/")[-2], "W": w, "bad_coherent": lib.bench_check(), "bad_mixed": lib.bench_check_mixed(), "bad_sims": lib.bench_check_sims(),
           "runs_per_batch": round(lib.bench_groups() / (64 // w), 2)}
    out["scalar"], out["scalar_ins"] = timeit(lib.bench_scalar, w)
    out["mixed"], out["mixed_ins"] = timeit(lib.bench_batch, w)
    out["coherent"], out["coherent_ins"] = timeit(lib.bench_coherent, w)
    out["region"], out["region_ins"] = timeit(lib.bench_sig_loop, w)
    out["x_mixed"] = round(out["scalar"] / out["mixed"], 3)
    out["x_coherent"] = round(out["scalar"] / out["coherent"], 3)
    print(json.dumps(out), flush=True)
