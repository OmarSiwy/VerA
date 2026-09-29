//! §5 analog statements: blocks, assignments, named blocks.
//!
//! In: statement AST. Out: MIR instructions in the current block.
//!
//! LRM clauses this file's code cites: §3.2, §3.2.2, §4.2.1.1, §4.2.13, §5, §5.3, §5.3.2, §5.7, §5.9, §5.10.4, §6.6, §6.7.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_event = @import("event.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Ssa = @import("../ssa.zig");
const Elaborate = @import("../elaborate.zig");
const diag = @import("diag");
const Oom = Lower.Oom;
const NoiseSrc = Lower.NoiseSrc;
const TypedValue = Lower.TypedValue;
const ArrayInfo = Lower.ArrayInfo;

/// This file's private state on `Lower` (`Lower.stmt_state`).
pub const State = struct {
    /// A.6.5 `disable` targets: the enclosing named blocks, innermost last.
    named_blocks: std.ArrayList(NamedBlockCtx) = .empty,
};

/// A.6.5 `disable hierarchical_block_identifier` target: §5.3's "the control
/// shall pass out of the block", i.e. that block's own exit. One entry per
/// enclosing named block.
const NamedBlockCtx = struct { name: []const u8, exit: Mir.Block };

/// Lowers one statement into the current block (LRM §5).
pub fn lowerStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    const tok = self.file.stmtTok(id);
    // Same provenance cursor as `lowerExpr`, for the instructions a statement
    // emits outside any expression (phis, jumps, accumulator writes).
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = tok;
    // VerA's `vera_lte` statement attribute (A.6.4 prefix): every charge site
    // inside this statement, nested ones included, unless a nearer one says
    // otherwise (`lower_contrib.siteLte`).
    const lte = self.file.stmtLte(id, .vera_lte);
    if (lte) |a| try self.lte_stack.append(self.arena, try lower_contrib.lteValue(self, a));
    defer if (lte != null) {
        _ = self.lte_stack.pop();
    };
    // `vera_interp`, the same way, for every `absdelay` inside.
    const interp = self.file.stmtLte(id, .vera_interp);
    if (interp) |a| try self.interp_stack.append(self.arena, try lower_analog_op.interpQuad(self, a));
    defer if (interp != null) {
        _ = self.interp_stack.pop();
    };
    // `vera_nodiff`, the same way, for every assignment inside.
    const nodiff = self.file.stmtLte(id, .vera_nodiff);
    if (nodiff) |a| try self.nodiff_stack.append(self.arena, try nodiffValue(self, a));
    defer if (nodiff != null) {
        _ = self.nodiff_stack.pop();
    };
    switch (self.file.stmt(id)) {
        .contribute, .indirect => if (stopping(self)) return self.err(tok, .E0526, "", .{}),
        else => {}, // else: only a contribution leaves a branch without a Jacobian
    }
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| try lowerSeqBlock(self, b), // §5.3
        .assign => |a| try lowerAssign(self, a.target, a.value), // §5.7
        .contribute => |c| try lower_contrib.lowerContribute(self, c.lhs, c.rhs), // §5.6
        .indirect => |c| try lower_contrib.lowerIndirect(self, tok, c.lhs, c.probe, c.eqn), // §5.6.7
        .if_stmt => |s| {
            if (s.is_generate) try lower_control.checkGenScheme(self, tok, s.cond); // §6.6
            try lower_control.lowerIf(self, s.cond, s.then_s, s.else_s); // §5.8
        },
        .case_stmt => |s| {
            if (s.is_generate) try lower_control.checkGenScheme(self, tok, s.scrutinee); // §6.6
            try lower_control.lowerCase(self, tok, s.kind, s.scrutinee, s.arms); // §5.8.3
        },
        .for_stmt => |s| try lower_control.lowerFor(self, s.init, s.cond, s.step, s.body), // §5.9.2
        .while_stmt => |s| try lower_control.lowerWhile(self, s.cond, s.body), // §5.9.1
        .repeat_stmt => |s| try lower_control.lowerRepeat(self, s.count, s.body), // §5.9
        // §5.10. A.6.5 gives `@*`/`@ (*)` (recorded as a `.none` event) to
        // `event_control` alone; `analog_event_control` has no such
        // alternative.
        .event_control => |s| if (s.event == .none)
            try self.err(tok, .E0701, "", .{})
        else
            try lower_event.lowerEventControl(self, s.event, s.body),
        .event_trigger => |s| try lowerEventTrigger(self, tok, s.target), // §5.10.4
        .disable => |s| try lowerDisable(self, tok, self.file.str(s.name)),
        .sys_task => |s| try lower_event.lowerSysTask(self, tok, self.file.str(s.name), s.args),
        .jump => |j| try lowerJump(self, tok, j.kind, j.value),
    }
}

/// §5.10.4 / A.6.5 `event_trigger ::= -> hierarchical_event_identifier ;`.
/// Sets the event's flag for this timepoint; `@(ev)` reads it.
///
/// A.6.4 lists `event_trigger` under `analog_event_statement` and not under
/// `analog_statement`, so a trigger outside an event control is refused, as
/// `disable` (E0401) is.
fn lowerEventTrigger(self: *Lower, tok: u32, target: Ast.ExprId) Oom!void {
    if (self.file.exprs.tag(target) != .ident) return self.err(tok, .E0235, "§5.10.4: an indexed or hierarchical named event trigger in an analog block", .{});
    const name = self.file.str(self.file.exprs.strOf(target));
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0434);
        b.help("only `@(<event>) -> ev;` is legal", .{});
        return b.emit();
    }
    const place = self.events.get(name) orelse
        return self.err(tok, .E0705, "`{s}`", .{name});
    try self.builder.writeVariable(place, self.cur, .one);
}

/// A.6.5 `disable_statement`. It is an alternative of A.6.4
/// `analog_event_statement` and absent from `analog_statement`, so
/// `@(<event>) disable <block>;` is the only form an analog block can contain.
/// Clause 5 has no section for `disable`, so annex A is the citation.
fn lowerDisable(self: *Lower, tok: u32, name: []const u8) Oom!void {
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0401);
        b.help("only `@(<event>) disable <block>;` is legal", .{});
        return b.emit();
    }
    // A.6.5's operand is a block (or task) identifier and nothing else, so a
    // name that reaches no enclosing block label has no derivation. Searched
    // innermost first: §6.7 makes a block label a scope name.
    var i = self.stmt_state.named_blocks.items.len;
    while (i > 0) {
        i -= 1;
        const nb = self.stmt_state.named_blocks.items[i];
        if (!std.mem.eql(u8, nb.name, name)) continue;
        // §5.3: "the control shall pass out of the block after the last
        // statement is executed"; a disable passes out early to the same
        // destination, so the statements after the block still run.
        try self.gotoBlock(nb.exit);
        return self.startUnreachable();
    }
    // ponytail: hierarchical spellings (`disable top.dut.seg`) are not resolved;
    // elaboration flattens a label into the instance path, so an enclosing
    // block's flat name is what `name` already is. Walk the instance tree here
    // when a fixture disables a block it does not lexically enclose.
    var b = self.errWith(tok, .E0402);
    b.msg("`{s}` names no named block in scope", .{name});
    b.help("`disable` takes the label of an enclosing named block", .{});
    return b.emit();
}

/// §5.3.2 named sequential block: its declarations shadow for the block only.
fn lowerSeqBlock(self: *Lower, b: Ast.SeqBlock) Oom!void {
    const mark = self.scope_log.items.len;
    defer lower_param.closeScope(self, mark);
    // §5.3.2's key for a local's static location, in step with `scanHeld`'s.
    const outer_path = self.block_path;
    defer self.block_path = outer_path;
    if (b.name != .none)
        self.block_path = try std.fmt.allocPrint(self.arena, "{s}{s}.", .{ outer_path, self.file.str(b.name) });
    const outer_scope = self.scope_path;
    defer self.scope_path = outer_scope;
    if (try scopeElem(self, b)) |elem|
        self.scope_path = if (outer_scope.len == 0) elem else try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ outer_scope, Elaborate.sep, elem });
    for (b.params) |*p| try lower_param.lowerParamDecl(self, p); // §5.3.2 local parameters
    try lower_param.checkOneItemPerScope(self, b.params, b.vars, &.{});
    for (b.vars) |*v| try lower_param.declareVarDecl(self, v, .local);
    if (b.name != .none) try publishBlockLocals(self, self.file.str(b.name), b);
    // §6.7 a labelled block is a scope, and A.6.5 lets `disable` name it. The
    // exit block is where control lands both when falling off the end and when
    // disabled.
    const exit: ?Mir.Block = if (b.name == .none) null else blk: {
        const e = try self.mir.addBlock(self.arena);
        try self.stmt_state.named_blocks.append(self.arena, .{ .name = self.file.str(b.name), .exit = e });
        break :blk e;
    };
    // ponytail: the only statement-list caller keeps its source-order loop here.
    for (b.body) |s| try lowerStmt(self, s);
    if (exit) |e| {
        _ = self.stmt_state.named_blocks.pop();
        try self.gotoBlock(e);
        try self.builder.sealBlock(e);
        self.cur = e;
    }
}

/// The name `b` adds to §9.15's "path", or null for a block that is no scope.
/// A generate block is named by §6.6.3 (`Ast.SeqBlock.gen_name`), with §6.6.1's
/// `[i]` when a loop generate made it; any other block by its label, which
/// elaboration flattened onto the instance path (`joinLocal`) and which is
/// read back here relative to that instance.
fn scopeElem(self: *Lower, b: Ast.SeqBlock) Oom!?[]const u8 {
    const iter = self.gen_iter;
    self.gen_iter = null; // this block's alone, never a nested one's
    if (b.gen_name != .none) {
        const g = self.file.str(b.gen_name);
        return if (iter) |k| try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ g, k }) else g;
    }
    if (b.name == .none) return null;
    const label = self.file.str(b.name);
    const unit = if (self.cur_unit < self.out.unit_paths.len) self.out.unit_paths[self.cur_unit].path else "";
    return if (std.mem.startsWith(u8, label, unit)) label[unit.len..] else label;
}

/// §5.3.2: "All identifiers declared within a named sequential block can be
/// accessed outside the scope in which they are declared." The block's scope is
/// popped by `closeScope`, so the outside spelling needs a second binding that is
/// not shadow-logged, under `<label>.<local>` (the path `flatName` builds for
/// `myscope.localVar`). Assignment from outside stays refused (E0316): "Named
/// block variables cannot be assigned outside the scope of the block".
///
/// ponytail: last declaration wins when the same label runs twice (a §6.6.1
/// unrolled `for` body). Nothing can name one iteration's copy apart from
/// another, so there is nothing for an ordinal to disambiguate yet.
fn publishBlockLocals(self: *Lower, label: []const u8, b: Ast.SeqBlock) Oom!void {
    for (b.vars) |v| {
        const local = self.file.str(v.name);
        // Arrays are scalarized into `name[i]` entries, which have no scalar
        // slot under the bare name; §5.3.2's example is a scalar and no fixture
        // names an element hierarchically.
        const slot = self.vars.get(local) orelse continue;
        const q = try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ label, Elaborate.sep, local });
        try self.vars.put(self.arena, q, slot);
        try self.block_locals.put(self.arena, q, {});
    }
    // "Parameters declared within a named block have local scope", local to
    // assignment, which §6.3 override cannot reach anyway; the read follows the
    // same "all identifiers" sentence. They live in `consts`.
    for (b.params) |p| {
        const c = self.consts.get(self.file.str(p.name)) orelse continue;
        const q = try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ label, Elaborate.sep, self.file.str(p.name) });
        try self.consts.put(self.arena, q, c);
    }
}

/// A `vera_nodiff` value: §2.9's default 1 when absent, otherwise a constant
/// that folds without the model card, since it picks what the device computes.
/// E0525 otherwise, and the statement keeps its derivatives.
fn nodiffValue(self: *Lower, a: Ast.LteAttr) Oom!bool {
    if (a.value == .none) return true;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0525, "", .{});
        return false;
    };
    return c.isTrue();
}

/// Is the innermost enclosing `vera_nodiff` on?
fn stopping(self: *const Lower) bool {
    const s = self.nodiff_stack.items;
    return s.len != 0 and s[s.len - 1];
}

/// The right-hand side of an assignment: its value, with no derivative under
/// `vera_nodiff`. Only a real carries one.
// ponytail: an array-to-array copy (`A = B`, a slice) keeps its elements'
// derivatives; stop them where they are assigned, or route those copies here.
fn assignValue(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const tv = try lower_expr.lowerExpr(self, e);
    if (!stopping(self) or tv.ty != .real) return tv;
    return .{ .v = try self.emit(.dstop, &.{tv.v}), .ty = .real };
}

/// §5.7 procedural assignment. The target is an lvalue expression so array
/// elements (§3.2.2) work; the value is coerced to the target's type
/// (§4.2.1.1/§4.2.1.2).
fn lowerAssign(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    // §3.2.2 whole-array assignment from an assignment pattern (§4.2.13):
    // both sides are scalarized, so this is an element-wise copy.
    if (ex.tag(target) == .ident and (ex.tag(value) == .assign_pattern or ex.tag(value) == .concat)) {
        const name = self.file.str(ex.strOf(target));
        if (self.arrays.get(name)) |info| {
            const elems = try lower_param.flattenPattern(self, value, info.dims);
            var key_buf: [lower_param.elem_key_len]u8 = undefined;
            var sub: [lower_param.max_stack_dims]i64 = undefined;
            const idx = try lower_param.subscriptBuf(self, &sub, info.dims.len);
            for (elems, 0..) |elem, k| {
                if (elem == .none) continue;
                lower_param.shapeSubscripts(info.dims, k, idx);
                if (info.mem == null and !self.vars.contains(try lower_param.elemKey(self, &key_buf, name, idx))) continue;
                const tv = try assignValue(self, elem);
                try lower_param.writeElem(self, name, info, idx, try self.coerceTo(elem, info.ty, tv));
            }
            return;
        }
    }
    // §5.7 slice assignment: "The array on the LHS of the assignment shall be
    // an array variable, a slice of an array variable or an array parameter".
    // Asked first because a slice is neither a whole array nor a runtime element.
    if (try copyArraySlice(self, target, value)) return;
    // §5.7 whole-array assignment from another array, `A = B`: a shape rule,
    // checked here where both shapes are in scope, then an element-wise copy.
    if (ex.tag(target) == .ident and ex.tag(value) == .ident) {
        const dst_name = self.file.str(ex.strOf(target));
        if (self.arrays.get(dst_name)) |dst| {
            if (try copyWholeArray(self, target, value, dst_name, dst)) return;
        }
    }
    // §3.2.2 `a[i] = ...` with a runtime index (§4.7.1 Example 3's `arrayadd`
    // loops on an ordinary variable). The write becomes one masked write per
    // element, the mirror of `lowerIndex`'s select chain for a runtime read.
    if (ex.tag(target) == .index) {
        if (try assignRuntimeIndex(self, target, value)) return;
    }
    const lv = try resolveLvalue(self, target) orelse {
        _ = try lower_expr.lowerExpr(self, value); // keep collecting errors from the rhs
        return;
    };
    const tv = try assignValue(self, value);
    try writeLvalue(self, lv, try self.coerceTo(value, lv.ty, tv));
    // §4.6.4: remember that this name now carries a noise source, so a later
    // `I(a,b) <+ n;` still exports the generator. Recorded after the rhs is
    // lowered so the walk below sees the expression the value came from.
    if (ex.tag(target) == .ident) {
        var srcs: std.ArrayList(NoiseSrc) = .empty;
        try lower_contrib.noiseSrcsOf(self, value, &srcs);
        if (srcs.items.len != 0) {
            const g = try self.var_noise.getOrPut(self.arena, self.file.str(ex.strOf(target)));
            if (g.found_existing) {
                // Union by identity: re-lowering a loop body or a second
                // assignment through the same call is still one generator.
                for (g.value_ptr.*) |s| try lower_contrib.addNoiseSrc(self.arena, &srcs, s);
            }
            g.value_ptr.* = srcs.items;
        }
    }
}

/// Runtime scalar-element assignment. Each cell receives `select(index == k,
/// value, old)`, leaving all other cells unchanged, including on an invalid index.
/// ponytail: N masked writes per assignment; replace scalarization with explicit
/// array storage if large mutable arrays make this compile-time expansion costly.
fn assignRuntimeIndex(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    // Asked before the rhs is lowered: `false` falls through to the scalar path,
    // which lowers `value` itself, and lowering it twice would repeat side effects.
    if (!try isRuntimeElem(self, target)) return false;
    return writeRuntimeIndex(self, target, value, try assignValue(self, value));
}

/// Reports whether `target` is an element of a declared array whose subscript is
/// only known at run time; the precondition `assignRuntimeIndex` and §4.7.2.3's
/// output-argument writeback share.
fn isRuntimeElem(self: *Lower, target: Ast.ExprId) Oom!bool {
    var subs: [lower_param.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try indexChain(self, target, &subs)) orelse return false;
    for (chain.subs) |s| {
        if (lower_constfold.foldExpr(self, s, false) != null) continue;
        return self.arrays.contains(self.file.str(chain.name));
    }
    return false;
}

/// Writes an already lowered value to an array element with a runtime subscript,
/// as masked writes; §4.7.2.3's writeback has a `Mir.Value` and no expression.
/// Returns false when `target` is not such an element. `at_e` is only the
/// diagnostic site for §3.3's string conversion.
pub fn writeRuntimeIndex(self: *Lower, target: Ast.ExprId, at_e: Ast.ExprId, tv: TypedValue) Oom!bool {
    if (!try isRuntimeElem(self, target)) return false;
    var subs: [lower_param.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try indexChain(self, target, &subs)).?;
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name).?;
    if (!try checkSubscriptCount(self, target, name, info, chain.subs.len)) return true;

    const iv = try runtimeArrayIndex(self, chain.subs, info.dims);
    const new = try self.coerceTo(at_e, info.ty, tv);
    // A memory-backed array stores one element; an invalid subscript (-1)
    // stores nothing, as every masked write below leaves its cell.
    if (info.mem) |m| {
        try lower_param.storeElem(self, m.place, iv, new);
        return true;
    }
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    var sub: [lower_param.max_stack_dims]i64 = undefined;
    const at = try lower_param.subscriptBuf(self, &sub, info.dims.len);
    for (0..lower_param.shapeCells(info.dims)) |k| {
        lower_param.shapeSubscripts(info.dims, k, at);
        const key = try lower_param.elemKey(self, &key_buf, name, at);
        const slot = self.vars.get(key) orelse {
            try self.err(self.file.exprs.mainTok(target), .E0312, "`{s}`", .{name});
            return true;
        };
        const old = try self.builder.readVariable(slot.place, self.cur);
        const c = try self.emit(.ieq, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(k)) });
        try self.builder.writeVariable(slot.place, self.cur, try self.emit(.select, &.{ c, new, old }));
    }
    return true;
}

/// Flattens a full subscript tuple into one index in declaration order, checking
/// each dimension so `[i][columns]` cannot alias `[i+1][0]`. An invalid tuple gives
/// -1, which every masked write leaves untouched.
pub fn runtimeArrayIndex(self: *Lower, subs: []const Ast.ExprId, dims: []const lower_param.Bounds) Oom!Mir.Value {
    var flat = Mir.Value.zero;
    var valid = Mir.Value.one;
    for (subs, dims) |s, d| {
        const index = try self.toInt(try lower_expr.lowerExpr(self, s));
        const lo = try self.mir.addIntConst(self.arena, d.lo);
        const hi = try self.mir.addIntConst(self.arena, d.hi);
        const in_range = try self.emit(.logand, &.{
            try self.emit(.ige, &.{ index, lo }),
            try self.emit(.ile, &.{ index, hi }),
        });
        valid = try self.emit(.logand, &.{ valid, in_range });
        // Keep invalid index arithmetic bounded too, even before the final mask.
        const bounded = try self.emit(.select, &.{ in_range, index, lo });
        const offset = if (d.descending)
            try self.emit(.isub, &.{ hi, bounded })
        else
            try self.emit(.isub, &.{ bounded, lo });
        flat = try self.emit(.iadd, &.{
            try self.emit(.imul, &.{ flat, try self.mir.addIntConst(self.arena, d.count()) }),
            offset,
        });
    }
    return self.emit(.select, &.{ valid, flat, try self.mir.addIntConst(self.arena, -1) });
}

/// §5.7 unpacked array assignment, `A = B`: "Array assignments shall only be
/// done with arrays that are compatible. An array, or a slice of such an array,
/// shall be assignment compatible with any other such array or slice if all the
/// following conditions are satisfied: — The element types of source and target
/// shall be equivalent. — Every dimension of the source array shall have the
/// same number of elements as the target array."
///
/// The clause counts elements, not indices: `int A[10:1]; int B[0:9]; A = B;` is legal.
///
/// Returns false when the right-hand side is not an array at all, so the
/// ordinary scalar path keeps its own diagnostics.
fn copyWholeArray(
    self: *Lower,
    target: Ast.ExprId,
    value: Ast.ExprId,
    dst_name: []const u8,
    dst: ArrayInfo,
) Oom!bool {
    const src_name = self.file.str(self.file.exprs.strOf(value));
    const src = self.arrays.get(src_name) orelse return false;

    if (src.dims.len != dst.dims.len) {
        try self.err(self.file.exprs.mainTok(target), .E0429, "array `{s}` has {d} dimensions and `{s}` has {d}", .{
            dst_name, dst.dims.len, src_name, src.dims.len,
        });
        return true;
    }
    for (dst.dims, src.dims, 0..) |d, s, k| {
        if (d.count() == s.count()) continue;
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        // Print element counts, not bounds: `dimsBounds` normalizes `[10:1]` to
        // lo/hi, which is not the source's spelling.
        b.msg("dimension {d} of array `{s}` holds {d} elements and `{s}` holds {d}", .{
            k, dst_name, d.count(), src_name, s.count(),
        });
        b.note("§5.7 counts elements, not indices: `A[10:1] = B[0:9]` is legal", .{});
        try b.emit();
        return true;
    }
    // "The element types of source and target shall be equivalent." §4.2.1.1's
    // integer/real conversions do not apply: the clause has no coercion.
    if (src.ty != dst.ty) {
        try self.err(self.file.exprs.mainTok(target), .E0429, "array `{s}` holds `{s}` and `{s}` holds `{s}`", .{
            dst_name, @tagName(dst.ty), src_name, @tagName(src.ty),
        });
        return true;
    }

    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    var d_sub: [lower_param.max_stack_dims]i64 = undefined;
    var s_sub: [lower_param.max_stack_dims]i64 = undefined;
    const di = try lower_param.subscriptBuf(self, &d_sub, dst.dims.len);
    const si = try lower_param.subscriptBuf(self, &s_sub, src.dims.len);
    const n = lower_param.shapeCells(dst.dims);
    for (0..n) |k| {
        lower_param.shapeSubscripts(dst.dims, k, di);
        lower_param.shapeSubscripts(src.dims, k, si);
        const v = (try lower_expr.arrayElemValue(self, src_name, si)) orelse continue;
        if (dst.mem == null and !self.vars.contains(try lower_param.elemKey(self, &key_buf, dst_name, di))) continue;
        // The element types are already known equivalent, so there is no
        // conversion to make, only the source's `Value` to re-bind.
        try lower_param.writeElem(self, dst_name, dst, di, v.v);
    }
    return true;
}

/// §5.7 / A.8.5 an array reference that is not a scalar element: a whole array
/// (`subs.len == 0`) or a slice, whose subscript list is shorter than the declared
/// dimension list.
pub const ArraySlice = struct { name: []const u8, info: ArrayInfo, subs: []const Ast.ExprId };

/// Returns `e` as a whole-array or slice reference, or null for anything else,
/// including a full subscript list. `subs` may point into `buf`.
pub fn arrayRef(self: *Lower, e: Ast.ExprId, buf: *[lower_param.max_stack_dims]Ast.ExprId) Oom!?ArraySlice {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            const info = self.arrays.get(name) orelse return null;
            return .{ .name = name, .info = info, .subs = &.{} };
        },
        .index => {
            const chain = (try indexChain(self, e, buf)) orelse return null;
            const name = self.file.str(chain.name);
            const info = self.arrays.get(name) orelse return null;
            if (chain.subs.len >= info.dims.len) return null; // a cell, not a slice
            return .{ .name = name, .info = info, .subs = chain.subs };
        },
        else => return null, // else: only a name or a select can name an array
    }
}

/// §5.7 slice assignment, `A[i] = B` / `B = A[i]`, and A.8.5's production for
/// the right-hand side:
///
///   array_analog_variable_rvalue ::=
///         array_variable_identifier
///       | array_variable_identifier [ analog_expression ] { [ analog_expression ] }
///       | assignment_pattern
///
/// A short subscript list is the grammar's slice: on `integer flag_array[0:8][0:3]`,
/// `flag_array[3]` is a four-element row. The subscript is an `analog_expression`,
/// so it may be known only during the solve; a dynamic prefix becomes one `$idx`
/// per destination cell on the read side and one masked write per candidate row on
/// the write side. All source cells are read before any destination cell is
/// written, so an overlapping copy behaves as a copy.
///
/// ponytail: P*N selects for a P-row array of N-element slices; upgrade to real
/// array storage.
///
/// Returns false when neither side is a slice, so the whole-array and
/// runtime-element paths keep their own diagnostics.
fn copyArraySlice(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    var tbuf: [lower_param.max_stack_dims]Ast.ExprId = undefined;
    var vbuf: [lower_param.max_stack_dims]Ast.ExprId = undefined;
    const dst = (try arrayRef(self, target, &tbuf)) orelse return false;
    const src = (try arrayRef(self, value, &vbuf)) orelse return false;
    if (dst.subs.len == 0 and src.subs.len == 0) return false; // `copyWholeArray`

    // "Every dimension of the source array shall have the same number of
    // elements as the target array", compared on the slices.
    const dd = dst.info.dims[dst.subs.len..];
    const sd = src.info.dims[src.subs.len..];
    if (dd.len != sd.len or dst.info.ty != src.info.ty) {
        try self.err(self.file.exprs.mainTok(target), .E0429, "a `{s}` slice of `{s}` has {d} dimension(s) and a `{s}` slice of `{s}` has {d}", .{
            @tagName(dst.info.ty), dst.name, dd.len, @tagName(src.info.ty), src.name, sd.len,
        });
        return true;
    }
    for (dd, sd, 0..) |d, s, k| {
        if (d.count() == s.count()) continue;
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        b.msg("dimension {d} of the `{s}` slice holds {d} elements and the `{s}` slice holds {d}", .{
            k, dst.name, d.count(), src.name, s.count(),
        });
        b.note("§5.7 counts elements, not indices: `A[10:1] = B[0:9]` is legal", .{});
        try b.emit();
        return true;
    }

    const n = lower_param.shapeCells(dd);
    const vals = try self.arena.alloc(Mir.Value, n);
    if (!try readSliceCells(self, value, src, dd, vals)) return true;
    return writeSliceCells(self, target, dst, dd, vals);
}

/// Reads every cell of `s`'s slice into `out`, in the row-major order
/// `shapeSubscripts` walks. Returns false when a subscript is out of range.
pub fn readSliceCells(self: *Lower, at_e: Ast.ExprId, s: ArraySlice, sd: []const lower_param.Bounds, out: []Mir.Value) Oom!bool {
    var full: [lower_param.max_stack_dims]i64 = undefined;
    const idx = try lower_param.subscriptBuf(self, &full, s.info.dims.len);
    const pdims = s.info.dims[0..s.subs.len];

    if (try constPrefix(self, at_e, s, idx[0..s.subs.len])) |known| {
        if (!known) return false; // out of range — E0310 already reported
        for (out, 0..) |*v, k| {
            lower_param.shapeSubscripts(sd, k, idx[s.subs.len..]);
            const el = (try lower_expr.arrayElemValue(self, s.name, idx)) orelse return false;
            v.* = el.v;
        }
        return true;
    }
    // A dynamic prefix: one `$idx` switch per destination cell, over the same
    // cell of every candidate row. `runtimeArrayIndex` answers -1 for a
    // subscript outside its dimension, which `$idx` reads as the default 0, as
    // `lowerIndex` does for an out-of-range scalar read.
    const iv = try runtimeArrayIndex(self, s.subs, pdims);
    // Memory-backed: cell k of row `iv` is element `iv * cells + k`, and the
    // invalid row -1 lands below 0, which reads the same zero.
    if (s.info.mem) |m| {
        const row = try self.emit(.imul, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(out.len)) });
        for (out, 0..) |*v, k|
            v.* = try lower_param.loadElem(self, m, s.info.ty, try self.emit(.iadd, &.{ row, try self.mir.addIntConst(self.arena, @intCast(k)) }));
        return true;
    }
    const callee: []const u8 = switch (s.info.ty) {
        .real => "$idx",
        .integer => "$idx$int",
        .string => "$idx$str",
    };
    for (out, 0..) |*v, k| {
        var args: std.ArrayList(Mir.Value) = .empty;
        defer args.deinit(self.arena);
        try args.append(self.arena, .zero);
        try args.append(self.arena, iv);
        lower_param.shapeSubscripts(sd, k, idx[s.subs.len..]);
        for (0..lower_param.shapeCells(pdims)) |p| {
            lower_param.shapeSubscripts(pdims, p, idx[0..s.subs.len]);
            const el = (try lower_expr.arrayElemValue(self, s.name, idx)) orelse return false;
            try args.append(self.arena, el.v);
        }
        v.* = try self.call(callee, args.items);
    }
    return true;
}

/// The mirror image: writes `vals` into every cell of `d`'s slice.
pub fn writeSliceCells(self: *Lower, at_e: Ast.ExprId, d: ArraySlice, dd: []const lower_param.Bounds, vals: []const Mir.Value) Oom!bool {
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    var full: [lower_param.max_stack_dims]i64 = undefined;
    const idx = try lower_param.subscriptBuf(self, &full, d.info.dims.len);
    const pdims = d.info.dims[0..d.subs.len];

    if (try constPrefix(self, at_e, d, idx[0..d.subs.len])) |known| {
        if (!known) return true;
        for (vals, 0..) |v, k| {
            lower_param.shapeSubscripts(dd, k, idx[d.subs.len..]);
            if (d.info.mem == null and !self.vars.contains(try lower_param.elemKey(self, &key_buf, d.name, idx))) continue;
            try lower_param.writeElem(self, d.name, d.info, idx, v);
        }
        return true;
    }
    const iv = try runtimeArrayIndex(self, d.subs, pdims);
    // Memory-backed: the `readSliceCells` addressing; row -1 writes nothing.
    if (d.info.mem) |m| {
        const row = try self.emit(.imul, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(vals.len)) });
        for (vals, 0..) |v, k|
            try lower_param.storeElem(self, m.place, try self.emit(.iadd, &.{ row, try self.mir.addIntConst(self.arena, @intCast(k)) }), v);
        return true;
    }
    for (0..lower_param.shapeCells(pdims)) |p| {
        lower_param.shapeSubscripts(pdims, p, idx[0..d.subs.len]);
        const hit = try self.emit(.ieq, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(p)) });
        for (vals, 0..) |v, k| {
            lower_param.shapeSubscripts(dd, k, idx[d.subs.len..]);
            const slot = self.vars.get(try lower_param.elemKey(self, &key_buf, d.name, idx)) orelse continue;
            const old = try self.builder.readVariable(slot.place, self.cur);
            try self.builder.writeVariable(slot.place, self.cur, try self.emit(.select, &.{ hit, v, old }));
        }
    }
    return true;
}

/// The slice's leading subscripts, if every one of them folds: true when they
/// are also in range, false when §3.2.2 has been reported on them, null when at
/// least one is only known during the solve.
fn constPrefix(self: *Lower, at_e: Ast.ExprId, s: ArraySlice, out: []i64) Oom!?bool {
    for (s.subs, out) |e, *o| {
        const c = lower_constfold.foldExpr(self, e, false) orelse return null;
        o.* = c.asInt();
    }
    for (out, s.info.dims[0..s.subs.len], 0..) |i, d, k| {
        if (i >= d.lo and i <= d.hi) continue;
        try self.err(self.file.exprs.mainTok(at_e), .E0310, "index {d} is outside dimension {d} of `{s}[{d}:{d}]`", .{
            i, k, s.name, d.lo, d.hi,
        });
        return false;
    }
    return true;
}

/// An assignable location (§5.7): a variable, or one element of an array. An
/// element of a memory-backed array (§3.2.2) has no SSA place of its own, so
/// the location is read and written through `readLvalue`/`writeLvalue` only.
pub const Lvalue = struct {
    ty: Lower.Ty,
    at: union(enum) {
        place: Ssa.Place,
        elem: struct { place: Ssa.Place, index: Mir.Value },
    },
};

/// Returns the current value at `lv`.
pub fn readLvalue(self: *Lower, lv: Lvalue) Oom!Mir.Value {
    return switch (lv.at) {
        .place => |p| self.builder.readVariable(p, self.cur),
        .elem => |el| self.emit(if (lv.ty == .integer) .iload else .fload, &.{ try self.builder.readVariable(el.place, self.cur), el.index }),
    };
}

/// Writes `v` to `lv` in the current block.
pub fn writeLvalue(self: *Lower, lv: Lvalue, v: Mir.Value) Oom!void {
    switch (lv.at) {
        .place => |p| try self.builder.writeVariable(p, self.cur, v),
        .elem => |el| try lower_param.storeElem(self, el.place, el.index, v),
    }
}

/// Resolves an assignable location, `x` or `x[<constant>]` (§3.2.2). Returns null
/// after reporting a diagnostic for anything else.
pub fn resolveLvalue(self: *Lower, e: Ast.ExprId) Oom!?Lvalue {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.get(name)) |s| return .{ .ty = s.ty, .at = .{ .place = s.place } };
            if (self.param_index.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0312);
                b.msg("`{s}`", .{name});
                b.help("declare a `real` variable if the value changes during the solve", .{});
                try b.emit();
                return null;
            }
            var b = self.errWith(self.file.exprs.mainTok(e), .E0313);
            b.msg("`{s}`", .{name});
            const near = diag.didYouMeanMap(name, self.vars) orelse
                diag.didYouMeanMap(name, self.param_index);
            if (near) |s| b.suggestHere(s);
            try b.emit();
            return null;
        },
        .index => {
            var subs: [lower_param.max_stack_dims]Ast.ExprId = undefined;
            const chain = (try indexChain(self, e, &subs)) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
                return null;
            };
            const name = self.file.str(chain.name);
            var idx: [lower_param.max_stack_dims]i64 = undefined;
            const at = try lower_param.subscriptBuf(self, &idx, chain.subs.len);
            for (chain.subs, at) |s, *o| {
                const c = lower_constfold.constEval(self, s) orelse {
                    try self.err(self.file.exprs.mainTok(e), .E0311, "indexing `{s}`", .{name});
                    return null;
                };
                o.* = c.asInt();
            }
            return arrayElem(self, e, name, at);
        },
        // §5.7's third restriction: "Hierarchical assignment of a variable from
        // another scope/module is not allowed." Its own code, so the message
        // reads as the rule it is rather than a VerA limitation.
        .hier_ident => {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0316);
            b.msg("a hierarchical name is not an assignment target", .{});
            b.note("§5.7: \"Hierarchical assignment of a variable from another scope/module is not allowed\"", .{});
            try b.emit();
            return null;
        },
        // A.6.3: `{a, b} = ...` is net_lvalue/variable_lvalue, a different
        // production from the §4.2.13 expression, and it is not in the analog
        // subset (annex C). Named so the message does not blame the rhs.
        .concat, .multi_concat => {
            try self.err(self.file.exprs.mainTok(e), .E0317, "", .{});
            return null;
        },
        else => { // else: not an lvalue: E0316
            try self.err(self.file.exprs.mainTok(e), .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
            return null;
        },
    }
}

fn arrayElem(self: *Lower, e: Ast.ExprId, name: []const u8, idx: []const i64) Oom!?Lvalue {
    const info = self.arrays.get(name) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return null;
    };
    if (!try checkSubscripts(self, e, name, info, idx)) return null;
    if (info.mem) |m| return .{ .ty = info.ty, .at = .{ .elem = .{
        .place = m.place,
        .index = try self.mir.addIntConst(self.arena, lower_param.flatIndex(info.dims, idx)),
    } } };
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    const s = self.vars.get(try lower_param.elemKey(self, &key_buf, name, idx)) orelse return null;
    return .{ .ty = s.ty, .at = .{ .place = s.place } };
}

/// The base identifier and the subscripts of `name[i][j]...` (§3.2), outermost first.
pub const IndexChain = struct { name: Ast.StrId, subs: []const Ast.ExprId };
/// Returns `e`'s base name and subscripts, or null when the base is not a plain
/// name (`f(x)[0]`). `subs` points into `buf`, or into the arena when deeper.
pub fn indexChain(self: *Lower, e: Ast.ExprId, buf: []Ast.ExprId) Oom!?IndexChain {
    const ex = &self.file.exprs;
    var n: usize = 0;
    var cur = e;
    while (ex.tag(cur) == .index) : (cur = ex.lhs(cur)) n += 1;
    if (ex.tag(cur) != .ident or ex.strOf(cur) == .none) return null;
    const subs = if (n <= buf.len) buf[0..n] else try self.arena.alloc(Ast.ExprId, n);
    const name = ex.strOf(cur);
    cur = e;
    var i = n;
    while (i > 0) {
        i -= 1;
        subs[i] = ex.rhs(cur);
        cur = ex.lhs(cur);
    }
    return .{ .name = name, .subs = subs };
}

/// Checks that a reference supplies one subscript per declared dimension (§3.2),
/// returning false after a diagnostic. Separate from the range check because a
/// runtime subscript has a count but no value.
pub fn checkSubscriptCount(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, n: usize) Oom!bool {
    if (n == info.dims.len) return true;
    try self.err(self.file.exprs.mainTok(e), .E0356, "`{s}` is declared with {d} dimension(s) and is indexed with {d}", .{
        name, info.dims.len, n,
    });
    return false;
}

/// Checks each subscript against its dimension's declared bounds (§3.2.2),
/// returning false after a diagnostic.
pub fn checkSubscripts(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, idx: []const i64) Oom!bool {
    if (!try checkSubscriptCount(self, e, name, info, idx.len)) return false;
    for (idx, info.dims, 0..) |i, d, k| {
        if (i >= d.lo and i <= d.hi) continue;
        try self.err(self.file.exprs.mainTok(e), .E0310, "index {d} is outside dimension {d} of `{s}[{d}:{d}]`", .{
            i, k, name, d.lo, d.hi,
        });
        return false;
    }
    return true;
}

/// §4.7.1 `return`, §5.9 `break` / `continue`. All three close the current
/// block and continue into dead code, so statements after them are lowered but
/// unreachable (and dropped by codegen).
fn lowerJump(self: *Lower, tok: u32, kind: Ast.Stmt.JumpKind, value: Ast.ExprId) Oom!void {
    switch (kind) {
        .ret => {
            const rc = self.ret orelse {
                try self.err(tok, .E0403, "", .{});
                return;
            };
            if (value != .none) {
                const tv = try lower_expr.lowerExpr(self, value);
                const v = if (rc.slot.ty == .real) try self.toReal(tv) else try self.toInt(tv);
                try self.builder.writeVariable(rc.slot.place, self.cur, v);
            }
            try self.gotoBlock(rc.exit);
        },
        .brk, .cont => {
            const l = self.loops.getLastOrNull() orelse {
                try self.err(tok, .E0404, "`{s}`", .{if (kind == .brk) "break" else "continue"});
                return;
            };
            try self.gotoBlock(if (kind == .brk) l.brk else l.cont);
        },
    }
    try self.startUnreachable();
}
