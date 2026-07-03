#!/usr/bin/env python3
"""Logging zig wrapper: one JSON line per invocation into $ZLOG."""
import json, os, sys, time, subprocess
sys.path.insert(0, "/tmp/claude-1000/-home-omare-Documents-Projects-Zig-VerA/8e3fb2cc-fae4-4ce7-b84a-3ddbec9744d1/scratchpad/cl")
import pc
REAL = "/nix/store/n1hqsn4a4yfmipzyk2byavvx4ccx6ccr-zig-0.16.0/bin/zig"
c = pc.Counter(); c.start(); t = time.perf_counter()
p = subprocess.Popen([REAL] + sys.argv[1:])
_, st, ru = os.wait4(p.pid, 0)
rec = {"sub": sys.argv[1] if len(sys.argv) > 1 else "", "opt": next((a for a in sys.argv if a.startswith("-O")), ""),
       "noemit": "-fno-emit-bin" in sys.argv, "wall": time.perf_counter() - t, "cpu": ru.ru_utime + ru.ru_stime, "gi": c.read() / 1e9,
       "llvm": "-fllvm" in sys.argv, "selfhosted": "-fno-llvm" in sys.argv, "listen": any(a.startswith("--listen") for a in sys.argv),
       "t_end": time.time()}
with open(os.environ.get("ZLOG", "/dev/null"), "a") as f: f.write(json.dumps(rec) + "\n")
sys.exit(os.waitstatus_to_exitcode(st))
