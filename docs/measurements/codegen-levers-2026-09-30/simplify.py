#!/usr/bin/env python3
"""Lever-5 prototype: rewrite an emitted tree's text to a flatter shape, by identities
the scalar-family contract already guarantees (con(c).val() == c, zTo(S, 0x0, a) == a
for a value already at mask 0), then copy the tree. usage: simplify.py SRC DST [rules]
rules: comma list of conval, zto0, boolchain (default all)."""
import os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
rules = set((sys.argv[3] if len(sys.argv) > 3 else "conval,zto0,boolchain,slotarr").split(","))
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".zig-cache", "*.so"))

def match_paren(t, i):  # t[i] == '('
    d = 0
    for j in range(i, len(t)):
        c = t[j]
        if c == '(': d += 1
        elif c == ')':
            d -= 1
            if d == 0: return j
    raise ValueError

def conval(t):
    # S.con(X).val()  ->  (X)
    out, i, n = [], 0, 0
    key = "S.con("
    while True:
        k = t.find(key, i)
        if k < 0: out.append(t[i:]); break
        o = k + len(key) - 1
        c = match_paren(t, o)
        if t.startswith(".val()", c + 1):
            out.append(t[i:k]); out.append("(" + conval(t[o + 1:c]) + ")"); i = c + 1 + len(".val()"); n += 1
        else:
            out.append(t[i:o + 1]); i = o + 1
    return "".join(out)

def zto0(t):
    # zTo(S, 0x0, X) -> (X) : identity at mask 0 (X is already zOf(S, 0) in these sites:
    # a mask-0 slot assigned a mask-0 value); a type error would show it is not.
    return t.replace("zTo(S, 0x0, ", "(")

BC = re.compile(r"@as\(i64, @intFromBool\(\((@as\(i64, @intFromBool\([^()]*(?:\([^()]*\)[^()]*)*\)\))\) != \(@as\(i64, 0\)\)\)\)")
def boolchain(t):
    # @as(i64, @intFromBool((@as(i64, @intFromBool(E))) != (@as(i64, 0))))  ->  @as(i64, @intFromBool(E))
    prev = None
    while prev != t:
        prev = t; t = BC.sub(r"\1", t)
    return t

SL = re.compile(r"zSlots\(S, &\.\{ ((?:0x0, )*0x0) \}\)")
def slotarr(t):
    # an all-mask-0 slot tuple is an array of one type
    return SL.sub(lambda m: f"[{m.group(1).count('0x0')}]zOf(S, 0x0)", t)

HD = re.compile(r"var h: zSlots\(S, &\.\{ (.*?) \}\) = undefined;")
HR = re.compile(r"\bh\[(\d+)\]")
def slotgroup(t):
    # one array per distinct mask instead of one tuple field per slot
    out, i = [], 0
    while True:
        m = HD.search(t, i)
        if not m: out.append(t[i:]); return "".join(out)
        end = t.find("\n}\n", m.end()); end = len(t) if end < 0 else end
        ms = m.group(1).split(", ")
        groups = {}
        where = []
        for k in ms:
            groups.setdefault(k, 0); where.append((list(groups).index(k), groups[k])); groups[k] += 1
        decl = " ".join(f"var h{g}: [{n}]zOf(S, {k}) = undefined;" for g, (k, n) in enumerate(groups.items()))
        body = t[m.end():end]
        assert not re.search(r"\bh\b(?!\[)", body), "h used whole"
        body = HR.sub(lambda r: "h%d[%d]" % where[int(r.group(1))], body)
        out.append(t[i:m.start()]); out.append(decl); out.append(body); i = end

for root, _, files in os.walk(dst):
    for f in files:
        if not f.endswith(".zig") or f == "shim.zig": continue
        p = os.path.join(root, f); t = open(p).read(); b = len(t)
        if "zto0" in rules and f != "h.zig":
            # only inside setup/derive (mask-0 value family) and anywhere the literal mask is 0
            t = zto0(t)
        if "conval" in rules: t = conval(t)
        if "boolchain" in rules: t = boolchain(t)
        if "slotarr" in rules: t = slotarr(t)
        if "slotgroup" in rules: t = slotgroup(t)
        open(p, "w").write(t)
        print(f, b, "->", len(t))
