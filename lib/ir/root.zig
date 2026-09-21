//! IR — AST to proven MIR, and the top of this layer's file DAG.
//!
//! Re-export only. The leaves import each other directly, and they have to:
//! `lower.zig` and `elaborate.zig` are mutually recursive, because elaboration
//! (AST → flat design, §6.2.2) and lowering (design → MIR) are two halves of
//! one transformation, not two passes in sequence. That cycle is why this
//! layer is ONE module — it is a boundary around the cycle, not a claim that
//! no cycle exists.
//!
//!   AST
//!     → elaborate.zig  (class 9)     AST → flat design (§6.2.2)
//!     → lower.zig + ssa.zig → mir.zig (classes 3,4,5,7,9)
//!     → analysis.zig                 dependency + freedom lattices over MIR
//!     → ifconv.zig                   branch → select conversion
//!     → proof.zig      (class 6)     MIR → per-unit finiteness verdict
//!
//! Depends on `frontend`, `diag`, and `kernels` — the last only because
//! elaboration folds §9.13 distribution calls with the same rng the device
//! will run, so the constant it folds and the value it emits agree.

pub const Mir = @import("mir.zig");
/// §4.5 / §5.10.3 / §9.17 operator facts, one row per operator. A leaf: it
/// imports nothing but `std`, and everything that used to carry a switch over
/// the operator set reads a column of it.
pub const op = @import("op.zig");
pub const Analysis = @import("analysis.zig");
pub const Ssa = @import("ssa.zig");
pub const Elaborate = @import("elaborate.zig");
pub const Lower = @import("lower.zig");
pub const ifconv = @import("ifconv.zig");
pub const proof = @import("proof.zig");

test {
    _ = Mir;
    _ = op;
    _ = Analysis;
    _ = Ssa;
    _ = Elaborate;
    _ = Lower;
    _ = ifconv;
    _ = proof;
}
