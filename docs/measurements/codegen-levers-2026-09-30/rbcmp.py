#!/usr/bin/env python3
"""Interleaved runtime compare, pinned to P-core CPU 4:
rbcmp.py ROUNDS ENTRY a.so b.so ...  (first .so is the baseline)
Reports per .so: output hash (bit-exact check vs first), min cycles/eval, median
instructions/eval, min ns/eval, and the cycle delta vs the first."""
import json, os, statistics, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
rounds, entry, sos = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
C = {s: [] for s in sos}; N = {s: [] for s in sos}; I = {}; H = {}
for r in range(rounds):
    for s in sos:
        out = subprocess.run(["taskset", "-c", os.environ.get("CPU", "4"), sys.executable, os.path.join(HERE, "rb.py"), s, entry, "3"],
                             capture_output=True, text=True)
        j = json.loads(out.stdout)
        C[s].append(j["cyc_min"]); N[s].append(j["ns_min"]); I[s] = j["ins"]; H[s] = j["hash"]
b = min(C[sos[0]])
for s in sos:
    m = min(C[s])
    print(json.dumps({"so": os.path.basename(s), "entry": entry, "hash": H[s], "bit_exact_vs_first": H[s] == H[sos[0]],
                      "cyc_min": m, "ins": I[s], "ns_min": min(N[s]), "delta_cyc_pct": round(100 * (m - b) / b, 2)}), flush=True)
