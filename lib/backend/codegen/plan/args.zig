//! Call-argument facts the slice planners (`plan/setup.zig`, `plan/unit.zig`)
//! and the emitter share: which arguments are values, and the §9.4 display
//! mode that decides some of them. Callee in, answer out. Clauses: §3.3,
//! §4.5, §4.5.14, §5.10.3, §9.4, §9.5, §9.7.3, §9.13, §9.15.

const std = @import("std");
const Mir = @import("ir").Mir;
const opdb = @import("../op_zig.zig");
const OpKind = @import("ir").op.OpKind;
const Input = @import("input.zig").Input;

/// What to do with the §9.4 display tasks a model contains.
///
/// A device runs in the solver's inner loop, on a batch, sometimes on a GPU,
/// where a print is a per-iteration syscall or does not compile at all
/// (SPIR-V/PTX), so a device never prints. `.record` (a device's default)
/// gives it `say` instead: one entry point, outside `eval`, that a host calls
/// at an accepted point and that records each display task it runs as a
/// site index and its numeric values in a host-lent `contract.Say`
/// (`contract.SaySite`); what cannot be recorded is told so (W0850). `.drop`
/// is a device without that entry point, every task void (W0850). `.emit` is
/// the runnable testbench (`--emit-exe`, tb.zig), where the text is the point.
pub const Display = enum { drop, record, emit };

/// Is argument `i` of this call rendered as a value the calling unit must
/// compute? The others are consumed at codegen time: analysis names (§4.6.1),
/// operator control constants (§4.5), the operator input (its own unit
/// recomputes it), and the operands of ch9 tasks that answer from `Instance`
/// or a constant. Must stay in step with `emitCall`: slicing in an argument it
/// never renders declares an unread local (a Zig error), and missing one it
/// renders leaves an undefined leaf (`S.con(0.0)` in a print).
pub fn callArgIsValue(c: Mir.Callee, i: usize, display: Display) bool {
    return switch (c) {
        // The §5.10.3 `enable` is the exception: it is a live expression the
        // event test reads every evaluation, so it needs a slot like any other
        // operand.
        .@"idt$hold",
        .idtmod,
        .absdelay,
        .@"absdelay$quad",
        .transition,
        .slew,
        .last_crossing,
        .laplace_zd,
        .laplace_zp,
        .laplace_nd,
        .laplace_np,
        .zi_zd,
        .zi_zp,
        .zi_nd,
        .zi_np,
        .cross,
        .above,
        .@"$bound_step",
        .@"$discontinuity",
        => (enableArgIdx(Mir.callee.opKind(c)) orelse return false) == i,
        // §5.10.3.3 a latest period participates in the event condition too.
        .timer => i == 1 or i == 3,
        // §9.4.1/§9.7.3 the printing tasks: rendered by a printing artifact,
        // and recorded by a device's `say` (`contract.SaySite`)...
        .@"$display",
        .@"$displayb",
        .@"$displayo",
        .@"$displayh",
        .@"$write",
        .@"$writeb",
        .@"$writeo",
        .@"$writeh",
        .@"$strobe",
        .@"$strobeb",
        .@"$strobeo",
        .@"$strobeh",
        .@"$debug",
        .@"$warning",
        .@"$info",
        => display != .drop,
        // ...except a monitor, whose change detection a device does not
        // keep, and the two §9.7.3 tasks a device reports as a status.
        .@"$monitor",
        .@"$fatal",
        .@"$error",
        => display == .emit,
        // §9.5 every operand is live: the path, the type, the descriptor, the
        // control string, the offset. `emitCall` renders them all, in the
        // display unit because the kernels take them and in every other unit
        // through `emitFileCallDropped`, so this answer is one rule.
        .@"$fopen",
        .@"$fclose",
        .@"$fflush",
        .@"$fdisplay",
        .@"$fwrite",
        .@"$fstrobe",
        .@"$fmonitor",
        .@"$fdebug",
        .@"$fgets",
        .@"$fscanf",
        .@"$ftell",
        .@"$fseek",
        .@"$rewind",
        .@"$ferror",
        .@"$feof",
        .@"$fgets$str",
        .@"$ferror$str",
        .@"$fscanf$int",
        .@"$fscanf$real",
        .@"$fscanf$str",
        => display == .emit,
        .@"$rng$check" => i != 1, // prior effect and checked values
        // The automatic-seed site's index is consumed by the emitter, not at
        // runtime.
        .@"$rng$auto" => false,
        // A live variate/Next call reads its seed and numeric parameters.
        .@"$rng$rand",
        .@"$rng$rand_next",
        .@"$rng$i_uniform",
        .@"$rng$i_uniform_next",
        .@"$rng$uniform",
        .@"$rng$uniform_next",
        .@"$rng$normal",
        .@"$rng$normal_next",
        .@"$rng$exponential",
        .@"$rng$exponential_next",
        .@"$rng$poisson",
        .@"$rng$poisson_next",
        .@"$rng$chi_square",
        .@"$rng$chi_square_next",
        .@"$rng$t",
        .@"$rng$t_next",
        .@"$rng$erlang",
        .@"$rng$erlang_next",
        => true,
        .@"$idx", .@"$idx$int", .@"$idx$str" => i > 0, // index and selectable cells
        // IEEE 1364 §5.4 the operands; argument 0 is the tree's root, which
        // the emitter reads (`codegen/wide.zig`).
        .@"$wide", .@"$wide$int" => i > 0,
        // §3.3 Table 3-3: every piece, and the count.
        .@"$str$cat", .@"$str$repeat" => true,
        .@"$limit$uf" => i < 2,
        // §9.15's param_name may be "a string variable", so `emitCall` renders
        // it and the unit has to compute it.
        .@"$simparam$str" => i == 0,
        .ddx, .limexp => i == 0,
        .@"$vt", .@"$limit", .@"$clog2", .@"$rtoi", .@"$itor" => i == 0,
        // §12.32 a user system function's arguments, and §12.22.2 the
        // call an output argument is read back from: `emitSystfCall` and
        // `emitSystfOut` render every one, and the call itself must be one
        // value so its calltf runs once per evaluation.
        .systf,
        .@"$systf$out",
        // IEEE 1364 §17.11 math: every operand.
        .@"$sqrt",
        .@"$exp",
        .@"$expm1",
        .@"$ln",
        .@"$ln1p",
        .@"$log",
        .@"$log10",
        .@"$floor",
        .@"$ceil",
        .@"$sin",
        .@"$cos",
        .@"$tan",
        .@"$asin",
        .@"$acos",
        .@"$atan",
        .@"$sinh",
        .@"$cosh",
        .@"$tanh",
        .@"$asinh",
        .@"$acosh",
        .@"$atanh",
        .@"$pow",
        .@"$hypot",
        .@"$atan2",
        => true,
        // Events, noise, analysis names; and every task that answers from
        // `Instance`, `Model` or a constant, or reads its operands itself.
        .initial_step,
        .final_step,
        .analog_initial,
        .@"op$static",
        .analysis,
        .ac_stim,
        .white_noise,
        .flicker_noise,
        .noise_table,
        .noise_table_log,
        .@"$temperature",
        .@"$mfactor",
        .@"$abstime",
        .@"$realtime",
        .@"$simparam",
        .@"$param_given",
        .@"$port_connected",
        .@"$analog_node_alias",
        .@"$analog_port_alias",
        .@"$test$plusargs",
        .@"$value$plusargs",
        .@"$xposition",
        .@"$yposition",
        .@"$angle",
        .@"$hflip",
        .@"$vflip",
        .@"$realtobits",
        .@"$bitstoreal",
        .@"$monitoron",
        .@"$monitoroff",
        .@"$finish",
        .@"$stop",
        .@"$sformat",
        .@"$sformat$rt",
        .@"$sscanf",
        .@"$table_model",
        .@"$vera_reject_step",
        .@"$held_int",
        .@"$held_real",
        .@"$held_str",
        .@"$held_wide",
        .@"$tp_hit",
        .@"$tp_int",
        .@"$tp_real",
        .@"$tp_wide",
        .@"$limit$old",
        .@"$display$width",
        .@"$monitor$arm",
        .@"$sscanf$int",
        .@"$sscanf$real",
        .@"$sscanf$str",
        .@"$plusarg$str",
        => false,
    };
}

/// §5.10.3.1/.2/.3 where each event operator carries its `enable`, the one
/// argument of an analog operator that is a runtime expression, so `UnitPlan`
/// has to keep it live (see `callArgIsValue`) while every other control
/// argument is folded at codegen time.
pub fn enableArgIdx(k: OpKind) ?usize {
    // The table stores it as `?u8`, the narrowest type the range allows;
    // widened here, at the one boundary that indexes with it.
    return opdb.get(k).enable_arg orelse return null;
}

/// The literal string at argument `i`, or null when it is not one (or `i` is
/// past the end). The slice borrows the MIR's string table.
pub fn strArg(in: Input, args: []const Mir.Value, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    const def = in.mir.valueDef(in.an.rv(args[i]));
    return if (def == .str_const) def.str_const else null;
}

/// Does this operator's kernel read the current input? The pure-history ones
/// answer from `Instance` alone, and rendering an input they never emit would
/// leave the unit claiming a parameter (or a cache) nothing references.
/// `emitOperator` renders `in` exactly for these and `UnitPlan.analyze` must
/// agree, which is why the set lives in the op table and not in either.
pub fn opNeedsInput(k: OpKind) bool {
    return opdb.get(k).needs_input;
}

test "callArgIsValue: the display-gated prongs are the printing and §9.5 families" {
    // Only the §9.4.1/§9.7.3 printing tasks and the §9.5 family answer
    // differently under `.emit` and `.drop`; that is how `emitCall` gates them.
    for (std.meta.tags(Mir.Callee)) |c| {
        const want = Mir.callee.family(c) == .display or Mir.callee.isFileCall(c);
        try std.testing.expectEqual(want, callArgIsValue(c, 5, .emit) and !callArgIsValue(c, 5, .drop));
    }
    // `.record` keeps what a device's `say` records, and none of the §9.5
    // family, `$monitor` or the §9.7.3 status pair.
    try std.testing.expect(callArgIsValue(.@"$strobe", 0, .record));
    try std.testing.expect(callArgIsValue(.@"$warning", 0, .record));
    for ([_]Mir.Callee{ .@"$monitor", .@"$fatal", .@"$error", .@"$fdisplay" }) |c|
        try std.testing.expect(!callArgIsValue(c, 0, .record));
}

test enableArgIdx {
    // The positions are the clauses' own argument lists, counted from 0:
    // §5.10.3.1 `cross(expr, dir, time_tol, expr_tol, enable)`,
    // §5.10.3.2 `above(expr, time_tol, expr_tol, enable)`,
    // §5.10.3.3 `timer(start_time, period, time_tol, enable)`.
    try std.testing.expectEqual(@as(?usize, 4), enableArgIdx(.cross));
    try std.testing.expectEqual(@as(?usize, 3), enableArgIdx(.above));
    try std.testing.expectEqual(@as(?usize, 3), enableArgIdx(.timer));
    // No clause-4 operator and no §9.17 request has an `enable`.
    for ([_]OpKind{ .none, .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .bound_step, .discontinuity }) |k|
        try std.testing.expectEqual(@as(?usize, null), enableArgIdx(k));
}

test "callArgIsValue: an event operator keeps only its enable (and a timer its period) live" {
    const t = std.testing;
    // For every position up to one past the longest list, exactly the
    // positions the clause makes a runtime expression answer true.
    for (0..6) |i| {
        try t.expectEqual(i == 4, callArgIsValue(.cross, i, .drop));
        try t.expectEqual(i == 3, callArgIsValue(.above, i, .drop));
        // §5.10.3.3 "the next event will be scheduled based on the LATEST
        // value of the start_time and period": the period is live too.
        try t.expectEqual(i == 1 or i == 3, callArgIsValue(.timer, i, .drop));
        // §4.5.8 has no enable, and its input is its own unit's.
        try t.expect(!callArgIsValue(.transition, i, .emit));
        // §4.5.14 `ddx(expr, probe)`: the probe names a lane, it is not a value.
        try t.expectEqual(i == 0, callArgIsValue(.ddx, i, .drop));
        // IEEE 1364 §17.11 math reads every operand.
        try t.expect(callArgIsValue(.@"$hypot", i, .drop));
    }
    // A checked draw's argument 1 is consumed by the emitter, the rest are live.
    try t.expect(callArgIsValue(.@"$rng$check", 0, .drop));
    try t.expect(!callArgIsValue(.@"$rng$check", 1, .drop));
    try t.expect(callArgIsValue(.@"$rng$check", 2, .drop));
    // A user `$limit` function reads its two leading operands.
    try t.expect(callArgIsValue(.@"$limit$uf", 1, .drop));
    try t.expect(!callArgIsValue(.@"$limit$uf", 2, .drop));
}

test strArg {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{"a"});
    defer f.deinit();
    const a = f.alloc();
    const s = try f.mir.addStrConst(a, "pnjlim");
    const x = try f.mir.addFloatConst(a, 0.5);
    const an = try f.analysis();
    const in: Input = .{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered };
    const args = [_]Mir.Value{ x, s };
    try std.testing.expectEqualStrings("pnjlim", strArg(in, &args, 1).?);
    // A number is not a string, and a position past the end is not either.
    try std.testing.expectEqual(@as(?[]const u8, null), strArg(in, &args, 0));
    try std.testing.expectEqual(@as(?[]const u8, null), strArg(in, &args, 2));
}

test opNeedsInput {
    // §4.5.10 `last_crossing` answers from the crossing it latched; §5.10.3.1
    // `cross` compares the current input against the previous one.
    try std.testing.expect(!opNeedsInput(.last_crossing));
    try std.testing.expect(opNeedsInput(.cross));
    try std.testing.expect(opNeedsInput(.absdelay));
}

const Fixture = @import("fixture.zig").Fixture;
