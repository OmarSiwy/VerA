//! Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds.
//!
//! In: an expression AST and the current scope. Out: a `Const`, or null when the expression
//! is not constant. Reads the symbol tables, never writes.
//!
//! LRM clauses this file's code cites: §2.7, §3.2, §3.4, §3.5, §4.2, §4.2.1, §4.2.9, §4.2.11, §4.3, §4.7.2, §6.6.1, §6.6.2.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_constfold.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_expr = @import("expr.zig");
const Ast = @import("frontend").Ast;
const Const = Lower.Const;
const wrap32 = Lower.wrap32;

// ---------------------------------------------------------------------------
// Class 9 — constant evaluation (LRM §4.2 constant_expression, §6.6.1)
// ---------------------------------------------------------------------------

/// Fold an elaboration-time constant: literals, genvars (§3.5) and parameters
/// (§3.4 — a parameter IS a constant expression for array bounds and
/// generate bounds, §6.6.1). Returns null when the expression is not constant.
pub fn constEval(self: *const Lower, e: Ast.ExprId) ?Const {
    return foldExpr(self, e, true);
}

/// With `params = false`, a procedural `if (p > 0)` must stay
/// a runtime branch — `p` is overridable by the model card, so folding it to
/// its default would silently compile the wrong arm (§3.4 vs §6.6.2).
pub fn foldExpr(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal => return .{ .int = ex.intValue(e) },
        .real_literal => return .{ .real = ex.realValue(e) },
        .str_literal => return .{ .str = self.file.str(ex.strOf(e)) },
        .pos_inf => return .{ .real = std.math.inf(f64) },
        .neg_inf => return .{ .real = -std.math.inf(f64) },
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) return null; // a runtime variable
            // A function-local parameter is NOT overridable by a model card
            // (§4.7.2 — it never reaches the Model), so `foldExpr(..., false)`'s refusal
            // to look through a parameter does not apply to a shadowing local.
            if (!params and self.param_index.contains(name) and !lower_expr.funcParamShadows(self, name)) return null;
            return self.consts.get(name);
        },
        .unary => {
            const a = foldExpr(self, ex.lhs(e), params) orelse return null;
            return switch (ex.unOp(e)) {
                .plus => a,
                .minus => switch (a) {
                    .int => |i| .{ .int = -i },
                    .real => |r| .{ .real = -r },
                    .str => null,
                },
                .logical_not => Const{ .int = @intFromBool(!a.isTrue()) },
                .bit_not => Const{ .int = ~a.asInt() },
                else => null,
            };
        },
        .binary => return foldBinary(self, e, params),
        .ternary => {
            const c = foldExpr(self, ex.lhs(e), params) orelse return null;
            return foldExpr(self, if (c.isTrue()) ex.rhs(e) else ex.ternaryElse(e), params);
        },
        // §4.3 math in a constant expression — the common subset only.
        .builtin_call => {
            const name = self.file.str(ex.strOf(e));
            const args = ex.args(e);
            if (args.len == 1) {
                const a = foldExpr(self, args[0], params) orelse return null;
                if (std.mem.eql(u8, name, "abs")) return switch (a) {
                    .int => |i| .{ .int = @intCast(@abs(i)) },
                    .real => |r| .{ .real = @abs(r) },
                    .str => null,
                };
                const x = a.asReal();
                const r: f64 = if (std.mem.eql(u8, name, "sqrt"))
                    @sqrt(x)
                else if (std.mem.eql(u8, name, "exp"))
                    @exp(x)
                else if (std.mem.eql(u8, name, "ln"))
                    @log(x)
                else if (std.mem.eql(u8, name, "log"))
                    @log10(x)
                else if (std.mem.eql(u8, name, "floor"))
                    @floor(x)
                else if (std.mem.eql(u8, name, "ceil"))
                    @ceil(x)
                else
                    return null;
                return .{ .real = r };
            }
            if (args.len == 2) {
                const a = foldExpr(self, args[0], params) orelse return null;
                const b = foldExpr(self, args[1], params) orelse return null;
                const int = a == .int and b == .int;
                if (std.mem.eql(u8, name, "min"))
                    return if (int) Const{ .int = @min(a.asInt(), b.asInt()) } else Const{ .real = @min(a.asReal(), b.asReal()) };
                if (std.mem.eql(u8, name, "max"))
                    return if (int) Const{ .int = @max(a.asInt(), b.asInt()) } else Const{ .real = @max(a.asReal(), b.asReal()) };
                if (std.mem.eql(u8, name, "pow"))
                    return .{ .real = std.math.pow(f64, a.asReal(), b.asReal()) };
                return null;
            }
            return null;
        },
        else => return null,
    }
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
pub fn foldStrBinary(op: Ast.BinaryOp, a: Const, b: Const) ?Const {
    if (a != .str or b != .str) return null;
    const c = std.mem.order(u8, a.str, b.str);
    return .{ .int = @intFromBool(switch (op) {
        .eq => c == .eq,
        .neq => c != .eq,
        .lt => c == .lt,
        .le => c != .gt,
        .gt => c == .gt,
        .ge => c != .lt,
        else => return null,
    }) };
}

pub fn foldBinary(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    const ex = &self.file.exprs;
    if (mixedShiftComparison(self, e)) return null;
    const a = foldExpr(self, ex.lhs(e), params) orelse return null;
    const b = foldExpr(self, ex.rhs(e), params) orelse return null;
    const op = ex.binOp(e);
    // Table 3-3, before anything numeric touches a string. `Const.asReal` is 0
    // for EVERY string, so `"slow" == "fast"` folded as `0 == 0` and came out
    // TRUE — silently, and only in the folder: `lowerBinary` compares strings
    // properly at runtime, so the same expression answered differently
    // depending on whether it was a constant expression. A `for` bound over
    // `(mode == "fast") ? 3 : 1` ran three times with `mode` at "slow".
    if (a == .str or b == .str) return foldStrBinary(op, a, b);
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
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @intCast(@rem(@as(i65, a.asInt()), @as(i65, b.asInt()))) })
        else
            Const{ .real = @rem(x, y) },
        .pow => .{ .real = std.math.pow(f64, x, y) },
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
        else => null,
    };
}

/// Only provenance present in the AST/declarations is evidence of signedness.
/// This is a refusal guard, not general expression context/type propagation.
pub fn integerSourceSigned(self: *const Lower, e: Ast.ExprId, depth: u32) ?bool {
    if (e == .none or depth > 32) return null;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).signed,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.get(name)) |v| break :blk if (v.ty == .integer) true else null;
            if (self.arrays.get(name)) |a| break :blk if (a.ty == .integer) true else null;
            for (self.func_params) |p| {
                if (!self.file.strings.eql(p.name, name)) continue;
                break :blk if (p.ty == .integer) true else if (p.ty == .unspecified) integerSourceSigned(self, p.default, depth + 1) else null;
            }
            const pi = self.param_index.get(name) orelse break :blk null;
            const p = self.params.items[pi];
            if (p.ty != .integer) break :blk null;
            if (p.integer32) break :blk true;
            if (!p.is_local) break :blk null; // host overrides carry no signedness
            const module = self.module orelse break :blk null;
            for (module.params) |decl| {
                if (std.mem.eql(u8, self.file.str(decl.name), p.name))
                    break :blk integerSourceSigned(self, decl.default, depth + 1);
            }
            break :blk null;
        },
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => integerSourceSigned(self, ex.lhs(e), depth + 1),
            else => null,
        },
        .binary => switch (ex.binOp(e)) {
            .shl, .shr => integerSourceSigned(self, ex.lhs(e), depth + 1),
            else => null,
        },
        .index => integerSourceSigned(self, ex.lhs(e), depth + 1),
        else => null,
    };
}

/// §4.2.9, the rule that makes signedness a property of the COMPARISON and not
/// of either operand: "When one or both operands are unsigned, the expression
/// shall be interpreted as a comparison between unsigned values. If the operands
/// are of unequal bit lengths, the smaller operand shall be zero-extended to the
/// size of the larger operand."
///
/// The mask that zero-extension is, or `null` when both operands are signed (or
/// nothing proves either one unsigned) and the ordinary signed compare stands.
/// Masking BOTH sides to the wider width is the whole of the rule: the results
/// are then non-negative, so the signed i64 opcodes `cmp` emits compare them as
/// the unsigned values §4.2.9 asks for. `a < 32'd1` with `a` at -1 is
/// 4294967295 < 1, not -1 < 1.
///
/// §3.2 supplies the width of everything that is not a sized literal: "variables
/// can hold values ranging from -2**31 to 2**31-1", so 32 bits.
///
/// ponytail: a 64-bit-or-wider sized literal declines the mask rather than
/// widening the carrier. `Lower`'s integer carrier is i64 and the top bit is its
/// sign, so a 64-bit unsigned comparison has nowhere to be performed; the
/// upgrade path is a u64 compare opcode pair in `cmp`.
pub fn unsignedCompareMask(self: *const Lower, e: Ast.ExprId) ?i64 {
    const ex = &self.file.exprs;
    const l = ex.lhs(e);
    const r = ex.rhs(e);
    const sl = integerSourceSigned(self, l, 0);
    const sr = integerSourceSigned(self, r, 0);
    const unsigned = (sl != null and !sl.?) or (sr != null and !sr.?);
    if (!unsigned) return null;
    const w = @max(operandWidth(self, l), operandWidth(self, r));
    if (w >= 64) return null;
    return (@as(i64, 1) << @intCast(w)) - 1;
}

/// §3.2's 32 bits, or a §2.6.1 sized literal's own declared size.
pub fn operandWidth(self: *const Lower, e: Ast.ExprId) u32 {
    const ex = &self.file.exprs;
    if (e != .none and ex.tag(e) == .int_literal) {
        const w = ex.intLiteral(e).width;
        if (w != 0) return w;
    }
    return 32;
}

pub fn isShiftOperand(self: *const Lower, e: Ast.ExprId, depth: u32) bool {
    if (e == .none or depth > 32) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .binary => ex.binOp(e) == .shl or ex.binOp(e) == .shr,
        .unary => isShiftOperand(self, ex.lhs(e), depth + 1),
        else => false,
    };
}

pub fn mixedShiftComparison(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    switch (ex.binOp(e)) {
        .eq, .neq, .lt, .le, .gt, .ge => {},
        else => return false,
    }
    const a = ex.lhs(e);
    const b = ex.rhs(e);
    if (!isShiftOperand(self, a, 0) and !isShiftOperand(self, b, 0)) return false;
    const sa = integerSourceSigned(self, a, 0) orelse return false;
    const sb = integerSourceSigned(self, b, 0) orelse return false;
    return sa != sb;
}

// ponytail: §4.7.2 function-local `parameter` declarations fold into `consts` and
//     are not restored on exit. DURING the body the shadowing is right —
//     `func_params` masks `param_index`, so the local wins there and the
//     module parameter wins again after the call (`lookupName` asks
//     `param_index` before `consts`). What remains is the CONSTANT-fold view
//     AFTER the call: `consts` still carries the local's value under that
//     name, so a later array bound or generate bound folding the shadowed name
//     reads the function's constant, not the module default. Give `consts` the
//     same save/restore treatment as `vars` if a fixture ever does that.
