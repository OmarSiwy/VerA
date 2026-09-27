//! Per-unit plan for one emitted declaration: a target `Mir.Value` -> its
//! backward slice over the shared CFG, use counts, inline and dead-branch
//! decisions, and unit-local slots (§4.2.12 lazy arms, §5.9 loops).

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
// Shared with the emitter: `Display` is the §9.4 mode, and the `op*`/`call*`
// helpers classify a call the same way for the plan and for the text. They
// live in `args.zig` so this file imports no emitter.
const cg = @import("args.zig");
const Display = cg.Display;

pub const UnitPlan = @This();

/// How a CFG edge leaves its block, for the emitter's structured reconstruction.
pub const Act = union(enum) { cont: u32, brk: u32 };
/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

arena: std.mem.Allocator,
mir: *const Mir,
an: *const Analysis,
/// §9.4 artifact mode: decides whether a display task's operand is a value
/// the slice must reach.
display: Display,
/// Is the unit being analyzed the §9.4/§9.5 display unit? Set by the emitter
/// before `analyze`, and read only through `dispHere`.
///
/// The artifact mode alone is not enough: a §9.5 call's value is live in the
/// residual (`I(p,n) <+ V(p,n) + code`) while the descriptor operation itself
/// runs only in the display unit, so its operands are a live slice there and
/// dead everywhere else. Marking them everywhere would emit unread locals,
/// which Zig rejects.
display_unit: bool = false,
/// §9.5 values that carry a file call's result, through any operand or phi.
/// Only the display unit performs the call; every other unit reads the result
/// it last produced (`emitFileCallDropped`), which inside one point is the
/// previous point's. So in the display unit such a value is never a cache
/// read: `fd = $fopen(..)` under `@(initial_step)` then `$ftell(fd)` must see
/// the descriptor the open just returned. Empty under `.drop`.
file_dep: []bool = &.{},
/// The shared core's dedup index, from `plan/core.zig`, stable for the whole
/// compilation. A value with an entry is read out of the core rather than
/// recomputed, unless this unit re-runs the loop that defines it.
lo_idx: []const u32 = &.{},
/// The core's live-out values, in `lo_idx` order.
lo_vals: []const Mir.Value = &.{},
/// The setup roots (codegen/setup.zig `planSetup`): value -> its `Instance.su`
/// index, or `none_u32`. A root is a leaf here like a core-cached value:
/// computed outside every body, read as a field, valid in all units
/// including the core.
su_idx: []const u32 = &.{},
/// False while `setup` itself is planned (there the roots are the targets
/// being computed, not leaves) and before `planSetup` wires `su_idx`.
su_on: bool = false,
/// Planning `setup`: only branches on an invariant condition are tested
/// (`sinv`); every other one is taken `then` without reading its condition.
setup_mode: bool = false,
/// Per value: solve-invariant, while planning `setup`.
sinv: []const bool = &.{},
/// While planning `setup`: value -> the block `setup` computes it in when that
/// is not its own (`Sinv.home`).
su_home: []const u32 = &.{},
/// Set by `analyze`: did this unit end up reading the core? Drives the one
/// `const c = <module>__common__core(...)` line the emitter puts at the top.
uses_cache: bool = false,
/// Whether the unit being analyzed is the common declaration itself. Set by
/// `analyze` from its argument.
in_common: bool = false,

/// Per loop header: does this unit run the loop itself, so its values must be
/// recomputed rather than read from the core? Reset and refilled by `analyze`.
loop_recompute: []bool = &.{},
// ---- per-unit scratch ----
// Plain `[]bool` rather than bitsets: every access is a random probe and no
// set operation is ever taken over them.
/// Per value: in this unit's slice.
needed: []bool = &.{},
/// The values `mark` reached for this unit, sorted ascending. Every per-unit
/// sweep iterates this instead of `0..nv`, since a unit touches a small slice.
live: std.ArrayList(Mir.Value) = .empty,
/// Per value: reads in eager positions.
eager_use: []u32 = &.{},
/// Per value: reads in lazy `select` arm positions (§4.2.12).
arm_use: []u32 = &.{},
/// Per value: rendered inside its user instead of getting a slot.
inlined: []bool = &.{},
/// Per value: the longest chain of inlined operands rendering it recurses
/// through. Written by `boundInlineDepth` for the values it visits.
inl_depth: []u16 = &.{},
/// The slice fits in the entry block with no phi (the common case).
straight: bool = false,
/// Blocks this unit defines something in, and blocks it needs a phi of.
/// Per-block, per-unit; `planDeadBranches` is the only reader.
blk_work: []bool = &.{},
blk_phi: []bool = &.{},
/// A `branch` whose two arms are indistinguishable to this unit: it neither
/// defines anything nor copies a phi on either side before they reconverge.
/// The condition is then never marked live, slotted or emitted.
dead_branch: []bool = &.{},
/// Local slot of a needed value, or `none_u32`. Unit-local, never a MIR
/// index: naming.zig's ABSOLUTE RULE says why a MIR index in a name renumbers
/// every downstream declaration.
slot: []u32 = &.{},
/// Number of slots `analyze` assigned.
n_slots: u32 = 0,

/// The §9.4 mode as the unit being analyzed sees it: a task's operands are a
/// live slice only in the one unit that renders the task.
inline fn dispHere(self: *const UnitPlan) Display {
    return if (self.display_unit) self.display else .drop;
}

/// Returns a plan with every per-value and per-block table allocated from
/// `arena` (which owns them) but not yet cleared; `analyze` clears them. Under
/// `.emit` it also computes `file_dep` once for the compilation.
pub fn init(
    arena: std.mem.Allocator,
    mir: *const Mir,
    an: *const Analysis,
    display: Display,
) Error!UnitPlan {
    var self: UnitPlan = .{ .arena = arena, .mir = mir, .an = an, .display = display };
    self.loop_recompute = try arena.alloc(bool, an.nb);
    self.needed = try arena.alloc(bool, an.nv);
    self.eager_use = try arena.alloc(u32, an.nv);
    self.arm_use = try arena.alloc(u32, an.nv);
    self.inlined = try arena.alloc(bool, an.nv);
    self.inl_depth = try arena.alloc(u16, an.nv);
    self.slot = try arena.alloc(u32, an.nv);
    // Per-block tables, cleared by `planDeadBranches` before every read.
    self.blk_work = try arena.alloc(bool, an.nb);
    self.blk_phi = try arena.alloc(bool, an.nb);
    self.dead_branch = try arena.alloc(bool, an.nb);
    if (display == .emit) try self.markFileDeps();
    return self;
}

/// Fill `file_dep`. A fixpoint because a loop phi reads a value defined after
/// it; marking only ever adds, so it converges.
fn markFileDeps(self: *UnitPlan) Error!void {
    self.file_dep = try self.arena.alloc(bool, self.an.nv);
    @memset(self.file_dep, false);
    var grew = true;
    while (grew) {
        grew = false;
        for (Mir.Value.first_dynamic..self.an.nv) |i| {
            if (self.file_dep[i]) continue;
            const def = self.mir.valueDef(@enumFromInt(i));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const hit = switch (self.mir.instData(inst)) {
                .unary => |d| self.fileDep(d.operand),
                .binary => |d| self.fileDep(d.lhs) or self.fileDep(d.rhs),
                .ternary => |d| self.fileDep(d.cond) or self.fileDep(d.then_val) or self.fileDep(d.else_val),
                .call => |d| cg.isFileCall(d.callee) or for (d.args) |a| {
                    if (self.fileDep(a)) break true;
                } else false,
                .phi => |d| blk: {
                    var k: u32 = 0;
                    while (k < d.count) : (k += 1)
                        if (self.fileDep(self.mir.phiPair(inst, k).value)) break :blk true;
                    break :blk false;
                },
                .branch, .jump, .anew => false,
                .load => |d| self.fileDep(d.arr) or self.fileDep(d.index),
                .store => |d| self.fileDep(d.arr) or self.fileDep(d.index) or self.fileDep(d.value),
            };
            if (hit) {
                self.file_dep[i] = true;
                grew = true;
            }
        }
    }
}

inline fn fileDep(self: *const UnitPlan, v: Mir.Value) bool {
    return self.file_dep[@intFromEnum(self.an.rv(v))];
}

/// Is this Value a setup root here? Unlike `cached` it is true inside the
/// common declaration too: `setup` writes the field before any solve, so
/// every body may read it.
pub inline fn isRoot(self: *const UnitPlan, v: Mir.Value) bool {
    if (!self.su_on) return false;
    return self.su_idx[@intFromEnum(v)] != none_u32;
}

/// The block this unit computes `v` in.
fn homeBlock(self: *const UnitPlan, v: usize) u32 {
    if (self.setup_mode and self.su_home[v] != none_u32) return self.su_home[v];
    return self.an.def_block[v];
}

/// A branch the unit being planned actually tests: every one, except while
/// planning `setup`, which takes a per-eval branch `then` untested.
inline fn tested(self: *const UnitPlan, cond: Mir.Value) bool {
    return !self.setup_mode or self.sinv[@intFromEnum(cond)];
}

/// Is this Value read out of the common declaration's cache HERE? False inside
/// the common declaration itself, where it is computed, and false for a value
/// defined inside a loop this unit re-runs.
pub inline fn cached(self: *const UnitPlan, v: Mir.Value) bool {
    if (self.in_common or self.lo_idx[@intFromEnum(v)] == none_u32) return false;
    if (self.display_unit and self.file_dep.len != 0 and self.file_dep[@intFromEnum(v)]) return false;
    // §5.9 A unit that re-materializes a loop must not read that loop's values
    // out of the cache (see `analyze`).
    const blk = self.an.def_block[@intFromEnum(v)];
    if (blk != none_u32) {
        const l = self.an.loop_of[blk];
        if (l != none_u32 and self.loop_recompute[l]) return false;
    }
    return true;
}

/// Plans the unit that computes `target`, or with `in_common` the core's whole
/// live-out set `lo_vals` (then `target` is ignored). Overwrites every
/// per-unit table, including `slot` and `n_slots`.
///
/// A fixpoint: a §5.9 loop the unit must re-run changes the slice, which can
/// mark further loops. Marking only adds, so it converges.
pub fn analyze(self: *UnitPlan, target: Mir.Value, in_common: bool) Error!void {
    self.in_common = in_common;
    @memset(self.loop_recompute, false);
    while (true) {
        try self.analyzeUnitOnce(target);
        if (!self.markRecomputedLoops()) return;
    }
}

/// §5.9 Marks the loops this unit must run itself; returns whether any were
/// newly marked.
///
/// The common declaration runs a loop to completion and publishes one
/// snapshot. A unit with a private value inside that loop re-runs it, and
/// reading its counter and exit condition from the cache (their final values)
/// would run the copy zero times. So such a unit uses only local values of the
/// loop, and every other unit keeps reading the core. Not hoisting loop values
/// at all is also sound, but measured 2-5x larger output on models with loops.
fn markRecomputedLoops(self: *UnitPlan) bool {
    if (self.in_common) return false;
    var grew = false;
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (self.cached(lv) or self.isRoot(lv)) continue; // computed elsewhere
        const blk = self.an.def_block[v];
        if (blk == none_u32) continue;
        const l = self.an.loop_of[blk];
        if (l == none_u32 or self.loop_recompute[l]) continue;
        self.loop_recompute[l] = true;
        grew = true;
    }
    return grew;
}

fn analyzeUnitOnce(self: *UnitPlan, target: Mir.Value) Error!void {
    // A full clear: `analyze` runs a handful of times per compilation (setup,
    // the core, the §9.4 display unit), so there is no partial reset to keep
    // in sync with every new table.
    @memset(self.needed, false);
    @memset(self.eager_use, 0);
    @memset(self.arm_use, 0);
    @memset(self.inlined, false);
    @memset(self.slot, none_u32);
    self.live.clearRetainingCapacity();
    self.n_slots = 0;

    var work: std.ArrayList(Mir.Value) = .empty;
    defer work.deinit(self.arena);
    // The common declaration's targets are its whole live-out set and
    // `target` is ignored, so slicing, use counting and CFG reconstruction
    // are shared.
    if (self.in_common) {
        for (self.lo_vals) |v| try self.mark(&work, v);
    } else {
        try self.mark(&work, target);
    }
    try self.closeSlice(&work);
    // Whether the unit needs the CFG is decided from the target's own slice;
    // only then do branch conditions become live (a condition the unit never
    // branches on would be a local nothing reads, a hard error in Zig).
    self.straight = self.isStraightLine();
    if (!self.straight) {
        // Only the branches this unit can observe: most units hold a few
        // private values scattered through a CFG of hundreds of blocks, and
        // rebuilding all of it emits empty `if (c) { break :B } else
        // { break :B }` scaffolding. Marking is monotone (a newly live
        // condition only adds work to a block, which can only revive a
        // branch), so this converges.
        while (true) {
            self.planDeadBranches();
            var grew = false;
            for (self.an.rpo) |bi| {
                const t = self.an.term[bi];
                if (t == .none) continue;
                if (self.mir.instOp(t) != .branch) continue;
                if (self.dead_branch[bi]) continue;
                const cond = self.an.rv(self.mir.instData(t).branch.cond);
                if (self.needed[@intFromEnum(cond)] or !self.tested(cond)) continue;
                try self.mark(&work, cond);
                grew = true;
            }
            try self.closeSlice(&work);
            if (!grew) break;
        }
    }

    // Ascending value order, so the two sweeps below see exactly the order a
    // full 0..nv scan would. Values are unique ⇒ unstable sort is fine.
    std.mem.sortUnstable(Mir.Value, self.live.items, {}, ltValue);

    // Use counting: a `select` arm (§4.2.12) is a LAZY position.
    self.countUses(target);

    // Descending value order is a topological order for pure ops (a result
    // is always created after its operands), so one sweep suffices.
    var k = self.live.items.len;
    while (k > 0) {
        k -= 1;
        const v = @intFromEnum(self.live.items[k]);
        if (v < Mir.Value.first_dynamic) break; // sentinels sort first
        if (self.eager_use[v] != 0 or self.arm_use[v] == 0) continue;
        // Read at more than one arm position: a slot, computed once where it
        // is defined, rather than re-rendering its whole slice at every arm.
        // Eager is sound here: proof.markSelectArms guards only a slice owned
        // through use-count-1 links, so a value with two uses (and whatever it
        // alone reads) was proved on every path. And ifconv keeps an arm
        // holding a domain-restricted op as a CFG diamond, so no
        // ln/sqrt/pow/integer `/` reaches here from under a guard (§4.2.12).
        // One arm position stays inlined: laziness that costs nothing.
        if (self.arm_use[v] > 1) continue;
        // A live-out is a FIELD of the returned cache, so it has to exist as
        // a value; inlining it into its uses would render its expression at
        // every one of them, including the `return`.
        if (self.in_common and self.lo_idx[v] != none_u32) continue;
        const def = self.mir.valueDef(@as(Mir.Value, @enumFromInt(v)));
        if (def != .inst_result) continue;
        const op = self.mir.instOp(def.inst_result);
        // A `call` is never inlined: §4.5 operators and ch9 functions are
        // evaluated once per step regardless of which arm is taken. Nor is
        // §3.2.2 array storage: a load must run where it stands, before any
        // later store to the same storage (`Mir.Opcode.store`).
        if (op == .call or op == .phi) continue;
        switch (Mir.opClass(op)) {
            .anew, .load, .store => continue,
            .unary, .binary, .ternary, .phi, .branch, .jump, .call => {},
        }
        self.inlined[v] = true;
        // ponytail: addUses already moves eager operands into lazy-arm counts.
        self.addUses(def.inst_result, true);
    }

    self.fuseSingleUse();
    self.boundInlineDepth();

    // Slots for everything that survives as a statement, in ascending value
    // order: a unit-local dense index, never a MIR value index.
    self.uses_cache = false;
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic or self.inlined[v]) continue;
        // An Instance-field read needs no statement, slot or core call; it
        // is valid in every body including the core itself.
        if (self.isRoot(lv)) continue;
        // A cache read is a field access valid anywhere in the body, so it
        // needs no statement and no slot. This is what lets most units come
        // out straight-line.
        if (self.cached(lv)) {
            self.uses_cache = true;
            continue;
        }
        // §3.2.2 an array version is its storage, not a value: `anew` and
        // `store` are statements without a slot, and an array phi is the
        // same storage on every edge.
        if (self.an.arrOf(lv) != null) continue;
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        // §4.5 an operator's input is not a marked operand (`callArgIsValue`
        // says no, so the §4.5.2 one-evaluation-per-step rule holds), but
        // `emitOperator` still renders it, and outside the core that is a
        // cache read. Without this the §9.4 display unit, the one unit not
        // folded into the core, emits `c.f1` with no `c`.
        const d = self.mir.instData(def.inst_result);
        if (d == .call and cg.opNeedsInput(Mir.callee.opKind(d.call.callee)) and d.call.args.len != 0 and
            self.cached(self.an.rv(d.call.args[0]))) self.uses_cache = true;
        // §4.6.3 the same for `ac_stim`'s magnitude and phase (A.8.2
        // `analog_expression`s that `emitCall` renders through `ctrlEval`).
        // `callArgIsValue` says no because the usual constant spelling is
        // consumed at codegen time; a solve-computed one is a core live-out,
        // so outside the core it is a cache read. Argument 0 is the analysis
        // name and is never rendered.
        if (d == .call and d.call.callee == .ac_stim) {
            for (d.call.args, 0..) |a, ai| {
                if (ai != 0 and self.cached(self.an.rv(a))) self.uses_cache = true;
            }
        }
        self.slot[v] = self.n_slots;
        self.n_slots += 1;
    }
}

fn mark(self: *UnitPlan, work: *std.ArrayList(Mir.Value), v0: Mir.Value) Error!void {
    const v = self.an.rv(v0);
    if (self.needed[@intFromEnum(v)]) return;
    self.needed[@intFromEnum(v)] = true;
    try self.live.append(self.arena, v);
    // A value read from the core's cache or from a setup root's Instance
    // field is a leaf here: its operands were computed there, and pulling
    // them in is the duplication the hoist removes.
    if (self.cached(v) or self.isRoot(v)) return;
    try work.append(self.arena, v);
}

fn markOperands(self: *UnitPlan, work: *std.ArrayList(Mir.Value), inst: Mir.Inst) Error!void {
    switch (self.mir.instData(inst)) {
        .unary => |d| try self.mark(work, d.operand),
        .binary => |d| {
            try self.mark(work, d.lhs);
            if (!self.foldedExponent(d)) try self.mark(work, d.rhs);
        },
        .ternary => |d| {
            try self.mark(work, d.cond);
            try self.mark(work, d.then_val);
            try self.mark(work, d.else_val);
        },
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere())) try self.mark(work, a);
        },
        .phi => |d| {
            var i: u32 = 0;
            while (i < d.count) : (i += 1) try self.mark(work, self.mir.phiPair(inst, i).value);
        },
        .branch => |d| try self.mark(work, d.cond),
        .jump, .anew => {},
        .load => |d| {
            try self.mark(work, d.arr);
            try self.mark(work, d.index);
        },
        .store => |d| {
            try self.mark(work, d.arr);
            try self.mark(work, d.index);
            try self.mark(work, d.value);
        },
    }
}

fn closeSlice(self: *UnitPlan, work: *std.ArrayList(Mir.Value)) Error!void {
    while (work.pop()) |v| {
        const def = self.mir.valueDef(v);
        if (def != .inst_result) continue;
        try self.markOperands(work, def.inst_result);
    }
}

fn ltValue(_: void, lhs: Mir.Value, rhs: Mir.Value) bool {
    return @intFromEnum(lhs) < @intFromEnum(rhs);
}

fn countUses(self: *UnitPlan, target: Mir.Value) void {
    if (self.in_common) {
        for (self.lo_vals) |v| self.eager_use[@intFromEnum(v)] += 1;
    } else {
        self.eager_use[@intFromEnum(self.an.rv(target))] += 1;
    }
    for (self.live.items) |lv| {
        // A leaf: its operands are not here.
        if (self.cached(lv) or self.isRoot(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        self.addUses(def.inst_result, false);
    }
    if (self.straight) return;
    for (self.an.rpo) |bi| {
        const t = self.an.term[bi];
        if (t == .none) continue;
        if (self.mir.instOp(t) != .branch) continue;
        // A dead branch emits no `if`, so its condition has no use here. It
        // must not be counted, or the value would be slotted and assigned
        // with nothing reading it, which Zig rejects.
        if (self.dead_branch[bi]) continue;
        const cond = self.an.rv(self.mir.instData(t).branch.cond);
        if (!self.tested(cond)) continue;
        self.eager_use[@intFromEnum(cond)] += 1;
    }
}

/// `undo = false` counts, `undo = true` moves this instruction's eager uses
/// into arm uses (called when the instruction itself became lazy).
fn addUses(self: *UnitPlan, inst: Mir.Inst, undo: bool) void {
    const bump = struct {
        fn f(g: *UnitPlan, v: Mir.Value, arm: bool, un: bool) void {
            const i = @intFromEnum(g.an.rv(v));
            if (!g.needed[i]) return;
            if (un) {
                if (arm) return; // already an arm use
                if (g.eager_use[i] > 0) g.eager_use[i] -= 1;
                g.arm_use[i] += 1;
            } else if (arm) {
                g.arm_use[i] += 1;
            } else {
                g.eager_use[i] += 1;
            }
        }
    }.f;
    switch (self.mir.instData(inst)) {
        .unary => |d| bump(self, d.operand, false, undo),
        .binary => |d| {
            bump(self, d.lhs, false, undo);
            if (!self.foldedExponent(d)) bump(self, d.rhs, false, undo);
        },
        .ternary => |d| {
            bump(self, d.cond, false, undo);
            bump(self, d.then_val, true, undo);
            bump(self, d.else_val, true, undo);
        },
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere())) bump(self, a, false, undo);
        },
        .phi => |d| {
            var i: u32 = 0;
            while (i < d.count) : (i += 1) bump(self, self.mir.phiPair(inst, i).value, false, undo);
        },
        .branch, .jump, .anew => {},
        .load => |d| {
            bump(self, d.arr, false, undo);
            bump(self, d.index, false, undo);
        },
        .store => |d| {
            bump(self, d.arr, false, undo);
            bump(self, d.index, false, undo);
            bump(self, d.value, false, undo);
        },
    }
}

/// The deepest chain of inlined operands one statement may render.
const max_inline_depth = 256;

/// The renderer recurses once per inlined operand, so a fused chain as long
/// as the source (4096 summed contributions) overflows the compiler's stack.
/// Past `max_inline_depth` a FUSED value keeps its own statement, which is
/// where it stood before `fuseSingleUse` moved it. An arm-inlined value stays
/// inlined: it is lazy on purpose (§4.2.12).
fn boundInlineDepth(self: *UnitPlan) void {
    // Ascending value order is a topological order for everything that
    // inlines (operands are created before their results; a phi never
    // inlines), so every inlined operand's depth is already written.
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic or !self.inlined[v]) continue;
        const ops: [3]Mir.Value = switch (self.mir.instData(self.mir.valueDef(lv).inst_result)) {
            .unary => |d| .{ d.operand, .undef, .undef },
            .binary => |d| .{ d.lhs, d.rhs, .undef },
            .ternary => |d| .{ d.cond, d.then_val, d.else_val },
            .load => |d| .{ d.arr, d.index, .undef },
            // A storage version renders as its array's name.
            .call, .phi, .branch, .jump, .anew, .store => @splat(.undef),
        };
        var d: u16 = 1;
        for (ops) |o0| {
            const o = @intFromEnum(self.an.rv(o0));
            if (o >= Mir.Value.first_dynamic and self.inlined[o]) d = @max(d, self.inl_depth[o] + 1);
        }
        if (d > max_inline_depth and self.eager_use[v] != 0) {
            self.inlined[v] = false;
            d = 0;
        }
        self.inl_depth[v] = d;
    }
}

/// Fuses a value read exactly once, by a later statement of its own block,
/// into that statement instead of giving it a `const`. Clearing the slot is
/// the fusion: `renderValueRef` falls through to `renderInst` for anything
/// without a slot, so chains collapse transitively.
///
/// Sound because the use is single (`eager_use == 1 and arm_use == 0`; an arm
/// use is re-rendered per arm) and only pure statements lie between, so
/// nothing moves into a loop or past a side effect. Eager uses are not undone:
/// the expression still runs once, eagerly, a little later.
fn fuseSingleUse(self: *UnitPlan) void {
    for (0..self.an.nb) |bi| {
        const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
        if (stmts.len < 2) continue;
        for (stmts[0 .. stmts.len - 1], 0..) |inst, si| {
            const v = @intFromEnum(self.an.rv(self.an.i_res[@intFromEnum(inst)]));
            if (v < Mir.Value.first_dynamic) continue;
            if (!self.needed[v] or self.inlined[v]) continue;
            if (self.eager_use[v] != 1 or self.arm_use[v] != 0) continue;
            // A live-out is a FIELD of the returned cache (same reason as
            // the sweep above), and a cached value renders as `c.fN`
            // wherever it appears, so neither is ours to fuse.
            if (self.in_common and self.lo_idx[v] != none_u32) continue;
            if (self.cached(@enumFromInt(v))) continue;
            const op = self.mir.instOp(inst);
            // `call` is an operator/function evaluated once per step (§4.5)
            // and `phi` is materialised as a `var`; neither is an expression.
            if (op == .call or op == .phi) continue;
            // §3.2.2 a load may move later only past what cannot store.
            const is_load = Mir.opClass(op) == .load;
            // The user may sit further down the same block as long as every
            // statement in between is pure: a pure op reads only SSA values,
            // so sliding another past it changes nothing. A `call` or `phi`
            // stops the scan, because §4.5 operators and §9.4 prints are side
            // effects the value must not cross. This lets ifconv's spliced
            // arms sit between a comparison and the select that consumes it.
            for (stmts[si + 1 ..]) |next| {
                if (self.eagerlyUses(next, @enumFromInt(v))) {
                    self.inlined[v] = true;
                    break;
                }
                const nop = self.mir.instOp(next);
                if (nop == .call or nop == .phi) break;
                switch (Mir.opClass(nop)) {
                    .unary, .binary, .ternary, .load => {},
                    // A pure op reads no storage, so it slides past a store;
                    // a load does not.
                    .anew, .store => if (is_load) break,
                    .phi, .branch, .jump, .call => break,
                }
            }
        }
    }
}

/// Does `inst` read `v` in an eager position? Mirrors `addUses`, including
/// its two exclusions (a folded constant exponent is never materialised, and
/// a non-value call argument is not an operand), so the counts it is checked
/// against cannot drift from this answer. A `ternary`'s arms are lazy
/// positions, counted in `arm_use`.
fn eagerlyUses(self: *const UnitPlan, inst: Mir.Inst, v: Mir.Value) bool {
    return switch (self.mir.instData(inst)) {
        .unary => |d| self.an.rv(d.operand) == v,
        .binary => |d| self.an.rv(d.lhs) == v or
            (!self.foldedExponent(d) and self.an.rv(d.rhs) == v),
        .ternary => |d| self.an.rv(d.cond) == v,
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere()) and self.an.rv(a) == v) break true;
        } else false,
        .phi, .branch, .jump, .anew => false,
        .load => |d| self.an.rv(d.index) == v,
        .store => |d| self.an.rv(d.index) == v or self.an.rv(d.value) == v,
    };
}

/// §4.3.1 `pow(x, k)` with a constant exponent goes through the scalar's
/// `pow(S, f64)`, so the exponent is never materialised as a value.
///
/// `resolve_params = false` mirrors `Gen.renderOp`'s `.pow` arm: a parameter
/// exponent belongs to the model card, so it stays live and renders as
/// `S.con(model.<p>)`. Folding through its declared default would freeze an
/// overridden exponent at that default.
fn foldedExponent(self: *const UnitPlan, d: anytype) bool {
    return d.op == .pow and self.an.foldConst(d.rhs, false) != null;
}

/// Returns true when the slice lives entirely in the entry block and uses no
/// phi, so the unit emits flat `const` code. Valid after `analyze` marked the
/// slice.
pub fn isStraightLine(self: *const UnitPlan) bool {
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic) continue;
        // A cache or Instance-field read is a field of a value the body
        // already holds, so it has no block of its own.
        if (self.cached(lv) or self.isRoot(lv)) continue;
        const db = self.homeBlock(v);
        if (db != none_u32 and db != 0) return false;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .phi) return false;
    }
    return true;
}

/// Marks in `dead_branch` every `branch` this unit cannot tell apart.
///
/// A branch is dead here when both edges reduce to the same control action
/// once the empty blocks between are skipped, and neither copies a phi on the
/// way. The unit then computes the same values and reaches the same place
/// whichever arm runs, so the condition is unobservable and the `if` goes.
pub fn planDeadBranches(self: *UnitPlan) void {
    @memset(self.blk_work, false);
    @memset(self.blk_phi, false);
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic) continue;
        const db = self.homeBlock(v);
        if (db == none_u32) continue;
        // A phi marks its block even when cached: `blk_phi` means "the two
        // arms disagree at this SSA join", a property of the CFG and the
        // value, not of whether this unit reads the result from the cache.
        // A setup root's value is the same whichever way the unit goes
        // (`setup` decided every branch it depends on), so neither its phi
        // copies nor its block are work here.
        if (self.isRoot(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.an.i_op[@intFromEnum(def.inst_result)] == .phi)
            self.blk_phi[db] = true;
        // A cache read has no block of its own.
        if (self.cached(lv)) continue;
        self.blk_work[db] = true;
    }
    @memset(self.dead_branch, false);
    // Innermost first (reverse RPO), so an arm whose only content is a branch
    // already found dead reads as the jump it will be emitted as (`edgeAct`).
    var k = self.an.rpo.len;
    while (k > 0) {
        k -= 1;
        const bi = self.an.rpo[k];
        const t = self.an.term[bi];
        if (t == .none or self.mir.instOp(t) != .branch) continue;
        const d = self.mir.instData(t).branch;
        const a = self.edgeAct(bi, @intFromEnum(d.then_block)) orelse continue;
        const b2 = self.edgeAct(bi, @intFromEnum(d.else_block)) orelse continue;
        if (std.meta.eql(a, b2)) self.dead_branch[bi] = true;
    }
}

/// Returns the control action the edge `from0 -> to0` reduces to once empty
/// inline blocks are skipped, or null when the edge copies a phi, does work
/// this unit observes, or nests deeper than the walk tracks. Reads
/// `blk_work`/`blk_phi`/`dead_branch`, so it is valid only inside
/// `planDeadBranches` or after it.
pub fn edgeAct(self: *const UnitPlan, from0: u32, to0: u32) ?Act {
    var from = from0;
    var to = to0;
    var hops: u32 = 0;
    // Merge blocks whose labels a block walked through here opened: the walk
    // reaching one continues into it, because it is emitted INLINE right
    // after its label closes (`emitCode`), not broken to from outside.
    // ponytail: a fixed 32; a deeper nest answers null, the safe side.
    var opened: [32]u32 = undefined;
    var n_open: usize = 0;
    while (hops <= self.an.nb) : (hops += 1) {
        // A phi in `to` means `emitEdge` copies a value on this edge, which
        // is the one thing the two arms cannot share.
        if (self.blk_phi[to]) return null;
        if (self.an.is_loop[to] and self.an.dominates(to, from)) return .{ .cont = to };
        if (self.an.is_merge[to] and std.mem.indexOfScalar(u32, opened[0..n_open], to) == null) return .{ .brk = to };
        // Otherwise `to` is emitted INLINE here, so it has to be empty and
        // end in a plain jump for the two arms to stay indistinguishable.
        //
        // §5.9 and NOT inside a loop, even when empty. "Empty of values
        // this unit computes" is not "no effect" on a back edge: the arms
        // decide which loop-carried phi values get copied on the way round,
        // and `blk_phi` only guards a phi's own block. A loop-carried phi the
        // unit reads from the cache leaves it clear, so the two arms are not
        // interchangeable (the hazard `markRecomputedLoops` handles).
        if (self.an.is_loop[to] or self.an.inLoop(to) or self.blk_work[to]) return null;
        const labels = self.an.mk_pool[self.an.mk_off[to]..self.an.mk_off[to + 1]];
        if (n_open + labels.len > opened.len) return null;
        @memcpy(opened[n_open..][0..labels.len], labels);
        n_open += labels.len;
        const t = self.an.term[to];
        if (t == .none) return null;
        from = to;
        // A dead branch emits as the edge to its `then` block (`emitTerm`).
        to = switch (self.mir.instOp(t)) {
            .jump => @intFromEnum(self.mir.instData(t).jump.target),
            .branch => if (self.dead_branch[to]) @intFromEnum(self.mir.instData(t).branch.then_block) else return null,
            else => return null, // else: a terminator is a jump or a branch; anything else ends the walk
        };
    }
    return null;
}

const Fixture = @import("fixture.zig").Fixture;

test "a unit's slice stops at a value the core carries" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const sq = try f.mir.emit(a, .entry, .fmul, &.{ va, va }); // V(a)^2
    const two = try f.mir.addFloatConst(a, 2.0);
    const t = try f.mir.emit(a, .entry, .fadd, &.{ sq, two }); // V(a)^2 + 2
    const an = try f.analysis();

    // `prepare` always wires the core's index; here the core carries nothing.
    const lo_idx = try a.alloc(u32, an.nv);
    @memset(lo_idx, none_u32);
    var p = try UnitPlan.init(a, &f.mir, &an, .drop);
    p.lo_idx = lo_idx;
    try p.analyze(t, false);
    try std.testing.expect(p.straight);
    try std.testing.expect(p.needed[@intFromEnum(sq)] and p.needed[@intFromEnum(va)]);
    try std.testing.expect(!p.uses_cache);

    // Now the core returns `sq`: the unit reads it as a leaf, so `V(a)` is
    // no longer part of its slice.
    lo_idx[@intFromEnum(sq)] = 0;
    p.lo_vals = &.{sq};
    try p.analyze(t, false);
    try std.testing.expect(p.cached(sq) and p.uses_cache);
    try std.testing.expect(p.needed[@intFromEnum(sq)] and !p.needed[@intFromEnum(va)]);
}
