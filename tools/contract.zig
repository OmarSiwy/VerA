//! Device contract: the comptime interface every device (VA-generated or
//! hand-written) must satisfy. `validate(D)` structurally checks the surface
//! the engine calls — decls present, enum dense, param types, function arity —
//! so a mismatch fails at the device definition with a readable error.
//!
//! This contract is NORMATIVE, not descriptive: it specifies the device↔host
//! interface required to represent Verilog-AMS LRM 2.4 analog semantics, and a
//! member may be declared here before the engine consumes it. A member with no
//! LRM justification and no consumer is not a roadmap item — it is deleted.
//!
//! What is tracked, and where:
//!   - a member declared here and not yet consumed says so in ITS OWN comment,
//!     at the declaration, naming the clause that requires it. That is the only
//!     place the fact cannot drift away from;
//!   - the rules the COMPILER does not carry are the `//! xfail` lines in
//!     tests/fixtures/**.va, which the torture run prints and which FAIL the run
//!     the day they come true — a ledger that cannot go stale, unlike a table;
//!   - the ceilings the waves shipped DELIBERATELY, which no xfail line can
//!     state because no fixture fails on them, are /TODO.md;
//!   - the wave/epic history those xfails were worked off in is `git log`.
//!
//! Three earlier revisions of this header each cited a register that did not
//! exist — first a `VerA/TODO.md`, then a `tests/lrm-rules/*.tsv` with a `zig
//! build ledger` step, then a `docs/conformance-plan.md` — and a fourth claimed
//! no register existed at all, which had stopped being true: /TODO.md was
//! committed in wave 1 and is the file the first of those was reaching for.
//! Check the path before you cite it; a pointer to a file nobody can open reads
//! as evidence that the gap is tracked somewhere.
//!
//! This file CHECKS the contract, plus ONE implementation: `gm`, the
//! device-routed f64 transcendentals emitted scalar helpers call — physics
//! still never receives a scalar type from here.
//! Physics is written generic over an opaque scalar S:
//!
//!   pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, i: *const Instance, t: f64) [n_u]S;
//!   pub fn q   (comptime S: type, x, m, i, t) [n_u]S;   // optional: charges
//!
//! The engine instantiates S — a plain-f64 value form for residuals, a
//! derivative-carrying dual for the Jacobian. The S primitive set devices may
//! use: con addC scale · add sub neg mul div · exp log expm1 log1p sqrt
//! pow(a,c) · sin cos tanh sinh cosh atan · abs minC maxC min max ·
//! lt le eq sel · val.
//! expm1/log1p are primitives and not exp(x)-1 / log(1+x): §4.3.1 Table 4-14
//! names the C library forms precisely because those two compositions cancel.
//!
//! lt/le/eq (§4.2.5/§4.2.7) return an S MASK — 1.0 where the relation holds,
//! 0.0 elsewhere, PER LANE, derivative zero: a comparison is piecewise
//! constant. `sel(c, a, b)` (§4.2.12) is `a` where the mask is nonzero and
//! `b` elsewhere, carrying the winner's derivative — the same selection
//! semantics §4.3.1 gives min/max. gt/ge are operand swaps and ne swaps
//! sel's arms, so four primitives close the set. Codegen emits them ONLY for
//! a conditional that may run BOTH arms: a `.strict` unit whose arms contain
//! no call and no domain-restricted op, where a dead arm's NaN/inf is
//! IEEE-defined and the pick discards it. That buys two things — the host's
//! predictor stops eating a data-dependent branch per Newton iteration, and
//! a lane-parallel S (one operating point per lane) gets a true per-lane
//! decision where a `.val()` steer has no single answer. A conditional the
//! finiteness proof accepted only UNDER its guard (`x > 0 ? ln(x) : 0`)
//! keeps the lazy Zig `if` instead.
//!
//! THE WIDTHS INSIDE S ARE THE HOST'S, NOT THE DEVICE'S. Every member of that
//! primitive set takes and returns `f64` at the boundary — `con(f64)`,
//! `scale(f64)`, `addC(f64)`, `val() f64`, `ddxAt(usize) f64` — and physics code
//! may not open S up, so a host is free to carry the derivative half of a dual
//! in `f32` while the value half stays `f64`. That is the inexact-Newton
//! construction: the converged answer is fixed by the accuracy of the RESIDUAL,
//! and an approximate Jacobian costs iterations rather than correctness. On a
//! consumer GPU it is the whole game — sm_89 runs f32 at 69x its f64 rate.
//!
//! A device opts in with `pub const jac_f32 = true` (VerA's `--jac-f32`).
//! Absent, the host must assume f64: a model whose unknowns span more than
//! f32's ~7 digits can lose a Newton direction outright, and only the physics
//! knows that. The permission is per DEVICE for exactly that reason.
//!
//! It is a permission and NOT an order, so it is also per INSTANTIATION: a host
//! that compiles the same device twice may take it once and decline it once.
//! ESPice does exactly that — f32 in the GPU kernel, f64 on the CPU path, one
//! binary. `pub const jac_f32_host = true` (`--jac-f32-host`) is the separate,
//! stronger request that the host take it on its CPU instantiation too; it
//! implies the permission and `validate` refuses it without one.
//!
//! Optional scalar trait: `pub const collapse_applied: bool = true` promises
//! the host has applied this device's `collapse()` aliases to its gather and
//! scatter maps. Generated physics then omits the short's cancelling stamps,
//! preserving arbitrarily small conductances already in the same matrix slot.
//! Absent or false retains the full branch equations for standalone evaluation.
//!
//! RULES for physics code:
//!   - Everything not depending on x (param prep, temperature, geometry)
//!     stays plain f64. Only x-dependent chains use S ops.
//!   - Never branch on an S with `if` directly; use .val() for topology-level
//!     decisions, minC/maxC/min/max for clamps, and lt/le/eq + sel for
//!     value-form conditionals.

const std = @import("std");

/// Device-routed f64 transcendentals for the SCALAR paths of generated code
/// (`R`, the §4.5.15 limiters, zLimexp's clamp constant). Those helpers also
/// compile inside GPU kernels (the engine's StateKernel runs `D.limit` /
/// `D.updateState` on the device), and NVPTX/AMDGCN have no libm — `@exp` /
/// `@log` on an f64 die at PTX assembly with "no libcall available for
/// fexp". The host branch of every function IS the builtin (bit-identical to
/// the historical emission); the device branch is a self-contained port so
/// this file keeps zero imports (Zig's one-module-per-file rule forbids
/// reusing gompute's copy here — same musl ancestry, same <=1 ulp f64).
///
/// ponytail: exp/log/sin/cos are ported (the calls the admitted device class
/// reaches — measured off the PTX libcall errors; sin/cos joined when the
/// bjt hit tan through the StateKernel's scalar core); pow/tanh/sinh/cosh
/// are composed on them; expm1/log1p/atan stay on std.math (pure Zig). A
/// model that reaches another builtin on the device fails ITS kernel
/// compile loudly — extend `gm` then, not before.
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

    // musl exp.c / log.c ports, via gompute src/device/math.zig (measured
    // there: f64 <= 1 ulp on sm_89).
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

    // musl k_sin.c / k_cos.c and the medium branch of __rem_pio2, via
    // gompute src/device/math.zig (measured there: f64 matched glibc
    // bit-for-bit over (0,8] on sm_89).
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
        // The host branch must be indistinguishable from the historical raw
        // emission; the soft ports are pinned against libm on a physical
        // range so a transcription slip fails HERE, not inside a kernel.
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
    }
};

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

/// Accepted-state bookkeeping for FSM devices (switches). The transient
/// loop uses this to reject/retry a timestep whose converged solution flipped
/// a device state, so the discontinuity lands sharp at the crossing:
///   query  — does the working state differ from the last accepted state?
///   commit — step accepted: accepted := working
///   revert — step rejected: working := accepted
pub const StateCtlOp = enum(u8) { query, commit, revert };

/// §4.6.1 `analysis()`, Table 4-21. Host mirror of the `AnalysisKind` every
/// generated device declares for itself — the engine converts by ordinal
/// (`@enumFromInt(@intFromEnum(..))`), same trick as StateCtlOp, so the tag
/// ORDER here is load-bearing. `validateSimState` enforces the agreement
/// rather than leaving it to a comment.
pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

/// Host-owned per-pass simulation state (see `Hooks.set_sim_state`).
/// Everything here is a property of the ANALYSIS, not of the device, so the
/// host is the only writer:
///   t     — §9.10 `$abstime`, the time the solve is targeting
///   dt    — §9.10 timestep feeding `ddt`/`idt`; 0 in a static analysis, which
///           is what the generated zDdt/zIdt helpers test for
///   kind  — §4.6.1 `analysis()`
///   initial_step / final_step — §5.10.2 global events
pub const SimState = struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: AnalysisKind = .dc,
    initial_step: bool = false,
    final_step: bool = false,
};

pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

/// Host-written `Instance` fields. These are NOT decls — the host reaches them
/// by name (`@hasField`), so a typo used to be a silently-null hook rather than
/// an error; `temperature` was probed as `"temp"` for a while and was null for
/// every generated device. Presence stays optional (a hand-written resistor
/// needs none of them), but the NAME and TYPE are contract now.
///
/// `analysis_kind` additionally has to agree with `AnalysisKind` by ordinal,
/// because the host writes it with `@enumFromInt(@intFromEnum(..))`.
const SimStateField = struct { name: []const u8, T: type };
const sim_state_fields = [_]SimStateField{
    .{ .name = "temperature", .T = f64 }, // §9.15 $temperature, kelvin
    .{ .name = "abstime", .T = f64 }, // §9.10 $abstime
    .{ .name = "dt", .T = f64 }, // §9.10 timestep feeding ddt/idt
    .{ .name = "mfactor", .T = f64 }, // §9.15/E.4.1 $mfactor
    .{ .name = "is_initial_step", .T = bool }, // §5.10.2
    .{ .name = "is_final_step", .T = bool }, // §5.10.2
    .{ .name = "bound_step", .T = f64 }, // §9.17.2 $bound_step
};

/// §4.6.4 noise generator topology. Position k of `noise_gens` names one
/// generator of `kind` on the (row, col) branch.
///
/// **§4.6.4.6 correlation is the `source` field.** The clause's mechanism is
/// "using the output of one noise function for more than one noise source":
/// two rows carrying the SAME non-null `source` are one physical generator
/// contributed to two branches — perfectly correlated — while distinct values
/// (and null) are independent generators. VerA numbers sources densely in
/// first-appearance order; a hand-written device may leave the default, which
/// declares every row independent, exactly what an absent field used to mean.
/// The fixtures that grade the sharing are
/// `tests/fixtures/ch04_expressions/38_correlated_noise.va` (Example 1, one
/// shared source) and `161_partially_correlated_noise.va` (Example 2, shared +
/// unshared).
///
/// Still not expressible: the per-use scaling coefficient (`c1*n` vs `c2*n`) —
/// a `coeff` lands with the `noisePsd` hook, which is the first thing that
/// could evaluate it.
pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker },
        /// §4.6.4.6 shared-generator identity; null = independent.
        source: ?u16 = null,
    };
}

/// One generator's PSD at a given state vector, returned by the optional
/// device `noisePsd` hook (position k = noise_gens[k]):
///   S(f) = white + flicker / f^ef   [A²/Hz]
/// white: thermal 4kT·g, shot 2q|I| — the DEVICE computes it from its own
/// currents/conductances. corr_with pairs correlated generators (BSIM4
/// tnoiMod, PSP igid); real coefficient until a reference demands complex.
///
/// NOTE: this parametric form cannot express
/// §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log`, which are piecewise
/// PSD-vs-frequency. It is superseded by `noisePsd(x, m, i, f) -> [k]f64`
/// once codegen emits it; the two changes land together.
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    corr_with: ?u8 = null,
    corr: f64 = 0,
};

/// Operating-point output variable metadata. Mirrors `noise_gens`: an optional
/// comptime table a device may declare, describing internal quantities (gm,
/// gds, vth, currents, ...) it exposes for post-solve inspection. Position k
/// in `op_vars` corresponds to element k of the `opValues(...)` result. A
/// Verilog-A `(* desc=... *) real x;` module variable (§3.2.1 output
/// variables) becomes one entry.
pub const OpVar = struct {
    name: []const u8,
    units: []const u8 = "",
    desc: []const u8 = "",
};

/// §2.8.3 + §12.32: one `$name` the compiler could not resolve, which §2.8.3
/// says may be "defined using the VPI as described in Clause 11 and Clause 12".
/// Position k of `systf_calls` is what position k of `SystfHost.call` answers.
///
/// Keyed by NAME and not by call site, because that is what
/// `vpi_register_analog_systf()` registers: "the task or function name shall be
/// unique in the domain in which it is registered". Two calls to one `$name`
/// are one entry and one binding.
///
/// The name is the whole entry, and §12.32's own structure is why. Its other
/// fields — `type` (vpiAnalogSysTask/SysFunc), `sysfunctype`
/// (vpiIntFunc/vpiRealFunc), `sizetf` — are the APPLICATION's declaration of
/// what it registered, not facts a compiler that has never seen the
/// registration can report. A struct rather than a bare `[]const u8` so they
/// have somewhere to land if a host ever needs them; per this file's own rule,
/// none is added before a consumer asks.
pub const Systf = struct {
    /// `$sampnhold`, with the `$`. §12.32: "first character shall be `$`".
    name: []const u8,
};

/// The VPI application, as the device sees it. Written into `Instance.systf` by
/// the host; `validateHost` is what makes it non-optional for a device that
/// declares any `systf_calls`.
///
/// WHY VALUE-PLUS-PARTIALS AND NOT `fn (k, args: []S) S`. `eval` is generic
/// over S and gets instantiated at least twice — a plain f64 for the residual,
/// a derivative-carrying dual for the Jacobian — and a function POINTER cannot
/// be generic over S. So the boundary has to be concrete, which means the host
/// returns the value and its partials separately and the device rebuilds the
/// dual from them.
///
/// That is not a workaround: it is §12.22.1 "Derivatives for analog system
/// task/functions" and §12.32's `derivtf` / `p_vpi_stf_partials`, arrived at
/// from the opposite direction. A systf inside a contribution is inside the
/// residual, and the residual must stay a pure function of `x` or the host's
/// own Newton iteration cannot converge — which is the same invariant that
/// keeps §9.5 file I/O and `$random` out of `eval`. A value with no derivative
/// would break it; a value WITH its derivative does not.
pub const SystfHost = struct {
    /// The application's own state — `s_vpi_analog_systf_data.user_data`.
    ctx: *anyopaque,
    /// §12.32 `calltf` and §12.22.1 `derivtf` in one call. Returns the value at
    /// `args` and writes d(value)/d(args[j]) into `partials[j]`.
    ///
    /// `partials` is exactly `args.len` long and is NOT zeroed on entry: an
    /// application that leaves an entry alone is claiming a derivative it did
    /// not compute. Write every slot, zero included.
    call: *const fn (ctx: *anyopaque, k: usize, args: []const f64, partials: []f64) f64,
};

/// Rectangular complex, for the small-signal stamp. Plain struct rather than
/// std.math.Complex so the layout is fixed across the `.so` ABI boundary.
pub const Complex = struct {
    re: f64 = 0,
    im: f64 = 0,
};

/// §4.6.3 / §4.5.11 / §4.5.12 small-signal stamp topology, sparse. Position k
/// of `ac_stamps` describes element k of the `acStamp(...)` result:
///   col == null — an independent complex SOURCE on `row` (`ac_stim`)
///   col != null — a complex Jacobian entry (row, col)
///
/// This exists for exactly the responses `G + jwC` cannot represent, i.e. the
/// ones transcendental in s: `absdelay`/`transition` (e^-s·td), `zi_*`
/// (e^sT), and `ac_stim`'s phase. A RATIONAL response (`laplace_*`) does NOT
/// belong here — it is realizable as internal unknowns with real G/C, which is
/// correct in tran/ac/noise/pss/pz alike.
pub const AcStamp = struct {
    row: u8,
    col: ?u8 = null,
};

/// Result of a limiting pass. `converged` is the device's own verdict on
/// whether its clamp was significant enough to require another Newton
/// iteration — pnjlim says yes, a cosmetic fetlim/limvds clamp says no. It
/// replaces the old `limit_flag_unknowns` per-unknown table, which could only
/// answer that question positionally and could not distinguish a large clamp
/// from a small one on the same unknown.
pub fn LimitResult(comptime n: usize) type {
    return struct {
        x: [n]f64,
        converged: bool = false,
    };
}

/// Which unknowns `limit`/`seed` actually touch, as bit masks over `U`.
/// `limitReads` is every `cur`/`old` entry the body loads, `limitWrites` every
/// `x` entry it can store. Both are supersets, and both default to ALL when a
/// device does not declare them — the answer that costs performance rather
/// than correctness.
///
/// `limit`'s signature has to be `[n_u]f64` in and out, because a host cannot
/// name a device's unknowns. But a MOS ladder reads four of eight and writes
/// two: without these masks a host gathers, copies through the frame and
/// stores back the other four once per instance per Newton iterate, to arrive
/// at the value they already had. ngspice has no such traffic — its limiter
/// memory is the three branch voltages in `CKTstate0`.
///
/// THE RULE FOR A HOST: an unknown outside `limitWrites` was never written by
/// the device, so its "previously limited" value must come from the host's own
/// previous iterate, not from the plane `limit` writes into.
pub fn limitReads(comptime D: type) u64 {
    return if (@hasDecl(D, "limit_reads")) D.limit_reads else ~@as(u64, 0);
}
pub fn limitWrites(comptime D: type) u64 {
    return if (@hasDecl(D, "limit_writes")) D.limit_writes else ~@as(u64, 0);
}

/// Constant-Jacobian declaration. `g`/`c` assert that the device's dF/dx and
/// dQ/dx do not depend on x, so the engine can build the stamp once and memcpy
/// it every Newton iteration. A wrong value silently freezes the Jacobian.
pub const Constant = struct {
    g: bool = false,
    c: bool = false,
};

pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".fields.len;
}

// ============================================================================
// Validation
// ============================================================================

/// The S primitive set, as data — the header's prose list, machine-checkable.
/// Every scalar a host hands to `eval`/`q` must carry all of these;
/// `checkScalar` is the one-line way to pin an implementation to the list, so
/// a primitive added to the contract cannot silently miss a scalar (four
/// spellings exist today: R in codegen's rscalar_txt, Dual and Vec in tb.zig,
/// and whatever the embedding host brings).
pub const s_primitives = [_][]const u8{
    "con",  "addC", "scale", "add",   "sub",  "neg",  "mul",  "div",
    "exp",  "log",  "expm1", "log1p", "sqrt", "pow",  "sin",  "cos",
    "tanh", "sinh", "cosh",  "atan",  "abs",  "minC", "maxC", "min",
    "max",  "lt",   "le",    "eq",    "sel",  "val",  "ddxAt",
};

pub fn checkScalar(comptime S: type) void {
    if (@hasDecl(S, "collapse_applied") and @TypeOf(S.collapse_applied) != bool)
        @compileError(@typeName(S) ++ ": scalar collapse_applied must be bool");
    inline for (s_primitives) |p| {
        if (!@hasDecl(S, p))
            @compileError(@typeName(S) ++ ": scalar S is missing contract primitive `" ++ p ++ "`");
    }
}

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

    // Ports come first in `U` (codegen orders them that way), so num_ports is a
    // prefix length and the only real bound is `np <= n`. ZERO is legal: §6.2
    // makes the port list OPTIONAL and Annex A.1.2 admits `module identifier ;`,
    // so a device with no terminals and only internal unknowns is a well-formed
    // compilation unit. Its residual is solvable — every equation it contributes
    // is over its own private nodes — and elaboration can instantiate it as a
    // child that contributes those equations to the parent. Nothing downstream
    // needs np >= 1: the limiter mask (`u >= num_ports`) and the port/internal
    // split in codegen both degenerate correctly at 0.
    const np: usize = D.num_ports;
    if (np > n)
        @compileError(name ++ ".num_ports must be <= |U|");

    validateDefaultedStruct(D, "Model");
    validateDefaultedStruct(D, "Instance");
    validateSimState(D);

    // Physics: generic over S, so only shape-checkable. eval/q take
    // (comptime S, [n]S, *const Model, *const Instance, f64).
    validatePhysicsFn(D, "eval");
    if (@hasDecl(D, "q")) validatePhysicsFn(D, "q");

    // `evalQ` is `eval` and `q` sharing ONE model evaluation — the same five
    // parameters, returning both residuals. Fusing is the whole point, so it
    // is meaningless without a reactive half; a device that declares it
    // without `q` has a hook whose second field nothing can fill.
    if (@hasDecl(D, "evalQ")) {
        if (!@hasDecl(D, "q"))
            @compileError(name ++ ".evalQ without q: the fused entry point needs a reactive half");
        if (genericFnError(D, "evalQ", "struct { res: [n_u]S, q: [n_u]S }")) |m| @compileError(m);
    }

    // §9.4/§9.5 display phase (the clause map lives on `allowed_pub_decls`).
    // Present only in a printing artifact; when present it must be callable
    // the way tb.zig's generated runner calls it — `D.display(Dual, xd,
    // model, inst, t)` — which is `eval`'s generic shape returning void.
    //
    // §9.7 SIMULATION CONTROL RUNS INSIDE THIS PHASE AND MAY NOT RETURN. A
    // `$finish`/`$stop`/`$fatal` the model reaches terminates the PROCESS at
    // its position among the prints (`std.process.exit`; exit status 0 for
    // §9.7.1/§9.7.2, `$fatal`'s finish_number floored at 1 for §9.7.3's
    // errorcode). The signature stays `void` on purpose: both clauses tie the
    // task to the accepted point — which is exactly when a host calls this —
    // so ending the run right here IS the contract, and a return-value channel
    // would only re-encode "the process is over" for a caller that no longer
    // exists. A host that must survive its devices' §9.7 calls (an interactive
    // kernel with a real `$stop`) upgrades this to a control-code return; no
    // such host exists today, and a device built `--display=drop` contains no
    // display phase and no exit (the calls are dropped under W0850/W0851).
    if (@hasDecl(D, "display")) {
        if (genericFnError(D, "display", "void")) |m| @compileError(m);
    }

    // Optional permission, not a shape: the WIDTH of S is the host's, and this
    // only says which widths this device's physics tolerates.
    if (@hasDecl(D, "jac_f32") and @TypeOf(D.jac_f32) != bool)
        @compileError(@typeName(D) ++ ".jac_f32 must be a bool");
    // `jac_f32_host` is a request laid ON that permission — the host taking it
    // on its CPU path too, not only wherever f32 is free. Asking without the
    // permission means nothing, so it is refused here rather than silently
    // ignored by whichever host happens to read only one of the two decls.
    if (@hasDecl(D, "jac_f32_host")) {
        if (@TypeOf(D.jac_f32_host) != bool)
            @compileError(@typeName(D) ++ ".jac_f32_host must be a bool");
        if (D.jac_f32_host and !(@hasDecl(D, "jac_f32") and D.jac_f32))
            @compileError(@typeName(D) ++ ".jac_f32_host = true without jac_f32 = true");
    }

    // Voltage limiting (pnjlim/fetlim) and cold-start seeding (SPICE
    // MODEINITJCT). seed returns absolute local voltages written into a
    // zeroed x before Newton iteration 1; null leaves an unknown untouched
    // (externally driven terminals). Any device with junction limiting
    // should also declare seed — limiting from x_old = 0 is what pins
    // cold-start Newton in the wrong basin.
    // NOTE: limit corrections are only APPLIED to internal unknowns
    // (u >= num_ports) — the batch masks external writes, since a limiter
    // writing a driven/shared node fights sources and other devices.
    // seed writes are unmasked: they happen once, pre-solve, and the first
    // linear solve re-imposes every source constraint.
    if (@hasDecl(D, "limit"))
        expectFn(D, "limit", fn (*const D.Model, *const D.Instance, [n]f64, [n]f64) LimitResult(n));
    // The masks are only meaningful next to a `limit`, and `writes ⊆ reads`
    // because every corrected unknown is one the clamp read a probe from.
    for ([_][]const u8{ "limit_reads", "limit_writes" }) |m| {
        if (!@hasDecl(D, m)) continue;
        if (!@hasDecl(D, "limit")) @compileError(@typeName(D) ++ "." ++ m ++ " without a `limit`");
        if (@TypeOf(@field(D, m)) != u64) @compileError(@typeName(D) ++ "." ++ m ++ " must be a u64 mask over U");
    }
    if (@hasDecl(D, "limit_writes") and (limitWrites(D) & ~limitReads(D)) != 0)
        @compileError(@typeName(D) ++ ".limit_writes has a bit limit_reads does not");
    if (@hasDecl(D, "seed"))
        expectFn(D, "seed", fn (*const D.Model, *const D.Instance) [n]?f64);
    // Node collapse (ngspice setup): for each internal unknown, return the
    // port index it collapses onto when its separating parasitic R is 0, or
    // null to keep a private node. Consulted once at build time.
    if (@hasDecl(D, "collapse"))
        expectFn(D, "collapse", fn (*const D.Model, *const D.Instance) [n]?u8);
    // The same map with every retention flag set, comptime. A host uses it to
    // size a reduced derivative basis for the instances whose per-instance
    // `collapse` equals it, so the two invariants it relies on are checked
    // here rather than assumed: entries are fully resolved (an alias points at
    // a root, never at another alias) and point DOWNWARD (min-index root), so
    // `root[u] = collapse_full[u] orelse u` is one lookup and not a walk.
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

    // State machine: eval reads Instance, so updateState gets a MUTABLE
    // Instance — switch position etc. must live in Instance fields.
    if (@hasDecl(D, "initState") or @hasDecl(D, "updateState")) {
        if (!@hasDecl(D, "State"))
            @compileError(name ++ ": initState/updateState require pub const State");
        // initState takes a MUTABLE Instance for the §5.10 held variables: a
        // guarded variable with a parameter-dependent initializer cannot express
        // that value as a struct field default, because a default must be
        // comptime and a parameter is not. Those collapse to the parameter's
        // spec default today; this hook is the upgrade path.
        //
        // It is NOT for digital drivers, and there is no driver state anywhere in
        // this contract: no generated device has ever written a logic output
        // here. The §9.22 `$driver_*` family does not reach a device at all —
        // §9.22 confines those calls to connect modules, so lowering refuses
        // every one of them (E0818). This comment used to cite codegen's
        // hardwire-to-0 for the family as the reason, i.e. it recorded a wrong
        // answer as a design decision; the answer is gone.
        //
        // If driver access is ever supported it arrives as an OPTIONAL DECL on
        // this contract, the shape `display`, `u_abstol` and the §9.5 I/O
        // interface already use, with the HOST supplying the per-net driver list
        // — a compiler does not need a digital scheduler to ask its simulator a
        // question. Not a State field, and not this hook.
        expectFn(D, "initState", fn (*const D.Model, *D.Instance) D.State);
        expectFn(D, "updateState", fn (*const D.Model, *D.Instance, [n]f64, *D.State) UpdateResult);
        if (@hasDecl(D, "stateCtl"))
            expectFn(D, "stateCtl", fn (*const D.Model, *D.Instance, *D.State, StateCtlOp) bool);
    }

    // Convergence aids. Only the 2-arg attempt form exists — batch.zig:616
    // calls it unconditionally; a 3-arg variant would never be invoked.
    if (@hasDecl(D, "attempt"))
        expectFn(D, "attempt", fn (D.Model, f64) D.Model);

    // Optional metadata. Each is a comptime [k]T table paired with the hook
    // that fills position k — see `expectArray` / `requireWith`.
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]UnknownKind)
        @compileError(name ++ ".u_kinds must be [|U|]UnknownKind");

    // §3.6.1.2 `abstol`, per unknown: "the largest signal value that can be
    // safely ignored", declared on the NATURE bound to that net (and
    // overridable per discipline, §3.6.2.3). OPTIONAL, because it is a
    // convergence aid and not part of the residual: a host without it has to
    // invent one tolerance for every unknown, which is what a host that only
    // knows `u_kinds` does. A host that runs Newton on `eval` reads it — the
    // absolute half of the iteration's stopping test is exactly this number,
    // and it is per-unknown because a thermal net and a voltage net do not
    // agree on what "negligible" means.
    if (@hasDecl(D, "u_abstol") and @TypeOf(D.u_abstol) != [n]f64)
        @compileError(name ++ ".u_abstol must be [|U|]f64");

    // §5.6 STRUCTURAL Jacobian, one bitset per residual row: bit `cu` of
    // `jac_pattern[ru]` is set when `∂eval(x)[ru]/∂x[cu]` can be nonzero, and
    // `q_pattern` says the same for `q`. OPTIONAL and OVER-APPROXIMATE — a host
    // that does not find them assumes every entry live, which is the dense
    // n×n local Jacobian it had to assume before.
    //
    // It is worth declaring because the dense assumption is not free on either
    // side of the boundary: the host reserves a sparse-matrix entry for every
    // (row, col) a device might fill, and adds a float into every one of them
    // per instance per Newton iteration. A MOSFET fills a third of its n×n.
    //
    // Above 64 unknowns a generator should emit NEITHER — the dense fallback is
    // the correct answer and a wider bitset is not worth an ABI.
    if (@hasDecl(D, "jac_pattern") and @TypeOf(D.jac_pattern) != [n]u64)
        @compileError(name ++ ".jac_pattern must be [|U|]u64");
    if (@hasDecl(D, "q_pattern")) {
        if (@TypeOf(D.q_pattern) != [n]u64)
            @compileError(name ++ ".q_pattern must be [|U|]u64");
        if (!@hasDecl(D, "q"))
            @compileError(name ++ ".q_pattern without a `q` residual to describe");
    }

    // §5.6 which residual rows the half ever WRITES — ONE bitset, bit `ru` per
    // row, not per column. `jac_rows` describes `eval`, `q_rows` describes `q`.
    // Also optional, also over-approximate, also omitted above 64 unknowns.
    //
    // A SEPARATE declaration from the pattern, and it must stay one. The
    // pattern answers for the DERIVATIVE: `res[ru] = <term with no unknown in
    // it>` writes the row and ORs nothing into the column mask, so a clear
    // pattern row does NOT mean a clear row. `isource` ships that exact shape —
    // `jac_pattern = {0, 0}` and both rows written with the DC current — and a
    // host that inferred "row dead" from "columns dead" would delete every
    // independent current source in the netlist. On the reactive half the same
    // mistake is quieter and worse: a `ddt()` of something varying in `t` and
    // not in `x` would leave the host's per-state charge tape frozen at zero
    // for a live state and its LTE bound silently gone.
    //
    // So the containment is checked here, in the only direction that is sound:
    // every row with a live column must be a written row.
    checkRowMask(D, name, "jac_rows", "eval", n);
    checkRowMask(D, name, "q_rows", "q", n);

    // In-device noise PSDs: pure fn of ANY state vector (AC noise calls it
    // once at x_op, pnoise per PSS sample, tran-noise per step). Position k of
    // the result describes generator k. Devices without it keep the
    // thermal-off-the-Jacobian collectNoise fallback.
    expectArray(D, "noise_gens", NoiseGen(D));
    requireWith(D, "noisePsd", "noise_gens");
    if (@hasDecl(D, "noisePsd"))
        expectFn(D, "noisePsd", fn ([n]f64, *const D.Model, *const D.Instance) [D.noise_gens.len]PsdTerm);

    // Small-signal stamp: the complex contribution `G + jwC` cannot carry.
    // Sparse — `ac_stamps` is the comptime pattern, `acStamp` the values at a
    // frequency, same idiom as noise_gens/noisePsd.
    expectArray(D, "ac_stamps", AcStamp);
    requireWith(D, "ac_stamps", "acStamp");
    requireWith(D, "acStamp", "ac_stamps");
    if (@hasDecl(D, "ac_stamps")) {
        for (D.ac_stamps) |s| {
            if (s.row >= n or (s.col orelse 0) >= n)
                @compileError(name ++ ".ac_stamps: row/col out of range 0..|U|-1");
        }
        expectFn(D, "acStamp", fn ([n]f64, *const D.Model, *const D.Instance, f64) [D.ac_stamps.len]Complex);
    }

    // Operating-point output variables (§3.2.1). Position k in op_vars
    // describes element k of opValues's result. Twin metadata exactly like
    // ac_stamps/acStamp above: the table and the hook require each other in
    // BOTH directions, and the hook's shape is checked — it is generic over S
    // (the engine reads op values off whichever scalar it is holding), so the
    // check is `eval`'s, with the result sized by the table.
    expectArray(D, "op_vars", OpVar);
    requireWith(D, "op_vars", "opValues");
    requireWith(D, "opValues", "op_vars");
    if (@hasDecl(D, "opValues")) {
        if (genericFnError(D, "opValues", "[op_vars.len]S")) |m| @compileError(m);
    }

    // §2.8.3/§12.32 unresolved `$name`s. There is no device-side hook to pair
    // this table with — the implementation is the HOST's, which is the whole
    // point — so what is checked here is only that the device can be reached:
    // `eval` reads the binding off `Instance`, so a device that names a systf
    // and has nowhere to read it from could not be built at all. `validateHost`
    // is the other half, and the host is what calls it.
    expectArray(D, "systf_calls", Systf);
    if (@hasDecl(D, "systf_calls") and D.systf_calls.len != 0) {
        if (!@hasField(D.Instance, "systf"))
            @compileError(name ++ ": declares systf_calls but Instance has no `systf` field " ++
                "for the host to bind — see contract.SystfHost");
        if (@FieldType(D.Instance, "systf") != ?*const SystfHost)
            @compileError(name ++ ".Instance.systf must be `?*const contract.SystfHost`");
    }

    validateMcParam(D);

    // LRM 6.3.4 / 3.4.5: parameters whose value is an expression over OTHER
    // parameters, plus every localparam. The Model is a flat struct, so a host
    // write to a base parameter cannot reach what was declared over it; the
    // host closes that gap by calling `derive` once, after it finishes writing
    // the card and before it builds an Instance. Absent when the module has no
    // such parameter, which is the common case — a literal default is still
    // just a field initializer.
    if (@hasDecl(D, "derive"))
        expectFn(D, "derive", fn (*D.Model) void);

    // precompute: instance-mutating parameter prep before solve.
    if (@hasDecl(D, "precompute"))
        expectFn(D, "precompute", fn (*D.Instance, *const D.Model) void);

    // Constant-Jacobian declaration.
    if (@hasDecl(D, "constant") and @TypeOf(D.constant) != Constant)
        @compileError(name ++ ".constant must be contract.Constant");

    // Breakpoint scheduling for piecewise sources.
    if (@hasDecl(D, "nextBreakpoint"))
        expectFn(D, "nextBreakpoint", fn (*const D.Model, f64) ?f64);
    // §4.5.7 transport delays (absdelay sites), model-frame like
    // nextBreakpoint: the host echoes wavefront breakpoints from these.
    if (@hasDecl(D, "delays")) {
        const R = @typeInfo(@TypeOf(D.delays)).@"fn".return_type.?;
        if (@typeInfo(R) != .array or @typeInfo(R).array.child != f64)
            @compileError(@typeName(D) ++ ".delays: must return [n]f64");
        expectFn(D, "delays", fn (*const D.Model) R);
    }

    // Pub-decl allowlist: only contract-recognized names may be pub.
    rejectStrayPubDecls(D);
}

/// The other half of `validate`, and the only check aimed at the HOST rather
/// than the device. A simulator embedding VerA calls it once per device it
/// links, beside `validate(D)`.
///
/// `validate(D)` cannot ask this. It runs where the DEVICE is defined, and at
/// that point the host does not exist yet — a `.va` compiled to a `.so` does
/// not know which simulator will load it. So the requirement "somebody must
/// implement this" can only be enforced where the two meet, which is here.
///
/// WHAT IT REFUSES, and why that is the right severity. A device declaring
/// `systf_calls` contains a `$name` whose value is the application's to supply.
/// With no binding there is no value — not a wrong one, an absent one — and the
/// residual would read a number nothing computed. §12.32.3's own sampnhold
/// listing never initializes `sampler->value` before its first update callback,
/// so the language fixes no default to fall back to. Failing the host's build
/// is the only outcome that cannot be mistaken for a working device.
///
/// `vera`'s own testbench binds a stub rather than being exempt from this — see
/// `src/backend/tb.zig`. An exemption for the tool's own host is how a seam
/// stops being tested.
pub fn validateHost(comptime H: type, comptime D: type) void {
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
    .{ "Model", {} },
    .{ "Instance", {} },
    .{ "eval", {} },
    .{ "q", {} },
    // Both residuals from one core evaluation; see `validate`'s pair rule.
    .{ "evalQ", {} },
    .{ "limit", {} },
    // The two live-set masks over `U` that go with it — see `limitReads`.
    // Optional; a device without them reads as "every unknown", which is the
    // behaviour every host had before they existed.
    .{ "limit_reads", {} },
    .{ "limit_writes", {} },
    .{ "seed", {} },
    .{ "collapse", {} },
    // The same alias map with every retention flag set, at comptime — see the
    // `collapse_full` block in `validate`.
    .{ "collapse_full", {} },
    .{ "initState", {} },
    .{ "updateState", {} },
    .{ "stateCtl", {} },
    .{ "State", {} },
    // Single-precision-Jacobian permission — checked inline in `validate` (the
    // "`jac_f32` must be a bool" guard); the S note in the header is the story.
    // Optional; absent means f64, which is the default a host must assume.
    .{ "jac_f32", {} },
    // ...and the host-side request laid on it (`--jac-f32-host`). Checked in
    // `validate` beside the permission, which it implies.
    .{ "jac_f32_host", {} },
    // Lane-parallel permission: eval/q instantiated with a vector S (one
    // operating point per lane) is exact per lane — no `.val()` steering, no
    // per-call scalar draw, no value-collapsing helper on an x-dependent
    // chain. Emitted by codegen only when nothing in the device pinned lanes;
    // the generated testbench's batch differential check asserts the claim on
    // every fixture that carries it. Absent means batching is NOT sound.
    .{ "lane_clean", {} },
    // The CORE (physics units) reads a host-published sim-state Instance
    // field (analysis()/$abstime/ddt-family `inst.dt` and friends). A host
    // that keeps Instance blobs device-resident republishes those fields on
    // the HOST copy only, so such a core must not run device-resident
    // (ARPice engine.gpuEligible keys off this). Emitted by codegen from a
    // scan of exactly the unit range; the updateState epilogue's
    // `state.t_prev = inst.abstime` latch does not count — nothing in the
    // core reads it back.
    .{ "core_reads_simstate", {} },
    // Runtime analysis kind exported by generated devices for the analysis()
    // builtin; the host engine sets Instance.analysis_kind per pass. Its
    // ordinals are checked against `AnalysisKind` by `validateSimState`.
    .{ "AnalysisKind", {} },
    // LRM 9.4 display tasks AND LRM 9.5 file I/O: the device's per-accepted-point
    // SIDE-EFFECT phase, and the whole of the optional I/O interface a host may
    // provide. Present ONLY in a device built with `--display=emit` (FastVAF's
    // testbench artifact); the engine never calls it, and a device compiled for
    // the solver does not have it at all.
    //
    // One decl for both clauses, because they are one phase. §9.5.2 defines its
    // output tasks as §9.4.1's "with one additional argument, which is either a
    // multichannel descriptor or a file descriptor", and §9.5.9 puts every file
    // write at the ACCEPTED point — "if a file is being written to during an
    // iterative solve, then the file write operations shall not be performed
    // unless the iteration is accepted. The exception to this is the $fdebug". So
    // the descriptor operations are sequenced here, in source order, with the
    // prints, and NOT in `eval`: a residual has to stay a pure function of x or
    // the host's Newton iteration cannot converge, and an open, a read position
    // and an appended line are none of them.
    //
    // A host that declines to call this gets the DEGRADED path, and that path is
    // conformant rather than a fudge. §9.5.1 reserves 0 as $fopen's failure
    // return; a device whose host offers no file table genuinely cannot open a
    // file, so 0 is the correct answer and every later operation on it is a
    // no-op with a defined result (§9.5.4.1's "code is set to zero", §9.5.7's
    // zero errno with an empty description, §9.5.8's zero).
    //
    // This is NOT part of the Kernel ABI and must not become part of it: nothing
    // in `Instance` holds a descriptor, and `eval`/`q` cannot reach a file at all.
    .{ "display", {} },
    .{ "attempt", {} },
    .{ "u_kinds", {} },
    .{ "u_abstol", {} },
    .{ "jac_pattern", {} },
    .{ "q_pattern", {} },
    // Which residual rows each half ever writes — one u64 of row bits, the
    // companion the pattern deliberately cannot substitute for. See
    // `checkRowMask` and its call site in `validate`.
    .{ "jac_rows", {} },
    .{ "q_rows", {} },
    .{ "noise_gens", {} },
    .{ "noisePsd", {} },
    .{ "ac_stamps", {} },
    .{ "acStamp", {} },
    .{ "op_vars", {} },
    .{ "opValues", {} },
    // §2.8.3/§12.32 the `$name`s left to a VPI application. Pub because the
    // HOST reads it — to know what it has to bind, and `validateHost` to refuse
    // when it has not.
    .{ "systf_calls", {} },
    .{ "mc_param", {} },
    .{ "derive", {} },
    .{ "precompute", {} },
    .{ "constant", {} },
    .{ "nextBreakpoint", {} },
    .{ "delays", {} },
});

fn rejectStrayPubDecls(comptime D: type) void {
    const decls = @typeInfo(D).@"struct".decls;
    for (decls) |d| {
        if (allowed_pub_decls.has(d.name)) continue;
        // <module>__analog_op__{laplace,zi}_*__sec — the cascade coefficients of
        // an LRM 4.5.11/4.5.12 filter. Public on purpose: they ARE the transfer
        // function, and a host running .ac/.noise would have to build H(jw)
        // from them because the real-valued residual cannot carry it. The name
        // embeds the module, so it cannot be in the list above.
        //
        // NOTE (§4.5.11/12): this exemption is
        // scheduled for removal. `laplace_*` is rational and belongs in the
        // matrix as internal unknowns; `zi_*` is transcendental and belongs in
        // `acStamp`. Neither needs a public coefficient table. The exemption
        // stays only until codegen stops emitting it — VerA's own fixtures
        // (066_laplace_dc_gain, 067_zi_sample_hold, 23_laplace_filters,
        // 24_z_transform_filters) depend on it today.
        // ponytail: the exemption is suffix-only; endsWith owns the length guard.
        if (std.mem.endsWith(u8, d.name, "__sec")) continue;
        @compileError(@typeName(D) ++ ": stray pub decl `" ++ d.name ++
            "` — only contract-recognized names may be pub");
    }
}

/// eval/q: fn (comptime S: type, [n]S, *const Model, *const Instance, f64) [n]S.
/// Generic over S, so the concrete signature is checked by instantiation:
/// here only arity + comptime-type first param.
fn validatePhysicsFn(comptime D: type, comptime fn_name: []const u8) void {
    if (genericFnError(D, fn_name, "[n_u]S")) |m| @compileError(m);
}

/// The shape shared by every generic-over-S entry point (`eval`, `q`,
/// `opValues`, `display`): five parameters, the first `comptime S: type`.
/// `ret` only names the expected result in the complaint — a generic return
/// cannot be checked without instantiating. Returns the message instead of
/// raising it so the NEGATIVE half is testable; `validate` is the raiser.
fn genericFnError(comptime D: type, comptime fn_name: []const u8, comptime ret: []const u8) ?[]const u8 {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != 5 or info.@"fn".params[0].type != type)
        return @typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, [n_u]S, *const Model, *const Instance, f64) " ++ ret;
    return null;
}

fn expectFn(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(D, fn_name))
        @compileError(@typeName(D) ++ ": missing " ++ fn_name);
    if (@TypeOf(@field(D, fn_name)) != Expected)
        @compileError(@typeName(D) ++ "." ++ fn_name ++ ": expected " ++ @typeName(Expected));
}

/// Optional comptime `[k]Child` metadata table. No-op when absent — every
/// caller is "if you declare it, it must be this shape".
fn expectArray(comptime D: type, comptime decl: []const u8, comptime Child: type) void {
    if (!@hasDecl(D, decl)) return;
    const info = @typeInfo(@TypeOf(@field(D, decl)));
    if (info != .array or info.array.child != Child)
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be [k]" ++ @typeName(Child));
}

/// `jac_rows` / `q_rows`: one u64, bit `ru` set when residual half `half` ever
/// writes `res[ru]`. Optional. Checked here rather than inline because both
/// halves want the identical four rules, the last of which is the one that
/// matters — a row with a live Jacobian column is unarguably a written row, so
/// the mask must contain the pattern's nonzero rows. (The converse is exactly
/// what must NOT be assumed; see the note at the call site.)
fn checkRowMask(
    comptime D: type,
    comptime name: []const u8,
    comptime decl: []const u8,
    comptime half: []const u8,
    comptime n: usize,
) void {
    if (rowMaskError(D, name, decl, half, n)) |m| @compileError(m);
}

/// The testable half — see `genericFnError` for why the message is returned
/// rather than raised. The containment test is the interesting one and it runs
/// in ONE direction only: a row with a live pattern column must be marked
/// written, never the reverse.
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

/// `decl` is meaningless without `needs` — a table with no hook to fill it, or
/// a hook with no table to describe it. Declare it both ways for a pair that
/// is mutually required (ac_stamps/acStamp, op_vars/opValues).
fn requireWith(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) void {
    if (requireWithError(D, decl, needs)) |m| @compileError(m);
}

/// The testable half of `requireWith` — see `genericFnError` for why the
/// message is returned rather than raised.
fn requireWithError(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) ?[]const u8 {
    if (@hasDecl(D, decl) and !@hasDecl(D, needs))
        return @typeName(D) ++ ": `" ++ decl ++ "` requires `" ++ needs ++ "`";
    return null;
}

/// A numeric parameter field of either width. BOTH are live: this generator
/// emits `f64` parameters, while a device written by hand straight against this
/// contract may still declare `f32`. The host reaches them through a tagged
/// `ParamRef`, so neither width is privileged here either.
fn hasFloatField(comptime T: type, comptime name: []const u8) bool {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and (f.type == f32 or f.type == f64)) return true;
    }
    return false;
}

/// The host-written `Instance` fields (see `sim_state_fields`). Presence is
/// optional; the name and type are not. Without this check a renamed or
/// retyped field is a silently-null hook — `$abstime` pins to 0 and every
/// waveform in the circuit collapses to its t=0 value with no diagnostic.
fn validateSimState(comptime D: type) void {
    const name = @typeName(D);
    for (sim_state_fields) |f| {
        if (!@hasField(D.Instance, f.name)) continue;
        if (@FieldType(D.Instance, f.name) != f.T)
            @compileError(name ++ ".Instance." ++ f.name ++ ": host-written field must be " ++
                @typeName(f.T));
    }

    if (!@hasField(D.Instance, "analysis_kind")) return;
    const K = @FieldType(D.Instance, "analysis_kind");
    if (@typeInfo(K) != .@"enum")
        @compileError(name ++ ".Instance.analysis_kind must be an enum");
    // The host writes this field with @enumFromInt(@intFromEnum(host_kind)),
    // so the device's tag ORDER is load-bearing, not just its tag set.
    const want = @typeInfo(AnalysisKind).@"enum".fields;
    const got = @typeInfo(K).@"enum".fields;
    if (got.len != want.len)
        @compileError(name ++ ".Instance.analysis_kind: enum must have exactly " ++
            std.fmt.comptimePrint("{d}", .{want.len}) ++ " tags, matching contract.AnalysisKind");
    for (want, got) |w, g| {
        if (!std.mem.eql(u8, w.name, g.name) or w.value != g.value)
            @compileError(name ++ ".Instance.analysis_kind: tag `" ++ g.name ++
                "` must be `" ++ w.name ++ "` at the same ordinal — the host converts by ordinal");
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
    // Generated string parameters point at immutable literals in the device
    // image. The loader keeps that .so open for the lifetime of every opaque
    // Model blob, so copying the slice through init_model/ProtoStore is safe;
    // numeric setParam/collectParams intentionally ignore it.
    if (T == []const u8) return true;
    // The VPI binding (§2.8.3/§12.32), and the only pointer INTO THE HOST this
    // rule admits. It is not POD and is deliberately not treated as such: the
    // host writes it, the host owns what it points at, and the device only ever
    // calls through it. Nothing copies an `Instance` across a process boundary —
    // the `.so` seam copies `Model` blobs, which is what the rule above is
    // about — so a host-lifetime pointer here outlives every use of it.
    //
    // Named rather than admitted by shape: `isValueType` returning true for
    // pointers in general would let a device hold one in `Model`, which the
    // loader DOES copy, and that is the bug this whole check exists to stop.
    if (T == ?*const SystfHost) return true;
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        // Integer-backed enums are fixed-size POD (e.g. Instance.analysis_kind).
        .@"enum" => |e| isValueType(e.tag_type),
        .array => |a| isValueType(a.child),
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

/// Optional per-device declaration: `pub const mc_param = "resist";`
/// Names the principal value parameter (Instance or Model float field) that
/// Monte Carlo varies. Validated here so a typo fails at compile time.
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
    const n_u = nU(@This());

    pub const Model = struct {
        g: f64 = 1e-3,
    };

    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const ir = x[0].sub(x[1]).scale(model.g);
        return .{ ir, ir.neg() };
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

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64) [n_u]S {
        const g = if (inst.closed) model.gon else model.goff;
        const ir = x[0].sub(x[1]).scale(g);
        return .{ ir, ir.neg() };
    }

    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }

    pub fn updateState(_: *const Model, inst: *Instance, x: [n_u]f64, s: *State) UpdateResult {
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

    pub fn limit(_: *const Model, _: *const Instance, x_new: [n_u]f64, _: [n_u]f64) LimitResult(n_u) {
        return .{ .x = x_new, .converged = true };
    }
};

const MockTline = struct {
    const Self = @This();

    pub const U = enum(u8) { p1, p2 };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    // A generated device declares its own mirror of contract.AnalysisKind; the
    // host converts by ordinal, so the order must match exactly.
    pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

    pub const Model = struct {
        z0: f32 = 50,
        td: f32 = 1e-9,
    };

    pub const Instance = struct {
        // Host-written; name and type are contract (see sim_state_fields).
        abstime: f64 = 0,
        dt: f64 = 0,
        bound_step: f64 = std.math.inf(f64),
        analysis_kind: Self.AnalysisKind = .dc,
    };

    pub const mc_param = "z0";
    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    pub const noise_gens = [_]NoiseGen(@This()){.{ .row = 0, .col = 1, .kind = .thermal }};

    // e^-s·td is transcendental: G + jwC cannot carry it, so the delay's
    // small-signal response comes through the stamp.
    pub const ac_stamps = [_]AcStamp{
        .{ .row = 0, .col = 1 },
        .{ .row = 1, .col = 0 },
    };

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ x[0].scale(y0), x[1].scale(y0) };
    }

    pub fn acStamp(_: [n_u]f64, model: *const Model, _: *const Instance, f: f64) [ac_stamps.len]Complex {
        const w = 2.0 * std.math.pi * f;
        const th = -w * @as(f64, model.td);
        const y0 = 1.0 / @as(f64, model.z0);
        const e: Complex = .{ .re = @cos(th) * y0, .im = @sin(th) * y0 };
        return .{ e, e };
    }
};

/// Declares EVERY contract member. Exists so `allowed_pub_decls` cannot drift
/// out of sync with `validate` — a member validate knows about but the
/// allowlist does not is a `stray pub decl` compile error right here, and a
/// member in neither is one this device fails to declare. It is the only place
/// the full surface is exercised at once.
const MockAll = struct {
    const Self = @This();
    const n_u = nU(@This());

    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };
    pub const State = struct { flips: u32 = 0 };
    pub const jac_f32 = true;
    pub const jac_f32_host = true;
    pub const lane_clean = true;
    pub const core_reads_simstate = true;

    pub const Model = struct { g: f32 = 1e-3 };
    pub const Instance = struct {
        temperature: f64 = 300.15,
        abstime: f64 = 0,
        dt: f64 = 0,
        mfactor: f64 = 1,
        analysis_kind: Self.AnalysisKind = .dc,
        is_initial_step: bool = false,
        is_final_step: bool = false,
        bound_step: f64 = std.math.inf(f64),
        systf: ?*const SystfHost = null,
    };

    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    // §3.6.1.2 electrical potential's abstol, both unknowns being voltages.
    pub const u_abstol = [n_u]f64{ 1e-6, 1e-6 };
    pub const mc_param = "g";
    pub const constant: Constant = .{ .g = true };
    pub const noise_gens = [_]NoiseGen(Self){.{ .row = 0, .col = 1, .kind = .thermal }};
    pub const ac_stamps = [_]AcStamp{ .{ .row = 0, .col = 1 }, .{ .row = 1 } };
    pub const op_vars = [_]OpVar{.{ .name = "gd", .units = "S" }};
    pub const systf_calls = [_]Systf{.{ .name = "$sampnhold" }};
    // The over-approximate masks, plus their row-level companions. All-ones is
    // what a host must assume when a device omits them, so it is also the value
    // that cannot be wrong here — this guard is about the ALLOWLIST not
    // drifting, and these had drifted out of it: `jac_pattern`/`q_pattern` were
    // allowlisted with nothing declaring them, so the guard had been failing to
    // COMPILE rather than failing loudly.
    //
    // `q` is diagonal here, which is the point of keeping it narrower than
    // all-ones: the interesting case is a row written with an EMPTY column
    // mask (`isource`), and `checkRowMask` only rejects the reverse — live
    // columns on a row not marked written.
    pub const jac_pattern = [n_u]u64{ 0b11, 0b11 };
    pub const q_pattern = [n_u]u64{ 0b01, 0b10 };
    pub const jac_rows: u64 = 0b11;
    pub const q_rows: u64 = 0b11;
    pub const limit_reads: u64 = 0b11;
    pub const limit_writes: u64 = 0b11;

    pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, _: *const Instance, _: f64) [n_u]S {
        const i = x[0].sub(x[1]).scale(@as(f64, m.g));
        return .{ i, i.neg() };
    }
    pub fn evalQ(comptime S: type, x: [n_u]S, m: *const Model, i: *const Instance, t: f64) struct { res: [n_u]S, q: [n_u]S } {
        return .{ .res = eval(S, x, m, i, t), .q = q(S, x, m, i, t) };
    }
    pub fn q(comptime S: type, x: [n_u]S, _: *const Model, _: *const Instance, _: f64) [n_u]S {
        return .{ x[0].scale(1e-12), x[1].scale(-1e-12) };
    }
    pub fn opValues(comptime S: type, _: [n_u]S, m: *const Model, _: *const Instance, _: f64) [op_vars.len]S {
        return .{S.con(@as(f64, m.g))};
    }
    pub fn limit(_: *const Model, _: *const Instance, cur: [n_u]f64, _: [n_u]f64) LimitResult(n_u) {
        return .{ .x = cur, .converged = true };
    }
    pub fn seed(_: *const Model, _: *const Instance) [n_u]?f64 {
        return .{ 0.6, null };
    }
    pub fn collapse(_: *const Model, _: *const Instance) [n_u]?u8 {
        return .{ null, null };
    }
    pub const collapse_full: [n_u]?u8 = .{ null, 0 };
    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }
    pub fn updateState(_: *const Model, _: *Instance, _: [n_u]f64, s: *State) UpdateResult {
        s.flips += 1;
        return .ok;
    }
    pub fn stateCtl(_: *const Model, _: *Instance, _: *State, _: StateCtlOp) bool {
        return false;
    }
    pub fn attempt(m: Model, lambda: f64) Model {
        var out = m;
        out.g *= @floatCast(lambda);
        return out;
    }
    pub fn noisePsd(_: [n_u]f64, m: *const Model, _: *const Instance) [noise_gens.len]PsdTerm {
        return .{.{ .white = 4 * 1.38e-23 * 300.15 * @as(f64, m.g) }};
    }
    pub fn acStamp(_: [n_u]f64, _: *const Model, _: *const Instance, _: f64) [ac_stamps.len]Complex {
        return .{ .{}, .{} };
    }
    pub fn derive(_: *Model) void {}
    pub fn precompute(_: *Instance, _: *const Model) void {}
    pub fn nextBreakpoint(_: *const Model, _: f64) ?f64 {
        return null;
    }
    pub fn delays(_: *const Model) [1]f64 {
        return .{1e-9};
    }
    /// The shape tb.zig's generated runner actually calls — `D.display(Dual,
    /// xd, model, inst, t)` — and codegen emits: `pub fn display(comptime S:
    /// type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64)
    /// void`. This used to be a 2-arg `(Model, Instance)` fn, which no caller
    /// anywhere has ever used; `validate` now refuses that shape.
    pub fn display(comptime S: type, _: [n_u]S, _: *const Model, _: *const Instance, _: f64) void {}
};

test "validate: minimal resistor" {
    comptime validate(MockR);
}

test "validate: every contract member at once (allowlist cannot drift)" {
    comptime validate(MockAll);
    // Every allowlisted name is either declared above or is a required decl
    // MockAll already has — so an entry added to one and not the other fails.
    comptime for (allowed_pub_decls.keys()) |k| {
        if (!@hasDecl(MockAll, k))
            @compileError("allowed_pub_decls has `" ++ k ++ "` but MockAll does not declare it");
    };
}

test "op_vars/opValues are twins: each half is refused without the other" {
    // The mirror of ac_stamps/acStamp. A hook with no table has positions
    // nothing describes; a table with no hook describes values nothing fills.
    const OnlyHook = struct {
        pub fn opValues() void {}
    };
    const OnlyTable = struct {
        pub const op_vars = [_]OpVar{.{ .name = "gm" }};
    };
    try testing.expect(comptime (requireWithError(OnlyHook, "opValues", "op_vars") != null));
    try testing.expect(comptime (requireWithError(OnlyTable, "op_vars", "opValues") != null));
    // MockAll declares both halves, so neither direction complains.
    try testing.expect(comptime (requireWithError(MockAll, "op_vars", "opValues") == null));
    try testing.expect(comptime (requireWithError(MockAll, "opValues", "op_vars") == null));
}

test "display/opValues shapes: the generic 5-param form, wrong arities refused" {
    // The exact shape that used to slip through: MockAll's display was a
    // 2-arg `(Model, Instance)` fn no caller has ever used — tb.zig calls
    // `D.display(Dual, xd, model, inst, t)`, and a device declaring the
    // 2-arg form fails in the RUNNER's build, three cache steps from the
    // device that caused it. Refused at the definition instead.
    const Bad = struct {
        pub const Model = struct {};
        pub const Instance = struct {};
        pub fn display(_: *const Model, _: *const Instance) void {}
        pub fn opValues(_: f64) f64 {
            return 0;
        }
        pub fn eval(_: f64) void {} // not generic: first param is not `type`
    };
    try testing.expect(comptime (genericFnError(Bad, "display", "void") != null));
    try testing.expect(comptime (genericFnError(Bad, "opValues", "[op_vars.len]S") != null));
    try testing.expect(comptime (genericFnError(Bad, "eval", "[n_u]S") != null));
    // The real shapes pass: MockAll.display mirrors codegen's emitted decl,
    // MockAll.opValues mirrors eval.
    try testing.expect(comptime (genericFnError(MockAll, "display", "void") == null));
    try testing.expect(comptime (genericFnError(MockAll, "opValues", "[op_vars.len]S") == null));
    try testing.expect(comptime (genericFnError(MockAll, "eval", "[n_u]S") == null));
}

test "jac_rows: an empty pattern row may still be written; a live one may not be unwritten" {
    // `isource`'s shape, and the whole reason the declaration exists: the DC
    // current depends on no unknown, so both column masks are empty while both
    // rows are written. A host that inferred "row dead" from "columns dead"
    // would delete it — so this direction has to stay legal.
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

test "validateHost: a systf is the host's to bind, and only when there is one" {
    // MockR names no `$name`, so any host will do — including one that has
    // never heard of VPI. That is the common case and it must stay free.
    comptime validateHost(struct {}, MockR);

    // MockAll calls `$sampnhold`, so a host linking it must answer for it.
    const Sim = struct {
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

    // The value-plus-partials boundary reassembles into a dual: a term is
    // `p_j * (arg_j - arg_j.val())`, whose VALUE is zero and whose DERIVATIVE
    // is p_j·d(arg_j), so adding it to `S.con(v)` grafts the host's partial on
    // without disturbing the value. Checked here on the plain-f64 side, where
    // every such term must vanish exactly.
    var partials: [1]f64 = .{7.5};
    const v = Sim.app.call(Sim.app.ctx, 0, &.{0.25}, &partials);
    try std.testing.expectEqual(@as(f64, 0), v);
    try std.testing.expectEqual(@as(f64, 0), partials[0]); // written, not left at 7.5
}

/// §6.2's optional port list, in device form: no terminals, one internal
/// unknown. This is what tests/fixtures/ch06_hierarchy/module_definition.va
/// lowers to (`module m; electrical p; analog I(p) <+ V(p); endmodule`), and it
/// used to be a `num_ports must be in 1..|U|` compile error — a stale guard that
/// predated the host being able to Newton-solve a device's private nodes.
const MockNoPorts = struct {
    pub const U = enum(u8) { p };
    pub const num_ports: usize = 0;
    const n_u = nU(@This());

    pub const Model = struct { g: f64 = 1.0 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        return .{x[0].scale(model.g)};
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
    _ = MockSw.updateState(&m, &inst, .{ 1.0, 0.0 }, &s);
    try testing.expect(inst.closed);
    try testing.expectEqual(@as(u32, 1), s.flips);
}

test "limit reports its own convergence verdict" {
    const m: MockSw.Model = .{};
    const i: MockSw.Instance = .{};
    const r = MockSw.limit(&m, &i, .{ 1.0, 0.0 }, .{ 0.0, 0.0 });
    try testing.expect(r.converged);
    try testing.expectEqual(@as(f64, 1.0), r.x[0]);
}

test "acStamp carries the delay phase G+jwC cannot" {
    const m: MockTline.Model = .{};
    const i: MockTline.Instance = .{};
    // At f = 1/(4*td) the delay is a quarter period: e^-j(pi/2) -> -j.
    const s = MockTline.acStamp(.{ 0, 0 }, &m, &i, 0.25 / @as(f64, m.td));
    try testing.expectApproxEqAbs(@as(f64, 0), s[0].re, 1e-12);
    try testing.expectApproxEqAbs(-1.0 / @as(f64, m.z0), s[0].im, 1e-12);
}

test "nU" {
    try testing.expectEqual(@as(comptime_int, 2), comptime nU(MockR));
}
