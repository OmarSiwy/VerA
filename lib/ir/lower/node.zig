//! §1.3.1 nodes: nets, ports, ground and the solver-unknown order.
//!
//! In: net and port declarations. Out: `node_order` (the U-enum index codegen depends on),
//! implicit nets, and the port/branch tables.
//!
//! LRM clauses this file's code cites: §1, §1.3.1.1, §2.7, §2.8.1, §3.6.3, §3.6.3.2, §3.6.5, §3.12, §5.4.1, §5.5.2, §5.9.3, §6.5.2.2.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_node.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Preprocessor = @import("frontend").Preprocessor;
const assert = Lower.assert;
const Oom = Lower.Oom;
const ground = Lower.ground;
const NodeKind = Lower.NodeKind;
const VecRange = Lower.VecRange;
const tokStart = Lower.tokStart;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;

// ---- §1.3.1 nodes ----------------------------------------------------------

/// §1.3.4 — is `dname` a SIGNAL-FLOW discipline? Exactly one of the two natures
/// is bound, so the net carries one quantity and no conservation law relates it
/// to anything (§3.6.2.1 makes the both-natures case conservative instead).
///
/// The exclusive-or matters. codegen.zig flowOnlySignalFlowNet asks the
/// narrower `flow and no potential`, which is right for the question IT asks —
/// "is this node's one unknown a flow?" — but a natureless `domain continuous`
/// discipline (§3.11.1) and a
/// `domain discrete` one bind NEITHER nature, and neither is a signal-flow
/// discipline. §1.3.4.1/§1.3.4.2 say "potential signal flow" and "flow
/// signal-flow" disciplines, which is one nature, present.
pub fn isSignalFlow(self: *const Lower, dname: []const u8) bool {
    if (dname.len == 0) return false;
    const d = self.disciplines.get(dname) orelse return false;
    return d.has_potential != d.has_flow;
}

/// §10.2 + §7.4. "The default discipline is applied by discipline resolution
/// (see 7.4 and Annex F) to all discrete signals without a discipline
/// declaration that appear in the text stream following the use of the
/// `default_discipline directive." So: only a net that still has none, and
/// only a directive that precedes the net's own declaration.
///
/// The QUALIFIER selects which nets a default claims, which is why more than
/// one can be in force "provided each differs in qualifier", and why §10.2's
/// precedence sentence ("the more specific directives have higher precedence")
/// makes a qualified default beat an unqualified one. Every net that reaches
/// this point is a plain net, hence `wire` by IEEE Std 1364 §3.5's default
/// nettype — VerA has no `real`/`wreal` net declarations at all (E0205) and a
/// `reg` is one §3.2 integer VARIABLE rather than a net (§7.3.1 Table 7-1's own
/// mapping), so `wire` and the unqualified form are the only two keys that can
/// match.
/// ponytail: widen the key to the net's declared data type when those land.
/// The same, for a declaration that may be a §3.6.3 vector: the default is
/// written onto each scalarised element, since the base name is not a node.
pub fn applyDefaultToAll(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    const r = self.vectors.get(name) orelse
        return applyDefaultDiscipline(self, try netKey(self, name, main_tok), main_tok);
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    for (0..r.size()) |k|
        try applyDefaultDiscipline(self, try lower_param.elemKey(self, &key_buf, name, &.{r.at(@intCast(k))}), main_tok);
}

pub fn applyDefaultDiscipline(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (self.directives.disciplines.len == 0) return;
    const idx = self.node_voltages.get(name) orelse return;
    if (idx == ground) return;
    if (self.node_disciplines.items[idx].len != 0) return;
    if (main_tok >= self.tok_starts.len) return;
    const at = self.tok_starts[main_tok];

    // Backwards from the declaration: the most recent directive wins, and a
    // wire-qualified one wins over an unqualified one however old it is.
    var fallback: ?[]const u8 = null;
    var i = self.directives.disciplines.len;
    const chosen = while (i > 0) {
        i -= 1;
        const e = self.directives.disciplines[i];
        if (e.at > at) continue;
        // §10.2: the bare form and `resetall withdraw the default outright,
        // so nothing older than one of those is still in force.
        if (e.discipline.len == 0) break fallback;
        if (e.qualifier == .wire) break e.discipline;
        if (e.qualifier == null and fallback == null) fallback = e.discipline;
    } else fallback;

    const dname = chosen orelse return;
    // A default naming a discipline that was never declared supplies no
    // nature, so leaving the net bare is the honest outcome: E0337 then says
    // the net has no discipline, which is exactly what happened.
    if (!self.disciplines.contains(dname)) return;
    self.node_disciplines.items[idx] = dname;
}

/// IEEE 1364 §19.2 `` `default_nettype none ``, on a name that is about to
/// become a §3.6.5 implicit net. A no-op under every other net type: the
/// directive picks the TYPE an implicit net has, and VerA's analog nets have no
/// type to pick — §3.6 gives a net a DISCIPLINE, which is §10.2's directive and
/// a different question. `none` is the member that says something this engine
/// can act on, because it says the implicit net may not exist at all.
///
/// ponytail: the other ten values are accepted and dropped. The ceiling is real
/// and it is the digital kernel's — `wand`/`wor`/`trireg`/`tri0` differ only in
/// how MULTIPLE DRIVERS resolve, and VerA has no driver-resolution model to
/// differ in. Upgrade path is the discrete net type on `Ast.NetDecl`, at which
/// point this function stops discarding the value and starts stamping it.
pub fn rejectImplicitNet(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (Preprocessor.NetTypeRegion.inForce(self.directives.nettypes, self.tokStart(main_tok), .default) != .none) return;
    var b = self.errWith(main_tok, .E0367);
    b.msg("`{s}` was never declared, and `default_nettype none is in force", .{name});
    b.note("§3.6.5 would make it an implicit net; IEEE 1364 §19.2's `none` is what withdraws that", .{});
    b.help("declare it — `electrical {s};` — or go back to `default_nettype wire", .{name});
    try b.emit();
}

/// IEEE 1364 §19.10 on the internal nets §6.2.2 gave the unconnected `input`
/// ports. Run after the declarations are interned and before the analog blocks
/// lower, which is the order the rule reads in: the port arrives already driven,
/// and the child's equations then see whatever the drive put there.
///
/// WHAT A PULL IS HERE. §19.10 pulls a digital net to a logic level through a
/// `pull`-strength driver. The analog kernel has neither logic levels nor
/// strengths, and it has exactly one way of saying "driven to a level": a
/// potential source between the node and the reference. So `pull0` holds the
/// port at 0 and `pull1` at 1, in the units of its discipline's potential
/// nature — and the half that DISCRIMINATES is not the number, it is the
/// source: an unconnected input under `nounconnected_drive is a floating
/// unknown that KCL gives zero current, and under either pull it is a driven
/// node that current flows into.
///
/// ponytail: 1.0 is the ceiling. §19.10's `pull1` is strength Pu1 on a
/// four-state net, not one volt, and a discipline whose potential is a
/// temperature or a pressure has no reason for its logic 1 to be 1. The upgrade
/// path is the discrete kernel's net resolution, where a pull is a driver among
/// drivers and this stops being a potential at all; until there is one, a
/// number that is right for `logic` and honest about being a number beats
/// recording the directive and doing nothing with it.
///
/// Skipped on a net whose discipline binds no potential (§3.6.2.2 discrete, or
/// none at all): there is nothing to hold it at, and inventing a source would
/// turn a directive into an E0501 about an access function the model never
/// wrote.
pub fn applyUnconnectedDrive(self: *Lower) Oom!void {
    if (self.directives.drives.len == 0) return;
    for (self.unconnected_inputs) |site| {
        const drive = Preprocessor.DriveRegion.inForce(self.directives.drives, self.tokStart(site.main_tok), .default);
        if (drive == .float) continue;
        const idx = self.node_voltages.get(site.name) orelse continue;
        if (idx == ground) continue;
        const info = self.disciplines.get(self.node_disciplines.items[idx]) orelse continue;
        if (!info.has_potential) continue;
        const target: lower_contrib.Target = .{ .access = .potential, .hi = idx, .lo = ground };
        const acc = self.accum.items[try lower_contrib.contribIndex(self, target, site.main_tok)];
        const old = try self.builder.readVariable(acc.resist, self.cur);
        const level: Mir.Value = if (drive == .pull1) .f_one else .f_zero;
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, level }));
        // §5.6.1.3: the source is retained on every path, the same as an
        // unconditional `<+` — there is no path on which an unconnected port
        // stops being unconnected.
        try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    }
}

/// Register (or find) a node. Undeclared names are implicit nets (§3.6.5), so
/// this never fails; registration order is source order ⇒ deterministic.
pub fn internNode(self: *Lower, name: []const u8, discipline: []const u8) Oom!u16 {
    const gop = try self.node_voltages.getOrPut(self.arena, name);
    if (gop.found_existing) {
        if (discipline.len != 0 and gop.value_ptr.* != ground)
            self.node_disciplines.items[gop.value_ptr.*] = discipline;
        return gop.value_ptr.*;
    }
    const idx = try appendNode(self, name, discipline, .net);
    gop.value_ptr.* = idx;
    return idx;
}

/// §3.6.3.2 fold one net_decl_assignment into a nodeset value for `node`.
///
/// "The initializer shall be a constant_expression" — so a fold that fails IS
/// the rule, and E0365 is it. `constEval` looks through parameters, which is
/// what the clause wants: §3.4 makes a parameter reference a constant
/// expression, and `electrical n = vstart;` is the form a model card tunes.
///
/// A string folds to 0.0 through `asReal()` and is not separately diagnosed: a
/// nodeset is a potential, `parameter string` cannot be one, and the value it
/// lands on is the same 0.0 the unknown starts at without any nodeset at all.
///
/// ponytail: the value is frozen at the fold, so a nodeset written over a
/// parameter keeps the parameter's DECLARED default even after a model card
/// overrides it — a stale initial guess, never a wrong answer, since §3.6.3.2
/// only feeds the solver's starting point. The upgrade path is the §6.3.4
/// `derive()` shape: keep the `Ast.ExprId`, render it with codegen's
/// `f64Const`, and export `nodeset(model)` instead of a comptime table.
pub fn recordNodeset(self: *Lower, node: u16, e: Ast.ExprId, tok: u32, name: []const u8) Oom!void {
    const c = lower_constfold.constEval(self, e) orelse {
        var b = self.errWith(tok, .E0365);
        b.msg("the initializer of `{s}` is not a constant expression", .{name});
        b.note("§3.6.3.2 gives it to the analog solver as a nodeset value for the potential of `{s}`, which is fixed before the solve starts", .{name});
        try b.emit();
        return;
    };
    try self.nodesets.append(self.arena, .{ .node = node, .value = c.asReal(), .tok = tok });
}

/// The one place a `node_order` slot is created: it fixes the slot's KIND and
/// its SPELLING together, which is the split this table exists to keep. Every
/// caller owns the IDENTITY question itself (`node_voltages` for a net,
/// `flow_unknowns` for a branch, `port_probes` for a port) — this function does
/// not dedupe and must not, since two distinct unknowns may ask for one name.
pub fn appendNode(self: *Lower, name: []const u8, discipline: []const u8, kind: NodeKind) Oom!u16 {
    const idx: u16 = @intCast(self.node_order.items.len);
    assert(idx != ground);
    const spelling = try uniqueSpelling(self, name);
    try self.spellings.put(self.arena, spelling, {});
    try self.node_order.append(self.arena, spelling);
    try self.node_kind.append(self.arena, kind);
    try self.node_disciplines.append(self.arena, discipline);
    try self.node_dir.append(self.arena, .unspecified);
    try self.probe_cache.append(self.arena, .undef);
    return idx;
}

/// `name`, or the first `name#k` nobody has taken. codegen prints one `U`
/// member per slot, so two slots cannot share a spelling — and once identity
/// stopped BEING the spelling, two slots genuinely can want one:
///
///   - §1.3.1.1's reference node prints `gnd` (`nodeName`) and §2.7 lets a plain
///     net be called `gnd` too, so `I(a)` and `I(a,gnd)` both print `flow(a,gnd)`
///     while naming two different branches;
///   - §2.8.1 strips the backslash, so a net `\flow(p,n)` is the identifier
///     `flow(p,n)`, which is what `flowUnknown` prints for the branch (p,n).
///
/// `#` is not a §2.7 identifier character and `naming.sanitize` escapes it, so a
/// suffixed member cannot collide with an unsuffixed one either — the same
/// convention, and the same reasoning, as `codegen.freshUName`, which uniquifies
/// the branch-current unknowns codegen appends after `node_order`. The loop
/// terminates in at most `node_order.len` steps (each `k` it rejects is held by
/// a distinct earlier slot), and that is bounded by |U| ≤ 256.
///
/// The suffix falls on the LATER slot, so it is a function of source order and
/// nothing else. A fixture that has to spell one of these writes the member as
/// `emitTopology` prints it — the same rule as every other unknown.
pub fn uniqueSpelling(self: *Lower, name: []const u8) Oom![]const u8 {
    if (!self.spellings.contains(name)) return name;
    // The candidates that LOSE are hashed and thrown away, so they are built on
    // the stack and only the winner reaches the arena — `elemKey`'s trick, with
    // the same spill for a name too wide for the buffer.
    var buf: [spelling_buf_len]u8 = undefined;
    var k: u32 = 1;
    while (true) : (k += 1) {
        const cand = std.fmt.bufPrint(&buf, "{s}#{d}", .{ name, k }) catch
            try std.fmt.allocPrint(self.arena, "{s}#{d}", .{ name, k });
        if (!self.spellings.contains(cand)) return self.arena.dupe(u8, cand);
    }
}

/// Widest spelling `uniqueSpelling` builds without spilling: `flow(<` plus two
/// §2.7 identifiers — capped at 1024 characters, the same source bound
/// `elem_key_len` and `naming.max_name_len` are sized from — plus the
/// punctuation and a `#` with a `u32` after it.
pub const spelling_buf_len = 2 * 1024 + 32;

/// Resolve a net reference — `n` or `n[i]` — to a node_order index.
///
/// The element case is a plain `internNode` of the scalarised name, so a
/// vector element is a node like any other from here on. What this function
/// owes on top is the two checks that only exist while the range is still
/// known: §5.5.2 says an access function takes "scalars or individual elements
/// of a vector", so a bare vector name is not a signal (E0351), and an index
/// has to name an element that was declared (E0351/E0352). Without them
/// `V(bus[9])` would quietly intern a §3.6.5 implicit net called `bus[9]` and
/// read 0.
pub fn nodeOf(self: *Lower, e: Ast.ExprId) Oom!u16 {
    if (e == .none) return ground;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            // §2.8.1 — see `netKey`. The reference to `\bus[0] ` is an `.ident`
            // and the reference to element 0 of `bus` is an `.index`, so the two
            // never share a path here; only the KEY had to be kept apart.
            const name = try netKey(self, self.file.str(ex.strOf(e)), ex.mainTok(e));
            if (self.vectors.get(name)) |r| {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` is a vector [{d}:{d}]; name one element of it", .{ name, r.msb, r.lsb });
                return ground;
            }
            // IEEE 1364 §19.2's `none`, on the other half of §3.6.5: `internNode`
            // below is the one call in this file that MAKES a net out of a name
            // nobody declared, so this is the one place the directive can act.
            // Checked before the intern and not inside it — `lowerModule` interns
            // every declared port and net through the same function, and those
            // are declarations, not implicit nets.
            if (!self.node_voltages.contains(name))
                try rejectImplicitNet(self, name, self.file.exprs.mainTok(e));
            return internNode(self, name, "");
        },
        // §6.7.1 a hierarchical terminal, `V(u.a)`. `flatName` is the whole
        // resolution: elaboration named the child's net `u.a`, so the path IS the
        // flat name and the lookup is the ordinary one.
        //
        // What it may NOT do is intern a new node the way the `.ident` arm does.
        // §3.6.5's implicit net is a rule about an UNDECLARED SIMPLE name in this
        // module; a path that resolves to nothing names no net anywhere in the
        // design, and silently creating one turns a wrong path into a floating
        // node and an E0337 about a name the author never declared.
        .hier_ident => {
            const name = try lower_expr.flatName(self, e);
            if (!self.node_voltages.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0901);
                b.msg("`{s}` names no net in the elaborated design", .{name});
                try b.emit();
                return ground;
            }
            return internNode(self, name, "");
        },
        .index => {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) {
                try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
                return ground;
            }
            const name = self.file.str(ex.strOf(base));
            const r = self.vectors.get(name) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` was not declared with a range", .{name});
                return ground;
            };
            // §5.5.2 "The index must be a constant expression, though it may
            // include genvar variables" — which `constEval` reads out of
            // `consts`, where `tryUnrollFor` binds the genvar of the enclosing
            // §5.9.3 `for` for the duration of each unrolled copy.
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
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
            return ground;
        },
    }
}

/// The scalarised name of one vector element. `p[0]` and not `p__0`: it is the
/// spelling the source uses, so a diagnostic, a `//!` operating-point binding
/// and the emitted `U` enum all name the same thing, and naming.zig's escape
/// makes it a legal Zig identifier without anybody choosing an encoding.
///
/// `internNode` for a vector element, `bus[3]`.
///
/// The spelling goes into a stack buffer for the LOOKUP and only reaches the
/// arena when the element is genuinely new. `elemKey`'s reasoning exactly, and
/// for the same reason: §5.5.2 lets `V(bus[3])` sit in an unrolled §5.9.3 loop
/// body, and formatting the name afresh on every reference would just
/// rediscover the slot the first one interned. `getKey` hands back the arena copy
/// already in the map, so `internNode` does its whole job unchanged.
/// The node-table key for a net named by the SOURCE identifier at `tok`.
///
/// §2.8.1: "Escaped identifiers shall start with the backslash character (\) and
/// end with white space ... Neither the leading backslash character nor the
/// terminating white space is considered to be part of the identifier." So
/// `electrical \bus[0] ;` declares a SCALAR net whose name is the five
/// characters `bus[0]` — byte-for-byte what `internNodeElem` prints for element
/// 0 of `electrical [0:1] bus`. That spelling is a GENERATED name (§3.13.3), not
/// a declaration in the module's namespace, so the two are different objects and
/// the shared key merged them: the escaped scalar was refused as a second
/// discipline declaration of the vector's element (E0902), and without that
/// refusal the two would have shared one solver unknown and one wrong voltage.
///
/// Discriminated at the TOKEN, which is the only place the information still
/// exists — the parser strips the `\` from the name (`Parser.tokenText`), and no
/// property of the resulting string can tell `bus[0]` from `bus[0]`. The `\` is
/// put back, which is unspellable by any generated name and is the §2.8.1
/// spelling a reader already expects in a diagnostic.
///
/// Only a name ENDING in `]` is touched: nothing else can collide with an
/// element spelling, and an escaped net that cannot collide keeps the key it has
/// always had. That matters for the Annex E path, which declares a SPICE card
/// named for a keyword as an escaped identifier (`spice_cards`).
///
/// ponytail: a fresh arena copy per reference, not per net. The name is rare
/// enough that the `elemKey` stack-buffer trick would cost more comment than it
/// saves; `internNode`'s `getOrPut` drops the copy on every hit after the first.
pub fn netKey(self: *Lower, name: []const u8, tok: u32) Oom![]const u8 {
    if (name.len == 0 or name[name.len - 1] != ']') return name;
    if (tok >= self.tok_starts.len) return name;
    const at = self.tok_starts[tok];
    if (at >= self.src.len or self.src[at] != '\\') return name;
    return std.fmt.allocPrint(self.arena, "\\{s}", .{name});
}

pub fn internNodeElem(self: *Lower, base: []const u8, i: i64) Oom!u16 {
    var buf: [lower_param.elem_key_len]u8 = undefined;
    const key = try lower_param.elemKey(self, &buf, base, &.{i});
    const name = self.node_voltages.getKey(key) orelse try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, i });
    return internNode(self, name, "");
}

/// Fold a declared `[msb:lsb]` (§3.6.3 Syntax 3-6). The bounds are constant
/// expressions — §6.5.2.2 prints `electrical [0:4-1] in;` as valid — so this
/// is lowering's job and not the parser's. `null` means it did not fold and
/// the diagnostic has been emitted.
pub fn foldDim(self: *Lower, d: Ast.Dim, tok: u32) Oom!?VecRange {
    const msb = lower_constfold.constEval(self, d.msb) orelse {
        try self.err(tok, .E0352, "the msb of the range is not a constant expression", .{});
        return null;
    };
    const lsb = lower_constfold.constEval(self, d.lsb) orelse {
        try self.err(tok, .E0352, "the lsb of the range is not a constant expression", .{});
        return null;
    };
    return .{ .msb = msb.asInt(), .lsb = lsb.asInt() };
}

/// §6.5.2.2 the range of a port, from whichever of its two declarations
/// carries one — and, when both do, only after the clause's own check: "If a
/// port is declared as a vector, the range specification between the two
/// declarations of a port shall be identical."
///
/// Identical means EVALUATE-identical, which is why the comparison is here and
/// on FOLDED bounds: the clause prints `input [0:3] in; electrical [0:4-1] in;`
/// as valid and `input [3:0] in; electrical [0:3] in;` as an error, and those
/// two differ only after folding. A range on ONE declaration is not this rule's
/// business — its sentence is guarded by "if a port is declared as a vector",
/// and `inout p; electrical [3:0] p;` declares it exactly once.
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
/// bare identifier at all — `branch (a[1], b)` is two scalars).
pub fn vecTerminal(self: *const Lower, e: Ast.ExprId) ?VecRange {
    if (e == .none) return null;
    if (self.file.exprs.tag(e) != .ident) return null;
    return self.vectors.get(self.file.str(self.file.exprs.strOf(e)));
}

/// §3.12 a vector branch. The LRM's own example:
///
///     electrical [3:5]a;
///     electrical [1:3]b;
///     branch (a,b) br1;  // Branch br1 is of size 3 and can be indexed 0 to 2
///
/// Three rules, all of them here. The terminals pair "in a parallel one-to-one
/// fashion", which is `VecRange.at(k)` against `at(k)` — declaration order on
/// both sides, so neither terminal's own numbering leaks into the pairing. A
/// scalar terminal fans in (Figure 3-2), so it repeats. And "if the range of
/// the vector branch is not specified then the indexing of the vector branch
/// shall start at 0" — hence `[0:size-1]` regardless of what either terminal
/// is indexed from.
///
/// The elements are registered in `branches` under their scalarised names, so
/// `V(br1[1])` resolves through the ordinary branch lookup; the base name goes
/// into `vectors` so that `V(br1)` and `V(br1[9])` get the vector diagnostics
/// rather than being read as a net.
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
    // A scalar terminal is resolved once, outside the loop: it is the SAME
    // node on every element (Figure 3-2), not a fresh implicit net per index.
    const h_scalar = if (hv == null) try nodeOf(self, b.hi) else ground;
    const l_scalar = if (lv == null) try nodeOf(self, b.lo) else ground;
    const h_name = if (hv != null) self.file.str(self.file.exprs.strOf(b.hi)) else "";
    const l_name = if (lv != null) self.file.str(self.file.exprs.strOf(b.lo)) else "";
    for (0..size) |k| {
        const hi = if (hv) |h| try internNode(self, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ h_name, h.at(@intCast(k)) }), "") else h_scalar;
        const lo = if (lv) |l| try internNode(self, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ l_name, l.at(@intCast(k)) }), "") else l_scalar;
        // §3.12 → §3.11 once, not `size` times: every element of a vector
        // branch pairs the same two DISCIPLINES, so the verdict is the same on
        // all of them and only the first has anything new to say.
        if (k == 0) try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo);
        try self.branches.put(self.arena, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, @as(i64, @intCast(k)) }), .{
            .hi = hi,
            .lo = lo,
            .id = newBranchId(self),
        });
    }
    try self.vectors.put(self.arena, name, .{ .msb = 0, .lsb = @as(i64, size) - 1 });
}

/// The name codegen prints for a node_order index (naming.zig unit targets).
pub fn nodeName(self: *const Lower, idx: u16) []const u8 {
    return if (idx == ground) "gnd" else self.node_order.items[idx];
}

/// §5.4.1 a fresh branch identity, one per DECLARED branch name (array elements
/// included). Ids are per-module and never reused; nothing outside lowering sees
/// them, so they need no stable spelling.
pub fn newBranchId(self: *Lower) u32 {
    self.last_branch_id += 1;
    return self.last_branch_id;
}

/// §4.4 potential probe of one node. Deduped so a node is one `block_param`
/// (codegen's `x[idx]`); ground is the literal 0 (§1.3.1.1).
pub fn probe(self: *Lower, idx: u16) Oom!Mir.Value {
    if (idx == ground) return .f_zero;
    if (self.probe_cache.items[idx] != .undef) return self.probe_cache.items[idx];
    const v = try self.mir.addBlockParam(self.arena, idx);
    self.probe_cache.items[idx] = v;
    return v;
}

/// §5.4.2 reading a flow (`I(a,b)`) makes the branch current a solver unknown
/// of its own. It gets a node_order slot so codegen indexes it like any other
/// `x[i]`.
///
/// Deduped on the PAIR, which is the identity §5.4.1 gives a branch, and not on
/// the printed name. Two branches can print alike — §1.3.1.1's reference node
/// and a net that §2.7 lets the author call `gnd` both spell `gnd` — and keying
/// on the name aliased `I(a)` onto `I(a,gnd)`, one unknown for two currents and
/// a Jacobian that is quietly wrong (`ch05_analog_behavior/
/// net_named_gnd_is_not_ground.va` is that circuit).
///
/// It also means the name is formatted on the MISS path only, where the old
/// spelling-keyed version paid an `allocPrint` per reference to discover the
/// entry already existed.
pub fn flowUnknown(self: *Lower, hi: u16, lo: u16) Oom!u16 {
    const gop = try self.flow_unknowns.getOrPut(self.arena, .{ .hi = hi, .lo = lo });
    if (gop.found_existing) return gop.value_ptr.*;
    const name = try std.fmt.allocPrint(self.arena, "flow({s},{s})", .{ nodeName(self, hi), nodeName(self, lo) });
    // The tolerance node is the HIGH one: a branch unknown carries no discipline
    // of its own (§3.6.1.2's abstol has to come from somewhere).
    const u = try appendNode(self, name, "", .{ .branch_flow = hi });
    gop.value_ptr.* = u;
    return u;
}

/// §5.4.3 the unknown carrying `I(<p>)`. Spelled `flow(<p>)` on purpose: it
/// reads as the port access function it came from, and it can never be mistaken
/// for a `flow(a,b)` branch unknown (that form always has a comma).
///
/// `port_probes` is the identity — one entry per port, and the scan is bounded
/// by the module's port count, which is why it needs no map. Reading it FIRST
/// is the fix: the old order interned the name and let the string dedupe,
/// so a net spelled `flow(<p>)` took over the port's current.
pub fn portFlowUnknown(self: *Lower, p: u16) Oom!u16 {
    for (self.port_probes.items) |pp| {
        if (pp.port == p) return pp.u;
    }
    const name = try std.fmt.allocPrint(self.arena, "flow(<{s}>)", .{nodeName(self, p)});
    const u = try appendNode(self, name, "", .{ .port_flow = p });
    try self.port_probes.append(self.arena, .{ .port = p, .u = u });
    return u;
}
