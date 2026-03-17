//! IEEE 1364-2005 §17 system tasks that keep state of their own: §17.5's
//! programmable logic arrays and §17.6's stochastic queues.
//!
//! In: a task's argument expressions and the `Run`. Out: values written to
//! the task's output arguments, and (queues) `Run.queues`.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const exec = @import("exec.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;

// ---- §17.6 stochastic analysis queues ---------------------------------------

/// The four §17.6 queue tasks; `$q_full` is a function (`SysFn.q_full`).
pub const QueueOp = enum { initialize, add, remove, exam };

const Job = struct { id: i64, info: i64, arrived: u64 };

/// One §17.6.1 queue: FIFO (type 1) or LIFO (type 2) of at most `max` jobs,
/// with what §17.6.4's statistics are computed from.
pub const Queue = struct {
    lifo: bool,
    max: u64,
    jobs: std.ArrayList(Job) = .empty,
    /// §17.6.4 code 3, "the maximum queue length" reached.
    peak: u64 = 0,
    last_arrival: ?u64 = null,
    interarrivals: u64 = 0,
    interarrival_sum: u64 = 0,
    waits: u64 = 0,
    wait_sum: u64 = 0,
    wait_min: ?u64 = null,
};

// Table 17-16's status codes.
const ok = 0;
const full = 1;
const undefined_id = 2;
const empty = 3;
const bad_type = 4;
const bad_length = 5;
const duplicate_id = 6;

fn int(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return (try exec.eval(self, a, e, 0)).asInt();
}

/// The simulation time in the module's unit, which §17.6's statistics are in.
fn now(self: *Run) u64 {
    return self.scale.?.unitsAt(self.scheduler.now);
}

/// One queue task (§17.6.1-§17.6.3, §17.6.5): the status is the last
/// argument of all four, and is always written.
pub fn queueTask(self: *Run, a: std.mem.Allocator, op: QueueOp, args: []const Ast.ExprId) Error!void {
    const id = try int(self, a, args[0]);
    const status: i64 = switch (op) {
        .initialize => blk: {
            const kind = try int(self, a, args[1]);
            const max = try int(self, a, args[2]);
            if (kind != 1 and kind != 2) break :blk bad_type;
            if (max == null or max.? <= 0) break :blk bad_length;
            const entry = try self.queues.getOrPut(self.arena, id orelse break :blk undefined_id);
            if (entry.found_existing) break :blk duplicate_id;
            entry.value_ptr.* = .{ .lifo = kind == 2, .max = @intCast(max.?) };
            break :blk ok;
        },
        .add => blk: {
            const q = self.queues.getPtr(id orelse break :blk undefined_id) orelse break :blk undefined_id;
            if (q.jobs.items.len >= q.max) break :blk full;
            const t = now(self);
            if (q.last_arrival) |last| {
                q.interarrivals += 1;
                q.interarrival_sum += t - last;
            }
            q.last_arrival = t;
            try q.jobs.append(self.arena, .{ .id = (try int(self, a, args[1])) orelse 0, .info = (try int(self, a, args[2])) orelse 0, .arrived = t });
            q.peak = @max(q.peak, q.jobs.items.len);
            break :blk ok;
        },
        .remove => blk: {
            const q = self.queues.getPtr(id orelse break :blk undefined_id) orelse break :blk undefined_id;
            if (q.jobs.items.len == 0) break :blk empty;
            const job = if (q.lifo) q.jobs.pop().? else q.jobs.orderedRemove(0);
            const wait = now(self) - job.arrived;
            q.waits += 1;
            q.wait_sum += wait;
            q.wait_min = @min(q.wait_min orelse wait, wait);
            try exec.assignInt(self, a, args[1], job.id);
            try exec.assignInt(self, a, args[2], job.info);
            break :blk ok;
        },
        // §17.6.4 Table 17-15's statistics codes.
        .exam => blk: {
            const q = self.queues.getPtr(id orelse break :blk undefined_id) orelse break :blk undefined_id;
            const t = now(self);
            const value: u64 = switch ((try int(self, a, args[1])) orelse 0) {
                1 => q.jobs.items.len,
                2 => if (q.interarrivals == 0) 0 else q.interarrival_sum / q.interarrivals,
                3 => q.peak,
                4 => q.wait_min orelse 0,
                5 => longest: {
                    var w: u64 = 0;
                    for (q.jobs.items) |j| w = @max(w, t - j.arrived);
                    break :longest w;
                },
                6 => if (q.waits == 0) 0 else q.wait_sum / q.waits,
                else => break :blk undefined_id,
            };
            try exec.assignInt(self, a, args[2], @intCast(value));
            break :blk ok;
        },
    };
    try exec.assignInt(self, a, args[3], status);
}

/// §17.6.5 `$q_full(q_id, status)`: 1 when the queue holds its maximum.
pub fn queueFull(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const q = if (try int(self, a, args[0])) |id| self.queues.getPtr(id) else null;
    try exec.assignInt(self, a, args[1], if (q == null) undefined_id else ok);
    const found = q orelse return 0;
    return @intFromBool(found.jobs.items.len >= found.max);
}

// ---- §17.5 programmable logic arrays ----------------------------------------

/// One of §17.5's sixteen PLA tasks: `$async$and$array` and the rest. The
/// logic is applied to each personality row's selected inputs.
pub const Pla = struct {
    logic: enum { @"and", @"or", nand, nor },
    /// `plane` (§17.5.4): 0 selects the complement, 1 the input, z/? nothing.
    /// `array`: 1 selects the input, 0 nothing.
    plane: bool,
    /// `async` re-evaluates whenever an input or the personality changes.
    async_: bool,
};

pub const pla_tasks = blk: {
    var list: [16]struct { []const u8, Pla } = undefined;
    var n = 0;
    for (.{ "async", "sync" }) |timing| for (.{ "and", "or", "nand", "nor" }) |logic| for (.{ "array", "plane" }) |form| {
        list[n] = .{ "$" ++ timing ++ "$" ++ logic ++ "$" ++ form, .{
            .logic = @field(@FieldType(Pla, "logic"), logic),
            .plane = std.mem.eql(u8, form, "plane"),
            .async_ = std.mem.eql(u8, timing, "async"),
        } };
        n += 1;
    };
    break :blk list;
};

/// §17.5 one evaluation: row k of the personality memory (lowest address
/// first) computes output bit k; within a row, bit j of the personality
/// governs input j, both counted from the left. An unknown input selected by
/// a row makes it unknown unless the row's controlling value decides it.
/// ponytail: rows are taken lowest address first, which is the declaration
/// order of the ascending memories §17.5's examples use.
pub fn pla(self: *Run, a: std.mem.Allocator, p: Pla, args: []const Ast.ExprId) Error!void {
    const base = try self.slot(args[0]);
    const arr = self.arrays.get(base).?; // compile proved it is an array
    const in = try exec.eval(self, a, args[1], 0);
    const tt = try exec.targetType(self, args[2]);
    const out = try filled(a, tt.width, false, .x);
    const and_like = p.logic == .@"and" or p.logic == .nand;
    for (0..@min(arr.count, tt.width)) |k| {
        const row = self.values[base + @as(u32, @intCast(k))];
        var unknown = false;
        var decided = false;
        for (0..@min(row.width, in.width)) |j| {
            const sel = row.bit(@intCast(row.width - 1 - j));
            var b = in.bit(@intCast(in.width - 1 - j));
            if (p.plane) {
                if (sel == .zero) b = switch (b) {
                    .zero => .one,
                    .one => .zero,
                    else => .x,
                } else if (sel != .one) continue;
            } else if (sel == .zero) continue else if (sel != .one) b = .x;
            // `and` is decided by a 0, `or` by a 1.
            if (b == (if (and_like) Int.Bit.zero else Int.Bit.one)) decided = true;
            if (b == .x or b == .z) unknown = true;
        }
        const value: Int.Bit = if (decided) (if (and_like) .zero else .one) else if (unknown) .x else (if (and_like) .one else .zero);
        const inverted = p.logic == .nand or p.logic == .nor;
        setBit(out, @intCast(tt.width - 1 - k), if (!inverted) value else switch (value) {
            .zero => .one,
            .one => .zero,
            else => .x,
        });
    }
    try exec.assign(self, a, args[2], out);
}

// ---- tests ------------------------------------------------------------------

test "§17.6 queues: FIFO and LIFO order, capacity and the status codes" {
    try expectRun(
        \\module m;
        \\integer s, j, i, v;
        \\initial begin
        \\  $q_initialize(1, 1, 2, s); $write("%0d", s);
        \\  $q_initialize(1, 1, 2, s); $write("%0d", s);
        \\  $q_initialize(2, 2, 2, s); $q_initialize(3, 5, 2, s); $write("%0d", s);
        \\  $q_add(1, 7, 70, s); $q_add(1, 8, 80, s); $q_add(1, 9, 90, s); $write("%0d", s);
        \\  $q_add(2, 7, 70, s); $q_add(2, 8, 80, s);
        \\  v = $q_full(1, s); $write("%0d", v);
        \\  $q_remove(1, j, i, s); $write(" %0d/%0d", j, i);
        \\  $q_remove(2, j, i, s); $write(" %0d/%0d", j, i);
        \\  $q_exam(1, 3, v, s); $write(" %0d", v);
        \\  $q_remove(4, j, i, s); $display(" %0d", s);
        \\end
        \\endmodule
    , "06411 7/70 8/80 2 2\n");
}

test "§17.5 a synchronous PLA evaluates only when called, an asynchronous one tracks" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [1:2] mem [1:2]; reg [1:2] in; reg [1:2] s, y;
        \\initial begin
        \\  mem[1] = 2'b11; mem[2] = 2'b10; in = 2'b10;
        \\  $sync$or$array(mem, in, s); $async$nand$plane(mem, in, y);
        \\  #1 in = 2'b01; #1 $display("%b %b", s, y);
        \\end
        \\endmodule
    , "11 11\n");
}
