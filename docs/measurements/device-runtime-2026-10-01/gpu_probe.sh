#!/bin/bash
# gpu_probe.sh OUTDIR: compile contract.gm's exp/log/pow for NVPTX (sm_80)
# and AMDGCN (gfx90a) and count fused multiply-adds in the output. The
# routines use none, so any fma there would be a backend contraction that
# makes GPU bits differ from the host's. AMDGCN's f64 division expands into
# v_div_scale/v_rcp/v_fma/v_div_fixup, which is IEEE-correct division, not
# contraction: those are reported separately.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
C=$HERE/../../../tools/contract.zig
O=${1:-$(mktemp -d)}
mkdir -p "$O"
cat > "$O/probe.zig" <<'EOF'
const gm = @import("contract").gm;
export fn vexp(x: f64) f64 {
    return gm.exp(x);
}
export fn vlog(x: f64) f64 {
    return gm.log(x);
}
export fn vpow(x: f64, y: f64) f64 {
    return gm.pow(x, y);
}
EOF
cd "$O"
zig build-obj -target nvptx64-cuda -mcpu=sm_80 -OReleaseFast -fstrip --dep contract -Mroot=probe.zig "-Mcontract=$C" -femit-asm=probe.ptx -fno-emit-bin
zig build-obj -target amdgcn-amdhsa -mcpu=gfx90a -OReleaseFast -fstrip --dep contract -Mroot=probe.zig "-Mcontract=$C" -femit-asm=probe.s -fno-emit-bin
echo "nvptx fma:  $(grep -c 'fma\.' probe.ptx || true)"
echo "amdgcn fma: $(grep -cE 'v_fma|v_fmac' probe.s || true) (division expansions: $(grep -c v_div_fixup probe.s || true))"
