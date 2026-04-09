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
    systf: *const fn (?*anyopaque) callconv(.c) void,
};

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

const gpa = std.heap.smp_allocator;

/// Bind the loaded library. Its row table is read once: it is a property of
/// the compiled device, not of an analysis.
pub fn attach(l: Lib) error{OutOfMemory}!void {
    lib = l;
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
            if (!callback.convergenceRejected()) break;
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
    vals_fresh = false;
    _ = l.solve(t, dt, first, last);
}

fn accept(l: Lib, first: bool, last: bool) void {
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
