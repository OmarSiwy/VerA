//! The frontend's public API: Verilog-AMS source text in, AST out
//! (preprocessor, lexer, parser; LRM clauses 2 to 10 and annexes D and E).
//! Depends on `base`, `diag` and `kernels`; `elab`, `analog` and the backends
//! import this layer, never the reverse (`ir` does not import it at all).

/// §2.6.1 integer literals and the IEEE 1364-2005 §5 four-state operations
/// on them: `kernels.Integer`, re-exported for callers that reach it
/// through `frontend`.
pub const Integer = @import("kernels").Integer;
/// Token tags, the annex B keyword table and the §10.6 keyword sets.
pub const token = @import("token.zig");
/// Clause 10 directives and comment stripping: source files in, one text out.
pub const Preprocessor = @import("preprocessor.zig");
/// The lexer file; its cursor type is `Lexer.Lexer`, its token list
/// `Lexer.TokenList`.
pub const Lexer = @import("lexer.zig");
/// The AST; `Ast.SourceFile` is the root every later stage reads.
pub const Ast = @import("ast.zig");
/// The parser file; its state type is `Parser.Parser`.
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

/// Runs a recursive walk on a stack reserved for its nesting depth, so
/// nesting is bounded by memory: `base.deep_stack`, re-exported for callers
/// that reach it through `frontend`.
pub const deep_stack = @import("base").deep_stack;

test {
    @import("std").testing.refAllDecls(@This());
}
