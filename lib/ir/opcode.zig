//! IR facts about each `Mir.Opcode`, one row per opcode: operand class, result
//! type, LRM domain obligation (Tables 4-14/4-15), comparison relation and
//! constant fold. `table` is a `std.EnumArray`, so a new opcode does not
//! compile until its row exists. Target spellings live in
//! `lib/device/codegen/opcode_zig.zig`: lib/ir does not know the target is Zig.
//!
//! LRM clauses this file's code cites: §2.7, §3.2, §4.2, §4.2.1.1, §4.2.1.2,
//! §4.2.1.3, §4.2.4, §4.2.5, §4.2.7, §4.2.8, §4.2.9, §4.2.11, §4.3.1, §4.3.2.

const std = @import("std");
const value_fold = @import("kernels").fold;
const Const = value_fold.Const;
const Mir = @import("mir.zig");
const Opcode = Mir.Opcode;

/// LRM Tables 4-14 / 4-15 domains. The operand of each must be proven in-domain
/// (else compile error), except the "All x" group which governs float mode only.
pub const Domain = enum {
    all, // exp, expm1, sinh, cosh, tanh, sin, cos, floor, ceil, min, max, abs; §4.3.1/§4.3.2
    positive, // ln, log10                                   §4.3.1  (x > 0)
    gt_neg_one, // ln1p                                       §4.3.1  (x > -1)
    non_negative, // sqrt                                     §4.3.1  (x >= 0)
    unit_closed, // asin, acos                                §4.3.2  (-1 <= x <= 1)
    unit_open, // atanh                                       §4.3.2  (-1 < x < 1)
    ge_one, // acosh                                          §4.3.2  (x >= 1)
    nonzero_divisor, // '/', '%'                              §4.2 / §4.3.1
    tan_poles, // tan: x != n(π/2), n odd                     §4.3.2
    pow_sign, // pow(x,y) sign rules                          §4.3.1 Table 4-14
};

/// `lhs REL rhs` for the twelve comparison opcodes (`Info.rel`).
const Relation = enum { lt, le, gt, ge, eq, ne };

/// How the one constant kernel (`kernels.fold`) folds an opcode.
/// No default: a new opcode states its fold or does not compile.
pub const Fold = union(enum) {
    /// Not a value of its operands: a latch, or a class `fold` never sees
    /// (`select`, `phi` and `call` are the walker's to resolve).
    none,
    /// `opt_barrier`: the operand, unchanged.
    identity,
    /// §4.2.1.2 integer→real (`if_cast`).
    to_real,
    /// §4.2.1.1 real→integer, rounding, ties away from zero (`fi_cast`).
    /// Saturating and NaN→0 (`lossyCast`): the rule codegen emits.
    to_int,
    unary: Kernel(value_fold.UnaryOp),
    binary: Kernel(value_fold.BinaryOp),
    math: Kernel(value_fold.MathFn),
};

/// One kernel operation. The operands are first converted to the opcode's
/// type (`int` or real) because a MIR opcode, unlike a source operator,
/// already names it: `fadd` is real whatever its operands folded to. `wrap`
/// applies §3.2's 32 bits to the result where the device does (`wrap32`);
/// `+ - * << /` and `**` already wrap in the kernel.
pub fn Kernel(comptime Op: type) type {
    return struct { f: Op, int: bool = false, wrap: bool = false };
}

/// One row of `table`.
pub const Info = struct {
    /// Operand shape; drives `Mir.instData` decoding.
    class: Mir.OpClass,
    /// The result is a §3.2 integer rather than a real. Relational, equality
    /// and logical operators yield integer 0/1 (§4.2.5, §4.2.7, §4.2.8).
    int: bool = false,
    /// The result is 0 or 1: the relational, equality and logical operators.
    bool01: bool = false,
    /// A predicate the prover's `condFacts` can mine and if-conversion's
    /// `peelToBool` may peel: the §4.2.5/§4.2.7 comparisons and `!`. Not `&&`
    /// and `||`, which are 0/1 but carry no fact about an operand.
    predicate: bool = false,
    /// The §4.2.4/§4.2.5 relation a comparison tests, real or integer alike;
    /// null for every other opcode. The prover's `condFacts` mines it.
    rel: ?Relation = null,
    /// The LRM domain obligation. For the binary members it is on the SECOND
    /// operand (`nonzero_divisor`) or on BOTH (`pow_sign`); everything else
    /// constrains the single unary operand.
    ///
    /// Not `.fdiv`: §4.2.4 makes only `%`-by-zero an error. `x/0.0` is an
    /// exact IEEE ±inf and is legal, so it forfeits finiteness instead of
    /// rejecting (see the prover's `.fdiv` transfer). `ipow`'s one
    /// undefined corner is pow's: a zero base under a negative exponent (IEEE
    /// 1364-2005 Table 5-6's 'bx).
    domain: Domain = .all,
    /// Table 4-14/4-15 spelling for diagnostics (`log10` is Verilog-A's
    /// `log`); null means the tag name.
    label: ?[]const u8 = null,
    /// How `fold` evaluates it over constant operands.
    fold: Fold,
};

/// Per-opcode facts, total over `Mir.Opcode`.
pub const table = std.EnumArray(Opcode, Info).init(.{
    .fadd = .{ .class = .binary, .fold = .{ .binary = .{ .f = .add } } },
    .fsub = .{ .class = .binary, .fold = .{ .binary = .{ .f = .sub } } },
    .fmul = .{ .class = .binary, .fold = .{ .binary = .{ .f = .mul } } },
    .fdiv = .{ .class = .binary, .fold = .{ .binary = .{ .f = .div } } },
    .fmod = .{ .class = .binary, .domain = .nonzero_divisor, .fold = .{ .binary = .{ .f = .mod } } },
    .fneg = .{ .class = .unary, .fold = .{ .unary = .{ .f = .minus } } },
    .iadd = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .add, .int = true } } },
    .isub = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .sub, .int = true } } },
    .imul = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .mul, .int = true } } },
    .idiv = .{ .class = .binary, .int = true, .domain = .nonzero_divisor, .fold = .{ .binary = .{ .f = .div, .int = true } } },
    .imod = .{ .class = .binary, .int = true, .domain = .nonzero_divisor, .fold = .{ .binary = .{ .f = .mod, .int = true } } },
    .ineg = .{ .class = .unary, .int = true, .fold = .{ .unary = .{ .f = .minus, .int = true, .wrap = true } } },
    .flt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .lt, .fold = .{ .binary = .{ .f = .lt } } },
    .fgt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .gt, .fold = .{ .binary = .{ .f = .gt } } },
    .fle = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .le, .fold = .{ .binary = .{ .f = .le } } },
    .fge = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ge, .fold = .{ .binary = .{ .f = .ge } } },
    .feq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .eq, .fold = .{ .binary = .{ .f = .eq } } },
    .fne = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ne, .fold = .{ .binary = .{ .f = .neq } } },
    .ilt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .lt, .fold = .{ .binary = .{ .f = .lt, .int = true } } },
    .igt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .gt, .fold = .{ .binary = .{ .f = .gt, .int = true } } },
    .ile = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .le, .fold = .{ .binary = .{ .f = .le, .int = true } } },
    .ige = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ge, .fold = .{ .binary = .{ .f = .ge, .int = true } } },
    .ieq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .eq, .fold = .{ .binary = .{ .f = .eq, .int = true } } },
    .ine = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .rel = .ne, .fold = .{ .binary = .{ .f = .neq, .int = true } } },
    .logand = .{ .class = .binary, .int = true, .bool01 = true, .fold = .{ .binary = .{ .f = .logical_and } } },
    .logor = .{ .class = .binary, .int = true, .bool01 = true, .fold = .{ .binary = .{ .f = .logical_or } } },
    .lognot = .{ .class = .unary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .unary = .{ .f = .logical_not } } },
    .bitand = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_and, .int = true } } },
    .bitor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_or, .int = true } } },
    .bitxor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_xor, .int = true } } },
    .bitxnor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_xnor, .int = true } } },
    .bitnot = .{ .class = .unary, .int = true, .fold = .{ .unary = .{ .f = .bit_not, .int = true } } },
    .shl = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .shl, .int = true } } },
    .shr = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .shr, .int = true } } },
    .sqrt = .{ .class = .unary, .domain = .non_negative, .label = "sqrt()", .fold = .{ .math = .{ .f = .sqrt } } },
    .exp = .{ .class = .unary, .fold = .{ .math = .{ .f = .exp } } },
    .expm1 = .{ .class = .unary, .fold = .{ .math = .{ .f = .expm1 } } },
    .ln = .{ .class = .unary, .domain = .positive, .label = "ln()", .fold = .{ .math = .{ .f = .ln } } },
    .ln1p = .{ .class = .unary, .domain = .gt_neg_one, .label = "ln1p()", .fold = .{ .math = .{ .f = .ln1p } } },
    .log10 = .{ .class = .unary, .domain = .positive, .label = "log()", .fold = .{ .math = .{ .f = .log } } },
    .pow = .{ .class = .binary, .domain = .pow_sign, .label = "pow()", .fold = .{ .math = .{ .f = .pow } } },
    .hypot = .{ .class = .binary, .fold = .{ .math = .{ .f = .hypot } } },
    .floor = .{ .class = .unary, .fold = .{ .math = .{ .f = .floor } } },
    .ceil = .{ .class = .unary, .fold = .{ .math = .{ .f = .ceil } } },
    .fabs = .{ .class = .unary, .fold = .{ .math = .{ .f = .abs } } },
    .fmin = .{ .class = .binary, .fold = .{ .math = .{ .f = .min } } },
    .fmax = .{ .class = .binary, .fold = .{ .math = .{ .f = .max } } },
    .iabs = .{ .class = .unary, .int = true, .fold = .{ .math = .{ .f = .abs, .int = true, .wrap = true } } },
    .imin = .{ .class = .binary, .int = true, .fold = .{ .math = .{ .f = .min, .int = true } } },
    .imax = .{ .class = .binary, .int = true, .fold = .{ .math = .{ .f = .max, .int = true } } },
    .ipow = .{ .class = .binary, .int = true, .domain = .pow_sign, .fold = .{ .binary = .{ .f = .pow, .int = true } } },
    .sin = .{ .class = .unary, .fold = .{ .math = .{ .f = .sin } } },
    .cos = .{ .class = .unary, .fold = .{ .math = .{ .f = .cos } } },
    .tan = .{ .class = .unary, .domain = .tan_poles, .label = "tan()", .fold = .{ .math = .{ .f = .tan } } },
    .asin = .{ .class = .unary, .domain = .unit_closed, .label = "asin()", .fold = .{ .math = .{ .f = .asin } } },
    .acos = .{ .class = .unary, .domain = .unit_closed, .label = "acos()", .fold = .{ .math = .{ .f = .acos } } },
    .atan = .{ .class = .unary, .fold = .{ .math = .{ .f = .atan } } },
    .atan2 = .{ .class = .binary, .fold = .{ .math = .{ .f = .atan2 } } },
    .sinh = .{ .class = .unary, .fold = .{ .math = .{ .f = .sinh } } },
    .cosh = .{ .class = .unary, .fold = .{ .math = .{ .f = .cosh } } },
    .tanh = .{ .class = .unary, .fold = .{ .math = .{ .f = .tanh } } },
    .asinh = .{ .class = .unary, .fold = .{ .math = .{ .f = .asinh } } },
    .acosh = .{ .class = .unary, .domain = .ge_one, .label = "acosh()", .fold = .{ .math = .{ .f = .acosh } } },
    .atanh = .{ .class = .unary, .domain = .unit_open, .label = "atanh()", .fold = .{ .math = .{ .f = .atanh } } },
    .fi_cast = .{ .class = .unary, .int = true, .fold = .to_int },
    .if_cast = .{ .class = .unary, .fold = .to_real },
    .opt_barrier = .{ .class = .unary, .fold = .identity },
    .dstop = .{ .class = .unary, .fold = .identity },
    .path_prev = .{ .class = .unary, .fold = .none },
    .path_acc = .{ .class = .unary, .fold = .none },
    .select = .{ .class = .ternary, .fold = .none },
    // §3.2.2 memory-backed arrays: an element is not a value of the index's
    // operands, so nothing folds; an `iload` is a §3.2 integer.
    .anew = .{ .class = .anew, .fold = .none },
    .fload = .{ .class = .load, .fold = .none },
    .iload = .{ .class = .load, .int = true, .fold = .none },
    .store = .{ .class = .store, .fold = .none },
    .phi = .{ .class = .phi, .fold = .none },
    .branch = .{ .class = .branch, .fold = .none },
    .jump = .{ .class = .jump, .fold = .none },
    .call = .{ .class = .call, .fold = .none },
});

/// Returns `op`'s row of `table`.
pub fn get(op: Opcode) Info {
    return table.get(op);
}

/// Returns `op` over already-folded operands, through the one constant kernel: the
/// per-instruction step every MIR folder shares (`analysis.foldConst`,
/// `lower/contrib.scanFinite`). Null when `op` is not a constant operation or
/// the kernel declines (a zero integer divisor, `0 ** -1`). `args` holds one
/// folded operand per operand of `op` (one for a unary, two for a binary).
/// Asserts that `args.len` is that operand count for every opcode that
/// folds (a `.none` row reads no operand and takes any slice).
pub fn fold(op: Opcode, args: []const Const) ?Const {
    return switch (table.get(op).fold) {
        .none => null,
        .identity => blk: {
            std.debug.assert(args.len == 1);
            break :blk args[0];
        },
        // §4.2.1.1/§4.2.1.2 convert a number; `asReal` would read a string as 0.
        .to_real => blk: {
            std.debug.assert(args.len == 1);
            break :blk if (args[0] == .str) null else .{ .real = args[0].asReal() };
        },
        .to_int => blk: {
            std.debug.assert(args.len == 1);
            break :blk if (args[0] == .str) null else .{ .int = std.math.lossyCast(i64, @round(args[0].asReal())) };
        },
        .unary => |k| blk: {
            std.debug.assert(args.len == 1);
            break :blk wrapped(k.wrap, value_fold.unary(k.f, as(k.int, args[0]) orelse return null));
        },
        .binary => |k| blk: {
            std.debug.assert(args.len == 2);
            break :blk wrapped(k.wrap, value_fold.binary(
                k.f,
                as(k.int, args[0]) orelse return null,
                as(k.int, args[1]) orelse return null,
                null,
            ));
        },
        .math => |k| blk: {
            std.debug.assert(args.len == k.f.arity());
            var buf: [2]Const = undefined;
            for (args, 0..) |a, i| buf[i] = as(k.int, a) orelse return null;
            break :blk wrapped(k.wrap, value_fold.math(k.f, buf[0..args.len]));
        },
    };
}

/// A folded operand in the opcode's type. An integer from a real is
/// `fi_cast`'s rounding; a string is not an operand of any opcode.
fn as(int: bool, c: Const) ?Const {
    if (c == .str) return null;
    if (!int) return .{ .real = c.asReal() };
    return .{ .int = switch (c) {
        .int => |i| i,
        .real => |r| std.math.lossyCast(i64, @round(r)),
        .str => unreachable,
    } };
}

fn wrapped(wrap: bool, r: ?Const) ?Const {
    const c = r orelse return null;
    return if (wrap and c == .int) .{ .int = value_fold.wrap32(c.int) } else c;
}

test "fold: an opcode's type, not its operands', decides the kernel's rule" {
    const i = struct {
        fn c(v: i64) Const {
            return .{ .int = v };
        }
    }.c;
    // `fdiv` is real division even over two integers; `idiv` truncates.
    try std.testing.expectEqual(@as(f64, 3.5), fold(.fdiv, &.{ i(7), i(2) }).?.real);
    try std.testing.expectEqual(@as(i64, 3), fold(.idiv, &.{ i(7), i(2) }).?.int);
    try std.testing.expectEqual(@as(?Const, null), fold(.idiv, &.{ i(7), i(0) }));
    // §3.2: `~` and unary minus at 32 bits.
    try std.testing.expectEqual(@as(i64, -2147483648), fold(.ineg, &.{i(-2147483648)}).?.int);
    try std.testing.expectEqual(@as(i64, -1), fold(.bitnot, &.{i(0)}).?.int);
    // §4.3.2 folds, and `fi_cast` rounds half away from zero.
    try std.testing.expectEqual(@sin(@as(f64, 0.5)), fold(.sin, &.{.{ .real = 0.5 }}).?.real);
    try std.testing.expectEqual(@as(i64, -3), fold(.fi_cast, &.{.{ .real = -2.5 }}).?.int);
    try std.testing.expectEqual(@as(?Const, null), fold(.path_prev, &.{.{ .real = 1 }}));
}

/// Returns the diagnostic spelling of `op` (see `Info.label`).
pub fn label(op: Opcode) []const u8 {
    return table.get(op).label orelse @tagName(op);
}

test "opcode: each row's flags agree with the LRM typing and its fold's shape" {
    for (std.enums.values(Opcode)) |op| {
        errdefer std.debug.print("opcode `{s}`\n", .{@tagName(op)});
        const info = table.get(op);
        // §4.2.5/§4.2.7/§4.2.8: a 0/1 result is an integer, and only a 0/1
        // result is a predicate.
        if (info.bool01) try std.testing.expect(info.int);
        if (info.predicate) try std.testing.expect(info.bool01);
        // A relation is exactly a comparison: every predicate but `!`.
        try std.testing.expectEqual(info.predicate and op != .lognot, info.rel != null);
        // A label exists to name a domain error.
        if (info.label != null) try std.testing.expect(info.domain != .all);
        // The kernel a row folds through takes as many operands as its class.
        switch (info.fold) {
            .unary, .identity, .to_real, .to_int => try std.testing.expectEqual(Mir.OpClass.unary, info.class),
            .binary => try std.testing.expectEqual(Mir.OpClass.binary, info.class),
            .math => |k| try std.testing.expectEqual(if (k.f.arity() == 1) Mir.OpClass.unary else .binary, info.class),
            .none => {},
        }
        try std.testing.expectEqual(info.class, Mir.opClass(op));
        try std.testing.expectEqual(info.int, Mir.opIsInteger(op));
    }
}

test "fold: hand-derived values for every operator family" {
    const t = std.testing;
    const i = struct {
        fn c(v: i64) Const {
            return .{ .int = v };
        }
    }.c;
    const f = struct {
        fn c(v: f64) Const {
            return .{ .real = v };
        }
    }.c;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // §3.2 32-bit integers: 2147483647 + 1 = -2^31, and 65536 * 65536 = 2^32 ≡ 0.
    try t.expectEqual(@as(i64, -2147483648), fold(.iadd, &.{ i(2147483647), i(1) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.imul, &.{ i(65536), i(65536) }).?.int);
    try t.expectEqual(@as(i64, 2147483647), fold(.isub, &.{ i(-2147483648), i(1) }).?.int);
    // §4.2.4: integer `/` truncates toward zero (-7 / 2 = -3), `%` takes the
    // dividend's sign (-7 % 2 = -1), and a zero divisor has no value.
    try t.expectEqual(@as(i64, -3), fold(.idiv, &.{ i(-7), i(2) }).?.int);
    try t.expectEqual(@as(i64, -1), fold(.imod, &.{ i(-7), i(2) }).?.int);
    try t.expectEqual(@as(?Const, null), fold(.imod, &.{ i(1), i(0) }));
    // -2^31 / -1 overflows 32 bits and wraps back to -2^31.
    try t.expectEqual(@as(i64, -2147483648), fold(.idiv, &.{ i(-2147483648), i(-1) }).?.int);
    // Real `%`: -7.5 % 2 = -1.5; by zero has no value. Real `/` by zero is
    // IEEE +inf: the domain table leaves `fdiv` unrestricted.
    try t.expectEqual(@as(f64, -1.5), fold(.fmod, &.{ f(-7.5), f(2) }).?.real);
    try t.expectEqual(@as(?Const, null), fold(.fmod, &.{ f(1), f(0) }));
    try t.expectEqual(inf, fold(.fdiv, &.{ f(1), f(0) }).?.real);
    try t.expectEqual(@as(f64, -0.5), fold(.fneg, &.{f(0.5)}).?.real);
    // An integer opcode first rounds a real operand as `fi_cast` does:
    // 2.5 → 3, so 2.5 + 2 = 5; and 1.4 → 1 < 1.5 → 2.
    try t.expectEqual(@as(i64, 5), fold(.iadd, &.{ f(2.5), i(2) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.ilt, &.{ f(1.4), f(1.5) }).?.int);
    // §4.2.5/§4.2.7: comparisons are integer 0/1; NaN equals nothing.
    try t.expectEqual(@as(i64, 1), fold(.flt, &.{ i(1), f(1.5) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.feq, &.{ f(nan), f(nan) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.fne, &.{ f(nan), f(nan) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.ige, &.{ i(3), i(3) }).?.int);
    // §4.2.8 logical operators over any nonzero operand.
    try t.expectEqual(@as(i64, 1), fold(.logand, &.{ f(0.5), i(-3) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.logor, &.{ f(0), i(0) }).?.int);
    try t.expectEqual(@as(i64, 1), fold(.lognot, &.{f(0)}).?.int);
    // §4.2.9 bitwise: 1100 ^ 1010 = 0110, and xnor is its complement.
    try t.expectEqual(@as(i64, 0b0110), fold(.bitxor, &.{ i(0b1100), i(0b1010) }).?.int);
    try t.expectEqual(@as(i64, -7), fold(.bitxnor, &.{ i(0b1100), i(0b1010) }).?.int);
    try t.expectEqual(@as(i64, 0b1000), fold(.bitand, &.{ i(0b1100), i(0b1010) }).?.int);
    try t.expectEqual(@as(i64, 0b1110), fold(.bitor, &.{ i(0b1100), i(0b1010) }).?.int);
    // §4.2.11 at 32 bits: 1 << 31 is negative, 1 << 32 is 0, `>>` fills zeros.
    try t.expectEqual(@as(i64, -2147483648), fold(.shl, &.{ i(1), i(31) }).?.int);
    try t.expectEqual(@as(i64, 0), fold(.shl, &.{ i(1), i(32) }).?.int);
    try t.expectEqual(@as(i64, 0x7fff_ffff), fold(.shr, &.{ i(-1), i(1) }).?.int);
    // §4.3.1 "min(x,y) is equivalent to (x < y) ? x : y": a NaN x yields y,
    // a NaN y yields the NaN.
    try t.expectEqual(@as(f64, 1), fold(.fmin, &.{ f(nan), f(1) }).?.real);
    try t.expect(std.math.isNan(fold(.fmin, &.{ f(1), f(nan) }).?.real));
    try t.expectEqual(@as(f64, 1), fold(.fmax, &.{ f(nan), f(1) }).?.real);
    // Integer forms stay integer; |-2^31| wraps to -2^31 at 32 bits.
    try t.expectEqual(@as(i64, -2147483648), fold(.iabs, &.{i(-2147483648)}).?.int);
    try t.expectEqual(@as(i64, -3), fold(.imin, &.{ i(-3), i(2) }).?.int);
    try t.expectEqual(@as(i64, 2), fold(.imax, &.{ i(-3), i(2) }).?.int);
    // §4.2.1.3 integer `**`: 2 ** 10 = 1024, and 0 ** -1 has no value.
    try t.expectEqual(@as(i64, 1024), fold(.ipow, &.{ i(2), i(10) }).?.int);
    try t.expectEqual(@as(?Const, null), fold(.ipow, &.{ i(0), i(-1) }));
    // §4.3.1 math is real even over integers: sqrt(4) = 2.0 (IEEE sqrt is
    // exact here), hypot(3, 4) = 5, and Table 4-14's `log` is decimal.
    try t.expectEqual(@as(f64, 2), fold(.sqrt, &.{i(4)}).?.real);
    try t.expectApproxEqAbs(@as(f64, 5), fold(.hypot, &.{ i(3), i(4) }).?.real, 1e-15);
    try t.expectApproxEqAbs(@as(f64, 3), fold(.log10, &.{f(1000)}).?.real, 1e-15);
    // §4.2.1.1: ties away from zero, saturating, NaN → 0 (`lossyCast`).
    try t.expectEqual(@as(i64, 3), fold(.fi_cast, &.{f(2.5)}).?.int);
    try t.expectEqual(@as(i64, -3), fold(.fi_cast, &.{f(-2.5)}).?.int);
    try t.expectEqual(@as(i64, 0), fold(.fi_cast, &.{f(nan)}).?.int);
    try t.expectEqual(@as(i64, std.math.maxInt(i64)), fold(.fi_cast, &.{f(inf)}).?.int);
    try t.expectEqual(@as(f64, 7), fold(.if_cast, &.{i(7)}).?.real);
    // `opt_barrier` and `dstop` are the operand's value.
    try t.expectEqual(@as(f64, 0.25), fold(.opt_barrier, &.{f(0.25)}).?.real);
    try t.expectEqual(@as(i64, 4), fold(.dstop, &.{i(4)}).?.int);
    // Not values of their operands: latches, select, arrays, phis, calls.
    for ([_]Opcode{ .path_prev, .path_acc, .select, .anew, .fload, .iload, .store, .phi, .call }) |op|
        try t.expectEqual(@as(?Const, null), fold(op, &.{ f(1), f(1), f(1) }));
}

test "fold: a string is not an operand of any opcode" {
    // §4.2.1.1/§4.2.1.2 convert between integer and real only; lowering
    // converts a §2.7 string before it reaches an opcode, so a string here
    // has no value to fold to.
    const s: Const = .{ .str = "abc" };
    const one: Const = .{ .real = 1 };
    try std.testing.expectEqual(@as(?Const, null), fold(.fi_cast, &.{s}));
    try std.testing.expectEqual(@as(?Const, null), fold(.if_cast, &.{s}));
    try std.testing.expectEqual(@as(?Const, null), fold(.fadd, &.{ s, one }));
    try std.testing.expectEqual(@as(?Const, null), fold(.ieq, &.{ one, s }));
    try std.testing.expectEqual(@as(?Const, null), fold(.exp, &.{s}));
    try std.testing.expectEqual(@as(?Const, null), fold(.lognot, &.{s}));
}

test label {
    // Table 4-14's `log` is the decimal logarithm, MIR's `log10`.
    try std.testing.expectEqualStrings("log()", label(.log10));
    try std.testing.expectEqualStrings("sqrt()", label(.sqrt));
    try std.testing.expectEqualStrings("fadd", label(.fadd));
}
