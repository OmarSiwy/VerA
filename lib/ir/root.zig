//! IR — AST to proven MIR, and the top of this layer's file DAG.
//!
//! Re-export only. The leaves import each other directly. Elaboration imports
//! no lowering file: its closure is `elaborate/`, `dist.zig` and
//! `discipline_rules.zig`, which lowering imports too. It stays in this module
//! because a module of its own would own those two shared leaves and add a
//! `module_specs` row, a minor release, to enforce one edge nothing crosses.
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
/// §4.5 / §5.10.3 / §9.17 the stateful operator set, `OpKind`.
pub const op = @import("op.zig");
pub const Analysis = @import("analysis.zig");
pub const Ssa = @import("ssa.zig");
pub const Elaborate = @import("elaborate.zig");
pub const Lower = @import("lower.zig");
/// What lowering hands every later stage — lower/tables.zig.
pub const Lowered = Lower.Lowered;
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
