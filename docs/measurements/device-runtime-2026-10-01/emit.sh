#!/bin/bash
# emit.sh VERA OUT [models...]: --emit-so every workload with the dyn_rt host
# into OUT/<model>/ (tree + lib<model>.1.so). Default: all workloads.
VERA=$1; OUT=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
A=/home/omare/Documents/Projects/Zig/ARPice/models
ms=${*:-"resistor diode mos1 bsim4va psp103 txl coupled_ltra bsource bsource_uninit"}
mkdir -p "$OUT"
for m in $ms; do
  case $m in
    txl|coupled_ltra) src=$A/native/$m.va ;;
    bsource_uninit) mkdir -p "$OUT/src"; sed 's/(\* vera_scratch \*) real st/(* vera_scratch = "uninit" *) real st/' $A/bsource.va > "$OUT/src/bsource.va"; src=$OUT/src/bsource.va ;;
    *) src=$A/$m.va ;;
  esac
  rm -rf "${OUT:?}/$m"
  t0=$(date +%s.%N)
  so=$("$VERA" --emit-so --dyn "$HERE/dyn_rt.zig" --work-dir "$OUT/$m" -I "$A" -I "$(dirname "$src")" "$src" 2>"$OUT/$m.err")
  t1=$(date +%s.%N)
  echo "$m ${so:-FAIL} $(echo "$t1 - $t0" | bc)s"
done
