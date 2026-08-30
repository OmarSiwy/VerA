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
const assert = std.debug.assert;

const none_u32 = std.math.maxInt(u32);

/// One side of the branch, validated before any mutation.
const Arm = struct {
    /// The arm block, or `.none`-like sentinel when the edge goes straight to
    /// the join (triangle): then the phi pair for this side names X itself.
    block: ?Mir.Block,
    join: Mir.Block,
};

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
            if (try tryConvert(gpa, mir, @enumFromInt(b), preds)) {
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

/// Validate one side: either the direct edge to what the other side joins at,
/// or a single-pred all-pure block ending in a jump. Returns null on any
/// disqualifier. NO MUTATION here — both sides validate before either moves.
fn classifyArm(mir: *const Mir, x: Mir.Block, arm: Mir.Block, preds: []const u32) ?Mir.Block {
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
    }
    const j = join orelse return null;
    if (j == x or j == arm) return null;
    return j;
}

fn tryConvert(gpa: std.mem.Allocator, mir: *Mir, x: Mir.Block, preds: []u32) !bool {
    const term = lastInst(mir, x) orelse return false;
    if (mir.instOp(term) != .branch) return false;
    const br = mir.instData(term).branch;
    if (br.then_block == br.else_block) return false;

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
    var phis: std.ArrayList(Mir.Inst) = .empty;
    defer phis.deinit(gpa);
    {
        var it = mir.blockInsts(join);
        while (it.next()) |inst| {
            if (mir.instOp(inst) != .phi) continue;
            const r = mir.instResult(inst);
            if (mir.resolveAlias(r) != r) continue; // collapsed — dead row
            if (phiValueFor(mir, inst, then_key) == null) return false;
            if (phiValueFor(mir, inst, else_key) == null) return false;
            try phis.append(gpa, inst);
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
    for (phis.items) |phi| {
        const vt = phiValueFor(mir, phi, then_key).?;
        const ve = phiValueFor(mir, phi, else_key).?;
        const sel = try mir.emit(gpa, x, .select, &.{ cond, vt, ve });
        try rewritePhi(gpa, mir, phi, then_key, else_key, x, sel);
    }
    _ = try mir.emitJump(gpa, x, join);
    return true;
}

/// Strip nested `ine(x, 0)` wrappers. Safe for a select cond regardless of
/// whether x is 0/1: both sides read "nonzero is true".
fn peelToBool(mir: *const Mir, cond0: Mir.Value) Mir.Value {
    var cond = cond0;
    while (true) {
        const def = mir.valueDef(mir.resolveAlias(cond));
        if (def != .inst_result) return cond;
        if (mir.instOp(def.inst_result) != .ine) return cond;
        const d = mir.instData(def.inst_result).binary;
        if (mir.resolveAlias(d.rhs) != .zero) return cond;
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
fn rewritePhi(gpa: std.mem.Allocator, mir: *Mir, phi: Mir.Inst, then_key: Mir.Block, else_key: Mir.Block, x: Mir.Block, sel: Mir.Value) !void {
    const d = mir.instData(phi).phi;
    var pairs: std.ArrayList(Mir.PhiPair) = .empty;
    defer pairs.deinit(gpa);
    for (0..d.count) |k| {
        const p = mir.phiPair(phi, @intCast(k));
        if (p.block == then_key or p.block == else_key) continue;
        try pairs.append(gpa, p);
    }
    try pairs.append(gpa, .{ .block = x, .value = sel });
    // The pairs are ALWAYS rewritten, even when the phi collapses to an alias:
    // proof.zig evaluates dead phi rows left in the chain (ssa.zig contract 2)
    // and counts their pairs as uses (markSelectArms), so stale pairs naming
    // the arm values would cost the arm its single-use guard — silently
    // dropping `x > 0 ? ln(x) : 0` from .optimized to .strict. A single
    // `(x, sel)` pair is exactly the trivial-phi shape ssa.zig leaves behind:
    // its join and finiteness equal the alias target's, so the prover's
    // through-the-alias writes stay consistent.
    try mir.setPhiPairs(gpa, phi, pairs.items);
    if (pairs.items.len == 1) mir.setAlias(mir.instResult(phi), sel);
}
