//! Test-only: the planner fixture, which moved to `prove` with the setup
//! tiers (ARCHITECTURE.md Phase 6). `naming.zig` and `beh_verilog.zig` still
//! reach it here, the R2 edge Phase 8 deletes with this file.

/// See `prove.Fixture`.
pub const Fixture = @import("prove").Fixture;
