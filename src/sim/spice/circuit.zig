//! One VerA device as the deck runner's system: the device's unknowns are
//! the circuit's, and one `eval` fills the four planes the analyses read
//! (g = dI/dx, c = dQ/dx, rhs = I, q = Q), dense and row-major. It also
//! carries the state hooks `converger` and `tran` call (`updateStates`,
//! `stateCtl`, `boundStep`, `nextBreakpoint`), each one call into the
//! device through `tools/contract.zig`.
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
const std = @import("std");
const contract = @import("contract");

pub fn Circuit(comptime D: type) type {
    const n_u = contract.nU(D);
    return struct {
        const Self = @This();
        /// The value family of the value-only hooks: no lanes.
        pub const Val = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{ .dense = true });
        /// `eval`'s family: unknown `u` on lane `u`.
        pub const Dual = contract.RefFamily(f64, &lane_of, .{ .dense = true });
        const lane_of = blk: {
            var l: [n_u]u8 = undefined;
            for (&l, 0..) |*e, u| e.* = u;
            break :blk l;
        };
        pub const State = if (@hasDecl(D, "updateState") and @hasDecl(D, "initState")) D.State else void;
        pub const has_charge = @hasDecl(D, "q");
        pub const unknowns = n_u;
        pub const Device = D;

        n: usize = n_u,
        model: *const D.Model,
        inst: *D.Instance,
        state: State,
        /// The last accepted `inst` and `state`, which `.revert` restores.
        saved_inst: D.Instance,
        saved_state: State,
        sim: contract.SimState = .{},
        g_vals: [n_u * n_u]f64 = undefined,
        c_vals: [n_u * n_u]f64 = undefined,
        rhs: [n_u]f64 = undefined,
        q_vec: [n_u]f64 = undefined,
        diag_slots: [n_u]u32 = blk: {
            var d: [n_u]u32 = undefined;
            for (&d, 0..) |*e, i| e.* = i * n_u + i;
            break :blk d;
        },
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

        /// `model` is derived and set up, `inst` set up; the device's own
        /// `initState` gives the first state.
        pub fn init(model: *const D.Model, inst: *D.Instance) Self {
            const st: State = if (State == void) {} else D.initState(model, inst);
            return .{ .model = model, .inst = inst, .state = st, .saved_inst = inst.*, .saved_state = st };
        }

        /// Publishes the analysis kind, time and step flags; the Newton
        /// iteration count is `beginSolve`'s.
        pub fn setSimState(self: *Self, st: contract.SimState) void {
            const it = self.sim.iteration;
            self.sim = st;
            self.sim.iteration = it;
        }

        /// The whole local Jacobian: the device's lanes on the columns in
        /// `deriv_reads`, `jac_const` on the rest (`g`, or `c` when `react`).
        fn withConst(self: *const Self, rows: [n_u]Dual, react: bool) [n_u]Dual {
            var out = rows;
            inline for (comptime contract.jacConst(D)) |e| {
                if (contract.jacConstApplies(D, e, self.model, Dual.collapse_applied))
                    out[@backingInt(e.row)].d[@backingInt(e.col)] = if (react) e.c else e.g;
            }
            return out;
        }

        /// Stamps every plane at `x`. `t` is in `sim` already.
        pub fn eval(self: *Self, x: []const f64, _: f64) void {
            const r = self.withConst(D.eval(Dual, x[0..n_u], self.model, self.inst, self.sim), false);
            for (r, 0..) |row, i| {
                self.rhs[i] = row.v;
                @memcpy(self.g_vals[i * n_u ..][0..n_u], &row.d);
            }
            if (has_charge) self.evalQ(x, 0);
        }

        /// The charge planes only.
        pub fn evalQ(self: *Self, x: []const f64, _: f64) void {
            if (!has_charge) return;
            const qq = self.withConst(contract.qRows(D, Dual, D.q(Dual, x[0..n_u], self.model, self.inst, self.sim)), true);
            for (qq, 0..) |row, i| {
                self.q_vec[i] = row.v;
                @memcpy(self.c_vals[i * n_u ..][0..n_u], &row.d);
            }
        }

        /// G + alpha*C into `out` (ESPice `combineGC`).
        pub fn combineGC(self: *const Self, alpha: f64, out: []f64) void {
            for (out[0 .. n_u * n_u], self.g_vals, self.c_vals) |*o, g, c| o.* = g + alpha * c;
        }

        /// Starts a nonlinear solve: `$simparam("iteration")` reads 1.
        pub fn beginSolve(self: *Self) void {
            self.sim.iteration = 1;
        }

        /// Hands the device the previous Newton iterate, then counts it.
        pub fn advanceIteration(self: *Self, previous_x: []const f64) void {
            if (@hasDecl(D, "advanceIteration")) D.advanceIteration(Val, self.model, self.inst, previous_x[0..n_u].*, self.sim);
            self.sim.iteration +|= 1;
        }

        /// False when the device vetoes convergence at `x`.
        pub fn checkConvergence(self: *const Self, x: []const f64) bool {
            if (!@hasDecl(D, "checkConvergence")) return true;
            return D.checkConvergence(Val, self.model, self.inst, x[0..n_u].*, self.sim);
        }

        /// §9.17.3 the device's clamp of `x` against `x_old`; true when it
        /// moved anything (the iterate is then not converged).
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

        /// Commits, reverts or queries the accepted device state. `.commit`
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

        /// §9.17.2 the tightest `$bound_step` the device asked for, or null.
        /// Only meaningful after an accepted step ran `updateStates`.
        pub fn boundStep(self: *const Self) ?f64 {
            if (!@hasField(D.Instance, "bound_step")) return null;
            const b = self.inst.bound_step;
            return if (b > 0 and b < std.math.inf(f64)) b else null;
        }

        /// §5.10.3.3 the earliest device breakpoint after `t`, or null.
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
