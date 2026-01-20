//! If-conversion: pure CFG diamonds/triangles → §4.2.12 `select`.
//!
//! Transformation: Mir (post-lowering, pre-proof) → the same Mir with every
//! convertible two-way branch replaced by straight-line code and one `select`
//! per join phi. Runs between lower and prove in root.zig.
//!
//! WHY. A data-dependent branch in an eval unit costs twice: the host's Newton
//! loop hands the predictor data-dependent work (ref/SIMD-Strategies T7), and a
//! lane-parallel S (one operating point per lane) has no single branch
//! direction at all. As a `select` the conditional can be emitted branchless
//! (`S.sel`) whenever the proof shows both arms total — and where it does not,
//! codegen's lazy `if`-expression emission preserves §4.2.3's short-circuit
//! semantics exactly as the branch did, because proof.markSelectArms re-derives
//! the guard facts the CFG edge used to carry.
//!
//! WHAT CONVERTS. Block X ending `branch(c, T, E)` where each arm side is
//! either the join J itself (triangle) or a block with exactly one predecessor
//! whose every instruction is a pure value op (unary/binary/ternary — no call,
//! no opt_barrier, no live phi) ending `jump J`. Arms splice into X in
//! then-else order, each join phi becomes `select(c, v_then, v_else)` in X,
//! and X jumps to J. Effectful arms — calls, analog operators, display — never
//! match, so §4.2.3's "side effects shall not occur" is preserved by
//! construction; runtime-error laziness is the proof's job (see above).
//!
//! Fixpoint: converting an inner diamond can collapse an outer arm to a single
//! block (nested `?:`, `&&` chains), so sweep until a round converts nothing.
//!
//! DOD: one u32 pred-count per block per round, on the caller's arena. Inst
//! rows MOVE by relinking `next` (chains are singly linked); the orphaned
//! branch/jump rows stay in `insts` but in no chain, which every consumer
//! tolerates because they only walk chains. Emptied arm blocks keep their
//! BlockRow with first=last=none — unreachable, and both proof.walk and the
//! codegen relooper already handle unreachable blocks.
//!
//! DETERMINISM: blocks are visited in index order and every mutation is an
//! append or a relink of existing rows, so identical MIR converts identically.

const std = @import("std");
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const proof = @import("proof.zig");

/// `contributions` (Lower's) carry uses the MIR cannot see — each target's
/// resist/react value. They enter the use counts so a domain-restricted op
/// the guard must cover is never mistaken for exclusively-owned;
/// proof.markSelectArms counts them the same way.
pub fn run(gpa: std.mem.Allocator, mir: *Mir, contributions: []const Lower.Contribution) !u32 {
    const nb = mir.blockCount();
    if (nb == 0) return 0;
    const preds = try gpa.alloc(u32, nb);
    defer gpa.free(preds);
    // Re-sized per round: each conversion appends a select Value.
    var uses: std.ArrayList(u32) = .empty;
    defer uses.deinit(gpa);

    var converted: u32 = 0;
    var changed = true;
    while (changed) {
        changed = false;
        countPreds(mir, preds);
        try uses.resize(gpa, mir.defs.len + Mir.Value.first_dynamic);
        countUses(mir, contributions, uses.items);
        var b: u32 = 0;
        while (b < nb) : (b += 1) {
            if (try tryConvert(gpa, mir, @enumFromInt(b), preds, uses.items)) {
                converted += 1;
                changed = true;
            }
        }
    }
    return converted;
}

fn countPreds(mir: *const Mir, preds: []u32) void {
    @memset(preds, 0);
    for (0..preds.len) |b| {
        var it = mir.blockInsts(@enumFromInt(@as(u32, @intCast(b))));
        while (it.next()) |inst| {
            switch (mir.instData(inst)) {
                .branch => |d| {
                    preds[@intFromEnum(d.then_block)] += 1;
                    preds[@intFromEnum(d.else_block)] += 1;
                },
                .jump => |d| preds[@intFromEnum(d.target)] += 1,
                else => {},
            }
        }
    }
}

/// Per-round use counts, alias-resolved, chain-walked (orphaned rows from
/// earlier conversions are in no chain and must not count). Mirrors
/// proof.markSelectArms' counting — the same census that decides whether an
/// arm's slice is exclusively owned and can carry the guard.
fn countUses(mir: *const Mir, contributions: []const Lower.Contribution, uses: []u32) void {
    @memset(uses, 0);
    const bump = struct {
        fn f(m: *const Mir, u: []u32, v: Mir.Value) void {
            u[@intFromEnum(m.resolveAlias(v))] += 1;
        }
    }.f;
    for (contributions) |c| {
        bump(mir, uses, c.resist_val);
        bump(mir, uses, c.react_val);
    }
    for (0..mir.blockCount()) |b| {
        var it = mir.blockInsts(@enumFromInt(@as(u32, @intCast(b))));
        while (it.next()) |inst| {
            switch (mir.instData(inst)) {
                .unary => |d| bump(mir, uses, d.operand),
                .binary => |d| {
                    bump(mir, uses, d.lhs);
                    bump(mir, uses, d.rhs);
                },
                .ternary => |d| {
                    bump(mir, uses, d.cond);
                    bump(mir, uses, d.then_val);
                    bump(mir, uses, d.else_val);
                },
                .call => |d| for (d.args) |a| bump(mir, uses, a),
                .phi => |d| for (0..d.count) |k| bump(mir, uses, mir.phiPair(inst, @intCast(k)).value),
                .branch => |d| bump(mir, uses, d.cond),
                .jump => {},
            }
        }
    }
}

/// Validate one side: either the direct edge to what the other side joins at,
/// or a single-pred all-pure block ending in a jump. Returns null on any
/// disqualifier. NO MUTATION here — both sides validate before either moves.
fn classifyArm(mir: *const Mir, x: Mir.Block, arm: Mir.Block, preds: []const u32, uses: []const u32) ?Mir.Block {
    if (arm == x) return null; // back edge to the branching block itself
    if (preds[@intFromEnum(arm)] != 1) return null;
    var join: ?Mir.Block = null;
    var it = mir.blockInsts(arm);
    while (it.next()) |inst| {
        if (join != null) return null; // an inst after the terminator (live phi rows land here)
        switch (mir.instData(inst)) {
            .unary => |u| if (u.op == .opt_barrier) return null,
            .binary, .ternary => {},
            .jump => |d| join = d.target,
            // A collapsed phi row is dead (alias IS the rewrite — ssa.zig
            // contract 1); a live one in a single-pred block cannot exist
            // (Braun trivial-phi removal), so treat it as a disqualifier
            // rather than trust that it never happens.
            .phi => if (mir.resolveAlias(mir.instResult(inst)) == mir.instResult(inst)) return null,
            .call, .branch => return null,
        }
        // A domain-restricted op (ln, sqrt, integer /, …) only keeps its
        // guard through conversion if proof.markSelectArms can walk to it,
        // and that walk stops at any value used more than once. The CFG edge
        // guarded EVERYTHING it dominated, multi-use included — so a shared
        // domain-op result must keep its diamond or a legal model turns
        // rejected (integer div) or drops to `.strict` (real ops).
        const op = mir.instOp(inst);
        if (proof.domainOf(op) != .all) {
            const res = mir.instResult(inst);
            if (res == .undef) return null;
            const ri = @intFromEnum(mir.resolveAlias(res));
            // Past the census ⇒ the alias points at a select THIS round
            // emitted; the counts are stale. Refuse now — the fixpoint
            // re-offers the diamond next round with a fresh census.
            if (ri >= uses.len or uses[ri] != 1) return null;
        }
    }
    const j = join orelse return null;
    if (j == x or j == arm) return null;
    return j;
}

fn tryConvert(gpa: std.mem.Allocator, mir: *Mir, x: Mir.Block, preds: []u32, uses: []const u32) !bool {
    const term = lastInst(mir, x) orelse return false;
    if (mir.instOp(term) != .branch) return false;
    const br = mir.instData(term).branch;
    if (br.then_block == br.else_block) return false;

    // Resolve the two sides. At least one must be a real arm; the other may be
    // the join itself (triangle from `&&`/`||` and one-armed `if`).
    const then_join = classifyArm(mir, x, br.then_block, preds, uses);
    const else_join = classifyArm(mir, x, br.else_block, preds, uses);
    var join: Mir.Block = undefined;
    var then_arm: ?Mir.Block = null;
    var else_arm: ?Mir.Block = null;
    if (then_join != null and else_join != null and then_join.? == else_join.?) {
        join = then_join.?;
        then_arm = br.then_block;
        else_arm = br.else_block;
    } else if (then_join != null and then_join.? == br.else_block) {
        join = br.else_block; // triangle: else edge is direct
        then_arm = br.then_block;
    } else if (else_join != null and else_join.? == br.then_block) {
        join = br.then_block; // triangle: then edge is direct
        else_arm = br.else_block;
    } else return false;

    // Validate every live phi in the join: it must carry a pair for each side
    // of this diamond, or the conversion cannot rewrite it.
    const then_key: Mir.Block = then_arm orelse x;
    const else_key: Mir.Block = else_arm orelse x;
    {
        var it = mir.blockInsts(join);
        while (it.next()) |inst| {
            if (mir.instOp(inst) != .phi) continue;
            const r = mir.instResult(inst);
            if (mir.resolveAlias(r) != r) continue; // collapsed — dead row
            if (phiValueFor(mir, inst, then_key) == null) return false;
            if (phiValueFor(mir, inst, else_key) == null) return false;
        }
    }

    // ---- mutation ----------------------------------------------------------
    // Emitted rows inherit the branch's provenance token.
    mir.cur_tok = mir.instTok(term);

    // Drop the branch row from X's chain, then splice the arms in.
    truncateBefore(mir, x, term);
    if (then_arm) |a| splice(mir, x, a);
    if (else_arm) |a| splice(mir, x, a);

    // One select per live join phi, then the fall-through jump. The cond is
    // peeled of `toBool` wrappers first: a select condition means "nonzero ⇒
    // then" (codegen's renderCond), which is exactly what `ine(x, 0)` asserts
    // of x, so the wrapper adds nothing — and peeling it leaves the bare
    // comparison as the select's cond, where codegen can render it as a
    // lane-true S mask instead of an i64 round-trip.
    const cond = peelToBool(mir, br.cond);
    var phis = mir.blockInsts(join);
    while (phis.next()) |phi| {
        if (mir.instOp(phi) != .phi) continue;
        const result = mir.instResult(phi);
        if (mir.resolveAlias(result) != result) continue;
        const vt = phiValueFor(mir, phi, then_key).?;
        const ve = phiValueFor(mir, phi, else_key).?;
        const sel = try mir.emit(gpa, x, .select, &.{ cond, vt, ve });
        // emit may relocate the borrowed column; the cursor itself is an index.
        phis.next_col = mir.insts.items(.next);
        rewritePhi(mir, phi, then_key, else_key, x, sel);
    }
    _ = try mir.emitJump(gpa, x, join);
    return true;
}

/// Strip nested `ine(x, 0)` wrappers, but ONLY when x is itself a predicate
/// (§4.2.5/§4.2.8 comparison or lognot). The select cond reads "nonzero is
/// true" either way, so value-wise any peel would be safe — but proof.zig's
/// condFacts mines a bare `ine(x, 0)` for the §4.2.4 nonzero-divisor fact,
/// and peeling a NON-predicate x would hand markSelectArms a cond it can
/// derive no facts from, silently un-guarding `b != 0 ? a/b : 0`.
fn peelToBool(mir: *const Mir, cond0: Mir.Value) Mir.Value {
    var cond = cond0;
    while (true) {
        const def = mir.valueDef(mir.resolveAlias(cond));
        if (def != .inst_result) return cond;
        if (mir.instOp(def.inst_result) != .ine) return cond;
        const d = mir.instData(def.inst_result).binary;
        if (mir.resolveAlias(d.rhs) != .zero) return cond;
        if (!proof.isPredicateValue(mir, d.lhs)) return cond;
        cond = d.lhs;
    }
}

fn lastInst(mir: *const Mir, b: Mir.Block) ?Mir.Inst {
    const last = mir.blocks.items(.last)[@intFromEnum(b)];
    return if (last == .none) null else last;
}

/// The phi's incoming value for edge `from` → phi's block, or null.
fn phiValueFor(mir: *const Mir, phi: Mir.Inst, from: Mir.Block) ?Mir.Value {
    const d = mir.instData(phi).phi;
    for (0..d.count) |k| {
        const p = mir.phiPair(phi, @intCast(k));
        if (p.block == from) return p.value;
    }
    return null;
}

/// Remove `inst` (X's terminator) from X's chain by re-terminating the chain
/// at its predecessor. The row itself is orphaned, not reused.
fn truncateBefore(mir: *Mir, b: Mir.Block, inst: Mir.Inst) void {
    const bi = @intFromEnum(b);
    const first = mir.blocks.items(.first)[bi];
    if (first == inst) {
        mir.blocks.items(.first)[bi] = .none;
        mir.blocks.items(.last)[bi] = .none;
        return;
    }
    var prev = first;
    while (mir.insts.items(.next)[@intFromEnum(prev)] != inst)
        prev = mir.insts.items(.next)[@intFromEnum(prev)];
    mir.insts.items(.next)[@intFromEnum(prev)] = .none;
    mir.blocks.items(.last)[bi] = prev;
}

/// Move every row of `arm` except its jump terminator to the end of `dst`,
/// preserving order. `arm` is left empty (first=last=none).
fn splice(mir: *Mir, dst: Mir.Block, arm: Mir.Block) void {
    var it = mir.blockInsts(arm);
    while (it.next()) |inst| {
        if (mir.instOp(inst) == .jump) continue; // classifyArm proved it's last
        appendExisting(mir, dst, inst);
    }
    mir.blocks.items(.first)[@intFromEnum(arm)] = .none;
    mir.blocks.items(.last)[@intFromEnum(arm)] = .none;
}

/// Relink an existing row to the end of `dst`'s chain (addInst without the
/// append — the row already exists).
fn appendExisting(mir: *Mir, dst: Mir.Block, inst: Mir.Inst) void {
    mir.insts.items(.next)[@intFromEnum(inst)] = .none;
    const bi = @intFromEnum(dst);
    const last = mir.blocks.items(.last)[bi];
    if (last == .none) {
        mir.blocks.items(.first)[bi] = inst;
    } else {
        mir.insts.items(.next)[@intFromEnum(last)] = inst;
    }
    mir.blocks.items(.last)[bi] = inst;
}

/// Replace this phi's diamond pairs with one `(x, sel)` pair; if that leaves a
/// single incoming value the phi collapses to an alias, exactly like ssa.zig's
/// trivial-phi removal.
fn rewritePhi(mir: *Mir, phi: Mir.Inst, then_key: Mir.Block, else_key: Mir.Block, x: Mir.Block, sel: Mir.Value) void {
    const d = mir.instData(phi).phi;
    var count: u32 = 0;
    // Validation found both edges: replacing them by one always fits. Payload
    // regions belong to individual instructions; compact only this phi's region.
    for (0..d.count) |k| {
        const p = mir.phiPair(phi, @intCast(k));
        if (p.block == then_key or p.block == else_key) continue;
        mir.extra.items[d.start + count * 2] = @intFromEnum(p.block);
        mir.extra.items[d.start + count * 2 + 1] = @intFromEnum(p.value);
        count += 1;
    }
    mir.extra.items[d.start + count * 2] = @intFromEnum(x);
    mir.extra.items[d.start + count * 2 + 1] = @intFromEnum(sel);
    mir.insts.items(.c)[@intFromEnum(phi)] = count + 1;
    // Even dead phis must hold the new pairs: proof evaluates their operands.
    if (count == 0) mir.setAlias(mir.instResult(phi), sel);
}

test "phi compaction preserves unrelated edges and neighboring payloads" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const entry = try mir.addBlock(a);
    const left = try mir.addBlock(a);
    const right = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const result = try mir.emitPhi(a, join, &.{
        .{ .block = left, .value = .zero },
        .{ .block = entry, .value = .one },
        .{ .block = right, .value = .one },
    });
    const phi = mir.valueDef(result).inst_result;
    const neighbor = try mir.addExtra(a, &.{ 17, 23 });
    const size = mir.extra.items.len;
    rewritePhi(&mir, phi, left, right, join, .zero);
    try std.testing.expectEqual(size, mir.extra.items.len);
    try std.testing.expectEqual(@as(u32, 2), mir.instData(phi).phi.count);
    try std.testing.expectEqual(Mir.PhiPair{ .block = entry, .value = .one }, mir.phiPair(phi, 0));
    try std.testing.expectEqual(Mir.PhiPair{ .block = join, .value = .zero }, mir.phiPair(phi, 1));
    try std.testing.expectEqual(result, mir.resolveAlias(result));
    rewritePhi(&mir, phi, entry, join, entry, .one);
    try std.testing.expectEqual(Mir.Value.one, mir.resolveAlias(result));
    try std.testing.expectEqual(Mir.PhiPair{ .block = entry, .value = .one }, mir.phiPair(phi, 0));
    try std.testing.expectEqual(size, mir.extra.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 17, 23 }, mir.extra.items[neighbor..]);
}

test "if conversion refreshes phi iterator when select emission grows instruction columns" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const entry = try mir.addBlock(a);
    const left = try mir.addBlock(a);
    const right = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const cond = try mir.addBlockParam(a, 0);
    _ = try mir.emitBranch(a, entry, cond, left, right);
    const lv = try mir.emit(a, left, .fadd, &.{ .f_one, .f_two });
    _ = try mir.emitJump(a, left, join);
    const rv = try mir.emit(a, right, .fmul, &.{ .f_two, .f_two });
    _ = try mir.emitJump(a, right, join);
    const left_values = [_]Mir.Value{ lv, .f_one };
    const right_values = [_]Mir.Value{ rv, .f_two };
    var results: [2]Mir.Value = undefined;
    for (&results, left_values, right_values) |*result, l, r| result.* = try mir.emitPhi(a, join, &.{
        .{ .block = left, .value = l },
        .{ .block = right, .value = r },
    });

    // The first select must grow the SoA allocation. A cached .next slice
    // then points into freed/relocated columns while more join phis remain.
    try mir.insts.setCapacity(a, mir.insts.len);
    const old_capacity = mir.insts.capacity;
    try std.testing.expectEqual(mir.insts.len, old_capacity);
    try std.testing.expectEqual(@as(u32, 1), try run(a, &mir, &.{}));
    try std.testing.expect(mir.insts.capacity > old_capacity);

    for (results, left_values, right_values) |result, l, r| {
        const selected = mir.resolveAlias(result);
        try std.testing.expect(selected != result);
        const inst = mir.valueDef(selected).inst_result;
        try std.testing.expectEqual(Mir.Opcode.select, mir.instOp(inst));
        const select = mir.instData(inst).ternary;
        try std.testing.expectEqual(cond, select.cond);
        try std.testing.expectEqual(l, select.then_val);
        try std.testing.expectEqual(r, select.else_val);
    }
    var selects: u32 = 0;
    var insts = mir.blockInsts(entry);
    while (insts.next()) |inst| if (mir.instOp(inst) == .select) {
        selects += 1;
    };
    try std.testing.expectEqual(@as(u32, 2), selects);
    try std.testing.expectEqual(join, mir.instData(lastInst(&mir, entry).?).jump.target);
}
