//! Net resolution of the interpreter: a net's drivers (their current
//! values and strengths) -> the value it shows, published through
//! `waiters.store`; plus each driver kind's own value and the delayed
//! transitions in flight. The tables it folds with are `net.zig`'s.
//! Clauses: IEEE 1364-2005 §3.7, §3.8, §6.1.3 inertial delay, §7.6 MOS and
//! pass switches, §7.8.5 gates, §7.9, §7.10, §7.11, §7.12, §8 UDPs,
//! §8.5.3.5; VAMS §3.7 wreal.
const std = @import("std");
const Int = @import("kernels").Integer;
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const net_mod = @import("net.zig");
const Inertial = net_mod.Inertial;
const no_cold = net_mod.no_cold;
const Bridge = net_mod.Bridge;
const Gate = net_mod.Gate;
const gateBit = net_mod.gateBit;
const Signal = net_mod.Signal;
const netPull = net_mod.netPull;
const wiredLogic = net_mod.wiredLogic;
const filled = net_mod.filled;
const setBit = net_mod.setBit;
const Tran = net_mod.Tran;
const reach = net_mod.reach;
const switchPaths = net_mod.switchPaths;
const crossed = net_mod.crossed;
const foldUniform = net_mod.foldUniform;
const evaluate = @import("evaluate.zig");
const exec = @import("exec.zig");
const waiters = @import("waiters.zig");

/// §7.9: a net's value is the wired-logic resolution of all its drivers, so
/// it is recomputed whole on every driver update and published through
/// `store`, the path a variable write takes, so `@(posedge w)` resumes on a
/// net.
pub fn resolve(self: *Run, net: u32) Error!void {
    const n = self.nets[net];
    const drivers = self.netDrivers(net);
    // A §18.4 port's state can change with its drivers' strengths alone.
    if (self.watch[n.slot].contains(.ports)) try waiters.requestVcd(self);
    if (self.netCold(n).trans.len != 0) return resolveJoined(self, net);
    // VAMS §3.7: a wreal has at most one driver and is that driver's value
    // (no four-state resolution, no strength), and 0.0 with none.
    if (n.kind == .wreal) {
        n.resolved.values()[0] = 0;
        n.resolved.unknowns()[0] = 0;
        for (drivers) |d| {
            const cur = self.drivers[d].current;
            if (!cur.hasUnknown()) n.resolved.values()[0] = cur.values()[0];
        }
        return waiters.store(self, n.slot, n.resolved.planes);
    }
    const current = self.values[n.slot];
    const tables = wiredLogic(n.kind);
    var floating: u32 = 0;
    if (uniform(self, net)) foldUniform(n.resolved, self.drivers, drivers) else for (0..n.resolved.width) |i| {
        const at: u32 = @intCast(i);
        var acc: Signal = .{};
        for (drivers) |d| {
            const c = contribution(self.drivers[d], at);
            acc = if (tables) |table| acc.combineWired(c, table) else acc.combine(c);
        }
        // §7.9/§7.10: a `trireg` with no driver asserting anything is in
        // the capacitive state, and what it asserts there is the charge
        // it last held, at its charge strength. Checked before the net
        // type's own pull so that a driven trireg never sees it.
        if (n.kind == .trireg and acc.none()) {
            acc = .of(current.bit(at), n.charge, n.charge);
            floating += 1;
        }
        acc = acc.combine(netPull(n.kind));
        self.signals[n.signal + at] = acc;
        setBit(n.resolved, at, acc.collapse());
    }
    if (n.kind == .trireg) try chargeState(self, net, floating == n.resolved.width);
    // A.2.1.3's `[ delay3 ]` delays the net's own transition, so it applies
    // between the resolution and the publish, after every driver is folded in.
    if (self.netCold(n).delay.present) {
        const c = try self.netColdMut(net);
        const st = &c.transition;
        if (try schedule(self, self.values[n.slot], false, n.resolved, false, st))
            st.in_flight = try exec.enqueue(self, .{ .net_update = net }, c.delay.continuous(self.values[n.slot].truth(), st.target), false);
        return;
    }
    try waiters.store(self, n.slot, n.resolved.planes);
}

/// Whether `net` resolves plane-wise (`net.foldUniform`): a net type with no
/// wired logic and no pull of its own (§7.9), whose per-bit `signal` nothing
/// reads (`Net.strength_read`), driven at one strength on both sides by
/// every driver, none of them H/L (§7.10.2).
fn uniform(self: *const Run, net: u32) bool {
    const n = self.nets[net];
    switch (n.kind) {
        .wire, .tri, .uwire => {},
        .tri0, .tri1, .trireg, .wand, .wor, .triand, .trior, .supply0, .supply1, .wreal => return false,
    }
    const ids = self.netDrivers(net);
    if (n.strength_read or ids.len == 0) return false;
    const s = self.drivers[ids[0]].s0;
    if (s == .highz) return false;
    for (ids) |d| {
        const dr = self.drivers[d];
        if (dr.or_z or dr.s0 != s or dr.s1 != s or dr.current.planes.len != n.resolved.planes.len) return false;
    }
    return true;
}

/// IEEE 1364-2005 §7.6/§8.5.3.5 "switch processing shall consider all the
/// devices in a bidirectional switch-connected net before it can determine
/// the appropriate value for any node": the net bits joined through
/// conducting pass switches resolve as one, from every driver of every one of
/// them. A signal crossing a switch loses supply strength (§7.11) and one
/// Table 7-8 step per resistive switch on the strongest path (§7.12). Across
/// a switch of unknown conduction a driver may or may not arrive, so what it
/// asserts there is widened to include high impedance (§7.10.2). With no
/// driver asserting anything, the group's triregs are §4.6.3.1's capacitive
/// network: each asserts the charge it holds at its charge strength, so the
/// larger charge wins and equal ones of different values make x.
/// ponytail: no charge decay, wired logic or net delay inside a joined
/// group; the group is found afresh on every resolution, which is fine for
/// the handful of switches a digital fixture wires up.
fn resolveJoined(self: *Run, start: u32) Error!void {
    // `Run.resolve_scratch`, kept between calls so a resolution per event
    // does not grow the run's arena; a nested call (a store below waking
    // another group) shares it, and only the outermost resets it.
    if (self.resolve_depth == 0) _ = self.resolve_scratch.reset(.retain_capacity);
    self.resolve_depth += 1;
    defer self.resolve_depth -= 1;
    const a = self.resolve_scratch.allocator();
    var touched: std.ArrayList(u32) = .empty;
    try touched.append(a, start);
    for (0..self.nets[start].resolved.width) |i| {
        const group = try reach(Switches{ .r = self }, a, .{ .net = start, .bit = @intCast(i) });
        for (group) |y| {
            const paths = try switchPaths(Switches{ .r = self }, a, y, group);
            var acc: Signal = .{};
            for (group, paths) |z, p| {
                const n = self.nets[z.net];
                var own = netPull(n.kind);
                for (self.netDrivers(z.net)) |d| own = own.combine(contribution(self.drivers[d], z.bit));
                acc = acc.combine(crossed(own, z, y, p));
            }
            if (acc.none()) for (group, paths) |z, p| {
                const n = self.nets[z.net];
                if (n.kind == .trireg) acc = acc.combine(crossed(.of(self.values[n.slot].bit(z.bit), n.charge, n.charge), z, y, p));
            };
            const n = self.nets[y.net];
            self.signals[n.signal + y.bit] = acc;
            setBit(n.resolved, y.bit, acc.collapse());
            if (std.mem.findScalar(u32, touched.items, y.net) == null) try touched.append(a, y.net);
        }
    }
    for (touched.items) |t| try waiters.store(self, self.nets[t].slot, self.nets[t].resolved.planes);
}

/// `net.reach`'s and `net.switchPaths`'s view of the run's switches: each
/// net's `NetCold.trans` list and the conduction held in its `Tran` row.
const Switches = struct {
    r: *const Run,
    pub fn switches(g: Switches, net: u32) []const u32 {
        return g.r.netCold(g.r.nets[net]).trans;
    }
    pub fn tran(g: Switches, ti: u32) Tran {
        return g.r.trans[ti];
    }
    pub fn conduction(g: Switches, ti: u32) Tran.State {
        return g.r.trans[ti].state;
    }
};

/// §7.6 what a MOS switch drives: its data's value, at the data's strength
/// reduced by §7.12 (the resolved strength of a net, strong for anything
/// else), when its gate conducts; z when it does not; §7.10.2's H or L when
/// the gate is x or z. A z on the data is z whatever the gate ("a switch
/// transmits the z through"), where a switch differs from a bufif.
pub fn mosValue(self: *Run, scratch: std.mem.Allocator, at: u32, m: net_mod.Mos, or_z: *bool) Error!Int.Literal {
    const ex = &self.file.exprs;
    const g = (try evaluate.eval(self, scratch, m.gate, 1)).bit(0);
    var sig: Signal = .of((try evaluate.eval(self, scratch, m.data, 1)).bit(0), .strong, .strong);
    if (ex.tag(m.data) == .ident) if (self.net_of.get(try self.slot(m.data))) |net| {
        sig = self.signals[self.nets[net].signal];
    };
    const d = &self.drivers[at];
    d.s0 = net_mod.reduce(if (sig.lo < 0) @fromBackingInt(@intCast(@as(u8, @intCast(-sig.lo)))) else .highz, m.resistive);
    d.s1 = net_mod.reduce(if (sig.hi > 0) @fromBackingInt(@intCast(@as(u8, @intCast(sig.hi)))) else .highz, m.resistive);
    const value = sig.collapse();
    const on: Int.Bit = if (m.n_type) .one else .zero;
    const out: Int.Bit = if (value == .z or (g != on and (g == .zero or g == .one))) .z else value;
    or_z.* = out != .z and g != on;
    return filled(scratch, 1, false, out);
}

/// What one driver asserts on bit `at`: its value at its strengths, or §7.10.2's
/// H/L when a gate's control is unknown.
pub fn contribution(dr: net_mod.Driver, at: u32) Signal {
    const b = dr.current.bit(at);
    return if (dr.or_z and b != .z) .orZ(b, dr.s0, dr.s1) else .of(b, dr.s0, dr.s1);
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
pub fn schedule(self: *Run, from: Int.Literal, from_or_z: bool, to: Int.Literal, to_or_z: bool, st: *Inertial) Error!bool {
    const settled = if (st.in_flight != null) st.target else from;
    const settled_or_z = if (st.in_flight != null) st.or_z else from_or_z;
    if (std.mem.eql(u64, settled.planes, to.planes) and settled_or_z == to_or_z) return false;
    if (st.in_flight) |h| try exec.cancel(self, h);
    st.in_flight = null;
    if (st.target.planes.len != to.planes.len) st.target.planes = try self.arena.alloc(u64, to.planes.len);
    @memcpy(st.target.planes, to.planes);
    st.target.width = to.width;
    st.target.signed = to.signed;
    st.or_z = to_or_z;
    return true;
}

/// §7.6 a controlled pass switch with a delay: it turns on after the first
/// delay, off after the second, and to unknown conduction after the smaller.
/// A control that returns before its change lands cancels it (§7.14's
/// inertial reading, as a gate's).
pub fn switchAfter(self: *Run, at: u32, next: Tran.State) Error!void {
    const t = &self.trans[at];
    const settled = if (t.pending != null) t.target else t.state;
    if (settled == next) return;
    if (t.pending) |h| try exec.cancel(self, h);
    t.pending = null;
    if (next == t.state) return;
    t.target = next;
    t.pending = try exec.enqueue(self, .{ .tran_switch = at }, t.delay.to(switch (next) {
        .on => .one,
        .off => .zero,
        .unknown => .x,
    }), false);
}

/// §3.8 charge decay. The countdown restarts on each entry into the
/// capacitive state, so this takes the state and acts on its edge.
// ponytail: whole-net, not per-bit: a vector `trireg` with some bits driven
// and some floating decays all of them together; a countdown per bit if a
// design needs it.
fn chargeState(self: *Run, net: u32, floating: bool) Error!void {
    const n = &self.nets[net];
    const was = n.capacitive;
    n.capacitive = floating;
    // Leaving the state, or entering one that never decays, only has to
    // cancel whatever countdown was running.
    if (was == floating) return;
    // A trireg without a cold row has no decay and no countdown to cancel.
    if (n.cold == no_cold) return;
    const c = &self.net_cold.items[n.cold];
    if (c.decay_event) |h| try exec.cancel(self, h);
    c.decay_event = null;
    if (!floating) return;
    const after = c.decay orelse return;
    c.decay_event = try exec.enqueue(self, .{ .decay = net }, after, false);
}

/// What a gate driver contributes: §7.8.5's one output bit, and whether it is
/// §7.10.2's H/L.
pub fn gateValue(self: *Run, scratch: std.mem.Allocator, g: Gate, width: u32, or_z: *bool) Error!Int.Literal {
    // Scratch, which `execute` resets each instruction, so `gateBit` stays a
    // pure function of the input bits, read straight off §7.8.5's tables.
    const bits = try scratch.alloc(Int.Bit, g.ins.len);
    for (g.ins, bits) |in, *b| {
        const v = try evaluate.eval(self, scratch, in, 1);
        b.* = v.bit(if (v.width > 1) g.lane.? else 0);
    }
    const out = try filled(scratch, width, false, .z);
    const o = gateBit(g.kind, bits);
    setBit(out, g.out_bit orelse 0, o.bit);
    or_z.* = o.or_z;
    return out;
}

/// What a UDP driver contributes (IEEE 1364-2005 §8). Its inputs are read with
/// z as x (§8.1.6). A combinational table is simply consulted; a sequential
/// one takes each input that changed since the last evaluation as one event,
/// in terminal order, and its state follows the entries matched (§8.6).
pub fn udpValue(self: *Run, scratch: std.mem.Allocator, u: *net_mod.Udp, width: u32) Error!Int.Literal {
    const bits = try scratch.alloc(Int.Bit, u.ins.len);
    for (u.ins, bits) |in, *b| {
        const w = try evaluate.eval(self, scratch, in, 1);
        const v = w.bit(if (w.width > 1) u.lane orelse 0 else 0);
        b.* = if (v == .z) .x else v;
    }
    const out = if (!u.sequential) net_mod.udpEval(u.rows, false, bits, .x, null, .x) else blk: {
        for (bits, 0..) |b, k| {
            if (b == u.prev[k]) continue;
            const from = u.prev[k];
            u.prev[k] = b;
            u.state = net_mod.udpEval(u.rows, true, u.prev, u.state, @intCast(k), from);
        }
        break :blk u.state;
    };
    const result = try filled(scratch, width, false, .z);
    setBit(result, u.out_bit orelse 0, out);
    return result;
}

/// What a `Bridge` driver contributes: its window, z everywhere else.
pub fn window(self: *Run, scratch: std.mem.Allocator, b: Bridge, width: u32) Error!Int.Literal {
    const out = try filled(scratch, width, false, .z);
    evaluate.copyBits(out, b.dst_lo, self.values[b.src], b.src_lo, b.width);
    return out;
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
        // at t=16 lands at 19 and the fall at t=19 lands at 26: the two delays are
        // chosen by the value transitioned to, not by the direction of the source.
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
        // Released at t=5, so the decay is at t=25, sampled at 24 and 26 and never
        // at it: a sample in the decay's own timestep would pin an intra-timestep
        // order. The countdown restarts from the second release at t=28; one
        // measured from the first release would have fired by t=46.
        \\t24 1 1
        \\t26 x 1
        \\restarted 0 0
        \\late x 0
        \\
    );
}

test "A.2.1.3 a net's own delay applies to its resolved value, rise and fall apart" {
    // `wire #(2,5) w;` plus `assign w = a`: the delay is the net's (with
    // `= a` on the declaration it would be the assignment's, §6.1.3). a rises
    // at 10, so w at 12; a falls at 20, so w at 25. Sampled at 11, 13, 24, 26.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a; wire #(2,5) w; assign w = a;
        \\initial begin
        \\  a = 0; #10 a = 1;
        \\  #1 $write("%b", w); #2 $write("%b", w);
        \\  #7 a = 0; #4 $write("%b", w); #2 $display("%b", w);
        \\end
        \\endmodule
    , "0110\n");
}

test "§7.6 a controlled pass switch with a delay turns on and off after it" {
    // tranif1 #(2,3): on 2 units after its control rises (at 12), off 3
    // after it falls (at 23). Sampled at 11, 13, 22 and 24.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg c; wire a, b;
        \\assign a = 1'b1;
        \\tranif1 #(2,3) t(a, b, c);
        \\initial begin
        \\  c = 0; #10 c = 1;
        \\  #1 $write("%b", b); #2 $write("%b", b);
        \\  #7 c = 0; #2 $write("%b", b); #2 $display("%b", b);
        \\end
        \\endmodule
    , "z11z\n");
}

const bus_source =
    \\`timescale 1ns/1ns
    \\module leaf(input [3:0] i, output [3:0] o); assign o = i; endmodule
    \\module m;
    \\reg [1:0] sel; reg [69:0] d0, d1;
    \\wire [69:0] bus; wire [3:0] w; wire p;
    \\assign bus = sel[0] ? d0 : 70'bz;
    \\assign bus = sel[1] ? d1 : 70'bz;
    \\assign (weak0, weak1) p = d0[0];
    \\assign p = sel[1] ? d1[0] : 1'bz;
    \\leaf u({d0[1:0], d1[1:0]}, w);
    \\initial begin
    \\  d0 = {1'b1, 65'b0, 4'b0101}; d1 = {1'b0, 65'b0, 4'b0011}; sel = 1;
    \\  #1 $display("%b %b %b %b", bus[69], bus[3:0], p, w);
    \\  sel = 3;
    \\  #1 $display("%b %b %b", bus[69], bus[3:0], p);
    \\  force bus[1] = 1'b0; sel = 2;
    \\  #1 $display("%b %b", bus[69], bus[3:0]);
    \\  release bus[1];
    \\  #1 $display("%b %b", bus[69], bus[3:0]);
    \\  sel = 0;
    \\  #1 $display("%b %b %b", bus[69], bus[3:0], p);
    \\end
    \\endmodule
;
const bus_expected = "1 0101 1 0111\nx 0xx1 1\n0 0001\n0 0011\nz zzzz 1\n";

test "§7.9 a bus of tri-state drivers resolves across a word boundary, under a forced select and beside a weaker driver" {
    try expectRun(bus_source, bus_expected);
}

fn runBus(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bag = @import("diag").Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try @import("root.zig").run(arena.allocator(), bus_source, .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings(bus_expected, output.written());
}

test "allocation failure anywhere in net resolution, a port window or a forced select cleans up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runBus, .{});
}
