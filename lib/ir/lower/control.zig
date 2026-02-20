//! §5.8 conditionals and §5.9 loops.
//!
//! In: if/case/for/while/repeat AST. Out: MIR control flow (blocks, branches, phis).
//!
//! LRM clauses this file's code cites: §3.5, §4.2.7, §5.6.7, §5.8, §5.8.1, §5.8.3, §5.9, §5.9.1, §5.9.2, §6.6, §6.6.1, §6.6.2.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_control.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const lower_stmt = @import("stmt.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;
const gotoBlock = Lower.gotoBlock;
const branchTo = Lower.branchTo;
const toInt = Lower.toInt;
const toBool = Lower.toBool;

// ---------------------------------------------------------------------------
// Class 4 — control flow (LRM §5.8, §5.9)
// ---------------------------------------------------------------------------

/// §6.6: "All expressions in generate schemes shall be constant expressions,
/// deterministic at elaboration time." The scheme of an if-generate is its
/// condition and of a case-generate its selector; the loop generate's three
/// parts are E0417-E0419, judged in `tryUnrollFor` where the unroll needs them.
///
/// `constEval`, NOT `foldExpr(..., false)`: a `parameter` is a `constant_primary` (A.8.4)
/// and §6.6's stated purpose is "the ability for parameter values to affect the
/// structure of the model", so a parameterized scheme is exactly what the clause
/// is for. What it excludes is a module variable or anything reading the
/// solution — the things `constEval` returns null for.
///
/// Reported and then lowered anyway: a scheme VerA cannot fold is still lowered
/// as the §5.8 runtime branch it looks like, so a second mistake inside the
/// selected arm is reported in the same run.
///
/// ponytail: a scheme this accepts is not necessarily FOLDED. `foldExpr(..., false)` keeps
/// refusing a parameter on purpose — folding it to its declared default would
/// compile the arm the model card did not ask for — so a parameterized generate
/// becomes a runtime diamond over both arms instead of one elaborated arm. Same
/// behavior, different structure, and nothing VerA emits can observe the
/// difference until §6.6.1's per-instance declarations exist.
pub fn checkGenScheme(self: *Lower, tok: u32, scheme: Ast.ExprId) Oom!void {
    if (lower_constfold.constEval(self, scheme) != null) return;
    var b = self.errWith(tok, .E0428);
    b.help("a generate scheme may read parameters and genvars, not variables", .{});
    try b.emit();
}

/// §5.8 conditional. A constant-foldable condition lowers only the taken arm —
/// that is also what makes `generate if` (§6.6.2) collapse at elaboration.
pub fn lowerIf(self: *Lower, cond: Ast.ExprId, then_s: Ast.StmtId, else_s: Ast.StmtId) Oom!void {
    if (lower_constfold.foldExpr(self, cond, false)) |c| {
        return lower_stmt.lowerStmt(self, if (c.isTrue()) then_s else else_s);
    }
    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    try lowerBranchStmt(self, c, then_s, else_s, isAnalysisOrConst(self, cond));
}

/// Lower a body that only runs under a RUNTIME condition. The wrapper carries
/// §5.6.7's ban on indirect contributions in a non-constant conditional or loop
/// and §5.8.1/§5.9's ban on analog operators in one; the constant-folded paths
/// (`lowerIf`'s fold, `tryUnrollFor`) call `lowerStmt` directly and are
/// therefore unrestricted, which is exactly the "unless the conditional
/// expression is a constant expression" carve-out.
///
/// `static` is the WEAKER §5.8.1 carve-out — an `analysis_or_constant_expression`
/// rather than a constant one. It relaxes E0514 alone; `cond_depth` still rises,
/// so the two constant-only rules keep rejecting the same code they did.
pub fn lowerCondBody(self: *Lower, body: Ast.StmtId, static: bool) Oom!void {
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }
    try lower_stmt.lowerStmt(self, body);
}

/// A.8.3 `analysis_or_constant_expression` — the §5.8.1 carve-out. True when
/// nothing in the tree can change between one Newton iteration and the next:
/// literals, `parameter`s and `analysis()` calls, combined with operators.
///
/// Deliberately NOT `foldExpr(..., false)`: that folds to a VALUE and refuses a parameter
/// on purpose (a model card overrides it), while this asks the different
/// question of whether the value is fixed for the whole analysis. A parameter
/// is `constant_primary` in A.8.4 and cannot move mid-solve, so it qualifies.
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
        .unary => isAnalysisOrConst(self, ex.lhs(e)),
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
            var buf: [lower_param.elem_key_len]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.writeAll(name) catch break :blk false;
            for (info.dims) |d| w.print("[{d}]", .{d.lo}) catch break :blk false;
            break :blk self.param_index.contains(w.buffered());
        },
        .binary, .range, .multi_concat => isAnalysisOrConst(self, ex.lhs(e)) and isAnalysisOrConst(self, ex.rhs(e)),
        .ternary => isAnalysisOrConst(self, ex.lhs(e)) and
            isAnalysisOrConst(self, ex.rhs(e)) and
            isAnalysisOrConst(self, ex.ternaryElse(e)),
        // A.8.4 `constant_analog_built_in_function_call` and
        // `constant_concatenation`: constant when every operand is.
        .builtin_call, .concat => for (ex.args(e)) |a| {
            if (!isAnalysisOrConst(self, a)) break false;
        } else true,
        // A.8.4 `nature_attribute_reference ::= net_identifier .
        // potential_or_flow . nature_attribute_identifier` — a nature's
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
        // `constant_analog_function_call` promises nothing about the BODY, which
        // may read `$abstime` (§9.10), and §4.5.15's test is "terms which can
        // not change their value during the course of a simulation".
        .call,
        .branch_access,
        .port_access,
        .filter_call,
        .noise_call,
        .assign_pattern,
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

pub fn lowerBranchStmt(
    self: *Lower,
    cond: Mir.Value,
    then_s: Ast.StmtId,
    else_s: Ast.StmtId,
    static: bool,
) Oom!void {
    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);

    try self.branchTo(cond, then_b, else_b, true);

    self.cur = then_b;
    try lowerCondBody(self, then_s, static);
    try self.gotoBlock(join);

    self.cur = else_b;
    try lowerCondBody(self, else_s, static);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §5.8.3 case — lowered as the equality chain the LRM defines it to be: the
/// first matching arm wins, `default` is the final else. `casex`/`casez` have
/// no meaning for a real scrutinee (annex C).
pub fn lowerCase(
    self: *Lower,
    tok: u32,
    kind: Ast.CaseKind,
    scrutinee: Ast.ExprId,
    arms: []const Ast.CaseArm,
) Oom!void {
    if (kind != .normal) {
        var b = self.errWith(tok, .E0416);
        b.help("use `case`", .{});
        try b.emit();
        return;
    }
    const sv = try lower_expr.lowerExpr(self, scrutinee);
    var default_arm: Ast.StmtId = .none;
    var defaults: usize = 0;
    for (arms) |a| {
        if (a.labels.len != 0) continue;
        defaults += 1;
        default_arm = a.body;
    }
    // §5.8.3: "The default statement is optional. Use of multiple default
    // statements in one case statement is illegal." Nothing in the clause
    // orders them, so a second one leaves the fall-through arm ambiguous —
    // which is why this is a well-formedness rule and not a preference.
    // Reported once for the statement, and lowering carries on with the last
    // one so a second, unrelated mistake in the same case is still reported.
    if (defaults > 1) {
        var b = self.errWith(tok, .E0427);
        b.msg("{d} `default` arms", .{defaults});
        try b.emit();
    }
    // §5.8.1 applies to `case` word for word: the arm LABELS are constants by
    // A.6.7, so whether an arm is decided before the solve turns entirely on
    // the scrutinee.
    try lowerCaseChain(self, sv, arms, default_arm, isAnalysisOrConst(self, scrutinee));
}

pub fn lowerCaseChain(
    self: *Lower,
    sv: TypedValue,
    arms: []const Ast.CaseArm,
    default_arm: Ast.StmtId,
    static: bool,
) Oom!void {
    if (arms.len == 0) return lower_stmt.lowerStmt(self, default_arm);
    const a = arms[0];
    if (a.labels.len == 0) return lowerCaseChain(self, sv, arms[1..], default_arm, static);

    // §5.8.3 an arm with several labels matches any of them.
    var cond: ?Mir.Value = null;
    for (a.labels) |l| {
        const eq = try lower_expr.cmp(self, .eq, sv, try lower_expr.lowerExpr(self, l));
        cond = if (cond) |c| try self.emit(.logor, &.{ c, eq }) else eq;
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(cond.?, then_b, else_b, true);

    self.cur = then_b;
    try lowerCondBody(self, a.body, static);
    try self.gotoBlock(join);

    self.cur = else_b;
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    try lowerCaseChain(self, sv, arms[1..], default_arm, static);
    self.static_cond_depth -= @intFromBool(static);
    self.cond_depth -= 1;
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §5.9.1 `while`. Braun order: the header is sealed only after the back edge.
pub fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try lower_expr.lowerExpr(self, cond));
    const body_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, NOT `header`: a §4.2.7 short-circuit (`while (i<=4 && f(x))`)
    // splits the condition across blocks of its own and leaves `cur` at the
    // join. Branching from `header` regardless appended a SECOND terminator to
    // a block that already ended in the `&&`'s branch — the join and the rhs
    // block then had no predecessor, codegen never emitted them, and the loop
    // branched on a temporary nothing ever assigned. Same hazard as `?:` in a
    // condition. Pinned by codegen.zig's test "§5.9.1 a short-circuit loop
    // condition still reaches the loop's branch".
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

/// §5.9 `repeat (n)` — the LRM's counted loop, lowered as an integer countdown.
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

/// §5.9.2 `for`. If the loop variable is a genvar (§3.5) the whole loop is
/// unrolled at elaboration (§6.6.1) — that is the only form allowed to appear
/// in a generate region, and it is what makes `genvar`-indexed nets work.
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
    // `self.cur`, not `header` — see `lowerWhile`: the condition may have been
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
pub const max_unroll: u32 = 4096;

/// §3.5/§6.6.1 genvar loop-generate. Returns false when this is an ordinary
/// procedural `for` (which `lowerFor` then lowers as a CFG loop).
pub fn tryUnrollFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!bool {
    const gv = genvarOf(self, init_s) orelse return false;
    const start = lower_constfold.constEval(self, assignValueOf(self, init_s).?) orelse {
        try self.err(self.file.exprs.mainTok(cond), .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    try self.consts.put(self.arena, gv, start);
    // Visible to `queueDisplay`'s snapshot while the body lowers.
    try self.active_genvars.append(self.arena, gv);
    defer _ = self.active_genvars.pop();

    var n: u32 = 0;
    while (n < max_unroll) : (n += 1) {
        const c = lower_constfold.constEval(self, cond) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        try lower_stmt.lowerStmt(self, body);
        const next = lower_constfold.constEval(self, assignValueOf(self, step) orelse .none) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    if (n == max_unroll)
        try self.err(self.file.exprs.mainTok(cond), .E0420, "gave up after {d} iterations", .{max_unroll});
    _ = self.consts.remove(gv);
    return true;
}

/// The genvar assigned by a `for` init statement, if any (§3.5).
pub fn genvarOf(self: *const Lower, init_s: Ast.StmtId) ?[]const u8 {
    const m = self.module orelse return null;
    if (init_s == .none) return null;
    const s = self.file.stmt(init_s);
    if (s != .assign) return null;
    const t = s.assign.target;
    if (self.file.exprs.tag(t) != .ident) return null;
    const name_id = self.file.exprs.strOf(t);
    for (m.genvars) |g| if (g == name_id) return self.file.str(name_id);
    return null;
}

pub fn assignValueOf(self: *const Lower, s: Ast.StmtId) ?Ast.ExprId {
    if (s == .none) return null;
    const st = self.file.stmt(s);
    return if (st == .assign) st.assign.value else null;
}
