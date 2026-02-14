#!/usr/bin/env python3
"""Compile positive Annex G clients; failures remain failures, never XFAIL passes."""
import argparse
import pathlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--include", required=True, type=pathlib.Path)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    source = pathlib.Path(__file__).resolve().parents[1] / "tests/vpi_annex_g_header_probe.c"
    failed = False
    for name in ("BASELINE", "VECTOR_SIGNED", "VECTOR_GUARD", "VECTOR_PREDEFINED", "VECTOR_LAYOUT", "STRENGTH",
                 "NAME_SIGNATURE", "CALLBACK", "VALUE_ROUTINES"):
        result = subprocess.run([args.cc, "-std=c11", "-fsyntax-only",
                                 "-I", str(args.include), "-DPROBE_" + name,
                                 str(source)], capture_output=True, text=True)
        print(f"{'PASS' if result.returncode == 0 else 'FAIL'} ANNEX-G-{name} exit={result.returncode}")
        if result.returncode:
            failed = True
            print(result.stderr, file=sys.stderr, end="")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
