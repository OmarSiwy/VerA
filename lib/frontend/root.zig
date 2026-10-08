//! The frontend's public API: Verilog-AMS source text in, AST out
//! (preprocessor, lexer, parser; LRM clauses 2 to 10 and annexes D and E).
//! Depends only on `diag`; `ir/` and `backend/` import this layer, never the
//! reverse.

pub const Integer = @import("integer.zig");
pub const token = @import("token.zig");
pub const Preprocessor = @import("preprocessor.zig");
pub const Lexer = @import("lexer.zig");
pub const Ast = @import("ast.zig");
pub const Parser = @import("parser.zig");

/// The §4.2 constant_expression folder every stage shares.
pub const constfold = @import("constfold.zig");

/// SPICE `.MODEL`/`.SUBCKT` card synthesis (annex E.2). The pipeline reaches
/// it through `Preprocessor`; exported so a caller can synthesize without
/// running the preprocessor.
pub const spice_cards = @import("spice_cards.zig");

/// §3.7/§6.5.3 structural `wreal` rules, shared by the elaborator and the
/// digital runner.
pub const wreal = @import("wreal.zig");

/// IEEE 1364-2005 §13.2 library map files.
pub const libmap = @import("libmap.zig");

test {
    @import("std").testing.refAllDecls(@This());
    // specification/TESTING.md L3: the four-state reference `Integer` is judged by.
    _ = @import("ref4.zig");
}
