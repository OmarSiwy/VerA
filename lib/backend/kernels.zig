//! Module root for the device-runtime kernel files: Zig source text that
//! `codegen/kernel_text.zig` `@embedFile`s verbatim into every generated device
//! that needs it, and that this module also compiles as ordinary Zig for the
//! callers that run the same numerics outside a device.
//!
//! Each kernel file is one data domain, spliced only into a device that uses
//! it, and owns the state it declares:
//!   str_kernels    §9.5.3/§9.5.4.2 format and scan; per-site `zSBuf` rows and
//!                  `zMonitor` latches (file scope in the device)
//!   file_kernels   §9.5 descriptor table `zf_slots`, `zf_written` (file scope)
//!   table_kernels  §9.21 interpolation; stack scratch only
//!   rng_kernels    §9.13 Table 9-10; the seed is the caller's variable
//!   filter_kernels §4.5.11/§4.5.12 sections; histories live in `Instance`
//!   limit_kernels  §4.5.15 SPICE limiters; pure
//!   timer_kernels  §5.10.3.3 timer deadlines; the controls live in `Instance`
//! The `Instance`/`Model` fields that hold filter, timer and rng state are
//! codegen's: these files only read and write the slots they are passed.
//!
//! A kernel file must compile alone inside a device: it opens with `//`, not
//! `//!` (a doc header cannot sit mid-file), names `std` by a private alias, and
//! calls no other kernel file. Its bytes are device text, so editing one moves
//! every golden that embeds it, so a kernel file holds no `test` block: its
//! tests are `kernels/test.zig`, which this root's `test` block pulls in. No
//! device imports this root. `zig build test-kernels` runs them.

/// `tools/contract.zig`'s `abi_version`, re-exported for `backend`, which
/// cannot import `contract` itself: codegen stamps it into every device.
pub const abi_version = @import("contract").abi_version;
/// §9.5.3/§9.5.4.2 string formatting and scanning; the digital engine's
/// `%e/%f/%g` formatter (`zCReal`).
pub const str_kernels = @import("kernels/str_kernels.zig");
/// §9.21 `$table_model` interpolation.
pub const table_kernels = @import("kernels/table_kernels.zig");
/// §9.13 probabilistic distribution functions; also elaboration's literal
/// folds (`ir/elaborate/clone.zig`) and the digital engine's IEEE 1364 §17.9
/// `$dist_*`, so every path draws the same sequence from a seed.
pub const rng_kernels = @import("kernels/rng_kernels.zig");
/// §4.5.11/§4.5.12 filter numerics.
pub const filter_kernels = @import("kernels/filter_kernels.zig");
/// §9.5 file-descriptor I/O; also the digital engine's IEEE 1364 §17.2
/// descriptor table when no host shares one (`sim/digital/system.zig` `own`).
pub const file_kernels = @import("kernels/file_kernels.zig");
/// §4.5.15 SPICE limiting functions.
pub const limit_kernels = @import("kernels/limit_kernels.zig");
/// §5.10.3.3 absolute timer scheduling, also used by the mixed coordinator.
pub const timer_kernels = @import("kernels/timer_kernels.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("kernels/test.zig");
}
