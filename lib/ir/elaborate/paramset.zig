//! §6.4 paramsets: an instance of a paramset name and its overrides → the
//! selected paramset (§6.4.2), the module at the end of its chain, and the
//! parameter values the paramset statements assign. LRM §3.4.2, §3.4.5,
//! §3.4.7, §6.3, §6.4, §6.4.1, §6.4.2, §6.4.3, §9.18, §9.19.

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_clone = @import("clone.zig");
const elab_names = @import("names.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Error = elaborate.Error;
const sep = elaborate.sep;
const Unit = Flatten.Unit;
const connectionFor = Flatten.connectionFor;

// ---- §6.4 paramsets ---------------------------------------------------

/// Returns the paramset of an overload set this instance uses (§6.4.2), or
/// null after reporting E0904 (no paramset of that name), E0911 (none
/// admits the instance) or E0914 (still ambiguous after tie-breaking).
///
/// "Paramset identifiers need not be unique: multiple paramsets can be
/// declared using the same paramset_identifier ... During elaboration, the
/// simulator shall choose an appropriate paramset from the set that shares a
/// given name for every instance that references that name."
///
/// Two phases, from the clause. The selection rules ("the following rules
/// shall be enforced") cut the overload set down to the applicable paramsets
/// (`paramsetAdmits`). Then: "The rules above may not
/// be sufficient for the simulator to pick a unique paramset, in which case
/// the following rules shall be applied in order until a unique paramset
/// has been selected:"
///
///   1. "The paramset with the fewest number of un-overridden parameters
///      shall be selected." (§6.4.2's m3 example: the default paramset, l and
///      w both overridden, beats the long-channel one, ad and as defaulted.)
///   2. "The paramset with the greatest number of local parameters with
///      specified ranges shall be selected."
///   3. "The paramset with the fewest ports not connected in the instance
///      line shall be selected", over the target module's port list, since
///      same-named paramsets "may refer to different modules".
pub fn selectParamset(self: *Flatten, inst: *const Ast.Instance) Error!?*const Ast.ParamsetDecl {
    var candidates: usize = 0;
    var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    for (self.ctx.file.paramsets) |*ps| {
        if (ps.name != inst.module) continue;
        candidates += 1;
        if (paramsetAdmits(self, inst, ps)) try live.append(self.ctx.arena, ps);
    }
    if (live.items.len == 0) {
        if (candidates == 0) {
            try self.err(inst.main_tok, .E0904, "`{s}`", .{self.ctx.file.str(inst.module)});
        } else {
            try self.err(inst.main_tok, .E0911, "`{s}`: no paramset named `{s}` admits these parameter values", .{
                self.ctx.file.str(inst.name), self.ctx.file.str(inst.module),
            });
        }
        return null;
    }
    // "applied in order until a unique paramset has been selected".
    if (live.items.len > 1) try tieBreak(self, inst, &live, .un_overridden);
    if (live.items.len > 1) try tieBreak(self, inst, &live, .ranged_locals);
    if (live.items.len > 1) try tieBreak(self, inst, &live, .unconnected_ports);
    if (live.items.len > 1) {
        try self.err(inst.main_tok, .E0914, "`{s}`: {d} paramsets named `{s}` are still applicable after §6.4.2's tie-breaking rules", .{
            self.ctx.file.str(inst.name), live.items.len, self.ctx.file.str(inst.module),
        });
        return null;
    }
    return live.items[0];
}

/// The three §6.4.2 tie-breaking rules, in the clause's order.
pub const TieRule = enum { un_overridden, ranged_locals, unconnected_ports };

/// Applies one tie-breaking rule: scores every surviving candidate and keeps
/// the minimum in `live` (a "greatest" rule negates its count).
pub fn tieBreak(
    self: *Flatten,
    inst: *const Ast.Instance,
    live: *std.ArrayList(*const Ast.ParamsetDecl),
    rule: TieRule,
) Error!void {
    const scores = try self.ctx.arena.alloc(i64, live.items.len);
    for (live.items, scores) |ps, *s| s.* = switch (rule) {
        // "the fewest number of un-overridden parameters": the paramset's
        // overridable parameters the instance left at their defaults. A
        // localparam is not overridable (§3.4.5), and §6.4.2's neighbouring
        // rules count "parameters" and "local parameters" separately.
        .un_overridden => blk: {
            const overridable: i64 = @intCast(overridableCount(ps.params));
            const named = inst.params.len != 0 and inst.params[0].name != .none;
            if (!named) {
                // §6.3 ordered values land on the first inst.params.len
                // overridable parameters, so the remainder is the count.
                break :blk @max(0, overridable - @as(i64, @intCast(inst.params.len)));
            }
            var n: i64 = 0;
            for (ps.params) |p| {
                if (p.is_local) continue;
                n += @intFromBool(!overridesParam(inst, ps, p.name));
            }
            break :blk n;
        },
        // "the greatest number of local parameters with specified ranges",
        // negated.
        .ranged_locals => blk: {
            var n: i64 = 0;
            for (ps.params) |p| n += @intFromBool(p.is_local and p.ranges.len != 0);
            break :blk -n;
        },
        // "the fewest ports not connected in the instance line". A target
        // module the file never declares scores worst; if such a candidate
        // is selected anyway, E0904 names it at the use site.
        .unconnected_ports => blk: {
            const child = elab_names.findModule(self, ps.target) orelse break :blk std.math.maxInt(i64);
            var n: i64 = 0;
            for (child.ports, 0..) |p, i| {
                const conn = connectionFor(inst, p, i);
                n += @intFromBool(conn == null or conn.?.expr == .none);
            }
            break :blk n;
        },
    };
    var best = scores[0];
    for (scores[1..]) |s| best = @min(best, s);
    var w: usize = 0;
    for (live.items, scores) |ps, s| if (s == best) {
        live.items[w] = ps;
        w += 1;
    };
    live.shrinkRetainingCapacity(w);
}

/// Returns how many of `params` an override can land on: the non-local ones
/// (§3.4.5).
pub fn overridableCount(params: []const Ast.ParamDecl) usize {
    var n: usize = 0;
    for (params) |p| n += @intFromBool(!p.is_local);
    return n;
}

/// Returns whether a named instance override with a value lands on paramset
/// parameter `name`, directly or through a §3.4.7 alias.
pub fn overridesParam(inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl, name: Ast.StrId) bool {
    for (inst.params) |o| {
        if (o.value == .none) continue;
        if (o.name == name) return true;
        for (ps.aliasparams) |al| if (al.alias == o.name and al.target == name) return true;
    }
    return false;
}

/// Returns whether `ps` passes §6.4.2's selection rules for `inst` ("When
/// choosing an appropriate paramset, the following rules shall be
/// enforced"), as far as each is decidable here. Reports nothing.
///
///   1. "All parameters overridden on the instance shall be parameters of
///      the paramset", and §3.4.5 keeps a localparam out of an override's
///      reach in either spelling.
///   2. "The parameters of the paramset, with overrides and defaults, shall
///      be all within the allowed ranges specified in the paramset
///      parameter declaration": this is what makes a binned set select on
///      geometry.
///   3. "The local parameters of the paramset, computed from parameters,
///      shall be within the allowed ranges specified in the paramset":
///      judged as far as `constReal` folds (see `inRanges`).
///   4. "The underlying module shall have a port declared for each port
///      connected in the instance line." An undeclared target module cannot
///      fail it; that is E0904 at the use site.
pub fn paramsetAdmits(self: *Flatten, inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl) bool {
    const named = inst.params.len != 0 and inst.params[0].name != .none;
    if (!named and inst.params.len > overridableCount(ps.params)) return false;
    var ord: usize = 0;
    for (ps.params) |p| {
        // §6.4.2 "with overrides and defaults": the value this paramset would
        // give the parameter, whichever supplied it. An `is_local` entry
        // takes no override in either spelling (§3.4.5), so its default is
        // the value judged (criterion 3).
        var value = p.default;
        if (p.is_local) {
            // keep the default
        } else if (named) {
            for (inst.params) |o| {
                if (o.name == p.name and o.value != .none) value = o.value;
            }
        } else {
            if (ord < inst.params.len) value = inst.params[ord].value;
            ord += 1;
        }
        if (!inRanges(self, value, p.ranges)) return false;
    }
    if (named) for (inst.params) |o| {
        // §9.18's system parameters are not the paramset's to declare.
        if (self.ctx.file.strings.eql(o.name, "$mfactor")) continue;
        const found = for (ps.params) |p| {
            if (!p.is_local and p.name == o.name) break true;
        } else for (ps.aliasparams) |al| {
            if (al.alias == o.name) break true;
        } else false;
        if (!found) return false;
    };
    // Criterion 4, both connection spellings. A mixed or malformed list is
    // E0906 after selection (`checkConnectionShape`).
    if (elab_names.findModule(self, ps.target)) |child| {
        const conns_named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (conns_named) {
            for (inst.ports) |c| {
                if (c.name == .none) continue;
                const found = for (child.ports) |p| {
                    if (p.name == c.name) break true;
                } else false;
                if (!found) return false;
            }
        } else if (inst.ports.len > child.ports.len) return false;
    }
    return true;
}

/// §3.4.2 does this value satisfy the declared `from`/`exclude` ranges?
///
/// ponytail: a value or a bound this cannot fold counts as admissible, so a
/// missing folder never becomes a selection error; `Lower` still judges the
/// value it ends up with (E0361).
fn inRanges(self: *Flatten, value: Ast.ExprId, ranges: []const Ast.ValueRange) bool {
    if (ranges.len == 0) return true;
    // §3.4.2: "Valid values of string parameters are indicated differently.
    // The `from` keyword may be used with a list of valid string values, or
    // the `exclude` keyword may be used with a list of invalid string
    // values." A.2.5's `value_range_type '{ string {, string} }`, parsed
    // into `ValueRange.strings`. Without this arm a binned set keyed on a
    // string (§3.4.6's `ebersmoll` mapping) admits every bin.
    if (value != .none and self.ctx.file.exprs.tag(value) == .str_literal)
        return strInRanges(self, self.ctx.file.str(self.ctx.file.exprs.strOf(value)), ranges);
    const v = constReal(self, value) orelse return true;
    var has_from = false;
    var in_from = false;
    for (ranges) |r| {
        if (r.strings != null) continue;
        const lo = constReal(self, r.lo) orelse return true;
        const hi = if (r.hi == .none) lo else constReal(self, r.hi) orelse return true;
        const above = if (r.lo_inclusive) v >= lo else v > lo;
        const below = if (r.hi_inclusive) v <= hi else v < hi;
        switch (r.kind) {
            .from => {
                has_from = true;
                if (above and below) in_from = true;
            },
            .exclude => if (above and below) return false,
        }
    }
    return !has_from or in_from;
}

/// The string half of `inRanges`: membership in a `'{ ... }` set, union over
/// the `from` clauses, any `exclude` hit fatal, as lowering's
/// `checkParamRange` judges it. Returns a verdict instead of a diagnostic,
/// because here a non-member only means "this bin is not the one".
fn strInRanges(self: *Flatten, s: []const u8, ranges: []const Ast.ValueRange) bool {
    var has_from = false;
    var in_from = false;
    for (ranges) |r| {
        const off = r.strings orelse continue;
        const contains = for (self.ctx.file.exprs.list(off)) |id| {
            if (std.mem.eql(u8, s, self.ctx.file.str(@enumFromInt(id)))) break true;
        } else false;
        switch (r.kind) {
            .from => {
                has_from = true;
                in_from = in_from or contains;
            },
            .exclude => if (contains) return false,
        }
    }
    return !has_from or in_from;
}

/// Folds `e` to a real, or null: §2.6 literals, the A.2.5 infinities, and
/// every operator over them, through the shared constant kernel, so `1/2` is
/// §4.2.4's integer division as in lowering. Parameter reads do not fold;
/// §6.4.2's printed ranges are all literals.
pub fn constReal(self: *Flatten, e: Ast.ExprId) ?f64 {
    const c = constfold.fold(self.ctx.file, e, constfold.literal_env) orelse return null;
    return if (c == .str) null else c.asReal();
}

/// Reports E0890 and returns true when `e` folds to a `$mfactor` that is not
/// positive (§9.18 Table 9-29). Only a factor that folds over literals is
/// judged (`constReal`).
pub fn checkMfactor(self: *Flatten, tok: u32, e: Ast.ExprId) Error!bool {
    const v = constReal(self, e) orelse return false;
    if (v > 0) return false;
    try self.err(tok, .E0890, "`$mfactor` is {d}, and Table 9-29 allows only $mfactor > 0", .{v});
    return true;
}

/// Computes the module parameter values a paramset instance gives `child`
/// into `over`, and sets `unit`'s §9.18 `$mfactor` and §9.19 `$param_given`
/// (§6.4). Two levels: the instance overrides the paramset's own parameters,
/// then the paramset's statements compute the module's from those, so
/// `.k = 2.0 * gain;` with `#(.gain(3.0))` gives `k` = 6.0.
///
/// The paramset's own parameters become localparams under
/// `path ++ paramset_name ++ sep`, so `u.gain` stays the module's parameter
/// and `u.ch6_ps.gain` is the paramset's.
pub fn paramsetOverrides(
    self: *Flatten,
    inst: *const Ast.Instance,
    ps: *const Ast.ParamsetDecl,
    child: *const Ast.ModuleDecl,
    parent: *const Unit,
    over: *std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
    unit: *Unit,
    path: []const u8,
) Error!void {
    const ps_path = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}{c}", .{ path, self.ctx.file.str(ps.name), sep });

    // §6.4's chain, near to far. `chainEnd` already walked it to find
    // `child`, so this cannot fail here.
    var chain: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    _ = try elab_names.paramsetChain(self, ps, &chain);

    // ---- level 1: the paramset's own parameters, overridden by the instance
    var ps_unit: Unit = .{ .mfactor = parent.mfactor };
    var ps_over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
    // A synthesized instance of the paramset-as-unit: same overrides, no
    // ports, so `collectOverrides` handles §6.3's ordered/named arms,
    // §3.4.7's aliases and §9.18's `.$mfactor` for it.
    const as_module: Ast.ModuleDecl = .{
        .name = ps.name,
        .ports = &.{},
        .params = ps.params,
        .aliasparams = ps.aliasparams,
        .main_tok = ps.main_tok,
    };
    try self.collectOverrides(inst, &as_module, parent, &ps_over, &ps_unit, ps_path);
    for (ps.params) |p| try elab_names.bind(self, &ps_unit, ps_path, p.name);
    for (ps.aliasparams) |al| try elab_names.bind(self, &ps_unit, ps_path, al.alias);

    const saved = self.unit;
    self.unit = ps_unit;
    // Everything cloned from here to the restore is paramset-body text;
    // the instance's override values (`ps_over`) were cloned above, in the
    // parent's scope.
    self.in_paramset = true;
    try elab_clone.cloneParams(self, ps.params, ps.aliasparams, &ps_over);

    // ---- level 2: the module's parameters, from the paramsets' statements
    //
    // §6.4's chain, applied far link first so a nearer link's assignment to
    // the same module parameter wins. §6.4 gives no precedence rule;
    // nearest-wins treats the near link as the more specific one, as §6.3
    // ranks an instance override over a default.
    //
    // ponytail: a farther link's own parameters are not brought into scope;
    // its statements are evaluated in the near link's. Only the near link is
    // named by an instance, so only its parameters can take a §6.3 override,
    // and no fixture writes a far link that reads one. The upgrade path is a
    // per-link `Unit` + `cloneParams` under `path ++ link.name ++ sep`,
    // built in the same loop.
    var mfactor = ps_unit.mfactor;
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        for (chain.items[i].overrides) |o| switch (o.kind) {
            .module_param => {
                const decl = for (child.params) |*p| {
                    if (p.name == o.name) break p;
                } else {
                    try self.err(o.main_tok, .E0907, "`{s}` is not a parameter of `{s}`", .{
                        self.ctx.file.str(o.name), self.ctx.file.str(child.name),
                    });
                    continue;
                };
                if (decl.is_local) {
                    try self.err(o.main_tok, .E0907, "`{s}` is a localparam of `{s}`", .{
                        self.ctx.file.str(o.name), self.ctx.file.str(child.name),
                    });
                    continue;
                }
                // §6.4.1 "these variables shall not be used to assign values
                // to the module's parameters". Named here, where the paramset
                // is still in hand: once cloned, `t` is only an unknown name.
                if (readsVar(self.ctx.file, chain.items[i], o.value)) |v| {
                    try self.err(self.ctx.file.exprs.mainTok(v), .E0237, "`.{s} = ...` reads the paramset variable `{s}`, and paramset variables shall not assign the module's parameters", .{
                        self.ctx.file.str(o.name), self.ctx.file.str(self.ctx.file.exprs.strOf(v)),
                    });
                    continue;
                }
                try over.put(self.ctx.arena, o.name, try elab_clone.cloneExpr(self, o.value));
            },
            // §9.18 `.$mfactor = expr;` in a paramset is the same override the
            // instance's `.$mfactor(expr)` is, so it multiplies the same way.
            .system_param => {
                if (!self.ctx.file.strings.eql(o.name, "$mfactor")) {
                    try self.err(o.main_tok, .E0907, "`{s}` is not a system parameter this paramset can set", .{
                        self.ctx.file.str(o.name),
                    });
                    continue;
                }
                if (try checkMfactor(self, o.main_tok, o.value)) continue;
                const v = try elab_clone.cloneExpr(self, o.value);
                mfactor = if (mfactor == .none) v else try self.ctx.file.exprs.add(self.ctx.arena, .{
                    .tag = .binary,
                    .main_tok = o.main_tok,
                    .lhs = mfactor,
                    .rhs = v,
                    .extra = @intFromEnum(Ast.BinaryOp.mul),
                });
            },
            .output_var => {}, // §6.4.3, dropped in the parser
        };
    }
    self.in_paramset = false;
    self.unit = saved;

    unit.mfactor = mfactor;
    // §9.19 as for a module instance: decided here, once, per parameter.
    for (child.params) |p| try unit.given.put(self.ctx.arena, p.name, over.contains(p.name));
    for (child.aliasparams) |al| if (over.contains(al.target))
        try unit.given.put(self.ctx.arena, al.alias, true);
}

/// §6.4.1 the first identifier in `e` that names one of `ps`'s variables.
fn readsVar(file: *const Ast.SourceFile, ps: *const Ast.ParamsetDecl, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const x = &file.exprs;
    if (x.tag(e) == .ident) for (ps.vars) |v| {
        if (v.name == x.strOf(e)) return e;
    };
    var buf: [3]Ast.ExprId = undefined;
    for (x.children(e, &buf)) |c| if (readsVar(file, ps, c)) |hit| return hit;
    return null;
}
