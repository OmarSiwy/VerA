//! The §4.2 constant_expression folder: an expression AST (or one MIR operator
//! and its folded operands) in, a `Const` out, or null when the expression is
//! not constant. Pure: no allocation and no symbol table; identifiers and
//! `>>>`'s signedness come from the caller's `env`. Implements §3.2's 32-bit
//! integer wrap, §4.2.1.3, §4.2.4, §4.2.11, §4.2.12, §4.3 and Table 3-3;
//! §9.14 / IEEE §§5.4–5.5 size the self-determined `$clog2` operand.
//! §3.4/A.2.4 and §6.3 share the syntactic check for reads of simulation state.

const std = @import("std");
const Ast = @import("ast.zig");
/// The devices' exp/log/pow: a fold gives the bits the device computes.
const gm = @import("contract").gm;

/// A folded constant (§4.2 constant_expression). Genvars (§3.5) and parameter
/// defaults live here so `for (i=0;i<N;i=i+1)` can unroll (§6.6.1).
pub const Const = union(enum) {
    int: i64,
    real: f64,
    str: []const u8,

    /// Returns the value as a real; a string is 0.
    pub fn asReal(c: Const) f64 {
        return switch (c) {
            .int => |i| @floatFromInt(i),
            .real => |r| r,
            .str => 0,
        };
    }
    /// Returns the value as an integer, rounding a real to nearest with ties
    /// away from zero (LRM §4.2.1.1). Null for a NaN, an infinity or a real
    /// outside i64, which §4.2.1.1 gives no value; a string is 0. A caller
    /// holding a real the user wrote must use this and diagnose the null.
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
    /// `asIntExact`, saturating out-of-range reals and mapping NaN to 0. Never
    /// panics. Only for operands already known to be in range; a real the
    /// user wrote goes through `asIntExact`.
    pub fn asInt(c: Const) i64 {
        // A bare `@intFromFloat` on an out-of-range double is illegal behavior,
        // so this saturates instead.
        return c.asIntExact() orelse blk: {
            const r = c.asReal();
            if (std.math.isNan(r)) break :blk 0;
            break :blk if (r > 0) std.math.maxInt(i64) else std.math.minInt(i64);
        };
    }
    /// Returns the truth value: nonzero, or a non-empty string.
    pub fn isTrue(c: Const) bool {
        return switch (c) {
            .int => |i| i != 0,
            .real => |r| r != 0,
            .str => |s| s.len != 0,
        };
    }
};

/// Truncates an integer arithmetic result to §3.2's 32-bit two's complement
/// and widens it back: an `integer` "can hold values ranging from -2^31 to
/// 2^31-1", so `2147483647 + 1` is -2147483648 (LRM §3.2).
///
/// The width is imposed on the operation, not the storage: an `integer` stays
/// in an i64 slot. This is exact because both operands of an integer operation
/// are already in range (a §2.5.1 literal or another wrapped result).
///
/// Three sites must agree: this file's `binary`, `analysis.foldConst` and
/// codegen's `intBin32`. Otherwise one expression would answer differently
/// in a parameter default than at run time.
///
/// Not applied to a literal: §2.5.1's `-2147483648` negates the unsigned
/// 2147483648, and wrapping the operand first would make the result positive.
pub fn wrap32(x: i64) i64 {
    return @as(i32, @truncate(x));
}

/// §3.4.1 applies the declared parameter type before another expression reads
/// its value. Shared by elaboration's paramset selection and lowering, so the
/// selected member sees the same real/integer conversion as the emitted model.
/// Invalid real-to-integer inputs remain real for the caller's diagnostic.
pub fn parameterValue(ty: Ast.Type, value: Const) Const {
    return switch (ty) {
        .real => if (value == .str) value else .{ .real = value.asReal() },
        .integer => switch (value) {
            .int => |n| .{ .int = wrap32(n) },
            .real => if (value.asIntExact()) |n| .{ .int = wrap32(n) } else value,
            .str => value,
        },
        .string, .unspecified => value,
    };
}

/// Numeric host cards carry no new HDL type or width. Preserve an inferred
/// integral carrier without imposing the explicit `integer` declaration's
/// 32-bit wrap; operand width still comes from the elaborated declaration.
pub fn parameterCardValue(ty: Ast.Type, declared: ?Const, value: f64) Const {
    const c: Const = .{ .real = value };
    if (ty == .unspecified and declared != null and declared.? == .int)
        return if (c.asIntExact()) |n| .{ .int = n } else c;
    return parameterValue(ty, c);
}

/// §3.2's wrap for unary `-` and `abs`, whose result `r` comes from operand
/// `a`: -(-2^31) is -2^31. An operand wider than 32 bits is a §2.6.1 literal
/// ("at least 32" bits), and its negation keeps that width, as the literal
/// itself does.
fn wrapFrom(a: i64, r: i64) i64 {
    return if (std.math.cast(i32, a) != null) wrap32(r) else r;
}

/// §4.2.1.3 `b ** n` with both operands integer: "a common data type for each
/// operand is determined before the operator is applied", and with neither
/// real that type is integer. IEEE 1364-2005 §5.1.5 supplies the values: for
/// n >= 0 the power at §3.2's 32-bit width ("The result value is 1 if the
/// second operand is zero"), and for n < 0 Table 5-6's row: 1 for base 1,
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

/// §3.4/A.2.4: the spelling of the first simulation-state or module-variable
/// reference in a parameter default, or null when none exists. Access functions, analog
/// operators, small-signal sources and event functions are state reads by
/// TAG; a `sys_call` is one by NAME (`simStateName`), because most `$` names
/// that could appear here — `$param_given`, `$mfactor`, `$simprobe` — resolve
/// before the solve and are left to the ordinary paths. Every other tag is
/// searched through its `children`, first in source order.
pub fn firstStateRead(file: *const Ast.SourceFile, e: Ast.ExprId, vars: []const Ast.VarDecl) ?[]const u8 {
    if (e == .none) return null;
    const ex = &file.exprs;
    const tag = ex.tag(e);
    switch (tag) {
        // §4.4 access functions, §4.5 analog operators, §4.6 small-signal
        // sources, §5.10 event functions: operating-point reads by construction.
        .branch_access, .port_access, .filter_call, .noise_call, .event_function => return file.str(ex.strOf(e)),
        .sys_call => {
            const n = file.str(ex.strOf(e));
            if (simStateName(n)) return n;
        },
        // §3.4 "constant numbers and previously defined parameters": a module
        // variable is neither, and holds nothing until the analog block runs.
        .ident => for (vars) |v| {
            if (v.name == ex.strOf(e)) return file.str(v.name);
        },
        else => {}, // else: a state read only through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (firstStateRead(file, c, vars)) |w| return w;
    return null;
}

/// The `$` (and `analysis`) names whose value belongs to a solve: time, the
/// ambient temperature pair, the RNG family, and the analysis type. §9.13's
/// distributions are matched by their two prefixes.
///
/// `$simparam` is deliberately NOT here: §9.15's table is the HOST's, constant
/// for a whole run, and a default reading it is the documented W1050 contract
/// — the field ships as 0 and the host writes it (codegen's "§3.4 a default
/// with no compile-time value is W1050" test pins exactly that shape).
fn simStateName(n: []const u8) bool {
    const names = [_][]const u8{
        "$abstime", "$realtime", "$temperature", "$vt",
        "$random",  "$arandom",  "analysis",
    };
    for (names) |s| if (std.mem.eql(u8, n, s)) return true;
    return std.mem.startsWith(u8, n, "$dist_") or std.mem.startsWith(u8, n, "$rdist_");
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

/// Folds Table 3-3's string operators. "Equality. Checks whether the two
/// strings are equal. Result is 1 if they are equal and 0 if they are not" and
/// "Relational operators return 1 if the corresponding condition is true using
/// the lexicographical ordering of the two strings".
///
/// A mixed string/number pair declines to fold. §2.7 makes a string operand
/// "unsigned integer constants" in an arithmetic context, but that conversion
/// is lowering's (`strNum`), and declining leaves the runtime path to answer.
fn strBinary(op: Ast.BinaryOp, a: Const, b: Const) ?Const {
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

/// Folds a unary operator over a folded operand. Returns null for the
/// reductions, which need a width a `Const` does not carry; `fold` answers
/// them from the literal.
pub fn unary(op: Ast.UnaryOp, a: Const) ?Const {
    return switch (op) {
        .plus => a,
        .minus => switch (a) {
            // `-%` because a 64-bit literal can be minInt(i64).
            .int => |i| .{ .int = wrapFrom(i, 0 -% i) },
            .real => |r| .{ .real = -r },
            .str => null,
        },
        .logical_not => Const{ .int = @intFromBool(!a.isTrue()) },
        .bit_not => Const{ .int = ~a.asInt() },
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => null,
    };
}

/// Folds a binary operator over two folded operands, or returns null when the
/// result has no constant value here: an integer zero divisor or a zero
/// modulus, a string beside a number or under an operator Table 3-3 does not
/// define, a shift count outside 0..63, a real under `<<<`, `>>>`, `===` or
/// `!==`, and `0 ** negative`. `lhs_signed` is the left operand's
/// signedness, read only by `>>>` (IEEE 1364-2005 §5.1.12); null makes `>>>`
/// decline.
pub fn binary(op: Ast.BinaryOp, a: Const, b: Const, lhs_signed: ?bool) ?Const {
    // Strings first: `asReal` is 0 for every string, so a numeric compare
    // would make `"slow" == "fast"` true.
    if (a == .str or b == .str) return strBinary(op, a, b);
    // §4.2.1 integer arithmetic only when both operands are integer.
    const int = a == .int and b == .int;
    const x = a.asReal();
    const y = b.asReal();
    // §3.2's 32-bit two's complement result (`wrap32`). `%` needs none: a
    // remainder is never wider than its operands.
    return switch (op) {
        .add => if (int) Const{ .int = wrap32(a.asInt() +% b.asInt()) } else Const{ .real = x + y },
        .sub => if (int) Const{ .int = wrap32(a.asInt() -% b.asInt()) } else Const{ .real = x - y },
        .mul => if (int) Const{ .int = wrap32(a.asInt() *% b.asInt()) } else Const{ .real = x * y },
        // A literal can occupy the full i64 carrier, and its minInt/-1
        // quotient needs 65 bits before the wrap.
        .div => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @as(i32, @truncate(@divTrunc(@as(i65, a.asInt()), @as(i65, b.asInt())))) })
        else
            Const{ .real = x / y },
        // §4.2.4: "It shall be an error to pass zero (0) as the second
        // argument to the modulus operator", for either type, so a zero
        // divisor has no value to fold to; the prover's E0601 reports it.
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @intCast(@rem(@as(i65, a.asInt()), @as(i65, b.asInt()))) })
        else if (y == 0)
            null
        else
            Const{ .real = @rem(x, y) },
        // `ipow32`; its 'bx corner (0 ** negative) declines to fold.
        .pow => if (int) (if (ipow32(a.asInt(), b.asInt())) |r| Const{ .int = r } else null) else Const{ .real = gm.pow(x, y) },
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
            // §3.2.1's 32-bit `integer`. Must agree with codegen's
            // `shrLogical`, or a constant and a computed operand differ.
            if (sh == 0) break :blk a;
            if (sh > 31) break :blk Const{ .int = 0 };
            const lo: u32 = @bitCast(@as(i32, @truncate(a.asInt())));
            break :blk Const{ .int = lo >> @as(u5, @intCast(sh)) };
        },
        // §4.2.11 keeps `<<<`/`>>>` out of the analog BLOCK only; a constant
        // expression outside it is IEEE 1364-2005 §5.1.12's: `<<<` is `<<`,
        // and `>>>` fills with the sign bit "if the result type is signed",
        // with zeroes otherwise, so an operand of unknown signedness declines.
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
        // §4.2.5 case equality on two-state operands is `==`/`!=` (x and z
        // cannot occur), which is how lowering lowers it (VAMS §7.3.2). A real
        // operand is refused there (E0369), so it does not fold here either.
        .case_eq => if (int) Const{ .int = @intFromBool(a.int == b.int) } else null,
        .case_neq => if (int) Const{ .int = @intFromBool(a.int != b.int) } else null,
    };
}

/// The built-in math functions of §4.3 Tables 4-14 and 4-15, named by their
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

    /// Returns the function spelled `name`, or null for any other name.
    pub fn fromName(name: []const u8) ?MathFn {
        return std.meta.stringToEnum(MathFn, name);
    }
    /// Returns how many arguments §4.3's tables give `f`: 1 or 2.
    pub fn arity(f: MathFn) usize {
        return switch (f) {
            .min, .max, .pow, .hypot, .atan2 => 2,
            .abs, .sqrt, .exp, .expm1, .ln, .ln1p, .log, .floor, .ceil => 1,
            .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => 1,
        };
    }
};

/// Folds a §4.3 function over folded arguments, or returns null on a wrong
/// arity or a string argument. §4.3.1: `abs`, `min` and `max` are integer
/// when every argument is; every other function is real, `pow` included
/// (§4.2.1.3's integer power is the operator `**`). Out-of-domain
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
        .abs => if (int) Const{ .int = wrapFrom(args[0].int, if (args[0].int < 0) 0 -% args[0].int else args[0].int) } else Const{ .real = @abs(x) },
        // §4.3.1 "min(x,y) is equivalent to (x < y) ? x : y", bit for bit:
        // @min/@max drop a NaN and leave a zero's sign open, and run time
        // (kernel_text zMin/zMax) uses the conditional form.
        .min => if (int) Const{ .int = @min(args[0].int, args[1].int) } else Const{ .real = if (x < y) x else y },
        .max => if (int) Const{ .int = @max(args[0].int, args[1].int) } else Const{ .real = if (x > y) x else y },
        .pow => .{ .real = gm.pow(x, y) },
        .hypot => .{ .real = std.math.hypot(x, y) },
        .atan2 => .{ .real = std.math.atan2(x, y) },
        .sqrt => .{ .real = @sqrt(x) },
        .exp => .{ .real = gm.exp(x) },
        .expm1 => .{ .real = std.math.expm1(x) },
        .ln => .{ .real = gm.log(x) },
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

/// Folds `e` over `file`'s expression store, or returns null when it is not
/// constant. Covers literals, the A.2.5 infinities, the unary and binary
/// operators, a lazy `?:`, and §4.3's math functions. `&&` and `||` fold both
/// operands here (`foldSized` short-circuits), so `0 && 1/0` declines.
///
/// `env` answers what the structure cannot, as three methods:
///   leaf(e) ?Const     any tag this walk does not fold itself (an identifier)
///   signed(e) ?bool    an operand's signedness (`>>>`, §4.2.9 comparisons)
///   width(e) ?u32      a name's bit length (§4.2.9 comparisons)
/// `literal_env` answers none of them: a fold over literals only.
pub fn fold(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const {
    return foldContext(file, e, env, false, null);
}

/// IEEE §§5.4–5.5: a system-function operand is self-determined, but its
/// type and size propagate into its context-dependent subexpressions.
pub fn foldSized(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const {
    return foldContext(file, e, env, true, null);
}

fn foldContext(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, comptime sized: bool, parent: ?IntContext) ?Const {
    if (e == .none) return null;
    const ex = &file.exprs;
    const plan: ?IntPlan = if (sized) intPlan(file, e, env, parent) else null;
    if (plan) |p| if (!p.supported) return null;
    const contexts = if (plan) |p| p.operands else [_]?IntContext{ null, null, null };
    var value: Const = switch (ex.tag(e)) {
        .int_literal => .{ .int = ex.intValue(e) },
        .logic_literal => .{ .int = ex.logicValue(e).asExactInt() orelse return null },
        .real_literal => .{ .real = ex.realValue(e) },
        .str_literal => .{ .str = file.str(ex.strOf(e)) },
        .pos_inf => .{ .real = std.math.inf(f64) },
        .neg_inf => .{ .real = -std.math.inf(f64) },
        .unary => blk: {
            const a = foldContext(file, ex.lhs(e), env, sized, contexts[0]) orelse return null;
            const op = ex.unOp(e);
            break :blk (switch (op) {
                .plus, .minus, .logical_not, .bit_not => unary(op, a),
                .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => reduction(ex, op, ex.lhs(e), a),
            }) orelse return null;
        },
        .binary => blk: {
            var a = foldContext(file, ex.lhs(e), env, sized, contexts[0]) orelse return null;
            const op = ex.binOp(e);
            if (sized and ((op == .logical_and and !a.isTrue()) or (op == .logical_or and a.isTrue())))
                break :blk .{ .int = @intFromBool(a.isTrue()) };
            var b = foldContext(file, ex.rhs(e), env, sized, contexts[1]) orelse return null;
            const compare = op == .eq or op == .neq or op == .case_eq or op == .case_neq or op == .lt or op == .le or op == .gt or op == .ge;
            if (sized and a == .int and b == .int) {
                if (op == .shr) if (contexts[0]) |c| {
                    a.int = (IntContext{ .width = c.width, .signed = false }).normalize(a.int);
                };
                if (compare) if (contexts[0]) |c| if (!c.signed and c.width == 64) {
                    a.int ^= std.math.minInt(i64);
                    b.int ^= std.math.minInt(i64);
                };
            } else if (compare and a == .int and b == .int) if (unsignedCompare(file, ex.lhs(e), ex.rhs(e), env)) |u| {
                a.int = u.extend(.lhs, a.int);
                b.int = u.extend(.rhs, b.int);
            };
            const shift_signed = if (op != .ashr) null else if (sized and contexts[0] != null) contexts[0].?.signed else env.signed(ex.lhs(e));
            break :blk binary(op, a, b, shift_signed) orelse return null;
        },
        .ternary => blk: {
            const c = foldContext(file, ex.lhs(e), env, sized, contexts[0]) orelse return null;
            break :blk foldContext(file, if (c.isTrue()) ex.rhs(e) else ex.ternaryElse(e), env, sized, contexts[if (c.isTrue()) 1 else 2]) orelse return null;
        },
        // §4.3 Table 4-14/4-15 math in a constant expression.
        .builtin_call => blk: {
            const f = MathFn.fromName(file.str(ex.strOf(e))) orelse return null;
            const args = ex.args(e);
            if (args.len != f.arity()) return null;
            var vals: [2]Const = undefined;
            for (args, 0..) |a, i| vals[i] = fold(file, a, env) orelse return null;
            break :blk math(f, vals[0..args.len]) orelse return null;
        },
        else => env.leaf(e) orelse return null, // else: every other tag names something only the caller can resolve
    };
    if (value == .int) if (plan) |p| {
        value.int = p.resize(value.int);
    };
    return value;
}

/// §4.2.9 on the i64 carrier: "When one or both operands are unsigned, the
/// expression shall be interpreted as a comparison between unsigned values. If
/// the operands are of unequal bit lengths, the smaller operand shall be
/// zero-extended to the size of the larger operand." Each operand is extended
/// from its OWN width: `a` at -1 against `40'hFF_FFFF_FFFF` is
/// 40'h00_FFFF_FFFF. Both signed, the carrier already holds the sign-extended
/// values and the signed compare stands.
pub const UnsignedCompare = struct {
    /// Each operand's own-width mask; null at 64 bits or wider, or an unknown
    /// width, where the carrier's value is taken as it stands.
    mask: [2]?i64,
    /// An operand is 64 bits or wider: order the pair as u64 by flipping bit 63
    /// of both before the signed compare.
    flip: bool,

    pub const Side = enum { lhs, rhs };

    /// Returns operand `side`'s value as the i64 the signed compare orders as
    /// §4.2.9's unsigned comparison.
    pub fn extend(u: UnsignedCompare, side: Side, v: i64) i64 {
        const z = if (u.mask[@backingInt(side)]) |m| v & m else v;
        return if (u.flip) z ^ std.math.minInt(i64) else z;
    }
};

/// The §4.2.9 extension of comparison `l` vs `r` under `env` (`fold`'s), or
/// null when neither operand is known unsigned.
pub fn unsignedCompare(file: *const Ast.SourceFile, l: Ast.ExprId, r: Ast.ExprId, env: anytype) ?UnsignedCompare {
    if ((env.signed(l) orelse true) and (env.signed(r) orelse true)) return null;
    const w = [2]?u32{ operandWidth(file, l, env), operandWidth(file, r, env) };
    var u: UnsignedCompare = .{ .mask = undefined, .flip = false };
    for (w, &u.mask) |wi, *m| {
        const n = wi orelse {
            m.* = null;
            continue;
        };
        u.flip = u.flip or n >= 64;
        m.* = if (n >= 64) null else (@as(i64, 1) << @intCast(n)) - 1;
    }
    return u;
}

/// The bit length §4.2.9 extends an operand from: a §2.6.1 literal's size and
/// a name's (`env.width`) as written; any other integer expression is §3.2's
/// 32 bits, since the analog operators compute at that width, or the carrier's
/// wider value where a sign, a complement, a bitwise operator or `?:` passes a
/// wide operand through. Null when unknown.
pub fn operandWidth(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?u32 {
    return expressionWidth(file, e, env, false);
}

/// IEEE 1364-2005 §5.4.1 / §17.11.1: `$clog2`'s self-determined operand
/// keeps the size of a sized unary or arithmetic expression; no assignment
/// context widens it to the analog integer carrier's 32 bits.
pub fn clog2Width(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?u32 {
    return expressionWidth(file, e, env, true);
}

fn expressionWidth(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, comptime self_determined: bool) ?u32 {
    const ex = &file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => literalWidth(ex, e),
        .logic_literal => ex.logicValue(e).width,
        .ident => env.width(e),
        // `unary`'s `wrapFrom`: a sign or complement keeps a wide literal's width.
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => widthFloor(expressionWidth(file, ex.lhs(e), env, self_determined) orelse return null, self_determined),
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => if (self_determined) 1 else 32,
        },
        .binary => switch (ex.binOp(e)) {
            .bit_and, .bit_or, .bit_xor, .bit_xnor => widthFloor(@max(expressionWidth(file, ex.lhs(e), env, self_determined) orelse return null, expressionWidth(file, ex.rhs(e), env, self_determined) orelse return null), self_determined),
            .add, .sub, .mul, .div, .mod => if (self_determined) @max(expressionWidth(file, ex.lhs(e), env, true) orelse return null, expressionWidth(file, ex.rhs(e), env, true) orelse return null) else 32,
            .pow, .shl, .shr, .ashl, .ashr => if (self_determined) expressionWidth(file, ex.lhs(e), env, true) else 32,
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => if (self_determined) 1 else 32,
        },
        .ternary => widthFloor(@max(expressionWidth(file, ex.rhs(e), env, self_determined) orelse return null, expressionWidth(file, ex.ternaryElse(e), env, self_determined) orelse return null), self_determined),
        // §9.11 `$realtobits` returns the double's 64-bit pattern.
        .sys_call => if (std.mem.eql(u8, file.str(ex.strOf(e)), "$realtobits")) 64 else 32,
        else => 32, // else: every other integer-valued form is §3.2's 32-bit integer
    };
}

// A §2.6.1 integer literal's width: its size, or, unsized, "at least 32"
// bits: §3.2's 32 when they hold the value, the carrier's 64 when they do
// not. `expressionWidth` and `reduction` must agree on it.
fn literalWidth(ex: *const Ast.ExprStore, e: Ast.ExprId) u32 {
    const w = ex.intLiteral(e).width;
    if (w != 0) return w;
    const v = ex.intValue(e);
    return if (std.math.cast(u32, v) != null or std.math.cast(i32, v) != null) 32 else 64;
}

fn widthFloor(w: u32, comptime self_determined: bool) u32 {
    return if (self_determined) w else @max(w, 32);
}

/// IEEE §5.5.1 signedness before the unsigned `$clog2` boundary. Names are
/// the environment's; a function call keeps its own argument contexts.
pub fn clog2Signed(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?bool {
    const ex = &file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).signed,
        .logic_literal => ex.logicValue(e).signed,
        .ident => env.signed(e),
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => clog2Signed(file, ex.lhs(e), env),
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => false,
        },
        .binary => switch (ex.binOp(e)) {
            .shl, .shr, .ashl, .ashr, .pow => clog2Signed(file, ex.lhs(e), env),
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => clog2OperandsSigned(file, ex.lhs(e), ex.rhs(e), env),
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => false,
        },
        .ternary => clog2OperandsSigned(file, ex.rhs(e), ex.ternaryElse(e), env),
        .sys_call => !std.mem.eql(u8, file.str(ex.strOf(e)), "$realtobits"),
        .call, .index => true, // analog function/array integral results are §3.2 integers
        else => null, // else: not an integral expression in the analog context
    };
}

fn clog2OperandsSigned(file: *const Ast.SourceFile, a: Ast.ExprId, b: Ast.ExprId, env: anytype) ?bool {
    const sa = clog2Signed(file, a, env) orelse return null;
    const sb = clog2Signed(file, b, env) orelse return null;
    return sa and sb;
}

/// One IEEE §5.5.2 type/size context, over the existing i64 carrier.
pub const IntContext = struct {
    /// Bits; 64 or more leaves the carrier as it is.
    width: u32,
    signed: bool,

    /// Returns `value` cut to `width` bits and re-extended by `signed`.
    /// `width` is at least 1: every context comes from an operand width.
    pub fn normalize(c: IntContext, value: i64) i64 {
        if (c.width >= 64) return value;
        const mask = (@as(u64, 1) << @intCast(c.width)) - 1;
        var bits = @as(u64, @bitCast(value)) & mask;
        if (c.signed and bits & (@as(u64, 1) << @intCast(c.width - 1)) != 0) bits |= ~mask;
        return @bitCast(bits);
    }
};

/// Shared by folding and lowering: where context propagates, where it stops,
/// and how the result enters its parent. No changes to ordinary analog ops.
pub const IntPlan = struct {
    /// The context the node's value enters its parent in.
    result: IntContext,
    /// The width the node computes at, before `resize` converts it.
    from_width: u32,
    /// The context each operand is folded in (`lhs`, `rhs`, the `?:` else
    /// arm); null where the operand is self-determined.
    operands: [3]?IntContext = .{ null, null, null },
    /// False when the result is wider than the i64 carrier can compute.
    supported: bool = true,

    /// Returns `value`, computed at `from_width`, converted to `result`.
    pub fn resize(p: IntPlan, value: i64) i64 {
        const source: IntContext = .{ .width = p.from_width, .signed = p.result.signed };
        return p.result.normalize(source.normalize(value));
    }
};

/// Returns how `e` is sized inside `parent` (null: `e` is self-determined).
/// IEEE Table 5-22 and §5.5.2: logical operands, a shift/power's RHS, and a
/// conditional's condition are self-determined. Comparisons share a context
/// between their operands, independent of their one-bit result. Null when
/// `env` cannot give a width or signedness the plan needs.
pub fn intPlan(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, parent: ?IntContext) ?IntPlan {
    const ex = &file.exprs;
    const own: IntContext = .{ .width = clog2Width(file, e, env) orelse return null, .signed = clog2Signed(file, e, env) orelse return null };
    const result: IntContext = if (parent) |p| .{ .width = @max(p.width, own.width), .signed = p.signed } else own;
    var plan: IntPlan = .{ .result = result, .from_width = own.width };
    switch (ex.tag(e)) {
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => {
                plan.from_width = result.width;
                plan.operands[0] = result;
                plan.supported = result.width <= (if (ex.unOp(e) == .minus) @as(u32, 32) else 64);
            },
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {},
        },
        .binary => switch (ex.binOp(e)) {
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                plan.from_width = result.width;
                plan.operands[0] = result;
                plan.operands[1] = result;
                const bitwise = switch (ex.binOp(e)) {
                    .bit_and, .bit_or, .bit_xor, .bit_xnor => true,
                    else => false, // else: the enclosing prong's five arithmetic operations wrap at 32
                };
                plan.supported = result.width <= (if (bitwise) @as(u32, 64) else 32);
            },
            .pow, .shl, .shr, .ashl, .ashr => {
                plan.from_width = result.width;
                plan.operands[0] = result;
                plan.supported = result.width <= 32;
            },
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                const comparison: IntContext = .{
                    .width = @max(clog2Width(file, ex.lhs(e), env) orelse return null, clog2Width(file, ex.rhs(e), env) orelse return null),
                    .signed = clog2OperandsSigned(file, ex.lhs(e), ex.rhs(e), env) orelse return null,
                };
                plan.operands[0] = comparison;
                plan.operands[1] = comparison;
                plan.supported = comparison.width <= 64;
            },
            .logical_and, .logical_or => {},
        },
        .ternary => {
            plan.from_width = result.width;
            plan.operands[1] = result;
            plan.operands[2] = result;
            plan.supported = result.width <= 64;
        },
        else => {}, // else: a primary keeps its own width until converted to its parent
    }
    return plan;
}

/// §17.11.1's unsigned interpretation at the source operand's width.
/// Wider signed literals that fit the i64 carrier repeat their sign bit;
/// a negative one is therefore above 2**(width-1) and rounds up to width.
pub fn clog2(value: i64, width: u32) i64 {
    if (width > 64 and value < 0) return width;
    const mask: u64 = if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
    const bits = @as(u64, @bitCast(value)) & mask;
    return if (bits <= 1) 0 else 64 - @as(i64, @clz(bits - 1));
}

/// The `env` that knows nothing: `fold(file, e, literal_env)` folds literals
/// and the operators over them, and declines an identifier and `>>>`.
pub const literal_env: LiteralEnv = .{};
/// The type of `literal_env`: every query answers null.
pub const LiteralEnv = struct {
    pub fn leaf(_: LiteralEnv, _: Ast.ExprId) ?Const {
        return null;
    }
    pub fn signed(_: LiteralEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    pub fn width(_: LiteralEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};

// ponytail: literal operands only. A parameter's width is 32 unless A.2.1.1's
// `[ range ]` sized it, and an expression's is §5.4's sizing rules; carry a
// width beside `Const` if a model ever reduces either.

/// IEEE 1364-2005 §5.1.11: "The unary reduction operators shall perform a
/// bitwise operation on a single operand to produce a single-bit result", so
/// the answer depends on the operand's width, which a `Const` does not carry.
/// A literal has one: its size, or unsized the width `operandWidth` gives it
/// (§3.2's 32 bits, or 64 when 32 do not hold its value); any other operand,
/// and a size past 64, declines. §4.2.10 bars these operators from the analog
/// block, not from a parameter declaration.
fn reduction(ex: *const Ast.ExprStore, op: Ast.UnaryOp, operand: Ast.ExprId, a: Const) ?Const {
    if (a != .int) return null;
    if (ex.tag(operand) != .int_literal) return null;
    const w = literalWidth(ex, operand);
    if (w > 64) return null;
    const width: u7 = @intCast(w);
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

test "negate and abs wrap a 32-bit operand and keep a wider literal's width" {
    const min32: i64 = std.math.minInt(i32);
    try std.testing.expectEqual(min32, unary(.minus, .{ .int = min32 }).?.int);
    try std.testing.expectEqual(min32, math(.abs, &.{.{ .int = min32 }}).?.int);
    try std.testing.expectEqual(@as(i64, -5000000000), unary(.minus, .{ .int = 5000000000 }).?.int);
    try std.testing.expectEqual(@as(i64, 5000000000), math(.abs, &.{.{ .int = -5000000000 }}).?.int);
}

const testing = std.testing;

fn expectInt(want: i64, got: ?Const) !void {
    const c = got orelse return error.TestExpectedEqual;
    try testing.expect(c == .int);
    try testing.expectEqual(want, c.int);
}

fn expectReal(want: f64, got: ?Const) !void {
    const c = got orelse return error.TestExpectedEqual;
    try testing.expect(c == .real);
    try testing.expectEqual(want, c.real);
}

test "Const conversions: §4.2.1.1 rounding, the i64 range, and truth" {
    // §4.2.1.1: a real converts to an integer by rounding to nearest, ties
    // away from zero.
    try testing.expectEqual(@as(?i64, 3), (Const{ .real = 2.5 }).asIntExact());
    try testing.expectEqual(@as(?i64, -3), (Const{ .real = -2.5 }).asIntExact());
    try testing.expectEqual(@as(?i64, 2), (Const{ .real = 2.4999 }).asIntExact());
    // 2^63 is the first double past i64; -2^63 is minInt itself.
    try testing.expectEqual(@as(?i64, null), (Const{ .real = 9223372036854775808.0 }).asIntExact());
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), (Const{ .real = -9223372036854775808.0 }).asIntExact());
    try testing.expectEqual(@as(?i64, null), (Const{ .real = std.math.nan(f64) }).asIntExact());
    try testing.expectEqual(@as(?i64, null), (Const{ .real = std.math.inf(f64) }).asIntExact());
    try testing.expectEqual(@as(?i64, 0), (Const{ .str = "12" }).asIntExact());
    try testing.expectEqual(@as(?i64, -7), (Const{ .int = -7 }).asIntExact());
    // `asInt` saturates and maps NaN to 0 instead of failing.
    try testing.expectEqual(std.math.maxInt(i64), (Const{ .real = 1e300 }).asInt());
    try testing.expectEqual(std.math.minInt(i64), (Const{ .real = -1e300 }).asInt());
    try testing.expectEqual(@as(i64, 0), (Const{ .real = std.math.nan(f64) }).asInt());
    try testing.expectEqual(@as(f64, 0), (Const{ .str = "1.5" }).asReal());
    try testing.expectEqual(@as(f64, -4), (Const{ .int = -4 }).asReal());
    try testing.expect(!(Const{ .str = "" }).isTrue());
    try testing.expect((Const{ .str = "0" }).isTrue());
    try testing.expect(!(Const{ .real = -0.0 }).isTrue());
    try testing.expect((Const{ .real = std.math.nan(f64) }).isTrue());
    // §3.2's 32-bit wrap.
    try testing.expectEqual(@as(i64, -2147483648), wrap32(2147483648));
    try testing.expectEqual(@as(i64, 2147483647), wrap32(-2147483649));
    try testing.expectEqual(@as(i64, 0), wrap32(4294967296));
}

test "§3.4.1 parameterValue converts to the declared type; a host card does not impose `integer`'s wrap" {
    try expectReal(3, parameterValue(.real, .{ .int = 3 }));
    try testing.expect(parameterValue(.real, .{ .str = "s" }) == .str);
    try expectInt(3, parameterValue(.integer, .{ .real = 2.5 }));
    try expectInt(1, parameterValue(.integer, .{ .int = 4294967297 }));
    // A real with no integer value stays real, for the caller's diagnostic.
    try testing.expect(parameterValue(.integer, .{ .real = std.math.nan(f64) }) == .real);
    try expectInt(4, parameterValue(.string, .{ .int = 4 }));
    try expectReal(0.5, parameterValue(.unspecified, .{ .real = 0.5 }));
    // 5e9 mod 2^32 = 705032704: an `integer` declaration wraps the card...
    try expectInt(705032704, parameterCardValue(.integer, null, 5e9));
    // ...an inferred integral one keeps the whole value...
    try expectInt(5000000000, parameterCardValue(.unspecified, .{ .int = 1 }, 5e9));
    // ...rounding a fraction as §4.2.1.1 does, unless the default was real.
    try expectInt(3, parameterCardValue(.unspecified, .{ .int = 1 }, 2.5));
    try expectReal(3, parameterCardValue(.unspecified, .{ .real = 1 }, 3));
    try expectReal(3, parameterCardValue(.unspecified, null, 3));
}

test "ipow32 agrees with repeated 32-bit multiplication" {
    // Oracle: n wrapping multiplications of the truncated base, which is
    // what §3.2's 32-bit power is for n >= 0.
    var prng = std.Random.DefaultPrng.init(0x1364_0506);
    const random = prng.random();
    for (0..4000) |i| {
        const b: i64 = if (i < 1000) @as(i64, @intCast(i % 11)) - 5 else random.int(i32);
        const reps: usize = i % 70;
        var want: i32 = 1;
        for (0..reps) |_| want *%= @as(i32, @truncate(b));
        try testing.expectEqual(@as(?i64, want), ipow32(b, @intCast(reps)));
    }
    // A huge even or odd exponent of -1, and of 2 (which wraps to 0).
    try testing.expectEqual(@as(?i64, 1), ipow32(-1, 1 << 40));
    try testing.expectEqual(@as(?i64, -1), ipow32(-1, (1 << 40) + 1));
    try testing.expectEqual(@as(?i64, 0), ipow32(2, 1 << 40));
}

test "unary folds a sign, a logical not and a complement; reductions need a width" {
    try testing.expect(unary(.plus, .{ .str = "s" }).? == .str);
    try testing.expect(unary(.minus, .{ .str = "s" }) == null);
    try expectReal(-1.5, unary(.minus, .{ .real = 1.5 }));
    try expectInt(std.math.minInt(i64), unary(.minus, .{ .int = std.math.minInt(i64) }));
    try expectInt(1, unary(.logical_not, .{ .real = 0.0 }));
    try expectInt(0, unary(.logical_not, .{ .str = "a" }));
    try expectInt(-1, unary(.bit_not, .{ .int = 0 }));
    for ([_]Ast.UnaryOp{ .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor }) |op|
        try testing.expect(unary(op, .{ .int = 3 }) == null);
}

test "binary over integers: §3.2's 32-bit wrap, §4.2.11 shifts, and the cases that have no value" {
    const Case = struct { Ast.BinaryOp, i64, i64, ?bool, ?i64 };
    const min32: i64 = std.math.minInt(i32);
    for ([_]Case{
        .{ .add, 2147483647, 1, null, min32 },
        .{ .sub, min32, 1, null, 2147483647 },
        .{ .mul, 65536, 65536, null, 0 },
        // Division truncates toward zero; the remainder has the dividend's sign.
        .{ .div, -7, 2, null, -3 },
        .{ .div, 7, -2, null, -3 },
        .{ .div, 1, 0, null, null },
        // minInt(i64) / -1 is 2^63, whose low 32 bits are 0.
        .{ .div, std.math.minInt(i64), -1, null, 0 },
        .{ .mod, -7, 2, null, -1 },
        .{ .mod, 7, -2, null, 1 },
        .{ .mod, 5, 0, null, null },
        .{ .mod, std.math.minInt(i64), -1, null, 0 },
        .{ .pow, 2, 10, null, 1024 },
        .{ .pow, 0, -1, null, null },
        .{ .eq, 3, 3, null, 1 },
        .{ .neq, 3, 3, null, 0 },
        .{ .lt, -1, 0, null, 1 },
        .{ .le, 0, 0, null, 1 },
        .{ .gt, 0, -1, null, 1 },
        .{ .ge, -1, 0, null, 0 },
        .{ .bit_and, 12, 10, null, 8 },
        .{ .bit_or, 12, 10, null, 14 },
        .{ .bit_xor, 12, 10, null, 6 },
        .{ .bit_xnor, 12, 10, null, -7 },
        .{ .logical_and, 2, 0, null, 0 },
        .{ .logical_or, 0, 3, null, 1 },
        // `1 << 31` is negative and `1 << 32` zero at 32 bits; a count
        // outside 0..63 has no constant value here.
        .{ .shl, 1, 31, null, min32 },
        .{ .shl, 1, 32, null, 0 },
        .{ .shl, 3, 63, null, 0 },
        .{ .shl, 1, -1, null, null },
        .{ .shl, 1, 64, null, null },
        // `>>` zero-fills over 32 bits: -16 >> 2 is 0x3FFFFFFC.
        .{ .shr, -16, 2, null, 1073741820 },
        .{ .shr, -16, 0, null, -16 },
        .{ .shr, -16, 32, null, 0 },
        .{ .shr, 1, 64, null, null },
        .{ .ashl, 1, 31, null, min32 },
        // `>>>` fills with the sign bit only when the operand is signed.
        .{ .ashr, -16, 2, true, -4 },
        .{ .ashr, -16, 40, true, -1 },
        .{ .ashr, -16, 2, false, 1073741820 },
        .{ .ashr, -1, 32, false, 0 },
        .{ .ashr, -16, 2, null, null },
        .{ .ashr, -16, -1, true, null },
        .{ .case_eq, 3, 3, null, 1 },
        .{ .case_neq, 3, 4, null, 1 },
    }) |c| {
        const got = binary(c[0], .{ .int = c[1] }, .{ .int = c[2] }, c[3]);
        if (c[4]) |want| try expectInt(want, got) else try testing.expect(got == null);
    }
}

test "binary over reals and strings: IEEE arithmetic, Table 3-3, and the mixes that decline" {
    try expectReal(std.math.inf(f64), binary(.div, .{ .real = 1 }, .{ .real = 0 }, null));
    try testing.expect(binary(.mod, .{ .real = 5 }, .{ .real = 0 }, null) == null);
    try expectReal(1.5, binary(.mod, .{ .real = 7.5 }, .{ .int = 2 }, null));
    try expectReal(1.5, binary(.add, .{ .int = 1 }, .{ .real = 0.5 }, null));
    try expectInt(1, binary(.lt, .{ .int = 1 }, .{ .real = 1.5 }, null));
    try testing.expect(binary(.ashr, .{ .real = 8 }, .{ .int = 1 }, true) == null);
    try testing.expect(binary(.case_eq, .{ .real = 3 }, .{ .real = 3 }, null) == null);
    const p = binary(.pow, .{ .real = 2 }, .{ .real = 0.5 }, null).?.real;
    try testing.expect(std.math.approxEqRel(f64, std.math.sqrt2, p, 1e-15));
    // Table 3-3: equality and lexicographic order, nothing else.
    try expectInt(1, binary(.lt, .{ .str = "ab" }, .{ .str = "b" }, null));
    try expectInt(1, binary(.eq, .{ .str = "ab" }, .{ .str = "ab" }, null));
    try expectInt(0, binary(.eq, .{ .str = "slow" }, .{ .str = "fast" }, null));
    try expectInt(1, binary(.ge, .{ .str = "b" }, .{ .str = "b" }, null));
    try testing.expect(binary(.add, .{ .str = "a" }, .{ .str = "b" }, null) == null);
    try testing.expect(binary(.eq, .{ .str = "a" }, .{ .int = 1 }, null) == null);
}

test "§4.3 math: integer abs/min/max, the conditional min/max, and arity" {
    try testing.expect(math(.sqrt, &.{ .{ .real = 1 }, .{ .real = 2 } }) == null);
    try testing.expect(math(.min, &.{.{ .int = 1 }}) == null);
    try testing.expect(math(.exp, &.{.{ .str = "1" }}) == null);
    try expectInt(3, math(.abs, &.{.{ .int = -3 }}));
    try expectInt(std.math.minInt(i64), math(.abs, &.{.{ .int = std.math.minInt(i64) }}));
    try expectReal(2.5, math(.abs, &.{.{ .real = -2.5 }}));
    try expectInt(1, math(.min, &.{ .{ .int = 1 }, .{ .int = 2 } }));
    try expectInt(2, math(.max, &.{ .{ .int = 1 }, .{ .int = 2 } }));
    try expectReal(1, math(.min, &.{ .{ .int = 1 }, .{ .real = 2 } }));
    // §4.3.1 "(x < y) ? x : y": a NaN first loses, a NaN second wins, and
    // the second of two zeros is taken.
    const nan = std.math.nan(f64);
    try expectReal(1, math(.min, &.{ .{ .real = nan }, .{ .real = 1 } }));
    try testing.expect(std.math.isNan(math(.min, &.{ .{ .real = 1 }, .{ .real = nan } }).?.real));
    try expectReal(1, math(.max, &.{ .{ .real = nan }, .{ .real = 1 } }));
    try testing.expect(!std.math.signbit(math(.min, &.{ .{ .real = -0.0 }, .{ .real = 0.0 } }).?.real));
    try testing.expect(std.math.signbit(math(.min, &.{ .{ .real = 0.0 }, .{ .real = -0.0 } }).?.real));
    // `log` is decimal (§4.3.1), `ln` natural.
    try testing.expect(std.math.approxEqAbs(f64, 3, math(.log, &.{.{ .int = 1000 }}).?.real, 1e-15));
    try testing.expect(std.math.approxEqAbs(f64, 1, math(.ln, &.{.{ .real = std.math.e }}).?.real, 1e-15));
    try expectReal(-2, math(.floor, &.{.{ .real = -1.5 }}));
    try expectReal(-1, math(.ceil, &.{.{ .real = -1.5 }}));
    try expectReal(5, math(.hypot, &.{ .{ .int = 3 }, .{ .int = 4 } }));
    try testing.expect(std.math.approxEqAbs(f64, std.math.pi, math(.atan2, &.{ .{ .real = 0 }, .{ .real = -1 } }).?.real, 1e-15));
    try testing.expect(std.math.isNan(math(.sqrt, &.{.{ .real = -1 }}).?.real));
    // Every name, and only the five two-argument functions take two.
    for (std.enums.values(MathFn)) |f| {
        try testing.expectEqual(@as(?MathFn, f), MathFn.fromName(@tagName(f)));
        const two = f == .min or f == .max or f == .pow or f == .hypot or f == .atan2;
        try testing.expectEqual(@as(usize, if (two) 2 else 1), f.arity());
    }
    try testing.expectEqual(@as(?MathFn, null), MathFn.fromName("LOG"));
    try testing.expectEqual(@as(?MathFn, null), MathFn.fromName("log10"));
}

test "IntContext.normalize agrees with modular arithmetic at every width" {
    // Oracle: the value modulo 2^width in i128, less 2^width when signed and
    // at or above 2^(width-1).
    var prng = std.Random.DefaultPrng.init(0x0555_0002);
    const random = prng.random();
    for (0..5000) |_| {
        const width = random.intRangeAtMost(u32, 1, 70);
        const signed = random.boolean();
        const value = random.int(i64) >> random.int(u6);
        var want: i128 = value;
        if (width < 64) {
            const m: i128 = @as(i128, 1) << @intCast(width);
            want = @mod(want, m);
            if (signed and want >= @divExact(m, 2)) want -= m;
        }
        try testing.expectEqual(@as(i64, @intCast(want)), (IntContext{ .width = width, .signed = signed }).normalize(value));
    }
    // 4 bits signed holds 15 as -1, then widens unchanged; unsigned, 31 is 15.
    const plan: IntPlan = .{ .result = .{ .width = 8, .signed = true }, .from_width = 4 };
    try testing.expectEqual(@as(i64, -1), plan.resize(15));
    const unsigned: IntPlan = .{ .result = .{ .width = 8, .signed = false }, .from_width = 4 };
    try testing.expectEqual(@as(i64, 15), unsigned.resize(31));
}

test "clog2 is the least k with 2^k at or above the unsigned value" {
    // Oracle: the smallest k for which 2^k >= the value read unsigned at
    // `width`, counted in u128.
    for (1..13) |w| {
        const width: u32 = @intCast(w);
        for (0..@as(usize, 1) << @intCast(w)) |v| {
            var k: i64 = 0;
            while ((@as(u128, 1) << @intCast(k)) < v) k += 1;
            try testing.expectEqual(k, clog2(@intCast(v), width));
        }
        // A negative carrier value is read at `width` bits, unsigned.
        try testing.expectEqual(clog2((@as(i64, 1) << @intCast(w)) - 1, width), clog2(-1, width));
    }
    try testing.expectEqual(@as(i64, 64), clog2(-1, 64));
    try testing.expectEqual(@as(i64, 63), clog2((1 << 62) | 1, 64));
    try testing.expectEqual(@as(i64, 65), clog2(-1, 65));
    try testing.expectEqual(@as(i64, 3), clog2(5, 70));
}

test "UnsignedCompare.extend masks each side at its own width and orders 64-bit pairs as u64" {
    const u: UnsignedCompare = .{ .mask = .{ 0xff, null }, .flip = false };
    try testing.expectEqual(@as(i64, 255), u.extend(.lhs, -1));
    try testing.expectEqual(@as(i64, -1), u.extend(.rhs, -1));
    const f: UnsignedCompare = .{ .mask = .{ null, null }, .flip = true };
    try testing.expect(f.extend(.lhs, -1) > f.extend(.rhs, 1));
}

/// `fold`'s environment in these tests: `a` is a signed 32-bit integer
/// holding -1 and `u` an unsigned 8-bit one holding 255; a literal reports its
/// own signedness, as lowering's environment does.
const TestEnv = struct {
    file: *const Ast.SourceFile,

    fn name(env: TestEnv, e: Ast.ExprId) ?[]const u8 {
        if (env.file.exprs.tag(e) != .ident) return null;
        return env.file.str(env.file.exprs.strOf(e));
    }
    pub fn leaf(env: TestEnv, e: Ast.ExprId) ?Const {
        const n = env.name(e) orelse return null;
        if (std.mem.eql(u8, n, "a")) return .{ .int = -1 };
        if (std.mem.eql(u8, n, "u")) return .{ .int = 255 };
        return null;
    }
    pub fn signed(env: TestEnv, e: Ast.ExprId) ?bool {
        const ex = &env.file.exprs;
        if (ex.tag(e) == .int_literal) return ex.intLiteral(e).signed;
        if (ex.tag(e) == .logic_literal) return ex.logicValue(e).signed;
        const n = env.name(e) orelse return null;
        if (std.mem.eql(u8, n, "a")) return true;
        if (std.mem.eql(u8, n, "u")) return false;
        return null;
    }
    pub fn width(env: TestEnv, e: Ast.ExprId) ?u32 {
        const n = env.name(e) orelse return null;
        if (std.mem.eql(u8, n, "a")) return 32;
        if (std.mem.eql(u8, n, "u")) return 8;
        return null;
    }
};

const TestExpr = struct { file: Ast.SourceFile, e: Ast.ExprId, vars: []const Ast.VarDecl };

/// Parses `module m; <decls> parameter p = <src>; endmodule` with the real
/// lexer and parser, and returns `p`'s default.
fn testParse(arena: std.mem.Allocator, decls: []const u8, src: []const u8) !TestExpr {
    const text = try arena.print("module m; {s} parameter p = {s}; endmodule\n", .{ decls, src });
    const r = try @import("parser/test.zig").parseForTest(arena, text);
    try testing.expectEqual(@as(u32, 0), r.bag.err_count);
    const m = r.file.modules[0];
    return .{ .file = r.file, .e = m.params[0].default, .vars = m.vars };
}

fn testFold(arena: std.mem.Allocator, src: []const u8, comptime sized: bool) !?Const {
    const t = try testParse(arena, "", src);
    const env: TestEnv = .{ .file = &t.file };
    return if (sized) foldSized(&t.file, t.e, env) else fold(&t.file, t.e, env);
}

test "fold over parsed constant expressions: literals, operators, a lazy ?:, §4.3 calls and names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectInt(3, try testFold(a, "1 + 2", false));
    try expectInt(-2147483648, try testFold(a, "2147483647 + 1", false));
    try expectReal(3, try testFold(a, "1.5 * 2", false));
    try expectInt(1, try testFold(a, "\"ab\" == \"ab\"", false));
    // §4.2.12: only the taken arm has to have a value.
    try expectInt(4, try testFold(a, "1 ? 4 : 1/0", false));
    try expectInt(5, try testFold(a, "0 ? 1/0 : 5", false));
    // `fold` evaluates both operands of `&&`; `foldSized` short-circuits.
    try testing.expect((try testFold(a, "0 && 1/0", false)) == null);
    try expectInt(0, try testFold(a, "0 && 1/0", true));
    try expectInt(1, try testFold(a, "1 || 1/0", true));
    try expectInt(-1, try testFold(a, "a", false));
    try testing.expect((try testFold(a, "zz", false)) == null);
    try expectReal(2, try testFold(a, "sqrt(4.0)", false));
    try testing.expect(std.math.approxEqRel(f64, 8, (try testFold(a, "pow(2, 3)", false)).?.real, 1e-15));
    try expectInt(3, try testFold(a, "abs(-3)", false));
    try expectReal(1, try testFold(a, "min(1, 2.0)", false));
    try expectInt(7, try testFold(a, "max(a, 7)", false));
    try expectInt(255, try testFold(a, "8'hff", false));
    // A four-state literal has no analog value; a wide one with an i64 value does.
    try testing.expect((try testFold(a, "4'b1x01", false)) == null);
    try expectInt(5, try testFold(a, "128'h5", false));
    try expectInt(8, try testFold(a, "-4'sb1000", false));
    // `literal_env` folds literals and declines a name.
    const t = try testParse(a, "", "a + 1");
    try testing.expect(fold(&t.file, t.e, literal_env) == null);
    const lit = try testParse(a, "", "2 * 3");
    try expectInt(6, fold(&lit.file, lit.e, literal_env));
}

test "IEEE 1364-2005 §5.1.11 reductions fold over a literal at its size, or an unsized one's width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, ?i64 };
    for ([_]Case{
        .{ "&4'b1111", 1 },
        .{ "~&4'b1111", 0 },
        .{ "|4'b0000", 0 },
        .{ "~|4'b0000", 1 },
        .{ "^3'b111", 1 },
        .{ "~^3'b111", 0 },
        .{ "&64'hFFFF_FFFF_FFFF_FFFF", 1 },
        .{ "^64'h8000_0000_0000_0001", 0 },
        // Unsized: §3.2's 32 bits, so 15 is not all ones and 2^32-1 is.
        .{ "&15", 0 },
        .{ "~&15", 1 },
        .{ "&4294967295", 1 },
        // 2^32 needs 64 bits (`operandWidth`), and its one bit is set.
        .{ "|4294967296", 1 },
        .{ "&4294967296", 0 },
        // No width to read: a wide literal, or anything but a literal.
        .{ "&65'h1", null },
        .{ "&(1 + 1)", null },
    }) |c| {
        const got = try testFold(a, c[0], false);
        if (c[1]) |want| try expectInt(want, got) else try testing.expect(got == null);
    }
}

test "§4.2.9 a comparison with an unsigned operand compares unsigned values at each operand's own width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `a` is a signed 32-bit -1: against an unsigned operand it is 2^32-1.
    try expectInt(1, try testFold(a, "a > 40'h0", false));
    try expectInt(1, try testFold(a, "a == 32'hFFFF_FFFF", false));
    try expectInt(1, try testFold(a, "a < 0", false));
    // 8-bit 255 against 2^32-1.
    try expectInt(0, try testFold(a, "u > a", false));
    // A 64-bit unsigned literal orders as a u64.
    try expectInt(1, try testFold(a, "64'hFFFF_FFFF_FFFF_FFFF > 1", false));
    // §5.1.12 `>>>` reads the left operand's signedness from the environment.
    try expectInt(-1, try testFold(a, "a >>> 1", false));
    try expectInt(127, try testFold(a, "u >>> 1", false));
    try expectInt(-1, try testFold(a, "8'shff >>> 1", false));
}

test "foldSized: IEEE §§5.4-5.5 propagate a context's width and signedness into the operands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 4-bit addition wraps at 4 bits; `fold`'s carrier does not.
    try expectInt(0, try testFold(a, "4'b1111 + 4'b0001", true));
    try expectInt(16, try testFold(a, "4'b1111 + 4'b0001", false));
    try expectInt(0, try testFold(a, "4'sb1111 + 8'sb1", true));
    // -(-8) at 4 signed bits is -8 again.
    try expectInt(-8, try testFold(a, "-4'sb1000", true));
    try expectInt(4, try testFold(a, "4'b1000 >> 1", true));
    try expectInt(-4, try testFold(a, "4'sb1000 >>> 1", true));
    // Both sides become 32-bit unsigned: 255 against 2^32-1.
    try expectInt(0, try testFold(a, "8'hFF == -1", true));
    try expectInt(15, try testFold(a, "1 ? 4'b1111 : 8'h00", true));
    // Arithmetic wider than 32 bits is past the carrier's plan.
    try testing.expect((try testFold(a, "40'h1 + 40'h1", true)) == null);
}

test "operandWidth, clog2Width and clog2Signed size an expression as §2.6.1 and IEEE §5.4-5.5 do" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const W = struct { []const u8, ?u32, ?u32 };
    // Source, operandWidth, clog2Width.
    for ([_]W{
        .{ "4'b1010", 4, 4 },
        .{ "5000000000", 64, 64 },
        .{ "7", 32, 32 },
        .{ "-4'sb1", 32, 4 },
        .{ "~40'h1", 40, 40 },
        .{ "a < 1", 32, 1 },
        .{ "!u", 32, 1 },
        .{ "$realtobits(1.0)", 64, 64 },
        .{ "1 ? 8'h1 : 40'h1", 40, 40 },
        .{ "u", 8, 8 },
        .{ "u + u", 32, 8 },
        .{ "4'b1 + 8'b1", 32, 8 },
        .{ "4'b1 << 3", 32, 4 },
        .{ "u ** 2", 32, 8 },
        .{ "128'h1", 128, 128 },
        .{ "zz", null, null },
    }) |c| {
        const t = try testParse(a, "", c[0]);
        const env: TestEnv = .{ .file = &t.file };
        try testing.expectEqual(c[1], operandWidth(&t.file, t.e, env));
        try testing.expectEqual(c[2], clog2Width(&t.file, t.e, env));
    }
    const S = struct { []const u8, ?bool };
    for ([_]S{
        .{ "4'sb1", true },
        .{ "4'b1", false },
        .{ "4'sb1 + 4'b1", false },
        .{ "4'sb1 << 4'b1", true },
        .{ "1 == 1", false },
        .{ "~4'sb1", true },
        .{ "$realtobits(1.0)", false },
        .{ "$random", true },
        .{ "a", true },
        .{ "1.5", null },
    }) |c| {
        const t = try testParse(a, "", c[0]);
        try testing.expectEqual(c[1], clog2Signed(&t.file, t.e, TestEnv{ .file = &t.file }));
    }
}

test "§3.4 firstStateRead names the first simulation-state or variable read of a default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, ?[]const u8 };
    for ([_]Case{
        .{ "x + 1", "x" },
        .{ "$abstime * 2", "$abstime" },
        .{ "1 + $temperature", "$temperature" },
        .{ "$random", "$random" },
        .{ "$dist_normal(1, 2, 3)", "$dist_normal" },
        .{ "$rdist_uniform(1, 2, 3)", "$rdist_uniform" },
        // §9.15's table is the host's, constant for the run.
        .{ "$simparam(\"gmin\")", null },
        .{ "2 * y", null },
        .{ "2 * 3", null },
    }) |c| {
        const t = try testParse(a, "real x;", c[0]);
        const got = firstStateRead(&t.file, t.e, t.vars);
        if (c[1]) |want| try testing.expectEqualStrings(want, got.?) else try testing.expect(got == null);
    }
}
