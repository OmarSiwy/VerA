//! The SPICE deck runner's analyses, over one VerA device (`Circuit`): the
//! operating point (`op`), `.tran` (`tran`) and `.noise` (`noise`), on
//! direct Newton (`converger`) and dense LU (`dense_lu`). Copied from
//! OmarSiwy/ESPice at 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d, CPU paths
//! only; each file's header names its origin and what was adapted or left
//! out. The generated testbench calls `deck` for `//! tran` and `//! onoise`
//! (`lib/backend/tb/runner.zig`); `zig build test-spice` grades the result.
//! Host-side only: nothing here reaches the device text, which stays
//! GPU-compilable.

/// One device as the system the analyses solve.
pub const Circuit = @import("circuit.zig").Circuit;
/// Direct Newton and its acceptance gates.
pub const converger = @import("converger.zig");
/// The operating point (plain Newton from the cold start).
pub const op = @import("op.zig");
/// Transient with LTE, breakpoint, `$bound_step` and state-flip control.
pub const tran = @import("tran.zig");
/// Small-signal output noise density.
pub const noise = @import("noise.zig");
/// Dense LU, plain and stacked-real complex.
pub const dense_lu = @import("dense_lu.zig");
/// Companion coefficients and the LTE bound.
pub const integrator = @import("integrator.zig");
/// The `//! tran` / `//! onoise` entry points a generated testbench calls.
pub const deck = @import("deck.zig");

test {
    _ = converger;
    _ = tran;
    _ = dense_lu;
    _ = integrator;
    _ = deck;
}
