#!/usr/bin/env python3
"""Fresh-cache `zig build-lib` of an emitted device tree, timed with --time-report.
usage: zb.py TREE HOST LABEL [--reps N] [--opt ReleaseFast] [--so OUT.so] [-- extra zig flags]
Prints one JSON line per rep and a summary line with medians."""
import json, os, shutil, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = "/home/omare/Documents/Projects/Zig/VerA/.claude/worktrees/agent-ab2014c0641d336f0/tools/contract.zig"
a = sys.argv[1:]
extra = []
if "--" in a:
    i = a.index("--"); extra = a[i+1:]; a = a[:i]
tree, host, label = a[0], a[1], a[2]
reps, opt, so_out, root = 3, "ReleaseFast", None, "shim.zig"
k = 3
while k < len(a):
    if a[k] == "--reps": reps = int(a[k+1]); k += 2
    elif a[k] == "--opt": opt = a[k+1]; k += 2
    elif a[k] == "--so": so_out = a[k+1]; k += 2
    elif a[k] == "--root": root = a[k+1]; k += 2
    else: raise SystemExit("bad arg " + a[k])
tree = os.path.abspath(tree)
name = os.path.basename(tree.rstrip("/")).replace("-", "_")
rows = []
for r in range(reps):
    cache = tempfile.mkdtemp(prefix="zb-", dir=os.path.join(HERE, "cache"))
    if os.environ.get("ZB_SEED"):
        shutil.rmtree(cache); shutil.copytree(os.environ["ZB_SEED"], cache, symlinks=True)
    digital = "@import(\"sim\")" in open(f"{tree}/device.zig").read()
    W = "/home/omare/Documents/Projects/Zig/VerA/.claude/worktrees/agent-ab2014c0641d336f0"
    ds = ["--dep", "sim", "--dep", "diag", "--dep", "frontend", "--dep", "kernels"] if digital else []
    argv = ["zig", "build-lib", "-dynamic", f"-O{opt}", "--name", name, "--cache-dir", cache, "-fllvm", *extra,
            "--dep", "contract", "--dep", "dyn", *ds, "--dep", "device", f"-Mroot={tree}/{root}",
            "--dep", "contract", "--dep", "dyn", *ds, f"-Mdevice={tree}/device.zig",
            f"-Mcontract={CONTRACT}", "--dep", "contract", f"-Mdyn={os.path.abspath(host)}"]
    if digital:
        argv += ["--dep", "contract", "--dep", "diag", "--dep", "frontend", "--dep", "kernels", f"-Msim={os.environ.get('SIMROOT', W + '/src/sim/root.zig')}",
                 f"-Mdiag={W}/lib/diag.zig", "--dep", "diag", f"-Mfrontend={W}/lib/frontend/root.zig", f"-Mkernels={W}/lib/backend/kernels.zig"]
    p = subprocess.run([sys.executable, os.path.join(HERE, "zt.py"), *argv], capture_output=True, text=True)
    try:
        j = json.loads(p.stdout)
    except Exception:
        print(p.stdout[-3000:], p.stderr[-3000:], file=sys.stderr); raise
    if not j.get("ok"):
        print(json.dumps({"label": label, "fail": j.get("error_text", "")[:3000]}))
        shutil.rmtree(cache, ignore_errors=True); sys.exit(1)
    so = os.path.join(cache, "o", j["digest"], f"lib{name}.so")
    if so_out and r == 0: shutil.copy(so, so_out)
    j["so_bytes"] = os.path.getsize(so)
    try:
        sz = subprocess.run(["size", "-A", so], capture_output=True, text=True).stdout
        j["text_bytes"] = next(int(l.split()[1]) for l in sz.splitlines() if l.startswith(".text"))
    except Exception: pass
    j["label"] = label
    j.pop("llvm_passes", None) if r else None
    rows.append(j)
    print(json.dumps(j), flush=True)
    shutil.rmtree(cache, ignore_errors=True)
med = lambda key: statistics.median(x[key] for x in rows)
summ = {"label": label, "summary": True, "reps": reps, "wall_s": med("wall_s"), "sema_s": med("sema_s"),
        "llvm_s": med("llvm_s"), "files_s": med("files_s"), "text_bytes": rows[0].get("text_bytes"),
        "so_bytes": rows[0]["so_bytes"], "generic_instances": rows[0]["stats"]["n_generic_instances"],
        "inline_calls": rows[0]["stats"]["n_inline_calls"], "load": os.getloadavg()[0]}
print(json.dumps(summ), flush=True)
