//! Test root for the emitted device-runtime kernels.
//!
//! These six files are the code every generated device actually runs: they are
//! `@embedFile`d verbatim into `device.zig` and `@import`ed by codegen.zig's
//! tests, so one source serves both. That import is also the only thing that
//! put their tests in a build — which meant reaching them required compiling
//! codegen.zig (10k lines) and the whole IR behind it.
//!
//! This root exists so `zig build test-kernels` runs them on their own. Every
//! file below is a leaf: `table/rng/filter_kernels` import nothing at all,
//! `str/file_kernels` only std, and `limit_kernels`' `contract` import sits
//! behind a `comptime k_dev` that is false on the host.
//!
//! Nothing imports THIS file — it is a build root, not a dependency. Adding it
//! to a device's import graph would pull test code into generated source.

test {
    _ = @import("str_kernels.zig");
    _ = @import("table_kernels.zig");
    _ = @import("rng_kernels.zig");
    _ = @import("filter_kernels.zig");
    _ = @import("file_kernels.zig");
    _ = @import("limit_kernels.zig");
}
