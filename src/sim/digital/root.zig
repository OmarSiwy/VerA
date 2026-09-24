//! Shared frontend -> finite initial-process execution. IEEE1364-2005 §§9,11.
//! This deliberately rejects unsupported source forms before executing a task.
//!
//! In: Verilog source text. Out: its §17 transcript on `out`, or E1100
//! diagnostics before any process has printed anything.
//!
//! This file is the `Run` driver: the engine state and its §6.2.2 per-instance
//! names (§12.4 downward references), §6.2.2 elaboration of the instance tree
//! into slots, nets and driver rows (§6.5 ports, §6.5.7.1 port connections,
//! IEEE 1364 §19.10 `unconnected_drive`), and `run`, which compiles every
//! driver and process and then drains the scheduler.
//!
//!   compile.zig  AST -> bytecode: §5.5 typing, A.6.5 statements
//!   exec.zig     the interpreter: evaluation, the write path, §7.9 resolution
//!   net.zig      §7.9 resolution data: drivers, strengths, gate tables, delays
//!   display.zig  IEEE 1364 §17 display, strobe, monitor, `%t`, `$readmem`
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
pub const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const compile = @import("compile.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does — `exec.store` now, `exec.enqueue` of a `.write` later — so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
pub const exec = @import("exec.zig");
const display = @import("display.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Waiter = exec.Waiter;
const Delay = @import("net.zig").Delay;
const Bridge = @import("net.zig").Bridge;
const Net = @import("net.zig").Net;
const Gate = @import("net.zig").Gate;
const Udp = @import("net.zig").Udp;
const Slice = @import("net.zig").Slice;
const Mos = @import("net.zig").Mos;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const undriven = @import("net.zig").undriven;
const Show = display.Show;
const TimeFormat = display.TimeFormat;

// ---- the public surface -----------------------------------------------------

pub const Error = error{DigitalFailed} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub const Options = struct {
    file_name: []const u8 = "<digital>",
    include_dirs: []const []const u8 = &.{},
    /// Only IEEE 1364-2005 §17.2.9's `$readmemb`/`$readmemh` reach the
    /// filesystem while a process is running, so this is optional: a caller
    /// with no `Io` gets a diagnostic from those two tasks and an unchanged
    /// engine everywhere else. The unit tests are that caller.
    io: ?std.Io = null,
    /// VAMS §7: elaborate the DIGITAL half of a mixed-signal module. See `Mixed`.
    mixed: ?Mixed = null,
};

/// The digital half of a design an analog compile already accepted (VAMS
/// §7.2.2's discrete context of an analog module). Elaboration then skips
/// what belongs to the continuous side instead of refusing it: `analog`
/// blocks, disciplined (continuous) nets and ports, parameters, analog
/// functions, and every variable the digital engine cannot hold. A digital
/// process that names one of those still fails, as an undeclared name.
pub const Mixed = struct {
    /// The module the analog compile lowered: the design's root.
    top: []const u8,
    /// `source` is the analog compile's own PREPROCESSED text, so it is not
    /// preprocessed again and the `timescale it consumed comes in here.
    timescale: ?Front.Preprocessor.Timescale,
};

// ---- engine state and name resolution (§6.2.2, §12.4, §3.9) -----------------

/// One declared identifier, qualified by the §6.2.2 instance that declared it.
const Name = struct { scope: u32, str: Ast.StrId };

// §3.9 an unpacked array is `count` consecutive element slots; the declared
// name maps to the first. `low`/`high` are the declared address bounds, in
// either order of declaration — no operation here observes element ORDER, only
// which address names which element.
///
/// §4.9 a multidimensional array keeps its first dimension in `low`/`high`
/// and the others in `rest`, addressed row-major.
const Array = struct { count: u32, low: i64, high: i64, rest: []const Span = &.{} };
pub const Span = struct { low: i64, high: i64 };

/// A packed vector's declared `[msb:lsb]` (§3.3).
pub const VecRange = struct { msb: i64, lsb: i64 };

/// Who is told when a slot's value changes. `analog` is VAMS §8.5's implicit
/// D2A: the slot is read by an analog block, so a change posts a region-3b
/// macro-process event (see `watchAnalog`).
/// `vpi` is VAMS §12.31.1's cbValueChange: an application watches the slot,
/// and a change calls `Run.vpi_change` (see `store`).
/// `vcd` is IEEE 1364-2005 §18's value change dump: the slot is dumped, so a
/// change asks for the end-of-step section (`vcd.zig`).
/// `d2a` is VAMS §8.5's explicit D2A: the slot is the operand of a digital
/// event term in an analog event control (see `watchEvent`).
pub const Watcher = enum { monitor, analog, vpi, vcd, d2a };

/// Why `runUntil` returned. `analog` is a region-3b event (VAMS §8.5.1): every
/// active, explicit D2A, inactive and nonblocking event of the current tick has
/// run, and an analog-read value changed. The caller solves NOW and calls
/// `runUntil` again, which resumes the same tick at its monitor region.
/// `explicit_d2a` is region 1b (§8.5.3.6): region 1 of the tick is done, and
/// `d2a_fired` names the analog event terms that occurred. The caller takes the
/// values the guarded statements read NOW; the tick's region-3b stop follows.
pub const Stop = enum { idle, analog, explicit_d2a };

/// One digital event term of an analog event control (`Run.watchEvent`).
pub const D2aSite = struct { slot: u32, edge: exec.Edge, site: u6 };

/// The scheduler payload of the one analog macro-process. Not a `pending`
/// row: the event carries no data, and the scheduler coalesces repeats of it
/// (§8.5.3.7) by payload.
pub const analog_payload: u32 = std.math.maxInt(u32);

pub const Run = struct {
    arena: std.mem.Allocator,
    file: *const Ast.SourceFile,
    starts: []const u32,
    bag: *diag.Bag,
    out: *std.Io.Writer,
    /// §6.2.2 names are per INSTANCE, not per module: two instances of one
    /// definition declare the same identifiers over different storage, so the
    /// key is the scope the name was declared in plus the interned name. The
    /// scope in force is `self.scope`, which the executing process carries.
    names: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    scope: u32 = 0,
    /// The highest scope id handed out; the root is 0.
    scopes: u32 = 0,
    /// Per scope id: the instance that minted it, its name and its module —
    /// §17.1.1.6's `%m` path and §13.6's `%l` binding. Row 0 is the root,
    /// named after its module.
    /// `lexical` marks a scope nested INSIDE its parent's module — a task or
    /// function (§12.7) — whose unresolved names are searched for in the
    /// parent; an instance is a hierarchy boundary and is searched no further.
    /// `index` marks one iteration of a §12.4.1 loop generate, the `[i]` of
    /// its block name.
    scope_info: std.ArrayList(struct { parent: u32, name: Ast.StrId, module: Ast.StrId, lexical: bool = false, index: ?i64 = null }) = .empty,
    /// IEEE 1364-2005 §10 the tasks and functions of every instance.
    subs: std.ArrayList(Sub) = .empty,
    /// A subroutine by its name in the instance that declares it.
    sub_by_name: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// Per instance scope, the index of its first `subs` row: a call site is
    /// typed once per module, so it records a module-relative index
    /// (`call_subs`) and each instance adds its own base.
    sub_base: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    call_subs: std.AutoHashMapUnmanaged(Ast.ExprId, u32) = .empty,
    /// §10.3 a `disable` of a subroutine with synchronous activations in
    /// progress: every activation returns at once until the outermost one.
    unwind: ?u32 = null,
    sync_depth: u16 = 0,
    /// Compiling a function body, which §10.4.4 restricts.
    in_function: bool = false,
    /// The saved storage of the automatic activations in progress.
    saved_planes: std.ArrayList(u64) = .empty,
    /// §10.2.3 the activations of recursive timed tasks: the one the
    /// executing process is in (0 for none), every one in progress, and the
    /// rows free for reuse.
    ctx: u32 = 0,
    acts: std.ArrayList(exec.Act) = .empty,
    free_acts: std.ArrayList(u32) = .empty,
    /// The instruction a system task is running from, so `%m` can name the
    /// §5.3.2 named blocks around it.
    pc: u32 = 0,
    /// §12.4 one instance NAME, keyed by the scope that instantiated it, to the
    /// scope it minted. `names` cannot carry this: an instance is not storage,
    /// and a downward hierarchical reference walks these before it reaches a
    /// slot at all.
    instances: std.AutoHashMapUnmanaged(Name, u32) = .empty,
    /// IEEE 1364 §19.10's regions, in text-stream order. Read once per
    /// unconnected input port; `lib/ir/lower/node.zig`'s `applyUnconnectedDrive` is
    /// the analog half of the same directive.
    drives: []const Front.Preprocessor.DriveRegion = &.{},
    /// Variables, array elements and nets share one slot space, so one `store`
    /// wakes event waiters for all three.
    values: []Int.Literal,
    /// Which of `nets` a slot is, for the slots that are nets at all. A map and
    /// not a `net_base` boundary because §6.2.2 elaboration interleaves one
    /// instance's variables with the next one's nets.
    net_of: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    nets: []Net = &.{},
    drivers: []Driver = &.{},
    /// §7.6 every pass switch.
    trans: []Tran = &.{},
    /// Keyed by the base slot of an unpacked array (§3.9).
    arrays: std.AutoHashMapUnmanaged(u32, Array) = .empty,
    /// The slots that are §5.10.4 named events. They occupy a slot only so that
    /// `@(e)` and `-> e` can meet on the waiter list; nothing is ever stored
    /// there, because §5.10's events "do not hold any data".
    events: std.AutoHashMapUnmanaged(u32, void) = .empty,
    // Natural types, indexed by AST ExprId; width zero marks an unvisited row.
    types: []Type = &.{},
    /// Which system function each `.sys_call` is, indexed by AST ExprId and
    /// written by `infer` — so evaluation switches on it instead of hashing
    /// the name again. Null for every other node.
    sys_calls: []?compile.SysFn = &.{},
    replications: std.AutoHashMapUnmanaged(Ast.ExprId, u32) = .empty,
    code: std.ArrayList(Instruction) = .empty,
    /// The instance scope each instruction was compiled in, one row per `code`
    /// row. A process never leaves the scope it was written in, so `execute`
    /// reads this once per dispatch — including on an event resumption, which
    /// re-enters at a pc in the middle of a body.
    code_scope: std.ArrayList(u32) = .empty,
    case_targets: std.ArrayList(u32) = .empty,
    /// §5.3.2 the pc range of each named sequential block, keyed the way every
    /// other declared name is — per §6.2.2 INSTANCE, so two instances of one
    /// definition disable their own copy and not each other's.
    /// `depth` is the block's statement nesting, which orders two named
    /// blocks with the same range (`begin : a begin : b ... end end`) for `%m`.
    blocks: std.AutoHashMapUnmanaged(Name, struct { start: u32, end: u32, depth: u16 }) = .empty,
    /// The `.disable_block` instructions still waiting for their range, and the
    /// name each one is waiting for. A.6.5 puts no ordering rule on a
    /// `disable`: the block it names is routinely in ANOTHER process, which may
    /// not be compiled yet, so the lookup is deferred to one pass at the end
    /// rather than failing in the middle of a dispatch.
    disables: std.ArrayList(struct { at: u32, name: Name, tok: u32 }) = .empty,
    // One counter per lexical repeat is sufficient without recursive processes.
    repeats: std.ArrayList(u64) = .empty,
    /// §9.8.2 one counter per lexical `fork`: the arms still running. One per
    /// SITE is enough for `repeats`' reason — the parent waits at the site.
    joins: std.ArrayList(u32) = .empty,
    /// §9.3 the procedural continuous assignments in effect, by slot: the
    /// process range of an `assign` and of a `force`. While one is, ordinary
    /// writes to the slot do not land (`store`); a force outranks an assign.
    overrides: std.AutoHashMapUnmanaged(u32, Overrides) = .empty,
    /// `store` from an override's own process, which the guard lets through.
    overriding: bool = false,
    // §8.5.3.3 one parked right-hand side per lexical intra-assignment timing
    // control. One cell per SITE is enough for the same reason `repeats` is:
    // the process that reached it is suspended there, so it cannot reach it
    // again before the `deposit` consumes the value.
    holds: std.ArrayList(Int.Literal) = .empty,
    /// Payload rows, indexed by the scheduler's `payload`. Recycled through
    /// `free_rows`, so this is bounded by the most events queued at once.
    pending: std.ArrayList(Row) = .empty,
    free_rows: std.ArrayList(u32) = .empty,
    waiters: std.ArrayList(Waiter) = .empty,
    scheduler: Scheduler,
    /// The source's own path, so §17.2.9's memory file resolves beside the
    /// module that names it.
    file_name: []const u8 = "",
    io: ?std.Io = null,
    scale: ?Time.Scale = null,
    /// The module's TIME UNIT as a power of ten of a second, which `Scale`
    /// deliberately does not keep — it stores ratios, and `%t` needs the
    /// absolute magnitude to reach §17.3's `units_number`.
    unit_exp: i32 = 0,
    time_format: TimeFormat = .{},
    /// §17.3.2 Table 17-11's default `units_number`: "the smallest time
    /// precision argument of all the `timescale compiler directives".
    finest: i32 = 0,
    /// §17.1.3 the one standing monitor. A second `$monitor` replaces it;
    /// there is no stack.
    monitor: ?struct { args: []const Ast.ExprId, show: Show, scope: u32, pc: u32 } = null,
    monitor_on: bool = true,
    /// One `.monitor` event per timestep however many values moved.
    monitor_pending: bool = false,
    /// The slots the standing monitor's arguments read — §17.1.3's "variable
    /// or an expression in the argument list". Clock queries read no slot,
    /// which is the clause's `$time`/`$stime`/`$realtime` exception.
    monitor_slots: std.ArrayList(u32) = .empty,
    /// Per slot, who is told when its value changes. `store` tests this on
    /// every change and nothing else: it is the one value-change hook, whose
    /// first watcher is §17.1.3's monitor; §18's value change dump and VAMS
    /// §8.5's implicit D2A are the same event, each a member of its own.
    watch: []std.EnumSet(Watcher) = &.{},
    /// One region-3b event per tick however many analog-read values moved,
    /// the same coalescing `monitor_pending` does for region 4.
    analog_pending: bool = false,
    /// §8.5 the explicit D2A terms, the ones that occurred this tick (bit =
    /// `D2aSite.site`), and the one region-1b event that reports them.
    d2a_sites: std.ArrayList(D2aSite) = .empty,
    d2a_fired: u64 = 0,
    d2a_pending: bool = false,
    /// Elaborating the digital half of a mixed-signal module (`Options.mixed`).
    mixed: bool = false,
    /// §3.3 the declared `[msb:lsb]` of every packed vector, by slot, so a
    /// bit-select can name its bit (IEEE 1364-2005 §5.2.1). A slot absent from
    /// here is `[width-1:0]`.
    vec_ranges: std.AutoHashMapUnmanaged(u32, VecRange) = .empty,
    /// Called after a `.vpi`-watched slot changed value and its waiters were
    /// woken. The VPI installs it; nothing else in the engine reads it.
    vpi_change: ?*const fn (r: *Run, slot: u32) void = null,
    /// IEEE 1364-2005 §12.3.11 "the sign attribute shall not cross
    /// hierarchy": a port that COLLAPSED onto its parent's net shares the
    /// parent's slot but keeps its own declaration's signedness. Keyed by the
    /// port's name in the child, and present only where the two differ.
    port_signed: std.AutoHashMapUnmanaged(Name, bool) = .empty,
    /// Pass one's slot space while it is still growing: the view `constant`
    /// evaluates a bound or a parameter against before `values` is final.
    growing: ?*std.ArrayList(Int.Literal) = null,
    /// §12.2 parameter slots — constants an expression may fold, never a
    /// target.
    params: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// IEEE 1364-2005 §4.8 `real` variables and VAMS §3.7 `wreal` nets: slots
    /// holding a double's 64 bits, which typing, conversion and change
    /// detection read as a real.
    reals: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// §17.6 the stochastic queues, by `q_id`.
    queues: std.AutoHashMapUnmanaged(i64, @import("system.zig").Queue) = .empty,
    /// §17.2 the files opened for reading, by descriptor order; a closed one
    /// is null.
    files: std.ArrayList(?@import("system.zig").File) = .empty,
    /// §5.2.1 each part-select's constant `[msb:lsb]`, folded once by `infer`.
    part_selects: std.AutoHashMapUnmanaged(Ast.ExprId, VecRange) = .empty,
    /// §18 the value change dump.
    vcd: @import("vcd.zig").Vcd = .{},

    /// VAMS §8.5 / §8.4.3.2: the analog block reads `slot` outside any event
    /// guard, so it is implicitly sensitive to it and every change is an
    /// implicit D2A. From now on a change of it makes `runUntil` stop with
    /// `.analog` at region 3b of the tick it happened in.
    pub fn watchAnalog(r: *Run, at: u32) void {
        r.watch[at].insert(.analog);
    }

    /// VAMS §7.3.4 / §8.5: an analog event control waits on `edge` of `slot`
    /// (a variable, net or named event), as term `site` < 64. From now on the
    /// event makes `runUntil` stop with `.explicit_d2a` at region 1b of its
    /// tick, with bit `site` set in `d2a_fired`.
    pub fn watchEvent(r: *Run, at: u32, edge: exec.Edge, site: u6) Error!void {
        r.watch[at].insert(.d2a);
        try r.d2a_sites.append(r.arena, .{ .slot = at, .edge = edge, .site = site });
    }

    /// Dispatch every event at a time <= `limit` (IEEE 1364 §11.4's loop,
    /// VAMS §8.5.1's regions), then return with the queue holding only later
    /// work. `limit = maxInt` is the whole simulation, which is `run`. Calling
    /// again with a larger limit resumes; nothing is lost between calls
    /// because every suspended process is a waiter or a queued event.
    pub fn runUntil(r: *Run, limit: Tick) Error!Stop {
        var scratch = std.heap.ArenaAllocator.init(r.arena);
        defer scratch.deinit();
        while (r.scheduler.nextUntil(limit)) |event| {
            _ = scratch.reset(.retain_capacity);
            if (event.region == .analog) {
                r.analog_pending = false;
                return .analog;
            }
            // §8.4.7 "Digital to analog events shall cause an analog solution
            // of the time where they occur": 1b is always followed by 3b.
            if (event.region == .explicit_d2a) {
                r.d2a_pending = false;
                try exec.requestAnalog(r);
                return .explicit_d2a;
            }
            const item = r.pending.items[event.payload].item;
            switch (item) {
                .run_process => |start| {
                    r.ctx = 0;
                    try exec.execute(r, &scratch, start);
                },
                .@"resume" => |x| {
                    r.ctx = x.ctx;
                    try exec.makeResident(r, x.ctx);
                    try exec.execute(r, &scratch, x.pc);
                },
                .write => |w| try exec.write(r, scratch.allocator(), .{ .slot = w.target, .sel = w.sel }, w.value),
                .strobe => |s| {
                    r.scope = s.scope;
                    r.pc = s.pc;
                    try display.display(r, s.args, scratch.allocator(), s.show);
                },
                .monitor_tick => {
                    r.monitor_pending = false;
                    try display.monitorPrint(r, scratch.allocator());
                },
                .vcd_tick => try @import("vcd.zig").tick(r, scratch.allocator()),
                .tran_switch => |at| {
                    const t = &r.trans[at];
                    t.pending = null;
                    t.state = t.target;
                    try exec.resolve(r, t.a);
                    try exec.resolve(r, t.b);
                },
                // §6.1.3: a cancelled transition never gets here — the scheduler
                // dropped it — so what arrives is the one still in flight.
                .drive => |at| {
                    const d = &r.drivers[at];
                    d.transition.in_flight = null;
                    @memcpy(d.current.planes, d.transition.target.planes);
                    d.or_z = d.transition.or_z;
                    try exec.resolve(r, d.net);
                },
                .net_update => |at| {
                    const n = &r.nets[at];
                    n.transition.in_flight = null;
                    try exec.store(r, n.slot, n.transition.target.planes);
                },
                // §3.8: the charge has been held for the decay time, and what a
                // trireg holds once it is worth nothing is x.
                .decay => |at| {
                    const n = &r.nets[at];
                    n.decay_event = null;
                    for (0..n.resolved.width) |i| setBit(n.resolved, @intCast(i), .x);
                    try exec.store(r, n.slot, n.resolved.planes);
                },
            }
            // Freed only now: the `.write` planes above are this row's own, and
            // nothing dispatched may reuse them before `store` has copied them.
            try r.free_rows.append(r.arena, event.payload);
        }
        return .idle;
    }

    /// The slot a name declared in the design's ROOT scope is stored in, or
    /// null when the root declares no such variable or net. `values[slot]` is
    /// its current value; this is how a caller outside the engine reads one.
    pub fn slotOf(self: *const Run, name: []const u8) ?u32 {
        const str = self.file.strings.find(name) orelse return null;
        return self.names.get(.{ .scope = 0, .str = str });
    }

    pub fn fail(self: *Run, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        const start = self.starts[@min(tok, self.starts.len - 1)];
        self.bag.add(.lower, .E1100, .{ .start = start, .end = start }, fmt, args) catch return error.OutOfMemory;
        return error.DigitalFailed;
    }
    pub fn exprFail(self: *Run, e: Ast.ExprId, comptime msg: []const u8) Error {
        return self.fail(self.file.exprs.mainTok(e), "{s}", .{msg});
    }
    /// §12.4 a DOWNWARD hierarchical reference: every part but the last names an
    /// instance declared in the scope before it, and the last is a declared name
    /// in the scope the final instance minted. Upward references (§12.5) resolve
    /// by searching enclosing scopes and are not implemented — a name that does
    /// not descend from the referring scope is simply undeclared here.
    pub fn slot(self: *Run, e: Ast.ExprId) Error!u32 {
        const ex = &self.file.exprs;
        if (ex.tag(e) == .hier_ident) {
            const parts = ex.nameParts(e);
            var scope = self.instanceOf(self.scope);
            for (parts[0 .. parts.len - 1]) |part|
                scope = self.instances.get(.{ .scope = scope, .str = part }) orelse
                    return self.exprFail(e, "undeclared instance in a hierarchical reference");
            return self.names.get(.{ .scope = scope, .str = parts[parts.len - 1] }) orelse
                self.exprFail(e, "undeclared digital variable");
        }
        if (ex.tag(e) != .ident) return self.exprFail(e, "only whole-variable lvalues are implemented");
        return self.lookup(self.scope, ex.strOf(e)) orelse self.exprFail(e, "undeclared digital variable");
    }
    /// The type a slot's value has, for an assignment to it.
    pub fn slotType(self: *const Run, at: u32) compile.Type {
        if (self.reals.contains(at)) return compile.real_type;
        return .{ .width = self.values[at].width, .signed = self.values[at].signed };
    }
    /// §12.7 a name as seen from `scope`: declared there, or in an enclosing
    /// scope of the same module — never across an instance boundary.
    pub fn lookup(self: *const Run, scope: u32, str: Ast.StrId) ?u32 {
        var s = scope;
        while (true) {
            if (self.names.get(.{ .scope = s, .str = str })) |at| return at;
            const info = self.scope_info.items[s];
            if (!info.lexical) return null;
            s = info.parent;
        }
    }
    /// The instance a (possibly nested) scope belongs to.
    pub fn instanceOf(self: *const Run, scope: u32) u32 {
        var s = scope;
        while (self.scope_info.items[s].lexical) s = self.scope_info.items[s].parent;
        return s;
    }
    /// A constant expression's value at elaboration (IEEE 1364-2005 §5.2 /
    /// §12.2): literals, parameters, operators and the constant system
    /// functions, folded by the engine's own evaluator — so a bound and a
    /// run-time expression cannot disagree about an operator. The result's
    /// planes are fresh arena memory, never a literal's own.
    pub fn constant(self: *Run, e: Ast.ExprId, tok: u32) Error!Int.Literal {
        if (self.growing) |g| self.values = g.items;
        try compile.checkExpr(self, e);
        if (!compile.constantExpression(self, e)) return self.fail(tok, "a constant expression is required here", .{});
        const v = try exec.eval(self, self.arena, e, 0);
        const out = try filled(self.arena, v.width, v.signed, .zero);
        @memcpy(out.planes, v.planes);
        return out;
    }
    /// One declared bound (§3.3, §4.3.1): any constant expression, and — the
    /// §4.3.1 example `[-2:1]` — any sign.
    fn declaredBound(self: *Run, e: Ast.ExprId, tok: u32) Error!i64 {
        if (self.file.exprs.tag(e) == .int_literal) return self.file.exprs.intValue(e);
        return (try self.constant(e, tok)).asInt() orelse self.fail(tok, "a declaration bound cannot contain x or z", .{});
    }
    /// A.2.2.3 `delay_value ::= unsigned_number | real_number | identifier`, in
    /// scheduler ticks. Elaboration-time, because a net's or a driver's delay is
    /// fixed for the run — only a procedural `#` re-evaluates.
    ///
    /// The `identifier` alternative names a parameter, so anything but a
    /// literal goes through `constant`.
    fn declaredDelay(self: *Run, e: Ast.ExprId, tok: u32) Error!u64 {
        const scale = self.scale.?; // elaborate always sets one (§19.8)
        return switch (self.file.exprs.tag(e)) {
            .real_literal => scale.realDelay(self.file.exprs.realValue(e)),
            .int_literal => scale.signedDelay(self.file.exprs.intValue(e)),
            else => scale.signedDelay((try self.constant(e, tok)).asInt() orelse return self.fail(tok, "a declared delay cannot contain x or z", .{})), // else: any other form is a constant expression, which `constant` folds or refuses
        } catch self.fail(tok, "digital delay cannot be represented", .{});
    }

    /// One A.2.2.3 `delay3` as the three tick counts §7.14 chooses between. The
    /// two-value form leaves `off` unwritten because the clause derives it —
    /// "the smallest of the delays" — rather than spelling it.
    fn declaredDelay3(self: *Run, d: Ast.Delay3, tok: u32) Error!Delay {
        if (!d.any()) return .{};
        var out: Delay = .{ .present = true };
        out.rise = try self.declaredDelay(d.rise, tok);
        out.fall = try self.declaredDelay(d.fall, tok);
        out.off = if (d.off != .none) try self.declaredDelay(d.off, tok) else @min(out.rise, out.fall);
        return out;
    }

    /// §3.3/§6.5.2 a packed `[msb:lsb]` range as a bit width.
    fn declaredWidth(self: *Run, range: Ast.Dim, tok: u32) Error!u32 {
        const hi = try self.declaredBound(range.msb, tok);
        const lo = try self.declaredBound(range.lsb, tok);
        if (@abs(hi - lo) >= std.math.maxInt(u32)) return self.fail(tok, "packed range is outside the supported u32 width", .{});
        return @intCast(@abs(hi - lo) + 1);
    }
    fn bind(self: *Run, name: Ast.StrId, at: u32, tok: u32) Error!void {
        const entry = try self.names.getOrPut(self.arena, .{ .scope = self.scope, .str = name });
        if (entry.found_existing) return self.fail(tok, "duplicate digital variable", .{});
        entry.value_ptr.* = at;
    }
    /// A reference to ONE whole value. §3.9's unpacked array has no value of
    /// its own — only its elements do — so a bare array name is refused here.
    /// The slot an lvalue's WIDTH comes from: an array element reference is as
    /// wide as element zero, so a parked value can be sized before §8.5.3.3
    /// resolves which element it lands in.
    pub fn baseSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const ex = &self.file.exprs;
        return if (ex.tag(e) == .index) self.slot(self.chainBase(e).base) else self.scalarSlot(e);
    }
    /// The name at the bottom of a stack of selects, `a` in `a[i][j]`, and
    /// how many selects stand on it.
    pub fn chainBase(self: *const Run, e: Ast.ExprId) struct { base: Ast.ExprId, depth: u32 } {
        const ex = &self.file.exprs;
        var x = e;
        var depth: u32 = 0;
        while (ex.tag(x) == .index) : (depth += 1) x = ex.lhs(x);
        return .{ .base = x, .depth = depth };
    }
    pub fn scalarSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const at = try self.slot(e);
        if (self.arrays.contains(at)) return self.exprFail(e, "an unpacked array reference requires an element index");
        return at;
    }
    /// The array an `.index` names an ELEMENT of — one index per dimension
    /// (§4.9) — or null when it is a bit or part select.
    pub fn indexedArray(self: *Run, e: Ast.ExprId) Error!?Array {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .index) return null;
        const c = self.chainBase(e);
        if (ex.tag(c.base) != .ident) return null;
        const arr = self.arrays.get(try self.slot(c.base)) orelse return null;
        return if (c.depth == 1 + arr.rest.len) arr else null;
    }
};

// ---- elaboration (§6.2.2, §6.5, §6.5.7.1, IEEE 1364 §19.10) -----------------

/// A.2.4 `net_assignment` and everything else that ends up as one driver of one
/// net: the module's own `assign`s, a `net_decl_assignment`, and the two halves
/// of a §6.5.7 port connection that could not collapse to a single net.
///
/// `scope` is the instance the EXPRESSION is written in, which for a port
/// connection is the parent and not the module that owns the net.
const Wire = struct {
    net: u32,
    scope: u32,
    value: Ast.ExprId = .none,
    bridge: ?Bridge = null,
    gate: ?Gate = null,
    udp: ?*Udp = null,
    /// Set instead of `value` for IEEE 1364 §19.10's pull — see `Driver.pull`.
    pull: ?Int.Bit = null,
    /// The driven net is bits [lo, lo+width) of `value` read `total` wide.
    slice: ?Slice = null,
    mos: ?Mos = null,
    s0: Ast.Strength = .strong,
    s1: Ast.Strength = .strong,
    delay: Ast.Delay3 = .{},
    tok: u32,
};

/// What the parent decided one port connection is. §6.5.7.1's "matching size
/// rule" plus IEEE 1364 clause 12's "a port is a connection, not an
/// assignment": wherever one net can stand for both sides, `collapse` makes
/// them literally the same net, which is the only model under which a child's
/// DRIVE STRENGTH survives the boundary (d03_11). The other two arms are the
/// fallback for a connection no single net can express.
const PortBind = union(enum) {
    /// §6.2.2 an unconnected port: the child's net exists and nothing feeds it.
    open,
    /// The parent net index this port IS.
    collapse: u32,
    /// An input port fed by a parent expression that is not one whole net.
    receive: struct { expr: Ast.ExprId, scope: u32, tok: u32, slice: ?Slice = null },
    /// An output port whose parent side is a concatenation: the operand nets,
    /// leftmost first (§6.5.7.1 joins them highest-order first).
    send: struct { operands: []const u32, tok: u32 },
};

/// Everything §6.2.2 elaboration accumulates before any expression is compiled.
/// The split is load-bearing: a name lookup in pass two must not run against a
/// slot space a later instance is still growing, and `Int.Literal` slices would
/// move under it.
const Elab = struct {
    values: std.ArrayList(Int.Literal) = .empty,
    nets: std.ArrayList(Net) = .empty,
    wires: std.ArrayList(Wire) = .empty,
    /// One row per elaborated instance: the definition and its name scope.
    insts: std.ArrayList(struct { module: *const Ast.ModuleDecl, scope: u32 }) = .empty,
    /// §7.6 pass switches, with the instance scope their control is read in.
    trans: std.ArrayList(struct { tran: Tran, scope: u32, tok: u32 }) = .empty,
};

/// §6.2.2: the root of the design is the description nothing instantiates.
fn pickTop(r: *Run, modules: []const Ast.ModuleDecl) Error!*const Ast.ModuleDecl {
    var top: ?*const Ast.ModuleDecl = null;
    // IEEE 1364-2005 §13.3.1.1: a configuration's `design` statement names
    // the top-level cells, whatever else the source leaves uninstantiated.
    if (r.file.config_cells.len > 1) return r.fail(0, "digital execution requires exactly one top-level module", .{});
    if (r.file.config_cells.len == 1) return findModule(r, r.file.config_cells[0], 0);
    // §12.1.1: "an instantiated module is not a top" — wherever it is
    // instantiated, a generate arm the scheme does not select included.
    var generated: std.ArrayList(Ast.StrId) = .empty;
    for (modules) |other| for (other.analog) |ab| try generatedModules(r.file, ab.body, &generated, r.arena);
    outer: for (modules) |*candidate| {
        if (candidate.is_connect) continue;
        for (modules) |other| for (other.instances) |inst| {
            if (inst.module == candidate.name) continue :outer;
        };
        if (std.mem.indexOfScalar(Ast.StrId, generated.items, candidate.name) != null) continue;
        if (top != null) return r.fail(candidate.main_tok, "digital execution requires exactly one top-level module", .{});
        top = candidate;
    }
    return top orelse r.fail(0, "digital execution found no top-level module", .{});
}

fn findModule(r: *Run, name: Ast.StrId, tok: u32) Error!*const Ast.ModuleDecl {
    for (r.file.modules) |*m| if (m.name == name) {
        if (m.is_connect) return r.fail(tok, "a connect module is inserted by §7.6 discipline resolution, not instantiated", .{});
        return m;
    };
    return r.fail(tok, "undeclared module in instantiation", .{});
}

/// One instance's storage: its variables, its nets, its ports' nets, and the
/// driver rows its continuous assignments and port connections contribute.
/// Recurses into child instances AFTER its own nets exist, so a port connection
/// always resolves against a parent that is fully declared.
fn declare(r: *Run, e: *Elab, m: *const Ast.ModuleDecl, scope: u32, binds: []const PortBind, depth: u16) Error!void {
    const arena = r.arena;
    if (depth == 64) return r.fail(m.main_tok, "digital instance hierarchies deeper than 64 levels are not implemented", .{});
    if (!r.mixed and (m.aliasparams.len != 0 or m.branches.len != 0 or m.defparams.len != 0 or m.functions.len != 0 or m.attrs.len != 0))
        return r.fail(m.main_tok, "digital execution currently requires a module with only variables, nets, events, instances and processes", .{});
    // A digital parse makes each generate construct an `analog` block over
    // an `if`; anything else there is a genuine analog block.
    if (!r.mixed) for (m.analog) |ab| if (!isGenerate(r.file, m, ab.body))
        return r.fail(ab.main_tok, "digital execution currently requires a module with only variables, nets, events, instances and processes", .{});
    r.scope = scope;
    try e.insts.append(arena, .{ .module = m, .scope = scope });
    // IEEE 1364-2005 §12.2 module parameters, in declaration order so a
    // default may name an earlier one. A mixed module's parameters are the
    // analog block's (real-valued, overridable by the analog compile).
    // ponytail: no overrides — an instance's `#( … )` and `defparam` are
    // refused above and below — so one value per declaration is exact.
    if (!r.mixed) for (m.params) |p| {
        if (p.dims.len != 0 or (p.ty != .unspecified and p.ty != .integer))
            return r.fail(p.main_tok, "only integral scalar parameters are implemented by digital execution", .{});
        const value = try r.constant(p.default, p.main_tok);
        // §12.2: a range or a type converts the value like an assignment;
        // otherwise the parameter takes the type of its value.
        const ty: compile.Type = if (p.packed_range) |range|
            .{ .width = try r.declaredWidth(range, p.main_tok), .signed = false }
        else if (p.ty == .integer)
            .{ .width = 32, .signed = true }
        else
            .{ .width = value.width, .signed = value.signed };
        const converted = try exec.convert(arena, value, ty);
        const at: u32 = @intCast(e.values.items.len);
        try r.bind(p.name, at, p.main_tok);
        const slot_value = try filled(arena, ty.width, ty.signed, .zero);
        @memcpy(slot_value.planes, converted.planes);
        try e.values.append(arena, slot_value);
        try r.params.put(arena, at, {});
    };
    // §5.10.4 a named event gets a slot so `-> e` and `@(e)` have a rendezvous
    // point on the waiter list; the stored value is never read or written.
    for (m.events) |name| {
        if (e.values.items.len == std.math.maxInt(u32)) return r.fail(m.main_tok, "too many digital storage slots", .{});
        const at: u32 = @intCast(e.values.items.len);
        try r.bind(name, at, m.main_tok);
        try e.values.append(arena, try filled(arena, 1, false, .x));
        try r.events.put(arena, at, {});
    }
    for (m.vars) |v| {
        // A mixed module's real and initialized variables are the ANALOG
        // block's (§7.2.2); a digital process naming one is an undeclared name.
        // ponytail: digital-context `real` (VAMS Table 7-1's real row) is the
        // upgrade — a real lane in the slot space.
        if (r.mixed and (v.ty != .integer or v.init != .none or v.storage == .time)) continue;
        if (v.init != .none and v.dims.len != 0) return r.fail(v.main_tok, "an unpacked array declaration takes no initializer", .{});
        _ = try mintVar(r, v);
    }
    // IEEE 1364-2005 §10.2/§10.4: each task and function is a scope of this
    // instance holding its formals, its locals and a function's result — the
    // storage a static subroutine shares between activations (§10.2.3).
    try r.sub_base.put(arena, scope, @intCast(r.subs.items.len));
    for (m.tasks) |*t| {
        // A mixed module's real-valued function is the analog side's to call
        // (VAMS §4.7); this engine holds no real, so it declares none.
        if (r.mixed and usesReal(t)) continue;
        const f = try frame(r, t, scope);
        const entry = try r.sub_by_name.getOrPut(arena, .{ .scope = scope, .str = t.name });
        if (entry.found_existing) return r.fail(t.main_tok, "duplicate task or function", .{});
        entry.value_ptr.* = @intCast(r.subs.items.len);
        try r.subs.append(arena, .{ .decl = t, .inst = scope, .frame = f });
    }
    for (m.nets) |n| {
        // §7.2.1: a disciplined net is continuous — the analog solver's.
        if (r.mixed and (n.is_ground or continuous(r.file, n.discipline))) continue;
        if (!r.mixed and (n.discipline != .none or n.is_ground))
            return r.fail(n.main_tok, "disciplined and ground nets are not implemented by digital execution", .{});
        const width = if (n.range) |range| try r.declaredWidth(range, n.main_tok) else 1;
        const at = try mintNet(r, e, n.kind, width, n.is_signed, n.name, n.main_tok);
        if (n.range) |range| try r.vec_ranges.put(arena, e.nets.items[at].slot, .{
            .msb = try r.declaredBound(range.msb, n.main_tok),
            .lsb = try r.declaredBound(range.lsb, n.main_tok),
        });
        var net = &e.nets.items[at];
        net.delay = try r.declaredDelay3(n.delay, n.main_tok);
        // A.2.1.3 gives `trireg` its own alternatives, and in them the third
        // `delay3` value is the CHARGE DECAY TIME. It is not a turn-off delay:
        // a trireg in the capacitive state does not turn off, it holds — so the
        // net's own turn-off falls back to §7.14's "smallest of the delays".
        if (n.kind == .trireg and n.delay.off != .none) {
            net.decay = net.delay.off;
            net.delay.off = @min(net.delay.rise, net.delay.fall);
        }
        net.charge = n.charge;
        // A.2.4 `net_decl_assignment` is a continuous assignment written on the
        // declaration, so it is one more driver of that net and not a separate
        // construct. Its delay is the NET's (`wire #3 y = ~a;` — A.2.1.3 puts
        // the `delay3` before the name list, not on the `=`), which is why the
        // row it contributes carries none of its own.
        if (n.init != .none)
            try e.wires.append(arena, .{ .net = at, .scope = scope, .value = n.init, .tok = n.main_tok });
    }
    // §6.5 the ports, after the body nets: a port net minted here is the one a
    // body `wire w;` on the same name was folded into by the parser.
    for (m.ports, 0..) |p, i| {
        if (r.mixed and continuous(r.file, p.discipline)) continue; // §7.2.1 continuous
        const bind = if (i < binds.len) binds[i] else PortBind.open;
        const width = if (p.kind == .wreal) 64 else if (p.range orelse p.type_range) |range| try r.declaredWidth(range, p.main_tok) else 1;
        if (bind == .collapse) {
            // VAMS §3.7: "When the two nets connected by a port are of net
            // type wreal and wire/tri, the resulting single net will be
            // assigned as wreal" — on whichever side the wreal is.
            const outer = &e.nets.items[bind.collapse];
            const merging = (p.kind == .wreal) != (outer.kind == .wreal);
            if (merging and p.kind == .wreal) try promoteWreal(r, e, bind.collapse);
            if (!merging and outer.resolved.width != width)
                return r.fail(p.main_tok, "§6.5.7.1: the sizes of the port and the net connected to it shall match", .{});
            try r.bind(p.name, outer.slot, p.main_tok);
            if (p.is_signed != e.values.items[outer.slot].signed)
                try r.port_signed.put(arena, .{ .scope = scope, .str = p.name }, p.is_signed);
            continue;
        }
        // `p.kind`, NOT `.wire`. A body declaration naming a header port is
        // folded into the `Port` by the parser, so `inout t; tri0 t;` arrives
        // here as one `Port` — and until `Ast.Port` carried a net type that
        // fold DROPPED it, minting every port net `.wire`. The visible effect
        // was that an internal `tri0` read 0 while the identical declaration
        // on a port read z: §7.9's resolution and `netPull`'s undriven value
        // are both functions of the net type, and the port's was a lie.
        const at = try mintNet(r, e, p.kind, width, p.is_signed, p.name, p.main_tok);
        switch (bind) {
            // IEEE 1364 §19.10: an unconnected INPUT port declared in an
            // `unconnected_drive` region is pulled to a logic level THROUGH A
            // PULL-STRENGTH DRIVER. So it is one driver among drivers and meets
            // the net's own type in §7.9 resolution — which is the whole
            // difference from `lib/ir/lower.zig`'s analog approximation, where a
            // potential source can neither tie with a `tri0` nor lose to a
            // `supply0`.
            .open => if (p.direction == .input) {
                const drive = Front.Preprocessor.DriveRegion.inForce(r.drives, r.starts[@min(p.main_tok, r.starts.len - 1)], .default);
                if (drive != .float) try e.wires.append(arena, .{
                    .net = at,
                    .scope = scope,
                    .pull = if (drive == .pull1) .one else .zero,
                    .s0 = .pull,
                    .s1 = .pull,
                    .tok = p.main_tok,
                });
            },
            .collapse => {},
            .receive => |c| try e.wires.append(arena, .{ .net = at, .scope = c.scope, .value = c.expr, .slice = c.slice, .tok = c.tok }),
            .send => |c| {
                // §6.5.7.1 joins the operands highest-order first, so the
                // rightmost operand takes the port's low bits.
                var lo: u32 = 0;
                var k = c.operands.len;
                while (k != 0) {
                    k -= 1;
                    const dst = &e.nets.items[c.operands[k]];
                    const w = dst.resolved.width;
                    if (lo + w > width) return r.fail(c.tok, "§6.5.7.1: the sizes of the port and the net connected to it shall match", .{});
                    try e.wires.append(arena, .{
                        .net = c.operands[k],
                        .scope = scope,
                        .bridge = .{ .src = e.nets.items[at].slot, .src_lo = lo, .dst_lo = 0, .width = w },
                        .tok = c.tok,
                    });
                    lo += w;
                }
                if (lo != width) return r.fail(c.tok, "§6.5.7.1: the sizes of the port and the net connected to it shall match", .{});
            },
        }
    }
    for (m.assigns) |a| {
        const target = try r.scalarSlot(a.target);
        const net = r.net_of.get(target) orelse return r.fail(a.main_tok, "a continuous assignment can only drive a net", .{});
        try e.wires.append(arena, .{ .net = net, .scope = scope, .value = a.value, .s0 = a.strength0, .s1 = a.strength1, .delay = a.delay, .tok = a.main_tok });
    }
    // §7.1 a gate instance is one more driver of its output net, so it joins
    // the same list an `assign` does and resolves against them.
    for (m.gates) |g| {
        const target = try r.scalarSlot(g.out);
        const net = r.net_of.get(target) orelse return r.fail(g.main_tok, "a gate's output terminal must be a net", .{});
        const width = e.nets.items[net].resolved.width;
        // IEEE 1364-2005 §7.1.5/§7.1.6: an instance array is one gate per
        // index, and a terminal as wide as the array gives each gate one bit
        // — the leftmost index the most significant — while a scalar one is
        // shared by all of them.
        const lanes: u32 = if (g.range) |rg| try r.declaredWidth(rg, g.main_tok) else 1;
        // §7.8.5's tables are one bit wide, so a plain gate's output is too.
        if (width != 1 and width != lanes) return r.fail(g.main_tok, "a gate's output terminal is one bit, or one per instance of an array", .{});
        for (0..lanes) |j| {
            const lane: ?u32 = if (g.range == null) null else @intCast(lanes - 1 - j);
            try e.wires.append(arena, .{
                .net = net,
                .scope = scope,
                .gate = .{ .kind = g.kind, .ins = g.ins, .lane = lane, .lanes = lanes, .out_bit = if (width == 1) null else lane },
                .s0 = g.strength0,
                .s1 = g.strength1,
                .delay = g.delay,
                .tok = g.main_tok,
            });
        }
    }
    // IEEE 1364-2005 §7.6/§7.7 switches. A MOS switch drives its output net
    // with what it passes, as a gate does; a CMOS switch is an n-type and a
    // p-type sharing data and output. A pass switch joins its two nets into
    // one resolution while it conducts.
    // ponytail: a MOS or CMOS switch's terminals are scalar nets.
    for (m.switches) |sw| {
        const resistive = switch (sw.kind) {
            .rcmos, .rnmos, .rpmos, .rtran, .rtranif0, .rtranif1 => true,
            .cmos, .nmos, .pmos, .tran, .tranif0, .tranif1 => false,
        };
        switch (sw.kind) {
            .nmos, .pmos, .rnmos, .rpmos, .cmos, .rcmos => {
                const out = r.net_of.get(try r.scalarSlot(sw.terms[0])) orelse return r.fail(sw.main_tok, "a switch's output and inout terminals are nets", .{});
                if (e.nets.items[out].resolved.width != 1) return r.fail(sw.main_tok, "only scalar MOS switch terminals are implemented", .{});
                const cmos = sw.kind == .cmos or sw.kind == .rcmos;
                const n_type = sw.kind == .nmos or sw.kind == .rnmos;
                for (0..@as(usize, if (cmos) 2 else 1)) |half| try e.wires.append(arena, .{
                    .net = out,
                    .scope = scope,
                    .mos = .{ .data = sw.terms[1], .gate = sw.terms[2 + half], .n_type = if (cmos) half == 0 else n_type, .resistive = resistive },
                    .delay = sw.delay,
                    .tok = sw.main_tok,
                });
            },
            .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => {
                const gated = sw.kind != .tran and sw.kind != .rtran;
                // §7.6: the controlled ones take "zero, one, or two delays"
                // (the grammar already refuses any on tran and rtran).
                if (sw.delay.off != .none) return r.fail(sw.main_tok, "§7.6: a pass switch takes at most two delays", .{});
                const ta = try switchTerminal(r, e, sw.terms[0], sw.main_tok);
                const tb = try switchTerminal(r, e, sw.terms[1], sw.main_tok);
                try e.trans.append(arena, .{
                    .tran = .{
                        .a = ta.net,
                        .b = tb.net,
                        .a_bit = ta.bit,
                        .b_bit = tb.bit,
                        .ctrl = if (gated) sw.terms[2] else .none,
                        .on = if (sw.kind == .tranif0 or sw.kind == .rtranif0) .zero else .one,
                        .state = if (gated) .unknown else .on,
                        .target = if (gated) .unknown else .on,
                        .resistive = resistive,
                        .delay = try r.declaredDelay3(sw.delay, sw.main_tok),
                    },
                    .scope = scope,
                    .tok = sw.main_tok,
                });
            },
        }
    }
    // IEEE 1364-2005 §7.8 a pullup/pulldown "shall place a logic value 1 [0]
    // on the nets connected", at pull strength unless one is written: a
    // constant driver, the same row `unconnected_drive` contributes.
    for (m.pulls) |p| {
        const net = r.net_of.get(try r.scalarSlot(p.out)) orelse return r.fail(p.main_tok, "a pull source's terminal must be a net", .{});
        try e.wires.append(arena, .{ .net = net, .scope = scope, .pull = if (p.one) .one else .zero, .s0 = p.strength, .s1 = p.strength, .tok = p.main_tok });
    }
    for (m.instances) |*inst| try instantiate(r, e, scope, inst, depth);
    if (!r.mixed) for (m.analog) |ab| try generate(r, e, scope, ab.body, depth);
}

/// §7.6 "the bidirectional terminals of all six devices shall be connected
/// only to scalar nets or bit-selects of vector nets": the net, and the bit
/// position a constant select names against its declared range.
fn switchTerminal(r: *Run, e: *Elab, t: Ast.ExprId, tok: u32) Error!struct { net: u32, bit: u32 } {
    const ex = &r.file.exprs;
    if (ex.tag(t) != .index) {
        const net = r.net_of.get(try r.scalarSlot(t)) orelse return r.fail(tok, "a switch's output and inout terminals are nets", .{});
        if (e.nets.items[net].resolved.width != 1) return r.fail(tok, "§7.6: a pass switch terminal is a scalar net or a bit-select of a vector net", .{});
        return .{ .net = net, .bit = 0 };
    }
    if (ex.tag(ex.rhs(t)) == .range) return r.fail(tok, "§7.6: a pass switch terminal is a scalar net or a bit-select of a vector net", .{});
    const at = try r.scalarSlot(ex.lhs(t));
    const net = r.net_of.get(at) orelse return r.fail(tok, "a switch's output and inout terminals are nets", .{});
    const index = try r.declaredBound(ex.rhs(t), tok);
    const width: i64 = e.nets.items[net].resolved.width;
    const range = r.vec_ranges.get(at) orelse VecRange{ .msb = width - 1, .lsb = 0 };
    const pos = if (range.msb >= range.lsb) index - range.lsb else range.lsb - index;
    if (pos < 0 or pos >= width) return r.fail(tok, "a pass switch terminal selects a bit outside its net", .{});
    return .{ .net = net, .bit = @intCast(pos) };
}

/// IEEE 1364-2005 §12.4 a generate construct as a digital parse leaves it:
/// an `if` or `case` whose arms are blocks, or a `for` over a genvar (§12.4.1:
/// what tells a loop generate from a loop statement is its genvar).
fn isGenerate(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, s: Ast.StmtId) bool {
    return switch (file.stmt(s)) {
        .if_stmt => |i| i.is_generate,
        .case_stmt => |c| c.is_generate,
        .for_stmt => |f| genvarOf(file, m, f) != null,
        else => false, // else: every other analog-block body is analog behaviour
    };
}

/// §12.4.1 the genvar a loop generate's `genvar_initialization` assigns, or
/// null when the loop's index is no genvar of `m`.
fn genvarOf(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, f: anytype) ?Ast.StrId {
    if (f.init == .none) return null;
    const init = switch (file.stmt(f.init)) {
        .assign => |a| a,
        else => return null, // else: A.4.2 genvar_initialization is an assignment
    };
    if (file.exprs.tag(init.target) != .ident) return null;
    const name = file.exprs.strOf(init.target);
    return if (std.mem.indexOfScalar(Ast.StrId, m.genvars, name) != null) name else null;
}

/// §12.4: the scheme's constant expressions select at most one arm of an
/// `if` or `case` (§12.4.2) and unroll a `for` once per genvar value
/// (§12.4.1), and only the selected blocks' instances come into existence
/// (§12.1.1: an instance in an unselected arm still makes its module no
/// top-level one).
/// ponytail: instances only; a block's other items are refused by the
/// parser. A part-select bound written with a genvar is folded once, with
/// the first iteration's value; a bit-select is read per iteration.
fn generate(r: *Run, e: *Elab, scope: u32, s: Ast.StmtId, depth: u16) Error!void {
    if (s == .none) return;
    const tok = r.file.stmtTok(s);
    switch (r.file.stmt(s)) {
        .empty => {},
        .if_stmt => |i| {
            r.scope = scope;
            const cond = (try r.constant(i.cond, tok)).truth();
            try generate(r, e, scope, if (cond == .one) i.then_s else i.else_s, depth);
        },
        // §12.4.2: "the case_generate_item selected is the one whose
        // expression matches the case expression", the default otherwise.
        .case_stmt => |c| {
            r.scope = scope;
            const value = try r.constant(c.scrutinee, tok);
            var chosen: ?Ast.StmtId = null;
            var fallback: Ast.StmtId = .none;
            for (c.arms) |arm| {
                if (arm.labels.len == 0) fallback = arm.body;
                for (arm.labels) |label| {
                    if (chosen != null) break;
                    const l = try r.constant(label, tok);
                    const ty: Type = .{ .width = @max(l.width, value.width), .signed = l.signed and value.signed };
                    if ((try exec.convert(r.arena, value, ty)).equality(.case_equal, try exec.convert(r.arena, l, ty)) == .one) chosen = arm.body;
                }
            }
            try generate(r, e, scope, chosen orelse fallback, depth);
        },
        // §12.4.1: the genvar steps through its values in the module's scope,
        // and each iteration's block is a scope of its own, `name[value]`, in
        // which the genvar is a local parameter holding that value.
        .for_stmt => |f| {
            const m = findModule(r, r.scope_info.items[r.instanceOf(scope)].module, tok) catch unreachable; // the instance was minted from it
            const gv = genvarOf(r.file, m, f) orelse return r.fail(tok, "§12.4.1: a loop generate's index is a genvar", .{});
            const step = switch (r.file.stmt(f.step)) {
                .assign => |a| a,
                else => return r.fail(tok, "§12.4.1: a loop generate's iteration assigns its genvar", .{}), // else: A.4.2 genvar_iteration is an assignment
            };
            if (r.file.exprs.tag(step.target) != .ident or r.file.exprs.strOf(step.target) != gv)
                return r.fail(tok, "§12.4.1: a loop generate's iteration assigns its genvar", .{});
            r.scope = scope;
            if (r.scope_info.items[scope].index != null and r.names.contains(.{ .scope = scope, .str = gv }))
                return r.fail(tok, "§12.4.1: two nested loop generate constructs cannot use the same genvar", .{});
            const at = r.names.get(.{ .scope = scope, .str = gv }) orelse try genvarSlot(r, e, gv, tok);
            try setGenvar(r, e, at, try r.constant(r.file.stmt(f.init).assign.value, tok));
            const name: Ast.StrId = switch (r.file.stmt(f.body)) {
                .block => |b| b.name,
                else => .none, // else: a lone item is an unnamed generate block
            };
            var seen: std.ArrayList(i64) = .empty;
            while ((try r.constant(f.cond, tok)).truth() == .one) {
                if (seen.items.len == 65536) return r.fail(tok, "§12.4.1: this loop generate does not terminate within 65536 iterations", .{});
                const value = e.values.items[at].asInt() orelse return r.fail(tok, "§12.4.1: a genvar shall not be x or z", .{});
                if (std.mem.indexOfScalar(i64, seen.items, value) != null) return r.fail(tok, "§12.4.1: a genvar value is repeated", .{});
                try seen.append(r.arena, value);
                const iter = try newScope(r, tok);
                try r.scope_info.append(r.arena, .{ .parent = scope, .name = name, .module = m.name, .lexical = true, .index = value });
                r.scope = iter;
                try setGenvar(r, e, try genvarSlot(r, e, gv, tok), e.values.items[at]);
                try generate(r, e, iter, f.body, depth);
                r.scope = scope;
                try setGenvar(r, e, at, try r.constant(step.value, tok));
            }
        },
        .block => |b| {
            for (b.instances) |*inst| try instantiate(r, e, scope, inst, depth);
            for (b.body) |inner| try generate(r, e, scope, inner, depth);
        },
        else => return r.fail(tok, "only generate constructs of instances are implemented by digital execution", .{}), // else: analog behaviour inside a generate block
    }
}

/// A genvar's storage in the current scope: a 32-bit signed constant
/// (§3.5 "an integer"), which `constant` folds like any parameter.
fn genvarSlot(r: *Run, e: *Elab, name: Ast.StrId, tok: u32) Error!u32 {
    const at: u32 = @intCast(e.values.items.len);
    try r.bind(name, at, tok);
    try e.values.append(r.arena, try filled(r.arena, 32, true, .x));
    r.values = e.values.items;
    try r.params.put(r.arena, at, {});
    return at;
}

fn setGenvar(r: *Run, e: *Elab, at: u32, value: Int.Literal) Error!void {
    @memcpy(e.values.items[at].planes, (try exec.convert(r.arena, value, .{ .width = 32, .signed = true })).planes);
}

/// Every module a generate construct instantiates, in either arm.
fn generatedModules(file: *const Ast.SourceFile, s: Ast.StmtId, out: *std.ArrayList(Ast.StrId), a: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (s == .none) return;
    switch (file.stmt(s)) {
        .if_stmt => |i| {
            try generatedModules(file, i.then_s, out, a);
            try generatedModules(file, i.else_s, out, a);
        },
        .case_stmt => |c| for (c.arms) |arm| try generatedModules(file, arm.body, out, a),
        .for_stmt => |f| try generatedModules(file, f.body, out, a),
        .block => |b| {
            for (b.instances) |inst| try out.append(a, inst.module);
            for (b.body) |inner| try generatedModules(file, inner, out, a);
        },
        else => {}, // else: no other statement holds an instance
    }
}

/// §6.2.2 one module or UDP instance, declared in `scope`.
fn instantiate(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, depth: u16) Error!void {
    const arena = r.arena;
    r.scope = scope;
    {
        if (inst.range != null or inst.params.len != 0)
            return r.fail(inst.main_tok, "instance arrays and parameter overrides are not implemented by digital execution", .{});
        if (findUdp(r.file, inst.module)) |u| return declareUdp(r, e, scope, inst, u);
        const child = try findModule(r, inst.module, inst.main_tok);
        const binds_out = try arena.alloc(PortBind, child.ports.len);
        @memset(binds_out, .open);
        for (inst.ports, 0..) |conn, i| {
            // IEEE 1364-2005 §12.3.2/§12.3.6: a header port `.name(expr)` is
            // connected by its EXTERNAL name, and when its expression is a
            // concatenation of internal ports every one of them is a slice
            // of the one connection — leftmost the most significant.
            if (conn.name != .none and portByName(child, conn.name) == null) {
                const first = for (child.ports, 0..) |p, k| {
                    if (p.external_name == conn.name) break k;
                } else return r.fail(conn.main_tok, "the instantiated module has no such port", .{});
                var total: u32 = 0;
                var last = first;
                while (last < child.ports.len and child.ports[last].external_name == conn.name) : (last += 1)
                    total += try portWidth(r, child.ports[last]);
                var lo = total;
                for (child.ports[first..last], first..) |p, k| {
                    if (p.direction != .input) return r.fail(conn.main_tok, "only an input port may be a concatenation of internal ports", .{});
                    const w = try portWidth(r, p);
                    lo -= w;
                    r.scope = scope;
                    binds_out[k] = if (conn.expr == .none) .open else .{ .receive = .{ .expr = conn.expr, .scope = scope, .tok = conn.main_tok, .slice = .{ .lo = lo, .total = total } } };
                }
                continue;
            }
            const at = if (conn.name == .none) i else portByName(child, conn.name).?;
            if (at >= child.ports.len) return r.fail(conn.main_tok, "more port connections than the module has ports", .{});
            r.scope = scope;
            // A continuous port is the analog solver's on both sides (§7.2.1),
            // so a mixed design's digital half connects nothing through it —
            // the same skip the child's own port loop makes.
            if (r.mixed and continuous(r.file, child.ports[at].discipline)) continue;
            binds_out[at] = try bindPort(r, child.ports[at], conn, scope);
        }
        const child_scope = try newScope(r, inst.main_tok);
        try r.scope_info.append(arena, .{ .parent = scope, .name = inst.name, .module = child.name });
        // §12.4's path is walked by NAME, so the instance's own identifier has
        // to outlive the recursion that consumes it.
        if (inst.name != .none) try r.instances.put(arena, .{ .scope = scope, .str = inst.name }, child_scope);
        try declare(r, e, child, child_scope, binds_out, depth + 1);
        r.scope = scope;
    }
}

/// VAMS §3.6.2.2: is `name` a CONTINUOUS discipline — the analog solver's —
/// rather than a discrete one such as Annex D's `ddiscrete`, whose nets are
/// §7.2's digital nets and this engine's? A net is a net by its declaration;
/// the discipline only says which kernel resolves it. The same rule as
/// `lib/ir/lower/discipline.zig`'s `isContinuous` (the last declaration wins;
/// an undeclared domain is continuous when a nature is bound), restated here
/// because `sim` cannot import `ir`.
fn continuous(file: *const Ast.SourceFile, name: Ast.StrId) bool {
    if (name == .none) return false;
    var i = file.disciplines.len;
    while (i > 0) {
        i -= 1;
        const d = &file.disciplines[i];
        if (d.name != name) continue;
        return switch (d.domain) {
            .continuous => true,
            .discrete => false,
            .unspecified => d.potential != .none or d.flow != .none,
        };
    }
    return false;
}

pub fn newScope(r: *Run, tok: u32) Error!u32 {
    r.scopes += 1;
    if (r.scopes == std.math.maxInt(u32)) return r.fail(tok, "too many digital instances", .{});
    return r.scopes;
}

/// One variable's storage in the current scope — a whole value, or §3.9's
/// array of them — bound to its name. Works in both passes: an automatic
/// task inlined at a call site gets fresh storage while pass two compiles it.
pub fn mintVar(r: *Run, v: Ast.VarDecl) Error!u32 {
    const g = r.growing.?;
    if (v.ty == .string) return r.fail(v.main_tok, "string variables are not implemented", .{});
    const real = v.ty == .real;
    if (v.dims.len > 16) return r.fail(v.main_tok, "arrays of more than 16 dimensions are not implemented", .{});
    // §4.8: `integer` is 32 signed bits and `time` 64 unsigned ones.
    // §4.8: a real is a double, held as its 64 bits.
    const width: u32 = if (real) 64 else if (v.packed_range) |range| try r.declaredWidth(range, v.main_tok) else switch (v.storage) {
        .reg => 1,
        .variable => 32,
        .time => 64,
    };
    const base: u32 = @intCast(g.items.len);
    try r.bind(v.name, base, v.main_tok);
    if (v.packed_range) |range| try r.vec_ranges.put(r.arena, base, .{
        .msb = try r.declaredBound(range.msb, v.main_tok),
        .lsb = try r.declaredBound(range.lsb, v.main_tok),
    });
    var count: u32 = 1;
    if (v.dims.len != 0) {
        const spans = try r.arena.alloc(Span, v.dims.len);
        for (v.dims, spans) |d, *s| {
            const lo = try r.declaredBound(d.lsb, v.main_tok);
            const hi = try r.declaredBound(d.msb, v.main_tok);
            s.* = .{ .low = @min(lo, hi), .high = @max(lo, hi) };
            const size = std.math.cast(u32, s.high - s.low + 1) orelse return r.fail(v.main_tok, "unpacked array size is outside the supported u32 range", .{});
            count = std.math.mul(u32, count, size) catch return r.fail(v.main_tok, "unpacked array size is outside the supported u32 range", .{});
        }
        try r.arrays.put(r.arena, base, .{ .count = count, .low = spans[0].low, .high = spans[0].high, .rest = spans[1..] });
    }
    if (count > std.math.maxInt(u32) - g.items.len) return r.fail(v.main_tok, "too many digital storage slots", .{});
    const signed = switch (v.storage) {
        .reg => v.is_signed,
        .variable => true,
        .time => false,
    };
    // §4.8: "the default initial value for real ... shall be 0.0"; every
    // other variable starts at x (§3.2).
    for (0..count) |i| {
        try g.append(r.arena, try filled(r.arena, width, signed or real, if (real) .zero else .x));
        if (real) try r.reals.put(r.arena, base + @as(u32, @intCast(i)), {});
    }
    r.values = g.items;
    return base;
}

/// §10 one subroutine as the engine runs it: the declaration, the instance
/// that declared it, and its static frame. `entry` is the pc of its body
/// compiled for a synchronous call; a task with timing controls has none,
/// and is inlined at each enable instead (`ranges` are those copies, for
/// §10.3's `disable`).
pub const Sub = struct {
    decl: *const Ast.Subroutine,
    inst: u32,
    frame: Frame,
    entry: u32 = 0,
    timed: ?bool = null,
    /// Synchronous activations in progress.
    active: u32 = 0,
    /// Being inlined right now, which a timed task reaching itself would be.
    inlining: bool = false,
    /// A timed task that reaches itself: its body compiled once out of line,
    /// over a frame of its own, entered by `.call_timed` (§10.2.3). The
    /// activation whose storage the frame holds is `resident`.
    body: ?struct { entry: u32, frame: Frame } = null,
    resident: u32 = 0,
    ranges: std.ArrayList(struct { start: u32, end: u32 }) = .empty,
};

fn usesReal(t: *const Ast.Subroutine) bool {
    if (t.is_function and t.result.ty != .integer) return true;
    for (t.ports) |p| if (p.v.ty != .integer) return true;
    for (t.vars) |v| if (v.ty != .integer) return true;
    return false;
}

/// One activation's storage: a scope, a slot per formal, the result slot of
/// a function, and the contiguous slot range an automatic activation saves.
/// §9.3 one slot's procedural continuous assignments: the pc range of the
/// process maintaining each.
pub const Overrides = struct {
    assign: ?PcRange = null,
    force: ?PcRange = null,
};
pub const PcRange = struct { start: u32, end: u32 };

pub const Frame = struct { scope: u32, ports: []const u32, result: u32, first: u32, count: u32 };

/// A fresh frame for `t` inside instance `inst`: its static one in pass one,
/// an automatic task's per-call-site one in pass two.
pub fn frame(r: *Run, t: *const Ast.Subroutine, inst: u32) Error!Frame {
    const g = r.growing.?;
    const scope = try newScope(r, t.main_tok);
    try r.scope_info.append(r.arena, .{ .parent = inst, .name = t.name, .module = r.scope_info.items[inst].module, .lexical = true });
    const saved = r.scope;
    r.scope = scope;
    defer r.scope = saved;
    const first: u32 = @intCast(g.items.len);
    const ports = try r.arena.alloc(u32, t.ports.len);
    for (t.ports, ports) |p, *slot| slot.* = try mintVar(r, p.v);
    const result = if (t.is_function) try mintVar(r, t.result) else 0;
    for (t.vars) |v| {
        if (v.init != .none) return r.fail(v.main_tok, "an initialized task or function variable is not implemented", .{});
        _ = try mintVar(r, v);
    }
    return .{ .scope = scope, .ports = ports, .result = result, .first = first, .count = @as(u32, @intCast(g.items.len)) - first };
}

/// VAMS §3.7's port merge: a wire or tri joined to a wreal port becomes one
/// wreal net, for every other connection to it too. `wrealRules` has
/// already refused the net types §3.7 does not call compatible.
fn promoteWreal(r: *Run, e: *Elab, net: u32) Error!void {
    const n = &e.nets.items[net];
    if (n.kind == .wreal) return;
    n.kind = .wreal;
    n.resolved = try filled(r.arena, 64, false, .z);
    e.values.items[n.slot] = try filled(r.arena, 64, true, .zero);
    r.values = e.values.items;
    try r.reals.put(r.arena, n.slot, {});
}

/// Allocate one net and its slot, and bind `name` to it in the current scope.
fn mintNet(r: *Run, e: *Elab, kind: Ast.NetKind, width: u32, signed: bool, name: Ast.StrId, tok: u32) Error!u32 {
    if (e.values.items.len == std.math.maxInt(u32)) return r.fail(tok, "too many digital storage slots", .{});
    const slot: u32 = @intCast(e.values.items.len);
    const at: u32 = @intCast(e.nets.items.len);
    try r.bind(name, slot, tok);
    // §3.7: a net with no driver is Z, not X — except where the net type itself
    // supplies a value. That is the whole net/variable difference. VAMS §3.7:
    // a wreal carries a real and "shall have an initial value of zero".
    const wreal = kind == .wreal;
    try e.values.append(r.arena, try filled(r.arena, if (wreal) 64 else width, signed or wreal, if (wreal) .zero else undriven(kind)));
    if (wreal) try r.reals.put(r.arena, slot, {});
    const signal = try r.arena.alloc(Signal, width);
    @memset(signal, .{});
    try e.nets.append(r.arena, .{ .kind = kind, .slot = slot, .resolved = try filled(r.arena, if (wreal) 64 else width, false, .z), .signal = signal, .tok = tok });
    try r.net_of.put(r.arena, slot, at);
    return at;
}

fn findUdp(file: *const Ast.SourceFile, name: Ast.StrId) ?*const Ast.UdpDecl {
    for (file.udps) |*u| if (u.name == name) return u;
    return null;
}

/// IEEE 1364-2005 §8 one UDP instance: one more driver of its output net, as
/// a gate is (§8.1: "UDPs are instantiated exactly the same way as gate
/// primitives"), whose value is its table's. §8.5: a sequential UDP's state
/// starts at its `initial` value — or x — and that value is on the output at
/// time 0 whatever the instance delay.
fn declareUdp(r: *Run, e: *Elab, scope: u32, inst: *const Ast.Instance, u: *const Ast.UdpDecl) Error!void {
    const net_mod = @import("net.zig");
    if (inst.ports.len != u.ports.len) return r.fail(inst.main_tok, "§8: a UDP instance connects its output and every input, in order", .{});
    for (inst.ports) |c| if (c.name != .none or c.expr == .none)
        return r.fail(c.main_tok, "§8: a UDP instance connects its terminals by position, none left open", .{});
    const net = r.net_of.get(try r.scalarSlot(inst.ports[0].expr)) orelse return r.fail(inst.main_tok, "a UDP's output terminal must be a net", .{});
    if (e.nets.items[net].resolved.width != 1) return r.fail(inst.main_tok, "only scalar UDP terminals are implemented", .{});
    const rows = (try net_mod.udpRows(r.arena, u)) orelse return r.fail(u.main_tok, "a UDP table entry needs one field per input", .{});
    const ins = try r.arena.alloc(Ast.ExprId, u.ports.len - 1);
    for (inst.ports[1..], ins) |c, *in| in.* = c.expr;
    const prev = try r.arena.alloc(Int.Bit, ins.len);
    @memset(prev, .x);
    const ex = &r.file.exprs;
    const state: Int.Bit = if (u.init == .none) .x else switch (ex.tag(u.init)) {
        .int_literal => if (ex.intValue(u.init) == 0) .zero else .one,
        .logic_literal => ex.logicValue(u.init).bit(0),
        else => return r.exprFail(u.init, "a UDP initial value is 0, 1 or x"), // else: A.5.3 init_val is a literal
    };
    const udp = try r.arena.create(Udp);
    udp.* = .{ .rows = rows, .sequential = u.is_sequential, .ins = ins, .prev = prev, .state = state };
    try e.wires.append(r.arena, .{ .net = net, .scope = scope, .udp = udp, .s0 = inst.strength0, .s1 = inst.strength1, .delay = inst.delay, .tok = inst.main_tok });
}

/// A port by the name a named connection may use: its own, when the header
/// gave it no external name.
fn portByName(m: *const Ast.ModuleDecl, name: Ast.StrId) ?usize {
    for (m.ports, 0..) |p, k| if (p.name == name and p.external_name == .none) return k;
    for (m.ports, 0..) |p, k| if (p.external_name == name and (k + 1 == m.ports.len or m.ports[k + 1].external_name != name) and (k == 0 or m.ports[k - 1].external_name != name)) return k;
    return null;
}

/// A port's declared width, evaluated in the scope being elaborated.
/// ponytail: a child port whose range names the child's parameters is sized
/// before the child exists; the literal ranges every fixture writes are fine.
fn portWidth(r: *Run, p: Ast.Port) Error!u32 {
    if (p.kind == .wreal) return 64;
    return if (p.range orelse p.type_range) |range| r.declaredWidth(range, p.main_tok) else 1;
}

/// §6.5.7 one port connection, decided in the PARENT's scope.
fn bindPort(r: *Run, port: Ast.Port, conn: Ast.PortConn, scope: u32) Error!PortBind {
    if (conn.expr == .none) return .open;
    const ex = &r.file.exprs;
    // One whole net of the right size on the outside is a net COLLAPSE, and
    // that is the only arm under which the child's drive strengths reach the
    // parent's resolution unchanged (IEEE 1364 clause 12: a port is a
    // connection). `bindPort` does not size-check here — `declare` does, once
    // the port's own width is known.
    if (ex.tag(conn.expr) == .ident) {
        if (r.net_of.get(try r.scalarSlot(conn.expr))) |net| return .{ .collapse = net };
    }
    return switch (port.direction) {
        // §6.5.2.2 an input port is a RECEIVER: the child puts no driver on the
        // outside, so whatever the parent wrote feeds the port net.
        .input => .{ .receive = .{ .expr = conn.expr, .scope = scope, .tok = conn.main_tok } },
        .output => blk: {
            if (ex.tag(conn.expr) != .concat) return r.exprFail(conn.expr, "an output port connects to a net or a concatenation of nets");
            const args = ex.args(conn.expr);
            const operands = try r.arena.alloc(u32, args.len);
            for (args, operands) |arg, *out| {
                if (ex.tag(arg) != .ident) return r.exprFail(arg, "an output port connects to a net or a concatenation of nets");
                out.* = r.net_of.get(try r.scalarSlot(arg)) orelse return r.exprFail(arg, "an output port can only drive a net");
            }
            break :blk .{ .send = .{ .operands = operands, .tok = conn.main_tok } };
        },
        // A collapse already covers the useful `inout`; anything else would
        // need a bidirectional bit bridge, which no fixture asks for.
        .inout => r.fail(conn.main_tok, "an inout port connection must name one whole net", .{}),
        .unspecified => r.fail(port.main_tok, "§6.5.2.2: this port has no direction declaration", .{}),
    };
}

/// §6.5.3 and §3.7, the two `wreal` rules about STRUCTURE rather than value.
/// Checked on the parsed file, before elaboration, so a file that breaks one
/// hears the LRM's reason.
// ponytail: drivers are counted per module (assigns and the declaration's
// own `=`); a driver arriving through a port is not. Counting those needs the
// elaborated net, which `declare` builds after this.
fn wrealRules(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag) std.mem.Allocator.Error!void {
    const ex = &file.exprs;
    for (file.modules) |*m| {
        for (m.nets) |n| if (n.kind == .wreal) try wrealDrivers(file, starts, bag, m, n.name, n.init != .none);
        for (m.ports) |p| if (p.kind == .wreal) try wrealDrivers(file, starts, bag, m, p.name, false);
        for (m.instances) |inst| {
            const child = for (file.modules) |*c| {
                if (c.name == inst.module) break c;
            } else continue;
            for (inst.ports, 0..) |conn, i| {
                if (conn.expr == .none or ex.tag(conn.expr) != .ident) continue;
                const port = if (conn.name == .none) (if (i < child.ports.len) child.ports[i] else continue) else for (child.ports) |p| {
                    if (p.name == conn.name) break p;
                } else continue;
                // A name the parent never declared as a net is a variable
                // (a real expression, which 3.7 allows) or an implicit wire.
                const outer = netKind(m, ex.strOf(conn.expr)) orelse continue;
                if ((outer == .wreal) == (port.kind == .wreal)) continue;
                const other = if (outer == .wreal) port.kind else outer;
                if (other == .wire or other == .tri) continue;
                const start = starts[@min(conn.main_tok, starts.len - 1)];
                try bag.add(.lower, .E0919, .{ .start = start, .end = start }, "`{s}` is a {s} and port `{s}` is a {s}", .{
                    file.str(ex.strOf(conn.expr)), @tagName(outer), file.str(port.name), @tagName(port.kind),
                });
            }
        }
    }
}

fn wrealDrivers(file: *const Ast.SourceFile, starts: []const u32, bag: *diag.Bag, m: *const Ast.ModuleDecl, name: Ast.StrId, declared: bool) std.mem.Allocator.Error!void {
    var count: u32 = @intFromBool(declared);
    for (m.assigns) |a| {
        if (a.target == .none or file.exprs.tag(a.target) != .ident or file.exprs.strOf(a.target) != name) continue;
        count += 1;
        if (count != 2) continue;
        const start = starts[@min(a.main_tok, starts.len - 1)];
        try bag.add(.lower, .E0918, .{ .start = start, .end = start }, "`{s}` is already driven", .{file.str(name)});
    }
}

/// The declared net type of `name` in `m`, or null if `m` declares no such net.
fn netKind(m: *const Ast.ModuleDecl, name: Ast.StrId) ?Ast.NetKind {
    for (m.ports) |p| if (p.name == name) return p.kind;
    for (m.nets) |n| if (n.name == name) return n.kind;
    return null;
}

// ---- the driver (§6.2.2, §6.1, §7.9, §17.3) ---------------------------------

/// IEEE 1364-2005 §19.8: "If there is no `timescale specified or it has been
/// reset by a `resetall directive, the time unit and precision are
/// simulator-specific." Not an error — so this simulator's are one second,
/// unit and precision alike, which makes every delay a whole count of units
/// and `$time`, `$realtime` and `%t` print the numbers the source wrote.
const default_quantum: Time.Quantum = .s;

/// Callers own the run arena and diagnostic source lifetime. No analog lowering,
/// generated-device interpretation, external compiler, or secondary lexer is used.
pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    var r = try elaborate(arena, source, opts, bag, out);
    // Nothing is `watchAnalog`ed in a digital-only run, so it never stops early.
    _ = try r.runUntil(std.math.maxInt(Tick));
}

/// Everything `run` does before the first event dispatches: preprocess,
/// parse, §6.2.2 elaboration, and every driver and process compiled and
/// enqueued at time 0. The returned `Run` owns nothing outside `arena`, so a
/// caller that holds it may step it with `runUntil` for as long as the arena
/// lives — which is what a mixed-signal coordinator needs from it.
pub fn elaborate(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!Run {
    const pp: Front.Preprocessor.Output = if (opts.mixed) |mx| .{
        .text = source,
        .directives = .{ .timescales = if (mx.timescale) |t| try arena.dupe(Front.Preprocessor.TimescaleEvent, &.{.{ .at = 0, .value = t }}) else &.{} },
    } else Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .std_defs = false, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    const text = pp.text;
    const times = pp.directives.timescales;
    const drives = pp.directives.drives;
    var tokens = try Front.Lexer.Lexer.tokenize(arena, text);
    var parser = Front.Parser.Parser.init(arena, text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    // A failed parse still leaves every recovered module in `parser.file`, and
    // the `wreal` refusal is itself a parse error, so the rules read that.
    // Arena-owned, not a local: the returned `Run` points at it.
    const file = try arena.create(Ast.SourceFile);
    file.* = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => parser.file,
    };
    try wrealRules(file, tokens.items(.start), bag);
    if (bag.failed()) return error.DigitalFailed;
    var r: Run = .{ .arena = arena, .file = file, .starts = tokens.items(.start), .bag = bag, .out = out, .values = &.{}, .scheduler = Scheduler.init(arena), .file_name = opts.file_name, .io = opts.io, .drives = drives, .mixed = opts.mixed != null };
    const m = if (opts.mixed) |mx| for (file.modules) |*c| {
        if (file.strings.eql(c.name, mx.top)) break c;
    } else return r.fail(0, "the mixed-signal root module is not in the source", .{}) else blk: {
        if (file.modules.len == 0 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires ordinary modules and no analog declarations", .{});
        break :blk try pickTop(&r, file.modules);
    };
    // §6.2.2: a `timescale applies from where it is written, and the FIRST
    // description in the file is what "before any module" means once there is
    // more than one — the root is not necessarily the first one declared.
    // A mixed design's text opens with the annex D/E prelude, so its root is
    // the module that has to come after the directive.
    const first_tok = if (opts.mixed != null) m.main_tok else file.modules[0].main_tok;
    var unit: Time.Quantum = default_quantum;
    var precision: Time.Quantum = default_quantum;
    for (times) |event| {
        if (event.at > r.starts[first_tok]) return r.fail(m.main_tok, "timescale/resetall after module start is not implemented for digital execution", .{});
        // A null value is IEEE 1364 §19.6's `resetall, which returns
        // `timescale to "none specified" — §19.8's simulator-specific
        // default below. A MALFORMED directive never reaches here: the
        // preprocessor refuses it where it is written (E0142).
        const t = event.value orelse {
            unit = default_quantum;
            precision = default_quantum;
            continue;
        };
        unit = Time.Quantum.fromSeconds(t.unit) catch return r.fail(m.main_tok, "unsupported time unit", .{});
        precision = Time.Quantum.fromSeconds(t.precision) catch return r.fail(m.main_tok, "unsupported time precision", .{});
    }
    r.scale = Time.Scale.init(unit, precision, precision) catch return r.fail(m.main_tok, "invalid timescale", .{});
    r.unit_exp = @intFromEnum(unit);
    // §17.3: "the default ... is the smallest time precision argument of
    // all the `timescale compiler directives in the source description".
    // One timescale applies to the whole design here, so that is its precision.
    r.time_format.units = @intFromEnum(precision);
    r.finest = r.time_format.units;
    // PASS ONE — storage. Variables, array elements and nets share one slot
    // space, so one `store` publishes all three and wakes the same event
    // waiters. §6.2.2 elaboration walks the instance tree parent-first, which
    // is what lets a port connection resolve against nets that already exist.
    var e: Elab = .{};
    try r.scope_info.append(arena, .{ .parent = 0, .name = m.name, .module = m.name });
    // Allocated before pass one: a bound or a parameter is typed and folded
    // while the slot space is still growing (`Run.constant`).
    r.types = try arena.alloc(Type, file.exprs.nodes.len);
    @memset(r.types, .{ .width = 0, .signed = false });
    r.sys_calls = try arena.alloc(?compile.SysFn, file.exprs.nodes.len);
    @memset(r.sys_calls, null);
    r.growing = &e.values;
    try declare(&r, &e, m, 0, &.{}, 0);
    r.values = e.values.items;
    r.nets = e.nets.items;
    // PASS TWO — drivers, then processes. §6.1 one continuous assignment is one
    // driver of one net; §7.9 resolution needs them grouped, because every
    // update reads all of a net's drivers.
    //
    // Drivers compile FIRST so that no driver's pc can also be a process's
    // resumption point: a `wait_event` resumes at its own pc plus one, and
    // every instruction from here on belongs to a process.
    if (e.wires.items.len > std.math.maxInt(u32)) return r.fail(m.main_tok, "too many continuous assignments", .{});
    r.drivers = try arena.alloc(Driver, e.wires.items.len);
    const grouped = try arena.alloc(std.ArrayList(u32), e.nets.items.len);
    @memset(grouped, .empty);
    for (e.wires.items, 0..) |a, i| {
        r.scope = a.scope;
        var watched: std.ArrayList(u32) = .empty;
        if (a.bridge) |b| {
            try watched.append(arena, b.src);
        } else if (a.gate) |g| {
            // §7.8.5 a gate re-evaluates on any input change, exactly as a
            // continuous assignment does on any operand change.
            for (g.ins) |in| {
                try compile.checkExpr(&r, in);
                const w = compile.typeOf(&r, in).width;
                if (w != 1 and !(g.lane != null and w == g.lanes)) return r.exprFail(in, "a gate's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            }
        } else if (a.mos) |mo| {
            for ([_]Ast.ExprId{ mo.data, mo.gate }) |in| {
                try compile.checkExpr(&r, in);
                if (compile.typeOf(&r, in).width != 1) return r.exprFail(in, "only scalar switch terminals are implemented");
                try compile.sensitivity(&r, in, &watched);
            }
        } else if (a.udp) |u| {
            for (u.ins) |in| {
                try compile.checkExpr(&r, in);
                if (compile.typeOf(&r, in).width != 1) return r.exprFail(in, "only scalar UDP terminals are implemented");
                try compile.sensitivity(&r, in, &watched);
            }
        } else if (a.pull == null) {
            try compile.checkExpr(&r, a.value);
            try compile.sensitivity(&r, a.value, &watched);
        }
        r.drivers[i] = .{
            .net = a.net,
            .value = a.value,
            .scope = a.scope,
            .bridge = a.bridge,
            .gate = a.gate,
            .udp = a.udp,
            .pull = a.pull,
            .slice = a.slice,
            .mos = a.mos,
            .sensitivity = watched.items,
            // A sequential UDP's output is its state from the start (§8.5).
            .current = try filled(arena, r.nets[a.net].resolved.width, false, if (a.udp) |u| (if (u.sequential) u.state else .z) else .z),
            .s0 = a.s0,
            .s1 = a.s1,
            .delay = try r.declaredDelay3(a.delay, a.tok),
        };
        try grouped[a.net].append(arena, @intCast(i));
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .continuous = @intCast(i) }) }, null, false);
    }
    // §7.6: each net knows the pass switches on it, and a controlled one is
    // a process that re-resolves both sides whenever its control changes.
    r.trans = try arena.alloc(Tran, e.trans.items.len);
    const on_net = try arena.alloc(std.ArrayList(u32), e.nets.items.len);
    @memset(on_net, .empty);
    for (e.trans.items, r.trans, 0..) |t, *dst, i| {
        dst.* = t.tran;
        try on_net[t.tran.a].append(arena, @intCast(i));
        try on_net[t.tran.b].append(arena, @intCast(i));
        if (t.tran.ctrl == .none) continue;
        r.scope = t.scope;
        try compile.checkExpr(&r, t.tran.ctrl);
        var watched: std.ArrayList(u32) = .empty;
        try compile.sensitivity(&r, t.tran.ctrl, &watched);
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .switch_ctrl = .{ .tran = @intCast(i), .slots = watched.items } }) }, null, false);
    }
    for (r.nets, on_net) |*n, t| n.trans = t.items;
    for (r.nets, grouped) |*n, g| {
        // §7.9 `uwire` is the UNRESOLVED net type: a second driver is not a
        // resolution question there, it is an error.
        if (n.kind == .uwire and g.items.len > 1) return r.fail(n.tok, "a uwire net accepts a single driver", .{});
        n.drivers = g.items;
    }
    // §10 subroutine bodies, each on its own pc range before any process, so
    // a synchronous call never runs into a process's code.
    try compile.compileSubs(&r);
    for (e.insts.items) |inst| {
        r.scope = inst.scope;
        // IEEE 1364-2005 §6.2.1: a variable declaration assignment "shall be
        // the same as" an initial block making the assignment, so it is one,
        // queued ahead of the instance's own processes. A mixed module's
        // initialized variables are the analog block's and were skipped.
        for (inst.module.vars) |v| if (v.init != .none) {
            const at = r.names.get(.{ .scope = inst.scope, .str = v.name }) orelse continue;
            try compile.checkExpr(&r, v.init);
            const start = try compile.append(&r, .{ .init_var = .{ .slot = at, .value = v.init } });
            _ = try compile.append(&r, .stop);
            _ = try exec.enqueue(&r, .{ .run_process = start }, null, false);
        };
        for (inst.module.discrete) |process| {
            const start: u32 = @intCast(r.code.items.len);
            try compile.compileStmt(&r, process.body, 0);
            _ = try compile.append(&r, if (process.is_always)
                .{ .restart = .{ .target = start, .tok = process.main_tok } }
            else
                .stop);
            _ = try exec.enqueue(&r, .{ .run_process = start }, null, false);
        }
    }
    // A.6.5's `disable` names a block that needs no declaration before its use
    // — d04_14's is in the process next door — so the ranges are bound here,
    // once every process has a pc range at all.
    // A block is looked for through the enclosing scopes (§12.7); a name
    // that is no block may be a task (§10.3), which has no single range.
    disabling: for (r.disables.items) |d| {
        var s = d.name.scope;
        while (true) {
            if (r.blocks.get(.{ .scope = s, .str = d.name.str })) |range| {
                r.code.items[d.at] = .{ .disable_block = .{ .start = range.start, .end = range.end } };
                continue :disabling;
            }
            if (!r.scope_info.items[s].lexical) break;
            s = r.scope_info.items[s].parent;
        }
        const idx = r.sub_by_name.get(.{ .scope = r.instanceOf(d.name.scope), .str = d.name.str }) orelse
            return r.fail(d.tok, "undeclared named block or task", .{});
        r.code.items[d.at] = .{ .disable_task = idx };
    }
    // Pass two may have minted storage (an automatic task inlined at a call
    // site), so the slot space is final only now.
    r.growing = null;
    r.values = e.values.items;
    r.watch = try arena.alloc(std.EnumSet(Watcher), r.values.len);
    @memset(r.watch, .initEmpty());
    return r;
}

// ---- tests ------------------------------------------------------------------

test {
    _ = @import("system.zig");
    _ = @import("vcd.zig");
}

pub fn expectRun(source: []const u8, expected: []const u8) !void {
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

test "elaborate + runUntil step the engine one bounded horizon at a time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] code;
        \\initial begin code = 4'd1; #10 code = 4'd5; #10 code = 4'd9; end
        \\endmodule
    , .{}, &bag, &output.writer);
    const at = r.slotOf("code").?;
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("nope"));
    // Nothing has run: the reg is still §3.2's x.
    try std.testing.expect(r.values[at].hasUnknown());
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 1), r.values[at].asInt());
    try std.testing.expectEqual(@as(?Tick, 10), r.scheduler.peekTime());
    _ = try r.runUntil(9);
    try std.testing.expectEqual(@as(?i64, 1), r.values[at].asInt());
    _ = try r.runUntil(10);
    try std.testing.expectEqual(@as(?i64, 5), r.values[at].asInt());
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(@as(?i64, 9), r.values[at].asInt());
    try std.testing.expectEqual(@as(?Tick, null), r.scheduler.peekTime());
}

test "IEEE 1364 §5.2.1 a bit-select names its bit against the declared range" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] a; reg [0:3] b; wire [3:0] w; wire hi;
        \\integer i;
        \\assign w = a;
        \\assign hi = w[3];
        \\initial begin
        \\  a = 4'b1010; b = 4'b1000; i = 1;
        \\  #0 $display("%b%b %b %b%b %b %b", a[1], a[0], hi, b[0], b[3], a[i], a[4]);
        \\end
        \\endmodule
    , "10 1 10 1 x\n");
}

test "VAMS §7.2.2 the digital half of a mixed-signal module elaborates beside its analog half" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    // Already preprocessed text, as an analog compile hands it over: the
    // timescale arrives in `Mixed`, not as a directive.
    var r = try elaborate(arena.allocator(),
        \\discipline electrical potential Voltage; flow Current; enddiscipline
        \\module helper(a); inout a; electrical a; analog V(a) <+ 0; endmodule
        \\module dac(out);
        \\  inout out; electrical out; electrical inner;
        \\  parameter real gain = 2.0;
        \\  reg [3:0] code; real x;
        \\  initial begin code = 4'd3; #5 code = 4'd7; end
        \\  analog begin x = gain * code; V(out) <+ x; end
        \\endmodule
    , .{ .mixed = .{ .top = "dac", .timescale = .{ .unit = 1e-9, .precision = 1e-9 } } }, &bag, &output.writer);
    const at = r.slotOf("code").?;
    // The continuous half is not the digital engine's to hold.
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("x"));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("out"));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("inner"));
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 3), r.values[at].asInt());
    _ = try r.runUntil(5);
    try std.testing.expectEqual(@as(?i64, 7), r.values[at].asInt());
}

test "§12.4 a downward hierarchical reference reads the named instance's net" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module child(a, y);
        \\input a;
        \\output y;
        \\wire a, y;
        \\assign y = ~a;
        \\endmodule
        \\module top;
        \\reg r;
        \\wire w;
        \\child u(r, w);
        \\initial begin r = 1'b0; #0 $display("a=%b y=%b", u.a, u.y); end
        \\endmodule
    , "a=0 y=1\n");
}

test "§12.4 a hierarchical path descends one instance per part" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module leaf(a);
        \\input a;
        \\wire a;
        \\endmodule
        \\module mid(a);
        \\input a;
        \\wire a;
        \\leaf d(a);
        \\endmodule
        \\module top;
        \\reg r;
        \\mid u(r);
        \\initial begin r = 1'b1; #0 $display("%b", u.d.a); end
        \\endmodule
    , "1\n");
}

// IEEE 1364 §19.10. The directive drives at PULL strength, so the level it
// asks for is not automatically the level the net shows — `strong0` outranks
// it and wins, which is the half no "pull is just a value" model reproduces.
test "§19.10 unconnected_drive pulls an open input port and loses to a stronger driver" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\`unconnected_drive pull1
        \\module child(a, b);
        \\input a;
        \\input b;
        \\wire a, b;
        \\endmodule
        \\`nounconnected_drive
        \\module top;
        \\wire s;
        \\assign (strong0, strong1) s = 1'b0;
        \\child u( , s);
        \\initial #0 $display("open=%b driven=%b", u.a, u.b);
        \\endmodule
    , "open=1 driven=0\n");
}

test "§19.10 nounconnected_drive leaves an open input port floating" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module child(a);
        \\input a;
        \\wire a;
        \\endmodule
        \\module top;
        \\child u( );
        \\initial #0 $display("%b", u.a);
        \\endmodule
    , "z\n");
}

// §10: an untimed task runs in place, a timed one suspends its caller; a
// static task's storage outlives its activation and an automatic one's does
// not; recursion gets a frame per activation; `disable` of a task ends every
// activation, and the caller resumes after its enable.
test "§10 tasks and functions: copy in/out, lifetimes, recursion, disable" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [7:0] a, b, c; integer n, tails;
        \\function automatic integer fib(input integer k);
        \\  fib = k < 2 ? k : fib(k - 1) + fib(k - 2);
        \\endfunction
        \\function [3:0] low(input [7:0] x); low = x; endfunction
        \\task count(input clr, output [7:0] o); reg [7:0] kept; begin if (clr) kept = 0; kept = kept + 1; o = kept; end endtask
        \\task late(input [7:0] i, output [7:0] o); #2 o = i + 1; endtask
        \\task automatic dive(input integer d); begin if (d == 0) disable dive; else dive(d - 1); tails = tails + 1; end endtask
        \\initial begin
        \\  n = fib(10); a = low(8'hab) + 8'h10;
        \\  count(1'b1, b); count(1'b0, b);
        \\  tails = 0; dive(3);
        \\  late(a, c);
        \\  $display("%0d %h %0d %h %0d %0d", n, a, b, c, tails, $time);
        \\end
        \\endmodule
    , "55 1b 2 1c 0 2\n");
}

// §10.2.3: each activation of an automatic task that suspends and reaches
// itself has its own storage, even while another caller's activations are
// alive; and an actual that is the callee's own formal is read before the
// new activation's frame is initialized.
test "§10.2.3 recursive timed automatic tasks and a formal passed to itself" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer ra, rb;
        \\task automatic sum(input integer n, input integer d, output integer t);
        \\  integer b; begin if (n == 0) t = 0; else begin #d sum(n - 1, d, b); t = b + n; end end
        \\endtask
        \\function automatic integer f(input integer n, input integer k); f = k == 0 ? n : f(n, k - 1); endfunction
        \\initial begin sum(2, 2, ra); $display("%0d ra=%0d", $time, ra); end
        \\initial begin sum(3, 3, rb); $display("%0d rb=%0d f=%0d", $time, rb, f(7, 3)); end
        \\endmodule
    , "4 ra=3\n9 rb=6 f=7\n");
}

// §6.2.1: the initializer is an initial-block assignment at time 0 — so a
// net assigned from the variable tracks it, and a later write replaces it.
test "§6.2.1 a variable declaration assignment is a time-0 write" {
    try expectRun(
        \\module m;
        \\reg [7:0] v = 2*3+1; integer i = -5; time t = 64'd9;
        \\wire [7:0] w = v;
        \\initial begin #1 $display("%0d %0d %0d %0d", v, w, i, t); v = 12; #1 $display("%0d", w); end
        \\endmodule
    , "7 7 -5 9\n12\n");
}

// §12.2: a parameter is a constant of its value's type unless a range or a
// type converts it, a later default may use an earlier parameter, and every
// bound and delay is a constant expression over them.
test "§12.2 parameters fold into bounds, delays and expressions" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m #(parameter W = 4) ();
        \\localparam [2:0] SEVEN = 15, D = W / 2;
        \\parameter integer N = -W;
        \\reg [W-1:0] r; reg [-2:1] neg; wire #D late;
        \\reg s; assign late = s;
        \\initial begin
        \\  r = 5'h1f; neg = 17; s = 1;
        \\  #1 $display("%b %0d %0d %b %b %b", r, SEVEN, N, neg, late, W == 4);
        \\  #2 $display("%b", late);
        \\end
        \\endmodule
    , "1111 7 -4 0001 z 1\n1\n");
}

// §12.4.2: only the selected arm's instance exists, and §12.1.1 keeps the
// module of the unselected one from becoming a second top.
test "§12.4.2 a conditional generate instantiates only its selected arm" {
    try expectRun(
        \\module a; initial $display("a"); endmodule
        \\module b; initial $display("b"); endmodule
        \\module m #(parameter P = 1) ();
        \\generate if (P == 0) begin : g0 a u(); end else if (P == 1) begin : g1 b u(); end endgenerate
        \\endmodule
    , "b\n");
}

// §12.4.1: one block per genvar value, each a scope `g[i]` holding i as a
// local parameter; §12.4.2: only the matching case arm exists.
test "§12.4.1/§12.4.2 a loop generate unrolls and a case generate selects" {
    try expectRun(
        \\module c(input [3:0] v); initial #1 $display("%m %0d", v); endmodule
        \\module d; initial #2 $display("d"); endmodule
        \\module m;
        \\genvar i;
        \\for (i = 3; i > 0; i = i - 2) begin : g c u(i + 1); end
        \\generate case (2'b1x) 2'b10: begin : e c u(0); end 2'b1x: begin : f d u(); end endcase endgenerate
        \\endmodule
    , "m.g[3].u 4\nm.g[1].u 2\nd\n");
    try expectRejected("module c; endmodule\nmodule m; genvar i; for (i = 0; i < 2; i = i) begin : g c u(); end endmodule", "genvar value is repeated");
}

// §12.3.2/§12.3.6: a named header port whose expression concatenates internal
// ports takes one connection, split leftmost-most-significant; a header port
// renamed `.ext(int)` is connected by the external name.
test "§12.3.6 an external port name, alone or over a concatenation" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module c(.in({a, b}), .o(y)); input [1:0] a; input b; output y; assign y = a[1] ^ b; endmodule
        \\module m; wire q; c u(.in(3'b101), .o(q)); initial #1 $display("%b %b%b", q, u.a, u.b); endmodule
    , "0 101\n");
}

// §12.3.11: each side of a port reads the connected bits with ITS OWN
// declaration's signedness — the child's `signed` port sees -1 in a parent's
// unsigned 8'hff, and an unsigned port sees 255 in a signed parent net.
test "§12.3.11 the sign attribute does not cross a port, and a signed net is signed" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module sc(input signed [7:0] v, output n); assign n = v < 0; endmodule
        \\module uc(v, n); input [7:0] v; output n; assign n = v < 0; endmodule
        \\module m;
        \\wire [7:0] pu = 8'hff;
        \\wire signed [7:0] ps = 8'hff;
        \\wire a, b;
        \\sc x(pu, a);
        \\uc y(ps, b);
        \\initial #1 $display("%b%b %0d %0d", a, b, ps, pu);
        \\endmodule
    , "10 -1 255\n");
}

// §7.8: a pull source drives at pull strength unless its OWN side's strength
// is written, and the other side's is ignored — so `(weak0, strong1)` is a
// strong pullup that beats a pulldown, and `(strong0, weak1)` a weak one.
test "§7.8 pullup and pulldown are drivers at the strength of their own side" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\wire a, b, c, d;
        \\pullup (weak0, strong1) pa(a);
        \\pullup (strong0, weak1) pb(b);
        \\pulldown da(a), db(b);
        \\pullup (c);
        \\reg r;
        \\assign (weak0, weak1) d = r;
        \\pullup (d);
        \\initial begin r = 0; #1 $display("%b%b%b%b", a, b, c, d); end
        \\endmodule
    , "1011\n");
}

pub fn expectRejected(source: []const u8, message: []const u8) !void {
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

test "a legal wreal runs, and hears none of the structural wreal codes" {
    // §3.7's compatible list is wire, tri and wreal, and one driver is legal.
    const legal = [_][]const u8{
        "module m; real a; wreal w; assign w = a; endmodule",
        "module c(o); output o; wreal o; endmodule\nmodule m; wire n; c u(.o(n)); endmodule",
        "module c(o); output o; wreal o; endmodule\nmodule m; tri n; c u(n); endmodule",
        "module c(o); output o; wreal o; endmodule\nmodule m; wreal n; c u(n); endmodule",
    };
    for (legal) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bag = diag.Bag.init(arena.allocator());
        var output = std.Io.Writer.Allocating.init(arena.allocator());
        try run(arena.allocator(), source, .{}, &bag, &output.writer);
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.indexOf(u8, messages.written(), "E0918") == null);
        try std.testing.expect(std.mem.indexOf(u8, messages.written(), "E0919") == null);
    }
}

test "the net and array declaration boundaries are explicit" {
    // §6.1/§6.2.2: neither form of assignment accepts the other's target.
    try expectRejected("module m; wire w; initial w = 1; endmodule", "no procedural assignment to a net");
    try expectRejected("module m; reg r; initial $display(\"before\"); assign r = 1; endmodule", "can only drive a net");
    try expectRejected("module m; wire w; reg a; assign w[0] = a; endmodule", "whole-variable");
    // §7.9 uwire resolves nothing, so a second driver is an error.
    try expectRejected("module m; uwire u; reg a,b; assign u = a; assign u = b; endmodule", "uwire net accepts a single driver");
    // §6.5.3 a wreal has at most one driver, and §3.7 closes the list of net
    // types a port may join it to.
    try expectRejected("module m; real a,b; wreal w; assign w = a; assign w = b; endmodule", "E0918");
    try expectRejected("module m; real a; wreal w = a; assign w = a; endmodule", "E0918");
    try expectRejected("module c(o); output o; wreal o; endmodule\nmodule m; wand n; c u(.o(n)); endmodule", "E0919");
    try expectRejected("module c(o); output o; wand o; endmodule\nmodule m; wreal n; c u(n); endmodule", "E0919");
    // A.2.2.2: every alternative pairs ONE 0-side spec with ONE 1-side spec,
    // and `charge_strength` is a different production that A.2.1.3 grants only
    // to `trireg`. A parser that read "any parenthesised strength after any net
    // type" would accept both of these.
    try expectRejected("module m; wire w; reg a; assign (strong0, pull0) w = a; endmodule", "pairs one 0-side with one 1-side");
    try expectRejected("module m; wire (small) w; reg a; assign w = a; endmodule", "charge strength is only legal on a trireg");
    // A.2.2.3's `delay_value` admits an `identifier`, which must name a
    // parameter; this one names nothing.
    try expectRejected("`timescale 1ns/1ns\nmodule m; wire #w y; reg a; assign y = a; endmodule", "undeclared digital variable");
    // §3.9 an array has no value of its own, and a select is not an element.
    try expectRejected("module m; reg [3:0] mem [0:3]; initial $display(\"%b\",mem); endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] mem [0:1]; reg a; initial @(mem) a = 1; endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] a; integer i; initial $display(\"%b\",a[i:0]); endmodule", "constant expression is required");
    try expectRejected("module m; reg [3:0] mem [0:1][0:1]; initial $display(\"%b\", mem[0]); endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] mem [0:1]; initial mem[65'h1] = 0; endmodule", "indices wider than 64 bits");
    // §3.6 a disciplined net belongs to the analog solver, not to this executor.
    // A net's `=` no longer joins them: A.2.4's `net_decl_assignment` is a
    // continuous assignment on an UNdisciplined net, and it runs.
    try expectRejected("module m; electrical e; initial $display(\"x\"); endmodule", "disciplined and ground");
    try expectRejected("module m; wire [p:0] w; initial $display(\"x\"); endmodule", "undeclared digital variable");
    try expectRejected("module m; reg [3:0] a; wire [a:0] w; initial $display(\"x\"); endmodule", "constant expression is required");
    try expectRejected("module m; parameter P = 1; initial P = 2; endmodule", "parameter is a constant");
}

test "§19.8 no timescale is the simulator's own unit, not an error" {
    // "If there is no `timescale specified or it has been reset by a
    // `resetall directive, the time unit and precision are simulator-specific."
    try expectRun("module m; wire w; reg a; assign #3 w = a; initial begin a = 1; #2 $display(\"%b %0d\", w, $time); #1 $display(\"%b %t\", w, $time); end endmodule",
        "z 2\n1                    3\n");
    try expectRun("`timescale 1ns/1ps\n`resetall\nmodule m; initial #1 $display(\"%0d %g\", $time, $realtime); endmodule", "1 1\n");
}

test "timescale provenance rejects malformed or later directives" {
    // All three are refused by the preprocessor now (E0142), so what the digital
    // executor sees is a failed preprocess and the message names the directive
    // rather than the consumer that could not use it.
    try expectRejected("`timescale 2ns/1ps\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ns/1ps junk\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ps/1ns\nmodule m; initial #1 ; endmodule", "coarser than the time unit");
    try expectRejected("`timescale 1ns/1ps\nmodule m; initial #1 ; endmodule\n`timescale 1ms/1us\n", "after module start");
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #(128'd1) ; endmodule", "wider than 64");
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
