//! Codegen probe for `src/sim/rt/logic.zig`'s word kernels, at 4 words (a
//! 256-bit value, the last word masked to 248 bits). Build with
//! `zig build-obj -OReleaseFast -mcpu=x86_64_v3 -fstrip -femit-asm=k.s -fno-emit-bin`.
//! The plain loops (`anyx`, `cond`) replaced `@Vector` code and must stay
//! packed; `not` and `orx` keep `@Vector` because the plain loop went half
//! scalar (21 vs 10 instructions for `not`, xmm vs ymm for `orx`).
//!
// expect: anyx_plain vector>=2
// expect: cond_plain vector>=8
// expect: not_vector vector>=5
// expect: orx_vector vector>=4
const N = 4;
const top: u64 = (1 << 56) - 1;

/// `logic.anyX`: any unknown bit in the value.
export fn anyx_plain(x: [*]const u64, len: usize) bool {
    _ = len;
    var any: u64 = 0;
    for (x[0..N]) |w| any |= w;
    return any != 0;
}

/// `logic.cond`'s ambiguous arm: only matching known bits survive.
export fn cond_plain(ov: [*]u64, ox: [*]u64, yv: [*]const u64, yx: [*]const u64, nv: [*]const u64, nx: [*]const u64, len: usize) void {
    _ = len;
    var v: [N]u64 = undefined;
    var x: [N]u64 = undefined;
    for (&v, &x, yv[0..N].*, yx[0..N].*, nv[0..N].*, nx[0..N].*) |*ev, *ex, a, ax, b, bx| {
        ex.* = ax | bx | (a ^ b);
        ev.* = a | ex.*;
    }
    ov[0..N].* = v;
    ox[0..N].* = x;
}

/// `logic.not` at more than 64 bits.
export fn not_vector(o: [*]u64, v: [*]const u64, x: [*]const u64, len: usize) void {
    _ = len;
    const V = @Vector(N, u64);
    var r: [N]u64 = ~@as(V, v[0..N].*) | @as(V, x[0..N].*);
    r[N - 1] &= top;
    o[0..N].* = r;
}

/// `logic.orX`: a result, or all x when `unk`.
export fn orx_vector(ov: [*]u64, ox: [*]u64, r: [*]const u64, unk: bool, len: usize) void {
    _ = len;
    const u = 0 -% @as(u64, @intFromBool(unk));
    const V = @Vector(N, u64);
    const uv: V = @splat(u);
    var v: [N]u64 = @as(V, r[0..N].*) | uv;
    var x: [N]u64 = uv;
    v[N - 1] &= top;
    x[N - 1] &= top;
    ov[0..N].* = v;
    ox[0..N].* = x;
}
