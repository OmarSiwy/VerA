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
// ponytail: no A2D yet — no analog-event monitors, no step rejection, no
// rollback (§8.4.6). Those need `A` to report crossings and to restore a
// checkpoint; they are steps 7-9 of the ch07 plan and extend this loop, not
// replace it.
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
/// `A` provides four methods, each fallible:
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
/// and installs its own `digital.Run.watchAnalog` on every slot it reads,
/// which is what makes a change of one of them an implicit D2A.
pub fn run(comptime A: type, a: *A, dig: *digital.Run, opts: Options) !void {
    std.debug.assert(opts.times.len != 0);
    var s: State(A) = .{ .a = a, .dig = dig, .final = opts.times[opts.times.len - 1] };
    for (opts.times, 0..) |target, i| {
        const horizon = tickAtOrBefore(target, opts.tick);
        // Every tick up to the horizon, one at a time, so an implicit D2A at
        // tick k is solved at k's own time and not at the next declared point.
        while (dig.scheduler.peekTime()) |k| {
            if (k > horizon) break;
            while (true) {
                switch (try dig.runUntil(k)) {
                    .idle => break,
                    // §8.5.3.6: the guarded reads take region 1b's values; the
                    // tick's region-3b stop, which the engine has already
                    // queued, solves with the fired terms.
                    .explicit_d2a => {
                        s.pending |= dig.d2a_fired;
                        dig.d2a_fired = 0;
                        try a.snapshot(dig);
                        continue;
                    },
                    .analog => {},
                }
                const tk = @as(f64, @floatFromInt(k)) * opts.tick;
                const t = if (k == horizon and @abs(tk - target) <= 1e-9 * @max(opts.tick, target)) target else tk;
                // §8.4.2: activity before the first analog time is settled
                // into the DC point, not given solutions of its own.
                if (i == 0 and t < target) continue;
                try s.accept(t);
            }
        }
        // The declared point itself, unless a D2A at this very time already
        // solved it with the tick's final values (region 3b follows 1-3).
        if (s.acc == null or s.acc.? != target) try s.accept(target);
    }
    try a.finish();
}

fn State(comptime A: type) type {
    return struct {
        a: *A,
        dig: *digital.Run,
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

        fn accept(s: *@This(), t: f64) !void {
            if (s.acc) |ta| if (ta != t) {
                try s.a.finish();
                s.prev = ta;
                s.fired = 0;
            };
            s.fired |= s.pending;
            s.pending = 0;
            try s.a.setInputs(s.dig, s.fired);
            try s.a.solveAt(t, if (s.prev) |p| t - p else 0.0, s.prev == null, t == s.final);
            s.acc = t;
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
        try f.solves.append(f.gpa, .{ .t = t, .dt = dt, .v = f.input, .first = first, .last = last, .fired = f.fired, .snap = f.snap });
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
