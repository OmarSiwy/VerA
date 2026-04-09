//! §12.31 vpi_register_cb, §12.34 vpi_remove_cb, §12.6 vpi_get_cb_info — the
//! simulation-callback registry, and the dispatch a host drives it through.
//!
//! WHO FIRES WHAT. This file owns the registry and the three action reasons
//! a host reaches by existing (§12.31.4: cbEndOfCompile, cbStartOfSimulation,
//! cbEndOfSimulation, via `endOfCompile`/`startOfSimulation`/
//! `endOfSimulation`). The time and value-change reasons are fired by
//! `run.zig`, which drives the digital engine: it asks this file which
//! callbacks are due (`nextDue`, `fireDue`, `fireChange`) and this file calls
//! them.
//!
//! HANDLES. A callback handle is a pointer to a heap `Cb`, valid while it is a
//! key of `live` — the iterator rule from root.zig, for the same reason: the
//! pointer came from C and is not read until membership proves it is ours.
//! §12.34 "after vpi_remove_cb() is called with a handle to the callback, the
//! handle is no longer valid", so removal deletes the key FIRST. The `Cb`
//! itself outlives the key while any dispatch is on the stack (a callback may
//! remove itself, p02_07), and is freed by the next sweep at depth zero.

const std = @import("std");
const root = @import("root.zig");
const value = @import("value.zig");
const analog = @import("analog.zig");

const vpiHandle = root.vpiHandle;

// ---------------------------------------------------------------------------
// The C ABI — Figure 12-5/12-9/12-10/12-17, as vpi_user.h lays them out.
// ---------------------------------------------------------------------------

pub const Time = extern struct {
    type: c_int,
    high: c_uint,
    low: c_uint,
    real: f64,
};

pub const VecVal = extern struct { aval: c_int, bval: c_int };

pub const StrengthVal = extern struct { logic: c_int, s0: c_int, s1: c_int };

pub const Value = extern struct {
    format: c_int,
    value: extern union {
        str: [*c]u8,
        scalar: c_int,
        integer: c_int,
        real: f64,
        time: ?*Time,
        vector: [*c]VecVal,
        strength: ?*StrengthVal,
        misc: [*c]u8,
    },
};

pub const Routine = *const fn (*CbData) callconv(.c) c_int;

pub const CbData = extern struct {
    reason: c_int,
    cb_rtn: ?Routine,
    obj: vpiHandle,
    time: ?*Time,
    value: ?*Value,
    index: c_int,
    user_data: [*c]u8,
};

// s_vpi_time.type — §12.15.
pub const vpiScaledRealTime: c_int = 1;
pub const vpiSimTime: c_int = 2;
pub const vpiSuppressTime: c_int = 3;

// §12.31 reasons, Annex G numbering.
pub const cbValueChange: c_int = 1;
pub const cbForce: c_int = 3;
pub const cbRelease: c_int = 4;
pub const cbAtStartOfSimTime: c_int = 5;
pub const cbReadWriteSynch: c_int = 6;
pub const cbReadOnlySynch: c_int = 7;
pub const cbNextSimTime: c_int = 8;
pub const cbAfterDelay: c_int = 9;
pub const cbEndOfCompile: c_int = 10;
pub const cbStartOfSimulation: c_int = 11;
pub const cbEndOfSimulation: c_int = 12;

// §12.31.3 the analog reasons. Verilog-AMS names them and numbers none; the
// numbers are the ones tests/fixtures/ch12_vpi_routines/p03_vpi_analog.h
// allocated, now vpi_user.h's.
pub const acbInitialStep: c_int = 701;
pub const acbFinalStep: c_int = 702;
pub const acbAbsTime: c_int = 703;
pub const acbElapsedTime: c_int = 704;
pub const acbConvergenceTest: c_int = 705;
pub const acbAcceptedPoint: c_int = 706;

pub fn isAnalogReason(r: c_int) bool {
    return r >= acbInitialStep and r <= acbAcceptedPoint;
}

/// §11.6.25's callback object, as `vpi_get(vpiType, cb)` reports it.
pub const vpiCallback: c_int = 107;

pub const vpiSuppressVal: c_int = 13;

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

pub const Cb = struct {
    reason: c_int,
    rtn: Routine,
    obj: vpiHandle,
    user_data: [*c]u8,
    index: c_int,
    /// The registered `time->type`, or vpiSuppressTime when none was given.
    time_type: c_int,
    /// The registered time structure, COPIED: the application's may be on its
    /// stack (audit_vpi_event_handles.c registers from one).
    time: Time,
    /// The registered `value->format`, or vpiSuppressVal.
    value_format: c_int,
    /// Time reasons: the absolute tick this callback is due at.
    due: u64 = 0,
    /// cbNextSimTime: the tick it was registered at — it fires at the first
    /// time queue after this one.
    since: u64 = 0,
    /// acbAbsTime / acbElapsedTime: the analog time, in seconds, whose
    /// accepted solution it is delivered upon — and which it forces.
    due_real: f64 = 0,
    dead: bool = false,
};

const gpa = std.heap.smp_allocator;

/// Registration order, dead ones included until the next sweep.
var cbs: std.ArrayList(*Cb) = .empty;
/// The live handles.
var live: std.AutoHashMapUnmanaged(usize, *Cb) = .empty;
/// How many dispatches are on the stack; a sweep only runs at zero.
var depth: u32 = 0;

pub fn asCb(h: vpiHandle) ?*Cb {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

/// Forget every callback. `root.close()` calls this: callbacks are part of the
/// session a design was opened for.
pub fn reset() void {
    for (cbs.items) |cb| gpa.destroy(cb);
    cbs.clearAndFree(gpa);
    live.clearAndFree(gpa);
    depth = 0;
}

fn isTimeReason(r: c_int) bool {
    return switch (r) {
        cbAtStartOfSimTime, cbReadWriteSynch, cbReadOnlySynch, cbNextSimTime, cbAfterDelay => true,
        else => false,
    };
}

/// §12.31. Returns the callback handle, or NULL plus vpiError for a request
/// that cannot be kept.
pub export fn vpi_register_cb(cb_data_p: ?*const CbData) vpiHandle {
    root.clearError();
    const d = cb_data_p orelse {
        root.fail("BADCB", "vpi_register_cb: cb_data_p is NULL", .{});
        return null;
    };
    const rtn = d.cb_rtn orelse {
        root.fail("BADCB", "vpi_register_cb: cb_rtn is NULL", .{});
        return null;
    };
    var cb: Cb = .{
        .reason = d.reason,
        .rtn = rtn,
        .obj = d.obj,
        .user_data = d.user_data,
        .index = d.index,
        .time_type = if (d.time) |t| t.type else vpiSuppressTime,
        .time = if (d.time) |t| t.* else std.mem.zeroes(Time),
        .value_format = if (d.value) |v| v.format else vpiSuppressVal,
    };
    switch (d.reason) {
        // §12.31.4: "The only fields in the s_cb_data structure which need to
        // be setup for simulation action/feature callbacks are the reason,
        // cb_rtn, and user_data".
        cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation => {},
        // §12.31.1: "For force and release callbacks, if this is set to NULL,
        // every force and release shall generate a callback." A non-NULL obj
        // must be one VerA issued.
        cbForce, cbRelease => if (d.obj != null and root.asObj(d.obj) == null) {
            root.fail("BADHANDLE", "vpi_register_cb: obj is not a handle to an object", .{});
            return null;
        },
        // §12.31.1 "After value change on an expression or terminal". The
        // object must be one whose value can change in this process: a
        // digital net, reg, variable or memory word.
        cbValueChange => {
            const o = root.asObj(d.obj) orelse {
                root.fail("BADHANDLE", "vpi_register_cb: cbValueChange needs an object handle in obj", .{});
                return null;
            };
            if (o.slot == null and (o.members.len == 0 or root.design.?.objects[o.members[0]].slot == null)) {
                root.fail("NOVALUE", "vpi_register_cb: `{s}` has no simulation value that can change", .{o.full});
                return null;
            }
            value.watch(o);
        },
        cbAtStartOfSimTime, cbReadWriteSynch, cbReadOnlySynch, cbAfterDelay, cbNextSimTime => {
            // IEEE 1364-2005 27.33.2, which §12.31 defers to for the header:
            // a time callback needs a time it can deliver in. cbNextSimTime is
            // the exception — "For reason cbNextSimTime, the time structure is
            // ignored" (§12.31.2) — but it still says which FORMAT to deliver.
            if (d.reason != cbNextSimTime and (d.time == null or cb.time_type == vpiSuppressTime)) {
                root.fail("BADTIME", "vpi_register_cb: reason {d} needs a vpiSimTime or vpiScaledRealTime time", .{d.reason});
                return null;
            }
            if (cb.time_type != vpiSimTime and cb.time_type != vpiScaledRealTime and cb.time_type != vpiSuppressTime) {
                root.fail("BADTIME", "vpi_register_cb: time type {d} is not a §12.15 time type", .{cb.time_type});
                return null;
            }
            const now = root.run.now();
            cb.since = now;
            if (d.reason != cbNextSimTime) {
                const ticks = root.run.ticksOf(cb.time, d.obj) orelse return null;
                // §12.31.2: cbAtStartOfSimTime names a TIME; the others name a
                // DELAY from now ("after a specified amount of time").
                cb.due = if (d.reason == cbAtStartOfSimTime) ticks else now +| ticks;
                if (cb.due < now) {
                    root.fail("BADTIME", "vpi_register_cb: time {d} is already in the past (now {d})", .{ cb.due, now });
                    return null;
                }
            }
        },
        // §12.31.3. The four step reasons carry no time; acbAbsTime names an
        // absolute analog time and acbElapsedTime an interval "advanced from
        // the current solution" — the latest accepted one, or the start of
        // the next analysis when none is running. Both are seconds, so only
        // vpiScaledRealTime can state them.
        acbInitialStep, acbFinalStep, acbConvergenceTest, acbAcceptedPoint => {},
        acbAbsTime, acbElapsedTime => {
            const t = d.time orelse {
                root.fail("BADTIME", "vpi_register_cb: reason {d} needs a vpiScaledRealTime time", .{d.reason});
                return null;
            };
            if (t.type != vpiScaledRealTime) {
                root.fail("BADTIME", "vpi_register_cb: an analog time is in seconds; time type {d} is not vpiScaledRealTime", .{t.type});
                return null;
            }
            if (!std.math.isFinite(t.real) or t.real < 0) {
                root.fail("BADTIME", "vpi_register_cb: {e} is not a time an analysis reaches", .{t.real});
                return null;
            }
            cb.due_real = if (d.reason == acbAbsTime) t.real else analog.acceptedTime() + t.real;
        },
        else => {
            root.fail("NOREASON", "vpi_register_cb: reason {d} is not a reason VerA can deliver", .{d.reason});
            return null;
        },
    }
    const p = gpa.create(Cb) catch return oom();
    p.* = cb;
    cbs.append(gpa, p) catch {
        gpa.destroy(p);
        return oom();
    };
    live.put(gpa, @intFromPtr(p), p) catch {
        _ = cbs.pop();
        gpa.destroy(p);
        return oom();
    };
    return @ptrCast(p);
}

fn oom() vpiHandle {
    root.fail("NOMEM", "vpi_register_cb: out of memory", .{});
    return null;
}

/// §12.34 "shall return a 1 (TRUE) if successful, and a 0 (FALSE) on a
/// failure. After vpi_remove_cb() is called with a handle to the callback, the
/// handle is no longer valid."
pub export fn vpi_remove_cb(cb_obj: vpiHandle) c_int {
    root.clearError();
    const cb = asCb(cb_obj) orelse {
        root.fail("BADHANDLE", "vpi_remove_cb: {s} is not a live callback handle", .{if (cb_obj == null) "NULL" else "that handle"});
        return 0;
    };
    _ = live.remove(@intFromPtr(cb));
    cb.dead = true;
    sweep();
    return 1;
}

/// §12.6 "shall return information about a simulation-related callback in an
/// s_cb_data structure. The memory for this structure shall be allocated by
/// the user." The `time` and `value` sub-structures are the user's too when
/// they point anywhere: they are written, never replaced.
pub export fn vpi_get_cb_info(obj: vpiHandle, cb_data_p: ?*CbData) void {
    root.clearError();
    const cb = asCb(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_cb_info: {s} is not a live callback handle", .{if (obj == null) "NULL" else "that handle"});
        return;
    };
    const out = cb_data_p orelse {
        root.fail("BADCB", "vpi_get_cb_info: cb_data_p is NULL", .{});
        return;
    };
    out.reason = cb.reason;
    out.cb_rtn = cb.rtn;
    out.obj = cb.obj;
    out.index = cb.index;
    out.user_data = cb.user_data;
    if (out.time) |t| {
        t.* = cb.time;
        t.type = cb.time_type;
    }
    if (out.value) |v| v.format = cb.value_format;
}

fn sweep() void {
    if (depth != 0) return;
    var i: usize = 0;
    while (i < cbs.items.len) {
        if (cbs.items[i].dead) {
            gpa.destroy(cbs.orderedRemove(i));
        } else i += 1;
    }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Call `cb` with a FRESH s_cb_data — §12.31.1 "this is not a pointer to the
/// same structure which was passed to vpi_register_cb()" — whose time and
/// value are filled in the registered type and format. A value-change
/// callback reads its value from `from`: the array element that changed, or
/// the registered object itself.
fn call(cb: *Cb, index: c_int, from: ?*const root.Obj) c_int {
    var t: Time = std.mem.zeroes(Time);
    const override = cb.reason == cbForce or cb.reason == cbRelease;
    var data: CbData = .{
        .reason = cb.reason,
        .cb_rtn = cb.rtn,
        .obj = if (override) @ptrCast(@constCast(from.?)) else cb.obj,
        .time = null,
        .value = null,
        .index = index,
        .user_data = cb.user_data,
    };
    if (isAnalogReason(cb.reason)) {
        // §12.31.3's time is the analog clock's, in seconds.
        if (cb.time_type != vpiSuppressTime) {
            t = cb.time;
            t.type = vpiScaledRealTime;
            t.real = analog.time();
            data.time = &t;
        }
    } else if (cb.time_type != vpiSuppressTime) {
        t.type = cb.time_type;
        root.run.timeNow(cb.obj, &t);
        data.time = &t;
    }
    var v: Value = std.mem.zeroes(Value);
    if ((cb.reason == cbValueChange or override) and cb.value_format != vpiSuppressVal) {
        v.format = cb.value_format;
        value.read(from orelse root.asObj(cb.obj).?, &v, &value.cb_store);
        data.value = &v;
    }
    depth += 1;
    defer depth -= 1;
    return cb.rtn(&data);
}

/// Every live callback of `reason`, in registration order. Only the ones
/// registered BEFORE this dispatch began: a callback registered from inside
/// one is for a later occurrence (p02_07's heir must not see the change whose
/// dispatch registered it).
fn fireAll(reason: c_int) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (!cb.dead and cb.reason == reason) _ = call(cb, cb.index, null);
    }
    sweep();
}

/// §12.31.4 cbEndOfCompile — "End of simulation data structure compilation
/// or build": after the design is elaborated and the startup routines ran.
pub fn endOfCompile() void {
    // The build's last step before it is "end": the registered systfs'
    // compiletf/sizetf/derivtf at each call site (§12.32.1, §12.33.1).
    @import("systf.zig").buildCalls();
    fireAll(cbEndOfCompile);
}

/// §12.31.4 cbStartOfSimulation — "beginning of time 0 simulation cycle".
pub fn startOfSimulation() void {
    fireAll(cbStartOfSimulation);
}

/// §12.31.4 cbEndOfSimulation — "e.g., $finish system task executed".
pub fn endOfSimulation() void {
    fireAll(cbEndOfSimulation);
}

/// The earliest tick a live time callback is due at that is strictly after
/// `after` — or AT it when `inclusive` — or null.
pub fn nextDue(after: u64, inclusive: bool) ?u64 {
    var best: ?u64 = null;
    for (cbs.items) |cb| {
        if (cb.dead or !isTimeReason(cb.reason) or cb.reason == cbNextSimTime) continue;
        if (cb.due < after or (!inclusive and cb.due == after)) continue;
        if (best == null or cb.due < best.?) best = cb.due;
    }
    return best;
}

/// Every pending time a time callback holds, for §11.6.25's vpiTimeQueue.
pub fn pendingTimes(out: *std.ArrayList(u64), a: std.mem.Allocator) !void {
    for (cbs.items) |cb| {
        if (cb.dead or !isTimeReason(cb.reason) or cb.reason == cbNextSimTime) continue;
        try out.append(a, cb.due);
    }
}

/// Fire the callbacks of `reason` due at `now`, each at most once: a time
/// callback is one-shot (§12.31.2 "shall occur ... a specified time"), so it
/// is removed as it fires and its handle stops being valid.
pub fn fireDue(reason: c_int, now: u64) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != reason or cb.due != now) continue;
        retire(cb);
        _ = call(cb, cb.index, null);
    }
    sweep();
}

/// §12.31.2 cbNextSimTime: "before execution of events in the next event
/// queue" — the first time queue after the one it was registered in.
pub fn fireNext(now: u64) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != cbNextSimTime or now <= cb.since) continue;
        retire(cb);
        _ = call(cb, cb.index, null);
    }
    sweep();
}

/// §12.31.1 cbValueChange for every callback watching the object stored in
/// `slot`, which the engine just changed.
pub fn fireSlot(slot: u32) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != cbValueChange) continue;
        const target = root.asObj(cb.obj) orelse continue;
        if (target.slot == slot) {
            _ = call(cb, cb.index, null);
            continue;
        }
        // §12.31.1: a callback on an array hears each element's change, with
        // that element's value and "the index of the memory word or variable
        // select which changed value".
        const d = &root.design.?;
        for (target.members) |m| {
            const word = &d.objects[m];
            if (word.slot != slot) continue;
            _ = call(cb, @intCast(d.objects[word.index.?].value.?.int), word);
        }
    }
    sweep();
}

/// §12.31.1 cbForce/cbRelease after `o` was forced or released: every
/// callback registered on `o`, and every one registered with a NULL obj.
/// "the object returned in the obj field shall be a handle to the force,
/// release ... statement"; a vpi_put_value force has no statement, so obj is
/// the object it forced. The value is `o`'s, after the force or release.
/// ponytail: only vpi_put_value's forces fire this. A procedural `force`
/// statement has no §11.6 statement object here for obj to name; hook the
/// engine's `.override_on`/`.override_off` when one exists.
pub fn fireOverride(reason: c_int, o: *root.Obj) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != reason) continue;
        if (cb.obj != null and root.asObj(cb.obj) != o) continue;
        _ = call(cb, cb.index, o);
    }
    sweep();
}

// ---------------------------------------------------------------------------
// §12.31.3 analog dispatch — driven by `analog.zig`'s time walk.
// ---------------------------------------------------------------------------

/// acbInitialStep, acbFinalStep or acbAcceptedPoint: every live callback of
/// `reason` registered before this dispatch began. These persist: §12.31.3
/// ties them to a kind of solution, not to one.
pub fn fireAnalog(reason: c_int) void {
    fireAll(reason);
}

/// acbConvergenceTest, "prior acceptance of the analog solution for the
/// given time (this callback allows rejection of the analog solution at that
/// time and backup to an earlier time)". Every callback runs; the solution
/// is rejected if ANY returned non-zero.
///
/// IMPLEMENTATION-DEFINED, and documented here and in p03_SPEC.md: the LRM
/// types `cb_rtn` as returning `int` and gives this reason the power to
/// reject without spelling the encoding. 0 accepts, as 0 is the uneventful
/// return of every other callback; anything else rejects.
pub fn convergenceRejected() bool {
    var rejected = false;
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != acbConvergenceTest) continue;
        if (call(cb, cb.index, null) != 0) rejected = true;
    }
    sweep();
    return rejected;
}

/// acbAbsTime / acbElapsedTime due upon the solution accepted at `t`: each
/// is delivered once and then retired — AFTER its routine returns, so a
/// routine that removes itself is removing a live callback (§12.34 returns 1
/// for it, p03_04).
pub fn fireTimed(t: f64) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or (cb.reason != acbAbsTime and cb.reason != acbElapsedTime)) continue;
        if (!analog.sameTime(cb.due_real, t)) continue;
        _ = call(cb, cb.index, null);
        if (!cb.dead) retire(cb);
    }
    sweep();
}

/// The earliest acbAbsTime/acbElapsedTime instant strictly after `after`
/// and at most `until`: the next solution §12.31.3 says "shall" be forced.
pub fn nextForced(after: f64, until: f64) ?f64 {
    var best: ?f64 = null;
    for (cbs.items) |cb| {
        if (cb.dead or (cb.reason != acbAbsTime and cb.reason != acbElapsedTime)) continue;
        if (cb.due_real <= after or analog.sameTime(cb.due_real, after) or cb.due_real > until) continue;
        if (best == null or cb.due_real < best.?) best = cb.due_real;
    }
    return best;
}

fn retire(cb: *Cb) void {
    _ = live.remove(@intFromPtr(cb));
    cb.dead = true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

var order: [8]u8 = undefined;
var order_len: usize = 0;

fn note(c: u8) void {
    order[order_len] = c;
    order_len += 1;
}

fn onCompile(d: *CbData) callconv(.c) c_int {
    std.debug.assert(d.reason == cbEndOfCompile);
    note('C');
    return 0;
}
fn onStart(_: *CbData) callconv(.c) c_int {
    note('S');
    return 0;
}
fn onEnd(d: *CbData) callconv(.c) c_int {
    note(if (d.user_data != null) d.user_data[0] else 'E');
    return 0;
}

var self_handle: vpiHandle = null;
fn removeSelf(_: *CbData) callconv(.c) c_int {
    note('R');
    std.debug.assert(vpi_remove_cb(self_handle) == 1);
    return 0;
}

test "§12.31.4: action callbacks fire once each, in registration order, with user_data" {
    reset();
    defer reset();
    order_len = 0;
    var tag = "X".*;
    const regs = [_]CbData{
        .{ .reason = cbEndOfSimulation, .cb_rtn = onEnd, .obj = null, .time = null, .value = null, .index = 0, .user_data = &tag },
        .{ .reason = cbEndOfCompile, .cb_rtn = onCompile, .obj = null, .time = null, .value = null, .index = 0, .user_data = null },
        .{ .reason = cbStartOfSimulation, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null },
    };
    for (&regs) |*r| try std.testing.expect(vpi_register_cb(r) != null);
    endOfCompile();
    startOfSimulation();
    endOfSimulation();
    try std.testing.expectEqualStrings("CSX", order[0..order_len]);
}

test "§12.34/§12.6: removal invalidates the handle, and info round-trips" {
    reset();
    defer reset();
    var tag = "u".*;
    var t: Time = .{ .type = vpiSimTime, .high = 0, .low = 0, .real = 0 };
    const reg: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = onCompile, .obj = null, .time = &t, .value = null, .index = 3, .user_data = &tag };
    const h = vpi_register_cb(&reg);
    try std.testing.expect(h != null);
    // §12.31.1: the registration is COPIED — changing the caller's struct
    // afterwards changes nothing.
    t.type = vpiScaledRealTime;

    var it: Time = .{ .type = vpiSuppressTime, .high = 9, .low = 9, .real = 9 };
    var iv: Value = std.mem.zeroes(Value);
    iv.format = 99;
    var info: CbData = .{ .reason = 0, .cb_rtn = null, .obj = null, .time = &it, .value = &iv, .index = 0, .user_data = null };
    vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(cbEndOfCompile, info.reason);
    try std.testing.expect(info.cb_rtn == @as(?Routine, onCompile));
    try std.testing.expectEqual(@as(c_int, 3), info.index);
    try std.testing.expect(info.user_data == @as([*c]u8, &tag));
    try std.testing.expectEqual(vpiSimTime, it.type);
    try std.testing.expectEqual(vpiSuppressVal, iv.format);

    try std.testing.expectEqual(@as(c_int, 1), vpi_remove_cb(h));
    try std.testing.expectEqual(@as(c_int, 0), vpi_remove_cb(h));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

test "a callback may remove itself during its own dispatch" {
    reset();
    defer reset();
    order_len = 0;
    const reg: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = removeSelf, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    self_handle = vpi_register_cb(&reg);
    endOfCompile();
    endOfCompile();
    try std.testing.expectEqualStrings("R", order[0..order_len]);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

test "registrations VerA cannot keep are refused with vpiError" {
    reset();
    defer reset();
    // No routine.
    const none: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = null, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&none) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // A time reason with no time, and with vpiSuppressTime (IEEE 1364 27.33.2).
    var t: Time = .{ .type = vpiSuppressTime, .high = 0, .low = 5, .real = 0 };
    var bad: CbData = .{ .reason = cbAfterDelay, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&bad) == null);
    bad.time = &t;
    try std.testing.expect(vpi_register_cb(&bad) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // A value change on something that is not an object.
    var junk: u32 = 0;
    const vc: CbData = .{ .reason = cbValueChange, .cb_rtn = onStart, .obj = @ptrCast(&junk), .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&vc) == null);
    // A reason with no number VerA delivers (cbStmt, 2).
    const stmt: CbData = .{ .reason = 2, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&stmt) == null);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}
