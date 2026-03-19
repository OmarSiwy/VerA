//! Units: one function per source unit, and the body each one computes.
//!
//! In: a unit and its backward slice of the MIR. Out: one stably named Zig function with its
//! own @setFloatMode (proof.zig's verdict for that unit).
//!
//! LRM clauses this file's code cites: §1.3.1.1, §3.6.2.2, §4.5, §4.5.11, §4.5.12, §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.6, §5.6.1.3, §9.4.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_unit.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_cfg = @import("cfg.zig");
const Mir = @import("ir").Mir;
const cg_filters = @import("../cg_filters.zig");
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const proof = @import("ir").proof;
const diag = @import("diag");
const naming = @import("../naming.zig");
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const dynCtrlArgs = codegen.dynCtrlArgs;
const unitComment = codegen.unitComment;

// =======================================================================
// Units
// =======================================================================

/// One emitted unit function, resolved BEFORE anything is written.
///
/// `planCommon` has to know the exact set of units and their targets in
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
        /// `planCommon`.
        display,
    };
};

pub fn unitMode(self: *const Gen, i: usize) proof.FloatMode {
    // proof.zig rates the CONTRIBUTION units only (proof.unitCount ==
    // lower.contributions.len); an analog-operator unit is not covered, so
    // it takes the safe side.
    if (i >= self.verdict.unit_modes.len) return .strict;
    return self.verdict.unit_modes[i];
}

pub fn buildJobs(self: *Gen) Error!void {
    var jobs: std.ArrayList(Job) = .empty;
    for (self.lowered.contributions.items, 0..) |c, i| {
        const mode = unitMode(self, i);
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
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = opInstOf(self, @intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        const k = u.op;
        try jobs.append(self.arena, .{
            .kind = .op_input,
            .target = if (args.len == 0) Mir.Value.f_zero else self.an.rv(args[0]),
            .mode = unitMode(self, i),
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
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const inst = opInstOf(self, @intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        for (dynCtrlArgs(u.op)) |ai| {
            if (ai >= args.len) continue;
            const v = self.an.rv(args[ai]);
            if (v == .f_zero) continue;
            if (!try gen_call.ctrlIsDynamic(self, args[ai])) continue;
            try jobs.append(self.arena, .{
                .kind = .ctrl,
                .target = v,
                .mode = unitMode(self, i),
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
    for (self.limits.calls) |lc| {
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
        const ret = plan_topo.retention(self.input(), c);
        if (ret != .runtime) continue;
        try jobs.append(self.arena, .{
            .kind = .retained,
            .target = ret.runtime,
            .mode = unitMode(self, i),
            .comment = "§5.6.1.3 retention flag",
        });
        if (plan_topo.switchFlowOf(self.input(), i)) |j| {
            const fret = plan_topo.retention(self.input(), self.lowered.contributions.items[j]);
            if (fret == .runtime) try jobs.append(self.arena, .{
                .kind = .retained,
                .target = fret.runtime,
                .mode = unitMode(self, j),
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
    for (self.noise.rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }, 0..) |v, k| {
            if (v == .f_zero) continue;
            if (k != 0 and gen_dispatch.psdConst(self, v) != null) continue;
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
    for (self.noise.ac_rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }) |v| {
            if (v == .f_zero) continue;
            if (!try gen_call.ctrlIsDynamic(self, v)) continue;
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
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        const args = opArgs(self, i);
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
    if (self.display == .emit and root != .f_zero) {
        var buf: [naming.max_name_len]u8 = undefined;
        const n = naming.unitName(&buf, self.mir.name, .{
            .role = .display,
            .target = "tasks",
        }) catch return error.NameTooLong;
        self.display_name = try self.arena.dupe(u8, n);
        try jobs.append(self.arena, .{
            .kind = .display,
            .name = self.display_name,
            .target = root,
            .mode = .strict,
            .comment = "§9.4 display tasks, in source order",
        });
    }
    self.jobs = jobs.items;
}

pub fn emitUnits(self: *Gen) Error!void {
    try self.w("// ---- the model, in one declaration ----\n\n", .{});
    // The §9.4 display unit calls the core through `core`, not through its
    // structural key, so the ONE call spelling works in both the single-file
    // form (this alias) and the split form (the alias in `Output.prelude`,
    // which is an `@import`). It sits in the prologue, ahead of the first
    // recorded unit range, so the ranges still tile.
    if (self.common_name.len != 0) try self.w("const core = {s};\n\n", .{self.common_name});
    try emitCommon(self);
    // §4.5.11/§4.5.12 the coefficient reader is DERIVED from the operator's
    // unit name (like the old `<unit>__q`), not a Unit of its own, so the
    // normative ordering in naming.zig/proof.zig is untouched. It reads
    // `Model` alone, so it was never part of the residual slice and is
    // unaffected by the merge.
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const k = u.op;
        if (k != .laplace and k != .zi) continue;
        if (opInstOf(self, @intCast(i)) == null) continue;
        const p = cg_filters.planOf(self, i);
        if (p.err != null) continue;
        const lo = self.out.items.len;
        const nm = try std.fmt.allocPrint(self.arena, "{s}__sec", .{self.names.unit_names[i]});
        const at = try cg_filters.emitFilterSections(self, self.names.unit_names[i], p, k == .zi);
        try gen_file.recordUnitFile(self, nm, lo, at);
    }
    for (self.jobs) |job| {
        if (job.kind != .display) continue;
        self.pre_fatal = job.pre_fatal;
        // §9.5 the one unit where a descriptor operation may actually happen.
        self.emitting_display = true;
        defer self.emitting_display = false;
        const lo = self.out.items.len;
        const at = try emitUnit(self, job.name, job.target, @tagName(job.mode), job.comment);
        try gen_file.recordUnitFile(self, job.name, lo, at);
    }
    self.pre_fatal = null;
}

/// The one declaration the shared core is emitted into. See the block
/// comment at "the shared core" for why the whole model is one declaration
/// returning a struct rather than one declaration per unit.
///
/// The return type is written INLINE (an anonymous struct in the signature)
/// rather than as a named `Common(S)`: a named type would be a second
/// top-level declaration, and in the single-file form it would have to be
/// public for the unit files to reach it — which `contract.validate`
/// rejects. Zig infers the anonymous type at both ends, so the units never
/// have to name it.
pub fn emitCommon(self: *Gen) Error!void {
    if (self.lo_vals.len == 0) return;
    self.emitting_common = true;
    defer self.emitting_common = false;

    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    // §3.6.2.2 a refusal visible from ANY unit's declaration poisons the one
    // body they now share. That is not a widening: `eval` stamps every
    // contribution, so a `@compileError` in any single unit already failed
    // the whole device.
    self.fatal = null;
    for (self.jobs) |job| {
        if (job.kind == .display) continue;
        if (job.pre_fatal) |m| {
            self.fatal = m;
            break;
        }
    }
    const pre = self.fatal;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(.undef, self.emitting_common); // `emitting_common` ⇒ the live-outs are the targets

    const lo = self.out.items.len;
    try self.w(
        \\/// The whole model, evaluated ONCE per residual: the {d} source units
        \\/// share one CFG, so they share one declaration and `eval`/`q` read
        \\/// their targets out of the returned struct.
        \\
        \\/// Inlined at every host-scalar site (`@call(.always_inline, ...)` in
        \\/// `eval`/`q`/`evalQ`), which destructure the returned struct at
        \\/// once: behind a call boundary the `[n_u]S` argument and the
        \\/// {d}-field result both go to memory, the host's Dual derivative
        \\/// vectors spill instead of staying in registers, and no live-out the
        \\/// caller drops can be dead-coded. Measured on ARPice
        \\/// devices/mos6_inverter: 45.3 ms inline vs 64.9 ms out-of-line
        \\/// (+43%), tran/fourbitadder +40%, scaling/parallel_inverters_500
        \\/// +51%. NOT `inline fn`, so the value-only `core(R, ...)` sites —
        \\/// updateState, noisePsd, collapse, limit, seed — share ONE
        \\/// out-of-line instantiation instead of each inlining the model.
        \\
    , .{ self.jobs.len, self.jobs.len });
    const at_fn = self.out.items.len;
    try self.w("fn {s}(comptime S: type, ", .{self.common_name});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr) struct {{\n", .{});
    for (self.lo_vals, 0..) |v, k| {
        try self.w("    f{d}: {s},\n", .{ k, zigTy(self.an.vty[@intFromEnum(v)]) });
    }
    for (self.hp_vals, 0..) |v, j| {
        try self.w("    f{d}: {s}, // hoisted prefix\n", .{
            self.lo_vals.len + j, zigTy(self.an.vty[@intFromEnum(v)]),
        });
    }
    try self.w("}} {{\n", .{});
    // §4.3: the STRICTEST mode of every consumer — `proof.FloatMode.strictest`
    // explains why the join has to absorb `.strict`.
    try self.w("    @setFloatMode(.{t});\n", .{self.common_mode});
    self.cur_strict = self.common_mode == .strict;

    // Off the slice, not the text: every call the core computes is in
    // `plan.live`, and `gen_call.readsSimState` is the one list of which of
    // them render a read of a host-published sim-state field.
    for (self.plan.live.items) |lv| {
        const def = self.mir.valueDef(lv);
        if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) continue;
        if (self.plan.pcHoisted(lv)) continue; // a field read, not a call
        if (gen_call.readsSimState(self, def.inst_result)) self.core_reads_simstate = true;
    }

    const body_start = self.out.items.len;
    self.fatal = pre;
    try emitUnitBody(self, .undef);
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses_x) patchParam(self, at_x, "x".len);
    if (!self.uses_model) patchParam(self, at_model, "model".len);
    if (!self.uses_inst) patchParam(self, at_inst, "inst".len);
    try self.w("}}\n\n", .{});
    try gen_file.recordUnitFile(self, self.common_name, lo, at_fn);
}

/// The operator `call` unit `unit` was enumerated from — `naming` records it.
pub fn opInstOf(self: *const Gen, unit: u32) ?Mir.Inst {
    const inst = self.names.units[unit].inst;
    return if (inst == .none) null else inst;
}

/// The unit enumerated from operator `call` `inst`, or `none_u32`.
// ponytail: a scan over the unit list (tens of entries), once per rendered
// operator; an nv-sized reverse map is what this replaced.
pub fn unitOfInst(self: *const Gen, inst: Mir.Inst) u32 {
    for (self.names.units, 0..) |u, i| {
        if (u.inst == inst) return @intCast(i);
    }
    return none_u32;
}

/// Call arguments of the operator that owns unit `i` (empty if it has none).
pub fn opArgs(self: *const Gen, i: usize) []const Mir.Value {
    const inst = opInstOf(self, @intCast(i)) orelse return &.{};
    return self.mir.instData(inst).call.args;
}

/// Which field of the core holds analog-operator unit `i`'s §4.5 input, or
/// `none_u32` for an operator called with no argument (its input is the
/// literal zero and never reaches the core).
pub fn opInputIdx(self: *const Gen, i: u32) u32 {
    const args = opArgs(self, i);
    if (args.len == 0) return none_u32;
    return self.lo_idx[@intFromEnum(self.an.rv(args[0]))];
}

/// Emit one source-unit function. LRM §5.6/§4.7/§5.3.
/// The signature is UNIFORM and never churns; only the body depends on the
/// unit's own logic, so `zig` re-Semas exactly the units that changed.
/// Which parameters the body ended up reading is only known after the body
/// is rendered, but the signature comes first. Rather than render into a
/// scratch buffer and copy (a second pass over every byte of a 191 MB
/// output), emit the signature with three fixed-width slots and overwrite
/// them in place. Zig does the same thing — `Parse.reserveNode` /`setNode`,
/// AstGen's `instructions.append(undefined)` … `instructions.set(...)`.
///
/// Zig allows whitespace before a parameter's `:`, so `_` can be padded out
/// to the width of the name it replaces. Padding the DISCARD rather than the
/// name keeps the used case byte-identical to a direct emit.
///
/// Returns the offset of the `fn` keyword, which is where
/// `orchestrator.writeTree` splices `pub ` when the declaration is written
/// to its own `u/<key>.zig`. It is NOT emitted `pub` here: `text` is also
/// the single-file `--emit-zig` form, and `contract.rejectStrayPubDecls`
/// (tools/contract.zig) allows only contract-recognized names
/// to be public on a device type. A per-unit name can never be one of
/// those, so the visibility belongs to the split, not to the emission.
pub fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: []const u8, comment: []const u8) Error!usize {
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    self.fatal = self.pre_fatal;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(target, self.emitting_common);

    try self.w("/// {s}\n", .{comment});
    const at_fn = self.out.items.len;
    try self.w("fn {s}(comptime S: type, ", .{name});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr) S {{\n", .{});
    try self.w("    @setFloatMode(.{s});\n", .{mode});
    self.cur_strict = std.mem.eql(u8, mode, "strict");

    const body_start = self.out.items.len;
    try emitUnitBody(self, target);
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses_x) patchParam(self, at_x, "x".len);
    if (!self.uses_model) patchParam(self, at_model, "model".len);
    if (!self.uses_inst) patchParam(self, at_inst, "inst".len);
    try self.w("}}\n\n", .{});
    return at_fn;
}

/// Overwrite a reserved parameter-name slot with `_`, space-padded to the
/// name's width so the bytes after it do not move.
pub fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
    self.out.items[at..][0..width].* = ("_" ++ " " ** (width - 1)).*;
}

// ---- slicing: what this unit actually has to compute -------------------

/// What taking `from → to` reduces to for this unit, or null when the edge
/// does something the unit can observe. Iterative, not recursive: the chain
/// of empty blocks is bounded by nothing syntactic.

// ---- body emission ------------------------------------------------------

pub fn zigTy(t: VTy) []const u8 {
    return switch (t) {
        .real => "S",
        .int => "i64",
        .str => "[]const u8",
    };
}

/// The identity a slot starts at when it must be defined on every path.
/// Matches `renderVal`'s rendering of an `.undef` operand, so the two agree
/// on what "no value here" looks like.
/// Name of the hoist array a slot of this type lives in — see `hoist_idx`.
pub fn hoistArray(t: VTy) []const u8 {
    return switch (t) {
        .real => "h",
        .int => "hi",
        .str => "hs",
    };
}

/// The name a value's slot is read and written under: its own `tN`, or an
/// element of its type's hoist array. The ONE place that knows the
/// difference, so declaration and use can never drift apart.
///
/// `writeSlotRef` is the hot form — every slotted use goes through it, and
/// it writes straight into the output buffer. `slotRefStr` is for the one
/// caller that needs the name as a value (`f64Const`).
pub fn slotArr(self: *Gen, i: usize) ?[]const u8 {
    const s = self.plan.slot[i];
    if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return hoistArray(self.an.vty[i]);
    return null;
}
pub fn slotNum(self: *Gen, i: usize) u32 {
    const s = self.plan.slot[i];
    if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return self.hoist_idx.items[s];
    return s;
}
pub fn writeSlotRef(self: *Gen, i: usize) Error!void {
    if (slotArr(self, i)) |arr| {
        return self.b("{s}[{d}]", .{ arr, slotNum(self, i) });
    }
    return self.b("t{d}", .{slotNum(self, i)});
}
pub fn slotRefStr(self: *Gen, i: usize) Error![]const u8 {
    if (slotArr(self, i)) |arr| {
        return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ arr, slotNum(self, i) });
    }
    return std.fmt.allocPrint(self.arena, "t{d}", .{slotNum(self, i)});
}

pub fn zeroOf(t: VTy) []const u8 {
    return switch (t) {
        .real => "S.con(0.0)",
        .int => "0",
        .str => "\"\"",
    };
}

/// Where one slot's declaration ends up, and the evidence for it.
///
/// `def_off`/`max_use` are output offsets and `scope` an index into
/// `sc_end`: since the emitted scopes nest, "every use is lexically inside
/// the block that defines this slot" is exactly
/// `def_off < max_use < sc_end[scope]`, and no dominator query is needed —
/// the emitter's own brace placement IS the answer.
pub const Place = struct {
    defs: u32 = 0,
    uses: u32 = 0,
    def_off: u32 = 0,
    /// Offset of the LAST def — a loop-carried slot's final write sits
    /// textually after its last read, and the prefix planner
    /// (`planHoistPrefix`) must see it.
    max_def: u32 = 0,
    max_use: u32 = 0,
    scope: u32 = 0,
    /// Something disqualifies this slot from `const`-at-definition: a
    /// second assignment (a real phi), a phi copy on a CFG edge, or a use
    /// emitted before the assignment (a loop-carried read).
    pinned: bool = false,
    /// Set once, after the probe: declare at the definition instead of at
    /// function scope.
    at_def: bool = false,
};

pub fn scopeOpen(self: *Gen) Error!void {
    if (!self.probing) return;
    try self.sc_end.append(self.arena, 0);
    try self.sc_open.append(self.arena, @intCast(self.sc_end.items.len - 1));
}

/// `at` is where the scope's text ends, which is NOT always `out.len`: the
/// `emitCode` peephole rewinds over a label it decided not to keep.
pub fn scopeClose(self: *Gen, at: usize) void {
    if (!self.probing) return;
    self.sc_end.items[self.sc_open.pop().?] = @intCast(at);
}

/// `movable` is false for a phi copy: `emitPhiCopies` writes the slot from
/// several edges, and even a single-edge copy lands in an arm its merge
/// block's readers are lexically outside of.
pub fn probeDef(self: *Gen, slot: u32, movable: bool) void {
    if (!self.probing) return;
    const p = &self.place.items[slot];
    if (p.defs == 0) {
        p.def_off = @intCast(self.out.items.len);
        p.scope = self.sc_open.getLast();
    }
    p.max_def = @intCast(self.out.items.len);
    p.defs += 1;
    if (p.defs > 1 or !movable) p.pinned = true;
}

pub fn probeUse(self: *Gen, slot: u32) void {
    if (!self.probing) return;
    const p = &self.place.items[slot];
    p.uses += 1;
    // Read before written in the text: a loop-carried value, or a slot the
    // emitter never assigns at all (which is the `undefined`/zero seed the
    // hoist exists to provide).
    if (p.defs == 0) p.pinned = true;
    p.max_use = @max(p.max_use, @as(u32, @intCast(self.out.items.len)));
}

/// Emit the body once into scratch to learn, per slot, where its assignment
/// lands relative to its reads; rewind; then emit for real.
///
/// A dry run rather than a dominator/liveness query because the emitted
/// nesting is not the CFG: `planDeadBranches` deletes `if`s, the `emitCode`
/// peephole deletes labels, and `emitEdge` inlines a whole subtree into an
/// arm. Re-deriving the resulting brace structure would be a second, subtly
/// different copy of the emitter. Emission only appends to `out` and only
/// sets monotone `uses_*` flags, so running it twice is free of side
/// effects (`fatal` is set-once and reproduces the same message).
pub fn probeBody(self: *Gen, target: Mir.Value) Error!void {
    self.place.clearRetainingCapacity();
    try self.place.appendNTimes(self.arena, .{}, self.plan.n_slots);
    self.sc_end.clearRetainingCapacity();
    self.sc_open.clearRetainingCapacity();

    const at = self.out.items.len;
    self.probing = true;
    self.hp_bnd = 0;
    self.hp_cut = 0;
    self.hp_off = 0;
    self.hp_dirty = false;
    self.stmt_count = 0;
    try scopeOpen(self); // the function body itself
    try gen_cfg.emitTree(self, 0, 1, target);
    scopeClose(self, self.out.items.len);
    self.probing = false;
    self.hp_bnd = 0; // the real walk counts the same boundaries from zero
    self.out.shrinkRetainingCapacity(at);

    for (self.place.items) |*p| {
        // `uses == 0` keeps its `var`: a slot that is written and never read
        // is legal Zig, but the same code as an unused `const` is not.
        p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
            p.max_use < self.sc_end.items[p.scope];
    }
    // A value crossing the prefix guard has to be in a hoist ARRAY: the
    // guard is a scope its `const` would not survive, and the else arm has
    // to be able to assign it.
    for (self.hp_vals) |v| {
        const s = self.plan.slot[@intFromEnum(v)];
        if (s != none_u32) self.place.items[s].at_def = false;
    }
}

pub fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
    // FIRST, before anything can emit a slot name: slot numbering is
    // unit-local, so last unit's hoist indices would otherwise still be
    // live here and rename this unit's slots into another unit's array.
    // Both paths below can emit before the real assignment happens — the
    // straight-line path returns early, and `probeBody` dry-runs the whole
    // body — so clearing anywhere later is too late.
    self.hoist_idx.clearRetainingCapacity();
    try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);

    // One call, at the top of the body, so the shared core is evaluated
    // exactly once per unit — the same number of times it is evaluated
    // today, when every unit inlines a copy of it.
    if (self.plan.uses_cache) {
        self.uses_x = true;
        self.uses_model = true;
        self.uses_inst = true;
        try self.ind(1);
        try self.b("const c = @call(.always_inline, core, .{{ S, x, model, inst }});\n", .{});
    }
    if (self.plan.straight) {
        try gen_cfg.emitBlockInsts(self, 0, 1, true);
        try gen_cfg.emitReturn(self, 1, target);
        return;
    }
    // Out-of-SSA: a function-scope `var` per surviving value that NEEDS
    // one. Function scope (not the defining lexical block) because a
    // labelled-block reconstruction can put a definition inside a scope its
    // dominated uses are lexically outside of — but that is the exception,
    // not the rule, so `probeBody` measures it instead of assuming it and
    // `emitBlockInsts` declares the rest as `const` at the definition. On
    // `hisimhv_va` that is 16 k of 20 k hoists removed, ~26% of the file.
    //
    // What is left hoisted, and why each one has to be:
    //   - assigned more than once — a genuine phi, so it must be a `var`;
    //   - assigned by `emitPhiCopies` — the copy sits in the arm, the
    //     readers sit after the merge;
    //   - read outside the block that assigns it — the labelled-block case
    //     the comment above describes;
    //   - never assigned at all, which is the `undefined`/zero seed below.
    //
    // `undefined` is safe for every slot EXCEPT one the function RETURNS.
    // SSA guarantees a use is dominated by its definition, so an ordinary
    // slot is always written before it is read — but the return is reached
    // from every exit block, including ones the definition does not
    // dominate. That happens whenever the unit's target is defined inside a
    // conditional, which is exactly what `if (c) I <+ transition(x)` builds:
    // the operator's INPUT unit then returned `undefined` on the not-taken
    // path, and `updateState` pushed that into the operator's history —
    // undefined behavior in a shipped device, and silent state corruption in
    // the far more common case where it merely looked like a number.
    //
    // Zero is the value, not just a safe one: the arm did not execute, so it
    // contributed nothing this step — the same reason lowering seeds a §5.6
    // contribution accumulator with `.f_zero`.
    // Pinned by tests/fixtures/exhaustive/069_conditional_operator_state.va.
    try probeBody(self, target);
    const ret = self.an.rv(target);

    // One array per type instead of one `var` per slot. Two passes: assign
    // every survivor its index first, so the array lengths are known before
    // anything is written, then emit the declarations. `hoist_idx` was
    // cleared at entry and `probeBody` has just run against those cleared
    // names, so this is the first assignment either pass has seen.
    var n_hoist = [_]u32{0} ** 3;
    // A returned slot cannot be seeded `undefined` (see above), and an array
    // is declared once for all of its elements — so those are seeded by an
    // explicit store after the declaration instead.
    var seeded: std.ArrayList(Mir.Value) = .empty;
    defer seeded.deinit(self.arena);
    for (self.plan.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (self.plan.slot[v] == none_u32) continue;
        const p = self.place.items[self.plan.slot[v]];
        if (p.at_def) continue;
        // Never assigned and never read: `mark` kept the value alive but
        // the emitted tree reaches neither end of it. Declaring it would be
        // an unused local.
        if (p.defs == 0 and p.uses == 0) continue;
        const ty = @intFromEnum(self.an.vty[v]);
        self.hoist_idx.items[self.plan.slot[v]] = n_hoist[ty];
        n_hoist[ty] += 1;
        const returned = if (self.emitting_common) self.lo_idx[v] != none_u32 else lv == ret;
        if (returned) try seeded.append(self.arena, lv);
    }
    for ([_]VTy{ .real, .int, .str }) |ty| {
        const n = n_hoist[@intFromEnum(ty)];
        if (n == 0) continue;
        try self.ind(1);
        try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
    }
    for (seeded.items) |lv| {
        const v = @intFromEnum(lv);
        try self.ind(1);
        try writeSlotRef(self, v);
        try self.b(" = {s};\n", .{zeroOf(self.an.vty[v])});
    }
    try gen_cfg.emitTree(self, 0, 1, target);
    // The guard opened at boundary 0 is closed at boundary `hp_cut`;
    // if the real walk never reached it the emitted brace is unbalanced,
    // which is a generator bug and not something to ship.
    assert(!self.hp_on or !self.emitting_common or self.hp_bnd > self.hp_cut);
}
