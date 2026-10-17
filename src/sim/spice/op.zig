//! Operating point: ESPice's Newton ladder from the SPICE cold start. Plain
//! Newton, then dynamic gmin stepping, then source stepping, each rung run
//! only when the one before it did not converge.
//!
//! Copied from OmarSiwy/ESPice src/analysis/dc/op.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d: `solve`, `coldStart` and rungs
//! 1-3 of `solveLadder` (ngspice cktop.c's `dynamic_gmin` for rung 2), with
//! `newtonRun`'s budgets: itl1 iterations for a full solve, itl2 for one
//! stepping solve, INITFIX on a solve from the cold start. Adapted: one
//! device (`circuit.Circuit`), no `.ic` holds, and a §3.6.3.2 nodeset
//! (`u_nodeset`) is part of the cold start, never a clamp (VD-117). Rung
//! 2's gmin sits
//! on every voltage row's diagonal (`converger.Options.gmin`) rather than on
//! `gminStamps`' Sparse preorder twins; the solve that ends the rung carries
//! no gmin, so the placement moves no answer. Rung 3 scales the sources
//! through §9.15's `sourceScaleFactor` (`Model.source_scale__`, which every
//! Annex E independent source multiplies its value by) where ESPice calls a
//! native device's `attempt`; a device without the field skips the rung.
//! Both rungs publish their value to `$simparam("gmin")` and
//! `$simparam("sourceScaleFactor")` (`Circuit.setHomotopy`), as ESPice's
//! later ladder does, and restore the deck's before the solve that ends the
//! rung. Not taken: JFNK, OPtran and the floating-node check; a deck no rung
//! solves fails with `error.NoOperatingPoint`.
//!
//! In: a `Circuit` and its kind of static analysis; out: the operating point
//! in `x`, committed. LRM: §4.6.1 (the analysis kind), §5.10.2
//! (`initial_step`), §9.15 (the homotopy knobs), §9.17.3 (cold-start seeds),
//! §3.6.3.2 (nodesets).
const std = @import("std");
const contract = @import("contract");
const converger = @import("converger.zig");

/// The rung that solved the operating point.
pub const Rung = enum { plain, gmin, source };

/// SPICE's itl1 and itl2: the Newton budget of a full solve and of one
/// stepping solve (ngspice cktop.c).
const itl1: u16 = 100;
const itl2: u16 = 50;
/// SPICE's `.options gmin`, where gmin stepping ends.
const gmin_target: f64 = 1e-12;
/// The gmin rung starts at this over its factor (dynamic_gmin's OldGmin).
const gmin_start: f64 = 1e-2;

/// Zeroes `x`, applies the device's §9.17.3 cold-start seeds (SPICE
/// MODEINITJCT) so the first iteration linearizes there instead of at 0,
/// then its §3.6.3.2 nodesets (`u_nodeset`), which win where both name an
/// unknown: a nodeset is the user's guess, a seed the model's default, and
/// ngspice holds nodeset nodes over INITJCT's junction values. A nodeset is
/// only where Newton starts, as in the testbench host
/// (`lib/exe/tb/runner.zig` `pointUnknowns`); no rung clamps it
/// (VD-117). Asserts that `x` holds exactly n_u values.
fn coldStart(ckt: anytype, x: []f64) void {
    @memset(x, 0);
    const D = @TypeOf(ckt.*).Device;
    const C = @TypeOf(ckt.*);
    if (@hasDecl(D, "seed")) for (D.seed(C.Val, ckt.model, ckt.inst, ckt.sim), x) |s, *xi| if (s) |v| {
        xi.* = v;
    };
    // ponytail: mirrors the testbench's loop instead of sharing it: that one
    // is Zig text emitted into each testbench, and src/sim cannot import
    // lib/exe; a shared contract helper would be new ABI surface.
    if (@hasDecl(D, "u_nodeset")) for (D.u_nodeset, x) |ns, *xi| if (ns) |v| {
        xi.* = v;
    };
}

/// The `converger.newton` hook of a static solve: `assemble` is one eval,
/// the matrix G itself.
const EvalHook = struct {
    /// Stamps every plane of `ckt` at `x`.
    pub fn assemble(_: EvalHook, ckt: anytype, x: []const f64, t: f64) void {
        ckt.eval(x, t);
    }
    /// Returns `ckt`'s G plane, which the solve may modify (gmin).
    pub fn vals(_: EvalHook, ckt: anytype) []f64 {
        return &ckt.g_vals;
    }
};

/// Solves the operating point into `x` from a cold start, as a static
/// analysis of `kind` (`.dc`, `.static` for one that precedes a
/// small-signal analysis, or `.ic` for a transient's own: §4.6.1), and on
/// convergence commits the device state and returns the rung that solved
/// it. `initial_step` holds for this solve only (§5.10.2), so every later
/// eval at this point does not re-latch. `error.NoOperatingPoint` when no
/// rung converges; the deck's knobs are restored either way.
pub fn solve(ckt: anytype, ws: anytype, x: []f64, kind: contract.AnalysisKind) !Rung {
    ckt.setSimState(.{ .kind = kind, .initial_step = true });
    const rung = try ladder(ckt, ws, x);
    ckt.say(x);
    _ = ckt.stateCtl(.commit);
    ckt.setSimState(.{ .kind = kind, .analog_initial = false });
    return rung;
}

/// One Newton solve at the device's current knobs; a singular matrix is a
/// solve that did not converge.
fn newtonRun(ckt: anytype, ws: anytype, x: []f64, gmin: f64, max_iter: u16, init_fix: bool) converger.Result {
    const opts: converger.Options = .{ .max_iter = max_iter, .gmin = gmin, .init_fix = init_fix };
    return converger.newton(ckt, ws, x, 0, opts, EvalHook{}) catch
        converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };
}

/// The three rungs, leaving the solution in `x`.
fn ladder(ckt: anytype, ws: anytype, x: []f64) error{NoOperatingPoint}!Rung {
    const C = @TypeOf(ckt.*);
    const M = C.Device.Model;

    // Rung 1: plain Newton, no diagonal gmin (junction gmin is the device's).
    coldStart(ckt, x);
    if (newtonRun(ckt, ws, x, 0, itl1, true).converged) return .plain;

    // The knobs as the deck left them, which every rung's last solve uses.
    const deck_gmin: f64 = if (@hasField(M, "gmin__")) ckt.model.gmin__ else gmin_target;
    const deck_scale: f64 = if (@hasField(M, "source_scale__")) ckt.model.source_scale__ else 1.0;
    // The last converged solution, where both stepping rungs restart.
    var x_good: [C.unknowns]f64 = undefined;

    // Rung 2: dynamic gmin stepping. Descend gmin by `factor`; on a failed
    // step, back up toward the last good gmin by the factor's 4th root and
    // retry from the last converged x; give up once the factor is ~1. An
    // easy step (a quarter of itl2) speeds up, capped at the start factor; a
    // hard one (over three quarters) slows down (cktop.c:207-222).
    {
        coldStart(ckt, x);
        var factor: f64 = 10.0;
        var good_gmin = gmin_start;
        var gmin = good_gmin / factor;
        var have_good = false;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            ckt.setHomotopy(gmin, deck_scale);
            const r = newtonRun(ckt, ws, x, gmin, itl2, !have_good);
            if (r.converged) {
                if (gmin <= gmin_target) {
                    // dynamic_gmin's last solve drops the shunt: the answer
                    // must not carry it.
                    ckt.setHomotopy(deck_gmin, deck_scale);
                    if (newtonRun(ckt, ws, x, 0, itl1, false).converged) return .gmin;
                    break;
                }
                @memcpy(&x_good, x);
                have_good = true;
                good_gmin = gmin;
                if (r.iterations <= itl2 / 4) {
                    factor = @min(factor * @sqrt(factor), 10.0);
                } else if (r.iterations > 3 * itl2 / 4) {
                    factor = @max(@sqrt(factor), 1.00005);
                }
                if (gmin < factor * gmin_target) {
                    factor = gmin / gmin_target;
                    gmin = gmin_target;
                } else gmin /= factor;
            } else {
                if (factor < 1.00005) break; // wedged against the last good step
                factor = @sqrt(@sqrt(factor));
                gmin = good_gmin / factor;
                if (have_good) @memcpy(x, &x_good) else coldStart(ckt, x);
            }
        }
        ckt.setHomotopy(deck_gmin, deck_scale);
    }

    // Rung 3: source stepping from every source at zero, with an adaptive
    // step: 1.5x on success, halved on failure and retried from the last
    // good lambda and x. Then a full solve from wherever it got to.
    if (@hasField(M, "source_scale__")) {
        coldStart(ckt, x);
        var lambda: f64 = 0;
        var lambda_good: f64 = -1; // none converged yet
        var delta: f64 = 0.25;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            ckt.setHomotopy(deck_gmin, lambda * deck_scale);
            const r = newtonRun(ckt, ws, x, 0, itl2, lambda_good < 0);
            if (r.converged) {
                if (lambda >= 1.0) break; // full sources reached
                lambda_good = lambda;
                @memcpy(&x_good, x);
                delta *= 1.5;
                lambda = @min(lambda + delta, 1.0);
            } else {
                delta *= 0.5;
                if (delta < 1e-4) break;
                // Nothing converged yet: the lambda = 0 start failed, and a
                // retry would be the same cold solve.
                if (lambda_good < 0) break;
                @memcpy(x, &x_good);
                lambda = @min(lambda_good + delta, 1.0);
            }
        }
        ckt.setHomotopy(deck_gmin, deck_scale);
        if (newtonRun(ckt, ws, x, 0, itl1, false).converged) return .source;
    }
    return error.NoOperatingPoint;
}

// ---------------------------------------------------------------------------
// Tests: hand-written devices with hand-solved operating points, one per
// rung, and one with no operating point at all.
// ---------------------------------------------------------------------------

const Circuit = @import("circuit.zig").Circuit;

/// `in` -- k·v³ -- `mid` -- k·v³ -- ground, from a 1 V source on `in`
/// (branch current `br`). Each conductance is 3k·v², so at the cold start
/// the `mid` row and column are zero and plain Newton's first matrix is
/// singular. By symmetry k(1 - m)³ = k·m³, so V(mid) = 0.5.
const MockCubic = struct {
    pub const U = enum(u8) { in, mid, br };
    pub const num_ports: usize = 0;
    pub const vera_version = contract.vera_version;
    pub const u_kinds = [_]contract.UnknownKind{ .voltage, .voltage, .current };
    pub const Model = struct { k: f64 = 1e-3, gmin__: f64 = 1e-12, source_scale__: f64 = 1.0 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [3]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const d = p[0].sub(p[1]);
        const top = d.mul(d).mul(d).scale(m.k);
        const bot = p[1].mul(p[1]).mul(p[1]).scale(m.k);
        return contract.rows(@This(), S, .{ top.add(p[2]), bot.sub(top), p[0].addC(-1.0 * m.source_scale__) });
    }
};

/// A 5 V source through 1 ohm into `is·(exp(v/vt) - 1)` with no `$limit`.
/// Newton from 0 lands near 5 V and walks down about vt per iteration,
/// some 165 iterations to the knee: past itl1 for plain Newton and past
/// itl2 for every gmin step (1/R = 1 S swamps gmin <= 1e-2). Source
/// stepping reaches it. The root of 5 - v = 1e-14·(exp(v/0.025) - 1) is
/// v = 0.8415334423073747 (Newton in python3, 200 iterations from 0.9).
const MockDiode = struct {
    pub const U = enum(u8) { in, a, br };
    pub const num_ports: usize = 0;
    pub const vera_version = contract.vera_version;
    pub const u_kinds = [_]contract.UnknownKind{ .voltage, .voltage, .current };
    pub const Model = struct { gmin__: f64 = 1e-12, source_scale__: f64 = 1.0 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [3]S.V, m: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const ir = p[0].sub(p[1]);
        const id = p[1].scale(1.0 / 0.025).exp().addC(-1.0).scale(1e-14);
        return contract.rows(@This(), S, .{ ir.add(p[2]), id.sub(ir), p[0].addC(-5.0 * m.source_scale__) });
    }
};

test "a singular cold start is gmin stepping's, a slow one source stepping's, and the deck's knobs come back" {
    {
        var model: MockCubic.Model = .{};
        var inst: MockCubic.Instance = .{};
        var ckt: Circuit(MockCubic) = .init(&model, &inst);
        var ws: converger.Workspace(3) = .{};
        var x: [3]f64 = undefined;
        try std.testing.expectEqual(Rung.gmin, try solve(&ckt, &ws, &x, .dc));
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), x[1], 1e-6);
        try std.testing.expectEqual(@as(f64, 1e-12), model.gmin__);
    }
    {
        var model: MockDiode.Model = .{};
        var inst: MockDiode.Instance = .{};
        var ckt: Circuit(MockDiode) = .init(&model, &inst);
        var ws: converger.Workspace(3) = .{};
        var x: [3]f64 = undefined;
        try std.testing.expectEqual(Rung.source, try solve(&ckt, &ws, &x, .dc));
        // The published point is the last linearization point, within
        // SPICE's reltol of the root.
        try std.testing.expectApproxEqAbs(@as(f64, 0.8415334423073747), x[1], 1e-3);
        try std.testing.expectEqual(@as(f64, 1.0), model.source_scale__);
        try std.testing.expectEqual(@as(f64, 1e-12), model.gmin__);
    }
}

/// A 2 V source across 1 kOhm: V(in) = 2, and the source's branch carries
/// -2 mA (the resistor's current leaves `in` and the branch returns it).
/// `seed` starts V(in) at 0.7, the way a §9.17.3 `$limit` seed does.
const MockLinear = struct {
    pub const U = enum(u8) { in, br };
    pub const num_ports: usize = 0;
    pub const vera_version = contract.vera_version;
    pub const u_kinds = [_]contract.UnknownKind{ .voltage, .current };
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{ p[0].scale(1e-3).add(p[1]), p[0].addC(-2.0) });
    }

    pub fn seed(comptime _: type, _: *const Model, _: *const Instance, _: contract.SimState) [2]?f64 {
        return .{ 0.7, null };
    }
};

test coldStart {
    var model: MockLinear.Model = .{};
    var inst: MockLinear.Instance = .{};
    var ckt: Circuit(MockLinear) = .init(&model, &inst);
    var x = [_]f64{ 5, 5 };
    coldStart(&ckt, &x);
    try std.testing.expectEqual([2]f64{ 0.7, 0 }, x);
}

test solve {
    var model: MockLinear.Model = .{};
    var inst: MockLinear.Instance = .{};
    var ckt: Circuit(MockLinear) = .init(&model, &inst);
    var ws: converger.Workspace(2) = .{};
    var x: [2]f64 = undefined;
    try std.testing.expectEqual(Rung.plain, try solve(&ckt, &ws, &x, .static));
    try std.testing.expectApproxEqAbs(@as(f64, 2), x[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -2e-3), x[1], 1e-15);
    // §5.10.2 initial_step held for the solve only; the kind stays.
    try std.testing.expectEqual(contract.AnalysisKind.static, ckt.sim.kind);
    try std.testing.expect(!ckt.sim.initial_step);
    try std.testing.expect(!ckt.sim.analog_initial);
}

/// f(v) = v³ - v on one free node, roots -1, 0 and 1, starting from nodeset
/// `ns`. From the cold start 0 Newton is already at the root 0 (f(0) = 0,
/// f'(0) = -1). From 2: f = 6, f' = 11, so 2 → 1.4545 → 1.1510 → 1.0253 →
/// 1.0009 → 1, staying right of 1/√3 where f' = 0 (f is convex and
/// increasing there), so it lands on 1; from -2, by f's odd symmetry, on -1.
fn MockBistable(comptime ns: ?f64) type {
    return struct {
        pub const U = enum(u8) { a };
        pub const num_ports: usize = 1;
        pub const vera_version = contract.vera_version;
        pub const Model = struct {};
        pub const Instance = struct {};
        pub const u_nodeset = [1]?f64{ns};

        pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
            const p = contract.probes(@This(), S, x);
            return contract.rows(@This(), S, .{p[0].mul(p[0]).mul(p[0]).sub(p[0])});
        }
    };
}

fn solveBistable(comptime ns: ?f64) !f64 {
    const D = MockBistable(ns);
    var model: D.Model = .{};
    var inst: D.Instance = .{};
    var ckt: Circuit(D) = .init(&model, &inst);
    var ws: converger.Workspace(1) = .{};
    var x: [1]f64 = undefined;
    try std.testing.expectEqual(Rung.plain, try solve(&ckt, &ws, &x, .dc));
    return x[0];
}

test "a nodeset picks which root the operating point's Newton finds, and is never held" {
    try std.testing.expectEqual(@as(f64, 0), try solveBistable(null));
    // Within SPICE's reltol (1e-3) of the root; a clamped nodeset gives ±2.
    try std.testing.expectApproxEqAbs(@as(f64, 1), try solveBistable(2.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, -1), try solveBistable(-2.0), 1e-3);
}

/// One free node whose `seed` says 0.7 and whose nodeset says 1.5.
const MockSeededNodeset = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const vera_version = contract.vera_version;
    pub const Model = struct {};
    pub const Instance = struct {};
    pub const u_nodeset = [1]?f64{1.5};

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{p[0].scale(1e-3)});
    }

    pub fn seed(comptime _: type, _: *const Model, _: *const Instance, _: contract.SimState) [1]?f64 {
        return .{0.7};
    }
};

test "coldStart: a nodeset overrides the seed on its unknown" {
    var model: MockSeededNodeset.Model = .{};
    var inst: MockSeededNodeset.Instance = .{};
    var ckt: Circuit(MockSeededNodeset) = .init(&model, &inst);
    var x = [_]f64{5};
    coldStart(&ckt, &x);
    try std.testing.expectEqual([1]f64{1.5}, x);
}

/// x^2 + 1 = 0 on one node: no real root, and none with any gmin the
/// ladder tries either (x^2 + gmin·x + 1 has one only from gmin = 2).
/// No `source_scale__`, so the source rung is skipped.
const MockNoRoot = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const vera_version = contract.vera_version;
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{p[0].mul(p[0]).addC(1.0)});
    }
};

test "a device with no operating point fails every rung with error.NoOperatingPoint" {
    var model: MockNoRoot.Model = .{};
    var inst: MockNoRoot.Instance = .{};
    var ckt: Circuit(MockNoRoot) = .init(&model, &inst);
    var ws: converger.Workspace(1) = .{};
    var x: [1]f64 = undefined;
    try std.testing.expectError(error.NoOperatingPoint, solve(&ckt, &ws, &x, .dc));
}
