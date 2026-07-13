#!/bin/bash
# build.sh TREEROOT OUT CONTRACT "cpu:W ..." models...: one .so per (model, cpu, W).
H=$(cd "$(dirname "$0")" && pwd)
T=$1; O=$2; C=$3; CFGS=$4; shift 4
for m in "$@"; do for cw in $CFGS; do
  cpu=${cw%%:*}; w=${cw##*:}
  d=$O/$m.$cpu.w$w; mkdir -p "$d"
  echo "pub const W = $w; pub const SIG = ${SIG:-true};" > "$d/cfg.zig"
  (cd "$d" && zig build-lib -dynamic -OReleaseFast ${STRIP--fstrip} -mcpu=$cpu -j4 --name b --cache-dir "$O/.cache" \
    --dep contract --dep dyn --dep device "-Mroot=$T/$m/shim.zig" \
    --dep contract "-Mdevice=$T/$m/device.zig" "-Mcontract=$C" \
    --dep contract --dep cfg "-Mdyn=$H/batch_host.zig" "-Mcfg=$d/cfg.zig" 2>&1 | head -8)
  echo "$m $cpu W=$w $(ls $d/libb.so 2>/dev/null || echo FAIL)"
done; done
