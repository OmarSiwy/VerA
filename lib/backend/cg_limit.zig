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
const plan_topo = @import("codegen/plan/topology.zig");
const Lowered = @import("ir").Lowered;
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
/// The pure half: which sites are honoured, and the questions both halves ask.
const plan_limit = @import("codegen/plan/limit.zig");
pub const Alg = plan_limit.Alg;
pub const LimitCall = plan_limit.LimitCall;
const Ladder = plan_limit.Ladder;

const none_u32 = std.math.maxInt(u32);

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
    lv.writes |= ubit(if (g.limits.writable(lc.lo)) lc.lo else lc.hi);
}

pub fn liveSets(g: *const Gen) Live {
    var lv: Live = .{};
    // A core re-entry is seeded from EVERY entry of `cur` (`emit`'s `xr` loop),
    // and n_u > 64 has no room in the mask — both answer "all of them".
    if (usesCore(g) or g.names.n_u > 64) lv.reads = ~@as(u64, 0);
    for (g.limits.calls, 0..) |lc, i| switch (lc.alg) {
        .fetlimds => {
            const lad = g.limits.ladderOf(i).?;
            if (i != @min(lad.gs, lad.gd)) continue;
            // The two mode arms unioned: the shared gate is read, and both
            // channel nodes are read AND written (which one takes the fetlim
            // correction and which the limvds one swaps with the mode).
            const gs = g.limits.calls[lad.gs];
            const gd = g.limits.calls[lad.gd];
            lv.reads |= ubit(gs.hi) | ubit(gs.lo) | ubit(gd.lo);
            lv.writes |= ubit(gs.lo) | ubit(gd.lo);
        },
        .limvds => if (!g.limits.limvdsClaimed(i)) unionSite(&lv, g, lc),
        else => unionSite(&lv, g, lc),
    };
    // `seed` corrects the same node `emitClamp` does, but OR it in rather than
    // rely on that: the host initialises `lim_x` through `seed` and reads it
    // back through `limit`, so a bit in one and not the other is a stale slot.
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        lv.writes |= ubit(if (g.limits.writable(lc.lo)) lc.lo else lc.hi);
    }
    lv.reads |= lv.writes;
    return lv;
}

// -------------------------------------------------------------------- emit

/// Does any clamp read a value out of the shared core AT CLAMP TIME? Three ways
/// not to: `limvds` takes no arguments, an unsigned site has no sign, and — the
/// case that matters — the argument is solve-invariant, so `setup` already
/// latched it into `Instance.su` (codegen/setup.zig).
pub fn usesCore(g: *const Gen) bool {
    for (g.limits.calls) |lc| {
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
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        if (needsCore(g, lc.argv[1]) or needsCore(g, lc.sign)) return true;
    }
    return false;
}

/// One argument: is it still a core live-out read, rather than a setup root?
fn needsCore(g: *const Gen, v0: Mir.Value) bool {
    if (v0 == .f_zero) return false;
    return !isRoot(g, v0) and !isLeaf(g, v0);
}

/// A literal or a parameter: rendered straight over `Model`, no core.
fn isLeaf(g: *const Gen, v0: Mir.Value) bool {
    return switch (g.mir.valueDef(g.an.rv(v0))) {
        .float_const, .int_const => true,
        .param_ref => |p| Analysis.tyOfParam(g.lowered.params.items[p].ty) != .str,
        .undef, .str_const, .block_param, .inst_result => false,
    };
}

fn isRoot(g: *const Gen, v0: Mir.Value) bool {
    return g.su.idx.len != 0 and g.su.idx[@intFromEnum(g.an.rv(v0))] != none_u32;
}

/// Does any clamp argument read `Model` directly (a parameter leaf)?
fn readsParam(g: *const Gen) bool {
    for (g.limits.calls) |lc| {
        if (lc.sign != .f_zero and paramLeaf(g, lc.sign)) return true;
        for (lc.argv[0..lc.alg.arity()]) |v| {
            if (v != .f_zero and paramLeaf(g, v)) return true;
        }
    }
    return false;
}

fn paramLeaf(g: *const Gen, v: Mir.Value) bool {
    return g.mir.valueDef(g.an.rv(v)) == .param_ref and isLeaf(g, v);
}

/// Does any clamp argument read `inst.su`?
fn readsRoot(g: *const Gen) bool {
    for (g.limits.calls) |lc| {
        if (lc.sign != .f_zero and isRoot(g, lc.sign)) return true;
        for (lc.argv[0..lc.alg.arity()]) |v| {
            if (v != .f_zero and isRoot(g, v)) return true;
        }
    }
    return false;
}

/// Does the `$limit` family evaluate the core ANYWHERE — so the file needs
/// `R`? Only when a clamp reads an argument live; a setup root is a field.
pub fn needsR(g: *const Gen) bool {
    return usesCore(g);
}

pub fn emit(g: *Gen) Error!void {
    if (g.limits.declined.len != 0) {
        try g.w("// §4.5.15 `$limit` DECLINED at {d} call site(s) — the probe is\n", .{g.limits.declined.len});
        try g.w("// returned unchanged there, which §4.5.15 permits:\n", .{});
        for (g.limits.declined) |d| try g.w("//   - {s}\n", .{d});
        try g.w("\n", .{});
    }
    if (g.limits.calls.len == 0) return;

    const needs_core = usesCore(g);
    // A setup root is an `inst.su` read, so `inst` stays named even when the
    // core call is gone. `model` goes with the core, or with a parameter leaf.
    const reads_inst = needs_core or readsRoot(g);
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
        if (needs_core or readsParam(g)) "model" else "_",
        if (reads_inst) "inst" else "_",
    });
    const probe_inst = if (needs_core) try g.probeInstance() else "inst";
    if (needs_core) try g.w(
        \\    var xr: [n_u]R = undefined;
        \\    for (cur, 0..) |xv, i| xr[i] = R.con(xv);
        \\    const m = core(R, xr, model, {s}{s});
        \\
    , .{ probe_inst, g.heldArg(true) });
    try g.w("    var x = cur;\n", .{});
    // Only `pnjlim` ever reports non-convergence, so a fetlim/limvds-only
    // device has nothing to track and `var ok` would never be mutated.
    var any_pnjlim = false;
    for (g.limits.calls) |lc| any_pnjlim = any_pnjlim or lc.alg == .pnjlim or lc.alg == .steplim;
    if (any_pnjlim) try g.w("    var ok = true;\n", .{});
    try emitSigns(g);
    for (g.limits.calls, 0..) |lc, i| switch (lc.alg) {
        // Collect kept only complete ladders; the earlier leg speaks for all
        // three sites, the partner and the claimed limvds stay silent.
        .fetlimds => {
            const lad = g.limits.ladderOf(i).?;
            if (i == @min(lad.gs, lad.gd)) try emitLadder(g, lad);
        },
        .limvds => if (!g.limits.limvdsClaimed(i)) try emitClamp(g, lc),
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
}

/// `const zsg__k: f64 = ±1.0` for each DISTINCT frame sign, once at the top of
/// `limit`. Every clamp on a MOSFET reads the same `type` parameter, so without
/// this the compare-and-select is re-emitted three or four times per body over
/// a latched `inst.su` field that cannot have changed between them (measured: 8 Ir
/// per MOSFET per Newton iterate on mos1, 5 of them recoverable). Named from
/// the MIR value so `signOf` needs no shared state.
fn emitSigns(g: *Gen) Error!void {
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(g.gpa);
    // MIRRORS `emit`'s dispatch site for site. A claimed `limvds` emits no
    // clamp of its own but IS the ladder's channel rung, so its sign is still
    // referenced; a const with no reference is a Zig compile error, and one
    // referenced but not emitted is worse.
    for (g.limits.calls, 0..) |lc, i| switch (lc.alg) {
        .fetlimds => {
            const lad = g.limits.ladderOf(i).?;
            if (i != @min(lad.gs, lad.gd)) continue;
            try oneSign(g, &seen, g.limits.calls[lad.gs].sign);
            try oneSign(g, &seen, g.limits.calls[lad.gd].sign);
            try oneSign(g, &seen, g.limits.calls[lad.ds].sign);
        },
        .limvds => if (!g.limits.limvdsClaimed(i)) try oneSign(g, &seen, lc.sign),
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
        plan_limit.uName(g.names.u_names, lc.hi),                 plan_limit.uName(g.names.u_names, lc.lo), lc.alg,
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
    const w_lo = g.limits.writable(lc.lo);
    if (w_lo) {
        try g.w("        x[@intFromEnum(U.{s})] -= vl - vn;\n", .{g.names.u_names[lc.lo]});
    } else {
        try g.w("        x[@intFromEnum(U.{s})] += vl - vn;\n", .{g.names.u_names[lc.hi]});
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
    const gs = g.limits.calls[lad.gs];
    const gd = g.limits.calls[lad.gd];
    const ds = g.limits.calls[lad.ds];
    const ng = g.names.u_names[gs.hi]; // shared gate
    const nd = g.names.u_names[gd.lo]; // drain-side channel node (the limvds hi)
    const ns = g.names.u_names[gs.lo]; // source-side channel node (the limvds lo)
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
    const ngate = g.names.u_names[leg.hi];
    const nw = g.names.u_names[leg.lo];
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
    try g.w("{s}[@intFromEnum(U.{s})]", .{ arr, g.names.u_names[lc.hi] });
    if (lc.lo != none_u32) try g.w(" - {s}[@intFromEnum(U.{s})]", .{ arr, g.names.u_names[lc.lo] });
}

fn writeArg(g: *Gen, v: Mir.Value) Error!void {
    if (v == .f_zero) return g.w("0.0", .{});
    const i = @intFromEnum(g.an.rv(v));
    // Solve-invariant: `setup` latched it (codegen/setup.zig), so neither
    // `limit` nor `seed` evaluates the core for it.
    if (isRoot(g, v)) return g.w("{s}", .{try Gen.rootRef(g, v, false)});
    if (isLeaf(g, v)) return g.w("{s}", .{try g.f64Expr(v)});
    const k = g.core.lo_idx[i];
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
    for (g.limits.calls) |lc| {
        if (lc.alg == .pnjlim and lc.argv[1] != .f_zero) any = true;
    }
    if (!any) return;
    const needs_core = seedUsesCore(g);
    const reads_inst = needs_core or readsRoot(g);
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
        if (needs_core or readsParam(g)) "model" else "_",
        if (reads_inst) "inst" else "_",
    });
    const probe_inst = if (needs_core) try g.probeInstance() else "inst";
    if (needs_core) try g.w(
        \\    var xr: [n_u]R = undefined;
        \\    for (&xr) |*p| p.* = R.con(0.0);
        \\    const m = core(R, xr, model, {s}{s});
        \\
    , .{ probe_inst, g.heldArg(true) });
    try g.w("    var s: [n_u]?f64 = .{{null}} ** n_u;\n", .{});
    for (g.limits.calls) |lc| {
        if (lc.alg != .pnjlim or lc.argv[1] == .f_zero) continue;
        // The junction sits across `V(hi, lo)`, and only the internal side is
        // ours to place. Two clamps on the same net leave the later one's
        // bias — they are the same junction seen twice, so either is right.
        // A signed clamp seeds V = sign·vcrit: the junction is forward at
        // NEGATIVE probe voltage when the sign argument is negative.
        const on_lo = g.limits.writable(lc.lo);
        if (lc.sign != .f_zero) {
            try g.w("    s[@intFromEnum(U.{s})] = if (", .{g.names.u_names[if (on_lo) lc.lo else lc.hi]});
            try writeArg(g, lc.sign);
            try g.w(" < 0) {s}", .{if (on_lo) "" else "-"});
            try writeArg(g, lc.argv[1]);
            try g.w(" else {s}", .{if (on_lo) "-" else ""});
            try writeArg(g, lc.argv[1]);
        } else if (on_lo) {
            try g.w("    s[@intFromEnum(U.{s})] = -", .{g.names.u_names[lc.lo]});
            try writeArg(g, lc.argv[1]);
        } else {
            try g.w("    s[@intFromEnum(U.{s})] = ", .{g.names.u_names[lc.hi]});
            try writeArg(g, lc.argv[1]);
        }
        try g.w("; // V({s},{s}) = {s}vcrit\n", .{
            plan_limit.uName(g.names.u_names, lc.hi), plan_limit.uName(g.names.u_names, lc.lo),
            if (lc.sign != .f_zero) "±" else "",
        });
    }
    try g.w("    return s;\n}}\n\n", .{});
}
