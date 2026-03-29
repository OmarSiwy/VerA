//! §4.7 user-defined analog functions.
//!
//! In: function declarations and call sites. Out: inlined MIR at each call (recursion refused).
//!
//! LRM clauses this file's code cites: §3.2, §4.7, §4.7.1, §4.7.2, §4.7.2.3, §4.7.2.4, §4.7.3, §5.11, §6.8, §7.3.7, §9.17.3.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_func.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_limit = @import("limit.zig");
const lower_param = @import("param.zig");
const lower_stmt = @import("stmt.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const VarSlot = Lower.VarSlot;
const init = Lower.init;
const tokenSpan = Lower.tokenSpan;
const err = Lower.err;
const errWith = Lower.errWith;
const poison = Lower.poison;
const emit = Lower.emit;
const call = Lower.call;
const gotoBlock = Lower.gotoBlock;
const toReal = Lower.toReal;
const toInt = Lower.toInt;
const astTy = Lower.astTy;

// ---------------------------------------------------------------------------
// Class 9 — user-defined analog functions (LRM §4.7)
// ---------------------------------------------------------------------------

/// §4.7.3: "An analog user-defined function ... shall not call itself directly
/// or indirectly, i.e., recursive functions are not permitted."
///
/// The sentence constrains the FUNCTION, so the check cannot be left to
/// `inlineUserFuncPre`'s inline stack: that one only fires when the analog block
/// actually reaches the call, which makes an illegal declaration legal as long
/// as nobody calls it — and it is precisely the declarations that cannot be
/// compiled, since §4.7.2 inlining has no call ABI to fall back on.
///
/// The call graph is tiny (functions are per-module and hand-written), so this
/// is a reachability walk per function rather than an SCC pass; both report the
/// same set, and this one names every function that sits on a cycle.
pub fn checkFuncRecursion(self: *Lower, fns: []const Ast.FuncDecl) Oom!void {
    if (fns.len == 0) return;
    const edges = try self.arena.alloc(std.ArrayList(u32), fns.len);
    for (fns, edges) |*fd, *out| {
        out.* = .empty;
        try scanCallSites(self, fd.body, false, fns, out);
    }

    const seen = try self.arena.alloc(bool, fns.len);
    var stack: std.ArrayList(u32) = .empty;
    for (fns, 0..) |*fd, i| {
        @memset(seen, false);
        stack.clearRetainingCapacity();
        try stack.append(self.arena, @intCast(i));
        while (stack.pop()) |j| {
            for (edges[j].items) |k| {
                if (k == i) { // back at the start ⇒ `fd` calls itself, however far around
                    try self.err(fd.main_tok, .E0510, "`{s}`", .{self.file.str(fd.name)});
                    stack.clearRetainingCapacity();
                    break;
                }
                if (seen[k]) continue;
                seen[k] = true;
                try stack.append(self.arena, k);
            }
        }
    }
}

/// With `limits`, §9.17.3 mints one state slot per ACCESS FUNCTION reached by a
/// user-function `$limit`, in source order, seeded in the entry block.
/// `LimitSlot`'s header says why the key is the access function, not the call site.
/// Otherwise collect the §4.7 functions the statement calls, as indices into `fns`.
/// A name that is not a declared function is not an edge — `lowerUserCall`
/// reports it (E0512) when the call is reached.
pub fn scanCallSites(
    self: *Lower,
    id: Ast.StmtId,
    comptime limits: bool,
    fns: if (limits) void else []const Ast.FuncDecl,
    out: if (limits) void else *std.ArrayList(u32),
) Oom!void {
    if (id == .none) return;
    // Every edge of the statement (`SourceFile.stmtEdges`): a `$limit` or a
    // call is a site wherever it is written, a for-loop's init and step, a
    // case label, a repeat count and an event expression included.
    const Walk = struct {
        l: *Lower,
        fns: if (limits) void else []const Ast.FuncDecl,
        out: if (limits) void else *std.ArrayList(u32),
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            try scanCallSitesExpr(w.l, e, limits, w.fns, w.out);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try scanCallSites(w.l, s, limits, w.fns, w.out);
        }
    };
    try self.file.stmtEdges(id, Walk{ .l = self, .fns = fns, .out = out });
}

pub fn scanCallSitesExpr(
    self: *Lower,
    e: Ast.ExprId,
    comptime limits: bool,
    fns: if (limits) void else []const Ast.FuncDecl,
    out: if (limits) void else *std.ArrayList(u32),
) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (limits) {
        if (tag == .sys_call and std.mem.eql(u8, self.file.str(ex.strOf(e)), "$limit")) {
            const args = if (ex.extraOf(e) < ex.pool.items.len) ex.args(e) else &[_]Ast.ExprId{};
            if (args.len >= 2) {
                if (lower_limit.limitUserFunc(self, args[1]) != null) try lower_limit.addLimitSlot(self, args[0]);
            }
        }
    } else if (tag == .call) {
        // StrIds are interned, so identity IS name equality (`natureOf` relies
        // on the same thing).
        for (fns, 0..) |*fd, k| if (fd.name == ex.strOf(e)) {
            try out.append(self.arena, @intCast(k));
            break;
        };
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try scanCallSitesExpr(self, c, limits, fns, out);
}

pub fn lowerUserCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const m = self.out.module orelse return poison;
    for (m.functions) |*fd| {
        if (!std.mem.eql(u8, self.file.str(fd.name), name)) continue;
        // §7.3.7's first sentence, the mirror of E0430's second: "Digital
        // functions cannot be called from within the analog context." The
        // declaration is legal (§4.7 admits both kinds); it is the CALL that
        // crosses, so the diagnostic lands here and not on the keyword.
        // Lowered anyway afterwards, so one refused call does not turn every
        // use of its result into a second, derived complaint.
        if (!fd.is_analog) {
            var b = self.errWith(ex.mainTok(e), .E0436);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(fd.main_tok), "`{s}` is declared here, without `analog`", .{name});
            try b.emit();
        }
        return inlineUserFuncPre(self, fd, &.{}, ex.args(e), e);
    }
    // vpi_* and every other unresolved name lands here.
    try lower_expr.unknownCall(self, e, name);
    return poison;
}

/// LRM §4.7.3/§4.7.2 — analog functions are INLINED (§4.7.1 forbids
/// recursion, and there is no call ABI in the generated device).
///
/// §4.7.1 isolation: the body sees only its own arguments and locals, never
/// module variables — implemented by swapping in a fresh scope.
/// §4.7.2.3/§4.7.2.4: `output`/`inout` arguments are written back to the
/// caller's lvalue after the body runs.
///
/// Leading formals can bind to values the CALLER already has rather than to
/// source expressions. §9.17.3's `$limit` supplies these leading values: the
/// simulator supplies `vnew` and `vold` itself and the source only writes the
/// tail. `pre` fills `fd.args[0..pre.len]`, `arg_exprs` the rest.
pub fn inlineUserFuncPre(
    self: *Lower,
    fd: *const Ast.FuncDecl,
    pre: []const Mir.Value,
    arg_exprs: []const Ast.ExprId,
    site: Ast.ExprId,
) Oom!TypedValue {
    const name = self.file.str(fd.name);
    for (self.inlining.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            try self.err(self.file.exprs.mainTok(site), .E0510, "`{s}`", .{name});
            return poison;
        }
    }
    if (pre.len + arg_exprs.len != fd.args.len) {
        try self.err(self.file.exprs.mainTok(site), .E0511, "`{s}()` takes {d}, got {d}", .{
            name, fd.args.len, pre.len + arg_exprs.len,
        });
        return poison;
    }

    // Actuals are evaluated in the CALLER's scope, before it is swapped out.
    // An ARRAY formal (§4.7.2.3) takes one Value per element — the formal is
    // scalarized inside the function exactly as a §3.2 array is anywhere else,
    // so the pass is element-wise in both directions.
    var actuals: std.ArrayList([]const Mir.Value) = .empty;
    defer actuals.deinit(self.arena);
    for (fd.args, 0..) |formal, fi| {
        const ty = astTy(formal.ty);
        // §9.17.3's simulator-supplied leading formals: already a value, and
        // already checked `input` by the caller, so neither the array nor the
        // output arm below can apply to one.
        if (fi < pre.len) {
            try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{switch (ty) {
                .real => try self.toReal(.{ .v = pre[fi], .ty = .real }),
                .integer => try self.toInt(.{ .v = pre[fi], .ty = .real }),
                .string => pre[fi],
            }}));
            continue;
        }
        const actual = arg_exprs[fi - pre.len];
        if (formal.dims.len != 0) {
            // §4.7.2.3 formal bounds fold in the caller's scope: they may name
            // a module parameter.
            const dims = try lower_param.dimsBounds(self, formal.dims, formal.main_tok, self.file.str(formal.name)) orelse return poison;
            const n = lower_param.shapeCells(dims);
            const vals = try self.arena.alloc(Mir.Value, n);
            // §4.7.2.3: "All output arguments ... are initialized, zero (0) if
            // numeric, which in turn means that the argument passed to it is
            // reset to zero." An `inout` is NOT (§4.7.2.4 copies in). The
            // shape rule binds an `output` all the same: nothing is copied in,
            // but `funcArrayOut` copies n values back into the actual.
            const shaped = if (formal.direction == .output) blk: {
                @memset(vals, lower_param.zeroOf(ty));
                break :blk try arrayActualCells(self, actual) == n;
            } else try funcArrayIn(self, actual, ty, vals);
            if (!shaped) {
                try self.err(self.file.exprs.mainTok(actual), .E0511, "`{s}()` argument `{s}` needs {d} elements", .{
                    name, self.file.str(formal.name), n,
                });
                return poison;
            }
            try actuals.append(self.arena, vals);
            continue;
        }
        if (formal.direction == .output) {
            try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{lower_param.zeroOf(ty)}));
            continue;
        }
        const tv = try lower_expr.lowerExpr(self, actual);
        try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{switch (ty) {
            .real => try self.toReal(tv),
            .integer => try self.toInt(tv),
            .string => tv.v,
        }}));
    }

    // ---- enter the function scope (§4.7.1) ----
    const saved_vars = self.vars;
    const saved_arrays = self.arrays;
    const saved_ret = self.ret;
    const saved_restrict = self.restrict;
    // MASKED, not merely marked: the body is inlined into the caller's CFG, so
    // without a fresh stack a `break` in a function whose own loops are all
    // closed bound the loop the CALL SITE sits in and silently exited it — a
    // caller-scope capture the same §4.7.1 isolation that swaps `vars` forbids.
    // With the stack empty, `lowerJump` reports the §5.11 "only be used in a
    // loop" E0404 exactly as it does for a bare module-level `break`, and a
    // loop INSIDE the body still pushes and binds normally.
    const saved_loops = self.loops;
    const saved_func_params = self.func_params;
    const log_mark = self.scope_log.items.len;
    self.vars = .empty;
    self.arrays = .empty;
    self.loops = .empty;
    self.restrict = "an analog function";
    try self.inlining.append(self.arena, name);

    // §4.7.2 local parameters fold to constants; they never reach the Model.
    // The DECL LIST is installed as `func_params` so `lookupName` masks a
    // module parameter of the same name for the body's duration (§6.8) —
    // swapped per call like `vars`, so a callee never sees its caller's
    // locals (§4.7.1 isolation).
    self.func_params = fd.params;
    // `consts` is shared with the caller, and §4.7.1 lets the body see only
    // "locally-defined parameters and module-level parameters" of what it
    // holds. So for the body's duration the caller's genvars are taken out
    // (a genvar is neither), and a local parameter's fold replaces a module
    // parameter's of the same name; `shadowed` records every entry touched,
    // and the exit below puts each one back. Without it a local `N` stayed
    // the module's `N` for every constant fold after the call.
    var shadowed: std.ArrayList(struct { name: []const u8, prev: ?Const }) = .empty;
    defer shadowed.deinit(self.arena);
    const saved_genvars = self.active_genvars;
    self.active_genvars = .empty;
    for (saved_genvars.items) |g| {
        const prev = self.consts.fetchRemove(g) orelse continue;
        try shadowed.append(self.arena, .{ .name = g, .prev = prev.value });
    }
    for (fd.params) |*p| {
        const c = lower_constfold.constEval(self, p.default) orelse continue;
        const pname = self.file.str(p.name);
        try shadowed.append(self.arena, .{ .name = pname, .prev = self.consts.get(pname) });
        try self.consts.put(self.arena, pname, c);
    }

    const ret_ty = astTy(fd.ret_ty);
    const ret_slot = try lower_param.declareVar(self, name, ret_ty); // §4.7.1 return variable
    try self.builder.writeVariable(ret_slot.place, self.cur, lower_param.zeroOf(ret_ty));

    var arg_slots: std.ArrayList([]const VarSlot) = .empty;
    defer arg_slots.deinit(self.arena);
    for (fd.args, actuals.items) |formal, vals| {
        const fname = self.file.str(formal.name);
        const ty = astTy(formal.ty);
        if (formal.dims.len != 0) {
            // The formal's own §3.2 declaration, inside the function scope: the
            // shape comes from the FORMAL and the values from the actual, which
            // is what makes `arrayadd(x, '{y,z})` (§4.7.3) legal — the two
            // actuals have different shapes and the same size.
            const dims = try lower_param.dimsBounds(self, formal.dims, formal.main_tok, fname) orelse continue;
            // §3.2.2 a formal some subscript in the body indexes at run time:
            // one storage, filled element by element from the actual.
            if (lower_param.isMemArray(self, formal.name, ty)) {
                const place = try lower_param.declareMemArray(self, fname, dims, ty, true);
                for (vals, 0..) |v, k| try lower_param.storeElem(self, place, try self.mir.addIntConst(self.arena, @intCast(k)), v);
                try arg_slots.append(self.arena, &.{});
                continue;
            }
            try lower_param.declareArray(self, fname, .{ .dims = dims, .ty = ty });
            const slots = try self.arena.alloc(VarSlot, vals.len);
            var sub: [lower_param.max_stack_dims]i64 = undefined;
            const idx = try lower_param.subscriptBuf(self, &sub, dims.len);
            for (vals, slots, 0..) |v, *slot, k| {
                lower_param.shapeSubscripts(dims, k, idx);
                slot.* = try lower_param.declareVar(self, try lower_param.elemName(self, fname, idx), ty);
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
            try arg_slots.append(self.arena, slots);
            continue;
        }
        const slot = try lower_param.declareVar(self, fname, ty);
        try self.builder.writeVariable(slot.place, self.cur, vals[0]);
        try arg_slots.append(self.arena, try self.arena.dupe(VarSlot, &.{slot}));
    }
    // §6.8 an analog function is one of the six scopes; its locals are a list
    // like a module's or a block's.
    try lower_param.checkOneItemPerScope(self, fd.vars);
    for (fd.vars) |*v| try lower_param.declareVarDecl(self, v, .local);

    const exit = try self.mir.addBlock(self.arena);
    self.ret = .{ .slot = ret_slot, .exit = exit };
    try lower_stmt.lowerStmt(self, fd.body);
    try self.gotoBlock(exit);
    try self.builder.sealBlock(exit);
    self.cur = exit;

    const result: TypedValue = .{
        .v = try self.builder.readVariable(ret_slot.place, self.cur),
        .ty = ret_ty,
    };
    // §4.7.2.3/§4.7.2.4 read the writeback values while the scope is still up.
    var writeback: std.ArrayList([]const Mir.Value) = .empty;
    defer writeback.deinit(self.arena);
    for (fd.args, arg_slots.items) |formal, slots| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        // A memory-backed formal has no per-element slots; read its cells.
        if (self.arrays.get(self.file.str(formal.name))) |info| if (info.mem != null) {
            const vals = try self.arena.alloc(Mir.Value, lower_param.shapeCells(info.dims));
            var sub: [lower_param.max_stack_dims]i64 = undefined;
            const idx = try lower_param.subscriptBuf(self, &sub, info.dims.len);
            for (vals, 0..) |*v, k| {
                lower_param.shapeSubscripts(info.dims, k, idx);
                v.* = (try lower_expr.arrayElemValue(self, self.file.str(formal.name), idx)).?.v;
            }
            try writeback.append(self.arena, vals);
            continue;
        };
        const vals = try self.arena.alloc(Mir.Value, slots.len);
        for (slots, vals) |slot, *v| v.* = try self.builder.readVariable(slot.place, self.cur);
        try writeback.append(self.arena, vals);
    }

    // ---- leave the function scope ----
    _ = self.inlining.pop();
    self.scope_log.shrinkRetainingCapacity(log_mark);
    self.vars.deinit(self.arena);
    self.arrays.deinit(self.arena);
    self.vars = saved_vars;
    self.arrays = saved_arrays;
    self.ret = saved_ret;
    self.restrict = saved_restrict;
    self.func_params = saved_func_params;
    self.loops.deinit(self.arena);
    self.loops = saved_loops;
    // Undo in reverse, so a name touched twice ends at its first `prev`.
    while (shadowed.pop()) |sh| {
        if (sh.prev) |c| try self.consts.put(self.arena, sh.name, c) else _ = self.consts.remove(sh.name);
    }
    self.active_genvars = saved_genvars;

    var w: usize = 0;
    for (fd.args, 0..) |formal, fi| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        defer w += 1;
        // A `pre` formal has no source expression to write back into. §9.17.3
        // makes every formal of a `$limit` limiter `input` (E0814), so this is
        // unreachable there; the guard is what keeps it unreachable.
        if (fi < pre.len) continue;
        const actual = arg_exprs[fi - pre.len];
        const vals = writeback.items[w];
        if (formal.dims.len != 0) {
            // §4.7.2.3: "the last value assigned to the output argument is then
            // assigned to the corresponding analog variable reference that was
            // passed into the function" — element by element, in declaration
            // order, into the caller's own storage.
            try funcArrayOut(self, actual, vals);
            continue;
        }
        // §3.2 a runtime subscript names no single storage slot, so the
        // writeback is the same masked one `a[i] = …` takes. §4.7.2.3 says
        // only that "the last value assigned to the output argument is then
        // assigned to the corresponding analog variable reference" — it puts
        // no constant-expression condition on the reference, and `resolveLvalue`
        // was refusing one with E0311.
        if (try lower_stmt.writeRuntimeIndex(self, actual, actual, .{ .v = vals[0], .ty = astTy(formal.ty) })) continue;
        const slot = try lower_stmt.resolveLvalue(self, actual) orelse continue;
        try lower_stmt.writeLvalue(self, slot, vals[0]);
    }
    return result;
}

/// The cell count of an array actual in one of §4.7.2.3's two shapes, "an
/// analog variable or an array assignment pattern of analog variables", or null
/// for anything else.
fn arrayActualCells(self: *Lower, actual: Ast.ExprId) Oom!?usize {
    const ex = &self.file.exprs;
    return switch (ex.tag(actual)) {
        .ident => if (self.arrays.get(self.file.str(ex.strOf(actual)))) |info| lower_param.shapeCells(info.dims) else null,
        .assign_pattern, .concat => (try lower_param.patternElems(self, actual)).len,
        else => null, // else: §4.7.2.3 admits no third shape
    };
}

/// §4.7.2.3: "the argument passed into the function must be an analog variable
/// or an array assignment pattern of analog variables of equivalent size."
/// Copy IN — one Value per element of the formal. False when the actual has the
/// wrong size or is not one of those two shapes.
///
/// The pattern arm lowers each element as an EXPRESSION and not as an lvalue:
/// copy-in has no reason to require storage, and `funcArrayOut` is where the
/// clause's write-back needs one. `'{y, z}` satisfies both.
pub fn funcArrayIn(self: *Lower, actual: Ast.ExprId, ty: Ty, out: []Mir.Value) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(actual)) {
        .ident => {
            const aname = self.file.str(ex.strOf(actual));
            const info = self.arrays.get(aname) orelse return false;
            if (lower_param.shapeCells(info.dims) != out.len) return false;
            var sub: [lower_param.max_stack_dims]i64 = undefined;
            const idx = try lower_param.subscriptBuf(self, &sub, info.dims.len);
            for (out, 0..) |*v, k| {
                lower_param.shapeSubscripts(info.dims, k, idx);
                const el = (try lower_expr.arrayElemValue(self, aname, idx)) orelse return false;
                v.* = if (ty == .real) try self.toReal(el) else el.v;
            }
            return true;
        },
        .assign_pattern, .concat => {
            const elems = try lower_param.patternElems(self, actual);
            if (elems.len != out.len) return false;
            for (elems, out) |e, *v| {
                const tv = try lower_expr.lowerExpr(self, e);
                v.* = if (ty == .real) try self.toReal(tv) else tv.v;
            }
            return true;
        },
        else => return false, // else: §4.7.2.3 admits no third shape; the caller reports E0511
    }
}

/// The write-back half of the same sentence. Each element of the actual is an
/// ordinary lvalue, so a pattern element that is not writable collects the usual
/// E0313/E0316 from `resolveLvalue` — which is the right verdict: §4.7.2.3 says
/// "analog variables", and a literal there has nowhere to receive the result.
pub fn funcArrayOut(self: *Lower, actual: Ast.ExprId, vals: []const Mir.Value) Oom!void {
    const ex = &self.file.exprs;
    switch (ex.tag(actual)) {
        .ident => {
            const aname = self.file.str(ex.strOf(actual));
            const info = self.arrays.get(aname) orelse return;
            var key_buf: [lower_param.elem_key_len]u8 = undefined;
            var sub: [lower_param.max_stack_dims]i64 = undefined;
            const idx = try lower_param.subscriptBuf(self, &sub, info.dims.len);
            for (vals, 0..) |v, k| {
                lower_param.shapeSubscripts(info.dims, k, idx);
                if (info.mem == null and !self.vars.contains(try lower_param.elemKey(self, &key_buf, aname, idx))) continue;
                try lower_param.writeElem(self, aname, info, idx, v);
            }
        },
        .assign_pattern, .concat => {
            for (try lower_param.patternElems(self, actual), vals) |e, v| {
                const slot = try lower_stmt.resolveLvalue(self, e) orelse continue;
                try lower_stmt.writeLvalue(self, slot, v);
            }
        },
        else => unreachable, // else: the call refused any other shape (`arrayActualCells`, `funcArrayIn`)
    }
}
