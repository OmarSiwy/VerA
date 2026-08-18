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
//! placement depends on the order the text comes out in. They live here anyway,
//! because the partial reset below has to see the previous unit's `live` set to
//! clear them, and splitting storage from that reset would put an ordering
//! dependency across a file boundary. One owner, no hazard.
//!
//! ## CORPUS — where every measured number in this file comes from
//!
//! `hisimhv_va` (HiSIM_HV) and `bsimsoi_va` (the public Berkeley BSIM-SOI) are
//! two of the 38 foundry models in the ARPice host repo, at
//! `../ARPice/src/devices/models` — `VERA_MODELS` overrode that path for the
//! `baseline.sh` oracle these were taken with. NONE is vendored here, and no
//! fixture is remotely their shape — the numbers below are per-unit line counts
//! in the thousands, over ~105 units. So every ratio below is real and none of
//! it is reproducible from this tree alone: check the models out before you
//! re-measure, and do not re-derive a replacement from a fixture.
//!
//! ## RESET IS PARTIAL, AND THAT IS THE DESIGN
//!
//! `analyze` clears only the cells named by the PREVIOUS unit's `live` set, not
//! all `nv` of them. Clearing every table per unit was O(units × values), and a
//! 600 K-line model has hundreds of units that each touch a small slice of the
//! values.
//!
//! So every table here holds stale data from earlier units in every cell outside
//! the previous unit's live set. `needed` is what makes that safe: it is the only
//! one written by `mark`, and every read of `eager_use`, `arm_use`, `inlined` and
//! `slot` is guarded by it. Unit N is correct because unit N−1 cleaned up after
//! itself.
//!
//! Two consequences, both load-bearing:
//!   - `analyze` must be called for EVERY unit, in order, even one whose output
//!     is discarded. Skip one and its live set is never cleared, so the next unit
//!     reads its `eager_use` under a `needed` that has just been set true.
//!   - a field added here MUST be cleared in the same loop in `analyzeUnitOnce`,
//!     or it silently inherits the previous unit's value.
//!
//! `loop_recompute` is the exception: it is indexed by BLOCK, not by value, so
//! the live set cannot name its cells and `analyze` resets it in full.
//!
//! ### AND IN THIS TREE THE RESET LOOP RUNS ZERO ITERATIONS
//!
//! Measured, ReleaseFast, every fixture, by counting `analyzeUnitOnce` and
//! printing `live.items.len` on entry: **739 of the 1164 fixtures reach codegen,
//! each calls `analyze` exactly ONCE, and `live` is empty at all 739 resets.**
//! `emitUnits` only calls `emitUnit` for a `job.is_display` job, so under the
//! default `--display=drop` the shared core is the whole emission and there is
//! no second unit to inherit anything. `--display=emit` adds exactly one
//! `emitUnit` call — the only non-empty reset that exists here (live = 28 on
//! `exhaustive/102_loops.va`).
//!
//! The scheme is not dead: it is what keeps the CORPUS models (~105 units) off
//! O(units x values). But nothing in this tree exercises it, so the "a field
//! added here MUST be cleared" hazard above has NO test coverage — read that as
//! a reason to be careful, not as permission to simplify.
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
//! A bitset also cannot obsolete the partial reset above, which was the
//! interesting question: three of the five tables that loop clears
//! (`eager_use`, `arm_use`, `slot`) are `[]u32`, so a full clear stays
//! O(units x values) no matter how `needed` and `inlined` are stored.
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
const Mir = @import("../ir/mir.zig");
const Analysis = @import("../ir/analysis.zig");
const Lower = @import("../ir/lower.zig");
// The emitter owns these: `Display` is its §9.4 mode, and the two `op*`/`call*`
// helpers classify a call the same way for the plan and for the text. Mutual
// import with codegen.zig is fine here — nothing in the cycle is a comptime
// dependency of the other's types.
const cg = @import("codegen.zig");
const Display = cg.Display;
const assert = std.debug.assert;

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
/// The shared core's dedup index, from `planCommon`. Stable for the whole
/// compilation; a value with an entry here is read out of the core rather than
/// recomputed, unless this unit re-runs the loop that defines it.
lo_idx: []const u32 = &.{},
lo_vals: []const Mir.Value = &.{},
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
    @memset(self.loop_recompute, false);
    self.needed = try arena.alloc(bool, an.nv);
    self.eager_use = try arena.alloc(u32, an.nv);
    self.arm_use = try arena.alloc(u32, an.nv);
    self.inlined = try arena.alloc(bool, an.nv);
    self.slot = try arena.alloc(u32, an.nv);
    @memset(self.needed, false);
    @memset(self.eager_use, 0);
    @memset(self.arm_use, 0);
    @memset(self.inlined, false);
    @memset(self.slot, none_u32);
    // Per-BLOCK, not per-value: a whole `@memset` of these per unit is a few KB,
    // nothing like the `0..nv` per-unit sweeps that were deleted.
    self.blk_work = try arena.alloc(bool, an.nb);
    self.blk_phi = try arena.alloc(bool, an.nb);
    self.dead_branch = try arena.alloc(bool, an.nb);
    return self;
}

/// Is this Value read out of the common declaration's cache HERE? False inside
/// the common declaration itself, where it is computed, and false for a value
/// defined inside a loop this unit re-runs.
pub inline fn cached(self: *const UnitPlan, v: Mir.Value) bool {
    if (self.in_common or self.lo_idx[@intFromEnum(v)] == none_u32) return false;
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
        if (!self.markRecomputedLoops()) return;
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
        if (self.cached(lv)) continue; // computed by the core, not here
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
    // Only the previous unit's live values can be dirty: every write below
    // is guarded by `needed`, which only `mark` sets. Clearing the whole
    // per-value tables per unit was O(units × values).
    for (self.live.items) |lv| {
        const i = @intFromEnum(lv);
        self.needed[i] = false;
        self.eager_use[i] = 0;
        self.arm_use[i] = 0;
        self.inlined[i] = false;
        self.slot[i] = none_u32;
    }
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
    if (!self.straight) {
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
        self.reattribute(def.inst_result);
    }

    self.fuseSingleUse();

    // Slots for everything that survives as a statement, in ascending value
    // order — a UNIT-LOCAL dense index, never a MIR value index.
    self.uses_cache = false;
    for (self.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (v < Mir.Value.first_dynamic or self.inlined[v]) continue;
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
        if (d == .call and cg.opNeedsInput(cg.opKind(d.call.name)) and d.call.args.len != 0 and
            self.cached(self.an.rv(d.call.args[0]))) self.uses_cache = true;
        self.slot[v] = self.n_slots;
        self.n_slots += 1;
    }
}

fn mark(self: *UnitPlan, work: *std.ArrayList(Mir.Value), v0: Mir.Value) Error!void {
    const v = self.an.rv(v0);
    if (self.needed[@intFromEnum(v)]) return;
    self.needed[@intFromEnum(v)] = true;
    try self.live.append(self.arena, v);
    // A value read out of the common declaration's cache is a LEAF here:
    // its operands were computed there, and pulling them in is exactly the
    // duplication the hoist removes.
    if (self.cached(v)) return;
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
            if (cg.callArgIsValue(d.name, i, self.dispHere())) try self.mark(work, a);
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
        if (self.cached(lv)) continue; // a leaf: its operands are not here
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
            if (cg.callArgIsValue(d.name, i, self.dispHere())) bump(self, a, false, undo);
        },
        .phi => |d| {
            var i: u32 = 0;
            while (i < d.count) : (i += 1) bump(self, self.mir.phiPair(inst, i).value, false, undo);
        },
        .branch, .jump => {},
    }
}

fn reattribute(self: *UnitPlan, inst: Mir.Inst) void {
    self.addUses(inst, true);
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
/// So this must NOT call `reattribute`: the operands stay eager because the
/// expression is still evaluated exactly once, eagerly, one statement later.
fn fuseSingleUse(self: *UnitPlan) void {
    for (0..self.an.nb) |bi| {
        const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
        if (stmts.len < 2) continue;
        for (stmts[0 .. stmts.len - 1], stmts[1..]) |inst, next| {
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
            if (!self.eagerlyUses(next, @enumFromInt(v))) continue;
            self.inlined[v] = true;
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
            if (cg.callArgIsValue(d.name, i, self.dispHere()) and self.an.rv(a) == v) break true;
        } else false,
        else => false,
    };
}

/// §4.3.1 `pow(x, k)` with a constant exponent goes through the scalar's
/// `pow(S, f64)`, so the exponent is never materialised as a value.
fn foldedExponent(self: *const UnitPlan, d: anytype) bool {
    return d.op == .pow and self.an.foldConst(d.rhs, 0, true) != null;
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
        // A cache read is a field of a value the body already holds, so it
        // has no block of its own — which is what collapses most units to a
        // flat body once the shared core is hoisted out of them.
        if (self.cached(lv)) continue;
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
        if (self.cached(lv)) continue; // a cache read has no block of its own
        self.blk_work[db] = true;
    }
    @memset(self.dead_branch, false);
    for (self.an.rpo) |bi| {
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
    while (hops <= self.an.nb) : (hops += 1) {
        // A phi in `to` means `emitEdge` copies a value on this edge, which
        // is the one thing the two arms cannot share.
        if (self.blk_phi[to]) return null;
        if (self.an.is_loop[to] and self.an.dominates(to, from)) return .{ .cont = to };
        if (self.an.is_merge[to]) return .{ .brk = to };
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
        if (self.an.mk_off[to + 1] != self.an.mk_off[to]) return null; // opens labels
        const t = self.an.term[to];
        if (t == .none or self.mir.instOp(t) != .jump) return null;
        from = to;
        to = @intFromEnum(self.mir.instData(t).jump.target);
    }
    return null;
}
