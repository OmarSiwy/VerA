#!/usr/bin/env python3
"""Interleaved split-build matrix. usage: runsplit.py OUT.jsonl ROUNDS SPECFILE
SPECFILE lines: label tree part [part...]   (part = host.zig:Opt[:flags])
Round 0 keeps so/<label>.so. Prints medians per label at the end."""
import json, os, statistics, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
out, rounds, spec = sys.argv[1], int(sys.argv[2]), sys.argv[3]
vs = [l.split() for l in open(spec) if l.strip()]
with open(out, "a") as f:
    for r in range(rounds):
        for label, tree, *parts in vs:
            p = subprocess.run([sys.executable, os.path.join(HERE, "zsplit.py"), tree, label, os.path.join(HERE, "so", label + ".so"), *parts],
                               capture_output=True, text=True, cwd=HERE)
            try: j = json.loads(p.stdout)
            except Exception: j = {"label": label, "fail": (p.stdout + p.stderr)[-1500:]}
            j["round"] = r; j["load1"] = os.getloadavg()[0]
            f.write(json.dumps(j) + "\n"); f.flush()
            print(label, r, "FAIL " + j["fail"][-300:] if "fail" in j else f'Gi={j["ginstr"]:.2f} wall={j["wall_s"]:.2f} objs={j["objs_wall_s"]:.2f} link={j["link_wall_s"]:.2f} sema={j["sema_s"]:.2f} llvm={j["llvm_s"]:.2f}', flush=True)
rows = [json.loads(l) for l in open(out)]
for label, *_ in vs:
    xs = [x for x in rows if x.get("label") == label and "wall_s" in x]
    if not xs: continue
    m = lambda k: statistics.median(x[k] for x in xs)
    print(f"{label:28s} n={len(xs)} Ginstr={m('ginstr'):.2f} wall={m('wall_s'):.3f} objs={m('objs_wall_s'):.3f} link={m('link_wall_s'):.3f} maxsema={m('sema_s'):.3f} maxllvm={m('llvm_s'):.3f} text={xs[0]['text_bytes']}")
