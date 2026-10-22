//! Integration kernels: the companion coefficients, the dynamic-current
//! recurrence and the CKTterr LTE bound. tran.zig drives them per step.
//! In: a step history (dt, charges, the previous dynamic current); out:
//! coefficients, dynamic currents, and the next-step bound in seconds.
//!
//! Copied from OmarSiwy/ESPice src/analysis/tran/integrator.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d. Adapted: `Method` is declared
//! here (ESPice's `core.query.Method`, the same three variants). Not taken:
//! `rebaseCurrent`, the accepted-point charge re-read tran.zig leaves out.
//!
//! LRM: none; the formulas are ngspice's (nicomcof.c, niinteg.c,
//! cktterr.c), cited per function.
const std = @import("std");

/// The integration method a `.tran` runs (ESPice `core.query.Method`).
pub const Method = enum { backward_euler, trapezoidal, gear_2 };

/// The integration coefficients, ngspice `CKTag[]` (nicomcof.c). `ag0`
/// multiplies q(x): it is the companion conductance factor (niinteg.c:77) and the
/// Jacobian axpy weight. `ag2` multiplies q_prev2 and is nonzero for gear-2
/// only. `ag1` weighs trap's previous current, ngspice's xmu/(1 - xmu): 1 for
/// the plain trapezoid. Each method's dynamic residual is
///   BE:   ag0*(q - q1)
///   trap: ag0*(q - q1) - ag1*i_prev
///   gear: ag0*(q - q1) - ag2*(q1 - q2)
pub const Coeffs = struct { ag0: f64, ag2: f64, ag1: f64 = 1 };

/// Returns the coefficients for a step of `dt` seconds after one of
/// `dt_prev`; `dt_prev` is read by gear-2 only, `xmu` by the trapezoid
/// only. Gear-2 is the variable-step BDF2 ngspice solves as a Vandermonde
/// system over the real step history (nicomcof.c:60-136); with r = dt/dt_prev its closed form
/// is ag0 = (1+2r)/((1+r)dt), ag2 = r^2/((1+r)dt), and r = 1 gives the
/// uniform-step 3/(2dt), 1/(2dt). `xmu` is the trapezoid's weight
/// (`Options.xmu`); at 0.5 its coefficients are exactly 2/dt and 1.
pub fn coeffs(method: Method, dt: f64, dt_prev: f64, xmu: f64) Coeffs {
    return switch (method) {
        .backward_euler => .{ .ag0 = 1.0 / dt, .ag2 = 0 },
        .trapezoidal => .{ .ag0 = 1.0 / dt / (1.0 - xmu), .ag2 = 0, .ag1 = xmu / (1.0 - xmu) },
        .gear_2 => blk: {
            const r = dt / dt_prev;
            break :blk .{
                .ag0 = (1.0 + 2.0 * r) / ((1.0 + r) * dt),
                .ag2 = r * r / ((1.0 + r) * dt),
            };
        },
    };
}

/// Returns the LTE divided-difference coefficient, ngspice `CKTterr` (cktterr.c:24-34)
/// indexed by order: gearCoeff = {.5, .2222222222, ...}, trapCoeff = {.5,
/// .08333333333}. The order here is fixed by the method (BE 1, trap and
/// gear-2 2).
fn lteCoeff(method: Method) f64 {
    // ngspice's decimals, not 2/9 and 1/12: the 4e-11 relative gap moves
    // every LTE-chosen step by 2e-11, which a 256-stage inverter chain
    // amplifies past tolerance.
    return switch (method) {
        .backward_euler => 0.5, // gearCoeff[0] == trapCoeff[0]
        .trapezoidal => 0.08333333333, // trapCoeff[1]
        .gear_2 => 0.2222222222, // gearCoeff[1]
    };
}

/// The companion kernel over any index space, `d = ag0*(q0 - q1)` minus the
/// method's history term (ag1*i_prev for trap, ag2*(q1 - q2) for gear):
///   accumulate = false: out  = d - history   (ngspice NIintegrate)
///   accumulate = true:  out += d - history   (the Newton residual's dynamic part)
/// `i_prev` may alias `out`: with `accumulate` false and `i_prev == out` it
/// advances the dynamic current in place. q2 is read by gear only, i_prev by
/// trap only. With `accumulate` every element rounds (out + d) - history.
/// Asserts that every input the method reads is at least as long as `out`.
pub fn companionAt(
    method: Method,
    comptime accumulate: bool,
    out: []f64,
    q0: []const f64,
    q1: []const f64,
    q2: []const f64,
    i_prev: []const f64,
    c: Coeffs,
) void {
    const n = out.len;
    std.debug.assert(q0.len >= n);
    std.debug.assert(q1.len >= n);
    if (method == .gear_2) std.debug.assert(q2.len >= n);
    if (method == .trapezoidal) std.debug.assert(i_prev.len >= n);
    // One plain loop per method, so the method's switch is outside it.
    switch (method) {
        .backward_euler => for (out, q0[0..n], q1[0..n]) |*o, a, b| {
            const d = c.ag0 * (a - b);
            o.* = if (accumulate) o.* + d else d;
        },
        .trapezoidal => for (out, q0[0..n], q1[0..n], i_prev[0..n]) |*o, a, b, p| {
            const d = c.ag0 * (a - b);
            o.* = (if (accumulate) o.* + d else d) - c.ag1 * p;
        },
        .gear_2 => for (out, q0[0..n], q1[0..n], q2[0..n]) |*o, a, b, b2| {
            const d = c.ag0 * (a - b);
            o.* = (if (accumulate) o.* + d else d) - c.ag2 * (b - b2);
        },
    }
}

/// Step history and tolerances for one `stepBound`: `dt` is the step just
/// taken, `dt1`/`dt2` the two before it, all in seconds.
pub const LteIn = struct { dt: f64, dt1: f64, dt2: f64, reltol: f64, abstol: f64, chgtol: f64, trtol: f64 };

/// Returns ngspice CKTterr's next-step bound in seconds, min over every
/// charge state j of
///   i_new_j     = what `companionAt` writes under `cur_method`
///   tol_j       = max(abstol + reltol*max(|i_new_j|, |i_prev_j|),
///                     reltol*max(|q0_j|, |q1_j|, chgtol)/dt)
///   del_j       = trtol*tol_j / max(abstol, lteCoeff(method)*|dd_j|)
/// with dd_j the divided difference over order+2 charge points, and the
/// square root taken at order 2. The caller accepts the step when
/// del > 0.9*dt (dctran.c:872-913).
///
/// `method` sets the coefficient and order; at the BE-to-order-2 promotion
/// probe (dctran.c:901-913) it is the method being probed. `cur_method` and
/// `c` are what the step integrated with. `q` is the charge history
/// [cur, prev, prev2, prev3] over one index space (per state or per row).
/// Each state rounds as cktterr.c does, divisions included, and the min is
/// exact, so the result does not depend on how the loop is vectorized. A
/// NaN del_j is skipped, as a float min would. An empty history returns
/// infinity. Asserts that `q[1]`, `q[2]`, `i_prev` (and `q[3]` at order 2)
/// are at least as long as `q[0]`.
pub fn stepBound(method: Method, cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    // Both methods comptime: a runtime switch stayed inside the loop.
    const min_del = switch (method) {
        inline else => |m| switch (cur_method) {
            inline else => |cm| minDel(m, cm, q, i_prev, c, lte),
        },
    };
    // sqrt is monotone, so one sqrt of the min equals the min of the sqrts.
    return if (method == .backward_euler) min_del else @sqrt(min_del);
}

/// The min over the states of del_j, before the order-2 root.
fn minDel(comptime method: Method, comptime cur_method: Method, q: [4][]const f64, i_prev: []const f64, c: Coeffs, lte: LteIn) f64 {
    const n = q[0].len;
    std.debug.assert(q[1].len >= n);
    std.debug.assert(q[2].len >= n);
    std.debug.assert(i_prev.len >= n);
    if (method != .backward_euler) std.debug.assert(q[3].len >= n);
    // cktterr.c's deltmp sums: d0+d1, d1+d2, then (d1+d2)+d0.
    const sum01 = lte.dt + lte.dt1;
    const sum12 = lte.dt1 + lte.dt2;
    const sum012 = lte.dt + sum12;
    const coeff = lteCoeff(method);
    // del_j > 0 (or NaN), so its bit pattern, sign cleared, orders like its
    // value, and a NaN's sorts above inf's and never wins: an exact min that
    // vectorizes, where a float `@min` reduction does not. The sign is
    // cleared because x86's 0/0 is the negative default NaN.
    // BE reads no q3: q0 stands in, so the loop needs no fourth length.
    const q3 = if (method == .backward_euler) q[0] else q[3][0..n];
    var m: i64 = @bitCast(std.math.inf(f64));
    for (q[0], q[1][0..n], q[2][0..n], q3, i_prev[0..n]) |qc, qp, qp2, qp3, ip| {
        const i_new = switch (cur_method) {
            .trapezoidal => c.ag0 * (qc - qp) - c.ag1 * ip,
            .gear_2 => c.ag0 * (qc - qp) - c.ag2 * (qp - qp2),
            .backward_euler => c.ag0 * (qc - qp),
        };
        const volttol = lte.abstol + lte.reltol * @max(@abs(i_new), @abs(ip));
        const chargetol = lte.reltol * @max(@max(@abs(qc), @abs(qp)), lte.chgtol) / lte.dt;
        const tol = @max(volttol, chargetol);
        const f12 = (qp - qp2) / lte.dt1;
        var dd = ((qc - qp) / lte.dt - f12) / sum01;
        if (method != .backward_euler) {
            const f123 = (f12 - (qp2 - qp3) / lte.dt2) / sum12;
            dd = (dd - f123) / sum012;
        }
        const del = lte.trtol * tol / @max(lte.abstol, coeff * @abs(dd));
        m = @min(m, @as(i64, @bitCast(@as(u64, @bitCast(del)) & 0x7fff_ffff_ffff_ffff)));
    }
    return @bitCast(m);
}

// ---------------------------------------------------------------------------
// Tests. Oracles: the methods' exactness on low-degree charge histories
// (BDF2 and the trapezoid differentiate a quadratic exactly), hand-evaluated
// CKTterr bounds on polynomial charges, and the `w == 1` instantiation for
// the vector bodies, which must agree bit for bit.
// ---------------------------------------------------------------------------

const testing = std.testing;
const methods = [_]Method{ .backward_euler, .trapezoidal, .gear_2 };

fn expectBits(want: f64, got: f64) !void {
    try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
}

test coeffs {
    const dt: f64 = 1e-9; // f64: a comptime_float dt would divide in f128
    const be = coeffs(.backward_euler, dt, 5e-9, 0.5);
    try expectBits(1.0 / dt, be.ag0);
    try testing.expectEqual(0, be.ag2);
    // At xmu = 0.5 the trapezoid's coefficients are exactly 2/dt and 1.
    const tr = coeffs(.trapezoidal, dt, 5e-9, 0.5);
    try expectBits(2.0 / dt, tr.ag0);
    try testing.expectEqual(1, tr.ag1);
    // Uniform-step BDF2: 3/(2dt) and 1/(2dt).
    const g2 = coeffs(.gear_2, dt, dt, 0.5);
    try expectBits(3.0 / (2.0 * dt), g2.ag0);
    try expectBits(1.0 / (2.0 * dt), g2.ag2);
    // dt = 2 after 1, r = 2: (1 + 2r)/((1 + r)dt) = 5/6 and
    // r^2/((1 + r)dt) = 2/3.
    const v = coeffs(.gear_2, 2, 1, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 5.0 / 6.0), v.ag0, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), v.ag2, 1e-15);
}

test lteCoeff {
    try testing.expectEqual(0.5, lteCoeff(.backward_euler));
    try testing.expectEqual(0.08333333333, lteCoeff(.trapezoidal));
    try testing.expectEqual(0.2222222222, lteCoeff(.gear_2));
}

test "companionAt differentiates q = t^2 as each method should" {
    // q(t) = t^2 at t = 0, 1, 3 (steps 1 then 2), so q = 0, 1, 9 and
    // dq/dt(3) = 6, dq/dt(1) = 2. BDF2 and the trapezoid are exact on a
    // quadratic; backward Euler gives the chord (9 - 1)/2 = 4.
    const q0 = [_]f64{9};
    const q1 = [_]f64{1};
    const q2 = [_]f64{0};
    const i_prev = [_]f64{2};
    var out: [1]f64 = undefined;
    companionAt(.backward_euler, false, &out, &q0, &q1, &q2, &i_prev, coeffs(.backward_euler, 2, 1, 0.5));
    try testing.expectEqual(4, out[0]);
    companionAt(.trapezoidal, false, &out, &q0, &q1, &q2, &i_prev, coeffs(.trapezoidal, 2, 1, 0.5));
    try testing.expectEqual(6, out[0]);
    companionAt(.gear_2, false, &out, &q0, &q1, &q2, &i_prev, coeffs(.gear_2, 2, 1, 0.5));
    try testing.expectApproxEqAbs(@as(f64, 6), out[0], 1e-14);
    // Accumulating adds onto what is there: (10 + 8) - 2.
    out = .{10};
    companionAt(.trapezoidal, true, &out, &q0, &q1, &q2, &i_prev, coeffs(.trapezoidal, 2, 1, 0.5));
    try testing.expectEqual(16, out[0]);
}

test "companionAt converges at each method's order on q = sin(t) (method of manufactured solutions)" {
    // dq/dt(1) = cos(1). Halving h divides backward Euler's error by 2 and
    // the trapezoid's and BDF2's by 4. The trapezoid gets the exact
    // previous current, so only its own truncation error shows.
    const t = 1.0;
    const orders = [_]f64{ 1, 2, 2 };
    for (methods, orders) |m, order| {
        var err: [2]f64 = undefined;
        for (&err, [_]f64{ 1e-2, 5e-3 }) |*e, h| {
            var out: [1]f64 = undefined;
            const q = [3]f64{ @sin(t), @sin(t - h), @sin(t - 2 * h) };
            companionAt(m, false, &out, q[0..1], q[1..2], q[2..3], &.{@cos(t - h)}, coeffs(m, h, h, 0.5));
            e.* = @abs(out[0] - @cos(t));
        }
        try testing.expectApproxEqAbs(std.math.pow(f64, 2, order), err[0] / err[1], 0.1);
    }
}

test "companionAt advances the dynamic current in place" {
    // In place, the trapezoid's previous current is its own output slot:
    // i = 2/2·(9 - 1) - 2 = 6, as above.
    var i_cur = [_]f64{2};
    companionAt(.trapezoidal, false, &i_cur, &.{9}, &.{1}, &.{0}, &i_cur, coeffs(.trapezoidal, 2, 1, 0.5));
    try testing.expectEqual(6, i_cur[0]);
}

/// Fills `row` with `scale`-sized values and, one in 32, a NaN or an Inf.
fn fillEdgy(rnd: std.Random, row: []f64, scale: f64) void {
    for (row) |*e| e.* = switch (rnd.uintLessThan(u8, 32)) {
        0 => std.math.nan(f64),
        1 => -std.math.inf(f64),
        else => (rnd.float(f64) - 0.5) * scale,
    };
}

const len_max = 200;
const pad = 3; // misaligned starts

test "companionAt equals its one-element instantiation bit for bit: lengths 0..200, every start, NaN/Inf" {
    var prng: std.Random.DefaultPrng = .init(5);
    const rnd = prng.random();
    var q: [3][len_max + pad]f64 = undefined;
    var ip: [len_max + pad]f64 = undefined;
    var out: [len_max + pad]f64 = undefined;
    var base: [len_max + pad]f64 = undefined;
    for (&q) |*row| fillEdgy(rnd, row, 1e-12);
    fillEdgy(rnd, &ip, 1);
    fillEdgy(rnd, &base, 1);
    inline for (.{ false, true }) |acc| for (methods) |m| {
        const c = coeffs(m, 1e-9, 3e-9, 0.5);
        for (0..len_max + 1) |len| for (0..pad + 1) |off| {
            const e = off + len;
            @memcpy(out[off..e], base[off..e]);
            companionAt(m, acc, out[off..e], q[0][off..e], q[1][off..e], q[2][off..e], ip[off..e], c);
            for (off..e) |j| {
                var one = [1]f64{base[j]};
                companionAt(m, acc, &one, q[0][j..][0..1], q[1][j..][0..1], q[2][j..][0..1], ip[j..][0..1], c);
                try expectBits(one[0], out[j]);
            }
        };
    };
}

test stepBound {
    const lte: LteIn = .{ .dt = 1, .dt1 = 1, .dt2 = 1, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
    // Order 1 on q = t^2 at t = 2, 1, 0: the divided difference is 1.
    // i_new = 1·(4 - 1) = 3; tol = max(1e-12 + 1e-3·3, 1e-3·4/1) = 4e-3;
    // del = 7·4e-3 / max(1e-12, 0.5·1) = 0.056.
    const be = coeffs(.backward_euler, 1, 1, 0.5);
    const d1 = stepBound(.backward_euler, .backward_euler, .{ &.{4}, &.{1}, &.{0}, &.{0} }, &.{0}, be, lte);
    try testing.expectApproxEqRel(@as(f64, 0.056), d1, 1e-14);
    // Order 2 on q = t^3 at t = 3, 2, 1, 0: the third divided difference
    // is 1. Trapezoid: i_prev = q'(2) = 12, i_new = 2·(27 - 8) - 12 = 26;
    // tol = max(1e-12 + 1e-3·26, 1e-3·27/1) = 0.027;
    // del = sqrt(7·0.027 / 0.08333333333) = 1.5059880477914558.
    const tr = coeffs(.trapezoidal, 1, 1, 0.5);
    const d2 = stepBound(.trapezoidal, .trapezoidal, .{ &.{27}, &.{8}, &.{1}, &.{0} }, &.{12}, tr, lte);
    try testing.expectApproxEqRel(@as(f64, 1.5059880477914558), d2, 1e-14);
    // q = t^2 at t = 2, 1, 0, -1 has no third difference: only the
    // abstol floor bounds it, sqrt(7·6e-3 / 1e-12) ≈ 2e5.
    const flat = stepBound(.trapezoidal, .trapezoidal, .{ &.{4}, &.{1}, &.{0}, &.{1} }, &.{0}, tr, lte);
    try testing.expect(flat > 1e5);
    // No states: nothing bounds the step.
    try testing.expectEqual(std.math.inf(f64), stepBound(.gear_2, .gear_2, .{ &.{}, &.{}, &.{}, &.{} }, &.{}, tr, lte));
}

test "stepBound equals the strict min of its one-state bounds: lengths 0..200, every start, NaN/Inf" {
    var prng: std.Random.DefaultPrng = .init(9);
    const rnd = prng.random();
    var q: [4][len_max + pad]f64 = undefined;
    var ip: [len_max + pad]f64 = undefined;
    for (&q) |*row| fillEdgy(rnd, row, 1e-12);
    fillEdgy(rnd, &ip, 1e-3);
    const lte: LteIn = .{ .dt = 1e-9, .dt1 = 2e-9, .dt2 = 1.5e-9, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
    for (0..len_max + 1) |len| for (0..pad + 1) |off| {
        const e = off + len;
        const hist: [4][]const f64 = .{ q[0][off..e], q[1][off..e], q[2][off..e], q[3][off..e] };
        for (methods) |m| for (methods) |cm| {
            const c = coeffs(cm, lte.dt, lte.dt1, 0.5);
            // A float min that skips NaN, over one state at a time.
            var want = std.math.inf(f64);
            for (off..e) |j| {
                const one: [4][]const f64 = .{ q[0][j..][0..1], q[1][j..][0..1], q[2][j..][0..1], q[3][j..][0..1] };
                const d = stepBound(m, cm, one, ip[j..][0..1], c, lte);
                if (d < want) want = d;
            }
            try expectBits(want, stepBound(m, cm, hist, ip[off..e], c, lte));
        };
    };
}
