//! §4.5 analog operators and filters.
//!
//! In: ddt/idt/absdelay/transition/slew/laplace/zi/... calls. Out: MIR `call`s plus the
//! operator state rows `lib/ir/op.zig` describes.
//!
//! LRM clauses this file's code cites: §4.5, §4.5.2, §4.5.5, §4.5.6, §4.5.10, §4.5.11, §4.5.12, §4.5.13, §4.6.4, §4.6.4.3, §5.5.3, §5.8.1.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_analog_op.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_param = @import("param.zig");
const lower_table_model = @import("table_model.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const err = Lower.err;
const errWith = Lower.errWith;
const poison = Lower.poison;
const emit = Lower.emit;
const call = Lower.call;
const toReal = Lower.toReal;

// ---- §4.5 analog operators / filters ---------------------------------------

/// §4.5 analog operators. Each occurrence owns simulator state, so every one
/// stays a distinct `call` instruction carrying its arguments — codegen
/// allocates one Instance state slot per call site (§4.5.2).
///
/// Vector coefficient arguments (§4.5.11 laplace_*, §4.5.12 zi_*) are
/// FLATTENED into the argument list as `<count>, e0, e1, …`, so the call is
/// self-describing without a second pool.
/// The two A.8.2 `analog_filter_function_call` names that keep NO history.
///
/// §5.8.1 bans "an analog operator" under a runtime condition, and both of these
/// are listed in §4.5, so the letter of the rule covers them. Its stated reason
/// does not: §4.5.6 makes `ddx` a derivative of the expression as it stands on
/// THIS evaluation, and §4.5.13 makes `limexp` a piecewise-linear substitution
/// for `exp` past a critical voltage. Neither reads a previous timestep, so
/// neither can carry a wrong history out of a branch that was off — and E0514's
/// whole claim is about corrupted history. Warning on them would be noise that
/// teaches a modeller to silence the code; `vdmos.va` uses conditional `limexp`
/// three times and is right to.
pub fn isHistoryless(name: []const u8) bool {
    return std.mem.eql(u8, name, "ddx") or std.mem.eql(u8, name, "limexp");
}

/// §4.5.15's placement rules for the analog operator `name` at `e`. EVERY path
/// that lowers one calls this — `lowerFilter`, and `lowerReactive`'s `ddt`
/// spine, which strips the call without going through `lowerFilter` and so
/// once let `if (V(p) > 0) I(p) <+ ddt(V(p));` compile. False when the
/// operator must not be lowered at all.
pub fn checkOperatorPlace(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!bool {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx});
        return false;
    }
    // §5.8.1 / §5.9: an analog operator is a state machine the kernel advances
    // once per accepted step, on the straight-line spine of the analog block.
    // Under a branch the solve can flip, the step its arm was off feeds it the
    // type's zero instead of the real input, and its history is wrong from then
    // on.
    if (self.cond_depth != self.static_cond_depth and !isHistoryless(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0514);
        b.msg("`{s}`", .{name});
        b.help("hoist `{s}(...)` onto the spine and make only its USE conditional", .{name});
        try b.emit();
    }
    return true;
}

pub fn lowerFilter(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);
    if (!try checkOperatorPlace(self, e, name)) return poison;

    // §4.5.6 ddx(f, V(node)) — the second argument is a probe, not a value:
    // it names the unknown to differentiate with respect to.
    if (std.mem.eql(u8, name, "ddx")) {
        if (args.len != 2) return lower_expr.arityError(self, e, name, 2);
        const f = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        if (ex.tag(args[1]) != .branch_access) {
            try self.err(self.file.exprs.mainTok(e), .E0504, "", .{});
            return poison;
        }
        const t = try lower_contrib.branchOf(self, args[1]) orelse return poison;
        // §4.5.6: "The second argument shall be the potential of a scalar net
        // or port or the flow through a branch, because these are the unknown
        // variables in the system of equations for the analog solver."
        //
        // `V(p, n)` is neither. It is the DIFFERENCE of two unknowns, and the
        // operator is defined as the partial derivative "holding all other
        // unknowns fixed" — which V(p)-V(n) makes unanswerable, since d/dV(p)
        // and -d/dV(n) are both defensible readings and they differ. §4.5.6's
        // own vccs example puts the two-node probe in the EXPRESSION and a
        // single-node probe in the second slot. A FLOW is exempt: a branch
        // current is one unknown however many nets the branch spans.
        if (t.access == .potential and t.lo != ground) {
            try self.err(self.file.exprs.mainTok(args[1]), .E0504, "a potential across two nets is not one unknown", .{});
            return poison;
        }
        try lower_hier_name.refuseRuntime(self, self.file.exprs.mainTok(args[1]), t.hi, t.lo);
        const u: u16 = switch (t.access) {
            .potential => t.hi,
            // PEEK — never mint. §4.5.6's closing sentence: "If the expression
            // does not depend explicitly on the unknown, then ddx() returns
            // zero (0)." A flow no probe has made a system unknown CANNOT be
            // depended on: the only way a branch current enters an expression
            // is through an `I()` read, and every read routes through
            // `flowUnknown` — including any inside THIS ddx's first argument,
            // which was lowered above, so the peek runs after every mint that
            // could matter. Minting here declared an unknown no equation ever
            // pins (the probe-branch row only exists for a READ branch): an
            // all-zero Jacobian row and a structurally singular system. And
            // recording a branch READ instead would make the pair a flow-probe
            // branch — a 0 V short §4.5.6 gives a derivative operator no
            // license to add to the topology. Absent unknown = the plain 0.
            .flow => self.out.flow_unknowns.get(.{ .hi = t.hi, .lo = t.lo }) orelse
                return .{ .v = .f_zero, .ty = .real },
        };
        const d = try self.call("ddx", &.{ f, try self.mir.addIntConst(self.arena, u) });
        // §1.3.1.2 again: `ddx(f, I(n,p))` differentiates with respect to the
        // negation of the one canonical unknown, so the derivative negates too.
        // A potential probe reaches here only in the single-net form, which the
        // check above enforces and which is never reversed.
        return .{ .v = if (t.neg) try self.emit(.fneg, &.{d}) else d, .ty = .real };
    }

    // A.8.2 fixes each operator's MANDATORY arguments — everything left of the
    // grammar's first `[`. The per-slot loop below judges only slots that were
    // WRITTEN (`ddt(,1.0)` → E0505), so a list that stops early has to be
    // measured against the grammar here: `ddt()` otherwise skipped the loop
    // entirely and became a silent zero, `absdelay(x)` a delay of nothing.
    // The laplace forms mandate three slots — both vector commas sit outside
    // the brackets, so a slot may be NULL (the loop's `nullZerosOk` carve-out
    // governs which) but it must be THERE — and the zi forms four (…, T).
    const min_args: usize = if (std.mem.eql(u8, name, "absdelay"))
        2
    else if (std.mem.startsWith(u8, name, "laplace_"))
        3
    else if (std.mem.startsWith(u8, name, "zi_"))
        4
    else
        1; // ddt, idt, idtmod, transition, slew, last_crossing, limexp
    if (args.len < min_args) {
        try self.err(self.file.exprs.mainTok(e), .E0505, "`{s}()` needs {d} argument(s), got {d}", .{ name, min_args, args.len });
        return poison;
    }

    try checkFilterArgBounds(self, name, args); // §4.5.5-§4.5.10

    const abstol_slot = abstolSlot(name);

    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (args, 0..) |a, i| {
        // A.8.2 analog_filter_function_call has no `analog_expression_or_null`
        // form: every declared argument must be present (§4.5.14).
        //
        // §4.5.15 states the rule with its own escape hatch — "It is illegal to
        // specify a null argument in the argument list of an analog operator,
        // EXCEPT AS SPECIFIED ELSEWHERE in this document" — and §4.5.11/§4.5.12
        // are what the exception points at, in the identical sentence: "The
        // zeros argument may be represented as a null argument. The null
        // argument is characterized by two adjacent commas (,,) in the argument
        // list." §4.5.11.5's own band-limited-noise example writes it. An empty
        // zeros vector is an empty PRODUCT, hence the numerator 1 — which is
        // why the carve-out is only for the root forms (`*_zp`, `*_zd`), where
        // the slot is a list of roots. In `*_np`/`*_nd` the same slot is a
        // coefficient vector, and an empty one has no such reading.
        if (a == .none) {
            if (i == 1 and nullZerosOk(name)) {
                try vals.append(self.arena, try self.mir.addIntConst(self.arena, 0));
                continue;
            }
            try self.err(self.file.exprs.mainTok(e), .E0505, "`{s}()`", .{name});
            return poison;
        }
        // A.8.3 `abstol_expression ::= constant_expression | nature_identifier`.
        // The second arm is the ONLY place a nature name is a value, so it is
        // resolved here and not in `lookupName`: natures and disciplines share
        // one global scope (§3.13.1), and letting that scope answer general
        // identifier lookup would shadow every variable named after a nature.
        if (abstol_slot == i) {
            if (natureAbstol(self, a)) |t| {
                try vals.append(self.arena, try self.mir.addFloatConst(self.arena, t));
                continue;
            }
        }
        if (try appendVectorArg(self, &vals, a)) continue;
        const tv = try lower_expr.lowerExpr(self, a);
        try vals.append(self.arena, if (tv.ty == .string) tv.v else try self.toReal(tv));
    }
    return .{ .v = try self.call(name, vals.items), .ty = .real };
}

/// Which argument of an analog operator is its TOLERANCE, or null for an
/// operator that has none. §5.5.3, last sentence: "The abstol attribute of a
/// nature may also be accessed simply by using the nature's identifier as the
/// appropriate argument to the ddt(), idt(), or idtmod() operators described in
/// 4.5." Those three, and the slot each of their signatures puts it in:
///
///     4.5.3  ddt(expr [, abstol|nature])
///     4.5.4  idt(expr [, ic [, assert [, abstol|nature]]])
///     4.5.5  idtmod(expr [, ic [, modulus [, offset [, abstol|nature]]]])
///
/// Every one is the LAST slot, but they are written out rather than computed
/// from `args.len` because a call that has dropped a trailing argument would
/// then read its `assert` or its `offset` as a tolerance.
pub fn abstolSlot(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "ddt")) return 1;
    if (std.mem.eql(u8, name, "idt")) return 3;
    if (std.mem.eql(u8, name, "idtmod")) return 4;
    return null;
}

/// The abstol a bare `nature_identifier` in a tolerance slot stands for, or
/// null when the expression is not one — in which case the caller lowers it as
/// the `constant_expression` arm of A.8.3 and every ordinary diagnostic applies.
///
/// The ordinary scopes are consulted FIRST, so a variable or parameter that
/// happens to share a nature's name still wins here exactly as it does
/// everywhere else (§2.8). Only a name nothing else answers reaches the nature
/// table.
/// The §4.5.3/§5.5.3 tolerance slot as a value, with its diagnostics. Returns
/// null when the slot holds an ordinary expression, which the caller lowers as
/// A.8.3's `constant_expression` arm.
pub fn lowerAbstolArg(self: *Lower, e: Ast.ExprId) Oom!?f64 {
    if (natureAbstol(self, e)) |t| return t;
    // A `.banned` reference has no value; `lowerExpr` is where E0359 lives, so
    // the argument is lowered for its diagnostic and the result discarded.
    if (self.file.exprs.tag(e) == .hier_ident) _ = try lower_expr.lowerExpr(self, e);
    return null;
}

pub fn natureAbstol(self: *Lower, e: Ast.ExprId) ?f64 {
    const ex = &self.file.exprs;
    // §5.5.3's other spelling of the same value, `n1.potential.abstol`. Its last
    // sentence makes the two interchangeable in this slot: "The abstol attribute
    // of a nature may ALSO be accessed simply by using the nature's identifier
    // as the appropriate argument to the ddt(), idt(), or idtmod() operators".
    if (ex.tag(e) == .hier_ident) {
        // A `.banned` attribute is diagnosed by `lowerExpr`, which every caller
        // falls through to; returning null here is what routes it there.
        const r = natureAttrRef(self, e) orelse return null;
        return switch (r) {
            .value => |c| switch (c) {
                .real, .int => c.asReal(),
                .str => null,
            },
            .banned => null,
        };
    }
    if (ex.tag(e) != .ident) return null;
    const id = ex.strOf(e);
    const name = self.file.str(id);
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name))
        return null;
    for (self.file.natures) |*n| {
        if (n.name != id) continue;
        // §3.6.1.2 makes `abstol` mandatory on a base nature and inherited by a
        // derived one, and `checkNatureTable` has already refused a nature with
        // neither, so the fallback is only ever reached on a compile that is
        // failing anyway. It is here so that this returns "yes, a nature" and
        // the name does not also collect an E0314.
        return lower_discipline.natureOf(self, id).abstol orelse 0;
    }
    return null;
}

/// §5.5.3 Syntax 5-4 `nature_attribute_reference ::= net_identifier .
/// potential_or_flow . nature_attribute_identifier` — "the attributes for a net
/// or a branch can be accessed by using the hierarchical referencing operator
/// (.) to the potential or flow for the net or branch". §5.5.3's own twocap
/// example is `ddt(V(a,b), a.potential.abstol)`.
///
/// A constant, resolved at elaboration: the net's discipline decides which
/// nature each half binds, and a nature attribute "shall be constant"
/// (§3.6.1.3). Null when the expression is a §6.8 hierarchical name instead,
/// which is the other thing `.hier_ident` carries.
///
/// `abstol` comes from `DisciplineInfo` and not from the nature, deliberately:
/// §3.6.2.3 lets a DISCIPLINE override its bound nature's tolerance, and that
/// map is where the override has already been applied.
///
/// The sentence right after Syntax 5-4 is enforced by the same walk: "This
/// syntax shall not be used for the access, ddt_nature, or idt_nature attributes
/// of a nature, nor any other attribute whose value is not a constant
/// expression." Those three name an IDENTIFIER, so there is nothing to fold —
/// which is why the ban and the fold are one test (`.banned`) and not two.
pub const NatureRef = union(enum) {
    value: Const,
    /// The attribute named, for the message.
    banned: []const u8,
};
pub fn natureAttrRef(self: *Lower, e: Ast.ExprId) ?NatureRef {
    const parts = self.file.exprs.nameParts(e);
    if (parts.len != 3) return null;
    const half = self.file.str(parts[1]);
    const is_potential = std.mem.eql(u8, half, "potential");
    if (!is_potential and !std.mem.eql(u8, half, "flow")) return null;

    const net = self.file.str(parts[0]);
    const idx = self.node_voltages.get(net) orelse return null;
    if (idx == ground) return null;
    const dname = self.out.nodes.items(.disc)[idx];
    const attr = self.file.str(parts[2]);

    if (std.mem.eql(u8, attr, "abstol")) {
        const info = self.out.disciplines.get(dname) orelse return null;
        return .{ .value = .{ .real = if (is_potential) info.potential_abstol else info.flow_abstol } };
    }
    // ponytail: reuse compatibility's first-declaration lookup.
    const d = lower_discipline.disciplineDecl(self, dname) orelse return null;
    const nat = if (is_potential) d.potential else d.flow;
    if (nat == .none) return null;
    const v = self.file.natureAttrExpr(nat, attr) orelse return .{ .banned = attr };
    return .{ .value = lower_constfold.constEval(self, v) orelse return .{ .banned = attr } };
}

/// §4.5.5-§4.5.10 control-argument bounds. Each operator states its bound in
/// one sentence and each bound is what makes the operator's own contract
/// satisfiable — see E0516 for the five sentences.
///
/// FOLDED OPERANDS ONLY, and that restraint is the rule and not a shortcut:
/// A.8.2 types these slots `analog_expression`, not `constant_expression`, so
/// `transition(x, 0, tr, tf)` over parameters is a legal model whose signs are
/// unknowable here. `constEval` returning null is silence. Rejecting what
/// cannot be proven would break every parameterised rise time in the wild.
///
/// Here and not in codegen because this is a claim about the ARGUMENT: by the
/// time a filter is a `call` its arguments are positional values and the LRM's
/// own names for them — the words the diagnostic has to say — are gone.
pub fn checkFilterArgBounds(self: *Lower, name: []const u8, args: []const Ast.ExprId) Oom!void {
    const Bound = enum {
        positive,
        non_negative,
        negative,

        fn holds(b: @This(), v: f64) bool {
            return switch (b) {
                .positive => v > 0,
                .non_negative => v >= 0,
                .negative => v < 0,
            };
        }
        /// The LRM's own word for the bound; it goes in the message.
        fn word(b: @This()) []const u8 {
            return switch (b) {
                .positive => "positive",
                .non_negative => "non-negative",
                .negative => "negative",
            };
        }
    };
    const Rule = struct { i: usize, arg: []const u8, want: Bound };
    const rules: []const Rule = if (std.mem.eql(u8, name, "idtmod"))
        &.{.{ .i = 2, .arg = "modulus", .want = .positive }}
    else if (std.mem.eql(u8, name, "absdelay"))
        // "In all cases" covers the optional-maxdelay form too, so the index is
        // the same for both spellings.
        &.{.{ .i = 1, .arg = "td", .want = .positive }}
    else if (std.mem.eql(u8, name, "transition"))
        &.{
            .{ .i = 1, .arg = "td", .want = .non_negative },
            .{ .i = 2, .arg = "rise_time", .want = .non_negative },
            .{ .i = 3, .arg = "fall_time", .want = .non_negative },
            .{ .i = 4, .arg = "time_tol", .want = .non_negative },
        }
    else if (std.mem.eql(u8, name, "slew"))
        // Checked on the WRITTEN arguments, before §4.5.9's "if the
        // max_neg_slew_rate is not specified, it defaults to the opposite of
        // the max_pos_slew_rate" can manufacture a well-signed second rate out
        // of a badly-signed first one.
        &.{
            .{ .i = 1, .arg = "max_pos_slew_rate", .want = .positive },
            .{ .i = 2, .arg = "max_neg_slew_rate", .want = .negative },
        }
    else
        &.{};

    for (rules) |r| {
        if (r.i >= args.len or args[r.i] == .none) continue;
        const c = lower_constfold.constEval(self, args[r.i]) orelse continue;
        if (c == .str) continue; // a type error, not a range one
        const v = c.asReal();
        if (r.want.holds(v)) continue;
        try self.err(self.file.exprs.mainTok(args[r.i]), .E0516, "`{s}()` argument `{s}` shall be {s}, got {d}", .{ name, r.arg, r.want.word(), v });
    }

    // §4.5.10: "The optional direction indicator shall evaluate to an integer
    // expression +1, -1, or 0." An enumeration of three, not a range — +2 does
    // not select anything and there is nothing to clamp it onto.
    if (std.mem.eql(u8, name, "last_crossing") and args.len > 1 and args[1] != .none) {
        if (lower_constfold.constEval(self, args[1])) |c| {
            const v = c.asReal();
            if (c != .str and (v != @round(v) or @abs(v) > 1))
                try self.err(self.file.exprs.mainTok(args[1]), .E0516, "`last_crossing()` direction indicator shall be +1, -1 or 0, got {d}", .{v});
        }
    }
}

/// §4.5.11/§4.5.12 filter coefficient vectors and §9.21/§4.6.4 noise data
/// vectors: an assignment pattern `'{a,b}` or the name of an array parameter
/// (§3.4.4). Flattened into the call as `<count>, e0, e1, …`, so the argument
/// list stays self-describing. Returns false when `a` is an ordinary scalar.
/// §4.5.11/§4.5.12: does this filter take its ZEROS as a root vector, so that
/// the null form `f(x, , poles, …)` reads as the empty product 1?
pub fn nullZerosOk(name: []const u8) bool {
    const forms = [_][]const u8{ "laplace_zp", "laplace_zd", "zi_zp", "zi_zd" };
    for (forms) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

pub fn appendVectorArg(self: *Lower, out: *std.ArrayList(Mir.Value), a: Ast.ExprId) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(a)) {
        .assign_pattern, .concat => {
            const elems = try lower_param.patternElems(self, a);
            try out.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(elems.len)));
            for (elems) |el|
                try out.append(self.arena, try self.toReal(try lower_expr.lowerExpr(self, el)));
            return true;
        },
        .ident => {
            const name = self.file.str(ex.strOf(a));
            const info = self.arrays.get(name) orelse return false;
            // §4.5.11's coefficient slot is a FLAT vector: a multidimensional
            // array has no reading as a list of poles and is left to the
            // ordinary path, which reports it (E0356).
            if (info.dims.len != 1) return false;
            const d = info.dims[0];
            try out.append(self.arena, try self.mir.addIntConst(self.arena, d.count()));
            var index: [1]i64 = undefined;
            for (0..@intCast(d.count())) |k| {
                lower_param.shapeSubscripts(info.dims, k, &index);
                const el = (try lower_expr.arrayElemValue(self, name, &index)) orelse return true;
                try out.append(self.arena, try self.toReal(el));
            }
            return true;
        },
        else => return false, // else: not one of §4.5.11's two vector shapes; the ordinary path lowers or reports it
    }
}

/// §4.6.4 noise sources. They contribute only in a small-signal noise
/// analysis; codegen decides that from the call name (the value is 0 in DC).
pub fn lowerNoise(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    // A.8.2 `ac_stim ( [ " analysis_identifier " [ , analog_expression ...` —
    // the quotation marks are in the production, so the analysis name is a
    // string LITERAL and nothing else (a string parameter is §4.6.4.3's
    // allowance for a noise table's file name, not this one's).
    if (std.mem.eql(u8, name, "ac_stim")) if (ex.args(e).len != 0) {
        const a0 = ex.args(e)[0];
        if (a0 != .none and ex.tag(a0) != .str_literal) {
            try self.err(ex.mainTok(a0), .E0521, "", .{});
            return poison;
        }
    };
    // Syntax 4-4 `flicker_noise ( analog_expression , analog_expression
    // [ , string ] )`: only the name is bracketed. §4.6.4.2's "1/f^exp" has no
    // default exponent, so a one-argument call has no spectrum to invent.
    if (std.mem.eql(u8, name, "flicker_noise")) {
        var n: usize = 0;
        for (ex.args(e)) |a| n += @intFromBool(a != .none);
        if (n < 2) {
            try self.err(ex.mainTok(e), .E0522, "got {d} argument(s)", .{n});
            return poison;
        }
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    // §4.6.4 the PSD arguments, positionally: arg 0 is the power, arg 1 of
    // `flicker_noise` is the exponent. Recorded HERE — this is the only place
    // the call's arguments are lowered, and `noiseSrcsOf` walks the AST after
    // the fact, where the MIR values are no longer reachable from the id.
    // §4.6.3 has its OWN defaults for the same two slots — "The default
    // magnitude is one (1) and the default phase is zero (0)" — and seeding
    // them here is what makes a bare `ac_stim()` export the unit source the
    // clause describes instead of a magnitude of zero.
    var psd: [2]Mir.Value = if (std.mem.eql(u8, name, "ac_stim"))
        .{ .f_one, .f_zero }
    else
        .{ .f_zero, .f_one };
    var reals: usize = 0;
    // §4.6.4.3/.4 the table itself. `appendVectorArg` writes the element COUNT
    // and then the elements, so the pairs are the slice after that count — the
    // same vector spelling §4.5.11's filter coefficients arrive in, which is
    // why this needs no reader of its own.
    var tab: ?struct { usize, usize } = null;
    // A.8.2's `noise_table_input_arg` is argument 0 of `noise_table`/
    // `noise_table_log` and nothing else — the trailing `string` of every other
    // form is §4.6.4's optional LABEL, which must not be read as a file name.
    const table_input = std.mem.eql(u8, name, "noise_table") or
        std.mem.eql(u8, name, "noise_table_log");
    for (ex.args(e), 0..) |a, ai| {
        if (a == .none) continue;
        const at = vals.items.len;
        // §4.6.4.3's FILE form of the input: "When the input is a file name,
        // the indicated file will contain the frequency / power pairs. The
        // file name argument shall be constant and will be either a string
        // literal or a string parameter." Constant means the pairs are
        // compile-time data, so they land in the SAME slot the vector form
        // fills and everything downstream — the sort, the uniqueness rule, the
        // comptime `noise_tables` export — is unchanged.
        if (table_input and ai == 0) if (lower_constfold.constEval(self, a)) |c| if (c == .str) {
            if (try lower_table_model.readNoiseTableFile(self, e, c.str)) |pairs| {
                try vals.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(pairs.len)));
                for (pairs) |x| try vals.append(self.arena, try self.mir.addFloatConst(self.arena, x));
                if (tab == null) tab = .{ at + 1, vals.items.len };
            }
            continue;
        };
        if (try appendVectorArg(self, &vals, a)) {
            // Indices, not a slice: `vals` keeps growing and may reallocate.
            if (tab == null) tab = .{ at + 1, vals.items.len };
            continue;
        }
        const tv = try lower_expr.lowerExpr(self, a);
        if (tv.ty == .string) {
            try vals.append(self.arena, tv.v);
            continue;
        }
        const rv = try self.toReal(tv);
        if (reals < 2) psd[reals] = rv;
        reals += 1;
        try vals.append(self.arena, rv);
    }
    // §4.6.4.1 `white_noise(pwr[, name])` has one real argument, so its `.f_one`
    // exponent seed is never read as a spectrum; `flicker_noise` always
    // overwrites it (E0522 above refuses the call that would not).
    try self.noise_psd.put(self.arena, @intFromEnum(e), psd);
    if (tab) |r| try self.noise_tab.put(
        self.arena,
        @intFromEnum(e),
        try self.arena.dupe(Mir.Value, vals.items[r[0]..r[1]]),
    );
    const result = try self.call(name, vals.items);
    try self.noise_val.put(self.arena, @intFromEnum(e), result);
    return .{ .v = result, .ty = .real };
}

/// §4.6.4.6 `∂contribution/∂generator`, over the MIR that is already built.
///
/// A noise function is an AMPLITUDE and a contribution combines amplitudes
/// linearly — that is what makes "perfectly correlated noise is generated by
/// using the output of one noise function for more than one noise source"
/// meaningful — so the derivative is a CONSTANT with respect to the generator
/// and is exactly the factor the branch applies to it.
///
/// Over the DAG and not over the AST: re-lowering the expression to read its
/// shape would duplicate every side effect in it, and the values this needs
/// (the other operand of each multiply) already exist as SSA names. Nothing
/// here evaluates anything; it emits a handful of arithmetic nodes that
/// reference values the contribution already computed.
///
/// Three answers, and the difference between the last two is the whole reason
/// this is not an optional:
///   absent     the generator does not occur here, so its coefficient is 0 and
///              this statement adds nothing to the branch's total;
///   nonlinear  it occurs in a shape no single factor describes (squared, in a
///              denominator, inside a call), so there IS no coefficient;
///   value      the factor.
pub const Coeff = union(enum) { absent, nonlinear, value: Mir.Value };

/// `-v`, folded when `v` is a literal. A coefficient is very often a bare
/// parameter or number, and a folded one renders inline in `noisePsd` instead
/// of taking a core live-out slot for `0.0 - 3.0`.
pub fn coeffNeg(self: *Lower, v: Mir.Value) Oom!Mir.Value {
    if (self.mir.valueDef(self.mir.resolveAlias(v)) == .float_const)
        return self.mir.addFloatConst(self.arena, -self.mir.valueDef(self.mir.resolveAlias(v)).float_const);
    return self.emit(.fneg, &.{v});
}

/// `a · b`, with the identity folded away. The derivative of `c * n` is
/// `c * 1`, and emitting that multiply would hide the constant from
/// `psdConst`.
pub fn coeffMul(self: *Lower, a: Mir.Value, b: Mir.Value) Oom!Mir.Value {
    if (a == .f_one) return b;
    if (b == .f_one) return a;
    return self.emit(.fmul, &.{ a, b });
}

pub fn noiseCoeff(self: *Lower, v: Mir.Value, n: Mir.Value) Oom!Coeff {
    return coeffAt(self, v, self.mir.resolveAlias(n), 0, null);
}

/// The phis the walk is inside, innermost first. A loop-header phi reaches
/// itself again through its back edge; meeting one already on the path is a
/// generator fed back into itself, which no single factor describes.
const PhiPath = struct { inst: Mir.Inst, up: ?*const PhiPath };

fn coeffAt(self: *Lower, v: Mir.Value, gen: Mir.Value, depth: u16, path: ?*const PhiPath) Oom!Coeff {
    if (depth == 64) return .nonlinear;
    const value = self.mir.resolveAlias(v);
    if (value == gen) return .{ .value = .f_one };
    const inst = switch (self.mir.valueDef(value)) {
        .inst_result => |i| i,
        // A constant, a parameter or a probe cannot contain the generator.
        .undef, .float_const, .int_const, .str_const, .param_ref, .block_param => return .absent,
    };
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            const d = try coeffAt(self, u.operand, gen, depth + 1, path);
            if (d == .absent) return .absent;
            if (u.op != .fneg or d == .nonlinear) return .nonlinear;
            return .{ .value = try coeffNeg(self, d.value) };
        },
        .binary => |b| {
            const da = try coeffAt(self, b.lhs, gen, depth + 1, path);
            const db = try coeffAt(self, b.rhs, gen, depth + 1, path);
            if (da == .absent and db == .absent) return .absent;
            if (da == .nonlinear or db == .nonlinear) return .nonlinear;
            switch (b.op) {
                .fadd, .fsub => {
                    // A side that does not mention the generator contributes
                    // the zero this skips rather than emits.
                    if (da == .absent) return .{
                        .value = if (b.op == .fadd) db.value else try coeffNeg(self, db.value),
                    };
                    if (db == .absent) return .{ .value = da.value };
                    return .{ .value = try self.emit(if (b.op == .fadd) .fadd else .fsub, &.{ da.value, db.value }) };
                },
                // The generator on both sides of a multiply is the generator
                // SQUARED, which is not a linear source and has no coefficient.
                .fmul => {
                    if (da != .absent and db != .absent) return .nonlinear;
                    if (da == .absent) return .{ .value = try coeffMul(self, b.lhs, db.value) };
                    return .{ .value = try coeffMul(self, da.value, b.rhs) };
                },
                // Dividing BY the generator is nonlinear for the same reason.
                .fdiv => {
                    if (db != .absent) return .nonlinear;
                    return .{ .value = try self.emit(.fdiv, &.{ da.value, b.rhs }) };
                },
                // The rest of the two-operand ops: a generator under any of them
                // is no longer an amplitude scaled by a factor (an integer op
                // would have to round it, a comparison or a min/max selects on
                // it, pow/hypot/atan2/fmod are not linear in it).
                .fmod,
                .iadd,
                .isub,
                .imul,
                .idiv,
                .imod,
                .flt,
                .fgt,
                .fle,
                .fge,
                .feq,
                .fne,
                .ilt,
                .igt,
                .ile,
                .ige,
                .ieq,
                .ine,
                .logand,
                .logor,
                .bitand,
                .bitor,
                .bitxor,
                .bitxnor,
                .shl,
                .shr,
                .pow,
                .hypot,
                .fmin,
                .fmax,
                .imin,
                .imax,
                .ipow,
                .atan2,
                => return .nonlinear,
                // `instData` decodes `.binary` only for `opClass(op) == .binary`.
                .fneg,
                .ineg,
                .lognot,
                .bitnot,
                .sqrt,
                .exp,
                .expm1,
                .ln,
                .ln1p,
                .log10,
                .floor,
                .ceil,
                .fabs,
                .iabs,
                .sin,
                .cos,
                .tan,
                .asin,
                .acos,
                .atan,
                .sinh,
                .cosh,
                .tanh,
                .asinh,
                .acosh,
                .atanh,
                .fi_cast,
                .if_cast,
                .opt_barrier,
                .path_prev,
                .path_acc,
                .select,
                .phi,
                .branch,
                .jump,
                .call,
                => unreachable,
            }
        },
        // §4.2.12 `?:` — either arm may carry the generator, and which arm runs
        // is a solve-time question, so the coefficient is the same conditional.
        .ternary => |t| {
            const dy = try coeffAt(self, t.then_val, gen, depth + 1, path);
            const dn = try coeffAt(self, t.else_val, gen, depth + 1, path);
            if (dy == .absent and dn == .absent) return .absent;
            if (dy == .nonlinear or dn == .nonlinear) return .nonlinear;
            return .{ .value = try self.emit(.select, &.{
                t.cond,
                if (dy == .absent) .f_zero else dy.value,
                if (dn == .absent) .f_zero else dn.value,
            }) };
        },
        // §5.8 `if` and §4.2.12 `?:` BOTH arrive here: `lowerTernary` builds a
        // CFG diamond and ifconv only turns it into a `.select` later. So this
        // is the same answer as `.ternary`'s, spelled per incoming edge: the
        // coefficient of a phi is the phi of the incoming coefficients.
        .phi => |p| {
            // An unsealed loop header's phi has no operands yet, so nothing is
            // known about what it carries.
            if (p.count == 0) return .nonlinear;
            var up = path;
            while (up) |f| : (up = f.up) if (f.inst == inst) return .nonlinear;
            const here: PhiPath = .{ .inst = inst, .up = path };
            const coeffs = try self.arena.alloc(Mir.PhiPair, p.count);
            var any = false;
            var same = true;
            for (coeffs, 0..) |*c, k| {
                const pair = self.mir.phiPair(inst, @intCast(k));
                const before = self.mir.blockLast(self.cur);
                const d = try coeffAt(self, pair.value, gen, depth + 1, &here);
                // What that walk EMITTED (`x/r` has coefficient `1/r`) landed in
                // `self.cur`, after the join, where the edge from `pair.block`
                // cannot carry it. Its operands are sub-terms of `pair.value`,
                // so they exist at the end of that block: compute it there.
                if (!self.mir.moveTailBefore(self.cur, before, pair.block)) return .nonlinear;
                const cv: Mir.Value = switch (d) {
                    .absent => .f_zero,
                    .nonlinear => return .nonlinear,
                    .value => |x| blk: {
                        any = true;
                        break :blk x;
                    },
                };
                c.* = .{ .block = pair.block, .value = cv };
                if (cv != coeffs[0].value) same = false;
            }
            if (!any) return .absent;
            // One value on every edge is available at the join already.
            if (same) return .{ .value = coeffs[0].value };
            return .{ .value = try self.mir.emitPhi(self.arena, blockOf(self, inst), coeffs) };
        },
        // A call's arguments are reachable, so "does the generator occur in
        // here at all" is answerable even though the derivative is not.
        .call => |c| {
            for (c.args) |arg| if (try coeffAt(self, arg, gen, depth + 1, path) != .absent) return .nonlinear;
            return .absent;
        },
        // Terminators define no value, so no Value resolves to one.
        .branch, .jump => unreachable,
    }
}

/// The block `inst` was appended to. A linear scan — the coefficient phi is
/// the one caller, and it runs once per differing-arm noise use.
fn blockOf(self: *Lower, inst: Mir.Inst) Mir.Block {
    for (0..self.mir.blockCount()) |b| {
        const blk: Mir.Block = @enumFromInt(@as(u32, @intCast(b)));
        var it = self.mir.blockInsts(blk);
        while (it.next()) |i| if (i == inst) return blk;
    }
    unreachable; // every instruction is linked into exactly one block
}
