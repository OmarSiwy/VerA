//! IR: AST → elaborated design (§6.2.2) → SSA MIR → analysis, if-conversion
//! and the finiteness proof. Re-exports only; the files import each other
//! directly. Elaboration imports no lowering file (its closure is `elaborate/`,
//! `dist.zig`, `discipline_rules.zig`), so it could be its own module; it stays
//! here because that split would add a `module_specs` row for an edge nothing
//! crosses. `kernels` is a dependency so §9.13 folds use the device's rng.

/// SSA instruction set every stage after lowering reads.
pub const Mir = @import("mir.zig");
/// §4.5 / §5.10.3 / §9.17 the stateful operator set, `OpKind`.
pub const op = @import("op.zig");
/// Dependency and freedom lattices over a finished MIR.
pub const Analysis = @import("analysis.zig");
/// SSA construction used while lowering.
pub const Ssa = @import("ssa.zig");
/// Hierarchy flattening, AST → one flat module (§6).
pub const Elaborate = @import("elaborate.zig");
/// AST → MIR lowering.
pub const Lower = @import("lower.zig");
/// What lowering hands every later stage (lower/tables.zig).
pub const Lowered = Lower.Lowered;
/// Branch → `select` conversion over MIR.
pub const ifconv = @import("ifconv.zig");
/// Per-unit float-mode verdict from the finiteness proof.
pub const proof = @import("proof.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
