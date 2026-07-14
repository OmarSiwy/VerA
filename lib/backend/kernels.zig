//! Module root for the device-runtime kernel files, which are `@embedFile`d
//! verbatim into generated devices. Each file belongs to exactly one module, so
//! codegen's tests and `ir/elaborate.zig` (§9.13 folding via `rng_kernels`)
//! reach them through here; `zig build test-kernels` runs their tests alone.
//! No device imports this file: its `test` block would pull test code in.

/// §9.5.3/§9.5.4.2 string formatting and scanning.
/// `tools/contract.zig`'s `abi_version`, re-exported for `backend`, which
/// cannot import `contract` itself: codegen stamps it into every device.
pub const abi_version = @import("contract").abi_version;
pub const str_kernels = @import("str_kernels.zig");
/// §9.21 `$table_model` interpolation.
pub const table_kernels = @import("table_kernels.zig");
/// §9.13 probabilistic distribution functions.
pub const rng_kernels = @import("rng_kernels.zig");
/// §4.5.11/§4.5.12 filter numerics.
pub const filter_kernels = @import("filter_kernels.zig");
/// §9.5 file-descriptor I/O.
pub const file_kernels = @import("file_kernels.zig");
/// §4.5.15 SPICE limiting functions.
pub const limit_kernels = @import("limit_kernels.zig");
/// §5.10.3.3 absolute timer scheduling, also used by the mixed coordinator.
pub const timer_kernels = @import("timer_kernels.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
