//! §12.16 vpi_get_value and §12.30 vpi_put_value, and cbValueChange's
//! delivery — values in every Table 12-4 format.
//!
//! WHERE A VALUE COMES FROM. Two places, and an object has at most one:
//!   - a DIGITAL object (`Obj.slot`) reads `digital.Run.values[slot]`, the
//!     engine's own four-state storage. Its two bit planes ARE Figure 12-10's
//!     aval/bval (frontend/integer.zig: value, unknown = 00/10/11/01 for
//!     0/1/X/Z), so every format here is a reading of those planes and nothing
//!     is converted between state encodings.
//!   - an ANALOG parameter (`Obj.value`) reads the constant lowering folded
//!     for it (`Lowered.consts`) — the one value an analog compile knows without
//!     running the device. Node and branch values live in a compiled device
//!     this process does not run, and are not answered.
//!
//! WRITES go through the engine's own write path (`exec.store` now,
//! `exec.enqueue` of a `.write` later), so a put wakes processes waiting on the
//! object and fires value-change callbacks exactly as a procedural assignment
//! does.

const std = @import("std");
const sim = @import("sim");
const Int = @import("frontend").Integer;
const root = @import("root.zig");
const callback = @import("callback.zig");
const run = @import("run.zig");

const digital = sim.digital;
const exec = digital.exec;
const Obj = root.Obj;
const Value = callback.Value;
const VecVal = callback.VecVal;
const Time = callback.Time;
const vpiHandle = root.vpiHandle;

// Table 12-4 formats, Annex G numbering.
pub const vpiBinStrVal: c_int = 1;
pub const vpiOctStrVal: c_int = 2;
pub const vpiDecStrVal: c_int = 3;
pub const vpiHexStrVal: c_int = 4;
pub const vpiScalarVal: c_int = 5;
pub const vpiIntVal: c_int = 6;
pub const vpiRealVal: c_int = 7;
pub const vpiStringVal: c_int = 8;
pub const vpiVectorVal: c_int = 9;
pub const vpiStrengthVal: c_int = 10;
pub const vpiTimeVal: c_int = 11;
pub const vpiObjTypeVal: c_int = 12;
pub const vpiSuppressVal: c_int = 13;

// vpiScalarVal values.
pub const vpi0: c_int = 0;
pub const vpi1: c_int = 1;
pub const vpiZ: c_int = 2;
pub const vpiX: c_int = 3;
pub const vpiH: c_int = 4;
pub const vpiL: c_int = 5;

// §12.30 flags.
pub const vpiNoDelay: c_int = 1;
pub const vpiInertialDelay: c_int = 2;
pub const vpiTransportDelay: c_int = 3;
pub const vpiPureTransportDelay: c_int = 4;
pub const vpiForceFlag: c_int = 5;
pub const vpiReleaseFlag: c_int = 6;
pub const vpiCancelEvent: c_int = 7;
pub const vpiReturnEvent: c_int = 0x1000;

pub const vpiSchedEvent: c_int = 53;
pub const vpiScheduled: c_int = 46;

const gpa = std.heap.smp_allocator;

// ---------------------------------------------------------------------------
// A value, as read
// ---------------------------------------------------------------------------

/// Four-state bits, LSB first, as two parallel planes of u64 words — the
/// engine's own layout, so a digital value is borrowed rather than copied.
const Bits = struct {
    width: u32,
    val: []const u64,
    unk: []const u64,
    signed: bool,

    fn bit(b: Bits, i: u32) Int.Bit {
        const w = i / 64;
        const o: u6 = @truncate(i);
        const v: u2 = @intCast((b.val[w] >> o) & 1);
        const u: u2 = @intCast((b.unk[w] >> o) & 1);
        return @enumFromInt(v | (u << 1));
    }

    fn known(b: Bits) bool {
        for (b.unk) |w| if (w != 0) return false;
        return true;
    }

    /// The low 64 bits with x and z read as 0 — Table 12-4's vpiIntVal rule
    /// "Any bits x or z in the value of the object are mapped to a 0" —
    /// sign-extended from the object's width when it is signed.
    fn low64(b: Bits) u64 {
        var x = b.val[0] & ~b.unk[0];
        if (b.width < 64) {
            x &= (@as(u64, 1) << @intCast(b.width)) - 1;
            if (b.signed and b.width > 0 and (x >> @intCast(b.width - 1)) & 1 == 1)
                x |= ~((@as(u64, 1) << @intCast(b.width)) - 1);
        }
        return x;
    }
};

/// What an object's value is, when it has one.
const Source = union(enum) {
    bits: Bits,
    real: f64,
    str: []const u8,
};

fn source(o: *const Obj) ?Source {
    if (o.slot) |at| {
        const r = run.attached() orelse return null;
        const lit = r.values[at];
        // The engine holds a real as its IEEE 754 bits in the value plane.
        if (r.reals.contains(at)) return .{ .real = @bitCast(lit.planes[0]) };
        return .{ .bits = .{ .width = lit.width, .val = lit.values(), .unk = lit.unknowns(), .signed = lit.signed } };
    }
    if (o.value) |c| return switch (c) {
        .int => |i| .{ .bits = constBits(i) },
        .real => |f| .{ .real = f },
        .str => |s| .{ .str = s },
    };
    return null;
}

var const_word: [2]u64 = undefined;

/// A folded integer constant as 32 signed bits: §3.4.1's `integer` parameter.
fn constBits(i: i64) Bits {
    const_word = .{ @bitCast(i), 0 };
    return .{ .width = 32, .val = const_word[0..1], .unk = const_word[1..2], .signed = true };
}

/// Does `o` carry a value §12.16 can read?
pub fn hasValue(o: *const Obj) bool {
    return o.slot != null or o.value != null;
}

// ---------------------------------------------------------------------------
// The formats
// ---------------------------------------------------------------------------

/// One routine's value storage. §12.16: "The memory for the union members
/// str, time, vector, strength, and misc ... shall be provided by the routine
/// vpi_get_value(). This memory shall only be valid until the next call" —
/// and a value-change callback's value is "free[d] upon the return of the
/// callback", so the callback delivery owns a set of its own and a
/// vpi_get_value made INSIDE a callback does not clobber what it was handed.
pub const Store = struct {
    str: std.ArrayList(u8) = .empty,
    vec: std.ArrayList(VecVal) = .empty,
    time: Time = std.mem.zeroes(Time),
};

var get_store: Store = .{};
pub var cb_store: Store = .{};

/// Fill `v` from `o` in the format `v.format` names. Errors are recorded and
/// leave `v` as it was.
pub fn read(o: *const Obj, v: *Value, st: *Store) void {
    const src = source(o) orelse if (@import("analog.zig").argValue(o)) |r| Source{ .real = r } else {
        root.fail("NOVALUE", "vpi_get_value: `{s}` has no value this process can read", .{o.full});
        return;
    };
    if (v.format == vpiObjTypeVal) v.format = switch (src) {
        .real => vpiRealVal,
        .str => vpiStringVal,
        // §12.16: "For an integer, vpiIntVal ... For a scalar, ... vpiScalar
        // ... For a vector, vpiVectorVal". An integer PARAMETER is an integer.
        .bits => |b| if (o.kind == .integer or o.value != null) vpiIntVal else if (b.width == 1) vpiScalarVal else vpiVectorVal,
    };
    formatInto(src, v, st) catch {
        root.fail("NOMEM", "vpi_get_value: out of memory", .{});
    };
}

fn formatInto(src: Source, v: *Value, st: *Store) !void {
    switch (v.format) {
        vpiSuppressVal => {},
        vpiBinStrVal, vpiOctStrVal, vpiHexStrVal, vpiDecStrVal, vpiStringVal => {
            st.str.clearRetainingCapacity();
            switch (src) {
                .bits => |b| try radixString(&st.str, b, v.format),
                .real => |f| {
                    // NOTE to Table 12-4: a real "shall be converted to an
                    // integer using the rounding defined by the Verilog-AMS
                    // HDL" before any format but vpiRealVal.
                    if (v.format == vpiStringVal) {
                        try st.str.print(gpa, "{d}", .{f});
                    } else try radixString(&st.str, constBits(roundAway(f)), v.format);
                },
                .str => |s| {
                    if (v.format != vpiStringVal) return badFormat(v.format, "string");
                    try st.str.appendSlice(gpa, s);
                },
            }
            try st.str.append(gpa, 0);
            v.value.str = st.str.items.ptr;
        },
        vpiScalarVal => switch (src) {
            .bits => |b| v.value.scalar = switch (b.bit(0)) {
                .zero => vpi0,
                .one => vpi1,
                .z => vpiZ,
                .x => vpiX,
            },
            else => return badFormat(v.format, "non-bit"),
        },
        vpiIntVal => v.value.integer = switch (src) {
            .bits => |b| @bitCast(@as(u32, @truncate(b.low64()))),
            .real => |f| @truncate(roundAway(f)),
            .str => return badFormat(v.format, "string"),
        },
        vpiRealVal => v.value.real = switch (src) {
            .bits => |b| toReal(b),
            .real => |f| f,
            .str => return badFormat(v.format, "string"),
        },
        vpiVectorVal => {
            const b = switch (src) {
                .bits => |b| b,
                .real => |f| constBits(roundAway(f)),
                .str => return badFormat(v.format, "string"),
            };
            const n = (b.width + 31) / 32;
            st.vec.clearRetainingCapacity();
            try st.vec.ensureTotalCapacity(gpa, n);
            for (0..n) |k| {
                const w = k / 2;
                const shift: u6 = if (k % 2 == 0) 0 else 32;
                var a: u32 = @truncate(b.val[w] >> shift);
                var u: u32 = @truncate(b.unk[w] >> shift);
                // Bits past the object's width are not part of it.
                const top = b.width - @as(u32, @intCast(k)) * 32;
                if (top < 32) {
                    const m = (@as(u32, 1) << @intCast(top)) - 1;
                    a &= m;
                    u &= m;
                }
                st.vec.appendAssumeCapacity(.{ .aval = @bitCast(a), .bval = @bitCast(u) });
            }
            v.value.vector = st.vec.items.ptr;
        },
        vpiTimeVal => {
            const b = switch (src) {
                .bits => |b| b,
                else => return badFormat(v.format, "non-bit"),
            };
            const x = b.low64();
            st.time = .{ .type = callback.vpiSimTime, .high = @truncate(x >> 32), .low = @truncate(x), .real = 0 };
            v.value.time = &st.time;
        },
        else => return badFormat(v.format, "any"),
    }
}

fn badFormat(format: c_int, what: []const u8) error{}!void {
    root.fail("BADFORMAT", "value format {d} is not answered for a {s} value", .{ format, what });
}

/// §4.2.1.1 real-to-integer: nearest, ties away from zero.
fn roundAway(f: f64) i64 {
    if (!std.math.isFinite(f)) return 0;
    return std.math.lossyCast(i64, @round(f));
}

fn toReal(b: Bits) f64 {
    if (b.width <= 64) {
        const x = b.low64();
        return if (b.signed) @floatFromInt(@as(i64, @bitCast(x))) else @floatFromInt(x);
    }
    // Wider than 64: sum the words, x/z read as 0.
    var r: f64 = 0;
    var k = b.val.len;
    while (k > 0) {
        k -= 1;
        r = r * 18446744073709551616.0 + @as(f64, @floatFromInt(b.val[k] & ~b.unk[k]));
    }
    return r;
}

/// Table 12-4's string formats. Octal and hex group from the LSB; a group
/// that is ALL x (z) prints `x` (`z`), one that is only PARTLY x (z) prints
/// `X` (`Z`) — x winning over z when a group holds both, as it would in any
/// expression reading the group.
fn radixString(out: *std.ArrayList(u8), b: Bits, format: c_int) !void {
    switch (format) {
        vpiBinStrVal => {
            var i = b.width;
            while (i > 0) {
                i -= 1;
                try out.append(gpa, switch (b.bit(i)) {
                    .zero => '0',
                    .one => '1',
                    .x => 'x',
                    .z => 'z',
                });
            }
        },
        vpiOctStrVal, vpiHexStrVal => {
            const g: u32 = if (format == vpiOctStrVal) 3 else 4;
            const groups = (b.width + g - 1) / g;
            var k = groups;
            while (k > 0) {
                k -= 1;
                const lo = k * g;
                const hi = @min(lo + g, b.width);
                try out.append(gpa, groupChar(b, lo, hi));
            }
        },
        vpiDecStrVal => {
            if (!b.known()) {
                // The same all/some rule over the whole value: a decimal digit
                // has no bits of its own to be unknown in.
                try out.append(gpa, groupChar(b, 0, b.width));
                return;
            }
            try decimal(out, b);
        },
        vpiStringVal => {
            // "each 8-bit group of the value of the object is assumed to
            // represent an ASCII character", MSB first. A NUL group prints
            // nothing: it is the padding of a register wider than its text.
            var k = (b.width + 7) / 8;
            while (k > 0) {
                k -= 1;
                var c: u8 = 0;
                const lo = k * 8;
                const hi = @min(lo + 8, b.width);
                var i = hi;
                while (i > lo) {
                    i -= 1;
                    c = (c << 1) | @intFromBool(b.bit(i) == .one);
                }
                if (c != 0) try out.append(gpa, c);
            }
        },
        else => unreachable,
    }
}

fn groupChar(b: Bits, lo: u32, hi: u32) u8 {
    var xs: u32 = 0;
    var zs: u32 = 0;
    var d: u8 = 0;
    var i = hi;
    while (i > lo) {
        i -= 1;
        const bit = b.bit(i);
        d = (d << 1) | @intFromBool(bit == .one);
        if (bit == .x) xs += 1;
        if (bit == .z) zs += 1;
    }
    const n = hi - lo;
    if (xs == n) return 'x';
    if (zs == n) return 'z';
    if (xs != 0) return 'X';
    if (zs != 0) return 'Z';
    return "0123456789abcdef"[d];
}

/// Decimal of a fully known value, any width: repeated division of the
/// magnitude by 10. Signed objects print their sign.
fn decimal(out: *std.ArrayList(u8), b: Bits) !void {
    const words = try gpa.alloc(u64, b.val.len);
    defer gpa.free(words);
    @memcpy(words, b.val);
    // Mask to width, then negate a signed negative value.
    if (b.width % 64 != 0) words[words.len - 1] &= (@as(u64, 1) << @intCast(b.width % 64)) - 1;
    var neg = false;
    if (b.signed and b.bit(b.width - 1) == .one) {
        neg = true;
        var carry: u1 = 1;
        for (words) |*w| {
            const r = @addWithOverflow(~w.*, @as(u64, carry));
            w.* = r[0];
            carry = r[1];
        }
        if (b.width % 64 != 0) words[words.len - 1] &= (@as(u64, 1) << @intCast(b.width % 64)) - 1;
    }
    const start = out.items.len;
    while (true) {
        var rem: u128 = 0;
        var k = words.len;
        var zero = true;
        while (k > 0) {
            k -= 1;
            const cur = (rem << 64) | words[k];
            words[k] = @intCast(cur / 10);
            rem = cur % 10;
            if (words[k] != 0) zero = false;
        }
        try out.append(gpa, '0' + @as(u8, @intCast(rem)));
        if (zero) break;
    }
    if (neg) try out.append(gpa, '-');
    std.mem.reverse(u8, out.items[start..]);
}

/// §12.16. The object must carry a value; the string, vector and time
/// storage belongs to this routine until its next call.
pub export fn vpi_get_value(obj: vpiHandle, value_p: ?*Value) void {
    root.clearError();
    const v = value_p orelse {
        root.fail("BADVALUE", "vpi_get_value: value_p is NULL", .{});
        return;
    };
    // §12.22.1 a derivative object reads back what calltf put on it.
    if (@import("analog.zig").asDeriv(obj)) |dv| {
        v.format = vpiRealVal;
        v.value.real = dv.value;
        return;
    }
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_value: that handle is not an object with a value", .{});
        return;
    };
    read(o, v, &get_store);
}

// ---------------------------------------------------------------------------
// §12.30 vpi_put_value
// ---------------------------------------------------------------------------

/// One event a put scheduled. The HANDLE is `live`'s key; the record itself
/// stays in `events` while the event can still fire, so an inertial or
/// transport put can find it after the application freed its handle —
/// "Calling vpi_free_object() on the handle shall free the handle but shall
/// not effect the event."
pub const Event = struct {
    handle: sim.scheduler.Handle,
    slot: u32,
    time: u64,
};

var events: std.ArrayList(*Event) = .empty;
var live: std.AutoHashMapUnmanaged(usize, *Event) = .empty;

pub fn asEvent(h: vpiHandle) ?*Event {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

pub fn freeEvent(e: *Event) void {
    _ = live.remove(@intFromPtr(e));
}

/// Is the event still waiting to fire?
pub fn scheduled(e: *const Event) bool {
    const r = run.attached() orelse return false;
    return r.scheduler.payloadOf(e.handle) != null;
}

pub fn reset() void {
    for (events.items) |e| gpa.destroy(e);
    events.clearAndFree(gpa);
    live.clearAndFree(gpa);
    get_store.str.clearAndFree(gpa);
    get_store.vec.clearAndFree(gpa);
    cb_store.str.clearAndFree(gpa);
    cb_store.vec.clearAndFree(gpa);
    put_buf.clearAndFree(gpa);
}

/// Drop the records of events that fired or were cancelled and whose handle
/// the application no longer holds.
fn prune() void {
    var i: usize = 0;
    while (i < events.items.len) {
        const e = events.items[i];
        if (!scheduled(e) and !live.contains(@intFromPtr(e))) {
            gpa.destroy(events.swapRemove(i));
        } else i += 1;
    }
}

fn cancel(r: *digital.Run, h: sim.scheduler.Handle) void {
    const row = r.scheduler.payloadOf(h) orelse return;
    _ = r.scheduler.cancel(h) catch return;
    r.free_rows.append(r.arena, row) catch {};
}

var put_buf: std.ArrayList(u64) = .empty;

/// "shall set simulation logic values on an object ... The flags argument
/// shall be used to direct the routine to use one of the following delay
/// modes". Returns a vpiSchedEvent handle when vpiReturnEvent is set AND an
/// event was scheduled; otherwise NULL, which is not in itself an error.
pub export fn vpi_put_value(obj: vpiHandle, value_p: ?*Value, time_p: ?*const Time, flags: c_int) vpiHandle {
    root.clearError();
    const mode = flags & ~vpiReturnEvent;
    if (mode == vpiCancelEvent) {
        // "It shall not be an error to cancel an event which has already
        // occurred." A handle that is not a scheduled event at all is one.
        const e = asEvent(obj) orelse {
            root.fail("BADHANDLE", "vpi_put_value(vpiCancelEvent): that handle is not a vpiSchedEvent", .{});
            return null;
        };
        if (run.attached()) |r| cancel(r, e.handle);
        return null;
    }
    if (run.read_only) {
        root.fail("READONLY", "vpi_put_value: cbReadOnlySynch forbids writing values or scheduling events", .{});
        return null;
    }
    // §12.32.2 a derivative object of the running analog call.
    if (@import("analog.zig").asDeriv(obj)) |dv| {
        const pv = value_p orelse {
            root.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
            return null;
        };
        if (pv.format != vpiRealVal) {
            root.fail("BADFORMAT", "vpi_put_value: a derivative is a real, put with vpiRealVal", .{});
            return null;
        }
        _ = @import("analog.zig").putDerivative(dv, pv.value.real);
        return null;
    }
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_put_value: that handle is not an object", .{});
        return null;
    };
    // §12.30 "The routine can be applied to nets, regs, variables, memory
    // words, system function calls, sequential UDPs, and schedule events" —
    // a parameter is none of those. §11.6.12 NOTE 1 makes its value the
    // elaborated constant, which a put cannot be allowed to rewrite.
    // §11.6.13 NOTE 2: "For primitives, vpi_put_value() shall only be used
    // with sequential UDP primitives." A gate is not one.
    if (o.kind == .code and o.vtype == root.code.vpiGate) {
        root.fail("NOPUT", "vpi_put_value: a gate is a primitive, and only a sequential UDP takes a put", .{});
        return null;
    }
    if (o.kind == .parameter) {
        root.fail("NOPUT", "vpi_put_value: `{s}` is a parameter, which vpi_put_value does not apply to", .{o.full});
        return null;
    }
    // §12.30 "system function calls": the returned value of the analog call
    // calltf is running for (§12.32.3 "Set returned value to held value").
    if (o.kind == .code and o.vtype == root.code.vpiSysFuncCall) if (value_p) |pv| if (pv.format == vpiRealVal) {
        if (@import("analog.zig").putResult(o, pv.value.real)) return null;
    };
    const at = o.slot orelse {
        root.fail("NOVALUE", "vpi_put_value: `{s}` has no value this process holds", .{o.full});
        return null;
    };
    // vpiReleaseFlag: "The value_p shall contain the current value of the
    // object" — written back, after the release (IEEE 1364 §9.3.2 puts a
    // net back under its drivers at once).
    if (mode == vpiReleaseFlag) {
        exec.release(run.attached().?, at, true) catch return engineFail();
        if (value_p) |v| read(o, v, &get_store);
        callback.fireOverride(callback.cbRelease, o);
        return null;
    }
    // A net's value is the resolution of its drivers (§7.9); storing into it
    // would last until the next driver update. A put to a net needs a driver
    // of its own, which the engine does not give an application. A force
    // overrides the drivers, so it is the one put a net takes (§9.3.2).
    if (mode != vpiForceFlag and (o.kind == .net or (o.kind == .port and (run.attached().?).net_of.contains(at)))) {
        root.fail("NETPUT", "vpi_put_value: `{s}` is a net, whose value its drivers decide", .{o.full});
        return null;
    }
    const v = value_p orelse {
        root.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
        return null;
    };
    const r = run.attached().?;
    const dest = r.values[at];
    put_buf.resize(gpa, dest.planes.len) catch return oom();
    toPlanes(v, dest.width, put_buf.items) catch |e| {
        if (e == error.OutOfMemory) return oom();
        return null;
    };
    // A real holds IEEE 754 bits: a vpiRealVal as given, any other format as
    // the signed integer it wrote (IEEE 1364 §4.8.2 integer-to-real).
    if (r.reals.contains(at)) {
        const f: f64 = if (v.format == vpiRealVal) v.value.real else @floatFromInt(@as(i64, @bitCast(put_buf.items[0])));
        @memset(put_buf.items, 0);
        put_buf.items[0] = @bitCast(f);
    }
    const lit: Int.Literal = .{ .width = dest.width, .sized = true, .signed = dest.signed, .planes = put_buf.items };

    switch (mode) {
        // "time_p shall be ignored": a force is immediate.
        vpiForceFlag => {
            exec.forceValue(r, at, lit.planes) catch return engineFail();
            callback.fireOverride(callback.cbForce, o);
            return null;
        },
        vpiNoDelay => {
            exec.store(r, at, lit.planes) catch return engineFail();
            return null;
        },
        vpiInertialDelay, vpiTransportDelay, vpiPureTransportDelay => {
            const t = time_p orelse {
                root.fail("BADTIME", "vpi_put_value: a delayed put needs time_p", .{});
                return null;
            };
            const delay = run.ticksOf(t.*, obj) orelse return null;
            const when = run.now() +| delay;
            prune();
            for (events.items) |e| {
                if (e.slot != at or !scheduled(e)) continue;
                // vpiInertialDelay: "All scheduled events on the object shall
                // be removed". vpiTransportDelay: "All events on the object
                // scheduled for times later than this event shall be removed".
                if (mode == vpiInertialDelay or (mode == vpiTransportDelay and e.time > when)) cancel(r, e.handle);
            }
            const h = exec.enqueue(r, .{ .write = .{ .target = at, .value = lit } }, delay, false) catch return engineFail();
            const e = gpa.create(Event) catch return oom();
            e.* = .{ .handle = h, .slot = at, .time = when };
            events.append(gpa, e) catch {
                gpa.destroy(e);
                return oom();
            };
            if (flags & vpiReturnEvent == 0) return null;
            live.put(gpa, @intFromPtr(e), e) catch return oom();
            return @ptrCast(e);
        },
        else => {
            root.fail("BADFLAGS", "vpi_put_value: {d} is not a §12.30 delay mode", .{mode});
            return null;
        },
    }
}

fn oom() vpiHandle {
    root.fail("NOMEM", "vpi_put_value: out of memory", .{});
    return null;
}

fn engineFail() vpiHandle {
    root.fail("ENGINE", "vpi_put_value: the digital engine refused the write", .{});
    return null;
}

/// `v` as `width` bits in `planes` (value words, then unknown words).
fn toPlanes(v: *const Value, width: u32, planes: []u64) !void {
    @memset(planes, 0);
    const n = planes.len / 2;
    const val = planes[0..n];
    const unk = planes[n..];
    const set = struct {
        fn f(vv: []u64, uu: []u64, w: u32, i: u32, b: Int.Bit) void {
            if (i >= w) return;
            const o: u6 = @truncate(i);
            const m = @as(u64, 1) << o;
            const e = @intFromEnum(b);
            if (e & 1 != 0) vv[i / 64] |= m;
            if (e & 2 != 0) uu[i / 64] |= m;
        }
    }.f;
    switch (v.format) {
        vpiIntVal, vpiRealVal, vpiTimeVal => {
            const x: u64 = switch (v.format) {
                vpiIntVal => @bitCast(@as(i64, v.value.integer)),
                vpiRealVal => @bitCast(roundAway(v.value.real)),
                else => blk: {
                    const t = v.value.time orelse return badPut("vpiTimeVal with a NULL time");
                    break :blk (@as(u64, t.high) << 32) | t.low;
                },
            };
            // Sign-extend across the whole object: a negative int or real
            // written to a wide reg is still negative.
            const fill: u64 = if (v.format != vpiTimeVal and @as(i64, @bitCast(x)) < 0) ~@as(u64, 0) else 0;
            for (val, 0..) |*w, k| w.* = if (k == 0) x else fill;
        },
        vpiScalarVal => set(val, unk, width, 0, switch (v.value.scalar) {
            vpi0, vpiL => .zero,
            vpi1, vpiH => .one,
            vpiZ => .z,
            vpiX => .x,
            else => return badPut("vpiScalarVal outside vpi0/vpi1/vpiX/vpiZ/vpiH/vpiL"),
        }),
        vpiVectorVal => {
            const vec = v.value.vector orelse return badPut("vpiVectorVal with a NULL vector");
            const words = (width + 31) / 32;
            for (0..words) |k| {
                const a: u64 = @as(u32, @bitCast(vec[k].aval));
                const b: u64 = @as(u32, @bitCast(vec[k].bval));
                const shift: u6 = if (k % 2 == 0) 0 else 32;
                val[k / 2] |= a << shift;
                unk[k / 2] |= b << shift;
            }
        },
        vpiBinStrVal, vpiOctStrVal, vpiHexStrVal => {
            const s = std.mem.span(v.value.str orelse return badPut("a string format with a NULL str"));
            const g: u32 = switch (v.format) {
                vpiBinStrVal => 1,
                vpiOctStrVal => 3,
                else => 4,
            };
            var i: u32 = 0;
            var k = s.len;
            while (k > 0) {
                k -= 1;
                const c = s[k];
                const digit: ?u8 = std.fmt.charToDigit(c, @as(u8, 1) << @intCast(g)) catch null;
                var j: u32 = 0;
                while (j < g) : (j += 1) {
                    const b: Int.Bit = switch (c) {
                        'x', 'X' => .x,
                        'z', 'Z', '?' => .z,
                        else => if (digit) |d| (if ((d >> @intCast(j)) & 1 == 1) .one else .zero) else return badPut("a digit outside the format's radix"),
                    };
                    set(val, unk, width, i + j, b);
                }
                i += g;
            }
        },
        vpiDecStrVal => {
            const s = std.mem.span(v.value.str orelse return badPut("vpiDecStrVal with a NULL str"));
            const neg = s.len > 0 and s[0] == '-';
            for (s[@intFromBool(neg)..]) |c| {
                const d = std.fmt.charToDigit(c, 10) catch return badPut("a non-decimal digit in vpiDecStrVal");
                // val = val * 10 + d, across the words.
                var carry: u128 = d;
                for (val) |*w| {
                    const p = @as(u128, w.*) * 10 + carry;
                    w.* = @truncate(p);
                    carry = p >> 64;
                }
            }
            if (neg) {
                var carry: u1 = 1;
                for (val) |*w| {
                    const r = @addWithOverflow(~w.*, @as(u64, carry));
                    w.* = r[0];
                    carry = r[1];
                }
            }
        },
        vpiStringVal => {
            const s = std.mem.span(v.value.str orelse return badPut("vpiStringVal with a NULL str"));
            // The LAST character is the least significant byte.
            for (0..s.len) |k| {
                const c = s[s.len - 1 - k];
                for (0..8) |j| set(val, unk, width, @intCast(k * 8 + j), if ((c >> @intCast(j)) & 1 == 1) .one else .zero);
            }
        },
        else => return badPut("a value format vpi_put_value does not read"),
    }
    // Nothing past the object's width.
    if (width % 64 != 0) {
        const m = (@as(u64, 1) << @intCast(width % 64)) - 1;
        val[n - 1] &= m;
        unk[n - 1] &= m;
    }
}

fn badPut(why: []const u8) error{BadValue} {
    root.fail("BADVALUE", "vpi_put_value: {s}", .{why});
    return error.BadValue;
}

// ---------------------------------------------------------------------------
// cbValueChange delivery
// ---------------------------------------------------------------------------

/// Watch `o`'s slot for changes; the engine calls `onChange` for it from now
/// on. Cheap to repeat.
pub fn watch(o: *const Obj) void {
    const r = run.attached() orelse return;
    r.vpi_change = onChange;
    if (o.slot) |at| r.watch[at].insert(.vpi);
    // An array: every element (§12.31.1 "if the obj is a memory word or a
    // variable array, ... the index field shall contain the index").
    const d = &(root.design orelse return);
    for (o.members) |m| if (d.objects[m].slot) |at| r.watch[at].insert(.vpi);
}

fn onChange(_: *digital.Run, slot: u32) void {
    callback.fireSlot(slot);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Harness = @import("run.zig").Harness;

fn getStr(h: vpiHandle, format: c_int) []const u8 {
    var v: Value = std.mem.zeroes(Value);
    v.format = format;
    vpi_get_value(h, &v);
    return std.mem.span(v.value.str);
}

test "§12.16 Table 12-4: every string format over a four-state value" {
    var h: Harness = undefined;
    try h.init(
        \\module v;
        \\  reg [11:0] known, unknown;
        \\  reg [39:0] text;
        \\  reg signed [7:0] neg;
        \\  initial begin
        \\    known = 12'b1010_0111_0001;
        \\    unknown = 12'b1010_zzzz_01x1;
        \\    text = 40'h5665724121;
        \\    neg = -8'sd5;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();
    const known = root.vpi_handle_by_name("v.known", null);
    const unknown = root.vpi_handle_by_name("v.unknown", null);
    try std.testing.expectEqualStrings("101001110001", getStr(known, vpiBinStrVal));
    try std.testing.expectEqualStrings("5161", getStr(known, vpiOctStrVal));
    try std.testing.expectEqualStrings("2673", getStr(known, vpiDecStrVal));
    try std.testing.expectEqualStrings("a71", getStr(known, vpiHexStrVal));
    try std.testing.expectEqualStrings("1010zzzz01x1", getStr(unknown, vpiBinStrVal));
    try std.testing.expectEqualStrings("azX", getStr(unknown, vpiHexStrVal));
    try std.testing.expectEqualStrings("5ZZX", getStr(unknown, vpiOctStrVal));
    try std.testing.expectEqualStrings("VerA!", getStr(root.vpi_handle_by_name("v.text", null), vpiStringVal));
    try std.testing.expectEqualStrings("-5", getStr(root.vpi_handle_by_name("v.neg", null), vpiDecStrVal));

    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    vpi_get_value(unknown, &v);
    try std.testing.expectEqual(@as(c_int, 0xa05), v.value.integer);
    v.format = vpiVectorVal;
    vpi_get_value(unknown, &v);
    try std.testing.expectEqual(@as(c_int, 0xa07), v.value.vector[0].aval);
    try std.testing.expectEqual(@as(c_int, 0x0f2), v.value.vector[0].bval);
    v.format = vpiObjTypeVal;
    vpi_get_value(known, &v);
    try std.testing.expectEqual(vpiVectorVal, v.format);
    // A format the routine does not read, and a handle that is not an object.
    v.format = 99;
    vpi_get_value(known, &v);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    vpi_get_value(null, &v);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

test "§12.30: vpiNoDelay writes now, the delay modes schedule, and events cancel" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module p;
        \\  reg [7:0] q;
        \\  initial begin q = 0; #50 $finish(0); end
        \\endmodule
    );
    defer h.deinit();
    const q = root.vpi_handle_by_name("p.q", null);
    var v: Value = std.mem.zeroes(Value);
    var t: Time = .{ .type = callback.vpiSimTime, .high = 0, .low = 5, .real = 0 };
    v.format = vpiHexStrVal;
    v.value.str = @constCast("a5");
    try std.testing.expect(vpi_put_value(q, &v, null, vpiNoDelay | vpiReturnEvent) == null);
    try std.testing.expectEqualStrings("10100101", getStr(q, vpiBinStrVal));

    v.format = vpiIntVal;
    v.value.integer = 0xAA;
    const aa = vpi_put_value(q, &v, &t, vpiPureTransportDelay | vpiReturnEvent);
    try std.testing.expect(aa != null);
    try std.testing.expectEqual(vpiSchedEvent, root.vpi_get(root.vpiType, aa));
    try std.testing.expectEqual(@as(c_int, 1), root.vpi_get(vpiScheduled, aa));
    // An inertial put removes the 0xAA event.
    v.value.integer = 0xCC;
    t.low = 10;
    try std.testing.expect(vpi_put_value(q, &v, &t, vpiInertialDelay) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_get(vpiScheduled, aa));
    // Cancelling it again is not an error.
    _ = vpi_put_value(aa, null, null, vpiCancelEvent);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try run.simulate();
    v.format = vpiIntVal;
    vpi_get_value(q, &v);
    try std.testing.expectEqual(@as(c_int, 0xCC), v.value.integer);
}

test "§12.30: vpiForceFlag overrides a net's driver, vpiReleaseFlag hands it back" {
    var h: Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module f;
        \\  reg [7:0] a;
        \\  wire [7:0] w;
        \\  assign w = a + 8'd1;
        \\  initial begin a = 10; #50 $finish(0); end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();
    const w = root.vpi_handle_by_name("f.w", null);
    var fmt: Value = std.mem.zeroes(Value);
    fmt.format = vpiIntVal;
    for ([_]c_int{ callback.cbForce, callback.cbRelease }) |reason| {
        const d: callback.CbData = .{ .reason = reason, .cb_rtn = noteOverride, .obj = null, .time = null, .value = &fmt, .index = 0, .user_data = null };
        try std.testing.expect(callback.vpi_register_cb(&d) != null);
    }
    overrides_n = 0;
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiIntVal;
    // A plain put to a net is still refused: its drivers decide it.
    v.value.integer = 7;
    try std.testing.expect(vpi_put_value(w, &v, null, vpiNoDelay) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    v.value.integer = 0xF0;
    try std.testing.expect(vpi_put_value(w, &v, null, vpiForceFlag) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    v.value.integer = 0;
    vpi_get_value(w, &v);
    try std.testing.expectEqual(@as(c_int, 0xF0), v.value.integer);
    // Release: value_p comes back holding the driver's value, a + 1.
    v.value.integer = -1;
    _ = vpi_put_value(w, &v, null, vpiReleaseFlag);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 11), v.value.integer);
    // One cbForce carrying the forced value, one cbRelease the released one,
    // each naming the object.
    try std.testing.expectEqualSlices([3]c_int, &.{ .{ callback.cbForce, 0xF0, 1 }, .{ callback.cbRelease, 11, 1 } }, overrides[0..overrides_n]);
}

var overrides: [4][3]c_int = undefined;
var overrides_n: usize = 0;

fn noteOverride(d: *callback.CbData) callconv(.c) c_int {
    overrides[overrides_n] = .{ d.reason, d.value.?.value.integer, @intFromBool(root.asObj(d.obj) != null) };
    overrides_n += 1;
    return 0;
}

test "§12.16: an analog parameter reads the value lowering folded" {
    var res = try @import("vera").compileSource(std.testing.allocator,
        \\module r(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real g = 2.5;
        \\  parameter integer k = 3;
        \\  analog I(p,n) <+ g*k*V(p,n);
        \\endmodule
    , .lint);
    defer res.deinit();
    try root.open(std.testing.allocator, res.lowered);
    defer root.close();
    var v: Value = std.mem.zeroes(Value);
    v.format = vpiRealVal;
    vpi_get_value(root.vpi_handle_by_name("r.g", null), &v);
    try std.testing.expectEqual(@as(f64, 2.5), v.value.real);
    v.format = vpiObjTypeVal;
    vpi_get_value(root.vpi_handle_by_name("r.k", null), &v);
    try std.testing.expectEqual(vpiIntVal, v.format);
    v.format = vpiIntVal;
    vpi_get_value(root.vpi_handle_by_name("r.k", null), &v);
    try std.testing.expectEqual(@as(c_int, 3), v.value.integer);
    // A node's value lives in a device this process does not run.
    vpi_get_value(root.vpi_handle_by_name("r.p", null), &v);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}
