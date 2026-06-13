//! Call-argument facts the slice planners (`plan/setup.zig`, `plan/unit.zig`)
//! and the emitter share: which arguments are values, and the §9.4 display
//! mode that decides some of them. Callee in, answer out.

const std = @import("std");
const Mir = @import("ir").Mir;
const opdb = @import("../op_zig.zig");
const OpKind = @import("ir").op.OpKind;
const Input = @import("input.zig").Input;

/// What to do with the §9.4 display tasks a model contains.
///
/// `.drop` is the default: a device runs in the solver's inner loop, on a
/// batch, sometimes on a GPU, where a print is a per-iteration syscall or does
/// not compile at all (SPIR-V/PTX). So a device never prints, and a source
/// that asked to is told so (W0850). `.emit` is the runnable testbench
/// (`--emit-exe`, tb.zig), where the text is the point.
pub const Display = enum { drop, emit };

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
        .timer,
        .@"$bound_step",
        .@"$discontinuity",
        => (enableArgIdx(Mir.callee.opKind(c)) orelse return false) == i,
        // §9.4.1/§9.7.3 the printing tasks.
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
        .@"$monitor",
        .@"$debug",
        .@"$fatal",
        .@"$error",
        .@"$warning",
        .@"$info",
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
        // §3.3 Table 3-3: every piece, and the count.
        .@"$str$cat", .@"$str$repeat" => true,
        .@"$limit$uf" => i < 2,
        // §9.15's param_name may be "a string variable", so `emitCall` renders
        // it and the unit has to compute it.
        .@"$simparam$str" => i == 0,
        .ddx, .limexp => i == 0,
        .@"$vt", .@"$limit", .@"$clog2", .@"$rtoi", .@"$itor" => i == 0,
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
        .@"$sscanf",
        .@"$table_model",
        .@"$held_int",
        .@"$held_real",
        .@"$limit$old",
        .@"$display$width",
        .@"$monitor$arm",
        .@"$sscanf$int",
        .@"$sscanf$real",
        .@"$sscanf$str",
        .@"$plusarg$str",
        .systf,
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

/// The literal string at argument `i`, or null when it is not one.
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
}
