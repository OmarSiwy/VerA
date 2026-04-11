//! §12.7 vpi_get_analog_delta, §12.8 vpi_get_analog_freq, §12.9
//! vpi_get_analog_time, §12.10 vpi_get_analog_value, and the analysis
//! §12.31.3's analog callbacks are delivered from.
//!
//! WHAT RUNS. A Verilog-AMS device is compiled Zig; this process cannot
//! evaluate one from the object model. The host (`tests/vpi_host.zig`) builds
//! the design's device and the fixed solver as a shared library
//! (`tb.renderVpiLib`), loads it, and hands this file its entry points
//! (`attach`). The TIME WALK is here, not in the library, because §12.31.3
//! gives the application a say in it: acbAbsTime and acbElapsedTime "shall
//! force a solution at that time", and acbConvergenceTest may reject one
//! and "backup to an earlier time". A fixed grid decided when the library
//! was generated could honour neither.
//!
//! THE WALK, for `tran <start> <stop>`:
//!
//!   t = start, dt = 0: the time zero transient solution (§12.7/§12.9 "shall
//!                      return zero (0) during DC or the time zero transient
//!                      solution")
//!   repeat until t = stop:
//!     target = the nearest of the next grid point (start + k·max_step), stop,
//!              and the earliest acbAbsTime/acbElapsedTime after t
//!     solve tentatively at target, dt = target − t
//!     acbConvergenceTest ("prior acceptance"); any rejection halves dt and
//!              solves again — strictly earlier, as §12.31.3 says
//!     accept:  acbInitialStep (first) · acbAbsTime/acbElapsedTime due ·
//!              acbAcceptedPoint (all but the first) · acbFinalStep (last)
//!
//! `op` is the one DC solution, first and last at once. Nothing is committed
//! before acceptance (`vera_vpi_accept` is the only writer of history), so a
//! rejected solution leaves no trace but the attempt.
//!
//! FLOWS. §12.10 reads a branch's flow or potential. A potential is the
//! difference of two unknowns. A flow is an unknown only for a potential
//! source; a flow source's current is its §5.6 row's value, which the device
//! publishes on request (`codegen.Options.vpi_contribs`) — the resistive
//! half plus the time derivative of the reactive half, backward Euler over
//! the step being solved, exactly as the solver forms it.

const std = @import("std");
const root = @import("root.zig");
const callback = @import("callback.zig");
const code = @import("code.zig");
const systf = @import("systf.zig");

const vpiHandle = root.vpiHandle;

/// `tb.renderVpiLib`'s C interface.
pub const Lib = struct {
    open: *const fn (u8) callconv(.c) void,
    solve: *const fn (f64, f64, bool, bool) callconv(.c) bool,
    accept: *const fn () callconv(.c) void,
    x: *const fn () callconv(.c) [*]const f64,
    n_u: *const fn () callconv(.c) usize,
    n_rows: *const fn () callconv(.c) usize,
    row: *const fn (usize, *[4]i32) callconv(.c) void,
    rows: *const fn ([*]f64) callconv(.c) void,
    systf: *const fn (?HostCall) callconv(.c) void,
    n_systf: *const fn () callconv(.c) usize,
    systf_name: *const fn (usize, *usize) callconv(.c) [*]const u8,
};

/// The C function the library forwards `contract.SystfHost.call` to.
pub const HostCall = *const fn (usize, [*]const f64, usize, [*]f64) callconv(.c) f64;

pub const Kind = enum { op, tran };

/// One `analysis` line: §12.18's vpiStartTime/vpiEndTime/vpiTransientMaxStep
/// are its fields.
pub const Analysis = struct {
    kind: Kind,
    start: f64 = 0,
    stop: f64 = 0,
    max_step: f64 = 0,
};

/// The device's `AnalysisKind` ordinals (`static, ic, nodeset, dc, tran, ac,
/// noise`): an operating point is a DC analysis, a transient a transient.
fn kindOrdinal(k: Kind) u8 {
    return switch (k) {
        .op => 3,
        .tran => 4,
    };
}

const Row = struct { flow: bool, hi: i32, lo: i32, flow_u: i32 };

var lib: ?Lib = null;
var rows: []Row = &.{};
/// Each row's (resistive, reactive) value at the current x.
var now_vals: []f64 = &.{};
/// Each row's reactive value at the last ACCEPTED solution — the other
/// operand of the backward-Euler difference.
var prev_react: []f64 = &.{};
var vals_fresh = false;

/// The analysis running, or null between analyses.
var current: ?Analysis = null;
/// The time of the solution being attempted, or of the latest accepted one.
var t_now: f64 = 0;
/// The latest converged and accepted solution's time.
var t_accepted: f64 = 0;
/// The step being attempted, or the one the accepted solution was reached by.
var delta: f64 = 0;
/// A solution has been attempted in this process, so x means something.
var have_solution = false;
/// A later-than-first solution is attempted and not yet accepted: the one
/// §12.36 vpiRejectTransientStep can reject.
var open_step = false;
/// §12.36 vpiRejectTransientStep was called on the open step.
var reject_step = false;

/// §12.36 vpiRejectTransientStep: "cause the current analog simulation time
/// point to be rejected". The walk backs up as for an acbConvergenceTest
/// rejection. False when no rejectable solution is open: outside an analysis,
/// on the first solution (no earlier time to back up to), or once accepted.
pub fn rejectStep() bool {
    if (current == null or !open_step) return false;
    reject_step = true;
    return true;
}

const gpa = std.heap.smp_allocator;

/// Bind the loaded library. Its row table is read once: it is a property of
/// the compiled device, not of an analysis.
pub fn attach(l: Lib) error{OutOfMemory}!void {
    lib = l;
    // §12.32: the device's user system function calls, each bound to the
    // one call object of that name — `systf_calls` is keyed by NAME, so a
    // name with two call sites cannot say which of them is running, and is
    // refused when called rather than handed to the wrong one.
    const n_calls = l.n_systf();
    call_obj = try gpa.alloc(?u32, n_calls);
    for (call_obj, 0..) |*c, k| {
        var len: usize = 0;
        const name = l.systf_name(k, &len)[0..len];
        c.* = null;
        var seen: u32 = 0;
        for (root.design.?.objects, 0..) |o, i| {
            if (o.kind != .code or !o.in_analog or (o.vtype != code.vpiSysFuncCall and o.vtype != code.vpiSysTaskCall)) continue;
            if (!std.mem.eql(u8, o.name, name)) continue;
            seen += 1;
            c.* = @intCast(i);
        }
        if (seen > 1) c.* = null;
    }
    if (n_calls != 0) l.systf(deviceCall);
    const n = l.n_rows();
    rows = try gpa.alloc(Row, n);
    now_vals = try gpa.alloc(f64, 2 * n);
    prev_react = try gpa.alloc(f64, n);
    for (rows, 0..) |*r, k| {
        var m: [4]i32 = undefined;
        l.row(k, &m);
        r.* = .{ .flow = m[0] == 1, .hi = m[1], .lo = m[2], .flow_u = m[3] };
    }
}

pub fn detach() void {
    lib = null;
    gpa.free(call_obj);
    call_obj = &.{};
    arg_values.clearAndFree(gpa);
    active_call = null;
    n_derivs = 0;
    gpa.free(rows);
    gpa.free(now_vals);
    gpa.free(prev_react);
    rows = &.{};
    now_vals = &.{};
    prev_react = &.{};
    current = null;
    t_now = 0;
    t_accepted = 0;
    delta = 0;
    have_solution = false;
}

pub fn attached() ?Lib {
    return lib;
}

pub fn analysis() ?Analysis {
    return current;
}

/// §12.9's value: the attempted solution's time, or the latest accepted.
pub fn time() f64 {
    return t_now;
}

/// Where acbElapsedTime counts from: "the current solution".
pub fn acceptedTime() f64 {
    return if (current != null) t_accepted else 0;
}

/// Two analog instants are one when they differ by rounding only: a forced
/// point is solved at exactly the requested double, but a grid point is
/// `start + k·step` and need not be bit-equal to a time an application
/// computed another way.
pub fn sameTime(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-12 * @max(1.0, @max(@abs(a), @abs(b))) or @abs(a - b) <= 1e-21;
}

pub const Error = error{ NoLibrary, DidNotConverge, BackupExhausted };

/// Run one analysis to its end, delivering every §12.31.3 callback.
pub fn run(a: Analysis) Error!void {
    const l = lib orelse return error.NoLibrary;
    l.open(kindOrdinal(a.kind));
    @memset(prev_react, 0);
    var run_a = a;
    // §12.18 vpiTransientMaxStep is the step this walk takes.
    if (run_a.kind == .tran and run_a.max_step <= 0) run_a.max_step = (a.stop - a.start) / 50.0;
    current = run_a;
    defer current = null;
    t_accepted = a.start;
    const last0 = a.kind == .op or a.stop <= a.start;
    try attempt(l, a.start, 0, true, last0);
    // The first solution has no earlier time to back up to; §12.31.3's
    // rejection is honoured from the next one on.
    _ = callback.convergenceRejected();
    accept(l, true, last0);
    if (last0) return;

    const h = run_a.max_step;
    while (!sameTime(t_accepted, a.stop) and t_accepted < a.stop) {
        // The next grid point strictly after t, by index rather than by
        // accumulation, so a thousand steps do not drift off `stop`.
        const k = @floor((t_accepted - a.start) / h + 1e-9) + 1;
        var target = @min(a.start + k * h, a.stop);
        if (callback.nextForced(t_accepted, target)) |f| target = f;
        if (a.stop - target < h * 1e-6) target = a.stop;
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (tries == 60) return error.BackupExhausted;
            try attempt(l, target, target - t_accepted, false, sameTime(target, a.stop));
            if (!(callback.convergenceRejected() or reject_step)) break;
            // "backup to an earlier time": half the step, from the same
            // accepted solution.
            target = t_accepted + (target - t_accepted) / 2;
        }
        accept(l, false, sameTime(target, a.stop));
    }
}

fn attempt(l: Lib, t: f64, dt: f64, first: bool, last: bool) Error!void {
    t_now = t;
    delta = dt;
    have_solution = true;
    open_step = !first;
    reject_step = false;
    vals_fresh = false;
    _ = l.solve(t, dt, first, last);
}

fn accept(l: Lib, first: bool, last: bool) void {
    open_step = false;
    // Row values are the accepted solution's, read before history moves.
    refreshRows(l);
    l.accept();
    t_accepted = t_now;
    // §12.31.3 names two reasons for the first solution's acceptance —
    // acbInitialStep "upon acceptance of the first analog solution" and
    // acbAcceptedPoint "upon acceptance of the solution at the given time" —
    // and does not say whether the first is also the second. VerA delivers
    // the first solution as acbInitialStep only, so the accepted points an
    // application sees are the ones the analysis ADVANCED to, each strictly
    // later than the last (p03_02 pins that reading). The final solution is
    // an advance: it is an accepted point, then acbFinalStep.
    if (first) callback.fireAnalog(callback.acbInitialStep);
    callback.fireTimed(t_accepted);
    if (!first) callback.fireAnalog(callback.acbAcceptedPoint);
    if (last) callback.fireAnalog(callback.acbFinalStep);
    // Only now does this solution's charge become the next step's history.
    for (prev_react, 0..) |*q, k| q.* = now_vals[2 * k + 1];
}

fn refreshRows(l: Lib) void {
    if (vals_fresh or rows.len == 0) return;
    l.rows(now_vals.ptr);
    vals_fresh = true;
}

// ---------------------------------------------------------------------------
// §12.10 values
// ---------------------------------------------------------------------------

fn unknown(x: [*]const f64, row: i32) f64 {
    return if (row < 0) 0 else x[@intCast(row)];
}

fn unknownU16(x: [*]const f64, row: u16) f64 {
    return if (row == @import("ir").Lower.ground) 0 else x[row];
}

pub const ValueError = error{ NoAnalysis, Unknowable };

/// The real part of quantity `q`'s value — §11.6.7's "real value". This
/// process runs no small-signal analysis, so every imaginary part is 0.
pub fn quantityValue(q: *const root.Obj) ValueError!f64 {
    const l = lib orelse return error.NoAnalysis;
    if (!have_solution) return error.NoAnalysis;
    const d = &root.design.?;
    const b = &d.objects[q.branch orelse return error.NoAnalysis];
    const x = l.x();
    const is_flow = b.flow != null and &d.objects[b.flow.?] == q;
    if (!is_flow) return unknownU16(x, b.hi_row) - unknownU16(x, b.lo_row);
    if (b.flow_unknowable) return error.Unknowable;
    const sign: f64 = if (b.flow_neg) -1 else 1;
    if (b.contrib_pot) |k| {
        const r = rows[k];
        if (r.flow_u < 0) return error.Unknowable;
        return sign * x[@intCast(r.flow_u)];
    }
    if (b.contrib_flow) |k| {
        refreshRows(l);
        var v = now_vals[2 * k];
        if (delta > 0) v += (now_vals[2 * k + 1] - prev_react[k]) / delta;
        return sign * v;
    }
    // §5.6.1.3: a branch with no source retains nothing, and is an open
    // circuit — its flow is zero.
    return 0;
}

// ---------------------------------------------------------------------------
// The C routines
// ---------------------------------------------------------------------------

/// §12.9 "the time of the solution attempted or of the latest converged and
/// accepted solution otherwise. The function shall return zero (0) during DC
/// or the time zero transient solution."
pub export fn vpi_get_analog_time() f64 {
    root.clearError();
    if (current) |a| if (a.kind == .op) return 0;
    return t_now;
}

/// §12.7 "the elapsed time between the latest converged and accepted
/// solution and the solution being calculated. The function shall return
/// zero (0) during DC or the time zero transient solution." Inside an
/// acceptance callback the solution "being calculated" is the one just
/// accepted, so it is the step that reached it.
pub export fn vpi_get_analog_delta() f64 {
    root.clearError();
    if (current) |a| if (a.kind == .op) return 0;
    return delta;
}

/// §12.8 "the current frequency used in the small-signal analysis. The
/// function shall return zero (0) during DC or transient analysis." No
/// small-signal analysis runs in this process, so it is zero throughout.
pub export fn vpi_get_analog_freq() f64 {
    root.clearError();
    return 0;
}

// ---------------------------------------------------------------------------
// §12.32 analog system function calls, during the analysis
// ---------------------------------------------------------------------------

/// Per device call index: the VPI call object, or null when there is none
/// or more than one.
var call_obj: []?u32 = &.{};

/// The call being evaluated: §12.32's calltf is running for it.
const Active = struct { obj: u32, result: f64, partials: []f64 };
var active_call: ?*Active = null;

/// Each call argument's value at the latest evaluation, by object index —
/// what `vpi_get_value` answers for an argument with no value of its own
/// (an access function, an operation), inside calltf and after it: the
/// §12.32.3 sampler reads its expression from an acbAbsTime callback.
var arg_values: std.AutoHashMapUnmanaged(u32, f64) = .empty;

/// `contract.SystfHost.call`, for the library. §12.32.1: calltf is called
/// "each time the system task or function is invoked during simulation
/// execution", with the registration's user_data, and inside it
/// `vpi_handle(vpiSysTfCall, NULL)` is this call. The returned value is what
/// calltf put on the call (§12.30 "system function calls"); the partials are
/// what it put on §12.22.1's derivative objects, 0 where it put none.
fn deviceCall(k: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64 {
    @memset(partials[0..n], 0);
    const at = if (k < call_obj.len) call_obj[k] else null;
    const obj = at orelse {
        root.fail("AMBIGUOUS", "an analog system function called from more than one site is not told apart by this host", .{});
        return 0;
    };
    const d = &root.design.?;
    const o = &d.objects[obj];
    const reg = systf.find(o.name, .analog) orelse return 0;
    for (o.lists) |l| if (l.tag == code.vpiArgument) {
        for (l.items[0..@min(n, l.items.len)], 0..) |a, j| arg_values.put(gpa, a, args[j]) catch {};
    };
    const f = reg.analog.calltf orelse return 0;
    var st: Active = .{ .obj = obj, .result = 0, .partials = partials[0..n] };
    const prev_call = active_call;
    const prev_sys = systf.active;
    active_call = &st;
    systf.active = obj;
    defer {
        active_call = prev_call;
        systf.active = prev_sys;
    }
    var cb: callback.CbData = .{ .reason = 0, .cb_rtn = null, .obj = @ptrCast(o), .time = null, .value = null, .index = 0, .user_data = reg.analog.user_data };
    _ = f(&cb);
    return st.result;
}

/// §12.16 for an analog call argument that has no value of its own: its
/// value at the latest evaluation.
pub fn argValue(o: *const root.Obj) ?f64 {
    const d = &(root.design orelse return null);
    const i = (@intFromPtr(o) - @intFromPtr(d.objects.ptr)) / @sizeOf(root.Obj);
    return arg_values.get(@intCast(i));
}

/// §12.30 onto the call calltf is running for: its returned value. False
/// when `o` is not that call, so the ordinary put rules apply.
pub fn putResult(o: *const root.Obj, v: f64) bool {
    const st = active_call orelse return false;
    const d = &root.design.?;
    if (o != &d.objects[st.obj]) return false;
    st.result = v;
    return true;
}

// ---------------------------------------------------------------------------
// §12.22.1 / §12.32.2 derivative objects
// ---------------------------------------------------------------------------

/// One derivative handle: the call, and (of, wrt) in §12.32.2's numbering.
/// Handed out from a fixed array, so a handle is ours iff it points into it.
pub const Deriv = struct { call: u32, of: c_int, wrt: c_int, value: f64 = 0 };
var derivs: [64]Deriv = undefined;
var n_derivs: usize = 0;

pub fn asDeriv(h: vpiHandle) ?*Deriv {
    const p = @intFromPtr(h orelse return null);
    const lo = @intFromPtr(&derivs[0]);
    if (p < lo or p >= lo + n_derivs * @sizeOf(Deriv) or (p - lo) % @sizeOf(Deriv) != 0) return null;
    return @ptrFromInt(p);
}

/// Which §12.32.2 position `h` is on call `obj`: 0 for the call itself (the
/// returned value), 1.. for its arguments, null for neither.
fn position(obj: u32, h: vpiHandle) ?c_int {
    const d = &root.design.?;
    const o = root.asObj(h) orelse return null;
    if (o == &d.objects[obj]) return 0;
    for (d.objects[obj].lists) |l| if (l.tag == code.vpiArgument) {
        for (l.items, 0..) |a, j| if (&d.objects[a] == o) return @intCast(j + 1);
    };
    return null;
}

pub fn derivative(ref1: vpiHandle, ref2: vpiHandle) vpiHandle {
    const st = active_call orelse {
        root.fail("NOCALL", "vpi_handle_multi(vpiDerivative): no analog system task or function call is running", .{});
        return null;
    };
    const of = position(st.obj, ref1) orelse {
        root.fail("NOTARG", "vpi_handle_multi(vpiDerivative): the first handle is neither the call nor one of its arguments", .{});
        return null;
    };
    const wrt = position(st.obj, ref2) orelse 0;
    if (wrt == 0) {
        root.fail("NOTARG", "vpi_handle_multi(vpiDerivative): a derivative is taken with respect to an argument", .{});
        return null;
    }
    for (systf.partialsOf(st.obj)) |p| {
        if (p.of != of or p.wrt != wrt) continue;
        for (derivs[0..n_derivs]) |*dv| if (dv.call == st.obj and dv.of == of and dv.wrt == wrt) return @ptrCast(dv);
        if (n_derivs == derivs.len) {
            root.fail("NOMEM", "vpi_handle_multi(vpiDerivative): more than {d} derivative objects", .{derivs.len});
            return null;
        }
        derivs[n_derivs] = .{ .call = st.obj, .of = of, .wrt = wrt };
        n_derivs += 1;
        return @ptrCast(&derivs[n_derivs - 1]);
    }
    root.fail("UNDECLARED", "vpi_handle_multi(vpiDerivative): d({d})/d({d}) was not declared by derivtf", .{ of, wrt });
    return null;
}

/// §12.32.2 "values can then be contributed to the derivative using the
/// vpi_put_value function in the calltf call back". The device carries the
/// partials of the RETURNED value (its `SystfHost` returns one value), so a
/// derivative of an output argument has nowhere to go and is refused.
pub fn putDerivative(dv: *Deriv, v: f64) bool {
    const st = active_call orelse {
        root.fail("NOCALL", "vpi_put_value: a derivative takes a value during its call's calltf", .{});
        return false;
    };
    if (dv.call != st.obj) {
        root.fail("NOCALL", "vpi_put_value: that derivative belongs to another call", .{});
        return false;
    }
    if (dv.of != 0) {
        root.fail("NOTSUPPORTED", "vpi_put_value: the derivative of an output argument; this device takes the returned value's partials only", .{});
        return false;
    }
    const j: usize = @intCast(dv.wrt - 1);
    if (j >= st.partials.len) return false;
    st.partials[j] = v;
    dv.value = v;
    return true;
}

