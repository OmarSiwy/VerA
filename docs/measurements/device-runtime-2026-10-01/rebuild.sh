#!/bin/bash
# rebuild.sh SRCROOT OUTROOT CONTRACT [models...]: rebuild emit.sh trees against
# another contract.zig (the host family / math under test), ReleaseFast,
# stripped (STRIP= keeps symbols), native CPU like the orchestrator, no libc.
# EXTRA= adds flags.
HERE=$(cd "$(dirname "$0")" && pwd)
S=$1; O=$2; C=$3; shift 3
for m in "$@"; do
  mkdir -p "$O/$m"; cd "$O/$m" || exit 1
  zig build-lib -dynamic -OReleaseFast ${STRIP--fstrip} $EXTRA --name "$m" -j4 --cache-dir "$O/.cache" \
    --dep contract --dep dyn --dep device "-Mroot=$S/$m/shim.zig" \
    --dep contract "-Mdevice=$S/$m/device.zig" "-Mcontract=$C" \
    --dep contract "-Mdyn=$HERE/dyn_rt.zig" 2>&1 | head -5
  echo "$m ${PIPESTATUS[0]}"
done
