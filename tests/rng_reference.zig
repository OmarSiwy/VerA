//! L3 RNG oracle (specification/TESTING.md §5): `rng_kernels.zig` against IEEE
//! 1364-2005 §17.9.3's C listing, compiled as C (`rng_reference.c`, built
//! with `-ffp-contract=off`) and linked into this test. In: seeds and each
//! distribution's argument range; out: the variate and the updated seed, two
//! calls deep, so a correct first value cannot hide a wrong seed walk.
//! Restored from `git show 4250899d^:tests/rng_reference.zig` (the commit
//! specification/TESTING.md and CLAUSE-AUDIT.md cite as 2cc1c08) onto today's kernels,
//! which add `$random` and `$dist_uniform` (the listing's `rtl_dist_uniform`)
//! and the seedless latch step `zRngNext`. Their domain refusals are
//! `rng_domains.zig`, a separate process because they panic.
//! Clauses: 1364-2005 §17.9.3 (Table 17-17); VAMS §9.13.1-§9.13.3.

const std = @import("std");
const k = @import("kernels").rng_kernels;

extern fn rng_reference(seed: *u32, op: u8, a: f64, b: f64) f64;

/// `rng_reference`'s `op`, one per listing routine.
const Op = enum(u8) { uniform, normal, exponential, poisson, chi_square, t, erlang, dist_uniform };

fn cOp(op: Op) u8 {
    return switch (op) {
        .uniform => 0,
        .normal => 1,
        .exponential => 2,
        .poisson => 3,
        .chi_square => 4,
        .t => 5,
        .erlang => 6,
        .dist_uniform => 7,
    };
}

fn draw(op: Op, next: bool, seed: i64, a: f64, b: f64) f64 {
    return switch (op) {
        .uniform => if (next) k.zRngUniformNext(seed, a, b) else k.zRngUniform(seed, a, b),
        .normal => if (next) k.zRngNormalNext(seed, a, b) else k.zRngNormal(seed, a, b),
        .exponential => if (next) k.zRngExponentialNext(seed, a) else k.zRngExponential(seed, a),
        .poisson => if (next) k.zRngPoissonNext(seed, a) else k.zRngPoisson(seed, a),
        .chi_square => if (next) k.zRngChiSquareNext(seed, a) else k.zRngChiSquare(seed, a),
        .t => if (next) k.zRngTNext(seed, a) else k.zRngT(seed, a),
        .erlang => if (next) k.zRngErlangNext(seed, a, b) else k.zRngErlang(seed, a, b),
        .dist_uniform => if (next) k.zRngIUniformNext(seed, a, b) else k.zRngIUniform(seed, a, b),
    };
}

/// Two successive calls on one seed variable: each variate against the
/// listing's, and the seed the `*Next` twin writes back against the seed the
/// listing left, exactly.
fn check(op: Op, seed: i32, a: f64, b: f64) !void {
    var state: u32 = @bitCast(seed);
    var current: i64 = seed;
    for (0..2) |_| {
        const expected = rng_reference(&state, cOp(op), a, b);
        const actual = draw(op, false, current, a, b);
        if (std.math.isNan(expected)) {
            try std.testing.expect(std.math.isNan(actual));
        } else if (std.math.isInf(expected) or op == .uniform or op == .poisson or op == .dist_uniform) {
            try std.testing.expectEqual(expected, actual);
        } else {
            // C libm and Zig's builtins may round log/exp/sqrt differently;
            // the operation order and the seed walk must still agree.
            try std.testing.expectApproxEqRel(expected, actual, 2e-14);
        }
        const next: i64 = @as(i32, @bitCast(state));
        try std.testing.expectEqual(@as(f64, @floatFromInt(next)), draw(op, true, current, a, b));
        current = next;
    }
}

const seeds = [_]i32{ -2147483648, -7, 0, 1, 7, 42, 2147483647 };

test "§17.9.3: every distribution's values and successive seeds match the compiled listing" {
    for (seeds) |seed| {
        try check(.uniform, seed, -2.25, 4.75);
        try check(.normal, seed, 2.5, 1.25);
        try check(.exponential, seed, 2.5, 0);
        try check(.poisson, seed, 2.5, 0);
        for ([_]f64{ 1, 2, 4096, 4097, 5001, 8192 }) |count| {
            try check(.chi_square, seed, count, 0);
            try check(.t, seed, count, 0);
            try check(.erlang, seed, count, 2.5);
        }
    }
}

test "§17.9.3 rtl_dist_uniform: $dist_uniform's three branches and $random's full range" {
    const min = -2147483648.0;
    const max = 2147483647.0;
    const ranges = [_][2]f64{
        .{ min, max }, // the third branch, which is $random
        .{ -5, 5 },
        .{ 0, 1 },
        .{ min, 0 },
        .{ 0, max }, // the second branch: end is LONG_MAX
        .{ min + 1, max },
        .{ max - 1, max },
        .{ min, min + 1 },
        .{ 7, 7 }, // start >= end: start, and the seed untouched
        .{ 10, -3 },
    };
    for (seeds) |seed| for (ranges) |r| try check(.dist_uniform, seed, r[0], r[1]);
    // $random is rtl_dist_uniform(seed, LONG_MIN, LONG_MAX) (Table 17-17).
    for (seeds) |seed| {
        var state: u32 = @bitCast(seed);
        const want = rng_reference(&state, cOp(.dist_uniform), min, max);
        try std.testing.expectEqual(want, k.zRngRand(seed));
        try std.testing.expectEqual(@as(f64, @floatFromInt(@as(i32, @bitCast(state)))), k.zRngRandNext(seed));
        // The seedless latch advances by one plain uniform() step.
        var one: u32 = @bitCast(seed);
        _ = rng_reference(&one, cOp(.uniform), 0, 1);
        try std.testing.expectEqual(@as(f64, @floatFromInt(@as(i32, @bitCast(one)))), k.zRngNext(seed));
    }
}

test "§17.9.3 seeded random seeds across every distribution's argument range" {
    var prng: std.Random.DefaultPrng = .init(0x179_3);
    const r = prng.random();
    for (0..400) |_| {
        const seed: i32 = @bitCast(r.int(u32));
        const start = (r.float(f64) - 0.5) * 2e6;
        try check(.uniform, seed, start, start + 1e-3 + r.float(f64) * 1e6);
        // Mean 0: a random mean can cancel the deviate to near zero, where a
        // one-ulp libm difference is no longer 2e-14 relative.
        try check(.normal, seed, 0, (r.float(f64) - 0.5) * 50);
        try check(.exponential, seed, 1e-3 + r.float(f64) * 1e3, 0);
        try check(.poisson, seed, 1e-3 + r.float(f64) * 40, 0);
        const count: f64 = @floatFromInt(r.intRangeAtMost(u32, 1, 300));
        try check(.chi_square, seed, count, 0);
        try check(.t, seed, count, 0);
        try check(.erlang, seed, count, 1e-3 + r.float(f64) * 100);
        const lo: f64 = @floatFromInt(r.int(i32));
        const hi: f64 = if (r.boolean()) @floatFromInt(r.int(i32)) else lo + @as(f64, @floatFromInt(r.intRangeAtMost(i32, 0, 100)));
        try check(.dist_uniform, seed, lo, @min(hi, 2147483647.0));
    }
}

test "§17.9.3 nonfinite corners keep the listing's value and seed instead of a fallback" {
    // The LCG step from this seed produces 0xffffffff, the listing's uniform
    // overshoot above 1, so df = 2 gives a negative chi-square value.
    const seed: i32 = @bitCast(@as(u32, 3023745526));
    try std.testing.expect(std.math.isNan(k.zRngT(seed, 2)));
    try std.testing.expect(k.zRngTNext(seed, 2) != -1);
    try check(.t, seed, 2, 0);
    // The specified product, underflow included.
    try std.testing.expect(std.math.isInf(k.zRngErlang(7, 8192, 3)));
    try check(.erlang, 7, 8192, 3);
}
