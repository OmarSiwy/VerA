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

/// §4.5.12 how many samples a filter of period `period` owes at time `t` when
/// `nk` of them have already been taken. "T specifies the sampling period of
/// the filter", so the instants are k·T and the k-th is owed once t reaches it.
///
/// ponytail: the 1e-9 is a RELATIVE tolerance on the sample instant, and it is
/// load-bearing rather than defensive — the residual and the accepted-step
/// sampler reach k·T by two different float routes, and a filter whose two
/// halves disagree about which timepoint IS a sample instant drops that sample
/// for the rest of the run. 1e-9 of a period is some seven orders below any
/// timestep a host takes and seven above f64's own noise at these magnitudes.
/// The upgrade path, if a host ever needs it, is a host-supplied time
/// tolerance the way §4.5.8's `time_tol` is spelled.
pub fn zZiDue(t: f64, nk: f64, period: f64) u32 {
    if (!(period > 0.0)) return 0;
    const n = @floor(t / period + 1e-9) + 1.0 - nk;
    if (!(n >= 1.0)) return 0;
    // ponytail: a step that jumped 4096 sample instants has already aliased
    // the filter beyond what replaying the held input could recover; the
    // ceiling only keeps the replay loop bounded.
    return if (n > 4096.0) 4096 else @intFromFloat(n);
}

/// §4.5.12 the Z-filter as the RESIDUAL sees it, the counterpart of
/// `zZiStep`'s accepted-step side.
///
/// `dt <= 0` is a static analysis: there is no history and no clock, a constant
/// input makes every sample equal, so z = 1 and the filter IS its DC gain
/// H(1) = ∏ Σ_k num[i][k] / Σ_k den[i][k] — the exact value of the transfer
/// function at z = 1, applied to the input so the operating point gets the
/// right Jacobian too. This mirrors `zLaplace`'s H(0) branch.
///
/// THE SAMPLE INSTANT. §4.5.12: "a filter with unity transfer function acts
/// like a simple sample-and-hold which samples every T seconds and EXHIBITS NO
/// DELAY", and with τ = 0 "the output is abruptly discontinuous". So at
/// t = k·T the output is the output OF the k-th sample, not the (k−1)-th. This
/// used to answer `inst.__out`, which `updateState` writes AFTER the timepoint
/// has been evaluated — the whole filter ran one sample period late. The
/// recurrence is therefore evaluated HERE, on a COPY of the history, and
/// `updateState` re-runs the identical `zZiStep` on the accepted solution; the
/// two see the same input and the same sections, so they cannot disagree.
/// Between samples the output is the held constant and carries no derivative.
pub fn zZiEval(
    comptime S: type,
    comptime NS: usize,
    comptime D: usize,
    uin: S,
    sec: [NS][2][D + 1]f64,
    dt: f64,
    out: f64,
    t: f64,
    nk: f64,
    period: f64,
    uh: []const f64,
    yh: []const f64,
) S {
    if (!(dt > 0.0)) {
        var y = uin;
        for (0..NS) |i| {
            var num: f64 = 0.0;
            var den: f64 = 0.0;
            for (sec[i][0]) |c| num += c;
            for (sec[i][1]) |c| den += c;
            y = y.scale(num / den);
        }
        return y;
    }
    // The SAME count `updateState`'s sampler takes, so a timepoint is a sample
    // instant for both halves of the operator or for neither.
    var k = zZiDue(t, nk, period);
    if (k == 0) return S.con(out);
    // Replaying the samples a wide step jumped over needs a mutable history,
    // and the residual may not move the accepted state — so it works on a
    // comptime-sized stack copy. Nothing here allocates.
    var ub: [NS * D]f64 = undefined;
    var yb: [NS * D]f64 = undefined;
    @memcpy(&ub, uh);
    @memcpy(&yb, yh);
    while (k > 1) : (k -= 1) _ = zZiStep(NS, D, uin.val(), sec, &ub, &yb);
    // The LAST sample is the one the solver differentiates through: each
    // section is linear in its input with gain b[0]/a[0], and reads its own
    // history un-pushed, exactly as `zZiStep` does.
    var y = uin;
    for (0..NS) |i| y = zSec(S, D, y, sec[i][0], sec[i][1], ub[i * D ..][0..D], yb[i * D ..][0..D]);
    return y;
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
