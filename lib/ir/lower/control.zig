//! §5.8 conditionals, §5.9 loops, and §6.6 hierarchy selection.
//!
//! In: if/case/for/while/repeat AST and gated hierarchy restrictions.
//! Out: MIR control flow (blocks, branches, phis) and selection diagnostics.
//!
//! LRM clauses this file's code cites: §3.5, §4.2.7, §5.6.7, §5.8, §5.8.1, §5.8.3, §5.9, §5.9.1, §5.9.2, §6.3.1, §6.4, §6.6, §6.6.1, §6.6.2, §6.9.4.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_stmt = @import("stmt.zig");
const lower_shape = @import("shape.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;

/// This file's private state on `Lower` (`Lower.control_state`): the scratch
/// `isStaticValue` walks with, cleared at the start of each walk and reused, so
/// a condition costs no arena allocation once the sets have grown to the
/// largest walk (on psp103, ~5k conditions used to leave ~3 MB of dead sets).
pub const State = struct {
    /// Values already on the walk.
    seen: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty,
    /// Blocks whose deciding branch was already judged.
    blocks: std.AutoHashMapUnmanaged(Mir.Block, void) = .empty,
    /// `controlStatic`'s predecessor worklist; nested walks share it above a
    /// base mark.
    stack: std.ArrayList(Mir.Block) = .empty,
};

/// §6.6: "All expressions in generate schemes shall be constant expressions,
/// deterministic at elaboration time." The scheme of an if-generate is its
/// condition and of a case-generate its selector; the loop generate's three
/// parts are E0417-E0419, judged in `tryUnrollFor` where the unroll needs them.
///
/// A parameter is a `constant_primary` (A.8.4), and §6.6 exists for "parameter
/// values to affect the structure of the model", so parameters fold here; a module
/// variable or a solution read does not. Each parameter read becomes a §3.4 shape
/// parameter (`shapeEval`), which `checkShape` keeps the card from moving. An
/// unfoldable scheme is reported, then still lowered as a §5.8 runtime branch.
///
/// ponytail: `lowerIf` still lowers a parameterized generate as a runtime diamond
/// over both arms. The card cannot move a shape parameter, so the diamond always
/// takes the compiled arm; this is unobservable until §6.6.1 per-instance
/// declarations exist.
pub fn checkGenScheme(self: *Lower, tok: u32, scheme: Ast.ExprId) Oom!void {
    if (lower_constfold.shapeEval(self, scheme) != null) return;
    var b = self.errWith(tok, .E0428);
    b.help("a generate scheme may read parameters and genvars, not variables", .{});
    try b.emit();
}

/// §6.3.1/§6.4 forbid a defparam in or below a paramset instance. §6.9.4
/// gives parameters their final values before §6.6.2 selects generate arms;
/// flattening retained both arms, so judge their gates only after lowerParamDecl.
/// As with every generate scheme, the card must preserve the selected shape.
pub fn checkParamsetDefparams(self: *Lower) Oom!void {
    for (self.paramset_defparams) |dp| {
        if (dp.gate != .none) {
            const active = lower_constfold.shapeEval(self, dp.gate) orelse {
                try checkGenScheme(self, self.file.exprs.mainTok(dp.gate), dp.gate);
                continue;
            };
            if (!active.isTrue()) continue;
        }
        try self.err(dp.main_tok, .E0926, "a defparam in the hierarchy of paramset instance `{s}`", .{dp.instance});
    }
}

/// Lowers a §5.8 conditional. A constant-foldable condition lowers only the taken
/// arm, which is also what collapses `generate if` (§6.6.2).
pub fn lowerIf(self: *Lower, cond: Ast.ExprId, then_s: Ast.StmtId, else_s: Ast.StmtId) Oom!void {
    if (lower_constfold.foldExpr(self, cond, false)) |c| {
        return lower_stmt.lowerStmt(self, if (c.isTrue()) then_s else else_s);
    }
    // §5.6.7 "Indirect branch contributions shall not be used in conditional
    // ... statements, unless the conditional expression is a constant
    // expression", and a parameter is a `constant_primary` (A.8.4). The arm
    // decides the circuit's topology, so its parameters become shape
    // parameters a card cannot move (`shapeEval`), as a generate scheme's do.
    if ((try hasIndirect(self, then_s) or try hasIndirect(self, else_s)) and
        lower_constfold.foldExpr(self, cond, true) != null)
    {
        const c = lower_constfold.shapeEval(self, cond).?;
        return lower_stmt.lowerStmt(self, if (c.isTrue()) then_s else else_s);
    }
    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    try lowerBranchStmt(self, c, then_s, else_s, isAnalysisOrConst(self, cond) or try isStaticValue(self, c), cond);
}

/// Whether statement `id` or one under it is a §5.6.7 indirect contribution.
fn hasIndirect(self: *Lower, id: Ast.StmtId) Oom!bool {
    if (id == .none) return false;
    if (self.file.stmt(id) == .indirect) return true;
    var walk = struct {
        lower: *Lower,
        found: bool = false,
        pub fn expr(_: *@This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: *@This(), s: Ast.StmtId) Oom!void {
            w.found = w.found or try hasIndirect(w.lower, s);
        }
    }{ .lower = self };
    try self.file.stmtEdges(id, &walk);
    return walk.found;
}

/// Lowers a body that only runs under a runtime condition, raising `cond_depth` for
/// §5.6.7's ban on indirect contributions and §5.8.1/§5.9's ban on analog operators.
/// Constant-folded paths call `lowerStmt` directly, which is the "unless the
/// conditional expression is a constant expression" carve-out. `static` is §5.8.1's
/// weaker `analysis_or_constant_expression` carve-out; it relaxes E0514 alone.
fn lowerCondBody(self: *Lower, body: Ast.StmtId, static: bool) Oom!void {
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }
    try lower_stmt.lowerStmt(self, body);
}

/// Reports whether `e` is an A.8.3 `analysis_or_constant_expression` (the §5.8.1
/// carve-out): literals, parameters and `analysis()` calls combined with operators,
/// none of which can change between Newton iterations. Unlike `foldExpr(..., false)`,
/// a parameter qualifies: the card may override it, but not mid-solve.
pub fn isAnalysisOrConst(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        // A.8.4 `number`, `string_literal`.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => true,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk false;
            break :blk self.param_index.contains(name) or self.consts.contains(name);
        },
        // A.8.2 analysis_function_call. Its value is fixed for the analysis,
        // which is the whole reason §5.8.1 spells out "analysis_or_constant".
        // A.8.4 `system_parameter_identifier`: §9.18 Syntax 9-13's six hierarchical
        // parameters, fixed per instance for the whole simulation.
        .sys_call => blk: {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "analysis")) break :blk true;
            if (ex.args(e).len != 0) break :blk false;
            for ([_][]const u8{ "$mfactor", "$xposition", "$yposition", "$angle", "$hflip", "$vflip" }) |s| {
                if (std.mem.eql(u8, name, s)) break :blk true;
            }
            break :blk false;
        },
        // A.8.4 `parameter_identifier [ constant_range_expression ]`: the base
        // has to name a §3.4.4 array PARAMETER, whose elements `param.zig`
        // scalarizes into `param_index` under `elemKey`'s `name[i]` spelling.
        .index => blk: {
            var base = e;
            while (ex.tag(base) == .index) {
                if (!isAnalysisOrConst(self, ex.rhs(base))) break :blk false;
                base = ex.lhs(base);
            }
            if (ex.tag(base) != .ident) break :blk false;
            const name = self.file.str(ex.strOf(base));
            const info = self.arrays.get(name) orelse break :blk false;
            var buf: [lower_shape.elem_key_len]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.writeAll(name) catch break :blk false;
            for (info.dims) |d| w.print("[{d}]", .{d.lo}) catch break :blk false;
            break :blk self.param_index.contains(w.buffered());
        },
        // Operators, A.8.4 `constant_analog_built_in_function_call` and
        // `constant_concatenation`: constant when every operand is.
        .unary, .binary, .range, .indexed_range, .multi_concat, .ternary, .builtin_call, .concat => blk: {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (!isAnalysisOrConst(self, c)) break :blk false;
            break :blk true;
        },
        // A.8.4 `nature_attribute_reference ::= net_identifier .
        // potential_or_flow . nature_attribute_identifier`: a nature's
        // attribute is fixed at declaration. Any other dotted name is a §6.8
        // hierarchical reference to something that can move.
        .hier_ident => blk: {
            const parts = ex.nameParts(e);
            if (parts.len != 3) break :blk false;
            break :blk self.file.strings.eql(parts[1], "potential") or self.file.strings.eql(parts[1], "flow");
        },
        // Probes, analog operators and small-signal sources are exactly what
        // moves between iterations; an assignment pattern and the event forms
        // are not A.8.4 primaries.
        //
        // A user function call stays out even with constant arguments: A.8.4's
        // `constant_analog_function_call` promises nothing about the body, which
        // may read `$abstime` (§9.10), and §4.5.15's test is "terms which can
        // not change their value during the course of a simulation".
        .call,
        .branch_access,
        .port_access,
        .filter_call,
        .noise_call,
        .assign_pattern,
        .pattern_repl,
        .event_or,
        .event_posedge,
        .event_negedge,
        .event_initial_step,
        .event_final_step,
        .event_function,
        .event_driver_update,
        => false,
    };
}

/// Reports whether lowered value `v` consists of §4.5.15 "terms which can not
/// change their value during the course of a simulation", by following its
/// dependences rather than its spelling, so `td = ptf * c * tf; if (td == 0.0)`
/// qualifies where `isAnalysisOrConst` refuses every variable.
///
/// Static leaves: literals, parameters (§3.4), and the calls `static_calls`
/// names. Dynamic: a §4.4 probe (`block_param`), the committed-state latches,
/// any other call (analog operators, `$abstime`, `$held_*` seeds, I/O, ...),
/// and a phi whose merge a dynamic branch decides.
///
/// ponytail: a phi is judged by every branch backward-reachable from its
/// incoming blocks, not only the ones between its dominator and itself, so a
/// solve-dependent `if` anywhere earlier in the block makes a later merge
/// dynamic even when it cannot decide it. Sound, and no worse than the
/// syntactic test it extends (which refuses every variable). Upgrade: control
/// dependence through the immediate dominator of the phi's block. A held
/// variable is dynamic even when every write to it is static, for the same
/// reason.
pub fn isStaticValue(self: *Lower, v: Mir.Value) Oom!bool {
    const st = &self.control_state;
    st.seen.clearRetainingCapacity();
    st.blocks.clearRetainingCapacity();
    st.stack.clearRetainingCapacity();
    return staticWalk(self, v, &st.seen, &st.blocks);
}

/// The calls whose value is fixed for the whole simulation: A.8.2's
/// `analysis()`, §9.15's `$temperature` and `$vt`, §9.18's six system
/// parameters, and the runtime array read (a pure selection over its operands).
const static_calls = std.StaticStringMap(void).initComptime(.{
    .{"analysis"},   .{"$temperature"}, .{"$vt"},    .{"$mfactor"}, .{"$xposition"},
    .{"$yposition"}, .{"$angle"},       .{"$hflip"}, .{"$vflip"},   .{"$idx"},
    .{"$idx$int"},   .{"$idx$str"},
});

fn staticWalk(
    self: *Lower,
    v0: Mir.Value,
    seen: *std.AutoHashMapUnmanaged(Mir.Value, void),
    blocks: *std.AutoHashMapUnmanaged(Mir.Block, void),
) Oom!bool {
    const v = self.mir.resolveAlias(v0);
    // A value already on the walk is being decided by the rest of it: a loop
    // phi reaching itself adds no dependence of its own.
    if ((try seen.getOrPut(self.arena, v)).found_existing) return true;
    const inst = switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => return true,
        .block_param => return false, // §4.4: an unknown of the solve
        .inst_result => |i| i,
    };
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            // Committed-solution latches: they move with every accepted step.
            if (u.op == .path_prev or u.op == .path_acc) return false;
            return staticWalk(self, u.operand, seen, blocks);
        },
        .binary => |b| return try staticWalk(self, b.lhs, seen, blocks) and
            try staticWalk(self, b.rhs, seen, blocks),
        .ternary => |t| return try staticWalk(self, t.cond, seen, blocks) and
            try staticWalk(self, t.then_val, seen, blocks) and
            try staticWalk(self, t.else_val, seen, blocks),
        .call => |c| {
            if (!static_calls.has(c.name)) return false;
            // `args` borrows the payload pool; the walk appends nothing to it.
            for (c.args) |a| if (!try staticWalk(self, a, seen, blocks)) return false;
            return true;
        },
        .phi => |p| {
            // An incomplete phi (unsealed loop header) has no operands yet.
            if (p.count == 0) return false;
            for (0..p.count) |k| {
                const pair = self.mir.phiPair(inst, @intCast(k));
                if (!try staticWalk(self, pair.value, seen, blocks)) return false;
                if (!try controlStatic(self, pair.block, seen, blocks)) return false;
            }
            return true;
        },
        .branch, .jump => return false,
        // §3.2.2 a fresh local array is static; a held one is dynamic, as a
        // held variable is. An element is static when its version and its
        // index are, and a version when everything stored into it is.
        .anew => |a| return self.out.mem_arrays.items[a.array].held == Lower.none_u32,
        .load => |l| return try staticWalk(self, l.arr, seen, blocks) and
            try staticWalk(self, l.index, seen, blocks),
        .store => |st| return try staticWalk(self, st.arr, seen, blocks) and
            try staticWalk(self, st.index, seen, blocks) and
            try staticWalk(self, st.value, seen, blocks),
    }
}

/// Reports whether every branch that can decide whether control reaches `from` has
/// a static condition. Walks predecessors to the entry; see `isStaticValue` for the
/// over-approximation.
fn controlStatic(
    self: *Lower,
    from: Mir.Block,
    seen: *std.AutoHashMapUnmanaged(Mir.Value, void),
    blocks: *std.AutoHashMapUnmanaged(Mir.Block, void),
) Oom!bool {
    // A nested walk (a phi met while judging a branch) works above `base` and
    // leaves the stack there on success; a `false` unwinds every walk at once.
    const stack = &self.control_state.stack;
    const base = stack.items.len;
    try stack.append(self.arena, from);
    const b = &self.builder;
    while (stack.items.len > base) {
        const blk = stack.pop().?;
        if ((try blocks.getOrPut(self.arena, blk)).found_existing) continue;
        const i = @backingInt(blk);
        // Unsealed: more predecessors may still arrive (a loop's back edge).
        if (i >= b.block_state.len or !b.block_state.items(.sealed)[i]) return false;
        const last = self.mir.blockLast(blk);
        if (last != .none and self.mir.instOp(last) == .branch) {
            if (!try staticWalk(self, self.mir.instData(last).branch.cond, seen, blocks)) return false;
        }
        var node = b.block_state.items(.preds_head)[i];
        for (0..b.block_state.items(.preds_len)[i]) |_| {
            try stack.append(self.arena, b.pred_pool.items[node].block);
            node = b.pred_pool.items[node].next;
        }
    }
    return true;
}

/// Lowers `if (cond) then_s else else_s` over an already lowered condition as a
/// runtime diamond; `static` is as for `lowerGuarded`.
pub fn lowerBranchStmt(
    self: *Lower,
    cond: Mir.Value,
    then_s: Ast.StmtId,
    else_s: Ast.StmtId,
    static: bool,
    /// The source condition of an `if`, for §9.20's parameter-chosen alias
    /// (`lower_hier_name.pushCond`); `.none` for a guard the compiler made.
    ast_cond: Ast.ExprId,
) Oom!void {
    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);

    try self.branchTo(cond, then_b, else_b, true);

    const src = ast_cond != .none;
    const pure = src and isAnalysisOrConst(self, ast_cond);
    self.cur = then_b;
    if (src) try lower_hier_name.pushCond(self, .{ .e = ast_cond, .pol = true, .pure = pure });
    try lowerCondBody(self, then_s, static);
    if (src) lower_hier_name.popCond(self);
    try self.gotoBlock(join);

    self.cur = else_b;
    if (src) try lower_hier_name.pushCond(self, .{ .e = ast_cond, .pol = false, .pure = pure });
    try lowerCondBody(self, else_s, static);
    if (src) lower_hier_name.popCond(self);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// Lowers a §5.8.3 case as its equality chain: the first matching arm wins and
/// `default` is the final else. `casex`/`casez` (§7.3.2) differ only in the
/// don't-care bits a four-state side brings (`lower_expr.caseMatch`).
pub fn lowerCase(
    self: *Lower,
    tok: u32,
    kind: Ast.CaseKind,
    scrutinee: Ast.ExprId,
    arms: []const Ast.CaseArm,
) Oom!void {
    const sv = try lower_expr.lowerExpr(self, scrutinee);
    var default_arm: Ast.StmtId = .none;
    var defaults: usize = 0;
    for (arms) |a| {
        if (a.labels.len != 0) continue;
        defaults += 1;
        default_arm = a.body;
    }
    // §5.8.3: "The default statement is optional. Use of multiple default
    // statements in one case statement is illegal." Reported once; lowering
    // carries on with the last one so later mistakes are still reported.
    if (defaults > 1) {
        try self.err(tok, .E0427, "{d} `default` arms", .{defaults});
    }
    // §5.8.1 applies to `case` word for word: the arm LABELS are constants by
    // A.6.7, so whether an arm is decided before the solve turns entirely on
    // the scrutinee.
    // §7.3.2 a four-state subject or an x/z label compares both planes, as
    // `===` does (IEEE 1364 §9.5: `case` is case equality).
    const ex = &self.file.exprs;
    var four = ex.tag(scrutinee) == .ident and self.out.discrete_xz.contains(self.file.str(ex.strOf(scrutinee)));
    for (arms) |a| for (a.labels) |l| if (ex.tag(l) == .logic_literal) {
        four = true;
    };
    try lowerCaseChain(self, sv, scrutinee, if (four) scrutinee else null, kind, arms, default_arm, isAnalysisOrConst(self, scrutinee) or try isStaticValue(self, sv.v));
}

fn lowerCaseChain(
    self: *Lower,
    sv: TypedValue,
    /// The source subject, for §9.20's parameter-chosen alias (`pushCond`).
    subject: Ast.ExprId,
    four_state: ?Ast.ExprId,
    kind: Ast.CaseKind,
    arms: []const Ast.CaseArm,
    default_arm: Ast.StmtId,
    static: bool,
) Oom!void {
    if (arms.len == 0) return lower_stmt.lowerStmt(self, default_arm);
    const a = arms[0];
    if (a.labels.len == 0) return lowerCaseChain(self, sv, subject, four_state, kind, arms[1..], default_arm, static);

    // §5.8.3 an arm with several labels matches any of them.
    var cond: ?Mir.Value = null;
    for (a.labels) |l| {
        const eq = if (four_state) |fs|
            (try lower_expr.caseMatch(self, kind, fs, l)) orelse try lower_expr.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l))
        else
            try lower_expr.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l));
        cond = if (cond) |c| try self.emit(.logor, &.{ c, eq }) else eq;
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(cond.?, then_b, else_b, true);

    const pure = isAnalysisOrConst(self, subject);
    self.cur = then_b;
    try lower_hier_name.pushCond(self, .{ .e = subject, .labels = a.labels, .pol = true, .pure = pure });
    try lowerCondBody(self, a.body, static);
    lower_hier_name.popCond(self);
    try self.gotoBlock(join);

    self.cur = else_b;
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    try lower_hier_name.pushCond(self, .{ .e = subject, .labels = a.labels, .pol = false, .pure = pure });
    try lowerCaseChain(self, sv, subject, four_state, kind, arms[1..], default_arm, static);
    lower_hier_name.popCond(self);
    self.static_cond_depth -= @intFromBool(static);
    self.cond_depth -= 1;
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// Lowers a §5.9.1 `while` loop. The header is sealed only after the back edge (Braun SSA).
pub fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header`: a §4.2.7 short-circuit or `?:` in the condition
    // splits it across blocks and leaves `cur` at the join, and `header` already
    // ends in that split's branch.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = header });
    self.cur = body_b;
    try lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(header);
    _ = self.loops.pop();

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Lowers a §5.9 `repeat (n)` loop as an integer countdown.
pub fn lowerRepeat(self: *Lower, count: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const n = try self.toInt(try lower_expr.lowerExpr(self, count));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, n);

    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const i = try self.builder.readVariable(place, header);
    const c = try self.emit(.igt, &.{ i, .zero });
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    _ = self.loops.pop();

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    const cur_i = try self.builder.readVariable(place, step_b);
    try self.builder.writeVariable(place, step_b, try self.emit(.isub, &.{ cur_i, .one }));
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Lowers a §5.9.2 `for` loop. A genvar loop (§3.5) is unrolled instead (§6.6.1),
/// which is what makes `genvar`-indexed nets work.
pub fn lowerFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!void {
    if (try tryUnrollFor(self, init_s, cond, step, body)) return;

    try lower_stmt.lowerStmt(self, init_s);
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header` (see `lowerWhile`): the condition may have been
    // split across blocks by a short-circuit, and the branch belongs at its end.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try lowerCondBody(self, body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    _ = self.loops.pop();

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    try lower_stmt.lowerStmt(self, step);
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Bound on §6.6.1 unrolling: a runaway genvar loop is a source bug, not a
/// reason to emit a million instructions.
const max_unroll: u32 = 4096;

/// §3.5/§6.6.1 genvar loop-generate. Returns false when this is an ordinary
/// procedural `for` (which `lowerFor` then lowers as a CFG loop). The bounds
/// fold with `shapeEval`: a parameter in them fixes how many copies of the body
/// exist, so it is a §3.4 shape parameter like an array bound.
fn tryUnrollFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!bool {
    const gv = genvarOf(self, init_s) orelse return false;
    // §6.6.1 "Both the initialization and iteration assignments shall assign
    // to the same genvar": a property of the text, so judged before any trip
    // (a zero-trip loop never evaluates its step). E0419's explain owns it.
    if (step != .none and self.file.stmt(step) == .assign) {
        const t = self.file.stmt(step).assign.target;
        const name = if (self.file.exprs.tag(t) == .ident) self.file.str(self.file.exprs.strOf(t)) else "";
        if (!std.mem.eql(u8, name, gv)) {
            try self.err(self.file.exprs.mainTok(t), .E0419, "the iteration assigns `{s}`, and the initialization the genvar `{s}`: both shall assign the same genvar", .{ name, gv });
            return true;
        }
    }
    const init_v = assignValueOf(self, init_s).?;
    const start = lower_constfold.shapeEval(self, init_v) orelse {
        if (unknownLiteral(self, init_v)) |lit|
            try self.err(self.file.exprs.mainTok(lit), .E0486, "the initialization sets the genvar `{s}`", .{gv})
        else
            try self.err(self.file.exprs.mainTok(cond), .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    try self.consts.put(self.arena, gv, start);
    // Visible to `queueDisplay`'s snapshot while the body lowers.
    try self.active_genvars.append(self.arena, gv);
    defer _ = self.active_genvars.pop();
    // §5.11: a `break`/`continue` that reaches this loop first is E0440.
    const saved_base = self.analog_for_base;
    self.analog_for_base = self.loops.items.len;
    defer self.analog_for_base = saved_base;

    var n: u32 = 0;
    while (n < max_unroll) : (n += 1) {
        const c = lower_constfold.shapeEval(self, cond) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        // §6.6.1 a loop generate's block is `name[i]` in §9.15's "path".
        if (body != .none and self.file.stmt(body) == .block and self.file.stmt(body).block.gen_name != .none)
            self.gen_iter = if (self.consts.get(gv)) |v| v.asInt() else null;
        try lower_stmt.lowerStmt(self, body);
        const step_v = assignValueOf(self, step) orelse .none;
        const next = lower_constfold.shapeEval(self, step_v) orelse {
            if (unknownLiteral(self, step_v)) |lit|
                try self.err(self.file.exprs.mainTok(lit), .E0486, "the iteration sets the genvar `{s}`", .{gv})
            else
                try self.err(self.file.exprs.mainTok(cond), .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    if (n == max_unroll) try loopBeyondCap(self, gv, cond, step);
    _ = self.consts.remove(gv);
    return true;
}

/// Iterations `loopBeyondCap` follows a loop's scheme alone, body unlowered,
/// to tell a long loop from one that never ends.
const max_probe: u32 = 1 << 20;

/// The body has been unrolled `max_unroll` times. The scheme alone (§6.6.1's
/// condition and step, which fold without the body) decides what that means:
/// it may end right here (exactly `max_unroll` iterations, legal); end later
/// (E0485, the engine's limit and not a language rule); or never end, which
/// a genvar value that repeats proves outright and a scheme still running
/// after `max_probe` iterations is taken to mean (E0420, §6.6.1's error).
fn loopBeyondCap(self: *Lower, gv: []const u8, cond: Ast.ExprId, step: Ast.StmtId) Oom!void {
    const tok = self.file.exprs.mainTok(cond);
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    var k: u32 = max_unroll;
    while (k < max_unroll + max_probe) : (k += 1) {
        const c = lower_constfold.shapeEval(self, cond) orelse return;
        if (!c.isTrue()) {
            if (k != max_unroll)
                try self.err(tok, .E0485, "it runs {d} iterations; at most {d} are unrolled", .{ k, max_unroll });
            return;
        }
        const v = (self.consts.get(gv) orelse return).asInt();
        if ((try seen.getOrPut(self.arena, v)).found_existing) {
            try self.err(tok, .E0420, "`{s}` repeats the value {d}", .{ gv, v });
            return;
        }
        const next = lower_constfold.shapeEval(self, assignValueOf(self, step) orelse .none) orelse return;
        try self.consts.put(self.arena, gv, next);
    }
    try self.err(tok, .E0420, "still running after {d} iterations", .{max_unroll + max_probe});
}

/// Returns the genvar a `for` init statement assigns, or null (LRM §3.5).
fn genvarOf(self: *const Lower, init_s: Ast.StmtId) ?[]const u8 {
    const m = self.out.module orelse return null;
    if (init_s == .none) return null;
    const s = self.file.stmt(init_s);
    if (s != .assign) return null;
    const t = s.assign.target;
    if (self.file.exprs.tag(t) != .ident) return null;
    const name_id = self.file.exprs.strOf(t);
    for (m.genvars) |g| if (g == name_id) return self.file.str(name_id);
    return null;
}

/// §6.6.1 "It shall be an error if any bit of the genvar is set to x or z":
/// the first literal under `e` with an x or z bit, which is what keeps a
/// genvar assignment's value from folding. `markDiscreteExprs` exempts these
/// literals from E0130, since the scheme is folded, never executed.
fn unknownLiteral(self: *const Lower, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .logic_literal) return if (ex.logicValue(e).hasUnknown()) e else null;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (unknownLiteral(self, c)) |hit| return hit;
    return null;
}

fn assignValueOf(self: *const Lower, s: Ast.StmtId) ?Ast.ExprId {
    if (s == .none) return null;
    const st = self.file.stmt(s);
    return if (st == .assign) st.assign.value else null;
}
