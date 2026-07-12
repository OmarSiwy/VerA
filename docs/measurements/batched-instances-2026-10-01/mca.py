#!/usr/bin/env python3
"""mca.py ASMDIR...: llvm-mca throughput of evalScalar and evalBatch (each
function body taken as one straight-line block, every branch arm counted),
per-instance cycles = evalBatch / W, against evalScalar (whose cost includes
one output scatter, as evalBatch's does W)."""
import os, re, subprocess, sys
MCA = '/nix/store/wfjvqf9zlh05w0admf7x1mz0jn4bfy21-llvm-21.1.8/bin/llvm-mca'
MCPU = {'x86_64_v3': 'alderlake', 'x86_64': 'x86-64', 'x86_64_v4': 'skylake-avx512', 'znver4': 'znver4',
        'sapphirerapids': 'sapphirerapids', 'neoverse_n1': 'neoverse-n1', 'apple_m1': 'apple-m1', 'neoverse_v1': 'neoverse-v1'}
def body(lines, name):
    start = next(i for i, l in enumerate(lines) if l.startswith('".Lbatch_host.Api(device).%s":' % name))
    out = []
    for l in lines[start + 1:]:
        if l.startswith('.Lfunc_end') or l.startswith('.Ltmp') and 'func_end' in l: break
        s = l.strip()
        if not s or s.startswith(('.cfi', '.p2align', '#', '//', '.loc', '.file', '.size', '.type')): continue
        if s.endswith(':'): continue  # labels: one straight line
        if s.startswith('.'): continue
        out.append(s)
    return out
def mca(asm, triple, cpu):
    extra = ['-x86-asm-syntax=intel'] if triple.startswith('x86') else []
    p = subprocess.run([MCA, '-mtriple=' + triple, '-mcpu=' + cpu, '-iterations=20', '-skip-unsupported-instructions=parse-failure'] + extra, input='\n'.join(asm) + '\n', capture_output=True, text=True)
    m = re.search(r'Total Cycles:\s+(\d+)', p.stdout)
    if not m: return None, p.stderr[-300:]
    return int(m.group(1)) / 20.0, len(asm)
for d in sys.argv[1:]:
    name = os.path.basename(d.rstrip('/'))
    model, cpu, w = re.match(r'(\w+)\.(\w+)\.w(\d+)', name).groups()
    w = int(w)
    triple = 'aarch64-linux-gnu' if cpu in ('neoverse_n1', 'apple_m1', 'neoverse_v1') else 'x86_64-linux-gnu'
    lines = open(os.path.join(d, 'b.s')).read().split('\n')
    s, sn = mca(body(lines, 'evalScalar'), triple, MCPU[cpu])
    b, bn = mca(body(lines, 'evalBatch'), triple, MCPU[cpu])
    if s is None or b is None:
        print(name, 'mca failed', sn, bn); continue
    print(f"{model:8s} {cpu:15s} W={w}: scalar {s:8.1f} cy ({sn} instr), batch {b:9.1f} cy ({bn} instr) -> {b / w:8.1f} cy/instance, ratio {s / (b / w):.2f}")
