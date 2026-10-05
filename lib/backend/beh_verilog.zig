//! Proven MIR in, a behavioural IEEE 1364-2005 module out (`vera
//! --emit-verilog`): the digital stand-in a gate-level or RTL simulation
//! uses for an analog macro, derived from the same `.va` the analog side is
//! verified against. Same module name, same port order.
//!
//! The abstraction. Every net the model drives (one with a contribution) is
//! one bit: high when its potential is above VDD/2. For every assignment of
//! the input pins and node bits, each pin or node at 0 or VDD, the analog
//! block is run once (an interpreter over the MIR whose arithmetic is
//! `opcode.fold`, the compiler's own constant kernel). A node's §5.6 KCL
//! residual S and §5.6.1.2 charge Q, read with its own potential at 0 and at
//! VDD, give the potential it settles to, F = -S(0)·VDD/(S(VDD)-S(0)), and
//! its time constant, tau = ΔQ/ΔS: exact for an RC, a secant for anything
//! else. The node's next value is F > VDD/2, reached tau·ln2 later (the 50 %
//! crossing of a rail-to-rail RC step) plus the `td` of every §4.5.8
//! `transition` / §4.5.7 `absdelay` the residual read through. A §5.6
//! `V(n) <+ F` contribution sets F directly.
//!
//! Each node becomes a truth table over the bits it depends on and a
//! `assign #(rise, fall)` (inertial, §6.1.3), so a pulse shorter than the
//! node's delay is swallowed as an RC would. An input that is x or z selects
//! no row and drives x.
//!
//! Pins (§2.9 attributes on a port declaration, `--digital-pins` wins):
//!   `(* vera_pin = "digital" *)`  logic: `input` if the model never drives it,
//!                                 else `output`
//!   `(* vera_pin = "analog" *)`   undriven `inout wire`; read as its logic level
//!   `(* vera_pin = "power" *)`    supply, VDD;  `(* vera_pin = "ground" *)`, 0 V
//! Undecorated: `vdd*`/`vcc*`/`vpwr`/`vpb`/`avdd`/`dvdd` are power,
//! `vss*`/`gnd*`/`vgnd`/`vnb`/`vee*`/`avss`/`dvss` ground, the rest analog.
//! `(* vera_delay = <seconds> *)` on a net's declaration replaces its derived
//! delay (both edges). On a port, both go on the direction declaration
//! (`inout`): a port's discipline declaration carries no attribute to it. `--power-pins` moves the supply pins under
//! `` `ifdef USE_POWER_PINS ``.
//!
//! Refused with a message, never emitted half-right: §5.10 events and held
//! variables, `I()` probes and `ddt`/`idt` outside a contribution (their
//! unknowns are not nets), arrays, vector ports, `$abstime` and any call with
//! no static value, and more than `max_vars` pins plus nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const constfold = @import("frontend").constfold;
const Const = constfold.Const;

/// What `emit` reads besides the model.
pub const Options = struct {
    /// `--digital-pins`: port names that are logic, whatever their attributes say.
    digital: []const []const u8 = &.{},
    /// `--power-pins`: declare the supply pins only under `ifdef USE_POWER_PINS`.
    power_pins: bool = false,
    /// The logic-high potential (V) a pin or node is evaluated at.
    vdd: f64 = 1.8,
    /// The `.va` path, for the header comment.
    source: []const u8 = "",
};

pub const Error = error{ OutOfMemory, Refused };

/// The largest pins-plus-nodes count the truth tables enumerate (2^n runs).
pub const max_vars = 20;

const Pin = enum { digital, analog, power, ground };

/// A node's settled logic value; `x` when it settles at exactly VDD/2.
const Bit = enum { @"0", @"1", x };

/// Returns the module text, or `error.Refused` with `why.*` set to the reason.
/// Everything is allocated in `arena`.
pub fn emit(arena: Allocator, mir: *const Mir, lw: *const Lowered, o: Options, why: *[]const u8) Error![]const u8 {
    var e: Emitter = .{ .arena = arena, .mir = mir, .lw = lw, .o = o, .why = why };
    return e.run();
}

const Emitter = struct {
    arena: Allocator,
    mir: *const Mir,
    lw: *const Lowered,
    o: Options,
    why: *[]const u8,
    /// Each port's kind, set once `run` has classified them.
    pins: []const Pin = &.{},
    /// Which `nodes` rows a contribution drives.
    driven: []const bool = &.{},

    fn refuse(self: *Emitter, comptime fmt: []const u8, args: anytype) Error {
        self.why.* = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.Refused;
    }

    fn run(self: *Emitter) Error![]const u8 {
        const lw = self.lw;
        const n_nodes = lw.nodes.len;
        const names = lw.nodes.items(.name);
        const kinds = lw.nodes.items(.kind);

        if (lw.held_vars.items.len != 0) return self.refuse("`{s}` holds state across evaluations (§5.10 event or held variable); --emit-verilog abstracts only continuous models", .{lw.held_vars.items[0].name});
        if (lw.vectors.count() != 0) return self.refuse("vector nets are not supported; declare the bits as scalar ports", .{});
        if (lw.num_ports == 0) return self.refuse("module `{s}` has no ports", .{self.mir.name});

        // Attributes on declarations, by declared name.
        var pin_attr: std.StringHashMapUnmanaged([]const u8) = .empty;
        var delay_attr: std.StringHashMapUnmanaged(f64) = .empty;
        for (lw.file.attributes.items) |b| {
            if (b.owner.kind != .declaration) continue;
            const span = lw.tokenSpan(b.owner.tok);
            const decl = lw.src[span.start..span.end];
            for (b.specs) |s| {
                const an = lw.file.str(s.name);
                const v: ?Const = if (s.value == .none) .{ .int = 1 } else constfold.fold(lw.file, s.value, constfold.literal_env);
                if (std.mem.eql(u8, an, "vera_pin")) {
                    if (v == null or v.? != .str) return self.refuse("`{s}`: vera_pin takes \"digital\", \"analog\", \"power\" or \"ground\"", .{decl});
                    try pin_attr.put(self.arena, decl, v.?.str);
                } else if (std.mem.eql(u8, an, "vera_delay")) {
                    const d = if (v) |c| c.asReal() else -1;
                    if (v == null or v.? == .str or !(d >= 0) or !std.math.isFinite(d)) return self.refuse("`{s}`: vera_delay takes a constant delay in seconds, >= 0", .{decl});
                    try delay_attr.put(self.arena, decl, d);
                }
            }
        }

        // Pin kinds, ports only.
        const pins = try self.arena.alloc(Pin, lw.num_ports);
        for (self.o.digital) |d| {
            for (names[0..lw.num_ports]) |n| {
                if (std.mem.eql(u8, n, d)) break;
            } else return self.refuse("--digital-pins: `{s}` is not a port of `{s}`", .{ d, self.mir.name });
        }
        for (pins, names[0..lw.num_ports]) |*p, n| {
            p.* = for (self.o.digital) |d| {
                if (std.mem.eql(u8, n, d)) break .digital;
            } else if (pin_attr.get(n)) |a|
                std.meta.stringToEnum(Pin, a) orelse return self.refuse("`{s}`: vera_pin = \"{s}\" is not digital, analog, power or ground", .{ n, a })
            else
                guessSupply(n) orelse .analog;
        }
        self.pins = pins;

        // Which rows a contribution drives, and the rail each supply sits at.
        const driven = try self.arena.alloc(bool, n_nodes);
        @memset(driven, false);
        const potential = try self.arena.alloc(?u32, n_nodes); // the `V(n) <+` contribution
        @memset(potential, null);
        for (lw.contributions.items, 0..) |c, ci| {
            if (c.kind != .direct) return self.refuse("§5.6.7 indirect branch assignments are not supported", .{});
            for ([_]u16{ c.hi, c.lo }) |r| {
                if (r == Lowered.ground) continue;
                if (kinds[r] != .net) return self.refuse("`{s}` is not a net (an I() probe, or ddt/idt outside a contribution)", .{names[r]});
            }
            if (c.access == .potential) {
                if (c.hi == Lowered.ground or self.isSupply(pins, c.hi)) continue;
                if (c.lo != Lowered.ground and !self.isSupply(pins, c.lo)) return self.refuse("`V({s}, {s}) <+`: a potential contribution must be referred to a supply or ground", .{ names[c.hi], names[c.lo] });
                potential[c.hi] = @intCast(ci);
                driven[c.hi] = true;
            } else for ([_]u16{ c.hi, c.lo }) |r| {
                if (r != Lowered.ground and !self.isSupply(pins, r)) driven[r] = true;
            }
        }

        self.driven = driven;

        // The variables: undriven signal ports (inputs), then driven nets (states).
        var vars: std.ArrayList(u16) = .empty;
        for (0..lw.num_ports) |r| if (!driven[r] and !self.isSupply(pins, @intCast(r))) try vars.append(self.arena, @intCast(r));
        const n_inputs = vars.items.len;
        for (0..n_nodes) |r| if (driven[r]) try vars.append(self.arena, @intCast(r));
        const nv = vars.items.len;
        if (nv > max_vars) return self.refuse("{d} pins and driven nodes; the truth tables stop at {d}", .{ nv, max_vars });
        const states = vars.items[n_inputs..];

        // One analog evaluation per assignment: each state's residual, charge,
        // transition delay and, for a potential-driven node, its target.
        const n_masks = @as(usize, 1) << @intCast(nv);
        const S = try self.arena.alloc(f64, n_masks * states.len);
        const Q = try self.arena.alloc(f64, n_masks * states.len);
        const TD = try self.arena.alloc(f64, n_masks * states.len);
        const volts = try self.arena.alloc(f64, n_nodes);
        var in: Interp = .{ .e = self, .volts = volts, .env = try self.arena.alloc(?Val, Mir.Value.first_dynamic + self.mir.defs.len) };
        for (0..n_masks) |m| {
            for (0..n_nodes) |r| volts[r] = if (r < lw.num_ports) switch (pins[r]) {
                .power => self.o.vdd,
                .ground => 0,
                .digital, .analog => std.math.nan(f64),
            } else std.math.nan(f64);
            for (vars.items, 0..) |r, k| volts[r] = if (m >> @intCast(k) & 1 == 1) self.o.vdd else 0;
            try in.run();
            for (states, 0..) |r, si| {
                var s: f64 = 0;
                var q: f64 = 0;
                var td: f64 = 0;
                if (potential[r]) |ci| {
                    const c = lw.contributions.items[ci];
                    const f = try in.get(c.resist_val);
                    s = f.c.asReal() + if (c.lo == Lowered.ground) 0 else volts[c.lo];
                    td = f.d;
                } else for (lw.contributions.items) |c| {
                    if (c.access != .flow or (c.hi != r and c.lo != r)) continue;
                    const sign: f64 = if (c.hi == r) 1 else -1;
                    const rv = try in.get(c.resist_val);
                    const qv = try in.get(c.react_val);
                    s += sign * rv.c.asReal();
                    q += sign * qv.c.asReal();
                    td = @max(td, @max(rv.d, qv.d));
                }
                S[m * states.len + si] = s;
                Q[m * states.len + si] = q;
                TD[m * states.len + si] = td;
            }
        }

        // Per node: the target bit for each assignment, the rise/fall delays
        // and the variables the target depends on.
        const targets = try self.arena.alloc([]Bit, states.len);
        const rises = try self.arena.alloc(f64, states.len);
        const falls = try self.arena.alloc(f64, states.len);
        const supports = try self.arena.alloc([]const usize, states.len);
        const ln2 = @log(2.0);
        for (states, 0..) |r, si| {
            const bit = @as(usize, 1) << @intCast(n_inputs + si);
            const target = try self.arena.alloc(Bit, n_masks);
            var rise: f64 = 0;
            var fall: f64 = 0;
            for (0..n_masks) |m| {
                const at = struct {
                    fn f(a: []const f64, mm: usize, n: usize, i: usize) f64 {
                        return a[mm * n + i];
                    }
                }.f;
                var f: f64 = undefined;
                var tau: f64 = 0;
                if (potential[r] != null) {
                    f = at(S, m, states.len, si);
                } else {
                    const s0 = at(S, m & ~bit, states.len, si);
                    const s1 = at(S, m | bit, states.len, si);
                    const a = (s1 - s0) / self.o.vdd;
                    if (!(a != 0) or !std.math.isFinite(a)) return self.refuse("node `{s}`: its current does not depend on its own potential, so it settles nowhere", .{names[r]});
                    f = -s0 / a;
                    tau = @abs((at(Q, m | bit, states.len, si) - at(Q, m & ~bit, states.len, si)) / self.o.vdd / a);
                }
                if (!std.math.isFinite(f)) return self.refuse("node `{s}`: its settled potential is not finite", .{names[r]});
                // Settling at VDD/2 (a comparator with equal inputs) is no logic level.
                target[m] = if (@abs(f - self.o.vdd / 2) <= 1e-9 * self.o.vdd) .x else if (f > self.o.vdd / 2) .@"1" else .@"0";
                const d = tau * ln2 + at(TD, m, states.len, si);
                switch (target[m]) {
                    .@"1" => rise = @max(rise, d),
                    .@"0" => fall = @max(fall, d),
                    .x => {},
                }
            }
            if (delay_attr.get(names[r])) |d| {
                rise = d;
                fall = d;
            }
            var support: std.ArrayList(usize) = .empty;
            for (0..nv) |k| {
                const b = @as(usize, 1) << @intCast(k);
                for (0..n_masks) |m| if (target[m] != target[m ^ b]) {
                    try support.append(self.arena, k);
                    break;
                };
            }
            targets[si] = target;
            rises[si] = rise;
            falls[si] = fall;
            supports[si] = support.items;
        }

        // Only what reaches a digital output is emitted: a driven analog
        // port or an internal net nothing logic reads is dead.
        const live = try self.arena.alloc(bool, states.len);
        for (live, states) |*l, r| l.* = r < lw.num_ports and pins[r] == .digital;
        var grew = true;
        while (grew) {
            grew = false;
            for (states, 0..) |_, si| if (live[si]) for (supports[si]) |k| if (k >= n_inputs and !live[k - n_inputs]) {
                live[k - n_inputs] = true;
                grew = true;
            };
        }
        var out: std.ArrayList(u8) = .empty;
        var body: std.ArrayList(u8) = .empty;
        for (states, 0..) |r, si| if (live[si])
            try self.node(&body, vars.items, targets[si], supports[si], r, rises[si], falls[si]);

        // Header and ports.
        const w = &out;
        const A = self.arena;
        try w.print(A, "// GENERATED BY VerA --emit-verilog from {s} - DO NOT EDIT.\n", .{self.o.source});
        try w.print(A,
            \\// Behavioural model of `{s}` for digital simulation: a driven net is high
            \\// above VDD/2 = {d} V; its switching delay is the model's own RC (tau*ln2) plus
            \\// any transition()/absdelay() td, or its (* vera_delay *). Analog pins are
            \\// undriven and read as their logic level.
            \\`timescale 1ns/1ps
            \\module {s} (
            \\
        , .{ self.mir.name, self.o.vdd / 2, self.mir.name });
        const first_signal = for (pins, 0..) |p, i| {
            if (!self.hidden(p)) break i;
        } else return self.refuse("every port is a supply; nothing to model", .{});
        var in_ifdef = false;
        for (pins, names[0..lw.num_ports], 0..) |p, n, i| {
            const h = self.hidden(p);
            if (h != in_ifdef) {
                try w.appendSlice(A, if (h) "`ifdef USE_POWER_PINS\n" else "`endif\n");
                in_ifdef = h;
            }
            if (i < first_signal) {
                try w.print(A, "    {f},\n", .{ident(n)});
            } else try w.print(A, "    {s}{f}\n", .{ if (i == first_signal) "  " else ", ", ident(n) });
        }
        if (in_ifdef) try w.appendSlice(A, "`endif\n");
        try w.appendSlice(A, ");\n");

        in_ifdef = false;
        for (pins, names[0..lw.num_ports], 0..) |p, n, i| {
            const h = self.hidden(p);
            if (h != in_ifdef) {
                try w.appendSlice(A, if (h) "`ifdef USE_POWER_PINS\n" else "`endif\n");
                in_ifdef = h;
            }
            const dw: [2][]const u8 = switch (p) {
                .digital => if (driven[i]) .{ "output", "digital" } else .{ "input ", "digital" },
                .analog => .{ "inout ", "analog, undriven" },
                .power => .{ "inout ", "power" },
                .ground => .{ "inout ", "ground" },
            };
            try w.print(A, "    {s} wire {f}; // {s}\n", .{ dw[0], ident(n), dw[1] });
        }
        if (in_ifdef) try w.appendSlice(A, "`endif\n");

        // Internal nets: every driven row that is not a digital port.
        for (states, live) |r, l| if (l and !(r < lw.num_ports and pins[r] == .digital))
            try w.print(A, "    wire {f}; // {s}\n", .{ self.net(pins, r), names[r] });
        try w.appendSlice(A, body.items);
        try w.appendSlice(A, "endmodule\n");
        return out.items;
    }

    fn isSupply(self: *const Emitter, pins: []const Pin, r: u16) bool {
        return r < self.lw.num_ports and (pins[r] == .power or pins[r] == .ground);
    }

    fn hidden(self: *const Emitter, p: Pin) bool {
        return self.o.power_pins and (p == .power or p == .ground);
    }

    /// The Verilog net that carries row `r`'s bit: a digital or an undriven
    /// port itself, else an internal `vera_n_*` (a driven analog port stays
    /// undriven outside).
    fn net(self: *const Emitter, pins: []const Pin, r: u16) Name {
        const n = self.lw.nodes.items(.name)[r];
        if (r < self.lw.num_ports and (pins[r] == .digital or !self.driven[r])) return ident(n);
        return .{ .prefix = "vera_n_", .text = n };
    }

    /// Emits row `r`'s target table and its delayed assignment.
    fn node(self: *Emitter, w: *std.ArrayList(u8), vars: []const u16, target: []const Bit, support: []const usize, r: u16, rise: f64, fall: f64) Error!void {
        const A = self.arena;
        const lw = self.lw;
        const name = lw.nodes.items(.name)[r];
        const pins = self.pins;
        const t: Name = .{ .prefix = "vera_t_", .text = name };
        const sane: Name = .{ .prefix = "", .text = name };
        try w.print(A, "\n    // {s}\n", .{name});
        try w.print(A, "    parameter real vera_rise_{f} = {d:.6}; // ns\n", .{ sane, rise * 1e9 });
        try w.print(A, "    parameter real vera_fall_{f} = {d:.6}; // ns\n", .{ sane, fall * 1e9 });
        if (support.len == 0) {
            try w.print(A, "    wire {f} = 1'b{t};\n", .{ t, target[0] });
        } else {
            try w.print(A, "    reg {f};\n    always @* begin\n        case ({{", .{t});
            var k = support.len;
            while (k > 0) {
                k -= 1;
                try w.print(A, "{f}{s}", .{ self.net(pins, vars[support[k]]), if (k == 0) "" else ", " });
            }
            try w.appendSlice(A, "})\n");
            for (0..@as(usize, 1) << @intCast(support.len)) |sub| {
                var m: usize = 0;
                for (support, 0..) |v, j| if (sub >> @intCast(j) & 1 == 1) {
                    m |= @as(usize, 1) << @intCast(v);
                };
                try w.print(A, "            {d}'b", .{support.len});
                var j = support.len;
                while (j > 0) {
                    j -= 1;
                    try w.append(A, if (sub >> @intCast(j) & 1 == 1) '1' else '0');
                }
                try w.print(A, ": {f} = 1'b{t};\n", .{ t, target[m] });
            }
            try w.print(A, "            default: {f} = 1'bx;\n        endcase\n    end\n", .{t});
        }
        try w.print(A, "    assign #(vera_rise_{f}, vera_fall_{f}) {f} = {f};\n", .{ sane, sane, self.net(pins, r), t });
    }
};

/// A Verilog name: `prefix` then `text` with every non-identifier byte made
/// `_`, or (no prefix) `text` itself, escaped (§3.7.1) when it is not a
/// simple identifier.
const Name = struct {
    prefix: ?[]const u8 = null,
    text: []const u8,

    pub fn format(n: Name, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (n.prefix) |p| {
            try w.writeAll(p);
            for (n.text) |c| try w.writeByte(if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
            return;
        }
        const simple = n.text.len != 0 and !std.ascii.isDigit(n.text[0]) and n.text[0] != '$' and
            for (n.text) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) break false;
            } else true;
        if (simple) return w.writeAll(n.text);
        try w.print("\\{s} ", .{n.text});
    }
};

fn ident(text: []const u8) Name {
    return .{ .text = text };
}

/// The supply a port's name conventionally is, or null.
fn guessSupply(name: []const u8) ?Pin {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    const n = std.ascii.lowerString(&buf, name);
    for ([_][]const u8{ "vdd", "vcc", "vpwr", "vpb", "avdd", "dvdd" }) |p| if (std.mem.startsWith(u8, n, p)) return .power;
    for ([_][]const u8{ "vss", "gnd", "vgnd", "vnb", "vee", "avss", "dvss" }) |p| if (std.mem.startsWith(u8, n, p)) return .ground;
    return null;
}

/// A MIR value under one assignment: the number, and the longest
/// `transition`/`absdelay` delay (s) on any path into it.
const Val = struct { c: Const, d: f64 = 0 };

/// Runs the analog block once over `volts` (one potential per `nodes` row).
const Interp = struct {
    e: *Emitter,
    volts: []const f64,
    env: []?Val,

    fn run(self: *Interp) Error!void {
        const mir = self.e.mir;
        @memset(self.env, null);
        var block: Mir.Block = .entry;
        var prev: ?Mir.Block = null;
        var steps: usize = 0;
        blocks: while (true) {
            steps += 1;
            if (steps > 1 << 20) return self.e.refuse("the analog block did not finish (a loop over a node potential?)", .{});
            // Phis read the edge just taken, all at once (they are parallel).
            var it = mir.blockInsts(block);
            while (it.next()) |inst| {
                const res = mir.instResult(inst);
                const v: Val = switch (mir.instData(inst)) {
                    // §5.6.1.2 `A*ddt(B)` is charged as path_acc + A·(B - path_prev(B)):
                    // with both latches at 0 the charge is A·B, whose secant is A·ΔB.
                    .unary => |u| if (u.op == .path_prev or u.op == .path_acc) .{ .c = .{ .real = 0 } } else try self.op(u.op, &.{u.operand}),
                    .binary => |b| try self.op(b.op, &.{ b.lhs, b.rhs }),
                    .ternary => |t| try self.get(if ((try self.get(t.cond)).c.isTrue()) t.then_val else t.else_val),
                    .phi => |p| blk: {
                        for (0..p.count) |i| {
                            const pair = mir.phiPair(inst, @intCast(i));
                            if (prev != null and pair.block == prev.?) break :blk try self.get(pair.value);
                        }
                        return self.e.refuse("a phi with no operand for the edge taken", .{});
                    },
                    .branch => |b| {
                        prev = block;
                        block = if ((try self.get(b.cond)).c.isTrue()) b.then_block else b.else_block;
                        continue :blocks;
                    },
                    .jump => |j| {
                        prev = block;
                        block = j.target;
                        continue :blocks;
                    },
                    .call => |c| try self.call(c.callee, c.name, c.args),
                    .anew, .load, .store => return self.e.refuse("§3.2.2 runtime-indexed arrays are not supported", .{}),
                };
                if (res != .undef) self.env[@backingInt(res)] = v;
            }
            return;
        }
    }

    fn get(self: *Interp, value: Mir.Value) Error!Val {
        const mir = self.e.mir;
        const v = mir.resolveAlias(value);
        return switch (mir.valueDef(v)) {
            .float_const => |x| .{ .c = .{ .real = x } },
            .int_const => |x| .{ .c = .{ .int = x } },
            .str_const => |s| .{ .c = .{ .str = s } },
            .param_ref => |p| blk: {
                const info = self.e.lw.params.items[p];
                if (info.folded) |c| break :blk .{ .c = c };
                break :blk self.get(info.default);
            },
            .block_param => |u| blk: {
                const x = self.volts[u];
                if (std.math.isNan(x)) return self.e.refuse("`{s}` is read but is neither a pin nor a driven net", .{self.e.lw.nodes.items(.name)[u]});
                break :blk .{ .c = .{ .real = x } };
            },
            .inst_result => self.env[@backingInt(v)] orelse self.e.refuse("a value read before its block ran", .{}),
            .undef => self.e.refuse("an undefined value", .{}),
        };
    }

    fn op(self: *Interp, o: Mir.Opcode, operands: []const Mir.Value) Error!Val {
        var cs: [2]Const = undefined;
        var d: f64 = 0;
        for (operands, 0..) |x, i| {
            const v = try self.get(x);
            cs[i] = v.c;
            d = @max(d, v.d);
        }
        const c = Mir.opcode.fold(o, cs[0..operands.len]) orelse
            return self.e.refuse("`{s}` has no value here", .{Mir.opcode.label(o)});
        return .{ .c = c, .d = d };
    }

    fn call(self: *Interp, callee: Mir.Callee, name: []const u8, args: []const Mir.Value) Error!Val {
        return switch (callee) {
            // §4.5.8/§4.5.7: the settled value, `td` later.
            .transition, .absdelay, .@"absdelay$quad" => blk: {
                const x = try self.get(args[0]);
                const td = if (args.len > 1) (try self.get(args[1])).c.asReal() else 0;
                break :blk .{ .c = x.c, .d = x.d + @max(td, 0) };
            },
            // §4.5.9: the settled value; a slew's time depends on the swing.
            .slew => self.get(args[0]),
            .limexp => blk: {
                const x = try self.get(args[0]);
                break :blk .{ .c = .{ .real = @exp(x.c.asReal()) }, .d = x.d };
            },
            // A transient's point, not its DC solve.
            .@"op$static" => .{ .c = .{ .int = 0 } },
            .@"$mfactor" => .{ .c = .{ .real = 1 } },
            .@"$temperature" => .{ .c = .{ .real = 300.15 } },
            .@"$vt" => blk: {
                const t = if (args.len > 0) (try self.get(args[0])).c.asReal() else 300.15;
                break :blk .{ .c = .{ .real = 1.380649e-23 * t / 1.602176634e-19 } };
            },
            // Every other callee is time-dependent, an event, a noise or host
            // query, or a task: none has one static value per assignment.
            else => self.e.refuse("`{s}` has no static value; --emit-verilog cannot abstract it", .{name}), // else: a new callee is refused until it is given a static value here
        };
    }
};
