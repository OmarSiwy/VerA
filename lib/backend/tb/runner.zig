//! Runner generation: the testbench `main` for one fixture.
//!
//! In: the testbench plan and the device's exported tables. Out: the runner's Zig source.
//!
//! LRM clauses this file's code cites: §1, §2.8.3, §3.4.1, §3.4.5, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.6, §6.3.4, §9.19.
//!
//! Cut verbatim from `tb.zig`.

const std = @import("std");
const tb = @import("../tb.zig");
const tb_runner_text = @import("runner_text.zig");
const naming = @import("../naming.zig");
const Lowered = @import("ir").Lowered;
const Mir = @import("ir").Mir;
const Io = tb.Io;
const Allocator = tb.Allocator;
const Error = tb.Error;
const Sweep = tb.Sweep;
const Directives = tb.Directives;
const max_points = tb.max_points;

// ---------------------------------------------------------------------------
// Runner generation
// ---------------------------------------------------------------------------

/// Emit the runner's Zig source. `title` is what each transcript block is keyed
/// by — the fixture's file stem, so a failing diff names the fixture.
///
/// Everything is written with `std.debug.print`, which is also where the
/// generated `$strobe` writes: ONE stream, so the interleaving of the model's
/// own output with the harness's is deterministic and diffable. stdout is left
/// alone for a caller that wants to pipe something else.
pub fn renderRunner(arena: Allocator, title: []const u8, d: Directives) Error![]const u8 {
    if (d.mixed) |mx| return renderMixed(arena, title, d, mx);
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, tb_runner_text.runner_head);
    try print(&out, arena, "const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try out.appendSlice(arena, tb_runner_text.runner_body);

    // --- main -------------------------------------------------------------
    try out.appendSlice(arena,
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| {
        // §3.4.1/§4.2.1.1 via `cardValue`: a card is written in reals and an
        // integer parameter rounds, away from zero on a tie. Writing the real
        // straight into an `i64` field was not even a wrong number — it was a
        // `zig build-exe` failure, "fractional component prevents float value
        // '-1.5' from coercion to type 'i64'".
        try print(&out, arena, "    model.{f} = cardValue(@TypeOf(model.{f}), {f});\n", .{
            std.zig.fmtId(p.name), std.zig.fmtId(p.name), fmtF64(p.value),
        });
        // §9.19 `$param_given` is answered from a companion field when codegen
        // emitted one. Setting the value without it would make an explicit
        // override read as "not given".
        try print(
            &out,
            arena,
            "    if (comptime @hasField(D.Model, \"{f}__given\")) @field(model, \"{f}__given\") = true;\n",
            .{ std.zig.fmtString(p.name), std.zig.fmtString(p.name) },
        );
    }
    // §6.3.4: the model card is complete only now, so this is where a parameter
    // defined over another one gets its value. It runs unconditionally — a
    // §3.4.5 localparam is re-derived even with no `//! param` line, since the
    // point of `derive` is also that a localparam is not overridable.
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "derive")) D.derive(&model);
        \\
        \\    var inst: D.Instance = .{};
        \\
    );
    try print(&out, arena, "    inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try print(&out, arena, "    inst.analysis_kind = .{t};\n", .{d.analysis});
    // §2.8.3/§12.32: this testbench IS a host, so it answers for the device's
    // unresolved `$name`s like any other. It binds `no_vpi_app` rather than
    // being exempt from `validateHost` — an exemption for the tool's own host is
    // how a seam stops being tested, and it is the one host that certainly
    // exercises every device VerA emits.
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
    //
    // Before the operating points, and once: `noise_gens` is a COMPTIME table,
    // a property of the model and not of a bias. Printing it per point would
    // repeat one fact N times and make a sweep's transcript say N times as much
    // as it knows.
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
        for (d.noise) |e| try print(&out, arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
        try out.appendSlice(arena,
            \\        };
            \\        if (comptime @hasDecl(D, "noise_gens")) {
            \\            std.debug.print("noise count got={d} want={d} ok={d}\n", .{
            \\                D.noise_gens.len, want.len, @intFromBool(D.noise_gens.len == want.len),
            \\            });
            \\            inline for (D.noise_gens, 0..) |g, i| {
            \\                var buf: [192]u8 = undefined;
            \\                // `U`'s tag names ARE the spelling contract — the same
            \\                // names a `//! bias` line uses and the same ones a
            \\                // diagnostic prints — so a fixture writes what it reads
            \\                // in the source.
            \\                // `#k` is §4.6.4.6's correlation column: two rows
            \\                // printing the same `#k` share one physical generator;
            \\                // `#null` is a row that declared no identity.
            \\                const got = std.fmt.bufPrint(&buf, "{s}({s},{s})#{?d}", .{
            \\                    @tagName(g.kind),
            \\                    @tagName(@as(D.U, @enumFromInt(g.row))),
            \\                    @tagName(@as(D.U, @enumFromInt(g.col))),
            \\                    g.source,
            \\                }) catch "<too long>";
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

    // --- one straight-line block per operating point ------------------------
    //
    // The SWEEP is the outer loop and TIME the inner one, and the §4.5 operator
    // state belongs to the inner walk: each sweep point is its own transient run
    // and starts from a fresh `State`, or the second bias would inherit the
    // first one's history and no transcript line would mean anything on its own.
    const points = try expand(arena, d);
    // §5.10.2 / Table 5-1: `initial_step` is active on the FIRST point of an
    // analysis and `final_step` on the LAST. What counts as "an analysis" here
    // is read off the runner's own shape. With `//! time` each sweep block is a
    // separate transient run — it restarts the time walk at dt = 0 with a fresh
    // `State` — so every block carries its own first and last point. Without it
    // the blocks are the steps of ONE dc sweep, and only the first and last step
    // of the whole sweep carry the events. A one-point fixture is both at once,
    // which is exactly the DCOP column of Table 5-1: both events, one point.
    const per_block = d.times.len > 1;
    var n: usize = 0;
    // `//! psweep` gives each point its OWN model card: §8.2 makes a parametric
    // sweep a series of sub-tasks, and §6.3.4 says anything derived from the
    // swept parameter has to be recomputed with it, which is `derive`'s job.
    // Without a psweep line not one byte of this changes — the shared `model`
    // built above is passed straight through, as it always was.
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points) |pt| {
        try out.appendSlice(arena, "    {\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| {
                try print(&out, arena, "        pm.{f} = cardValue(@TypeOf(pm.{f}), {f});\n", .{
                    std.zig.fmtId(s.name), std.zig.fmtId(s.name), fmtF64(v),
                });
                try print(
                    &out,
                    arena,
                    "        if (comptime @hasField(D.Model, \"{f}__given\")) @field(pm, \"{f}__given\") = true;\n",
                    .{ std.zig.fmtString(s.name), std.zig.fmtString(s.name) },
                );
            }
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"derive\")) D.derive(&pm);\n");
            // §6.3.4 again: the hoisted prep derives from the swept card too.
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"setup\")) D.setup(Dual, &pm, &inst);\n");
        }
        // `forced` is the other half of the operating point: which unknowns the
        // HOST drives, as opposed to which ones the device's own equations
        // determine. Newton needs the distinction; a bare evaluation did not.
        // Its DEFAULT is the harness's netlist — every unknown tied to the
        // reference — and `//! solve` is what unties the ones no line names.
        try print(
            &out,
            arena,
            "        var x: [n_u]f64 = @splat(0.0);\n        var forced: [n_u]?f64 = @splat({s});\n" ++
                // §3.6.3.2: "the value ... will be used as a nodeset value by
                // the analog solver". A nodeset is an INITIAL GUESS and nothing
                // more — it seeds `x` and does not touch `forced`, so Newton is
                // free to walk away from it. On a system with more than one
                // solution that is the entire point: `a08_nodeset_01`'s cubic
                // has roots at 1, 2 and 3, and which one the solve lands on is
                // decided right here.
                //
                // VerA has emitted `u_nodeset` for as long as it has parsed net
                // initializers, and nothing had ever read it — so the clause
                // was implemented up to the device boundary and no further.
                //
                // Before the `//! bias` lines below, so a fixture that names an
                // unknown outright still wins: a bias is a constraint, a
                // nodeset is a suggestion.
                "        if (comptime @hasDecl(D, \"u_nodeset\")) for (D.u_nodeset, 0..) |nodeset_i, i| {{\n" ++
                "            if (nodeset_i) |v| x[i] = v;\n" ++
                "        }};\n" ++
                "        var state = newState(&{s}, &inst);\n",
            .{ if (d.solve_free) "null" else "0.0", mdl },
        );
        for (d.bias) |b|
            try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        for (d.sweeps, pt[0..d.sweeps.len]) |s, v|
            try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
        for (d.times, 0..) |t, k| {
            for (d.waves) |wv| {
                // A short `wave` HOLDS its last value — that is how a step is
                // written without repeating the level once per remaining time.
                const v = wv.values[@min(k, wv.values.len - 1)];
                try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(wv.name), fmtF64(v) });
            }
            // §4.5.3 `ddt` divides by `dt`; the FIRST time is the DC point, so
            // it gets dt = 0 — which every operator kernel reads as "no history"
            // and answers with its DC form (§4.5.4 the initial condition,
            // §4.5.11 the filter's DC gain).
            const dt: f64 = if (k == 0) 0.0 else d.times[k] - d.times[k - 1];
            try print(&out, arena, "        inst.abstime = {f};\n        inst.dt = {f};\n", .{ fmtF64(t), fmtF64(dt) });
            // Both are written at every point, never left over from the last
            // one: the guard codegen emits reads the field as it stands when
            // `eval`/`display` runs, so a stale `true` would fire the body a
            // second time.
            try print(&out, arena, "        inst.is_initial_step = {};\n        inst.is_final_step = {};\n", .{
                k == 0 and (per_block or n == 0),
                k + 1 == d.times.len and (per_block or n + 1 == points.len),
            });
            // §5.2.1 `analog initial` is re-executed per SUB-TASK, which in this
            // runner is one point of the sweep: the first time step of every
            // block, whether or not that block is the first of the analysis.
            // That is the one place it differs from `is_initial_step` above, and
            // the difference is only visible under `//! psweep` — where the
            // clause's "if a parameter ... is changed during a sub-task ... the
            // analog initial block shall be re-executed" is exactly the case.
            try print(&out, arena, "        inst.is_analog_initial = {};\n", .{k == 0});
            // §5.6 the model is evaluated AT A SOLUTION: solve first, then let
            // the model print. Every `//!` value is still exactly itself — it
            // came in as a constraint row — and everything else is now the
            // number the device's own equations put there.
            try print(&out, arena, "        const solved{d} = solve(&x, &forced, &{s}, &inst);\n", .{ n, mdl });
            try print(&out, arena, "        point({d}, &x, {f}, &{s}, &inst);\n", .{ n, fmtF64(t), mdl });
            // §4.6.4.1/.2 the PSD is a function of the BIAS, so unlike the
            // topology it cannot be printed once beside the comptime table.
            // The first point is the one a fixture states: it is the only
            // point every fixture has, and pinning a density at a named bias
            // is the whole content of a bias-dependent `white=`.
            if (n == 0) try emitNoisePsd(arena, &out, d, mdl);
            // §4.6.3 the magnitude and phase are the model CARD's — a parameter
            // is a legal `mag` — so they need a card, which is this block's
            // `mdl`; `//! psweep` gives each point its own and the first point
            // is the one a fixture states, exactly as for the PSD above.
            if (n == 0) try emitAcStim(arena, &out, d, mdl);
            // §4.5.2 accepted-step bookkeeping. This is the whole reason the
            // stateful operators are observable at all: `eval` reads history out
            // of `Instance`, and only `updateState` ever writes it.
            try print(&out, arena, "        stepPost(&{s}, &inst, &x, &state, solved{d});\n", .{ mdl, n });
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

/// The mixed-signal plan of a compile, or null for a module with no discrete
/// half that needs the event queue (`Lowered.mixed_signal`). Borrowed from the
/// compile's arena.
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
    };
}

/// VAMS §8 the mixed-signal testbench: the same device and solver, but the
/// operating points come from `sim.mixed.run` — the declared `//! time`s plus
/// every implicit D2A time — and the discrete inputs from the digital half of
/// the same source, re-elaborated at startup (`sim.digital.elaborate`).
///
/// The adapter the coordinator drives is emitted per fixture, because the
/// input names and the `//! wave` lines are. A `//! wave` is PIECEWISE LINEAR
/// here: an inserted point falls between declared ones, and at every declared
/// point the value is the one the fixed-grid runner's step-hold gives.
pub fn renderMixed(arena: Allocator, title: []const u8, d: Directives, mx: tb.Mixed) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, tb_runner_text.runner_head);
    try print(&out, arena, "const title = \"{f}\";\n\n", .{std.zig.fmtString(title)});
    try out.appendSlice(arena, tb_runner_text.runner_body);
    try out.appendSlice(arena, tb_runner_text.mixed_body);
    if (d.asserts_noise or d.asserts_acstim)
        try out.appendSlice(arena, "comptime { @compileError(title ++ \": //! noise and //! acstim are not read by the mixed-signal runner\"); }\n");

    try print(&out, arena, "const mixed_source = \"{f}\";\n", .{std.zig.fmtString(mx.source)});
    try print(&out, arena, "const mixed_top = \"{f}\";\n", .{std.zig.fmtString(mx.top)});
    try print(&out, arena, "const mixed_timescale: ?Timescale = {s};\n", .{if (mx.unit) |u|
        try std.fmt.allocPrint(arena, ".{{ .unit = {f}, .precision = {f} }}", .{ fmtF64(u), fmtF64(mx.precision.?) })
    else
        "null"});
    try out.appendSlice(arena, "const times = [_]f64{");
    for (d.times, 0..) |t, i| try print(&out, arena, "{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(t) });
    try out.appendSlice(arena, " };\n");
    for (d.waves, 0..) |wv, k| {
        try print(&out, arena, "const wave_{d} = [_]f64{{", .{k});
        for (wv.values, 0..) |v, i| try print(&out, arena, "{s}{f}", .{ if (i == 0) " " else ", ", fmtF64(v) });
        try out.appendSlice(arena, " };\n");
    }

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
        try print(&out, arena, "        set(a.x, a.forced, \"{f}\", pwl(&wave_{d}, t));\n", .{ std.zig.fmtString(wv.name), k });
    try out.appendSlice(arena,
        \\        a.inst.abstime = t;
        \\        a.inst.dt = dt;
        \\        a.inst.is_initial_step = first;
        \\        a.inst.is_final_step = last;
        \\        a.inst.is_analog_initial = first;
        \\        a.solved = solve(a.x, a.forced, a.model, a.inst);
        \\        a.t = t;
        \\    }
        \\
        \\    pub fn finish(a: *Analog) !void {
        \\        a.flush();
        \\        point(a.n.*, a.x, a.t, a.model, a.inst);
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
    // Each digital name beside the `Model` field codegen spelled for it.
    var buf: [256]u8 = undefined;
    try out.appendSlice(arena, "const input_ports = [_]Port{");
    for (mx.inputs) |name| {
        try print(&out, arena, " .{{ .name = \"{f}\", .field = \"{s}\"", .{ std.zig.fmtString(name), naming.sanitize(&buf, name) catch return error.OutOfMemory });
        for (mx.xz) |x| if (std.mem.eql(u8, x, name)) {
            const field = naming.sanitize(&buf, try std.fmt.allocPrint(arena, "{s}__xz", .{name})) catch return error.OutOfMemory;
            try print(&out, arena, ", .xz = \"{s}\"", .{field});
        };
        try out.appendSlice(arena, " },");
    }
    try out.appendSlice(arena, " };\nconst snap_ports = [_]Port{");
    for (mx.snaps) |name| {
        const field = naming.sanitize(&buf, try std.fmt.allocPrint(arena, "{s}__1b", .{name})) catch return error.OutOfMemory;
        try print(&out, arena, " .{{ .name = \"{f}\", .field = \"{s}\" }},", .{ std.zig.fmtString(name), field });
    }
    try out.appendSlice(arena, " };\nconst event_ports = [_]EventPort{");
    for (mx.events) |ev| try print(&out, arena, " .{{ .name = \"{f}\", .edge = .{t}, .field = \"{s}\" }},", .{ std.zig.fmtString(ev.name), ev.edge, naming.sanitize(&buf, ev.param) catch return error.OutOfMemory });
    try out.appendSlice(arena, " };\n");
    // VAMS §7.8.4 the inserted connect modules, which the source the digital
    // half re-elaborates does not hold (`sim.digital.Insert`).
    try out.appendSlice(arena, "const mixed_inserts = [_]sim.digital.Insert{");
    for (mx.inserts) |row| {
        try out.appendSlice(arena, " .{");
        inline for (@typeInfo(@TypeOf(row)).@"struct".fields) |f|
            try print(&out, arena, " .{s} = \"{f}\",", .{ f.name, std.zig.fmtString(@field(row, f.name)) });
        try out.appendSlice(arena, " },");
    }
    try out.appendSlice(arena, " };\n");
    // VAMS §7.3.6.4 each analog variable a digital expression reads, beside
    // the §5.10 held `Instance` field (`plan/names.zig`'s spelling) its value
    // is copied from. One that is not held — assigned outside an analog event
    // statement — is left out, and the digital half refuses the read.
    try out.appendSlice(arena, "const a2d_ports = [_]Port{");
    var mod_buf: [256]u8 = undefined;
    const mod = naming.sanitize(&mod_buf, mx.top) catch return error.OutOfMemory;
    for (mx.reads) |name| for (mx.held) |h| if (std.mem.eql(u8, h.name, name)) {
        const leaf = naming.sanitize(&buf, name) catch return error.OutOfMemory;
        try print(&out, arena, " .{{ .name = \"{f}\", .field = \"{s}__held__{s}\" }},", .{ std.zig.fmtString(name), mod, leaf });
        break;
    };
    try out.appendSlice(arena, " };\nconst mixed_reads = blk: {\n    var names: [a2d_ports.len][]const u8 = undefined;\n    for (a2d_ports, &names) |p, *n| n.* = p.name;\n    const out = names;\n    break :blk out;\n};\n\n");

    // --- main ---------------------------------------------------------------
    try out.appendSlice(arena,
        \\pub fn main(init: std.process.Init.Minimal) void {
        \\    var model: D.Model = .{};
        \\
    );
    for (d.params) |p| {
        try print(&out, arena, "    model.{f} = cardValue(@TypeOf(model.{f}), {f});\n", .{
            std.zig.fmtId(p.name), std.zig.fmtId(p.name), fmtF64(p.value),
        });
        try print(&out, arena, "    if (comptime @hasField(D.Model, \"{f}__given\")) @field(model, \"{f}__given\") = true;\n", .{
            std.zig.fmtString(p.name), std.zig.fmtString(p.name),
        });
    }
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "derive")) D.derive(&model);
        \\    var inst: D.Instance = .{};
        \\
    );
    try print(&out, arena, "    inst.temperature = {f};\n", .{fmtF64(d.temp)});
    try print(&out, arena, "    inst.analysis_kind = .{t};\n", .{d.analysis});
    try out.appendSlice(arena,
        \\    if (comptime @hasDecl(D, "systf_calls")) inst.systf = &no_vpi_app;
        \\    if (comptime @hasField(D.Instance, "plusargs")) inst.plusargs = plusargs(init);
        \\    if (comptime @hasDecl(D, "setup")) D.setup(Dual, &model, &inst);
        \\    std.debug.print("=== {s} ===\n", .{title});
        \\    var n: usize = 0;
        \\
    );
    // Each sweep point is its own analysis: a fresh digital elaboration, a
    // fresh `State`, exactly as the fixed-grid runner restarts its time walk.
    const points = try expand(arena, d);
    const mdl = if (d.psweeps.len == 0) "model" else "pm";
    for (points) |pt| {
        try out.appendSlice(arena, "    {\n");
        if (d.psweeps.len != 0) {
            try out.appendSlice(arena, "        var pm = model;\n");
            for (d.psweeps, pt[d.sweeps.len..]) |s, v| {
                try print(&out, arena, "        pm.{f} = cardValue(@TypeOf(pm.{f}), {f});\n", .{ std.zig.fmtId(s.name), std.zig.fmtId(s.name), fmtF64(v) });
                try print(&out, arena, "        if (comptime @hasField(D.Model, \"{f}__given\")) @field(pm, \"{f}__given\") = true;\n", .{ std.zig.fmtString(s.name), std.zig.fmtString(s.name) });
            }
            try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"derive\")) D.derive(&pm);\n");
        }
        try print(&out, arena,
            \\        var x: [n_u]f64 = @splat(0.0);
            \\        var forced: [n_u]?f64 = @splat({s});
            \\        if (comptime @hasDecl(D, "u_nodeset")) for (D.u_nodeset, 0..) |nodeset_i, i| {{
            \\            if (nodeset_i) |v| x[i] = v;
            \\        }};
            \\        var state = newState(&{s}, &inst);
            \\
        , .{ if (d.solve_free) "null" else "0.0", mdl });
        for (d.bias) |b|
            try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(b.name), fmtF64(b.value) });
        for (d.sweeps, pt[0..d.sweeps.len]) |s, v|
            try print(&out, arena, "        set(&x, &forced, \"{f}\", {f});\n", .{ std.zig.fmtString(s.name), fmtF64(v) });
        try print(&out, arena, "        runMixed(&{s}, &inst, &x, &forced, &state, &n);\n    }}\n", .{mdl});
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

/// The relative compare the `white`/`flicker`/`ef`/`points` fields use, emitted
/// as a local rather than added to the prelude: it exists only where a `//!
/// noise` line asked for a number, and a prelude declaration would be dead in
/// every other testbench.
pub const noise_close =
    \\        const nclose = struct {
    \\            fn f(g: f64, w: f64, rt: f64) bool {
    \\                return @abs(g - w) <= rt * @max(@abs(g), @abs(w));
    \\            }
    \\        }.f;
    \\
;

/// The §4.6.4 fields that are COMPTIME properties of the device: the source
/// label (§4.6.4.1/.2/.3) and the tabulated spectrum (§4.6.4.3/.4). Emitted
/// beside the topology block, one guarded statement per asserting line, so a
/// fixture that asserts none of them adds nothing.
pub fn emitNoiseComptime(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
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
        try print(out, arena, "        if (comptime D.noise_gens.len > {d}) {{\n", .{k});
        if (w.name) |nm| try print(
            out,
            arena,
            "            std.debug.print(\"noise[{d}].name got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                "                D.noise_gens[{d}].name, \"{f}\",\n" ++
                "                @intFromBool(std.mem.eql(u8, D.noise_gens[{d}].name, \"{f}\")),\n" ++
                "            }});\n",
            .{ k, k, std.zig.fmtString(nm), k, std.zig.fmtString(nm) },
        );
        if (w.interp != null or w.points != null) {
            // A `.table` row and only a `.table` row has a spectrum here. A
            // fixture that asserts `points` on a parametric row is asserting
            // something the export cannot carry, and that is a FAIL with a
            // reason rather than a crash on `g.table.?`.
            try print(out, arena,
                \\            if (D.noise_gens[{d}].table) |ti| {{
                \\                const tbl = D.noise_tables[ti];
                \\
            , .{k});
            if (w.interp) |ip| try print(
                out,
                arena,
                "                std.debug.print(\"noise[{d}].interp got={{s}} want={{s}} ok={{d}}\\n\", .{{\n" ++
                    "                    @tagName(tbl.interp), \"{s}\",\n" ++
                    "                    @intFromBool(std.mem.eql(u8, @tagName(tbl.interp), \"{s}\")),\n" ++
                    "                }});\n",
                .{ k, ip, ip },
            );
            if (w.points) |pts| {
                // §4.6.4.3's array-parameter input: `noise_tables` then holds
                // the parameter's DECLARED DEFAULTS, and the card's own knots
                // are `noiseTablePoints` — one flat array whose segment for
                // table `ti` starts after every earlier table's points. A
                // device of literal tables does not declare the hook and this
                // reads `tbl.points`, which is the same thing.
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
                for (pts, 0..) |p, i| try print(out, arena, "{s}.{{ {f}, {f} }}", .{
                    if (i == 0) " " else ", ", fmtF64(p[0]), fmtF64(p[1]),
                });
                try print(out, arena,
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
            try print(out, arena,
                \\            }} else std.debug.print("noise[{d}].table got=none want=a table ok=0\n", .{{}});
                \\
            , .{k});
        }
        try out.appendSlice(arena, "        }\n");
    }
    try out.appendSlice(arena, "    }\n");
}

/// §4.6.4.1/.2 `white`, `flicker` and `ef`, read out of `noisePsd` at the
/// operating point this is emitted into. `model` is the caller's card name,
/// which `//! psweep` renames.
pub fn emitNoisePsd(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    var any = false;
    for (d.noise) |w| {
        if (w.needsPoint()) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"noisePsd\")) {\n");
    try out.appendSlice(arena, noise_close);
    try print(out, arena, "            const psd = D.noisePsd(x, &{s}, &inst);\n", .{mdl});
    for (d.noise, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try print(out, arena, "            if (comptime D.noise_gens.len > {d}) {{\n", .{k});
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
            try print(
                out,
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

/// §4.6.3 the COMPTIME half of the AC stimulus export: how many sources there
/// are, which branch each is on, and which analysis it answers to. One block,
/// not one per line: unlike `noise_gens`'s per-row tables there is nothing here
/// that needs a `k`-indexed statement of its own.
pub fn emitAcTopology(arena: Allocator, out: *std.ArrayList(u8), d: Directives) Error!void {
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
    for (d.acstim) |e| try print(out, arena, "            \"{f}\",\n", .{std.zig.fmtString(e.topo)});
    try out.appendSlice(arena, "        };\n");
    // A parallel `?[]const u8` column rather than a second guarded block per
    // line: `inline for` makes the index comptime, so one lookup covers every
    // line and a line that asserts no name simply has none.
    try out.appendSlice(arena, "        const want_name = [_]?[]const u8{");
    for (d.acstim, 0..) |e, i| {
        if (e.name) |nm|
            try print(out, arena, "{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(nm) })
        else
            try print(out, arena, "{s}null", .{if (i == 0) " " else ", "});
    }
    try out.appendSlice(arena,
        \\ };
        \\        _ = &want_name;
        \\        if (comptime @hasDecl(D, "ac_gens")) {
        \\            std.debug.print("acstim count got={d} want={d} ok={d}\n", .{
        \\                D.ac_gens.len, want.len, @intFromBool(D.ac_gens.len == want.len),
        \\            });
        \\            inline for (D.ac_gens, 0..) |g, i| {
        \\                var buf: [192]u8 = undefined;
        \\                // `U`'s tag names ARE the spelling contract, same as the
        \\                // `//! noise` block and the same as `//! bias`.
        \\                const got = std.fmt.bufPrint(&buf, "({s},{s})", .{
        \\                    @tagName(@as(D.U, @enumFromInt(g.row))),
        \\                    @tagName(@as(D.U, @enumFromInt(g.col))),
        \\                }) catch "<too long>";
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

/// §4.6.3 `mag` and `phase`, read out of `acStim` at the operating point this
/// is emitted into — `x` is that point, because A.8.2's magnitude and phase are
/// `analog_expression`s and a swept-amplitude source has a phasor that depends
/// on the bias. `model` is the caller's card name, which `//! psweep` renames —
/// the same contract `emitNoisePsd` has.
pub fn emitAcStim(arena: Allocator, out: *std.ArrayList(u8), d: Directives, mdl: []const u8) Error!void {
    var any = false;
    for (d.acstim) |w| {
        if (w.needsPoint()) any = true;
    }
    if (!any) return;
    try out.appendSlice(arena, "        if (comptime @hasDecl(D, \"acStim\")) {\n");
    try out.appendSlice(arena, noise_close);
    try print(out, arena, "            const stim = D.acStim(x, &{s}, &inst);\n", .{mdl});
    for (d.acstim, 0..) |w, k| {
        if (!w.needsPoint()) continue;
        try print(out, arena, "            if (comptime D.ac_gens.len > {d}) {{\n", .{k});
        const fields = [_]struct { []const u8, ?f64 }{ .{ "mag", w.mag }, .{ "phase", w.phase } };
        for (fields) |f| {
            const want = f[1] orelse continue;
            try print(
                out,
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

/// The cartesian product of the sweep lines, last varying fastest. One
/// allocation per point.
/// A point is `sweeps.len + psweeps.len` wide: the unknown columns first, then
/// the parameter columns, so `psweep` varies fastest and a parameter sweep reads
/// as the inner loop it is.
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

/// `{d}` on an f64 is shortest-round-trip, which is exact but can print `1e-14`
/// — legal Zig. What it must never print is `inf`/`nan`, which are not.
pub fn fmtF64(x: f64) std.fmt.Alt(f64, formatF64) {
    return .{ .data = x };
}

pub fn formatF64(x: f64, w: *Io.Writer) Io.Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("std.math.nan(f64)");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)");
    try w.print("{d}", .{x});
}

pub fn print(out: *std.ArrayList(u8), arena: Allocator, comptime fmt: []const u8, args: anytype) Error!void {
    var aw: Io.Writer.Allocating = .fromArrayList(arena, out);
    defer out.* = aw.toArrayList();
    aw.writer.print(fmt, args) catch return error.OutOfMemory;
}
