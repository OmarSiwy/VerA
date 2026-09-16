//! Exact decimal timescale factors and integer digital delay counts.
//! IEEE 1364-2005 §§4.8, 4.8.2, 9.7.1, 14.3.1 and 19.8.
const std = @import("std");

pub const Error = error{
    InvalidMagnitude,
    InvalidUnit,
    InvalidQuantum,
    PrecisionTooCoarse,
    GlobalPrecisionTooCoarse,
    DelayOverflow,
    NonFiniteDelay,
    NegativeRealDelay,
};

/// Decimal exponent in seconds, including all 18 legal directive operands.
pub const Quantum = enum(i5) {
    fs = -15,
    ten_fs = -14,
    hundred_fs = -13,
    ps = -12,
    ten_ps = -11,
    hundred_ps = -10,
    ns = -9,
    ten_ns = -8,
    hundred_ns = -7,
    us = -6,
    ten_us = -5,
    hundred_us = -4,
    ms = -3,
    ten_ms = -2,
    hundred_ms = -1,
    s = 0,
    ten_s = 1,
    hundred_s = 2,

    pub fn fromParts(magnitude: u8, unit: []const u8) Error!Quantum {
        const offset: i5 = switch (magnitude) {
            1 => 0,
            10 => 1,
            100 => 2,
            else => return error.InvalidMagnitude,
        };
        const units = std.StaticStringMap(i5).initComptime(.{
            .{ "s", 0 },   .{ "ms", -3 },  .{ "us", -6 },
            .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 },
        });
        return @enumFromInt((units.get(unit) orelse return error.InvalidUnit) + offset);
    }

    /// Bridge for the existing preprocessor's canonical binary64 constants.
    /// No tolerance, ratio, logarithm, or computed floating-point exponent.
    pub fn fromSeconds(seconds: f64) Error!Quantum {
        const decades = [_]f64{
            1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10,
            1e-9,  1e-8,  1e-7,  1e-6,  1e-5,  1e-4,
            1e-3,  1e-2,  1e-1,  1e0,   1e1,   1e2,
        };
        for (decades, 0..) |value, i| {
            if (seconds == value) return @enumFromInt(@as(i6, @intCast(i)) - 15);
        }
        return error.InvalidQuantum;
    }
};

/// Both factors are read together per delay conversion, and are at most 10^17.
/// Caller-owned immutable scope data; no allocation or timestamp storage here.
pub const Scale = struct {
    local_per_unit: u57,
    global_per_local: u57,

    pub fn init(unit: Quantum, precision: Quantum, global: Quantum) Error!Scale {
        const u: i6 = @intFromEnum(unit);
        const p: i6 = @intFromEnum(precision);
        const g: i6 = @intFromEnum(global);
        if (p > u) return error.PrecisionTooCoarse;
        if (g > p) return error.GlobalPrecisionTooCoarse;
        return .{
            .local_per_unit = power10(@intCast(u - p)),
            .global_per_local = power10(@intCast(p - g)),
        };
    }

    pub fn unsignedDelay(self: Scale, value: u64) Error!u64 {
        return self.globalTicks(try multiply(value, self.local_per_unit));
    }

    /// Procedural delay: negative integral values are unsigned 64-bit time values
    /// (§9.7.1), not zero. Scaling overflow is a diagnosed resource limit.
    pub fn signedDelay(self: Scale, value: i64) Error!u64 {
        return self.unsignedDelay(@bitCast(value));
    }

    /// Scale the evaluated binary64 value and round to local precision, then scale
    /// exactly to global ticks. See docs/digital-time.md for the numeric contract.
    pub fn realDelay(self: Scale, value: f64) Error!u64 {
        if (!std.math.isFinite(value)) return error.NonFiniteDelay;
        if (value < 0) return error.NegativeRealDelay;
        return self.globalTicks(try roundedLocal(value, self.local_per_unit));
    }

    /// Specify-path negative delays are zero (§14.3.1), unlike procedural delays.
    pub fn pathSignedDelay(self: Scale, value: i64) Error!u64 {
        return self.unsignedDelay(@intCast(@max(value, 0)));
    }

    pub fn pathRealDelay(self: Scale, value: f64) Error!u64 {
        if (!std.math.isFinite(value)) return error.NonFiniteDelay;
        return self.realDelay(@max(value, 0));
    }

    fn globalTicks(self: Scale, local: u64) Error!u64 {
        return multiply(local, self.global_per_local);
    }
};

fn power10(exponent: u5) u57 {
    var value: u57 = 1;
    for (0..exponent) |_| value *= 10;
    return value;
}

fn multiply(value: u64, factor: u57) Error!u64 {
    const result: u128 = @as(u128, value) * factor;
    return std.math.cast(u64, result) orelse error.DelayOverflow;
}

/// Conventional IEEE binary64 scaling followed by half-away-from-zero rounding.
/// Only this real-input boundary uses floating arithmetic; global scaling and
/// all integral-input conversions remain integer operations.
fn roundedLocal(value: f64, factor: u57) Error!u64 {
    const scaled = value * @as(f64, @floatFromInt(factor));
    const rounded = @round(scaled);
    if (!std.math.isFinite(rounded) or rounded >= 0x1p64) return error.DelayOverflow;
    return @intFromFloat(rounded);
}

const testing = std.testing;

test "all legal timescale magnitudes and suffixes map to exact decades" {
    const units = [_][]const u8{ "fs", "ps", "ns", "us", "ms", "s" };
    for (units, 0..) |suffix, i| {
        for ([_]u8{ 1, 10, 100 }, 0..) |mag, j| {
            const q = try Quantum.fromParts(mag, suffix);
            try testing.expectEqual(@as(i6, @intCast(i * 3 + j)) - 15, @as(i6, @intFromEnum(q)));
        }
    }
    try testing.expectError(error.InvalidMagnitude, Quantum.fromParts(2, "ns"));
    try testing.expectError(error.InvalidMagnitude, Quantum.fromParts(0, "s"));
    try testing.expectError(error.InvalidUnit, Quantum.fromParts(1, "NS"));
    try testing.expectError(error.InvalidUnit, Quantum.fromParts(1, "sec"));
    try testing.expectError(error.InvalidUnit, Quantum.fromParts(1, "as"));
}

test "preprocessor seconds bridge rejects noncanonical floating values" {
    try testing.expectEqual(Quantum.fs, try Quantum.fromSeconds(1e-15));
    try testing.expectEqual(Quantum.hundred_s, try Quantum.fromSeconds(100));
    try testing.expectEqual(Quantum.hundred_us, try Quantum.fromSeconds(1e-4));
    for ([_]f64{ 0, -1, 2e-9, 1e-16, std.math.inf(f64), std.math.nan(f64), @bitCast(@as(u64, @bitCast(@as(f64, 1e-9))) + 1) }) |bad|
        try testing.expectError(error.InvalidQuantum, Quantum.fromSeconds(bad));
}

test "local and global precision ordering is validated" {
    try testing.expectError(error.PrecisionTooCoarse, Scale.init(.ps, .ns, .fs));
    try testing.expectError(error.GlobalPrecisionTooCoarse, Scale.init(.ns, .ps, .ns));
    const largest = try Scale.init(.hundred_s, .fs, .fs);
    try testing.expectEqual(@as(u57, 100_000_000_000_000_000), largest.local_per_unit);
    try testing.expectEqual(@as(u64, 100_000_000_000_000_000), try largest.unsignedDelay(1));
}

test "integer delay counts stay exact past binary64 precision" {
    const identity = try Scale.init(.ns, .ns, .ns);
    try testing.expectEqual(@as(u64, 9_007_199_254_740_993), try identity.unsignedDelay(9_007_199_254_740_993));
    try testing.expectEqual(std.math.maxInt(u64), try identity.unsignedDelay(std.math.maxInt(u64)));
    const finer = try Scale.init(.ns, .ps, .fs);
    try testing.expectEqual(@as(u64, 7_000_000), try finer.unsignedDelay(7));
    try testing.expectEqual(@as(u64, 0), try finer.unsignedDelay(0));
    try testing.expectError(error.DelayOverflow, finer.unsignedDelay(std.math.maxInt(u64)));
}

test "real delays round locally before conversion to global ticks" {
    const scale = try Scale.init(.ten_ns, .ns, .ps);
    try testing.expectEqual(@as(u64, 16_000), try scale.realDelay(1.55)); // §19.8 example
    try testing.expectEqual(@as(u64, 13_000), try scale.realDelay(1.25)); // exact half, away
    try testing.expectEqual(@as(u64, 12_000), try scale.realDelay(1.24));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(0.03125));
    try testing.expectEqual(@as(u64, 1_000), try scale.realDelay(0.0625));
    const coarse = try Scale.init(.ns, .ns, .ps);
    try testing.expectEqual(@as(u64, 0), try coarse.realDelay(0.49));
    try testing.expectEqual(@as(u64, 1_000), try coarse.realDelay(0.5));
    try testing.expectEqual(@as(u64, 1_000), try coarse.realDelay(1.49));
}

test "real rounding distinguishes adjacent binary64 values at half ticks" {
    const scale = try Scale.init(.s, .s, .s);
    const half_bits: u64 = @bitCast(@as(f64, 0.5));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(@bitCast(half_bits - 1)));
    try testing.expectEqual(@as(u64, 1), try scale.realDelay(@bitCast(half_bits + 1)));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(@bitCast(@as(u64, 1))));
    try testing.expectEqual(@as(u64, 0), try scale.realDelay(-0.0));
    try testing.expectEqual(@as(u64, 9_007_199_254_740_992), try scale.realDelay(9_007_199_254_740_992));
    try testing.expectEqual(std.math.maxInt(u64) - 2047, try scale.realDelay(@bitCast(@as(u64, @bitCast(@as(f64, 0x1p64))) - 1)));
    try testing.expectError(error.DelayOverflow, scale.realDelay(0x1p64));
    try testing.expectError(error.DelayOverflow, scale.realDelay(std.math.floatMax(f64)));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(std.math.inf(f64)));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(-std.math.inf(f64)));
    try testing.expectError(error.NonFiniteDelay, scale.realDelay(std.math.nan(f64)));
}

test "binary64 scaling interpretation preserves conventional decimal-half rounding" {
    const scale = try Scale.init(.ten_ns, .ns, .ns);
    // The multiplication rounds these binary64 inputs to exact half ticks.
    // An exact rational reinterpretation would instead produce 1 and 14.
    try testing.expectEqual(@as(u64, 2), try scale.realDelay(0.15));
    try testing.expectEqual(@as(u64, 15), try scale.realDelay(1.45));
    const large = try Scale.init(.hundred_s, .fs, .fs);
    const next_one: f64 = @bitCast(@as(u64, @bitCast(@as(f64, 1))) + 1);
    try testing.expectEqual(@as(u64, 100_000_000_000_000_016), try large.realDelay(next_one));
    const global = try Scale.init(.hundred_s, .s, .fs);
    try testing.expectError(error.DelayOverflow, global.realDelay(1000));
}

test "negative procedural integers and negative path delays have different rules" {
    const scale = try Scale.init(.ns, .ns, .ns);
    try testing.expectEqual(std.math.maxInt(u64), try scale.signedDelay(-1));
    try testing.expectEqual(@as(u64, 1) << 63, try scale.signedDelay(std.math.minInt(i64)));
    try testing.expectEqual(@as(u64, 2), try scale.signedDelay(2));
    try testing.expectEqual(@as(u64, 0), try scale.pathSignedDelay(-1));
    try testing.expectEqual(@as(u64, 0), try scale.pathRealDelay(-0.5));
    try testing.expectError(error.NegativeRealDelay, scale.realDelay(-0.5));
    try testing.expectError(error.NonFiniteDelay, scale.pathRealDelay(-std.math.inf(f64)));
    const finer = try Scale.init(.ns, .ps, .ps);
    try testing.expectError(error.DelayOverflow, finer.signedDelay(-1));
}

test "dyadic real delays match independent rational rounding oracle across scale grid" {
    for (0..18) |unit_offset| {
        for (0..unit_offset + 1) |precision_offset| {
            const unit: Quantum = @enumFromInt(@as(i6, @intCast(unit_offset)) - 15);
            const precision: Quantum = @enumFromInt(@as(i6, @intCast(precision_offset)) - 15);
            const scale = try Scale.init(unit, precision, precision);
            for (0..257) |n| {
                const numerator: u128 = @as(u128, n) * scale.local_per_unit;
                const expected: u128 = (numerator + 128) / 256;
                try testing.expectEqual(@as(u64, @intCast(expected)), try scale.realDelay(@as(f64, @floatFromInt(n)) / 256));
            }
        }
    }
}
