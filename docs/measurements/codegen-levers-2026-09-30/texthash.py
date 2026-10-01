#!/usr/bin/env python3
"""texthash.py so/*.so : sha256 (12 hex) of each .so's .text section, grouped by model."""
import hashlib, os, subprocess, sys, tempfile
for f in sorted(sys.argv[1:]):
    t = tempfile.mktemp()
    subprocess.run(["objcopy", "-O", "binary", "--only-section=.text", f, t], check=True)
    d = open(t, "rb").read(); os.unlink(t)
    print(f"{hashlib.sha256(d).hexdigest()[:12]} {len(d):8d} {os.path.basename(f)}")
