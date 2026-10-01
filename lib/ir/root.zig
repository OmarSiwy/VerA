//! IR: the SSA MIR and the tables lowering hands every later stage, as types
//! and their column functions. Re-exports only; the files import each other
//! directly. Lowering is `analog`'s and the passes over the MIR are `prove`'s
//! (ARCHITECTURE.md Phase 5); both import this module, so it imports neither.
//! `Elaborate` is `elab`'s, re-exported so `ir.Elaborate` keeps its name
//! (Phase 4); §1 marks the `frontend` and `elab` edges [A] until Phase 11.
//! `kernels` holds the value folds and kernel tables it reads.

/// SSA instruction set every stage after lowering reads.
pub const Mir = @import("mir.zig");
/// §4.5 / §5.10.3 / §9.17 the stateful operator set, `OpKind`.
pub const op = @import("op.zig");
/// Hierarchy flattening, AST → one flat module (§6).
pub const Elaborate = @import("elab").Elaborate;
/// What lowering hands every later stage, and the row types of its tables.
pub const Lowered = @import("lowered.zig");
/// §9.15 simulation parameters: compile-time value, host field, run-time rows.
pub const simparam = @import("simparam.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
