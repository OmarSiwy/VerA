//! §3.4 parameters: the model card's rows, and §2.9 attribute values.
//!
//! In: parameter/localparam declarations, `aliasparam`s and attribute specs.
//! Out: `Lowered.params` (the model-card ABI, one row per scalar and per
//! §3.4.4 array element), `Lowered.aliases`, the `consts` the constant
//! folder reads, and `param_values`/`param_index`, through which every later
//! read of a parameter goes. A row's `ranges` reach proof.zig as bound
//! evidence.
//!
//! LRM clauses this file's code cites: §2.9, §2.9.2, §3.4, §3.4.1, §3.4.2, §3.4.4, §3.4.5,
//! §3.4.7, §4.2.1.1, §4.2.13, §5.5.3, §6.3, §6.3.4, §6.6.1, §6.7.1, §9.18.

const std = @import("std");
const hier_param = @import("../hier_param.zig");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const diag = @import("diag");
const Oom = Lower.Oom;
const Const = Lower.Const;
const astTy = Lower.astTy;
/// §3.4 every parameter of the module, in source order, so a default may read
/// an earlier one (§6.3.4): the §6.3.6 geometry aliases first, then each
/// declaration, then the §6.4.2 selection parameters marked as shape. Runs
/// before the ports, whose ranges may read a parameter.
pub fn lowerParams(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    // One row per scalar declaration and per system alias, sized once: grown
    // row by row in the arena, the table left ~2.8x its final size behind in
    // abandoned copies (210 KB for psp103's 847 rows). An array parameter's
    // elements still grow it past this.
    const rows = module.params.len + module.aliasparams.len;
    try self.out.params.ensureTotalCapacityPrecise(self.arena, self.out.params.items.len + rows);
    try self.param_values.ensureTotalCapacityPrecise(self.arena, self.param_values.items.len + rows);
    // `consts` too: it is only ever probed by name, so its capacity reaches no
    // output. (`param_index` is not pre-sized: `didYouMeanMap` walks it, and a
    // walk's order follows the capacity.)
    try self.consts.ensureTotalCapacity(self.arena, self.consts.count() + @as(u32, @intCast(rows)));
    // §3.4 parameters before the ports, because a range is a constant
    // expression over them: §6.5.2.2's own example is `input [1:width] dt`
    // with `width` a module parameter, and `foldDim` cannot answer that from
    // an empty `consts`. A parameter declaration cannot name a net (§3.4
    // defaults are constant expressions), so the order is otherwise free.
    // §6.3.6 implicitly declares the geometry controls. Register their
    // top-level aliases before the explicit parameters so they exist
    // before a flattened child's dependent defaults read them. Keep the
    // existing `$mfactor` host/scaling ABI in its separate alias path below.
    for (module.aliasparams) |a| {
        const kind = hier_param.Kind.fromName(self.file.str(a.target)) orelse continue;
        if (kind == .mfactor) continue;
        const alias = self.file.str(a.alias);
        const collides = self.param_index.contains(alias) or for (module.params) |p| {
            if (p.name == a.alias) break true;
        } else false;
        if (collides) {
            try self.err(module.main_tok, .E0331, "`{s}`", .{alias});
            continue;
        }
        _ = try aliasSystemParam(self, alias, self.file.str(a.target));
    }
    for (module.params) |*p| try lowerParamDecl(self, p);
    for (self.selection_params) |name| if (self.param_index.get(self.file.str(name))) |i| {
        self.out.params.items[i].shape = true;
    };
}

/// §3.4.7 each `aliasparam` other than a §6.3.6 geometry alias (`lowerParams`
/// declared those): a second name for an existing parameter, or for a system
/// parameter (`aliasSystemParam`). E0331 when the alias collides, E0303 when
/// the target is unknown.
pub fn declareAliasParams(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    // §3.4 parameters were lowered above the port loop, in source order, so a
    // later default may still reference an earlier parameter (§6.3.4).
    // §3.4.7 aliasparam: a second name for an existing parameter.
    for (module.aliasparams) |a| {
        const target = self.file.str(a.target);
        const alias = self.file.str(a.alias);
        if (hier_param.Kind.fromName(target)) |kind|
            if (kind != .mfactor) continue; // already declared above
        // §3.4.7 "The alias_identifier shall not occur anywhere else in the
        // module; in particular, it shall not conflict with a different
        // parameter_identifier". Unchecked, the `put` below would rebind the
        // colliding name for the rest of the module.
        if (!self.param_index.contains(alias) and try aliasSystemParam(self, alias, target)) continue;
        if (self.param_index.contains(alias)) {
            var b = self.errWith(module.main_tok, .E0331);
            b.msg("`{s}`", .{alias});
            b.help("an `aliasparam` gives `{s}` a second NAME, it does not declare a second parameter", .{target});
            try b.emit();
            continue;
        }
        if (self.param_index.get(target)) |idx| {
            try self.param_index.put(self.arena, alias, idx);
            try self.out.aliases.append(self.arena, .{ .name = alias, .param = idx });
        } else {
            var b = self.errWith(module.main_tok, .E0303);
            b.msg("`{s}`", .{target});
            if (diag.didYouMeanMap(target, self.param_index)) |s|
                b.help("did you mean `{s}`?", .{s});
            try b.emit();
        }
    }
}
/// Registers a parameter: infers its type (§3.4.1), folds its default, and
/// copies `decl.ranges` into `ParamInfo.ranges` for the prover (LRM §3.4, §3.4.2).
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
    // carry (`parameter real bad = $abstime;` would read 0.0). Reported and
    // then lowered anyway, like E0347.
    if (@import("frontend").constfold.firstStateRead(self.file, decl.default, if (self.out.module) |m| m.vars else &.{})) |what| {
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
            break @import("frontend").constfold.parameterCardValue(decl.ty, declared, o.value);
    } else null;
    const folded = over orelse declared;
    // §4.2.1.1 converts by "rounding the real number to the nearest integer",
    // and an infinity or a NaN has none: `parameterConst` leaves such a value
    // real, so it is refused here rather than saturated on the card.
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
    // parameter may not be frozen at its folded value: the host overrides the
    // base after elaboration and the dependent has to follow it.
    // `foldExpr(..., false)` refuses to look through a parameter, so it is the
    // "may this be baked into the model card?" test; `folded` above cannot be,
    // for the §6.6.1 reason. Codegen turns the surviving expression into `derive()`.
    const default = if (over) |c| switch (c) {
        .int => |n| try self.mir.addIntConst(self.arena, n),
        .real => |n| try self.mir.addFloatConst(self.arena, n),
        .str => unreachable, // a card value is a real
    } else try parameterDefault(self, decl.default, decl.ty);

    try addParam(self, name, ty, default, folded, decl.ranges, decl.is_local, decl.main_tok);
    self.out.params.items[self.out.params.items.len - 1].integer32 = decl.ty == .integer;
    self.out.params.items[self.out.params.items.len - 1].source_width = if (decl.packed_range) |range|
        lower_shape.packedShapeWidth(self, range)
    else if (decl.ty == .integer)
        32
    else
        lower_constfold.clog2Width(self, decl.default);
    self.out.params.items[self.out.params.items.len - 1].source_signed = if (decl.ty == .integer)
        true
    else if (decl.packed_range != null or decl.is_signed)
        decl.is_signed
    else
        lower_constfold.clog2Signed(self, decl.default);
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

/// §3.4.2: "The parameter value shall be within the range from the smallest
/// value specified to the largest value specified", minus everything an
/// `exclude` removes. Several `from` clauses are a UNION — the clause's own
/// example writes two — so the test is "inside at least one", not "inside all".
///
/// Only reached for a §6.3 override (see the call site). Nothing is reported
/// when a bound or the value will not fold: §3.4.2 admits a constant expression
/// over earlier parameters, and a bound that reads an overridable parameter has
/// no single value at compile time.
fn checkParamRange(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8, folded: ?Const) Oom!void {
    const c = folded orelse return;
    if (c == .str) {
        var has_from = false;
        var in_from = false;
        for (decl.ranges) |r| {
            const off = r.strings orelse continue;
            const contains = for (self.file.exprs.list(off)) |id| {
                if (std.mem.eql(u8, c.str, self.file.str(@fromBackingInt(@intCast(id))))) break true;
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
fn rangeBound(self: *Lower, e: Ast.ExprId) ?f64 {
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
fn checkParamType(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8, folded: ?Const) Oom!void {
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

/// §3.4.7/§9.18 permits aliases of all six system parameters. The first
/// alias supplies a model-card slot with Table 9-29's top-level default;
/// additional aliases share that slot. A child alias is resolved earlier,
/// by elaboration, so it never replaces the top-level system value here.
///
/// As before, a host overriding the `$mfactor` alias must also keep the
/// `Instance.mfactor` scaling field consistent with that model-card value.
pub fn aliasSystemParam(self: *Lower, alias: []const u8, target: []const u8) Oom!bool {
    const kind = hier_param.Kind.fromName(target) orelse return false;
    if (self.hier_params.get(kind)) |idx| {
        try self.param_index.put(self.arena, alias, idx);
        try self.out.aliases.append(self.arena, .{ .name = alias, .param = idx });
        return true;
    }
    self.hier_params.set(kind, @intCast(self.out.params.items.len));
    const value = kind.initial();
    try addParam(self, alias, .real, try self.mir.addFloatConst(self.arena, value), .{ .real = value }, &.{}, false, Mir.no_tok);
    return true;
}

/// Appends a model-card parameter and binds `name` to its index. An integer
/// localparam with a constant default reads as that constant; everything else
/// reads the card.
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
const parameterConst = @import("frontend").constfold.parameterValue;

/// The MIR must contain the same declared-type conversion as `folded` metadata.
/// Later defaults and operator controls follow this MIR, not the Model field.
fn parameterDefault(self: *Lower, e: Ast.ExprId, ty: Ast.Type) Oom!Mir.Value {
    if (e == .none) return lower_var.zeroOf(astTy(ty));
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
fn lowerParamArray(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8) Oom!void {
    const dims = try lower_shape.dimsBounds(self, decl.dims, decl.main_tok, name) orelse return;
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
    const elems = try lower_shape.flattenPattern(self, decl.default, dims);

    try lower_var.declareArray(self, name, .{ .dims = dims, .ty = astTy(ty) });
    var sub: [lower_shape.max_stack_dims]i64 = undefined;
    const idx = try lower_shape.subscriptBuf(self, &sub, dims.len);
    for (elems, 0..) |elem, k| {
        lower_shape.shapeSubscripts(dims, k, idx);
        const default = try parameterDefault(self, elem, ty);
        // §3.4.4 an omitted element is the type's zero; anything else folds
        // through the declared defaults exactly as a scalar's does.
        const folded: ?Const = if (elem == .none)
            (if (astTy(ty) == .real) Const{ .real = 0 } else Const{ .int = 0 })
        else
            lower_constfold.constEval(self, elem);
        try addParam(self, try lower_shape.elemName(self, name, idx), ty, default, if (folded) |c| parameterConst(ty, c) else null, decl.ranges, decl.is_local, decl.main_tok);
    }
}

/// §2.9's two rules about an attribute VALUE, and §2.9.2's four value domains.
///
/// In lowering because "constant expression" depends on the declaration
/// tables. The parser (`Parser.parseAttributes`) checks the nesting ban. The
/// attribute's target is not needed: neither rule is about the decorated item.
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
fn joinQuoted(arena: std.mem.Allocator, items: []const []const u8) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, i| {
        if (i != 0) try out.appendSlice(arena, if (i + 1 == items.len) " or " else ", ");
        try out.print(arena, "\"{s}\"", .{it});
    }
    return out.toOwnedSlice(arena);
}
