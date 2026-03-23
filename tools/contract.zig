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
/// are composed on them; log1p stays on std.math (pure Zig). A model that
/// reaches another builtin on the device fails ITS kernel compile loudly —
/// extend `gm` then, not before.
///
/// expm1/atan were on that "pure Zig, leave them" list and should not have
/// been. They need no libcall, so NVPTX takes them — but both raise the
/// subnormal underflow flag through `std.mem.doNotOptimizeAway`, which for a
/// float is `asm volatile ("" :: "rm" (v))`, and AMDGPU cannot match the `m`
/// alternative. So the loud failure the paragraph above relies on is
/// AMD-only, and reads `Could not match memory address. Inline asm failure!`
/// rather than naming a function. A CUDA-only test matrix says nothing about
/// it. Both are here now.
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
    /// Needs no libcall, and STILL does not compile for AMDGCN: std's port
    /// raises the subnormal underflow flag through `std.mem.doNotOptimizeAway`,
    /// which for a float is `asm volatile ("" :: "rm" (v))`, and the AMDGPU
    /// backend cannot match the `m` alternative. It assembles to PTX without
    /// complaint, so the hole is AMD-only and an NVIDIA box never sees it.
    ///
    /// The device branch is std's own algorithm with that one line dropped. It
    /// set a flag no GPU exposes to read, so every returned value is identical.
    pub inline fn expm1(x: f64) f64 {
        return if (comptime dev) softExpm1(x) else std.math.expm1(x);
    }
    /// Same AMDGCN hole as `expm1`, cheaper dodge: `std.math.atan` carries a
    /// vector path that never reaches the idiom.
    ///
    /// TWO lanes, and the width is the point — `@Vector(1, f64)` does not fail
    /// to select, it SEGVs the compiler. The second result is discarded, so
    /// device `atan` costs twice what it should; port std's `atanBinary64`
    /// minus its one bad line if that ever reaches a profile. The host branch
    /// stays the scalar body, so host emission is bit-identical to before.
    pub inline fn atan(x: f64) f64 {
        if (comptime !dev) return std.math.atan(x);
        const v: @Vector(2, f64) = @splat(x);
        return std.math.atan(v)[0];
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

    /// musl expm1.c, by way of `std.math.expm1`, minus its one
    /// `doNotOptimizeAway` — see `expm1` above.
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
        try std.testing.expectEqual(std.math.expm1(0.7), expm1(0.7));
        try std.testing.expectEqual(std.math.atan(0.7), atan(0.7));

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

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

/// What a device carries across accepted points, declared as `state_class` so
/// a host's GPU gate reads one decl instead of inferring it from field shapes.
///   none       — no `State`/`updateState` at all.
///   path_latch — only the §5.6.1.2 path latches: `updateState` stages
///                `wb`/`wq`, `stateCtl(.commit)` latches them; no operator
///                history, no held FSM, no §9.13.1 seed.
///   history    — anything else `updateState` advances.
/// A device without the decl is `history` when it has `updateState` and `none`
/// otherwise — the safe reading for a host that predates it.
pub const StateClass = enum { none, path_latch, history };

pub fn stateClass(comptime D: type) StateClass {
    if (@hasDecl(D, "state_class")) return D.state_class;
    return if (@hasDecl(D, "updateState")) .history else .none;
}

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
    // §9.12 / IEEE 1364 §17.10 the command line's arguments, verbatim and in
    // order (`argv[1..]`); only `+` entries are plusargs. Emitted only by a
    // device that calls $test$plusargs/$value$plusargs; a host that never
    // writes it leaves `&.{}`, i.e. "no plusargs", and every search answers 0.
    .{ .name = "plusargs", .T = []const [:0]const u8 },
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
/// The per-use scaling coefficient (`c1*n` vs `c2*n`) landed where this note
/// said it would: `PsdTerm.coeff`, because it can depend on the bias and only
/// the `noisePsd` hook is evaluated at one.
///
/// §4.6.4.3/.4 `noise_table`/`noise_table_log` are the `table` kind, and their
/// PSD is `noise_tables[table.?]` rather than anything `noisePsd` can return —
/// see `NoiseTable`. The tag is APPENDED, so every existing ordinal and every
/// existing row is unchanged, and a host that switches on `kind` gets a
/// compile error at the new tag rather than a silent mis-read: a table
/// generator answered as `.thermal` would be handed to a 4kT·g fallback whose
/// answer has nothing to do with the table.
pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker, table },
        /// §4.6.4.6 shared-generator identity; null = independent.
        source: ?u16 = null,
        /// §4.6.4.3/.4 index into the device's `noise_tables`. Non-null exactly
        /// when `kind == .table`; `validate` checks both halves.
        table: ?u16 = null,
        /// §4.6.4.1/.2/.3 the optional `name` argument, empty when the model
        /// supplied none. "The optional name argument acts as a label for the
        /// noise source used when the simulator outputs the individual
        /// contribution of each noise source to the total output noise. The
        /// contributions of noise sources with the same name from the same
        /// instance of a module are combined in the noise contribution
        /// summary."
        ///
        /// Combined IN THE SUMMARY — a host groups its REPORT by this string.
        /// It is not correlation and not identity: §4.6.4.6 makes every
        /// separate call an uncorrelated generator, so two rows may share a
        /// name and still carry different `source` values, and a host that
        /// added them as one random process would be wrong. `source` is the
        /// only field that says anything about correlation.
        name: []const u8 = "",
    };
}

/// §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log`: one generator's PSD as
/// a piecewise (frequency, power) table instead of a parametric term. Position
/// k of the device's optional `noise_tables` is what `NoiseGen.table == k`
/// names.
///
/// A COMPTIME table beside `noise_gens`, not a field of `PsdTerm`: the clause's
/// input is "an array parameter or an array assignment pattern", i.e. data the
/// model states once and not per bias, and a host that integrates a spectrum
/// wants the KNOTS — a segment of a log-log line has a closed-form integral and
/// a sampled evaluator does not. `noisePsd` still answers position k, and for a
/// table row it answers all-zero, so a host that has not learned about tables
/// yet reads no noise from one rather than the wrong noise.
///
/// The invariants `validate` enforces, so a consumer may assume them:
/// `points.len >= 1`, frequencies strictly ascending (§4.6.4.3: "the simulator
/// shall internally sort the pairs into ascending frequency … Each frequency
/// value must be unique" — VerA sorts at compile time, so the host never has
/// to), every frequency > 0, every power >= 0, and > 0 throughout a `.log`
/// table because its own interpolation takes their logarithm.
pub const NoiseTable = struct {
    /// §4.6.4.3 linear in (f, p); §4.6.4.4 linear in (log f, log p) — a
    /// straight line on a log-log plot, which is the whole difference between
    /// the two functions (LRM Figure 4-14).
    interp: enum(u8) { linear, log },
    /// (frequency [Hz], power [units²/Hz]) pairs, ascending in frequency.
    points: []const [2]f64,
};

/// §4.6.4.3 "the simulator shall internally sort the pairs into ascending
/// frequency if required". VerA sorts the DEFAULTS at compile time, so a
/// device's `noise_tables` already arrives ascending; this is for the knots a
/// model card moved, which `noiseTablePoints` returns and which no compiler
/// saw. In place, because that is where the generated accessor has them.
pub fn sortNoiseTable(pts: [][2]f64) void {
    std.mem.sort([2]f64, pts, {}, struct {
        fn lt(_: void, a: [2]f64, b: [2]f64) bool {
            return a[0] < b[0];
        }
    }.lt);
}

/// §4.6.4.3/.4 the tabulated PSD at `f`. Lives here rather than in each host
/// because the two clauses state one formula each and both are easy to get
/// subtly wrong — §4.6.4.4 is `pow(10, log(p1) + (log(p2)-log(p1)) *
/// (log(f)-log(f1)) / (log(f2)-log(f1)))`, written below with the natural
/// logarithm, which is the same line: the base cancels in the ratio.
///
/// Outside the table both clauses clamp, in the same words: "for frequencies
/// lower than the lowest frequency in the value set, noise_table() returns the
/// power specified for the lowest frequency, and for frequencies higher than
/// the highest frequency, noise_table() returns the power specified for the
/// highest frequency." No extrapolation, in either mode — which is also what
/// makes a one-point table legal and constant.
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
        .log => @exp(@log(a[1]) + (@log(b[1]) - @log(a[1])) *
            (@log(f) - @log(a[0])) / (@log(b[0]) - @log(a[0]))),
    };
}

/// One generator's PSD at a given state vector, returned by the optional
/// device `noisePsd` hook (position k = noise_gens[k]):
///   S(f) = white + flicker / f^ef   [A²/Hz]
/// white: thermal 4kT·g, shot 2q|I| — the DEVICE computes it from its own
/// currents/conductances. corr_with pairs correlated generators (BSIM4
/// tnoiMod, PSP igid); real coefficient until a reference demands complex.
///
/// NOTE: this parametric form cannot express §4.6.4.3 `noise_table` /
/// §4.6.4.4 `noise_table_log`, which are piecewise PSD-vs-frequency; those are
/// `NoiseGen.kind == .table` and `noise_tables`, and their `PsdTerm` reads
/// all-zero. So the full spectrum of generator k is
///
///     S_k(f) = white + flicker/f^ef        (parametric rows)
///     S_k(f) = noiseTableAt(noise_tables[noise_gens[k].table.?], f)
///
/// and a host that simply ADDS the two is right for both, because each shape
/// is zero where the other one speaks.
///
/// `coeff` MULTIPLIES whichever of those two shapes this row has, and it is not
/// optional arithmetic — see its own doc.
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    corr_with: ?u8 = null,
    corr: f64 = 0,
    /// §4.6.4.6 the factor the CONTRIBUTION applies to this generator: the `c1`
    /// of `V(a,b) <+ c1*n`. The density the branch actually carries is
    ///
    ///     S_k(f) = coeff² · (white + flicker/f^ef)          parametric rows
    ///     S_k(f) = coeff² · noiseTableAt(noise_tables[…], f) table rows
    ///
    /// **A host that ignores this field is low by c² on any scaled source**,
    /// silently — which is what VerA did before the field existed, because
    /// there was nowhere to put the factor.
    ///
    /// Here and not folded into `white`, for two reasons that each rule it out
    /// on their own. A §4.6.4.3 table row's spectrum is COMPTIME data and
    /// cannot absorb a factor that may depend on the bias — and it may:
    /// `I(a,b) <+ V(a,b)*white_noise(p)` is a legal modulated source, which is
    /// why this lives on the per-bias `PsdTerm` and not on `NoiseGen`. And the
    /// §4.6.4.6 cross term between two rows sharing a `source` is
    ///
    ///     S_ij(f) = coeff_i · coeff_j · (the shared generator's own spectrum)
    ///
    /// whose SIGN is the whole difference between correlation and
    /// anti-correlation. A squared density cannot carry it, so the field is
    /// signed and only the host squares it.
    ///
    /// 1.0 for the overwhelmingly common `I(a,b) <+ white_noise(pwr)`, and 1.0
    /// for a use VerA could not reduce to a single factor — a generator
    /// squared, or inside a call — where no coefficient exists to report.
    coeff: f64 = 1,
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

/// §4.6.3 AC stimulus topology. Position k of `ac_gens` names one `ac_stim`
/// call on the (row, col) branch, and position k of the `acStim(...)` result
/// carries that call's phasor — exactly the `noise_gens`/`noisePsd` split, for
/// the same reason: the branch and the analysis name are properties of the
/// MODEL TEXT, the magnitude and phase are properties of the model card.
///
/// "When the name of the small-signal analysis matches analysis_name, the
/// source becomes active and models a source with magnitude mag and phase
/// phase … The AC stimulus function returns zero (0) during large-signal
/// analyses (such as DC and transient) as well as on all small-signal analyses
/// using names which do not match analysis_name."
///
/// **What a host that ignores this export gets wrong.** VerA also lowers
/// `ac_stim` into the residual, as `mag·cos(phase)` — the phasor's REAL PART,
/// because a residual is real. So a host that reads only the residual sees a
/// source whose quadrature component has been deleted: a stimulus at phase π/2
/// disappears from the analysis entirely instead of being in quadrature with
/// one at phase 0. This table is the whole phasor. A host that solves a complex
/// small-signal system reads it INSTEAD OF the residual term, not in addition
/// — both spell the same source, and adding them counts its real part twice.
pub fn AcGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        /// §4.6.3 `analysis_name`: the source is active only while the
        /// small-signal analysis in force carries this name (§4.6.1's Table
        /// 4-21 vocabulary — "ac", "noise", "xf", …). "ac" is the clause's own
        /// default for `ac_stim()`.
        name: []const u8 = "ac",
    };
}

/// §4.6.3 one AC stimulus' phasor, `mag·e^(j·phase)`, returned by the optional
/// `acStim(x, model, inst)` hook (position k = `ac_gens[k]`).
///
/// EVALUATED AT A STATE VECTOR, like `noisePsd` and for the same reason: A.8.2
/// gives `ac_stim`'s magnitude and phase as `analog_expression`, so a
/// swept-amplitude source — `ac_stim("ac", k*V(ctrl))` — has a phasor that is
/// a function of the operating point and not of the card alone.
///
/// Polar and not rectangular, because polar is what the clause states and what
/// the model wrote: converting here would round `cos(π/2)` to 6.1e-17 and hand
/// a host a source that is 6.1e-17 out of quadrature for no reason.
///
/// `mag` may be NEGATIVE: §4.6.4.6's per-use coefficient applies to a stimulus
/// too (`I(a,b) <+ -2*ac_stim("ac")`), and a real factor folds into the
/// magnitude exactly, sign and all — `−m·e^(jφ)` is `m·e^(j(φ+π))`. A host that
/// takes `@abs(mag)` inverts such a source.
pub const AcPhasor = struct {
    /// Magnitude, in the contributed nature's units. §4.6.3's default is 1.
    mag: f64 = 1,
    /// Phase, in RADIANS — "phase is given in radians". Default 0.
    phase: f64 = 0,
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

/// Which unknowns need a derivative lane, as a bit mask over `U` (bit i is
/// `@intFromEnum` value i). A SOUND SUPERSET, and like `limitReads` it
/// defaults to ALL when a device does not declare `deriv_reads` — the answer
/// that costs performance rather than correctness.
///
/// THE PROMISE: for every unknown u outside the mask, every ∂eval[row]/∂x[u]
/// and ∂q[row]/∂x[u] is a compile-time constant — the same at every x, every
/// Model and every Instance — and `jacConst` holds its exact value. Such a
/// column only ever enters the residual as a linear term with a constant
/// coefficient: a §5.6 branch relation's ±V, KCL's ±x[flow], a §5.4.3
/// port-probe row. The branch-flow unknowns are most of them; bsim4va's
/// shared core differentiates 11 of its 18.
///
/// THE RULE FOR A HOST: seed derivative lanes only for the unknowns in the
/// mask, and stamp `jacConst` for the rest. Every unknown still reaches
/// `eval` with its VALUE; only its lane is gone. The width is the host's to
/// pad — `Dual(next_pow2(popcount))` measured best — and the device declares
/// only the mask. `ddxAt` reads a lane by unknown index; see `ddxReads`.
///
/// The constant entries stay in `jac_pattern`/`q_pattern` and
/// `jac_rows`/`q_rows`: their matrix slots exist, only their values are known
/// before the solve.
///
/// `validate` enforces four rules, each where a wrong mask would otherwise
/// corrupt the Jacobian silently:
///   (a) a declared `deriv_reads` needs |U| <= 64, the width of the mask;
///   (b) `limitWrites ⊆ derivReads` on a device with a `limit`: the host's
///       limiting correction `I(vlim) + g(vlim)·(v − vlim)` is lane-indexed,
///       so every unknown the limiter moves needs a live lane;
///   (c) `jac_const` is sorted by (row, col) with no duplicates, has no
///       entry whose `g` and `c` are both zero, and names no column inside
///       the mask;
///   (d) `ddxReads ⊆ derivReads`, for the same reason as (b).
pub fn derivReads(comptime D: type) u64 {
    return if (@hasDecl(D, "deriv_reads")) D.deriv_reads else ~@as(u64, 0);
}

/// The unknowns whose partial §4.5.14 `ddx` reads, as a bit mask over `U`:
/// device code calls `S.ddxAt(col)` with `col` an UNKNOWN index, so the VALUE
/// it returns is a lane. Defaults to ALL when a device does not declare
/// `ddx_reads`, and `validate` holds it inside `derivReads` (rule (d)).
///
/// THE RULE FOR A HOST: `ddxAt(col)` must go through the host's own
/// unknown-to-lane map. On a narrow Dual, lane `col` is some other unknown's
/// partial, or out of range — a wrong VALUE in the residual, not only a wrong
/// Jacobian, and nothing downstream notices.
pub fn ddxReads(comptime D: type) u64 {
    return if (@hasDecl(D, "ddx_reads")) D.ddx_reads else ~@as(u64, 0);
}

/// One constant entry of the local Jacobian, for a column outside
/// `derivReads`: `g` is ∂eval[row]/∂x[col] and `c` is ∂q[row]/∂x[col], both
/// exact. Generic over the device's own `U`, because the unknown enum is per
/// device: a device spells its table `[_]contract.JacConst(U){ ... }`.
///
/// An absent entry is exactly 0 in both halves, which is why an entry with
/// `g == c == 0` is refused rather than tolerated — see `derivReads` (c).
pub fn JacConst(comptime U: type) type {
    return struct { row: U, col: U, g: f64, c: f64 };
}

/// The device's `jac_const` as a slice, sorted by (row, col); empty when the
/// device declares none — which is also the only answer `derivReads`'
/// all-ones default leaves room for.
pub fn jacConst(comptime D: type) []const JacConst(D.U) {
    return if (@hasDecl(D, "jac_const")) D.jac_const[0..] else &.{};
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
    "con",  "addC", "scale", "add",   "sub",  "neg",  "mul",   "div",
    "exp",  "log",  "expm1", "log1p", "sqrt", "pow",  "sin",   "cos",
    "tanh", "sinh", "cosh",  "atan",  "abs",  "minC", "maxC",  "min",
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

/// Devices with first-call table state require exclusively owned mutable evaluation.
/// Initialization is permanent for the instance and is not timestep rollback state.
pub fn InstancePtr(comptime D: type) type {
    return if (@hasDecl(D, "mutable_eval") and D.mutable_eval) *D.Instance else *const D.Instance;
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
    if (@hasDecl(D, "mutable_eval") and @TypeOf(D.mutable_eval) != bool)
        @compileError(name ++ ".mutable_eval must be bool");
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
    // display phase and no exit (the calls are dropped under W0850).
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
    // The narrow-lane pair and its three rules — see `derivReads`.
    if (derivReadsError(D, n)) |m| @compileError(m);
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
    if (@hasDecl(D, "state_class")) {
        if (@TypeOf(D.state_class) != StateClass)
            @compileError(name ++ ".state_class must be a contract.StateClass");
        if ((D.state_class == .none) == @hasDecl(D, "updateState"))
            @compileError(name ++ ".state_class: `.none` exactly when there is no updateState");
        // `path_latch` promises the commit that latches the staged values.
        if (D.state_class == .path_latch and !@hasDecl(D, "stateCtl"))
            @compileError(name ++ ".state_class = .path_latch requires stateCtl");
    }
    // §5.6.1.2 + §4.5.2 the fused accepted-point pass: `q` and `updateState`
    // from one core evaluation, so it needs both of them to be equivalent to.
    if (@hasDecl(D, "acceptQ")) {
        if (!@hasDecl(D, "q") or !@hasDecl(D, "updateState"))
            @compileError(name ++ ".acceptQ requires q and updateState");
        const info = @typeInfo(@TypeOf(D.acceptQ));
        if (info != .@"fn" or info.@"fn".params.len != 5 or info.@"fn".params[0].type != type)
            @compileError(name ++ ".acceptQ: expected fn (comptime S: type, [n_u]S, *const Model, *Instance, *State) [n_u]S");
    }

    if (@hasDecl(D, "beginSolve")) expectFn(D, "beginSolve", fn (*D.Instance) void);
    // §9.15/§9.17.3 iteration state is separate from accepted-time history.
    if (@hasDecl(D, "advanceIteration"))
        expectFn(D, "advanceIteration", fn (*const D.Model, *D.Instance, [n]f64) void);
    if (@hasDecl(D, "checkConvergence"))
        expectFn(D, "checkConvergence", fn (*const D.Model, *const D.Instance, [n]f64) bool);

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

    // §3.6.3.2 `electrical n = 5.0;`, per unknown: "the initializer ... will be
    // used as a nodeset value for the potential of the net by the analog
    // solver". OPTIONAL in the strongest sense — it is an initial GUESS, so a
    // host that never reads it computes the same answer and only starts
    // somewhere else. Absent whenever the module declares no initializer at
    // all, which is almost every module.
    //
    // `?f64`, because "a null value in the constant array indicates that no
    // nodeset value is being specified for this element" and 0.0 is a perfectly
    // ordinary nodeset. A host takes `u_nodeset[i]` as the starting x for that
    // unknown and leaves the nulls at whatever it would have used.
    //
    // NOT an initial condition: §5.10.2's `initial_step` and the `.ic` pass are
    // a different mechanism with a different meaning — a value the solve must
    // HOLD. Nothing here may be handed to a host as one.
    if (@hasDecl(D, "u_nodeset") and @TypeOf(D.u_nodeset) != [n]?f64)
        @compileError(name ++ ".u_nodeset must be [|U|]?f64");

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
    // the result describes generator k. `requireWith` is the weak direction
    // (a PSD needs a generator to belong to); the strong one — a generator
    // needs a PSD, because nothing outside the device can state one — is the
    // HOST's to enforce, since only a host knows whether it has a fallback.
    // ARPice has none and `@compileError`s (devices/engine.zig collectNoise).
    expectArray(D, "noise_gens", NoiseGen(D));
    requireWith(D, "noisePsd", "noise_gens");
    if (@hasDecl(D, "noisePsd"))
        expectFn(D, "noisePsd", fn ([n]f64, *const D.Model, *const D.Instance) [D.noise_gens.len]PsdTerm);

    // §4.6.4.3/.4 the tabulated PSDs, and the `kind`/`table` pairing that says
    // which generator reads one. Checked HERE and not left to the host: the
    // invariants `noiseTableAt` assumes (non-empty, ascending, unique, and
    // logarithmable in a `.log` table) are exactly the ones whose violation
    // reads as a NaN spectrum three analyses later.
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
        // §4.6.4.3's array-parameter input: `noise_tables` then holds the
        // parameter's DECLARED DEFAULTS and this is the card's own knots, one
        // flat array over every table in `noise_tables` order. Optional — a
        // device of literal tables does not declare it, and a host that reads
        // `noise_tables` alone is right about such a device.
        if (@hasDecl(D, "noiseTablePoints")) {
            var total: usize = 0;
            for (tables) |t| total += t.points.len;
            expectFn(D, "noiseTablePoints", fn (*const D.Model) [total][2]f64);
        }
    }

    // §4.6.3 the AC stimulus sources. Same twin shape as noise_gens/noisePsd:
    // the hook needs a table to be positional against, and `row`/`col` are
    // range-checked by `AcGen`'s own integer widths.
    expectArray(D, "ac_gens", AcGen(D));
    requireWith(D, "acStim", "ac_gens");
    if (@hasDecl(D, "acStim"))
        expectFn(D, "acStim", fn ([n]f64, *const D.Model, *const D.Instance) [D.ac_gens.len]AcPhasor);

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
/// `lib/backend/tb.zig`. An exemption for the tool's own host is how a seam
/// stops being tested.
pub fn validateHost(comptime H: type, comptime D: type) void {
    if (@hasDecl(D, "mutable_eval") and D.mutable_eval) {
        if (!@hasDecl(H, "mutable_eval") or !H.mutable_eval)
            @compileError("this device requires exclusive mutable evaluation; declare mutable_eval = true");
    }
    if (@hasDecl(D, "advanceIteration") or @hasDecl(D, "checkConvergence") or @hasDecl(D, "beginSolve")) {
        if (!@hasDecl(H, "iteration_hooks")) @compileError(@typeName(H) ++
            " must implement the Newton iteration hooks and declare iteration_hooks = true; " ++
            "updateState alone cannot execute this device. See CONSUMING.md.");
        if (!H.iteration_hooks) @compileError("this device requires Newton iteration hooks");
    }
    // §4.6.4.3 an array-parameter noise table. `noise_tables` holds only the
    // parameter's DECLARED DEFAULTS, so a host that reads it and stops has
    // silently ignored the model card — the exact trap that made VerA refuse
    // the spelling outright for so long. Opting in is how a host says it reads
    // `noiseTablePoints`; there is no way to check that it does, and a silent
    // wrong spectrum is worse than a build that will not start.
    if (@hasDecl(D, "noiseTablePoints")) {
        if (!@hasDecl(H, "noise_table_points") or !H.noise_table_points)
            @compileError(@typeName(H) ++ " must read `noiseTablePoints`: " ++ @typeName(D) ++
                " has a 4.6.4.3 noise table whose knots are model parameters, and " ++
                "`noise_tables` carries only their declared defaults. Declare " ++
                "noise_table_points = true once the host reads the hook.");
    }
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
    // The narrow-derivative pair: which unknowns need a lane, and the exact
    // constant partials of the rest — see `derivReads`.
    .{ "deriv_reads", {} },
    .{ "ddx_reads", {} },
    .{ "jac_const", {} },
    .{ "seed", {} },
    .{ "collapse", {} },
    // The same alias map with every retention flag set, at comptime — see the
    // `collapse_full` block in `validate`.
    .{ "collapse_full", {} },
    .{ "initState", {} },
    .{ "updateState", {} },
    .{ "advanceIteration", {} },
    .{ "checkConvergence", {} },
    .{ "beginSolve", {} },
    .{ "stateCtl", {} },
    .{ "State", {} },
    // What `State` carries (`StateClass`), and the fused accepted-point pass;
    // both checked in `validate`.
    .{ "state_class", {} },
    .{ "acceptQ", {} },
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
    // (ARPice engine.gpuEligible keys off this). Emitted by codegen from the
    // calls in the core's slice: abstime, dt, analysis_kind, the step and
    // `analog initial` flags, newton_iteration and limiter_previous. The
    // updateState epilogue's `state.t_prev = inst.abstime` latch does not
    // count — nothing in the core reads it back.
    .{ "core_reads_simstate", {} },
    .{ "mutable_eval", {} },
    // §4.6.4.3's array-parameter table at this card. Optional; see `validate`
    // and `validateHost` — a device that declares it has knots `noise_tables`
    // states only the declared defaults of.
    .{ "noiseTablePoints", {} },
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
    // §3.6.3.2 the declared nodeset per unknown, `?f64`. Optional; see the
    // `u_nodeset` block in `validate`.
    .{ "u_nodeset", {} },
    .{ "jac_pattern", {} },
    .{ "q_pattern", {} },
    // Which residual rows each half ever writes — one u64 of row bits, the
    // companion the pattern deliberately cannot substitute for. See
    // `checkRowMask` and its call site in `validate`.
    .{ "jac_rows", {} },
    .{ "q_rows", {} },
    .{ "noise_gens", {} },
    .{ "noisePsd", {} },
    .{ "noise_tables", {} },
    // §4.6.3 the AC stimulus sources and their phasors.
    .{ "ac_gens", {} },
    .{ "acStim", {} },
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
        // matrix as internal unknowns; `zi_*` is transcendental and needs a
        // complex AC stamp the contract does not carry yet. Neither needs a public coefficient table. The exemption
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
/// `display`): five parameters, the first `comptime S: type`.
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

/// `derivReads`' rules (a)–(d), returned rather than raised so each is
/// testable — see `genericFnError`. `n` is |U|, passed in so rule (a) can be
/// exercised without a 65-member enum.
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
        if (k == 0) continue;
        const pr: usize = @intFromEnum(t[k - 1].row);
        const pc: usize = @intFromEnum(t[k - 1].col);
        if (r < pr or (r == pr and c <= pc))
            return name ++ ".jac_const must be sorted by (row, col) with no duplicates";
    }
    return null;
}

/// `decl` is meaningless without `needs` — a table with no hook to fill it, or
/// a hook with no table to describe it. Declare it both ways for a pair that
/// is mutually required (ac_gens/acStim, noise_gens/noisePsd).
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
    // §9.12 `Instance.plusargs`, admitted by name for the same reason: the
    // host's own argv, host-owned and host-lifetime.
    if (T == []const [:0]const u8) return true;
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

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ x[0].scale(y0), x[1].scale(y0) };
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
    pub const mutable_eval = false;

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
    // §3.6.3.2 one net declared `electrical p = 5.0;`, the other with no
    // initializer — the mock carries both halves so `?f64` is exercised.
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
    // `eval` scales by the model's `g`, so neither column is constant — and
    // rule (b) would demand both lanes anyway, since `limit` writes both.
    pub const deriv_reads: u64 = 0b11;
    pub const ddx_reads: u64 = 0b01;
    pub const jac_const = [_]JacConst(U){};

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
    pub const state_class: StateClass = .history;
    pub fn acceptQ(comptime S: type, x: [n_u]S, m: *const Model, inst: *Instance, s: *State) [n_u]S {
        s.flips += 1;
        return q(S, x, m, inst, 0);
    }
    pub fn beginSolve(_: *Instance) void {}

    pub fn advanceIteration(_: *const Model, _: *Instance, _: [n_u]f64) void {}

    pub fn checkConvergence(_: *const Model, _: *const Instance, _: [n_u]f64) bool {
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
    pub fn noisePsd(_: [n_u]f64, m: *const Model, _: *const Instance) [noise_gens.len]PsdTerm {
        // Row 1 is the table's, and its parametric part is zero: the table IS
        // its spectrum, so anything else here would be added to it.
        return .{ .{ .white = 4 * 1.38e-23 * 300.15 * @as(f64, m.g) }, .{ .white = 0 } };
    }
    pub fn acStim(_: [n_u]f64, _: *const Model, _: *const Instance) [ac_gens.len]AcPhasor {
        return .{.{ .mag = 1, .phase = 0 }};
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

test "display shapes: the generic 5-param form, wrong arities refused" {
    // The exact shape that used to slip through: MockAll's display was a
    // 2-arg `(Model, Instance)` fn no caller has ever used — tb.zig calls
    // `D.display(Dual, xd, model, inst, t)`, and a device declaring the
    // 2-arg form fails in the RUNNER's build, three cache steps from the
    // device that caused it. Refused at the definition instead.
    const Bad = struct {
        pub const Model = struct {};
        pub const Instance = struct {};
        pub fn display(_: *const Model, _: *const Instance) void {}
        pub fn eval(_: f64) void {} // not generic: first param is not `type`
    };
    try testing.expect(comptime (genericFnError(Bad, "display", "void") != null));
    try testing.expect(comptime (genericFnError(Bad, "eval", "[n_u]S") != null));
    // The real shapes pass: MockAll.display mirrors codegen's emitted decl.
    try testing.expect(comptime (genericFnError(MockAll, "display", "void") == null));
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
    pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, _: *const Instance, _: f64) [n_u]S {
        return .{ x[2], x[2].neg(), x[0].sub(x[1]).addC(-m.vdc) };
    }
};

/// The smallest f64 scalar `eval` accepts, for checking a mock's table
/// against the function it describes.
const F = struct {
    v: f64,
    fn addC(a: F, c: f64) F {
        return .{ .v = a.v + c };
    }
    fn sub(a: F, b: F) F {
        return .{ .v = a.v - b.v };
    }
    fn neg(a: F) F {
        return .{ .v = -a.v };
    }
};

test "deriv_reads/jac_const: a linear device needs no lane, and the table is its Jacobian" {
    comptime validate(MockVsrc);
    // The table is exact, so a unit step on a column moves each row by
    // exactly the entry's `g` — a finite difference with no truncation error,
    // because every term the column enters is linear.
    const m: MockVsrc.Model = .{};
    const base = [3]F{ .{ .v = 0.25 }, .{ .v = -0.5 }, .{ .v = 2e-3 } };
    const r0 = MockVsrc.eval(F, base, &m, &.{}, 0);
    for (0..3) |col| {
        var xs = base;
        xs[col].v += 1.0;
        const r1 = MockVsrc.eval(F, xs, &m, &.{}, 0);
        for (0..3) |row| {
            var want: f64 = 0;
            for (jacConst(MockVsrc)) |e| {
                if (@intFromEnum(e.row) == row and @intFromEnum(e.col) == col) want = e.g;
            }
            try testing.expectEqual(want, r1[row].v - r0[row].v);
        }
    }
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
    // ALL of them — so a device with a narrow mask must declare it.
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
    // And the defaults: nothing declared is all lanes and no table.
    try testing.expectEqual(~@as(u64, 0), derivReads(MockR));
    try testing.expectEqual(@as(usize, 0), jacConst(MockR).len);
}

test "validateHost: a systf is the host's to bind, and only when there is one" {
    // MockR names no `$name`, so any host will do — including one that has
    // never heard of VPI. That is the common case and it must stay free.
    comptime validateHost(struct {}, MockR);

    // MockAll calls `$sampnhold`, so a host linking it must answer for it.
    const Sim = struct {
        pub const iteration_hooks = true;
        // MockAll also carries a §4.6.4.3 card-valued noise table, so a host
        // linking it must say it reads `noiseTablePoints` rather than the
        // declared defaults in `noise_tables`.
        pub const noise_table_points = true;
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

    // One pair is a legal table and a constant PSD — both clamps answer it.
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
    // bows, and at 1 kHz it reads 1 + (1e-6 - 1)*(999/999999) — nowhere near
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
