#!/usr/bin/env python3
"""Interleaved A/B build matrix. usage: run.py OUT.jsonl ROUNDS label:tree:host[:flag,flag...] ...
Each round builds every variant once (fresh cache); round 0 keeps so/<label>.so.
Then prints median sema/llvm/wall per label."""
import json, os, statistics, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
out, rounds, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
if specs and specs[0].startswith("@"): specs = open(specs[0][1:]).read().split()
vs = []
for s in specs:
    p = s.split(":")
    vs.append((p[0], p[1], p[2], [f for f in (p[3].split(",") if len(p) > 3 and p[3] else [])]))
with open(out, "a") as f:
    for r in range(rounds):
        for label, tree, host, flags in vs:
            cmd = [sys.executable, os.path.join(HERE, "zb.py"), tree, host, label, "--reps", "1"]
            if r == 0: cmd += ["--so", os.path.join(HERE, "so", label + ".so")]
            if flags: cmd += ["--", *flags]
            p = subprocess.run(cmd, capture_output=True, text=True, cwd=HERE)
            line = p.stdout.splitlines()[0] if p.stdout else json.dumps({"label": label, "fail": p.stderr[-2000:]})
            j = json.loads(line); j["round"] = r; j["load1"] = os.getloadavg()[0]
            f.write(json.dumps(j) + "\n"); f.flush()
            print(label, r, "FAIL" if "fail" in j else f'Gi={j["ginstr"]:.2f} cpu={j["cpu_s"]:.2f} wall={j["wall_s"]:.2f} sema={j["sema_s"]:.2f} llvm={j["llvm_s"]:.2f}', flush=True)
rows = [json.loads(l) for l in open(out)]
for label, *_ in vs:
    xs = [x for x in rows if x.get("label") == label and "wall_s" in x]
    if not xs: continue
    m = lambda k: statistics.median(x[k] for x in xs)
    print(f"{label:28s} n={len(xs)} Ginstr={m('ginstr'):.2f} cpu={m('cpu_s'):.3f} wall={m('wall_s'):.3f} sema={m('sema_s'):.3f} llvm={m('llvm_s'):.3f} files={m('files_s'):.3f} text={xs[0].get('text_bytes')}")
