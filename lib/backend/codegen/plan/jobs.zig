//! Jobs: the lowered module and the plans it depends on (`Names`, `$limit`
//! sites, small-signal rows) -> every value the shared core returns, and why,
//! resolved before a unit is written. Clauses: §2.9, §4.5, §4.6.3, §4.6.4, §5.6,
//! §5.6.1.2, §5.6.1.3, §5.6.7, §5.10, §5.10.3.3, §9.4, §9.13, §9.17, §9.21.1.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const proof = @import("ir").proof;
const OpKind = @import("ir").op.OpKind;
const naming = @import("../../naming.zig");
const Input = @import("input.zig").Input;
const Names = @import("names.zig").Names;
const LimitCall = @import("limit.zig").LimitCall;
const plan_noise = @import("noise.zig");
const plan_topo = @import("topology.zig");
const unitMode = @import("../float/mode.zig").unitMode;

const none_u32 = std.math.maxInt(u32);

/// The planned core targets.
pub const Jobs = struct {
    /// Every unit function to emit, resolved before any of them is written.
    list: []Job = &.{},
    /// `<module>__display__tasks`, or empty when the model prints nothing (or
    /// when the §9.4 tasks are dropped). The job that renders it is queued
    /// last.
    display_name: []const u8 = "",
};

/// What `plan` reads besides the lowered module.
pub const From = struct {
    names: *const Names,
    /// `proof.Verdict.unit_modes`: the float mode of each CONTRIBUTION unit.
    unit_modes: []const proof.FloatMode,
    /// `Limits.calls`: the honoured §4.5.15 sites.
    limits: []const LimitCall,
    noise: *const plan_noise.Noise,
    /// `Options.display == .emit`: the §9.4 tasks become a unit of their own.
    emit_display: bool,
    /// A `.record` device has tasks its `say` records (`cg_display.planSay`):
    /// the display unit is that entry point's body.
    record_display: bool = false,
    /// `plan/qsite.zig` `QSites.sites`: the `Lowered.charge_sites` that get a
    /// `q` slot, in slot order. Each one's charge is a core live-out.
    q_sites: []const u32 = &.{},
    /// `Options.vpi_contribs`: every value `vpiContribs` and `vpiShares`
    /// report is a core live-out.
    vpi: bool = false,
};

/// One emitted unit function, resolved before anything is written.
///
/// `plan_core.plan` counts how many units share a value, and `emitUnits`
/// must emit exactly that set: a disagreement would leave a value rendered as
/// a cache read in a unit whose slice was never counted. One list, built
/// once, walked twice.
pub const Job = struct {
    kind: Kind,
    /// The declaration name. Only the §9.4 display job is emitted as a
    /// declaration of its own (`emitUnits`); every other job exists to put
    /// its target in the core, so it has none.
    name: []const u8 = "",
    target: Mir.Value,
    mode: proof.FloatMode,
    comment: []const u8,
    /// §3.6.2.2 refusal seeded from the unit's DECLARATION (`Gen.pre_fatal`).
    pre_fatal: ?[]const u8 = null,
    /// Index into `units` for an analog-operator job whose §4.5.11/§4.5.12
    /// coefficient reader is emitted right after it; `none_u32` otherwise.
    sec_of: u32 = none_u32,

    /// Why the target is in the core. `plan` queues the kinds in this order,
    /// which is the order of the core's fields: a model that gains a target
    /// of one kind appends fields and renumbers none of the earlier kinds.
    pub const Kind = enum {
        /// §5.6 a contribution's resistive target.
        resist,
        /// §5.6.1.2 a charge site's charge (`plan/qsite.zig`).
        react,
        /// §4.5 an analog operator's input, or a §9.17 request.
        op_input,
        /// §4.5 Table 4-20 a dynamic operator control argument.
        ctrl,
        /// §5.10 a held variable's end-of-block value.
        held,
        /// §4.5.15 a `$limit` algorithm argument.
        limit_arg,
        /// §9.17.3 a next-iteration limiter value.
        limit_old,
        /// §9.17.1 the iteration-rejection request.
        reject_iteration,
        /// §5.6.1.3 a runtime retention flag.
        retained,
        /// §4.6.4 a noise PSD, exponent or coefficient.
        noise,
        /// §4.6.3 a solve-computed AC stimulus magnitude or phase.
        ac_stim,
        /// §5.10.3.3 a timer's latest period.
        timer_period,
        /// §9.21.1/§9.13 table captures and distribution checks.
        table_effect,
        /// VerA's `vera_timepoint` (§2.9): whether a cached statement ran, and
        /// each variable it assigned, which `eval` stores into the cache.
        timepoint,
        /// VerA's `$vera_reject_step`: the retry time `updateState` returns.
        reject_step,
        /// §9.7.3 a device's status code and its arguments, which `eval`
        /// latches into `Instance` (`Lowered.status`).
        status,
        /// Clause 12 (`From.vpi`): a row's reactive half, or one instance's
        /// share of a shared row, that `vpiContribs`/`vpiShares` report.
        vpi,
        /// §9.4: the one job that is NOT folded into the core, because its
        /// body has side effects the residual must not trigger. See
        /// `plan_core.plan`.
        display,
    };
};

/// Returns every core target in queue order (`Job.Kind`); slices are owned by
/// `self.arena`. `dyn.isDynamic(v)` answers whether a §4.5 control argument
/// renders only off the core, so a test can pass a stub. Fails on
/// allocation, on a display name over `naming.max_name_len`, or with `dyn`'s
/// error.
pub fn plan(self: Input, from: From, dyn: anytype) !Jobs {
    var out: Jobs = .{};
    var jobs: std.ArrayList(Job) = .empty;
    for (self.lowered.contributions.items, 0..) |c, i| {
        const mode = unitMode(from.unit_modes, i);
        const resist = self.an.rv(c.resist_val);
        if (resist != .f_zero) try jobs.append(self.arena, .{
            .kind = .resist,
            .target = resist,
            .mode = mode,
            .comment = unitComment(c, false),
        });
        // §5.6.1.2 its charges, one per site, beside it.
        for (from.q_sites) |k| {
            const s = self.lowered.charge_sites.items[k];
            if (s.contrib != i) continue;
            try jobs.append(self.arena, .{
                .kind = .react,
                .target = self.an.rv(s.final),
                .mode = mode,
                .comment = unitComment(c, true),
            });
        }
    }
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = from.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        const k = u.op;
        try jobs.append(self.arena, .{
            .kind = .op_input,
            .target = if (args.len == 0) Mir.Value.f_zero else self.an.rv(args[0]),
            .mode = unitMode(from.unit_modes, i),
            .comment = switch (k) {
                .bound_step, .discontinuity => "§9.17 analog kernel control request",
                .none, .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .cross, .above, .timer => "§4.5 analog operator input",
            },
            .sec_of = if (k == .laplace or k == .zi) @intCast(i) else none_u32,
        });
    }
    // §4.5 Table 4-20's dynamic control arguments: `updateState` has one core
    // sweep, so an argument it must read on the accepted solution has to be a
    // field of it. The table is normative (`absdelay`: `expr, td`; `idt`:
    // `expr, ic, assert`; `idtmod`: `expr, ic, modulus, offset`). Only
    // arguments that do not fold are queued: a literal or model parameter
    // renders over Model and puts nothing in the core.
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = from.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        for (0..args.len) |ai| {
            if (!isDynCtrlArg(u.op, ai)) continue;
            const v = self.an.rv(args[ai]);
            if (v == .f_zero) continue;
            if (!try dyn.isDynamic(args[ai])) continue;
            try jobs.append(self.arena, .{
                .kind = .ctrl,
                .target = v,
                .mode = unitMode(from.unit_modes, i),
                .comment = "§4.5 Table 4-20 dynamic operator control argument",
            });
        }
    }
    // §5.10 the end-of-block value of every held variable, so `updateState`
    // can store it back. `.strict` unconditionally: proof.zig rates
    // contributions only.
    for (self.lowered.held_vars.items) |h| {
        try jobs.append(self.arena, .{
            .kind = .held,
            .target = self.an.rv(h.final),
            .mode = .strict,
            .comment = "§5.10 event-assigned variable, held across evaluations",
        });
    }
    // §4.5.15 the arguments of every honoured `$limit`, so `limit` reads them
    // from the core instead of re-deriving the temperature prelude.
    for (from.limits) |lc| {
        // A literal or parameter seed is written in place (`writeArg`);
        // queued, it would make every other use of that constant read `c`.
        const seed: Mir.Value = switch (self.mir.valueDef(self.an.rv(lc.seed))) {
            .float_const, .int_const, .param_ref, .undef => .undef,
            .str_const, .block_param, .inst_result => lc.seed,
        };
        for ([_]Mir.Value{ lc.argv[0], lc.argv[1], lc.sign, seed }) |v| {
            if (v == .f_zero or v == .undef) continue;
            try jobs.append(self.arena, .{
                .kind = .limit_arg,
                .target = v,
                .mode = .strict,
                .comment = "§4.5.15 $limit algorithm argument",
            });
        }
    }
    for (self.lowered.limit_slots.items) |slot| try jobs.append(self.arena, .{
        .kind = .limit_old,
        .target = self.an.rv(slot.final),
        .mode = .strict,
        .comment = "§9.17.3 next-iteration limiter value",
    });
    if (self.lowered.uses.contains(.reject_iteration)) try jobs.append(self.arena, .{
        .kind = .reject_iteration,
        .target = self.an.rv(self.lowered.reject_iteration),
        .mode = .strict,
        .comment = "§9.17.1 iteration rejection",
    });
    // §5.6.1.3 the retention flags of every runtime-selected branch row
    // (`Retention.runtime`), read by `emitResidual` as core fields. A module
    // whose potential contributions are all unconditional queues nothing.
    for (self.lowered.contributions.items, 0..) |c, i| {
        if (c.kind != .direct or c.access != .potential) continue;
        const ret = plan_topo.retention(self, c);
        if (ret != .runtime) continue;
        try jobs.append(self.arena, .{
            .kind = .retained,
            .target = ret.runtime,
            .mode = unitMode(from.unit_modes, i),
            .comment = "§5.6.1.3 retention flag",
        });
        if (plan_topo.switchFlowOf(self, i)) |j| {
            const fret = plan_topo.retention(self, self.lowered.contributions.items[j]);
            if (fret == .runtime) try jobs.append(self.arena, .{
                .kind = .retained,
                .target = fret.runtime,
                .mode = unitMode(from.unit_modes, j),
                .comment = "§5.6.1.3 retention flag",
            });
        }
    }
    // §4.6.4 the PSD argument of every noise generator, so `noisePsd` reads
    // the model's own expression out of the core.
    //
    // The power always goes through the core, even when it folds to a model
    // constant, because generators are conditional: `if (r > 0) I(a,b) <+
    // white_noise(4kT/r)` must read back zero when the statement did not run.
    // A core live-out is seeded `S.con(0)` and assigned only inside the
    // branch; rendered outside the core, `4kT/0` would be an infinity that
    // reaches the host as NaN. The exponent and a constant §4.6.4.6
    // coefficient render inline, since they are read only on a row whose
    // power is nonzero. A bias-dependent coefficient
    // (`I(a,b) <+ V(a,b)*white_noise(p)`) is a live-out like the power.
    for (from.noise.rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }, 0..) |v, k| {
            if (v == .f_zero) continue;
            if (k != 0 and plan_noise.psdConst(self.mir, v) != null) continue;
            try jobs.append(self.arena, .{
                .kind = .noise,
                .target = v,
                .mode = .strict,
                .comment = "§4.6.4 noise PSD",
            });
        }
    }
    // §4.6.3 an `ac_stim` magnitude or phase the solve computes (A.8.2 makes
    // both `analog_expression`), so `acStim` reads it out of the core sweep
    // as `noisePsd` does. Only arguments that do not fold are queued: a
    // literal or model parameter renders over `Model`.
    for (from.noise.ac_rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }) |v| {
            if (v == .f_zero) continue;
            if (!try dyn.isDynamic(v)) continue;
            try jobs.append(self.arena, .{
                .kind = .ac_stim,
                .target = v,
                .mode = .strict,
                .comment = "§4.6.3 AC stimulus magnitude or phase",
            });
        }
    }
    // §5.10.3.3: "If the start_time or period expressions change value
    // during the evaluation of the analog block, the next event will be
    // scheduled based on the LATEST value of the start_time and period."
    // The start_time is the operator's input and already rides the core; a
    // solve-computed period is queued here. Clause-5 event arguments are
    // `analog_expression`s: §4.5.14's constant-or-parameter rule covers only
    // the clause-4 operators.
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        if (self.lowered.timer_controls.get(from.names.opInstOf(@intCast(i)).?)) |latest| {
            for (latest) |arg| {
                const v = self.an.rv(arg);
                if (v == .f_zero or self.an.foldConst(v, false) != null) continue;
                try jobs.append(self.arena, .{
                    .kind = .timer_period,
                    .target = v,
                    .mode = .strict,
                    .comment = "§5.10.3.3 end-of-evaluation timer control",
                });
            }
        }
        const args = from.names.opArgs(self.mir, i);
        if (args.len < 2) continue;
        if (self.an.foldConst(args[1], false) != null) continue; // renders inline
        const v = self.an.rv(args[1]);
        if (v == .f_zero) continue;
        try jobs.append(self.arena, .{
            .kind = .timer_period,
            .target = v,
            .mode = .strict,
            .comment = "§5.10.3.3 the latest period, read by the schedule",
        });
    }
    if (self.lowered.table_effect != .f_zero) try jobs.append(self.arena, .{
        .kind = .table_effect,
        .target = self.an.rv(self.lowered.table_effect),
        .mode = .strict,
        .comment = "§9.21.1 captures and §4.2.4/§9.13 runtime checks in source order",
    });
    // VerA's `vera_timepoint` (§2.9): each statement's mark, then the slots
    // something reads after it. A scratch variable no later statement reads
    // is not cached: its hit-arm read is dead and is never emitted.
    const read = if (self.lowered.timepoints.items.len != 0) try readSet(self, jobs.items) else &.{};
    for (self.lowered.timepoints.items) |t| {
        if (self.an.foldConst(t.mark, false) == null) try jobs.append(self.arena, .{
            .kind = .timepoint,
            .target = self.an.rv(t.mark),
            .mode = .strict,
            .comment = "vera_timepoint statement ran",
        });
        for (t.slots) |sl| if (read[@backingInt(self.an.rv(sl.final))]) try jobs.append(self.arena, .{
            .kind = .timepoint,
            .target = self.an.rv(sl.final),
            .mode = .strict,
            .comment = "vera_timepoint cached value",
        });
    }
    if (self.lowered.reject_step != .undef) try jobs.append(self.arena, .{
        .kind = .reject_step,
        .target = self.an.rv(self.lowered.reject_step),
        .mode = .strict,
        .comment = "$vera_reject_step retry time",
    });
    // §9.7.3 a device reports `$fatal`/`$error` as a status (a printing
    // artifact runs the display chain instead). Values that fold are written
    // as constants by `zStatusStore` and need no core field.
    if (!from.emit_display and self.lowered.status != .undef) {
        const vals = [_]Mir.Value{self.lowered.status} ++ self.lowered.status_args;
        for (vals) |v| {
            if (v == .undef or self.an.foldConst(v, false) != null) continue;
            try jobs.append(self.arena, .{
                .kind = .status,
                .target = self.an.rv(v),
                .mode = .strict,
                .comment = "§9.7.3 the device status and its arguments",
            });
        }
    }
    // Clause 12 the values a VPI device reports beside the residual: each
    // row's reactive half (a resistive half is a `.resist` job already) and
    // each instance's share of a shared row. After every kind `eval` reads,
    // so the fields before them number as they do without `vpi`.
    if (from.vpi) {
        for (self.lowered.contributions.items, 0..) |c, i| try queueVpi(self, &jobs, from, c.react_val, i);
        for (self.lowered.contrib_shares.items) |sh| {
            try queueVpi(self, &jobs, from, sh.resist_val, sh.row);
            try queueVpi(self, &jobs, from, sh.react_val, sh.row);
        }
    }
    // §9.4 the display tasks, as one unit. Queued last, so no existing job
    // (and so no declaration name) moves when a model gains or loses a
    // `$strobe`. `.strict` unconditionally: a print is not on the residual
    // path, and proof.zig rates contributions only.
    const root = self.an.rv(self.lowered.display_root);
    if ((from.emit_display or from.record_display) and root != .f_zero) {
        var buf: [naming.max_name_len]u8 = undefined;
        const n = naming.unitName(&buf, self.mir.name, .{
            .role = .display,
            .target = "tasks",
        }) catch return error.NameTooLong;
        out.display_name = try self.arena.dupe(u8, n);
        try jobs.append(self.arena, .{
            .kind = .display,
            .name = out.display_name,
            .target = root,
            .mode = .strict,
            .comment = "§9.4 display tasks, in source order",
        });
    }
    out.list = jobs.items;
    return out;
}

/// Queues `v`, a value of contribution `row`, as a `.vpi` job unless it is 0.
fn queueVpi(self: Input, jobs: *std.ArrayList(Job), from: From, v: Mir.Value, row: usize) !void {
    const t = self.an.rv(v);
    if (t == .f_zero) return;
    try jobs.append(self.arena, .{
        .kind = .vpi,
        .target = t,
        .mode = unitMode(from.unit_modes, row),
        .comment = "Clause 12 a value vpiContribs or vpiShares reports",
    });
}

/// Value -> some instruction reads it, or a job in `queued` returns it. Dead
/// instructions count: the answer only has to be a superset.
fn readSet(self: Input, queued: []const Job) ![]bool {
    const read = try self.arena.alloc(bool, self.an.nv);
    @memset(read, false);
    for (queued) |j| read[@backingInt(self.an.rv(j.target))] = true;
    for (0..self.mir.insts.len) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(@as(u32, @intCast(ii))));
        switch (self.mir.instData(inst)) {
            .unary => |d| read[@backingInt(self.an.rv(d.operand))] = true,
            .binary => |d| for ([_]Mir.Value{ d.lhs, d.rhs }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .ternary => |d| for ([_]Mir.Value{ d.cond, d.then_val, d.else_val }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .phi => |d| for (0..d.count) |k| {
                read[@backingInt(self.an.rv(self.mir.phiPair(inst, @intCast(k)).value))] = true;
            },
            .branch => |d| read[@backingInt(self.an.rv(d.cond))] = true,
            .call => |d| for (d.args) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .load => |d| for ([_]Mir.Value{ d.arr, d.index }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .store => |d| for ([_]Mir.Value{ d.arr, d.index, d.value }) |v| {
                read[@backingInt(self.an.rv(v))] = true;
            },
            .jump, .anew => {},
        }
    }
    return read;
}

/// §4.5 Table 4-20 "Analog operator arguments": whether argument position `ai`
/// is one `updateState` reads off the core: the clause marks it DYNAMIC, or
/// §4.5.14 samples it (the input at position 0 is already a unit of its own,
/// so it is not one). Everything else stays a `constant_expression` and is
/// still E0515 when it is a solve result.
fn isDynCtrlArg(k: OpKind, ai: usize) bool {
    return switch (k) {
        // td ("dynamic: expr, td"), and maxdelay: the constant one, but §4.5.14
        // samples a dynamic value there "at the start of the analysis", which
        // `updateState` latches off this field (`absdelayMaxdSampled`).
        .absdelay => ai == 1 or ai == 2,
        .idt_hold => ai == 1 or ai == 2, // ic, assert
        .idtmod => ai >= 1 and ai <= 3, // ic, modulus, offset
        // §4.5.14 every filter coefficient, latched the same way
        // (`cg_filters.FilterPlan.sampled`). The flattened vector counts fold
        // and a moving ε is E0515 in lowering, so neither is queued; a moving
        // zi_* period, τ or t0 is queued and then refused by the plan.
        .laplace, .zi => ai >= 1,
        .none, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => false,
    };
}

fn unitComment(c: Lower.Contribution, react: bool) []const u8 {
    if (react) return "§5.6.1.2 reactive part (charge/flux; q() differentiates it)";
    if (c.kind == .indirect)
        return "§5.6.7 indirect contribution — the constraint `<probe> − <equation>`";
    return switch (c.access) {
        .flow => "§5.6 flow contribution — current into `hi`, out of `lo` (§1.3.1.2)",
        .potential => "§5.6 potential contribution — the branch constitutive relation",
    };
}

const Fixture = @import("fixture.zig").Fixture;

test "jobs queue in insert-tolerant order: contributions, operator inputs, held values" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b" });
    defer f.deinit();
    const a = f.alloc();
    const va = try f.probe(0);
    const vb = try f.probe(1);
    const q = try f.call("slew", &.{va}); // an operator unit, input V(a)
    // I(a,b) <+ V(b) + ddt(slew(V(a))): a resistive and a reactive target.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .resist_val = vb, .react_val = q });
    try f.lowered.charge_sites.append(a, .{ .contrib = 0, .sign = 1, .final = q });
    try f.lowered.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = .f_zero, .final = vb });
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const names = try @import("names.zig").plan(in, 1);
    const noise: plan_noise.Noise = .{};
    const never = struct {
        pub fn isDynamic(_: @This(), _: Mir.Value) error{}!bool {
            return false;
        }
    }{};

    const jobs = try plan(in, .{
        .names = &names,
        .unit_modes = &.{.optimized},
        .limits = &.{},
        .noise = &noise,
        .emit_display = false,
        .q_sites = &.{0},
    }, never);
    const kinds = try a.alloc(Job.Kind, jobs.list.len);
    for (jobs.list, kinds) |j, *k| k.* = j.kind;
    try std.testing.expectEqualSlices(Job.Kind, &.{ .resist, .react, .op_input, .held }, kinds);
    // The contribution keeps the prover's mode; an operator unit and a held
    // value are not rated by it and take the safe side.
    try std.testing.expectEqual(proof.FloatMode.optimized, jobs.list[0].mode);
    try std.testing.expectEqual(proof.FloatMode.strict, jobs.list[2].mode);
    try std.testing.expectEqual(va, jobs.list[2].target);
    try std.testing.expectEqualStrings("", jobs.display_name);
}
