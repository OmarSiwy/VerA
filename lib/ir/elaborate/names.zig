//! Hierarchical names: an instance path and a local name → the flat, injective
//! name the lowered design uses; module and paramset lookup; access-function
//! respelling across a port join; constant folding of instance bounds.
//! LRM §3.6.1.4, §3.6.5, §4.4, §6.2.2, §6.3.6, §6.4, §6.7, §7.4, E.3.2, E.3.3.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const discipline = @import("../discipline_rules.zig");
const Lexer = @import("frontend").Lexer;
const Error = elaborate.Error;
const Unit = Flatten.Unit;

/// §6.7 a hierarchical expression's path in the flattened namespace. Shared
/// by lowering and the pre-fold §3.4.7 alias-use check. Port joins are applied
/// by the caller because they are design connectivity, not name spelling.
pub fn flatReference(file: *const Ast.SourceFile, arena: std.mem.Allocator, module: ?*const Ast.ModuleDecl, e: Ast.ExprId) std.mem.Allocator.Error![]const u8 {
    var parts = file.exprs.nameParts(e);
    // §6.2.1 the `$root` prefix: "used to unambiguously refer to a top-level
    // instance or to an instance path starting from the root of the instantiation
    // tree", against a plain path, where "the ambiguity is resolved by giving
    // priority to the local scope". Elaboration's flat namespace IS rooted — a
    // name with no path prefix is a name of the top, so `$root.` is dropped.
    // The segment after it names a top-level instance (§6.7's
    // `$root.mymodule.u1`), and a flattened design's one top-level instance is
    // the device itself, so the top module's name drops with it.
    //
    // Not done in `Elaborate`'s clone: the top module's body is never cloned,
    // so the rule would only reach children. Here it applies to every unit.
    if (parts.len > 1 and file.strings.eql(parts[0], "$root")) parts = parts[1..];
    // The top module's own name, with or without `$root`: IEEE 1364 §12.6's
    // upward name referencing, which §6.7.1's last paragraph adopts, lets a
    // path open with the name of a module above the reference; §5.5.5's
    // example reads `V(top.a1.b)` from inside `b1`. The flattened namespace is
    // rooted at the top, so its name drops. A local of the same name wins
    // (§6.2.1 "priority to the local scope"): cloning has already renamed
    // part 0 of a child's local path, and the top's own instances are
    // checked here.
    if (parts.len > 1) if (module) |m| if (parts[0] == m.name and for (m.instances) |inst| {
        if (inst.name == parts[0]) break false;
    } else true) {
        parts = parts[1..];
    };
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0) try out.append(arena, elaborate.sep);
        try out.appendSlice(arena, file.str(p));
    }
    return out.toOwnedSlice(arena);
}

// ---- names ------------------------------------------------------------

/// Returns `path ++ local`, interned. The flat name is the §6.7 path, so the
/// path table (`Design.names`) needs no row for it.
pub fn join(self: *Flatten, path: []const u8, local: Ast.StrId) Error!Ast.StrId {
    const s = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(local) });
    return self.ctx.file.intern(self.ctx.arena, s);
}

/// A flat name `path ++ local`, not yet joined: the key shape of
/// `Flatten.defparams` and `Flatten.ooc`, probed with `getAdapted` and
/// `Context` so a lookup allocates nothing.
// A probe used to print the joined key into the compilation arena and drop
// it, once per parameter, alias, port and net of every instance.
pub const PathKey = struct {
    path: []const u8,
    local: []const u8,

    /// `std.hash_map.StringContext` over the joined bytes: Wyhash streamed
    /// over the two halves equals Wyhash of their concatenation, so the probe
    /// lands in the bucket the stored `path ++ local` key hashed to.
    pub const Context = struct {
        /// Returns `StringContext.hash(k.path ++ k.local)`.
        pub fn hash(_: Context, k: PathKey) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(k.path);
            h.update(k.local);
            return h.final();
        }
        /// Returns whether `stored` is exactly `k.path ++ k.local`.
        pub fn eql(_: Context, k: PathKey, stored: []const u8) bool {
            return stored.len == k.path.len + k.local.len and
                std.mem.startsWith(u8, stored, k.path) and
                std.mem.endsWith(u8, stored, k.local);
        }
    };
};

/// Binds `local` to its flat name `path ++ local` in `unit`'s rename map,
/// unless it is already bound (a port joined to the parent's net).
pub fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) Error!void {
    // A port already bound to the parent's net keeps that binding: `inout p;
    // electrical p;` leaves a NetDecl behind for the same name, and rewriting
    // it here would disconnect the port.
    if (unit.rename.contains(local)) return;
    try unit.rename.put(self.ctx.arena, local, try join(self, path, local));
}

/// Returns the flat spelling of a name in the unit being cloned. A name with
/// no entry is not the unit's (a block-local, a function formal, or a §3.6.5
/// implicit net) and keeps its own spelling.
pub fn flat(self: *Flatten, local: Ast.StrId) Ast.StrId {
    return self.unit.rename.get(local) orelse local;
}

/// Reports an instance whose module name declares nothing: E0904, or E0952
/// when the SPICE netlist has a `.MODEL` of that name whose type is a
/// primitive VerA does not support (E.1.2: "a particular SPICE netlist can
/// reference a primitive which is unsupported"). The name matches the card
/// as E.2.1 matches netlist names, regardless of case.
pub fn unknownModule(self: *Flatten, inst: *const Ast.Instance) Error!void {
    const want = self.ctx.file.str(inst.module);
    for (self.ctx.file.netlist_unsupported) |card| {
        const space = std.mem.indexOfScalar(u8, card, ' ').?; // `name type`
        if (!std.ascii.eqlIgnoreCase(card[0..space], want)) continue;
        return self.err(inst.main_tok, .E0952, "`{s}` is a SPICE `.MODEL` of type `{s}`, a primitive Table E.1 and VerA do not provide", .{ want, card[space + 1 ..] });
    }
    try self.err(inst.main_tok, .E0904, "`{s}`", .{want});
}

/// Returns the net a port connection names, or null when it is not a plain
/// identifier. §6.2.2 allows an expression; VerA takes a scalar net
/// reference, which a topology join can express without a new node.
pub fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
    if (e == .none) return null;
    if (self.ctx.file.exprs.tag(e) != .ident) return null;
    return self.ctx.file.exprs.strOf(e);
}

/// Returns the module `name` denotes, or null. Lookup order: user modules,
/// the LAST of several same-named ones (IEEE 1364-2005 §13.2.1.1, see
/// `warnRedefinedModules`), then the shipped Annex E prelude, since E.3.3 selects "a module or
/// paramset defined in the Verilog-AMS ... in favor of a SPICE primitive,
/// model, or subcircuit using exactly the same name". Last, E.2.1: "if no
/// exact match is found, the mixed-case name shall match the same name
/// defined within SPICE regardless of the case", over the netlist-derived
/// modules only (already lower-cased).
///
/// An exact paramset match returns null so the caller selects that paramset
/// before considering any SPICE definition. Declaration collisions with a
/// netlist are diagnosed by `warnSpiceShadows`; the optional warning for a
/// Table E.1 primitive alone is not issued. Two SPICE objects of the same
/// name resolve primitive-first; Annex E does not order them.
pub fn findModule(self: *Flatten, name: Ast.StrId) ?*const Ast.ModuleDecl {
    const user = self.ctx.file.userModules();
    var i = user.len;
    while (i > 0) {
        i -= 1;
        if (user[i].name == name) return &user[i];
    }
    for (self.ctx.file.paramsets) |ps| if (ps.name == name) return null;
    for (self.ctx.file.modules[0..self.ctx.file.builtin_modules]) |*m| {
        if (m.name == name) return m;
    }
    const want = self.ctx.file.str(name);
    for (self.ctx.file.netlistModules()) |*m| {
        if (std.ascii.eqlIgnoreCase(self.ctx.file.str(m.name), want)) return m;
    }
    return null;
}

/// IEEE 1364-2005 §13.2.1.1: "If multiple cells with the same name map to
/// the same library, then the LAST cell encountered shall be written to the
/// library" and "a warning message shall be issued" (W1152). §4.11's ban on
/// reusing a module name predates libraries; the digital binder reads it the
/// same way (`src/sim/digital/bind.zig` `libraries`), so one design
/// elaborates alike in both engines. `findModule` and `pickTop` take the
/// last definition.
pub fn warnRedefinedModules(self: *Flatten) Error!void {
    const user = self.ctx.file.userModules();
    for (user, 0..) |m, i| for (user[i + 1 ..]) |later| {
        if (later.name != m.name) continue;
        try self.ctx.bag.add(.lower, .W1152, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, later.main_tok), "`{s}` is defined again; this later definition is the module", .{self.ctx.file.str(m.name)});
        break;
    };
}

/// E.3.3 requires a warning for a same-named HDL declaration and a SPICE
/// model/subcircuit. Check definitions once, independently of the repeated
/// lookups used for ports, connect planning and parameter selection. Netlist
/// names have E.2.1's canonical lowercase spelling; a differently cased HDL
/// declaration leaves case-insensitive fallback available and does not warn.
pub fn warnSpiceShadows(self: *Flatten) Error!void {
    const file = self.ctx.file;
    for (file.netlistModules()) |spice| {
        for (file.userModules()) |m| if (m.name == spice.name)
            try spiceShadowWarning(self, m.name, m.main_tok, "module");
        for (file.paramsets) |ps| if (ps.name == spice.name)
            try spiceShadowWarning(self, ps.name, ps.main_tok, "paramset");
    }
}

fn spiceShadowWarning(self: *Flatten, name: Ast.StrId, tok: u32, kind: []const u8) Error!void {
    try self.ctx.bag.add(.lower, .W0951, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), "{s} `{s}` is used instead of the SPICE model or subcircuit when this name is instantiated", .{ kind, self.ctx.file.str(name) });
}

/// §6.4: "The second identifier is usually the name of a module with which
/// the paramset is associated. The second identifier may instead be the name
/// of a second paramset. A chain of paramsets may be defined, but the last
/// paramset in the chain shall reference a module."
///
/// Appends the chain's links to `out`, near (the one the instance named) to
/// far. Returns false after reporting E0904 when a link names neither a
/// module nor a paramset, or the chain is a cycle.
///
/// The chain is walked by name and the first declaration of that name wins.
/// §6.4.2's selection rules are written for "every instance that references
/// that name", and a chain link is not an instance, so an overloaded inner
/// link has no instance context to select against.
pub fn paramsetChain(
    self: *Flatten,
    near: *const Ast.ParamsetDecl,
    out: *std.ArrayList(*const Ast.ParamsetDecl),
) Error!bool {
    // Every link is a distinct paramset (a repeat is the cycle refused below).
    try out.ensureUnusedCapacity(self.ctx.arena, self.ctx.file.paramsets.len + 1);
    var link = near;
    while (true) {
        out.appendAssumeCapacity(link);
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

/// Returns whether `m` is one of the shipped Table E.1 primitives (Annex E).
/// Identity, not name: a user module called `resistor` shadows the primitive
/// (E.3.3, see `findModule`) and must not get E.3.2's treatment: E.3.2.1's
/// port_discipline "shall only apply to analog primitives ... for other
/// modules as well as the ports of all other modules it shall be ignored".
///
/// Table E.1's own rows only: a module synthesized from a netlist `.MODEL`
/// card is a wrapper around a primitive, not a primitive, and its body is one
/// instantiation with no access function of its own to substitute.
pub fn isPrimitive(self: *Flatten, m: *const Ast.ModuleDecl) bool {
    // Table E.1's rows are one contiguous run of `modules`, so identity is an
    // address range test, not a scan.
    const rows = self.ctx.file.tablePrimitives();
    const at = @intFromPtr(m);
    return at >= @intFromPtr(rows.ptr) and at < @intFromPtr(rows.ptr + rows.len);
}

/// Checks every E.3.2.1 `port_discipline` attribute on `inst` (E0358).
/// "The value shall be of type string and the
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

/// E.3.2's first source for one port of a primitive instance: the
/// `port_discipline` on its connection, else the one on the instance ("It
/// shall only apply to either the analog primitive itself or the port to which
/// it is attached"; E.3.2.1's `motor1` example overrides the instance's per
/// port). Null when neither carries a valid one; `checkPortDiscipline`
/// reports an invalid one.
pub fn portDisciplineAttr(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance, conn: Ast.PortConn) ?Ast.StrId {
    var on_inst: ?Ast.StrId = null;
    for (module.attrs) |a| {
        if (!std.mem.eql(u8, self.ctx.file.str(a.name), "port_discipline")) continue;
        const t = decoratedTok(self, a.main_tok);
        if (!decorates(self, t, inst)) continue;
        if (a.value == .none) continue;
        const c = constfold.fold(self.ctx.file, a.value, ParamEnv{ .self = self, .local = true }) orelse continue;
        if (c != .str) continue;
        const name = self.ctx.file.strings.find(c.str) orelse continue;
        const d = discipline.declOf(self.ctx.file, name) orelse continue;
        if (discipline.domainOf(d) != .continuous) continue;
        if (t == conn.main_tok) return name;
        for (inst.ports) |p| {
            if (p.main_tok == t) break;
        } else on_inst = name;
    }
    return on_inst;
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

/// Returns the access function a shipped primitive's `V` or `I` means on the
/// net its port was connected to (E.3.2).
///
/// Table E.1's Behavior column writes V and I for every row, but E.3.2 lets a
/// primitive "be used in any design, including mixed disciplines" (E.3.2.1's
/// `vcvs` with a `rotational_omega` control pair). So V is the port pair's
/// potential and I its flow, spelled with the §3.6.1.4 access function of the
/// discipline the net resolved to. The discipline is read from the net,
/// where `walkInstances` binds E.3.2's three sources in order.
///
/// Limits: an unconnected primitive port carrying the attribute keeps the
/// prelude's `electrical`, and a primitive cloned before a later level
/// resolves its net keeps V/I. Applies to prelude bodies only
/// (`Unit.primitive`); a user module's `V` means V.
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

/// §4.4: "The access function name shall match the discipline declaration
/// for the nets, ports, or branch given in the argument expression list." In a
/// child, that declaration is the child's own: §7.4 resolves disciplines only
/// for nets "whose discipline is undeclared", and §6.5.8 lets one node carry
/// several continuous disciplines. So an access on a bound port is judged
/// against the port's local discipline (`Unit.port_disc`), E0501 here since
/// after the join lowering sees only the parent's net, and then respelled as
/// the same half of the net it was joined to, the rewrite `primitiveAccess`
/// makes for Table E.1's V and I. `net` is the terminal as the child wrote it,
/// `flat_net` the same terminal cloned.
///
/// When the joined net's discipline binds no nature for that half (§3.11.1's
/// natureless or domainless parent, compatible with the child's), there is no
/// spelling to respell to: the access keeps the child's name and is recorded
/// `local_only`, so lowering does not judge it again against the net
/// (`Design.local_accesses`).
///
/// ponytail: the respelling uses the net's discipline as known at the join;
/// a §7.7.2 `resolveto` re-decided after the walk (`resolveMultiCandidates`)
/// is not seen, the same ceiling `primitiveAccess` and `mfactorScale` have.
pub fn localAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, flat_net: Ast.ExprId, tok: u32) Error!LocalAccess {
    const file = self.ctx.file;
    const keep: LocalAccess = .{ .name = access };
    const local = self.unit.port_disc.get(netRefName(self, net) orelse return keep) orelse return keep;
    const disc = self.disc_of.get(netRefName(self, flat_net) orelse return keep) orelse return keep;
    if (disc == local) return keep;
    // §5.5.1 the generic spellings name a half on every discipline.
    const a = file.str(access);
    if (std.mem.eql(u8, a, "potential") or std.mem.eql(u8, a, "flow")) return keep;
    const half: Ast.PotentialOrFlow = if (discipline.accessOf(file, local, .potential) == access)
        .potential
    else if (discipline.accessOf(file, local, .flow) == access)
        .flow
    else {
        try self.err(tok, .E0501, "`{s}` is not an access function of `{s}`, which this module declares `{s}`", .{
            a, file.str(file.exprs.strOf(net)), file.str(local),
        });
        return keep;
    };
    const name = discipline.accessOf(file, disc, half) orelse return .{ .name = access, .local_only = true };
    return .{ .name = name };
}

/// `localAccess`'s answer: the spelling, and whether only the child's
/// declaration can judge it.
pub const LocalAccess = struct { name: Ast.StrId, local_only: bool = false };

/// Returns `value` multiplied or divided (`op`) by the unit's running
/// `$mfactor` product when `access` is the flow access of `net`'s discipline,
/// else null (§6.3.6's two automatic scaling rules).
///
///     "All contributions to a branch flow quantity in the analog block
///      shall be multiplied by $mfactor. The value returned by any branch
///      flow probe in the analog block ... shall be divided by $mfactor."
///
/// A flattened child's $mfactor copies exist only in its own equations, so
/// the scaling is source arithmetic. The top's $mfactor stays with the host
/// (Table 9-29's 1.0; `unit.hier.get(.mfactor)` is `.none` there and nothing fires).
///
/// ponytail: a named branch (`I(br)`) is not in `disc_of`, so it is left
/// unscaled; the upgrade is a branch → net map here. Rules 3 and 4 (noise
/// power) are not applied; `mfactor_flow_noise.va` and
/// `mfactor_potential_noise.va` pin the unscaled top-level case only.
pub fn mfactorScale(
    self: *Flatten,
    value: Ast.ExprId,
    access: Ast.StrId,
    net: Ast.ExprId,
    op: Ast.BinaryOp,
    tok: u32,
) Error!?Ast.ExprId {
    if (self.unit.hier.get(.mfactor) == .none) return null;
    const name = netRefName(self, net) orelse return null;
    const disc = self.disc_of.get(name) orelse return null;
    const flow = discipline.accessOf(self.ctx.file, disc, .flow) orelse return null;
    if (flow != access) return null; // a potential
    return try self.ctx.file.exprs.add(self.ctx.arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = value,
        .rhs = self.unit.hier.get(.mfactor),
        .extra = @backingInt(op),
    });
}

/// Folds a §6.2.2 instance array bound, written in the current unit's local
/// names, to an integer; null when it does not fold or is real. A bound may
/// read a parameter (§3.4), with this instance's overrides applied.
pub fn constInt(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = true }) orelse return null;
    return if (c == .int) c.int else null;
}

/// `constInt` for an expression already in the flat namespace (a cloned
/// declaration's range, say), so no name is renamed.
pub fn constIntFlat(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = false }) orelse return null;
    return if (c == .int) c.int else null;
}

/// §6.4.2 folds an override in its source namespace. When `reads` is supplied,
/// it records which flattened parameter values an overload choice used, for
/// the same host shape check that protects §6.6 generate selection.
pub fn constValue(self: *Flatten, e: Ast.ExprId, local: bool, reads: ?[]bool) ?constfold.Const {
    return constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = local, .reads = reads });
}

/// `constfold.fold`'s identifiers, answered from the parameters flattened so
/// far. The bound is written in the instantiating module's local names, while
/// every value in `self.params` is already flat, so only the first lookup
/// renames. A scalar parameter only; anything else declines.
const ParamEnv = struct {
    self: *Flatten,
    local: bool,
    depth: u8 = 0,
    reads: ?[]bool = null,

    /// Resolves an identifier to a flattened scalar parameter's folded value.
    pub fn leaf(env: ParamEnv, e: Ast.ExprId) ?constfold.Const {
        const self = env.self;
        const ex = &self.ctx.file.exprs;
        // ponytail: a depth cap, not cycle detection; a cyclic default is
        // lowering's diagnostic, this only has to terminate.
        if (ex.tag(e) != .ident or env.depth > 32) return null;
        const name = if (env.local) flat(self, ex.strOf(e)) else ex.strOf(e);
        for (self.params.items, 0..) |p, i| if (p.name == name and p.dims.len == 0) {
            if (env.reads) |reads| reads[i] = true;
            if (!p.is_local and p.ty != .string) for (self.ctx.param_overrides) |o| {
                if (!std.mem.eql(u8, o.name, self.ctx.file.str(name))) continue;
                // The replaced default supplies an inferred TYPE only. Its
                // former value dependencies cannot change this card binding
                // and must not freeze unrelated host fields as shape inputs.
                const declared = if (p.ty == .unspecified)
                    constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1 })
                else
                    null;
                return constfold.parameterCardValue(p.ty, declared, o.value);
            };
            const declared = constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1, .reads = env.reads }) orelse return null;
            return constfold.parameterValue(p.ty, declared);
        };
        return null;
    }
    /// Leaves operand signedness unknown.
    pub fn signed(_: ParamEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    /// Leaves a parameter's width unknown.
    pub fn width(_: ParamEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};
