//! Jobs: every value the shared core returns, and why — resolved before a
//! single unit is written.
//!
//! PURE (ARCHITECTURE.md §2): `plan` takes the lowered module and the plans it
//! depends on (`Names`, the `$limit` sites, the small-signal rows) and returns
//! the job list. The ONE fact it needs from the renderer — whether a §4.5
//! control argument renders host-side or only off the core — is a parameter,
//! `dyn.isDynamic(v)`, rather than a `*Gen`, so a test passes a stub.
//!
//! LRM clauses this file's code cites: §4.5, §4.6.3, §4.6.4, §5.6, §5.6.1.2,
//! §5.6.1.3, §5.6.7, §5.10, §5.10.3.3, §9.4, §9.13, §9.17, §9.21.1.
//!
//! Cut verbatim from `codegen/unit.zig` (`Job`, `buildJobs`) and
//! `codegen.zig` (`dynCtrlArgs`, `unitComment`); only the receiver changed.

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
};

/// One emitted unit function, resolved BEFORE anything is written.
///
/// `plan_core.plan` has to know the exact set of units and their targets in
/// order to count how many of them share a value, and `emitUnits` has to
/// emit exactly that set — a disagreement between the two would leave a
/// value rendered as a cache read in a unit whose slice was never counted.
/// One list, built once, walked twice.
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

    /// Why the target is in the core. `buildJobs` queues the kinds in this
    /// order, which is the insert-tolerance order of the core's fields.
    pub const Kind = enum {
        /// §5.6 a contribution's resistive target.
        resist,
        /// §5.6.1.2 a contribution's reactive target.
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
        /// §9.4: the one job that is NOT folded into the core, because its
        /// body has side effects the residual must not trigger. See
        /// `plan_core.plan`.
        display,
    };
};

pub fn plan(self: Input, from: From, dyn: anytype) !Jobs {
    var out: Jobs = .{};
    var jobs: std.ArrayList(Job) = .empty;
    for (self.lowered.contributions.items, 0..) |c, i| {
        const mode = unitMode(from.unit_modes, i);
        const resist = self.an.rv(c.resist_val);
        const react = self.an.rv(c.react_val);
        if (resist != .f_zero) try jobs.append(self.arena, .{
            .kind = .resist,
            .target = resist,
            .mode = mode,
            .comment = unitComment(c, false),
        });
        if (react != .f_zero) try jobs.append(self.arena, .{
            .kind = .react,
            .target = react,
            .mode = mode,
            .comment = unitComment(c, true),
        });
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
                .none, .ddt, .idt, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .cross, .above, .timer => "§4.5 analog operator input",
            },
            .sec_of = if (k == .laplace or k == .zi) @intCast(i) else none_u32,
        });
    }
    // §4.5 Table 4-20's DYNAMIC control arguments, on exactly the terms the
    // `$limit` arguments below are queued on: `updateState` has only ONE
    // core sweep, so an argument it must read on the accepted solution has
    // to be a field of it. The table is normative — for `absdelay` the
    // dynamic arguments are `expr, td`, for `idt` they are `expr, ic,
    // assert`, for `idtmod` `expr, ic, modulus, offset` — and VerA used to
    // refuse every one of them with E0515, which is the opposite of what
    // the table says.
    //
    // ONLY the arguments that do not fold are queued. A literal or a model
    // parameter still renders over Model and puts nothing in the core, so
    // every device that exists today is byte-identical.
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = from.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        for (dynCtrlArgs(u.op)) |ai| {
            if (ai >= args.len) continue;
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
    // can store it back. Queued AFTER the operator inputs and before the
    // §9.4 display job for the same insert-tolerance reason: a model that
    // gains a held variable appends a core field, it renumbers none.
    //
    // `.strict` unconditionally: proof.zig rates contributions only.
    for (self.lowered.held_vars.items) |h| {
        try jobs.append(self.arena, .{
            .kind = .held,
            .target = self.an.rv(h.final),
            .mode = .strict,
            .comment = "§5.10 event-assigned variable, held across evaluations",
        });
    }
    // §4.5.15 the arguments of every honoured `$limit`, so `limit` can read
    // them out of the core instead of re-deriving the temperature prelude.
    // Queued after the held variables and before the §9.4 display job for
    // the same insert-tolerance reason: a model that gains a `$limit`
    // appends core fields, it renumbers none.
    for (from.limits) |lc| {
        for ([_]Mir.Value{ lc.argv[0], lc.argv[1], lc.sign }) |v| {
            if (v == .f_zero) continue;
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
    // (see `Retention.runtime`), so `emitResidual` can read them as core
    // fields. Queued after the limit arguments and before the §9.4 display
    // job for the same insert-tolerance reason as both neighbours — and a
    // module whose every potential contribution is unconditional queues
    // NOTHING here, so its core fields do not move.
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
    // §4.6.4 the PSD argument of every noise generator, so `noisePsd` can
    // read the model's OWN expression out of the core instead of a host
    // guessing it back off the Jacobian. Queued after the retention flags
    // and before the §9.4 display job for the same insert-tolerance reason
    // as every neighbour.
    //
    // The POWER is always routed through the core, even when it folds to a
    // model constant, because §4.6.4's generators are CONDITIONAL: every
    // series resistance in the tree spells `if (r > 0) I(a,b) <+
    // white_noise(4kT/r)`, and a generator whose statement did not execute
    // has to read back zero. A core live-out does exactly that (`h[k]` is
    // seeded `S.con(0)` at entry and assigned only inside the branch);
    // anything rendered outside the core evaluates unconditionally, and
    // `4kT/0` is not zero, it is an infinity that reaches the host as a
    // NaN the moment the collapsed branch gives it a zero adjoint gain.
    // `planPrecompute` declines these targets for the same reason.
    //
    // The EXPONENT is exempt: a constant renders inline, because it is only
    // ever read on a row whose power is non-zero — i.e. one that executed.
    // §4.6.4.6's coefficient joins them on the exponent's terms: a constant
    // factor renders inline, and one that depends on the bias
    // (`I(a,b) <+ V(a,b)*white_noise(p)`) is a core live-out like the power.
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
    // §4.6.3 the same, for an `ac_stim` magnitude or phase the SOLVE
    // computes. A.8.2 makes both `analog_expression`, so `acStim` has to
    // answer at a state vector exactly as `noisePsd` does, and the only
    // way it reads one is out of the core sweep.
    //
    // ONLY the arguments that do not fold, on the terms Table 4-20's
    // dynamic arguments are queued on above: a literal or a model
    // parameter renders over `Model` and puts nothing here, so every
    // device with a constant stimulus keeps the fields it had.
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
    // The start_time is already the operator's input, so it rides the core;
    // the period was only ever read through `f64Expr`, which is a HOST-side
    // spelling and answered a solve-computed period with E0515 — the clause
    // says clause-5 event arguments are `analog_expression`s, and §4.5.14's
    // constant-or-parameter rule is about the clause-4 operators. Queued
    // here, after the noise PSDs and before the §9.4 display job, for the
    // same insert-tolerance reason as every neighbour: a model that gains a
    // dynamic period appends a core field and renumbers none.
    for (from.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        const args = from.names.opArgs(self.mir, i);
        if (args.len < 2) continue;
        if (self.an.foldConst(args[1], 0, false) != null) continue; // renders inline
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
        .comment = "§9.21.1 table captures and §9.13 distribution checks in source order",
    });
    // §9.4 the display tasks, as ONE unit. Queued last, so no existing job —
    // and therefore no existing declaration name — moves when a model gains
    // or loses a `$strobe`.
    //
    // `.strict` unconditionally: proof.zig rates contributions only, a print
    // is not on the residual path, so there is nothing here for `.optimized`
    // to speed up and no verdict that would justify claiming it.
    const root = self.an.rv(self.lowered.display_root);
    if (from.emit_display and root != .f_zero) {
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

/// §4.5 Table 4-20 "Analog operator arguments": which argument positions the
/// clause marks DYNAMIC (the input at position 0 is already a unit of its own,
/// so it is not listed here). Everything absent from this table stays a
/// `constant_expression` and is still E0515 when it is a solve result.
fn dynCtrlArgs(k: OpKind) []const usize {
    return switch (k) {
        // td ("dynamic: expr, td"), and maxdelay: the constant one, but §4.5.14
        // samples a dynamic value there "at the start of the analysis", which
        // `updateState` latches off this field (`absdelayMaxdSampled`).
        .absdelay => &.{ 1, 2 },
        .idt => &.{ 1, 2 }, // ic, assert
        .idtmod => &.{ 1, 2, 3 }, // ic, modulus, offset
        .none, .ddt, .transition, .slew, .last_crossing, .laplace, .zi, .cross, .above, .timer, .bound_step, .discontinuity => &.{},
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
    const q = try f.call("ddt", &.{va}); // an operator unit, input V(a)
    // I(a,b) <+ V(b) + ddt(V(a)): a resistive and a reactive target.
    try f.lowered.contributions.append(a, .{ .access = .flow, .hi = 0, .lo = 1, .resist_val = vb, .react_val = q });
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
