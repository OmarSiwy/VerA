//! §7.8 automatic insertion of connect modules.
//!
//! In: one module's instance list, at one level of the hierarchy. Out: the same
//! list with every mixed port re-pointed at a digital segment, plus one
//! synthetic instance of the selected connect module per segment, for the
//! ordinary flatten to inline like any other child.
//!
//! LRM clauses this file's code cites: §3.11.1, §7.6, §7.7.1, §7.7.3, §7.7.4, §7.8, §7.8.1, §7.8.2, §7.8.3, §7.8.4, §7.8.5.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_resolve = @import("resolve.zig");
const discipline = @import("../lower/discipline.zig");
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
/// AFTER the originals, so `module.instances.len` is the index at which the
/// auto-inserted ones begin. `module.instances` itself when nothing is mixed.
///
/// §7.8.4, whose rules this is: "A connection shall be selected for a port only
/// if one of the connections to the port is digital and the other is analog.
/// In this case, the port shall match one (and only one) connect statement";
/// "The connect module for a port shall be instantiated in the context of the
/// ports upper connection" (this module); "All ports connecting to the same
/// signal (upper connection), sharing the same connect module, and having
/// merged parameter shall share a single instance of the selected connect
/// module. All other ports shall have an instance of the selected connect
/// module".
///
/// A mixed port no statement matches is left joined, as it was before this
/// pass existed: the discipline resolution of §7.4 still judges it.
///
/// ponytail: rules are read only from connect modules with exactly one
/// continuous and one discrete port (every §7.6 example), and a port is judged
/// only when both of its connections declare a discipline. Supply-sensitive
/// bridges with a third port (§7.8.6) and the Figure 7-6 coercion through
/// undeclared interconnect are the upgrade.
pub fn plan(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) Error![]const Ast.Instance {
    var rules: std.ArrayList(Rule) = .empty;
    for (self.ctx.file.connectrules) |cr| for (cr.insertions) |*ins| {
        if (try ruleOf(self, ins)) |r| try rules.append(self.ctx.arena, r);
    };
    if (rules.items.len == 0) return module.instances;

    const file = self.ctx.file;
    var hits: std.ArrayList(Hit) = .empty;
    for (module.instances, 0..) |inst, ii| {
        const child = elab_names.findModule(self, inst.module) orelse continue;
        if (child.is_connect) continue;
        for (child.ports, 0..) |p, pi| {
            const ci = connIndex(&inst, p, pi) orelse continue;
            const sig = elab_names.netRefName(self, inst.ports[ci].expr) orelse continue;
            const upper = self.disc_of.get(self.unit.rename.get(sig) orelse sig) orelse continue;
            const lower = p.discipline;
            const up_d = domain(file, upper) orelse continue;
            const lo_d = domain(file, lower) orelse continue;
            if (up_d == lo_d) continue; // not a mixed port
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
                .rule = found orelse continue,
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
        // The bridge's port that faces the LOWER connection, and the one that
        // takes the upper: the discrete port when the child's side is digital,
        // the continuous one when it is analog (m03_09's shape).
        const low_analog = domain(file, h.bottom) == .continuous;
        const lower_port, const upper_port = if (low_analog) .{ r.cont.port, r.disc.port } else .{ r.disc.port, r.cont.port };
        // §7.8.3 "The default is merged." And §7.8.2 overrides `split` on an
        // analog lower connection: "there shall never be more than one analog
        // node representing a signal", so those ports always share one.
        // ponytail: §7.8.3.2 Example 3 leaves the INSTANCE count of an analog
        // split unstated; one is the count that keeps the node count right.
        const merged = r.ins.mode != .split or low_analog;
        // A merged port joins the bridge an EARLIER port of its group made.
        const first = if (merged) for (hits.items[0..hi]) |g| {
            if (g.sig == h.sig and g.rule == h.rule and g.bottom == h.bottom) break g;
        } else null else null;
        const conn = &conns[h.inst][h.conn];
        const up_expr = conn.expr;
        const name = try segmentName(self, path, r, merged, lower_port, h, if (first) |g| g else h, out.items);
        conn.expr = try ident(self, name.segment, conn.main_tok);
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
        try std.fmt.allocPrint(a, "{s}__{s}__{s}", .{ file.str(h.sig), file.str(insts[h.inst].name), file.str(h.port) })
    else
        try std.fmt.allocPrint(a, "{s}__{s}__{s}", .{ file.str(owner.sig), file.str(r.module.name), file.str(owner.bottom) });
    return .{
        .instance = try file.intern(a, leaf),
        .segment = try file.intern(a, try std.fmt.allocPrint(a, "{s}{s}{c}{s}", .{ path, leaf, sep, file.str(lower_port) })),
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

/// §7.7.1 read against the connect module: its two ports split into the
/// continuous and the discrete side (§7.6 "The port disciplines define the
/// default type of disciplines which shall be bridged by the connect module.
/// The directional qualifiers of the discrete port determine the default
/// scenarios"), then the statement's overrides applied by domain ("one shall
/// be discrete and the other continuous"). Null for a statement this pass
/// cannot read: an unknown module was E0915 already.
fn ruleOf(self: *Flatten, ins: *const Ast.ConnectInsertion) Error!?Rule {
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
            try self.err(ins.main_tok, .E0915, "`{s}` cannot stand for `{s}`'s `{s}` ({s})", .{
                file.str(ov[1]), file.str(m.name), file.str(side.discipline), why,
            });
            return null;
        }
        side.discipline = ov[1];
        if (ov[0] != .unspecified) side.dir = ov[0];
    };
    return r;
}

/// Does connect rule `r` bridge a port of direction `dir` whose upper and
/// lower connections have these disciplines? §7.6's three examples, which
/// state the matching in terms of DATA FLOW: a d2a (discrete input, continuous
/// output) "can bridge a mixed input port whose upper connection is compatible
/// with discipline ddiscrete and whose lower connection is compatible with
/// electrical, or a mixed output port whose upper connection is compatible
/// with discipline electrical and whose lower connection is compatible with
/// ddiscrete"; an inout/inout bidir "can bridge any mixed port". So the rule's
/// INPUT side faces the port's source: the upper connection of an input port,
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
