//! What every `plan/` function reads: the lowered module and the facts derived
//! from it. A value, not a pointer to the emitter — which is the whole point of
//! the directory (ARCHITECTURE.md §2: a plan takes inputs and returns a value).
//!
//! The field names are `Gen`'s, so a planner cut out of the emitter keeps its
//! body verbatim: `self.mir`, `self.an`, `self.lowered`, `self.arena`.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lowered = @import("ir").Lowered;

pub const Input = struct {
    /// The per-compilation arena: every plan is allocated here and freed with it.
    arena: std.mem.Allocator,
    mir: *const Mir,
    an: *const Analysis,
    lowered: *const Lowered,
};
