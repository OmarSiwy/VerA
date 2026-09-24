//! §4.2 expressions, §4.3 math functions, §4.4 signal access.
//!
//! In: expression AST. Out: typed MIR values (`TypedValue`).
//!
//! LRM clauses this file's code cites: §3.3, §4.2.3, §4.2.7, §4.3, §4.4, §4.5.15, §4.7, §5.4.3, §5.6.1.2, §6.7, §6.7.1, §6.8.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_expr.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_func = @import("func.zig");
const lower_node = @import("node.zig");
const lower_param = @import("param.zig");
const lower_stmt = @import("stmt.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Elaborate = @import("../elaborate.zig");
const diag = @import("diag");
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const Accum = Lower.Accum;
const err = Lower.err;
const errWith = Lower.errWith;
const poison = Lower.poison;
const emit = Lower.emit;
const call = Lower.call;
const gotoBlock = Lower.gotoBlock;
const branchTo = Lower.branchTo;
const strNum = Lower.strNum;
const toReal = Lower.toReal;
const toBool = Lower.toBool;
const unify = Lower.unify;
const astTy = Lower.astTy;

// ---------------------------------------------------------------------------
// Class 4/5 — expressions (LRM §4.2), math (§4.3), signal access (§4.4)
// ---------------------------------------------------------------------------

/// Expression lowering. LRM §4. Returns the Value AND its LRM type, because
/// every operator's opcode family depends on it (§4.2.1.1–§4.2.1.3).
pub fn lowerExpr(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (e == .none) return poison;
    const ex = &self.file.exprs;
    // PROVENANCE. Every MIR instruction emitted while this node is being
    // lowered is stamped with its token (Mir.addInst reads the cursor), which
    // is how proof.zig turns a `Mir.Inst` back into a source span. Saved and
    // restored because lowering recurses: an operand must not leave the cursor
    // pointing at itself once the parent resumes emitting.
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = ex.mainTok(e);
    switch (ex.tag(e)) {
        .int_literal => return .{ .v = try self.mir.addIntConst(self.arena, ex.intValue(e)), .ty = .integer }, // §2.6.1
        .logic_literal => {
            try self.err(ex.mainTok(e), .E0130, "digital literal requires a four-state execution backend", .{});
            return poison;
        },
        .real_literal => return .{ .v = try self.mir.addFloatConst(self.arena, ex.realValue(e)), .ty = .real }, // §2.6.2
        .str_literal => return .{
            .v = try self.mir.addStrConst(self.arena, self.file.str(ex.strOf(e))),
            .ty = .string,
        }, // §2.7
        // A.2.5 — only legal inside a value range, which proof.zig reads from
        // the AST directly; lowering one is harmless.
        .pos_inf => return .{ .v = .f_inf, .ty = .real },
        .neg_inf => return .{ .v = try self.mir.addFloatConst(self.arena, -std.math.inf(f64)), .ty = .real },

        .ident => return lookupName(self, e, self.file.str(ex.strOf(e))),
        .hier_ident => {
            // §5.5.3 Syntax 5-4 first: a nature attribute reference is a
            // CONSTANT this module can resolve, unlike a §6.8 hierarchical name,
            // which needs an instance tree (E0901).
            if (lower_analog_op.natureAttrRef(self, e)) |r| switch (r) {
                .value => |c| return switch (c) {
                    .real, .int => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
                    .str => .{ .v = try self.mir.addStrConst(self.arena, c.str), .ty = .string },
                },
                .banned => |attr| {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0359);
                    b.msg("`{s}`", .{attr});
                    b.note("§5.5.3: \"This syntax shall not be used for the access, ddt_nature, or idt_nature attributes of a nature, nor any other attribute whose value is not a constant expression\"", .{});
                    try b.emit();
                    return poison;
                },
            };
            // §6.7 "access of parameters can be done hierarchically", and
            // §6.7.1 extends it to variables. The path IS the flat name
            // elaboration gave the child's entity, so once the join resolves
            // there is nothing hierarchical left to do; E0901 is what is left
            // when it does not.
            const name = try flatName(self, e);
            // §6.7.1's fifth bullet, and the ONLY one of the list that is a
            // prohibition: "It shall be an error to access analog variables
            // hierarchically." It has to be tested before the resolution below,
            // because the resolution succeeds — a flattened child's variable is
            // an ordinary variable of the flat design under its path name, so
            // nothing else would stop the read.
            // …EXCEPT a §5.3.2 named-block local, which the LRM spells out the
            // other way: "All identifiers declared within a named sequential
            // block can be accessed outside the scope in which they are
            // declared." §6.7.1 is about reaching into another INSTANCE;
            // `publishBlockLocals` bound only labels of this analog block.
            if (self.vars.contains(name) and !self.block_locals.contains(name)) {
                var vb = self.errWith(self.file.exprs.mainTok(e), .E0910);
                vb.msg("`{s}`", .{name});
                vb.note("§6.7.1 permits a hierarchical parameter, branch probe or analog function; a variable is the one entry on that list it forbids", .{});
                try vb.emit();
                return poison;
            }
            if (self.param_index.contains(name) or self.consts.contains(name) or
                self.node_voltages.contains(name) or self.block_locals.contains(name))
                return lookupName(self, e, name);
            try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names nothing in the elaborated design", .{name});
            return poison;
        },

        .unary => return lowerUnary(self, e),
        .binary => return lowerBinary(self, e),
        .ternary => return lowerTernary(self, e), // §4.2.3 / §4.2.12

        .call => return lower_func.lowerUserCall(self, e), // §4.7
        .builtin_call => return lowerBuiltin(self, e), // §4.3
        .sys_call => return lower_sysfunc.lowerSysCall(self, e), // ch9
        .filter_call => return lower_analog_op.lowerFilter(self, e), // §4.5
        .noise_call => return lower_analog_op.lowerNoise(self, e), // §4.6

        .branch_access => return lowerBranchAccess(self, e), // §4.4.1
        .port_access => return lowerPortAccess(self, e), // §4.4.2/§5.4.3

        .index => return lowerIndex(self, e),

        // §4.2.13 / §3.3 Table 3-3. A `.multi_concat` reaches lowering only
        // when its multiplier is not a literal, which Table 3-3 allows for a
        // string result; every other replication was unrolled in the parser,
        // where the operand widths still exist.
        .concat, .multi_concat => return lowerConcat(self, e),
        .assign_pattern, .pattern_repl => {
            try self.err(self.file.exprs.mainTok(e), .E0509, "", .{});
            return poison;
        },
        .range => {
            try self.err(self.file.exprs.mainTok(e), .E0329, "", .{});
            return poison;
        },
        .event_or,
        .event_posedge,
        .event_negedge,
        .event_initial_step,
        .event_final_step,
        .event_function,
        // A.6.5 `driver_update expression` — an event, so E0701 like the rest.
        // Nothing lowers a connect module, so this is reachable only if someone
        // writes the keyword where a value belongs.
        .event_driver_update,
        => {
            try self.err(self.file.exprs.mainTok(e), .E0701, "", .{});
            return poison;
        },
    }
}

/// §3.2.2 array element read. A constant index selects one scalarized
/// element; a runtime index becomes a `$idx` call carrying every element, which
/// codegen renders as ONE `switch` — a jump table, so the read is O(1) in the
/// array's extent (the array is scalarized, so there is no memory to index).
pub fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    var subs: [lower_param.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_stmt.indexChain(self, e, &subs)) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0330, "only `name[<index>]` is supported", .{});
        return poison;
    };
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return poison;
    };

    var idx: [lower_param.max_stack_dims]i64 = undefined;
    const at = try lower_param.subscriptBuf(self, &idx, chain.subs.len);
    var all_const = true;
    for (chain.subs, at) |s, *o| {
        // `foldExpr(.., false)`, NOT `constEval`: a §3.4 parameter is
        // overridable by the model card, so folding `a[n-1]` through `n`'s
        // DEFAULT bakes one element into the device and answers every other
        // card with it. The same rule `foldExpr`'s own header states for a
        // procedural `if (p > 0)`; a subscript is no different, and it fails
        // louder — `parameter integer pwl_len = 0` folded `a[pwl_len-1]` to
        // `a[-1]` and reported E0310 on legal source.
        if (lower_constfold.foldExpr(self, s, false)) |c| {
            // §4.2.1.1 converts a real subscript by rounding to the nearest
            // integer; an infinity, a NaN, or a magnitude past i64 has none, so
            // the subscript names no element. That is the same verdict E0310
            // already reaches for a constant subscript outside the declared
            // range — which is exactly what this is, once the converter
            // declines to invent an index for it.
            o.* = c.asIntExact() orelse {
                try self.err(self.file.exprs.mainTok(s), .E0310, "subscript {e} of `{s}` has no integer value, so it lies outside every dimension", .{ c.asReal(), name });
                return poison;
            };
        } else all_const = false;
    }
    if (!try lower_stmt.checkSubscriptCount(self, e, name, info, at.len)) return poison;
    if (all_const) {
        if (!try lower_stmt.checkSubscripts(self, e, name, info, at)) return poison;
        return (try arrayElemValue(self, name, at)) orelse poison;
    }

    // `$idx` emits one switch over the scalarized elements. Both reads and
    // writes use the same declared-order flattening and per-dimension bounds.
    const iv = try lower_stmt.runtimeArrayIndex(self, chain.subs, info.dims);
    const ty = info.ty;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, .zero);
    try vals.append(self.arena, iv);
    for (0..lower_param.shapeCells(info.dims)) |k| {
        lower_param.shapeSubscripts(info.dims, k, at);
        const el = (try arrayElemValue(self, name, at)) orelse return poison;
        try vals.append(self.arena, if (ty == .real) try self.toReal(el) else el.v);
    }
    // The callee name IS the result type — `analysis.callTy` and `sysFuncTy`
    // agree by construction, the `$sscanf$int` rule.
    const callee: []const u8 = switch (ty) {
        .real => "$idx",
        .integer => "$idx$int",
        .string => "$idx$str",
    };
    return .{ .v = try self.call(callee, vals.items), .ty = ty };
}

/// `{a, b, ...}` in a value position. The INTEGER form (§4.2.13) needs each
/// operand's bit width, which only the token text carries, so `parser.zig`
/// folds it and lowering never sees one; what is left here is §3.3 Table 3-3
/// `{Str1,...,Strn}`, "concatenation of Str1,…,Strn" — the LRM's own example is
/// `{ "hello", " ", "world" }` == `"hello world"`.
///
/// ponytail: constant operands only. A string Value is a `str_const` (there is
/// no runtime string in the emitted device), so a non-constant operand has
/// nothing to concatenate and is rejected rather than substituted.
///
/// A `.multi_concat` arrives here for one reason: §3.3 Table 3-3's Replication
/// row says the "multiplier must be of integral type and can be nonconstant.
/// If multiplier is nonconstant or Str is of type string, the result is a
/// string containing N concatenated copies", and the parser unrolls only a
/// literal count (see `replCount`). So every replication left standing is a
/// string one, and N is whatever the folder can make of the multiplier.
pub fn lowerConcat(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const repl = ex.tag(e) == .multi_concat;
    const elems = ex.args(if (repl) ex.rhs(e) else e);
    if (elems.len == 0) {
        try self.err(self.file.exprs.mainTok(e), .E0326, "", .{});
        return poison;
    }
    var copies: i64 = 1;
    if (repl) {
        const c = try lowerExpr(self, ex.lhs(e));
        copies = switch (self.mir.valueDef(c.v)) {
            .int_const => |n| n,
            // A multiplier that survives to the residual has no width and no
            // string to repeat: §3.3's `{i{"Hi"}}` is legal because `i` is
            // knowable, not because the device could build a string at runtime.
            .undef, .float_const, .str_const, .param_ref, .block_param, .inst_result => {
                try self.err(self.file.exprs.mainTok(ex.lhs(e)), .E0328, "", .{});
                return poison;
            },
        };
        // §4.2.13: the replication constant is "non-negative, non-x and
        // non-z". Zero is legal and yields the empty string.
        if (copies < 0) {
            try self.err(self.file.exprs.mainTok(ex.lhs(e)), .E0327, "a replication constant shall be non-negative, got {d}", .{copies});
            return poison;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (elems) |el| {
        const tv = try lowerExpr(self, el);
        if (tv.ty != .string) {
            try self.err(self.file.exprs.mainTok(e), .E0327, "only sized constants and strings can be concatenated", .{});
            return poison;
        }
        switch (self.mir.valueDef(tv.v)) {
            .str_const => |s| try out.appendSlice(self.arena, s),
            .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => {
                try self.err(self.file.exprs.mainTok(e), .E0328, "", .{});
                return poison;
            },
        }
    }
    if (repl) {
        const one = try self.arena.dupe(u8, out.items);
        out.clearRetainingCapacity();
        for (0..@intCast(copies)) |_| try out.appendSlice(self.arena, one);
    }
    // The interner borrows: the bytes live in the arena, which outlives the Mir.
    return .{ .v = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)), .ty = .string };
}

/// The Value of one scalarized element — a variable array (§3.2.2) or a
/// parameter array (§3.4.4).
pub fn arrayElemValue(self: *Lower, name: []const u8, idx: []const i64) Oom!?TypedValue {
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    const key = try lower_param.elemKey(self, &key_buf, name, idx);
    if (self.vars.get(key)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    if (self.param_index.get(key)) |pi|
        return .{ .v = self.param_values.items[pi], .ty = astTy(self.out.params.items[pi].ty) };
    return null;
}

/// §6.7 the flat spelling of a `.hier_ident` path: its parts joined by
/// `Elaborate.sep`.
///
/// That join is the whole out-of-module reference mechanism, and it is one line
/// because of what elaboration already did: flattening renames a child's entity
/// to `path.name` (Ruling E, `Elaborate.sep`), so the name §6.7 asks for and the
/// name the flat design carries are the SAME STRING. Nothing here walks an
/// instance tree, because there is no tree left to walk.
///
/// Arena-allocated per call. Cold: one path per source reference.
pub fn flatName(self: *Lower, e: Ast.ExprId) Oom![]const u8 {
    var parts = self.file.exprs.nameParts(e);
    // §6.2.1 the `$root` prefix: "used to unambiguously refer to a top-level
    // instance or to an instance path starting from the root of the instantiation
    // tree", against a plain path, where "the ambiguity is resolved by giving
    // priority to the local scope". Elaboration's flat namespace IS rooted — a
    // name with no path prefix is a name of the top — so `$root.` means "do not
    // apply the local scope", and dropping the prefix is how that is said. The
    // segment after it names a TOP-LEVEL INSTANCE (§6.7's own `$root.mymodule.u1`
    // is "absolute name"), and the one top-level instance a flattened design has
    // is the device itself, so the top module's own name drops with it.
    //
    // Not done in `Elaborate`'s clone: a `$root` path in the TOP module's body is
    // never cloned (the tree-of-one returns by pointer), so the rule would only
    // have applied to children. Here it applies to every unit.
    if (parts.len > 1 and self.file.strings.eql(parts[0], "$root")) {
        parts = parts[1..];
        if (parts.len > 1) {
            if (self.out.module) |m| if (parts[0] == m.name) {
                parts = parts[1..];
            };
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0) try out.append(self.arena, Elaborate.sep);
        try out.appendSlice(self.arena, self.file.str(p));
    }
    const path = try out.toOwnedSlice(self.arena);
    // The one place the join is NOT the answer: a child port bound to a parent
    // net is the same signal as that net, so `u.a` denotes `p` and there is no
    // `u.a` to find. `Design.names` holds those aliases and nothing else.
    return self.out.hier_names.get(path) orelse path;
}

/// §2.8 name resolution: variables (§3.2) shadow parameters (§3.4), which
/// shadow genvars (§3.5). Nets are NOT values — they are only reachable
/// through an access function (§4.4).
/// §6.7 hierarchical reads pass the dotted path joined by `flatName`.
pub fn lookupName(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    if (self.vars.get(name)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    // §4.7.2/§6.8: inside a function body, a function-local `parameter` of the
    // same name shadows the module's, so `param_index` is masked and the local
    // value is found in `consts` (where `inlineUserFuncPre` folded it).
    if (!funcParamShadows(self, name)) if (self.param_index.get(name)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.out.params.items[idx].ty) };
    if (self.consts.get(name)) |c| return switch (c) {
        .int => .{ .v = try self.mir.addIntConst(self.arena, c.asInt()), .ty = .integer },
        .real => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
        .str => |s| .{ .v = try self.mir.addStrConst(self.arena, s), .ty = .string },
    };
    if (self.node_voltages.contains(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}`", .{name});
        b.help("probe it: `V({s})` or `I({s})`", .{ name, name });
        try b.emit();
        return poison;
    }
    var b = self.errWith(self.file.exprs.mainTok(e), .E0314);
    b.msg("`{s}`", .{name});
    const near = diag.didYouMeanMap(name, self.vars) orelse
        diag.didYouMeanMap(name, self.param_index) orelse
        diag.didYouMeanMap(name, self.node_voltages) orelse
        diag.didYouMeanMap(name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
}

/// §4.7.2/§6.8: does the function currently being inlined declare `name` as a
/// local parameter? True makes the local (in `consts`) win over a module
/// parameter of the same name — the shadowing §6.8's scope list requires.
pub fn funcParamShadows(self: *const Lower, name: []const u8) bool {
    for (self.func_params) |*p| {
        if (self.file.strings.eql(p.name, name)) return true;
    }
    return false;
}

/// A.8.6 unary operators. §4.2.3 (+/-), §4.2.7 (!), §4.2.9 (~).
pub fn lowerUnary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const a = try lowerExpr(self, ex.lhs(e));
    switch (ex.unOp(e)) {
        .plus => return a,
        .minus => {
            // §4.2.3. Fold a LITERAL here instead of emitting `ineg(3)`. The
            // §4.2.8 divisor proof reads an operand's interval, and proof.zig's
            // `integerIv` gives every integer instruction the full i64 clamp —
            // it has no transfer function for `ineg` — so `11 % -3` could not
            // prove its divisor non-zero and died on E0601. A negative literal
            // is a constant however the grammar spells it, so the fix belongs
            // where the constant is built, not in a second range rule.
            switch (self.mir.valueDef(self.mir.resolveAlias(a.v))) {
                .int_const => |x| if (x != std.math.minInt(i64))
                    return .{ .v = try self.mir.addIntConst(self.arena, -x), .ty = a.ty },
                .float_const => |x| return .{ .v = try self.mir.addFloatConst(self.arena, -x), .ty = a.ty },
                .undef, .str_const, .param_ref, .block_param, .inst_result => {},
            }
            return .{
                .v = try self.emit(if (a.ty == .real) .fneg else .ineg, &.{a.v}),
                .ty = a.ty,
            };
        },
        .logical_not => return .{ .v = try self.emit(.lognot, &.{try self.toBool(a)}), .ty = .integer },
        .bit_not => {
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0318, "`~` on a {s}", .{@tagName(a.ty)});
                return poison;
            }
            return .{ .v = try self.emit(.bitnot, &.{a.v}), .ty = .integer };
        },
        // §4.2.10, the whole clause: "The reduction operators can not be used
        // inside the analog block and only have meaning when used in the
        // digital context." There is no carve-out and no analog form.
        //
        // Unconditional, for the reason `isDigitalOnlySysFunc` gives at length:
        // `parseAnalog` is the only producer of statements VerA lowers, so
        // every expression that reaches here IS in the analog block and a
        // context flag would read `true` at every call site.
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor => {
            // §4.2.1 first: a real operand has no bits to fold at all, and
            // E0319 names the operand rather than the context.
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0319, "got a {s}", .{@tagName(a.ty)});
                return poison;
            }
            try self.err(self.file.exprs.mainTok(e), .E0348, "", .{});
            return poison;
        },
        // §4.2.10 xor reduction is a parity, which has no analog equivalent
        // and no MIR opcode (annex C).
        .reduce_xor, .reduce_xnor => {
            try self.err(self.file.exprs.mainTok(e), .E0320, "", .{});
            return poison;
        },
    }
}

/// A.8.6 binary operators. LRM Table 4-3 precedence is the parser's job; this
/// only picks the opcode family from the operand types (§4.2.1).
pub fn lowerBinary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const op = ex.binOp(e);
    if (lower_constfold.mixedShiftComparison(self, e)) {
        try self.err(ex.mainTok(e), .E0364, "comparison mixes signed and unsigned operands around a logical shift", .{});
        return poison;
    }

    // §4.2.7 && and || SHORT-CIRCUIT: the rhs must not be evaluated when the
    // lhs already decides the result, so this needs real control flow.
    if (op == .logical_and or op == .logical_or) return lowerShortCircuit(self, e, op);

    // §3.3 Table 3-3: "If both operands are string literals, the operator is
    // the same Verilog equality operator as for integer types." Each literal
    // is its packed bytes (§2.6.3), NULs included, and the shorter is
    // zero-extended — which is byte equality once leading NULs are dropped.
    // The literal's LEXICAL bytes, because string storage removes NULs.
    const eq_op = op == .eq or op == .neq or op == .case_eq or op == .case_neq;
    if (eq_op and ex.tag(ex.lhs(e)) == .str_literal and ex.tag(ex.rhs(e)) == .str_literal) {
        const sa = (try lower_sysfunc.outputLiteral(self, ex.lhs(e))) orelse self.file.str(ex.strOf(ex.lhs(e)));
        const sb = (try lower_sysfunc.outputLiteral(self, ex.rhs(e))) orelse self.file.str(ex.strOf(ex.rhs(e)));
        const same = std.mem.eql(u8, std.mem.trimStart(u8, sa, "\x00"), std.mem.trimStart(u8, sb, "\x00"));
        const want_same = op == .eq or op == .case_eq;
        return .{ .v = if (same == want_same) .one else .zero, .ty = .integer };
    }
    var a = try lowerExpr(self, ex.lhs(e));
    var b = try lowerExpr(self, ex.rhs(e));
    // §2.7 makes a string operand an unsigned integer, so a MIXED pair is
    // arithmetic and not a string operation. Two strings stay strings: Table
    // 3-3's relational row is a string comparison and `{a, " ", b}` is a
    // concatenation, and both would be destroyed by converting either side.
    if ((a.ty == .string) != (b.ty == .string)) {
        a = try self.strNum(a);
        b = try self.strNum(b);
    }

    switch (op) {
        .add, .sub, .mul, .div, .mod => {
            const ty = unify(a.ty, b.ty);
            if (ty == .string) {
                try self.err(self.file.exprs.mainTok(e), .E0321, "", .{});
                return poison;
            }
            const real = ty == .real;
            const opc: Mir.Opcode = switch (op) {
                .add => if (real) .fadd else .iadd,
                .sub => if (real) .fsub else .isub,
                .mul => if (real) .fmul else .imul,
                .div => if (real) .fdiv else .idiv,
                .mod => if (real) .fmod else .imod,
                else => unreachable, // else: the enclosing prong admits only these five
            };
            const lv = if (real) try self.toReal(a) else a.v;
            const rv = if (real) try self.toReal(b) else b.v;
            return .{ .v = try self.emit(opc, &.{ lv, rv }), .ty = ty };
        },
        // §4.2.1.3: "If either operand is real, the other operand is converted
        // to real" — so two integers stay integer, and `7/(2**k)` divides by
        // an integer. §4.3.1's `pow()` FUNCTION is the real-valued one.
        .pow => return if (a.ty == .integer and b.ty == .integer)
            .{ .v = try self.emit(.ipow, &.{ a.v, b.v }), .ty = .integer }
        else
            .{ .v = try self.emit(.pow, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real },
        .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
            // §7.3.2 lists `===` and `!==` among the features the analog
            // context supports, and §4.2.6 defers their meaning to IEEE 1364
            // §5.1.8: x and z compare as bits. Every operand that reaches here
            // is two-state (an x/z literal is E0130, a four-state net read is
            // E0315), and on two-state bits the case operators ARE `==` and
            // `!=`. §4.2.1 still bars them from a real operand: Table 4-2, the
            // operators legal on reals, has no `===` or `!==`.
            const case = op == .case_eq or op == .case_neq;
            if (case and (a.ty == .real or b.ty == .real)) {
                var d = self.errWith(self.file.exprs.mainTok(e), .E0369);
                d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
                try d.emit();
                return poison;
            }
            const op_cmp: Ast.BinaryOp = if (!case) op else if (op == .case_eq) .eq else .neq;
            // §4.2.9's unsigned context, applied to the pair rather than to
            // either operand. See `unsignedCompareMask`.
            if (a.ty == .integer and b.ty == .integer) if (lower_constfold.unsignedCompareMask(self, e)) |m| {
                const k = try self.mir.addIntConst(self.arena, m);
                const az: TypedValue = .{ .v = try self.emit(.bitand, &.{ a.v, k }), .ty = .integer };
                const bz: TypedValue = .{ .v = try self.emit(.bitand, &.{ b.v, k }), .ty = .integer };
                return .{ .v = try cmp(self, op_cmp, az, bz), .ty = .integer };
            };
            return .{ .v = try cmp(self, op_cmp, a, b), .ty = .integer };
        },
        .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr => {
            if (a.ty != .integer or b.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0322, "got {s} and {s}", .{ @tagName(a.ty), @tagName(b.ty) });
                return poison;
            }
            const opc: Mir.Opcode = switch (op) {
                .bit_and => .bitand,
                .bit_or => .bitor,
                .bit_xor => .bitxor,
                .bit_xnor => .bitxnor,
                .shl => .shl,
                .shr => .shr,
                else => unreachable, // else: the enclosing prong admits only these six
            };
            return .{ .v = try self.emit(opc, &.{ a.v, b.v }), .ty = .integer };
        },
        // §4.2.11 arithmetic shifts have no MIR opcode: a Verilog-A `integer`
        // is signed, so `<<<`/`>>>` would need a separate signed-shift op.
        .ashl, .ashr => {
            var d = self.errWith(self.file.exprs.mainTok(e), .E0324);
            d.help("use `<<` and `>>`", .{});
            try d.emit();
            return poison;
        },
        // `lowerShortCircuit` returned for both at the top.
        .logical_and, .logical_or => unreachable,
    }
}

/// §4.2.4 relational / §4.2.5 equality — integer 0/1 result either way.
pub fn cmp(self: *Lower, op: Ast.BinaryOp, a: TypedValue, b: TypedValue) Oom!Mir.Value {
    const real = unify(a.ty, b.ty) == .real;
    const opc: Mir.Opcode = switch (op) {
        .eq => if (real) .feq else .ieq,
        .neq => if (real) .fne else .ine,
        .lt => if (real) .flt else .ilt,
        .le => if (real) .fle else .ile,
        .gt => if (real) .fgt else .igt,
        .ge => if (real) .fge else .ige,
        else => unreachable, // else: both callers pass a relational or `==`/`!=` operator
    };
    const lv = if (real) try self.toReal(a) else a.v;
    const rv = if (real) try self.toReal(b) else b.v;
    return self.emit(opc, &.{ lv, rv });
}

/// §4.2.3 names THREE short-circuiting operators, "&&, ||, and ?:", and says of
/// all three that "any side effects or runtime errors that would have occurred
/// due to evaluation of the short-circuited operand expression shall not occur";
/// §4.2.12 says the same from the value side, naming only the arm it selects.
/// So the arms are BRANCHES and not operands of a `select`: an inlined function
/// that writes an `inout` formal (§4.7.2.4) must not run in the arm that was not
/// chosen, and neither must a division the condition exists to guard.
///
/// The shape is `lowerShortCircuit`'s — one place, one phi at the join. The one
/// difference is the type: `&&` is integer by definition, while §4.2.1 makes a
/// ternary's type the unification of BOTH arms, and neither arm's type is known
/// until it has been lowered. So the then-arm is left UNTERMINATED while the
/// else-arm is lowered, and both are finished afterwards, once `ty` is settled
/// and the `.itof` each arm may need can still be emitted before its jump.
/// Nothing between the two reads the then-arm's terminator: the SSA builder
/// walks predecessors, and the else-arm has none of the then-arm's blocks.
pub fn lowerTernary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const cond = ex.lhs(e);
    const c = try self.toBool(try lowerExpr(self, cond));

    // §4.5.15 "Analog operators shall not be used inside conditional (if, case,
    // or ?:) statements unless the conditional expression controlling the
    // statement consists of terms which can not change their value during the
    // course of a simulation." `?:` is in that list, and short-circuiting is
    // precisely WHY: an operator in an arm loses its history on every step the
    // arm is off. The two counters `lowerCondBody` raises for an `if` body are
    // raised here for the same rule, and that is what lets E0514 in
    // `lowerFilter` see it.
    const static = lower_control.isAnalysisOrConst(self, cond) or try lower_control.isStaticValue(self, c);
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(c, then_b, else_b, true);

    self.cur = then_b;
    const t = try lowerExpr(self, ex.rhs(e));
    const then_end = self.cur; // an arm may have branched on its own (`&&`, a nested `?:`)

    self.cur = else_b;
    const f = try lowerExpr(self, ex.ternaryElse(e));
    const else_end = self.cur;

    const ty = unify(t.ty, f.ty);
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, else_end, if (ty == .real) try self.toReal(f) else f.v);
    try self.gotoBlock(join);

    self.cur = then_end;
    try self.builder.writeVariable(place, then_end, if (ty == .real) try self.toReal(t) else t.v);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = ty };
}

/// §4.5.15 "It is important to ensure that ALL analog operators are evaluated
/// EVERY ITERATION of a simulation to ensure that the internal state is
/// maintained." Does this subtree hold one of the operators that rule protects?
/// `ddx` and `limexp` are the clause's own exceptions (see `isHistoryless`).
///
/// ponytail: syntactic, and it does not look inside a §4.7 analog function
/// body. An operator there is already E0422 territory, and the upgrade path if
/// one ever is legal is a per-function flag computed when the function lowers.
pub fn hasStatefulOp(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (tag == .filter_call and !lower_analog_op.isHistoryless(self.file.str(ex.strOf(e)))) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (hasStatefulOp(self, c)) return true;
    return false;
}

/// §4.2.7 `&&` / `||` with LRM short-circuit evaluation. The rhs gets its own
/// block, so a guard like `(x != 0) && (1/x > k)` never divides by zero.
pub fn lowerShortCircuit(self: *Lower, e: Ast.ExprId, op: Ast.BinaryOp) Oom!TypedValue {
    const ex = &self.file.exprs;
    // §4.5.15's evaluate-every-iteration rule wins over §4.2.7's skip when the
    // rhs holds an analog operator: the skipped step feeds that operator site
    // the branch-local zero instead of its real input, so its history is
    // stranded and it diverges from an identical site outside the `||` — "the
    // internal state ... corrupted or become out-of-date" the clause's closing
    // sentence names. §4.2.3's "any side effects ... shall not occur" is about
    // side effects and runtime errors; advancing an operator VerA is required
    // to advance every iteration is neither.
    //
    // §4.5.15's restriction paragraph names `if`, `case` and `?:` and nothing
    // else, so it does not make this spelling illegal and nothing here
    // diagnoses it — it makes the two sites agree, which is what it asks for.
    if (hasStatefulOp(self, ex.rhs(e))) {
        const l = try self.toBool(try lowerExpr(self, ex.lhs(e)));
        const r = try self.toBool(try lowerExpr(self, ex.rhs(e)));
        // `toBool` normalises both to 0/1, so max IS `||` and min IS `&&` —
        // no opcode and no block.
        return .{
            .v = try self.emit(if (op == .logical_and) .imin else .imax, &.{ l, r }),
            .ty = .integer,
        };
    }
    const a = try self.toBool(try lowerExpr(self, ex.lhs(e)));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, a);

    const rhs_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    // `a && b` evaluates b only when a is true; `a || b` only when a is false.
    if (op == .logical_and) {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, rhs_b, join);
    } else {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, join, rhs_b);
    }
    try self.builder.addPredecessor(rhs_b, self.cur);
    try self.builder.addPredecessor(join, self.cur);
    try self.builder.sealBlock(rhs_b);

    self.cur = rhs_b;
    const b = try self.toBool(try lowerExpr(self, ex.rhs(e)));
    try self.builder.writeVariable(place, self.cur, b);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = .integer };
}

/// §4.4.1 access function: `V(a)`, `V(a,b)`, `I(br)`.
/// A potential is the difference of two node unknowns; a flow that is *read*
/// makes the branch current an unknown of its own (§5.4.2).
pub fn lowerBranchAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    // §3.12.1: a port branch names the §5.4.3 port flow, so `I(pb)` and
    // `I(<p>)` are one quantity and read the one unknown. Ahead of `branchOf`
    // because the name is not in `branches` and would otherwise fall through to
    // `nodeOf` and become an implicit net.
    if (try lower_contrib.portBranchOf(self, e)) |p| return portFlowRead(self, e, p);
    const t = try lower_contrib.branchOf(self, e) orelse return poison;
    try self.branch_reads.append(self.arena, .{
        .access = t.access,
        .hi = t.hi,
        .lo = t.lo,
        .tok = self.file.exprs.mainTok(e),
    });
    // §1.3.1.2: the reversed spelling of a branch is the same quantity with the
    // opposite sign. For the potential that is just which way the subtraction
    // runs; for the flow it is the whole point — `t` has already been
    // canonicalised, so `I(n,p)` reads the ONE `flow(p,n)` unknown negated
    // instead of minting a second, independent one that nothing constrains.
    switch (t.access) {
        .potential => {
            const hi = try lower_node.probe(self, t.hi);
            if (t.lo == ground)
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{hi}) else hi, .ty = .real };
            const lo = try lower_node.probe(self, t.lo);
            const d = if (t.neg) [2]Mir.Value{ lo, hi } else [2]Mir.Value{ hi, lo };
            return .{ .v = try self.emit(.fsub, &d), .ty = .real };
        },
        .flow => {
            // §5.4.2.2 "Both the potential and the flow of a source branch are
            // accessible in expressions anywhere in the module." For a FLOW
            // source that access cannot be a solver unknown: a current source's
            // branch flow has no node-derived value and no row pins it, so a
            // read of the unknown answers its initial 0 whatever was
            // contributed. What the branch flow of a flow source IS, by
            // definition, is the value retained on the branch (§5.6.1.2) — so
            // the read is the ACCUMULATOR, read at `self.cur`. WHERE `self.cur`
            // is is the caller's statement of position semantics, and there are
            // exactly two: an ORDINARY expression (an assignment's, a
            // contribution's right side) reads mid-block and sees §5.6.1.2's
            // sequential retention — a read above the first `<+` sees nothing
            // retained — while a §9.4 display operand is lowered from
            // `lowerDeferredDisplays` with `self.cur` past the whole block, so
            // it sees the §9.4.1 CONVERGED end-of-cycle value, §5.6.1.3
            // retention-select phis included (§5.8's conditional arms come out
            // as `readVariable`'s phis with nothing written here).
            //
            // §5.6.6 FIRST: inside a `<+`'s own right-hand side, a read of the
            // SAME branch is the implicit form — "the value of the target may
            // be expressed in terms of itself" — and its value is the one "the
            // underlying implementation ... will find", i.e. the branch-flow
            // unknown, never the retained prefix. Ahead of `flowAccum` because
            // the statement's own entry already exists by the time its rhs
            // lowers (`contribIndex` runs first), and the accumulator it would
            // find is exactly the stale self-reference §5.6.6 rules out.
            // The unknown this mints is defined by codegen's `FreeFlow` row,
            // `x[u] − Σ contributions = 0` — the same shape `portFlowRead`
            // documents for `I(<p>)`. Without it the self-reference answered
            // its seed of 0 and the model was silently linearised.
            if (self.contrib_target) |ct| {
                if (ct.access == .flow and t.access == .flow and
                    ct.hi == t.hi and ct.lo == t.lo and ct.br == t.br)
                {
                    const u = try lower_node.flowUnknown(self, t.hi, t.lo);
                    const v = try lower_node.probe(self, u);
                    return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
                }
            }
            // Only once a flow contribution has ALREADY been lowered onto this
            // pair, which is the distinction the clause draws: an uncontributed
            // branch is a §5.4.2.1 flow PROBE — a short whose current is a
            // genuine unknown of the solve — and a POTENTIAL source's branch
            // current is pinned by the branch row codegen emits for it. Both of
            // those keep the unknown and read it — the second of them including
            // §5.6.8.1's hierarchical case, where the source this instance just
            // created runs in PARALLEL with another instance's accumulator
            // (`potentialSourceHere`).
            if (!potentialSourceHere(self, t)) if (flowAccum(self, t)) |acc| {
                // §5.6.1.2: the retained value of a source branch is the WHOLE
                // of what was contributed to it, and §5.4.2.2 makes that whole
                // readable. No clause lets a reactive term count for the node
                // equation and not for a probe.
                //
                // The reactive half is retained as a CHARGE — the clause strips
                // one `ddt` off the contributed term — so reading the FLOW back
                // has to differentiate it again. That is a second `ddt`
                // instance with its own operator state, which is what this
                // `call` mints, and it is the honest cost: the current of a
                // capacitor IS a derivative. A model computing its own
                // dissipation, a charge-conservation check, or §5.4.3's
                // transit-time term read zero until this existed.
                //
                // Only when there IS a reactive half. `.f_zero` is what the
                // entry-block seed leaves when nothing wrote the place, so an
                // ordinary resistive branch emits no operator and cannot newly
                // trip §5.8.1's conditional-operator rule.
                const r = try self.builder.readVariable(acc.resist, self.cur);
                const q = try self.builder.readVariable(acc.react, self.cur);
                const v = if (q == .f_zero) r else blk: {
                    const dq = try self.call("ddt", &.{q});
                    break :blk if (r == .f_zero) dq else try self.emit(.fadd, &.{ r, dq });
                };
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
            };
            const u = try lower_node.flowUnknown(self, t.hi, t.lo);
            const v = try lower_node.probe(self, u);
            return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
        },
    }
}

/// The §5.6.1.2 retained-flow accumulator of the branch (hi, lo), if a `<+` has
/// already made it a flow source. Keyed exactly like `contribIndex` — on the
/// canonicalised pair, so `I(n,p)` finds the one entry `I(p,n)` created.
///
/// NOT keyed on the unit, unlike `discardOpposite`: §5.5.5 lets "a module
/// access the potential and flow of a branch in another module instance ...
/// providing that value is available in the other instance", and a hierarchical
/// `I(x1.p, x1.n)` is exactly that read. §5.5.4's new-branch rule is about the
/// access functions whose examples are all POTENTIAL probes, which draw no flow
/// — see `potentialSourceHere` for the case where this unit's OWN source is the
/// branch being read.
pub fn flowAccum(self: *const Lower, t: lower_contrib.Target) ?Accum {
    for (self.out.contributions.items, self.accum.items) |c, acc| {
        if (c.kind == .direct and c.access == .flow and c.hi == t.hi and c.lo == t.lo and c.br == t.br)
            return acc;
    }
    return null;
}

/// §5.6.8.1: "Direct contribution statements can contribute to a branch between
/// combinations of local and hierarchical nets. In these cases, a new unnamed
/// branch is created in the module containing the direct contribution
/// statements." So a potential `<+` written HERE is a source branch of THIS
/// instance, in parallel with whatever another instance retained over the same
/// node pair — §5.4.1's "only one unnamed branch between any two nets" is a
/// PER-INSTANCE rule, and flattening has already collapsed the pairs.
///
/// The flow of that source is the branch-current unknown codegen pins with its
/// branch row, never the parallel branch's accumulator. Without this a parent's
/// `I(drv.x, drv.y)` read back the CHILD's conduction current.
///
/// `unit` is the id of the contribution that OPENED the entry (see its doc), so
/// a second instance potential-sourcing a pair another already sources reads the
/// accumulator instead — two ideal potential sources in parallel is a degenerate
/// topology the clause does not describe either way.
pub fn potentialSourceHere(self: *const Lower, t: lower_contrib.Target) bool {
    for (self.out.contributions.items) |c| {
        if (c.kind == .direct and c.access == .potential and c.hi == t.hi and c.lo == t.lo and
            c.br == t.br and c.unit == self.cur_unit) return true;
    }
    return false;
}

/// LRM §5.4.3 port access — `I(<p>)`.
///
/// "The port access function accesses the flow into a port of a module. ...
/// However (<>) is used to delimit the port name, e.g., I(<a>) accesses the
/// current through module port a."
///
/// By KCL that current is precisely the sum of everything this module stamps at
/// `p`, i.e. the residual codegen is in the middle of assembling — so it cannot
/// be an expression over the other units without a cycle. It becomes its own
/// solver unknown, exactly like the §5.4.2 branch-flow unknown, and codegen
/// pins it with the row `x[u] − Σ stamps at p`.
pub fn lowerPortAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    return portFlowRead(self, e, try lower_node.nodeOf(self, self.file.exprs.lhs(e)));
}

/// The read half of §5.4.3, shared by `I(<p>)` and by a §3.12.1 port branch
/// named over the same port: the two spellings are one quantity, so they must
/// be one unknown and one set of rules. `p` is the port's `nodes` row —
/// resolved by the caller, because the two spellings name it differently (an
/// argument expression here, a branch declaration there).
pub fn portFlowRead(self: *Lower, e: Ast.ExprId, p: u16) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return poison;
    };
    // §5.4.3 "The expression V(<a>) is invalid for ports and nets, where V is a
    // potential access function." A port access reads a FLOW, always.
    if (access == .potential) {
        try self.err(self.file.exprs.mainTok(e), .E0507, "`{s}` is a potential access function", .{name});
        return poison;
    }
    // §4.4.2 "For port access functions, the expression list is a single port
    // of the module"; §5.4.1 "it must be a declared port of the module in which
    // the port access function is used." An internal net has no outside, so its
    // port flow would be an identically-zero substitute — reject instead.
    if (p == ground or p >= self.out.num_ports) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0508);
        b.msg("`{s}(<{s}>)`", .{ name, lower_node.nodeName(self, p) });
        if (diag.didYouMeanMap(lower_node.nodeName(self, p), self.node_voltages)) |s|
            b.help("did you mean `{s}`?", .{s});
        try b.emit();
        return poison;
    }
    // §4.4 the name still has to be the port discipline's flow access.
    try lower_contrib.checkAccessMatch(self, e, name, access, p);
    return .{ .v = try lower_node.probe(self, try lower_node.portFlowUnknown(self, p)), .ty = .real };
}

// ---- §4.3 math functions (Tables 4-14 and 4-15) ----------------------------

/// LRM Table 4-14 §4.3.1 / Table 4-15 §4.3.2 — the real-valued one-argument
/// functions, by their LRM spelling. `log` is base 10 (`log10` in MIR).
pub fn unaryMathOp(name: []const u8) ?Mir.Opcode {
    return unary_math.get(name);
}

/// LRM Table 4-14 — the real-valued two-argument functions.
pub fn binaryMathOp(name: []const u8) ?Mir.Opcode {
    return binary_math.get(name);
}

// File-scope so `unknownCall` can offer `.keys()` as did-you-mean candidates:
// a misspelled built-in is the commonest way to reach E0512, and the LRM's own
// spelling is the answer.
pub const unary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "exp", .exp },     .{ "expm1", .expm1 },
    .{ "ln", .ln },       .{ "ln1p", .ln1p },   .{ "log", .log10 },
    .{ "floor", .floor }, .{ "ceil", .ceil },   .{ "sin", .sin },
    .{ "cos", .cos },     .{ "tan", .tan },     .{ "asin", .asin },
    .{ "acos", .acos },   .{ "atan", .atan },   .{ "sinh", .sinh },
    .{ "cosh", .cosh },   .{ "tanh", .tanh },   .{ "asinh", .asinh },
    .{ "acosh", .acosh }, .{ "atanh", .atanh },
});

pub const binary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "pow", .pow }, .{ "hypot", .hypot }, .{ "atan2", .atan2 },
});

/// §4.3 built-in math. `abs`/`min`/`max` keep integer operands integer
/// (§4.3.1: "if both operands are integer the result is integer").
pub fn lowerBuiltin(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const spelling = self.file.str(ex.strOf(e));
    const name = if (std.mem.startsWith(u8, spelling, "$")) spelling[1..] else spelling;
    const args = ex.args(e);

    if (unaryMathOp(name)) |op| {
        if (args.len != 1) return arityError(self, e, name, 1);
        const a = try lowerExpr(self, args[0]);
        return .{ .v = try self.emit(op, &.{try self.toReal(a)}), .ty = .real };
    }
    if (binaryMathOp(name)) |op| {
        if (args.len != 2) return arityError(self, e, name, 2);
        const a = try lowerExpr(self, args[0]);
        const b = try lowerExpr(self, args[1]);
        return .{ .v = try self.emit(op, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real };
    }
    if (std.mem.eql(u8, name, "abs")) {
        if (args.len != 1) return arityError(self, e, name, 1);
        const a = try lowerExpr(self, args[0]);
        const int = a.ty == .integer;
        return .{ .v = try self.emit(if (int) .iabs else .fabs, &.{a.v}), .ty = a.ty };
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len != 2) return arityError(self, e, name, 2);
        const a = try lowerExpr(self, args[0]);
        const b = try lowerExpr(self, args[1]);
        const ty = unify(a.ty, b.ty);
        const is_min = name[1] == 'i';
        const op: Mir.Opcode = if (ty == .real)
            (if (is_min) .fmin else .fmax)
        else
            (if (is_min) .imin else .imax);
        const lv = if (ty == .real) try self.toReal(a) else a.v;
        const rv = if (ty == .real) try self.toReal(b) else b.v;
        return .{ .v = try self.emit(op, &.{ lv, rv }), .ty = ty };
    }
    try unknownCall(self, e, name);
    return poison;
}

/// E0512 with a suggestion drawn from everything that COULD have been called
/// here: the module's §4.7 analog functions and the §4.3 built-ins of Tables
/// 4-14/4-15. `m.functions` is a slice, not a map, so the candidates are
/// collected before `didYouMean` sees them — and the built-in names ride in the
/// same list so one call picks the single nearest of the whole set.
pub fn unknownCall(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    var b = self.errWith(self.file.exprs.mainTok(e), .E0512);
    b.msg("`{s}`", .{name});

    var names: std.ArrayList([]const u8) = .empty;
    if (self.out.module) |m| {
        for (m.functions) |*fd| try names.append(self.arena, self.file.str(fd.name));
    }
    try names.appendSlice(self.arena, unary_math.keys());
    try names.appendSlice(self.arena, binary_math.keys());
    // §3.13.2 access functions land here too: the parser routes `Vv(p,n)` to a
    // function call precisely BECAUSE `Vv` is not an access name, so `V` is the
    // answer far more often than any analog function is.
    var it = self.access_kind.keyIterator();
    while (it.next()) |k| try names.append(self.arena, k.*);
    if (diag.didYouMean(name, names.items)) |s| b.suggestHere(s);

    return b.emit();
}

pub fn arityError(self: *Lower, e: Ast.ExprId, name: []const u8, want: usize) Oom!TypedValue {
    try self.err(self.file.exprs.mainTok(e), .E0506, "`{s}()` takes {d}", .{ name, want });
    return poison;
}
