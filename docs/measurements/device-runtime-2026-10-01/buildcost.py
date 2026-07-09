#!/usr/bin/env python3
"""Fresh-cache ReleaseFast stripped `zig build-lib` of an emit.sh tree with the
dyn_rt host: buildcost.py TREE... -> retired user instructions (Gi, whole
process tree) and wall seconds per tree."""
import os, shutil, subprocess, sys, tempfile, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pc
W = os.path.abspath(os.path.join(HERE, "../../.."))
for tree in sys.argv[1:]:
    cache = tempfile.mkdtemp(prefix="bc-")
    out = tempfile.mkdtemp(prefix="bo-")
    argv = ["zig", "build-lib", "-dynamic", "-OReleaseFast", "-fstrip", "-j4", "--name", "dev", "--cache-dir", cache,
            "--dep", "contract", "--dep", "dyn", "--dep", "device", f"-Mroot={tree}/shim.zig",
            "--dep", "contract", f"-Mdevice={tree}/device.zig", f"-Mcontract={W}/tools/contract.zig",
            "--dep", "contract", f"-Mdyn={HERE}/dyn_rt.zig"]
    c = pc.Counter(); c.start(); t = time.perf_counter()
    p = subprocess.run(argv, cwd=out, capture_output=True, text=True)
    wall = time.perf_counter() - t; gi = c.read() / 1e9
    print(f"{tree} rc={p.returncode} Gi={gi:.2f} wall={wall:.2f}s {p.stderr[-300:] if p.returncode else ''}", flush=True)
    shutil.rmtree(cache, ignore_errors=True); shutil.rmtree(out, ignore_errors=True)
