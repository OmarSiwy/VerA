//! Backend module root: proven MIR in, device.zig, testbench and loadable `.so` out.
//! Re-export only. The files import each other mutually (`codegen.zig` calls
//! `cg_*` and `codegen/plan/unit.zig`, which read `codegen.Gen` back), so the
//! module boundary goes around that cycle. Depends on `ir`, `frontend`, `diag`
//! and `kernels`.
//!
//! The three `cg_*` entries are here for their tests alone: `codegen.zig`'s
//! `test` block does not reach them (`docs/seams/s1-codegen.md` proposal 1).

/// Stable declaration names and the canonical unit order.
pub const naming = @import("naming.zig");
/// MIR to device.zig source.
pub const codegen = @import("codegen.zig");
/// MIR to a behavioural Verilog module (`--emit-verilog`).
pub const beh_verilog = @import("beh_verilog.zig");
/// §9.4 display and §9.7.3 severity tasks to `std.debug.print`.
pub const cg_display = @import("cg_display.zig");
/// §4.5.11 `laplace_*` and §4.5.12 `zi_*` filter planning and emission.
pub const cg_filters = @import("cg_filters.zig");
/// §4.5.15 `$limit` to the contract's `limit` and `seed` hooks.
pub const cg_limit = @import("cg_limit.zig");
/// device.zig to a versioned `.so` (§8.3 device-side ABI).
pub const orchestrator = @import("orchestrator.zig");
/// The self-checking testbench artifact built from `//!` directives.
pub const tb = @import("tb.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
