//! The instance walk: one module's instance list → every reachable instance
//! inlined into the flat module, depth first in source order. Per level it
//! records the level's §6.3.1 defparams and Annex F.2.1 out-of-context
//! declarations, plans §7.8.4 connect modules, then per instance binds the
//! ports (§6.2.2), applies the overrides (§6.3, §6.4), names every
//! declaration (§6.7), clones the body (`clone.zig`) and recurses.
//! LRM §3.6.2, §3.6.5, §6.2.2, §6.3, §6.3.1, §6.4, §6.4.3, §6.5, §6.5.5, §6.5.7.1,
//! §6.6, §6.7.1, §7.1, §7.8.4, §9.15, §9.19, A.4.1, A.5.4, Annex E.3.2;
//! IEEE 1364-2005 §5.2.1, §12.3.3, §12.3.6, §19.9.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const Unit = Flatten.Unit;
const Error = elaborate.Error;
const sep = elaborate.sep;
const max_depth = elaborate.max_depth;
const elab_clone = @import("clone.zig");
const elab_insert = @import("insert.zig");
const elab_names = @import("names.zig");
const elab_override = @import("override.zig");
const elab_paramset = @import("paramset.zig");
const elab_resolve = @import("resolve.zig");
const discipline = @import("../discipline_rules.zig");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;

/// Returns whether `name` is an IEEE 1364 UDP: a digital primitive the
/// analog flatten never inlines (A.5.4).
fn isUdp(file: *const Ast.SourceFile, name: Ast.StrId) bool {
    for (file.udps) |u| if (u.name == name) return true;
    return false;
}

/// §6.6 every module instance in a generate block under `id`, schemes aside.
pub fn genInstanceList(file: *Ast.SourceFile, id: Ast.StmtId, arena: std.mem.Allocator, out: *std.ArrayList(Ast.Instance)) Error!void {
    try genInstanceListIn(file, id, arena, "", out);
}

fn genInstanceListIn(file: *Ast.SourceFile, id: Ast.StmtId, arena: std.mem.Allocator, prefix: []const u8, out: *std.ArrayList(Ast.Instance)) Error!void {
    if (id == .none) return;
    switch (file.stmt(id)) {
        .block => |b| {
            const inner = try blockPrefix(file, arena, prefix, b);
            for (b.instances) |inst| try out.append(arena, try scoped(file, arena, inner, inst));
            for (b.body) |s| try genInstanceListIn(file, s, arena, inner, out);
        },
        .if_stmt => |s| {
            try genInstanceListIn(file, s.then_s, arena, prefix, out);
            try genInstanceListIn(file, s.else_s, arena, prefix, out);
        },
        .for_stmt => |s| try genInstanceListIn(file, s.body, arena, prefix, out),
        .case_stmt => |s| for (s.arms) |a| try genInstanceListIn(file, a.body, arena, prefix, out),
        else => {}, // else: no other statement holds a generate block
    }
}

/// §6.6.3 / IEEE 1364-2005 §12.4.3: a generate block is a scope, so an
/// instance in `g1` is `g1.u`, and one in an unnamed block is
/// `genblk<n>.u` for external interfaces (`Ast.SeqBlock.gen_name`). Two
/// blocks may each hold a `u`. The prefix of the blocks enclosing `b`, plus
/// `b`'s own name when it is a generate scope.
fn blockPrefix(file: *Ast.SourceFile, arena: std.mem.Allocator, prefix: []const u8, b: Ast.SeqBlock) Error![]const u8 {
    if (b.gen_name == .none) return prefix;
    return arena.print("{s}{s}{c}", .{ prefix, file.str(b.gen_name), sep });
}

/// `inst` named inside the generate scope `prefix` (see `blockPrefix`). The
/// flat path joins on `sep`, so `g1.u` is the instance's hierarchical name.
fn scoped(file: *Ast.SourceFile, arena: std.mem.Allocator, prefix: []const u8, inst: Ast.Instance) Error!Ast.Instance {
    if (prefix.len == 0) return inst;
    var out = inst;
    out.name = try file.intern(arena, try arena.print("{s}{s}", .{ prefix, file.str(inst.name) }));
    return out;
}

/// §6.6 appends a generate block's module instances to `out` and, in
/// parallel, the scheme that brings each into existence to `gates`, cloned
/// into this unit's flat namespace.
/// "At most one generate block instantiated from a set of alternatives":
/// an if-generate's arms are gated `c` and `!c`, and `inlineInstance`
/// lowers each child's analog blocks under its gate. `checkGenScheme`
/// marks the parameters as shape parameters, so a host card cannot change
/// the arm selected by their final compile-time values.
/// A loop generate's instances are `loopInstances`'s.
/// ponytail: a case generate's instance is E0235 (`refuseGen`): it needs an
/// equality chain per arm.
/// `prefix` names the generate scopes enclosing `id` (`blockPrefix`);
/// `locals` are their localparams, outermost first (`bindGenLocals`).
fn genInstances(self: *Flatten, id: Ast.StmtId, gate: Ast.ExprId, prefix: []const u8, locals: []const Ast.ParamDecl, out: *std.ArrayList(Ast.Instance), gates: *std.ArrayList(Ast.ExprId)) Error!void {
    if (id == .none) return;
    switch (self.ctx.file.stmt(id)) {
        .block => |b| {
            const inner = try blockPrefix(self.ctx.file, self.ctx.arena, prefix, b);
            const inner_locals = if (b.params.len == 0) locals else try std.mem.concat(self.ctx.arena, Ast.ParamDecl, &.{ locals, b.params });
            for (b.instances) |inst| {
                var bound = try scoped(self.ctx.file, self.ctx.arena, inner, inst);
                if (inner_locals.len != 0) {
                    const params = try self.ctx.arena.dupe(Ast.ParamOverride, inst.params);
                    for (params) |*o| o.value = try bindGenLocals(self, o.value, inner_locals);
                    bound.params = params;
                }
                try out.append(self.ctx.arena, bound);
            }
            try gates.appendNTimes(self.ctx.arena, gate, b.instances.len);
            for (b.body) |s| try genInstances(self, s, gate, inner, inner_locals, out, gates);
        },
        .if_stmt => |s| if (s.is_generate) {
            const c = try elab_clone.cloneExpr(self, s.cond);
            try genInstances(self, s.then_s, try conj(self, gate, c, false), prefix, locals, out, gates);
            try genInstances(self, s.else_s, try conj(self, gate, c, true), prefix, locals, out, gates);
        },
        .for_stmt => |s| try loopInstances(self, s.init, s.cond, s.step, s.body, gate, prefix, locals, out, gates),
        .case_stmt => |s| for (s.arms) |a| try refuseGen(self, a.body),
        else => {}, // else: no other statement holds a generate block
    }
}

/// §6.6.2 a generate block's localparams are declared in the block's scope,
/// so an instance's `#(...)` written there may read them, and §6.9.2 selects
/// a paramset only once "the generate construct has been evaluated", with
/// the values the block supplies. The flatten keeps an override in the
/// instantiating module's names, where a block localparam does not exist, so
/// each identifier in `e` naming one of `locals` (the innermost, latest
/// declared, when several share a name) is replaced by that localparam's
/// value expression, itself read in the scope it was declared in. The
/// result is still in the module's names and depends on the module's
/// parameters as the localparam did.
/// ponytail: the localparam's declared type is not applied to the
/// substituted value; the receiving parameter's type converts it.
fn bindGenLocals(self: *Flatten, e: Ast.ExprId, locals: []const Ast.ParamDecl) Error!Ast.ExprId {
    if (e == .none) return e;
    const x = &self.ctx.file.exprs;
    var n = x.get(e);
    switch (n.tag) {
        .ident => {
            var k = locals.len;
            while (k > 0) {
                k -= 1;
                if (locals[k].name == n.str and locals[k].dims.len == 0) return bindGenLocals(self, locals[k].default, locals[0..k]);
            }
            return e;
        },
        .unary => {
            n.lhs = try bindGenLocals(self, x.lhs(e), locals);
            if (n.lhs == x.lhs(e)) return e;
        },
        .binary, .index, .range, .indexed_range, .multi_concat, .pattern_repl => {
            n.lhs = try bindGenLocals(self, x.lhs(e), locals);
            n.rhs = try bindGenLocals(self, x.rhs(e), locals);
            if (n.lhs == x.lhs(e) and n.rhs == x.rhs(e)) return e;
        },
        .ternary => {
            const third = x.ternaryElse(e);
            n.lhs = try bindGenLocals(self, x.lhs(e), locals);
            n.rhs = try bindGenLocals(self, x.rhs(e), locals);
            const t = try bindGenLocals(self, third, locals);
            if (n.lhs == x.lhs(e) and n.rhs == x.rhs(e) and t == third) return e;
            n.extra = @backingInt(t);
        },
        .call, .sys_call, .builtin_call, .concat, .assign_pattern => {
            const src = x.args(e);
            const args = try self.ctx.arena.alloc(Ast.ExprId, src.len);
            var changed = false;
            for (src, args) |a, *o| {
                o.* = try bindGenLocals(self, a, locals);
                changed = changed or o.* != a;
            }
            if (!changed) return e;
            n.extra = try x.addExprList(self.ctx.arena, args);
        },
        else => return e, // else: literals, dotted names and the analog-only forms name no block localparam a constant override can read
    }
    return x.add(self.ctx.arena, n);
}

/// §6.6.1 a loop generate's module instances, one set per iteration. The
/// genvar is "an integer parameter" in each generate block instance, "the
/// value of the index variable at the time the instance was elaborated", so
/// each copy's overrides and connections read it as a literal, and the copy
/// is named `blk[i].inst` (§6.6.1, §6.6.3) inside the enclosing scopes
/// `prefix`. An override reads the localparams of those scopes and of the
/// loop's block (`bindGenLocals`, before the genvar is bound, so a
/// localparam computed from the genvar takes this iteration's value).
/// §6.9.2's paramset selection then sees those values. The scheme folds in the module's names; one that does
/// not fold, or runs past `max_iterations`, yields no instances here, and
/// lowering's unroll of the same loop reports why (E0417-E0420, E0485, E0486).
///
/// ponytail: instances written directly in the loop's block only. One under
/// a nested generate scheme or block is E0235; the upgrade is recursing
/// through `genInstances` with the genvar bound.
fn loopInstances(self: *Flatten, init: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId, gate: Ast.ExprId, prefix: []const u8, locals: []const Ast.ParamDecl, out: *std.ArrayList(Ast.Instance), gates: *std.ArrayList(Ast.ExprId)) Error!void {
    const file = self.ctx.file;
    var all: std.ArrayList(Ast.Instance) = .empty;
    try genInstanceList(file, body, self.ctx.arena, &all);
    if (all.items.len == 0) return;
    const blk = if (body != .none and file.stmt(body) == .block) file.stmt(body).block else return refuseGen(self, body);
    if (blk.gen_name == .none) return refuseGen(self, body);
    if (blk.instances.len != all.items.len) {
        for (all.items[blk.instances.len..]) |inst| try self.err(inst.main_tok, .E0235, "a module instance under a generate scheme nested in a loop generate", .{});
        return;
    }
    if (init == .none or step == .none or file.stmt(init) != .assign or file.stmt(step) != .assign) return;
    const gv_e = file.stmt(init).assign.target;
    if (file.exprs.tag(gv_e) != .ident) return;
    const gv = file.exprs.strOf(gv_e);
    const inner_locals = if (blk.params.len == 0) locals else try std.mem.concat(self.ctx.arena, Ast.ParamDecl, &.{ locals, blk.params });
    var v = (try constGenvar(self, file.stmt(init).assign.value, gv, null)) orelse return;
    var n: u32 = 0;
    while (n < max_iterations) : (n += 1) {
        const lit = try file.exprs.addInt(self.ctx.arena, file.exprs.mainTok(cond), v);
        const c = elab_names.constValue(self, try substIdent(self, cond, gv, lit), true, null) orelse return;
        if (!c.isTrue()) return;
        for (blk.instances) |inst| {
            var copy = inst;
            copy.name = try file.intern(self.ctx.arena, try self.ctx.arena.print("{s}{s}[{d}]{c}{s}", .{ prefix, file.str(blk.gen_name), v, sep, file.str(inst.name) }));
            const params = try self.ctx.arena.dupe(Ast.ParamOverride, inst.params);
            for (params) |*o| o.value = try substIdent(self, try bindGenLocals(self, o.value, inner_locals), gv, lit);
            copy.params = params;
            const ports = try self.ctx.arena.dupe(Ast.PortConn, inst.ports);
            for (ports) |*pc| pc.expr = try substIdent(self, pc.expr, gv, lit);
            copy.ports = ports;
            try out.append(self.ctx.arena, copy);
            try gates.append(self.ctx.arena, gate);
        }
        v = (try constGenvar(self, file.stmt(step).assign.value, gv, lit)) orelse return;
    }
}

/// Lowering's `max_unroll`: past it lowering refuses the loop (E0485/E0420).
const max_iterations = 4096;

/// A genvar assignment's value, folded in the module's names with the genvar
/// at `at` (null for the initialization), or null when it is no integer.
fn constGenvar(self: *Flatten, e: Ast.ExprId, gv: Ast.StrId, at: ?Ast.ExprId) Error!?i64 {
    const bound = if (at) |lit| try substIdent(self, e, gv, lit) else e;
    const c = elab_names.constValue(self, bound, true, null) orelse return null;
    return if (c == .int) c.int else null;
}

/// `e` with every identifier `name` replaced by `with`; rows unchanged where
/// nothing below them changed.
pub fn substIdent(self: *Flatten, e: Ast.ExprId, name: Ast.StrId, with: Ast.ExprId) Error!Ast.ExprId {
    if (e == .none) return e;
    const x = &self.ctx.file.exprs;
    var n = x.get(e);
    switch (n.tag) {
        .ident => return if (n.str == name) with else e,
        .unary => {
            n.lhs = try substIdent(self, x.lhs(e), name, with);
            if (n.lhs == x.lhs(e)) return e;
        },
        .binary, .index, .range, .indexed_range, .multi_concat, .pattern_repl => {
            n.lhs = try substIdent(self, x.lhs(e), name, with);
            n.rhs = try substIdent(self, x.rhs(e), name, with);
            if (n.lhs == x.lhs(e) and n.rhs == x.rhs(e)) return e;
        },
        .ternary => {
            const third = x.ternaryElse(e);
            n.lhs = try substIdent(self, x.lhs(e), name, with);
            n.rhs = try substIdent(self, x.rhs(e), name, with);
            const t = try substIdent(self, third, name, with);
            if (n.lhs == x.lhs(e) and n.rhs == x.rhs(e) and t == third) return e;
            n.extra = @backingInt(t);
        },
        .call, .sys_call, .builtin_call, .concat, .assign_pattern => {
            const src = x.args(e);
            const args = try self.ctx.arena.alloc(Ast.ExprId, src.len);
            var changed = false;
            for (src, args) |a, *o| {
                o.* = try substIdent(self, a, name, with);
                changed = changed or o.* != a;
            }
            if (!changed) return e;
            n.extra = try x.addExprList(self.ctx.arena, args);
        },
        else => return e, // else: literals, dotted names and the analog-only forms hold no genvar an instance's override or connection reads
    }
    return x.add(self.ctx.arena, n);
}

fn refuseGen(self: *Flatten, id: Ast.StmtId) Error!void {
    var all: std.ArrayList(Ast.Instance) = .empty;
    try genInstanceList(self.ctx.file, id, self.ctx.arena, &all);
    for (all.items) |inst| try self.err(inst.main_tok, .E0235, "a module instance in a loop or case generate", .{});
}

/// `a && c` (or `a && !c`), `a` = `.none` meaning true.
fn conj(self: *Flatten, a: Ast.ExprId, c: Ast.ExprId, negate: bool) Error!Ast.ExprId {
    const ex = &self.ctx.file.exprs;
    const tok = ex.mainTok(c);
    const t = if (!negate) c else try ex.add(self.ctx.arena, .{
        .tag = .unary,
        .main_tok = tok,
        .lhs = c,
        .extra = @backingInt(Ast.UnaryOp.logical_not),
    });
    if (a == .none) return t;
    return ex.add(self.ctx.arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = a,
        .rhs = t,
        .extra = @backingInt(Ast.BinaryOp.logical_and),
    });
}

/// §6.2.2 every instance of one unit, in source order, depth first. `path`
/// is the unit's own hierarchical prefix ("" at the top).
pub fn walkInstances(
    self: *Flatten,
    source_module: *const Ast.ModuleDecl,
    path: []const u8,
    /// The module names being elaborated, top first: `stack[0..depth + 1]`.
    /// `depth < max_depth` holds before each push (E1018), so it never overflows.
    stack: *[max_depth + 1]Ast.StrId,
    depth: u32,
) Error!void {
    // §6.3/§6.4.2 an indexed defparam can select a different paramset for
    // each array element. Expand before §6.9.3 connect planning, so both
    // passes use the same external instance paths and selected modules.
    // Preserve early named errors before allocating an array's rows.
    for (source_module.instances) |inst| {
        if (inst.range == null) continue;
        if (isUdp(self.ctx.file, inst.module)) continue;
        if (elab_names.findModule(self, inst.module)) |child| {
            for (stack[0 .. depth + 1]) |on_stack| if (on_stack == child.name) {
                try self.err(inst.main_tok, .E0905, "`{s}` is already being elaborated at `{s}{s}`", .{
                    self.ctx.file.str(child.name), path, self.ctx.file.str(inst.name),
                });
                return;
            };
        } else {
            const known = for (self.ctx.file.paramsets) |ps| {
                if (ps.name == inst.module) break true;
            } else false;
            if (!known) {
                try elab_names.unknownModule(self, &inst);
                return;
            }
        }
        if (depth >= max_depth) {
            try self.err(inst.main_tok, .E1018, "at `{s}{s}`", .{ path, self.ctx.file.str(inst.name) });
            return;
        }
    }
    var expanded = source_module.*;
    expanded.instances = try expandInstanceArrays(self, source_module.instances);
    const module = &expanded;
    // Both before the children: each names something below this module.
    try elab_override.collectDefparams(self, module, path); // §6.3.1
    try elab_resolve.collectOoc(self, module, path); // Annex F.2.1 step 3

    // The source instances, then the §6.6 generate instances, whose schemes
    // `gates` holds in parallel from index `module.instances.len` on.
    var src: std.ArrayList(Ast.Instance) = .empty;
    try src.appendSlice(self.ctx.arena, module.instances);
    var gates: std.ArrayList(Ast.ExprId) = .empty;
    for (module.analog) |blk| try genInstances(self, blk.body, .none, "", &.{}, &src, &gates);
    std.debug.assert(src.items.len == module.instances.len + gates.items.len);

    // §7.8.4 connect modules are inserted "in the context of the ports
    // upper connection", which is this module: `plan` re-points each mixed
    // port at a digital segment and appends the bridges, which then inline
    // like any child. Indices past `src.items.len` are those.
    // The first walk (`Flatten.dry`) inserts nothing: it records the tree.
    const all = if (self.dry) src.items else try elab_insert.plan(self, module, path, src.items, gates.items);

    // E.3.2's first source, "A port_discipline attribute on the analog
    // primitive", bound for every primitive of this level before any is
    // inlined, so E.3.2.2's "the same discipline" scan for an unattributed
    // primitive finds the segment resolved in any source order.
    // ponytail: a primitive reached through a paramset keeps only the
    // default; `selectParamset` diagnoses, so it is not run twice.
    for (module.instances) |*inst| {
        const child = elab_names.findModule(self, inst.module) orelse continue;
        if (!elab_names.isPrimitive(self, child)) continue;
        for (child.ports, 0..) |p, i| {
            const conn = connectionFor(inst, p, i) orelse continue;
            const n = elab_names.netRefName(self, conn.expr) orelse continue;
            var q = p;
            q.discipline = elab_names.portDisciplineAttr(self, module, inst, conn) orelse continue;
            const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, self.ctx.file.str(inst.name), sep });
            try elab_resolve.resolveDiscipline(self, child_path, q, self.unit.rename.get(n) orelse n, conn.main_tok);
        }
    }

    for (all, 0..) |inst, idx| {
        const auto = idx >= src.items.len;
        const gate: Ast.ExprId = if (idx < module.instances.len or auto) .none else gates.items[idx - module.instances.len];
        // §3.6.5, the structural half: an actual that names nothing `module`
        // declared is an implicit net (see `Design.implicit_nets`).
        // Collected here, not in `inlineInstance`, because only this loop
        // still has `module` in hand; one level down the names are flat.
        // Reads the source's own connections, not `plan`'s segments.
        if (!auto and idx < module.instances.len) try checkVariableActuals(self, module, &module.instances[idx]);
        if (!auto) for (src.items[idx].ports) |c| {
            const n = elab_names.netRefName(self, c.expr) orelse continue;
            if (declares(module, n)) continue;
            try self.implicit_nets.append(self.ctx.arena, .{
                .name = self.ctx.file.str(n),
                .main_tok = c.main_tok,
            });
        };

        // A.4.1 `module_instantiation ::= module_or_paramset_identifier ...`:
        // §6.4 says a paramset "can be instantiated exactly like a module".
        // A module wins; §6.4.2 selection runs only when nothing else matches.
        //
        // A.5.4: a named udp_instance parses as a module instance
        // (`parseUdpInst`), so its `#( … )` arrives as a
        // parameter_value_assignment. It is A.2.2.3's `delay2` (at most two
        // positional values), and the instance reaches no analog device (W0252).
        if (isUdp(self.ctx.file, inst.module)) {
            for (inst.params) |p| if (p.scaled_literal_tok) |tok|
                try self.err(tok, .E0247, "a scaled literal in `{s}`'s UDP delay", .{self.ctx.file.str(inst.module)});
            if (inst.params.len > 2 or (inst.params.len != 0 and inst.params[0].name != .none))
                try self.err(inst.main_tok, .E0239, "`{s} #(…) {s}`: {d} value(s)", .{ self.ctx.file.str(inst.module), self.ctx.file.str(inst.name), inst.params.len })
            else
                try self.ctx.bag.add(.lower, .W0252, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, inst.main_tok), "`{s}` primitive", .{self.ctx.file.str(inst.module)});
            continue;
        }
        // §6.2.2 `name_of_module_instance ::= module_instance_identifier
        // [ range ]`: one instance per element, each addressable as §6.7's
        // `adder1[5].sum`.
        var lo: i64 = 0;
        var hi: i64 = 0;
        var is_array = false;
        if (inst.range) |r| {
            const msb = elab_names.constInt(self, r.msb) orelse {
                try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
                continue;
            };
            const lsb = elab_names.constInt(self, r.lsb) orelse {
                try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
                continue;
            };
            lo = @min(msb, lsb);
            hi = @max(msb, lsb);
            is_array = true;
        }

        // The end may be maxInt(i64). Keep the loop's one-past-end
        // value in a wider carrier; `continue` must advance safely too.
        var k: i128 = lo;
        while (k <= hi) : (k += 1) {
            const leaf = if (is_array)
                try self.ctx.arena.print("{s}[{d}]", .{ self.ctx.file.str(inst.name), k })
            else
                self.ctx.file.str(inst.name);
            const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, leaf, sep });
            var ps: ?*const Ast.ParamsetDecl = null;
            const child = elab_names.findModule(self, inst.module) orelse blk: {
                ps = try elab_paramset.selectParamset(self, &inst, child_path) orelse continue;
                break :blk try elab_names.chainEnd(self, ps.?) orelse continue;
            };
            if (elab_names.isPrimitive(self, child)) try elab_names.checkPortDiscipline(self, module, &inst);
            // §7.1 manually and automatically inserted connect modules
            // follow this same instance walk.
            for (stack[0 .. depth + 1]) |on_stack| if (on_stack == child.name) {
                try self.err(inst.main_tok, .E0905, "`{s}` is already being elaborated at `{s}`", .{ self.ctx.file.str(child.name), child_path });
                return;
            };
            if (depth >= max_depth) {
                try self.err(inst.main_tok, .E1018, "at `{s}`", .{child_path});
                return;
            }
            // Both arms of an if-generate are inlined under their gates; the
            // tree holds only an instance its scheme brings into existence
            // (one whose gate does not fold is left out, as unknown).
            if (self.dry and elab_names.gateHolds(self, gate)) {
                const kids = try self.tree.getOrPut(self.ctx.arena, path);
                if (!kids.found_existing) kids.value_ptr.* = .empty;
                try kids.value_ptr.append(self.ctx.arena, .{ .inst = inst, .module = child, .path = child_path });
            }
            try inlineInstance(self, &inst, child, ps, child_path, stack, depth, gate);
        }
    }
}

/// Scalarize §6.2.2 module arrays before per-instance decisions. The source
/// AST remains unchanged for the mixed runner's independent digital walk.
fn expandInstanceArrays(self: *Flatten, insts: []const Ast.Instance) Error![]const Ast.Instance {
    for (insts) |inst| {
        if (inst.range != null) break;
    } else return insts;
    var out: std.ArrayList(Ast.Instance) = .empty;
    for (insts) |inst| {
        // UDP instances belong to the digital walk. The analog path
        // reports W0252 once at the source site, as for a scalar UDP.
        if (isUdp(self.ctx.file, inst.module)) {
            try out.append(self.ctx.arena, inst);
            continue;
        }
        const range = inst.range orelse {
            try out.append(self.ctx.arena, inst);
            continue;
        };
        const msb = elab_names.constInt(self, range.msb);
        const lsb = elab_names.constInt(self, range.lsb);
        if (msb == null or lsb == null) {
            try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
            continue;
        }
        // A singleton at maxInt(i64) is legal and must not overflow
        // when advancing past its final element. No range subtraction.
        var k: i128 = @min(msb.?, lsb.?);
        while (k <= @max(msb.?, lsb.?)) : (k += 1) {
            var scalar = inst;
            scalar.name = try self.ctx.file.intern(self.ctx.arena, try self.ctx.arena.print("{s}[{d}]", .{ self.ctx.file.str(inst.name), k }));
            scalar.range = null;
            try out.append(self.ctx.arena, scalar);
        }
    }
    return out.items;
}

/// Inline ONE instance: bind its ports, apply its §6.3 overrides, rename its
/// declarations into the flat namespace, clone its body, then recurse.
///
/// `path` already ends in `sep`, so a flat name is `path ++ local`.
fn inlineInstance(
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    /// §6.4 non-null when the instance named a PARAMSET: `child` is then the
    /// module the paramset specializes and the instance's own `#(...)`
    /// overrides belong to the paramset, not to `child`.
    ps: ?*const Ast.ParamsetDecl,
    path: []const u8,
    stack: *[max_depth + 1]Ast.StrId,
    depth: u32,
    /// §6.6 the scheme of the generate block `inst` sits in (`genInstances`).
    gate: Ast.ExprId,
) Error!void {
    const parent = self.unit; // restored below; the rename map is a stack
    var unit: Unit = .{
        .path = path,
        .primitive = elab_names.isPrimitive(self, child),
        .gate = if (gate == .none) parent.gate else try conj(self, parent.gate, gate, false),
        .paramset_instance = if (ps != null) path[0 .. path.len - 1] else parent.paramset_instance,
        .module = child,
        .up = &parent,
    };

    // §3.6.2 every out-of-context declaration naming a segment of this
    // instance was collected above it; judge each once, before it is applied.
    try elab_resolve.checkOocOverrides(self, child, path);

    // ---- §6.2.2 port connections ---------------------------------------
    // Resolved in the PARENT's namespace, which means through the parent's
    // rename map: an actual naming a net of a mid-level module has already
    // been flattened to `u.n`.
    // At most one of each per child port.
    var concats: std.ArrayList(struct { port: Ast.Port, parts: []const elaborate.NetPart, tok: u32 }) = try .initCapacity(self.ctx.arena, child.ports.len);
    var widths: std.ArrayList(struct { port: Ast.Port, net: Ast.StrId, tok: u32 }) = try .initCapacity(self.ctx.arena, child.ports.len);
    for (child.ports, 0..) |p, i| {
        const conn = connectionFor(inst, p, i);
        try unit.connected.put(self.ctx.arena, p.name, conn != null and conn.?.expr != .none);
        // §6.5.7.1 a concatenated net expression, and §6.5.5's "scalar
        // member, sub-range" of a parent net: each a list of the parent's net
        // parts, bound element by element once the child's range is known.
        if (conn) |c| if (c.expr != .none and switch (self.ctx.file.exprs.tag(c.expr)) {
            .concat, .index => true,
            else => false, // else: a whole net (joined below) or not a net expression (E0906 below)
        }) {
            var parts: std.ArrayList(elaborate.NetPart) = .empty;
            const is_concat = self.ctx.file.exprs.tag(c.expr) == .concat;
            var ok = true;
            if (is_concat) {
                for (self.ctx.file.exprs.args(c.expr)) |o| if (!try netPart(self, &parent, o, &parts)) {
                    ok = false;
                    break;
                };
            } else ok = try netPart(self, &parent, c.expr, &parts);
            if (!ok) {
                try self.err(c.main_tok, .E0906, "a port connection lists scalar nets, constant bit-selects and constant part-selects of nets", .{});
                continue;
            }
            const vector = p.range != null or p.type_range != null;
            if (is_concat and !vector) {
                try self.err(c.main_tok, .E0906, "a concatenation connects only a vector port, and `{s}` is scalar", .{self.ctx.file.str(p.name)});
                continue;
            }
            try unit.rename.put(self.ctx.arena, p.name, try elab_names.join(self, path, p.name));
            const local = elab_resolve.oocDiscipline(self, path, p.name) orelse p.discipline;
            if (local != .none) try unit.port_disc.put(self.ctx.arena, p.name, local);
            try concats.append(self.ctx.arena, .{ .port = p, .parts = parts.items, .tok = c.main_tok });
            continue;
        };
        const actual: ?Ast.StrId = if (conn) |c| elab_names.netRefName(self, c.expr) else null;
        if (actual) |n| {
            // The port is the parent's net: no new node, no new declaration.
            // ponytail: the parent map already owns this lookup and fallback.
            const bound = parent.rename.get(n) orelse n;
            try unit.rename.put(self.ctx.arena, p.name, bound);
            // §6.7.1 the port still has a hierarchical name that may be
            // probed, so the path resolves to the net it was joined to.
            // These are the only rows `Design.names` holds.
            try self.names.put(
                self.ctx.arena,
                try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(p.name) }),
                self.ctx.file.str(bound),
            );
            // E.3.2: a primitive's attribute was bound by `walkInstances`,
            // and its declared `electrical` is the default, bound last.
            // §4.4 otherwise the child's own declaration names its accesses.
            if (unit.primitive) {
                try self.prim_ports.append(self.ctx.arena, .{ .path = path, .port = p, .bound = bound });
            } else {
                widths.appendAssumeCapacity(.{ .port = p, .net = bound, .tok = conn.?.main_tok });
                try elab_resolve.resolveDiscipline(self, path, p, bound, conn.?.main_tok);
                const local = elab_resolve.oocDiscipline(self, path, p.name) orelse p.discipline;
                if (local != .none) try unit.port_disc.put(self.ctx.arena, p.name, local);
            }
        } else {
            // §6.2.2 "a blank port connection shall represent the situation
            // where the port is not to be connected", and an omitted named
            // port is the same thing. The child's equations still reference
            // it, so it becomes an internal net carrying the port's discipline.
            const internal = try elab_names.join(self, path, p.name);
            try unit.rename.put(self.ctx.arena, p.name, internal);
            try elab_resolve.addNet(self, .{
                .name = internal,
                // §3.10 order 1 still beats the local declaration on a port
                // nobody connected: the segment exists, it is just the only
                // segment of its signal.
                .discipline = elab_resolve.oocDiscipline(self, path, p.name) orelse p.discipline,
                .main_tok = p.main_tok,
            });
            // IEEE 1364 §19.9 applies to unconnected input ports of the
            // modules declared between the directive pair, so the site is
            // the port's declaration in the child (`p.main_tok`), not the
            // instance.
            if (p.direction == .input) try self.unconnected_inputs.append(self.ctx.arena, .{
                .name = self.ctx.file.str(internal),
                .main_tok = p.main_tok,
            });
        }
        if (conn) |c| if (c.expr != .none and actual == null)
            try self.err(c.main_tok, .E0906, "a port connection must be a net reference", .{});
    }
    try checkConnectionShape(self, inst, child);

    // ---- §6.3 parameter overrides --------------------------------------
    // Built before any name is renamed, because an override's VALUE is an
    // expression in the parent (`#(.gain(scale*2))`) and its NAME is a
    // parameter of the child.
    var over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
    var ps_stmts: std.ArrayList(Ast.StmtId) = .empty;
    if (ps) |p|
        try elab_paramset.paramsetOverrides(self, inst, p, child, &parent, &over, &unit, path, &ps_stmts)
    else
        try elab_override.collectOverrides(self, inst, child, &parent, &over, &unit, path);
    // §6.4.3 an undescribed paramset variable hides the module's variable of
    // the same name from this instance's reporting. Only the selected
    // paramset's own declarations; a chain's earlier links are not read.
    if (ps) |p| for (p.vars) |v| if (!v.desc) for (child.vars) |mv| if (mv.name == v.name)
        try self.ps_hidden.append(self.ctx.arena, try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(v.name) }));

    // ---- names: every local declaration gets its flat spelling ----------
    for (child.params) |p| try elab_names.bind(self, &unit, path, p.name);
    for (child.aliasparams) |al| try elab_names.bind(self, &unit, path, al.alias);
    for (child.nets) |n| try elab_names.bind(self, &unit, path, n.name);
    for (child.vars) |v| try elab_names.bind(self, &unit, path, v.name);
    for (child.branches) |b| try elab_names.bind(self, &unit, path, b.name);
    for (child.genvars) |g| try elab_names.bind(self, &unit, path, g);
    for (child.events) |e| try elab_names.bind(self, &unit, path, e.name);
    for (child.functions) |fd| try elab_names.bind(self, &unit, path, fd.name);
    for (child.instances) |sub| try elab_names.bind(self, &unit, path, sub.name);
    for (self.genInstancesOf(child)) |sub| try elab_names.bind(self, &unit, path, sub.name);

    self.unit = unit;
    for (concats.items) |cc| {
        const name = unit.rename.get(cc.port.name).?;
        try self.port_concats.append(self.ctx.arena, .{
            .name = self.ctx.file.str(name),
            .range = try elab_clone.cloneDim(self, cc.port.range orelse cc.port.type_range),
            .parts = cc.parts,
            .main_tok = cc.tok,
        });
        try elab_resolve.noteSignalDiscipline(self, name, elab_resolve.oocDiscipline(self, path, cc.port.name) orelse cc.port.discipline);
    }
    for (widths.items) |pw| try self.port_widths.append(self.ctx.arena, .{
        .net = self.ctx.file.str(pw.net),
        .range = try elab_clone.cloneDim(self, pw.port.range orelse pw.port.type_range),
        .main_tok = pw.tok,
    });

    // ---- the declarations themselves -----------------------------------
    try elab_clone.cloneParams(self, child.params, child.aliasparams, &over);
    for (child.nets) |n| {
        // Annex F.2.1 step 3: a dotted declaration is an out-of-context one,
        // already collected by `resolve.collectOoc`. It declares no net HERE.
        if (elab_resolve.isOoc(self.ctx.file.str(n.name))) continue;
        var out = n;
        out.name = elab_names.flat(self, n.name);
        out.range = try elab_clone.cloneDim(self, n.range);
        out.init = try elab_clone.cloneExpr(self, n.init);
        // §3.10 precedence order 1 on an internal net of the child: an
        // out-of-context declaration "overrides any discipline which may
        // be declared for sig in the module where sig was declared".
        if (elab_resolve.oocDiscipline(self, path, n.name)) |d| out.discipline = d;
        try elab_resolve.addNet(self, out);
    }
    for (child.vars) |v| {
        const out = try elab_clone.cloneVar(self, v);
        // IEEE 1364-2005 §12.3.3 an output port "declared as a variable"
        // is renamed with its port onto the parent's net, so two such
        // ports on one net (§9.22's two drivers) are one flat name. One
        // declaration serves both: the digital half resolves the net.
        const port = for (child.ports) |p| {
            if (p.name == v.name) break true;
        } else false;
        const again = port and for (self.vars.items) |seen| {
            if (seen.name == out.name) break true;
        } else false;
        if (again) continue;
        try self.vars.append(self.ctx.arena, out);
        // §6.8: renamed onto the parent's net, the variable and that net
        // share a flat name from two scopes (`Design.port_vars`).
        const flat_name = self.ctx.file.str(out.name);
        const local = self.ctx.file.str(v.name);
        const own = flat_name.len == path.len + local.len and std.mem.startsWith(u8, flat_name, path) and std.mem.endsWith(u8, flat_name, local);
        if (port and !own) try self.port_vars.append(self.ctx.arena, out.name);
    }
    for (child.branches) |b| {
        var out = b;
        out.name = elab_names.flat(self, b.name);
        out.hi = try elab_clone.cloneExpr(self, b.hi);
        out.lo = try elab_clone.cloneExpr(self, b.lo);
        out.range = try elab_clone.cloneDim(self, b.range);
        try self.branches.append(self.ctx.arena, out);
    }
    for (child.genvars) |g| try self.genvars.append(self.ctx.arena, elab_names.flat(self, g));
    for (child.events) |e| try self.events.append(self.ctx.arena, try elab_clone.cloneEvent(self, e));
    for (child.functions) |fd| try self.functions.append(self.ctx.arena, try elab_clone.cloneFunc(self, fd));
    for (child.attrs) |at| try self.attrs.append(self.ctx.arena, .{
        .name = at.name,
        .value = try elab_clone.cloneExpr(self, at.value),
        .main_tok = at.main_tok,
    });
    // One id per INSTANCE, not per module: two instances of the same child
    // are two devices, and §5.6.1.3 must not let one discard the other's.
    self.last_unit += 1;
    const unit_id = self.last_unit;
    // Appended in issue order, so `Design.units[unit_id]` is this instance.
    try self.unit_paths.append(self.ctx.arena, .{
        .module = self.ctx.file.str(child.name),
        .path = path,
        .decl = child,
    });
    for (child.analog) |blk| try appendAnalog(self, &unit, unit_id, blk.is_initial, try elab_clone.cloneStmt(self, blk.body), blk.main_tok);
    // §6.4.3 a paramset's statements, after the module's blocks: an output
    // variable "may be computed from values of any output parameters of the
    // module" (`.gm`), which those blocks compute.
    if (ps_stmts.items.len != 0) {
        const tok = ps.?.main_tok;
        try appendAnalog(self, &unit, unit_id, false, try self.ctx.file.addStmt(self.ctx.arena, .{ .block = .{ .body = ps_stmts.items } }, tok), tok);
    }
    // ponytail: a gated child's discrete half has no scheme to run under.
    if (unit.gate != .none and child.discrete.len + child.assigns.len + child.gates.len + child.pulls.len + child.switches.len != 0)
        try self.err(inst.main_tok, .E0235, "a module instance with discrete behavior", .{});
    for (child.discrete) |blk| try self.discrete.append(self.ctx.arena, .{
        .is_always = blk.is_always,
        .body = try elab_clone.cloneStmt(self, blk.body),
        .main_tok = blk.main_tok,
    });
    for (child.assigns) |a| {
        var o = a;
        o.target = try elab_clone.cloneExpr(self, a.target);
        o.value = try elab_clone.cloneExpr(self, a.value);
        o.delay = try elab_clone.cloneDelay(self, a.delay);
        try self.assigns.append(self.ctx.arena, o);
    }
    for (child.gates) |g| {
        var o = g;
        o.out = try elab_clone.cloneExpr(self, g.out);
        const ins = try self.ctx.arena.alloc(Ast.ExprId, g.ins.len);
        for (g.ins, ins) |src, *d| d.* = try elab_clone.cloneExpr(self, src);
        o.ins = ins;
        o.delay = try elab_clone.cloneDelay(self, g.delay);
        try self.gates.append(self.ctx.arena, o);
    }
    for (child.pulls) |p| {
        var o = p;
        o.out = try elab_clone.cloneExpr(self, p.out);
        try self.pulls.append(self.ctx.arena, o);
    }
    for (child.switches) |sw| {
        var o = sw;
        const terms = try self.ctx.arena.alloc(Ast.ExprId, sw.terms.len);
        for (sw.terms, terms) |src, *d| d.* = try elab_clone.cloneExpr(self, src);
        o.terms = terms;
        o.delay = try elab_clone.cloneDelay(self, sw.delay);
        try self.switches.append(self.ctx.arena, o);
    }
    // ---- recurse, with this unit's map in force ------------------------
    stack[depth + 1] = child.name;
    try walkInstances(self, child, path, stack, depth + 1);

    self.unit = parent;
}

/// Appends the parent net part `e` names: a net `x` whole, §6.5.5's scalar
/// member `bus[1]`, its sub-range `bus[3:2]`, or IEEE 1364-2005 §5.2.1's
/// `bus[i +: 2]` (a sub-range by A.2.1.3's constant_range_expression). The
/// bounds fold in the parent's names, a genvar's value included; whether
/// they lie in the net's declared range is lowering's to judge (E0352).
/// Returns false for anything else: a non-constant bound, or an expression
/// that is not a net.
fn netPart(self: *Flatten, parent: *const Unit, e: Ast.ExprId, out: *std.ArrayList(elaborate.NetPart)) Error!bool {
    const ex = &self.ctx.file.exprs;
    const base = if (ex.tag(e) == .index) ex.lhs(e) else e;
    const n = elab_names.netRefName(self, base) orelse return false;
    const net = self.ctx.file.str(parent.rename.get(n) orelse n);
    if (base == e) {
        try out.append(self.ctx.arena, .{ .net = net });
        return true;
    }
    const sel = ex.rhs(e);
    const two = ex.tag(sel) == .range or ex.tag(sel) == .indexed_range;
    // `constInt` folds in `self.unit`, which is still the parent here.
    const a = elab_names.constInt(self, if (two) ex.lhs(sel) else sel) orelse return false;
    const b = if (two) elab_names.constInt(self, ex.rhs(sel)) orelse return false else a;
    try out.append(self.ctx.arena, .{
        .net = net,
        .sel = if (!two) .bit else if (ex.tag(sel) == .range) .range else if (ex.extraOf(sel) != 0) .down else .up,
        .a = a,
        .b = b,
    });
    return true;
}

/// Appends one analog block of unit `unit_id`. §6.6 an instance a generate
/// scheme brings into existence behaves only while the scheme holds.
fn appendAnalog(self: *Flatten, unit: *const Unit, unit_id: u32, is_initial: bool, cloned: Ast.StmtId, tok: u32) Error!void {
    const body = if (unit.gate == .none) cloned else try self.ctx.file.addStmt(self.ctx.arena, .{ .if_stmt = .{
        .cond = unit.gate,
        .then_s = cloned,
        .else_s = .none,
        .is_generate = false,
    } }, tok);
    try self.analog.append(self.ctx.arena, .{
        .is_initial = is_initial,
        .body = body,
        .main_tok = tok,
        .unit = unit_id,
    });
}

// ponytail: binding needs only the connection list and port, not flattening state.
/// Returns the connection that binds `port`, the i'th declared port, or
/// null when the list does not mention it (§6.2.2). The first entry decides
/// between named and ordered binding; a named list takes the first match.
pub fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn {
    // One binding rule for the walk and for `insert.plan`, which needs the index.
    return inst.ports[elab_insert.connIndex(inst, port, i) orelse return null];
}

// ponytail: a linear scan per connection, quadratic in one module's
// declaration count. Build a per-module set if a generated netlist puts
// thousands of nets and instances in one module.
/// Returns whether `module` declares a net `name`, as a §6.5 port or a
/// §3.6.3 net declaration (§3.6.5's test). A parameter, variable or genvar
/// is not a net, so an actual naming one is E0906, not an implicit net.
pub fn declares(module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (module.ports) |p| if (p.name == name) return true;
    for (module.nets) |n| if (n.name == name) return true;
    return false;
}

/// §6.5 "Ports provide a means of interconnecting instances of modules. If a
/// module A instantiates module B, the ports of module B are associated with
/// either the ports or the internal nets of module A." A VARIABLE of A is
/// neither, so it cannot stand as the actual of B's continuous port: there is
/// no node for the port to join (§6.5.1 lists the port expressions, every one
/// of them a net), and it is not an implicit net either (`declares`).
///
/// Only a port of CONTINUOUS discipline: a real variable driving a discrete
/// or `wreal` input is a real EXPRESSION, which §3.7 and IEEE 1364's input
/// port rules allow, and the mixed-signal kernel decides those.
fn checkVariableActuals(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance) Error!void {
    const child = elab_names.findModule(self, inst.module) orelse return;
    for (child.ports, 0..) |p, i| {
        const c = connectionFor(inst, p, i) orelse continue;
        const n = elab_names.netRefName(self, c.expr) orelse continue;
        if (declares(module, n)) continue;
        const is_var = for (module.vars) |v| {
            if (v.name == n) break true;
        } else false;
        if (!is_var or p.discipline == .none or !discipline.isContinuous(self.ctx.file, p.discipline)) continue;
        try self.err(c.main_tok, .E0906, "`{s}` is a variable, and port `{s}` of `{s}` has the continuous discipline `{s}`: it joins only a net", .{
            self.ctx.file.str(n), self.ctx.file.str(p.name), self.ctx.file.str(child.name), self.ctx.file.str(p.discipline),
        });
    }
}

/// The ways a connection list can be malformed: longer than the port list,
/// naming a port that does not exist, mixing the two spellings, or naming
/// one port twice. §6.2.2 permits it to be shorter: that is the
/// omitted-port spelling of "not to be connected".
///
/// The list's FIRST entry decides which spelling it is (`connectionFor`
/// binds by the same test), so a mix is diagnosed relative to that. §6.5.5:
/// "The two types of module port connections can not be mixed; connections
/// to the ports of a particular module instance shall be all by order or
/// all by name."
fn checkConnectionShape(self: *Flatten, inst: *const Ast.Instance, child: *const Ast.ModuleDecl) Error!void {
    const named = inst.ports.len != 0 and inst.ports[0].name != .none;
    if (!named) {
        if (inst.ports.len > child.ports.len) try self.err(
            inst.ports[child.ports.len].main_tok,
            .E0906,
            "`{s}` declares {d} port{s}, and this instance connects {d}",
            .{ self.ctx.file.str(child.name), child.ports.len, if (child.ports.len == 1) "" else "s", inst.ports.len },
        );
        // An ordered list binds by position, so a `.name(...)` inside one
        // would be ignored silently; the named loop below cannot see it.
        for (inst.ports) |c| if (c.name != .none) try self.err(
            c.main_tok,
            .E0906,
            "a named connection in a list of ordered connections",
            .{},
        );
        return;
    }
    for (inst.ports, 0..) |c, i| {
        if (c.name == .none) {
            try self.err(c.main_tok, .E0906, "an ordered connection in a list of named connections", .{});
            continue;
        }
        const found = for (child.ports) |p| {
            if (p.connName() == c.name) break true;
        } else false;
        if (!found) {
            try self.err(c.main_tok, .E0906, "`{s}` is not a port of `{s}`", .{
                self.ctx.file.str(c.name), self.ctx.file.str(child.name),
            });
            continue;
        }
        // IEEE 1364 §12.3.6: a port is connected at most once.
        // `connectionFor` takes the first match, so a second `.a(...)`
        // would otherwise be dropped silently.
        for (inst.ports[0..i]) |prev| if (prev.name == c.name) {
            try self.err(c.main_tok, .E0906, "`{s}` is connected twice", .{self.ctx.file.str(c.name)});
            break;
        };
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");

test connectionFor {
    const e1: Ast.ExprId = @fromBackingInt(@as(u32, 1));
    const e2: Ast.ExprId = @fromBackingInt(@as(u32, 2));
    const a: Ast.StrId = @fromBackingInt(@as(u32, 10));
    const b: Ast.StrId = @fromBackingInt(@as(u32, 11));
    const ordered: Ast.Instance = .{ .module = a, .name = a, .ports = &.{ .{ .expr = e1 }, .{ .expr = e2 } } };
    try std.testing.expectEqual(e2, connectionFor(&ordered, .{ .name = b }, 1).?.expr);
    try std.testing.expect(connectionFor(&ordered, .{ .name = b }, 2) == null);
    const named: Ast.Instance = .{ .module = a, .name = a, .ports = &.{ .{ .name = b, .expr = e1 }, .{ .name = a, .expr = e2 } } };
    try std.testing.expectEqual(e2, connectionFor(&named, .{ .name = a }, 0).?.expr);
    try std.testing.expectEqual(e1, connectionFor(&named, .{ .name = b }, 1).?.expr);
}

test declares {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module m(p); inout p; electrical p; electrical w; real v; endmodule");
    const m = &f.file.modules[0];
    // §3.6.5: a port and a declared net are nets; a variable is not.
    try std.testing.expect(declares(m, fixture.id(&f.file, "p").?));
    try std.testing.expect(declares(m, fixture.id(&f.file, "w").?));
    try std.testing.expect(!declares(m, fixture.id(&f.file, "v").?));
}

test substIdent {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    const a = f.arena.allocator();
    const x = &f.file.exprs;
    const na = try f.file.intern(a, "a");
    const nb = try f.file.intern(a, "b");
    const nc = try f.file.intern(a, "c");
    const ea = try x.add(a, .{ .tag = .ident, .str = na });
    const eb = try x.add(a, .{ .tag = .ident, .str = nb });
    const sum = try x.add(a, .{ .tag = .binary, .lhs = ea, .rhs = eb, .extra = @backingInt(Ast.BinaryOp.add) });
    const seven = try x.addInt(a, 0, 7);
    // Nothing named `c` below: the same row, and no row appended.
    const rows = x.nodes.len;
    try std.testing.expectEqual(sum, try substIdent(&fl, sum, nc, seven));
    try std.testing.expectEqual(rows, x.nodes.len);
    // A replaced operand gets a new row over the operand left alone.
    const out = try substIdent(&fl, sum, na, seven);
    try std.testing.expect(out != sum);
    try std.testing.expectEqual(Ast.BinaryOp.add, x.binOp(out));
    try std.testing.expectEqual(seven, x.lhs(out));
    try std.testing.expectEqual(eb, x.rhs(out));
}

test "§6.6.2 bindGenLocals reads the innermost localparam, in the scope it was declared in" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    const a = f.arena.allocator();
    const x = &f.file.exprs;
    const k = try f.file.intern(a, "k");
    const one = try x.addInt(a, 0, 1);
    const two = try x.addInt(a, 0, 2);
    const ek = try x.add(a, .{ .tag = .ident, .str = k });
    const ek_inner = try x.add(a, .{ .tag = .ident, .str = k });
    // Two blocks each declare `k`: the inner (later) one wins.
    const shadow = [_]Ast.ParamDecl{
        .{ .name = k, .ty = .integer, .default = one },
        .{ .name = k, .ty = .integer, .default = two },
    };
    try std.testing.expectEqual(two, try bindGenLocals(&fl, ek, &shadow));
    // The inner `k = k` reads the outer `k`, where it was declared.
    const nested = [_]Ast.ParamDecl{
        .{ .name = k, .ty = .integer, .default = one },
        .{ .name = k, .ty = .integer, .default = ek_inner },
    };
    try std.testing.expectEqual(one, try bindGenLocals(&fl, ek, &nested));
    // An array localparam is no scalar value to substitute.
    const array = [_]Ast.ParamDecl{.{ .name = k, .ty = .integer, .default = one, .dims = &.{.{ .msb = one, .lsb = one }} }};
    try std.testing.expectEqual(ek, try bindGenLocals(&fl, ek, &array));
}

test "§6.6 conj builds a generate block's gate: the scheme alone, negated, or under an enclosing one" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    const a = f.arena.allocator();
    const x = &f.file.exprs;
    const c = try x.add(a, .{ .tag = .ident, .str = try f.file.intern(a, "c") });
    const g = try x.add(a, .{ .tag = .ident, .str = try f.file.intern(a, "g") });
    try std.testing.expectEqual(c, try conj(&fl, .none, c, false));
    const not_c = try conj(&fl, .none, c, true);
    try std.testing.expectEqual(Ast.UnaryOp.logical_not, x.unOp(not_c));
    try std.testing.expectEqual(c, x.lhs(not_c));
    const both = try conj(&fl, g, c, true);
    try std.testing.expectEqual(Ast.BinaryOp.logical_and, x.binOp(both));
    try std.testing.expectEqual(g, x.lhs(both));
    try std.testing.expectEqual(Ast.UnaryOp.logical_not, x.unOp(x.rhs(both)));
}

test "§6.2.2 an instance array is one instance per element, lowest index first; a range that does not fold is E0909" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u[1:0](p); endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 3), d.units.len);
    try std.testing.expectEqualStrings("u[0].", d.units[1].path);
    try std.testing.expectEqualStrings("u[1].", d.units[2].path);

    var g: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try fixture.parse(&g,
        \\module top(p); inout p; electrical p; real r; kid u[r:0](p); endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(g.ctx()));
    try std.testing.expect(fixture.hasCode(&g.bag, .E0909));
}

test "§6.5.5 a connection list is all ordered or all named, at most as long as the ports, each port once (E0906)" {
    const src =
        \\module top(p); inout p; electrical p; kid u{s}; endmodule
        \\module kid(a, b); inout a, b; electrical a, b; endmodule
    ;
    for ([_][]const u8{
        "(p, p, p)", // longer than the port list
        "(p, .b(p))", // a named connection in an ordered list
        "(.a(p), p)", // an ordered connection in a named list
        "(.zz(p))", // no such port
        "(.a(p), .a(p))", // IEEE 1364 §12.3.6 connected twice
    }) |conns| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{conns}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
        try std.testing.expect(fixture.hasCode(&f.bag, .E0906));
    }
    // §6.2.2 permits a shorter list: `b` is then unconnected.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"(.a(p))"}));
    _ = try elaborate.elaborate(good.ctx());
}

test "§6.5 a variable cannot stand for a continuous port (E0906); a net can" {
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p); inout p; ca p; {s} kid u(x); endmodule
        \\module kid(a); inout a; ca a; endmodule
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"real x;"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0906));

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"ca x;"}));
    _ = try elaborate.elaborate(good.ctx());
}

test "§6.2.2 a blank connection is an internal net and §9.19 $port_connected says so" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p, ); endmodule
        \\module kid(a, b); inout a; input b; electrical a, b;
        \\  analog I(a) <+ $port_connected(a);
        \\  analog I(a) <+ $port_connected(b);
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    // The input `b` is "not to be connected": its own net, judged later
    // against IEEE 1364 §19.9 `unconnected_drive`.
    try std.testing.expectEqual(@as(usize, 1), d.unconnected_inputs.len);
    try std.testing.expectEqualStrings("u.b", d.unconnected_inputs[0].name);
    try std.testing.expect(fixture.netNamed(&f.file, d.top, "u.b") != null);
    const x = &f.file.exprs;
    try std.testing.expectEqual(@as(i64, 1), x.intValue(f.file.stmt(d.top.analog[0].body).contribute.rhs));
    try std.testing.expectEqual(@as(i64, 0), x.intValue(f.file.stmt(d.top.analog[1].body).contribute.rhs));
}

test "§3.6.5 an actual the parent never declared is an implicit net, reported and given the port's discipline" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(q); endmodule
        \\module kid(a); inout a; electrical a; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), d.implicit_nets.len);
    try std.testing.expectEqualStrings("q", d.implicit_nets[0].name);
    try std.testing.expectEqualStrings("electrical", f.file.str(fixture.netNamed(&f.file, d.top, "q").?.discipline));
}

test "§6.5.7.1 a concatenation or a constant select binds a port to parts of parent nets" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline electrical; domain continuous; enddiscipline
        \\module top(a, b); inout a, b; electrical a, b; electrical [3:0] bus;
        \\  kid u({a, b}); one w1(bus[1]); one w2(bus[3:2]); one w3(bus[1 +: 2]); one w4(bus[3 -: 2]);
        \\endmodule
        \\module kid(v); inout [1:0] v; electrical [1:0] v; endmodule
        \\module one(s); inout s; electrical s; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const NetPart = elaborate.NetPart;
    const Want = struct { name: []const u8, vector: bool, parts: []const NetPart };
    const want = [_]Want{
        .{ .name = "u.v", .vector = true, .parts = &.{ .{ .net = "a" }, .{ .net = "b" } } },
        .{ .name = "w1.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .bit, .a = 1, .b = 1 }} },
        .{ .name = "w2.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .range, .a = 3, .b = 2 }} },
        .{ .name = "w3.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .up, .a = 1, .b = 2 }} },
        .{ .name = "w4.s", .vector = false, .parts = &.{.{ .net = "bus", .sel = .down, .a = 3, .b = 2 }} },
    };
    try std.testing.expectEqual(want.len, d.port_concats.len);
    for (want, d.port_concats) |w, got| {
        try std.testing.expectEqualStrings(w.name, got.name);
        try std.testing.expectEqual(w.vector, got.range != null);
        try std.testing.expectEqual(w.parts.len, got.parts.len);
        for (w.parts, got.parts) |wp, gp| {
            try std.testing.expectEqualStrings(wp.net, gp.net);
            try std.testing.expectEqual(wp.sel, gp.sel);
            try std.testing.expectEqual(wp.a, gp.a);
            try std.testing.expectEqual(wp.b, gp.b);
        }
    }
}

test "§6.7.1 a connected port's path names the parent's net; an internal net needs no row" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline electrical; domain continuous; enddiscipline
        \\module top(p, n); inout p, n; electrical p, n; kid u(p, n); endmodule
        \\module kid(a, b); inout a, b; electrical a, b; electrical w; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(u32, 2), d.names.count());
    try std.testing.expectEqualStrings("p", d.names.get("u.a").?);
    try std.testing.expectEqualStrings("n", d.names.get("u.b").?);
    try std.testing.expect(d.names.get("u.w") == null);
    try std.testing.expect(fixture.netNamed(&f.file, d.top, "u.w") != null);
    // §6.5.7.1 one size check per port bound to a net.
    try std.testing.expectEqual(@as(usize, 2), d.port_widths.len);
    try std.testing.expectEqualStrings("p", d.port_widths[0].net);
    try std.testing.expect(d.port_widths[0].range == null);
}

test "§6.6 a module instance with discrete behavior under a generate scheme is E0235" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; parameter integer sel = 1;
        \\  generate if (sel) begin kid u(p); end endgenerate
        \\endmodule
        \\module kid(a); inout a; electrical a; reg q; initial q = 0; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
    try std.testing.expect(fixture.hasCode(&f.bag, .E0235));
}

test "§6.4.3 a paramset variable without a description hides the module's variable of that name" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; ps u(p); endmodule
        \\paramset ps dev; real id; .scale = 4.0; endparamset
        \\module dev(a); inout a; electrical a; parameter real scale = 1.0; real id;
        \\  analog begin id = scale * V(a); I(a) <+ id; end
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), d.ps_hidden.len);
    try std.testing.expectEqualStrings("u.id", d.ps_hidden[0]);
    const scale = fixture.paramNamed(&f.file, d.top, "u.scale").?;
    try std.testing.expect(scale.is_override);
    try std.testing.expectEqual(@as(f64, 4.0), f.file.exprs.realValue(scale.default));
}
