//! §12.33 vpi_register_systf, §12.32 vpi_register_analog_systf, §12.14
//! vpi_get_systf_info, §12.13 vpi_get_analog_systf_info, and §12.22's
//! vpi_handle_multi — the user system task/function registry.
//!
//! WHAT IS HERE: the registry, whole. Registration validates what §12.32/
//! §12.33 constrain — "first character shall be `$`", the type and
//! sysfunctype constants, and §12.32's uniqueness rule, "The task or function
//! name shall be unique in the domain in which it is registered. That is, the
//! same name can be shared by two sets of callbacks, provided that one set is
//! registered in the digital domain and the other is registered in the
//! analog" — and hands back a vpiUserSystf handle whose registration the info
//! routines read back and `vpi_iterate(vpiUserSystf, NULL)` walks.
//!
//! WHAT IS NOT, and why, stated once: the compiletf/sizetf/derivtf/calltf
//! INVOCATIONS. They happen at a call site of the registered name, and
//!   - the digital engine refuses a user `$name` call at elaboration (it has
//!     no user-systf call form), so no digital call site ever exists; and
//!   - an analog call site is evaluated inside a compiled device, which a
//!     host binds through `contract.SystfHost` in its own process — not this
//!     one.
//! So there is never an active call: `vpi_handle(vpiSysTfCall, NULL)` is NULL
//! (the ordinary "no such object" answer, not an error), and
//! `vpi_handle_multi(vpiDerivative, …)` has no argument handles it could be
//! given. Both are real answers for the process as it is.

const std = @import("std");
const root = @import("root.zig");
const callback = @import("callback.zig");

const vpiHandle = root.vpiHandle;

// §12.33.1 type / sysfunctype, Annex G numbering. VAMS spells the function
// type vpiSysFunction; Annex G spells it vpiSysFunc. Same number.
pub const vpiSysTask: c_int = 1;
pub const vpiSysFunc: c_int = 2;
pub const vpiIntFunc: c_int = 1;
pub const vpiRealFunc: c_int = 2;
pub const vpiTimeFunc: c_int = 3;
pub const vpiSizedFunc: c_int = 4;
pub const vpiSizedSignedFunc: c_int = 5;

// §12.32.1. Verilog-AMS names these and numbers none of them; the numbers are
// VerA's, the ones p03_vpi_analog.h allocated before them.
pub const vpiAnalogSysTask: c_int = 740;
pub const vpiAnalogSysFunc: c_int = 741;
pub const vpiDerivative: c_int = 730;

pub const vpiUserSystf: c_int = 67;
pub const vpiSysTfCall: c_int = 85;
pub const vpiInterModPath: c_int = 26;

/// Figure 12-19, laid out for C.
pub const SystfData = extern struct {
    type: c_int,
    sysfunctype: c_int,
    tfname: [*c]u8,
    calltf: ?*const fn ([*c]u8) callconv(.c) c_int,
    compiletf: ?*const fn ([*c]u8) callconv(.c) c_int,
    sizetf: ?*const fn ([*c]u8) callconv(.c) c_int,
    user_data: [*c]u8,
};

pub const Partials = extern struct {
    count: c_int,
    derivative_of: [*c]c_int,
    derivative_wrt: [*c]c_int,
};

/// Figure 12-18, laid out for C.
pub const AnalogSystfData = extern struct {
    type: c_int,
    sysfunctype: c_int,
    tfname: [*c]u8,
    calltf: ?*const fn (*callback.CbData) callconv(.c) c_int,
    compiletf: ?*const fn (*callback.CbData) callconv(.c) c_int,
    sizetf: ?*const fn (*callback.CbData) callconv(.c) c_int,
    derivtf: ?*const fn (*callback.CbData) callconv(.c) ?*Partials,
    user_data: [*c]u8,
};

pub const Domain = enum { digital, analog };

/// §11.6.16's call properties. Annex G numbers vpiSysFuncType as vpiFuncType.
pub const vpiUserDefn: c_int = 45;
pub const vpiSysFuncType: c_int = 44;

/// The registration of `name` in `domain`, if one was made: §11.6.16 NOTE 3's
/// "corresponding systf object" of a call to a user-defined name.
pub fn find(name: []const u8, domain: Domain) ?*Systf {
    for (regs.items) |s| if (s.domain == domain and std.mem.eql(u8, s.name, name)) return s;
    return null;
}

pub const Systf = struct {
    domain: Domain,
    /// The registration as given, with `tfname` pointing at this record's own
    /// copy: the application's string may be a stack buffer (§12.33's own
    /// example builds the name with sprintf).
    digital: SystfData = std.mem.zeroes(SystfData),
    analog: AnalogSystfData = std.mem.zeroes(AnalogSystfData),
    name: [:0]u8,
};

const gpa = std.heap.smp_allocator;
var regs: std.ArrayList(*Systf) = .empty;
var live: std.AutoHashMapUnmanaged(usize, *Systf) = .empty;

pub fn asSystf(h: vpiHandle) ?*Systf {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

pub fn reset() void {
    for (regs.items) |s| {
        gpa.free(s.name);
        gpa.destroy(s);
    }
    regs.clearAndFree(gpa);
    live.clearAndFree(gpa);
}

/// Every registration, in order, for `vpi_iterate(vpiUserSystf, NULL)`.
pub fn all(a: std.mem.Allocator) ![]vpiHandle {
    const out = try a.alloc(vpiHandle, regs.items.len);
    for (regs.items, out) |s, *h| h.* = @ptrCast(s);
    return out;
}

fn checkName(who: []const u8, tfname: [*c]const u8, domain: Domain) ?[]const u8 {
    if (tfname == null) {
        root.fail("BADNAME", "{s}: tfname is NULL", .{who});
        return null;
    }
    const name = std.mem.span(tfname);
    // §12.32/§12.33: "first character shall be `$`" — and a `$` alone names
    // nothing a source could call.
    if (name.len < 2 or name[0] != '$') {
        root.fail("BADNAME", "{s}: `{s}` does not begin with `$` and a name", .{ who, name });
        return null;
    }
    for (regs.items) |s| if (s.domain == domain and std.mem.eql(u8, s.name, name)) {
        root.fail("DUPSYSTF", "{s}: `{s}` is already registered in the {t} domain", .{ who, name, domain });
        return null;
    };
    return name;
}

fn add(s: Systf) vpiHandle {
    const p = gpa.create(Systf) catch return oom();
    p.* = s;
    regs.append(gpa, p) catch {
        gpa.destroy(p);
        return oom();
    };
    live.put(gpa, @intFromPtr(p), p) catch {
        _ = regs.pop();
        gpa.destroy(p);
        return oom();
    };
    return @ptrCast(p);
}

fn oom() vpiHandle {
    root.fail("NOMEM", "systf registration: out of memory", .{});
    return null;
}

/// §12.33 "shall register callbacks for user-defined system tasks or
/// functions". §12.33.1: type is vpiSysTask or vpiSysFunction, and for a
/// function sysfunctype is vpiIntFunc, vpiRealFunc, vpiTimeFunc or
/// vpiSizedFunc (Annex G adds vpiSizedSignedFunc).
pub export fn vpi_register_systf(systf_data_p: ?*const SystfData) vpiHandle {
    root.clearError();
    const d = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_register_systf: systf_data_p is NULL", .{});
        return null;
    };
    if (d.type != vpiSysTask and d.type != vpiSysFunc) {
        root.fail("BADSYSTF", "vpi_register_systf: type {d} is neither vpiSysTask nor vpiSysFunction", .{d.type});
        return null;
    }
    if (d.type == vpiSysFunc and (d.sysfunctype < vpiIntFunc or d.sysfunctype > vpiSizedSignedFunc)) {
        root.fail("BADSYSTF", "vpi_register_systf: sysfunctype {d} is not a §12.33.1 function type", .{d.sysfunctype});
        return null;
    }
    const name = checkName("vpi_register_systf", d.tfname, .digital) orelse return null;
    const copy = gpa.dupeZ(u8, name) catch return oom();
    var reg = d.*;
    reg.tfname = copy.ptr;
    const h = add(.{ .domain = .digital, .digital = reg, .name = copy });
    if (h == null) gpa.free(copy);
    return h;
}

/// §12.32. §12.32.1: type is vpiAnalogSysTask or vpiAnalogSysFunction, and
/// for a function sysfunctype is vpiIntFunc or vpiRealFunc.
pub export fn vpi_register_analog_systf(systf_data_p: ?*const AnalogSystfData) vpiHandle {
    root.clearError();
    const d = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_register_analog_systf: systf_data_p is NULL", .{});
        return null;
    };
    if (d.type != vpiAnalogSysTask and d.type != vpiAnalogSysFunc) {
        root.fail("BADSYSTF", "vpi_register_analog_systf: type {d} is neither vpiAnalogSysTask nor vpiAnalogSysFunction", .{d.type});
        return null;
    }
    if (d.type == vpiAnalogSysFunc and d.sysfunctype != vpiIntFunc and d.sysfunctype != vpiRealFunc) {
        root.fail("BADSYSTF", "vpi_register_analog_systf: sysfunctype {d} is neither vpiIntFunc nor vpiRealFunc", .{d.sysfunctype});
        return null;
    }
    const name = checkName("vpi_register_analog_systf", d.tfname, .analog) orelse return null;
    const copy = gpa.dupeZ(u8, name) catch return oom();
    var reg = d.*;
    reg.tfname = copy.ptr;
    const h = add(.{ .domain = .analog, .analog = reg, .name = copy });
    if (h == null) gpa.free(copy);
    return h;
}

/// §12.14 "shall return information about a user-defined system task or
/// function callback in an s_vpi_systf_data structure".
pub export fn vpi_get_systf_info(obj: vpiHandle, systf_data_p: ?*SystfData) void {
    root.clearError();
    const s = asSystf(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_systf_info: that handle is not a vpiUserSystf", .{});
        return;
    };
    const out = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_get_systf_info: systf_data_p is NULL", .{});
        return;
    };
    if (s.domain != .digital) {
        root.fail("DOMAIN", "vpi_get_systf_info: `{s}` is an analog registration; vpi_get_analog_systf_info reads it", .{s.name});
        return;
    }
    out.* = s.digital;
}

/// §12.13, the analog twin of §12.14.
pub export fn vpi_get_analog_systf_info(obj: vpiHandle, systf_data_p: ?*AnalogSystfData) void {
    root.clearError();
    const s = asSystf(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_analog_systf_info: that handle is not a vpiUserSystf", .{});
        return;
    };
    const out = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_get_analog_systf_info: systf_data_p is NULL", .{});
        return;
    };
    if (s.domain != .analog) {
        root.fail("DOMAIN", "vpi_get_analog_systf_info: `{s}` is a digital registration; vpi_get_systf_info reads it", .{s.name});
        return;
    }
    out.* = s.analog;
}

/// §12.22 / §12.22.1. `vpiDerivative` names the partial of `ref1` with
/// respect to `ref2`, two ARGUMENTS of the active analog call, and "can only
/// be called for those derivatives allocated during the derivtf phase". No
/// call is ever active in this process (see the file header), so no handle can
/// be an argument of one and every request fails — as does vpiInterModPath,
/// whose module paths (specify blocks) the model does not hold.
pub export fn vpi_handle_multi(obj_type: c_int, ref1: vpiHandle, ref2: vpiHandle, ...) callconv(.c) vpiHandle {
    root.clearError();
    switch (obj_type) {
        vpiDerivative => root.fail(
            "NOCALL",
            "vpi_handle_multi(vpiDerivative): {s} and {s} are not arguments of an active analog system task call",
            .{ if (ref1 == null) "NULL" else "the first handle", if (ref2 == null) "NULL" else "the second" },
        ),
        vpiInterModPath => root.fail("NOPATH", "vpi_handle_multi(vpiInterModPath): inter-module paths are not modelled", .{}),
        else => root.fail("NOTRAVERSE", "vpi_handle_multi: {d} is not a many-to-one relationship", .{obj_type}),
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn dCall(_: [*c]u8) callconv(.c) c_int {
    return 0;
}
fn aCall(_: *callback.CbData) callconv(.c) c_int {
    return 0;
}

test "§12.32/§12.33: a name is unique per domain, shared across the two, and must start with $" {
    reset();
    defer reset();
    var name_buf = "$both".*;
    var ud = "digital".*;
    const dig: SystfData = .{ .type = vpiSysFunc, .sysfunctype = vpiRealFunc, .tfname = &name_buf, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = &ud };
    const d = vpi_register_systf(&dig);
    try std.testing.expect(d != null);
    // The registration copied the name: the caller's buffer may change.
    name_buf[1] = 'X';
    try std.testing.expect(vpi_register_systf(&dig) != null); // `$Xoth` is new
    name_buf[1] = 'b';
    try std.testing.expect(vpi_register_systf(&dig) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    const ana: AnalogSystfData = .{ .type = vpiAnalogSysTask, .sysfunctype = 0, .tfname = &name_buf, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    const a = vpi_register_analog_systf(&ana);
    try std.testing.expect(a != null);
    try std.testing.expect(vpi_register_analog_systf(&ana) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_compare_objects(d, a));

    var info: SystfData = std.mem.zeroes(SystfData);
    vpi_get_systf_info(d, &info);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqualStrings("$both", std.mem.span(info.tfname));
    try std.testing.expect(info.user_data == @as([*c]u8, &ud));
    try std.testing.expectEqual(vpiUserSystf, root.vpi_get(root.vpiType, d));
    // The other domain's reader refuses.
    var ainfo: AnalogSystfData = std.mem.zeroes(AnalogSystfData);
    vpi_get_analog_systf_info(d, &ainfo);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    var bad = "nodollar".*;
    const nd: SystfData = .{ .type = vpiSysTask, .sysfunctype = 0, .tfname = &bad, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    try std.testing.expect(vpi_register_systf(&nd) == null);
    // A function with no §12.33.1 return type.
    var f = "$f".*;
    const nf: SystfData = .{ .type = vpiSysFunc, .sysfunctype = 99, .tfname = &f, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    try std.testing.expect(vpi_register_systf(&nf) == null);
    try std.testing.expectEqual(@as(usize, 3), regs.items.len);
}

test "§11.6.16/§12.22.1: with no call active there is no call and no derivative" {
    reset();
    defer reset();
    try std.testing.expect(root.vpi_handle(vpiSysTfCall, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expect(vpi_handle_multi(vpiDerivative, null, null) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}
