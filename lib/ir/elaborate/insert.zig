//! §7.8 automatic insertion of connect modules: one module's instance list →
//! the same list with every mixed port re-pointed at a new segment, plus one
//! synthetic instance of the selected connect module per segment for the
//! flatten to inline like any other child. LRM §3.11.1, §7.6, §7.7.1, §7.7.3,
//! §7.8.1 to §7.8.5.

const std = @import("std");
const hier_param = @import("../hier_param.zig");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_resolve = @import("resolve.zig");
const elab_paramset = @import("paramset.zig");
const discipline = @import("../discipline_rules.zig");
const Ast = @import("frontend").Ast;
const Error = elaborate.Error;
const sep = elaborate.sep;

/// One connect statement, read as §7.6's Table 7-2 pair: which of the connect
/// module's two ports is continuous and which discrete, with the discipline and
/// direction each has after §7.7.1's overrides.
const Rule = struct {
    ins: *const Ast.ConnectInsertion,
    module: *const Ast.ModuleDecl,
    cont: Side,
    disc: Side,

    const Side = struct { port: Ast.StrId, discipline: Ast.StrId, dir: Ast.Direction };
};

/// One mixed port that matched exactly one rule.
const Hit = struct {
    inst: usize,
    conn: usize,
    rule: usize,
    /// The upper connection, a name in THIS module (§7.8.5's SigName).
    sig: Ast.StrId,
    /// The lower connection's discipline (§7.8.5's BottomDiscipline).
    bottom: Ast.StrId,
    port: Ast.StrId,
};

/// The instances of `module` as §7.8.4 leaves them: every port matched by a
/// connect statement is bound to a fresh digital segment instead of its upper
/// connection, and the connect module instances bridging the two are appended
/// after the originals, so `module.instances.len` is the index at which the
/// auto-inserted ones begin. Returns `module.instances` itself when nothing is
/// mixed; otherwise the list is new, in the arena. Reports E0922 for a port
/// that matches more than one connect statement.
///
/// §7.8.4: "A connection shall be selected for a port only
/// if one of the connections to the port is digital and the other is analog.
/// In this case, the port shall match one (and only one) connect statement";
/// "The connect module for a port shall be instantiated in the context of the
/// ports upper connection" (this module); "All ports connecting to the same
/// signal (upper connection), sharing the same connect module, and having
/// merged parameter shall share a single instance of the selected connect
/// module. All other ports shall have an instance of the selected connect
/// module".
///
/// A port no statement matches is left joined and recorded in
/// `unbridged`: whether it is mixed is known only once §7.4 has resolved
/// its net, and `checkUnbridged` judges it then (E0927).
///
/// An undeclared upper connection takes §7.4.4.1's basic answer at this
/// level (`levelDiscipline`) so a statement can match it; the resolution
/// proper still runs as the children are bound.
///
/// ponytail: rules are read only from connect modules with exactly one
/// continuous and one discrete port (every §7.6 example), and a port is judged
/// only when both of its connections declare a discipline. Supply-sensitive
/// bridges with a third port (§7.8.6) and the Figure 7-6 coercion through
/// undeclared interconnect are the upgrade.
pub fn plan(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) Error![]const Ast.Instance {
    var rules: std.ArrayList(Rule) = .empty;
    for (self.ctx.file.connectrules) |cr| for (cr.insertions) |*ins| {
        // `checkConnectRules` has reported what is wrong with a statement;
        // here a refused one simply bridges nothing.
        const r = try ruleOf(self, ins, false) orelse continue;
        if (!try paramsDeclared(self, ins, r.module, false)) continue;
        try rules.append(self.ctx.arena, r);
    };
    const file = self.ctx.file;
    var hits: std.ArrayList(Hit) = .empty;
    for (module.instances, 0..) |inst, ii| {
        const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, file.str(inst.name), elaborate.sep });
        const child = try moduleOf(self, &inst, child_path) orelse continue;
        if (child.is_connect) continue;
        for (child.ports, 0..) |p, pi| {
            const ci = connIndex(&inst, p, pi) orelse continue;
            const sig = elab_names.netRefName(self, inst.ports[ci].expr) orelse continue;
            const bound = self.unit.rename.get(sig) orelse sig;
            const lower = p.discipline;
            const lo_d = domain(file, lower) orelse continue;
            const unbridged: Unbridged = .{ .tok = inst.ports[ci].main_tok, .net = bound, .lower = lower, .port = p.name, .inst = inst.name, .dir = p.direction };
            const upper = self.disc_of.get(bound) orelse levelDiscipline(self, module, sig) orelse {
                try self.unbridged.append(self.ctx.arena, unbridged);
                continue;
            };
            const up_d = domain(file, upper) orelse continue;
            if (up_d == lo_d) {
                // Not mixed yet: an undeclared net may still resolve continuous.
                try self.unbridged.append(self.ctx.arena, unbridged);
                continue;
            }
            var found: ?usize = null;
            var count: usize = 0;
            for (rules.items, 0..) |r, ri| if (matches(file, r, p.direction, upper, lower)) {
                count += 1;
                if (found == null) found = ri;
            };
            if (count > 1) {
                try self.err(inst.ports[ci].main_tok, .E0922, "port `{s}` of `{s}` matches more than one connect statement ({d})", .{
                    file.str(p.name), file.str(inst.name), count,
                });
                continue;
            }
            try hits.append(self.ctx.arena, .{
                .inst = ii,
                .conn = ci,
                .rule = found orelse {
                    try self.unbridged.append(self.ctx.arena, unbridged);
                    continue;
                },
                .sig = sig,
                .bottom = lower,
                .port = p.name,
            });
        }
    }
    if (hits.items.len == 0) return module.instances;

    // Copies of the originals, whose connection lists the segments rewrite.
    var out: std.ArrayList(Ast.Instance) = .empty;
    try out.appendSlice(self.ctx.arena, module.instances);
    const conns = try self.ctx.arena.alloc([]Ast.PortConn, out.items.len);
    for (out.items, conns) |*inst, *c| {
        c.* = try self.ctx.arena.dupe(Ast.PortConn, inst.ports);
        inst.ports = c.*;
    }

    for (hits.items, 0..) |h, hi| {
        const r = rules.items[h.rule];
        // The bridge's port that faces the lower connection, and the one that
        // takes the upper: the discrete port when the child's side is digital,
        // the continuous one when it is analog (m03_09's shape).
        const low_analog = domain(file, h.bottom) == .continuous;
        const lower_port, const upper_port = if (low_analog) .{ r.cont.port, r.disc.port } else .{ r.disc.port, r.cont.port };
        // §7.8.3 "The default is merged." And §7.8.2 overrides `split` on an
        // analog lower connection: "there shall never be more than one analog
        // node representing a signal", so those ports always share one.
        // ponytail: §7.8.3.2 Example 3 leaves the instance count of an analog
        // split unstated; one is the count that keeps the node count right.
        const merged = r.ins.mode != .split or low_analog;
        // A merged port joins the bridge an earlier port of its group made.
        const first = if (merged) for (hits.items[0..hi]) |g| {
            if (g.sig == h.sig and g.rule == h.rule and g.bottom == h.bottom) break g;
        } else null else null;
        const conn = &conns[h.inst][h.conn];
        const up_expr = conn.expr;
        const name = try segmentName(self, path, r, merged, lower_port, h, if (first) |g| g else h, out.items);
        conn.expr = try ident(self, name.segment, conn.main_tok);
        try self.inserts.append(self.ctx.arena, .{
            .path = path,
            .inst = file.str(out.items[h.inst].name),
            .port = file.str(h.port),
            .module = file.str(r.module.name),
            .name = file.str(name.instance),
            .upper_port = file.str(upper_port),
            .lower_port = file.str(lower_port),
        });
        if (first != null) continue;

        try elab_resolve.addNet(self, .{ .name = name.segment, .discipline = h.bottom, .main_tok = conn.main_tok });
        const ports = try self.ctx.arena.alloc(Ast.PortConn, 2);
        ports[0] = .{ .name = upper_port, .expr = up_expr, .main_tok = conn.main_tok };
        ports[1] = .{ .name = lower_port, .expr = try ident(self, name.segment, conn.main_tok), .main_tok = conn.main_tok };
        try out.append(self.ctx.arena, .{
            .module = r.module.name,
            .name = name.instance,
            // §7.7.3 "An attribute method can be used with the connect
            // statement to specify parameter values to pass into the
            // Verilog-AMS HDL connect module".
            .params = r.ins.params,
            .ports = ports,
            .main_tok = conn.main_tok,
        });
    }
    return out.items;
}

/// A child port `plan` bridged with nothing, as `checkUnbridged` reads it.
pub const Unbridged = struct {
    tok: u32,
    /// The flat net the port joins.
    net: Ast.StrId,
    /// The port's own discipline: its lower connection.
    lower: Ast.StrId,
    port: Ast.StrId,
    inst: Ast.StrId,
    dir: Ast.Direction,
};

/// §7.8.4 "the port shall match one (and only one) connect statement", the
/// zero-match half (E0922 is the other), and §6.5.7 "Ports of both analog
/// and digital discipline may be connected to a net provided the
/// appropriate connect statements exist". Run after §7.4 resolution, since
/// a port is mixed by the disciplines its net resolved to, not by what
/// crosses it.
pub fn checkUnbridged(self: *Flatten) Error!void {
    const file = self.ctx.file;
    for (self.unbridged.items) |u| {
        const upper = self.disc_of.get(u.net) orelse continue;
        const up_d = domain(file, upper) orelse continue;
        const lo_d = domain(file, u.lower).?;
        if (up_d == lo_d or up_d == .unspecified or lo_d == .unspecified) continue;
        // A statement that matches, which `plan` could not apply: the net
        // resolved continuous above the level that elaborated this port.
        const rule = find: {
            for (file.connectrules) |cr| for (cr.insertions) |*ins| {
                const r = try ruleOf(self, ins, false) orelse continue;
                if (matches(file, r, u.dir, upper, u.lower)) break :find r;
            };
            break :find null;
        };
        if (rule) |r| {
            try self.err(u.tok, .E0929, "`{s}` matches port `{s}` of `{s}` (`{s}`), but its net `{s}` resolved `{s}` above the level that elaborated the port", .{
                file.str(r.module.name), file.str(u.port), file.str(u.inst), file.str(u.lower), file.str(u.net), file.str(upper),
            });
            continue;
        }
        try self.err(u.tok, .E0927, "port `{s}` of `{s}` is `{s}` and its net `{s}` is `{s}`, and no connect statement bridges them", .{
            file.str(u.port), file.str(u.inst), file.str(u.lower), file.str(u.net), file.str(upper),
        });
    }
}

/// §7.4.4.1 basic mode at this level, for an upper connection no
/// declaration has reached yet: "At each level of the hierarchy where
/// continuous and discrete meet for an undeclared net that net segment is
/// declared continuous". The first continuous discipline a child port of
/// `module` brings to `sig`, else null (the net is not continuous here, so
/// no port of it is mixed yet).
fn levelDiscipline(self: *Flatten, module: *const Ast.ModuleDecl, sig: Ast.StrId) ?Ast.StrId {
    for (module.instances) |inst| {
        const child = elab_names.findModule(self, inst.module) orelse continue;
        if (child.is_connect) continue;
        for (child.ports, 0..) |p, pi| {
            const ci = connIndex(&inst, p, pi) orelse continue;
            if (elab_names.netRefName(self, inst.ports[ci].expr) != sig) continue;
            if (domain(self.ctx.file, p.discipline) == .continuous) return p.discipline;
        }
    }
    return null;
}

/// The module `inst` elaborates to: the one it names, or (§6.9.3) the module
/// at the end of the paramset §6.4.2 selects for it. "Automatic insertion of
/// connect modules is a post-elaboration operation ... It should also occur
/// after the paramset selection as the choice for a particular module
/// instantiation may affect the disciplines of the connected nets." The ports
/// whose disciplines decide whether a connection is mixed are the selected
/// module's.
///
/// Quiet: selection proper (`elab_paramset.selectParamset`) runs again when the
/// instance is inlined and reports anything wrong there, once. A set that does
/// not narrow to one paramset here inserts nothing.
fn moduleOf(self: *Flatten, inst: *const Ast.Instance, path: []const u8) Error!?*const Ast.ModuleDecl {
    if (elab_names.findModule(self, inst.module)) |m| return m;
    var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    _ = try elab_paramset.matchingParamsets(self, inst, path, &live);
    if (live.items.len != 1) return null;
    // The chain, walked without `paramsetChain`'s diagnostics; a chain that
    // never reaches a module is E0904 at inlining.
    var link = live.items[0];
    for (0..self.ctx.file.paramsets.len + 1) |_| {
        if (elab_names.findModule(self, link.target)) |m| return m;
        link = for (self.ctx.file.paramsets) |*p| {
            if (p.name == link.target) break p;
        } else return null;
    }
    return null;
}

/// §7.8.5's generated instance name, and the flat name of the segment it
/// bridges to the lower connections (its `lower_port`, seen from inside it).
///
///     merged  SigName__ModuleName__BottomDiscipline
///     split   SigName__InstName__PortName
fn segmentName(
    self: *Flatten,
    path: []const u8,
    r: Rule,
    merged: bool,
    lower_port: Ast.StrId,
    h: Hit,
    owner: Hit,
    insts: []const Ast.Instance,
) Error!struct { instance: Ast.StrId, segment: Ast.StrId } {
    const file = self.ctx.file;
    const a = self.ctx.arena;
    const leaf = if (!merged)
        try a.print("{s}__{s}__{s}", .{ file.str(h.sig), file.str(insts[h.inst].name), file.str(h.port) })
    else
        try a.print("{s}__{s}__{s}", .{ file.str(owner.sig), file.str(r.module.name), file.str(owner.bottom) });
    return .{
        .instance = try file.intern(a, leaf),
        .segment = try file.intern(a, try a.print("{s}{s}{c}{s}", .{ path, leaf, sep, file.str(lower_port) })),
    };
}

fn ident(self: *Flatten, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
    return self.ctx.file.exprs.add(self.ctx.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
}

/// The index into `inst.ports` that binds `p`, the `pi`'th declared port.
fn connIndex(inst: *const Ast.Instance, p: Ast.Port, pi: usize) ?usize {
    const named = inst.ports.len != 0 and inst.ports[0].name != .none;
    if (!named) return if (pi < inst.ports.len) pi else null;
    for (inst.ports, 0..) |c, i| if (c.name == p.name) return i;
    return null;
}

fn domain(file: *const Ast.SourceFile, d: Ast.StrId) ?Ast.DisciplineDecl.Domain {
    return discipline.domainOf(discipline.declOf(file, d) orelse return null);
}

/// Reads a §7.7.1 connect statement as a `Rule`: the module's two ports split
/// into the continuous and the discrete side (§7.6 "The port disciplines define the
/// default type of disciplines which shall be bridged by the connect module.
/// The directional qualifiers of the discrete port determine the default
/// scenarios"), then the statement's overrides applied by domain ("one shall
/// be discrete and the other continuous"). Null for a statement this pass
/// cannot read: an unknown module was E0915 already. `report` is true for the
/// one call per statement `checkConnectRules` makes, so a conflicting override
/// is diagnosed once per compilation and not once per module that has ports.
pub fn ruleOf(self: *Flatten, ins: *const Ast.ConnectInsertion, report: bool) Error!?Rule {
    const file = self.ctx.file;
    const m = elab_names.findModule(self, ins.module) orelse return null;
    if (!m.is_connect or m.ports.len != 2) return null;
    var cont: ?Rule.Side = null;
    var disc: ?Rule.Side = null;
    for (m.ports) |p| {
        const side: Rule.Side = .{ .port = p.name, .discipline = p.discipline, .dir = p.direction };
        switch (domain(file, p.discipline) orelse return null) {
            .continuous => cont = side,
            .discrete => disc = side,
            .unspecified => return null,
        }
    }
    var r: Rule = .{ .ins = ins, .module = m, .cont = cont orelse return null, .disc = disc orelse return null };
    if (ins.overrides) |o| for ([_]struct { Ast.Direction, Ast.StrId }{ .{ o.a_dir, o.a }, .{ o.b_dir, o.b } }) |ov| {
        const side = switch (domain(file, ov[1]) orelse return null) {
            .continuous => &r.cont,
            .discrete => &r.disc,
            .unspecified => return null,
        };
        // "the specified disciplines shall be compatible for both the
        // continuous and discrete disciplines of the given connect module"
        if (discipline.disciplineConflict(file, side.discipline, ov[1])) |why| {
            if (report) try self.err(ins.main_tok, .E0915, "`{s}` cannot stand for `{s}`'s `{s}` ({s})", .{
                file.str(ov[1]), file.str(m.name), file.str(side.discipline), why,
            });
            return null;
        }
        side.discipline = ov[1];
        if (ov[0] != .unspecified) side.dir = ov[0];
    };
    return r;
}

/// §7.6 Table 7-2, "The following combinations of directional qualifiers are
/// supported for the continuous and discrete disciplines of a connect module":
/// input/output, output/input, inout/inout, read after §7.7.1's direction
/// overrides, which "are used to define the type of connect module". Any other
/// pair names no scenario the module could be inserted in, so the statement
/// is refused (E0982). A port with no direction is not judged here.
pub fn checkDirections(self: *Flatten, r: Rule) Error!void {
    const c = r.cont.dir;
    const d = r.disc.dir;
    if (c == .unspecified or d == .unspecified) return;
    if ((c == .input and d == .output) or (c == .output and d == .input) or (c == .inout and d == .inout)) return;
    const file = self.ctx.file;
    try self.err(r.ins.main_tok, .E0982, "`{s}`'s continuous port `{s}` is `{t}` and its discrete port `{s}` is `{t}`", .{
        file.str(r.module.name), file.str(r.cont.port), c, file.str(r.disc.port), d,
    });
}

/// §7.7.3 "Any parameters declared in the connect module can be specified":
/// the statement's `#(...)` is an A.4.1 parameter_value_assignment on the
/// module it names, so a name that module does not declare, a localparam
/// (§3.4.5) or an ordered list longer than its overridable parameters is the
/// same E0907 an instance gets, judged at the statement whether or not any
/// port selects it. `report` as in `ruleOf`. Returns whether every entry
/// named an overridable parameter.
pub fn paramsDeclared(self: *Flatten, ins: *const Ast.ConnectInsertion, m: *const Ast.ModuleDecl, report: bool) Error!bool {
    const file = self.ctx.file;
    if (ins.params.len == 0) return true;
    const named = ins.params[0].name != .none;
    if (!named) {
        var n: usize = 0;
        for (m.params) |p| if (!p.is_local) {
            n += 1;
        };
        if (ins.params.len <= n) return true;
        if (report) try self.err(ins.params[n].main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this connect statement sets {d}", .{
            file.str(m.name), n, if (n == 1) "" else "s", ins.params.len,
        });
        return false;
    }
    var ok = true;
    for (ins.params) |o| {
        var target = o.name;
        for (m.aliasparams) |al| if (al.alias == o.name) {
            target = al.target;
            break;
        };
        if (hier_param.Kind.fromName(file.str(target)) != null) continue;
        const decl = for (m.params) |*p| {
            if (p.name == target) break p;
        } else null;
        if (decl != null and !decl.?.is_local) continue;
        ok = false;
        if (report) try self.err(o.main_tok, .E0907, "`{s}` is {s} of connect module `{s}`", .{
            file.str(o.name), if (decl == null) "not a parameter" else "a localparam", file.str(m.name),
        });
    }
    return ok;
}

/// Does connect rule `r` bridge a port of direction `dir` whose upper and
/// lower connections have these disciplines? §7.6's three examples, which
/// state the matching in terms of data flow: a d2a (discrete input, continuous
/// output) "can bridge a mixed input port whose upper connection is compatible
/// with discipline ddiscrete and whose lower connection is compatible with
/// electrical, or a mixed output port whose upper connection is compatible
/// with discipline electrical and whose lower connection is compatible with
/// ddiscrete"; an inout/inout bidir "can bridge any mixed port". So the rule's
/// input side faces the port's source: the upper connection of an input port,
/// the lower of an output port. "Compatible" is §3.11.1's.
fn matches(file: *const Ast.SourceFile, r: Rule, dir: Ast.Direction, upper: Ast.StrId, lower: Ast.StrId) bool {
    const compat = struct {
        fn f(fl: *const Ast.SourceFile, a: Ast.StrId, b: Ast.StrId) bool {
            return discipline.disciplineConflict(fl, a, b) == null and domain(fl, a) == domain(fl, b);
        }
    }.f;
    if (r.cont.dir == .inout and r.disc.dir == .inout) {
        const c, const d = if (domain(file, upper) == .continuous) .{ upper, lower } else .{ lower, upper };
        return compat(file, r.cont.discipline, c) and compat(file, r.disc.discipline, d);
    }
    const in_side, const out_side = if (r.cont.dir == .input and r.disc.dir == .output)
        .{ r.cont, r.disc }
    else if (r.cont.dir == .output and r.disc.dir == .input)
        .{ r.disc, r.cont }
    else
        return false; // not a Table 7-2 combination
    const source, const sink = switch (dir) {
        .input => .{ upper, lower },
        .output => .{ lower, upper },
        // A unidirectional bridge does not cover an inout port, and a port
        // with no direction has no source side to face.
        .inout, .unspecified => return false,
    };
    return compat(file, in_side.discipline, source) and compat(file, out_side.discipline, sink);
}
