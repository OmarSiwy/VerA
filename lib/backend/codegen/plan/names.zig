//! Names: every identifier the device declares, and the unknowns behind them —
//! decided before a byte is written.
//!
//! PURE (ARCHITECTURE.md §2): `plan` takes the lowered module and returns a
//! `Names`. No `*Gen`, no writer, no diagnostics, so it is testable from a
//! hand-built `Mir`/`Lowered` (see the tests at the bottom).
//!
//! LRM clauses this file's code cites: §3.4.7, §5.4.1, §5.4.2, §5.6, §5.6.7.1,
//! §5.10, §9.19.
//!
//! Cut verbatim from `codegen.zig` (`buildUnits`/`buildNames`); only the
//! receiver changed.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lowered = @import("ir").Lowered;
const naming = @import("../../naming.zig");
const Input = @import("input.zig").Input;

pub const Error = std.mem.Allocator.Error || error{NameTooLong};
const none_u32 = std.math.maxInt(u32);

pub const Names = struct {
    units: []naming.Unit = &.{},
    unit_names: [][]const u8 = &.{},
    /// Extra solver unknowns codegen appends after `Lowered.nodes`: one
    /// branch current per §5.6 potential contribution that lowering did not
    /// already give a `flow(a,b)` slot. Values are `nodes`-space indices.
    branch_u: []u32 = &.{},
    n_u: u32 = 0,
    /// Sanitized U-enum member name per unknown.
    u_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lowered.params` entry.
    p_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lowered.aliases` entry (§3.4.7).
    a_names: [][]const u8 = &.{},
    /// §5.10 `Instance` field name per `Lowered.held_vars` entry.
    held_names: [][]const u8 = &.{},
    /// Parameters queried by §9.19 `$param_given` (they gain a `__given` flag).
    p_given: []bool = &.{},
};

/// `n_unit_modes` is `Verdict.unit_modes.len`: the canonical-order contract
/// `unitMode` depends on is checked here, where all three tables are in hand
/// for the only time.
pub fn plan(in: Input, n_unit_modes: usize) Error!Names {
    const a = in.arena;
    const mir = in.mir;
    const an = in.an;
    const lowered = in.lowered;
    var self: Names = .{};
    self.units = naming.enumerateUnits(a, mir, lowered) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSpaceLeft => return error.NameTooLong,
    };
    // The contract `unitMode` below depends on, checked once where all
    // three tables are in hand for the only time.
    naming.assertCanonicalOrder(self.units, lowered, n_unit_modes);
    self.unit_names = try a.alloc([]const u8, self.units.len);
    var buf: [naming.max_name_len]u8 = undefined;
    for (self.units, 0..) |u, i| {
        const n = naming.unitName(&buf, mir.name, u) catch return error.NameTooLong;
        self.unit_names[i] = try a.dupe(u8, n);
    }

    // §5.6 potential contributions need a branch-current unknown. Lowering
    // allocates a `flow(a,b)` slot only where the model PROBES I(a,b), so
    // codegen appends the missing ones after `nodes` — every existing
    // block_param index keeps its meaning.
    const base: u32 = @intCast(lowered.nodes.len);
    self.branch_u = try a.alloc(u32, lowered.contributions.items.len);
    @memset(self.branch_u, none_u32);
    // Raw names of the unknowns appended after `nodes`, in append order.
    var extra: std.ArrayList([]const u8) = .empty;
    for (lowered.contributions.items, 0..) |c, i| {
        // A §5.6 potential source and a §5.6.7 indirect (nullor) source are
        // the same topology: a source in the branch whose current is its
        // own unknown.
        if (c.access != .potential and c.kind != .indirect) continue;
        // Reuse the §5.4.2 slot lowering already allocated because the model
        // PROBES I(a,b) — unless an earlier contribution is already driving
        // it. §5.6.7.1 permits several indirect contributions to one branch,
        // and each is a separate source with a separate current.
        //
        // Asked for by the NODE PAIR, which is the identity §5.4.1 gives the
        // branch. This used to format `flow(hi,lo)` and scan `nodes`
        // for a string match, which made it the fourth place that re-derived
        // structure from a spelling — and the one that survived the key
        // split in lowering: §1.3.1.1's reference node prints `gnd`, so on a
        // module with a plain net called `gnd` the branches (a, reference)
        // and (a, gnd) matched each other's slot and V(a) and V(a,gnd) drove
        // one current.
        var found: u32 = if (lowered.flow_unknowns.get(.{ .hi = c.hi, .lo = c.lo })) |u| u else none_u32;
        if (found != none_u32 and uIsDriven(self.branch_u, found, i)) found = none_u32;
        if (found == none_u32) {
            const nm = try std.fmt.allocPrint(a, "flow({s},{s})", .{
                lowered.nodeName(c.hi), lowered.nodeName(c.lo),
            });
            found = base + @as(u32, @intCast(extra.items.len));
            try extra.append(a, try freshUName(a, lowered, nm, extra.items));
        }
        self.branch_u[i] = found;
    }
    self.n_u = base + @as(u32, @intCast(extra.items.len));

    self.u_names = try a.alloc([]const u8, self.n_u);
    for (lowered.nodes.items(.name), 0..) |n, i| {
        self.u_names[i] = try a.dupe(u8, naming.sanitize(&buf, n) catch return error.OutOfMemory);
    }
    for (extra.items, 0..) |n, k| {
        self.u_names[base + k] = try a.dupe(u8, naming.sanitize(&buf, n) catch return error.OutOfMemory);
    }

    self.p_names = try a.alloc([]const u8, lowered.params.items.len);
    for (lowered.params.items, 0..) |p, i| {
        self.p_names[i] = try a.dupe(u8, naming.sanitize(&buf, p.name) catch return error.OutOfMemory);
    }
    self.a_names = try a.alloc([]const u8, lowered.aliases.items.len);
    for (lowered.aliases.items, 0..) |al, i| {
        self.a_names[i] = try a.dupe(u8, naming.sanitize(&buf, al.name) catch return error.OutOfMemory);
    }

    // §5.10 held variables. Same `<module>__<role>__<target>` grammar
    // `naming.unitName` builds, with `held` where a role word would go:
    // `naming.Role` is a closed set that this is deliberately not a member
    // of (a held variable is not an emitted source unit), and no enumerated
    // unit can spell that segment, so the two name spaces cannot meet. The
    // target is one `sanitize`d leaf, which is injective — and a module
    // variable's name is unique in its scope, so the whole key is.
    self.held_names = try a.alloc([]const u8, lowered.held_vars.items.len);
    if (self.held_names.len != 0) {
        var mod_buf: [naming.max_name_len]u8 = undefined;
        const mod = naming.sanitize(&mod_buf, mir.name) catch return error.NameTooLong;
        for (lowered.held_vars.items, 0..) |h, i| {
            const leaf = naming.sanitize(&buf, h.name) catch return error.NameTooLong;
            self.held_names[i] = try std.fmt.allocPrint(a, "{s}__held__{s}", .{ mod, leaf });
        }
    }
    self.p_given = try a.alloc(bool, lowered.params.items.len);
    @memset(self.p_given, false);
    // A non-local parameter whose default reads another parameter is a
    // `derive()` target, and its guard (`if (!model.X__given)`) needs the
    // flag whether or not the model ever queries §9.19 — same fold
    // condition `emitDerive` selects assignments on.
    for (lowered.params.items, 0..) |p, i| {
        if (p.is_local or Analysis.tyOfParam(p.ty) == .str) continue;
        if (an.foldConst(p.default, 0, false) == null) self.p_given[i] = true;
    }
    // §9.19 $param_given(p): the flag lives in Model, but only for the
    // parameters actually asked about.
    for (0..an.nb) |bi| {
        for (an.blockInstsFlat(@intCast(bi))) |inst| {
            if (mir.instOp(inst) != .call) continue;
            const d = mir.instData(inst).call;
            if (d.callee != .@"$param_given") continue;
            if (d.args.len == 0) continue;
            const def = mir.valueDef(an.rv(d.args[0]));
            if (def == .param_ref) self.p_given[def.param_ref] = true;
        }
    }
    return self;
}

/// Is unknown `u` already the current of a source from a contribution
/// before `i`? Two sources in one branch need two currents.
fn uIsDriven(branch_u: []const u32, u: u32, i: usize) bool {
    // ponytail: stdlib scans the same bounded prefix; no membership table needed.
    return std.mem.indexOfScalar(u32, branch_u[0..i], u) != null;
}

/// `nm`, or `nm#k` for the first `k` that no unknown claims yet. `sanitize`
/// escapes `#`, so the emitted U member stays a legal, injective name.
fn freshUName(a: std.mem.Allocator, lowered: *const Lowered, nm: []const u8, extra: []const []const u8) Error![]const u8 {
    var name = nm;
    var k: u32 = 1;
    while (uNameTaken(lowered, name, extra)) : (k += 1) {
        name = try std.fmt.allocPrint(a, "{s}#{d}", .{ nm, k });
    }
    return name;
}

fn uNameTaken(lowered: *const Lowered, nm: []const u8, extra: []const []const u8) bool {
    for (lowered.nodes.items(.name)) |n| {
        if (std.mem.eql(u8, n, nm)) return true;
    }
    for (extra) |n| {
        if (std.mem.eql(u8, n, nm)) return true;
    }
    return false;
}

const Fixture = @import("fixture.zig").Fixture;
const Lower = @import("ir").Lower;

test "a potential source gets a branch current; two on one branch get two" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    // I(a,b) <+ …  (no unknown), V(a,b) <+ …  twice (two currents), V(b) <+ …
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 0, .lo = 1 });
    try f.lowered.contributions.append(a, .{ .access = .potential, .hi = 1, .lo = Lower.ground });
    const an = try f.analysis();

    const n = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, 4);
    try std.testing.expectEqual(@as(u32, 5), n.n_u);
    try std.testing.expectEqualSlices(u32, &.{ none_u32, 2, 3, 4 }, n.branch_u);
    // The second current on (a,b) takes the first free `#k`, sanitized.
    try std.testing.expectEqualStrings("a", n.u_names[0]);
    try std.testing.expect(!std.mem.eql(u8, n.u_names[2], n.u_names[3]));
    try std.testing.expectEqual(@as(usize, 4), n.unit_names.len);
    try std.testing.expectEqualStrings("mymod__analog__I_a_b", n.unit_names[0]);
}
