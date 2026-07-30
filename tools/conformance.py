#!/usr/bin/env python3
"""How conformant VerA is to the specification, measured — never typed.

    tools/conformance.py                      # print the measures block (A, B, C)
    tools/conformance.py --changelog v0.1.0   # prepend it to CHANGELOG.md
    tools/conformance.py --check v0.1.0       # re-measure and diff vs CHANGELOG.md
    tools/conformance.py <subcommand> [...]   # one of the signals below

Every number comes from a command in this file. There is no second place a
percentage is written down, which is the point: ROADMAP.md §1 defines v1.0.0
as four measures, and three of them are machine-readable today. Only the
measures block may write A, B and C; every subcommand is a separate signal and
none of them changes the block or CHANGELOG.md:

    comments        clauses the code cites or refuses vs the fixtures' tags
    tally-b         CLAUSE-AUDIT.md §7.1's §§17-18 obligation arithmetic
    lrm-audit       the LRM PDF against docs/*.html, section by section
    ieee1364-audit  the IEEE 1364-2005 heading worklist (licensed local PDF)
    keywords        Table B.1 against the PDF, and its spelling fixtures
    figures         re-crop the LRM figures in docs/figures from the PDF
    verilator       Verilator as a second engine on the same .v designs
    selftest        regression checks for the subcommands and the LRM text

ponytail: a regex over the suite's own report, not a --json flag on bench.zig.
Both lines parsed here are already machine-shaped — the `pass fail unasserted
xfail` TSV row (tests/bench.zig) and the coverage tally (tests/harness/
coverage.zig). If a third consumer ever wants this, add the JSON then.
"""
import argparse
import datetime
import difflib
import hashlib
import html
import json
import os
import re
import struct
import subprocess
import sys
import unicodedata
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# name -> function(argv) -> exit code. Each section below adds its own.
SUBCOMMANDS = {}


def die(msg):
    print(f"conformance.py: {msg}", file=sys.stderr)
    sys.exit(2)


def run(*argv):
    """`$(argv 2>&1)` and its exit status."""
    p = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.stdout.decode("utf-8", "replace").rstrip("\n"), p.returncode


def quiet(*argv):
    """`argv >/dev/null 2>&1 && echo pass || echo FAIL`."""
    rc = subprocess.run(argv, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    return "pass" if rc == 0 else "FAIL"


def is_num(s):
    return re.fullmatch(r"[0-9]+", s or "") is not None


def polarity(text):
    """The four polarity counts, in report order. A fifth number joins the
    fourth field, as `read -r a b c d` would, and so fails `is_num`."""
    found = re.findall(r"\d+(?= (?:cited both ways|positive citations only|rejection citations only|uncited))", text)
    return (found + ["", "", "", ""])[:3] + [" ".join(found[3:])]


def first(pattern, text):
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else ""


def pct(n, d):
    return "n/a" if d == 0 else "%.1f%%" % (100 * n / d)


def measure():
    """The measures block, and the numbers its status lines quote."""
    # CI has already run these suites and kept the logs; re-running them costs
    # half an hour and cannot produce a different answer. Locally both are
    # unset and this script runs them itself.
    #   STRICT_LOG=… COVERAGE_LOG=… tools/conformance.py
    strict_log = os.environ.get("STRICT_LOG", "")
    coverage_log = os.environ.get("COVERAGE_LOG", "")
    if not (strict_log or coverage_log):
        if subprocess.run(["zig", "build", "-Doptimize=ReleaseFast", "install"], cwd=ROOT, stdout=sys.stderr).returncode:
            sys.exit(2)

    # --- Measure A: the fixture suite ---------------------------------------
    # bench.zig prints a TSV header `pass fail unasserted xfail` and one row
    # under it. --strict decides the exit code on it; the counts print either way.
    if strict_log:
        try:
            strict = Path(strict_log).read_text(errors="replace").rstrip("\n")
        except OSError as e:
            print(f"cat: {strict_log}: {e.strerror}", file=sys.stderr)
            strict = ""
        rcs = re.findall(r"^(?:strict exit: |exit=)(\d+)", strict, re.M)
        strict_rc = rcs[-1] if rcs else "?"
    else:
        strict, strict_rc = run("zig", "build", "benchmark", "--", "--strict")
    lines = strict.split("\n")
    heads = [i for i, l in enumerate(lines) if l == "pass\tfail\tunasserted\txfail"]
    row = (lines[heads[-1] + 1] if heads[-1] + 1 < len(lines) else lines[heads[-1]]).split(None, 3) if heads else []
    passed, fail, unas, xfail = (row + ["", "", "", ""])[:4]
    if not is_num(passed):
        print("\n".join(lines[-30:]), file=sys.stderr)
        die("could not parse the verdict row. bench.zig changed?")
    try:
        total = sum(int(v or 0) for v in (passed, fail, unas, xfail))
    except ValueError:
        die("could not parse the verdict row. bench.zig changed?")
    p = int(passed)

    # --- Measure C: static clause citations, not verified rule coverage -------
    if coverage_log:
        try:
            cov = Path(coverage_log).read_text(errors="replace").rstrip("\n")
        except OSError:
            die("could not read COVERAGE_LOG")
    else:
        cov, rc = run("zig", "build", "benchmark", "--", "--coverage")
        if rc:
            die("coverage command failed")
    both, acc, ref, unc = polarity(cov)
    # CLAUSE-AUDIT §5 classifications (`CLAUSES.tsv`), counted apart from both
    # ways: a reviewed claim that a clause carries nothing to reject, not evidence.
    classified = first(r"(\d+)(?= classified$)", cov)
    clauses = first(r"^\d+ of (\d+)(?= LRM clauses cited)", cov)
    if not is_num(clauses):
        die("could not parse the coverage tally. harness/coverage.zig changed?")
    if not all(is_num(v) for v in (both, acc, ref, unc, classified)):
        die("incomplete coverage polarity tally")
    if sum(int(v) for v in (both, acc, ref, unc, classified)) != int(clauses):
        die("coverage tally does not sum to clause denominator")

    # --- Measure B: IEEE 1364-2005 clauses, the same static inventory ---------
    cov1364, rc = run("zig", "build", "test-1364", "--", "--coverage")
    if rc:
        die("1364 coverage command failed")
    b_both, b_acc, b_ref, b_unc = polarity(cov1364)
    b_classified = first(r"(\d+)(?= classified$)", cov1364)
    b_clauses = first(r"^\d+ of (\d+)(?= IEEE 1364-2005 clauses cited)", cov1364)
    if not all(is_num(v) for v in (b_clauses, b_both, b_acc, b_ref, b_unc, b_classified)):
        die("could not parse the 1364 coverage tally. tests/ieee1364.zig changed?")
    if sum(int(v) for v in (b_both, b_acc, b_ref, b_unc, b_classified)) != int(b_clauses):
        die("1364 tally does not sum to its clause denominator")

    # --- The two gates that are pass/fail, not a percentage --------------------
    unit = quiet("zig", "build", "test")
    devices = quiet("zig", "build", "test-devices")

    n_both, n_clauses, n_classified = int(both), int(clauses), int(classified)
    nb_both, nb_clauses, nb_classified = int(b_both), int(b_clauses), int(b_classified)
    block = f"""| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **{passed} / {total} — {pct(p, total)}** | {total - p} rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | {fail} · {unas} · {xfail} | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **{both} / {clauses} — {pct(n_both, n_clauses)}** | {n_clauses - n_both - n_classified} clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | {acc} · {ref} · {unc} | requires rule-level review | same run |
| &nbsp;&nbsp;↳ classified under `CLAUSE-AUDIT.md` §5 (`CLAUSES.tsv`) | {classified} | reviewed claims, not evidence | same run |
| **B** — IEEE 1364-2005 clauses with both citation polarities (static) | **{b_both} / {b_clauses} — {pct(nb_both, nb_clauses)}** | {nb_clauses - nb_both - nb_classified} clauses | `zig build test-1364 -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited · classified | {b_acc} · {b_ref} · {b_unc} · {b_classified} | §§17–18 obligation detail: `docs/CLAUSE-AUDIT.md` §7.1 | same run |
| **D** — `ARCHITECTURE.md` §6 phases landed | hand-entered, see `ARCHITECTURE.md` §8 | not measured by this script | architecture review required |
| `zig build test` | **{unit}** | pass | `zig build test` |
| `zig build test-devices` | **{devices}** | pass | `zig build test-devices` |

`--strict` exit code **{strict_rc}** — 0 only when FAIL, unasserted and XFAIL are all 0.
A, B and C are measured by this script and nothing else may write them. D is
hand-entered against its source document; if you change it, say which document
you read.

B and C count citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `docs/CLAUSE-AUDIT.md`."""
    return block, f"{passed}/{total} fixtures, {both}/{clauses} clauses"


def measured(lines):
    """Only the rows this script computes are verifiable. D is hand-entered
    against a document no command reads, so `--check` must not hold it to the
    placeholder text `--changelog` wrote: it would force every release to
    either leave them blank or fail."""
    return [l for l in lines if l.startswith("|") and "hand-entered" not in l]


def section(text, version):
    """`sed -n '/^## <version> /,/^## .*—/p'`: from the entry's heading to the
    next entry's, both included."""
    start = re.compile("^## " + re.escape(version) + " ")
    end = re.compile("^## .*—")
    out, inside = [], False
    for line in text.split("\n"):
        if inside:
            out.append(line)
            inside = not end.search(line)
        elif start.search(line):
            out.append(line)
            inside = True
    return out


def measures(mode, version):
    changelog = ROOT / "CHANGELOG.md"
    block, summary = measure()
    if not mode:
        print(block)
        return 0
    text = changelog.read_text() if changelog.exists() else ""
    if mode == "--check":
        if not re.search("^## " + re.escape(version) + " ", text, re.M):
            die(f"CHANGELOG.md has no {version} entry. Run: tools/conformance.py --changelog {version}")
        want = measured(section(text, version))
        got = measured(block.split("\n"))
        if want == got:
            print(f"conformance.py: {version} matches the tree — {summary}", file=sys.stderr)
            return 0
        print(f"conformance.py: CHANGELOG.md's {version} numbers are not what this tree measures.", file=sys.stderr)
        print("  Left is CHANGELOG.md, right is this run. Re-tag after re-measuring:", file=sys.stderr)
        print(f"    tools/conformance.py --changelog {version}", file=sys.stderr)
        sys.stderr.writelines(difflib.unified_diff(
            [l + "\n" for l in want], [l + "\n" for l in got], "CHANGELOG.md", "this tree"))
        return 1
    # --changelog: prepend. The preamble is preserved by splitting on the first
    # `## ` line, so a re-run never duplicates it.
    lines = text.splitlines(keepends=True)
    cut = next((i for i, l in enumerate(lines) if l.startswith("## ")), len(lines))
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    changelog.write_text("".join(lines[:cut]) + f"## {version} — {date}\n\n{block}\n\n" + "".join(lines[cut:]))
    print(f"CHANGELOG.md: {version} written — {summary}", file=sys.stderr)
    return 0


def main(argv):
    if argv and argv[0] in SUBCOMMANDS:
        return SUBCOMMANDS[argv[0]](argv[1:])
    mode = argv[0] if argv else ""
    if mode not in ("", "--changelog", "--check"):
        print(f"usage: conformance.py [--changelog|--check vX.Y.Z] | {'|'.join(SUBCOMMANDS)} ...", file=sys.stderr)
        return 2
    version = argv[1] if len(argv) > 1 else ""
    if mode and not version:
        print(f"usage: conformance.py {mode} vX.Y.Z", file=sys.stderr)
        return 2
    return measures(mode, version)


# ---------------------------------------------------------------------------
# tally-b: CLAUSE-AUDIT.md §7.1's inherited §§17-18 obligation table
# ---------------------------------------------------------------------------

def tally_b(argv):
    """Re-add CLAUSE-AUDIT.md §7.1's table and fail if the per-section rows stop
    summing to the total, or closed + open stops summing to the row count.

    B is the one measure with no suite behind its §§17-18 detail: those
    obligations are outside `--coverage`'s denominator by construction
    (CLAUSE-AUDIT.md §1.1 c), so the rows are hand-read. What CAN be checked is
    the arithmetic, and that is this check's whole job. It answers "is the
    hand-read tally self-consistent?", not "is it right?": re-deriving the rows
    is reading, and AGENTS.md §2 says so. Never report it as a measurement.

    ponytail: a split on `|` over the one table, not a markdown parser. The
    table is pinned by its header row, so a reshuffle of §7 cannot silently
    match the wrong one.
    """
    doc = ROOT / "docs/CLAUSE-AUDIT.md"
    if not os.access(doc, os.R_OK):
        print(f"tally-b: {doc} is missing (it was deleted once: 2cc1c08)", file=sys.stderr)
        return 2

    def cells(fields):
        """Columns Rows..unspecified as numbers: digits only, a dash is 0."""
        out = []
        for i in range(2, 9):
            digits = re.sub(r"[^0-9]", "", fields[i]) if i < len(fields) else ""
            out.append(int(digits) if digits else 0)
        return out

    intable, rows, verdicts, trows, tsum, closed, opened = False, 0, 0, 0, 0, 0, 0
    per, bad = [], []
    for line in doc.read_text().split("\n"):
        fields = line.split("|")
        if re.match(r"^\| Section \| Rows \| missing \|", line):
            intable = True
            continue
        if intable and line.startswith("| **Total**"):
            v = cells(fields)
            trows, tsum, intable = v[0], sum(v[1:]), False
            continue
        if intable and line.startswith("| §4"):
            v = cells(fields)
            rows += v[0]
            verdicts += sum(v[1:])
            per.append(f"{fields[1]}  rows={v[0]}  verdicts={sum(v[1:])}")
            if v[0] != sum(v[1:]):
                bad.append(per[-1])
        if line.startswith("| **closed** |"):
            closed = cells(fields)[0]
        if line.startswith("| **open** |"):
            opened = cells(fields)[0]

    rc = 0
    for p in per:
        print("  " + p)
    print(f"\n  section rows       {rows}\n  section verdicts   {verdicts}\n  stated total       {trows} / {tsum}")
    print(f"  closed + open      {closed} + {opened} = {closed + opened}\n")
    for b in bad:
        print(f"FAIL: section does not sum: {b}")
        rc = 1
    if rows != verdicts:
        print(f"FAIL: rows {rows} != verdicts {verdicts}")
        rc = 1
    if trows != rows:
        print(f"FAIL: stated total {trows} != summed rows {rows}")
        rc = 1
    if tsum != verdicts:
        print(f"FAIL: stated verdict total {tsum} != summed {verdicts}")
        rc = 1
    if closed + opened != rows:
        print(f"FAIL: closed+open {closed + opened} != rows {rows}")
        rc = 1
    if rc == 0:
        print(f"measure B: {closed} / {rows} closed, {opened} open — tally is self-consistent")
    return rc


SUBCOMMANDS["tally-b"] = tally_b


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
