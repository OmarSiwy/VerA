//! §7.9 net resolution data, with no engine state.
//!
//! In: driver bits, their A.2.2.2 strengths and the net's type. Out: one
//! resolved four-state bit, a delay in scheduler ticks, or a gate output bit.
//!
//! Clauses: IEEE 1364-2005 clause 7's strength pair and §7.9 Tables
//! 7-4/7-6/7-7 wired logic, §7.10; §7.8.5 gate tables for A.3.1/A.3.4 gate
//! instances; §3.7 undriven values and §3.8 `trireg` charge; A.2.2.3 `delay3`
//! chosen per IEEE 1364-2005 §7.14, and §6.1.3's vector and inertial rules.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const Error = @import("root.zig").Error;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;

// ---- delays (A.2.2.3, §7.14, §6.1.3) ----------------------------------------

/// IEEE 1364-2005 §6.1.3: a delayed continuous assignment is INERTIAL — "if
/// the value changes before the delay has elapsed, the scheduled event is
/// cancelled". So a driver or a net has at most ONE transition in flight, and
/// cancelling it is the scheduler's own `cancel` on the handle kept here.
pub const Inertial = struct {
    /// The event in flight, or null when none is. Cleared when it dispatches.
    in_flight: ?Handle = null,
    /// What the event in flight will publish, meaningful only while
    /// `in_flight` is set. Compared against rather than the published value, so
    /// that a re-evaluation landing on the value already on its way leaves the
    /// timer alone instead of restarting it. Its planes are sized once and
    /// then reused, so a toggling input costs no memory per transition.
    target: Int.Literal = .{ .width = 0, .sized = true, .signed = false, .planes = &.{} },
    /// `target`'s §7.10.2 H/L flag, for a gate driver (see `Driver.or_z`).
    or_z: bool = false,
};

/// A.2.2.3's three values, already in scheduler ticks. `present` is false for
/// every construct that names no delay, and that is the path the engine took
/// before delays existed — an immediate store.
pub const Delay = struct {
    rise: u64 = 0,
    fall: u64 = 0,
    off: u64 = 0,
    present: bool = false,

    /// IEEE 1364-2005 §7.14: the delay is chosen by the value being
    /// transitioned TO, and a transition to x takes the SMALLEST of the three —
    /// x is "the value is somewhere in here", and it is true from the first
    /// moment any of the three transitions could have begun.
    ///
    /// This selector is scalar. Net-delay vector handling remains separate
    /// from §6.1.3's whole-vector continuous-assignment rule below.
    pub fn to(self: Delay, b: Int.Bit) u64 {
        return switch (b) {
            .one => self.rise,
            .zero => self.fall,
            .z => self.off,
            .x => @min(self.rise, @min(self.fall, self.off)),
        };
    }

    /// IEEE 1364-2005 §6.1.3: vector assignments use falling delay for
    /// nonzero-to-zero, turn-off for all-z, and rising for every other case.
    /// Unlike scalar gates, mixed x/z values do not select a minimum delay.
    /// The caller supplies the published driver value, not a pending target.
    pub fn continuous(self: Delay, from: Int.Literal, value: Int.Literal) u64 {
        if (value.width == 1) return self.to(value.bit(0));
        var all_z = true;
        for (0..value.width) |bit| {
            if (value.bit(@intCast(bit)) != .z) {
                all_z = false;
                break;
            }
        }
        if (all_z) return self.off;
        if (from.truth() == .one and value.truth() == .zero) return self.fall;
        return self.rise;
    }
};

// ---- nets, drivers and gates (§7.9, §6.1, §7.8.5, A.3.1) --------------------

/// §6.5.7.1's "vector port ... connected to a ... concatenated net expression
/// of the matching width", the half of a port connection that cannot be a net
/// collapse: `width` bits starting at `src_lo` of one slot are carried onto
/// `dst_lo` of another net. Everything outside that window is z, which is the
/// identity of §7.9's resolution, so a window is an ordinary driver that
/// happens to assert only part of the net.
pub const Bridge = struct { src: u32, src_lo: u32, dst_lo: u32, width: u32 };

// §7.9 one net: its resolution function, its storage, and the drivers whose
// wired-logic combination IS its value. `resolved` is the scratch the fold
// writes before publishing through `store`; it is sized once, at setup.
pub const Net = struct {
    kind: Ast.NetKind,
    slot: u32,
    resolved: Int.Literal,
    /// The declaring token, for a verdict reached after elaboration (§7.9's
    /// `uwire` driver count is the only one so far).
    tok: u32 = 0,
    drivers: []const u32 = &.{},
    /// A.2.1.3 `charge_strength`, the level the stored charge of a `trireg` in
    /// the capacitive state asserts. `medium` is §3.8's default and is ignored
    /// outright by every other net type.
    charge: Ast.Strength = .medium,
    /// A.2.1.3 `[ delay3 ]` on the declaration, applied to the RESOLVED value.
    delay: Delay = .{},
    transition: Inertial = .{},
    /// A.2.1.3's third `delay3` value on a `trireg`: how long the capacitive
    /// state may last before the charge is worth nothing. `null` — which is
    /// what a `trireg` with no `delay3` gets — is IEEE 1364-2005 §3.8's
    /// indefinite hold.
    decay: ?u64 = null,
    /// Whether the last resolution found no driver asserting anything, which is
    /// §3.8's capacitive state. The decay countdown restarts on each ENTRY into
    /// it, so the transition is what is watched, not the state.
    capacitive: bool = false,
    /// The §3.8 decay countdown in flight, cancelled on leaving the state.
    decay_event: ?Handle = null,
    /// Per bit, the §7.10 signal the last resolution found — its strength is
    /// what a MOS switch reading this net passes on (§7.12).
    signal: []Signal = &.{},
    /// The §7.6 pass switches with this net as a terminal.
    trans: []const u32 = &.{},
};

/// §7.6 one MOS switch (half of a CMOS one, §7.7): it passes `data` — value
/// and strength — to its output while `gate` holds the conducting value (1
/// for an n-type, 0 for a p-type), and is off otherwise.
pub const Mos = struct { data: Ast.ExprId, gate: Ast.ExprId, n_type: bool, resistive: bool };

/// §7.6 one pass switch between bit `a_bit` of net `a` and bit `b_bit` of
/// net `b` ("scalar nets or bit-selects of vector nets"): always on (`tran`),
/// or on while `ctrl` equals `on` (`tranif1`: 1, `tranif0`: 0) and of
/// unknown conduction while it is x or z. A resistive one reduces what it
/// passes by §7.12. `delay` is the turn-on (`rise`) and turn-off (`fall`)
/// delay of a controlled one; `target` is the state in flight.
pub const Tran = struct {
    a: u32,
    b: u32,
    a_bit: u32 = 0,
    b_bit: u32 = 0,
    ctrl: Ast.ExprId = .none,
    on: Int.Bit = .one,
    state: State = .on,
    resistive: bool = false,
    delay: Delay = .{},
    target: State = .on,
    pending: ?Handle = null,

    pub const State = enum { on, off, unknown };
};

/// §7.11/§7.12 a signal that crossed `hops` pass switches, `resistive` of
/// them resistive: supply becomes strong at the first switch, and each
/// resistive one reduces by Table 7-8.
pub fn reduceSignal(sig: Signal, hops: u32, resistive: u32) Signal {
    if (hops == 0) return sig;
    const one = struct {
        fn side(v: i8, k: u32) i8 {
            var s = reduce(@enumFromInt(@abs(v)), false);
            for (0..k) |_| s = reduce(s, true);
            const m: i8 = @intCast(@intFromEnum(s));
            return if (v < 0) -m else m;
        }
    };
    return .{ .lo = one.side(sig.lo, resistive), .hi = one.side(sig.hi, resistive) };
}

/// IEEE 1364-2005 §7.12 Table 7-8: what a resistive switch makes of the
/// strength it passes; a non-resistive one only turns supply into strong.
pub fn reduce(s: Ast.Strength, resistive: bool) Ast.Strength {
    if (!resistive) return if (s == .supply) .strong else s;
    return switch (s) {
        .supply, .strong => .pull,
        .pull => .weak,
        .large, .weak => .medium,
        .medium, .small => .small,
        .highz => .highz,
    };
}

/// One gate evaluation: §7.8.5's output bit, and whether it is §7.10.2's H/L
/// — `bit` or high impedance — rather than `bit` itself.
pub const GateOut = struct { bit: Int.Bit, or_z: bool = false };

/// A window of a wider value: bits [lo, lo + the receiver's width) of it read
/// `total` bits wide.
pub const Slice = struct { lo: u32, total: u32 };

/// One A.3.1 gate instance, reduced to what §7.8.5 needs to compute its output:
/// the type and the input terminals in source order.
///
/// One member of a §7.1.5 instance array is lane `lane` of `lanes`: an input
/// as wide as the array gives it its bit `lane` (§7.1.6), a scalar one is
/// broadcast, and it drives bit `out_bit` of a vector output net.
pub const Gate = struct { kind: Ast.GateKind, ins: []const Ast.ExprId, lane: ?u32 = null, lanes: u32 = 1, out_bit: ?u32 = null };

/// §7.8.5: "a gate transmits a logic value, not a connection" — every primitive
/// but the MOS switches reads a z input as x. This is the one place the gate
/// tables part company with the expression operators.
fn gateIn(b: Int.Bit) Int.Bit {
    return if (b == .z) .x else b;
}

/// §7.8.5's tables for A.3.4's twelve computing gate types, one output bit.
///
/// The n-input arms are written as controlling-value rules rather than as 4x4
/// tables because that is what the tables ARE: `and(0, x)` is 0 because the 0
/// controls, while `xor(0, x)` is x because xor has no controlling value. An
/// implementation that folds "unknown in, unknown out" uniformly gets the and
/// and or rows wrong and nothing else.
pub fn gateBit(kind: Ast.GateKind, ins: []const Int.Bit) GateOut {
    switch (kind) {
        // A.3.1 `( output_terminal , input_terminal , enable_terminal )`. Three
        // regimes: the OFF enable gives z whatever the data is; the ON enable
        // gives the gate function of the data; an x/z enable means the gate may
        // or may not be conducting, which IEEE 1364 writes as L (0-or-z) or H
        // (1-or-z). Neither is a member of {0,1,x,z} — L is not 0, because it
        // might be z — so the value alone projects to x, and the flag is what
        // lets §7.10.3 resolve it against another driver (Figure 7-6).
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
            const on: Int.Bit = if (kind == .g_bufif1 or kind == .g_notif1) .one else .zero;
            const enable = ins[1];
            const data = if (kind == .g_bufif0 or kind == .g_bufif1) gateIn(ins[0]) else invert(ins[0]);
            if (enable == .x or enable == .z) return .{ .bit = data, .or_z = data != .x };
            if (enable != on) return .{ .bit = .z };
            return .{ .bit = data };
        },
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => return .{ .bit = logicBit(kind, ins) },
    }
}

/// ~x is x and ~z is x: the complement of "unknown" is unknown.
fn invert(b: Int.Bit) Int.Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

fn logicBit(kind: Ast.GateKind, ins: []const Int.Bit) Int.Bit {
    switch (kind) {
        .g_and, .g_nand, .g_or, .g_nor => {
            // The value that decides the output on its own, and the output it
            // decides — `and` is controlled by 0 and produces 0.
            const control: Int.Bit = if (kind == .g_and or kind == .g_nand) .zero else .one;
            var unknown = false;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == control) return if (kind == .g_and or kind == .g_or) control else invert(control);
                if (b == .x) unknown = true;
            }
            if (unknown) return .x;
            const quiet = invert(control);
            return if (kind == .g_and or kind == .g_or) quiet else control;
        },
        .g_xor, .g_xnor => {
            var ones: u32 = 0;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == .x) return .x;
                if (b == .one) ones += 1;
            }
            const parity: Int.Bit = if (ones % 2 == 1) .one else .zero;
            return if (kind == .g_xor) parity else invert(parity);
        },
        .g_buf => return gateIn(ins[0]),
        .g_not => return invert(ins[0]),
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => unreachable, // gateBit's own arm
    }
}

// §6.1 one driver. It keeps its OWN value — the net's is the resolution of all
// of them — and re-evaluates whenever one of its operands changes. `s0`/`s1`
// are A.2.2.2's `drive_strength`, which is a property of the DRIVER and not of
// the value it currently holds.
pub const Driver = struct {
    net: u32,
    value: Ast.ExprId,
    /// The §6.2.2 instance `value` is written in. A port connection expression
    /// belongs to the PARENT, which is not the scope of the net it feeds.
    scope: u32 = 0,
    /// Set instead of `value` (which is then `.none`) for a port connection
    /// that cannot collapse — see `Bridge`.
    bridge: ?Bridge = null,
    /// Set instead of `value` for an A.3.1 gate instance. A gate is a driver
    /// (§7.1) but not an expression: §7.8.5's tables read z on an input as x,
    /// which no operator does.
    gate: ?Gate = null,
    /// Set instead of `value` for an IEEE 1364-2005 §8 UDP instance.
    udp: ?*Udp = null,
    /// `value` is read `total` bits wide and this driver asserts the bits
    /// from `lo` up — one internal port of a §12.3.6 concatenated port.
    slice: ?Slice = null,
    /// Set instead of `value` for a §7.6 MOS switch, whose `s0`/`s1` are the
    /// strengths it passes, set at each evaluation.
    mos: ?Mos = null,
    /// Set instead of `value` for IEEE 1364 §19.10's `unconnected_drive`: the
    /// directive pulls an unconnected input port to a logic level THROUGH A
    /// PULL-STRENGTH DRIVER, so it is a driver among drivers and argues with
    /// the net's own type through `Signal` like any other. A constant, hence no
    /// expression and an empty sensitivity list — it is evaluated once, at the
    /// initial `.continuous` dispatch, and never re-runs.
    pull: ?Int.Bit = null,
    sensitivity: []const u32,
    current: Int.Literal,
    /// A gate's `current` is §7.10.2's H/L: its one bit, or high impedance.
    or_z: bool = false,
    s0: Ast.Strength = .strong,
    s1: Ast.Strength = .strong,
    /// A.6.1 `[ delay3 ]`.
    delay: Delay = .{},
    transition: Inertial = .{},
};

// ---- strength and resolution (clause 7, §7.9 Tables 7-4/7-6/7-7, §3.7) ------

/// IEEE 1364-2005 §7.10's signal: a RANGE of strength levels on Figure 7-2's
/// scale, which runs Su0 … Sm0 HiZ0 HiZ1 Sm1 … Su1. A position here is that
/// scale folded at HiZ: `-s` is strength0 level `s`, `+s` strength1 level
/// `s`, and 0 is HiZ. A four-state value is not enough to resolve a net,
/// because "0 and 1 disagree" has a different answer depending on which
/// driver is stronger, and a per-side maximum is not enough either: §7.10.2's
/// StH (a bufif1 with an x enable passing a 1) is `[HiZ, St1]`, which a
/// maximum cannot tell from St1 and which §7.10.3 lets a Pu1 settle to 1.
/// Collapsing back to four states is the LAST step, not the first.
pub const Signal = struct {
    lo: i8 = 0,
    hi: i8 = 0,

    /// What a driver holding `b` at `(s0, s1)` asserts. An `x` spans BOTH
    /// sides — that is what makes it an ambiguous range rather than a value —
    /// and a `z` asserts nothing, which is why an undriven net reads z. A
    /// `highz` strength on one side of an `x` is Figure 7-17's H/L: "HiZ0 is
    /// part of the result because the strength specification ... specified
    /// that strength for an output with a value 0".
    pub fn of(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal {
        const p0 = -@as(i8, @intCast(@intFromEnum(s0)));
        const p1: i8 = @intCast(@intFromEnum(s1));
        return switch (b) {
            .one => .{ .lo = p1, .hi = p1 },
            .zero => .{ .lo = p0, .hi = p0 },
            .x => .{ .lo = p0, .hi = p1 },
            .z => .{},
        };
    }

    /// §7.10.2 H or L: `b` or high impedance, at `b`'s side's strength —
    /// what a three-state driver with an unknown control asserts (Figure 7-6).
    pub fn orZ(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal {
        return of(.x, if (b == .one) .highz else s0, if (b == .zero) .highz else s1);
    }

    pub fn none(self: Signal) bool {
        return self.lo == 0 and self.hi == 0;
    }

    /// §7.10.1-§7.10.3, one more contributor folded in.
    ///   - two unambiguous signals: the stronger wins; equal strength and
    ///     opposite values give x "along with the strength levels of both
    ///     signals and all the smaller strength levels" — the hull;
    ///   - two ambiguous ones: "a range that includes the extremes of the
    ///     signals and all the strengths between them" — the hull again;
    ///   - one of each: §7.10.3's rules a-c. The ambiguous levels STRONGER
    ///     than the unambiguous one remain, the rest disappear, and the gap
    ///     between what remains and the unambiguous level is filled. An
    ///     opposite-value level EQUAL to it remains too: Figure 7-21's text
    ///     drops only the opposite levels of "lesser strength", and §4.6.1
    ///     Table 4-2 makes St0 with StX an x, which dropping it would not.
    pub fn combine(a: Signal, b: Signal) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        const hull: Signal = .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
        const ua = a.lo == a.hi;
        const ub = b.lo == b.hi;
        if (ua and ub) {
            if (@abs(a.lo) != @abs(b.lo)) return if (@abs(a.lo) > @abs(b.lo)) a else b;
            return hull;
        }
        if (!ua and !ub) return hull;
        const u = if (ua) a.lo else b.lo;
        const amb = if (ua) b else a;
        const s: i8 = @intCast(@abs(u));
        return .{
            .lo = if (amb.lo < -s or (amb.lo == -s and u > 0)) @min(u, amb.lo) else u,
            .hi = if (amb.hi > s or (amb.hi == s and u < 0)) @max(u, amb.hi) else u,
        };
    }

    /// The one place the range becomes a printable value again: wholly on
    /// one side is that side's value, HiZ alone is z, and anything that
    /// straddles HiZ — including §7.10.2's H and L — is x.
    pub fn collapse(self: Signal) Int.Bit {
        if (self.lo > 0) return .one;
        if (self.hi < 0) return .zero;
        if (self.none()) return .z;
        return .x;
    }
};

/// §3.7/§7.9: what the net TYPE itself contributes, at the level clause 7 gives
/// it. This is the same information `undriven` returns as a value, at the
/// strength that lets a driver argue with it: a `weak1` driver cannot move a
/// `tri0` because pull(5) beats weak(3), and nothing an `assign` can write
/// beats a supply net's supply(7).
pub fn netPull(kind: Ast.NetKind) Signal {
    return switch (kind) {
        .supply0 => .of(.zero, .supply, .highz),
        .supply1 => .of(.one, .highz, .supply),
        .tri0 => .of(.zero, .pull, .highz),
        .tri1 => .of(.one, .highz, .pull),
        // No pull of its own; a wreal resolves as a real and never gets here.
        .wire, .tri, .triand, .trior, .trireg, .wand, .wor, .uwire, .wreal => .{},
    };
}

/// §7.9 Tables 7-4/7-6/7-7 are VALUE tables: a wired-logic net combines what
/// its drivers say, and a strength decides only whether a driver says anything
/// (a 0 driven through `highz0` is a z, and z is the tables' identity).
pub fn wiredLogic(kind: Ast.NetKind) bool {
    return switch (kind) {
        .wand, .triand, .wor, .trior => true,
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => false,
    };
}

/// IEEE1364-2005 §7.9 wired logic, Tables 7-4/7-6/7-7: fold one more driver's
/// bit into a net's accumulated bit. `z` is the identity of all three tables,
/// which is exactly why an undriven net reads z.
///
/// Only the wired-logic net types reach this now: `wire`/`tri`/`tri0`/`tri1`/
/// `trireg` and the supply nets resolve through `Signal`, which is clause 7's
/// strength model, and the `else` arm below survives for the one thing the
/// value tables still do there — deciding what a fold with no contribution at
/// all reads as.
///
/// ponytail: the wired-logic result carries no strength onward. §7.10 gives
/// the combination a strength of its own (the stronger of the two on the
/// winning side), which nothing can observe here because a wired-logic net is
/// never itself a driver of another net and `%v` does not exist. When gate
/// primitives land (D08) and a `wand` feeds a `tran`, this becomes a `Signal`
/// fold with the table applied to the collapsed values and the strength taken
/// alongside.
pub fn wired(kind: Ast.NetKind, acc: Int.Bit, b: Int.Bit) Int.Bit {
    if (acc == .z) return b;
    if (b == .z) return acc;
    return switch (kind) {
        .wand, .triand => if (acc == .zero or b == .zero) .zero else if (acc == .one and b == .one) .one else .x,
        .wor, .trior => if (acc == .one or b == .one) .one else if (acc == .zero and b == .zero) .zero else .x,
        // Agreement, else conflict.
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => if (acc == b) acc else .x,
    };
}

/// §3.7 the value a net of this type shows with no driver at all: the pull of
/// `tri0`/`tri1`, the constant of a supply net, the X a `trireg` starts at
/// before it has any charge to hold, and Z for everything else.
pub fn undriven(kind: Ast.NetKind) Int.Bit {
    return switch (kind) {
        .supply0, .tri0 => .zero,
        .supply1, .tri1 => .one,
        .trireg => .x,
        // A wreal reads 0.0 undriven, which `mintNet` gives it directly.
        .wire, .tri, .triand, .trior, .wand, .wor, .uwire, .wreal => .z,
    };
}

// ---- user-defined primitives (IEEE 1364-2005 §8, A.5) -----------------------

/// One A.5.3 input field: a level symbol (`0 1 x ? b`), a parenthesized edge
/// `(vw)`, or one of Table 8-1's edge letters (`r f p n *`).
pub const UdpSym = union(enum) { level: u8, pair: [2]u8, letter: u8 };

/// One table entry, split into fields. `edge_at` is the input its edge is on,
/// null for a level entry; `state` is 0 in a combinational table.
pub const UdpRow = struct { ins: []const UdpSym, state: u8, out: u8, edge_at: ?u32 };

/// §8 one UDP instance as a driver: its table, its input terminals, and what
/// a sequential one carries between events — the input values the table last
/// saw (an event is a change FROM these) and its state, the output reg.
pub const Udp = struct {
    rows: []const UdpRow,
    sequential: bool,
    ins: []const Ast.ExprId,
    prev: []Int.Bit,
    state: Int.Bit,
    /// Whether the driver has published once; §8.5's initial value is
    /// published at time 0 whatever the instance delay.
    started: bool = false,
};

/// Split A.5.3's input characters into one field per input, or null when an
/// entry has the wrong number of them (A.5.3 gives each input exactly one).
pub fn udpRows(a: std.mem.Allocator, decl: *const Ast.UdpDecl) Error!?[]const UdpRow {
    const inputs = decl.ports.len - 1;
    const rows = try a.alloc(UdpRow, decl.rows.len);
    for (decl.rows, rows) |src, *row| {
        var syms: std.ArrayList(UdpSym) = .empty;
        var edge_at: ?u32 = null;
        var i: usize = 0;
        while (i < src.inputs.len) : (i += 1) {
            const c = src.inputs[i];
            const sym: UdpSym = switch (c) {
                '(' => blk: {
                    if (i + 3 >= src.inputs.len or src.inputs[i + 3] != ')') return null;
                    const pair: [2]u8 = .{ std.ascii.toLower(src.inputs[i + 1]), std.ascii.toLower(src.inputs[i + 2]) };
                    i += 3;
                    break :blk .{ .pair = pair };
                },
                'r', 'R', 'f', 'F', 'p', 'P', 'n', 'N', '*' => .{ .letter = std.ascii.toLower(c) },
                else => .{ .level = std.ascii.toLower(c) },
            };
            if (sym != .level) edge_at = @intCast(syms.items.len);
            try syms.append(a, sym);
        }
        if (syms.items.len != inputs) return null;
        row.* = .{ .ins = syms.items, .state = std.ascii.toLower(src.state), .out = std.ascii.toLower(src.output), .edge_at = edge_at };
    }
    return rows;
}

/// Table 8-1's level symbols against a value the table reads (§8.1.6: a z
/// input has already been read as x).
fn udpLevel(sym: u8, b: Int.Bit) bool {
    return switch (sym) {
        '0' => b == .zero,
        '1' => b == .one,
        'x' => b == .x,
        '?' => true,
        'b' => b == .zero or b == .one,
        else => false,
    };
}

/// Table 8-1's edges: `(vw)` is v then w; r is (01), f (10), p any of (01)
/// (0x) (x1), n any of (10) (1x) (x0), and * any change at all.
fn udpEdge(sym: UdpSym, from: Int.Bit, to: Int.Bit) bool {
    if (from == to) return false;
    return switch (sym) {
        .level => false,
        .pair => |p| udpLevel(p[0], from) and udpLevel(p[1], to),
        .letter => |l| switch (l) {
            'r' => from == .zero and to == .one,
            'f' => from == .one and to == .zero,
            'p' => (from == .zero and to != .zero) or (from == .x and to == .one),
            'n' => (from == .one and to != .one) or (from == .x and to == .zero),
            else => true, // `*`
        },
    };
}

fn udpOut(sym: u8, state: Int.Bit) Int.Bit {
    return switch (sym) {
        '0' => .zero,
        '1' => .one,
        '-' => state,
        else => .x,
    };
}

/// §8.6/§8.7 one evaluation. With `changed == null` only level entries can
/// match (a combinational table, or a sequential one re-read without an
/// event); otherwise `changed` went from `from` to `ins[changed]`, and an
/// edge entry on that input matches too — after every level entry, since
/// §8.8 makes level-sensitive entries dominate edge-sensitive ones. Nothing
/// matching is x (§8.1.6: "a combination of input values not specified ...
/// results in x").
pub fn udpEval(rows: []const UdpRow, sequential: bool, ins: []const Int.Bit, state: Int.Bit, changed: ?u32, from: Int.Bit) Int.Bit {
    for (rows) |row| {
        if (row.edge_at != null) continue;
        if (sequential and !udpLevel(row.state, state)) continue;
        for (row.ins, ins) |sym, b| {
            if (!udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    const k = changed orelse return .x;
    for (rows) |row| {
        if (row.edge_at != k or !udpLevel(row.state, state)) continue;
        for (row.ins, ins, 0..) |sym, b, i| {
            if (i == k) {
                if (!udpEdge(sym, from, b)) break;
            } else if (sym != .level or !udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    return .x;
}

// ---- four-state storage (§3.7) ----------------------------------------------

/// A four-state value of `width` bits, every bit `fill`. This is the one place
/// declared state gets its starting value: X for a variable, Z for an undriven
/// net (§3.7 — that difference IS the net/variable difference).
pub fn filled(a: std.mem.Allocator, width: u32, signed: bool, fill: Int.Bit) Error!Int.Literal {
    const words = (@as(usize, width) - 1) / 64 + 1;
    const planes = try a.alloc(u64, words * 2);
    @memset(planes[0..words], if (@intFromEnum(fill) & 1 != 0) std.math.maxInt(u64) else 0);
    @memset(planes[words..], if (@intFromEnum(fill) >> 1 != 0) std.math.maxInt(u64) else 0);
    const tail: u6 = @truncate(width);
    if (tail != 0) {
        const keep = (@as(u64, 1) << tail) - 1;
        planes[words - 1] &= keep;
        planes[2 * words - 1] &= keep;
    }
    return .{ .width = width, .signed = signed, .sized = true, .planes = planes };
}

/// Write one packed bit. The read side is `Int.Literal.bit`; only the §7.9
/// resolution fold writes bit by bit.
pub fn setBit(value: Int.Literal, index: u32, b: Int.Bit) void {
    const at = @as(u64, 1) << @truncate(index);
    const word = index / 64;
    if (@intFromEnum(b) & 1 != 0) value.values()[word] |= at else value.values()[word] &= ~at;
    if (@intFromEnum(b) >> 1 != 0) value.unknowns()[word] |= at else value.unknowns()[word] &= ~at;
}

// ---- tests ------------------------------------------------------------------

test "continuous vector delay audit_assignment_vector_delay" {
    try expectRun(
        \\// IEEE1364-2005 §6.1.3: vector nonzero-to-nonzero uses rising delay,
        \\// even if one bit falls. Whole-vector transition to zero uses falling delay;
        \\// all-z uses turnoff. Samples deliberately avoid exact update-time races.
        \\//! inherited IEEE 1364-2005 6.1.3
        \\`timescale 1ns/1ns
        \\module audit_assignment_vector_delay;
        \\  reg [1:0] a;
        \\  wire [1:0] y;
        \\  assign #(2,7,4) y = a;
        \\  initial begin
        \\    a = 0;
        \\    #10 a = 1;
        \\    #3 $display("nonzero=%b", y);
        \\    a = 2;
        \\    #3 $display("nonzero_to_nonzero=%b", y);
        \\    a = 0;
        \\    #6 $display("before_fall=%b", y);
        \\    #2 $display("after_fall=%b", y);
        \\    a = 2'bzz;
        \\    #3 $display("before_turnoff=%b", y);
        \\    #2 $display("after_turnoff=%b", y);
        \\    $finish(0);
        \\  end
        \\endmodule
    ,
        \\nonzero=01
        \\nonzero_to_nonzero=10
        \\before_fall=10
        \\after_fall=00
        \\before_turnoff=00
        \\after_turnoff=zz
        \\
    );
}

test "continuous vector delay audit_assignment_vector_delay_unknown" {
    try expectRun(
        \\// IEEE1364-2005 §6.1.3: vector transitions other than nonzero->zero
        \\// and all-z use rising delay. Mixed x/z is not all-z; unlike scalar gates,
        \\// a vector transition to x does not select the minimum delay.
        \\// #(7,5,2): start00; at10 assign0x -> due17; at19 assign1z -> due26;
        \\// at28 assignzz -> due30. Samples avoid update instants.
        \\//! inherited IEEE 1364-2005 6.1.3
        \\`timescale 1ns/1ns
        \\module audit_assignment_vector_delay_unknown;
        \\  reg [1:0] a;
        \\  wire [1:0] y;
        \\  assign #(7,5,2) y = a;
        \\  initial begin
        \\    a = 0;
        \\    #10 a = 2'b0x;
        \\    #3 $display("before_x=%b", y);
        \\    #5 $display("after_x=%b", y);
        \\    #1 a = 2'b1z;
        \\    #3 $display("before_mixed_z=%b", y);
        \\    #5 $display("after_mixed_z=%b", y);
        \\    #1 a = 2'bzz;
        \\    #1 $display("before_all_z=%b", y);
        \\    #2 $display("after_all_z=%b", y);
        \\    $finish(0);
        \\  end
        \\endmodule
    ,
        \\before_x=00
        \\after_x=0x
        \\before_mixed_z=0x
        \\after_mixed_z=1z
        \\before_all_z=1z
        \\after_all_z=zz
        \\
    );
}

test "continuous vector delay examines upper limbs and keeps scalar selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const zero = try filled(arena.allocator(), 129, false, .zero);
    const high = try filled(arena.allocator(), 129, false, .zero);
    setBit(high, 128, .one);
    const off = try filled(arena.allocator(), 129, false, .z);
    const mixed = try filled(arena.allocator(), 129, false, .z);
    setBit(mixed, 128, .x);
    const delay = Delay{ .rise = 7, .fall = 5, .off = 2, .present = true };
    try std.testing.expectEqual(@as(u64, 7), delay.continuous(zero, high));
    try std.testing.expectEqual(@as(u64, 5), delay.continuous(high, zero));
    try std.testing.expectEqual(@as(u64, 2), delay.continuous(high, off));
    try std.testing.expectEqual(@as(u64, 7), delay.continuous(high, mixed));
    for ([_]Int.Bit{ .zero, .one, .x, .z }) |bit| {
        const scalar = try filled(arena.allocator(), 1, false, bit);
        try std.testing.expectEqual(delay.to(bit), delay.continuous(scalar, scalar));
    }
}

test "an undriven net reads Z where a variable reads X" {
    try expectRun(
        \\module example;
        \\reg [3:0] r;
        \\wire [3:0] w;
        \\wire s;
        \\initial $display("%b %b %b", r, w, s);
        \\endmodule
    , "xxxx zzzz z\n");
}

test "IEEE1364-2005 section 7.9 wired logic resolves all drivers of one net" {
    // Each net has the same two drivers; only the resolution function differs.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\wor wo;
        \\assign w = a, wa = a, wo = a;
        \\assign w = b, wa = b, wo = b;
        \\initial begin
        \\  a = 0; b = 0; #1 $display("0 0 %b %b %b", w, wa, wo);
        \\  a = 1;        #1 $display("1 0 %b %b %b", w, wa, wo);
        \\  b = 1;        #1 $display("1 1 %b %b %b", w, wa, wo);
        \\  a = 1'bz;     #1 $display("z 1 %b %b %b", w, wa, wo);
        \\  b = 1'bx;     #1 $display("z x %b %b %b", w, wa, wo);
        \\  b = 1'bz;     #1 $display("z z %b %b %b", w, wa, wo);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\0 0 0 0 0
        \\1 0 x 0 1
        \\1 1 1 1 1
        \\z 1 1 1 1
        \\z x x x x
        \\z z z z z
        \\
    );
}

// IEEE 1364-2005 clause 7 via §1.1, annex A.2.2.2 and A.6.1. The boundary the
// suite's d03 fixtures own is the resolution ITSELF; what a unit test is for is
// the three places the pair model changes an answer the value-only resolver had
// a different one for, so that a regression is named here rather than in a
// transcript diff.
test "a drive strength decides which of two disagreeing drivers the net shows" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\tri0 t;
        \\assign (strong1, strong0) w = a, t = a;
        \\assign (weak1, weak0) w = b;
        \\initial begin
        \\  a = 1; b = 0; #1 $display("6v3 %b %b", w, t);
        \\  a = 0; b = 1; #1 $display("3v6 %b %b", w, t);
        \\  a = 1'bx;     #1 $display("ambiguous %b %b", w, t);
        \\  a = 1'bz;     #1 $display("removed %b %b", w, t);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
    // `t` is a tri0: its own pull(5) loses to strong(6) on both polarities and
    // to the strong x on neither side, so the ambiguous line is x there too —
    // and the weak driver of `w` never moves it.
        \\6v3 1 1
        \\3v6 0 0
        \\ambiguous x x
        \\removed 1 0
        \\
    );
}

test "a highz half suppresses that polarity outright, wired logic included" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\assign (strong1, highz0) w = a, wa = a;
        \\assign (weak1, weak0) w = b, wa = b;
        \\initial begin
        \\  a = 0; b = 1; #1 $display("open_drain %b %b", w, wa);
        \\  a = 0; b = 0; #1 $display("weak_zero %b %b", w, wa);
        \\  a = 0; b = 1'bz; #1 $display("nothing_left %b %b", w, wa);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
    // The `highz0` driver holding 0 asserts nothing at all, so it is invisible
    // to the plain wire AND is the wand table's identity rather than a 0 vote.
        \\open_drain 1 1
        \\weak_zero 0 0
        \\nothing_left z z
        \\
    );
}

test "a supply net outranks every strength an assign can write but its own" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\supply1 vdd;
        \\supply1 v2;
        \\assign (strong1, strong0) vdd = a;
        \\assign (supply1, supply0) v2 = a;
        \\initial begin
        \\  a = 0; #1 $display("zero %b %b", vdd, v2);
        \\  a = 1; #1 $display("one %b %b", vdd, v2);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
    // A supply-strength driver does not LOSE to the net, it TIES with it, and a
    // tie on two nonzero sides is x. That is the line a resolver which simply
    // ignores a supply net's drivers gets wrong.
        \\zero 1 x
        \\one 1 1
        \\
    );
}

test "the pull supply and capacitive net types supply what no driver did" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg d;
        \\tri0 t0;
        \\tri1 t1;
        \\supply0 s0;
        \\supply1 s1;
        \\trireg c;
        \\assign t0 = d, t1 = d, s0 = d, s1 = d, c = d;
        \\initial begin
        \\  $display("start %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 0;    #1 $display("zero  %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 1'bz; #1 $display("float %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\start x x 0 1 x
        \\zero  0 0 0 1 0
        \\float 0 1 0 1 0
        \\
    );
}

// §7.10.2/§7.10.3 against the clause's own figures, each as (lo, hi) on the
// folded scale: 35X is [-3, 5], 56X [-5, 6], 36X [-3, 6], 651 [5, 6].
test "§7.10 strength ranges combine the way Figures 7-9 through 7-19 draw them" {
    const S = Signal;
    // Figure 7-9: PuH + WeL is 35X, "the extremes of the signals and all the strengths between".
    try std.testing.expectEqual(S{ .lo = -3, .hi = 5 }, S.orZ(.one, .strong, .pull).combine(S.orZ(.zero, .weak, .strong)));
    // Figure 7-14: 651 + 530 is 56X.
    try std.testing.expectEqual(S{ .lo = -5, .hi = 6 }, (S{ .lo = 5, .hi = 6 }).combine(.{ .lo = -5, .hi = -3 }));
    // Figure 7-19: StH + We0 is 36X (rule c fills the gap).
    const sth = S.of(.x, .highz, .strong);
    try std.testing.expectEqual(S{ .lo = -3, .hi = 6 }, sth.combine(S.of(.zero, .weak, .strong)));
    // Rules a/b: StH + Pu1 keeps only St1 above Pu1 — a 1, not an x.
    try std.testing.expectEqual(Int.Bit.one, sth.combine(S.of(.one, .strong, .pull)).collapse());
    try std.testing.expectEqual(Int.Bit.x, sth.collapse());
    // An opposite level EQUAL to the unambiguous one ties: Table 4-2's 0-with-x.
    try std.testing.expectEqual(Int.Bit.x, S.of(.x, .strong, .strong).combine(S.of(.zero, .strong, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.x, S.of(.x, .pull, .pull).combine(S.of(.zero, .pull, .highz)).collapse());
    try std.testing.expectEqual(Int.Bit.x, sth.combine(S.of(.zero, .strong, .strong)).collapse());
    // §7.10.1: unambiguous — the stronger wins, equal and opposite is x.
    try std.testing.expectEqual(Int.Bit.zero, S.of(.one, .strong, .weak).combine(S.of(.zero, .pull, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.x, S.of(.one, .strong, .pull).combine(S.of(.zero, .pull, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.z, S.of(.one, .strong, .highz).collapse());
}

// §7.6/§7.12: a MOS switch passes its data at the data's strength (reduced by
// an `r` switch), a tran joins two nets into one resolution, and a tranif
// whose control is x lets the far side's value arrive only as "or z".
test "§7.6 MOS strength pass-through and reduction, tran and tranif joins" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg d, g, c; wire n, rn, p, q, s, t;
        \\pullup (n); pullup (rn);
        \\nmos (n, d, g); rnmos (rn, d, g);
        \\assign p = d; tran (p, q);
        \\buf (s, 1'b1); tranif1 (s, t, c);
        \\initial begin
        \\  d = 0; g = 1; c = 1'bx; #1 $write("%b%b %b%b %b%b ", n, rn, p, q, s, t);
        \\  c = 1; #1 $write("%b ", t); c = 0; #1 $display("%b", t);
        \\end
        \\endmodule
    , "0x 00 1x 1 z\n");
}

// §7.1.6: a vector terminal as wide as the array is split one bit per gate,
// a scalar one is shared, and each gate drives only its own output bit.
test "§7.1.5 a gate instance array splits vector terminals and shares scalars" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [2:0] a, b; reg e; wire [2:0] y; wire [2:0] z;
        \\and g[2:0](y, a, b);
        \\bufif0 f[0:2](z, a, e);
        \\initial begin a = 3'b110; b = 3'b011; e = 1; #1 $write("%b %b ", y, z); e = 0; #1 $display("%b", z); end
        \\endmodule
    , "010 zzz 110\n");
}

// §8: a rising-edge toggle built from Table 8-1's letters, behind an
// instance delay — the initial state is out at time 0, a falling edge holds,
// each rising edge flips the state and lands 2 units later.
test "§8 a sequential UDP with edge letters, an initial state and an instance delay" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\primitive tog(q, c);
        \\  output q; reg q; input c;
        \\  initial q = 1;
        \\  table r : 0 : 1; r : 1 : 0; f : ? : -; (?x) : ? : -; (x?) : ? : -; endtable
        \\endprimitive
        \\module m;
        \\reg c; wire q;
        \\tog #2 t(q, c);
        \\initial begin
        \\  #1 $write("%b", q); c = 0; #1 c = 1; #1 $write("%b", q); #1 $write("%b", q);
        \\  c = 0; #3 c = 1; #3 $display("%b", q);
        \\end
        \\endmodule
    , "1101\n");
}
