//! Outlining (`--outline-chunk=N`): cutting a long body into noinline chunks.
//!
//! In: a unit body being emitted. Out: the same statements, cut into chunk functions every N
//! statements so the Zig compiler's time and memory stay bounded.
//!
//! LRM clauses this file's code cites: §5.6.1.3.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_outline.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_hoist = @import("hoist.zig");
const gen_render = @import("render.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;

// ---- outlining ----------------------------------------------------------

/// Cut trigger, called at the two places a chunk may end: between top-level
/// statements (`emitBlockInsts` at depth 1) and before a top-level subtree
/// (`emitTree` at depth 1). Depth 1 means no label, loop or arm is open —
/// the emitter's depth IS its brace count — so a `break`/`continue` can
/// never cross a chunk boundary, and every value that does is in a hoist
/// array (the probe's per-chunk scopes force exactly that).
pub fn maybeCut(self: *Gen) Error!void {
    // Same two call sites, same reason (see below): depth 1 is the only
    // place a region boundary can land. The two are mutually exclusive —
    // `planHoistPrefix` declines whenever `outline` is set.
    try gen_hoist.hpBoundary(self);
    if (!self.oc_on or self.oc_insts < self.outline) return;
    self.oc_insts = 0;
    self.oc_cuts += 1;
    if (self.probing) {
        gen_unit.scopeClose(self, self.out.items.len);
        try gen_unit.scopeOpen(self);
        try self.oc_bounds.append(self.arena, @intCast(self.out.items.len));
    } else if (self.oc_real) {
        try closeChunkFn(self);
        try openChunkFn(self);
    }
}

/// The chunk whose probe-text interval contains this slot's whole life,
/// or null when it spans a boundary (or the driver's return).
pub fn ocLocalIn(self: *const Gen, p: gen_unit.Place) ?u32 {
    const hi = @max(p.max_use, p.max_def);
    const bounds = self.oc_bounds.items;
    for (0..bounds.len - 1) |k| {
        if (p.def_off >= bounds[k] and hi < bounds[k + 1]) return @intCast(k);
    }
    return null;
}

/// One chunk header. Uniform signature — always all three unit parameters
/// plus every hoist array the unit has — with the same reserve-and-patch
/// slots as `emitUnit`, so a chunk that reads only `h` says so.
pub fn openChunkFn(self: *Gen) Error!void {
    try self.w("fn {s}__c{d}(comptime S: type, ", .{ self.oc_name, self.oc_cuts });
    self.oc_at[0] = self.out.items.len;
    try self.w("x: *const [n_u]S, ", .{});
    self.oc_at[1] = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    self.oc_at[2] = self.out.items.len;
    try self.w("inst: InstancePtr", .{});
    for ([_]VTy{ .real, .int, .str }) |ty| {
        const n = self.oc_n[@intFromEnum(ty)];
        if (n == 0) continue;
        try self.w(", ", .{});
        self.oc_at[3 + @intFromEnum(ty)] = self.out.items.len;
        try self.w("{s}: *[{d}]{s}", .{ gen_unit.hoistArray(ty), n, gen_unit.zigTy(ty) });
    }
    try self.w(") void {{\n", .{});
    try self.w("    @setFloatMode(.{s});\n", .{self.oc_mode});
    // This chunk's own share of the out-of-SSA vars (see `ocLocalIn`).
    for (self.oc_local_chunk.items, self.oc_local_slot.items, self.oc_local_ty.items) |k, slot, ty| {
        if (k != self.oc_cuts) continue;
        try self.w("    var t{d}: {s} = undefined;\n", .{ slot, gen_unit.zigTy(ty) });
    }
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    self.oc_use = @splat(false);
}

pub fn closeChunkFn(self: *Gen) Error!void {
    if (!self.uses_x) gen_unit.patchParam(self, self.oc_at[0], "x".len);
    if (!self.uses_model) gen_unit.patchParam(self, self.oc_at[1], "model".len);
    if (!self.uses_inst) gen_unit.patchParam(self, self.oc_at[2], "inst".len);
    if (self.oc_n[0] != 0 and !self.oc_use[0]) gen_unit.patchParam(self, self.oc_at[3], "h".len);
    if (self.oc_n[1] != 0 and !self.oc_use[1]) gen_unit.patchParam(self, self.oc_at[4], "hi".len);
    if (self.oc_n[2] != 0 and !self.oc_use[2]) gen_unit.patchParam(self, self.oc_at[5], "hs".len);
    try self.w("}}\n\n", .{});
}

/// The real walk, emitted as sibling `fn`s after the driver's closing
/// brace. Same walk the probe ran, so the cuts land on the same statements;
/// the driver's call list was emitted from the probe's count and the assert
/// is the agreement check.
pub fn emitChunkFns(self: *Gen, target: Mir.Value) Error!void {
    if (!self.oc_on) return;
    self.oc_real = true;
    self.oc_insts = 0;
    self.oc_cuts = 0;
    self.oc_returns = 0;
    try openChunkFn(self);
    try emitTree(self, 0, 1, target);
    try closeChunkFn(self);
    self.oc_real = false;
    self.oc_on = false;
    assert(self.oc_cuts + 1 == self.oc_total);
}

/// A unit returns its one contribution value; the common declaration
/// returns the whole cache. Same exit points either way, so this is the one
/// place that knows the difference.
pub fn emitReturn(self: *Gen, depth: u32, target: Mir.Value) Error!void {
    try self.ind(depth);
    if (!self.emitting_common) {
        try self.b("return ", .{});
        try gen_render.renderVal(self, target, .real);
        try self.b(";\n", .{});
        return;
    }
    // An exit inside the prefix guard would skip the else arm's reloads and
    // the whole body after them, so the region ends before it.
    self.hp_dirty = true;
    try self.b("return .{{\n", .{});
    for (self.lo_vals, 0..) |v, k| {
        try self.ind(depth + 1);
        try self.b(".f{d} = ", .{k});
        try gen_render.renderVal(self, v, self.an.vty[@intFromEnum(v)]);
        try self.b(",\n", .{});
    }
    // The prefix's live-outs ride out as ordinary fields — that is the only
    // way `precompute` can see them (`planHoistPrefix`).
    for (self.hp_vals, 0..) |v, j| {
        try self.ind(depth + 1);
        try self.b(".f{d} = ", .{self.lo_vals.len + j});
        try gen_render.renderVal(self, v, self.an.vty[@intFromEnum(v)]);
        try self.b(",\n", .{});
    }
    try self.ind(depth);
    try self.b("}};\n", .{});
}

pub fn emitBlockInsts(self: *Gen, bi: u32, depth: u32, comptime decl: bool) Error!void {
    const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
    for (stmts) |inst| {
        const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
        if (!self.plan.needed[i] or self.plan.slot[i] == none_u32) continue;
        if (depth == 1) try maybeCut(self);
        gen_hoist.hpMarkInst(self, inst);
        self.oc_insts += 1;
        gen_unit.probeDef(self, self.plan.slot[i], true);
        // `or` short-circuits, so the straight-line path (`decl`, which runs
        // without a probe) never touches `place`.
        const at_def = decl or self.place.items[self.plan.slot[i]].at_def;
        try self.ind(depth);
        if (at_def) {
            try self.b("const t{d}: {s} = ", .{ self.plan.slot[i], gen_unit.zigTy(self.an.vty[i]) });
        } else {
            try gen_unit.writeSlotRef(self, i);
            try self.b(" = ", .{});
        }
        try gen_render.renderInst(self, inst);
        try self.b(";\n", .{});
    }
}

pub fn emitTree(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
    if (depth == 1) try maybeCut(self);
    if (self.an.is_loop[bi]) {
        try self.ind(depth);
        try self.b("L{d}: while (true) {{\n", .{bi});
        try gen_unit.scopeOpen(self);
        try emitCode(self, bi, depth + 1, target);
        gen_unit.scopeClose(self, self.out.items.len);
        try self.ind(depth);
        try self.b("}}\n", .{});
    } else {
        try emitCode(self, bi, depth, target);
    }
}

pub fn emitCode(self: *Gen, bi: u32, depth0: u32, target: Mir.Value) Error!void {
    const mc = self.an.mk_pool[self.an.mk_off[bi]..self.an.mk_off[bi + 1]];
    var depth = depth0;
    // Where the INNERMOST label (`mc[0]`, opened last) begins — the peephole
    // below rewinds to it.
    var at_inner: usize = 0;
    var i = mc.len;
    while (i > 0) {
        i -= 1;
        if (i == 0) at_inner = self.out.items.len;
        try self.ind(depth);
        try self.b("B{d}: {{\n", .{mc[i]});
        try gen_unit.scopeOpen(self);
        depth += 1;
    }
    const body_start = self.out.items.len;
    try emitBlockInsts(self, bi, depth, false);
    try emitTerm(self, bi, depth, target);

    // PEEPHOLE. `B{k}: { break :B{k}; }` is a labelled block whose only
    // statement is to leave it, and an empty one says the same thing — both
    // mean "fall through to `k`'s own code", which is emitted right after
    // the closing brace either way. This is what `planDeadBranches` leaves
    // behind once the `if` that used to sit here is gone: measured on
    // `bsimsoi_va`, 2 262 of a unit's remaining 3 207 lines. Rewinding `out`
    // is the same reserve-and-back-patch `emitUnit` uses for the signature.
    const dropped = mc.len != 0 and isFallThrough(self, body_start, depth, mc[0]);
    if (dropped) {
        self.out.shrinkRetainingCapacity(at_inner);
        gen_unit.scopeClose(self, at_inner);
        depth -= 1;
    }
    for (mc, 0..) |k, j| {
        if (j != 0 or !dropped) {
            depth -= 1;
            gen_unit.scopeClose(self, self.out.items.len);
            try self.ind(depth);
            try self.b("}}\n", .{});
        }
        try emitTree(self, k, depth, target);
    }
}

/// Is everything emitted since `at` exactly "leave the block labelled `k`"?
/// A break to any OTHER label is not the same thing: dropping this label
/// would then let control fall into `k`'s code instead of past it.
pub fn isFallThrough(self: *const Gen, at: usize, depth: u32, k: u32) bool {
    const body = self.out.items[at..];
    if (body.len == 0) return true;
    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "break :B{d};\n", .{k}) catch return false;
    if (body.len != depth * 4 + want.len) return false;
    for (body[0 .. depth * 4]) |ch| {
        if (ch != ' ') return false;
    }
    return std.mem.eql(u8, body[depth * 4 ..], want);
}

pub fn emitTerm(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
    const t = self.an.term[bi];
    if (t == .none) {
        // The block lowering ended in: the contribution accumulators are
        // read here (§5.6.1.3).
        if (self.oc_on) {
            self.oc_returns += 1;
            if (self.oc_real) {
                // The driver owns the VALUE return; the chunk still must
                // LEAVE here — hisimhv's exit sits inside a `while (true)`,
                // and falling through where the monolith returned re-runs
                // the loop forever.
                try self.ind(depth);
                try self.b("return;\n", .{});
                return;
            }
            // Probe: render it so its reads are counted — pinned into the
            // hoist arrays by `probeUse` — and record where it ended for
            // `probeBody`'s trailing-text feasibility check. The pre-
            // return offset closes the last chunk-locality interval, so
            // a slot the return reads can never classify chunk-local.
            try self.oc_bounds.append(self.arena, @intCast(self.out.items.len));
            self.oc_in_ret = true;
            try emitReturn(self, depth, target);
            self.oc_in_ret = false;
            if (self.oc_returns == 1) self.oc_ret_at = self.out.items.len;
            return;
        }
        try emitReturn(self, depth, target);
        return;
    }
    switch (self.mir.instData(t)) {
        .jump => |d| try emitEdge(self, bi, @intFromEnum(d.target), depth, target),
        .branch => |d| {
            // `planDeadBranches`: both arms reconverge with nothing this
            // unit can observe in between, so emit the common action once.
            if (self.plan.dead_branch[bi])
                return emitEdge(self, bi, @intFromEnum(d.then_block), depth, target);
            // The condition decides which arm's phi copies run, so a
            // bias-dependent one ends the region even when both arms are
            // parameter-only.
            gen_hoist.hpMark(self, d.cond);
            try self.ind(depth);
            try self.b("if (", .{});
            try renderCond(self, d.cond);
            try self.b(") {{\n", .{});
            try gen_unit.scopeOpen(self);
            try emitEdge(self, bi, @intFromEnum(d.then_block), depth + 1, target);
            gen_unit.scopeClose(self, self.out.items.len);
            try self.ind(depth);
            try self.b("}} else {{\n", .{});
            try gen_unit.scopeOpen(self);
            try emitEdge(self, bi, @intFromEnum(d.else_block), depth + 1, target);
            gen_unit.scopeClose(self, self.out.items.len);
            try self.ind(depth);
            try self.b("}}\n", .{});
        },
        else => unreachable,
    }
}

pub fn renderCond(self: *Gen, cond: Mir.Value) Error!void {
    gen_render.pinLanes(self, cond);
    const v = self.an.rv(cond);
    if (self.an.tyOf(v) == .int) {
        try gen_render.renderVal(self, v, .int);
        try self.b(" != 0", .{});
    } else {
        try self.b("(", .{});
        try gen_render.renderVal(self, v, .real);
        try self.b(").val() != 0.0", .{});
    }
}

pub fn emitEdge(self: *Gen, from: u32, to: u32, depth: u32, target: Mir.Value) Error!void {
    try emitPhiCopies(self, from, to, depth);
    if (self.an.is_loop[to] and self.an.dominates(to, from)) {
        try self.ind(depth);
        try self.b("continue :L{d};\n", .{to});
    } else if (self.an.is_merge[to]) {
        try self.ind(depth);
        try self.b("break :B{d};\n", .{to});
    } else {
        try emitTree(self, to, depth, target);
    }
}

/// SSA-out-of-form on the edge `from → to`. Emitted through temporaries when
/// `to` has more than one live phi, so a phi reading another phi of the same
/// block (the swap idiom) cannot lose a copy.
pub fn emitPhiCopies(self: *Gen, from: u32, to: u32, depth: u32) Error!void {
    const phis = self.an.phi_pool[self.an.phi_off[to]..self.an.phi_off[to + 1]];
    var n: u32 = 0;
    for (phis) |inst| {
        if (slotted(self, inst)) n += 1;
    }
    if (n == 0) return;
    const par = n > 1;
    if (par) {
        try self.ind(depth);
        try self.b("{{\n", .{});
    }
    const d2 = if (par) depth + 1 else depth;
    var k: u32 = 0;
    for (phis) |inst| {
        if (!slotted(self, inst)) continue;
        const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
        // A phi is transparent to `hpPure` because THIS is where its value
        // enters — one incoming copy per edge, each checked as it is written.
        gen_hoist.hpMark(self, self.an.phiIn(inst, from));
        self.oc_insts += 1;
        try self.ind(d2);
        if (par) {
            try self.b("const c{d}: {s} = ", .{ k, gen_unit.zigTy(self.an.vty[i]) });
        } else {
            gen_unit.probeDef(self, self.plan.slot[i], false);
            try gen_unit.writeSlotRef(self, i);
            try self.b(" = ", .{});
        }
        try gen_render.renderVal(self, self.an.phiIn(inst, from), self.an.vty[i]);
        try self.b(";\n", .{});
        k += 1;
    }
    if (!par) return;
    k = 0;
    for (phis) |inst| {
        if (!slotted(self, inst)) continue;
        try self.ind(d2);
        gen_unit.probeDef(self, self.plan.slot[@intFromEnum(self.an.i_res[@intFromEnum(inst)])], false);
        try gen_unit.writeSlotRef(self, @intFromEnum(self.an.i_res[@intFromEnum(inst)]));
        try self.b(" = c{d};\n", .{k});
        k += 1;
    }
    try self.ind(depth);
    try self.b("}}\n", .{});
}

/// A pooled phi this unit actually materializes into a local slot.
pub fn slotted(self: *const Gen, inst: Mir.Inst) bool {
    const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
    return self.plan.needed[i] and self.plan.slot[i] != none_u32;
}
