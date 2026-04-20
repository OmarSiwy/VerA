//! IEEE 1364-2005 four-state operators on one machine word, for a native
//! executable. std-only.
//!
//! In: operands of at most 64 bits as a `W`, their widths and signedness
//! known when the design is compiled (§5.5: every width is static). Out: the
//! value `Integer.Literal`'s operator of the same name computes — which is
//! the oracle the tests at the bottom compare against, bit for bit.
//!
//! Clauses: §5.1.5 arithmetic, §5.1.7 relational, §5.1.8 equality, §5.1.9
//! logical, §5.1.10 bitwise, §5.1.11 reduction, §5.1.12 shift, §5.1.13
//! conditional, Tables 5-12..5-21; §5.5.2 extension; §9.5.1 casez/casex.
const std = @import("std");

/// A value of at most 64 bits as two planes, VPI-encoded per bit: (v, x) =
/// 00/10/11/01 for 0/1/x/z. Bits at and above the width are 0 in both.
pub const W = struct { v: u64, x: u64 };

/// One bit, as `Integer.Bit` encodes it: `v | x << 1`.
pub const Bit = enum(u2) { zero = 0, one = 1, z = 2, x = 3 };

pub fn mask(comptime w: u32) u64 {
    comptime std.debug.assert(w >= 1 and w <= 64);
    return if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << w) - 1;
}

pub inline fn k(v: u64, x: u64) W {
    return .{ .v = v, .x = x };
}

fn allX(comptime w: u32) W {
    return .{ .v = mask(w), .x = mask(w) };
}

/// Bit 0.
pub inline fn low(a: W) Bit {
    return @enumFromInt(@as(u2, @intCast(a.v & 1)) | @as(u2, @intCast(a.x & 1)) << 1);
}

/// `Literal.resize`: truncate, or extend by `sign` (per plane, so a top x
/// or z replicates as itself).
pub inline fn rs(a: W, comptime from: u32, comptime to: u32, comptime sign: bool) W {
    if (to <= from or !sign) return .{ .v = a.v & mask(to), .x = a.x & mask(to) };
    const hi = ~mask(from) & mask(to);
    return .{
        .v = a.v | (hi & (0 -% ((a.v >> (from - 1)) & 1))),
        .x = a.x | (hi & (0 -% ((a.x >> (from - 1)) & 1))),
    };
}

/// A one-bit result in its context (`exec.scalarContext`).
pub inline fn ctx(b: Bit, comptime w: u32, comptime sign: bool) W {
    const n: u2 = @intFromEnum(b);
    return rs(.{ .v = n & 1, .x = n >> 1 }, 1, w, sign);
}

pub inline fn not(a: W, comptime w: u32) W {
    return .{ .v = (~a.v | a.x) & mask(w), .x = a.x };
}

/// Any unknown bit makes all of it x.
pub inline fn neg(a: W, comptime w: u32) W {
    const unk = 0 -% @as(u64, @intFromBool(a.x != 0));
    return .{ .v = ((0 -% a.v) | unk) & mask(w), .x = unk & mask(w) };
}

pub const Bitwise = enum { @"and", @"or", xor, xnor };

pub inline fn bitwise(comptime op: Bitwise, a: W, b: W, comptime w: u32) W {
    return switch (op) {
        .@"and" => blk: {
            const x = (a.x | b.x) & (a.v | a.x) & (b.v | b.x);
            break :blk .{ .v = (a.v & b.v) | x, .x = x };
        },
        .@"or" => blk: {
            const x = (a.x | b.x) & ~((a.v & ~a.x) | (b.v & ~b.x));
            break :blk .{ .v = a.v | b.v | x, .x = x };
        },
        .xor => .{ .v = (a.v ^ b.v) | a.x | b.x, .x = a.x | b.x },
        .xnor => .{ .v = (~(a.v ^ b.v) | a.x | b.x) & mask(w), .x = a.x | b.x },
    };
}

fn sext(v: u64, comptime w: u32) u64 {
    if (w == 64) return v;
    return v | (~mask(w) & (0 -% ((v >> (w - 1)) & 1)));
}

pub const Arith = enum { add, sub, mul, div, mod };

/// `Literal.arithmetic` at one word: any unknown bit, and `/` or `%` by 0,
/// is all x (§5.1.5).
pub inline fn arith(comptime op: Arith, a: W, b: W, comptime w: u32, comptime signed: bool) W {
    const av = if (signed) sext(a.v, w) else a.v;
    const bv = if (signed) sext(b.v, w) else b.v;
    const zero = (op == .div or op == .mod) and bv == 0;
    const unk = 0 -% @as(u64, @intFromBool((a.x | b.x) != 0 or zero));
    const d = bv | @intFromBool(bv == 0); // never divides by zero; `unk` covers it
    const r: u64 = switch (op) {
        .add => av +% bv,
        .sub => av -% bv,
        .mul => av *% bv,
        .div, .mod => if (!signed)
            (if (op == .div) av / d else av % d)
        else if (d == std.math.maxInt(u64))
            (if (op == .div) 0 -% av else 0)
        else
            @bitCast(if (op == .div) @divTrunc(@as(i64, @bitCast(av)), @as(i64, @bitCast(d))) else @rem(@as(i64, @bitCast(av)), @as(i64, @bitCast(d)))),
    };
    return .{ .v = (r | unk) & mask(w), .x = unk & mask(w) };
}

/// `Literal.power` at one word: the base in context, the exponent
/// self-determined (§5.1.5 Table 5-6).
pub fn pow(a: W, comptime w: u32, comptime signed: bool, e: W, comptime ew: u32, comptime esigned: bool) W {
    if (a.x != 0 or e.x != 0) return allX(w);
    const m = mask(w);
    const ev = e.v & mask(ew);
    if (ev == 0) return .{ .v = 1, .x = 0 };
    const negative = esigned and (ev >> (ew - 1)) & 1 == 1;
    const b = a.v & m;
    if (b == 0) return if (negative) allX(w) else .{ .v = 0, .x = 0 };
    if (b == 1 or (signed and b == m)) return .{ .v = if (b == 1 or ev & 1 == 0) 1 else m, .x = 0 };
    if (negative) return .{ .v = 0, .x = 0 };
    var result: u64 = 1;
    var base = b;
    var rest = ev;
    while (rest != 0) : (rest >>= 1) {
        if (rest & 1 == 1) result *%= base;
        base *%= base;
    }
    return .{ .v = result & m, .x = 0 };
}

pub const Shift = enum { left, right, arithmetic_left, arithmetic_right };

/// `Literal.shift`: an unknown amount is all x; an amount of at least the
/// width leaves only the fill (§5.1.12).
pub inline fn shift(comptime op: Shift, a: W, comptime w: u32, comptime signed: bool, b: W) W {
    if (b.x != 0) return allX(w);
    const fill = op == .arithmetic_right and signed;
    if (b.v >= w) return if (fill)
        .{ .v = 0 -% ((a.v >> (w - 1)) & 1) & mask(w), .x = 0 -% ((a.x >> (w - 1)) & 1) & mask(w) }
    else
        .{ .v = 0, .x = 0 };
    const n: u6 = @intCast(b.v);
    return switch (op) {
        .left, .arithmetic_left => .{ .v = (a.v << n) & mask(w), .x = (a.x << n) & mask(w) },
        .right, .arithmetic_right => if (fill) .{
            .v = @as(u64, @bitCast(@as(i64, @bitCast(sext(a.v, w))) >> n)) & mask(w),
            .x = @as(u64, @bitCast(@as(i64, @bitCast(sext(a.x, w))) >> n)) & mask(w),
        } else .{ .v = a.v >> n, .x = a.x >> n },
    };
}

pub const Relational = enum { lt, le, gt, ge };

/// Any unknown bit makes the relation x (§5.1.7).
pub inline fn rel(comptime op: Relational, a: W, b: W, comptime w: u32, comptime signed: bool) Bit {
    if ((a.x | b.x) != 0) return .x;
    const ord = if (signed)
        std.math.order(@as(i64, @bitCast(sext(a.v, w))), @as(i64, @bitCast(sext(b.v, w))))
    else
        std.math.order(a.v, b.v);
    return if (switch (op) {
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
    }) .one else .zero;
}

pub const Equality = enum { eq, neq, case_eq, case_neq };

/// Both operands already in their common type (§5.1.8).
pub inline fn eq(comptime op: Equality, a: W, b: W) Bit {
    const different = switch (op) {
        .case_eq, .case_neq => (a.v ^ b.v) | (a.x ^ b.x),
        .eq, .neq => (a.v ^ b.v) & ~(a.x | b.x),
    };
    const r: Bit = if (different != 0) .zero else switch (op) {
        .case_eq, .case_neq => .one,
        .eq, .neq => if ((a.x | b.x) != 0) .x else .one,
    };
    return if (op == .neq or op == .case_neq) invert(r) else r;
}

pub const Reduction = enum { @"and", nand, @"or", nor, xor, xnor };

pub inline fn reduce(comptime op: Reduction, a: W, comptime w: u32) Bit {
    const r: Bit = switch (op) {
        .@"and", .nand => if (~(a.v | a.x) & mask(w) != 0) .zero else if (a.x != 0) .x else .one,
        .@"or", .nor => if (a.v & ~a.x != 0) .one else if (a.x != 0) .x else .zero,
        .xor, .xnor => if (a.x != 0) .x else if (@popCount(a.v) & 1 == 1) .one else .zero,
    };
    return switch (op) {
        .nand, .nor, .xnor => invert(r),
        else => r,
    };
}

/// §5.1.9: any known 1 makes it true, even beside x or z.
pub inline fn truth(a: W) Bit {
    return if (a.v & ~a.x != 0) .one else if (a.x != 0) .x else .zero;
}

pub inline fn invert(b: Bit) Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

pub const Logical = enum { @"and", @"or" };

/// `Literal.logical` of two one-bit truths.
pub inline fn logical(comptime op: Logical, a: Bit, b: Bit) Bit {
    return switch (op) {
        .@"and" => if (a == .zero or b == .zero) .zero else if (a == .one and b == .one) .one else .x,
        .@"or" => if (a == .one or b == .one) .one else if (a == .zero and b == .zero) .zero else .x,
    };
}

/// §5.1.13 Table 5-21: under an ambiguous condition only matching known
/// bits survive. Both arms already in the context type.
pub inline fn cond(c: Bit, y: W, n: W) W {
    return switch (c) {
        .one => y,
        .zero => n,
        .x, .z => blk: {
            const x = y.x | n.x | (y.v ^ n.v);
            break :blk .{ .v = y.v | x, .x = x };
        },
    };
}

/// `{hi, lo}`, `lo` being `lw` bits wide.
pub inline fn join(hi: W, lo: W, comptime lw: u32) W {
    if (lw == 64) return lo;
    return .{ .v = hi.v << lw | lo.v, .x = hi.x << lw | lo.x };
}

/// The integer a self-determined index reads as, or null when it has an
/// unknown bit (`Literal.asInt`).
pub inline fn asInt(a: W, comptime w: u32, comptime signed: bool) ?i64 {
    if (a.x != 0) return null;
    return @bitCast(if (signed) sext(a.v, w) else a.v);
}

/// `exec.position` then `readSelect` of one bit: bit `index` of a vector
/// declared `[msb:lsb]`, x when the index is x/z or outside it (§5.2.1).
pub inline fn bitAt(a: W, index: ?i64, comptime msb: i64, comptime lsb: i64, comptime w: u32) W {
    const i = index orelse return .{ .v = 1, .x = 1 };
    const p = if (msb >= lsb) i - lsb else lsb - i;
    if (p < 0 or p >= w) return .{ .v = 1, .x = 1 };
    const n: u6 = @intCast(p);
    return .{ .v = (a.v >> n) & 1, .x = (a.x >> n) & 1 };
}

/// A constant part-select (`emit_expr.partPlace`): bit i is bit `i + shift`
/// of `a` where `valid` has bit i, else x.
pub inline fn part(a: W, comptime shift_: i64, comptime valid: u64, comptime w: u32) W {
    const v = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.v >> @intCast(shift_) else a.v << @intCast(-shift_);
    const x = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.x >> @intCast(shift_) else a.x << @intCast(-shift_);
    const holes = ~valid & mask(w);
    return .{ .v = (v & valid) | holes, .x = (x & valid) | holes };
}

/// The inverse of `part` for an assignment: `a`'s bits placed at `shift`,
/// under `m` (the slot bits the select names).
pub inline fn place(a: W, comptime shift_: i64, comptime m: u64) W {
    const v = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.v << @intCast(shift_) else a.v >> @intCast(-shift_);
    const x = if (shift_ >= 64 or shift_ <= -64) 0 else if (shift_ >= 0) a.x << @intCast(shift_) else a.x >> @intCast(-shift_);
    return .{ .v = v & m, .x = x & m };
}

/// `a` moved up to bit `p`: a one-bit value landing on a runtime bit-select.
pub inline fn up(a: W, p: u6) W {
    return .{ .v = a.v << p, .x = a.x << p };
}

/// The bit position a runtime bit-select writes, or null (`exec.position`).
pub inline fn pos(index: ?i64, comptime msb: i64, comptime lsb: i64, comptime w: u32) ?u6 {
    const i = index orelse return null;
    const p = if (msb >= lsb) i - lsb else lsb - i;
    return if (p < 0 or p >= w) null else @intCast(p);
}

/// §5.1.14 `{count{a}}`.
pub inline fn rep(a: W, comptime w: u32, comptime count: u32) W {
    var out: W = .{ .v = 0, .x = 0 };
    inline for (0..count) |_| out = join(out, a, w);
    return out;
}

/// §17.11 `$clog2` of a self-determined operand, x/z read as 0 (`exec`'s
/// `integerCeilingLog2`).
pub inline fn clog2(a: W, comptime w: u32) u64 {
    _ = w;
    if (a.x != 0 or a.v == 0) return 0;
    const length: u64 = 64 - @clz(a.v);
    return if (a.v & (a.v - 1) == 0) length - 1 else length;
}

pub const CaseKind = enum { normal, casez, casex };

/// §9.5 / §9.5.1: `case` is `===`; casez/casex skip z (and x) bits of
/// either side.
pub inline fn caseMatch(comptime kind: CaseKind, a: W, b: W) bool {
    const wild: u64 = switch (kind) {
        .normal => 0,
        .casex => a.x | b.x,
        .casez => (a.x & ~a.v) | (b.x & ~b.v),
    };
    return ((a.v ^ b.v) | (a.x ^ b.x)) & ~wild == 0;
}

// ---- tests: every kernel against `Integer.Literal` --------------------------

const Int = @import("frontend").Integer;

fn lit(a: std.mem.Allocator, v: W, w: u32, signed: bool) !Int.Literal {
    const planes = try a.alloc(u64, 2);
    planes[0] = v.v;
    planes[1] = v.x;
    return .{ .width = w, .sized = true, .signed = signed, .planes = planes };
}

fn same(want: Int.Literal, got: W) !void {
    try std.testing.expectEqual(want.values()[0], got.v);
    try std.testing.expectEqual(want.unknowns()[0], got.x);
}

fn bitOf(b: Int.Bit) Bit {
    return @enumFromInt(@intFromEnum(b));
}

fn check(comptime w: u32, comptime signed: bool, a: W, b: W) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const la = try lit(al, a, w, signed);
    const lb = try lit(al, b, w, signed);
    try same(try la.bitwiseNot(al), not(a, w));
    try same(try la.negate(al), neg(a, w));
    inline for (.{ .@"and", .@"or", .xor, .xnor }, .{ .and_bits, .or_bits, .xor_bits, .xnor_bits }) |op, iop|
        try same(try la.bitwise(al, iop, lb), bitwise(op, a, b, w));
    inline for (.{ .add, .sub, .mul, .div, .mod }, .{ .add, .subtract, .multiply, .divide, .remainder }) |op, iop|
        try same(try la.arithmetic(al, iop, lb), arith(op, a, b, w, signed));
    inline for (.{ .left, .right, .arithmetic_left, .arithmetic_right }) |op|
        try same(try la.shift(al, @field(Int.Shift, @tagName(op)), lb), shift(op, a, w, signed, b));
    try same(try la.power(al, lb), pow(a, w, signed, b, w, signed));
    inline for (.{ .lt, .le, .gt, .ge }, .{ .less, .less_equal, .greater, .greater_equal }) |op, iop|
        try std.testing.expectEqual(bitOf(la.relational(iop, lb)), rel(op, a, b, w, signed));
    inline for (.{ .eq, .neq, .case_eq, .case_neq }, .{ .equal, .not_equal, .case_equal, .case_not_equal }) |op, iop|
        try std.testing.expectEqual(bitOf(la.equality(iop, lb)), eq(op, a, b));
    inline for (.{ .@"and", .nand, .@"or", .nor, .xor, .xnor }, .{ .and_bits, .nand_bits, .or_bits, .nor_bits, .xor_bits, .xnor_bits }) |op, iop|
        try std.testing.expectEqual(bitOf(la.reduce(iop)), reduce(op, a, w));
    try std.testing.expectEqual(bitOf(la.truth()), truth(a));
    try same(try la.conditional(al, la, lb), cond(truth(a), a, b));
    inline for (.{ w, @min(w + 3, 64), 64 }) |to| {
        try same(try la.resize(al, to, if (signed) .sign else .zero), rs(a, w, to, signed));
    }
    const lab = try Int.Literal.concatenate(al, &.{ la, lb });
    if (2 * w <= 64) try same(lab, join(a, b, w));
}

fn randomW(rand: std.Random, comptime w: u32) W {
    // Mostly known, so arithmetic is exercised past its all-x early exit.
    const x = if (rand.uintLessThan(u8, 3) == 0) rand.int(u64) & mask(w) else 0;
    return .{ .v = rand.int(u64) & mask(w), .x = x };
}

test "every kernel equals Integer.Literal: all 4^w operand pairs for w in 1..3" {
    inline for (.{ 1, 2, 3 }) |w| inline for (.{ false, true }) |signed| {
        const n: u64 = @as(u64, 1) << (2 * w);
        for (0..n) |i| for (0..n) |j| {
            const a: W = .{ .v = i & mask(w), .x = (i >> w) & mask(w) };
            const b: W = .{ .v = j & mask(w), .x = (j >> w) & mask(w) };
            try check(w, signed, a, b);
        };
    };
}

test "every kernel equals Integer.Literal: random words at block-boundary widths" {
    var prng = std.Random.DefaultPrng.init(0x1364);
    const rand = prng.random();
    inline for (.{ 5, 31, 32, 33, 63, 64 }) |w| inline for (.{ false, true }) |signed| {
        for (0..2000) |_| try check(w, signed, randomW(rand, w), randomW(rand, w));
        // Small shift amounts and exponents, which random words never are.
        for (0..500) |_| try check(w, signed, randomW(rand, w), .{ .v = rand.uintLessThan(u64, w + 2), .x = 0 });
    };
}

test "casez/casex agree with the per-bit wildcard rule" {
    var prng = std.Random.DefaultPrng.init(0x951);
    const rand = prng.random();
    for (0..5000) |_| {
        const a = randomW(rand, 6);
        const b = randomW(rand, 6);
        inline for (.{ .casez, .casex }) |kind| {
            var want = true;
            for (0..6) |i| {
                const ab: u2 = @intCast((a.v >> @intCast(i)) & 1 | ((a.x >> @intCast(i)) & 1) << 1);
                const bb: u2 = @intCast((b.v >> @intCast(i)) & 1 | ((b.x >> @intCast(i)) & 1) << 1);
                const wild = ab == 2 or bb == 2 or (kind == .casex and (ab == 3 or bb == 3));
                if (!wild and ab != bb) want = false;
            }
            try std.testing.expectEqual(want, caseMatch(kind, a, b));
        }
        try std.testing.expectEqual(eq(.case_eq, a, b) == .one, caseMatch(.normal, a, b));
    }
}
