//! §4.5.15 `$limit` — the convergence half of the backend.
//!
//! Transformation: each `$limit(V(a,b), "alg", args…)` call in the MIR → one
//! clamp in the contract's `limit` hook, plus a cold-start bias in `seed`. The
//! host applies both to the solution vector: `limit` after every linear solve
//! (`ARPice/src/devices/engine.zig` `limitRange`, driven from
//! `converger.zig`'s `finalizeStep`), `seed` once before Newton iteration 1
//! (`Circuit.zig`'s `seedJunctions`).
//!
//! `eval` still renders `$limit` as the IDENTITY of its probe, and that is not
//! a gap — it is the other half of this design. The host clamps `x` BEFORE it
//! calls `eval`, so the probe the body reads is already the limited value.
//! Applying the clamp a second time inside `eval` would limit against the
//! wrong `x_old` and break the Jacobian's agreement with the residual.
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
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;

const none_u32 = std.math.maxInt(u32);

/// The three SPICE3 limiters the corpus names. NOT an LRM taxonomy: §4.5.15
/// leaves the identifier implementation-defined, and these are the spellings
/// `devsup.c` established, which is what every `.va` in the corpus writes.
/// An identifier that is not one of these is declined, which §4.5.15 permits
/// ("the simulator may choose to ignore the limiting request").
pub const Alg = enum {
    pnjlim,
    fetlim,
    limvds,
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
            .fetlim => 1,
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
    g.limits_declined = declined.items;
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
        // §4.5.15 also allows a user analog function here. That is a call, not
        // a string, and it needs the whole body — out of scope, declined.
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

// -------------------------------------------------------------------- emit

/// Does any clamp read a value out of the shared core? `limvds` takes no
/// arguments, so a model using only that needs neither `core` nor `R`.
pub fn usesCore(g: *const Gen) bool {
    for (g.limits) |lc| {
        if (lc.sign != .f_zero) return true;
        for (lc.argv[0..lc.alg.arity()]) |v| {
            if (v != .f_zero) return true;
        }
    }
    return false;
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
    try g.w(
        \\/// §4.5.15 `$limit`: SPICE voltage limiting, applied by the host between
        \\/// the linear solve and the next `eval`.
        \\///
        \\/// The clamps run in SOURCE ORDER and each reads the `x` the previous one
        \\/// left, because that is both the order the model wrote them in and the
        \\/// order ngspice's load routines apply them (fetlim → limvds → pnjlim on
        \\/// a JFET). Each clamp has ONE writer — the second-named node — so
        \\/// clamps that share their first-named node cannot fight (emitClamp
        \\/// says why a split breaks a BJT).
        \\
    , .{});
    try g.w("pub fn limit({s}: *const Model, {s}: *const Instance, cur: [n_u]f64, old: [n_u]f64) contract.LimitResult(n_u) {{\n", .{
        if (needs_core) "model" else "_",
        if (needs_core) "inst" else "_",
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
    for (g.limits) |lc| try emitClamp(g, lc);
    try g.w("    return .{{ .x = x, .converged = {s} }};\n}}\n\n", .{if (any_pnjlim) "ok" else "true"});

    try emitSeed(g);
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
            try g.w("        const sg: f64 = if (vo < 0) -1.0 else if (vo > 0) 1.0 else (if (", .{});
            try writeArg(g, lc.sign);
            try g.w(" < 0) -1.0 else 1.0);\n", .{});
        } else {
            try g.w("        const sg: f64 = if (", .{});
            try writeArg(g, lc.sign);
            try g.w(" < 0) -1.0 else 1.0;\n", .{});
        }
    }
    try g.w("        const vl = {s}z{s}({s}vn, {s}vo", .{
        if (signed) "sg * " else "",
        switch (lc.alg) {
            .pnjlim => @as([]const u8, "Pnjlim"),
            .fetlim => "Fetlim",
            .limvds => "Limvds",
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

fn writeProbe(g: *Gen, lc: LimitCall, arr: []const u8) Error!void {
    try g.w("{s}[@intFromEnum(U.{s})]", .{ arr, g.u_names[lc.hi] });
    if (lc.lo != none_u32) try g.w(" - {s}[@intFromEnum(U.{s})]", .{ arr, g.u_names[lc.lo] });
}

fn writeArg(g: *Gen, v: Mir.Value) Error!void {
    if (v == .f_zero) return g.w("0.0", .{});
    const k = g.lo_idx[@intFromEnum(v)];
    std.debug.assert(k != none_u32); // `buildJobs` queues every `argv`
    // An integer core field (a `parameter integer` sign) is a bare i64, not
    // a Dual — no `.v` to read.
    if (g.an.vty[@intFromEnum(v)] == .int)
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
    try g.w(
        \\/// SPICE `MODEINITJCT`: start every pnjlim-limited junction at its own
        \\/// `vcrit` rather than at 0 V, where the junction is invisible to Newton.
        \\///
        \\/// The core runs at x = 0, and that is not an approximation of the
        \\/// operating point — `seed` IS the x = 0 point, so it is the only
        \\/// information there is. Unlike `limit`, these writes are NOT masked by
        \\/// the host: they happen once, pre-solve, and the first linear solve
        \\/// re-imposes every source constraint over them.
        \\pub fn seed(model: *const Model, inst: *const Instance) [n_u]?f64 {{
        \\    var xr: [n_u]R = undefined;
        \\    for (&xr) |*p| p.* = R.con(0.0);
        \\    const m = core(R, xr, model, inst);
        \\    var s: [n_u]?f64 = .{{null}} ** n_u;
        \\
    , .{});
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
