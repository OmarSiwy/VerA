#!/usr/bin/env python3
"""Split build: each part is a separate `zig build-obj` (run in PARALLEL), then one link.
usage: zsplit.py TREE LABEL OUT.so part... ; part = host.zig:Opt[:flag,flag]
Prints JSON: wall (parallel objs + link), per-part sema/llvm/cpu, link time."""
import json, os, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = "/home/omare/Documents/Projects/Zig/VerA/.claude/worktrees/agent-ab2014c0641d336f0/tools/contract.zig"
tree, label, so_out, parts = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
name = os.path.basename(tree).replace("-", "_")
tmp = tempfile.mkdtemp(prefix="zs-", dir=os.path.join(HERE, "cache"))
def obj(i_part):
    i, spec = i_part
    p = spec.split(":"); host, opt = p[0], p[1]; flags = p[2].split(",") if len(p) > 2 and p[2] else []
    cache = os.path.join(tmp, f"c{i}")
    argv = ["zig", "build-obj", f"-O{opt}", "--name", f"{name}_p{i}", "--cache-dir", cache, "-fllvm", "-fPIC", *flags,
            "--dep", "contract", "--dep", "dyn", "--dep", "device", f"-Mroot={tree}/shim.zig",
            "--dep", "contract", "--dep", "dyn", f"-Mdevice={tree}/device.zig",
            f"-Mcontract={CONTRACT}", "--dep", "contract", f"-Mdyn={os.path.join(HERE, host)}"]
    r = subprocess.run([sys.executable, os.path.join(HERE, "zt.py"), *argv], capture_output=True, text=True)
    j = json.loads(r.stdout)
    if not j.get("ok"): raise SystemExit(f"part {spec} failed: {j.get('error_text','')[:2000]}")
    j["obj"] = os.path.join(cache, "o", j["digest"], f"{name}_p{i}.o")
    j["spec"] = spec
    return j
t0 = time.perf_counter()
with ThreadPoolExecutor(len(parts)) as ex:
    js = list(ex.map(obj, enumerate(parts)))
t1 = time.perf_counter()
link_opt = parts[0].split(":")[1]
lcache = os.path.join(tmp, "link")
largv = ["zig", "build-lib", "-dynamic", f"-O{link_opt}", "--name", name, "--cache-dir", lcache, *[j["obj"] for j in js]]
lr = subprocess.run([sys.executable, os.path.join(HERE, "zt.py"), *largv], capture_output=True, text=True)
lj = json.loads(lr.stdout)
t2 = time.perf_counter()
if not lj.get("ok"): raise SystemExit("link failed: " + lj.get("error_text", "")[:2000])
so = os.path.join(lcache, "o", lj["digest"], f"lib{name}.so")
shutil.copy(so, so_out)
sz = subprocess.run(["size", "-A", so], capture_output=True, text=True).stdout
text = next(int(l.split()[1]) for l in sz.splitlines() if l.startswith(".text"))
res = {"label": label, "wall_s": t2 - t0, "objs_wall_s": t1 - t0, "link_wall_s": t2 - t1,
       "cpu_s": sum(j["cpu_s"] for j in js) + lj["cpu_s"], "ginstr": sum(j["ginstr"] for j in js) + lj["ginstr"],
       "sema_s": max(j["sema_s"] for j in js), "llvm_s": max(j["llvm_s"] for j in js), "files_s": max(j["files_s"] for j in js),
       "parts": [{k: j[k] for k in ("spec", "wall_s", "cpu_s", "ginstr", "sema_s", "llvm_s", "files_s")} for j in js],
       "text_bytes": text, "ok": True}
print(json.dumps(res))
shutil.rmtree(tmp, ignore_errors=True)
