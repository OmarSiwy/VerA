//! The AST handles and scalar enums that outlive the parse: `Ast` aliases
//! them, and `Lowered` carries them (a parameter's type, a port's direction,
//! the expression a D2A event term is keyed by) without importing the
//! frontend. Imports only std.
//!
//! LRM clauses this file's code cites: §3.1, §3.2, §3.3, §3.4.1, §4.7.2.3,
//! §6.5.2.2, A.1.3, A.1.4, A.2.1.1.

const std = @import("std");

/// Handle into the expression columns (LRM annex A expression grammar).
pub const ExprId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Scalar data types. LRM §3.1, §3.2, §3.3, §3.4.1.
/// `realtime` collapses to `.real` and `time` to `.integer` (A.2.1.1
/// parameter_type); the distinction is meaningless in the analog kernel.
/// `.unspecified` is `parameter p = <expr>;` with no type keyword: §3.4.1 derives
/// the type from the default expression, which only lowering can fold. Lowering
/// resolves it; codegen never sees it.
pub const Type = enum(u8) { real, integer, string, unspecified };

/// Port / function-argument direction. LRM §6.5.2.2 (ports), §4.7.2.3
/// (function output/inout args). `.unspecified` is a port named in
/// `list_of_ports` whose direction arrives later as a `port_declaration`
/// (A.1.3 / A.1.4).
pub const Direction = enum(u8) { unspecified, input, output, inout };
