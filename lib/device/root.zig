//! Device module root: proven MIR in, device.zig text out; `zigbuild` builds
//! it. Re-export only. The files import each other mutually (`codegen.zig`
//! calls `cg_*` and `codegen/plan/unit.zig`, which read `codegen.Gen` back),
//! so the module boundary goes around that cycle. Depends on `ir`, `prove`,
//! `diag`, `kernels` (the text spliced into every device) and `zigbuild`
//! (`Output`); the tests also take `frontend` and `analog`, to parse and
//! lower source, and `dynlib`, to load what they built. Neither the testbench (`exe`) nor `--emit-verilog`
//! (`verilog`) is reachable from here.
//!
//! The three `cg_*` entries are here for their tests alone: `codegen.zig`'s
//! `test` block does not reach them (`docs/seams/s1-codegen.md` at 6e59b3d4^,
//! proposal 1).

/// MIR to device.zig source.
pub const codegen = @import("codegen.zig");
/// §9.4 display and §9.7.3 severity tasks to `std.debug.print`.
pub const cg_display = @import("cg_display.zig");
/// §4.5.11 `laplace_*` and §4.5.12 `zi_*` filter planning and emission.
pub const cg_filters = @import("cg_filters.zig");
/// §4.5.15 `$limit` to the contract's `limit` and `seed` hooks.
pub const cg_limit = @import("cg_limit.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
