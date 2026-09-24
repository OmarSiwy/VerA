//! Per-unit state for one emitted declaration: what this unit has to compute,
//! how many times each value is read, what gets inlined, and which local slot
//! each surviving value lands in.
//!
//! Transformation (per unit): a target `Mir.Value` → a backward slice over the
//! shared CFG, use counts, inline decisions, dead-branch marks and slot
//! assignments.
//!
//! NOT purely a plan, and the name is generous on purpose. `analyze` computes
//! the slice and the counts up front, but `slot`/`n_slots` are filled by the
//! EMITTER as it walks (`emitUnitBody`, and `probeBody`'s dry run of it) —
//! placement depends on the order the text comes out in.
//!
//! ## CORPUS — where every measured number in this file comes from
//!
//! `hisimhv_va` (HiSIM_HV) and `bsimsoi_va` (the public Berkeley BSIM-SOI) are
//! two of the 38 foundry models in the ARPice host repo, at
//! `../ARPice/src/devices/models` — `VERA_MODELS` overrode that path for the
//! `baseline.sh` oracle these were taken with. NONE is vendored here, and no
//! fixture is remotely their shape. So every ratio below is real and none of
//! it is reproducible from this tree alone: check the models out before you
//! re-measure, and do not re-derive a replacement from a fixture.
//!
//! ## RESET IS FULL
//!
//! `analyze` clears every per-value table with one `@memset` each. It used to
//! clear only the cells the PREVIOUS unit's `live` set named, which made every
//! field added here a "MUST be cleared in the same loop" hazard with no test
//! behind it. That scheme paid for itself when ~105 units each called
//! `analyze`; since the core merge a compilation calls it at most a handful of
//! times (precompute, the core, the §9.4 display unit), so a full clear costs
//! a few × nv × 14 bytes of stores and the hazard is gone.
//!
//! ## THE SIDE TABLES STAY `[]bool` — MEASURED; do not pack them into a bitset
//!
//! Same run, sampling `nb`/`nv` at every `analyzeUnitOnce`:
//!
//!     nb (blocks) median 1   mean 3.0   p99 25    max 103
//!     nv (values) median 38  mean 49.5  p99 213   max 929
//!
//! `loop_recompute`, `blk_work`, `blk_phi` and `dead_branch` are therefore ONE
//! BYTE long in the median compilation and 103 bytes at the largest fixture in
//! the tree. `needed` and `inlined` are 38 bytes and 929 bytes. Every read of
//! all six is a random probe by block or value index; the only whole-array
//! operations are the `@memset(.., false)` clears, and there is no set union or
//! intersection over any of them — which is the one thing a bitset does for
//! free. Converting them buys 87 bytes at the worst block table and charges a
//! shift and a mask on every probe in the emitter's hottest walk.
//!
//! A bitset would not have made the old partial reset unnecessary either:
//! three of the five per-value tables (`eager_use`, `arm_use`, `slot`) are
//! `[]u32`, so a full clear costs the same no matter how `needed` and
//! `inlined` are stored.
//!
//! Where a whole-array clear IS the cost, the tool is a generation stamp, not a
//! bitset — `proof.verdict` already does this: `seen[i] == u` reuses the slice
//! index as the stamp and clears the array once instead of once per
//! contribution. That works on `[]u32` too, which a bitset does not.
//!
//! ## `analyze` IS A FIXPOINT, NOT A PASS
//!
//! `markRecomputedLoops` can discover that a §5.9 loop this unit re-runs owns
//! values it must recompute rather than read from the core. That changes the
//! slice, which can mark further loops. Marking only ever ADDS, so it is monotone
//! and converges — in practice after one extra round.
//!
//! ## `in_common` IS AN ARGUMENT, NOT A FIELD
//!
//! It used to be `Gen.emitting_common`, read from four places in here — analysis
//! silently depending on which emission phase the caller was in. It is now a
//! parameter of `analyze`, so the dependency is in the signature.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
// The emitter owns these: `Display` is its §9.4 mode, and the two `op*`/`call*`
// helpers classify a call the same way for the plan and for the text. Mutual
// import with codegen.zig is fine here — nothing in the cycle is a comptime
// dependency of the other's types.
const cg = @import("codegen.zig");
const Display = cg.Display;

pub const UnitPlan = @This();

/// How a CFG edge leaves its block, for the emitter's structured reconstruction.
pub const Act = union(enum) { cont: u32, brk: u32 };
pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

arena: std.mem.Allocator,
mir: *const Mir,
an: *const Analysis,
/// §9.4 — `addUses`/`markOperands` need it to know whether a display task's
/// operand is a value the slice must reach.
display: Display,
/// Is the unit being analyzed the §9.4/§9.5 display unit? Set by the emitter
/// before `analyze`, and read only through `dispHere`.
///
/// The artifact mode above is not enough on its own: a §9.5 call's VALUE is live
/// in the residual (`I(p,n) <+ V(p,n) + code`) while the descriptor operation
/// itself may only happen in the display unit, so its operands are a live slice
/// there and dead everywhere else. Marking them everywhere emitted locals the
/// residual's rendering never reads, which Zig rejects outright.
display_unit: bool = false,
/// §9.5 values that carry a file call's RESULT, through any operand or phi.
/// Only the display unit performs the call; every other unit reads the result
/// the display unit last produced (`emitFileCallDropped`), which inside one
/// point is the PREVIOUS point's. So in the display unit such a value is never
/// a cache read: `fd = $fopen(..)` under `@(initial_step)` then `$ftell(fd)`
/// has to see the descriptor the open just returned, not the core's copy of
/// it. Empty under `.drop`, where no unit performs a file call at all.
file_dep: []bool = &.{},
/// The shared core's dedup index, from `plan/core.zig`. Stable for the whole
/// compilation; a value with an entry here is read out of the core rather than
/// recomputed, unless this unit re-runs the loop that defines it.
lo_idx: []const u32 = &.{},
lo_vals: []const Mir.Value = &.{},
/// Temperature/parameter-only hoist (codegen `planPrecompute`): value → the
/// `Instance.pc__<k>` field `precompute` writes, or `none_u32`. A mapped value
/// is a LEAF here exactly like a core-cached one — computed outside every
/// body, read as a field — valid in ALL units including the core.
pc_idx: []const u32 = &.{},
/// False only while the precompute body itself is planned (there the mapped
/// values are the targets being computed, not leaves) and before `prepare`
/// wires `pc_idx`.
pc_on: bool = false,
/// Skip the branch-condition marking and the §5.9 loop fixpoint: the
/// precompute body is emitted FLAT (pure ops in value order, no CFG), so a
/// condition would be a slotted local nothing reads.
flat: bool = false,
/// Set by `analyze`: did this unit end up reading the core? Drives the one
/// `const c = <module>__common__core(...)` line the emitter puts at the top.
uses_cache: bool = false,
/// Which emission phase the caller is in — see the header. Set by `analyze`.
in_common: bool = false,

/// PER UNIT, indexed by loop header: does the unit being analyzed run this
/// loop itself, so its values must be recomputed rather than read from the
/// core? Reset and refilled by `analyzeUnit`.
loop_recompute: []bool = &.{},
// ---- per-unit scratch ----
needed: []bool = &.{},
/// The values `mark` reached for this unit, sorted ascending. Everything
/// per-unit iterates this instead of `0..nv` — a unit touches a small slice
/// of a 600 K-line model's values, and there are hundreds of units.
live: std.ArrayList(Mir.Value) = .empty,
eager_use: []u32 = &.{},
arm_use: []u32 = &.{},
inlined: []bool = &.{},
/// The slice fits in the entry block with no phi (the common case).
straight: bool = false,
/// Blocks this unit defines something in, and blocks it needs a phi of.
/// Per-block, per-unit; `planDeadBranches` is the only reader.
blk_work: []bool = &.{},
blk_phi: []bool = &.{},
/// A `branch` whose two arms are indistinguishable to THIS unit: it neither
/// defines anything nor copies a phi on either side before they reconverge.
/// The condition is then never marked live, never slotted and never
/// emitted — see `planDeadBranches`.
dead_branch: []bool = &.{},
/// Local slot of a needed value, or `none_u32`. UNIT-LOCAL — never a MIR
/// index; naming.zig's ABSOLUTE RULE says why a MIR index in a name renumbers
/// every downstream declaration.
slot: []u32 = &.{},
n_slots: u32 = 0,

/// The §9.4 mode as the unit being analyzed sees it: a task's operands are a
/// live slice only in the one unit that renders the task.
inline fn dispHere(self: *const UnitPlan) Display {
    return if (self.display_unit) self.display else .drop;
}

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
    self.slot = try arena.alloc(u32, an.nv);
    // Cleared by `analyzeUnitOnce`, which every read is behind.
    // Per-BLOCK, not per-value: a whole `@memset` of these per unit is a few KB,
    // nothing like the `0..nv` per-unit sweeps that were deleted.
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
                .branch, .jump => false,
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

/// Is this Value a `precompute`d Instance field HERE? Unlike `cached` it is
/// true inside the common declaration too — the field is written before any
/// solve, so every body may read it.
pub inline fn pcHoisted(self: *const UnitPlan, v: Mir.Value) bool {
    if (!self.pc_on) return false;
    return self.pc_idx[@intFromEnum(v)] != none_u32;
}

/// Is this Value read out of the common declaration's cache HERE? False inside
/// the common declaration itself, where it is computed, and false for a value
/// defined inside a loop this unit re-runs.
pub inline fn cached(self: *const UnitPlan, v: Mir.Value) bool {
    if (self.in_common or self.lo_idx[@intFromEnum(v)] == none_u32) return false;
    if (self.display_unit and self.file_dep.len != 0 and self.file_dep[@intFromEnum(v)]) return false;
    // §5.9 A unit that re-materializes a loop must not read that loop's values
    // out of the cache — see `analyze`'s fixpoint.
    const blk = self.an.def_block[@intFromEnum(v)];
    if (blk != none_u32) {
        const l = self.an.loop_of[blk];
        if (l != none_u32 and self.loop_recompute[l]) return false;
    }
    return true;
}

pub fn analyze(self: *UnitPlan, target: Mir.Value, in_common: bool) Error!void {
    self.in_common = in_common;
    @memset(self.loop_recompute, false);
    while (true) {
        try self.analyzeUnitOnce(target);
        if (self.flat or !self.markRecomputedLoops()) return;
    }
}

/// §5.9 Which loops must this unit run for itself?
///
/// The common declaration runs a loop to completion and publishes ONE
/// snapshot of it. A unit with a private value inside the same loop
/// re-materializes the loop around that snapshot — and then reads its
/// counter and its exit condition from a cache already holding their FINAL
/// values, so the copy runs zero times. (`102_loops` printed
/// `for sums 1..5 got=0 want=15`.)
///
/// The fix is per UNIT, not per model: a unit that runs a loop locally uses
/// only local values of it, and every other unit keeps reading the core.
/// Refusing to hoist loop values at all is sound too and costs 2-5x the
/// generated output on the models that have loops (hisimhv_va: 17 MB → 78 MB;
/// CORPUS in the header — no fixture in this tree has that shape).
///
/// Monotone — marking a loop only ADDS private values, which can only mark
/// more loops — so the fixpoint converges; in practice after one extra round.
fn markRecomputedLoops(self: *UnitPlan) bool {
    if (self.in_common) return false;
    var grew = false;
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (self.cached(lv) or self.pcHoisted(lv)) continue; // computed elsewhere
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
    @memset(self.needed, false);
    @memset(self.eager_use, 0);
    @memset(self.arm_use, 0);
    @memset(self.inlined, false);
    @memset(self.slot, none_u32);
    self.live.clearRetainingCapacity();
    self.n_slots = 0;

    var work: std.ArrayList(Mir.Value) = .empty;
    defer work.deinit(self.arena);
    // The common declaration has many targets — its whole live-out set —
    // and `target` is ignored. One entry point, so the slicing, the use
    // counting and the CFG reconstruction below are shared verbatim.
    if (self.in_common) {
        for (self.lo_vals) |v| try self.mark(&work, v);
    } else {
        try self.mark(&work, target);
    }
    try self.closeSlice(&work);
    // Whether the unit needs the CFG at all is decided from the target's
    // own slice; only then do the branch conditions become live (emitting a
    // condition the unit never branches on would declare a local nothing
    // reads — a hard error in Zig).
    self.straight = self.isStraightLine();
    if (!self.straight and !self.flat) {
        // Only the branches this unit can OBSERVE. Hoisting the shared core
        // leaves most units with a handful of private values scattered
        // through a CFG of hundreds of blocks, and reconstructing all of it
        // was, measured on `bsimsoi_va`, 754 of the 5 431 lines of every
        // unit being `if (c) { break :B } else { break :B }` (CORPUS: the
        // public Berkeley BSIM-SOI release — see this file's CORPUS header).
        //
        // Marking is monotone — a newly live condition can only ADD work to
        // a block, which can only revive a branch — so this converges, and
        // in practice after two rounds.
        while (true) {
            self.planDeadBranches();
            var grew = false;
            for (self.an.rpo) |bi| {
                const t = self.an.term[bi];
                if (t == .none) continue;
                if (self.mir.instOp(t) != .branch) continue;
                if (self.dead_branch[bi]) continue;
                const cond = self.an.rv(self.mir.instData(t).branch.cond);
                if (self.needed[@intFromEnum(cond)]) continue;
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
        // Read at MORE than one arm position: a slot, computed once where it
        // is defined. Inlined, its whole backward slice was re-rendered at
        // every use, in every select sharing it — including values the source
        // computed before the `if`, whose only readers happen to be arms.
        // Eager is sound here: proof.markSelectArms guards only a slice owned
        // through use-count-1 links, so a value with two uses — and whatever
        // it alone reads — was proved on EVERY path, guard or not. And ifconv
        // keeps an arm holding a domain-restricted op as a CFG diamond, so no
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
        // evaluated once per step regardless of which arm is taken.
        if (op == .call or op == .phi) continue;
        self.inlined[v] = true;
        // ponytail: addUses already moves eager operands into lazy-arm counts.
        self.addUses(def.inst_result, true);
    }

    self.fuseSingleUse();

    // Slots for everything that survives as a statement, in ascending value
    // order — a UNIT-LOCAL dense index, never a MIR value index.
    self.uses_cache = false;
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic or self.inlined[v]) continue;
        // An Instance-field read needs no statement, no slot, and no core
        // call — it is valid in every body including the core itself.
        if (self.pcHoisted(lv)) continue;
        // A cache read is a field access, as cheap as a parameter read, and
        // it is valid anywhere in the body — it needs no statement and no
        // slot. This is also what lets most units come out straight-line.
        if (self.cached(lv)) {
            self.uses_cache = true;
            continue;
        }
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        // §4.5 an operator's INPUT is not a `mark`ed operand — `callArgIsValue`
        // deliberately says no, so the §4.5.2 one-evaluation-per-step rule
        // holds — but `emitOperator` still renders it, and outside the core
        // that rendering is a cache read. Without this the §9.4 display unit
        // (the one unit not folded into the core) emits `c.f1` with no `c`.
        const d = self.mir.instData(def.inst_result);
        if (d == .call and cg.opNeedsInput(Mir.callee.opKind(d.call.callee)) and d.call.args.len != 0 and
            self.cached(self.an.rv(d.call.args[0]))) self.uses_cache = true;
        // §4.6.3 the same hole, for `ac_stim`'s magnitude and phase. A.8.2
        // gives both as `analog_expression` and `emitCall` renders them
        // through `ctrlEval`; `callArgIsValue` still says no, because the
        // constant spelling every model writes is consumed at codegen time.
        // A solve-computed one is a core live-out, so outside the core it is
        // a cache read this loop would otherwise never see. Argument 0 is the
        // analysis NAME and is never rendered.
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
    // A value read out of the common declaration's cache — or out of a
    // `precompute`d Instance field — is a LEAF here: its operands were
    // computed there, and pulling them in is exactly the duplication the
    // hoist removes.
    if (self.cached(v) or self.pcHoisted(v)) return;
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
        .jump => {},
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
        if (self.cached(lv) or self.pcHoisted(lv)) continue;
        const def = self.mir.valueDef(lv);
        if (def != .inst_result) continue;
        self.addUses(def.inst_result, false);
    }
    if (self.straight or self.flat) return;
    for (self.an.rpo) |bi| {
        const t = self.an.term[bi];
        if (t == .none) continue;
        if (self.mir.instOp(t) != .branch) continue;
        // A dead branch emits no `if`, so its condition has no use here. It
        // must not be counted, or the value would be slotted and assigned
        // with nothing reading it — which Zig rejects.
        if (self.dead_branch[bi]) continue;
        self.eager_use[@intFromEnum(self.an.rv(self.mir.instData(t).branch.cond))] += 1;
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
        .branch, .jump => {},
    }
}

/// A value read EXACTLY ONCE, by the very next statement of its own block,
/// is rendered inside that statement instead of getting a `const` of its
/// own. `renderValueRef` already falls through to `renderInst` for anything
/// without a slot, so clearing the slot IS the fusion — no new rendering
/// path, and chains collapse transitively because the fallthrough recurses.
///
/// Measured on the emitted text before writing this: 14,930 of 16,242 `const
/// tN` temps (92%) have exactly one use, and 11,366 of those are consumed on
/// the very next line. (CORPUS: emitted device.zig from the corpus in this
/// file's header. WHICH model was not recorded — 22df456 introduced the count
/// and does not say — so re-derive before quoting the ratio for one model.)
/// That adjacency is the whole safety argument and the reason this is not the
/// same pass as the lazy-arm inlining above:
///
///   - ONE use, so the expression is rendered once — no duplicated work.
///     `eager_use == 1 and arm_use == 0` is exactly that, since an arm use
///     is re-rendered per arm by design.
///   - the use is the NEXT statement in `stmt_pool`, so the computation
///     moves later by one statement, inside the same block. Nothing can be
///     hoisted into a loop body or sunk past a side effect, which is what a
///     general "def dominates use" rule would have to reason about.
///
/// So this must NOT undo eager uses: the operands stay eager because the
/// expression is still evaluated exactly once, eagerly, one statement later.
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
            // `call` is an operator/function evaluated once per step (§4.5),
            // `phi` is materialised as a `var` — neither is an expression.
            if (op == .call or op == .phi) continue;
            // The user may sit further down the SAME block as long as every
            // statement in between is a pure expression (unary/binary/
            // ternary): a pure op reads only SSA values, so sliding another
            // pure expression past it changes nothing — the original
            // adjacent-statement rule is the k == si + 1 case. A `call` or
            // `phi` stops the scan: §4.5 operators and §9.4 prints are the
            // side effects the adjacency rule existed to not cross. This is
            // what lets ifconv's spliced arms sit between a comparison and
            // the select that consumes it without costing the fusion.
            for (stmts[si + 1 ..]) |next| {
                if (self.eagerlyUses(next, @enumFromInt(v))) {
                    self.inlined[v] = true;
                    break;
                }
                const nop = self.mir.instOp(next);
                if (nop == .call or nop == .phi) break;
                switch (Mir.opClass(nop)) {
                    .unary, .binary, .ternary => {},
                    .phi, .branch, .jump, .call => break,
                }
            }
        }
    }
}

/// Does `inst` read `v` in an EAGER position? Mirrors `addUses`, including
/// its two exclusions — a folded constant exponent is never materialised,
/// and a non-value call argument is not an operand — so that the counts this
/// is checked against and the answer here cannot drift apart. A `ternary`'s
/// arms are lazy positions, which is `arm_use`, not this.
fn eagerlyUses(self: *const UnitPlan, inst: Mir.Inst, v: Mir.Value) bool {
    return switch (self.mir.instData(inst)) {
        .unary => |d| self.an.rv(d.operand) == v,
        .binary => |d| self.an.rv(d.lhs) == v or
            (!self.foldedExponent(d) and self.an.rv(d.rhs) == v),
        .ternary => |d| self.an.rv(d.cond) == v,
        .call => |d| for (d.args, 0..) |a, i| {
            if (cg.callArgIsValue(d.callee, i, self.dispHere()) and self.an.rv(a) == v) break true;
        } else false,
        .phi, .branch, .jump => false,
    };
}

/// §4.3.1 `pow(x, k)` with a constant exponent goes through the scalar's
/// `pow(S, f64)`, so the exponent is never materialised as a value.
///
/// `resolve_params = false`, the exact mirror of `Gen.renderOp`'s `.pow` arm:
/// a PARAMETER exponent is a value the model card owns, so it is marked live
/// here (and the unit's `model` stays named) and rendered `S.con(model.<p>)`
/// there. Folding through the declared default on either side — this one used
/// `true` — freezes an overridden exponent at its default.
fn foldedExponent(self: *const UnitPlan, d: anytype) bool {
    return d.op == .pow and self.an.foldConst(d.rhs, 0, false) != null;
}

/// True when the slice lives entirely in the entry block and uses no phi —
/// the common case (no `if` on the path to this contribution), and worth a
/// special case because it emits flat, readable `const` code.
///
/// Iterates `live`, not `0..nv`: it is called once per unit, and `live` is
/// the small set `mark` actually reached — the same reason every other
/// per-unit sweep iterates it.
pub fn isStraightLine(self: *const UnitPlan) bool {
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic) continue;
        // A cache or Instance-field read is a field of a value the body
        // already holds, so it has no block of its own — which is what
        // collapses most units to a flat body once the shared core is
        // hoisted out of them.
        if (self.cached(lv) or self.pcHoisted(lv)) continue;
        const db = self.an.def_block[v];
        if (db != none_u32 and db != 0) return false;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .phi) return false;
    }
    return true;
}

/// Which `branch`es this unit cannot tell apart.
///
/// A branch is dead here when both of its edges reduce to the SAME control
/// action once the empty blocks between are skipped, and neither copies a
/// phi on the way: the unit then computes the same values and reaches the
/// same place whichever arm runs, so the condition is unobservable and the
/// whole `if` can go. This is the per-unit half of the hoist — the shared
/// core takes the values, this takes the scaffolding that held them.
pub fn planDeadBranches(self: *UnitPlan) void {
    @memset(self.blk_work, false);
    @memset(self.blk_phi, false);
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic) continue;
        const db = self.an.def_block[v];
        if (db == none_u32) continue;
        // A phi marks its block EVEN WHEN CACHED. `blk_phi` means "the two
        // arms disagree at this SSA join", which is a property of the CFG
        // and the value — not of whether this unit happens to read the
        // result out of the cache. Measured: with a `cached` skip here,
        // `hisimhv_va` moved 4 000 of 128 000 residual entries (CORPUS in
        // the header: not in this tree).
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.an.i_op[@intFromEnum(def.inst_result)] == .phi)
            self.blk_phi[db] = true;
        // A cache/Instance-field read has no block of its own.
        if (self.cached(lv) or self.pcHoisted(lv)) continue;
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
        // and `blk_phi` only guards a phi's OWN block — a loop-carried phi
        // the unit reads from the cache leaves it clear, so the two arms are
        // NOT interchangeable. It is the same hazard `markRecomputedLoops`
        // re-materializes a loop for. Measured: without this clause,
        // `hisimhv_va` moved 4 000 of 128 000 residual entries (CORPUS in
        // the header: not in this tree).
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
