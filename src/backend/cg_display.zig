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
    /// §9.4.3 `%c`. Zig's `{c}` verb takes a `u8`, so the i64 the operand
    /// arrives as has to be narrowed at the call site or the generated
    /// device does not compile. Table 9-22 says "display as an ASCII
    /// character", which is the low byte — truncation, not a range error.
    chr: bool = false,
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

/// §9.5.3 `$swrite`/`$sformat` — "the same as their counterparts", §9.4.1's
/// writers, "except that ... the resulting string shall be written" to a string
/// variable. So the format translation is `emitDisplayTask`'s, verbatim: the
/// operands, the conversions, the pairing rule and the "no format string at all"
/// fallback are all the same clause. The only differences are the SINK
/// (`bufPrint` into this call site's scratch row instead of `std.debug.print`)
/// and the newline, which §9.4.1 gives to `$display` and not to the writers.
///
/// The value of the emitted block is the formatted slice, which lowering
/// assigns to the string variable the source named.
pub fn emitStringFormat(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
    var fmt_at: ?usize = null;
    for (args, 0..) |_, i| {
        if (g.strArg(args, i) != null) {
            fmt_at = i;
            break;
        }
    }
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    if (fmt_at) |at| {
        try translateFormat(g, g.strArg(args, at).?, args[at + 1 ..], &fmt, &ops);
    } else {
        for (args, 0..) |a, i| {
            if (i != 0) try fmt.append(g.arena, ' ');
            try appendConv(g, &fmt, &ops, a, 0, "");
        }
    }
    try g.b("zs: {{ ", .{});
    for (ops.items, 0..) |p, i| {
        if (p.pad) try g.b("var zb{d}: [24]u8 = undefined; ", .{i});
    }
    // An overrun formats to the empty string: §9.5.3 states no truncation rule,
    // and half a number is a worse answer than none. See `zSBuf`'s size note.
    try g.b("break :zs std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
    for (ops.items, 0..) |p, i| {
        if (i != 0) try g.b(", ", .{});
        try renderPrintArg(g, p, i);
    }
    try g.b("}}) catch \"\"; }}", .{});
}

// ------------------------------------------------------- §9.5 file I/O ----
//
// §9.5.2 defines its five output tasks as the §9.4.1 ones "with one additional
// argument, which is either a multichannel descriptor or a file descriptor", so
// the formatter is the same formatter and lives here rather than in a second
// copy. The rest of the family is a descriptor operation with no text at all,
// but it is emitted from the same place because it is sequenced in the same
// unit — see `codegen.Gen.emitting_display`.

/// One §9.5 call, in the display unit. `site` is the call's MIR instruction id,
/// which is the per-call-site key for the formatted bytes (`zSBuf`) exactly as
/// it is for `$sformat`.
pub fn emitFileCall(g: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    // §9.5.1/§9.5.2/§9.5.6: `$fclose`, `$fflush` and the five output tasks are
    // TASKS, so `analysis.callTy` leaves them real like every other void call —
    // but the kernels answer in bytes and channels, which are integers. The
    // conversion is here rather than in the type table because the value is
    // discarded either way: it exists only to give the display chain something to
    // carry (`Lower.sequenceFileCall`), and typing seven void tasks as integers to
    // avoid one cast would change what `$display`'s own chain carries too.
    const wrap = Analysis.callTy(name) == .real;
    if (wrap) try g.b("S.con(@as(f64, @floatFromInt(", .{});
    try emitFileCallInner(g, name, args, site);
    if (wrap) try g.b(")))", .{});
}

fn emitFileCallInner(g: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    const eq = std.mem.eql;
    if (isFileOut(name)) return emitFileWrite(g, name, args, site);
    // §9.5.1 Syntax 9-2: one argument is a multichannel descriptor, two are a
    // file descriptor. The presence of the type argument IS the discriminator,
    // and it is the only thing that decides which encoding comes back.
    if (eq(u8, name, "$fopen")) {
        try g.b("zFOpen(", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.f_zero, .str);
        try g.b(", ", .{});
        if (args.len > 1) try g.renderVal(args[1], .str) else try g.b("\"\"", .{});
        return g.b(", {s})", .{if (args.len > 1) "false" else "true"});
    }
    // The one-argument descriptor operations, in clause order.
    const one = [_]struct { n: []const u8, k: []const u8 }{
        .{ .n = "$fclose", .k = "zFClose" }, // §9.5.1
        .{ .n = "$fflush", .k = "zFFlush" }, // §9.5.6
        .{ .n = "$fgets", .k = "zFGets" }, // §9.5.4.1 — the character count
        .{ .n = "$ftell", .k = "zFTell" }, // §9.5.5
        .{ .n = "$feof", .k = "zFEof" }, // §9.5.8
        .{ .n = "$ferror", .k = "zFError" }, // §9.5.7 — the errno
    };
    for (one) |o| if (eq(u8, name, o.n)) {
        try g.b("{s}(", .{o.k});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(")", .{});
    };
    // §9.5.5 `$rewind(fd)` "is equivalent to $fseek (fd,0,0)" — the clause's own
    // words, so it is the same kernel with the constants written in.
    if (eq(u8, name, "$rewind")) {
        try g.b("zFSeek(", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(", 0, 0)", .{});
    }
    if (eq(u8, name, "$fseek")) {
        try g.b("zFSeek(", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 2) args[2] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // §9.5.4.2 the count: read one line and hand it to §9.5.3's scanner, which
    // `str_kernels.zScan` already is. `Lower.lowerFileRead` built the operands as
    // (fd, format).
    if (eq(u8, name, "$fscanf")) {
        try g.b("zScanN(zFRead(", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        try g.b("), ", .{});
        try g.renderVal(if (args.len > 1) args[1] else Mir.Value.f_zero, .str);
        return g.b(")", .{});
    }
    // The synthetic readers, all of which take the count first — see
    // `file_kernels.zFLine` for why that operand is there and why it is read.
    if (eq(u8, name, "$fgets$str")) return emitLine(g, args, "zFLine");
    if (eq(u8, name, "$ferror$str")) {
        try g.b("zFErrorStr(", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // §9.5.4.2's items: the same three flavours `$sscanf` has, over the line the
    // count's read latched. `(count, fd, format, item)`.
    const scan: ?[]const u8 = if (eq(u8, name, "$fscanf$int"))
        "zScanI"
    else if (eq(u8, name, "$fscanf$real"))
        "zScanR"
    else if (eq(u8, name, "$fscanf$str")) "zScanS" else null;
    if (scan) |k| {
        try g.b("{s}(", .{k});
        try emitLine(g, args, "zFLine");
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 2) args[2] else Mir.Value.f_zero, .str);
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 3) args[3] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    return g.abort("VerA: unhandled §9.5 call `{s}`", .{name});
}

/// `zFLine(count, fd)` — the latched line, over the first two operands every
/// synthetic reader carries.
fn emitLine(g: *Gen, args: []const Mir.Value, kernel: []const u8) Error!void {
    try g.b("{s}(", .{kernel});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
    try g.b(", ", .{});
    try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
    try g.b(")", .{});
}

/// §9.5.2's five output tasks. The descriptor is `args[0]`; everything after it
/// is the §9.4.1 task this one is named after, so the format translation, the
/// pairing rule, the "no format string" fallback and the newline rule are all
/// `emitDisplayTask`'s, applied to the BASE name — `$fwrite` is the one that does
/// not end the line, exactly as `$write` is.
fn emitFileWrite(g: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    const eq = std.mem.eql;
    // §9.5.1 `$fclose` and §9.5.6 `$fflush` take a descriptor and no text.
    if (eq(u8, name, "$fclose") or eq(u8, name, "$fflush")) {
        try g.b("{s}(", .{if (eq(u8, name, "$fclose")) "zFClose" else "zFFlush"});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // "$fdisplay" → "display", "$fwrite" → "write": the §9.4.1 task §9.5.2 names
    // this one after, with both the `$` and the `f` gone. The two things it is
    // read for are §9.4.1's newline rule (`$write` is the member that does not end
    // the line, and so is `$fwrite`) and §9.4.1's radix suffix.
    const base = name[2..];
    const rest = if (args.len > 0) args[1..] else args;
    var fmt_at: ?usize = null;
    for (rest, 0..) |_, i| {
        if (g.strArg(rest, i) != null) {
            fmt_at = i;
            break;
        }
    }
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    if (fmt_at) |at| {
        try translateFormat(g, g.strArg(rest, at).?, rest[at + 1 ..], &fmt, &ops);
    } else {
        const conv: u8 = switch (base[base.len - 1]) {
            'b' => 'b',
            'o' => 'o',
            'h' => 'x',
            else => 0,
        };
        for (rest, 0..) |a, i| {
            if (i != 0) try fmt.append(g.arena, ' ');
            try appendConv(g, &fmt, &ops, a, conv, "");
        }
    }
    if (!std.mem.startsWith(u8, base, "write")) try fmt.append(g.arena, '\n');

    // The text is formatted into this call site's own scratch row and then
    // written, which is `emitStringFormat`'s sink with a descriptor instead of a
    // string variable. An overrun writes nothing rather than half a line: §9.5.2
    // states no truncation rule, same as §9.5.3.
    try g.b("zf: {{ ", .{});
    for (ops.items, 0..) |p, i| {
        if (p.pad) try g.b("var zb{d}: [24]u8 = undefined; ", .{i});
    }
    try g.b("break :zf zFPut(", .{});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
    try g.b(", std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
    for (ops.items, 0..) |p, i| {
        if (i != 0) try g.b(", ", .{});
        try renderPrintArg(g, p, i);
    }
    try g.b("}}) catch \"\"); }}", .{});
}

fn isFileOut(name: []const u8) bool {
    return Lower.isFileOutTask(name);
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
        // §9.4.3 `%m` names the enclosing module. `%l` is the SAME class —
        // "for each % character (except %m, %% and %l) … a corresponding
        // expression argument shall be supplied" — so it must not consume one
        // either; `lower.checkFormatPairing` counts it that way, and a `%l`
        // that ate an operand here slid every later conversion by one.
        //
        // Table 9-22 wants "library.cell". VerA compiles a source file, not a
        // library-mapped design — there is no §13-of-1364 library map to bind
        // against and no CLI surface that could supply one — so the library
        // component is empty and the cell is the module, which is the same
        // text `%m` gives.
        if (conv == 'm' or conv == 'l') {
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
        'd', 'f', 'g', 'r', 't', 'u', 'z', 'v' => "d",
        else => if (ty == .str) "s" else "d",
    };
    // A float has no bit pattern to show in a radix conversion, and Zig's
    // `{x}` on an f64 is a hex FLOAT — not what `%h` asks for. Round it,
    // exactly like §4.2.1.1 does at any other real→integer boundary.
    // §2.7 makes a string literal an unsigned base-256 integer wherever it is
    // used as an operand, and an EXPLICIT numeric conversion is such a use:
    // `$strobe("%d", "\n")` prints 10. `%s` and the default conversion (`conv
    // == 0`) still print the text — that is what §9.4.3 asks of them and what
    // every `CHECK` macro's `%s` name depends on. `renderVal` does the digits.
    const str_as_int = ty == .str and switch (conv) {
        'd', 'b', 'o', 'h', 'x' => true,
        else => false,
    };
    const as_int = str_as_int or (ty != .str and (std.mem.eql(u8, verb, "b") or
        std.mem.eql(u8, verb, "o") or std.mem.eql(u8, verb, "x") or
        std.mem.eql(u8, verb, "c") or conv == 'd'));
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
    try ops.append(a, .{ .v = v, .want = if (as_int) .int else ty, .pad = pad, .chr = conv == 'c' and ty != .str });
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
        .int => if (p.chr) {
            try g.b("@as(u8, @truncate(@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))))", .{});
        } else try g.renderVal(p.v, .int),
        .str => try g.renderVal(p.v, .str),
    }
}

