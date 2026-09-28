//! `base`: the leaf tables every tier may import. Imports only std.
//! `deep_stack` runs a recursive walk on a stack reserved for its depth, the
//! interner maps §2.7/§2.8 text to `StrId`s, and `BigArena` is the
//! compilation's arena. The aliases below are the module's API.

/// Runs a recursive walk on a stack reserved for its nesting depth, so
/// nesting is bounded by memory. Every stage that recurses over source
/// nesting (the parser, lowering, the digital engine) shares it.
pub const deep_stack = @import("deep_stack.zig");
/// Handle into a `StringInterner`. LRM §2.8 identifiers, §2.7 strings.
pub const StrId = @import("interner.zig").StrId;
/// Identifier and string intern table, ids in insertion order.
pub const StringInterner = @import("interner.zig").StringInterner;
/// The compilation arena (`vera.CompileResult.arena`), large blocks passed
/// through to the backing allocator.
pub const BigArena = @import("big_arena.zig");

test {
    _ = deep_stack;
    _ = @import("interner.zig");
    _ = BigArena;
}
