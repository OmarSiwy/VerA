#!/usr/bin/env python3
"""VerA's IEEE 1364-2005 behaviour against outside suites and tools.

    tools/external_digital.py [VERA] [--native] [--only SUITE] [--names FILE]

`zig build test-external-digital` runs this with the built `vera`. Three
suites, each a folder under tests/fixtures/external/ with a MANIFEST.md (the
upstream URL and pinned commit are read from its `- upstream:` and
`- commit:` lines) and a TRIAGE.md:

    ivtest         the Icarus Verilog regression suite: its lists, gold files
                   and PASSED convention (MANIFEST.md has the selection rule)
    sv-tests       chipsalliance/sv-tests, the Verilog-2005 subset
    iverilog-diff  `iverilog -g2005` + `vvp` against `vera --run`, transcript
                   for transcript, over VerA's own .v fixtures and the two
                   selections above; verilator and yosys are a second opinion
                   where the two disagree on accepting a source

Upstream sources are fetched into .zig-cache/external/ (git-ignored) at the
pinned commit, never committed: ivtest is GPL-2.0.

Every disagreement prints as `FAIL <suite>/<name>: why`, or `KNOWN` when its
name has a row in the suite's TRIAGE.md (which carries the verdict). Exit 1
while any FAIL is untriaged. Needs python3, git; iverilog/vvp for
iverilog-diff, verilator/yosys for its second opinion (`nix develop
.#benchmarking`). A suite whose tool is missing is reported as skipped.
"""
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXT = ROOT / "tests/fixtures/external"
CACHE = ROOT / ".zig-cache/external"
TIMEOUT = 20
JOBS = min(4, os.cpu_count() or 1)
# Prepended to every tool invocation, e.g. a memory cap:
# EXT_WRAP="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0"
WRAP = os.environ.get("EXT_WRAP", "").split()

# IEEE 1364-2005's normative system tasks and functions: clauses 15 (timing
# checks), 17 and 18 (VCD), and the PLA tasks of 17.5. Annex C's (`$save`,
# `$countdrivers`, `$scope`, ...) are informative and stay out.
SYSTF_1364 = set("""
acos acosh asin asinh atan atan2 atanh bitstoreal ceil clog2 cos cosh display
displayb displayh displayo dist_chi_square dist_erlang dist_exponential
dist_normal dist_poisson dist_t dist_uniform dumpall dumpfile dumpflush
dumplimit dumpoff dumpon dumpports dumpportsall dumpportsflush dumpportslimit
dumpportsoff dumpportson dumpvars exp fclose fdisplay fdisplayb fdisplayh
fdisplayo feof ferror fflush fgetc fgets finish floor fmonitor fmonitorb
fmonitorh fmonitoro fopen fread fscanf fseek fstrobe fstrobeb fstrobeh fstrobeo
ftell fullskew fwrite fwriteb fwriteh fwriteo hold hypot itor ln log10 monitor
monitorb monitorh monitoro monitoroff monitoron nochange period pow
printtimescale q_add q_exam q_full q_initialize q_remove random readmemb
readmemh realtime realtobits recovery recrem removal rewind rtoi sdf_annotate
setup setuphold sformat signed sin sinh skew sqrt sscanf stime stop strobe
strobeb strobeh strobeo swrite swriteb swriteh swriteo tan tanh time timeformat
timeskew ungetc unsigned width write writeb writeh writeo test$plusargs
value$plusargs
""".split())
SYSTF_1364 |= {f"{s}$and${k}" for s in ("async", "sync") for k in ("array", "plane")}
SYSTF_1364 |= {f"{s}${g}${k}" for s in ("async", "sync") for g in ("nand", "or", "nor") for k in ("array", "plane")}

# IEEE 1800-2017 Table B.1 keywords that IEEE 1364-2005 Table B.1 does not
# reserve. A 1364 source may use them as identifiers; the sv-tests rule refuses
# such a source anyway, since sv-tests is written for SystemVerilog.
SV_KEYWORDS = set("""
accept_on alias always_comb always_ff always_latch assert assume before bind
bins binsof bit break byte chandle checker class clocking const constraint
context continue cover covergroup coverpoint cross dist do endchecker endclass
endclocking endgroup endinterface endpackage endprogram endproperty endsequence
enum eventually expect export extends extern final first_match foreach
forkjoin global iff ignore_bins illegal_bins implements implies import inside
int interconnect interface intersect join_any join_none let local logic
longint matches modport nettype new nexttime null package packed priority
program property protected pure rand randc randcase randsequence ref
reject_on restrict return s_always s_eventually s_nexttime s_until
s_until_with sequence shortint shortreal soft solve static string strong
struct super sync_accept_on sync_reject_on tagged this throughout
timeprecision timeunit type typedef union unique unique0 until until_with
untyped var virtual void wait_order weak within
""".split())
# SystemVerilog-only syntax, over the source without comments and strings:
# '{ and '0-style fills, casts, ++/--, compound assignment, ::, ##, .*
# connection, $ as a range bound, a streaming {<< or {>>, a time literal, an
# `edge` event, a parameter port list without `parameter`, an end label
# (`end : b`, `join : b`, `endmodule : m`), a declaration in an unnamed block
# (1364 A.6.3 gives only a named block declarations), a statement label
# (`l: begin`).
SV_TOKENS = re.compile(r"'\{|'[01xXzZ](?![0-9a-zA-Z_])|\w'\(|\+\+|--|[-+*/%&|^]=|<<=|>>=|::|##|\.\*|\[\s*\$|:\s*\$\s*\]"
                       r"|\{\s*(?:<<|>>)|\b\d+(?:\.\d+)?(?:fs|ps|ns|us|ms|s)\b|@\s*\(\s*edge\b|#\s*\(\s*[A-Za-z_]\w*\s*="
                       r"|\b(?:end\w*|join)\s*:\s*[A-Za-z_]|\bbegin\s+(?:integer|reg|real|realtime|time|event|parameter|localparam)\b|(?:^|;)\s*[A-Za-z_]\w*\s*:\s*(?:begin|fork)\b", re.M)
# SystemVerilog-only preprocessor forms, over the raw text: `", `\`", ``
# token pasting, `undefineall, `__FILE__/`__LINE__, a macro formal with a
# default (`define M(a=5)), a string continued past a newline (1364 3.6: "on
# a single line").
SV_PP = re.compile(r"`\"|`\\`\"|``|`undefineall|`__FILE__|`__LINE__|`define\s+\w+\([^)]*=|\"[^\"\n]*\\\n")


def strip(text):
    """`text` without comments and string contents (strings become "")."""
    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"',
                  lambda m: '""' if m.group(0).startswith('"') else " ", text, flags=re.S)


def non_1364_systf(code):
    return sorted({m for m in re.findall(r"(?<![\w\\])\$([A-Za-z_][\w$]*)", code)} - SYSTF_1364)


def sv_reasons(code, raw=""):
    words = set(re.findall(r"(?<![\w$`\\])[A-Za-z_]\w*", code)) & SV_KEYWORDS
    toks = SV_TOKENS.findall(code)
    return sorted(words) + sorted(set(toks)) + sorted(set(SV_PP.findall(raw)))


# ---------------------------------------------------------------------------
# Plumbing: manifests, the fetch cache, triage, running tools.
# ---------------------------------------------------------------------------

def manifest(suite):
    text = (EXT / suite / "MANIFEST.md").read_text()
    return dict(re.findall(r"(?m)^- (\w+): `?([^`\s]+)`?", text))


def fetch(suite):
    """The pinned upstream tree, shallow-fetched once into the cache."""
    m = manifest(suite)
    d = CACHE / suite
    head = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip() if d.is_dir() else ""
    if head != m["commit"]:
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        for argv in (["git", "init", "-q"], ["git", "fetch", "-q", "--depth", "1", m["upstream"], m["commit"]],
                     ["git", "checkout", "-q", "FETCH_HEAD"]):
            subprocess.run(argv, cwd=d, check=True)
    return d


def triage(suite):
    """name -> verdict, from TRIAGE.md's `| name | verdict | ... |` rows."""
    p = EXT / suite / "TRIAGE.md"
    rows = re.findall(r"(?m)^\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|", p.read_text()) if p.is_file() else []
    return dict(rows)


def run(argv, cwd, timeout=TIMEOUT):
    """(status, stdout, stderr): status is 0.. exit code, or 'timeout'."""
    try:
        p = subprocess.run([*WRAP, *map(str, argv)], cwd=cwd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")
    except subprocess.TimeoutExpired as e:
        return "timeout", (e.stdout or b"").decode(errors="replace"), (e.stderr or b"").decode(errors="replace")


# What the standard leaves to the tool, dropped from both sides before a
# transcript compare: the simulator's own $finish/$stop report (17.4.1 says
# only that a "diagnostic message" may print), iverilog's compile-time
# warnings in a gold file, and vvp's VCD banner. Line endings normalise to \n.
TOOL_LINE = re.compile(
    r"^(\$finish at tick .*|\$stop at tick .*"
    r"|\S+:\d+: \$(finish|stop) called at .*"
    r"|\S+:\d+: (warning|sorry|error): .*"
    r"|VCD (info|warning): .*|WARNING: .*|\*\* VVP Stop\(0\) \*\*|\*\* Flushing output streams\.|\*\* Current simulation time is .*"
    r"|\*\* Continue with \$stop\.|\*\*\* This is .*)$")


def normalise(text):
    return "\n".join(l for l in text.replace("\r\n", "\n").split("\n") if not TOOL_LINE.match(l)).strip("\n")


def first_error(err):
    """The first diagnostic line of a vera stderr, for a FAIL line."""
    return next((l.strip() for l in err.split("\n") if l.startswith(("error", "thread", "panic"))), "")


def passed(text):
    return any(re.fullmatch(r"\s*passed\s*", l, re.I) for l in text.split("\n"))


class Vera:
    def __init__(self, exe, native):
        self.exe, self.native = exe, native

    def run(self, files, cwd, args=()):
        return run([self.exe, "--run", *args, *files], cwd)

    def emit_exe(self, files, cwd, args=(), key="x"):
        work = CACHE / "native" / key
        work.mkdir(parents=True, exist_ok=True)
        rc, out, err = run([self.exe, "--emit-exe", "--work-dir", work, *args, *files], cwd, timeout=600)
        if rc != 0:
            return rc, out, err
        return run([out.strip().split("\n")[0]], cwd)


# ---------------------------------------------------------------------------
# ivtest
# ---------------------------------------------------------------------------

# iverilog options a selected test may carry, and the vera flags they mean.
# -gspecify enables specify blocks VerA always reads; -W* only adds warnings.
IVL_OPTS = {"-gspecify": [], "-g2005": ["--std=1364-2005"], "-g2001": ["--std=1364-2001"],
            "-g2001-noconfig": ["--std=1364-2001"], "-g1995": ["--std=1364-1995"], "-g1": ["--std=1364-1995"],
            "-g2": ["--std=1364-2001"]}
TYPES = {"normal", "CE", "CO", "CN", "RE"}


def ivtest_lists(iv):
    """name -> (type, args, dir, gold) with upstream's precedence
    (perl-lib/RegressionList.pm): regress-ivl1.list is read before
    regress-vlg.list and the first entry for a name wins. Only names whose
    winning entry is regress-vlg.list's are returned, plus regress-vvp.list's
    JSON tests."""
    seen, out = set(), {}
    for lst in ("regress-ivl1.list", "regress-vlg.list"):
        for line in (iv / lst).read_text().split("\n"):
            line = re.sub(r"#.*", "", line).strip()
            if not line:
                continue
            f = line.split()
            if ":" in f[0] or f[0] in seen:
                continue
            seen.add(f[0])
            if lst != "regress-vlg.list":
                continue
            ty, *args = f[1].split(",")
            gold = f[3][len("gold="):] if len(f) > 3 and f[3].startswith("gold=") else None
            extra = f[3] if len(f) > 3 and not f[3].startswith("gold=") else None
            out[f[0]] = (ty, args + ([extra] if extra else []), f[2], gold and "gold/" + gold)
    import json
    for line in (iv / "regress-vvp.list").read_text().split("\n"):
        f = re.sub(r"#.*", "", line).split()
        if len(f) < 2 or f[0] in seen:
            continue
        try:
            j = json.loads((iv / f[1]).read_text())
        except ValueError:
            continue
        gold = j.get("gold")
        out[f[0]] = (j["type"], j.get("iverilog-args", []) + j.get("vvp-args", []) + j.get("vvp-args-extended", []),
                     "ivltests", gold and f"gold/{gold}-vvp-stdout.gold", j["source"])
    return out


def ivtest_select(iv):
    """(selected cases, {excluded name: reason})."""
    cases, skipped = [], {}
    for name, entry in sorted(ivtest_lists(iv).items()):
        ty, args, d, gold = entry[:4]
        src = Path(d) / (entry[4] if len(entry) > 4 else name + ".v")
        if ty not in TYPES:
            skipped[name] = f"type {ty}"
            continue
        bad = [a for a in args if a not in IVL_OPTS and not a.startswith("-W")]
        if bad:
            skipped[name] = "option " + " ".join(bad)
            continue
        if not (iv / src).is_file():
            skipped[name] = "no source"
            continue
        systf = non_1364_systf(strip((iv / src).read_text(errors="replace")))
        if systf:
            skipped[name] = "non-1364 $" + " $".join(systf)
            continue
        std = [v for a in args for v in IVL_OPTS.get(a, [])] or ["--std=1364-2005"]
        cases.append(dict(name=name, type=ty, src=str(src), std=std, gold=gold, cwd=iv))
    return cases, skipped


def ivtest_judge(case, rc, out):
    ty = case["type"]
    if ty in ("CE", "RE"):
        return None if rc not in (0, "timeout") else f"{ty}: expected a refusal, vera exited {rc}"
    if ty in ("CO", "CN"):
        return None if rc in (0, "timeout") else f"{ty}: expected to compile, vera exited {rc}"
    if rc != 0:
        return f"vera exited {rc}"
    if case["gold"]:
        g = case["cwd"] / case["gold"]
        want = normalise(g.read_text(errors="replace")) if g.is_file() else ""
        return None if normalise(out) == want else "transcript differs from gold"
    return None if passed(out) else "no PASSED line"


def ivtest(vera, report):
    iv = fetch("ivtest") / "ivtest"
    cases, skipped = ivtest_select(iv)

    def one(c):
        args = [*c["std"], "-I", "ivltests"]
        rc, out, err = vera.run([c["src"]], c["cwd"], args)
        why = ivtest_judge(c, rc, out)
        nwhy = "-"
        if vera.native and c["type"] == "normal" and rc == 0:
            nrc, nout, _ = vera.emit_exe([c["src"]], c["cwd"], args, key="ivtest-" + c["name"])
            nwhy = ivtest_judge(c, nrc, nout)
        if why and rc != 0:
            why += ": " + first_error(err)
        return c["name"], why, nwhy, err

    results = list(concurrent.futures.ThreadPoolExecutor(JOBS).map(one, cases))
    report("ivtest", [(n, w, e) for n, w, _, e in results], len(skipped))
    if vera.native:
        report("ivtest-native", [(n, nw, "") for n, _, nw, _ in results if nw != "-"], 0, triage_as="ivtest")
    return cases


# ---------------------------------------------------------------------------
# sv-tests
# ---------------------------------------------------------------------------

def svtests_select(sv):
    cases, skipped = [], {}
    for p in sorted((sv / "tests").rglob("*")):
        if p.suffix not in (".sv", ".v") or not p.is_file():
            continue
        rel = str(p.relative_to(sv / "tests"))
        if not rel.startswith("chapter-"):
            skipped[rel] = "not a chapter test"
            continue
        text = p.read_text(errors="replace")
        meta = dict(re.findall(r"(?m)^:([a-zA-Z_-]+):\s*(.+)$", text))
        if "name" not in meta:
            skipped[rel] = "no metadata (an included file)"
            continue
        if "uvm" in meta.get("tags", "").split():
            skipped[rel] = "uvm"
            continue
        if set(meta) & {"defines", "files", "incdirs", "top_module"}:
            skipped[rel] = "needs runner flags"
            continue
        code = strip(text)
        why = sv_reasons(code, text)
        if why:
            skipped[rel] = "SystemVerilog: " + " ".join(why[:4])
            continue
        systf = non_1364_systf(code)
        if systf:
            skipped[rel] = "non-1364 $" + " $".join(systf)
            continue
        # VerA reads a `.sv` file as IEEE 1800 and refuses it; the text passed
        # rule 2, so it is handed over as the `.v` it is.
        v = CACHE / "sv-tests-v" / (rel[:-len(p.suffix)] + ".v")
        v.parent.mkdir(parents=True, exist_ok=True)
        v.write_text(text)
        cases.append(dict(name=rel, src=str(v), cwd=p.parent,
                          should_fail="should_fail_because" in meta or meta.get("should_fail") == "1",
                          simulate="simulation" in meta.get("type", "parsing elaboration")))
    return cases, skipped


def sv_asserts(out):
    """sv-tests' tools/logparser.py: every `:assert: <python expr>` holds."""
    for e in re.findall(r":assert:(.*)", out):
        try:
            if not eval(e, {"__builtins__": {}}):
                return False
        except Exception:
            return False
    return True


def svtests(vera, report):
    sv = fetch("sv-tests")
    cases, skipped = svtests_select(sv)

    def one(c):
        rc, out, err = vera.run([c["src"]], c["cwd"], ["--std=1364-2005", "-I", str(c["cwd"])])
        ok = rc not in (0, "timeout")
        if c["should_fail"]:
            why = None if ok else f"should_fail: vera exited {rc}"
        elif ok:
            why = f"vera exited {rc}: {first_error(err)}"
        else:
            why = None if not c["simulate"] or sv_asserts(out) else ":assert: failed"
        return c["name"], why, err

    report("sv-tests", list(concurrent.futures.ThreadPoolExecutor(JOBS).map(one, cases)), len(skipped))
    return cases


# ---------------------------------------------------------------------------
# iverilog-diff
# ---------------------------------------------------------------------------

def runner_args(path):
    """tests/harness/digital.zig's `// digital-runner:` directives: (vera
    flags, extra files, skip reason)."""
    flags, files, skip = [], [], None
    for m in re.finditer(r"(?m)^\s*// digital-runner:\s*(\S+)(.*)$", path.read_text(errors="replace")):
        key, rest = m.group(1), m.group(2).split()
        if key.startswith("--std=") or key.startswith("--event-budget="):
            flags.append(key)
        elif key == "files":
            files += [str(path.parent / f) for f in rest]
        elif key in ("--libmap", "-L"):
            skip = "library map (iverilog has no 13.2 library map)"
    return flags, files, skip


def diff_cases(iv_cases, sv_cases):
    """A fixture runs in a copy of its directory (both tools resolve a relative
    `$readmem`/`$fopen` against the working directory, and a case that writes
    a file must not write into the repository)."""
    out = []
    copy = CACHE / "fixtures"
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(ROOT / "tests/fixtures", copy, ignore=shutil.ignore_patterns("external"))
    for sub in ("ieee1364", "digital"):
        for p in sorted((ROOT / "tests/fixtures" / sub).rglob("*.v")):
            text = p.read_text(errors="replace")
            if not (p.with_suffix("").with_suffix(".expected.txt").is_file() or p.with_name(p.stem + ".expected.txt").is_file()
                    or "// digital-runner: reject" in text):
                continue
            flags, files, skip = runner_args(p)
            rel = p.relative_to(ROOT / "tests/fixtures")
            files = [str(copy / Path(f).relative_to(ROOT / "tests/fixtures")) for f in files]
            out.append(dict(name=str(rel), files=[str(copy / rel), *files], cwd=(copy / rel).parent,
                            flags=flags, skip=skip))
    for c in iv_cases:
        out.append(dict(name="ivtest/" + c["name"], files=[c["src"]], cwd=c["cwd"], flags=c["std"], skip=None))
    for c in sv_cases:
        out.append(dict(name="sv-tests/" + c["name"], files=[c["src"]], cwd=c["cwd"], flags=["--std=1364-2005"], skip=None))
    return out


def second_opinion(files, cwd):
    """`verilator --lint-only` and yosys `read_verilog`: accepts/refuses."""
    ops = []
    if shutil.which("verilator"):
        rc, _, _ = run(["verilator", "--lint-only", "--timing", "-Wno-fatal", "-Wno-lint", "-Wno-style", *files], cwd)
        ops.append("verilator " + ("accepts" if rc == 0 else "refuses"))
    if shutil.which("yosys"):
        rc, _, _ = run(["yosys", "-q", "-p", "read_verilog " + " ".join(files)], cwd)
        ops.append("yosys " + ("accepts" if rc == 0 else "refuses"))
    return ", ".join(ops)


def iverilog_diff(vera, report, iv_cases, sv_cases):
    if not (shutil.which("iverilog") and shutil.which("vvp")):
        print("iverilog-diff: skipped — iverilog/vvp not on PATH", file=sys.stderr)
        return
    work = CACHE / "ivl-out"
    work.mkdir(parents=True, exist_ok=True)
    cases = diff_cases(iv_cases, sv_cases)

    def one(i_c):
        i, c = i_c
        if c["skip"]:
            return c["name"], "SKIP " + c["skip"], ""
        files = [os.path.relpath(f, c["cwd"]) if os.path.isabs(f) else f for f in c["files"]]
        exe = str(work / f"{i}.vvp")
        irc, iout, ierr = run(["iverilog", "-g2005", "-o", exe, "-I", ".", *files], c["cwd"])
        if irc == 0:
            irc, iout, ierr = run(["vvp", "-n", exe], c["cwd"])
            if irc == "timeout":
                return c["name"], "SKIP iverilog run times out", ""
            ivl = ("accepts", irc, normalise(iout))
        else:
            ivl = ("refuses", irc, "")
        vrc, vout, verr = vera.run(files, c["cwd"], c["flags"])
        if vrc == "timeout":
            return c["name"], "vera times out", verr
        ver = ("accepts", vrc, normalise(vout)) if "could not compile" not in verr else ("refuses", vrc, "")
        if ivl[0] != ver[0]:
            return c["name"], f"iverilog {ivl[0]}, vera {ver[0]} ({second_opinion(files, c['cwd'])})", verr
        if ivl[0] == "refuses":
            return c["name"], None, verr
        if (ivl[1] == 0) != (ver[1] == 0):
            return c["name"], f"exit: vvp {ivl[1]}, vera {ver[1]}", verr
        return c["name"], None if ivl[2] == ver[2] else "transcript differs", verr

    res = list(concurrent.futures.ThreadPoolExecutor(JOBS).map(one, enumerate(cases)))
    skips = [r for r in res if r[1] and r[1].startswith("SKIP ")]
    report("iverilog-diff", [r for r in res if r not in skips], len(skips))


# ---------------------------------------------------------------------------

def main(argv):
    native = "--native" in argv
    only = argv[argv.index("--only") + 1] if "--only" in argv else None
    names_file = argv[argv.index("--names") + 1] if "--names" in argv else None
    pos = [a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or argv[i - 1] not in ("--only", "--names"))]
    vera = Vera(os.path.realpath(pos[0] if pos else ROOT / "zig-out/bin/vera"), native)
    lines, tallies, untriaged = [], [], [0]

    def report(suite, results, excluded, triage_as=None):
        known = triage(triage_as or suite)
        agree = sum(1 for _, w, _ in results if w is None)
        new = 0
        for name, why, _ in results:
            if why is None:
                continue
            if name in known:
                lines.append(f"KNOWN {suite}/{name}: {why} [{known[name]}]")
            else:
                lines.append(f"FAIL {suite}/{name}: {why}")
                new += 1
        untriaged[0] += new
        tallies.append(f"{suite}\t{len(results)}\t{agree}\t{len(results) - agree}\t{new}\t{excluded}")

    iv = ivtest(vera, report) if only in (None, "ivtest", "iverilog-diff") else []
    sv = svtests(vera, report) if only in (None, "sv-tests", "iverilog-diff") else []
    if only in (None, "iverilog-diff"):
        if only:
            tallies.clear(), lines.clear()
        iverilog_diff(vera, report, iv, sv)

    lines.sort()
    print("\n".join(lines), file=sys.stderr)
    print("suite\tselected\tagree\tdisagree\tuntriaged\texcluded")
    print("\n".join(tallies))
    if names_file:
        Path(names_file).write_text("".join(re.sub(r":.*", "", l) + "\n" for l in lines))
    return 1 if untriaged[0] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
