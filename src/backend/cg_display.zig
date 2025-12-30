//! §9.4 display tasks — the printing half of the backend.
//!
//! Transformation: a void `call` to `$strobe`/`$display`/`$write`/`$monitor` or a
//! §9.7.3 severity task → a `std.debug.print` with §9.4.3 conversions translated
//! into Zig format specifiers.
//!
//! Free functions over `*Gen` rather than methods, because Zig cannot extend a
//! struct across files. Split out because this group is the most self-contained
//! in the emitter: it calls `renderVal`/`strArg` and nothing else in here, and
//! nothing in here calls back into it except the one `emitSysCall` dispatch.
//!
//! A display task is a STATEMENT in the source and a void `call` in the MIR, so
//! `Display == .drop` means nothing below ever runs — see `codegen.Display`.

const std = @import("std");
const Mir = @import("../ir/mir.zig");
const Analysis = @import("../ir/analysis.zig");
const Lower = @import("../ir/lower.zig");
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const VTy = Analysis.VTy;
const assert = std.debug.assert;

// -------------------------------------------------------- §9.4 display ----
//
// A display task is a STATEMENT in the source and a void `call` in the MIR,
// and codegen renders values, not statements. Rather than grow a statement
// path for the one construct that needs it, the call renders as a labeled
// block EXPRESSION whose value is the same `S.con(0.0)` the dropped form
// produces — the print is the side effect on the way there. It reaches the
// output because `Lower.finishDisplays` chained it into a live root; see
// `buildJobs`.

/// One rendered `std.debug.print` operand: the value and the Zig type the
/// chosen conversion needs it in. `%h` on a real is a real→integer
/// conversion (§4.2.1.1), not a reinterpretation, so `want` is not always
/// the value's own type.
pub const PrintArg = struct {
    v: Mir.Value,
    want: VTy,
    /// Render through `zPadInt` into a per-call stack buffer instead of
    /// directly. See `emitDisplayTask` for the one reason this exists.
    pad: bool = false,
};

/// Emit one §9.4.1/§9.7.3 task as `std.debug.print`.
///
/// Output goes to stderr, which is where `std.debug.print` writes and where a
/// simulator's transcript belongs — stdout is for a host that pipes data.
pub fn emitDisplayTask(g: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
    // §9.7.3 `$fatal(finish_number, "fmt", …)` puts a non-string first, and
    // §9.4.1 allows `$display` with no format at all. Both fall out of
    // "the format is the first string constant, if there is one".
    var fmt_at: ?usize = null;
    for (args, 0..) |_, i| {
        if (g.strArg(args, i) != null) {
            fmt_at = i;
            break;
        }
    }

    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    // §9.7.3: the severity is the message's whole reason for existing, and a
    // reader cannot recover it from the text.
    if (severityWord(name)) |word| {
        try fmt.appendSlice(g.arena, word);
        try fmt.appendSlice(g.arena, ": ");
    }
    if (fmt_at) |at| {
        try translateFormat(g, g.strArg(args, at).?, args[at + 1 ..], &fmt, &ops);
    } else {
        // §9.4.3 no format string: each operand in its natural default,
        // separated by a space — with §9.4.1's radix suffix applied.
        const conv: u8 = switch (name[name.len - 1]) {
            'b' => 'b',
            'o' => 'o',
            'h' => 'x',
            else => 0,
        };
        for (args, 0..) |a, i| {
            if (i != 0) try fmt.append(g.arena, ' ');
            try appendConv(g, &fmt, &ops, a, conv, "");
        }
    }
    // §9.4.1: `$write` is the family member that does NOT end the line.
    if (!std.mem.startsWith(u8, name, "$write")) try fmt.append(g.arena, '\n');

    // A width-padded integer is printed through `zPadInt` because Zig's
    // `{d:>5}` writes `+42` where §9.4.3 (and C, and every other Verilog
    // tool) writes ` 42` — std.fmt spells the sign explicitly once a width
    // makes the field fixed. Padding the DECIMAL TEXT instead reproduces the
    // documented behavior, and the scratch it needs is a stack array in the
    // same block as the print.
    try g.b("zd: {{ ", .{});
    for (ops.items, 0..) |p, i| {
        if (p.pad) try g.b("var zb{d}: [24]u8 = undefined; ", .{i});
    }
    try g.b("std.debug.print(\"{f}\", .{{", .{std.zig.fmtString(fmt.items)});
    for (ops.items, 0..) |p, i| {
        if (i != 0) try g.b(", ", .{});
        try renderPrintArg(g, p, i);
    }
    try g.b("}}); break :zd S.con(0.0); }}", .{});
}

/// §9.7.3 severity tasks. Null for the §9.4.1 display family.
pub fn severityWord(name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, name, "$fatal")) return "FATAL";
    if (eq(u8, name, "$error")) return "ERROR";
    if (eq(u8, name, "$warning")) return "WARNING";
    if (eq(u8, name, "$info")) return "INFO";
    return null;
}

/// §9.4.2/§9.4.3 format string → a Zig one, consuming an operand per
/// conversion. Literal text is copied through with `{`/`}` doubled, because
/// it is about to become a `std.fmt` template.
///
/// Unmatched operands (more arguments than conversions) are appended
/// space-separated in their default form, which is what §9.4.3 says the
/// display tasks do.
pub fn translateFormat(
    g: *Gen,
    src: []const u8,
    operands: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
) Error!void {
    const a = g.arena;
    var next: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '{' or c == '}') { // std.fmt's own escape
            try fmt.append(a, c);
            try fmt.append(a, c);
            i += 1;
            continue;
        }
        if (c != '%') {
            try fmt.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= src.len) break;
        if (src[i] == '%') { // §9.4.3 `%%` is a literal percent
            try fmt.append(a, '%');
            i += 1;
            continue;
        }
        // §9.4.3 `%[-0][width][.precision]conv` — the flags Verilog shares
        // with C. Zig's spec is `[fill][align][width][.precision]`, and its
        // fill/alignment are only meaningful WITH a width, so they are
        // emitted only when one was given.
        var spec: std.ArrayList(u8) = .empty;
        var left = false;
        var zero = false;
        while (i < src.len and (src[i] == '-' or src[i] == '+' or src[i] == ' ' or src[i] == '0')) : (i += 1) {
            if (src[i] == '-') left = true;
            if (src[i] == '0') zero = true;
        }
        const width_at = i;
        while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
        if (i > width_at) {
            if (zero) try spec.append(a, '0');
            try spec.append(a, if (left) '<' else '>');
            try spec.appendSlice(a, src[width_at..i]);
        }
        if (i < src.len and src[i] == '.') {
            try spec.append(a, '.');
            i += 1;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) try spec.append(a, src[i]);
        }
        if (i >= src.len) break;
        const conv = std.ascii.toLower(src[i]);
        i += 1;
        // §9.4.4 `%m` names the enclosing module and consumes no operand.
        if (conv == 'm') {
            try fmt.appendSlice(a, g.mir.name);
            continue;
        }
        const operand = if (next < operands.len) operands[next] else Mir.Value.f_zero;
        next += 1;
        try appendConv(g, fmt, ops, operand, conv, spec.items);
    }
    while (next < operands.len) : (next += 1) {
        try fmt.append(a, ' ');
        try appendConv(g, fmt, ops, operands[next], 0, "");
    }
}

/// One conversion: append its `{…}` to `fmt` and its operand to `ops`.
/// `conv == 0` means "the operand's natural form" (§9.4.3 default).
pub fn appendConv(
    g: *Gen,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
    v: Mir.Value,
    conv: u8,
    spec: []const u8,
) Error!void {
    const a = g.arena;
    const ty = g.an.tyOf(g.an.rv(v));
    // The Zig verb. `%f` is C's fixed-point default of six decimals; `%g`
    // and `%r` are shortest-round-trip, which is what `{d}` on a float is.
    // §9.4.3's engineering-notation `%r` scale suffix is NOT reproduced.
    const verb: []const u8 = switch (conv) {
        'b' => "b",
        'o' => "o",
        'h', 'x' => "x",
        'c' => "c",
        's' => "s",
        'e' => "e",
        'd', 'f', 'g', 'r', 't', 'u', 'z', 'l', 'v' => "d",
        else => if (ty == .str) "s" else "d",
    };
    // A float has no bit pattern to show in a radix conversion, and Zig's
    // `{x}` on an f64 is a hex FLOAT — not what `%h` asks for. Round it,
    // exactly like §4.2.1.1 does at any other real→integer boundary.
    const as_int = ty != .str and (std.mem.eql(u8, verb, "b") or
        std.mem.eql(u8, verb, "o") or std.mem.eql(u8, verb, "x") or
        std.mem.eql(u8, verb, "c") or conv == 'd');
    // A width (not a bare precision) is what makes std.fmt spell an
    // integer's sign; only then is the detour through `zPadInt` needed, and
    // only for the plain decimal conversion — a radix conversion has no
    // sign to spell.
    const pad = conv == 'd' and spec.len != 0 and spec[spec.len - 1] != '.' and
        std.mem.indexOfAny(u8, spec, "<>") != null;
    try fmt.append(a, '{');
    try fmt.appendSlice(a, if (pad) "s" else verb);
    // `%f`'s six decimals only apply when the source did not say otherwise.
    const default_prec = conv == 'f' and std.mem.indexOfScalar(u8, spec, '.') == null;
    if (spec.len > 0 or default_prec) {
        try fmt.append(a, ':');
        try fmt.appendSlice(a, spec);
        if (default_prec) try fmt.appendSlice(a, ".6");
    }
    try fmt.append(a, '}');
    try ops.append(a, .{ .v = v, .want = if (as_int) .int else ty, .pad = pad });
}

/// Render one operand of a `std.debug.print`. The `S` scalar is opaque, so a
/// real crosses into the format layer through `.val()`; an integer and a
/// string are already plain Zig values.
pub fn renderPrintArg(g: *Gen, p: PrintArg, i: usize) Error!void {
    if (p.pad) {
        try g.b("zPadInt(&zb{d}, ", .{i});
        try g.renderVal(p.v, .int);
        return g.b(")", .{});
    }
    switch (p.want) {
        .real => {
            try g.b("(", .{});
            try g.renderVal(p.v, .real);
            try g.b(").val()", .{});
        },
        .int => try g.renderVal(p.v, .int),
        .str => try g.renderVal(p.v, .str),
    }
}

