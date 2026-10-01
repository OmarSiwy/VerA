#!/usr/bin/env python3
"""Interleaved runtime compare of emit.sh trees, pinned to one P-core:
cmp.py ROUNDS MODELS ENTRIES BASE_DIR VARIANT_DIR...
MODELS/ENTRIES are comma lists (entries: evalQ,eval,q,update,tran).
Per model x entry: hash (bench_hash/bench_hash_tran; bit-exact vs BASE),
min cycles/call over rounds, median instructions/call, cycle delta vs BASE.
Appends JSON lines to $OUT (default /dev/null) and prints a table."""
import glob, json, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
E = {"evalQ": "bench_loop", "eval": "bench_loop_eval", "q": "bench_loop_q", "update": "bench_loop_update", "tran": "bench_loop_tran"}
rounds, models, entries, dirs = int(sys.argv[1]), sys.argv[2].split(","), sys.argv[3].split(","), sys.argv[4:]
out = open(os.environ.get("OUT", "/dev/null"), "a")
for m in models:
    sos = []
    for d in dirs:
        g = glob.glob(f"{d}/{m}/lib*.so")
        sos.append(g[0] if g else None)
    if not sos[0]: print(m, "missing base"); continue
    for e in entries:
        C = {}; I = {}; H = {}
        for r in range(rounds):
            for s in sos:
                if not s: continue
                p = subprocess.run(["taskset", "-c", os.environ.get("CPU", "4"), sys.executable, os.path.join(HERE, "rb.py"), s, E[e], "3"], capture_output=True, text=True)
                try: j = json.loads(p.stdout)
                except Exception: print(m, e, s, "ERR", p.stderr[-500:]); continue
                C.setdefault(s, []).append(j["cyc_min"]); I[s] = j["ins"]; H[s] = j["hash"] + "/" + j["hash_tran"]
        if sos[0] not in C: continue
        b = min(C[sos[0]])
        row = [f"{m:14s} {e:6s}"]
        for d, s in zip(dirs, sos):
            if s not in C: row.append(" " * 30); continue
            c = min(C[s]); ex = H[s] == H[sos[0]]
            row.append(f"{c:10.1f}cy {I[s]:10.1f}in {100*(c-b)/max(b,1e-9):+6.1f}% {'=' if ex else 'X'}")
            out.write(json.dumps({"model": m, "entry": e, "dir": d, "cyc_min": c, "ins": I[s], "hash": H[s], "bit_exact": ex, "delta_pct": round(100*(c-b)/max(b,1e-9), 2)}) + "\n")
        print(" | ".join(row), flush=True)
