//! The instance walk: one module's instance list → every reachable instance
//! inlined into the flat module, depth first in source order. Per level it
//! records the level's §6.3.1 defparams and Annex F.2.1 out-of-context
//! declarations, plans §7.8.4 connect modules, then per instance binds the
//! ports (§6.2.2), applies the overrides (§6.3, §6.4), names every
//! declaration (§6.7), clones the body (`clone.zig`) and recurses.
//! LRM §3.6.5, §6.2.2, §6.3, §6.3.1, §6.4, §6.4.3, §6.5, §6.5.5, §6.5.7.1,
//! §6.6, §6.7.1, §7.1, §7.8.4, §9.15, §9.19, A.4.1, A.5.4, Annex E.3.2;
//! IEEE 1364-2005 §12.3.3, §12.3.6, §19.9.

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
/// ponytail: if-generate only. A loop or case generate's instance is
/// E0235 (`refuseGen`): the loop needs one renamed instance per
/// iteration, the case an equality chain per arm.
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
        .for_stmt => |s| try refuseGen(self, s.body),
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

    // §7.8.4 connect modules are inserted "in the context of the ports
    // upper connection", which is this module: `plan` re-points each mixed
    // port at a digital segment and appends the bridges, which then inline
    // like any child. Indices past `module.instances.len` are those.
    const insts = try elab_insert.plan(self, module, path);

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

    // The planned instances, then the §6.6 generate instances, whose schemes
    // `gates` holds in parallel from index `insts.len` on.
    var all: std.ArrayList(Ast.Instance) = .empty;
    try all.appendSlice(self.ctx.arena, insts);
    var gates: std.ArrayList(Ast.ExprId) = .empty;
    for (module.analog) |blk| try genInstances(self, blk.body, .none, "", &.{}, &all, &gates);
    std.debug.assert(all.items.len == insts.len + gates.items.len);
    for (all.items, 0..) |inst, idx| {
        const auto = idx >= module.instances.len and idx < insts.len;
        const gate: Ast.ExprId = if (idx < insts.len) .none else gates.items[idx - insts.len];
        // §3.6.5, the structural half: an actual that names nothing `module`
        // declared is an implicit net (see `Design.implicit_nets`).
        // Collected here, not in `inlineInstance`, because only this loop
        // still has `module` in hand; one level down the names are flat.
        // Reads the source's own connections, not `plan`'s segments.
        if (!auto and idx < module.instances.len) try checkVariableActuals(self, module, &module.instances[idx]);
        if (!auto) for ((if (idx < module.instances.len) module.instances[idx] else inst).ports) |c| {
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
    };

    // ---- §6.2.2 port connections ---------------------------------------
    // Resolved in the PARENT's namespace, which means through the parent's
    // rename map: an actual naming a net of a mid-level module has already
    // been flattened to `u.n`.
    // At most one of each per child port.
    var concats: std.ArrayList(struct { port: Ast.Port, elems: []const []const u8, tok: u32 }) = try .initCapacity(self.ctx.arena, child.ports.len);
    var widths: std.ArrayList(struct { port: Ast.Port, net: Ast.StrId, tok: u32 }) = try .initCapacity(self.ctx.arena, child.ports.len);
    for (child.ports, 0..) |p, i| {
        const conn = connectionFor(inst, p, i);
        try unit.connected.put(self.ctx.arena, p.name, conn != null and conn.?.expr != .none);
        // §6.5.7.1 a concatenated net expression: each operand a net of the
        // parent, bound element by element once the child's range is known.
        if (conn) |c| if (c.expr != .none and self.ctx.file.exprs.tag(c.expr) == .concat) {
            const ops = self.ctx.file.exprs.args(c.expr);
            const elems = try self.ctx.arena.alloc([]const u8, ops.len);
            for (ops, elems) |o, *el| {
                const n = elab_names.netRefName(self, o) orelse {
                    try self.err(c.main_tok, .E0906, "a concatenation in a port connection must list scalar net references", .{});
                    break;
                };
                el.* = self.ctx.file.str(parent.rename.get(n) orelse n);
            } else {
                if (p.range == null and p.type_range == null) {
                    try self.err(c.main_tok, .E0906, "a concatenation connects only a vector port, and `{s}` is scalar", .{self.ctx.file.str(p.name)});
                    continue;
                }
                try unit.rename.put(self.ctx.arena, p.name, try elab_names.join(self, path, p.name));
                const local = elab_resolve.oocDiscipline(self, path, p.name) orelse p.discipline;
                if (local != .none) try unit.port_disc.put(self.ctx.arena, p.name, local);
                concats.appendAssumeCapacity(.{ .port = p, .elems = elems, .tok = c.main_tok });
            }
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
    if (ps) |p|
        try elab_paramset.paramsetOverrides(self, inst, p, child, &parent, &over, &unit, path)
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
            .range = (try elab_clone.cloneDim(self, cc.port.range orelse cc.port.type_range)).?,
            .elems = cc.elems,
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
        if (!again) try self.vars.append(self.ctx.arena, out);
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
    for (child.analog) |blk| {
        var body = try elab_clone.cloneStmt(self, blk.body);
        // §6.6 an instance a generate scheme brings into existence behaves
        // only while the scheme holds.
        if (unit.gate != .none) body = try self.ctx.file.addStmt(self.ctx.arena, .{ .if_stmt = .{
            .cond = unit.gate,
            .then_s = body,
            .else_s = .none,
            .is_generate = false,
        } }, blk.main_tok);
        try self.analog.append(self.ctx.arena, .{
            .is_initial = blk.is_initial,
            .body = body,
            .main_tok = blk.main_tok,
            .unit = unit_id,
        });
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

// ponytail: binding needs only the connection list and port, not flattening state.
/// Returns the connection that binds `port`, the i'th declared port, or
/// null when the list does not mention it (§6.2.2). The first entry decides
/// between named and ordered binding; a named list takes the first match.
pub fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn {
    const named = inst.ports.len != 0 and inst.ports[0].name != .none;
    if (!named) return if (i < inst.ports.len) inst.ports[i] else null;
    for (inst.ports) |c| if (c.name == port.name) return c;
    return null;
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
            if (p.name == c.name) break true;
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
