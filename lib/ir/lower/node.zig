//! §1.3.1 nodes: nets, ports, ground and the solver-unknown order.
//!
//! In: net and port declarations. Out: `nodes` (the U-enum index codegen depends on),
//! implicit nets, and the port/branch tables.
//!
//! LRM clauses this file's code cites: §1, §1.3.1.1, §2.7, §2.8.1, §3.6.3, §3.6.3.2, §3.6.5, §3.9, §3.12, §5.4.1, §5.5.2, §5.9.3, §6.5.2.2.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_discipline = @import("discipline.zig");
const discipline_rules = @import("../discipline_rules.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Preprocessor = @import("frontend").Preprocessor;
const assert = Lower.assert;
const Oom = Lower.Oom;
const ground = Lower.ground;
const unnamed_branch = Lower.unnamed_branch;
const NodeKind = Lower.NodeKind;
const VecRange = Lower.VecRange;

/// This file's private state on `Lower` (`Lower.node_state`).
pub const State = struct {
    /// Last `BranchInfo.id` handed out. Starts at `unnamed_branch`, so the first
    /// declared branch is 1 and no named branch can ever be mistaken for §5.4.1
    /// Example 2's single implicit branch of a node pair.
    last_branch_id: u32 = unnamed_branch,
    /// Every spelling handed to `nodes`, so `appendNode` can keep them unique for
    /// the emitted `U` enum. Not an identity table: two different unknowns may want
    /// one spelling (see `uniqueSpelling`).
    spellings: std.StringHashMapUnmanaged(void) = .empty,
    /// Deduped probe Value per `nodes` row; `.undef` = not probed yet.
    probe_cache: std.ArrayList(Mir.Value) = .empty,
    /// `op_state` rows minted so far, the `<k>` of `opStateNode`'s spelling.
    op_states: u32 = 0,
    /// E1015 was reported: `nodes` is full.
    full: bool = false,
};

/// The most rows `nodes` holds: a row is a u16 and `ground` is the last value.
const max_nodes = ground;

/// Reports whether `dname` is a §1.3.4 signal-flow discipline: exactly one of its
/// two natures is bound. A discipline binding both is conservative (§3.6.2.1); one
/// binding neither (natureless continuous, or discrete) is not signal-flow either.
pub fn isSignalFlow(self: *const Lower, dname: []const u8) bool {
    if (dname.len == 0) return false;
    const d = self.out.disciplines.get(dname) orelse return false;
    return d.has_potential != d.has_flow;
}

/// Applies the `default_discipline in force at `main_tok` to net `name`, or to each
/// scalarised element when it is a §3.6.3 vector (LRM §10.2).
pub fn applyDefaultToAll(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    const r = self.out.vectors.get(name) orelse
        return applyDefaultDiscipline(self, try netKey(self, name, main_tok), main_tok);
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    for (0..r.size()) |k|
        try applyDefaultDiscipline(self, try lower_param.elemKey(self, &key_buf, name, &.{r.at(@intCast(k))}), main_tok);
}

/// §10.2: "The default discipline is applied ... to all discrete signals without a
/// discipline declaration that appear in the text stream following the use of the
/// `default_discipline directive." So only a net that still has none, and only a
/// directive preceding its declaration. Every net here is a plain `wire` (IEEE 1364
/// §3.5), so `wire` and the unqualified form are the only qualifiers that can match.
/// ponytail: widen the key to the net's declared data type when those land.
fn applyDefaultDiscipline(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (self.directives.disciplines.len == 0) return;
    const idx = self.node_voltages.get(name) orelse return;
    if (idx == ground) return;
    if (self.out.nodes.items(.disc)[idx].len != 0) return;
    const dname = defaultDisciplineAt(self, main_tok) orelse return;
    // A default naming a discipline that was never declared supplies no
    // nature, so the net stays bare and E0337 reports it.
    if (!self.out.disciplines.contains(dname)) return;
    self.out.nodes.items(.disc)[idx] = dname;
}

/// §10.2 the `default_discipline in force for a wire at token `main_tok`, or null.
/// The most recent directive wins, and a wire-qualified one wins over an
/// unqualified one however old it is ("the more specific directives have higher
/// precedence").
fn defaultDisciplineAt(self: *const Lower, main_tok: u32) ?[]const u8 {
    if (main_tok >= self.tok_starts.len) return null;
    const at = self.tok_starts[main_tok];
    var fallback: ?[]const u8 = null;
    var i = self.directives.disciplines.len;
    return while (i > 0) {
        i -= 1;
        const e = self.directives.disciplines[i];
        if (e.at > at) continue;
        // §10.2: the bare form and `resetall withdraw the default outright,
        // so nothing older than one of those is still in force.
        if (e.discipline.len == 0) break fallback;
        if (e.qualifier == .wire) break e.discipline;
        if (e.qualifier == null and fallback == null) fallback = e.discipline;
    } else fallback;
}

/// §3.9 "For digital primitives the domain is discrete and thus the discipline
/// is set via the default_discipline directive as it is for digital modules.
/// If the discipline of digital connections (vpiLoConn) to a mixed net are
/// unknown then the default_discipline must be specified (via the directive or
/// other vendor specific method). If not specified, an error will result
/// during discipline resolution." Reports E0960.
///
/// Every gate, pull source or switch terminal is such a digital connection, and
/// its net is mixed when the net's own discipline is continuous. VerA has no
/// vendor-specific method, so only the directive in force at the primitive can
/// supply the connection's discipline. Must run after `applyDefaultToAll`.
pub fn checkPrimitiveDisciplines(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.gates) |g| {
        try checkPrimitiveTerminal(self, g.out, g.main_tok, "gate");
        for (g.ins) |t| try checkPrimitiveTerminal(self, t, g.main_tok, "gate");
    }
    for (module.pulls) |p| try checkPrimitiveTerminal(self, p.out, p.main_tok, "pull source");
    for (module.switches) |sw| for (sw.terms) |t| try checkPrimitiveTerminal(self, t, sw.main_tok, "switch");
}

fn checkPrimitiveTerminal(self: *Lower, term: Ast.ExprId, prim_tok: u32, what: []const u8) Oom!void {
    const ex = &self.file.exprs;
    const base = self.file.lvalueBase(term);
    if (base == .none or ex.tag(base) != .ident) return;
    if (defaultDisciplineAt(self, prim_tok) != null) return;
    const name = self.file.str(ex.strOf(base));
    // A vector is scalarised by now and its elements share one discipline
    // (§3.6.3), so the first element answers for the whole net.
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    const key = if (self.out.vectors.get(name)) |r| try lower_param.elemKey(self, &key_buf, name, &.{r.at(0)}) else name;
    const idx = self.node_voltages.get(key) orelse return;
    if (idx == ground) return;
    const dname = self.out.nodes.items(.disc)[idx];
    const decl = lower_discipline.disciplineDecl(self, dname) orelse return;
    if (discipline_rules.domainOf(decl) != .continuous) return;
    var b = self.errWith(ex.mainTok(base), .E0960);
    b.msg("`{s}` is of continuous discipline `{s}` and a terminal of a digital {s}", .{ name, dname, what });
    b.note("the primitive's side of the net is discrete, so the net is mixed, and no `default_discipline is in force to name that side's discipline", .{});
    b.help("put `default_discipline logic (or another discrete discipline) before the primitive", .{});
    try b.emit();
}

/// Reports an error when IEEE 1364 §19.2 `` `default_nettype none `` is in force at
/// `main_tok`, on a name about to become a §3.6.5 implicit net. Other net types are
/// a no-op: VerA's analog nets have a discipline, not a net type.
///
/// ponytail: the other ten values are accepted and dropped; they differ only in
/// how multiple drivers resolve, which VerA does not model. Upgrade: a discrete
/// net type on `Ast.NetDecl`.
pub fn rejectImplicitNet(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (Preprocessor.NetTypeRegion.inForce(self.directives.nettypes, self.tokStart(main_tok), .default) != .none) return;
    var b = self.errWith(main_tok, .E0367);
    b.msg("`{s}` was never declared, and `default_nettype none is in force", .{name});
    b.note("§3.6.5 would make it an implicit net; IEEE 1364 §19.2's `none` is what withdraws that", .{});
    b.help("declare it — `electrical {s};` — or go back to `default_nettype wire", .{name});
    try b.emit();
}

/// Applies IEEE 1364 §19.10 `unconnected_drive to the internal nets §6.2.2 gave
/// unconnected `input` ports: `pull0` holds the port at potential 0 and `pull1` at 1,
/// in its discipline's potential units, through a potential source. Must run after
/// the declarations are interned and before the analog blocks lower. Skips a net
/// whose discipline binds no potential.
///
/// ponytail: 1.0 stands in for §19.10's Pu1 strength; the upgrade is discrete net
/// resolution, where a pull is a driver rather than a potential.
pub fn applyUnconnectedDrive(self: *Lower) Oom!void {
    if (self.directives.drives.len == 0) return;
    for (self.unconnected_inputs) |site| {
        const drive = Preprocessor.DriveRegion.inForce(self.directives.drives, self.tokStart(site.main_tok), .default);
        if (drive == .float) continue;
        const idx = self.node_voltages.get(site.name) orelse continue;
        if (idx == ground) continue;
        const info = self.out.disciplines.get(self.out.nodes.items(.disc)[idx]) orelse continue;
        if (!info.has_potential) continue;
        const target: lower_contrib.Target = .{ .access = .potential, .hi = idx, .lo = ground };
        const acc = self.accum.items[try lower_contrib.contribIndex(self, target, site.main_tok)];
        const old = try self.builder.readVariable(acc.resist, self.cur);
        const level: Mir.Value = if (drive == .pull1) .f_one else .f_zero;
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, level }));
        // §5.6.1.3: retained on every path, like an unconditional `<+`.
        try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    }
}

/// Returns the `nodes` row of net `name`, creating it on first use. Undeclared names
/// are implicit nets (§3.6.5); rows are created in source order.
pub fn internNode(self: *Lower, name: []const u8, discipline: []const u8) Oom!u16 {
    const gop = try self.node_voltages.getOrPut(self.arena, name);
    if (gop.found_existing) {
        if (discipline.len != 0 and gop.value_ptr.* != ground)
            self.out.nodes.items(.disc)[gop.value_ptr.*] = discipline;
        return gop.value_ptr.*;
    }
    const idx = try appendNode(self, name, discipline, .net);
    gop.value_ptr.* = idx;
    return idx;
}

/// Folds one §3.6.3.2 net_decl_assignment into a nodeset value for `node`.
/// "The initializer shall be a constant_expression": a failed fold reports E0365.
/// Parameters fold (§3.4). A string folds to 0.0, the unknown's own start value.
///
/// ponytail: the value is frozen at the parameter's declared default, so a card
/// override leaves a stale initial guess (never a wrong answer). Upgrade: keep the
/// `Ast.ExprId` and export `nodeset(model)` the way `derive()` is.
pub fn recordNodeset(self: *Lower, node: u16, e: Ast.ExprId, tok: u32, name: []const u8) Oom!void {
    const c = lower_constfold.constEval(self, e) orelse {
        var b = self.errWith(tok, .E0365);
        b.msg("the initializer of `{s}` is not a constant expression", .{name});
        b.note("§3.6.3.2 gives it to the analog solver as a nodeset value for the potential of `{s}`, which is fixed before the solve starts", .{name});
        try b.emit();
        return;
    };
    try self.out.nodesets.append(self.arena, .{ .node = node, .value = c.asReal(), .tok = tok });
}

/// Mints the §4.5.2 unknown one analog operator site introduces, spelled
/// `<op>$<k>`. Never deduped: each site owns its own unknown and row.
pub fn opStateNode(self: *Lower, op: []const u8, abstol: f64) Oom!u16 {
    const name = try std.fmt.allocPrint(self.arena, "{s}${d}", .{ op, self.node_state.op_states });
    self.node_state.op_states += 1;
    return appendNode(self, name, "", .{ .op_state = abstol });
}

/// The one place a `nodes` row is created, fixing its kind and spelling together.
/// Does not dedupe: each caller owns identity (`node_voltages` for a net,
/// `flow_unknowns` for a branch, `port_probes` for a port), and two distinct
/// unknowns may ask for one name.
fn appendNode(self: *Lower, name: []const u8, discipline: []const u8, kind: NodeKind) Oom!u16 {
    if (self.out.nodes.len == max_nodes) {
        const m = self.out.module.?;
        if (!self.node_state.full) try self.err(m.main_tok, .E1015, "`{s}` needs more than {d} nets and unknowns", .{ self.file.str(m.name), max_nodes });
        self.node_state.full = true;
        return 0; // stands in for the row, so lowering reports the rest
    }
    const idx: u16 = @intCast(self.out.nodes.len);
    const spelling = try uniqueSpelling(self, name);
    try self.node_state.spellings.put(self.arena, spelling, {});
    try self.out.nodes.append(self.arena, .{ .name = spelling, .kind = kind, .disc = discipline, .dir = .unspecified });
    try self.node_state.probe_cache.append(self.arena, .undef);
    return idx;
}

/// `name`, or the first `name#k` nobody has taken, since each slot is one `U` member.
/// Two slots can want one spelling: a net named `gnd` (§2.7) against the reference
/// node, or an escaped net `\flow(p,n)` (§2.8.1) against branch (p,n). `#` is not a
/// §2.7 identifier character, so a suffixed name cannot collide with a source one.
/// The suffix falls on the later slot, so it depends only on source order.
fn uniqueSpelling(self: *Lower, name: []const u8) Oom![]const u8 {
    if (!self.node_state.spellings.contains(name)) return name;
    // Losing candidates are built on the stack; only the winner reaches the arena.
    var buf: [spelling_buf_len]u8 = undefined;
    var k: u32 = 1;
    while (true) : (k += 1) {
        const cand = std.fmt.bufPrint(&buf, "{s}#{d}", .{ name, k }) catch
            try std.fmt.allocPrint(self.arena, "{s}#{d}", .{ name, k });
        if (!self.node_state.spellings.contains(cand)) return self.arena.dupe(u8, cand);
    }
}

/// Widest spelling `uniqueSpelling` builds without spilling: two 1024-character
/// identifiers (the bound `elem_key_len` uses), punctuation, and `#` with a `u32`.
const spelling_buf_len = 2 * 1024 + 32;

/// §3.12.1 "A port branch ... is a branch between the upper and lower
/// connections of the port", Syntax 3-9 `branch ( < port_identifier > )`.
/// Checked per source module, since after flattening a child's port may be an
/// internal node of the device.
pub fn checkPortBranchDecls(self: *Lower) Oom!void {
    const ex = &self.file.exprs;
    for (self.file.modules[self.file.builtin_modules..]) |*m| for (m.branches) |b| {
        if (!b.is_port_branch) continue;
        const t = if (ex.tag(b.hi) == .index) ex.lhs(b.hi) else b.hi;
        if (ex.tag(t) != .ident) continue; // nodeOf reports a malformed terminal
        const name = ex.strOf(t);
        for (m.ports) |p| {
            if (p.name == name) break;
        } else try self.err(b.main_tok, .E0372, "`{s}` is declared over `{s}`, which is not a port of `{s}`", .{
            self.file.str(b.name), self.file.str(name), self.file.str(m.name),
        });
    };
}

/// Resolves a net reference, `n` or `n[i]`, to a `nodes` row. An access function
/// takes "scalars or individual elements of a vector" (§5.5.2), so a bare vector
/// name reports E0351 and an undeclared element E0351/E0352.
pub fn nodeOf(self: *Lower, e: Ast.ExprId) Oom!u16 {
    if (e == .none) return ground;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            // §2.8.1, see `netKey`. The reference to `\bus[0] ` is an `.ident`
            // and the reference to element 0 of `bus` is an `.index`, so the two
            // never share a path here; only the KEY had to be kept apart.
            const name = try netKey(self, self.file.str(ex.strOf(e)), ex.mainTok(e));
            if (self.out.vectors.get(name)) |r| {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` is a vector [{d}:{d}]; name one element of it", .{ name, r.msb, r.lsb });
                return ground;
            }
            // IEEE 1364 §19.2's `none`: this is the one place an undeclared name
            // becomes a net. Checked here, not in `internNode`, which also interns
            // every declared net.
            if (!self.node_voltages.contains(name))
                try rejectImplicitNet(self, name, self.file.exprs.mainTok(e));
            return internNode(self, name, "");
        },
        // §6.7.1 a hierarchical terminal, `V(u.a)`: elaboration named the child's
        // net `u.a`, so `flatName` resolves it. It never interns a new node:
        // §3.6.5's implicit net applies only to an undeclared simple name.
        .hier_ident => {
            const name = try lower_expr.flatName(self, e);
            if (!self.node_voltages.contains(name)) {
                try self.err(self.file.exprs.mainTok(e), .E0901, "`{s}` names no net in the elaborated design", .{name});
                return ground;
            }
            return internNode(self, name, "");
        },
        .index => {
            const base = ex.lhs(e);
            // `u.v[1]`: §6.7.1's hierarchical terminal, one element of it.
            const name = switch (ex.tag(base)) {
                .ident => self.file.str(ex.strOf(base)),
                .hier_ident => try lower_expr.flatName(self, base),
                else => { // else: a select of anything but a net name is no net reference: E0306
                    try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
                    return ground;
                },
            };
            const r = self.out.vectors.get(name) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` was not declared with a range", .{name});
                return ground;
            };
            // §5.5.2 "The index must be a constant expression, though it may
            // include genvar variables"; `tryUnrollFor` binds the genvar in
            // `consts` for each unrolled copy.
            const i = lower_constfold.constEval(self, ex.rhs(e)) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0352, "index into `{s}` is not a constant expression", .{name});
                return ground;
            };
            if (!r.has(i.asInt())) {
                try self.err(self.file.exprs.mainTok(e), .E0352, "`{s}` is [{d}:{d}], so {d} is not one of its elements", .{ name, r.msb, r.lsb, i.asInt() });
                return ground;
            }
            return internNodeElem(self, name, i.asInt());
        },
        else => { // else: not a net reference: E0306
            try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
            return ground;
        },
    }
}

/// The node-table key for a net named by the source identifier at `tok`.
///
/// §2.8.1: "Escaped identifiers shall start with the backslash character (\) and
/// end with white space ... Neither the leading backslash character nor the
/// terminating white space is considered to be part of the identifier." So
/// `electrical \bus[0] ;` declares a SCALAR net whose name is the five
/// characters `bus[0]`, the same as `internNodeElem`'s name for element 0 of
/// `electrical [0:1] bus`, which is a generated name (§3.13.3) and a different
/// object. Only the token still shows the `\` (the parser strips it), so an escaped
/// name ending in `]` gets the `\` back in its key; other names keep theirs.
///
/// ponytail: allocates a fresh arena copy per reference; such names are rare.
pub fn netKey(self: *Lower, name: []const u8, tok: u32) Oom![]const u8 {
    if (name.len == 0 or name[name.len - 1] != ']') return name;
    if (tok >= self.tok_starts.len) return name;
    const at = self.tok_starts[tok];
    if (at >= self.src.len or self.src[at] != '\\') return name;
    return std.fmt.allocPrint(self.arena, "\\{s}", .{name});
}

/// `internNode` for a vector element, spelled as the source does (`bus[3]`).
/// Looks up on a stack buffer and allocates only for a new element.
fn internNodeElem(self: *Lower, base: []const u8, i: i64) Oom!u16 {
    var buf: [lower_param.elem_key_len]u8 = undefined;
    const key = try lower_param.elemKey(self, &buf, base, &.{i});
    const name = self.node_voltages.getKey(key) orelse try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, i });
    return internNode(self, name, "");
}

/// Folds a declared `[msb:lsb]` (§3.6.3 Syntax 3-6); the bounds are constant
/// expressions (`electrical [0:4-1] in;`, §6.5.2.2). Returns null after a diagnostic.
pub fn foldDim(self: *Lower, d: Ast.Dim, tok: u32) Oom!?VecRange {
    const msb = lower_constfold.shapeEval(self, d.msb) orelse {
        try self.err(tok, .E0352, "the msb of the range is not a constant expression", .{});
        return null;
    };
    const lsb = lower_constfold.shapeEval(self, d.lsb) orelse {
        try self.err(tok, .E0352, "the lsb of the range is not a constant expression", .{});
        return null;
    };
    const r: VecRange = .{ .msb = msb.asInt(), .lsb = lsb.asInt() };
    const n = @abs(@as(i128, r.msb) - r.lsb) + 1;
    if (n > max_nodes) {
        try self.err(tok, .E1015, "the range [{d}:{d}] has {d} elements", .{ r.msb, r.lsb, n });
        return null;
    }
    return r;
}

/// Returns a port's range from whichever of its two declarations carries one. When
/// both do, "the range specification between the two declarations of a port shall
/// be identical" (LRM §6.5.2.2), compared after folding: `input [0:3] in;
/// electrical [0:4-1] in;` is valid, `input [3:0] in; electrical [0:3] in;` is not.
pub fn portRange(self: *Lower, p: *const Ast.Port) Oom!?VecRange {
    const dir_r = if (p.range) |d| try foldDim(self, d, p.main_tok) else null;
    const ty_r = if (p.type_range) |d| try foldDim(self, d, p.main_tok) else null;
    if (dir_r) |a| if (ty_r) |b| {
        if (a.msb != b.msb or a.lsb != b.lsb)
            try self.err(p.main_tok, .E0350, "`{s}` is [{d}:{d}] where it is given a direction and [{d}:{d}] where it is given a discipline", .{
                self.file.str(p.name), a.msb, a.lsb, b.msb, b.lsb,
            });
    };
    return dir_r orelse ty_r;
}

/// The vector a branch terminal names, or null when it is a scalar (or not a
/// bare identifier at all: `branch (a[1], b)` is two scalars).
pub fn vecTerminal(self: *const Lower, e: Ast.ExprId) ?VecRange {
    if (e == .none) return null;
    if (self.file.exprs.tag(e) != .ident) return null;
    return self.out.vectors.get(self.file.str(self.file.exprs.strOf(e)));
}

/// §3.12 a vector branch. The LRM's own example:
///
///     electrical [3:5]a;
///     electrical [1:3]b;
///     branch (a,b) br1;  // Branch br1 is of size 3 and can be indexed 0 to 2
///
/// The terminals pair "in a parallel one-to-one fashion" in declaration order, a
/// scalar terminal repeats (Figure 3-2), and the branch is indexed `[0:size-1]`.
/// Elements are registered in `branches` under scalarised names; the base name
/// goes into `vectors` for the vector diagnostics.
pub fn declareVectorBranch(self: *Lower, b: *const Ast.BranchDecl) Oom!void {
    const name = self.file.str(b.name);
    const hv = vecTerminal(self, b.hi);
    const lv = vecTerminal(self, b.lo);
    if (hv) |h| if (lv) |l| {
        if (h.size() != l.size()) {
            try self.err(b.main_tok, .E0353, "`{s}` joins a size-{d} vector to a size-{d} one", .{ name, h.size(), l.size() });
            return;
        }
    };
    const size = if (hv) |h| h.size() else lv.?.size();
    // A scalar terminal is the same node on every element (Figure 3-2).
    const h_scalar = if (hv == null) try nodeOf(self, b.hi) else ground;
    const l_scalar = if (lv == null) try nodeOf(self, b.lo) else ground;
    const h_name = if (hv != null) self.file.str(self.file.exprs.strOf(b.hi)) else "";
    const l_name = if (lv != null) self.file.str(self.file.exprs.strOf(b.lo)) else "";
    for (0..size) |k| {
        const hi = if (hv) |h| try internNode(self, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ h_name, h.at(@intCast(k)) }), "") else h_scalar;
        const lo = if (lv) |l| try internNode(self, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ l_name, l.at(@intCast(k)) }), "") else l_scalar;
        // §3.12 → §3.11 once: every element pairs the same two disciplines.
        if (k == 0) try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo);
        try self.branches.put(self.arena, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, @as(i64, @intCast(k)) }), .{
            .hi = hi,
            .lo = lo,
            .id = newBranchId(self),
        });
    }
    try self.out.vectors.put(self.arena, name, .{ .msb = 0, .lsb = @as(i64, size) - 1 });
}

/// Returns the name codegen prints for a `nodes` row, or "gnd" for `ground`.
pub fn nodeName(self: *const Lower, idx: u16) []const u8 {
    return self.out.nodeName(idx);
}

/// Returns a fresh §5.4.1 branch identity, one per declared branch name (array
/// elements included). Ids are per-module, never reused, and private to lowering.
pub fn newBranchId(self: *Lower) u32 {
    self.node_state.last_branch_id += 1;
    return self.node_state.last_branch_id;
}

/// Returns the §4.4 potential probe of one node, deduped so a node is one
/// `block_param` (codegen's `x[idx]`); ground is the literal 0 (§1.3.1.1).
pub fn probe(self: *Lower, idx: u16) Oom!Mir.Value {
    if (idx == ground) return .f_zero;
    if (self.node_state.probe_cache.items[idx] != .undef) return self.node_state.probe_cache.items[idx];
    const v = try self.mir.addBlockParam(self.arena, idx);
    self.node_state.probe_cache.items[idx] = v;
    return v;
}

/// Returns the `nodes` row of branch (hi, lo)'s current, the solver unknown a §5.4.2
/// flow read creates. Deduped on the node pair (the §5.4.1 identity), not the
/// printed name, since a net called `gnd` prints like the reference node.
pub fn flowUnknown(self: *Lower, hi: u16, lo: u16) Oom!u16 {
    const gop = try self.out.flow_unknowns.getOrPut(self.arena, .{ .hi = hi, .lo = lo });
    if (gop.found_existing) return gop.value_ptr.*;
    const name = try std.fmt.allocPrint(self.arena, "flow({s},{s})", .{ nodeName(self, hi), nodeName(self, lo) });
    // The tolerance node is the HIGH one: a branch unknown carries no discipline
    // of its own (§3.6.1.2's abstol has to come from somewhere).
    const u = try appendNode(self, name, "", .{ .branch_flow = hi });
    gop.value_ptr.* = u;
    return u;
}

/// Returns the §5.4.3 unknown carrying `I(<p>)`, spelled `flow(<p>)`. `port_probes`
/// is the identity (a linear scan over the module's ports), so a net spelled
/// `flow(<p>)` cannot take over the port's current.
pub fn portFlowUnknown(self: *Lower, p: u16) Oom!u16 {
    for (self.out.port_probes.items) |pp| {
        if (pp.port == p) return pp.u;
    }
    const name = try std.fmt.allocPrint(self.arena, "flow(<{s}>)", .{nodeName(self, p)});
    const u = try appendNode(self, name, "", .{ .port_flow = p });
    try self.out.port_probes.append(self.arena, .{ .port = p, .u = u });
    return u;
}
