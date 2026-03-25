//! §5.6 contributions: `<+`, indirect contributions, switch branches.
//!
//! In: contribution statements. Out: `contributions` (one per access and node pair; the unit
//! order proof.zig and naming.zig index by), branch rows.
//!
//! LRM clauses this file's code cites: §1.3.1, §1.3.1.2, §4.4, §4.6.3, §4.6.4.6, §5.4.1, §5.6.1.2, §5.6.1.3, §5.6.7, §5.6.7.2, §6.3.6, §7.3.2.1.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_contrib.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_node = @import("node.zig");
const lower_param = @import("param.zig");
const Ast = @import("frontend").Ast;
const Const = Lower.Const;
const Mir = @import("../mir.zig");
const diag = @import("diag");
const Oom = Lower.Oom;
const unnamed_branch = Lower.unnamed_branch;
const ground = Lower.ground;
const Access = Lower.Access;
const Kind = Lower.Kind;
const NoiseKind = Lower.NoiseKind;
const NoiseSrc = Lower.NoiseSrc;
const Accum = Lower.Accum;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;
const call = Lower.call;
const toReal = Lower.toReal;

// ---------------------------------------------------------------------------
// Class 4 — contributions (LRM §5.6)
// ---------------------------------------------------------------------------

/// LRM §5.6. Resolve the branch, split the rhs into its resistive and reactive
/// halves (§5.6.1.2) and ACCUMULATE both into the target's places (§5.6.1.3).
///
/// Reference direction (§1.3.1.2) is carried by the (hi, lo) order alone —
/// codegen stamps `+val` at hi and `-val` at lo.
pub fn lowerContribute(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(lhs), .E0405, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Contribution statements cannot be used inside an event control
    // block because it can generate discontinuity in analog signals"; A.6.4
    // `analog_event_statement` states it structurally.
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(lhs), .E0406, "", .{});
        return;
    }
    // §5.9, the third blanket restriction on `repeat`/`while`/non-genvar `for`:
    // "Contribution statements are not allowed". The set of branches a device
    // stamps is fixed before the solve, and a runtime trip count is not.
    //
    // `self.loops` is exactly the right question: only the three CFG loops push
    // onto it, and §5.9.3's genvar `for` is unrolled by `tryUnrollFor` before
    // `lowerFor` ever gets there — so an `analog for (i = 0; i < 4; ...)` over a
    // genvar contributes four times and never reaches here.
    if (self.loops.items.len != 0) {
        try self.err(self.file.exprs.mainTok(lhs), .E0426, "", .{});
        return;
    }
    const ex = &self.file.exprs;
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+." (§4.4 says the same of branch assignment.)
    if (ex.tag(lhs) == .port_access) {
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0407);
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        _ = try lower_expr.lowerExpr(self, rhs);
        return;
    }
    if (ex.tag(lhs) != .branch_access) {
        try self.err(self.file.exprs.mainTok(lhs), .E0408, "", .{});
        _ = try lower_expr.lowerExpr(self, rhs);
        return;
    }
    try checkZeroTransitionZFilter(self, rhs);
    const target = try branchOf(self, lhs) orelse return;
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot be
    // contributed to using the branch contribution operator <+."
    if (indirectOn(self, target.hi, target.lo)) {
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0409);
        b.msg("`{s}({s},{s})`", .{
            if (target.access == .potential) "V" else "I",
            lower_node.nodeName(self, target.hi),
            lower_node.nodeName(self, target.lo),
        });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }
    // §1.3.4.1 "In that case, potential contributions may not be made to
    // `input` ports"; §1.3.4.2 says the same of flow contributions. The port's
    // direction IS the direction of its one quantity, so an `input` is supplied
    // from outside and driving it has no meaning. Only `input` — contributing
    // to an `output` is the whole point of a signal-flow port, and an `inout`
    // signal-flow port never gets this far: E0360 refuses the declaration.
    for ([_]u16{ target.hi, target.lo }) |n| {
        if (n >= self.out.nodes.len or self.out.nodes.items(.dir)[n] != .input) continue;
        if (!lower_node.isSignalFlow(self, self.out.nodes.items(.disc)[n])) continue;
        try self.err(self.file.exprs.mainTok(lhs), .E0425, "`{s}` is an `input` port of discipline `{s}`", .{ self.out.nodes.items(.name)[n], self.out.nodes.items(.disc)[n] });
        return;
    }
    // §5.6.8.2: a hierarchical contribution is not allowed when it "changes
    // the branch into a switch branch". A named branch belongs to one instance
    // (§5.4.1), so the other access function on it from a DIFFERENT unit is
    // exactly that, whichever of the two blocks lowers first. Inside one unit
    // it is §5.6.1.3's value retention and stays legal (`discardOpposite`).
    if (target.br != unnamed_branch) for (self.out.contributions.items) |c| {
        if (c.kind != .direct or c.br != target.br or c.access == target.access or c.unit == self.cur_unit) continue;
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0439);
        b.label(self.tokenSpan(c.tok), "the other module instance contributes the {s} here", .{if (c.access == .potential) "potential" else "flow"});
        try b.emit();
        return;
    };
    if (target.access == .flow) try checkMfactorDoubleScaling(self, lhs, rhs);
    const idx = try contribIndex(self, target, self.file.exprs.mainTok(lhs));

    // §5.6.6: while THIS statement's right-hand side lowers, a read of its own
    // target is the implicit form — see `contrib_target`.
    self.contrib_target = target;
    defer self.contrib_target = null;
    const split = try splitContribution(self, rhs);
    if (split.resist) |v| try checkFiniteContribution(self, lhs, v); // §7.3.2.1
    if (split.react) |v| try checkFiniteContribution(self, lhs, v);
    const acc = self.accum.items[idx];
    // §5.6.1.3 value retention, the half that is a REPLACEMENT and not a sum.
    // Before this statement's own value is added, anything retained for the
    // OTHER quantity of the same branch is thrown away.
    try discardOpposite(self, target);
    // §1.3.1.2: `I(n,p) <+ e` drives the same branch as `I(p,n) <+ -e`, so the
    // reversed spelling accumulates into the same source with the sign flipped.
    // Checked AFTER §7.3.2.1, which is about the value the source names and
    // does not care which way the branch was written.
    if (split.resist) |v0| {
        const v = if (target.neg) try self.emit(.fneg, &.{v0}) else v0;
        const old = try self.builder.readVariable(acc.resist, self.cur);
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, v }));
    }
    if (split.react) |v0| {
        const v = if (target.neg) try self.emit(.fneg, &.{v0}) else v0;
        const old = try self.builder.readVariable(acc.react, self.cur);
        try self.builder.writeVariable(acc.react, self.cur, try self.emit(.fadd, &.{ old, v }));
    }
    // §5.6.1.3 this statement RETAINS a value for its quantity on every path
    // that executes it — even `<+ 0.0`, whose retained zero is §5.6.5's closed
    // switch and not an absent source. A constant write: no MIR instruction,
    // and on a straight line no phi either.
    try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    // §4.6.4 the noise generators belong to the target, not to one statement,
    // and they ACCUMULATE: two `<+` lines on one branch declare two sources —
    // unless they reach the SAME source through a variable (§4.6.4.6), which
    // the identity dedup in `addNoiseSrc` keeps as one generator.
    {
        var srcs: std.ArrayList(NoiseSrc) = .empty;
        try srcs.appendSlice(self.arena, self.out.contributions.items[idx].noise_srcs);
        try noiseSrcsOf(self, rhs, &srcs);
        // §4.6.4.6 the per-use coefficient. It ADDS across statements, because
        // two `<+` lines on one branch sum into one source: `V(a,b) <+ c1*n`
        // followed by `V(a,b) <+ c2*n` drives the branch with (c1+c2)·n, and
        // `addNoiseSrc` has already collapsed them onto one row.
        //
        // Read off `split.resist`: a noise function is an amplitude, not a
        // reactive quantity, so the generator only ever appears in the
        // resistive half. The §1.3.1.2 sign flip is applied for the same
        // reason it is applied above — `I(n,p) <+ c*n` drives the branch
        // with −c, and the sign is what separates correlation from
        // anti-correlation.
        if (split.resist) |v0| {
            for (srcs.items) |*s| {
                if (s.nonlinear) continue;
                const g = self.noise_val.get(s.id) orelse continue;
                switch (try lower_analog_op.noiseCoeff(self, v0, g)) {
                    .absent => {},
                    // No factor describes this use. Fall back to 1, which is
                    // what the export carried before coefficients existed, and
                    // stop accumulating so a later statement cannot make the
                    // row claim more than it knows.
                    .nonlinear => {
                        s.nonlinear = true;
                        s.coeff = .f_one;
                    },
                    .value => |d| {
                        const signed = if (target.neg) try lower_analog_op.coeffNeg(self, d) else d;
                        s.coeff = if (s.coeff == .f_zero) signed else try self.emit(.fadd, &.{ s.coeff, signed });
                    },
                }
            }
        }
        self.out.contributions.items[idx].noise_srcs = srcs.items;
    }
}

/// §6.3.6 the double-scaling misuse, which the clause states about a specific
/// printed module and calls an ERROR there:
///
///   "The first example, badres, misuses the $mfactor such that the contributed
///   current would be multiplied by $mfactor twice, once by the explicit
///   multiplication and once by the automatic scaling rule. The simulator will
///   generate an error for this module."
///
/// The automatic rule is the clause's first bullet — "all contributions to a
/// branch flow quantity in the analog block shall be multiplied by $mfactor" —
/// and the clause adds that "Verilog-AMS does not provide a method to disable"
/// it. So an explicit factor of $mfactor in a FLOW contribution cannot be an
/// opt-out; it can only be the second multiplication.
///
/// THE PREDICATE IS SCALING, NOT PRESENCE, and that is what keeps §6.3.6's own
/// legal companion legal: `parares` reads $mfactor in the CONDITION of an `if`
/// (`r/$mfactor < 1e-3`) and the clause says outright that "no error will be
/// generated for this module". So the test is `$mfactor` as an operand of a `*`
/// or a `/` inside the contributed value — division included, since dividing the
/// contribution by $mfactor is the same misuse read as an attempt to cancel the
/// automatic rule out.
///
/// Flow only: §6.3.6's automatic scaling is stated for flow contributions, so a
/// potential contribution has nothing for an explicit factor to double.
///
/// ponytail: the ceiling is a FLATTENED child, where elaboration has already
/// substituted `$mfactor` for the running product (elaborate.zig
/// `rewriteSysCall`) and there is no `sys_call` left to find. It only bites when
/// some ancestor actually specified a `.$mfactor(...)` — with none specified the
/// read is left as-is and this check sees it. The upgrade is to run this scan in
/// the clone, which needs the discipline table elaboration does not have.
pub fn checkMfactorDoubleScaling(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    if (!scalesByMfactor(self, rhs)) return;
    var b = self.errWith(self.file.exprs.mainTok(lhs), .E0912);
    b.msg("this flow contribution multiplies by `$mfactor`", .{});
    b.note("§6.3.6: every flow contribution is scaled by $mfactor automatically, and \"Verilog-AMS does not provide a method to disable\" it — so an explicit factor scales it twice", .{});
    b.help("delete the `$mfactor` factor; read it in a guard if the equation needs to know the multiplicity", .{});
    try b.emit();
}

/// Is the CONTRIBUTED VALUE a product in which `$mfactor` is a factor?
///
/// The walk follows the product SPINE of the right-hand side — mul, div and the
/// sign operators — and no further. That is the clause's own sentence read
/// literally: "the contributed current would be multiplied by $mfactor twice".
/// A `$mfactor` that multiplies one addend of a sum does not multiply the
/// contributed current; `mfactor.va` writes `I(p) <+ V(p) + 0.0 * $mfactor;` on
/// purpose, to read the parameter from the residual path, and that contribution
/// is `V(p)` — scaling it once is all that happens to it.
///
/// The precedent for stopping at the spine is `checkZeroTransitionZFilter` above:
/// where the LRM states a rule about the value assigned to a branch, a scan of
/// the whole subtree invents a rule about expressions the clause declines to
/// state. The known hole is `I <+ V/r * $mfactor + off`, which is a misuse this
/// does not catch; the LRM gives no rule for the mixed case and `badres` is not
/// it.
pub fn scalesByMfactor(self: *Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .mul, .div => isMfactorRead(self, ex.lhs(e)) or isMfactorRead(self, ex.rhs(e)) or
                scalesByMfactor(self, ex.lhs(e)) or scalesByMfactor(self, ex.rhs(e)),
            else => false, // else: only `*` and `/` scale; the doc above says why the spine stops there
        },
        .unary => switch (ex.unOp(e)) {
            .plus, .minus => scalesByMfactor(self, ex.lhs(e)),
            else => false, // else: only a sign keeps the spine
        },
        else => false, // else: not on the multiplicative spine
    };
}

/// A read of §9.18's `$mfactor`, under either of its two spellings: the system
/// function itself, or the §3.4.7 `aliasparam m = $mfactor;` name for it — the
/// alias is a second name for one location, so it is the same read.
pub fn isMfactorRead(self: *Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .sys_call => std.mem.eql(u8, self.file.str(ex.strOf(e)), "$mfactor"),
        .ident => if (self.mfactor_param) |pi|
            self.param_index.get(self.file.str(ex.strOf(e))) == pi
        else
            false,
        else => false, // else: neither of `$mfactor`'s two spellings
    };
}

/// §4.5.12, the two sentences that are one rule: "If the transition time is
/// specified as zero (0), then the output is abruptly discontinuous. A Z-filter
/// with zero (0) transition time shall not be directly assigned to a branch."
///
/// A zero τ is LEGAL — the same clause makes τ optional and "nonnegative", and
/// reading the discontinuous output into a variable is fine. What is banned is
/// putting the discontinuity straight into the equation system, where a branch
/// quantity that steps instantaneously has no derivative for Newton-Raphson.
/// So the target of the rule is the STATEMENT, which is why the check lives
/// here and not beside the operator's other argument checks.
///
/// DIRECTLY: the filter call has to BE the right-hand side. `V(x) <+ 2*zi_zp(…)`
/// is arithmetic over the filter's output and the clause does not reach it —
/// the LRM says "directly assigned", and a scan of the whole subtree would
/// invent a rule about expressions the clause declines to state.
///
/// An absent τ is not a zero one: it means the sampler's own default, which is
/// the simulator's business (§4.5.12 leaves it unstated) and is not the
/// "specified as zero" the sentence conditions on.
pub fn checkZeroTransitionZFilter(self: *Lower, rhs: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    if (ex.tag(rhs) != .filter_call) return;
    if (!std.mem.startsWith(u8, self.file.str(ex.strOf(rhs)), "zi_")) return;
    // zi_*(expr, numerator, denominator, T [, τ [, t0]]) — A.8.2.
    const args = ex.args(rhs);
    if (args.len < 5 or args[4] == .none) return;
    const tau = lower_constfold.constEval(self, args[4]) orelse return;
    if (tau.asReal() != 0.0) return;
    var b = self.errWith(self.file.exprs.mainTok(rhs), .E0518);
    b.msg("a Z-filter with zero (0) transition time shall not be directly assigned to a branch", .{});
    b.help("read it into a variable first, then contribute the variable", .{});
    try b.emit();
}

/// §7.3.2.1: "While use of these special numbers in digital expressions is not
/// an error, it is illegal to assign these values to a branch through
/// contribution in the analog context."
///
/// Compile time only, and that boundary is the clause's own scope rather than a
/// limitation to apologise for: §7.3.2.1 is about a value the SOURCE names, and
/// with `inf` confined by annex A to a value_range_expression the only way to
/// write one is the IEEE arithmetic the clause itself describes — 1.0/0.0,
/// -1.0/0.0, 0.0/0.0. A value that goes infinite only at some operating point
/// is W0650's business, and W0650 is a different claim: "not provably finite",
/// not "provably not finite".
///
/// SUBEXPRESSIONS, not the whole contribution. A branch value almost always
/// contains a probe, so `bad + 0.0*V(p)` folds to nothing as a unit; the scan
/// folds every subtree it can and accuses the first one that is not finite.
pub fn checkFiniteContribution(self: *Lower, lhs: Ast.ExprId, v: Mir.Value) Oom!void {
    var bad: ?f64 = null;
    _ = scanFinite(self, v, 0, &bad);
    const x = bad orelse return;
    try self.err(self.file.exprs.mainTok(lhs), .E0424, "{s}", .{
        if (std.math.isNan(x)) "contribution of a NaN" else "contribution of an infinite value",
    });
}

/// Fold `v0` where it is constant, recording the first non-finite result in
/// `bad`. Returns null for anything not constant — a probe, a parameter (the
/// host overrides it, so its declared default proves nothing), a call — but
/// keeps walking into it, because the offending constant is normally one
/// operand of a sum that is not constant.
///
/// Not `analysis.foldConst`: that wants a built `Analysis`, which does not
/// exist until lowering has finished, and this rule has to be reported on the
/// `<+` that broke it.
///
/// ponytail: arithmetic and sign only. `exp(1000)` overflows to +inf as well,
/// but §7.3.2.1's examples are IEEE division and every operator added here
/// widens the surface for a false accusation. Add the transcendentals the day a
/// model writes one.
pub fn scanFinite(self: *const Lower, v0: Mir.Value, depth: u32, bad: *?f64) ?Const {
    if (depth > 32) return null;
    const v = self.mir.resolveAlias(v0);
    const r: ?Const = switch (self.mir.valueDef(v)) {
        .float_const => |x| .{ .real = x },
        .int_const => |x| .{ .int = x },
        .inst_result => |inst| switch (self.mir.instData(inst)) {
            .unary => |u| blk: {
                const a = scanFinite(self, u.operand, depth + 1, bad) orelse break :blk null;
                break :blk if (accuses(u.op)) Mir.opcode.fold(u.op, &.{a}) else null;
            },
            // Both sides walked before either is tested: the scan is the
            // point, the fold is only how it gets there.
            .binary => |bn| blk: {
                const a = scanFinite(self, bn.lhs, depth + 1, bad);
                const b = scanFinite(self, bn.rhs, depth + 1, bad);
                if (!accuses(bn.op)) break :blk null;
                break :blk Mir.opcode.fold(bn.op, &.{ a orelse break :blk null, b orelse break :blk null });
            },
            .ternary, .phi, .branch, .jump, .call => null,
        },
        .undef, .str_const, .param_ref, .block_param => null,
    };
    if (r) |c| {
        const x = c.asReal();
        if (!std.math.isFinite(x) and bad.* == null) bad.* = x;
    }
    return r;
}

/// The opcodes `scanFinite` folds: IEEE arithmetic and sign, the ponytail
/// above. The operation itself is the shared kernel's (`opcode.fold`).
fn accuses(op: Mir.Opcode) bool {
    return switch (op) {
        .fneg, .ineg, .fabs, .iabs, .if_cast, .opt_barrier, .fadd, .fsub, .fmul, .fdiv => true,
        else => false, // else: §7.3.2.1's examples are IEEE division; every other operator widens the surface for a false accusation
    };
}

/// LRM §5.6.7 indirect branch contribution — `V(out) : V(in) == e;`, read
/// "drive V(out) so that V(in) == e".
///
/// Topologically identical to a direct potential contribution: `out` is driven
/// by a source whose current is a solver unknown, and codegen stamps that
/// current at hi/lo. Only the constitutive row differs — it is
///
///     <probe> − <equation>
///
/// with NO `V(hi,lo)` term, because "the source voltage needs to be adjusted so
/// that the given equation is satisfied": the branch voltage is the free
/// variable, not a term of the constraint. Row ORIENTATION is probe − equation
/// (not the reverse); for a symmetric equation like the ideal opamp both signs
/// converge to the same point, but an asymmetric one does not.
///
/// "Any branches referenced in the equation are only probed and not driven" —
/// that falls out for free: `lowerExpr` on `V(in)` produces a probe, and only
/// the entry appended here ever reaches codegen's stamping loop.
pub fn lowerIndirect(self: *Lower, tok: u32, lhs: Ast.ExprId, probe_e: Ast.ExprId, eqn: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(lhs), .E0410, "not allowed in {s}", .{ctx});
        return;
    }
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(lhs), .E0411, "", .{});
        return;
    }
    // §5.6.7 "Indirect branch contributions shall not be used in conditional or
    // looping statements, unless the conditional expression is a constant
    // expression." A constant condition never reaches here (see `cond_depth`).
    if (self.cond_depth != 0) {
        try self.err(tok, .E0412, "the condition is not a constant expression", .{});
        return;
    }
    const ex = &self.file.exprs;
    if (ex.tag(lhs) != .branch_access) {
        try self.err(self.file.exprs.mainTok(lhs), .E0413, "", .{});
        return;
    }
    // §5.6.7 "The left-hand side of the equality operator must either be an
    // access function, or ddt, idt or idtmod applied to an access function."
    if (!isIndirectProbe(self, probe_e)) {
        var b = self.errWith(self.file.exprs.mainTok(probe_e), .E0414);
        b.help("use an access function, or `ddt`/`idt`/`idtmod` applied to one", .{});
        try b.emit();
        return;
    }
    const target = try branchOf(self, lhs) orelse return;
    // §5.6.7.2 incompatible with a direct contribution across the same pair of
    // analog nets — checked on the accumulator ENTRY, since `<+` statements are
    // deduped across statements and across if-arms.
    for (self.out.contributions.items) |c| {
        if (c.kind != .direct) continue;
        if (!samePair(c.hi, c.lo, target.hi, target.lo)) continue;
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0415);
        b.msg("`({s},{s})`", .{ lower_node.nodeName(self, target.hi), lower_node.nodeName(self, target.lo) });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }

    const p = try self.toReal(try lower_expr.lowerExpr(self, probe_e));
    const e = try self.toReal(try lower_expr.lowerExpr(self, eqn));
    const row = try self.emit(.fsub, &.{ p, e });

    // Its own entry, never `contribIndex`: §5.6.7.1 allows several indirect
    // contributions, each of which is a separate source and equation.
    const idx = try newContrib(self, .indirect, target, self.file.exprs.mainTok(lhs));
    try self.builder.writeVariable(self.accum.items[idx].resist, self.cur, row);
}

/// §1.3.1: "The potential and flow of a probe branch may not both appear in
/// expressions in a given module." §5.4.2.1 states it as the ban — "using both
/// the potential and the flow of a probe branch is illegal" — and gives the
/// reason: it pins ONE of a probe's quantities at zero, the potential of a flow
/// probe or the flow of a potential probe, and which one is decided by which
/// the module reads. Reading both asks for two zeros at once.
///
/// A SWEEP and not a test at the read, because the classification depends on
/// contributions that may be lowered later: §1.3.1 makes a branch a probe by
/// nothing ever appearing on the left of its `<+`, which is only knowable once
/// the whole module is lowered. A source branch is exempt — §5.4.2.2 makes both
/// of its quantities accessible.
pub fn checkProbeBranches(self: *Lower) Oom!void {
    // ponytail: O(reads²) over one module's access functions. A pair map keyed
    // on the unordered node pair if a model ever makes this measurable.
    for (self.branch_reads.items, 0..) |a, i| {
        for (self.branch_reads.items[i + 1 ..]) |b| {
            if (a.access == b.access or !samePair(a.hi, a.lo, b.hi, b.lo)) continue;
            if (contributedOn(self, a.hi, a.lo)) continue;
            var d = self.errWith(b.tok, .E0423);
            d.msg("both quantities of the probe branch (`{s}`, `{s}`) are read", .{
                lower_node.nodeName(self, a.hi), lower_node.nodeName(self, a.lo),
            });
            d.note("nothing is contributed to that branch, so §1.3.1 makes it a probe; contribute to it to make it a source, or read only one quantity", .{});
            try d.emit();
            return; // one report per module: the second pair is the same defect
        }
    }
}

/// Is anything contributed to this node pair — directly (§5.6.1) or indirectly
/// (§5.6.7)? That is exactly §1.3.1's test for "not a probe".
pub fn contributedOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.out.contributions.items) |c| {
        if (samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// §5.6.7.2 "the same pair of analog nets (or any of its parallel branches)" —
/// unordered, since (a,b) and (b,a) are the same pair with opposite reference
/// directions (§1.3.1.2).
pub fn samePair(a_hi: u16, a_lo: u16, b_hi: u16, b_lo: u16) bool {
    return (a_hi == b_hi and a_lo == b_lo) or (a_hi == b_lo and a_lo == b_hi);
}

pub fn indirectOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.out.contributions.items) |c| {
        if (c.kind == .indirect and samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// A.8.3 `indirect_expression`: a branch/port probe, or ddt/idt/idtmod of one.
/// The optional tolerance/initial-condition arguments are ordinary expressions
/// and are not restricted.
pub fn isIndirectProbe(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (e == .none) return false;
    switch (ex.tag(e)) {
        .branch_access, .port_access => return true,
        .filter_call => {},
        else => return false, // else: not A.8.3 `indirect_expression`
    }
    const name = self.file.str(ex.strOf(e));
    const is_op = std.mem.eql(u8, name, "ddt") or
        std.mem.eql(u8, name, "idt") or
        std.mem.eql(u8, name, "idtmod");
    if (!is_op) return false;
    const args = ex.args(e);
    if (args.len == 0) return false;
    return switch (ex.tag(args[0])) {
        .branch_access, .port_access => true,
        else => false, // else: A.8.3 takes the operator OF a probe only
    };
}

/// A resolved access. `hi`/`lo` are in CANONICAL order (`hi < lo` as `nodes`
/// indices, which puts `ground` — `maxInt(u16)` — last, so `V(n)` is untouched);
/// `neg` says the source wrote the terminals the other way round.
///
/// §1.3.1.2 associated reference directions: "A positive flow enters a branch
/// through the port marked with the plus sign and exits the branch through the
/// port marked with the minus sign." So `a,b` and `b,a` are ONE branch named
/// twice, and its two spellings differ by a sign — for the flow and for the
/// potential alike.
///
/// Canonicalising here rather than at each use is what makes that true
/// everywhere at once: `flowUnknown` mints one unknown per branch instead of an
/// independent second one for the reversed pair, `contribIndex` accumulates
/// both spellings into one source, and codegen — which reconstructs the
/// `flow(a,b)` NAME from a contribution's `hi`/`lo` to find the slot lowering
/// already allocated — only ever sees the one spelling, so nothing downstream
/// needs to know the rule exists.
pub const Target = struct {
    access: Access,
    hi: u16,
    lo: u16,
    neg: bool = false,
    /// §5.4.1 the branch this reference names — a `BranchInfo.id` for a declared
    /// name, `unnamed_branch` for the pair's one implicit branch. Carried beside
    /// the pair rather than instead of it: the pair is what codegen stamps and
    /// what §5.6.7.2's "or any of its parallel branches" is stated over.
    br: u32 = unnamed_branch,
};

/// The key a branch reference has in `branches`: `br` for a scalar branch,
/// `br[k]` for one element of a §3.12 vector branch. `null` when the
/// expression cannot name a branch at all (a two-terminal access, a
/// non-constant index), which is not an error here — `nodeOf` reads the same
/// expression as a net reference and reports whatever is wrong with it.
pub fn branchKey(self: *Lower, buf: *[lower_param.elem_key_len]u8, e: Ast.ExprId) Oom!?[]const u8 {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident => self.file.str(ex.strOf(e)),
        // §5.5.5 "A module is allowed to access the potential and flow of a
        // branch in another module instance", and §6.7.1's first bullet says it
        // of the name: "Potential and flow access for named and unnamed
        // branches (including port branches) can be done hierarchically." The
        // resolution is `nodeOf`'s exactly: elaboration cloned the child's
        // BranchDecl under `path.name` (Ruling E), so the §6.7 path IS the key
        // `branches`/`port_branches` already hold, and `flatName` is the whole
        // join. A miss is not an error HERE — the caller falls through to
        // `nodeOf`, whose `.hier_ident` arm owns E0901 and, like this path,
        // mints nothing on failure (a wrong path names no branch anywhere).
        // Arena rather than `buf`: cold, one path per source reference.
        .hier_ident => try lower_expr.flatName(self, e),
        // Into the caller's buffer, not the arena: both consumers do nothing
        // with the result but `branches.get`/`port_branches.get`, which never
        // retain a key — and this runs once per §4.4.1 ACCESS, so `br[0]` in an
        // unrolled loop body was minting a fresh string per iteration. `elemKey`.
        .index => blk: {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) break :blk null;
            const i = lower_constfold.constEval(self, ex.rhs(e)) orelse break :blk null;
            break :blk try lower_param.elemKey(self, buf, self.file.str(ex.strOf(base)), &.{i.asInt()});
        },
        else => null, // else: names no branch; `nodeOf` reads it as a net reference and reports it
    };
}

/// The port a §3.12.1 port branch names, when the single argument of an access
/// function is one. `null` for everything else, including a two-argument
/// access — a port branch is a name, never a pair.
pub fn portBranchOf(self: *Lower, e: Ast.ExprId) Oom!?u16 {
    if (self.file.exprs.rhs(e) != .none) return null;
    var key_buf: [lower_param.elem_key_len]u8 = undefined;
    const key = try branchKey(self, &key_buf, self.file.exprs.lhs(e)) orelse return null;
    return self.port_branches.get(key);
}

pub fn canonical(access: Access, hi: u16, lo: u16, br: u32) Target {
    return if (hi <= lo)
        .{ .access = access, .hi = hi, .lo = lo, .br = br }
    else
        .{ .access = access, .hi = lo, .lo = hi, .neg = true, .br = br };
}

/// §4.4.1 resolve `V(a)`, `V(a,b)`, `I(br)` to (access, node pair).
pub fn branchOf(self: *Lower, e: Ast.ExprId) Oom!?Target {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return null;
    };
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+", and §3.12.1 makes a named port branch the same
    // function under another name. `lowerBranchAccess` — the READ path, the one
    // place a port branch means something — has already peeled it off above, so
    // everything still arriving here is an lvalue or an indirect-assignment
    // probe. ponytail: `ddx(f, I(pb))` also lands here and gets this message,
    // which names the right clause and the wrong position; no fixture writes it,
    // and the honest fix is §4.5.6 deciding whether a port flow is a valid
    // derivative unknown at all.
    if (try portBranchOf(self, e)) |_| {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0407);
        b.msg("`{s}` is a port branch (3.12.1)", .{self.file.str(ex.strOf(ex.lhs(e)))});
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        return null;
    }
    const first = ex.lhs(e);
    // §3.12 a single argument naming a declared branch — `br`, or `br[k]` for
    // an element of a vector branch, which `declareVectorBranch` registered
    // under exactly that scalarised name. The miss falls through to `nodeOf`,
    // which owns every diagnostic about a bad index.
    if (ex.rhs(e) == .none) {
        var key_buf: [lower_param.elem_key_len]u8 = undefined;
        if (try branchKey(self, &key_buf, first)) |key| {
            if (self.branches.get(key)) |b| {
                try checkAccessMatch(self, e, name, access, b.hi);
                return canonical(access, b.hi, b.lo, b.id);
            }
        }
    }
    const hi = try lower_node.nodeOf(self, first);
    const lo = if (ex.rhs(e) == .none) ground else try lower_node.nodeOf(self, ex.rhs(e));
    try checkAccessMatch(self, e, name, access, hi);
    // §3.11's own example of the rule: "if an access function has two nets as
    // arguments, they must be compatible".
    try lower_discipline.checkNetCompat(self, ex.mainTok(e), hi, lo);
    // §4.4 Table 4-16 gives both `V(n1,n1)` and `I(n1,n1)` as `Error`, and the
    // prose under it is normative for the flow half: "If two net expressions
    // are given as arguments to a flow access function, they shall not evaluate
    // to the same signal." A branch from p to p is not a zero-potential branch;
    // it is not a branch. Annex G Table G.1 records why the spelling exists at
    // all — `I(a,a)` was the OVI v1.0 port flow, replaced by `I(<a>)`.
    //
    // Only the TWO-argument form: `V(n)` is `V(n, gnd)` by §1.3.1.1 and is not
    // written with a repeated signal, so `V(gnd)` stays legal.
    //
    // Ground is exempt as a PAIR, not as an oversight. §1.3.1.1 collapses every
    // `ground` net onto the one global reference node, so `V(g1, g2)` over two
    // separately declared grounds lands on hi == lo == ground while naming two
    // different signals — which Table 4-16 does not forbid, and which
    // ch01_intro/24 and annex_h_glossary/08 both assert reads 0.
    // ponytail: that also lets the literal `V(g1, g1)` through. Catching it
    // needs a name comparison the interned index has already thrown away, and
    // no fixture writes it.
    if (ex.rhs(e) != .none and hi == lo and hi != ground) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}({s}, {s})` names one signal twice", .{ name, lower_node.nodeName(self, hi), lower_node.nodeName(self, lo) });
        if (access == .flow)
            b.help("the flow into a port is `{s}(<{s}>)` (5.4.3)", .{ name, lower_node.nodeName(self, hi) });
        try b.emit();
        return null;
    }
    return canonical(access, hi, lo, unnamed_branch);
}

/// §5.5.1 Syntax 5-3 `nature_access_function ::= nature_attribute_identifier |
/// potential | flow`. Spelled out as constants because they are the one pair of
/// access names that is not read out of a §3.6.1.4 `access =` attribute.
pub const generic_potential = "potential";
pub const generic_flow = "flow";

/// §4.4: "The access function name shall match the discipline declaration for
/// the nets, ports, or branch given in the argument expression list."
///
/// `access_kind` alone cannot answer this — it is the global set of access
/// names, so every name that belongs to SOME discipline resolves on EVERY net,
/// and `V(n)` quietly read a net whose discipline names its potential something
/// else. The discipline of the node is what decides.
///
/// Three separate failures live here, and they are three because a net can be
/// wrong in three different ways:
///
///  - E0337, no discipline at all. §3.6.5 makes the implicit net legal AS A
///    DECLARATION, so this cannot fire where the net is created — only here, on
///    the access, which is what §3.6.3 ("such nets can not be used in analog
///    behavioral descriptions") and §6.5.2.1 ("can only be used in a structural
///    description") actually forbid.
///  - E0501 with no `want`, the discipline binds no nature for this half:
///    natureless (`ddiscrete`, `\logic`, a bare `discipline x; enddiscipline`)
///    or the wrong half of a signal-flow pair (`I` on annex D's `voltage`).
///    §1.3.4 puts it plainest — "flow for such a node is not defined".
///  - E0501 with a `want`, the §3.6.1.4 name mismatch.
///
/// The last two share a code because they are one sentence of §4.4: the name
/// does not match the discipline. They differ only in whether there is a
/// spelling to suggest, which is a note, not a rule.
pub fn checkAccessMatch(self: *Lower, e: Ast.ExprId, name: []const u8, access: Access, node: u16) Oom!void {
    if (node == ground) return;
    const dname = self.out.nodes.items(.disc)[node];
    if (dname.len == 0) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0337);
        b.msg("`{s}` has no discipline, so `{s}` names nothing on it", .{ lower_node.nodeName(self, node), name });
        b.note("§3.6.2.4 treats a net with no discipline that is referenced in behavioral code as discrete; declare one, e.g. `electrical {s};`", .{lower_node.nodeName(self, node)});
        try b.emit();
        return;
    }
    const info = self.out.disciplines.get(dname) orelse return;
    const want = switch (access) {
        .potential => info.potential_access,
        .flow => info.flow_access,
    };
    const half = if (access == .potential) "potential" else "flow";
    if (want.len == 0) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}` is not an access function of `{s}`", .{ name, lower_node.nodeName(self, node) });
        b.note("`{s}` is of discipline `{s}`, which binds no {s} nature, so `{s}` has no {s} to access", .{
            lower_node.nodeName(self, node), dname, half, lower_node.nodeName(self, node), half,
        });
        try b.emit();
        return;
    }
    if (std.mem.eql(u8, want, name)) return;
    // §4.4: "As an alternative to using the access attribute specified in the
    // discipline, the generic potential and flow access functions are also
    // supported." So `potential`/`flow` are exempt from the name match, and
    // ONLY from it — the two checks above still apply, and must: §5.5.1's
    // generic spelling reaches a nature, not a bare node, so a natureless or
    // half-bound discipline has nothing for it to read either.
    if (std.mem.eql(u8, name, generic_potential) or std.mem.eql(u8, name, generic_flow)) return;
    var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
    b.msg("`{s}` is not an access function of `{s}`", .{ name, lower_node.nodeName(self, node) });
    b.suggestHere(want);
    b.note("`{s}` is of discipline `{s}`, whose {s} nature declares `access = {s}`", .{
        lower_node.nodeName(self, node),
        dname,
        half,
        want,
    });
    try b.emit();
}

/// Find or create the accumulator pair for one contribution target. A pair
/// that receives BOTH a potential and a flow contribution (in different arms)
/// is the §5.6.5 switch branch — two entries, one per access.
pub fn contribIndex(self: *Lower, t: Target, tok: u32) Oom!u32 {
    for (self.out.contributions.items, 0..) |c, i| {
        // §5.6.7.2 an indirectly-assigned branch is never an accumulation
        // target, so its entry can never absorb a `<+` (which `lowerIndirect`
        // rejects outright anyway).
        if (c.kind != .direct) continue;
        // §5.4.1: the pair does not identify the branch, so `br` is part of the
        // key. Two named branches over one pair get one accumulator each; every
        // spelling of the pair's UNNAMED branch shares the one §5.4.1 Example 2
        // allows it.
        if (c.access == t.access and c.hi == t.hi and c.lo == t.lo and c.br == t.br) return @intCast(i);
    }
    return newContrib(self, .direct, t, tok);
}

/// Append a fresh contribution + its accumulator pair. The two tables stay
/// parallel; see the UNIT ORDERING note in proof.zig.
pub fn newContrib(self: *Lower, kind: Kind, t: Target, tok: u32) Oom!u32 {
    try lower_hier_name.refuseRuntime(self, tok, t.hi, t.lo);
    const idx: u32 = @intCast(self.out.contributions.items.len);
    try self.out.contributions.append(self.arena, .{
        .access = t.access,
        .br = t.br,
        .tok = tok,
        .hi = t.hi,
        .lo = t.lo,
        .kind = kind,
        .unit = self.cur_unit,
    });
    const acc: Accum = .{
        .resist = self.builder.newPlace(),
        .react = self.builder.newPlace(),
        .wrote = self.builder.newPlace(),
    };
    // Seeded in the entry block, which dominates everything: a contribution
    // that only happens on one arm of an `if` reads 0 on the other (§5.8) —
    // and per §5.6.1.3 retains nothing there, which is what `wrote` starts as.
    try self.builder.writeVariable(acc.resist, .entry, .f_zero);
    try self.builder.writeVariable(acc.react, .entry, .f_zero);
    try self.builder.writeVariable(acc.wrote, .entry, .f_zero);
    try self.accum.append(self.arena, acc);
    return idx;
}

/// §5.6.1.3 "Contributing a flow to a branch which already has a value retained
/// for the potential results in the potential being discarded and the branch
/// being converted to a flow source. Similarly, contributing a potential to a
/// branch which already has a flow retained results in the flow being
/// discarded." Only contributions of the SAME kind are additive, so a kind
/// mismatch replaces rather than accumulates — which is the whole difference
/// between the clause's own worked example answering 7.0 (1 discarded by the
/// flow, the flow discarded by the 3, then 3 + 4) and answering 8.0.
///
/// Zeroing the other accumulator is the whole implementation, because a zeroed
/// accumulator emits NO row: `emitResidual` skips a contribution whose folded
/// value is `.f_zero`. So an unconditional discard deletes the source from the
/// device, which is what "discarded" means, and a zero FLOW source is in any
/// case §5.4.4's open circuit — the state the branch is in when nothing is
/// retained for it.
///
/// Under a conditional the discard survives as a phi rather than a constant —
/// and so does the `wrote` flag cleared beside it, which is the whole §5.6.5
/// switch branch: codegen reads both ends' flags and selects the branch row's
/// content at run time (retained potential → potential source, retained flow →
/// flow source, neither → §5.6.1.3's open circuit).
pub fn discardOpposite(self: *Lower, t: Target) Oom!void {
    const other: Access = if (t.access == .potential) .flow else .potential;
    for (self.out.contributions.items, self.accum.items) |c, acc| {
        if (c.kind != .direct or c.access != other or c.hi != t.hi or c.lo != t.lo) continue;
        // §5.6.1.3 is stated of "a branch", so only the OTHER quantity of THIS
        // branch is discarded. A parallel named branch over the same pair is a
        // different source and keeps what it retained.
        if (c.br != t.br) continue;
        // And so is a parallel INSTANCE over the same pair. §5.4.1 gives branch
        // identity per module instance; flattening collapses every instance's
        // unnamed branch onto the node pair, so without this a load wired across
        // a source deletes the source — `resistor load(p,n)` beside
        // `vsine v1(p,n)`, which is the first circuit anyone draws.
        if (c.unit != self.cur_unit) continue;
        try self.builder.writeVariable(acc.resist, self.cur, .f_zero);
        try self.builder.writeVariable(acc.react, self.cur, .f_zero);
        try self.builder.writeVariable(acc.wrote, self.cur, .f_zero);
    }
}

pub const Split = struct { resist: ?Mir.Value, react: ?Mir.Value };

/// LRM §5.6.1.2 — separate the ddt terms (§4.5.3) into the reactive part.
///
/// The split is structural, on the ADDITIVE terms of the rhs: a term free of
/// `ddt` is resistive; a term containing one is reactive, and its reactive
/// value is the term with the `ddt` stripped (`C*ddt(V)` → `C*V`), i.e. the
/// charge/flux whose time derivative codegen's q() differentiates. That is
/// exact whenever `ddt` appears once along a multiplicative spine of the term,
/// which is what §5.6.1.2's charge formulation means. Anything else (`ddt`
/// inside a call, two `ddt`s multiplied) is a diagnostic — never silently the
/// wrong physics.
pub fn splitContribution(self: *Lower, rhs: Ast.ExprId) Oom!Split {
    var out: Split = .{ .resist = null, .react = null };
    try splitTerm(self, rhs, false, &out);
    return out;
}

pub fn splitTerm(self: *Lower, e: Ast.ExprId, negate: bool, out: *Split) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .add => {
                try splitTerm(self, ex.lhs(e), negate, out);
                try splitTerm(self, ex.rhs(e), negate, out);
                return;
            },
            .sub => {
                try splitTerm(self, ex.lhs(e), negate, out);
                try splitTerm(self, ex.rhs(e), !negate, out);
                return;
            },
            else => {}, // else: not a sum, so one term, lowered whole below
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return splitTerm(self, ex.lhs(e), negate, out),
            .minus => return splitTerm(self, ex.lhs(e), !negate, out),
            else => {}, // else: not a sign, so one term, lowered whole below
        },
        else => {}, // else: not a sum or a sign, so one term, lowered whole below
    }

    if (containsDdt(self, e)) {
        const t = try lowerReactive(self, e) orelse return;
        try accumulate(self, &out.react, try finishReactive(self, t), negate);
    } else {
        const v = try self.toReal(try lower_expr.lowerExpr(self, e));
        try accumulate(self, &out.resist, v, negate);
    }
}

pub fn accumulate(self: *Lower, slot: *?Mir.Value, v: Mir.Value, negate: bool) Oom!void {
    if (slot.*) |old| {
        slot.* = try self.emit(if (negate) .fsub else .fadd, &.{ old, v });
    } else {
        slot.* = if (negate) try self.emit(.fneg, &.{v}) else v;
    }
}

/// Does this subtree contain a `ddt` (§4.5.3)? Every child edge is searched
/// (`ExprStore.children`), assignment-pattern elements included.
pub fn containsDdt(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (containsDdt(self, c)) return true;
    return false;
}

/// One reactive term with its multiplicative spine split apart: `b` is the
/// `ddt` operand, `coeff` the accumulated product of everything that rode
/// outside the ddt (null = 1), `coeff_nonconst` whether any factor depends
/// on an unknown (literals/params have zero gradient and need no site).
pub const ReactiveTerm = struct { b: Mir.Value, coeff: ?Mir.Value = null, coeff_nonconst: bool = false };

pub fn coeffIsConst(self: *const Lower, v: Mir.Value) bool {
    return switch (self.mir.valueKind(v)) {
        .float_const, .int_const, .undef, .param_ref => true,
        .str_const, .block_param, .inst_result => false,
    };
}

/// LRM semantics of `A*ddt(B)` is A·dB/dt — the CAPACITANCE form: the
/// stamped current carries no B·dA/dt (measured with the plain-product
/// lowering: MESA Cgg inflated up to 2.17x, oscillator period 21% slow).
/// A non-constant A becomes a path-integrated charge, ngspice's own
/// construction (NIintegrate on the increment, mesaload.c:341-344):
///
///     q = pq + A·(B − pb)      pb = B at last accept, pq = Σ committed A·ΔB
///
/// The base (pb, pq) is FIXED across one Newton attempt and advances only at
/// `stateCtl(.commit)` (operating-point exit, transient accepted step), so
///  - the committed charge increment is A·ΔB: capacitance-form physics;
///  - at any committed point ΔB = 0, so the C-plane is exactly A·∂B/∂x (AC);
///  - within a step the residual is one smooth function whose AD Jacobian
///    carries dA only as (dA/dx)·ΔB — the legitimate Newton term that
///    vanishes as dt→0. The earlier per-iterate freeze latch instead solved
///    the product-form residual with the dA term deleted from the Jacobian:
///    a quasi-Newton whose error gain grows with α = 1/dt, which is exactly
///    the mesa_oscillator/hfet_inverter/mos6_inverter timestep wedge.
pub fn finishReactive(self: *Lower, t: ReactiveTerm) Oom!Mir.Value {
    const c = t.coeff orelse return t.b; // plain ddt(B): q = B, exact
    // Constant/param coefficient: dA ≡ 0, the plain product IS the
    // capacitance form (and pq/pb with zero init would reproduce it).
    if (!t.coeff_nonconst) return try self.emit(.fmul, &.{ c, t.b });
    const pb = try self.emit(.path_prev, &.{t.b});
    const d = try self.emit(.fmul, &.{ c, try self.emit(.fsub, &.{ t.b, pb }) });
    return try self.emit(.fadd, &.{ try self.emit(.path_acc, &.{d}), d });
}

pub fn mulCoeff(self: *Lower, t: *ReactiveTerm, c: Mir.Value, op: Mir.Opcode) Oom!void {
    t.coeff = if (t.coeff) |old|
        try self.emit(op, &.{ old, c })
    else if (op == .fdiv)
        try self.emit(.fdiv, &.{ try self.mir.addFloatConst(self.arena, 1.0), c })
    else
        c;
    t.coeff_nonconst = t.coeff_nonconst or !coeffIsConst(self, c);
}

/// The charge/flux of a reactive term: strip exactly one `ddt` from a
/// multiplicative spine (§5.6.1.2), collecting the spine's coefficients
/// LIVE (no gradient suppression — `finishReactive` decides the form).
pub fn lowerReactive(self: *Lower, e: Ast.ExprId) Oom!?ReactiveTerm {
    const ex = &self.file.exprs;
    spine: switch (ex.tag(e)) {
        .filter_call => {
            if (self.file.strings.eql(ex.strOf(e), "ddt")) {
                if (!try lower_analog_op.checkOperatorPlace(self, e, "ddt")) return null;
                const args = ex.args(e);
                // A.8.2 gives a filter no `analog_expression_or_null` form, so
                // an OMITTED slot (`ddt(,1.0)`) is as wrong as no argument at
                // all. `lowerFilter` already rejects it on the non-reactive
                // path; this reactive spine bypasses that call and has to
                // agree (§4.5.14).
                if (args.len == 0 or args[0] == .none) {
                    try self.err(self.file.exprs.mainTok(e), .E0502, "", .{});
                    return null;
                }
                // args[1] (abstol/nature, §4.5.3) only affects tolerance, so
                // it is not lowered — but it still has to be LEGAL, on the same
                // grounds as the E0502 agreement above: this spine bypasses
                // `lowerFilter`, where §5.5.3's ban on a non-constant attribute
                // reference is otherwise reached through `lowerExpr`.
                if (args.len > 1) _ = try lower_analog_op.lowerAbstolArg(self, args[1]);
                return .{ .b = try self.toReal(try lower_expr.lowerExpr(self, args[0])) };
            }
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return lowerReactive(self, ex.lhs(e)),
            .minus => {
                var t = try lowerReactive(self, ex.lhs(e)) orelse return null;
                // Sign rides the coefficient (constness unchanged: negation
                // adds no unknown dependence).
                t.coeff = if (t.coeff) |old| try self.emit(.fneg, &.{old}) else try self.mir.addFloatConst(self.arena, -1.0);
                return t;
            },
            else => {}, // else: no other unary operator keeps a ddt on a linear spine: E0503 below
        },
        .binary => switch (ex.binOp(e)) {
            .mul => {
                const l_has = containsDdt(self, ex.lhs(e));
                const r_has = containsDdt(self, ex.rhs(e));
                if (l_has and r_has) break :spine;
                if (l_has) {
                    var t = try lowerReactive(self, ex.lhs(e)) orelse return null;
                    try mulCoeff(self, &t, try self.toReal(try lower_expr.lowerExpr(self, ex.rhs(e))), .fmul);
                    return t;
                }
                const c = try self.toReal(try lower_expr.lowerExpr(self, ex.lhs(e)));
                var t = try lowerReactive(self, ex.rhs(e)) orelse return null;
                try mulCoeff(self, &t, c, .fmul);
                return t;
            },
            .div => {
                if (containsDdt(self, ex.rhs(e))) break :spine; // ddt in a divisor
                var t = try lowerReactive(self, ex.lhs(e)) orelse return null;
                try mulCoeff(self, &t, try self.toReal(try lower_expr.lowerExpr(self, ex.rhs(e))), .fdiv);
                return t;
            },
            // A sum of reactive terms under a factor, `c*(ddt(a) + ddt(b))`.
            // §4.5.3's ddt is a time derivative, so it is linear: the charge
            // of the sum is the sum of the charges, and the factor outside
            // scales that as it scales one. Each side is finished to its own
            // charge first, so a side with its own non-constant factor keeps
            // its capacitance form. A side WITHOUT a ddt is a resistive term
            // the factor would also have to scale, which this spine cannot
            // return — still E0503.
            .add, .sub => {
                if (!containsDdt(self, ex.lhs(e)) or !containsDdt(self, ex.rhs(e))) break :spine;
                const l = try lowerReactive(self, ex.lhs(e)) orelse return null;
                const lq = try finishReactive(self, l);
                const r = try lowerReactive(self, ex.rhs(e)) orelse return null;
                const rq = try finishReactive(self, r);
                return .{ .b = try self.emit(if (ex.binOp(e) == .add) .fadd else .fsub, &.{ lq, rq }) };
            },
            // No other operator keeps a ddt on a linear spine.
            .mod,
            .pow,
            .eq,
            .neq,
            .case_eq,
            .case_neq,
            .lt,
            .le,
            .gt,
            .ge,
            .logical_and,
            .logical_or,
            .bit_and,
            .bit_or,
            .bit_xor,
            .bit_xnor,
            .shl,
            .shr,
            .ashl,
            .ashr,
            => {},
        },
        else => {}, // else: no other node keeps a ddt on a linear spine: E0503 below
    }
    var b = self.errWith(self.file.exprs.mainTok(e), .E0503);
    b.help("assign the derivative to a variable, then use that variable in the contribution", .{});
    try b.emit();
    return null;
}

/// §4.6.4 every small-signal noise source in one expression, appended to `out`
/// in first-appearance order, deduplicated by generator identity.
///
/// A SET and a full walk, not the first hit: `I(a,b) <+ white_noise(k) +
/// flicker_noise(kf, 1.0)` declares two generators on one branch, and so do two
/// separate `<+` lines (see `NoiseSrc`). Dedup is by `id`, so a variable named
/// in both arms of a ?: still counts its generator once, while two textually
/// separate calls of the same kind stay two generators (§4.6.4.6: "each noise
/// function generates noise which is uncorrelated").
/// §4.6.4.1/.2/.3 the optional `name`, read straight off the AST rather than
/// recorded by `lowerNoise`: the label is a string LITERAL in the source, so
/// the call node still carries it here and a side map would only be a second
/// copy to keep in step.
///
/// The name is the TRAILING string argument of a call that has more than one,
/// which is the one rule all three forms share — `white_noise(pwr, name)`,
/// `flicker_noise(pwr, exp, name)`, `noise_table(input, name)`. The arity test
/// is what keeps §4.6.4.3's one-argument `noise_table("file.tbl")` a FILENAME
/// and not a label.
pub fn noiseName(self: *const Lower, e: Ast.ExprId) []const u8 {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) return "";
    const last = args[args.len - 1];
    if (last == .none or ex.tag(last) != .str_literal) return "";
    return self.file.str(ex.strOf(last));
}

/// §4.6.3 `ac_stim`'s LEADING string argument — the analysis the stimulus is
/// active in. A.8.2 puts the quotation marks inside the production
/// (`ac_stim ( [ " analysis_identifier " …`), so a literal is the only spelling
/// there is; "ac" is the clause's own default for the absent one.
///
/// The opposite end of the call from `noiseName`, and that is the whole
/// difference between the two: §4.6.4's label is trailing and optional, §4.6.3's
/// analysis name is leading and selects the analysis. Sharing one reader would
/// have read `ac_stim("ac", 2.0, 0.0)` as unnamed and `ac_stim("noise")` as a
/// noise LABEL rather than as the analysis it names.
pub fn acAnalysisName(self: *const Lower, e: Ast.ExprId) []const u8 {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len == 0 or args[0] == .none or ex.tag(args[0]) != .str_literal) return "ac";
    return self.file.str(ex.strOf(args[0]));
}

pub fn noiseSrcsOf(self: *const Lower, e: Ast.ExprId, out: *std.ArrayList(NoiseSrc)) error{OutOfMemory}!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .noise_call => {
            const n = self.file.strings.get(ex.strOf(e));
            // §4.6.3 ac_stim shares the small-signal grammar but is a STIMULUS,
            // not a noise source; listing it in `noise_gens` would invent a
            // noise generator the model never declared. It is the ONLY name in
            // this grammar that is not a generator — §4.6.4.3/.4's tables are
            // generators whose PSD happens to be a table, and they carry it in
            // `NoiseSrc.table` rather than in `pwr`/`exp`. It is collected
            // HERE, on the same walk, and separated by `kind` in codegen, which
            // is what gives the stimulus §4.6.4.6's "assigned to a variable
            // first" path without a second copy of this function.
            const kind: NoiseKind = if (std.mem.eql(u8, n, "white_noise"))
                .thermal // §4.6.4.1
            else if (std.mem.eql(u8, n, "flicker_noise"))
                .flicker // §4.6.4.2
            else if (std.mem.eql(u8, n, "noise_table"))
                .table // §4.6.4.3
            else if (std.mem.eql(u8, n, "noise_table_log"))
                .table_log // §4.6.4.4
            else if (std.mem.eql(u8, n, "ac_stim"))
                .ac_stim // §4.6.3
            else
                return;
            const psd = self.noise_psd.get(@intFromEnum(e)) orelse
                if (kind == .ac_stim) [2]Mir.Value{ .f_one, .f_zero } // §4.6.3 mag 1, phase 0
                else [2]Mir.Value{ .f_zero, .f_one };
            try addNoiseSrc(self.arena, out, .{
                .kind = kind,
                .id = @intFromEnum(e),
                .pwr = psd[0],
                .exp = psd[1],
                .table = self.noise_tab.get(@intFromEnum(e)) orelse &.{},
                .tok = ex.mainTok(e),
                .name = if (kind == .ac_stim) acAnalysisName(self, e) else noiseName(self, e),
            });
        },
        // §4.6.4.6's own spelling: the source was assigned to a variable and
        // the contribution names the variable. Without this the walk stops at
        // the identifier and the generator is never exported — and the shared
        // `id` the map carries is what keeps two such uses ONE generator.
        .ident => {
            const srcs = self.var_noise.get(self.file.str(ex.strOf(e))) orelse return;
            for (srcs) |s| try addNoiseSrc(self.arena, out, s);
        },
        // Every other tag through its children (`ExprStore.children`),
        // assignment-pattern elements included. Both arms of a ?: count: a
        // SET of declared generators is what this walk collects, and which arm
        // the solve takes does not undeclare the other one.
        else => { // else: every other tag holds generators only through its children
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try noiseSrcsOf(self, c, out);
        },
    }
}

/// Append one generator unless its identity is already in the list.
pub fn addNoiseSrc(arena: std.mem.Allocator, out: *std.ArrayList(NoiseSrc), s: NoiseSrc) error{OutOfMemory}!void {
    for (out.items) |x| if (x.id == s.id) return;
    try out.append(arena, s);
}
