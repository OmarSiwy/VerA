//! The device/host ABI: the comptime interface every generated or hand-written
//! device satisfies. `validate(D)` checks it where the device is defined and
//! `validateHost(H, D)` where a host links it. Physics is generic over a
//! host-supplied scalar family (`family_fns`); `RefFamily` is the reference
//! one and `gm` the f64 transcendentals it and GPU kernels share. A member with
//! no consumer yet names the LRM clause that requires it.

const std = @import("std");

/// The ABI version this file specifies. A generated device mirrors it as
/// `pub const contract_abi`, and `validateHost` refuses a device whose value
/// differs. Bumped by every change a linked host could observe.
pub const abi_version: u32 = 5;

/// f64 transcendentals that also compile for NVPTX and AMDGCN, which have no
/// libm. Used by the scalar paths of generated code (the §4.5.15 limiters) and
/// by `RefFamily`. On the host each function is the Zig builtin or `std.math`
/// call; on a GPU target it is a self-contained musl port (<= 1 ulp), so this
/// file needs no imports beyond std.
///
/// ponytail: only the functions device code reaches are ported. A model that
/// reaches another builtin on a GPU fails its kernel compile; extend `gm` then.
pub const gm = struct {
    const dev = switch (@import("builtin").target.cpu.arch) {
        .nvptx64, .amdgcn => true,
        else => false,
    };
    const ln2hi = 6.93147180369123816490e-01;
    const ln2lo = 1.90821492927058770002e-10;
    const log2e = 1.44269504088896338700;

    pub inline fn exp(x: f64) f64 {
        return if (comptime dev) softExp(x) else @exp(x);
    }
    pub inline fn log(x: f64) f64 {
        return if (comptime dev) softLog(x) else @log(x);
    }
    pub inline fn pow(x: f64, y: f64) f64 {
        if (comptime !dev) return std.math.pow(f64, x, y);
        // Square-and-multiply for integer |y| <= 64 (exact); exp(y ln x)
        // otherwise. Negative base only for integer y.
        if (y == 0 or x == 1) return 1;
        if (x == 0) return if (y > 0) 0 else std.math.inf(f64);
        if (y == @trunc(y) and @abs(y) <= 64) {
            var n: u32 = @intFromFloat(@abs(y));
            var base = x;
            var acc: f64 = 1;
            while (n != 0) : (n >>= 1) {
                if (n & 1 != 0) acc *= base;
                base *= base;
            }
            return if (y < 0) 1 / acc else acc;
        }
        if (x > 0) return softExp(y * softLog(x));
        if (y != @trunc(y)) return std.math.nan(f64);
        const m = softExp(y * softLog(-x));
        return if (@rem(@abs(y), 2.0) == 1) -m else m;
    }
    pub inline fn tanh(x: f64) f64 {
        if (comptime !dev) return std.math.tanh(x);
        // Cephes rational below 0.625, else 1 - 2/(e^2|x| + 1).
        const ax = @abs(x);
        if (ax < 0.625) {
            const z = x * x;
            const p = ((-9.64399179425052238628e-1 * z +
                -9.92877231001918586564e1) * z + -1.61468768441708447952e3) * z;
            const q = ((z + 1.12811678491632931402e2) * z +
                2.23548839060100448583e3) * z + 4.84406305325125486048e3;
            return x + x * (p / q);
        }
        const r = 1 - 2.0 / (softExp(2 * ax) + 1);
        return if (x < 0) -r else r;
    }
    pub inline fn sinh(x: f64) f64 {
        if (comptime !dev) return std.math.sinh(x);
        const ax = @abs(x);
        if (ax < 0.5) {
            const z = x * x;
            return x * (1 + z * (1.0 / 6.0 + z * (1.0 / 120.0 +
                z * (1.0 / 5040.0 + z * (1.0 / 362880.0 +
                    z * (1.0 / 39916800.0 + z * (1.0 / 6227020800.0)))))));
        }
        const e = softExp(ax);
        const r = 0.5 * e - 0.5 / e;
        return if (x < 0) -r else r;
    }
    pub inline fn cosh(x: f64) f64 {
        if (comptime !dev) return std.math.cosh(x);
        const e = softExp(@abs(x));
        return 0.5 * e + 0.5 / e;
    }
    pub inline fn sin(x: f64) f64 {
        return if (comptime dev) softSin(x) else @sin(x);
    }
    pub inline fn cos(x: f64) f64 {
        return if (comptime dev) softCos(x) else @cos(x);
    }
    // std's port raises the subnormal underflow flag through
    // `std.mem.doNotOptimizeAway` (`asm volatile ("" :: "rm" (v))`), which the
    // AMDGPU backend cannot match. The device branch is std's algorithm with
    // that line dropped; it only set a flag, so every value is identical.
    pub inline fn expm1(x: f64) f64 {
        return if (comptime dev) softExpm1(x) else std.math.expm1(x);
    }
    // Same AMDGCN hole as `expm1`, dodged through `std.math.atan`'s vector
    // path, which never reaches the idiom. Two lanes because `@Vector(1, f64)`
    // crashes the compiler; the second is discarded. ponytail: port
    // `atanBinary64` minus its bad line if device atan reaches a profile.
    pub inline fn atan(x: f64) f64 {
        if (comptime !dev) return std.math.atan(x);
        const v: @Vector(2, f64) = @splat(x);
        return std.math.atan(v)[0];
    }

    // musl exp.c / log.c ports (f64 <= 1 ulp).
    const P1 = 1.66666666666666019037e-01;
    const P2 = -2.77777777770155933842e-03;
    const P3 = 6.61375632143793436117e-05;
    const P4 = -1.65339022054652515390e-06;
    const P5 = 4.13813679705723846039e-08;

    fn softExp(x: f64) f64 {
        const bits: u64 = @bitCast(x);
        const neg = bits >> 63 != 0;
        const ax: u32 = @truncate((bits >> 32) & 0x7fffffff);
        if (ax >= 0x4086232b) { // |x| >~ 708.39
            if (std.math.isNan(x)) return x;
            if (x > 709.782712893383973096) return std.math.inf(f64);
            if (x < -745.13321910194110842) return 0;
        }
        var k: i32 = 0;
        var hi: f64 = x;
        var lo: f64 = 0;
        var r = x;
        if (ax > 0x3fd62e42) { // |x| > 0.5 ln2
            k = if (ax >= 0x3ff0a2b2) // |x| >= 1.5 ln2
                @intFromFloat(log2e * x + if (neg) @as(f64, -0.5) else 0.5)
            else if (neg) -1 else 1;
            const kf: f64 = @floatFromInt(k);
            hi = x - kf * ln2hi;
            lo = kf * ln2lo;
            r = hi - lo;
        } else if (ax <= 0x3e300000) { // |x| <= 2^-28: 1+x is already correct
            return 1 + x;
        }
        const rr = r * r;
        const c = r - rr * (P1 + rr * (P2 + rr * (P3 + rr * (P4 + rr * P5))));
        const y = 1 + (r * c / (2 - c) - lo + hi);
        return if (k == 0) y else std.math.scalbn(y, k);
    }

    /// musl expm1.c, by way of `std.math.expm1`, minus its one
    /// `doNotOptimizeAway`, see `expm1` above.
    ///
    /// Not `softExp(x) - 1`: the whole point is that the `-1` happens INSIDE
    /// the reduced-argument polynomial, where the subtraction would otherwise
    /// cancel away most of the significand for small x.
    fn softExpm1(x_: f64) f64 {
        if (std.math.isNan(x_)) return std.math.nan(f64);
        const Q1 = -3.33333333333331316428e-02;
        const Q2 = 1.58730158725481460165e-03;
        const Q3 = -7.93650757867487942473e-05;
        const Q4 = 4.00821782732936239552e-06;
        const Q5 = -2.01099218183624371326e-07;

        var x = x_;
        const ux: u64 = @bitCast(x);
        const hx: u32 = @as(u32, @intCast(ux >> 32)) & 0x7FFFFFFF;
        const sign = ux >> 63;

        if (std.math.isNegativeInf(x)) return -1.0;
        if (hx >= 0x4043687A) { // |x| >= 56 ln2
            if (hx > 0x7FF00000) return x; // nan
            if (sign != 0) return -1;
            if (x > 7.09782712893383973096e+02) return std.math.inf(f64);
        }

        var hi: f64 = undefined;
        var lo: f64 = undefined;
        var c: f64 = undefined;
        var k: i32 = undefined;
        if (hx > 0x3FD62E42) { // |x| > 0.5 ln2
            if (hx < 0x3FF0A2B2) { // |x| < 1.5 ln2
                if (sign == 0) {
                    hi = x - ln2hi;
                    lo = ln2lo;
                    k = 1;
                } else {
                    hi = x + ln2hi;
                    lo = -ln2lo;
                    k = -1;
                }
            } else {
                var kf = log2e * x;
                if (sign != 0) kf -= 0.5 else kf += 0.5;
                k = @intFromFloat(kf);
                const t = @as(f64, @floatFromInt(k));
                hi = x - t * ln2hi;
                lo = t * ln2lo;
            }
            x = hi - lo;
            c = (hi - x) - lo;
        } else if (hx < 0x3C900000) {
            // |x| < 2^-54, where expm1(x) == x. std raises the underflow flag
            // for a subnormal here; that is the line this port drops.
            return x;
        } else {
            k = 0;
        }

        const hfx = 0.5 * x;
        const hxs = x * hfx;
        const r1 = 1.0 + hxs * (Q1 + hxs * (Q2 + hxs * (Q3 + hxs * (Q4 + hxs * Q5))));
        const t = 3.0 - r1 * hfx;
        var e = hxs * ((r1 - t) / (6.0 - x * t));

        if (k == 0) return x - (x * e - hxs);
        e = x * (e - c) - c;
        e -= hxs;
        if (k == -1) return 0.5 * (x - e) - 0.5;
        if (k == 1) {
            if (x < -0.25) return -2.0 * (e - (x + 0.5));
            return 1.0 + 2.0 * (x - e);
        }

        const twopk: f64 = @bitCast(@as(u64, @intCast(0x3FF +% k)) << 52);
        if (k < 0 or k > 56) {
            var y = x - e + 1.0;
            if (k == 1024) y = y * 2.0 * 0x1.0p1023 else y = y * twopk;
            return y - 1.0;
        }
        const uf: f64 = @bitCast(@as(u64, @intCast(0x3FF -% k)) << 52);
        if (k < 20) return (x - e + (1 - uf)) * twopk;
        return (x - (e + uf) + 1) * twopk;
    }

    const Lg1 = 6.666666666666735130e-01;
    const Lg2 = 3.999999999940941908e-01;
    const Lg3 = 2.857142874366239149e-01;
    const Lg4 = 2.222219843214978396e-01;
    const Lg5 = 1.818357216161805012e-01;
    const Lg6 = 1.531383769920937332e-01;
    const Lg7 = 1.479819860511658591e-01;

    fn softLog(x: f64) f64 {
        var u: u64 = @bitCast(x);
        var hx: u32 = @truncate(u >> 32);
        var k: i32 = 0;
        if (hx < 0x00100000 or hx >> 31 != 0) {
            if (u << 1 == 0) return -std.math.inf(f64); // log(+-0)
            if (hx >> 31 != 0) return std.math.nan(f64); // log(negative)
            u = @bitCast(x * 0x1p54); // subnormal: scale into range
            hx = @truncate(u >> 32);
            k -= 54;
        } else if (hx >= 0x7ff00000) {
            return x; // inf / nan
        } else if (hx == 0x3ff00000 and u << 32 == 0) {
            return 0; // log(1)
        }
        hx +%= 0x3ff00000 - 0x3fe6a09e; // reduce into [sqrt(2)/2, sqrt(2)]
        k += @as(i32, @intCast(hx >> 20)) - 0x3ff;
        hx = (hx & 0x000fffff) + 0x3fe6a09e;
        u = (@as(u64, hx) << 32) | (u & 0xffffffff);
        const f = @as(f64, @bitCast(u)) - 1.0;
        const hfsq = 0.5 * f * f;
        const s = f / (2.0 + f);
        const z = s * s;
        const w = z * z;
        const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
        const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
        const dk: f64 = @floatFromInt(k);
        return s * (hfsq + t2 + t1) + dk * ln2lo - hfsq + f + dk * ln2hi;
    }

    // musl k_sin.c / k_cos.c and the medium branch of __rem_pio2.
    const pio4 = 0x1.921fb54442d18p-1;
    const pio2 = 0x1.921fb54442d18p+0;
    const invpio2 = 6.36619772367581382433e-01;
    const pio2_1 = 1.57079632673412561417e+00;
    const pio2_1t = 6.07710050650619224932e-11;
    const pio2_2 = 6.07710050630396597660e-11;
    const pio2_2t = 2.02226624879595063154e-21;
    const pio2_3 = 2.02226624871116645580e-21;
    const pio2_3t = 8.47842766036889956997e-32;
    const tau_hi = 6.28318530717958623200e+00;
    const tau_lo = 2.44929359829470635445e-16;

    const S1 = -1.66666666666666324348e-01;
    const S2 = 8.33333333332248946124e-03;
    const S3 = -1.98412698298579493134e-04;
    const S4 = 2.75573137070700676789e-06;
    const S5 = -2.50507602534068634195e-08;
    const S6 = 1.58969099521155010221e-10;

    const C1 = 4.16666666666666019037e-02;
    const C2 = -1.38888888888741095749e-03;
    const C3 = 2.48015872894767294178e-05;
    const C4 = -2.75573143513906633035e-07;
    const C5 = 2.08757232129817482790e-09;
    const C6 = -1.13596475577881948265e-11;

    /// sin on [-pi/4, pi/4]; `y` is the low half of a double-double argument.
    fn kernelSin(x: f64, y: f64, tail: bool) f64 {
        const z = x * x;
        const w = z * z;
        const r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
        const v = z * x;
        if (!tail) return x + v * (S1 + z * r);
        return x - ((z * (0.5 * y - v * r) - y) - v * S1);
    }

    /// cos on [-pi/4, pi/4]; `y` is the low half of a double-double argument.
    fn kernelCos(x: f64, y: f64) f64 {
        const z = x * x;
        const zz = z * z;
        const r = z * (C1 + z * (C2 + z * C3)) + zz * zz * (C4 + z * (C5 + z * C6));
        const hz = 0.5 * z;
        const w = 1.0 - hz;
        return w + (((1.0 - w) - hz) + (z * r - x * y));
    }

    /// x = y[0] + y[1] + n*(pi/2), with |y[0]| <= pi/4. Returns n.
    fn remPio2(x: f64, y: *[2]f64) i32 {
        // ponytail: no Payne-Hanek. Past 2^20*(pi/2) ~= 1.6e6 rad the
        // Cody-Waite splits stop being exact, so pre-reduce mod 2pi in
        // double-double instead; phase accuracy then decays ~1 bit per
        // octave. Exact phase beyond that wants musl's __rem_pio2_large.
        var xr = x;
        if (@abs(xr) >= 0x1p20 * pio2) {
            const q0 = @round(xr / (tau_hi + tau_lo));
            xr = (xr - q0 * tau_hi) - q0 * tau_lo;
        }

        var q: f64 = @round(xr * invpio2);
        var n: i32 = @intFromFloat(q);
        var r = xr - q * pio2_1;
        var w = q * pio2_1t; // 1st round, good to 85 bits
        if (r - w < -pio4) {
            n -= 1;
            q -= 1;
            r = xr - q * pio2_1;
            w = q * pio2_1t;
        } else if (r - w > pio4) {
            n += 1;
            q += 1;
            r = xr - q * pio2_1;
            w = q * pio2_1t;
        }
        y[0] = r - w;

        const ex = expOf(xr);
        if (ex - expOf(y[0]) > 16) { // 2nd round, good to 118 bits
            const t = r;
            w = q * pio2_2;
            r = t - w;
            w = q * pio2_2t - ((t - r) - w);
            y[0] = r - w;
            if (ex - expOf(y[0]) > 49) { // 3rd round, covers the rest
                const t3 = r;
                w = q * pio2_3;
                r = t3 - w;
                w = q * pio2_3t - ((t3 - r) - w);
                y[0] = r - w;
            }
        }
        y[1] = (r - y[0]) - w;
        return n;
    }

    fn expOf(x: f64) i32 {
        return @intCast(@as(u64, @bitCast(x)) >> 52 & 0x7ff);
    }

    fn softSin(x: f64) f64 {
        const ax = @abs(x);
        if (ax < pio4) return if (ax < 0x1p-27) x else kernelSin(x, 0.0, false);
        if (!std.math.isFinite(x)) return std.math.nan(f64);
        var y: [2]f64 = undefined;
        const n = remPio2(x, &y);
        return switch (@as(u32, @bitCast(n)) & 3) {
            0 => kernelSin(y[0], y[1], true),
            1 => kernelCos(y[0], y[1]),
            2 => -kernelSin(y[0], y[1], true),
            else => -kernelCos(y[0], y[1]),
        };
    }

    fn softCos(x: f64) f64 {
        const ax = @abs(x);
        if (ax < pio4) return if (ax < 0x1p-27) 1.0 else kernelCos(x, 0.0);
        if (!std.math.isFinite(x)) return std.math.nan(f64);
        var y: [2]f64 = undefined;
        const n = remPio2(x, &y);
        return switch (@as(u32, @bitCast(n)) & 3) {
            0 => kernelCos(y[0], y[1]),
            1 => -kernelSin(y[0], y[1], true),
            2 => -kernelCos(y[0], y[1]),
            else => kernelSin(y[0], y[1], true),
        };
    }

    test "gm host branches are the builtins, device ports agree to ~1 ulp" {
        // The host branch is the builtin; the soft ports are pinned against
        // libm on a physical range so a transcription slip fails here, not
        // inside a kernel.
        var x: f64 = -700.0;
        while (x <= 700.0) : (x += 13.77) {
            try std.testing.expectEqual(@exp(x), exp(x));
            const se = softExp(x);
            const re = @exp(x);
            if (re != 0 and std.math.isFinite(re))
                try std.testing.expect(@abs(se - re) <= 2 * @abs(re) * std.math.floatEps(f64));
        }
        var y: f64 = 1e-30;
        while (y < 1e30) : (y *= 3.7) {
            try std.testing.expectEqual(@log(y), log(y));
            const sl = softLog(y);
            const rl = @log(y);
            try std.testing.expect(@abs(sl - rl) <= 2 * @max(@abs(rl), 1.0) * std.math.floatEps(f64));
        }
        try std.testing.expectEqual(-std.math.inf(f64), softLog(0.0));
        try std.testing.expect(std.math.isNan(softLog(-1.0)));
        try std.testing.expectEqual(std.math.inf(f64), softExp(710.0));
        try std.testing.expectEqual(@as(f64, 0.0), softExp(-746.0));
        var t: f64 = -8.0;
        while (t <= 8.0) : (t += 0.0937) {
            try std.testing.expectEqual(@sin(t), sin(t));
            try std.testing.expectEqual(@cos(t), cos(t));
            const eps = 4 * std.math.floatEps(f64); // abs bound: zeros of sin/cos
            try std.testing.expect(@abs(softSin(t) - @sin(t)) <= eps);
            try std.testing.expect(@abs(softCos(t) - @cos(t)) <= eps);
        }
        try std.testing.expectApproxEqAbs(@sin(1e9), softSin(1e9), 1e-6);
        try std.testing.expect(std.math.isNan(softSin(std.math.inf(f64))));
        try std.testing.expectEqual(@as(f64, 1.0), softCos(0.0));

        // expm1: the port drops a line that touched only the FP flag register,
        // so every VALUE must equal std's. Bit equality, not a tolerance --
        // anything looser would hide a transcription slip in a branch the
        // sweep happens to straddle. The edges are the reduction boundaries
        // the algorithm actually switches on.
        for ([_]f64{
            0,       -0.0,    0x1p-60, -0x1p-60, 0x1p-54, -0x1p-54, 1e-300,
            0.3465,  -0.3465, 0.3466,  -0.3466,  1.0397,  -1.0397,  1.0398,
            -1.0398, 1,       -1,      0.25,     -0.25,   -0.2501,  2,
            -2,      38.8,    -38.8,   38.9,     709.78,  710,      -745,
        }) |v| {
            try std.testing.expectEqual(
                @as(u64, @bitCast(std.math.expm1(v))),
                @as(u64, @bitCast(softExpm1(v))),
            );
        }
        var m: f64 = -40.0;
        while (m <= 40.0) : (m += 0.00731) {
            try std.testing.expectEqual(
                @as(u64, @bitCast(std.math.expm1(m))),
                @as(u64, @bitCast(softExpm1(m))),
            );
        }
        try std.testing.expectEqual(@as(f64, -1), softExpm1(-std.math.inf(f64)));
        try std.testing.expectEqual(std.math.inf(f64), softExpm1(std.math.inf(f64)));
        try std.testing.expect(std.math.isNan(softExpm1(std.math.nan(f64))));
        // The host branch must still BE std's, so expm1/atan are unchanged
        // for every build that is not a GPU kernel.
        try std.testing.expectEqual(std.math.expm1(@as(f64, 0.7)), expm1(0.7));
        try std.testing.expectEqual(std.math.atan(@as(f64, 0.7)), atan(0.7));

        // atan's device branch is std's own vector body, so it is not
        // bit-identical to the scalar one -- pin the gap at an ulp.
        var a: f64 = -20.0;
        while (a <= 20.0) : (a += 0.0137) {
            const want = std.math.atan(a);
            const got = std.math.atan(@as(@Vector(2, f64), @splat(a)))[0];
            try std.testing.expect(@abs(got - want) <= 2 * @abs(want) * std.math.floatEps(f64));
        }
    }
};

/// What `updateState` returns: `.ok`, or a request that the host reject the
/// step and retry with its end at `request_reject_at` (an absolute time). In
/// a static solve (any `kind` but `.tran`) the request means "iterate again at
/// this point": the device's state moved, and the solve must see it.
pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

/// What a device carries across accepted points, declared as `state_class`:
///   none: no `State` and no `updateState`.
///   path_latch: only the §5.6.1.2 path latches. `updateState` stages them and
///     `stateCtl(.commit)` latches them; no operator history, held FSM or
///     §9.13.1 seed.
///   history: anything else `updateState` advances.
pub const StateClass = enum { none, path_latch, history };

/// Returns `D.state_class`, or for a device without the decl `history` when it
/// has `updateState` and `none` otherwise.
pub fn stateClass(comptime D: type) StateClass {
    if (@hasDecl(D, "state_class")) return D.state_class;
    return if (@hasDecl(D, "updateState")) .history else .none;
}

/// The operations of `stateCtl`, which a transient loop uses to reject and
/// retry a step after `updateState` has run on it. The host commits every
/// accepted point, the operating point included, before it may revert.
///   query: does the working state differ from the last accepted one in a
///     way that should reject the step (a flipped device state)?
///   commit: the step is accepted; accepted := working.
///   revert: the step is rejected; working := accepted, for every field
///     `updateState` advances and `State.t_prev`. Exact when at most one
///     `updateState` ran since the last commit or revert. Static-solve
///     iteration state (the levels a static solve iterates on) may survive
///     it; a device that keeps any rebuilds from the accepted state in every
///     `updateState`, so a host must not restore it either.
pub const StateCtlOp = enum(u8) { query, commit, revert };

/// §4.6.1 `analysis()`, Table 4-21: the analysis a `SimState` describes.
/// The tag names are the analysis names `analysis()` compares against.
pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

/// The analysis in force, passed by value to every entry point that reads it.
/// The host is its only writer, and one value serves every instance of a batch.
///   t: §9.10 `$abstime`, the time the solve is targeting.
///   dt: the step since the last accepted point. 0 marks the static solve
///     (DC, IC, a transient's first point) an operator's DC form keys on.
///   kind: §4.6.1 `analysis()`.
///   initial_step, final_step: the §5.10.2 global events.
///   analog_initial: this evaluation is the first of a §5.2.1 sub-task (each
///     point of a parameter sweep), so `analog initial` runs.
///   iteration: §9.15 `$simparam("iteration")`, 1 at a solve's first iterate.
/// `extern`, 24 bytes, align 8, the same on every target (`iteration` at 20).
/// The defaults are a DC operating point at t = 0, which is what `collapse`
/// and `derive` evaluate at.
pub const SimState = extern struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: AnalysisKind = .dc,
    initial_step: bool = false,
    final_step: bool = false,
    analog_initial: bool = true,
    iteration: u32 = 1,
};

comptime {
    std.debug.assert(@sizeOf(SimState) == 24 and @offsetOf(SimState, "iteration") == 20);
}

/// What an unknown is, per position of the optional `u_kinds` table.
pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

/// Host-written `Instance` fields. Presence is optional; the name and type are
/// contract, because the host reaches them by `@hasField` and a typo would be
/// a silently ignored field rather than an error.
const SimStateField = struct { name: []const u8, T: type };
const sim_state_fields = [_]SimStateField{
    .{ .name = "temperature", .T = f64 }, // §9.15 $temperature, kelvin
    .{ .name = "mfactor", .T = f64 }, // §9.15/E.4.1 $mfactor
    .{ .name = "bound_step", .T = f64 }, // §9.17.2 $bound_step
    // §9.12 / IEEE 1364 §17.10 the command line's arguments (`argv[1..]`),
    // host-owned; only `+` entries are plusargs. Left at `&.{}`, every
    // $test$plusargs/$value$plusargs search answers 0.
    .{ .name = "plusargs", .T = []const [:0]const u8 },
};

/// Host-written `Model` fields, all `f64`: §9.15 `$simparam` names whose value
/// is one number per run (SPICE `.options`). Presence is optional, and each is
/// initialized to its SPICE default, so a host that writes none gets that. The
/// host writes them before `derive`, and calls `setup` again after writing a
/// name `setup_simparams` lists.
const host_model_fields = [_][]const u8{
    "nom_temp__", // $simparam("tnom"), degC; 27
    "reltol__", // $simparam("reltol"); 1e-3
    "abstol__", // $simparam("abstol"), amperes; 1e-12
    "vntol__", // $simparam("vntol"), volts; 1e-6
};

/// §4.6.4 one noise generator: position k of `noise_gens` is a generator of
/// `kind` on the (row, col) branch, and position k of `noisePsd`'s result is
/// its PSD. A `.table` generator's PSD is `noise_tables[table.?]` (see
/// `NoiseTable`); its `noisePsd` entry reads zero. The per-use scale factor is
/// `PsdTerm.coeff`, because it may depend on the bias.
pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker, table },
        /// §4.6.4.6 correlation: rows with the same non-null `source` are one
        /// generator contributed to several branches, fully correlated.
        /// Distinct values, and null, are independent generators.
        source: ?u16 = null,
        /// §4.6.4.3/.4 index into the device's `noise_tables`. Non-null exactly
        /// when `kind == .table`; `validate` checks both halves.
        table: ?u16 = null,
        /// §4.6.4.1-.3 the optional `name` argument, empty when absent. A host
        /// groups its noise contribution REPORT by it. It says nothing about
        /// correlation: two rows may share a name and have different `source`
        /// values, and are then independent.
        name: []const u8 = "",
    };
}

/// §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log`: one generator's PSD as
/// a piecewise (frequency, power) table. Position k of the device's optional
/// `noise_tables` is what `NoiseGen.table == k` names. Comptime data, so a
/// host that integrates a spectrum gets the knots.
///
/// `validate` guarantees: at least one point, frequencies strictly ascending
/// and > 0, powers >= 0, and > 0 in a `.log` table. When the device declares
/// `noiseTablePoints`, these are only the parameter defaults; see that hook.
pub const NoiseTable = struct {
    /// §4.6.4.3 linear in (f, p); §4.6.4.4 linear in (log f, log p).
    interp: enum(u8) { linear, log },
    /// (frequency [Hz], power [units²/Hz]) pairs, ascending in frequency.
    points: []const [2]f64,
};

/// Sorts `pts` by frequency in place (§4.6.4.3 "the simulator shall internally
/// sort the pairs into ascending frequency"). For the knots `noiseTablePoints`
/// returns; `noise_tables` already arrives sorted.
pub fn sortNoiseTable(pts: [][2]f64) void {
    std.mem.sort([2]f64, pts, {}, struct {
        fn lt(_: void, a: [2]f64, b: [2]f64) bool {
            return a[0] < b[0];
        }
    }.lt);
}

/// Returns the §4.6.4.3/.4 tabulated PSD at `f`. Outside the table it clamps
/// to the end power, as both clauses require; a one-point table is constant.
/// Precondition: `t` meets `NoiseTable`'s invariants.
pub fn noiseTableAt(t: NoiseTable, f: f64) f64 {
    const p = t.points;
    if (f <= p[0][0]) return p[0][1];
    const top = p[p.len - 1];
    if (f >= top[0]) return top[1];
    // ponytail: linear scan. A noise table is a handful of points (the LRM's
    // own example is seven); a binary search is worth it at hundreds.
    var i: usize = 1;
    while (p[i][0] <= f) i += 1;
    const a = p[i - 1];
    const b = p[i];
    return switch (t.interp) {
        .linear => a[1] + (b[1] - a[1]) * (f - a[0]) / (b[0] - a[0]),
        // §4.6.4.4's base-10 formula; the base cancels in the ratio.
        .log => @exp(@log(a[1]) + (@log(b[1]) - @log(a[1])) *
            (@log(f) - @log(a[0])) / (@log(b[0]) - @log(a[0]))),
    };
}

/// One generator's PSD at a state vector, position k of `noisePsd`'s result
/// (generator `noise_gens[k]`). The density generator k contributes is
///
///     S_k(f) = coeff² · (white + flicker/f^ef)                              parametric row
///     S_k(f) = coeff² · noiseTableAt(noise_tables[noise_gens[k].table.?], f)  table row
///
/// A table row's `white` and `flicker` are zero, so a host that adds both
/// shapes is right for every row. The device computes `white` itself.
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    /// A generator this one is correlated with (BSIM4 tnoiMod, PSP igid), and
    /// the real correlation coefficient.
    corr_with: ?u8 = null,
    corr: f64 = 0,
    /// §4.6.4.6 the signed factor the contribution applies to this generator
    /// (the `c1` of `V(a,b) <+ c1*n`); it may depend on the bias. A host must
    /// apply it: the density is `coeff²` times the shape above, and the cross
    /// term of two rows sharing a `source` is `coeff_i · coeff_j` times the
    /// shared spectrum, whose sign distinguishes correlation from
    /// anti-correlation. 1.0 when the use reduces to no single factor.
    coeff: f64 = 1,
};

/// §2.8.3/§12.32 one `$name` the compiler could not resolve, left to a VPI
/// application. Position k of `systf_calls` is what `SystfHost.call(ctx, k, ...)`
/// answers. Keyed by name, as `vpi_register_analog_systf()` registers it, so
/// two calls to one `$name` are one entry.
pub const Systf = struct {
    /// `$sampnhold`, with the `$`. §12.32: "first character shall be `$`".
    name: []const u8,
};

/// The VPI application as the device sees it. The host owns it and writes a
/// pointer into `Instance.systf`; `validateHost` requires a binding for every
/// device that declares `systf_calls`. The call returns a value and its
/// partials (§12.22.1, §12.32 `derivtf`) rather than a family value, because a
/// function pointer cannot be generic over the family.
pub const SystfHost = struct {
    /// The application's own state (`s_vpi_analog_systf_data.user_data`).
    ctx: *anyopaque,
    /// §12.32 `calltf` and §12.22.1 `derivtf` in one call: returns the value
    /// of `systf_calls[k]` at `args` and writes d(value)/d(args[j]) into
    /// `partials[j]`. `partials.len == args.len` and it is not zeroed on
    /// entry, so the callee must write every slot.
    call: *const fn (ctx: *anyopaque, k: usize, args: []const f64, partials: []f64) f64,
};

/// The device's §9.5 descriptor table, for a host whose second context (a
/// mixed simulation's digital half) must share it (§9.5.1.2). The host routes
/// that context's file tasks through these, so a descriptor names the same
/// channel in both, with §9.5.1's encodings (an mcd has bit 31 clear, an fd bit
/// 31 set). `put` writes already-formatted text. Declared only by a printing
/// artifact that calls the §9.5 family.
pub const FileIo = struct {
    open: *const fn (path: []const u8, ty: []const u8, mcd: bool) i64,
    close: *const fn (d: i64) i64,
    put: *const fn (d: i64, text: []const u8) i64,
    getc: *const fn (d: i64) i64,
    ungetc: *const fn (c: i64, d: i64) i64,
    tell: *const fn (d: i64) i64,
    seek: *const fn (d: i64, off: i64, op: i64) i64,
    eof: *const fn (d: i64) i64,
    /// §9.5.7 `$ferror`'s code for the most recent operation on `d`, or on
    /// the failed open that returned `d` = 0. Optional: without it every
    /// `$ferror` answers 0, "no error".
    err: ?*const fn (d: i64) i64 = null,
    /// §9.5.1.1: a host running several analyses in one process calls this
    /// at the first point of each analysis after the first, so a file one
    /// analysis opened "w" and a later one reopens "w" is appended to rather
    /// than truncated. Optional: a one-analysis host never calls it.
    new_analysis: ?*const fn () void = null,
};

/// Returns the device's `file_io`, or null when it has no descriptor table.
pub fn fileIo(comptime D: type) ?FileIo {
    return if (@hasDecl(D, "file_io")) D.file_io else null;
}

/// §4.6.3 one AC stimulus: position k of `ac_gens` is an `ac_stim` call on the
/// (row, col) branch, and position k of `acStim`'s result is its phasor.
/// The residual carries only the phasor's real part, `mag·cos(phase)`. A host
/// that solves a complex small-signal system reads this table instead of that
/// residual term; adding both counts the real part twice.
pub fn AcGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        /// §4.6.3 `analysis_name`: the source is active only in the
        /// small-signal analysis of this name (Table 4-21), and zero in every
        /// other analysis.
        name: []const u8 = "ac",
    };
}

/// §4.6.3 one AC stimulus' phasor, `mag·e^(j·phase)`, position k of `acStim`'s
/// result. Evaluated at a state vector, since A.8.2 lets magnitude and phase
/// depend on the operating point. Polar, as the model wrote it. `mag` may be
/// negative (a per-use coefficient folded in); a host must not take its
/// absolute value.
pub const AcPhasor = struct {
    /// Magnitude, in the contributed nature's units.
    mag: f64 = 1,
    /// Phase, in radians.
    phase: f64 = 0,
};

/// Returns the device's `ac_dyn_slots`, or empty. Slot `row * n_u + col` is a
/// local Jacobian entry whose small-signal value depends on frequency: a
/// partial that flows through §4.5.7 `absdelay` (e^(−jω·td)), §4.5.11
/// `laplace_*` (H(jω)) or §4.5.12 `zi_*` (H(e^(jωT))). Under kind `.ac` or
/// `.noise`, `eval`, `q` and `evalQ` omit every such partial (the values
/// stay), and `acDyn(F, &model, inst, &x, sim, ω, &out)` writes the omitted
/// part of slot `ac_dyn_slots[k]` into `out[k]`, so the host's small-signal
/// matrix is
///
///     A(ω)[slot] = G[slot] + jω·C[slot] + out[k]
///
/// with G and C from the same `x` and `sim` passed to `acDyn`; `out[k]`
/// already carries the jω of a charge an operator feeds. `F` is `f64` or
/// `@Vector(W, f64)`: `omega` holds W frequencies and each `out[k]` part their
/// W terms, lane for lane, with no branch across lanes. At ω = 0 `out[k].re`
/// is exactly the partial the operator's DC form gives (absdelay 1, a
/// `laplace_*` H(0), a `zi_*` H(1), times the chain rule around it) and
/// `out[k].im` is 0. Pure, so a host may call it per frequency, in any
/// order. A superset: a listed slot may read 0.
/// `validate` checks the list is sorted and unique, inside `jac_pattern |
/// q_pattern`, and every column in `derivReads`.
pub fn acDynSlots(comptime D: type) []const u32 {
    return if (@hasDecl(D, "ac_dyn_slots")) D.ac_dyn_slots[0..] else &.{};
}

/// `validate`'s `ac_dyn_slots`/`acDyn` rules, returned so each is testable.
fn acDynError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "ac_dyn_slots") != @hasDecl(D, "acDyn")) return name ++ ": ac_dyn_slots and acDyn come together";
    if (!@hasDecl(D, "ac_dyn_slots")) return null;
    const info = @typeInfo(@TypeOf(D.ac_dyn_slots));
    if (info != .array or info.array.child != u32) return name ++ ".ac_dyn_slots must be [k]u32";
    const f = @typeInfo(@TypeOf(D.acDyn));
    if (f != .@"fn" or f.@"fn".params.len != 7 or f.@"fn".params[0].type != type)
        return name ++ ".acDyn: expected fn (comptime F: type, *const Model, InstancePtr, *const [n_u]f64, SimState, F, *[ac_dyn_slots.len]std.math.Complex(F)) void";
    const n = nU(D);
    for (D.ac_dyn_slots, 0..) |s, i| {
        if (s >= n * n) return name ++ ".ac_dyn_slots: a slot at or past n_u * n_u";
        if (i != 0 and s <= D.ac_dyn_slots[i - 1]) return name ++ ".ac_dyn_slots must be sorted with no duplicates";
        if (n > 64) continue;
        const r = s / n;
        const c = s % n;
        const jp: u64 = if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(u64, 0);
        const qp: u64 = if (@hasDecl(D, "q_pattern")) D.q_pattern[r] else if (@hasDecl(D, "q")) ~@as(u64, 0) else 0;
        if (((jp | qp) >> @intCast(c)) & 1 == 0) return name ++ ".ac_dyn_slots: a slot outside jac_pattern | q_pattern";
        if ((derivReads(D) >> @intCast(c)) & 1 == 0) return name ++ ".ac_dyn_slots: a slot whose column is outside deriv_reads";
    }
    return null;
}

/// What `limit` returns: the limited unknowns, and `converged`, false when the
/// host must run another Newton iteration: a clamp was large enough (pnjlim's
/// clamp is; a small fetlim/limvds one is not), or the model evaluated at
/// `old` executed §9.17.1 `$discontinuity(-1)`.
pub fn LimitResult(comptime n: usize) type {
    return struct {
        x: [n]f64,
        converged: bool = false,
    };
}

/// Returns the unknowns `limit` loads from `cur`/`old`, as a bit mask over `U`:
/// `D.limit_reads`, or all ones when undeclared. A superset.
pub fn limitReads(comptime D: type) u64 {
    return if (@hasDecl(D, "limit_reads")) D.limit_reads else ~@as(u64, 0);
}

/// Returns the unknowns `limit`/`seed` can store, as a bit mask over `U`:
/// `D.limit_writes`, or all ones when undeclared. A superset. An unknown
/// outside it is never limited, so its previous limited value is the host's
/// own previous iterate, not the plane `limit` writes into.
pub fn limitWrites(comptime D: type) u64 {
    return if (@hasDecl(D, "limit_writes")) D.limit_writes else ~@as(u64, 0);
}

/// Returns the unknowns that need a derivative lane, as a bit mask over `U`
/// (bit i is `@intFromEnum` value i): `D.deriv_reads`, or all ones when
/// undeclared. A superset.
///
/// For every unknown outside the mask, each ∂eval[row]/∂x[u] and ∂q[row]/∂x[u]
/// is a compile-time constant, and `jacConst` holds its exact value; the device
/// reads such an unknown with `S.con`, so no lane carries its partial. A host
/// stamps `jacConst` for those columns. Their matrix slots stay in
/// `jac_pattern`/`q_pattern` and `jac_rows`/`q_rows`.
///
/// `validate` enforces: (a) a declared mask needs |U| <= 64; (b) on a device
/// with `limit`, `limitWrites ⊆ derivReads`, because the host's limiting
/// correction is lane-indexed; (c) `jac_const` is sorted by (row, col), has no
/// duplicate, no all-zero entry and no column inside the mask, and a guard's
/// `when.flag` names a `Model` field; (d) `ddxReads ⊆ derivReads`.
pub fn derivReads(comptime D: type) u64 {
    return if (@hasDecl(D, "deriv_reads")) D.deriv_reads else ~@as(u64, 0);
}

/// Returns the unknowns whose partial §4.5.14 `ddx` reads, as a bit mask over
/// `U`: `D.ddx_reads`, or all ones when undeclared. The device calls
/// `S.ddxAt(u)` with `u` an unknown index and uses the result as a value, so a
/// family must map `u` to its own lane; a wrong map is a wrong residual.
pub fn ddxReads(comptime D: type) u64 {
    return if (@hasDecl(D, "ddx_reads")) D.ddx_reads else ~@as(u64, 0);
}

/// One constant entry of the local Jacobian, for a column outside
/// `derivReads`: `g` is ∂eval[row]/∂x[col] and `c` is ∂q[row]/∂x[col], both
/// exact. An absent entry is exactly 0 in both. A guarded entry (`when`
/// non-null) applies only as `jacConstApplies` says.
pub fn JacConst(comptime U: type) type {
    return struct { row: U, col: U, g: f64, c: f64, when: ?JacWhen = null };
}

/// The guard on a `jac_const` entry, for a partial that is constant per model
/// card and host rather than per device (a §5.6.5 collapsible branch's KCL
/// stamps). The entry applies iff `@field(model, flag)` is nonzero and
/// `collapse_open == !collapsed`, where `collapsed` is the family's
/// `collapse_applied`. `flag` is a `Model` field name; VerA's are
/// `<flow unknown>__retained` fields that `derive` fills, so the host must
/// call `derive` first.
pub const JacWhen = struct { flag: []const u8, collapse_open: bool };

/// Returns whether `jac_const` entry `e` applies to `model` under a host whose
/// collapse state is `collapsed` (see `JacWhen`). An unguarded entry always
/// applies.
pub fn jacConstApplies(comptime D: type, comptime e: JacConst(D.U), model: *const D.Model, collapsed: bool) bool {
    const w = e.when orelse return true;
    if (w.collapse_open == collapsed) return false;
    const v = @field(model, w.flag);
    return if (@TypeOf(v) == bool) v else v != 0;
}

/// Returns the device's `jac_const`, sorted by (row, col), or empty when it
/// declares none.
pub fn jacConst(comptime D: type) []const JacConst(D.U) {
    return if (@hasDecl(D, "jac_const")) D.jac_const[0..] else &.{};
}

/// The device's optional `constant` declaration: `g`/`c` promise that dF/dx and
/// dQ/dx do not depend on x, so a host may build the stamp once and reuse it
/// every iteration. A wrong promise silently freezes the Jacobian.
pub const Constant = struct {
    g: bool = false,
    c: bool = false,
};

/// Returns |U|, the device's number of unknowns.
pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".fields.len;
}

// ============================================================================
// §5.6.1.2 charge sites
// ============================================================================
//
// `q` returns one charge per charge site (a `ddt` term of a contribution, after
// unrolling and flattening), not one per residual row; `evalQ(...).q` and
// `acceptQ` return the same `Sites`. Row r of the reactive residual is
// Σ e.sign · q[e.site] over the `q_stamps` entries with e.row == r (`qRows`).
// A host integrates and truncation-checks each site on its own, then stamps
// the currents into rows. `q_lte[k]` says whether site k joins the truncation
// check (VerA's `vera_lte` attribute clears it). A device without `n_q` and
// `q_stamps` has one site per row, site k on row k with sign +1, all checked.
// `jac_const.c`, `q_pattern` and `q_rows` stay per row; `q_site_pattern[k]`
// is site k's column set. A §4.5.2 operator unknown (each idt site, and a
// ddt off a contribution's spine) is an ordinary internal `.voltage` unknown
// with its own row and site.

/// One `q_stamps` entry: reactive row `row` gains `sign · q[site]`.
pub fn QStamp(comptime U: type) type {
    return struct { site: u16, row: U, sign: f64 };
}

/// Returns how many charges `q` returns: `n_q`, or |U| for the per-row layout.
pub fn nQ(comptime D: type) comptime_int {
    return if (@hasDecl(D, "n_q")) D.n_q else nU(D);
}

/// Returns the site-to-row map, sorted by (row, site); the identity for the
/// per-row layout.
pub fn qStamps(comptime D: type) []const QStamp(D.U) {
    if (@hasDecl(D, "q_stamps")) return D.q_stamps[0..];
    const n = nU(D);
    const id = comptime blk: {
        var t: [n]QStamp(D.U) = undefined;
        for (&t, 0..) |*e, k| e.* = .{ .site = k, .row = @enumFromInt(k), .sign = 1 };
        break :blk t;
    };
    return &id;
}

/// Returns, per site, whether it joins the truncation-error check: `q_lte`, or
/// all true when undeclared.
pub fn qLte(comptime D: type) [nQ(D)]bool {
    return if (@hasDecl(D, "q_lte")) D.q_lte else @splat(true);
}

/// Returns the lanes reactive row `r` carries: the union of the `siteMask`s
/// of the sites `q_stamps` puts on it.
pub fn qRowMask(comptime D: type, comptime r: usize) u64 {
    var m: u64 = 0;
    for (qStamps(D)) |e| {
        if (@intFromEnum(e.row) == r) m |= siteMask(D, e.site);
    }
    return m;
}

/// What `qRows` returns for family `S`: row `r` as `S.Of(qRowMask(D, r))`.
pub fn QRows(comptime D: type, comptime S: type) type {
    @setEvalBranchQuota(1_000_000);
    var ts: [nU(D)]type = undefined;
    for (&ts, 0..) |*t, r| t.* = S.Of(qRowMask(D, r));
    return @Tuple(&ts);
}

/// Returns the reactive residual's rows from the sites' charges:
/// `Σ sign · q[site]` per row, summed from +0 in `q_stamps` order.
pub fn qRows(comptime D: type, comptime S: type, q: Sites(D, S)) QRows(D, S) {
    @setEvalBranchQuota(1_000_000);
    var out: QRows(D, S) = undefined;
    inline for (0..nU(D)) |r| out[r] = S.con(0.0).to(qRowMask(D, r));
    inline for (comptime qStamps(D)) |e| {
        const r = @intFromEnum(e.row);
        const s = q[e.site];
        out[r] = if (e.sign == 1) out[r].add(s) else if (e.sign == -1) out[r].sub(s) else out[r].add(s.scale(e.sign));
    }
    return out;
}

/// `validate`'s charge-site rules, returned so each is testable: `n_q` and
/// `q_stamps` come together; every entry names a site below `n_q` with a
/// finite nonzero sign; entries are sorted by (row, site) with no repeat;
/// `q_lte` is `[n_q]bool`; `q_site_pattern` is `[n_q]u64`.
fn qSitesError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "n_q") != @hasDecl(D, "q_stamps")) return name ++ ": n_q and q_stamps come together";
    if (@hasDecl(D, "q_lte") and @TypeOf(D.q_lte) != [nQ(D)]bool) return name ++ ".q_lte must be [n_q]bool";
    if (@hasDecl(D, "q_site_pattern") and @TypeOf(D.q_site_pattern) != [nQ(D)]u64) return name ++ ".q_site_pattern must be [n_q]u64";
    if (!@hasDecl(D, "q_stamps")) return null;
    if (@TypeOf(D.n_q) != usize and @TypeOf(D.n_q) != comptime_int) return name ++ ".n_q must be a usize";
    const t = qStamps(D);
    for (t, 0..) |e, k| {
        if (e.site >= D.n_q) return name ++ ".q_stamps: a site at or past n_q";
        if (e.sign == 0 or !std.math.isFinite(e.sign)) return name ++ ".q_stamps: a zero or non-finite sign";
        if (k == 0) continue;
        const p = t[k - 1];
        const pr: usize = @intFromEnum(p.row);
        const r: usize = @intFromEnum(e.row);
        if (r < pr or (r == pr and e.site <= p.site)) return name ++ ".q_stamps must be sorted by (row, site) with no duplicates";
    }
    return null;
}

// ============================================================================
// Scalar families
// ============================================================================
//
// The device asks the host for `S.Of(mask)`, the scalar carrying the
// derivative lanes of exactly the unknowns `mask` names, and types each value
// by the unknowns it can depend on.
//
// The numerics, pinned per primitive so every family computes the same thing.
// Values are bit-exact except the transcendentals (exp log expm1 sin cos tanh
// sinh cosh atan pow), whose last ulp is the host's. Lanes follow the formula
// with one rounding per listed operation; FMA is optional.
//
//   add sub neg      IEEE; a lane present in one operand is copied (negated for sub)
//   mul              a·b; lanes mulAdd(b.d, a.v, a.d·b.v), a one-sided operand one product
//   div              IEEE q = a/b; lanes mulAdd(b.d, −q, a.d)·(1/b.v), an `Of(0)` divisor a.d·(1/b.v)
//   scale addC       a·c, a+c; lanes a.d·c, a.d
//   exp log expm1    d·e, d·(1/v), d·exp(v)
//   log1p sqrt       d·(1/(1+v)), d·(0.5/s) (0 unless s > 0)
//   sin cos          d·cos, d·(−sin)
//   tanh sinh cosh   d·(1−th²), d·cosh, d·sinh
//   atan             d·(1/(1+v²))
//   pow(x, c)        host pow; lanes d·(c·p/x), or d·(c·pow(0, c−1)) at x = 0; a non-finite slope is 0
//   lt le eq         IEEE compare → 1.0/0.0 (NaN gives 0), no lanes: `Of(0)`
//   sel(c, a, b)     c ≠ 0 ? a : b (a NaN c picks a), the winner's lanes widened to both
//   to(m)            the same value, lanes widened to `m`; the new ones are exactly +0
//
// §4.3.1 spells min, max and abs as conditionals, and so does the device:
// min = (x < y) ? x : y, max = (x > y) ? x : y, abs = (x > 0) ? x : −x, the
// slew clamps (c < a) ? c : a and (a < c) ? c : a, each over lt and sel and
// carrying the selected operand's lanes.

/// The decls of the family a host passes as `comptime S`: `Of(comptime m: u64)
/// type`; `V`, the type of one unknown's value (`f64`, or a vector for a
/// family that evaluates several operating points at once); `con(f64) Of(0)`
/// and, when `V` is not `f64`, `lift(V) Of(0)`; `probe(comptime u: usize, V)
/// Of(1 << u)`; `sel(c, a, b)` joining `a` and `b`.
///
/// The device probes only unknowns in `derivReads` and names only masks inside
/// it. A family may carry more lanes than a mask names, or map several
/// unknowns to one lane. Above 64 unknowns every mask is all ones, so only a
/// family whose `Of` ignores its mask can serve the device. A `V` other than
/// `f64` is sound only for a device that declares `batch_ok`.
///
/// Optional trait: `collapse_applied: bool = true` promises the host applied
/// the device's `collapse()` aliases to its gather and scatter maps; the
/// device then omits the collapsed branches' cancelling stamps.
pub const family_fns = [_][]const u8{ "Of", "V", "con", "probe", "sel" };

/// The methods every `Of(m)` value carries, with the numerics pinned in the
/// table above. A binary operation takes any `Of(m')` operand and returns
/// `Of(m | m')`; a unary one keeps `Of(m)`; `lt`/`le`/`eq` return `Of(0)`;
/// `to(comptime m2)` widens and is a compile error unless `m ⊆ m2`;
/// `ddxAt(comptime u)` is lane `u`, or 0 off the mask. Constants and results
/// cross as `f64` (`con`, `scale`, `addC`, `val`, `ddxAt`) and device code
/// never opens a value, so lanes may be narrower than `f64` (`jac_f32`).
pub const family_primitives = [_][]const u8{
    "addC",  "scale", "add",  "sub", "neg", "mul",   "div",  "exp",  "log",
    "expm1", "log1p", "sqrt", "pow", "sin", "cos",   "tanh", "sinh", "cosh",
    "atan",  "lt",    "le",   "eq",  "val", "ddxAt", "to",
};

/// Checks family `S` at comptime: its `family_fns` decls, and the
/// `family_primitives` of `Of(0)` and `Of(1)`.
pub fn checkFamily(comptime S: type) void {
    if (@hasDecl(S, "collapse_applied") and @TypeOf(S.collapse_applied) != bool)
        @compileError(@typeName(S) ++ ": family collapse_applied must be bool");
    inline for (family_fns) |f| {
        if (!@hasDecl(S, f)) @compileError(@typeName(S) ++ ": family is missing `" ++ f ++ "`");
    }
    inline for (.{ S.Of(0), S.Of(1) }) |T| inline for (family_primitives) |p| {
        if (!@hasDecl(T, p)) @compileError(@typeName(T) ++ ": family value is missing primitive `" ++ p ++ "`");
    };
}

/// The `RefFamily` `lane[u]` entry for an unknown the family does not carry.
pub const no_lane: u8 = std.math.maxInt(u8);

/// Layout options for `RefFamily`.
pub const RefOptions = struct {
    /// Every `Of(m)` is one type carrying every lane `lane` maps, its lanes
    /// an array a host may index at run time. Otherwise `Of(m)` carries
    /// exactly `m`'s lanes, in unknown order.
    dense: bool,
    /// The family's `collapse_applied` trait (see `family_fns`).
    collapse_applied: bool = false,
};

/// Returns the reference family: the numerics table above, lanes of float type `L`
/// (`f64`, or `f32` under `jac_f32`) beside an `f64` value. `lane[u]` is the
/// lane unknown `u` occupies in the dense layout, or `no_lane`; a sparse
/// `Of(m)` refuses at compile time a mask naming an unknown `lane` does not
/// carry. Transcendentals go through `gm`, so the family compiles for NVPTX
/// and AMDGCN too.
pub fn RefFamily(comptime L: type, comptime lane: []const u8, comptime opts: RefOptions) type {
    return if (opts.dense) RefDense(L, lane, opts.collapse_applied) else RefSparse(L, lane, opts.collapse_applied);
}

const fma_lanes = switch (@import("builtin").cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(@import("builtin").cpu.features, .fma),
    .aarch64, .nvptx64, .amdgcn => true,
    else => false,
};

inline fn laneFma(comptime T: type, a: T, b: T, c: T) T {
    return if (fma_lanes) @mulAdd(T, a, b, c) else a * b + c;
}

/// `pow`'s lane coefficient (§7[2]): c·p/x off zero, c·pow(0, c−1) at it, 0
/// when that is not finite.
fn powSlope(x: f64, c: f64, p: f64) f64 {
    const s = if (x != 0.0) c * p / x else c * gm.pow(x, c - 1.0);
    return if (std.math.isFinite(s)) s else 0.0;
}

/// `sqrt`'s lane coefficient: 0.5/s, and 0 unless s > 0.
fn sqrtSlope(s: f64) f64 {
    return if (s > 0.0) 0.5 / s else 0.0;
}

fn laneWidth(comptime lane: []const u8) usize {
    var n: usize = 0;
    for (lane) |l| {
        if (l != no_lane) n = @max(n, @as(usize, l) + 1);
    }
    return n;
}

fn RefDense(comptime L: type, comptime lane: []const u8, comptime collapsed: bool) type {
    return struct {
        v: f64,
        /// An array, not a vector, so a host's scatter loop may index it at
        /// run time; the arithmetic below runs on it as `Lanes`.
        d: [N]L = @splat(0.0),
        pub const collapse_applied = collapsed;
        pub const V = f64;
        const N = laneWidth(lane);
        const Lanes = @Vector(N, L);
        const T = @This();
        inline fn k(c: f64) Lanes {
            return @splat(@as(L, @floatCast(c)));
        }
        inline fn lv(a: T) Lanes {
            return a.d;
        }
        fn map(a: T, v: f64, c: f64) T {
            return .{ .v = v, .d = lv(a) * k(c) };
        }

        pub fn Of(comptime _: u64) type {
            return T;
        }
        pub fn con(c: f64) T {
            return .{ .v = c };
        }
        pub fn probe(comptime u: usize, v: f64) T {
            var d: [N]L = @splat(0.0);
            if (lane[u] != no_lane) d[lane[u]] = 1.0;
            return .{ .v = v, .d = d };
        }
        pub fn to(a: T, comptime _: u64) T {
            return a;
        }
        pub fn val(a: T) f64 {
            return a.v;
        }
        pub fn ddxAt(a: T, comptime u: usize) f64 {
            if (lane[u] == no_lane) return 0.0;
            return a.d[lane[u]];
        }
        pub fn add(a: T, b: T) T {
            return .{ .v = a.v + b.v, .d = lv(a) + lv(b) };
        }
        pub fn sub(a: T, b: T) T {
            return .{ .v = a.v - b.v, .d = lv(a) - lv(b) };
        }
        pub fn neg(a: T) T {
            return .{ .v = -a.v, .d = -lv(a) };
        }
        pub fn mul(a: T, b: T) T {
            return .{ .v = a.v * b.v, .d = laneFma(Lanes, lv(b), k(a.v), lv(a) * k(b.v)) };
        }
        pub fn div(a: T, b: T) T {
            const inv = 1.0 / b.v;
            const q = a.v / b.v;
            return .{ .v = q, .d = laneFma(Lanes, lv(b), k(-q), lv(a)) * k(inv) };
        }
        pub fn scale(a: T, c: f64) T {
            return map(a, a.v * c, c);
        }
        pub fn addC(a: T, c: f64) T {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn exp(a: T) T {
            const e = gm.exp(a.v);
            return map(a, e, e);
        }
        pub fn log(a: T) T {
            return map(a, gm.log(a.v), 1.0 / a.v);
        }
        pub fn expm1(a: T) T {
            return map(a, gm.expm1(a.v), gm.exp(a.v));
        }
        pub fn log1p(a: T) T {
            return map(a, std.math.log1p(a.v), 1.0 / (1.0 + a.v));
        }
        pub fn sqrt(a: T) T {
            const s = @sqrt(a.v);
            return map(a, s, sqrtSlope(s));
        }
        pub fn sin(a: T) T {
            return map(a, gm.sin(a.v), gm.cos(a.v));
        }
        pub fn cos(a: T) T {
            return map(a, gm.cos(a.v), -gm.sin(a.v));
        }
        pub fn tanh(a: T) T {
            const th = gm.tanh(a.v);
            return map(a, th, 1.0 - th * th);
        }
        pub fn sinh(a: T) T {
            return map(a, gm.sinh(a.v), gm.cosh(a.v));
        }
        pub fn cosh(a: T) T {
            return map(a, gm.cosh(a.v), gm.sinh(a.v));
        }
        pub fn atan(a: T) T {
            return map(a, gm.atan(a.v), 1.0 / (1.0 + a.v * a.v));
        }
        pub fn pow(a: T, c: f64) T {
            const p = gm.pow(a.v, c);
            return map(a, p, powSlope(a.v, c, p));
        }
        pub fn lt(a: T, b: T) T {
            return con(@floatFromInt(@intFromBool(a.v < b.v)));
        }
        pub fn le(a: T, b: T) T {
            return con(@floatFromInt(@intFromBool(a.v <= b.v)));
        }
        pub fn eq(a: T, b: T) T {
            return con(@floatFromInt(@intFromBool(a.v == b.v)));
        }
        pub fn sel(c: T, a: T, b: T) T {
            return if (c.v != 0.0) a else b;
        }
    };
}

fn RefSparse(comptime L: type, comptime lane: []const u8, comptime collapsed: bool) type {
    return struct {
        pub const collapse_applied = collapsed;
        pub const V = f64;

        pub fn con(c: f64) Of(0) {
            return .{ .v = c, .d = .{} };
        }
        pub fn probe(comptime u: usize, v: f64) Of(@as(u64, 1) << u) {
            return .{ .v = v, .d = @splat(1.0) };
        }
        pub fn sel(c: anytype, a: anytype, b: anytype) Of(@TypeOf(a).mask | @TypeOf(b).mask) {
            const r = @TypeOf(a).mask | @TypeOf(b).mask;
            return if (c.v != 0.0) a.to(r) else b.to(r);
        }

        pub fn Of(comptime m: u64) type {
            @setEvalBranchQuota(100_000);
            for (0..64) |u| {
                if ((m >> u) & 1 != 0 and (u >= lane.len or lane[u] == no_lane))
                    @compileError(std.fmt.comptimePrint("RefFamily: mask 0x{x} names unknown {d}, which `lane` does not carry", .{ m, u }));
            }
            return struct {
                v: f64,
                d: Lanes align(@alignOf(L)),
                pub const mask = m;
                const Lanes = @Vector(@popCount(m), L);
                const T = @This();
                inline fn k(c: f64) Lanes {
                    return @splat(@as(L, @floatCast(c)));
                }
                fn map(a: T, v: f64, c: f64) T {
                    return .{ .v = v, .d = a.d * k(c) };
                }
                fn Join(comptime B: type) type {
                    return Of(m | B.mask);
                }
                inline fn kj(comptime B: type, c: f64) @Vector(@popCount(m | B.mask), L) {
                    return @splat(@as(L, @floatCast(c)));
                }

                /// This value's lanes in `to_m`'s layout; new lanes are exactly +0.
                inline fn spread(a: T, comptime to_m: u64) @Vector(@popCount(to_m), L) {
                    if (m & ~to_m != 0) @compileError(std.fmt.comptimePrint("RefFamily: mask 0x{x} does not widen to 0x{x}", .{ m, to_m }));
                    if (m == to_m) return a.d;
                    if (m == 0) return @splat(0.0);
                    const idx = comptime blk: {
                        @setEvalBranchQuota(100_000);
                        var idx: [@popCount(to_m)]i32 = undefined;
                        var j: usize = 0;
                        for (0..64) |u| if ((to_m >> u) & 1 != 0) {
                            idx[j] = if ((m >> u) & 1 != 0) @popCount(m & ((@as(u64, 1) << u) - 1)) else -1;
                            j += 1;
                        };
                        break :blk idx;
                    };
                    const z: @Vector(1, L) = @splat(0.0);
                    return @shuffle(L, a.d, z, idx);
                }

                pub fn to(a: T, comptime to_m: u64) Of(to_m) {
                    return .{ .v = a.v, .d = a.spread(to_m) };
                }
                pub fn val(a: T) f64 {
                    return a.v;
                }
                pub fn ddxAt(a: T, comptime u: usize) f64 {
                    if ((m >> u) & 1 == 0) return 0.0;
                    return a.d[@popCount(m & ((@as(u64, 1) << u) - 1))];
                }

                pub fn add(a: T, b: anytype) Join(@TypeOf(b)) {
                    const r = m | @TypeOf(b).mask;
                    return .{ .v = a.v + b.v, .d = a.spread(r) + b.spread(r) };
                }
                pub fn sub(a: T, b: anytype) Join(@TypeOf(b)) {
                    const r = m | @TypeOf(b).mask;
                    return .{ .v = a.v - b.v, .d = a.spread(r) - b.spread(r) };
                }
                pub fn neg(a: T) T {
                    return .{ .v = -a.v, .d = -a.d };
                }
                pub fn mul(a: T, b: anytype) Join(@TypeOf(b)) {
                    const B = @TypeOf(b);
                    const r = m | B.mask;
                    if (B.mask == 0) return .{ .v = a.v * b.v, .d = a.spread(r) * kj(B, b.v) };
                    if (m == 0) return .{ .v = a.v * b.v, .d = b.spread(r) * kj(B, a.v) };
                    return .{ .v = a.v * b.v, .d = laneFma(@Vector(@popCount(r), L), b.spread(r), kj(B, a.v), a.spread(r) * kj(B, b.v)) };
                }
                pub fn div(a: T, b: anytype) Join(@TypeOf(b)) {
                    const B = @TypeOf(b);
                    const r = m | B.mask;
                    const inv = 1.0 / b.v;
                    const q = a.v / b.v;
                    if (B.mask == 0) return .{ .v = q, .d = a.spread(r) * kj(B, inv) };
                    return .{ .v = q, .d = laneFma(@Vector(@popCount(r), L), b.spread(r), kj(B, -q), a.spread(r)) * kj(B, inv) };
                }
                pub fn scale(a: T, c: f64) T {
                    return map(a, a.v * c, c);
                }
                pub fn addC(a: T, c: f64) T {
                    return .{ .v = a.v + c, .d = a.d };
                }
                pub fn exp(a: T) T {
                    const e = gm.exp(a.v);
                    return map(a, e, e);
                }
                pub fn log(a: T) T {
                    return map(a, gm.log(a.v), 1.0 / a.v);
                }
                pub fn expm1(a: T) T {
                    return map(a, gm.expm1(a.v), gm.exp(a.v));
                }
                pub fn log1p(a: T) T {
                    return map(a, std.math.log1p(a.v), 1.0 / (1.0 + a.v));
                }
                pub fn sqrt(a: T) T {
                    const s = @sqrt(a.v);
                    return map(a, s, sqrtSlope(s));
                }
                pub fn sin(a: T) T {
                    return map(a, gm.sin(a.v), gm.cos(a.v));
                }
                pub fn cos(a: T) T {
                    return map(a, gm.cos(a.v), -gm.sin(a.v));
                }
                pub fn tanh(a: T) T {
                    const th = gm.tanh(a.v);
                    return map(a, th, 1.0 - th * th);
                }
                pub fn sinh(a: T) T {
                    return map(a, gm.sinh(a.v), gm.cosh(a.v));
                }
                pub fn cosh(a: T) T {
                    return map(a, gm.cosh(a.v), gm.sinh(a.v));
                }
                pub fn atan(a: T) T {
                    return map(a, gm.atan(a.v), 1.0 / (1.0 + a.v * a.v));
                }
                pub fn pow(a: T, c: f64) T {
                    const p = gm.pow(a.v, c);
                    return map(a, p, powSlope(a.v, c, p));
                }
                pub fn lt(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v < b.v)));
                }
                pub fn le(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v <= b.v)));
                }
                pub fn eq(a: T, b: anytype) Of(0) {
                    return con(@floatFromInt(@intFromBool(a.v == b.v)));
                }
            };
        }
    };
}

/// One distinct `Of` mask a device declares reals at, and how many it
/// declares: data for a host's width policy (`laneMasks`), never a width.
pub const LaneUse = struct { mask: u64, uses: u32 };

/// Returns `D.lane_masks`, or one dense entry (`derivReads`) for a device
/// without it.
pub fn laneMasks(comptime D: type) []const LaneUse {
    if (@hasDecl(D, "lane_masks")) return &D.lane_masks;
    return &.{.{ .mask = derivReads(D) & unknownsMask(D), .uses = 0 }};
}

/// Every unknown of `D` as a mask.
fn unknownsMask(comptime D: type) u64 {
    return if (nU(D) >= 64) ~@as(u64, 0) else (@as(u64, 1) << nU(D)) - 1;
}

/// The lanes residual row `r` carries: `jac_pattern[r]` inside
/// `derivReads`, every read lane when the device declares no pattern.
pub fn rowMask(comptime D: type, comptime r: usize) u64 {
    const p = if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(u64, 0);
    return p & derivReads(D) & unknownsMask(D);
}

/// The lanes charge site `k` carries: `q_site_pattern[k]` inside `derivReads`.
pub fn siteMask(comptime D: type, comptime k: usize) u64 {
    const p = if (@hasDecl(D, "q_site_pattern")) D.q_site_pattern[k] else ~@as(u64, 0);
    return p & derivReads(D) & unknownsMask(D);
}

/// What `eval` returns for family `S`: row `r` as `S.Of(rowMask(D, r))`,
/// in `U` order.
pub fn Rows(comptime D: type, comptime S: type) type {
    @setEvalBranchQuota(1_000_000);
    var ts: [nU(D)]type = undefined;
    for (&ts, 0..) |*t, r| t.* = S.Of(rowMask(D, r));
    return @Tuple(&ts);
}

/// What `q` returns for family `S`: site `k` as `S.Of(siteMask(D, k))`.
pub fn Sites(comptime D: type, comptime S: type) type {
    @setEvalBranchQuota(1_000_000);
    var ts: [nQ(D)]type = undefined;
    for (&ts, 0..) |*t, k| t.* = S.Of(siteMask(D, k));
    return @Tuple(&ts);
}

/// Every unknown `D` reads a lane of, as the one mask a hand-written device
/// computes at: `S.Of(denseMask(D))` is a whole dense value.
pub fn denseMask(comptime D: type) u64 {
    return derivReads(D) & unknownsMask(D);
}

/// The unknowns as a hand-written device reads them: `probe` on every lane
/// it reads, widened to `denseMask`, and `con` on the rest.
pub fn probes(comptime D: type, comptime S: type, x: *const [nU(D)]S.V) [nU(D)]S.Of(denseMask(D)) {
    var p: [nU(D)]S.Of(denseMask(D)) = undefined;
    inline for (0..nU(D)) |u| p[u] = if (comptime (denseMask(D) >> u) & 1 != 0) S.probe(u, x[u]).to(denseMask(D)) else S.con(x[u]).to(denseMask(D));
    return p;
}

/// `Rows(D, S)` from rows a hand-written device computed at `denseMask`. A
/// compile error when `D` declares a `jac_pattern` narrower than that: the
/// device must then type each row itself.
pub fn rows(comptime D: type, comptime S: type, a: [nU(D)]S.Of(denseMask(D))) Rows(D, S) {
    var r: Rows(D, S) = undefined;
    inline for (0..nU(D)) |u| r[u] = a[u].to(rowMask(D, u));
    return r;
}

/// `Sites(D, S)` from charges a hand-written device computed at `denseMask`,
/// on the same terms as `rows`.
pub fn sites(comptime D: type, comptime S: type, a: [nQ(D)]S.Of(denseMask(D))) Sites(D, S) {
    var r: Sites(D, S) = undefined;
    inline for (0..nQ(D)) |k| r[k] = a[k].to(siteMask(D, k));
    return r;
}

/// Checks family `S` against the numerics table at run time: every primitive
/// over an edge-value grid against the reference family in f64, the pinned
/// edge cases of pow, div, the compares and `sel`, and one mask join per
/// binary operation. Values must match bit for bit (transcendentals within 1 ulp);
/// lanes within 1e-6 relative, which admits f32 lanes and an unfused host,
/// and only where the operands, the value and the lane are finite and inside
/// f32's range: past that a dense host's `0·inf` is NaN on a lane a sparse
/// one never computes, and an f32 lane rightly flushes or overflows.
/// Prints the first mismatch and returns `error.FamilyMismatch`.
pub fn expectFamily(comptime S: type) !void {
    @setEvalBranchQuota(100_000);
    checkFamily(S);
    const Ref = RefFamily(f64, &.{ 0, 1 }, .{ .dense = false });
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const grid = [_]f64{ 0.0, -0.0, 0.5, 1.5, -2.25, 3.0, 1e-310, 1e300, -1e300, inf, -inf, nan };
    // f32 lanes: a lane 1 + 2^-40 rounds to 1.
    const narrow = S.probe(0, 1.0).scale(1.0 + 0x1p-40).ddxAt(0) == 1.0;

    const unary = .{ "neg", "exp", "log", "expm1", "log1p", "sqrt", "sin", "cos", "tanh", "sinh", "cosh", "atan" };
    inline for (unary) |op| for (grid) |x| {
        const got = @field(S.Of(1), op)(S.probe(0, x));
        const want = @field(Ref.Of(1), op)(Ref.probe(0, x));
        try famExpect(op, narrow, x, 0, got, want, !std.mem.eql(u8, op, "neg"));
    };
    for (grid) |x| for ([_]f64{ 3.0, 2.0, 1.0, 0.5, 0.0, -1.0, -2.5 }) |c| {
        try famExpect("pow", narrow, x, c, S.probe(0, x).pow(c), Ref.probe(0, x).pow(c), true);
        try famExpect("scale", narrow, x, c, S.probe(0, x).scale(c), Ref.probe(0, x).scale(c), false);
        try famExpect("addC", narrow, x, c, S.probe(0, x).addC(c), Ref.probe(0, x).addC(c), false);
    };
    const binary = .{ "add", "sub", "mul", "div", "lt", "le", "eq" };
    inline for (binary) |op| for (grid) |x| for (grid) |y| {
        const got = @field(S.Of(1), op)(S.probe(0, x), S.probe(1, y));
        const want = @field(Ref.Of(1), op)(Ref.probe(0, x), Ref.probe(1, y));
        try famExpect(op, narrow, x, y, got, want, false);
        const got0 = @field(S.Of(1), op)(S.probe(0, x), S.con(y));
        const want0 = @field(Ref.Of(1), op)(Ref.probe(0, x), Ref.con(y));
        try famExpect(op, narrow, x, y, got0, want0, false);
        // The join: the operands' lanes land on their own unknowns.
        if (comptime op.len == 3 and @TypeOf(got) != S.Of(0b11)) {
            std.debug.print("expectFamily: {s} of Of(1) and Of(2) is not Of(3)\n", .{op});
            return error.FamilyMismatch;
        }
    };
    for (grid) |c| for (grid) |x| {
        try famExpect("sel", narrow, c, x, S.sel(S.con(c), S.probe(0, x), S.probe(1, 2.0)), Ref.sel(Ref.con(c), Ref.probe(0, x), Ref.probe(1, 2.0)), false);
    };

    // The pinned edge cases (value, lane): signs of zero and infinities exact.
    // `div`'s pins are values only: at a zero or infinite divisor its lanes
    // are not finite, and a dense host's are NaN where a sparse one's are not.
    const Pin = struct { what: []const u8, x: f64, y: f64, v: f64, d: ?f64 };
    const pins = [_]Pin{
        .{ .what = "pow", .x = -2, .y = 3, .v = -8, .d = 12 },
        .{ .what = "pow", .x = -2, .y = 2, .v = 4, .d = -4 },
        .{ .what = "pow", .x = -2, .y = 0.5, .v = nan, .d = 0 },
        .{ .what = "pow", .x = 0, .y = 2, .v = 0, .d = 0 },
        .{ .what = "pow", .x = 0, .y = 1, .v = 0, .d = 1 },
        .{ .what = "pow", .x = 0, .y = 0, .v = 1, .d = 0 },
        .{ .what = "pow", .x = 0, .y = 0.5, .v = 0, .d = 0 },
        .{ .what = "pow", .x = 0, .y = -1, .v = inf, .d = 0 },
        .{ .what = "pow", .x = -0.0, .y = -1, .v = -inf, .d = 0 },
        .{ .what = "div", .x = 0, .y = 0, .v = nan, .d = null },
        .{ .what = "div", .x = 1, .y = 0, .v = inf, .d = null },
        .{ .what = "div", .x = 1, .y = -0.0, .v = -inf, .d = null },
        .{ .what = "div", .x = 1, .y = inf, .v = 0, .d = null },
        .{ .what = "div", .x = inf, .y = inf, .v = nan, .d = null },
        .{ .what = "sel", .x = nan, .y = 5, .v = 5, .d = 1 },
        .{ .what = "lt", .x = nan, .y = 1, .v = 0, .d = 0 },
        .{ .what = "le", .x = 1, .y = nan, .v = 0, .d = 0 },
        .{ .what = "eq", .x = nan, .y = nan, .v = 0, .d = 0 },
    };
    for (pins) |p| {
        const a = S.probe(0, p.y);
        const r = if (std.mem.eql(u8, p.what, "pow"))
            S.probe(0, p.x).pow(p.y).to(0b11)
        else if (std.mem.eql(u8, p.what, "div"))
            S.probe(0, p.x).div(S.con(p.y)).to(0b11)
        else if (std.mem.eql(u8, p.what, "sel"))
            S.sel(S.con(p.x), a, S.con(0.0)).to(0b11)
        else if (std.mem.eql(u8, p.what, "lt"))
            S.probe(0, p.x).lt(S.con(p.y)).to(0b11)
        else if (std.mem.eql(u8, p.what, "le"))
            S.probe(0, p.x).le(S.con(p.y)).to(0b11)
        else
            S.probe(0, p.x).eq(S.con(p.y)).to(0b11);
        if (!famSame(r.val(), p.v) or (p.d != null and !famSame(r.ddxAt(0), p.d.?))) {
            std.debug.print("expectFamily: {s}({e}, {e}) = ({e}, lane {e}), pinned ({e}, lane {?e})\n", .{ p.what, p.x, p.y, r.val(), r.ddxAt(0), p.v, p.d });
            return error.FamilyMismatch;
        }
    }
    // `to`'s new lanes are exactly +0.
    const w = S.con(2.0).to(0b11);
    if (@as(u64, @bitCast(w.ddxAt(0))) != 0 or @as(u64, @bitCast(w.ddxAt(1))) != 0) {
        std.debug.print("expectFamily: to() gave a new lane that is not +0\n", .{});
        return error.FamilyMismatch;
    }
}

/// Bits equal, or both NaN.
fn famSame(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b)) or (std.math.isNan(a) and std.math.isNan(b));
}

fn famClose(a: f64, b: f64, rel: f64) bool {
    if (famSame(a, b) or (a == 0 and b == 0)) return true;
    return std.math.isFinite(a) and std.math.isFinite(b) and @abs(a - b) <= rel * @max(@abs(a), @abs(b));
}

fn inF32(x: f64) bool {
    return x == 0 or (@abs(x) >= std.math.floatMin(f32) and @abs(x) <= std.math.floatMax(f32));
}

fn famUlps(a: f64, b: f64) u64 {
    const ia: i64 = @bitCast(a);
    const ib: i64 = @bitCast(b);
    if ((ia < 0) != (ib < 0)) return if (a == b) 0 else std.math.maxInt(u64);
    return @abs(ia - ib);
}

fn famExpect(comptime op: []const u8, narrow: bool, x: f64, y: f64, got: anytype, want: anytype, transcendental: bool) !void {
    const gv = got.val();
    const wv = want.val();
    const v_ok = famSame(gv, wv) or (transcendental and famUlps(gv, wv) <= 1);
    const lanes = std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(wv);
    // Past f32's range an f32 lane rightly flushes or overflows, and so does
    // a coefficient on its way into one.
    const in_range = !narrow or (inF32(x) and inF32(y) and inF32(want.ddxAt(0)) and inF32(want.ddxAt(1)));
    inline for (0..2) |u| {
        // A dense host's `0·inf` on a lane the sparse reference never carries.
        const dense_nan = (@TypeOf(want).mask >> u) & 1 == 0 and std.math.isNan(got.ddxAt(u));
        if (!v_ok or (lanes and in_range and !dense_nan and !famClose(got.ddxAt(u), want.ddxAt(u), 1e-6))) {
            std.debug.print("expectFamily: {s}({e}, {e}) = ({e}, lane{d} {e}), reference ({e}, lane{d} {e})\n", .{ op, x, y, gv, u, got.ddxAt(u), wv, u, want.ddxAt(u) });
            return error.FamilyMismatch;
        }
    }
}

/// Returns the instance pointer type `eval`/`q` take: `*D.Instance` for a
/// device that declares `mutable_eval` (it initializes table state on its
/// first call, permanently and outside timestep rollback), so the host must
/// give each evaluation exclusive access; `*const D.Instance` otherwise.
pub fn InstancePtr(comptime D: type) type {
    return if (@hasDecl(D, "mutable_eval") and D.mutable_eval) *D.Instance else *const D.Instance;
}

// ============================================================================
// Validation
// ============================================================================

/// Checks device `D` against the contract at comptime; a violation is a compile
/// error naming the decl. Required: `U` (a dense `enum(u8)`, ports first),
/// `num_ports` (<= |U|; 0 is legal, §6.2), `Model` and `Instance` (structs
/// whose fields all have defaults and are value types), and
/// `eval(S, x, model, inst, sim) Rows(D, S)`. Every other decl is optional
/// and must be one `validate` knows. The entry points, in the order a host
/// calls them:
///
///   derive(S, *model)            after writing a card, before building instances
///                                (§6.3.4 parameters derived from others)
///   checkShape(&model)           after derive; non-null names a §3.4 shape
///                                parameter the card moved, so refuse the card
///   setup(S, &model, &inst)      after every card, instance, temperature or
///                                `setup_simparams` write; fills `inst.su`
///   collapse(S, &model, &inst)   once per instance at build: per internal unknown,
///                                the index it merges into, or null
///   initState(&model, &inst)     once per instance, before the first solve
///   seed(S, ...)                 once before Newton iteration 1
///   eval / q / evalQ             every iterate; `q` returns one charge per site
///                                (`Sites`), `evalQ` both from one evaluation
///   limit(S, ..., cur, old, sim) every iterate, on the instance's private limited
///                                image; returns `cur` where it does not clamp
///   advanceIteration / checkConvergence
///                                after each iterate / before accepting one
///   updateState(S, ..., x, &state, sim)
///                                at each accepted point; `acceptQ` fuses it with `q`
///   stateCtl(op)                 query, commit or revert the accepted state
///   display(S, &x, ...)          per accepted point, `--display=emit` artifacts only;
///                                a §9.7 `$finish`/`$stop`/`$fatal` exits the process
///   noisePsd / acStim            at any state vector, positional on
///                                `noise_gens` / `ac_gens`
///   acDyn(F, ..., omega, &out)   per small-signal frequency (or lane of them), positional on
///                                `ac_dyn_slots` (`acDynSlots`)
///   nextBreakpoint / pendingBreakpoint / delays
///                                transient breakpoint scheduling
///
/// The value-only hooks take the same `comptime S` as `eval`, with a family
/// whose `Of(m)` carries no lanes, so the host picks the arithmetic of every
/// path. Optional permissions: `jac_f32` (the host may carry lanes in f32;
/// absent, it must assume f64), `jac_f32_host` (take it on the CPU path too;
/// requires `jac_f32`), `batch_ok` (a family whose `V` holds several operating
/// points evaluates each exactly), `mutable_eval` (see `InstancePtr`).
pub fn validate(comptime D: type) void {
    @setEvalBranchQuota(1_000_000);
    const name = @typeName(D);

    // Required decls first, so a missing one reads as a contract violation
    // rather than a raw "no member named ..." error.
    for (.{ "U", "num_ports", "Model", "Instance", "eval" }) |decl| {
        if (!@hasDecl(D, decl))
            @compileError(name ++ ": contract requires `pub " ++ decl ++ "`");
    }

    if (@typeInfo(D.U) != .@"enum" or !isDenseEnum(D.U))
        @compileError(name ++ ".U must be a dense enum(u8) with values 0..n-1");
    const n = nU(D);

    // Ports are a prefix of `U`. Zero is legal: §6.2 makes the port list
    // optional, and a portless module still contributes its private equations.
    const np: usize = D.num_ports;
    if (np > n)
        @compileError(name ++ ".num_ports must be <= |U|");

    validateDefaultedStruct(D, "Model");
    validateDefaultedStruct(D, "Instance");
    if (@hasDecl(D, "mutable_eval") and @TypeOf(D.mutable_eval) != bool)
        @compileError(name ++ ".mutable_eval must be bool");
    validateSimState(D);

    // Generic over S, so only the shape is checkable here.
    validatePhysicsFn(D, "eval");
    if (@hasDecl(D, "q")) validatePhysicsFn(D, "q");

    // `evalQ` fuses `eval` and `q`, so it is meaningless without `q`.
    if (@hasDecl(D, "evalQ")) {
        if (!@hasDecl(D, "q"))
            @compileError(name ++ ".evalQ without q: the fused entry point needs a reactive half");
        if (genericFnError(D, "evalQ", "struct { res: Rows(D, S), q: Sites(D, S) }")) |m| @compileError(m);
    }
    if (qSitesError(D)) |m| @compileError(m);

    // §9.4/§9.5 display phase: `eval`'s generic shape returning void. §9.7
    // `$finish`/`$stop`/`$fatal` inside it exit the process (status 0, or
    // `$fatal`'s finish_number floored at 1), because both clauses tie the task
    // to the accepted point, which is when a host calls this.
    if (@hasDecl(D, "display")) {
        if (genericFnError(D, "display", "void")) |m| @compileError(m);
    }
    if (@hasDecl(D, "file_io") and @TypeOf(D.file_io) != FileIo)
        @compileError(@typeName(D) ++ ".file_io must be a contract.FileIo");

    // A permission, not a shape: the lane width is the host's to choose.
    if (@hasDecl(D, "jac_f32") and @TypeOf(D.jac_f32) != bool)
        @compileError(@typeName(D) ++ ".jac_f32 must be a bool");
    // A request laid on that permission, so refused without it rather than
    // ignored by a host that reads only one of the two decls.
    if (@hasDecl(D, "jac_f32_host")) {
        if (@TypeOf(D.jac_f32_host) != bool)
            @compileError(@typeName(D) ++ ".jac_f32_host must be a bool");
        if (D.jac_f32_host and !(@hasDecl(D, "jac_f32") and D.jac_f32))
            @compileError(@typeName(D) ++ ".jac_f32_host = true without jac_f32 = true");
    }

    // §9.17.3 limiting and SPICE MODEINITJCT seeding, both on the instance's
    // private limited image, never the shared x. `seed` is non-null only on
    // `limit_writes` lanes. `old` is the previous iterate's limited point: the
    // image on `limit_writes` once seed or limit has run, x_old elsewhere. A
    // host that masks ports loses only that clamp, which §9.17.3 permits.
    if (@hasDecl(D, "limit"))
        expectGeneric(D, "limit", 6, "fn (comptime S: type, *const Model, *const Instance, cur: [n_u]f64, old: [n_u]f64, SimState) LimitResult(n_u)");
    // `writes ⊆ reads`: every corrected unknown is one the clamp read.
    for ([_][]const u8{ "limit_reads", "limit_writes" }) |m| {
        if (!@hasDecl(D, m)) continue;
        if (!@hasDecl(D, "limit")) @compileError(@typeName(D) ++ "." ++ m ++ " without a `limit`");
        if (@TypeOf(@field(D, m)) != u64) @compileError(@typeName(D) ++ "." ++ m ++ " must be a u64 mask over U");
    }
    if (@hasDecl(D, "limit_writes") and (limitWrites(D) & ~limitReads(D)) != 0)
        @compileError(@typeName(D) ++ ".limit_writes has a bit limit_reads does not");
    // Rules (a)-(d) of `derivReads`.
    if (derivReadsError(D, n)) |m| @compileError(m);
    if (@hasDecl(D, "seed"))
        expectGeneric(D, "seed", 4, "fn (comptime S: type, *const Model, *const Instance, SimState) [n_u]?f64");
    // Node collapse: per internal unknown, the index it merges into when its
    // separating parasitic resistance is 0, or null.
    if (@hasDecl(D, "collapse"))
        expectGeneric(D, "collapse", 3, "fn (comptime S: type, *const Model, *const Instance) [n_u]?u8");
    // The same map with every retention flag set, at comptime, for a host
    // sizing a reduced derivative basis. Entries point downward at a root,
    // never at another alias, so `root[u] = collapse_full[u] orelse u` is one
    // lookup.
    if (@hasDecl(D, "collapse_full")) {
        if (!@hasDecl(D, "collapse"))
            @compileError(name ++ ": collapse_full without a `collapse`");
        if (@TypeOf(D.collapse_full) != [n]?u8)
            @compileError(name ++ ".collapse_full must be [n_u]?u8");
        for (D.collapse_full, 0..) |e, u| if (e) |r| {
            if (r >= u) @compileError(name ++ ".collapse_full must alias downward");
            if (D.collapse_full[r] != null) @compileError(name ++ ".collapse_full must be fully resolved");
        };
    }

    // `eval` reads Instance, so state `eval` sees (a switch position) lives in
    // Instance fields, and `updateState` gets it mutable.
    if (@hasDecl(D, "initState") or @hasDecl(D, "updateState")) {
        if (!@hasDecl(D, "State"))
            @compileError(name ++ ": initState/updateState require pub const State");
        // initState takes a mutable Instance so a §5.10 held variable can get
        // a parameter-dependent initial value, which a comptime field default
        // cannot express. §9.22 driver access never reaches a device (E0818).
        expectFn(D, "initState", fn (*const D.Model, *D.Instance) D.State);
        expectGeneric(D, "updateState", 6, "fn (comptime S: type, *const Model, *Instance, [n_u]f64, *State, SimState) UpdateResult");
        if (@hasDecl(D, "stateCtl"))
            expectFn(D, "stateCtl", fn (*const D.Model, *D.Instance, *D.State, StateCtlOp) bool);
    }
    if (@hasDecl(D, "state_class")) {
        if (@TypeOf(D.state_class) != StateClass)
            @compileError(name ++ ".state_class must be a contract.StateClass");
        if ((D.state_class == .none) == @hasDecl(D, "updateState"))
            @compileError(name ++ ".state_class: `.none` exactly when there is no updateState");
        // `path_latch` promises the commit that latches the staged values.
        if (D.state_class == .path_latch and !@hasDecl(D, "stateCtl"))
            @compileError(name ++ ".state_class = .path_latch requires stateCtl");
    }
    // The solve-invariant slice: `setup` fills `inst.su`, and `eval` reads it
    // as constants. `setup`'s family must compute values the way `eval`'s does.
    if (@hasDecl(D, "Setup") != @hasDecl(D, "setup") or @hasDecl(D, "setup") != @hasDecl(D, "setup_simparams"))
        @compileError(name ++ ": Setup, setup and setup_simparams come together");
    if (@hasDecl(D, "setup")) {
        const info = @typeInfo(@TypeOf(D.setup));
        if (info != .@"fn" or info.@"fn".params.len != 3 or info.@"fn".params[0].type != type)
            @compileError(name ++ ".setup: expected fn (comptime S: type, *const Model, *Instance) void");
        if (!@hasField(D.Instance, "su") or @FieldType(D.Instance, "su") != D.Setup)
            @compileError(name ++ ".Instance must carry `su: Setup`");
        const sp = @typeInfo(@TypeOf(D.setup_simparams));
        if (sp != .array or sp.array.child != []const u8)
            @compileError(name ++ ".setup_simparams must be [k][]const u8");
    }
    // §5.6.1.2/§4.5.2 `q` and `updateState` fused into one evaluation.
    if (@hasDecl(D, "acceptQ")) {
        if (!@hasDecl(D, "q") or !@hasDecl(D, "updateState"))
            @compileError(name ++ ".acceptQ requires q and updateState");
        expectGeneric(D, "acceptQ", 6, "fn (comptime S: type, *const [n_u]S.V, *const Model, *Instance, *State, SimState) Sites(D, S)");
    }

    // §9.15/§9.17.3 iteration state is separate from accepted-time history.
    if (@hasDecl(D, "advanceIteration"))
        expectGeneric(D, "advanceIteration", 5, "fn (comptime S: type, *const Model, *Instance, [n_u]f64, SimState) void");
    if (@hasDecl(D, "checkConvergence"))
        expectGeneric(D, "checkConvergence", 5, "fn (comptime S: type, *const Model, *const Instance, [n_u]f64, SimState) bool");

    // Convergence aid: the card modified for continuation step `lambda`.
    if (@hasDecl(D, "attempt"))
        expectFn(D, "attempt", fn (D.Model, f64) D.Model);

    // Optional per-unknown metadata tables.
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]UnknownKind)
        @compileError(name ++ ".u_kinds must be [|U|]UnknownKind");

    // §3.6.1.2 `abstol` of each unknown's nature (§3.6.2.3 discipline
    // overrides included): the absolute half of a Newton stopping test.
    if (@hasDecl(D, "u_abstol") and @TypeOf(D.u_abstol) != [n]f64)
        @compileError(name ++ ".u_abstol must be [|U|]f64");

    // §3.6.3.2 a net initializer (`electrical n = 5.0;`) is a nodeset: a
    // starting guess for that unknown, null where none is given. It is not an
    // initial condition the solve must hold.
    if (@hasDecl(D, "u_nodeset") and @TypeOf(D.u_nodeset) != [n]?f64)
        @compileError(name ++ ".u_nodeset must be [|U|]?f64");

    // §5.6 structural Jacobian, over-approximate: bit `cu` of
    // `jac_pattern[ru]` is set when ∂eval[ru]/∂x[cu] can be nonzero, and
    // `q_pattern` says the same for `q`. Absent means dense; omitted above 64
    // unknowns.
    if (@hasDecl(D, "jac_pattern") and @TypeOf(D.jac_pattern) != [n]u64)
        @compileError(name ++ ".jac_pattern must be [|U|]u64");
    if (@hasDecl(D, "q_pattern")) {
        if (@TypeOf(D.q_pattern) != [n]u64)
            @compileError(name ++ ".q_pattern must be [|U|]u64");
        if (!@hasDecl(D, "q"))
            @compileError(name ++ ".q_pattern without a `q` residual to describe");
    }

    // Which rows `eval` (`jac_rows`) and `q` (`q_rows`) ever write, one bit
    // per row. Separate from the pattern because a row can be written with no
    // unknown in it (an independent current source has `jac_pattern = {0, 0}`
    // and two written rows). Only the sound direction is checked: a row with a
    // live column is a written row.
    checkRowMask(D, name, "jac_rows", "eval", n);
    checkRowMask(D, name, "q_rows", "q", n);

    // Noise PSDs: a pure function of any state vector. Only the weak
    // direction is checked (a PSD needs a generator); whether a generator
    // without a PSD is acceptable is the host's call.
    expectArray(D, "noise_gens", NoiseGen(D));
    requireWith(D, "noisePsd", "noise_gens");
    // Clause 12: the row values are meaningless without the rows' shape.
    requireWith(D, "vpiContribs", "vpi_contrib_access");
    requireWith(D, "vpiContribs", "vpi_contrib_hi");
    requireWith(D, "vpiContribs", "vpi_contrib_lo");
    requireWith(D, "vpiContribs", "vpi_contrib_flow_u");
    if (@hasDecl(D, "noisePsd"))
        expectGeneric(D, "noisePsd", 5, "fn (comptime S: type, [n_u]f64, *const Model, *const Instance, SimState) [noise_gens.len]PsdTerm");

    // §4.6.4.3/.4 tables: `noiseTableAt`'s preconditions, checked here
    // because a violation otherwise surfaces as a NaN spectrum.
    expectArray(D, "noise_tables", NoiseTable);
    requireWith(D, "noise_tables", "noise_gens");
    if (@hasDecl(D, "noise_gens")) {
        const tables: []const NoiseTable = if (@hasDecl(D, "noise_tables")) &D.noise_tables else &.{};
        for (D.noise_gens) |g| {
            if ((g.kind == .table) != (g.table != null))
                @compileError(name ++ ".noise_gens: `.table` is set exactly on a `.table` generator");
            if (g.table) |k| if (k >= tables.len)
                @compileError(name ++ ".noise_gens: `.table` index is out of range of `noise_tables`");
        }
        for (tables) |t| {
            if (t.points.len == 0) @compileError(name ++ ".noise_tables: an empty table has no PSD to state");
            for (t.points, 0..) |p, i| {
                if (!(p[0] > 0)) @compileError(name ++ ".noise_tables: frequency must be positive");
                if (!(p[1] >= 0)) @compileError(name ++ ".noise_tables: power must be non-negative");
                if (t.interp == .log and !(p[1] > 0))
                    @compileError(name ++ ".noise_tables: a log table interpolates log(power), so power must be positive");
                if (i != 0 and !(p[0] > t.points[i - 1][0]))
                    @compileError(name ++ ".noise_tables: frequencies must be sorted and unique");
            }
        }
        // §4.6.4.3 array-parameter tables: `noise_tables` holds the declared
        // defaults, and this returns the card's knots, one flat array over
        // every table in `noise_tables` order.
        if (@hasDecl(D, "noiseTablePoints")) {
            var total: usize = 0;
            for (tables) |t| total += t.points.len;
            expectFn(D, "noiseTablePoints", fn (*const D.Model) [total][2]f64);
        }
    }

    // §4.6.3 AC stimuli; `AcGen`'s integer widths range-check row and col.
    expectArray(D, "ac_gens", AcGen(D));
    requireWith(D, "acStim", "ac_gens");
    if (@hasDecl(D, "acStim"))
        expectGeneric(D, "acStim", 5, "fn (comptime S: type, [n_u]f64, *const Model, *const Instance, SimState) [ac_gens.len]AcPhasor");
    if (acDynError(D)) |m| @compileError(m);

    // §2.8.3/§12.32 unresolved `$name`s: the device must have the
    // `Instance.systf` slot the host binds; `validateHost` checks the host.
    expectArray(D, "systf_calls", Systf);
    if (@hasDecl(D, "systf_calls") and D.systf_calls.len != 0) {
        if (!@hasField(D.Instance, "systf"))
            @compileError(name ++ ": declares systf_calls but Instance has no `systf` field " ++
                "for the host to bind — see contract.SystfHost");
        if (@FieldType(D.Instance, "systf") != ?*const SystfHost)
            @compileError(name ++ ".Instance.systf must be `?*const contract.SystfHost`");
    }

    validateMcParam(D);

    // §6.3.4/§3.4.5 parameters defined over other parameters, and every
    // localparam: `Model` is flat, so a write to a base parameter reaches them
    // only through `derive`.
    if (@hasDecl(D, "derive"))
        expectGeneric(D, "derive", 2, "fn (comptime S: type, *Model) void");

    // §3.4 shape parameters, folded into an array bound, a replication count
    // or the generate structure, so the device holds one value of each.
    if (@hasDecl(D, "checkShape"))
        expectFn(D, "checkShape", fn (*const D.Model) ?[]const u8);

    // Hand-written devices' per-instance preparation before a solve.
    if (@hasDecl(D, "precompute"))
        expectFn(D, "precompute", fn (*D.Instance, *const D.Model) void);

    if (@hasDecl(D, "constant") and @TypeOf(D.constant) != Constant)
        @compileError(name ++ ".constant must be contract.Constant");

    // Breakpoint scheduling (piecewise sources).
    if (@hasDecl(D, "nextBreakpoint"))
        expectFn(D, "nextBreakpoint", fn (*const D.Model, f64) ?f64);
    // The live per-instance schedule: §5.10.3.3 timers (re-armed start
    // times included), digital events, and the corners of D2A ramps.
    if (@hasDecl(D, "pendingBreakpoint"))
        expectFn(D, "pendingBreakpoint", fn (*const D.Instance, f64) ?f64);
    // §4.5.7 `absdelay` delays, from which the host echoes breakpoints.
    if (@hasDecl(D, "delays")) {
        const R = @typeInfo(@TypeOf(D.delays)).@"fn".return_type.?;
        if (@typeInfo(R) != .array or @typeInfo(R).array.child != f64)
            @compileError(@typeName(D) ++ ".delays: must return [n]f64");
        expectFn(D, "delays", fn (*const D.Model) R);
    }

    rejectStrayPubDecls(D);
}

/// Checks host `H` against what device `D` needs from it; a host calls it once
/// per device it links, beside `validate(D)`. A missing obligation is a compile
/// error. `H` declares each obligation it meets as a `true` bool:
///   `D.contract_abi` must equal `abi_version` (no declaration; regenerate D);
///   `calls_setup` when D has `setup`: the host calls it after every card,
///     instance, temperature or `setup_simparams` write, before `eval`;
///   `mutable_eval` when D declares it: evaluations get exclusive `*Instance`;
///   `iteration_hooks` when D has `advanceIteration`/`checkConvergence`: the
///     host calls the first after every iterate and the second before
///     accepting one, on the same Instance `eval` reads;
///   `noise_table_points` when D has `noiseTablePoints`: the host reads the
///     card's knots from it, not the defaults in `noise_tables`;
///   `shape_check` when D has `checkShape`: the host calls it after `derive`
///     and refuses a card it names;
///   `calls_ac_dyn` when D declares `ac_dyn_slots`: true when the host adds
///     `acDyn` to every small-signal matrix it builds (`acDynSlots`), false
///     when it runs no small-signal analysis;
///   `systf: fn (*const Model) ?*const SystfHost` when D declares
///     `systf_calls`: §12.32 fixes no default value for an unbound `$name`.
pub fn validateHost(comptime H: type, comptime D: type) void {
    if (!@hasDecl(D, "contract_abi") or D.contract_abi != abi_version)
        @compileError(@typeName(D) ++ " was generated for a different device ABI than this contract's " ++
            std.fmt.comptimePrint("abi_version = {d}", .{abi_version}) ++
            "; regenerate it with the VerA this contract came from.");
    // A host that skips `setup` evaluates at `inst.su`'s NaN initializers.
    if (@hasDecl(D, "setup")) {
        if (!@hasDecl(H, "calls_setup") or !H.calls_setup)
            @compileError(@typeName(H) ++ " must call `setup`: " ++ @typeName(D) ++
                " computes its solve-invariant values once, into `Instance.su`, and `eval` " ++
                "reads them. Declare calls_setup = true once the host calls " ++
                "`setup(V, &model, &inst)` after every card, instance, temperature or " ++
                "`setup_simparams` write.");
    }
    if (@hasDecl(D, "mutable_eval") and D.mutable_eval) {
        if (!@hasDecl(H, "mutable_eval") or !H.mutable_eval)
            @compileError("this device requires exclusive mutable evaluation; declare mutable_eval = true");
    }
    // `advanceIteration` writes `limiter_previous`, which the next `eval`
    // reads, so a host keeping Instance on a GPU runs the hook there.
    if (@hasDecl(D, "advanceIteration") or @hasDecl(D, "checkConvergence")) {
        if (!@hasDecl(H, "iteration_hooks")) @compileError(@typeName(H) ++
            " must implement the Newton iteration hooks and declare iteration_hooks = true; " ++
            "updateState alone cannot execute this device, and its limiter_previous is written " ++
            "by advanceIteration on the Instance eval reads.");
        if (!H.iteration_hooks) @compileError("this device requires Newton iteration hooks");
    }
    // A host reading only `noise_tables` would silently ignore the card.
    if (@hasDecl(D, "noiseTablePoints")) {
        if (!@hasDecl(H, "noise_table_points") or !H.noise_table_points)
            @compileError(@typeName(H) ++ " must read `noiseTablePoints`: " ++ @typeName(D) ++
                " has a 4.6.4.3 noise table whose knots are model parameters, and " ++
                "`noise_tables` carries only their declared defaults. Declare " ++
                "noise_table_points = true once the host reads the hook.");
    }
    // A card that moves a §3.4 shape parameter would otherwise evaluate with a
    // wrong-sized array, silently.
    if (@hasDecl(D, "checkShape")) {
        if (!@hasDecl(H, "shape_check") or !H.shape_check)
            @compileError(@typeName(H) ++ " must call `checkShape`: " ++ @typeName(D) ++
                " was compiled for fixed values of its shape parameters (3.4), and a card " ++
                "that moves one must be refused. Declare shape_check = true once the host " ++
                "calls it after `derive`.");
    }
    // Under `.ac`/`.noise` `eval` omits these slots' partials, so a host that
    // does not add `acDyn` back solves a matrix missing them.
    if (@hasDecl(D, "ac_dyn_slots") and !@hasDecl(H, "calls_ac_dyn"))
        @compileError(@typeName(H) ++ " must declare `calls_ac_dyn`: " ++ @typeName(D) ++
            " has small-signal slots that depend on frequency (4.5.7 absdelay, 4.5.11 laplace, " ++
            "4.5.12 zi), which `eval` leaves out under .ac and .noise. Declare calls_ac_dyn = true " ++
            "once every small-signal matrix adds `acDyn`'s terms, or false if the host runs no " ++
            "small-signal analysis.");
    if (!@hasDecl(D, "systf_calls") or D.systf_calls.len == 0) return;
    const d = @typeName(D);
    const h = @typeName(H);
    if (!@hasDecl(H, "systf")) @compileError(h ++ " must declare `systf` — " ++ d ++
        " calls " ++ D.systf_calls[0].name ++ ", which §2.8.3 leaves to a VPI application, " ++
        "and this host binds none. See contract.SystfHost.");
    if (@TypeOf(@field(H, "systf")) != fn (*const D.Model) ?*const SystfHost and
        @TypeOf(@field(H, "systf")) != *const fn (*const D.Model) ?*const SystfHost)
        @compileError(h ++ ".systf must be `fn (*const Model) ?*const contract.SystfHost`");
}

const allowed_pub_decls = std.StaticStringMap(void).initComptime(.{
    .{ "U", {} },
    .{ "num_ports", {} },
    .{ "contract_abi", {} },
    .{ "Model", {} },
    .{ "Instance", {} },
    .{ "eval", {} },
    .{ "q", {} },
    .{ "evalQ", {} },
    .{ "limit", {} },
    .{ "limit_reads", {} },
    .{ "limit_writes", {} },
    .{ "deriv_reads", {} },
    .{ "ddx_reads", {} },
    .{ "jac_const", {} },
    .{ "seed", {} },
    .{ "collapse", {} },
    .{ "collapse_full", {} },
    .{ "initState", {} },
    .{ "updateState", {} },
    .{ "advanceIteration", {} },
    .{ "checkConvergence", {} },
    .{ "stateCtl", {} },
    .{ "State", {} },
    .{ "state_class", {} },
    .{ "acceptQ", {} },
    .{ "Setup", {} },
    .{ "setup", {} },
    .{ "setup_simparams", {} },
    .{ "jac_f32", {} },
    .{ "jac_f32_host", {} },
    // Nothing steers on a `.val()` of an x-dependent value, draws a per-call
    // scalar, or collapses an x-dependent chain to its value.
    .{ "batch_ok", {} },
    .{ "mutable_eval", {} },
    .{ "noiseTablePoints", {} },
    // §9.4 display tasks and §9.5 file I/O, one accepted-point phase (§9.5.9
    // performs file writes only at an accepted point), kept out of `eval` so
    // the residual stays a pure function of x. A device built for a solver has
    // no display phase, and its `$fopen` returns §9.5.1's failure value 0.
    .{ "display", {} },
    .{ "file_io", {} },
    .{ "attempt", {} },
    .{ "u_kinds", {} },
    .{ "u_abstol", {} },
    .{ "u_nodeset", {} },
    .{ "jac_pattern", {} },
    .{ "q_pattern", {} },
    .{ "jac_rows", {} },
    .{ "q_rows", {} },
    .{ "n_q", {} },
    .{ "q_stamps", {} },
    .{ "q_lte", {} },
    .{ "q_site_pattern", {} },
    .{ "noise_gens", {} },
    .{ "noisePsd", {} },
    .{ "noise_tables", {} },
    .{ "ac_gens", {} },
    .{ "acStim", {} },
    .{ "ac_dyn_slots", {} },
    .{ "acDyn", {} },
    .{ "systf_calls", {} },
    .{ "mc_param", {} },
    .{ "derive", {} },
    .{ "checkShape", {} },
    .{ "precompute", {} },
    .{ "constant", {} },
    .{ "nextBreakpoint", {} },
    .{ "pendingBreakpoint", {} },
    .{ "delays", {} },
    // Clause 12: the §5.6 contribution rows an analog VPI host reads §12.10's
    // flows from, emitted only under `codegen.Options.vpi_contribs`.
    .{ "vpiContribs", {} },
    .{ "vpi_contrib_access", {} },
    .{ "vpi_contrib_hi", {} },
    .{ "vpi_contrib_lo", {} },
    .{ "vpi_contrib_flow_u", {} },
    .{ "lane_masks", {} },
});

fn rejectStrayPubDecls(comptime D: type) void {
    const decls = @typeInfo(D).@"struct".decls;
    for (decls) |d| {
        if (allowed_pub_decls.has(d.name)) continue;
        // `<module>__analog_op__{laplace,zi}_*__sec`: a §4.5.11/§4.5.12
        // filter's cascade coefficients, public because a small-signal host
        // builds H(jw) from them. The name embeds the module, so it cannot be
        // listed. TODO: drop once `laplace_*` lowers to internal unknowns and
        // `zi_*` has a complex AC stamp.
        // ponytail: the exemption is suffix-only; endsWith owns the length guard.
        if (std.mem.endsWith(u8, d.name, "__sec")) continue;
        @compileError(@typeName(D) ++ ": stray pub decl `" ++ d.name ++
            "` — only contract-recognized names may be pub");
    }
}

/// eval/q are generic over S, so only arity and the comptime first parameter
/// are checked here; instantiation checks the rest.
fn validatePhysicsFn(comptime D: type, comptime fn_name: []const u8) void {
    if (genericFnError(D, fn_name, if (std.mem.eql(u8, fn_name, "q")) "Sites(D, S)" else "Rows(D, S)")) |m| @compileError(m);
}

/// The shape shared by `eval`, `q`, `evalQ` and `display`: five parameters,
/// the first `comptime S: type`. `ret` only names the result in the message.
/// Returns the message rather than raising it so the refusal is testable.
fn genericFnError(comptime D: type, comptime fn_name: []const u8, comptime ret: []const u8) ?[]const u8 {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != 5 or info.@"fn".params[0].type != type)
        return @typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, *const [n_u]S.V, *const Model, InstancePtr, SimState) " ++ ret;
    return null;
}

/// A generic entry point: `params` parameters, the first `comptime S: type`.
/// `shape` names the whole expected signature in the complaint.
fn expectGeneric(comptime D: type, comptime fn_name: []const u8, comptime params: usize, comptime shape: []const u8) void {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != params or info.@"fn".params[0].type != type)
        @compileError(@typeName(D) ++ "." ++ fn_name ++ ": expected " ++ shape);
}

fn expectFn(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(D, fn_name))
        @compileError(@typeName(D) ++ ": missing " ++ fn_name);
    if (@TypeOf(@field(D, fn_name)) != Expected)
        @compileError(@typeName(D) ++ "." ++ fn_name ++ ": expected " ++ @typeName(Expected));
}

/// If `D` declares `decl`, it must be a `[k]Child` array.
fn expectArray(comptime D: type, comptime decl: []const u8, comptime Child: type) void {
    if (!@hasDecl(D, decl)) return;
    const info = @typeInfo(@TypeOf(@field(D, decl)));
    if (info != .array or info.array.child != Child)
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be [k]" ++ @typeName(Child));
}

/// Checks `jac_rows`/`q_rows` (bit `ru` set when `half` ever writes row `ru`).
fn checkRowMask(
    comptime D: type,
    comptime name: []const u8,
    comptime decl: []const u8,
    comptime half: []const u8,
    comptime n: usize,
) void {
    if (rowMaskError(D, name, decl, half, n)) |m| @compileError(m);
}

/// The testable half of `checkRowMask`. Containment runs one way only: a row
/// with a live pattern column must be marked written, never the reverse.
fn rowMaskError(
    comptime D: type,
    comptime name: []const u8,
    comptime decl: []const u8,
    comptime half: []const u8,
    comptime n: usize,
) ?[]const u8 {
    if (!@hasDecl(D, decl)) return null;
    if (@TypeOf(@field(D, decl)) != u64)
        return name ++ "." ++ decl ++ " must be u64";
    if (n > 64)
        return name ++ "." ++ decl ++ " with |U| > 64 — omit it, the dense fallback is correct";
    if (!@hasDecl(D, half))
        return name ++ "." ++ decl ++ " without a `" ++ half ++ "` residual to describe";
    const pat = if (std.mem.eql(u8, half, "q")) "q_pattern" else "jac_pattern";
    if (!@hasDecl(D, pat)) return null;
    const mask: u64 = @field(D, decl);
    for (@field(D, pat), 0..) |row, ru| {
        if (row == 0) continue;
        if ((mask >> @intCast(ru)) & 1 != 0) continue;
        return name ++ "." ++ decl ++ ": row " ++ std.fmt.comptimePrint("{d}", .{ru}) ++
            " has live " ++ pat ++ " columns but is not marked written";
    }
    return null;
}

/// `derivReads`' rules (a)-(d), returned rather than raised so each is
/// testable. `n` is |U|, passed in so rule (a) is testable without a
/// 65-member enum.
fn derivReadsError(comptime D: type, comptime n: usize) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "deriv_reads")) {
        if (@TypeOf(D.deriv_reads) != u64) return name ++ ".deriv_reads must be a u64 mask over U";
        if (n > 64) return name ++ ".deriv_reads with |U| > 64 — omit it, the all-lanes default is correct";
    }
    if (@hasDecl(D, "limit") and (limitWrites(D) & ~derivReads(D)) != 0)
        return name ++ ".limit_writes has a bit deriv_reads does not: the limiting correction needs that lane";
    if (@hasDecl(D, "ddx_reads") and @TypeOf(D.ddx_reads) != u64) return name ++ ".ddx_reads must be a u64 mask over U";
    if ((ddxReads(D) & ~derivReads(D)) != 0)
        return name ++ ".ddx_reads has a bit deriv_reads does not: ddx() reads that lane";
    if (!@hasDecl(D, "jac_const")) return null;
    const mask = derivReads(D);
    const t = jacConst(D);
    for (t, 0..) |e, k| {
        const r: usize = @intFromEnum(e.row);
        const c: usize = @intFromEnum(e.col);
        if (c < 64 and (mask >> @intCast(c)) & 1 != 0)
            return name ++ ".jac_const: column `" ++ @tagName(e.col) ++ "` is in deriv_reads, so its partials are not constant";
        if (e.g == 0 and e.c == 0)
            return name ++ ".jac_const: an all-zero entry — an absent entry already means exactly 0";
        if (e.when) |w| if (!@hasField(D.Model, w.flag))
            return name ++ ".jac_const: `when.flag` \"" ++ w.flag ++ "\" is not a field of Model";
        if (k == 0) continue;
        const pr: usize = @intFromEnum(t[k - 1].row);
        const pc: usize = @intFromEnum(t[k - 1].col);
        if (r < pr or (r == pr and c <= pc))
            return name ++ ".jac_const must be sorted by (row, col) with no duplicates";
    }
    return null;
}

/// Refuses `decl` without `needs`. Called both ways for a mutually required
/// pair.
fn requireWith(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) void {
    if (requireWithError(D, decl, needs)) |m| @compileError(m);
}

/// The testable half of `requireWith`.
fn requireWithError(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) ?[]const u8 {
    if (@hasDecl(D, decl) and !@hasDecl(D, needs))
        return @typeName(D) ++ ": `" ++ decl ++ "` requires `" ++ needs ++ "`";
    return null;
}

/// A float field of either width: VerA emits `f64` parameters, and a
/// hand-written device may declare `f32`.
fn hasFloatField(comptime T: type, comptime name: []const u8) bool {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and (f.type == f32 or f.type == f64)) return true;
    }
    return false;
}

/// Checks the host-written `Instance` and `Model` fields (`sim_state_fields`,
/// `host_model_fields`).
fn validateSimState(comptime D: type) void {
    const name = @typeName(D);
    for (sim_state_fields) |f| {
        if (!@hasField(D.Instance, f.name)) continue;
        if (@FieldType(D.Instance, f.name) != f.T)
            @compileError(name ++ ".Instance." ++ f.name ++ ": host-written field must be " ++
                @typeName(f.T));
    }
    for (host_model_fields) |f| {
        if (@hasField(D.Model, f) and @FieldType(D.Model, f) != f64)
            @compileError(name ++ ".Model." ++ f ++ ": host-written field must be f64");
    }

    // `SimState` carries these, so an Instance field of the same name is one
    // no host writes: a device built for an earlier contract.
    for ([_][]const u8{ "abstime", "dt", "analysis_kind", "is_initial_step", "is_final_step", "is_analog_initial", "newton_iteration" }) |f| {
        if (@hasField(D.Instance, f))
            @compileError(name ++ ".Instance." ++ f ++ ": the host passes it in `contract.SimState`, not in Instance");
    }
}

fn validateDefaultedStruct(comptime D: type, comptime decl: []const u8) void {
    const T = @field(D, decl);
    if (@typeInfo(T) != .@"struct")
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be a struct");
    for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null)
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++ " must have a default value");
        if (!isValueType(f.type))
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++
                ": field type must be numeric/bool/enum, []const u8, or a fixed-size array of these");
    }
}

fn isValueType(comptime T: type) bool {
    // String parameters point at literals in the device image, which a
    // loader keeps mapped for as long as any Model blob lives.
    if (T == []const u8) return true;
    // The §12.32 VPI binding: a host-owned pointer the device only calls
    // through. Admitted by name, not by shape, because a pointer in `Model`
    // would be copied across the `.so` seam; an `Instance` never is.
    if (T == ?*const SystfHost) return true;
    // §9.12 `Instance.plusargs`, admitted by name for the same reason: the
    // host's own argv, host-owned and host-lifetime.
    if (T == []const [:0]const u8) return true;
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        // Integer-backed enums are fixed-size POD.
        .@"enum" => |e| isValueType(e.tag_type),
        .array => |a| isValueType(a.child),
        // `Instance.su` (a `Setup`): a plain struct of value fields is as
        // copyable as its fields. `void` is `su_ok` outside Debug.
        .@"struct" => |s| for (s.fields) |f| {
            if (!isValueType(f.type)) break false;
        } else true,
        .void => true,
        else => false,
    };
}

fn isDenseEnum(comptime E: type) bool {
    const info = @typeInfo(E).@"enum";
    if (info.tag_type != u8) return false;
    for (info.fields, 0..) |f, idx| {
        if (f.value != idx) return false;
    }
    return true;
}

/// `mc_param` names the float field of Model or Instance that Monte Carlo
/// varies (`pub const mc_param = "resist";`).
fn validateMcParam(comptime D: type) void {
    if (!@hasDecl(D, "mc_param")) return;
    if (!hasFloatField(D.Instance, D.mc_param) and !hasFloatField(D.Model, D.mc_param))
        @compileError(@typeName(D) ++ ".mc_param '" ++ D.mc_param ++
            "' is not a float field of Model or Instance");
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const MockR = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const contract_abi = abi_version;
    const n_u = nU(@This());

    pub const Model = struct {
        g: f64 = 1e-3,
    };

    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, _: *const Instance, _: SimState) Rows(@This(), S) {
        const p = probes(@This(), S, x);
        const ir = p[0].sub(p[1]).scale(model.g);
        return rows(@This(), S, .{ ir, ir.neg() });
    }
};

const MockSw = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    // Switch position lives in Instance so eval can read it.
    pub const State = struct { flips: u32 = 0 };

    pub const Model = struct {
        gon: f64 = 1.0,
        goff: f64 = 1e-12,
    };

    pub const Instance = struct {
        closed: bool = false,
    };

    pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: *const Instance, _: SimState) Rows(@This(), S) {
        const g = if (inst.closed) model.gon else model.goff;
        const p = probes(@This(), S, x);
        const ir = p[0].sub(p[1]).scale(g);
        return rows(@This(), S, .{ ir, ir.neg() });
    }

    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }

    pub fn updateState(comptime _: type, _: *const Model, inst: *Instance, x: [n_u]f64, s: *State, _: SimState) UpdateResult {
        const want = (x[0] - x[1]) > 0.5;
        if (want != inst.closed) {
            inst.closed = want;
            s.flips += 1;
        }
        return .ok;
    }

    pub fn attempt(model: Model, lambda: f64) Model {
        var m = model;
        m.gon *= lambda;
        return m;
    }

    pub fn limit(comptime _: type, _: *const Model, _: *const Instance, x_new: [n_u]f64, _: [n_u]f64, _: SimState) LimitResult(n_u) {
        return .{ .x = x_new, .converged = true };
    }
};

const MockTline = struct {
    const Self = @This();

    pub const U = enum(u8) { p1, p2 };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    pub const Model = struct {
        z0: f32 = 50,
        td: f32 = 1e-9,
    };

    pub const Instance = struct {
        // Host-written; name and type are contract (see sim_state_fields).
        bound_step: f64 = std.math.inf(f64),
    };

    pub const mc_param = "z0";
    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    pub const noise_gens = [_]NoiseGen(@This()){.{ .row = 0, .col = 1, .kind = .thermal }};

    pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, _: *const Instance, _: SimState) Rows(Self, S) {
        const y0 = 1.0 / @as(f64, model.z0);
        const p = probes(Self, S, x);
        return rows(Self, S, .{ p[0].scale(y0), p[1].scale(y0) });
    }
};

/// Declares every contract member, so `allowed_pub_decls` cannot drift from
/// `validate`: a member missing from the allowlist is a stray-pub-decl error
/// here.
const MockAll = struct {
    const Self = @This();
    const n_u = nU(@This());

    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const contract_abi = abi_version;
    pub const State = struct { flips: u32 = 0 };
    pub const jac_f32 = true;
    pub const jac_f32_host = true;
    pub const batch_ok = true;
    pub const mutable_eval = false;

    pub const Model = struct { g: f32 = 1e-3 };
    pub const Instance = struct {
        temperature: f64 = 300.15,
        mfactor: f64 = 1,
        bound_step: f64 = std.math.inf(f64),
        systf: ?*const SystfHost = null,
        su: Setup = .{},
    };
    pub const Setup = struct { r: [1]f64 = @splat(std.math.nan(f64)) };
    pub const setup_simparams = [_][]const u8{"tnom"};
    pub fn setup(comptime V: type, m: *const Model, inst: *Instance) void {
        inst.su.r[0] = V.con(@floatCast(m.g)).val();
    }

    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    // §3.6.1.2 electrical potential's abstol, both unknowns being voltages.
    pub const u_abstol = [n_u]f64{ 1e-6, 1e-6 };
    // §3.6.3.2 one net declared `electrical p = 5.0;`, the other with no
    // initializer; the mock carries both halves so `?f64` is exercised.
    pub const u_nodeset = [n_u]?f64{ 5.0, null };
    pub const mc_param = "g";
    pub const constant: Constant = .{ .g = true };
    // §4.6.4: a parametric generator and a §4.6.4.4 tabulated one, so the
    // `kind`/`table` pairing and the all-zero `PsdTerm` of a table row are both
    // declared somewhere that `validate` sees them.
    pub const noise_gens = [_]NoiseGen(Self){
        .{ .row = 0, .col = 1, .kind = .thermal },
        .{ .row = 0, .col = 1, .kind = .table, .table = 0 },
    };
    pub const noise_tables = [_]NoiseTable{
        .{ .interp = .log, .points = &.{ .{ 1, 1e-18 }, .{ 1e6, 1e-24 } } },
    };
    // §4.6.4.3's array-parameter input, where `noise_tables` above is the
    // DECLARED DEFAULT and this is the card's: one flat array over every
    // table, so its length is the sum of their `points.len`.
    pub fn noiseTablePoints(m: *const Model) [2][2]f64 {
        return .{ .{ 1, 1e-18 * @as(f64, m.g) }, .{ 1e6, 1e-24 } };
    }
    // §4.6.3: one stimulus on the (0,1) branch, so the `ac_gens`/`acStim`
    // pairing and `AcPhasor`'s polar shape are both somewhere `validate` sees.
    pub const ac_gens = [_]AcGen(Self){.{ .row = 0, .col = 1, .name = "ac" }};
    pub const systf_calls = [_]Systf{.{ .name = "$sampnhold" }};
    // §9.5.1.2 a table that has nothing open: every operation answers "no".
    pub const file_io: FileIo = .{
        .open = struct {
            fn f(_: []const u8, _: []const u8, _: bool) i64 {
                return 0;
            }
        }.f,
        .close = noFile,
        .put = struct {
            fn f(_: i64, _: []const u8) i64 {
                return 0;
            }
        }.f,
        .getc = noFile,
        .ungetc = struct {
            fn f(_: i64, _: i64) i64 {
                return -1;
            }
        }.f,
        .tell = noFile,
        .seek = struct {
            fn f(_: i64, _: i64, _: i64) i64 {
                return -1;
            }
        }.f,
        .eof = noFile,
    };
    fn noFile(_: i64) i64 {
        return -1;
    }
    // All-ones is what a host assumes for an omitted mask, so it cannot be
    // wrong here. `q` is diagonal so `checkRowMask` sees a narrower pattern.
    pub const jac_pattern = [n_u]u64{ 0b11, 0b11 };
    pub const q_pattern = [n_u]u64{ 0b01, 0b10 };
    pub const jac_rows: u64 = 0b11;
    pub const q_rows: u64 = 0b11;
    pub const limit_reads: u64 = 0b11;
    pub const limit_writes: u64 = 0b11;
    // `eval` scales by the model's `g`, so neither column is constant, and
    // rule (b) would demand both lanes anyway, since `limit` writes both.
    pub const deriv_reads: u64 = 0b11;
    pub const ddx_reads: u64 = 0b01;
    pub const jac_const = [_]JacConst(U){};
    // §5.6.1.2 two charge sites, one per row; the second is left out of
    // truncation, the way a junction charge is.
    pub const n_q: usize = 2;
    pub const q_stamps = [_]QStamp(U){ .{ .site = 0, .row = .p, .sign = 1 }, .{ .site = 1, .row = .n, .sign = 1 } };
    pub const q_lte = [n_q]bool{ true, false };
    pub const q_site_pattern = [n_q]u64{ 0b01, 0b10 };

    pub fn eval(comptime S: type, x: *const [n_u]S.V, m: *const Model, _: *const Instance, _: SimState) Rows(Self, S) {
        const p = probes(Self, S, x);
        const i = p[0].sub(p[1]).scale(@as(f64, m.g));
        return rows(Self, S, .{ i, i.neg() });
    }
    pub fn evalQ(comptime S: type, x: *const [n_u]S.V, m: *const Model, i: *const Instance, sim: SimState) struct { res: Rows(Self, S), q: Sites(Self, S) } {
        return .{ .res = eval(S, x, m, i, sim), .q = q(S, x, m, i, sim) };
    }
    pub fn q(comptime S: type, x: *const [n_u]S.V, _: *const Model, _: *const Instance, _: SimState) Sites(Self, S) {
        return .{ S.probe(0, x[0]).scale(1e-12), S.probe(1, x[1]).scale(-1e-12) };
    }
    pub fn limit(comptime _: type, _: *const Model, _: *const Instance, cur: [n_u]f64, _: [n_u]f64, _: SimState) LimitResult(n_u) {
        return .{ .x = cur, .converged = true };
    }
    pub fn seed(comptime _: type, _: *const Model, _: *const Instance, _: SimState) [n_u]?f64 {
        return .{ 0.6, null };
    }
    pub fn collapse(comptime _: type, _: *const Model, _: *const Instance) [n_u]?u8 {
        return .{ null, null };
    }
    pub const collapse_full: [n_u]?u8 = .{ null, 0 };
    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }
    pub fn updateState(comptime _: type, _: *const Model, _: *Instance, _: [n_u]f64, s: *State, _: SimState) UpdateResult {
        s.flips += 1;
        return .ok;
    }
    pub const state_class: StateClass = .history;
    pub fn acceptQ(comptime S: type, x: *const [n_u]S.V, m: *const Model, inst: *Instance, s: *State, sim: SimState) Sites(Self, S) {
        s.flips += 1;
        return q(S, x, m, inst, sim);
    }

    pub fn advanceIteration(comptime _: type, _: *const Model, _: *Instance, _: [n_u]f64, _: SimState) void {}

    pub fn checkConvergence(comptime _: type, _: *const Model, _: *const Instance, _: [n_u]f64, _: SimState) bool {
        return true;
    }

    pub fn stateCtl(_: *const Model, _: *Instance, _: *State, _: StateCtlOp) bool {
        return false;
    }
    pub fn attempt(m: Model, lambda: f64) Model {
        var out = m;
        out.g *= @floatCast(lambda);
        return out;
    }
    pub fn noisePsd(comptime _: type, _: [n_u]f64, m: *const Model, _: *const Instance, _: SimState) [noise_gens.len]PsdTerm {
        // Row 1 is the table's, and its parametric part is zero: the table IS
        // its spectrum, so anything else here would be added to it.
        return .{ .{ .white = 4 * 1.38e-23 * 300.15 * @as(f64, m.g) }, .{ .white = 0 } };
    }
    pub fn acStim(comptime _: type, _: [n_u]f64, _: *const Model, _: *const Instance, _: SimState) [ac_gens.len]AcPhasor {
        return .{.{ .mag = 1, .phase = 0 }};
    }
    // §4.5.7 a 1 ns delay on the (p, n) partial.
    pub const ac_dyn_slots = [_]u32{1};
    pub fn acDyn(comptime F: type, _: *const Model, _: *const Instance, _: *const [n_u]f64, _: SimState, omega: F, out: *[ac_dyn_slots.len]std.math.Complex(F)) void {
        const td: F = if (@typeInfo(F) == .vector) @splat(1e-9) else 1e-9;
        out[0] = .init(@cos(omega * td), -@sin(omega * td));
    }
    pub fn derive(comptime _: type, _: *Model) void {}
    pub fn checkShape(m: *const Model) ?[]const u8 {
        return if (m.g != 1e-3) "g" else null;
    }
    pub fn precompute(_: *Instance, _: *const Model) void {}
    pub fn nextBreakpoint(_: *const Model, _: f64) ?f64 {
        return null;
    }
    pub fn pendingBreakpoint(_: *const Instance, _: f64) ?f64 {
        return null;
    }
    pub fn delays(_: *const Model) [1]f64 {
        return .{1e-9};
    }
    /// The shape tb.zig's generated runner calls and codegen emits.
    pub fn display(comptime _: type, _: *const [n_u]f64, _: *const Model, _: *const Instance, _: SimState) void {}
    /// `codegen.Options.vpi_contribs`: one flow row from p to n.
    pub const vpi_contrib_access = [_]u8{1};
    pub const vpi_contrib_hi = [_]i32{0};
    pub const vpi_contrib_lo = [_]i32{1};
    pub const vpi_contrib_flow_u = [_]i32{-1};
    pub fn vpiContribs(comptime S: type, x: *const [n_u]S.V, m: *const Model, _: *const Instance, _: SimState) [1][2]f64 {
        return .{.{ (x[0] - x[1]) * m.g, 0.0 }};
    }
    pub const lane_masks = [_]LaneUse{.{ .mask = 0b11, .uses = 1 }};
};

test "validate: minimal resistor" {
    comptime validate(MockR);
}

test "validate: every contract member at once (allowlist cannot drift)" {
    comptime validate(MockAll);
    // Every allowlisted name is either declared above or is a required decl
    // MockAll already has, so an entry added to one and not the other fails.
    comptime for (allowed_pub_decls.keys()) |k| {
        if (!@hasDecl(MockAll, k))
            @compileError("allowed_pub_decls has `" ++ k ++ "` but MockAll does not declare it");
    };
}

test "display shapes: the generic 5-param form, wrong arities refused" {
    // A 2-arg `(Model, Instance)` display fails in the RUNNER's build, three
    // cache steps from the device that caused it, so it is refused at the
    // definition.
    const Bad = struct {
        pub const Model = struct {};
        pub const Instance = struct {};
        pub fn display(_: *const Model, _: *const Instance) void {}
        pub fn eval(_: f64) void {} // not generic: first param is not `type`
    };
    try testing.expect(comptime (genericFnError(Bad, "display", "void") != null));
    try testing.expect(comptime (genericFnError(Bad, "eval", "Rows(D, S)") != null));
    // The real shapes pass: MockAll.display mirrors codegen's emitted decl.
    try testing.expect(comptime (genericFnError(MockAll, "display", "void") == null));
    try testing.expect(comptime (genericFnError(MockAll, "eval", "Rows(D, S)") == null));
}

test "jac_rows: an empty pattern row may still be written; a live one may not be unwritten" {
    // `isource`'s shape, and the whole reason the declaration exists: the DC
    // current depends on no unknown, so both column masks are empty while both
    // rows are written. A host that inferred "row dead" from "columns dead"
    // would delete it, so this direction has to stay legal.
    const Isrc = struct {
        pub const jac_pattern = [2]u64{ 0, 0 };
        pub const jac_rows: u64 = 0b11;
        pub fn eval() void {}
    };
    try testing.expect(comptime (rowMaskError(Isrc, "Isrc", "jac_rows", "eval", 2) == null));

    // The unsound direction: row 1 has a live partial, so it is unarguably
    // written, and claiming otherwise deletes a real Jacobian entry.
    const Bad = struct {
        pub const jac_pattern = [2]u64{ 0, 0b10 };
        pub const jac_rows: u64 = 0b01;
        pub fn eval() void {}
    };
    try testing.expect(comptime (rowMaskError(Bad, "Bad", "jac_rows", "eval", 2) != null));

    // And a mask with no residual to describe.
    const Orphan = struct {
        pub const q_rows: u64 = 0b11;
    };
    try testing.expect(comptime (rowMaskError(Orphan, "Orphan", "q_rows", "q", 2) != null));
}

/// A §5.6 potential source, `V(p,n) <+ vdc`: the shape whose every partial is
/// constant. The branch flow `br` enters KCL as ±x[br] and the branch row is
/// `x[p] − x[n] − vdc`, so no column needs a lane.
const MockVsrc = struct {
    pub const U = enum(u8) { p, n, br };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());
    pub const Model = struct { vdc: f64 = 1.5 };
    pub const Instance = struct {};
    pub const deriv_reads: u64 = 0;
    pub const ddx_reads: u64 = 0;
    pub const jac_const = [_]JacConst(U){
        .{ .row = .p, .col = .br, .g = 1, .c = 0 },
        .{ .row = .n, .col = .br, .g = -1, .c = 0 },
        .{ .row = .br, .col = .p, .g = 1, .c = 0 },
        .{ .row = .br, .col = .n, .g = -1, .c = 0 },
    };
    pub fn eval(comptime S: type, x: *const [n_u]S.V, m: *const Model, _: *const Instance, _: SimState) Rows(@This(), S) {
        const p = probes(@This(), S, x);
        return rows(@This(), S, .{ p[2], p[2].neg(), p[0].sub(p[1]).addC(-m.vdc) });
    }
};

test "deriv_reads/jac_const: a linear device needs no lane, and the table is its Jacobian" {
    comptime validate(MockVsrc);
    // The table is exact, so a unit step on a column moves each row by
    // exactly the entry's `g`, a finite difference with no truncation error,
    // because every term the column enters is linear.
    const m: MockVsrc.Model = .{};
    const base = [3]f64{ 0.25, -0.5, 2e-3 };
    const Values = RefFamily(f64, &(.{no_lane} ** 3), .{ .dense = true });
    const r0: [3]Values = MockVsrc.eval(Values, &base, &m, &.{}, .{});
    for (0..3) |col| {
        var xs = base;
        xs[col] += 1.0;
        const r1: [3]Values = MockVsrc.eval(Values, &xs, &m, &.{}, .{});
        for (0..3) |row| {
            var want: f64 = 0;
            for (jacConst(MockVsrc)) |e| {
                if (@intFromEnum(e.row) == row and @intFromEnum(e.col) == col) want = e.g;
            }
            try testing.expectEqual(want, r1[row].v - r0[row].v);
        }
    }
}

test "q sites: rows are the signed sums of the stamps, and the table's rules refuse their mistakes" {
    // Two charges at the gate row: a per-row host would see one sum, the
    // per-site one sees both.
    const U3 = enum(u8) { g, s, d };
    const Two = struct {
        pub const U = U3;
        pub const n_q: usize = 2;
        pub const q_stamps = [_]QStamp(U3){
            .{ .site = 0, .row = .g, .sign = 1 },
            .{ .site = 1, .row = .g, .sign = 1 },
            .{ .site = 0, .row = .s, .sign = -1 },
            .{ .site = 1, .row = .d, .sign = -1 },
        };
        pub const q_lte = [n_q]bool{ true, false };
    };
    try testing.expect(comptime (qSitesError(Two) == null));
    const Values = RefFamily(f64, &(.{no_lane} ** 3), .{ .dense = true });
    const qr = qRows(Two, Values, .{ Values.con(2.0), Values.con(0.5) });
    try testing.expectEqual(@as(f64, 2.5), qr[0].v);
    try testing.expectEqual(@as(f64, -2.0), qr[1].v);
    try testing.expectEqual(@as(f64, -0.5), qr[2].v);
    try testing.expectEqual([2]bool{ true, false }, qLte(Two));
    // No declaration: the per-row layout, identity stamps, every site checked.
    try testing.expectEqual(@as(usize, 3), qStamps(struct {
        pub const U = U3;
    }).len);
    // Unsorted, a site past n_q, a zero sign, and n_q without q_stamps.
    const Bad = struct {
        fn of(comptime t: []const QStamp(U3)) type {
            return struct {
                pub const U = U3;
                pub const n_q: usize = 2;
                pub const q_stamps = t[0..t.len].*;
            };
        }
    };
    try testing.expect(comptime (qSitesError(Bad.of(&.{ .{ .site = 0, .row = .s, .sign = 1 }, .{ .site = 0, .row = .g, .sign = 1 } })) != null));
    try testing.expect(comptime (qSitesError(Bad.of(&.{.{ .site = 2, .row = .g, .sign = 1 }})) != null));
    try testing.expect(comptime (qSitesError(Bad.of(&.{.{ .site = 0, .row = .g, .sign = 0 }})) != null));
    try testing.expect(comptime (qSitesError(struct {
        pub const U = U3;
        pub const n_q: usize = 1;
    }) != null));
}

test "ac_dyn_slots: each rule refuses its own mistake" {
    try testing.expect(comptime (acDynError(MockAll) == null));
    const Of = struct {
        fn dev(comptime slots: []const u32, comptime dr: u64) type {
            return struct {
                pub const U = enum(u8) { p, n };
                pub const jac_pattern = [2]u64{ 0b10, 0b00 };
                pub const deriv_reads: u64 = dr;
                pub const ac_dyn_slots = slots[0..slots.len].*;
                pub fn acDyn(comptime F: type, _: *const void, _: *const void, _: *const [2]f64, _: SimState, _: F, _: *[slots.len]std.math.Complex(F)) void {}
            };
        }
    };
    // Slot 1 is (p, n): inside the pattern, its column a lane.
    try testing.expect(comptime (acDynError(Of.dev(&.{1}, 0b10)) == null));
    // Past n_u², unsorted, outside the pattern, a column with no lane.
    try testing.expect(comptime (acDynError(Of.dev(&.{4}, 0b10)) != null));
    try testing.expect(comptime (acDynError(Of.dev(&.{ 1, 1 }, 0b10)) != null));
    try testing.expect(comptime (acDynError(Of.dev(&.{0}, 0b11)) != null));
    try testing.expect(comptime (acDynError(Of.dev(&.{1}, 0b01)) != null));
    // The two decls come together.
    try testing.expect(comptime (acDynError(struct {
        pub const U = enum(u8) { p, n };
        pub const ac_dyn_slots = [_]u32{1};
    }) != null));
}

test "deriv_reads: the four rules each refuse their own mistake" {
    // (a) the mask is one u64.
    try testing.expect(comptime (derivReadsError(MockVsrc, 3) == null));
    try testing.expect(comptime (derivReadsError(MockVsrc, 65) != null));
    // (b) a limited unknown needs a live lane.
    const Lim = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
        pub const limit_writes: u64 = 0b10;
        pub fn limit() void {}
    };
    try testing.expect(comptime (derivReadsError(Lim, 2) != null));
    // A `limit` with no `limit_writes` writes ALL, so it needs every lane.
    const LimAll = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
        pub fn limit() void {}
    };
    try testing.expect(comptime (derivReadsError(LimAll, 2) != null));
    // No `limit`, no constraint: `limitWrites`' all-ones default is not a write.
    const NoLim = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0;
        pub const ddx_reads: u64 = 0;
    };
    try testing.expect(comptime (derivReadsError(NoLim, 2) == null));
    // (d) a ddx() column needs a live lane, and an undeclared `ddx_reads` is
    // ALL of them, so a device with a narrow mask must declare it.
    const Ddx = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
        pub const ddx_reads: u64 = 0b10;
    };
    try testing.expect(comptime (derivReadsError(Ddx, 2) != null));
    const DdxAll = struct {
        pub const U = enum(u8) { a, b };
        pub const deriv_reads: u64 = 0b01;
    };
    try testing.expect(comptime (derivReadsError(DdxAll, 2) != null));
    // (c) unsorted, duplicated, all-zero, and a column that has a lane.
    const U3 = MockVsrc.U;
    const cases = [_][]const JacConst(U3){
        &.{ .{ .row = .n, .col = .br, .g = -1, .c = 0 }, .{ .row = .p, .col = .br, .g = 1, .c = 0 } },
        &.{ .{ .row = .p, .col = .br, .g = 1, .c = 0 }, .{ .row = .p, .col = .br, .g = 1, .c = 0 } },
        &.{.{ .row = .p, .col = .br, .g = 0, .c = 0 }},
        &.{.{ .row = .p, .col = .br, .g = 1, .c = 0 }},
    };
    const masks = [_]u64{ 0, 0, 0, 0b100 };
    inline for (cases, masks) |t, mk| {
        const Bad = struct {
            pub const U = U3;
            pub const deriv_reads: u64 = mk;
            pub const ddx_reads: u64 = 0;
            pub const jac_const = t;
        };
        try testing.expect(comptime (derivReadsError(Bad, 3) != null));
    }
    // A guard must name a real Model field.
    const Guarded = struct {
        pub const U = U3;
        pub const Model = struct { br__retained: f64 = 1 };
        pub const deriv_reads: u64 = 0;
        pub const ddx_reads: u64 = 0;
        pub const jac_const = [_]JacConst(U3){.{ .row = .p, .col = .br, .g = 1, .c = 0, .when = .{ .flag = "br__retained", .collapse_open = true } }};
    };
    try testing.expect(comptime (derivReadsError(Guarded, 3) == null));
    const Misnamed = struct {
        pub const U = U3;
        pub const Model = struct { br__retained: f64 = 1 };
        pub const deriv_reads: u64 = 0;
        pub const ddx_reads: u64 = 0;
        pub const jac_const = [_]JacConst(U3){.{ .row = .p, .col = .br, .g = 1, .c = 0, .when = .{ .flag = "nope", .collapse_open = true } }};
    };
    try testing.expect(comptime (derivReadsError(Misnamed, 3) != null));
    // And it applies exactly when the flag is set and the host did not collapse.
    const e = Guarded.jac_const[0];
    var gmodel: Guarded.Model = .{};
    try testing.expect(jacConstApplies(Guarded, e, &gmodel, false));
    try testing.expect(!jacConstApplies(Guarded, e, &gmodel, true));
    gmodel.br__retained = 0;
    try testing.expect(!jacConstApplies(Guarded, e, &gmodel, false));
    // And the defaults: nothing declared is all lanes and no table.
    try testing.expectEqual(~@as(u64, 0), derivReads(MockR));
    try testing.expectEqual(@as(usize, 0), jacConst(MockR).len);
}

test "validateHost: a systf is the host's to bind, and only when there is one" {
    // MockR names no `$name`, so any host will do, including one that has
    // never heard of VPI. That is the common case and it must stay free.
    comptime validateHost(struct {}, MockR);

    // MockAll calls `$sampnhold`, so a host linking it must answer for it.
    const Sim = struct {
        pub const iteration_hooks = true;
        // MockAll also carries a §4.6.4.3 card-valued noise table, so a host
        // linking it must say it reads `noiseTablePoints` rather than the
        // declared defaults in `noise_tables`.
        pub const noise_table_points = true;
        // ...and MockAll has a shape parameter, so the host calls `checkShape`.
        pub const shape_check = true;
        // ...and a `setup`, so the host fills `Instance.su` before `eval`.
        pub const calls_setup = true;
        // ...and a frequency-dependent slot, so the host adds `acDyn`.
        pub const calls_ac_dyn = true;
        var app: SystfHost = .{ .ctx = undefined, .call = zero };
        fn zero(_: *anyopaque, _: usize, _: []const f64, partials: []f64) f64 {
            @memset(partials, 0);
            return 0;
        }
        pub fn systf(_: *const MockAll.Model) ?*const SystfHost {
            return &app;
        }
    };
    comptime validateHost(Sim, MockAll);

    // The device rebuilds a family value as `S.con(v)` plus
    // `p_j * (arg_j - arg_j.val())` per argument: zero in value, p_j·d(arg_j)
    // in the lanes. On the plain-f64 side every such term must vanish exactly.
    var partials: [1]f64 = .{7.5};
    const v = Sim.app.call(Sim.app.ctx, 0, &.{0.25}, &partials);
    try std.testing.expectEqual(@as(f64, 0), v);
    try std.testing.expectEqual(@as(f64, 0), partials[0]); // written, not left at 7.5
}

/// §6.2's optional port list, in device form: no terminals, one internal
/// unknown, as tests/fixtures/ch06_hierarchy/module_definition.va lowers
/// (`module m; electrical p; analog I(p) <+ V(p); endmodule`).
const MockNoPorts = struct {
    pub const U = enum(u8) { p };
    pub const num_ports: usize = 0;
    const n_u = nU(@This());

    pub const Model = struct { g: f64 = 1.0 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, _: *const Instance, _: SimState) Rows(@This(), S) {
        return rows(@This(), S, .{probes(@This(), S, x)[0].scale(model.g)});
    }
};

test "validate: a module with no port list (§6.2 optional, A.1.2)" {
    comptime validate(MockNoPorts);
    try testing.expectEqual(@as(usize, 0), MockNoPorts.num_ports);
}

test "validate: switch (state in Instance + attempt + limit)" {
    comptime validate(MockSw);
}

test "validate: tline (ac stamp + sim-state fields + metadata)" {
    comptime validate(MockTline);
}

test "updateState mutates Instance" {
    var inst: MockSw.Instance = .{};
    var s: MockSw.State = .{};
    const m: MockSw.Model = .{};
    _ = MockSw.updateState(void, &m, &inst, .{ 1.0, 0.0 }, &s, .{});
    try testing.expect(inst.closed);
    try testing.expectEqual(@as(u32, 1), s.flips);
}

test "limit reports its own convergence verdict" {
    const m: MockSw.Model = .{};
    const i: MockSw.Instance = .{};
    const r = MockSw.limit(void, &m, &i, .{ 1.0, 0.0 }, .{ 0.0, 0.0 }, .{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(f64, 1.0), r.x[0]);
}

test "nU" {
    try testing.expectEqual(@as(comptime_int, 2), comptime nU(MockR));
}

test "§4.6.4.3 noise_table interpolates linearly BETWEEN the pairs" {
    // Every `want` below is the clause's own arithmetic done by hand, not
    // whatever the evaluator returns: the segment [100, 200] rises 4 -> 10, so
    // a quarter of the way along it is 4 + 6/4 and half of it is 4 + 3.
    const t: NoiseTable = .{ .interp = .linear, .points = &.{ .{ 100, 4.0 }, .{ 200, 10.0 } } };
    try testing.expectApproxEqAbs(@as(f64, 5.5), noiseTableAt(t, 125), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 7.0), noiseTableAt(t, 150), 1e-15);
    // The knots themselves, which no interpolation may move.
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(t, 100));
    try testing.expectEqual(@as(f64, 10.0), noiseTableAt(t, 200));
    // "for frequencies lower than the lowest frequency … returns the power
    // specified for the lowest frequency", and the same for the highest: a
    // clamp, never an extrapolated 1.0 below or 16.0 above.
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(t, 50));
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(t, 1e-9));
    try testing.expectEqual(@as(f64, 10.0), noiseTableAt(t, 1000));

    // Three points: the SECOND segment has to be the one that answers f = 3.
    const u: NoiseTable = .{ .interp = .linear, .points = &.{ .{ 1, 1.0 }, .{ 2, 4.0 }, .{ 4, 8.0 } } };
    try testing.expectApproxEqAbs(@as(f64, 2.5), noiseTableAt(u, 1.5), 1e-15);
    try testing.expectEqual(@as(f64, 4.0), noiseTableAt(u, 2));
    try testing.expectApproxEqAbs(@as(f64, 6.0), noiseTableAt(u, 3), 1e-15);

    // One pair is a legal table and a constant PSD: both clamps answer it.
    const one: NoiseTable = .{ .interp = .linear, .points = &.{.{ 5, 3.0 }} };
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 1));
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 5));
    try testing.expectEqual(@as(f64, 3.0), noiseTableAt(one, 1e9));
}

test "§4.6.4.4 noise_table_log is a straight line on a log-log plot" {
    // §4.6.4.4's own worked example: `noise_table_log('{1,1, 1e6,1e-6})`.
    // log10(p) falls 0 -> -6 while log10(f) rises 0 -> 6, so the line is
    // p = 1/f and every interior decade is exactly a decade down.
    const t: NoiseTable = .{ .interp = .log, .points = &.{ .{ 1, 1.0 }, .{ 1e6, 1e-6 } } };
    for ([_]f64{ 1e1, 1e2, 1e3, 1e4, 1e5 }) |f|
        try testing.expectApproxEqRel(1.0 / f, noiseTableAt(t, f), 1e-12);

    // Figure 4-14 is this difference: on the SAME two points the linear form
    // bows, and at 1 kHz it reads 1 + (1e-6 - 1)*(999/999999), nowhere near
    // the 1e-3 the log form gives.
    const lin: NoiseTable = .{ .interp = .linear, .points = t.points };
    const want = 1.0 + (1e-6 - 1.0) * (1e3 - 1.0) / (1e6 - 1.0);
    try testing.expectApproxEqRel(want, noiseTableAt(lin, 1e3), 1e-12);
    try testing.expect(noiseTableAt(lin, 1e3) > 0.9);

    // A slope that is not -1, and a knot that is not a decade boundary: the
    // line through (10, 1e-2) and (1000, 1e-6) is p = f^-2.
    const s: NoiseTable = .{ .interp = .log, .points = &.{ .{ 10, 1e-2 }, .{ 1000, 1e-6 } } };
    try testing.expectApproxEqRel(@as(f64, 1e-4), noiseTableAt(s, 100), 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.0 / (31.62277660168379 * 31.62277660168379)), noiseTableAt(s, 31.62277660168379), 1e-12);
    // Knots and clamps behave as in the linear mode.
    try testing.expectEqual(@as(f64, 1e-2), noiseTableAt(s, 10));
    try testing.expectEqual(@as(f64, 1e-6), noiseTableAt(s, 1000));
    try testing.expectEqual(@as(f64, 1e-2), noiseTableAt(s, 1));
    try testing.expectEqual(@as(f64, 1e-6), noiseTableAt(s, 1e9));

    // A flat log table is flat, not NaN: log(p2) - log(p1) = 0 is a legal line.
    const flat: NoiseTable = .{ .interp = .log, .points = &.{ .{ 1, 2e-9 }, .{ 100, 2e-9 } } };
    try testing.expectApproxEqRel(@as(f64, 2e-9), noiseTableAt(flat, 7), 1e-12);
}

test "RefFamily meets the numerics table: dense and sparse, f64 and f32 lanes" {
    const lane = [_]u8{ 0, 1 };
    try expectFamily(RefFamily(f64, &lane, .{ .dense = false }));
    try expectFamily(RefFamily(f64, &lane, .{ .dense = true }));
    try expectFamily(RefFamily(f32, &lane, .{ .dense = false }));
    try expectFamily(RefFamily(f32, &lane, .{ .dense = true }));
    // Lane-free, the value-only family a host may run its value paths on,
    // is still a family.
    checkFamily(RefFamily(f64, &.{ no_lane, no_lane }, .{ .dense = true }));
}

test "RefFamily sparse: Of(m) carries exactly m's lanes, joins on binary ops" {
    const S = RefFamily(f64, &.{ 0, 1, 2, 3 }, .{ .dense = false });
    try testing.expectEqual(@as(usize, 3 * 8), @sizeOf(S.Of(0b0101))); // the value and two lanes
    const a = S.probe(0, 2.0);
    const c = S.probe(2, 3.0);
    const p = a.mul(c);
    try testing.expect(@TypeOf(p) == S.Of(0b0101));
    try testing.expectEqual(@as(f64, 3.0), p.ddxAt(0));
    try testing.expectEqual(@as(f64, 2.0), p.ddxAt(2));
    try testing.expectEqual(@as(f64, 0.0), p.ddxAt(1));
    // An `Of(0)` divisor contributes no lanes: d(a/k) = da/k.
    const q = c.div(S.con(4.0));
    try testing.expect(@TypeOf(q) == S.Of(0b0100));
    try testing.expectEqual(@as(f64, 0.25), q.ddxAt(2));
    // `sel` widens both arms to the join; `to` pads with +0.
    const s = S.sel(S.con(0.0), a, c);
    try testing.expect(@TypeOf(s) == S.Of(0b0101));
    try testing.expectEqual(@as(f64, 1.0), s.ddxAt(2));
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(s.ddxAt(0))));
}

test "a family's rows carry the pattern's lanes" {
    const S = RefFamily(f64, &.{ 0, 1 }, .{ .dense = false });
    const r = MockAll.eval(S, &.{ 2.0, 1.0 }, &.{ .g = 0.5 }, &.{}, .{});
    try testing.expect(@TypeOf(r[0]) == S.Of(rowMask(MockAll, 0)));
    try testing.expectEqual(@as(f64, 0.5), r[0].val());
    try testing.expectEqual(@as(f64, -0.5), r[1].ddxAt(0));
    try testing.expectEqual(@as(f64, 0.5), r[1].ddxAt(1));
    try testing.expectEqual(@as(usize, 1), laneMasks(MockAll).len);
    // `q_site_pattern` narrows each charge to its own unknown.
    const qs = MockAll.q(S, &.{ 2.0, 1.0 }, &.{}, &.{}, .{});
    try testing.expect(@TypeOf(qs[1]) == S.Of(0b10));
    const qr = qRows(MockAll, S, qs);
    try testing.expectEqual(@as(f64, -1e-12), qr[1].ddxAt(1));
}

test "RefFamily dense: one type, lanes where `lane` puts them" {
    const S = RefFamily(f64, &.{ 1, no_lane, 0 }, .{ .dense = true, .collapse_applied = true });
    try testing.expect(S.Of(0b1) == S.Of(0b100));
    try testing.expect(S.collapse_applied);
    const x = S.probe(0, 3.0).mul(S.probe(2, 5.0)).add(S.probe(1, 7.0));
    try testing.expectEqual(@as(f64, 22.0), x.val());
    try testing.expectEqual(@as(f64, 5.0), x.ddxAt(0));
    try testing.expectEqual(@as(f64, 0.0), x.ddxAt(1)); // not carried
    try testing.expectEqual(@as(f64, 3.0), x.ddxAt(2));
    try testing.expectEqual([2]f64{ 3.0, 5.0 }, x.d);
}
