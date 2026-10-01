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

/// The pieces `vera --emit-so` builds a large device in (`orchestrator.Part`):
/// one compiler process and object each, in parallel, linked into one
/// library. A `dyn` host may declare
/// `pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: DevicePart) void`
/// beside `exportDevice`; the split build then calls it once per part, each
/// in its own object, so it must export every symbol from exactly one part
/// (a call into another part goes through `@extern`). `.setup`: `setup`,
/// `derive`, `initState`, `stateCtl`, `pendingBreakpoint`; `.state`:
/// `updateState`; `.eval`: `eval`, `evalQ`, `q`. A host without it gets
/// `exportDevice` in the `.setup` object, and the others export nothing.
/// Additive: no `abi_version` change.
pub const DevicePart = enum { setup, state, eval };

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

    /// exp, log and pow are VerA's own, one implementation on every target
    /// (host, NVPTX, AMDGCN): faithful (< 1 ulp; docs/IMPLEMENTATION.md, "Host
    /// math"), fma-free so every target rounds alike (`exact_everywhere`).
    /// `exp`/`log` take `f64` or `@Vector(n, f64)`; `powV` is pow's vector
    /// form.
    pub inline fn exp(x: anytype) @TypeOf(x) {
        return hexp(x);
    }
    pub inline fn log(x: anytype) @TypeOf(x) {
        return hlog(x);
    }
    pub inline fn pow(x: f64, y: f64) f64 {
        return armPow(x, y);
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
        const r = 1 - 2.0 / (armExp(2 * ax) + 1);
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
        const e = armExp(ax);
        const r = 0.5 * e - 0.5 / e;
        return if (x < 0) -r else r;
    }
    pub inline fn cosh(x: f64) f64 {
        if (comptime !dev) return std.math.cosh(x);
        const e = armExp(@abs(x));
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

    // ---- host exp and log for a scalar or a vector of operating points ----
    //
    // `hexp`/`hlog` take `f64` or `@Vector(n, f64)` (a batch family's value
    // type). A vector whose lanes are all ordinary inputs runs ARM's
    // arithmetic below on the whole vector (one table gather per lane); a
    // vector with any special lane (zero, subnormal, huge, inf, NaN, negative
    // log argument) takes the scalar routine lane by lane. The vector
    // arithmetic is the scalar's, operation for operation, so a lane's
    // result is the scalar call's bit for bit.

    fn UOf(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .vector => |v| @Vector(v.len, u64),
            else => u64,
        };
    }
    fn IOf(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .vector => |v| @Vector(v.len, i64),
            else => i64,
        };
    }
    inline fn sp(comptime T: type, c: anytype) T {
        return switch (@typeInfo(T)) {
            .vector => @splat(c),
            else => c,
        };
    }
    inline fn shl(v: anytype, comptime n: u6) @TypeOf(v) {
        return switch (@typeInfo(@TypeOf(v))) {
            .vector => |t| v << @as(@Vector(t.len, u6), @splat(n)),
            else => v << n,
        };
    }
    inline fn shrU(v: anytype, comptime n: u6) @TypeOf(v) {
        return switch (@typeInfo(@TypeOf(v))) {
            .vector => |t| v >> @as(@Vector(t.len, u6), @splat(n)),
            else => v >> n,
        };
    }
    /// `tab[idx]` lane by lane: a gather.
    inline fn gather(comptime E: type, tab: []const E, idx: anytype) switch (@typeInfo(@TypeOf(idx))) {
        .vector => |v| @Vector(v.len, E),
        else => E,
    } {
        switch (@typeInfo(@TypeOf(idx))) {
            .vector => |v| {
                var out: @Vector(v.len, E) = undefined;
                inline for (0..v.len) |l| out[l] = tab[@intCast(idx[l])];
                return out;
            },
            else => return tab[@intCast(idx)],
        }
    }

    /// `exp_inline`'s ordinary-input arithmetic: scale bits, the reduction's
    /// k and tmp, exp(x + xtail) ~= scale * (1 + tmp).
    inline fn expMain(comptime T: type, x: T, xtail: T, sbias: u64) struct { tmp: T, sbits: UOf(T), ki: UOf(T) } {
        const U = UOf(T);
        const z = sp(T, exp_invln2n) * x;
        var kd = z + sp(T, exp_shift);
        const ki: U = @bitCast(kd);
        kd -= sp(T, exp_shift);
        var r = x + kd * sp(T, exp_negln2hin) + kd * sp(T, exp_negln2lon);
        r += xtail;
        const idx = shl(ki % sp(U, exp_n), 1);
        const top = shl(ki +% sp(U, sbias), 52 - 7);
        const tail: T = @bitCast(gather(u64, &exp_tab, idx));
        const sbits = gather(u64, &exp_tab, idx + sp(U, 1)) +% top;
        const r2 = r * r;
        const tmp = tail + r + r2 * (sp(T, exp_c2) + r * sp(T, exp_c3)) + r2 * r2 * (sp(T, exp_c4) + r * sp(T, exp_c5));
        return .{ .tmp = tmp, .sbits = sbits, .ki = ki };
    }

    /// `log_inline`: log(x) = y + tail for x's (normalized) bits.
    inline fn powLogG(comptime T: type, ix: UOf(T)) struct { y: T, tail: T } {
        const U = UOf(T);
        const I = IOf(T);
        const tmp = ix -% sp(U, pow_off);
        const i = shrU(tmp, 52 - 7) % sp(U, 128);
        const k = @as(I, @bitCast(tmp)) >> switch (@typeInfo(T)) {
            .vector => |v| @as(@Vector(v.len, u6), @splat(52)),
            else => @as(u6, 52),
        };
        const iz = ix -% (tmp & sp(U, @as(u64, 0xfff) << 52));
        const z: T = @bitCast(iz);
        const kd: T = @floatFromInt(k);
        const invc = gather(f64, &pow_log_invc, i);
        const logc = gather(f64, &pow_log_logc, i);
        const logctail = gather(f64, &pow_log_logctail, i);
        // No fma (`exact_everywhere`): split z so rhi, rlo and rhi*rhi are
        // exact and |rlo| <= |r|.
        const zhi: T = @bitCast((iz +% sp(U, 1 << 31)) & sp(U, ~@as(u64, 0) << 32));
        const zlo = z - zhi;
        const rhi = zhi * invc - sp(T, 1.0);
        const rlo = zlo * invc;
        const r = rhi + rlo;
        const t1 = kd * sp(T, pow_ln2hi) + logc;
        const t2 = t1 + r;
        const lo1 = kd * sp(T, pow_ln2lo) + logctail;
        const lo2 = t1 - t2 + r;
        const ar = sp(T, pow_a[0]) * r;
        const ar2 = r * ar;
        const ar3 = r * ar2;
        const arhi = sp(T, pow_a[0]) * rhi;
        const arhi2 = rhi * arhi;
        const hi = t2 + arhi2;
        const lo3 = rlo * (ar + arhi);
        const lo4 = t2 - hi + arhi2;
        const p = ar3 * (sp(T, pow_a[1]) + r * sp(T, pow_a[2]) + ar2 * (sp(T, pow_a[3]) + r * sp(T, pow_a[4]) + ar2 * (sp(T, pow_a[5]) + r * sp(T, pow_a[6]))));
        const lo = lo1 + lo2 + lo3 + lo4 + p;
        const y = hi + lo;
        return .{ .y = y, .tail = hi - y + lo };
    }

    /// exp(x) for `f64` or `@Vector(n, f64)`; the contract is `armExp`'s.
    pub fn hexp(x: anytype) @TypeOf(x) {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .vector => |v| {
                const U = UOf(T);
                const abstop = shrU(@as(U, @bitCast(x)), 52) & sp(U, 0x7ff);
                const ordinary = abstop -% sp(U, top12(0x1p-54)) < sp(U, top12(512.0) - top12(0x1p-54));
                if (!@reduce(.And, ordinary)) {
                    @branchHint(.unlikely);
                    var out: T = undefined;
                    inline for (0..v.len) |l| out[l] = armExp(x[l]);
                    return out;
                }
                const m = expMain(T, x, sp(T, 0.0), 0);
                const scale: T = @bitCast(m.sbits);
                // `expSmall`'s lanes: the scalar call's branch, as a select.
                const small = abstop < sp(U, top12(0x1p-28));
                return @select(f64, small, expSmall(x), scale + scale * m.tmp);
            },
            else => return armExp(x),
        }
    }

    /// log.c's band around 1, where it switches to a direct polynomial in
    /// x - 1: bits in [LO, HI).
    const log_lo: u64 = @bitCast(@as(f64, 1.0 - 0x1p-4));
    const log_hi: u64 = @bitCast(@as(f64, 1.0 + 0x1.09p-4));

    /// log.c's table path for an ordinary x (positive, normal, finite,
    /// outside the band around 1): k ln2 + log(c) + poly(z/c - 1).
    inline fn logMain(comptime T: type, ix: UOf(T)) T {
        const U = UOf(T);
        const I = IOf(T);
        const tmp = ix -% sp(U, 0x3fe6000000000000);
        const i = shrU(tmp, 52 - 7) % sp(U, 128);
        const k = @as(I, @bitCast(tmp)) >> switch (@typeInfo(T)) {
            .vector => |v| @as(@Vector(v.len, u6), @splat(52)),
            else => @as(u6, 52),
        };
        const iz = ix -% (tmp & sp(U, @as(u64, 0xfff) << 52));
        const z: T = @bitCast(iz);
        const invc = gather(f64, &log_invc, i);
        const logc = gather(f64, &log_logc, i);
        const r = (z - gather(f64, &log_chi, i) - gather(f64, &log_clo, i)) * invc;
        const kd: T = @floatFromInt(k);
        const w = kd * sp(T, 0x1.62e42fefa3800p-1) + logc;
        const hi = w + r;
        const lo = w - hi + r + kd * sp(T, 0x1.ef35793c76730p-45);
        const r2 = r * r;
        return lo + r2 * sp(T, log_poly[0]) + r * r2 * (sp(T, log_poly[1]) + r * sp(T, log_poly[2]) + r2 * (sp(T, log_poly[3]) + r * sp(T, log_poly[4]))) + hi;
    }

    /// log(x) for `f64` or `@Vector(n, f64)`; the contract is `armLog`'s.
    pub fn hlog(x: anytype) @TypeOf(x) {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .vector => |v| {
                const U = UOf(T);
                const ix: U = @bitCast(x);
                // Positive, normal and finite (top12 in [0x001, 0x7fe]), and
                // outside the band around 1.
                const normal = shrU(ix, 52) -% sp(U, 0x001) < sp(U, 0x7fe);
                const off_band = (ix -% sp(U, log_lo)) >= sp(U, log_hi - log_lo);
                if (!@reduce(.And, normal) or !@reduce(.And, off_band)) {
                    @branchHint(.unlikely);
                    var out: T = undefined;
                    inline for (0..v.len) |l| out[l] = armLog(x[l]);
                    return out;
                }
                return logMain(T, ix);
            },
            else => return armLog(x),
        }
    }

    /// log(x): ARM's log.c, max error 0.52 ulp (measured 0.515 in the band
    /// around 1, 0.500 elsewhere); log(+-0) = -inf, log(x < 0) = NaN,
    /// log(+inf) = +inf, log(1) = +0, NaN propagates, subnormals normalized.
    pub fn armLog(x: f64) f64 {
        var ix = asU(x);
        if (ix -% log_lo < log_hi - log_lo) {
            @branchHint(.unlikely);
            if (ix == asU(1.0)) return 0;
            const r = x - 1.0;
            const r2 = r * r;
            const r3 = r * r2;
            const p = log_poly1;
            const y = r3 * (p[1] + r * p[2] + r2 * p[3] + r3 * (p[4] + r * p[5] + r2 * p[6] + r3 * (p[7] + r * p[8] + r2 * p[9] + r3 * p[10])));
            var w = r * 0x1p27;
            const rhi = r + w - w;
            const rlo = r - rhi;
            w = rhi * rhi * p[0];
            const hi = r + w;
            const lo = r - hi + w + p[0] * rlo * (rhi + r);
            return y + lo + hi;
        }
        const top = ix >> 48;
        if (top -% 0x0010 >= 0x7ff0 - 0x0010) {
            @branchHint(.unlikely);
            if (ix << 1 == 0) return -std.math.inf(f64); // +-0
            if (ix == asU(std.math.inf(f64))) return x;
            if (top & 0x8000 != 0 or top & 0x7ff0 == 0x7ff0) return std.math.nan(f64); // < 0, NaN
            // Subnormal: normalize so the exponent goes negative.
            ix = asU(x * 0x1p52) -% (52 << 52);
        }
        return logMain(f64, ix);
    }

    // ARM log.c (musl src/math/log.c, log_data.c; Copyright (c) 2018, Arm
    // Limited, MIT), its fma-free variant (`exact_everywhere`), as Zig's
    // compiler_rt/log.zig carries it.
    const log_poly = [5]f64{ -0x1.0000000000001p-1, 0x1.555555551305bp-2, -0x1.fffffffeb459p-3, 0x1.999b324f10111p-3, -0x1.55575e506c89fp-3 };
    const log_poly1 = [11]f64{ -0x1p-1, 0x1.5555555555577p-2, -0x1.ffffffffffdcbp-3, 0x1.999999995dd0cp-3, -0x1.55555556745a7p-3, 0x1.24924a344de3p-3, -0x1.fffffa4423d65p-4, 0x1.c7184282ad6cap-4, -0x1.999eb43b068ffp-4, 0x1.78182f7afd085p-4, -0x1.5521375d145cdp-4 };
    const log_invc = [128]f64{
        0x1.734f0c3e0de9fp+0, 0x1.713786a2ce91fp+0, 0x1.6f26008fab5a0p+0, 0x1.6d1a61f138c7dp+0,
        0x1.6b1490bc5b4d1p+0, 0x1.69147332f0cbap+0, 0x1.6719f18224223p+0, 0x1.6524f99a51ed9p+0,
        0x1.63356aa8f24c4p+0, 0x1.614b36b9ddc14p+0, 0x1.5f66452c65c4cp+0, 0x1.5d867b5912c4fp+0,
        0x1.5babccb5b90dep+0, 0x1.59d61f2d91a78p+0, 0x1.5805612465687p+0, 0x1.56397cee76bd3p+0,
        0x1.54725e2a77f93p+0, 0x1.52aff42064583p+0, 0x1.50f22dbb2bddfp+0, 0x1.4f38f4734ded7p+0,
        0x1.4d843cfde2840p+0, 0x1.4bd3ec078a3c8p+0, 0x1.4a27fc3e0258ap+0, 0x1.4880524d48434p+0,
        0x1.46dce1b192d0bp+0, 0x1.453d9d3391854p+0, 0x1.43a2744b4845ap+0, 0x1.420b54115f8fbp+0,
        0x1.40782da3ef4b1p+0, 0x1.3ee8f5d57fe8fp+0, 0x1.3d5d9a00b4ce9p+0, 0x1.3bd60c010c12bp+0,
        0x1.3a5242b75dab8p+0, 0x1.38d22cd9fd002p+0, 0x1.3755bc5847a1cp+0, 0x1.35dce49ad36e2p+0,
        0x1.34679984dd440p+0, 0x1.32f5cceffcb24p+0, 0x1.3187775a10d49p+0, 0x1.301c8373e3990p+0,
        0x1.2eb4ebb95f841p+0, 0x1.2d50a0219a9d1p+0, 0x1.2bef9a8b7fd2ap+0, 0x1.2a91c7a0c1babp+0,
        0x1.293726014b530p+0, 0x1.27dfa5757a1f5p+0, 0x1.268b39b1d3bbfp+0, 0x1.2539d838ff5bdp+0,
        0x1.23eb7aac9083bp+0, 0x1.22a012ba940b6p+0, 0x1.2157996cc4132p+0, 0x1.201201dd2fc9bp+0,
        0x1.1ecf4494d480bp+0, 0x1.1d8f5528f6569p+0, 0x1.1c52311577e7cp+0, 0x1.1b17c74cb26e9p+0,
        0x1.19e010c2c1ab6p+0, 0x1.18ab07bb670bdp+0, 0x1.1778a25efbcb6p+0, 0x1.1648d354c31dap+0,
        0x1.151b990275fddp+0, 0x1.13f0ea432d24cp+0, 0x1.12c8b7210f9dap+0, 0x1.11a3028ecb531p+0,
        0x1.107fbda8434afp+0, 0x1.0f5ee0f4e6bb3p+0, 0x1.0e4065d2a9fcep+0, 0x1.0d244632ca521p+0,
        0x1.0c0a77ce2981ap+0, 0x1.0af2f83c636d1p+0, 0x1.09ddb98a01339p+0, 0x1.08cabaf52e7dfp+0,
        0x1.07b9f2f4e28fbp+0, 0x1.06ab58c358f19p+0, 0x1.059eea5ecf92cp+0, 0x1.04949cdd12c90p+0,
        0x1.038c6c6f0ada9p+0, 0x1.02865137932a9p+0, 0x1.0182427ea7348p+0, 0x1.008040614b195p+0,
        0x1.fe01ff726fa1ap-1, 0x1.fa11cc261ea74p-1, 0x1.f6310b081992ep-1, 0x1.f25f63ceeadcdp-1,
        0x1.ee9c8039113e7p-1, 0x1.eae8078cbb1abp-1, 0x1.e741aa29d0c9bp-1, 0x1.e3a91830a99b5p-1,
        0x1.e01e009609a56p-1, 0x1.dca01e577bb98p-1, 0x1.d92f20b7c9103p-1, 0x1.d5cac66fb5ccep-1,
        0x1.d272caa5ede9dp-1, 0x1.cf26e3e6b2ccdp-1, 0x1.cbe6da2a77902p-1, 0x1.c8b266d37086dp-1,
        0x1.c5894bd5d5804p-1, 0x1.c26b533bb9f8cp-1, 0x1.bf583eeece73fp-1, 0x1.bc4fd75db96c1p-1,
        0x1.b951e0c864a28p-1, 0x1.b65e2c5ef3e2cp-1, 0x1.b374867c9888bp-1, 0x1.b094b211d304ap-1,
        0x1.adbe885f2ef7ep-1, 0x1.aaf1d31603da2p-1, 0x1.a82e63fd358a7p-1, 0x1.a5740ef09738bp-1,
        0x1.a2c2a90ab4b27p-1, 0x1.a01a01393f2d1p-1, 0x1.9d79f24db3c1bp-1, 0x1.9ae2505c7b190p-1,
        0x1.9852ef297ce2fp-1, 0x1.95cbaeea44b75p-1, 0x1.934c69de74838p-1, 0x1.90d4f2f6752e6p-1,
        0x1.8e6528effd79dp-1, 0x1.8bfce9fcc007cp-1, 0x1.899c0dabec30ep-1, 0x1.87427aa2317fbp-1,
        0x1.84f00acb39a08p-1, 0x1.82a49e8653e55p-1, 0x1.8060195f40260p-1, 0x1.7e22563e0a329p-1,
        0x1.7beb377dcb5adp-1, 0x1.79baa679725c2p-1, 0x1.77907f2170657p-1, 0x1.756cadbd6130cp-1,
    };
    const log_logc = [128]f64{
        -0x1.7cc7f79e69000p-2, -0x1.76feec20d0000p-2, -0x1.713e31351e000p-2, -0x1.6b85b38287800p-2,
        -0x1.65d5590807800p-2, -0x1.602d076180000p-2, -0x1.5a8ca86909000p-2, -0x1.54f4356035000p-2,
        -0x1.4f637c36b4000p-2, -0x1.49da7fda85000p-2, -0x1.445923989a800p-2, -0x1.3edf439b0b800p-2,
        -0x1.396ce448f7000p-2, -0x1.3401e17bda000p-2, -0x1.2e9e2ef468000p-2, -0x1.2941b3830e000p-2,
        -0x1.23ec58cda8800p-2, -0x1.1e9e129279000p-2, -0x1.1956d2b48f800p-2, -0x1.141679ab9f800p-2,
        -0x1.0edd094ef9800p-2, -0x1.09aa518db1000p-2, -0x1.047e65263b800p-2, -0x1.feb224586f000p-3,
        -0x1.f474a7517b000p-3, -0x1.ea4443d103000p-3, -0x1.e020d44e9b000p-3, -0x1.d60a22977f000p-3,
        -0x1.cc00104959000p-3, -0x1.c202956891000p-3, -0x1.b81178d811000p-3, -0x1.ae2c9ccd3d000p-3,
        -0x1.a45402e129000p-3, -0x1.9a877681df000p-3, -0x1.90c6d69483000p-3, -0x1.87120a645c000p-3,
        -0x1.7d68fb4143000p-3, -0x1.73cb83c627000p-3, -0x1.6a39a9b376000p-3, -0x1.60b3154b7a000p-3,
        -0x1.5737d76243000p-3, -0x1.4dc7b8fc23000p-3, -0x1.4462c51d20000p-3, -0x1.3b08abc830000p-3,
        -0x1.31b996b490000p-3, -0x1.2875490a44000p-3, -0x1.1f3b9f879a000p-3, -0x1.160c8252ca000p-3,
        -0x1.0ce7f57f72000p-3, -0x1.03cdc49fea000p-3, -0x1.f57bdbc4b8000p-4, -0x1.e370896404000p-4,
        -0x1.d17983ef94000p-4, -0x1.bf9674ed8a000p-4, -0x1.adc79202f6000p-4, -0x1.9c0c3e7288000p-4,
        -0x1.8a646b372c000p-4, -0x1.78d01b3ac0000p-4, -0x1.674f145380000p-4, -0x1.55e0e6d878000p-4,
        -0x1.4485cdea1e000p-4, -0x1.333d94d6aa000p-4, -0x1.22079f8c56000p-4, -0x1.10e4698622000p-4,
        -0x1.ffa6c6ad20000p-5, -0x1.dda8d4a774000p-5, -0x1.bbcece4850000p-5, -0x1.9a1894012c000p-5,
        -0x1.788583302c000p-5, -0x1.5715e67d68000p-5, -0x1.35c8a49658000p-5, -0x1.149e364154000p-5,
        -0x1.e72c082eb8000p-6, -0x1.a55f152528000p-6, -0x1.63d62cf818000p-6, -0x1.228fb8caa0000p-6,
        -0x1.c317b20f90000p-7, -0x1.419355daa0000p-7, -0x1.81203c2ec0000p-8, -0x1.0040979240000p-9,
        0x1.feff384900000p-9,  0x1.7dc41353d0000p-7,  0x1.3cea3c4c28000p-6,  0x1.b9fc114890000p-6,
        0x1.1b0d8ce110000p-5,  0x1.58a5bd001c000p-5,  0x1.95c8340d88000p-5,  0x1.d276aef578000p-5,
        0x1.07598e598c000p-4,  0x1.253f5e30d2000p-4,  0x1.42edd8b380000p-4,  0x1.606598757c000p-4,
        0x1.7da76356a0000p-4,  0x1.9ab434e1c6000p-4,  0x1.b78c7bb0d6000p-4,  0x1.d431332e72000p-4,
        0x1.f0a3171de6000p-4,  0x1.067152b914000p-3,  0x1.147858292b000p-3,  0x1.2266ecdca3000p-3,
        0x1.303d7a6c55000p-3,  0x1.3dfc33c331000p-3,  0x1.4ba366b7a8000p-3,  0x1.5933928d1f000p-3,
        0x1.66acd2418f000p-3,  0x1.740f8ec669000p-3,  0x1.815c0f51af000p-3,  0x1.8e92954f68000p-3,
        0x1.9bb3602f84000p-3,  0x1.a8bed1c2c0000p-3,  0x1.b5b515c01d000p-3,  0x1.c2967ccbcc000p-3,
        0x1.cf635d5486000p-3,  0x1.dc1bd3446c000p-3,  0x1.e8c01b8cfe000p-3,  0x1.f5509c0179000p-3,
        0x1.00e6c121fb800p-2,  0x1.071b80e93d000p-2,  0x1.0d46b9e867000p-2,  0x1.13687334bd000p-2,
        0x1.1980d67234800p-2,  0x1.1f8ffe0cc8000p-2,  0x1.2595fd7636800p-2,  0x1.2b9300914a800p-2,
        0x1.3187210436000p-2,  0x1.377266dec1800p-2,  0x1.3d54ffbaf3000p-2,  0x1.432eee32fe000p-2,
    };
    const log_chi = [128]f64{
        0x1.61000014fb66bp-1, 0x1.63000034db495p-1, 0x1.650000d94d478p-1, 0x1.67000074e6fadp-1,
        0x1.68ffffedf0faep-1, 0x1.6b0000763c5bcp-1, 0x1.6d0001e5cc1f6p-1, 0x1.6efffeb05f63ep-1,
        0x1.710000e86978p-1,  0x1.72ffffc67e912p-1, 0x1.74fffdf81116ap-1, 0x1.770000f679c9p-1,
        0x1.78ffffa7ec835p-1, 0x1.7affffe20c2e6p-1, 0x1.7cfffed3fc9p-1,   0x1.7efffe9261a76p-1,
        0x1.81000049ca3e8p-1, 0x1.8300017932c8fp-1, 0x1.850000633739cp-1, 0x1.87000204289c6p-1,
        0x1.88fffebf57904p-1, 0x1.8b00022bc04dfp-1, 0x1.8cfffe50c1b8ap-1, 0x1.8effffc918e43p-1,
        0x1.910001efa5fc7p-1, 0x1.9300013467bb9p-1, 0x1.94fffe6ee076fp-1, 0x1.96fffde3c12d1p-1,
        0x1.98ffff4458a0dp-1, 0x1.9afffdd982e3ep-1, 0x1.9cfffed49fb66p-1, 0x1.9f00020f19c51p-1,
        0x1.a10001145b006p-1, 0x1.a300007bbf6fap-1, 0x1.a500010971d79p-1, 0x1.a70001df52e48p-1,
        0x1.a90001c593352p-1, 0x1.ab0002a4f3e4bp-1, 0x1.acfffd7ae1ed1p-1, 0x1.aefffee510478p-1,
        0x1.b0fffdb650d5bp-1, 0x1.b2ffffeaaca57p-1, 0x1.b4fffd995badcp-1, 0x1.b7000249e659cp-1,
        0x1.b8ffff987164p-1,  0x1.bafffd204cb4fp-1, 0x1.bcfffd2415c45p-1, 0x1.beffff86309dfp-1,
        0x1.c0fffe1b57653p-1, 0x1.c2ffff1fa57e3p-1, 0x1.c4fffdcbfe424p-1, 0x1.c6fffed54b9f7p-1,
        0x1.c8fffeb998fd5p-1, 0x1.cb0002125219ap-1, 0x1.ccfffdd94469cp-1, 0x1.cefffeafdc476p-1,
        0x1.d1000169af82bp-1, 0x1.d30000d0ff71dp-1, 0x1.d4fffea790fc4p-1, 0x1.d70002edc87e5p-1,
        0x1.d900021dc82aap-1, 0x1.dafffd86b0283p-1, 0x1.dd000296c4739p-1, 0x1.defffe54490f5p-1,
        0x1.e0fffcdabf694p-1, 0x1.e2fffdb52c8ddp-1, 0x1.e4ffff24216efp-1, 0x1.e6fffe88a5e11p-1,
        0x1.e9000119eff0dp-1, 0x1.eafffdfa51744p-1, 0x1.ed0001a127fa1p-1, 0x1.ef00007babcc4p-1,
        0x1.f0ffff57a8d02p-1, 0x1.f30001ee58ac7p-1, 0x1.f4ffff5823494p-1, 0x1.f6ffffca94c6bp-1,
        0x1.f8fffe1f9c441p-1, 0x1.fafffd2e0e37ep-1, 0x1.fd0001c77e49ep-1, 0x1.feffff7e0c331p-1,
        0x1.00ffff465606ep+0, 0x1.02ffff3867a58p+0, 0x1.04ffffdfc0d17p+0, 0x1.0700003cd4d82p+0,
        0x1.08ffff9f2cbe8p+0, 0x1.0b000010cda65p+0, 0x1.0d00001a4d338p+0, 0x1.0effffadafdfdp+0,
        0x1.110000bbafd96p+0, 0x1.12ffffae5f45dp+0, 0x1.150000dd59ad9p+0, 0x1.170000f21559ap+0,
        0x1.18ffffc275426p+0, 0x1.1b000123d3c59p+0, 0x1.1cffff8299eb7p+0, 0x1.1effff48ad4p+0,
        0x1.210000c8b86a4p+0, 0x1.2300003854303p+0, 0x1.24fffffbcf684p+0, 0x1.26ffff52921d9p+0,
        0x1.2900014933a3cp+0, 0x1.2b00014556313p+0, 0x1.2cfffebfe523bp+0, 0x1.2f0000bb8ad96p+0,
        0x1.30ffffb7ae2afp+0, 0x1.32ffffeac5f7fp+0, 0x1.350000ca66756p+0, 0x1.3700011fbf721p+0,
        0x1.38ffff9592fb9p+0, 0x1.3b00004ddd242p+0, 0x1.3cffff5b2c957p+0, 0x1.3efffeab0b418p+0,
        0x1.410001532aff4p+0, 0x1.4300017478b29p+0, 0x1.44fffe795b463p+0, 0x1.46fffe80475ep+0,
        0x1.48fffef6fc1e7p+0, 0x1.4afffe5bea704p+0, 0x1.4d000171027dep+0, 0x1.4f0000ff03ee2p+0,
        0x1.5100012dc4bd1p+0, 0x1.530001605277ap+0, 0x1.54fffecdb704cp+0, 0x1.56fffef5f54a9p+0,
        0x1.5900017e61012p+0, 0x1.5b00003c93e92p+0, 0x1.5d0001d4919bcp+0, 0x1.5efffe7b87a89p+0,
    };
    const log_clo = [128]f64{
        0x1.e026c91425b3cp-56,  0x1.dbfea48005d41p-55,  0x1.e7fa786d6a5b7p-55,  0x1.1fcea6b54254cp-57,
        -0x1.c7e274c590efdp-56, -0x1.ac16848dcda01p-55, 0x1.33f1c9d499311p-55,  -0x1.e80041ae22d53p-56,
        0x1.bff6671097952p-56,  0x1.c00e226bd8724p-55,  -0x1.e02916ef101d2p-57, -0x1.7fc71cd549c74p-57,
        0x1.1bec19ef50483p-55,  -0x1.07e1729cc6465p-56, -0x1.08072087b8b1cp-55, 0x1.dc0286d9df9aep-55,
        0x1.97fd251e54c33p-55,  -0x1.afee9b630f381p-55, 0x1.9bfbf6b6535bcp-55,  -0x1.bbf65f3117b75p-55,
        -0x1.9006ea23dcb57p-55, -0x1.d00df38e04b0ap-56, -0x1.8007146ff9f05p-55, 0x1.3817bd07a7038p-55,
        0x1.93e9176dfb403p-55,  0x1.f804e4b980276p-56,  -0x1.f7ef0d9ff622ep-55, -0x1.082aa962638bap-56,
        -0x1.7801b9164a8efp-55, -0x1.740e08a5a9337p-55, 0x1.fce08c19bep-60,     -0x1.a3faa27885b0ap-55,
        0x1.4ff489958da56p-56,  0x1.cbeab8a2b6d18p-55,  0x1.8fecadd78793p-55,   -0x1.f41763dd8abdbp-55,
        -0x1.ebf0284c27612p-55, -0x1.9fd043cff3f5fp-57, -0x1.23ee7129070b4p-55, 0x1.a063ee00edea3p-57,
        0x1.a06c8381f0ab9p-58,  -0x1.9011e74233c1dp-56, -0x1.9ff1068862a9fp-56, 0x1.aff45d0864f3ep-55,
        0x1.cfe7796c2c3f9p-56,  -0x1.3ff27eef22bc4p-57, -0x1.cffb7ee3bea21p-57, -0x1.14103972e0b5cp-55,
        0x1.bc16494b76a19p-55,  -0x1.4feef8d30c6edp-57, -0x1.43f68bcec4775p-55, 0x1.47ea3f053e0ecp-55,
        0x1.383068df992f1p-56,  -0x1.8fd8e64180e04p-57, 0x1.e7ebe1cc7ea72p-55,  0x1.ebe39ad9f88fep-55,
        0x1.57d91a8b95a71p-56,  0x1.9c1906970c7dap-55,  -0x1.80e37c558fe0cp-58, -0x1.f80d64dc10f44p-56,
        -0x1.47c8f94fd5c5cp-56, 0x1.c7f1dc521617ep-55,  0x1.8019eb2ffb153p-55,  0x1.e00d2c652cc89p-57,
        -0x1.f8340202d69d2p-56, 0x1.b00c1ca1b0864p-56,  0x1.2ffa8b094ab51p-56,  -0x1.7f673b1efbe59p-58,
        -0x1.4808d5e0bc801p-55, 0x1.80006d54320b5p-56,  -0x1.002f860565c92p-58, -0x1.540445d35e611p-55,
        -0x1.ffb3139ef9105p-59, 0x1.a81acf2731155p-55,  0x1.a3f41d4d7c743p-55,  -0x1.202f41c987875p-57,
        0x1.77dd1f477e74bp-56,  -0x1.f01199a7ca331p-57, 0x1.181ee4bceacb1p-56,  -0x1.e05370170875ap-57,
        -0x1.a7ead491c0adap-55, -0x1.77f69c3fcb2ep-54,  0x1.7bffe34cb945bp-54,  0x1.20083c0e456cbp-55,
        -0x1.dffdfbe37751ap-57, -0x1.13f7faee626ebp-54, 0x1.07dfa79489ff7p-55,  -0x1.7040570d66bcp-56,
        0x1.e80d4846d0b62p-55,  0x1.dbffa64fd36efp-54,  0x1.a0077701250aep-54,  0x1.dfdf9e2e3deeep-55,
        0x1.10030dc3b7273p-54,  0x1.97f7980030188p-54,  -0x1.5f932ab9f8c67p-57, 0x1.37fbf9da75bebp-54,
        0x1.f806b91fd5b22p-54,  0x1.3ffc2eb9fbf33p-54,  0x1.601e77e2e2e72p-56,  0x1.ffcbb767f0c61p-56,
        -0x1.202ca3c02412bp-56, -0x1.2808233f21f02p-54, -0x1.8ff7e384fdcf2p-55, -0x1.5ff51503041c5p-55,
        -0x1.10071885e289dp-55, -0x1.1ff5d3fb7b715p-54, 0x1.57f82228b82bdp-54,  0x1.000bac40dd5ccp-55,
        -0x1.43f9d2db2a751p-54, 0x1.57f6b707638e1p-55,  0x1.a023a10bf1231p-56,  0x1.87f6d66b152bp-54,
        0x1.7f8375f198524p-57,  0x1.301e672dc5143p-55,  0x1.9ff69b8b2895ap-55,  -0x1.5c0b19bc2f254p-54,
        0x1.b4009f23a2a72p-54,  -0x1.4ffb7bf0d7d45p-54, -0x1.9c06471dc6a3dp-54, 0x1.77f890b85531cp-54,
        0x1.004657166a436p-57,  -0x1.6bfcece233209p-54, -0x1.902720505a1d7p-55, 0x1.bbfe60ec96412p-54,
        0x1.87ec581afef9p-55,   -0x1.f41080abf0ccp-54,  -0x1.8812afb254729p-54, -0x1.47eb780ed6904p-54,
    };

    // ---- ARM optimized-routines exp and pow (musl src/math pow.c,
    // exp_data.c, pow_data.c; Copyright (c) 2018, Arm Limited, MIT) ----
    //
    // The host math without libc. Correctness contract, checked by the tests
    // below and measured in docs/measurements/device-runtime-2026-10-01.md:
    //   exp:  error <= 0.52 ulp of the correctly rounded result for every
    //         finite x (ARM: 0.509 with fma, 0.511 without); exp(+-0) = 1,
    //         exp(+inf) = +inf, exp(-inf) = +0, NaN in -> NaN out; +inf above
    //         0x1.62e42fefa39efp9 (709.78), gradual underflow to +0 below
    //         -745.13; never negative.
    //   pow:  error <= 0.54 ulp for finite non-special x, y; the special
    //         cases of C99 F.10.4.4 (pow(x, +-0) = 1, pow(1, y) = 1,
    //         pow(-x, odd int) = -pow(x, y), pow(-x, non-int) = NaN, zero and
    //         infinity rows); exact for every case where x^y is exact and
    //         fits.
    // Both replace routines that were not more accurate: compiler_rt's exp
    // (musl's older FreeBSD exp, < 1 ulp) and `std.math.pow` (repeated
    // squaring for the integer part of y, then exp(yf*log x): its error grows
    // with |y|). Neither is bit-identical to them.

    const exp_n = 128;
    const exp_invln2n = 0x1.71547652b82fep0 * 128.0;
    const exp_negln2hin = -0x1.62e42fefa0000p-8;
    const exp_negln2lon = -0x1.cf79abc9e3b3ap-47;
    const exp_shift = 0x1.8p52;
    const exp_c2 = 0x1.ffffffffffdbdp-2;
    const exp_c3 = 0x1.555555555543cp-3;
    const exp_c4 = 0x1.55555cf172b91p-5;
    const exp_c5 = 0x1.1111167a4d017p-7;
    const pow_ln2hi = 0x1.62e42fefa3800p-1;
    const pow_ln2lo = 0x1.ef35793c76730p-45;
    const pow_a = [7]f64{
        -0x1p-1,
        0x1.555555555556p-2 * -2.0,
        -0x1.0000000000006p-2 * -2.0,
        0x1.999999959554ep-3 * 4.0,
        -0x1.555555529a47ap-3 * 4.0,
        0x1.2495b9b4845e9p-3 * -8.0,
        -0x1.0002b8b263fc3p-3 * -8.0,
    };
    const pow_off: u64 = 0x3fe6955500000000;
    const sign_bias: u64 = 0x800 << 7;
    // exact_everywhere: these routines use no fma. `@mulAdd` is one
    // rounding where the hardware fuses and a slow libcall where it does not
    // (baseline x86-64), and a fused and an unfused build round differently,
    // so the same device would give different bits on host, NVPTX and
    // AMDGCN. ARM's fma-free variants are the ones used, measured
    // (round 2, i9-14900HX): exp unchanged (it has no fma), log 10.1 -> 12.5
    // and pow 23.7 -> 28.0 TSC ticks/call, bounds unchanged at the measured
    // precision (log <= 0.500, pow <= 0.505 ulp).

    inline fn top12(x: f64) u32 {
        return @intCast(@as(u64, @bitCast(x)) >> 52);
    }
    inline fn asF(u: u64) f64 {
        return @bitCast(u);
    }
    inline fn asU(f: f64) u64 {
        return @bitCast(f);
    }

    /// `pow.c` `specialcase`: scale * (1 + tmp) where scale's exponent may
    /// have left the normal range (`ki` the reduction's k).
    fn expSpecial(tmp: f64, sbits0: u64, ki: u64) f64 {
        var sbits = sbits0;
        if (ki & 0x80000000 == 0) {
            // k > 0: the exponent of scale may have overflowed by <= 460.
            sbits -%= 1009 << 52;
            const scale = asF(sbits);
            return 0x1p1009 * (scale + scale * tmp);
        }
        // k < 0: round in the normal range first, then scale into the
        // subnormal one, so there is no double rounding.
        sbits +%= 1022 << 52;
        const scale = asF(sbits);
        var y = scale + scale * tmp;
        if (@abs(y) < 1.0) {
            const one: f64 = if (y < 0.0) -1.0 else 1.0;
            var lo = scale - y + scale * tmp;
            const hi = one + y;
            lo = one - hi + y + lo;
            y = (hi + lo) - one;
            if (y == 0.0) y = asF(sbits & 0x8000000000000000);
        }
        return 0x1p-1022 * y;
    }

    /// `pow.c` `exp_inline`: sign * exp(x + xtail), |xtail| < 2^-8/N.
    inline fn expCore(x: f64, xtail: f64, sbias: u64) f64 {
        var abstop = top12(x) & 0x7ff;
        if (abstop -% top12(0x1p-54) >= top12(512.0) -% top12(0x1p-54)) {
            @branchHint(.unlikely);
            if (abstop -% top12(0x1p-54) >= 0x80000000) {
                // Tiny x (0 included): 1 + x rounds right.
                const one = 1.0 + x;
                return if (sbias != 0) -one else one;
            }
            if (abstop >= top12(1024.0)) {
                const inf = std.math.inf(f64);
                const r: f64 = if (asU(x) >> 63 != 0) 0.0 else inf;
                return if (sbias != 0) -r else r;
            }
            abstop = 0; // large |x|: `expSpecial` below
        }
        // exp(x) = 2^(k/N) * exp(r), r in [-ln2/2N, ln2/2N].
        const m = expMain(f64, x, xtail, sbias);
        if (abstop == 0) {
            @branchHint(.unlikely);
            return expSpecial(m.tmp, m.sbits, m.ki);
        }
        const scale = asF(m.sbits);
        return scale + scale * m.tmp;
    }

    /// exp(x), see the contract above.
    /// exp(x) for |x| < 2^-28: 1 + (x + x^2/2), the next term below
    /// 2^-86 relative, so one final rounding (<= 0.5 + 2^-30 ulp). Cheaper
    /// than the table path for the near-zero arguments a history decay
    /// factor exp(-a*dt) feeds every step (coupled_ltra: all of them).
    inline fn expSmall(x: anytype) @TypeOf(x) {
        const T = @TypeOf(x);
        return sp(T, 1.0) + (x + x * x * sp(T, 0.5));
    }

    pub fn armExp(x: f64) f64 {
        const abstop = top12(x) & 0x7ff;
        if (abstop < top12(0x1p-28)) return expSmall(x);
        if (abstop >= top12(512.0)) {
            @branchHint(.unlikely);
            if (abstop >= 0x7ff) return if (asU(x) == asU(-std.math.inf(f64))) 0.0 else 1.0 + x; // +-inf, NaN
            // The results `expSpecial` would round to anyway, without it
            // (a decaying history term reaches here every step): exp(x)
            // rounds to +0 below this double (it is above -1075 ln2, the
            // next one below is not) and to +inf above ln(DBL_MAX).
            if (x < -0x1.74910d52d3051p9) return 0.0;
            if (x > 0x1.62e42fefa39efp9) return std.math.inf(f64);
        }
        return expCore(x, 0.0, 0);
    }

    /// `pow.c` `log_inline`: log(x) as hi + tail for x's (normalized) bits.
    inline fn powLog(ix: u64, tail: *f64) f64 {
        const l = powLogG(f64, ix);
        tail.* = l.tail;
        return l.y;
    }

    /// 0: not an integer, 1: odd, 2: even, for the bits of a non-zero
    /// finite double.
    inline fn checkInt(iy: u64) u32 {
        const e: u32 = @intCast(iy >> 52 & 0x7ff);
        if (e < 0x3ff) return 0;
        if (e > 0x3ff + 52) return 2;
        const sh: u6 = @intCast(0x3ff + 52 - e);
        if (iy & ((@as(u64, 1) << sh) - 1) != 0) return 0;
        if (iy & (@as(u64, 1) << sh) != 0) return 1;
        return 2;
    }
    inline fn zeroInfNan(i: u64) bool {
        return 2 *% i -% 1 >= 2 *% asU(std.math.inf(f64)) -% 1;
    }

    /// x^y for `f64` or `@Vector(n, f64)` bases and one exponent; the
    /// contract is `armPow`'s. A vector whose bases are all positive, normal
    /// and finite, with an ordinary y and an ordinary exp argument in every
    /// lane, runs `armPow`'s arithmetic on the whole vector; any other takes
    /// `armPow` lane by lane. Either way a lane is the scalar call's bits.
    pub fn powV(x: anytype, y: f64) @TypeOf(x) {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .vector => |v| {
                const U = UOf(T);
                const ix: U = @bitCast(x);
                const iy = asU(y);
                const topy = top12(y) & 0x7ff;
                const normal = shrU(ix, 52) -% sp(U, 0x001) < sp(U, 0x7fe);
                if (@reduce(.And, normal) and topy -% 0x3be < 0x43e - 0x3be) {
                    const l = powLogG(T, ix);
                    // `armPow`'s fma-free y * (hi + lo).
                    const yhi = asF(iy & (~@as(u64, 0) << 27));
                    const ylo = y - yhi;
                    const lhi: T = @bitCast(@as(U, @bitCast(l.y)) & sp(U, ~@as(u64, 0) << 27));
                    const llo = l.y - lhi + l.tail;
                    const ehi = sp(T, yhi) * lhi;
                    const elo = sp(T, ylo) * lhi + sp(T, y) * llo;
                    const abstop = shrU(@as(U, @bitCast(ehi)), 52) & sp(U, 0x7ff);
                    if (@reduce(.And, abstop -% sp(U, top12(0x1p-54)) < sp(U, top12(512.0) - top12(0x1p-54)))) {
                        const m = expMain(T, ehi, elo, 0);
                        const scale: T = @bitCast(m.sbits);
                        return scale + scale * m.tmp;
                    }
                }
                var out: T = undefined;
                inline for (0..v.len) |k| out[k] = armPow(x[k], y);
                return out;
            },
            else => return armPow(x, y),
        }
    }

    /// x^y, see the contract above.
    pub fn armPow(x: f64, y: f64) f64 {
        var sbias: u64 = 0;
        var ix = asU(x);
        const iy = asU(y);
        var topx = top12(x);
        const topy = top12(y);
        if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            @branchHint(.unlikely);
            if (zeroInfNan(iy)) {
                if (2 *% iy == 0) return 1.0;
                if (ix == asU(1.0)) return 1.0;
                if (2 *% ix > 2 *% asU(std.math.inf(f64)) or 2 *% iy > 2 *% asU(std.math.inf(f64))) return x + y;
                if (2 *% ix == 2 *% asU(1.0)) return 1.0;
                if ((2 *% ix < 2 *% asU(1.0)) == (iy >> 63 == 0)) return 0.0;
                return y * y;
            }
            if (zeroInfNan(ix)) {
                var x2 = x * x;
                if (ix >> 63 != 0 and checkInt(iy) == 1) x2 = -x2;
                return if (iy >> 63 != 0) 1.0 / x2 else x2;
            }
            // x and y are non-zero finite.
            if (ix >> 63 != 0) {
                const yint = checkInt(iy);
                if (yint == 0) return std.math.nan(f64);
                if (yint == 1) sbias = sign_bias;
                ix &= 0x7fffffffffffffff;
                topx &= 0x7ff;
            }
            if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
                if (ix == asU(1.0)) return 1.0;
                if ((topy & 0x7ff) < 0x3be) return if (ix > asU(1.0)) 1.0 + y else 1.0 - y;
                const inf = std.math.inf(f64);
                return if ((ix > asU(1.0)) == (topy < 0x800)) inf else 0.0;
            }
            if (topx == 0) {
                // Subnormal x: normalize so the exponent goes negative.
                ix = asU(x * 0x1p52) & 0x7fffffffffffffff;
                ix -%= 52 << 52;
            }
        }
        var lo: f64 = undefined;
        const hi = powLog(ix, &lo);
        // y * (hi + lo) as ehi + elo without fma (`exact_everywhere`).
        const yhi = asF(iy & (~@as(u64, 0) << 27));
        const ylo = y - yhi;
        const lhi = asF(asU(hi) & (~@as(u64, 0) << 27));
        const llo = hi - lhi + lo;
        const ehi = yhi * lhi;
        const elo = ylo * lhi + y * llo;
        return expCore(ehi, elo, sbias);
    }
    /// ARM exp_data.c `tab`: 2^(k/128) ~= H[k]*(1 + T[k]); [2k] = bits of T[k],
    /// [2k+1] = bits of H[k] - (k << 52)/128.
    const exp_tab = [256]u64{
        0x0,                0x3ff0000000000000, 0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
        0xbc7160139cd8dc5d, 0x3fefec9a3e778061, 0xbc905e7a108766d1, 0x3fefe315e86e7f85,
        0x3c8cd2523567f613, 0x3fefd9b0d3158574, 0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
        0x3c60f74e61e6c861, 0x3fefc74518759bc8, 0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
        0x3c979aa65d837b6d, 0x3fefb5586cf9890f, 0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
        0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2, 0xbc6a033489906e0b, 0x3fef9b66affed31b,
        0xbc9556522a2fbd0e, 0x3fef9301d0125b51, 0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
        0xbc91c923b9d5f416, 0x3fef829aaea92de0, 0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
        0xbc801b15eaa59348, 0x3fef72b83c7d517b, 0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
        0x3c8b898c3f1353bf, 0x3fef635beb6fcb75, 0xbc96d99c7611eb26, 0x3fef5be084045cd4,
        0x3c9aecf73e3a2f60, 0x3fef54873168b9aa, 0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
        0x3c8a6f4144a6c38d, 0x3fef463b88628cd6, 0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
        0x3c968efde3a8a894, 0x3fef387a6e756238, 0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
        0x3c80472b981fe7f2, 0x3fef2b4565e27cdd, 0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
        0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1, 0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
        0x3c8b3782720c0ab4, 0x3fef1285a6e4030b, 0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
        0x3c834d754db0abb6, 0x3fef06fe0a31b715, 0x3c864201e2ac744c, 0x3fef0170fc4cd831,
        0x3c8fdd395dd3f84a, 0x3feefc08b26416ff, 0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
        0xbc924aedcc4b5068, 0x3feef1a7373aa9cb, 0xbc9907f81b512d8e, 0x3feeecae6d05d866,
        0xbc71d1e83e9436d2, 0x3feee7db34e59ff7, 0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
        0x3c859f48a72a4c6d, 0x3feedea64c123422, 0xbc9312607a28698a, 0x3feeda4504ac801c,
        0xbc58a78f4817895b, 0x3feed60a21f72e2a, 0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
        0x3c4363ed60c2ac11, 0x3feece086061892d, 0x3c9666093b0664ef, 0x3feeca41ed1d0057,
        0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0, 0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
        0x3c7690cebb7aafb0, 0x3feebfdad5362a27, 0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
        0xbc8f94340071a38e, 0x3feeb9b2769d2ca7, 0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
        0xbc78dec6bd0f385f, 0x3feeb42b569d4f82, 0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
        0x3c93350518fdd78e, 0x3feeaf4736b527da, 0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
        0x3c9063e1e21c5409, 0x3feeab07dd485429, 0x3c34c7855019c6ea, 0x3feea9268a5946b7,
        0x3c9432e62b64c035, 0x3feea76f15ad2148, 0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
        0xbc8c33c53bef4da8, 0x3feea47eb03a5585, 0xbc845378892be9ae, 0x3feea34634ccc320,
        0xbc93cedd78565858, 0x3feea23882552225, 0x3c5710aa807e1964, 0x3feea155d44ca973,
        0xbc93b3efbf5e2228, 0x3feea09e667f3bcd, 0xbc6a12ad8734b982, 0x3feea012750bdabf,
        0xbc6367efb86da9ee, 0x3fee9fb23c651a2f, 0xbc80dc3d54e08851, 0x3fee9f7df9519484,
        0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74, 0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
        0xbc8619321e55e68a, 0x3fee9feb564267c9, 0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
        0xbc7b32dcb94da51d, 0x3feea11473eb0187, 0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
        0x3c65ebe1abd66c55, 0x3feea2f336cf4e62, 0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
        0xbc9369b6f13b3734, 0x3feea589994cce13, 0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
        0xbc94d450d872576e, 0x3feea8d99b4492ed, 0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
        0x3c8db72fc1f0eab4, 0x3feeace5422aa0db, 0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
        0x3c7bf68359f35f44, 0x3feeb1ae99157736, 0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
        0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5, 0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
        0xbc92434322f4f9aa, 0x3feebd829fde4e50, 0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
        0x3c71affc2b91ce27, 0x3feec49182a3f090, 0x3c6dd235e10a73bb, 0x3feec86319e32323,
        0xbc87c50422622263, 0x3feecc667b5de565, 0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
        0xbc91bbd1d3bcbb15, 0x3feed503b23e255d, 0x3c90cc319cee31d2, 0x3feed99e1330b358,
        0x3c8469846e735ab3, 0x3feede6b5579fdbf, 0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
        0x3c8c1a7792cb3387, 0x3feee89f995ad3ad, 0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
        0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb, 0xbc90a40e3da6f640, 0x3feef9728de5593a,
        0xbc68d6f438ad9334, 0x3feeff76f2fb5e47, 0xbc91eee26b588a35, 0x3fef05b030a1064a,
        0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2, 0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
        0x3c736eae30af0cb3, 0x3fef199bdd85529c, 0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
        0x3c84e08fd10959ac, 0x3fef27f12e57d14b, 0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
        0x3c676b2c6c921968, 0x3fef3720dcef9069, 0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
        0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c, 0xbc900dae3875a949, 0x3fef4f87080d89f2,
        0x3c74a385a63d07a7, 0x3fef5818dcfba487, 0xbc82919e2040220f, 0x3fef60e316c98398,
        0x3c8e5a50d5c192ac, 0x3fef69e603db3285, 0x3c843a59ac016b4b, 0x3fef7321f301b460,
        0xbc82d52107b43e1f, 0x3fef7c97337b9b5f, 0xbc892ab93b470dc9, 0x3fef864614f5a129,
        0x3c74b604603a88d3, 0x3fef902ee78b3ff6, 0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
        0xbc8ff7128fd391f0, 0x3fefa4afa2a490da, 0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
        0x3c8ec3bc41aa2008, 0x3fefba1bee615a27, 0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
        0x3c8a64a931d185ee, 0x3fefd0765b6e4540, 0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
        0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8, 0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
    };
    /// ARM pow_data.c `tab`: { invc, logc, logctail } per 1/128 subinterval.
    const pow_log_invc = column(0);
    const pow_log_logc = column(1);
    const pow_log_logctail = column(2);
    fn column(comptime c: usize) [128]f64 {
        var out: [128]f64 = undefined;
        for (&out, pow_log_tab) |*o, row| o.* = row[c];
        return out;
    }
    const pow_log_tab = [128][3]f64{
        .{ 0x1.6a00000000000p+0, -0x1.62c82f2b9c800p-2, 0x1.ab42428375680p-48 },
        .{ 0x1.6800000000000p+0, -0x1.5d1bdbf580800p-2, -0x1.ca508d8e0f720p-46 },
        .{ 0x1.6600000000000p+0, -0x1.5767717455800p-2, -0x1.362a4d5b6506dp-45 },
        .{ 0x1.6400000000000p+0, -0x1.51aad872df800p-2, -0x1.684e49eb067d5p-49 },
        .{ 0x1.6200000000000p+0, -0x1.4be5f95777800p-2, -0x1.41b6993293ee0p-47 },
        .{ 0x1.6000000000000p+0, -0x1.4618bc21c6000p-2, 0x1.3d82f484c84ccp-46 },
        .{ 0x1.5e00000000000p+0, -0x1.404308686a800p-2, 0x1.c42f3ed820b3ap-50 },
        .{ 0x1.5c00000000000p+0, -0x1.3a64c55694800p-2, 0x1.0b1c686519460p-45 },
        .{ 0x1.5a00000000000p+0, -0x1.347dd9a988000p-2, 0x1.5594dd4c58092p-45 },
        .{ 0x1.5800000000000p+0, -0x1.2e8e2bae12000p-2, 0x1.67b1e99b72bd8p-45 },
        .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
        .{ 0x1.5600000000000p+0, -0x1.2895a13de8800p-2, 0x1.5ca14b6cfb03fp-46 },
        .{ 0x1.5400000000000p+0, -0x1.22941fbcf7800p-2, -0x1.65a242853da76p-46 },
        .{ 0x1.5200000000000p+0, -0x1.1c898c1699800p-2, -0x1.fafbc68e75404p-46 },
        .{ 0x1.5000000000000p+0, -0x1.1675cababa800p-2, 0x1.f1fc63382a8f0p-46 },
        .{ 0x1.4e00000000000p+0, -0x1.1058bf9ae4800p-2, -0x1.6a8c4fd055a66p-45 },
        .{ 0x1.4c00000000000p+0, -0x1.0a324e2739000p-2, -0x1.c6bee7ef4030ep-47 },
        .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
        .{ 0x1.4a00000000000p+0, -0x1.0402594b4d000p-2, -0x1.036b89ef42d7fp-48 },
        .{ 0x1.4800000000000p+0, -0x1.fb9186d5e4000p-3, 0x1.d572aab993c87p-47 },
        .{ 0x1.4600000000000p+0, -0x1.ef0adcbdc6000p-3, 0x1.b26b79c86af24p-45 },
        .{ 0x1.4400000000000p+0, -0x1.e27076e2af000p-3, -0x1.72f4f543fff10p-46 },
        .{ 0x1.4200000000000p+0, -0x1.d5c216b4fc000p-3, 0x1.1ba91bbca681bp-45 },
        .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
        .{ 0x1.4000000000000p+0, -0x1.c8ff7c79aa000p-3, 0x1.7794f689f8434p-45 },
        .{ 0x1.3e00000000000p+0, -0x1.bc286742d9000p-3, 0x1.94eb0318bb78fp-46 },
        .{ 0x1.3c00000000000p+0, -0x1.af3c94e80c000p-3, 0x1.a4e633fcd9066p-52 },
        .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
        .{ 0x1.3a00000000000p+0, -0x1.a23bc1fe2b000p-3, -0x1.58c64dc46c1eap-45 },
        .{ 0x1.3800000000000p+0, -0x1.9525a9cf45000p-3, -0x1.ad1d904c1d4e3p-45 },
        .{ 0x1.3600000000000p+0, -0x1.87fa06520d000p-3, 0x1.bbdbf7fdbfa09p-45 },
        .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
        .{ 0x1.3400000000000p+0, -0x1.7ab890210e000p-3, 0x1.bdb9072534a58p-45 },
        .{ 0x1.3200000000000p+0, -0x1.6d60fe719d000p-3, -0x1.0e46aa3b2e266p-46 },
        .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
        .{ 0x1.3000000000000p+0, -0x1.5ff3070a79000p-3, -0x1.e9e439f105039p-46 },
        .{ 0x1.2e00000000000p+0, -0x1.526e5e3a1b000p-3, -0x1.0de8b90075b8fp-45 },
        .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
        .{ 0x1.2c00000000000p+0, -0x1.44d2b6ccb8000p-3, 0x1.70cc16135783cp-46 },
        .{ 0x1.2a00000000000p+0, -0x1.371fc201e9000p-3, 0x1.178864d27543ap-48 },
        .{ 0x1.2800000000000p+0, -0x1.29552f81ff000p-3, -0x1.48d301771c408p-45 },
        .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
        .{ 0x1.2600000000000p+0, -0x1.1b72ad52f6000p-3, -0x1.e80a41811a396p-45 },
        .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
        .{ 0x1.2400000000000p+0, -0x1.0d77e7cd09000p-3, 0x1.a699688e85bf4p-47 },
        .{ 0x1.2200000000000p+0, -0x1.fec9131dbe000p-4, -0x1.575545ca333f2p-45 },
        .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
        .{ 0x1.2000000000000p+0, -0x1.e27076e2b0000p-4, 0x1.a342c2af0003cp-45 },
        .{ 0x1.1e00000000000p+0, -0x1.c5e548f5bc000p-4, -0x1.d0c57585fbe06p-46 },
        .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
        .{ 0x1.1c00000000000p+0, -0x1.a926d3a4ae000p-4, 0x1.53935e85baac8p-45 },
        .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
        .{ 0x1.1a00000000000p+0, -0x1.8c345d631a000p-4, 0x1.37c294d2f5668p-46 },
        .{ 0x1.1800000000000p+0, -0x1.6f0d28ae56000p-4, -0x1.69737c93373dap-45 },
        .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
        .{ 0x1.1600000000000p+0, -0x1.51b073f062000p-4, 0x1.f025b61c65e57p-46 },
        .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
        .{ 0x1.1400000000000p+0, -0x1.341d7961be000p-4, 0x1.c5edaccf913dfp-45 },
        .{ 0x1.1200000000000p+0, -0x1.16536eea38000p-4, 0x1.47c5e768fa309p-46 },
        .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
        .{ 0x1.1000000000000p+0, -0x1.f0a30c0118000p-5, 0x1.d599e83368e91p-45 },
        .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
        .{ 0x1.0e00000000000p+0, -0x1.b42dd71198000p-5, 0x1.c827ae5d6704cp-46 },
        .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
        .{ 0x1.0c00000000000p+0, -0x1.77458f632c000p-5, -0x1.cfc4634f2a1eep-45 },
        .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
        .{ 0x1.0a00000000000p+0, -0x1.39e87b9fec000p-5, 0x1.502b7f526feaap-48 },
        .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
        .{ 0x1.0800000000000p+0, -0x1.f829b0e780000p-6, -0x1.980267c7e09e4p-45 },
        .{ 0x1.0600000000000p+0, -0x1.7b91b07d58000p-6, -0x1.88d5493faa639p-45 },
        .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
        .{ 0x1.0400000000000p+0, -0x1.fc0a8b0fc0000p-7, -0x1.f1e7cf6d3a69cp-50 },
        .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
        .{ 0x1.0200000000000p+0, -0x1.fe02a6b100000p-8, -0x1.9e23f0dda40e4p-46 },
        .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
        .{ 0x1.0000000000000p+0, 0x0.0000000000000p+0, 0x0.0000000000000p+0 },
        .{ 0x1.fc00000000000p-1, 0x1.0101575890000p-7, -0x1.0c76b999d2be8p-46 },
        .{ 0x1.f800000000000p-1, 0x1.0205658938000p-6, -0x1.3dc5b06e2f7d2p-45 },
        .{ 0x1.f400000000000p-1, 0x1.8492528c90000p-6, -0x1.aa0ba325a0c34p-45 },
        .{ 0x1.f000000000000p-1, 0x1.0415d89e74000p-5, 0x1.111c05cf1d753p-47 },
        .{ 0x1.ec00000000000p-1, 0x1.466aed42e0000p-5, -0x1.c167375bdfd28p-45 },
        .{ 0x1.e800000000000p-1, 0x1.894aa149fc000p-5, -0x1.97995d05a267dp-46 },
        .{ 0x1.e400000000000p-1, 0x1.ccb73cdddc000p-5, -0x1.a68f247d82807p-46 },
        .{ 0x1.e200000000000p-1, 0x1.eea31c006c000p-5, -0x1.e113e4fc93b7bp-47 },
        .{ 0x1.de00000000000p-1, 0x1.1973bd1466000p-4, -0x1.5325d560d9e9bp-45 },
        .{ 0x1.da00000000000p-1, 0x1.3bdf5a7d1e000p-4, 0x1.cc85ea5db4ed7p-45 },
        .{ 0x1.d600000000000p-1, 0x1.5e95a4d97a000p-4, -0x1.c69063c5d1d1ep-45 },
        .{ 0x1.d400000000000p-1, 0x1.700d30aeac000p-4, 0x1.c1e8da99ded32p-49 },
        .{ 0x1.d000000000000p-1, 0x1.9335e5d594000p-4, 0x1.3115c3abd47dap-45 },
        .{ 0x1.cc00000000000p-1, 0x1.b6ac88dad6000p-4, -0x1.390802bf768e5p-46 },
        .{ 0x1.ca00000000000p-1, 0x1.c885801bc4000p-4, 0x1.646d1c65aacd3p-45 },
        .{ 0x1.c600000000000p-1, 0x1.ec739830a2000p-4, -0x1.dc068afe645e0p-45 },
        .{ 0x1.c400000000000p-1, 0x1.fe89139dbe000p-4, -0x1.534d64fa10afdp-45 },
        .{ 0x1.c000000000000p-1, 0x1.1178e8227e000p-3, 0x1.1ef78ce2d07f2p-45 },
        .{ 0x1.be00000000000p-1, 0x1.1aa2b7e23f000p-3, 0x1.ca78e44389934p-45 },
        .{ 0x1.ba00000000000p-1, 0x1.2d1610c868000p-3, 0x1.39d6ccb81b4a1p-47 },
        .{ 0x1.b800000000000p-1, 0x1.365fcb0159000p-3, 0x1.62fa8234b7289p-51 },
        .{ 0x1.b400000000000p-1, 0x1.4913d8333b000p-3, 0x1.5837954fdb678p-45 },
        .{ 0x1.b200000000000p-1, 0x1.527e5e4a1b000p-3, 0x1.633e8e5697dc7p-45 },
        .{ 0x1.ae00000000000p-1, 0x1.6574ebe8c1000p-3, 0x1.9cf8b2c3c2e78p-46 },
        .{ 0x1.ac00000000000p-1, 0x1.6f0128b757000p-3, -0x1.5118de59c21e1p-45 },
        .{ 0x1.aa00000000000p-1, 0x1.7898d85445000p-3, -0x1.c661070914305p-46 },
        .{ 0x1.a600000000000p-1, 0x1.8beafeb390000p-3, -0x1.73d54aae92cd1p-47 },
        .{ 0x1.a400000000000p-1, 0x1.95a5adcf70000p-3, 0x1.7f22858a0ff6fp-47 },
        .{ 0x1.a000000000000p-1, 0x1.a93ed3c8ae000p-3, -0x1.8724350562169p-45 },
        .{ 0x1.9e00000000000p-1, 0x1.b31d8575bd000p-3, -0x1.c358d4eace1aap-47 },
        .{ 0x1.9c00000000000p-1, 0x1.bd087383be000p-3, -0x1.d4bc4595412b6p-45 },
        .{ 0x1.9a00000000000p-1, 0x1.c6ffbc6f01000p-3, -0x1.1ec72c5962bd2p-48 },
        .{ 0x1.9600000000000p-1, 0x1.db13db0d49000p-3, -0x1.aff2af715b035p-45 },
        .{ 0x1.9400000000000p-1, 0x1.e530effe71000p-3, 0x1.212276041f430p-51 },
        .{ 0x1.9200000000000p-1, 0x1.ef5ade4dd0000p-3, -0x1.a211565bb8e11p-51 },
        .{ 0x1.9000000000000p-1, 0x1.f991c6cb3b000p-3, 0x1.bcbecca0cdf30p-46 },
        .{ 0x1.8c00000000000p-1, 0x1.07138604d5800p-2, 0x1.89cdb16ed4e91p-48 },
        .{ 0x1.8a00000000000p-1, 0x1.0c42d67616000p-2, 0x1.7188b163ceae9p-45 },
        .{ 0x1.8800000000000p-1, 0x1.1178e8227e800p-2, -0x1.c210e63a5f01cp-45 },
        .{ 0x1.8600000000000p-1, 0x1.16b5ccbacf800p-2, 0x1.b9acdf7a51681p-45 },
        .{ 0x1.8400000000000p-1, 0x1.1bf99635a6800p-2, 0x1.ca6ed5147bdb7p-45 },
        .{ 0x1.8200000000000p-1, 0x1.214456d0eb800p-2, 0x1.a87deba46baeap-47 },
        .{ 0x1.7e00000000000p-1, 0x1.2bef07cdc9000p-2, 0x1.a9cfa4a5004f4p-45 },
        .{ 0x1.7c00000000000p-1, 0x1.314f1e1d36000p-2, -0x1.8e27ad3213cb8p-45 },
        .{ 0x1.7a00000000000p-1, 0x1.36b6776be1000p-2, 0x1.16ecdb0f177c8p-46 },
        .{ 0x1.7800000000000p-1, 0x1.3c25277333000p-2, 0x1.83b54b606bd5cp-46 },
        .{ 0x1.7600000000000p-1, 0x1.419b423d5e800p-2, 0x1.8e436ec90e09dp-47 },
        .{ 0x1.7400000000000p-1, 0x1.4718dc271c800p-2, -0x1.f27ce0967d675p-45 },
        .{ 0x1.7200000000000p-1, 0x1.4c9e09e173000p-2, -0x1.e20891b0ad8a4p-45 },
        .{ 0x1.7000000000000p-1, 0x1.522ae0738a000p-2, 0x1.ebe708164c759p-45 },
        .{ 0x1.6e00000000000p-1, 0x1.57bf753c8d000p-2, 0x1.fadedee5d40efp-46 },
        .{ 0x1.6c00000000000p-1, 0x1.5d5bddf596000p-2, -0x1.a0b2a08a465dcp-47 },
    };

    // musl exp.c / log.c ports (f64 <= 1 ulp).
    const P1 = 1.66666666666666019037e-01;
    const P2 = -2.77777777770155933842e-03;
    const P3 = 6.61375632143793436117e-05;
    const P4 = -1.65339022054652515390e-06;
    const P5 = 4.13813679705723846039e-08;

    /// musl expm1.c, by way of `std.math.expm1`, minus its one
    /// `doNotOptimizeAway`, see `expm1` above.
    ///
    /// Not `exp(x) - 1`: the whole point is that the `-1` happens INSIDE
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

    /// Distance in units in the last place between two finite doubles of the
    /// same sign.
    fn ulps(a: f64, b: f64) u64 {
        const ia: i64 = @bitCast(a);
        const ib: i64 = @bitCast(b);
        return @abs(ia - ib);
    }

    // ---- the accuracy bound, against an f128 oracle ----
    const ln2_q: f128 = 0x1.62e42fefa39ef35793c7673007e6p-1;
    fn expQ(t: f128) f128 {
        const k = @round(t / ln2_q);
        const r = t - k * ln2_q;
        var term: f128 = 1;
        var sum: f128 = 1;
        var n: f128 = 1;
        while (n < 36) : (n += 1) {
            term = term * r / n;
            sum += term;
        }
        return std.math.ldexp(sum, @intFromFloat(k));
    }
    fn logQ(x: f64) f128 {
        const fr = std.math.frexp(@as(f128, x));
        var m = fr.significand;
        var e: f128 = @floatFromInt(fr.exponent);
        if (m < 0.70710678) {
            m *= 2;
            e -= 1;
        }
        const u = (m - 1) / (m + 1);
        const uu = u * u;
        var term = u;
        var sum: f128 = 0;
        var k: f128 = 1;
        while (k < 100) : (k += 2) {
            sum += term / k;
            term *= uu;
        }
        return 2 * sum + e * ln2_q;
    }
    /// `f(x)` evaluated by the compiler (comptime IEEE arithmetic).
    fn folds(comptime f: fn (f64) f64, comptime x: f64) f64 {
        @setEvalBranchQuota(1_000_000);
        return f(x);
    }
    /// `x` as a run-time value, so the call below is not folded.
    fn rt(x: f64) f64 {
        var v = x;
        std.mem.doNotOptimizeAway(&v);
        return v;
    }
    /// |got - ref| in units of the last place of the double nearest ref.
    fn ulpQ(got: f64, ref: f128) f64 {
        const rd: f64 = @floatCast(ref);
        const e = @max(std.math.ilogb(rd) - 52, -1074);
        return @floatCast(@abs(@as(f128, got) - ref) / std.math.ldexp(@as(f128, 1.0), e));
    }

    test "exp/log/pow stay within the documented bound of an f128 oracle" {
        // docs/IMPLEMENTATION.md: exp <= 0.52, log <= 0.52, pow <= 0.55 ulp
        // (measured maxima 0.507, 0.500, 0.505; the margin is the bound ARM
        // proves). A fixed sample, so the test is reproducible.
        var prng = std.Random.DefaultPrng.init(0x7a11);
        const r = prng.random();
        var worst = [3]f64{ 0, 0, 0 };
        for (0..1500) |_| {
            const x = r.float(f64) * 1440.0 - 735.0;
            worst[0] = @max(worst[0], ulpQ(armExp(x), expQ(x)));
            const lx: f64 = @bitCast((r.int(u64) % 0x7fe0000000000000) + 0x0010000000000000);
            worst[1] = @max(worst[1], ulpQ(armLog(lx), logQ(lx)));
            const px = std.math.pow(f64, 10.0, r.float(f64) * 15.0 - 3.0);
            const py = r.float(f64) * 21.0 - 3.0;
            worst[2] = @max(worst[2], ulpQ(armPow(px, py), expQ(@as(f128, py) * logQ(px))));
        }
        try std.testing.expect(worst[0] <= 0.52);
        try std.testing.expect(worst[1] <= 0.52);
        try std.testing.expect(worst[2] <= 0.55);
    }

    test "exp/log/pow fold at comptime to the bits they run to: no target-dependent operation" {
        // `exact_everywhere`: no fma, so the routines are plain IEEE f64
        // arithmetic, which Zig's comptime evaluates target-independently.
        // A run that matches the fold matches every target the same code
        // compiles for (host, NVPTX, AMDGCN) unless a backend fuses or
        // reassociates on its own, which none does without contract flags.
        const xs = [_]f64{ -744.9, -700.25, -20.5, -0.75, -1e-9, 0.0, 3e-17, 0.693, 1.0, 22.0, 512.5, 709.7 };
        const ls = [_]f64{ 0x1p-1060, 1e-300, 1e-9, 0.5, 0.999999, 1.0, 1.0000001, 3.0, 1e18, 1e308 };
        inline for (xs) |x| {
            const folded = comptime folds(armExp, x);
            try std.testing.expectEqual(@as(u64, @bitCast(folded)), @as(u64, @bitCast(armExp(rt(x)))));
        }
        inline for (ls) |x| {
            const folded = comptime folds(armLog, x);
            try std.testing.expectEqual(@as(u64, @bitCast(folded)), @as(u64, @bitCast(armLog(rt(x)))));
            const pf = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                break :blk armPow(x, 1.4552480184709202);
            };
            try std.testing.expectEqual(@as(u64, @bitCast(pf)), @as(u64, @bitCast(armPow(rt(x), 1.4552480184709202))));
        }
        // The vector form is the scalar's, lane for lane.
        const v: @Vector(4, f64) = .{ -3.5, 0.25, 7.0, 41.0 };
        const ev = hexp(v);
        const lv = hlog(v * v);
        const pv = powV(v * v, 1.4552480184709202);
        const pn = powV(v, 3.0); // a negative base: lane by lane
        inline for (0..4) |l| {
            try std.testing.expectEqual(@as(u64, @bitCast(armPow(v[l] * v[l], 1.4552480184709202))), @as(u64, @bitCast(pv[l])));
            try std.testing.expectEqual(@as(u64, @bitCast(armPow(v[l], 3.0))), @as(u64, @bitCast(pn[l])));
            try std.testing.expectEqual(@as(u64, @bitCast(armExp(v[l]))), @as(u64, @bitCast(ev[l])));
            try std.testing.expectEqual(@as(u64, @bitCast(armLog(v[l] * v[l]))), @as(u64, @bitCast(lv[l])));
        }
    }

    test "armExp/armPow: the contract's special cases, exact cases and 1-ulp agreement" {
        const inf = std.math.inf(f64);
        // exp: specials and range ends.
        try std.testing.expectEqual(@as(f64, 1.0), armExp(0.0));
        try std.testing.expectEqual(@as(f64, 1.0), armExp(-0.0));
        try std.testing.expectEqual(inf, armExp(inf));
        try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(armExp(-inf))));
        try std.testing.expect(std.math.isNan(armExp(std.math.nan(f64))));
        try std.testing.expectEqual(inf, armExp(709.8));
        try std.testing.expect(armExp(709.78) < inf);
        try std.testing.expectEqual(@as(f64, 0.0), armExp(-745.2));
        try std.testing.expect(armExp(-745.0) > 0.0); // gradual underflow
        // The thresholds: the last double whose exp rounds to the least
        // subnormal / to DBL_MAX's neighbourhood, and the next one past it.
        try std.testing.expectEqual(@as(f64, 0x1p-1074), armExp(-0x1.74910d52d3051p9));
        try std.testing.expectEqual(@as(f64, 0.0), armExp(-0x1.74910d52d3052p9));
        try std.testing.expect(armExp(0x1.62e42fefa39efp9) < inf);
        try std.testing.expectEqual(inf, armExp(0x1.62e42fefa39f0p9));
        try std.testing.expectEqual(std.math.e, armExp(1.0));
        // Monotone across a reduction-table seam and against compiler_rt.
        var x: f64 = -745.0;
        var prev: f64 = 0.0;
        while (x < 709.0) : (x += 0.0731) {
            const e = armExp(x);
            try std.testing.expect(e >= prev);
            prev = e;
            if (@exp(x) > 0x1p-1022) try std.testing.expect(ulps(e, @exp(x)) <= 1);
        }
        // pow: C99 F.10.4.4 rows and exact results.
        try std.testing.expectEqual(@as(f64, 1.0), armPow(-3.0, 0.0));
        try std.testing.expectEqual(@as(f64, 1.0), armPow(1.0, std.math.nan(f64)));
        try std.testing.expectEqual(@as(f64, 1024.0), armPow(2.0, 10.0));
        try std.testing.expectEqual(@as(f64, -8.0), armPow(-2.0, 3.0));
        try std.testing.expectEqual(@as(f64, 0.0625), armPow(-2.0, -4.0));
        try std.testing.expectEqual(@as(f64, 2.0), armPow(4.0, 0.5));
        try std.testing.expectEqual(@as(f64, 0.1), armPow(0.1, 1.0));
        try std.testing.expect(std.math.isNan(armPow(-2.0, 0.5)));
        try std.testing.expectEqual(inf, armPow(0.0, -1.0));
        try std.testing.expectEqual(-inf, armPow(-0.0, -1.0));
        try std.testing.expectEqual(@as(u64, 1 << 63), @as(u64, @bitCast(armPow(-0.0, 3.0))));
        try std.testing.expectEqual(@as(f64, 0.0), armPow(0.5, inf));
        try std.testing.expectEqual(inf, armPow(2.0, inf));
        try std.testing.expectEqual(inf, armPow(10.0, 400.0));
        try std.testing.expectEqual(@as(f64, 0.0), armPow(10.0, -400.0));
        var b: f64 = 0.013;
        while (b < 90.0) : (b *= 1.37) {
            var e: f64 = -7.3;
            while (e < 7.3) : (e += 0.61) {
                const want = std.math.pow(f64, b, e);
                // std's pow is the less accurate of the two; a few ulps apart.
                try std.testing.expect(ulps(armPow(b, e), want) <= 4);
            }
        }
    }

    test "gm exp/log agree with compiler_rt to 1 ulp; the device ports with libm" {
        // exp/log are VerA's (<= 0.52 ulp); compiler_rt's are < 1 ulp, so
        // the two may differ by one ulp, never more. The sin/cos/expm1 device
        // ports are pinned against libm so a transcription slip fails here,
        // not inside a kernel.
        var x: f64 = -700.0;
        while (x <= 700.0) : (x += 13.77) try std.testing.expect(ulps(exp(x), @exp(x)) <= 1);
        var y: f64 = 1e-30;
        while (y < 1e30) : (y *= 3.7) try std.testing.expect(ulps(log(y), @log(y)) <= 1);
        try std.testing.expectEqual(-std.math.inf(f64), log(0.0));
        try std.testing.expect(std.math.isNan(log(-1.0)));
        try std.testing.expectEqual(std.math.inf(f64), exp(710.0));
        try std.testing.expectEqual(@as(f64, 0.0), exp(-746.0));
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
///     VerA's `$simparam("dt")` (§9.15) returns it unchanged.
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

        /// The unknowns `lane` carries, one bit each: computed once per family.
        const carried: u64 = blk: {
            var c: u64 = 0;
            for (lane, 0..) |l, u| if (u < 64 and l != no_lane) {
                c |= @as(u64, 1) << @intCast(u);
            };
            break :blk c;
        };

        /// O(1) at compile time on purpose. Zig 0.16 re-evaluates this call
        /// at every call site whose return type names it (`Join`, `zOf`, so
        /// every family operation in a device), not once per mask: the
        /// 64-step check loop it replaced was 39% of psp103's `eval`
        /// object build (23.4 -> 14.3 Gi).
        pub fn Of(comptime m: u64) type {
            if (m & ~carried != 0)
                @compileError(std.fmt.comptimePrint("RefFamily: mask 0x{x} names unknown {d}, which `lane` does not carry", .{ m, @ctz(m & ~carried) }));
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

/// The pub names `validate` accepts. An enum, not a string map: `@hasField`
/// is one lookup, where building a `StaticStringMap` at comptime cost every
/// device build analysis time.
const AllowedPubDecl = enum {
    U,
    num_ports,
    contract_abi,
    Model,
    Instance,
    eval,
    q,
    evalQ,
    limit,
    limit_reads,
    limit_writes,
    deriv_reads,
    ddx_reads,
    jac_const,
    seed,
    collapse,
    collapse_full,
    initState,
    updateState,
    advanceIteration,
    checkConvergence,
    stateCtl,
    State,
    state_class,
    acceptQ,
    Setup,
    setup,
    setup_simparams,
    jac_f32,
    jac_f32_host,
    // Nothing steers on a `.val()` of an x-dependent value, draws a per-call
    // scalar, or collapses an x-dependent chain to its value.
    batch_ok,
    mutable_eval,
    noiseTablePoints,
    // §9.4 display tasks and §9.5 file I/O, one accepted-point phase (§9.5.9
    // performs file writes only at an accepted point), kept out of `eval` so
    // the residual stays a pure function of x. A device built for a solver has
    // no display phase, and its `$fopen` returns §9.5.1's failure value 0.
    display,
    file_io,
    attempt,
    u_kinds,
    u_abstol,
    u_nodeset,
    jac_pattern,
    q_pattern,
    jac_rows,
    q_rows,
    n_q,
    q_stamps,
    q_lte,
    q_site_pattern,
    noise_gens,
    noisePsd,
    noise_tables,
    ac_gens,
    acStim,
    ac_dyn_slots,
    acDyn,
    systf_calls,
    mc_param,
    derive,
    checkShape,
    precompute,
    constant,
    nextBreakpoint,
    pendingBreakpoint,
    delays,
    // Clause 12: the §5.6 contribution rows an analog VPI host reads §12.10's
    // flows from, emitted only under `codegen.Options.vpi_contribs`.
    vpiContribs,
    vpi_contrib_access,
    vpi_contrib_hi,
    vpi_contrib_lo,
    vpi_contrib_flow_u,
    lane_masks,
};

fn rejectStrayPubDecls(comptime D: type) void {
    const decls = @typeInfo(D).@"struct".decls;
    for (decls) |d| {
        if (@hasField(AllowedPubDecl, d.name)) continue;
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

/// Declares every contract member, so `AllowedPubDecl` cannot drift from
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
    comptime for (std.meta.fieldNames(AllowedPubDecl)) |k| {
        if (!@hasDecl(MockAll, k))
            @compileError("AllowedPubDecl has `" ++ k ++ "` but MockAll does not declare it");
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
