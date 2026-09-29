//! Runner generation: `tb.Directives` in, the testbench's Zig source out
//! (fixed-grid, mixed-signal, or the Clause 12 VPI library form).
//! LRM: §1, §2.8.3, §3.4, §3.4.1, §3.4.5, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.1,
//! §4.6.4.3, §4.6.4.6, §5.10.2, §6.3.4, §8.2, §9.19.

const std = @import("std");
const tb = @import("../tb.zig");
const tb_runner_text = @import("runner_text.zig");
const naming = @import("../naming.zig");
const Lowered = @import("ir").Lowered;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Io = tb.Io;
const Allocator = tb.Allocator;
const Error = tb.Error;
const Sweep = tb.Sweep;
const Directives = tb.Directives;
const max_points = tb.max_points;

/// Returns the runner's Zig source, allocated in `arena`; dispatches to
/// `renderMixed` when `d.mixed` is set. `title` keys each transcript block
/// (the fixture's file stem). All output goes to stderr via `std.debug.print`,
/// the stream generated `$strobe` uses, so the interleaving is deterministic.
pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    if (d.mixed) |mx| return renderMixed(arena, title, d, mx);
    var out: std.ArrayList(u8) = .empty;

    try head(&out, arena, title);

    // --- main -------------------------------------------------------------
    try out.appendSlice(arena,
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| try setCard(&out, arena, "    ", "model", p.name, p.value);
    // §6.3.4: the card is complete only now. Unconditional, so a §3.4.5
    // localparam is derived even with no `//! param` line.
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "derive")) D.derive(Val, &model);
        \\    shapeCheck(&model);
        \\
        \\    var inst: D.Instance = .{};
        \\
    );
    try out.print(arena, "    inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try out.print(arena, "    sim_state = .{{ .kind = .{t} }};\n", .{d.analysis});
    // §2.8.3/§12.32: this testbench is a host, so it binds `no_vpi_app` for
    // the device's unresolved `$name`s and passes `validateHost` like any other.
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    // The solve-invariant slice: after the card and the temperature
        \\    // write, before the first evaluation — the ordering a host keeps.
        \\    // With `Dual` itself as the value scalar, so every latched value is
        \\    // the bits `eval` would have computed.
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model, &inst);
        \\
    );
    try out.appendSlice(arena,
        \\
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\
    );

    // --- §4.6.4 the exported noise topology ---------------------------------
    // Once, before the points: `noise_gens` is a comptime table.
    if (d.asserts_noise) {
        try out.appendSlice(arena,
            \\
            \\    // §4.6.4: what this device tells a host about its noise
            \\    // generators. Nothing in the model's own text can see this —
            \\    // §4.6.2 makes every source read 0 outside a small-signal
            \\    // analysis — so the table is the only place the clause is
            \\    // observable, and a `//! noise` line is how a fixture reaches it.
            \\    {
            \\        const want = [_][]const u8{
            \\
        );
        for (d.noise) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
        try out.appendSlice(arena,
            \\        };
            \\        if (comptime @hasDecl(D, "noise_gens")) {
            \\            std.debug.print("noise count got={d} want={d} ok={d}\n", .{
            \\                D.noise_gens.len, want.len, @intFromBool(D.noise_gens.len == want.len),
            \\            });
            \\            inline for (D.noise_gens, 0..) |g, i| {
            \\                // `U`'s tag names ARE the spelling contract — the same
            \\                // names a `//! bias` line uses and the same ones a
            \\                // diagnostic prints — so a fixture writes what it reads
            \\                // in the source.
            \\                // `#k` is §4.6.4.6's correlation column: two rows
            \\                // printing the same `#k` share one physical generator;
            \\                // `#null` is a row that declared no identity.
            \\                // Every field is comptime, so the row is too, at any length.
            \\                const got = comptime std.fmt.comptimePrint("{s}({s},{s})#{?d}", .{
            \\                    @tagName(g.kind),
            \\                    @tagName(@as(D.U, @enumFromInt(g.row))),
            \\                    @tagName(@as(D.U, @enumFromInt(g.col))),
            \\                    g.source,
            \\                });
            \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
            \\                std.debug.print("noise[{d}] got={s} want={s} ok={d}\n", .{
            \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
            \\                });
            \\            }
            \\        } else {
            \\            // No table at all is the empty table: a device that
            \\            // declares no generator does not declare an empty one.
            \\            std.debug.print("noise count got=0 want={d} ok={d}\n", .{
            \\                want.len, @intFromBool(want.len == 0),
            \\            });
            \\        }
            \\    }
            \\
        );
        try emitNoiseComptime(arena, &out, d);
    }

    // --- §4.6.3 the exported AC stimulus topology ---------------------------
    if (d.asserts_acstim) try emitAcTopology(arena, &out, d);

    // --- §5.6.1.2 the exported charge sites ---------------------------------
    if (d.asserts_qsite) try emitQSites(arena, &out, d);

    // --- §9.17.3 the published cold start -----------------------------------
    if (d.asserts_seed) try emitSeedCheck(arena, &out, d);

    // --- §3.6.1.2 the published tolerances ----------------------------------
    for (d.abstols) |b| try out.print(arena,
        \\    if (comptime std.meta.stringToEnum(D.U, "{0f}")) |u| {{
        \\        const g = u_abstol[@intFromEnum(u)];
        \\        std.debug.print("abstol[{0f}] got={{e}} want={{e}} ok={{d}}\n", .{{ g, @as(f64, {1f}), @intFromBool(near(g, {1f})) }});
        \\    }} else std.debug.print("abstol[{0f}] got=none want={{e}} ok=0\n", .{{@as(f64, {1f})}});
        \\
    , .{ std.zig.fmtString(b.name), fmtF64(b.value) });

    // --- one straight-line block per operating point ------------------------
    // Sweep outer, time inner. Each sweep point is its own transient run with a
    // fresh `State`, so no bias inherits another's §4.5 operator history.
    const points = try expand(arena, d);
    // §5.10.2 / Table 5-1: `initial_step` fires on an analysis's first point
    // and `final_step` on its last. With `//! time` each sweep block is its own
    // transient analysis; without it the blocks are the steps of one dc sweep.
    // A one-point fixture gets both events, as Table 5-1's DCOP column does.
    const per_block = d.times.len > 1;
    var n: usize = 0;
    // `//! psweep` gives each point its own model card: §8.2 sub-tasks, each
    // re-derived per §6.3.4. Without it the shared `model` is used.
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points) |pt| {
        try out.appendSlice(arena, "    {\n");
        // §9.5.1.1 a block after the first is a following analysis of the same
        // process, so a file it reopens "w" keeps earlier output.
        if (per_block and n != 0)
            try out.appendSlice(arena, "        if (comptime contract.fileIo(D)) |f| if (f.new_analysis) |g| g();\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| try setCard(&out, arena, "        ", "pm", s.name, v);
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"derive\")) D.derive(Val, &pm);\n");
            try out.appendSlice(arena, "        shapeCheck(&pm);\n");
            // §6.3.4: setup also derives from the swept card.
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"setup\")) D.setup(Dual, &pm, &inst);\n");
        }
        // `forced` marks the unknowns the host drives rather than Newton. By
        // default every unknown is tied to the reference; `//! solve` unties
        // the ones no line names.
        try out.print(
            arena,
            "        var x: [n_u]f64 = @splat(0.0);\n        var forced: [n_u]?f64 = @splat({s});\n" ++
                // §3.6.3.2 a nodeset is an initial guess: it seeds `x` and does
                // not touch `forced`, so it picks which root Newton finds. It
                // precedes the `//! bias` lines, which override it.
                "        if (comptime @hasDecl(D, \"u_nodeset\")) for (D.u_nodeset, 0..) |nodeset_i, i| {{\n" ++
                "            if (nodeset_i) |v| x[i] = v;\n" ++
                "        }};\n" ++
                "        var state = newState(&{s}, &inst);\n",
            .{ if (d.solve_free) "null" else "0.0", mdl },
        );
        for (d.op_states) |u| try out.print(arena, "        forced[{d}] = null;\n", .{u});
        for (d.bias) |b|
            try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        for (d.sweeps, pt[0..d.sweeps.len]) |s, v|
            try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
        for (d.times, 0..) |t, k| {
            for (d.waves) |wv| {
                // A short `wave` holds its last value.
                const v = wv.values[@min(k, wv.values.len - 1)];
                try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(wv.name), fmtF64(v) });
            }
            // The first time is the DC point, dt = 0, which operator kernels
            // answer with their DC form (§4.5.4 initial condition, §4.5.11 DC gain).
            const dt: f64 = if (k == 0) 0.0 else d.times[k] - d.times[k - 1];
            try out.print(arena, "        sim_state.t = {f};\n        sim_state.dt = {f};\n", .{ fmtF64(t), fmtF64(dt) });
            // Written at every point: a stale `true` would fire an event twice.
            try out.print(arena, "        sim_state.initial_step = {};\n        sim_state.final_step = {};\n", .{
                k == 0 and (per_block or n == 0),
                k + 1 == d.times.len and (per_block or n + 1 == points.len),
            });
            // §5.2.1 `analog initial` re-runs per sub-task: the first time of
            // every block, unlike `initial_step` (visible under `//! psweep`).
            try out.print(arena, "        sim_state.analog_initial = {};\n", .{k == 0});
            // §5.6 the model prints at a solution: solve first, then `point`.
            try out.print(arena, "        const solved{d} = solve(&x, &forced, &{s}, &inst);\n", .{ n, mdl });
            try out.print(arena, "        point({d}, &x, &{s}, &inst);\n", .{ n, mdl });
            // §4.6.4.1/.2 the PSD depends on bias; fixtures state it at the
            // first point, the one every fixture has.
            if (n == 0) try emitNoisePsd(arena, &out, d, mdl);
            // §4.6.3 magnitude and phase may read the card (`mdl`); also
            // stated at the first point.
            if (n == 0) try emitAcStim(arena, &out, d, mdl);
            // `acDyn` linearizes at the point `eval` does; also the first.
            if (n == 0) try emitAcDyn(arena, &out, d, mdl);
            // §9.17.3 the published clamp, with this point's `x` as `cur`.
            if (n == 0) try emitLimitCheck(arena, &out, d, mdl);
            // §4.5.2 accepted-step bookkeeping: only `updateState` writes the
            // history `eval` reads.
            try out.print(arena, "        stepPost(&{s}, &inst, &x, &state, solved{d});\n", .{ mdl, n });
            n += 1;
        }
        try out.appendSlice(arena, "    }\n");
    }

    try out.appendSlice(arena, if (d.print_residual)
        \\}
        \\
        \\const print_residual = true;
        \\
    else
        \\}
        \\
        \\const print_residual = false;
        \\
    );
    return out.items;
}

/// Returns the `//! param` lines that name a shape parameter of `lowered`
/// (`ParamInfo.shape`, §3.4), allocated in `arena`. A shape parameter is fixed
/// at compile time, so a non-empty result means the caller must compile again
/// with it as `Options.param_overrides`, as `--param` would.
pub fn shapeOverrides(arena: Allocator, d: Directives, lowered: *const Lowered) Allocator.Error![]const @import("ir").Lower.ParamOverride {
    var out: std.ArrayList(@import("ir").Lower.ParamOverride) = .empty;
    for (d.params) |card| for (lowered.params.items) |p| {
        if (p.shape and std.mem.eql(u8, p.name, card.name)) try out.append(arena, .{ .name = card.name, .value = card.value });
    };
    return out.items;
}

/// The `U` indices of the §4.5.2 operator unknowns (`Directives.op_states`).
pub fn opStates(arena: Allocator, lowered: *const Lowered) Error![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    for (lowered.nodes.items(.kind), 0..) |k, i| switch (k) {
        .op_state => try out.append(arena, @intCast(i)),
        .net, .branch_flow, .port_flow => {},
    };
    return out.items;
}

/// Returns the mixed-signal plan of a compile, or null for a module with no
/// discrete half that needs the event queue (`Lowered.mixed_signal`). The
/// slices borrow from `lowered` and `mir`.
pub fn mixedPlan(lowered: *const Lowered, mir: *const Mir) ?tb.Mixed {
    if (!lowered.mixed_signal) return null;
    const ts = lowered.directives.timescale();
    return .{
        .source = lowered.src,
        .top = mir.name,
        .unit = if (ts) |t| t.unit else null,
        .precision = if (ts) |t| t.precision else null,
        .inputs = lowered.discrete_inputs.keys(),
        .snaps = lowered.discrete_snaps.keys(),
        .xz = lowered.discrete_xz.keys(),
        .events = lowered.discrete_events.values(),
        .inserts = lowered.inserts,
        .reads = lowered.discrete_reads.keys(),
        .held = lowered.held_vars.items,
        .params = lowered.params.items,
        .param_reads = lowered.discrete_params.keys(),
    };
}

/// Adds W0750 to `bag` at the first §5.10.3 `cross`, `above` or `timer`
/// call when the module gets the fixed-grid runner (`mixedPlan` is null),
/// which inserts no timepoint: such an event fires at the first `//! time`
/// point past its own time.
pub fn warnGridEvents(bag: *diag.Bag, lowered: *const Lowered, mir: *const Mir) !void {
    if (lowered.mixed_signal) return;
    for (0..mir.blockCount()) |bi| {
        var insts = mir.blockInsts(@enumFromInt(bi));
        while (insts.next()) |inst| {
            if (mir.instOp(inst) != .call or mir.instTok(inst) == Mir.no_tok) continue;
            const k = Mir.callee.opKind(mir.instData(inst).call.callee);
            if (k == .cross or k == .above or k == .timer)
                return bag.add(.codegen, .W0750, lowered.tokenSpan(mir.instTok(inst)), "the testbench inserts no timepoint at it", .{});
        }
    }
}

/// Emits the `//! qsite` check (`tb.Directives.qsites`), once before the
/// points: the site layout is a comptime property of the device.
fn emitQSites(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §5.6.1.2 the charge sites a host tapes one by one: which rows
        \\    // each stamps (`q_stamps`) and whether `q_lte` checks it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (d.qsites) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e)});
    try out.appendSlice(arena,
        \\        };
        \\        const nq = if (comptime @hasDecl(D, "q")) contract.nQ(D) else 0;
        \\        std.debug.print("qsite count got={d} want={d} ok={d}\n", .{ nq, want.len, @intFromBool(nq == want.len) });
        \\        if (comptime @hasDecl(D, "q")) {
        \\            inline for (0..nq) |k| {
        \\                // Built at comptime from comptime stamps, so a site with
        \\                // many rows is never cut short.
        \\                const got = comptime blk: {
        \\                    @setEvalBranchQuota(1_000_000);
        \\                    var s: []const u8 = "";
        \\                    for (contract.qStamps(D)) |e| if (e.site == k) {
        \\                        s = s ++ if (e.sign == 1) @tagName(e.row) ++ "+ " else if (e.sign == -1) @tagName(e.row) ++ "- " else std.fmt.comptimePrint("{s}*{d} ", .{ @tagName(e.row), e.sign });
        \\                    };
        \\                    break :blk s ++ if (contract.qLte(D)[k]) "lte" else "nolte";
        \\                };
        \\                const w_k: []const u8 = if (k < want.len) want[k] else "<none>";
        \\                std.debug.print("qsite[{d}] got={s} want={s} ok={d}\n", .{ k, got, w_k, @intFromBool(std.mem.eql(u8, got, w_k)) });
        \\            }
        \\        }
        \\    }
        \\
    );
}

/// Emits the `//! seed` check (`tb.Directives.seeds`), once after `setup`,
/// where a host calls `seed` before solving.
fn emitSeedCheck(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §9.17.3 the cold start a host writes into its limited image.
        \\    {
        \\        const got: [n_u]?f64 = if (comptime @hasDecl(D, "seed")) D.seed(Val, &model, &inst, sim_state) else @splat(null);
        \\        var want: [n_u]?f64 = @splat(null);
        \\
    );
    for (d.seeds) |b| try out.print(arena, "        want[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    try out.appendSlice(arena,
        \\        const writes: u64 = if (comptime @hasDecl(D, "limit_writes")) D.limit_writes else 0;
        \\        for (got, want, 0..) |g, w, i| {
        \\            if (g == null and w == null) continue;
        \\            const ok = g != null and w != null and near(g.?, w.?);
        \\            std.debug.print("seed[{s}] got={?d} want={?d} ok={d}\n", .{ @tagName(@as(D.U, @enumFromInt(i))), g, w, @intFromBool(ok) });
        \\            if (g != null) std.debug.print("seed[{s}] in limit_writes ok={d}\n", .{
        \\                @tagName(@as(D.U, @enumFromInt(i))), @intFromBool(i < 64 and (writes >> @intCast(i)) & 1 != 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Emits the `//! limit` checks (`tb.Directives.limits`) at the first point,
/// after the solve, so `x` is the bias the fixture states.
fn emitLimitCheck(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    for (d.limits, 0..) |c, k| {
        try out.appendSlice(arena, "        {\n            var old = x;\n            _ = &old;\n");
        for (c.old) |b| try out.print(arena, "            old[ix(\"{f}\")] = {f};\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        try out.print(arena,
            \\            if (comptime !@hasDecl(D, "limit")) {{
            \\                std.debug.print("limit[{d}] got=none want=limit ok=0\n", .{{}});
            \\            }} else {{
            \\                const r = D.limit(Val, &{s}, &inst, x, old, sim_state);
            \\
        , .{ k, mdl });
        for (c.want) |b| {
            if (std.mem.eql(u8, b.name, "converged")) {
                try out.print(arena, "                std.debug.print(\"limit[{d}].converged got={{d}} want={d} ok={{d}}\\n\", .{{ @intFromBool(r.converged), @intFromBool(r.converged == {}) }});\n", .{ k, @intFromBool(b.value != 0), b.value != 0 });
            } else {
                try out.print(arena, "                std.debug.print(\"limit[{d}].{f} got={{d}} want={{d}} ok={{d}}\\n\", .{{ r.x[ix(\"{f}\")], @as(f64, {f}), @intFromBool(near(r.x[ix(\"{f}\")], {f})) }});\n", .{
                    k, std.zig.fmtString(b.name), std.zig.fmtString(b.name), fmtF64(b.value), std.zig.fmtString(b.name), fmtF64(b.value),
                });
            }
        }
        try out.appendSlice(arena, "            }\n        }\n");
    }
}

/// The page every runner opens with: the fixed head, `title`, the fixed body.
fn head(out: *std.ArrayList(u8), arena: Allocator, title: []const u8) Error!void {
    try out.appendSlice(arena, tb_runner_text.runner_head);
    try out.print(arena, "const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try out.appendSlice(arena, tb_runner_text.runner_body);
}

/// Writes one card line, `<card>.<name> = value`, at `indent`.
fn setCard(out: *std.ArrayList(u8), arena: Allocator, indent: []const u8, card: []const u8, name: []const u8, value: f64) Error!void {
    // §3.4.1/§4.2.1.1 via `cardValue`: a card is written in reals and an
    // integer parameter rounds, away from zero on a tie.
    try out.print(arena, "{s}{s}.{f} = cardValue(@TypeOf({s}.{f}), {f});\n", .{
        indent, card, std.zig.fmtId(name), card, std.zig.fmtId(name), fmtF64(value),
    });
    // §9.19 `$param_given` reads the companion field when codegen emitted one.
    try out.print(arena, "{s}if (comptime @hasField(D.Model, \"{f}__given\")) @field({s}, \"{f}__given\") = true;\n", .{
        indent, std.zig.fmtString(name), card, std.zig.fmtString(name),
    });
}

/// The `//! time` grid as `times`, and each `//! wave` as `wave_<k>`.
fn timeArrays(out: *std.ArrayList(u8), arena: Allocator, d: Directives) Error!void {
    try out.appendSlice(arena, "const times = [_]f64{");
    for (d.times, 0..) |t, i| try out.print(arena, "{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(t) });
    try out.appendSlice(arena, " };\n");
    for (d.waves, 0..) |wv, k| {
        try out.print(arena, "const wave_{d} = [_]f64{{", .{k});
        for (wv.values, 0..) |v, i| try out.print(arena, "{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(v) });
        try out.appendSlice(arena, " };\n");
    }
}

/// Returns the VAMS §8 mixed-signal runner, allocated in `arena`: the same
/// device and solver, with operating points from `sim.mixed.run` (declared
/// `//! time`s plus every implicit D2A time) and discrete inputs from the
/// digital half, re-elaborated at startup. A `//! wave` is piecewise linear
/// here, equal to the fixed-grid runner's value at every declared point.
/// Device-table directives (noise, acstim, qsite, seed, limit) are a compile
/// error in the emitted runner.
pub fn renderMixed(arena: Allocator, title: []const u8, d: Directives, mx: tb.Mixed) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try head(&out, arena, title);
    try out.appendSlice(arena, tb_runner_text.mixed_body);
    if (d.asserts_noise or d.asserts_acstim or d.asserts_qsite or d.asserts_seed or d.limits.len != 0 or d.acdyn.len != 0)
        try out.appendSlice(arena, "comptime { @compileError(title ++ \": //! noise, //! acstim, //! qsite, //! seed, //! limit and //! acdyn are not read by the mixed-signal runner\"); }\n");

    try out.print(arena, "const mixed_source = \"{f}\";\n", .{std.zig.fmtString(mx.source)});
    try out.print(arena, "const mixed_top = \"{f}\";\n", .{std.zig.fmtString(mx.top)});
    try out.print(arena, "const mixed_timescale: ?Timescale = {s};\n", .{if (mx.unit) |u|
        try std.fmt.allocPrint(arena, ".{{ .unit = {f}, .precision = {f} }}", .{ fmtF64(u), fmtF64(mx.precision.?) })
    else
        "null"});
    try timeArrays(&out, arena, d);

    // The adapter: `sim.mixed.run`'s `A`.
    try out.appendSlice(arena,
        \\
        \\const Analog = struct {
        \\    model: *D.Model,
        \\    inst: *D.Instance,
        \\    x: *[n_u]f64,
        \\    forced: *[n_u]?f64,
        \\    state: *State,
        \\    dout: *std.Io.Writer.Allocating,
        \\    n: *usize,
        \\    slots: [input_ports.len]u32,
        \\    snap_slots: [snap_ports.len]u32,
        \\    /// §7.3.6.4 the digital slots `a2d_ports` are copied into.
        \\    dig: *sim.digital.Run,
        \\    a2d_slots: [a2d_ports.len]u32,
        \\    /// §8.5.3.6 the region-1b values of the last explicit D2A event.
        \\    snaps: [snap_ports.len]f64 = @splat(0),
        \\    t: f64 = 0.0,
        \\    solved: bool = false,
        \\    /// The last finished solution, for §7.3.6.3's interpolation.
        \\    x_prev: [n_u]f64 = @splat(0.0),
        \\    t_prev: ?f64 = null,
        \\
        \\    /// §7.3.6.5 / Table 7-1: every input as the integer the digital
        \\    /// engine holds for the latest tick, the guarded reads' snapshot, and
        \\    /// the explicit D2A terms delivered to this solve. The fields are
        \\    /// parameters to the device, so its parameter-only prep is redone.
        \\    pub fn setInputs(a: *Analog, dig: *sim.digital.Run, fired: u64) !void {
        \\        a.flush();
        \\        inline for (input_ports, 0..) |p, i| if (p.xz) |xz| {
        \\            // §7.3.2 read four-state: both planes, and x or z is a value.
        \\            const v = dig.values[a.slots[i]];
        \\            setField(a.model, p.field, v.asInt() orelse @as(i64, @bitCast(v.values()[0])));
        \\            setField(a.model, xz, @as(i64, @bitCast(v.unknowns()[0])));
        \\        } else setField(a.model, p.field, mixedInput(dig, a.slots[i], p.name));
        \\        inline for (snap_ports, 0..) |p, i| setField(a.model, p.field, a.snaps[i]);
        \\        inline for (event_ports, 0..) |p, k| setField(a.model, p.field, @intFromBool(fired >> k & 1 != 0));
        \\        if (comptime @hasDecl(D, "setup")) D.setup(Dual, a.model, a.inst);
        \\    }
        \\
        \\    /// §5.10.3.3 the device's next timer instant after `t`, if it has one.
        \\    pub fn breakpoint(a: *Analog, t: f64) ?f64 {
        \\        const m: ?f64 = if (comptime @hasDecl(D, "nextBreakpoint")) D.nextBreakpoint(a.model, t) else null;
        \\        const i: ?f64 = if (comptime @hasDecl(D, "pendingBreakpoint")) D.pendingBreakpoint(a.inst, t) else null;
        \\        return if (m != null and i != null) @min(m.?, i.?) else m orelse i;
        \\    }
        \\
        \\    pub fn snapshot(a: *Analog, dig: *sim.digital.Run) !void {
        \\        inline for (snap_ports, 0..) |p, i| a.snaps[i] = mixedInput(dig, a.snap_slots[i], p.name);
        \\    }
        \\
        \\    pub fn solveAt(a: *Analog, t: f64, dt: f64, first: bool, last: bool) !void {
        \\
    );
    for (d.waves, 0..) |wv, k|
        try out.print(arena, "        set(a.x, a.forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try out.appendSlice(arena,
        \\        sim_state.t = t;
        \\        sim_state.dt = dt;
        \\        sim_state.initial_step = first;
        \\        sim_state.final_step = last;
        \\        sim_state.analog_initial = first;
        \\        a.solved = solve(a.x, a.forced, a.model, a.inst);
        \\        a.t = t;
        \\    }
        \\
        \\    pub fn finish(a: *Analog) !void {
        \\        a.flush();
        \\        point(a.n.*, a.x, a.model, a.inst);
        \\        stepPost(a.model, a.inst, a.x, a.state, a.solved);
        \\        // §7.3.6.4: what the accepted solution left in each held variable.
        \\        inline for (a2d_ports, 0..) |p, i| {
        \\            const v = @field(a.inst, p.field);
        \\            try a.dig.a2dWrite(a.a2d_slots[i], if (@TypeOf(v) == f64) v else @as(f64, @floatFromInt(v)));
        \\        }
        \\        a.n.* += 1;
        \\        a.x_prev = a.x.*;
        \\        a.t_prev = a.t;
        \\    }
        \\
        \\    /// VAMS §7.3.6.3 `V(n1)` / `V(n1, n2)` for a digital expression: the
        \\    /// tentative solution (`t` null), or the value "calculated for the
        \\    /// time corresponding to a real promotion of the digital time",
        \\    /// linear between the last finished solution and the tentative one.
        \\    pub fn probe(a: *Analog, t: ?f64, n1: []const u8, n2: ?[]const u8) !f64 {
        \\        const now = try potential(a.x, n1, n2);
        \\        const tq = t orelse return now;
        \\        const tp = a.t_prev orelse return now;
        \\        if (tq >= a.t or a.t <= tp) return now;
        \\        const before = try potential(&a.x_prev, n1, n2);
        \\        if (tq <= tp) return before;
        \\        return before + (now - before) * (tq - tp) / (a.t - tp);
        \\    }
        \\
        \\    /// The digital half's own §17 output, in time order with the analog
        \\    /// points: everything it printed up to the tick being solved.
        \\    fn flush(a: *Analog) void {
        \\        std.debug.print("{s}", .{a.dout.written()});
        \\        a.dout.clearRetainingCapacity();
        \\    }
        \\};
        \\
        \\
    );
    // Each digital name beside its `Model` field.
    var buf: [naming.max_name_len]u8 = undefined;
    try out.appendSlice(arena, "const input_ports = [_]Port{");
    for (mx.inputs) |name| {
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\"", .{ std.zig.fmtString(name), naming.sanitize(&buf, name) catch return error.OutOfMemory });
        for (mx.xz) |x| if (std.mem.eql(u8, x, name)) {
            const field = naming.sanitize(&buf, try std.fmt.allocPrint(arena, "{s}__xz", .{name})) catch return error.OutOfMemory;
            try out.print(arena, ", .xz = \"{s}\"", .{field});
        };
        try out.appendSlice(arena, " },");
    }
    try out.appendSlice(arena, " };\nconst snap_ports = [_]Port{");
    for (mx.snaps) |name| {
        const field = naming.sanitize(&buf, try std.fmt.allocPrint(arena, "{s}__1b", .{name})) catch return error.OutOfMemory;
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(name), field });
    }
    try out.appendSlice(arena, " };\nconst event_ports = [_]EventPort{");
    for (mx.events) |ev| try out.print(arena, " .{{ .name = \"{f}\", .edge = .{t}, .field = \"{s}\" }},", .{ std.zig.fmtString(ev.name), ev.edge, naming.sanitize(&buf, ev.param) catch return error.OutOfMemory });
    try out.appendSlice(arena, " };\n");
    // VAMS §7.8.4 the inserted connect modules, which the source the digital
    // half re-elaborates does not hold (`sim.digital.Insert`).
    try out.appendSlice(arena, "const mixed_inserts = [_]sim.digital.Insert{");
    for (mx.inserts) |row| {
        try out.appendSlice(arena, " .{");
        inline for (@typeInfo(@TypeOf(row)).@"struct".fields) |f|
            try out.print(arena, " .{s} = \"{f}\",", .{ f.name, std.zig.fmtString(@field(row, f.name)) });
        try out.appendSlice(arena, " },");
    }
    try out.appendSlice(arena, " };\n");
    // VAMS §7.3.6.4 each analog variable a digital expression reads, beside
    // the §5.10 held `Instance` field its value is copied from. A variable
    // that is not held is left out, and the digital half refuses the read.
    try out.appendSlice(arena, "const a2d_ports = [_]Port{");
    var mod_buf: [naming.max_name_len]u8 = undefined;
    const mod = naming.sanitize(&mod_buf, mx.top) catch return error.OutOfMemory;
    for (mx.reads) |name| for (mx.held) |h| if (std.mem.eql(u8, h.name, name)) {
        const leaf = naming.sanitize(&buf, name) catch return error.OutOfMemory;
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}__held__{s}\" }},", .{ std.zig.fmtString(name), mod, leaf });
        break;
    };
    // VAMS §6.3 the card's root parameters, so the digital half reads the
    // values `Model` gets (`sim.digital.Mixed.params`).
    try out.appendSlice(arena, " };\nconst mixed_params = [_]sim.digital.Param{");
    for (d.params) |p| try out.print(arena, " .{{ .name = \"{f}\", .value = {f} }},", .{ std.zig.fmtString(p.name), fmtF64(p.value) });
    // The host has already derived these values, including defaults that the
    // digital expression subset cannot evaluate. Copy from each analysis's
    // actual Model, after card writes and per-point parameter overrides.
    try out.appendSlice(arena, " };\nconst mixed_real_ports = [_]Port{");
    for (mx.params) |p| {
        if (p.ty != .real) continue;
        const read = for (mx.param_reads) |name| {
            if (std.mem.eql(u8, p.name, name)) break true;
        } else false;
        if (!read) continue;
        try out.print(arena, " .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(p.name), naming.sanitize(&buf, p.name) catch return error.OutOfMemory });
    }
    try out.appendSlice(arena, " };\nconst mixed_reads = blk: {\n    var names: [a2d_ports.len][]const u8 = undefined;\n    for (a2d_ports, &names) |p, *n| n.* = p.name;\n    const out = names;\n    break :blk out;\n};\n\n");

    // --- main ---------------------------------------------------------------
    try out.appendSlice(arena,
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| try setCard(&out, arena, "    ", "model", p.name, p.value);
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "derive")) D.derive(Val, &model);
        \\    shapeCheck(&model);
        \\    var inst: D.Instance = .{};
        \\
    );
    try out.print(arena, "    inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try out.print(arena, "    sim_state = .{{ .kind = .{t} }};\n", .{d.analysis});
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model, &inst);
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\    var n: usize = 0;
        \\
    );
    // Each sweep point is its own analysis: fresh digital elaboration and `State`.
    const points = try expand(arena, d);
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points, 0..) |pt, pi| {
        try out.appendSlice(arena, "    {\n");
        // §9.5.1.1, as in the fixed-grid runner: every point here is an analysis.
        if (pi != 0)
            try out.appendSlice(arena, "        if (comptime contract.fileIo(D)) |f| if (f.new_analysis) |g| g();\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| try setCard(&out, arena, "        ", "pm", s.name, v);
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"derive\")) D.derive(Val, &pm);\n");
            try out.appendSlice(arena, "        shapeCheck(&pm);\n");
        }
        try out.print(arena,
            \\        var x: [n_u]f64 = @splat(0.0);
            \\        var forced: [n_u]?f64 = @splat({s});
            \\        if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {{
            \\            if (nodeset_i) |v| x[i] = v;
            \\        }};
            \\        var state = newState(&{s}, &inst);
            \\
        , .{ if (d.solve_free) "null" else "0.0", mdl });
        for (d.op_states) |u| try out.print(arena, "        forced[{d}] = null;\n", .{u});
        for (d.bias) |b|
            try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        for (d.sweeps, pt[0..d.sweeps.len]) |s, v|
            try out.print(arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
        try out.print(arena, "        runMixed(&{s}, &inst, &x, &forced, &state, &n);\n    }}\n", .{mdl});
    }
    try out.appendSlice(arena, if (d.print_residual)
        \\}
        \\
        \\const print_residual = true;
        \\
    else
        \\}
        \\
        \\const print_residual = false;
        \\
    );
    return out.items;
}

/// Returns a Clause 12 analog host library (§12.7 to §12.10, §12.18,
/// §12.31.3), allocated in `arena`: the device and solver behind a C
/// interface, stepped by a host that owns the time walk (`src/vpi/analog.zig`),
/// since §12.31.3 lets a VPI application force or reject a solution time. It
/// exports: solve at t tentatively, accept the last solution, read x, and read
/// each §5.6 row's value; the device must be compiled with
/// `Options.vpi_contribs`. Only an accepted solve writes history, so a rejected
/// point needs no undo. Every unknown is solved for (§3.6.1) unless a
/// `//! bias`/`//! wave` line pins it.
pub fn renderVpiLib(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try head(&out, arena, title);
    try timeArrays(&out, arena, d);
    try out.appendSlice(arena, tb_runner_text.vpi_lib_body);

    // --- open: the card, the instance, the unknowns -----------------------
    try out.appendSlice(arena,
        \\export fn vera_vpi_open(kind: u8) callconv(.c) void {
        \\    g_model = .{};
        \\
    );
    for (d.params) |p| try setCard(&out, arena, "    ", "g_model", p.name, p.value);
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "derive")) D.derive(Val, &g_model);
        \\    shapeCheck(&g_model);
        \\    g_inst = .{};
        \\
    );
    try out.print(arena, "    g_inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try out.appendSlice(arena,
        \\    sim_state = .{ .kind = @enumFromInt(kind) };
        \\    if (comptime @hasDecl(D, "systf_calls")) g_inst.systf = if (host_call != null) &host_systf else &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) g_inst.plusargs = &.{};
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &g_model, &g_inst);
        \\    g_x = @splat(0.0);
        \\    g_forced = @splat(null);
        \\    if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {
        \\        if (nodeset_i) |v| g_x[i] = v;
        \\    };
        \\
    );
    for (d.bias) |b|
        try out.print(arena, "    set(&g_x, &g_forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
    try out.appendSlice(arena,
        \\    g_state = newState(&g_model, &g_inst);
        \\    q_prev = @splat(0.0);
        \\    g_solved = false;
        \\}
        \\
        \\export fn vera_vpi_solve(t: f64, dt: f64, first: bool, last: bool) callconv(.c) bool {
        \\
    );
    for (d.waves, 0..) |wv, k|
        try out.print(arena, "    set(&g_x, &g_forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try out.appendSlice(arena,
        \\    sim_state.t = t;
        \\    sim_state.dt = dt;
        \\    sim_state.initial_step = first;
        \\    sim_state.final_step = last;
        \\    sim_state.analog_initial = first;
        \\    g_solved = solve(&g_x, &g_forced, &g_model, &g_inst);
        \\    return g_solved;
        \\}
        \\
        \\const print_residual = false;
        \\
    );
    return out.items;
}

/// The relative compare for `white`/`flicker`/`ef`/`points`, emitted locally
/// only where a `//! noise` line asks for a number.
const noise_close =
    \\        const nclose = struct {
    \\            fn f(g: f64, w: f64, rt: f64) bool {
    \\                return @abs(g - w) <= rt * @max(@abs(g), @abs(w));
    \\            }
    \\        }.f;
    \\
;

/// Emits the checks of the comptime §4.6.4 fields: the source label
/// (§4.6.4.1/.2/.3) and the tabulated spectrum (§4.6.4.3/.4), one guarded
/// statement per asserting line.
fn emitNoiseComptime(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    var any_points = false;
    for (d.noise) |w| {
        if (w.points != null) any_points = true;
    }
    var any = any_points;
    for (d.noise) |w| {
        if (w.name != null or w.interp != null) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "    if (comptime @hasDecl(D, \"noise_gens\")) {\n");
    if (any_points) try out.appendSlice(arena, noise_close);
    for (d.noise, 0..) |w, k| {
        if (w.name == null and w.interp == null and w.points == null) continue;
        try out.print(arena, "        if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        if (w.name) |nm| try out.print(
            arena,
            "            std.debug.print(\"noise[{d}].name got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                "                D.noise_gens[{d}].name, \"{f}\",\n" ++
                "                @intFromBool(std.mem.eql(u8, D.noise_gens[{d}].name, \"{f}\")),\n" ++
                "            }});\n",
            .{ k, k, std.zig.fmtString(nm), k, std.zig.fmtString(nm) },
        );
        if (w.interp != null or w.points != null) {
            // Only a `.table` row has a spectrum; `points` on another row
            // FAILs with a reason instead of crashing on `g.table.?`.
            try out.print(arena,
                \\            if (D.noise_gens[{d}].table) |ti| {{
                \\                const tbl = D.noise_tables[ti];
                \\
            , .{k});
            if (w.interp) |ip| try out.print(
                arena,
                "                std.debug.print(\"noise[{d}].interp got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                    "                    @tagName(tbl.interp), \"{s}\",\n" ++
                    "                    @intFromBool(std.mem.eql(u8, @tagName(tbl.interp), \"{s}\")),\n" ++
                    "                }});\n",
                .{ k, ip, ip },
            );
            if (w.points) |pts| {
                // §4.6.4.3 array-parameter input: `noise_tables` holds the
                // declared defaults and the card's knots are `noiseTablePoints`,
                // one flat array with table `ti`'s segment after every earlier
                // table's. Devices of literal tables lack the hook.
                try out.appendSlice(arena,
                    \\                const card = if (comptime @hasDecl(D, "noiseTablePoints"))
                    \\                    D.noiseTablePoints(&model)
                    \\                else
                    \\                    [_][2]f64{};
                    \\                var off: usize = 0;
                    \\                for (D.noise_tables[0..ti]) |t0| off += t0.points.len;
                    \\                const got_pts: []const [2]f64 = if (comptime @hasDecl(D, "noiseTablePoints"))
                    \\                    card[off..][0..tbl.points.len]
                    \\                else
                    \\                    tbl.points;
                    \\
                );
                try out.appendSlice(arena, "                const want_pts = [_][2]f64{");
                for (pts, 0..) |p, i| try out.print(arena, "{s}.{{ {f}, {f} }}", .{
                    if (i == 0) " " else ", ", fmtF64(p[0]), fmtF64(p[1]),
                });
                try out.print(arena,
                    \\ }};
                    \\                var pts_ok = got_pts.len == want_pts.len;
                    \\                if (pts_ok) for (got_pts, want_pts) |g, wp| {{
                    \\                    if (!nclose(g[0], wp[0], {f}) or !nclose(g[1], wp[1], {f})) {{
                    \\                        pts_ok = false;
                    \\                        break;
                    \\                    }}
                    \\                }};
                    \\                std.debug.print("noise[{d}].points got={{any}} want={{any}} ok={{d}}\n", .{{
                    \\                    got_pts, want_pts, @intFromBool(pts_ok),
                    \\                }});
                    \\
                , .{ fmtF64(w.rtol), fmtF64(w.rtol), k });
            }
            try out.print(arena,
                \\            }} else std.debug.print("noise[{d}].table got=none want=a table ok=0\n", .{{}});
                \\
            , .{k});
        }
        try out.appendSlice(arena, "        }\n");
    }
    try out.appendSlice(arena, "    }\n");
}

/// Emits the §4.6.4.1/.2 `white`, `flicker` and `ef` checks, read from
/// `noisePsd` at the enclosing operating point. `mdl` names the card.
fn emitNoisePsd(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    var any = false;
    for (d.noise) |w| {
        if (w.needsPoint()) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"noisePsd\")) {\n");
    try out.appendSlice(arena, noise_close);
    try out.print(arena, "            const psd = D.noisePsd(Val, x, &{s}, &inst, sim_state);\n", .{mdl});
    for (d.noise, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try out.print(arena, "            if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        // §4.6.4.6: a density is scaled by the square of the use's
        // coefficient, an exponent is not scaled at all.
        const fields = [_]struct { []const u8, ?f64, bool }{
            .{ "white", w.white, true },
            .{ "flicker", w.flicker, true },
            .{ "ef", w.ef, false },
        };
        for (fields) |f| {
            const want = f[1] orelse continue;
            const got = if (f[2])
                try std.fmt.allocPrint(arena, "psd[{d}].{s} * psd[{d}].coeff * psd[{d}].coeff", .{ k, f[0], k, k })
            else
                try std.fmt.allocPrint(arena, "psd[{d}].{s}", .{ k, f[0] });
            try out.print(
                arena,
                "                std.debug.print(\"noise[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    {s}, {f},\n" ++
                    "                    @intFromBool(nclose({s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], got, fmtF64(want), got, fmtF64(want), fmtF64(w.rtol) },
            );
        }
        try out.appendSlice(arena, "            }\n");
    }
    try out.appendSlice(arena, "        }\n");
}

/// Emits the comptime §4.6.3 `ac_gens` checks: source count, branch and
/// analysis name, in one block.
fn emitAcTopology(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
    try out.appendSlice(arena,
        \\
        \\    // §4.6.3: what this device tells a host about its AC stimuli. The
        \\    // model's own text cannot see this either — what a `CHECK` on
        \\    // `ac_stim` reads back is the residual's real part, `mag*cos(phase)`
        \\    // — so the phasor leaves through `ac_gens`/`acStim` and a
        \\    // `//! acstim` line is how a fixture reaches it.
        \\    {
        \\        const want = [_][]const u8{
        \\
    );
    for (d.acstim) |e| try out.print(arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
    try out.appendSlice(arena, "        };\n");
    // A parallel `?[]const u8` column: `inline for` makes the index comptime,
    // so one lookup covers every line.
    try out.appendSlice(arena, "        const want_name = [_]?[]const u8{");
    for (d.acstim, 0..) |e, i| {
        if (e.name) |nm|
            try out.print(arena, "{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(nm) })
        else
            try out.print(arena, "{s}null", .{if (i == 0) " " else ", "});
    }
    try out.appendSlice(arena,
        \\ };
        \\        _ = &want_name;
        \\        if (comptime @hasDecl(D, "ac_gens")) {
        \\            std.debug.print("acstim count got={d} want={d} ok={d}\n", .{
        \\                D.ac_gens.len, want.len, @intFromBool(D.ac_gens.len == want.len),
        \\            });
        \\            inline for (D.ac_gens, 0..) |g, i| {
        \\                // `U`'s tag names ARE the spelling contract, same as the
        \\                // `//! noise` block and the same as `//! bias`.
        \\                const got = comptime std.fmt.comptimePrint("({s},{s})", .{
        \\                    @tagName(@as(D.U, @enumFromInt(g.row))),
        \\                    @tagName(@as(D.U, @enumFromInt(g.col))),
        \\                });
        \\                const w_i: []const u8 = if (i < want.len) want[i] else "<none>";
        \\                std.debug.print("acstim[{d}] got={s} want={s} ok={d}\n", .{
        \\                    i, got, w_i, @intFromBool(std.mem.eql(u8, got, w_i)),
        \\                });
        \\                if (i < want_name.len) if (want_name[i]) |wn| {
        \\                    std.debug.print("acstim[{d}].name got={s} want={s} ok={d}\n", .{
        \\                        i, g.name, wn, @intFromBool(std.mem.eql(u8, g.name, wn)),
        \\                    });
        \\                };
        \\            }
        \\        } else {
        \\            // No table at all is the empty table, for the reason the
        \\            // `noise_gens` block gives.
        \\            std.debug.print("acstim count got=0 want={d} ok={d}\n", .{
        \\                want.len, @intFromBool(want.len == 0),
        \\            });
        \\        }
        \\    }
        \\
    );
}

/// Emits the §4.6.3 `mag` and `phase` checks, read from `acStim` at the
/// enclosing operating point (A.8.2 makes both `analog_expression`s, so they
/// may depend on bias). `mdl` names the card.
fn emitAcStim(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    var any = false;
    for (d.acstim) |w| {
        if (w.needsPoint()) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"acStim\")) {\n");
    try out.appendSlice(arena, noise_close);
    try out.print(arena, "            const stim = D.acStim(Val, x, &{s}, &inst, sim_state);\n", .{mdl});
    for (d.acstim, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try out.print(arena, "            if (comptime D.ac_gens.len > {d}) {{\n", .{k});
        const fields = [_]struct { []const u8, ?f64 }{ .{ "mag", w.mag }, .{ "phase", w.phase } };
        for (fields) |f| {
            const want = f[1] orelse continue;
            try out.print(
                arena,
                "                std.debug.print(\"acstim[{d}].{s} got={{d}} want={{d}} ok={{d}}\\n\", .{{\n" ++
                    "                    stim[{d}].{s}, {f},\n" ++
                    "                    @intFromBool(nclose(stim[{d}].{s}, {f}, {f})),\n" ++
                    "                }});\n",
                .{ k, f[0], k, f[0], fmtF64(want), k, f[0], fmtF64(want), fmtF64(w.rtol) },
            );
        }
        try out.appendSlice(arena, "            }\n");
    }
    try out.appendSlice(arena, "        }\n");
}

/// Emits the `//! acdyn` checks (`tb.AcDynWant`): `acDyn`'s term at each named
/// slot and frequency, at the enclosing operating point. `mdl` names the card.
fn emitAcDyn(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    for (d.acdyn) |w| {
        try out.print(arena, "        {{\n            const ad = acDynAt(ix(\"{f}\"), ix(\"{f}\"), 2.0 * std.math.pi * {f}, &x, &{s}, &inst);\n", .{
            std.zig.fmtString(w.row), std.zig.fmtString(w.col), fmtF64(w.f), mdl,
        });
        const parts = [_]struct { []const u8, f64 }{ .{ "re", w.re }, .{ "im", w.im } };
        for (parts) |p| try out.print(
            arena,
            "            std.debug.print(\"acdyn[({f},{f}) f={f}].{s} got={{e}} want={{e}} ok={{d}}\\n\", .{{ ad.{s}, @as(f64, {f}), @intFromBool(@abs(ad.{s} - {f}) <= {f}) }});\n",
            .{ std.zig.fmtString(w.row), std.zig.fmtString(w.col), fmtF64(w.f), p[0], p[0], fmtF64(p[1]), p[0], fmtF64(p[1]), fmtF64(w.tol) },
        );
        try out.appendSlice(arena, "        }\n");
    }
}

/// Returns the cartesian product of `sweeps` then `psweeps`, last varying
/// fastest, allocated in `arena`. Each point holds the unknown columns, then
/// the parameter columns. Fails with `error.TooManyPoints` past `max_points`.
pub fn expand(arena: Allocator, d: Directives) Error![]const []const f64 {
    const dims = d.sweeps.len + d.psweeps.len;
    if (dims == 0) return &.{&.{}};
    const col = struct {
        fn at(dd: Directives, k: usize) Sweep {
            return if (k < dd.sweeps.len) dd.sweeps[k] else dd.psweeps[k - dd.sweeps.len];
        }
    };
    var total: usize = 1;
    for (0..dims) |k| {
        total *|= col.at(d, k).values.len;
        if (total > max_points) return error.TooManyPoints;
    }
    const rows = try arena.alloc([]const f64, total);
    for (rows, 0..) |*row, n| {
        const cells = try arena.alloc(f64, dims);
        var rem = n;
        var k = dims;
        while (k > 0) {
            k -= 1;
            const vals = col.at(d, k).values;
            cells[k] = vals[rem % vals.len];
            rem /= vals.len;
        }
        row.* = cells;
    }
    return rows;
}

/// Formats `x` as a Zig expression: shortest round-trip decimal, or a
/// `std.math` call for inf and nan, which have no literal.
pub fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64) {
    return .{ .data = x };
}

fn formatF64(x: f64, w: *Io.Writer) Io.Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("std.math.nan(f64)");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)");
    try w.print("{d}", .{x});
}
