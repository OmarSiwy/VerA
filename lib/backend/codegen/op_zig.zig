//! Backend facts per `ir.op.OpKind` (§4.5, §5.10.3, §9.17 operators): the
//! operator's `Instance` fields as Zig source, whether its kernel reads the
//! current input or `dt`, and which argument is the §5.10.3 `enable`.
//! `absdelay`, `laplace` and `zi` size their fields from the call, so they are
//! `.from_args` and codegen computes them.

const std = @import("std");
const OpKind = @import("ir").op.OpKind;

/// One `f64` `Instance` field an operator owns. The only non-f64 operator
/// field (`absdelay`'s `__head: u32`) is `.from_args`, so there is no type
/// column.
pub const Slot = struct {
    /// Field name is `<unit>__<suffix>`.
    suffix: []const u8,
    /// Rendered verbatim as the struct-field default. Not always "0.0":
    /// §4.5.10's `__t_last` starts at -1.0 to mean "no crossing yet".
    default: []const u8,
    /// Trailing `// ...` on the emitted line. Empty for none.
    note: []const u8 = "",
};

/// One operator's backend facts.
pub const Row = struct {
    /// The clause this operator realizes.
    lrm: []const u8,

    /// The kernel reads the current input rather than answering from
    /// `Instance` alone. `emitOperator` and `UnitPlan.callArgIsValue` both
    /// read this, so they agree.
    ///
    /// `cross` and `timer` compare the current input (`timer`: its
    /// `start_time`) against `__prev` in `eval` (§5.10.3). `zi` needs it for
    /// the §4.5.12 static branch. `absdelay` needs it for the §4.5.7 DC
    /// pass-through and for a delay shorter than the accepted step.
    needs_input: bool,

    /// `updateState` needs `dt` (time since the last accepted step) to
    /// advance this operator.
    needs_dt: bool,

    /// Index of the §5.10.3 `enable` argument: the one control argument that
    /// stays a runtime expression, so `UnitPlan` keeps it live while every
    /// other control argument folds at codegen time.
    enable_arg: ?u8,

    /// The `Instance` fields this operator always owns.
    slots: []const Slot = &.{},

    /// `.static`: `slots` is complete. `.from_args`: the field count depends
    /// on the call and codegen computes it. `.none`: no per-unit field (§9.17
    /// writes the two unconditional `Instance` members instead).
    shape: enum { static, from_args, none } = .static,
};

/// Every operator's row; total over `OpKind`, so a new variant fails to
/// compile here.
pub const table = std.EnumArray(OpKind, Row).init(.{
    .none = .{
        .lrm = "",
        .needs_input = false,
        .needs_dt = false,
        .enable_arg = null,
        .shape = .none,
    },
    .idt = .{
        .lrm = "§4.5.4",
        .needs_input = true,
        .needs_dt = true,
        .enable_arg = null,
        .slots = &.{.{ .suffix = "acc", .default = "0.0", .note = "§4.5.4" }},
    },
    .idtmod = .{
        .lrm = "§4.5.5",
        .needs_input = true,
        .needs_dt = true,
        .enable_arg = null,
        .slots = &.{.{ .suffix = "acc", .default = "0.0", .note = "§4.5.4" }},
    },
    .absdelay = .{
        .lrm = "§4.5.7",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = null,
        // Ring length is `hist_len` and the `__td` field exists only for a
        // SIGNAL-valued td, so codegen emits these.
        .shape = .from_args,
    },
    .transition = .{
        .lrm = "§4.5.8",
        .needs_input = true,
        .needs_dt = true,
        .enable_arg = null,
        // The origin of the ramp in progress (level and time the output left),
        // not the previous output: that keeps the traversal piecewise linear
        // rather than exponential. `zTransStep` re-arms it only once the output
        // has caught up, so a multi-step ramp counts from where it started.
        .slots = &.{
            .{ .suffix = "from", .default = "0.0", .note = "§4.5.8 ramp origin (value), destination, start time" },
            .{ .suffix = "to", .default = "0.0" },
            .{ .suffix = "t0", .default = "0.0" },
        },
    },
    .slew = .{
        .lrm = "§4.5.9",
        .needs_input = true,
        .needs_dt = true,
        .enable_arg = null,
        .slots = &.{.{ .suffix = "prev", .default = "0.0", .note = "§4.5" }},
    },
    .last_crossing = .{
        .lrm = "§4.5.10",
        .needs_input = false,
        .needs_dt = true,
        .enable_arg = null,
        .slots = &.{
            .{ .suffix = "prev", .default = "0.0", .note = "§4.5.10" },
            .{ .suffix = "t_last", .default = "-1.0" },
        },
    },
    .laplace = .{
        .lrm = "§4.5.11",
        .needs_input = true,
        .needs_dt = true,
        .enable_arg = null,
        // Direct-form-I history of the FLATTENED cascade: ns*deg past inputs and
        // outputs. Structural, but a function of the call.
        .shape = .from_args,
    },
    .zi = .{
        .lrm = "§4.5.12",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = null,
        .shape = .from_args,
    },
    .cross = .{
        .lrm = "§5.10.3.1",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = 4, // cross(expr, dir, time_tol, expr_tol, enable)
        // No `__hit` flag: one written on the accepted step would be read one
        // timepoint after the event.
        .slots = &.{.{ .suffix = "prev", .default = "0.0", .note = "§5.10.3" }},
    },
    .above = .{
        .lrm = "§5.10.3.2",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = 3, // above(expr, time_tol, expr_tol, enable)
        // The 0.0 default implements the clause's initial rule: "If the
        // expression is positive at the conclusion of the initial condition
        // analysis ..., the above() function shall generate an event". With
        // `__prev` at zero the ordinary "was <= 0, is now > 0" test fires there.
        .slots = &.{.{ .suffix = "prev", .default = "0.0", .note = "§5.10.3.2" }},
    },
    .timer = .{
        .lrm = "§5.10.3.3",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = 3, // timer(start, period, time_tol, enable)
        // `start` is the start_time the pending `next` was scheduled from. A
        // different start_time re-schedules, earlier or later (§5.10.3.3: "the
        // next event will be scheduled based on the latest value"). NaN means
        // nothing is scheduled yet and differs from every start_time.
        .slots = &.{
            .{ .suffix = "next", .default = "0.0", .note = "§5.10.3" },
            .{ .suffix = "start", .default = "std.math.nan(f64)" },
        },
    },
    .bound_step = .{
        .lrm = "§9.17.2",
        .needs_input = false,
        .needs_dt = false,
        .enable_arg = null,
        // §9.17 writes the unconditional `bound_step`/`discontinuity_order`
        // members. The unit exists so `updateState` has a function to
        // evaluate the requested value with.
        .shape = .none,
    },
    .discontinuity = .{
        .lrm = "§9.17.1",
        .needs_input = false,
        .needs_dt = false,
        .enable_arg = null,
        .shape = .none,
    },
});

/// Returns `k`'s row.
pub fn get(k: OpKind) Row {
    return table.get(k);
}

test "op_zig: the table is total and internally consistent" {
    // Totality is already a compile-time property of EnumArray; what a test can
    // still catch is a row that contradicts itself.
    for (std.enums.values(OpKind)) |k| {
        const r = get(k);
        if (k == .none) {
            try std.testing.expectEqual(@as(usize, 0), r.slots.len);
            continue;
        }
        // Every real operator cites the clause it realizes.
        try std.testing.expect(r.lrm.len != 0);
        try std.testing.expect(std.mem.startsWith(u8, r.lrm, "§"));
        // `.static` is the claim that `slots` is complete, so a `.static` row
        // with no slots is one of the two meaning `.none`, spelled wrong.
        if (r.shape == .static) try std.testing.expect(r.slots.len != 0);
        if (r.shape == .from_args) try std.testing.expectEqual(@as(usize, 0), r.slots.len);
        // An `enable` is the LAST argument of the three §5.10.3 forms; nothing
        // else has one.
        if (r.enable_arg != null)
            try std.testing.expect(k == .cross or k == .above or k == .timer);
    }
}

test "op_zig: the three §5.10.3 enable indices are the last argument" {
    try std.testing.expectEqual(@as(?u8, 4), get(.cross).enable_arg);
    try std.testing.expectEqual(@as(?u8, 3), get(.above).enable_arg);
    try std.testing.expectEqual(@as(?u8, 3), get(.timer).enable_arg);
    try std.testing.expectEqual(@as(?u8, null), get(.slew).enable_arg);
}
