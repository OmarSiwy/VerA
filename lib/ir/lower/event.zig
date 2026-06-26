//! §5.10 analog events: `@(...)`, cross/above/timer, initial_step/final_step.
//!
//! In: event-controlled statements. Out: event-guarded MIR and the event side tables codegen
//! turns into updateState.
//!
//! LRM clauses this file's code cites: §5.10, §5.10.2, §5.10.3, §5.10.3.1, §9.4.1, §9.4.3, §9.5, §9.5.2, §9.5.4.2, §9.7.3, §9.13.1, §9.13.2.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_control = @import("control.zig");
const lower_expr = @import("expr.zig");
const lower_param = @import("param.zig");
const lower_stmt = @import("stmt.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const dist = @import("../dist.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const VarSlot = Lower.VarSlot;
const poison = Lower.poison;

/// This file's private state on `Lower` (`Lower.event_state`).
pub const State = struct {
    /// §9.4.1 display statements whose CALL is created at the end of the analog
    /// block (`finishDisplays`), in source order — see `queueDisplay` for the
    /// clause reading. Parallel-ish to `displays`: each entry names the
    /// placeholder `displays` row whose `.val` it fills.
    deferred_displays: std.ArrayList(DeferredDisplay) = .empty,
    /// §9.4.1 `$monitor`/`$fmonitor` statements lowered so far. Each one's ordinal
    /// is the key its registration (`$monitor$arm`) and its end-of-step report
    /// share — see `lower_event.armMonitor`.
    monitor_sites: u32 = 0,
    /// Preserve the implementation's omitted-seed sequence numbering across
    /// constant/parameter sites, which now keep their own source-seeded state.
    rng_site_ordinal: u32 = 0,
    /// One hidden seed and first-call flag per source site and elaborated scope.
    rng_internal: std.StringHashMapUnmanaged(InternalSeed) = .empty,
};

const InternalSeed = struct { seed: VarSlot, ready: VarSlot };

/// One §9.4/§9.7 task whose `call` is minted at the END of the analog block —
/// every unconditional display-family statement takes this route (see
/// `queueDisplay`). Holds what the statement position knew and the end of the
/// block will not: the at-statement operand values and the genvar bindings.
const DeferredDisplay = struct {
    name: []const u8,
    tok: u32,
    /// The original argument list, `.none` slots included (A.6.9).
    args: []const Ast.ExprId,
    /// Parallel to `args`. Non-null = the operand's value, captured AT THE
    /// STATEMENT (§5.6.1.2 sequential semantics for everything that is not
    /// converged simulation data — a variable printed then reassigned shows
    /// its at-statement value). Null = the operand reads a branch flow and is
    /// lowered at the end of the block instead, against the converged
    /// retention state (§9.4.1/§5.4.2.2).
    pre: []const ?TypedValue,
    /// §5.9.3 genvar bindings live at the statement, re-established around the
    /// end-of-block lowering so `I(pair[k])` in an unrolled body still folds.
    genvars: []const GenvarBind,
    /// `Ast.AnalogBlock.unit` of the block this statement was written in.
    /// Re-established around the end-of-block lowering for the same reason
    /// `genvars` is: `flowAccum` keys on it (§5.6.8.1's per-instance branch),
    /// and by `finishDisplays` time `cur_unit` is whatever block lowered last.
    unit: u32,
    /// Index of the placeholder row in `displays` whose `.val` this fills.
    display: u32,
    /// §9.4.1 a `$monitor`/`$fmonitor` report: the site key, prepended to the
    /// call's operands. Every operand of one is lowered at the end of the block.
    monitor: ?Mir.Value = null,
};
const GenvarBind = struct { name: []const u8, c: Const };

// ---- §5.10 events -----------------------------------------------------------

/// Lowers an analog event control to a guard: the event becomes a `call` whose
/// integer result codegen answers from the simulator state, and the body runs
/// only when it is set (LRM §5.10, §5.10.2, §5.10.3).
pub fn lowerEventControl(self: *Lower, event: Ast.ExprId, body: Ast.StmtId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(event), .E0702, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Nested event control statements are not allowed" — and A.6.4
    // agrees: `analog_event_statement` has no
    // `analog_event_control_statement` alternative.
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(event), .E0703, "", .{});
        return;
    }
    // §5.8 "Event control statements (e.g.: timer, cross) cannot be used inside
    // conditional statements unless the conditional expression is a constant
    // expression"; §5.9 bans them in repeat/while/non-genvar for outright;
    // §5.10.3.1 repeats it for `cross`. Stricter than E0514 on purpose: the
    // carve-out here is a constant expression, so `analysis("dc")` does not
    // license it and `static_cond_depth` is not consulted.
    if (self.cond_depth != 0) {
        var b = self.errWith(self.file.exprs.mainTok(event), .E0707);
        b.help("put `@(...)` on the spine and make the statement it guards conditional", .{});
        try b.emit();
    }
    const cond = try lowerEventExpr(self, event) orelse return;
    const prev = self.in_event_stmt;
    self.in_event_stmt = true;
    defer self.in_event_stmt = prev;
    const prev_d2a = self.in_d2a_body;
    defer self.in_d2a_body = prev_d2a;
    if (hasD2aTerm(self, event)) self.in_d2a_body = true;
    // §5.10 an event's `hit` flag changes during the solve, so it is never static.
    try lower_control.lowerBranchStmt(self, cond, body, .none, false, .none);
}

fn hasD2aTerm(self: *Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (ex.tag(e) == .event_or) return hasD2aTerm(self, ex.lhs(e)) or hasD2aTerm(self, ex.rhs(e));
    return self.out.discrete_events.contains(e);
}

/// §5.10.1 or-lists, §5.10.2 initial_step/final_step, §5.10.3 cross/above/timer.
fn lowerEventExpr(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
    const ex = &self.file.exprs;
    // §7.3.4 / §7.3.6.2 a digital event term: the explicit D2A flag the host
    // raises for the solve at the tick the event occurred in (§8.5.3.6).
    if (self.out.discrete_events.get(e)) |site|
        return self.param_values.items[self.param_index.get(site.param).?];
    switch (ex.tag(e)) {
        // §5.10.1 `@(a or b)` — active when either is.
        .event_or => {
            const a = try lowerEventExpr(self, ex.lhs(e)) orelse return null;
            const b = try lowerEventExpr(self, ex.rhs(e)) orelse return null;
            return try self.emit(.logor, &.{ a, b });
        },
        // §5.10.2 global events; the analysis-name arguments select which
        // analyses they fire in (`initial_step("dc","tran")`).
        .event_initial_step, .event_final_step => {
            const name = if (ex.tag(e) == .event_initial_step) "initial_step" else "final_step";
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            if (ex.extraOf(e) < ex.pool.items.len) {
                for (ex.nameParts(e)) |p|
                    try args.append(self.arena, try self.mir.addStrConst(self.arena, self.file.str(p)));
            }
            return try self.call(name, args.items);
        },
        // §5.10.3 monitored events.
        .event_function => {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "absdelta")) {
                // §5.10.3.4 "only allowed in an initial or always block": in a
                // digital process it is the mixed-signal kernel's monitor, and
                // here it is misplaced.
                try self.err(self.file.exprs.mainTok(e), .E0513, "", .{});
                return null;
            }
            try checkEventArgBounds(self, e, name); // §5.10.3.1-§5.10.3.3
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            for (ex.args(e)) |a| {
                // A.6.5 permits omitted arguments; keep the position.
                if (a == .none) {
                    try args.append(self.arena, .f_zero);
                    continue;
                }
                try args.append(self.arena, try self.toReal(try lower_expr.lowerExpr(self, a)));
            }
            return try self.call(name, args.items);
        },
        .event_posedge, .event_negedge => {
            try self.err(self.file.exprs.mainTok(e), .E0704, "", .{});
            return null;
        },
        // §5.10.4 `@ hierarchical_event_identifier`: the event's flag is the
        // guard. In scope for Verilog-A: §5.10 lists named events as an analog
        // event kind, and annex C.7 excludes only digital behaviour and events.
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.events.get(name)) |p| return try self.builder.readVariable(p, self.cur);
            try self.err(self.file.exprs.mainTok(e), .E0705, "`{s}`", .{name});
            return null;
        },
        else => { // else: not an event expression: E0706
            try self.err(self.file.exprs.mainTok(e), .E0706, "", .{});
            return null;
        },
    }
}

/// Checks the §5.10.3.1/§5.10.3.2 argument rules for the monitored events
/// (E0517): a non-integer direction, a negative tolerance, and a tolerance with
/// no direction. `timer` gets only the tolerance rule, which §5.10.3.3 repeats
/// for its third argument. Syntax 5-16 types every argument `analog_expression`,
/// so only what folds is judged.
pub fn checkEventArgBounds(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    const is_cross = std.mem.eql(u8, name, "cross");
    if (std.mem.eql(u8, name, "timer")) {
        const args = self.file.exprs.args(e);
        if (args.len < 3 or args[2] == .none) return;
        const c = lower_constfold.constEval(self, args[2]) orelse return;
        if (c == .str or c.asReal() >= 0) return;
        try self.err(self.file.exprs.mainTok(args[2]), .E0517, "`timer()` time_tol shall be non-negative, got {d}", .{c.asReal()});
        return;
    }
    if (!is_cross and !std.mem.eql(u8, name, "above")) return;
    const args = self.file.exprs.args(e);
    // §5.10.3.2 above() has no direction: its tolerances start one slot earlier.
    const dir: ?usize = if (is_cross) 1 else null;
    const tol_first: usize = if (is_cross) 2 else 1;

    if (dir) |d| if (d < args.len and args[d] != .none) {
        if (lower_constfold.constEval(self, args[d])) |c| {
            const v = c.asReal();
            // "shall evaluate to integers". Only a folded non-integral value is
            // refused: 0.5 selects no direction, while a real 1.0 evaluates to one.
            if (c != .str and v != @round(v))
                try self.err(self.file.exprs.mainTok(args[d]), .E0517, "`cross()` direction shall evaluate to an integer, got {d}", .{v});
        }
    };

    var tol_given = false;
    for (tol_first..@min(tol_first + 2, args.len)) |i| {
        if (args[i] == .none) continue;
        tol_given = true;
        const c = lower_constfold.constEval(self, args[i]) orelse continue;
        if (c == .str) continue;
        const v = c.asReal();
        if (v >= 0) continue;
        try self.err(self.file.exprs.mainTok(args[i]), .E0517, "`{s}()` {s} shall be non-negative, got {d}", .{
            name,
            if (i == tol_first) "time_tol" else "expr_tol",
            v,
        });
    }

    // "If either or both tolerances are defined, then the direction shall also
    // be defined." Elision as such is legal — §5.10.3.1's own `sh` example
    // writes `cross(V(smpl) - thresh, dir, , , en === 1'b1)`, so the error is
    // the missing direction, not the comma.
    if (tol_given) if (dir) |d| {
        if (d >= args.len or args[d] == .none) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0517);
            b.msg("a tolerance is given but the direction slot is empty", .{});
            b.help("write the direction explicitly; `0` is \"either edge\"", .{});
            try b.emit();
        }
    };
}

// ---- ch9 system tasks (statement position) ---------------------------------

/// Lowers a §5.12/ch9 system task in statement position. Display and file tasks
/// are void calls codegen may drop; the unsupported set is rejected by name.
pub fn lowerSysTask(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    if (try lower_sysfunc.refuseReserved(self, tok, name)) return;
    const c: Mir.Callee = .fromName(name);
    const family = Mir.callee.family(c);
    const formats = Mir.callee.takesFormat(c);
    if (isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(tok, .E0806, "`{s}`", .{name});
        return;
    }
    // §9.7.2, final sentence: "The $stop task shall not be used within an
    // analog initial block." Positional, not a support question — $stop in an
    // ordinary analog block is legal.
    if (self.in_analog_initial and std.mem.eql(u8, name, "$stop")) {
        try self.err(tok, .E0807, "", .{});
        return;
    }
    if (try lower_sysfunc.checkArity(self, tok, name, args)) return;
    if (c == .@"$clog2") {
        _ = try lower_sysfunc.lowerClog2(self, tok, args[0]);
        return;
    }
    // §9.13 Table 9-10 in statement position. They are FUNCTIONS, so a bare
    // `$random(s);` is only ever written for the seed's inout side effect — which
    // is exactly what `lowerRandom` performs; the variate is dropped.
    if (try lowerRandom(self, tok, name, args)) |_| return;
    // §9.4.3's pairing rule is stated for the display tasks and §9.5.2 defines
    // the file ones as "the same as their counterparts", so it covers both.
    // `checkFormatPairing` takes the first argument that folds to a string,
    // which steps over the descriptor.
    if (formats) try checkFormatPairing(self, tok, args);
    // §9.5.3/§9.5.4.2: all three of these write through an argument, which is
    // not something a `call` result can do — see `lowerStringWrite`/`lowerScan`.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat"))
        return lowerStringWrite(self, tok, name, args);
    if (std.mem.eql(u8, name, "$sscanf")) {
        _ = try lowerScan(self, tok, args); // the count is the value; a statement drops it
        return;
    }
    // §9.5.4: the same shape as `$sscanf` for the same reason — a destination
    // argument. In statement position the count is dropped, the write is not.
    if (try lowerFileRead(self, tok, name, args)) |_| return;
    if (try lowerKernelCtl(self, tok, name, args)) return; // §9.17
    // §9.4.1 `$monitor` and its §9.5.2 file twin: registered HERE, reported at
    // the end of every accepted step from then on — see `armMonitor`.
    const mon: ?Mir.Value = if (c == .@"$monitor" or c == .@"$fmonitor") try armMonitor(self, name) else null;
    if (mon != null and self.restrict == null) return queueDisplay(self, tok, name, args, mon);
    // §9.4.1 the display/severity/control family on the unconditional spine:
    // its call is minted at the end of the block, where an operand that reads a
    // branch flow is evaluated (see `queueDisplay`). Conditional and restricted
    // cases mint the call at the statement: a guarded call has to stay in its
    // arm, and E0421 fires where `restrict` is still set.
    if ((family == .display or family == .simctl) and
        self.cond_depth == 0 and self.restrict == null)
        return queueDisplay(self, tok, name, args, null);
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    var live: std.ArrayList(Ast.ExprId) = .empty;
    defer live.deinit(self.arena);
    var tys: std.ArrayList(Ty) = .empty;
    defer tys.deinit(self.arena);
    for (args, 0..) |a, i| {
        if (a == .none) continue; // A.6.9 empty argument slot
        const tv = try lower_sysfunc.lowerTaskArg(self, a, name);
        if (try lower_sysfunc.checkDescriptor(self, name, i, a, tv)) return;
        try vals.append(self.arena, tv.v);
        try live.append(self.arena, a);
        try tys.append(self.arena, tv.ty);
    }
    if (family == .file_out) {
        self.out.uses.insert(.file_tasks);
        // The §9.4.3 formatter renders into a scratch row before the write, so a
        // module with a §9.5.2 output task needs the string kernels too.
        self.out.uses.insert(.str_tasks);
    }
    if (formats) {
        // §9.4.3's other pairing half — each conversion against its operand's
        // TYPE. After the loop, because the types are what lowering computed.
        try prepareFormatArgs(self, live.items, tys.items, vals.items);
    }
    // A restricted context's monitor reports at the statement: its operands
    // are diagnosed there, and an inlined function's locals end with the body.
    if (mon) |k| try vals.insert(self.arena, 0, k);
    const v = try self.call(name, vals.items);
    // ponytail: printing and simulation control share one display-chain append.
    if (formats or family == .simctl) {
        // §9.7.1/§9.7.2 simulation control joins the per-accepted-point
        // display phase: both clauses tie the task to "an accepted iteration",
        // and §9.7.3's $fatal already travels this way. The printing artifact
        // stops the run at its position among the prints (cg_display.emitSimCtl);
        // a device drops it with W0850, because eval has no channel to stop a
        // host's solve. A conditional call travels `display_cond_place` like a
        // conditional $strobe (§9.4.6).
        const cond = self.cond_depth != 0;
        if (cond) try self.chainCondDisplay(v);
        try self.out.displays.append(self.arena, .{
            .val = v,
            .name = name,
            .tok = tok,
            .conditional = cond,
        });
    }
}

/// Sequences one unconditional display-family statement: captures its operands
/// and mints its `call` at the end of the analog block (LRM §9.4.1).
///
/// Why the end: $strobe displays data once "the simulator has converged", and
/// §5.4.2.2 makes a source branch's flow accessible "anywhere in the module".
/// A flow source's value is the §5.6.1.2 retained accumulator, settled only at
/// the end of the cycle (§5.6.1.3), so an operand that reads one is lowered in
/// `finishDisplays`, where the `flowAccum` read is the final retained value.
///
/// Only those operands move. Any other operand keeps its at-statement value, so
/// `x = 1; $strobe("%g", x); x = 2;` prints 1. The split is per operand because
/// SSA dominance puts a whole tree after the accumulator value it contains.
///
/// $display and $strobe collapse onto the same phase, since the printing
/// artifact runs the display chain once per accepted point; §9.7's tasks travel
/// the same chain. The §9.5.2 file writers do not take this route: §9.5.9
/// sequences them against `$fgets`/`$ftell` at statement order. The call is
/// minted at the end even when no operand defers, so prints keep source order.
///
/// A non-null `monitor` is a `$monitor`/`$fmonitor` report (`armMonitor`): every
/// operand defers, because the report runs at the end of each accepted step
/// whether or not the statement ran, and it may come from a guarded statement.
fn queueDisplay(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId, monitor: ?Mir.Value) Oom!void {
    const pre = try self.arena.alloc(?TypedValue, args.len);
    var any_deferred = false;
    for (args, pre) |a, *p| {
        p.* = null;
        if (a == .none) continue; // A.6.9 empty argument slot
        if (monitor != null or containsFlowRead(self, a)) {
            any_deferred = true;
            continue;
        }
        p.* = try lower_sysfunc.lowerTaskArg(self, a, name);
    }
    // §5.9.3 an unrolled body's genvar bindings are gone from `consts` by
    // `finishDisplays`, so a deferred operand snapshots them.
    var genvars: []const GenvarBind = &.{};
    if (any_deferred and self.active_genvars.items.len != 0) {
        const gs = try self.arena.alloc(GenvarBind, self.active_genvars.items.len);
        for (self.active_genvars.items, gs) |gname, *g|
            g.* = .{ .name = gname, .c = self.consts.get(gname).? };
        genvars = gs;
    }
    try self.event_state.deferred_displays.append(self.arena, .{
        .name = name,
        .tok = tok,
        .args = args,
        .pre = pre,
        .genvars = genvars,
        .unit = self.cur_unit,
        .display = @intCast(self.out.displays.items.len),
        .monitor = monitor,
    });
    // The placeholder keeps `displays` in source order — W0850 reporting and
    // the chain both walk it — and `lowerDeferredDisplays` fills `.val`.
    try self.out.displays.append(self.arena, .{
        .val = .undef,
        .name = name,
        .tok = tok,
        .conditional = false,
    });
}

/// §9.4.1: "When a $monitor task is invoked with one or more arguments, the
/// simulator sets up a mechanism whereby for each accepted step, if the variable
/// or an expression in the argument list changes value compared with the last
/// accepted step ... the entire argument list is displayed at the end of the
/// time step as if reported by the $strobe task."
///
/// So one statement is two events. The invocation happens at the statement,
/// under its guards: this call, `$monitor$arm(k)`, latches site `k` on. The
/// report is `queueDisplay`'s end-of-block call with `k` prepended and runs at
/// the end of every accepted step from then on; codegen joins the two on `k`
/// (`str_kernels.zMonitor`). A monitor armed once under `@(initial_step)` keeps
/// reporting.
///
/// The arm rides `display_cond_place`, not `displays`: the report already has
/// the statement's `displays` row, and W0850 is one warning per statement.
fn armMonitor(self: *Lower, name: []const u8) Oom!Mir.Value {
    if (std.mem.eql(u8, name, "$fmonitor")) {
        self.out.uses.insert(.file_tasks);
        self.out.uses.insert(.str_tasks);
    }
    const k = try self.mir.addIntConst(self.arena, self.event_state.monitor_sites);
    self.event_state.monitor_sites += 1;
    try self.chainCondDisplay(try self.call("$monitor$arm", &.{k}));
    return k;
}

/// Does this operand tree read a branch FLOW (§4.4.1 `I(...)` under any
/// §3.6.1.4 spelling)? That is the one read whose value is position-dependent
/// inside the block (§5.6.1.2 retention); potentials and §5.4.3 port flows
/// resolve to solver unknowns and read the same value everywhere, so they do
/// not force an operand to the end. Every child edge is searched
/// (`ExprStore.children`), assignment-pattern elements included.
fn containsFlowRead(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .branch_access) {
        const kind = self.access_kind.get(self.file.str(ex.strOf(e))) orelse return false;
        return kind == .flow;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (containsFlowRead(self, c)) return true;
    return false;
}

/// The end-of-block half of `queueDisplay`: lower what was deferred, mint each
/// call, fill its `displays` placeholder. Runs at the top of `finishDisplays`,
/// with `self.cur` past the last statement and past `lowerModule`'s final
/// accumulator reads — so a `flowAccum` read here is the §5.6.1.3 end-of-cycle
/// retention state, phis and all.
pub fn lowerDeferredDisplays(self: *Lower) Oom!void {
    for (self.event_state.deferred_displays.items) |dd| {
        // Provenance: instructions minted here belong to the display
        // statement, not to whatever token the block ended on.
        self.mir.cur_tok = dd.tok;
        self.cur_unit = dd.unit;
        for (dd.genvars) |g| try self.consts.put(self.arena, g.name, g.c);
        var vals: std.ArrayList(Mir.Value) = .empty;
        defer vals.deinit(self.arena);
        var live: std.ArrayList(Ast.ExprId) = .empty;
        defer live.deinit(self.arena);
        var tys: std.ArrayList(Ty) = .empty;
        defer tys.deinit(self.arena);
        for (dd.args, dd.pre) |a, p| {
            if (a == .none) continue;
            const tv = p orelse try lower_sysfunc.lowerTaskArg(self, a, dd.name);
            try vals.append(self.arena, tv.v);
            try live.append(self.arena, a);
            try tys.append(self.arena, tv.ty);
        }
        for (dd.genvars) |g| _ = self.consts.remove(g.name);
        // §9.4.3 conversion-vs-type pairing, postponed with the operands.
        try prepareFormatArgs(self, live.items, tys.items, vals.items);
        if (dd.monitor) |k| try vals.insert(self.arena, 0, k);
        self.out.displays.items[dd.display].val = try self.call(dd.name, vals.items);
    }
}

/// Sequences one §9.5 file-family call into the per-point I/O phase.
///
/// Every §9.5 call has a side effect on a descriptor, and §9.5.9 puts those at
/// the accepted point ("the file write operations shall not be performed unless
/// the iteration is accepted"). The display chain is that phase: codegen keeps
/// it out of the shared core so its side effects cannot run per Newton
/// iteration. So a file call joins the chain whether or not its value is read
/// (a discarded `$fgets` count still moves what `$ftell` measures).
///
/// The chain carries reals (`fadd`) and every §9.5 function is integer-valued,
/// so the carrier is `$itor`.
pub fn sequenceFileCall(self: *Lower, tok: u32, name: []const u8, v: Mir.Value) Oom!void {
    self.out.uses.insert(.file_tasks);
    const carrier = try self.call("$itor", &.{v});
    const cond = self.cond_depth != 0;
    if (cond) try self.chainCondDisplay(carrier);
    try self.out.displays.append(self.arena, .{
        .val = carrier,
        .name = name,
        .tok = tok,
        .conditional = cond,
    });
}

/// §9.5.4.1 `code = $fgets( str, fd )`, §9.5.4.2 `code = $fscanf( fd, format,
/// args )` and §9.7.3-adjacent §9.5.7 `errno = $ferror( fd, str )` — the three
/// §9.5 calls that write through an argument as well as returning a value.
///
/// Same rewrite as `lowerScan`: an out-parameter has no spelling in an SSA
/// expression tree. One source call becomes the count (or errno) plus one
/// reader per destination, each taking the count as its first operand, which
/// sequences the pair and carries the "nothing was assigned" rule into the
/// reader. Returns null when `name` is not one of the three.
pub fn lowerFileRead(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?Mir.Value {
    const eq = std.mem.eql;
    const gets = eq(u8, name, "$fgets");
    const scan = eq(u8, name, "$fscanf");
    const ferr = eq(u8, name, "$ferror");
    if (!gets and !scan and !ferr) return null;
    self.out.uses.insert(.file_tasks);
    // §9.5.4.2's conversions are §9.5.3's conversions, so the scanner is the
    // string one and the string kernels have to be there.
    if (scan) self.out.uses.insert(.str_tasks);

    // Syntax 9-6/9-7/9-9: `$fgets` takes the destination first, `$ferror`
    // second; `$fscanf` takes the descriptor, the format, then the destinations.
    const fd_at: usize = if (gets) 1 else 0;
    if (args.len <= fd_at or args[fd_at] == .none) {
        try self.err(tok, .E0813, "`{s}` needs a file descriptor", .{name});
        return try self.mir.addIntConst(self.arena, 0);
    }
    const fd_tv = try lower_sysfunc.lowerSysArg(self, args[fd_at], false); // a descriptor, never a net
    if (try lower_sysfunc.checkDescriptor(self, name, fd_at, args[fd_at], fd_tv)) return try self.mir.addIntConst(self.arena, 0);
    const fd = fd_tv.v;
    // §9.5.4.2 alone has a control string, and it is an operand of every reader
    // as well as of the count.
    const fmt: ?Mir.Value = if (scan) blk: {
        if (args.len < 2 or args[1] == .none) {
            try self.err(tok, .E0813, "`$fscanf` needs a format string", .{});
            break :blk null;
        }
        // Only a literal format can be checked — `lowerScan`'s reasoning, and
        // its diagnostic, apply verbatim to the file source of the same scan.
        if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
            .str => |s| if (try checkScanFormat(self, tok, s)) break :blk null,
            else => {},
        };
        break :blk (try lower_expr.lowerExpr(self, args[1])).v;
    } else null;
    if (scan and fmt == null) return try self.mir.addIntConst(self.arena, 0);

    const n = if (gets)
        try self.call("$fgets", &.{fd})
    else if (ferr)
        try self.call("$ferror", &.{fd})
    else
        try self.call("$fscanf", &.{ fd, fmt.? });
    try sequenceFileCall(self, tok, name, n);

    const dests = if (gets) args[0..1] else if (ferr) args[1..] else args[2..];
    var item: i64 = 0;
    for (dests) |a| {
        if (a == .none) continue;
        const slot = try lower_stmt.resolveLvalue(self, a) orelse continue;
        // §9.5.4.1/§9.5.7 write a string; only §9.5.4.2 has typed items, and
        // there the destination's declared type picks the callee as in
        // `lowerScan`: the name is the type, so `sysFuncTy` and
        // `callee.ty` cannot disagree.
        if (gets or ferr) {
            if (slot.ty != .string) {
                try self.err(self.file.exprs.mainTok(a), .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
                continue;
            }
            const v = try self.call(if (gets) "$fgets$str" else "$ferror$str", &.{ n, fd });
            try lower_stmt.writeLvalue(self, slot, v);
            continue;
        }
        const callee: []const u8 = switch (slot.ty) {
            .integer => "$fscanf$int",
            .string => "$fscanf$str",
            .real => "$fscanf$real",
        };
        const index = try self.mir.addIntConst(self.arena, item);
        const v = try self.call(callee, &.{ n, fd, fmt.?, index });
        // Only successful assignments change destinations. Reuse the count
        // from the sequenced file read; never consume another input window.
        const old = try lower_stmt.readLvalue(self, slot);
        const assigned = try self.emit(.igt, &.{ n, index });
        try lower_stmt.writeLvalue(self, slot, try self.emit(.select, &.{ assigned, v, old }));
        item += 1;
    }
    return n;
}

/// §9.4.3: "for each % character (except %m, %% and %l) that appears in a
/// string, a corresponding expression argument shall be supplied after the
/// string."
///
/// Only a shortfall is diagnosed. The same clause gives a surplus a meaning
/// ("displayed using the default decimal format"), and §9.7.3 puts a
/// non-string first in `$fatal(n, "…")`, so the format is the first argument
/// that folds to a string, the rule `cg_display.emitDisplayTask` uses. A format
/// built at run time is not checked.
pub fn checkFormatPairing(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!void {
    const at, const fmt = for (args, 0..) |a, i| {
        if (try lower_sysfunc.outputLiteral(self, a)) |text| break .{ i, text };
        if (lower_constfold.constEval(self, a)) |c| switch (c) {
            .str => |s| break .{ i, s },
            else => {},
        };
    } else return;

    var need: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) break;
        // §9.4.3 `%[flags][width][.precision]conv`; the conversion letter is
        // what decides, so everything before it is skipped unread.
        while (i < fmt.len and (std.mem.indexOfScalar(u8, "-+ 0.", fmt[i]) != null or
            (fmt[i] >= '0' and fmt[i] <= '9'))) : (i += 1)
        {}
        if (i >= fmt.len) break;
        const conv = std.ascii.toLower(fmt[i]);
        i += 1;
        if (conv == '%' or conv == 'm' or conv == 'l') continue; // the three that consume nothing
        need += 1;
    }

    // A null argument (`,,`) is still an argument — §9.4.1 gives it a
    // rendering — so the supply is the slot count, not the non-empty one.
    const have = args.len - (at + 1);
    if (have >= need) return;
    try self.err(tok, .E0810, "the format string has {d} consuming format specifiers but {d} arguments follow it", .{ need, have });
}

/// Preserve the source integer width before SSA replaces variables with their
/// values. The synthetic identity is consumed by the display formatter only;
/// other conversions still see the same numeric value.
fn formatOperand(self: *Lower, e: Ast.ExprId, tv: TypedValue) Oom!Mir.Value {
    const bits = formatBits(self, e) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0819, "numeric `%s` needs a preserved integral width; this expression's sizing is not implemented", .{});
        return tv.v;
    };
    return self.call("$display$width", &.{ tv.v, try self.mir.addIntConst(self.arena, bits) });
}

/// Only return widths the current analog IR preserves. A guessed carrier width
/// can silently truncate a wide conditional or sign-extend a small operand.
fn formatBits(self: *Lower, e: Ast.ExprId) ?u7 {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => @intCast(if (ex.intLiteral(e).width == 0) 64 else ex.intLiteral(e).width),
        .unary => switch (ex.unOp(e)) {
            .plus => formatBits(self, ex.lhs(e)),
            .minus, .bit_not => if ((formatBits(self, ex.lhs(e)) orelse return null) <= 32) formatBits(self, ex.lhs(e)) else null,
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => 1,
        },
        .ternary => blk: {
            const lhs = formatBits(self, ex.rhs(e)) orelse return null;
            const rhs = formatBits(self, ex.ternaryElse(e)) orelse return null;
            // Mixed-width branches also need signedness propagation before
            // selection. The current IR carries neither fact across a phi.
            break :blk if (lhs == rhs) lhs else null;
        },
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk 32; // §3.2 integer variable
            const pi = self.param_index.get(name) orelse return null;
            const module = self.out.module orelse return null;
            for (module.params) |decl| {
                if (!std.mem.eql(u8, self.file.str(decl.name), self.out.params.items[pi].name)) continue;
                if (decl.ty == .integer) break :blk 32;
                // §3.4.1: an untyped parameter derives its type from the FINAL
                // override. The host's numeric parameter ABI has no width.
                if (!decl.is_local) break :blk null;
                // Host derivation preserves equal-width conditional arms;
                // unsupported dependent expressions diagnose at code generation.
                break :blk formatBits(self, decl.default);
            }
            break :blk null;
        },
        .sys_call => if (std.mem.eql(u8, self.file.str(ex.strOf(e)), "$realtobits")) 64 else 32,
        .binary => switch (ex.binOp(e)) {
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => 1,
            // General arithmetic needs expression-width propagation, not the
            // analog arithmetic emitter's current unconditional wrap32.
            .add, .sub, .mul, .div, .mod, .pow, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => null,
        },
        else => null, // else: no preserved width, so E0819 refuses it rather than guess
    };
}

/// §9.4.3's other pairing rule: each conversion against its operand's type.
/// `checkFormatPairing` counts; this checks that each pair can be rendered
/// (E0819), so a mismatch is reported here rather than failing the device build.
///
/// Walk every format run as `cg_display.buildArgs` does, skipping consumed
/// operands so a string used by `%s` does not become a new format. Numeric
/// `%s` operands also retain their source width through an identity call.
/// A shortfall stops where the operands stop; E0810 already owns it.
fn prepareFormatArgs(self: *Lower, live: []const Ast.ExprId, tys: []const Ty, vals: []Mir.Value) Oom!void {
    std.debug.assert(live.len == tys.len);
    var at: usize = 0;
    while (at < live.len) {
        // Use the actual lowered bytes, including direct literal NUL escapes,
        // so validation and emission inspect the same format.
        const lowered = self.mir.valueDef(vals[at]);
        const fmt_or: ?[]const u8 = if (lowered == .str_const) lowered.str_const else if (lower_constfold.constEval(self, live[at])) |c| switch (c) {
            .str => |str| str,
            else => null,
        } else null;
        const fmt = fmt_or orelse {
            // §9.4.3 a bare operand takes "the default decimal format" — `%d`'s field.
            if (tys[at] == .integer) try decimalWidth(self, live[at], &vals[at]);
            at += 1;
            continue;
        };
        var next = at + 1;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, fmt, i, '%')) |p| {
            i = p + 1;
            if (i >= fmt.len) break;
            while (i < fmt.len and (std.mem.indexOfScalar(u8, "-+ 0.", fmt[i]) != null or
                (fmt[i] >= '0' and fmt[i] <= '9'))) : (i += 1)
            {}
            if (i >= fmt.len) break;
            const conv = std.ascii.toLower(fmt[i]);
            i += 1;
            if (conv == '%' or conv == 'm' or conv == 'l') continue; // the three that consume nothing
            if (next >= tys.len) return; // ran out of operands: E0810's finding, not ours
            const ty = tys[next];
            const arg = live[next];
            next += 1;
            // What `cg_display.appendConv` renders per (conversion, type):
            //   %d/%b/%o/%h/%x — any type; a string takes §2.7's integer view.
            //   %c             — an integer's low byte (Table 9-22); a real rounds.
            //   %s             — text, or §9.4.5's integer ASCII byte sequence.
            //                    Real operands still need a defined conversion.
            //   %e/%f/%g/%r and the %t/%u/%z/%v decimal defaults — numbers only.
            //   anything else  — the operand's natural form, every type.
            const bad = switch (conv) {
                's' => ty != .string and ty != .integer,
                'c' => ty == .string,
                'e', 'f', 'g', 'r', 't', 'u', 'z', 'v' => ty == .string,
                else => false,
            };
            if (!bad) {
                if (conv == 's') {
                    if (ty == .integer) {
                        vals[next - 1] = try formatOperand(self, arg, .{ .v = vals[next - 1], .ty = ty });
                    } else if (self.mir.valueDef(vals[next - 1]) == .str_const) {
                        // §9.4.5 suppresses leading zero bytes of a literal's
                        // packed byte sequence, before field padding. Stored
                        // strings already exclude every NUL (§3.3).
                        const bytes = self.mir.valueDef(vals[next - 1]).str_const;
                        vals[next - 1] = try self.mir.addStrConst(self.arena, std.mem.trimStart(u8, bytes, &.{0}));
                    }
                } else if ((conv == 'h' or conv == 'x' or conv == 'o' or conv == 'b') and ty == .integer) {
                    // A radix conversion shows the operand's bit pattern at
                    // its own width (1364-2005 §17.1.1.2), and §3.2 makes an
                    // `integer` 32 bits: -5 is fffffffb. Only a width this
                    // knows is recorded, and only a narrower one than the
                    // 64-bit carrier — an unknown width keeps the carrier's
                    // pattern instead of becoming `%s`'s E0819 refusal.
                    if (formatBits(self, arg)) |bits| {
                        if (bits < 64) vals[next - 1] = try self.call("$display$width", &.{
                            vals[next - 1], try self.mir.addIntConst(self.arena, bits),
                        });
                    }
                } else if (conv == 'd' and ty == .integer) {
                    try decimalWidth(self, arg, &vals[next - 1]);
                }
                continue;
            }
            var b = self.errWith(self.file.exprs.mainTok(arg), .E0819);
            b.msg("`%{c}` on a {s} operand", .{ conv, @tagName(ty) });
            if (conv == 's') {
                b.help("print the number with `%g` or `%d`", .{});
            } else if (conv == 'c') {
                b.help("`%c` takes a character code; use `%s` for the text", .{});
            } else {
                b.help("use `%s` for the text, or `%d` for the string's integer value", .{});
            }
            try b.emit();
        }
        at = next;
    }
}

/// IEEE 1364 §17.1.1.3: "the values written to the output ... are sized
/// automatically" — a decimal field is as wide as the operand's largest value.
/// That needs the width AND the signedness, and only an unsigned sized literal
/// carries both through today's IR; every other integer keeps the minimal
/// field `cg_display.buildArgs` documents as a deviation.
fn decimalWidth(self: *Lower, e: Ast.ExprId, v: *Mir.Value) Oom!void {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .int_literal) return;
    const lit = ex.intLiteral(e);
    if (lit.width == 0 or lit.width >= 64 or lit.signed) return;
    v.* = try self.call("$display$width", &.{ v.*, try self.mir.addIntConst(self.arena, lit.width) });
}

/// §9.5.3 `$swrite(str, …)` / `$sformat(str, fmt, …)` — the §9.4.3 formatter
/// with a string variable where the transcript would be: "the first argument to
/// $swrite shall be a string variable to which the resulting string shall be
/// written, instead of a variable specifying the file to which to write".
///
/// Lowered as an assignment, not a void call, because the write is the task: a
/// call whose result nothing reads is dead code once codegen slices a unit out
/// of the MIR. `cg_display` renders it like a `$display`.
fn lowerStringWrite(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    if (args.len == 0 or args[0] == .none) {
        try self.err(tok, .E0813, "`{s}` needs a string variable to write into", .{name});
        return;
    }
    const slot = try lower_stmt.resolveLvalue(self, args[0]) orelse return;
    if (slot.ty != .string) {
        try self.err(self.file.exprs.mainTok(args[0]), .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
        return;
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    var live: std.ArrayList(Ast.ExprId) = .empty;
    defer live.deinit(self.arena);
    var tys: std.ArrayList(Ty) = .empty;
    defer tys.deinit(self.arena);
    // Types are preserved, not coerced: the conversion `cg_display.appendConv`
    // picks depends on the operand's own type (§9.4.3 `%d` on a real is a
    // §4.2.1.1 conversion, `%s` on a string is the text).
    for (args[1..]) |a| {
        if (a == .none) continue;
        const tv = try lower_sysfunc.lowerFormatArg(self, a);
        try vals.append(self.arena, tv.v);
        try live.append(self.arena, a);
        try tys.append(self.arena, tv.ty);
    }
    try checkFormatPairing(self, tok, args[1..]);
    try prepareFormatArgs(self, live.items, tys.items, vals.items);
    self.out.uses.insert(.str_tasks);
    const v = try self.call("$sformat", vals.items);
    try lower_stmt.writeLvalue(self, slot, v);
}

/// §9.5.4.2 `code = $sscanf( str, format, args )`. One source call becomes one
/// `$sscanf` (the count) plus one `$sscanf$<ty>` assignment per output argument,
/// each naming the item it wants by index among the ASSIGNED items — so a `%*d`
/// suppressed field shifts nothing, because it is not assigned.
///
/// An out-parameter has no spelling in an SSA expression tree, and the scan is a
/// pure function of the two strings, so N+1 evaluations compute what one call
/// with N writes would. `str_kernels.zig` says the same from the runtime side.
///
/// Returns the count value; a statement-position call drops it.
pub fn lowerScan(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!Mir.Value {
    if (args.len < 2 or args[0] == .none or args[1] == .none) {
        try self.err(tok, .E0813, "$sscanf needs a string to read and a format string", .{});
        return self.mir.addIntConst(self.arena, 0);
    }
    const src = (try lower_expr.lowerExpr(self, args[0])).v;
    const fmt = (try lower_expr.lowerExpr(self, args[1])).v;
    // Only a literal format can be checked, and only a literal one is worth
    // checking: a conversion code the scanner does not implement would consume
    // nothing and still be counted, so the model would read a plausible number.
    if (lower_constfold.constEval(self, args[1])) |c| switch (c) {
        .str => |s| if (try checkScanFormat(self, tok, s)) return self.mir.addIntConst(self.arena, 0),
        else => {},
    };
    self.out.uses.insert(.str_tasks);
    // Snapshot the count from the original input/format before any destination
    // assignment, including destinations aliasing either string argument.
    const count = try self.call("$sscanf", &.{ src, fmt });
    var item: i64 = 0;
    for (args[2..]) |a| {
        if (a == .none) continue;
        const slot = try lower_stmt.resolveLvalue(self, a) orelse continue;
        // The destination's declared type picks the callee, exactly as §5.10's
        // `holdSlot` does: the name IS the type, so `callee.ty` and
        // `sysFuncTy` cannot disagree about it.
        const callee: []const u8 = switch (slot.ty) {
            .integer => "$sscanf$int",
            .string => "$sscanf$str",
            .real => "$sscanf$real",
        };
        const index = try self.mir.addIntConst(self.arena, item);
        const v = try self.call(callee, &.{ src, fmt, index });
        // Read the current SSA value per assignment: if a destination occurs
        // twice, a failed later conversion retains the earlier successful one.
        const old = try lower_stmt.readLvalue(self, slot);
        const assigned = try self.emit(.igt, &.{ count, index });
        try lower_stmt.writeLvalue(self, slot, try self.emit(.select, &.{ assigned, v, old }));
        item += 1;
    }
    return count;
}

/// §9.12 / IEEE 1364 §17.10.2 `found = $value$plusargs(user_string, variable)`:
/// "If no string is found matching, the function returns the integer value
/// zero, and the variable provided is not modified" — so, as in `lowerScan`,
/// the write is a `select` on the result over the variable's incoming value.
/// The value is `$sscanf` of the matched plusarg against the whole user_string
/// (the device's `zPlusarg` says why that is the clause's conversion).
pub fn lowerValuePlusargs(self: *Lower, args: []const Ast.ExprId) Oom!Mir.Value {
    const user = (try lower_expr.lowerExpr(self, args[0])).v;
    const found = try self.call("$value$plusargs", &.{user});
    const slot = try lower_stmt.resolveLvalue(self, args[1]) orelse return found;
    self.out.uses.insert(.str_tasks);
    const callee: []const u8 = switch (slot.ty) {
        .integer => "$sscanf$int",
        .string => "$sscanf$str",
        .real => "$sscanf$real",
    };
    const zero = try self.mir.addIntConst(self.arena, 0);
    const v = try self.call(callee, &.{ try self.call("$plusarg$str", &.{user}), user, zero });
    const old = try lower_stmt.readLvalue(self, slot);
    const hit = try self.emit(.igt, &.{ found, zero });
    try lower_stmt.writeLvalue(self, slot, try self.emit(.select, &.{ hit, v, old }));
    return found;
}

// ---------------------------------------------------------------------------
// §9.13 probabilistic distributions
// ---------------------------------------------------------------------------

/// §9.13 Table 9-10, whose "supported in analog context" column reads Yes for
/// every one of the 17 names. One source call becomes TWO pure calls over the
/// seed's incoming value — the variate, and the updated seed §9.13.1/§9.13.2
/// require to be written back through the inout argument — for the reason
/// `lowerScan` splits `$sscanf`: a unit body is an SSA expression tree and an
/// out-parameter has no spelling in one.
///
/// Both halves are functions of the same input, so re-evaluating the block at
/// one operating point re-derives the same pair: §9.13.2's "shall always return
/// the same value given the same seed", and the determinism Newton needs
/// (see `rng_kernels.zig`).
///
/// Returns null when `name` is not one of the 17.
pub fn lowerRandom(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?TypedValue {
    const d = dist.of(name) orelse return null;
    const ex = &self.file.exprs;
    self.out.uses.insert(.rng);

    // Drop A.6.9 empty slots first, so the arity below counts what was written.
    var given: std.ArrayList(Ast.ExprId) = .empty;
    defer given.deinit(self.arena);
    for (args) |a| if (a != .none) try given.append(self.arena, a);

    // §9.13.1 Syntax 9-8 / §9.13.2 Syntax 9-9: the optional trailing
    // `type_string` ("instance" or "global") "shall only be used in calls to a
    // distribution function from within a paramset". Elaboration
    // (`rewriteParamsetDist`) already handled the in-paramset calls, so any
    // string still in the last slot was written outside one.
    if (given.items.len > 0) {
        const last = given.items[given.items.len - 1];
        if (ex.tag(last) == .str_literal) {
            try self.err(self.file.exprs.mainTok(last), .E0816, "`{s}`'s `type_string` argument is only meaningful within a paramset (§6.4)", .{name});
            return poison;
        }
    }

    const want: usize = @as(usize, d.nparam) + 1;
    // §9.13.1's two are the only ones whose seed "may be omitted, in which case
    // the simulator picks a seed"; Syntax 9-9 makes it mandatory everywhere else.
    const min: usize = if (d.nparam == 0) 0 else want;
    if (given.items.len < min or given.items.len > want) {
        try self.err(tok, .E0816, "`{s}` takes {s}{d} argument{s}, got {d}", .{
            name,
            if (min < want) "at most " else "",
            want,
            if (want == 1) "" else "s",
            given.items.len,
        });
        return poison;
    }

    // ---- the seed -----------------------------------------------------------
    var seed: Mir.Value = undefined;
    // Set only for §9.13.2's "If it is an integer VARIABLE, then it is an inout
    // argument"; a parameter, a constant and an omitted seed all leave it null,
    // which is §9.13.1's "the system function does not update the parameter
    // value".
    var write_back: ?VarSlot = null;
    if (given.items.len > 0) {
        const sa = given.items[0];
        const tv = try lower_expr.lowerExpr(self, sa);
        // §9.13.2: "For each system function, the seed argument shall be an
        // integer", and Syntax 9-9 says the same as grammar —
        // `seed ::= integer_variable_identifier | integer_parameter_identifier
        // | [ sign ] decimal_number`. A real is none of the three, and the
        // inout half of the rule needs somewhere to put an updated INTEGER.
        if (tv.ty != .integer) {
            try self.err(self.file.exprs.mainTok(sa), .E0816, "the seed argument shall be an integer, and this one is {s}", .{@tagName(tv.ty)});
            return poison;
        }
        seed = tv.v;
        if (ex.tag(sa) == .ident) if (self.vars.get(self.file.str(ex.strOf(sa)))) |s| {
            if (s.ty == .integer) write_back = s;
        };
    }
    if (write_back == null) {
        const ordinal = self.event_state.rng_site_ordinal;
        self.event_state.rng_site_ordinal += 1;
        if (given.items.len > 0) {
            // §9.13.1/§9.13.2 assign the supplied initial value, then update
            // the hidden seed only when THIS source call executes. The held
            // SSA places give it the same sequencing and rollback as an
            // explicit seed variable, including a skipped branch or loop.
            const state = try internalSeed(self, tok);
            const ready = try self.builder.readVariable(state.ready.place, self.cur);
            const previous = try self.builder.readVariable(state.seed.place, self.cur);
            seed = try self.emit(.select, &.{ try self.toBool(.{ .v = ready, .ty = .integer }), previous, seed });
            try self.builder.writeVariable(state.ready.place, self.cur, .one);
            write_back = state.seed;
        } else {
            // Omitted seeds retain their existing implementation-defined
            // starting values and accepted-point progression.
            const site = self.out.rng_auto_seeds.items.len;
            try self.out.rng_auto_seeds.append(self.arena, 1 + 7919 * @as(i64, ordinal));
            const latch = try self.call("$rng$auto", &.{try self.mir.addIntConst(self.arena, @intCast(site))});
            seed = try self.toInt(.{ .v = latch, .ty = .real });
        }
    }

    // ---- the parameters, and the rules §9.13.2 states about them ------------
    // §4.2.3 suppresses errors in skipped operands. Entry is a conservative
    // proof that the call executes unconditionally; later blocks keep runtime
    // checks even when they would also be safe to diagnose here. Function-local
    // constants can depend on host parameters, so they also stay runtime.
    const eager = self.cur == .entry and self.inlining.items.len == 0;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, seed);
    for (given.items[@min(1, given.items.len)..], 0..) |a, i| {
        const tv = try lower_expr.lowerExpr(self, a);
        try vals.append(self.arena, try self.toReal(tv));
        // A declared parameter default is not the final host-supplied value.
        // Keep static signature/type checks above, and defer numeric checks
        // unless both execution and the argument value are known here.
        if (!eager) continue;
        const c = lower_constfold.foldExpr(self, a, false) orelse continue;
        if (c == .str) continue;
        if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(c.asReal() > 0))
            try self.err(self.file.exprs.mainTok(a), .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{
                name, dist.paramName(d, i), c.asReal(),
            });
        if (d.count and i == 0 and c.asReal() > 0 and
            (!(c.asReal() <= 2147483647.0) or c.asReal() != @trunc(c.asReal())))
            try self.err(self.file.exprs.mainTok(a), .E0816, "`{s}`'s fractional or out-of-range `{s}` is unsupported; the reference count domain is 1..2147483647", .{ name, dist.paramName(d, i) });
    }
    if (eager and d.ordered and d.ty == .real and vals.items.len == 3) {
        const lo = lower_constfold.foldExpr(self, given.items[1], false);
        const hi = lower_constfold.foldExpr(self, given.items[2], false);
        if (lo != null and hi != null and lo.? != .str and hi.? != .str and
            !(lo.?.asReal() < hi.?.asReal()))
        {
            var b = self.errWith(self.file.exprs.mainTok(given.items[1]), .E0816);
            b.msg("the start value shall be smaller than the end value, got {d} and {d}", .{ lo.?.asReal(), hi.?.asReal() });
            b.note("§9.13.2: start and end \"bound the values returned\", and an interval with start above end is empty", .{});
            try b.emit();
        }
    }

    // A required runtime error remains observable even when neither the value
    // nor final seed is used. Share the guarded source-order effect chain with
    // table captures, but do not force an unused distribution's draw loop.
    const rules: u4 = @as(u4, @intCast(d.positive)) |
        (if (d.count) @as(u4, 4) else 0) |
        (if (d.ordered and d.ty == .real) @as(u4, 8) else 0);
    if (rules != 0) {
        if (self.table_effect_place == null) {
            const place = self.builder.newPlace();
            try self.builder.writeVariable(place, .entry, .f_zero);
            self.table_effect_place = place;
        }
        const place = self.table_effect_place.?;
        const previous = try self.builder.readVariable(place, self.cur);
        const checked = try self.call("$rng$check", &.{
            previous,
            try self.mir.addIntConst(self.arena, rules),
            vals.items[1],
            if (d.nparam > 1) vals.items[2] else .f_zero,
        });
        try self.builder.writeVariable(place, self.cur, checked);
    }

    // ---- the two calls ------------------------------------------------------
    const v = try self.call(d.kernel, vals.items);
    // §9.13.1/§9.13.2: "a value is passed to the function and a different value
    // is returned. The variable is initialized by the user and only updated by
    // the system function." Written after the variate, so both read the same
    // incoming seed however the two calls are ordered in the MIR.
    //
    // The write-back is the kernel's own `_next` twin over the same arguments:
    // IEEE 1364 §17.9.3's routines consume a data-dependent number of LCG draws,
    // and §9.13.3 binds this family to that listing, so the updated seed must
    // land where the reference's `long *seed` did.
    if (write_back) |s| {
        const next_name = try std.fmt.allocPrint(self.arena, "{s}_next", .{d.kernel});
        const next = try self.call(next_name, vals.items);
        try self.builder.writeVariable(s.place, self.cur, try self.toInt(.{ .v = next, .ty = .real }));
    }
    return .{ .v = if (d.ty == .integer) try self.toInt(.{ .v = v, .ty = .real }) else v, .ty = switch (d.ty) {
        .real => .real,
        .integer => .integer,
    } };
}

/// Repeated execution of one source site shares its hidden seed. A first-call
/// flag defers a model-card parameter's initialization until the call runs;
/// neither an unevaluated branch nor a discarded Newton iterate consumes it.
fn internalSeed(self: *Lower, tok: u32) Oom!InternalSeed {
    const scope = if (self.inlining.items.len != 0) self.inlining.items[self.inlining.items.len - 1] else self.scope_path;
    const key = try std.fmt.allocPrint(self.arena, "{d}:{s}:{d}", .{ self.cur_unit, scope, tok });
    const entry = try self.event_state.rng_internal.getOrPut(self.arena, key);
    if (!entry.found_existing) {
        const name = try std.fmt.allocPrint(self.arena, "$rng.{d}", .{self.event_state.rng_internal.count() - 1});
        entry.value_ptr.* = .{
            .seed = try lower_param.hiddenHeldInt(self, try std.fmt.allocPrint(self.arena, "{s}.seed", .{name})),
            .ready = try lower_param.hiddenHeldInt(self, try std.fmt.allocPrint(self.arena, "{s}.ready", .{name})),
        };
    }
    return entry.value_ptr.*;
}

/// §9.5.4.2's conversion codes, and nothing else. True when the format was
/// refused. The suppression `*` and the maximum field width are part of the
/// specification and are read past here; `str_kernels.zScan` implements them.
///
/// Case-sensitive, unlike §9.4.3's display table: §9.5.4.2 spells each scan
/// code once, in lower case, and leaves an invalid one implementation
/// dependent. `zScan` compares the raw byte, so `%D` would silently match
/// nothing; refusing it is the useful implementation-dependent result.
fn checkScanFormat(self: *Lower, tok: u32, fmt: []const u8) Oom!bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) break;
        if (fmt[i] == '%') { // a literal percent, matched not converted
            i += 1;
            continue;
        }
        if (fmt[i] == '*') i += 1;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i >= fmt.len) break;
        const conv = fmt[i];
        i += 1;
        // §9.5.4.2's code table has SIX rows, and `r` and `m` are two of them:
        // "r Matches a 'real' number in engineering notation, using the scale
        // factors defined in 2.6.2" and "m Returns the current hierarchical
        // path as a string. Does not read data from the input file or str
        // argument".
        if (std.mem.indexOfScalar(u8, "dohxbcfegsrm", conv) != null) continue;
        var b = self.errWith(tok, .E0813);
        b.msg("$sscanf does not support the conversion `%{c}`", .{conv});
        b.note("§9.5.4.2's codes are %d %o %h %x %b %c %f %e %g %s %r %m", .{});
        try b.emit();
        return true;
    }
    return false;
}

/// §9.17 analog kernel control. Handled here rather than as an ordinary void
/// call because both tasks write to the host, and an unread call would be
/// dropped. Returns true when `name` was one of them.
fn lowerKernelCtl(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!bool {
    // §9.17.2 `$bound_step ( expression ) ;` — "the simulator shall ensure that
    // the next time step taken is no larger than the smallest $bound_step()
    // argument currently active", so the accumulation is a running minimum.
    if (std.mem.eql(u8, name, "$bound_step")) {
        if (args.len != 1 or args[0] == .none) {
            try self.err(tok, .E0802, "got {d}", .{args.len});
            return true;
        }
        // "The expression argument shall be non-negative" (§9.17.2); `abs`
        // would silently repair a model that violates it, so a provably
        // negative constant is a diagnostic and anything else is taken as
        // written.
        if (lower_constfold.constEval(self, args[0])) |c| {
            if (c.asReal() < 0.0) {
                try self.err(self.file.exprs.mainTok(args[0]), .E0803, "got {d}", .{c.asReal()});
                return true;
            }
        }
        const p = try self.kernelCtlPlace(&self.bound_step_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }

    // §9.17.1 `$discontinuity [ ( constant_expression ) ] ;` — the argument is
    // the DEGREE, "a discontinuity in the i'th derivative", so a smaller degree
    // is the more severe announcement and the running minimum is what the host
    // needs. `$discontinuity` with no argument is degree 0.
    if (std.mem.eql(u8, name, "$discontinuity")) {
        const real_args = for (args) |a| {
            if (a != .none) break args;
        } else args[0..0];
        if (real_args.len > 1) {
            try self.err(tok, .E0804, "got {d}", .{real_args.len});
            return true;
        }
        var degree: i64 = 0;
        if (real_args.len == 1) {
            const c = lower_constfold.constEval(self, real_args[0]) orelse {
                try self.err(self.file.exprs.mainTok(real_args[0]), .E0805, "", .{});
                return true;
            };
            // §9.17.1 "i must be a non-negative integer", and §3.3 "A string
            // cannot be assigned to an integral type": a `string` PARAMETER has
            // no integer to be. A string LITERAL does: §3.3 lets it be
            // assigned to an integral type, as its packed bytes (§2.7), which
            // `Const.asIntExact`'s `.str => 0` is not.
            if (c == .str) {
                if (self.file.exprs.tag(real_args[0]) != .str_literal) {
                    try self.err(self.file.exprs.mainTok(real_args[0]), .E0820, "got a `string` value, \"{s}\", which is not an integer", .{c.str});
                    return true;
                }
                degree = Lower.strToInt(c.str, 32);
            } else
            // Same hole as the subscript path: §4.2.1.1 gives an infinity no
            // nearest integer, so there is no degree here to compare against
            // -1. E0820 is the clause's own verdict for a degree it cannot
            // accept, and reporting it keeps the rest of the file compiling.
            degree = c.asIntExact() orelse {
                try self.err(tok, .E0820, "got {e}", .{c.asReal()});
                return true;
            };
        }
        if (degree == -1) {
            if (self.reject_iteration_place == null) {
                const p = self.builder.newPlace();
                try self.builder.writeVariable(p, .entry, .zero);
                self.reject_iteration_place = p;
                self.out.uses.insert(.reject_iteration);
            }
            try self.builder.writeVariable(self.reject_iteration_place.?, self.cur, .one);
            return true;
        }
        if (degree < -1) {
            try self.err(tok, .E0820, "got {d}", .{degree});
            return true;
        }
        const p = try self.kernelCtlPlace(&self.disc_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.mir.addFloatConst(self.arena, @floatFromInt(degree));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }
    return false;
}

/// Whether `name` is a system function whose §9.2 "supported in analog
/// context" cell says No, across the seven Chapter 9 tables (E0806).
///
/// A name test, with no context flag: every statement lowering sees is in the
/// analog context (A.6.2 `analog_construct`, with §4.7.2 function bodies
/// inlined into one).
/// ponytail: add the flag when a §7 digital block is lowered here.
pub fn isDigitalOnlySysFunc(name: []const u8) bool {
    const digital_only = [_][]const u8{
        // Table 9-1 (§9.4.1) — radix variants and the $monitor mode switches.
        "$displayb",         "$displayh",         "$displayo",
        "$strobeb",          "$strobeh",          "$strobeo",
        "$writeb",           "$writeh",           "$writeo",
        "$monitorb",         "$monitorh",         "$monitoro",
        "$monitoron",        "$monitoroff",
        // Table 9-2 (§9.5) — the same radix story against a descriptor, plus
        // the byte/vector reads and the two digital-netlist loaders.
              "$fdisplayb",
        "$fdisplayh",        "$fdisplayo",        "$fwriteb",
        "$fwriteh",          "$fwriteo",          "$fstrobeb",
        "$fstrobeh",         "$fstrobeo",         "$fmonitorb",
        "$fmonitorh",        "$fmonitoro",        "$swriteb",
        "$swriteh",          "$swriteo",          "$fgetc",
        "$ungetc",           "$fread",            "$readmemb",
        "$readmemh",         "$sdf_annotate",
        // Table 9-3 (§9.6) — the timescale tick, which the analog kernel has
        // no notion of.
            "$printtimescale",
        "$timeformat",
        // Table 9-5 (§9.8) — "Verilog AMS HDL does not extend the PLA modeling
        // tasks defined in IEEE Std 1364 Verilog." All sixteen spellings; the
        // `$` inside the name is an ordinary identifier character (§2.8.3), so
        // each of these is one token.
              "$async$and$array",  "$async$and$plane",
        "$async$nand$array", "$async$nand$plane", "$async$or$array",
        "$async$or$plane",   "$async$nor$array",  "$async$nor$plane",
        "$sync$and$array",   "$sync$and$plane",   "$sync$nand$array",
        "$sync$nand$plane",  "$sync$or$array",    "$sync$or$plane",
        "$sync$nor$array",   "$sync$nor$plane",
        // Table 9-6 (§9.9) — "Verilog AMS HDL does not extend the stochastic
        // analysis tasks defined in IEEE Std 1364 Verilog."
          "$q_initialize",
        "$q_remove",         "$q_exam",           "$q_add",
        "$q_full",
        // Table 9-7 (§9.10) — tick counts. $abstime is the analog spelling and
        // is the one row of that table with Yes in both columns; §9.10's NOTE
        // additionally deprecates $realtime in the analog context.
                  "$time",             "$stime",
        "$realtime",
        // Table 9-8 (§9.11) — the extension is four names, not two:
        // "$bitstoreal and $realtobits,$rtoi and $itor can be used in the
        // analog context". Table 9-8's analog column agrees — only $signed and
        // $unsigned read No, and both presuppose a sized vector.
                "$signed",           "$unsigned",
    };
    for (digital_only) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

/// Whether `name` is analog-only: its §9.2 "Supported in digital context" cell
/// is No and its analog cell Yes. §9.7 says it of the severity tasks in prose.
pub fn isAnalogOnlySysFunc(name: []const u8) bool {
    const analog_only = [_][]const u8{
        "$debug", "$fdebug", // Tables 9-1/9-2
        "$fatal", "$warning", "$error", "$info", // Table 9-4
        "$simprobe", // §9.15
        "$discontinuity", "$limit", "$bound_step", // §9.17
        "$param_given", "$port_connected", // §9.19
        "$analog_node_alias", "$analog_port_alias", // §9.20
    };
    for (analog_only) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

/// §9.22 paragraph 3, second sentence: "Driver access functions can only be
/// called from connect modules." §9.23 repeats the fence for its four
/// supplementary functions ("supported in the digital context of
/// connectmodules"), and Table 9-19 gives every name below "Supported in analog
/// context of connectmodule: No".
///
/// A rule about the call site: an ordinary module is not a connect module, so
/// the call is illegal on sight. Answering 0 in codegen would look right and be
/// wrong, since §9.22.2/§9.22.3/§9.23.x index "between 0 and N-1".
///
/// A name test like `isDigitalOnlySysFunc`: every call site lowering reaches is
/// inside the elaborated device, and `elaborate.pickTop` never picks a connect
/// module (§7.6), so a driver call inside one is never lowered here.
///
/// `$receiver_count` is listed because its "Non-normative" §9.22.1 paragraph
/// sits inside §9.22, takes the same `signal_name` argument, and Table 9-19
/// carries it with the rest.
pub fn isConnectModuleOnlySysFunc(name: []const u8) bool {
    const cm_only = [_][]const u8{
        // §9.22.1–§9.22.3 and the §9.22.1 non-normative paragraph.
        "$driver_count",         "$receiver_count", "$driver_state",
        "$driver_strength",
        // §9.23.1–§9.23.4, the supplementary pending-event queries.
             "$driver_delay",   "$driver_next_state",
        "$driver_next_strength", "$driver_type",
    };
    for (cm_only) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}
