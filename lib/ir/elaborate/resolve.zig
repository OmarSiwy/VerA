//! Annex F.2 discipline resolution across the hierarchy.
//!
//! In: the flattened nets with their declared and inherited disciplines. Out: one discipline
//! per net, or a diagnostic for an incompatible connection.
//!
//! LRM clauses this file's code cites: §3.6.2.2, §3.10, §3.11, §7.2.2, §7.4, §7.4.4.1, §7.6, §7.7, §7.7.1, §7.7.2, §7.7.2.1, §7.7.3, §7.8.
//!
//! Cut verbatim from `elaborate.zig`. Functions take `self: *Flatten` and are called
//! directly, `elab_resolve.f(self, ...)`; `elaborate.zig` aliases only what other modules call.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_insert = @import("insert.zig");
const discipline = @import("../lower/discipline.zig");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Error = elaborate.Error;
const sep = elaborate.sep;
const declares = Flatten.declares;

// ---- Annex F.2 discipline resolution ----------------------------------

/// Is this declared name an out-of-context one? A period can only have come
/// from a hierarchical path (see `sep`), so the test is the presence of one.
pub fn isOoc(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, sep) != null;
}

/// A net declaration that is not a declaration of THIS module's net: it is
/// dropped from the flattened module, because its whole content is the
/// discipline it contributes to a segment somewhere below (`ooc`), and a net
/// under a dotted name would otherwise reach lowering as a node nothing
/// connects.
pub fn addNets(self: *Flatten, nets: []const Ast.NetDecl) Error!void {
    for (nets) |n| {
        if (isOoc(self.ctx.file.str(n.name))) continue;
        try addNet(self, n);
    }
}

/// THE insertion point for a net of the flattened module. Nothing appends to
/// `self.nets` directly: `disc_of` is only as complete as this is exclusive.
pub fn addNet(self: *Flatten, n: Ast.NetDecl) Error!void {
    try self.nets.append(self.ctx.arena, n);
    try noteDiscipline(self, n.name, n.discipline);
}

/// Record a declared discipline for a flat net. FIRST wins, which is what
/// the scan this replaces did — see `disc_of` for why there is no second
/// slot, and `resolveDiscipline` for what first-wins still costs.
pub fn noteDiscipline(self: *Flatten, name: Ast.StrId, disc: Ast.StrId) Error!void {
    if (disc == .none) return;
    const gop = try self.disc_of.getOrPut(self.ctx.arena, name);
    if (!gop.found_existing) gop.value_ptr.* = disc;
}

/// §3.10 precedence order 1: the out-of-context discipline for one segment,
/// if a declaration named it.
///
/// Consulted at all three places a segment gets its discipline: a bound port
/// (`resolveDiscipline`), an unconnected one, and — since wave 13 — the
/// child-net loop, which is a child's own INTERNAL net. The clause's printed
/// example decides that last one: "electrical top.middle.bottom.sig;
/// overrides any discipline which may be declared for sig IN THE MODULE
/// WHERE SIG WAS DECLARED", and the module where a name was declared is the
/// module holding its declaration, port or not.
/// `annex_f_resolution/out_of_context_internal_net.va` is the fixture; it
/// FAILs on the one-line removal of that call.
///
/// ponytail: an out-of-context declaration that matched NOTHING is not
/// diagnosed, the way an unmatched `defparam` is (E0907). A `defparam` names
/// a parameter and nothing else can absorb it; a net declaration under a
/// dotted name is indistinguishable from here from a legal form this pass
/// simply does not reach, so reporting it would report correct programs. The
/// upgrade is a `used` flag on `ooc`, exactly like `Defparam.used`, once
/// every consumer of the table is in.
pub fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) Error!?Ast.StrId {
    // The same allocPrint join every sibling key builds (`defparams`,
    // `walkInstances`). This was a fixed 256-byte bufPrint whose overflow
    // was `catch return null` — a path longer than the buffer silently lost
    // its out-of-context declaration, which is a wrong DISCIPLINE, not a
    // wrong diagnostic.
    const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(local) });
    const n = self.ooc.get(key) orelse return null;
    return if (n.discipline == .none) null else n.discipline;
}

/// Annex F.2 / §7.4, for the one shape a FLATTENED design has of it.
///
/// F.2: "A net segment of a signal on the upper connection of a port shall be
/// considered as the parent to a net segment on the lower connection of the
/// port ... the continuous domain is passed up the hierarchy from lower levels
/// to the top level." Flattening has already collapsed every segment of one
/// signal into a single node (Ruling E) — the join in the branch above IS
/// F.2's parent/child relation — so what is left of the traversal is: a
/// segment that declares a discipline gives it to the signal, and an
/// undeclared parent segment inherits it. That is exactly steps 4.a and 4.b's
/// single-discipline case, and the depth-first walk supplies the ORDER for
/// free, since a child is inlined after its parent's own declarations are in.
///
/// DURING the walk, first declaration wins (plus §7.4.4.1's
/// continuous-over-discrete upgrade below) — which is 4.b decided
/// correctly wherever the matching-domain candidate set has AT MOST ONE
/// member, i.e. every design without a `connect ... resolveto` question to
/// ask. The multi-candidate arm cannot run here: 4.b wants the candidates
/// partitioned by domain and matched as a SET against §7.7.2's resolution
/// statements, and the set is not complete until every segment of the
/// signal has been walked. So this function also FEEDS `segs`, and
/// `resolveMultiCandidates` re-decides, after the walk, exactly the nets
/// where more than one matching-domain candidate arrived — everywhere
/// else the post-pass is a no-op and first-wins IS the answer, which is
/// what keeps every pre-`connectrules` fixture's behaviour bit-identical.
///
/// §3.11's Signal Connection Rule IS judged here, at the one place both
/// segments are still visible: "It shall be an error to connect two ports or
/// nets of the same domain with incompatible disciplines" (§7.4.3 says it of
/// a continuous port). After this function the port's discipline has been
/// merged into `bound` and lowering sees one node. A segment of the OTHER
/// domain is §7.4.4's connect-module question, not this rule's. What the
/// post-pass adds is only what F.2.1 4.b states over the multi-candidate
/// list — resolve by statement, or unknown, or E0903.
///
/// ponytail: each arriving segment is compared with the discipline the
/// signal has SO FAR, not with every earlier segment. Compatibility is not
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
    const disc = (try oocDiscipline(self, path, p.name)) orelse p.discipline;
    // F.2 step 4.b's raw material: this port's lower connection is a child
    // segment of `bound`, and it declares `disc`. Recorded UNCONDITIONALLY
    // — whether the net resolves here, later, or was declared outright —
    // because the post-pass, not this arrival, is what knows which nets
    // have a question left (`port_resolved` gates it there). An UNDECLARED
    // port is recorded too, as `.none` with its instance path: the segments
    // that reach `bound` from inside that instance are its level of the
    // hierarchy, resolved there first (§7.4.1 Figure 7-2's NetB).
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
        // §7.4.4.1, and it is the whole of the basic mode's rule: "At each
        // level of the hierarchy where continuous and discrete meet for an
        // undeclared net that net segment is declared continuous." The
        // clause's own worked example says it twice — "NetC resolves to
        // electrical based on continuous (electrical) winning over discrete
        // (cmos2)".
        //
        // Only for a net THIS function resolved. A net the source declared
        // is not an undeclared interconnect, and §3.10's precedence already
        // decided it; upgrading one here would silently overrule a
        // declaration. `port_resolved` is what draws that line — first-wins
        // still holds everywhere else, which is what `noteDiscipline` says.
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
        // The DECLARATION's token, not the connection's: if this discipline
        // turns out to be wrong for the net, the source the reader has to fix
        // is the one that named it.
        .main_tok = p.main_tok,
    });
}

/// Annex F.2.1 step 4 (its 4.a/4.b are printed verbatim in F.2.2 step 4).
/// Runs ONCE, after the walk, over every net that got its discipline from a
/// bound port rather than a declaration — F.2's "net ... which still has not
/// been assigned a discipline". The flatten joined every level of the
/// hierarchy into one net, so the per-level question §7.4.1 asks ("If
/// disciplines at the lower connections of ports (where the undeclared net
/// is an upper connection) are among the disciplines in discipline_list")
/// is re-asked bottom-up by `resolveLevel`, one level per undeclared port;
/// `levelAnswer` is 4.a/4.b for one level. Where the walk's first-wins
/// answer was already 4.b's — at most one candidate per level — the write
/// below changes nothing, which keeps every pre-`connectrules` design's
/// discipline bit-identical.
///
/// The clause's other 4.a sentence — a net "used in digital behavioral code"
/// is digital — has no input here: a net's domain comes from its segments.
///
pub fn resolveMultiCandidates(self: *Flatten) Error!void {
    var it = self.segs.iterator();
    while (it.next()) |entry| {
        const net = entry.key_ptr.*;
        // A net the source declared was decided by §3.10 precedence
        // (steps 2/3); step 4 is only for undeclared interconnect.
        if (!self.port_resolved.contains(net)) continue;
        const r = try resolveLevel(self, net, entry.value_ptr, null) orelse continue;
        if (self.disc_of.get(net) == r) continue;
        // Bullet 3: "the net is of the resolved discipline given by the
        // statement" — which "need not be one of the disciplines specified
        // in the discipline list" (§7.7.2.1). Same two writes as §7.4.4.1's
        // upgrade in `resolveDiscipline`.
        self.disc_of.putAssumeCapacity(net, r);
        for (self.nets.items) |*n| {
            if (n.name == net) n.discipline = r;
        }
    }
}

/// §7.4.1 "at each level of the hierarchy": the arrival that arrival `i`
/// reached the net through — the one whose instance path is the LONGEST
/// proper prefix of `i`'s — or null for a segment at the net's own level. A
/// flattened net keeps every segment of every level in one list; this is
/// what puts the levels back.
fn levelOf(paths: []const []const u8, i: usize) ?usize {
    var best: ?usize = null;
    for (paths, 0..) |q, j| {
        if (q.len >= paths[i].len or !std.mem.startsWith(u8, paths[i], q)) continue;
        if (best == null or q.len > paths[best.?].len) best = j;
    }
    return best;
}

/// One level's answer for `net`, over the arrivals directly at that level
/// (`group`'s members, or the net's own level's at null). A DECLARED lower
/// connection is itself (§7.4.4.3: "that discipline shall be used"); an
/// undeclared one is its own level's answer, resolved first — so Figure
/// 7-2's NetA sees "the resulting cmos3 from module twoblks", not twoblks'
/// children. A design with no undeclared intermediate port has one level,
/// and this is F.2.1 4.b as it always was.
fn resolveLevel(self: *Flatten, net: Ast.StrId, s: anytype, group: ?usize) Error!?Ast.StrId {
    var discs: std.ArrayList(Ast.StrId) = .empty;
    for (s.discs.items, 0..) |d, i| {
        const lvl = levelOf(s.paths.items, i);
        if ((lvl == null) != (group == null)) continue;
        if (lvl != null and lvl.? != group.?) continue;
        const v = if (d != .none) d else (try resolveLevel(self, net, s, i)) orelse continue;
        try discs.append(self.ctx.arena, v);
    }
    return levelAnswer(self, net, s.tok, discs.items);
}

/// Annex F.2.1 step 4 over one level's candidate disciplines.
///
///  4.a  domain: "Any net whose child nets are all digital shall be
///       considered digital (discrete domain), any others shall be
///       considered analog (continuous domain)." §7.4.4.1's basic mode says
///       the same thing as a precedence ("continuous winning over discrete").
///  4.b  candidates: the DISTINCT disciplines whose domain matches the
///       level's. One → that one. More than one → bullet 3: a §7.7.2
///       resolution statement whose list matches the set resolves it
///       (`resolveto exclude` refuses it instead, E0917); no statement →
///       bullet 4: UNKNOWN, "legal provided the net has no mixed-port
///       connections (i.e., it does not connect through a port to a segment
///       of a different domain). Otherwise this is an error" — E0903.
///
/// A legally-unknown net keeps its first arrival in the level's domain,
/// which is the answer the walk's first-wins rule always gave.
fn levelAnswer(self: *Flatten, net: Ast.StrId, tok: u32, discs: []const Ast.StrId) Error!?Ast.StrId {
    var net_continuous = false;
    for (discs) |d| {
        if (discipline.isContinuous(self.ctx.file, d)) net_continuous = true;
    }
    var cands: std.ArrayList(Ast.StrId) = .empty;
    var mixed_port = false;
    for (discs) |d| {
        if (discipline.isContinuous(self.ctx.file, d) != net_continuous) {
            mixed_port = true;
            continue;
        }
        // ponytail: linear membership for short lists; use a set if this scan dominates.
        if (std.mem.indexOfScalar(Ast.StrId, cands.items, d) == null)
            try cands.append(self.ctx.arena, d);
    }
    if (cands.items.len <= 1) return if (cands.items.len == 1) cands.items[0] else null;

    if (try matchResolution(self, cands.items)) |r| {
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

/// §7.7.2 the first resolution statement whose discipline list matches
/// `cands` as a SET (order-free, duplicate-free on both sides — 4.b's
/// "the contents of the list match"). First match across every
/// `connectrules` block in source order, which is §7.7.2.1's tie-break.
pub fn matchResolution(self: *Flatten, cands: []const Ast.StrId) Error!?*const Ast.ConnectResolution {
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
                    try self.ctx.bag.add(.lower, .W0950, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, r.main_tok), "multiple {s} resolution rules apply; using the first", .{
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

/// §7.7 the names a `connectrules` block spends, judged once per
/// compilation (before the tree-of-one shortcut — see `elaborate`).
/// A.1.2 puts no order on descriptions, so this is elaboration's and not
/// the parser's: the connect module or discipline may be declared after
/// the block.
pub fn checkConnectRules(self: *Flatten) Error!void {
    for (self.ctx.file.connectrules) |cr| {
        for (cr.insertions) |*ins| {
            // §7.7.1 "connect connectmodule_identifier": the name must be
            // a §7.6 connect module — an ordinary module bridges nothing.
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
            // §7.7.3's parameter names (E0907) — judged here, once, for every
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

/// A.2.1.3 `discipline_identifier list_of_net_identifiers ;` — the identifier
/// names a declared discipline (§3.6.2). Judged over EVERY module, once per
/// compilation, like `checkConnectRules`: a module that nothing instantiates
/// is never lowered, and the common way to write this error — `child c1;`,
/// an A.4.1 instance without its mandatory parentheses, which parses as a net
/// `c1` of discipline `child` — is exactly the one that leaves `child` an
/// uninstantiated root.
// ponytail: nets declared inside a generate block are not visited; add them
// when a fixture declares one with a bad discipline.
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
