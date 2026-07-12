#!/usr/bin/env python3
"""bench.py LIB.so...: per-instance cycles of scalar evalQ vs batched evalQ
(W points per call), min over 5 reps, pinned by the caller (taskset)."""
import ctypes, json, sys, time
sys.path.insert(0, "/home/omare/Documents/Projects/Zig/VerA/.claude/worktrees/agent-a6fd63bb4c0f3a019/docs/measurements/device-runtime-2026-10-01")
import pc
for so in sys.argv[1:]:
    lib = ctypes.CDLL(so)
    lib.bench_check.restype = ctypes.c_uint64
    lib.bench_w.restype = ctypes.c_uint32
    lib.bench_setup()
    bad = lib.bench_check()
    w = lib.bench_w()
    out = {"so": so.split("/")[-2], "W": w, "check_mismatches": bad}
    for name in ("bench_scalar", "bench_batch"):
        f = getattr(lib, name); f.argtypes = [ctypes.c_uint64]
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
        out[name.split("_")[1]] = round(min(cy), 1)
        out[name.split("_")[1] + "_ins"] = round(sorted(ins)[2], 1)
    out["speedup"] = round(out["scalar"] / out["batch"], 3)
    print(json.dumps(out), flush=True)
