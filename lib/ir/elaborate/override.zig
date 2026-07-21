//! §6.3 parameter overrides: an instance's `#(...)` list and the §6.3.1
//! defparams collected on the way down → the child's override map (`over`),
//! its §9.18 hierarchical system-parameter values and its §9.19
//! `$param_given` answers. Owns `Flatten.defparams`. LRM §3.4.4, §3.4.5,
//! §3.4.7, §6.3, §6.3.1, §6.3.3, §9.18 Table 9-29, §9.19; IEEE 1364-2005
//! §12.2.2.2.

const std = @import("std");
const hier_param = @import("../hier_param.zig");
const elaborate = @import("../elaborate.zig");
const Flatten = elaborate.Flatten;
const Unit = Flatten.Unit;
const Error = elaborate.Error;
const elab_clone = @import("clone.zig");
const PathKey = @import("names.zig").PathKey;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;

/// One collected §6.3.1 override, in `Flatten.defparams`.
pub const Defparam = struct {
    /// Already cloned, in the DECLARING module's namespace (§6.3.1: "a constant
    /// expression involving ... parameters declared in the same module as the
    /// defparam statement").
    value: Ast.ExprId,
    tok: u32,
    /// §6.3.1 a path that named no parameter of the elaborated design is E0907,
    /// and this is how that is noticed: nothing ever claimed it.
    used: bool = false,
};

comptime {
    // One row per defparam statement in the instance tree; 12 B budget.
    std.debug.assert(@sizeOf(Defparam) == 12);
}

/// Records `module`'s §6.3.1 defparams, at its instance prefix `path`, before
/// any child is inlined: a defparam applies downward, and the parameters it
/// overrides are created as those instances are. Under a §6.4 paramset
/// instance a defparam overrides nothing; it lands in
/// `Flatten.paramset_defparams` for lowering to judge.
pub fn collectDefparams(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) Error!void {
    for (module.defparams) |dp| {
        if (self.unit.paramset_instance) |instance| {
            try self.paramset_defparams.append(self.ctx.arena, .{
                .main_tok = dp.main_tok,
                .instance = instance,
                .gate = self.unit.gate,
            });
            // An active site is illegal; an inactive site's hierarchy
            // does not exist. Neither may override a child parameter.
            continue;
        }
        const key = try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(dp.path) });
        try self.defparams.put(self.ctx.arena, key, .{
            .value = try elab_clone.cloneExpr(self, dp.value),
            .tok = dp.main_tok,
        });
    }
}

/// Reports E0907 for every defparam no parameter claimed. §6.3.1 a defparam
/// names "the parameter ... in any module instance throughout the design",
/// so one that matched nothing named nothing. Runs after the walk because
/// the instance a path names may be several levels below the module the
/// defparam is written in.
pub fn reportUnusedDefparams(self: *Flatten) Error!void {
    var it = self.defparams.iterator();
    while (it.next()) |dp| if (!dp.value_ptr.used) try self.err(
        dp.value_ptr.tok,
        .E0907,
        "`{s}` names no parameter of the elaborated design",
        .{dp.key_ptr.*},
    );
}

/// Returns how many of `params` an override can land on: the non-local ones
/// (§3.4.5).
pub fn overridableCount(params: []const Ast.ParamDecl) usize {
    var n: usize = 0;
    for (params) |p| n += @intFromBool(!p.is_local);
    return n;
}

/// One effective §6.3 override. A defparam value was cloned in its DECLARING
/// module; an inline value is still in the instantiating module's namespace.
pub const ParamBinding = struct {
    value: Ast.ExprId,
    /// The name the override was written with (an alias or the original), for
    /// §3.4.7's conflict check; `.none` for an ordered `#(...)` value.
    spelling: Ast.StrId,
    /// True for a defparam's value, already in the flat namespace; false for
    /// an inline value, still in the instantiating module's names.
    flat: bool,
};

comptime {
    // One row per paramset parameter per §6.4.2 candidate; 12 B budget.
    std.debug.assert(@sizeOf(ParamBinding) == 12);
}

/// The same binding feeds overload selection and final parameter assignment.
/// §6.3 lets a defparam replace an inline value under the same name. §3.4.7
/// forbids different original/alias spellings even across the two mechanisms.
/// Inspection never consumes an override: only the selected instance does.
pub fn parameterBinding(self: *Flatten, inst: *const Ast.Instance, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam, index: usize, path: []const u8, consume: bool) Error!?ParamBinding {
    const p = params[index];
    if (p.is_local) return null;
    var found: ?ParamBinding = null;
    const named = inst.params.len != 0 and inst.params[0].name != .none;
    if (named) {
        for (inst.params) |o| {
            if (o.value == .none) continue;
            var target = o.name;
            for (aliases) |al| if (al.alias == o.name) {
                target = al.target;
                break;
            };
            if (target == p.name) found = .{ .value = o.value, .spelling = o.name, .flat = false };
        }
    } else {
        var ordinal: usize = 0;
        for (params[0..index]) |before| if (!before.is_local) {
            ordinal += 1;
        };
        if (ordinal < inst.params.len and inst.params[ordinal].value != .none)
            found = .{ .value = inst.params[ordinal].value, .spelling = .none, .flat = false };
    }
    try parameterDefparam(self, path, p.name, p.name, consume, &found);
    for (aliases) |al| if (al.target == p.name)
        try parameterDefparam(self, path, p.name, al.alias, consume, &found);
    return found;
}

fn parameterDefparam(self: *Flatten, path: []const u8, original: Ast.StrId, spelling: Ast.StrId, consume: bool, found: *?ParamBinding) Error!void {
    const dp = self.defparams.getPtrAdapted(PathKey{ .path = path, .local = self.ctx.file.str(spelling) }, PathKey.Context{}) orelse return;
    if (consume) {
        dp.used = true;
        if (found.*) |before| if (before.spelling != .none and before.spelling != spelling)
            try self.err(dp.tok, .E0908, "`{s}` and its alias are both given a value", .{self.ctx.file.str(original)});
    }
    found.* = .{ .value = dp.value, .spelling = spelling, .flat = true };
}

/// Folds `e` to a real, or null: §2.6 literals, the A.2.5 infinities, and
/// every operator over them, through the shared constant kernel, so `1/2` is
/// §4.2.4's integer division as in lowering. This literal-only helper checks
/// §9.18 domains without freezing host inputs; selection uses ParamsetEnv.
pub fn constReal(self: *Flatten, e: Ast.ExprId) ?f64 {
    const c = constfold.fold(self.ctx.file, e, constfold.literal_env) orelse return null;
    return if (c == .str) null else c.asReal();
}

/// §9.18/Table 9-29 domains, checked when the specified expression folds
/// without the model card. Every override mechanism uses this same check.
/// Host-dependent values retain the existing `$mfactor` validation boundary.
pub fn checkSystemParam(self: *Flatten, kind: hier_param.Kind, tok: u32, e: Ast.ExprId) Error!bool {
    if (constfold.firstStateRead(self.ctx.file, e, self.vars.items)) |what| {
        try self.err(tok, .E0363, "`{s}` override reads `{s}`", .{ kind.name(), what });
        return true;
    }
    const v = constReal(self, e) orelse return false;
    if (kind.allows(v)) return false;
    try self.err(tok, .E0890, "`{s}` is {d}, and Table 9-29 allows only {s}", .{ kind.name(), v, kind.domain() });
    return true;
}

/// Returns whether `child` has an overridable parameter `target`; otherwise
/// reports E0907 naming it `shown` (an alias reads as written, §3.4.7).
pub fn checkOverridable(self: *Flatten, child: *const Ast.ModuleDecl, target: Ast.StrId, shown: Ast.StrId, tok: u32) Error!bool {
    const decl = for (child.params) |*p| {
        if (p.name == target) break p;
    } else {
        try self.err(tok, .E0907, "`{s}` is not a parameter of `{s}`", .{ self.ctx.file.str(shown), self.ctx.file.str(child.name) });
        return false;
    };
    // §3.4.5 a localparam is not overridable.
    if (decl.is_local) {
        try self.err(tok, .E0907, "`{s}` is a localparam of `{s}`", .{ self.ctx.file.str(shown), self.ctx.file.str(child.name) });
        return false;
    }
    return true;
}

/// §9.19 `$param_given` is a fact about the instantiation, one answer per
/// flattened parameter (an alias shares its target's), so the clone can
/// substitute a literal.
pub fn markGiven(self: *Flatten, child: *const Ast.ModuleDecl, over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId), unit: *Unit) Error!void {
    for (child.params) |p| try unit.given.put(self.ctx.arena, p.name, over.contains(p.name));
    for (child.aliasparams) |al| if (over.contains(al.target))
        try unit.given.put(self.ctx.arena, al.alias, true);
}

/// Binds an instance's `#(...)` to `child`'s parameters into `over` (§6.3),
/// applies matching defparams last (§6.3.1), and sets `unit`'s §9.18
/// hierarchical values and §9.19 `$param_given` answers. Reports E0907 and
/// E0908 on bad overrides.
pub fn collectOverrides(
    self: *Flatten,
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    parent: *const Unit,
    over: *std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
    unit: *Unit,
    path: []const u8,
) Error!void {
    var specified: hier_param.Values = .initFill(.none);
    var spellings: std.EnumArray(hier_param.Kind, Ast.StrId) = .initFill(.none);

    const named = inst.params.len != 0 and inst.params[0].name != .none;
    // §3.4.5: local parameters "cannot directly be modified with the
    // defparam statement or by the ordered or named parameter value
    // assignment", so §6.3's declaration order counts overridable
    // parameters only and an ordered value skips every `is_local` entry.
    // The named arm refuses a localparam by name below.
    var ord: usize = 0;
    for (inst.params) |o| {
        // The value is the parent's expression, cloned under the parent's map.
        const saved = self.unit;
        self.unit = parent.*;
        const value = elab_clone.cloneExpr(self, o.value) catch |e| {
            self.unit = saved;
            return e;
        };
        self.unit = saved;

        if (!named) {
            // §6.3 "in the order of their declaration".
            while (ord < child.params.len and child.params[ord].is_local) ord += 1;
            if (ord >= child.params.len) {
                const n = overridableCount(child.params);
                try self.err(o.main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this instance overrides {d}", .{
                    self.ctx.file.str(child.name), n,
                    if (n == 1) "" else "s",       inst.params.len,
                });
                continue;
            }
            try over.put(self.ctx.arena, child.params[ord].name, value);
            ord += 1;
            continue;
        }
        // §3.4.7 an aliasparam is a second NAME for one parameter, so an
        // override through it lands on the target.
        var target = o.name;
        for (child.aliasparams) |al| if (al.alias == o.name) {
            target = al.target;
            break;
        };
        if (hier_param.Kind.fromName(self.ctx.file.str(target))) |kind| {
            // §6.3.3 an empty association supplies no new value.
            if (o.value == .none) continue;
            if (specified.get(kind) != .none) {
                try self.err(o.main_tok, .E0908, "`{s}` is given more than one value", .{kind.name()});
                continue;
            }
            specified.set(kind, value);
            spellings.set(kind, o.name);
            continue;
        }
        if (!try checkOverridable(self, child, target, o.name, o.main_tok)) continue;
        // §6.3.3 / IEEE 12.2.2.2: .name() documents the parameter but
        // leaves its default, dependencies and $param_given unchanged.
        // Validate the name/localparam above even when no value is given.
        if (o.value == .none) continue;
        // §3.4.7: "It shall be an error to specify a value for both the
        // original parameter and its alias in the same module instantiation".
        if (over.contains(target)) {
            try self.err(o.main_tok, .E0908, "`{s}` and its alias are both given a value", .{self.ctx.file.str(target)});
            continue;
        }
        try over.put(self.ctx.arena, target, value);
    }

    // Resolve §6.3.1 precedence BEFORE composition: a defparam replaces
    // the specified value, never the inherited contribution. §3.4.7
    // forbids assigning through different aliases, even across mechanisms.
    for (hier_param.Kind.all) |kind| {
        const direct = try self.ctx.file.intern(self.ctx.arena, kind.name());
        try collectSystemDefparam(self, path, kind, direct, &specified, &spellings);
        for (child.aliasparams) |al| if (al.target == direct)
            try collectSystemDefparam(self, path, kind, al.alias, &specified, &spellings);
        const value = specified.get(kind);
        unit.hier.set(kind, parent.hier.get(kind));
        if (value == .none or try checkSystemParam(self, kind, self.ctx.file.exprs.mainTok(value), value)) continue;
        unit.hier.set(kind, try kind.compose(self.ctx.file, self.ctx.arena, parent.hier.get(kind), value, self.ctx.file.exprs.mainTok(value)));
    }

    // §6.3.1 last: "If a defparam assignment conflicts with a module
    // instance parameter, the parameter in the module shall take the value
    // specified by the defparam." It overwrites `#(...)` whatever the text
    // order. §3.4.5 still holds: only overridable parameters are looked up.
    for (child.params, 0..) |p, i| {
        const binding = try parameterBinding(self, inst, child.params, child.aliasparams, i, path, true) orelse continue;
        if (binding.flat) try over.put(self.ctx.arena, p.name, binding.value);
    }

    try markGiven(self, child, over, unit);
}

fn collectSystemDefparam(self: *Flatten, path: []const u8, kind: hier_param.Kind, name: Ast.StrId, specified: *hier_param.Values, spellings: *std.EnumArray(hier_param.Kind, Ast.StrId)) Error!void {
    const dp = self.defparams.getPtrAdapted(PathKey{ .path = path, .local = self.ctx.file.str(name) }, PathKey.Context{}) orelse return;
    dp.used = true;
    const previous = spellings.get(kind);
    if (previous != .none and previous != name) {
        try self.err(dp.tok, .E0908, "`{s}` and its alias are both given a value", .{kind.name()});
        return;
    }
    specified.set(kind, dp.value);
    spellings.set(kind, name);
}
