//! §6.3.6/§9.18 hierarchical system-parameter names → Table 9-29 identities,
//! domains and composition expressions. Shared by elaboration and the
//! §3.4.7 top-level alias declarations in lowering.

const std = @import("std");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;

/// One §9.18 Table 9-29 hierarchical system parameter. The tag is the
/// spelling without its `$`.
pub const Kind = enum {
    angle,
    hflip,
    mfactor,
    vflip,
    xposition,
    yposition,

    /// Every kind, in declaration order (the order elaboration reports them).
    pub const all = std.enums.values(Kind);

    /// Returns the kind `spelling` names, `$` included, or null.
    pub fn fromName(spelling: []const u8) ?Kind {
        if (spelling.len == 0 or spelling[0] != '$') return null;
        return std.meta.stringToEnum(Kind, spelling[1..]);
    }

    /// Returns the source spelling, `$` included.
    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .angle => "$angle",
            .hflip => "$hflip",
            .mfactor => "$mfactor",
            .vflip => "$vflip",
            .xposition => "$xposition",
            .yposition => "$yposition",
        };
    }

    /// Returns Table 9-29's value for an instance nothing sets: the
    /// composition's identity (0 for the sums, 1 for the products).
    pub fn initial(self: Kind) f64 {
        return switch (self) {
            .angle, .xposition, .yposition => 0,
            .hflip, .mfactor, .vflip => 1,
        };
    }

    /// Returns whether `value` is in Table 9-29's domain for the kind.
    pub fn allows(self: Kind, value: f64) bool {
        return switch (self) {
            .angle => value >= 0 and value < 360,
            .hflip, .vflip => value == 1 or value == -1,
            .mfactor => value > 0,
            .xposition, .yposition => true,
        };
    }

    /// Returns whether Table 9-29 restricts the kind's values at all.
    pub fn constrained(self: Kind) bool {
        return switch (self) {
            .angle, .hflip, .vflip, .mfactor => true,
            .xposition, .yposition => false,
        };
    }

    /// Returns the domain `allows` checks, worded for a diagnostic.
    pub fn domain(self: Kind) []const u8 {
        return switch (self) {
            .angle => "0 <= $angle < 360",
            .hflip => "$hflip = +1 or -1",
            .mfactor => "$mfactor > 0",
            .vflip => "$vflip = +1 or -1",
            .xposition, .yposition => "any value",
        };
    }

    /// `parent` and `value` already refer to the flat namespace. `.none`
    /// means the table's top-level identity. Force real arithmetic: even an
    /// integer spelling of a coordinate or angle is a real-valued system
    /// parameter, so a fractional angle never passes through integer `%`.
    pub fn compose(self: Kind, file: *Ast.SourceFile, arena: std.mem.Allocator, parent: Ast.ExprId, value: Ast.ExprId, tok: u32) std.mem.Allocator.Error!Ast.ExprId {
        const x = &file.exprs;
        const real_value = if (constfold.fold(file, value, constfold.literal_env)) |v|
            if (v == .str) value else try x.addReal(arena, tok, v.asReal())
        else
            try binary(file, arena, .add, value, try x.addReal(arena, tok, 0), tok);
        if (parent == .none) return real_value;
        const op: Ast.BinaryOp = switch (self) {
            .angle, .xposition, .yposition => .add,
            .hflip, .mfactor, .vflip => .mul,
        };
        const combined = try binary(file, arena, op, parent, real_value, tok);
        // Each valid input is in [0,360), so the sum is nonnegative and
        // §4.2.4's real remainder is precisely Table 9-29's modulo 360.
        return if (self == .angle)
            binary(file, arena, .mod, combined, try x.addReal(arena, tok, 360), tok)
        else
            combined;
    }
};

/// One instance's expression per kind, `.none` where nothing sets it.
pub const Values = std.EnumArray(Kind, Ast.ExprId);
/// Lowering's §3.4.7 top-level alias per kind: the `Lowered.params` row that
/// holds it, or null.
pub const Aliases = std.EnumArray(Kind, ?u32);

fn binary(file: *Ast.SourceFile, arena: std.mem.Allocator, op: Ast.BinaryOp, lhs: Ast.ExprId, rhs: Ast.ExprId, tok: u32) std.mem.Allocator.Error!Ast.ExprId {
    return file.exprs.add(arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = lhs,
        .rhs = rhs,
        .extra = @backingInt(op),
    });
}
