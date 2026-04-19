#!/usr/bin/env bash
# `vera --std=1364-2005 --run` against Verilator 5 (`--binary`) on the same .v
# designs: six self-contained digital fixtures plus the two scalable benchmarks
# in tools/bench-v/. Prints one Markdown table: wall time and peak RSS, and
# whether the two stdouts agree (Verilator's `- ` report lines dropped). VerA
# interprets, so its one column is parse + elaborate + run.
#
# usage: tools/vs-verilator.sh [VERA]    default zig-out/bin/vera; build it with
#        -Doptimize=ReleaseFast (either -Dlanguage) or the times mean nothing.
#        tools/vs-verilator.sh --oracle  Verilator over every tests/fixtures/
#        ieee1364 .v, one row each, into tests/fixtures/ieee1364/VERILATOR.tsv.
set -u
cd "$(dirname "$0")/.."
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
# Resolved once: `nix shell` per call would add its start-up to every build.
if ! bins=$(nix build --no-link --print-out-paths nixpkgs#verilator nixpkgs#gcc 2>/dev/null); then
  echo "vs-verilator: skipped — Verilator is not reachable through nix" >&2
  exit 0
fi
PATH=$(printf '%s/bin:' $bins)$PATH

# --oracle: a second opinion on every 1364 fixture. VerA is not run; its answer
# is the committed transcript `zig build test-1364` already holds it to. A row
# that disagrees is data for a reader, never a reason to edit the fixture.
if [ "${1:-}" = --oracle ]; then
  oracle() {  # FIXTURE -> one TSV row
    local f=$1 n d expect acc=refuses rc=- agrees=- note=
    n=${f#tests/fixtures/ieee1364/} d=$W/${1//\//_}
    mkdir -p "$d" && cp -r "$(dirname "$f")"/. "$d"/  # `$readmem`/`$fopen` paths are relative
    if grep -qE '^\s*(// digital-runner: reject|//! reject)' "$f"; then expect=reject
    elif [ -f "${f%.v}.expected.txt" ]; then expect=transcript
    else expect=other; fi
    if verilator --binary --timing -j 2 -Wno-fatal -Wno-lint -Wno-style --Mdir "$d/obj" -o sim \
      "$f" > "$d/build.log" 2>&1; then
      acc=accepts
      (cd "$d" && timeout 60 ./obj/sim > out.txt 2> err.txt); rc=$?
    else note=$(grep -m1 '%Error' "$d/build.log" | sed "s|$PWD/||; s|\t| |g" | cut -c1-160); fi
    case $expect in
      reject) if [ $acc = refuses ] || [ "$rc" != 0 ]; then agrees=yes; else agrees=no; note="accepts and exits 0"; fi ;;
      transcript)
        if [ $acc = accepts ] && [ "$rc" = 0 ] && grep -v '^- ' "$d/out.txt" | cmp -s - "${f%.v}.expected.txt"; then
          agrees=yes
        else
          agrees=no
          if [ $acc = accepts ]; then
            [ "$rc" = 124 ] && note=timeout || note="exit $rc"
            [ "$rc" = 0 ] && note="stdout differs"
            grep -qE '(^|[^[:alnum:]_])[01_]*[xXzZ][01xXzZ_]*($|[^[:alnum:]_])' "${f%.v}.expected.txt" &&
              note="$note; golden shows x/z"
          fi
        fi ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$expect" "$acc" "$rc" "$agrees" "$note"
  }
  export -f oracle; export W
  out=tests/fixtures/ieee1364/VERILATOR.tsv
  {
    echo "# $(verilator --version) — \`verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style\`,"
    echo "# written by \`tools/vs-verilator.sh --oracle\`. agrees: a transcript fixture's stdout"
    echo "# (Verilator's \`- \` report lines dropped) equals its .expected.txt, a reject fixture is"
    echo "# refused at build or exits nonzero. Verilator is 2-state by default, so a golden"
    echo "# showing x/z is expected to differ. Disagreements are listed, never resolved."
    printf 'fixture\texpect\tverilator\texit\tagrees\tnote\n'
    find tests/fixtures/ieee1364 -name '*.v' | sort | xargs -P 12 -I{} bash -c 'oracle "$1"' _ {} | sort
  } > "$out"
  awk -F'\t' '$5 == "yes" { y++ } $5 == "yes" || $5 == "no" { n++ }
    END { printf "vs-verilator: %d / %d fixtures agree (%.1f%%) -> '"$out"'\n", y, n, 100 * y / n }' "$out" >&2
  exit 0
fi
VERA=$(realpath "${1:-zig-out/bin/vera}")

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
