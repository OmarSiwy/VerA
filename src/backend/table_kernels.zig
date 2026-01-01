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
// Only LINEAR interpolation reaches here. Table 9-30's `D`/`2`/`3` and Table
// 9-31's `E` are refused at the call (E0815) rather than approximated, so a
// substring that got this far is `1` plus two of `C`/`L`.

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

/// Exclusive end of the run of rows in `sel` sharing row `sel[start]`'s value in
/// column `dim` — i.e. one isoline of the current dimension.
///
/// §9.21.1: "Whether the data is sorted or not, the system determines the
/// isoline ordinate by reading its EXACT value from the file or array", so the
/// comparison is `==` with no tolerance. The clause's own next sentence is the
/// consequence: "Any noise on the isoline ordinate may cause the system to
/// incorrectly generate multiple isolines where the user intended a single one."
pub fn zTabEnd(comptime NCOL: usize, data: []const f64, sel: []const usize, dim: usize, start: usize) usize {
    const key = data[sel[start] * NCOL + dim];
    var i = start + 1;
    while (i < sel.len and data[sel[i] * NCOL + dim] == key) i += 1;
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
/// `sel`, which is the whole representation `zTabEnd` and `zTabAt` rely on.
///
/// Insertion sort over the index permutation: it is O(n) on the sorted input the
/// clause tells users to write, it is stable (so §9.21's duplicate-point rule
/// keeps source order), and the block is comptime-sized with nowhere to
/// allocate.
///
/// ponytail: O(n²) on adversarial order, and it runs on every residual
/// evaluation — §9.21.1's "The state of the data source is captured on the first
/// call to the table model function. Any change after this point is ignored."
/// licenses doing it exactly once, but VerA has no per-instance table cache to
/// hold the permutation in. Hoist it into `Instance` the day a model carries a
/// table big enough to measure.
pub fn zTabSort(comptime NCOL: usize, comptime ND: usize, data: []const f64, sel: []usize) void {
    var i: usize = 1;
    while (i < sel.len) : (i += 1) {
        const v = sel[i];
        var j = i;
        while (j > 0 and zTabLess(NCOL, ND, data, v, sel[j - 1])) : (j -= 1) sel[j] = sel[j - 1];
        sel[j] = v;
    }
}

/// §9.21's recursive scheme at one level. `sel` is the sorted row-index block of
/// the isoline selected by the dimensions already consumed; `dim` is the
/// dimension to bracket next.
pub fn zTabAt(
    comptime ND: usize,
    comptime NCOL: usize,
    comptime dep: usize,
    comptime ext: []const u8,
    data: []const f64,
    sel: []const usize,
    dim: usize,
    x: [ND]f64,
) zTabRes(ND) {
    // Every independent consumed: this block is one sample point, and its
    // dependent column is the answer. Zero gradient — the value of a sample
    // does not move with the lookup coordinates.
    if (dim == ND) return .{ .v = data[sel[0] * NCOL + dep], .g = @splat(0.0) };

    var a_s: usize = 0;
    var a_e = zTabEnd(NCOL, data, sel, dim, 0);
    // ONE isoline in this dimension. §9.21 requires "at least two points per
    // dimension" and that "the result of the bracketing to produce intermediate
    // points must also produce at least two points per subsequent lower
    // dimension", so this is degenerate data; VerA reports the shape it can see
    // at the call (E0815). Treating it as constant in this dimension is the only
    // other option that is not a division by a zero span.
    if (a_e == sel.len) return zTabAt(ND, NCOL, dep, ext, data, sel[a_s..a_e], dim + 1, x);

    var b_s = a_e;
    var b_e = zTabEnd(NCOL, data, sel, dim, b_s);
    // Slide the pair up while the upper isoline is still below the lookup
    // ordinate and another isoline follows it. What is left is the bracketing
    // pair when one exists, and the nearest pair at whichever end it does not.
    while (b_e < sel.len and data[sel[b_s] * NCOL + dim] < x[dim]) {
        a_s = b_s;
        a_e = b_e;
        b_s = b_e;
        b_e = zTabEnd(NCOL, data, sel, dim, b_s);
    }
    const xa = data[sel[a_s] * NCOL + dim];
    const xb = data[sel[b_s] * NCOL + dim];

    // Table 9-31 constant extrapolation "returns the table endpoint value" —
    // the isoline at the end evaluated with THIS coordinate clamped into range,
    // which is what dropping to the endpoint isoline with a zero slope in `dim`
    // means. `ext[2*dim]` is the low end and `ext[2*dim+1]` the high end;
    // §9.21.2 fixes that order ("the first character specifies the
    // extrapolation method used for the end with the lower coordinate value").
    if (x[dim] < xa and ext[2 * dim] == 'C')
        return zTabAt(ND, NCOL, dep, ext, data, sel[a_s..a_e], dim + 1, x);
    if (x[dim] > xb and ext[2 * dim + 1] == 'C')
        return zTabAt(ND, NCOL, dep, ext, data, sel[b_s..b_e], dim + 1, x);

    const ra = zTabAt(ND, NCOL, dep, ext, data, sel[a_s..a_e], dim + 1, x);
    const rb = zTabAt(ND, NCOL, dep, ext, data, sel[b_s..b_e], dim + 1, x);
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
    var sel: [NP]usize = undefined;
    for (0..NP) |i| sel[i] = i;
    zTabSort(NCOL, ND, &rows, &sel);

    var x: [ND]f64 = undefined;
    for (0..ND) |d| x[d] = pt[d].val();
    const r = zTabAt(ND, NCOL, dep, ext, &rows, &sel, 0, x);

    // The scheme is piecewise linear, so ONE affine reconstruction carries both
    // the value and the exact Jacobian row: `pt[d].addC(-x[d])` is the zero at
    // this operating point whose derivative is still ∂pt[d]/∂unknown, so scaling
    // it by ∂f/∂x[d] and summing gives the chain rule with the value untouched.
    var out = S.con(r.v);
    for (0..ND) |d| out = out.add(pt[d].addC(-x[d]).scale(r.g[d]));
    return out;
}
