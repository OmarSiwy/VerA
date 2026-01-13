// §4.5.15 SPICE voltage-limiting kernels — EMITTED VERBATIM into every device
// that honours a `$limit` call (`codegen.limit_txt` is `@embedFile` of this
// file) and `@import`ed by codegen.zig's tests, for the same reason
// `filter_kernels.zig` is: the numerics the tests check are the numerics the
// device runs. Until this file existed they were a string literal in
// `cg_limit.zig` and nothing could call them.
//
// Transcribed from ngspice `src/spicelib/devices/devsup.c` — which is what the
// `"pnjlim"`/`"fetlim"`/`"limvds"` identifiers in a `.va` name. §4.5.15 leaves
// the algorithm implementation-defined, so the LRM fixes nothing here except
// §9.17.3's "when the simulator has converged, the return value of the $limit()
// function is the value of the access function reference" — i.e. a converged
// bias must come back UNCHANGED. That transparency is the property the
// `annex_e_spice/limit_*.va` fixtures assert and the one the tests below pin.
//
// BRANCHLESS (simd-first T7): the pub kernels compute every candidate
// unconditionally and combine with selects, so the predictor sees constant
// behaviour whether or not the clamp fires — the ngspice control flow survives
// only in the `*Oracle` transcriptions below, kept as the differential-test
// reference (T8 step 5). Two rules make that transformation exact:
//
//   * CLAMP BEFORE LOG. A branchless kernel evaluates its dead paths, so every
//     `@log` argument is clamped with `@max(x, 0.0)` FIRST — never log a
//     negative on a dead path and lean on the select to mask the NaN
//     (proof.zig's guard-fact license demands the clamp; a masked NaN is one
//     maxnum-semantics change away from escaping). The floor is 0.0, not some
//     epsilon, because it must be invisible on every LIVE path: the guards
//     bound live arguments to ≥ 0 but division/subtraction rounding can land
//     them EXACTLY on 0 (`(vnew-vold)/vt` rounding down to 2.0 makes
//     `arg-2.0 == 0`), where the oracle takes `@log(0) = -inf` — and so does
//     the clamped kernel, bit-identically. An epsilon floor would differ there.
//     The clamp is only sound on the physical domain `vt > 0`, `vcrit > 0`
//     (vcrit = vt·ln(vt/(√2·Is)) is positive whenever vt > √2·Is): outside it
//     the ORACLE itself logs a negative and returns NaN, which no clamp can
//     reproduce. cg_limit only ever passes physical vt/vcrit.
//
//   * SAME FORMULA, SAME ORDER. Each candidate is the oracle's expression
//     verbatim, and equal-value ties resolve through the identical builtin
//     (`@max`/`@min`/select), so damped results are bit-identical too, and a
//     path the oracle leaves untouched returns `vnew0` BIT-IDENTICALLY —
//     `cg_limit.emitClamp` reads "the clamp fired" off the returned value
//     differing from the one passed in, which is only a truthful convergence
//     flag under that exact transparency.
//
// Nothing here allocates or reads the enclosing device: each is a pure f64
// function of the new iterate, the previous one, and the algorithm's own
// constants.

/// Two-way pick, BIT-SELECT spelling: mask is all-ones/all-zeros from the
/// bool, result is exactly `a`'s or `b`'s bit pattern. NOT `if (c) a else b`,
/// and not a bare `(m & a) | (~m & b)` either — LLVM folds both back into a
/// `select` and then branch-lowers every keep-vs-modify one (verified:
/// `-femit-asm` showed `ja`/`jbe` inside the kernels guarding the arm's
/// computation) because it likes sinking a one-use arm behind a jump. The
/// empty asm makes each arm's bits opaque, so there is no instruction to sink
/// and the select stays data-flow. `"r"` is a GPR on every target Zig names.
inline fn sel(c: bool, a: f64, b: f64) f64 {
    var av: u64 = @bitCast(a);
    var bv: u64 = @bitCast(b);
    asm volatile (""
        : [av] "+r" (av),
          [bv] "+r" (bv),
    );
    const m = @as(u64, 0) -% @intFromBool(c);
    return @bitCast((m & av) | (~m & bv));
}

/// SPICE3 `DEVpnjlim`: damp a p-n junction's exponential. `vt` is the
/// junction's thermal voltage and `vcrit` the bias where its exponential
/// starts to outrun Newton, i.e. `vt*ln(vt/(sqrt(2)*is))`. Branchless; see
/// header. Requires the physical domain `vt > 0`, `vcrit > 0`.
pub fn zPnjlim(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    const arg = (vnew0 - vold) / vt;
    // Damping candidates, all evaluated. Live guards: d_up needs arg ≥ 2 (so
    // arg-2 ≥ 0), d_dn needs arg ≤ -2 (so 2-arg ≥ 4), d_log needs
    // vnew0 > vcrit > 0 (so vnew0/vt ≥ 0 after rounding) — the 0.0 clamp only
    // ever rewrites DEAD arguments.
    const d_up = vold + vt * (2.0 + @log(@max(arg - 2.0, 0.0)));
    const d_dn = vold - vt * (2.0 + @log(@max(2.0 - arg, 0.0)));
    const d_log = vt * @log(@max(vnew0 / vt, 0.0));
    const damped = sel(vold > 0.0, sel(arg > 0.0, d_up, d_dn), d_log);
    // The negative-excursion floor of the oracle's `else if` arm.
    const floor = sel(vold > 0.0, -vold - 1.0, 2.0 * vold - 1.0);
    const floored = sel(vnew0 < 0.0 and vnew0 < floor, floor, vnew0);
    const damp = vnew0 > vcrit and @abs(vnew0 - vold) > vt + vt;
    return sel(damp, damped, floored);
}

/// SPICE3 `DEVfetlim`: keep a gate bias from stepping across threshold in
/// one Newton iteration. `vto` is the threshold voltage. Branchless; no logs,
/// so no domain caveat — exact on all finite inputs.
pub fn zFetlim(vnew0: f64, vold: f64, vto: f64) f64 {
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;
    const delv = vnew0 - vold;
    const down = delv <= 0.0;
    // ngspice's MAX/MIN are `?:` ternaries, i.e. exactly `sel` — NOT Zig's
    // `@max`/`@min`, whose maxnum NaN-fixup select got branch-lowered here.
    // vold ≥ vtox: going off keeps a floor, staying on caps the step.
    const flr = vto + 2.0;
    const hi_dn = sel(vnew0 >= vtox, sel(-delv > vtstlo, vold - vtstlo, vnew0), sel(vnew0 > flr, vnew0, flr));
    const hi_up = sel(delv >= vtsthi, vold + vtsthi, vnew0);
    const r_hi = sel(down, hi_dn, hi_up);
    // vto ≤ vold < vtox: plain clamp about threshold.
    const lo_b = vto - 0.5;
    const hi_b = vto + 4.0;
    const r_mid = sel(down, sel(vnew0 > lo_b, vnew0, lo_b), sel(vnew0 < hi_b, vnew0, hi_b));
    const r_on = sel(vold >= vtox, r_hi, r_mid);
    // vold < vto (off): symmetric step bounds, ceiling at vto+0.5 going on.
    const off_dn = sel(-delv > vtsthi, vold - vtsthi, vnew0);
    const off_up = sel(vnew0 <= vto + 0.5, sel(delv > vtstlo, vold + vtstlo, vnew0), vto + 0.5);
    const r_off = sel(down, off_dn, off_up);
    return sel(vold >= vto, r_on, r_off);
}

/// SPICE3 `DEVlimvds`: bound a drain-source step. Takes no model data —
/// the numbers are the algorithm. Branchless; exact on all finite inputs.
pub fn zLimvds(vnew0: f64, vold: f64) f64 {
    const r_hi = sel(vnew0 > vold, @min(vnew0, 3.0 * vold + 2.0), sel(vnew0 < 3.5, @max(vnew0, 2.0), vnew0));
    const r_lo = sel(vnew0 > vold, @min(vnew0, 4.0), @max(vnew0, -0.5));
    return sel(vold >= 3.5, r_hi, r_lo);
}

// ------------------------------------------------------------------ oracles
// The original branchy ngspice transcriptions, verbatim. NOT emitted callers'
// API (cg_limit emits `zPnjlim` etc. by name) — these exist so the
// differential test below can pin the branchless kernels bit-for-bit
// (simd-first T8: keep the scalar reference after the fast one ships).

fn zPnjlimOracle(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    var vnew = vnew0;
    if (vnew > vcrit and @abs(vnew - vold) > vt + vt) {
        if (vold > 0.0) {
            // The guard above makes |arg| > 2, so both logs take a
            // strictly positive argument (or exactly 0 after rounding).
            const arg = (vnew - vold) / vt;
            vnew = if (arg > 0.0)
                vold + vt * (2.0 + @log(arg - 2.0))
            else
                vold - vt * (2.0 + @log(2.0 - arg));
        } else {
            vnew = vt * @log(vnew / vt);
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

// The differential test lives HERE, not in ref/SIMD-Strategies/verify.zig,
// because `zig run verify.zig` roots the module at ref/SIMD-Strategies/ and a
// `@import("../../src/…")` escapes it. codegen.zig's tests `@import` this
// file, so `zig build test-va` picks this block up.
test "§4.5.15 branchless limiters ≡ branchy ngspice oracles, bit for bit" {
    // NOT `std`: this file is embedded verbatim into device.zig, whose file-scope
    // `std` a test-local of the same name would shadow (AstGen error).
    const stdx = @import("std");
    const expectBits = struct {
        fn eq(a: f64, b: f64) !void {
            try stdx.testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
        }
    }.eq;

    var prng = stdx.Random.DefaultPrng.init(0x5eed_4515);
    const rand = prng.random();
    // Signed magnitude in 1e-12..1e3 (log-uniform), both signs.
    const draw = struct {
        fn any(r: stdx.Random) f64 {
            const m = stdx.math.pow(f64, 10.0, -12.0 + 15.0 * r.float(f64));
            return if (r.boolean()) m else -m;
        }
        fn pos(r: stdx.Random) f64 {
            return stdx.math.pow(f64, 10.0, -12.0 + 15.0 * r.float(f64));
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
        try expectBits(zPnjlim(vnew, vold, vt, vcrit), zPnjlimOracle(vnew, vold, vt, vcrit));
        try expectBits(zFetlim(vnew, vold, vto), zFetlimOracle(vnew, vold, vto));
        try expectBits(zLimvds(vnew, vold), zLimvdsOracle(vnew, vold));

        // Exact boundary hits, derived from the same random draws so they land
        // on every magnitude: each guard's `==` case must stay transparent.
        try expectBits(zPnjlim(vcrit, vold, vt, vcrit), zPnjlimOracle(vcrit, vold, vt, vcrit)); // vnew == vcrit
        try expectBits(zPnjlim(vold + (vt + vt), vold, vt, vcrit), zPnjlimOracle(vold + (vt + vt), vold, vt, vcrit)); // |Δ| == 2vt
        try expectBits(zPnjlim(vold - (vt + vt), vold, vt, vcrit), zPnjlimOracle(vold - (vt + vt), vold, vt, vcrit));
        try expectBits(zPnjlim(-vold - 1.0, vold, vt, vcrit), zPnjlimOracle(-vold - 1.0, vold, vt, vcrit)); // vnew == floor
        try expectBits(zPnjlim(vnew, 0.0, vt, vcrit), zPnjlimOracle(vnew, 0.0, vt, vcrit)); // vold on its sign guard
        try expectBits(zFetlim(vnew, vto, vto), zFetlimOracle(vnew, vto, vto)); // vold == vto
        try expectBits(zFetlim(vnew, vto + 3.5, vto), zFetlimOracle(vnew, vto + 3.5, vto)); // vold == vtox
        try expectBits(zFetlim(vold, vold, vto), zFetlimOracle(vold, vold, vto)); // delv == 0
        try expectBits(zFetlim(vto + 0.5, vold, vto), zFetlimOracle(vto + 0.5, vold, vto)); // vnew == vtemp
        try expectBits(zFetlim(vto + 2.0, vold, vto), zFetlimOracle(vto + 2.0, vold, vto));
        try expectBits(zLimvds(vnew, 3.5), zLimvdsOracle(vnew, 3.5)); // vold on 3.5
        try expectBits(zLimvds(3.5, vold), zLimvdsOracle(3.5, vold)); // vnew on 3.5
        try expectBits(zLimvds(vold, vold), zLimvdsOracle(vold, vold)); // vnew == vold
        try expectBits(zLimvds(4.0, vold), zLimvdsOracle(4.0, vold));
        try expectBits(zLimvds(-0.5, vold), zLimvdsOracle(-0.5, vold));
        try expectBits(zLimvds(3.0 * vold + 2.0, vold), zLimvdsOracle(3.0 * vold + 2.0, vold));
    }

    // Signed-zero ties through the MAX/MIN ternaries: vto placing a bound at
    // exactly 0.0 while vnew is ±0.0.
    for ([_]f64{ -2.0, 0.5, -4.0 }) |vto| {
        for ([_]f64{ 0.0, -0.0 }) |z| {
            for ([_]f64{ 1.0, -1.0, 5.0, -5.0, 0.0 }) |vold| {
                try expectBits(zFetlim(z, vold, vto), zFetlimOracle(z, vold, vto));
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
            try expectBits(zFetlim(vnew, vold, vto), zFetlimOracle(vnew, vold, vto));
    }
}
