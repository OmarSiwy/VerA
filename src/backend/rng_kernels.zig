// §9.13 probabilistic distribution kernels — EMITTED VERBATIM into every device
// that calls one of Table 9-10's 17 names (`codegen.rng_txt` is `@embedFile` of
// this file) and `@import`ed by codegen.zig's tests, on the same terms as
// `str_kernels.zig` and `table_kernels.zig`: one source, so what the tests
// exercise is byte-for-byte what the device runs.
//
// THE ALGORITHM IS IEEE 1364-2005 §17.9.3, VERBATIM. §9.13.3: "17.9.3 of IEEE
// Std 1364 Verilog contains the C-code to describe the algorithm of
// probabilistic system functions based on the seed value passed to them", and
// Table 9-26 cross-lists every `$rdist_*` name onto that listing's C function
// (`$rdist_uniform`→`uniform`, `$rdist_normal`→`normal`, …). The `$dist_*`
// twins are the listing's `rtl_dist_*` integer wrappers, and `$random` is
// `rtl_dist_uniform(seed, INT32_MIN, INT32_MAX)`, which is how the listing's
// own callers spell it.
//
// PROVENANCE. Not transcribed from memory: ported from two independent
// open-source reproductions of the listing, cross-checked constant-by-constant
// against each other before a line of Zig was written, and the port was then
// verified bit-exact against the compiled C on the seeds the tests below pin:
//
//   - Icarus Verilog, vpi/sys_random.c ("largely copied from the IEEE standard
//     (section 17.9.3 in IEEE 1364-2005, Annex N in IEEE 1800-2017)"):
//     https://raw.githubusercontent.com/steveicarus/iverilog/master/vpi/sys_random.c
//     functions: rtl_dist_uniform / uniform / normal / exponential / poisson /
//     chi_square / t / erlangian.
//   - Verilator, include/verilated_probdist.cpp:
//     https://raw.githubusercontent.com/verilator/verilator/master/include/verilated_probdist.cpp
//     functions: VL_DIST_UNIFORM / _vl_dbase_uniform / _vl_dbase_normal /
//     _vl_dbase_exponential / VL_DIST_POISSON / _vl_dbase_chi_square /
//     VL_DIST_T / VL_DIST_ERLANG.
//
// The constants both sources agree on, all present below: LCG
// `seed' = 69069·seed + 1` on a WRAPPING 32-bit word (the original listing's
// `long` arithmetic — its behavior depends on 32-bit signed overflow, which
// both sources reproduce with explicit 32-bit types and this file reproduces
// with `u32` `*%`/`+%`); the zero-seed escape `259341593`; the
// mantissa-fill `(seed >> 9) | 0x3f800000` spelled arithmetically as
// `1.0 + (seed >> 9)·2⁻²³`, exactly equal to the float-punning original; the
// double `d = 0.00000011920928955078125` (2⁻²³) in `c = c + c·d`.
//
// WHY EVERY DRAW IS A PURE FUNCTION OF THE SEED, AND WHY THAT IS THE WHOLE
// DESIGN. A device residual is re-evaluated many times at ONE operating point —
// that is what Newton does — so a draw that changed between iterations would
// make the residual non-deterministic and the solve would never converge. This
// is not a VerA restriction; it is why commercial simulators latch a variate for
// the duration of a point. §9.13.1/§9.13.2 make that free for the seeded forms:
//
//   "If the random_seed argument is specified it is an inout argument; that is,
//    a value is passed to the function and a different value is returned. The
//    variable should be initialized by the user prior to calling $random and
//    only updated by the system function."
//
// The seed is therefore a SOURCE VARIABLE, not hidden simulator state, and the
// variate is a function of its incoming value. Lowering splits one source call
// into two pure calls over that value — the variate (`zRng*`) and the updated
// seed (`zRng*Next`) — exactly as `lowerScan` splits `$sscanf` into one call
// per out-parameter. Re-evaluating the analog block re-derives both from the
// same input, so §9.13.2's "the system functions shall always return the same
// value given the same seed" and Newton's need for a fixed residual are the
// same requirement, met by the same code.
//
// The updated seed is PER DISTRIBUTION (`zRngNormalNext`, not one generic
// step): §17.9.3's routines consume a data-dependent number of LCG steps —
// `normal` rejects Marsaglia pairs, `poisson` multiplies uniforms until the
// mass is passed, `chi_square`/`t`/`erlangian` loop over the degrees — and the
// reference stream across SUCCESSIVE calls on one seed variable is only
// reproduced if the write-back walks exactly as far as the variate did. Each
// `zRng*Next` therefore replays its own routine and returns the final seed.
//
// The seedless forms (`$random`, `$arandom` with the seed omitted, and a
// constant/parameter seed, whose §9.13.1 "internal seed" is not visible from the
// source) have no such variable. Their state is a latch in `Instance`, drawn in
// the per-point sampling phase (`updateState`, the accepted-step boundary) and
// only READ by the residual — same discipline, different owner. `zRngNext`
// (one plain `uniform()` step) is that latch's advance.
//
// ponytail: two deliberate ceilings the reference does not have, both inside a
// Newton iteration on purpose — degrees of freedom / Erlang stages clamp at
// 4096 (`zRngDf`; beyond it a normal approximation is the upgrade path), and
// non-positive df/k, which `rtl_dist_*` rejects with a warning and a 0 before
// its inner routine runs, returns the same 0 here (lowering already made
// foldable violations E0816).

// There is deliberately no `const std` here — unlike `str_kernels.zig` this file
// needs nothing from it, and every declaration below is emitted verbatim into
// device.zig, where a second `std` at file scope would be a redeclaration.

/// The i64 the LRM's `integer` seed variable carries, folded onto the C
/// listing's 32-bit word: the low 32 bits, exactly what assigning an `int32_t*`
/// through the VPI did in the reference's callers.
fn zRngS32(seed: i64) u32 {
    return @truncate(@as(u64, @bitCast(seed)));
}

/// The updated 32-bit word read back out as the SIGNED value the listing's
/// `long *seed` stored — negative seeds are part of the reference stream.
/// Returned as f64 because every emitted `$rng$*` callee is real-typed and
/// lowering converts (§4.2.1.1); an i32 is far below 2^53 and therefore exact.
fn zRngSOut(s: u32) f64 {
    return @floatFromInt(@as(i32, @bitCast(s)));
}

/// §17.9.3 `uniform(seed, start, end)`, the primitive every other routine
/// draws through. One LCG step; returns a double on [start, end) — up to the
/// listing's own top-sliver overshoot of `end` by ~2⁻²³·(end−start), which is
/// the reference's behavior and therefore ours.
fn zRngUniformCore(s: *u32, start: f64, end: f64) f64 {
    const d: f64 = 0.00000011920928955078125; // 2^-23, the listing's `d`
    var a = start;
    var b = end;
    if (start >= end) {
        a = 0.0;
        b = 2147483647.0;
    }
    if (s.* == 0) s.* = 259341593;
    s.* = 69069 *% s.* +% 1; // C `long` overflow semantics: wrapping 32-bit
    // `(newseed >> 9) | 0x3f800000` bit-punned to float is exactly
    // 1 + (newseed >> 9)·2⁻²³; Icarus carries this arithmetic spelling.
    var c: f64 = 1.0 + @as(f64, @floatFromInt(s.* >> 9)) * d;
    c = c + (c * d);
    return ((b - a) * (c - 1.0)) + a;
}

/// §17.9.3 `normal(seed, mean, deviation)`: Marsaglia polar rejection over
/// pairs of `uniform(seed, -1, 1)`. The loop is why the seed's advance is
/// data-dependent and `zRngNormalNext` replays it.
fn zRngNormalCore(s: *u32, mean: f64, dev: f64) f64 {
    var v1: f64 = 0.0;
    var v2: f64 = 0.0;
    var sq: f64 = 1.0;
    while (sq >= 1.0 or sq == 0.0) {
        v1 = zRngUniformCore(s, -1.0, 1.0);
        v2 = zRngUniformCore(s, -1.0, 1.0);
        sq = v1 * v1 + v2 * v2;
    }
    return v1 * @sqrt(-2.0 * @log(sq) / sq) * dev + mean;
}

/// §17.9.3 `exponential(seed, mean)`: `-log(uniform(0,1))·mean`, the `n != 0`
/// guard included verbatim.
fn zRngExponentialCore(s: *u32, mean: f64) f64 {
    var n = zRngUniformCore(s, 0.0, 1.0);
    if (n != 0.0) n = -@log(n) * mean;
    return n;
}

/// §17.9.3 `poisson(seed, mean)`: draw one uniform, then multiply uniforms
/// into it until the cumulative product drops under exp(-mean). The count of
/// multiplications is the variate. Terminates for every mean: each factor is a
/// uniform strictly inside (0,1)-ish, so the product underflows to zero in a
/// few thousand steps even when `exp(-mean)` is itself zero.
fn zRngPoissonCore(s: *u32, mean: f64) f64 {
    var n: f64 = 0.0;
    const p = @exp(-mean);
    var q = zRngUniformCore(s, 0.0, 1.0);
    while (p < q) {
        n += 1.0;
        q = zRngUniformCore(s, 0.0, 1.0) * q;
    }
    return n;
}

/// The C cast the reference applied to a degree-of-freedom / stage-count
/// argument at its integer boundary (truncation toward zero), with this file's
/// one admitted ceiling on top.
///
/// ponytail: 4096 degrees of freedom is the ceiling — `chi_square`/`erlangian`
/// walk one or two LCG steps PER DEGREE inside a Newton iteration, so an
/// unbounded df is unbounded work per residual evaluation. A normal
/// approximation is the upgrade path beyond it.
fn zRngDf(df: f64) i32 {
    if (df >= 4096.0) return 4096;
    if (df <= 0.0) return 0;
    return @intFromFloat(@trunc(df));
}

/// §17.9.3 `chi_square(seed, deg_of_free)`: one squared normal for an odd df,
/// then `2·exponential(seed, 1)` per even pair.
fn zRngChiSquareCore(s: *u32, df: i32) f64 {
    var x: f64 = 0.0;
    if (@rem(df, 2) != 0) {
        const z = zRngNormalCore(s, 0.0, 1.0);
        x = z * z;
    }
    var k: i32 = 2;
    while (k <= df) : (k += 2) x += 2.0 * zRngExponentialCore(s, 1.0);
    return x;
}

// A note with no function under it: §17.9.3's integer-result rounding,
// `(long)(r + 0.5)` mirrored through zero, is exactly round-half-away-from-zero
// — the same rule §4.2.1.1 gives `fi_cast` — so the shared `$dist_*` kernels
// get the reference's `rtl_dist_*` rounding for free from lowering's `toInt`
// and no `zRng*` spelling of it exists.

/// §17.9.3 `rtl_dist_uniform(seed, INT32_MIN, INT32_MAX)` — the way the
/// listing's own `$random` caller spells it (Icarus sys_random.c line
/// `rtl_dist_uniform(&seed, INT_MIN, INT_MAX)`), i.e. the full-range third
/// branch: rescale the uniform from [−2³¹, 2³¹−1] onto [−2³¹, 2³¹) and floor.
fn zRngRandCore(s: *u32) f64 {
    var r = (zRngUniformCore(s, -2147483648.0, 2147483647.0) + 2147483648.0) / 4294967295.0;
    r = r * 4294967296.0 - 2147483648.0;
    // The listing's `(long)r` / `(long)(r - 1)` pair: C truncation toward zero.
    const f = if (r >= 0.0) @trunc(r) else @trunc(r - 1.0);
    // The top 2⁻²³ sliver lands exactly on 2³¹, where the C cast is UB that
    // every shipping compiler resolves to the wrapped/saturated 0x80000000;
    // the i64 round trip makes that defined here.
    return @floatFromInt(@as(i32, @truncate(@as(i64, @intFromFloat(f)))));
}

/// §17.9.3 `rtl_dist_uniform(seed, start, end)`: an INTEGER in the closed range
/// [start, end], via one `uniform` over the half-open widened interval, floored
/// and clamped — all three of the listing's branches, including the widen-by-one
/// asymmetries at the two int32 extremes.
fn zRngIUniformCore(s: *u32, start_r: f64, end_r: f64) f64 {
    // The reference's arguments are int32; fold the real-typed carrier onto
    // that domain the way the C cast did, saturating instead of trapping.
    const start: i32 = @intFromFloat(@max(-2147483648.0, @min(2147483647.0, @trunc(start_r))));
    const end: i32 = @intFromFloat(@max(-2147483648.0, @min(2147483647.0, @trunc(end_r))));
    if (start >= end) return @floatFromInt(start);
    if (end != 2147483647) {
        const e1: f64 = @floatFromInt(end + 1);
        const r = zRngUniformCore(s, @floatFromInt(start), e1);
        var i: i64 = @intFromFloat(if (r >= 0.0) @trunc(r) else @trunc(r - 1.0));
        if (i < start) i = start;
        if (i >= end + 1) i = end;
        return @floatFromInt(i);
    } else if (start != -2147483648) {
        const s1: f64 = @floatFromInt(start - 1);
        const r = zRngUniformCore(s, s1, 2147483647.0) + 1.0;
        var i: i64 = @intFromFloat(if (r >= 0.0) @trunc(r) else @trunc(r - 1.0));
        if (i <= start - 1) i = start;
        if (i > end) i = end;
        return @floatFromInt(i);
    }
    return zRngRandCore(s);
}

/// §17.9.3 `t(seed, deg_of_free)`: a fresh normal over the root of a
/// chi-square per degree. The `chi2 <= 0` guard is not the listing's — it is
/// the measure-zero corner where the chi-square comes back 0 (or 2⁻²³-sliver
/// negative) and the reference divides by a zero root to a NaN; `proof`
/// promises this family finite, so that corner answers 0 instead.
fn zRngTCore(s: *u32, df: i32) f64 {
    const chi2 = zRngChiSquareCore(s, df);
    if (chi2 <= 0.0) return 0.0;
    return zRngNormalCore(s, 0.0, 1.0) / @sqrt(chi2 / @as(f64, @floatFromInt(df)));
}

/// §17.9.3 `erlangian(seed, k, mean)`: minus-log of a product of `k` uniforms,
/// scaled by `mean / k`.
fn zRngErlangCore(s: *u32, k: i32, mean: f64) f64 {
    var x: f64 = 1.0;
    var i: i32 = 1;
    while (i <= k) : (i += 1) x *= zRngUniformCore(s, 0.0, 1.0);
    return -mean * @log(x) / @as(f64, @floatFromInt(k));
}

// ---------------------------------------------------------------------------
// The emitted entry points. Each distribution is a PAIR pure in the i64 seed:
// the variate, and the `*Next` twin that replays the identical routine and
// returns the reference's final seed for §9.13.2's inout write-back.
// ---------------------------------------------------------------------------

/// One plain `uniform()` step of the seed, for the seedless forms' `Instance`
/// latch (`updateState` advances `rng_auto` through this once per ACCEPTED
/// point). No fixed point on the whole 32-bit word — `69069·s + 1 ≡ s (mod 2³²)`
/// asks 4 | gcd to divide −1 — so the fixtures' `sa != 7` holds for every seed.
pub fn zRngNext(seed: i64) f64 {
    var s = zRngS32(seed);
    _ = zRngUniformCore(&s, 0.0, 1.0);
    return zRngSOut(s);
}

/// §9.13.1 `$random`/`$arandom`: "the random number returned is a 32-bit signed
/// integer; it can be positive or negative."
pub fn zRngRand(seed: i64) f64 {
    var s = zRngS32(seed);
    return zRngRandCore(&s);
}

pub fn zRngRandNext(seed: i64) f64 {
    var s = zRngS32(seed);
    _ = zRngRandCore(&s);
    return zRngSOut(s);
}

/// IEEE 1364 §17.9.2 `$dist_uniform(seed, start, end)`: an INTEGER in the
/// closed range [start, end]; `start >= end` degenerates to `start`, the same
/// answer the listing gives.
pub fn zRngIUniform(seed: i64, start: f64, end: f64) f64 {
    var s = zRngS32(seed);
    return zRngIUniformCore(&s, start, end);
}

pub fn zRngIUniformNext(seed: i64, start: f64, end: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngIUniformCore(&s, start, end);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_uniform` — Table 9-26 row one, the listing's `uniform`
/// itself, with the real `start`/`end` the analog form passes where the digital
/// caller passed ints. "The start and end arguments are real inputs which bound
/// the values returned"; `start >= end` is the listing's degenerate arm and
/// falls back to its [0, 2³¹−1] span (lowering already rejects the foldable
/// case as E0816).
pub fn zRngUniform(seed: i64, start: f64, end: f64) f64 {
    var s = zRngS32(seed);
    return zRngUniformCore(&s, start, end);
}

pub fn zRngUniformNext(seed: i64, start: f64, end: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngUniformCore(&s, start, end);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_normal` / `$dist_normal` — Table 9-26 `normal`. The integer
/// twin's `(r + 0.5)` rounding is lowering's `fi_cast` (§4.2.1.1 rounds
/// half-away-from-zero, the identical rule).
pub fn zRngNormal(seed: i64, mean: f64, sd: f64) f64 {
    var s = zRngS32(seed);
    return zRngNormalCore(&s, mean, sd);
}

pub fn zRngNormalNext(seed: i64, mean: f64, sd: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngNormalCore(&s, mean, sd);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_exponential` — Table 9-26 `exponential`. The domain rule
/// ("mean … shall be greater than zero") is enforced in lowering where it
/// folds; a runtime violation gets the reference wrapper's answer, 0.
pub fn zRngExponential(seed: i64, mean: f64) f64 {
    if (mean <= 0.0) return 0.0;
    var s = zRngS32(seed);
    return zRngExponentialCore(&s, mean);
}

pub fn zRngExponentialNext(seed: i64, mean: f64) f64 {
    var s = zRngS32(seed);
    if (mean > 0.0) _ = zRngExponentialCore(&s, mean);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_poisson` — Table 9-26 `poisson`.
pub fn zRngPoisson(seed: i64, mean: f64) f64 {
    if (mean <= 0.0) return 0.0;
    var s = zRngS32(seed);
    return zRngPoissonCore(&s, mean);
}

pub fn zRngPoissonNext(seed: i64, mean: f64) f64 {
    var s = zRngS32(seed);
    if (mean > 0.0) _ = zRngPoissonCore(&s, mean);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_chi_square` — Table 9-26 `chi_square`.
pub fn zRngChiSquare(seed: i64, df: f64) f64 {
    const n = zRngDf(df);
    if (n <= 0) return 0.0;
    var s = zRngS32(seed);
    return zRngChiSquareCore(&s, n);
}

pub fn zRngChiSquareNext(seed: i64, df: f64) f64 {
    var s = zRngS32(seed);
    _ = zRngChiSquareCore(&s, zRngDf(df));
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_t` — Table 9-26 `t`.
pub fn zRngT(seed: i64, df: f64) f64 {
    const n = zRngDf(df);
    if (n <= 0) return 0.0;
    var s = zRngS32(seed);
    return zRngTCore(&s, n);
}

pub fn zRngTNext(seed: i64, df: f64) f64 {
    var s = zRngS32(seed);
    const n = zRngDf(df);
    if (n > 0) _ = zRngTCore(&s, n);
    return zRngSOut(s);
}

/// §9.13.2 `$rdist_erlang` — Table 9-26 `erlang` (the listing's `erlangian`).
pub fn zRngErlang(seed: i64, k_stage: f64, mean: f64) f64 {
    const k = zRngDf(k_stage);
    if (k <= 0) return 0.0;
    var s = zRngS32(seed);
    return zRngErlangCore(&s, k, mean);
}

pub fn zRngErlangNext(seed: i64, k_stage: f64, mean: f64) f64 {
    var s = zRngS32(seed);
    const k = zRngDf(k_stage);
    if (k > 0) _ = zRngErlangCore(&s, k, mean);
    return zRngSOut(s);
}
