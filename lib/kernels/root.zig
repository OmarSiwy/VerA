//! Module root for the device-runtime kernel files. Kernel source -> two
//! consumers of the same bytes: device text, spliced verbatim into every
//! generated device that needs it (`codegen/kernel_text.zig` reads it as
//! `text.*`, the `@embedFile`s below, since an embed cannot leave its own
//! module's directory), and ordinary Zig compiled here for the callers that
//! run the same numerics outside a device. Beside them sit the host-only
//! runtime files, never spliced: `integer.zig` (judged by `ref4.zig`),
//! `fold.zig` and `fmt.zig`, so the compiler and `sim` share one copy of
//! each operator's semantics.
//! LRM: §2.6.1, §2.7, §3.2, §4.2, §4.3, §4.5, §4.5.11, §4.5.12, §4.5.15,
//! §5.10.3.3, §9.4.1, §9.4.3, §9.5, §9.5.3, §9.5.4.2, §9.13, §9.17.3, §9.21;
//! IEEE 1364-2005 §5, §17.1, §17.2.4, §17.9.3.
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
//!   hist_kernels   §4.5.7 absdelay ring and its thinning; the samples live in `Instance`
//!   wide_kernels   IEEE 1364 §5.4 integers past 32 bits; pure, stack only
//!   ops_kernels    §4.5 analog operators over `S`; the accepted state is the
//!                  caller's. Its functions are private device text, so only
//!                  AstGen checks it here
//! The `Instance`/`Model` fields that hold filter, timer and rng state are
//! codegen's: these files only read and write the slots they are passed.
//!
//! A kernel file must compile alone inside a device: it names `std` by a
//! private alias and calls no other kernel file. It opens with `//`, not `//!`
//! (a doc header cannot sit mid-file), except `timer_kernels.zig` and
//! `hist_kernels.zig`, which open with a `//!` paragraph that
//! `kernel_text.timer_txt` and `kernel_text.hist_txt` cut off at the first
//! blank line. Its bytes are device text, so editing one moves every golden that
//! embeds it, comments included, and a kernel file holds no `test` block: its
//! tests are `test.zig`, which this root's `test` block pulls in. No
//! device imports this root. `zig build test-kernels` runs them.

/// `tools/contract.zig`'s `vera_version`, re-exported for `device`, which
/// cannot import `contract` itself: codegen stamps it into every device.
pub const vera_version = @import("contract").vera_version;
/// §9.5.3/§9.5.4.2 string formatting and scanning; the digital engine's
/// `%e/%f/%g` formatter (`zCReal`).
pub const str_kernels = @import("str_kernels.zig");
/// §9.21 `$table_model` interpolation.
pub const table_kernels = @import("table_kernels.zig");
/// §9.13 probabilistic distribution functions; also elaboration's literal
/// folds (`elab/elaborate/clone.zig`) and the digital engine's IEEE 1364 §17.9
/// `$dist_*`, so every path draws the same sequence from a seed.
pub const rng_kernels = @import("rng_kernels.zig");
/// §4.5.11/§4.5.12 filter numerics.
pub const filter_kernels = @import("filter_kernels.zig");
/// §9.5 file-descriptor I/O; also the digital engine's IEEE 1364 §17.2
/// descriptor table when no host shares one (`sim/digital/system.zig` `own`).
/// The table is process-global: every caller in one process shares its
/// thirty channels.
pub const file_kernels = @import("file_kernels.zig");
/// §4.5.15 SPICE limiting functions.
pub const limit_kernels = @import("limit_kernels.zig");
/// §5.10.3.3 absolute timer scheduling, also used by the mixed coordinator.
pub const timer_kernels = @import("timer_kernels.zig");
/// §4.5.7 the absdelay ring and its thinning.
pub const hist_kernels = @import("hist_kernels.zig");
/// IEEE 1364 §5.4 integers of any width (`lower/wide.zig`'s trees).
pub const wide_kernels = @import("wide_kernels.zig");
/// §4.5 the analog operator kernels (`zIdt`, `zSlew`, `zTransition`, ...): device text only.
pub const ops_kernels = @import("ops_kernels.zig");

/// §2.6.1 integer literals and the IEEE 1364-2005 §5 four-state operations
/// on them: the one reference every engine's operators are judged by
/// (`ref4.zig` checks it). Host Zig, not device text.
pub const Integer = @import("integer.zig");
/// IEEE 1364-2005 §17.1 value and time text over `Integer` literals, shared
/// by the digital interpreter and a native executable (`sim`). Host Zig.
pub const fmt = @import("fmt.zig");
/// The §4.2 value folds (`Const`, `unary`, `binary`, `math`, `wrap32`,
/// `ipow32`, `clog2`, `strToInt`) and the A.8.6 operator enums they take:
/// one answer for a parameter default (`frontend.constfold`) and a folded
/// MIR opcode (`ir.opcode`). Host Zig.
pub const fold = @import("fold.zig");
/// §9.5.1 Table 9-24's `$fopen` type strings, the fifteen of IEEE 1364-2005
/// §17.2.1 Table 17-7: one list for lowering's E0889 and the digital engine's
/// `$fopen` (`sim/digital/system.zig` `fileType`). Host Zig.
pub const fopen_types = @import("std").StaticStringMap(void).initComptime(.{
    .{"r"},   .{"rb"}, .{"w"},   .{"wb"},  .{"a"},  .{"ab"},  .{"r+"},  .{"r+b"},
    .{"rb+"}, .{"w+"}, .{"w+b"}, .{"wb+"}, .{"a+"}, .{"a+b"}, .{"ab+"},
});

/// Each kernel file's bytes, for `codegen/kernel_text.zig` to splice into a
/// device: `@embedFile` reaches only files under its own module's root.
pub const text = struct {
    pub const str = @embedFile("str_kernels.zig");
    pub const table = @embedFile("table_kernels.zig");
    pub const rng = @embedFile("rng_kernels.zig");
    pub const filter = @embedFile("filter_kernels.zig");
    pub const file = @embedFile("file_kernels.zig");
    pub const limit = @embedFile("limit_kernels.zig");
    pub const timer = @embedFile("timer_kernels.zig");
    pub const hist = @embedFile("hist_kernels.zig");
    pub const wide = @embedFile("wide_kernels.zig");
    pub const ops = @embedFile("ops_kernels.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test.zig");
    _ = Integer;
    _ = fmt;
    _ = fold;
    // The four-state reference `Integer` is judged by.
    _ = @import("ref4.zig");
}
