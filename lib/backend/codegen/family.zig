//! Scalar family text (`contract.family_fns`): a MIR value's unknown set
//! (`Analysis.unknownDeps`) in, the mask literals, `zTo`/`zOf` wrappers and
//! the per-device `lane_masks` table out. A mask is written only where values
//! merge (hoisted slot, lazy `if` arms, array element, kernel result, returned
//! field, residual row); `zTo` fails to compile on a value whose lanes the mask
//! misses, so an unsound mask cannot drop a lane silently.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;

/// Returns the unknowns `v` may depend on: its mask before `zdr` cuts it.
pub fn mask(self: *const Gen, v: Mir.Value) u64 {
    return self.an.unknownDeps(v);
}

/// Writes `zTo(S, 0x<m>, `; the caller writes the value and the closing `)`.
pub fn openTo(self: *Gen, m: u64) Error!void {
    try self.b("zTo(S, 0x{x}, ", .{m});
}

/// Returns `zOf(S, 0x<m>)` as text for a `{s}` slot, allocated in the arena.
pub fn ofText(self: *Gen, m: u64) Error![]const u8 {
    return self.arena.print("zOf(S, 0x{x})", .{m});
}

/// Records one real the shared core declares at mask `m`, for `lane_masks`.
/// Ignored in `setup` (value scalar) and in a `probeBody` dry run.
pub fn note(self: *Gen, m: u64) Error!void {
    if (self.probe.active or !self.emitting_common or self.su.mode) return;
    try self.fam_masks.append(self.arena, m);
}

/// Writes `lane_masks`: every distinct mask a real was declared at, cut to
/// `deriv_reads`, with its use count. A host sizes its lane types from it.
/// Sorts `fam_masks` in place.
pub fn emitLaneMasks(self: *Gen, deriv_reads: u64) Error!void {
    const ms = self.fam_masks.items;
    for (ms) |*m| m.* &= deriv_reads;
    std.mem.sort(u64, ms, {}, std.sort.asc(u64));
    try self.w(
        \\/// Every distinct `Of` mask a real in this device is declared at, and
        \\/// how many are (`contract.laneMasks`).
        \\pub const lane_masks = [_]contract.LaneUse{{
        \\
    , .{});
    var i: usize = 0;
    while (i < ms.len) {
        var j = i;
        while (j < ms.len and ms[j] == ms[i]) j += 1;
        try self.w("    .{{ .mask = 0x{x}, .uses = {d} }},\n", .{ ms[i], j - i });
        i = j;
    }
    try self.w("}};\n\n", .{});
}

/// Returns `contract.Constant`: `.g` when ∂eval/∂x cannot depend on x, `.c`
/// when ∂q/∂x cannot, at every x and analysis point. False is always sound.
///
/// A value is affine in x when its lanes depend on the card alone: a probe, a
/// card constant, a sum or negation of affine values, an affine value times or
/// divided by a card constant, or a select or join on a card constant over
/// affine arms. A card constant varies with neither x nor host-rewritten state
/// (`gen_call.readsHostState`): `$abstime * V` has a constant partial at every
/// x and a different one at every time.
pub fn constant(self: *Gen) Error!struct { g: bool, c: bool } {
    const nv = self.an.nv;
    // `host` and `aff` are scratch of this pass (two nv-long columns, 250 KiB
    // on hisimhv_va): on the gpa, freed on return.
    const host = try self.gpa.alloc(bool, nv);
    defer self.gpa.free(host);
    @memset(host, false);
    var steered = false;
    for (0..self.mir.insts.len) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(i));
        if (self.mir.instOp(inst) == .branch and self.an.xDep(self.mir.instData(inst).branch.cond)) steered = true;
    }
    // The host-state cone, then the affine set: both monotone, so each
    // fixpoint settles in at most (longest chain) sweeps.
    var changed = true;
    while (changed) {
        changed = false;
        for (0..nv) |v| {
            if (host[v] or !hostStep(self, @fromBackingInt(@intCast(v)), host)) continue;
            host[v] = true;
            changed = true;
        }
    }
    const aff = try self.gpa.alloc(bool, nv);
    defer self.gpa.free(aff);
    @memset(aff, true);
    changed = true;
    while (changed) {
        changed = false;
        for (0..nv) |v| {
            if (!aff[v] or affineStep(self, @fromBackingInt(@intCast(v)), aff, host, steered)) continue;
            aff[v] = false;
            changed = true;
        }
    }
    const k: Lattice = .{ .g = self, .aff = aff, .host = host };
    var g = self.lowered.table_effect == .f_zero;
    var c = gen_dispatch.anyQ(self);
    for (self.lowered.contributions.items) |ct| {
        g = g and k.affine(ct.resist_val) and k.card(ct.wrote_val);
        c = c and k.affine(ct.react_val) and k.card(ct.wrote_val);
    }
    for (self.qs.sites) |s| c = c and k.affine(self.lowered.charge_sites.items[s].final);
    return .{ .g = g, .c = c };
}

const Lattice = struct {
    g: *const Gen,
    aff: []const bool,
    host: []const bool,
    fn affine(k: Lattice, v: Mir.Value) bool {
        return k.aff[@backingInt(k.g.an.rv(v))];
    }
    fn card(k: Lattice, v: Mir.Value) bool {
        return !k.g.an.xDep(v) and !k.host[@backingInt(k.g.an.rv(v))];
    }
};

/// One step of the host-state cone: a call that reads host state, or any
/// operand in the cone.
fn hostStep(self: *const Gen, v: Mir.Value, host: []const bool) bool {
    const in = struct {
        fn f(g: *const Gen, h: []const bool, o: Mir.Value) bool {
            return h[@backingInt(g.an.rv(o))];
        }
    }.f;
    const def = self.mir.valueDef(self.an.rv(v));
    if (def != .inst_result) return false;
    const inst = def.inst_result;
    return switch (self.mir.instData(inst)) {
        .call => |c| gen_call.readsHostState(self, inst) or for (c.args) |a| {
            if (in(self, host, a)) break true;
        } else false,
        .unary => |u| in(self, host, u.operand),
        .binary => |b| in(self, host, b.lhs) or in(self, host, b.rhs),
        .ternary => |t| in(self, host, t.cond) or in(self, host, t.then_val) or in(self, host, t.else_val),
        .phi => |d| for (0..d.count) |j| {
            if (in(self, host, self.mir.phiPair(inst, @intCast(j)).value)) break true;
        } else false,
        .load => |l| in(self, host, l.arr) or in(self, host, l.index),
        .store => |s| in(self, host, s.arr) or in(self, host, s.index) or in(self, host, s.value),
        .anew, .branch, .jump => false,
    };
}

/// One step of the affine set, given the current answer for the operands.
fn affineStep(self: *const Gen, v: Mir.Value, aff: []const bool, host: []const bool, steered: bool) bool {
    const k: Lattice = .{ .g = self, .aff = aff, .host = host };
    if (k.card(v)) return true;
    const def = self.mir.valueDef(self.an.rv(v));
    switch (def) {
        .block_param => return true,
        .undef, .float_const, .int_const, .str_const, .param_ref => return true,
        .inst_result => |inst| return switch (self.mir.instData(inst)) {
            // `dstop`'s lanes are zero at every x.
            .unary => |u| if (u.op == .fneg) k.affine(u.operand) else u.op == .dstop,
            .binary => |b| if (b.op == .fadd or b.op == .fsub)
                k.affine(b.lhs) and k.affine(b.rhs)
            else if (b.op == .fmul)
                (k.card(b.lhs) and k.affine(b.rhs)) or (k.card(b.rhs) and k.affine(b.lhs))
            else if (b.op == .fdiv)
                k.affine(b.lhs) and k.card(b.rhs)
            else
                false,
            .ternary => |t| k.card(t.cond) and k.affine(t.then_val) and k.affine(t.else_val),
            // A join is a select on the branch that reached it.
            .phi => |d| !steered and for (0..d.count) |j| {
                if (!k.affine(self.mir.phiPair(inst, @intCast(j)).value)) break false;
            } else true,
            .call, .load, .store, .anew, .branch, .jump => false,
        },
    }
}
