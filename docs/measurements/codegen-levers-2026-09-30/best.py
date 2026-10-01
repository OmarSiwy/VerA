#!/usr/bin/env python3
"""best.py FILE.jsonl... : per label, median Ginstr and the least-disturbed (min-wall) sample's phases."""
import json, statistics, sys
rows = [json.loads(l) for f in sys.argv[1:] for l in open(f)]
by = {}
for r in rows:
    if "wall_s" in r: by.setdefault(r["label"], []).append(r)
for k in sorted(by):
    xs = by[k]; b = min(xs, key=lambda r: r["wall_s"])
    gi = statistics.median(x["ginstr"] for x in xs if "ginstr" in x) if any("ginstr" in x for x in xs) else float("nan")
    print(f"{k:26s} n={len(xs)} Gi={gi:7.2f} minwall={b['wall_s']:6.2f} sema={b['sema_s']:5.2f} llvm={b['llvm_s']:6.2f} text={b.get('text_bytes')}")
