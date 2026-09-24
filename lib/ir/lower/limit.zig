//! `$limit`: the limiting-function call and its per-call state slot.
//!
//! In: `$limit(access, fn, ...)` calls. Out: a `LimitSlot` per call site and the MIR call.
//!
//! LRM clauses this file's code cites: §2.8, §4.5.15, §4.7, §9.17.3, §9.20.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_limit.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_contrib = @import("contrib.zig");
const lower_func = @import("func.zig");
const lower_node = @import("node.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const call = Lower.call;
const toReal = Lower.toReal;

/// The §4.7 function a `$limit` second argument names, or null when the argument
/// is not one — Syntax 9-12's other two forms put a string there, or nothing.
///
/// The ordinary scopes are consulted FIRST, so a variable or parameter that
/// happens to share a function's name still wins (§2.8), exactly as
/// `natureAbstol` arranges for a nature identifier in a tolerance slot.
// ponytail: lookup only; add an error set if resolution ever does fallible work.
pub fn limitUserFunc(self: *Lower, a: Ast.ExprId) ?*const Ast.FuncDecl {
    const ex = &self.file.exprs;
    if (ex.tag(a) != .ident) return null;
    const name = self.file.str(ex.strOf(a));
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name))
        return null;
    const m = self.out.module orelse return null;
    for (m.functions) |*fd| {
        if (std.mem.eql(u8, self.file.str(fd.name), name)) return fd;
    }
    return null;
}

/// §9.17.3 the third form: `$limit(access, user_function, args…)` returns
/// `user_function(vnew, vold, args…)` — the access function's value at this
/// iterate, the value the slot returned at the previous one, then the call's
/// own tail. The function is an ordinary §4.7 body, so it is INLINED like every
/// other analog function; the only thing §9.17.3 adds is where `vold` comes
/// from (`LimitSlot`) and where the return goes (the same slot).
///
/// THE RETURNED VALUE CARRIES THE ACCESS FUNCTION'S DERIVATIVE, not the
/// limiter's. That is the point of limiting and not a shortcut: SPICE evaluates
/// the device at the limited bias and stamps `I(vlim) + g(vlim)·(v − vlim)`, so
/// the residual is LINEAR in the true unknown beyond the limit point and the
/// Jacobian entry never vanishes. Differentiating the limiter itself instead
/// gives dv_lim/dv = 0 inside the clamped region — a device that contributes no
/// conductance, which is a singular row for a floating internal node. `$limit$uf`
/// renders that as `vlim.val()` shifted onto the probe (codegen `zLimitUf`), the
/// same relation the STRING form gets for free from the host writing its clamp
/// back into `x` before `eval` runs (cg_limit.zig's header).
pub fn lowerLimitUser(self: *Lower, e: Ast.ExprId, fd: *const Ast.FuncDecl, args: []const Ast.ExprId) Oom!TypedValue {
    // §9.17.3 the first argument is an ACCESS FUNCTION, never a net.
    const vnew = try self.toReal(try lower_sysfunc.lowerSysArg(self, args[0], false));
    const slot = try limitSlotOf(self, args[0]) orelse {
        // No access function to key state on (`$limit(x, f)` with an ordinary
        // expression). §4.5.15 lets a simulator decline any limiting request;
        // declining is the one answer that cannot invent state.
        return .{ .v = try self.call("$limit", &.{vnew}), .ty = .real };
    };
    // The SEED, not the slot's running value: §9.17.3 says the second argument
    // is "the value that was returned by the $limit() function on the PREVIOUS
    // iteration", so every site on one access function reads the same number
    // however many of them ran this time. Reading the running value instead
    // chains them — a reader followed by a writer would limit twice per
    // evaluation and halve the damping.
    const old = self.out.limit_slots.items[slot].seed;
    const res = try self.toReal(try lower_func.inlineUserFuncPre(self, fd, &.{ vnew, old }, args[2..], e));
    // The site's return is the slot's NEXT state. Written at the site, so the
    // last site to run this evaluation is the one the next iterate reads —
    // which is what makes the read-then-write accessor idiom work.
    try self.builder.writeVariable(self.limit_places.items[slot], self.cur, res);
    return .{ .v = try self.call("$limit$uf", &.{ vnew, res }), .ty = .real };
}

/// The `limit_slots` index for this access function, minting nothing: every
/// slot was created by `scanCallSites` before the body was lowered. Null
/// when the argument is not an access function at all.
pub fn limitSlotOf(self: *Lower, a: Ast.ExprId) Oom!?usize {
    const t = try limitSlotKey(self, a) orelse return null;
    for (self.out.limit_slots.items, 0..) |s, i| {
        if (s.access == t.access and s.hi == t.hi and s.lo == t.lo and s.neg == t.neg and s.br == t.br)
            return i;
    }
    return null;
}

/// The branch an access function names. `null` for anything that is not one.
///
/// Asked twice of the same expression — once by `scanCallSites`, once by
/// the site — and that costs nothing: `branchOf`'s diagnostics are deduped by
/// `(code, span)` in the bag, so a malformed access function is still reported
/// exactly once.
pub fn limitSlotKey(self: *Lower, a: Ast.ExprId) Oom!?lower_contrib.Target {
    if (a == .none or self.file.exprs.tag(a) != .branch_access) return null;
    return lower_contrib.branchOf(self, a);
}

pub fn addLimitSlot(self: *Lower, a: Ast.ExprId) Oom!void {
    const t = try limitSlotKey(self, a) orelse return;
    for (self.out.limit_slots.items) |s| {
        if (s.access == t.access and s.hi == t.hi and s.lo == t.lo and s.neg == t.neg and s.br == t.br)
            return;
    }
    const k: i64 = @intCast(self.out.limit_slots.items.len);
    // A `call`, so it is opaque to `analysis.foldConst` — the previous iterate
    // is not a constant, however constant the rest of the expression is.
    const seed = try self.call("$limit$old", &.{try self.mir.addIntConst(self.arena, k)});
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, seed);
    try self.out.limit_slots.append(self.arena, .{
        .label = try std.fmt.allocPrint(self.arena, "{s}({s},{s})", .{
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
