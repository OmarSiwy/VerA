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
/// result has no constant value (zero divisor, string mix, out-of-range
/// shift). `lhs_signed` is the left operand's signedness, read only by `>>>`
/// (IEEE 1364-2005 §5.1.12); null makes `>>>` decline.
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
        .min => if (int) Const{ .int = @min(args[0].int, args[1].int) } else Const{ .real = @min(x, y) },
        .max => if (int) Const{ .int = @max(args[0].int, args[1].int) } else Const{ .real = @max(x, y) },
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
/// operators, a lazy `?:`, and §4.3's math functions.
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
        // §2.6.1: an unsized number is "at least 32" bits; one no 32 bits
        // hold keeps the carrier's.
        .int_literal => if (ex.intLiteral(e).width != 0) ex.intLiteral(e).width else if (std.math.cast(u32, ex.intValue(e)) != null or std.math.cast(i32, ex.intValue(e)) != null) 32 else 64,
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

/// IEEE Table 5-22 and §5.5.2: logical operands, a shift/power's RHS, and a
/// conditional's condition are self-determined. Comparisons share a context
/// between their operands, independent of their one-bit result.
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
/// A literal has one (its size, or §3.2's 32 bits unsized); any other operand
/// declines. §4.2.10 bars these operators from the analog block, not from a
/// parameter declaration.
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

test "negate and abs wrap a 32-bit operand and keep a wider literal's width" {
    const min32: i64 = std.math.minInt(i32);
    try std.testing.expectEqual(min32, unary(.minus, .{ .int = min32 }).?.int);
    try std.testing.expectEqual(min32, math(.abs, &.{.{ .int = min32 }}).?.int);
    try std.testing.expectEqual(@as(i64, -5000000000), unary(.minus, .{ .int = 5000000000 }).?.int);
    try std.testing.expectEqual(@as(i64, 5000000000), math(.abs, &.{.{ .int = -5000000000 }}).?.int);
}
