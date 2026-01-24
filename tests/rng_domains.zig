const std = @import("std");
const k = @import("kernels").rng_kernels;
var expected: []const u8 = "not configured";
pub const panic = std.debug.FullPanic(expectDomainError);

fn expectDomainError(message: []const u8, _: ?usize) noreturn {
    if (std.mem.indexOf(u8, message, expected) != null) std.process.exit(0);
    std.debug.print("unexpected panic: {s}\n", .{message});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const id = try std.fmt.parseInt(u8, args.next() orelse return 2, 10);
    const next = id & 1 != 0;
    const case = id / 2;
    const nan = std.math.nan(f64);
    expected = switch (case) {
        6, 7, 9, 10, 12, 13 => "fractional or out-of-range",
        17, 18, 19 => "start shall be smaller than end",
        else => "shall be greater than zero",
    };
    // Both public paths must reject before returning a value or changed seed.
    _ = switch (case) {
        0, 1, 2 => blk: {
            const mean: f64 = if (case == 0) 0 else if (case == 1) -1 else nan;
            break :blk if (next) k.zRngExponentialNext(7, mean) else k.zRngExponential(7, mean);
        },
        3, 4 => blk: {
            const mean: f64 = if (case == 3) 0 else nan;
            break :blk if (next) k.zRngPoissonNext(7, mean) else k.zRngPoisson(7, mean);
        },
        5, 6, 7 => blk: {
            const count: f64 = if (case == 5) 0 else if (case == 6) 1.5 else 2147483648;
            break :blk if (next) k.zRngChiSquareNext(7, count) else k.zRngChiSquare(7, count);
        },
        8, 9, 10 => blk: {
            const count: f64 = if (case == 8) 0 else if (case == 9) 1.5 else 2147483648;
            break :blk if (next) k.zRngTNext(7, count) else k.zRngT(7, count);
        },
        11, 12, 13 => blk: {
            const count: f64 = if (case == 11) 0 else if (case == 12) 1.5 else 2147483648;
            break :blk if (next) k.zRngErlangNext(7, count, 1) else k.zRngErlang(7, count, 1);
        },
        14, 15, 16 => blk: {
            const mean: f64 = if (case == 14) 0 else if (case == 15) -1 else nan;
            break :blk if (next) k.zRngErlangNext(7, 2, mean) else k.zRngErlang(7, 2, mean);
        },
        17, 18, 19 => blk: {
            const end: f64 = if (case == 17) 1 else if (case == 18) 0 else nan;
            break :blk if (next) k.zRngUniformNext(7, 1, end) else k.zRngUniform(7, 1, end);
        },
        else => return 2,
    };
    return 1; // Returning a fallback is a failed test.
}
