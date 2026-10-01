#!/usr/bin/env python3
"""Run one `zig build-* --listen=- --time-report` update; print a JSON summary.
usage: zt.py <zig argv... (no --listen)>   env ZT_DECLS=N  top decls to keep"""
import json, os, struct, subprocess, sys, time

argv = sys.argv[1:]
argv = argv[:2] + ["--listen=-", "--time-report"] + argv[2:]
import pc
_ctr = pc.Counter()
_ctr.start()
t0 = time.perf_counter()
p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
p.stdin.write(struct.pack("<II", 1, 0)); p.stdin.flush()  # update
out = {"ok": False}
def rd(n):
    b = b""
    while len(b) < n:
        c = p.stdout.read(n - len(b))
        if not c: raise SystemExit("compiler gone")
        b += c
    return b
while True:
    tag, ln = struct.unpack("<II", rd(8)); body = rd(ln)
    if tag == 11:  # time_report
        open(os.environ.get("ZT_DUMP", "/dev/null"), "wb").write(body)
        st = struct.unpack("<4I9Q", body[:88])
        names = ["n_reachable_files","n_imported_files","n_generic_instances","n_inline_calls",
                 "cpu_ns_parse","cpu_ns_astgen","cpu_ns_sema","cpu_ns_codegen","cpu_ns_link",
                 "real_ns_files","real_ns_decls","real_ns_llvm_emit","real_ns_link_flush"]
        out["stats"] = dict(zip(names, st))
        lp, fl, dl, _ = struct.unpack("<4I", body[88:104])
        off = 104
        passes = body[off:off+lp].decode(errors="replace"); off += lp
        files = []
        for _ in range(fl):
            e = body.index(b"\0", off); files.append(body[off:e].decode()); off = e + 1
        decls = []
        for _ in range(dl):
            e = body.index(b"\0", off); nm = body[off:e].decode(errors="replace"); off = e + 1
            fi, cnt, s, c, l = struct.unpack("<IIQQQ", body[off:off+32]); off += 32
            decls.append((s + c, nm, files[fi] if fi < len(files) else "?", s, c))
        decls.sort(reverse=True)
        k = int(os.environ.get("ZT_DECLS", "12"))
        out["decls"] = [{"name": n, "file": os.path.basename(f), "sema_ns": s, "codegen_ns": c} for _, n, f, s, c in decls[:k]]
        import re
        pl = []; sec = ""; lines = passes.splitlines()
        for i, line in enumerate(lines):
            if line.startswith("===-") and i + 1 < len(lines) and not lines[i+1].startswith("===-"):
                sec = lines[i+1].strip()
            nums = re.findall(r"([\d.]+) \(\s*[\d.]+%\)", line)
            if len(nums) == 4:
                name = line[line.rindex(")") + 1:].strip()
                if name != "Total": pl.append((float(nums[3]), name))
        pl.sort(reverse=True)
        out["llvm_passes"] = [{"name": n, "wall_s": w} for w, n in pl[:15]]
    elif tag == 1:  # error_bundle
        el, sl = struct.unpack("<II", body[:8])
        out["errors"] = el > 0 and len(body) > 8 + 4 * el and b"\0" in body
        out["error_text"] = body[8 + 4 * el:][:4000].decode(errors="replace") if el else ""
        break
    elif tag == 2:
        out["ok"] = True
        out["digest"] = body[1:17].hex()
p.stdin.write(struct.pack("<II", 0, 0)); p.stdin.close()
_, _st, ru = os.wait4(p.pid, 0); p.returncode = _st
out["cpu_s"] = ru.ru_utime + ru.ru_stime
out["ginstr"] = _ctr.read() / 1e9
out["wall_s"] = time.perf_counter() - t0
s = out.get("stats", {})
if s:
    out["sema_s"] = s["real_ns_decls"] / 1e9
    out["llvm_s"] = s["real_ns_llvm_emit"] / 1e9
    out["files_s"] = s["real_ns_files"] / 1e9
    out["link_s"] = s["real_ns_link_flush"] / 1e9
print(json.dumps(out))
