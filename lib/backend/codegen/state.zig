//! §4.5.2 the analog-operator state machine, and §5.6.5 zero-parasitic collapse.
//!
//! In: the stateful operator calls. Out: `initState`/`updateState`/`stateCtl`, advancing each
//! operator's `Instance` slots once per accepted timepoint.
//!
//! LRM clauses this file's code cites: §4.5.2, §4.5.7, §4.5.10, §4.5.12, §5.6.1.3, §5.6.5, §5.10.3, §5.10.3.3, §5.10.5, §9.13.1, §9.17.1, §9.17.2.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_state.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const CollapsePair = @import("plan/topology.zig").CollapsePair;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_hoist = @import("hoist.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const opdb = @import("ir").op;
const cg_filters = @import("../cg_filters.zig");
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const opHasState = codegen.opHasState;
const enableArgIdx = codegen.enableArgIdx;

// =======================================================================
// §4.5.2 the analog-operator state machine
// =======================================================================

/// What the accepted-step body needs, decided once for `updateState` and
/// `acceptQ` alike.
const Accept = struct {
    /// Some operator steps on `dt = inst.abstime - state.t_prev`.
    uses_dt: bool = false,
    /// Some operator input, held variable or path latch is a core field.
    uses_core: bool = false,
    /// `State.t_prev` has a reader: `dt`, or a §4.5.7 `absdelay` freezing its
    /// td at the first evaluation. Without one the field and its store are
    /// not emitted, and a path-latch-only `State` is `struct {}`.
    reads_t_prev: bool = false,
};

fn scanAccept(self: *Gen) Error!Accept {
    var a: Accept = .{};
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const k = u.op;
        a.uses_dt = a.uses_dt or opdb.get(k).needs_dt;
        if (k == .absdelay and (try gen_call.absdelayFreezes(self, self.names.opArgs(self.mir, i)) or
            try gen_call.absdelayMaxdSampled(self, self.names.opArgs(self.mir, i)))) a.reads_t_prev = true;
        if (!opHasState(k)) continue;
        a.uses_core = a.uses_core or gen_unit.opInputIdx(self, @intCast(i)) != none_u32;
    }
    for (self.core.held_idx) |k| a.uses_core = a.uses_core or k != none_u32;
    a.uses_core = a.uses_core or gen_file.pathLatches(self);
    a.reads_t_prev = a.reads_t_prev or a.uses_dt;
    return a;
}

/// Advance every stateful operator once the step is accepted. State lives in
/// `Instance` (eval reads it); `State` only carries the bookkeeping the
/// contract wants in its own struct.
pub fn emitStateMachine(self: *Gen) Error!void {
    const acc = try scanAccept(self);
    const uses_core = acc.uses_core;
    try self.w(
        \\/// §4.5.2 accepted-step bookkeeping for the analog operators.
        \\pub const State = struct {{
        \\
    , .{});
    if (acc.reads_t_prev) try self.w("    t_prev: f64 = 0.0,\n", .{});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "    limiter_previous: [{d}]f64 = @splat(0.0),\n",
        .{self.lowered.limit_slots.items.len},
    );
    if (self.lowered.uses.contains(.newton_iter)) try self.w("    newton_iteration: u32 = 1,\n", .{});
    try self.w(
        \\}};
        \\
        \\pub fn initState(_: *const Model, _: *Instance) State {{
        \\    return .{{}};
        \\}}
        \\
        \\pub fn updateState({0s}: *const Model, inst: *Instance, {1s}: [n_u]f64, {2s}: *State) contract.UpdateResult {{
        \\
    , .{
        // Both go unread when the only accepted-step work is §9.13.1's
        // internal-seed advance, which is a function of the seed alone.
        if (uses_core) "model" else "_",
        if (uses_core) "x" else "_",
        if (acc.reads_t_prev) "state" else "_",
    });
    if (uses_core) try self.w(
        \\    var xr: [n_u]R = undefined;
        \\    for (x, 0..) |xv, i| xr[i] = R.con(xv);
        \\
    , .{});
    // ONE core evaluation for every operator's input, not one per operator:
    // the inputs are fields of the same struct, so the accepted-step sweep
    // costs exactly one model evaluation however many operators there are.
    // `model` is always live because that call reads it. `dt` is not.
    if (uses_core) try self.w("    const m = core(R, xr, model, {s});\n", .{try gen_hoist.probeInstance(self)});
    try emitAcceptBody(self, acc, ".v");
    try self.w(
        \\    return .ok;
        \\}}
        \\
        \\
    , .{});
    try emitStateClass(self);
    if (gen_file.emitsStateCtl(self)) try gen_file.emitStateCtl(self);
    try emitAdvanceIteration(self);
    try emitAcceptQ(self, acc);
}

/// `contract.StateClass`, so a host's GPU gate reads one decl instead of
/// inferring the class from which fields exist. `.path_latch`: the state is
/// the §5.6.1.2 latches alone — `updateState` only stages `wb`/`wq` and
/// `stateCtl(.commit)` latches them, with no operator history, held FSM or
/// §9.13.1 seed to advance. Anything else `updateState` carries is `.history`.
fn emitStateClass(self: *Gen) Error!void {
    const latch_only = gen_file.pathLatches(self) and !gen_file.hasStatefulOps(self) and
        self.lowered.rng_auto_sites == 0;
    try self.w("pub const state_class: contract.StateClass = .{s};\n\n", .{
        if (latch_only) "path_latch" else "history",
    });
}

/// §5.6.1.2 + §4.5.2 the accepted-point pass as ONE core evaluation: the
/// charge `q` at `x` and everything `updateState` stages. Built from
/// `emitFused`'s mechanism — both halves are written against one hoisted
/// `core` call. Emitted beside `updateState` whenever the device has a
/// reactive half; a host that fetches `q` at the accepted point calls this
/// instead of `q` followed by `updateState`, which ran the core twice.
fn emitAcceptQ(self: *Gen, acc: Accept) Error!void {
    if (!gen_dispatch.anyQ(self)) return;
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = true; // the §9.17 resets below always write it
    self.core_wanted = false;
    self.core_hoisted = true;
    defer self.core_hoisted = false;
    try self.w(
        \\/// §5.6.1.2 + §4.5.2 the accepted-point pass from ONE core evaluation.
        \\/// Returns `q(S, x, model, inst, t)` and then does what
        \\/// `updateState(model, inst, <values of x>, state)` does, reading the
        \\/// same core result; staged values carry `S`'s value semantics.
        \\
    , .{});
    try self.w("pub fn acceptQ(comptime S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, inst: *Instance, {s}: *State) [n_u]S {{\n", .{
        if (acc.reads_t_prev) "state" else "_",
    });
    const at_core = self.out.items.len;
    try self.ind(1);
    try self.b("const qq = blk: {{\n", .{});
    try self.ind(2);
    const at_mut = self.out.items.len;
    try self.b("var   res = [_]S{{S.con(0.0)}} ** n_u;\n", .{});
    self.ind_base = 1;
    const stamps = try gen_dispatch.emitStamps(self, true);
    self.ind_base = 0;
    if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
    try self.ind(2);
    try self.b("break :blk res;\n", .{});
    try self.ind(1);
    try self.b("}};\n", .{});
    try emitAcceptBody(self, acc, ".val()");
    try self.w("    return qq;\n}}\n\n", .{});
    if (self.core_wanted or acc.uses_core) {
        self.uses_x = true;
        self.uses_model = true;
        try self.out.insertSlice(self.gpa, at_core, "    const m = @call(.always_inline, core, .{ S, x, model, inst });\n");
    }
    if (!self.uses_x) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.uses_model) gen_unit.patchParam(self, at_model, "model".len);
}

/// The accepted-step body shared by `updateState` (`val` = ".v" on `R`) and
/// `acceptQ` (".val()" on the host's `S`): stage the path latches, advance
/// every operator, write the held variables back. Reads the core result `m`.
fn emitAcceptBody(self: *Gen, acc: Accept, val: []const u8) Error!void {
    const uses_dt = acc.uses_dt;
    // §5.6.1.2 stage this iterate's path-latch operands. They become the
    // committed base ONLY at stateCtl(.commit): a rejected attempt leaves
    // pb/pq untouched, so the retry reopens on the accepted charge with a
    // zero α·Δq residual.
    for (self.core.prev_lo, 0..) |lo, k| {
        try self.w("    inst.wb__{d} = m.f{d}{s}; // path_prev staging\n", .{ k, lo, val });
    }
    for (self.core.acc_lo, 0..) |lo, k| {
        try self.w("    inst.wq__{d} = m.f{d}{s}; // path_acc staging\n", .{ k, lo, val });
    }
    if (uses_dt) try self.w("    const dt = inst.abstime - state.t_prev;\n", .{});
    // §9.17 reset FIRST, unconditionally: a `$bound_step` that only fired on
    // one arm of an `if` last step must not keep bounding this one, and the
    // reset value is also the right answer for a model that never calls the
    // task at all.
    try self.w(
        \\    inst.bound_step = std.math.inf(f64); // §9.17.2
        \\    inst.discontinuity_order = -1; // §9.17.1
        \\
    , .{});
    // §9.13.1 the internal seed advances HERE and nowhere else: this is the
    // accepted-step boundary, so a stream moves once per solved point and the
    // residual it feeds is fixed for the whole Newton loop that produced it.
    if (self.lowered.rng_auto_sites != 0) try self.w(
        \\    // §9.13.1 "this internal seed gets updated every time the call
        \\    // to $arandom is made" — once per ACCEPTED point, per call site.
        \\    for (&inst.rng_auto) |*rs| rs.* = @intFromFloat(zRngNext(rs.*));
        \\
    , .{});
    for (self.names.units, 0..) |u, i| {
        const k = u.op;
        if (u.role != .analog_op or !opHasState(k)) continue;
        const n = self.names.unit_names[i];
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
        const args = self.mir.instData(inst).call.args;
        const lo = gen_unit.opInputIdx(self, @intCast(i));
        if (lo == none_u32) {
            try self.w("    {{\n        const in: f64 = 0.0;\n", .{});
        } else {
            try self.w("    {{\n        const in = m.f{d}{s};\n", .{ lo, val });
        }
        switch (k) {
            .ddt => try self.w("        inst.{s}__prev = in;\n", .{n}),
            // §4.5.4 with `assert`: "Once assert becomes zero, idt()
            // returns the integral of the argument starting from the last
            // instant where assert was nonzero" — so while assert is
            // nonzero the accumulator is PINNED at ic, and integration
            // resumes from there.
            .idt => if (args.len >= 3) try self.w(
                "        inst.{s}__acc = if (({s}) != 0.0) ({s}) else zIdtAcc(in, inst.{s}__acc, dt, {s});\n",
                .{
                    n,                                           try gen_call.ctrlStep(self, args, 2, "0.0"),
                    try gen_call.ctrlStep(self, args, 1, "0.0"), n,
                    try gen_call.ctrlStep(self, args, 1, "0.0"),
                },
            ) else try self.w("        inst.{s}__acc = zIdtAcc(in, inst.{s}__acc, dt, {s});\n", .{
                n, n, try gen_call.ctrlStep(self, args, 1, "0.0"),
            }),
            .idtmod => try self.w("        inst.{s}__acc = zWrap(zIdtAcc(in, inst.{s}__acc, dt, {s}), {s}, {s});\n", .{
                n,                                           n,
                try gen_call.ctrlStep(self, args, 1, "0.0"), try gen_call.ctrlStep(self, args, 2, "0.0"),
                try gen_call.ctrlStep(self, args, 3, "0.0"),
            }),
            .absdelay => {
                try self.w("        zHistPush(&inst.{s}__t, &inst.{s}__v, &inst.{s}__head, inst.abstime, in);\n", .{ n, n, n });
                // §4.5.7 "the value of td when the absdelay() is first
                // evaluated shall be used and any future changes to td
                // shall be ignored" — the static point IS that first
                // evaluation, and `zAbsdelay` passes its input straight
                // through there, so latching here is before any delayed
                // value has been answered.
                if (try gen_call.absdelayFreezes(self, args)) try self.w(
                    "        if (inst.abstime <= state.t_prev) inst.{s}__td = {s};\n",
                    .{ n, try gen_call.ctrlStep(self, args, 1, "0.0") },
                );
                // §4.5.14 a dynamic maxdelay: its value at the start of the
                // analysis, latched at the same first evaluation.
                if (try gen_call.absdelayMaxdSampled(self, args)) try self.w(
                    "        if (inst.abstime <= state.t_prev) inst.{s}__maxd = {s};\n",
                    .{ n, try gen_call.ctrlStep(self, args, 2, "0.0") },
                );
                // §9.17.2 the same self-defence the §4.5.12 filter mounts
                // with its period: ask the host to keep the step at or
                // under td, or a wide step flattens the delay to
                // `zAbsdelay`'s short-side interpolation and the 32-sample
                // ring records nothing finer than the steps taken. `td`
                // may be a model expression (a parameter's overridden
                // value), so the bound is computed at run time; only a
                // positive one binds — `@min` with 0 would stop time.
                try self.w(
                    "        const zad_td = {s};\n        if (zad_td > 0.0) inst.bound_step = @min(inst.bound_step, zad_td);\n",
                    .{try gen_call.absdelayTd(self, n, args, true)},
                );
            },
            .transition => {
                const t = try gen_call.transitionTimes(self, args);
                try self.w(
                    "        zTransStep(in, &inst.{0s}__from, &inst.{0s}__to, &inst.{0s}__t0, " ++
                        "inst.abstime, dt, {1s}, {2s}, {3s});\n",
                    .{ n, try gen_call.argF64(self, args, 1, "0.0"), t[0], t[1] },
                );
            },
            .slew => {
                const r = try gen_call.slewRates(self, args);
                try self.w("        inst.{s}__prev = zSlew(R, R.con(in), inst.{s}__prev, dt, {s}, @abs({s})).v;\n", .{
                    n, n, r[0], r[1],
                });
            },
            // §4.5.10 `last_crossing(expr, direction)`. The direction is the
            // SAME closed argument as §5.10.3 `cross`'s — +1 rising, -1
            // falling, 0 either — so it is decoded and honoured the same
            // way; a bare sign change would report a falling edge to a
            // `last_crossing(V(p), +1)`.
            //
            // `dt > 0.0` is not an optimisation, it is the SEEDING rule.
            // `__prev` initialises to 0.0, which is a value the signal was
            // never at, so on the very first accepted step the sign test
            // compares against a sample that does not exist — a signal
            // sitting at -1 V read as a falling crossing of zero, reported
            // at `state.t_prev + f*dt` = 0.0, which is not the "negative
            // value" §4.5.10's last sentence requires before the first real
            // crossing. A crossing needs an INTERVAL, and the DC point
            // (dt = 0) is not one: it only seeds the history.
            .last_crossing => try self.w(
                \\        if (dt > 0.0 and ({1s})) {{
                \\            const f = inst.{0s}__prev / (inst.{0s}__prev - in);
                \\            inst.{0s}__t_last = state.t_prev + f * dt;
                \\        }}
                \\        inst.{0s}__prev = in;
                \\
            , .{ n, try gen_call.crossTest(self, n, args, "in") }),
            // §5.10.3 only the HISTORY moves here; `eval` raises the event
            // (see `emitOperator`), so nothing an accepted step writes can
            // still be read one timepoint later than it happened. The
            // `enable` is not consulted: it gates the EVENT, not the record
            // of where the signal was, and a disabled operator that later
            // re-enables must not compare against a stale sample.
            // §5.10.3.2 same history, same reason: `eval` raises the event
            // and this only records where the signal was on the ACCEPTED
            // step, so a re-arm cannot be observed one timepoint late.
            .cross, .above => try self.w("        inst.{s}__prev = in;\n", .{n}),
            // §5.10.3.3 the schedule is absolute — "at start_time, and every
            // period after that" — so it advances past the accepted time
            // whether or not the enable let the event through.
            .timer => try self.w(
                \\        if (inst.{0s}__next < in) inst.{0s}__next = in;
                \\        if (inst.abstime >= inst.{0s}__next) {{
                \\            const period = {1s};
                \\            inst.{0s}__next = if (period > 0.0) inst.{0s}__next + period else std.math.inf(f64);
                \\        }}
                \\
            , .{ n, try gen_call.timerPeriod(self, args) }),
            // §9.17.2 "the next time step taken is no larger than the
            // smallest $bound_step() argument currently ACTIVE". `in` is
            // already the running minimum over every `$bound_step` that
            // executed (lower.zig accumulates it through the CFG); the
            // `@min` folds it against the §4.5.12 sampling periods, which
            // are equally active and may be written by an earlier block.
            .bound_step => try self.w("        inst.bound_step = @min(inst.bound_step, in);\n", .{}),
            // §9.17.1 same, and `inf` means "no announcement": the degree is
            // a non-negative constant_expression, so a finite `in` is exact.
            // `lossyCast` because "finite" is not "fits an i32", and the
            // artifact is built ReleaseFast — a huge degree saturates
            // instead of being UB.
            .discontinuity => try self.w(
                "        inst.discontinuity_order = if (std.math.isFinite(in)) std.math.lossyCast(i32, in) else -1;\n",
                .{},
            ),
            // §4.5.11 advance the cascade on the accepted solution.
            .laplace => {
                const p = cg_filters.planOf(self, i);
                if (p.err == null) try self.w(
                    "        zLaplaceStep({d}, {d}, in, {s}__sec(model), dt, &inst.{s}__u, &inst.{s}__y);\n",
                    .{ p.ns, p.deg, n, n, n },
                );
            },
            // §4.5.12 the filter runs on ITS OWN timebase: sample when the
            // accepted time reaches the next multiple of T, hold in
            // between. Same shape as the §5.10.3 `timer` block above, and
            // the step bound is what keeps the solver from stepping over a
            // sample and aliasing the filter.
            .zi => {
                const p = cg_filters.planOf(self, i);
                if (p.err == null) try self.w(
                    \\        const period = {1s};
                    \\        // §4.5.12: "T specifies the sampling period of the filter".
                    \\        // The recurrence runs once per T of SIMULATED TIME, so a step that
                    \\        // crosses k sample instants runs it k times. Stepping it ONCE per
                    \\        // evaluation — which is what this did — makes the output a function
                    \\        // of how densely the host happened to place its timepoints, and the
                    \\        // same filter at the same T returned bit-identical values for 20 us
                    \\        // and 200 us of elapsed time.
                    \\        //
                    \\        // `zZiDue` counts off the k*T GRID, and `eval` calls the identical
                    \\        // function: the two halves of the operator cannot disagree about
                    \\        // which timepoint is a sample instant. A `__next` time re-armed by
                    \\        // `+= zn*T` could and did — three additions of 1e-9 overshoot the
                    \\        // double nearest 3e-9, and the sample at t = 3T was lost for good.
                    \\        var zi_k = zZiDue(inst.abstime, inst.{0s}__nk, period);
                    \\        if (zi_k > 0) {{
                    \\            inst.{0s}__nk += @as(f64, @floatFromInt(zi_k));
                    \\            while (zi_k > 0) : (zi_k -= 1)
                    \\                inst.{0s}__out = zZiStep({2d}, {3d}, in, {0s}__sec(model), &inst.{0s}__u, &inst.{0s}__y);
                    \\            inst.discontinuity_order = 0; // §9.17.1 the held output steps
                    \\        }}
                    \\        inst.bound_step = @min(inst.bound_step, period);
                    \\
                , .{ n, p.period orelse "0.0", p.ns, p.deg });
            },
            .none => {},
        }
        try self.w("    }}\n", .{});
    }
    // §5.10 store every held variable back. HERE and nowhere else: this
    // function runs on the ACCEPTED solution, once per step, exactly like
    // the operator history above — writing it from `eval` would latch a
    // Newton iterate that the solver goes on to throw away.
    for (self.lowered.held_vars.items, 0..) |h, i| {
        const k = self.core.held_idx[i];
        const n = self.names.held_names[i];
        if (k == none_u32) {
            // The value folded away entirely (never assigned outside the
            // §5.10 body on any reachable path, and the body's value is a
            // literal zero); nothing to carry.
            try self.w("    inst.{s} = 0;\n", .{n});
        } else if (h.ty == .integer) {
            try self.w("    inst.{s} = m.f{d};\n", .{ n, k });
        } else {
            try self.w("    inst.{s} = m.f{d}{s};\n", .{ n, k, val });
        }
    }
    if (acc.reads_t_prev) try self.w("    state.t_prev = inst.abstime;\n", .{});
}

/// Called after evaluating a Newton iterate, with that iterate's x.
/// All return values are computed before any history slot is changed.
pub fn emitAdvanceIteration(self: *Gen) Error!void {
    if (self.lowered.limit_slots.items.len == 0 and !self.lowered.uses.contains(.newton_iter) and !self.lowered.uses.contains(.reject_iteration)) return;
    if (self.lowered.uses.contains(.newton_iter)) try self.w(
        "pub fn beginSolve(inst: *Instance) void {{\n    inst.newton_iteration = 1;\n}}\n\n",
        .{},
    );
    var uses_core = false;
    for (self.lowered.limit_slots.items) |slot| uses_core = uses_core or gen_dispatch.coreIdx(self, self.an.rv(slot.final)) != null;
    const uses_inst = uses_core or self.lowered.uses.contains(.newton_iter) or self.lowered.limit_slots.items.len != 0;
    try self.w("pub fn advanceIteration({s}: *const Model, {s}: *Instance, {s}: [n_u]f64) void {{\n", .{
        if (uses_core) "model" else "_", if (uses_inst) "inst" else "_", if (uses_core) "x" else "_",
    });
    if (uses_core) try self.w(
        "    var xr: [n_u]R = undefined;\n    for (x, 0..) |v, i| xr[i] = R.con(v);\n    const m = core(R, xr, model, {s});\n",
        .{try gen_hoist.probeInstance(self)},
    );
    for (self.lowered.limit_slots.items, 0..) |slot, k| {
        if (gen_dispatch.coreIdx(self, self.an.rv(slot.final))) |lo|
            try self.w("    inst.limiter_previous[{d}] = m.f{d}.v;\n", .{ k, lo })
        else
            try self.w("    inst.limiter_previous[{d}] = 0.0;\n", .{k});
    }
    if (self.lowered.uses.contains(.newton_iter)) try self.w("    inst.newton_iteration +|= 1;\n", .{});
    try self.w("}}\n\n", .{});
    if (self.lowered.uses.contains(.reject_iteration)) {
        try self.w("pub fn checkConvergence(model: *const Model, inst: *const Instance, x: [n_u]f64) bool {{\n", .{});
        const probe_inst = try gen_hoist.probeInstance(self);
        try self.w("    var xr: [n_u]R = undefined;\n    for (x, 0..) |v, i| xr[i] = R.con(v);\n" ++
            "    return core(R, xr, model, {s}).f{d} == 0;\n}}\n\n", .{ probe_inst, gen_dispatch.coreIdx(self, self.an.rv(self.lowered.reject_iteration)).? });
    }
}

/// §5.10.5 `timer(start_time, period)` — the host's `nextBreakpoint` hook.
///
/// WHY THIS OPERATOR AND NO OTHER. `nextBreakpoint` asks "at what time must
/// the transient loop PLACE a timepoint", so a discontinuity lands on a step
/// instead of being smeared across one. Nothing else in Verilog-A says that:
/// §9.17.2 `$bound_step` bounds step SIZE (a bound, not a location) and
/// §9.17.1 `$discontinuity` only announces one after the fact. §5.10.5 is the
/// exact wording — "the timer function schedules an event at `start_time`,
/// and every `period` after that" — so the fire times ARE the breakpoints.
///
/// The signature `contract.zig` fixes is `fn (*const Model, f64) ?f64`: no
/// `Instance`, so the live `__next` counter the state machine advances is out
/// of reach and the schedule has to be RECOMPUTED from `(model, t)`. That is
/// possible because §4.5.14 makes an analog-operator control argument a
/// constant or parameter expression, which is exactly what `f64Const`
/// renders — `model.<p>` leaves and arithmetic over them.
///
/// ALL OR NOTHING. If any one timer's arguments do not render, the whole
/// function is dropped rather than emitted covering the others. A missing
/// hook only costs accuracy (the host falls back to LTE step control, as it
/// does for every device today); a hook that silently reports a SUBSET reads
/// to the host as "this device wants no other timepoints", which is a claim
/// this code would not be entitled to make.
///
// ponytail: the §5.10.3.3 `enable` is honoured here only where it folds
// WITHOUT parameters (a genuinely-constant zero: that timer never fires,
// so proposing its fire times would be a lie about where a discontinuity
// is) or renders over the Model (a parameter enable: the guard is emitted
// and evaluated at run time — folding it through the DECLARED default
// used to veto a timer whose enable the model card overrode to nonzero).
// A timer whose enable is a solved quantity keeps its breakpoints, because
// this hook has no `Instance` to evaluate one against and an extra timepoint
// costs a step, never an answer.
// ---------------------------------------------- zero-parasitic collapse

/// The host-side collapse hook — `seed`'s twin: it runs the core once at
/// x = 0 (exact, since every admitted flag is `buildFree`) and reads the
/// same §5.6.1.3 retention flags `eval` selects the branch row on. Flag
/// set ⇒ the 0 V potential arm is retained ⇒ the branch is a dead short:
/// the host aliases the internal node and the branch-flow unknown onto
/// the far node, every stamp of the pair lands on one matrix slot and
/// cancels exactly, and the LU never sees the short.
///
/// Consulted ONCE, at build — ngspice's own semantics (setup runs before
/// the first load), and why `buildFree` refuses anything that can change
/// between evaluations.
pub fn emitCollapse(self: *Gen, pairs: []const CollapsePair) Error!void {
    if (pairs.len == 0) return;
    try self.w(
        \\/// Zero-parasitic node collapse (ngspice setup: DIOsetup's
        \\/// `posPrimeNode = posNode` when RS == 0). Applied by the host before
        \\/// matrix build; the flags read here are the §5.6.1.3 retention flags
        \\/// `eval` selects the branch rows on, evaluated at x = 0 like `seed` —
        \\/// sound because codegen admits only build-time-constant flags.
        \\///
        \\/// Dead shorts form CHAINS (BSIM4's rgateMod=0 retains both V(g,gm)=0
        \\/// and V(gm,gi)=0, sharing gm), so aliases are resolved by union-find:
        \\/// every member of a merged set lands on ONE root and each stamp of
        \\/// the set cancels on a single slot. Last-write-wins aliasing left the
        \\/// chain's first link dangling — its KVL row landed on a KCL row as
        \\/// ±1 garbage stamps and the "solution" violated the model equations.
        \\pub fn collapse(model: *const Model, inst: *const Instance) [n_u]?u8 {{
        \\    var xr: [n_u]R = undefined;
        \\    for (&xr) |*p| p.* = R.con(0.0);
        \\    // SEEDS ITS OWN PRECOMPUTE, on a local copy. `collapse` decides
        \\    // TOPOLOGY, so a host must call it while building the matrix —
        \\    // before the batch exists and therefore before the batch runs
        \\    // `precompute`. But it answers by evaluating `core` at x = 0, and
        \\    // `core` reads `Instance.pc__*`: without this the retention flags
        \\    // are read off unwritten zeros and a device collapses (or fails to)
        \\    // on garbage. `precompute` is a pure function of (model, instance),
        \\    // so computing it here is the same answer the batch will compute
        \\    // later, and the copy keeps the caller's Instance untouched.
        \\{s}    const m = core(R, xr, model, {s});
        \\    var parent: [n_u]u8 = undefined;
        \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
        \\
    , .{
        // The hoisted core prefix rides the same seeding: without it the
        // local copy's `hp_ok` is 0, the region runs, and the answer is the
        // same — but `precompute` is what makes the flags agree with the
        // batch's, and it is the only writer of `hp_*`.
        if (self.pc.vals.len != 0 or self.hp.vals.len != 0)
            "    var pin = inst.*;\n    precompute(&pin, model);\n"
        else if (self.lowered.table_samples.items.len != 0)
            "    var pin = inst.*;\n"
        else
            "",
        if (self.pc.vals.len != 0 or self.hp.vals.len != 0 or self.lowered.table_samples.items.len != 0) "&pin" else "inst",
    });
    for (pairs, 0..) |p, pi| {
        const fi = @intFromEnum(self.an.rv(p.flag));
        const k = self.core.lo_idx[fi];
        assert(k != none_u32); // `buildJobs` queues every runtime retention flag
        if (self.an.vty[fi] == .int)
            try self.w("    const a{d} = (m.f{d} != 0);", .{ pi, k })
        else
            try self.w("    const a{d} = (m.f{d}.v != 0.0);", .{ pi, k });
        try self.w(" // 0 V arm retained: dead short\n", .{});
        try self.w("    if (a{d}) zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
            pi, self.names.u_names[p.victim], self.names.u_names[p.target],
        });
    }
    try self.w(
        \\    var out: [n_u]?u8 = .{{null}} ** n_u;
        \\    for (0..n_u) |u| {{
        \\        const r = zCollapseRoot(&parent, @intCast(u));
        \\        if (r != u) out[u] = r;
        \\    }}
        \\
    , .{});
    // UNCONDITIONAL, unlike the union above. The flag decides whether the
    // two NODES merge; the branch-flow unknown goes either way. Short
    // taken: it is part of the merged set. Short not taken: the branch is
    // `I(hi,lo) <+ <conductance>`, which wants no current row at all —
    // `emitSwitchRow`'s else arm stamps it straight into KCL. Guarding this
    // line on the flag cost the host one unknown and one matrix row per
    // RETAINED parasitic, for a row the physics never writes.
    for (pairs) |p| {
        try self.w("    out[@intFromEnum(U.{s})] = zCollapseRoot(&parent, @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.flow_u], self.names.u_names[p.target],
        });
    }
    try self.w("    return out;\n}}\n\n", .{});
    try self.w(
        \\fn zCollapseRoot(parent: *const [n_u]u8, start: u8) u8 {{
        \\    var u = start;
        \\    while (parent[u] != u) u = parent[u];
        \\    return u;
        \\}}
        \\
        \\/// Min-index root wins, so a set's root is always its lowest unknown —
        \\/// the host resolves aliases in ascending order and needs the target
        \\/// resolved before every mover.
        \\fn zCollapseUnion(parent: *[n_u]u8, a: u8, b: u8) void {{
        \\    const ra = zCollapseRoot(parent, a);
        \\    const rb = zCollapseRoot(parent, b);
        \\    if (ra == rb) return;
        \\    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
        \\}}
        \\
        \\
    , .{});
    try emitCollapseFull(self, pairs);
}

/// `collapse` with EVERY retention flag set — the maximal collapse, at
/// comptime.
///
/// `collapse` itself can only answer per instance, because the flags are
/// parameters. A host that wants to SPECIALISE the fully collapsed
/// instances needs the alias map before any instance exists: it sizes a
/// reduced derivative basis (the merged set is ONE unknown, so it needs
/// one seed lane and one Jacobian column, not |set| of each) and that is a
/// type, not a value. So the two halves are split — this const is the
/// shape, `collapse` is the per-instance test, and an instance qualifies
/// for the narrow basis exactly when the two arrays are equal.
///
/// Every union below is unconditional here, which is the only difference
/// from `collapse`: a flag that is clear at runtime merges strictly less,
/// so `collapse(m, i) == collapse_full` is the honest "maximal" predicate
/// and every other outcome falls back to the full width.
pub fn emitCollapseFull(self: *Gen, pairs: []const CollapsePair) Error!void {
    try self.w(
        \\/// The MAXIMAL collapse: `collapse` with every §5.6.1.3 retention
        \\/// flag set. Comptime, so a host can size a reduced derivative
        \\/// basis for the instances whose runtime `collapse` equals this;
        \\/// any other outcome merges strictly less and must use full width.
        \\pub const collapse_full: [n_u]?u8 = blk: {{
        \\    var parent: [n_u]u8 = undefined;
        \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
        \\
    , .{});
    for (pairs) |p| {
        try self.w("    zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.victim], self.names.u_names[p.target],
        });
    }
    try self.w(
        \\    var out: [n_u]?u8 = .{{null}} ** n_u;
        \\    for (0..n_u) |u| {{
        \\        const r = zCollapseRoot(&parent, @intCast(u));
        \\        if (r != u) out[u] = r;
        \\    }}
        \\
    , .{});
    for (pairs) |p| {
        try self.w("    out[@intFromEnum(U.{s})] = zCollapseRoot(&parent, @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.flow_u], self.names.u_names[p.target],
        });
    }
    try self.w("    break :blk out;\n}};\n\n", .{});
}

/// §4.5.7 the per-site transport delays, model-frame like
/// `nextBreakpoint` above — a delay argument is a §4.5.14
/// constant/parameter expression, so it renders over `Model` alone.
/// The host's transient uses these two ways (ngspice traload's habit):
/// a landed breakpoint re-emits one echo at t + td so the ARRIVING
/// wavefront gets its own timepoint instead of being smeared across a
/// step, and dt_max is clamped under the shortest delay. A site whose
/// delay is a solved quantity is skipped — no claim beats a wrong one.
pub fn emitDelays(self: *Gen) Error!void {
    const saved = self.uses_model;
    defer self.uses_model = saved;
    self.uses_model = false;
    var tds: std.ArrayList([]const u8) = .empty;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .absdelay) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        if (args.len < 2) continue;
        const td = try gen_call.f64Const(self, args[1], 0, false) orelse continue;
        try tds.append(self.arena, td);
    }
    if (tds.items.len == 0) return;
    try self.w(
        \\/// §4.5.7 transport delays, one per absdelay site. The host lands
        \\/// wavefront breakpoints at corner + td and bounds dt_max under the
        \\/// shortest delay (engine minDelay -> tran echo machinery).
        \\pub fn delays({s}: *const Model) [{d}]f64 {{
        \\    return .{{
    , .{ if (self.uses_model) "model" else "_", tds.items.len });
    for (tds.items, 0..) |td, k| try self.w("{s} {s}", .{ if (k == 0) "" else ",", td });
    try self.w(" }};\n}}\n\n\n", .{});
}

pub fn emitNextBreakpoint(self: *Gen) Error!void {
    if (!gen_file.usesOp(self, .timer)) return;

    // Render FIRST, emit second: `f64Const` is what sets `uses_model`, and
    // an unused `model` parameter does not compile.
    const saved = self.uses_model;
    defer self.uses_model = saved;
    self.uses_model = false;

    var timers: std.ArrayList([3]?[]const u8) = .empty;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse return;
        const args = self.mir.instData(inst).call.args;
        // §5.10.3.3 "if enable is specified and it is zero, then timer() is
        // inactive": a constant-zero enable means this timer never fires, so
        // it contributes no breakpoint — and it must not veto the others.
        var guard: ?[]const u8 = null;
        if (enableArgIdx(.timer)) |ei| {
            if (ei < args.len) {
                if (self.an.foldConst(args[ei], 0, false)) |c| {
                    if (c.f == 0.0) continue;
                } else if (try gen_call.f64Const(self, args[ei], 0, false)) |e| {
                    guard = e;
                }
            }
        }
        // No diagnostic: `f64Expr` already fired one for the period if it is
        // unrenderable, and a start_time that is a solved quantity is legal
        // Verilog-A that this hook simply cannot describe.
        const start = try gen_call.f64Const(self, if (args.len > 0) args[0] else .zero, 0, false) orelse return;
        const period = try gen_call.f64Const(self, if (args.len > 1) args[1] else .zero, 0, false) orelse return;
        try timers.append(self.arena, .{ start, period, guard });
    }
    if (timers.items.len == 0) return;

    try self.w(
        \\/// §5.10.5 the earliest `timer` fire strictly after `t`, so the host
        \\/// puts a timepoint ON the discontinuity instead of across it.
        \\pub fn nextBreakpoint({s}: *const Model, t: f64) ?f64 {{
        \\    var best = std.math.inf(f64);
        \\
    , .{if (self.uses_model) "model" else "_"});
    for (timers.items) |tm| {
        if (tm[2]) |g| try self.w("    if (({s}) != 0.0)\n    ", .{g});
        try self.w("    if (zNextTimer({s}, {s}, t)) |b| best = @min(best, b);\n", .{ tm[0].?, tm[1].? });
    }
    try self.w(
        \\    return if (best == std.math.inf(f64)) null else best;
        \\}}
        \\
        \\
    , .{});
}
