//! Hierarchical names: instance paths and the flat names they produce.
//!
//! In: an instance path. Out: the flat, injective name the lowered design uses.
//!
//! LRM clauses this file's code cites: §3.6.1.4, §3.6.5, §3.11, §6.2.2, §6.3.6, §6.4, §6.4.2, §6.7, E.3.2.1.
//!
//! Cut verbatim from `elaborate.zig`. Functions take `self: *Flatten` and are called
//! directly, `elab_names.f(self, ...)`; `elaborate.zig` aliases only what other modules call.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const discipline = @import("../lower/discipline.zig");
const Lexer = @import("frontend").Lexer;
const Error = elaborate.Error;
const Unit = Flatten.Unit;

// ---- names ------------------------------------------------------------

/// `path ++ local`, interned. The flat name IS the §6.7 path, so the path
/// table (`Design.names`) needs no row for it.
pub fn join(self: *Flatten, path: []const u8, local: Ast.StrId) Error!Ast.StrId {
    const s = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(local) });
    return self.ctx.file.intern(self.ctx.arena, s);
}

pub fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) Error!void {
    // A port already bound to the parent's net keeps that binding: `inout p;
    // electrical p;` leaves a NetDecl behind for the same name, and rewriting
    // it here would disconnect the port.
    if (unit.rename.contains(local)) return;
    try unit.rename.put(self.ctx.arena, local, try join(self, path, local));
}

/// The flat spelling of a name in the unit being cloned. A name with no
/// entry is not the unit's — a block-local, a function formal, or an
/// undeclared net §3.6.5 makes implicit — and keeps its own spelling.
pub fn flat(self: *Flatten, local: Ast.StrId) Ast.StrId {
    return self.unit.rename.get(local) orelse local;
}

/// The net a port connection names. §6.2.2 allows an expression; VerA takes
/// a scalar net reference, which is what a topology join can be expressed as
/// without introducing a node and an equation for the expression's value.
pub fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
    if (e == .none) return null;
    if (self.ctx.file.exprs.tag(e) != .ident) return null;
    return self.ctx.file.exprs.strOf(e);
}

/// E.3.3 name scoping: "in the resolution hierarchy of names during
/// elaboration a module or paramset defined in the Verilog-AMS will always be
/// selected in favor of a SPICE primitive, model, or subcircuit using exactly
/// the same name". So the user's declarations first, the shipped Annex E
/// prelude second — which is the whole of the rule, because the prelude is a
/// prefix of `modules` (see `Ast.SourceFile.builtin_modules`).
///
/// E.3.3's "may issue a warning stating that the Verilog-AMS module ... is
/// used instead of the SPICE primitive" is declined: `may`, and a warning on
/// every use of a common word like `resistor` is noise.
///
/// THE THIRD ARM IS E.2.1's SECOND SENTENCE: "if no exact match is found, the
/// mixed-case name shall match the same name defined within SPICE regardless
/// of the case." Scoped to the netlist-derived tail of the prelude
/// (`Ast.SourceFile.netlistModules`) and reached only after both exact passes
/// fail, which is exactly what the clause says: the case-sensitive arm is
/// "from within Verilog-AMS HDL, a mixed-case name matches the same name with
/// an identical case", and E.3.3 adds that a differing-case match "does not
/// interfere" with the SPICE object. Names arrive from the netlist already
/// lower-cased (`spice_cards`), so one `eqlIgnoreCase` is the whole rule.
///
/// A netlist `.MODEL resistor` and Table E.1's `resistor` are ordered
/// primitive-first here, by the exact-match pass. Annex E does not say which
/// wins — E.3.3 only orders a Verilog-AMS module against a SPICE object, not
/// two SPICE objects — and no fixture pins it; primitive-first is chosen
/// because Table E.1 is the part the LRM standardises.
pub fn findModule(self: *Flatten, name: Ast.StrId) ?*const Ast.ModuleDecl {
    for (self.ctx.file.userModules()) |*m| if (m.name == name) return m;
    for (self.ctx.file.modules[0..self.ctx.file.builtin_modules]) |*m| {
        if (m.name == name) return m;
    }
    const want = self.ctx.file.str(name);
    for (self.ctx.file.netlistModules()) |*m| {
        if (std.ascii.eqlIgnoreCase(self.ctx.file.str(m.name), want)) return m;
    }
    return null;
}

/// §6.4: "The second identifier is usually the name of a module with which
/// the paramset is associated. The second identifier may instead be the name
/// of a second paramset. A chain of paramsets may be defined, but the last
/// paramset in the chain shall reference a module."
///
/// The links, near (the one the instance named) to far. `.none` only when a
/// link's second identifier names neither — E0904, reported here.
///
/// The chain is walked by NAME and the first declaration of that name wins.
/// §6.4.2's selection rules are written for "every instance that references
/// that name", and a chain link is not an instance, so an overloaded inner
/// link has no instance context to select against.
pub fn paramsetChain(
    self: *Flatten,
    near: *const Ast.ParamsetDecl,
    out: *std.ArrayList(*const Ast.ParamsetDecl),
) Error!bool {
    var link = near;
    while (true) {
        try out.append(self.ctx.arena, link);
        if (findModule(self, link.target) != null) return true;
        const next = for (self.ctx.file.paramsets) |*p| {
            if (p.name == link.target) break p;
        } else {
            try self.err(link.main_tok, .E0904, "`{s}`, the module this paramset specializes", .{
                self.ctx.file.str(link.target),
            });
            return false;
        };
        // A chain that closes on itself never reaches a module, so §6.4's
        // "the last paramset in the chain shall reference a module" is
        // violated by the cycle itself.
        for (out.items) |seen| if (seen == next) {
            try self.err(next.main_tok, .E0904, "`{s}`: the paramset chain is a cycle and never reaches a module", .{
                self.ctx.file.str(next.name),
            });
            return false;
        };
        link = next;
    }
}

/// The module at the end of `ps`'s chain, or `null` after an E0904.
pub fn chainEnd(self: *Flatten, ps: *const Ast.ParamsetDecl) Error!?*const Ast.ModuleDecl {
    var chain: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    if (!try paramsetChain(self, ps, &chain)) return null;
    return findModule(self, chain.items[chain.items.len - 1].target).?;
}

/// Annex E — is `m` one of the shipped Table E.1 primitives? Identity, not
/// name: a user module called `resistor` shadows the primitive (E.3.3, see
/// `findModule`) and must NOT get E.3.2's treatment, because E.3.2.1 says the
/// port_discipline machinery "shall only apply to analog primitives ... for
/// other modules as well as the ports of all other modules it shall be
/// ignored".
///
/// Table E.1's own rows only: a module synthesized from a netlist `.MODEL`
/// card is a wrapper AROUND a primitive, not a primitive, and its body is one
/// instantiation with no access function of its own to substitute.
pub fn isPrimitive(self: *Flatten, m: *const Ast.ModuleDecl) bool {
    for (self.ctx.file.tablePrimitives()) |*p| {
        if (p == m) return true;
    }
    return false;
}

/// E.3.2.1 `port_discipline`: "The value shall be of type string and the
/// value must be a valid discipline of domain continuous. This attribute
/// shall only apply to analog primitives or the ports of analog primitives;
/// for other modules as well as the ports of all other modules it shall be
/// ignored." So it is judged here, on an instance `isPrimitive` answered
/// yes for, and nowhere else.
///
/// `module.attrs` holds every attr_spec of the instantiating module without
/// its target (`Parser.skipAttributes`), so the target is recovered from the
/// token stream: the first token after the attribute-instance run an
/// attr_spec sits in is the item it decorates, and that item is this
/// instantiation (its module identifier, with no `;` before the instance
/// name) or one of its port connections.
pub fn checkPortDiscipline(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance) Error!void {
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.ctx.file.str(a.name), "port_discipline")) continue;
        if (!decorates(self, decoratedTok(self, a.main_tok), inst)) continue;
        // §2.9: a valueless attr_spec has the value 1, which is not a string.
        const c = if (a.value == .none)
            constfold.Const{ .int = 1 }
        else
            // Not constant: lowering's E0357 (§2.9) owns that answer.
            constfold.fold(self.ctx.file, a.value, ParamEnv{ .self = self, .local = true }) orelse continue;
        const want = switch (c) {
            .str => |sv| sv,
            else => {
                try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline requires a string naming a continuous discipline", .{});
                continue;
            },
        };
        const d = discipline.declOf(self.ctx.file, self.ctx.file.strings.find(want) orelse .none) orelse {
            try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline names an undeclared discipline `{s}`", .{want});
            continue;
        };
        if (discipline.domainOf(d) != .continuous)
            try self.err(a.main_tok, .E0358, "E.3.2.1: port_discipline requires a continuous discipline; `{s}` is not one", .{want});
    }
}

/// The source text of token `t`.
fn tokText(self: *Flatten, t: u32) []const u8 {
    const sp = Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, t);
    return self.ctx.src[sp.start..sp.end];
}

/// The first token after the run of `(* ... *)` instances that token `t`
/// (an attr_name) is inside. §2.9 forbids nesting, so the first `*)` closes.
fn decoratedTok(self: *Flatten, t: u32) u32 {
    const n: u32 = @intCast(self.ctx.tok_starts.len);
    var i = t;
    while (i < n) {
        while (i < n and !std.mem.eql(u8, tokText(self, i), "*)")) i += 1;
        i += 1;
        if (i >= n or !std.mem.eql(u8, tokText(self, i), "(*")) return i;
    }
    return i;
}

/// Is token `t` the start of `inst`'s instantiation or of one of its port
/// connections? A.4.1 attaches `{ attribute_instance }` to both.
fn decorates(self: *Flatten, t: u32, inst: *const Ast.Instance) bool {
    for (inst.ports) |c| if (c.main_tok == t) return true;
    if (t >= inst.main_tok or !std.mem.eql(u8, tokText(self, t), self.ctx.file.str(inst.module))) return false;
    // `resistor r1(a, b), r2(c, d);` shares one attribute list; a `;` between
    // means `t` began an earlier statement.
    var i = t + 1;
    while (i < inst.main_tok) : (i += 1) if (std.mem.eql(u8, tokText(self, i), ";")) return false;
    return true;
}

/// E.3.2 the access function a shipped primitive's `V` or `I` means on the
/// net its port was connected to.
///
/// Table E.1's Behavior column is written in V and I for every row, including
/// rows whose ports need not be electrical: E.3.2 exists precisely so a
/// primitive can "be used in any design, including mixed disciplines", and
/// E.3.2.1's own example is a `vcvs` whose output pair is electrical and whose
/// control pair is `rotational_omega` — one instance, two natures, one
/// equation `V(p,n) = gain*V(ps,ns)`. So the table's V is "the potential of
/// this port pair" and its I is "the flow", and the concrete spelling is the
/// access function (§3.6.1.4) of whatever discipline the port resolved to.
///
/// The discipline itself is NOT read from the `port_discipline` attribute.
/// E.3.2 orders the three sources — the attribute, "the resolution of the
/// discipline", then electrical — and after the flatten a connected port IS
/// the parent's net (Ruling E), so the resolution has already happened and its
/// answer is that net's declared discipline. An attribute asking for a
/// discipline the connected net does not have would be a §3.11 error either
/// way, which is why every E.3.2.1 example declares the two together. The
/// ceiling: an UNCONNECTED port of a primitive carrying the attribute keeps
/// the prelude's `electrical`, since nothing resolved it and the attribute is
/// the only remaining source.
///
/// Applies to the prelude's bodies only (`Unit.primitive`). A user module's
/// `V` is a request for V, and getting Theta instead would be a compiler
/// rewriting the source.
pub fn primitiveAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId) Ast.StrId {
    const which: Ast.PotentialOrFlow = blk: {
        const a_ = self.ctx.file.str(access);
        if (std.mem.eql(u8, a_, "V")) break :blk .potential;
        if (std.mem.eql(u8, a_, "I")) break :blk .flow;
        return access; // not one of the table's two spellings
    };
    const name = netRefName(self, net) orelse return access;
    const disc = self.disc_of.get(name) orelse .none;
    if (disc == .none) return access; // §3.6.5 implicit, or resolved later
    return discipline.accessOf(self.ctx.file, disc, which) orelse access;
}

/// §6.3.6's two automatic scaling rules, applied to one already-cloned
/// branch access. `flow_scale` is the running `$mfactor` product the unit
/// was instantiated with, as an expression in the flat namespace.
///
///     "All contributions to a branch flow quantity in the analog block
///      shall be multiplied by $mfactor. The value returned by any branch
///      flow probe in the analog block ... shall be divided by $mfactor."
///
/// The clause's own justification is why this is arithmetic on the SOURCE
/// and not a knob the host turns: "the behavior of the module in the design
/// is identical to the behavior of a quantity $mfactor of identical modules
/// with the same connections". A flattened child IS the design, so the only
/// place those $mfactor copies can come from is its own equations. (The
/// TOP's $mfactor is a different thing and stays with the host, which scales
/// the whole stamp by it — Table 9-29 gives the top the value 1.0, so
/// `unit.mfactor` is `.none` there and nothing here fires.)
///
/// Is this access a FLOW? The discipline of the net the terminal resolved to
/// names a flow nature, and §3.6.1.4's `access` attribute of that nature is
/// the spelling — the same three-step lookup `primitiveAccess` does, for the
/// same reason: `I` is electrical's spelling and not every discipline's.
///
/// ponytail: a NAMED branch (`I(br)`) is not in `disc_of`, so it is left
/// unscaled; the upgrade is a branch → net map here. Rules 3 and 4 (noise
/// power, multiplied for a flow contribution and divided for a potential
/// one) are likewise not applied — `mfactor_flow_noise.va` and
/// `mfactor_potential_noise.va` pin the unscaled top-level case only.
pub fn mfactorScale(
    self: *Flatten,
    value: Ast.ExprId,
    access: Ast.StrId,
    net: Ast.ExprId,
    op: Ast.BinaryOp,
    tok: u32,
) Error!?Ast.ExprId {
    if (self.unit.mfactor == .none) return null;
    const name = netRefName(self, net) orelse return null;
    const disc = self.disc_of.get(name) orelse return null;
    const flow = discipline.accessOf(self.ctx.file, disc, .flow) orelse return null;
    if (flow != access) return null; // a potential
    return try self.ctx.file.exprs.add(self.ctx.arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = value,
        .rhs = self.unit.mfactor,
        .extra = @intFromEnum(op),
    });
}

/// §6.2.2 an instance array bound: a constant expression, folded by the one
/// constant kernel (§4.2's integer typing, every operator); a real-valued
/// bound is not one. §3.4 makes a parameter a constant expression, so a bound
/// may read one — its value as this instance sees it, override included.
pub fn constInt(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = true }) orelse return null;
    return if (c == .int) c.int else null;
}

/// `constInt` for an expression already in the FLAT namespace (a cloned
/// declaration's range, say), so no name is renamed.
pub fn constIntFlat(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = false }) orelse return null;
    return if (c == .int) c.int else null;
}

/// `constfold.fold`'s identifiers, answered from the parameters flattened so
/// far. The bound is written in the instantiating module's LOCAL names, while
/// every value in `self.params` is already in the FLAT namespace — so only the
/// first lookup renames. A scalar parameter only; anything else declines.
const ParamEnv = struct {
    self: *Flatten,
    local: bool,
    depth: u8 = 0,

    pub fn leaf(env: ParamEnv, e: Ast.ExprId) ?constfold.Const {
        const self = env.self;
        const ex = &self.ctx.file.exprs;
        // ponytail: a depth cap, not cycle detection; a cyclic default is
        // lowering's diagnostic, this only has to terminate.
        if (ex.tag(e) != .ident or env.depth > 32) return null;
        const name = if (env.local) flat(self, ex.strOf(e)) else ex.strOf(e);
        for (self.params.items) |p| if (p.name == name and p.dims.len == 0) {
            const v = constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1 }) orelse return null;
            // §3.4.1: a declared `integer` type converts the value.
            return if (p.ty == .integer and v == .real) .{ .int = v.asIntExact() orelse return null } else v;
        };
        return null;
    }
    pub fn refuse(_: ParamEnv, _: Ast.ExprId) bool {
        return false;
    }
    pub fn signed(_: ParamEnv, _: Ast.ExprId) ?bool {
        return null;
    }
};
