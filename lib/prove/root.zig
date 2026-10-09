//! The passes over a lowered MIR: `Mir` + `Lowered` (`ir`) in; CFG and value
//! facts, if-converted MIR, a float-mode verdict per unit, the setup tiers
//! (solve invariance, the §3.2 held-row mask) and the MIR postcondition out.
//! Re-exports only; the files import each other directly.
//! `analog` is imported only by tests that lower source (`proof/test.zig`) or
//! build SSA (`ssa_test.zig`), and `frontend` only by `proof/test.zig`, which
//! parses that source; Zig cannot scope either to tests (ARCHITECTURE.md §1
//! row 11). `contract`: the proof's transfer functions use the devices'
//! `exp`/`log`/`pow` (`contract.gm`).

/// Dependency and freedom lattices over a finished MIR.
pub const Analysis = @import("analysis.zig");
/// Branch → `select` conversion over MIR.
pub const ifconv = @import("ifconv.zig");
/// Per-unit float-mode verdict from the finiteness proof.
pub const proof = @import("proof.zig");
/// The MIR's postcondition, checked after lowering and each MIR pass.
pub const verify = @import("verify.zig");
/// The setup tiers: solve invariance (`Sinv`), which codegen reads as a
/// value, and `pruneHeld`'s held-row mask, which lowering applies.
pub const setup = @import("setup.zig");
/// What a setup tier or a codegen `plan/` function reads.
pub const Input = @import("input.zig").Input;
/// The literal string at a call argument, or null.
pub const strArg = @import("input.zig").strArg;
/// Test-only: a hand-built `Mir` + `Lowered` for planner tests.
pub const Fixture = @import("fixture.zig").Fixture;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ssa_test.zig");
}
