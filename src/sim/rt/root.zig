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
//! That is the `fifo` schedule. The `static` one keeps the queue only for
//! what needs it: a combinational node (a continuous assignment, an
//! `always @*`) is marked dirty when a bit it reads changes and every dirty
//! node runs in one `settle` event, in topological order; an `always @(event)`
//! whose body never suspends waits on a static per-slot watcher list, not on
//! a suspension record. Both are orders §11.4.1 leaves to the simulator.
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
const two = logic.two;

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
    /// Every slot's initial value (`Run.values`), `logic.words(width)`
    /// words per plane, slot after slot.
    v: []const u64,
    x: []const u64,
    /// `Run.values.len`.
    slots: u32,
    /// `Run.fan_start`/`Run.fan`: the continuous drivers reading each slot.
    fan_start: []const u32,
    fan: []const u32,
    /// `Run.code.len`: the pc space `armed` covers.
    code_len: u32,
    /// `Run.repeats.len`: one counter per lexical `repeat` (§9.6).
    repeats: u32,
    /// `Run.pending`'s time-0 queue, as the pcs each process starts at.
    order: []const u32,
    /// Static schedule: per slot, the bits each combinational node reads
    /// (`comb[comb_start[slot]..comb_start[slot + 1]]`, ascending by word),
    /// nodes numbered in topological order, and how many nodes there are.
    comb_start: []const u32 = &.{},
    comb: []const Sense = &.{},
    nodes: u32 = 0,
    /// Static schedule: per slot, the event-control terms of the processes
    /// that wait at one fixed place (`watchers[watch_start[slot]..]`), and
    /// how many such processes there are.
    watch_start: []const u32 = &.{},
    watchers: []const Watcher = &.{},
    triggered: u32 = 0,
};

/// Node `node` reads the bits `mask` of plane word `word`.
pub const Sense = struct { node: u32, word: u32, mask: u64 };

/// One term of a triggered process: it resumes at `pc` on `edge`.
pub const Watcher = struct { proc: u32, pc: u32, edge: Edge };

/// What `State.next` returns for a settle event.
pub const settle_pc: u32 = std.math.maxInt(u32);

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
/// One §9.2.2 nonblocking update: the bits `m` of `slot` (words from
/// `off`) become `v`/`x` when it matures, merged into the value the slot
/// holds THEN. `v`, `x` and `m` are `n` words each at `words[at..]`.
const Nba = struct { slot: u32, off: u32, n: u32, at: u32 };
/// The scheduler payload of the one NBA-region event that applies every
/// row in `rows`, in order: the interpreter's one event per row, which the
/// scheduler promotes together, with nothing between them.
const nba_payload: u32 = 1 << 31;
/// The payload of a settle event; every other payload is a pc.
const settle_payload: u32 = nba_payload | 1;

/// `root.max_events_per_tick`.
const budget: u64 = @import("../digital/root.zig").max_events_per_tick;

pub const State = struct {
    gpa: std.mem.Allocator,
    v: []u64,
    x: []u64,
    sched: Scheduler,
    /// The NBA region's rows, in the order they were queued.
    rows: std.ArrayList(Nba) = .empty,
    words: std.ArrayList(u64) = .empty,
    susps: std.ArrayList(Susp) = .empty,
    free_susps: std.ArrayList(u32) = .empty,
    terms: []std.ArrayList(Term),
    fan_start: []const u32,
    fan: []const u32,
    armed: []bool,
    comb_start: []const u32,
    comb: []const Sense,
    /// The slots with node readers that changed since the settle event was
    /// queued, each once (`pending`): a slot written many times before the
    /// settle costs its fan-out once.
    changed: std.ArrayList(u32) = .empty,
    pending: []bool,
    /// Per plane word of a slot with node readers: the bits that changed
    /// since its readers were last marked.
    diff: []u64,
    /// One bit per combinational node, set while the settle event runs; it
    /// runs them from `cursor` up.
    dirty: []u64,
    cursor: u32 = 0,
    settle: enum { idle, queued, running } = .idle,
    watch_start: []const u32,
    watchers: []const Watcher,
    /// Per triggered process: it is waiting at its event control.
    waiting: []bool,
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
            .terms = try gpa.alloc(std.ArrayList(Term), d.slots),
            .fan_start = d.fan_start,
            .fan = d.fan,
            .armed = try gpa.alloc(bool, d.code_len),
            .comb_start = d.comb_start,
            .comb = d.comb,
            .pending = try gpa.alloc(bool, if (d.nodes == 0) 0 else d.slots),
            .diff = try gpa.alloc(u64, if (d.nodes == 0) 0 else d.v.len),
            .dirty = try gpa.alloc(u64, (d.nodes + 63) / 64),
            .watch_start = d.watch_start,
            .watchers = d.watchers,
            .waiting = try gpa.alloc(bool, d.triggered),
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
        @memset(self.pending, false);
        @memset(self.diff, 0);
        @memset(self.dirty, 0);
        @memset(self.waiting, false);
        @memset(self.repeats, 0);
        for (d.order) |pc| try self.run(pc, null);
    }

    /// The next process to dispatch, at the pc it resumes at, or
    /// `settle_pc`; null once the queue is empty or `$finish` ran.
    /// Nonblocking updates are applied here.
    pub fn next(self: *State) Error!?u32 {
        while (self.sched.next()) |event| {
            try self.count(event.time);
            if (event.payload == settle_payload) {
                for (self.changed.items) |slot| {
                    self.pending[slot] = false;
                    self.markReaders(slot);
                }
                self.changed.clearRetainingCapacity();
                self.settle = .running;
                return settle_pc;
            }
            if (event.payload != nba_payload) return event.payload;
            for (self.rows.items, 0..) |row, i| {
                if (i != 0) try self.count(event.time);
                const w = self.words.items[row.at..][0 .. 3 * row.n];
                try self.store(row.slot, row.off, w[0..row.n], w[row.n..][0..row.n], w[2 * row.n ..]);
            }
            self.rows.clearRetainingCapacity();
            self.words.clearRetainingCapacity();
        }
        return null;
    }

    /// `Run.runUntil`'s zero-delay-loop guard, counted the same way: one
    /// event per nonblocking row.
    fn count(self: *State, at: u64) Error!void {
        if (at != self.budget_time) {
            self.budget_time = at;
            self.budget_used = 0;
        }
        self.budget_used += 1;
        if (self.budget_used > budget)
            return self.fail("more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ budget, at });
    }

    /// The next dirty combinational node of this settle event, in
    /// topological order, or null when none is left.
    pub fn nextDirty(self: *State) ?u32 {
        while (self.cursor < self.dirty.len) : (self.cursor += 1) {
            const w = self.dirty[self.cursor];
            if (w != 0) {
                self.dirty[self.cursor] = w & (w - 1);
                return self.cursor * 64 + @ctz(w);
            }
        }
        self.cursor = 0;
        self.settle = .idle;
        return null;
    }

    /// Mark dirty the nodes that read a bit of `slot` changed since the
    /// last call, then forget those changes.
    fn markReaders(self: *State, slot: u32) void {
        const senses = self.comb[self.comb_start[slot]..self.comb_start[slot + 1]];
        for (senses) |e| {
            const hit = self.diff[e.word] & e.mask != 0;
            self.dirty[e.node / 64] |= @as(u64, @intFromBool(hit)) << @intCast(e.node % 64);
            // A node's successors come after it, so a running settle only
            // ever gains bits above its cursor; this keeps it right regardless.
            self.cursor = @min(self.cursor, if (hit) e.node / 64 else self.cursor);
        }
        if (senses.len != 0) @memset(self.diff[senses[0].word .. senses[senses.len - 1].word + 1], 0);
    }

    /// Whether a node reads some bit of `slot`.
    inline fn sensed(self: *const State, slot: u32) bool {
        return slot + 1 < self.comb_start.len and self.comb_start[slot] != self.comb_start[slot + 1];
    }

    /// `slot` changed: its node readers run in the settle event, which is
    /// queued now if it is not already.
    fn dirtyReaders(self: *State, slot: u32) Error!void {
        switch (self.settle) {
            .running => self.markReaders(slot),
            .queued => if (!self.pending[slot]) {
                self.pending[slot] = true;
                try self.changed.append(self.gpa, slot);
            },
            .idle => {
                self.pending[slot] = true;
                try self.changed.append(self.gpa, slot);
                self.settle = .queued;
                _ = self.sched.schedule(.active, settle_payload) catch |e| return self.schedFail(e);
            },
        }
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

    // Under `--two-state` the x plane stays zero, and a read says so as a
    // constant, so every operator's x half folds away where it is compiled.

    /// The value of at most 64 bits at word `off`.
    pub inline fn get(self: *const State, off: u32) W {
        return .{ .v = self.v[off], .x = if (two) 0 else self.x[off] };
    }

    /// The `n`-word value at word `off`.
    pub inline fn getw(self: *const State, off: u32, comptime n: u32) logic.Wide(n) {
        return .{ .v = self.v[off..][0..n].*, .x = if (two) @splat(0) else self.x[off..][0..n].* };
    }

    /// The bits `m` of the value at word `off` become `a`'s, for a slot no
    /// event control, driver or node can be waiting on.
    pub inline fn set(self: *State, off: u32, a: anytype, m: anytype) void {
        if (@TypeOf(a) != W) {
            for (self.v[off..][0..a.v.len], self.x[off..][0..a.v.len], a.v, a.x, m) |*ov, *ox, av, ax, am| {
                ov.* = (ov.* & ~am) | (av & am);
                ox.* = (ox.* & ~am) | (ax & am);
            }
            return;
        }
        const bits: u64 = m;
        self.v[off] = (self.v[off] & ~bits) | (a.v & bits);
        if (!two) self.x[off] = (self.x[off] & ~bits) | (a.x & bits);
    }

    /// `exec.store` of the bits `m` of `slot`, whose words start at `off`:
    /// nothing happens unless the value changes; then every waiter it
    /// matches wakes. `a` is a `logic.T`, `m` the `logic.M` of its width.
    pub inline fn put(self: *State, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        if (@TypeOf(a) != W) return self.store(slot, off, &a.v, &a.x, &m);
        return self.putWord(slot, off, 0, a, m);
    }

    /// `put` of the bits `m` of word `j` alone: a bit-select of a wide slot
    /// touches one word. An edge is its least significant bit's (§9.7.2),
    /// which only word 0 holds.
    pub inline fn putWord(self: *State, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
        const at = off + j;
        const o = self.get(at);
        const nv = (o.v & ~m) | (a.v & m);
        const nx = (o.x & ~m) | (a.x & m);
        const d = (nv ^ o.v) | (nx ^ o.x);
        if (d == 0) return;
        const before = logic.low(self.get(off));
        self.v[at] = nv;
        if (!two) self.x[at] = nx;
        if (self.sensed(slot)) self.diff[at] |= d;
        try self.wake(slot, before, logic.low(self.get(off)));
    }

    fn store(self: *State, slot: u32, off: u32, v: []const u64, x: []const u64, m: []const u64) Error!void {
        const sv = self.v[off..][0..v.len];
        const sx = self.x[off..][0..v.len];
        const before = logic.low(W{ .v = sv[0], .x = sx[0] });
        const sense = self.sensed(slot);
        var changed: u64 = 0;
        for (sv, sx, v, x, m, 0..) |*ov, *ox, av, ax, am, i| {
            const nv = (ov.* & ~am) | (av & am);
            const nx = (ox.* & ~am) | (ax & am);
            const d = (nv ^ ov.*) | (nx ^ ox.*);
            changed |= d;
            if (sense) self.diff[off + i] |= d;
            ov.* = nv;
            ox.* = nx;
        }
        if (changed == 0) return;
        try self.wake(slot, before, logic.low(W{ .v = sv[0], .x = sx[0] }));
    }

    /// §9.2.2: schedule the bits `m` of `slot` (words from `off`) to become
    /// `a` in the NBA region.
    pub fn nba(self: *State, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        const n: u32 = if (@TypeOf(a) == W) 1 else a.v.len;
        const at: u32 = @intCast(self.words.items.len);
        if (@TypeOf(a) == W)
            try self.words.appendSlice(self.gpa, &.{ a.v, a.x, m })
        else
            try self.words.appendSlice(self.gpa, &(a.v ++ a.x ++ m));
        try self.rows.append(self.gpa, .{ .slot = slot, .off = off, .n = n, .at = at });
        if (self.rows.items.len == 1) _ = self.sched.schedule(.nba, nba_payload) catch |e| return self.schedFail(e);
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
    /// event controls in the order they suspended. Under the static
    /// schedule the nodes and triggered processes reading it come between.
    pub fn wake(self: *State, slot: u32, before: Bit, after: Bit) Error!void {
        if (slot + 1 < self.fan_start.len) for (self.fan[self.fan_start[slot]..self.fan_start[slot + 1]]) |pc| if (self.armed[pc]) {
            self.armed[pc] = false;
            try self.run(pc, null);
        };
        if (slot + 1 < self.comb_start.len and self.comb_start[slot] != self.comb_start[slot + 1]) try self.dirtyReaders(slot);
        if (slot + 1 < self.watch_start.len) for (self.watchers[self.watch_start[slot]..self.watch_start[slot + 1]]) |w| {
            if (!self.waiting[w.proc] or !w.edge.matches(before, after)) continue;
            self.waiting[w.proc] = false;
            try self.run(w.pc, null);
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

    /// `a`'s planes as the `Literal` the interpreter formats.
    fn literal(buf: []u64, w: u32, signed: bool) Int.Literal {
        return .{ .width = w, .signed = signed, .sized = true, .planes = buf };
    }

    /// One `%b`/`%o`/`%h`/`%d` operand (§17.1.1.3).
    pub fn value(self: *State, a: anytype, w: u32, signed: bool, radix: fmt.Radix, width: ?u32) Error!void {
        var buf = logic.planesOf(a);
        fmt.value(self.out, literal(&buf, w, signed), radix, width) catch |e| return switch (e) {
            error.TooWide => self.fail("decimal display of an operand wider than 64 bits is not implemented", .{}),
            error.WriteFailed => error.WriteFailed,
        };
    }

    /// One `%t` operand, in a module whose unit is 10^`unit_exp` s (§17.3).
    pub fn time(self: *State, a: anytype, w: u32, signed: bool, unit_exp: i32) Error!void {
        var buf = logic.planesOf(a);
        try fmt.time(self.out, literal(&buf, w, signed), self.time_format, unit_exp);
    }

    /// One `%s` or `%c` operand (§17.1.1.7).
    pub fn text(self: *State, a: anytype, w: u32, char: bool, width: ?u32) Error!void {
        var buf = logic.planesOf(a);
        try fmt.text(self.out, literal(&buf, w, false), char, width);
    }
};
