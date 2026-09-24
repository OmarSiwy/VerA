//! What a MIR `call` calls, as an enum: every callee name lowering can emit.
//!
//! The tag IS the spelling (`.@"$vt"`, `.ddt`, `.@"$limit$old"`), so a name
//! round-trips through `@tagName` with no second table to drift, and a
//! consumer that dispatched with `mem.eql(u8, name, "$vt")` switches on
//! `.@"$vt"` instead — exhaustively, where tests/exhaustive.zig can see it.
//!
//! `.systf` is every name NOT listed: a §2.8.3 user system function (a VPI
//! registration, §12.32) or a typo W0852 reports. Its spelling is not the tag,
//! so a call keeps its raw name beside the enum (`Mir.InstData.call.name`).
//!
//! Minted once, by `Mir.emitCall`, the one MIR call constructor.
//!
//! DOD: `fromName` is one comptime `StaticStringMap` probe; `table` is
//! comptime rows in `.rodata`. No allocation.

const std = @import("std");
const op = @import("op.zig");

pub const Callee = enum(u8) {
    // §4.5 analog operators (Table 4-19) and §4.5.13/§4.5.14 limexp, ddx.
    ddt,
    idt,
    idtmod,
    absdelay,
    transition,
    slew,
    last_crossing,
    laplace_zd,
    laplace_zp,
    laplace_nd,
    laplace_np,
    zi_zd,
    zi_zp,
    zi_nd,
    zi_np,
    limexp,
    ddx,
    // §5.10 events; `analog_initial` is VerA's §5.10.2 first-point flag.
    cross,
    above,
    timer,
    initial_step,
    final_step,
    analog_initial,
    // §4.6 analysis-dependent functions, §4.6.4 noise.
    analysis,
    ac_stim,
    white_noise,
    flicker_noise,
    noise_table,
    noise_table_log,
    // §9.10/§9.15/§9.18/§9.19 environment, simulator and module queries.
    @"$temperature",
    @"$vt",
    @"$mfactor",
    @"$abstime",
    @"$realtime",
    @"$simparam",
    @"$simparam$str",
    @"$param_given",
    @"$port_connected",
    @"$analog_node_alias",
    @"$analog_port_alias",
    @"$test$plusargs",
    @"$value$plusargs",
    @"$xposition",
    @"$yposition",
    @"$angle",
    @"$hflip",
    @"$vflip",
    // §9.11 conversions, §9.12.1 $clog2.
    @"$rtoi",
    @"$itor",
    @"$realtobits",
    @"$bitstoreal",
    @"$clog2",
    // IEEE 1364 §17.11 math, the `$` spellings of Table 4-14/4-15.
    @"$sqrt",
    @"$exp",
    @"$expm1",
    @"$ln",
    @"$ln1p",
    @"$log",
    @"$log10",
    @"$floor",
    @"$ceil",
    @"$sin",
    @"$cos",
    @"$tan",
    @"$asin",
    @"$acos",
    @"$atan",
    @"$sinh",
    @"$cosh",
    @"$tanh",
    @"$asinh",
    @"$acosh",
    @"$atanh",
    @"$pow",
    @"$hypot",
    @"$atan2",
    // §9.4 display, §9.7 simulation control and severity.
    @"$display",
    @"$displayb",
    @"$displayo",
    @"$displayh",
    @"$write",
    @"$writeb",
    @"$writeo",
    @"$writeh",
    @"$strobe",
    @"$strobeb",
    @"$strobeo",
    @"$strobeh",
    @"$monitor",
    @"$monitoron",
    @"$monitoroff",
    @"$debug",
    @"$fatal",
    @"$error",
    @"$warning",
    @"$info",
    @"$finish",
    @"$stop",
    // §9.5 files.
    @"$fopen",
    @"$fclose",
    @"$fflush",
    @"$fdisplay",
    @"$fwrite",
    @"$fstrobe",
    @"$fmonitor",
    @"$fdebug",
    @"$fgets",
    @"$fscanf",
    @"$ftell",
    @"$fseek",
    @"$rewind",
    @"$ferror",
    @"$feof",
    // §9.5.3/§9.5.4.2 strings.
    @"$sformat",
    @"$sscanf",
    // §9.17 limiting and step control, §9.21 table model.
    @"$bound_step",
    @"$discontinuity",
    @"$limit",
    @"$table_model",
    // VerA-synthetic: lowering's rewrites of one source call into several.
    @"$held_int",
    @"$held_real",
    @"$limit$old",
    @"$limit$uf",
    @"$idx",
    @"$idx$int",
    @"$idx$str",
    @"$display$width",
    @"$monitor$arm",
    @"$fgets$str",
    @"$ferror$str",
    @"$fscanf$int",
    @"$fscanf$real",
    @"$fscanf$str",
    @"$sscanf$int",
    @"$sscanf$real",
    @"$sscanf$str",
    // §9.13 Table 9-10, as `Lower.lowerRandom` rewrites it: one kernel per
    // distribution, its `_next` seed write-back twin, and the seed latches.
    @"$rng$auto",
    @"$rng$check",
    @"$rng$rand",
    @"$rng$rand_next",
    @"$rng$i_uniform",
    @"$rng$i_uniform_next",
    @"$rng$uniform",
    @"$rng$uniform_next",
    @"$rng$normal",
    @"$rng$normal_next",
    @"$rng$exponential",
    @"$rng$exponential_next",
    @"$rng$poisson",
    @"$rng$poisson_next",
    @"$rng$chi_square",
    @"$rng$chi_square_next",
    @"$rng$t",
    @"$rng$t_next",
    @"$rng$erlang",
    @"$rng$erlang_next",
    /// Any other name: a user system function. The raw name is the call's.
    systf,

    /// The callee a source or synthetic spelling names; `.systf` for any
    /// name not listed above.
    pub fn fromName(name: []const u8) Callee {
        return by_name.get(name) orelse .systf;
    }
};

const by_name = std.StaticStringMap(Callee).initComptime(blk: {
    const fields = @typeInfo(Callee).@"enum".fields;
    var kvs: [fields.len - 1]struct { []const u8, Callee } = undefined;
    for (fields[0 .. fields.len - 1], &kvs) |f, *kv| kv.* = .{ f.name, @enumFromInt(f.value) };
    break :blk kvs;
});

/// A call's value type — the one fact `Lower.sysFuncTy` (lowering's side)
/// and `analysis.callTy` (codegen's side) used to keep in two lists that had
/// to agree. `analysis.VTy` is this type.
pub const Ty = enum(u8) { real, int, str };

pub const Info = struct {
    /// Everything not listed is real: §9.14/§9.15 and every §4.5 operator.
    ty: Ty = .real,
};

pub const table = std.EnumArray(Callee, Info).initDefault(.{}, .{
    .@"$param_given" = .{ .ty = .int },
    .@"$port_connected" = .{ .ty = .int },
    .@"$test$plusargs" = .{ .ty = .int },
    .@"$value$plusargs" = .{ .ty = .int },
    .@"$rtoi" = .{ .ty = .int },
    .@"$clog2" = .{ .ty = .int },
    // §9.11 Table 9-8: `$realtobits` yields the bit PATTERN (an integer),
    // `$bitstoreal` the real that pattern stands for — see
    // tests/fixtures/exhaustive/122_bit_conversions.va.
    .@"$realtobits" = .{ .ty = .int },
    .@"$analog_node_alias" = .{ .ty = .int },
    .@"$analog_port_alias" = .{ .ty = .int },
    .@"$sscanf" = .{ .ty = .int },
    .@"$sscanf$int" = .{ .ty = .int },
    .@"$display$width" = .{ .ty = .int },
    .@"$idx$int" = .{ .ty = .int },
    // §5.10 `Lower.holdSlot`'s synthetic seed: the callee is chosen by the
    // variable's declared type, so the name IS the type.
    .@"$held_int" = .{ .ty = .int },
    // §9.5: every descriptor function is integer-valued.
    .@"$fopen" = .{ .ty = .int },
    .@"$fgets" = .{ .ty = .int },
    .@"$fscanf" = .{ .ty = .int },
    .@"$fscanf$int" = .{ .ty = .int },
    .@"$ftell" = .{ .ty = .int },
    .@"$fseek" = .{ .ty = .int },
    .@"$rewind" = .{ .ty = .int },
    .@"$ferror" = .{ .ty = .int },
    .@"$feof" = .{ .ty = .int },
    .@"$simparam$str" = .{ .ty = .str },
    .@"$sformat" = .{ .ty = .str },
    .@"$sscanf$str" = .{ .ty = .str },
    .@"$idx$str" = .{ .ty = .str },
    .@"$fgets$str" = .{ .ty = .str },
    .@"$fscanf$str" = .{ .ty = .str },
    .@"$ferror$str" = .{ .ty = .str },
});

pub fn ty(c: Callee) Ty {
    return table.get(c).ty;
}

/// The §4.5 operator, §5.10.3 event or §9.17 task this callee is — the unit
/// `naming.enumerateUnits` gives it and the `Instance` state `op.table` says
/// it owns — or `.none`. Written out, so a new callee states whether it owns
/// state; `op.byName` is the same map over spellings, held equal below.
pub fn opKind(c: Callee) op.OpKind {
    return switch (c) {
        .ddt => .ddt,
        .idt => .idt,
        .idtmod => .idtmod,
        .absdelay => .absdelay,
        .transition => .transition,
        .slew => .slew,
        .last_crossing => .last_crossing,
        .cross => .cross,
        .above => .above,
        .timer => .timer,
        .@"$bound_step" => .bound_step,
        .@"$discontinuity" => .discontinuity,
        .laplace_zd, .laplace_zp, .laplace_nd, .laplace_np => .laplace,
        .zi_zd, .zi_zp, .zi_nd, .zi_np => .zi,
        // §4.5.13/§4.5.14 are pure (no state, no unit), and nothing else
        // here owns per-instance state or a monitored event.
        .limexp, .ddx, .initial_step, .final_step, .analog_initial, .analysis, .ac_stim,
        .white_noise, .flicker_noise, .noise_table, .noise_table_log, .@"$temperature", .@"$vt",
        .@"$mfactor", .@"$abstime", .@"$realtime", .@"$simparam", .@"$simparam$str",
        .@"$param_given", .@"$port_connected", .@"$analog_node_alias", .@"$analog_port_alias",
        .@"$test$plusargs", .@"$value$plusargs", .@"$xposition", .@"$yposition", .@"$angle",
        .@"$hflip", .@"$vflip", .@"$rtoi", .@"$itor", .@"$realtobits", .@"$bitstoreal", .@"$clog2",
        .@"$sqrt", .@"$exp", .@"$expm1", .@"$ln", .@"$ln1p", .@"$log", .@"$log10", .@"$floor",
        .@"$ceil", .@"$sin", .@"$cos", .@"$tan", .@"$asin", .@"$acos", .@"$atan", .@"$sinh",
        .@"$cosh", .@"$tanh", .@"$asinh", .@"$acosh", .@"$atanh", .@"$pow", .@"$hypot", .@"$atan2",
        .@"$display", .@"$displayb", .@"$displayo", .@"$displayh", .@"$write", .@"$writeb",
        .@"$writeo", .@"$writeh", .@"$strobe", .@"$strobeb", .@"$strobeo", .@"$strobeh",
        .@"$monitor", .@"$monitoron", .@"$monitoroff", .@"$debug", .@"$fatal", .@"$error",
        .@"$warning", .@"$info", .@"$finish", .@"$stop", .@"$fopen", .@"$fclose", .@"$fflush",
        .@"$fdisplay", .@"$fwrite", .@"$fstrobe", .@"$fmonitor", .@"$fdebug", .@"$fgets",
        .@"$fscanf", .@"$ftell", .@"$fseek", .@"$rewind", .@"$ferror", .@"$feof", .@"$sformat",
        .@"$sscanf", .@"$limit", .@"$table_model", .@"$held_int", .@"$held_real", .@"$limit$old",
        .@"$limit$uf", .@"$idx", .@"$idx$int", .@"$idx$str", .@"$display$width", .@"$monitor$arm",
        .@"$fgets$str", .@"$ferror$str", .@"$fscanf$int", .@"$fscanf$real", .@"$fscanf$str",
        .@"$sscanf$int", .@"$sscanf$real", .@"$sscanf$str", .@"$rng$auto", .@"$rng$check",
        .@"$rng$rand", .@"$rng$rand_next", .@"$rng$i_uniform", .@"$rng$i_uniform_next",
        .@"$rng$uniform", .@"$rng$uniform_next", .@"$rng$normal", .@"$rng$normal_next",
        .@"$rng$exponential", .@"$rng$exponential_next", .@"$rng$poisson", .@"$rng$poisson_next",
        .@"$rng$chi_square", .@"$rng$chi_square_next", .@"$rng$t", .@"$rng$t_next",
        .@"$rng$erlang", .@"$rng$erlang_next", .systf,
        => .none,
    };
}

test "a callee name round-trips; anything else is .systf" {
    for (std.meta.tags(Callee)) |c| {
        if (c == .systf) continue;
        try std.testing.expectEqual(c, Callee.fromName(@tagName(c)));
    }
    try std.testing.expectEqual(Callee.systf, Callee.fromName("$resistor"));
    try std.testing.expectEqual(Callee.systf, Callee.fromName("systf"));
    try std.testing.expectEqual(Ty.int, ty(.@"$held_int"));
    try std.testing.expectEqual(Ty.real, ty(.@"$held_real"));
    try std.testing.expectEqual(Ty.real, ty(.systf));
}

test "opKind is op.byName over every spelling" {
    for (std.meta.tags(Callee)) |c| {
        const want = if (c == .systf) op.OpKind.none else op.byName(@tagName(c));
        try std.testing.expectEqual(want, opKind(c));
    }
}
