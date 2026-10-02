#!/bin/bash
# runall.sh OUTDIR RESULT: bench every built .so, pinned to P-core 4.
cd "$(dirname "$0")"
uptime
for f in "$1"/*/libb.so; do taskset -c 4 python3 bench.py "$f" 2>&1 | grep -v '^k='; done | tee "$2"
