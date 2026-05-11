//! What every `plan/` function reads: the lowered module and the facts
//! derived from it, as a value rather than the emitter, so a plan takes
//! inputs and returns a value. Field names match `Gen`'s.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lowered = @import("ir").Lowered;

/// The lowered module and the analysis over it, borrowed for one compilation.
pub const Input = struct {
    /// The per-compilation arena: every plan is allocated here and freed with it.
    arena: std.mem.Allocator,
    mir: *const Mir,
    an: *const Analysis,
    lowered: *const Lowered,
};
