//! The backend's facts about each `Mir.Opcode` — how it is SPELLED in Zig —
//! one row per opcode.
//!
//! `lib/ir/opcode.zig` holds the IR facts and leaves the Zig spellings to the
//! backend ("`lib/ir` does not know the target is Zig"); this is that half.
//! `std.EnumArray.init` with no defaults, so an opcode added to `Mir.Opcode`
//! does not compile until its row states every column here — the questions
//! `devSafe`, `libmClass`, `f64Const` and `renderOp` used to answer in
//! separate switches with an `else`, each taking a default silently.
//!
//! DOD: comptime rows in `.rodata`, read with one indexed load. No allocation.

const std = @import("std");
const Mir = @import("ir").Mir;

/// How `render.renderOp` writes an opcode over `S`.
pub const Spell = union(enum) {
    /// Written by hand in `renderOp`: arithmetic with its scalar fast paths,
    /// comparisons, integer ops, casts, latches, and the control opcodes.
    custom,
    /// An `S` protocol method: `(a).sqrt()`, `(a).div(b)`.
    method: []const u8,
    /// A kernel from `kernel_text`: `zLog10(S, a)`, `zHypot(S, a, b)`.
    helper: []const u8,
};

pub const Row = struct {
    /// §4.3 its `S` spelling in `renderOp`.
    s: Spell,
    /// That spelling ALWAYS collapses its operands to `.val()` — a scalar
    /// decision, so a lane-parallel `S` pins its lanes (`float/lanes.zig` `pinLanes`).
    /// `pow` is not here: it pins only on its `zPow` path, which `renderOp`
    /// decides from the exponent. `fi_cast` is, and pins in its own prong.
    pins_lanes: bool,
    /// `f64Const`'s plain-f64 host spelling: the text around the operand of
    /// a unary (2 fragments) or around a binary's two (3). Null: no host
    /// form (`fmod` has one, but it is not a fragment wrap — see there).
    ///
    /// §4.3.1 Table 4-14 and §4.3.2 Table 4-15 in full: every one is a pure
    /// f64→f64 function of a value the host already has, so a §6.3.4 default
    /// over one derives exactly as an arithmetic default does — the clause
    /// puts no operator restriction on a dependent parameter, so neither
    /// does this. The integer ops share the real spelling, in the f64 domain
    /// `foldConst` folds them in; `idiv` has none, because its truncation is
    /// NOT what `/` does on an f64. `if_cast` and `opt_barrier` are
    /// identities there.
    host_f64: ?[]const []const u8,
    /// `codegen.devSafe`: the host spelling is instructions a GPU executes
    /// without libm, AND the opcode is real-valued.
    dev_safe: bool,
    /// `hoist.libmClass`: the op is a libm call on the host, costly enough
    /// that evaluating it eagerly is a price (`float/lanes.zig` `eagerCostly`).
    libm: bool,
};

pub const table = std.EnumArray(Mir.Opcode, Row).init(.{
    .fadd = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "(", ") + (", ")" }, .dev_safe = true, .libm = false },
    .fsub = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "(", ") - (", ")" }, .dev_safe = true, .libm = false },
    .fmul = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "(", ") * (", ")" }, .dev_safe = true, .libm = false },
    .fdiv = .{ .s = .{ .method = "div" }, .pins_lanes = false, .host_f64 = &.{ "(", ") / (", ")" }, .dev_safe = true, .libm = false },
    .fmod = .{ .s = .{ .helper = "zFmod" }, .pins_lanes = true, .host_f64 = null, .dev_safe = false, .libm = false },
    .fneg = .{ .s = .{ .method = "neg" }, .pins_lanes = false, .host_f64 = &.{ "-(", ")" }, .dev_safe = true, .libm = false },
    .iadd = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "(", ") + (", ")" }, .dev_safe = false, .libm = false },
    .isub = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "(", ") - (", ")" }, .dev_safe = false, .libm = false },
    .imul = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "(", ") * (", ")" }, .dev_safe = false, .libm = false },
    .idiv = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .imod = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .ineg = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "-(", ")" }, .dev_safe = false, .libm = false },
    .flt = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .fgt = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .fle = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .fge = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .feq = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .fne = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .ilt = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .igt = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .ile = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .ige = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .ieq = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .ine = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .logand = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .logor = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .lognot = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .bitand = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .bitor = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .bitxor = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .bitxnor = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .bitnot = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .shl = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .shr = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .sqrt = .{ .s = .{ .method = "sqrt" }, .pins_lanes = false, .host_f64 = &.{ "@sqrt(", ")" }, .dev_safe = true, .libm = false },
    .exp = .{ .s = .{ .method = "exp" }, .pins_lanes = false, .host_f64 = &.{ "@exp(", ")" }, .dev_safe = false, .libm = true },
    .expm1 = .{ .s = .{ .method = "expm1" }, .pins_lanes = false, .host_f64 = &.{ "std.math.expm1(", ")" }, .dev_safe = false, .libm = true },
    .ln = .{ .s = .{ .method = "log" }, .pins_lanes = false, .host_f64 = &.{ "@log(", ")" }, .dev_safe = false, .libm = true },
    .ln1p = .{ .s = .{ .method = "log1p" }, .pins_lanes = false, .host_f64 = &.{ "std.math.log1p(", ")" }, .dev_safe = false, .libm = true },
    .log10 = .{ .s = .{ .helper = "zLog10" }, .pins_lanes = false, .host_f64 = &.{ "@log10(", ")" }, .dev_safe = false, .libm = true },
    .pow = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "std.math.pow(f64, ", ", ", ")" }, .dev_safe = false, .libm = true },
    .hypot = .{ .s = .{ .helper = "zHypot" }, .pins_lanes = true, .host_f64 = &.{ "std.math.hypot(", ", ", ")" }, .dev_safe = false, .libm = true },
    .floor = .{ .s = .{ .helper = "zFloor" }, .pins_lanes = true, .host_f64 = &.{ "@floor(", ")" }, .dev_safe = true, .libm = false },
    .ceil = .{ .s = .{ .helper = "zCeil" }, .pins_lanes = true, .host_f64 = &.{ "@ceil(", ")" }, .dev_safe = true, .libm = false },
    .fabs = .{ .s = .{ .method = "abs" }, .pins_lanes = false, .host_f64 = &.{ "@abs(", ")" }, .dev_safe = true, .libm = false },
    .fmin = .{ .s = .{ .helper = "zMin" }, .pins_lanes = false, .host_f64 = &.{ "@min(", ", ", ")" }, .dev_safe = true, .libm = false },
    .fmax = .{ .s = .{ .helper = "zMax" }, .pins_lanes = false, .host_f64 = &.{ "@max(", ", ", ")" }, .dev_safe = true, .libm = false },
    .iabs = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "@abs(", ")" }, .dev_safe = false, .libm = false },
    .imin = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "@min(", ", ", ")" }, .dev_safe = false, .libm = false },
    .imax = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "@max(", ", ", ")" }, .dev_safe = false, .libm = false },
    .ipow = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .sin = .{ .s = .{ .method = "sin" }, .pins_lanes = false, .host_f64 = &.{ "@sin(", ")" }, .dev_safe = false, .libm = true },
    .cos = .{ .s = .{ .method = "cos" }, .pins_lanes = false, .host_f64 = &.{ "@cos(", ")" }, .dev_safe = false, .libm = true },
    .tan = .{ .s = .{ .helper = "zTan" }, .pins_lanes = false, .host_f64 = &.{ "@tan(", ")" }, .dev_safe = false, .libm = true },
    .asin = .{ .s = .{ .helper = "zAsin" }, .pins_lanes = false, .host_f64 = &.{ "std.math.asin(", ")" }, .dev_safe = false, .libm = true },
    .acos = .{ .s = .{ .helper = "zAcos" }, .pins_lanes = false, .host_f64 = &.{ "std.math.acos(", ")" }, .dev_safe = false, .libm = true },
    .atan = .{ .s = .{ .method = "atan" }, .pins_lanes = false, .host_f64 = &.{ "std.math.atan(", ")" }, .dev_safe = false, .libm = true },
    .atan2 = .{ .s = .{ .helper = "zAtan2" }, .pins_lanes = true, .host_f64 = &.{ "std.math.atan2(", ", ", ")" }, .dev_safe = false, .libm = true },
    .sinh = .{ .s = .{ .method = "sinh" }, .pins_lanes = false, .host_f64 = &.{ "std.math.sinh(", ")" }, .dev_safe = false, .libm = true },
    .cosh = .{ .s = .{ .method = "cosh" }, .pins_lanes = false, .host_f64 = &.{ "std.math.cosh(", ")" }, .dev_safe = false, .libm = true },
    .tanh = .{ .s = .{ .method = "tanh" }, .pins_lanes = false, .host_f64 = &.{ "std.math.tanh(", ")" }, .dev_safe = false, .libm = true },
    .asinh = .{ .s = .{ .helper = "zAsinh" }, .pins_lanes = false, .host_f64 = &.{ "std.math.asinh(", ")" }, .dev_safe = false, .libm = true },
    .acosh = .{ .s = .{ .helper = "zAcosh" }, .pins_lanes = false, .host_f64 = &.{ "std.math.acosh(", ")" }, .dev_safe = false, .libm = true },
    .atanh = .{ .s = .{ .helper = "zAtanh" }, .pins_lanes = false, .host_f64 = &.{ "std.math.atanh(", ")" }, .dev_safe = false, .libm = true },
    .fi_cast = .{ .s = .custom, .pins_lanes = true, .host_f64 = null, .dev_safe = false, .libm = false },
    .if_cast = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "", "" }, .dev_safe = false, .libm = false },
    .opt_barrier = .{ .s = .custom, .pins_lanes = false, .host_f64 = &.{ "", "" }, .dev_safe = true, .libm = false },
    .path_prev = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .path_acc = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .select = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    // §3.2.2 array storage (`render.emitArrayStmt`/`renderLoad`). A store into
    // `f64` storage collapses its value to `.val()` and pins there, per
    // storage — not a fact of the opcode.
    .anew = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .fload = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .iload = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .store = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .phi = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .branch = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .jump = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
    .call = .{ .s = .custom, .pins_lanes = false, .host_f64 = null, .dev_safe = false, .libm = false },
});

pub fn get(op: Mir.Opcode) Row {
    return table.get(op);
}

test "opcode_zig: every row agrees with the IR table's shape" {
    for (std.meta.tags(Mir.Opcode)) |op| {
        const r = get(op);
        const class = Mir.opcode.get(op).class;
        if (r.host_f64) |h| try std.testing.expectEqual(@as(usize, switch (class) {
            .unary => 2,
            .binary => 3,
            else => return error.HostSpellingOnANonValueOp, // else: only unary and binary ops have operands to wrap
        }), h.len);
        // A method or kernel takes one operand or two, and a real one.
        if (r.s != .custom) {
            try std.testing.expect(class == .unary or class == .binary);
            try std.testing.expect(!Mir.opcode.get(op).int);
        }
        // `devSafe` is REAL-ONLY (see there), and a GPU form is a host form.
        if (r.dev_safe) {
            try std.testing.expect(!Mir.opcode.get(op).int);
            try std.testing.expect(r.host_f64 != null);
        }
        if (r.libm) try std.testing.expect(!r.dev_safe);
    }
}
