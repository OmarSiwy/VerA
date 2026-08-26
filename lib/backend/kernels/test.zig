//! The kernel files' own tests: kernels.zig's `test` block pulls this file in,
//! so `zig build test-kernels` (and `zig build test`) run it. They sit here and
//! not beside the kernels because a kernel file's bytes are spliced verbatim
//! into every device that uses it (`codegen/kernel_text.zig`), and a test block
//! there shipped in every device's text. They still call the kernels through
//! the files the devices embed, so what they check is what a device runs.
//! LRM: §4.5.11, §4.5.12, §4.5.15, §9.17.3.

const std = @import("std");
const gm = @import("contract").gm;
const filt = @import("filter_kernels.zig");
const limit = @import("limit_kernels.zig");

// ---------------------------------------------------------------- filter
// `zBilin` is NOT re-tested here beyond the degree below: codegen's
// "§4.5.11 the bilinear transform is the one the emitted filter runs" already
// pins D = 0 and D = 2 exactly and the DC/Nyquist closed forms at D = 3.
// `zSec`/`zLaplace`/`zZiStep` remain uncovered: they need a solver scalar type
// or a coefficient cascade, which is a fixture, not a one-liner.

test "zBilin: D = 1, the degree the other rows skip" {
    // P(s) = 2 + 3s, k = 10. Clearing (1+z⁻¹) by hand:
    //   P·(1+z⁻¹) = 2(1+z⁻¹) + 3k(1−z⁻¹) = (2+3k) + (2−3k)z⁻¹.
    // Dyadic, so exact. codegen.zig covers D = 0, 2 and 3; a first-order
    // section is the commonest filter there is and was the gap between them.
    const qz = filt.zBilin(1, .{ 2.0, 3.0 }, 10.0, 1);
    try std.testing.expectEqual([2]f64{ 32.0, -28.0 }, qz);
}

test "zDeg/zBilin: a zero-padded section transforms at its own degree" {
    // The same 2 + 3s padded to D = 3. Its effective degree is 1, and the
    // transform at d = 1 is the row above, bit for bit, with zeros after.
    // Untrimmed, `(1+z⁻¹)²` would multiply both sides: poles on z = −1.
    const sec: [2][4]f64 = .{ .{ 2.0, 3.0, 0.0, 0.0 }, .{ 1.0, 0.0, 0.0, 0.0 } };
    try std.testing.expectEqual(@as(usize, 1), filt.zDeg(3, sec));
    try std.testing.expectEqual([4]f64{ 32.0, -28.0, 0.0, 0.0 }, filt.zBilin(3, sec[0], 10.0, 1));
    // Either side sets the degree: a denominator-only s² is degree 2.
    try std.testing.expectEqual(@as(usize, 2), filt.zDeg(2, .{ .{ 1.0, 0.0, 0.0 }, .{ 1.0, 0.0, 5.0 } }));
    try std.testing.expectEqual(@as(usize, 0), filt.zDeg(2, .{ .{ 4.0, 0.0, 0.0 }, .{ 2.0, 0.0, 0.0 } }));
}

test "zPush: newest first, and an empty history is a no-op" {
    var uh: [3]f64 = .{ 0, 0, 0 };
    var yh: [3]f64 = .{ 0, 0, 0 };
    for ([_]f64{ 1, 2, 3 }) |v| filt.zPush(&uh, &yh, v, -v);
    // Newest at index 0, oldest last — the order zSec/zSecR index with.
    try std.testing.expectEqualSlices(f64, &.{ 3, 2, 1 }, &uh);
    try std.testing.expectEqualSlices(f64, &.{ -3, -2, -1 }, &yh);

    // A degree-0 section keeps no history; the guard is what makes that legal.
    var none: [0]f64 = .{};
    filt.zPush(&none, &none, 1.0, 1.0);
}

test "zH0: the gain at s = 0, common powers of s cancelled, a pole answers 0" {
    // den[0] != 0: num[0]/den[0], the pair unchanged.
    try std.testing.expectEqual([2]f64{ 3.0, 2.0 }, filt.zH0(1, .{ .{ 3.0, 5.0 }, .{ 2.0, 7.0 } }));
    // s / (s + s²) = 1 / (1 + s): H(0) = 1, not 0/0.
    try std.testing.expectEqual([2]f64{ 1.0, 1.0 }, filt.zH0(2, .{ .{ 0.0, 1.0, 0.0 }, .{ 0.0, 1.0, 1.0 } }));
    // s² / (s + s²): a zero at s = 0 remains, H(0) = 0.
    const z = filt.zH0(2, .{ .{ 0.0, 0.0, 1.0 }, .{ 0.0, 1.0, 1.0 } });
    try std.testing.expectEqual(@as(f64, 0.0), z[0] / z[1]);
    // 1 / s: a pole at s = 0, VerA's static output 0.
    try std.testing.expectEqual([2]f64{ 0.0, 1.0 }, filt.zH0(1, .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } }));
}

test "zLaplaceStep: a slow pole holds H(0), and a step follows the bilinear difference equation" {
    // 0.625 / ((1 + s/1e5)(1 + s/1e9)) at dt = 0.1 ns: ω·dt = 1e-5 on the
    // slow pole. Direct form on the bilinear coefficients drifts off H(0)
    // here (specification/Vague_Decisions.md); the state-space step may not move at all.
    const sec: [1][2][3]f64 = .{.{ .{ 0.625, 0.0, 0.0 }, .{ 1.0, 1e-5 + 1e-9, 1e-14 } }};
    var uh: [2]f64 = undefined;
    var yh: [2]f64 = undefined;
    filt.zLaplaceStep(1, 2, 1.0, sec, 0.0, &uh, &yh);
    for (0..2000) |_| filt.zLaplaceStep(1, 2, 1.0, sec, 1e-10, &uh, &yh);
    const f = filt.zSsForm(2, sec[0]).?;
    try std.testing.expectEqual(filt.ZSs{ .off = 0, .m = 2 }, f);
    try std.testing.expectEqual(@as(f64, 0.625), filt.zSsStep(2, f, sec[0], &yh, 1.0, 1.0, 1e-10, null)[0]);

    // First order, 1/(1 + s), stepped 0 -> 1 from rest with h = 0.5: the
    // bilinear difference equation of y' = u − y,
    //   (1 + h/2) y_n = (1 − h/2) y_{n−1} + h/2 (u_{n−1} + u_n),
    // so y = 0.2, 0.52, 0.712, ... (u_0 = 0 is the static point).
    const one: [1][2][2]f64 = .{.{ .{ 1.0, 0.0 }, .{ 1.0, 1.0 } }};
    var uh1: [1]f64 = undefined;
    var yh1: [1]f64 = undefined;
    filt.zLaplaceStep(1, 1, 0.0, one, 0.0, &uh1, &yh1);
    var want: f64 = 0.0;
    var u_prev: f64 = 0.0;
    for (0..5) |_| {
        want = (0.75 * want + 0.25 * (u_prev + 1.0)) / 1.25;
        u_prev = 1.0;
        const got = filt.zSsStep(1, filt.zSsForm(1, one[0]).?, one[0], &yh1, uh1[0], 1.0, 0.5, null)[0];
        filt.zLaplaceStep(1, 1, 1.0, one, 0.5, &uh1, &yh1);
        try std.testing.expectApproxEqRel(want, got, 1e-15);
    }
    // A bare gain (D = 0) has no state to index: 3/2 at every point.
    var none: [0]f64 = .{};
    filt.zLaplaceStep(1, 0, 2.0, .{.{ .{3.0}, .{2.0} }}, 0.0, &none, &none);
    filt.zLaplaceStep(1, 0, 2.0, .{.{ .{3.0}, .{2.0} }}, 1e-9, &none, &none);
    // An improper section (s / 1) keeps direct form.
    try std.testing.expectEqual(@as(?filt.ZSs, null), filt.zSsForm(1, .{ .{ 0.0, 1.0 }, .{ 1.0, 0.0 } }));
}

test "zRootSecs: conjugates pair within tolerance, reals pair in order, an orphan is NaN" {
    // -1 ± 1j (the partner off by 1e-12 relative) and -2: (1 + s + s²/2), (1 + s/2).
    const s = filt.zRootSecs(3, false, .{ -1, 1, -2, 0, -1, -1 - 1e-12 });
    try std.testing.expectApproxEqRel(@as(f64, 1.0), s[0][1], 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), s[0][2], 1e-12);
    try std.testing.expectEqual([3]f64{ 1, 0.5, 0 }, s[1]);
    // Two reals and a zero root in z⁻¹: (1 − 0.5z⁻¹)(1 − 0.25z⁻¹), z⁻¹.
    const z = filt.zRootSecs(3, true, .{ 0.5, 0, 0.25, 0, 0, 0 });
    try std.testing.expectEqual([3]f64{ 1, -0.75, 0.125 }, z[0]);
    try std.testing.expectEqual([3]f64{ 0, 1, 0 }, z[1]);
    // -1 + 1j alone has no conjugate.
    try std.testing.expect(filt.zRootSecs(1, false, .{ -1, 1 })[0][0] != filt.zRootSecs(1, false, .{ -1, 1 })[0][0]);
}

test "zSecR: unit section is the identity, and gain is b0/a0" {
    const uh: [1]f64 = .{0};
    const yh: [1]f64 = .{0};
    try std.testing.expectApproxEqAbs(
        @as(f64, 4.25),
        filt.zSecR(1, 4.25, .{ 1, 0 }, .{ 1, 0 }, &uh, &yh),
        1e-12,
    );
    // b[0]/a[0] is the instantaneous gain the solver differentiates through.
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.0),
        filt.zSecR(1, 4.0, .{ 3, 0 }, .{ 6, 0 }, &uh, &yh),
        1e-12,
    );
}

// ------------------------------------------------------------------ oracles
// limit_kernels.zig's original branchy ngspice transcriptions, verbatim, kept
// as the differential test's reference (simd-first T8: keep the scalar
// reference after the fast one ships). Test-only, so they live here and not in
// the device text.

fn zPnjlimOracle(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    var vnew = vnew0;
    if (vnew > vcrit and @abs(vnew - vold) > vt + vt) {
        if (vold > 0.0) {
            // The guard above makes |arg| > 2, so both logs take a
            // strictly positive argument (or exactly 0 after rounding).
            const arg = (vnew - vold) / vt;
            vnew = if (arg > 0.0)
                vold + vt * (2.0 + gm.log(arg - 2.0))
            else
                vold - vt * (2.0 + gm.log(2.0 - arg));
        } else {
            vnew = vt * gm.log(vnew / vt);
        }
    } else if (vnew < 0.0) {
        const arg = if (vold > 0.0) -vold - 1.0 else 2.0 * vold - 1.0;
        if (vnew < arg) vnew = arg;
    }
    return vnew;
}

fn zFetlimOracle(vnew0: f64, vold: f64, vto: f64) f64 {
    var vnew = vnew0;
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;
    const delv = vnew - vold;
    if (vold >= vto) {
        if (vold >= vtox) {
            if (delv <= 0.0) { // going off
                if (vnew >= vtox) {
                    if (-delv > vtstlo) vnew = vold - vtstlo;
                } else vnew = if (vnew > vto + 2.0) vnew else vto + 2.0; // ngspice MAX(a,b)
            } else { // staying on
                if (delv >= vtsthi) vnew = vold + vtsthi;
            }
        } else { // middle region
            vnew = if (delv <= 0.0)
                (if (vnew > vto - 0.5) vnew else vto - 0.5) // MAX
            else
                (if (vnew < vto + 4.0) vnew else vto + 4.0); // MIN
        }
    } else { // off
        if (delv <= 0.0) {
            if (-delv > vtsthi) vnew = vold - vtsthi;
        } else {
            const vtemp = vto + 0.5;
            if (vnew <= vtemp) {
                if (delv > vtstlo) vnew = vold + vtstlo;
            } else vnew = vtemp;
        }
    }
    return vnew;
}

fn zLimvdsOracle(vnew0: f64, vold: f64) f64 {
    var vnew = vnew0;
    if (vold >= 3.5) {
        if (vnew > vold) {
            vnew = @min(vnew, 3.0 * vold + 2.0);
        } else if (vnew < 3.5) vnew = @max(vnew, 2.0);
    } else {
        vnew = if (vnew > vold) @min(vnew, 4.0) else @max(vnew, -0.5);
    }
    return vnew;
}

/// ngspice `B4SOIlimit` minus the NaN reset (see zSteplim's header for why
/// the kernel bounds NaN instead of zeroing it).
fn zSteplimOracle(vnew0: f64, vold: f64, lim: f64) f64 {
    const t0 = vnew0 - vold;
    if (@abs(t0) > lim)
        return if (t0 > 0.0) vold + lim else vold - lim;
    return vnew0;
}

// §4.5.15 the branchless limiters against the oracles above.
test "§4.5.15 branchless limiters ≡ branchy ngspice oracles, bit for bit" {
    const expectBits = struct {
        fn eq(a: f64, b: f64) !void {
            try std.testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
        }
    }.eq;

    var prng = std.Random.DefaultPrng.init(0x5eed_4515);
    const rand = prng.random();
    // Signed magnitude in 1e-12..1e3 (log-uniform), both signs.
    const draw = struct {
        fn any(r: std.Random) f64 {
            const m = std.math.pow(f64, 10.0, -12.0 + 15.0 * r.float(f64));
            return if (r.boolean()) m else -m;
        }
        fn pos(r: std.Random) f64 {
            return std.math.pow(f64, 10.0, -12.0 + 15.0 * r.float(f64));
        }
    };

    for (0..1_000_000) |_| {
        const vnew = draw.any(rand);
        const vold = draw.any(rand);
        // vt/vcrit positive: the physical domain (see header) — outside it the
        // ORACLE logs a negative and NaNs, which the clamped kernel cannot.
        const vt = draw.pos(rand);
        const vcrit = draw.pos(rand);
        const vto = draw.any(rand);
        const lim = draw.pos(rand);
        try expectBits(limit.zPnjlim(vnew, vold, vt, vcrit), zPnjlimOracle(vnew, vold, vt, vcrit));
        try expectBits(limit.zFetlim(vnew, vold, vto), zFetlimOracle(vnew, vold, vto));
        try expectBits(limit.zLimvds(vnew, vold), zLimvdsOracle(vnew, vold));
        try expectBits(limit.zSteplim(vnew, vold, lim), zSteplimOracle(vnew, vold, lim));
        try expectBits(limit.zSteplim(vold + lim, vold, lim), zSteplimOracle(vold + lim, vold, lim)); // |Δ| == lim
        try expectBits(limit.zSteplim(vold - lim, vold, lim), zSteplimOracle(vold - lim, vold, lim));

        // Exact boundary hits, derived from the same random draws so they land
        // on every magnitude: each guard's `==` case must stay transparent.
        try expectBits(limit.zPnjlim(vcrit, vold, vt, vcrit), zPnjlimOracle(vcrit, vold, vt, vcrit)); // vnew == vcrit
        try expectBits(limit.zPnjlim(vold + (vt + vt), vold, vt, vcrit), zPnjlimOracle(vold + (vt + vt), vold, vt, vcrit)); // |Δ| == 2vt
        try expectBits(limit.zPnjlim(vold - (vt + vt), vold, vt, vcrit), zPnjlimOracle(vold - (vt + vt), vold, vt, vcrit));
        try expectBits(limit.zPnjlim(-vold - 1.0, vold, vt, vcrit), zPnjlimOracle(-vold - 1.0, vold, vt, vcrit)); // vnew == floor
        try expectBits(limit.zPnjlim(vnew, 0.0, vt, vcrit), zPnjlimOracle(vnew, 0.0, vt, vcrit)); // vold on its sign guard
        try expectBits(limit.zFetlim(vnew, vto, vto), zFetlimOracle(vnew, vto, vto)); // vold == vto
        try expectBits(limit.zFetlim(vnew, vto + 3.5, vto), zFetlimOracle(vnew, vto + 3.5, vto)); // vold == vtox
        try expectBits(limit.zFetlim(vold, vold, vto), zFetlimOracle(vold, vold, vto)); // delv == 0
        try expectBits(limit.zFetlim(vto + 0.5, vold, vto), zFetlimOracle(vto + 0.5, vold, vto)); // vnew == vtemp
        try expectBits(limit.zFetlim(vto + 2.0, vold, vto), zFetlimOracle(vto + 2.0, vold, vto));
        try expectBits(limit.zLimvds(vnew, 3.5), zLimvdsOracle(vnew, 3.5)); // vold on 3.5
        try expectBits(limit.zLimvds(3.5, vold), zLimvdsOracle(3.5, vold)); // vnew on 3.5
        try expectBits(limit.zLimvds(vold, vold), zLimvdsOracle(vold, vold)); // vnew == vold
        try expectBits(limit.zLimvds(4.0, vold), zLimvdsOracle(4.0, vold));
        try expectBits(limit.zLimvds(-0.5, vold), zLimvdsOracle(-0.5, vold));
        try expectBits(limit.zLimvds(3.0 * vold + 2.0, vold), zLimvdsOracle(3.0 * vold + 2.0, vold));
    }

    // Signed-zero ties through the MAX/MIN ternaries: vto placing a bound at
    // exactly 0.0 while vnew is ±0.0.
    for ([_]f64{ -2.0, 0.5, -4.0 }) |vto| {
        for ([_]f64{ 0.0, -0.0 }) |z| {
            for ([_]f64{ 1.0, -1.0, 5.0, -5.0, 0.0 }) |vold| {
                try expectBits(limit.zFetlim(z, vold, vto), zFetlimOracle(z, vold, vto));
            }
        }
    }

    // fetlim step-bound edges need vtsthi/vtstlo, which depend on (vold, vto).
    for (0..1_000) |_| {
        const vold = draw.any(rand);
        const vto = draw.any(rand);
        const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
        const vtstlo = vtsthi * 0.5 + 2.0;
        for ([_]f64{ vold + vtsthi, vold - vtsthi, vold + vtstlo, vold - vtstlo }) |vnew|
            try expectBits(limit.zFetlim(vnew, vold, vto), zFetlimOracle(vnew, vold, vto));
    }
}

// ---------------------------------------------------------------- held string

test "zStrHeld: a held string owns its bytes, so rewriting the source leaves it (#19)" {
    const str = @import("str_kernels.zig");
    var site: [8]u8 = "t=10    ".*;
    const held = str.zStrHeld(site[0..4]);
    @memcpy(site[0..4], "t=20");
    try std.testing.expectEqualStrings("t=10", held.get());
    // `updateState`'s order: copy out first, then store (the new text may be
    // a slice of the field it replaces). A copy is a value, which is what
    // `stateCtl(.revert)` restores.
    var inst = held;
    const next = str.zStrHeld(inst.get()[2..]);
    inst = next;
    try std.testing.expectEqualStrings("10", inst.get());
    try std.testing.expectEqualStrings("t=10", held.get());
}
