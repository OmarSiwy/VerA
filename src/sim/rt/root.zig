//! The runtime a `vera --emit-exe design.v` executable links.
//!
//! In: the emitted design (`digital/emit.zig`): its initial values, its
//! static fan-out, its time-0 process order, and one function per process.
//! Out: its IEEE 1364 §17 transcript on stdout, exit 0; or a diagnostic on
//! stderr, exit 1.
//!
//! `State` is the interpreter's queue discipline with the interpreter taken
//! out: the same §11 scheduler, the same event-control waiter lists (§9.7,
//! §5.10.1), the same continuous-assignment fan-out (§6.1) and the same
//! nonblocking update rows (§9.2.2), so a native process wakes and is woken
//! in exactly `vera --run`'s order. Only the process bodies are compiled.
//!
//! `interpret` is the executable of a design `digital/emit.zig` did not make
//! native: the embedded source through the interpreter, exactly `vera --run`.
const std = @import("std");
const diag = @import("diag");
const digital = @import("../digital/root.zig");
const Scheduler = @import("../scheduler.zig").Scheduler;
pub const Scale = @import("../time.zig").Scale;
pub const fmt = @import("../fmt.zig");
pub const logic = @import("logic.zig");
const Int = @import("frontend").Integer;
const W = logic.W;
const Bit = logic.Bit;

test {
    _ = logic;
    std.testing.refAllDecls(State);
}

/// `vera --run` of `source` inside the executable: its transcript on stdout,
/// its diagnostics on stderr, and `vera --run`'s exit status. The names in
/// `opts` resolve against the working directory the executable runs in.
pub fn interpret(init: std.process.Init, opts: digital.Options, source: []const u8) u8 {
    const io = init.io;
    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [1 << 12]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    defer stderr.interface.flush() catch {};
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    var run_opts = opts;
    run_opts.io = io;
    const code: u8 = if (digital.run(arena, source, run_opts, &bag, &stdout.interface)) 0 else |e| blk: {
        if (e != error.DigitalFailed) stderr.interface.print("error: digital execution failed: {t}\n", .{e}) catch {};
        break :blk 1;
    };
    stdout.interface.flush() catch return 1;
    if (!bag.isEmpty()) diag.render(&bag, &stderr.interface, .{}) catch {};
    return code;
}

/// A native design's static half, emitted as constants.
pub const Design = struct {
    /// Every slot's initial value, one word per plane (`Run.values`).
    v: []const u64,
    x: []const u64,
    /// `Run.fan_start`/`Run.fan`: the continuous drivers reading each slot.
    fan_start: []const u32,
    fan: []const u32,
    /// `Run.code.len`: the pc space `armed` covers.
    code_len: u32,
    /// `Run.repeats.len`: one counter per lexical `repeat` (§9.6).
    repeats: u32,
    /// `Run.pending`'s time-0 queue, as the pcs each process starts at.
    order: []const u32,
};

/// `exec.Edge`: §5.10.1 an edge is a change toward 1 or away from 1.
pub const Edge = enum(u2) {
    any,
    posedge,
    negedge,

    fn matches(self: Edge, before: Bit, after: Bit) bool {
        if (self == .any) return true;
        if (before == after) return false;
        return switch (self) {
            .posedge => before == .zero or after == .one,
            .negedge => before == .one or after == .zero,
            .any => unreachable,
        };
    }
};

pub const Error = error{Failed} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// `exec.Susp` without the task activation, which no native process has.
const Susp = struct { pc: u32, gen: u32, alive: bool };
const Term = struct { susp: u32, gen: u32, edge: Edge };
/// One §9.2.2 nonblocking update: the bits `m` of `slot` become `v`/`x`
/// when it matures, merged into the value the slot holds THEN.
const Nba = struct { slot: u32, v: u64, x: u64, m: u64 };
/// A scheduler payload with this bit is an `Nba` row; else it is a pc.
const nba_bit: u32 = 1 << 31;

/// `root.max_events_per_tick`.
const budget: u64 = @import("../digital/root.zig").max_events_per_tick;

pub const State = struct {
    gpa: std.mem.Allocator,
    v: []u64,
    x: []u64,
    sched: Scheduler,
    rows: std.ArrayList(Nba) = .empty,
    free_rows: std.ArrayList(u32) = .empty,
    susps: std.ArrayList(Susp) = .empty,
    free_susps: std.ArrayList(u32) = .empty,
    terms: []std.ArrayList(Term),
    fan_start: []const u32,
    fan: []const u32,
    armed: []bool,
    repeats: []u64,
    time_format: fmt.TimeFormat,
    budget_time: u64 = 0,
    budget_used: u64 = 0,
    stdout: std.Io.File.Writer,
    out: *std.Io.Writer,
    io: std.Io,
    buf: [1 << 16]u8,

    /// In place: `out` points into `self`. The time-0 queue is `d.order`.
    pub fn init(self: *State, init_: std.process.Init, d: *const Design, time_units: i32) Error!void {
        const gpa = std.heap.smp_allocator;
        self.* = .{
            .gpa = gpa,
            .v = try gpa.dupe(u64, d.v),
            .x = try gpa.dupe(u64, d.x),
            .sched = .init(gpa),
            .terms = try gpa.alloc(std.ArrayList(Term), d.v.len),
            .fan_start = d.fan_start,
            .fan = d.fan,
            .armed = try gpa.alloc(bool, d.code_len),
            .repeats = try gpa.alloc(u64, d.repeats),
            .time_format = .{ .units = time_units },
            .stdout = undefined,
            .out = undefined,
            .io = init_.io,
            .buf = undefined,
        };
        self.stdout = std.Io.File.stdout().writer(init_.io, &self.buf);
        self.out = &self.stdout.interface;
        @memset(self.terms, .empty);
        @memset(self.armed, false);
        @memset(self.repeats, 0);
        for (d.order) |pc| try self.run(pc, null);
    }

    /// The next process to dispatch, at the pc it resumes at; null once the
    /// queue is empty or `$finish` ran. Nonblocking updates are applied here.
    pub fn next(self: *State) Error!?u32 {
        while (self.sched.next()) |event| {
            // `Run.runUntil`'s zero-delay-loop guard, counted the same way.
            if (event.time != self.budget_time) {
                self.budget_time = event.time;
                self.budget_used = 0;
            }
            self.budget_used += 1;
            if (self.budget_used > budget)
                return self.fail("more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ budget, event.time });
            if (event.payload & nba_bit == 0) return event.payload;
            const at = event.payload & ~nba_bit;
            const row = self.rows.items[at];
            try self.free_rows.append(self.gpa, at);
            try self.put(row.slot, .{ .v = row.v, .x = row.x }, row.m);
        }
        return null;
    }

    /// Exit status, after flushing the transcript.
    pub fn exit(self: *State, failed: ?Error) u8 {
        const flushed = if (self.out.flush()) true else |_| false;
        if (failed) |e| if (e != error.Failed) self.say("digital execution failed: {t}", .{e});
        return if (failed == null and flushed) 0 else 1;
    }

    /// A run-time refusal in `vera --run`'s words (E1100), on stderr.
    pub fn fail(self: *State, comptime message: []const u8, args: anytype) Error {
        self.say(message, args);
        return error.Failed;
    }

    fn say(self: *State, comptime message: []const u8, args: anytype) void {
        self.out.flush() catch {};
        var buf: [512]u8 = undefined;
        var e = std.Io.File.stderr().writer(self.io, &buf);
        e.interface.print("error[E1100]: " ++ message ++ "\n", args) catch {};
        e.interface.flush() catch {};
    }

    pub inline fn get(self: *const State, slot: u32) W {
        return .{ .v = self.v[slot], .x = self.x[slot] };
    }

    /// `exec.store` of the bits `m` of `slot`: nothing happens unless the
    /// value changes; then every waiter it matches wakes.
    pub fn put(self: *State, slot: u32, a: W, m: u64) Error!void {
        const ov = self.v[slot];
        const ox = self.x[slot];
        const nv = (ov & ~m) | (a.v & m);
        const nx = (ox & ~m) | (a.x & m);
        if (nv == ov and nx == ox) return;
        self.v[slot] = nv;
        self.x[slot] = nx;
        try self.wake(slot, logic.low(.{ .v = ov, .x = ox }), logic.low(.{ .v = nv, .x = nx }));
    }

    /// §9.2.2: schedule the bits `m` of `slot` to become `a` in the NBA region.
    pub fn nba(self: *State, slot: u32, a: W, m: u64) Error!void {
        const row: Nba = .{ .slot = slot, .v = a.v, .x = a.x, .m = m };
        const at: u32 = if (self.free_rows.pop()) |i| blk: {
            self.rows.items[i] = row;
            break :blk i;
        } else blk: {
            try self.rows.append(self.gpa, row);
            break :blk @intCast(self.rows.items.len - 1);
        };
        _ = self.sched.schedule(.nba, at | nba_bit) catch |e| return self.schedFail(e);
    }

    /// Queue the process at `pc`: now (active), or `ticks` later (inactive).
    pub fn run(self: *State, pc: u32, after: ?u64) Error!void {
        _ = (if (after) |t|
            self.sched.scheduleAfter(t, .inactive, pc) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital timing failure: {t}", .{e})
        else
            self.sched.schedule(.active, pc) catch |e| return self.schedFail(e));
    }

    fn schedFail(self: *State, e: Scheduler.Error) Error {
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital scheduling failure: {t}", .{e});
    }

    /// `exec.wake`: the continuous drivers reading `slot` first, then the
    /// event controls in the order they suspended.
    pub fn wake(self: *State, slot: u32, before: Bit, after: Bit) Error!void {
        if (slot + 1 < self.fan_start.len) for (self.fan[self.fan_start[slot]..self.fan_start[slot + 1]]) |pc| if (self.armed[pc]) {
            self.armed[pc] = false;
            try self.run(pc, null);
        };
        const list = &self.terms[slot];
        var keep: usize = 0;
        for (list.items) |t| {
            const s = &self.susps.items[t.susp];
            if (s.gen != t.gen) continue;
            if (!t.edge.matches(before, after)) {
                list.items[keep] = t;
                keep += 1;
                continue;
            }
            const pc = s.pc;
            self.retire(t.susp);
            try self.run(pc, null);
        }
        list.shrinkRetainingCapacity(keep);
    }

    /// `exec.park`: suspend the running process, to resume at `pc`.
    pub fn park(self: *State, pc: u32) Error!u32 {
        const id = self.free_susps.pop() orelse blk: {
            try self.susps.append(self.gpa, .{ .pc = 0, .gen = 0, .alive = false });
            try self.free_susps.ensureTotalCapacity(self.gpa, self.susps.items.len);
            break :blk @as(u32, @intCast(self.susps.items.len - 1));
        };
        const s = &self.susps.items[id];
        s.pc = pc;
        s.alive = true;
        return id;
    }

    /// `exec.watch`: file one term of suspension `id` under `slot`.
    pub fn watch(self: *State, id: u32, slot: u32, edge: Edge) Error!void {
        const list = &self.terms[slot];
        if (list.items.len == list.capacity and list.capacity != 0) {
            var keep: usize = 0;
            for (list.items) |t| if (self.susps.items[t.susp].gen == t.gen) {
                list.items[keep] = t;
                keep += 1;
            };
            list.shrinkRetainingCapacity(keep);
            if (keep > list.capacity / 2) try list.ensureTotalCapacity(self.gpa, list.capacity * 2);
        }
        try list.append(self.gpa, .{ .susp = id, .gen = self.susps.items[id].gen, .edge = edge });
    }

    fn retire(self: *State, id: u32) void {
        const s = &self.susps.items[id];
        s.alive = false;
        s.gen +%= 1;
        self.free_susps.appendAssumeCapacity(id);
    }

    /// §17.7.1 `$time`: now, in the invoking module's unit.
    pub fn units(self: *const State, scale: Scale) u64 {
        return scale.unitsAt(self.sched.now);
    }

    /// `exec.delayOf` of an integral delay (§9.7.1): x/z reads as 0.
    pub fn ticks(self: *State, a: W, signed: bool, scale: Scale) Error!u64 {
        if (a.x != 0) return 0;
        return (if (signed) scale.signedDelay(@bitCast(a.v)) else scale.unsignedDelay(a.v)) catch |e|
            self.fail("digital delay cannot be represented: {t}", .{e});
    }

    /// §9.6 a `repeat` count (`exec` `.repeat_start`): x/z is 0 times.
    pub fn repeatCount(self: *State, a: W, comptime w: u32, comptime signed: bool) Error!u64 {
        if (a.x != 0) return 0;
        if (signed and logic.asInt(a, w, true).? < 0)
            return self.fail("negative repeat counts are not implemented; IEEE1364-2005 does not define this case explicitly", .{});
        return a.v;
    }

    /// §17.4.1 `$finish`: end the run after this process step.
    pub fn finish(self: *State, verbose: bool, file: []const u8, byte: u32) Error!void {
        if (verbose) try self.out.print("$finish at tick {d}, {s} byte {d}\n", .{ self.sched.now, file, byte });
        self.sched.finish();
    }

    fn literal(a: *const W, buf: *[2]u64, w: u32, signed: bool) Int.Literal {
        buf.* = .{ a.v, a.x };
        return .{ .width = w, .signed = signed, .sized = true, .planes = buf };
    }

    /// One `%b`/`%o`/`%h`/`%d` operand (§17.1.1.3).
    pub fn value(self: *State, a: W, w: u32, signed: bool, radix: fmt.Radix, width: ?u32) Error!void {
        var buf: [2]u64 = undefined;
        fmt.value(self.out, literal(&a, &buf, w, signed), radix, width) catch |e| return switch (e) {
            error.TooWide => unreachable, // a native operand is at most 64 bits
            error.WriteFailed => error.WriteFailed,
        };
    }

    /// One `%t` operand, in a module whose unit is 10^`unit_exp` s (§17.3).
    pub fn time(self: *State, a: W, w: u32, signed: bool, unit_exp: i32) Error!void {
        var buf: [2]u64 = undefined;
        try fmt.time(self.out, literal(&a, &buf, w, signed), self.time_format, unit_exp);
    }

    /// One `%s` or `%c` operand (§17.1.1.7).
    pub fn text(self: *State, a: W, w: u32, char: bool, width: ?u32) Error!void {
        var buf: [2]u64 = undefined;
        try fmt.text(self.out, literal(&a, &buf, w, false), char, width);
    }
};
