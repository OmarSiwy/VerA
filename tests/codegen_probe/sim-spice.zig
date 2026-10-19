//! src/sim/spice/'s plain loops, one `export fn` each, so a later edit that
//! makes one scalar again shows in the assembly. In: the loop's operands as
//! C-ABI pointers and a length; out: what the loop in its source file
//! computes. No LRM clause: these check the deck runner's numerics.
//!
//! Counts are asm_probe.py's `vector` column on x86_64_v3, ReleaseFast
//! (ymm-operand lines in parentheses); "hand" is the hand-written
//! `@Vector` version each one replaced. Every body below uses packed ymm
//! ops; none folds into a strict scalar loop.
//!
//! expect: norm_plain vector>=80 (101, ymm 86; hand 43, ymm 29; converger.updateAndNorm)
//! expect: companion_trap_acc vector>=30 (39; hand 9; integrator.companionAt)
//! expect: companion_gear vector>=30 (44; hand 10; integrator.companionAt)
//! expect: mindel_gear vector>=80 (98, ymm 64; hand 89, ymm 65; integrator.minDel)
//! expect: elim_row vector>=16 (22; hand 25; dense_lu.elimRow)
//! expect: complex_admittance vector>=20 (31, ymm 29; hand 20; dense_lu.buildComplexAdmittance)
//! expect: combine_gc vector>=12 (17; hand 19; circuit.combineGC)
const std = @import("std");
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
