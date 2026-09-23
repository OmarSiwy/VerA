//! §7.2.2 the discrete context: which statements and nets are digital.
//!
//! In: the module AST. Out: per-net and per-statement access/context marks on `Lower`,
//! and a diagnostic for every analog construct used in a discrete context.
//!
//! LRM clauses this file's code cites: §3.2.2, §4.5.15, §4.7.1, §4.7.3, §5.2.1, §7.2.2, §7.3, §7.3.1, §7.3.7, §8.5.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_context.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const Ast = @import("frontend").Ast;
const Oom = Lower.Oom;
const init = Lower.init;
const tokenSpan = Lower.tokenSpan;
const err = Lower.err;
const errWith = Lower.errWith;
const emit = Lower.emit;
const call = Lower.call;

// ---- §7.2.2 the discrete context -------------------------------------------

/// §7.2.2's two contexts, and the four rules the LRM states across them.
///
/// A `Ast.DiscreteBlock` is not lowered as CODE — an `always` block is refused
/// outright (E0205) and an `initial` block contributes only its constant results
/// (`collectInitialState`), because EXECUTING one needs an event queue and delta
/// cycles, which is a simulator and not a compiler pass. What is done here is the
/// other half: the LRM states rules ABOUT a discrete context, and while the
/// keyword was a hard syntax error not one of them could fire. All four are
/// decidable from the AST alone, which is why this is a scan and not a lowering:
///
///   §4.5.15  an analog operator "can not be used inside an initial or always
///            block"                                                  → E0422
///   §4.7.3   an analog function "shall only be called within the analog
///            context" (§7.3.7 states the mixed-signal half)           → E0430
///   §5.2.1   "digital values cannot be accessed from the analog initial
///            block"                                                   → E0431
///   §7.2.2   "It shall be an error to assign to a given variable in both
///            contexts"                                                → E0432
///
/// §7.2.2's first sentence is what makes the last two computable without a
/// digital engine: "The domain of a variable is that of the context from which
/// its value is assigned." So the set of ASSIGNMENT TARGETS in the discrete
/// blocks IS the set of digital-owned variables, and no `reg`-ness, no driver
/// state and no scheduler is needed to know it.
pub const DiscreteCtx = struct {
    /// Module-level variables assigned by a statement in an `initial` or
    /// `always` block → the token of the block that assigns it. Insertion
    /// ordered: two errors in one module must be reported in source order.
    assigned: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// This module's §4.7.1 analog function names.
    funcs: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Which block the scan is inside, for the E0422 wording (§4.5.15 names
    /// both spellings).
    where: []const u8 = "",
};

pub fn checkDiscreteContext(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    if (module.discrete.len == 0) return;

    var ctx: DiscreteCtx = .{};
    // ANALOG functions only. §4.7.3/§7.3.7's rule is that an *analog* function
    // may not be called from the discrete context; a DIGITAL function called
    // from a digital process is the ordinary case and must not be refused.
    for (module.functions) |f| {
        if (!f.is_analog) continue;
        try ctx.funcs.put(self.arena, self.file.str(f.name), {});
    }

    for (module.discrete) |blk| {
        ctx.where = if (blk.is_always) "an always block" else "an initial block";
        try scanContext(self, blk.body, true, blk.main_tok, &ctx);
    }
    // The continuous side second: §7.2.2's conflict and §5.2.1's read are both
    // "this analog statement, against what the discrete blocks own", so the
    // discrete set has to be complete first. §7.2.2 is symmetric, and reporting
    // it at the ANALOG statement is the choice the clause's own wording makes —
    // "the domain of a variable is that of the context from which its value is
    // assigned" gives the variable to whichever context is not the intruder, and
    // a module with a discrete block in it has already been told about that.
    for (module.analog) |blk| try scanContext(self, blk.body, false, blk.is_initial, &ctx);
}

/// A.6.2 `initial_construct ::= initial statement`, lowered — as far as it can
/// honestly be lowered by a compiler with no discrete kernel.
///
/// THE ONE SHAPE. A body of assignments of CONSTANT expressions to module
/// variables. §7.2.2's first sentence is what makes that shape complete rather
/// than a guess: "The domain of a variable is that of the context from which its
/// value is assigned", so the target belongs to the discrete context, and §7.2.2
/// then forbids the continuous context to assign it as well (E0432). The block
/// runs once before the analysis, nothing else ever writes the variable, and the
/// constant is therefore the value it holds for the whole analysis. §7.3.1
/// Table 7-1 is the rest of the story — how the continuous context READS it —
/// and for a `reg` the parser has already applied that table's `bit` row by
/// declaring the grouping as one integer.
///
/// So this records the expression and `lowerModule` installs it as the
/// variable's initial value, exactly where an A.2.2.1 declaration assignment
/// lands. No block is emitted, because there is no second point in time at which
/// it could run.
///
/// EVERYTHING ELSE IS E0433, and deliberately so rather than "unimplemented":
/// a delay or an event control has nothing to suspend on, a loop or a
/// conditional is only worth writing over values that change during the run, and
/// a non-constant right-hand side reads something no discrete kernel computed.
/// Each of those has several possible readings and the LRM picks between them
/// with §8.5's simulation cycle, which VerA does not have. Refusing is the
/// answer that cannot be silently wrong.
///
// ponytail: no event queue, no delta cycles, no drivers. The upgrade path is a
// discrete half in the engine, not a bigger version of this function — and if
// one ever lands, this stays as its constant-folding fast path.
pub fn collectInitialState(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.discrete) |blk| {
        // `always` is refused at the keyword (E0205, parser): it re-runs on an
        // event, so it has no constant reading to collect. Reporting its body
        // here as well would be a second diagnostic for one decision.
        if (blk.is_always) continue;
        try collectInitialStmt(self, blk.body);
    }
}

pub fn collectInitialStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .empty => {},
        // A.6.3 `seq_block` — transparent. Its own local declarations are not:
        // a name declared inside the block is not the module variable the
        // continuous context reads, so there is nothing to install.
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0)
                try self.err(self.file.stmtTok(id), .E0433, "a local declaration inside an initial block", .{});
            for (b.body) |s| try collectInitialStmt(self, s);
        },
        .assign => |a| {
            const tok = self.file.stmtTok(id);
            if (a.target == .none or ex.tag(a.target) != .ident) {
                // §3.2.2 `bus[i] = …`: the element is representable, but which
                // element is a question about a value, and the arrays this ever
                // applies to are the ones a digital kernel would drive.
                try self.err(tok, .E0433, "the assignment target is not a plain variable name", .{});
                return;
            }
            const name = self.file.str(ex.strOf(a.target));
            if (lower_constfold.constEval(self, a.value) == null) {
                var b = self.errWith(tok, .E0433);
                b.msg("`{s}` is assigned a value that is not constant", .{name});
                b.note(
                    "an initial block runs once, before the analysis, so a value it computes " ++
                        "from anything the analysis produces does not exist yet",
                    .{},
                );
                try b.emit();
                return;
            }
            // Last assignment wins — the body is sequential, so a later one
            // overwrites an earlier one, and both overwrite an A.2.2.1
            // declaration assignment (which happens at elaboration, before this
            // block runs).
            try self.initial_state.put(self.arena, name, .{ .value = a.value, .tok = tok });
        },
        else => try self.err(
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
    }
}

/// Collect discrete §7.2.2 assignment targets, then check the continuous side
/// for both-context assignments and §5.2.1 digital reads in `analog initial`.
/// The context is compile-time: each walk keeps its own early exits and visits.
/// Runs only in a module that HAS a discrete block; ordinary analog pays nothing.
///
/// ponytail: a name declared in a NAMED BLOCK inside the discrete body shadows
/// the module-level one, and this scan does not model that — the
/// `self.vars.contains` filter is what keeps the false positive out, by only
/// ever recording a name the module itself declared. A block-local `integer x`
/// shadowing a module-level `real x` would still be recorded; give
/// `Ast.SeqBlock` a scope walk here if a model ever does that.
pub fn scanContext(self: *Lower, id: Ast.StmtId, comptime discrete: bool, context: if (discrete) u32 else bool, ctx: *DiscreteCtx) Oom!void {
    if (id == .none or (!discrete and ctx.assigned.count() == 0)) return;
    const is_initial = if (discrete) {} else context;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .assign => |a| {
            // The target of `bus[3] = ...` is the array, so walk down to the
            // base name — §7.2.2's domain is a property of the DECLARATION.
            var t = a.target;
            while (t != .none and (ex.tag(t) == .index or ex.tag(t) == .range)) t = ex.lhs(t);
            if (t != .none and ex.tag(t) == .ident) {
                const name = self.file.str(ex.strOf(t));
                if (discrete) {
                    if (self.vars.contains(name)) try ctx.assigned.put(self.arena, name, context);
                } else if (ctx.assigned.get(name)) |dtok| {
                    var b = self.errWith(self.file.exprs.mainTok(t), .E0432);
                    b.msg("`{s}`", .{name});
                    b.label(
                        self.tokenSpan(dtok),
                        "`{s}` is also assigned here, in the discrete context",
                        .{name},
                    );
                    try b.emit();
                }
            }
            try scanContextExpr(self, a.value, discrete, is_initial, ctx);
        },
        .block => |b| for (b.body) |s| try scanContext(self, s, discrete, context, ctx),
        .if_stmt => |s| {
            try scanContextExpr(self, s.cond, discrete, is_initial, ctx);
            try scanContext(self, s.then_s, discrete, context, ctx);
            try scanContext(self, s.else_s, discrete, context, ctx);
        },
        .case_stmt => |s| {
            try scanContextExpr(self, s.scrutinee, discrete, is_initial, ctx);
            for (s.arms) |arm| {
                for (arm.labels) |l| try scanContextExpr(self, l, discrete, is_initial, ctx);
                try scanContext(self, arm.body, discrete, context, ctx);
            }
        },
        .for_stmt => |s| {
            try scanContext(self, s.init, discrete, context, ctx);
            try scanContextExpr(self, s.cond, discrete, is_initial, ctx);
            try scanContext(self, s.step, discrete, context, ctx);
            try scanContext(self, s.body, discrete, context, ctx);
        },
        .while_stmt => |s| {
            try scanContextExpr(self, s.cond, discrete, is_initial, ctx);
            try scanContext(self, s.body, discrete, context, ctx);
        },
        .repeat_stmt => |s| {
            try scanContextExpr(self, s.count, discrete, is_initial, ctx);
            try scanContext(self, s.body, discrete, context, ctx);
        },
        .event_control => |s| {
            try scanContextExpr(self, s.event, discrete, is_initial, ctx);
            try scanContext(self, s.body, discrete, context, ctx);
        },
        .sys_task => |s| for (s.args) |a| try scanContextExpr(self, a, discrete, is_initial, ctx),
        // §7.3, the write half: "Read operations of nets and variables in both
        // domains are allowed from both contexts. WRITE operations of nets and
        // variables are only allowed from the context of their domain." A `<+`
        // here writes a CONTINUOUS net from the discrete context, so it is
        // refused whether or not the enclosing block is executable.
        //
        // This used to read "the block has already been refused, nothing to
        // add", and that was the masking: the block's own E0205 says the
        // construct is unsupported, which is a statement about VerA, while
        // §7.3 is a statement about the SOURCE and holds in a compiler that
        // supports `always` perfectly. The two answers are not
        // interchangeable, and the clause's rule had no coverage at all while
        // the weaker one stood in for it.
        //
        // NOT E0432 (§7.2.2, "assigned in both contexts"): that rule is about
        // a variable with two writers and fires only when both exist. Here
        // there is one writer, in the wrong domain.
        .contribute => |s| if (discrete) {
            var b = self.errWith(self.file.exprs.mainTok(s.lhs), .E0435);
            b.msg("contributed from {s}", .{ctx.where});
            try b.emit();
        } else try scanContextExpr(self, s.rhs, discrete, is_initial, ctx),
        .indirect => |s| if (discrete) {
            var b = self.errWith(self.file.exprs.mainTok(s.lhs), .E0435);
            b.msg("indirectly contributed from {s}", .{ctx.where});
            try b.emit();
        } else try scanContextExpr(self, s.eqn, discrete, is_initial, ctx),
        .empty, .event_trigger, .disable, .jump => {},
    }
}

/// Every expression reachable from a context statement. The child edges are the
/// per-tag column usage documented on `Ast.ExprTag`; the `args` whitelist is the
/// set of tags whose `extra` is an ExprId list offset — the others park a literal
/// value or a StrId list there, and reading them as expressions would walk
/// garbage.
/// §5.2.1: "digital values cannot be accessed from the analog initial block as
/// they have not yet been assigned when the analog initial block is executed."
/// Only the READ is diagnosed, and only inside an `analog initial` — the same
/// read from the ordinary analog block is what §7.3.1 Table 7-1 is the
/// conversion table for.
pub fn scanContextExpr(self: *Lower, e: Ast.ExprId, comptime discrete: bool, is_initial: if (discrete) void else bool, ctx: *DiscreteCtx) Oom!void {
    if (e == .none or (!discrete and !is_initial)) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (discrete) {
        switch (tag) {
            // §4.5.15, verbatim: analog operators "can not be used inside an initial
            // or always block". Same code as the analog-function-body and
            // analog-initial cases, because it is the same sentence's family of
            // contexts: an operator carries state from one accepted timepoint to the
            // next, and none of these has a timepoint to advance.
            .filter_call => try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx.where}),
            .call => {
                const name = self.file.str(ex.strOf(e));
                if (ctx.funcs.contains(name)) {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0430);
                    b.msg("`{s}`", .{name});
                    b.note(
                        "an analog function shall only be called from an analog block " ++
                            "or from another analog function",
                        .{},
                    );
                    try b.emit();
                }
            },
            else => {},
        }
    } else if (tag == .ident) {
        const name = self.file.str(ex.strOf(e));
        if (ctx.assigned.get(name)) |dtok| {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0431);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(dtok), "`{s}` is assigned here, in the discrete context", .{name});
            try b.emit();
        }
    }
    try scanContextExpr(self, ex.lhs(e), discrete, is_initial, ctx);
    try scanContextExpr(self, ex.rhs(e), discrete, is_initial, ctx);
    if (tag == .ternary) try scanContextExpr(self, ex.ternaryElse(e), discrete, is_initial, ctx);
    switch (tag) {
        .call,
        .builtin_call,
        .sys_call,
        .filter_call,
        .noise_call,
        .event_function,
        .concat,
        .assign_pattern,
        => for (ex.args(e)) |a| try scanContextExpr(self, a, discrete, is_initial, ctx),
        else => {},
    }
}
