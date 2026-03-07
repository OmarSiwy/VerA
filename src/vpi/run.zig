//! The simulation a VPI application's time callbacks run inside: the digital
//! engine (`src/sim/digital`), driven one time queue at a time.
//!
//! IEEE 1364 §11.4's loop is the engine's `runUntil`. What §12.31.2 adds is a
//! set of moments INSIDE that loop an application can be called at, and this
//! file is the loop with those moments cut into it:
//!
//!   for each time t that holds an event or a time callback, in order:
//!     cbNextSimTime                  "before execution of events in the next
//!                                     event queue"
//!     cbAtStartOfSimTime, cbAfterDelay
//!                                    "before execution of events in a
//!                                     specified time queue" — even an empty one
//!     every event at t               `runUntil(t)`
//!     cbReadWriteSynch               "after execution of events", and what it
//!                                     schedules at t runs before the next step
//!     cbReadOnlySynch                the same, with writes refused
//!
//! §12.31.2 "A callback can be set for any time, even if no event is present",
//! so a callback's time is a time the loop visits whether or not the engine
//! has anything there — the clock is advanced to it explicitly.
//!
//! THE CLOCK is `now`, in engine ticks (the global precision). Before `attach`
//! and after the run it holds its last value, so `vpi_get_time` in a
//! cbEndOfSimulation reads the time the run ended at.

const std = @import("std");
const sim = @import("sim");
const root = @import("root.zig");
const callback = @import("callback.zig");

const digital = sim.digital;
const Time = callback.Time;
const vpiHandle = root.vpiHandle;

var engine: ?*digital.Run = null;
var clock: u64 = 0;

pub fn now() u64 {
    return clock;
}

/// Bind the engine an `openDigital` model was built over. Time 0: nothing has
/// dispatched yet, and §12.31.4's cbStartOfSimulation is "beginning of time 0".
pub fn attach(r: *digital.Run) void {
    engine = r;
    clock = r.scheduler.now;
}

pub fn detach() void {
    engine = null;
    clock = 0;
    var it = queues.valueIterator();
    while (it.next()) |q| gpa.destroy(q.*);
    queues.clearAndFree(gpa);
    queue_live.clearAndFree(gpa);
}

pub fn attached() ?*digital.Run {
    return engine;
}

/// Run the attached design to completion — `$finish`, an empty queue, or a
/// finish an application requested — firing every callback on the way, then
/// §12.31.4's cbEndOfSimulation.
pub fn simulate() digital.Error!void {
    const r = engine orelse return;
    callback.startOfSimulation();
    while (!stopped(r)) {
        const ev = r.scheduler.peekTime();
        const due = callback.nextDue(clock, true);
        const t = earliest(ev, due) orelse break;
        if (t > clock) {
            // Every event at or before `clock` has run and the next is at `t`,
            // so moving the clock to `t` skips nothing. The engine's own clock
            // moves with it: a delay an application schedules from a
            // start-of-time callback counts from `t`, not from the last queue.
            clock = t;
            r.scheduler.now = t;
            callback.fireNext(t);
        }
        callback.fireDue(callback.cbAtStartOfSimTime, t);
        callback.fireDue(callback.cbAfterDelay, t);
        if (stopped(r)) break;
        _ = try r.runUntil(t);
        // A read-write callback may schedule more work at `t`; it runs before
        // the time is left, and a second read-write pass sees its effect.
        while (!stopped(r)) {
            callback.fireDue(callback.cbReadWriteSynch, t);
            if (r.scheduler.peekTime() != t) break;
            _ = try r.runUntil(t);
        }
        if (stopped(r)) break;
        read_only = true;
        callback.fireDue(callback.cbReadOnlySynch, t);
        read_only = false;
        // A time holding only callbacks that all fired, with nothing after,
        // ends the loop at the top; one holding nothing new would spin.
        if (r.scheduler.peekTime() == t) continue;
        if (callback.nextDue(t, false) == null and r.scheduler.peekTime() == null) break;
    }
    callback.endOfSimulation();
}

/// True inside a cbReadOnlySynch dispatch, where §12.31.2 forbids "writing
/// values or scheduling events".
pub var read_only: bool = false;

fn stopped(r: *digital.Run) bool {
    return r.scheduler.phase == .stopped;
}

fn earliest(a: ?u64, b: ?u64) ?u64 {
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

/// The design's timescale, when it declared one: engine ticks per time unit.
fn scale() ?sim.time.Scale {
    const r = engine orelse return null;
    return r.scale;
}

/// A §12.15 time structure as engine ticks. vpiSimTime is ticks already.
/// vpiScaledRealTime is in the time unit of `obj`'s module — "the indicated
/// time shall be in the timescale associated with the object" (§12.30) — or,
/// with no object, in "the simulation time unit" (§12.15), which is a tick.
/// Null, with the error recorded, when the value is not a time.
pub fn ticksOf(t: Time, obj: vpiHandle) ?u64 {
    if (t.type == callback.vpiSimTime) return (@as(u64, t.high) << 32) | t.low;
    if (!std.math.isFinite(t.real) or t.real < 0) {
        root.fail("BADTIME", "{d} is not a time", .{t.real});
        return null;
    }
    if (obj != null) if (scale()) |s| return s.realDelay(t.real) catch {
        root.fail("BADTIME", "{d} cannot be represented in engine ticks", .{t.real});
        return null;
    };
    return @intFromFloat(@round(t.real));
}

/// Fill `t` with the current time in the format `t.type` names: §12.15
/// "using the time scale of the object. If obj is NULL, the simulation time is
/// retrieved using the simulation time unit."
pub fn timeNow(obj: vpiHandle, t: *Time) void {
    fillTime(clock, obj, t);
}

pub fn fillTime(ticks: u64, obj: vpiHandle, t: *Time) void {
    t.high = @truncate(ticks >> 32);
    t.low = @truncate(ticks);
    t.real = if (obj != null and scale() != null) scale().?.realAt(ticks) else @floatFromInt(ticks);
}

// ---------------------------------------------------------------------------
// §12.15 vpi_get_time
// ---------------------------------------------------------------------------

pub const vpiTimeQueue: c_int = 64;

/// "shall retrieve the current simulation time, using the time scale of the
/// object. If obj is NULL, the simulation time is retrieved using the
/// simulation time unit." A §11.6.25 time queue answers ITS time — which is
/// how an application reads the pending times it iterated.
pub export fn vpi_get_time(obj: vpiHandle, time_p: ?*Time) void {
    root.clearError();
    const t = time_p orelse {
        root.fail("BADTIME", "vpi_get_time: time_p is NULL", .{});
        return;
    };
    if (t.type != callback.vpiSimTime and t.type != callback.vpiScaledRealTime) {
        root.fail("BADTIME", "vpi_get_time: time type {d} is neither vpiSimTime nor vpiScaledRealTime", .{t.type});
        return;
    }
    if (obj == null) return fillTime(clock, null, t);
    if (asQueue(obj)) |q| return fillTime(q.time, null, t);
    _ = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_time: that handle is not an object", .{});
        return;
    };
    fillTime(clock, obj, t);
}

// ---------------------------------------------------------------------------
// §12.36 vpi_sim_control
// ---------------------------------------------------------------------------

pub const vpiStop: c_int = 66;
pub const vpiFinish: c_int = 67;
pub const vpiReset: c_int = 68;
pub const vpiSetInteractiveScope: c_int = 69;

/// "shall return 1 (true) if successful; 0 (false) on a failure".
///
/// vpiFinish — "cause $finish built-in Verilog system task to be executed upon
/// return of user function". The engine is told to finish now, which is the
/// same thing from where a user function sits: a callback runs between two
/// dispatches (or inside a store, which completes), nothing further is
/// dispatched, and the loop above ends the run and fires cbEndOfSimulation at
/// the time the request was made. The diagnostic-level argument is read and
/// not printed.
///
/// ponytail: vpiStop, vpiReset and vpiSetInteractiveScope all need an
/// interactive mode or a restartable run, and VerA's engine has neither, so
/// they fail with vpiError rather than pretending. The VAMS analog controls
/// (vpiRejectTransientStep, vpiTransientFailConverge) need an analog solver
/// in this process, which there is not.
pub export fn vpi_sim_control(operation: c_int, ...) callconv(.c) c_int {
    root.clearError();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    switch (operation) {
        vpiFinish => {
            _ = @cVaArg(&ap, c_int); // the diagnostic level, as $finish(n)
            const r = engine orelse {
                root.fail("NORUN", "vpi_sim_control(vpiFinish): no simulation is running", .{});
                return 0;
            };
            r.scheduler.finish();
            return 1;
        },
        vpiStop, vpiReset, vpiSetInteractiveScope => {
            root.fail("NOCONTROL", "vpi_sim_control: operation {d} needs an interactive mode VerA does not have", .{operation});
            return 0;
        },
        else => {
            root.fail("NOCONTROL", "vpi_sim_control: {d} is not a §12.36 operation", .{operation});
            return 0;
        },
    }
}

// ---------------------------------------------------------------------------
// §11.6.25 time queues
// ---------------------------------------------------------------------------

/// One pending time. Interned per time, so two iterations hand out the same
/// handle for the same queue and vpi_compare_objects can say so.
pub const Queue = struct { time: u64 };

const gpa = std.heap.smp_allocator;
var queues: std.AutoHashMapUnmanaged(u64, *Queue) = .empty;
var queue_live: std.AutoHashMapUnmanaged(usize, *Queue) = .empty;

pub fn asQueue(h: vpiHandle) ?*Queue {
    const p = h orelse return null;
    return queue_live.get(@intFromPtr(p));
}

/// §11.6.25 NOTE 3: the pending time queues, in strictly increasing time. A
/// time queue exists wherever the simulation must stop: an event, or a time
/// callback — the data model gives a callback a one-to-one `vpiParent`
/// relationship to its time queue, and §12.31.2 has the loop wake at a
/// callback's time "even if no event is present". cbNextSimTime holds no
/// time of its own ("the time structure is ignored"). Caller owns the slice.
pub fn timeQueues(a: std.mem.Allocator) ![]root.vpiHandle {
    var times: std.ArrayList(u64) = .empty;
    defer times.deinit(a);
    if (engine) |r| try r.scheduler.pendingTimes(a, &times);
    try callback.pendingTimes(&times, a);
    std.mem.sort(u64, times.items, {}, std.sort.asc(u64));
    var out: std.ArrayList(root.vpiHandle) = .empty;
    errdefer out.deinit(a);
    var last: ?u64 = null;
    for (times.items) |t| {
        if (t < clock or (last != null and last.? == t)) continue;
        last = t;
        const entry = try queues.getOrPut(gpa, t);
        if (!entry.found_existing) {
            const q = gpa.create(Queue) catch |e| {
                _ = queues.remove(t);
                return e;
            };
            q.* = .{ .time = t };
            entry.value_ptr.* = q;
            try queue_live.put(gpa, @intFromPtr(q), q);
        }
        try out.append(a, @ptrCast(entry.value_ptr.*));
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests: a real digital run, driven through the loop above.
// ---------------------------------------------------------------------------

pub const Harness = struct {
    arena: std.heap.ArenaAllocator,
    bag: @import("vera").diag.Bag,
    out: std.Io.Writer.Allocating,
    run: digital.Run,

    pub fn init(h: *Harness, source: []const u8) !void {
        h.arena = .init(std.testing.allocator);
        errdefer h.arena.deinit();
        h.bag = .init(h.arena.allocator());
        h.out = .init(h.arena.allocator());
        h.run = try digital.elaborate(h.arena.allocator(), source, .{}, &h.bag, &h.out.writer);
        try root.openDigital(std.testing.allocator, &h.run);
    }

    pub fn deinit(h: *Harness) void {
        root.close();
        h.arena.deinit();
    }
};

const timeline =
    \\`timescale 1ns/1ns
    \\module t;
    \\  reg [7:0] s;
    \\  integer k;
    \\  initial begin
    \\    s = 8'h01; k = 3;
    \\    #7 s = 8'h42;
    \\    #3 $display("done");
    \\  end
    \\endmodule
;

var seen: [16]u64 = undefined;
var seen_n: usize = 0;

fn record(d: *callback.CbData) callconv(.c) c_int {
    seen[seen_n] = (@as(u64, d.time.?.high) << 32) | d.time.?.low;
    seen_n += 1;
    return 0;
}

fn register(reason: c_int, low: u32) !void {
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = low, .real = 0 };
    const d: callback.CbData = .{ .reason = reason, .cb_rtn = record, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    if (callback.vpi_register_cb(&d) == null) return error.TestUnexpectedResult;
}

test "the digital model: one scope per instance, every declaration bound to its slot" {
    var h: Harness = undefined;
    try h.init(
        \\module top;
        \\  reg [3:0] a;
        \\  wire w;
        \\  integer n;
        \\  leaf u();
        \\endmodule
        \\module leaf;
        \\  reg q;
        \\endmodule
    );
    defer h.deinit();
    const d = &root.design.?;
    try std.testing.expectEqual(@as(usize, 2), d.scopes.len);
    try std.testing.expectEqualStrings("leaf", d.scopes[1].def_name);
    const a = root.asObj(root.vpi_handle_by_name("top.a", null)).?;
    try std.testing.expectEqual(@as(u32, 4), a.size);
    try std.testing.expectEqual(h.run.slotOf("a").?, a.slot.?);
    try std.testing.expect(root.asObj(root.vpi_handle_by_name("top.w", null)).?.kind == .net);
    try std.testing.expectEqual(root.vpiIntegerVar, root.vpi_get(root.vpiType, root.vpi_handle_by_name("top.n", null)));
    try std.testing.expect(root.vpi_handle_by_name("top.u.q", null) != null);
}

test "§12.31.2: time callbacks fire at their times, eventless ones included, before and after the queue" {
    var h: Harness = undefined;
    try h.init(timeline);
    defer h.deinit();
    seen_n = 0;
    try register(callback.cbAtStartOfSimTime, 7);
    try register(callback.cbReadOnlySynch, 7);
    // No design event at 5: "A callback can be set for any time, even if no
    // event is present."
    try register(callback.cbAfterDelay, 5);
    try simulate();
    try std.testing.expectEqualSlices(u64, &.{ 5, 7, 7 }, seen[0..seen_n]);
    try std.testing.expectEqual(@as(u64, 10), now());
    try std.testing.expectEqualStrings("done\n", h.out.written());
}

var walked: [8]u64 = undefined;
var walked_n: usize = 0;

fn walk(_: *callback.CbData) callconv(.c) c_int {
    const itr = root.vpi_iterate(vpiTimeQueue, null);
    while (root.vpi_scan(itr)) |q| {
        var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 0, .real = 0 };
        vpi_get_time(q, &t);
        walked[walked_n] = t.low;
        walked_n += 1;
    }
    return 0;
}

test "§12.15/§11.6.25: vpi_get_time scales by the object, and the time queues are the pending times" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1us/1ns
        \\module q;
        \\  reg r;
        \\  initial begin r = 0; #2 r = 1; #3 r = 0; end
        \\endmodule
    );
    defer h.deinit();
    walked_n = 0;
    // At t=1us (1000 ticks at the 1 ns precision), from a start-of-time
    // callback: the design waits at 2us — its 5us step does not exist until
    // the 2us one runs — and a callback of this test's own waits at 7us.
    var t1: Time = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 1.0 };
    const top = root.vpi_handle_by_name("q", null);
    const at1: callback.CbData = .{ .reason = callback.cbAtStartOfSimTime, .cb_rtn = walk, .obj = top, .time = &t1, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&at1) != null);
    try register(callback.cbAtStartOfSimTime, 7000);
    seen_n = 0;
    try simulate();
    try std.testing.expectEqualSlices(u64, &.{ 2000, 7000 }, walked[0..walked_n]);

    // After the run: 7000 ticks. In the module's 1 us unit that is 7.0; with
    // no object it is "the simulation time unit", the tick.
    var t: Time = .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = 0 };
    vpi_get_time(top, &t);
    try std.testing.expectEqual(@as(f64, 7.0), t.real);
    vpi_get_time(null, &t);
    try std.testing.expectEqual(@as(f64, 7000.0), t.real);
    t.type = callback.vpiSimTime;
    vpi_get_time(null, &t);
    try std.testing.expectEqual(@as(c_uint, 7000), t.low);
    // A time with no type VerA reads, and a handle that is not an object.
    t.type = callback.vpiSuppressTime;
    vpi_get_time(null, &t);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    var junk: u32 = 0;
    t.type = callback.vpiSimTime;
    vpi_get_time(@ptrCast(&junk), &t);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

var finish_seen: u64 = 0;
var end_seen: u64 = std.math.maxInt(u64);

fn finishNow(_: *callback.CbData) callconv(.c) c_int {
    finish_seen = now();
    if (vpi_sim_control(vpiFinish, @as(c_int, 0)) != 1) finish_seen = 999;
    return 0;
}

fn atEnd(_: *callback.CbData) callconv(.c) c_int {
    end_seen = now();
    return 0;
}

test "§12.36: vpiFinish from a callback ends the run at that time, and the design does no more" {
    var h: Harness = undefined;
    try h.init(timeline);
    defer h.deinit();
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 8, .real = 0 };
    const fin: callback.CbData = .{ .reason = callback.cbAtStartOfSimTime, .cb_rtn = finishNow, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&fin) != null);
    const end: callback.CbData = .{ .reason = callback.cbEndOfSimulation, .cb_rtn = atEnd, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(callback.vpi_register_cb(&end) != null);
    seen_n = 0;
    try simulate();
    try std.testing.expectEqual(@as(u64, 8), finish_seen);
    try std.testing.expectEqual(@as(u64, 8), end_seen);
    // The design's `#3 $display("done")` at t=10 never ran.
    try std.testing.expectEqualStrings("", h.out.written());

    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(vpiStop, @as(c_int, 0)));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_sim_control(12345));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}
