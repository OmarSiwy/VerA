//! AST -> bytecode for the digital engine.
//!
//! In: one process body, or one driver's expression, in the instance scope it
//! was written in. Out: `Instruction` rows appended to `Run.code`, the natural
//! type of every expression in `Run.types`, and the static slot lists that
//! drivers and `@*` wait on — or E1100 before any process has run.
//!
//! Clauses: expression typing per IEEE1364-2005 §5.5.1 Table 5-22 and §5.1.14
//! concatenation; A.6.5 statements, §8.5.3.3/§8.5.3.4 intra-assignment timing,
//! §9.7.1 delays, §9.7.5 `@*`, §5.10.4 named events, §6.1 continuous
//! assignment operands; §17.7 clock queries and §9.14 Table 9-11 `$clog2`.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const expectRejected = @import("root.zig").expectRejected;
const filled = @import("net.zig").filled;
const tasks = display.tasks;

// ---- the bytecode and its tables (A.6.5, §9.14 Table 9-11, §17.7) -----------

pub const Type = struct { width: u32, signed: bool };

// All fields in a row are consumed by one dispatch; expressions stay in the AST.
// Every statement kind is its own instruction, decided here, so `execute` is
// one switch over this union and never goes back to the statement.
pub const Instruction = union(enum(u5)) {
    // A.6.2 a blocking or nonblocking assignment with no intra-assignment
    // timing control (those are `sample`/`deposit`).
    assign: struct { target: Ast.ExprId, value: Ast.ExprId, nonblocking: bool },
    // §9.7.1 `#d stmt`: suspend for the delay, resume at the next pc.
    delay: struct { amount: Ast.ExprId, tok: u32 },
    // One §17 system task, resolved against `display.tasks` at compile time.
    task: struct { task: display.Task, args: []const Ast.ExprId, tok: u32 },
    // §6.1 one continuous assignment: evaluate, drive, resolve, then suspend
    // on its own operands. Its resumption point is its own pc.
    continuous: u32,
    branch: struct { condition: Ast.ExprId, otherwise: u32 },
    jump: u32,
    case_select: struct { statement: Ast.StmtId, targets: u32, fallback: u32, ty: Type },
    repeat_start: struct { count: Ast.ExprId, counter: u32, end: u32 },
    repeat_next: struct { counter: u32, body: u32 },
    // §5.10.1 suspend until one watched variable takes a matching edge.
    wait_event: Ast.ExprId,
    // A.6.5 `@*`. §9.7.5's implicit list is derived from the body and is
    // STATIC, so it is resolved to slots once at compile time; a resumption is
    // then the same `.any` waiter an explicit `@(a or b)` installs.
    wait_slots: []const u32,
    // A.6.5 `wait_statement`, which is LEVEL sensitive: the condition is tested
    // on arrival and again on every resumption, and only a true reading falls
    // through. `slots` is the same operand list `@*` uses, here only to decide
    // when it is worth re-testing.
    wait_level: struct { cond: Ast.ExprId, slots: []const u32 },
    // §8.5.3.3 the two halves of A.6.2's intra-assignment timing control.
    // `sample` evaluates the right-hand side with the values current when the
    // statement is REACHED and parks it in `cell`, then applies the timing;
    // `deposit` resolves the target and writes the parked value when the
    // process resumes ("the values at the time the process resumes are used to
    // determine the target(s)"). A nonblocking one emits no `deposit`: it
    // schedules the write from `sample` and does not suspend.
    sample: struct { statement: Ast.StmtId, cell: u32 },
    deposit: struct { statement: Ast.StmtId, cell: u32 },
    // A.6.5 `-> named_event`. §5.10: events "have no time duration" and "do not
    // hold any data", so this publishes NOTHING — it only resumes whoever is
    // waiting on the slot right now. A trigger nobody is waiting for is gone.
    trigger: u32,
    // §9.9.2 an `always` body returning to its own start.
    restart: struct { target: u32, tok: u32 },
    // A.6.5 `disable_statement ::= disable hierarchical_block_identifier ;`.
    // A named block is a contiguous pc range and that range IS its activity, so
    // terminating the block is dropping whatever resumption points into it.
    // Resolved to a range after every process is compiled, because a `disable`
    // may name a block written later in the file.
    disable_block: struct { start: u32, end: u32 },
    stop,
};

/// §9.14 Table 9-11's integral system functions, the two of IEEE 1364 §17.7
/// that read the clock, and §4.2.1.4's `$signed`/`$unsigned` casts: every
/// system function an integral expression may call. `infer` resolves each
/// call once into `Run.sys_calls`; separate from `tasks` because these are
/// EXPRESSIONS.
pub const SysFn = enum {
    /// §17.7.1, 64 bits: "the time unit of the module that invoked it".
    time,
    /// §17.7.1's 32-bit half, "the low order 32 bits of the current
    /// simulation time".
    stime,
    /// §9.14 Table 9-11 / IEEE 1364 §17.11: ceiling of log base 2.
    clog2,
    make_signed,
    make_unsigned,

    /// Does this read the simulation clock? Such a call is not a constant
    /// expression however constant its arguments are, which a replication
    /// count and a case label both depend on.
    fn readsClock(self: SysFn) bool {
        return switch (self) {
            .time, .stime => true,
            .clog2, .make_signed, .make_unsigned => false,
        };
    }
};

const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },
    .{ "$stime", .stime },
    .{ "$clog2", .clog2 },
    .{ "$signed", .make_signed },
    .{ "$unsigned", .make_unsigned },
});

// ---- expression typing (§5.5.1 Table 5-22, §5.1.14) -------------------------

fn leafType(self: *Run, e: Ast.ExprId) Error!Type {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident, .hier_ident => blk: {
            const at = try self.scalarSlot(e);
            // §5.10: events "do not hold any data", so a named event has no
            // value an expression could read.
            if (self.events.contains(at)) return self.exprFail(e, "§5.10: a named event holds no data; it can only be triggered and waited on");
            const v = self.values[at];
            break :blk .{ .width = v.width, .signed = v.signed };
        },
        .int_literal => blk: {
            const n = ex.intLiteral(e);
            if (n.width == 0 and (if (n.signed) n.value < std.math.minInt(i32) or n.value > std.math.maxInt(i32) else n.value < 0 or n.value > std.math.maxInt(u32)))
                return self.exprFail(e, "unsized constants outside the implemented 32-bit integer width are not supported; use an explicit size");
            break :blk .{ .width = if (n.width == 0) 32 else n.width, .signed = n.signed };
        },
        .logic_literal => blk: {
            const n = ex.logicValue(e);
            if (!n.sized) return self.exprFail(e, "unsized four-state literal context fill is not implemented; use an explicit size");
            break :blk .{ .width = n.width, .signed = n.signed };
        },
        else => self.exprFail(e, "this expression requires digital context typing beyond the implemented leaf operands"),
    };
}

pub fn common(a: Type, b: Type) Type {
    return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
}

pub fn typeOf(self: *Run, e: Ast.ExprId) Type {
    const ty = self.types[@intFromEnum(e)];
    std.debug.assert(ty.width != 0 or self.replications.contains(e)); // zero only for validated replication
    return ty;
}

pub fn checkExpr(self: *Run, e: Ast.ExprId) Error!void {
    _ = try inferValue(self, e, 0);
}

fn inferValue(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
    const ty = try infer(self, e, depth);
    if (ty.width == 0) return self.exprFail(e, "zero replication requires an immediately enclosing concatenation with a positive-width operand");
    return ty;
}

fn constantExpression(self: *Run, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal => return true,
        .unary, .binary, .multi_concat, .ternary, .concat => {},
        // §17.7: a call that reads the clock is never constant, however
        // constant its (absent) arguments are. Without this `$time`
        // would be accepted as a replication count.
        .sys_call => if (sys_fns.get(self.file.str(ex.strOf(e)))) |f| {
            if (f.readsClock()) return false;
        },
        else => return false, // else: not a form this executor folds
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (!constantExpression(self, c)) return false;
    return true;
}

// Bare unsized numbers are prohibited by §5.1.14. Its application to
// arithmetic expressions is disputed; retain an explicit unsupported
// boundary until qualified, stopping at self-determined expression results.
fn unsizedConcatOperand(self: *Run, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).width == 0,
        .logic_literal => !ex.logicValue(e).sized,
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => unsizedConcatOperand(self, ex.lhs(e)),
            else => false,
        },
        .binary => switch (ex.binOp(e)) {
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => unsizedConcatOperand(self, ex.lhs(e)) or unsizedConcatOperand(self, ex.rhs(e)),
            .shl, .shr, .ashl, .ashr, .pow => unsizedConcatOperand(self, ex.lhs(e)),
            else => false,
        },
        .ternary => unsizedConcatOperand(self, ex.rhs(e)) or unsizedConcatOperand(self, ex.ternaryElse(e)),
        else => false,
    };
}

fn replicationCount(self: *Run, e: Ast.ExprId) Error!u32 {
    if (!constantExpression(self, e)) return self.exprFail(e, "integral replication requires a constant expression");
    var scratch = std.heap.ArenaAllocator.init(self.arena);
    defer scratch.deinit();
    const value = try exec.eval(self, scratch.allocator(), e, 0);
    if (value.hasUnknown()) return self.exprFail(e, "replication count cannot contain X or Z");
    if (value.signed and value.bit(value.width - 1) == .one) return self.exprFail(e, "replication count cannot be negative");
    for (value.values()[1..]) |word| if (word != 0) return self.exprFail(e, "replication count exceeds the supported u32 range");
    if (value.values()[0] > std.math.maxInt(u32)) return self.exprFail(e, "replication count exceeds the supported u32 range");
    return @intCast(value.values()[0]);
}

// IEEE1364-2005 Table 5-22, §5.5.1: infer natural size/type bottom-up.
// ponytail: recursive evaluation is bounded to 256 AST levels; an explicit
// stack can remove this ceiling when deeper expressions are needed.
fn infer(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
    if (e == .none) return self.fail(0, "omitted expressions are not implemented", .{});
    if (depth == 256) return self.exprFail(e, "digital expressions deeper than 256 AST levels are not implemented");
    const entry = &self.types[@intFromEnum(e)];
    if (entry.width != 0 or self.replications.contains(e)) return entry.*;
    const ex = &self.file.exprs;
    const ty: Type = switch (ex.tag(e)) {
        .int_literal, .logic_literal, .ident, .hier_ident => try leafType(self, e),
        // §3.9 an array element has the element's declared type; the index
        // is self-determined and never widens the result.
        .index => blk: {
            if (try self.indexedArray(e) == null) return self.exprFail(e, "bit and part selects are not implemented; only unpacked array elements are indexed");
            const index = try inferValue(self, ex.rhs(e), depth + 1);
            if (index.width > 64) return self.exprFail(ex.rhs(e), "array indices wider than 64 bits are not implemented");
            const v = self.values[try self.slot(ex.lhs(e))];
            break :blk .{ .width = v.width, .signed = v.signed };
        },
        .unary => blk: {
            const operand = try inferValue(self, ex.lhs(e), depth + 1);
            break :blk switch (ex.unOp(e)) {
                .plus, .minus, .bit_not => operand,
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .width = 1, .signed = false },
            };
        },
        .binary => blk: {
            const lhs = try inferValue(self, ex.lhs(e), depth + 1);
            const rhs = try inferValue(self, ex.rhs(e), depth + 1);
            break :blk switch (ex.binOp(e)) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => common(lhs, rhs),
                .shl, .shr, .ashl, .ashr, .pow => lhs,
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .width = 1, .signed = false },
            };
        },
        .ternary => blk: {
            _ = try inferValue(self, ex.lhs(e), depth + 1);
            const yes = try inferValue(self, ex.rhs(e), depth + 1);
            const no = try inferValue(self, ex.ternaryElse(e), depth + 1);
            break :blk common(yes, no);
        },
        .sys_call => blk: {
            const f = sys_fns.get(self.file.str(ex.strOf(e))) orelse
                return self.exprFail(e, "this digital expression form is not implemented");
            self.sys_calls[@intFromEnum(e)] = f;
            const args = ex.args(e);
            switch (f) {
                    // §17.7.1 gives `$time` the 64-bit `time` type and
                    // `$stime` its low 32 bits. Both unsigned: simulation
                    // time has no negative half.
                    .time, .stime => {
                        if (args.len != 0) return self.exprFail(e, "$time and $stime take no arguments");
                        if (self.scale == null) return self.exprFail(e, "the time queries require an explicit valid timescale before the module");
                        break :blk .{ .width = if (f == .time) 64 else 32, .signed = false };
                    },
                    // §17.11's result is an `integer`, which §3.2 makes a
                    // 32-bit SIGNED type — so `$clog2(x) - 1` at x = 0 is
                    // -1 and not 4294967295.
                    .clog2 => {
                        if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$clog2 takes exactly one argument");
                        _ = try inferValue(self, args[0], depth + 1);
                        break :blk .{ .width = 32, .signed = true };
                    },
                    .make_signed, .make_unsigned => {
                        if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                        const operand = try inferValue(self, args[0], depth + 1);
                        break :blk .{ .width = operand.width, .signed = f == .make_signed };
                    },
            }
        },
        .concat => blk: {
            var width: u32 = 0;
            for (ex.args(e)) |arg| {
                const operand = try infer(self, arg, depth + 1);
                if (unsizedConcatOperand(self, arg)) {
                    if (ex.tag(arg) == .int_literal or ex.tag(arg) == .logic_literal)
                        return self.exprFail(arg, "unsized constant numbers are not allowed as concatenation operands");
                    return self.exprFail(arg, "concatenation operands with unsized arithmetic are not implemented");
                }
                width = std.math.add(u32, width, operand.width) catch return self.exprFail(e, "concatenation width exceeds the supported u32 range");
            }
            if (width == 0) return self.exprFail(e, "a concatenation requires a positive-width operand; zero-only and empty concatenations are invalid");
            break :blk .{ .width = width, .signed = false };
        },
        .multi_concat => blk: {
            _ = try inferValue(self, ex.lhs(e), depth + 1);
            const operand = try inferValue(self, ex.rhs(e), depth + 1);
            const count = try replicationCount(self, ex.lhs(e));
            const width = std.math.mul(u32, count, operand.width) catch return self.exprFail(e, "replication width exceeds the supported u32 range");
            try self.replications.put(self.arena, e, count);
            break :blk .{ .width = width, .signed = false };
        },
        else => return self.exprFail(e, "this digital expression form is not implemented"),
    };
    entry.* = ty;
    return ty;
}

// ---- statements -> bytecode (A.6.5, §8.5.3.3, §9.7.5) -----------------------

fn position(self: *Run) u32 {
    return @intCast(self.code.items.len);
}

pub fn append(self: *Run, instruction: Instruction) Error!u32 {
    if (self.code.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital instructions", .{});
    const at = position(self);
    try self.code.append(self.arena, instruction);
    try self.code_scope.append(self.arena, self.scope);
    return at;
}

pub fn compileStmt(self: *Run, id: Ast.StmtId, depth: u16) Error!void {
    const tok = self.file.stmtTok(id);
    if (depth == 256) return self.fail(tok, "digital statements deeper than 256 AST levels are not implemented", .{});
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| {
            // §5.3.2's block-local declarations are a SCOPE, which the flat
            // `Name` space has no room for; the name on its own is not, and
            // that is all `disable` needs.
            if (b.vars.len != 0 or b.params.len != 0) return self.fail(tok, "block-local declarations are not implemented", .{});
            const start = position(self);
            for (b.body) |s| try compileStmt(self, s, depth + 1);
            if (b.name != .none) {
                const entry = try self.blocks.getOrPut(self.arena, .{ .scope = self.scope, .str = b.name });
                if (entry.found_existing) return self.fail(tok, "duplicate named block", .{});
                // `end` is one past the block, which is the statement
                // execution continues with once the block is terminated.
                entry.value_ptr.* = .{ .start = start, .end = position(self) };
            }
        },
        // A.6.5 `disable_statement`. The range is patched in once every
        // process exists — see `Run.disables`.
        .disable => |s| {
            const at = try append(self, .{ .disable_block = .{ .start = 0, .end = 0 } });
            try self.disables.append(self.arena, .{ .at = at, .name = .{ .scope = self.scope, .str = s.name }, .tok = tok });
        },
        .if_stmt => |s| {
            if (s.is_generate) return self.fail(tok, "conditional generate is not implemented", .{});
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.then_s, depth + 1);
            if (s.else_s == .none) {
                self.code.items[test_pc].branch.otherwise = position(self);
            } else {
                const end_pc = try append(self, .{ .jump = 0 });
                self.code.items[test_pc].branch.otherwise = position(self);
                try compileStmt(self, s.else_s, depth + 1);
                self.code.items[end_pc].jump = position(self);
            }
        },
        .while_stmt => |s| {
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.body, depth + 1);
            _ = try append(self, .{ .jump = test_pc });
            self.code.items[test_pc].branch.otherwise = position(self);
        },
        .for_stmt => |s| {
            try compileStmt(self, s.init, depth + 1);
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.body, depth + 1);
            try compileStmt(self, s.step, depth + 1);
            _ = try append(self, .{ .jump = test_pc });
            self.code.items[test_pc].branch.otherwise = position(self);
        },
        .repeat_stmt => |s| {
            try checkExpr(self, s.count);
            if (typeOf(self, s.count).width > 64) return self.exprFail(s.count, "repeat counts wider than 64 bits are not implemented");
            if (self.repeats.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many repeat counters", .{});
            const counter: u32 = @intCast(self.repeats.items.len);
            try self.repeats.append(self.arena, 0);
            const test_pc = try append(self, .{ .repeat_start = .{ .count = s.count, .counter = counter, .end = 0 } });
            const body_pc = position(self);
            try compileStmt(self, s.body, depth + 1);
            _ = try append(self, .{ .repeat_next = .{ .counter = counter, .body = body_pc } });
            self.code.items[test_pc].repeat_start.end = position(self);
        },
        .case_stmt => |s| {
            if (s.is_generate) return self.fail(tok, "case generate is not implemented", .{});
            if (s.arms.len == 0) return self.fail(tok, "a case statement requires at least one item", .{});
            try checkExpr(self, s.scrutinee);
            var ty = typeOf(self, s.scrutinee);
            var have_default = false;
            for (s.arms) |arm| {
                if (arm.labels.len == 0) {
                    if (have_default) return self.fail(tok, "a case statement cannot have multiple default items", .{});
                    have_default = true;
                }
                for (arm.labels) |label| {
                    try checkExpr(self, label);
                    ty = common(ty, typeOf(self, label));
                }
            }
            if (s.arms.len > std.math.maxInt(u32) - self.case_targets.items.len) return self.fail(tok, "too many case targets", .{});
            const targets: u32 = @intCast(self.case_targets.items.len);
            try self.case_targets.appendNTimes(self.arena, 0, s.arms.len);
            const dispatch = try append(self, .{ .case_select = .{ .statement = id, .targets = targets, .fallback = 0, .ty = ty } });
            const exits = try self.arena.alloc(u32, s.arms.len);
            for (s.arms, 0..) |arm, i| {
                self.case_targets.items[targets + i] = position(self);
                if (arm.labels.len == 0) self.code.items[dispatch].case_select.fallback = position(self);
                try compileStmt(self, arm.body, depth + 1);
                exits[i] = try append(self, .{ .jump = 0 });
            }
            const end = position(self);
            if (!have_default) self.code.items[dispatch].case_select.fallback = end;
            for (exits) |at| self.code.items[at].jump = end;
        },
        .assign => |s| {
            try checkTarget(self, s.target);
            try checkExpr(self, s.value);
            if (s.timing == .none) {
                _ = try append(self, .{ .assign = .{ .target = s.target, .value = s.value, .nonblocking = s.nonblocking } });
                return;
            }
            // A.6.2's intra-assignment `delay_or_event_control`, §8.5.3.3.
            if (s.timing_is_delay) try checkDelay(self, s.timing, tok) else {
                // ponytail: no `<= @(e) rhs`. §8.5.3.4's nonblocking form
                // does not suspend, so the parked value would have to be
                // held by the WAITER rather than by a per-site cell; give
                // `Waiter` a payload when something needs it.
                if (s.nonblocking) return self.fail(tok, "an event control inside a nonblocking assignment is not implemented", .{});
                try checkEvent(self, s.timing);
            }
            if (self.holds.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many intra-assignment timing controls", .{});
            const cell: u32 = @intCast(self.holds.items.len);
            try self.holds.append(self.arena, try filled(self.arena, 1, false, .x));
            _ = try append(self, .{ .sample = .{ .statement = id, .cell = cell } });
            // §8.5.3.4: a nonblocking one does not suspend the process — it
            // schedules the update and falls through — so it has no
            // resumption point and needs no `deposit`.
            if (!s.nonblocking) _ = try append(self, .{ .deposit = .{ .statement = id, .cell = cell } });
        },
        // A.6.5 `event_trigger`. The slot is resolved here, not at run
        // time, so a trigger cannot fail in the middle of a dispatch.
        .event_trigger => |s| {
            const at = self.names.get(.{ .scope = self.scope, .str = s.name }) orelse
                return self.fail(tok, "undeclared named event", .{});
            if (!self.events.contains(at)) return self.fail(tok, "§5.10.4: `->` triggers a named event, not a variable or net", .{});
            _ = try append(self, .{ .trigger = at });
        },
        .event_control => |s| {
            // A.6.5 `@*`. The terms come from the body, so the body has to
            // be type-checked before they can be read off it: emit the wait
            // with an empty list, compile the body, then patch the list in.
            if (s.event == .none) {
                const at = try append(self, .{ .wait_slots = &.{} });
                try compileStmt(self, s.body, depth + 1);
                var watched: std.ArrayList(u32) = .empty;
                try readSlots(self, s.body, &watched, depth);
                // §9.7.5's list is what the statement READS. A statement
                // that reads nothing would suspend forever, which is never
                // what `@*` was written to mean.
                if (watched.items.len == 0) return self.fail(tok, "§9.7.5: `@*` needs the statement to read at least one net or variable", .{});
                self.code.items[at].wait_slots = watched.items;
                return;
            }
            switch (s.kind) {
                .event => {
                    try checkEvent(self, s.event);
                    _ = try append(self, .{ .wait_event = s.event });
                },
                .delay => {
                    try checkDelay(self, s.event, tok);
                    _ = try append(self, .{ .delay = .{ .amount = s.event, .tok = tok } });
                },
                // A.6.5 `wait_statement`. The condition's operands ARE the
                // wake-up list, but unlike `@` they only bring the process
                // back to the same pc to re-test the level.
                .level => {
                    try checkExpr(self, s.event);
                    var watched: std.ArrayList(u32) = .empty;
                    try sensitivity(self, s.event, &watched);
                    // IEEE 1364-2005 9.7.6 tests the current level first.
                    // An empty dependency list is legal: true continues;
                    // false suspends without registering any future wakeup.
                    _ = try append(self, .{ .wait_level = .{ .cond = s.event, .slots = watched.items } });
                },
            }
            try compileStmt(self, s.body, depth + 1);
        },
        .sys_task => |s| {
            const name = self.file.str(s.name);
            const task = tasks.get(name) orelse return self.fail(tok, "digital system task `{s}` is not implemented", .{name});
            switch (task) {
                // All three format the same surface, so all three are
                // validated by the same dry run.
                .show, .strobe, .monitor => |sh| try display.display(self, s.args, null, sh),
                .monitor_enable => if (s.args.len != 0)
                    return self.fail(tok, "$monitoron and $monitoroff take no arguments", .{}),
                .timeformat => {
                    // §17.3's four arguments are simulator SETTINGS, read
                    // once when the task runs; a source that computed them
                    // from a net would be asking the format to track a
                    // value, which the clause does not define.
                    const ex = &self.file.exprs;
                    if (s.args.len != 4) return self.fail(tok, "$timeformat takes exactly four arguments", .{});
                    for (s.args[0..2]) |a| if (a == .none or !constantExpression(self, a))
                        return self.exprFail(a, "$timeformat's units and precision must be constant");
                    if (s.args[2] == .none or ex.tag(s.args[2]) != .str_literal)
                        return self.exprFail(s.args[2], "$timeformat's suffix must be a string literal");
                    if (s.args[3] == .none or !constantExpression(self, s.args[3]))
                        return self.exprFail(s.args[3], "$timeformat's minimum width must be constant");
                    for (s.args[0..2]) |a| try checkExpr(self, a);
                    try checkExpr(self, s.args[3]);
                },
                .readmem => {
                    const ex = &self.file.exprs;
                    if (s.args.len < 2 or s.args.len > 4)
                        return self.fail(tok, "$readmemb/$readmemh take (file, memory [, start [, finish]])", .{});
                    if (s.args[0] == .none or ex.tag(s.args[0]) != .str_literal)
                        return self.exprFail(s.args[0], "the memory file name must be a string literal");
                    if (s.args[1] == .none or ex.tag(s.args[1]) != .ident or !self.arrays.contains(try self.slot(s.args[1])))
                        return self.exprFail(s.args[1], "$readmemb/$readmemh load an unpacked array");
                    for (s.args[2..]) |a| {
                        if (a == .none or !constantExpression(self, a))
                            return self.exprFail(a, "the $readmem address bounds must be constant");
                        try checkExpr(self, a);
                    }
                },
                .finish => {
                    if (s.args.len > 1) return self.fail(tok, "$finish accepts zero or one argument", .{});
                    if (s.args.len == 1) {
                        const ex = &self.file.exprs;
                        if (ex.tag(s.args[0]) != .int_literal or ex.intValue(s.args[0]) < 0 or ex.intValue(s.args[0]) > 1)
                            return self.fail(tok, "only $finish(0), $finish(1), and $finish are implemented", .{});
                    }
                },
            }
            _ = try append(self, .{ .task = .{ .task = task, .args = s.args, .tok = tok } });
        },
        else => return self.fail(tok, "this digital statement is not implemented", .{}),
    }
}

// ---- static sensitivity and target checks (§6.1, §9.7.5, §9.7.1) ------------

/// §6.1 "a continuous assignment is evaluated whenever an operand changes".
/// The operands are the slots its expression reads; they resolve at compile
/// time, like an event term, so a resumption cannot fail mid-dispatch.
///
/// ponytail: an array element operand watches EVERY element of that array,
/// because the element a dynamic index names is not known until it is read.
/// A per-array wake list would replace that if a big memory ever feeds one.
pub fn sensitivity(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!void {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal => {},
        .ident, .hier_ident => try watch(self, try self.slot(e), out),
        .index => {
            const base = try self.slot(ex.lhs(e));
            const arr = self.arrays.get(base).?; // infer proved this is an array
            for (0..arr.count) |i| try watch(self, base + @as(u32, @intCast(i)), out);
            try sensitivity(self, ex.rhs(e), out);
        },
        .unary, .binary, .multi_concat, .ternary, .sys_call, .concat => {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try sensitivity(self, c, out);
        },
        else => unreachable, // else: checkExpr admitted only the forms above
    }
}

/// §9.7.5's implicit event expression: every net and variable the statement
/// READS. The identifier on the left of an assignment is written, not read,
/// so it contributes nothing — but an index into it is read, which is why
/// the target is walked for its subscript and not for its base.
///
/// Runs only after `compileStmt` accepted the same statement, so every form
/// reachable here is one of the forms below and every expression in it is
/// already type-checked.
fn readSlots(self: *Run, id: Ast.StmtId, out: *std.ArrayList(u32), depth: u16) Error!void {
    if (id == .none) return;
    if (depth == 256) return self.fail(self.file.stmtTok(id), "digital statements deeper than 256 AST levels are not implemented", .{});
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try readSlots(self, s, out, depth + 1),
        .if_stmt => |s| {
            try sensitivity(self, s.cond, out);
            try readSlots(self, s.then_s, out, depth + 1);
            try readSlots(self, s.else_s, out, depth + 1);
        },
        .while_stmt => |s| {
            try sensitivity(self, s.cond, out);
            try readSlots(self, s.body, out, depth + 1);
        },
        .for_stmt => |s| {
            try sensitivity(self, s.cond, out);
            for ([_]Ast.StmtId{ s.init, s.body, s.step }) |part| try readSlots(self, part, out, depth + 1);
        },
        .repeat_stmt => |s| {
            try sensitivity(self, s.count, out);
            try readSlots(self, s.body, out, depth + 1);
        },
        .case_stmt => |s| {
            try sensitivity(self, s.scrutinee, out);
            for (s.arms) |arm| {
                for (arm.labels) |label| try sensitivity(self, label, out);
                try readSlots(self, arm.body, out, depth + 1);
            }
        },
        .assign => |s| {
            try sensitivity(self, s.value, out);
            // An element lvalue reads its subscript; `sensitivity` on the
            // whole `.index` would also add the array's own elements.
            if (ex.tag(s.target) == .index) try sensitivity(self, ex.rhs(s.target), out);
        },
        .sys_task => |s| for (s.args) |a| {
            if (a != .none and ex.tag(a) != .str_literal) try sensitivity(self, a, out);
        },
        // A trigger reads nothing, a `disable` reads nothing, an empty
        // statement reads nothing, and a nested `@`/`#` inside `@*`
        // suspends on its own terms — §9.7.5 takes the implicit list from
        // the statement's reads either way.
        .empty, .event_trigger, .disable => {},
        .event_control => |s| try readSlots(self, s.body, out, depth + 1),
        else => unreachable, // compileStmt admitted only the forms above
    }
}

fn watch(self: *Run, at: u32, out: *std.ArrayList(u32)) Error!void {
    for (out.items) |seen| if (seen == at) return;
    try out.append(self.arena, at);
}

/// §6.2.2/§6.1: a net is driven by a continuous assignment and a variable by
/// a procedural one; neither accepts the other's form.
fn checkTarget(self: *Run, e: Ast.ExprId) Error!void {
    const ex = &self.file.exprs;
    if (try self.indexedArray(e) != null) {
        try checkExpr(self, ex.rhs(e));
        if (typeOf(self, ex.rhs(e)).width > 64) return self.exprFail(ex.rhs(e), "array indices wider than 64 bits are not implemented");
        return;
    }
    if (self.net_of.contains(try self.scalarSlot(e)))
        return self.exprFail(e, "a net is driven by a continuous assignment; there is no procedural assignment to a net");
}

/// §9.7.1 a delay is a "delay_value", and A.8.3 makes that
/// `unsigned_number | real_number | ...` — so `#0.5` is as ordinary as
/// `#1`. A real literal is left untyped here and rounded to the module's
/// PRECISION at run time (`Scale.realDelay`) rather than truncated to its
/// unit, which is the only thing that makes a sub-unit delay mean anything.
fn checkDelay(self: *Run, e: Ast.ExprId, tok: u32) Error!void {
    if (self.scale == null) return self.fail(tok, "digital delays require an explicit valid timescale before the module", .{});
    if (self.file.exprs.tag(e) == .real_literal) return;
    try checkExpr(self, e);
    if (typeOf(self, e).width > 64) return self.exprFail(e, "delay values wider than 64 bits are not implemented");
}

/// Event terms resolve to watched slots at compile time, so a resumption
/// never has to fail in the middle of a dispatch.
fn checkEvent(self: *Run, e: Ast.ExprId) Error!void {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .event_or => {
            try checkEvent(self, ex.lhs(e));
            try checkEvent(self, ex.rhs(e));
        },
        .event_posedge, .event_negedge => _ = try self.scalarSlot(ex.lhs(e)),
        .ident => _ = try self.scalarSlot(e),
        else => return self.exprFail(e, "only variable and posedge/negedge event terms are implemented"),
    }
}

// ---- tests ------------------------------------------------------------------

test "an array element operand wakes a continuous assignment" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [3:0] mem [0:1];
        \\integer i;
        \\wire [3:0] w;
        \\assign w = mem[i];
        \\initial begin
        \\  i = 0; mem[0] = 4'h1; mem[1] = 4'h2;
        \\  #1 $display("%b", w);
        \\  i = 1;
        \\  #1 $display("%b", w);
        \\  mem[1] = 4'h7;
        \\  #1 $display("%b", w);
        \\  $finish(0);
        \\end
        \\endmodule
    , "0001\n0010\n0111\n");
}

test "unsupported source is rejected before any process side effect" {
    try expectRejected("module m; initial $display(\"before\"); initial forever ; endmodule", "error");
    try expectRejected("module m; tran(a,b); initial $display(\"before\"); endmodule", "switch primitives");
    try expectRejected("module m; initial $display(\"%b\",2147483648); endmodule", "unsized constants");
    try expectRejected("module m; initial $display(\"%b\",'hx); endmodule", "unsized four-state");
    try expectRejected("module m; reg c; always begin c = 1; end endmodule", "without suspending");
    try expectRejected("module m; reg c; initial @(c[0]) c = 1; endmodule", "event terms are implemented");
    // §5.10 "events do not hold any data", so neither direction of the
    // event/variable confusion compiles.
    try expectRejected("module m; event e; initial $display(\"%b\", e); endmodule", "holds no data");
    try expectRejected("module m; reg c; initial -> c; endmodule", "triggers a named event");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=(a+1)+$bogus(1); end endmodule", "expression form");
    try expectRejected("module m; reg [3:0] a; initial a[0]=1; endmodule", "whole-variable");
    try expectRejected("module m; initial $finish(2); endmodule", "only $finish");
    // The conversions that ARE implemented are §9.4.3 Table 9-22's; `%s` and
    // `%c` are not, and the refusal names the table rather than one letter.
    try expectRejected("module m; initial $display(\"%s\",1); endmodule", "Table 9-22");
    // §17.7: a real conversion needs a real, and `$realtime` is the only one.
    try expectRejected("`timescale 1ns/1ns\nmodule m; reg a; initial $display(\"%g\",a); endmodule", "only one implemented");
    try expectRejected("module m; reg a; initial a=1; integer a; endmodule", "duplicate digital");
}

test "nested unsupported forms fail preflight even in unselected conditional arms" {
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b1 ? 1'b0 : $bogus(1); end endmodule", "expression form");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b0 && $bogus(1); end endmodule", "expression form");
}

test "deep left-associated source expression fails before output" {
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("module m; reg a; initial begin $display(\"before\"); a=0");
    for (0..256) |_| try source.writer.writeAll("+0");
    try source.writer.writeAll("; end endmodule");
    try expectRejected(source.written(), "deeper than 256 AST levels");
}

test "control flow validates unselected bodies and every case label" {
    try expectRejected("module m; initial begin $display(\"before\"); if(0) $bogustask(\"BAD\"); end endmodule", "system task");
    try expectRejected("module m; initial begin $display(\"before\"); case(1) 1:; $bogus(2):; endcase end endmodule", "expression form");
    try expectRejected("module m; initial begin $display(\"before\"); while(0) @(a); end endmodule", "undeclared digital variable");
    try expectRejected("module m; initial case(1) default:; default:; endcase endmodule", "multiple default");
    try expectRejected("module m; initial case(1) endcase endmodule", "at least one item");
    try expectRejected("module m; initial repeat(65'd1); endmodule", "wider than 64");
    try expectRejected("module m; initial repeat(-1); endmodule", "negative repeat counts");
}

test "statement depth is explicit and diagnosed before execution" {
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("module m; initial $display(\"before\"); initial ");
    for (0..256) |_| try source.writer.writeAll("if(1) ");
    try source.writer.writeAll("; endmodule");
    try expectRejected(source.written(), "statements deeper than 256");
}

test "concatenation validates zero replication structure and constant counts" {
    try expectRejected("module m; initial $display(\"%b\",{0{1'b1}}); endmodule", "immediately enclosing concatenation");
    try expectRejected("module m; initial $display(\"%b\",{{{0{1'b1}}},1'b1}); endmodule", "positive-width operand");
    try expectRejected("module m; initial $display(\"%b\",{}); endmodule", "positive-width operand");
    try expectRejected("module m; initial $display(\"%b\",{{0{$bogus(1)}},1'b1}); endmodule", "expression form");
    try expectRejected("module m; integer n; initial begin $display(\"before\"); $display(\"%b\",{n{1'b1}}); end endmodule", "constant expression");
    try expectRejected("module m; initial $display(\"%b\",{-1{1'b1}}); endmodule", "cannot be negative");
    try expectRejected("module m; initial $display(\"%b\",{1'bx{1'b1}}); endmodule", "cannot contain X or Z");
    try expectRejected("module m; initial $display(\"%b\",{1'bz{1'b1}}); endmodule", "cannot contain X or Z");
    try expectRejected("module m; initial $display(\"%b\",{65'h10000000000000000{1'b1}}); endmodule", "count exceeds");
    try expectRejected("module m; initial $display(\"%b\",{32'h80000000{2'b1}}); endmodule", "width exceeds");
}

test "concat unsized boundary and cast arity are explicit" {
    try expectRejected("module m; initial $display(\"%b\",{1'b1,3}); endmodule", "unsized constant numbers");
    try expectRejected("module m; initial $display(\"%b\",{1+2,1'b1}); endmodule", "unsized arithmetic");
    try expectRejected("module m; initial $display(\"%b\",{8'd1+1,1'b1}); endmodule", "unsized arithmetic");
    try expectRejected("module m; initial $display(\"%b\",$signed()); endmodule", "exactly one integral argument");
    try expectRejected("module m; initial $display(\"%b\",$unsigned(1,2)); endmodule", "exactly one integral argument");
    try expectRejected("module m; initial $display(\"%b\",$signed(1.0)); endmodule", "expression form");
}
