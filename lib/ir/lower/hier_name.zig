//! §9.16 `$simprobe` and §9.20 hierarchical reference strings.
//!
//! In: string-named instance/node references. Out: the flat unknown each one names,
//! resolved at compile time (the device has no runtime hierarchy).
//!
//! LRM clauses this file's code cites: §1.3.1.1, §3.6.3.2, §3.11.1, §5.4.3, §6.2.1, §6.7, §9.16, §9.20.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_hier_name.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_limit = @import("limit.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Elaborate = @import("../elaborate.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const err = Lower.err;
const errWith = Lower.errWith;
const poison = Lower.poison;
const emit = Lower.emit;
const call = Lower.call;
const astTy = Lower.astTy;

/// This file's private state on `Lower` (`Lower.hier_name_state`).
pub const State = struct {
    /// §9.20 the analog_net_reference of every alias call so far → the unknown that
    /// net was DECLARED with, before any alias moved it.
    ///
    /// Two rules need this and neither can be answered from `node_voltages` once an
    /// alias has been applied. The relation between two calls — "It shall be an
    /// error for the hierarchical_reference_string to reference a node that is used
    /// as an analog_net_reference in ANOTHER ... call" — is the key set. And the
    /// clause's ban on a PORT as the analog_net_reference is about the net's own
    /// declaration: once `n1` has been aliased onto a port, `node_voltages` says it
    /// IS one, and the SECOND call of the last-writer rule would be refused for
    /// something the source never wrote.
    alias_home: std.StringHashMapUnmanaged(u16) = .empty,
};

/// §9.20 one resolved `hierarchical_reference_string`: the unknown it names,
/// and whether the name was a node of the flat design itself (`direct`) rather
/// than a child port flattening bound to one.
pub const AliasHit = struct { idx: u16, direct: bool };

/// §9.20's validity list for `$analog_node_alias()` / `$analog_port_alias()`,
/// then the alias itself.
///
/// All six rules are checked HERE, in lowering, because every one of them is a
/// property of the call and none of them is a property of a value: the block the
/// call sits in, the guard above it, the SHAPE of the first argument (a node
/// declaration, not a probe and not a bit select), the constancy of the second,
/// and the relation between two calls. codegen sees a `call` with two operands
/// and cannot recover any of that.
///
/// One code for the list. The six sentences are one rule with one reason — an
/// alias makes its node "refer to the same circuit matrix position" as the
/// hierarchical reference, so it is a topology edit and topology is fixed before
/// a solve — and each message quotes the sentence it enforces.
///
/// The edit is HERE too, and for the same reason: a node's identity in this
/// compiler is `node_voltages`, the name → unknown map every probe goes
/// through, so "refer to the same circuit matrix position" is one `put`. Doing
/// it at the call site is also what gives §9.20's last-writer rule — "if a
/// particular node is involved in multiple calls ..., then the last evaluated
/// call shall take precedence" — for free: the calls are lowered in source
/// order and each overwrites the last.
pub fn checkAliasCall(self: *Lower, e: Ast.ExprId, name: []const u8, args: []const Ast.ExprId) Oom!lower_limit.AliasResult {
    const ex = &self.file.exprs;
    // 1. "It shall be an error for the $analog_node_alias() and
    // $analog_port_alias() system functions to be used outside the analog
    // initial block." The next sentence gives the reason: both "shall be
    // re-evaluated each sweep point of a dc sweep", i.e. between solves.
    if (!self.in_analog_initial) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` is used outside an analog initial block", .{name});
        return .refused;
    }
    // 2. "shall not be used inside conditional ( if , case , or ?: ) statements
    // unless the conditional expression controlling the statement consists of
    // terms which can not change during the course of a simulation."
    //
    // That carve-out is EXACTLY `static_cond_depth`: A.8.3's
    // `analysis_or_constant_expression` is the same "cannot change during the
    // simulation" set, so a parameter or `analysis()` guard is admitted and
    // `$abstime` is not. A constant-folded `if` never raises either counter and
    // so never reaches here at all.
    //
    // The `analog initial` block is itself ONE guarded body — `lowerModule`
    // wraps it in the `initial_step` flag rather than splitting the CFG — so the
    // depth inside an EMPTY initial block is already 1/0. That guard is not a
    // §9.20 conditional, it is the context the clause requires, so it is
    // discounted (saturating, since rule 1 above is what guarantees it is there).
    if ((self.cond_depth -| 1) != self.static_cond_depth) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` is used inside conditional statement whose condition can change during the simulation", .{name});
        return .refused;
    }
    // 3/4/5. The analog_net_reference. "The analog_net_reference shall be either
    // a scalar or vector continuous node declared in the module containing the
    // system function call."
    const ref = if (args.len > 0) args[0] else Ast.ExprId.none;
    if (ref == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` needs an analog_net_reference and a hierarchical_reference_string", .{name});
        return .refused;
    }
    // The analog_net_reference's own unknown, for the alias below.
    var local: u16 = ground;
    switch (ex.tag(ref)) {
        .ident => {
            const rname = self.file.str(ex.strOf(ref));
            // The net's own unknown: §9.20's last-writer rule means `rname` may
            // already BE an alias, and every rule below is about the
            // declaration, not about where the previous call pointed it.
            const idx = self.hier_name_state.alias_home.get(rname) orelse self.node_voltages.get(rname);
            if (idx == null or idx.? == ground or self.vars.contains(rname)) {
                try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
                return .refused;
            }
            // 4. "It shall be an error for the analog_net_reference to be a port
            // or to be involved in port connections." A port is already bound to
            // whatever the instantiating netlist connected it to, and the alias
            // would bind the same matrix position a second time.
            if (idx.? < self.out.num_ports) {
                try self.err(self.file.exprs.mainTok(e), .E0812, "§9.20 does not allow the analog_net_reference to be a port: `{s}`", .{rname});
                return .refused;
            }
            local = idx.?;
        },
        // 5. "If the analog_net_reference is a vector node, it shall reference
        // the full vector node, it shall be an error for it to be a bit select
        // or part select of a vector node." The asymmetry is deliberate: the
        // scalar ELEMENT is what the hierarchical_reference_string may name.
        .index, .range => {
            try self.err(self.file.exprs.mainTok(e), .E0812, "a vector analog_net_reference must be the whole vector, not a bit select or part select", .{});
            return .refused;
        },
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
            return .refused;
        },
    }
    // 6. "The hierarchical_reference_string shall be a CONSTANT string value
    // (string literal or string parameter) containing a hierarchical reference
    // to a continuous node." Two spellings and nothing else — a string VARIABLE
    // is read during a solve, which is what the analog-initial rule already
    // rules out for the call itself. `constEval` admits exactly those two.
    const target = blk: {
        if (args.len > 1) if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
            .str => |s| break :blk s,
            else => {},
        };
        try self.err(self.file.exprs.mainTok(e), .E0812, "the hierarchical_reference_string of `{s}` is not a constant string (a string literal or a string parameter)", .{name});
        return .refused;
    };
    // "It shall be an error for the hierarchical_reference_string to reference a
    // node that is used as an analog_net_reference in ANOTHER
    // $analog_node_alias or $analog_port_alias() system function call." The same
    // LEFT argument twice is legal — the clause spends a last-writer rule on it
    // — so only target-against-other-reference is compared.
    //
    // Only a dotted-free string can name one: §6.7 says "the first name in a
    // path name can also be the top of a hierarchy which starts at the level
    // where the path is being used", so a bare name resolves locally, while
    // `$root.top.a` names something this module does not declare.
    const ref_name = self.file.str(ex.strOf(args[0]));
    if (std.mem.indexOfScalar(u8, target, '.') == null and !std.mem.eql(u8, target, ref_name)) {
        if (self.hier_name_state.alias_home.contains(target)) {
            try self.err(self.file.exprs.mainTok(e), .E0812, "`\"{s}\"` is already the analog_net_reference of another $analog_node_alias/$analog_port_alias call", .{target});
            return .refused;
        }
    }
    // First call for this net records its DECLARED unknown; a later one must
    // not overwrite it with the alias the earlier call installed.
    if (!self.hier_name_state.alias_home.contains(ref_name)) try self.hier_name_state.alias_home.put(self.arena, ref_name, local);
    return bindAlias(self, name, ref_name, local, target);
}

/// §9.20's topology edit, and the validity list that decides whether it happens.
///
/// "The return value for both system functions shall be one (1) if the
/// hierarchical_reference_string points to a valid continuous node and zero (0)
/// otherwise. If the hierarchical_reference_string references a valid continuous
/// node, then the analog_net_reference will be aliased to that hierarchical node
/// and shall refer to the same circuit matrix position."
///
/// The clause's own three validity rules, in its order, plus resolution:
///
///   "shall refer to a scalar continuous node or a scalar element of a
///    continuous vector node" — a vector BASE name is not a node here at all
///    (lowering scalarises `[3:0] b` into `b[3]`…`b[0]`), so it resolves to
///    nothing and takes the zero answer without an arm of its own;
///   "the discipline of the analog_net_reference and the resolved hierarchical
///    node reference shall be compatible (see 3.11)" — `disciplineConflict`,
///    the same §3.11.1 rule list `checkNetCompat` applies to a branch;
///   "for the $analog_port_alias() system function, the resolved hierarchical
///    node reference shall be a port".
///
/// Everything that survives is one `node_voltages` write. The aliased net keeps
/// its own `nodes` row, which no probe can reach any more: an unknown with
/// no equation, which is what a net the clause has just merged away IS. That is
/// the same shape a declared-and-unused net already has here, and pruning it
/// would renumber `U` — an ABI the host reads.
///
/// ponytail: the resolution is COMPILE TIME, so §9.20's "shall be re-evaluated
/// each sweep point of a dc sweep" is satisfied vacuously — the answer cannot
/// change between sweep points, because the only inputs are the string and the
/// elaborated design. The one input that CAN move is a string PARAMETER the host
/// overrides on the model card: that is frozen at its declared default here,
/// exactly as §3.6.3.2's nodeset is. Making it move needs a device whose
/// topology is a function of its model card, which is not what `U` is; the
/// upgrade path is to refuse a parameter-valued string whose default and
/// override could resolve differently, once a host exists that can tell us.
pub fn bindAlias(self: *Lower, fname: []const u8, ref_name: []const u8, local: u16, target: []const u8) Oom!lower_limit.AliasResult {
    const hit = resolveAliasNode(self, target) orelse return .unresolved;
    // §1.3.1.1 ground is not an unknown, but it IS a valid continuous node and
    // the clause's own example aliases to it ("node n1 will be aliased to
    // top.gnd"). Probing an aliased-to-ground net then yields the literal 0,
    // which is what the reference node is.
    if (hit.idx != ground) {
        if (lower_discipline.nodeDisciplineConflict(
            self,
            self.out.nodes.items(.disc)[local],
            self.out.nodes.items(.disc)[hit.idx],
        ) != null) return .unresolved;
        if (self.out.disciplines.get(self.out.nodes.items(.disc)[hit.idx])) |info| {
            if (info.is_discrete) return .unresolved;
        }
    }
    if (std.mem.eql(u8, fname, "$analog_port_alias")) {
        // "the resolved hierarchical node reference shall be a port". A port of
        // the ELABORATED device, which is the only port whose flow §5.4.3 can
        // read: `I(<p>)` is a row pinning the module's KCL sum at `p`.
        //
        // ponytail: so a child instance's port — the clause's own
        // `$analog_port_alias(n2, "top.r1.p")`, whose promise is that `I(<n2>)`
        // "shall measure the flow through the port of the INSTANCE referred to"
        // — takes the zero answer instead. Flattening binds that port to the
        // parent net it was connected to (`hier_names`), and the flow through
        // one instance's terminal is no longer a quantity the flat design has:
        // every instance on that net shares it. Answering 1 and measuring the
        // NET's flow would be a different number wearing the right name, and
        // §9.20 gives the honest 0 a meaning ("the user is encouraged to check
        // the return value"). The upgrade path is a per-instance terminal flow
        // unknown, which is elaboration's to mint, not this function's.
        if (!hit.direct or hit.idx == ground or hit.idx >= self.out.num_ports) return .unresolved;
    }
    // The alias itself: from here the analog_net_reference names the resolved
    // node's unknown, so every later probe of it lands on that matrix position.
    try self.node_voltages.put(self.arena, ref_name, hit.idx);
    return .bound;
}

/// §6.7 resolve a `hierarchical_reference_string` against the ELABORATED design.
/// `direct` says the name was a node of the flat design itself rather than a
/// child port that flattening bound to one — see `bindAlias`'s port rule.
///
/// Flattening renames a child's net to `path.name` with `Elaborate.sep`, which
/// IS a period, so the string §9.20 hands us and the name the flat design
/// carries are the same bytes and this is a map lookup — the same identity
/// `flatName` rides for a `.hier_ident` written in source. What differs is only
/// that the path arrives as a string, so the two prefix rules are applied to
/// bytes instead of to interned parts:
///
///   §6.2.1 `$root.` — "used to unambiguously refer to a top-level instance or
///   to an instance path starting from the root of the instantiation tree";
///   §6.7 the first name of a path "can also be the top of a hierarchy", with
///   "the ambiguity ... resolved by giving priority to the local scope" — hence
///   the unstripped lookup FIRST, and the device's own module name stripped
///   only after it fails.
pub fn resolveAliasNode(self: *Lower, path: []const u8) ?AliasHit {
    if (lookupFlatNode(self, path)) |h| return h;
    var p = path;
    if (std.mem.startsWith(u8, p, "$root.")) p = p["$root.".len..];
    if (self.out.module) |m| {
        const mn = self.file.str(m.name);
        if (p.len > mn.len + 1 and p[mn.len] == Elaborate.sep and std.mem.startsWith(u8, p, mn))
            p = p[mn.len + 1 ..];
    }
    if (p.len == path.len) return null; // nothing stripped; already looked up
    return lookupFlatNode(self, p);
}

pub fn lookupFlatNode(self: *Lower, p: []const u8) ?AliasHit {
    if (self.node_voltages.get(p)) |i| return .{ .idx = i, .direct = true };
    // A child port bound to a parent net is the same signal as that net, and
    // `Design.names` holds exactly those aliases (`flatName`'s one exception).
    if (self.out.hier_names.get(p)) |flat| {
        if (self.node_voltages.get(flat)) |i| return .{ .idx = i, .direct = false };
    }
    return null;
}

/// §9.16 the dynamic simulation probe function, Syntax 9-11:
///
///     $simprobe ( inst_name , param_name [, expression] )
///
/// "$simprobe allows a module to probe the value of a parameter of another
/// module instance", and the clause's one sentence with a value in it is the
/// resolution rule: "If either the inst_name or param_name cannot be resolved,
/// and the optional expression is not supplied, then an error shall be
/// generated. If the optional expression is supplied, its value will be returned
/// in lieu of raising an error."
///
/// So the answer is decided by whether `inst_name.param_name` resolves, and in a
/// flattened design that is a NAME LOOKUP: the flat name of a child's parameter
/// IS its hierarchical path (`Elaborate.sep`), the same identity §6.7 rides on.
/// Nothing is dynamic about it, which is the point — the device has no runtime
/// hierarchy to walk.
///
/// ponytail: the ceiling is a COMPUTED name. §9.16's arguments are strings, and a
/// string that is not a literal here cannot be resolved at compile time; it takes
/// the fallback, which is precisely what §9.16 says an unresolvable probe does,
/// and with no fallback it is the error the clause asks for. A host with a real
/// instance table would resolve more names than this does — that is the piece
/// Ruling E deliberately gave up, and it is recorded here rather than hidden.
/// §9.16 "the parent of the current instance": the caller's own instance path
/// with its last segment dropped, separator included, "" at the top. Joined to
/// an `inst_name` it gives the flat name of a SIBLING.
pub fn callerParentPath(self: *const Lower) []const u8 {
    if (self.cur_unit >= self.out.unit_paths.len) return "";
    const p = self.out.unit_paths[self.cur_unit].path;
    if (p.len == 0) return p;
    // `path` ends with the separator, so the caller's own segment is the text
    // between the previous separator and the last one.
    const cut = std.mem.lastIndexOfScalar(u8, p[0 .. p.len - 1], Elaborate.sep) orelse return "";
    return p[0 .. cut + 1];
}

pub fn lowerSimprobe(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0809);
        b.msg("`$simprobe` takes an instance name and a parameter name", .{});
        try b.emit();
        return poison;
    }
    const inst = lower_sysfunc.constStrArg(self, args[0]);
    const param = lower_sysfunc.constStrArg(self, args[1]);
    if (inst != null and param != null) {
        // §9.16: "the simulator will look for an instance called inst_name IN
        // THE PARENT OF THE CURRENT INSTANCE i.e. a sibling of the instance
        // containing the $simprobe() expression." The name is therefore
        // RELATIVE, and the flat key is the caller's parent path joined to it —
        // not the bare `inst_name`, which only worked for a caller that
        // happened to sit at the root, and which also resolved a path FROM the
        // root, the one reading the sibling rule excludes.
        const path = try std.mem.concat(self.arena, u8, &.{
            callerParentPath(self), inst.?, &[_]u8{Elaborate.sep}, param.?,
        });
        if (self.param_index.get(path)) |pi|
            return .{ .v = self.param_values.items[pi], .ty = astTy(self.out.params.items[pi].ty) };
        // §9.16's own first sentence: "$simprobe() queries the simulator for AN
        // OUTPUT VARIABLE named param_name in a sibling instance", and the
        // clause's example probes `id` of a mosfet — an operating-point
        // quantity, not a parameter. "The intended use of this function is to
        // allow dynamic monitoring of instance quantities", which a probe that
        // can only read the netlist's own numbers does not do. A flattened
        // child's variable is an ordinary variable under its path name, so the
        // read is the ordinary one.
        //
        // The sibling's block was lowered before this one (elaboration appends
        // instances in tree order), so the value read here is the one that
        // instance computed for this evaluation.
        if (self.vars.get(path)) |slot|
            return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    }
    // Unresolved. §9.16's own two outcomes, in the clause's order.
    if (args.len >= 3 and args[2] != .none) return lower_expr.lowerExpr(self, args[2]);
    var b = self.errWith(self.file.exprs.mainTok(e), .E0817);
    b.msg("`$simprobe(\"{s}\", \"{s}\")` names no parameter of the elaborated design", .{
        inst orelse "<expression>", param orelse "<expression>",
    });
    b.note("§9.16: with no third argument, an unresolvable probe \"shall generate an error\"", .{});
    b.help("supply the fallback expression §9.16 defines for this case: `$simprobe(inst, param, <value>)`", .{});
    try b.emit();
    return poison;
}
