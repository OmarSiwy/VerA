//! The direct Newton loop and its acceptance gates, generic over the system:
//! stamp, factor, solve, accept.
//!
//! In: a system `sys` and a start `x`; out: the converged `x`, or a report
//! that it did not converge. `sys` is a pointer with fields `n`, `rhs`
//! and `current_row`, and optional pub methods
//! beginSolve, advanceIteration, checkConvergence, applyLimits and
//! updateStates. `hook` provides assemble(sys, x) and vals(sys) (the
//! Jacobian, row-major n x n).
//!
//! Copied from OmarSiwy/ESPice src/solver/converger.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d: `newton`, `finalizeStep`,
//! `updateAndNorm`, `Options` and `Result`. Adapted:
//! the sparse `direct.Solver` is `dense_lu.factorizeSolveNeg` on a copy of
//! the matrix (the deck runner's systems are a device's handful of
//! unknowns), so `Workspace` is fixed-size and allocates nothing, and the
//! factor-reuse signature goes with it. Not taken: JFNK/GMRES, the
//! `ESPICE_SOLVER` pin and the `ZP_*` debug traces (environment reads), the
//! profiler, the GPU `deviceSolve`, `loadCheck`, `evalFollows`, `checkpoint`,
//! `force` holds and `gmin_stamps` (Sparse's preorder twins: here gmin is on
//! every voltage row's diagonal, which moves no answer, since the operating
//! point's last solve carries none), `run`'s limit clearing and the
//! per-gate rejection reason (ESPice's traces; no system here clears limits
//! or reads the reason).
//!
//! LRM: §9.17.3 `$limit` (the `applyLimits` gate); the gates themselves are
//! SPICE's (ngspice niiter.c, niconv.c), not the LRM's.
const std = @import("std");
const dense_lu = @import("dense_lu.zig");

/// Controls for one nonlinear solve. Defaults are SPICE's `.options`.
pub const Options = struct {
    /// Newton iterations before the solve gives up (SPICE's itl1).
    max_iter: u16 = 100,
    /// Current-row absolute tolerance, amperes.
    abstol: f64 = 1e-12,
    /// Relative tolerance of both the delta and the residual gate.
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
    /// Iterations run, the converging one included; `max_iter` when not
    /// converged.
    iterations: u16,
};

/// Returns the per-system Newton scratch for `n` unknowns: the matrix copy
/// the factor destroys, and the step vectors. Fixed-size, so `.{}` is the
/// whole setup and nothing allocates.
pub fn Workspace(comptime n: usize) type {
    return struct {
        a: [n * n]f64 = undefined,
        dx: [n]f64 = undefined,
        x_old: [n]f64 = undefined,
    };
}

/// Runs direct Newton from `x`: assemble, factor, solve, accept. The only
/// error is a singular matrix (`error.Singular`), returned at once, with
/// `x` at the last iterate. Asserts that `x` and every `ws` array hold at
/// least `sys.n` (n²) values.
///
/// A converged `x` is the last linearization point x_k, not the x_k+1 of the
/// final solve, which only feeds the acceptance gates. ngspice's NIiter
/// returns before swapping CKTrhs into CKTrhsOld (niiter.c), and CKTdump and
/// every device state read CKTrhsOld. A NaN or infinite iterate never
/// converges.
pub fn newton(sys: anytype, ws: anytype, x: []f64, opts: Options, hook: anytype) dense_lu.Error!Result {
    const S = @TypeOf(sys.*);
    const n = sys.n;
    std.debug.assert(x.len >= n);
    std.debug.assert(ws.a.len >= n * n);
    const dx = ws.dx[0..n];
    const x_old = ws.x_old[0..n];
    var init_fix = opts.init_fix;
    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();

    for (0..opts.max_iter) |iter| {
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);
        hook.assemble(sys, x);
        const v = hook.vals(sys);
        if (opts.gmin > 0) for (0..n) |i| if (!sys.current_row[i]) {
            v[i * (n + 1)] += opts.gmin;
            sys.rhs[i] += opts.gmin * x[i];
        };
        @memcpy(ws.a[0 .. n * n], v[0 .. n * n]);
        try dense_lu.factorizeSolveNeg(n, ws.a[0 .. n * n], sys.rhs[0..n], dx);
        if (!finalizeStep(sys, x, dx, x_old, v, iter == 0, opts)) continue;
        if (init_fix) {
            init_fix = false;
            continue;
        }
        @memcpy(x[0..n], x_old);
        return .{ .converged = true, .iterations = @intCast(iter + 1) };
    }
    return .{ .converged = false, .iterations = opts.max_iter };
}

/// Applies `dx` and runs the acceptance gates in order: device limiting,
/// first iterate, per-row delta, row-scaled residual (`sys.rhs`), device
/// convergence, then state staging. True when every gate passes.
fn finalizeStep(sys: anytype, x: []f64, dx: []const f64, x_old: []f64, vals: []const f64, first: bool, opts: Options) bool {
    const S = @TypeOf(sys.*);
    const n = sys.n;
    const scaled = updateAndNorm(x[0..n], dx[0..n], x_old[0..n], sys.current_row[0..n], opts.reltol, opts.abstol, opts.vntol);

    if (comptime @hasDecl(S, "applyLimits")) if (sys.applyLimits(x, x_old)) return false;
    if (first) return false;
    // Negated, so a NaN norm (a NaN tolerance) fails too.
    if (!(scaled < 1.0)) return false;
    for (0..n) |i| {
        const scale = @abs(vals[i * (n + 1)]);
        // A zero diagonal is a voltage-defined branch row (V/E/H source):
        // its scale is the source gain, and an exact solution still leaves
        // O(gain * eps) residual there (a 1e9-gain E source reads 2.7e-8).
        // The delta test alone governs such rows, as in ngspice NIconvTest.
        if (scale == 0) continue;
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        // Negated, so a NaN residual fails too.
        if (!(@abs(sys.rhs[i]) <= tol)) return false;
    }
    if (comptime @hasDecl(S, "checkConvergence")) if (!sys.checkConvergence(x)) return false;
    // Last, at the x_k `newton` publishes. A device that flips here forces
    // one more iterate.
    if (comptime @hasDecl(S, "updateStates")) if (sys.updateStates(x_old[0..n]) != null) return false;
    return true;
}

const inf = std.math.inf(f64);

/// x_old = x; x += dx; returns max |dx| / (reltol * max(|x|, |x_old|) + atol),
/// atol = abstol on current rows, vntol elsewhere. A row whose new x or dx
/// is NaN or infinite scores inf, and a zero step scores 0 whatever its
/// tolerance (ngspice's |dx| <= tol holds), so zero tolerances give no 0/0.
/// Asserts that every slice is as long as `x`.
fn updateAndNorm(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    std.debug.assert(dx.len == x.len);
    std.debug.assert(x_old.len == x.len);
    std.debug.assert(current_row.len == x.len);
    var worst: i64 = 0;
    for (x, dx, x_old, current_row) |*xi, d, *xo, c| {
        const o = xi.*;
        xo.* = o;
        const xn = o + d;
        xi.* = xn;
        const atol = if (c) abstol else vntol;
        const tol = reltol * @max(@abs(xn), @abs(o)) + atol;
        const finite = @abs(xn) < inf and @abs(d) < inf;
        const r = if (!finite) inf else if (d == 0) 0 else @abs(d) / tol;
        // The max runs over the bit patterns, sign cleared: they order like
        // the non-negative ratios with NaN above inf, so the max is exact,
        // order-independent and vectorizes, and a NaN (from a NaN tolerance)
        // propagates where a float `@max` (maxnum) would drop it. The sign is
        // cleared because x86's default NaN is negative.
        worst = @max(worst, @as(i64, @bitCast(@as(u64, @bitCast(r)) & 0x7fff_ffff_ffff_ffff)));
    }
    return @bitCast(worst);
}

// ---------------------------------------------------------------------------
// Tests. Oracles: hand-solved linear systems (Newton on a linear residual
// lands on the root after one solve, and the gates accept it on the next
// iterate), a plain scalar `updateAndNorm`, and call counts of the
// optional hooks.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ams_voltage_update_convergence_criterion" {
    // Exercise the actual acceptance gate. Residuals are zero so only the
    // voltage update criterion can reject these exact binary-sized steps.
    var sys = struct {
        n: usize = 1,
        rhs: [1]f64 = .{0},
        current_row: [1]bool = .{false},
    }{};
    for ([_]f64{ 0.0625, -0.0625, 0.125, -0.125, 0.25, -0.25 }) |step| {
        var x = [_]f64{1};
        var old: [1]f64 = undefined;
        const accepted = finalizeStep(&sys, &x, &.{step}, &old, &.{1}, false, .{ .reltol = 0, .vntol = 0.125 });
        try testing.expectEqual(@abs(step) < 0.125, accepted);
        try testing.expectEqual(@as(f64, 1), old[0]);
        try testing.expectEqual(1 + step, x[0]);
    }
    // A decreasing update must use the old magnitude; an increasing update
    // must use the new magnitude. Adding abstol is independently observable.
    var decreasing = [_]f64{1};
    var increasing = [_]f64{1};
    var old: [1]f64 = undefined;
    try testing.expectApproxEqAbs(@as(f64, 8.0 / 9.0), updateAndNorm(&decreasing, &.{-0.125}, &old, &.{false}, 0.125, 0, 0.015625), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.8), updateAndNorm(&increasing, &.{0.125}, &old, &.{false}, 0.125, 0, 0.015625), 1e-15);
}

test "updateAndNorm scores a NaN step as infinite, a small one below 1, a zero one 0, and a NaN tolerance NaN" {
    var x = [_]f64{ 1.0, 0.0, 2.0 };
    var x_old: [3]f64 = undefined;
    const cur = [_]bool{ false, true, false };
    try testing.expect(updateAndNorm(&x, &.{ 1e-9, 1e-15, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6) < 1.0);
    try testing.expectEqual(@as(f64, 1.0), x_old[0]);
    try testing.expectEqual(inf, updateAndNorm(&x, &.{ std.math.nan(f64), 0, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6));
    try testing.expectEqual(inf, updateAndNorm(&x, &.{ 0, -inf, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6));
    // Zero tolerances: a zero step at x = 0 passes (no 0/0), any other
    // step is infinitely large.
    var z = [_]f64{0};
    try testing.expectEqual(0, updateAndNorm(&z, &.{0}, x_old[0..1], &.{true}, 0, 0, 0));
    try testing.expectEqual(inf, updateAndNorm(&z, &.{1e-300}, x_old[0..1], &.{true}, 0, 0, 0));
    // A NaN tolerance propagates, and `finalizeStep`'s `!(scaled < 1)`
    // refuses it.
    var y = [_]f64{1.0};
    try testing.expect(std.math.isNan(updateAndNorm(&y, &.{1e-9}, x_old[0..1], &.{false}, std.math.nan(f64), 1e-12, 1e-6)));
    try testing.expectEqual(0, updateAndNorm(x[0..0], &.{}, x_old[0..0], &.{}, 1e-3, 1e-12, 1e-6));
}

/// The strict scalar loop `updateAndNorm` must equal: float compares, with
/// the first NaN ratio (sign cleared) winning over every other.
fn normOracle(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    var worst: f64 = 0;
    for (x, dx, x_old, current_row) |*xi, d, *xo, c| {
        const o = xi.*;
        xo.* = o;
        xi.* = o + d;
        const tol = reltol * @max(@abs(xi.*), @abs(o)) + (if (c) abstol else vntol);
        const finite = @abs(xi.*) < inf and @abs(d) < inf;
        const r = if (!finite) inf else if (d == 0) 0 else @abs(d) / tol;
        if (!std.math.isNan(worst) and !(r <= worst)) worst = @abs(r);
    }
    return worst;
}

test "updateAndNorm equals its strict scalar loop bit for bit: lengths 0..200, every start, NaN/Inf" {
    var prng: std.Random.DefaultPrng = .init(11);
    const rnd = prng.random();
    const len_max = 200;
    const pad = 3; // misaligned starts
    var x: [len_max + pad]f64 = undefined;
    var x2: [len_max + pad]f64 = undefined;
    var dx: [len_max + pad]f64 = undefined;
    var xo: [len_max + pad]f64 = undefined;
    var xo2: [len_max + pad]f64 = undefined;
    var cur: [len_max + pad]bool = undefined;
    for (0..len_max + 1) |len| for (0..pad + 1) |off| {
        const e = off + len;
        for (x[off..e], dx[off..e], cur[off..e]) |*xi, *d, *c| {
            xi.* = 4 * rnd.float(f64) - 2;
            d.* = (rnd.float(f64) - 0.5) * std.math.pow(f64, 10, -12 * rnd.float(f64));
            c.* = rnd.boolean();
            // An occasional diverged entry: infinite x or step, NaN step.
            switch (rnd.uintLessThan(u8, 64)) {
                0 => xi.* = inf,
                1 => d.* = std.math.nan(f64),
                2 => d.* = -inf,
                3 => {
                    xi.* = 0;
                    d.* = 0;
                },
                else => {},
            }
        }
        @memcpy(x2[off..e], x[off..e]);
        // Zero tolerances on one run in eight, where zero steps must score 0.
        const tol: f64 = if (len % 8 == 0) 0 else 1e-6;
        const got = updateAndNorm(x[off..e], dx[off..e], xo[off..e], cur[off..e], 1e-3, tol * 1e-6, tol);
        const want = normOracle(x2[off..e], dx[off..e], xo2[off..e], cur[off..e], 1e-3, tol * 1e-6, tol);
        try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
        for (x2[off..e], x[off..e], xo2[off..e], xo[off..e]) |a, b, c, d| {
            try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
            try testing.expectEqual(@as(u64, @bitCast(c)), @as(u64, @bitCast(d)));
        }
    };
}

/// A linear system G·x = b with no optional hooks: `assemble` rewrites the
/// matrix each time, as a device's eval does, since gmin adds to it.
fn LinearSys(comptime n: usize) type {
    return struct {
        n: usize = n,
        rhs: [n]f64 = undefined,
        current_row: [n]bool = @splat(false),
        jac: [n * n]f64 = undefined,
        g: [n * n]f64,
        b: [n]f64,

        const Sys = @This();
        const Hook = struct {
            pub fn assemble(_: Hook, s: *Sys, x: []const f64) void {
                s.jac = s.g;
                for (0..n) |i| {
                    var r = -s.b[i];
                    for (0..n) |j| r += s.g[i * n + j] * x[j];
                    s.rhs[i] = r;
                }
            }
            pub fn vals(_: Hook, s: *Sys) []f64 {
                return &s.jac;
            }
        };
    };
}

test newton {
    // G = [[2, -1], [-1, 2]], b = (1, 0): x = (2/3, 1/3). The first solve
    // lands on the root; iterate 0 is never accepted, so iterate 1 is.
    const L = LinearSys(2);
    var sys: L = .{ .g = .{ 2, -1, -1, 2 }, .b = .{ 1, 0 } };
    var ws: Workspace(2) = .{};
    var x = [_]f64{ 0, 0 };
    const r = try newton(&sys, &ws, &x, .{}, L.Hook{});
    try testing.expect(r.converged);
    try testing.expectEqual(2, r.iterations);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), x[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), x[1], 1e-15);

    // INITFIX: the first passing iterate only re-arms, so one more runs.
    x = .{ 0, 0 };
    const fix = try newton(&sys, &ws, &x, .{ .init_fix = true }, L.Hook{});
    try testing.expect(fix.converged);
    try testing.expectEqual(3, fix.iterations);

    // One iteration is never enough.
    x = .{ 0, 0 };
    const short = try newton(&sys, &ws, &x, .{ .max_iter = 1 }, L.Hook{});
    try testing.expect(!short.converged);
    try testing.expectEqual(1, short.iterations);

    // max_iter = 0 runs nothing.
    const none = try newton(&sys, &ws, &x, .{ .max_iter = 0 }, L.Hook{});
    try testing.expect(!none.converged);
    try testing.expectEqual(0, none.iterations);
}

test "newton returns error.Singular, and a NaN residual never converges" {
    const L = LinearSys(2);
    var ws: Workspace(2) = .{};
    var x = [_]f64{ 0, 0 };
    var singular: L = .{ .g = .{ 1, 2, 2, 4 }, .b = .{ 1, 1 } };
    try testing.expectError(error.Singular, newton(&singular, &ws, &x, .{}, L.Hook{}));

    var poisoned: L = .{ .g = .{ 2, -1, -1, 2 }, .b = .{ std.math.nan(f64), 0 } };
    x = .{ 0, 0 };
    const r = try newton(&poisoned, &ws, &x, .{ .max_iter = 5 }, L.Hook{});
    try testing.expect(!r.converged);
    try testing.expectEqual(5, r.iterations);
}

test "Options.gmin shunts voltage rows only" {
    // x - 1 = 0 with gmin = 1 on the diagonal and gmin·x on the residual:
    // 2x - 1 = 0, x = 0.5 exactly. A current row takes no gmin: x = 1.
    const L = LinearSys(1);
    var ws: Workspace(1) = .{};
    var sys: L = .{ .g = .{1}, .b = .{1} };
    var x = [_]f64{0};
    const r = try newton(&sys, &ws, &x, .{ .gmin = 1 }, L.Hook{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(f64, 0.5), x[0]);

    sys.current_row = .{true};
    x = .{0};
    _ = try newton(&sys, &ws, &x, .{ .gmin = 1 }, L.Hook{});
    try testing.expectEqual(@as(f64, 1), x[0]);
}

/// x - 1 = 0 with every optional hook, each counting or vetoing.
const HookSys = struct {
    n: usize = 1,
    rhs: [1]f64 = undefined,
    current_row: [1]bool = .{false},
    jac: [1]f64 = undefined,
    begins: u32 = 0,
    advances: u32 = 0,
    first_prev: ?f64 = null,
    vetoes: u32 = 0,
    flips: u32 = 0,
    limit_always: bool = false,

    pub fn beginSolve(s: *HookSys) void {
        s.begins += 1;
    }
    pub fn advanceIteration(s: *HookSys, prev: []const f64) void {
        s.advances += 1;
        if (s.first_prev == null) s.first_prev = prev[0];
    }
    pub fn checkConvergence(s: *HookSys, _: []const f64) bool {
        if (s.vetoes == 0) return true;
        s.vetoes -= 1;
        return false;
    }
    pub fn applyLimits(s: *HookSys, _: []f64, _: []const f64) bool {
        return s.limit_always;
    }
    pub fn updateStates(s: *HookSys, _: []const f64) ?f64 {
        if (s.flips == 0) return null;
        s.flips -= 1;
        return 1.0;
    }

    const Hook = struct {
        pub fn assemble(_: Hook, s: *HookSys, x: []const f64) void {
            s.jac = .{1};
            s.rhs = .{x[0] - 1};
        }
        pub fn vals(_: Hook, s: *HookSys) []f64 {
            return &s.jac;
        }
    };
};

test "newton's optional hooks: counted, vetoing, flipping, limiting" {
    var ws: Workspace(1) = .{};
    var x = [_]f64{0};

    var plain: HookSys = .{};
    const r = try newton(&plain, &ws, &x, .{}, HookSys.Hook{});
    try testing.expect(r.converged);
    try testing.expectEqual(2, r.iterations);
    try testing.expectEqual(1, plain.begins);
    // One advance, before iterate 1, handing over iterate 0's point.
    try testing.expectEqual(1, plain.advances);
    try testing.expectEqual(@as(?f64, 0), plain.first_prev);

    // Each veto or state flip costs exactly one more iterate.
    var vetoed: HookSys = .{ .vetoes = 2 };
    x = .{0};
    try testing.expectEqual(4, (try newton(&vetoed, &ws, &x, .{}, HookSys.Hook{})).iterations);
    var flipped: HookSys = .{ .flips = 1 };
    x = .{0};
    try testing.expectEqual(3, (try newton(&flipped, &ws, &x, .{}, HookSys.Hook{})).iterations);

    // A device that limits every iterate never converges.
    var limited: HookSys = .{ .limit_always = true };
    x = .{0};
    const l = try newton(&limited, &ws, &x, .{ .max_iter = 7 }, HookSys.Hook{});
    try testing.expect(!l.converged);
    try testing.expectEqual(7, l.iterations);
}
