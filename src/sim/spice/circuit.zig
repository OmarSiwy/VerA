//! One VerA device as the deck runner's system: the device's unknowns are
//! the circuit's, and one `eval` fills the four planes the analyses read
//! (g = dI/dx, c = dQ/dx, rhs = I, q = Q), dense and row-major. It also
//! carries the state hooks `converger`, `op` and `tran` call (`updateStates`,
//! `stateCtl`, `boundStep`, `nextBreakpoint`, and `setHomotopy`, the §9.15
//! gmin and source-scale knobs), each one call into the device through
//! `tools/contract.zig`.
//!
//! The role of OmarSiwy/ESPice's src/analysis/Circuit.zig and the VerA half
//! of src/device/eval.zig at 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d,
//! rewritten for one device and no ground row: ESPice's batches, CSC pattern,
//! parallel and GPU evaluation have nothing to do here. The state semantics
//! are ESPice's: `updateStates` reverts a staged update first, a
//! `request_reject_at` is collected into `reject_at` while `land_rejects`,
//! and `.query` asks whether a `cross`/`above` latch flipped.
//!
//! A deck's top module is the whole circuit, so every unknown is solved for:
//! nothing is forced. Host-only by construction (it is never imported by the
//! device text), so the device stays GPU-compilable.
//!
//! LRM: §9.15 (`gmin`, `sourceScaleFactor`), §9.17.2 `$bound_step`, §9.17.3
//! `$limit`, §9.4 display output, §5.10.3.3 breakpoints.
const std = @import("std");
const contract = @import("contract");

/// Returns the system type for device `D`: its unknowns are the circuit's,
/// its planes are fixed-size arrays (n_u² for `g`/`c`), and nothing in it
/// allocates. `D` must satisfy `tools/contract.zig`'s device contract.
pub fn Circuit(comptime D: type) type {
    const n_u = contract.nU(D);
    return struct {
        const Self = @This();
        /// The value family of the value-only hooks: no lanes.
        pub const Val = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});
        /// The family of every lane-reading entry point: unknown `u` on lane
        /// `u`, each value carrying only the partials it can have.
        pub const Dual = contract.RefFamily(f64, &lane_of, .{});
        const lane_of = blk: {
            var l: [n_u]u32 = undefined;
            for (&l, 0..) |*e, u| e.* = u;
            break :blk l;
        };
        /// The device's `State`, or `void` for a device without
        /// `updateState`/`initState`.
        pub const State = if (@hasDecl(D, "updateState") and @hasDecl(D, "initState")) D.State else void;
        /// Whether the device has charges (`q`), so `c_vals`/`q_vec` are live.
        pub const has_charge = @hasDecl(D, "q");
        /// |U|, the number of unknowns and of residual rows.
        pub const unknowns = n_u;
        /// The device type, for the analyses' own `@hasDecl` checks.
        pub const Device = D;

        /// |U| at run time, the field `converger.newton` reads.
        n: usize = n_u,
        /// Mutable for the operating point's homotopy knobs (`setHomotopy`).
        model: *D.Model,
        /// The working instance; `.revert` overwrites it with `saved_inst`.
        inst: *D.Instance,
        /// The working device state.
        state: State,
        /// The last accepted `inst` and `state`, which `.revert` restores.
        saved_inst: D.Instance,
        saved_state: State,
        /// The analysis every hook is called with; `setSimState` writes it.
        sim: contract.SimState = .{},
        /// dI/dx at the last `eval`, row-major n_u x n_u.
        g_vals: [n_u * n_u]f64 = undefined,
        /// dQ/dx at the last `eval`/`evalQ`, row-major n_u x n_u.
        c_vals: [n_u * n_u]f64 = undefined,
        /// I(x) at the last `eval`, one per row.
        rhs: [n_u]f64 = undefined,
        /// Q(x) at the last `eval`/`evalQ`, one per row.
        q_vec: [n_u]f64 = undefined,
        /// Rows whose tolerance is `abstol` (amperes), not `vntol`.
        current_row: [n_u]bool = blk: {
            var c: [n_u]bool = @splat(false);
            if (@hasDecl(D, "u_kinds")) for (D.u_kinds, &c) |k, *e| {
                e.* = k != .voltage;
            };
            break :blk c;
        },
        /// While set, `updateStates` collects a `request_reject_at` here
        /// instead of returning it (ESPice `land_rejects`).
        land_rejects: bool = false,
        reject_at: ?f64 = null,
        state_staged: bool = false,

        /// Returns the system over `model` and `inst`, which must be derived
        /// and set up and must outlive it (both are borrowed, not copied).
        /// The device's own `initState` gives the first state, which is also
        /// the first accepted one.
        pub fn init(model: *D.Model, inst: *D.Instance) Self {
            const st: State = if (State == void) {} else D.initState(model, inst);
            return .{ .model = model, .inst = inst, .state = st, .saved_inst = inst.*, .saved_state = st };
        }

        /// Whether `setup` caches a value derived from either homotopy knob,
        /// so writing one has to re-run it (`setup_simparams`).
        const caches_homotopy = blk: {
            if (!@hasDecl(D, "setup_simparams")) break :blk false;
            for (D.setup_simparams) |name| {
                if (std.mem.eql(u8, name, "gmin") or std.mem.eql(u8, name, "sourceScaleFactor")) break :blk true;
            }
            break :blk false;
        };

        /// Writes §9.15's two homotopy knobs, Table 9-27's `gmin` and
        /// `sourceScaleFactor` (`Model.gmin__`, `Model.source_scale__`; a
        /// device without the field ignores that knob), then re-runs `setup`
        /// and `setupInstance` when the device caches either.
        pub fn setHomotopy(self: *Self, gmin: f64, source_scale: f64) void {
            if (@hasField(D.Model, "gmin__")) self.model.gmin__ = gmin;
            if (@hasField(D.Model, "source_scale__")) self.model.source_scale__ = source_scale;
            if (!caches_homotopy) return;
            D.setup(Dual, self.model);
            if (@hasDecl(D, "setupInstance")) D.setupInstance(self.model, self.inst);
        }

        /// Publishes the analysis kind, time and step flags; the Newton
        /// iteration count is `beginSolve`'s.
        pub fn setSimState(self: *Self, st: contract.SimState) void {
            const it = self.sim.iteration;
            self.sim = st;
            self.sim.iteration = it;
        }

        /// Writes `rows` into `vals` and the row-major `plane`, then
        /// `jac_const` on its columns (`g`, or `c` when `react`).
        /// `rows` is indexable by row; each row may be its own sparse type.
        fn scatter(self: *const Self, rows: anytype, vals: *[n_u]f64, plane: *[n_u * n_u]f64, react: bool) void {
            inline for (0..n_u) |i| {
                const T = @TypeOf(rows[i]);
                const dst = plane[i * n_u ..][0..n_u];
                vals[i] = rows[i].v;
                // One run-time loop over the row's lanes, not n_u inline reads.
                @memset(dst, 0.0);
                const lanes: [@popCount(T.mask)]f64 = rows[i].d;
                for (comptime laneColumns(T.mask), lanes) |u, l| dst[u] = l;
            }
            inline for (comptime contract.jacConst(D)) |e| {
                if (contract.jacConstApplies(D, e, self.model, Dual.collapse_applied))
                    plane[@as(usize, @backingInt(e.row)) * n_u + @backingInt(e.col)] = if (react) e.c else e.g;
            }
        }

        /// The unknown each lane of a value with mask `m` belongs to, in lane order.
        fn laneColumns(comptime m: anytype) [@popCount(m)]usize {
            var cols: [@popCount(m)]usize = undefined;
            var j: usize = 0;
            for (0..@bitSizeOf(@TypeOf(m))) |u| if ((m >> u) & 1 != 0) {
                cols[j] = u;
                j += 1;
            };
            return cols;
        }

        /// Stamps every plane at `x`, `c_vals`/`q_vec` too when the device
        /// has charge, at the time `setSimState` published.
        /// Asserts that `x` holds at least n_u values.
        pub fn eval(self: *Self, x: []const f64) void {
            self.scatter(D.eval(Dual, x[0..n_u], self.model, self.inst, self.sim), &self.rhs, &self.g_vals, false);
            if (has_charge) self.evalQ(x);
        }

        /// Stamps the charge planes only (`c_vals`, `q_vec`); a no-op for a
        /// device without charge. Asserts that `x` holds at least n_u values.
        pub fn evalQ(self: *Self, x: []const f64) void {
            if (!has_charge) return;
            self.scatter(contract.qRows(D, Dual, D.q(Dual, x[0..n_u], self.model, self.inst, self.sim)), &self.q_vec, &self.c_vals, true);
        }

        /// Writes G + alpha*C into `out` (ESPice `combineGC`), from the
        /// planes of the last `eval`. Asserts that `out` holds n_u² values.
        pub fn combineGC(self: *const Self, alpha: f64, out: []f64) void {
            // Per element a multiply then an add, never fused (strict mode).
            for (out[0 .. n_u * n_u], &self.g_vals, &self.c_vals) |*o, g, c| o.* = g + alpha * c;
        }

        /// Starts a nonlinear solve: §9.15 `$simparam("iteration")` reads 1.
        pub fn beginSolve(self: *Self) void {
            self.sim.iteration = 1;
        }

        /// Hands the device the previous Newton iterate, then counts it
        /// (saturating). Asserts that `previous_x` holds n_u values.
        pub fn advanceIteration(self: *Self, previous_x: []const f64) void {
            if (@hasDecl(D, "advanceIteration")) D.advanceIteration(Val, self.model, self.inst, previous_x[0..n_u].*, self.sim);
            self.sim.iteration +|= 1;
        }

        /// Returns false when the device vetoes convergence at `x`; true for
        /// a device without `checkConvergence`.
        pub fn checkConvergence(self: *const Self, x: []const f64) bool {
            if (!@hasDecl(D, "checkConvergence")) return true;
            return D.checkConvergence(Val, self.model, self.inst, x[0..n_u].*, self.sim);
        }

        /// Applies §9.17.3 the device's clamp of `x` against `x_old` in
        /// place. Returns true when it moved anything or the device says the
        /// iterate is not converged (`LimitResult.converged`).
        pub fn applyLimits(self: *const Self, x: []f64, x_old: []const f64) bool {
            if (!@hasDecl(D, "limit")) return false;
            const r = D.limit(Val, self.model, self.inst, x[0..n_u].*, x_old[0..n_u].*, self.sim);
            var limited = false;
            for (x[0..n_u], r.x) |*xi, li| if (xi.* != li) {
                xi.* = li;
                limited = true;
            };
            return limited or !r.converged;
        }

        /// Advances device state from the last accepted point to `x`
        /// (`updateState`). Returns the earliest retry time the device asks
        /// for, or null; while `land_rejects` it is kept in `reject_at` and
        /// null is returned. A second call before the next commit or revert
        /// reverts first, since one `updateState` is what `.revert` undoes.
        pub fn updateStates(self: *Self, x: []const f64) ?f64 {
            if (State == void) return null;
            if (self.state_staged) _ = self.stateCtl(.revert);
            self.state_staged = true;
            const tr: ?f64 = switch (D.updateState(Val, self.model, self.inst, x[0..n_u].*, &self.state, self.sim)) {
                .ok => null,
                .request_reject_at => |r| r,
            };
            if (!self.land_rejects) return tr;
            if (tr) |r| self.reject_at = if (self.reject_at) |cur| @min(cur, r) else r;
            return null;
        }

        /// Commits, reverts or queries the accepted device state, and returns
        /// the query's answer (false for `.commit`/`.revert`). `.commit`
        /// at every accepted point, the operating point included; `.revert`
        /// after every rejected attempt. `.query`: did a `cross`/`above`
        /// flip move the working state off the last accepted one?
        pub fn stateCtl(self: *Self, op: contract.StateCtlOp) bool {
            if (op != .query) self.state_staged = false;
            switch (op) {
                .query => return if (State != void and @hasDecl(D, "stateCtl")) D.stateCtl(self.model, self.inst, &self.state, .query) else false,
                .commit => {
                    if (State != void and @hasDecl(D, "stateCtl")) _ = D.stateCtl(self.model, self.inst, &self.state, .commit);
                    self.saved_inst = self.inst.*;
                    self.saved_state = self.state;
                },
                .revert => {
                    self.inst.* = self.saved_inst;
                    self.state = self.saved_state;
                },
            }
            return false;
        }

        /// §9.4 the device's display output for the point `x` the analysis is
        /// accepting, to stderr: what a `.record` device's `say` records,
        /// rendered by `contract.formatSay`, or a printing device's own
        /// `display`. Called before the commit, so the device reads the
        /// `Instance` `eval` saw (`saved_inst`; §9.4.6: no display task but
        /// `$debug` shows output unless an iteration has been accepted).
        pub fn say(self: *const Self, x: []const f64) void {
            var inst = self.saved_inst;
            if (@hasDecl(D, "say")) {
                var store: [4096]f64 = undefined;
                var rec: contract.Say = .{ .buf = &store };
                D.say(Dual, x[0..n_u], self.model, &inst, self.sim, &rec);
                var text: [65536]u8 = undefined;
                var w: std.Io.Writer = .fixed(&text);
                contract.formatSay(D, &rec, "", &w) catch {};
                std.debug.print("{s}", .{w.buffered()});
            } else if (@hasDecl(D, "display")) D.display(Dual, x[0..n_u], self.model, &inst, self.sim);
        }

        /// Returns §9.17.2 the tightest `$bound_step` the device asked for,
        /// or null when it asked for none (0, infinite, or no field).
        /// Only meaningful after an accepted step ran `updateStates`.
        pub fn boundStep(self: *const Self) ?f64 {
            if (!@hasField(D.Instance, "bound_step")) return null;
            const b = self.inst.bound_step;
            return if (b > 0 and b < std.math.inf(f64)) b else null;
        }

        /// Returns §5.10.3.3 the earliest device breakpoint after `t` from
        /// either hook, or null when neither has one.
        pub fn nextBreakpoint(self: *const Self, t: f64) ?f64 {
            var best = std.math.inf(f64);
            if (@hasDecl(D, "nextBreakpoint")) if (D.nextBreakpoint(self.model, t)) |bp| {
                best = @min(best, bp);
            };
            if (@hasDecl(D, "pendingBreakpoint")) if (D.pendingBreakpoint(self.inst, t)) |bp| {
                best = @min(best, bp);
            };
            return if (best == std.math.inf(f64)) null else best;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: one hand-written device per group of hooks, each hook observable
// through what it writes to `Model`, `Instance` or `State`.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Counts `updateState` calls in `State` and `Instance`, and asks for a
/// retry at x[0] when x[0] > 0. Breakpoints at `Model.bp` and
/// `Instance.pending`; §9.17.2 `bound_step` as the host-written field.
const MockState = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { bp: f64 = std.math.inf(f64) };
    pub const Instance = struct { level: u32 = 0, bound_step: f64 = 0, pending: f64 = std.math.inf(f64) };
    pub const State = struct { updates: u32 = 0 };

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return contract.rows(@This(), S, contract.probes(@This(), S, x));
    }
    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }
    pub fn updateState(comptime _: type, _: *const Model, inst: *Instance, x: [1]f64, st: *State, _: contract.SimState) contract.UpdateResult {
        st.updates += 1;
        inst.level += 1;
        return if (x[0] > 0) .{ .request_reject_at = x[0] } else .ok;
    }
    pub fn nextBreakpoint(m: *const Model, t: f64) ?f64 {
        return if (t < m.bp) m.bp else null;
    }
    pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {
        return if (t < inst.pending) inst.pending else null;
    }
};

test "updateStates stages one update, which commit keeps and revert undoes" {
    var model: MockState.Model = .{};
    var inst: MockState.Instance = .{};
    var ckt: Circuit(MockState) = .init(&model, &inst);
    try testing.expectEqual(null, ckt.updateStates(&.{0.0}));
    try testing.expectEqual(1, ckt.state.updates);
    // A second update before a commit or revert reverts the first.
    try testing.expectEqual(null, ckt.updateStates(&.{0.0}));
    try testing.expectEqual(1, ckt.state.updates);
    try testing.expectEqual(1, inst.level);
    try testing.expect(!ckt.stateCtl(.commit));
    _ = ckt.updateStates(&.{0.0});
    try testing.expectEqual(2, ckt.state.updates);
    try testing.expectEqual(2, inst.level);
    try testing.expect(!ckt.stateCtl(.revert));
    try testing.expectEqual(1, ckt.state.updates);
    try testing.expectEqual(1, inst.level);
    // No stateCtl hook: the query sees no flip.
    try testing.expect(!ckt.stateCtl(.query));
}

test "a retry request is returned, or collected at its earliest while land_rejects" {
    var model: MockState.Model = .{};
    var inst: MockState.Instance = .{};
    var ckt: Circuit(MockState) = .init(&model, &inst);
    try testing.expectEqual(@as(?f64, 3), ckt.updateStates(&.{3.0}));
    ckt.land_rejects = true;
    try testing.expectEqual(null, ckt.updateStates(&.{2.0}));
    try testing.expectEqual(@as(?f64, 2), ckt.reject_at);
    try testing.expectEqual(null, ckt.updateStates(&.{1.0}));
    try testing.expectEqual(null, ckt.updateStates(&.{5.0}));
    try testing.expectEqual(@as(?f64, 1), ckt.reject_at);
}

test "Circuit.boundStep" {
    var model: MockState.Model = .{};
    var inst: MockState.Instance = .{};
    var ckt: Circuit(MockState) = .init(&model, &inst);
    // §9.17.2 0 and infinity ask for no bound.
    try testing.expectEqual(null, ckt.boundStep());
    inst.bound_step = std.math.inf(f64);
    try testing.expectEqual(null, ckt.boundStep());
    inst.bound_step = 1e-9;
    try testing.expectEqual(@as(?f64, 1e-9), ckt.boundStep());
}

test "Circuit.nextBreakpoint" {
    var model: MockState.Model = .{};
    var inst: MockState.Instance = .{};
    var ckt: Circuit(MockState) = .init(&model, &inst);
    // Both hooks answer infinity: no breakpoint.
    try testing.expectEqual(null, ckt.nextBreakpoint(0));
    model.bp = 3e-9;
    try testing.expectEqual(@as(?f64, 3e-9), ckt.nextBreakpoint(0));
    inst.pending = 2e-9;
    try testing.expectEqual(@as(?f64, 2e-9), ckt.nextBreakpoint(0));
    // Past the pending one, the card's is next; past both, none.
    try testing.expectEqual(@as(?f64, 3e-9), ckt.nextBreakpoint(2e-9));
    try testing.expectEqual(null, ckt.nextBreakpoint(3e-9));
}

/// §9.15's two knobs, with `setup` caching `sourceScaleFactor`; `setup`
/// and `setupInstance` count their runs.
const MockKnobs = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { gmin__: f64 = 1e-12, source_scale__: f64 = 1, setups: u32 = 0 };
    pub const Instance = struct { setups: u32 = 0 };
    pub const setup_simparams = [_][]const u8{"sourceScaleFactor"};

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return contract.rows(@This(), S, contract.probes(@This(), S, x));
    }
    pub fn setup(comptime _: type, m: *Model) void {
        m.setups += 1;
    }
    pub fn setupInstance(_: *const Model, inst: *Instance) void {
        inst.setups += 1;
    }
};

test "Circuit.setHomotopy" {
    var model: MockKnobs.Model = .{};
    var inst: MockKnobs.Instance = .{};
    var ckt: Circuit(MockKnobs) = .init(&model, &inst);
    ckt.setHomotopy(1e-3, 0.25);
    try testing.expectEqual(1e-3, model.gmin__);
    try testing.expectEqual(0.25, model.source_scale__);
    try testing.expectEqual(1, model.setups);
    try testing.expectEqual(1, inst.setups);
    // A device with neither field nor cache: nothing to write, nothing runs.
    var m2: MockState.Model = .{};
    var inst2: MockState.Instance = .{};
    var plain: Circuit(MockState) = .init(&m2, &inst2);
    plain.setHomotopy(1e-3, 0.25);
    try testing.expectEqual(std.math.inf(f64), m2.bp);
}

/// The iteration hooks: `advanceIteration` keeps the iterate it is handed,
/// `checkConvergence` refuses x[0] >= 1, `limit` caps a rise at `step`.
const MockHooks = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const vera_version = contract.vera_version;
    pub const Model = struct { step: f64 = 0.5, converged: bool = true };
    pub const Instance = struct { prev: f64 = -1 };

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return contract.rows(@This(), S, contract.probes(@This(), S, x));
    }
    pub fn advanceIteration(comptime _: type, _: *const Model, inst: *Instance, prev: [1]f64, _: contract.SimState) void {
        inst.prev = prev[0];
    }
    pub fn checkConvergence(comptime _: type, _: *const Model, _: *const Instance, x: [1]f64, _: contract.SimState) bool {
        return x[0] < 1;
    }
    pub fn limit(comptime _: type, m: *const Model, _: *const Instance, cur: [1]f64, old: [1]f64, _: contract.SimState) contract.LimitResult(1) {
        return .{ .x = .{@min(cur[0], old[0] + m.step)}, .converged = m.converged };
    }
};

test "the iteration count: beginSolve sets 1, advanceIteration counts, setSimState keeps it" {
    var model: MockHooks.Model = .{};
    var inst: MockHooks.Instance = .{};
    var ckt: Circuit(MockHooks) = .init(&model, &inst);
    ckt.beginSolve();
    try testing.expectEqual(1, ckt.sim.iteration);
    ckt.advanceIteration(&.{0.25});
    try testing.expectEqual(0.25, inst.prev);
    try testing.expectEqual(2, ckt.sim.iteration);
    ckt.setSimState(.{ .t = 1e-9, .kind = .tran });
    try testing.expectEqual(2, ckt.sim.iteration);
    try testing.expectEqual(contract.AnalysisKind.tran, ckt.sim.kind);
    // Saturating: a runaway solve does not wrap to 0.
    ckt.sim.iteration = std.math.maxInt(u32);
    ckt.advanceIteration(&.{0.0});
    try testing.expectEqual(std.math.maxInt(u32), ckt.sim.iteration);
    try testing.expect(ckt.checkConvergence(&.{0.5}));
    try testing.expect(!ckt.checkConvergence(&.{2.0}));
}

test "Circuit.applyLimits" {
    var model: MockHooks.Model = .{};
    var inst: MockHooks.Instance = .{};
    var ckt: Circuit(MockHooks) = .init(&model, &inst);
    // 0 -> 2 is capped at 0.5 and reported.
    var x = [_]f64{2};
    try testing.expect(ckt.applyLimits(&x, &.{0.0}));
    try testing.expectEqual(0.5, x[0]);
    // Within the cap nothing moves.
    x = .{0.25};
    try testing.expect(!ckt.applyLimits(&x, &.{0.0}));
    try testing.expectEqual(0.25, x[0]);
    // The device may refuse convergence without moving anything.
    model.converged = false;
    try testing.expect(ckt.applyLimits(&x, &.{0.0}));
    try testing.expectEqual(0.25, x[0]);
}

/// Two decoupled rows, I = (2a, 3b) and Q = (5a, 7b), plus a constant
/// partial dI_a/db = 11, dQ_a/db = 13 from `jac_const`.
const MockJac = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const vera_version = contract.vera_version;
    pub const Model = struct {};
    pub const Instance = struct {};
    pub const jac_const = [_]contract.JacConst(U){.{ .row = .a, .col = .b, .g = 11, .c = 13 }};

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{ p[0].scale(2), p[1].scale(3) });
    }
    pub fn q(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Sites(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.sites(@This(), S, .{ p[0].scale(5), p[1].scale(7) });
    }
};

test "eval fills all four planes, jac_const included, and combineGC adds them" {
    var model: MockJac.Model = .{};
    var inst: MockJac.Instance = .{};
    var ckt: Circuit(MockJac) = .init(&model, &inst);
    ckt.eval(&.{ 1, 2 });
    try testing.expectEqual([2]f64{ 2, 6 }, ckt.rhs);
    try testing.expectEqual([2]f64{ 5, 14 }, ckt.q_vec);
    try testing.expectEqual([4]f64{ 2, 11, 0, 3 }, ckt.g_vals);
    try testing.expectEqual([4]f64{ 5, 13, 0, 7 }, ckt.c_vals);
    // G + 0.5·C.
    var a: [4]f64 = undefined;
    ckt.combineGC(0.5, &a);
    try testing.expectEqual([4]f64{ 4.5, 17.5, 0, 6.5 }, a);
}

/// Five unknowns, so the planes hold 25 values: whole vectors and a tail
/// at every width up to 16.
const MockWide = struct {
    pub const U = enum(u8) { a, b, c, d, e };
    pub const num_ports: usize = 5;
    pub const vera_version = contract.vera_version;
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [5]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return contract.rows(@This(), S, contract.probes(@This(), S, x));
    }
};

test "combineGC equals g + alpha·c bit for bit" {
    var model: MockWide.Model = .{};
    var inst: MockWide.Instance = .{};
    var ckt: Circuit(MockWide) = .init(&model, &inst);
    var prng: std.Random.DefaultPrng = .init(3);
    const rnd = prng.random();
    for (&ckt.g_vals, &ckt.c_vals) |*g, *c| {
        g.* = rnd.float(f64) - 0.5;
        c.* = (rnd.float(f64) - 0.5) * 1e-12;
    }
    const alpha = 3.7e9;
    var out: [25]f64 = undefined;
    ckt.combineGC(alpha, &out);
    for (out, ckt.g_vals, ckt.c_vals) |o, g, c| {
        try testing.expectEqual(@as(u64, @bitCast(g + alpha * c)), @as(u64, @bitCast(o)));
    }
}
