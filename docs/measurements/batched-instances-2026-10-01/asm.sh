#!/bin/bash
# asm.sh TREEROOT OUT CONTRACT "target:cpu:W ..." models...: assembly of the
# batch host (evalScalar / evalBatch) per (model, target, cpu, W).
H=$(cd "$(dirname "$0")" && pwd)
T=$1; O=$2; C=$3; CFGS=$4; shift 4
for m in "$@"; do for c in $CFGS; do
  tgt=$(echo $c | cut -d: -f1); cpu=$(echo $c | cut -d: -f2); w=$(echo $c | cut -d: -f3)
  d=$O/$m.$cpu.w$w; mkdir -p "$d"
  echo "pub const W = $w;" > "$d/cfg.zig"
  (cd "$d" && zig build-obj -target $tgt -mcpu=$cpu -OReleaseFast -fstrip -j4 --name b --cache-dir "$O/.cache" \
    --dep contract --dep dyn --dep device "-Mroot=$T/$m/shim.zig" \
    --dep contract "-Mdevice=$T/$m/device.zig" "-Mcontract=$C" \
    --dep contract --dep cfg "-Mdyn=$H/batch_host.zig" "-Mcfg=$d/cfg.zig" -femit-asm=b.s -fno-emit-bin 2>&1 | head -5)
  echo "$m $tgt $cpu W=$w $(wc -l < $d/b.s 2>/dev/null || echo FAIL)"
done; done
