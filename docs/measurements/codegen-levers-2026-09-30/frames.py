#!/usr/bin/env python3
"""frames.py LIB.so [N]: largest stack frames (first `sub $imm,%rsp` per function), from objdump."""
import re, subprocess, sys
out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-C", sys.argv[1]], capture_output=True, text=True).stdout
fn, fr = None, {}
for line in out.splitlines():
    m = re.match(r"^[0-9a-f]+ <(.*)>:$", line)
    if m: fn = m.group(1); continue
    m = re.search(r"\bsub\s+\$0x([0-9a-f]+),%rsp", line)
    if m and fn and fn not in fr: fr[fn] = int(m.group(1), 16)
for f, s in sorted(fr.items(), key=lambda x: -x[1])[: int(sys.argv[2]) if len(sys.argv) > 2 else 6]:
    print(f"{s:9d}  {f[:110]}")
