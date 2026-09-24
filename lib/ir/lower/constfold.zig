//! Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds.
//!
//! In: an expression AST and the current scope. Out: a `Const`, or null when the expression
//! is not constant. Reads the symbol tables, never writes.
//!
//! LRM clauses this file's code cites: §2.7, §3.2, §3.4, §3.5, §4.2, §4.2.1, §4.2.9, §4.2.11, §4.3, §4.7.2, §6.6.1, §6.6.2.
//!
//! The operator rules are the shared kernel's (`frontend/constfold.zig`); this
//! file is lowering's `env` over it — identifiers through `consts` — plus the
//! §4.2.9 signedness questions. Functions take `self: *Lower` and are called
//! directly, `lower_constfold.f(self, ...)`.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_expr = @import("expr.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Const = constfold.Const;

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
    return constfold.fold(self.file, e, Env{ .self = self, .params = params });
}

/// What `constfold.fold` asks of lowering: identifiers through `consts`, the
/// §4.2.9 mixed-signedness shift comparison it must not fold, and `>>>`'s
/// operand signedness.
const Env = struct {
    self: *const Lower,
    params: bool,

    pub fn leaf(env: Env, e: Ast.ExprId) ?Const {
        const self = env.self;
        const ex = &self.file.exprs;
        if (ex.tag(e) != .ident) return null;
        const name = self.file.str(ex.strOf(e));
        if (self.vars.contains(name)) return null; // a runtime variable
        // A function-local parameter is NOT overridable by a model card
        // (§4.7.2 — it never reaches the Model), so `foldExpr(..., false)`'s refusal
        // to look through a parameter does not apply to a shadowing local.
        if (!env.params and self.param_index.contains(name) and !lower_expr.funcParamShadows(self, name)) return null;
        return self.consts.get(name);
    }
    pub fn refuse(env: Env, e: Ast.ExprId) bool {
        return mixedShiftComparison(env.self, e);
    }
    pub fn signed(env: Env, e: Ast.ExprId) ?bool {
        return integerSourceSigned(env.self, e, 0);
    }
};

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
            const p = self.out.params.items[pi];
            if (p.ty != .integer) break :blk null;
            if (p.integer32) break :blk true;
            if (!p.is_local) break :blk null; // host overrides carry no signedness
            const module = self.out.module orelse break :blk null;
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
