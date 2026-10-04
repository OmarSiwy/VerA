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
/// A module's §19.8 time scale, which the emitted code passes to `$time` and delays.
pub const Scale = @import("../time.zig").Scale;
/// §17.1 value text, shared with the interpreter.
pub const fmt = @import("../fmt.zig");
/// The four-state operators the emitted expressions call (`L`).
pub const logic = @import("logic.zig");
/// §7.9 net resolution of the native design.
pub const net = @import("net.zig");
/// §18 the value change dump, shared with the interpreter.
pub const vcd = @import("../digital/vcd.zig");
/// §18.3 the extended (ports) dump.
pub const evcd = @import("evcd.zig");
const snapshot = @import("snapshot.zig");
/// A native design as a contract device an analog host loads.
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
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buf);
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
    /// §18.3 the `$dumpports` calls, each one file (`evcd.File`).
    ports_dump: []const evcd.File = &.{},
    /// §7.9 the nets resolved from their drivers, those drivers, and the
    /// §8 UDPs among them.
    nets: []const net.Net = &.{},
    drivers: []const net.Driver = &.{},
    udps: []const net.Udp = &.{},
    /// §7.6 the pass switches between those nets.
    trans: []const net.Tran = &.{},
    /// `--state=auto`: the plane words (first word, count) of the slots
    /// whose value at a time-step boundary nothing reads before a whole
    /// write (`digital/plan.zig` `stepLocal`), an x in which does not keep
    /// the design 4-state.
    dead: []const [2]u32 = &.{},
    /// §10.2.1 per slot (empty without `vera_activations`): 1 + the task
    /// whose out-of-line automatic activations each own this named event,
    /// else 0 (`waiters.eventContext`).
    act_events: []const u32 = &.{},
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
    const failed = if (!asked(init_, "--vera-snapshot")) loop(s, four, two_, std.math.maxInt(u64)) else blk: {
        var stats: snapshot.Stats = .{};
        const failed = snapshot.twice(s, four, two_, &stats);
        stderrLine(init_, "vera-snapshot: {d} ticks, boundary at most {d} bytes\n", .{ stats.ticks, stats.bytes });
        break :blk failed;
    };
    // §18.3.6.1: the extended dump's last step, then `$vcdclose`.
    if (failed != null) return failed;
    evcd.close(s, s.sched.now) catch |e| return e;
    return null;
}

/// Dispatches every event of `s` at a tick up to `limit` in its phase;
/// returns how the run ended, null also when the next event is past `limit`.
/// `four` is a `Dispatch`, or in the prebuilt engine an `engine.DispatchC`.
pub fn loop(s: *State, four: anytype, comptime two_: ?Dispatch, limit: u64) ?Error {
    if (prebuilt) return engine.loop(s, four, two_, limit);
    while (true) {
        const pc = (@call(.always_inline, State.next, .{ s, limit }) catch |e| return e) orelse return null;
        (if (two_ != null and s.two) two_.?(s, pc) else if (@TypeOf(four) == engine.DispatchC) engine.call(four, s, pc) else four(s, pc)) catch |e| return e;
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
    var e = std.Io.File.stderr().writerStreaming(init_.io, &buf);
    e.interface.print(f, values) catch {};
    e.interface.flush() catch {};
}

/// Node `node` reads the bits `mask` of plane word `word`.
pub const Sense = struct {
    node: u32,
    word: u32,
    mask: u64,

    // Budget: one row per (slot, node) read, walked by `markReaders`.
    comptime {
        std.debug.assert(@sizeOf(Sense) == 16);
    }
};

/// One term of a triggered process: it resumes at `pc` on `edge`.
pub const Watcher = struct { proc: u32, pc: u32, edge: Edge };

/// What `State.next` returns for a settle event.
pub const settle_pc: u32 = std.math.maxInt(u32);

/// `waiters.Edge`: §5.10.1 an edge is a change toward 1 or away from 1.
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

    /// Everything: the reach of a store `plan` could not narrow.
    pub const all: Reach = .{ .fan = true, .comb = true, .watch = true, .terms = true, .mon = true, .dump = true };
};

/// `waiters.Susp`: where the process resumes, in which §10.2.3 activation
/// (`State.ctx`, 0 for none). `seq` is its `State.stamp`.
const Susp = struct { pc: u32, gen: u32, ctx: u32 = 0, alive: bool, seq: u64 = 0 };
/// `exec.Act`: one activation of a timed task that reaches itself, entered
/// by `State.callTimed`. Its caller resumes at `ret_pc` in `ret_ctx`; an
/// automatic task's frame is the `n` plane words from `lo`, kept in
/// `storage` (both planes) while another activation of it is resident.
const Act = struct { sub: u32, ret_pc: u32, ret_ctx: u32, lo: u32, n: u32, storage: []u64 = &.{} };
/// A process continuation queued inside an activation (`exec.Pending`'s
/// `resume`); its scheduler payload is `resume_base` + its row.
const Resume = struct { pc: u32, ctx: u32, live: bool };
/// §9.7.3: the event element selected now, or null for an invalid index.
/// The emitted function reads the declaring scope's slots in the active
/// logic phase. Its address is immutable across a saved tick boundary.
pub const EventSelect = fn (*State) Error!?u32;
const Term = struct { susp: u32, gen: u32, edge: Edge, select: ?*const EventSelect = null, rec: u32 = no_rec };
/// §9.7.2 a constant select term's bits: `width` of them from bit `shift`
/// of plane word `word` on, and their value when last tested.
const Rec = struct { word: u32, shift: u32, width: u32, v: u64, x: u64 };
/// `Term.rec` of a term that watches its whole slot.
const no_rec = std.math.maxInt(u32);
/// One §9.2.2 nonblocking update: the bits `m` of `slot` (words from
/// `off`) become `v`/`x` when it matures, merged into the value the slot
/// holds then. `v`, `x` and `m` are `n` words each: the row's own `one`
/// for a single word, else at `words[at..]`. A `quiet` slot has nothing to
/// wake. A real row compares numeric values when it arrives (§4.8).
const Nba = struct { slot: u32, off: u32, n: u32, at: u32, quiet: bool, real: bool, one: [3]u64 = undefined };
/// An `Nba` in flight past this timestep, owning its `v`, `x`, `m` words.
const Late = struct { slot: u32, off: u32, n: u32, real: bool, words: []u64 };
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
/// `resume_base + k`: process continuation `resumes[k]`, in an activation.
const resume_base: u32 = 5 << 29;

/// `root.Overrides`: the process ranges of a slot's `assign` and `force`,
/// and of the forces of constant selects of a net (§9.3.2), each holding
/// bits [lo, lo + width); `emit` numbers a net's distinct selects.
/// ponytail: at most `max_parts` forced selects per net (`emit` refuses
/// more); a list per slot if a design forces more of one net.
const Layers = struct { assign: ?Range = null, force: ?Range = null, parts: [max_parts]Part = @splat(.{}) };
const Range = struct { start: u32, end: u32 };
const Part = struct { lo: u32 = 0, width: u32 = 0, range: ?Range = null };
/// Forced selects per net a native design may hold (`emit` refuses more).
pub const max_parts = 4;

/// Some `assign` or `force` (§9.3) can hold a slot: the executable's root
/// declares `vera_overrides`.
pub const overrides = @hasDecl(@import("root"), "vera_overrides");

/// A §10.2.3 timed task reaches itself (`emit`'s `.call_timed`): the
/// executable's root declares `vera_activations`, and its processes carry
/// an activation (`State.ctx`).
pub const activations = @hasDecl(@import("root"), "vera_activations");

/// A contract device's root declares `vera_prebuilt_engine`: the engine's
/// design-independent half is linked prebuilt (`engine.zig`).
pub const prebuilt = @hasDecl(@import("root"), "vera_prebuilt_engine");
/// The prebuilt-engine seam (`prebuilt`).
pub const engine = @import("engine.zig");

/// `root.max_events_per_tick`, or the executable's `vera --event-budget=`.
pub const budget: u64 = if (@hasDecl(@import("root"), "vera_event_budget")) @import("root").vera_event_budget else @import("../digital/root.zig").max_events_per_tick;

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
        /// `State.get`; the x half is 0 in the 2-state phase.
        pub inline fn get(s: anytype, off: u32) W {
            var a = s.get(off);
            if (k) a.x = 0;
            return a;
        }

        /// `State.getw`; the x half is 0 in the 2-state phase.
        pub inline fn getw(s: anytype, off: u32, comptime n: u32) logic.Wide(n) {
            var a = s.getw(off, n);
            if (k) a.x = @splat(0);
            return a;
        }

        /// `State.set`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn set(s: anytype, off: u32, a: anytype, m: anytype) Error!void {
            if (!k) return s.set(off, a, m);
            try known(a, m);
            poke(true, planeV(s), undefined, off, a, m);
        }

        /// `State.put`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn put(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            if (@TypeOf(a) != W) return s.store(slot, off, &a.v, &a.x, &m);
            return s.putWordAs(k, reach, slot, off, 0, a, m);
        }

        /// `put` out of line, for code that runs once.
        pub noinline fn putCold(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            return put(s, reach, slot, off, a, m);
        }

        /// `set` out of line.
        pub noinline fn setCold(s: *State, off: u32, a: anytype, m: anytype) Error!void {
            return set(s, off, a, m);
        }

        /// `State.putWord`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn putWord(s: *State, comptime reach: Reach, slot: u32, off: u32, j: u32, a: W, m: u64) Error!void {
            if (k) try known(a, m);
            return s.putWordAs(k, reach, slot, off, j, a, m);
        }

        /// `View.putNode`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn putNode(s: View, comptime reach: Reach, slot: u32, off: u32, a: anytype, comptime senses: []const Sense) Error!void {
            if (k) try known(a, @as(@TypeOf(a.x), if (@TypeOf(a) == W) std.math.maxInt(u64) else @splat(std.math.maxInt(u64))));
            return s.putNodeAs(k, reach, slot, off, a, senses);
        }

        /// `State.nba`; `error.Rerun` on an x or z in the 2-state phase.
        pub inline fn nba(s: *State, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
            if (k) try known(a, m);
            return @call(.always_inline, State.nba, .{ s, reach, slot, off, a, m });
        }

        /// `State.nbaAfter`; `error.Rerun` on an x or z in the 2-state phase.
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

    /// `State.get` through the held pointers.
    pub inline fn get(self: View, off: u32) W {
        return peek(two, self.v, self.x, off);
    }

    /// `State.getw` through the held pointers.
    pub inline fn getw(self: View, off: u32, comptime n: u32) logic.Wide(n) {
        return peekw(self.v, self.x, off, n);
    }

    /// `State.set` through the held pointers.
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
        if (@reduce(.Or, @as(@Vector(n, u64), d)) != 0) try self.s.wakeOf(reach, slot, before, logic.low(peek(k, self.v, self.x, off)));
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
    /// The select terms' bits (`Term.rec`), and the rows free.
    recs: std.ArrayList(Rec) = .empty,
    free_recs: std.ArrayList(u32) = .empty,
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
    /// §10.2.3 (`activations`): the activation the running process is in
    /// (0 for none); every one in progress (row 0 unused) and the rows free;
    /// per task, the activation its automatic frame holds; the queued
    /// continuations inside one; per slot, `Design.act_events`. `jump` is
    /// the pc `dispatch` runs next, without queueing (a call or a return),
    /// `returned` says the call site at that pc is being returned to.
    ctx: u32 = 0,
    acts: std.ArrayList(Act) = .empty,
    free_acts: std.ArrayList(u32) = .empty,
    resident: []u32 = &.{},
    resumes: std.ArrayList(Resume) = .empty,
    free_resumes: std.ArrayList(u32) = .empty,
    act_events: []const u32 = &.{},
    jump: ?u32 = null,
    returned: bool = false,
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
    /// §18.3 the extended dump: the files, what each has written, and the
    /// time its `$dumpports` calls ran at. Outside a snapshot, as `dump` is.
    port_files: []const evcd.File = &.{},
    port_live: []evcd.Live = &.{},
    ports_at: ?u64 = null,
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
            .resident = try gpa.alloc(u32, if (activations) d.subs else 0),
            .act_events = d.act_events,
            .monitored = try gpa.alloc(bool, d.slots),
            .time_format = .{ .units = time_units },
            .cap = .init(gpa),
            .layers = try gpa.alloc(Layers, if (overrides) d.slots else 0),
            .catalog = d.vcd,
            .port_files = d.ports_dump,
            .port_live = try gpa.alloc(evcd.Live, d.ports_dump.len),
            .dumped = try gpa.alloc(bool, if (d.vcd != null) d.slots else 0),
            .nets = try .init(gpa, d.nets, d.drivers, d.udps, d.trans),
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
        @memset(self.resident, 0);
        @memset(self.monitored, false);
        @memset(self.layers, .{});
        @memset(self.dumped, false);
        @memset(self.port_live, .{});
        for (d.order) |pc| try self.runPlain(pc, null);
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
                if (row.real)
                    try self.putReal(row.slot, row.off, .{ .v = row.words[0], .x = 0 }, row.words[2])
                else
                    try self.store(row.slot, row.off, row.words[0..row.n], row.words[row.n..][0..row.n], row.words[2 * row.n ..]);
                self.gpa.free(row.words);
                self.late.items[k].words = &.{};
                try self.free_late.append(self.gpa, k);
                continue;
            }
            if (activations and event.payload >= resume_base) {
                const k = event.payload - resume_base;
                const row = self.resumes.items[k];
                self.resumes.items[k].live = false;
                try self.free_resumes.append(self.gpa, k);
                self.ctx = row.ctx;
                try self.makeResident(row.ctx);
                return row.pc;
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
                if (activations) self.ctx = 0;
                return settle_pc;
            }
            if (event.payload >= net.drive_base and event.payload < nba_payload) {
                try net.arrive(self, event.payload);
                continue;
            }
            if (event.payload != nba_payload) {
                if (activations) self.ctx = 0;
                return event.payload;
            }
            for (self.rows.items, 0..) |*row, i| {
                if (i != 0) try self.count(event.time);
                const w: []const u64 = if (row.n == 1) &row.one else self.words.items[row.at..][0 .. 3 * row.n];
                if (row.real) {
                    try self.putReal(row.slot, row.off, .{ .v = w[0], .x = 0 }, w[2]);
                } else if (row.quiet) {
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
            // §18.4: the extended dump's changes at the end of the step.
            if (self.port_live.len != 0) try evcd.tick(self, self.budget_time);
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
        var e = std.Io.File.stderr().writerStreaming(self.io, &buf);
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

    /// `waiters.store` of the bits `m` of `slot`, whose words start at `off`:
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

    /// `put` of a real (§4.8, `waiters.store`): it changes when its value
    /// does, so -0.0 over 0.0 is no change and a NaN always is one.
    pub fn putReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void {
        _ = m;
        if (self.held(slot)) return;
        if (logic.real(self.get(off)) == logic.real(a)) return;
        const before = logic.low(self.get(off));
        self.v[off] = a.v;
        if (!two) self.x[off] = 0;
        if (self.sensed(slot)) self.diff[off] = std.math.maxInt(u64);
        try self.wake(slot, before, logic.low(a));
    }

    // The emitted code calls these as `s.<name>(...)`; each lives in the
    // file that owns its data.

    /// `snapshot.save`: this state as a tick boundary.
    pub const save = snapshot.save;
    /// `snapshot.restore`: a tick boundary `save` wrote.
    pub const restore = snapshot.restore;

    /// §7.9 the net-resolution entry points (`net.zig`).
    pub const drive = net.drive;
    pub const switchCtrl = net.switchCtrl;
    pub const gate = net.gate;
    pub const udp = net.udp;
    pub const mos = net.mos;
    pub const bridge = net.bridge;
    pub const pull = net.pull;
    pub const resolve = net.resolve;

    /// §18.3 `$dumpports` selection and control (`evcd.zig`).
    pub const portsSelect = evcd.select;
    pub const portsControl = evcd.control;

    /// `put` of the bits `m` of an `n`-word value at runtime width.
    pub fn store(self: *State, slot: u32, off: u32, v: []const u64, x: []const u64, m: []const u64) Error!void {
        if (self.held(slot)) return;
        if (self.two) for (x, m) |a, b| if (a & b != 0) return error.Rerun;
        const sv = self.v[off..][0..v.len];
        const sx = self.x[off..][0..v.len];
        const before = logic.low(W{ .v = sv[0], .x = sx[0] });
        const sense = self.sensed(slot);
        var changed: u64 = 0;
        for (sv, sx, v, x, m, 0..) |*ov, *ox, av, ax, am_, i| {
            // §9.3.2 a forced select of a net keeps its bits; the rest resolve.
            const am = am_ & ~self.forcedBits(slot, i);
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
        return self.nbaValue(false, reach, slot, off, a, m);
    }

    /// §9.2.2 NBA of a §4.8 real, retaining numeric change detection.
    pub fn nbaReal(self: *State, slot: u32, off: u32, a: W, m: u64) Error!void {
        return self.nbaValue(true, .all, slot, off, a, m);
    }

    fn nbaValue(self: *State, comptime is_real: bool, comptime reach: Reach, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        const quiet = reach == Reach{};
        if (@TypeOf(a) == W) {
            // Grown out of line, appended in line: with two phases' call
            // sites LLVM otherwise outlines the whole `append`.
            if (self.rows.items.len == self.rows.capacity) try self.rows.ensureUnusedCapacity(self.gpa, 1);
            self.rows.appendAssumeCapacity(.{ .slot = slot, .off = off, .n = 1, .at = 0, .quiet = quiet, .real = is_real, .one = .{ a.v, a.x, m } });
        } else {
            const at: u32 = @intCast(self.words.items.len);
            try self.words.appendSlice(self.gpa, &(a.v ++ a.x ++ m));
            try self.rows.append(self.gpa, .{ .slot = slot, .off = off, .n = a.v.len, .at = at, .quiet = quiet, .real = is_real });
        }
        if (self.rows.items.len == 1) _ = self.sched.schedule(.nba, nba_payload) catch |e| return self.schedFail(e);
    }

    /// §9.2.2 `<= #d`: `nba` of the update `after` ticks later. At 0 it
    /// joins this step's rows, the order its own event would take.
    pub fn nbaAfter(self: *State, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        return self.nbaAfterValue(false, reach, after, slot, off, a, m);
    }

    /// `nbaAfter` retaining the target's real type until the update lands.
    pub fn nbaRealAfter(self: *State, after: u64, slot: u32, off: u32, a: W, m: u64) Error!void {
        return self.nbaAfterValue(true, .all, after, slot, off, a, m);
    }

    fn nbaAfterValue(self: *State, comptime is_real: bool, comptime reach: Reach, after: u64, slot: u32, off: u32, a: anytype, m: anytype) Error!void {
        if (after == 0) return self.nbaValue(is_real, reach, slot, off, a, m);
        const n: u32 = if (@TypeOf(a) == W) 1 else a.v.len;
        const words = try self.gpa.alloc(u64, 3 * n);
        if (@TypeOf(a) == W) @memcpy(words, &[3]u64{ a.v, a.x, m }) else @memcpy(words, &(a.v ++ a.x ++ m));
        const k = self.free_late.pop() orelse blk: {
            try self.late.append(self.gpa, undefined);
            break :blk @as(u32, @intCast(self.late.items.len - 1));
        };
        self.late.items[k] = .{ .slot = slot, .off = off, .n = n, .real = is_real, .words = words };
        _ = self.sched.scheduleAfter(after, .nba, late_base + k) catch |e|
            return if (e == error.OutOfMemory) error.OutOfMemory else self.fail("digital timing failure: {t}", .{e});
    }

    /// §10.3 `disable` of the named block or task copy at pcs `[lo, hi)`:
    /// every suspension and queued resumption inside it is dropped, and if
    /// there was one, its process continues at `end` (`exec.disableRange`).
    pub fn disable(self: *State, lo: u32, hi: u32, end: u32) Error!void {
        if (try self.stop(lo, hi)) try self.runPlain(end, null);
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
        if (activations) for (self.resumes.items, 0..) |*row, k| if (row.live and row.pc >= lo and row.pc < hi) {
            const at = resume_base + @as(u32, @intCast(k));
            _ = self.sched.cancelRange(at, at + 1) catch |e| return self.schedFail(e);
            row.live = false;
            try self.free_resumes.append(self.gpa, @intCast(k));
            hit = true;
        };
        return hit;
    }

    /// §9.3: an `assign` or `force` holds `slot` and blocks every write but
    /// its own process's (`waiters.store`'s guard; an `assign` holds only a
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
        try self.runPlain(start, null);
    }

    /// The bits of word `j` of `slot` that a forced select holds against
    /// every writer but the force's own process.
    inline fn forcedBits(self: *const State, slot: u32, j: usize) u64 {
        if (!overrides or self.overriding) return 0;
        var m: u64 = 0;
        for (self.layers[slot].parts) |p| if (p.range != null) {
            const lo: i64 = @as(i64, p.lo) - 64 * @as(i64, @intCast(j));
            const hi = lo + p.width;
            if (hi <= 0 or lo >= 64) continue;
            const a: u7 = @intCast(@max(lo, 0));
            const b: u7 = @intCast(@min(hi, 64));
            m |= (if (b == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(b)) - 1) & ~((@as(u64, 1) << @intCast(a)) - 1);
        };
        return m;
    }

    /// `exec` `.override_on` of a forced select: part `k` of `slot`, bits
    /// [lo, lo + width), is held by the force whose process is pcs
    /// [start, end), replacing the force of the same select before it.
    pub fn overrideBits(self: *State, slot: u32, k: u32, lo: u32, width: u32, start: u32, end: u32) Error!void {
        const p = &self.layers[slot].parts[k];
        if (p.range) |old| _ = try self.stop(old.start, old.end);
        p.* = .{ .lo = lo, .width = width, .range = .{ .start = start, .end = end } };
        try self.runPlain(start, null);
    }

    /// `waiters.releaseBits`: part `k` of `slot` is its drivers' again; the
    /// design re-resolves the net.
    pub fn releaseBits(self: *State, slot: u32, k: u32) Error!void {
        const p = &self.layers[slot].parts[k];
        if (p.range) |old| _ = try self.stop(old.start, old.end);
        p.range = null;
    }

    /// A forced select's own write: bits [lo, lo + bw) of the `sw`-bit
    /// `slot` at word `off` become `a`.
    pub fn putBits(self: *State, slot: u32, off: u32, comptime lo: u32, comptime bw: u32, comptime sw: u32, a: anytype) Error!void {
        const n = comptime logic.words(sw);
        var v: [n]u64 = @splat(0);
        var x: [n]u64 = @splat(0);
        var m: [n]u64 = @splat(0);
        const src = logic.wide(a);
        for (0..bw) |i| {
            const at = lo + i;
            const bit = @as(u64, 1) << @intCast(at % 64);
            if (src.v[i / 64] >> @intCast(i % 64) & 1 != 0) v[at / 64] |= bit;
            if (src.x[i / 64] >> @intCast(i % 64) & 1 != 0) x[at / 64] |= bit;
            m[at / 64] |= bit;
        }
        try self.store(slot, off, &v, &x, &m);
    }

    /// Is `slot` forced? An `assign` under a force keeps tracking but does
    /// not write (`exec` `.override_eval`).
    pub fn forced(self: *const State, slot: u32) bool {
        return self.layers[slot].force != null;
    }

    /// `waiters.release`: §9.3 `deassign` (`force` false) or `release` of
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
        if (l.assign) |a| try self.runPlain(a.start, null);
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

    /// `exec.callTimed`: §10.2.2 task `sub` begins a new activation, whose
    /// caller resumes at its call site `ret_pc`. An automatic task (§10.2.3)
    /// sets the resident activation's frame aside and starts its own as
    /// `fill`, `fill.len` words from `lo`; the emitted call then copies the
    /// inputs in and jumps to the body.
    pub fn callTimed(self: *State, sub: u32, ret_pc: u32, lo: u32, fill: []const u64) Error!void {
        if (self.acts.items.len == 0) try self.acts.append(self.gpa, .{ .sub = 0, .ret_pc = 0, .ret_ctx = 0, .lo = 0, .n = 0 }); // 0 is "no activation"
        const act: Act = .{ .sub = sub, .ret_pc = ret_pc, .ret_ctx = self.ctx, .lo = lo, .n = @intCast(fill.len) };
        const id: u32 = if (self.free_acts.pop()) |k| blk: {
            const storage = self.acts.items[k].storage;
            self.acts.items[k] = act;
            self.acts.items[k].storage = storage;
            break :blk k;
        } else blk: {
            try self.acts.append(self.gpa, act);
            break :blk @intCast(self.acts.items.len - 1);
        };
        if (fill.len != 0) {
            try self.evict(sub);
            @memcpy(self.v[lo..][0..fill.len], fill);
            if (!two) @memcpy(self.x[lo..][0..fill.len], fill);
            self.resident[sub] = id;
        }
        self.ctx = id;
    }

    /// `exec.returnTimed`: the running activation has ended (the emitted
    /// body has put its outputs aside); its caller's activation becomes
    /// resident, and the call site it returns to is the result.
    pub fn returnTimed(self: *State) Error!u32 {
        const done = self.ctx;
        const act = self.acts.items[done];
        if (self.resident[act.sub] == done) self.resident[act.sub] = 0; // dead: nothing to save
        try self.free_acts.append(self.gpa, done);
        self.ctx = act.ret_ctx;
        try self.makeResident(self.ctx);
        self.returned = true;
        return act.ret_pc;
    }

    /// Save the resident activation of automatic task `sub`, freeing its frame.
    fn evict(self: *State, sub: u32) Error!void {
        const id = self.resident[sub];
        if (id == 0) return;
        const act = &self.acts.items[id];
        if (act.storage.len != 2 * act.n) {
            self.gpa.free(act.storage);
            act.storage = &.{};
            act.storage = try self.gpa.alloc(u64, 2 * act.n);
        }
        @memcpy(act.storage[0..act.n], self.v[act.lo..][0..act.n]);
        @memcpy(act.storage[act.n..], self.x[act.lo..][0..act.n]);
        self.resident[sub] = 0;
    }

    /// `exec.makeResident`: activation `ctx`'s storage in its task's frame.
    fn makeResident(self: *State, ctx: u32) Error!void {
        if (ctx == 0) return;
        const act = self.acts.items[ctx];
        if (act.n == 0 or self.resident[act.sub] == ctx) return;
        try self.evict(act.sub);
        @memcpy(self.v[act.lo..][0..act.n], act.storage[0..act.n]);
        @memcpy(self.x[act.lo..][0..act.n], act.storage[act.n..]);
        self.resident[act.sub] = ctx;
    }

    /// `waiters.eventContext`: the live activation of automatic task `sub`
    /// that activation `from` runs inside, or 0.
    fn eventContext(self: *const State, sub: u32, from: u32) u32 {
        var ctx = from;
        while (ctx != 0) : (ctx = self.acts.items[ctx].ret_ctx) if (self.acts.items[ctx].sub == sub) return ctx;
        return 0;
    }

    /// `waiters.selectedEvent`: §9.7.3 the element `select` names, read in the
    /// waiter's activation `ctx`; the running one is resident again after.
    fn selectIn(self: *State, select: *const EventSelect, ctx: u32) Error!?u32 {
        if (!activations or ctx == self.ctx) return select(self);
        const running = self.ctx;
        self.ctx = ctx;
        try self.makeResident(ctx);
        const at = select(self);
        self.ctx = running;
        try self.makeResident(running);
        return at;
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

    /// Queues the running process's continuation at `pc`, in its activation
    /// (`ctx`): now (active), or `after` ticks later (inactive).
    pub fn run(self: *State, pc: u32, after: ?u64) Error!void {
        return self.runIn(pc, if (activations) self.ctx else 0, after);
    }

    /// `run` in activation `ctx` (`exec.resumption`).
    fn runIn(self: *State, pc: u32, ctx: u32, after: ?u64) Error!void {
        if (!activations or ctx == 0) return self.runPlain(pc, after);
        const k = self.free_resumes.pop() orelse blk: {
            try self.resumes.append(self.gpa, undefined);
            break :blk @as(u32, @intCast(self.resumes.items.len - 1));
        };
        self.resumes.items[k] = .{ .pc = pc, .ctx = ctx, .live = true };
        _ = (if (after) |t|
            self.sched.scheduleAfter(t, .inactive, resume_base + k) catch |e| return self.timeFail(e)
        else
            self.sched.schedule(.active, resume_base + k) catch |e| return self.schedFail(e));
    }

    /// Queues the process at `pc` outside any activation: now (active), or
    /// `after` ticks later (inactive).
    fn runPlain(self: *State, pc: u32, after: ?u64) Error!void {
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

    /// `waiters.wake`: the continuous drivers reading `slot` first, then the
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
            try self.runPlain(pc, null);
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
        // §10.2.1: an automatic task's event is one per activation, so only
        // a waiter in the activation that triggers it wakes.
        const owner: u32 = if (activations and self.act_events.len != 0) self.act_events[slot] else 0;
        const event_ctx = if (owner != 0) self.eventContext(owner - 1, self.ctx) else 0;
        var keep: usize = 0;
        for (list.items) |t| {
            const s = &self.susps.items[t.susp];
            if (s.gen != t.gen) {
                self.dropRec(t);
                continue;
            }
            // Only named-event lists carry selectors. IEEE §10.4.4(f)
            // forbids a function from triggering an event, so a selector
            // cannot recursively compact this same list. Its blocking
            // writes may wake ordinary value lists below.
            const selected = (owner == 0 or event_ctx == self.eventContext(owner - 1, s.ctx)) and
                if (t.select) |select| (try self.selectIn(select, s.ctx)) == slot else true;
            // A selector can call an HDL function whose writes resume this
            // suspension through another term of its event-or expression.
            if (s.gen != t.gen) continue;
            const hit = if (t.rec == no_rec) t.edge.matches(before, after) else self.recChanged(t.rec, t.edge);
            if (!hit or !selected) {
                list.items[keep] = t;
                keep += 1;
                continue;
            }
            self.dropRec(t);
            if (reach.watch) try self.wakeWatchers(slot, before, after, s.seq);
            const pc = s.pc;
            const ctx = s.ctx;
            self.retire(t.susp);
            try self.runIn(pc, ctx, null);
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
            try self.runPlain(w.pc, null);
        }
    }

    /// What a change of `slot` would wake now: `.any` when a continuous
    /// driver, a node or an any-change term reads it, and the edge of each
    /// edge term waiting on it (§9.7.2: of its least significant bit). The
    /// monitor and the dump are left out.
    pub fn wakes(self: *const State, slot: u32) std.EnumSet(Edge) {
        var e: std.EnumSet(Edge) = .empty;
        if (self.sensed(slot) or (slot + 1 < self.fan_start.len and self.fan_start[slot] != self.fan_start[slot + 1])) e.insert(.any);
        // A select term's edge is of a bit other than the slot's LSB.
        for (self.terms[slot].items) |t| if (self.susps.items[t.susp].gen == t.gen) e.insert(if (t.rec == no_rec) t.edge else .any);
        if (slot + 1 < self.watch_start.len) for (self.watchers[self.watch_start[slot]..self.watch_start[slot + 1]]) |w| {
            if (self.waiting[w.proc] != 0) e.insert(w.edge);
        };
        return e;
    }

    /// The next suspension's order among all of them: `vera --run` wakes
    /// the processes waiting on a change in this order (`wakeTerms`).
    pub inline fn stamp(self: *State) u64 {
        self.seq += 1;
        return self.seq;
    }

    /// `waiters.park`: suspend the running process, to resume at `pc`.
    pub fn park(self: *State, pc: u32) Error!u32 {
        const id = self.free_susps.pop() orelse blk: {
            try self.susps.append(self.gpa, .{ .pc = 0, .gen = 0, .alive = false });
            try self.free_susps.ensureTotalCapacity(self.gpa, self.susps.items.len);
            break :blk @as(u32, @intCast(self.susps.items.len - 1));
        };
        const s = &self.susps.items[id];
        s.pc = pc;
        if (activations) s.ctx = self.ctx;
        s.alive = true;
        s.seq = self.stamp();
        return id;
    }

    /// `waiters.watch`: file one term of suspension `id` under `slot`.
    pub fn watch(self: *State, id: u32, slot: u32, edge: Edge) Error!void {
        return self.watchTerm(id, slot, edge, null);
    }

    /// §9.7.3: only an occurrence of the selected element wakes this
    /// suspension. Index changes alone neither wake it nor freeze a choice.
    /// Inlined automatic invocations already have separate event slots.
    pub fn watchSelected(self: *State, id: u32, first: u32, elements: u32, select: *const EventSelect) Error!void {
        for (first..first + elements) |slot| try self.watchTerm(id, @intCast(slot), .any, select);
    }

    fn watchTerm(self: *State, id: u32, slot: u32, edge: Edge, select: ?*const EventSelect) Error!void {
        const list = &self.terms[slot];
        if (list.items.len == list.capacity and list.capacity != 0) {
            var keep: usize = 0;
            for (list.items) |t| if (self.susps.items[t.susp].gen == t.gen) {
                list.items[keep] = t;
                keep += 1;
            } else self.dropRec(t);
            list.shrinkRetainingCapacity(keep);
            if (keep > list.capacity / 2) try list.ensureTotalCapacity(self.gpa, list.capacity * 2);
        }
        try list.append(self.gpa, .{ .susp = id, .gen = self.susps.items[id].gen, .edge = edge, .select = select });
    }

    /// §9.7.2 a constant select term: bits `[lo, lo + width)` (at most 64)
    /// of `slot`, whose words start at `off`. It remembers them, so every
    /// update of the slot is tested against them at once (§11.6.3), a
    /// pulse that puts them back included.
    pub fn watchBits(self: *State, id: u32, slot: u32, off: u32, lo: u32, width: u32, edge: Edge) Error!void {
        const k = self.free_recs.pop() orelse blk: {
            try self.recs.append(self.gpa, undefined);
            break :blk @as(u32, @intCast(self.recs.items.len - 1));
        };
        // `dropRec` returns it without failing.
        try self.free_recs.ensureTotalCapacity(self.gpa, self.recs.items.len);
        const r = &self.recs.items[k];
        r.* = .{ .word = off + lo / 64, .shift = lo % 64, .width = width, .v = 0, .x = 0 };
        const now = self.bits(r.*);
        r.v = now.v;
        r.x = now.x;
        try self.watchTerm(id, slot, edge, null);
        const list = &self.terms[slot];
        list.items[list.items.len - 1].rec = k;
    }

    /// A select term's bits now.
    fn bits(self: *const State, r: Rec) W {
        const sh: u6 = @intCast(r.shift);
        var v = self.v[r.word] >> sh;
        var x = if (two) 0 else self.x[r.word] >> sh;
        if (sh != 0 and r.shift + r.width > 64) {
            const up: u6 = @intCast(64 - r.shift);
            v |= self.v[r.word + 1] << up;
            if (!two) x |= self.x[r.word + 1] << up;
        }
        const m = if (r.width == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(r.width)) - 1;
        return .{ .v = v & m, .x = x & m };
    }

    /// Did select term `k`'s bits change in a way `edge` matches (of their
    /// least significant bit)? Either way it now remembers them.
    fn recChanged(self: *State, k: u32, edge: Edge) bool {
        const r = &self.recs.items[k];
        const now = self.bits(r.*);
        if (now.v == r.v and now.x == r.x) return false;
        const before = logic.low(W{ .v = r.v, .x = r.x });
        r.v = now.v;
        r.x = now.x;
        return edge.matches(before, logic.low(now));
    }

    /// A term leaves its list: its select bits' row is free.
    inline fn dropRec(self: *State, t: Term) void {
        if (t.rec != no_rec) self.free_recs.appendAssumeCapacity(t.rec);
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

    /// §17.2.4.2 `$fgets`: the bytes read into a `w`-bit destination, valid
    /// until the next scratch-using call. No bytes means no assignment.
    pub fn fileLine(self: *State, d: ?i64, comptime w: u32) Error![]const u8 {
        if (self.quiet) return "";
        const fd = (d orelse return "") & 0xffff_ffff;
        _ = self.scratch.reset(.retain_capacity);
        return system.readLine(self.scratch.allocator(), system.own, fd, w / 8);
    }

    /// §17.2.4.4: one big-endian binary word, copied out of the shared
    /// reader's scratch storage so assigning it may safely call other tasks.
    pub fn fileWord(self: *State, d: ?i64, comptime w: u32) Error!struct { value: ?logic.T(w), n: i64 } {
        if (self.quiet) return .{ .value = null, .n = 0 };
        const fd = (d orelse return .{ .value = null, .n = 0 }) & 0xffff_ffff;
        _ = self.scratch.reset(.retain_capacity);
        const word = system.readWord(self.scratch.allocator(), system.own, fd, w) catch return error.OutOfMemory;
        const v = word.value orelse return .{ .value = null, .n = word.n };
        if (w <= 64) return .{ .value = .{ .v = v.values()[0], .x = 0 }, .n = word.n };
        var word_value: logic.T(w) = .{ .v = undefined, .x = @splat(0) };
        @memcpy(&word_value.v, v.values());
        return .{ .value = word_value, .n = word.n };
    }

    /// §17.2.7 `$ferror`: the descriptor's error and the corresponding text.
    /// Descriptor zero also reports a failed open, as on the interpreter path.
    pub fn fileError(self: *const State, d: ?i64) struct { code: i64, text: []const u8 } {
        const code = if (self.quiet) 0 else system.own.err.?((d orelse 0) & 0xffff_ffff);
        return .{ .code = code, .text = @import("kernels").file_kernels.zFErrorStr(code, 0) };
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

    /// §17.2.4.3 `$fscanf`: the same conversion stream as `$sscanf`, together
    /// with the file position which `finishFileScan` advances by consumed input.
    pub fn scanFile(self: *State, descriptor: ?i64, format: anytype, comptime fw: u32, outs: usize) Error!system.FileScan {
        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        return system.fileScan(a, system.own, if (self.quiet) null else descriptor, try chars(a, format, fw), outs);
    }

    /// `system.finishFileScan` of a `scanFile`: the file position follows
    /// what the scan consumed.
    pub fn finishFileScan(self: *const State, file: system.FileScan, sc: system.Scan) void {
        if (self.quiet) return;
        _ = system.finishFileScan(system.own, file, sc);
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
        var e = std.Io.File.stderr().writerStreaming(self.io, &buf);
        e.interface.print("warning[" ++ code ++ "]: " ++ message ++ "\n", args) catch {};
        e.interface.flush() catch {};
    }

    /// §17.2.9 `$readmemb`/`$readmemh` of the file `name` beside `source`
    /// (`display.MemLoad`) into the array whose lowest address is `slot`,
    /// at word `off`, each element `width` bits. `given` is how many of the
    /// start and finish addresses `first`/`last` the call has (null: x or z).
    pub fn readmem(self: *State, source: []const u8, name: []const u8, radix: fmt.Radix, width: u32, slot: u32, off: u32, low: i64, high: i64, given: u2, first: ?i64, last: ?i64) Error!void {
        if (self.quiet) return;
        if ((given >= 1 and first == null) or (given == 2 and last == null)) return self.fail(display.unknown_bound, .{});
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

    /// §17.1.1.5 `%v` of the native net `k` (`Nets.sig0`, kept by the fold
    /// a net whose strength is read resolves through).
    pub fn netStrength(self: *State, k: u32) Error!void {
        try display.strength(self.out, self.nets.sig0[k]);
    }

    /// §17.1.1.5 `%v` of an operand that is not a net: its bit 0, strong.
    pub fn strongStrength(self: *State, a: anytype, w: u32) Error!void {
        var buf = logic.planesOf(a);
        try display.strength(self.out, .of(literal(&buf, w, false).bit(0), .strong, .strong));
    }

    /// §17.2.3 a `$sformat` format held in a variable, read when the task
    /// runs (`display.sformat`'s dynamic walk): its characters, how far they
    /// are used, and whether they end inside a conversion.
    pub const Format = struct { text: []const u8, i: usize = 0, bad: bool = false };

    /// One argument-taking conversion of a `Format`.
    pub const Spec = struct { conv: u8, width: ?u32, precision: i64 };

    /// The characters of the `w`-bit format `a` (`system.text`) in `buf`,
    /// `w / 8` bytes rounded up; none when it holds an x or z.
    pub fn formatOf(buf: []u8, a: anytype, w: u32) Format {
        var planes = logic.planesOf(a);
        const v = literal(&planes, w, false);
        if (v.hasUnknown()) return .{ .text = "" };
        var n: usize = 0;
        var k = buf.len;
        while (k != 0) {
            k -= 1;
            var c: u8 = 0;
            for (0..8) |b| {
                const at: u32 = @intCast(k * 8 + b);
                if (at < w and v.bit(at) == .one) c |= @as(u8, 1) << @intCast(b);
            }
            if (c == 0 and n == 0) continue;
            buf[n] = c;
            n += 1;
        }
        return .{ .text = buf[0..n] };
    }

    /// The next conversion of `f` that takes an argument, printing the text
    /// before it (`%%`, `%m` as `scope`, `%l` as `lib`); null, having warned
    /// (W1153), when the format has none left for the argument.
    pub fn nextSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec {
        if (try self.scanSpec(f, scope, lib)) |sp| return sp;
        self.warn("W1153", display.sformat_mismatch, .{});
        return null;
    }

    /// The text after the last argument's conversion; W1153 when another
    /// conversion wants an argument or the format ends inside one.
    pub fn endFormat(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!void {
        if (try self.scanSpec(f, scope, lib) != null or f.bad) self.warn("W1153", display.sformat_mismatch, .{});
    }

    fn scanSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec {
        const t = f.text;
        while (f.i < t.len) {
            const c = t[f.i];
            f.i += 1;
            if (c != '%') {
                try self.out.writeByte(c);
                continue;
            }
            if (f.i < t.len and t[f.i] == '%') {
                f.i += 1;
                try self.out.writeByte('%');
                continue;
            }
            var width: ?u32 = null;
            while (f.i < t.len and t[f.i] >= '0' and t[f.i] <= '9') : (f.i += 1)
                width = (width orelse 0) *| 10 +| (t[f.i] - '0');
            var precision: i64 = -1;
            if (f.i < t.len and t[f.i] == '.') {
                f.i += 1;
                precision = 0;
                while (f.i < t.len and t[f.i] >= '0' and t[f.i] <= '9') : (f.i += 1)
                    precision = precision *| 10 +| (t[f.i] - '0');
            }
            if (f.i == t.len) {
                f.bad = true;
                return null;
            }
            if ((width orelse 0) > display.max_field or precision > display.max_field)
                return self.fail("a field width or precision here exceeds {d}", .{display.max_field});
            const conv = t[f.i];
            f.i += 1;
            switch (conv) {
                'm', 'M' => try self.out.writeAll(scope),
                'l', 'L' => try self.out.writeAll(lib),
                'b', 'B', 'o', 'O', 'h', 'H', 'd', 'D', 'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R', 't', 'T', 's', 'S', 'c', 'C', 'v', 'V' => return .{ .conv = conv, .width = width, .precision = precision },
                else => return self.fail("only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g, §9.4.7 %r and %%) and %c %s %m %l %t %v are implemented", .{}),
            }
        }
        return null;
    }

    /// One `%s` or `%c` operand (§17.1.1.7).
    pub fn text(self: *State, a: anytype, w: u32, char: bool, width: ?u32) Error!void {
        var buf = logic.planesOf(a);
        try fmt.text(self.out, literal(&buf, w, false), char, width);
    }
};
