//! Lane decisions of the generated device, read through `*Gen`. A lane is
//! dirty once an x-dependent value collapses to one scalar decision
//! (`pinLanes`, `pinCrossing` set `Float.pinned`). A device with no dirty lane
//! emits `batch_ok = true`: `eval`/`q` are exact per point on a multi-point `V`.
//! Under `.strict`, a select with total, cheap inline arms renders as `sel`
//! (`eagerSafe`, `eagerCostly`). The float mode half is `mode.zig`.

const std = @import("std");
const codegen = @import("../../codegen.zig");
const Gen = codegen.Gen;
const gen_render = @import("../render.zig");
const Mir = @import("ir").Mir;
const proof = @import("ir").proof;

/// Returns whether evaluating `v`'s inline subtree eagerly would run a libm
/// call the branch would have skipped. `eagerSafe` says whether both arms
/// may run; this says whether they should. A `materialized` value already
/// ran, so it never counts.
///
/// Branchless wins when the arms are a few FP ops. A transcendental pays for
/// the discarded arm on every eval, which costs more than the branch and the
/// lane pin it brings (measured on mos1; instance-parallel `S` caps at 1.17x
/// end to end because the sparse stamp does not vectorize).
pub fn eagerCostly(self: *Gen, v0: Mir.Value, depth: u32) bool {
    if (depth > 64) return false;
    const v = self.an.rv(v0);
    if (gen_render.materialized(self, v)) return false;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const row = self.mir.instRow(def.inst_result);
    if (codegen.opcode_zig.get(row.op).libm) return true;
    return switch (Mir.opClass(row.op)) {
        .unary => eagerCostly(self, @enumFromInt(row.a), depth + 1),
        .binary => eagerCostly(self, @enumFromInt(row.a), depth + 1) or
            eagerCostly(self, @enumFromInt(row.b), depth + 1),
        .ternary => eagerCostly(self, @enumFromInt(row.a), depth + 1) or
            eagerCostly(self, @enumFromInt(row.b), depth + 1) or
            eagerCostly(self, @enumFromInt(row.c), depth + 1),
        // §3.2.2 a load is one bounds-checked memory read; its index is the
        // only inline operand.
        .load => eagerCostly(self, @enumFromInt(row.b), depth + 1),
        .phi, .branch, .jump, .call, .anew, .store => false,
    };
}

/// Returns whether `v`'s inline subtree may run unconditionally in a
/// `.strict` unit. True for materialized values, leaves, and trees of ops
/// total on all of R under IEEE semantics: no call, and
/// `proof.domainOf == .all` (which excludes ln/sqrt/pow and the trapping
/// idiv/imod/fmod). "Inline" matches what `renderVal` inlines.
pub fn eagerSafe(self: *Gen, v0: Mir.Value, depth: u32) bool {
    if (depth > 64) return false;
    const v = self.an.rv(v0);
    if (gen_render.materialized(self, v)) return true;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return true; // const / param / probe
    const inst = def.inst_result;
    const row = self.mir.instRow(inst);
    if (row.op == .call) return false;
    if (proof.domainOf(row.op) != .all) return false;
    return switch (Mir.opClass(row.op)) {
        .phi => true, // function-scope var, assigned on edges before here
        .unary => eagerSafe(self, @enumFromInt(row.a), depth + 1),
        .binary => eagerSafe(self, @enumFromInt(row.a), depth + 1) and
            eagerSafe(self, @enumFromInt(row.b), depth + 1),
        .ternary => eagerSafe(self, @enumFromInt(row.a), depth + 1) and
            eagerSafe(self, @enumFromInt(row.b), depth + 1) and
            eagerSafe(self, @enumFromInt(row.c), depth + 1),
        // §3.2.2 total: an index outside the array reads zero.
        .load => eagerSafe(self, @enumFromInt(row.b), depth + 1),
        .branch, .jump, .call, .anew, .store => false,
    };
}

/// Records that `v` is about to collapse to one scalar decision, pinning
/// lanes if `v` varies with x. Params, temperature and time are
/// lane-uniform. Tests `xDep`, not `dFree`: a `dstop` has no lanes and still
/// varies. No effect while emitting the display unit.
pub fn pinLanes(self: *Gen, v: Mir.Value) void {
    if (self.emitting_display) return;
    if (!self.an.xDep(v)) return;
    self.float.pinned = true;
}

/// Records a crossing that is one scalar per call, not per lane (a §9.13
/// draw, a systf's `.val()` hand-off). Pins unconditionally, except in the
/// §9.4 display unit, which is not part of the residual.
pub fn pinCrossing(self: *Gen) void {
    self.float.pinned = self.float.pinned or !self.emitting_display;
}
