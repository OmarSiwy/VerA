import ctypes, sys
for so in sys.argv[1:]:
    lib = ctypes.CDLL(so); lib.bench_setup()
    lib.bench_groups.restype = ctypes.c_uint64; lib.bench_w.restype = ctypes.c_uint32
    w = lib.bench_w(); r = lib.bench_groups()
    print(so.split('/')[-2], 'W', w, 'batched runs', r, 'for', 64 // w * w, 'points; fully coherent would be', 64 // w)
