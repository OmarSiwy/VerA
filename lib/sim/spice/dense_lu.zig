//! Dense row-major LU with partial pivoting and SIMD row operations, for the
//! small dense f64 systems: the deck runner's Newton matrix and its stacked
//! real G + jwC noise system. Matrices are n x n, row-major, stride n. From
//! n = 40 elimination runs in rank-8 panels; the unblocked loops are its
//! bitwise oracle.
//!
//! In: an n x n matrix and a right-hand side; out: the solution, or
//! `error.Singular`.
//!
//! Copied from OmarSiwy/ESPice src/solver/dense_lu.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d. Adapted: the negated
//! right-hand side is a plain loop where ESPice calls
//! `core.numerics.scale`. Not taken: `factorizeSolve` and `solveFactored`
//! (with `fmsSolveSimd`), which nothing here calls: the Newton step is
//! `factorizeSolveNeg` and the noise adjoint `solveFactoredT`.
//!
//! LRM: none; plain numerical linear algebra.

const std = @import("std");

// ponytail: rank-8 panels are the only blocking; 2-D register tiling of the
// trailing update is next if dense solves dominate again.

/// A pivot fell below eps^2.
pub const Error = error{Singular};

const W = std.simd.suggestVectorLength(f64) orelse 1;
const V = @Vector(W, f64);
/// Pivot magnitudes below eps^2 (4.9e-32) count as zero.
const singular_tol: f64 = std.math.floatEps(f64) * std.math.floatEps(f64);

/// Writes x = -A^-1 b, the Newton step, in one elimination pass. Destroys
/// `a` (row-major n x n). `b` and `x` must not alias. Returns
/// `error.Singular` when a pivot falls below eps^2, with `a` and `x`
/// partial. Asserts that `a` holds n² values and `b`, `x` n each. O(n³).
pub fn factorizeSolveNeg(n: usize, a: []f64, b: []const f64, x: []f64) Error!void {
    std.debug.assert(a.len >= n * n);
    std.debug.assert(b.len >= n);
    std.debug.assert(x.len >= n);
    for (x[0..n], b[0..n]) |*xi, bi| xi.* = -bi;
    if (n >= blocked_min) {
        try eliminateBlocked(n, a, &.{}, x, .solve);
        return backSubstitute(n, a, x);
    }

    for (0..n) |k| {
        const max_row = pivotRow(n, a, k);
        if (@abs(a[max_row * n + k]) < singular_tol) return error.Singular;
        if (max_row != k) {
            swapRows(a, n, k, max_row);
            std.mem.swap(f64, &x[k], &x[max_row]);
        }
        const pivot = a[k * n + k];
        const inv_pivot = @as(f64, 1.0) / pivot;
        const row_k = a[k * n ..][0..n];
        for (k + 1..n) |ii| {
            const factor = a[ii * n + k] * inv_pivot;
            const row_i = a[ii * n ..][0..n];
            elimRow(row_i, row_k, factor, k + 1, n);
            x[ii] -= factor * x[k];
        }
    }

    backSubstitute(n, a, x);
}

/// Factors PA = LU in place: unit-lower L below the diagonal, U on and
/// above it. `piv[k]` is the row swapped with row k at step k (LAPACK
/// convention). Returns `error.Singular` when a pivot falls below eps^2,
/// with `a` and `piv` partial. Asserts that `a` holds n² values and `piv`
/// n. O(n³).
pub fn factorize(n: usize, a: []f64, piv: []u32) Error!void {
    std.debug.assert(a.len >= n * n);
    std.debug.assert(piv.len >= n);
    if (n >= blocked_min) return eliminateBlocked(n, a, piv, &.{}, .factor);
    for (0..n) |k| {
        const max_row = pivotRow(n, a, k);
        piv[k] = @intCast(max_row);
        if (max_row != k) swapRows(a, n, k, max_row);

        const pivot = a[k * n + k];
        if (@abs(pivot) < singular_tol) return error.Singular;
        const inv_pivot = @as(f64, 1.0) / pivot;
        const row_k = a[k * n ..][0..n];
        for (k + 1..n) |ii| {
            const factor = a[ii * n + k] * inv_pivot;
            a[ii * n + k] = factor;
            const row_i = a[ii * n ..][0..n];
            elimRow(row_i, row_k, factor, k + 1, n);
        }
    }
}

/// Writes x = A^-T b from `factorize` output: A^T = U^T L^T P, so forward
/// through U^T, back through L^T, then undo the swaps. `b` and `x` may
/// alias. Asserts that `lu` holds n² values and `piv`, `b`, `x` n each.
/// O(n²).
pub fn solveFactoredT(n: usize, lu: []const f64, piv: []const u32, b: []const f64, x: []f64) void {
    std.debug.assert(lu.len >= n * n);
    std.debug.assert(piv.len >= n);
    if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

    for (0..n) |i| {
        x[i] = subtractColumnDot(n, lu, x, i, 0, i) / lu[i * n + i];
    }

    var i = n;
    while (i > 0) {
        i -= 1;
        x[i] = subtractColumnDot(n, lu, x, i, i + 1, n);
    }

    var k = n;
    while (k > 0) {
        k -= 1;
        if (piv[k] != k) std.mem.swap(f64, &x[k], &x[piv[k]]);
    }
}

/// Writes the stacked-real admittance [G, -ωC; ωC, G] of G + jωC into `a`
/// (row-major, stride nn = 2n) from n x n row-major G and C. Asserts that
/// nn = 2n and that `a` holds nn² values.
pub fn buildComplexAdmittance(
    n: usize,
    nn: usize,
    g_dense: []const f64,
    c_mat: []const f64,
    omega: f64,
    a: []f64,
) void {
    std.debug.assert(nn == 2 * n);
    std.debug.assert(a.len >= nn * nn);
    for (0..n) |row| {
        const g_row = g_dense[row * n ..][0..n];
        const a_tl = a[row * nn ..][0..nn];
        const a_bl = a[(n + row) * nn ..][0..nn];
        @memcpy(a_tl[0..n], g_row);
        @memcpy(a_bl[n..], g_row);
        for (c_mat[row * n ..][0..n], a_tl[n..], a_bl[0..n]) |c, *tr, *bl| {
            tr.* = -omega * c;
            bl.* = omega * c;
        }
    }
}

/// x[i] - sum over j in [start, end) of lu[j*n + i] * x[j], in index
/// order.
inline fn subtractColumnDot(n: usize, lu: []const f64, x: []const f64, i: usize, start: usize, end: usize) f64 {
    // ponytail: a strided scalar walk; it beats a W-lane gather up to
    // n = 32 and loses about 25% from n = 64. Keep a transposed factor copy
    // if large noise systems show up in a profile.
    var sum = x[i];
    for (start..end) |j| sum -= lu[j * n + i] * x[j];
    return sum;
}

/// Pivot columns per panel.
const block = 8;
/// Below this order the unblocked loops win: panel bookkeeping costs
/// more than the row traffic it saves (Ir crossover between 32 and 48).
const blocked_min = 5 * block;

const Mode = enum { factor, solve };

/// Blocked right-looking elimination. A panel of `block` columns is
/// factored as in the unblocked loops, then each trailing row takes
/// all the panel's updates in one pass while the panel's U rows stay
/// in L1. Every entry still gets `a -= l * u` in increasing k with the
/// same multipliers, so results are bitwise the unblocked loops'.
/// `.factor` records swaps in `piv`; `.solve` carries `x` instead.
fn eliminateBlocked(n: usize, a: []f64, piv: []u32, x: []f64, comptime mode: Mode) Error!void {
    var k0: usize = 0;
    while (k0 < n) : (k0 += block) {
        const kb = @min(k0 + block, n);
        for (k0..kb) |k| if (!panelStep(n, a, piv, x, k, kb, mode)) return error.Singular;
        if (kb == n) break;
        // The panel's own U rows, trailing columns: row k takes the
        // updates of rows k0..k-1, which are final by then.
        for (k0 + 1..kb) |k| {
            const row = a[k * n ..][0..n];
            for (k0..k) |kk| elimRow(row, a[kk * n ..][0..n], row[kk], kb, n);
        }
        for (kb..n) |i| panelUpdate(a[i * n ..][0..n], a, n, k0, kb);
    }
}

/// Pivot step k of `eliminateBlocked`: the unblocked body with the
/// row update stopped at the panel edge `kb`. Always stores the
/// multiplier, which `panelUpdate` reads. False on a singular pivot.
inline fn panelStep(n: usize, a: []f64, piv: []u32, x: []f64, k: usize, kb: usize, comptime mode: Mode) bool {
    const max_row = pivotRow(n, a, k);
    if (mode == .factor) piv[k] = @intCast(max_row);
    if (@abs(a[max_row * n + k]) < singular_tol) return false;
    if (max_row != k) {
        swapRows(a, n, k, max_row);
        if (mode == .solve) std.mem.swap(f64, &x[k], &x[max_row]);
    }
    const inv_pivot = @as(f64, 1.0) / a[k * n + k];
    const row_k = a[k * n ..][0..n];
    for (k + 1..n) |ii| {
        const factor = a[ii * n + k] * inv_pivot;
        a[ii * n + k] = factor;
        elimRow(a[ii * n ..][0..n], row_k, factor, k + 1, kb);
        if (mode == .solve) x[ii] -= factor * x[k];
    }
    return true;
}

/// row[kb..n] -= row[kk] * a[kk, kb..n] for kk in [k0, kb), term by
/// term in increasing kk, which rounds like `kb - k0` separate
/// `elimRow` calls. Four independent vector chains hide the
/// subtract latency and keep the row in registers across the panel: the
/// plain form, one `elimRow` per kk, measured 30% slower from n = 40
/// (the vectorizer does not vectorize the outer j loop).
inline fn panelUpdate(row: []f64, a: []const f64, n: usize, k0: usize, kb: usize) void {
    var j = kb;
    while (j + 4 * W <= n) : (j += 4 * W) {
        var v0: V = row[j..][0..W].*;
        var v1: V = row[j + W ..][0..W].*;
        var v2: V = row[j + 2 * W ..][0..W].*;
        var v3: V = row[j + 3 * W ..][0..W].*;
        for (k0..kb) |kk| {
            const l: V = @splat(row[kk]);
            const u = a[kk * n + j ..];
            v0 = v0 - l * @as(V, u[0..W].*);
            v1 = v1 - l * @as(V, u[W..][0..W].*);
            v2 = v2 - l * @as(V, u[2 * W ..][0..W].*);
            v3 = v3 - l * @as(V, u[3 * W ..][0..W].*);
        }
        row[j..][0..W].* = v0;
        row[j + W ..][0..W].* = v1;
        row[j + 2 * W ..][0..W].* = v2;
        row[j + 3 * W ..][0..W].* = v3;
    }
    while (j + W <= n) : (j += W) {
        var v: V = row[j..][0..W].*;
        for (k0..kb) |kk| v = v - @as(V, @splat(row[kk])) * @as(V, a[kk * n + j ..][0..W].*);
        row[j..][0..W].* = v;
    }
    while (j < n) : (j += 1) {
        var v = row[j];
        for (k0..kb) |kk| v -= row[kk] * a[kk * n + j];
        row[j] = v;
    }
}

/// First row i in [k, n) maximizing |a[i*n + k]|.
fn pivotRow(n: usize, a: []const f64, k: usize) usize {
    var max_val: f64 = @abs(a[k * n + k]);
    var max_row: usize = k;
    for (k + 1..n) |i| {
        const v = @abs(a[i * n + k]);
        if (v > max_val) {
            max_val = v;
            max_row = i;
        }
    }
    return max_row;
}

/// U x = y in place, each row's sum in index order.
fn backSubstitute(n: usize, a: []const f64, x: []f64) void {
    var ki: usize = n;
    while (ki > 0) {
        ki -= 1;
        const row = a[ki * n ..][0..n];
        var sum = x[ki];
        for (row[ki + 1 ..], x[ki + 1 .. n]) |av, xv| sum -= av * xv;
        x[ki] = sum / row[ki];
    }
}

/// row_i[start..n] -= factor * row_k[start..n].
inline fn elimRow(row_i: []f64, row_k: []const f64, factor: f64, start: usize, n: usize) void {
    for (row_i[start..n], row_k[start..n]) |*a, b| a.* -= factor * b;
}

/// Swaps rows r1 and r2 of the n-wide matrix `a`. Explicit vectors: the
/// 0.18 vectorizer leaves the plain two-way swap scalar (1.3 against 0.8
/// cycles/element at n = 16..1024, x86_64_v3).
fn swapRows(a: []f64, n: usize, r1: usize, r2: usize) void {
    var j: usize = 0;
    while (j + W <= n) : (j += W) {
        const p1: *[W]f64 = a[r1 * n + j ..][0..W];
        const p2: *[W]f64 = a[r2 * n + j ..][0..W];
        const tmp = p1.*;
        p1.* = p2.*;
        p2.* = tmp;
    }
    while (j < n) : (j += 1) std.mem.swap(f64, &a[r1 * n + j], &a[r2 * n + j]);
}

// ---------------------------------------------------------------------------
// Tests. Oracles: hand-solved systems, LAPACK's scaled residual ratio
// (LAWN 41 §7.1: ‖Ax - b‖ / (n·‖A‖·‖x‖·eps) <= 30, independent of how the
// solve got there), and a naive triple-loop LU that performs the same
// roundings in the same order, which the blocked path claims to match bit
// for bit. Sizes sweep 1..64: every vector tail, and both sides of
// `blocked_min`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const n_max = 64;

/// Fills `a` (n x n) and `b` with uniform values in [-1, 1).
fn randomSystem(rnd: std.Random, n: usize, a: []f64, b: []f64) void {
    for (a[0 .. n * n]) |*e| e.* = 2 * rnd.float(f64) - 1;
    for (b[0..n]) |*e| e.* = 2 * rnd.float(f64) - 1;
}

/// ‖op(A)·x - s·b‖∞ / (n·‖op(A)‖∞·‖x‖∞·eps), op = A or A^T, s = ±1.
fn residualRatio(n: usize, a: []const f64, x: []const f64, b: []const f64, transpose: bool, s: f64) f64 {
    var r_max: f64 = 0;
    var a_norm: f64 = 0;
    var x_norm: f64 = 0;
    for (0..n) |i| {
        var r = -s * b[i];
        var row_sum: f64 = 0;
        for (0..n) |j| {
            const e = if (transpose) a[j * n + i] else a[i * n + j];
            r += e * x[j];
            row_sum += @abs(e);
        }
        r_max = @max(r_max, @abs(r));
        a_norm = @max(a_norm, row_sum);
        x_norm = @max(x_norm, @abs(x[i]));
    }
    return r_max / (@as(f64, @floatFromInt(n)) * a_norm * x_norm * std.math.floatEps(f64));
}

/// The textbook LU with the unblocked loops' pivot rule and roundings:
/// first maximal |a[i][k]|, multiplier a[i][k] * (1 / pivot), then
/// a[i][j] - f * a[k][j] for j > k in increasing k. No singular check.
fn naiveFactor(n: usize, a: []f64, piv: []u32) void {
    for (0..n) |k| {
        var p = k;
        for (k + 1..n) |i| {
            if (@abs(a[i * n + k]) > @abs(a[p * n + k])) p = i;
        }
        piv[k] = @intCast(p);
        if (p != k) for (0..n) |j| std.mem.swap(f64, &a[k * n + j], &a[p * n + j]);
        const inv = @as(f64, 1.0) / a[k * n + k];
        for (k + 1..n) |i| {
            const f = a[i * n + k] * inv;
            a[i * n + k] = f;
            for (k + 1..n) |j| a[i * n + j] = a[i * n + j] - f * a[k * n + j];
        }
    }
}

test factorizeSolveNeg {
    // A·(1, -2, 3) = (-1, 2, 0) by hand; A[0][0] = 0 forces a row swap.
    var a = [_]f64{ 0, 2, 1, 1, 1, 1, 2, 1, 0 };
    var x: [3]f64 = undefined;
    try factorizeSolveNeg(3, &a, &.{ -1, 2, 0 }, &x);
    for ([_]f64{ -1, 2, -3 }, x) |want, got| try testing.expectApproxEqAbs(want, got, 1e-15);
}

test "factorizeSolveNeg and factorize refuse a singular matrix, and n = 0 is a no-op" {
    // Row 2 = 2 · row 1: after one elimination step the second pivot is
    // exactly 0, below eps^2.
    var a = [_]f64{ 1, 2, 2, 4 };
    var x: [2]f64 = undefined;
    try testing.expectError(error.Singular, factorizeSolveNeg(2, &a, &.{ 1, 1 }, &x));
    var lu = [_]f64{ 1, 2, 2, 4 };
    var piv: [2]u32 = undefined;
    try testing.expectError(error.Singular, factorize(2, &lu, &piv));
    // A zero column is singular at its first step.
    var z = [_]f64{ 0, 1, 0, 1 };
    try testing.expectError(error.Singular, factorize(2, &z, &piv));
    try factorizeSolveNeg(0, &.{}, &.{}, &.{});
    try factorize(0, &.{}, &.{});
}

test "a NaN right-hand side is no singular matrix: it reaches x" {
    // The Newton gates, not the factor, refuse a NaN step.
    var a = [_]f64{ 2, 1, 1, 3 };
    var x: [2]f64 = undefined;
    try factorizeSolveNeg(2, &a, &.{ std.math.nan(f64), 1 }, &x);
    try testing.expect(std.math.isNan(x[0]));
    try testing.expect(std.math.isNan(x[1]));
}

test "factorizeSolveNeg's residual is backward-stable at every size, blocked or not" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rnd = prng.random();
    var a: [n_max * n_max]f64 = undefined;
    var work: [n_max * n_max]f64 = undefined;
    var b: [n_max]f64 = undefined;
    var x: [n_max]f64 = undefined;
    for (1..n_max + 1) |n| {
        randomSystem(rnd, n, &a, &b);
        @memcpy(work[0 .. n * n], a[0 .. n * n]);
        try factorizeSolveNeg(n, work[0 .. n * n], b[0..n], x[0..n]);
        // x = -A^-1 b, so A·x + b ≈ 0.
        try testing.expect(residualRatio(n, &a, &x, &b, false, -1) <= 30);
    }
}

test "factorize matches the naive LU bit for bit, across blocked_min" {
    var prng: std.Random.DefaultPrng = .init(41);
    const rnd = prng.random();
    var a: [n_max * n_max]f64 = undefined;
    var ref: [n_max * n_max]f64 = undefined;
    var b: [n_max]f64 = undefined;
    var piv: [n_max]u32 = undefined;
    var ref_piv: [n_max]u32 = undefined;
    for ([_]usize{ 1, 2, 3, 5, 8, 9, 17, 39, 40, 41, 47, 48, 49, 64 }) |n| {
        randomSystem(rnd, n, &a, &b);
        @memcpy(ref[0 .. n * n], a[0 .. n * n]);
        try factorize(n, a[0 .. n * n], piv[0..n]);
        naiveFactor(n, ref[0 .. n * n], ref_piv[0..n]);
        try testing.expectEqualSlices(u32, ref_piv[0..n], piv[0..n]);
        for (ref[0 .. n * n], a[0 .. n * n]) |want, got| {
            try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
        }
    }
}

test solveFactoredT {
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    var a: [n_max * n_max]f64 = undefined;
    var lu: [n_max * n_max]f64 = undefined;
    var b: [n_max]f64 = undefined;
    var y: [n_max]f64 = undefined;
    var piv: [n_max]u32 = undefined;
    for (1..n_max + 1) |n| {
        randomSystem(rnd, n, &a, &b);
        @memcpy(lu[0 .. n * n], a[0 .. n * n]);
        try factorize(n, lu[0 .. n * n], piv[0..n]);
        solveFactoredT(n, lu[0 .. n * n], piv[0..n], b[0..n], y[0..n]);
        try testing.expect(residualRatio(n, &a, &y, &b, true, 1) <= 30);
        // In place: `b` and `x` may alias.
        solveFactoredT(n, lu[0 .. n * n], piv[0..n], b[0..n], b[0..n]);
        for (y[0..n], b[0..n]) |want, got| try testing.expectEqual(want, got);
    }
    // By hand: A = [[2, 1], [0, 4]], A^T y = (2, 9) gives y = (1, 2).
    var small = [_]f64{ 2, 1, 0, 4 };
    var p2: [2]u32 = undefined;
    try factorize(2, &small, &p2);
    var y2: [2]f64 = undefined;
    solveFactoredT(2, &small, &p2, &.{ 2, 9 }, &y2);
    try testing.expectApproxEqAbs(@as(f64, 1), y2[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2), y2[1], 1e-15);
}

test buildComplexAdmittance {
    // Every block entry of [G, -ωC; ωC, G], at sizes that end in a vector
    // tail and at ones that do not.
    var g: [9 * 9]f64 = undefined;
    var c: [9 * 9]f64 = undefined;
    for (&g, &c, 0..) |*ge, *ce, k| {
        ge.* = @floatFromInt(k + 1);
        ce.* = 0.5 * @as(f64, @floatFromInt(k)) - 3;
    }
    var a: [18 * 18]f64 = undefined;
    const omega = 2.5;
    for (0..10) |n| {
        const nn = 2 * n;
        buildComplexAdmittance(n, nn, g[0 .. n * n], c[0 .. n * n], omega, a[0 .. nn * nn]);
        for (0..n) |r| for (0..n) |col| {
            const gv = g[r * n + col];
            const cv = c[r * n + col];
            try testing.expectEqual(gv, a[r * nn + col]);
            try testing.expectEqual(-omega * cv, a[r * nn + n + col]);
            try testing.expectEqual(omega * cv, a[(n + r) * nn + col]);
            try testing.expectEqual(gv, a[(n + r) * nn + n + col]);
        };
    }
}
