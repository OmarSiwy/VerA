//! The LANE story of the generated device: when may `eval`/`q` be
//! instantiated with a lane-parallel `S` (one operating point per lane), and
//! which selects run branchless so a vector `S` has nothing to steer on.
//!
//! AGENTS.md §5: SIMD-first applies to the EMITTED device — its `eval` is the
//! hot loop this project exists to make fast — and the decisions that govern
//! its lanes used to be scattered through `Gen`. They are here:
//!
//!   - `pinLanes` / `pinCrossing`: an x-dependent value collapsed to one
//!     scalar decision (a `.val()` comparison, a lazy `if`, an int cast, an
//!     event operator, a value-collapsing helper, a per-call draw, a host
//!     crossing) sets `Float.pinned`.
//!   - `lane_clean`: a device that finishes with `pinned` false gets
//!     `pub const lane_clean = true;` (`file.zig`), which the testbench's
//!     wide-vs-narrow batch check keys on.
//!   - `eagerSafe` / `eagerCostly`: under `Float.strict` a real select whose
//!     inline arms are total and cheap renders as the contract's `sel` mask —
//!     true per lane — instead of a lazy `if`.
//!
//! The float MODE half (strict vs optimized, the f32 Jacobian permission) is
//! `mode.zig`. Emit-side: these read the slice plan through `*Gen`.

const std = @import("std");
const codegen = @import("../../codegen.zig");
const Gen = codegen.Gen;
const gen_render = @import("../render.zig");
const Mir = @import("ir").Mir;
const proof = @import("ir").proof;

/// May `v`'s inline-rendered subtree run UNCONDITIONALLY in a `.strict`
/// unit? True for anything already materialized (slots/cache/phi vars are
/// computed before the select either way), leaves, and trees of ops that
/// are total on all of R under IEEE semantics: no call, and
/// `proof.domainOf == .all` — which excludes ln/sqrt/pow/… and the
/// hard-UB idiv/imod/fmod. Mirrors `foldHidesSlot`'s stop condition, so
/// "inline" here is exactly what `renderVal` would inline.
/// Would evaluating this arm eagerly run a libm call that the branch would
/// have skipped? `eagerSafe` answers whether both arms MAY be evaluated;
/// this answers whether they SHOULD.
///
/// Branchless is the right default because the arms are a few FP ops and a
/// mispredict costs more than both. A transcendental inverts that: `exp` is
/// ~50 instructions, so a `sel` over it pays for the arm that is thrown
/// away every single time. mos1 measured 2.00 `exp` per instance-eval
/// against ngspice's 1.45 for exactly this reason — the b-s junction kept
/// its `if` (a multi-use domain op blocked if-conversion) while the
/// identical b-d junction was flattened, so both of ITS arms run forever.
///
/// The cost of saying no is a data-dependent branch and a lane pin. That
/// was the argument for keeping these eager — a lane-parallel S has no
/// single `.val()` to steer on. It does not survive measurement: an
/// instance-parallel S would have to take BOTH junction arms anyway, which
/// is what collapses that design's kernel speedup from 3.6x to 1.67x, and
/// the sparse stamp it cannot vectorize at all (195 Ir/instance at W=1,
/// 196 at W=4) caps the whole idea at 1.17x end-to-end. Not a lever worth
/// protecting with a real per-iterate cost.
///
/// Only the INLINE tree counts: a `materialized` value is a statement that
/// already ran, so hoisting it into a select changes nothing.
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

/// An x-dependent value is about to be collapsed to one scalar decision —
/// record that lanes are pinned. dFree values are lane-uniform (params,
/// temperature, time), so collapsing them steers nothing.
pub fn pinLanes(self: *Gen, v: Mir.Value) void {
    if (self.emitting_display) return;
    if (self.an.dFree(v)) return;
    self.float.pinned = true;
}

/// A crossing that is one scalar per CALL, not per lane — a §9.13 draw, a
/// systf's `.val()` hand-off to the host: it pins unconditionally, except in
/// the §9.4 display unit, which is not part of the residual.
pub fn pinCrossing(self: *Gen) void {
    self.float.pinned = self.float.pinned or !self.emitting_display;
}
