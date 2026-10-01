//! Analog lowering: an elaborated design (`elab`, §6.2.2) → SSA `Mir` plus the
//! `Lowered` tables (`ir`), through SSA construction. Re-exports only; the
//! files import each other directly. Code after lowering reads `ir`'s types,
//! not this module (ARCHITECTURE.md Phase 5); the spine (`vera`) and the
//! tests that lower source import it.

/// AST → MIR lowering.
pub const Lower = @import("lower.zig");
/// SSA construction used while lowering.
pub const Ssa = @import("ssa.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
