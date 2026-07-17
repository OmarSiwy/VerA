//! What the drivers of a resolved net assert -> the value the net shows,
//! published through `State.store` so its waiters wake as `exec.resolve`'s
//! store wakes them, plus the delayed transitions in flight. The tables are
//! `digital/net.zig`'s; the one fold here, the all-strong one, is `Signal`'s.
//! Clauses: IEEE 1364-2005 §7.9 Tables 7-4 to 7-7, §7.10, §3.7, §3.8, §6.1.3,
//! §7.14 `delay3`, §7.8.5 gates, §7.6 MOS and pass switches, §8 UDPs, §19.10.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const dnet = @import("../digital/net.zig");
const Handle = @import("../scheduler.zig").Handle;
const root = @import("root.zig");
const State = root.State;
const Error = root.Error;
const logic = @import("logic.zig");
const Bit = logic.Bit;
const Signal = dnet.Signal;

/// `State.next` payloads: driver k's, net k's delayed transition, and net
/// k's §3.8 charge decay. All below `nba_payload`, above every pc and show.
pub const drive_base: u32 = root.show_base | 1 << 28;
/// `net_base + k`: net k's delayed transition lands (`drive_base`).
pub const net_base: u32 = root.show_base | 2 << 28;
/// `decay_base + k`: net k's §3.8 charge decays to x (`drive_base`).
pub const decay_base: u32 = root.show_base | 3 << 28;

/// One net `exec.resolve` folds: `Run.nets[k]` with its word offset.
pub const Net = struct {
    kind: Ast.NetKind,
    slot: u32,
    off: u32,
    width: u32,
    drivers: []const u32,
    /// Every driver asserts strong0/strong1 and never §7.10.2's H/L, and
    /// no switch reads the net's strength: `foldStrong` applies.
    strong: bool,
    delay: dnet.Delay = .{},
    charge: Ast.Strength = .medium,
    decay: ?u64 = null,
};

/// One driver of a `Net`, `Run.drivers[i]` without its expression.
pub const Driver = struct {
    net: u32,
    s0: Ast.Strength = .strong,
    s1: Ast.Strength = .strong,
    delay: dnet.Delay = .{},
    /// The bit whose value picks the delay (§7.14), or null for §6.1.3's
    /// whole-vector rule of a continuous assignment.
    delay_bit: ?u32 = 0,
    /// Its value at time 0: a sequential UDP's state (§8.5), else z.
    init: Bit = .z,
    source: Source,
};

/// What computes a driver's value.
pub const Source = union(enum) {
    expr,
    /// The output bit of a gate (one of a §7.1.5 array).
    gate: u32,
    /// Index into `Design.udps`.
    udp: u32,
    mos: Mos,
    bridge: Bridge,
    pull: Bit,
};

/// `dnet.Mos` resolved: its data terminal's net, when it names one, is
/// where its strength comes from.
pub const Mos = struct { n_type: bool, resistive: bool, data_net: ?u32 = null };

/// `dnet.Bridge` with its source slot's first word.
pub const Bridge = struct { src_off: u32, src_lo: u32, dst_lo: u32, width: u32 };

/// `dnet.Udp`'s table: `ins` inputs, its state at time 0.
pub const Udp = struct { rows: []const dnet.UdpRow, sequential: bool, ins: u32, state: Bit };

/// `dnet.Tran` without its control (a `switch_ctrl` process reads that):
/// `a` and `b` are `Nets.nets` rows, and `state` is the conduction at time 0.
pub const Tran = struct {
    a: u32,
    b: u32,
    a_bit: u32 = 0,
    b_bit: u32 = 0,
    on: Bit = .one,
    state: dnet.Tran.State = .on,
    resistive: bool = false,
    delay: dnet.Delay = .{},
};

/// `State.next` payload `tran_base + i`: pass switch i's delayed change of
/// conduction lands (`decay_base` with this bit set in its index).
const tran_bit: u32 = 1 << 27;
/// `tran_base + i`: pass switch i's delayed change of conduction lands.
pub const tran_base: u32 = decay_base + tran_bit;

/// What the resolution keeps between events, one row per net or driver.
pub const Nets = struct {
    nets: []const Net,
    drivers: []const Driver,
    udps: []const Udp,
    /// Per driver, its first word in `cur`/`tgt`: values then unknowns,
    /// as wide as its net.
    at: []u32,
    cur: []u64,
    tgt: []u64,
    or_z: []bool,
    tgt_or_z: []bool,
    /// A MOS switch's strengths follow its data (§7.12); the rest are fixed.
    s0: []Ast.Strength,
    s1: []Ast.Strength,
    flight: []?Handle,
    started: []bool,
    /// Per net, its first word in `res`/`ntgt`.
    nat: []u32,
    res: []u64,
    ntgt: []u64,
    nflight: []?Handle,
    capacitive: []bool,
    decay_ev: []?Handle,
    /// Bit 0's §7.10 signal, which a MOS switch passes on.
    sig0: []Signal,
    /// Per UDP, its first input in `prev`, the inputs its table last saw.
    pat: []u32,
    prev: []Int.Bit,
    state: []Int.Bit,
    /// All ones, as wide as the widest net: `store`'s mask.
    ones: []u64,
    /// A driver value under construction.
    scratch: []u64,
    /// §7.6 the pass switches, their conduction, the one in flight, and
    /// per net the switches with it as a terminal.
    trans: []const Tran = &.{},
    tstate: []dnet.Tran.State = &.{},
    ttarget: []dnet.Tran.State = &.{},
    tpending: []?Handle = &.{},
    on_net: []const []const u32 = &.{},

    /// The state at time 0, allocated from `gpa` for the whole run.
    pub fn init(gpa: std.mem.Allocator, nets: []const Net, drivers: []const Driver, udps: []const Udp, trans: []const Tran) Error!Nets {
        var t: Nets = undefined;
        t.nets = nets;
        t.drivers = drivers;
        t.udps = udps;
        t.trans = trans;
        t.tstate = try gpa.alloc(dnet.Tran.State, trans.len);
        t.ttarget = try gpa.alloc(dnet.Tran.State, trans.len);
        for (trans, t.tstate, t.ttarget) |tr, *st, *tg| {
            st.* = tr.state;
            tg.* = tr.state;
        }
        t.tpending = try gpa.alloc(?Handle, trans.len);
        @memset(t.tpending, null);
        const on_net = try gpa.alloc([]const u32, nets.len);
        for (on_net, 0..) |*l, k| {
            var list: std.ArrayList(u32) = .empty;
            for (trans, 0..) |tr, i| if (tr.a == k or tr.b == k) try list.append(gpa, @intCast(i));
            l.* = list.items;
        }
        t.on_net = on_net;
        var widest: u32 = 1;
        t.at = try gpa.alloc(u32, drivers.len);
        var n: u32 = 0;
        for (drivers, t.at) |d, *at| {
            at.* = n;
            n += 2 * words(nets[d.net].width);
        }
        t.cur = try gpa.alloc(u64, n);
        t.tgt = try gpa.alloc(u64, n);
        @memset(t.tgt, 0);
        for (drivers, t.at) |d, at| {
            const w = nets[d.net].width;
            // A UDP's initial value is its output bit's (§8.5); the rest z.
            fill(t.cur[at..][0 .. 2 * words(w)], w, if (d.source == .udp) .z else d.init);
            if (d.source == .udp) setBit(t.cur[at..][0 .. 2 * words(w)], d.delay_bit orelse 0, int(d.init));
        }
        t.or_z = try gpa.alloc(bool, drivers.len);
        t.tgt_or_z = try gpa.alloc(bool, drivers.len);
        @memset(t.or_z, false);
        @memset(t.tgt_or_z, false);
        t.s0 = try gpa.alloc(Ast.Strength, drivers.len);
        t.s1 = try gpa.alloc(Ast.Strength, drivers.len);
        for (drivers, t.s0, t.s1) |d, *s0, *s1| {
            s0.* = d.s0;
            s1.* = d.s1;
        }
        t.flight = try gpa.alloc(?Handle, drivers.len);
        @memset(t.flight, null);
        t.started = try gpa.alloc(bool, drivers.len);
        @memset(t.started, false);
        t.nat = try gpa.alloc(u32, nets.len);
        n = 0;
        for (nets, t.nat) |net, *at| {
            at.* = n;
            n += 2 * words(net.width);
            widest = @max(widest, net.width);
        }
        t.res = try gpa.alloc(u64, n);
        t.ntgt = try gpa.alloc(u64, n);
        @memset(t.res, 0);
        @memset(t.ntgt, 0);
        t.nflight = try gpa.alloc(?Handle, nets.len);
        t.decay_ev = try gpa.alloc(?Handle, nets.len);
        t.capacitive = try gpa.alloc(bool, nets.len);
        t.sig0 = try gpa.alloc(Signal, nets.len);
        @memset(t.nflight, null);
        @memset(t.decay_ev, null);
        @memset(t.capacitive, false);
        @memset(t.sig0, .{});
        t.pat = try gpa.alloc(u32, udps.len);
        t.state = try gpa.alloc(Int.Bit, udps.len);
        n = 0;
        for (udps, t.pat, t.state) |u, *at, *st| {
            at.* = n;
            n += u.ins;
            st.* = int(u.state);
        }
        t.prev = try gpa.alloc(Int.Bit, n);
        @memset(t.prev, .x);
        t.ones = try gpa.alloc(u64, words(widest));
        @memset(t.ones, std.math.maxInt(u64));
        t.scratch = try gpa.alloc(u64, 2 * words(widest));
        return t;
    }
};

fn words(w: u32) u32 {
    return (w + 63) / 64;
}

fn int(b: Bit) Int.Bit {
    return @fromBackingInt(@intCast(@backingInt(b)));
}

/// `planes` (values then unknowns) of a `w`-bit value, every bit `b`.
fn fill(planes: []u64, w: u32, b: Bit) void {
    const n = planes.len / 2;
    for (planes[0..n], planes[n..], 0..) |*v, *x, j| {
        const m = dnet.wordMask(w, j);
        v.* = if (@backingInt(b) & 1 != 0) m else 0;
        x.* = if (@backingInt(b) >> 1 != 0) m else 0;
    }
}

fn bitAt(planes: []const u64, i: u32) Int.Bit {
    const n = planes.len / 2;
    const v: u2 = @intCast(planes[i / 64] >> @intCast(i % 64) & 1);
    const x: u2 = @intCast(planes[n + i / 64] >> @intCast(i % 64) & 1);
    return @fromBackingInt(@intCast(v | x << 1));
}

fn setBit(planes: []u64, i: u32, b: Int.Bit) void {
    const n = planes.len / 2;
    const at = @as(u64, 1) << @intCast(i % 64);
    const e = @backingInt(b);
    planes[i / 64] = (planes[i / 64] & ~at) | (if (e & 1 != 0) at else 0);
    planes[n + i / 64] = (planes[n + i / 64] & ~at) | (if (e >> 1 != 0) at else 0);
}

fn literal(planes: []const u64, w: u32) Int.Literal {
    return .{ .width = w, .signed = false, .sized = true, .planes = @constCast(planes) };
}

/// `exec` `.continuous`: driver `i` asserts `planes` (values then unknowns,
/// its net's width) and, when `or_z`, §7.10.2's H/L. With a `delay3` the
/// value arrives by §6.1.3's inertial rule; without, the net resolves now.
pub fn drive(s: *State, i: u32, planes: []const u64, or_z: bool) Error!void {
    const t = &s.nets;
    const d = t.drivers[i];
    const cur = t.cur[t.at[i]..][0..planes.len];
    // §8.5: a sequential UDP's initial output is published at time 0
    // whatever its delay.
    const first = d.source == .udp and t.udps[d.source.udp].sequential and !t.started[i];
    // A combinational one's output is x until its first delayed value.
    if (d.source == .udp and !t.started[i] and !first and d.delay.present) try resolve(s, d.net);
    t.started[i] = true;
    if (d.delay.present and !first) {
        const tgt = t.tgt[t.at[i]..][0..planes.len];
        const h = planes.len / 2;
        if (!try inertial(s, &t.flight[i], tgt, &t.tgt_or_z[i], cur[0..h], cur[h..], t.or_z[i], planes, or_z)) return;
        const w = t.nets[d.net].width;
        const ticks = if (d.delay_bit) |b| d.delay.to(bitAt(tgt, b)) else d.delay.continuous(literal(cur, w), literal(tgt, w));
        t.flight[i] = s.sched.scheduleAfter(ticks, .inactive, drive_base + i) catch |e| return s.timeFail(e);
        return;
    }
    @memcpy(cur, planes);
    t.or_z[i] = or_z;
    return resolve(s, d.net);
}

/// `drive` of a value that is z but for bit `at`, which is `b`.
fn driveBit(s: *State, i: u32, at: u32, b: Int.Bit, or_z: bool) Error!void {
    const t = &s.nets;
    const planes = t.scratch[0 .. 2 * words(t.nets[t.drivers[i].net].width)];
    fill(planes, t.nets[t.drivers[i].net].width, .z);
    setBit(planes, at, b);
    return drive(s, i, planes, or_z);
}

/// §7.8.5 gate driver `i` of type `kind` over its input bits.
pub fn gate(s: *State, i: u32, comptime kind: Ast.GateKind, ins: []const Bit) Error!void {
    const o = dnet.gateBit(kind, @ptrCast(ins));
    return driveBit(s, i, s.nets.drivers[i].source.gate, o.bit, o.or_z);
}

/// §8 UDP driver `i` over its input bits (`exec.udpValue`).
pub fn udp(s: *State, i: u32, ins: []const Bit) Error!void {
    const t = &s.nets;
    const k = t.drivers[i].source.udp;
    const u = t.udps[k];
    var buf: [64]Int.Bit = undefined;
    const bits = buf[0..ins.len];
    // §8.1.6: a z input is read as x.
    for (ins, bits) |b, *o| o.* = if (b == .z) .x else int(b);
    const out = if (!u.sequential) dnet.udpEval(u.rows, false, bits, .x, null, .x) else blk: {
        const prev = t.prev[t.pat[k]..][0..ins.len];
        for (bits, 0..) |b, j| {
            if (b == prev[j]) continue;
            const from = prev[j];
            prev[j] = b;
            t.state[k] = dnet.udpEval(u.rows, true, prev, t.state[k], @intCast(j), from);
        }
        break :blk t.state[k];
    };
    return driveBit(s, i, t.drivers[i].delay_bit orelse 0, out, false);
}

/// §7.6 MOS switch driver `i` (`exec.mosValue`): its data at the data
/// net's strength, reduced by §7.12, while `gate` conducts; z when it does
/// not; H/L when the gate is x or z. A z on the data passes as z.
pub fn mos(s: *State, i: u32, data: Bit, gate_: Bit) Error!void {
    const t = &s.nets;
    const m = t.drivers[i].source.mos;
    const g = int(gate_);
    const sig: Signal = if (m.data_net) |k| t.sig0[k] else .of(int(data), .strong, .strong);
    t.s0[i] = dnet.reduce(if (sig.lo < 0) @fromBackingInt(@intCast(@as(u8, @intCast(-sig.lo)))) else .highz, m.resistive);
    t.s1[i] = dnet.reduce(if (sig.hi > 0) @fromBackingInt(@intCast(@as(u8, @intCast(sig.hi)))) else .highz, m.resistive);
    const value = sig.collapse();
    const on: Int.Bit = if (m.n_type) .one else .zero;
    const out: Int.Bit = if (value == .z or (g != on and (g == .zero or g == .one))) .z else value;
    return driveBit(s, i, 0, out, out != .z and g != on);
}

/// §6.5.7.1 port window driver `i`: its source's bits, z outside them.
pub fn bridge(s: *State, i: u32) Error!void {
    const t = &s.nets;
    const b = t.drivers[i].source.bridge;
    const w = t.nets[t.drivers[i].net].width;
    const planes = t.scratch[0 .. 2 * words(w)];
    fill(planes, w, .z);
    for (0..b.width) |j| {
        const at = b.src_lo + @as(u32, @intCast(j));
        const o = b.src_off + at / 64;
        const v: u2 = @intCast(s.v[o] >> @intCast(at % 64) & 1);
        const x: u2 = if (logic.two) 0 else @intCast(s.x[o] >> @intCast(at % 64) & 1);
        setBit(planes, b.dst_lo + @as(u32, @intCast(j)), @fromBackingInt(@intCast(v | x << 1)));
    }
    return drive(s, i, planes, false);
}

/// §19.10 `unconnected_drive` driver `i`: its level on every bit.
pub fn pull(s: *State, i: u32) Error!void {
    const t = &s.nets;
    const w = t.nets[t.drivers[i].net].width;
    const planes = t.scratch[0 .. 2 * words(w)];
    fill(planes, w, t.drivers[i].source.pull);
    return drive(s, i, planes, false);
}

/// `exec.resolve` of net `k`: every driver folded, a `trireg`'s charge
/// where none asserts anything, the net type's own pull; then published,
/// or after the net's `delay3`.
pub fn resolve(s: *State, k: u32) Error!void {
    const t = &s.nets;
    if (t.on_net.len != 0 and t.on_net[k].len != 0) return resolveJoined(s, k);
    const n = t.nets[k];
    const nw = words(n.width);
    const res = t.res[t.nat[k]..][0 .. 2 * nw];
    const cv = s.v[n.off..][0..nw];
    const cx = s.x[n.off..][0..nw];
    const floating = if (n.strong) foldStrong(t, n, res, cv, cx) else fold(t, k, res, cv, cx);
    if (n.kind == .trireg) try chargeState(s, k, floating);
    if (n.delay.present) {
        const tgt = t.ntgt[t.nat[k]..][0 .. 2 * nw];
        var or_z = false;
        if (try inertial(s, &t.nflight[k], tgt, &or_z, cv, cx, false, res, false))
            t.nflight[k] = s.sched.scheduleAfter(n.delay.to(bitAt(tgt, 0)), .inactive, net_base + k) catch |e| return s.timeFail(e);
        return;
    }
    return s.store(n.slot, n.off, res[0..nw], res[nw..], t.ones[0..nw]);
}

/// `Signal`'s fold when every driver is strong and none is H/L: a driver
/// bit is St0, St1, StX or nothing, so a strength never decides and the
/// §7.9 tables reduce to plane algebra. `(cv, cx)` is the value the net
/// shows, a `trireg`'s charge. Whether no bit is driven (§3.8).
fn foldStrong(t: *const Nets, n: Net, res: []u64, cv: []const u64, cx: []const u64) bool {
    const nw = cv.len;
    var driven_any: u64 = 0;
    for (0..nw) |j| {
        const m = dnet.wordMask(n.width, j);
        var one: u64 = 0;
        var zero: u64 = 0;
        var unk: u64 = 0;
        for (n.drivers) |di| {
            const p = t.cur[t.at[di]..];
            const v = p[j];
            const x = p[nw + j];
            one |= v & ~x;
            zero |= ~v & ~x & m;
            unk |= v & x;
        }
        const driven = one | zero | unk;
        const z = m & ~driven;
        // Per bit, x where the table says so and 1 where only a 1 remains.
        // Table 7-4: disagreement is x. At equal strength a 0 decides
        // wired `and` (Table 7-6), a 1 wired `or` (Table 7-7).
        const X, const o = if (dnet.wiredLogic(n.kind)) |table| switch (table) {
            .@"and" => .{ unk & ~zero, one & ~zero & ~unk },
            .@"or" => .{ unk & ~one, one },
        } else .{ unk | (one & zero), one & ~zero & ~unk };
        var v = o | X;
        var x = X | z;
        switch (n.kind) {
            // §3.7 the net type's pull fills what no driver asserts, a
            // supply's beats every strong one.
            .tri0 => x &= ~z,
            .tri1 => {
                v |= z;
                x &= ~z;
            },
            .supply0 => {
                v = 0;
                x = 0;
            },
            .supply1 => {
                v = m;
                x = 0;
            },
            // §3.8 an undriven bit holds its charge.
            .trireg => {
                v = (v & driven) | (cv[j] & z);
                x = (x & driven) | (cx[j] & z);
            },
            .wire, .tri, .uwire, .wand, .wor, .triand, .trior, .wreal => {},
        }
        res[j] = v;
        res[nw + j] = x;
        driven_any |= driven;
    }
    return driven_any == 0;
}

/// `exec.resolve`'s fold, bit by bit through `Signal`.
fn fold(t: *Nets, k: u32, res: []u64, cv: []const u64, cx: []const u64) bool {
    const n = t.nets[k];
    const nw = cv.len;
    const tables = dnet.wiredLogic(n.kind);
    var floating: u32 = 0;
    for (0..n.width) |bi| {
        const at: u32 = @intCast(bi);
        var acc: Signal = .{};
        for (n.drivers) |di| {
            const b = bitAt(t.cur[t.at[di]..][0 .. 2 * nw], at);
            const c: Signal = if (t.or_z[di] and b != .z) .orZ(b, t.s0[di], t.s1[di]) else .of(b, t.s0[di], t.s1[di]);
            acc = if (tables) |table| acc.combineWired(c, table) else acc.combine(c);
        }
        if (n.kind == .trireg and acc.none()) {
            const w = at / 64;
            const sh: u6 = @intCast(at % 64);
            const cb: Int.Bit = @fromBackingInt(@intCast(@as(u2, @intCast(cv[w] >> sh & 1)) | @as(u2, @intCast(cx[w] >> sh & 1)) << 1));
            acc = .of(cb, n.charge, n.charge);
            floating += 1;
        }
        acc = acc.combine(dnet.netPull(n.kind));
        if (at == 0) t.sig0[k] = acc;
        setBit(res, at, acc.collapse());
    }
    return floating == n.width;
}

/// One bit of one net, as a pass switch terminal sees it.
const Node = struct { net: u32, bit: u32 };

/// `exec.resolveJoined`: §7.6 "switch processing shall consider all the
/// devices in a bidirectional switch-connected net before it can determine
/// the appropriate value for any node". Each bit of net `start` and the net
/// bits joined to it through switches that may conduct resolve as one, from
/// every driver of every one of them, reduced by the switches crossed (§7.11,
/// §7.12) and widened to include high impedance across one of unknown
/// conduction (§7.10.2); with no driver asserting anything, the group's
/// triregs share their charge (§4.6.3.1). Every net touched is published.
/// ponytail: the interpreter's limits, kept: no charge decay, wired logic or
/// net delay inside a joined group, and the group is found afresh each time.
fn resolveJoined(s: *State, start: u32) Error!void {
    const t = &s.nets;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var touched: std.ArrayList(u32) = .empty;
    for (0..t.nets[start].width) |i| {
        const group = try reach(t, a, .{ .net = start, .bit = @intCast(i) });
        for (group) |y| {
            const paths = try switchPaths(t, a, y, group);
            var acc: Signal = .{};
            for (group, paths) |z, p| {
                var own = dnet.netPull(t.nets[z.net].kind);
                for (t.nets[z.net].drivers) |di| own = own.combine(contribution(t, di, z.bit));
                acc = acc.combine(crossed(own, z, y, p));
            }
            if (acc.none()) for (group, paths) |z, p| {
                const n = t.nets[z.net];
                if (n.kind == .trireg) acc = acc.combine(crossed(.of(shown(s, n, z.bit), n.charge, n.charge), z, y, p));
            };
            const n = t.nets[y.net];
            const res = t.res[t.nat[y.net]..][0 .. 2 * words(n.width)];
            // A net first reached here keeps what it shows on the bits no
            // switch joins (`exec`'s `resolved`, which it published).
            if (std.mem.indexOfScalar(u32, touched.items, y.net) == null) {
                try touched.append(a, y.net);
                const nw = words(n.width);
                @memcpy(res[0..nw], s.v[n.off..][0..nw]);
                if (logic.two) @memset(res[nw..], 0) else @memcpy(res[nw..], s.x[n.off..][0..nw]);
            }
            if (y.bit == 0) t.sig0[y.net] = acc;
            setBit(res, y.bit, acc.collapse());
        }
    }
    for (touched.items) |k| {
        const n = t.nets[k];
        const nw = words(n.width);
        const res = t.res[t.nat[k]..][0 .. 2 * nw];
        try s.store(n.slot, n.off, res[0..nw], res[nw..], t.ones[0..nw]);
    }
}

/// Bit `at` of what net `n` shows.
fn shown(s: *const State, n: Net, at: u32) Int.Bit {
    const o = n.off + at / 64;
    const v: u2 = @intCast(s.v[o] >> @intCast(at % 64) & 1);
    const x: u2 = if (logic.two) 0 else @intCast(s.x[o] >> @intCast(at % 64) & 1);
    return @fromBackingInt(@intCast(v | x << 1));
}

/// What driver `di` asserts on bit `at` of its net (`exec.contribution`).
pub fn contribution(t: *const Nets, di: u32, at: u32) Signal {
    const nw = words(t.nets[t.drivers[di].net].width);
    const b = bitAt(t.cur[t.at[di]..][0 .. 2 * nw], at);
    return if (t.or_z[di] and b != .z) .orZ(b, t.s0[di], t.s1[di]) else .of(b, t.s0[di], t.s1[di]);
}

/// `exec.arrive`: what `own`, asserted at `z`, asserts at `y` over `p`.
fn crossed(own: Signal, z: Node, y: Node, p: SwitchPath) Signal {
    const sig = dnet.reduceSignal(own, @intFromBool(!std.meta.eql(z, y)), p.res);
    return if (p.sure or sig.none()) sig else .{ .lo = @min(sig.lo, 0), .hi = @max(sig.hi, 0) };
}

/// The terminal of switch `tr` across from `u`, or null when `u` is neither.
fn across(tr: Tran, u: Node) ?Node {
    if (tr.a == u.net and tr.a_bit == u.bit) return .{ .net = tr.b, .bit = tr.b_bit };
    if (tr.b == u.net and tr.b_bit == u.bit) return .{ .net = tr.a, .bit = tr.a_bit };
    return null;
}

/// The net bits joined to `from` through pass switches that may conduct.
fn reach(t: *const Nets, a: std.mem.Allocator, from: Node) Error![]const Node {
    var seen: std.ArrayList(Node) = .empty;
    try seen.append(a, from);
    var i: usize = 0;
    while (i < seen.items.len) : (i += 1) {
        const u = seen.items[i];
        for (t.on_net[u.net]) |ti| {
            if (t.tstate[ti] == .off) continue;
            const v = across(t.trans[ti], u) orelse continue;
            for (seen.items) |w| {
                if (std.meta.eql(w, v)) break;
            } else try seen.append(a, v);
        }
    }
    return seen.items;
}

/// From a group member to `y`: the fewest resistive switches on a path that
/// may conduct, and whether some path surely does.
const SwitchPath = struct { res: u32, sure: bool };

fn switchPaths(t: *const Nets, a: std.mem.Allocator, y: Node, group: []const Node) Error![]const SwitchPath {
    const p = try a.alloc(SwitchPath, group.len);
    @memset(p, .{ .res = std.math.maxInt(u32), .sure = false });
    for (group, p) |u, *q| if (std.meta.eql(u, y)) {
        q.* = .{ .res = 0, .sure = true };
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (group, 0..) |u, iu| {
            if (p[iu].res == std.math.maxInt(u32)) continue;
            for (t.on_net[u.net]) |ti| {
                const st = t.tstate[ti];
                if (st == .off) continue;
                const v = across(t.trans[ti], u) orelse continue;
                const iv = for (group, 0..) |w, k| {
                    if (std.meta.eql(w, v)) break k;
                } else continue;
                const res = p[iu].res + @intFromBool(t.trans[ti].resistive);
                if (res < p[iv].res) {
                    p[iv].res = res;
                    changed = true;
                }
                if (p[iu].sure and st == .on and !p[iv].sure) {
                    p[iv].sure = true;
                    changed = true;
                }
            }
        }
    }
    return p;
}

/// `exec` `.switch_ctrl`: pass switch `i`'s control reads `c`, so it
/// conducts, does not, or may (x or z); both sides re-resolve now, or after
/// the switch's delay (`switchAfter`).
pub fn switchCtrl(s: *State, i: u32, c: Bit) Error!void {
    const t = &s.nets;
    const tr = t.trans[i];
    const cb = int(c);
    const next: dnet.Tran.State = if (cb == int(tr.on)) .on else if (cb == .zero or cb == .one) .off else .unknown;
    if (tr.delay.present) return switchAfter(s, i, next);
    t.tstate[i] = next;
    try resolve(s, tr.a);
    try resolve(s, tr.b);
}

/// `exec.switchAfter`: a controlled switch with a delay turns on after the
/// first, off after the second, and to unknown conduction after the
/// smaller; a control that returns before its change lands cancels it.
fn switchAfter(s: *State, i: u32, next: dnet.Tran.State) Error!void {
    const t = &s.nets;
    const settled = if (t.tpending[i] != null) t.ttarget[i] else t.tstate[i];
    if (settled == next) return;
    if (t.tpending[i]) |h| _ = s.sched.cancel(h) catch |e| return s.schedFail(e);
    t.tpending[i] = null;
    if (next == t.tstate[i]) return;
    t.ttarget[i] = next;
    const to: Int.Bit = switch (next) {
        .on => .one,
        .off => .zero,
        .unknown => .x,
    };
    t.tpending[i] = s.sched.scheduleAfter(t.trans[i].delay.to(to), .inactive, tran_base + i) catch |e| return s.timeFail(e);
}

/// `exec.chargeState`: the §3.8 decay countdown restarts on each entry
/// into the capacitive state and stops on leaving it.
fn chargeState(s: *State, k: u32, floating: bool) Error!void {
    const t = &s.nets;
    const was = t.capacitive[k];
    t.capacitive[k] = floating;
    if (was == floating) return;
    if (t.decay_ev[k]) |h| _ = s.sched.cancel(h) catch |e| return s.schedFail(e);
    t.decay_ev[k] = null;
    if (!floating) return;
    const after = t.nets[k].decay orelse return;
    t.decay_ev[k] = s.sched.scheduleAfter(after, .inactive, decay_base + k) catch |e| return s.timeFail(e);
}

/// `exec.schedule`, §6.1.3's inertial rule: whether a transition to `to`
/// must be scheduled, having cancelled the one it displaces and recorded
/// `to` in `tgt`. Not when the value settles back to what is published, or
/// is what is already on its way: a pulse shorter than the delay vanishes.
fn inertial(s: *State, flight: *?Handle, tgt: []u64, tgt_or_z: *bool, from_v: []const u64, from_x: []const u64, from_or_z: bool, to: []const u64, to_or_z: bool) Error!bool {
    const h = to.len / 2;
    const same = if (flight.* != null)
        std.mem.eql(u64, tgt, to) and tgt_or_z.* == to_or_z
    else
        std.mem.eql(u64, from_v, to[0..h]) and (logic.two or std.mem.eql(u64, from_x, to[h..])) and from_or_z == to_or_z;
    if (same) return false;
    if (flight.*) |f| _ = s.sched.cancel(f) catch |e| return s.schedFail(e);
    flight.* = null;
    @memcpy(tgt, to);
    tgt_or_z.* = to_or_z;
    return true;
}

/// `State.next`'s dispatch of a `drive_base`/`net_base`/`decay_base`
/// payload (`Run.runUntil`'s `.drive`, `.net_update`, `.decay`).
pub fn arrive(s: *State, payload: u32) Error!void {
    const t = &s.nets;
    const k = payload & ((1 << 28) - 1);
    switch (payload - k) {
        drive_base => {
            const d = t.drivers[k];
            const n = 2 * words(t.nets[d.net].width);
            t.flight[k] = null;
            @memcpy(t.cur[t.at[k]..][0..n], t.tgt[t.at[k]..][0..n]);
            t.or_z[k] = t.tgt_or_z[k];
            return resolve(s, d.net);
        },
        net_base => {
            const n = t.nets[k];
            const nw = words(n.width);
            t.nflight[k] = null;
            const tgt = t.ntgt[t.nat[k]..];
            return s.store(n.slot, n.off, tgt[0..nw], tgt[nw..][0..nw], t.ones[0..nw]);
        },
        // §3.8: a charge held for the decay time is worth nothing, x.
        decay_base => if (k >= tran_bit) {
            const i = k - tran_bit;
            t.tpending[i] = null;
            t.tstate[i] = t.ttarget[i];
            try resolve(s, t.trans[i].a);
            return resolve(s, t.trans[i].b);
        } else {
            const n = t.nets[k];
            const nw = words(n.width);
            t.decay_ev[k] = null;
            const res = t.res[t.nat[k]..][0 .. 2 * nw];
            fill(res, n.width, .x);
            return s.store(n.slot, n.off, res[0..nw], res[nw..], t.ones[0..nw]);
        },
        else => unreachable,
    }
}

test "the all-strong plane fold is Signal's fold" {
    // Every net kind the fold covers, three drivers, every 4^3 combination
    // on one bit each, against `exec.resolve`'s per-bit fold.
    const kinds = [_]Ast.NetKind{ .wire, .tri, .wand, .wor, .triand, .trior, .tri0, .tri1, .supply0, .supply1, .trireg };
    const bits = [_]Int.Bit{ .zero, .one, .z, .x };
    for (kinds) |kind| for (bits) |charge| {
        var cur: [3 * 2]u64 = undefined;
        const at = [_]u32{ 0, 2, 4 };
        for (0..64) |combo| {
            // Driver j's value in bit 0 of its own planes.
            for (0..3) |j| {
                const b = bits[combo >> @intCast(2 * j) & 3];
                cur[at[j]] = @backingInt(b) & 1;
                cur[at[j] + 1] = @backingInt(b) >> 1;
            }
            const net: Net = .{ .kind = kind, .slot = 0, .off = 0, .width = 1, .drivers = &.{ 0, 1, 2 }, .strong = true };
            const t: Nets = .{
                .nets = &.{net},
                .drivers = &.{},
                .udps = &.{},
                .at = @constCast(&at),
                .cur = &cur,
                .tgt = &.{},
                .or_z = @constCast(&[_]bool{ false, false, false }),
                .tgt_or_z = &.{},
                .s0 = @constCast(&[_]Ast.Strength{ .strong, .strong, .strong }),
                .s1 = @constCast(&[_]Ast.Strength{ .strong, .strong, .strong }),
                .flight = &.{},
                .started = &.{},
                .nat = &.{},
                .res = &.{},
                .ntgt = &.{},
                .nflight = &.{},
                .capacitive = &.{},
                .decay_ev = &.{},
                .sig0 = @constCast(&[_]Signal{.{}}),
                .pat = &.{},
                .prev = &.{},
                .state = &.{},
                .ones = &.{},
                .scratch = &.{},
            };
            const cv = [_]u64{@backingInt(charge) & 1};
            const cx = [_]u64{@backingInt(charge) >> 1};
            var fast: [2]u64 = undefined;
            var slow: [2]u64 = .{ 0, 0 };
            var tt = t;
            const f1 = foldStrong(&tt, net, &fast, &cv, &cx);
            const f2 = fold(&tt, 0, &slow, &cv, &cx);
            try std.testing.expectEqual(slow, fast);
            // Only a `trireg` counts its undriven bits.
            if (kind == .trireg) try std.testing.expectEqual(f2, f1);
        }
    };
}
