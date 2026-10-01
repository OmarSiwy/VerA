#!/usr/bin/env python3
"""Lever 7: cost of VerA's preflight `zig build-obj -fno-emit-bin` (src/main.zig typeCheck).
usage: pf.py ROUNDS model...  -> per model: fresh-cache and warm-cache wall + Ginstr medians."""
import json, os, shutil, statistics, subprocess, sys, tempfile, time
import pc
HERE = os.path.dirname(os.path.abspath(__file__))
C = "/home/omare/Documents/Projects/Zig/VerA/.claude/worktrees/agent-ab2014c0641d336f0/tools/contract.zig"
rounds, models = int(sys.argv[1]), sys.argv[2:]
def run(model, cache):
    ctr = pc.Counter(); ctr.start(); t = time.perf_counter()
    r = subprocess.run(["zig", "build-obj", "-fno-emit-bin", "--dep", "contract",
                        f"-Mroot={HERE}/.zig-cache/vera-check/{model}.device.zig", f"-Mcontract={C}", "--cache-dir", cache],
                       capture_output=True)
    assert r.returncode == 0, r.stderr[-2000:]
    return time.perf_counter() - t, ctr.read() / 1e9
seed = tempfile.mkdtemp(dir=os.path.join(HERE, "cache")); run("resistor", seed)  # std ZIR warm, like cwd/.zig-cache
res = {m: {"fresh": [], "warm": []} for m in models}
for _ in range(rounds):
    for m in models:
        d = tempfile.mkdtemp(dir=os.path.join(HERE, "cache")); res[m]["fresh"].append(run(m, d)); shutil.rmtree(d)
        d = tempfile.mkdtemp(dir=os.path.join(HERE, "cache")); shutil.rmtree(d); shutil.copytree(seed, d)
        res[m]["warm"].append(run(m, d)); shutil.rmtree(d)
for m in models:
    f = res[m]["fresh"]; w = res[m]["warm"]
    print(json.dumps({"model": m, "fresh_wall": round(statistics.median(x[0] for x in f), 3), "fresh_Gi": round(statistics.median(x[1] for x in f), 2),
                      "warm_wall": round(statistics.median(x[0] for x in w), 3), "warm_Gi": round(statistics.median(x[1] for x in w), 2)}))
shutil.rmtree(seed)
