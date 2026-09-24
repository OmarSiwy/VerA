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
const Time = @import("../time.zig");
const compile = @import("compile.zig");
const exec = @import("exec.zig");
const display = @import("display.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Waiter = exec.Waiter;
const Delay = @import("net.zig").Delay;
const Bridge = @import("net.zig").Bridge;
const Net = @import("net.zig").Net;
const Gate = @import("net.zig").Gate;
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
};

// ---- engine state and name resolution (§6.2.2, §12.4, §3.9) -----------------

/// One declared identifier, qualified by the §6.2.2 instance that declared it.
const Name = struct { scope: u32, str: Ast.StrId };

// §3.9 an unpacked array is `count` consecutive element slots; the declared
// name maps to the first. `low`/`high` are the declared address bounds, in
// either order of declaration — no operation here observes element ORDER, only
// which address names which element.
const Array = struct { count: u32, low: i64, high: i64 };

pub const Watcher = enum { monitor };

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
    blocks: std.AutoHashMapUnmanaged(Name, struct { start: u32, end: u32 }) = .empty,
    /// The `.disable_block` instructions still waiting for their range, and the
    /// name each one is waiting for. A.6.5 puts no ordering rule on a
    /// `disable`: the block it names is routinely in ANOTHER process, which may
    /// not be compiled yet, so the lookup is deferred to one pass at the end
    /// rather than failing in the middle of a dispatch.
    disables: std.ArrayList(struct { at: u32, name: Name, tok: u32 }) = .empty,
    // One counter per lexical repeat is sufficient without recursive processes.
    repeats: std.ArrayList(u64) = .empty,
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
    /// §17.1.3 the one standing monitor. A second `$monitor` replaces it;
    /// there is no stack.
    monitor: ?struct { args: []const Ast.ExprId, show: Show, scope: u32 } = null,
    monitor_on: bool = true,
    /// One `.monitor` event per timestep however many values moved.
    monitor_pending: bool = false,
    /// The slots the standing monitor's arguments read — §17.1.3's "variable
    /// or an expression in the argument list". Clock queries read no slot,
    /// which is the clause's `$time`/`$stime`/`$realtime` exception.
    monitor_slots: std.ArrayList(u32) = .empty,
    /// Per slot, who is told when its value changes. `store` tests this on
    /// every change and nothing else: it is the one value-change hook, whose
    /// first watcher is §17.1.3's monitor. §18's VCD value changes and VAMS
    /// §8.5's implicit D2A are the same event and would each add a member.
    watch: []std.EnumSet(Watcher) = &.{},

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
            var scope = self.scope;
            for (parts[0 .. parts.len - 1]) |part|
                scope = self.instances.get(.{ .scope = scope, .str = part }) orelse
                    return self.exprFail(e, "undeclared instance in a hierarchical reference");
            return self.names.get(.{ .scope = scope, .str = parts[parts.len - 1] }) orelse
                self.exprFail(e, "undeclared digital variable");
        }
        if (ex.tag(e) != .ident) return self.exprFail(e, "only whole-variable lvalues are implemented");
        return self.names.get(.{ .scope = self.scope, .str = ex.strOf(e) }) orelse self.exprFail(e, "undeclared digital variable");
    }
    /// One declared bound. Digital execution takes literal bounds only: the
    /// parameters and constant functions §3.9 also admits are not declared yet.
    fn declaredBound(self: *Run, e: Ast.ExprId, tok: u32) Error!i64 {
        if (self.file.exprs.tag(e) != .int_literal) return self.fail(tok, "declaration bounds must be literal integers", .{});
        return self.file.exprs.intValue(e);
    }
    /// A.2.2.3 `delay_value ::= unsigned_number | real_number | identifier`, in
    /// scheduler ticks. Elaboration-time, because a net's or a driver's delay is
    /// fixed for the run — only a procedural `#` re-evaluates.
    ///
    /// ponytail: the `identifier` alternative is refused. It would name a
    /// `parameter`, and digital execution has no parameters at all yet; the
    /// upgrade is one call to the constant folder once it does.
    fn declaredDelay(self: *Run, e: Ast.ExprId, tok: u32) Error!u64 {
        const scale = self.scale orelse return self.fail(tok, "a delay needs an explicit valid timescale", .{});
        return switch (self.file.exprs.tag(e)) {
            .real_literal => scale.realDelay(self.file.exprs.realValue(e)),
            .int_literal => scale.signedDelay(self.file.exprs.intValue(e)),
            else => self.fail(tok, "a declared delay must be a literal number", .{}),
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
        if (hi < 0 or lo < 0 or @abs(hi - lo) >= std.math.maxInt(u32)) return self.fail(tok, "packed range is outside the supported u32 width", .{});
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
        return if (ex.tag(e) == .index) self.slot(ex.lhs(e)) else self.scalarSlot(e);
    }
    pub fn scalarSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const at = try self.slot(e);
        if (self.arrays.contains(at)) return self.exprFail(e, "an unpacked array reference requires an element index");
        return at;
    }
    /// The array an `.index` selects from, or null when this is not an element
    /// reference (a bit or part select, which is not implemented).
    pub fn indexedArray(self: *Run, e: Ast.ExprId) Error!?Array {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .index or ex.tag(ex.lhs(e)) != .ident) return null;
        return self.arrays.get(try self.slot(ex.lhs(e)));
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
    /// Set instead of `value` for IEEE 1364 §19.10's pull — see `Driver.pull`.
    pull: ?Int.Bit = null,
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
    receive: struct { expr: Ast.ExprId, scope: u32, tok: u32 },
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
};

/// §6.2.2: the root of the design is the description nothing instantiates.
fn pickTop(r: *Run, modules: []const Ast.ModuleDecl) Error!*const Ast.ModuleDecl {
    var top: ?*const Ast.ModuleDecl = null;
    outer: for (modules) |*candidate| {
        if (candidate.is_connect) continue;
        for (modules) |other| for (other.instances) |inst| {
            if (inst.module == candidate.name) continue :outer;
        };
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
    if (m.params.len != 0 or m.aliasparams.len != 0 or m.branches.len != 0 or m.defparams.len != 0 or m.genvars.len != 0 or m.functions.len != 0 or m.analog.len != 0 or m.attrs.len != 0)
        return r.fail(m.main_tok, "digital execution currently requires a module with only variables, nets, events, instances and processes", .{});
    r.scope = scope;
    try e.insts.append(arena, .{ .module = m, .scope = scope });
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
        if (v.ty != .integer or v.init != .none or v.storage == .time) return r.fail(v.main_tok, "only uninitialized scalar/packed reg and integer declarations are implemented", .{});
        // ponytail: one unpacked dimension. §3.9 admits any number; the second
        // one needs a row-major address fold this has no consumer for yet.
        if (v.dims.len > 1) return r.fail(v.main_tok, "only one unpacked array dimension is implemented", .{});
        const width: u32 = if (v.packed_range) |range| try r.declaredWidth(range, v.main_tok) else if (v.storage == .reg) 1 else 32;
        const base: u32 = @intCast(e.values.items.len);
        try r.bind(v.name, base, v.main_tok);
        var count: u32 = 1;
        if (v.dims.len == 1) {
            const lo = try r.declaredBound(v.dims[0].lsb, v.main_tok);
            const hi = try r.declaredBound(v.dims[0].msb, v.main_tok);
            const low = @min(lo, hi);
            const high = @max(lo, hi);
            if (high - low >= std.math.maxInt(u32)) return r.fail(v.main_tok, "unpacked array size is outside the supported u32 range", .{});
            count = @intCast(high - low + 1);
            try r.arrays.put(arena, base, .{ .count = count, .low = low, .high = high });
        }
        if (count > std.math.maxInt(u32) - e.values.items.len) return r.fail(v.main_tok, "too many digital storage slots", .{});
        for (0..count) |_| try e.values.append(arena, try filled(arena, width, if (v.storage == .reg) v.is_signed else true, .x));
    }
    for (m.nets) |n| {
        if (n.discipline != .none or n.is_ground)
            return r.fail(n.main_tok, "disciplined and ground nets are not implemented by digital execution", .{});
        const width = if (n.range) |range| try r.declaredWidth(range, n.main_tok) else 1;
        const at = try mintNet(r, e, n.kind, width, n.name, n.main_tok);
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
        const bind = if (i < binds.len) binds[i] else PortBind.open;
        const width = if (p.range orelse p.type_range) |range| try r.declaredWidth(range, p.main_tok) else 1;
        if (bind == .collapse) {
            const outer = e.nets.items[bind.collapse];
            if (outer.resolved.width != width)
                return r.fail(p.main_tok, "§6.5.7.1: the sizes of the port and the net connected to it shall match", .{});
            try r.bind(p.name, outer.slot, p.main_tok);
            continue;
        }
        // `p.kind`, NOT `.wire`. A body declaration naming a header port is
        // folded into the `Port` by the parser, so `inout t; tri0 t;` arrives
        // here as one `Port` — and until `Ast.Port` carried a net type that
        // fold DROPPED it, minting every port net `.wire`. The visible effect
        // was that an internal `tri0` read 0 while the identical declaration
        // on a port read z: §7.9's resolution and `netPull`'s undriven value
        // are both functions of the net type, and the port's was a lie.
        const at = try mintNet(r, e, p.kind, width, p.name, p.main_tok);
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
            .receive => |c| try e.wires.append(arena, .{ .net = at, .scope = c.scope, .value = c.expr, .tok = c.tok }),
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
        // §7.8.5's tables are one bit wide. A vector terminal would be A.3.1's
        // `net_lvalue`, whose per-bit expansion nothing here asks for.
        if (e.nets.items[net].resolved.width != 1) return r.fail(g.main_tok, "only scalar gate terminals are implemented", .{});
        try e.wires.append(arena, .{
            .net = net,
            .scope = scope,
            .gate = .{ .kind = g.kind, .ins = g.ins },
            .s0 = g.strength0,
            .s1 = g.strength1,
            .delay = g.delay,
            .tok = g.main_tok,
        });
    }
    for (m.instances) |inst| {
        if (inst.range != null or inst.params.len != 0)
            return r.fail(inst.main_tok, "instance arrays and parameter overrides are not implemented by digital execution", .{});
        const child = try findModule(r, inst.module, inst.main_tok);
        const binds_out = try arena.alloc(PortBind, child.ports.len);
        @memset(binds_out, .open);
        for (inst.ports, 0..) |conn, i| {
            const at = if (conn.name == .none) i else blk: {
                for (child.ports, 0..) |p, k| if (p.name == conn.name) break :blk k;
                return r.fail(conn.main_tok, "the instantiated module has no such port", .{});
            };
            if (at >= child.ports.len) return r.fail(conn.main_tok, "more port connections than the module has ports", .{});
            r.scope = scope;
            binds_out[at] = try bindPort(r, child.ports[at], conn, scope);
        }
        const child_scope = try newScope(r, inst.main_tok);
        // §12.4's path is walked by NAME, so the instance's own identifier has
        // to outlive the recursion that consumes it.
        if (inst.name != .none) try r.instances.put(arena, .{ .scope = scope, .str = inst.name }, child_scope);
        try declare(r, e, child, child_scope, binds_out, depth + 1);
        r.scope = scope;
    }
}

fn newScope(r: *Run, tok: u32) Error!u32 {
    r.scopes += 1;
    if (r.scopes == std.math.maxInt(u32)) return r.fail(tok, "too many digital instances", .{});
    return r.scopes;
}

/// Allocate one net and its slot, and bind `name` to it in the current scope.
fn mintNet(r: *Run, e: *Elab, kind: Ast.NetKind, width: u32, name: Ast.StrId, tok: u32) Error!u32 {
    if (e.values.items.len == std.math.maxInt(u32)) return r.fail(tok, "too many digital storage slots", .{});
    const slot: u32 = @intCast(e.values.items.len);
    const at: u32 = @intCast(e.nets.items.len);
    try r.bind(name, slot, tok);
    // §3.7: a net with no driver is Z, not X — except where the net type itself
    // supplies a value. That is the whole net/variable difference.
    try e.values.append(r.arena, try filled(r.arena, width, false, undriven(kind)));
    try e.nets.append(r.arena, .{ .kind = kind, .slot = slot, .resolved = try filled(r.arena, width, false, .z), .tok = tok });
    try r.net_of.put(r.arena, slot, at);
    return at;
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
/// Checked on the parsed file, before the parser's E1100 for `wreal` itself
/// stops the run, so a file that breaks one hears the LRM's reason and not
/// only "not implemented" — and keeps hearing it once `wreal` runs.
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

/// Callers own the run arena and diagnostic source lifetime. No analog lowering,
/// generated-device interpretation, external compiler, or secondary lexer is used.
pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    var times: []const Front.Preprocessor.TimescaleEvent = &.{};
    var drives: []const Front.Preprocessor.DriveRegion = &.{};
    const text = Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .std_defs = false, .timescale_events = &times, .drives = &drives, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    var tokens = try Front.Lexer.Lexer.tokenize(arena, text);
    var parser = Front.Parser.Parser.init(arena, text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    // A failed parse still leaves every recovered module in `parser.file`, and
    // the `wreal` refusal is itself a parse error, so the rules read that.
    const file = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => parser.file,
    };
    try wrealRules(&file, tokens.items(.start), bag);
    if (bag.failed()) return error.DigitalFailed;
    var r: Run = .{ .arena = arena, .file = &file, .starts = tokens.items(.start), .bag = bag, .out = out, .values = &.{}, .scheduler = Scheduler.init(arena), .file_name = opts.file_name, .io = opts.io, .drives = drives };
    if (file.modules.len == 0 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires ordinary modules and no analog declarations", .{});
    const m = try pickTop(&r, file.modules);
    // §6.2.2: a `timescale applies from where it is written, and the FIRST
    // description in the file is what "before any module" means once there is
    // more than one — the root is not necessarily the first one declared.
    const first_tok = file.modules[0].main_tok;
    for (times) |event| {
        if (event.at > r.starts[first_tok]) return r.fail(m.main_tok, "timescale/resetall after module start is not implemented for digital execution", .{});
        // A null scale is now only ever IEEE 1364 §19.6's `resetall, which
        // returns `timescale to "none specified". A MALFORMED directive no
        // longer reaches here at all: the preprocessor refuses it where it is
        // written (E0142), which is a better place to hear about it than a
        // consumer three stages away.
        const t = event.scale orelse return r.fail(m.main_tok, "a resetall timing state is not supported by digital execution", .{});
        const unit = Time.Quantum.fromSeconds(t.unit) catch return r.fail(m.main_tok, "unsupported time unit", .{});
        const precision = Time.Quantum.fromSeconds(t.precision) catch return r.fail(m.main_tok, "unsupported time precision", .{});
        r.scale = Time.Scale.init(unit, precision, precision) catch return r.fail(m.main_tok, "invalid timescale", .{});
        r.unit_exp = @intFromEnum(unit);
        // §17.3: "the default ... is the smallest time precision argument of
        // all the `timescale compiler directives in the source description".
        // One module here, so that is this one's precision.
        r.time_format.units = @intFromEnum(precision);
    }
    // PASS ONE — storage. Variables, array elements and nets share one slot
    // space, so one `store` publishes all three and wakes the same event
    // waiters. §6.2.2 elaboration walks the instance tree parent-first, which
    // is what lets a port connection resolve against nets that already exist.
    var e: Elab = .{};
    try declare(&r, &e, m, 0, &.{}, 0);
    r.values = e.values.items;
    r.watch = try arena.alloc(std.EnumSet(Watcher), r.values.len);
    @memset(r.watch, .initEmpty());
    r.nets = e.nets.items;
    r.types = try arena.alloc(Type, file.exprs.nodes.len);
    @memset(r.types, .{ .width = 0, .signed = false });
    r.sys_calls = try arena.alloc(?compile.SysFn, file.exprs.nodes.len);
    @memset(r.sys_calls, null);
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
                if (compile.typeOf(&r, in).width != 1) return r.exprFail(in, "only scalar gate terminals are implemented");
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
            .pull = a.pull,
            .sensitivity = watched.items,
            .current = try filled(arena, r.nets[a.net].resolved.width, false, .z),
            .s0 = a.s0,
            .s1 = a.s1,
            .delay = try r.declaredDelay3(a.delay, a.tok),
        };
        try grouped[a.net].append(arena, @intCast(i));
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .continuous = @intCast(i) }) }, null, false);
    }
    for (r.nets, grouped) |*n, g| {
        // §7.9 `uwire` is the UNRESOLVED net type: a second driver is not a
        // resolution question there, it is an error.
        if (n.kind == .uwire and g.items.len > 1) return r.fail(n.tok, "a uwire net accepts a single driver", .{});
        n.drivers = g.items;
    }
    for (e.insts.items) |inst| {
        r.scope = inst.scope;
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
    for (r.disables.items) |d| {
        const range = r.blocks.get(d.name) orelse return r.fail(d.tok, "undeclared named block", .{});
        r.code.items[d.at].disable_block = .{ .start = range.start, .end = range.end };
    }
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    while (r.scheduler.next()) |event| {
        _ = scratch.reset(.retain_capacity);
        const item = r.pending.items[event.payload].item;
        switch (item) {
            .run_process => |start| try exec.execute(&r, &scratch, start),
            .write => |w| try exec.store(&r, w.target, w.value.planes),
            .strobe => |s| {
                r.scope = s.scope;
                try display.display(&r, s.args, scratch.allocator(), s.show);
            },
            .monitor_tick => {
                r.monitor_pending = false;
                try display.monitorPrint(&r, scratch.allocator());
            },
            // §6.1.3: a cancelled transition never gets here — the scheduler
            // dropped it — so what arrives is the one still in flight.
            .drive => |at| {
                const d = &r.drivers[at];
                d.transition.in_flight = null;
                @memcpy(d.current.planes, d.transition.target.planes);
                try exec.resolve(&r, d.net);
            },
            .net_update => |at| {
                const n = &r.nets[at];
                n.transition.in_flight = null;
                try exec.store(&r, n.slot, n.transition.target.planes);
            },
            // §3.8: the charge has been held for the decay time, and what a
            // trireg holds once it is worth nothing is x.
            .decay => |at| {
                const n = &r.nets[at];
                n.decay_event = null;
                for (0..n.resolved.width) |i| setBit(n.resolved, @intCast(i), .x);
                try exec.store(&r, n.slot, n.resolved.planes);
            },
        }
        // Freed only now: the `.write` planes above are this row's own, and
        // nothing dispatched may reuse them before `store` has copied them.
        try r.free_rows.append(arena, event.payload);
    }
}

// ---- tests ------------------------------------------------------------------

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

test "a legal wreal hears only the E1100, never the structural wreal codes" {
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
        try std.testing.expectError(error.DigitalFailed, run(arena.allocator(), source, .{}, &bag, &output.writer));
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.indexOf(u8, messages.written(), "E1100") != null);
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
    // types a port may join it to. Both are named even though `wreal` itself
    // is still E1100.
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
    // Both delay3 positions now RUN, so the boundary that remains is the fold,
    // not the syntax: A.2.2.3's `delay_value` admits an `identifier`, and
    // digital execution has no parameter for one to name.
    try expectRejected("`timescale 1ns/1ns\nmodule m; wire #w y; reg a; assign y = a; endmodule", "must be a literal number");
    // A delay has to be measured against something, and §17.3 takes the
    // design's precision from a `timescale and nowhere else.
    try expectRejected("module m; wire w; reg a; assign #3 w = a; endmodule", "explicit valid timescale");
    // §3.9 an array has no value of its own, and a select is not an element.
    try expectRejected("module m; reg [3:0] mem [0:3]; initial $display(\"%b\",mem); endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] mem [0:1]; reg a; initial @(mem) a = 1; endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] a; initial $display(\"%b\",a[0]); endmodule", "bit and part selects");
    try expectRejected("module m; reg [3:0] mem [0:1][0:1]; initial $display(\"x\"); endmodule", "one unpacked array dimension");
    try expectRejected("module m; reg [3:0] mem [0:1]; initial mem[65'h1] = 0; endmodule", "indices wider than 64 bits");
    // §3.6 a disciplined net belongs to the analog solver, not to this executor.
    // A net's `=` no longer joins them: A.2.4's `net_decl_assignment` is a
    // continuous assignment on an UNdisciplined net, and it runs.
    try expectRejected("module m; electrical e; initial $display(\"x\"); endmodule", "disciplined and ground");
    try expectRejected("module m; wire [p:0] w; initial $display(\"x\"); endmodule", "bounds must be literal integers");
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
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #(128'd1) ; endmodule", "wider than 64");
    // §17.7: a clock query has no unit to report in without a timescale.
    try expectRejected("module m; initial $display(\"%0d\", $time); endmodule", "explicit valid timescale");
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
