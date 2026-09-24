//! §4.5.15 `$limit` — which call sites this device honours, decided before
//! anything is written.
//!
//! PURE (ARCHITECTURE.md §2): `plan` takes the lowered module and the unknowns'
//! names and returns a `Limits` — the honoured sites in source order and one
//! line per declined site. `cg_limit.zig` is the emitter that reads it (`limit`,
//! `seed`, the `precompute` prep); the questions both sides ask of the list
//! (`ladderOf`, `limvdsClaimed`, `writable`) are methods here so the two can
//! only ever agree.
//!
//! Cut verbatim from `cg_limit.zig` (`collect` and its helpers); only the
//! receiver changed.

const std = @import("std");
const Mir = @import("ir").Mir;
const Input = @import("input.zig").Input;
const plan_topo = @import("topology.zig");

pub const Error = std.mem.Allocator.Error;
const none_u32 = std.math.maxInt(u32);

/// §4.5.15 the `$limit` call sites this device honours, in source order, and
/// one line per site it does not. `buildJobs` queues the honoured sites'
/// algorithm arguments into the core.
pub const Limits = struct {
    calls: []LimitCall = &.{},
    declined: [][]const u8 = &.{},
    /// `Lowered.num_ports` — what `writable` answers from.
    num_ports: usize = 0,

    /// The ladder `calls[i]` (a `fetlimds` site, either leg) belongs to:
    /// exactly two `fetlimds` sites share its first-named node (the gate), one
    /// `limvds` site spans their second-named nodes (the channel), and both
    /// channel nodes are the device's own to correct. Null otherwise. Derived on
    /// demand — the plan and the emitter ask the same question of the same list, so
    /// storing the answer could only let the two fall out of agreement.
    pub fn ladderOf(g: Limits, i: usize) ?Ladder {
        const me = g.calls[i];
        var partner: usize = undefined;
        var gate_legs: usize = 0;
        for (g.calls, 0..) |lc, j| {
            if (lc.alg != .fetlimds or lc.hi != me.hi) continue;
            gate_legs += 1;
            if (j != i) partner = j;
        }
        if (gate_legs != 2) return null;
        const other = g.calls[partner];
        if (!g.writable(me.lo) or !g.writable(other.lo)) return null;
        for (g.calls, 0..) |lc, k| {
            if (lc.alg != .limvds) continue;
            if (lc.hi == me.lo and lc.lo == other.lo)
                return .{ .gs = @intCast(partner), .gd = @intCast(i), .ds = @intCast(k) };
            if (lc.hi == other.lo and lc.lo == me.lo)
                return .{ .gs = @intCast(i), .gd = @intCast(partner), .ds = @intCast(k) };
        }
        return null;
    }

    /// Is this `limvds` site the channel rung of some ladder? Then `emitLadder`
    /// owns it and the flat list must not clamp it a second time.
    pub fn limvdsClaimed(g: Limits, k: usize) bool {
        for (g.calls, 0..) |lc, i| {
            if (lc.alg != .fetlimds) continue;
            const lad = g.ladderOf(i) orelse continue;
            if (lad.ds == k) return true;
        }
        return false;
    }

    /// Can the device correct this unknown? Only its own internal nets: the host
    /// masks writes to §6.5 ports, because a limiter moving a driven or shared
    /// node fights the sources and the other devices on it (`contract.zig`'s
    /// note on `limit`).
    pub fn writable(g: Limits, u: u32) bool {
        return u != none_u32 and u >= g.num_ports;
    }
};

/// The three SPICE3 limiters the corpus names, plus one of our own. NOT an
/// LRM taxonomy: §4.5.15 leaves the identifier implementation-defined; the
/// first three are the spellings `devsup.c` established, which is what every
/// `.va` in the corpus writes. An identifier that is not one of these is
/// declined, which §4.5.15 permits ("the simulator may choose to ignore the
/// limiting request").
///
/// `fetlimds` is OURS, naming a construct devsup.c has no word for: ngspice's
/// MOS loads (mos1load.c:351-373, same in mos2/3/6/9, vdmos, b3ld) do not
/// fetlim both gate legs — they fetlim the junction that CONTROLS the channel
/// in the present mode, `vgs` when the OLD vds >= 0 and `vgd` when it is
/// negative, run limvds, and derive the other leg. A static both-legs ladder
/// clamps the non-controlling frame at a vds = 0 crossing, and Newton
/// two-cycles against the mode-swapped Jacobian (ngspice/mosamp wedged at the
/// seam). Spell BOTH gate legs `fetlimds` next to a `limvds` on the channel
/// and the three emit as one mode ladder (`emitLadder`); jfet/hfet keep
/// `fetlim`, because their ngspice loads really do clamp both legs.
pub const Alg = enum {
    pnjlim,
    fetlim,
    limvds,
    fetlimds,
    /// ngspice's per-model absolute step clamp (`B4SOIlimit`, hisim's
    /// `limit_dx`): |vnew − vold| ≤ arg. Unlike `pnjlim` it carries NO
    /// cold-start seed — B4SOI's MODEINITJCT starts every junction at
    /// icVxS (0), and the vcrit seed is exactly what parked a floating
    /// SOI body in the high-current basin.
    steplim,

    /// Numeric arguments that follow the algorithm name.
    pub fn arity(a: Alg) usize {
        return switch (a) {
            .pnjlim => 2,
            .fetlim, .fetlimds => 1,
            .limvds => 0,
            .steplim => 1,
        };
    }
};

const max_args = 2;

/// One resolved `$limit` call site.
pub const LimitCall = struct {
    alg: Alg,
    /// Unknowns the probe spans, `V(hi, lo)`. `none_u32` is §1.3.1.1 global
    /// ground, which is not an unknown and reads as a hard 0.
    hi: u32,
    lo: u32,
    /// The algorithm's numeric arguments as MIR values. `buildJobs` queues these
    /// as core jobs, so by emission time each has an `lo_idx` field.
    argv: [max_args]Mir.Value = .{ .f_zero, .f_zero },
    /// Optional trailing argument: the FRAME SIGN. All three devsup.c
    /// limiters assume forward = positive; a PNP/PMOS model whose junction is
    /// forward at NEGATIVE probe voltage passes its `type` parameter here and
    /// the clamp runs on `sign·v` — exactly ngspice's habit of limiting
    /// `type*vbe` in the load routine. `.f_zero` = unsigned (+1).
    ///
    /// This exists because the alternative spellings do not survive lowering:
    /// `$limit` under `if (type > 0)` is declined (no CFG in the clamp list),
    /// and `$limit(type*V(a,b), …)` has no node pair to correct.
    sign: Mir.Value = .f_zero,
};

// -------------------------------------------------------------------- plan

/// Resolve every `$limit` call. Runs in `prepare` BEFORE `buildJobs`, which
/// queues `argv` into the shared core.
pub fn plan(g: Input, u_names: []const []const u8) Error!Limits {
    var lim: Limits = .{ .num_ports = g.lowered.num_ports };
    var out: std.ArrayList(LimitCall) = .empty;
    var declined: std.ArrayList([]const u8) = .empty;
    // A block that dominates the exit is on every path to it, so a call there
    // runs unconditionally. `limit` has no CFG of its own — it is a flat list
    // of clamps — so a call under an `if` is one this cannot honour: its guard
    // is bias-dependent and would have to be re-evaluated at the UNLIMITED x.
    //
    // The exit is the block with NO successors, not `rpo[last]`: with a loop
    // upstream, DFS may visit the loop's after-block before its body, and
    // reverse postorder then ends on the BODY — dominance against that
    // declined every `$limit` in BSIMSOI (its temp section runs a `for` over
    // fingers and a TOXP `while` before the probe block).
    const exit = blk: {
        for (g.an.rpo) |bi| {
            if (g.an.succs[bi].len == 0) break :blk bi;
        }
        break :blk g.an.rpo[g.an.rpo.len - 1];
    };
    for (g.an.rpo) |bi| {
        for (g.an.blockInstsFlat(bi)) |inst| {
            if (g.mir.instOp(inst) != .call) continue;
            const d = g.mir.instData(inst).call;
            if (d.callee != .@"$limit") continue;

            const alg = algOf(g, d.args) orelse continue; // §4.5.15 declining is conformant
            const pair = probePair(g, d.args) orelse {
                try decline(g, u_names, &declined, d.args, "its first argument is not a §4.4 potential probe of one or two nets");
                continue;
            };
            if (!g.an.dominates(bi, exit)) {
                try decline(g, u_names, &declined, d.args, "it is under an `if`, and the clamp list carries no control flow");
                continue;
            }
            if (!lim.writable(pair[0]) and !lim.writable(pair[1])) {
                try decline(g, u_names, &declined, d.args, "both nets are §6.5 ports, which the host masks — there is nothing private to correct");
                continue;
            }
            const n = alg.arity();
            if (d.args.len < 2 + n) {
                try decline(g, u_names, &declined, d.args, "too few arguments for the algorithm named");
                continue;
            }
            var lc: LimitCall = .{ .alg = alg, .hi = pair[0], .lo = pair[1] };
            var bad = false;
            for (0..n) |k| {
                const v = g.an.rv(d.args[2 + k]);
                // The clamp is arithmetic on volts. An integer argument would
                // land in the core as an `i64` field, and reading `.v` off it
                // would not compile — refuse it here, where the reason is
                // sayable, rather than emit code that does not build.
                if (v != .f_zero and g.an.vty[@intFromEnum(v)] != .real) bad = true;
                lc.argv[k] = v;
            }
            // One argument past the algorithm's arity is the frame sign.
            // Integer is fine here — the emitted uses are comparisons
            // (`< 0.0`), never arithmetic, and `parameter integer type` is
            // the standard polarity spelling (bjt.va).
            if (d.args.len > 2 + n) {
                const v = g.an.rv(d.args[2 + n]);
                if (v != .f_zero and g.an.vty[@intFromEnum(v)] == .str) bad = true;
                lc.sign = v;
            }
            if (bad) {
                try decline(g, u_names, &declined, d.args, "an algorithm argument is not real-valued");
                continue;
            }
            try out.append(g.arena, lc);
        }
    }
    lim.calls = out.items;

    // A `fetlimds` site is only honoured as a member of a COMPLETE mode
    // ladder — dangling, it would clamp one leg with no frame authority,
    // which is the static-order bug the algorithm exists to fix. The mask is
    // computed over the unfiltered list first: validity is symmetric (both
    // legs check both `lo`s, a >2-way gate share fails every member), so
    // dropping the invalid sites never invalidates a surviving one.
    var any_dangling = false;
    for (lim.calls, 0..) |lc, i| {
        if (lc.alg == .fetlimds and lim.ladderOf(i) == null) any_dangling = true;
    }
    if (any_dangling) {
        const keep = try g.arena.alloc(bool, lim.calls.len);
        for (lim.calls, 0..) |lc, i| {
            keep[i] = lc.alg != .fetlimds or lim.ladderOf(i) != null;
            if (!keep[i]) try declineLc(g, u_names, &declined, lc, "no complete mode ladder — it needs a second fetlimds site on the same gate node and a limvds site across the two channel nodes, all channel sides internal");
        }
        var w_: usize = 0;
        for (out.items, 0..) |lc, i| {
            if (!keep[i]) continue;
            out.items[w_] = lc;
            w_ += 1;
        }
        lim.calls = out.items[0..w_];
    }
    lim.declined = declined.items;
    return lim;
}

fn declineLc(g: Input, u_names: []const []const u8, list: *std.ArrayList([]const u8), lc: LimitCall, why: []const u8) Error!void {
    try list.append(g.arena, try std.fmt.allocPrint(g.arena, "$limit(V({s},{s}), \"{t}\"): {s}", .{ uName(u_names, lc.hi), uName(u_names, lc.lo), lc.alg, why }));
}

/// A resolved mode ladder: indices into `calls` of the vgs leg, the vgd
/// leg, and the `limvds` site whose probe orients them — `limvds` reads
/// V(di,si), so the leg landing on its `lo` is the source leg (vgs) and the
/// one landing on its `hi` is the drain leg (vgd).
pub const Ladder = struct { gs: u32, gd: u32, ds: u32 };

fn decline(g: Input, u_names: []const []const u8, list: *std.ArrayList([]const u8), args: []const Mir.Value, why: []const u8) Error!void {
    try list.append(g.arena, try std.fmt.allocPrint(g.arena, "{s}: {s}", .{ spell(g, u_names, args), why }));
}

/// `$limit(V(a,b), "alg")` as it reads in the source, for the declined list.
fn spell(g: Input, u_names: []const []const u8, args: []const Mir.Value) []const u8 {
    const alg: []const u8 = if (args.len >= 2) switch (g.mir.valueDef(g.an.rv(args[1]))) {
        .str_const => |s| s,
        .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => "?",
    } else "?";
    const pair = probePair(g, args);
    const hi: []const u8 = if (pair) |p| uName(u_names, p[0]) else "?";
    const lo: []const u8 = if (pair) |p| uName(u_names, p[1]) else "?";
    return std.fmt.allocPrint(g.arena, "$limit(V({s},{s}), \"{s}\")", .{ hi, lo, alg }) catch "$limit(…)";
}

pub fn uName(u_names: []const []const u8, u: u32) []const u8 {
    return if (u == none_u32) "0" else u_names[u];
}

/// §4.4 `V(a,b)` lowers to `fsub` of two probes and `V(a)` to a bare probe
/// (mir.zig:420-422). Anything else — a flow probe, an expression — has no
/// node pair to correct.
fn probePair(g: Input, args: []const Mir.Value) ?[2]u32 {
    if (args.len == 0) return null;
    const v = g.an.rv(args[0]);
    const pair: [2]u32 = switch (g.mir.valueDef(v)) {
        .block_param => |u| .{ u, none_u32 },
        .inst_result => |inst| blk: {
            if (g.mir.instOp(inst) != .fsub) return null;
            const d = g.mir.instData(inst).binary;
            const a = g.mir.valueDef(g.an.rv(d.lhs));
            const b = g.mir.valueDef(g.an.rv(d.rhs));
            if (a != .block_param or b != .block_param) return null;
            break :blk .{ a.block_param, b.block_param };
        },
        .undef, .float_const, .int_const, .str_const, .param_ref => return null,
    };
    // §5.4.2 a branch-flow unknown is an ampere. These limiters are voltage
    // clamps; writing one back as if it were a potential is nonsense.
    for (pair) |u| {
        if (u != none_u32 and plan_topo.isFlowUnknown(g, u)) return null;
    }
    return pair;
}

fn algOf(g: Input, args: []const Mir.Value) ?Alg {
    // §4.5.15 bare `$limit(V(a,b))` asks for the simulator's own choice of
    // algorithm. Ours is none: inventing a clamp the model did not name would
    // change its answers with no way to say so in the source.
    if (args.len < 2) return null;
    const s = switch (g.mir.valueDef(g.an.rv(args[1]))) {
        .str_const => |s| s,
        // §9.17.3 also allows a user analog function here. That is a call, not
        // a string, and it needs the whole body — handled in lowering
        // (`Lower.lowerLimitUser`), so it never reaches the clamp list.
        .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => return null,
    };
    return std.meta.stringToEnum(Alg, s);
}

const Fixture = @import("fixture.zig").Fixture;

test "an honoured pnjlim, and the declines that say why" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "p", "a", "b" }); // one port, two internal nets
    defer f.deinit();
    f.lowered.num_ports = 1;
    const a = f.alloc();
    const va = try f.probe(1);
    const vb = try f.probe(2);
    const vab = try f.mir.emit(a, .entry, .fsub, &.{ va, vb });
    const pnj = try f.mir.addStrConst(a, "pnjlim");
    const vt = try f.mir.addFloatConst(a, 0.025);
    const vcrit = try f.mir.addFloatConst(a, 0.6);
    // $limit(V(a,b), "pnjlim", vt, vcrit): honoured, both nets internal.
    _ = try f.call("$limit", &.{ vab, pnj, vt, vcrit });
    // $limit(V(p), "pnjlim", vt, vcrit): the only net is a port.
    _ = try f.call("$limit", &.{ try f.probe(0), pnj, vt, vcrit });
    // $limit(V(a,b), "pnjlim", vt): too few arguments.
    _ = try f.call("$limit", &.{ vab, pnj, vt });
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "p", "a", "b" });
    try std.testing.expectEqual(@as(usize, 1), lim.calls.len);
    try std.testing.expectEqual(Alg.pnjlim, lim.calls[0].alg);
    try std.testing.expectEqual(@as(u32, 1), lim.calls[0].hi);
    try std.testing.expectEqual(@as(u32, 2), lim.calls[0].lo);
    try std.testing.expect(lim.writable(2) and !lim.writable(0));
    try std.testing.expectEqual(@as(usize, 2), lim.declined.len);
    try std.testing.expect(std.mem.indexOf(u8, lim.declined[0], "§6.5 ports") != null);
    try std.testing.expect(std.mem.indexOf(u8, lim.declined[1], "too few arguments") != null);
}
