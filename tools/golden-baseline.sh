#!/usr/bin/env bash
# Snapshot what the compiler SAYS about every fixture, so a refactor can prove
# it changed nothing.
#
#     tools/golden-baseline.sh before        # on the pre-refactor tree
#     ... refactor ...
#     tools/golden-baseline.sh after
#     diff -r .zig-cache/vera-golden/{before,after} && echo IDENTICAL
#
# Captures stdout AND stderr AND the exit status per fixture, because a refactor
# that touches diagnostics (Phase 1 touches E0515) must be held to the message
# text too, not only to the generated device.
#
# ponytail: a shell loop over `vera --emit-zig`, not a build step. The build
# graph cannot see fixture contents (bench.zig reads them at run time, see
# build.zig's note on `test-devices`), so a cacheable Run step would cache a
# pass for a golden nobody compared. 30s and no new Zig is the right trade.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${1:?usage: golden-baseline.sh <tag>   (e.g. before | after)}"
out="$root/.zig-cache/vera-golden/$tag"
vera="$root/zig-out/bin/vera"

[ -x "$vera" ] || { echo "build it first: zig build" >&2; exit 2; }

rm -rf "$out"; mkdir -p "$out"

# One fixture: emit into $out mirroring its path under tests/fixtures.
# Exported so the xargs subshells can see it.
snap() {
  local f="$1" out="$2" root="$3" vera="$4"
  local rel="${f#"$root"/tests/fixtures/}"
  local dst="$out/$rel.txt"
  mkdir -p "$(dirname "$dst")"
  # -I both: the shared tests/fixtures/check.vh, and the fixture's own directory
  # for a local `include.
  "$vera" --emit-zig --color=never \
      -I "$root/tests/fixtures" -I "$(dirname "$f")" "$f" >"$dst" 2>&1
  echo "exit=$?" >>"$dst"
}
export -f snap

find "$root/tests/fixtures" -name '*.va' -print0 \
  | sort -z \
  | xargs -0 -P "$(nproc)" -I{} bash -c 'snap "$@"' _ {} "$out" "$root" "$vera"

echo "$(find "$out" -name '*.txt' | wc -l) fixtures snapshotted -> $out"
