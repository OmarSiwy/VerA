#!/usr/bin/env python3
"""Run every shell transcript the documentation shows; fail when one drifts.

    tools/doctest.py                 # check every docs/**/*.out
    tools/doctest.py --update        # rewrite them from what the commands print
    tools/doctest.py FILE.out ...    # only these

A transcript is a `.out` file beside the example it runs, included into a page
with `{{#include NAME.out}}`. Each line starting with `$ ` is a command, run
with bash in the transcript's directory with this tree's `zig-out/bin` first on
PATH (so `vera` is the one `zig build` just installed). The lines after it, up
to the next `$ `, are its stdout and stderr merged, then `(exit N)` when it
exits nonzero. The page shows exactly the text this script compares, so the
documentation cannot show output the compiler does not produce.
"""
import argparse
import difflib
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
# A testbench build takes seconds; one past this is wedged.
TIMEOUT_S = 600


def commands(text):
    """The `$ ` lines of a transcript, in order."""
    return [line[2:] for line in text.splitlines() if line.startswith("$ ")]


def render(path):
    """The transcript `path`'s commands print now, in its own format."""
    env = dict(os.environ, PATH=f"{ROOT / 'zig-out' / 'bin'}{os.pathsep}{os.environ['PATH']}")
    out = []
    for cmd in commands(path.read_text()):
        p = subprocess.run(["bash", "-c", cmd], cwd=path.parent, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=TIMEOUT_S)
        out.append(f"$ {cmd}")
        text = p.stdout.decode("utf-8", "replace").rstrip("\n")
        if text:
            out.append(text)
        if p.returncode != 0:
            out.append(f"(exit {p.returncode})")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--update", action="store_true", help="rewrite each transcript from its commands")
    ap.add_argument("files", nargs="*", type=Path)
    args = ap.parse_args()
    files = [f.resolve() for f in args.files] or sorted(DOCS.rglob("*.out"))
    if not files:
        print("doctest.py: no transcripts found", file=sys.stderr)
        return 2
    drifted = 0
    for f in files:
        want = f.read_text()
        got = render(f)
        if got == want:
            print(f"ok    {f.relative_to(ROOT)}")
            continue
        if args.update:
            f.write_text(got)
            print(f"wrote {f.relative_to(ROOT)}")
            continue
        drifted += 1
        print(f"DRIFT {f.relative_to(ROOT)}")
        sys.stdout.writelines(difflib.unified_diff(want.splitlines(True), got.splitlines(True), "shown", "now"))
    print(f"{len(files) - drifted}/{len(files)} transcripts match")
    return 1 if drifted else 0


if __name__ == "__main__":
    sys.exit(main())
