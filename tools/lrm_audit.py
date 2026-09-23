#!/usr/bin/env python3
"""Source-fidelity worklist, NOT a conformance score.

Read the checked-in PDF with Poppler and compare each numbered section with
the HTML. Keep differences visible: equations, diagrams, tables, grammar and
normative scope still require human review. No fixture earns credit here.
"""

import argparse
import difflib
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
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


def inventory(root):
    pdf = root / "docs/VAMS-LRM-2023.pdf"
    source, pdf_duplicates = pdf_sections(pdf)
    html = {}
    duplicates = list(pdf_duplicates)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--section", help="Show a section and its descendants")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--diff", action="store_true", help="Print token differences")
    args = parser.parse_args()
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
        return
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


if __name__ == "__main__":
    main()
