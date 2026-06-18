//! The runtime a `vera --emit-exe design.v` executable links: the emitted
//! design (`digital/emit.zig`) in, its IEEE 1364 §17 transcript on stdout
//! out (exit 0), or a diagnostic on stderr (exit 1).
//! Clauses: §11 scheduling (§11.4.2 for the `static` order), §9.7 event
//! controls, §9.2.2 nonblocking updates, §6.1 and §7.9 nets, §17 system
//! tasks, §18 VCD.
const std = @import("std");
const diag = @import("diag");
const digital = @import("../digital/root.zig");
const Scheduler = @import("../scheduler.zig").Scheduler;
pub const Scale = @import("../time.zig").Scale;
pub const fmt = @import("../fmt.zig");
pub const logic = @import("logic.zig");
pub const net = @import("net.zig");
pub const vcd = @import("../digital/vcd.zig");
const snapshot = @import("snapshot.zig");
pub const Device = @import("device.zig").Device;
const Int = @import("frontend").Integer;
const zCReal = @import("kernels").str_kernels.zCReal;
const system = @import("../digital/system.zig");
const display = @import("../digital/display.zig");
const W = logic.W;
const Bit = logic.Bit;
const two = logic.two;

test {
    _ = logic;
    _ = net;
    _ = snapshot;
    std.testing.refAllDecls(State);
}

/// Runs `source` through the interpreter, exactly `vera --run`: the
/// executable of a design `digital/emit.zig` did not make native. Prints
/// the transcript on stdout and diagnostics on stderr; returns `vera --run`'s
/// exit status. The names in `opts` resolve against the working directory.
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

/// A native design's tables, emitted as constants.
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
    /// `Run.joins.len`: one counter per §9.8.2 `fork`.
    joins: u32 = 0,
    /// `Run.subs.len`: the tasks and functions (§10).
    subs: u32 = 0,
    /// What a `$dumpvars` (§18) can select; null when the design has none.
    vcd: ?*const vcd.Catalog = null,
    /// §7.9 the nets resolved from their drivers, those drivers, and the
    /// §8 UDPs among them.
    nets: []const net.Net = &.{},
    drivers: []const net.Driver = &.{},
    udps: []const net.Udp = &.{},
    /// `--state=auto`: the plane words (first word, count) of the slots
    /// whose value at a time-step boundary nothing reads before a whole
    /// write (`digital/plan.zig` `stepLocal`), an x in which does not keep
    /// the design 4-state.
    dead: []const [2]u32 = &.{},
};

/// The dispatch of one phase: `Code(k).dispatch` of the emitted root.
pub const Dispatch = fn (*State, u32) Error!void;

/// The `main` of a `--state=auto` executable: `four` (`Phase(false)`)
/// until a time step begins with no live x or z (`State.boundary`), `two`
/// (`Phase(true)`) after. A store of an x or z in the 2-state phase
/// (`error.Rerun`) runs the design again from time 0, all 4-state; the
/// transcript up to that store was the 4-state one already, so only the
/// rerun's output past it is printed. Run with the argument
/// `--vera-state`, it says which ran in one `vera-state:` line on stderr.
pub fn auto(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch, comptime two_: Dispatch) u8 {
    var s: State = undefined;
    s.init(init_, d, units) catch |e| return s.exit(e);
    s.live = s.gpa.alloc(u64, d.x.len) catch |e| return s.exit(e);
    @memset(s.live, std.math.maxInt(u64));
    for (d.dead) |w| @memset(s.live[w[0]..][0..w[1]], 0);
    const failed = run(init_, &s, four, two_);
    if (failed == null or failed.? != error.Rerun) {
        if (s.two) report(init_, "vera-state: 2-state from tick {d}\n", .{s.two_at}) else report(init_, "vera-state: 4-state\n", .{});
        return s.exit(failed);
    }
    report(init_, "vera-state: 2-state from tick {d}, rerun 4-state at tick {d}\n", .{ s.two_at, s.budget_time });
    s.out.flush() catch return 1;
    const printed = s.stdout.pos;
    var r: State = undefined;
    r.init(init_, d, units) catch |e| return r.exit(e);
    // ponytail: the rerun's whole transcript in memory; a writer that drops
    // the first `printed` bytes if a transcript outgrows it.
    var mem: std.Io.Writer.Allocating = .init(r.gpa);
    r.sink = &mem.writer;
    r.out = r.sink;
    const again = run(init_, &r, four, null);
    const code = r.exit(again);
    const text = mem.written();
    s.out.writeAll(text[@min(printed, text.len)..]) catch return 1;
    s.out.flush() catch return 1;
    return code;
}

/// The `main` of a 4-state or `--two-state` executable.
pub fn main(init_: std.process.Init, d: *const Design, units: i32, comptime four: Dispatch) u8 {
    var s: State = undefined;
    s.init(init_, d, units) catch |e| return s.exit(e);
    return s.exit(run(init_, &s, four, null));
}

/// `loop` over the whole run. With the argument `--vera-snapshot`, every
/// tick runs twice (`snapshot.twice`) and one `vera-snapshot:` line on
/// stderr says how many ticks and the largest boundary in bytes.
fn run(init_: std.process.Init, s: *State, comptime four: Dispatch, comptime two_: ?Dispatch) ?Error {
    if (!asked(init_, "--vera-snapshot")) return loop(s, four, two_, std.math.maxInt(u64));
    var stats: snapshot.Stats = .{};
    const failed = snapshot.twice(s, four, two_, &stats);
    stderrLine(init_, "vera-snapshot: {d} ticks, boundary at most {d} bytes\n", .{ stats.ticks, stats.bytes });
    return failed;
}

/// Dispatches every event of `s` at a tick up to `limit` in its phase;
/// returns how the run ended, null also when the next event is past `limit`.
pub fn loop(s: *State, comptime four: Dispatch, comptime two_: ?Dispatch, limit: u64) ?Error {
    while (true) {
        const pc = (@call(.always_inline, State.next, .{ s, limit }) catch |e| return e) orelse return null;
        (if (two_ != null and s.two) two_.?(s, pc) else four(s, pc)) catch |e| return e;
    }
}

/// Whether the executable was run with the argument `flag`.
fn asked(init_: std.process.Init, flag: []const u8) bool {
    var args = init_.minimal.args.iterateAllocator(init_.gpa) catch return false;
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn report(init_: std.process.Init, comptime f: []const u8, values: anytype) void {
    if (asked(init_, "--vera-state")) stderrLine(init_, f, values);
}

/// One line on stderr.
fn stderrLine(init_: std.process.Init, comptime f: []const u8, values: anytype) void {
    var buf: [128]u8 = undefined;
    var e = std.Io.File.stderr().writer(init_.io, &buf);
    e.interface.print(f, values) catch {};
    e.interface.flush() catch {};
}

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

/// `Rerun`: a `--state=auto` executable's 2-state phase met an x or z it
/// cannot hold (`Phase`); `auto` runs the design again, 4-state.
pub const Error = error{ Failed, Rerun } || std.mem.Allocator.Error || std.Io.Writer.Error;

/// What can observe a change of a slot, as `digital/plan.zig` found it: a
/// store's `wake` does only these.
pub const Reach = packed struct(u8) {
    /// Continuous drivers the fan-out queues (§6.1).
    fan: bool = false,
    /// Combinational nodes (`Design.comb`).
    comb: bool = false,
    /// Triggered processes (`Design.watchers`).
    watch: bool = false,
    /// A process suspended at an event control (`State.watch`).
    terms: bool = false,
    /// The §17.1.3 monitor.
    mon: bool = false,
    /// A §18 dump.
    dump: bool = false,
    _: u2 = 0,

    pub const all: Reach = .{ .fan = true, .comb = true, .watch = true, .terms = true, .mon = true, .dump = true };
};

/// `exec.Susp` without the task activation, which no native process has.
/// `seq` is its `State.stamp`.
const Susp = struct { pc: u32, gen: u32, alive: bool, seq: u64 = 0 };
const Term = struct { susp: u32, gen: u32, edge: Edge };
/// One §9.2.2 nonblocking update: the bits `m` of `slot` (words from
/// `off`) become `v`/`x` when it matures, merged into the value the slot
/// holds then. `v`, `x` and `m` are `n` words each: the row's own `one`
/// for a single word, else at `words[at..]`. A `quiet` slot has nothing to
/// wake.
const Nba = struct { slot: u32, off: u32, n: u32, at: u32, quiet: bool, one: [3]u64 = undefined };
/// An `Nba` in flight past this timestep, owning its `v`, `x`, `m` words.
const Late = struct { slot: u32, off: u32, n: u32, words: []u64 };
/// The scheduler payload of the one NBA-region event that applies every
/// row in `rows`, in order: the interpreter's one event per row, which the
/// scheduler promotes together, with nothing between them.
const nba_payload: u32 = 1 << 31;
/// The payload of a settle event.
const settle_payload: u32 = nba_payload | 1;
/// The payload of the one §17.1.3 monitor event of a timestep.
const monitor_payload: u32 = nba_payload | 2;
/// The payload of the one §18 dump event of a timestep.
const vcd_payload: u32 = nba_payload | 3;
/// `show_base + k`: the display of `$strobe` or `$monitor` site k, which
/// `next` returns for the design to print. Every payload below is a pc.
pub const show_base: u32 = 1 << 30;
/// `late_base + k`: delayed nonblocking update `late[k]` (§9.2.2 `<= #d`).
const late_base: u32 = 3 << 30;

/// `root.Overrides`: the process ranges of a slot's `assign` and `force`.
const Layers = struct { assign: ?Range = null, force: ?Range = null };
const Range = struct { start: u32, end: u32 };

/// Some `assign` or `force` (§9.3) can hold a slot: the executable's root
/// declares `vera_overrides`.
const overrides = @hasDecl(@import("root"), "vera_overrides");

/// `root.max_events_per_tick`, or the executable's `vera --event-budget=`.
const budget: u64 = if (@hasDecl(@import("root"), "vera_event_budget")) @import("root").vera_event_budget else @import("../digital/root.zig").max_events_per_tick;

/// `get` of planes `v`, `x`; `k` as `poke`'s.
inline fn peek(comptime k: bool, v: [*]const u64, x: [*]const u64, off: u32) W {
    return .{ .v = v[off], .x = if (k) 0 else x[off] };
}

/// `getw` of planes `v`, `x`.
inline fn peekw(v: [*]const u64, x: [*]const u64, off: u32, comptime n: u32) logic.Wide(n) {
    return .{ .v = v[off..][0..n].*, .x = if (two) @splat(0) else x[off..][0..n].* };
}

/// `set` of planes `v`, `x`; `k`: the x plane is zero and stays so, and
/// is not written.
inline fn poke(comptime k: bool, v: [*]u64, x: [*]u64, off: u32, a: anytype, m: anytype) void {
    if (@TypeOf(a) != W) {
        for (v[off..][0..a.v.len], a.v, m) |*ov, av, am| ov.* = (ov.* & ~am) | (av & am);
        if (!k) for (x[off..][0..a.v.len], a.x, m) |*ox, ax, am| {
            ox.* = (ox.* & ~am) | (ax & am);
        };
        return;
    }
    const bits: u64 = m;
    v[off] = (v[off] & ~bits) | (a.v & bits);
    if (!k) x[off] = (x[off] & ~bits) | (a.x & bits);
}

/// The design's plane accessors in one phase of a `--state=auto`
/// executable (`auto`). `Phase(false)` is `State`'s and `View`'s own.
/// `Phase(true)` runs only while the x plane is zero (`State.two`): a
/// read's x half is the constant 0, so every operator's x half folds away
/// where it is compiled, and a store of an x or z bit, the one way an x
/// could reach the planes again, fails with `error.Rerun` before it lands.
/// The operators stay IEEE 1364's, so an x a known operand makes (`/` by
/// 0, an out-of-range select) is printed or compared exactly; only
/// storing it ends the phase. `s` is a `*State` or a `View`.
pub fn Phase(comptime k: bool) type {
    return struct {
        pub inline fn get(s: anytype, off: u32) W {
            var a = s.get(off);
            if (k) a.x = 0;
            return a;
        }

        pub inline fn getw(s: anytype, off: u32, comptime n: u32) logic.Wide(n) {
            var a = s.getw(off, n);
            if (k) a.x = @splat(0);
            return a;
        }

        pub inline fn set(s: anytype, off: u32, a: anytype, m: anytype) Error!void {
            if (!k) return s.set(off, a, m);
            try known(a, m);
            poke(true, planeV(s), undefined, off, a, m);
        }

        pub inline fn put(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            if (@TypeOf(a) != W) return s.store(slot, off, &a.v, &a.x, &m);
            return s.putWordAs(k, reach, slot, off, 0, a, m);
        }

        /// `put` and `set` out of line, for code that runs once.
        pub noinline fn putCold(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            return put(s, reach, slot, off, a, m);
        }

        pub noinline fn setCold(s: *State, off: u32, a: anytype, m: anytype) Error!void {
            return set(s, off, a, m);
        }

        pub inline fn putWord(s: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
            if (k) try known(a, m);
            return s.putWordAs(k, reach, slot, off, j, a, m);
        }

        pub inline fn putNode(s: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
            if (k) try known(a, @as(@TypeOf(a.x), if (@TypeOf(a) == W) std.math.maxInt(u64) else @splat(std.math.maxInt(u64))));
            return s.putNodeAs(k, reach, slot, off, a, senses);
        }

        pub inline fn nba(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            return @call(.always_inline, State.nba, .{ s, reach, slot, off, a, m });
        }

        pub inline fn nbaAfter(s: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            return s.nbaAfter(reach, after, slot, off, a, m);
        }
    };
}

inline fn planeV(s: anytype) [*]u64 {
    return if (@TypeOf(s) == View) s.v else s.v.ptr;
}

/// `error.Rerun` if a bit `m` selects of `a` is x or z.
inline fn known(a: anytype, m: anytype) Error!void {
    var any: u64 = 0;
    if (@TypeOf(a) == W) any = a.x & m else for (a.x, m) |x, b| {
        any |= x & b;
    }
    if (any != 0) {
        @branchHint(.cold);
        return error.Rerun;
    }
}

/// A settle event's hold on a `State`: its planes and dirty words as
/// pointers read once, which stay in registers across the event's stores;
/// through `State` each is read again after every store. Neither moves
/// while a design runs.
pub const View = struct {
    s: *State,
    v: [*]u64,
    x: [*]u64,
    dirty: [*]u64,

    pub inline fn get(self: View, off: u32) W {
        return peek(two, self.v, self.x, off);
    }

    pub inline fn getw(self: View, off: u32, comptime n: u32) logic.Wide(n) {
        return peekw(self.v, self.x, off, n);
    }

    pub inline fn set(self: View, off: u32, a: anytype, m: anytype) void {
        poke(two, self.v, self.x, off, a, m);
    }

    /// Clear combinational node `n`'s dirty bit; whether it was set. The
    /// settle event takes every node in topological order, so a node only
    /// ever dirties one it has not reached yet.
    pub inline fn take(self: View, n: u32) bool {
        const bit = @as(u64, 1) << @intCast(n % 64);
        const was = self.dirty[n / 64] & bit != 0;
        self.dirty[n / 64] &= ~bit;
        return was;
    }

    /// `put` of the whole of a combinational node's output while the
    /// settle event runs it, whether or not an input changed: the value is
    /// stored as is, and the readers in `senses` (`word` counted from `off`)
    /// whose bits moved are marked dirty here, without a branch; `reach` is
    /// woken as `put` wakes it. A node reached in topological order only
    /// marks later ones.
    pub inline fn putNode(self: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
        return self.putNodeAs(two, reach, slot, off, a, senses);
    }

    /// `putNode`; `k` as `poke`'s.
    pub inline fn putNodeAs(self: View, comptime k: bool, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
        if (self.s.held(slot)) return;
        const s = logic.wide(a);
        const n = s.v.len;
        const before = logic.low(peek(k, self.v, self.x, off));
        var d: [n]u64 = undefined;
        inline for (0..n) |j| {
            const o = peek(k, self.v, self.x, off + j);
            d[j] = (s.v[j] ^ o.v) | (s.x[j] ^ o.x);
            self.v[off + j] = s.v[j];
            if (!k) self.x[off + j] = s.x[j];
        }
        inline for (senses) |e| self.dirty[e.node / 64] |= @as(u64, @intFromBool(d[e.word] & e.mask != 0)) << @intCast(e.node % 64);
        if (@as(u8, @bitCast(reach)) == 0) return;
        var any: u64 = 0;
        for (d) |x| any |= x;
        if (any != 0) try self.s.wakeOf(reach, slot, before, logic.low(peek(k, self.v, self.x, off)));
    }
};

/// One run of a native design. Under the `fifo` schedule it is `vera
/// --run`'s queue discipline with only the process bodies compiled: the
/// same waiter lists, fan-out and nonblocking rows, so a process wakes in
/// the interpreter's order. Under `static`, combinational nodes run in one
/// `settle` event in topological order, and a process that suspends only
/// at its entry waits on a per-slot watcher list; a store wakes those
/// processes and the event controls in suspension order (`stamp`).
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
    /// One bit per combinational node, set while the settle event runs.
    dirty: []u64,
    settle: enum { idle, queued, running } = .idle,
    watch_start: []const u32,
    watchers: []const Watcher,
    /// Per triggered process: the `stamp` of its suspension at its event
    /// control, 0 while it runs.
    waiting: []u64,
    /// The last `stamp`.
    seq: u64 = 0,
    repeats: []u64,
    /// §9.8.2: per `fork`, the arms still running.
    joins: []u32,
    /// §9.2.2 `<= #d` updates in flight, by `late_base` payload; a free row
    /// has no words.
    late: std.ArrayList(Late) = .empty,
    free_late: std.ArrayList(u32) = .empty,
    /// §10: per subroutine, its synchronous activations running; the one a
    /// `disable` is unwinding; how deep they nest; the automatic frames
    /// they set aside, both planes, innermost last.
    active: []u32,
    unwind: ?u32 = null,
    depth: u32 = 0,
    saved: std.ArrayList(u64) = .empty,
    /// §17.1.3: the standing monitor's site and the slots it watches.
    monitored: []bool,
    mon_site: ?u32 = null,
    mon_on: bool = true,
    mon_pending: bool = false,
    /// §17.6 the stochastic queues, by `q_id`.
    queues: system.Queues = .empty,
    /// `Run.random_seed`.
    random_seed: i32 = 0,
    /// §9.3 per slot (empty when the design has no `assign` or `force`):
    /// the pc ranges of the procedural continuous assignments holding it.
    /// While one does, only its own process (`overriding`) writes the slot.
    layers: []Layers,
    overriding: bool = false,
    /// §18 the dump, the design's catalog, and per slot (empty without a
    /// catalog) whether a change is dumped.
    dump: vcd.Vcd = .{},
    catalog: ?*const vcd.Catalog,
    dumped: []bool,
    /// §7.9 resolution state (`net.zig`).
    nets: net.Nets,
    /// `capture`'s buffer, and `scan`'s characters.
    cap: std.Io.Writer.Allocating,
    scratch: std.heap.ArenaAllocator,
    time_format: fmt.TimeFormat,
    budget_time: u64 = 0,
    budget_used: u64 = 0,
    /// `--state=auto` (`auto`): per plane word, the bits that must be known
    /// before the 2-state phase may begin (empty: never); the phase has
    /// begun (`Phase(true)`), and at which tick; the time steps begun, and
    /// the count at which the planes are next looked at.
    live: []u64 = &.{},
    two: bool = false,
    two_at: u64 = 0,
    steps: u64 = 0,
    look_at: u64 = 1,
    stdout: std.Io.File.Writer,
    /// Where the transcript goes (`stdout`, unless redirected), and where
    /// it goes now: `sink`, or a `capture`.
    sink: *std.Io.Writer,
    out: *std.Io.Writer,
    /// A run whose effects outside `State` are dropped (`snapshot.twice`):
    /// no transcript, no diagnostic, no file opened, read or written, no
    /// dump. Every file descriptor reads as unknown.
    quiet: bool = false,
    io: std.Io,
    buf: [1 << 16]u8,

    /// In place: `out` points into `self`. The time-0 queue is `d.order`.
    pub fn init(self: *State, init_: std.process.Init, d: *const Design, time_units: i32) Error!void {
        return self.initIn(std.heap.smp_allocator, init_.io, d, time_units);
    }

    /// `init` with its storage from `gpa`, printing through `io`.
    pub fn initIn(self: *State, gpa: std.mem.Allocator, io: std.Io, d: *const Design, time_units: i32) Error!void {
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
            .waiting = try gpa.alloc(u64, d.triggered),
            .repeats = try gpa.alloc(u64, d.repeats),
            .joins = try gpa.alloc(u32, d.joins),
            .active = try gpa.alloc(u32, d.subs),
            .monitored = try gpa.alloc(bool, d.slots),
            .time_format = .{ .units = time_units },
            .cap = .init(gpa),
            .layers = try gpa.alloc(Layers, if (overrides) d.slots else 0),
            .catalog = d.vcd,
            .dumped = try gpa.alloc(bool, if (d.vcd != null) d.slots else 0),
            .nets = try .init(gpa, d.nets, d.drivers, d.udps),
            .scratch = .init(gpa),
            .stdout = undefined,
            .sink = undefined,
            .out = undefined,
            .io = io,
            .buf = undefined,
        };
        self.stdout = std.Io.File.stdout().writer(io, &self.buf);
        self.sink = &self.stdout.interface;
        self.out = self.sink;
        @memset(self.terms, .empty);
        @memset(self.armed, false);
        @memset(self.pending, false);
        @memset(self.diff, 0);
        @memset(self.dirty, 0);
        @memset(self.waiting, 0);
        @memset(self.repeats, 0);
        @memset(self.joins, 0);
        @memset(self.active, 0);
        @memset(self.monitored, false);
        @memset(self.layers, .{});
        @memset(self.dumped, false);
        for (d.order) |pc| try self.run(pc, null);
    }

    /// The next process to dispatch, at the pc it resumes at, or
    /// `settle_pc`, or `show_base + k`; null once the queue is empty or
    /// `$finish` ran, or when the next event is past tick `limit`
    /// (`Scheduler.nextUntil`). Nonblocking updates are applied here.
    pub fn next(self: *State, limit: u64) Error!?u32 {
        while (self.sched.nextUntil(limit)) |event| {
            try self.count(event.time);
            if (event.payload >= late_base) {
                const k = event.payload - late_base;
                const row = self.late.items[k];
                try self.store(row.slot, row.off, row.words[0..row.n], row.words[row.n..][0..row.n], row.words[2 * row.n ..]);
                self.gpa.free(row.words);
                self.late.items[k].words = &.{};
                try self.free_late.append(self.gpa, k);
                continue;
            }
            if (event.payload == vcd_payload) {
                try self.dumpTick();
                continue;
            }
            if (event.payload == monitor_payload) {
                self.mon_pending = false;
                if (self.mon_on) if (self.mon_site) |k| return show_base + k;
                continue;
            }
            if (event.payload == settle_payload) {
                for (self.changed.items) |slot| {
                    self.pending[slot] = false;
                    self.markReaders(slot);
                }
                self.changed.clearRetainingCapacity();
                self.settle = .running;
                return settle_pc;
            }
            if (event.payload >= net.drive_base and event.payload < nba_payload) {
                try net.arrive(self, event.payload);
                continue;
            }
            if (event.payload != nba_payload) return event.payload;
            for (self.rows.items, 0..) |*row, i| {
                if (i != 0) try self.count(event.time);
                const w: []const u64 = if (row.n == 1) &row.one else self.words.items[row.at..][0 .. 3 * row.n];
                if (row.quiet) {
                    if (self.held(row.slot)) continue;
                    if (row.n != 1) {
                        self.merge(row.off, w[0..row.n], w[row.n..][0..row.n], w[2 * row.n ..]);
                    } else if (self.two) {
                        // `Phase(true).nba` let no x into the row.
                        poke(true, self.v.ptr, self.x.ptr, row.off, W{ .v = row.one[0], .x = 0 }, row.one[2]);
                    } else self.set(row.off, W{ .v = row.one[0], .x = row.one[1] }, row.one[2]);
                } else try self.store(row.slot, row.off, w[0..row.n], w[row.n..][0..row.n], w[2 * row.n ..]);
            }
            self.rows.clearRetainingCapacity();
            self.words.clearRetainingCapacity();
        }
        return null;
    }

    /// `Run.runUntil`'s zero-delay-loop guard, counted the same way: one
    /// event per nonblocking row.
    inline fn count(self: *State, at: u64) Error!void {
        if (at != self.budget_time) {
            self.budget_time = at;
            self.budget_used = 0;
            if (self.live.len != 0 and !self.two) self.boundary(at);
        }
        self.budget_used += 1;
        if (self.budget_used > budget)
            return self.fail("more than {d} events at time {d}: a zero-delay loop keeps simulation time from advancing", .{ budget, at });
    }

    /// A time step begins and every process is suspended: if no bit `live`
    /// names is x or z, the 2-state phase begins. The x left in the other
    /// words (`Design.dead`) is never read before it is overwritten. Looked
    /// at on the 1st, 2nd, 4th, ... step, so a design that keeps an x costs
    /// a scan per doubling.
    fn boundary(self: *State, at: u64) void {
        self.steps += 1;
        if (self.steps != self.look_at) return;
        self.look_at *= 2;
        var any: u64 = 0;
        for (self.x, self.live) |x, l| any |= x & l;
        if (any != 0) return;
        @memset(self.x, 0);
        self.two = true;
        self.two_at = at;
    }

    /// Marks dirty the nodes that read a bit of `slot` changed since the
    /// last call, then forgets those changes.
    fn markReaders(self: *State, slot: u32) void {
        const senses = self.comb[self.comb_start[slot]..self.comb_start[slot + 1]];
        // Held here, not re-read from `self` after each store to `dirty`.
        const diff = self.diff;
        const dirty = self.dirty;
        for (senses) |e| {
            const hit = diff[e.word] & e.mask != 0;
            dirty[e.node / 64] |= @as(u64, @intFromBool(hit)) << @intCast(e.node % 64);
        }
        if (senses.len != 0) @memset(diff[senses[0].word .. senses[senses.len - 1].word + 1], 0);
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
        if (self.quiet) return;
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
        return peek(two, self.v.ptr, self.x.ptr, off);
    }

    /// The `n`-word value at word `off`.
    pub inline fn getw(self: *const State, off: u32, comptime n: u32) logic.Wide(n) {
        return peekw(self.v.ptr, self.x.ptr, off, n);
    }

    /// The bits `m` of the value at word `off` become `a`'s, for a slot no
    /// event control, driver or node can be waiting on.
    pub inline fn set(self: *State, off: u32, a: anytype, m: anytype) void {
        poke(two, self.v.ptr, self.x.ptr, off, a, m);
    }

    /// The settle event's hold on the planes and dirty words.
    pub inline fn view(self: *State) View {
        return .{ .s = self, .v = self.v.ptr, .x = self.x.ptr, .dirty = self.dirty.ptr };
    }

    /// The bits `m` of the words from `off` become `v`/`x`'s.
    fn merge(self: *State, off: u32, v: []const u64, x: []const u64, m: []const u64) void {
        poke(two, self.v.ptr, self.x.ptr, off, .{ .v = v, .x = x }, m);
    }

    /// `exec.store` of the bits `m` of `slot`, whose words start at `off`:
    /// nothing happens unless the value changes; then every waiter it
    /// matches wakes, of those `reach` names. `a` is a `logic.T`, `m` the
    /// `logic.M` of its width.
    pub inline fn put(self: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        if (@TypeOf(a) != W) return self.store(slot, off, &a.v, &a.x, &m);
        return self.putWord(reach, slot, off, 0, a, m);
    }

    /// `put` of the bits `m` of word `j` alone: a bit-select of a wide slot
    /// touches one word. An edge is its least significant bit's (§9.7.2),
    /// which only word 0 holds.
    pub inline fn putWord(self: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
        return self.putWordAs(two, reach, slot, off, j, a, m);
    }

    /// `putWord`; `k` as `poke`'s.
    pub inline fn putWordAs(self: *State, comptime k: bool, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
        if (self.held(slot)) return;
        const at = off + j;
        const o = peek(k, self.v.ptr, self.x.ptr, at);
        const nv = (o.v & ~m) | (a.v & m);
        const nx = (o.x & ~m) | (a.x & m);
        const d = (nv ^ o.v) | (nx ^ o.x);
        if (comptime reach == Reach{ .comb = true }) {
            // Only nodes read the slot: the store does not branch on the
            // data, and only its first change of the step reaches `dirtyReaders`.
            self.v[at] = nv;
            if (!k) self.x[at] = nx;
            self.diff[at] |= d;
            if (!self.pending[slot] and d != 0) try self.dirtyReaders(slot);
            return;
        }
        if (d == 0) return;
        const before = logic.low(peek(k, self.v.ptr, self.x.ptr, off));
        self.v[at] = nv;
        if (!k) self.x[at] = nx;
        if (reach.comb and self.sensed(slot)) self.diff[at] |= d;
        try self.wakeOf(reach, slot, before, logic.low(peek(k, self.v.ptr, self.x.ptr, off)));
    }

    /// `put` of a real (§4.8, `exec.store`): it changes when its value
    /// does, so -0.0 over 0.0 is no change and a NaN always is one.
    pub fn putReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void {
        _ = m;
        if (self.held(slot)) return;
        if (logic.real(self.get(off)) == logic.real(a)) return;
        const before = logic.low(self.get(off));
        self.v[off] = a.v;
        if (self.sensed(slot)) self.diff[off] = std.math.maxInt(u64);
        try self.wake(slot, before, logic.low(a));
    }

    pub const save = snapshot.save;
    pub const restore = snapshot.restore;

    pub const drive = net.drive;
    pub const gate = net.gate;
    pub const udp = net.udp;
    pub const mos = net.mos;
    pub const bridge = net.bridge;
    pub const pull = net.pull;
    pub const resolve = net.resolve;

    /// `put` of the bits `m` of an `n`-word value at runtime width.
    pub fn store(self: *State, slot: u32, off: u32, v: []const u64, x: []const u64, m: []const u64) Error!void {
        if (self.held(slot)) return;
        if (self.two) for (x, m) |a, b| if (a & b != 0) return error.Rerun;
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
    pub fn nba(self: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        // ponytail: a real's update is compared by its bits, not its value as
        // `putReal` does; only -0.0 over 0.0 and a NaN over itself differ.
        const quiet = reach == Reach{};
        if (@TypeOf(a) == W) {
            // Grown out of line, appended in line: with two phases' call
            // sites LLVM otherwise outlines the whole `append`.
            if (self.rows.items.len == self.rows.capacity) try self.rows.ensureUnusedCapacity(self.gpa, 1);
            self.rows.appendAssumeCapacity(.{ .slot = slot, .off = off, .n = 1, .at = 0, .quiet = quiet, .one = .{ a.v, a.x, m } });
        } else {
            const at: u32 = @intCast(self.words.items.len);
            try self.words.appendSlice(self.gpa, &(a.v ++ a.x ++ m));
            try self.rows.append(self.gpa, .{ .slot = slot, .off = off, .n = a.v.len, .at = at, .quiet = quiet });
        }
        if (self.rows.items.len == 1) _ = self.sched.schedule(.nba, nba_payload) catch |e| return self.schedFail(e);
    }

    /// §9.2.2 `<= #d`: `nba` of the update `after` ticks later. At 0 it
    /// joins this step's rows, the order its own event would take.
    pub fn nbaAfter(self: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        if (after == 0) return self.nba(reach, slot, off, a, m);
        const n: u32 = if (@TypeOf(a) == W) 1 else a.v.len;
        const words = try self.gpa.alloc(u64, 3 * n);
        if (@TypeOf(a) == W) @memcpy(words, &[3]u64{ a.v, a.x, m }) else @memcpy(words, &(a.v ++ a.x ++ m));
        const k = self.free_late.pop() orelse blk: {
            try self.late.append(self.gpa, undefined);
            break :blk @as(u32, @intCast(self.late.items.len - 1));
        };
        self.late.items[k] = .{ .slot = slot, .off = off, .n = n, .words = words };
        _ = self.sched.scheduleAfter(after, .nba, late_base + k) catch |e|
            return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital timing failure: {t}", .{e});
    }

    /// §10.3 `disable` of the named block or task copy at pcs `[lo, hi)`:
    /// every suspension and queued resumption inside it is dropped, and if
    /// there was one, its process continues at `end` (`exec.disableRange`).
    pub fn disable(self: *State, lo: u32, hi: u32, end: u32) Error!void {
        if (try self.stop(lo, hi)) try self.run(end, null);
    }

    /// `exec.stopRange`: end every process suspended or queued in pcs
    /// [lo, hi); whether there was one.
    fn stop(self: *State, lo: u32, hi: u32) Error!bool {
        var hit = false;
        for (self.susps.items, 0..) |sp, id| if (sp.alive and sp.pc >= lo and sp.pc < hi) {
            self.retire(@intCast(id));
            hit = true;
        };
        if (self.sched.cancelRange(lo, hi) catch |e| return self.schedFail(e)) hit = true;
        return hit;
    }

    /// §9.3: an `assign` or `force` holds `slot` and blocks every write but
    /// its own process's (`exec.store`'s guard; an `assign` holds only a
    /// variable, which `compile` ensures).
    inline fn held(self: *const State, slot: u32) bool {
        if (!overrides or self.overriding) return false;
        const l = self.layers[slot];
        return l.assign != null or l.force != null;
    }

    /// `exec` `.override_on`: the `assign` (or `force`) whose process is pcs
    /// [start, end) now holds `slot`, replacing the one before it.
    pub fn overrideOn(self: *State, slot: u32, force: bool, start: u32, end: u32) Error!void {
        const l = &self.layers[slot];
        const layer = if (force) &l.force else &l.assign;
        if (layer.*) |old| _ = try self.stop(old.start, old.end);
        layer.* = .{ .start = start, .end = end };
        try self.run(start, null);
    }

    /// Is `slot` forced? An `assign` under a force keeps tracking but does
    /// not write (`exec` `.override_eval`).
    pub fn forced(self: *const State, slot: u32) bool {
        return self.layers[slot].force != null;
    }

    /// `exec.release`: §9.3 `deassign` (`force` false) or `release` of
    /// `slot`; releasing what is not held is a no-op. A released variable
    /// held by an `assign` is that assign's again; true when a released net
    /// must be re-resolved from its drivers, which the design does.
    pub fn release(self: *State, slot: u32, force: bool) Error!bool {
        const l = &self.layers[slot];
        if (l.assign == null and l.force == null) return false;
        const layer = if (force) &l.force else &l.assign;
        if (layer.*) |old| _ = try self.stop(old.start, old.end);
        layer.* = null;
        if (!force) return false;
        if (l.assign) |a| try self.run(a.start, null);
        return true;
    }

    /// §10.2.2 a synchronous activation of subroutine `sub` begins. An
    /// automatic one (§10.2.3) sets its frame, `fill.len` words from `lo`,
    /// aside and makes it x (`fill`, the x of each word); `leave` puts it back.
    pub fn enter(self: *State, sub: u32, lo: u32, fill: []const u64) Error!void {
        if (self.depth == 1024) return self.fail("task and function calls nested deeper than 1024 are not implemented", .{});
        self.depth += 1;
        self.active[sub] += 1;
        if (fill.len == 0) return;
        if (self.two) return error.Rerun;
        try self.saved.appendSlice(self.gpa, self.v[lo..][0..fill.len]);
        try self.saved.appendSlice(self.gpa, self.x[lo..][0..fill.len]);
        @memcpy(self.v[lo..][0..fill.len], fill);
        if (!two) @memcpy(self.x[lo..][0..fill.len], fill);
    }

    /// The activation `enter` began has returned. Restore the caller before
    /// its actuals receive captured outputs; a `disable` of `sub` ends with
    /// its outermost activation.
    pub fn leave(self: *State, sub: u32, lo: u32, n: u32) void {
        self.depth -= 1;
        self.active[sub] -= 1;
        if (n != 0) {
            const at = self.saved.items.len - 2 * n;
            @memcpy(self.v[lo..][0..n], self.saved.items[at..][0..n]);
            @memcpy(self.x[lo..][0..n], self.saved.items[at + n ..][0..n]);
            self.saved.shrinkRetainingCapacity(at);
        }
        if (self.unwind == sub and self.active[sub] == 0) self.unwind = null;
    }

    /// §17.1.2 `$strobe` site `site`: its line at the end of this timestep.
    pub fn strobe(self: *State, site: u32) Error!void {
        _ = self.sched.schedule(.monitor, show_base + site) catch |e| return self.schedFail(e);
    }

    /// §17.1.3 `$monitor` site `site`, watching `slots`, replaces the
    /// standing monitor; its first line is at the end of this timestep.
    pub fn monitor(self: *State, site: u32, slots: []const u32) Error!void {
        @memset(self.monitored, false);
        for (slots) |at| self.monitored[at] = true;
        self.mon_site = site;
        try self.requestMonitor();
    }

    /// `$monitoron` / `$monitoroff`: the site whose line `$monitoron`
    /// prints now, whether or not anything changed.
    pub fn monitorEnable(self: *State, on: bool) ?u32 {
        self.mon_on = on;
        return if (on) self.mon_site else null;
    }

    fn requestMonitor(self: *State) Error!void {
        if (self.mon_site == null or !self.mon_on or self.mon_pending) return;
        self.mon_pending = true;
        _ = self.sched.schedule(.monitor, monitor_payload) catch |e| return self.schedFail(e);
    }

    /// Queues the process at `pc`: now (active), or `after` ticks later (inactive).
    pub fn run(self: *State, pc: u32, after: ?u64) Error!void {
        _ = (if (after) |t|
            self.sched.scheduleAfter(t, .inactive, pc) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital timing failure: {t}", .{e})
        else
            self.sched.schedule(.active, pc) catch |e| return self.schedFail(e));
    }

    /// A scheduling failure as `error.OutOfMemory`, or an E1100 refusal.
    pub fn schedFail(self: *State, e: Scheduler.Error) Error {
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital scheduling failure: {t}", .{e});
    }

    /// `schedFail` of a failure to schedule a delay.
    pub fn timeFail(self: *State, e: Scheduler.Error) Error {
        return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital timing failure: {t}", .{e});
    }

    /// `exec.wake`: the continuous drivers reading `slot` first, then the
    /// event controls in the order they suspended. Under the static
    /// schedule the nodes reading it come before them, and the triggered
    /// processes take their place in that order by `stamp`. A change of a
    /// slot the monitor watches asks for its line (§17.1.3).
    pub fn wake(self: *State, slot: u32, before: Bit, after: Bit) Error!void {
        return self.wakeOf(.all, slot, before, after);
    }

    /// `wake` of what `reach` names alone.
    inline fn wakeOf(self: *State, comptime reach: Reach, slot: u32, before: Bit, after: Bit) Error!void {
        if (reach.mon and self.monitored.len != 0 and self.monitored[slot]) try self.requestMonitor();
        if (reach.dump and self.dumped.len != 0 and self.dumped[slot]) try self.requestDump();
        if (reach.fan and slot + 1 < self.fan_start.len) for (self.fan[self.fan_start[slot]..self.fan_start[slot + 1]]) |pc| if (self.armed[pc]) {
            self.armed[pc] = false;
            try self.run(pc, null);
        };
        if (reach.comb and self.sensed(slot)) try self.dirtyReaders(slot);
        if (reach.terms) return self.wakeTerms(reach, slot, before, after);
        if (reach.watch) try self.wakeWatchers(slot, before, after, std.math.maxInt(u64));
    }

    /// `wake` of the event controls filed under `slot`, in the order they
    /// suspended, each after the triggered processes that suspended before
    /// it: `vera --run`'s order, so a process woken here suspends again
    /// before they store what it waits for next.
    fn wakeTerms(self: *State, comptime reach: Reach, slot: u32, before: Bit, after: Bit) Error!void {
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
            if (reach.watch) try self.wakeWatchers(slot, before, after, s.seq);
            const pc = s.pc;
            self.retire(t.susp);
            try self.run(pc, null);
        }
        list.shrinkRetainingCapacity(keep);
        if (reach.watch) try self.wakeWatchers(slot, before, after, std.math.maxInt(u64));
    }

    /// `wake` of the triggered processes watching `slot` that suspended
    /// before stamp `bound`.
    fn wakeWatchers(self: *State, slot: u32, before: Bit, after: Bit, bound: u64) Error!void {
        if (slot + 1 >= self.watch_start.len) return;
        for (self.watchers[self.watch_start[slot]..self.watch_start[slot + 1]]) |w| {
            const since = self.waiting[w.proc];
            if (since == 0 or since >= bound or !w.edge.matches(before, after)) continue;
            self.waiting[w.proc] = 0;
            try self.run(w.pc, null);
        }
    }

    /// The next suspension's order among all of them: `vera --run` wakes
    /// the processes waiting on a change in this order (`wakeTerms`).
    pub inline fn stamp(self: *State) u64 {
        self.seq += 1;
        return self.seq;
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
        s.seq = self.stamp();
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

    /// §17.7.2 `$realtime`: now, in the invoking module's unit, unrounded.
    pub fn realtime(self: *const State, scale: Scale) f64 {
        return scale.realAt(self.sched.now);
    }

    /// §17.6 queue task `op` (`system.queueStep`), at now in `scale`'s unit.
    pub fn queue(self: *State, op: system.QueueOp, id: ?i64, in1: ?i64, in2: ?i64, scale: Scale) Error!system.QueueResult {
        return system.queueStep(&self.queues, self.gpa, op, id, in1, in2, self.units(scale));
    }

    /// §17.6.5 `$q_full` of queue `id`.
    pub fn queueFull(self: *const State, id: ?i64) @TypeOf(system.queueIsFull(undefined, null)) {
        return system.queueIsFull(&self.queues, id);
    }

    /// §17.2.1 `system.fopen` of the characters of `name` (`nw` bits) with
    /// the type in `mode` (`mw` bits), or `mode` null for a multichannel
    /// descriptor; `source` is the design's file, which a read looks beside.
    pub fn fopen(self: *State, source: []const u8, name: anytype, comptime nw: u32, mode: anytype, comptime mw: u32) Error!i64 {
        if (self.quiet) return 0;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const mcd = @TypeOf(mode) == @TypeOf(null);
        const m = if (mcd) null else try chars(a, mode, mw);
        return system.fopen(system.own, a, source, try chars(a, name, nw), m, mcd);
    }

    /// `system.text` of a `w`-bit value.
    fn chars(a: std.mem.Allocator, v: anytype, comptime w: u32) Error!?[]const u8 {
        var buf = logic.planesOf(v);
        return system.text(a, literal(&buf, w, false)) catch error.OutOfMemory;
    }

    /// `system.fileOp`.
    pub fn fileOp(self: *const State, f: system.FileFn, x: ?i64, y: ?i64, z: ?i64) i64 {
        if (self.quiet) return -1;
        return system.fileOp(system.own, f, x, y, z);
    }

    /// §17.2.7 `$fclose`.
    pub fn fclose(self: *const State, d: ?i64) void {
        if (self.quiet) return;
        _ = system.own.close((d orelse return) & 0xffff_ffff);
    }

    /// §17.2.4.3 `$sscanf` over the characters of `input` and `format`;
    /// the scan's slices live until the next call.
    pub fn scan(self: *State, input: anytype, comptime iw: u32, format: anytype, comptime fw: u32, outs: usize) Error!system.Scan {
        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        return .init(try chars(a, input, iw), try chars(a, format, fw), outs);
    }

    /// Everything printed until `captured` or `fshow` goes to a buffer.
    pub fn capture(self: *State) void {
        self.cap.clearRetainingCapacity();
        self.out = &self.cap.writer;
    }

    /// Ends a `capture`: the bytes printed since, valid until the next one.
    pub fn captured(self: *State) []const u8 {
        self.out = self.sink;
        return self.cap.written();
    }

    /// §17.2.2: ends a `capture`, sending its bytes to descriptor `d`'s
    /// channels (`system.channels`).
    pub fn fshow(self: *State, d: i64) Error!void {
        const bytes = self.captured();
        if (self.quiet) return;
        if (try system.channels(system.own, self.io, self.out, d & 0xffff_ffff, bytes)) self.warn("W1154", system.unwritten, .{});
    }

    /// The characters `bytes` in the `w`-bit cell at word `off`, the last
    /// one in the low byte, truncated or zero-filled on the left.
    pub fn setChars(self: *State, off: u32, comptime w: u32, bytes: []const u8) void {
        const n = comptime logic.words(w);
        const v = self.v[off..][0..n];
        @memset(v, 0);
        @memset(self.x[off..][0..n], 0);
        for (0..@min(bytes.len, n * 8)) |k| v[k / 8] |= @as(u64, bytes[bytes.len - 1 - k]) << @intCast(8 * (k % 8));
        v[n - 1] &= logic.mask(w - 64 * (n - 1));
    }

    /// §17.5 `system.plaEval` of the `nrows` `rw`-bit rows from word `off`
    /// over the `iw`-bit `in`, into the `ow`-bit cell at word `cell`.
    pub fn pla(self: *State, p: system.Pla, off: u32, nrows: u32, comptime rw: u32, in: anytype, comptime iw: u32, cell: u32, comptime ow: u32) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const n = comptime logic.words(rw);
        const rows = try a.alloc(Int.Literal, nrows);
        for (rows, 0..) |*row, k| {
            const planes = try a.alloc(u64, 2 * n);
            @memcpy(planes[0..n], self.v[off + k * n ..][0..n]);
            @memcpy(planes[n..], self.x[off + k * n ..][0..n]);
            if (two) @memset(planes[n..], 0);
            row.* = literal(planes, rw, false);
        }
        var ib = logic.planesOf(in);
        const out = @import("../digital/net.zig").filled(a, ow, false, .x) catch return error.OutOfMemory;
        system.plaEval(p, rows, literal(&ib, iw, false), out);
        const on = comptime logic.words(ow);
        for (self.v[cell..][0..on], self.x[cell..][0..on], out.values(), out.unknowns()) |*v, *x, ov, ox| {
            if (self.two and ox != 0) return error.Rerun;
            // `--two-state`: an output no row decides is 0.
            v.* = if (two) ov & ~ox else ov;
            x.* = if (two) 0 else ox;
        }
    }

    /// §18.1 `$dumpfile` of the characters of a `w`-bit `name`; `call` is
    /// the call as written.
    pub fn dumpFile(self: *State, name: anytype, comptime w: u32, call: []const u8) Error!void {
        if (self.quiet) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        self.dump.setFile(self.gpa, try chars(arena.allocator(), name, w), call) catch |e| return self.dumpFail(e);
    }

    /// §18.1.2 one `$dumpvars` (`vcd.Vcd.select`); its dump starts at the
    /// end of the step.
    pub fn dumpVars(self: *State, levels: ?i64, targets: []const vcd.Target) Error!void {
        if (self.quiet) return;
        self.dump.select(self.gpa, self.sched.now, 0, std.math.lossyCast(u32, levels orelse 0), targets) catch |e| return self.dumpFail(e);
        try self.requestDump();
    }

    /// `$dumpoff`, `$dumpon`, `$dumpall`, `$dumpflush` (`vcd.Vcd.control`).
    pub fn dumpControl(self: *State, op: vcd.Op) Error!void {
        if (self.quiet) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        self.dump.control(arena.allocator(), self.io, self.catalog.?, self, self.sched.now, op) catch |e| return self.dumpFail(e);
    }

    fn dumpTick(self: *State) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        self.dump.tick(self.gpa, arena.allocator(), self.io, self.catalog.?, self, self.sched.now) catch |e| return self.dumpFail(e);
    }

    /// One dump event per step however many dumped values moved.
    fn requestDump(self: *State) Error!void {
        if (self.dump.pending or self.quiet) return;
        self.dump.pending = true;
        _ = self.sched.schedule(.monitor, vcd_payload) catch |e| return self.schedFail(e);
    }

    fn dumpFail(self: *State, e: vcd.Failure) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.DumpvarsTime => self.fail(vcd.message(error.DumpvarsTime), .{}),
            inline else => |f| self.fail(comptime vcd.message(f), .{self.dump.name}),
        };
    }

    /// `vcd.Vcd`'s value source: catalog variable `v`'s planes.
    pub fn dumpPlanes(self: *const State, v: vcd.Var, out: []u64) void {
        const n = out.len / 2;
        @memcpy(out[0..n], self.v[v.off..][0..n]);
        if (two) @memset(out[n..], 0) else @memcpy(out[n..], self.x[v.off..][0..n]);
    }

    /// §18.2.2 named event `slot` was triggered (`vcd.Vcd.fire`); the
    /// `wake` that follows asks for the dump event.
    pub fn fire(self: *State, slot: u32) void {
        if (self.quiet) return;
        if (self.dumped.len != 0 and self.dumped[slot]) self.dump.fire(self.catalog.?, slot);
    }

    /// `vcd.Vcd`'s hook: a change of `slot` asks for a dump event.
    pub fn dumpSlot(self: *State, slot: u32) void {
        self.dumped[slot] = true;
    }

    /// §17.9 `system.dist`, with the interpreter's W1151 warning where the
    /// listing prints one.
    pub fn dist(self: *State, f: system.Dist, seed: i32, a: i32, b: i32) ?system.Draw {
        return system.dist(f, seed, a, b) orelse {
            self.warn("W1151", system.dist_warning, .{});
            return null;
        };
    }

    /// A run-time warning in `vera --run`'s words, on stderr.
    pub fn warn(self: *State, comptime code: []const u8, comptime message: []const u8, args: anytype) void {
        if (self.quiet) return;
        self.out.flush() catch {};
        var buf: [512]u8 = undefined;
        var e = std.Io.File.stderr().writer(self.io, &buf);
        e.interface.print("warning[" ++ code ++ "]: " ++ message ++ "\n", args) catch {};
        e.interface.flush() catch {};
    }

    /// §17.2.9 `$readmemb`/`$readmemh` of the file `name` beside `source`
    /// (`display.MemLoad`) into the array whose lowest address is `slot`,
    /// at word `off`, each element `width` bits. `given` is how many of the
    /// start and finish addresses `first`/`last` the call has (null: x or z).
    pub fn readmem(self: *State, source: []const u8, name: []const u8, radix: fmt.Radix, width: u32, slot: u32, off: u32, low: i64, high: i64, given: u2, first: ?i64, last: ?i64) Error!void {
        if (self.quiet) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const file = display.sideFile(self.io, a, source, name) catch |e| return if (e == error.StreamTooLong)
            self.fail(display.too_large, .{})
        else
            self.fail("the memory file cannot be read", .{});
        var load: display.MemLoad = .init(file, radix, width, low, high, given, first, last);
        const n = (width + 63) / 64;
        const m = try a.alloc(u64, n);
        @memset(m, std.math.maxInt(u64));
        m[n - 1] = @as(u64, std.math.maxInt(u64)) >> @intCast(64 * n - width);
        while (load.next(a) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("{s}", .{display.MemLoad.message(e)})) |w| {
            const v = w.value.values();
            const x = w.value.unknowns();
            // `--two-state`: an x or z digit loads 0.
            if (two) for (v, x) |*bv, *bx| {
                bv.* &= ~bx.*;
                bx.* = 0;
            };
            try self.store(slot + w.index, off + w.index * n, v, x, m);
        }
        if (load.mismatch()) |mm| self.warn("W1150", display.MemLoad.mismatch_text, .{ mm.found, mm.expected });
    }

    /// §17.9.1 a seedless `$random`.
    pub fn random(self: *State) i32 {
        const d = system.dist(.random, self.random_seed, 0, 0).?;
        self.random_seed = d.seed;
        return d.value;
    }

    /// `exec.delayOf` of a real delay (§9.7.1), rounded to the precision.
    pub fn realTicks(self: *State, r: f64, scale: Scale) Error!u64 {
        return scale.realDelay(r) catch |e| self.fail("digital delay cannot be represented: {t}", .{e});
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
        // §18: what this step changed is still part of the dump.
        if (self.dump.pending and !self.quiet) try self.dumpTick();
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
    pub fn time(self: *State, a: anytype, w: u32, signed: bool, unit_exp: i32, width: ?u32) Error!void {
        var buf = logic.planesOf(a);
        var f = self.time_format;
        if (width) |fw| f.width = fw;
        try fmt.time(self.out, literal(&buf, w, signed), f, unit_exp);
    }

    /// One real conversion (§17.1.1.2 `%e %f %g`, §9.4.7 `%r`): C's text,
    /// padded on the left to `width`.
    pub fn real(self: *State, r: f64, conv: u8, precision: i64, width: ?u32) Error!void {
        var buf: [display.real_buf]u8 = undefined;
        const out = zCReal(&buf, r, conv, 0, 0, precision);
        if (width) |w| if (out.len < w) try self.out.splatByteAll(' ', w - out.len);
        try self.out.writeAll(out);
    }

    /// One `%s` or `%c` operand (§17.1.1.7).
    pub fn text(self: *State, a: anytype, w: u32, char: bool, width: ?u32) Error!void {
        var buf = logic.planesOf(a);
        try fmt.text(self.out, literal(&buf, w, false), char, width);
    }
};
