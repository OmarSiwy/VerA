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
const lower_param = @import("param.zig");
const lower_discipline = @import("discipline.zig");
const lower_event = @import("event.zig");
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
/// A `Ast.DiscreteBlock` is not lowered as CODE: an `initial` block of constant
/// assignments contributes its results (`collectInitialState`), and anything
/// that needs an event queue and delta cycles makes the module MIXED — its
/// digital half runs on the mixed-signal kernel beside the device, and what the
/// analog block reads of it is a host-written input (`declareDiscreteInputs`).
/// What is done here is the other half: the LRM states rules ABOUT a discrete context, and while the
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
    /// The module's discrete half runs on the mixed-signal kernel
    /// (`Lower.mixed_signal`), so what that kernel cannot do yet is E0437.
    mixed: bool = false,
};

/// §8.5: does this module's discrete half need the event queue? An `always`
/// block and a continuous assignment are PROCESSES — each re-runs whenever
/// what it reads changes — and an `initial` block that suspends (a delay, an
/// event or level control, a nonblocking or intra-assignment-timed write) is
/// one too. Anything else is `collectInitialState`'s constant shape, which
/// needs no kernel and keeps its fast path.
///
/// Takes the FILE rather than the `Lower` so elaboration can ask it of the
/// flattened module before lowering exists (`elaborate.Flatten.run`, E0920).
pub fn isMixed(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl) bool {
    if (module.assigns.len != 0) return true;
    for (module.discrete) |blk| if (blk.is_always or suspends(file, blk.body)) return true;
    return false;
}

fn suspends(file: *const Ast.SourceFile, id: Ast.StmtId) bool {
    if (id == .none) return false;
    switch (file.stmt(id)) {
        .event_control => return true,
        .assign => |a| if (a.nonblocking or a.timing != .none) return true,
        else => {}, // else: a statement suspends only through its children
    }
    const Walk = struct {
        file: *const Ast.SourceFile,
        hit: *bool,
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (suspends(w.file, s)) w.hit.* = true;
        }
    };
    var hit = false;
    file.stmtEdges(id, Walk{ .file = file, .hit = &hit }) catch unreachable;
    return hit;
}

/// §7.3.1 / §7.3.6.5 / §8.5, the analog block's view of a mixed module's
/// digital half. Every variable a discrete process writes and every net a
/// continuous assignment drives is DIGITAL-OWNED (§7.2.2: "the domain of a
/// variable is that of the context from which its value is assigned"), and
/// when the analog block reads one it reads the value of "the greatest digital
/// time tick which is less than or equal to the analog time" (§7.3.6.5) — a
/// value only the digital kernel can compute. So each becomes a HOST-WRITTEN
/// input: a hidden §3.4 parameter of the same name, i.e. a `Model` field the
/// mixed-signal host writes before every solve (and re-runs `precompute`
/// after). Table 7-1 reads a bit grouping, a net and an `integer` alike as an
/// integer, which is the parameter's type.
///
/// Called before the ports and nets are interned, so a digital-owned net never
/// becomes an analog node and a digital-owned variable never an analog one.
///
// ponytail: a Model field is per MODEL, and a discrete input is per INSTANCE.
// That is exact for the testbench (one instance) and wrong for a host that
// instantiates one mixed device twice; the right home is an `Instance` field,
// which is codegen's to emit.
pub fn declareDiscreteInputs(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    if (!isMixed(self.file, module)) return;
    self.out.mixed_signal = true;
    const ex = &self.file.exprs;
    var owned: std.ArrayList(Ast.ExprId) = .empty;
    for (module.assigns) |a| {
        const t = self.file.lvalueBase(a.target);
        const n = if (t == .none) null else netOf(module, ex.strOf(t));
        if (n == null) {
            // IEEE 1364-2005 §6.1 (via VAMS §1.1): A.6.1's `net_assignment`
            // drives a `net_lvalue` — a variable has no driver to add.
            try self.err(a.main_tok, .E0438, "", .{});
            continue;
        }
        // The declaration kind decided E0438; the DOMAIN decides this one.
        // §7.2: "only digital blocks and primitives can drive a discrete net",
        // and §7.3: "Write operations of nets ... are only allowed from the
        // context of their domain" — and a continuous assignment is the
        // discrete context. A `ddiscrete` net (§3.6.2.2 `domain discrete`) is
        // a net exactly as `wire` is, and legal here.
        if (lower_discipline.isContinuous(self.file, n.?.discipline)) {
            try self.err(a.main_tok, .E0435, "`{s}` is driven by a continuous assignment", .{self.file.str(ex.strOf(t))});
            continue;
        }
        try owned.append(self.arena, t);
    }
    for (module.discrete) |blk| try collectWrites(self, blk.body, &owned);
    // Only what the analog block READS crosses: an owned value it never names
    // is the digital engine's alone, and must not make a solve fail on an x
    // (§7.3.2) that nothing analog ever sees.
    var reads: Reads = .{ .l = self };
    for (module.analog) |blk| try reads.stmt(blk.body);
    for (owned.items) |t| {
        const name = self.file.str(ex.strOf(t));
        if (self.out.discrete_inputs.contains(name) or !reads.names.contains(name)) continue;
        const ty: Ast.Type = for (module.vars) |v| {
            if (v.name == ex.strOf(t)) break v.ty;
        } else if (netOf(module, ex.strOf(t)) != null) .integer else continue; // an undeclared name is §6.8's, reported elsewhere
        if (ty != .integer) {
            // VAMS Table 7-1's `real` row: a digital `real` is read as a real.
            // The digital engine holds four-state bits only.
            try self.err(ex.mainTok(t), .E0437, "`{s}` is a digital `real`, and the digital engine holds no real-valued variable yet", .{name});
            continue;
        }
        try self.out.discrete_inputs.put(self.arena, name, ex.mainTok(t));
        try lower_param.addParam(self, name, .integer, try self.mir.addIntConst(self.arena, 0), .{ .int = 0 }, &.{}, false, ex.mainTok(t));
    }
}

/// Marks, in `marks` (indexed by `Ast.ExprId`), every expression §7.2.2's
/// discrete context owns in a MIXED module (`isMixed`): the bodies of its
/// `initial`/`always` blocks and its continuous assignments. Those run on the
/// mixed-signal kernel, which is four-state, so an x or z literal there is
/// ordinary IEEE 1364 and not the analog backend's to refuse. A non-mixed
/// module's `initial` is not marked: `collectInitialState` folds it into the
/// analog variables' initial values, where an x has nowhere to live.
pub fn markDiscreteExprs(file: *const Ast.SourceFile, marks: []bool) void {
    const Mark = struct {
        file: *const Ast.SourceFile,
        marks: []bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            w.marks[@intFromEnum(e)] = true;
            var buf: [3]Ast.ExprId = undefined;
            for (w.file.exprs.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    const w: Mark = .{ .file = file, .marks = marks };
    for (file.modules) |*m| {
        if (!isMixed(file, m)) continue;
        for (m.discrete) |blk| w.stmt(blk.body) catch unreachable;
        for (m.assigns) |a| for ([_]Ast.ExprId{ a.target, a.value, a.delay.rise, a.delay.fall, a.delay.off }) |e|
            w.expr(e, .read) catch unreachable;
    }
}

/// Every identifier an analog statement tree reads.
const Reads = struct {
    l: *Lower,
    names: std.StringHashMapUnmanaged(void) = .empty,
    pub fn stmt(w: *Reads, s: Ast.StmtId) Oom!void {
        if (s != .none) try w.l.file.stmtEdges(s, w);
    }
    pub fn expr(w: *Reads, e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
        if (e == .none) return;
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .ident) try w.names.put(w.l.arena, w.l.file.str(ex.strOf(e)), {});
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| {
            // §4.4: a bare name in `V(d)` is the net the access function is
            // applied to, not a Table 7-1 read of its digital value. Making it
            // a discrete input would drop the node and turn a ddiscrete net's
            // E0501 ("binds no potential nature") into a false E0337 ("has no
            // discipline"). An index expression inside the argument is a read.
            if (c != .none and ex.tag(e) == .branch_access and ex.tag(c) == .ident) continue;
            try w.expr(c, .read);
        }
    }
};

/// The net `name` declares in `module`, of any discipline, or null (a
/// variable, or undeclared). Its domain is the caller's question.
fn netOf(module: *const Ast.ModuleDecl, name: Ast.StrId) ?*const Ast.NetDecl {
    for (module.nets) |*n| if (n.name == name) return n;
    return null;
}

fn collectWrites(self: *Lower, id: Ast.StmtId, out: *std.ArrayList(Ast.ExprId)) Oom!void {
    if (id == .none) return;
    const funcs: []const Ast.FuncDecl = if (self.out.module) |m| m.functions else &.{};
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    try self.file.stmtWrites(funcs, id, self.arena, &writes);
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t != .none) try out.append(self.arena, t);
    }
    const Walk = struct {
        l: *Lower,
        out: *std.ArrayList(Ast.ExprId),
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try collectWrites(w.l, s, w.out);
        }
    };
    try self.file.stmtEdges(id, Walk{ .l = self, .out = out });
}

/// Every §5.10.4 named event of `module` a statement tree triggers or waits on,
/// name → first token.
const EventRefs = struct {
    l: *Lower,
    module: *const Ast.ModuleDecl,
    names: std.StringArrayHashMapUnmanaged(u32) = .empty,
    fn isEvent(w: *const EventRefs, s: Ast.StrId) bool {
        for (w.module.events) |ev| if (ev == s) return true;
        return false;
    }
    pub fn stmt(w: *EventRefs, s: Ast.StmtId) Oom!void {
        if (s == .none) return;
        switch (w.l.file.stmt(s)) {
            .event_trigger => |t| if (w.isEvent(t.name)) try w.names.put(w.l.arena, w.l.file.str(t.name), w.l.file.stmtTok(s)),
            else => {}, // else: only a trigger names an event outside an expression
        }
        try w.l.file.stmtEdges(s, w);
    }
    pub fn expr(w: *EventRefs, e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
        if (e == .none) return;
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .ident and w.isEvent(ex.strOf(e))) try w.names.put(w.l.arena, w.l.file.str(ex.strOf(e)), ex.mainTok(e));
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| try w.expr(c, .read);
    }
};

pub fn checkDiscreteContext(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    if (module.discrete.len == 0) return;
    // §7.3.6.1/§7.3.6.2: a named event triggered in one context and waited on
    // in the other crosses the A/D boundary — an A2D or an explicit D2A event,
    // neither of which the mixed-signal kernel carries yet. Refused rather than
    // lowered as two unrelated events that never meet.
    if (self.out.mixed_signal and module.events.len != 0) {
        var dig: EventRefs = .{ .l = self, .module = module };
        for (module.discrete) |blk| try dig.stmt(blk.body);
        var ana: EventRefs = .{ .l = self, .module = module };
        for (module.analog) |blk| try ana.stmt(blk.body);
        for (ana.names.keys(), ana.names.values()) |name, tok| if (dig.names.contains(name))
            try self.err(tok, .E0437, "named event `{s}` is used in both contexts, and the kernel carries no event across the A/D boundary yet (§7.3.6.1, §7.3.6.2)", .{name});
    }

    var ctx: DiscreteCtx = .{ .mixed = self.out.mixed_signal };
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
    // A mixed module's `initial` blocks run on the kernel, with the rest of
    // its digital half: their writes are discrete inputs, not constants.
    if (self.out.mixed_signal) return;
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
        // An analog-only task is §9.2's E0821 (`scanContext`), which names the
        // rule; E0433 on top would blame the initial-block model instead.
        .sys_task => |s| if (!lower_event.isAnalogOnlySysFunc(self.file.str(s.name))) try self.err(
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
        else => try self.err( // else: E0433 names every other statement; a new one is refused, not dropped
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
    // Every variable the statement writes, not only an assignment target: an
    // output actual and a `$random` seed assign too (`stmtWrites`). The target
    // of `bus[3] = ...` is the array, so `lvalueBase` walks down to the name —
    // §7.2.2's domain is a property of the DECLARATION.
    const funcs: []const Ast.FuncDecl = if (self.out.module) |m| m.functions else &.{};
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    defer writes.deinit(self.arena);
    try self.file.stmtWrites(funcs, id, self.arena, &writes);
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t == .none) continue;
        const name = self.file.str(ex.strOf(t));
        if (discrete) {
            if (self.vars.contains(name) or self.out.discrete_inputs.contains(name)) try ctx.assigned.put(self.arena, name, context);
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
    // Every edge but the four arms below, which read less than all of them.
    const Walk = struct {
        l: *Lower,
        context: if (discrete) u32 else bool,
        ctx: *DiscreteCtx,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            try scanContextExpr(w.l, e, discrete, if (discrete) {} else w.context, w.ctx);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try scanContext(w.l, s, discrete, w.context, w.ctx);
        }
    };
    // §9.2's digital column: a task whose "Supported in digital context" cell
    // is No (§9.7: "$fatal, $error, $warning" are "in the analog context
    // only"). Named by the table's own words, not by what VerA can execute.
    if (discrete) if (self.file.stmt(id) == .sys_task) {
        const n = self.file.str(self.file.stmt(id).sys_task.name);
        if (lower_event.isAnalogOnlySysFunc(n)) try self.err(self.file.stmtTok(id), .E0821, "`{s}` in {s}", .{ n, ctx.where });
    };
    switch (self.file.stmt(id)) {
        // The target is a write, collected above; only the value is read.
        .assign => |a| try scanContextExpr(self, a.value, discrete, is_initial, ctx),
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
            try self.err(self.file.exprs.mainTok(s.lhs), .E0435, "contributed from {s}", .{ctx.where});
        } else try scanContextExpr(self, s.rhs, discrete, is_initial, ctx),
        .indirect => |s| if (discrete) {
            try self.err(self.file.exprs.mainTok(s.lhs), .E0435, "indirectly contributed from {s}", .{ctx.where});
        } else try scanContextExpr(self, s.eqn, discrete, is_initial, ctx),
        .jump => {},
        else => try self.file.stmtEdges(id, Walk{ .l = self, .context = context, .ctx = ctx }), // else: stmtEdges is exhaustive
    }
}

/// Every expression reachable from a context statement (`ExprStore.children`).
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
        // §4.5.15, verbatim: analog operators "can not be used inside an initial
        // or always block". Same code as the analog-function-body and
        // analog-initial cases, because it is the same sentence's family of
        // contexts: an operator carries state from one accepted timepoint to the
        // next, and none of these has a timepoint to advance.
        if (tag == .filter_call) try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx.where});
        if (tag == .sys_call and lower_event.isAnalogOnlySysFunc(self.file.str(ex.strOf(e))))
            try self.err(ex.mainTok(e), .E0821, "`{s}` in {s}", .{ self.file.str(ex.strOf(e)), ctx.where });
        // What the mixed-signal kernel cannot do yet, named by the clause that
        // asks for it. Both are legal Verilog-AMS (§7.3.3/§7.3.5).
        if (ctx.mixed) switch (tag) {
            .event_function => try self.err(ex.mainTok(e), .E0437, "`{s}` in {s} is §7.3.6.1's A2D event, and the kernel has no analog-event monitor yet", .{ self.file.str(ex.strOf(e)), ctx.where }),
            .event_initial_step, .event_final_step => try self.err(ex.mainTok(e), .E0437, "a §5.10.2 analog event in {s} is §7.3.6.1's A2D event, and the kernel has no analog-event monitor yet", .{ctx.where}),
            .branch_access, .port_access => try self.err(ex.mainTok(e), .E0437, "an analog probe in {s} is §7.3.6.3's promoted-time read, which the kernel does not do yet", .{ctx.where}),
            else => {}, // else: every other tag is executable or judged elsewhere
        };
        if (tag == .call) {
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
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try scanContextExpr(self, c, discrete, is_initial, ctx);
}
