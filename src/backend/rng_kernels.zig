// §9.13 probabilistic distribution kernels — EMITTED VERBATIM into every device
// that calls one of Table 9-10's 17 names (`codegen.rng_txt` is `@embedFile` of
// this file) and `@import`ed by codegen.zig's tests, on the same terms as
// `str_kernels.zig` and `table_kernels.zig`: one source, so what the tests
// exercise is byte-for-byte what the device runs.
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
// seed (`zRngNext`) — exactly as `lowerScan` splits `$sscanf` into one call per
// out-parameter. Re-evaluating the analog block re-derives both from the same
// input, so §9.13.2's "the system functions shall always return the same value
// given the same seed" and Newton's need for a fixed residual are the same
// requirement, met by the same code.
//
// The seedless forms (`$random`, `$arandom` with the seed omitted, and a
// constant/parameter seed, whose §9.13.1 "internal seed" is not visible from the
// source) have no such variable. Their state is a latch in `Instance`, drawn in
// the per-point sampling phase (`updateState`, the accepted-step boundary) and
// only READ by the residual — same discipline, different owner.
//
// SCOPE: WHICH STREAM. §9.13.3 says "the algorithms for the probabilistic
// distribution functions are defined in IEEE 1364-2005 17.9.3" and prints the
// reference C there; no clause of this LRM requires a tool to reproduce that
// stream, and none of this suite's fixtures asserts a drawn digit — they assert
// repeatability on a seed, that the inout seed changed, the 32-bit width of
// §9.13.1's result, and $rdist_uniform's start/end bound. So the core here is
// the Lehmer minimal-standard generator 1364's listing is built on (multiplier
// 16807, modulus 2^31-1) WITHOUT its Numerical-Recipes shuffle table, which
// cannot be carried in the single `integer` the LRM gives the seed anyway.
//
// ponytail: if a future fixture pins a digit from 1364's listing, this file is
// where the shuffle table and the exact per-distribution routines go; the
// call-site contract (pure in the seed, one step per call) does not change.

// There is deliberately no `const std` here — unlike `str_kernels.zig` this file
// needs nothing from it, and every declaration below is emitted verbatim into
// device.zig, where a second `std` at file scope would be a redeclaration.

/// Fold any `integer` the user put in the seed onto the Lehmer generator's state
/// space [1, 2^31-2]. §9.13.1's Syntax 9-8 admits `[ sign ] decimal_number`, so
/// a negative seed is legal and has to land somewhere; 0 is the one state the
/// multiplicative generator cannot leave, so it maps to 1.
fn zRngNorm(seed: i64) u64 {
    const im: u64 = 2147483647; // 2^31-1
    // `@abs` of an i64 is a u64, so the most negative seed folds without the
    // overflow a negate-then-compare would take.
    const a: u64 = @as(u64, @abs(seed)) % im;
    return if (a == 0) 1 else a;
}

/// §9.13.1/§9.13.2 the updated seed: "a value is passed to the function and A
/// DIFFERENT VALUE IS RETURNED". One Lehmer step, `s' = 16807·s mod 2^31-1`,
/// which has no fixed point on [1, 2^31-2] — so the fixtures' `sa != 7` holds
/// for every legal seed, not just for seven.
///
/// Returned as f64 because every emitted `$rng$*` callee is real-typed and
/// lowering converts (§4.2.1.1); the state is below 2^31 and therefore exact.
pub fn zRngNext(seed: i64) f64 {
    const im: u64 = 2147483647;
    return @floatFromInt((16807 * zRngNorm(seed)) % im);
}

/// The `k`-th independent uniform on [0,1) belonging to seed state `seed`.
///
/// Indexed rather than sequential ON PURPOSE. A distribution needing three
/// uniforms must not leave the seed three steps further on than one needing a
/// single uniform, because `zRngNext` above is a SEPARATE call that knows only
/// the seed — it cannot know which distribution consumed how much. So every
/// §9.13 call advances the seed by exactly one step, and a distribution that
/// wants several uniforms asks for several INDICES into this seed's own stream.
/// Independence comes from the finalizer, not from iteration.
fn zRngU(seed: i64, k: u64) f64 {
    var h: u64 = zRngNorm(seed) ^ ((k +% 1) *% 0x9E3779B97F4A7C15);
    h = (h ^ (h >> 30)) *% 0xBF58476D1CE4E5B9;
    h = (h ^ (h >> 27)) *% 0x94D049BB133111EB;
    h ^= h >> 31;
    // 53 bits is the whole mantissa: the result is in [0,1) and never rounds up
    // to 1.0, which the log-based transforms below depend on.
    return @as(f64, @floatFromInt(h >> 11)) * 0x1p-53;
}

/// §9.13.1 `$random`/`$arandom`: "the random number returned is a 32-bit signed
/// integer; it can be positive or negative."
///
/// The Lehmer state is 31 bits and strictly positive, so it is NOT the answer —
/// it can never be negative and would fail the clause. The state is mixed to a
/// full 32 bits and reinterpreted as signed, which is a bijection on the mixed
/// word and therefore neither biases nor loses the state's period.
pub fn zRngRand(seed: i64) f64 {
    const u: u32 = @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(zRngNext(seed))))) *% 0x9E3779B9);
    return @floatFromInt(@as(i32, @bitCast(u)));
}

/// IEEE 1364 §17.9.2 `$dist_uniform(seed, start, end)`: an INTEGER in the closed
/// range [start, end]. Closed, so the span is `end - start + 1` and the floor of
/// a [0,1) uniform scaled by it lands on `end` only in the top bucket. `start >
/// end` is degenerate and returns `start`, the same answer 1364's listing gives.
pub fn zRngIUniform(seed: i64, start: f64, end: f64) f64 {
    const lo = @round(start);
    const hi = @round(end);
    if (lo >= hi) return lo;
    const span = hi - lo + 1.0;
    return @min(hi, lo + @floor(zRngU(seed, 0) * span));
}

/// §9.13.2 `$rdist_uniform`: "the start and end arguments are real inputs which
/// BOUND the values returned". Half-open at `end`, so the bound is never
/// exceeded even by a rounding of the product.
pub fn zRngUniform(seed: i64, start: f64, end: f64) f64 {
    if (start >= end) return start;
    return @min(end, start + zRngU(seed, 0) * (end - start));
}

/// A standard normal from the two uniforms at indices `k` and `k+1` (Box-Muller).
/// `1 - u` is in (0,1] so the logarithm is always finite.
fn zRngZ(seed: i64, k: u64) f64 {
    // Spelled `ua`/`ub` and not `u0`/`u1`: this text is emitted into device.zig,
    // where `u0` and `u1` shadow the primitive integer types.
    const ua = 1.0 - zRngU(seed, k);
    const ub = zRngU(seed, k + 1);
    return @sqrt(-2.0 * @log(ua)) * @cos(6.283185307179586 * ub);
}

/// §9.13.2 `$rdist_normal(seed, mean, standard_deviation)` — "Using a mean of
/// zero (0) and a standard_deviation of one (1), $rdist_normal generates
/// Gaussian distribution."
pub fn zRngNormal(seed: i64, mean: f64, sd: f64) f64 {
    return mean + sd * zRngZ(seed, 0);
}

/// §9.13.2 `$rdist_exponential(seed, mean)`. Inverse transform, so the result is
/// non-negative for any `mean > 0` — and the domain rule ("mean ... shall be
/// greater than zero") is enforced in lowering, not defended again here.
pub fn zRngExponential(seed: i64, mean: f64) f64 {
    return -mean * @log(1.0 - zRngU(seed, 0));
}

/// §9.13.2 `$rdist_poisson(seed, mean)`. Inversion on the Poisson CDF: multiply
/// out `p·mean/k` until the cumulative mass passes the uniform.
///
/// The iteration bound is a guard, not a distribution parameter: the expected
/// count is `mean`, so a large mean walks proportionally far and a bound keeps a
/// device evaluation from becoming unbounded work inside a Newton iteration.
pub fn zRngPoisson(seed: i64, mean: f64) f64 {
    const u = zRngU(seed, 0);
    var p = @exp(-mean);
    var cdf = p;
    var k: f64 = 0.0;
    while (u > cdf and k < 100000.0) {
        k += 1.0;
        p *= mean / k;
        cdf += p;
    }
    return k;
}

/// §9.13.2 `$rdist_chi_square(seed, degree_of_freedom)` — the sum of `df`
/// squared standard normals, which is the definition IEEE 1364 §17.9.3's routine
/// implements. Each summand takes its own pair of stream indices.
///
/// ponytail: 4096 degrees of freedom is the ceiling, for the same reason
/// `zRngPoisson` has one. Beyond it a normal approximation is the upgrade path.
pub fn zRngChiSquare(seed: i64, df: f64) f64 {
    const n: u64 = @intFromFloat(@min(4096.0, @max(1.0, @round(df))));
    var acc: f64 = 0.0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const z = zRngZ(seed, 2 * i);
        acc += z * z;
    }
    return acc;
}

/// §9.13.2 `$rdist_t(seed, degree_of_freedom)` — Student's t as a standard
/// normal over the root of a chi-square per degree of freedom. The two draws
/// come from disjoint index ranges of the same seed's stream, so they are
/// independent: the chi-square starts at index 2 and the normal owns 0 and 1.
pub fn zRngT(seed: i64, df: f64) f64 {
    const n = @min(4096.0, @max(1.0, @round(df)));
    var acc: f64 = 0.0;
    var i: u64 = 0;
    while (i < @as(u64, @intFromFloat(n))) : (i += 1) {
        const z = zRngZ(seed, 2 + 2 * i);
        acc += z * z;
    }
    if (acc <= 0.0) return 0.0;
    return zRngZ(seed, 0) / @sqrt(acc / n);
}

/// §9.13.2 `$rdist_erlang(seed, k_stage, mean)` — the k-stage Erlang, the sum of
/// `k_stage` exponential stages. The stage mean is `mean / k_stage` so that the
/// SUM has the requested mean, which is what makes `mean` the argument's name.
pub fn zRngErlang(seed: i64, k_stage: f64, mean: f64) f64 {
    const n = @min(4096.0, @max(1.0, @round(k_stage)));
    const per = mean / n;
    var acc: f64 = 0.0;
    var i: u64 = 0;
    while (i < @as(u64, @intFromFloat(n))) : (i += 1)
        acc += -per * @log(1.0 - zRngU(seed, i));
    return acc;
}
