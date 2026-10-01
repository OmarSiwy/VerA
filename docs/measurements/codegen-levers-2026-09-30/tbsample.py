#!/usr/bin/env python3
"""Suite share: for each sampled fixture, time `vera --emit-exe` (zig portion logged by
the zbin/zig wrapper) and the testbench run. usage: tbsample.py LIST OUT.jsonl [extra vera flags]"""
import json, os, subprocess, sys, time, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
W = "/home/omare/Documents/Projects/Zig/VerA/.claude/worktrees/agent-ab2014c0641d336f0"
VERA = os.path.join(HERE, "vera.base")
lst, out, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(out, "a") as fo:
    for path in open(lst).read().split():
        log = tempfile.mktemp(dir=os.path.join(HERE, "cache"))
        work = tempfile.mkdtemp(dir=os.path.join(HERE, "cache"))
        env = dict(os.environ, ZLOG=log)
        t = time.perf_counter()
        b = subprocess.run([VERA, "--emit-exe", "--contract", f"{W}/tools/contract.zig", "--zig", f"{HERE}/zbin/zig", "--work-dir", work,
                            "-I", f"{W}/tests/fixtures", "-I", os.path.dirname(f"{W}/{path}"), *extra, f"{W}/{path}"],
                           capture_output=True, text=True, env=env)
        tb = time.perf_counter() - t
        z = [json.loads(l) for l in open(log)] if os.path.exists(log) else []
        rec = {"fixture": path, "flags": extra, "emit_exe_wall": tb, "rc": b.returncode,
               "zig": [{k: x[k] for k in ("sub", "noemit", "wall", "cpu", "gi")} for x in z]}
        if b.returncode == 0 and b.stdout.strip():
            t = time.perf_counter()
            r = subprocess.run([b.stdout.strip()], capture_output=True, text=True, cwd=work)
            rec["run_wall"] = time.perf_counter() - t
            rec["ok1"] = r.stdout.count("ok=1"); rec["ok0"] = r.stdout.count("ok=0")
        fo.write(json.dumps(rec) + "\n"); fo.flush()
        subprocess.run(["rm", "-rf", work, log])
        print(path, round(tb, 2), [(x["sub"], round(x["wall"], 2)) for x in z], rec.get("run_wall"), flush=True)
