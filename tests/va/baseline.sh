#!/usr/bin/env bash
# Byte-identity oracle for codegen refactors.
#
# Most performance work on this compiler is meant to change the
# compiler's SPEED, not its OUTPUT. `zig build conformance` proves the small
# fixtures still behave; this proves the 38 real foundry models still produce
# the identical byte stream — which is the only thing that catches a reordered
# emit, a lost back-patch, or a nondeterministic thread interleaving.
#
#   tests/va/baseline.sh gen           # record  -> /tmp/vera-baseline/
#   tests/va/baseline.sh check         # compare against the recording
#   tests/va/baseline.sh check 20      # compare 20x (races show 1-in-N, not 1-in-1)
#
# The CLI is rebuilt ReleaseFast each run: a Debug build is ~10x slower, and
# ReleaseFast is what any recorded timing was measured in.
set -euo pipefail

# Repo root. `/..` from tests/va was right when this lived at
# modules/VerA/tests/; 436cf42 promoted the tree, so it needs one more level.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The 38 foundry models live in the HOST repo, not this one — this is the only
# oracle here with an external input. Overridable, and SKIPPED rather than failed
# when the host is not checked out beside us, the way the old Verilog suite
# skipped on a missing verilator.
models="${VERA_MODELS:-$here/../ARPice/src/devices/models}"
out="${BASELINE_DIR:-/tmp/vera-baseline}"
if [ ! -d "$models" ]; then
    echo "baseline.sh: no models at $models — set VERA_MODELS. Skipping."
    exit 0
fi
# Per-invocation, so two agents/shells checking concurrently do not overwrite
# each other's binary mid-run.
exe="$(mktemp -u /tmp/vera-oracle.XXXXXX)"
scratch="$(mktemp -d)"
# One trap for the whole script: bash REPLACES a trap rather than adding to it,
# so a second `trap ... EXIT` further down would silently leak the 8 MB binary.
trap 'rm -rf "$exe" "$exe.o" "$scratch"' EXIT

mode="${1:-check}"
runs="${2:-1}"

zig build-exe -OReleaseFast -Mroot="$here/src/va/main.zig" -femit-bin="$exe" >/dev/null

# A model that FAILS to compile is recorded as an empty `NAME.fail` marker
# rather than skipped, so the comparison catches a change that silently starts
# or stops rejecting a model. All 38 currently compile.
#
# Two used to be expected failures. Both were fixed in the MODELS, not here, so a
# `.fail` marker reappearing for either is an upstream regression and not a
# compiler one. The reasoning is kept because it is what makes the rejection
# correct in the first place:
#   hicumL2_va — used `HSa`, declared nowhere in the file. Since restored
#                upstream; the model now cites VA-Models hicumL2V2p4p0.va:903.
#   bsim4va    — `\`-continuation inside a string literal. Correct rejection
#                (E0138): LRM 2.7 requires a literal be "contained on a single
#                line" and Table 2-2 lists no \<newline> escape. That form is
#                SystemVerilog (IEEE 1800 5.9), which Verilog-AMS never
#                inherited from IEEE 1364-2005.
emit() { # emit <dest-dir>
    mkdir -p "$1"
    for va in "$models"/*.va; do
        n="$(basename "$va" .va)"
        "$exe" --emit-zig --color=never -o "$1/$n.zig" "$va" >/dev/null 2>&1 \
            || { rm -f "$1/$n.zig"; : > "$1/$n.fail"; }
    done
}

case "$mode" in
gen)
    rm -rf "$out"; emit "$out"
    echo "baseline: $(ls "$out" | wc -l) models, $(du -sh "$out" | cut -f1) in $out"
    ;;
check)
    tmp="$scratch"
    for i in $(seq 1 "$runs"); do
        emit "$tmp/$i"
        bad=0
        for f in "$out"/*; do
            cmp -s "$f" "$tmp/$i/$(basename "$f")" || { echo "DIFF run $i: $(basename "$f")"; bad=1; }
        done
        # A model that newly compiles (or newly fails) changes the file set, not
        # any single file's bytes — so compare the set too.
        diff <(ls "$out") <(ls "$tmp/$i") || bad=1
        [ "$bad" = 0 ] || exit 1
        rm -rf "$tmp/$i"
    done
    echo "byte-identical to baseline over $runs run(s)"
    ;;
*) echo "usage: baseline.sh [gen|check] [runs]" >&2; exit 2 ;;
esac
