//! The SPICE deck runner's analyses, over one VerA device (`Circuit`): the
//! operating point (`op`), `.tran` (`tran`) and `.noise` (`noise`), on
//! direct Newton (`converger`) and dense LU (`dense_lu`). Copied from
//! OmarSiwy/ESPice at 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d, CPU paths
//! only; each file's header names its origin and what was adapted or left
//! out. In: a derived and set-up device `Model`/`Instance` and a deck's
//! analysis card; out: one stderr row per accepted point or frequency. The
//! generated testbench calls `deck` for `//! tran` and `//! onoise`
//! (`lib/backend/tb/runner.zig`); `zig build test-spice` grades the result.
//! Host-side only: nothing here reaches the device text, which stays
//! GPU-compilable. The LRM clauses each file implements are in its header.
//!
//! The module's API is `deck` alone; every other file is reached only from
//! inside it.

/// The `//! tran` / `//! onoise` entry points a generated testbench calls.
pub const deck = @import("deck.zig");

const circuit = @import("circuit.zig");
const converger = @import("converger.zig");
const op = @import("op.zig");
const tran = @import("tran.zig");
const noise = @import("noise.zig");
const dense_lu = @import("dense_lu.zig");
const integrator = @import("integrator.zig");

test {
    _ = circuit;
    _ = converger;
    _ = op;
    _ = noise;
    _ = tran;
    _ = dense_lu;
    _ = integrator;
    _ = deck;
}
