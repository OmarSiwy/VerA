//! §4.5 analog operators, §5.10.3 monitored events and §9.17 kernel control —
//! one row per operator, one column per consumer.
//!
//! WHY THIS FILE EXISTS. The facts about a single operator used to be spread
//! over five call sites that had no way to know about each other: `transition`
//! appears 53 times in codegen.zig, 9 in lower.zig and 3 in cg_filters.zig, and
//! its arity, its `Instance` fields, whether `updateState` needs `dt` and
//! whether its kernel reads the current input were four separate switches in
//! three functions. Adding an operator meant finding all of them, and MISSING
//! one was silent: an absent arm fell through to `else` and the new operator
//! got `needs_input = false`, `enable_arg = null`, no state fields and no `dt`
//! — four wrong answers, no diagnostic, a model that quietly computes the
//! wrong number.
//!
//! `table` is a `std.EnumArray`, so it is total by construction: add a variant
//! to `OpKind` and this file stops compiling until the row exists. That is the
//! whole point. The compiler now asks the question the reviewer used to.
//!
//! WHAT IS DELIBERATELY NOT HERE:
//!
//!   - the callee → `OpKind` mapping. It is `callee.opKind`, a switch over
//!     `Callee` (laplace/zi have four spellings each, so it is many-to-one and
//!     not a column), and this file stays a leaf that imports only `std`.
//!   - the `Instance` shapes of `absdelay`, `laplace` and `zi`. Their field
//!     COUNT is a function of the call (the delay ring's length, the flattened
//!     cascade's ns*deg), so codegen computes them from `filterPlan` /
//!     `absdelayFreezes` and always will. `shape = .from_args` says so; the
//!     alternative was inventing a little language for array lengths inside a
//!     table, which is a worse spelling of the code it would have replaced.
//!
//! DOD: a dense `EnumArray` of comptime-known rows. No allocation, no hashing,
//! no runtime construction — every field resolves at compile time and the
//! `slots` slices point into `.rodata`.

const std = @import("std");

/// Every operator that owns per-instance state or a monitored event.
/// `naming.enumerateUnits` gives each occurrence of one a unit; `.none` is the
/// answer for every other `call` callee.
///
/// §4.5.13 `limexp` and §4.5.14 `ddx` are NOT here and must not be added: they
/// are pure functions of their argument, so they own no state and get no unit
/// (`naming.isStatefulAnalogOp` is the other half of that rule).
pub const OpKind = enum {
    none,
    ddt, // §4.5.3
    idt, // §4.5.4
    idtmod, // §4.5.5
    absdelay, // §4.5.7
    transition, // §4.5.8
    slew, // §4.5.9
    last_crossing, // §4.5.10
    laplace, // §4.5.11
    zi, // §4.5.12
    cross, // §5.10.3
    above, // §5.10.3
    timer, // §5.10.3
    bound_step, // §9.17.2
    discontinuity, // §9.17.1
};

/// One `Instance` field an operator owns. `codegen.emitInstance` writes these
/// out; it does not need to know what any of them mean.
///
/// There is no `ty`: every one of these is an `f64`. The one operator with a
/// non-f64 field (`absdelay`'s `__head: u32`) is `.from_args` anyway, so a type
/// column would have exactly one value and never vary. Add it when a second
/// arrives.
pub const Slot = struct {
    /// Field name is `<unit>__<suffix>`.
    suffix: []const u8,
    /// Rendered verbatim as the struct-field default. Not always "0.0":
    /// §4.5.10's `__t_last` starts at -1.0 to mean "no crossing yet".
    default: []const u8,
    /// Trailing `// ...` on the emitted line. Empty for none.
    note: []const u8 = "",
};

pub const Row = struct {
    /// The clause this operator realizes, as data. codegen used to carry this
    /// string inline in fourteen separate format literals.
    lrm: []const u8,

    /// Does the kernel read the CURRENT input, or answer from `Instance`
    /// alone? `emitOperator` renders `in` exactly for these and `UnitPlan`
    /// (`callArgIsValue`) has to agree, which is why the set lives in one place
    /// rather than in either of them.
    ///
    /// `cross` and `timer` are in the set because the §5.10.3 event moved into
    /// `eval`: the hit test compares the current input against `__prev`
    /// (`timer`'s "input" being its `start_time`). `zi` is in it for the
    /// §4.5.12 static branch, which is a gain on the input and not a held
    /// value. `absdelay` is in it for `zAbsdelay`'s two input-valued edges —
    /// the §4.5.7 DC pass-through, and a delay shorter than the accepted step,
    /// whose only covering data is the in-flight value.
    needs_input: bool,

    /// Does `updateState` need `dt` (the time since the last accepted step) to
    /// advance this operator?
    needs_dt: bool,

    /// §5.10.3: index of the `enable` argument — the ONE control argument of an
    /// analog operator that stays a runtime expression, so `UnitPlan` must keep
    /// it live while every other control argument folds at codegen time.
    enable_arg: ?u8,

    /// The `Instance` fields this operator always owns.
    slots: []const Slot = &.{},

    /// `.static` — `slots` is the complete answer.
    /// `.from_args` — the field count depends on the call; codegen computes it.
    /// `.none` — owns no per-unit field at all (§9.17 writes the two
    ///   unconditional `Instance` members instead).
    shape: enum { static, from_args, none } = .static,
};

/// THE TABLE. Total over `OpKind` by construction — a new variant is a compile
/// error here before it is a wrong answer anywhere else.
pub const table = std.EnumArray(OpKind, Row).init(.{
    .none = .{
        .lrm = "",
        .needs_input = false,
        .needs_dt = false,
        .enable_arg = null,
        .shape = .none,
    },
    .ddt = .{
        .lrm = "§4.5.3",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = null,
        .slots = &.{.{ .suffix = "prev", .default = "0.0", .note = "§4.5" }},
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
        // The ORIGIN of the ramp in progress: the level the output left and the
        // time it left it. NOT "the previous output" — that is the whole
        // difference between a piecewise LINEAR traversal of the excursion and
        // an exponential one. Re-armed by `zTransStep` only once the output has
        // caught up with its input, so a ramp spanning several timesteps keeps
        // counting from where it actually started.
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
        // The history the event test compares against, and nothing else: there
        // is no `__hit` flag, because a flag written on the accepted step is a
        // flag read one timepoint after the event (see `emitOperator`).
        .slots = &.{.{ .suffix = "prev", .default = "0.0", .note = "§5.10.3" }},
    },
    .above = .{
        .lrm = "§5.10.3.2",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = 3, // above(expr, time_tol, expr_tol, enable)
        // The 0.0 initialiser is not a placeholder — it IS the clause's
        // initialisation rule. "If the expression is positive at the conclusion
        // of the initial condition analysis that precedes a transient analysis,
        // the above() function shall generate an event": with `__prev` at zero
        // the ordinary "was ≤ 0, is now > 0" test fires on exactly that first
        // positive evaluation, so the special case needs no code of its own.
        .slots = &.{.{ .suffix = "prev", .default = "0.0", .note = "§5.10.3.2" }},
    },
    .timer = .{
        .lrm = "§5.10.3.3",
        .needs_input = true,
        .needs_dt = false,
        .enable_arg = 3, // timer(start, period, time_tol, enable)
        .slots = &.{.{ .suffix = "next", .default = "0.0", .note = "§5.10.3" }},
    },
    .bound_step = .{
        .lrm = "§9.17.2",
        .needs_input = false,
        .needs_dt = false,
        .enable_arg = null,
        // §9.17 writes the two UNCONDITIONAL `Instance` members
        // (`bound_step`, `discontinuity_order`), not a per-unit field. The unit
        // exists so `updateState` has one named function to evaluate the
        // requested value with.
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

pub fn get(k: OpKind) Row {
    return table.get(k);
}

/// Does this operator need `updateState` to advance anything? Everything that
/// reaches `OpKind` other than `.none` does, including the §9.17 tasks — their
/// unit is evaluated there even though their fields are unconditional.
pub fn hasState(k: OpKind) bool {
    return k != .none;
}

// ---------------------------------------------------------------------------

test "op: the table is total and internally consistent" {
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

test "op: the three §5.10.3 enable indices are the last argument" {
    try std.testing.expectEqual(@as(?u8, 4), get(.cross).enable_arg);
    try std.testing.expectEqual(@as(?u8, 3), get(.above).enable_arg);
    try std.testing.expectEqual(@as(?u8, 3), get(.timer).enable_arg);
    try std.testing.expectEqual(@as(?u8, null), get(.ddt).enable_arg);
}
