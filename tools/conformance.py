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


# ---------------------------------------------------------------------------
# lrm-audit: the LRM PDF against docs/*.html, section by section
# ---------------------------------------------------------------------------

LRM_PDF = ROOT / "docs/VAMS-LRM-2023.pdf"
LRM_SHA256 = "e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134"
SECTION = re.compile(r"^((?:[1-9][0-9]?|[A-H])(?:\.[0-9]+)+)\s+(.+)$")
CHAPTER = re.compile(r"^([1-9][0-9]?)\.\s+([A-Z].+)$")
ANNEX = re.compile(r"^Annex ([A-H])(?:\s|$)")


def heading(text):
    match = SECTION.match(text) or CHAPTER.match(text) or ANNEX.match(text)
    return match.group(1) if match else None


def tokens(text):
    # Do not guess which hyphens are line-wrap artifacts: Verilog-\nAMS and
    # arithmetic a-\nb retain meaningful '-'. Compatibility normalization
    # would also erase distinctions such as superscript ² versus ordinary 2.
    # Canonical Unicode equivalence is safe for this text-token worklist;
    # ligatures, soft hyphens and typography still require explicit review.
    text = unicodedata.normalize("NFC", text)
    return re.findall(r"\w+|[^\w\s]", text)


class ChapterHTML(HTMLParser):
    """Collect headings and body text, excluding navigation/style metadata."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sections = {}
        self.current = None
        self.skip = 0
        self.in_heading = False
        self.heading_text = []
        self.heading_line = 0
        self.duplicates = []

    def handle_starttag(self, tag, attrs):
        if tag in ("head", "nav", "script", "style"):
            self.skip += 1
        if self.skip:
            return
        if re.fullmatch(r"h[1-6]", tag):
            self.in_heading = True
            self.heading_text = []
            self.heading_line = self.getpos()[0]
        elif tag in ("p", "div", "pre", "tr", "li", "br", "figure"):
            self.append("\n")
        elif tag in ("td", "th"):
            self.append(" ")

    def handle_endtag(self, tag):
        if tag in ("head", "nav", "script", "style"):
            self.skip -= 1
            return
        if self.skip:
            return
        if re.fullmatch(r"h[1-6]", tag) and self.in_heading:
            title = "".join(self.heading_text).strip()
            section = heading(title)
            if section:
                if section in self.sections:
                    self.duplicates.append(section)
                self.current = section
                self.sections[section] = {
                    "title": title, "line": self.heading_line, "text": ""
                }
            else:
                self.append("\n" + title + "\n")
            self.in_heading = False
        elif tag in ("p", "div", "pre", "tr", "li", "figure"):
            self.append("\n")

    def append(self, text):
        if self.current:
            self.sections[self.current]["text"] += text

    def handle_data(self, text):
        if self.skip:
            return
        if self.in_heading:
            self.heading_text.append(text)
        else:
            self.append(text)


def pdf_sections(pdf):
    proc = subprocess.run(
        ["pdftotext", "-layout", str(pdf), "-"],
        capture_output=True, text=True, check=True,
    )
    sections = {}
    current = None
    chapter = None
    started = False
    duplicates = []
    for page, text in enumerate(proc.stdout.split("\f"), 1):
        lines = text.splitlines()
        # Exclude front matter/TOC using the first body heading, without dotted
        # leaders. PDF physical page indices remain attached to every section.
        if not started:
            if "1. Verilog-AMS introduction" not in lines:
                continue
            started = True
        for index, line in enumerate(lines):
            stripped = line.strip()
            if (not stripped or "Accellera Std VAMS-2023" in line
                    or "Accellera Standard for VERILOG-AMS" in line
                    or "Copyright © 2024 Accellera" in line
                    or (re.fullmatch(r"\d+", stripped) and
                        next((tail.strip() for tail in lines[index + 1:]
                              if tail.strip()), "").startswith(
                                  "Copyright © 2024 Accellera"))):
                continue
            # Body headings have varying indentation. Restrict candidates
            # to the current chapter so references cannot create foreign rows.
            top = CHAPTER.match(stripped) or re.fullmatch(r"Annex ([A-H])", stripped)
            sec = SECTION.match(stripped)
            new_id = None
            if top:
                proposed = top.group(1)
                # §1.5 repeats chapter titles as a contents description.
                # A new chapter follows its predecessor, never inside §1.5.
                order = [str(n) for n in range(1, 13)] + list("ABCDEFGH")
                expected = order[0] if chapter is None else (
                    order[order.index(chapter) + 1] if chapter != "H" else None
                )
                if proposed == expected and (current != "1.5" or page >= 24):
                    chapter = proposed
                    new_id = proposed
            elif sec and sec.group(1).split(".")[0] == chapter:
                # Cross references have prose continuations and sometimes
                # start at column zero. Repeated ids are retained as body text.
                if sec.group(1) not in sections:
                    new_id = sec.group(1)
            if new_id and new_id not in sections:
                current = new_id
                sections[current] = {"title": stripped, "page": page, "text": ""}
            elif current:
                sections[current]["text"] += line.rstrip() + "\n"
    return sections, duplicates


def sort_key(section):
    return tuple((0, int(p)) if p.isdigit() else (1, p) for p in section.split("."))


def html_sections(root):
    """Every numbered heading of docs/*.html: {section: {title, line, text, file}},
    and the headings declared twice."""
    html, duplicates = {}, []
    for path in sorted((root / "docs").glob("*.html")):
        if path.name == "index.html":
            continue
        parsed = ChapterHTML()
        parsed.feed(path.read_text())
        duplicates.extend(f"{path.name}:{s}" for s in parsed.duplicates)
        for section, item in parsed.sections.items():
            if section in html:
                duplicates.append(section)
            html[section] = dict(item, file=str(path.relative_to(root)))
    return html, duplicates


def inventory(root):
    pdf = root / "docs/VAMS-LRM-2023.pdf"
    source, pdf_duplicates = pdf_sections(pdf)
    html, duplicates = html_sections(root)
    duplicates = list(pdf_duplicates) + duplicates
    rows = []
    for section in sorted(source.keys() | html.keys(), key=sort_key):
        p, h = source.get(section), html.get(section)
        row = {"section": section, "pdf": p, "html": h}
        if p is None:
            row["comparison"] = "html-only-heading"
        elif h is None:
            row["comparison"] = "pdf-only-heading"
        else:
            row["comparison"] = (
                "same-text-tokens" if tokens(p["text"]) == tokens(h["text"])
                else "review-difference"
            )
        rows.append(row)
    return {
        "pdf_sha256": hashlib.sha256(pdf.read_bytes()).hexdigest(),
        "warning": "Mechanical worklist only; no claim of semantic fidelity or conformance.",
        "duplicate_html_headings": duplicates,
        "sections": rows,
    }


def lrm_audit(argv):
    """Source-fidelity worklist, NOT a conformance score.

    Read the checked-in PDF with Poppler and compare each numbered section with
    the HTML. Keep differences visible: equations, diagrams, tables, grammar and
    normative scope still require human review. No fixture earns credit here.
    """
    parser = argparse.ArgumentParser(prog="conformance.py lrm-audit", description=lrm_audit.__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--section", help="Show a section and its descendants")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--diff", action="store_true", help="Print token differences")
    args = parser.parse_args(argv)
    report = inventory(args.root)
    if args.section:
        report["sections"] = [r for r in report["sections"] if
                              r["section"] == args.section or
                              r["section"].startswith(args.section + ".")]
        if not report["sections"]:
            parser.error("section not found")
    if args.json:
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0
    print(report["warning"])
    print("PDF SHA256:", report["pdf_sha256"])
    for row in report["sections"]:
        p, h = row["pdf"], row["html"]
        loc = f'{h["file"]}:{h["line"]}' if h else "MISSING HTML"
        page = p["page"] if p else "MISSING PDF HEADING"
        print(f'{row["section"]}\tPDF page {page}\t{loc}\t{row["comparison"]}')
        if args.diff and p and h:
            a, b = tokens(p["text"]), tokens(h["text"])
            matcher = difflib.SequenceMatcher(None, a, b, autojunk=False)
            for tag, i, j, k, l in matcher.get_opcodes():
                if tag != "equal":
                    print("  PDF:", " ".join(a[max(0, i-5):j+5]))
                    print("  HTML:", " ".join(b[max(0, k-5):l+5]))
    for duplicate in report["duplicate_html_headings"]:
        print("DUPLICATE:", duplicate)
    return 0


SUBCOMMANDS["lrm-audit"] = lrm_audit


# ---------------------------------------------------------------------------
# ieee1364-audit: the IEEE 1364-2005 heading worklist (the licensed local PDF)
# ---------------------------------------------------------------------------

IEEE_SHA256 = "3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e"
# The pinned PDF's TOC lists 212; the body heading is on printed page 213.
# Explicitly retain both, rather than silently searching past a bad anchor.
ANCHOR_CORRECTIONS = {"14.2.1": 213}
IEEE_ROW = re.compile(r"^\s*((?:[0-9]+|[A-I])(?:\.[0-9]+)*)\.?\s+(.+?)\s*\.{3,}\s*(\d+)\s*$")
IEEE_ANNEX = re.compile(r"^\s*Annex ([A-I]) \((normative|informative)\)\s+(.+?)\s*\.{3,}\s*(\d+)\s*$")


def worklist(text):
    pages = text.split("\f")
    if not pages[-1].strip():
        pages.pop()
    body_start = next((i for i, page in enumerate(pages)
                       if re.search(r"(?m)^\s*1\. Overview\s*$", page)), None)
    if body_start is None:
        raise ValueError("cannot locate body heading 1. Overview")
    toc = "\n".join(pages[:body_start])
    start = re.search(r"(?m)^\s*Contents\s*$", toc)
    if not start:
        raise ValueError("cannot locate Contents")
    rows = []
    seen = set()
    ended = False
    for line in toc[start.end():].splitlines():
        annex = IEEE_ANNEX.match(line)
        match = IEEE_ROW.match(line)
        if annex:
            clause, kind, title, printed = annex.groups()
        elif match:
            clause, title, printed = match.groups()
            kind = "informative" if clause.split(".")[0] in ("C", "D", "H", "I") else "normative"
        elif re.search(r"\.{3,}\s*\d+\s*$", line):
            raise ValueError("unparsed TOC entry: " + line.strip())
        else:
            continue
        if clause in seen:
            raise ValueError("duplicate TOC clause: " + clause)
        seen.add(clause)
        if clause.split(".")[0] in ("21", "22", "23", "24", "25", "E", "F"):
            kind = "deprecated-removed"
        body_printed = ANCHOR_CORRECTIONS.get(clause, int(printed))
        physical = body_printed + body_start
        if not 1 <= physical <= len(pages):
            raise ValueError("page outside document: " + clause)
        page = pages[physical - 1]
        # Require the heading identifier at a line start on its listed page.
        # This does not verify title typography or complete body boundaries.
        prefix = "Annex " + clause if annex else re.escape(clause) + (r"\." if "." not in clause else "")
        located = bool(re.search(r"(?m)^\s*" + prefix + r"(?:\s|$)", page))
        rows.append({"id": "IEEE1364-2005:" + clause, "clause": clause,
                     "title": title.strip(), "toc_printed_page": int(printed),
                     "printed_page": body_printed,
                     "pdf_page": physical, "classification": kind,
                     "heading_located": located, "rule_review": "not-assessed"})
        if clause == "I":
            ended = True
            break
    if not ended:
        raise ValueError("TOC incomplete: Annex I endpoint absent")
    return rows


def ieee1364_audit(argv):
    """Local licensed-source heading worklist, never a conformance denominator.

    No source body text is written. Requires the user's local IEEE PDF and
    Poppler. The table of contents locates headings; it does not enumerate
    atomic rules. `tests/fixtures/ieee1364/CLAUSES.tsv` was cut from this
    output and is reviewed, never regenerated.
    """
    parser = argparse.ArgumentParser(prog="conformance.py ieee1364-audit", description=ieee1364_audit.__doc__)
    parser.add_argument("--pdf", type=Path, default=ROOT / "docs/1364-2005.pdf")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        digest = hashlib.sha256(args.pdf.read_bytes()).hexdigest()
        if digest != IEEE_SHA256:
            raise ValueError("source hash differs; verify edition/pagination before updating provenance")
        text = subprocess.run(["pdftotext", "-layout", str(args.pdf), "-"],
                              check=True, capture_output=True, text=True).stdout
        rows = worklist(text)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("IEEE source audit: " + str(exc), file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"source_sha256": digest, "warning": "Heading worklist only; no rule coverage claim",
                          "sections": rows}, indent=2))
    else:
        print("Heading worklist only; no rule coverage claim. SHA256 " + digest)
        for row in rows:
            print("\t".join((row["id"], str(row["pdf_page"]), row["classification"],
                              "located" if row["heading_located"] else "REVIEW-ANCHOR", row["title"])))
    return 1 if any(not row["heading_located"] for row in rows) else 0


SUBCOMMANDS["ieee1364-audit"] = ieee1364_audit


# ---------------------------------------------------------------------------
# keywords: Table B.1 against the PDF, and the exhaustive spelling fixtures
# ---------------------------------------------------------------------------

class KeywordTable(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_table = False
        self.in_code = False
        self.words = []

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.in_table = True
        if tag == "code":
            self.in_code = True

    def handle_endtag(self, tag):
        if tag == "table":
            self.in_table = False
        if tag == "code":
            self.in_code = False

    def handle_data(self, data):
        if self.in_table and self.in_code:
            self.words.extend(data.split())


def keyword_inventory():
    if hashlib.sha256(LRM_PDF.read_bytes()).hexdigest() != LRM_SHA256:
        raise ValueError("Source PDF changed: re-audit Table B.1 pages and correction")
    source = subprocess.run([
        "pdftotext", "-f", "400", "-l", "401", "-layout",
        str(LRM_PDF), "-",
    ], check=True, capture_output=True, text=True).stdout
    words = []
    for line in source.splitlines():
        if re.fullmatch(r"\s*[a-z][a-z_0-9]*(?:\s+[a-z][a-z_0-9]*){0,2}\s*", line):
            words.extend(line.split())
    # Visually confirmed source-table defect, also labeled in the HTML.
    if words.count("negedgenmos") != 1:
        raise ValueError("Source table changed: re-audit the negedgenmos correction")
    words.remove("negedgenmos")
    words.extend(["negedge", "nmos"])
    if len(words) != len(set(words)):
        raise ValueError("Duplicate source keyword")
    html = KeywordTable()
    html.feed((ROOT / "docs/annex-b-keywords.html").read_text())
    if len(html.words) != len(set(html.words)):
        raise ValueError("Duplicate HTML keyword")
    if set(words) != set(html.words):
        raise ValueError(f"PDF-only: {set(words) - set(html.words)}; "
                         f"HTML-only: {set(html.words) - set(words)}")
    return sorted(words)


def keyword_fixture(words, mode):
    entries = []
    for word in words:
        if mode == "escaped":
            entries.append(("\\" + word + " ", "escaped " + word))
        else:
            entries.extend([(word.upper(), "uppercase " + word),
                            (word[0].upper() + word[1:], "initial-uppercase " + word)])
    lines = [
        "// Generated by tools/conformance.py keywords --fixture " + mode,
        "// Source: VAMS-2023 Table B.1, physical pages 400-401;",
        "// the PDF's negedgenmos defect is split into negedge and nmos.",
        "// Annex B and 2.8.2 reserve nonescaped lowercase spellings only.",
        "// Each legal identifier is assigned its one-based inventory position.",
        "// All assignments precede all observations: name aliasing cannot hide",
        "// behind an immediate assignment/read pair. Each expected integer is",
        "// independently fixed by the generator, not read from the compiler.",
        "// This tests variable identifiers, not all identifier grammar positions.",
        "// Reads use a plain temporary so macro-argument whitespace processing",
        "// cannot hide the keyword-name test; see KEY-MACRO-001 in the audit.",
        "//! lrm B", "//! lrm 2.8.2", f"//! checks {len(entries)}", "//! print none",
        '`include "check.vh"', f"module audit_all_{mode}_keywords(p, n);",
        "    inout p, n;", "    electrical p, n;",
    ]
    lines += [f"    real {name};" for name, _ in entries]
    lines += ["    real observed;"]
    lines += ["    analog begin"]
    lines += [f"        {name} = {i}.0;" for i, (name, _) in enumerate(entries, 1)]
    for i, (name, label) in enumerate(entries, 1):
        lines += [f"        observed = {name};",
                  f'        `CHECKX("{label}", observed, {i}.0);']
    lines += ["        I(p,n) <+ 0.0;", "    end", "endmodule"]
    return "\n".join(lines) + "\n"


def keywords(argv):
    """Audit Table B.1 against the PDF; emit exhaustive spelling fixtures to stdout.

    This checks the spelling inventory, not implementation of keyword constructs
    or every grammar position. No compiler token table is used as the oracle.
    """
    parser = argparse.ArgumentParser(prog="conformance.py keywords", description=keywords.__doc__)
    parser.add_argument("--fixture", choices=["escaped", "case"])
    parser.add_argument("--check-fixtures", action="store_true")
    args = parser.parse_args(argv)
    words = keyword_inventory()
    if args.fixture:
        print(keyword_fixture(words, args.fixture), end="")
        return 0
    if args.check_fixtures:
        for mode in ["escaped", "case"]:
            path = ROOT / f"tests/fixtures/annex_b_keywords/audit_all_{mode}_keywords.va"
            if path.read_text() != keyword_fixture(words, mode):
                raise SystemExit(f"Fixture drift: {path}")
    print(f"Table B.1: {len(words)} distinct corrected spellings; PDF and HTML sets match.")
    return 0


SUBCOMMANDS["keywords"] = keywords


# ---------------------------------------------------------------------------
# figures: the LRM's figures in docs/figures, cropped from the pinned PDF
# ---------------------------------------------------------------------------

# Requires Poppler's pdftoppm. Coordinates are PDF points measured from the
# top-left of a physical page: (physical page, left, top, width, height).
# Crops include the original caption. Adding an entry requires visual
# comparison against the source page. Direct PDF rasterization preserves
# patterned guide lines that were lost in a pdftocairo-SVG/librsvg round trip
# during visual validation.
FIG_SCALE = 3  # 216 dpi; lossless PNG, no resampling or generative processing.

# Chapters 1-9 (`lrm-figure-<n>.png`).
LRM_FIGURES = {
    "1-1": (15, 152, 349, 310, 150),
    "1-2": (16, 163, 403, 285, 104),
    "1-3": (17, 88, 312, 436, 262),
    "3-1": (62, 180, 78, 252, 154),
    "3-2": (62, 184, 293, 244, 150),
    "4-3": (81, 135, 78, 345, 290),
    "4-4": (85, 88, 175, 437, 220),
    "4-5": (85, 127, 565, 359, 137),
    "4-6": (86, 136, 103, 340, 130),
    "4-7": (87, 150, 439, 310, 154),
    "4-8": (88, 150, 140, 310, 154),
    "4-9": (88, 150, 332, 310, 153),
    "4-10": (89, 150, 90, 310, 152),
    "4-11": (89, 150, 280, 310, 150),
    "4-12": (90, 150, 90, 310, 152),
    "4-13": (91, 148, 590, 316, 114),
    "4-14": (104, 125, 202, 360, 352),
    "5-1": (113, 130, 404, 352, 131),
    "5-2": (114, 130, 79, 352, 210),
    "5-3": (124, 105, 551, 402, 143),
    "5-4": (125, 119, 127, 374, 146),
    "5-5": (126, 128, 79, 355, 225),
    "5-6": (140, 88, 93, 436, 144),
    "7-1": (178, 105, 390, 402, 206),
    "7-2": (187, 111, 294, 390, 242),
    "7-3": (188, 87, 463, 500, 258),
    "7-4": (189, 87, 258, 500, 258),
    "7-5": (190, 87, 162, 500, 260),
    "7-6": (197, 87, 150, 500, 262),
    "7-7": (199, 152, 78, 308, 600),
    # One source drawing has an empty 7-8 caption above and the 7-9 caption
    # below. Keep both captions in this single crop, not duplicate drawings.
    "7-9": (201, 119, 67, 374, 465),
    "7-10": (202, 117, 210, 378, 458),
    "7-11": (212, 87, 78, 438, 380),
    "8-1": (214, 158, 78, 296, 469),
    "8-2": (216, 158, 78, 296, 516),
    "8-3": (220, 130, 78, 352, 202),
    "8-4": (221, 90, 238, 470, 310),
    "8-5": (222, 90, 90, 471, 309),
    "8-6": (224, 90, 90, 470, 292),
    "8-7": (225, 88, 98, 474, 280),
    "9-1": (268, 160, 86, 305, 214),
    "9-2": (268, 137, 463, 370, 222),
    "9-3": (276, 64, 403, 484, 141),
    "9-4": (277, 150, 417, 312, 216),
}

# Chapter 6 (`lrm-figure-6-<n>.png`).
CH6_FIGURES = {
    "6-1": (151, 190, 247, 232, 132),
    "6-2": (174, 103, 300, 423, 110),
}

# Chapter 11 source graphs (`ch11-<name>.png`). All source pages were visually
# checked on 2026-09-23. Broad model-page crops retain the original notes as
# well as edges; HTML also transcribes those notes.
CH11_CROPS = {"figure-11-1": (288, 110, 493, 390, 158),
              "legend-11-5-1-2": (293, 85, 68, 475, 660),
              "legend-11-5-3": (294, 85, 68, 475, 660)}
CH11_CROPS.update({f"model-page-{p}": (p, 60, 60, 500, 668)
                   for p in range(296, 322)})

# Annex E figure and table crops (`annex-e-<name>.png`).
ANNEX_E_CROPS = {
    "figure-e-1": (415, 220, 584, 175, 120),
    "table-e-1-a": (417, 78, 242, 455, 400),
    "table-e-1-b": (418, 78, 68, 455, 555),
    "table-e-1-c": (419, 78, 68, 455, 590),
}

# set: (crops, output prefix, message when the PDF changed, report line)
FIGURE_SETS = {
    "lrm": (LRM_FIGURES, "lrm-figure-", "Source PDF changed: re-audit page and crop coordinates first",
            "Figure {name}: PDF page {page}, box {left} {top} {width} {height}"),
    "ch6": (CH6_FIGURES, "lrm-figure-", "Source PDF changed: re-audit crop coordinates first",
            "Figure {name}: PDF page {page}, box {left} {top} {width} {height}"),
    "ch11": (CH11_CROPS, "ch11-", "Source PDF changed: re-audit every crop first",
             "{name}: physical {page}; rectangle {left} {top} {width} {height}"),
    "annex-e": (ANNEX_E_CROPS, "annex-e-", "Source changed: visually re-audit rectangles",
                "{name}: physical {page}; rectangle {left} {top} {width} {height}"),
}


def figures(argv):
    """Re-crop the LRM figures in docs/figures from docs/VAMS-LRM-2023.pdf.

        tools/conformance.py figures [lrm|ch6|ch11|annex-e ...]   # default: all
    """
    names = argv or list(FIGURE_SETS)
    for name in names:
        if name not in FIGURE_SETS:
            print(f"usage: conformance.py figures [{'|'.join(FIGURE_SETS)} ...]", file=sys.stderr)
            return 2
    destination = ROOT / "docs/figures"
    for name in names:
        crops, prefix, changed, report = FIGURE_SETS[name]
        if hashlib.sha256(LRM_PDF.read_bytes()).hexdigest() != LRM_SHA256:
            raise SystemExit(changed)
        destination.mkdir(exist_ok=True)
        for crop, (page, left, top, width, height) in crops.items():
            subprocess.run([
                "pdftoppm", "-f", str(page), "-l", str(page), "-singlefile",
                "-r", str(72 * FIG_SCALE), "-x", str(left * FIG_SCALE),
                "-y", str(top * FIG_SCALE), "-W", str(width * FIG_SCALE),
                "-H", str(height * FIG_SCALE), "-png", str(LRM_PDF), str(destination / f"{prefix}{crop}"),
            ], check=True)
            print(report.format(name=crop, page=page, left=left, top=top, width=width, height=height))
    return 0


SUBCOMMANDS["figures"] = figures


# ---------------------------------------------------------------------------
# comments: the clauses the code says it implements or refuses, against the
# clauses the fixtures cite. A pointer for a reader, NOT a measure.
# ---------------------------------------------------------------------------

# A standard named in a comment, optionally followed by a clause number:
# `IEEE 1364-2005 §9.2.2`, `IEEE 12.8.2`, `1364 §17`, `AMS 9.7.3`, `LRM §4.3`.
# A bare `§9.7.3` takes the standard the line last named, the LRM by default
# (VerA's comments write a bare § for this LRM and name IEEE 1364 when they
# mean it). Only the first number of a range or list after a standard word is
# read (`§§17-18` reads 17).
CITE = re.compile(
    r"(?P<std>\bIEEE(?:\s+Std)?(?:\s+1364(?:-2005)?)?|\b1364(?:-2005)?\b|\bVAMS(?:-2023)?\b|\bAMS\b|\bLRM\b)"
    r"(?:\s*§*\s*(?P<n1>[0-9]+(?:\.[0-9]+)*|[A-I](?:\.[0-9]+)+)\b)?"
    r"|§+\s*(?P<n2>[0-9]+(?:\.[0-9]+)*|[A-I](?:\.[0-9]+)*)\b")


def comment_cites(text):
    """(standard, clause, line number, named) for every clause a `//` comment
    cites; `named` is false for a bare § on a line that names no standard.
    A `\\\\` line is device text the compiler emits, not a comment."""
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("\\\\") or "//" not in line:
            continue
        std, named = "ams", False
        for m in CITE.finditer(line[line.index("//"):]):
            if m.group("std"):
                std = "ieee" if m.group("std").startswith(("IEEE", "1364")) else "ams"
                named = True
                if m.group("n1"):
                    out.append((std, m.group("n1"), no, True))
            else:
                out.append((std, m.group("n2"), no, named))
    return out


def under(child, parent):
    """Is clause `child` the clause `parent` or one of its subclauses?"""
    return child == parent or child.startswith(parent + ".")


def fixture_cites():
    """{(standard, clause): {"pos": [paths], "neg": [paths]}} from the
    fixtures' tags, the polarity rules `--coverage` and `test-1364 --coverage`
    use: a file with a `//! reject` (or `// digital-runner: reject`) cites
    negatively; a `.c` application counts only if `build.zig`'s `vpi_runs`
    runs it, and polarity is per line (`lrm-reject`, `inherited-reject`)."""
    runs = set(re.findall(r'\.c = "([^"]+\.c)"', (ROOT / "build.zig").read_text()))
    cites = {}

    def add(std, clause, side, path):
        cites.setdefault((std, clause), {"pos": [], "neg": []})[side].append(path)

    root = ROOT / "tests/fixtures"
    for path in sorted(root.rglob("*")):
        if path.suffix not in (".va", ".v", ".c") or not path.is_file():
            continue
        rel = str(path.relative_to(ROOT))
        if path.suffix == ".c" and rel not in runs:
            continue
        source = path.read_text(errors="replace")
        neg = path.suffix != ".c" and re.search(r"(?m)^\s*(//! reject|// digital-runner: reject)", source) is not None
        for raw in source.split("\n"):
            line = raw.strip()
            if not line.startswith("//!"):
                continue
            words = line[3:].strip()
            m = re.match(r"(lrm|lrm-reject)\s+(?:annex\s+)?(\S+)", words)
            if m:
                side = "neg" if neg or m.group(1) == "lrm-reject" else "pos"
                add("ams", m.group(2), side, rel)
                continue
            m = re.match(r"(inherited|inherited-reject) IEEE 1364-2005 (.*)", words)
            if m:
                side = "neg" if neg or m.group(1) == "inherited-reject" else "pos"
                for clause in re.split(r"[ ,]+", m.group(2).split("(")[0].strip()):
                    if clause:
                        add("ieee", clause, side, rel)
    return cites


def refusals():
    """{(standard, clause): [codes]} for every error code in lib/diag_code.zig
    whose catalogue row cites a clause: the code's refusal is the code's claim
    about that clause."""
    out, codes = {}, []
    for line in (ROOT / "lib/diag_code.zig").read_text().split("\n"):
        m = re.match(r"\s*(\.[EW]\d{4}(?:\s*,\s*\.[EW]\d{4})*)\s*=>", line)
        if m:
            codes = re.findall(r"[EW]\d{4}", m.group(1))
            continue
        m = re.match(r'\s*\.lrm = "([^"]*)"', line)
        if not m:
            continue
        for part in m.group(1).split(" / "):
            part = part.strip()
            std = "ieee" if part.startswith("IEEE 1364-2005 ") else "ams"
            clause = part.removeprefix("IEEE 1364-2005 ")
            for code in codes:
                if clause and code.startswith("E"):
                    out.setdefault((std, clause), []).append(code)
        codes = []
    return out


def clause_kinds():
    """{(standard, clause): kind} from every CLAUSES.tsv: the CLAUSE-AUDIT.md
    §5 classifications (`-` is an ordinary clause in the IEEE list)."""
    out = {}
    for path in sorted((ROOT / "tests/fixtures").rglob("CLAUSES.tsv")):
        std = "ieee" if "ieee1364" in path.parts else "ams"
        for line in path.read_text().split("\n"):
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) > 1 and cells[1] != "-":
                out[(std, cells[0].strip())] = cells[1].strip()
    return out


def comments(argv):
    """Code-comment clause signal: which clauses the code's comments cite and
    which its error codes refuse, cross-checked against the fixtures' tags and
    the CLAUSE-AUDIT.md §5 classifications (CLAUSES.tsv).

        tools/conformance.py comments          # counts, then every row
        tools/conformance.py comments --counts # counts only

    NOT a measure. It moves none of A, B or C and reports counts per category,
    never a percentage: it is pattern matching over prose, so a row is a place
    to look, not a finding.
    """
    counts_only = "--counts" in argv
    ams_known = set(html_sections(ROOT)[0])
    ieee_known = set()
    for line in (ROOT / "tests/fixtures/ieee1364/CLAUSES.tsv").read_text().split("\n"):
        if line.strip() and not line.startswith("#"):
            ieee_known.add(line.split("\t")[0].strip())
    known = {"ams": ams_known, "ieee": ieee_known}
    audit_text = (ROOT / "docs/CLAUSE-AUDIT.md").read_text()

    # The code's claims: comment cites in lib/ and src/.
    sites, unresolved, nfiles = {}, {"ams": 0, "ieee": 0}, 0
    for path in sorted(list((ROOT / "lib").rglob("*.zig")) + list((ROOT / "src").rglob("*.zig"))):
        rel = str(path.relative_to(ROOT))
        found = comment_cites(path.read_text())
        nfiles += bool(found)
        for std, clause, no, named in found:
            # A bare § the LRM has no heading for, on a line naming no
            # standard, is read as IEEE 1364 when that has the heading: the
            # digital engine's comments continue an `IEEE 1364-2005` list
            # onto the next line.
            if not named and clause not in known["ams"] and clause in known["ieee"]:
                std = "ieee"
            if clause not in known[std]:
                unresolved[std] += 1
                continue
            sites.setdefault((std, clause), []).append(f"{rel}:{no}")
    refused = {k: v for k, v in refusals().items() if k[1] in known[k[0]]}
    fixtures = fixture_cites()
    kinds = clause_kinds()

    def evidence(key, side):
        std, clause = key
        return [p for (s, c), sides in fixtures.items() if s == std and under(c, clause) for p in sides[side]]

    def mentioned(key):
        std, clause = key
        return any(s == std and under(c, clause) for (s, c) in list(sites) + list(refused))

    def in_audit(key):
        std, clause = key
        return re.search(r"§" + re.escape(clause) + r"(?![\d.]*\d)", audit_text) is not None

    order = lambda k: (k[0], sort_key(k[1]))
    implemented = sorted((k for k in sites if not evidence(k, "pos")), key=order)
    unpinned = sorted((k for k in refused if not evidence(k, "neg")), key=order)
    orphan = sorted((k for k in fixtures if k[1] in known[k[0]] and not mentioned(k)), key=order)
    std_name = {"ams": "LRM", "ieee": "IEEE 1364-2005"}

    def split(keys):
        return " · ".join(f"{std_name[s]} {sum(1 for k in keys if k[0] == s)}" for s in ("ams", "ieee"))

    print("Code-comment clause signal — NOT a measure: it moves none of A, B or C.")
    print("Pattern matching over comments; every row is a place to look, not a finding.")
    print("A bare § is this LRM unless its line names IEEE 1364, or only IEEE 1364 has the")
    print("heading. A clause matches its own cites and its subclauses' (code §4.5 is met by")
    print("a fixture citing 4.5.4). A cite naming no heading (an internal document's §, a")
    print("typo) is counted, never listed.")
    print()
    print(f"read: {sum(len(v) for v in sites.values())} comment cites of {len(sites)} clauses in {nfiles} files "
          f"under lib/ and src/ ({unresolved['ams']} LRM and {unresolved['ieee']} IEEE cites name no heading); "
          f"{sum(len(v) for v in refused.values())} error codes citing {len(refused)} clauses (lib/diag_code.zig); "
          f"{len(fixtures)} clauses cited by fixtures")
    print()
    print(f"1. cited in code, no positive fixture under it:   {len(implemented):4}  ({split(implemented)})")
    print(f"2. refused by an error code, no reject fixture:   {len(unpinned):4}  ({split(unpinned)})")
    print(f"3. cited by fixtures, no code comment or code:    {len(orphan):4}  ({split(orphan)})")
    if counts_only:
        return 0

    def tags(key):
        kind = kinds.get(key)
        return (f"  [CLAUSES.tsv: {kind}]" if kind else "") + ("  [in CLAUSE-AUDIT.md]" if in_audit(key) else "")

    def where(paths):
        return ", ".join(paths[:3]) + (f" (+{len(paths) - 3})" if len(paths) > 3 else "")

    print("\n## 1. Cited in code, no positive fixture cites the clause or a subclause")
    for k in implemented:
        neg = evidence(k, "neg")
        print(f"{std_name[k[0]]} §{k[1]}\t{where(sites[k])}" + (f"\treject fixtures only: {len(neg)}" if neg else "") + tags(k))
    print("\n## 2. Refused by an error code, no reject fixture cites the clause or a subclause")
    for k in unpinned:
        print(f"{std_name[k[0]]} §{k[1]}\t{' '.join(refused[k])}" + tags(k))
    print("\n## 3. Cited by fixtures, no comment or error code in lib/ or src/ cites the clause or a subclause")
    for k in orphan:
        f = fixtures[k]
        print(f"{std_name[k[0]]} §{k[1]}\t{where(f['pos'] + f['neg'])}" + tags(k))
    return 0


SUBCOMMANDS["comments"] = comments


# ---------------------------------------------------------------------------
# selftest: regression checks for the subcommands above and for the LRM text
# they read. Documentation integrity, not language conformance: no fixture
# earns credit here, and none of these runs the compiler.
# ---------------------------------------------------------------------------

import unittest
from unittest.mock import patch
from types import SimpleNamespace


class WorklistTests(unittest.TestCase):
    """lrm-audit's heading, token and HTML rules."""

    def test_heading_forms(self):
        for title, expected in (("2. Lexical conventions", "2"),
                                ("2.6.1 Integer constants", "2.6.1"),
                                ("Annex C (normative)", "C"),
                                ("C.3 Lexical conventions", "C.3"),
                                ("Table 2-2: Escapes", None)):
            self.assertEqual(heading(title), expected)

    def test_tokens_preserve_semantically_significant_symbols(self):
        self.assertEqual(tokens("first\n word"), tokens("first word"))
        self.assertNotEqual(tokens("a <= b"), tokens("a < b"))
        self.assertNotEqual(tokens("1M"), tokens("1m"))
        self.assertNotEqual(tokens("x ** 2"), tokens("x * 2"))

    def test_no_lossy_hyphen_or_compatibility_folding(self):
        self.assertEqual(tokens("Verilog-\nAMS"), tokens("Verilog-AMS"))
        self.assertNotEqual(tokens("Verilog-\nAMS"), tokens("VerilogAMS"))
        self.assertNotEqual(tokens("a-\nb"), tokens("ab"))
        self.assertNotEqual(tokens("x²"), tokens("x2"))
        self.assertNotEqual(tokens("ﬁ"), tokens("fi"))
        self.assertNotEqual(tokens("a­b"), tokens("ab"))

    def test_html_excludes_navigation_but_keeps_tables_and_subheadings(self):
        parser = ChapterHTML()
        parser.feed('<head><title>ignored</title></head><nav>ignored</nav>'
                    '<h1>2. Lexical conventions</h1><h2>2.7 Strings</h2>'
                    '<p>A &lt; B</p><h3>Table 2-2</h3>'
                    '<table><tr><td>escape</td><td>value</td></tr></table>')
        text = parser.sections['2.7']['text']
        self.assertIn('A < B', text)
        self.assertIn('Table 2-2', text)
        self.assertIn('escape value', text)
        self.assertNotIn('ignored', text)

    def test_duplicate_html_heading_is_visible(self):
        parser = ChapterHTML()
        parser.feed('<h2>2.7 Strings</h2><p>first</p>'
                    '<h2>2.7 Strings again</h2>')
        self.assertEqual(parser.duplicates, ['2.7'])

    @patch.object(subprocess, "run")
    def test_pdf_front_matter_footer_and_numeric_table_cells(self, run):
        run.return_value = SimpleNamespace(stdout=(
            'Contents\n2. Lexical conventions .... 11\f'
            '1. Verilog-AMS introduction\n1.1 Scope\nsource text\n'
            '2. Lexical conventions\n2.7 Strings\n377\nbyte boundary\n'
            '12\nCopyright © 2024 Accellera\f'))
        sections, _ = pdf_sections('source.pdf')
        self.assertEqual(list(sections), ['1', '1.1', '2', '2.7'])
        self.assertIn('377', sections['2.7']['text'])
        self.assertNotIn('12\n', sections['2.7']['text'])
        self.assertEqual(sections['2.7']['page'], 2)


class InheritedWorklistTests(unittest.TestCase):
    """ieee1364-audit's table-of-contents reader, on synthetic text (no PDF)."""

    def test_namespace_page_anchor_and_informative_distinction(self):
        text = ("Contents\n1. Overview ........ 1\n1.1 Scope ........ 1\n"
                "Annex I (informative) Bibliography ........ 2\f"
                "1. Overview\n1.1 Scope\fAnnex I\n(informative)\f")
        rows = worklist(text)
        self.assertEqual([r["id"] for r in rows],
                         ["IEEE1364-2005:1", "IEEE1364-2005:1.1", "IEEE1364-2005:I"])
        self.assertEqual(rows[0]["pdf_page"], 2)
        self.assertEqual(rows[-1]["classification"], "informative")
        self.assertTrue(all(r["heading_located"] for r in rows))
        self.assertTrue(all(r["rule_review"] == "not-assessed" for r in rows))

    def test_missing_anchor_is_not_verified(self):
        text = ("Contents\n1. Overview ........ 1\n1.2 Missing ........ 1\n"
                "Annex I (informative) Bibliography ........ 2\f"
                "1. Overview\fAnnex I\f")
        self.assertFalse(worklist(text)[1]["heading_located"])

    def test_incomplete_toc_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            worklist("Contents\n1. Overview ........ 1\f1. Overview\f")

    def test_known_contents_error_keeps_original_page(self):
        pages = [""] * 215
        pages[0] = ("Contents\n1. Overview ........ 1\n"
                    "14.2.1 Module path restrictions ........ 212\n"
                    "Annex I (informative) Bibliography ........ 214")
        pages[1] = "1. Overview"
        pages[213] = "14.2.1 Module path restrictions"
        pages[214] = "Annex I"
        row = worklist("\f".join(pages))[1]
        self.assertEqual(row["toc_printed_page"], 212)
        self.assertEqual(row["printed_page"], 213)
        self.assertEqual(row["pdf_page"], 214)
        self.assertTrue(row["heading_located"])

    def test_deprecated_is_not_silently_normative_or_closed(self):
        text = ("Contents\n1. Overview ........ 1\n21. Removed ........ 2\n"
                "Annex I (informative) Bibliography ........ 3\f"
                "1. Overview\f21. Removed\fAnnex I\f")
        self.assertEqual(worklist(text)[1]["classification"], "deprecated-removed")


class KeywordInventory(unittest.TestCase):
    """keywords: the independent inventory and its fixture generator."""

    def test_editorial_notes_do_not_add_keywords(self):
        parser = KeywordTable()
        parser.feed('<table><tr><td><code>if</code></td>'
                    '<td><code>module</code></td></tr></table>'
                    '<p>Not a keyword: <code>negedgenmos</code></p>')
        self.assertEqual(parser.words, ['if', 'module'])

    def test_escaped_generation_terminates_names_and_pins_observation_count(self):
        source = keyword_fixture(['analog', 'if'], 'escaped')
        self.assertIn('//! checks 2\n', source)
        self.assertIn('real \\analog ;', source)
        self.assertIn('observed = \\if ;', source)
        self.assertLess(source.index('\\if  = 2.0;'), source.index('observed ='))
        self.assertIn('`CHECKX("escaped if", observed, 2.0);', source)
        self.assertEqual(source.count('`CHECKX('), 2)

    def test_case_variants_have_independent_values(self):
        source = keyword_fixture(['analog', 'if'], 'case')
        self.assertIn('//! checks 4\n', source)
        for name, value in [('ANALOG', 1), ('Analog', 2), ('IF', 3), ('If', 4)]:
            self.assertIn(f'{name} = {value}.0;', source)
            self.assertIn(f'observed = {name};', source)
        self.assertLess(source.index('If = 4.0;'), source.index('observed ='))
        self.assertEqual(source.count('`CHECKX('), 4)


class FigureImages(HTMLParser):
    """Every <img>'s attributes, every id, and how many inline <svg>s."""

    def __init__(self):
        super().__init__()
        self.images = []
        self.ids = []
        self.figures = set()
        self.svg_count = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "img":
            self.images.append(attrs)
        if tag == "svg":
            self.svg_count += 1
        if tag == "figure":
            self.figures.add(attrs.get("id"))
        if "id" in attrs:
            self.ids.append(attrs["id"])


def png_size(data):
    return struct.unpack(">II", data[16:24])


class SourceFigures(unittest.TestCase):
    """figures: structural guards for the PDF figure assets; visual fidelity is
    reviewed separately."""

    def test_source_revision(self):
        self.assertEqual(hashlib.sha256(LRM_PDF.read_bytes()).hexdigest(), LRM_SHA256)

    def test_chapter_one_figures_and_convention_colors(self):
        expected = {"1-1", "1-2", "1-3"}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("1-")}, expected)
        html = (ROOT / "docs/ch1-intro.html").read_text()
        self.assertIn('.syntax b { color: #c00000; }', html)
        self.assertIn('.syntax.extension { color: #2020b0; }', html)
        self.assertIn('<div class="syntax extension">connectrules_declaration', html)

    def test_chapter_five_uses_all_source_figures(self):
        # These redraws previously changed open probe paths into wires and
        # moved the timing-event dot. Guard against silently reintroducing
        # inline substitutes; visual comparison remains a separate review.
        expected = {f"5-{n}" for n in range(1, 7)}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("5-")}, expected)
        parser = FigureImages()
        parser.feed((ROOT / "docs/ch5-analog.html").read_text())
        self.assertEqual(parser.svg_count, 0)
        for key in expected:
            self.assertEqual(parser.ids.count(f"figure-{key}"), 1)

    def test_chapter_six_crop_bounds_png_and_accessible_html(self):
        self.assertEqual(set(CH6_FIGURES), {"6-1", "6-2"})
        parser = FigureImages()
        parser.feed((ROOT / "docs/ch6-hierarchy.html").read_text())
        images = {i.get("src"): i for i in parser.images}
        for figure, (page, left, top, width, height) in CH6_FIGURES.items():
            self.assertIn(page, (151, 174))
            self.assertGreaterEqual(min(left, top), 0)
            self.assertGreater(min(width, height), 0)
            self.assertLessEqual(left + width, 612)
            self.assertLessEqual(top + height, 792)
            path = f"figures/lrm-figure-{figure}.png"
            data = (ROOT / "docs" / path).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(png_size(data), (width * FIG_SCALE, height * FIG_SCALE))
            self.assertIn(f"figure-{figure}", parser.figures)
            attrs = images[path]
            self.assertIn(f"Source Figure {figure}", attrs["alt"])
            self.assertEqual(int(attrs["width"]), width * FIG_SCALE)
            self.assertEqual(int(attrs["height"]), height * FIG_SCALE)

    def test_chapter_seven_preserves_shared_figure_captions(self):
        expected = {f"7-{n}" for n in range(1, 12)} - {"7-8"}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("7-")}, expected)
        parser = FigureImages()
        parser.feed((ROOT / "docs/ch7-mixed-signal.html").read_text())
        self.assertEqual(parser.svg_count, 0)
        # 7-8 is a source caption above the same drawing captioned 7-9 below.
        # Both remain addressable, without fabricating a separate image.
        for n in range(1, 12):
            self.assertEqual(parser.ids.count(f"figure-7-{n}"), 1)
        matches = [i for i in parser.images if i.get("src") == "figures/lrm-figure-7-9.png"]
        self.assertEqual(len(matches), 1)

    def test_chapter_nine_source_figures(self):
        expected = {f"9-{n}" for n in range(1, 5)}
        self.assertEqual({key for key in LRM_FIGURES if key.startswith("9-")}, expected)
        parser = FigureImages()
        parser.feed((ROOT / "docs/ch9-system.html").read_text())
        for key in expected:
            self.assertEqual(parser.ids.count(f"figure-{key}"), 1)
            filename = f"figures/lrm-figure-{key}.png"
            matches = [item for item in parser.images if item.get("src") == filename]
            self.assertEqual(len(matches), 1)
            self.assertTrue(matches[0].get("alt"))
            data = (ROOT / "docs" / filename).read_bytes()
            _, _, _, width, height = LRM_FIGURES[key]
            self.assertEqual(png_size(data), (width * 3, height * 3))

    def test_crops_are_inside_source_pages(self):
        for figure, (page, x, y, width, height) in LRM_FIGURES.items():
            with self.subTest(figure=figure):
                self.assertGreater(page, 0)
                self.assertLessEqual(page, 442)
                self.assertGreaterEqual(x, 0)
                self.assertGreaterEqual(y, 0)
                self.assertGreater(width, 0)
                self.assertGreater(height, 0)
                self.assertLessEqual(x + width, 612)
                self.assertLessEqual(y + height, 792)

    def test_assets_and_html_references(self):
        for figure, (_, _, _, width, height) in LRM_FIGURES.items():
            with self.subTest(figure=figure):
                filename = f"figures/lrm-figure-{figure}.png"
                data = (ROOT / "docs" / filename).read_bytes()
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(data[12:16], b"IHDR")
                self.assertEqual(png_size(data), (width * 3, height * 3))
                chapter = figure.split("-")[0]
                paths = list((ROOT / "docs").glob(f"ch{chapter}-*.html"))
                self.assertEqual(len(paths), 1)
                parser = FigureImages()
                parser.feed(paths[0].read_text())
                matches = [i for i in parser.images if i.get("src") == filename]
                self.assertEqual(len(matches), 1)
                self.assertTrue(matches[0].get("alt"))
                self.assertEqual(parser.ids.count(f"figure-{figure}"), 1)

    def test_chapter_eleven_source_and_assets(self):
        # Documentation integrity only: this is not an executed VPI test.
        parsed = FigureImages()
        parsed.feed((ROOT / "docs/ch11-vpi.html").read_text())
        self.assertEqual(len(parsed.ids), len(set(parsed.ids)))
        expected = {f"figures/ch11-{name}.png" for name in CH11_CROPS}
        self.assertEqual({item["src"] for item in parsed.images}, expected)
        for item in parsed.images:
            self.assertTrue(item.get("alt"))
            data = (ROOT / "docs" / item["src"]).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            name = Path(item["src"]).stem.removeprefix("ch11-")
            width, height = CH11_CROPS[name][-2:]
            self.assertEqual(png_size(data), (width * 3, height * 3))
        for clause in range(1, 26):
            self.assertIn(f"s11-6-{clause}", parsed.ids)

    def test_annex_e_source_links_and_dimensions(self):
        # Documentation integrity, not primitive simulation evidence.
        html = (ROOT / "docs/annex-e-spice.html").read_text()
        for name, (_, _, _, width, height) in ANNEX_E_CROPS.items():
            relative = f"figures/annex-e-{name}.png"
            self.assertIn(f'src="{relative}"', html)
            data = (ROOT / "docs" / relative).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(png_size(data), (width * 3, height * 3))


class SyntaxText(HTMLParser):
    """The text of every `<div class="syntax">` display, entities decoded."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.parts = []
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        if tag == "div":
            if self.depth:
                self.depth += 1
            elif "syntax" in dict(attrs).get("class", "").split():
                self.depth = 1
                self.parts = []

    def handle_endtag(self, tag):
        if tag == "div" and self.depth:
            self.depth -= 1
            if not self.depth:
                self.blocks.append("".join(self.parts))

    def handle_data(self, data):
        if self.depth:
            self.parts.append(data)


def syntax_text(source):
    parser = SyntaxText()
    parser.feed(source)
    parser.close()
    if parser.depth:
        raise ValueError("Unclosed syntax display")
    return parser.blocks


# The rendered Chapter 4 syntax text from root HTML SHA256
# c452aae6c5868af5538ce84d989bb3ae83b51e3047b9157784190688dca188fe.
CH4_SYNTAX_SHA256 = "c206b78ed2fa1dbba040bb45b5056ecb6ce58f10dfce7c977f8f595a0f6f4ff3"


class LrmSource(unittest.TestCase):
    """Bounded source-review guards on docs/*.html, not grammar completeness
    proof and not proof of whole-chapter source fidelity."""

    def test_annex_a_signed_base_separates_terminals_from_meta_symbols(self):
        page = (ROOT / "docs/annex-a-syntax.html").read_text()
        for base in "dDbBoOhH":
            spelling = "<b>'</b>[<b>s</b>|<b>S</b>]<b>" + base + "</b>"
            self.assertIn(spelling, page)
            self.assertEqual(html.unescape(re.sub(r"<[^>]*>", "", spelling)), "'[s|S]" + base)
        self.assertIn("lexical character classes", page)
        self.assertIn("Editorial source note", page)

    def test_ch2_comment_delimiters_are_literals_not_repetition_notation(self):
        page = (ROOT / "docs/ch2-lexical.html").read_text()
        block = re.search(r'<div class="syntax">(.*?)</div>', page, re.S).group(1)
        # AMS2023 physical24/printed11, visually reviewed2026-09-23.
        self.assertEqual(re.findall(r"<b>(.*?)</b>", block), ["//", "/*", "*/"])
        self.assertIn("one_line_comment ::= <b>//</b> comment_text \\n", block)
        self.assertIn("block_comment ::= <b>/*</b> comment_text <b>*/</b>", block)
        self.assertIn("comment_text ::= { Any_ASCII_character }", block)
        self.assertIn("      | block_comment", block)

    def test_ch4_rendered_syntax_matches_pre_markup_root(self):
        # Guards typography-only edits; it is not proof of full LRM fidelity.
        blocks = syntax_text((ROOT / "docs/ch4-expressions.html").read_text())
        self.assertTrue(blocks)
        digest = hashlib.sha256(json.dumps(blocks, ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, CH4_SYNTAX_SHA256)

    def test_entities_are_not_split_by_markup(self):
        for path in sorted((ROOT / "docs").glob("*.html")):
            with self.subTest(path=path.name):
                source = path.read_text()
                self.assertIsNone(re.search(r"&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]+|#x[0-9a-fA-F]+)<", source))

    def test_regression_rejects_tag_stripping_before_entity_decode(self):
        good = '<div class="syntax">&zeta;</div>'
        broken = '<div class="syntax">&zeta<b>;</b></div>'
        self.assertEqual(syntax_text(good), ["ζ"])
        self.assertNotEqual(syntax_text(good), syntax_text(broken))

    def test_ch12_literal_source_entities_and_editorial_boundary(self):
        page = (ROOT / "docs/ch12-vpi-routines.html").read_text()
        rendered = html.unescape(page)
        self.assertIn("systf_data_p = &amp;(systf_data_list[0]);", rendered)
        self.assertIn("while (systf_data_p-&gt;type)", rendered)
        for name in ("callback-layout", "resistor-source-defects",
                     "sampler-source-defects", "startup-source-defects",
                     "control-source-count"):
            self.assertIn('id="editorial-' + name + '"', page)
        self.assertEqual(page.count("Editorial source note (not LRM text)."), 5)

    def test_ch12_no_numbered_hdl_fixture_claims_vpi_execution(self):
        fixtures = ROOT / "tests/fixtures/ch12_vpi_routines"
        for path in fixtures.glob("[0-9]*.va"):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r"(?m)^//! lrm 12(?:\.|$)")


class InformativeContent(HTMLParser):
    """Glossary terms and table cells of an informative annex."""

    def __init__(self):
        super().__init__()
        self.terms = []
        self.tables = []
        self.in_term = False
        self.term = ""
        self.in_cell = False
        self.cell = ""
        self.row = []

    def handle_starttag(self, tag, attrs):
        if tag == "dt":
            self.in_term, self.term = True, ""
        elif tag == "table":
            self.tables.append([])
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.in_cell, self.cell = True, ""

    def handle_data(self, data):
        if self.in_term:
            self.term += data
        if self.in_cell:
            self.cell += data

    def handle_endtag(self, tag):
        if tag == "dt":
            self.terms.append(self.term)
            self.in_term = False
        elif tag in ("td", "th"):
            self.row.append(self.cell)
            self.in_cell = False
        elif tag == "tr":
            self.tables[-1].append(self.row)


class InformativeSource(unittest.TestCase):
    """Source-review guards for informative annex content, not compiler coverage."""

    def test_glossary_exact_term_inventory(self):
        expected = [
            "AMS", "behavioral description", "behavioral model", "block",
            "branch", "compact model", "component", "constitutive relationships",
            "control flow", "child module", "flow", "instance", "instantiation",
            "Kirchhoff’s Laws", "level", "model", "module", "net declaration",
            "node", "NR method", "parameter", "parameter declaration", "port",
            "potential", "primitive", "probe", "reference direction",
            "reference node", "scope", "structural definitions", "terminal",
            "Verilog-A", "Verilog-AMS",
        ]
        parsed = InformativeContent()
        parsed.feed((ROOT / "docs/annex-h-glossary.html").read_text())
        self.assertEqual(parsed.terms, expected)

    def test_history_preserves_source_gaps_and_table_cells(self):
        page = (ROOT / "docs/annex-g-changes.html").read_text()
        parsed = InformativeContent()
        parsed.feed(page)
        self.assertEqual(len(parsed.tables), 7)
        for index, table in enumerate(parsed.tables):
            for row in table:
                self.assertEqual(len(row), 4 if index == 0 else 3)
        # Printed 415 omits item 14; printed 416 omits item 13.
        self.assertNotIn("14", [row[0] for row in parsed.tables[1][1:]])
        self.assertNotIn("13", [row[0] for row in parsed.tables[2][1:]])
        # Printed 423 contains a genuinely blank Mantis row, not lost HTML.
        self.assertIn(["7893", "", ""], parsed.tables[6])
        self.assertIn("Editorial context (not LRM text)", page)
        self.assertIn("$roi()", page)  # source typo; do not silently rewrite


def selftest(argv):
    """Run the regression checks above (`unittest` arguments pass through,
    e.g. `selftest -v` or `selftest SourceFigures`)."""
    sys.dont_write_bytecode = True
    program = unittest.main(module=sys.modules[__name__], argv=["conformance.py selftest"] + argv, exit=False)
    return 0 if program.result.wasSuccessful() else 1


SUBCOMMANDS["selftest"] = selftest


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
