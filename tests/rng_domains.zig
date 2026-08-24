//! The refusal half of `rng_reference.zig`: VAMS §9.13.2's domains ("shall be
//! greater than zero", real uniform's start below its end) and the listing's
//! integral count domain, each a run-time error ("an error shall be
//! reported") that ends the process, so each case is one run of this program
//! (build.zig runs ids 0-45 and wants exit 1 with the case's rule on
//! stderr). Case `id / 2` names the call; odd ids take the
//! `*Next` twin, so both public paths refuse before returning a value or a
//! changed seed. Exit 3: a value came back. Restored from
//! `git show 4250899d^:tests/rng_domains.zig`, with `zRngCheck`, the
//! unused-call effect, added (cases 20-22).

const std = @import("std");
const k = @import("kernels").rng_kernels;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.skip();
    const id = try std.fmt.parseInt(u8, args.next() orelse return 2, 10);
    const next = id & 1 != 0;
    const case = id / 2;
    const nan = std.math.nan(f64);
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
        // zRngCheck's rule bits: 1 positive a, 4 integral count a, 8 a < b.
        20 => k.zRngCheck(0, 1, -1, 0),
        21 => k.zRngCheck(0, 4, 2.5, 0),
        22 => k.zRngCheck(0, 8, 3, 3),
        else => return 2,
    };
    return 3; // Returning a fallback is a failed test.
}
