//! A SPICE deck's one analysis on a generated testbench's device: the entry
//! points `lib/backend/tb/runner.zig` emits a call to for `//! tran` and
//! `//! onoise`. Each prints one full-precision row per accepted point or
//! frequency to stderr, for `zig build test-spice` to grade against the
//! deck's oracle, and exits 1 naming the failure.
const std = @import("std");
const contract = @import("contract");
const Circuit = @import("circuit.zig").Circuit;
const converger = @import("converger.zig");
const op = @import("op.zig");
const tran = @import("tran.zig");
const noise = @import("noise.zig");

fn fail(title: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("{s}: ", .{title});
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

/// Prints `tran t=<t> <unknown>=<x> ...` per accepted point.
fn TranRows(comptime D: type) type {
    return struct {
        pub fn record(_: @This(), t: f64, x: []const f64) !void {
            std.debug.print("tran t={e}", .{t});
            for (@typeInfo(D.U).@"enum".field_names, x) |name, v| std.debug.print(" {s}={e}", .{ name, v });
            std.debug.print("\n", .{});
        }
    };
}

/// `//! tran tstep, tstop`: the operating point (a transient's own, so
/// `analysis("ic")`), then `tran.simulate`. `model` and `inst` are derived
/// and set up.
pub fn runTran(comptime D: type, title: []const u8, model: *const D.Model, inst: *D.Instance, tstep: f64, tstop: f64) void {
    var ckt: Circuit(D) = .init(model, inst);
    var ws: converger.Workspace(contract.nU(D)) = .{};
    var x: [contract.nU(D)]f64 = undefined;
    _ = op.solve(&ckt, &ws, &x, .ic) catch |e| fail(title, "operating point: {t}", .{e});
    const r = tran.simulate(&ckt, &ws, &x, .{ .t_stop = tstop, .dt_init = tstep }, TranRows(D){}) catch |e| fail(title, "transient: {t}", .{e});
    if (!r.completed) fail(title, "transient: timestep too small at t = {e}", .{r.t_final});
}

/// `//! onoise V(out) = f, ...`: the operating point, then `noise.sweep`;
/// prints `noise f=<f> onoise=<V/sqrt(Hz)>`.
pub fn runNoise(comptime D: type, title: []const u8, model: *const D.Model, inst: *D.Instance, out: D.U, comptime freqs: []const f64) void {
    var ckt: Circuit(D) = .init(model, inst);
    var ws: converger.Workspace(contract.nU(D)) = .{};
    var x: [contract.nU(D)]f64 = undefined;
    _ = op.solve(&ckt, &ws, &x, .dc) catch |e| fail(title, "operating point: {t}", .{e});
    var dens: [freqs.len]f64 = undefined;
    noise.sweep(&ckt, &x, @backingInt(out), freqs, &dens) catch |e| fail(title, "noise: {t}", .{e});
    for (freqs, dens) |f, d| std.debug.print("noise f={e} onoise={e}\n", .{ f, @sqrt(d) });
}
