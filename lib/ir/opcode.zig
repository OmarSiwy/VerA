//! IR facts about each `Mir.Opcode`, one row per opcode.
//!
//! `table` is a `std.EnumArray`, so it is total by construction: add an opcode
//! to `Mir.Opcode` and this file stops compiling until its row exists. That is
//! the point. fix-lower's `.ipow` had to be found by hand at seven sites while
//! a score of `else =>` arms took a default silently; here it is one row.
//!
//! IR facts only. `lib/ir` does not know the target is Zig (analysis.zig's
//! header), so the Zig spellings of an opcode are the backend's table, not a
//! column here.
//!
//! DOD: comptime rows in `.rodata`, read with one indexed load. No allocation.

const std = @import("std");
const Mir = @import("mir.zig");
const Opcode = Mir.Opcode;

/// LRM Tables 4-14 / 4-15 domains. The operand of each must be proven in-domain
/// (else compile error), EXCEPT the "All x" group which governs float mode only.
pub const Domain = enum {
    all, // exp, expm1, sinh, cosh, tanh, sin, cos, floor, ceil, min, max, abs — §4.3.1/§4.3.2
    positive, // ln, log10                                   §4.3.1  (x > 0)
    gt_neg_one, // ln1p                                       §4.3.1  (x > -1)
    non_negative, // sqrt                                     §4.3.1  (x >= 0)
    unit_closed, // asin, acos                                §4.3.2  (-1 <= x <= 1)
    unit_open, // atanh                                       §4.3.2  (-1 < x < 1)
    ge_one, // acosh                                          §4.3.2  (x >= 1)
    nonzero_divisor, // '/', '%'                              §4.2 / §4.3.1
    tan_poles, // tan: x != n(π/2), n odd                     §4.3.2
    pow_sign, // pow(x,y) sign rules                          §4.3.1 Table 4-14
};

pub const Info = struct {
    /// Operand shape; drives `Mir.instData` decoding.
    class: Mir.OpClass,
    /// The result is a §3.2 integer rather than a real. Relational, equality
    /// and logical operators yield integer 0/1 (§4.2.5, §4.2.7, §4.2.8).
    int: bool = false,
    /// The result is 0 or 1: the relational, equality and logical operators.
    bool01: bool = false,
    /// A predicate the prover's `condFacts` can mine and if-conversion's
    /// `peelToBool` may peel: the §4.2.5/§4.2.7 comparisons and `!`. NOT `&&`
    /// and `||`, which are 0/1 but carry no fact about an operand.
    predicate: bool = false,
    /// The LRM domain obligation. For the binary members it is on the SECOND
    /// operand (`nonzero_divisor`) or on BOTH (`pow_sign`); everything else
    /// constrains the single unary operand.
    ///
    /// NOT `.fdiv`: §4.2.4 makes ONLY `%`-by-zero an error. `x/0.0` is an
    /// exact IEEE ±inf and is spec-legal, so it must not reject — it forfeits
    /// finiteness instead (see the prover's `.fdiv` transfer). `ipow`'s one
    /// undefined corner is pow's: a zero base under a negative exponent (IEEE
    /// 1364-2005 Table 5-6's 'bx).
    domain: Domain = .all,
    /// Table 4-14/4-15 spelling for diagnostics (`log10` is Verilog-A's
    /// `log`); null means the tag name.
    label: ?[]const u8 = null,
};

pub const table = std.EnumArray(Opcode, Info).init(.{
    .fadd = .{ .class = .binary },
    .fsub = .{ .class = .binary },
    .fmul = .{ .class = .binary },
    .fdiv = .{ .class = .binary },
    .fmod = .{ .class = .binary, .domain = .nonzero_divisor },
    .fneg = .{ .class = .unary },
    .iadd = .{ .class = .binary, .int = true },
    .isub = .{ .class = .binary, .int = true },
    .imul = .{ .class = .binary, .int = true },
    .idiv = .{ .class = .binary, .int = true, .domain = .nonzero_divisor },
    .imod = .{ .class = .binary, .int = true, .domain = .nonzero_divisor },
    .ineg = .{ .class = .unary, .int = true },
    .flt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .fgt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .fle = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .fge = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .feq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .fne = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .ilt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .igt = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .ile = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .ige = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .ieq = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .ine = .{ .class = .binary, .int = true, .bool01 = true, .predicate = true },
    .logand = .{ .class = .binary, .int = true, .bool01 = true },
    .logor = .{ .class = .binary, .int = true, .bool01 = true },
    .lognot = .{ .class = .unary, .int = true, .bool01 = true, .predicate = true },
    .bitand = .{ .class = .binary, .int = true },
    .bitor = .{ .class = .binary, .int = true },
    .bitxor = .{ .class = .binary, .int = true },
    .bitxnor = .{ .class = .binary, .int = true },
    .bitnot = .{ .class = .unary, .int = true },
    .shl = .{ .class = .binary, .int = true },
    .shr = .{ .class = .binary, .int = true },
    .sqrt = .{ .class = .unary, .domain = .non_negative, .label = "sqrt()" },
    .exp = .{ .class = .unary },
    .expm1 = .{ .class = .unary },
    .ln = .{ .class = .unary, .domain = .positive, .label = "ln()" },
    .ln1p = .{ .class = .unary, .domain = .gt_neg_one, .label = "ln1p()" },
    .log10 = .{ .class = .unary, .domain = .positive, .label = "log()" },
    .pow = .{ .class = .binary, .domain = .pow_sign, .label = "pow()" },
    .hypot = .{ .class = .binary },
    .floor = .{ .class = .unary },
    .ceil = .{ .class = .unary },
    .fabs = .{ .class = .unary },
    .fmin = .{ .class = .binary },
    .fmax = .{ .class = .binary },
    .iabs = .{ .class = .unary, .int = true },
    .imin = .{ .class = .binary, .int = true },
    .imax = .{ .class = .binary, .int = true },
    .ipow = .{ .class = .binary, .int = true, .domain = .pow_sign },
    .sin = .{ .class = .unary },
    .cos = .{ .class = .unary },
    .tan = .{ .class = .unary, .domain = .tan_poles, .label = "tan()" },
    .asin = .{ .class = .unary, .domain = .unit_closed, .label = "asin()" },
    .acos = .{ .class = .unary, .domain = .unit_closed, .label = "acos()" },
    .atan = .{ .class = .unary },
    .atan2 = .{ .class = .binary },
    .sinh = .{ .class = .unary },
    .cosh = .{ .class = .unary },
    .tanh = .{ .class = .unary },
    .asinh = .{ .class = .unary },
    .acosh = .{ .class = .unary, .domain = .ge_one, .label = "acosh()" },
    .atanh = .{ .class = .unary, .domain = .unit_open, .label = "atanh()" },
    .fi_cast = .{ .class = .unary, .int = true },
    .if_cast = .{ .class = .unary },
    .opt_barrier = .{ .class = .unary },
    .path_prev = .{ .class = .unary },
    .path_acc = .{ .class = .unary },
    .select = .{ .class = .ternary },
    .phi = .{ .class = .phi },
    .branch = .{ .class = .branch },
    .jump = .{ .class = .jump },
    .call = .{ .class = .call },
});

pub fn get(op: Opcode) Info {
    return table.get(op);
}

/// Diagnostic spelling of `op` — see `Info.label`.
pub fn label(op: Opcode) []const u8 {
    return table.get(op).label orelse @tagName(op);
}
