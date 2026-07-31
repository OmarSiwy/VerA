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


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
