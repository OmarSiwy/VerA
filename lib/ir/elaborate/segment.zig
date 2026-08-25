//! Annex F.2 over the unflattened hierarchy: one net segment (an instance
//! path and a local net name) → the discipline and domain discipline
//! resolution gives it, before flattening joins a signal's segments into one
//! node. `insert.plan` reads both connections of a port from here, so a
//! connect module lands at the level §7.4 resolution puts the meeting of the
//! two domains. LRM §3.6.2.4, §6.4, §6.6, §7.4.4, §7.4.4.1, §7.4.4.2,
//! §7.4.4.3, §7.7.2, §7.8.1, §7.8.4, Annex F.2.1 steps 3 and 4, F.2.2 steps
//! 4 and 5; IEEE 1364-2005 §12.1.2.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_resolve = @import("resolve.zig");
const elab_insert = @import("insert.zig");
const discipline = @import("../discipline_rules.zig");
const Ast = @import("frontend").Ast;
const Error = elaborate.Error;
const sep = elaborate.sep;

/// One segment's answer. `domain == .unspecified` is F.2.2 step 4's
/// "unknown": nothing below the segment declares a domain.
pub const Seg = struct {
    disc: Ast.StrId = .none,
    domain: Ast.DisciplineDecl.Domain = .unspecified,
    /// Steps 2 and 3 decided it (an in-context or out-of-context
    /// declaration), so steps 4 and 5 leave it alone.
    declared: bool = false,
    /// Steps 4.a and 5.a: "Any net which is used in digital behavioral code
    /// shall be considered digital", whatever its children or parent are.
    behavioral: bool = false,
};

fn ofDiscipline(file: *const Ast.SourceFile, d: Ast.StrId, declared: bool) Seg {
    const decl = discipline.declOf(file, d) orelse return .{ .disc = d, .declared = declared };
    return .{ .disc = d, .domain = discipline.domainOf(decl) orelse .unspecified, .declared = declared };
}

/// F.2.1 step 4 and F.2.2 step 4, the depth-first pass, which the two modes
/// share: a declared segment is its declaration; otherwise the segment is
/// continuous if any child segment is ("continuous (analog) has precedence
/// over discrete (digital)"), discrete if any is, and unknown when none says.
/// 4.b then picks among the children's disciplines of that domain: one is
/// the answer, several are a §7.7.2 `resolveto` (`resolve.levelCandidates`).
/// A child of unknown domain says nothing, so an undeclared port with
/// nothing below it does not make its parent analog. A segment the module's
/// digital behavioral code uses is digital whatever is below it (4.a), its
/// discipline the discrete children's, or none (§3.6.2.4).
///
/// Memoized per segment. `depth` stops a recursive instantiation, which the
/// walk itself reports (E0905, E1018).
///
/// The children are the ones the walk that inserts nothing elaborated below
/// `path` (`Flatten.tree`): every generate block's instances whose scheme
/// holds, every element of an instance array, a §6.4 paramset instance as
/// the module it selected, at any depth, with every out-of-context
/// declaration (`resolve.oocDisciplineBelow`). Without that walk (no
/// `connectrules`, so nothing to plan) the source instance list is read, a
/// paramset instance only where `insert.plan` is planning (`depth == 0`). A
/// port this pass could not decide is judged after the walk
/// (`insert.checkUnbridged`, E0929).
pub fn up(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, depth: u32) Error!Seg {
    const file = self.ctx.file;
    const key = try self.ctx.arena.print("{s}{s}", .{ path, file.str(net) });
    if (self.seg_up.get(key)) |s| return s;
    const answer = try compute(self, module, path, net, depth);
    try self.seg_up.put(self.ctx.arena, key, answer);
    return answer;
}

fn compute(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, depth: u32) Error!Seg {
    const file = self.ctx.file;
    if (elab_resolve.oocDisciplineBelow(self, path, net) orelse declaredIn(module, net)) |d|
        return ofDiscipline(file, d, true);
    // §3.6.2.4: "If the net is referenced in behavioral code, then it shall
    // be treated as having no discipline with a domain binding of discrete."
    const behavioral = digitalUse(file, module, net);
    if (depth >= elaborate.max_depth) return .{ .domain = if (behavioral) .discrete else .unspecified, .behavioral = behavioral };
    var below: std.ArrayList(Seg) = .empty;
    if (self.tree.get(path)) |kids| {
        for (kids.items) |*kid| try visitChild(self, &kid.inst, kid.module, kid.path, net, depth, &below);
    } else for (module.instances) |*inst| {
        if (inst.range != null) continue;
        const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, file.str(inst.name), sep });
        const m = (if (depth == 0)
            try elab_insert.moduleOf(self, inst, child_path)
        else
            elab_names.findModule(self, inst.module)) orelse continue;
        try visitChild(self, inst, m, child_path, net, depth, &below);
    }
    var domain: Ast.DisciplineDecl.Domain = if (behavioral) .discrete else .unspecified;
    if (!behavioral) for (below.items) |s| {
        if (s.domain == .continuous) domain = .continuous;
        if (s.domain == .discrete and domain == .unspecified) domain = .discrete;
    };
    if (domain == .unspecified) return .{};
    var cands: std.ArrayList(Ast.StrId) = .empty;
    for (below.items) |s| {
        if (s.domain != domain or s.disc == .none) continue;
        if (std.mem.indexOfScalar(Ast.StrId, cands.items, s.disc) == null)
            try cands.append(self.ctx.arena, s.disc);
    }
    return .{ .disc = try elab_resolve.levelCandidates(self, cands.items), .domain = domain, .behavioral = behavioral };
}

/// Appends to `below` the answer of each port of `inst` (elaborated as `m`
/// at `child_path`) that `net` connects, when it has a domain.
fn visitChild(self: *Flatten, inst: *const Ast.Instance, m: *const Ast.ModuleDecl, child_path: []const u8, net: Ast.StrId, depth: u32, below: *std.ArrayList(Seg)) Error!void {
    if (m.is_connect) return;
    for (m.ports, 0..) |p, pi| {
        const ci = elab_insert.connIndex(inst, p, pi) orelse continue;
        if (elab_names.netRefName(self, inst.ports[ci].expr) != net) continue;
        const s = try up(self, m, child_path, p.name, depth + 1);
        if (s.domain != .unspecified) try below.append(self.ctx.arena, s);
    }
}

/// Is `net` read or written by `module`'s digital behavioral code: a
/// continuous assignment (A.6.1) or an `initial`/`always` block (A.6.2)?
/// Undeclared names reach here only as nets (§3.6.5's implicit nets of a
/// port connection or an assignment target).
fn digitalUse(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, net: Ast.StrId) bool {
    const Walk = struct {
        file: *const Ast.SourceFile,
        net: Ast.StrId,
        hit: *bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            const ex = &w.file.exprs;
            if (ex.tag(e) == .ident and ex.strOf(e) == w.net) w.hit.* = true;
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    var hit = false;
    const w: Walk = .{ .file = file, .net = net, .hit = &hit };
    for (module.assigns) |a| {
        w.expr(a.target, .read) catch unreachable;
        w.expr(a.value, .read) catch unreachable;
    }
    for (module.discrete) |d| w.stmt(d.body) catch unreachable;
    return hit;
}

/// The discipline `module` itself declares for `net`, on a port or a net
/// declaration, if any.
fn declaredIn(module: *const Ast.ModuleDecl, net: Ast.StrId) ?Ast.StrId {
    for (module.ports) |p| if (p.name == net and p.discipline != .none) return p.discipline;
    for (module.nets) |n| if (n.name == net and n.discipline != .none) return n.discipline;
    return null;
}

/// The segment on the lower connection of a port whose upper connection
/// resolved to `parent`. Basic mode (F.2.1) has no second pass: it is `up`.
/// Detail mode adds F.2.2 step 5, "Traverse each signal hierarchically
/// (top-down) when a net is encountered which still has not been assigned a
/// discipline or which has been assigned a digital domain from step 4":
///
///  5.a "Any net whose parent nets are digital shall be considered digital.
///       Any others shall be considered analog."
///  5.b "If the net has not yet been assigned a discipline, examine all the
///       parent nets of that net": the parent's discipline. A segment step 4
///       made digital and 5.a keeps digital keeps step 4's discipline, which
///       is §7.4.4.3 Figure 7-5 Case 2's "Same as basic mode". One step 4
///       made digital and 5.a makes analog has no discipline of its domain,
///       so it takes the parent's (§7.4.4.2 Figure 7-4: "Continuous down:
///       NetA resolves to electrical").
///
/// A parent of unknown domain changes nothing: everything below it is
/// unknown too.
pub fn down(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, parent: Seg) Error!Seg {
    const s = try up(self, module, path, net, 0);
    if (self.ctx.discipline_resolution == .basic) return s;
    if (s.declared or s.behavioral or s.domain == .continuous) return s;
    return switch (parent.domain) {
        .continuous => .{ .disc = parent.disc, .domain = .continuous },
        .discrete => if (s.domain == .discrete) s else .{ .disc = parent.disc, .domain = .discrete },
        .unspecified => s,
    };
}
