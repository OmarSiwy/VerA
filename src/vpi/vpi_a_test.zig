//! Corner cases of root.zig's error status and delays.zig's puts, over
//! digital designs run through `run.Harness`. The rest of these files' tests
//! sit beside their code; test.zig holds the model's.
//! No LRM clause beyond the ones each test names.

const std = @import("std");
const callback = @import("callback.zig");
const code = @import("code.zig");
const delays = @import("delays.zig");
const handle = @import("handle.zig");
const iterate = @import("iterate.zig");
const root = @import("root.zig");
const run = @import("run.zig");
const systf = @import("systf.zig");

const Time = callback.Time;

fn scaled(v: f64) Time {
    return .{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = v };
}

fn ticks(n: u32) Time {
    return .{ .type = callback.vpiSimTime, .high = 0, .low = n, .real = 0 };
}

fn delayOf(da: []Time, n: c_int, time_type: c_int) delays.Delay {
    return .{ .da = da.ptr, .no_of_delays = n, .time_type = time_type, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
}

test "§12.2: a message past Figure 12-1's buffer is truncated and still NUL-terminated" {
    root.close();
    const long: [600]u8 = @splat('x');
    root.fail("LONG", "{s}", .{&long});
    var info: root.ErrorInfo = undefined;
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(&info));
    try std.testing.expectEqual(@as(usize, 511), std.mem.span(info.message).len);
    try std.testing.expectEqualStrings("LONG", std.mem.span(info.code));
    // vpi_chk_error leaves the status; the next routine clears it.
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_compare_objects(null, null));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(&info));
    try std.testing.expectEqualStrings("BADHANDLE", std.mem.span(info.code));
    root.clearError();
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(&info));
    try std.testing.expect(info.message == null and info.code == null);
}

test "§12.29: a delay put in ticks reads back in the module's time unit" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1us/1ns
        \\module top; reg a; wire y; buf g(y, a); endmodule
    );
    defer h.deinit();
    const g = handle.vpi_handle_by_name("top.g", null) orelse return error.TestUnexpectedResult;
    // 2000 and 3000 ticks of the 1 ns precision: 2 and 3 us.
    var da = [3]Time{ ticks(2000), ticks(3000), ticks(0) };
    var dl = delayOf(&da, 2, callback.vpiSimTime);
    delays.vpi_put_delays(g, &dl);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    dl = delayOf(&da, 3, callback.vpiScaledRealTime);
    delays.vpi_get_delays(g, &dl);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    for (da, [_]f64{ 2, 3, 2 }) |t, want| try std.testing.expectEqual(want, t.real);
}

/// The `n`th object (from 0) `vpi_iterate(tag, scope)` yields.
fn nth(tag: c_int, scope: root.vpiHandle, n: usize) ?*anyopaque {
    const itr = iterate.vpi_iterate(tag, scope);
    defer _ = root.vpi_free_object(itr);
    for (0..n) |_| _ = iterate.vpi_scan(itr);
    return iterate.vpi_scan(itr);
}

test "§12.29: a delay that is NaN, infinite or negative is refused, and the held one stays" {
    var h: run.Harness = undefined;
    try h.init(
        \\`timescale 1ns/1ns
        \\module leaf(a, y); input a; output y; buf (y, a);
        \\  specify (a => y) = 5; endspecify
        \\endmodule
        \\module top; reg r; wire n, z; leaf first_cell(r, n); leaf second_cell(n, z); endmodule
    );
    defer h.deinit();
    const first_cell = handle.vpi_handle_by_name("top.first_cell", null);
    const second_cell = handle.vpi_handle_by_name("top.second_cell", null);
    const path = nth(code.vpiModPath, first_cell, 0) orelse return error.TestUnexpectedResult;
    // first_cell's output `y` into second_cell's input `a`.
    const imp = systf.vpi_handle_multi(systf.vpiInterModPath, nth(root.vpiPort, first_cell, 1), nth(root.vpiPort, second_cell, 0)) orelse return error.TestUnexpectedResult;
    var da: [3]Time = undefined;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1 }) |bad| {
        // A module path: one delay. An inter-module path: two.
        da = .{ scaled(bad), scaled(bad), scaled(bad) };
        var dl = delayOf(&da, 1, callback.vpiScaledRealTime);
        delays.vpi_put_delays(path, &dl);
        try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
        dl.no_of_delays = 2;
        delays.vpi_put_delays(imp, &dl);
        try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    }
    var dl = delayOf(&da, 1, callback.vpiScaledRealTime);
    delays.vpi_get_delays(path, &dl);
    try std.testing.expectEqual(@as(f64, 5), da[0].real);
    dl.no_of_delays = 2;
    delays.vpi_get_delays(imp, &dl);
    try std.testing.expectEqual(@as(f64, 0), da[0].real);
}
