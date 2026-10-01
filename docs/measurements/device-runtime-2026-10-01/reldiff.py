#!/usr/bin/env python3
"""reldiff.py A.so B.so: every output both hashes mix (64 bias points x evalQ,
eval, q; 1074 transient steps), compared value by value. Prints the count,
how many differ, the max relative difference |a-b|/max(|a|,|b|) over values
with max(|a|,|b|) > FLOOR, and the max absolute difference below it.
Relative to the Jacobian/residual scale, so FLOOR (default 1e-300) only
skips exact zeros; pass a larger one to ignore entries at roundoff level."""
import ctypes, math, sys
FLOOR = float(sys.argv[3]) if len(sys.argv) > 3 else 1e-300
def dump(so):
    lib = ctypes.CDLL(so)
    lib.bench_dump.restype = ctypes.c_size_t
    cap = 1 << 24
    buf = (ctypes.c_double * cap)()
    n = lib.bench_dump(buf, cap)
    return list(buf[:n])
a, b = dump(sys.argv[1]), dump(sys.argv[2])
assert len(a) == len(b), (len(a), len(b))
diff = 0; rmax = 0.0; at = None; amax = 0.0; nan = 0
for i, (x, y) in enumerate(zip(a, b)):
    if x == y or (math.isnan(x) and math.isnan(y)): continue
    diff += 1
    if math.isnan(x) or math.isnan(y) or math.isinf(x) or math.isinf(y):
        nan += 1; continue
    m = max(abs(x), abs(y))
    if m > FLOOR:
        r = abs(x - y) / m
        if r > rmax: rmax, at = r, (i, x, y)
    else:
        amax = max(amax, abs(x - y))
print(f"values {len(a)}, differ {diff}, nonfinite-mismatch {nan}, max rel diff {rmax:.3e} (ulps ~{rmax/2**-52:.1f}) at {at}, max abs diff below floor {amax:.3e}")
