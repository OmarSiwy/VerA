//! VAMS §8 the mixed-signal coordinator: one global time over a digital `Run`
//! and an analog solver.
//!
//! §8.4.4 describes "a single event queue logically with a common global time",
//! and §7.3.6 allows "any synchronization method ... provided the semantics
//! [are] preserved". This loop is that global time. It belongs to neither
//! engine: the digital queue is integer ticks and cannot hold a real-valued
//! analog time, and the analog solver in a testbench is generated text that
//! cannot be unit-tested without generating code. So the analog side is a
//! comptime interface `A` (see `run`), and the tests below drive the real
//! digital engine against a fake one.
//!
//! What is here is the DIGITAL-TO-ANALOG half of §8:
//!   - §7.3.6.5: the analog solve at `t` sees every digital tick <= `t`;
//!   - §8.5 / §8.4.7: an implicit D2A — a change of a value the analog block
//!     reads — forces an analog solution at the time it occurs, including off
//!     the declared grid;
//!   - §8.5.1 / §8.5.3.7: that solve is the region-3b macro-process event, so
//!     it sees the tick's nonblocking updates (region 3) and runs once per tick;
//!   - §8.4.2: the digital activity at or before the first analog time is
//!     settled before the DC solve.
//! A solution is FINISHED (printed, committed) only once the digital engine
//! has consumed every tick at or before it, so a later D2A at the same time
//! re-solves instead of adding a second point.
//!
//! And the ANALOG-TO-DIGITAL half, once a digital process waits on an analog
//! event or probes the analog solution:
//!   - §7.3.5 / §5.10.3.1: `cross`/`above` in a digital event control is
//!     monitored against every tentative solution, and a step that jumps a
//!     crossing is cut back to within the event's `time_tol` after it;
//!   - §7.3.6.1 / §8.4.3.3: the A2D is delivered at the NEAREST tick, never
//!     earlier than the current digital time, and a D2A it causes at a tick
//!     already passed is solved at the analog time of the event (Figure 8-4);
//!   - §7.3.6.3: a probe in a digital expression reads the analog solution
//!     interpolated at the promoted digital time.
//!
// ponytail: the analog never steps past the next digital event (Figure 8-7's
// conservative half), so nothing is ever rolled back (§8.4.6) and an A2D is
// delivered once, from the solution that is kept. A step the analog device
// itself would reject (an analog-context `cross`) is not cut here: only the
// monitored events cut, through the host's own re-solve.
const std = @import("std");
const digital = @import("digital/root.zig");
const Tick = digital.Tick;

pub const Options = struct {
    /// The declared analog timepoints, in seconds, ascending. `times[0]` is the
    /// DC point that opens the analysis (§8.4.2); the rest are transient
    /// points. Implicit D2A points are inserted between them.
    times: []const f64,
    /// One scheduler tick, in seconds: the design's finest time precision.
    tick: f64,
};

/// The greatest tick whose time is <= `t` (§7.3.6.5's "greatest digital time
/// tick which is less than or equal to the analog time"). A `t` within
/// rounding of a tick IS that tick: 4e-9 / 1e-9 is 3.9999999999999996 in
/// binary64, and flooring it would put the analog solve one tick early.
pub fn tickAtOrBefore(t: f64, tick: f64) Tick {
    const x = t / tick;
    const r = @round(x);
    if (@abs(x - r) <= 1e-9 * @max(1.0, @abs(r))) return @intFromFloat(@max(r, 0.0));
    return @intFromFloat(@max(@floor(x), 0.0));
}

/// Run one analysis over `opts.times`.
///
/// `A` provides these methods, each fallible:
///   setInputs(a, dig, fired)      copy the discrete inputs the analog block reads
///                                 out of `dig` (§7.3.1 Table 7-1 conversion is A's),
///                                 and raise the explicit D2A terms in `fired`
///                                 (bit = `digital.D2aSite.site`) for this solve
///   snapshot(a, dig)              region 1b (§8.5.3.6): keep, for the next
///                                 setInputs, the values the statements guarded
///                                 by an explicit D2A event read
///   solveAt(a, t, dt, first, last) a TENTATIVE solution at `t`; `first` opens the
///                                 analysis (dt = 0), `last` is its final point
///   finish(a)                     the last tentative solution is final: report it
///                                 (§9.4 strobes) and commit its state (§4.5.2)
///   probe(a, t, n1, n2)           V(n1, n2) (n2 null: V(n1)) of the tentative
///                                 solution when `t` is null, else interpolated
///                                 at `t` between the last finished solution and
///                                 the tentative one (§7.3.6.3)
/// and installs its own `digital.Run.watchAnalog` on every slot it reads,
/// which is what makes a change of one of them an implicit D2A.
pub fn run(comptime A: type, a: *A, dig: *digital.Run, opts: Options) !void {
    std.debug.assert(opts.times.len != 0);
    var s: State(A) = .{ .a = a, .dig = dig, .opts = opts, .final = opts.times[opts.times.len - 1] };
    // §7.3.5 / §7.3.6.3: a monitored analog event or a probe needs the analog
    // solution at every digital event time, so the analog steps to each one
    // before the digital engine runs it (Figure 8-7's conservative half).
    const sync = dig.monitors.items.len != 0 or dig.has_probes;
    if (sync) {
        dig.probe = State(A).probeHook;
        dig.probe_ctx = &s;
        s.mons = try dig.arena.alloc(Mon, dig.monitors.items.len);
        for (s.mons, 0..) |*m, j| {
            const name = dig.file.str(dig.file.exprs.strOf(dig.monitors.items[j].expr));
            if (std.mem.eql(u8, name, "timer")) {
                // §5.10.3.3 timer(start_time, period, ...): "at start_time,
                // and every period after that"; a period <= 0 fires once.
                // ponytail: a firing at or before the DC point is not delivered.
                const start = (try dig.monitorArg(j, 0)).?;
                m.* = .{ .dir = 0, .tol = 0, .timer = .{ .next = start, .period = (try dig.monitorArg(j, 1)) orelse 0 } };
                while (m.timer.?.next <= opts.times[0]) if (!m.advanceTimer()) break;
                continue;
            }
            if (std.mem.eql(u8, name, "absdelta")) {
                // §5.10.3.4 absdelta(expr, delta, time_tol, expr_tol, enable).
                m.* = .{ .dir = 0, .tol = 0, .absdelta = .{ .delta = @max((try dig.monitorArg(j, 1)) orelse 0, 0) } };
                continue;
            }
            const above = std.mem.eql(u8, name, "above");
            // §5.10.3.1 cross(expr, dir, time_tol, ...); §5.10.3.2 above(expr, time_tol, ...).
            const dir = if (above) 1.0 else (try dig.monitorArg(j, 1)) orelse 0.0;
            const tol = (try dig.monitorArg(j, if (above) 1 else 2)) orelse 0.0;
            m.* = .{ .dir = @intFromFloat(dir), .tol = if (tol > 0) tol else @min(default_time_tol, opts.tick / 2) };
        }
    }
    for (opts.times, 0..) |target, i| {
        const horizon = tickAtOrBefore(target, opts.tick);
        if (sync and i > 0) {
            while (s.acc.? < target) {
                var t_end = target;
                if (dig.scheduler.peekTime()) |k| if (k <= horizon) {
                    t_end = @min(t_end, s.timeOf(k, target, horizon));
                };
                // §5.10.3.3 a timer places a point at its firing time, whether
                // it is monitored here or only the device's (`nextBreakpoint`).
                for (s.mons) |m| if (m.timer) |tm| if (tm.next > s.acc.?) {
                    t_end = @min(t_end, tm.next);
                };
                if (@hasDecl(A, "breakpoint")) if (a.breakpoint(s.acc.?)) |b| if (b > s.acc.?) {
                    t_end = @min(t_end, b);
                };
                try s.step(t_end);
            }
            continue;
        }
        // Every tick up to the horizon, one at a time, so an implicit D2A at
        // tick k is solved at k's own time and not at the next declared point.
        while (dig.scheduler.peekTime()) |k| {
            if (k > horizon) break;
            while (true) {
                switch (try dig.runUntil(k)) {
                    .idle => break,
                    .explicit_d2a => {
                        try s.explicitD2a();
                        continue;
                    },
                    .analog => {},
                }
                const t = s.timeOf(k, target, horizon);
                // §8.4.2: activity before the first analog time is settled
                // into the DC point, not given solutions of its own.
                if (i == 0 and t < target) continue;
                try s.accept(t);
            }
        }
        // The declared point itself, unless a D2A at this very time already
        // solved it with the tick's final values (region 3b follows 1-3).
        if (s.acc == null or s.acc.? != target) try s.accept(target);
        // §5.10.3.4 absdelta "generates events ... During initialization".
        if (sync and i == 0) {
            var any = false;
            for (s.mons, 0..) |*m, j| if (m.absdelta) |*ad| {
                ad.last = try s.monValue(j);
                try dig.deliverA2d(j, horizon);
                any = true;
            };
            if (any) try s.runDigital(horizon);
        }
    }
    try a.finish();
}

/// §5.10.3.1 leaves an absent `time_tol` to the tool.
const default_time_tol = 1e-12;

/// One monitored analog event (`digital.Run.monitors`): its direction, its
/// time tolerance, and its value on the last final solution — or, for a
/// timer, its next firing time.
const Mon = struct {
    dir: i8,
    tol: f64,
    v0: f64 = 0,
    timer: ?struct { next: f64, period: f64 } = null,
    /// §5.10.3.4: the change that makes an event, and the value at the last one.
    absdelta: ?struct { delta: f64, last: f64 = 0 } = null,

    fn isCrossing(m: Mon) bool {
        return m.timer == null and m.absdelta == null;
    }

    /// The firing after this one, or false when there is none.
    fn advanceTimer(m: *Mon) bool {
        const tm = &m.timer.?;
        if (tm.period <= 0) {
            tm.next = std.math.inf(f64);
            return false;
        }
        tm.next += tm.period;
        return true;
    }
};

/// §5.10.3.1: "If dir is +1, the event ... only occur[s] on rising edge
/// transitions", -1 on falling ones, 0 on both, and any other value on none.
/// The same test the device's `cross` makes against its accepted value.
fn crosses(dir: i8, v0: f64, v1: f64) bool {
    const rise = v0 <= 0 and v1 > 0;
    const fall = v0 >= 0 and v1 < 0;
    return switch (dir) {
        1 => rise,
        -1 => fall,
        0 => rise or fall,
        else => false,
    };
}

fn State(comptime A: type) type {
    return struct {
        const Self = @This();
        a: *A,
        dig: *digital.Run,
        opts: Options,
        final: f64,
        /// Time of the tentative, not yet finished, solution.
        acc: ?f64 = null,
        /// Time of the last finished solution: the base of `dt`.
        prev: ?f64 = null,
        /// Explicit D2A terms (bit = site) that occurred since the last solve,
        /// and those delivered to the tentative solution at `acc`. A term is
        /// delivered to exactly one finished solution: a re-solve at the same
        /// time keeps it, the next time point drops it.
        pending: u64 = 0,
        fired: u64 = 0,
        mons: []Mon = &.{},
        /// A monitor is being evaluated: probes read the tentative solution.
        mon_eval: bool = false,

        fn timeOf(s: *const Self, k: Tick, target: f64, horizon: Tick) f64 {
            const tk = @as(f64, @floatFromInt(k)) * s.opts.tick;
            return if (k == horizon and @abs(tk - target) <= 1e-9 * @max(s.opts.tick, target)) target else tk;
        }

        /// A solution at `t`, tentative: `acc` moves, `prev` does not.
        fn solve(s: *Self, t: f64) !void {
            try s.a.setInputs(s.dig, s.fired);
            try s.a.solveAt(t, if (s.prev) |p| t - p else 0.0, s.prev == null, t == s.final);
            s.acc = t;
        }

        /// The solution at `t`: a new time finishes the tentative one first.
        fn accept(s: *Self, t: f64) !void {
            if (s.acc) |ta| if (ta != t) {
                try s.a.finish();
                s.prev = ta;
                s.fired = 0;
            };
            s.fired |= s.pending;
            s.pending = 0;
            try s.solve(t);
        }

        fn explicitD2a(s: *Self) !void {
            s.pending |= s.dig.d2a_fired;
            s.dig.d2a_fired = 0;
            try s.a.snapshot(s.dig);
        }

        fn monValue(s: *Self, j: usize) !f64 {
            s.mon_eval = true;
            defer s.mon_eval = false;
            return (try s.dig.monitorArg(j, 0)).?;
        }

        /// One analog step toward `t_end`, which lies before the next digital
        /// event: §5.10.3.1 / §8.4.7 cut it at the first monitored crossing,
        /// deliver the A2D events it carries (§7.3.6.1, rounded per §8.4.3.3),
        /// then run the digital ticks at or before the step and re-solve at
        /// it for every D2A they cause (§8.4.3.2 "accept at wake-up time").
        fn step(s: *Self, t_end: f64) !void {
            const base = s.acc.?;
            for (s.mons, 0..) |*m, j| if (m.timer == null) {
                m.v0 = try s.monValue(j);
            };
            try s.accept(t_end);
            // Secant cuts, bounded: a linear crossing is found by the first.
            var cuts: u8 = 0;
            while (cuts < 64) : (cuts += 1) {
                var cut: ?f64 = null;
                for (s.mons, 0..) |m, j| {
                    if (!m.isCrossing()) continue;
                    const v1 = try s.monValue(j);
                    if (!crosses(m.dir, m.v0, v1)) continue;
                    const tc = base + m.v0 / (m.v0 - v1) * (s.acc.? - base);
                    if (s.acc.? - tc > m.tol) cut = @min(cut orelse tc + m.tol / 2, tc + m.tol / 2);
                }
                try s.solve(cut orelse break);
            }
            const tick: Tick = @intFromFloat(@round(s.acc.? / s.opts.tick));
            for (s.mons, 0..) |*m, j| if (m.timer) |tm| {
                // Stepped to exactly, so the point IS the firing.
                if (s.acc.? + s.opts.tick * 1e-6 < tm.next) continue;
                try s.dig.deliverA2d(j, tick);
                while (m.timer.?.next <= s.acc.? + s.opts.tick * 1e-6) if (!m.advanceTimer()) break;
            } else if (m.absdelta) |*ad| {
                // §5.10.3.4 / §8.4.6: absdelta does not force a timestep; each
                // change of "more than delta, relative to the previous
                // absdelta() event" is interpolated between the step's ends.
                // ponytail: a D2A it causes is re-solved at the step's end, not
                // rolled back to the event (§8.4.6 case a); expr_tol, time_tol,
                // enable and the direction-change trigger are not read.
                const v1 = try s.monValue(j);
                if (ad.delta == 0) {
                    // "an event is generated every timestep the expression
                    // value changes".
                    if (v1 != m.v0) try s.dig.deliverA2d(j, tick);
                    ad.last = v1;
                } else while (@abs(v1 - ad.last) > ad.delta) {
                    const level = ad.last + std.math.sign(v1 - ad.last) * ad.delta;
                    const f = if (v1 != m.v0) std.math.clamp((level - m.v0) / (v1 - m.v0), 0, 1) else 1;
                    const te = base + f * (s.acc.? - base);
                    try s.dig.deliverA2d(j, @intFromFloat(@round(te / s.opts.tick)));
                    ad.last = level;
                }
            } else if (crosses(m.dir, m.v0, try s.monValue(j))) try s.dig.deliverA2d(j, tick);
            try s.runDigital(tickAtOrBefore(s.acc.?, s.opts.tick));
        }

        /// The digital ticks at or before `horizon`, re-solving at the current
        /// analog time for every D2A they cause.
        fn runDigital(s: *Self, horizon: Tick) !void {
            while (true) switch (try s.dig.runUntil(horizon)) {
                .idle => break,
                .explicit_d2a => try s.explicitD2a(),
                .analog => try s.accept(s.acc.?),
            };
        }

        fn probeHook(ctx: *anyopaque, n1: []const u8, n2: ?[]const u8) digital.Error!f64 {
            const s: *Self = @ptrCast(@alignCast(ctx));
            // §7.3.6.3 "the analog value calculated for the time corresponding
            // to a real promotion of the digital time".
            const t: ?f64 = if (s.mon_eval or s.acc == null) null else @as(f64, @floatFromInt(s.dig.scheduler.now)) * s.opts.tick;
            return s.a.probe(t, n1, n2) catch |e| s.dig.fail(0, "the analog solution has no V({s}{s}{s}): {t}", .{ n1, if (n2 != null) ", " else "", n2 orelse "", e });
        }
    };
}

// ---- tests: the real digital engine against a fake analog --------------------

const testing = std.testing;
const diag = @import("diag");

/// Reads one digital variable, and records every solve and every finish.
const Fake = struct {
    slot: u32,
    input: i64 = -1,
    fired: u64 = 0,
    snap: i64 = -1,
    slope: f64 = 0,
    t: f64 = 0,
    solves: std.ArrayList(Point) = .empty,
    points: std.ArrayList(Point) = .empty,
    gpa: std.mem.Allocator,
    const Point = struct { t: f64, dt: f64, v: i64, first: bool, last: bool, fired: u64 = 0, snap: i64 = -1 };

    pub fn setInputs(f: *Fake, dig: *digital.Run, fired: u64) !void {
        f.input = dig.values[f.slot].asInt() orelse -1;
        f.fired = fired;
    }
    pub fn snapshot(f: *Fake, dig: *digital.Run) !void {
        f.snap = dig.values[f.slot].asInt() orelse -1;
    }
    pub fn solveAt(f: *Fake, t: f64, dt: f64, first: bool, last: bool) !void {
        f.t = t;
        try f.solves.append(f.gpa, .{ .t = t, .dt = dt, .v = f.input, .first = first, .last = last, .fired = f.fired, .snap = f.snap });
    }
    /// The fake analog's one node follows `slope` volts per second.
    pub fn probe(f: *Fake, t: ?f64, _: []const u8, _: ?[]const u8) !f64 {
        return f.slope * (t orelse f.t);
    }
    pub fn finish(f: *Fake) !void {
        try f.points.append(f.gpa, f.solves.items[f.solves.items.len - 1]);
    }
};

fn drive(arena: std.mem.Allocator, source: []const u8, name: []const u8, times: []const f64) !Fake {
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena, source, .{}, &bag, &out.writer);
    const slot = dig.slotOf(name).?;
    dig.watchAnalog(slot);
    var f: Fake = .{ .slot = slot, .gpa = arena };
    try run(Fake, &f, &dig, .{ .times = times, .tick = 1e-9 });
    return f;
}

fn expectPoints(f: Fake, want: []const [2]f64) !void {
    try testing.expectEqual(want.len, f.points.items.len);
    for (want, f.points.items) |w, p| {
        try testing.expectApproxEqAbs(w[0], p.t, 1e-18);
        try testing.expectEqual(@as(i64, @intFromFloat(w[1])), p.v);
    }
}

test "tickAtOrBefore: a time within rounding of a tick is that tick" {
    try testing.expectEqual(@as(Tick, 4), tickAtOrBefore(4e-9, 1e-9));
    try testing.expectEqual(@as(Tick, 4), tickAtOrBefore(4.5e-9, 1e-9));
    try testing.expectEqual(@as(Tick, 0), tickAtOrBefore(0, 1e-9));
    try testing.expectEqual(@as(Tick, 20), tickAtOrBefore(20e-9, 1e-9));
}

test "§7.3.6.5 the solve at t reads the greatest tick <= t, not the next and not the one before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg [3:0] code;
        \\initial begin code = 4'd1; #10 code = 4'd5; #10 code = 4'd9; end
        \\endmodule
    , "code", &.{ 5e-9, 10e-9, 15e-9, 20e-9, 25e-9 });
    try expectPoints(f, &.{ .{ 5e-9, 1 }, .{ 10e-9, 5 }, .{ 15e-9, 5 }, .{ 20e-9, 9 }, .{ 25e-9, 9 } });
    // The first point is the DC point and the last carries final_step.
    try testing.expect(f.points.items[0].first and f.points.items[0].dt == 0);
    try testing.expect(f.points.items[4].last and !f.points.items[3].last);
}

test "§8.4.7 an implicit D2A off the declared grid is an analog solution of its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg v;
        \\initial begin v = 0; #4 v = 1; end
        \\endmodule
    , "v", &.{ 0, 10e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 4e-9, 1 }, .{ 10e-9, 1 } });
    try testing.expectApproxEqAbs(@as(f64, 6e-9), f.points.items[2].dt, 1e-18);
}

test "§8.5.1 the region-3b solve sees the tick's nonblocking update, once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg clk, q;
        \\initial begin clk = 0; q = 0; #4 clk = 1; end
        \\always @(posedge clk) q <= 1;
        \\endmodule
    , "q", &.{ 0, 2e-9, 4e-9, 6e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 2e-9, 0 }, .{ 4e-9, 1 }, .{ 6e-9, 1 } });
    // One solve per point: `clk` is not an input, and 3b runs once per tick.
    try testing.expectEqual(@as(usize, 4), f.solves.items.len);
}

test "§8.4.2 time-zero digital activity settles before the DC solve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg a; wire b, c;
        \\initial a = 1'b1;
        \\assign b = ~a;
        \\assign c = ~b;
        \\endmodule
    , "c", &.{0});
    try expectPoints(f, &.{.{ 0, 1 }});
}

test "digital activity before the first analog time folds into the DC point" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try drive(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m; reg [3:0] v;
        \\initial begin v = 1; #2 v = 2; #10 v = 3; end
        \\endmodule
    , "v", &.{ 5e-9, 20e-9 });
    try expectPoints(f, &.{ .{ 5e-9, 2 }, .{ 12e-9, 3 }, .{ 20e-9, 3 } });
}

test "§8.5.3.6 an explicit D2A reads region 1b's values and forces a solution at its tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\`timescale 1ns/1ns
        \\module m; reg clk; integer da;
        \\initial begin clk = 0; da = 0; #4 clk = 1; end
        \\always @(posedge clk) begin da = 3; da <= 9; end
        \\endmodule
    , .{}, &bag, &out.writer);
    // The analog block waits on `posedge clk` (site 0) and reads `da` only
    // under it: `da` is snapshotted, not watched.
    try dig.watchEvent(dig.slotOf("clk").?, .posedge, 0);
    var f: Fake = .{ .slot = dig.slotOf("da").?, .gpa = arena };
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 2e-9, 6e-9 }, .tick = 1e-9 });
    // 4 ns is a solution of its own (§8.4.7), carrying the event and da = 3
    // (after region 1, before the region-3 `da <= 9`); the next point does not
    // carry the event again.
    try testing.expectEqual(@as(usize, 4), f.points.items.len);
    const p = f.points.items[2];
    try testing.expectApproxEqAbs(@as(f64, 4e-9), p.t, 1e-18);
    try testing.expectEqual(@as(u64, 1), p.fired);
    try testing.expectEqual(@as(i64, 3), p.snap);
    try testing.expectEqual(@as(u64, 0), f.points.items[1].fired);
    try testing.expectEqual(@as(u64, 0), f.points.items[3].fired);
}

test "§8.4.3.3 A2D crossings at 5.2 ns and 7.6 ns reach ticks 5 and 8; §7.3.6.3 a probe reads the promoted tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(vi);
        \\  inout vi; electrical vi;
        \\  integer lo, hi; real at;
        \\  initial begin lo = 0; hi = 0; at = 0.0; end
        \\  always @(cross(V(vi) - 0.52, +1, 1p)) begin lo = $time; at = V(vi); end
        \\  always @(cross(V(vi) - 0.76, +1, 1p)) hi = $time;
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescale = .{ .unit = 1e-9, .precision = 1e-9 } } }, &bag, &out.writer);
    // V(vi) = 0.1 V/ns, so the crossings are at 5.2 ns and 7.6 ns.
    var f: Fake = .{ .slot = dig.slotOf("lo").?, .gpa = arena, .slope = 1e8 };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 5e-9, 6e-9, 7e-9, 8e-9, 10e-9 }, .tick = 1e-9 });
    // The step to 6 ns was cut to within time_tol after 5.2 ns.
    const cut = for (f.points.items) |p| {
        if (p.t > 5.2e-9 and p.t <= 5.2e-9 + 1e-12) break p;
    } else return error.TestExpectedCut;
    // 5.2 rounds DOWN to tick 5, which the digital engine has passed: the A2D
    // runs at once and `lo` reaches the very solution that carried it.
    try testing.expectEqual(@as(i64, 5), cut.v);
    try testing.expectEqual(@as(?i64, 8), dig.values[dig.slotOf("hi").?].asInt());
    // The probe in the same process read V(vi) at 5.0 ns, the promoted tick,
    // not at 5.2 ns where the event was detected.
    const at: f64 = @bitCast(dig.values[dig.slotOf("at").?].values()[0]);
    try testing.expectApproxEqAbs(@as(f64, 0.5), at, 1e-12);
}

test "§7.8.4 an inserted bridge's digital half runs, and the analog reads it by its §6.7 path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    // The source holds no bridge: `inserts` is the analog compile's §7.8.4
    // insertion, re-pointing u.q at the segment `y__d2a__ddiscrete.cm`.
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\discipline ddiscrete domain discrete; enddiscipline
        \\connectmodule d2a(cm, el); input cm; output el; ddiscrete cm; electrical el; reg lvl;
        \\  always @(cm) lvl = cm;
        \\endmodule
        \\module src(q); output q; ddiscrete q; reg q; initial #4 q = 1'b1; endmodule
        \\module m; electrical y; src u(y); endmodule
    , .{ .mixed = .{
        .top = "m",
        .timescale = .{ .unit = 1e-9, .precision = 1e-9 },
        .inserts = &.{.{ .path = "", .inst = "u", .port = "q", .module = "d2a", .name = "y__d2a__ddiscrete", .upper_port = "el", .lower_port = "cm" }},
    } }, &bag, &out.writer);
    var f: Fake = .{ .slot = dig.slotOf("y__d2a__ddiscrete.lvl").?, .gpa = arena };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 10e-9 }, .tick = 1e-9 });
    // x (-1) until the child's write crosses the segment into the bridge.
    try expectPoints(f, &.{ .{ 0, -1 }, .{ 4e-9, 1 }, .{ 10e-9, 1 } });
    try testing.expect(dig.slotOf("y__d2a__ddiscrete.cm") != null);
}

test "§5.10.4 / §7.3.6.1 an analog timer's `-> ev` reaches `always @(ev)` at each firing, with a point there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag = diag.Bag.init(arena);
    var out = std.Io.Writer.Allocating.init(arena);
    var dig = try digital.elaborate(arena,
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module m(p);
        \\  inout p; electrical p; event ev; integer hits;
        \\  initial hits = 0;
        \\  always @(ev) hits = hits + 1;
        \\  analog begin @(timer(5n, 10n)) -> ev; I(p) <+ 1m * hits; end
        \\endmodule
    , .{ .mixed = .{ .top = "m", .timescale = .{ .unit = 1e-9, .precision = 1e-9 } } }, &bag, &out.writer);
    var f: Fake = .{ .slot = dig.slotOf("hits").?, .gpa = arena };
    dig.watchAnalog(f.slot);
    try run(Fake, &f, &dig, .{ .times = &.{ 0, 10e-9, 20e-9 }, .tick = 1e-9 });
    try expectPoints(f, &.{ .{ 0, 0 }, .{ 5e-9, 1 }, .{ 10e-9, 1 }, .{ 15e-9, 2 }, .{ 20e-9, 2 } });
}
