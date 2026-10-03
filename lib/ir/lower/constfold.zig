//! Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds.
//!
//! In: an expression AST and the current scope. Out: a `Const`, or null when the expression
//! is not constant. Reads the symbol tables, never writes. The operator rules are
//! `frontend/constfold.zig`'s; this file supplies identifiers (through `consts`) and §4.2.9 signedness.
//! LRM: §2.7, §3.2, §3.4, §3.5, §4.2, §4.2.1, §4.2.9, §4.2.11, §4.3, §4.7.2, §6.6.1, §6.6.2.
//! §9.14 / IEEE §§5.4–5.5, §17.11.1 preserve the `$clog2` operand context.

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
        const is_clog2 = std.mem.eql(u8, name, "$clog2");
        const a = (if (is_clog2) constfold.foldSized(self.file, args[0], ClogEnv{ .base = env }) else constfold.fold(self.file, args[0], env)) orelse return null;
        if (a == .str) return null;
        if (std.mem.eql(u8, name, "$rtoi")) {
            // §3.2's 32-bit integer; anything outside it (or NaN) stays a
            // run-time question rather than a folded guess.
            const t = @trunc(a.asReal());
            if (!(t >= -2147483648.0 and t <= 2147483647.0)) return null;
            return .{ .int = @intFromFloat(t) };
        }
        if (std.mem.eql(u8, name, "$itor")) return .{ .real = @floatFromInt(a.asIntExact() orelse return null) };
        // §9.14 / IEEE 1364-2005 §17.11.1: interpret the argument unsigned
        // at its source width, not at the i64 carrier's width.
        if (is_clog2) {
            if (a != .int) return null;
            const bits = clog2Width(self, args[0]) orelse return null;
            if (bits > 64 and !clog2WideCarrier(self, args[0], 0)) return null;
            return .{ .int = constfold.clog2(a.int, bits) };
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

/// `Env` with `$clog2`'s width and signedness rules (`constfold.intPlan`'s env).
const ClogEnv = struct {
    base: Env,
    pub fn leaf(env: ClogEnv, e: Ast.ExprId) ?Const {
        return env.base.leaf(e);
    }
    pub fn width(env: ClogEnv, e: Ast.ExprId) ?u32 {
        return nameWidthFor(env.base.self, e, 0, true);
    }
    pub fn signed(env: ClogEnv, e: Ast.ExprId) ?bool {
        return clog2Signed(env.base.self, e);
    }
};

/// The bit length of integer name `e`: §3.2's 32 bits for an `integer`
/// variable or typed parameter, an untyped local parameter's default's
/// (IEEE 1364-2005 §12.2, "the type and range of the final value assigned"),
/// and null for one the host may override, or anything not an integer.
/// `$clog2` additionally reads an inferred parameter's final elaborated HDL
/// default: numeric host bindings carry a value, never new width metadata.
fn nameWidth(self: *const Lower, e: Ast.ExprId, depth: u32) ?u32 {
    return nameWidthFor(self, e, depth, false);
}

fn nameWidthFor(self: *const Lower, e: Ast.ExprId, depth: u32, comptime self_determined: bool) ?u32 {
    if (depth > 32) return null;
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    // §7.3.1 maps a discrete reg read to a zero-extended 32-bit integer.
    // Its declared packed width affects the value, not the analog expression.
    if (self.vars.get(name)) |v| return if (v.ty == .integer) 32 else null;
    if (self.arrays.get(name)) |a| return if (a.ty == .integer) 32 else null;
    const deeper = WidthEnv(self_determined){ .self = self, .depth = depth + 1 };
    for (self.func_params) |p| {
        if (!self.file.strings.eql(p.name, name)) continue;
        if (self_determined) if (p.packed_range) |range| return packedWidth(self, range);
        return if (p.ty == .integer) 32 else if (p.ty == .unspecified) (if (self_determined) constfold.clog2Width(self.file, p.default, deeper) else constfold.operandWidth(self.file, p.default, deeper)) else null;
    }
    const pi = self.param_index.get(name) orelse return null;
    const p = self.out.params.items[pi];
    if (p.ty != .integer) return null;
    if (p.integer32) return 32;
    if (self_determined) return p.source_width;
    if (!p.is_local) return null;
    const module = self.out.module orelse return null;
    for (module.params) |decl| {
        if (std.mem.eql(u8, self.file.str(decl.name), p.name)) return constfold.operandWidth(self.file, decl.default, deeper);
    }
    return null;
}

/// A packed declaration's inclusive bit count, before arithmetic erases it.
/// Resolve in declaration scope so a later local cannot shadow either bound.
pub fn packedWidth(self: *const Lower, range: Ast.Dim) ?u32 {
    const left = (constEval(self, range.msb) orelse return null).asIntExact() orelse return null;
    const right = (constEval(self, range.lsb) orelse return null).asIntExact() orelse return null;
    return std.math.cast(u32, @abs(@as(i128, left) - right) + 1);
}

/// `nameWidth` one level down, as `constfold.operandWidth`'s `env`.
fn WidthEnv(comptime self_determined: bool) type {
    return struct {
        self: *const Lower,
        depth: u32,
        pub fn width(env: @This(), e: Ast.ExprId) ?u32 {
            return nameWidthFor(env.self, e, env.depth, self_determined);
        }
        pub fn signed(env: @This(), e: Ast.ExprId) ?bool {
            return nameSignedForClog2(env.self, e, env.depth);
        }
    };
}

/// `$clog2`'s IEEE self-determined source width, before integer MIR erases it.
pub fn clog2Width(self: *const Lower, e: Ast.ExprId) ?u32 {
    return constfold.clog2Width(self.file, e, WidthEnv(true){ .self = self, .depth = 0 });
}

/// `$clog2`'s IEEE self-determined source signedness, the companion of
/// `clog2Width`; null when nothing in scope states it.
pub fn clog2Signed(self: *const Lower, e: Ast.ExprId) ?bool {
    return constfold.clog2Signed(self.file, e, WidthEnv(true){ .self = self, .depth = 0 });
}

fn nameSignedForClog2(self: *const Lower, e: Ast.ExprId, depth: u32) ?bool {
    if (depth > 32) return null;
    const name = self.file.str(self.file.exprs.strOf(e));
    if (self.vars.get(name)) |v| return if (v.ty == .integer) true else null;
    if (self.arrays.get(name)) |a| return if (a.ty == .integer) true else null;
    for (self.func_params) |p| {
        if (!self.file.strings.eql(p.name, name)) continue;
        if (p.ty == .integer) return true;
        if (p.packed_range != null or p.is_signed) return p.is_signed;
        return constfold.clog2Signed(self.file, p.default, WidthEnv(true){ .self = self, .depth = depth + 1 });
    }
    const pi = self.param_index.get(name) orelse return null;
    const p = self.out.params.items[pi];
    return if (p.ty != .integer) null else if (p.integer32) true else p.source_signed;
}

/// The width-and-sign plan `lower/expr.zig` lowers a `$clog2` operand by, under
/// `parent`'s context. Folds no parameter (`params = false`): a model card may
/// override one. Null when the operand's integer sizing is unknown.
pub fn clog2Plan(self: *const Lower, e: Ast.ExprId, parent: ?constfold.IntContext) ?constfold.IntPlan {
    return constfold.intPlan(self.file, e, ClogEnv{ .base = .{ .self = self, .params = false } }, parent);
}

/// Above 64 bits, an i64 sign bit describes the source high bits only when
/// `asExactInt` proved their extension. Parameter aliases preserve that proof
/// at the same width; a wider declaration or arithmetic needs actual planes.
pub fn clog2WideCarrier(self: *const Lower, e: Ast.ExprId, depth: u32) bool {
    if (depth > 32) return false;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .logic_literal => return ex.logicValue(e).asExactInt() != null,
        .ident => {
            const name = self.file.str(ex.strOf(e));
            for (self.func_params) |p| {
                if (self.file.strings.eql(p.name, name)) return wideParamCarrier(self, p, depth + 1);
            }
            const pi = self.param_index.get(name) orelse return false;
            const p = self.out.params.items[pi];
            const module = self.out.module orelse return false;
            for (module.params) |decl| {
                if (std.mem.eql(u8, self.file.str(decl.name), p.name)) return wideParamCarrier(self, decl, depth + 1);
            }
            return false;
        },
        else => return false, // else: no proof that the carrier retains every high bit
    }
}

fn wideParamCarrier(self: *const Lower, p: Ast.ParamDecl, depth: u32) bool {
    if (p.packed_range) |range| {
        const width = packedWidth(self, range) orelse return false;
        if (width != (clog2Width(self, p.default) orelse return false)) return false;
    }
    return clog2WideCarrier(self, p.default, depth);
}

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
