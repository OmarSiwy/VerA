//! Clause 9 system tasks in statement position: §9.4 display and monitor,
//! §9.5 file and string I/O, §9.7 simulation control and the §9.7.3 status,
//! §9.17 analog kernel control.
//!
//! In: a `$task(...)` statement, or a §9.5 call `lower/sysfunc.zig` hands over.
//! Out: MIR `call`s on the display chain (`Lowered.displays`, rooted at
//! `Lowered.display_root`), the status channel (`Lowered.status`), and the
//! kernel-control values the host reads after an accepted step.
//!
//! Spine: `lowerSysTask` per statement; `finishKernelCtl` then
//! `finishDisplays` once, after every analog block (`lowerModule`'s order).
//! Every task with an effect on the host joins the display chain, so codegen
//! runs it once per accepted point and never per Newton iteration (§9.5.9).
//!
//! LRM clauses this file's code cites: §2.7, §3.2, §3.3, §3.4.1, §3.6.1.4, §4.2.1.1,
//! §4.4.1, §5.4.2.2, §5.4.3, §5.6.1.2, §5.6.1.3, §5.6.8.1, §5.9.3, §5.10, §5.12, §9.2,
//! §9.4, §9.4.1, §9.4.3, §9.4.5, §9.4.6, §9.5, §9.5.2, §9.5.3, §9.5.4, §9.5.4.1, §9.5.4.2,
//! §9.5.7, §9.5.9, §9.7, §9.7.1, §9.7.2, §9.7.3, §9.12, §9.13, §9.17, §9.17.1, §9.17.2,
//! §12.22.2, §12.30, §12.32.2.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_random = @import("random.zig");
const lower_stmt = @import("stmt.zig");
const lower_sysfunc = @import("sysfunc.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Ssa = @import("../ssa.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const Lowered = Lower.Lowered;
const assert = std.debug.assert;

/// This file's private state on `Lower` (`Lower.systask_state`).
pub const State = struct {
    /// §9.4.1 display statements whose CALL is created at the end of the analog
    /// block (`finishDisplays`), in source order — see `queueDisplay` for the
    /// clause reading. Parallel-ish to `displays`: each entry names the
    /// placeholder `displays` row whose `.val` it fills.
    deferred_displays: std.ArrayList(DeferredDisplay) = .empty,
    /// §9.4.1 `$monitor`/`$fmonitor` statements lowered so far. Each one's ordinal
    /// is the key its registration (`$monitor$arm`) and its end-of-step report
    /// share — see `armMonitor`.
    monitor_sites: u32 = 0,
    /// §9.4.6 the carrier for conditional prints, which cannot be `fadd`-chained
    /// directly because a call inside an `if` arm does not dominate the chain root.
    /// An SSA place seeded `.f_zero` in `.entry`, `fadd`-ed at each guarded call
    /// site and read once at the end: the arm's phi carries the call into the live
    /// slice on the path that ran. Null: no conditional print.
    display_cond_place: ?Ssa.Place = null,
    /// §9.17.2 `$bound_step`: an SSA place seeded to +inf ("nothing asked for") in
    /// the entry block and `fmin`-ed at every call site, so a call under an `if`
    /// bounds the step only on the arm that ran. `finishKernelCtl` turns the final
    /// value into one synthetic `call` (a unit). Null: the model never called it.
    bound_step_place: ?Ssa.Place = null,
    /// VerA's `$vera_reject_step`, the same way: +inf is "no request".
    reject_step_place: ?Ssa.Place = null,
    /// §9.17.1 `$discontinuity`, the same way as `bound_step_place`.
    disc_place: ?Ssa.Place = null,
    /// §9.7.3 the status channel (`Lowered.status`): the code place, seeded 0
    /// ("nothing reported"), then its argument places, written by the FIRST
    /// `$fatal`/`$error` an evaluation reaches. Null: the model has no site.
    status_places: ?[1 + Lowered.status_arg_max]Ssa.Place = null,
    /// §9.17.1 `$discontinuity(-1)`'s flag, seeded 0 and set 1 at each call site;
    /// its final read is `out.reject_iteration`, and `out.uses.reject_iteration`
    /// says it exists.
    reject_iteration_place: ?Ssa.Place = null,
    /// §9.7.3 `$error` inside `analog initial`: an integer place seeded 0 in
    /// `.entry` and set 1 at each such call, and the first call's token.
    /// `haltAfterInitError` reads it after the block. Null: no such call.
    init_error: ?struct { place: Ssa.Place, tok: u32 } = null,
};
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

// ---- statement position -----------------------------------------------------

/// Lowers a §5.12/ch9 system task in statement position. Display and file tasks
/// are void calls codegen may drop; the unsupported set is rejected by name.
pub fn lowerSysTask(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    if (try lower_sysfunc.refuseReserved(self, tok, name)) return;
    const c: Mir.Callee = .fromName(name);
    const family = Mir.callee.family(c);
    const formats = Mir.callee.takesFormat(c);
    if (lower_sysfunc.isDigitalOnlySysFunc(name)) { // §9.2
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
    if (try lower_random.lowerRandom(self, tok, name, args)) |_| return;
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
    if (c == .@"$fatal" and try badFinishNumber(self, args)) return;
    if (c == .@"$fatal" or c == .@"$error") try lowerStatus(self, tok, c == .@"$fatal", args);
    if (c == .@"$error" and self.in_analog_initial) {
        const ie = self.systask_state.init_error orelse blk: {
            const p = self.builder.newPlace();
            try self.builder.writeVariable(p, .entry, .zero);
            self.systask_state.init_error = .{ .place = p, .tok = tok };
            break :blk self.systask_state.init_error.?;
        };
        try self.builder.writeVariable(ie.place, self.cur, .one);
    }
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
    if (c == .systf) try systfOutputs(self, v, live.items, vals.items);
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
        if (cond) try chainCondDisplay(self, v);
        try self.out.displays.append(self.arena, .{
            .val = v,
            .name = name,
            .tok = tok,
            .conditional = cond,
        });
    }
}

/// §12.22.2 a user system task's output arguments: `$resistor(curr, V(p, n),
/// r)`'s calltf puts `curr` (§12.30) and its partials (§12.32.2), and the
/// next statement reads it. Every argument that is a real or integer variable
/// is read back after `call` as `$systf$out(call, j, args...)`, j 1-based as
/// §12.32.2 numbers arguments; an argument calltf did not put keeps its value
/// (`contract.SystfHost.output`). An integer takes the real §4.2.1.1 rounds.
fn systfOutputs(self: *Lower, call: Mir.Value, live: []const Ast.ExprId, vals: []const Mir.Value) Oom!void {
    const ex = &self.file.exprs;
    for (live, 0..) |a, j| {
        if (ex.tag(a) != .ident) continue;
        const s = self.vars.get(self.file.str(ex.strOf(a))) orelse continue;
        // A `reg` (§7.3.1) keeps its width rule; a string has no partials.
        if (s.ty == .string or s.reg_width != null) continue;
        const args = try self.arena.alloc(Mir.Value, vals.len + 2);
        args[0] = call;
        args[1] = try self.mir.addIntConst(self.arena, @intCast(j + 1));
        @memcpy(args[2..], vals);
        const out = try self.call("$systf$out", args);
        const lv: lower_stmt.Lvalue = .{ .ty = s.ty, .at = .{ .place = s.place } };
        try lower_stmt.writeLvalue(self, lv, if (s.ty == .integer) try self.emit(.fi_cast, &.{out}) else out);
    }
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
        const p = try kernelCtlPlace(self, &self.systask_state.bound_step_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }

    // VerA's `$vera_reject_step(t_retry)`: ask the host to reject the step
    // it is accepting and retry it ending at `t_retry`. The request is read
    // off the accepted solution by `updateState`, so the accumulation is a
    // running minimum, as `$bound_step`'s is: the earliest retry wins.
    if (std.mem.eql(u8, name, "$vera_reject_step")) {
        // An `analog initial` block runs once per analysis and an analog
        // function per call: neither is a step the host accepts.
        if (self.restrict) |ctx| {
            try self.err(tok, .E0533, "in {s}", .{ctx});
            return true;
        }
        const p = try kernelCtlPlace(self, &self.systask_state.reject_step_place);
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
            if (self.systask_state.reject_iteration_place == null) {
                const p = self.builder.newPlace();
                try self.builder.writeVariable(p, .entry, .zero);
                self.systask_state.reject_iteration_place = p;
                self.out.uses.insert(.reject_iteration);
            }
            try self.builder.writeVariable(self.systask_state.reject_iteration_place.?, self.cur, .one);
            return true;
        }
        if (degree < -1) {
            try self.err(tok, .E0820, "got {d}", .{degree});
            return true;
        }
        const p = try kernelCtlPlace(self, &self.systask_state.disc_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.mir.addFloatConst(self.arena, @floatFromInt(degree));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }
    return false;
}

/// Returns the kernel-control place in `slot`, creating it on first use seeded
/// to +inf in the entry block. +inf is both `fmin`'s identity and "the model
/// asked for nothing", so no "was it called" flag has to survive the CFG.
fn kernelCtlPlace(self: *Lower, slot: *?Ssa.Place) Oom!Ssa.Place {
    if (slot.*) |p| return p;
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_inf);
    slot.* = p;
    return p;
}

/// §9.7.3: "If $error is executed within an analog initial block, then the
/// message is issued and the initialization continues. However, the
/// simulation shall not proceed past initialization." Called after an
/// `analog initial` block: when one of its `$error` calls ran, a synthetic
/// `$fatal(1, …)` ends the run there, after the block's own prints and before
/// any of the analog block's. Status 1: a run an error ended (`$fatal`'s floor).
pub fn haltAfterInitError(self: *Lower) Oom!void {
    const ie = self.systask_state.init_error orelse return;
    const hit = try self.builder.readVariable(ie.place, self.cur);
    const then_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(hit, then_b, join, false);
    self.cur = then_b;
    self.cond_depth += 1;
    defer self.cond_depth -= 1;
    const v = try self.call("$fatal", &.{
        try self.mir.addIntConst(self.arena, 1),
        try self.mir.addStrConst(self.arena, "an $error in analog initial: the simulation does not proceed past initialization"),
    });
    try chainCondDisplay(self, v);
    try self.out.displays.append(self.arena, .{ .val = v, .name = "$fatal", .tok = ie.tok, .conditional = true });
    try self.gotoBlock(join);
    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §9.7.3 Syntax 9-7 `finish_number ::= 0 | 1 | 2`: reports E0824 and returns
/// true when `$fatal`'s first argument is a number that is not one of the
/// three. A string first argument is a message with the number omitted
/// (`cg_display.emitDisplayTask` keeps its text), not a finish_number.
fn badFinishNumber(self: *Lower, args: []const Ast.ExprId) Oom!bool {
    if (args.len == 0 or args[0] == .none) return false;
    const cv = lower_constfold.constEval(self, args[0]);
    if (cv) |v| switch (v) {
        .str => return false,
        .int => |n| if (n >= 0 and n <= 2) return false,
        .real => |x| if (x == 0 or x == 1 or x == 2) return false,
    };
    if (cv == null and try lower_sysfunc.outputLiteral(self, args[0]) != null) return false;
    try self.err(self.file.exprs.mainTok(args[0]), .E0824, "`$fatal`'s finish_number shall be 0, 1 or 2", .{});
    return true;
}

/// §9.7.3 `$fatal`/`$error` as a STATUS for a device, which cannot print or
/// stop its host (`Lowered.status`). Records the site, then makes the site the
/// evaluation's status unless an earlier one already is: the code place
/// keeps its value when nonzero, and each argument place moves only with it.
/// Runs at the statement, under its guards, so a call on an arm that did not
/// run reports nothing. The printing artifact ignores the result.
fn lowerStatus(self: *Lower, tok: u32, fatal: bool, args: []const Ast.ExprId) Oom!void {
    const site: u32 = @intCast(self.out.status_sites.items.len);
    // §9.7.3 `$fatal(finish_number, "…", …)`: the format is the first
    // argument that is a string literal, as `checkFormatPairing` reads it.
    var fmt: []const u8 = "";
    var first = args.len;
    for (args, 0..) |a, i| {
        if (a == .none) continue;
        const text = try lower_sysfunc.outputLiteral(self, a) orelse
            if (lower_constfold.constEval(self, a)) |cv| switch (cv) {
                .str => |s| s,
                else => null,
            } else null;
        if (text) |t| {
            fmt = t;
            first = i + 1;
            break;
        }
    }
    try self.out.status_sites.append(self.arena, .{ .fatal = fatal, .fmt = fmt, .tok = tok });

    const ps = self.systask_state.status_places orelse blk: {
        var ps: [1 + Lowered.status_arg_max]Ssa.Place = undefined;
        for (&ps) |*p| {
            p.* = self.builder.newPlace();
            try self.builder.writeVariable(p.*, .entry, .f_zero);
        }
        self.systask_state.status_places = ps;
        break :blk ps;
    };
    const cur = try self.builder.readVariable(ps[0], self.cur);
    const first_here = try self.emit(.feq, &.{ cur, .f_zero });
    const code: f64 = @floatFromInt((@as(u32, if (fatal) 1 else 2) << 24) | (site + 1));
    try self.builder.writeVariable(ps[0], self.cur, try self.emit(.select, &.{ first_here, try self.mir.addFloatConst(self.arena, code), cur }));
    var k: usize = 0;
    for (args[@min(first, args.len)..]) |a| {
        if (a == .none) continue;
        if (k == Lowered.status_arg_max) break;
        const tv = try lower_sysfunc.lowerTaskArg(self, a, if (fatal) "$fatal" else "$error");
        // A string argument has no numeric slot; `contract.formatStatus`
        // prints `%s` as `?`.
        const v = if (tv.ty == .string) Mir.Value.f_zero else try self.toReal(tv);
        const old = try self.builder.readVariable(ps[1 + k], self.cur);
        try self.builder.writeVariable(ps[1 + k], self.cur, try self.emit(.select, &.{ first_here, v, old }));
        k += 1;
    }
}

// ---- §9.4 display and monitor -----------------------------------------------

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
    try self.systask_state.deferred_displays.append(self.arena, .{
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
    const k = try self.mir.addIntConst(self.arena, self.systask_state.monitor_sites);
    self.systask_state.monitor_sites += 1;
    try chainCondDisplay(self, try self.call("$monitor$arm", &.{k}));
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

/// Carries one guarded §9.4/§9.5/§9.7 call into the display slice. The value is
/// discarded at the root; the `fadd` gives the call a use, without which
/// codegen's slice drops the print.
pub fn chainCondDisplay(self: *Lower, v: Mir.Value) Oom!void {
    const p = self.systask_state.display_cond_place orelse blk: {
        const np = self.builder.newPlace();
        try self.builder.writeVariable(np, .entry, .f_zero);
        self.systask_state.display_cond_place = np;
        break :blk np;
    };
    const prev = try self.builder.readVariable(p, self.cur);
    try self.builder.writeVariable(p, self.cur, try self.emit(.fadd, &.{ prev, v }));
}

// ---- §9.4.3 format strings --------------------------------------------------

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

// ---- §9.5 string and file I/O -----------------------------------------------

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
    // §9.5.3: "$sformat always interprets its second argument, and only its
    // second argument, as a format string. This format argument can be a
    // static string ... or can be a string variable whose content is
    // interpreted as the format string." A literal is translated at compile
    // time; anything else is formatted at run time (`$sformat$rt`).
    if (std.mem.eql(u8, name, "$sformat") and args.len > 1 and args[1] != .none and
        try lower_sysfunc.outputLiteral(self, args[1]) == null and
        (if (lower_constfold.constEval(self, args[1])) |cv| cv != .str else true))
    {
        const f = try lower_expr.lowerExpr(self, args[1]);
        if (f.ty != .string) {
            try self.err(self.file.exprs.mainTok(args[1]), .E0813, "`$sformat`'s format_string is a string, and this one is {s}", .{@tagName(f.ty)});
            return;
        }
        try vals.append(self.arena, f.v);
        for (args[2..]) |a| {
            if (a == .none) continue;
            try vals.append(self.arena, (try lower_sysfunc.lowerFormatArg(self, a)).v);
        }
        self.out.uses.insert(.str_tasks);
        return lower_stmt.writeLvalue(self, slot, try self.call("$sformat$rt", vals.items));
    }
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
    const src_tv = try lower_expr.lowerExpr(self, args[0]);
    // §9.5.4.2: "$sscanf reads from the string str (which shall be a string
    // variable, string parameter, or string literal)". A number has no
    // characters to scan.
    if (src_tv.ty != .string) {
        try self.err(self.file.exprs.mainTok(args[0]), .E0813, "`$sscanf` reads from a string variable, string parameter or string literal, and this one is {s}", .{@tagName(src_tv.ty)});
        return self.mir.addIntConst(self.arena, 0);
    }
    const src = src_tv.v;
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
    if (cond) try chainCondDisplay(self, carrier);
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

// ---- end of the analog block ------------------------------------------------

/// §9.17.1/§9.17.2. Turns each accumulated kernel-control place into exactly one
/// synthetic `call`, whose single argument is the value the host must read.
/// `naming.enumerateUnits` gives that call a unit; `codegen.emitStateMachine`
/// evaluates the unit once per accepted step and stores it into `Instance`.
pub fn finishKernelCtl(self: *Lower) Oom!void {
    if (self.systask_state.reject_iteration_place) |p| self.out.reject_iteration = try self.builder.readVariable(p, self.cur);
    if (self.systask_state.reject_step_place) |p| self.out.reject_step = try self.builder.readVariable(p, self.cur);
    if (self.systask_state.status_places) |ps| {
        self.out.status = try self.builder.readVariable(ps[0], self.cur);
        for (&self.out.status_args, ps[1..]) |*a, p| a.* = try self.builder.readVariable(p, self.cur);
    }
    if (self.systask_state.bound_step_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$bound_step", &.{v});
    }
    if (self.systask_state.disc_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$discontinuity", &.{v});
    }
}

/// §9.4 Chains every unconditional display call into one value, so codegen has
/// a single live root to slice a unit from. `fadd` is the cheapest carrier: the
/// sum is discarded, and rendering it walks the operands in MIR order, which is
/// source order.
///
/// Only `cond_depth == 0` calls join directly. They lie on the straight-line
/// spine of the analog block, so each one dominates `self.cur` here; a call
/// inside an `if` arm does not, and chaining it would be invalid SSA. Those
/// reach the root through `display_cond_place` instead — one read of a place
/// the arms wrote, an ordinary phi. §9.4.6 is satisfied by where the call
/// sits: it stays in the arm's block and codegen emits the arm as an `if`.
// ponytail: print order is MIR order, so a module that prints both kinds shows
// the guarded lines first, whatever the source order. Upgrade path: give
// `Display` a source-order index and have codegen emit by it.
pub fn finishDisplays(self: *Lower) Oom!void {
    try lowerDeferredDisplays(self);
    var root: Mir.Value = .f_zero;
    var first = true;
    for (self.out.displays.items) |d| {
        if (d.conditional) continue;
        // Every unconditional entry either carried its call from the
        // statement or was a `queueDisplay` placeholder just filled above.
        assert(d.val != .undef);
        root = if (first) d.val else try self.emit(.fadd, &.{ root, d.val });
        first = false;
    }
    if (self.systask_state.display_cond_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        root = if (first) v else try self.emit(.fadd, &.{ root, v });
    }
    self.out.display_root = root;
}

/// The end-of-block half of `queueDisplay`: lower what was deferred, mint each
/// call, fill its `displays` placeholder. Runs at the top of `finishDisplays`,
/// with `self.cur` past the last statement and past `lowerModule`'s final
/// accumulator reads — so a `flowAccum` read here is the §5.6.1.3 end-of-cycle
/// retention state, phis and all.
fn lowerDeferredDisplays(self: *Lower) Oom!void {
    for (self.systask_state.deferred_displays.items) |dd| {
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
