//! The direct Newton loop and its acceptance gates, generic over the system:
//! stamp, factor, solve, accept.
//!
//! `sys` is a pointer with fields `n`, `diag_slots`, `rhs` and `current_row`,
//! and optional methods beginSolve, advanceIteration, checkConvergence,
//! applyLimits, updateStates and clearLimits. `hook` provides assemble(sys,
//! x, t) and vals(sys) (the Jacobian, row-major n x n).
//!
//! Copied from OmarSiwy/ESPice src/solver/converger.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d: `newton`, `finalizeStep`,
//! `updateAndNorm`, `Options`, `Result` and `run`'s limit clearing. Adapted:
//! the sparse `direct.Solver` is `dense_lu.factorizeSolveNeg` on a copy of
//! the matrix (the deck runner's systems are a device's handful of
//! unknowns), so `Workspace` is fixed-size and allocates nothing, and the
//! factor-reuse signature goes with it. Not taken: JFNK/GMRES, the
//! `ESPICE_SOLVER` pin and the `ZP_*` debug traces (environment reads), the
//! profiler, the GPU `deviceSolve`, `loadCheck`, `evalFollows`, `checkpoint`,
//! `force` holds and `gmin_stamps` (Sparse's preorder twins: here gmin is on
//! every voltage row's diagonal, which moves no answer, since the operating
//! point's last solve carries none).
const std = @import("std");
const dense_lu = @import("dense_lu.zig");

/// Why `finalizeStep` refused an iterate. ESPice keeps it for its traces.
const Reject = enum { converged, first_iter, delta, limited, flipped, residual, device };

fn Deref(comptime P: type) type {
    return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
}

/// Controls for one nonlinear solve. Defaults are SPICE's `.options`.
pub const Options = struct {
    max_iter: u16 = 100,
    /// Current-row absolute tolerance, amperes.
    abstol: f64 = 1e-12,
    reltol: f64 = 1e-3,
    /// Voltage-row absolute tolerance, volts.
    vntol: f64 = 1e-6,
    /// Floor of the row-scaled residual gate.
    residual_tol: f64 = 1e-9,
    /// Conductance from every voltage unknown to ground: gmin on its
    /// diagonal and gmin * x on its residual. A current row (`current_row`,
    /// a V source's branch equation) has no diagonal to take it.
    gmin: f64 = 0,
    /// The solve is a cold operating point, ngspice's MODEINITJCT/INITFIX:
    /// the first iterate that passes every gate only switches to INITFLOAT
    /// and the next must pass too, so `newton` publishes the first passing
    /// solve (niiter.c, the MODEINITFIX branch).
    init_fix: bool = false,
};

/// Outcome of a nonlinear solve.
pub const Result = struct {
    converged: bool,
    iterations: u16,
    /// Largest scaled step of the accepted iterate; 0 when not converged.
    max_dx: f64,
};

/// Per-system Newton scratch for `n` unknowns: the matrix copy the factor
/// destroys, and the step vectors.
pub fn Workspace(comptime n: usize) type {
    return struct {
        a: [n * n]f64 = undefined,
        dx: [n]f64 = undefined,
        x_old: [n]f64 = undefined,
    };
}

/// Direct Newton: assemble, factor, solve, accept. Clears device limiting
/// on exit (ESPice `run`). The only error is a singular matrix.
///
/// A converged `x` is the last linearization point x_k, not the x_k+1 of the
/// final solve, which only feeds the acceptance gates. ngspice's NIiter
/// returns before swapping CKTrhs into CKTrhsOld (niiter.c), and CKTdump and
/// every device state read CKTrhsOld. A NaN or infinite iterate never
/// converges.
pub fn newton(
    sys: anytype,
    ws: anytype,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) dense_lu.Error!Result {
    const S = Deref(@TypeOf(sys));
    defer if (comptime @hasDecl(S, "clearLimits")) sys.clearLimits();
    const n = sys.n;
    const dx = ws.dx[0..n];
    const x_old = ws.x_old[0..n];
    var iter: u16 = 0;
    var init_fix = opts.init_fix;
    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();

    while (iter < opts.max_iter) : (iter += 1) {
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);
        hook.assemble(sys, x, t);
        const v = hook.vals(sys);
        if (opts.gmin > 0) for (0..n) |i| if (!sys.current_row[i]) {
            v[sys.diag_slots[i]] += opts.gmin;
            sys.rhs[i] += opts.gmin * x[i];
        };
        @memcpy(ws.a[0 .. n * n], v[0 .. n * n]);
        try dense_lu.factorizeSolveNeg(n, ws.a[0 .. n * n], sys.rhs[0..n], dx);
        const st = finalizeStep(sys, x, dx, x_old, sys.rhs[0..n], v, iter, opts);
        if (st.converged and init_fix) {
            init_fix = false;
        } else if (st.converged) {
            @memcpy(x[0..n], x_old[0..n]);
            return .{ .converged = true, .iterations = iter + 1, .max_dx = st.scaled };
        }
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

const Step = struct { converged: bool, scaled: f64, flipped: bool = false, why: Reject = .converged };

/// Applies `dx` and runs the acceptance gates in order: device limiting,
/// first iterate, per-row delta, row-scaled residual, device convergence,
/// then state staging.
fn finalizeStep(
    sys: anytype,
    x: []f64,
    dx: []const f64,
    x_old: []f64,
    residual: []const f64,
    vals: []const f64,
    iter: u16,
    opts: Options,
) Step {
    const S = Deref(@TypeOf(sys));
    const n = sys.n;
    const scaled = updateAndNorm(x[0..n], dx[0..n], x_old[0..n], sys.current_row[0..n], opts.reltol, opts.abstol, opts.vntol);

    const limited = if (comptime @hasDecl(S, "applyLimits")) sys.applyLimits(x, x_old) else false;

    if (limited) return .{ .converged = false, .scaled = scaled, .why = .limited };
    if (iter == 0) return .{ .converged = false, .scaled = scaled, .why = .first_iter };
    if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled, .why = .delta };
    for (0..n) |i| {
        const scale = @abs(vals[sys.diag_slots[i]]);
        // A zero diagonal is a voltage-defined branch row (V/E/H source):
        // its scale is the source gain, and an exact solution still leaves
        // O(gain * eps) residual there (a 1e9-gain E source reads 2.7e-8).
        // The delta test alone governs such rows, as in ngspice NIconvTest.
        if (scale == 0) continue;
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        // Negated, so a NaN residual fails too.
        if (!(@abs(residual[i]) <= tol)) return .{ .converged = false, .scaled = scaled, .why = .residual };
    }
    if (comptime @hasDecl(S, "checkConvergence")) {
        if (!sys.checkConvergence(x)) return .{ .converged = false, .scaled = scaled, .why = .device };
    }
    // Last, at the x_k `newton` publishes. A device that flips here forces
    // one more iterate.
    if (comptime @hasDecl(S, "updateStates")) {
        if (sys.updateStates(x_old[0..n])) |_| return .{ .converged = false, .scaled = scaled, .flipped = true, .why = .flipped };
    }
    return .{ .converged = true, .scaled = scaled };
}

const inf = std.math.inf(f64);

/// x_old = x; x += dx; returns max |dx| / (reltol * max(|x|, |x_old|) + atol),
/// atol = abstol on current rows, vntol elsewhere. A row whose new x or dx
/// is NaN or infinite scores inf: `@max` lowers to maxnum, which would drop
/// a NaN and pass a diverged step. Max is exact and order-independent, so
/// the vector body and scalar tail agree bitwise with a plain scalar loop.
fn updateAndNorm(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    const V = @Vector(W, f64);
    const rel: V = @splat(reltol);
    const abs_i: V = @splat(abstol);
    const abs_v: V = @splat(vntol);
    const inf_v: V = @splat(inf);
    var worst_v: V = @splat(0);
    var i: usize = 0;
    while (i + W <= x.len) : (i += W) {
        const xo: V = x[i..][0..W].*;
        const d: V = dx[i..][0..W].*;
        const cur: @Vector(W, bool) = current_row[i..][0..W].*;
        const xn = xo + d;
        x_old[i..][0..W].* = xo;
        x[i..][0..W].* = xn;
        const tol = rel * @max(@abs(xn), @abs(xo)) + @select(f64, cur, abs_i, abs_v);
        const finite = (@abs(xn) < inf_v) & (@abs(d) < inf_v);
        worst_v = @max(worst_v, @select(f64, finite, @abs(d) / tol, inf_v));
    }
    var worst: f64 = @reduce(.Max, worst_v);
    for (x[i..], dx[i..], x_old[i..], current_row[i..x.len]) |*xi, dxi, *xoi, is_cur| {
        const xo = xi.*;
        xoi.* = xo;
        xi.* = xo + dxi;
        const atol = if (is_cur) abstol else vntol;
        const tol = reltol * @max(@abs(xi.*), @abs(xo)) + atol;
        const finite = @abs(xi.*) < inf and @abs(dxi) < inf;
        worst = @max(worst, if (finite) @abs(dxi) / tol else inf);
    }
    return worst;
}

test "updateAndNorm scores a NaN step as infinite and a small one below 1" {
    var x = [_]f64{ 1.0, 0.0, 2.0 };
    var x_old: [3]f64 = undefined;
    const cur = [_]bool{ false, true, false };
    try std.testing.expect(updateAndNorm(&x, &.{ 1e-9, 1e-15, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6) < 1.0);
    try std.testing.expectEqual(@as(f64, 1.0), x_old[0]);
    try std.testing.expectEqual(inf, updateAndNorm(&x, &.{ std.math.nan(f64), 0, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6));
}
