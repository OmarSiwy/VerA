const std = @import("std");
const k = @import("kernels").rng_kernels;
extern fn rng_reference(seed: *u32, op: u8, a: f64, b: f64) f64;

fn draw(op: u8, next: bool, seed: i64, a: f64, b: f64) f64 {
    return switch (op) {
        0 => if (next) k.zRngUniformNext(seed, a, b) else k.zRngUniform(seed, a, b),
        1 => if (next) k.zRngNormalNext(seed, a, b) else k.zRngNormal(seed, a, b),
        2 => if (next) k.zRngExponentialNext(seed, a) else k.zRngExponential(seed, a),
        3 => if (next) k.zRngPoissonNext(seed, a) else k.zRngPoisson(seed, a),
        4 => if (next) k.zRngChiSquareNext(seed, a) else k.zRngChiSquare(seed, a),
        5 => if (next) k.zRngTNext(seed, a) else k.zRngT(seed, a),
        6 => if (next) k.zRngErlangNext(seed, a, b) else k.zRngErlang(seed, a, b),
        else => unreachable,
    };
}

fn check(op: u8, seed: i32, a: f64, b: f64) !void {
    var state: u32 = @bitCast(seed);
    var current: i64 = seed;
    // The second call distinguishes a correct first value from correct inout
    // progression, including all rejection and count-dependent draws.
    for (0..2) |_| {
        const expected = rng_reference(&state, op, a, b);
        const actual = draw(op, false, current, a, b);
        if (std.math.isNan(expected)) {
            try std.testing.expect(std.math.isNan(actual));
        } else if (std.math.isInf(expected)) {
            try std.testing.expectEqual(expected, actual);
        } else if (op == 0 or op == 3) {
            try std.testing.expectEqual(expected, actual);
        } else {
            // C libm and Zig intrinsics may round transcendental operations
            // differently; the operation order and seed must still agree.
            try std.testing.expectApproxEqRel(expected, actual, 2e-14);
        }
        const next: i64 = @as(i32, @bitCast(state));
        try std.testing.expectEqual(@as(f64, @floatFromInt(next)), draw(op, true, current, a, b));
        current = next;
    }
}

test "distribution values and successive seeds match compiled IEEE reference" {
    for ([_]i32{ -2147483648, -7, 0, 1, 7, 42, 2147483647 }) |seed| {
        try check(0, seed, -2.25, 4.75);
        try check(1, seed, 2.5, 1.25);
        try check(2, seed, 2.5, 0);
        try check(3, seed, 2.5, 0);
        for ([_]f64{ 1, 2, 4096, 4097, 5001, 8192 }) |count| {
            try check(4, seed, count, 0);
            try check(5, seed, count, 0);
            try check(6, seed, count, 2.5);
        }
    }
}

test "reference nonfinite corners preserve value and seed instead of fallback" {
    // LCG step from this seed produces 0xffffffff, the listing's uniform
    // overshoot above 1. df=2 therefore gives a negative chi-square value.
    const seed: i32 = @bitCast(@as(u32, 3023745526));
    try std.testing.expect(std.math.isNan(k.zRngT(seed, 2)));
    try std.testing.expect(k.zRngTNext(seed, 2) != -1);
    try check(5, seed, 2, 0);
    // Keep the specified product, including its floating-point underflow.
    try std.testing.expect(std.math.isInf(k.zRngErlang(7, 8192, 3)));
    try check(6, 7, 8192, 3);
}
