//! IR facts about each `Mir.Opcode`, one row per opcode.
//!
//! `table` is a `std.EnumArray`, so it is total by construction: add an opcode
//! to `Mir.Opcode` and this file stops compiling until its row exists. That is
//! the point. fix-lower's `.ipow` had to be found by hand at seven sites while
//! a score of `else =>` arms took a default silently; here it is one row.
//!
//! IR facts only. `lib/ir` does not know the target is Zig (analysis.zig's
//! header), so the Zig spellings of an opcode are the backend's table, not a
//! column here.
//!
//! DOD: comptime rows in `.rodata`, read with one indexed load. No allocation.

const std = @import("std");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Const = constfold.Const;
const Mir = @import("mir.zig");
const Opcode = Mir.Opcode;

/// LRM Tables 4-14 / 4-15 domains. The operand of each must be proven in-domain
/// (else compile error), EXCEPT the "All x" group which governs float mode only.
pub const Domain = enum {
    all, // exp, expm1, sinh, cosh, tanh, sin, cos, floor, ceil, min, max, abs — §4.3.1/§4.3.2
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

/// How the one constant kernel (`frontend/constfold.zig`) folds an opcode.
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
    unary: Kernel(Ast.UnaryOp),
    binary: Kernel(Ast.BinaryOp),
    math: Kernel(constfold.MathFn),
};

/// One kernel operation. The operands are first converted to the opcode's
/// type — `int` or real — because a MIR opcode, unlike a source operator,
/// already names it: `fadd` is real whatever its operands folded to. `wrap`
/// applies §3.2's 32 bits to the result where the device does (`wrap32`);
/// `+ - * << /` and `**` already wrap in the kernel.
pub fn Kernel(comptime Op: type) type {
    return struct { f: Op, int: bool = false, wrap: bool = false };
}

pub const Info = struct {
    /// Operand shape; drives `Mir.instData` decoding.
    class: Mir.OpClass,
    /// The result is a §3.2 integer rather than a real. Relational, equality
    /// and logical operators yield integer 0/1 (§4.2.5, §4.2.7, §4.2.8).
    int: bool = false,
    /// The result is 0 or 1: the relational, equality and logical operators.
    bool01: bool = false,
    /// A predicate the prover's `condFacts` can mine and if-conversion's
    /// `peelToBool` may peel: the §4.2.5/§4.2.7 comparisons and `!`. NOT `&&`
    /// and `||`, which are 0/1 but carry no fact about an operand.
    predicate: bool = false,
    /// The LRM domain obligation. For the binary members it is on the SECOND
    /// operand (`nonzero_divisor`) or on BOTH (`pow_sign`); everything else
    /// constrains the single unary operand.
    ///
    /// NOT `.fdiv`: §4.2.4 makes ONLY `%`-by-zero an error. `x/0.0` is an
    /// exact IEEE ±inf and is spec-legal, so it must not reject — it forfeits
    /// finiteness instead (see the prover's `.fdiv` transfer). `ipow`'s one
    /// undefined corner is pow's: a zero base under a negative exponent (IEEE
    /// 1364-2005 Table 5-6's 'bx).
    domain: Domain = .all,
    /// Table 4-14/4-15 spelling for diagnostics (`log10` is Verilog-A's
    /// `log`); null means the tag name.
    label: ?[]const u8 = null,
    /// How `fold` evaluates it over constant operands.
    fold: Fold,
};

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
    .flt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .lt } } },
    .fgt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .gt } } },
    .fle = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .le } } },
    .fge = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .ge } } },
    .feq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .eq } } },
    .fne = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .neq } } },
    .ilt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .lt, .int = true } } },
    .igt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .gt, .int = true } } },
    .ile = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .le, .int = true } } },
    .ige = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .ge, .int = true } } },
    .ieq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .eq, .int = true } } },
    .ine = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .binary = .{ .f = .neq, .int = true } } },
    .logand = .{ .class = .binary, .int = true, .bool01 = true, .fold = .{ .binary = .{ .f = .logical_and } } },
    .logor = .{ .class = .binary, .int = true, .bool01 = true, .fold = .{ .binary = .{ .f = .logical_or } } },
    .lognot = .{ .class = .unary, .int = true, .bool01 = true, .predicate = true, .fold = .{ .unary = .{ .f = .logical_not } } },
    .bitand = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_and, .int = true, .wrap = true } } },
    .bitor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_or, .int = true, .wrap = true } } },
    .bitxor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_xor, .int = true, .wrap = true } } },
    .bitxnor = .{ .class = .binary, .int = true, .fold = .{ .binary = .{ .f = .bit_xnor, .int = true, .wrap = true } } },
    .bitnot = .{ .class = .unary, .int = true, .fold = .{ .unary = .{ .f = .bit_not, .int = true, .wrap = true } } },
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
    .path_prev = .{ .class = .unary, .fold = .none },
    .path_acc = .{ .class = .unary, .fold = .none },
    .select = .{ .class = .ternary, .fold = .none },
    .phi = .{ .class = .phi, .fold = .none },
    .branch = .{ .class = .branch, .fold = .none },
    .jump = .{ .class = .jump, .fold = .none },
    .call = .{ .class = .call, .fold = .none },
});

pub fn get(op: Opcode) Info {
    return table.get(op);
}

/// `op` over already-folded operands, through the one constant kernel: the
/// per-instruction step every MIR folder shares (`analysis.foldConst`,
/// `lower/contrib.scanFinite`). Null when `op` is not a constant operation or
/// the kernel declines (a zero integer divisor, `0 ** -1`).
pub fn fold(op: Opcode, args: []const Const) ?Const {
    return switch (table.get(op).fold) {
        .none => null,
        .identity => args[0],
        .to_real => .{ .real = args[0].asReal() },
        .to_int => .{ .int = std.math.lossyCast(i64, @round(args[0].asReal())) },
        .unary => |k| wrapped(k.wrap, constfold.unary(k.f, as(k.int, args[0]) orelse return null)),
        .binary => |k| wrapped(k.wrap, constfold.binary(
            k.f,
            as(k.int, args[0]) orelse return null,
            as(k.int, args[1]) orelse return null,
            null,
        )),
        .math => |k| blk: {
            var buf: [2]Const = undefined;
            for (args, 0..) |a, i| buf[i] = as(k.int, a) orelse return null;
            break :blk wrapped(k.wrap, constfold.math(k.f, buf[0..args.len]));
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
    return if (wrap and c == .int) .{ .int = constfold.wrap32(c.int) } else c;
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
    // §4.3.2 now folds (R4), and `fi_cast` rounds half away from zero.
    try std.testing.expectEqual(@sin(@as(f64, 0.5)), fold(.sin, &.{.{ .real = 0.5 }}).?.real);
    try std.testing.expectEqual(@as(i64, -3), fold(.fi_cast, &.{.{ .real = -2.5 }}).?.int);
    try std.testing.expectEqual(@as(?Const, null), fold(.path_prev, &.{.{ .real = 1 }}));
}

/// Diagnostic spelling of `op` — see `Info.label`.
pub fn label(op: Opcode) []const u8 {
    return table.get(op).label orelse @tagName(op);
}
