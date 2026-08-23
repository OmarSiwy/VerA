//! Annex F.2 discipline resolution across the hierarchy: the flattened nets
//! with their declared and inherited disciplines → one discipline per net, or
//! a diagnostic for an incompatible connection. Also checks `connectrules`
//! names and every net's declared discipline. LRM §3.10, §3.11, §5.5.3, §7.2.4, §7.4,
//! §7.4.4.1, §7.4.4.3, §7.6, §7.7.1, §7.7.2, §7.7.2.1, §7.7.3, §7.8, Annex F.2.1.

const std = @import("std");
const elab_clone = @import("clone.zig");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_insert = @import("insert.zig");
const discipline = @import("../discipline_rules.zig");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Error = elaborate.Error;
const sep = elaborate.sep;
const declares = @import("instance.zig").declares;
const PathKey = elab_names.PathKey;

// ---- Annex F.2 discipline resolution ----------------------------------

/// Returns whether a declared net name is an out-of-context one. A period can
/// only come from a hierarchical path (see `sep`).
pub fn isOoc(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, sep) != null;
}

/// Adds `nets` to the flattened module through `addNet`, skipping
/// out-of-context declarations: their content is the discipline they give a
/// segment below (`ooc`), and under a dotted name they would reach lowering
/// as a node nothing connects.
pub fn addNets(self: *Flatten, nets: []const Ast.NetDecl) Error!void {
    for (nets) |n| {
        if (isOoc(self.ctx.file.str(n.name))) continue;
        try addNet(self, n);
    }
}

/// Appends a net to the flattened module and records its discipline. The only
/// way to append to `self.nets`, which keeps `disc_of` complete.
pub fn addNet(self: *Flatten, n: Ast.NetDecl) Error!void {
    try self.nets.append(self.ctx.arena, n);
    try noteDiscipline(self, n.name, n.discipline);
}

/// Records a declared discipline for a flat net; the first one wins. See
/// `disc_of` and `resolveDiscipline`.
pub fn noteDiscipline(self: *Flatten, name: Ast.StrId, disc: Ast.StrId) Error!void {
    if (disc == .none) return;
    const gop = try self.disc_of.getOrPut(self.ctx.arena, name);
    if (!gop.found_existing) gop.value_ptr.* = disc;
}

/// §3.10 precedence order 1: the out-of-context discipline for one segment,
/// if a declaration named it.
///
/// Consulted at all three places a segment gets its discipline: a bound port
/// (`resolveDiscipline`), an unconnected one, and a child's internal net. The
/// clause's example covers the last: "electrical top.middle.bottom.sig;
/// overrides any discipline which may be declared for sig in the module where
/// sig was declared" (`annex_f_resolution/out_of_context_internal_net.va`).
///
/// ponytail: an out-of-context declaration that matched nothing is not
/// diagnosed as an unmatched `defparam` is (E0907): from here it cannot be
/// told apart from a legal form this pass does not reach. The upgrade is a
/// `used` flag on `ooc`, like `Defparam.used`.
pub fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    const d = self.ooc.getAdapted(PathKey{ .path = path, .local = self.ctx.file.str(local) }, PathKey.Context{}) orelse return null;
    return if (d == .none) null else d;
}

/// Annex F.2.1 step 3: records `module`'s out-of-context discipline
/// declarations under its instance prefix `path`, before any child is
/// inlined, since each names a segment below this module. Reports E0902 for
/// a second declaration of one segment: "More than one conflicting
/// out-of-context discipline declaration for the same hierarchical segment
/// of a signal is an error", and §3.10 makes two declarations at one
/// precedence level illegal even when compatible, so this is a duplicate-key
/// test, not a compatibility test.
pub fn collectOoc(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) Error!void {
    for (module.nets) |n| {
        if (!isOoc(self.ctx.file.str(n.name))) continue;
        const key = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(n.name) });
        if (self.ooc.get(key)) |first| {
            try self.err(n.main_tok, .E0902, "`{s}` already has the out-of-context discipline `{s}`", .{
                key, self.ctx.file.str(first),
            });
            continue;
        }
        try self.ooc.put(self.ctx.arena, key, n.discipline);
        if (n.init != .none) try self.ooc_inits.append(self.ctx.arena, .{
            .key = key,
            .depth = path.len,
            .init = try elab_clone.cloneExpr(self, n.init),
        });
    }
}

/// An out-of-context declaration's initializer: the segment it names
/// (`collectOoc`'s key), how deep its declaring module sits (its path's
/// length), and the initializer in flat names.
pub const OocInit = struct { key: []const u8, depth: usize, init: Ast.ExprId };

/// §3.6.3.2: "If different nets of a node have conflicting initializers, then
/// initializers on hierarchical net declarations win. If there are multiple
/// hierarchical declarations, then the declaration on the highest level
/// wins." A segment's flat net is the port binding's (`names`) or, for an
/// internal net, the key itself (`sep` is the path separator). The first
/// declaration at the shallowest level wins: §3.6.3.2 makes a tie a race,
/// and `collectOoc` order is the walk's.
pub fn applyOocInits(self: *Flatten) Error!void {
    for (self.ooc_inits.items, 0..) |o, i| {
        const flat = self.names.get(o.key) orelse o.key;
        const beaten = for (self.ooc_inits.items, 0..) |q, j| {
            if (j == i) continue;
            if (!std.mem.eql(u8, self.names.get(q.key) orelse q.key, flat)) continue;
            if (q.depth < o.depth or (q.depth == o.depth and j < i)) break true;
        } else false;
        if (beaten) continue;
        const name = try self.ctx.file.intern(self.ctx.arena, flat);
        var found = false;
        for (self.nets.items) |*n| if (n.name == name) {
            n.init = o.init;
            found = true;
        };
        // An undeclared (implicit) net has no declaration to carry it.
        if (!found) try addNet(self, .{ .name = name, .init = o.init, .main_tok = self.ctx.file.exprs.mainTok(o.init) });
    }
}

/// Resolves the discipline of flat net `bound` as port `p` of the instance at
/// `path` joins it (Annex F.2, §7.4). Flattening has already collapsed every
/// segment of a signal into one node, so what is left of F.2's traversal is:
/// a segment that declares a discipline gives it to the signal, and an
/// undeclared parent segment inherits it. The depth-first walk supplies the
/// order.
///
/// During the walk the first declaration wins, plus §7.4.4.1's
/// continuous-over-discrete upgrade. That decides F.2.1 step 4.b wherever at
/// most one matching-domain candidate arrives. Every arrival is also recorded
/// in `segs`, and `resolveMultiCandidates` re-decides the rest after the walk.
///
/// §3.11's Signal Connection Rule is judged here, the last place both
/// segments are visible: "It shall be an error to connect two ports or nets
/// of the same domain with incompatible disciplines" (E0355). A segment of
/// the other domain is §7.4.4's connect-module question.
///
/// ponytail: each arriving segment is compared with the discipline the
/// signal has so far, not with every earlier segment. Compatibility is not
/// transitive (a natureless discipline is compatible with two disciplines
/// that are not compatible with each other), so a third segment can slip
/// past a natureless second. Upgrade: compare against every entry of
/// `segs` for the net.
///
/// `at` is the connection's token, or null for an Annex E primitive: its
/// ports' `electrical` is the prelude's placeholder, and E.3.2 resolves the
/// discipline from the attribute or the connected net instead, so there is
/// no declaration to judge.
pub fn resolveDiscipline(self: *Flatten, path: []const u8, p: Ast.Port, bound: Ast.StrId, at: ?u32) Error!void {
    const disc = oocDiscipline(self, path, p.name) orelse p.discipline;
    try noteSignalDiscipline(self, bound, disc);
    // F.2 step 4.b's input: this port's lower connection is a child segment
    // of `bound` declaring `disc`. Recorded unconditionally; the post-pass
    // decides which nets still have a question (`port_resolved`). An
    // undeclared port is recorded as `.none` with its instance path: the
    // segments reaching `bound` from inside that instance are its level of
    // the hierarchy, resolved there first (§7.4.1 Figure 7-2's NetB).
    {
        const gop = try self.segs.getOrPut(self.ctx.arena, bound);
        if (!gop.found_existing) gop.value_ptr.* = .{ .tok = p.main_tok };
        try gop.value_ptr.discs.append(self.ctx.arena, disc);
        try gop.value_ptr.paths.append(self.ctx.arena, path);
    }
    if (disc == .none) return;
    const declared = self.disc_of.get(bound) orelse .none;
    if (declared != .none) {
        const file = self.ctx.file;
        if (at != null and discipline.isContinuous(file, declared) == discipline.isContinuous(file, disc)) {
            if (discipline.disciplineConflict(file, declared, disc)) |why| {
                try self.err(at.?, .E0355, "port `{s}{s}` is of discipline `{s}` and is connected to `{s}`, of discipline `{s}` ({s})", .{
                    path, file.str(p.name), file.str(disc), file.str(bound), file.str(declared), why,
                });
                return;
            }
        }
        // §7.4.4.1 basic mode: "At each level of the hierarchy where
        // continuous and discrete meet for an undeclared net that net segment
        // is declared continuous."
        //
        // Only for a net this function resolved (`port_resolved`). A net the
        // source declared was decided by §3.10's precedence, and upgrading it
        // would overrule a declaration.
        if (!self.port_resolved.contains(bound)) return;
        if (discipline.isContinuous(self.ctx.file, declared)) return;
        if (!discipline.isContinuous(self.ctx.file, disc)) return;
        self.disc_of.putAssumeCapacity(bound, disc);
        for (self.nets.items) |*n| {
            if (n.name == bound) n.discipline = disc;
        }
        return;
    }
    try self.port_resolved.put(self.ctx.arena, bound, {});
    try addNet(self, .{
        .name = bound,
        .discipline = disc,
        // The declaration's token, not the connection's: a wrong discipline
        // is fixed where it was named.
        .main_tok = p.main_tok,
    });
}

/// §7.2.4 keeps a segment's tolerance separate from the single discipline
/// chosen for a flattened net by §7.4. Lowering owns nature-attribute folding.
pub fn noteSignalDiscipline(self: *Flatten, net: Ast.StrId, disc: Ast.StrId) Error!void {
    if (disc == .none) return;
    try self.signal_disciplines.append(self.ctx.arena, .{
        .net = self.ctx.file.str(net),
        .discipline = self.ctx.file.str(disc),
    });
}

/// Applies Annex F.2.1 step 4 after the walk to undeclared segments, retaining
/// their local answers for tolerances and nature attributes. The flattened
/// root changes only if its discipline came from a bound port rather than
/// a declaration. `resolveLevel` asks §7.4.1's question bottom-up;
/// `levelAnswer` is 4.a/4.b for one level. Reports E0903 and E0917.
///
/// The other 4.a sentence (a net "used in digital behavioral code" is
/// digital) is `segment.up`'s: it decides the mixed ports, and `insert.plan`
/// bridges them, so the net arrives here with its digital segments only.
pub fn resolveMultiCandidates(self: *Flatten) Error!void {
    var it = self.segs.iterator();
    while (it.next()) |entry| {
        const net = entry.key_ptr.*;
        // A declared upper segment does not declare every segment below it
        // (§7.4.4.3 Figure 7-5, Case 2). Their local resolution answers still
        // supply §7.2.4 tolerances and §5.5.3 nature attributes.
        for (entry.value_ptr.discs.items, 0..) |disc, i| {
            if (disc == .none) _ = try resolveLevel(self, net, entry.value_ptr, i);
        }
        // A net the source declared was decided by §3.10 precedence
        // (steps 2/3); step 4 is only for undeclared interconnect.
        if (!self.port_resolved.contains(net)) continue;
        const r = try resolveLevel(self, net, entry.value_ptr, null) orelse continue;
        if (self.disc_of.get(net) == r) continue;
        // Bullet 3: "the net is of the resolved discipline given by the
        // statement", which "need not be one of the disciplines specified
        // in the discipline list" (§7.7.2.1). Same two writes as §7.4.4.1's
        // upgrade in `resolveDiscipline`.
        self.disc_of.putAssumeCapacity(net, r);
        for (self.nets.items) |*n| {
            if (n.name == net) n.discipline = r;
        }
    }
    for (self.pending_attributes.items) |a| {
        var local: ?Ast.StrId = null;
        if (self.segs.getPtr(a.net)) |s| {
            for (s.paths.items, 0..) |path, i| {
                if (!std.mem.eql(u8, path, a.path)) continue;
                local = s.resolved.get(@intCast(i)) orelse null;
                break;
            }
        }
        if (local orelse self.disc_of.get(a.net)) |disc|
            try self.attribute_disciplines.put(self.ctx.arena, a.expr, disc);
    }
}

/// §7.4.1 "at each level of the hierarchy": the arrival that arrival `i`
/// reached the net through (the one whose instance path is the longest
/// proper prefix of `i`'s), or null for a segment at the net's own level.
/// This recovers the levels a flattened net's single list mixes together.
fn levelOf(paths: []const []const u8, i: usize) ?usize {
    var best: ?usize = null;
    for (paths, 0..) |q, j| {
        if (q.len >= paths[i].len or !std.mem.startsWith(u8, paths[i], q)) continue;
        if (best == null or q.len > paths[best.?].len) best = j;
    }
    return best;
}

/// One level's answer for `net`, over the arrivals directly at that level
/// (`group`'s members, or the net's own level's at null). A declared lower
/// connection is itself (§7.4.4.3: "that discipline shall be used"); an
/// undeclared one is its own level's answer, resolved first, so Figure
/// 7-2's NetA sees "the resulting cmos3 from module twoblks", not twoblks'
/// children.
fn resolveLevel(self: *Flatten, net: Ast.StrId, s: anytype, group: ?usize) Error!?Ast.StrId {
    if (group) |g| if (s.resolved.get(@intCast(g))) |cached| return cached;
    var discs: std.ArrayList(Ast.StrId) = try .initCapacity(self.ctx.arena, s.discs.items.len);
    for (s.discs.items, 0..) |d, i| {
        const lvl = levelOf(s.paths.items, i);
        if ((lvl == null) != (group == null)) continue;
        if (lvl != null and lvl.? != group.?) continue;
        const v = if (d != .none) d else (try resolveLevel(self, net, s, i)) orelse continue;
        discs.appendAssumeCapacity(v);
    }
    const answer = try levelAnswer(self, net, s.tok, discs.items);
    if (group) |g| try s.resolved.put(self.ctx.arena, @intCast(g), answer);
    if (answer) |disc| try noteSignalDiscipline(self, net, disc);
    return answer;
}

/// Annex F.2.1 step 4 over one level's candidate disciplines.
///
///  4.a  domain: "Any net whose child nets are all digital shall be
///       considered digital (discrete domain), any others shall be
///       considered analog (continuous domain)." §7.4.4.1's basic mode says
///       the same thing as a precedence ("continuous winning over discrete").
///  4.b  candidates: the distinct disciplines whose domain matches the
///       level's. One → that one. More than one → bullet 3: a §7.7.2
///       resolution statement whose list matches the set resolves it
///       (`resolveto exclude` refuses it instead, E0917); no statement →
///       bullet 4: unknown, "legal provided the net has no mixed-port
///       connections ... Otherwise this is an error" (E0903).
///
/// A legally unknown net keeps its first arrival in the level's domain.
fn levelAnswer(self: *Flatten, net: Ast.StrId, tok: u32, discs: []const Ast.StrId) Error!?Ast.StrId {
    var net_continuous = false;
    for (discs) |d| {
        if (discipline.isContinuous(self.ctx.file, d)) net_continuous = true;
    }
    var cands: std.ArrayList(Ast.StrId) = try .initCapacity(self.ctx.arena, discs.len);
    var mixed_port = false;
    for (discs) |d| {
        if (discipline.isContinuous(self.ctx.file, d) != net_continuous) {
            mixed_port = true;
            continue;
        }
        // ponytail: linear membership for short lists; use a set if this scan dominates.
        if (std.mem.indexOfScalar(Ast.StrId, cands.items, d) == null)
            cands.appendAssumeCapacity(d);
    }
    if (cands.items.len <= 1) return if (cands.items.len == 1) cands.items[0] else null;

    if (try matchResolution(self, cands.items, true)) |r| {
        if (r.exclude) {
            // §7.7.2: "deemed to be incompatible and an error is indicated
            // if they are found on the same net."
            try self.err(tok, .E0917, "the disciplines of `{s}` match `connect ... resolveto exclude`", .{
                self.ctx.file.str(net),
            });
            return null;
        }
        return r.resolved;
    }
    if (mixed_port) try self.err(
        tok,
        .E0903,
        "`{s}` has candidate disciplines {{`{s}`, `{s}`{s}}} and no matching `resolveto`",
        .{
            self.ctx.file.str(net),
            self.ctx.file.str(cands.items[0]),
            self.ctx.file.str(cands.items[1]),
            if (cands.items.len > 2) ", ..." else "",
        },
    );
    return cands.items[0];
}

/// Step 4.b's choice among one segment's same-domain candidate
/// disciplines, without the diagnostics `levelAnswer` reports for the
/// flattened net: `.none` for no candidate or a `resolveto exclude`, the
/// one candidate, the `resolveto` result, or the first of an unresolved
/// set. For `segment.up`.
pub fn levelCandidates(self: *Flatten, cands: []const Ast.StrId) Error!Ast.StrId {
    if (cands.len <= 1) return if (cands.len == 1) cands[0] else .none;
    const r = try matchResolution(self, cands, false) orelse return cands[0];
    return if (r.exclude) .none else r.resolved;
}

/// §7.7.2 the first resolution statement whose discipline list matches
/// `cands` as a set (order-free, duplicate-free on both sides: 4.b's
/// "the contents of the list match"). First match across every
/// `connectrules` block in source order, which is §7.7.2.1's tie-break.
fn matchResolution(self: *Flatten, cands: []const Ast.StrId, report: bool) Error!?*const Ast.ConnectResolution {
    // §7.7.2.1: an exact set wins even over an earlier subset match.
    // In the fallback, the candidate set is a subset of the rule's list.
    for ([_]bool{ true, false }) |want_exact| {
        var first: ?*const Ast.ConnectResolution = null;
        for (self.ctx.file.connectrules) |*cr| {
            rule: for (cr.resolutions) |*r| {
                for (cands) |c| {
                    if (std.mem.indexOfScalar(Ast.StrId, r.disciplines, c) == null) continue :rule;
                }
                var exact = true;
                for (r.disciplines) |d| {
                    if (std.mem.indexOfScalar(Ast.StrId, cands, d) == null) exact = false;
                }
                if (exact != want_exact) continue;
                if (first != null) {
                    if (report) try self.ctx.bag.add(.lower, .W0950, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, r.main_tok), "multiple {s} resolution rules apply; using the first", .{
                        if (want_exact) "exact" else "subset",
                    });
                    return first;
                }
                first = r;
            }
        }
        if (first != null) return first;
    }
    return null;
}

/// Checks the names every §7.7 `connectrules` statement uses (E0915, E0916,
/// E0923, E0982, E0907), once per compilation. Not the parser's job: A.1.2
/// puts no order on descriptions, so the connect module or discipline may be
/// declared after the block.
pub fn checkConnectRules(self: *Flatten) Error!void {
    for (self.ctx.file.connectrules) |cr| {
        for (cr.insertions) |*ins| {
            // §7.7.1 "connect connectmodule_identifier": the name must be
            // a §7.6 connect module; an ordinary module bridges nothing.
            const m = elab_names.findModule(self, ins.module) orelse {
                try self.err(ins.main_tok, .E0915, "nothing declares `{s}`", .{self.ctx.file.str(ins.module)});
                continue;
            };
            if (!m.is_connect) try self.err(ins.main_tok, .E0915, "`{s}` is not declared with `connectmodule`", .{
                self.ctx.file.str(ins.module),
            });
            // §7.8 "When two disciplines are specified in a connect
            // statement, one shall be discrete and the other continuous."
            if (ins.overrides) |o| {
                const da = discipline.domainOf(discipline.declOf(self.ctx.file, o.a) orelse continue);
                const db = discipline.domainOf(discipline.declOf(self.ctx.file, o.b) orelse continue);
                if (da == null or db == null or da == db) {
                    try self.err(ins.main_tok, .E0923, "`{s}` and `{s}`: one shall be discrete and the other continuous", .{
                        self.ctx.file.str(o.a), self.ctx.file.str(o.b),
                    });
                    continue;
                }
            }
            // §7.7.1 "the specified disciplines shall be compatible for both
            // the continuous and discrete disciplines of the given connect
            // module" (E0915), §7.6 Table 7-2's direction pairs (E0982) and
            // §7.7.3's parameter names (E0907), judged once for every
            // statement: insertion (`elab_insert.plan`) reads the same rule
            // quietly and only in a module whose ports reach one.
            if (!m.is_connect) continue;
            if (try elab_insert.ruleOf(self, ins, true)) |r| try elab_insert.checkDirections(self, r);
            _ = try elab_insert.paramsDeclared(self, ins, m, true);
        }
        for (cr.resolutions) |r| {
            // §7.7.2 every identifier in a resolution statement is a
            // discipline_identifier; one that names no discipline can
            // never match a candidate list, and would silently turn a
            // resolving design into an E0903 one.
            for (r.disciplines) |d| if (discipline.declOf(self.ctx.file, d) == null)
                try self.err(r.main_tok, .E0916, "nothing declares a discipline `{s}`", .{self.ctx.file.str(d)});
            if (!r.exclude and discipline.declOf(self.ctx.file, r.resolved) == null)
                try self.err(r.main_tok, .E0916, "nothing declares a discipline `{s}`", .{self.ctx.file.str(r.resolved)});
        }
    }
}

// ponytail: nets declared inside a generate block are not visited; add them
// when a fixture declares one with a bad discipline.
/// Checks that every net declaration in every user module names a declared
/// discipline (A.2.1.3, §3.6.2; E0371), once per compilation. Every module,
/// because the common form of this error, `child c1;` (an instance missing
/// its parentheses, parsed as a net of discipline `child`), leaves `child`
/// an uninstantiated module that is never lowered.
pub fn checkNetDisciplines(self: *Flatten) Error!void {
    const file = self.ctx.file;
    for (file.userModules()) |*m| for (m.nets) |n| {
        if (n.discipline == .none or discipline.declOf(file, n.discipline) != null) continue;
        if (elab_names.findModule(self, n.discipline) != null)
            try self.err(n.main_tok, .E0371, "`{s}` in the declaration of `{s}` is a module; an A.4.1 module_instance takes a parenthesised port list even when it is empty: `{s} {s}();`", .{
                file.str(n.discipline), file.str(n.name), file.str(n.discipline), file.str(n.name),
            })
        else
            try self.err(n.main_tok, .E0371, "`{s}` in the declaration of `{s}`", .{ file.str(n.discipline), file.str(n.name) });
    };
}
