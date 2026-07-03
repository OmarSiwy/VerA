#!/usr/bin/env python3
"""Runtime bench of a bench-host .so: rb.py LIB.so [entry] [reps]
entry: bench_loop (evalQ dual, default) | bench_loop_eval | bench_loop_q
Prints JSON: nu, hash (hex), ns/eval min and median over reps."""
import ctypes, json, statistics, sys, time
import pc
lib = ctypes.CDLL(sys.argv[1])
entry = sys.argv[2] if len(sys.argv) > 2 else "bench_loop"
reps = int(sys.argv[3]) if len(sys.argv) > 3 else 7
lib.bench_hash.restype = ctypes.c_uint64
lib.bench_nu.restype = ctypes.c_uint32
lib.bench_setup()
h = lib.bench_hash()
f = getattr(lib, entry); f.argtypes = [ctypes.c_uint64]
# calibrate to ~0.2 s per rep
n = 64
while True:
    t = time.perf_counter_ns(); f(n); dt = time.perf_counter_ns() - t
    if dt > 1e8 or n > 1 << 34: break
    n *= 4
n = max(64, int(n * 2e8 / max(dt, 1)))
s = []; cy = []; ins = []
cc = pc.Counter(0, inherit=False); ci = pc.Counter(1, inherit=False)
for _ in range(reps):
    cc.start(); ci.start()
    t = time.perf_counter_ns(); f(n); s.append((time.perf_counter_ns() - t) / n)
    cy.append(cc.read() / n); ins.append(ci.read() / n)
print(json.dumps({"so": sys.argv[1], "entry": entry, "nu": lib.bench_nu(), "hash": f"{h:016x}",
                  "ns_min": round(min(s), 3), "cyc_min": round(min(cy), 2), "cyc_med": round(statistics.median(cy), 2), "ins": round(statistics.median(ins), 2), "ns_med": round(statistics.median(s), 3), "iters": n}))
