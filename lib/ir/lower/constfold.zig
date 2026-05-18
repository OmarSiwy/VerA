//! Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds.
//!
//! In: an expression AST and the current scope. Out: a `Const`, or null when the expression
//! is not constant. Reads the symbol tables, never writes. The operator rules are
//! `frontend/constfold.zig`'s; this file supplies identifiers (through `consts`) and §4.2.9 signedness.
//! LRM: §2.7, §3.2, §3.4, §3.5, §4.2, §4.2.1, §4.2.9, §4.2.11, §4.3, §4.7.2, §6.6.1, §6.6.2.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_expr = @import("expr.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Const = constfold.Const;

/// Folds an elaboration-time constant: literals, genvars (LRM §3.5) and parameters
/// (LRM §3.4, §6.6.1). Returns null when the expression is not constant.
pub fn constEval(self: *const Lower, e: Ast.ExprId) ?Const {
    return foldExpr(self, e, true);
}

/// Folds a shape: an array or vector bound, a replication count, or a generate
/// scheme's bounds. Marks every parameter it reads `ParamInfo.shape`, because the
/// device cannot follow a model card there; codegen's `checkShape` refuses a card
/// that moves one (LRM §3.4).
pub fn shapeEval(self: *Lower, e: Ast.ExprId) ?Const {
    return constfold.fold(self.file, e, Env{ .self = self, .params = true, .shape = self });
}

/// Folds `e` to a constant, or returns null. With `params = false` parameters do not
/// fold: a procedural `if (p > 0)` stays a runtime branch because the model card can
/// override `p` (LRM §3.4, §6.6.2).
pub fn foldExpr(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    return constfold.fold(self.file, e, Env{ .self = self, .params = params });
}

/// What `constfold.fold` asks of lowering: identifiers through `consts`, and
/// the operand signedness and name widths of `>>>` and §4.2.9's comparisons.
const Env = struct {
    self: *const Lower,
    params: bool,
    /// `shapeEval`'s: where a parameter read in a shape is marked.
    shape: ?*Lower = null,

    /// Returns the constant an identifier or conversion call names, or null.
    pub fn leaf(env: Env, e: Ast.ExprId) ?Const {
        const self = env.self;
        const ex = &self.file.exprs;
        if (ex.tag(e) == .sys_call) return conversion(env, e);
        if (ex.tag(e) != .ident) return null;
        const name = self.file.str(ex.strOf(e));
        if (self.vars.contains(name)) return null; // a runtime variable
        // A function-local parameter is not overridable by a model card
        // (§4.7.2: it never reaches the Model), so `foldExpr(..., false)`'s refusal
        // to look through a parameter does not apply to a shadowing local.
        if (self.param_index.get(name)) |i| if (!lower_expr.funcParamShadows(self, name)) {
            if (!env.params) return null;
            if (env.shape) |l| l.out.params.items[i].shape = true;
        };
        return self.consts.get(name);
    }
    /// IEEE 1364-2005 §5.2 (VAMS §1.1): "the system functions allowed in
    /// constant expressions are the conversion system functions listed in 17.8
    /// and the mathematical system functions listed in 17.11"; VAMS §9.11
    /// admits the conversions to the analog context. §17.8: `$rtoi` converts
    /// "by truncating", `$itor` "integers to real values".
    // ponytail: $rtoi/$itor and $clog2 only. $realtobits/$bitstoreal need a 64-bit
    // pattern `Const.int` would carry signed; add them when a default uses one.
    fn conversion(env: Env, e: Ast.ExprId) ?Const {
        const self = env.self;
        const ex = &self.file.exprs;
        const name = self.file.str(ex.strOf(e));
        const args = ex.args(e);
        if (args.len != 1) return null;
        const a = constfold.fold(self.file, args[0], env) orelse return null;
        if (a == .str) return null;
        if (std.mem.eql(u8, name, "$rtoi")) {
            // §3.2's 32-bit integer; anything outside it (or NaN) stays a
            // run-time question rather than a folded guess.
            const t = @trunc(a.asReal());
            if (!(t >= -2147483648.0 and t <= 2147483647.0)) return null;
            return .{ .int = @intFromFloat(t) };
        }
        if (std.mem.eql(u8, name, "$itor")) return .{ .real = @floatFromInt(a.asIntExact() orelse return null) };
        // §9.14 / IEEE 1364-2005 §17.11.1, one of the "mathematical system
        // functions listed in 17.11": "the ceiling of the log base 2 of the
        // argument (the log rounded up to an integer value)". A non-negative
        // integer argument only (0 and 1 both give 0); the
        // unsigned reading of a negative argument stays a run-time question.
        if (std.mem.eql(u8, name, "$clog2")) {
            const n = a.asIntExact() orelse return null;
            if (n < 0) return null;
            if (n <= 1) return .{ .int = 0 };
            const u: u64 = @intCast(n - 1);
            return .{ .int = 64 - @as(i64, @clz(u)) };
        }
        return null;
    }
    /// Returns `e`'s source signedness, or null when nothing states it.
    pub fn signed(env: Env, e: Ast.ExprId) ?bool {
        return integerSourceSigned(env.self, e, 0);
    }
    /// Returns name `e`'s bit length, or null when nothing states it.
    pub fn width(env: Env, e: Ast.ExprId) ?u32 {
        return nameWidth(env.self, e, 0);
    }
};

/// The bit length of integer name `e`: §3.2's 32 bits for an `integer`
/// variable or typed parameter, an untyped local parameter's default's
/// (IEEE 1364-2005 §12.2, "the type and range of the final value assigned"),
/// and null for one the host may override, or anything not an integer.
fn nameWidth(self: *const Lower, e: Ast.ExprId, depth: u32) ?u32 {
    if (depth > 32) return null;
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (self.vars.get(name)) |v| return if (v.ty == .integer) 32 else null;
    if (self.arrays.get(name)) |a| return if (a.ty == .integer) 32 else null;
    const deeper = WidthEnv{ .self = self, .depth = depth + 1 };
    for (self.func_params) |p| {
        if (!self.file.strings.eql(p.name, name)) continue;
        return if (p.ty == .integer) 32 else if (p.ty == .unspecified) constfold.operandWidth(self.file, p.default, deeper) else null;
    }
    const pi = self.param_index.get(name) orelse return null;
    const p = self.out.params.items[pi];
    if (p.ty != .integer) return null;
    if (p.integer32) return 32;
    if (!p.is_local) return null;
    const module = self.out.module orelse return null;
    for (module.params) |decl| {
        if (std.mem.eql(u8, self.file.str(decl.name), p.name)) return constfold.operandWidth(self.file, decl.default, deeper);
    }
    return null;
}

/// `nameWidth` one level down, as `constfold.operandWidth`'s `env`.
const WidthEnv = struct {
    self: *const Lower,
    depth: u32,
    pub fn width(env: WidthEnv, e: Ast.ExprId) ?u32 {
        return nameWidth(env.self, e, env.depth);
    }
};

/// The signedness of an INTEGER expression, from what the source states: a
/// literal's base, a declaration's type, and IEEE 1364-2005 §5.5.1's rules for
/// the operators over them (VAMS §4.2.9 leaves expression signedness to 1364).
/// Null is "no evidence", never a guess: a real, a string, or a name whose type
/// only the host decides.
fn integerSourceSigned(self: *const Lower, e: Ast.ExprId, depth: u32) ?bool {
    if (e == .none or depth > 32) return null;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).signed,
        .logic_literal => ex.logicValue(e).signed,
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
            // §4.2.10 keeps the reductions out of the analog block, and §5.5.1
            // states no sign for `!`.
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => null,
        },
        .binary => switch (ex.binOp(e)) {
            // §4.2.11: the right operand "has no effect on the signedness of the
            // result"; 1364 §5.1.5: `**`'s second operand is self-determined.
            .shl, .shr, .ashl, .ashr, .pow => integerSourceSigned(self, ex.lhs(e), depth + 1),
            // §5.5.1, nonself-determined operands: "If any operand is unsigned,
            // the result is unsigned, regardless of the operator."
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => operandsSigned(self, ex.lhs(e), ex.rhs(e), depth + 1),
            // §5.5.1: "Comparison results (1, 0) are unsigned, regardless of the
            // operands."
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => false,
            // §5.5.1 states no sign for the logical operators.
            .logical_and, .logical_or => null,
        },
        // §4.2.12's two value arms are nonself-determined: the same §5.5.1 rule.
        .ternary => operandsSigned(self, ex.rhs(e), ex.ternaryElse(e), depth + 1),
        .index => integerSourceSigned(self, ex.lhs(e), depth + 1),
        else => null, // else: no declared integer provenance, so no evidence
    };
}

/// §5.5.1 over two nonself-determined operands: unsigned when either is, signed
/// when both are. Only when both are known integers: "If any operand is real,
/// the result is real", and a null operand may be one.
fn operandsSigned(self: *const Lower, a: Ast.ExprId, b: Ast.ExprId, depth: u32) ?bool {
    const sa = integerSourceSigned(self, a, depth) orelse return null;
    const sb = integerSourceSigned(self, b, depth) orelse return null;
    return sa and sb;
}

/// `constfold.unsignedCompare` for comparison `e`: how `cmp`'s signed opcodes
/// order its operands as §4.2.9's unsigned comparison, or null when both are
/// signed.
pub fn unsignedCompare(self: *const Lower, e: Ast.ExprId) ?constfold.UnsignedCompare {
    const ex = &self.file.exprs;
    return constfold.unsignedCompare(self.file, ex.lhs(e), ex.rhs(e), Env{ .self = self, .params = false });
}
