//! Transient analysis: Newton per timestep on A = G + ag0*C, with ngspice's
//! LTE step control, order promotion and breakpoint landing. The companion
//! residual uses the exact q(x) plane and the Jacobian the analytic C plane.
//!
//! Copied from OmarSiwy/ESPice src/analysis/tran/tran.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d: `simulate`, `TranHook`, the
//! MODEINITPRED predictor and `almostEqualUlps`. Adapted: the system is one
//! VerA device (`circuit.Circuit`) with fixed-size planes, so the scratch is
//! on the stack and nothing allocates; the stdpp predictor pipeline is its
//! plain loop; a recorded point goes to `recorder.record(t, x)`. Not taken:
//! `.tran uic` and `tstart`, the per-state LTE tape (`q_tape`, `vera_lte`:
//! the LTE runs over the row plane, ESPice's own fallback), transmission-line
//! delay echoes (`D.delays`), the accepted-point charge re-read for devices
//! with stateful charge, the per-device predictor and limit hooks, progress
//! checkpoints and the `ZP_*` statistics.
const std = @import("std");
const converger = @import("converger.zig");
const integrator = @import("integrator.zig");

pub const Method = integrator.Method;

/// `.tran` options (ESPice `core.query.Tran` and the transient half of
/// `Tolerances`).
pub const Options = struct {
    t_stop: f64,
    /// The card's tstep.
    dt_init: f64 = 1e-9,
    dt_min: f64 = 1e-18,
    /// ngspice tmax. Null means t_stop / 50.
    dt_max: ?f64 = null,
    method: Method = .trapezoidal,
    /// The trapezoid's weight on the previous step's derivative, [0, 0.5].
    xmu: f64 = 0.5,
    /// Runaway guard only; `dt_min` is the real brake.
    max_steps: u32 = 1_000_000_000,
    reltol: f64 = 1e-3,
    /// Amperes.
    abstol: f64 = 1e-12,
    /// Volts.
    vntol: f64 = 1e-6,
    /// Coulombs; charge floor of the truncation-error estimate.
    chgtol: f64 = 1e-14,
    /// Factor by which the truncation-error estimate is assumed to overshoot.
    trtol: f64 = 7.0,
};

pub const SimResult = struct { completed: bool, steps: u32, t_final: f64 };

/// Newton hook: companion RHS from the q plane, matrix G + ag0*C.
fn TranHook(comptime C: type) type {
    return struct {
        const Self = @This();
        /// The method this attempt integrates with (BE while order-dropped).
        method: Method,
        c: integrator.Coeffs,
        q_prev: []const f64,
        i_prev: []const f64, // read by trap only
        q_prev2: []const f64, // read by gear_2 only
        a_vals: []f64,

        /// Stamps the planes at `x` and adds the companion's dynamic current
        /// to the residual rows (converger hook).
        pub fn assemble(self: Self, ckt: *C, x: []const f64, t: f64) void {
            ckt.eval(x, t);
            if (C.has_charge) {
                switch (self.method) {
                    inline else => |m| integrator.companionAt(m, true, &ckt.rhs, &ckt.q_vec, self.q_prev, self.q_prev2, self.i_prev, self.c),
                }
            }
        }

        /// The Newton matrix values: G itself without charge, else G + ag0*C
        /// rebuilt into `a_vals`, overwriting the previous return.
        pub fn vals(self: Self, ckt: *C) []f64 {
            if (!C.has_charge) return &ckt.g_vals;
            ckt.combineGC(self.c.ag0, self.a_vals);
            return self.a_vals;
        }
    };
}

/// trial = cur + xfact·(cur - prev), the MODEINITPRED extrapolation.
fn predict(trial: []f64, cur: []const f64, prev: []const f64, xfact: f64) void {
    for (trial, cur, prev[0..cur.len]) |*t, c, p| t.* = c + xfact * (c - p);
}

/// Integrates from the operating point in `x` (solved and committed by
/// `op.solve`) to options.t_stop, recording every accepted point, t = 0
/// included, through `recorder.record(t, x)`. On return `x` holds the last
/// accepted solution. A dt underflow returns `completed = false`, not an
/// error; the only error is the recorder's.
pub fn simulate(ckt: anytype, ws: anytype, x: []f64, options: Options, recorder: anytype) !SimResult {
    const C = @TypeOf(ckt.*);
    const n = C.unknowns;
    const has_charge = C.has_charge;

    // A device's `request_reject_at` retries the step ending at that time.
    ckt.land_rejects = true;
    defer ckt.land_rejects = false;
    var x_try: [n]f64 = undefined;
    // The accepted point before `cur`, for the predictor. Equal to `cur`
    // until the first step is accepted, so that step starts from the OP.
    var x_prev: [n]f64 = undefined;
    @memcpy(&x_prev, x[0..n]);

    // Row-plane charge state: the dynamic current and the charge ring
    // [cur, prev, prev2, prev3]. Slot 0 takes the charge of each converged
    // attempt; the companion residual reads slots 1 and 2.
    var a_buf: [n * n]f64 = undefined;
    var i_prev: [n]f64 = @splat(0);
    var q_buf: [4][n]f64 = undefined;
    var q_hist: [4][]f64 = .{ &q_buf[0], &q_buf[1], &q_buf[2], &q_buf[3] };
    if (has_charge) {
        // No setSimState first: q_prev must be the charge the operating point
        // saw, so this eval runs in the static state op.solve left behind.
        ckt.eval(x, 0);
        // A flat q(0) history makes every divided difference vanish, so LTE
        // control runs from the first step.
        for (q_hist[1..]) |q| @memcpy(q, &ckt.q_vec);
    }

    ckt.setSimState(.{ .t = 0, .dt = 0, .kind = .tran, .initial_step = true, .analog_initial = false });
    _ = ckt.stateCtl(.commit);

    // ngspice tmax defaults to (tstop - tstart)/50.
    const effective_dt_max = options.dt_max orelse options.t_stop / 50.0;
    // The analysis' own CKTminBreak: delmin = 1e-11*maxStep and minBreak =
    // 10*delmin (traninit.c:36, dctran.c:170). Breakpoints closer than this
    // to the current time or to each other merge (dctran.c:636,
    // cktsetbk.c:45).
    const delmin = 1e-11 * effective_dt_max;
    const min_break = 10.0 * delmin;
    // How sharply a device state flip must land before the step is accepted.
    // An espice Newton/FSM tolerance with no ngspice counterpart.
    const state_eps = 5e-5 * effective_dt_max;

    try recorder.record(0, x[0..n]);

    var cur: []f64 = x[0..n];
    var trial: []f64 = &x_try;
    var prev: []f64 = &x_prev;
    var t: f64 = 0;
    // ngspice's first step: min(tstep, tstop/100)/10 clamped to tmax outside
    // the min (dctran.c:134), then the t = 0 breakpoint clamp 0.1*breaks[1]
    // (dctran.c:578-586), then the firsttime /10. The operand order sets the
    // phase of the whole accepted grid.
    var dt: f64 = @min(@min(options.dt_init, options.t_stop / 100.0) / 10.0, effective_dt_max);
    if (ckt.nextBreakpoint(min_break)) |bp0| dt = @min(dt, 0.1 * bp0);
    dt /= 10.0;
    // CKTdeltaOld[] starts at CKTmaxStep (dctran.c:312), which the first
    // divided differences read.
    var dt_prev: f64 = effective_dt_max;
    var dt_prev2: f64 = effective_dt_max;
    var steps: u32 = 0;
    // Order control: start at BE, promote to the configured method when the
    // LTE allows, and drop back to BE at breakpoints so trap does not ring
    // after a source edge.
    var use_be: bool = true;
    // ngspice's CKTbreaks[0] as the next step starts: the first breakpoint
    // past t + min_break, and whether dt_next was clamped onto it. Landing is
    // tested after the step is accepted, so a rejected step leaves no stale
    // flag. bp_save_dt is spice3's CKTsaveDelta, the dt the LTE wanted before
    // the last clamp; ngspice starts it at tstop/50 (dctran.c:318).
    var bp_next: ?f64 = null;
    var bp_clamped = false;
    var bp_save_dt: f64 = options.t_stop / 50.0;

    while (t < options.t_stop and steps < options.max_steps) {
        // Publish the point this attempt aims at before anything evaluates
        // it. §5.10.2: initial_step is the analysis' first step, final_step
        // the one that lands on t_stop.
        ckt.setSimState(.{
            .t = t + dt,
            .dt = dt,
            .kind = .tran,
            .initial_step = steps == 0,
            .final_step = t + dt >= options.t_stop,
            .analog_initial = false,
        });
        const eff_method: Method = if (use_be) .backward_euler else options.method;
        const cf = integrator.coeffs(eff_method, dt, dt_prev, options.xmu);
        const hook = TranHook(C){
            .method = eff_method,
            .c = cf,
            .q_prev = q_hist[1],
            .i_prev = &i_prev,
            .q_prev2 = q_hist[2],
            .a_vals = &a_buf,
        };

        // MODEINITPRED (dctran.c:794): the first iterate extrapolates the
        // last two accepted points by dt/dt_prev.
        predict(trial, cur, prev, dt / dt_prev);
        // ngspice's transient Newton accepts on the per-row delta test alone
        // (niconv.c).
        const nr_opts: converger.Options = .{
            .reltol = options.reltol,
            .abstol = options.abstol,
            .vntol = options.vntol,
            .residual_tol = std.math.inf(f64),
        };
        ckt.reject_at = null;
        const nr = converger.newton(ckt, ws, trial, t + dt, nr_opts, hook) catch
            converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };

        if (!nr.converged) {
            // Restore FSM devices to the last accepted state.
            _ = ckt.stateCtl(.revert);
            // Cut dt by 8 and drop to order 1 in one retry (dctran.c:815, :823).
            use_be = true;
            dt /= 8.0;
            if (dt < options.dt_min) return .{ .completed = false, .steps = steps, .t_final = t };
            continue;
        }

        // A device located an event inside this step and asked for the step
        // to end on it (`request_reject_at`): retry landing there. A time
        // within state_eps of the step's end counts as the end, the
        // resolution the flip query below keeps too.
        if (ckt.reject_at) |tr| if (tr > t and t + dt - tr > state_eps and tr - t >= options.dt_min) {
            _ = ckt.stateCtl(.revert);
            dt = tr - t;
            continue;
        };

        // A device state flipped inside this step (a `cross` fired): reject
        // and shrink so the event lands within state_eps of the crossing
        // instead of smeared across dt.
        if (dt > state_eps and ckt.stateCtl(.query)) {
            _ = ckt.stateCtl(.revert);
            use_be = true;
            dt = @max(0.25 * dt, state_eps);
            continue;
        }

        // The first accepted point skips CKTtrunc (dctran.c firsttime), so dt
        // repeats. §9.17.2 `$bound_step` is read after the step and applies
        // to the next one; devices only set it in `updateState`, so it cannot
        // be folded into effective_dt_max.
        var dt_next = if (steps == 0) dt else @min(dt * 2.0, effective_dt_max);
        if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);

        if (has_charge) {
            // CKTterr reads the charge of the published point.
            ckt.evalQ(trial, t + dt);
            @memcpy(q_hist[0], &ckt.q_vec);
            // Taken before the ring rotation below.
            const lq: [4][]const f64 = .{ q_hist[0], q_hist[1], q_hist[2], q_hist[3] };
            const lte: integrator.LteIn = .{
                .dt = dt,
                .dt1 = dt_prev,
                .dt2 = dt_prev2,
                .reltol = options.reltol,
                .abstol = options.abstol,
                .chgtol = options.chgtol,
                .trtol = options.trtol,
            };
            const W = std.simd.suggestVectorLength(f64) orelse 8;

            if (steps > 0) {
                const del = integrator.stepBound(W, eff_method, eff_method, lq, &i_prev, cf, lte);
                if (del < 0.9 * dt) {
                    _ = ckt.stateCtl(.revert);
                    // Retry at the LTE's dt and the same order
                    // (dctran.c:966 `CKTdelta = newdelta`).
                    dt = del;
                    if (dt < options.dt_min) return .{ .completed = false, .steps = steps, .t_final = t };
                    continue;
                }
                // Growth capped at 2x per accepted step, as in ngspice.
                dt_next = @min(@max(del, options.dt_min), 2.0 * dt, effective_dt_max);
            }

            // Order promotion (dctran.c:901-913): recompute the trunc at
            // order 2 and adopt min(2*dt, del2) as the next dt whether or not
            // the order changes, as ngspice's `CKTdelta = newdelta` does.
            if (steps > 0 and use_be) {
                const trial_del = integrator.stepBound(W, options.method, eff_method, lq, &i_prev, cf, lte);
                const nd2 = @min(2.0 * dt, trial_del);
                if (nd2 > 1.05 * dt) use_be = false;
                dt_next = @min(@max(nd2, options.dt_min), effective_dt_max);
                if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);
            }

            // The dynamic current under the method actually used.
            integrator.advanceCurrent(eff_method, &i_prev, q_hist[0], q_hist[1], q_hist[2], cf);

            // [cur, prev, prev2, prev3] -> [stale, cur, prev, prev2].
            std.mem.rotate([]f64, &q_hist, 3);
        }
        dt_prev2 = dt_prev;
        dt_prev = dt;

        // Rotate the slices; accepted states need no copy.
        const stale = prev;
        prev = cur;
        cur = trial;
        trial = stale;
        t += dt;
        steps += 1;
        ckt.say(cur);
        _ = ckt.stateCtl(.commit);

        // Landed on a breakpoint: drop to BE and resume at
        // 0.1*min(saveDelta, gap to the next break), spice3 dctran's rule,
        // which resolves paired edges instead of stepping over them. A step
        // that was not clamped lands too when it ends within 100 ulps of the
        // breakpoint or delmin short of it (dctran.c:559).
        if (bp_next) |bp| {
            const landed = if (bp_clamped)
                @abs(t - bp) <= min_break
            else
                (bp - t <= delmin or almostEqualUlps(t, bp, 100));
            if (landed) {
                use_be = true;
                var shrink = bp_save_dt;
                if (ckt.nextBreakpoint(t + min_break)) |nb| shrink = @min(shrink, nb - t);
                dt_next = @min(dt_next, 0.1 * shrink);
            }
            bp_next = null;
        }

        try recorder.record(t, cur);

        // Clamp dt to land on the next breakpoint, skipping those within
        // min_break of now (ngspice CKTminBreak merge).
        bp_next = ckt.nextBreakpoint(t + min_break);
        bp_clamped = false;
        if (bp_next) |bp| {
            const dt_to_bp = bp - t;
            if (dt_to_bp < dt_next) {
                bp_save_dt = dt_next;
                dt_next = dt_to_bp;
                bp_clamped = true;
            }
        }

        dt = dt_next;
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    if (cur.ptr != x.ptr) @memcpy(x[0..n], cur);
    return .{ .completed = t >= options.t_stop, .steps = steps, .t_final = t };
}

/// ngspice's AlmostEqualUlps (maths/misc/equality.c): `a` and `b` are at
/// most `max_ulps` representable doubles apart, across zero included.
fn almostEqualUlps(a: f64, b: f64, max_ulps: i64) bool {
    if (a == b) return true;
    const lex = struct {
        fn f(x: f64) i128 {
            const i: i64 = @bitCast(x);
            return if (i < 0) @as(i128, std.math.minInt(i64)) - i else i;
        }
    }.f;
    return @abs(lex(a) - lex(b)) <= max_ulps;
}

test "almostEqualUlps counts representable doubles across zero" {
    try std.testing.expect(almostEqualUlps(1.0, std.math.nextAfter(f64, 1.0, 2.0), 1));
    try std.testing.expect(!almostEqualUlps(1.0, 1.0 + 1e-12, 100));
    try std.testing.expect(almostEqualUlps(-0.0, 0.0, 0));
}
