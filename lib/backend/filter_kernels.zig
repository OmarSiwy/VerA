// §4.5.11 / §4.5.12 filter kernels — EMITTED VERBATIM into every device that
// uses a `laplace_*` or `zi_*` operator (`codegen.filt_txt` is `@embedFile` of
// this file) and `@import`ed by codegen.zig's tests. One source, so the
// numerics the tests check are the numerics the device runs.
//
// A filter is a CASCADE of sections, `H = ∏ num[i]/den[i]`, each section a
// polynomial ratio in `s` (§4.5.11) or `z⁻¹` (§4.5.12) with ascending
// coefficients. Sections are realised in direct form I: the state is the
// section's own past inputs and outputs, so a static analysis can seed it with
// the steady state and the first transient step starts consistent.
//
// Nothing here allocates, branches on data, or depends on the enclosing
// device — `NS` (sections) and `D` (degree) are structural constants from the
// flattened call, while every COEFFICIENT is a runtime read of Model.

/// Trapezoidal (bilinear) transform of `P(s) = Σ pᵢsⁱ` into `Σ qⱼz⁻ʲ`:
/// substitute `s = k(1−z⁻¹)/(1+z⁻¹)` and clear the denominator by `(1+z⁻¹)ᴰ`,
/// so a section's numerator and denominator stay a matched pair. `k = 2/dt`.
pub fn zBilin(comptime D: usize, p: [D + 1]f64, k: f64) [D + 1]f64 {
    var q: [D + 1]f64 = @splat(0.0);
    var ki: f64 = 1.0; // kⁱ
    for (0..D + 1) |i| {
        var t: [D + 1]f64 = @splat(0.0);
        t[0] = p[i] * ki;
        var deg: usize = 0;
        for (0..i) |_| { // × (1 − z⁻¹)
            var j = deg + 1;
            while (j > 0) : (j -= 1) t[j] -= t[j - 1];
            deg += 1;
        }
        for (0..D - i) |_| { // × (1 + z⁻¹)
            var j = deg + 1;
            while (j > 0) : (j -= 1) t[j] += t[j - 1];
            deg += 1;
        }
        for (0..D + 1) |j| q[j] += t[j];
        ki *= k;
    }
    return q;
}

/// One direct-form-I section on already-DISCRETE coefficients, in the solver's
/// scalar interface. Linear in `u` with gain `b[0]/a[0]`, so the derivative the
/// solver sees is the exact one.
pub fn zSec(comptime S: type, comptime D: usize, u: S, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) S {
    var acc: f64 = 0.0;
    for (1..D + 1) |j| acc += b[j] * uh[j - 1] - a[j] * yh[j - 1];
    return u.scale(b[0]).addC(acc).scale(1.0 / a[0]);
}

/// The same section on the accepted solution, where no derivative is wanted.
pub fn zSecR(comptime D: usize, u: f64, b: [D + 1]f64, a: [D + 1]f64, uh: []const f64, yh: []const f64) f64 {
    var acc = b[0] * u;
    for (1..D + 1) |j| acc += b[j] * uh[j - 1] - a[j] * yh[j - 1];
    return acc / a[0];
}

/// Newest-first push of one accepted (input, output) pair.
pub fn zPush(uh: []f64, yh: []f64, u: f64, y: f64) void {
    if (uh.len == 0) return;
    var j = uh.len;
    while (j > 1) : (j -= 1) {
        uh[j - 1] = uh[j - 2];
        yh[j - 1] = yh[j - 2];
    }
    uh[0] = u;
    yh[0] = y;
}

/// §4.5.11 the cascade, in the residual. `dt <= 0` is a static analysis, where
/// the filter IS its DC gain `H(0) = ∏ num[i][0]/den[i][0]` — the exact value
/// of the transfer function at s = 0, not a stand-in for one.
pub fn zLaplace(
    comptime S: type,
    comptime NS: usize,
    comptime D: usize,
    uin: S,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    uh: []const f64,
    yh: []const f64,
) S {
    var y = uin;
    for (0..NS) |i| {
        if (!(dt > 0.0)) {
            y = y.scale(sec[i][0][0] / sec[i][1][0]);
            continue;
        }
        const k = 2.0 / dt;
        y = zSec(S, D, y, zBilin(D, sec[i][0], k), zBilin(D, sec[i][1], k), uh[i * D ..][0..D], yh[i * D ..][0..D]);
    }
    return y;
}

/// §4.5.11 advance the cascade once the step is accepted.
pub fn zLaplaceStep(
    comptime NS: usize,
    comptime D: usize,
    uin: f64,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    uh: []f64,
    yh: []f64,
) void {
    var u = uin;
    for (0..NS) |i| {
        const us = uh[i * D ..][0..D];
        const ys = yh[i * D ..][0..D];
        const k = 2.0 / dt;
        const y = if (!(dt > 0.0))
            u * sec[i][0][0] / sec[i][1][0]
        else
            zSecR(D, u, zBilin(D, sec[i][0], k), zBilin(D, sec[i][1], k), us, ys);
        zPush(us, ys, u, y);
        u = y;
    }
}

/// §4.5.12 one SAMPLE of a Z-filter. The sections are already in `z⁻¹`, so
/// there is nothing to discretise — only the filter's own clock advances.
/// Returns the new held output.
pub fn zZiStep(
    comptime NS: usize,
    comptime D: usize,
    uin: f64,
    sec: [NS][2][D + 1]f64,
    uh: []f64,
    yh: []f64,
) f64 {
    var u = uin;
    for (0..NS) |i| {
        const us = uh[i * D ..][0..D];
        const ys = yh[i * D ..][0..D];
        const y = zSecR(D, u, sec[i][0], sec[i][1], us, ys);
        zPush(us, ys, u, y);
        u = y;
    }
    return u;
}

// ===========================================================================
// Tests. They live HERE, beside the kernels, for the reason the header gives:
// this file is the one source, so what the tests check is what the device
// runs. codegen.zig's tests `@import` this file, so `zig build test-va`
// collects them; `zig build test-kernels` runs them without codegen.
//
// NOT `std`: this file is embedded verbatim into device.zig, whose file-scope
// `std` a test-local of the same name would shadow (AstGen error). Same
// reason limit_kernels.zig spells it `stdx`.
//
// `zBilin` is NOT re-tested here beyond the degree below: codegen.zig's
// "§4.5.11 the bilinear transform is the one the emitted filter runs" already
// pins D = 0 and D = 2 exactly and the DC/Nyquist closed forms at D = 3.
// `zSec`/`zLaplace`/`zLaplaceStep`/`zZiStep` remain uncovered — they need a
// solver scalar type or a coefficient cascade, which is a fixture, not a
// one-liner.
// ===========================================================================

test "zBilin: D = 1, the degree the other rows skip" {
    const stdx = @import("std");
    // P(s) = 2 + 3s, k = 10. Clearing (1+z⁻¹) by hand:
    //   P·(1+z⁻¹) = 2(1+z⁻¹) + 3k(1−z⁻¹) = (2+3k) + (2−3k)z⁻¹.
    // Dyadic, so exact. codegen.zig covers D = 0, 2 and 3; a first-order
    // section is the commonest filter there is and was the gap between them.
    const q = zBilin(1, .{ 2.0, 3.0 }, 10.0);
    try stdx.testing.expectEqual([2]f64{ 32.0, -28.0 }, q);
}

test "zPush: newest first, and an empty history is a no-op" {
    const stdx = @import("std");
    var uh: [3]f64 = .{ 0, 0, 0 };
    var yh: [3]f64 = .{ 0, 0, 0 };
    for ([_]f64{ 1, 2, 3 }) |v| zPush(&uh, &yh, v, -v);
    // Newest at index 0, oldest last — the order zSec/zSecR index with.
    try stdx.testing.expectEqualSlices(f64, &.{ 3, 2, 1 }, &uh);
    try stdx.testing.expectEqualSlices(f64, &.{ -3, -2, -1 }, &yh);

    // A degree-0 section keeps no history; the guard is what makes that legal.
    var none: [0]f64 = .{};
    zPush(&none, &none, 1.0, 1.0);
}

test "zSecR: unit section is the identity, and gain is b0/a0" {
    const stdx = @import("std");
    const uh: [1]f64 = .{ 0 };
    const yh: [1]f64 = .{ 0 };
    try stdx.testing.expectApproxEqAbs(
        @as(f64, 4.25),
        zSecR(1, 4.25, .{ 1, 0 }, .{ 1, 0 }, &uh, &yh),
        1e-12,
    );
    // b[0]/a[0] is the instantaneous gain the solver differentiates through.
    try stdx.testing.expectApproxEqAbs(
        @as(f64, 2.0),
        zSecR(1, 4.0, .{ 3, 0 }, .{ 6, 0 }, &uh, &yh),
        1e-12,
    );
}
