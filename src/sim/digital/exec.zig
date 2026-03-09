//! The digital interpreter.
//!
//! In: a scheduled `Pending` row (a pc to run, a write, a delayed drive) and
//! the `Run` state. Out: stored values, woken waiters, newly scheduled events
//! and display output.
//!
//! Clauses: IEEE1364-2005 §5.5.2 context-determined evaluation, §3.9 array
//! addressing, IEEE 1364-2005 17.11.1 `$clog2`; §5.10.1 edges and resumption;
//! §6.1/§6.1.3 continuous assignment and its inertial delay; §7.9 resolution,
//! §3.8 trireg charge decay, §7.8.5 gates; §8.5.3.3/§8.5.3.4 intra-assignment
//! timing, §9.7.1 delays, IEEE1364-2005 §9.5.1 casex/casez, IEEE1364 §10.3
//! `disable`; §17.1.2 `$strobe` and §17.1.3 `$monitor` scheduling.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const compile = @import("compile.zig");
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const Type = compile.Type;
const Inertial = @import("net.zig").Inertial;
const Handle = @import("../scheduler.zig").Handle;
const Bridge = @import("net.zig").Bridge;
const Gate = @import("net.zig").Gate;
const gateBit = @import("net.zig").gateBit;
const Signal = @import("net.zig").Signal;
const netPull = @import("net.zig").netPull;
const wiredLogic = @import("net.zig").wiredLogic;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const wired = @import("net.zig").wired;
const undriven = @import("net.zig").undriven;
const Show = display.Show;

// ---- scheduler rows and waiters (§6.1.3, §17.1.2, §17.1.3, §5.10.1) ---------

// Each dispatch consumes all fields of one pending write. A `.write` value
// lives in its row's own planes (see `Row`), never in mutable variable storage.
pub const Pending = union(enum) {
    run_process: u32,
    write: struct { target: u32, value: Int.Literal },
    /// §17.1.2 one $strobe call, evaluated when the `.monitor` region runs and
    /// not when the call executed — the whole point of the task is that it
    /// reports the settled value.
    strobe: struct { args: []const Ast.ExprId, show: Show, scope: u32, pc: u32 },
    /// §17.1.3 "something changed this timestep, ask the standing monitor".
    /// One per timestep, coalesced by `monitor_pending`.
    monitor_tick,
    /// A.6.1's `[ delay3 ]` on a continuous assignment: this driver's
    /// `transition.target` arrives now. §6.1.3's inertial cancel is the
    /// scheduler's — see `Inertial`.
    drive: u32,
    /// A.2.1.3's `[ delay3 ]` on the net declaration: the same delay one level
    /// down, on the RESOLVED value rather than on one driver's.
    net_update: u32,
    /// A.2.1.3's third `delay3` value on a `trireg`: the charge that has now
    /// been held long enough to be worth nothing.
    decay: u32,
};

/// One payload row. Rows are recycled: a row is live exactly while the
/// scheduler holds its `handle` pending, and goes back on `Run.free_rows` when
/// it dispatches or is cancelled — so the table is as large as the most
/// events ever queued at once, not as the run is long. `buf` is the row's own
/// storage for a `.write` value, kept across reuse and grown only when a wider
/// value arrives.
pub const Row = struct { item: Pending, handle: Handle = undefined, buf: []u64 = &.{} };

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
pub const Waiter = struct { slot: u32, edge: Edge, pc: u32 };

// ---- expression evaluation (§5.5.2, §5.5.3, §3.9, 1364 17.11.1) -------------

/// IEEE 1364-2005 17.11.1: interpret every operand bit as unsigned, regardless
/// of declared signedness. The ceiling is the bit length, minus one exactly
/// for powers of two. Scan all limbs without narrowing or allocating a copy.
fn integerCeilingLog2(value: Int.Literal) u64 {
    // Preserve the existing unknown-input policy; this is not a claim that
    // the source mandates zero for an operand containing x/z.
    if (value.hasUnknown()) return 0;
    var length: u64 = 0;
    var power_of_two = true;
    for (value.values(), 0..) |word, index| {
        if (word == 0) continue;
        if (length != 0 or word & (word - 1) != 0) power_of_two = false;
        length = @as(u64, @intCast(index)) * 64 + 64 - @clz(word);
    }
    return if (length != 0 and power_of_two) length - 1 else length;
}

/// §3.9 the element an `.index` names right now, or the whole value a
/// scalar reference names. `null` is an out-of-bounds or X/Z index: it
/// names no storage, so a read of one is X and a write to one is discarded.
fn address(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .index) return try self.slot(e);
    const base = try self.slot(ex.lhs(e));
    const arr = self.arrays.get(base).?; // infer proved this is an array
    const at = (try eval(self, a, ex.rhs(e), 0)).asInt() orelse return null;
    if (at < arr.low or at > arr.high) return null;
    return base + @as(u32, @intCast(at - arr.low));
}

/// IEEE 1364-2005 §5.2.1: one bit of a vector, named against its DECLARED
/// range — `[3:0]` counts up from the right, `[0:3]` down — and x when the
/// index is x/z or outside that range.
fn bitSelect(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
    const ex = &self.file.exprs;
    const at = try self.slot(ex.lhs(e));
    const v = self.values[at];
    const range: @import("root.zig").VecRange = self.vec_ranges.get(at) orelse .{ .msb = @as(i64, v.width) - 1, .lsb = 0 };
    const index = (try eval(self, a, ex.rhs(e), 0)).asInt() orelse return filled(a, 1, false, .x);
    const pos = if (range.msb >= range.lsb) index - range.lsb else range.lsb - index;
    if (pos < 0 or pos >= v.width) return filled(a, 1, false, .x);
    return filled(a, 1, false, v.bit(@intCast(pos)));
}

fn leaf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident, .hier_ident => self.values[try self.slot(e)],
        .index => blk: {
            const ty = compile.typeOf(self, e);
            if (try self.indexedArray(e) == null) break :blk try bitSelect(self, a, e);
            const at = (try address(self, a, e)) orelse break :blk try filled(a, ty.width, ty.signed, .x);
            break :blk self.values[at];
        },
        .logic_literal => ex.logicValue(e),
        // §3.6 packed ASCII, the first character most significant.
        .str_literal => blk: {
            const text = self.file.str(ex.strOf(e));
            const value = try filled(a, compile.stringWidth(text), false, .zero);
            for (text, 0..) |c, i| {
                const shift: u32 = @intCast((text.len - 1 - i) * 8);
                value.values()[shift / 64] |= @as(u64, c) << @intCast(shift % 64);
            }
            break :blk value;
        },
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

/// `value` in type `ty`. Already that type is returned as is, planes and all —
/// so the result may BE a variable's storage, and a caller that keeps it past
/// the next store copies it (as `claim` and the hold cells do).
fn normalize(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal {
    if (value.width == ty.width and value.signed == ty.signed) return value;
    var result = value.resize(a, ty.width, if (ty.signed) .sign else .zero) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    result.signed = ty.signed;
    return result;
}

/// IEEE 1364-2005 §3.5.1 / Table 5-22's note: "if the size of the unsized
/// constant is smaller than the context, and its leftmost bit is x or z, the
/// x or z shall be extended" — to the size of the EXPRESSION, not to 32 bits.
/// The parsed literal already carries the fill up to its own width, so it is
/// its top bit that is replicated; a known top bit extends as usual.
fn unsizedFill(a: std.mem.Allocator, v: Int.Literal, ty: Type) Error!Int.Literal {
    const top = v.bit(v.width - 1);
    var out = v.resize(a, ty.width, if (top == .x or top == .z or ty.signed) .sign else .zero) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    out.signed = ty.signed;
    return out;
}

fn scalar(a: std.mem.Allocator, bit: Int.Bit) Error!Int.Literal {
    return filled(a, 1, false, bit);
}

// Assignment supplies width only (§5.5.3); its signedness cannot change
// the RHS type. Operator contexts below propagate BOTH width and type.
pub fn eval(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, width: u32) Error!Int.Literal {
    var ty = compile.typeOf(self, e);
    ty.width = @max(ty.width, width);
    return evalContext(self, a, e, ty);
}

fn scalarContext(a: std.mem.Allocator, bit: Int.Bit, ty: Type) Error!Int.Literal {
    return normalize(a, try scalar(a, bit), ty);
}

// IEEE1364-2005 §5.5.2: propagate context before evaluating operands.
// Fixed one-bit results stop propagation; their operands get the separate
// self-determined or common comparison context prescribed by Table 5-22.
fn evalContext(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, ty: Type) Error!Int.Literal {
    const ex = &self.file.exprs;
    if (ex.tag(e) == .logic_literal and !ex.logicValue(e).sized) return unsizedFill(a, ex.logicValue(e), ty);
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .ident, .hier_ident, .index => return normalize(a, try leaf(self, a, e), ty),
        .unary => {
            const op = ex.unOp(e);
            switch (op) {
                .plus, .minus, .bit_not => {
                    const value = try evalContext(self, a, ex.lhs(e), ty);
                    return switch (op) {
                        .plus => value,
                        .minus => value.negate(a),
                        .bit_not => value.bitwiseNot(a),
                        else => unreachable,
                    };
                },
                else => {
                    const value = try eval(self, a, ex.lhs(e), 0);
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
                    const operand_type = compile.common(compile.typeOf(self, ex.lhs(e)), compile.typeOf(self, ex.rhs(e)));
                    const lhs = try evalContext(self, a, ex.lhs(e), operand_type);
                    const rhs = try evalContext(self, a, ex.rhs(e), operand_type);
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
                    const lhs = try eval(self, a, ex.lhs(e), 0);
                    const truth = lhs.truth();
                    if ((op == .logical_and and truth == .zero) or (op == .logical_or and truth == .one))
                        return scalarContext(a, truth, ty);
                    const rhs = try eval(self, a, ex.rhs(e), 0);
                    return scalarContext(a, lhs.logical(if (op == .logical_and) .and_bits else .or_bits, rhs), ty);
                },
                .shl, .shr, .ashl, .ashr, .pow => {
                    const lhs = try evalContext(self, a, ex.lhs(e), ty);
                    const rhs = try eval(self, a, ex.rhs(e), 0);
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
            const lhs = try evalContext(self, a, ex.lhs(e), ty);
            const rhs = try evalContext(self, a, ex.rhs(e), ty);
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
            const condition = try eval(self, a, ex.lhs(e), 0);
            return switch (condition.truth()) {
                .one => evalContext(self, a, ex.rhs(e), ty),
                .zero => evalContext(self, a, ex.ternaryElse(e), ty),
                .x, .z => condition.conditional(a, try evalContext(self, a, ex.rhs(e), ty), try evalContext(self, a, ex.ternaryElse(e), ty)),
            };
        },
        // `infer` resolved every call it typed.
        .sys_call => switch (self.sys_calls[@intFromEnum(e)].?) {
            .make_signed, .make_unsigned => |cast| {
                var value = try eval(self, a, ex.args(e)[0], 0);
                value.signed = cast == .make_signed;
                return normalize(a, value, ty);
            },
            .time, .stime, .clog2, .test_plusargs, .value_plusargs => |f| {
                const natural = compile.typeOf(self, e);
                const raw: u64 = switch (f) {
                    .time, .stime => blk: {
                        const units = self.scale.?.unitsAt(self.scheduler.now);
                        break :blk if (f == .stime) units & 0xffff_ffff else units;
                    },
                    .clog2 => blk: {
                        const n = try eval(self, a, ex.args(e)[0], 0);
                        break :blk integerCeilingLog2(n);
                    },
                    .test_plusargs, .value_plusargs => 0,
                    .make_signed, .make_unsigned => unreachable, // the arm above
                };
                const planes = try a.alloc(u64, 2);
                planes[0] = if (natural.width >= 64) raw else raw & ((@as(u64, 1) << @intCast(natural.width)) - 1);
                planes[1] = 0;
                const value: Int.Literal = .{ .width = natural.width, .signed = natural.signed, .sized = true, .planes = planes };
                return normalize(a, value, ty);
            },
        },
        .concat => {
            var parts: std.ArrayList(Int.Literal) = .empty;
            for (ex.args(e)) |arg| {
                if (compile.typeOf(self, arg).width == 0) {
                    // §5.1.14 evaluates the repeated operand once even for
                    // count zero. No zero-width Literal enters value helpers.
                    std.debug.assert(ex.tag(arg) == .multi_concat);
                    _ = try eval(self, a, ex.rhs(arg), 0);
                } else try parts.append(a, try eval(self, a, arg, 0));
            }
            const value = Int.Literal.concatenate(a, parts.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // preflight checked exact widths
            };
            return normalize(a, value, ty);
        },
        .multi_concat => {
            const value = try eval(self, a, ex.rhs(e), 0);
            const repeated = value.replicate(a, self.replications.get(e).?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // zero only consumed by .concat above
            };
            return normalize(a, repeated, ty);
        },
        else => unreachable, // infer rejects unsupported forms before execution
    }
}

// ---- the write path and §7.9 resolution (§5.10.1, §6.1.3, §3.8, §7.8.5) -----

/// The one write path for both the active and NBA regions, so §5.10.1
/// resumption cannot be bypassed by whichever region a source used.
pub fn store(self: *Run, target: u32, planes: []const u64) Error!void {
    const dest = self.values[target];
    const before = dest.bit(0);
    const changed = !std.mem.eql(u64, dest.planes, planes);
    // Not copied when unchanged — which also covers `planes` BEING
    // `dest.planes` (`a = a`), a copy @memcpy forbids.
    if (changed) @memcpy(dest.planes, planes);
    if (!changed) return;
    // The value-change hook: every watcher of this slot hears it here.
    if (self.watch[target].contains(.monitor)) try requestMonitor(self);
    if (self.watch[target].contains(.analog)) try requestAnalog(self);
    try wake(self, target, before, dest.bit(0));
    if (self.watch[target].contains(.vpi)) if (self.vpi_change) |f| f(self, target);
}

/// VAMS §8.5: "the implicit D2A event ... is created when a digital variable to
/// which an analog block is implicitly sensitive changes value". §8.5.3.7 then
/// processes the macro-process in region 3b, after every region-1..3 event of
/// the tick, and once however many inputs moved.
fn requestAnalog(self: *Run) Error!void {
    if (self.analog_pending) return;
    self.analog_pending = true;
    _ = self.scheduler.schedule(.analog, @import("root.zig").analog_payload) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
}

/// §17.1.3: "the entire argument list is displayed at the end of the time
/// step". One event however many watched values moved, and however often —
/// a value that changes and changes back within the step still "changes
/// value", so it still prints, with the settled values.
fn requestMonitor(self: *Run) Error!void {
    if (self.monitor == null or !self.monitor_on or self.monitor_pending) return;
    self.monitor_pending = true;
    try enqueueMonitor(self, .monitor_tick);
}

/// Resume every process suspended on `target` whose edge matches. Split out
/// of `store` because §5.10.4's `-> e` resumes without publishing anything:
/// a named event has no value for a change to be detected in.
fn wake(self: *Run, target: u32, before: Int.Bit, after: Int.Bit) Error!void {
    if (self.waiters.items.len == 0) return;
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
        _ = try enqueue(self, .{ .run_process = w.pc }, null, false);
        i = 0;
    }
}

/// §7.9: a net's value is the wired-logic resolution of ALL its drivers, so
/// it is recomputed whole on every driver update and published through
/// `store` — the same path a variable write takes, which is what lets
/// `@(posedge w)` resume on a net.
pub fn resolve(self: *Run, net: u32) Error!void {
    const n = self.nets[net];
    const current = self.values[n.slot];
    // ponytail: one bit at a time. The tables are 4x4 over two planes, so a
    // plane-parallel fold is possible; do it when a wide bus resolves often
    // enough to show up, not before.
    const tables = wiredLogic(n.kind);
    var floating: u32 = 0;
    for (0..n.resolved.width) |i| {
        const at: u32 = @intCast(i);
        var bit: Int.Bit = .z;
        if (tables) {
            // Each driver collapses on its own first, so that a strength
            // that suppresses a value (`highz0` holding 0) drops out of the
            // fold entirely instead of voting as a 0.
            for (n.drivers) |d| bit = wired(n.kind, bit, contribution(self.drivers[d], at).collapse());
            if (bit == .z) bit = undriven(n.kind);
        } else {
            var acc: Signal = .{};
            for (n.drivers) |d| acc = acc.combine(contribution(self.drivers[d], at));
            // §7.9/§7.10: a `trireg` with no driver asserting anything is in
            // the capacitive state, and what it asserts there is the charge
            // it last held, at its charge strength. Checked before the net
            // type's own pull so that a driven trireg never sees it.
            if (n.kind == .trireg and acc.none()) {
                acc = .of(current.bit(at), n.charge, n.charge);
                floating += 1;
            }
            bit = acc.combine(netPull(n.kind)).collapse();
        }
        setBit(n.resolved, at, bit);
    }
    if (n.kind == .trireg) try chargeState(self, net, floating == n.resolved.width);
    // A.2.1.3's `[ delay3 ]` delays the net's own transition, so it sits
    // between the resolution and the publish — every driver has already
    // been folded in by the time it applies.
    if (n.delay.present) {
        const st = &self.nets[net].transition;
        if (try schedule(self, self.values[n.slot], false, n.resolved, false, st))
            st.in_flight = try enqueue(self, .{ .net_update = net }, n.delay.to(st.target.bit(0)), false);
        return;
    }
    try store(self, n.slot, n.resolved.planes);
}

/// What one driver asserts on bit `at`: its value at its strengths, or §7.10.2's
/// H/L when a gate's control is unknown.
fn contribution(dr: @import("net.zig").Driver, at: u32) Signal {
    const b = dr.current.bit(at);
    return if (dr.or_z) .orZ(b, dr.s0, dr.s1) else .of(b, dr.s0, dr.s1);
}

/// §6.1.3's inertial rule, shared by a driver's delay and a net's: "if the
/// value changes before the delay has elapsed, the scheduled event is
/// cancelled". Returns whether a new transition to `to` is needed, having
/// already cancelled whatever it displaced and recorded `to` as the target;
/// the caller schedules it and keeps the handle in `st.in_flight`.
///
/// False covers the two cases that make a pulse shorter than the delay
/// vanish rather than arrive late: the value is back to what is published,
/// and the value is what is already on its way.
fn schedule(self: *Run, from: Int.Literal, from_or_z: bool, to: Int.Literal, to_or_z: bool, st: *Inertial) Error!bool {
    const settled = if (st.in_flight != null) st.target else from;
    const settled_or_z = if (st.in_flight != null) st.or_z else from_or_z;
    if (std.mem.eql(u64, settled.planes, to.planes) and settled_or_z == to_or_z) return false;
    if (st.in_flight) |h| try cancel(self, h);
    st.in_flight = null;
    if (st.target.planes.len != to.planes.len) st.target.planes = try self.arena.alloc(u64, to.planes.len);
    @memcpy(st.target.planes, to.planes);
    st.target.width = to.width;
    st.target.signed = to.signed;
    st.or_z = to_or_z;
    return true;
}

/// Cancel one queued event and give its row back.
fn cancel(self: *Run, h: Handle) Error!void {
    const row = self.scheduler.payloadOf(h) orelse return;
    _ = self.scheduler.cancel(h) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
    try self.free_rows.append(self.arena, row);
}

/// §3.8 charge decay. The countdown restarts on each ENTRY into the
/// capacitive state, so this is called with the state and acts on the edge.
///
/// ponytail: whole-net, not per-bit. A vector `trireg` with some bits driven
/// and some floating decays all of them together; per-bit needs one
/// countdown per bit, which no fixture asks for.
fn chargeState(self: *Run, net: u32, floating: bool) Error!void {
    const n = &self.nets[net];
    const was = n.capacitive;
    n.capacitive = floating;
    // Leaving the state, or entering one that never decays, only has to
    // cancel whatever countdown was running.
    if (was == floating) return;
    if (n.decay_event) |h| try cancel(self, h);
    n.decay_event = null;
    if (!floating) return;
    const after = n.decay orelse return;
    n.decay_event = try enqueue(self, .{ .decay = net }, after, false);
}

/// What a gate driver contributes: §7.8.5's one output bit, and whether it is
/// §7.10.2's H/L.
fn gateValue(self: *Run, scratch: std.mem.Allocator, g: Gate, or_z: *bool) Error!Int.Literal {
    // One scratch list per evaluation, which `execute` resets each
    // instruction — the point is to keep `gateBit` a pure function of the
    // input bits, where §7.8.5's tables can be read straight off.
    var bits: std.ArrayList(Int.Bit) = .empty;
    for (g.ins) |in| try bits.append(scratch, (try eval(self, scratch, in, 1)).bit(0));
    const out = try filled(scratch, 1, false, .z);
    const o = gateBit(g.kind, bits.items);
    setBit(out, 0, o.bit);
    or_z.* = o.or_z;
    return out;
}

/// What a `Bridge` driver contributes: its window, z everywhere else.
fn window(self: *Run, scratch: std.mem.Allocator, b: Bridge, width: u32) Error!Int.Literal {
    const out = try filled(scratch, width, false, .z);
    const from = self.values[b.src];
    for (0..b.width) |i| setBit(out, b.dst_lo + @as(u32, @intCast(i)), from.bit(b.src_lo + @as(u32, @intCast(i))));
    return out;
}

// ---- process control and scheduling (§9.7.1, §17.1.3, 1364 §10.3) -----------

/// The run-time counterpart of `checkDelay`, in the module's precision.
fn delayOf(self: *Run, scratch: std.mem.Allocator, e: Ast.ExprId, tok: u32) Error!u64 {
    const ex = &self.file.exprs;
    if (ex.tag(e) == .real_literal) {
        return self.scale.?.realDelay(ex.realValue(e)) catch |err|
            return self.fail(tok, "digital delay cannot be represented: {t}", .{err});
    }
    const value = try eval(self, scratch, e, 0);
    // §9.7.1 leaves an x/z delay undefined; zero is the reading that keeps
    // the process running rather than losing it.
    if (value.hasUnknown()) return 0;
    if (value.width > 64) return self.exprFail(e, "delay values wider than 64 bits are not implemented");
    return (if (value.signed) self.scale.?.signedDelay(value.asInt().?) else self.scale.?.unsignedDelay(value.values()[0])) catch |err|
        return self.fail(tok, "digital delay cannot be represented: {t}", .{err});
}

fn suspendOn(self: *Run, e: Ast.ExprId, resume_pc: u32) Error!void {
    const ex = &self.file.exprs;
    const edge: Edge = switch (ex.tag(e)) {
        .event_or => {
            try suspendOn(self, ex.lhs(e), resume_pc);
            return suspendOn(self, ex.rhs(e), resume_pc);
        },
        .event_posedge => .posedge,
        .event_negedge => .negedge,
        else => .any,
    };
    const watched = if (edge == .any) e else ex.lhs(e);
    try self.waiters.append(self.arena, .{ .slot = try self.slot(watched), .edge = edge, .pc = resume_pc });
}

/// The `.monitor` region at the CURRENT time — §17.1.2/§17.1.3's "end of
/// the timestep", which the scheduler already orders after active,
/// inactive and NBA.
fn enqueueMonitor(self: *Run, item: Pending) Error!void {
    const at = try claim(self, item);
    self.pending.items[at].handle = self.scheduler.schedule(.monitor, at) catch |e|
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
}

/// A row for `item`: a recycled one when there is one. A `.write` value is
/// copied into the row's own planes, so the caller's may be scratch.
fn claim(self: *Run, item: Pending) Error!u32 {
    const at: u32 = self.free_rows.pop() orelse blk: {
        if (self.pending.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital events", .{});
        try self.pending.append(self.arena, .{ .item = item });
        break :blk @intCast(self.pending.items.len - 1);
    };
    const row = &self.pending.items[at];
    row.item = item;
    switch (item) {
        .write => |w| {
            if (row.buf.len < w.value.planes.len) row.buf = try self.arena.alloc(u64, w.value.planes.len);
            const planes = row.buf[0..w.value.planes.len];
            @memcpy(planes, w.value.planes);
            row.item.write.value.planes = planes;
        },
        .run_process, .strobe, .monitor_tick, .drive, .net_update, .decay => {},
    }
    return at;
}

/// IEEE 1364-2005 §10.3's `disable`, which §1.1 makes part of this
/// language: it "terminates the activity" of a named block, and "execution
/// continues with the statement following the block".
///
/// A suspended process is nothing but a resumption point, so the first
/// sentence is: drop every resumption whose pc lands inside the block —
/// the waiters it parked on an event, and the scheduled `.run_process`
/// rows a `#` delay left behind. The second sentence is then one enqueue at
/// `end`, and only when something WAS cancelled: a block nobody is
/// suspended inside has no activity to terminate, and resuming a process
/// that is not there would run the tail of a body twice.
///
/// ponytail: an NBA update already scheduled from inside the block still
/// lands. It is a write the block completed before it was disabled, not
/// activity of its own, and no fixture measures the alternative.
///
/// The executing process has no queued resumption to retire. Its dispatch
/// arm separately jumps past a containing target block (IEEE1364 §10.3);
/// this helper handles only suspended activity in that target range.
fn disableRange(self: *Run, start: u32, end: u32) Error!void {
    var hit = false;
    var i = self.waiters.items.len;
    while (i != 0) {
        i -= 1;
        const at = self.waiters.items[i].pc;
        if (at >= start and at < end) {
            _ = self.waiters.swapRemove(i);
            hit = true;
        }
    }
    // Only live rows: a free row's handle is stale, and so is the handle of
    // the row now dispatching, which the scheduler released before returning.
    for (self.pending.items) |row| switch (row.item) {
        .run_process => |at| if (at >= start and at < end and self.scheduler.payloadOf(row.handle) != null) {
            try cancel(self, row.handle);
            hit = true;
        },
        .write, .strobe, .monitor_tick, .drive, .net_update, .decay => {},
    };
    if (hit) _ = try enqueue(self, .{ .run_process = end }, null, false);
}

pub fn enqueue(self: *Run, item: Pending, delay: ?u64, nba: bool) Error!Handle {
    const at = try claim(self, item);
    const h = (if (delay) |d|
        self.scheduler.scheduleAfter(d, if (nba) .nba else .inactive, at) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital timing failure: {t}", .{e})
    else
        self.scheduler.schedule(if (nba) .nba else .active, at) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e}));
    self.pending.items[at].handle = h;
    return h;
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

// ---- the interpreter loop (A.6.5, §6.1, §8.5.3.3) ---------------------------

pub fn execute(self: *Run, scratch_arena: *std.heap.ArenaAllocator, start: u32) Error!void {
    var pc = start;
    var restarted = false;
    // §6.2.2: every name this body reads is its own instance's. A body
    // never crosses an instance boundary, so one read at entry covers the
    // whole dispatch — including a resumption landing mid-body.
    self.scope = self.code_scope.items[start];
    while (true) {
        // Each instruction completes its copies/captures before scratch is
        // reused; an untimed loop therefore retains no iteration temporaries.
        _ = scratch_arena.reset(.retain_capacity);
        const scratch = scratch_arena.allocator();
        switch (self.code.items[pc]) {
            .stop => return,
            .assign => |s| {
                // §3.9: an out-of-range or X/Z index names no element, so
                // the write is discarded rather than landing somewhere.
                if (try address(self, scratch, s.target)) |target| {
                    const dest = self.values[target];
                    const rhs = try eval(self, scratch, s.value, dest.width);
                    const value = try normalize(scratch, rhs, .{ .width = dest.width, .signed = rhs.signed });
                    if (s.nonblocking) _ = try enqueue(self, .{ .write = .{ .target = target, .value = value } }, null, true) else try store(self, target, value.planes);
                }
                pc += 1;
                continue;
            },
            .delay => |s| {
                _ = try enqueue(self, .{ .run_process = pc + 1 }, try delayOf(self, scratch, s.amount, s.tok), false);
                return;
            },
            .task => |s| {
                self.pc = pc;
                switch (s.task) {
                    .show => |sh| try display.display(self, s.args, scratch, sh),
                    // §17.1.2: the arguments are NOT captured, the call is.
                    // What it reports is the value at the end of the timestep,
                    // so evaluation waits for the `.monitor` region.
                    .strobe => |sh| try enqueueMonitor(self, .{ .strobe = .{ .args = s.args, .show = sh, .scope = self.scope, .pc = pc } }),
                    // §17.1.3 one standing monitor: a new one replaces the
                    // old, watch list and all. Its first line is at the end
                    // of this step like every other, so it shows settled
                    // values.
                    .monitor => |sh| {
                        for (self.monitor_slots.items) |at| self.watch[at].remove(.monitor);
                        self.monitor_slots.clearRetainingCapacity();
                        for (s.args) |arg| if (arg != .none and self.file.exprs.tag(arg) != .str_literal)
                            try compile.sensitivity(self, arg, &self.monitor_slots);
                        for (self.monitor_slots.items) |at| self.watch[at].insert(.monitor);
                        self.monitor = .{ .args = s.args, .show = sh, .scope = self.scope, .pc = pc };
                        try requestMonitor(self);
                    },
                    // "$monitoron shall produce a display immediately after
                    // it is invoked, regardless of whether a value change has
                    // taken place" — so whether it was already on is not asked.
                    // Turning it off is silent.
                    .monitor_enable => |on| {
                        self.monitor_on = on;
                        if (on) try display.monitorPrint(self, scratch);
                    },
                    .timeformat => if (s.args.len == 0) {
                        self.time_format = .{ .units = self.finest };
                    } else {
                        const ex = &self.file.exprs;
                        const units = try eval(self, scratch, s.args[0], 0);
                        const precision = try eval(self, scratch, s.args[1], 0);
                        const width = try eval(self, scratch, s.args[3], 0);
                        self.time_format = .{
                            .units = std.math.lossyCast(i32, units.asInt() orelse 0),
                            .precision = std.math.lossyCast(u32, precision.asInt() orelse 0),
                            .suffix = self.file.str(ex.strOf(s.args[2])),
                            .width = std.math.lossyCast(u32, width.asInt() orelse 0),
                        };
                    },
                    .readmem => |radix| try display.readMemory(self, scratch, s.args, radix),
                    .finish => {
                        // An x/z level has no verbosity to select; the fullest
                        // report is the reading that loses nothing.
                        const verbose = s.args.len == 0 or ((try eval(self, scratch, s.args[0], 0)).asInt() orelse 1) != 0;
                        if (verbose) {
                            const start_byte = self.starts[s.tok];
                            const loc = self.bag.locate(.{ .start = start_byte, .end = start_byte }, null);
                            try self.out.print("$finish at tick {d}, {s} byte {d}\n", .{ self.scheduler.now, self.bag.fileName(loc.file), loc.offset });
                        }
                        self.scheduler.finish();
                        return;
                    },
                }
                pc += 1;
                continue;
            },
            .jump => |target| {
                pc = target;
                continue;
            },
            .wait_event => |e| return suspendOn(self, e, pc + 1),
            // §9.7.5 the implicit list is a plain `or` of value changes.
            .wait_slots => |slots| {
                for (slots) |s| try self.waiters.append(self.arena, .{ .slot = s, .edge = .any, .pc = pc + 1 });
                return;
            },
            // A.6.5 a `wait` that is already satisfied does not suspend at
            // all; one that is not comes back to THIS pc, not the next, so
            // the level is re-tested rather than the edge trusted.
            .wait_level => |s| {
                if ((try eval(self, scratch, s.cond, 0)).truth() == .one) {
                    pc += 1;
                    continue;
                }
                for (s.slots) |at| try self.waiters.append(self.arena, .{ .slot = at, .edge = .any, .pc = pc });
                return;
            },
            // §8.5.3.3 "computes the right-hand side value using the
            // current values, then causes the executing process to be
            // suspended". Both halves of that sentence are here.
            .sample => |s| {
                const a = self.file.stmt(s.statement).assign;
                const tok = self.file.stmtTok(s.statement);
                // The parked value is the target's width, and the target
                // may be an array element, so the width comes from the
                // lvalue's base slot rather than from `address` — which
                // §8.5.3.3 says is not resolved until the process resumes.
                const width = self.values[try self.baseSlot(a.target)].width;
                const rhs = try eval(self, scratch, a.value, width);
                // The cell's own planes, not scratch: the value has to
                // outlive this dispatch, which is the whole point of parking
                // it. The width is the site's, so the planes are sized once.
                const parked = try normalize(scratch, rhs, .{ .width = width, .signed = rhs.signed });
                const cell = &self.holds.items[s.cell];
                if (cell.planes.len != parked.planes.len) cell.planes = try self.arena.alloc(u64, parked.planes.len);
                @memcpy(cell.planes, parked.planes);
                cell.width = parked.width;
                cell.signed = parked.signed;
                cell.sized = parked.sized;
                if (a.nonblocking) {
                    // §8.5.3.4 the process does not suspend; the write is
                    // one more NBA update, delayed if the control was one.
                    if (try address(self, scratch, a.target)) |target|
                        _ = try enqueue(
                            self,
                            .{ .write = .{ .target = target, .value = self.holds.items[s.cell] } },
                            if (a.timing_is_delay) try delayOf(self, scratch, a.timing, tok) else null,
                            true,
                        );
                    pc += 1;
                    continue;
                }
                if (a.timing_is_delay)
                    _ = try enqueue(self, .{ .run_process = pc + 1 }, try delayOf(self, scratch, a.timing, tok), false)
                else
                    try suspendOn(self, a.timing, pc + 1);
                return;
            },
            // §8.5.3.3 "the values at the time the process resumes are used
            // to determine the target(s)" — so the address is resolved now,
            // even though the value was fixed before the suspension.
            .deposit => |s| {
                const a = self.file.stmt(s.statement).assign;
                // §3.9: an out-of-range or X/Z index names no element, so
                // the write is discarded rather than landing somewhere.
                if (try address(self, scratch, a.target)) |target|
                    try store(self, target, self.holds.items[s.cell].planes);
                pc += 1;
                continue;
            },
            // §5.10 an event has "no time duration": the resumed processes
            // are scheduled in the active region of this same timestep, and
            // execution of the triggering process continues meanwhile.
            .trigger => |at| {
                try wake(self, at, .x, .x);
                pc += 1;
                continue;
            },
            // §6.1: drive this assignment's own value, resolve the net from
            // every driver of it, then suspend on the operands. The
            // resumption point is this same pc, so a change re-drives.
            .continuous => |at| {
                const d = self.drivers[at];
                // A driver's expression is written in the instance that
                // wrote the assignment — for a port connection that is the
                // PARENT of the net it feeds, so it is the driver's scope
                // and not the dispatch's that resolves its names.
                self.scope = d.scope;
                var or_z = false;
                const value = if (d.bridge) |b|
                    try window(self, scratch, b, d.current.width)
                else if (d.gate) |g|
                    try gateValue(self, scratch, g, &or_z)
                else if (d.pull) |b|
                    try filled(scratch, d.current.width, false, b)
                else blk: {
                    const rhs = try eval(self, scratch, d.value, d.current.width);
                    break :blk try normalize(scratch, rhs, .{ .width = d.current.width, .signed = rhs.signed });
                };
                // A.6.1's `[ delay3 ]` delays what this driver CONTRIBUTES,
                // not what the net shows: the other drivers are unaffected
                // and the net re-resolves when the delayed value lands.
                if (d.delay.present) {
                    const st = &self.drivers[at].transition;
                    if (try schedule(self, d.current, d.or_z, value, or_z, st)) {
                        const delay = if (d.gate == null and d.bridge == null and d.pull == null)
                            d.delay.continuous(d.current, st.target)
                        else
                            d.delay.to(st.target.bit(0));
                        st.in_flight = try enqueue(self, .{ .drive = at }, delay, false);
                    }
                } else {
                    @memcpy(d.current.planes, value.planes);
                    self.drivers[at].or_z = or_z;
                    try resolve(self, d.net);
                }
                for (d.sensitivity) |s| try self.waiters.append(self.arena, .{ .slot = s, .edge = .any, .pc = pc });
                return;
            },
            .disable_block => |b| {
                try disableRange(self, b.start, b.end);
                // IEEE1364 §10.3: self/ancestor disable resumes AFTER the
                // target block, while a sibling disable continues here.
                pc = if (pc >= b.start and pc < b.end) b.end else pc + 1;
                continue;
            },
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
                const value = try eval(self, scratch, s.condition, 0);
                pc = if (value.truth() == .one) pc + 1 else s.otherwise;
                continue;
            },
            .repeat_start => |s| {
                const value = try eval(self, scratch, s.count, 0);
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
                const value = try evalContext(self, scratch, case.scrutinee, s.ty);
                pc = s.fallback;
                search: for (case.arms, 0..) |arm, i| {
                    for (arm.labels) |label| {
                        const item = try evalContext(self, scratch, label, s.ty);
                        if (caseMatches(case.kind, value, item)) {
                            pc = self.case_targets.items[s.targets + i];
                            break :search;
                        }
                    }
                }
                continue;
            },
        }
    }
}

// ---- tests ------------------------------------------------------------------

test "continuous vector delay audit_assignment_pending_same_value" {
    try expectRun(
        \\// IEEE1364-2005 §6.1.3(b): cancel pending propagation only if the newly
        \\// evaluated RHS differs from the pending value. At10 a rises, scheduling1
        \\// at15. At12 b rises too, but(a|b) is still1: delivery remains15, not17.
        \\//! inherited IEEE 1364-2005 6.1.3
        \\`timescale 1ns/1ns
        \\module audit_assignment_pending_same_value;
        \\  reg a, b;
        \\  wire y;
        \\  assign #5 y = a | b;
        \\  initial begin
        \\    a = 0; b = 0;
        \\    #10 a = 1;
        \\    #2 b = 1;
        \\    #2 $display("before=%b", y);
        \\    #2 $display("original_deadline_passed=%b", y);
        \\    $finish(0);
        \\  end
        \\endmodule
    ,
        \\before=0
        \\original_deadline_passed=1
        \\
    );
}

test "§3.5.1 an unsized x/z constant fills its context, a known top digit does not" {
    try expectRun(
        \\module m;
        \\reg [39:0] w;
        \\initial begin
        \\  w = 'hx; $display("%h", w);
        \\  w = 'hz3; $display("%h", w);
        \\  w = 'h3x; $display("%h", w);
        \\  $display("%b", 'bz);
        \\end
        \\endmodule
    , "xxxxxxxxxx\nzzzzzzzzz3\n000000003x\nzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n");
}

test "wait constant true and constant expression continue immediately" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\initial begin
        \\  wait (1) $display("literal t=%0d", $time);
        \\  wait ((2 + 3) == 5) $display("expression t=%0d", $time);
        \\  wait (1);
        \\  $display("null body t=%0d", $time);
        \\end
        \\endmodule
    , "literal t=0\nexpression t=0\nnull body t=0\n");
}

test "wait constant false suspends without blocking other processes" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\initial begin
        \\  $display("armed");
        \\  wait (0) $display("wrong literal");
        \\  $display("wrong continuation");
        \\end
        \\initial begin
        \\  wait (7 == 8) $display("wrong expression");
        \\end
        \\initial begin
        \\  #2 $display("other t=%0d", $time);
        \\  $finish(0);
        \\end
        \\endmodule
    , "armed\nother t=2\n");
}

test "wait dependent condition still retests and resumes at true level" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer count;
        \\initial begin
        \\  count = 0;
        \\  wait (count == 2) $display("resumed count=%0d t=%0d", count, $time);
        \\end
        \\initial begin
        \\  #1 count = 1;
        \\  #1 count = 2;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "resumed count=2 t=2\n");
}

test "clog2 scans arbitrary-width unsigned bit patterns" {
    try expectRun(
        \\module m;
        \\reg [64:0] wide;
        \\reg [128:0] wider;
        \\reg signed [128:0] signed_wide;
        \\reg [256:0] many;
        \\initial begin
        \\  wide = 65'd1 << 64;
        \\  wider = 129'd1 << 128;
        \\  signed_wide = wider;
        \\  many = 257'd1 << 256;
        \\  $display("%0d %0d %0d %0d", $clog2(wide), $clog2(wider), $clog2(signed_wide), $clog2(many));
        \\  $display("%0d %0d %0d", $clog2(wide + 65'd1), $clog2(wider + 129'd1), $clog2(many + 257'd1));
        \\  $display("%0d %0d %0d", $clog2(wide - 65'd1), $clog2(wider - 129'd1), $clog2(many - 257'd1));
        \\  $display("%0d %0d %0d %0d", $clog2(257'd0), $clog2(257'd1), $clog2(257'd2), $clog2(257'd3));
        \\  $display("%0d %0d %0d", $clog2(32'shffffffff), $clog2(64'h8000000000000001), $clog2(0) - 1);
        \\end
        \\endmodule
    , "64 128 128 256\n65 129 257\n64 128 256\n0 0 1 2\n32 64 -1\n");
}

test "clog2 limb scan includes every limb and preserves unknown policy" {
    var planes: [10]u64 = @splat(0);
    const value: Int.Literal = .{ .width = 257, .signed = false, .sized = true, .planes = &planes };
    try std.testing.expectEqual(@as(u64, 0), integerCeilingLog2(value));
    for (0..257) |bit| {
        @memset(&planes, 0);
        planes[bit / 64] = @as(u64, 1) << @intCast(bit % 64);
        try std.testing.expectEqual(@as(u64, @intCast(bit)), integerCeilingLog2(value));
        if (bit != 0) {
            planes[0] |= 1;
            try std.testing.expectEqual(@as(u64, @intCast(bit + 1)), integerCeilingLog2(value));
        }
    }
    planes[5] = 1;
    try std.testing.expectEqual(@as(u64, 0), integerCeilingLog2(value));
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

test "a continuous assignment drives its net and re-evaluates on every operand" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire [1:0] w;
        \\assign w = {a, a & b};
        \\initial begin
        \\  a = 0; b = 0;
        \\  #1 $display("00 %b", w);
        \\  a = 1;
        \\  #1 $display("10 %b", w);
        \\  b = 1;
        \\  #1 $display("11 %b", w);
        \\  $finish(0);
        \\end
        \\endmodule
    , "00 00\n10 10\n11 11\n");
}

test "a net resolution resumes event waiters through the same write path" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\wire w;
        \\reg [1:0] hits;
        \\assign w = a;
        \\initial begin a = 0; hits = 0; end
        \\always @(posedge w) begin hits = hits + 1; $display("net posedge %b", hits); end
        \\initial begin #5 a = 1; #5 a = 0; #5 a = 1; #5 $finish(0); end
        \\endmodule
    , "net posedge 01\nnet posedge 10\n");
}

test "a delayed continuous assignment is inertial and swallows a short pulse" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\wire y;
        \\assign #(3, 7) y = a;
        \\initial begin
        \\  a = 0;
        \\  #10 #0 $display("t10 %b", y);
        \\  a = 1; #1 a = 0;
        \\  #5 #0 $display("pulse_gone %b", y);
        \\  a = 1;
        \\  #2 #0 $display("t18 %b", y);
        \\  #1 #0 $display("t19 %b", y);
        \\  a = 0;
        \\  #6 #0 $display("t25 %b", y);
        \\  #1 #0 $display("t26 %b", y);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
    // The 1 at t=11 would have landed at 14; the 0 at t=12 cancels it and is
    // itself the value already published, so nothing happens at all. The rise
    // at t=16 lands at 19 and the fall at t=19 lands at 26 — the two delays are
    // chosen by the value transitioned TO, not by the direction of the source.
        \\t10 0
        \\pulse_gone 0
        \\t18 0
        \\t19 1
        \\t25 1
        \\t26 0
        \\
    );
}

test "a trireg holds its charge for the decay time and then gives up" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg d;
        \\trireg (large) #(0, 0, 20) c;
        \\trireg forever_c;
        \\assign c = d, forever_c = d;
        \\initial begin
        \\  d = 1;
        \\  #5 d = 1'bz;
        \\  #19 $display("t24 %b %b", c, forever_c);
        \\  #2 $display("t26 %b %b", c, forever_c);
        \\  d = 0; #1 d = 1'bz;
        \\  #19 $display("restarted %b %b", c, forever_c);
        \\  #1000 $display("late %b %b", c, forever_c);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
    // Released at t=5, so the decay is at t=25 — sampled at 24 and 26 and never
    // AT it, because what a sample in the same timestep as the decay sees is an
    // intra-timestep ordering this pins nothing about. The countdown then
    // RESTARTS from the second release at t=28, which is what "restarted" is
    // for: a decay measured from the FIRST release would have fired by t=46.
        \\t24 1 1
        \\t26 x 1
        \\restarted 0 0
        \\late x 0
        \\
    );
}

test "unpacked array elements are addressed, and an out-of-range index reads X" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [7:0] mem [5:2];
        \\integer i;
        \\initial begin
        \\  for (i = 2; i < 6; i = i + 1) mem[i] = i * 3;
        \\  mem[1] = 8'hff;
        \\  mem[4] <= 8'h0f;
        \\  $display("%b %b %b", mem[2], mem[5], mem[1]);
        \\  #1 $display("%b %b", mem[4], mem[1'bx]);
        \\  $finish(0);
        \\end
        \\endmodule
    , "00000110 00001111 xxxxxxxx\n00001111 xxxxxxxx\n");
}

test "§9.7.1 a real delay rounds to the precision instead of truncating to the unit" {
    // `#0.5` under 10ns/100ps is 50 precision units — half a time unit, not
    // zero. A runner that truncated would print `0 0`, and one that ignored
    // the fraction would print `0 0` too; only rounding gives 1.
    try expectRun(
        \\`timescale 10ns/100ps
        \\module m; initial begin #0.5 $display("%0d %g", $time, $realtime); end endmodule
        \\
    , "1 0.5\n");
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

test "disable terminates a named block and resumes after it" {
    // Both halves of IEEE 1364 §10.3's sentence, and they are separable:
    // a `disable` that only cancelled would print 0001, and one that only
    // resumed would let the block's own `#4` write 0010 land first.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [3:0] r;
        \\initial begin
        \\  r = 4'b0001;
        \\  begin : work
        \\    #4 r = 4'b0010;
        \\  end
        \\  r = 4'b0100;
        \\end
        \\initial begin
        \\  #2 disable work;
        \\  #4 $display("after %b", r);
        \\  $finish(0);
        \\end
        \\endmodule
    , "after 0100\n");
}

test "disable self and ancestor skip the active target remainder" {
    try expectRun(
        \\module m;
        \\integer r;
        \\initial begin
        \\  r=0;
        \\  begin : outer
        \\    begin : inner
        \\      r=1; disable inner; r=99;
        \\    end
        \\    r=r+2;
        \\  end
        \\  $display("inner=%0d",r);
        \\  begin : ancestor
        \\    begin : descendant
        \\      r=1; disable ancestor; r=99;
        \\    end
        \\    r=88;
        \\  end
        \\  r=r+4; $display("ancestor=%0d",r);
        \\end
        \\endmodule
    , "inner=3\nancestor=5\n");
}

test "disable loop ancestor after suspension leaves unrelated processes alive" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer count,tail,resumed,sibling;
        \\initial begin
        \\  count=0; tail=0; resumed=0;
        \\  begin : stop_loop
        \\    repeat(3) begin
        \\      #1; count=count+1;
        \\      if(count==2) disable stop_loop;
        \\      tail=tail+1;
        \\    end
        \\  end
        \\  resumed=1;
        \\end
        \\initial begin sibling=0; #3; sibling=1; end
        \\initial begin
        \\  #4; $display("loop=%0d tail=%0d resumed=%0d sibling=%0d",count,tail,resumed,sibling);
        \\end
        \\endmodule
    , "loop=2 tail=1 resumed=1 sibling=1\n");
}

test "disable self allows later reentry and inactive sibling stays inactive" {
    try expectRun(
        \\module m;
        \\integer count;
        \\initial begin
        \\  count=0;
        \\  repeat(2) begin : work
        \\    count=count+1; disable work; count=99;
        \\  end
        \\  disable work;
        \\  $display("reentry=%0d",count);
        \\end
        \\endmodule
    , "reentry=2\n");
}

test "finish verbosity reports exact local precision ticks and mapped source" {
    const source = "`timescale 1ns/1ps\nmodule m; initial #1 $finish; endmodule";
    const offset = std.mem.indexOf(u8, source, "$finish").?;
    var expected: [128]u8 = undefined;
    try expectRun(source, try std.fmt.bufPrint(&expected, "$finish at tick 1000, <digital> byte {d}\n", .{offset}));
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

test "repeat accepts all 64 count bits and finish stops without an iteration clamp" {
    try expectRun("module m; initial repeat(64'hffffffffffffffff) begin $display(\"first\"); $finish(0); end endmodule", "first\n");
    try expectRun("module m; integer i; initial begin i=0; while(i<70001) i=i+1; $display(\"%b\",i); end endmodule", "00000000000000010001000101110001\n");
}
