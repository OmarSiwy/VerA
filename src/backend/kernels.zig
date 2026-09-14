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
//! It is also the DEPENDENCY door for the one kernel the compiler itself
//! calls: `ir/elaborate.zig` needs `rng_kernels` to fold §9.13 distribution
//! calls at elaboration time. That was a relative `@import("../backend/…")`,
//! the single edge contradicting root.zig's claim that `ir/` never imports
//! `backend/`. Routed through here it becomes `ir -> kernels`, which is honest
//! — rng_kernels imports nothing at all — and keeps the file in ONE module
//! instead of compiling into both.
//!
//! Nothing imports this file for its TEST block; that half is a build root.
//! Adding the root to a device's import graph would pull test code into
//! generated source.

//! All six are exported, not just the one `ir` needs: a kernel file may live in
//! exactly ONE module, and codegen.zig's tests import every one of them. Reach
//! them by relative path from inside `vera` and the compiler says so —
//! "file exists in modules 'vera' and 'kernels'" — which is the duplicate this
//! door exists to prevent.

pub const str_kernels = @import("str_kernels.zig");
pub const table_kernels = @import("table_kernels.zig");
pub const rng_kernels = @import("rng_kernels.zig");
pub const filter_kernels = @import("filter_kernels.zig");
pub const file_kernels = @import("file_kernels.zig");
pub const limit_kernels = @import("limit_kernels.zig");

test {
    _ = str_kernels;
    _ = table_kernels;
    _ = rng_kernels;
    _ = filter_kernels;
    _ = file_kernels;
    _ = limit_kernels;
}
