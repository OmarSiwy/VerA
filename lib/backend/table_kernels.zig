// §9.21 table-model interpolation kernels — EMITTED VERBATIM into every device
// that calls `$table_model` (`codegen.table_txt` is `@embedFile` of this file)
// and `@import`ed by codegen.zig's tests, for the same reason
// `filter_kernels.zig` is: the numerics the tests check are the numerics the
// device runs.
//
// §9.21 defines the lookup as a RECURSION over dimensions, not as an
// N-dimensional formula: "We first look through the set of isolines in y and
// find the pair that bracket y1. Now for each isoline in y we find the two
// points that bracket x1 and interpolate each isoline to find f(x1,yh) and
// f(x1,yl). Having thus generated an isoline in y for the point x1 in x, we may
// interpolate this isoline to find the value f(x1,y1)." So `zTabAt` recurses on
// the dimension index and every interpolation it performs is one-dimensional —
// which is also why §9.21.2 can specify the scheme PER DIMENSION.
//
// The sample block arrives as one flat row-major array of NP rows × NCOL
// columns (§9.21.1's file layout, independents outermost-first, then the
// dependents), plus the column the control string's dependent selector picked.
// Nothing here allocates: `NP`, `NCOL`, `ND` and the extrapolation characters
// are structural constants of the call, so the row-index permutation is a
// comptime-sized stack array.
//
// Each dimension's control is three bytes: interpolation (Table 9-30 `D`, `1`,
// `2` or `3` — `I` is a COLUMN mark, not a scheme, and lowering has already
// projected the ignored columns out), then the low and the high extrapolation
// character (Table 9-31 `C`, `L` or `E`).

// `std` is spelled `ztstd` HERE for the reason `file_kernels.zig` spells it
// `zfstd`: this text is embedded verbatim into device.zig, which already
// declares `const std`, and a device may carry several kernel blocks in the one
// file scope.
const ztstd = @import("std");

/// Table 9-31 `E`: "an extrapolation error is reported if the $table_model
/// function is requested to evaluate a point beyond the interpolation region"
/// and "Error extrapolation results in a fatal error being raised." Fatal, so
/// this ends the run exactly where §9.7.3's `$fatal` does — the point that
/// triggers it is a runtime value, and there is no other answer the clause
/// permits us to return.
fn ztExtrapError() noreturn {
    ztstd.debug.print("error: $table_model: LRM 9.21.2 `E`: lookup point is beyond the interpolation region\n", .{});
    ztstd.process.exit(1);
}

/// §9.21: "If there are two or more data points with the same independent values
/// but different dependent values then an error is generated." See `zTable` for
/// why the generation point is the call and not elaboration.
fn ztDuplicateError() noreturn {
    ztstd.debug.print("error: $table_model: LRM 9.21: two data points share their independent values and disagree on the dependent\n", .{});
    ztstd.process.exit(1);
}

/// One level's answer: the interpolated value and its exact gradient in the ND
/// lookup coordinates.
///
/// The gradient is not a convenience. A device residual hands the solver a
/// Jacobian row, and `$table_model` on a probe (§9.21's own example contributes
/// `$table_model(0.0, V(a,b), "sample.dat")`) is a function OF an unknown — a
/// lookup that returned a bare value would tell the solver the table is flat
/// and cost it the Newton step. Piecewise-linear data has an exact gradient
/// everywhere but the knots, so carrying it costs one multiply-add per level.
pub fn zTabRes(comptime ND: usize) type {
    return struct { v: f64, g: [ND]f64 };
}

/// Exclusive end of the run of rows in `order` sharing row `order[start]`'s value in
/// column `dim` — i.e. one isoline of the current dimension.
///
/// §9.21.1: "Whether the data is sorted or not, the system determines the
/// isoline ordinate by reading its EXACT value from the file or array", so the
/// comparison is `==` with no tolerance. The clause's own next sentence is the
/// consequence: "Any noise on the isoline ordinate may cause the system to
/// incorrectly generate multiple isolines where the user intended a single one."
pub fn zTabEnd(comptime NCOL: usize, data: []const f64, order: []const usize, dim: usize, start: usize) usize {
    const key = data[order[start] * NCOL + dim];
    var i = start + 1;
    while (i < order.len and data[order[i] * NCOL + dim] == key) i += 1;
    return i;
}

/// Lexicographic order on the independent columns, outermost first.
pub fn zTabLess(comptime NCOL: usize, comptime ND: usize, data: []const f64, a: usize, b: usize) bool {
    for (0..ND) |d| {
        const x = data[a * NCOL + d];
        const y = data[b * NCOL + d];
        if (x != y) return x < y;
    }
    return false;
}

/// §9.21.1: "While it is suggested that the user arrange the sampled isolines in
/// sorted order (one isoline following another in all dimensions); if the user
/// provides the data in random order the system will sort the data into isolines
/// in each dimension." That sort is what makes every isoline a CONTIGUOUS run of
/// `order`, which is the whole representation `zTabEnd` and `zTabAt` rely on.
///
/// Insertion sort over the index permutation: it is O(n) on the sorted input the
/// clause tells users to write, it is stable (so §9.21's duplicate-point rule
/// keeps source order), and the block is comptime-sized with nowhere to
/// allocate.
///
/// ponytail: O(n²) on adversarial order, recomputed per lookup. Samples are
/// already fixed by the generated first-call snapshot. Cache the permutation
/// alongside them if table sizes make the repeated sort measurable.
pub fn zTabSort(comptime NCOL: usize, comptime ND: usize, data: []const f64, order: []usize) void {
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const v = order[i];
        var j = i;
        while (j > 0 and zTabLess(NCOL, ND, data, v, order[j - 1])) : (j -= 1) order[j] = order[j - 1];
        order[j] = v;
    }
}

/// One isoline's spline answer: the value and the slope along that isoline.
pub const zTabVD = struct { v: f64, d: f64 };

/// §9.21.4's splines, on ONE isoline — `xs` strictly increasing, `fs` the value
/// already reduced out of every lower dimension. `scheme` is Table 9-30's `2` or
/// `3`; `lo`/`hi` are Table 9-31's characters for the two ends.
///
/// END CONDITIONS COME FROM THE EXTRAPOLATION CHARACTERS, which §9.21.4 states
/// outright: "When formulating the cubic spline equations the desired derivative
/// of the interpolation function at both end points must be specified in order
/// to provide the complete set of constraints for the cubic spline equations. It
/// is convenient then that the table model function specifies end point
/// extrapolation behavior. If the user selects linear extrapolation this leads
/// to a natural spline. If constant extrapolation is specified the end point
/// derivative is set to zero thus avoiding a discontinuity in the first order
/// derivative at that end point." So, PER END and independently:
///
///   `L` → natural: S''= 0 at that end (the spline meets its straight
///         extrapolant with no curvature jump);
///   `C` → clamped: S' = 0 at that end (the clause's own words), which is
///         exactly the slope of the constant extrapolant on the other side;
///   `E` → the clause assigns no condition, because with `E` there is no
///         extrapolant to be continuous with. Table 9-31 makes `L` the default
///         extrapolation, so `E` takes `L`'s end condition.
///
/// Every step below — the moment solve, the segment evaluation, the extrapolant
/// — is LINEAR in `fs` with coefficients that depend only on `xs` and `t`. That
/// is what lets `zTabSplineDim` recover the gradient by running this same
/// routine once per lower-dimension gradient component.
///
/// `NP` bounds the knot count (one isoline per sample in the degenerate case),
/// so the scratch is a comptime-sized stack array and nothing allocates. Two of
/// them: the quadratic's knot slopes and the cubic's Thomas sweep share them,
/// and the cubic back-substitutes its moments into `dp` in place.
pub fn zTabSpline1(
    comptime NP: usize,
    scheme: u8,
    lo: u8,
    hi: u8,
    xs: []const f64,
    fs: []const f64,
    t: f64,
) zTabVD {
    var cp: [NP]f64 = undefined;
    var dp: [NP]f64 = undefined;
    const n = xs.len;
    if (n < 2) return .{ .v = fs[0], .d = 0.0 };

    // Table 9-31: "The constant extrapolation method returns the table endpoint
    // value" — the same clamp the linear scheme applies, and flat, so the
    // dimension contributes nothing to the Jacobian out here.
    if (lo == 'C' and t < xs[0]) return .{ .v = fs[0], .d = 0.0 };
    if (hi == 'C' and t > xs[n - 1]) return .{ .v = fs[n - 1], .d = 0.0 };

    if (scheme == '2') {
        // A C¹ quadratic spline over k intervals has 3k coefficients against
        // 2k interpolation and k−1 slope-continuity constraints, i.e. 3k−1: ONE
        // end condition fits, which is §9.21.4's "Again one should attempt to
        // avoid end point discontinuities, though it is not always possible in
        // this case." The clause does not say which end keeps its jump; VerA
        // gives it to the end §9.21.2 names first ("the first character
        // specifies the extrapolation method used for the end with the lower
        // coordinate value") and marches the slopes upward from there, so the
        // low end honours its character exactly and the high end is whatever
        // the march arrives at. `tests/pending/A05/04_quadratic_spline.va`
        // asserts only the properties both readings share, for that reason.
        //
        // With `L` (or `E`) at the low end the free slope is the first secant,
        // which flattens the first segment's second derivative to zero — the
        // quadratic's reading of "natural", and what makes the straight
        // extrapolant meet it without a curvature jump.
        const z = &cp; // S' at each knot
        z[0] = if (lo == 'C') 0.0 else (fs[1] - fs[0]) / (xs[1] - xs[0]);
        for (1..n) |i| z[i] = 2.0 * (fs[i] - fs[i - 1]) / (xs[i] - xs[i - 1]) - z[i - 1];

        if (t < xs[0]) return .{ .v = fs[0] + z[0] * (t - xs[0]), .d = z[0] };
        if (t > xs[n - 1]) return .{ .v = fs[n - 1] + z[n - 1] * (t - xs[n - 1]), .d = z[n - 1] };
        var i: usize = 0;
        while (i + 2 < n and t > xs[i + 1]) i += 1;
        const h = xs[i + 1] - xs[i];
        const u = t - xs[i];
        const c = (z[i + 1] - z[i]) / (2.0 * h);
        return .{ .v = fs[i] + z[i] * u + c * u * u, .d = z[i] + 2.0 * c * u };
    }

    // Cubic, in the moment (M = S'') form. The interior rows are the standard
    //   h₍ᵢ₋₁₎M₍ᵢ₋₁₎ + 2(h₍ᵢ₋₁₎+hᵢ)Mᵢ + hᵢM₍ᵢ₊₁₎ = 6[(f₍ᵢ₊₁₎−fᵢ)/hᵢ − (fᵢ−f₍ᵢ₋₁₎)/h₍ᵢ₋₁₎]
    // and the two end rows are the end conditions above: natural is Mₑ = 0,
    // clamped with S'(xₑ) = 0 is 2h₀M₀ + h₀M₁ = 6(f₁−f₀)/h₀ at the low end and
    // h M₍ₙ₋₂₎ + 2h M₍ₙ₋₁₎ = −6(f₍ₙ₋₁₎−f₍ₙ₋₂₎)/h at the high end. Tridiagonal,
    // so one Thomas sweep — no pivoting is needed, the system is diagonally
    // dominant for strictly increasing `xs`.
    {
        const h0 = xs[1] - xs[0];
        const b0: f64 = if (lo == 'C') 2.0 * h0 else 1.0;
        const c0: f64 = if (lo == 'C') h0 else 0.0;
        const r0: f64 = if (lo == 'C') 6.0 * (fs[1] - fs[0]) / h0 else 0.0;
        cp[0] = c0 / b0;
        dp[0] = r0 / b0;
    }
    for (1..n - 1) |i| {
        const hm = xs[i] - xs[i - 1];
        const hp = xs[i + 1] - xs[i];
        const r = 6.0 * ((fs[i + 1] - fs[i]) / hp - (fs[i] - fs[i - 1]) / hm);
        const den = 2.0 * (hm + hp) - hm * cp[i - 1];
        cp[i] = hp / den;
        dp[i] = (r - hm * dp[i - 1]) / den;
    }
    {
        const hl = xs[n - 1] - xs[n - 2];
        const an: f64 = if (hi == 'C') hl else 0.0;
        const bn: f64 = if (hi == 'C') 2.0 * hl else 1.0;
        const rn: f64 = if (hi == 'C') -6.0 * (fs[n - 1] - fs[n - 2]) / hl else 0.0;
        dp[n - 1] = (rn - an * dp[n - 2]) / (bn - an * cp[n - 2]);
    }
    // Back-substitution in place: `dp` holds the moments from here on.
    var k = n - 1;
    while (k > 0) : (k -= 1) dp[k - 1] -= cp[k - 1] * dp[k];
    const m = dp[0..n];

    // Segment `i` of the interpolant, and its slope, at `u`.
    const seg = struct {
        fn at(mm: []const f64, ax: []const f64, af: []const f64, i: usize, u: f64) zTabVD {
            const h = ax[i + 1] - ax[i];
            const a = ax[i + 1] - u;
            const b = u - ax[i];
            return .{
                .v = (mm[i] * a * a * a + mm[i + 1] * b * b * b) / (6.0 * h) +
                    (af[i] - mm[i] * h * h / 6.0) * a / h +
                    (af[i + 1] - mm[i + 1] * h * h / 6.0) * b / h,
                .d = (mm[i + 1] * b * b - mm[i] * a * a) / (2.0 * h) +
                    (af[i + 1] - af[i]) / h - (mm[i + 1] - mm[i]) * h / 6.0,
            };
        }
    }.at;

    // Table 9-31 linear extrapolation "extends linearly to the requested point
    // from the endpoint using a slope consistent with the selected interpolation
    // method" — for a spline that is the SPLINE's own end slope, not the secant
    // through the last two samples.
    if (t < xs[0]) {
        const e0 = seg(m, xs, fs, 0, xs[0]);
        return .{ .v = fs[0] + e0.d * (t - xs[0]), .d = e0.d };
    }
    if (t > xs[n - 1]) {
        const en = seg(m, xs, fs, n - 2, xs[n - 1]);
        return .{ .v = fs[n - 1] + en.d * (t - xs[n - 1]), .d = en.d };
    }
    var i: usize = 0;
    while (i + 2 < n and t > xs[i + 1]) i += 1;
    return seg(m, xs, fs, i, t);
}

/// §9.21's recursion at a dimension whose scheme is a spline. Split out of
/// `zTabAt` so its knot block — the only part of the kernel sized by `NP` rather
/// than by `ND` — is on the stack only for the calls that need it.
///
/// A spline is a property of the WHOLE isoline set in this dimension, not of a
/// bracketing pair, so every isoline is reduced through the lower dimensions
/// first and the spline is laid through the results. That is §9.21's own
/// recursion read literally ("for each isoline in y we find the two points that
/// bracket x1 and interpolate each isoline ... Having thus generated an isoline
/// in y ... we may interpolate this isoline"), with the last step's scheme
/// swapped for the one this dimension asked for.
///
/// THE GRADIENT. `zTabSpline1` is a linear functional of its `fs`, so applying
/// it to the k-th gradient component of the knot results IS the k-th component
/// of the answer's gradient; this dimension's own component is the spline slope
/// the same call already returned. ND+1 solves, no derivative of the moment
/// system needed, and the result is exact rather than a difference quotient.
pub fn zTabSplineDim(
    comptime NP: usize,
    comptime ND: usize,
    comptime NCOL: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    data: []const f64,
    order: []const usize,
    dim: usize,
    x: [ND]f64,
) zTabRes(ND) {
    var kx: [NP]f64 = undefined;
    var kr: [NP]zTabRes(ND) = undefined;
    var n: usize = 0;
    var s: usize = 0;
    while (s < order.len) : (n += 1) {
        const e = zTabEnd(NCOL, data, order, dim, s);
        kx[n] = data[order[s] * NCOL + dim];
        kr[n] = zTabAt(NP, ND, NCOL, dep, ext, data, order[s..e], dim + 1, x);
        s = e;
    }

    var buf: [NP]f64 = undefined;
    for (0..n) |i| buf[i] = kr[i].v;
    const got = zTabSpline1(NP, ext[3 * dim], ext[3 * dim + 1], ext[3 * dim + 2], kx[0..n], buf[0..n], x[dim]);
    var r: zTabRes(ND) = .{ .v = got.v, .g = @splat(0.0) };
    r.g[dim] = got.d;
    for (0..ND) |c| {
        if (c == dim) continue;
        for (0..n) |i| buf[i] = kr[i].g[c];
        r.g[c] = zTabSpline1(NP, ext[3 * dim], ext[3 * dim + 1], ext[3 * dim + 2], kx[0..n], buf[0..n], x[dim]).v;
    }
    return r;
}

/// §9.21's recursive scheme at one level. `order` is the sorted row-index block of
/// the isoline selected by the dimensions already consumed; `dim` is the
/// dimension to bracket next.
pub fn zTabAt(
    comptime NP: usize,
    comptime ND: usize,
    comptime NCOL: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    data: []const f64,
    order: []const usize,
    dim: usize,
    x: [ND]f64,
) zTabRes(ND) {
    // Every independent consumed: this block is one sample point, and its
    // dependent column is the answer. Zero gradient — the value of a sample
    // does not move with the lookup coordinates.
    if (dim == ND) return .{ .v = data[order[0] * NCOL + dep], .g = @splat(0.0) };

    var a_s: usize = 0;
    var a_e = zTabEnd(NCOL, data, order, dim, 0);
    // ONE isoline in this dimension. §9.21 requires "at least two points per
    // dimension" and that "the result of the bracketing to produce intermediate
    // points must also produce at least two points per subsequent lower
    // dimension", so this is degenerate data; VerA reports the shape it can see
    // at the call (E0815). Treating it as constant in this dimension is the only
    // other option that is not a division by a zero span.
    if (a_e == order.len) return zTabAt(NP, ND, NCOL, dep, ext, data, order[a_s..a_e], dim + 1, x);

    var b_s = a_e;
    var b_e = zTabEnd(NCOL, data, order, dim, b_s);
    // Slide the pair up while the upper isoline is still below the lookup
    // ordinate and another isoline follows it. What is left is the bracketing
    // pair when one exists, and the nearest pair at whichever end it does not.
    while (b_e < order.len and data[order[b_s] * NCOL + dim] < x[dim]) {
        a_s = b_s;
        a_e = b_e;
        b_s = b_e;
        b_e = zTabEnd(NCOL, data, order, dim, b_s);
    }
    const xa = data[order[a_s] * NCOL + dim];
    const xb = data[order[b_s] * NCOL + dim];

    // Table 9-31 `E` before any scheme gets a say: it is a condition on the
    // POINT, not on the call — "an extrapolation error is reported if the
    // $table_model function is requested to evaluate a point beyond the
    // interpolation region". The pair slid above is pinned to the low end when
    // the ordinate is under every isoline and to the high end when it is over
    // every one, so `xa`/`xb` bound the region exactly here. Strictly outside:
    // an endpoint IS the boundary of the region, not a point beyond it.
    if (x[dim] < xa and ext[3 * dim + 1] == 'E') ztExtrapError();
    if (x[dim] > xb and ext[3 * dim + 2] == 'E') ztExtrapError();

    // Table 9-30 `2`/`3`: a spline is fitted to the whole isoline set of this
    // dimension, so it does not use the bracketing pair.
    if (ext[3 * dim] == '2' or ext[3 * dim] == '3')
        return zTabSplineDim(NP, ND, NCOL, dep, ext, data, order, dim, x);

    if (ext[3 * dim] == 'D') {
        // §9.21.4 ties choose the sample farther from zero. Discrete lookup
        // has zero slope in this dimension, including at either exterior end.
        const da = @abs(x[dim] - xa);
        const db = @abs(x[dim] - xb);
        const upper = x[dim] >= xb or (x[dim] > xa and
            (db < da or (db == da and @abs(xb) >= @abs(xa))));
        const selected = if (upper) order[b_s..b_e] else order[a_s..a_e];
        return zTabAt(NP, ND, NCOL, dep, ext, data, selected, dim + 1, x);
    }

    // Table 9-31 constant extrapolation "returns the table endpoint value" —
    // the isoline at the end evaluated with THIS coordinate clamped into range,
    // which is what dropping to the endpoint isoline with a zero slope in `dim`
    // means. `ext[3*dim+1]` is the low end and `ext[3*dim+2]` the high end;
    // §9.21.2 fixes that order ("the first character specifies the
    // extrapolation method used for the end with the lower coordinate value").
    if (x[dim] < xa and ext[3 * dim + 1] == 'C')
        return zTabAt(NP, ND, NCOL, dep, ext, data, order[a_s..a_e], dim + 1, x);
    if (x[dim] > xb and ext[3 * dim + 2] == 'C')
        return zTabAt(NP, ND, NCOL, dep, ext, data, order[b_s..b_e], dim + 1, x);

    const ra = zTabAt(NP, ND, NCOL, dep, ext, data, order[a_s..a_e], dim + 1, x);
    const rb = zTabAt(NP, ND, NCOL, dep, ext, data, order[b_s..b_e], dim + 1, x);
    // Linear interpolation and LINEAR extrapolation are the same affine segment
    // — Table 9-31: linear extrapolation "extends linearly to the requested
    // point from the endpoint using a slope consistent with the selected
    // interpolation method" — so `t` outside [0,1] needs nothing written for it.
    const t = (x[dim] - xa) / (xb - xa);
    var r: zTabRes(ND) = .{ .v = ra.v + t * (rb.v - ra.v), .g = undefined };
    for (0..ND) |k| r.g[k] = ra.g[k] + t * (rb.g[k] - ra.g[k]);
    r.g[dim] = (rb.v - ra.v) / (xb - xa); // this dimension's own slope
    return r;
}

/// §9.21 the whole lookup, in the solver's scalar interface.
pub fn zTable(
    comptime S: type,
    comptime NP: usize,
    comptime NCOL: usize,
    comptime ND: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    rows: [NP * NCOL]f64,
    pt: [ND]S,
) S {
    var order: [NP]usize = undefined;
    for (0..NP) |i| order[i] = i;
    zTabSort(NCOL, ND, &rows, &order);

    // §9.21: "Within the data set, each point shall be distinct in terms of its
    // independent variable values. If there are two or more data points with the
    // same independent and dependent values, then the duplicates shall be
    // ignored and the tool may generate a warning. If there are two or more data
    // points with the same independent values but different dependent values
    // then an error is generated."
    //
    // The benign half needs no code: the sort is stable and the recursion's
    // terminal level reads `order[0]` of the block, so an identical repeat is
    // already ignored. The conflicting half is checked HERE, at the call — the
    // dependents may be expressions of the solution (§9.21.1 captures the data
    // source "on the first call to the table model function"), so a table whose
    // conflict only exists at a particular operating point cannot be diagnosed
    // anywhere earlier, and a site that never runs is never diagnosed at all.
    // `order` is sorted, so neighbours that are not strictly increasing are
    // equal in every independent.
    for (1..NP) |i| {
        if (zTabLess(NCOL, ND, &rows, order[i - 1], order[i])) continue;
        if (rows[order[i - 1] * NCOL + dep] != rows[order[i] * NCOL + dep]) ztDuplicateError();
    }

    var x: [ND]f64 = undefined;
    for (0..ND) |d| x[d] = pt[d].val();
    const r = zTabAt(NP, ND, NCOL, dep, ext, &rows, &order, 0, x);

    // Every scheme carries its own exact gradient out of the recursion (a
    // spline's is its own slope, not a secant), so ONE affine reconstruction
    // carries both the value and the exact Jacobian row: `pt[d].addC(-x[d])` is the zero at
    // this operating point whose derivative is still ∂pt[d]/∂unknown, so scaling
    // it by ∂f/∂x[d] and summing gives the chain rule with the value untouched.
    var out = S.con(r.v);
    for (0..ND) |d| out = out.add(pt[d].addC(-x[d]).scale(r.g[d]));
    return out;
}
