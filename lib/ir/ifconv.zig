//! If-conversion: MIR → the same MIR with each pure CFG diamond or triangle
//! replaced by straight-line code and one §4.2.12 `select` per join phi, to a
//! fixpoint. An arm converts only when every instruction is a pure value op
//! (no call, `opt_barrier`, store or domain-restricted op), so §4.2.3's "side
//! effects shall not occur" holds by construction. Moved rows are relinked;
//! orphaned terminators and emptied arm blocks stay behind, unreachable.

const std = @import("std");
const Mir = @import("mir.zig");
const proof = @import("proof.zig");

/// Converts every pure diamond, to a fixpoint, and returns how many converted.
/// Blocks are visited in index order, so equal MIR converts identically.
/// `gpa` backs one temporary per-block pred count.
pub fn run(gpa: std.mem.Allocator, mir: *Mir) !u32 {
    const nb = mir.blockCount();
    if (nb == 0) return 0;
    const preds = try gpa.alloc(u32, nb);
    defer gpa.free(preds);

    var converted: u32 = 0;
    var changed = true;
    while (changed) {
        changed = false;
        countPreds(mir, preds);
        var b: u32 = 0;
        while (b < nb) : (b += 1) {
            if (try tryConvert(gpa, mir, @fromBackingInt(@intCast(b)), preds)) {
                converted += 1;
                changed = true;
            }
        }
    }
    return converted;
}

/// §5.2.1 `analog initial` and §5.10.2 `initial_step`: the branch on the
/// first-evaluation flag stays a branch. Its join phi, `phi(held read,
/// assigned value)`, is what codegen's setup split recognises as initial-only
/// work and computes once; a `select` on the flag would run every evaluation.
fn firstPoint(mir: *const Mir, cond: Mir.Value) bool {
    const def = mir.valueDef(mir.resolveAlias(cond));
    if (def != .inst_result or mir.instOp(def.inst_result) != .call) return false;
    const d = mir.instData(def.inst_result).call;
    // VerA's `vera_timepoint` (§2.9): a select would run the cached arm.
    return d.callee == .analog_initial or d.callee == .@"$tp_hit" or (d.callee == .initial_step and d.args.len == 0);
}

fn countPreds(mir: *const Mir, preds: []u32) void {
    @memset(preds, 0);
    for (0..preds.len) |b| {
        var it = mir.blockInsts(@fromBackingInt(@intCast(@as(u32, @intCast(b)))));
        while (it.next()) |inst| {
            switch (mir.instData(inst)) {
                .branch => |d| {
                    preds[@backingInt(d.then_block)] += 1;
                    preds[@backingInt(d.else_block)] += 1;
                },
                .jump => |d| preds[@backingInt(d.target)] += 1,
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
            }
        }
    }
}

/// Validate one side: either the direct edge to what the other side joins at,
/// or a single-pred all-pure block ending in a jump. Returns null on any
/// disqualifier. Does not mutate: both sides validate before either moves.
fn classifyArm(mir: *const Mir, x: Mir.Block, arm: Mir.Block, preds: []const u32) ?Mir.Block {
    if (arm == x) return null; // back edge to the branching block itself
    if (preds[@backingInt(arm)] != 1) return null;
    var join: ?Mir.Block = null;
    var it = mir.blockInsts(arm);
    while (it.next()) |inst| {
        if (join != null) return null; // an inst after the terminator (live phi rows land here)
        switch (mir.instData(inst)) {
            .unary => |u| if (u.op == .opt_barrier) return null,
            // §3.2.2 a load is a pure read of the version it names, so it may
            // move into X. A store may not: both arms' versions would be live
            // at the join, and a `select` of two versions of one storage has
            // nothing to select between (`Mir.Opcode.store`).
            .binary, .ternary, .load => {},
            .anew, .store => return null,
            .jump => |d| join = d.target,
            // A collapsed phi row is dead (the alias is the rewrite); a live one
            // in a single-pred block cannot exist (trivial-phi removal), so it
            // disqualifies rather than being trusted never to happen.
            .phi => if (mir.resolveAlias(mir.instResult(inst)) == mir.instResult(inst)) return null,
            .call, .branch => return null,
        }
        // §4.2.12 a domain-restricted op (ln, sqrt, pow, integer /, …) keeps
        // its diamond. Such an arm can never render branchless
        // (render.eagerSafe refuses it), so converting it removes no branch,
        // and it would pull the arm's values out of their block so shared ones
        // re-render as trees at each use. As a CFG arm the edge also guards
        // every value it dominates, which proof.markSelectArms cannot.
        if (proof.domainOf(mir.instOp(inst)) != .all) return null;
    }
    const j = join orelse return null;
    if (j == x or j == arm) return null;
    return j;
}

fn tryConvert(gpa: std.mem.Allocator, mir: *Mir, x: Mir.Block, preds: []u32) !bool {
    const term = terminator(mir, x) orelse return false;
    if (mir.instOp(term) != .branch) return false;
    const br = mir.instData(term).branch;
    if (br.then_block == br.else_block) return false;
    if (firstPoint(mir, br.cond)) return false;

    // Resolve the two sides. At least one must be a real arm; the other may be
    // the join itself (triangle from `&&`/`||` and one-armed `if`).
    const then_join = classifyArm(mir, x, br.then_block, preds);
    const else_join = classifyArm(mir, x, br.else_block, preds);
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
            if (mir.resolveAlias(r) != r) continue; // collapsed: dead row
            if (phiValueFor(mir, inst, then_key) == null) return false;
            if (phiValueFor(mir, inst, else_key) == null) return false;
        }
    }

    // ---- mutation ----------------------------------------------------------
    // Emitted rows inherit the branch's provenance token.
    mir.cur_tok = mir.instTok(term);

    // Drop the branch row from X's chain, then splice the arms in.
    // Late phi rows after the branch stay linked. Each arm's jump is its last
    // row (`classifyArm`) and is orphaned with the branch.
    mir.unlink(x, term);
    for ([_]?Mir.Block{ then_arm, else_arm }) |arm| if (arm) |a| {
        mir.unlink(a, mir.blockLast(a));
        mir.splice(x, a);
    };

    // One select per live join phi, then the fall-through jump. The cond is
    // peeled of `toBool` wrappers first: a select condition means "nonzero ⇒
    // then" (codegen's renderCond), which is exactly what `ine(x, 0)` asserts
    // of x, so the wrapper adds nothing, and peeling it leaves the bare
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

/// Strip nested `ine(x, 0)` wrappers, but only when x is itself a predicate
/// (§4.2.5/§4.2.8 comparison or lognot). Value-wise any peel is safe, but
/// proof.zig's condFacts mines a bare `ine(x, 0)` for the §4.2.4
/// nonzero-divisor fact; peeling a non-predicate x would silently un-guard
/// `b != 0 ? a/b : 0`.
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

/// `b`'s branch or jump, found by opcode and not by position: a phi row can
/// sit after the terminator (ssa.zig mints phis on demand), which is also why
/// analysis.buildCfg searches the same way.
fn terminator(mir: *const Mir, b: Mir.Block) ?Mir.Inst {
    var it = mir.blockInsts(b);
    while (it.next()) |inst| switch (Mir.opClass(mir.instOp(inst))) {
        .branch, .jump => return inst,
        .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
    };
    return null;
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
        mir.extra.items[d.start + count * 2] = @backingInt(p.block);
        mir.extra.items[d.start + count * 2 + 1] = @backingInt(p.value);
        count += 1;
    }
    mir.extra.items[d.start + count * 2] = @backingInt(x);
    mir.extra.items[d.start + count * 2 + 1] = @backingInt(sel);
    mir.insts.items(.c)[@backingInt(phi)] = count + 1;
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
    try std.testing.expectEqual(@as(u32, 1), try run(a, &mir));
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
    try std.testing.expectEqual(join, mir.instData(terminator(&mir, entry).?).jump.target);
}

test "a phi row after the branch neither blocks the conversion nor leaves the chain" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const pre = try mir.addBlock(a);
    const entry = try mir.addBlock(a);
    const left = try mir.addBlock(a);
    const right = try mir.addBlock(a);
    const join = try mir.addBlock(a);
    const cond = try mir.addBlockParam(a, 0);
    _ = try mir.emitJump(a, pre, entry);
    _ = try mir.emitBranch(a, entry, cond, left, right);
    // A phi minted on demand sits after the terminator.
    const late = try mir.emitPhi(a, entry, &.{.{ .block = pre, .value = cond }});
    const lv = try mir.emit(a, left, .fadd, &.{ .f_one, .f_two });
    _ = try mir.emitJump(a, left, join);
    const rv = try mir.emit(a, right, .fmul, &.{ .f_two, .f_two });
    _ = try mir.emitJump(a, right, join);
    _ = try mir.emitPhi(a, join, &.{ .{ .block = left, .value = lv }, .{ .block = right, .value = rv } });

    try std.testing.expectEqual(@as(u32, 1), try run(a, &mir));
    var saw_late = false;
    var it = mir.blockInsts(entry);
    while (it.next()) |inst| {
        if (mir.instResult(inst) == late) saw_late = true;
        try std.testing.expect(mir.instOp(inst) != .branch);
    }
    try std.testing.expect(saw_late);
    try std.testing.expectEqual(join, mir.instData(terminator(&mir, entry).?).jump.target);
}
