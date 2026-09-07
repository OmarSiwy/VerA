//! The direct Newton loop and its acceptance gates, generic over the system:
//! stamp, factor, solve, accept.
//!
//! In: a system `sys` and a start `x`; out: the converged `x`, or a report
//! that it did not converge. `sys` is a pointer with fields `n`,
//! `diag_slots`, `rhs` and `current_row`, and optional pub methods
//! beginSolve, advanceIteration, checkConvergence, applyLimits and
//! updateStates. `hook` provides assemble(sys, x, t) and vals(sys) (the
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

fn Deref(comptime P: type) type {
    return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
}

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
    /// Largest scaled step of the accepted iterate; 0 when not converged.
    max_dx: f64,
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
pub fn newton(
    sys: anytype,
    ws: anytype,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) dense_lu.Error!Result {
    const S = Deref(@TypeOf(sys));
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

/// One iterate's verdict, and its scaled step for `Result.max_dx`.
const Step = struct { converged: bool, scaled: f64 };

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

    if (limited) return .{ .converged = false, .scaled = scaled };
    if (iter == 0) return .{ .converged = false, .scaled = scaled };
    if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled };
    for (0..n) |i| {
        const scale = @abs(vals[sys.diag_slots[i]]);
        // A zero diagonal is a voltage-defined branch row (V/E/H source):
        // its scale is the source gain, and an exact solution still leaves
        // O(gain * eps) residual there (a 1e9-gain E source reads 2.7e-8).
        // The delta test alone governs such rows, as in ngspice NIconvTest.
        if (scale == 0) continue;
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        // Negated, so a NaN residual fails too.
        if (!(@abs(residual[i]) <= tol)) return .{ .converged = false, .scaled = scaled };
    }
    if (comptime @hasDecl(S, "checkConvergence")) {
        if (!sys.checkConvergence(x)) return .{ .converged = false, .scaled = scaled };
    }
    // Last, at the x_k `newton` publishes. A device that flips here forces
    // one more iterate.
    if (comptime @hasDecl(S, "updateStates")) {
        if (sys.updateStates(x_old[0..n])) |_| return .{ .converged = false, .scaled = scaled };
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

// ---------------------------------------------------------------------------
// Tests. Oracles: hand-solved linear systems (Newton on a linear residual
// lands on the root after one solve, and the gates accept it on the next
// iterate), a plain scalar `updateAndNorm`, and call counts of the
// optional hooks.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "updateAndNorm scores a NaN step as infinite and a small one below 1" {
    var x = [_]f64{ 1.0, 0.0, 2.0 };
    var x_old: [3]f64 = undefined;
    const cur = [_]bool{ false, true, false };
    try testing.expect(updateAndNorm(&x, &.{ 1e-9, 1e-15, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6) < 1.0);
    try testing.expectEqual(@as(f64, 1.0), x_old[0]);
    try testing.expectEqual(inf, updateAndNorm(&x, &.{ std.math.nan(f64), 0, 0 }, &x_old, &cur, 1e-3, 1e-12, 1e-6));
}

/// The plain loop `updateAndNorm` vectorizes, as its header states it.
fn normOracle(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    var worst: f64 = 0;
    for (x, dx, x_old, current_row) |*xi, d, *xo, c| {
        const o = xi.*;
        xo.* = o;
        xi.* = o + d;
        const tol = reltol * @max(@abs(xi.*), @abs(o)) + (if (c) abstol else vntol);
        const finite = @abs(xi.*) < inf and @abs(d) < inf;
        worst = @max(worst, if (finite) @abs(d) / tol else inf);
    }
    return worst;
}

test "updateAndNorm equals its scalar loop bit for bit at every length" {
    var prng: std.Random.DefaultPrng = .init(11);
    const rnd = prng.random();
    const len_max = 40; // past 3 vectors at every width up to 8
    var x: [len_max]f64 = undefined;
    var x2: [len_max]f64 = undefined;
    var dx: [len_max]f64 = undefined;
    var xo: [len_max]f64 = undefined;
    var xo2: [len_max]f64 = undefined;
    var cur: [len_max]bool = undefined;
    for (0..len_max + 1) |len| for (0..8) |_| {
        for (x[0..len], dx[0..len], cur[0..len]) |*xi, *d, *c| {
            xi.* = 4 * rnd.float(f64) - 2;
            d.* = (rnd.float(f64) - 0.5) * std.math.pow(f64, 10, -12 * rnd.float(f64));
            c.* = rnd.boolean();
            // An occasional diverged entry: infinite x or NaN step.
            switch (rnd.uintLessThan(u8, 32)) {
                0 => xi.* = inf,
                1 => d.* = std.math.nan(f64),
                else => {},
            }
        }
        @memcpy(x2[0..len], x[0..len]);
        const got = updateAndNorm(x[0..len], dx[0..len], xo[0..len], cur[0..len], 1e-3, 1e-12, 1e-6);
        const want = normOracle(x2[0..len], dx[0..len], xo2[0..len], cur[0..len], 1e-3, 1e-12, 1e-6);
        try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
        for (x2[0..len], x[0..len], xo2[0..len], xo[0..len]) |a, b, c, d| {
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
        diag_slots: [n]u32 = blk: {
            var d: [n]u32 = undefined;
            for (&d, 0..) |*e, i| e.* = i * n + i;
            break :blk d;
        },
        rhs: [n]f64 = undefined,
        current_row: [n]bool = @splat(false),
        jac: [n * n]f64 = undefined,
        g: [n * n]f64,
        b: [n]f64,

        const Sys = @This();
        const Hook = struct {
            pub fn assemble(_: Hook, s: *Sys, x: []const f64, _: f64) void {
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
    const r = try newton(&sys, &ws, &x, 0, .{}, L.Hook{});
    try testing.expect(r.converged);
    try testing.expectEqual(2, r.iterations);
    try testing.expect(r.max_dx < 1);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), x[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), x[1], 1e-15);

    // INITFIX: the first passing iterate only re-arms, so one more runs.
    x = .{ 0, 0 };
    const fix = try newton(&sys, &ws, &x, 0, .{ .init_fix = true }, L.Hook{});
    try testing.expect(fix.converged);
    try testing.expectEqual(3, fix.iterations);

    // One iteration is never enough.
    x = .{ 0, 0 };
    const short = try newton(&sys, &ws, &x, 0, .{ .max_iter = 1 }, L.Hook{});
    try testing.expect(!short.converged);
    try testing.expectEqual(1, short.iterations);
    try testing.expectEqual(0, short.max_dx);

    // max_iter = 0 runs nothing.
    const none = try newton(&sys, &ws, &x, 0, .{ .max_iter = 0 }, L.Hook{});
    try testing.expect(!none.converged);
    try testing.expectEqual(0, none.iterations);
}

test "newton returns error.Singular, and a NaN residual never converges" {
    const L = LinearSys(2);
    var ws: Workspace(2) = .{};
    var x = [_]f64{ 0, 0 };
    var singular: L = .{ .g = .{ 1, 2, 2, 4 }, .b = .{ 1, 1 } };
    try testing.expectError(error.Singular, newton(&singular, &ws, &x, 0, .{}, L.Hook{}));

    var poisoned: L = .{ .g = .{ 2, -1, -1, 2 }, .b = .{ std.math.nan(f64), 0 } };
    x = .{ 0, 0 };
    const r = try newton(&poisoned, &ws, &x, 0, .{ .max_iter = 5 }, L.Hook{});
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
    const r = try newton(&sys, &ws, &x, 0, .{ .gmin = 1 }, L.Hook{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(f64, 0.5), x[0]);

    sys.current_row = .{true};
    x = .{0};
    _ = try newton(&sys, &ws, &x, 0, .{ .gmin = 1 }, L.Hook{});
    try testing.expectEqual(@as(f64, 1), x[0]);
}

/// x - 1 = 0 with every optional hook, each counting or vetoing.
const HookSys = struct {
    n: usize = 1,
    diag_slots: [1]u32 = .{0},
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
        pub fn assemble(_: Hook, s: *HookSys, x: []const f64, _: f64) void {
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
    const r = try newton(&plain, &ws, &x, 0, .{}, HookSys.Hook{});
    try testing.expect(r.converged);
    try testing.expectEqual(2, r.iterations);
    try testing.expectEqual(1, plain.begins);
    // One advance, before iterate 1, handing over iterate 0's point.
    try testing.expectEqual(1, plain.advances);
    try testing.expectEqual(@as(?f64, 0), plain.first_prev);

    // Each veto or state flip costs exactly one more iterate.
    var vetoed: HookSys = .{ .vetoes = 2 };
    x = .{0};
    try testing.expectEqual(4, (try newton(&vetoed, &ws, &x, 0, .{}, HookSys.Hook{})).iterations);
    var flipped: HookSys = .{ .flips = 1 };
    x = .{0};
    try testing.expectEqual(3, (try newton(&flipped, &ws, &x, 0, .{}, HookSys.Hook{})).iterations);

    // A device that limits every iterate never converges.
    var limited: HookSys = .{ .limit_always = true };
    x = .{0};
    const l = try newton(&limited, &ws, &x, 0, .{ .max_iter = 7 }, HookSys.Hook{});
    try testing.expect(!l.converged);
    try testing.expectEqual(7, l.iterations);
}
