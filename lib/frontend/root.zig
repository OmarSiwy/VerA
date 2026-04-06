//! Frontend — text to AST, and the top of this layer's file DAG.
//!
//! Re-export only. The leaves below import each other and `diag` directly and
//! never this file, so the pipeline order stays readable on disk:
//!
//!   .va text
//!     → Preprocessor  (class 1)  text → text, `include + SPICE card synthesis
//!     → Lexer/token   (class 1)  text → tokens (SoA {tag, start})
//!     → Parser/Ast    (class 2)  tokens → AST (SoA, u32 handles)
//!
//! The layer depends on `diag` and nothing else in the engine: `ir/` and
//! `backend/` import THIS, never the reverse, which is the split that lets a
//! second frontend lower into the same MIR.

pub const Integer = @import("integer.zig");
pub const token = @import("token.zig");
pub const Preprocessor = @import("preprocessor.zig");
pub const Lexer = @import("lexer.zig");
pub const Ast = @import("ast.zig");
pub const Parser = @import("parser.zig");

/// §4.2 constant_expression: the one folder every stage shares.
pub const constfold = @import("constfold.zig");

/// SPICE `.MODEL`/`.SUBCKT` card synthesis. Reached through `Preprocessor`
/// in the pipeline; exported so its tests have a name and a caller can
/// synthesize without running the preprocessor.
pub const spice_cards = @import("spice_cards.zig");

/// §3.7/§6.5.3 the wreal STRUCTURE rules over a parsed file (E0918, E0919):
/// one owner for the device compile and the digital runner.
pub const wreal_rules = @import("wreal_rules.zig");

test {
    _ = Integer;
    _ = token;
    _ = Preprocessor;
    _ = Lexer;
    _ = Ast;
    _ = Parser;
    _ = constfold;
    _ = spice_cards;
    _ = wreal_rules;
}
