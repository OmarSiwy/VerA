//! Control-flow reconstruction: MIR's CFG emitted as structured Zig.
//!
//! In: one unit's MIR blocks, dominator tree and slot plan. Out: the unit body
//! as nested labelled blocks, `while (true)` loops, `if`s and out-of-SSA phi
//! copies (the dominator-tree scheme described in `codegen.zig`'s header).
//!
//! LRM clauses this file's code cites: §5.6.1.3.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_cfg.f(self, ...)`; `codegen.zig` aliases only what other modules call.

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

// ---- control-flow reconstruction ------------------------------------------

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
        if (depth == 1) try gen_hoist.hpBoundary(self);
        gen_hoist.hpMarkInst(self, inst);
        self.stmt_count += 1;
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
    if (depth == 1) try gen_hoist.hpBoundary(self);
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
        // `an.term` is the block's branch or jump, found by opcode.
        .unary, .binary, .ternary, .phi, .call => unreachable,
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

/// SSA-out-of-form on the edge `from → to`. Emitted through temporaries only
/// when an incoming value READS a phi of `to` itself (the swap idiom, or a
/// loop counter's `i + 1`): assigned in sequence, a later copy would then see
/// an earlier one's new value. Every other group — 309 of bsim4va's 310 — is
/// written straight into the slots, which is the same values in the same
/// order without a `{ const cK = ..; slot = cK; }` block per edge.
pub fn emitPhiCopies(self: *Gen, from: u32, to: u32, depth: u32) Error!void {
    const phis = self.an.phi_pool[self.an.phi_off[to]..self.an.phi_off[to + 1]];
    var n: u32 = 0;
    var reads_own = false;
    for (phis) |inst| {
        if (!slotted(self, inst)) continue;
        n += 1;
        if (!reads_own) reads_own = readsPhiOf(self, self.an.phiIn(inst, from), to, 0);
    }
    if (n == 0) return;
    const par = n > 1 and reads_own;
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
        self.stmt_count += 1;
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

/// Does rendering `v` read the slot of a phi defined in block `to`? Walks the
/// INLINE tree `renderVal` would print and stops at anything materialized —
/// a slot, a cache field or a precompute field is a name, and only a phi slot
/// of `to` is one the copies on this edge overwrite. Past the depth cap it
/// answers yes, which keeps the temporaries: the safe side.
fn readsPhiOf(self: *Gen, v0: Mir.Value, to: u32, depth: u32) bool {
    if (depth > 64) return true;
    const v = self.an.rv(v0);
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const inst = def.inst_result;
    if (self.mir.instOp(inst) == .phi) return self.an.def_block[@intFromEnum(v)] == to;
    if (gen_render.materialized(self, v)) return false;
    return switch (self.mir.instData(inst)) {
        .unary => |d| readsPhiOf(self, d.operand, to, depth + 1),
        .binary => |d| readsPhiOf(self, d.lhs, to, depth + 1) or readsPhiOf(self, d.rhs, to, depth + 1),
        .ternary => |d| readsPhiOf(self, d.cond, to, depth + 1) or
            readsPhiOf(self, d.then_val, to, depth + 1) or readsPhiOf(self, d.else_val, to, depth + 1),
        .call => |d| for (d.args) |a| {
            if (readsPhiOf(self, a, to, depth + 1)) break true;
        } else false,
        .phi, .branch, .jump => true,
    };
}

/// A pooled phi this unit actually materializes into a local slot.
pub fn slotted(self: *const Gen, inst: Mir.Inst) bool {
    const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
    return self.plan.needed[i] and self.plan.slot[i] != none_u32;
}
