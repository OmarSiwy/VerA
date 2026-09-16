//! Shared frontend -> finite initial-process execution. IEEE1364-2005 §§9,11.
//! This deliberately rejects unsupported source forms before executing a task.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const diag = @import("diag");
const Scheduler = @import("scheduler.zig").Scheduler;
const Time = @import("time.zig");

pub const Error = error{DigitalFailed} || std.mem.Allocator.Error || std.Io.Writer.Error;
pub const Options = struct {
    file_name: []const u8 = "<digital>",
    include_dirs: []const []const u8 = &.{},
};

// Each dispatch consumes all fields of one pending write. NBA snapshots own
// their planes in the run arena, never point into mutable variable storage.
const Pending = union(enum) { run_process: u32, write: struct { target: u32, value: Int.Literal } };
const Type = struct { width: u32, signed: bool };
// All fields in a row are consumed by one dispatch; expressions stay in the AST.
const Instruction = union(enum(u4)) {
    statement: Ast.StmtId,
    branch: struct { condition: Ast.ExprId, otherwise: u32 },
    jump: u32,
    case_select: struct { statement: Ast.StmtId, targets: u32, fallback: u32, ty: Type },
    repeat_start: struct { count: Ast.ExprId, counter: u32, end: u32 },
    repeat_next: struct { counter: u32, body: u32 },
    // §5.10.1 suspend until one watched variable takes a matching edge.
    wait_event: Ast.ExprId,
    // §9.9.2 an `always` body returning to its own start.
    restart: struct { target: u32, tok: u32 },
    stop,
};
// §5.10.1: an edge is a change toward 1 (posedge) or away from 1 (negedge),
// with x and z as the intermediate value on either side of the transition.
const Edge = enum(u2) {
    any,
    posedge,
    negedge,
    fn matches(self: Edge, before: Int.Bit, after: Int.Bit) bool {
        // A plain `@(v)` term watches the whole value, which the caller has
        // already proved changed; the other two read the LSB the table covers.
        if (self == .any) return true;
        if (before == after) return false;
        return switch (self) {
            .posedge => before == .zero or after == .one,
            .negedge => before == .one or after == .zero,
            .any => unreachable,
        };
    }
};
// One suspended process, keyed by the variable it watches. `pc` is both the
// resumption point and the process's identity while it is suspended: the terms
// of one `or` share it, and retire together when any one of them fires.
const Waiter = struct { slot: u32, edge: Edge, pc: u32 };
const Cast = enum(u1) { make_signed, make_unsigned };
const casts = std.StaticStringMap(Cast).initComptime(.{ .{ "$signed", .make_signed }, .{ "$unsigned", .make_unsigned } });
const Task = enum(u1) { display, finish };
const tasks = std.StaticStringMap(Task).initComptime(.{ .{ "$display", .display }, .{ "$finish", .finish } });
const Run = struct {
    arena: std.mem.Allocator,
    file: *const Ast.SourceFile,
    starts: []const u32,
    bag: *diag.Bag,
    out: *std.Io.Writer,
    names: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty,
    values: []Int.Literal,
    // Natural types, indexed by AST ExprId; width zero marks an unvisited row.
    types: []Type = &.{},
    replications: std.AutoHashMapUnmanaged(Ast.ExprId, u32) = .empty,
    code: std.ArrayList(Instruction) = .empty,
    case_targets: std.ArrayList(u32) = .empty,
    // One counter per lexical repeat is sufficient without recursive processes.
    repeats: std.ArrayList(u64) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    waiters: std.ArrayList(Waiter) = .empty,
    scheduler: Scheduler,
    scale: ?Time.Scale = null,

    fn fail(self: *Run, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        const start = self.starts[@min(tok, self.starts.len - 1)];
        self.bag.add(.lower, .E1100, .{ .start = start, .end = start }, fmt, args) catch return error.OutOfMemory;
        return error.DigitalFailed;
    }
    fn exprFail(self: *Run, e: Ast.ExprId, comptime msg: []const u8) Error {
        return self.fail(self.file.exprs.mainTok(e), "{s}", .{msg});
    }
    fn slot(self: *Run, e: Ast.ExprId) Error!u32 {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .ident) return self.exprFail(e, "only whole-variable lvalues are implemented");
        return self.names.get(ex.strOf(e)) orelse self.exprFail(e, "undeclared digital variable");
    }
    fn leafType(self: *Run, e: Ast.ExprId) Error!Type {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .ident => blk: {
                const v = self.values[try self.slot(e)];
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
    fn common(a: Type, b: Type) Type {
        return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
    }
    fn typeOf(self: *Run, e: Ast.ExprId) Type {
        const ty = self.types[@intFromEnum(e)];
        std.debug.assert(ty.width != 0 or self.replications.contains(e)); // zero only for validated replication
        return ty;
    }
    fn checkExpr(self: *Run, e: Ast.ExprId) Error!void {
        _ = try self.inferValue(e, 0);
    }
    fn inferValue(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
        const ty = try self.infer(e, depth);
        if (ty.width == 0) return self.exprFail(e, "zero replication requires an immediately enclosing concatenation with a positive-width operand");
        return ty;
    }
    fn constantExpression(self: *Run, e: Ast.ExprId) bool {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .int_literal, .logic_literal => true,
            .unary => self.constantExpression(ex.lhs(e)),
            .binary, .multi_concat => self.constantExpression(ex.lhs(e)) and self.constantExpression(ex.rhs(e)),
            .ternary => self.constantExpression(ex.lhs(e)) and self.constantExpression(ex.rhs(e)) and self.constantExpression(ex.ternaryElse(e)),
            .sys_call, .concat => blk: {
                for (ex.args(e)) |arg| if (!self.constantExpression(arg)) break :blk false;
                break :blk true;
            },
            else => false,
        };
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
                .plus, .minus, .bit_not => self.unsizedConcatOperand(ex.lhs(e)),
                else => false,
            },
            .binary => switch (ex.binOp(e)) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => self.unsizedConcatOperand(ex.lhs(e)) or self.unsizedConcatOperand(ex.rhs(e)),
                .shl, .shr, .ashl, .ashr, .pow => self.unsizedConcatOperand(ex.lhs(e)),
                else => false,
            },
            .ternary => self.unsizedConcatOperand(ex.rhs(e)) or self.unsizedConcatOperand(ex.ternaryElse(e)),
            else => false,
        };
    }
    fn replicationCount(self: *Run, e: Ast.ExprId) Error!u32 {
        if (!self.constantExpression(e)) return self.exprFail(e, "integral replication requires a constant expression");
        var scratch = std.heap.ArenaAllocator.init(self.arena);
        defer scratch.deinit();
        const value = try self.eval(scratch.allocator(), e, 0);
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
            .int_literal, .logic_literal, .ident => try self.leafType(e),
            .unary => blk: {
                const operand = try self.inferValue(ex.lhs(e), depth + 1);
                break :blk switch (ex.unOp(e)) {
                    .plus, .minus, .bit_not => operand,
                    .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .width = 1, .signed = false },
                };
            },
            .binary => blk: {
                const lhs = try self.inferValue(ex.lhs(e), depth + 1);
                const rhs = try self.inferValue(ex.rhs(e), depth + 1);
                break :blk switch (ex.binOp(e)) {
                    .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => common(lhs, rhs),
                    .shl, .shr, .ashl, .ashr, .pow => lhs,
                    .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .width = 1, .signed = false },
                };
            },
            .ternary => blk: {
                _ = try self.inferValue(ex.lhs(e), depth + 1);
                const yes = try self.inferValue(ex.rhs(e), depth + 1);
                const no = try self.inferValue(ex.ternaryElse(e), depth + 1);
                break :blk common(yes, no);
            },
            .sys_call => blk: {
                const cast = casts.get(self.file.str(ex.strOf(e))) orelse return self.exprFail(e, "this digital expression form is not implemented");
                const args = ex.args(e);
                if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                const operand = try self.inferValue(args[0], depth + 1);
                break :blk .{ .width = operand.width, .signed = cast == .make_signed };
            },
            .concat => blk: {
                var width: u32 = 0;
                for (ex.args(e)) |arg| {
                    const operand = try self.infer(arg, depth + 1);
                    if (self.unsizedConcatOperand(arg)) {
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
                _ = try self.inferValue(ex.lhs(e), depth + 1);
                const operand = try self.inferValue(ex.rhs(e), depth + 1);
                const count = try self.replicationCount(ex.lhs(e));
                const width = std.math.mul(u32, count, operand.width) catch return self.exprFail(e, "replication width exceeds the supported u32 range");
                try self.replications.put(self.arena, e, count);
                break :blk .{ .width = width, .signed = false };
            },
            else => return self.exprFail(e, "this digital expression form is not implemented"),
        };
        entry.* = ty;
        return ty;
    }
    fn leaf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .ident => self.values[try self.slot(e)],
            .logic_literal => ex.logicValue(e),
            .int_literal => blk: {
                const n = ex.intLiteral(e);
                const planes = try a.alloc(u64, 2);
                planes[0] = @bitCast(n.value);
                planes[1] = 0;
                const width = if (n.width == 0) 32 else n.width;
                if (width < 64) planes[0] &= (@as(u64, 1) << @intCast(width)) - 1;
                break :blk .{ .width = width, .signed = n.signed, .sized = n.width != 0, .planes = planes };
            },
            else => unreachable, // preflight checkExpr
        };
    }
    fn normalize(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal {
        var result = value.resize(a, ty.width, if (ty.signed) .sign else .zero) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ZeroSize => unreachable,
        };
        result.signed = ty.signed;
        return result;
    }
    fn scalar(a: std.mem.Allocator, bit: Int.Bit) Error!Int.Literal {
        const planes = try a.alloc(u64, 2);
        planes[0] = @intFromEnum(bit) & 1;
        planes[1] = @intFromEnum(bit) >> 1;
        return .{ .width = 1, .signed = false, .sized = true, .planes = planes };
    }
    // Assignment supplies width only (§5.5.3); its signedness cannot change
    // the RHS type. Operator contexts below propagate BOTH width and type.
    fn eval(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, width: u32) Error!Int.Literal {
        var ty = self.typeOf(e);
        ty.width = @max(ty.width, width);
        return self.evalContext(a, e, ty);
    }
    fn scalarContext(a: std.mem.Allocator, bit: Int.Bit, ty: Type) Error!Int.Literal {
        return normalize(a, try scalar(a, bit), ty);
    }
    // IEEE1364-2005 §5.5.2: propagate context before evaluating operands.
    // Fixed one-bit results stop propagation; their operands get the separate
    // self-determined or common comparison context prescribed by Table 5-22.
    fn evalContext(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, ty: Type) Error!Int.Literal {
        const ex = &self.file.exprs;
        switch (ex.tag(e)) {
            .int_literal, .logic_literal, .ident => return normalize(a, try self.leaf(a, e), ty),
            .unary => {
                const op = ex.unOp(e);
                switch (op) {
                    .plus, .minus, .bit_not => {
                        const value = try self.evalContext(a, ex.lhs(e), ty);
                        return switch (op) {
                            .plus => value,
                            .minus => value.negate(a),
                            .bit_not => value.bitwiseNot(a),
                            else => unreachable,
                        };
                    },
                    else => {
                        const value = try self.eval(a, ex.lhs(e), 0);
                        const bit = if (op == .logical_not) value.logicalNot() else value.reduce(switch (op) {
                            .reduce_and => .and_bits,
                            .reduce_nand => .nand_bits,
                            .reduce_or => .or_bits,
                            .reduce_nor => .nor_bits,
                            .reduce_xor => .xor_bits,
                            .reduce_xnor => .xnor_bits,
                            else => unreachable,
                        });
                        return scalarContext(a, bit, ty);
                    },
                }
            },
            .binary => {
                const op = ex.binOp(e);
                switch (op) {
                    .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                        const operand_type = common(self.typeOf(ex.lhs(e)), self.typeOf(ex.rhs(e)));
                        const lhs = try self.evalContext(a, ex.lhs(e), operand_type);
                        const rhs = try self.evalContext(a, ex.rhs(e), operand_type);
                        const bit = switch (op) {
                            .eq, .neq, .case_eq, .case_neq => lhs.equality(switch (op) {
                                .eq => .equal,
                                .neq => .not_equal,
                                .case_eq => .case_equal,
                                else => .case_not_equal,
                            }, rhs),
                            else => lhs.relational(switch (op) {
                                .lt => .less,
                                .le => .less_equal,
                                .gt => .greater,
                                else => .greater_equal,
                            }, rhs),
                        };
                        return scalarContext(a, bit, ty);
                    },
                    .logical_and, .logical_or => {
                        const lhs = try self.eval(a, ex.lhs(e), 0);
                        const truth = lhs.truth();
                        if ((op == .logical_and and truth == .zero) or (op == .logical_or and truth == .one))
                            return scalarContext(a, truth, ty);
                        const rhs = try self.eval(a, ex.rhs(e), 0);
                        return scalarContext(a, lhs.logical(if (op == .logical_and) .and_bits else .or_bits, rhs), ty);
                    },
                    .shl, .shr, .ashl, .ashr, .pow => {
                        const lhs = try self.evalContext(a, ex.lhs(e), ty);
                        const rhs = try self.eval(a, ex.rhs(e), 0);
                        if (op == .pow) return lhs.power(a, rhs);
                        return lhs.shift(a, switch (op) {
                            .shl => .left,
                            .shr => .right,
                            .ashl => .arithmetic_left,
                            else => .arithmetic_right,
                        }, rhs);
                    },
                    else => {},
                }
                const lhs = try self.evalContext(a, ex.lhs(e), ty);
                const rhs = try self.evalContext(a, ex.rhs(e), ty);
                return switch (op) {
                    .add, .sub, .mul, .div, .mod => lhs.arithmetic(a, switch (op) {
                        .add => .add,
                        .sub => .subtract,
                        .mul => .multiply,
                        .div => .divide,
                        else => .remainder,
                    }, rhs),
                    .bit_and, .bit_or, .bit_xor, .bit_xnor => lhs.bitwise(a, switch (op) {
                        .bit_and => .and_bits,
                        .bit_or => .or_bits,
                        .bit_xor => .xor_bits,
                        else => .xnor_bits,
                    }, rhs),
                    else => unreachable,
                };
            },
            .ternary => {
                const condition = try self.eval(a, ex.lhs(e), 0);
                return switch (condition.truth()) {
                    .one => self.evalContext(a, ex.rhs(e), ty),
                    .zero => self.evalContext(a, ex.ternaryElse(e), ty),
                    .x, .z => condition.conditional(a, try self.evalContext(a, ex.rhs(e), ty), try self.evalContext(a, ex.ternaryElse(e), ty)),
                };
            },
            .sys_call => {
                const cast = casts.get(self.file.str(ex.strOf(e))).?;
                var value = try self.eval(a, ex.args(e)[0], 0);
                value.signed = cast == .make_signed;
                return normalize(a, value, ty);
            },
            .concat => {
                var parts: std.ArrayList(Int.Literal) = .empty;
                for (ex.args(e)) |arg| {
                    if (self.typeOf(arg).width == 0) {
                        // §5.1.14 evaluates the repeated operand once even for
                        // count zero. No zero-width Literal enters value helpers.
                        std.debug.assert(ex.tag(arg) == .multi_concat);
                        _ = try self.eval(a, ex.rhs(arg), 0);
                    } else try parts.append(a, try self.eval(a, arg, 0));
                }
                const value = Int.Literal.concatenate(a, parts.items) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ZeroSize, error.Overflow => unreachable, // preflight checked exact widths
                };
                return normalize(a, value, ty);
            },
            .multi_concat => {
                const value = try self.eval(a, ex.rhs(e), 0);
                const repeated = value.replicate(a, self.replications.get(e).?) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ZeroSize, error.Overflow => unreachable, // zero only consumed by .concat above
                };
                return normalize(a, repeated, ty);
            },
            else => unreachable, // infer rejects unsupported forms before execution
        }
    }
    fn position(self: *Run) u32 {
        return @intCast(self.code.items.len);
    }
    fn append(self: *Run, instruction: Instruction) Error!u32 {
        if (self.code.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital instructions", .{});
        const at = self.position();
        try self.code.append(self.arena, instruction);
        return at;
    }
    fn compileStmt(self: *Run, id: Ast.StmtId, depth: u16) Error!void {
        const tok = self.file.stmtTok(id);
        if (depth == 256) return self.fail(tok, "digital statements deeper than 256 AST levels are not implemented", .{});
        switch (self.file.stmt(id)) {
            .empty => {},
            .block => |b| {
                if (b.name != .none or b.vars.len != 0 or b.params.len != 0) return self.fail(tok, "block declarations/named scopes are not implemented", .{});
                for (b.body) |s| try self.compileStmt(s, depth + 1);
            },
            .if_stmt => |s| {
                if (s.is_generate) return self.fail(tok, "conditional generate is not implemented", .{});
                try self.checkExpr(s.cond);
                const test_pc = try self.append(.{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
                try self.compileStmt(s.then_s, depth + 1);
                if (s.else_s == .none) {
                    self.code.items[test_pc].branch.otherwise = self.position();
                } else {
                    const end_pc = try self.append(.{ .jump = 0 });
                    self.code.items[test_pc].branch.otherwise = self.position();
                    try self.compileStmt(s.else_s, depth + 1);
                    self.code.items[end_pc].jump = self.position();
                }
            },
            .while_stmt => |s| {
                try self.checkExpr(s.cond);
                const test_pc = try self.append(.{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
                try self.compileStmt(s.body, depth + 1);
                _ = try self.append(.{ .jump = test_pc });
                self.code.items[test_pc].branch.otherwise = self.position();
            },
            .for_stmt => |s| {
                try self.compileStmt(s.init, depth + 1);
                try self.checkExpr(s.cond);
                const test_pc = try self.append(.{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
                try self.compileStmt(s.body, depth + 1);
                try self.compileStmt(s.step, depth + 1);
                _ = try self.append(.{ .jump = test_pc });
                self.code.items[test_pc].branch.otherwise = self.position();
            },
            .repeat_stmt => |s| {
                try self.checkExpr(s.count);
                if (self.typeOf(s.count).width > 64) return self.exprFail(s.count, "repeat counts wider than 64 bits are not implemented");
                if (self.repeats.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many repeat counters", .{});
                const counter: u32 = @intCast(self.repeats.items.len);
                try self.repeats.append(self.arena, 0);
                const test_pc = try self.append(.{ .repeat_start = .{ .count = s.count, .counter = counter, .end = 0 } });
                const body_pc = self.position();
                try self.compileStmt(s.body, depth + 1);
                _ = try self.append(.{ .repeat_next = .{ .counter = counter, .body = body_pc } });
                self.code.items[test_pc].repeat_start.end = self.position();
            },
            .case_stmt => |s| {
                if (s.is_generate) return self.fail(tok, "case generate is not implemented", .{});
                if (s.arms.len == 0) return self.fail(tok, "a case statement requires at least one item", .{});
                try self.checkExpr(s.scrutinee);
                var ty = self.typeOf(s.scrutinee);
                var have_default = false;
                for (s.arms) |arm| {
                    if (arm.labels.len == 0) {
                        if (have_default) return self.fail(tok, "a case statement cannot have multiple default items", .{});
                        have_default = true;
                    }
                    for (arm.labels) |label| {
                        try self.checkExpr(label);
                        ty = common(ty, self.typeOf(label));
                    }
                }
                if (s.arms.len > std.math.maxInt(u32) - self.case_targets.items.len) return self.fail(tok, "too many case targets", .{});
                const targets: u32 = @intCast(self.case_targets.items.len);
                try self.case_targets.appendNTimes(self.arena, 0, s.arms.len);
                const dispatch = try self.append(.{ .case_select = .{ .statement = id, .targets = targets, .fallback = 0, .ty = ty } });
                const exits = try self.arena.alloc(u32, s.arms.len);
                for (s.arms, 0..) |arm, i| {
                    self.case_targets.items[targets + i] = self.position();
                    if (arm.labels.len == 0) self.code.items[dispatch].case_select.fallback = self.position();
                    try self.compileStmt(arm.body, depth + 1);
                    exits[i] = try self.append(.{ .jump = 0 });
                }
                const end = self.position();
                if (!have_default) self.code.items[dispatch].case_select.fallback = end;
                for (exits) |at| self.code.items[at].jump = end;
            },
            .assign => |s| {
                _ = try self.slot(s.target);
                try self.checkExpr(s.value);
                _ = try self.append(.{ .statement = id });
            },
            .event_control => |s| {
                if (!s.is_delay) {
                    try self.checkEvent(s.event);
                    _ = try self.append(.{ .wait_event = s.event });
                    return self.compileStmt(s.body, depth + 1);
                }
                if (self.scale == null) return self.fail(tok, "digital delays require an explicit valid timescale before the module", .{});
                try self.checkExpr(s.event);
                if (self.typeOf(s.event).width > 64) return self.exprFail(s.event, "delay values wider than 64 bits are not implemented");
                _ = try self.append(.{ .statement = id });
                try self.compileStmt(s.body, depth + 1);
            },
            .sys_task => |s| {
                const name = self.file.str(s.name);
                const task = tasks.get(name) orelse return self.fail(tok, "digital system task `{s}` is not implemented", .{name});
                switch (task) {
                    .display => try self.display(s.args, null),
                    .finish => {
                        if (s.args.len > 1) return self.fail(tok, "$finish accepts zero or one argument", .{});
                        if (s.args.len == 1) {
                            const ex = &self.file.exprs;
                            if (ex.tag(s.args[0]) != .int_literal or ex.intValue(s.args[0]) < 0 or ex.intValue(s.args[0]) > 1)
                                return self.fail(tok, "only $finish(0), $finish(1), and $finish are implemented", .{});
                        }
                    },
                }
                _ = try self.append(.{ .statement = id });
            },
            else => return self.fail(tok, "this digital statement is not implemented", .{}),
        }
    }
    // null allocator validates the complete format/expression surface without
    // producing output. %b is width-exact, including separate X and Z states.
    fn display(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator) Error!void {
        const ex = &self.file.exprs;
        var arg: usize = 0;
        while (arg < args.len) : (arg += 1) {
            const e = args[arg];
            if (e == .none or ex.tag(e) != .str_literal) return self.fail(0, "$display requires literal formats; only %b and %% are implemented", .{});
            const format = self.file.str(ex.strOf(e));
            var i: usize = 0;
            while (i < format.len) : (i += 1) {
                if (format[i] != '%') {
                    if (allocator != null) try self.out.writeByte(format[i]);
                    continue;
                }
                i += 1;
                if (i == format.len) return self.exprFail(e, "unterminated display format");
                if (format[i] == '%') {
                    if (allocator != null) try self.out.writeByte('%');
                    continue;
                }
                if (format[i] != 'b') return self.exprFail(e, "only %b and %% display conversions are implemented");
                arg += 1;
                if (arg == args.len) return self.exprFail(e, "missing display argument");
                try self.checkExpr(args[arg]);
                if (allocator) |a| {
                    const v = try self.eval(a, args[arg], 0);
                    var bit = v.width;
                    while (bit != 0) {
                        bit -= 1;
                        try self.out.writeByte(switch (v.bit(bit)) {
                            .zero => '0',
                            .one => '1',
                            .x => 'x',
                            .z => 'z',
                        });
                    }
                }
            }
        }
        if (allocator != null) try self.out.writeByte('\n');
    }
    /// The one write path for both the active and NBA regions, so §5.10.1
    /// resumption cannot be bypassed by whichever region a source used.
    fn store(self: *Run, target: u32, planes: []const u64) Error!void {
        const dest = self.values[target];
        const before = dest.bit(0);
        const changed = !std.mem.eql(u64, dest.planes, planes);
        @memcpy(dest.planes, planes);
        if (!changed or self.waiters.items.len == 0) return;
        const after = dest.bit(0);
        // ponytail: linear scan. The list holds only currently-suspended
        // processes, so it is bounded by the source's process count; index it
        // by slot if a design ever suspends in bulk.
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            const w = self.waiters.items[i];
            if (w.slot != target or !w.edge.matches(before, after)) {
                i += 1;
                continue;
            }
            // Retire every term of this process's event expression. Scanning
            // down keeps the not-yet-examined prefix intact, so each swapped-in
            // entry has already been checked; the scan then restarts because
            // removal moved the tail. Every pass drops at least one entry.
            var j = self.waiters.items.len;
            while (j != 0) {
                j -= 1;
                if (self.waiters.items[j].pc == w.pc) _ = self.waiters.swapRemove(j);
            }
            try self.enqueue(.{ .run_process = w.pc }, null, false);
            i = 0;
        }
    }
    /// Event terms resolve to watched slots at compile time, so a resumption
    /// never has to fail in the middle of a dispatch.
    fn checkEvent(self: *Run, e: Ast.ExprId) Error!void {
        const ex = &self.file.exprs;
        switch (ex.tag(e)) {
            .event_or => {
                try self.checkEvent(ex.lhs(e));
                try self.checkEvent(ex.rhs(e));
            },
            .event_posedge, .event_negedge => _ = try self.slot(ex.lhs(e)),
            .ident => _ = try self.slot(e),
            else => return self.exprFail(e, "only variable and posedge/negedge event terms are implemented"),
        }
    }
    fn suspendOn(self: *Run, e: Ast.ExprId, resume_pc: u32) Error!void {
        const ex = &self.file.exprs;
        const edge: Edge = switch (ex.tag(e)) {
            .event_or => {
                try self.suspendOn(ex.lhs(e), resume_pc);
                return self.suspendOn(ex.rhs(e), resume_pc);
            },
            .event_posedge => .posedge,
            .event_negedge => .negedge,
            else => .any,
        };
        const watched = if (edge == .any) e else ex.lhs(e);
        try self.waiters.append(self.arena, .{ .slot = try self.slot(watched), .edge = edge, .pc = resume_pc });
    }
    fn enqueue(self: *Run, item: Pending, delay: ?u64, nba: bool) Error!void {
        if (self.pending.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital events", .{});
        const payload: u32 = @intCast(self.pending.items.len);
        try self.pending.append(self.arena, item);
        _ = if (delay) |d|
            self.scheduler.scheduleAfter(d, if (nba) .nba else .inactive, payload) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital timing failure: {t}", .{e})
        else
            self.scheduler.schedule(if (nba) .nba else .active, payload) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
    }
    fn caseMatches(kind: Ast.CaseKind, value: Int.Literal, label: Int.Literal) bool {
        std.debug.assert(value.width == label.width);
        if (kind == .normal) return value.equality(.case_equal, label) == .one;
        // IEEE1364-2005 §9.5.1: wildcards apply symmetrically to either value.
        for (0..value.width) |i| {
            const a = value.bit(@intCast(i));
            const b = label.bit(@intCast(i));
            if (a == .z or b == .z or (kind == .casex and (a == .x or b == .x))) continue;
            if (a != b) return false;
        }
        return true;
    }
    fn execute(self: *Run, scratch_arena: *std.heap.ArenaAllocator, start: u32) Error!void {
        var pc = start;
        var restarted = false;
        while (true) {
            // Each instruction completes its copies/captures before scratch is
            // reused; an untimed loop therefore retains no iteration temporaries.
            _ = scratch_arena.reset(.retain_capacity);
            const scratch = scratch_arena.allocator();
            const id = switch (self.code.items[pc]) {
                .stop => return,
                .statement => |id| id,
                .jump => |target| {
                    pc = target;
                    continue;
                },
                .wait_event => |e| return self.suspendOn(e, pc + 1),
                .restart => |s| {
                    // A suspension returns from this dispatch, so reaching the
                    // restart a second time within one proves a whole body ran
                    // with no timing control. That spins the scheduler forever
                    // at one timestamp, so it is reported instead of hanging.
                    if (restarted) return self.fail(s.tok, "this always process completed an iteration without suspending; it needs a delay or event control", .{});
                    restarted = true;
                    pc = s.target;
                    continue;
                },
                .branch => |s| {
                    const value = try self.eval(scratch, s.condition, 0);
                    pc = if (value.truth() == .one) pc + 1 else s.otherwise;
                    continue;
                },
                .repeat_start => |s| {
                    const value = try self.eval(scratch, s.count, 0);
                    const count = if (value.hasUnknown()) 0 else blk: {
                        if (value.signed and value.asInt().? < 0)
                            return self.exprFail(s.count, "negative repeat counts are not implemented; IEEE1364-2005 does not define this case explicitly");
                        break :blk value.values()[0];
                    };
                    self.repeats.items[s.counter] = count;
                    pc = if (count == 0) s.end else pc + 1;
                    continue;
                },
                .repeat_next => |s| {
                    self.repeats.items[s.counter] -= 1;
                    pc = if (self.repeats.items[s.counter] != 0) s.body else pc + 1;
                    continue;
                },
                .case_select => |s| {
                    const case = self.file.stmt(s.statement).case_stmt;
                    const value = try self.evalContext(scratch, case.scrutinee, s.ty);
                    pc = s.fallback;
                    search: for (case.arms, 0..) |arm, i| {
                        for (arm.labels) |label| {
                            const item = try self.evalContext(scratch, label, s.ty);
                            if (caseMatches(case.kind, value, item)) {
                                pc = self.case_targets.items[s.targets + i];
                                break :search;
                            }
                        }
                    }
                    continue;
                },
            };
            switch (self.file.stmt(id)) {
                .assign => |s| {
                    const target = try self.slot(s.target);
                    const dest = self.values[target];
                    const rhs = try self.eval(scratch, s.value, dest.width);
                    const value = try normalize(if (s.nonblocking) self.arena else scratch, rhs, .{ .width = dest.width, .signed = rhs.signed });
                    if (s.nonblocking) try self.enqueue(.{ .write = .{ .target = target, .value = value } }, null, true) else try self.store(target, value.planes);
                },
                .event_control => |s| {
                    const value = try self.eval(scratch, s.event, 0);
                    const delay: u64 = if (value.hasUnknown()) 0 else blk: {
                        if (value.width > 64) return self.exprFail(s.event, "delay values wider than 64 bits are not implemented");
                        break :blk (if (value.signed) self.scale.?.signedDelay(value.asInt().?) else self.scale.?.unsignedDelay(value.values()[0])) catch |e|
                            return self.fail(self.file.stmtTok(id), "digital delay cannot be represented: {t}", .{e});
                    };
                    try self.enqueue(.{ .run_process = pc + 1 }, delay, false);
                    return;
                },
                .sys_task => |s| {
                    if (tasks.get(self.file.str(s.name)).? == .display) try self.display(s.args, scratch) else {
                        const verbose = s.args.len == 0 or self.file.exprs.intValue(s.args[0]) != 0;
                        if (verbose) {
                            const start_byte = self.starts[self.file.stmtTok(id)];
                            const loc = self.bag.locate(.{ .start = start_byte, .end = start_byte }, null);
                            try self.out.print("$finish at tick {d}, {s} byte {d}\n", .{ self.scheduler.now, self.bag.fileName(loc.file), loc.offset });
                        }
                        self.scheduler.finish();
                        return;
                    }
                },
                else => unreachable,
            }
            pc += 1;
        }
    }
};

/// Callers own the run arena and diagnostic source lifetime. No analog lowering,
/// generated-device interpretation, external compiler, or secondary lexer is used.
pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    var times: []const Front.Preprocessor.TimescaleEvent = &.{};
    const text = Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .std_defs = false, .timescale_events = &times, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    var tokens = try Front.Lexer.Lexer.tokenize(arena, text);
    var parser = Front.Parser.Parser.init(arena, text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    const file = parser.parseSourceFile() catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseError => error.DigitalFailed,
    };
    if (bag.failed()) return error.DigitalFailed;
    var r: Run = .{ .arena = arena, .file = &file, .starts = tokens.items(.start), .bag = bag, .out = out, .values = &.{}, .scheduler = Scheduler.init(arena) };
    if (file.modules.len != 1 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires exactly one ordinary module", .{});
    const m = file.modules[0];
    if (m.is_connect or m.ports.len != 0 or m.params.len != 0 or m.aliasparams.len != 0 or m.nets.len != 0 or m.branches.len != 0 or m.instances.len != 0 or m.defparams.len != 0 or m.genvars.len != 0 or m.events.len != 0 or m.functions.len != 0 or m.analog.len != 0 or m.attrs.len != 0)
        return r.fail(m.main_tok, "digital execution currently requires a portless module with only variables and initial processes", .{});
    for (times) |event| {
        if (event.at > r.starts[m.main_tok]) return r.fail(m.main_tok, "timescale/resetall after module start is not implemented for digital execution", .{});
        // A null scale is now only ever IEEE 1364 §19.6's `resetall, which
        // returns `timescale to "none specified". A MALFORMED directive no
        // longer reaches here at all: the preprocessor refuses it where it is
        // written (E0142), which is a better place to hear about it than a
        // consumer three stages away.
        const t = event.scale orelse return r.fail(m.main_tok, "a resetall timing state is not supported by digital execution", .{});
        const unit = Time.Quantum.fromSeconds(t.unit) catch return r.fail(m.main_tok, "unsupported time unit", .{});
        const precision = Time.Quantum.fromSeconds(t.precision) catch return r.fail(m.main_tok, "unsupported time precision", .{});
        r.scale = Time.Scale.init(unit, precision, precision) catch return r.fail(m.main_tok, "invalid timescale", .{});
    }
    if (m.vars.len > std.math.maxInt(u32)) return r.fail(m.main_tok, "too many digital variables", .{});
    r.values = try arena.alloc(Int.Literal, m.vars.len);
    for (m.vars, 0..) |v, i| {
        if (v.ty != .integer or v.dims.len != 0 or v.init != .none or v.storage == .time) return r.fail(v.main_tok, "only uninitialized scalar/packed reg and integer declarations are implemented", .{});
        var width: u32 = if (v.storage == .reg) 1 else 32;
        if (v.packed_range) |range| {
            if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return r.fail(v.main_tok, "packed reg bounds must be literal nonnegative integers", .{});
            const hi = file.exprs.intValue(range.msb);
            const lo = file.exprs.intValue(range.lsb);
            if (hi < 0 or lo < 0 or @abs(hi - lo) >= std.math.maxInt(u32)) return r.fail(v.main_tok, "packed reg range is outside the supported u32 width", .{});
            width = @intCast(@abs(hi - lo) + 1);
        }
        const words = (@as(usize, width) - 1) / 64 + 1;
        const planes = try arena.alloc(u64, words * 2);
        @memset(planes, std.math.maxInt(u64));
        const tail: u6 = @truncate(width);
        if (tail != 0) {
            planes[words - 1] = (@as(u64, 1) << tail) - 1;
            planes[2 * words - 1] = planes[words - 1];
        }
        r.values[i] = .{ .width = width, .signed = if (v.storage == .reg) v.is_signed else true, .sized = true, .planes = planes };
        const entry = try r.names.getOrPut(arena, v.name);
        if (entry.found_existing) return r.fail(v.main_tok, "duplicate digital variable", .{});
        entry.value_ptr.* = @intCast(i);
    }
    r.types = try arena.alloc(Type, file.exprs.nodes.len);
    @memset(r.types, .{ .width = 0, .signed = false });
    for (m.discrete) |process| {
        const start: u32 = @intCast(r.code.items.len);
        try r.compileStmt(process.body, 0);
        _ = try r.append(if (process.is_always)
            .{ .restart = .{ .target = start, .tok = process.main_tok } }
        else
            .stop);
        try r.enqueue(.{ .run_process = start }, null, false);
    }
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    while (r.scheduler.next()) |event| {
        _ = scratch.reset(.retain_capacity);
        switch (r.pending.items[event.payload]) {
            .run_process => |start| try r.execute(&scratch, start),
            .write => |w| try r.store(w.target, w.value.planes),
        }
    }
}

fn expectRun(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    run(arena.allocator(), source, .{}, &bag, &output.writer) catch |e| {
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        std.debug.print("{s}", .{messages.written()});
        return e;
    };
    try std.testing.expectEqualStrings(expected, output.written());
}

test "source processes suspend at zero delay and NBA captures RHS in lexical order" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module example;
        \\reg [3:0] a, b;
        \\initial begin
        \\  $display("initial %b",a);
        \\  a = 4'b0001;
        \\  b <= a;
        \\  b <= 4'b0011;
        \\  a = 4'b0010;
        \\  #0 $display("inactive %b %b",a,b);
        \\  #1 $display("after %b %b",a,b);
        \\  $finish(0);
        \\end
        \\initial begin #0 $display("peer %b",a); end
        \\endmodule
    , "initial xxxx\ninactive 0010 xxxx\npeer 0010\nafter 0010 0011\n");
}

test "digital assignment context extends before operations and preserves X Z" {
    try expectRun(
        \\module example;
        \\reg [7:0] a;
        \\integer i;
        \\initial begin
        \\  a = ~4'b0000; $display("wide %b",a);
        \\  a = 4'sb1000; $display("signed %b",a);
        \\  a = 4'b1000; $display("unsigned %b",a);
        \\  a = 4'b10xz; $display("logic %b",a);
        \\  i = 32'shffffffff; $display("integer %b",i);
        \\end
        \\endmodule
    , "wide 11111111\nsigned 11111000\nunsigned 00001000\nlogic 000010xz\ninteger 11111111111111111111111111111111\n");
}

test "an always process resumes on each posedge of a clock it does not drive" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg clk;
        \\reg [3:0] n;
        \\initial begin clk = 0; n = 0; end
        \\always #5 clk = ~clk;
        \\always @(posedge clk) begin n = n + 1; $display("tick %b", n); end
        \\initial #28 $finish(0);
        \\endmodule
    , "tick 0001\ntick 0010\ntick 0011\n");
}

test "a negedge term ignores the opposite transition" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg clk;
        \\reg [3:0] n;
        \\initial begin clk = 0; n = 0; end
        \\always #5 clk = ~clk;
        \\always @(negedge clk) begin n = n + 1; $display("fall %b", n); end
        \\initial #28 $finish(0);
        \\endmodule
    , "fall 0001\nfall 0010\n");
}

test "every term of one event expression retires when any of them fires" {
    // Both waiters belong to one process: a second resumption per change would
    // double every line below.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg b;
        \\reg [1:0] hits;
        \\initial begin a = 0; b = 0; hits = 0; end
        \\always @(a or b) begin hits = hits + 1; $display("hit %b", hits); end
        \\initial begin #5 a = 1; #5 b = 1; #5 a = 0; #5 $finish(0); end
        \\endmodule
    , "hit 01\nhit 10\nhit 11\n");
}

test "a write that does not change the value resumes nothing" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg [1:0] hits;
        \\initial begin a = 0; hits = 0; end
        \\always @(a) begin hits = hits + 1; $display("hit %b", hits); end
        \\initial begin #5 a = 0; #5 a = 1; #5 $finish(0); end
        \\endmodule
    , "hit 01\n");
}

test "a nonblocking write resumes a waiting process from the NBA region" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg [1:0] hits;
        \\initial begin a = 0; hits = 0; end
        \\always @(posedge a) begin hits = hits + 1; $display("nba %b", hits); end
        \\initial begin #5 a <= 1; #5 $finish(0); end
        \\endmodule
    , "nba 01\n");
}

fn expectRejected(source: []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, run(arena.allocator(), source, .{}, &bag, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
    var messages = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, messages.written(), message) != null);
}

test "unsupported source is rejected before any process side effect" {
    try expectRejected("module m; initial $display(\"before\"); initial forever ; endmodule", "error");
    try expectRejected("module m; tran(a,b); initial $display(\"before\"); endmodule", "switch primitives");
    try expectRejected("module m; initial $display(\"%b\",2147483648); endmodule", "unsized constants");
    try expectRejected("module m; initial $display(\"%b\",'hx); endmodule", "unsized four-state");
    try expectRejected("module m; reg c; always begin c = 1; end endmodule", "without suspending");
    try expectRejected("module m; reg c; initial @(c[0]) c = 1; endmodule", "event terms are implemented");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=(a+1)+$clog2(1); end endmodule", "expression form");
    try expectRejected("module m; reg [3:0] a; initial a[0]=1; endmodule", "whole-variable");
    try expectRejected("module m; initial $finish(2); endmodule", "only $finish");
    try expectRejected("module m; initial $display(\"%d\",1); endmodule", "only %b");
    try expectRejected("module m; reg a; initial a=1; integer a; endmodule", "duplicate digital");
}

test "timescale provenance rejects absent malformed or later directives" {
    try expectRejected("module m; initial #1 ; endmodule", "explicit valid timescale");
    // All three are refused by the preprocessor now (E0142), so what the digital
    // executor sees is a failed preprocess and the message names the directive
    // rather than the consumer that could not use it.
    try expectRejected("`timescale 2ns/1ps\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ns/1ps junk\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ps/1ns\nmodule m; initial #1 ; endmodule", "coarser than the time unit");
    try expectRejected("`timescale 1ns/1ps\nmodule m; initial #1 ; endmodule\n`timescale 1ms/1us\n", "after module start");
    try expectRejected("`timescale 1ns/1ps\n`resetall\nmodule m; initial #1 ; endmodule", "resetall");
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #1.5 ; endmodule", "digital expression");
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #(128'd1) ; endmodule", "wider than 64");
}

test "unknown delay is zero and finish discards pending later processes" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\initial begin
        \\  a = 0; a <= 1;
        \\  #(1'bx) $display("unknown-delay %b",a);
        \\  #1 $display("later %b",a);
        \\  $finish(0);
        \\end
        \\initial begin #2 $display("not run"); end
        \\endmodule
    , "unknown-delay 0\nlater 1\n");
}

test "display retains escaped NUL bytes and unsized integer width" {
    try expectRun("module m; initial $display(\"A\\000B %b\",1); endmodule", "A\x00B 00000000000000000000000000000001\n");
    try expectRun("module m; initial $display(\"%b\",65'd1); endmodule", "00000000000000000000000000000000000000000000000000000000000000001\n");
}

test "finish verbosity reports exact local precision ticks and mapped source" {
    const source = "`timescale 1ns/1ps\nmodule m; initial #1 $finish; endmodule";
    const offset = std.mem.indexOf(u8, source, "$finish").?;
    var expected: [128]u8 = undefined;
    try expectRun(source, try std.fmt.bufPrint(&expected, "$finish at tick 1000, <digital> byte {d}\n", .{offset}));
}

test "nested unsupported forms fail preflight even in unselected conditional arms" {
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b1 ? 1'b0 : $clog2(1); end endmodule", "expression form");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b0 && $clog2(1); end endmodule", "expression form");
}

test "deep left-associated source expression fails before output" {
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("module m; reg a; initial begin $display(\"before\"); a=0");
    for (0..256) |_| try source.writer.writeAll("+0");
    try source.writer.writeAll("; end endmodule");
    try expectRejected(source.written(), "deeper than 256 AST levels");
}

test "nested expressions preserve NBA snapshot and evaluate delay at suspension" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] a,b;
        \\integer n;
        \\initial begin
        \\  a=4'h3; n=0;
        \\  b <= (a+4'h1)*4'h2;
        \\  a=4'hf;
        \\  #(n+1) $display("nested-nba %b",b);
        \\  $finish(0);
        \\end
        \\endmodule
    , "nested-nba 1000\n");
}

test "control flow validates unselected bodies and every case label" {
    try expectRejected("module m; initial begin $display(\"before\"); if(0) $write(\"BAD\"); end endmodule", "system task");
    try expectRejected("module m; initial begin $display(\"before\"); case(1) 1:; $clog2(2):; endcase end endmodule", "expression form");
    try expectRejected("module m; initial begin $display(\"before\"); while(0) @(a); end endmodule", "undeclared digital variable");
    try expectRejected("module m; initial case(1) default:; default:; endcase endmodule", "multiple default");
    try expectRejected("module m; initial case(1) endcase endmodule", "at least one item");
    try expectRejected("module m; initial repeat(65'd1); endmodule", "wider than 64");
    try expectRejected("module m; initial repeat(-1); endmodule", "negative repeat counts");
}

test "repeat accepts all 64 count bits and finish stops without an iteration clamp" {
    try expectRun("module m; initial repeat(64'hffffffffffffffff) begin $display(\"first\"); $finish(0); end endmodule", "first\n");
    try expectRun("module m; integer i; initial begin i=0; while(i<70001) i=i+1; $display(\"%b\",i); end endmodule", "00000000000000010001000101110001\n");
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
    try expectRejected("module m; initial $display(\"%b\",{{0{$clog2(1)}},1'b1}); endmodule", "expression form");
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

fn testConcatRunAllocation(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try run(arena.allocator(), "module m; reg [7:0] a; initial begin a={{0{$signed(65'bz)}},{(1+1){4'b10xz}}}; $display(\"%b\",a); end endmodule", .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings("10xz10xz\n", output.written());
}

test "source concat allocation failures clean up preflight and execution arenas" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testConcatRunAllocation, .{});
}
