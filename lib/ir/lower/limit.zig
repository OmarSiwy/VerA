//! §9.17.3 `$limit`: the limiting-function call and its state slot.
//!
//! In: `$limit(access, fn, ...)` calls. Out: the inlined call and one `LimitSlot` per
//! access function, shared by every site that names it.
//!
//! LRM clauses this file's code cites: §2.8, §4.5.15, §4.7, §9.17.3, §9.20.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_contrib = @import("contrib.zig");
const lower_func = @import("func.zig");
const lower_node = @import("node.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;

/// Returns the §4.7 function a `$limit` second argument names, or null when it names
/// none (Syntax 9-12's other two forms put a string there, or nothing).
/// A variable or parameter with the same name wins over the function (LRM §2.8).
// ponytail: lookup only; add an error set if resolution ever does fallible work.
pub fn limitUserFunc(self: *Lower, a: Ast.ExprId) ?*const Ast.FuncDecl {
    const ex = &self.file.exprs;
    if (a == .none or ex.tag(a) != .ident) return null;
    const name = self.file.str(ex.strOf(a));
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name))
        return null;
    const m = self.out.module orelse return null;
    for (m.functions) |*fd| {
        if (std.mem.eql(u8, self.file.str(fd.name), name)) return fd;
    }
    return null;
}

/// Lowers `$limit(access, user_function, args...)` to the inlined call
/// `user_function(vnew, vold, args...)`, where `vold` comes from the access function's `LimitSlot`
/// and the result becomes that slot's next state (LRM §9.17.3).
///
/// The result carries the access function's derivative, not the limiter's: the host
/// stamps `I(vlim) + g(vlim)*(v - vlim)`, so the Jacobian entry never vanishes in the
/// clamped region. `$limit$uf` (codegen `zLimitUf`) shifts `vlim.val()` onto the probe.
pub fn lowerLimitUser(self: *Lower, e: Ast.ExprId, fd: *const Ast.FuncDecl, args: []const Ast.ExprId) Oom!TypedValue {
    // §9.17.3 the first argument is an ACCESS FUNCTION, never a net.
    const vnew = try self.toReal(try lower_sysfunc.lowerSysArg(self, args[0], false));
    const slot = try limitSlotOf(self, args[0]) orelse {
        // No access function to key state on (`$limit(x, f)` with an ordinary
        // expression). §4.5.15 lets a simulator decline any limiting request;
        // declining is the one answer that cannot invent state.
        return .{ .v = try self.call("$limit", &.{vnew}), .ty = .real };
    };
    // The seed, not the slot's running value: §9.17.3's second argument is "the value
    // that was returned by the $limit() function on the previous iteration", so every
    // site on one access function reads the same number. Reading the running value
    // would chain the sites and limit twice per evaluation.
    const old = self.out.limit_slots.items[slot].seed;
    const res = try self.toReal(try lower_func.inlineUserFuncPre(self, fd, &.{ vnew, old }, args[2..], e));
    // Written at the site, so the last site to run this evaluation is the one the
    // next iterate reads.
    try self.builder.writeVariable(self.limit_places.items[slot], self.cur, res);
    return .{ .v = try self.call("$limit$uf", &.{ vnew, res }), .ty = .real };
}

/// The `limit_slots` index for this access function, minting nothing: `scanCallSites`
/// created every slot before the body was lowered. Null when `a` is not an access function.
fn limitSlotOf(self: *Lower, a: Ast.ExprId) Oom!?usize {
    const t = try limitSlotKey(self, a) orelse return null;
    for (self.out.limit_slots.items, 0..) |s, i| {
        if (s.access == t.access and s.hi == t.hi and s.lo == t.lo and s.neg == t.neg and s.br == t.br)
            return i;
    }
    return null;
}

/// The branch an access function names, or null for anything that is not one.
/// Called twice per expression; the bag dedupes `branchOf`'s diagnostics by
/// `(code, span)`, so a malformed access function is reported once.
fn limitSlotKey(self: *Lower, a: Ast.ExprId) Oom!?lower_contrib.Target {
    if (a == .none or self.file.exprs.tag(a) != .branch_access) return null;
    return lower_contrib.branchOf(self, a);
}

/// Creates the `LimitSlot` for access function `a` unless one with the same branch
/// exists, seeding its state place in the current block (LRM §9.17.3). Does nothing
/// when `a` is not an access function.
pub fn addLimitSlot(self: *Lower, a: Ast.ExprId) Oom!void {
    const t = try limitSlotKey(self, a) orelse return;
    for (self.out.limit_slots.items) |s| {
        if (s.access == t.access and s.hi == t.hi and s.lo == t.lo and s.neg == t.neg and s.br == t.br)
            return;
    }
    const k: i64 = @intCast(self.out.limit_slots.items.len);
    // A `call`, so `analysis.foldConst` cannot fold the previous iterate into a constant.
    const seed = try self.call("$limit$old", &.{try self.mir.addIntConst(self.arena, k)});
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, seed);
    try self.out.limit_slots.append(self.arena, .{
        .label = try self.arena.print("{s}({s},{s})", .{
            if (t.access == .potential) "V" else "I", lower_node.nodeName(self, t.hi), lower_node.nodeName(self, t.lo),
        }),
        .access = t.access,
        .hi = t.hi,
        .lo = t.lo,
        .neg = t.neg,
        .br = t.br,
        .seed = seed,
    });
    try self.limit_places.append(self.arena, place);
}

/// §9.20's outcome for one `$analog_node_alias()` / `$analog_port_alias()`
/// call: the six validity rules are errors, and what survives them is the
/// clause's own return value.
pub const AliasResult = enum {
    /// One of §9.20's six "shall be an error" sentences (E0812). The call has
    /// no value; lowering poisons it.
    refused,
    /// "the hierarchical_reference_string points to a valid continuous node":
    /// the analog_net_reference now names that node's unknown, and the call
    /// returns 1.
    bound,
    /// The string resolves to nothing this design contains. §9.20: the call
    /// returns 0 and "the node referenced by the analog_net_reference shall be
    /// treated as a normal continuous node declared in the module".
    unresolved,
};
