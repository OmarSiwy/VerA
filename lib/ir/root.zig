//! IR: elaborated design (`elab`, §6.2.2) → SSA MIR → analysis, if-conversion
//! and the finiteness proof. Re-exports only; the files import each other
//! directly. `Elaborate` is `elab`'s, re-exported so `ir.Elaborate` keeps its
//! name (ARCHITECTURE.md Phase 4); §1 marks the `elab` edge [A] until
//! Phase 11. `kernels` holds the value folds and kernel tables it reads.

/// SSA instruction set every stage after lowering reads.
pub const Mir = @import("mir.zig");
/// §4.5 / §5.10.3 / §9.17 the stateful operator set, `OpKind`.
pub const op = @import("op.zig");
/// Dependency and freedom lattices over a finished MIR.
pub const Analysis = @import("analysis.zig");
/// SSA construction used while lowering.
pub const Ssa = @import("ssa.zig");
/// Hierarchy flattening, AST → one flat module (§6).
pub const Elaborate = @import("elab").Elaborate;
/// AST → MIR lowering.
pub const Lower = @import("lower.zig");
/// What lowering hands every later stage, and the row types of its tables.
pub const Lowered = @import("lowered.zig");
/// §9.15 simulation parameters: compile-time value, host field, run-time rows.
pub const simparam = @import("simparam.zig");
/// Branch → `select` conversion over MIR.
pub const ifconv = @import("ifconv.zig");
/// Per-unit float-mode verdict from the finiteness proof.
pub const proof = @import("proof.zig");
/// The MIR's postcondition, checked after lowering and each MIR pass.
pub const verify = @import("verify.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
