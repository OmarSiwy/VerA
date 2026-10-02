#!/usr/bin/env python3
"""analyze.py DECK.sp DECK.csv LIB.so MODEL: divergence of batched instances
on a circuit's real bias. Flattens the deck's MOSFETs, reads every node
voltage at every accepted timepoint (espice csv), and per (card, W, L) group
and timepoint batches the group's instances W at a time through the device's
lead protocol: in netlist order (`naive`) and sorted by `contract.region`
(`grouped`). Reports device runs per batch (1.0 = no divergence)."""
import ctypes, csv, re, sys, collections
deck, csvf, so, model = sys.argv[1:5]
SCALE = {'f': 1e-15, 'p': 1e-12, 'n': 1e-9, 'u': 1e-6, 'm': 1e-3, 'k': 1e3, 'meg': 1e6, 'g': 1e9}
def num(s):
    m = re.match(r'^([-+]?[0-9.]+(?:e[-+]?\d+)?)(meg|[fpnumkg])?', s.lower())
    return float(m.group(1)) * (SCALE[m.group(2)] if m.group(2) else 1.0)
lines = []
for l in open(deck):
    l = l.rstrip('\n')
    if l.startswith('+') and lines: lines[-1] += ' ' + l[1:]
    else: lines.append(l)
models, subckts, top = {}, {}, []
cur = None
for l in lines:
    t = l.split()
    if not t or t[0].startswith('*'): continue
    k = t[0].lower()
    if k == '.model':
        name = t[1].lower()
        body = l[l.index('(') + 1:l.rindex(')')] if '(' in l else ' '.join(t[3:])
        typ = 'n' if 'nmos' in l.lower() else 'p'
        ps = dict((a.lower(), b) for a, b in re.findall(r'(\w+)\s*=\s*([^\s)]+)', body))
        models[name] = (typ, ps)
    elif k == '.subckt': cur = (t[1].lower(), [x.lower() for x in t[2:]]); subckts[cur[0]] = (cur[1], [])
    elif k == '.ends': cur = None
    elif cur: subckts[cur[0]][1].append(t)
    else: top.append(t)
devs = []  # (model, params, [d,g,s,b] node names)
def flatten(stmts, prefix, nodemap):
    for t in stmts:
        k = t[0].lower()
        if k.startswith('m'):
            nodes = [nodemap.get(n.lower(), (prefix + n.lower()) if prefix else n.lower()) for n in t[1:5]]
            ps = dict((a.lower(), num(b)) for a, b in (x.split('=') for x in t[6:] if '=' in x))
            devs.append((t[5].lower(), ps, nodes))
        elif k.startswith('x'):
            sub = t[-1].lower(); pins, body = subckts[sub]
            nm = dict(zip(pins, [nodemap.get(n.lower(), n.lower()) for n in t[1:-1]]))
            flatten(body, (prefix + k + '.'), nm)
flatten(top, '', {})
rows = list(csv.reader(open(csvf)))
head = rows[0]; data = [[float(x) for x in r] for r in rows[1:]]
col = {h[2:-1].lower(): i for i, h in enumerate(head) if h.startswith('v(')}
def V(r, n): return 0.0 if n in ('0', 'gnd') else r[col[n]]
if model == 'psp103':  # D G S B NOI GP SI DI BP BI BS BD
    def xvec(d, g, s, b): return [d, g, s, b, 0.0, g, s, d, b, b, b, b]
    nu = 12
else:  # bsim4va: d g s b di si gi gm bi sbulk dbulk + 7 flows
    def xvec(d, g, s, b): return [d, g, s, b, d, s, g, g, b, b, b] + [0.0] * 7
    nu = 18
lib = ctypes.CDLL(so)
lib.bench_w.restype = ctypes.c_uint32
lib.bench_signatures.restype = ctypes.c_uint64
lib.bench_set_runs.restype = ctypes.c_uint64
lib.bench_set_check.restype = ctypes.c_uint64
lib.bench_coherent_batches.restype = ctypes.c_uint64
lib.bench_param.restype = ctypes.c_bool
lib.bench_param.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_double]
lib.bench_set_points.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
lib.bench_set_runs.argtypes = [ctypes.c_bool]
W = lib.bench_w()
groups = collections.defaultdict(list)
for i, (m, ps, nodes) in enumerate(devs):
    groups[(m, tuple(sorted(ps.items())))].append(i)
tot = collections.Counter(); sigs_total = 0; bad = 0
for (m, ps), idx in groups.items():
    lib.bench_setup()
    typ, card = models[m]
    for k, v in card.items():
        try: lib.bench_param(k.encode(), len(k), num(v))
        except Exception: pass
    lib.bench_param(b'type', 4, 1.0 if typ == 'n' else -1.0)
    for k, v in ps: lib.bench_param(k.encode(), len(k), v)
    lib.bench_resetup()
    n = len(idx) // W * W
    if n == 0: continue
    for r in data[::2]:
        pts = []
        for i in idx[:n]:
            d, g, s, b = (V(r, x) for x in devs[i][2])
            pts += xvec(d, g, s, b)
        arr = (ctypes.c_double * len(pts))(*pts)
        lib.bench_set_points(arr, n)
        tot['batches'] += n // W
        tot['naive'] += lib.bench_set_runs(False); tot['coh_naive'] += lib.bench_coherent_batches()
        # stale: bucket on the previous timepoint's signatures (what a batched call hands back)
        tot['stale'] += lib.bench_set_runs(True); tot['coh_stale'] += lib.bench_coherent_batches()
        sigs_total += lib.bench_signatures()
        tot['grouped'] += lib.bench_set_runs(True); tot['coh_grouped'] += lib.bench_coherent_batches()
        if r is data[0]: bad += lib.bench_set_check()
print(f"{deck.split('/')[-1]} W={W}: {len(devs)} devices, {len(groups)} groups, runs/batch naive {tot['naive']/tot['batches']:.2f}, grouped by region {tot['grouped']/tot['batches']:.2f}, by last timepoint's region {tot['stale']/tot['batches']:.2f}; coherent batches naive {tot['coh_naive']/tot['batches']:.1%}, grouped {tot['coh_grouped']/tot['batches']:.1%}, stale {tot['coh_stale']/tot['batches']:.1%}; mismatches {bad}")
