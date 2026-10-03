//! §12.11 vpi_get_delays and §12.29 vpi_put_delays over the delay rows the
//! builders recorded (`Obj.delays`, in the module's time unit): continuous
//! assignments, gates and UDP instances, delay controls, and the §11.6.15
//! module paths and timing checks. A put on a gate, UDP or continuous
//! assignment rewrites the engine driver its statement became, and the row;
//! on a path or timing check, the row alone (no simulation applies a specify
//! block). Either way vpi_get_delays reads the put back.

const callback = @import("callback.zig");
const code = @import("code.zig");
const root = @import("root.zig");
const run = @import("run.zig");

const vpiContAssign = code.vpiContAssign;
const vpiDelayControl = code.vpiDelayControl;
const vpiGate = code.vpiGate;
const vpiModPath = code.vpiModPath;
const vpiTchk = code.vpiTchk;
const vpiUdp = code.vpiUdp;

// ---------------------------------------------------------------------------
// §12.11 vpi_get_delays
// ---------------------------------------------------------------------------

/// Figure 12-4, laid out as Annex G does (its `bool`s are PLI_INT32).
pub const Delay = extern struct {
    da: [*c]callback.Time,
    no_of_delays: c_int,
    time_type: c_int,
    mtm_flag: c_int,
    append_flag: c_int,
    pulsere_flag: c_int,
};

/// "shall retrieve the delays or pulse limits of an object and place them in
/// an s_vpi_delay structure which has been allocated by the user. The format
/// of the delay information shall be controlled by the time_type flag".
///
/// The objects with delays here are the ones §11.6 draws `vpi_get_delays()`
/// under and this model folds: a primitive (§11.6.13), a continuous
/// assignment (§11.6.17) and a delay control (§11.6.22). §12.11: "For
/// primitive objects, the no_of_delays value shall be 2 or 3." It names no
/// count for the other two; a continuous assignment carries a primitive's
/// delay3 (IEEE 1364 §6.1.3), so it takes 2 or 3 and the 1 its own `#d`
/// form writes, and a delay control holds 1. A delay asked for beyond those written is IEEE 1364
/// §7.14's derived one: fall = rise, turn-off = min(rise, fall).
///
/// Table 12-3's min/typ/max triple is one value three times (no mintypmax
/// expression reaches this model), and the reject and error limits of an
/// inertial delay are the delay itself (IEEE 1364 §14.6.1's default).
pub export fn vpi_get_delays(obj: root.vpiHandle, delay_p: ?*Delay) void {
    root.clearError();
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_delays: that handle is not an object", .{});
        return;
    };
    const d = delay_p orelse {
        root.fail("BADDELAY", "vpi_get_delays: delay_p is NULL", .{});
        return;
    };
    if (o.kind != .code or o.delays.len == 0) {
        root.fail("NODELAY", "vpi_get_delays: that object carries no delays", .{});
        return;
    }
    // §12.11: "For primitive objects, the no_of_delays value shall be 2 or
    // 3. For path delay objects, the no_of_delays value shall be 1, 2, 3, 6,
    // or 12. For timing check objects, the no_of_delays value shall match
    // the number of limits existing in the timing check."
    const primitive = o.vtype == vpiGate or o.vtype == vpiUdp;
    const legal = switch (o.vtype) {
        vpiModPath => switch (d.no_of_delays) {
            1, 2, 3, 6, 12 => true,
            else => false,
        },
        vpiTchk => d.no_of_delays == o.delays.len,
        else => d.no_of_delays >= @as(c_int, if (primitive) 2 else 1) and
            d.no_of_delays <= @as(c_int, if (o.vtype == vpiDelayControl) 1 else 3),
    };
    if (!legal) {
        root.fail("BADDELAY", "vpi_get_delays: no_of_delays {d} is not legal for this object", .{d.no_of_delays});
        return;
    }
    if (d.time_type != callback.vpiScaledRealTime and d.time_type != callback.vpiSimTime) {
        root.fail("BADDELAY", "vpi_get_delays: time_type {d} is neither vpiScaledRealTime nor vpiSimTime", .{d.time_type});
        return;
    }
    if (d.da == null) {
        root.fail("BADDELAY", "vpi_get_delays: da is NULL", .{});
        return;
    }
    const rise = o.delays[0];
    const fall = if (o.delays.len > 1) o.delays[1] else rise;
    const off = if (o.delays.len > 2) o.delays[2] else @min(rise, fall);
    var values_buf: [12]f64 = undefined;
    const values: []const f64 = if (o.vtype == vpiModPath)
        pathDelays(o.delays, &values_buf)
    else if (o.vtype == vpiTchk)
        o.delays
    else blk: {
        values_buf[0..3].* = .{ rise, fall, off };
        break :blk values_buf[0..3];
    };
    const mtm: usize = if (d.mtm_flag != 0) 3 else 1;
    const pulse: usize = if (d.pulsere_flag != 0) 3 else 1;
    var at: usize = 0;
    // A path's first three transitions (0->1, 1->0, 0->z) ARE its rise,
    // fall and turn-off, so every count reads a prefix.
    for (values[0..@intCast(d.no_of_delays)]) |v| {
        for (0..pulse) |_| for (0..mtm) |_| {
            var t: callback.Time = .{ .type = d.time_type, .high = 0, .low = 0, .real = v };
            if (d.time_type == callback.vpiSimTime) {
                const ticks = run.ticksOf(.{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = v }, obj) orelse return;
                t = .{ .type = callback.vpiSimTime, .high = @truncate(ticks >> 32), .low = @truncate(ticks), .real = 0 };
            }
            d.da[at] = t;
            at += 1;
        };
    }
}

// ---------------------------------------------------------------------------
// §12.29 vpi_put_delays
// ---------------------------------------------------------------------------

/// "shall set the delays or timing limits of an object as indicated in the
/// delay_p structure. The same ordering of delays shall be used as described
/// in the vpi_get_delays() function. If only the delay changes, and not the
/// pulse limits, the pulse limits shall retain the values they had before the
/// delays where altered."
///
/// The objects are the ones whose delays the ENGINE applies — a primitive
/// (§11.6.13: "For primitive objects, the no_of_delays value shall be 2 or
/// 3") and a continuous assignment (§11.6.17, a delay3: 1..3), found as the
/// driver their statement became in their instance. The new delays hold from
/// the next transition the engine schedules; one already in flight keeps the
/// delay it was scheduled with (IEEE 1364 §6.1.3/§7.14 fix a delay when the
/// change is scheduled). A delay control (§11.6.22) is a statement's, read
/// by a process, not a driver's, and is refused.
///
/// Table 12-5's layouts: with `mtm_flag` each delay is a min/typ/max triple
/// and the TYPICAL is applied (no mintypmax selection reaches the engine,
/// which runs typical, as `vpi_get_delays` reports); with `pulsere_flag` each
/// is a (delay, reject, error) triple, and the limits have nowhere to live
/// apart from the delay — IEEE 1364 §14.6.1's inertial default, "the pulse
/// limits ... the delay itself" — so they follow it, as they read back.
pub export fn vpi_put_delays(obj: root.vpiHandle, delay_p: ?*Delay) void {
    root.clearError();
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_put_delays: that handle is not an object", .{});
        return;
    };
    const d = delay_p orelse {
        root.fail("BADDELAY", "vpi_put_delays: delay_p is NULL", .{});
        return;
    };
    const primitive = o.kind == .code and (o.vtype == vpiGate or o.vtype == vpiUdp);
    const assign = o.kind == .code and o.vtype == vpiContAssign;
    // §11.6.15's paths and timing checks: "For path delay objects, the
    // no_of_delays value shall be 1, 2, 3, 6, or 12. For timing check
    // objects, the no_of_delays value shall match the number of limits".
    // They are the model's to hold — no simulation here applies a specify
    // block (W0251) — so the put sets what vpi_get_delays reads back.
    if (o.kind == .code and (o.vtype == vpiModPath or o.vtype == vpiTchk)) return putModelDelays(o, d);
    if (!primitive and !assign) {
        root.fail("NODELAY", "vpi_put_delays: that object has no delays a put can set", .{});
        return;
    }
    const least: c_int = if (primitive) 2 else 1;
    if (d.no_of_delays < least or d.no_of_delays > 3) {
        root.fail("BADDELAY", "vpi_put_delays: no_of_delays {d} is not legal here ({d}..3)", .{ d.no_of_delays, least });
        return;
    }
    if (d.time_type != callback.vpiScaledRealTime and d.time_type != callback.vpiSimTime) {
        root.fail("BADDELAY", "vpi_put_delays: time_type {d} is neither vpiScaledRealTime nor vpiSimTime", .{d.time_type});
        return;
    }
    if (d.da == null) {
        root.fail("BADDELAY", "vpi_put_delays: da is NULL", .{});
        return;
    }
    const r = run.attached() orelse {
        root.fail("NOENGINE", "vpi_put_delays: no simulation is running this object's drivers", .{});
        return;
    };
    const n: usize = @intCast(d.no_of_delays);
    const mtm: usize = if (d.mtm_flag != 0) 3 else 1;
    const pulse: usize = if (d.pulsere_flag != 0) 3 else 1;
    var ticks: [3]u64 = undefined;
    var units: [3]f64 = undefined;
    for (0..n) |k| {
        // The k-th delay's element: its typical (mtm), its delay (pulsere).
        const t = d.da[k * mtm * pulse + (if (mtm == 3) @as(usize, 1) else 0)];
        if (t.type != d.time_type) {
            root.fail("BADDELAY", "vpi_put_delays: da[{d}] is not of the structure's time_type", .{k});
            return;
        }
        ticks[k] = run.ticksOf(t, obj) orelse return;
        units[k] = if (t.type == callback.vpiScaledRealTime) t.real else @floatFromInt(ticks[k]);
    }
    // IEEE 1364 §7.14's derivations for the delays not given.
    if (n < 2) ticks[1] = ticks[0];
    if (n < 3) ticks[2] = @min(ticks[0], ticks[1]);
    const scope = o.owner orelse 0;
    var hit = false;
    for (r.drivers) |*drv| {
        if (drv.tok != o.src_tok or drv.scope != scope) continue;
        drv.delay = .{ .rise = ticks[0], .fall = ticks[1], .off = ticks[2], .present = true };
        hit = true;
    }
    if (!hit) {
        root.fail("NODRIVER", "vpi_put_delays: the engine holds no driver for that statement", .{});
        return;
    }
    // What vpi_get_delays reads back: the written delays, in the module's
    // unit when given scaled.
    const d_objs = &root.design.?;
    const idx = (@intFromPtr(o) - @intFromPtr(d_objs.objects.ptr)) / @sizeOf(root.Obj);
    d_objs.objects[idx].delays = d_objs.arena.allocator().dupe(f64, units[0..n]) catch {
        root.fail("NOMEM", "vpi_put_delays: out of memory", .{});
        return;
    };
}

/// IEEE 1364 §14.3.1 Table 14-3: a path's written delays as the twelve
/// transitions 0->1, 1->0, 0->z, z->1, 1->z, z->0, 0->x, x->1, 1->x, x->0,
/// x->z, z->x. One value is every transition; two are rise and fall; three
/// add turn-off; six are the first six; the x transitions of a six-value
/// path are the pessimistic ones, min into x and max out of it.
fn pathDelays(w: []const f64, out: *[12]f64) []const f64 {
    const t: [6]f64 = switch (w.len) {
        1 => .{ w[0], w[0], w[0], w[0], w[0], w[0] },
        2 => .{ w[0], w[1], w[0], w[0], w[1], w[1] },
        3 => .{ w[0], w[1], w[2], w[0], w[2], w[1] },
        6, 12 => w[0..6].*,
        else => return w,
    };
    out[0..6].* = t;
    if (w.len == 12) {
        out[6..12].* = w[6..12].*;
    } else {
        out[6] = @min(t[0], t[2]); // 0->x
        out[7] = @max(t[0], t[3]); // x->1
        out[8] = @min(t[1], t[4]); // 1->x
        out[9] = @max(t[1], t[5]); // x->0
        out[10] = @max(t[4], t[2]); // x->z
        out[11] = @min(t[3], t[5]); // z->x
    }
    return out[0..12];
}

fn putModelDelays(o: *const root.Obj, d: *const Delay) void {
    const legal = if (o.vtype == vpiModPath) switch (d.no_of_delays) {
        1, 2, 3, 6, 12 => true,
        else => false,
    } else d.no_of_delays == o.delays.len;
    if (!legal) {
        root.fail("BADDELAY", "vpi_put_delays: no_of_delays {d} is not legal for this object", .{d.no_of_delays});
        return;
    }
    if (d.time_type != callback.vpiScaledRealTime or d.da == null) {
        root.fail("BADDELAY", "vpi_put_delays: a specify object's delays are put as vpiScaledRealTime, in an array", .{});
        return;
    }
    const n: usize = @intCast(d.no_of_delays);
    const mtm: usize = if (d.mtm_flag != 0) 3 else 1;
    const pulse: usize = if (d.pulsere_flag != 0) 3 else 1;
    const design = &root.design.?;
    const out = design.arena.allocator().alloc(f64, n) catch {
        root.fail("NOMEM", "vpi_put_delays: out of memory", .{});
        return;
    };
    for (out, 0..) |*v, k| v.* = d.da[k * mtm * pulse + (if (mtm == 3) @as(usize, 1) else 0)].real;
    const idx = (@intFromPtr(o) - @intFromPtr(design.objects.ptr)) / @sizeOf(root.Obj);
    design.objects[idx].delays = out;
}
