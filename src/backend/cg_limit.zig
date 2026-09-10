//! §4.5.15 `$limit` — the convergence half of the backend.
//!
//! Transformation: each `$limit(V(a,b), "alg", args…)` call in the MIR → one
//! clamp in the contract's `limit` hook, plus a cold-start bias in `seed`. The
//! host applies both to the solution vector: `limit` after every linear solve
//! (`ARPice/src/devices/engine.zig` `limitRange`, driven from
//! `converger.zig`'s `finalizeStep`), `seed` once before Newton iteration 1
//! (`Circuit.zig`'s `seedJunctions`).
//!
//! `eval` still renders the STRING form of `$limit` as the IDENTITY of its
//! probe, and that is not a gap — it is the other half of this design. The host
//! clamps `x` BEFORE it calls `eval`, so the probe the body reads is already
//! the limited value. Applying the clamp a second time inside `eval` would
//! limit against the wrong `x_old` and break the Jacobian's agreement with the
//! residual.
//!
//! §9.17.3's USER-FUNCTION form is not this file's: nothing here can honour it,
//! because the limiter is Verilog-A the model wrote and the clamp list has no
//! way to call it. It is lowered instead — `Lower.lowerLimitUser` inlines the
//! function inside `eval` with a per-access-function previous-iterate slot, and
//! restores the probe's derivative on the way out (codegen's `zLimitUf`). The
//! two forms coexist in one module and share nothing but the spelling.
//!
//! WHY A WRITE-BACK INTO `x` AND NOT A CLAMPED LOCAL. SPICE limits the branch
//! voltage inside the load routine and never touches the node voltages; the
//! contract instead has the device return a corrected `x`. The two agree when
//! the correction lands on the unknown that is not shared with the rest of the
//! circuit — see `sides` — and only the contract's shape lets the engine keep
//! ONE limited solution vector that `eval`, `q` and the convergence test all
//! read. That is why `converged` is a device verdict and not a host guess.
//!
//! The limiters themselves are `backend/limit_kernels.zig`, `@embedFile`d by
//! codegen (`limit_txt`) and `@import`ed by its tests — one source, so the
//! shapes the tests pin are the shapes the device runs. They were a string
//! literal here until wave 10, which is why nothing could call them.
//!
//! Free functions over `*Gen`, like `cg_display.zig` and `cg_filters.zig`:
//! Zig cannot extend a struct across files.

const std = @import("std");
const Mir = @import("../ir/mir.zig");
const Analysis = @import("../ir/analysis.zig");
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;

const none_u32 = std.math.maxInt(u32);

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
    fn arity(a: Alg) usize {
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
    /// The algorithm's numeric arguments as MIR values. `collect` queues these
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

// ----------------------------------------------------------------- collect

/// Resolve every `$limit` call. Runs in `prepare` BEFORE `buildJobs`, which
/// queues `argv` into the shared core.
pub fn collect(g: *Gen) Error!void {
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
            if (!std.mem.eql(u8, d.name, "$limit")) continue;

            const alg = algOf(g, d.args) orelse continue; // §4.5.15 declining is conformant
            const pair = probePair(g, d.args) orelse {
                try decline(g, &declined, d.args, "its first argument is not a §4.4 potential probe of one or two nets");
                continue;
            };
            if (!g.an.dominates(bi, exit)) {
                try decline(g, &declined, d.args, "it is under an `if`, and the clamp list carries no control flow");
                continue;
            }
            if (!writable(g, pair[0]) and !writable(g, pair[1])) {
                try decline(g, &declined, d.args, "both nets are §6.5 ports, which the host masks — there is nothing private to correct");
                continue;
            }
            const n = alg.arity();
            if (d.args.len < 2 + n) {
                try decline(g, &declined, d.args, "too few arguments for the algorithm named");
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
                try decline(g, &declined, d.args, "an algorithm argument is not real-valued");
                continue;
            }
            try out.append(g.arena, lc);
        }
    }
    g.limits = out.items;

    // A `fetlimds` site is only honoured as a member of a COMPLETE mode
    // ladder — dangling, it would clamp one leg with no frame authority,
    // which is the static-order bug the algorithm exists to fix. The mask is
    // computed over the unfiltered list first: validity is symmetric (both
    // legs check both `lo`s, a >2-way gate share fails every member), so
    // dropping the invalid sites never invalidates a surviving one.
    var any_dangling = false;
    for (g.limits, 0..) |lc, i| {
        if (lc.alg == .fetlimds and ladderOf(g, i) == null) any_dangling = true;
    }
    if (any_dangling) {
        const keep = try g.arena.alloc(bool, g.limits.len);
        for (g.limits, 0..) |lc, i| {
            keep[i] = lc.alg != .fetlimds or ladderOf(g, i) != null;
            if (!keep[i]) try declineLc(g, &declined, lc, "no complete mode ladder — it needs a second fetlimds site on the same gate node and a limvds site across the two channel nodes, all channel sides internal");
        }
        var w_: usize = 0;
        for (out.items, 0..) |lc, i| {
            if (!keep[i]) continue;
            out.items[w_] = lc;
            w_ += 1;
        }
        g.limits = out.items[0..w_];
    }
    g.limits_declined = declined.items;
}

fn declineLc(g: *Gen, list: *std.ArrayList([]const u8), lc: LimitCall, why: []const u8) Error!void {
    try list.append(g.arena, try std.fmt.allocPrint(g.arena, "$limit(V({s},{s}), \"{t}\"): {s}", .{ uName(g, lc.hi), uName(g, lc.lo), lc.alg, why }));
}

/// A resolved mode ladder: indices into `g.limits` of the vgs leg, the vgd
/// leg, and the `limvds` site whose probe orients them — `limvds` reads
/// V(di,si), so the leg landing on its `lo` is the source leg (vgs) and the
/// one landing on its `hi` is the drain leg (vgd).
const Ladder = struct { gs: u32, gd: u32, ds: u32 };

/// The ladder `g.limits[i]` (a `fetlimds` site, either leg) belongs to:
/// exactly two `fetlimds` sites share its first-named node (the gate), one
/// `limvds` site spans their second-named nodes (the channel), and both
/// channel nodes are the device's own to correct. Null otherwise. Derived on
/// demand — collect and emit ask the same question of the same list, so
/// storing the answer could only let the two fall out of agreement.
fn ladderOf(g: *const Gen, i: usize) ?Ladder {
    const me = g.limits[i];
    var partner: usize = undefined;
    var gate_legs: usize = 0;
    for (g.limits, 0..) |lc, j| {
        if (lc.alg != .fetlimds or lc.hi != me.hi) continue;
        gate_legs += 1;
        if (j != i) partner = j;
    }
    if (gate_legs != 2) return null;
    const other = g.limits[partner];
    if (!writable(g, me.lo) or !writable(g, other.lo)) return null;
    for (g.limits, 0..) |lc, k| {
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
fn limvdsClaimed(g: *const Gen, k: usize) bool {
    for (g.limits, 0..) |lc, i| {
        if (lc.alg != .fetlimds) continue;
        const lad = ladderOf(g, i) orelse continue;
        if (lad.ds == k) return true;
    }
    return false;
}

fn decline(g: *Gen, list: *std.ArrayList([]const u8), args: []const Mir.Value, why: []const u8) Error!void {
    try list.append(g.arena, try std.fmt.allocPrint(g.arena, "{s}: {s}", .{ spell(g, args), why }));
}

/// `$limit(V(a,b), "alg")` as it reads in the source, for the declined list.
fn spell(g: *Gen, args: []const Mir.Value) []const u8 {
    const alg: []const u8 = if (args.len >= 2) switch (g.mir.valueDef(g.an.rv(args[1]))) {
        .str_const => |s| s,
        else => "?",
    } else "?";
    const pair = probePair(g, args);
    const hi: []const u8 = if (pair) |p| uName(g, p[0]) else "?";
    const lo: []const u8 = if (pair) |p| uName(g, p[1]) else "?";
    return std.fmt.allocPrint(g.arena, "$limit(V({s},{s}), \"{s}\")", .{ hi, lo, alg }) catch "$limit(…)";
}

fn uName(g: *const Gen, u: u32) []const u8 {
    return if (u == none_u32) "0" else g.u_names[u];
}

/// §4.4 `V(a,b)` lowers to `fsub` of two probes and `V(a)` to a bare probe
/// (mir.zig:420-422). Anything else — a flow probe, an expression — has no
/// node pair to correct.
fn probePair(g: *const Gen, args: []const Mir.Value) ?[2]u32 {
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
        else => return null,
    };
    // §5.4.2 a branch-flow unknown is an ampere. These limiters are voltage
    // clamps; writing one back as if it were a potential is nonsense.
    for (pair) |u| {
        if (u != none_u32 and g.isFlowUnknown(u)) return null;
    }
    return pair;
}

fn algOf(g: *const Gen, args: []const Mir.Value) ?Alg {
    // §4.5.15 bare `$limit(V(a,b))` asks for the simulator's own choice of
    // algorithm. Ours is none: inventing a clamp the model did not name would
    // change its answers with no way to say so in the source.
    if (args.len < 2) return null;
    const s = switch (g.mir.valueDef(g.an.rv(args[1]))) {
        .str_const => |s| s,
        // §9.17.3 also allows a user analog function here. That is a call, not
        // a string, and it needs the whole body — handled in lowering
        // (`Lower.lowerLimitUser`), so it never reaches the clamp list.
        else => return null,
    };
    return std.meta.stringToEnum(Alg, s);
}

/// Can the device correct this unknown? Only its own internal nets: the host
/// masks writes to §6.5 ports, because a limiter moving a driven or shared
/// node fights the sources and the other devices on it (`contract.zig`'s
/// note on `limit`).
fn writable(g: *const Gen, u: u32) bool {
    return u != none_u32 and u >= g.lower.num_ports;
}

// -------------------------------------------------------- the live sets

/// Which unknowns `limit` actually touches. `reads` is every `cur[u]`/`old[u]`
/// the emitted body loads, `writes` every `x[u]` it (or `seed`) can store.
///
/// WHY THE HOST WANTS THIS. `limit`'s signature is `[n_u]f64` twice in and
/// `[n_u]f64` out because the host cannot name a device's unknowns, but a MOS
/// ladder reads four of eight and writes two: `d`, `s` and the two branch-flow
/// unknowns pass straight through, and without a mask the host gathers them
/// from `x`, copies them across `limit`'s frame and stores them back into
/// `lim_x` once per instance per Newton iterate to arrive at the value they
/// already had. ngspice has no such traffic — its limiter memory is the three
/// BRANCH voltages in `CKTstate0`, not every node the device touches.
///
/// Both masks are SUPERSETS by construction and must stay that way: a missing
/// `reads` bit hands the clamp an undefined probe, a missing `writes` bit
/// silently drops a limit. `unionSite` mirrors `emitClamp`/`emitLadder`
/// site for site, so the two go stale together or not at all.
const Live = struct { reads: u64 = 0, writes: u64 = 0 };

fn ubit(u: u32) u64 {
    return if (u == none_u32) 0 else @as(u64, 1) << @intCast(u);
}

fn unionSite(lv: *Live, g: *const Gen, lc: LimitCall) void {
    lv.reads |= ubit(lc.hi) | ubit(lc.lo);
    lv.writes |= ubit(if (writable(g, lc.lo)) lc.lo else lc.hi);
}

pub fn liveSets(g: *const Gen) Live {
    var lv: Live = .{};
    // A core re-entry is seeded from EVERY entry of `cur` (`emit`'s `xr` loop),
    // and n_u > 64 has no room in the mask — both answer "all of them".
    if (usesCore(g) or g.n_u > 64) lv.reads = ~@as(u64, 0);
    for (g.limits, 0..) |lc, i| switch (lc.alg) {
        .fetlimds => {
            const lad = ladderOf(g, i).?;
            if (i != @min(lad.gs, lad.gd)) continue;
            // The two mode arms unioned: the shared gate is read, and both
            // channel nodes are read AND written (which one takes the fetlim
            // correction and which the limvds one swaps with the mode).
            const gs = g.limits[lad.gs];
            const gd = g.limits[lad.gd];
            lv.reads |= ubit(gs.hi) | ubit(gs.lo) | ubit(gd.lo);
            lv.writes |= ubit(gs.lo) | ubit(gd.lo);
        },
        .limvds => if (!limvdsClaimed(g, i)) unionSite(&lv, g, lc),
        else => unionSite(&lv, g, lc),
    };
    // `seed` corrects the same node `emitClamp` does, but OR it in rather than
    // rely on that: the host initialises `lim_x` through `seed` and reads it
    // back through `limit`, so a bit in one and not the other is a stale slot.
    for (g.limits) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        lv.writes |= ubit(if (writable(g, lc.lo)) lc.lo else lc.hi);
    }
    lv.reads |= lv.writes;
    return lv;
}

// ------------------------------------------------------------- the prep

/// Memo for `scValue`/`scBlock`.
///
/// FOUR states and not three. `pcClass` gets away with three because it refuses
/// every `phi`, so its value graph is a DAG and a plain visit mark suffices.
/// This one admits phis, so the graph can carry a §5.9 loop — and marking a
/// node `.no` on entry to break the cycle ALSO fails every second path into a
/// shared node, which is the common case in an SSA DAG. MEASURED: it dropped
/// mos1 from 6 hoisted arguments to 2 and moved the reported failure around
/// depending on visit order. `busy` is the cycle break and is never cached.
const ScCls = enum(u8) { unknown, busy, no, yes };

/// Scratch for one `planPrep`: per-Value and per-Block answers, shared across
/// every clamp argument because solve-constancy is a property of the MIR, not
/// of which argument asked.
const Sc = struct {
    g: *Gen,
    val: []ScCls,
    blk: []ScCls,
    /// `scBlock`'s backward-reachability mark. Reused per query and never held
    /// across a recursive call — see `scBlock`.
    seen: []bool,
};

/// Recursion cap, a sound fail-safe: `false` never hoists.
const sc_depth_max: u32 = 2048;

/// Is `v0` the SAME at every Newton iterate and every time point — so that
/// evaluating it once, at x = 0, IS evaluating it?
///
/// MEASURED MOTIVE (ARPice callgrind): `limit` runs the WHOLE model core for a
/// handful of scalars — 25.7% of scaling/parallel_inverters_100's total
/// instructions, ~13% of tran/fourbitadder, 1 820 instructions per instance per
/// Newton iteration. LLVM does not recover it: `core` is shared with
/// `eval`/`q`/`updateState`, and its `h[]` hoist array is written across a CFG
/// that dead-code elimination has to SROA through first.
///
/// THIS IS `pcClass` (codegen.zig) PLUS CONTROL FLOW. That one asks whether the
/// FLAT precompute body can RE-SPELL the value, so a `phi` is fatal there — and
/// a phi is exactly where 12 of the 16 `$limit` devices in the ARPice corpus
/// keep their `vcrit`: mos1's `h[20]` is the js/ad/as arm of block B43, mos6's
/// is `h[17]`, diode's is `h[9]`. Hoisting on `pcClass` alone would have
/// covered bjt, jfet2, mesa and vdmos and left every MOS level behind.
/// `emitPrep` runs the REAL core, so control flow costs nothing to EMIT; what
/// it costs is a proof obligation, and that is the `.phi` arm below.
///
/// NOT `UnitPlan.analyze`, which was tried first and is the wrong question. It
/// answers "what must this unit EMIT", so its fixpoint marks every branch
/// condition the unit's CFG scaffolding reaches — MEASURED: it poisoned bjt's
/// `$vt` with the conditions of blocks 49 and 51, the excess-phase
/// `if (td == 0.0)` diamonds, which no dataflow connects to `$vt` at all.
fn scValue(sc: *Sc, v0: Mir.Value, depth: u32) bool {
    const g = sc.g;
    const v = g.an.rv(v0);
    const i = @intFromEnum(v);
    switch (sc.val[i]) {
        .yes => return true,
        .no => return false,
        .busy => return false, // a §5.9 loop back edge: pessimistic, not cached
        .unknown => {},
    }
    if (depth > sc_depth_max) return false;
    sc.val[i] = .busy;
    const ok: bool = switch (g.mir.valueDef(v)) {
        .undef, .float_const, .int_const => true,
        // §4.4 access functions ARE the bias. A string cannot feed a clamp.
        .str_const, .block_param => false,
        .param_ref => |p| Analysis.tyOfParam(g.lower.params.items[p].ty) != .str,
        .inst_result => |inst| blk: {
            const row = g.mir.instRow(inst);
            switch (row.op) {
                // Every environment query `precompute` can already answer, and
                // nothing else: it runs before `$abstime` has a value, before
                // gmin stepping has picked a `$simparam("gmin")`, and before any
                // §4.5 operator has state.
                //
                // `pcClass`'s list plus §9.19 `$param_given` — which is not a
                // widening on the risk side. It renders as
                // `@intFromBool(model.<p>__given)` (`renderValueRef`'s param
                // arm), a plain `Model` field the netlist parser writes with the
                // card, so it is exactly as constant as the parameter it reports
                // on, and `precompute` re-runs on every card write.
                //
                // Leaving it out was MEASURED, not theoretical: it rejected
                // `vt`, `vcrit` and `vto` on every MOS level, because the
                // tox/nsub/js/ad guards that select them are spelled
                // `$param_given` — mos1 hoisted 1 of its 6 clamp arguments.
                //
                // `$temperature`/`$vt` only in their zero-argument forms, so no
                // unchecked argument can slip past the operand walk.
                .call => {
                    const d = g.mir.instData(inst).call;
                    break :blk std.mem.eql(u8, d.name, "$param_given") or
                        std.mem.eql(u8, d.name, "$temperature") or
                        (std.mem.eql(u8, d.name, "$vt") and d.args.len == 0);
                },
                // §5.6.1.2 path latches: `updateState`/commit have not written
                // them when `precompute` runs.
                .path_prev, .path_acc, .branch, .jump => break :blk false,
                // §4.2.12 the condition steers this one, so it is an operand.
                .select => {
                    const d = g.mir.instData(inst).ternary;
                    break :blk scValue(sc, d.cond, depth + 1) and
                        scValue(sc, d.then_val, depth + 1) and
                        scValue(sc, d.else_val, depth + 1);
                },
                // A phi is the CFG's `select`: its arms are operands and the
                // branches that can reach its block are its condition.
                .phi => {
                    const d = g.mir.instData(inst).phi;
                    var k: u32 = 0;
                    while (k < d.count) : (k += 1) {
                        if (!scValue(sc, g.mir.phiPair(inst, k).value, depth + 1))
                            break :blk false;
                    }
                    const b = g.an.def_block[i];
                    break :blk b != none_u32 and scBlock(sc, b, depth + 1);
                },
                else => switch (Mir.opClass(row.op)) {
                    .unary => break :blk scValue(sc, @enumFromInt(row.a), depth + 1),
                    .binary => break :blk scValue(sc, @enumFromInt(row.a), depth + 1) and
                        scValue(sc, @enumFromInt(row.b), depth + 1),
                    else => break :blk false,
                },
            }
        },
    };
    sc.val[i] = if (ok) .yes else .no;
    return ok;
}

/// Can anything bias-dependent decide whether block `b` was entered by one
/// predecessor rather than another?
///
/// A branch that CANNOT REACH `b` cannot steer a phi there, so the obligation is
/// exactly the branches that can — a backward walk over `preds` from `b`. That
/// is sound without a control-dependence pass (it is a superset of the control
/// dependences of `b`) and it is tight in practice because a Verilog-A compact
/// model puts its whole temperature/geometry prelude BEFORE the first probe:
/// mos1's `vcrit` lives in block B43, and every bias-dependent branch in mos1 is
/// downstream of it.
///
/// `b`'s OWN terminator is not one of them, which is why the walk is seeded
/// from `preds[b]` rather than from `b`: a phi executes on ENTRY to its block,
/// before the branch that leaves it. Harvesting `term[b]` also makes the block
/// its own guard, so `scValue` on that condition re-enters here, reads `.busy`
/// and fails — MEASURED, it rejected every phi in every device.
///
/// `seen` is scratch and must not be live across the `scValue` recursion below,
/// which re-enters here — so the reaching conditions are collected FIRST and
/// checked after.
fn scBlock(sc: *Sc, b: u32, depth: u32) bool {
    switch (sc.blk[b]) {
        .yes => return true,
        .no => return false,
        .busy => return false, // re-entered through a guard's own phi
        .unknown => {},
    }
    if (depth > sc_depth_max) return false;
    sc.blk[b] = .busy;
    const g = sc.g;

    @memset(sc.seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(g.arena);
    sc.seen[b] = true;
    for (g.an.preds[b]) |p0| {
        if (sc.seen[p0]) continue;
        sc.seen[p0] = true;
        stack.append(g.arena, p0) catch {
            sc.blk[b] = .no;
            return false;
        };
    }
    var conds: std.ArrayList(Mir.Value) = .empty;
    defer conds.deinit(g.arena);
    while (stack.pop()) |cur| {
        const t = g.an.term[cur];
        if (t != .none and g.mir.instOp(t) == .branch)
            conds.append(g.arena, g.mir.instData(t).branch.cond) catch {
                sc.blk[b] = .no; // OOM: `false` never hoists, same as the depth cap
                return false;
            };
        for (g.an.preds[cur]) |p| {
            if (sc.seen[p]) continue;
            sc.seen[p] = true;
            stack.append(g.arena, p) catch {
                sc.blk[b] = .no;
                return false;
            };
        }
    }
    for (conds.items) |c| {
        if (!scValue(sc, c, depth + 1)) {
            sc.blk[b] = .no;
            return false;
        }
    }
    sc.blk[b] = .yes;
    return true;
}

/// Which clamp arguments become `Instance.lp__<k>`. Runs at the END of
/// `prepare` — it needs `lo_idx` filled to name the core field `emitPrep` reads
/// each one out of, and it hands `writeArg`, `usesCore` and `emitInstance`
/// their answer.
///
/// It walks the raw MIR, not `plan`: a value read out of the core's cache or
/// out of a `pc__` field is a LEAF to a unit body but not to a proof, and
/// stopping there would prove nothing about its operands.
///
/// Field ORDER is the source order of the sites, argv before sign, which is the
/// same insert-tolerance rule the `pc__` and held-variable blocks follow: a
/// model that gains a `$limit` appends fields, it renumbers none.
pub fn planPrep(g: *Gen) Error!void {
    g.lp_idx = try g.arena.alloc(u32, g.an.nv);
    @memset(g.lp_idx, none_u32);
    if (g.limits.len == 0) return;

    var sc: Sc = .{
        .g = g,
        .val = try g.arena.alloc(ScCls, g.an.nv),
        .blk = try g.arena.alloc(ScCls, g.an.nb),
        .seen = try g.arena.alloc(bool, g.an.nb),
    };
    @memset(sc.val, .unknown);
    @memset(sc.blk, .unknown);

    var vals: std.ArrayList(Mir.Value) = .empty;
    for (g.limits) |lc| {
        for ([_]Mir.Value{ lc.argv[0], lc.argv[1], lc.sign }) |v0| {
            if (v0 == .f_zero) continue;
            const v = g.an.rv(v0);
            const i = @intFromEnum(v);
            if (g.lp_idx[i] != none_u32) continue;
            if (!scValue(&sc, v, 0)) continue;
            g.lp_idx[i] = @intCast(vals.items.len);
            try vals.append(g.arena, v);
        }
    }
    g.lp_vals = vals.items;
}

/// The prep body, appended to `precompute` AFTER the `pc__` writes — the core
/// reads those fields, so they have to be there first.
///
/// ONE core evaluation per instance per model-card/temperature write, in place
/// of one per instance per Newton iteration. It is `seed`'s own argument,
/// generalised: the core at x = 0 is not an approximation of these values, it
/// IS them (`solveConst`).
pub fn emitPrep(g: *Gen) Error!void {
    if (g.lp_vals.len == 0) return;
    try g.w(
        \\    // §4.5.15 the clamp arguments, hoisted out of the per-iterate
        \\    // `limit`: every one is solve- and time-independent, so the core's
        \\    // value at x = 0 is its value at every iterate.
        \\    var xr: [n_u]R = undefined;
        \\    for (&xr) |*p| p.* = R.con(0.0);
        \\    const m = core(R, xr, model, inst);
        \\
    , .{});
    for (g.lp_vals, 0..) |v, k| {
        const i = @intFromEnum(v);
        const f = g.lo_idx[i];
        std.debug.assert(f != none_u32); // `buildJobs` queues every argv and sign
        // An integer core field (a `parameter integer` polarity) is a bare i64.
        // It is read ONLY through `< 0` sign tests (`emitClamp`'s `sg`,
        // `writeSign`'s `sgt`, `emitSeed`'s arm select), and i64→f64 rounding
        // never crosses zero, so the widening is exact where it is used.
        if (g.an.vty[i] == .int)
            try g.w("    inst.lp__{d} = @floatFromInt(m.f{d});\n", .{ k, f })
        else
            try g.w("    inst.lp__{d} = m.f{d}.v;\n", .{ k, f });
    }
}

/// The differential case for `emitPrep`, against its own scalar oracle: the
/// SAME clamp arguments taken live out of the core at a NON-ZERO iterate —
/// which is the evaluation `limit` used to run for itself, per instance, per
/// Newton iteration.
///
/// `scValue`'s claim is that the two are identical, so the assertion is on the
/// BIT PATTERN and not on a tolerance. It is the same instruction sequence over
/// the same inputs, differing only in an `x` the proof says cannot reach these
/// values; a tolerance here would hide exactly the thing under test. Bits also
/// compare NaN correctly, which matters because a default model card can leave
/// a `log` of zero in an unrelated arm of the core.
///
/// Emitted into the device rather than into a `tb.zig` runner because that
/// runner is fixture-directive-driven and never runs for a host's own models —
/// this way the ARPice `test-devices` step, which compiles every generated
/// device, runs it for all 16 devices that have a `$limit`.
///
/// The fill gives each unknown a DIFFERENT voltage with an alternating sign, so
/// V(a,b) is nowhere identically zero and every bias-dependent branch in the
/// core gets flipped across the sweep. A uniform fill would leave every probe
/// at 0 and prove nothing.
///
/// The sign local is spelled `flip`, and this note lives HERE rather than in the
/// emitted text: the unsigned half of "codegen: §4.5.15 signed $limit clamps
/// sign*v" asserts the substring `sg` appears NOWHERE in the generated file, so
/// a variable — or a comment — naming it fails that test from three functions
/// away.
fn emitPrepTest(g: *Gen) Error!void {
    if (g.lp_vals.len == 0) return;
    try g.w(
        \\test "§4.5.15 `$limit` prep ≡ the live core at a non-zero iterate" {{
        \\    var model: Model = .{{}};
        \\    // NAMESPACED, like tb.zig's runner: `@hasDecl` gates the branch but
        \\    // an unqualified identifier still has to resolve, so a bare
        \\    // `derive(&model)` is a hard error on the models that have none.
        \\    if (comptime @hasDecl(Self, "derive")) Self.derive(&model);
        \\    var inst: Instance = .{{}};
        \\    inst.temperature = 300.15;
        \\    precompute(&inst, &model);
        \\    for (0..16) |trial| {{
        \\        var xr: [n_u]R = undefined;
        \\        for (&xr, 0..) |*p, u| {{
        \\            const flip: f64 = if ((trial + u) % 2 == 0) 1.0 else -1.0;
        \\            p.* = R.con(flip * (0.25 * @as(f64, @floatFromInt(u + 1)) +
        \\                @as(f64, @floatFromInt(trial))));
        \\        }}
        \\        const m = core(R, xr, &model, &inst);
        \\
    , .{});
    for (g.lp_vals, 0..) |v, k| {
        const i = @intFromEnum(v);
        const f = g.lo_idx[i];
        if (g.an.vty[i] == .int)
            try g.w("        try expectPrepBits(inst.lp__{d}, @floatFromInt(m.f{d}));\n", .{ k, f })
        else
            try g.w("        try expectPrepBits(inst.lp__{d}, m.f{d}.v);\n", .{ k, f });
    }
    try g.w(
        \\    }}
        \\}}
        \\
        \\/// Bit equality, so a NaN clamp argument compares equal to itself and a
        \\/// one-ulp drift is a failure rather than a rounding anecdote.
        \\fn expectPrepBits(got: f64, want: f64) !void {{
        \\    try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
        \\}}
        \\
        \\
    , .{});
}

// -------------------------------------------------------------------- emit

/// Does any clamp read a value out of the shared core AT CLAMP TIME? Three ways
/// not to: `limvds` takes no arguments, an unsigned site has no sign, and — the
/// case that matters — `planPrep` proved the argument solve-constant and
/// `precompute` already latched it into `Instance.lp__<k>`.
pub fn usesCore(g: *const Gen) bool {
    for (g.limits) |lc| {
        if (needsCore(g, lc.sign)) return true;
        for (lc.argv[0..lc.alg.arity()]) |v| {
            if (needsCore(g, v)) return true;
        }
    }
    return false;
}

/// `seed`'s narrower question: it reads only each pnjlim site's `vcrit` and
/// that site's sign.
fn seedUsesCore(g: *const Gen) bool {
    for (g.limits) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        if (needsCore(g, lc.argv[1]) or needsCore(g, lc.sign)) return true;
    }
    return false;
}

/// One argument: is it still a core live-out read, rather than a prep field?
fn needsCore(g: *const Gen, v0: Mir.Value) bool {
    if (v0 == .f_zero) return false;
    return g.lp_idx[@intFromEnum(g.an.rv(v0))] == none_u32;
}

/// Does the `$limit` family evaluate the core ANYWHERE — so the file needs `R`?
/// True whenever a clamp reads it live, and true whenever `emitPrep` exists,
/// because that is a core evaluation too (one per reprep, not one per iterate,
/// which is the whole point).
pub fn needsR(g: *const Gen) bool {
    return usesCore(g) or g.lp_vals.len != 0;
}

pub fn emit(g: *Gen) Error!void {
    if (g.limits_declined.len != 0) {
        try g.w("// §4.5.15 `$limit` DECLINED at {d} call site(s) — the probe is\n", .{g.limits_declined.len});
        try g.w("// returned unchanged there, which §4.5.15 permits:\n", .{});
        for (g.limits_declined) |d| try g.w("//   - {s}\n", .{d});
        try g.w("\n", .{});
    }
    if (g.limits.len == 0) return;

    const needs_core = usesCore(g);
    // A prep field is an `inst.lp__k` read, so `inst` stays named even when the
    // core call is gone. `model` goes with the core.
    const reads_inst = needs_core or g.lp_vals.len != 0;
    try g.w(
        \\/// §4.5.15 `$limit`: SPICE voltage limiting, applied by the host between
        \\/// the linear solve and the next `eval`.
        \\///
        \\/// The clamps run in SOURCE ORDER and each reads the `x` the previous one
        \\/// left, because that is both the order the model wrote them in and the
        \\/// order ngspice's load routines apply them (fetlim → limvds → pnjlim on
        \\/// a JFET). Each clamp has ONE writer — the second-named node — so
        \\/// clamps that share their first-named node cannot fight (emitClamp
        \\/// says why a split breaks a BJT). A `fetlimds` pair and its `limvds`
        \\/// emit as ONE mode-swapped rung at the pair's source position: the leg
        \\/// that controls the channel in the OLD vds sign is clamped and the
        \\/// other derived, exactly ngspice's MOS ladder (emitLadder).
        \\
    , .{});
    try g.w("pub fn limit({s}: *const Model, {s}: *const Instance, cur: [n_u]f64, old: [n_u]f64) contract.LimitResult(n_u) {{\n", .{
        if (needs_core) "model" else "_",
        if (reads_inst) "inst" else "_",
    });
    if (needs_core) try g.w(
        \\    var xr: [n_u]R = undefined;
        \\    for (cur, 0..) |xv, i| xr[i] = R.con(xv);
        \\    const m = core(R, xr, model, inst);
        \\
    , .{});
    try g.w("    var x = cur;\n", .{});
    // Only `pnjlim` ever reports non-convergence, so a fetlim/limvds-only
    // device has nothing to track and `var ok` would never be mutated.
    var any_pnjlim = false;
    for (g.limits) |lc| any_pnjlim = any_pnjlim or lc.alg == .pnjlim or lc.alg == .steplim;
    if (any_pnjlim) try g.w("    var ok = true;\n", .{});
    try emitSigns(g);
    for (g.limits, 0..) |lc, i| switch (lc.alg) {
        // Collect kept only complete ladders; the earlier leg speaks for all
        // three sites, the partner and the claimed limvds stay silent.
        .fetlimds => {
            const lad = ladderOf(g, i).?;
            if (i == @min(lad.gs, lad.gd)) try emitLadder(g, lad);
        },
        .limvds => if (!limvdsClaimed(g, i)) try emitClamp(g, lc),
        else => try emitClamp(g, lc),
    };
    try g.w("    return .{{ .x = x, .converged = {s} }};\n}}\n\n", .{if (any_pnjlim) "ok" else "true"});

    const lv = liveSets(g);
    try g.w(
        \\/// Which unknowns `limit` and `seed` touch — `limit_reads` every
        \\/// `cur`/`old` entry the body loads, `limit_writes` every `x` entry it
        \\/// can store. Both are supersets. A host that gathers, copies and
        \\/// writes back all `n_u` spends that traffic on unknowns the ladder
        \\/// never looks at; ngspice's limiter memory is the branch voltages in
        \\/// `CKTstate0`, not every node the device touches.
        \\
    , .{});
    try g.w("pub const limit_reads: u64 = 0x{x};\npub const limit_writes: u64 = 0x{x};\n\n", .{ lv.reads, lv.writes });

    try emitSeed(g);
    try emitPrepTest(g);
}

/// `const zsg__k: f64 = ±1.0` for each DISTINCT frame sign, once at the top of
/// `limit`. Every clamp on a MOSFET reads the same `type` parameter, so without
/// this the compare-and-select is re-emitted three or four times per body over
/// a latched `inst.lp__k` that cannot have changed between them (measured: 8 Ir
/// per MOSFET per Newton iterate on mos1, 5 of them recoverable). Named from
/// the MIR value so `signOf` needs no shared state.
fn emitSigns(g: *Gen) Error!void {
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(g.gpa);
    // MIRRORS `emit`'s dispatch site for site. A claimed `limvds` emits no
    // clamp of its own but IS the ladder's channel rung, so its sign is still
    // referenced; a const with no reference is a Zig compile error, and one
    // referenced but not emitted is worse.
    for (g.limits, 0..) |lc, i| switch (lc.alg) {
        .fetlimds => {
            const lad = ladderOf(g, i).?;
            if (i != @min(lad.gs, lad.gd)) continue;
            try oneSign(g, &seen, g.limits[lad.gs].sign);
            try oneSign(g, &seen, g.limits[lad.gd].sign);
            try oneSign(g, &seen, g.limits[lad.ds].sign);
        },
        .limvds => if (!limvdsClaimed(g, i)) try oneSign(g, &seen, lc.sign),
        else => try oneSign(g, &seen, lc.sign),
    };
}

fn oneSign(g: *Gen, seen: *std.ArrayList(u32), v: Mir.Value) Error!void {
    if (v == .f_zero) return;
    const k = signKey(g, v);
    for (seen.items) |s| if (s == k) return;
    try seen.append(g.gpa, k);
    try g.w("    const zsg__{d}: f64 = if (", .{k});
    try writeArg(g, v);
    try g.w(" < 0) -1.0 else 1.0;\n", .{});
}

fn signKey(g: *const Gen, v: Mir.Value) u32 {
    return @intFromEnum(g.an.rv(v));
}

fn emitClamp(g: *Gen, lc: LimitCall) Error!void {
    const signed = lc.sign != .f_zero;
    try g.w("    {{ // $limit(V({s},{s}), \"{t}\"){s}\n", .{
        uName(g, lc.hi), uName(g, lc.lo), lc.alg,
        if (signed) " in the frame of its sign argument" else "",
    });
    try g.w("        const vn = ", .{});
    try writeProbe(g, lc, "x");
    try g.w(";\n        const vo = ", .{});
    try writeProbe(g, lc, "old");
    try g.w(";\n", .{});
    if (signed) {
        // ±1 recovered from the model value: the limiters assume forward =
        // positive, so the clamp runs on sg·v and hands back sg·result.
        //
        // `limvds` alone frames on the OLD vds sign, not the sign argument:
        // ngspice's loads branch on `vdsold >= 0` (mos1load: `vds =
        // -DEVlimvds(-vds, -vdsold)` in inverse mode), which in raw node
        // coordinates is sign(vo). Framing on device type instead pinned an
        // inverted-mode FET at DEVlimvds's absolute -0.5 bound — a clamp
        // that is NOT fixed-point-preserving, so it moved the converged
        // solution, not just the trajectory (2.1x drain current at vds=-5).
        if (lc.alg == .limvds) {
            try g.w("        const sg: f64 = if (vo < 0) -1.0 else if (vo > 0) 1.0 else zsg__{d};\n", .{signKey(g, lc.sign)});
        } else {
            try g.w("        const sg: f64 = zsg__{d};\n", .{signKey(g, lc.sign)});
        }
    }
    try g.w("        const vl = {s}z{s}({s}vn, {s}vo", .{
        if (signed) "sg * " else "",
        switch (lc.alg) {
            .pnjlim => @as([]const u8, "Pnjlim"),
            .fetlim => "Fetlim",
            .limvds => "Limvds",
            .fetlimds => unreachable, // emitLadder owns every surviving site
            .steplim => "Steplim",
        },
        if (signed) "sg * " else "",
        if (signed) "sg * " else "",
    });
    for (lc.argv[0..lc.alg.arity()]) |v| {
        try g.w(", ", .{});
        try writeArg(g, v);
    }
    try g.w(");\n", .{});

    // SINGLE WRITER, never a split. Junctions share nodes — a BJT's vbe and
    // vbc clamps both span `bi`, and a diode-connected device gathers b and c
    // from ONE global node — so a dv/2 split makes sequential clamps fight
    // through the shared side and the final frame satisfies neither probe
    // (observed: a 12 V rail's local image dragged to −43 V, junction read
    // +72 V, e^80 residual). Anchoring the FIRST-named node and writing the
    // whole correction to the second keeps every probe exactly its limited
    // value: model authors put the shared side first (V(bi,ei), V(b,si)),
    // which is also ngspice's frame (vbe state hangs off the emitter side).
    const w_lo = writable(g, lc.lo);
    if (w_lo) {
        try g.w("        x[@intFromEnum(U.{s})] -= vl - vn;\n", .{g.u_names[lc.lo]});
    } else {
        try g.w("        x[@intFromEnum(U.{s})] += vl - vn;\n", .{g.u_names[lc.hi]});
    }
    // ngspice reports `icheck` from `DEVpnjlim` alone, and sets it exactly on
    // the paths where it moved `vnew` — so "the value changed" IS the flag,
    // with no out-parameter. `fetlim`/`limvds` have no such flag: their clamps
    // are trajectory shaping, not a statement about the residual. `steplim`
    // reports like pnjlim — ngspice's B4SOIlimit sets Check=1 on every clamp.
    if (lc.alg == .pnjlim or lc.alg == .steplim) try g.w("        if (vl != vn) ok = false;\n", .{});
    try g.w("    }}\n", .{});
}

/// One `fetlimds` pair + its `limvds`, emitted as ngspice's MOS gate ladder
/// (mos1load.c:351-373): branch on the sign of the OLD vds — the limiter's
/// own memory, and exactly the condition the load's mode select reads — clamp
/// the CONTROLLING gate leg, re-clamp the channel, derive the other leg. In
/// node coordinates "derive the other" is a write-target choice: correcting
/// the source-side node moves vgs and vds together and leaves vgd (normal
/// mode's fetlim, inverse mode's limvds); correcting the drain-side node
/// moves vgd and vds and leaves vgs (the other two rungs). And vgdo needs no
/// storage of its own: old[g]−old[di] IS vgso−vdso, the derivation ngspice
/// spells by hand off its vgs/vds states.
///
/// The channel rung fixes the same frame the standalone `limvds` clamp
/// recovers from sign(vo) (the f4cd9cc rule): the mode branch already knows
/// it — `sgt` in the normal arm, `-sgt` in the inverse arm, ngspice's
/// `vds = -DEVlimvds(-vds,-vdso)` — and adds the write target the flat list
/// cannot express.
fn emitLadder(g: *Gen, lad: Ladder) Error!void {
    const gs = g.limits[lad.gs];
    const gd = g.limits[lad.gd];
    const ds = g.limits[lad.ds];
    const ng = g.u_names[gs.hi]; // shared gate
    const nd = g.u_names[gd.lo]; // drain-side channel node (the limvds hi)
    const ns = g.u_names[gs.lo]; // source-side channel node (the limvds lo)
    try g.w("    {{ // \"fetlimds\" mode ladder (ngspice mos1load.c): fetlim V({s},{s}) | V({s},{s})\n", .{ ng, ns, ng, nd });
    try g.w("        // by the sign of OLD V({s},{s}), then limvds, then derive the other leg.\n", .{ nd, ns });
    try g.w("        const vdso = old[@intFromEnum(U.{s})] - old[@intFromEnum(U.{s})];\n", .{ nd, ns });
    try writeSign(g, "sgt", ds.sign);
    try g.w("        if (sgt * vdso >= 0.0) {{ // normal mode: vgs controls\n", .{});
    try emitLeg(g, gs, nd, ns, false);
    try g.w("        }} else {{ // inverse mode: vgd controls\n", .{});
    try emitLeg(g, gd, nd, ns, true);
    try g.w("        }}\n    }}\n", .{});
}

/// One arm: fetlim the controlling leg (writing its own second-named node, so
/// the other leg's probe is untouched), then limvds the channel V(nd,ns)
/// against the old vds, writing the node the fetlim left alone.
fn emitLeg(g: *Gen, leg: LimitCall, nd: []const u8, ns: []const u8, inv: bool) Error!void {
    const ngate = g.u_names[leg.hi];
    const nw = g.u_names[leg.lo];
    try g.w("            const vn = x[@intFromEnum(U.{s})] - x[@intFromEnum(U.{s})];\n", .{ ngate, nw });
    try g.w("            const vo = old[@intFromEnum(U.{s})] - old[@intFromEnum(U.{s})];\n", .{ ngate, nw });
    if (leg.sign == .f_zero) {
        try g.w("            const vl = zFetlim(vn, vo, ", .{});
    } else {
        try g.w("            const sg: f64 = zsg__{d};\n", .{signKey(g, leg.sign)});
        try g.w("            const vl = sg * zFetlim(sg * vn, sg * vo, ", .{});
    }
    try writeArg(g, leg.argv[0]);
    try g.w(");\n", .{});
    try g.w("            x[@intFromEnum(U.{s})] -= vl - vn;\n", .{nw});
    const neg: []const u8 = if (inv) "-" else "";
    try g.w("            const dn = x[@intFromEnum(U.{s})] - x[@intFromEnum(U.{s})];\n", .{ nd, ns });
    try g.w("            const dl = {s}sgt * zLimvds({s}sgt * dn, {s}sgt * vdso);\n", .{ neg, neg, neg });
    if (inv) {
        try g.w("            x[@intFromEnum(U.{s})] -= dl - dn;\n", .{ns});
    } else {
        try g.w("            x[@intFromEnum(U.{s})] += dl - dn;\n", .{nd});
    }
}

/// `const NAME: f64 = ±1.0` recovered from a sign argument, or the literal
/// 1.0 when the site is unsigned.
fn writeSign(g: *Gen, name: []const u8, v: Mir.Value) Error!void {
    if (v == .f_zero) return g.w("        const {s}: f64 = 1.0;\n", .{name});
    try g.w("        const {s}: f64 = zsg__{d};\n", .{ name, signKey(g, v) });
}

fn writeProbe(g: *Gen, lc: LimitCall, arr: []const u8) Error!void {
    try g.w("{s}[@intFromEnum(U.{s})]", .{ arr, g.u_names[lc.hi] });
    if (lc.lo != none_u32) try g.w(" - {s}[@intFromEnum(U.{s})]", .{ arr, g.u_names[lc.lo] });
}

fn writeArg(g: *Gen, v: Mir.Value) Error!void {
    if (v == .f_zero) return g.w("0.0", .{});
    const i = @intFromEnum(g.an.rv(v));
    // Hoisted: `precompute` latched it off ONE core evaluation at x = 0, which
    // `solveConst` proved is this value at every iterate. See `planPrep`.
    if (g.lp_idx[i] != none_u32) return g.w("inst.lp__{d}", .{g.lp_idx[i]});
    const k = g.lo_idx[i];
    std.debug.assert(k != none_u32); // `buildJobs` queues every `argv`
    // An integer core field (a `parameter integer` sign) is a bare i64, not
    // a Dual — no `.v` to read.
    if (g.an.vty[i] == .int)
        try g.w("m.f{d}", .{k})
    else
        try g.w("m.f{d}.v", .{k});
}

/// SPICE `MODEINITJCT`. Newton started at 0 V on a junction sees no current
/// and no conductance, so its first step is a blind jump into the exponential;
/// that is what pins a cold start in the wrong basin, and it is why
/// `contract.zig` says a device with `limit` should also have `seed`.
///
/// Every pnjlim-limited branch starts at its own `vcrit` — the bias where the
/// exponential is still Newton-tractable, which is exactly what `vcrit` IS.
/// `fetlim`/`limvds` get nothing: a channel is well-conditioned at 0 V.
fn emitSeed(g: *Gen) Error!void {
    var any = false;
    for (g.limits) |lc| {
        if (lc.alg == .pnjlim and lc.argv[1] != .f_zero) any = true;
    }
    if (!any) return;
    const needs_core = seedUsesCore(g);
    const reads_inst = needs_core or g.lp_vals.len != 0;
    try g.w(
        \\/// SPICE `MODEINITJCT`: start every pnjlim-limited junction at its own
        \\/// `vcrit` rather than at 0 V, where the junction is invisible to Newton.
        \\///
        \\/// The core runs at x = 0, and that is not an approximation of the
        \\/// operating point — `seed` IS the x = 0 point, so it is the only
        \\/// information there is. Unlike `limit`, these writes are NOT masked by
        \\/// the host: they happen once, pre-solve, and the first linear solve
        \\/// re-imposes every source constraint over them.
        \\
    , .{});
    try g.w("pub fn seed({s}: *const Model, {s}: *const Instance) [n_u]?f64 {{\n", .{
        if (needs_core) "model" else "_",
        if (reads_inst) "inst" else "_",
    });
    if (needs_core) try g.w(
        \\    var xr: [n_u]R = undefined;
        \\    for (&xr) |*p| p.* = R.con(0.0);
        \\    const m = core(R, xr, model, inst);
        \\
    , .{});
    try g.w("    var s: [n_u]?f64 = .{{null}} ** n_u;\n", .{});
    for (g.limits) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        // The junction sits across `V(hi, lo)`, and only the internal side is
        // ours to place. Two clamps on the same net leave the later one's
        // bias — they are the same junction seen twice, so either is right.
        // A signed clamp seeds V = sign·vcrit: the junction is forward at
        // NEGATIVE probe voltage when the sign argument is negative.
        const on_lo = writable(g, lc.lo);
        if (lc.sign != .f_zero) {
            try g.w("    s[@intFromEnum(U.{s})] = if (", .{g.u_names[if (on_lo) lc.lo else lc.hi]});
            try writeArg(g, lc.sign);
            try g.w(" < 0) {s}", .{if (on_lo) "" else "-"});
            try writeArg(g, lc.argv[1]);
            try g.w(" else {s}", .{if (on_lo) "-" else ""});
            try writeArg(g, lc.argv[1]);
        } else if (on_lo) {
            try g.w("    s[@intFromEnum(U.{s})] = -", .{g.u_names[lc.lo]});
            try writeArg(g, lc.argv[1]);
        } else {
            try g.w("    s[@intFromEnum(U.{s})] = ", .{g.u_names[lc.hi]});
            try writeArg(g, lc.argv[1]);
        }
        try g.w("; // V({s},{s}) = {s}vcrit\n", .{
            uName(g, lc.hi), uName(g, lc.lo),
            if (lc.sign != .f_zero) "±" else "",
        });
    }
    try g.w("    return s;\n}}\n\n", .{});
}
