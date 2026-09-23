#!/usr/bin/env python3
"""Local licensed-source heading worklist, never a conformance denominator.

No source body text is written. Requires the user's local IEEE PDF and Poppler.
The table of contents locates headings; it does not enumerate atomic rules.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHA256 = "3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e"
# The pinned PDF's TOC lists 212; the body heading is on printed page 213.
# Explicitly retain both, rather than silently searching past a bad anchor.
ANCHOR_CORRECTIONS = {"14.2.1": 213}
ROW = re.compile(r"^\s*((?:[0-9]+|[A-I])(?:\.[0-9]+)*)\.?\s+(.+?)\s*\.{3,}\s*(\d+)\s*$")
ANNEX = re.compile(r"^\s*Annex ([A-I]) \((normative|informative)\)\s+(.+?)\s*\.{3,}\s*(\d+)\s*$")


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
        annex = ANNEX.match(line)
        match = ROW.match(line)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdf", type=Path, default=ROOT / "docs/1364-2005.pdf")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        digest = hashlib.sha256(args.pdf.read_bytes()).hexdigest()
        if digest != SHA256:
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


if __name__ == "__main__":
    sys.exit(main())
