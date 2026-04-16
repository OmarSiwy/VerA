//! §3.4 parameters and §3.2 variables and scopes.
//!
//! In: parameter/localparam/variable declarations. Out: `params` (the model-card ABI),
//! ranges for proof.zig, and the variable slots the statement lowering assigns.
//!
//! LRM clauses this file's code cites: §2.9, §3.2, §3.2.2, §3.3, §3.4, §3.4.1, §3.4.2, §3.4.4, §5.3.2, §5.10, §6.3.4, §6.6.1.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_param.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_event = @import("event.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Ssa = @import("../ssa.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const VarSlot = Lower.VarSlot;
const ArrayInfo = Lower.ArrayInfo;
const Const = Lower.Const;
const init = Lower.init;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;
const call = Lower.call;
const wrap32 = Lower.wrap32;
const toReal = Lower.toReal;
const toInt = Lower.toInt;
const coerceTo = Lower.coerceTo;
const astTy = Lower.astTy;

/// This file's private state on `Lower` (`Lower.param_state`).
pub const State = struct {
    /// Variables `markHeldVars` found assigned under an `@(...)`, collected BEFORE
    /// the module's variables are declared. Empty for a module with no event
    /// control.
    ///
    /// Keyed on §5.3.2's "unique location", i.e. the pair (scope, name) spelled as
    /// a dotted path: a module variable is its bare name, a named block's local is
    /// `<label>.<name>` (`<outer>.<inner>.<name>` when nested). A bare name would
    /// make `lo.n`, `hi.n` and the module's own `n` one slot.
    /// The value says why (`Lower.HeldVar.Why`).
    held_names: std.StringHashMapUnmanaged(Lower.HeldVar.Why) = .empty,
    /// The enclosing NAMED blocks during `scanHeld`, so a target resolves to the
    /// nearest declaration of it — a module variable assigned from inside a block
    /// still keys bare, because the block does not declare it.
    held_frames: std.ArrayList(HeldFrame) = .empty,
    /// §3.2.2 array names some subscript indexes at run time (`markMemArrays`):
    /// `declareVarDecl` gives such an array one memory-backed storage.
    mem_names: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,
};

/// One enclosing §5.3.2 named block, as `scanHeld` sees it: the dotted prefix
/// its locals are keyed under, and the declarations that say which names those
/// are.
const HeldFrame = struct { prefix: []const u8, vars: []const Ast.VarDecl };

// ---------------------------------------------------------------------------
// Class 3 — parameters (LRM §3.4) and variables (§3.2)
// ---------------------------------------------------------------------------

/// LRM §3.4. Register a parameter: infer its type (§3.4.1), fold its default,
/// and COPY decl.ranges into ParamInfo.ranges (§3.4.2 — the class-6 evidence).
pub fn lowerParamDecl(self: *Lower, decl: *const Ast.ParamDecl) Oom!void {
    const name = self.file.str(decl.name);

    // §3.4.2: "The first expression in the range shall be numerically smaller
    // than the second expression in the range." Decidable from the declaration
    // alone — separate from checking an OVERRIDE against a well-formed range,
    // which needs an instance value. Folded bounds only; §3.4.2 admits a
    // constant_expression over earlier parameters. Here, above the array
    // dispatch, so an array's ranges are judged once and not once per element.
    for (decl.ranges) |r| {
        if (r.strings != null or r.hi == .none) continue; // string set / single value
        const lo = lower_constfold.constEval(self, r.lo) orelse continue;
        const hi = lower_constfold.constEval(self, r.hi) orelse continue;
        if (lo == .str or hi == .str) continue;
        if (lo.asReal() < hi.asReal()) continue;
        try self.err(decl.main_tok, .E0347, "`{s}` {s} bounds {d} and {d} are not in increasing order", .{
            name, @tagName(r.kind), lo.asReal(), hi.asReal(),
        });
    }

    // §3.4/A.2.4: a parameter assignment carries a constant_mintypmax_
    // expression. "Did not fold" cannot be the test — the derive() fall-through
    // below deliberately keeps a default that reads OTHER parameters (§6.3.4:
    // the dependent must follow an override of its base) — so what is policed
    // is the part no parameter dependence can excuse: a read of the operating
    // point or the simulation state, which has no value a model card could
    // carry. Without this, `parameter real bad = $abstime;` compiled and the
    // card silently read 0.0. Reported and then lowered anyway, like E0347.
    if (simStateInDefault(self, decl.default)) |what| {
        try self.err(decl.main_tok, .E0363, "`{s}` reads `{s}`", .{ name, what });
    }
    if (oomrInDefault(self, decl.default)) |h|
        try self.err(self.file.exprs.mainTok(h), .E0924, "`{s}` in the default of `{s}`", .{ try lower_expr.flatName(self, h), name });

    // §3.4.4 array parameters are scalarized into `name[i]` entries.
    if (decl.dims.len != 0) return lowerParamArray(self, decl, name);

    const declared = if (lower_constfold.constEval(self, decl.default)) |c| parameterConst(decl.ty, c) else null;
    // §3.4 "parameters can be modified at compilation time to have values
    // which are different from those specified in the declaration assignment":
    // a `--param` replaces the declaration value before anything reads it. In
    // the declared type, or — §3.4.1's inference — the declared default's.
    const over: ?Const = if (decl.is_local or decl.ty == .string) null else for (self.param_overrides) |o| {
        if (std.mem.eql(u8, o.name, name))
            break parameterConst(if (decl.ty == .unspecified and declared != null and declared.? == .int) .integer else decl.ty, .{ .real = o.value });
    } else null;
    const folded = over orelse declared;
    // §4.2.1.1 converts by "rounding the real number to the nearest integer",
    // and an infinity or a NaN has none: `parameterConst` leaves such a value
    // real, and it used to reach the card as i64's saturation value.
    if (decl.ty == .integer) if (folded) |c| if (c == .real and !std.math.isFinite(c.real))
        try self.err(decl.main_tok, .E0368, "`{s}` = {d}", .{ name, c.real });
    try checkParamType(self, decl, name, folded);
    // §3.4.2's OTHER half: "the parameter value shall be within the range". It
    // needs a value somebody supplied, and `is_override` is the only marker that
    // one was — elaborate.zig sets it when a §6.3 instance parameter value
    // assignment becomes this declaration's default. A module compiled on its own
    // has no instance, so its declared default is judged for its BOUNDS (E0347,
    // above) and not for itself.
    if (decl.is_override or over != null) try checkParamRange(self, decl, name, folded);
    const ty: Ast.Type = if (decl.ty != .unspecified) decl.ty else switch (folded orelse Const{ .real = 0 }) {
        .int => .integer,
        .real => .real,
        .str => .string,
    };
    // §6.3.4 later defaults may reference this one. §6.6.1 also makes a
    // parameter a legal constant expression for an array or generate bound, so
    // `consts` keeps carrying the value it folds to under the declared default
    // — that is the only value those two positions can ever see.
    if (folded) |c| try self.consts.put(self.arena, name, c);

    // §6.3.4: "an update of gate_width, whether by a defparam statement or in
    // an instantiation statement for the module which defined these parameters,
    // automatically updates gate_cap". So a default that MENTIONS another
    // parameter may NOT be frozen at the number it folds to under that
    // parameter's declared default — the host overrides the base after
    // elaboration and the dependent has to follow it. `foldExpr(..., false)` is precisely
    // the fold that refuses to look through a parameter, so it is the "may this
    // be baked into the model card?" test; `folded` above cannot be, for the
    // §6.6.1 reason. Codegen turns the surviving expression into `derive()`.
    const default = if (over) |c| switch (c) {
        .int => |n| try self.mir.addIntConst(self.arena, n),
        .real => |n| try self.mir.addFloatConst(self.arena, n),
        .str => unreachable, // a card value is a real
    } else try parameterDefault(self, decl.default, decl.ty);

    try addParam(self, name, ty, default, folded, decl.ranges, decl.is_local, decl.main_tok);
    self.out.params.items[self.out.params.items.len - 1].integer32 = decl.ty == .integer;
}

/// §3.4/A.2.4: the spelling of the first simulation-state or module-variable
/// reference in a parameter default, or null when none exists. Access functions, analog
/// operators, small-signal sources and event functions are state reads by
/// TAG; a `sys_call` is one by NAME (`simStateName`), because most `$` names
/// that could appear here — `$param_given`, `$mfactor`, `$simprobe` — resolve
/// before the solve and are left to the ordinary paths. Every other tag is
/// searched through its `children`, first in source order.
pub fn simStateInDefault(self: *const Lower, e: Ast.ExprId) ?[]const u8 {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    switch (tag) {
        // §4.4 access functions, §4.5 analog operators, §4.6 small-signal
        // sources, §5.10 event functions: operating-point reads by construction.
        .branch_access, .port_access, .filter_call, .noise_call, .event_function => return self.file.str(ex.strOf(e)),
        .sys_call => {
            const n = self.file.str(ex.strOf(e));
            if (simStateName(n)) return n;
        },
        // §3.4 "constant numbers and previously defined parameters": a module
        // variable is neither, and holds nothing until the analog block runs.
        .ident => if (self.out.module) |m| for (m.vars) |v| {
            if (v.name == ex.strOf(e)) return self.file.str(v.name);
        },
        else => {}, // else: a state read only through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (simStateInDefault(self, c)) |w| return w;
    return null;
}

/// §6.7.1 "parameter declaration statements shall not make out-of-module
/// references": the first hierarchical name in `e`, or null. A §5.5.3 nature
/// attribute reference (`net.potential.attr`) is a constant, not a reference.
fn oomrInDefault(self: *const Lower, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .hier_ident) {
        const parts = ex.nameParts(e);
        const half = if (parts.len == 3) self.file.str(parts[1]) else "";
        if (!std.mem.eql(u8, half, "potential") and !std.mem.eql(u8, half, "flow")) return e;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (oomrInDefault(self, c)) |h| return h;
    return null;
}

/// The `$` (and `analysis`) names whose value belongs to a solve: time, the
/// ambient temperature pair, the RNG family, and the analysis type. §9.13's
/// distributions are matched by their two prefixes.
///
/// `$simparam` is deliberately NOT here: §9.15's table is the HOST's, constant
/// for a whole run, and a default reading it is the documented W1050 contract
/// — the field ships as 0 and the host writes it (codegen's "§3.4 a default
/// with no compile-time value is W1050" test pins exactly that shape).
pub fn simStateName(n: []const u8) bool {
    const names = [_][]const u8{
        "$abstime", "$realtime", "$temperature", "$vt",
        "$random",  "$arandom",  "analysis",
    };
    for (names) |s| if (std.mem.eql(u8, n, s)) return true;
    return std.mem.startsWith(u8, n, "$dist_") or std.mem.startsWith(u8, n, "$rdist_");
}

/// §3.4.2: "The parameter value shall be within the range from the smallest
/// value specified to the largest value specified", minus everything an
/// `exclude` removes. Several `from` clauses are a UNION — the clause's own
/// example writes two — so the test is "inside at least one", not "inside all".
///
/// Only reached for a §6.3 override (see the call site). Nothing is reported
/// when a bound or the value will not fold: §3.4.2 admits a constant expression
/// over earlier parameters, and a bound that reads an overridable parameter has
/// no single value at compile time.
pub fn checkParamRange(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8, folded: ?Const) Oom!void {
    const c = folded orelse return;
    if (c == .str) {
        var has_from = false;
        var in_from = false;
        for (decl.ranges) |r| {
            const off = r.strings orelse continue;
            const contains = for (self.file.exprs.list(off)) |id| {
                if (std.mem.eql(u8, c.str, self.file.str(@enumFromInt(id)))) break true;
            } else false;
            switch (r.kind) {
                .from => {
                    has_from = true;
                    in_from = in_from or contains;
                },
                .exclude => if (contains) {
                    try self.err(decl.main_tok, .E0361, "`{s}` is \"{s}\", which the declared range excludes", .{ name, c.str });
                    return;
                },
            }
        }
        if (has_from and !in_from)
            try self.err(decl.main_tok, .E0361, "`{s}` is \"{s}\", outside the declared range", .{ name, c.str });
        return;
    }
    const v = c.asReal();

    var has_from = false;
    var in_from = false;
    for (decl.ranges) |r| {
        if (r.strings != null) continue;
        const lo = rangeBound(self, r.lo) orelse continue;
        // A.2.5 `exclude constant_expression` — a single value, so hi is absent.
        const hi = if (r.hi == .none) lo else rangeBound(self, r.hi) orelse continue;
        const above_lo = if (r.lo_inclusive) v >= lo else v > lo;
        const below_hi = if (r.hi_inclusive) v <= hi else v < hi;
        switch (r.kind) {
            .from => {
                has_from = true;
                if (above_lo and below_hi) in_from = true;
            },
            .exclude => if (above_lo and below_hi) {
                try self.err(decl.main_tok, .E0361, "`{s}` is {d}, which the declared range excludes", .{ name, v });
                return;
            },
        }
    }
    if (has_from and !in_from) {
        try self.err(decl.main_tok, .E0361, "`{s}` is {d}, outside the declared range", .{ name, v });
    }
}

/// One end of a §3.4.2 value_range. A.2.5 lets it be `inf` / `-inf`, which is
/// not a constant_expression and so cannot go through `constEval`.
pub fn rangeBound(self: *Lower, e: Ast.ExprId) ?f64 {
    if (e == .none) return null;
    return switch (self.file.exprs.tag(e)) {
        .pos_inf => std.math.inf(f64),
        .neg_inf => -std.math.inf(f64),
        else => blk: { // else: every other bound is a constant_expression, `constEval`'s to judge
            const c = lower_constfold.constEval(self, e) orelse break :blk null;
            break :blk if (c == .str) null else c.asReal();
        },
    };
}

/// §3.4.1 the two type rules the general "convert the value to the parameter's
/// type" sentence does NOT cover. Diagnose and carry on: inference still runs
/// and the parameter still enters the table, so one bad declaration does not
/// turn every use of it into a second diagnostic.
///
/// Scalars only — the array path has its own arm, since §3.4.4's requirement is
/// about the DECLARATION and holds whatever the pattern contains.
pub fn checkParamType(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8, folded: ?Const) Oom!void {
    const c = folded orelse return; // not constant here: nothing to compare
    const is_str = c == .str;
    // §3.4.1: "the type of a string parameter (see 3.4.6) ... is mandatory."
    // Inference is defined over the value "after any value overrides have been
    // applied", so an untyped parameter has no type until elaboration — and
    // the no-string-conversion rule below has to be decidable before then.
    if (decl.ty == .unspecified) {
        if (is_str) try self.err(decl.main_tok, .E0346, "`{s}` is initialized with a string; write `parameter string`", .{name});
        return;
    }
    // §3.4.1: "No conversion shall be applied for strings; it shall be an error
    // to assign a numeric value to a parameter declared as string or to assign
    // a string value to a real parameter." Both directions, one code — it is
    // one sentence and one fix.
    if ((decl.ty == .string) == is_str) return;
    try self.err(decl.main_tok, .E0345, "`{s}` is declared {s} and initialized with a {s} value", .{
        name,
        @tagName(decl.ty),
        if (is_str) "string" else "numeric",
    });
}

/// §3.4.7's other form: `aliasparam m = $mfactor;`, which the clause prints
/// beside `aliasparam trise = dtemp;` and which Syntax 3-2 does not cover —
/// `aliasparam_declaration ::= aliasparam parameter_identifier =
/// parameter_identifier ;` has an identifier on the right, so the form only
/// exists in the clause's prose. It exists because "m" is what a SPICE netlist
/// calls the shunt multiplicity and `$mfactor` is what §9.18 calls it, and a
/// model has to answer to both spellings.
///
/// THE ALIAS GETS THE STORAGE, which is the one design call here. §3.4.7 makes
/// an alias a second name for one location, and §9.18's `$mfactor` has no
/// location on VerA's model card at all — it is an `Instance` field the host
/// writes, because §6.3.6 has the host scale the whole stamp by it. So the way
/// to give the two names one location is the other direction: the alias becomes
/// an ordinary real parameter (Table 9-29's top-level 1.0 as its default, which
/// is exactly the value `$mfactor` had before anyone aliased it) and `$mfactor`
/// reads it (`lowerSysCall`).
///
/// ponytail: the ceiling is that a host which writes `Instance.mfactor` AND
/// overrides the alias has set the same physical quantity twice, and the
/// equations then read the alias while the stamp is scaled by the field. The
/// upgrade is for codegen to fold the model-card knob into `Instance.mfactor`
/// at `derive` time, which needs the two structs to know about each other.
pub fn aliasSystemParam(self: *Lower, alias: []const u8, target: []const u8) Oom!bool {
    if (!std.mem.eql(u8, target, "$mfactor")) return false;
    self.mfactor_param = @intCast(self.out.params.items.len);
    try addParam(self, alias, .real, try self.mir.addFloatConst(self.arena, 1.0), .{ .real = 1.0 }, &.{}, false, Mir.no_tok);
    return true;
}

pub fn addParam(
    self: *Lower,
    name: []const u8,
    ty: Ast.Type,
    default: Mir.Value,
    folded: ?Const,
    ranges: []const Ast.ValueRange,
    is_local: bool,
    tok: u32,
) Oom!void {
    const idx: u32 = @intCast(self.out.params.items.len);
    try self.out.params.append(self.arena, .{
        .name = name,
        .tok = tok, // §3.4.2 diagnostics point back at the declaration
        .ty = ty,
        .default = default,
        .folded = folded, // §3.4 the value under the declared defaults
        .ranges = ranges, // §3.4.2 — MUST reach proof.zig
        .is_local = is_local,
    });
    // §3.4.5 a localparam "shall not be directly modified", and `derive`
    // rewrites its field unconditionally: one whose default folds without
    // reading a parameter (`parameterDefault` returned a constant) holds that
    // number at every read. Reading an INTEGER one as the number is what lets
    // a loop bounded by it (`for (i = 0; i < n; ...)`) and a subscript over
    // it fold. ponytail: integers only — a real constant would also hand the
    // prover a point interval, and a unit it newly proves finite changes float
    // mode, so its bits; widen once that is wanted.
    const ref = switch (self.mir.valueDef(default)) {
        .int_const => if (is_local) default else null,
        else => null, // else: a real or string, or a default that reads a parameter or the operating point, stays a card read
    };
    try self.param_values.append(self.arena, ref orelse try self.mir.addParamRef(self.arena, idx));
    try self.param_index.put(self.arena, name, idx);
}

/// Apply an explicit parameter type before a later default infers its own type.
/// Out-of-i64 real conversion retains the existing saturation policy; deciding
/// that implementation-defined domain is separate from preserving integral bits.
pub fn parameterConst(ty: Ast.Type, value: Const) Const {
    return switch (ty) {
        .real => if (value == .str) value else .{ .real = value.asReal() },
        .integer => switch (value) {
            .int => |n| .{ .int = wrap32(n) },
            .real => |n| blk: {
                const rounded = @round(n);
                if (rounded >= -9223372036854775808.0 and rounded < 9223372036854775808.0)
                    break :blk .{ .int = wrap32(@intFromFloat(rounded)) };
                break :blk value;
            },
            .str => value,
        },
        .string, .unspecified => value,
    };
}

/// The MIR must contain the same declared-type conversion as `folded` metadata.
/// Later defaults and operator controls follow this MIR, not the Model field.
pub fn parameterDefault(self: *Lower, e: Ast.ExprId, ty: Ast.Type) Oom!Mir.Value {
    if (e == .none) return zeroOf(astTy(ty));
    if (lower_constfold.foldExpr(self, e, false)) |raw| {
        return switch (parameterConst(ty, raw)) {
            .int => |n| self.mir.addIntConst(self.arena, n),
            .real => |n| self.mir.addFloatConst(self.arena, n),
            .str => |s| self.mir.addStrConst(self.arena, s),
        };
    }
    const value = try lower_expr.lowerExpr(self, e);
    return switch (ty) {
        .real => self.toReal(value),
        // MIR integer arithmetic truncates to signed 32 bits. Adding zero
        // expresses that conversion without changing the mathematical value.
        .integer => self.emit(.iadd, &.{ try self.toInt(value), .zero }),
        .string, .unspecified => value.v,
    };
}

/// §3.4.4 `parameter real c[0:2] = '{1,2,3};` → three scalar parameters named
/// `c[0]`, `c[1]`, `c[2]`. Codegen emits one Model field each.
pub fn lowerParamArray(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8) Oom!void {
    const dims = try dimsBounds(self, decl.dims, decl.main_tok, name) orelse return;
    // §3.4.4, in the restriction list closed by "Failure to follow these
    // restrictions shall result in an error": "A type of a parameter array
    // shall be given in the declaration." §3.4.1 says it again from the other
    // side. The reason is that §3.4.1's fallback derives the type from the
    // assigned VALUE, and an array's initializer is an assignment pattern —
    // there is no scalar there to derive from. `.real` below is a recovery
    // guess, not an inference.
    if (decl.ty == .unspecified)
        try self.err(decl.main_tok, .E0346, "array parameter `{s}` has no declared type", .{name});
    const ty: Ast.Type = if (decl.ty == .unspecified) .real else decl.ty;
    // §3.4: "For parameters defined as arrays, the initializer shall be a
    // constant_assignment_pattern expression ... using an assignment pattern
    // (see 4.2.14), i.e. within '{ and } delimiters." Annex G Table G.4 item 2
    // records why the apostrophe was added at all — without it `{2.1, 4.5}` is
    // the §4.2.13 concatenation operator and a front end cannot tell a list of
    // values from a concatenation. Diagnosed and carried on with no elements,
    // so every element keeps its §3.4 zero default and one bad declaration does
    // not turn every USE of the parameter into a second diagnostic.
    if (decl.default != .none and self.file.exprs.tag(decl.default) != .assign_pattern) {
        var b = self.errWith(self.file.exprs.mainTok(decl.default), .E0349);
        b.msg("initialising array parameter `{s}`", .{name});
        b.help("write the list as an assignment pattern: `'{{ ... }}`", .{});
        try b.emit();
    }
    const elems = try flattenPattern(self, decl.default, dims);

    try declareArray(self, name, .{ .dims = dims, .ty = astTy(ty) });
    var sub: [max_stack_dims]i64 = undefined;
    const idx = try subscriptBuf(self, &sub, dims.len);
    for (elems, 0..) |elem, k| {
        shapeSubscripts(dims, k, idx);
        const default = try parameterDefault(self, elem, ty);
        // §3.4.4 an omitted element is the type's zero; anything else folds
        // through the declared defaults exactly as a scalar's does.
        const folded: ?Const = if (elem == .none)
            (if (astTy(ty) == .real) Const{ .real = 0 } else Const{ .int = 0 })
        else
            lower_constfold.constEval(self, elem);
        try addParam(self, try elemName(self, name, idx), ty, default, if (folded) |c| parameterConst(ty, c) else null, decl.ranges, decl.is_local, decl.main_tok);
    }
}

/// §2.9's two rules about an attribute VALUE, and §2.9.2's four value domains.
///
/// In lowering because "constant expression" is a question about the scopes: `z`
/// is refused and `gain` is not, and only the declaration tables know which is
/// which. The parser collects the specs (`Parser.parseAttributes`) and checks the
/// one rule it alone can see, the nesting ban.
///
/// The attribute's TARGET is not recorded and is not needed: neither rule is
/// about the decorated item, and §2.9 leaves what an attribute MEANS entirely to
/// the tool that reads it — "properties about objects, statements and groups of
/// statements in the HDL source that can be used by various tools".
pub fn checkAttributes(self: *Lower, attrs: []const Ast.NatureAttr) Oom!void {
    for (attrs) |a| {
        // §2.9: "If the value is not specified, then ... the default value is 1"
        // — a name on its own is complete, so there is nothing to judge.
        if (a.value == .none) continue;
        const name = self.file.str(a.name);
        const c = lower_constfold.constEval(self, a.value) orelse {
            var b = self.errWith(a.main_tok, .E0357);
            b.msg("`{s}`", .{name});
            b.note("§2.9 Syntax 2-4: `attr_spec ::= attr_name [ = constant_expression ]`", .{});
            try b.emit();
            continue;
        };
        // §2.9.2 fixes the value of exactly four names, with a "must" each.
        // Every OTHER name is a tool convention with no stated domain, so it is
        // not checked — inventing one would refuse conforming source.
        const want: ?[]const []const u8 = if (std.mem.eql(u8, name, "desc") or
            std.mem.eql(u8, name, "units"))
            // "The attribute must be assigned a string" — any string.
            &.{}
        else if (std.mem.eql(u8, name, "op"))
            &.{ "yes", "no" }
        else if (std.mem.eql(u8, name, "multiplicity"))
            &.{ "multiply", "divide", "none" }
        else
            null;
        const allowed = want orelse continue;
        const got = switch (c) {
            .str => |sv| sv,
            // `desc = 7` fails on this arm: not a string at all.
            else => {
                try self.err(a.main_tok, .E0358, "`{s}` must be assigned a string", .{name});
                continue;
            },
        };
        if (allowed.len == 0) continue; // desc/units: a string is the whole rule
        var in_domain = false;
        for (allowed) |ok| {
            if (std.mem.eql(u8, got, ok)) in_domain = true;
        }
        if (!in_domain) {
            var b = self.errWith(a.main_tok, .E0358);
            b.msg("`{s} = \"{s}\"`", .{ name, got });
            b.help("§2.9.2 lists the values for `{s}`: {s}", .{ name, try joinQuoted(self.arena, allowed) });
            try b.emit();
        }
    }
}

/// `"a", "b" or "c"` — the LRM's own listing style, for E0358's help line.
pub fn joinQuoted(arena: std.mem.Allocator, items: []const []const u8) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, i| {
        if (i != 0) try out.appendSlice(arena, if (i + 1 == items.len) " or " else ", ");
        try out.print(arena, "\"{s}\"", .{it});
    }
    return out.toOwnedSlice(arena);
}

/// §3.4.8/§3.3's nested assignment pattern, flattened to one expression per
/// cell of `dims` in the same row-major order `shapeSubscripts` walks. §3.3's
/// own example is
///
///     string paths[0:2][0:1] = '{ '{"dir1","fileA"}, '{"dir2","fileA"}, … };
///
/// — an element list per dimension, so the flattening is one recursion per
/// dimension rather than a single `args` read. A cell the pattern does not
/// reach is `.none`, which every caller reads as §3.2's zero (or "").
/// A `.concat` is accepted alongside `.assign_pattern` because the parser folds
/// `{a,b}` to the same node shape and §3.4.4's diagnostic (E0349) already
/// covers the spelling.
pub fn flattenPattern(self: *Lower, e: Ast.ExprId, dims: []const Bounds) Oom![]const Ast.ExprId {
    const out = try self.arena.alloc(Ast.ExprId, shapeCells(dims));
    try fillPattern(self, e, dims, out);
    return out;
}

pub fn fillPattern(self: *Lower, e: Ast.ExprId, dims: []const Bounds, out: []Ast.ExprId) Oom!void {
    if (dims.len == 0) {
        out[0] = e;
        return;
    }
    const ex = &self.file.exprs;
    const elems: []const Ast.ExprId = if (e != .none and
        (ex.tag(e) == .assign_pattern or ex.tag(e) == .concat))
        try patternElems(self, e)
    else
        &.{};
    const stride = shapeCells(dims[1..]);
    for (0..@intCast(dims[0].count())) |k| {
        const child = if (k < elems.len) elems[k] else Ast.ExprId.none;
        try fillPattern(self, child, dims[1..], out[k * stride ..][0..stride]);
    }
}

/// The elements of a pattern (or brace list), with A.8.1's replication form
/// unrolled when the parser could not: `'{N{a, b}}` whose count is a
/// constant_expression rather than a literal (§4.2.14), carried as one
/// `.pattern_repl` element. The count folds like an array bound — parameters
/// included (§3.4) — and must be a non-negative integer (§4.2.13), else E0223
/// and no elements, so every cell keeps its §3.2 zero default.
pub fn patternElems(self: *Lower, e: Ast.ExprId) Oom![]const Ast.ExprId {
    const ex = &self.file.exprs;
    const elems = ex.args(e);
    if (elems.len != 1 or ex.tag(elems[0]) != .pattern_repl) return elems;
    const count = ex.lhs(elems[0]);
    const group = ex.args(ex.rhs(elems[0]));
    const c = lower_constfold.shapeEval(self, count);
    const n = if (c) |v| switch (v) {
        .int => |i| i,
        else => null,
    } else null;
    // ponytail: the cap is an unrolling guard, not a rule; no declared array
    // comes near 2^20 cells.
    if (n == null or n.? < 0 or n.? * @as(i64, @intCast(group.len)) > 1 << 20) {
        try self.err(ex.mainTok(count), .E0223, "", .{});
        return &.{};
    }
    const out = try self.arena.alloc(Ast.ExprId, @as(usize, @intCast(n.?)) * group.len);
    for (0..@intCast(n.?)) |k| @memcpy(out[k * group.len ..][0..group.len], group);
    return out;
}

pub const Bounds = struct {
    lo: i64,
    hi: i64,
    descending: bool = false,

    pub fn count(b: Bounds) i64 {
        return b.hi - b.lo + 1;
    }
};

/// §3.2/§3.2.2/§3.4.4 `{ [msb:lsb] }` — one `Bounds` per declared dimension,
/// outermost first, so `flag_array[0:8][0:3]` is `{{0,8},{0,3}}`.
///
/// §3.2 puts no limit on the count and neither does this: a multidimensional
/// array is scalarized cell by cell (see `shapeCells`), exactly as the
/// one-dimensional case always was, so a second dimension costs a longer key
/// and nothing else.
pub fn dimsBounds(self: *Lower, dims: []const Ast.Dim, tok: u32, name: []const u8) Oom!?[]const Bounds {
    if (dims.len == 0) {
        try self.err(tok, .E0307, "`{s}` has no dimensions", .{name});
        return null;
    }
    const out = try self.arena.alloc(Bounds, dims.len);
    for (dims, out) |d, *b| {
        const a = lower_constfold.shapeEval(self, d.msb) orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
            return null;
        };
        const c = lower_constfold.shapeEval(self, d.lsb) orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
            return null;
        };
        const x = a.asInt();
        const y = c.asInt();
        b.* = .{ .lo = @min(x, y), .hi = @max(x, y), .descending = x > y };
    }
    return out;
}

/// How many scalars a declared shape becomes.
pub fn shapeCells(dims: []const Bounds) usize {
    var n: usize = 1;
    for (dims) |d| n *= @intCast(d.count());
    return n;
}

/// The subscripts of the `k`th cell of a ROW-MAJOR walk — the last dimension
/// varies fastest, which is the order §3.4.8's nested assignment pattern lists
/// its elements in (`'{ '{a,b}, '{c,d} }` is rows of columns).
pub fn shapeSubscripts(dims: []const Bounds, k: usize, out: []i64) void {
    var rest = k;
    var i = dims.len;
    while (i > 0) {
        i -= 1;
        const n: usize = @intCast(dims[i].count());
        const offset: i64 = @intCast(rest % n);
        out[i] = if (dims[i].descending) dims[i].hi - offset else dims[i].lo + offset;
        rest /= n;
    }
}

/// How many subscripts fit on the stack. NOT a proved bound — §3.2 puts no limit
/// on a declaration's dimension count, though its own examples go two deep — so
/// this is the spill shape and not a fixed buffer: eight covers everything real
/// and anything wider allocates. `indexChain` uses the same spill threshold.
pub const max_stack_dims = 8;

/// Scratch for ONE cell's subscripts, sized once for a whole `shapeSubscripts`
/// walk. Eight copies of this line were written out inline across seven loops
/// (`copyWholeArray` has both halves of a copy), each re-deciding the threshold
/// — and each INSIDE its loop, so a nine-dimensional array paid an arena
/// allocation per cell rather than one for the walk.
pub fn subscriptBuf(self: *Lower, buf: *[max_stack_dims]i64, n: usize) Oom![]i64 {
    return if (n <= buf.len) buf[0..n] else try self.arena.alloc(i64, n);
}

/// The scalarized key for one array element, `name[i]` / `name[i][j]`
/// (§3.2, §3.2.2, §3.4.4).
///
/// Only the two DECLARATION sites need this: `vars` and `param_index` retain
/// the key, so it has to outlive the call. Every *lookup* goes through
/// `elemKey` instead — see there.
pub fn elemName(self: *Lower, name: []const u8, idx: []const i64) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(self.arena, name);
    for (idx) |i| try out.print(self.arena, "[{d}]", .{i});
    return out.toOwnedSlice(self.arena);
}

/// Widest `name[i][j]…` a legal model can produce without spilling: §2.7 caps
/// an identifier at 1024 characters (the same source bound
/// `naming.max_name_len` is sized from), plus four subscripts of `[`, a
/// 20-character `i64` and `]`. A deeper array spills to the arena — see
/// `elemKey`.
pub const elem_key_len = 1024 + 22 * 4;

/// `name[i][j]` for a *lookup*, formatted into the caller's stack buffer.
///
/// `HashMap.get` only compares the key, it never retains it, so the arena copy
/// `elemName` makes is pure waste on this path — and it was paid once per
/// *reference*, so a `c[0]` read in a loop body leaked a fresh string every
/// time it was lowered. Now the arena sees `c[0]` once per compilation, at the
/// declaration. Same trick as `naming.zig`'s fixed key buffer, and safe for the
/// same reason: the slice never escapes the caller's frame.
///
/// ponytail: an over-long identifier, or an array of more than four dimensions,
/// falls back to the arena rather than carrying a diagnostic of its own — the
/// first is already rejected upstream, the second is legal §3.2 and only pays
/// one allocation per reference. Silently truncating the key would alias two
/// distinct elements, which is the one outcome that must not happen.
pub fn elemKey(self: *Lower, buf: *[elem_key_len]u8, name: []const u8, idx: []const i64) Oom![]const u8 {
    if (name.len > buf.len) return try elemName(self, name, idx);
    @memcpy(buf[0..name.len], name);
    var n = name.len;
    for (idx) |i| {
        const s = std.fmt.bufPrint(buf[n..], "[{d}]", .{i}) catch
            return try elemName(self, name, idx);
        n += s.len;
    }
    return buf[0..n];
}

// ---- §3.2 variables and scopes ---------------------------------------------

pub fn closeScope(self: *Lower, mark: usize) void {
    while (self.scope_log.items.len > mark) {
        const e = self.scope_log.pop().?;
        if (e.prev) |p| {
            self.vars.putAssumeCapacity(e.name, p);
        } else {
            _ = self.vars.remove(e.name);
        }
        if (e.prev_array) |a| {
            self.arrays.putAssumeCapacity(e.name, a);
        } else {
            _ = self.arrays.remove(e.name);
        }
    }
}

pub fn shadowName(self: *Lower, name: []const u8) Oom!void {
    try self.scope_log.append(self.arena, .{
        .name = name,
        .prev = self.vars.get(name),
        .prev_array = self.arrays.get(name),
    });
    _ = self.vars.remove(name);
    _ = self.arrays.remove(name);
}

pub fn declareArray(self: *Lower, name: []const u8, info: ArrayInfo) Oom!void {
    try shadowName(self, name);
    try self.arrays.put(self.arena, name, info);
}

/// Bind `name` to a fresh SSA place, remembering what it shadowed (§5.3.2).
pub fn declareVar(self: *Lower, name: []const u8, ty: Ty) Oom!VarSlot {
    const slot: VarSlot = .{ .place = self.builder.newPlace(), .ty = ty };
    try shadowName(self, name);
    try self.vars.put(self.arena, name, slot);
    return slot;
}

/// §6.8: "An identifier shall be used to declare only one item within a scope.
/// This rule means it is ILLEGAL TO DECLARE TWO OR MORE VARIABLES WHICH HAVE THE
/// SAME NAME, or to name a task the same as a variable within the same module, or
/// to give an instance the same name as the name of the net connected to its
/// output."
///
/// Checked across every kind a scope declares by name — parameters, variables,
/// nets — not only variable against variable: a second parameter used to reach
/// codegen as a duplicate struct field, and a net or parameter sharing a
/// variable's name was silently rebound. The test is over ONE SCOPE'S
/// DECLARATION LISTS rather than over `self.vars`: the lists are exactly the
/// declarations of one scope (§6.8 lists what opens one), so shadowing an outer
/// name cannot reach this. Net against net is left alone: a port direction and
/// its discipline are two declarations of one item. So is a discipline against
/// a variable — §7's connect modules write `reg out; ddiscrete out;` — so only a
/// net declaration with no discipline (`wire x;`) is a second item beside a
/// variable.
///
/// ponytail: O(n²) over one scope's names — ~1e6 u32 compares for a thousand-
/// parameter compact model. A set per scope when a model makes that show.
pub fn checkOneItemPerScope(self: *Lower, params: []const Ast.ParamDecl, vars: []const Ast.VarDecl, nets: []const Ast.NetDecl) Oom!void {
    for (params, 0..) |p, i| {
        if (declares(params[0..i], p.name)) try dupItem(self, p.main_tok, p.name);
    }
    for (vars, 0..) |v, i| {
        if (declares(vars[0..i], v.name) or declares(params, v.name))
            try dupItem(self, v.main_tok, v.name);
        for (nets) |n| if (n.name == v.name and n.discipline == .none) try dupItem(self, v.main_tok, v.name);
    }
    for (nets) |n| {
        if (declares(params, n.name)) try dupItem(self, n.main_tok, n.name);
    }
}

fn declares(decls: anytype, name: Ast.StrId) bool {
    for (decls) |d| if (d.name == name) return true;
    return false;
}

fn dupItem(self: *Lower, tok: u32, name: Ast.StrId) Oom!void {
    var b = self.errWith(tok, .E0362);
    b.msg("`{s}`", .{self.file.str(name)});
    b.note("§6.8: one identifier declares one item in a scope — the earlier declaration is unreachable", .{});
    try b.emit();
}

/// Where a `declareVarDecl` sits. §5.3.2 gives a persistent §5.10 slot to a
/// module variable and to a NAMED block's local; an unnamed `begin`'s
/// declaration is neither, and `block_path` is "" for it.
pub const VarScope = enum { module, local };

/// §3.2 declare and initialize. Verilog-AMS variables start at zero, so a read
/// on a path that never assigned is 0 rather than the SSA builder's `.undef`
/// (which codegen could not emit).
pub fn declareVarDecl(self: *Lower, decl: *const Ast.VarDecl, scope: VarScope) Oom!void {
    const name = self.file.str(decl.name);
    const ty = astTy(decl.ty);
    // §5.3.2: "All named block variables are static — that is, an unique
    // location exists for all variables and leaving or entering the block do
    // not affect the values stored in them." The location is (scope, name), so
    // the key `markHeldVars` recorded carries the block path; the empty prefix
    // is module scope, and an UNNAMED block gets no slot because the clause
    // grants one to named blocks only.
    const prefix = if (scope == .module) "" else self.block_path;
    const held_key = if (prefix.len == 0)
        name
    else
        try std.fmt.allocPrint(self.arena, "{s}{s}", .{ prefix, name });
    // §5.10. `.string` is deliberately excluded: a string never reaches the
    // residual (§3.3 strings only feed §9.4 tasks, which re-run every
    // evaluation anyway), so a persistent slot for one would be storage
    // nothing can observe.
    const why = self.param_state.held_names.get(held_key);
    const hold = (scope == .module or prefix.len != 0) and ty != .string and why != null;

    if (decl.dims.len != 0) {
        const dims = try dimsBounds(self, decl.dims, decl.main_tok, name) orelse return;
        if (isMemArray(self, decl.name, ty)) {
            const place = try declareMemArray(self, name, dims, ty, !hold);
            const elems = try flattenPattern(self, decl.init, dims);
            if (hold) {
                // §5.10 the initializer is the `Instance` field's default and
                // nothing else, exactly as for a held scalar: every evaluation
                // starts from what the last accepted one left.
                const inits = try self.arena.alloc(Mir.Value, elems.len);
                for (elems, inits) |elem, *iv| iv.* = if (elem != .none)
                    try self.coerceTo(elem, ty, try lower_expr.lowerExpr(self, elem))
                else
                    zeroOf(ty);
                const id = self.arrays.get(name).?.mem.?.id;
                try self.builder.writeVariable(place, self.cur, try holdArray(self, try qualifyHeld(self, prefix, name), ty, id, inits, place));
                return;
            }
            // §3.2 an element the pattern does not reach keeps the zero start.
            for (elems, 0..) |elem, k| {
                if (elem == .none) continue;
                const v = try self.coerceTo(elem, ty, try lower_expr.lowerExpr(self, elem));
                try storeElem(self, place, try self.mir.addIntConst(self.arena, @intCast(k)), v);
            }
            return;
        }
        try declareArray(self, name, .{ .dims = dims, .ty = ty });
        // §3.3's own example is `string names[1:3] = '{"first","middle","last"}`:
        // the declaration takes an initializer exactly like the §3.4.4 array
        // PARAMETER does, and dropping it silently zeroed every element. The
        // pattern is positional over the declared range, so element k lands at
        // its left bound first, following the declared direction, and
        // one list per dimension for a multidimensional array (§3.3, §3.4.8).
        const elems = try flattenPattern(self, decl.init, dims);
        var sub: [max_stack_dims]i64 = undefined;
        const idx = try subscriptBuf(self, &sub, dims.len);
        for (elems, 0..) |elem, k| {
            shapeSubscripts(dims, k, idx);
            // §3.2.2 arrays are scalarized, so a held array is just one held
            // slot per element — `markHeldVars` records the base name and every
            // element takes a slot, since the index may be a runtime `case`.
            const en = try elemName(self, name, idx);
            const slot = try declareVar(self, en, ty);
            // §3.2 an element the pattern does not reach keeps the zero start.
            const init_val: Mir.Value = if (elem != .none)
                try self.coerceTo(elem, ty, try lower_expr.lowerExpr(self, elem))
            else
                zeroOf(ty);
            try self.builder.writeVariable(slot.place, self.cur, if (hold)
                try holdSlot(self, try qualifyHeld(self, prefix, en), ty, init_val, slot.place, why.?)
            else
                init_val);
        }
        return;
    }

    const slot = try declareVar(self, name, ty);
    const init_val: Mir.Value = if (decl.init == .none)
        zeroOf(ty)
    else
        try self.coerceTo(decl.init, ty, try lower_expr.lowerExpr(self, decl.init));
    try self.builder.writeVariable(slot.place, self.cur, if (hold)
        try holdSlot(self, held_key, ty, init_val, slot.place, why.?)
    else
        init_val);
}

/// The `Instance` field name of a held slot carries the block path too, because
/// codegen derives one struct field per `held_vars` entry from it and two
/// blocks may spell a local the same way (§5.3.2's whole point).
pub fn qualifyHeld(self: *Lower, prefix: []const u8, name: []const u8) Oom![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(self.arena, "{s}{s}", .{ prefix, name });
}

/// Codegen makes one `Instance` field per `held_vars` entry out of its name, so
/// the name has to be unique. It is — until a §6.6.1 unrolled `for` lowers the
/// SAME named block twice, which is two executions of one source declaration
/// and so, by §5.3.2, two locations that happen to share a path.
fn uniqueHeld(self: *Lower, name: []const u8, idx: u32) Oom![]const u8 {
    for (self.out.held_vars.items) |h| {
        if (std.mem.eql(u8, h.name, name)) return std.fmt.allocPrint(self.arena, "{s}.{d}", .{ name, idx });
    }
    return name;
}

/// §5.10. Give one event-assigned variable its persistent `Instance` slot and
/// return the Value that READS that slot.
///
/// The read replaces the declared initializer AT THE DECLARATION, which is the
/// whole reason the decision is made here and not at the assignment that
/// reveals it: a read of the variable that lexically precedes the `@(...)` must
/// also see the retained value, and by the time lowering reaches that
/// assignment the earlier read has already been resolved against the
/// initializer and memoized. Patching the entry def afterwards would leave it
/// stale.
///
/// `$held_real` / `$held_int` are synthetic callees — no LRM function has these
/// names, and `naming.isStatefulAnalogOp` rejects them, so they create no unit
/// and renumber no existing `Instance` state. The single argument is the index
/// into `held_vars`, which is how codegen recovers the field.
pub fn holdSlot(self: *Lower, name: []const u8, ty: Ty, init_val: Mir.Value, place: Ssa.Place, why: Lower.HeldVar.Why) Oom!Mir.Value {
    // Emitted into the DECLARATION's block — `.entry`, unless the initializer
    // itself opened a diamond (§4.2.7 `&&`/`||` short-circuit), in which case it
    // is that diamond's join. Either way it dominates every statement of the
    // module, which is all the seed has to do.
    const idx: i64 = @intCast(self.out.held_vars.items.len);
    const seed = try self.call(if (ty == .integer) "$held_int" else "$held_real", &.{try self.mir.addIntConst(self.arena, idx)});
    try self.out.held_vars.append(self.arena, .{
        .name = try uniqueHeld(self, name, @intCast(idx)),
        .ty = ty,
        .init = init_val,
        .seed = seed,
        .why = why,
    });
    try self.held_places.append(self.arena, place);
    return seed;
}

/// §5.10 `holdSlot` for a memory-backed array: ONE held row whose seed is the
/// array's `anew` (which codegen fills from the `Instance` field) and whose
/// final value is the array version the block ends with.
fn holdArray(self: *Lower, name: []const u8, ty: Ty, id: u32, inits: []const Mir.Value, place: Ssa.Place) Oom!Mir.Value {
    const idx: u32 = @intCast(self.out.held_vars.items.len);
    const seed = try self.mir.emitAnew(self.arena, self.cur, id);
    self.out.mem_arrays.items[id].held = idx;
    try self.out.held_vars.append(self.arena, .{
        .name = try uniqueHeld(self, name, idx),
        .ty = ty,
        .init = zeroOf(ty),
        .seed = seed,
        .array = id,
        .inits = inits,
    });
    try self.held_places.append(self.arena, place);
    return seed;
}

/// §3.2.2 is `name` a memory-backed array? A string array never is: a string
/// has no runtime storage (§3.3), so its runtime reads stay `$idx$str`.
pub fn isMemArray(self: *const Lower, name: Ast.StrId, ty: Ty) bool {
    return ty != .string and self.param_state.mem_names.contains(name);
}

/// §3.2.2 declare `name` as ONE storage of `shapeCells(dims)` elements and
/// return the place that holds its current version — when `zero`, a fresh one
/// with every element zero (§3.2); otherwise the caller writes the first.
pub fn declareMemArray(self: *Lower, name: []const u8, dims: []const Bounds, ty: Ty, zero: bool) Oom!Ssa.Place {
    const id: u32 = @intCast(self.out.mem_arrays.items.len);
    try self.out.mem_arrays.append(self.arena, .{ .name = name, .len = @intCast(shapeCells(dims)), .ty = ty });
    const place = self.builder.newPlace();
    try declareArray(self, name, .{ .dims = dims, .ty = ty, .mem = .{ .place = place, .id = id } });
    if (zero) try self.builder.writeVariable(place, self.cur, try self.mir.emitAnew(self.arena, self.cur, id));
    return place;
}

/// §3.2.2 `a[index] = v` on a memory-backed array: the next version.
pub fn storeElem(self: *Lower, place: Ssa.Place, index: Mir.Value, v: Mir.Value) Oom!void {
    const cur = try self.builder.readVariable(place, self.cur);
    try self.builder.writeVariable(place, self.cur, try self.emit(.store, &.{ cur, index, v }));
}

/// §3.2.2 element `index` of a memory-backed array's current version.
pub fn loadElem(self: *Lower, mem: ArrayInfo.Mem, ty: Ty, index: Mir.Value) Oom!Mir.Value {
    const cur = try self.builder.readVariable(mem.place, self.cur);
    return self.emit(if (ty == .integer) .iload else .fload, &.{ cur, index });
}

/// The flat element index of an in-range subscript tuple: row-major, each
/// dimension counted from its left bound — `shapeSubscripts`' inverse and
/// `lower_stmt.runtimeArrayIndex`'s order.
pub fn flatIndex(dims: []const Bounds, idx: []const i64) i64 {
    var flat: i64 = 0;
    for (dims, idx) |d, i| flat = flat * d.count() + (if (d.descending) d.hi - i else i - d.lo);
    return flat;
}

/// §3.2.2 constant-subscript element write for either representation: the
/// element's own place, or a store into the array's storage.
pub fn writeElem(self: *Lower, name: []const u8, info: ArrayInfo, idx: []const i64, v: Mir.Value) Oom!void {
    if (info.mem) |m| return storeElem(self, m.place, try self.mir.addIntConst(self.arena, flatIndex(info.dims, idx)), v);
    var key_buf: [elem_key_len]u8 = undefined;
    const slot = self.vars.get(try elemKey(self, &key_buf, name, idx)) orelse return;
    try self.builder.writeVariable(slot.place, self.cur, v);
}

/// §3.2.2 which arrays does some subscript index at run time? Lowering decides
/// that per reference (`lower_expr.lowerIndex`: a subscript `foldExpr(.., false)`
/// cannot fold), after the declaration has already chosen a representation, so
/// this answers it ahead of time, by NAME and over the whole source, with the
/// same rule: a subscript reading a variable, a parameter (a model card can
/// override it) or a call is runtime; a literal, a genvar (§3.5: an unrolled
/// loop binds it) and a local constant are not.
///
/// The answer only picks a representation — both lower every access — so a
/// wrong guess costs speed and never meaning. A runtime-indexed array kept
/// scalar reads through a `$idx` switch over every element and writes one
/// masked select per element; txl.va's 5 x 2048 histories were 26 MB of Zig.
pub fn markMemArrays(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    var vars: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    defer vars.deinit(self.arena);
    for (module.vars) |v| try vars.put(self.arena, v.name, {});
    for (module.functions) |f| {
        for (f.vars) |v| try vars.put(self.arena, v.name, {});
        for (f.args) |a| try vars.put(self.arena, a.name, {});
    }
    for (self.file.stmts.items) |st| if (st == .block) for (st.block.vars) |v| try vars.put(self.arena, v.name, {});
    const ex = &self.file.exprs;
    for (0..ex.nodes.len) |i| {
        const e: Ast.ExprId = @enumFromInt(@as(u32, @intCast(i)));
        if (ex.tag(e) != .index or !runtimeSub(self, &vars, module.genvars, ex.rhs(e))) continue;
        var base = ex.lhs(e);
        while (ex.tag(base) == .index) base = ex.lhs(base);
        if (ex.tag(base) == .ident) try self.param_state.mem_names.put(self.arena, ex.strOf(base), {});
    }
}

fn runtimeSub(self: *const Lower, vars: *const std.AutoHashMapUnmanaged(Ast.StrId, void), genvars: []const Ast.StrId, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const n = ex.strOf(e);
            if (std.mem.indexOfScalar(Ast.StrId, genvars, n) != null) return false;
            return vars.contains(n) or self.param_index.contains(self.file.str(n));
        },
        .call, .sys_call, .hier_ident, .branch_access, .port_access, .filter_call, .noise_call => return true,
        else => { // else: every other node is runtime exactly when an operand is
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (runtimeSub(self, vars, genvars, c)) return true;
            return false;
        },
    }
}

/// §5.10. Collect the variables assigned inside an `@(<event>)` body, before
/// any of them is declared.
pub fn markHeldVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.analog) |blk| try scanHeld(self, blk.body, false);
    self.param_state.held_frames.clearRetainingCapacity();
    // §3.2 retention, beside the §5.10 rule above: see `Exposed`.
    var x: Exposed = .{ .l = self, .vars = module.vars };
    for (module.analog) |blk| {
        // §5.2.1 an `analog initial` body runs on the first evaluation only,
        // so what it assigns is not assigned on the later ones.
        x.in_initial = blk.is_initial;
        if (blk.is_initial) try x.maybe(blk.body, .none) else try x.stmt(blk.body);
    }
    self.param_state.held_frames.clearRetainingCapacity();
    var it = x.reads.keyIterator();
    while (it.next()) |k| if (x.writes.contains(k.*)) {
        const gop = try self.param_state.held_names.getOrPut(self.arena, k.*);
        if (gop.found_existing) continue;
        // Otherwise the held value is observable only when a write's
        // placement varies from one evaluation to the next, which only
        // codegen's solve-invariance can say.
        gop.value_ptr.* = if (x.reach.contains(k.*) or x.initial.contains(k.*)) .retained else .unless_invariant;
    };
}

/// §3.2: "Real variables are initialized to zero (0) at the start of a
/// simulation" — once, not per evaluation — and §5.6.1.3: "Unlike variables,
/// the contributed value for a branch is only valid for the current
/// iteration." A variable keeps its value from one evaluation to the next.
///
/// Only a READ that some path reaches before any WRITE of the same evaluation
/// can observe that (an upward-exposed use), so those variables, if the analog
/// block writes them at all, get a §5.10 slot; one assigned before every read
/// on every path needs none. §7.3.2's `avar = avar; // hold value` is the case.
///
/// Two of those always observe the held value, so they are `.retained`: a
/// variable an `analog initial` body writes (§5.2.1, read on later
/// evaluations), and an exposed read that REACHES a later write of the same
/// evaluation (`avar = avar`: what it reads is what the last evaluation
/// wrote). The rest are `.unless_invariant`: no read precedes a write, so the
/// held value is seen only if whether a write runs changes between
/// evaluations — `codegen.pruneHeld` asks solve invariance.
///
/// §3.2.2 an array is its scalarized elements, so a write whose subscripts
/// are literals assigns that element, and an array read with a subscript that does not
/// fold (or of the whole array) needs every element assigned.
///
/// ponytail: a definite-assignment walk over the AST, conservative where it is
/// cheap to be — any other subscript assigns nothing, a loop or
/// event body may not run, and after a §5.11 `disable` nothing counts. Each is
/// a slot that might not be needed, never a hold that is missed.
const Exposed = struct {
    l: *Lower,
    /// The module's variables; a named block's are in `held_frames`.
    vars: []const Ast.VarDecl,
    /// Keys assigned on every path to here; `list` is the same set in the
    /// order added, so a branch is undone by truncating it.
    defs: std.StringHashMapUnmanaged(void) = .empty,
    list: std.ArrayList([]const u8) = .empty,
    /// Keys read where `defs` did not have them, and keys written anywhere.
    reads: std.StringHashMapUnmanaged(void) = .empty,
    writes: std.StringHashMapUnmanaged(void) = .empty,
    disabled: bool = false,
    /// Keys with an exposed read on SOME path to here (a may-set, undone per
    /// arm like `defs`); a write of one of them is reached by that read.
    pend: std.StringHashMapUnmanaged(void) = .empty,
    pend_list: std.ArrayList([]const u8) = .empty,
    reach: std.StringHashMapUnmanaged(void) = .empty,
    /// Keys an `analog initial` body writes.
    initial: std.StringHashMapUnmanaged(void) = .empty,
    in_initial: bool = false,

    fn def(x: *Exposed, k: []const u8) Oom!void {
        if (x.disabled or x.defs.contains(k)) return;
        try x.defs.put(x.l.arena, k, {});
        try x.list.append(x.l.arena, k);
    }

    fn undo(x: *Exposed, mark: usize) void {
        for (x.list.items[mark..]) |k| _ = x.defs.remove(k);
        x.list.shrinkRetainingCapacity(mark);
    }

    fn exposed(x: *Exposed, k: []const u8) Oom!void {
        try x.reads.put(x.l.arena, k, {});
        if (x.pend.contains(k)) return;
        try x.pend.put(x.l.arena, k, {});
        try x.pend_list.append(x.l.arena, k);
    }

    fn write(x: *Exposed, k: []const u8) Oom!void {
        try x.writes.put(x.l.arena, k, {});
        if (x.pend.contains(k)) try x.reach.put(x.l.arena, k, {});
        if (x.in_initial) try x.initial.put(x.l.arena, k, {});
    }

    /// §5.9 a loop body may run again after itself, so it is walked twice:
    /// a read in one iteration reaches a write in the next.
    fn loop(x: *Exposed, body: Ast.StmtId, step: Ast.StmtId) Oom!void {
        const mark = x.list.items.len;
        for (0..2) |_| {
            try x.stmt(body);
            try x.stmt(step);
        }
        x.undo(mark);
    }

    /// `a` then `b` on a path that may not take them (§5.10, §5.2.1).
    fn maybe(x: *Exposed, a: Ast.StmtId, b: Ast.StmtId) Oom!void {
        const mark = x.list.items.len;
        try x.stmt(a);
        try x.stmt(b);
        x.undo(mark);
    }

    /// One of `arms` runs; `.none` is the empty arm. Keeps what all assign.
    fn alts(x: *Exposed, arms: []const Ast.StmtId) Oom!void {
        const mark = x.list.items.len;
        const pmark = x.pend_list.items.len;
        var pended: std.ArrayList([]const u8) = .empty;
        var common: ?[]const []const u8 = null;
        for (arms) |arm| {
            try x.stmt(arm);
            // The arms exclude each other: one's reads reach no write of another.
            try pended.appendSlice(x.l.arena, x.pend_list.items[pmark..]);
            for (x.pend_list.items[pmark..]) |k| _ = x.pend.remove(k);
            x.pend_list.shrinkRetainingCapacity(pmark);
            const got = x.list.items[mark..];
            if (common) |c| {
                var keep: std.ArrayList([]const u8) = .empty;
                for (c) |k| for (got) |g| if (std.mem.eql(u8, k, g)) {
                    try keep.append(x.l.arena, k);
                    break;
                };
                common = keep.items;
            } else common = try x.l.arena.dupe([]const u8, got);
            x.undo(mark);
        }
        for (common orelse &.{}) |k| try x.def(k);
        for (pended.items) |k| if (!x.pend.contains(k)) {
            try x.pend.put(x.l.arena, k, {});
            try x.pend_list.append(x.l.arena, k);
        };
    }

    fn stmt(x: *Exposed, id: Ast.StmtId) Oom!void {
        if (id == .none) return;
        const self = x.l;
        const s = self.file.stmt(id);
        // §5.9.2 the init assignment runs once, before the condition is read.
        if (s == .for_stmt) try x.stmt(s.for_stmt.init);
        // §9.4 a print the device drops reads nothing in the device.
        const dropped = s == .sys_task and self.displays_dropped and
            lower_event.isDisplayTask(self.file.str(s.sys_task.name));
        if (!dropped) try self.file.stmtEdges(id, Own{ .x = x });
        const funcs: []const Ast.FuncDecl = if (self.out.module) |m| m.functions else &.{};
        var ws: std.ArrayList(Ast.ExprId) = .empty;
        try self.file.stmtWrites(funcs, id, self.arena, &ws);
        for (ws.items) |w| {
            const t = self.file.lvalueBase(w);
            if (t == .none) continue;
            const k = try heldKey(self, self.file.str(self.file.exprs.strOf(t)));
            try x.write(k);
            if (t == w) try x.def(k) else if (try x.elem(k, w)) |ek| try x.def(ek);
        }
        switch (s) {
            .block => |b| {
                // The same frames `scanHeld` keeps, so the keys agree.
                const named = b.name != .none;
                if (named) {
                    const outer = if (self.param_state.held_frames.getLastOrNull()) |f| f.prefix else "";
                    try self.param_state.held_frames.append(self.arena, .{
                        .prefix = try std.fmt.allocPrint(self.arena, "{s}{s}.", .{ outer, self.file.str(b.name) }),
                        .vars = b.vars,
                    });
                }
                for (b.body) |c| try x.stmt(c);
                if (named) _ = self.param_state.held_frames.pop();
            },
            .if_stmt => |c| try x.alts(&.{ c.then_s, c.else_s }),
            .case_stmt => |c| {
                var arms: std.ArrayList(Ast.StmtId) = .empty;
                var dflt = false;
                for (c.arms) |arm| {
                    try arms.append(self.arena, arm.body);
                    dflt = dflt or arm.labels.len == 0;
                }
                if (!dflt) try arms.append(self.arena, .none);
                try x.alts(arms.items);
            },
            .for_stmt => |c| try x.loop(c.body, c.step),
            .while_stmt => |c| try x.loop(c.body, .none),
            .repeat_stmt => |c| try x.loop(c.body, .none),
            .event_control => |c| try x.maybe(c.body, .none),
            .disable => x.disabled = true,
            // A `break`/`continue` leaves a loop body, whose assignments never
            // count past the loop anyway; `return` ends a function, not this.
            .jump, .empty, .event_trigger, .assign, .contribute, .indirect, .sys_task => {},
        }
    }

    /// `stmtEdges` visitor: the statement's own expressions, children skipped.
    const Own = struct {
        x: *Exposed,
        pub fn expr(o: Own, e: Ast.ExprId, edge: Ast.SourceFile.Edge) Oom!void {
            switch (edge) {
                .read, .branch => try o.x.read(e),
                .write => try o.x.subscripts(e),
            }
        }
        pub fn stmt(_: Own, _: Ast.StmtId) Oom!void {}
    };

    fn read(x: *Exposed, e: Ast.ExprId) Oom!void {
        if (e == .none) return;
        const file = x.l.file;
        const ex = &file.exprs;
        const t = file.lvalueBase(e);
        if (t != .none) {
            // Subscripts first; they are reads of their own.
            var i = e;
            while (i != t) : (i = ex.lhs(i)) try x.read(ex.rhs(i));
            const k = try heldKey(x.l, file.str(ex.strOf(t)));
            if (x.defs.contains(k)) return;
            if (t != e) if (try x.elem(k, e)) |ek| {
                if (!x.defs.contains(ek)) try x.exposed(k);
                return;
            };
            // The whole variable, or an element nobody can name statically.
            if (!x.allCells(k, file.str(ex.strOf(t)))) try x.exposed(k);
            return;
        }
        // §4.7.2.3 an `output` actual is written by the call, not read.
        if (ex.tag(e) == .call) {
            const funcs: []const Ast.FuncDecl = if (x.l.out.module) |m| m.functions else &.{};
            for (funcs) |fd| if (fd.name == ex.strOf(e)) {
                for (ex.args(e), 0..) |a, i| {
                    if (i < fd.args.len and fd.args[i].direction == .output) try x.subscripts(a) else try x.read(a);
                }
                return;
            };
        }
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| try x.read(c);
    }

    /// What writing lvalue `e` reads: only its subscripts, and an A.8.1
    /// assignment pattern's elements' (§4.7.2.3).
    fn subscripts(x: *Exposed, e: Ast.ExprId) Oom!void {
        if (e == .none) return;
        const ex = &x.l.file.exprs;
        if (ex.tag(e) == .assign_pattern) {
            for (ex.args(e)) |a| try x.subscripts(a);
            return;
        }
        var t = e;
        while (ex.tag(t) == .index) : (t = ex.lhs(t)) try x.read(ex.rhs(t));
    }

    /// `k[i][j]` when every subscript of `e` is a literal, else null.
    fn elem(x: *Exposed, k: []const u8, e: Ast.ExprId) Oom!?[]const u8 {
        const ex = &x.l.file.exprs;
        var idx: std.ArrayList(i64) = .empty;
        var i = e;
        while (ex.tag(i) == .index) : (i = ex.lhs(i)) {
            if (ex.tag(ex.rhs(i)) == .range) return null;
            // Not through a parameter: a model card may override it (§3.4).
            const c = lower_constfold.foldExpr(x.l, ex.rhs(i), false) orelse return null;
            try idx.insert(x.l.arena, 0, c.asInt());
        }
        return try elemName(x.l, k, idx.items);
    }

    /// Is every §3.2.2 element of array `k` (declared `name`) assigned?
    /// False for a scalar, whose own key `read` has already tried.
    fn allCells(x: *Exposed, k: []const u8, name: []const u8) bool {
        const decl = x.declOf(name) orelse return false;
        if (decl.dims.len == 0) return false;
        var cells: usize = 1;
        for (decl.dims) |d| {
            const a = lower_constfold.constEval(x.l, d.msb) orelse return false;
            const b = lower_constfold.constEval(x.l, d.lsb) orelse return false;
            cells *= @abs(a.asInt() - b.asInt()) + 1;
        }
        var have: usize = 0;
        for (x.list.items) |d| have += @intFromBool(d.len > k.len and std.mem.startsWith(u8, d, k) and d[k.len] == '[');
        return have == cells;
    }

    /// The nearest declaration of `name`, as `heldKey` resolves it.
    fn declOf(x: *Exposed, name: []const u8) ?*const Ast.VarDecl {
        const frames = x.l.param_state.held_frames.items;
        var i = frames.len;
        while (i > 0) {
            i -= 1;
            for (frames[i].vars) |*v| if (x.l.file.strings.eql(v.name, name)) return v;
        }
        for (x.vars) |*v| if (x.l.file.strings.eql(v.name, name)) return v;
        return null;
    }
};

/// §5.3.2: "The block names give a means of uniquely identifying all variables
/// at any simulation time." Which location an assignment target names is
/// decided by the NEAREST declaration of it, so the walk looks outward from the
/// innermost named block and falls back to the bare (module-scope) name — a
/// module variable assigned from inside a block is still the module's.
pub fn heldKey(self: *Lower, name: []const u8) Oom![]const u8 {
    var i = self.param_state.held_frames.items.len;
    while (i > 0) {
        i -= 1;
        const f = self.param_state.held_frames.items[i];
        for (f.vars) |v| {
            if (!self.file.strings.eql(v.name, name)) continue;
            return std.fmt.allocPrint(self.arena, "{s}{s}", .{ f.prefix, name });
        }
    }
    return name;
}

/// One walk, two modes: outside an event body we are only looking for the
/// `@(...)`; inside one, every variable a statement WRITES has to survive to
/// the next evaluation. "Writes" is `Ast.SourceFile.stmtWrites`, not only the
/// assignment target: an output actual or a `$random` seed written only inside
/// an event body used to revert to zero at the next evaluation.
pub fn scanHeld(self: *Lower, id: Ast.StmtId, in_event: bool) Oom!void {
    if (id == .none) return;
    if (in_event) {
        const funcs: []const Ast.FuncDecl = if (self.out.module) |m| m.functions else &.{};
        var writes: std.ArrayList(Ast.ExprId) = .empty;
        defer writes.deinit(self.arena);
        try self.file.stmtWrites(funcs, id, self.arena, &writes);
        // §3.2 `x[i] = …` holds the ARRAY; `declareVarDecl` scalarizes it.
        for (writes.items) |w| {
            const t = self.file.lvalueBase(w);
            if (t == .none) continue;
            try self.param_state.held_names.put(self.arena, try heldKey(self, self.file.str(self.file.exprs.strOf(t))), .event);
        }
    }
    switch (self.file.stmt(id)) {
        .block => |b| {
            // §5.3.2 only a NAMED block's locals are static, so only a label
            // opens a frame; an unnamed `begin`'s declarations are ordinary.
            const named = b.name != .none;
            if (named) {
                const outer = if (self.param_state.held_frames.getLastOrNull()) |f| f.prefix else "";
                try self.param_state.held_frames.append(self.arena, .{
                    .prefix = try std.fmt.allocPrint(self.arena, "{s}{s}.", .{ outer, self.file.str(b.name) }),
                    .vars = b.vars,
                });
            }
            for (b.body) |s| try scanHeld(self, s, in_event);
            if (named) _ = self.param_state.held_frames.pop();
        },
        // §5.10 forbids nesting, so `true` is never re-entered; lowering
        // diagnoses that (E0703) and this walk does not need to.
        .event_control => |s| try scanHeld(self, s.body, true),
        // The rest: only their child statements, whose writes the walk collects.
        else => try self.file.stmtEdges(id, Held{ .l = self, .in_event = in_event }), // else: stmtEdges is exhaustive
    }
}

const Held = struct {
    l: *Lower,
    in_event: bool,
    pub fn expr(_: Held, _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
    pub fn stmt(h: Held, s: Ast.StmtId) Oom!void {
        try scanHeld(h.l, s, h.in_event);
    }
};

pub fn zeroOf(ty: Ty) Mir.Value {
    return switch (ty) {
        .real => .f_zero,
        .integer => .zero,
        .string => .undef,
    };
}
