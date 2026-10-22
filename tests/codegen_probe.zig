//! Codegen probes: one `export fn` per loop the compiler, the emitters and
//! the runtime must keep vectorised, so a later edit that makes one scalar
//! again shows in the assembly. Nothing in the build runs this file. Build it
//! by hand with
//!
//!   zig build-obj -OReleaseFast -mcpu=x86_64_v3 -fstrip -femit-asm=k.s -fno-emit-bin tests/codegen_probe.zig
//!
//! and count the packed (`ymm`) instructions of each function against its
//! `expect:` line below (`vector>=N`: the count on x86_64_v3, ReleaseFast; the
//! per-element loop each one replaced has none). No LRM clause: these check
//! VerA's own code.
const std = @import("std");

// ---------------------------------------------------------------------------
// src/codegen/device/
// ---------------------------------------------------------------------------

// Codegen probe for the code `src/codegen/device/codegen/render.zig` emits to start
// a §3.2 memory-backed array each evaluation. Build with
// `zig build-obj -OReleaseFast -mcpu=x86_64_v3 -fstrip -femit-asm=k.s -fno-emit-bin`.
// It was `zFill`, a hand-written `@Vector(4, T)` store loop behind a
// volatile read that kept LLVM off Zig 0.16's byte-wise compiler_rt
// `memset`. Under 0.18 a plain `@memset` of a run-time value is the same
// 51-53 packed stores, and of zero (what the emitter writes) a call into the
// fast `memset`: 19.5 vs 51 cycles for 203 `f64`.
//
// expect: fill_f64 vector>=40
// expect: fill_dual vector>=10

/// A §3.2 `real` array of 203 elements set to a run-time value.
export fn fill_f64(a: [*]f64, len: usize, v: f64) void {
    _ = len;
    @memset(a[0..203], v);
}

/// An array of 3-lane duals (a dense family's `zOf(S, m)`).
export fn fill_dual(a: [*][4]f64, len: usize, v: *const [4]f64) void {
    _ = len;
    @memset(a[0..100], v.*);
}

// ---------------------------------------------------------------------------
// src/codegen/digital/
// ---------------------------------------------------------------------------

// src/codegen/digital/'s plain loops, one `export fn` each, so a later edit that
// makes one scalar again shows in the assembly. In: the loop's operands as
// C-ABI pointers and a length; out: what the loop in `plan.zig` computes.
// No LRM clause: these check VerA's own emitter.
//
// expect: meet_plain vector>=16 (37 on x86_64_v3, ymm vpandn/vpand/vpor;
// the short-circuit `changed or` form it replaced: 0)

/// `plan.meet`'s word loop: `in &= set` over `n` words, returning the bits
/// it cleared (non-zero: `in` changed, so its pc is queued again).
export fn meet_plain(in: [*]u64, set: [*]const u64, n: usize) u64 {
    var lost: u64 = 0;
    for (in[0..n], set[0..n]) |*w, s| {
        lost |= w.* & ~s;
        w.* &= s;
    }
    return lost;
}

// ---------------------------------------------------------------------------
// lib/frontend/
// ---------------------------------------------------------------------------

// lib/frontend/'s byte scans, one `export fn` each, so a later edit that
// makes one scalar again shows in the assembly. In: the text as a C-ABI
// pointer and a length, and the start index; out: the index the scan in
// its source file returns. No LRM clause: these check VerA's own lexer and
// preprocessor.
//
// Counts are asm_probe.py's `vector` column on x86_64_v3, ReleaseFast; the
// per-byte loop each one replaced has none.
//
// expect: ident_end vector>=12 (21; lexer.identEnd)
// expect: find_stop vector>=8 (10; preprocessor.findStop over `scan_stops`)

/// lexer.identEnd: the first byte at or after `i` that is not a §2.8
/// identifier character.
export fn ident_end(p: [*]const u8, n: usize, i: usize) usize {
    const s = p[0..n];
    var k = i;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (k + lanes <= s.len) : (k += lanes) {
            const b: V = s[k..][0..lanes].*;
            const letter: Mask = @bitCast((b | @as(V, @splat(0x20))) -% @as(V, @splat('a')) < @as(V, @splat(26)));
            const digit: Mask = @bitCast(b -% @as(V, @splat('0')) < @as(V, @splat(10)));
            const under: Mask = @bitCast(b == @as(V, @splat('_')));
            const dollar: Mask = @bitCast(b == @as(V, @splat('$')));
            const out = ~(letter | digit | under | dollar);
            if (out != 0) return k + @ctz(out);
        }
    }
    while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_' or s[k] == '$')) k += 1;
    return k;
}

/// preprocessor.findStop with `scan_stops`: the first `"`, `\` or '`' at or
/// after `i`.
export fn find_stop(p: [*]const u8, n: usize, i: usize) usize {
    const text = p[0..n];
    const stops = "\"\\`";
    var k = i;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (k + lanes <= text.len) : (k += lanes) {
            const block: V = text[k..][0..lanes].*;
            var hit: Mask = 0;
            inline for (stops) |stop| hit |= @as(Mask, @bitCast(block == @as(V, @splat(stop))));
            if (hit != 0) return k + @ctz(hit);
        }
    }
    while (k < text.len) : (k += 1) {
        inline for (stops) |stop| if (text[k] == stop) return k;
    }
    return k;
}

// ---------------------------------------------------------------------------
// lib/sim/rt/
// ---------------------------------------------------------------------------

// Codegen probe for `lib/sim/rt/logic.zig`'s word kernels, at 4 words (a
// 256-bit value, the last word masked to 248 bits). Build with
// `zig build-obj -OReleaseFast -mcpu=x86_64_v3 -fstrip -femit-asm=k.s -fno-emit-bin`.
// The plain loops (`anyx`, `cond`) replaced `@Vector` code and must stay
// packed; `not` and `orx` keep `@Vector` because the plain loop went half
// scalar (21 vs 10 instructions for `not`, xmm vs ymm for `orx`).
//
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

// ---------------------------------------------------------------------------
// lib/sim/spice/
// ---------------------------------------------------------------------------

// lib/sim/spice/'s plain loops, one `export fn` each, so a later edit that
// makes one scalar again shows in the assembly. In: the loop's operands as
// C-ABI pointers and a length; out: what the loop in its source file
// computes. No LRM clause: these check the deck runner's numerics.
//
// Counts are asm_probe.py's `vector` column on x86_64_v3, ReleaseFast
// (ymm-operand lines in parentheses); "hand" is the hand-written
// `@Vector` version each one replaced. Every body below uses packed ymm
// ops; none folds into a strict scalar loop.
//
// expect: norm_plain vector>=80 (101, ymm 86; hand 43, ymm 29; converger.updateAndNorm)
// expect: companion_trap_acc vector>=30 (39; hand 9; integrator.companionAt)
// expect: companion_gear vector>=30 (44; hand 10; integrator.companionAt)
// expect: mindel_gear vector>=80 (98, ymm 64; hand 89, ymm 65; integrator.minDel)
// expect: elim_row vector>=16 (22; hand 25; dense_lu.elimRow)
// expect: complex_admittance vector>=20 (31, ymm 29; hand 20; dense_lu.buildComplexAdmittance)
// expect: combine_gc vector>=12 (17; hand 19; circuit.combineGC)
const inf = std.math.inf(f64);
const sign_clear: u64 = 0x7fff_ffff_ffff_ffff;

/// converger.updateAndNorm: x_old = x, x += dx, the max scaled step over
/// the bit patterns.
export fn norm_plain(x: [*]f64, dx: [*]const f64, x_old: [*]f64, cur: [*]const bool, n: usize, reltol: f64, abstol: f64, vntol: f64) f64 {
    var worst: i64 = 0;
    for (x[0..n], dx[0..n], x_old[0..n], cur[0..n]) |*xi, d, *xo, c| {
        const o = xi.*;
        xo.* = o;
        const xn = o + d;
        xi.* = xn;
        const atol = if (c) abstol else vntol;
        const tol = reltol * @max(@abs(xn), @abs(o)) + atol;
        const finite = @abs(xn) < inf and @abs(d) < inf;
        const r = if (!finite) inf else if (d == 0) 0 else @abs(d) / tol;
        worst = @max(worst, @as(i64, @bitCast(@as(u64, @bitCast(r)) & sign_clear)));
    }
    return @bitCast(worst);
}

/// integrator.companionAt, trapezoidal, accumulating: the Newton residual's
/// dynamic part.
export fn companion_trap_acc(out: [*]f64, q0: [*]const f64, q1: [*]const f64, ip: [*]const f64, n: usize, ag0: f64, ag1: f64) void {
    for (out[0..n], q0[0..n], q1[0..n], ip[0..n]) |*o, a, b, p| {
        const d = ag0 * (a - b);
        o.* = (o.* + d) - ag1 * p;
    }
}

/// integrator.companionAt, gear-2, writing: NIintegrate.
export fn companion_gear(out: [*]f64, q0: [*]const f64, q1: [*]const f64, q2: [*]const f64, n: usize, ag0: f64, ag2: f64) void {
    for (out[0..n], q0[0..n], q1[0..n], q2[0..n]) |*o, a, b, b2| {
        o.* = ag0 * (a - b) - ag2 * (b - b2);
    }
}

/// integrator.minDel at order 2 after a gear-2 step: CKTterr's min bound.
export fn mindel_gear(q0: [*]const f64, q1: [*]const f64, q2: [*]const f64, q3: [*]const f64, ip: [*]const f64, n: usize, dt: f64, dt1: f64, dt2: f64, ag0: f64, ag2: f64) f64 {
    const abstol = 1e-12;
    const reltol = 1e-3;
    const chgtol = 1e-14;
    const trtol = 7.0;
    const coeff = 0.2222222222;
    const sum01 = dt + dt1;
    const sum12 = dt1 + dt2;
    const sum012 = dt + sum12;
    var m: i64 = @bitCast(inf);
    for (q0[0..n], q1[0..n], q2[0..n], q3[0..n], ip[0..n]) |qc, qp, qp2, qp3, p| {
        const i_new = ag0 * (qc - qp) - ag2 * (qp - qp2);
        const volttol = abstol + reltol * @max(@abs(i_new), @abs(p));
        const chargetol = reltol * @max(@max(@abs(qc), @abs(qp)), chgtol) / dt;
        const tol = @max(volttol, chargetol);
        const f12 = (qp - qp2) / dt1;
        var dd = ((qc - qp) / dt - f12) / sum01;
        const f123 = (f12 - (qp2 - qp3) / dt2) / sum12;
        dd = (dd - f123) / sum012;
        const del = trtol * tol / @max(abstol, coeff * @abs(dd));
        m = @min(m, @as(i64, @bitCast(@as(u64, @bitCast(del)) & sign_clear)));
    }
    return @bitCast(m);
}

/// dense_lu.elimRow: one elimination row update, row_i -= f * row_k.
export fn elim_row(row_i: [*]f64, row_k: [*]const f64, n: usize, f: f64) void {
    for (row_i[0..n], row_k[0..n]) |*a, b| a.* -= f * b;
}

/// dense_lu.buildComplexAdmittance, one row: [G, -wC; wC, G].
export fn complex_admittance(g: [*]const f64, c: [*]const f64, tl: [*]f64, tr: [*]f64, bl: [*]f64, br: [*]f64, n: usize, omega: f64) void {
    @memcpy(tl[0..n], g[0..n]);
    @memcpy(br[0..n], g[0..n]);
    for (c[0..n], tr[0..n], bl[0..n]) |cv, *b, *d| {
        b.* = -omega * cv;
        d.* = omega * cv;
    }
}

/// circuit.combineGC: G + alpha * C.
export fn combine_gc(out: [*]f64, g: [*]const f64, c: [*]const f64, n: usize, alpha: f64) void {
    for (out[0..n], g[0..n], c[0..n]) |*o, gv, cv| o.* = gv + alpha * cv;
}
