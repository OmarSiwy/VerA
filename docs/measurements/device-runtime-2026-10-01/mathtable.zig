//! The math ULP/cycle table (docs/IMPLEMENTATION.md, "Host math"): max and
//! mean ulp against an f128 oracle (~2^-110 relative) and TSC ticks per call
//! for (a) VerA's previous routines (`@exp`/`@log` = compiler_rt, and
//! `std.math.pow`), (b) the system glibc's libm, dlopen'd for measurement
//! only, never linked into a device, and (c) `contract.gm` (ARM
//! optimized-routines design, fma-free). pow runs on the (x, y) pairs psp103's
//! evalQ/eval/q and transient actually passed (`--pow-trace FILE`, from
//! `math/dumptrace.py`), plus a synthetic spread.
//! Build: zig build-exe -OReleaseFast -lc --dep contract -Mroot=mathtable.zig
//!        -Mcontract=../../../tools/contract.zig
const std = @import("std");
const gm = @import("contract").gm;

const ln2q: f128 = 0x1.62e42fefa39ef35793c7673007e6p-1;
fn expQ(t: f128) f128 {
    const k = @round(t / ln2q);
    if (k > 1100) return std.math.inf(f128);
    if (k < -1200) return 0;
    const r = t - k * ln2q;
    var term: f128 = 1;
    var sum: f128 = 1;
    var n: f128 = 1;
    while (n < 36) : (n += 1) {
        term = term * r / n;
        sum += term;
    }
    return std.math.ldexp(sum, @intFromFloat(k));
}
fn logQ(x: f64) f128 {
    const fr = std.math.frexp(@as(f128, x));
    var m = fr.significand;
    var e: f128 = @floatFromInt(fr.exponent);
    if (m < 0.70710678) {
        m *= 2;
        e -= 1;
    }
    const u = (m - 1) / (m + 1);
    const uu = u * u;
    var term = u;
    var sum: f128 = 0;
    var k: f128 = 1;
    while (k < 100) : (k += 2) {
        sum += term / k;
        term *= uu;
    }
    return 2 * sum + e * ln2q;
}
fn ulp(got: f64, ref: f128) f64 {
    const rd: f64 = @floatCast(ref);
    if (std.math.isInf(rd)) return if (got == rd) 0 else 1e9;
    if (rd == 0 and got == 0) return 0;
    const e = if (rd == 0) -1074 else @max(std.math.ilogb(rd) - 52, -1074);
    return @floatCast(@abs(@as(f128, got) - ref) / std.math.ldexp(@as(f128, 1.0), e));
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

extern fn dlopen(?[*:0]const u8, c_int) ?*anyopaque;
extern fn dlsym(?*anyopaque, [*:0]const u8) ?*anyopaque;
var g_exp: *const fn (f64) callconv(.c) f64 = undefined;
var g_log: *const fn (f64) callconv(.c) f64 = undefined;
var g_pow: *const fn (f64, f64) callconv(.c) f64 = undefined;

fn oldExp(x: f64, _: f64) f64 {
    return @exp(x);
}
fn oldLog(x: f64, _: f64) f64 {
    return @log(x);
}
fn oldPow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}
fn gExp(x: f64, _: f64) f64 {
    return g_exp(x);
}
fn gLog(x: f64, _: f64) f64 {
    return g_log(x);
}
fn gPow(x: f64, y: f64) f64 {
    return g_pow(x, y);
}
fn nExp(x: f64, _: f64) f64 {
    return gm.armExp(x);
}
fn nLog(x: f64, _: f64) f64 {
    return gm.armLog(x);
}
fn nPow(x: f64, y: f64) f64 {
    return gm.armPow(x, y);
}

const Row = struct { max: f64 = 0, sum: f64 = 0, n: u64 = 0 };

fn accuracy(comptime f: anytype, xs: []const f64, ys: []const f64, refs: []const f128) Row {
    var r: Row = .{};
    for (xs, ys, refs) |x, y, q| {
        const e = ulp(f(x, y), q);
        r.max = @max(r.max, e);
        r.sum += e;
        r.n += 1;
    }
    return r;
}

/// TSC ticks per call: throughput (independent calls), min of 15 passes.
fn ticks(comptime f: anytype, xs: []const f64, ys: []const f64) f64 {
    var best: u64 = std.math.maxInt(u64);
    var sink: f64 = 0;
    for (0..15) |_| {
        const t = rdtsc();
        for (xs, ys) |x, y| sink += @call(.never_inline, f, .{ x, y });
        best = @min(best, rdtsc() - t);
    }
    std.mem.doNotOptimizeAway(sink);
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(xs.len));
}

/// TSC ticks per element of the `@Vector(4, f64)` form.
fn ticksV(comptime which: enum { exp, log }, xs: []const f64) f64 {
    var best: u64 = std.math.maxInt(u64);
    var sink: @Vector(4, f64) = @splat(0);
    for (0..15) |_| {
        const t = rdtsc();
        var i: usize = 0;
        while (i + 4 <= xs.len) : (i += 4) {
            const v: @Vector(4, f64) = xs[i..][0..4].*;
            sink += switch (which) {
                .exp => @call(.never_inline, gm.hexp, .{v}),
                .log => @call(.never_inline, gm.hlog, .{v}),
            };
        }
        best = @min(best, rdtsc() - t);
    }
    std.mem.doNotOptimizeAway(sink);
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(xs.len / 4 * 4));
}

fn line(name: []const u8, comptime fs: anytype, xs: []const f64, ys: []const f64, refs: []const f128, vec: ?f64) void {
    std.debug.print("| {s} |", .{name});
    inline for (fs) |f| {
        const a = accuracy(f, xs, ys, refs);
        std.debug.print(" {d:.4} / {d:.4} / {d:.1} |", .{ a.max, a.sum / @as(f64, @floatFromInt(a.n)), ticks(f, xs, ys) });
    }
    if (vec) |v| std.debug.print(" {d:.1} |\n", .{v}) else std.debug.print(" — |\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const h = dlopen("libm.so.6", 2) orelse return error.NoLibm;
    g_exp = @ptrCast(dlsym(h, "exp").?);
    g_log = @ptrCast(dlsym(h, "log").?);
    g_pow = @ptrCast(dlsym(h, "pow").?);
    var it = init.minimal.args.iterate();
    _ = it.next();
    const n: usize = if (it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 100_000;
    const trace: ?[]const u8 = it.next();

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const xs = try gpa.alloc(f64, n);
    const ys = try gpa.alloc(f64, n);
    const refs = try gpa.alloc(f128, n);
    @memset(ys, 0);

    std.debug.print("| function, range | (a) VerA before: max / mean ulp / ticks | (b) glibc 2.42 | (c) new | (c) @Vector(4) ticks/elem |\n|---|---|---|---|---|\n", .{});
    for (xs, refs) |*x, *q| {
        x.* = r.float(f64) * 1454.0 - 745.0;
        q.* = expQ(x.*);
    }
    line("exp, x in [-745, 709]", .{ oldExp, gExp, nExp }, xs, ys, refs, ticksV(.exp, xs));
    for (xs, refs) |*x, *q| {
        x.* = r.float(f64) * 125.0 - 80.0;
        q.* = expQ(x.*);
    }
    line("exp, x in [-80, 45] (diode..psp103)", .{ oldExp, gExp, nExp }, xs, ys, refs, ticksV(.exp, xs));
    for (xs, refs) |*x, *q| {
        x.* = (r.float(f64) * 2.0 - 1.0) * std.math.pow(f64, 2.0, -28.0 - r.float(f64) * 30.0);
        q.* = expQ(x.*);
    }
    line("exp, |x| < 2^-28 (decay factors)", .{ oldExp, gExp, nExp }, xs, ys, refs, ticksV(.exp, xs));
    for (xs, refs) |*x, *q| {
        x.* = @bitCast((r.int(u64) % 0x7fefffffffffffff) + 1);
        q.* = logQ(x.*);
    }
    line("log, x random bits in (0, inf)", .{ oldLog, gLog, nLog }, xs, ys, refs, ticksV(.log, xs));
    for (xs, refs) |*x, *q| {
        x.* = @bitCast(r.int(u64) % 0x000fffffffffffff + 1);
        q.* = logQ(x.*);
    }
    line("log, subnormal x", .{ oldLog, gLog, nLog }, xs, ys, refs, null);
    for (xs, refs) |*x, *q| {
        x.* = 0.9 + r.float(f64) * 0.2;
        q.* = logQ(x.*);
    }
    line("log, x in [0.9, 1.1]", .{ oldLog, gLog, nLog }, xs, ys, refs, ticksV(.log, xs));
    for (xs, ys, refs) |*x, *y, *q| {
        x.* = std.math.pow(f64, 10.0, r.float(f64) * 15.0 - 3.0);
        y.* = r.float(f64) * 21.0 - 3.0;
        q.* = expQ(@as(f128, y.*) * logQ(x.*));
    }
    line("pow, x in [1e-3, 1e12], y in [-3, 18]", .{ oldPow, gPow, nPow }, xs, ys, refs, null);
    if (trace) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 30));
        const v: []align(1) const f64 = std.mem.bytesAsSlice(f64, data);
        var m: usize = 0;
        var i: usize = 0;
        while (i + 3 <= v.len and m < n) : (i += 3) if (v[i] == 2.0 and v[i + 1] > 0) {
            xs[m] = v[i + 1];
            ys[m] = v[i + 2];
            refs[m] = expQ(@as(f128, ys[m]) * logQ(xs[m]));
            m += 1;
        };
        line("pow, psp103's own (x, y) pairs", .{ oldPow, gPow, nPow }, xs[0..m], ys[0..m], refs[0..m], null);
    }
}
