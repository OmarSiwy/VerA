//! §4.2 constant_expression: the one place its typing rules are written.
//!
//! In: an expression AST (or, for the MIR folder, one operator and its folded
//! operands). Out: a `Const`, or null when the expression is not constant.
//! Pure: no allocation, no symbol table. What the structure cannot answer — an
//! identifier, and `>>>`'s signedness — is asked of the caller's `env`.
//!
//! The rules, and the clause each comes from:
//!   §4.2.1.3  an operator is integer iff BOTH operands are integer.
//!   §3.2      integer `+ - *` (and `<<`, `**`) wrap at 32 bits: `wrap32`.
//!   §4.2.4    integer `/` truncates toward zero; a zero divisor declines.
//!   Table 3-3 string relations compare bytes; a mixed pair declines.
//!   §4.2.12   `?:` is lazy: only the taken arm must fold.
//!
//! Lives in the frontend because it imports nothing but the AST, so the
//! parser, elaboration, lowering and the proof can all share it.

const std = @import("std");
const Ast = @import("ast.zig");

/// A folded constant (§4.2 constant_expression). Genvars (§3.5) and parameter
/// defaults live here so `for (i=0;i<N;i=i+1)` can unroll (§6.6.1).
pub const Const = union(enum) {
    int: i64,
    real: f64,
    str: []const u8,

    pub fn asReal(c: Const) f64 {
        return switch (c) {
            .int => |i| @floatFromInt(i),
            .real => |r| r,
            .str => 0,
        };
    }
    /// §4.2.1.1 real→integer rounds, ties away from zero — and says nothing
    /// about a real that has no nearest integer, because it never contemplates
    /// one. A NaN, an infinity, and anything past i64 are all in that hole.
    ///
    /// Returns null there rather than inventing a value. Any caller holding a
    /// real the USER wrote must go through this and diagnose; `asInt` below is
    /// only for operands already known to be in range.
    pub fn asIntExact(c: Const) ?i64 {
        return switch (c) {
            .int => |i| i,
            .real => |r| blk: {
                const v = @round(r);
                if (!std.math.isFinite(v)) break :blk null;
                // Compared against 2^63 and not maxInt(i64): 2^63 is exactly
                // representable as an f64 and maxInt(i64) is not, so rounding
                // the bound itself would let 2^63 through as "in range".
                if (v >= 9223372036854775808.0 or v < -9223372036854775808.0) break :blk null;
                break :blk @intFromFloat(v);
            },
            .str => 0,
        };
    }
    pub fn asInt(c: Const) i64 {
        // Saturating, NaN to zero. This MUST NOT be able to panic: a bare
        // `@intFromFloat` on an out-of-range double is illegal behavior, and it
        // used to abort the whole compilation — no diagnostic, and every other
        // error in the file lost with it — whenever a folded subscript or a
        // `$discontinuity` degree reached it as an infinity. The two paths that
        // can see such a value now call `asIntExact` and report; this fallback
        // is what remains for operands a range check has already passed.
        return c.asIntExact() orelse blk: {
            const r = c.asReal();
            if (std.math.isNan(r)) break :blk 0;
            break :blk if (r > 0) std.math.maxInt(i64) else std.math.minInt(i64);
        };
    }
    pub fn isTrue(c: Const) bool {
        return switch (c) {
            .int => |i| i != 0,
            .real => |r| r != 0,
            .str => |s| s.len != 0,
        };
    }
};

/// §3.2, two sentences and one width: an `integer` "can hold values ranging from
/// -2^31 to 2^31-1", and "arithmetic operations performed on integer variables
/// produce 2's complement results". So the answer to `2147483647 + 1` is
/// -2147483648, and a 64-bit type is wrong at both ends of the range.
///
/// The width is imposed on the OPERATION, not on the storage: an `integer` stays
/// in an i64 slot (one machine word, and every ch9 status return and array
/// index already fits) and every integer arithmetic result is truncated to 32
/// bits and widened back. That is exact rather than approximate, because both
/// operands of an integer operation are themselves in range — either literals
/// §2.5.1 keeps in range or the output of another wrapped operation — so
/// truncating the 64-bit result is bit-for-bit the 32-bit result.
///
/// THREE SITES MUST AGREE and this is the only definition of the rule: this
/// file's `binary` (§4.2 constant expressions), `analysis.foldConst` (parameter
/// defaults and §4.5 operator control arguments) and `codegen.intBin` (the
/// device). A fold that disagreed with the runtime would make one expression
/// answer differently depending on whether it landed in a parameter default.
///
/// NOT applied to a literal: §2.5.1's `-2147483648` is `ineg` of the in-range-
/// as-unsigned 2147483648, and wrapping the operand first would make the
/// negation of it positive.
pub fn wrap32(x: i64) i64 {
    return @as(i32, @truncate(x));
}

/// §4.2.1.3 `b ** n` with both operands integer: "a common data type for each
/// operand is determined before the operator is applied", and with neither
/// real that type is integer. IEEE 1364-2005 §5.1.5 supplies the values: for
/// n >= 0 the power at §3.2's 32-bit width ("The result value is 1 if the
/// second operand is zero"), and for n < 0 Table 5-6's row — 1 for base 1,
/// ±1 by parity for base -1, 0 for every other base (the true value lies
/// strictly between -1 and 1 and an integer truncates it). A zero base under a
/// negative exponent is Table 5-6's 'bx, which an analog integer cannot hold:
/// null here, E0609 from the prover when it is provable, and 0 at run time.
///
/// Same three sites as `wrap32`: `binary`, `analysis.foldConst`, and
/// codegen's `ipow_fn`, which is this function as device text.
pub fn ipow32(b: i64, n: i64) ?i64 {
    if (n < 0) return switch (b) {
        0 => null,
        1 => 1,
        -1 => if (@rem(n, 2) == 0) 1 else -1,
        else => 0, // else: every |b| > 1 truncates to 0, Table 5-6's "negative" row
    };
    var x: i32 = @truncate(b);
    var e = n;
    var r: i32 = 1;
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) r *%= x;
        x *%= x;
    }
    return r;
}

test "ipow32 is IEEE 1364-2005 Table 5-6 at 32 bits" {
    try std.testing.expectEqual(@as(?i64, 8), ipow32(2, 3));
    try std.testing.expectEqual(@as(?i64, 1), ipow32(0, 0)); // "1 if the second operand is zero"
    try std.testing.expectEqual(@as(?i64, 0), ipow32(0, 3));
    try std.testing.expectEqual(@as(?i64, -27), ipow32(-3, 3));
    try std.testing.expectEqual(@as(?i64, 0), ipow32(2, -1)); // |b| > 1, n < 0
    try std.testing.expectEqual(@as(?i64, 0), ipow32(-2, -1));
    try std.testing.expectEqual(@as(?i64, 1), ipow32(1, -5));
    try std.testing.expectEqual(@as(?i64, -1), ipow32(-1, -3));
    try std.testing.expectEqual(@as(?i64, 1), ipow32(-1, -4));
    try std.testing.expectEqual(@as(?i64, null), ipow32(0, -1)); // 'bx
    try std.testing.expectEqual(@as(?i64, -2147483648), ipow32(2, 31)); // §3.2 wrap
    try std.testing.expectEqual(@as(?i64, 0), ipow32(2, 32));
}

/// Table 3-3's string operators, folded. "Equality. Checks whether the two
/// strings are equal. Result is 1 if they are equal and 0 if they are not" and
/// "Relational operators return 1 if the corresponding condition is true using
/// the lexicographical ordering of the two strings".
///
/// A MIXED pair declines to fold. §2.7 does make a string operand "unsigned
/// integer constants" for an arithmetic context, but the conversion is
/// `lowerBinary`'s (`strNum`) and duplicating it here to answer a constant
/// expression is not worth a second copy of the rule; declining leaves the
/// runtime path — which is correct — to answer, at the cost of a "not a
/// constant expression" on a shape nothing in the suite writes.
pub fn strBinary(op: Ast.BinaryOp, a: Const, b: Const) ?Const {
    if (a != .str or b != .str) return null;
    const c = std.mem.order(u8, a.str, b.str);
    return .{
        .int = @intFromBool(switch (op) {
            .eq => c == .eq,
            .neq => c != .eq,
            .lt => c == .lt,
            .le => c != .gt,
            .gt => c == .gt,
            .ge => c != .lt,
            else => return null, // else: Table 3-3 defines only the relations on strings
        }),
    };
}

/// A unary operator over a folded operand. The reductions need the operand's
/// WIDTH, which a `Const` does not carry: `fold` answers them from the literal.
pub fn unary(op: Ast.UnaryOp, a: Const) ?Const {
    return switch (op) {
        .plus => a,
        .minus => switch (a) {
            // Wrapping: a 64-bit literal can be minInt(i64), whose negation
            // is itself rather than a panic.
            .int => |i| .{ .int = 0 -% i },
            .real => |r| .{ .real = -r },
            .str => null,
        },
        .logical_not => Const{ .int = @intFromBool(!a.isTrue()) },
        .bit_not => Const{ .int = ~a.asInt() },
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => null,
    };
}

/// A binary operator over two folded operands. `lhs_signed` is the left
/// operand's signedness, read only by `>>>` (IEEE 1364-2005 §5.1.12); null
/// makes `>>>` decline.
pub fn binary(op: Ast.BinaryOp, a: Const, b: Const, lhs_signed: ?bool) ?Const {
    // Table 3-3, before anything numeric touches a string. `Const.asReal` is 0
    // for EVERY string, so `"slow" == "fast"` folded as `0 == 0` and came out
    // TRUE — silently, and only in the folder: `lowerBinary` compares strings
    // properly at runtime, so the same expression answered differently
    // depending on whether it was a constant expression. A `for` bound over
    // `(mode == "fast") ? 3 : 1` ran three times with `mode` at "slow".
    if (a == .str or b == .str) return strBinary(op, a, b);
    // §4.2.1 integer arithmetic only when BOTH operands are integer.
    const int = a == .int and b == .int;
    const x = a.asReal();
    const y = b.asReal();
    // §3.2's 32-bit 2's complement result — see `wrap32`. `%` needs none: a
    // remainder is never wider than its operands.
    return switch (op) {
        .add => if (int) Const{ .int = wrap32(a.asInt() +% b.asInt()) } else Const{ .real = x + y },
        .sub => if (int) Const{ .int = wrap32(a.asInt() -% b.asInt()) } else Const{ .real = x - y },
        .mul => if (int) Const{ .int = wrap32(a.asInt() *% b.asInt()) } else Const{ .real = x * y },
        // A literal can occupy the full i64 carrier before assignment. Its
        // minInt/-1 quotient needs 65 bits before the current MIR's wrap32.
        .div => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @as(i32, @truncate(@divTrunc(@as(i65, a.asInt()), @as(i65, b.asInt())))) })
        else
            Const{ .real = x / y },
        // §4.2.4: "It shall be an error to pass zero (0) as the second
        // argument to the modulus operator" — for either type, so a zero
        // divisor has no value to fold to; the prover's E0601 reports it.
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @intCast(@rem(@as(i65, a.asInt()), @as(i65, b.asInt()))) })
        else if (y == 0)
            null
        else
            Const{ .real = @rem(x, y) },
        // `ipow32`; its 'bx corner (0 ** negative) declines to fold.
        .pow => if (int) (if (ipow32(a.asInt(), b.asInt())) |r| Const{ .int = r } else null) else Const{ .real = std.math.pow(f64, x, y) },
        .eq => .{ .int = @intFromBool(if (int) a.int == b.int else x == y) },
        .neq => .{ .int = @intFromBool(if (int) a.int != b.int else x != y) },
        .lt => .{ .int = @intFromBool(if (int) a.int < b.int else x < y) },
        .le => .{ .int = @intFromBool(if (int) a.int <= b.int else x <= y) },
        .gt => .{ .int = @intFromBool(if (int) a.int > b.int else x > y) },
        .ge => .{ .int = @intFromBool(if (int) a.int >= b.int else x >= y) },
        .logical_and => .{ .int = @intFromBool(a.isTrue() and b.isTrue()) },
        .logical_or => .{ .int = @intFromBool(a.isTrue() or b.isTrue()) },
        .bit_and => .{ .int = a.asInt() & b.asInt() },
        .bit_or => .{ .int = a.asInt() | b.asInt() },
        .bit_xor => .{ .int = a.asInt() ^ b.asInt() },
        .bit_xnor => .{ .int = ~(a.asInt() ^ b.asInt()) },
        .shl, .shr => blk: {
            const sh = b.asInt();
            if (sh < 0 or sh > 63) break :blk null;
            // §4.2.11 `<<` zero-fills from the right; §3.2's width is what makes
            // `1 << 31` negative and `1 << 32` zero rather than 2^31 and 2^32.
            if (op == .shl) break :blk Const{ .int = wrap32(a.asInt() << @as(u6, @intCast(sh))) };
            // §4.2.11 `>>` fills the vacated positions with zeroes, over
            // §3.2.1's 32-bit `integer` — same rule codegen's `shrLogical`
            // emits, and the fold has to agree with it or a constant and a
            // computed operand give different answers.
            if (sh == 0) break :blk a;
            if (sh > 31) break :blk Const{ .int = 0 };
            const lo: u32 = @bitCast(@as(i32, @truncate(a.asInt())));
            break :blk Const{ .int = lo >> @as(u5, @intCast(sh)) };
        },
        // §4.2.11 keeps `<<<`/`>>>` out of the analog BLOCK only; a constant
        // expression outside it is IEEE 1364-2005 §5.1.12's: `<<<` is `<<`,
        // and `>>>` fills with the sign bit "if the result type is signed",
        // with zeroes otherwise — so an operand of unknown signedness declines.
        .ashl, .ashr => blk: {
            if (!int) break :blk null;
            const sh = b.asInt();
            if (sh < 0 or sh > 63) break :blk null;
            if (op == .ashl) break :blk Const{ .int = wrap32(a.asInt() << @as(u6, @intCast(sh))) };
            const signed = lhs_signed orelse break :blk null;
            const v: i32 = @truncate(a.asInt());
            if (signed) break :blk Const{ .int = v >> @as(u5, @intCast(@min(sh, 31))) };
            if (sh > 31) break :blk Const{ .int = 0 };
            break :blk Const{ .int = @as(u32, @bitCast(v)) >> @as(u5, @intCast(sh)) };
        },
        // §4.2.5 case equality on two-state operands IS `==`/`!=` (x and z
        // cannot occur), which is how lowering lowers it (VAMS §7.3.2). A real
        // operand is refused there (E0369), so it does not fold here either.
        .case_eq => if (int) Const{ .int = @intFromBool(a.int == b.int) } else null,
        .case_neq => if (int) Const{ .int = @intFromBool(a.int != b.int) } else null,
    };
}

/// §4.3 Table 4-14 and Table 4-15: the built-in math functions, by their
/// source spelling. `log` is the decimal logarithm (§4.3.1); `ln` the natural.
pub const MathFn = enum {
    abs,
    min,
    max,
    pow,
    hypot,
    atan2,
    sqrt,
    exp,
    expm1,
    ln,
    ln1p,
    log,
    floor,
    ceil,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,

    pub fn fromName(name: []const u8) ?MathFn {
        return std.meta.stringToEnum(MathFn, name);
    }
    pub fn arity(f: MathFn) usize {
        return switch (f) {
            .min, .max, .pow, .hypot, .atan2 => 2,
            .abs, .sqrt, .exp, .expm1, .ln, .ln1p, .log, .floor, .ceil => 1,
            .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => 1,
        };
    }
};

/// A §4.3 function over folded arguments. §4.3.1: `abs`, `min` and `max` are
/// integer when every argument is; every other function is real, `pow`
/// included (§4.2.1.3's integer power is the OPERATOR `**`). Out-of-domain
/// arguments fold to what IEEE arithmetic gives (NaN, ±inf); the prover, not
/// the folder, rules on domains.
pub fn math(f: MathFn, args: []const Const) ?Const {
    if (args.len != f.arity()) return null;
    for (args) |a| if (a == .str) return null;
    const x = args[0].asReal();
    const y = if (args.len > 1) args[1].asReal() else 0;
    const int = for (args) |a| {
        if (a != .int) break false;
    } else true;
    return switch (f) {
        // Wrapping, like unary minus: |minInt(i64)| is not an i64.
        .abs => if (int) Const{ .int = if (args[0].int < 0) 0 -% args[0].int else args[0].int } else Const{ .real = @abs(x) },
        .min => if (int) Const{ .int = @min(args[0].int, args[1].int) } else Const{ .real = @min(x, y) },
        .max => if (int) Const{ .int = @max(args[0].int, args[1].int) } else Const{ .real = @max(x, y) },
        .pow => .{ .real = std.math.pow(f64, x, y) },
        .hypot => .{ .real = std.math.hypot(x, y) },
        .atan2 => .{ .real = std.math.atan2(x, y) },
        .sqrt => .{ .real = @sqrt(x) },
        .exp => .{ .real = @exp(x) },
        .expm1 => .{ .real = std.math.expm1(x) },
        .ln => .{ .real = @log(x) },
        .ln1p => .{ .real = std.math.log1p(x) },
        .log => .{ .real = @log10(x) },
        .floor => .{ .real = @floor(x) },
        .ceil => .{ .real = @ceil(x) },
        .sin => .{ .real = @sin(x) },
        .cos => .{ .real = @cos(x) },
        .tan => .{ .real = @tan(x) },
        .asin => .{ .real = std.math.asin(x) },
        .acos => .{ .real = std.math.acos(x) },
        .atan => .{ .real = std.math.atan(x) },
        .sinh => .{ .real = std.math.sinh(x) },
        .cosh => .{ .real = std.math.cosh(x) },
        .tanh => .{ .real = std.math.tanh(x) },
        .asinh => .{ .real = std.math.asinh(x) },
        .acosh => .{ .real = std.math.acosh(x) },
        .atanh => .{ .real = std.math.atanh(x) },
    };
}

/// Fold `e` over `file`'s expression store: literals, the A.2.5 infinities,
/// the unary/binary operators, a lazy `?:`, and §4.3's math functions.
///
/// `env` answers what the structure cannot, as three methods:
///   leaf(e) ?Const     any tag this walk does not fold itself (an identifier)
///   refuse(e) bool     a `.binary` the caller will not fold at all
///   signed(e) ?bool    `>>>`'s left operand signedness
/// `literal_env` answers none of them: a fold over literals only.
pub fn fold(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const {
    if (e == .none) return null;
    const ex = &file.exprs;
    switch (ex.tag(e)) {
        .int_literal => return .{ .int = ex.intValue(e) },
        .real_literal => return .{ .real = ex.realValue(e) },
        .str_literal => return .{ .str = file.str(ex.strOf(e)) },
        .pos_inf => return .{ .real = std.math.inf(f64) },
        .neg_inf => return .{ .real = -std.math.inf(f64) },
        .unary => {
            const a = fold(file, ex.lhs(e), env) orelse return null;
            const op = ex.unOp(e);
            return switch (op) {
                .plus, .minus, .logical_not, .bit_not => unary(op, a),
                .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => reduction(ex, op, ex.lhs(e), a),
            };
        },
        .binary => {
            if (env.refuse(e)) return null;
            const a = fold(file, ex.lhs(e), env) orelse return null;
            const b = fold(file, ex.rhs(e), env) orelse return null;
            const op = ex.binOp(e);
            return binary(op, a, b, if (op == .ashr) env.signed(ex.lhs(e)) else null);
        },
        .ternary => {
            const c = fold(file, ex.lhs(e), env) orelse return null;
            return fold(file, if (c.isTrue()) ex.rhs(e) else ex.ternaryElse(e), env);
        },
        // §4.3 Table 4-14/4-15 math in a constant expression.
        .builtin_call => {
            const f = MathFn.fromName(file.str(ex.strOf(e))) orelse return null;
            const args = ex.args(e);
            if (args.len != f.arity()) return null;
            var vals: [2]Const = undefined;
            for (args, 0..) |a, i| vals[i] = fold(file, a, env) orelse return null;
            return math(f, vals[0..args.len]);
        },
        else => return env.leaf(e), // else: every other tag names something only the caller can resolve
    }
}

/// The `env` that knows nothing: `fold(file, e, literal_env)` folds literals
/// and the operators over them, and declines an identifier and `>>>`.
pub const literal_env: LiteralEnv = .{};
pub const LiteralEnv = struct {
    pub fn leaf(_: LiteralEnv, _: Ast.ExprId) ?Const {
        return null;
    }
    pub fn refuse(_: LiteralEnv, _: Ast.ExprId) bool {
        return false;
    }
    pub fn signed(_: LiteralEnv, _: Ast.ExprId) ?bool {
        return null;
    }
};

/// IEEE 1364-2005 §5.1.11: "The unary reduction operators shall perform a
/// bitwise operation on a single operand to produce a single-bit result", over
/// the operand's bits — so the answer depends on the operand's WIDTH, which a
/// `Const` does not carry. It is known for a literal: its size, and §3.2's 32
/// bits for an unsized one. Any other operand declines rather than guessing a
/// width. §4.2.10 bars these operators from the analog BLOCK, not from a
/// parameter declaration.
// ponytail: literal operands only. A parameter's width is 32 unless A.2.1.1's
// `[ range ]` sized it, and an expression's is §5.4's sizing rules; carry a
// width beside `Const` if a model ever reduces either.
fn reduction(ex: *const Ast.ExprStore, op: Ast.UnaryOp, operand: Ast.ExprId, a: Const) ?Const {
    if (a != .int) return null;
    if (ex.tag(operand) != .int_literal) return null;
    const w = ex.intLiteral(operand).width;
    const width: u7 = if (w == 0) 32 else if (w <= 64) @intCast(w) else return null;
    const mask: u64 = if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
    const bits: u64 = @as(u64, @bitCast(a.int)) & mask;
    const r: bool = switch (op) {
        .reduce_and => bits == mask,
        .reduce_nand => bits != mask,
        .reduce_or => bits != 0,
        .reduce_nor => bits == 0,
        .reduce_xor => @popCount(bits) % 2 == 1,
        .reduce_xnor => @popCount(bits) % 2 == 0,
        .plus, .minus, .logical_not, .bit_not => unreachable, // `fold` sends these to `unary`
    };
    return .{ .int = @intFromBool(r) };
}

test "case equality folds on integers like ==, and declines on reals" {
    const a: Const = .{ .int = 3 };
    const b: Const = .{ .int = 3 };
    const r: Const = .{ .real = 3.0 };
    try std.testing.expectEqual(@as(i64, 1), (binary(.case_eq, a, b, null) orelse unreachable).int);
    try std.testing.expectEqual(@as(i64, 0), (binary(.case_neq, a, b, null) orelse unreachable).int);
    try std.testing.expect(binary(.case_eq, a, r, null) == null);
}
