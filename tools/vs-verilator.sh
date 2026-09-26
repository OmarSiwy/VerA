#!/usr/bin/env bash
# `vera --std=1364-2005 --run` against Verilator 5 (`--binary`) on the same .v
# designs: six self-contained digital fixtures plus the two scalable benchmarks
# in tools/bench-v/. Prints one Markdown table: wall time and peak RSS, and
# whether the two stdouts agree (Verilator's `- ` report lines dropped). VerA
# interprets, so its one column is parse + elaborate + run.
#
# usage: tools/vs-verilator.sh [VERA]    default zig-out/bin/vera; build it with
#        -Doptimize=ReleaseFast (either -Dlanguage) or the times mean nothing.
set -u
cd "$(dirname "$0")/.."
VERA=$(realpath "${1:-zig-out/bin/vera}")
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
# Resolved once: `nix shell` per call would add its start-up to every build.
if ! bins=$(nix build --no-link --print-out-paths nixpkgs#verilator nixpkgs#gcc 2>/dev/null); then
  echo "vs-verilator: skipped — Verilator is not reachable through nix" >&2
  exit 0
fi
PATH=$(printf '%s/bin:' $bins)$PATH

designs=()
for f in 05_expressions/audit_expr_signed_boundaries 10_tasks_functions/audit_function_return_variable \
  17_system_tasks/audit_ieee_math_clog2_unsigned 04_data_types/audit_type_multidimensional_array \
  10_tasks_functions/d04_09_task_argument_passing 17_system_tasks/d09_01_display_radix; do
  designs+=("tests/fixtures/ieee1364/$f.v")
done
for nc in 64:1000 1024:10000; do
  f=$W/lfsr_chain_${nc/:/x}.v
  sed "s/N = 64;/N = ${nc%:*};/; s/CYCLES = 1000;/CYCLES = ${nc#*:};/" tools/bench-v/lfsr_chain.v > "$f"
  designs+=("$f")
done
for wv in 64:1000 512:10000; do
  f=$W/ripple_adder_${wv/:/x}.v
  tools/bench-v/ripple_adder.sh "${wv%:*}" "${wv#*:}" > "$f"
  designs+=("$f")
done

# timed OUT CMD...: stdout to OUT; sets `secs` and `mb` from GNU time.
timed() {
  local out=$1; shift
  /usr/bin/time -f '%e %M' -o "$W/t" "$@" > "$out" 2> "$W/err"
  local rc=$?
  read -r secs kb < <(tail -1 "$W/t")
  mb=$(awk "BEGIN { printf \"%.1f\", $kb / 1024 }")
  return $rc
}

echo "| design | vera run s | vera MB | verilator build s | verilator run s | verilator MB | outputs agree |"
echo "|---|---:|---:|---:|---:|---:|---|"
for d in "${designs[@]}"; do
  n=$(basename "$d" .v)
  if timed "$W/vera.out" "$VERA" --std=1364-2005 --run "$d"; then vs=$secs vm=$mb; else vs=error vm=-; fi
  if timed /dev/null verilator --binary -j 0 -Wno-fatal --Mdir "$W/obj_$n" -o sim "$d"; then
    bs=$secs
    if timed "$W/vl.out" "$W/obj_$n/sim"; then rs=$secs rm=$mb; else rs=error rm=-; fi
  else bs=error rs=- rm=-; : > "$W/vl.out"; fi
  if [ "$vs" != error ] && [ "$rs" != error ] && [ "$rs" != - ] &&
    diff -q "$W/vera.out" <(grep -v '^- ' "$W/vl.out") > /dev/null; then ok=yes; else ok=NO; fi
  echo "| $n | $vs | $vm | $bs | $rs | $rm | $ok |"
done
