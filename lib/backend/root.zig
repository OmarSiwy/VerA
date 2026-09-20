//! Backend — proven MIR to a loadable device, and the top of this layer's
//! file DAG.
//!
//! Re-export only. The leaves import each other directly and mutually:
//! `codegen.zig` calls into `cg_display`/`cg_filters`/`cg_limit`/`unit_plan`
//! and each of them reads `codegen.Gen` back. That cycle is why this is ONE
//! module — the same reasoning as `ir`, where the boundary goes around the
//! cycle rather than pretending it is absent.
//!
//!   MIR
//!     → naming.zig + codegen.zig   (classes 4,5,8,10)  MIR → device.zig
//!     → unit_plan/cg_*             per-unit emission strategy
//!     → tb.zig                     the Verilog-A testbench artifact
//!     → orchestrator.zig           (§8.3 ABI) device.zig → .so + GPU kernels
//!
//! Depends on `ir`, `frontend`, `diag` and `kernels`. The kernel files are
//! `@embedFile`d into the emitted device AND `@import`ed by codegen's tests
//! through the `kernels` module, so what the tests check is byte-for-byte what
//! the device runs — and the file still belongs to exactly one module.

pub const naming = @import("naming.zig");
pub const codegen = @import("codegen.zig");
pub const UnitPlan = @import("unit_plan.zig");
pub const cg_display = @import("cg_display.zig");
pub const cg_filters = @import("cg_filters.zig");
pub const cg_limit = @import("cg_limit.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const tb = @import("tb.zig");

test {
    _ = naming;
    _ = codegen;
    _ = UnitPlan;
    _ = cg_display;
    _ = cg_filters;
    _ = cg_limit;
    _ = orchestrator;
    _ = tb;
}
