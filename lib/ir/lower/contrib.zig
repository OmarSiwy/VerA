//! §5.6 contributions: `<+`, indirect contributions, switch branches.
//!
//! In: contribution statements. Out: `contributions` (one per access and branch; the unit
//! order proof.zig and naming.zig index by), branch rows.
//!
//! LRM clauses this file's code cites: §1.3.1, §1.3.1.2, §4.4, §4.6.3, §4.6.4.6, §5.4.1, §5.6.1.2, §5.6.1.3, §5.6.7, §5.6.7.2, §6.3.6, §7.3.2.1.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_node = @import("node.zig");
const lower_shape = @import("shape.zig");
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

/// Lowers one `<+`: resolves the branch, splits the rhs into its resistive and
/// reactive halves (§5.6.1.2) and accumulates both into the target (§5.6.1.3).
/// The reference direction (§1.3.1.2) is carried by the (hi, lo) order alone:
/// codegen stamps `+val` at hi and `-val` at lo. (LRM §5.6)
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
    // Only the three CFG loops push onto `self.loops`. §5.9.3's genvar `for` is
    // unrolled by `tryUnrollFor` before `lowerFor` runs, so a genvar loop
    // contributes once per iteration and never reaches here.
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
    // direction is the direction of its one quantity, so an `input` is supplied
    // from outside and driving it has no meaning. Only `input`: an `output` is
    // meant to be driven, and E0360 already refuses an `inout` signal-flow port.
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
    if (try checkHierParallel(self, lhs, target)) return;
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
    // §5.6.1.2 each reactive term is also a charge SITE of its own, so the
    // host can tape it apart from the others on the same row.
    for (split.sites.items) |ps| try addSite(self, idx, ps, target.neg);
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
                    // No factor describes this use. Fall back to 1 and stop
                    // accumulating, so a later statement cannot make the row
                    // claim more than it knows.
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

/// §6.3.6 the double-scaling misuse: "The first example, badres, misuses the
/// $mfactor such that the contributed current would be multiplied by $mfactor
/// twice ... The simulator will generate an error for this module." Every flow
/// contribution is already scaled by $mfactor and "Verilog-AMS does not provide
/// a method to disable" it, so an explicit factor can only scale it again.
///
/// The predicate is scaling, not presence: §6.3.6's legal `parares` reads
/// $mfactor in an `if` condition. So the test is `$mfactor` as an operand of a
/// `*` or `/` in the contributed value; dividing by it is the same misuse.
/// Potential contributions are not scaled, so only flow is checked.
///
/// ponytail: misses a flattened child whose ancestor specified `.$mfactor(...)`,
/// where elaboration (`rewriteSysCall`) has already substituted the product and
/// no `sys_call` is left. The upgrade is to run this scan in the clone, which
/// needs the discipline table elaboration does not have.
fn checkMfactorDoubleScaling(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    if (!scalesByMfactor(self, rhs)) return;
    var b = self.errWith(self.file.exprs.mainTok(lhs), .E0912);
    b.msg("this flow contribution multiplies by `$mfactor`", .{});
    b.note("§6.3.6: every flow contribution is scaled by $mfactor automatically, and \"Verilog-AMS does not provide a method to disable\" it — so an explicit factor scales it twice", .{});
    b.help("delete the `$mfactor` factor; read it in a guard if the equation needs to know the multiplicity", .{});
    try b.emit();
}

/// Whether the contributed value is a product with `$mfactor` as a factor.
///
/// The walk follows only the product spine (mul, div, sign), reading "the
/// contributed current would be multiplied by $mfactor twice" literally: a
/// `$mfactor` scaling one addend of a sum does not scale the current
/// (`mfactor.va` writes `I(p) <+ V(p) + 0.0 * $mfactor;` on purpose). The known
/// hole is `I <+ V/r * $mfactor + off`; the LRM gives no rule for the mixed case.
fn scalesByMfactor(self: *Lower, e: Ast.ExprId) bool {
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
fn isMfactorRead(self: *Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .sys_call => std.mem.eql(u8, self.file.str(ex.strOf(e)), "$mfactor"),
        .ident => if (self.hier_params.get(.mfactor)) |pi|
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
/// A zero τ is legal (reading the output into a variable is fine); the rule
/// targets the statement, so the check lives here rather than with the
/// operator's argument checks. "Directly" means the filter call is the whole
/// right-hand side: `V(x) <+ 2*zi_zp(…)` is not reached. An absent τ is the
/// simulator's default, not "specified as zero".
fn checkZeroTransitionZFilter(self: *Lower, rhs: Ast.ExprId) Oom!void {
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
/// Compile time only: the clause is about a value the source names, and annex A
/// confines `inf` to a value_range_expression, so the only way to write one is
/// IEEE arithmetic (1.0/0.0, 0.0/0.0). A value non-finite only at some operating
/// point is W0650's "not provably finite", a different claim.
///
/// Scans subexpressions, not the whole contribution: `bad + 0.0*V(p)` does not
/// fold as a unit, so the scan folds every subtree it can and reports the first
/// non-finite one.
fn checkFiniteContribution(self: *Lower, lhs: Ast.ExprId, v: Mir.Value) Oom!void {
    self.finite_scan.clearRetainingCapacity();
    var bad: ?f64 = null;
    _ = try scanFinite(self, v, &bad);
    const x = bad orelse return;
    try self.err(self.file.exprs.mainTok(lhs), .E0424, "{s}", .{
        if (std.math.isNan(x)) "contribution of a NaN" else "contribution of an infinite value",
    });
}

/// One visited value: its fold, and the first non-finite fold met in its
/// subtree, in the scan's order.
pub const FiniteScan = struct { r: ?Const, bad: ?f64 };

/// Fold `v0` where it is constant, recording the first non-finite result in
/// `bad`. Returns null for anything not constant — a probe, a parameter (the
/// host overrides it, so its declared default proves nothing), a call — but
/// keeps walking into it, because the offending constant is normally one
/// operand of a sum that is not constant. Visits each value once per
/// `self.finite_scan` clear.
///
/// Not `analysis.foldConst`: that wants a built `Analysis`, which does not
/// exist until lowering has finished, and this rule has to be reported on the
/// `<+` that broke it.
///
/// ponytail: arithmetic and sign only. `exp(1000)` overflows to +inf as well,
/// but §7.3.2.1's examples are IEEE division and every operator added here
/// widens the surface for a false accusation. Add transcendentals when a model
/// needs them.
fn scanFinite(self: *Lower, v0: Mir.Value, bad: *?f64) Oom!?Const {
    const v = self.mir.resolveAlias(v0);
    if (self.finite_scan.get(v)) |s| {
        if (bad.* == null) bad.* = s.bad;
        return s.r;
    }
    // ponytail: recursion as deep as the DAG; an explicit stack if a model
    // ever chains deep enough to exhaust it.
    var sub: ?f64 = null;
    const r: ?Const = switch (self.mir.valueDef(v)) {
        .float_const => |x| .{ .real = x },
        .int_const => |x| .{ .int = x },
        .inst_result => |inst| switch (self.mir.instData(inst)) {
            .unary => |u| blk: {
                const a = try scanFinite(self, u.operand, &sub) orelse break :blk null;
                break :blk if (accuses(u.op)) Mir.opcode.fold(u.op, &.{a}) else null;
            },
            // Both sides walked before either is tested: the scan is the
            // point, the fold is only how it gets there.
            .binary => |bn| blk: {
                const a = try scanFinite(self, bn.lhs, &sub);
                const b = try scanFinite(self, bn.rhs, &sub);
                if (!accuses(bn.op)) break :blk null;
                break :blk Mir.opcode.fold(bn.op, &.{ a orelse break :blk null, b orelse break :blk null });
            },
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => null,
        },
        .undef, .str_const, .param_ref, .block_param => null,
    };
    if (r) |c| {
        const x = c.asReal();
        if (!std.math.isFinite(x) and sub == null) sub = x;
    }
    try self.finite_scan.put(self.arena, v, .{ .r = r, .bad = sub });
    if (bad.* == null) bad.* = sub;
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

/// Lowers a §5.6.7 indirect branch contribution, `V(out) : V(in) == e;`, read
/// "drive V(out) so that V(in) == e".
///
/// Topologically a direct potential source whose current is a solver unknown.
/// Only the constitutive row differs: it is `<probe> - <equation>` with no
/// `V(hi,lo)` term, since "the source voltage needs to be adjusted so that the
/// given equation is satisfied". The orientation matters for an asymmetric
/// equation. Branches in the equation are only probed, because only the entry
/// appended here reaches codegen's stamping loop.
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
/// Runs as a sweep after the module is lowered, because a branch is a probe only
/// if nothing is ever contributed to it (§1.3.1). A source branch is exempt:
/// §5.4.2.2 makes both of its quantities accessible.
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

/// §5.6.8.1 one potential `<+` written through hierarchical net references.
pub const HierPotential = struct { hi: u16, lo: u16, unit: u32, tok: u32 };

/// Does the left-hand side reach another instance's nets by §5.6.8.1's spelling
/// — a hierarchical NET reference — rather than §5.6.8.2's `inst.branch(...)`?
fn hierNetForm(self: *const Lower, lhs: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (ex.extraOf(lhs) == Ast.branch_ref_hier_unnamed) return false;
    for ([_]Ast.ExprId{ ex.lhs(lhs), ex.rhs(lhs) }) |t| {
        if (t != .none and ex.tag(t) == .hier_ident) return true;
    }
    return false;
}

/// §5.6.8.1 "In these cases, a new unnamed branch is created in the module
/// containing the direct contribution statements. ... The simulator shall
/// check if the contribution produces a solvable set of equations, e.g. no
/// voltage source loops created."
///
/// A potential `<+` to `V(drv.x)` is therefore a second unnamed branch beside
/// any potential source `drv` has on the same pair: two potential sources in
/// parallel. `contribIndex` keys an unnamed branch on its node pair alone and
/// would sum them, so the loop is found here, before that merge, in either
/// lowering order. Conditional statements count too. Returns true when it
/// reported.
fn checkHierParallel(self: *Lower, lhs: Ast.ExprId, target: Target) Oom!bool {
    if (target.access != .potential or target.br != unnamed_branch) return false;
    const hier = hierNetForm(self, lhs);
    const clash: ?u32 = blk: {
        for (self.hier_potentials.items) |h| {
            if (h.unit != self.cur_unit and samePair(h.hi, h.lo, target.hi, target.lo)) break :blk h.tok;
        }
        if (hier) for (self.out.contributions.items) |c| {
            if (c.kind != .direct or c.access != .potential or c.br != unnamed_branch) continue;
            if (c.unit != self.cur_unit and samePair(c.hi, c.lo, target.hi, target.lo)) break :blk c.tok;
        };
        break :blk null;
    };
    if (hier) try self.hier_potentials.append(self.arena, .{ .hi = target.hi, .lo = target.lo, .unit = self.cur_unit, .tok = self.file.exprs.mainTok(lhs) });
    const other = clash orelse return false;
    var d = self.errWith(self.file.exprs.mainTok(lhs), .E0477);
    d.msg("`V({s},{s})` closes a loop of potential sources with a contribution from another module instance", .{
        lower_node.nodeName(self, target.hi), lower_node.nodeName(self, target.lo),
    });
    d.label(self.tokenSpan(other), "the other potential source on the same two nets", .{});
    d.note("a hierarchical net reference creates a new branch in the writing module (5.6.8.1), in parallel with this one", .{});
    try d.emit();
    return true;
}

/// §5.6.8.1 "The simulator shall check if the contribution produces a solvable
/// set of equations, e.g. no voltage source loops created." §5.6.8.2 repeats the
/// sentence for hierarchical contributions to a child's branches.
///
/// A loop of POTENTIAL sources fixes the sum of its branch potentials twice
/// (KVL) and leaves the branch flows around it undetermined, whatever the
/// values: the system is singular. The sweep is a union-find over the node
/// rows, one edge per potential-source row that is a source on EVERY path —
/// an unconditional direct row (`wrote_val` is the constant 1.0; a switch arm
/// is not always a potential source, §5.6.5) or an indirect row (always
/// unconditional, §5.6.7). An edge whose two ends are already joined closes a
/// loop.
///
/// Reported only when the loop's rows come from more than one module instance
/// (`Contribution.unit`), the case these clauses create and no single module's
/// author can see. A loop inside one module is not reported.
pub fn checkSourceLoops(self: *Lower) Oom!void {
    const Edge = struct { a: u32, b: u32, unit: u32 };
    const n_nodes: u32 = @intCast(self.out.nodes.len + 1); // the last row is ground
    const Ix = struct {
        n: u32,
        fn of(ix: @This(), node: u16) u32 {
            return if (node == ground) ix.n - 1 else node;
        }
    };
    const ix: Ix = .{ .n = n_nodes };
    const root = try self.arena.alloc(u32, n_nodes);
    for (root, 0..) |*r, i| r.* = @intCast(i);
    var edges: std.ArrayList(Edge) = .empty;
    for (self.out.contributions.items) |c| {
        if (c.access != .potential) continue;
        switch (c.kind) {
            .direct => if (c.wrote_val != .f_one) continue,
            .indirect => {},
        }
        const a = ix.of(c.hi);
        const b = ix.of(c.lo);
        const ra = find(root, a);
        const rb = find(root, b);
        if (ra != rb) {
            root[ra] = rb;
            try edges.append(self.arena, .{ .a = a, .b = b, .unit = c.unit });
            continue;
        }
        // Closed. The loop is this row plus the forest path from a to b; walk
        // that path (breadth-first over the accepted edges) and ask whether any
        // row on it belongs to another instance.
        const via = try self.arena.alloc(u32, n_nodes); // edge index that reached the node
        @memset(via, std.math.maxInt(u32));
        var queue: std.ArrayList(u32) = .empty;
        try queue.append(self.arena, a);
        var head: usize = 0;
        via[a] = @intCast(edges.items.len); // sentinel: the start
        while (head < queue.items.len and via[b] == std.math.maxInt(u32)) : (head += 1) {
            const at = queue.items[head];
            for (edges.items, 0..) |e, k| {
                const next = if (e.a == at) e.b else if (e.b == at) e.a else continue;
                if (via[next] != std.math.maxInt(u32)) continue;
                via[next] = @intCast(k);
                try queue.append(self.arena, next);
            }
        }
        var other: ?u32 = null;
        var at = b;
        while (at != a and via[at] < edges.items.len) {
            const e = edges.items[via[at]];
            if (e.unit != c.unit) other = e.unit;
            at = if (e.a == at) e.b else e.a;
        }
        const theirs = other orelse continue;
        var d = self.errWith(c.tok, .E0477);
        d.msg("`V({s},{s})` closes a loop of potential sources with a contribution from `{s}`", .{
            lower_node.nodeName(self, c.hi),
            lower_node.nodeName(self, c.lo),
            if (theirs < self.out.unit_paths.len and self.out.unit_paths[theirs].path.len != 0)
                self.out.unit_paths[theirs].path[0 .. self.out.unit_paths[theirs].path.len - 1] // drop the trailing separator
            else
                "the top-level module",
        });
        d.note("a loop of potential sources fixes its potentials twice and leaves its flows undetermined", .{});
        try d.emit();
        return; // one report: every further loop through this component is the same defect
    }
}

fn find(root: []u32, x: u32) u32 {
    var r = x;
    while (root[r] != r) r = root[r];
    var y = x;
    while (root[y] != r) {
        const next = root[y];
        root[y] = r;
        y = next;
    }
    return r;
}

/// Is anything contributed to this node pair — directly (§5.6.1) or indirectly
/// (§5.6.7)? That is exactly §1.3.1's test for "not a probe".
fn contributedOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.out.contributions.items) |c| {
        if (samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// §5.6.7.2 "the same pair of analog nets (or any of its parallel branches)" —
/// unordered, since (a,b) and (b,a) are the same pair with opposite reference
/// directions (§1.3.1.2).
fn samePair(a_hi: u16, a_lo: u16, b_hi: u16, b_lo: u16) bool {
    return (a_hi == b_hi and a_lo == b_lo) or (a_hi == b_lo and a_lo == b_hi);
}

fn indirectOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.out.contributions.items) |c| {
        if (c.kind == .indirect and samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// A.8.3 `indirect_expression`: a branch/port probe, or ddt/idt/idtmod of one.
/// The optional tolerance/initial-condition arguments are ordinary expressions
/// and are not restricted.
fn isIndirectProbe(self: *const Lower, e: Ast.ExprId) bool {
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
/// Canonicalising here means `flowUnknown` mints one unknown per branch,
/// `contribIndex` accumulates both spellings into one source, and codegen
/// (which rebuilds the `flow(a,b)` name from `hi`/`lo`) sees one spelling.
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
fn branchKey(self: *Lower, buf: *[lower_shape.elem_key_len]u8, e: Ast.ExprId) Oom!?[]const u8 {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident => self.file.str(ex.strOf(e)),
        // §5.5.5 "A module is allowed to access the potential and flow of a
        // branch in another module instance" (§6.7.1). Elaboration cloned the
        // child's BranchDecl under `path.name`, so the flat name is the key
        // `branches`/`port_branches` already hold. A miss falls through to
        // `nodeOf`, whose `.hier_ident` arm owns E0901. Arena rather than `buf`:
        // cold, one path per source reference.
        .hier_ident => try lower_expr.flatName(self, e),
        // Into the caller's buffer, not the arena: both consumers only call
        // `branches.get`/`port_branches.get`, which never retain a key, and this
        // runs once per §4.4.1 access.
        .index => blk: {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) break :blk null;
            const i = lower_constfold.constEval(self, ex.rhs(e)) orelse break :blk null;
            break :blk try lower_shape.elemKey(self, buf, self.file.str(ex.strOf(base)), &.{i.asInt()});
        },
        else => null, // else: names no branch; `nodeOf` reads it as a net reference and reports it
    };
}

/// The port a §3.12.1 port branch names, when the single argument of an access
/// function is one. `null` for everything else, including a two-argument
/// access — a port branch is a name, never a pair.
pub fn portBranchOf(self: *Lower, e: Ast.ExprId) Oom!?u16 {
    if (self.file.exprs.rhs(e) != .none) return null;
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = try branchKey(self, &key_buf, self.file.exprs.lhs(e)) orelse return null;
    return self.port_branches.get(key);
}

fn canonical(access: Access, hi: u16, lo: u16, br: u32) Target {
    return if (hi <= lo)
        .{ .access = access, .hi = hi, .lo = lo, .br = br }
    else
        .{ .access = access, .hi = lo, .lo = hi, .neg = true, .br = br };
}

/// Resolves `V(a)`, `V(a,b)`, `I(br)` to (access, node pair), or null after
/// reporting why it cannot (LRM §4.4.1).
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
    // §5.5.1's measure1 note: "V cannot be used as an access function because
    // there is a parameter called V declared in the module." A module-scope
    // name hides the access-function name, and a value cannot be called.
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}` is not an access function here: this module declares `{s}`, which hides it (§5.5.1)", .{ name, name });
        b.help("use the generic spelling, `{s}(...)`", .{if (access == .potential) generic_potential else generic_flow});
        try b.emit();
        return null;
    }
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+", and §3.12.1 makes a named port branch the same
    // function under another name. `lowerBranchAccess` handles the read path, so
    // everything arriving here is an lvalue or an indirect-assignment probe.
    // ponytail: `ddx(f, I(pb))` also lands here and gets this message, which
    // names the wrong position; the fix is §4.5.6 deciding whether a port flow
    // is a valid derivative unknown at all.
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
        var key_buf: [lower_shape.elem_key_len]u8 = undefined;
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
    // to the same signal." (Annex G Table G.1: `I(a,a)` was the OVI v1.0 port
    // flow, replaced by `I(<a>)`.) Only the two-argument form: `V(gnd)` stays
    // legal.
    //
    // Ground is exempt as a pair: §1.3.1.1 collapses every `ground` net onto one
    // node, so `V(g1, g2)` over two declared grounds names two signals and reads 0.
    // ponytail: that also lets the literal `V(g1, g1)` through; catching it needs
    // a name comparison the interned index has already thrown away.
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

/// §5.5.1 Syntax 5-3's generic potential access name. The generic pair is the
/// only access names not read from a §3.6.1.4 `access =` attribute.
pub const generic_potential = "potential";
/// §5.5.1 Syntax 5-3's generic flow access name.
pub const generic_flow = "flow";

/// §4.4: "The access function name shall match the discipline declaration for
/// the nets, ports, or branch given in the argument expression list."
///
/// `access_kind` is the global set of access names, so the node's discipline
/// decides. Reports one of:
///  - E0337: no discipline. §3.6.5 makes the implicit net legal as a
///    declaration; §3.6.3 and §6.5.2.1 forbid it in analog behaviour.
///  - E0501 with no suggestion: the discipline binds no nature for this half
///    (natureless, or `I` on a signal-flow `voltage`; §1.3.4).
///  - E0501 with a suggestion: the §3.6.1.4 name mismatch.
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
    // supported." So `potential`/`flow` skip only the name match; the checks
    // above still apply, since the generic spelling also reaches a nature.
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

/// Returns the contribution index for a target, creating its entry and
/// accumulator on first use. A pair that receives both a potential and a flow
/// contribution (in different arms) is the §5.6.5 switch branch: two entries,
/// one per access.
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
        if (c.access == t.access and c.hi == t.hi and c.lo == t.lo and c.br == t.br) {
            if (c.unit != self.cur_unit) {
                self.out.contributions.items[i].shared = true;
                const row: u32 = @intCast(i);
                for (self.out.contrib_sharers.items) |sh| {
                    if (sh.row == row and sh.unit == self.cur_unit) break;
                } else try self.out.contrib_sharers.append(self.arena, .{ .row = row, .unit = self.cur_unit });
            }
            return @intCast(i);
        }
    }
    return newContrib(self, .direct, t, tok);
}

/// Appends a contribution and its accumulator; the two lists stay parallel, so
/// a contribution's index is its accumulator's index.
fn newContrib(self: *Lower, kind: Kind, t: Target, tok: u32) Oom!u32 {
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
/// Zeroing the other accumulator is enough: codegen emits no row for a
/// contribution whose value folds to zero. Under a conditional the discard and
/// the cleared `wrote` flag survive as phis, which is the §5.6.5 switch branch:
/// codegen picks the row's content at run time from both flags.
fn discardOpposite(self: *Lower, t: Target) Oom!void {
    const other: Access = if (t.access == .potential) .flow else .potential;
    for (self.out.contributions.items, self.accum.items, 0..) |c, acc, ci| {
        if (c.kind != .direct or c.access != other or c.hi != t.hi or c.lo != t.lo) continue;
        // §5.6.1.3 is stated of "a branch", so only the OTHER quantity of THIS
        // branch is discarded. A parallel named branch over the same pair is a
        // different source and keeps what it retained.
        if (c.br != t.br) continue;
        // So is a parallel instance over the same pair. §5.4.1 gives branch
        // identity per module instance, and flattening collapses every
        // instance's unnamed branch onto the node pair: without this, a load
        // wired across a source would delete the source.
        if (c.unit != self.cur_unit) continue;
        try self.builder.writeVariable(acc.resist, self.cur, .f_zero);
        try self.builder.writeVariable(acc.react, self.cur, .f_zero);
        try self.builder.writeVariable(acc.wrote, self.cur, .f_zero);
        // The discarded charge goes with its sites.
        for (self.out.charge_sites.items, self.site_places.items) |s, p| {
            if (s.contrib == ci) try self.builder.writeVariable(p, self.cur, .f_zero);
        }
    }
}

/// A right-hand side split into its resistive and reactive halves (§5.6.1.2).
pub const Split = struct {
    resist: ?Mir.Value,
    react: ?Mir.Value,
    /// §5.6.1.2 the charge sites `react` sums, in term order (`ChargeSite`).
    sites: std.ArrayList(PendingSite) = .empty,
};

/// One reactive term of a right-hand side, before `lowerContribute` knows its
/// accumulator: the charge, its sign in the sum, and its `vera_lte` verdict.
pub const PendingSite = struct { charge: Mir.Value, negate: bool, lte: bool, tok: u32 };

/// Separates the ddt terms (§4.5.3) of a right-hand side into the reactive
/// part (LRM §5.6.1.2).
///
/// The split is on the additive terms: a term with no `ddt` is resistive; a term
/// with one is reactive, and its value is the term with the `ddt` stripped
/// (`C*ddt(V)` → `C*V`), the charge codegen differentiates. That is exact when
/// `ddt` appears once on a multiplicative spine (`linearDdt`). Any other term
/// (`ddt` inside a call, two `ddt`s multiplied) is resistive: each of its `ddt`s
/// is §4.5.2's new unknown with its own row and charge site (`opDdt`).
fn splitContribution(self: *Lower, rhs: Ast.ExprId) Oom!Split {
    var out: Split = .{ .resist = null, .react = null };
    try splitTerm(self, rhs, false, &out);
    return out;
}

fn splitTerm(self: *Lower, e: Ast.ExprId, negate: bool, out: *Split) Oom!void {
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

    if (linearDdt(self, e)) {
        const t = try lowerReactive(self, e) orelse return;
        const q = try finishReactive(self, t);
        try accumulate(self, &out.react, q, negate);
        const d = firstDdt(self, e);
        try out.sites.append(self.arena, .{
            .charge = q,
            .negate = negate,
            .lte = try siteLte(self, e),
            .tok = if (d != .none) self.file.exprs.mainTok(d) else Mir.no_tok,
        });
    } else {
        const v = try self.toReal(try lower_expr.lowerExpr(self, e));
        try accumulate(self, &out.resist, v, negate);
    }
}

fn accumulate(self: *Lower, slot: *?Mir.Value, v: Mir.Value, negate: bool) Oom!void {
    if (slot.*) |old| {
        slot.* = try self.emit(if (negate) .fsub else .fadd, &.{ old, v });
    } else {
        slot.* = if (negate) try self.emit(.fneg, &.{v}) else v;
    }
}

/// Record reactive term `ps` of the statement accumulating into contribution
/// `idx` as a charge site of its own (`Lower.ChargeSite`). Its SSA place is
/// seeded zero in the entry block, so a path that does not execute the site
/// — or that §5.6.1.3 discards (`discardOpposite`) — reads a zero charge.
fn addSite(self: *Lower, idx: u32, ps: PendingSite, neg: bool) Oom!void {
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_zero);
    try self.builder.writeVariable(p, self.cur, ps.charge);
    try self.site_places.append(self.arena, p);
    try self.out.charge_sites.append(self.arena, .{
        .contrib = idx,
        .sign = if (ps.negate != neg) -1.0 else 1.0,
        .lte = ps.lte,
        .tok = ps.tok,
    });
}

/// The first `ddt` call in `e`, or `.none`.
fn firstDdt(self: *const Lower, e: Ast.ExprId) Ast.ExprId {
    if (e == .none) return .none;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) return e;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| {
        const d = firstDdt(self, c);
        if (d != .none) return d;
    }
    return .none;
}

/// Does the charge site `e` join the host's truncation check? The innermost
/// `vera_lte` wins: one suffixed to a `ddt` in the term (`ddt (* vera_lte = 0
/// *) (q)`), then the nearest enclosing statement's (`lte_stack`), then the
/// default, yes. A term holding two `ddt`s under one factor is one site, and
/// the first suffixed one decides it.
fn siteLte(self: *Lower, e: Ast.ExprId) Oom!bool {
    if (lteSuffix(self, e)) |a| return lteValue(self, a);
    return stackLte(self);
}

/// `siteLte` for an operator call `e` that is its own site: its own suffix,
/// then the nearest enclosing statement's, then yes.
pub fn opSiteLte(self: *Lower, e: Ast.ExprId) Oom!bool {
    if (self.file.exprLte(e, .vera_lte)) |a| return lteValue(self, a);
    return stackLte(self);
}

fn stackLte(self: *const Lower) bool {
    return if (self.lte_stack.items.len != 0) self.lte_stack.items[self.lte_stack.items.len - 1] else true;
}

/// Writes the row of an operator unknown `s` (`lower_node.opStateNode`): a flow
/// contribution on (s, ground) with resistive half `f` and one charge site `q`,
/// stamped with sign -1 when `q_neg`. The resistive half starts as V(s) and
/// the site ASSIGNS it, so a card-conditional arm that is off leaves the row
/// `s = 0`, not an empty one that makes the system singular.
pub fn stampOpRow(self: *Lower, tok: u32, s: u16, f: Mir.Value, q: Mir.Value, q_neg: bool, lte: bool) Oom!void {
    const idx = try contribIndex(self, .{ .access = .flow, .hi = s, .lo = ground }, tok);
    const acc = self.accum.items[idx];
    try self.builder.writeVariable(acc.resist, .entry, try lower_node.probe(self, s));
    try self.builder.writeVariable(acc.wrote, .entry, .f_one);
    try self.builder.writeVariable(acc.resist, self.cur, f);
    try self.builder.writeVariable(acc.react, self.cur, if (q_neg) try self.emit(.fneg, &.{q}) else q);
    try addSite(self, idx, .{ .charge = q, .negate = q_neg, .lte = lte, .tok = tok }, false);
}

fn lteSuffix(self: *const Lower, e: Ast.ExprId) ?Ast.LteAttr {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) {
        if (self.file.exprLte(e, .vera_lte)) |a| return a;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (lteSuffix(self, c)) |a| return a;
    return null;
}

/// A `vera_lte` value: §2.9's default 1 when absent, otherwise a constant
/// expression that must fold WITHOUT the model card — the mask is a
/// compile-time table (`contract.QSites`), so a parameter cannot decide it.
/// E0523 otherwise, and the site keeps the default.
pub fn lteValue(self: *Lower, a: Ast.LteAttr) Oom!bool {
    if (a.value == .none) return true;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0523, "", .{});
        return true;
    };
    return c.isTrue();
}

/// Does this subtree contain a `ddt` (§4.5.3)? Every child edge is searched
/// (`ExprStore.children`), assignment-pattern elements included.
fn containsDdt(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (containsDdt(self, c)) return true;
    return false;
}

/// Is `e` a ddt on the linear spine `lowerReactive` strips: one `ddt` under
/// signs, factors and divisors free of `ddt`, or a sum of such terms?
fn linearDdt(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .filter_call => self.file.strings.eql(ex.strOf(e), "ddt"),
        .unary => (ex.unOp(e) == .plus or ex.unOp(e) == .minus) and linearDdt(self, ex.lhs(e)),
        .binary => switch (ex.binOp(e)) {
            .mul => if (containsDdt(self, ex.lhs(e)))
                !containsDdt(self, ex.rhs(e)) and linearDdt(self, ex.lhs(e))
            else
                linearDdt(self, ex.rhs(e)),
            .div => !containsDdt(self, ex.rhs(e)) and linearDdt(self, ex.lhs(e)),
            .add, .sub => linearDdt(self, ex.lhs(e)) and linearDdt(self, ex.rhs(e)),
            .mod, .pow, .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => false,
        },
        else => false, // else: no other node keeps a ddt on a linear spine
    };
}

/// One reactive term with its multiplicative spine split apart: `b` is the
/// `ddt` operand, `coeff` the accumulated product of everything that rode
/// outside the ddt (null = 1), `coeff_nonconst` whether any factor depends
/// on an unknown (literals/params have zero gradient and need no site).
pub const ReactiveTerm = struct { b: Mir.Value, coeff: ?Mir.Value = null, coeff_nonconst: bool = false };

/// Whether `v` has zero gradient: a literal, `undef` or a parameter.
pub fn coeffIsConst(self: *const Lower, v: Mir.Value) bool {
    return switch (self.mir.valueKind(v)) {
        .float_const, .int_const, .undef, .param_ref => true,
        .str_const, .block_param, .inst_result => false,
    };
}

/// LRM semantics of `A*ddt(B)` is A·dB/dt, the capacitance form: the stamped
/// current carries no B·dA/dt (the plain product measured wrong on MESA Cgg).
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
///    carries dA only as (dA/dx)·ΔB, the Newton term that vanishes as dt→0.
///    Deleting the dA term instead gives a quasi-Newton whose error gain grows
///    with 1/dt and wedges the timestep.
fn finishReactive(self: *Lower, t: ReactiveTerm) Oom!Mir.Value {
    const c = t.coeff orelse return t.b; // plain ddt(B): q = B, exact
    // Constant/param coefficient: dA ≡ 0, the plain product IS the
    // capacitance form (and pq/pb with zero init would reproduce it).
    if (!t.coeff_nonconst) return try self.emit(.fmul, &.{ c, t.b });
    const pb = try self.emit(.path_prev, &.{t.b});
    const d = try self.emit(.fmul, &.{ c, try self.emit(.fsub, &.{ t.b, pb }) });
    return try self.emit(.fadd, &.{ try self.emit(.path_acc, &.{d}), d });
}

fn mulCoeff(self: *Lower, t: *ReactiveTerm, c: Mir.Value, op: Mir.Opcode) Oom!void {
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
/// Asserts `linearDdt(e)`.
fn lowerReactive(self: *Lower, e: Ast.ExprId) Oom!?ReactiveTerm {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
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
                // args[1] (abstol/nature, §4.5.3) only affects tolerance, but
                // it still has to be LEGAL, on the same grounds as the E0502
                // agreement above: this spine bypasses `lowerFilter`.
                if (args.len > 1) _ = try lower_analog_op.lowerAbstolArg(self, "ddt", args[1]) orelse return null;
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
            else => {}, // else: no other unary operator keeps a ddt on a linear spine
        },
        .binary => switch (ex.binOp(e)) {
            .mul => {
                if (containsDdt(self, ex.lhs(e))) {
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
            // return, so `linearDdt` sends that term down the resistive path.
            .add, .sub => {
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
        else => {}, // else: no other node keeps a ddt on a linear spine
    }
    unreachable; // `linearDdt` admitted only the spine above
}

/// §4.6.4.1/.2/.3 the optional `name`, read straight off the AST: the label is
/// a string literal, so the call node still carries it.
///
/// The name is the trailing string argument of a call with more than one,
/// the rule all three forms share: `white_noise(pwr, name)`,
/// `flicker_noise(pwr, exp, name)`, `noise_table(input, name)`. The arity test
/// keeps §4.6.4.3's one-argument `noise_table("file.tbl")` a filename.
fn noiseName(self: *const Lower, e: Ast.ExprId) []const u8 {
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
/// The opposite end of the call from `noiseName`: §4.6.4's label is trailing
/// and optional, §4.6.3's analysis name is leading.
fn acAnalysisName(self: *const Lower, e: Ast.ExprId) []const u8 {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len == 0 or args[0] == .none or ex.tag(args[0]) != .str_literal) return "ac";
    return self.file.str(ex.strOf(args[0]));
}

/// §4.6.4: remembers that variable `name` now carries the noise sources of
/// `value`, so a later `I(a,b) <+ n;` still exports their generators. Called
/// after `value` is lowered, by an assignment and by a declaration
/// initializer (`real n = white_noise(pwr);`) alike.
pub fn noteVarNoise(self: *Lower, name: []const u8, value: Ast.ExprId) Oom!void {
    var srcs: std.ArrayList(NoiseSrc) = .empty;
    try noiseSrcsOf(self, value, &srcs);
    if (srcs.items.len == 0) return;
    const g = try self.var_noise.getOrPut(self.arena, name);
    if (g.found_existing) {
        // Union by identity: re-lowering a loop body or a second
        // assignment through the same call is still one generator.
        for (g.value_ptr.*) |src| try addNoiseSrc(self.arena, &srcs, src);
    }
    g.value_ptr.* = srcs.items;
}

/// Appends every §4.6.4 small-signal source in `e` to `out`, in first-appearance
/// order, deduplicated by generator identity (`id`). A full walk, not the first
/// hit: one expression can declare several generators. Two textually separate
/// calls stay two generators (§4.6.4.6: "each noise function generates noise
/// which is uncorrelated"); a variable read in both arms of a ?: counts once.
/// Allocates into `self.arena`.
pub fn noiseSrcsOf(self: *const Lower, e: Ast.ExprId, out: *std.ArrayList(NoiseSrc)) error{OutOfMemory}!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .noise_call => {
            const n = self.file.strings.get(ex.strOf(e));
            // §4.6.3 ac_stim shares the small-signal grammar but is a
            // stimulus, not a noise source. It is collected on the same walk
            // and separated by `kind` in codegen, which gives it §4.6.4.6's
            // "assigned to a variable first" path too. The §4.6.4.3/.4 tables
            // are generators and carry their PSD in `NoiseSrc.table`.
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
            const psd = self.noise_psd.get(@backingInt(e)) orelse
                if (kind == .ac_stim) [2]Mir.Value{ .f_one, .f_zero } // §4.6.3 mag 1, phase 0
                else [2]Mir.Value{ .f_zero, .f_one };
            try addNoiseSrc(self.arena, out, .{
                .kind = kind,
                .id = @backingInt(e),
                .pwr = psd[0],
                .exp = psd[1],
                .table = self.noise_tab.get(@backingInt(e)) orelse &.{},
                .tok = ex.mainTok(e),
                .name = if (kind == .ac_stim) acAnalysisName(self, e) else noiseName(self, e),
            });
        },
        // §4.6.4.6's own spelling: the source was assigned to a variable and
        // the contribution names the variable. The shared `id` keeps two such
        // uses one generator.
        .ident => {
            const srcs = self.var_noise.get(self.file.str(ex.strOf(e))) orelse return;
            for (srcs) |s| try addNoiseSrc(self.arena, out, s);
        },
        // Both arms of a ?: count: the walk collects the set of declared
        // generators, whichever arm the solve takes.
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
