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
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const VTy = Analysis.VTy;

// -------------------------------------------------------- §9.4 display ----
//
// A display task is a STATEMENT in the source and a void `call` in the MIR,
// and codegen renders values, not statements. Rather than grow a statement
// path for the one construct that needs it, the call renders as a labeled
// block EXPRESSION whose value is the same `S.con(0.0)` the dropped form
// produces — the print is the side effect on the way there. It reaches the
// output because `Lower.finishDisplays` chained it into a live root; see
// `buildJobs`.

/// Parsed §9.4.3 conversion prefix: `%[flags][width][.precision]conv`. Table
/// 9-23 grants the real conversions "the full formatting capabilities
/// available in the C language", so C (C11 7.21.6.1) is the reference for what
/// each flag means; the integer conversions get the same prefix grammar.
/// Width and precision are numbers rather than spec text because the C-int and
/// C-exponential renderings need them as arithmetic, not as passthrough.
pub const Spec = struct {
    left: bool = false, // '-' left-justify; C makes it override '0'
    plus: bool = false, // '+' always spell the sign
    space: bool = false, // ' ' a space where the sign would be; '+' wins
    zero: bool = false, // '0' pad with zeros AFTER the sign
    width: usize = 0, // 0 = no width given
    prec: ?usize = null, // null = no precision given

    // ponytail: the scratch for a composed field is a stack array in the
    // emitted block, so `%99999999d` would otherwise emit a 100 MB frame.
    // 4096 matches `str_kernels.zSBuf`'s row and `file_kernels.ZFSlot.line`,
    // so a record this formatter composes is one a §9.5.2 write can emit and a
    // §9.5.4.1 `$fgets` can read back whole; a wider request is clamped, not
    // honored. Upgrade path: spill to zSBuf if a real model ever wants more.
    const max_field = 4096;
    fn w(self: Spec) usize {
        return @min(self.width, max_field);
    }
    fn p(self: Spec, default: usize) usize {
        return @min(self.prec orelse default, max_field);
    }
};

/// One rendered `std.debug.print` operand: the value, the Zig type the chosen
/// conversion needs it in, and HOW it is rendered. `%h` on a real is a
/// real→integer conversion (§4.2.1.1), not a reinterpretation, so `want` is
/// not always the value's own type.
pub const PrintArg = struct {
    v: Mir.Value,
    want: VTy,
    how: Mode = .plain,
    spec: Spec = .{},
    /// `.creal`: the source's own conversion letter. Its CASE is data —
    /// `%E`/`%G` print the exponent marker and INF/NAN the way they were
    /// written — so the raw byte travels rather than a normalized one.
    conv: u8 = 0,
    /// Original integer width, before SSA and the i64 storage carrier.
    bits: u7 = 64,

    pub const Mode = enum {
        /// Straight through the Zig verb the conversion mapped to.
        plain,
        /// §9.4.3 `%c`. Zig's `{c}` verb takes a `u8`, so the i64 the operand
        /// arrives as has to be narrowed at the call site or the generated
        /// device does not compile. Table 9-22 says "display as an ASCII
        /// character", which is the low byte — truncation, not a range error.
        chr,
        /// `%<width>d` with no sign/zero flag: render the decimal TEXT through
        /// `zPadInt` and pad it as a string. See `emitDisplayTask` for why.
        pad,
        /// `%+d` / `% d` / `%0<width>d`: C puts the sign INSIDE the field —
        /// `+42`, ` 42`, `-0042` — which no Zig format spec can spell, so the
        /// field text is composed in per-op scratch and printed as `{s}`.
        cint,
        /// §9.4.3 Table 9-23's real conversions — `%e`, `%f`, `%g` and the
        /// engineering `%r` — through `str_kernels.zCReal`, which is C11
        /// 7.21.6.1 (flags, width, precision, correct round-half-to-EVEN)
        /// where Zig's float verbs are shortest-round-trip and round half
        /// away from zero. The kernel composes the WHOLE field, sign and
        /// padding included, because C's '0' flag puts the pad between the
        /// sign and the digits and no Zig format spec can spell that.
        creal,
        /// `%h`/`%o`/`%b`: the two's-complement bit pattern of the operand.
        /// Zig's radix verbs on an i64 print `-2a` instead, hence a u64
        /// bitcast around the rendered integer.
        bits,
        /// §9.4.5: most-significant byte first, with leading zero bytes removed.
        ascii,
    };

    /// Bytes of per-op scratch the emitted block declares, or null for the
    /// modes that render straight into the print's argument tuple.
    fn scratch(self: PrintArg) ?usize {
        return switch (self.how) {
            .ascii => @sizeOf(i64),
            .pad => 24, // i64's widest decimal (20 chars) plus slack
            .cint => @max(24, self.spec.w() + 2), // the full zero-filled field
            // The widest `%f` body is a sign, f64's 309 integer digits, the
            // point and the precision; the field can be wider still.
            .creal => @max(self.spec.w(), self.spec.p(6) + 320) + 8,
            else => null,
        };
    }
};

/// §9.4.1's argument-list model, shared by every sink (`$strobe` and family,
/// §9.5.2 file writers, §9.5.3 string writers): "$strobe displays its
/// arguments in the same order they appear in the argument list. Each argument
/// can be a quoted string, an expression which returns a value, or a null
/// argument." EVERY string argument is a format whose conversions consume the
/// expression arguments after it; an expression argument no format run
/// consumed prints in the default format (§9.4.3 "any expression argument with
/// no corresponding format specification is displayed using the default
/// decimal format"); and nothing inserts separators — §9.4.1's own way to
/// write a space between fields is a null argument.
///
/// Two documented deviations from the 1364-2005 §17.1.1.2 heritage:
///   - a bare INTEGER prints minimal-width (1364 auto-sizes the default %d
///     field to the operand's largest value, 20 columns for VerA's 64-bit
///     integers — nobody wants that in a transcript);
///   - a bare REAL prints shortest-round-trip decimal, VerA's documented `%g`
///     rendering (see `appendConv`), where 1364 gives reals `%g` proper.
fn buildArgs(
    g: *Gen,
    args: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
) Error!void {
    var i: usize = 0;
    while (i < args.len) {
        if (g.strArg(args, i)) |s| {
            i += 1;
            i += try translateFormat(g, s, args[i..], fmt, ops);
        } else {
            try appendConv(g, fmt, ops, args[i], 0, .{});
            i += 1;
        }
    }
}

/// The per-op scratch declarations of one emitted display block.
fn emitScratch(g: *Gen, ops: []const PrintArg) Error!void {
    for (ops, 0..) |p, i| {
        if (p.scratch()) |n| try g.b("var zb{d}: [{d}]u8 = undefined; ", .{ i, n });
    }
}

fn renderPrintArgs(g: *Gen, ops: []const PrintArg) Error!void {
    for (ops, 0..) |p, i| {
        if (i != 0) try g.b(", ", .{});
        try renderPrintArg(g, p, i);
    }
}

/// Emit one §9.4.1/§9.7.3 task as `std.debug.print`.
///
/// Output goes to stderr, which is where `std.debug.print` writes and where a
/// simulator's transcript belongs — stdout is for a host that pipes data.
pub fn emitDisplayTask(g: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    // §9.7.3: the severity is the message's whole reason for existing, and a
    // reader cannot recover it from the text.
    if (severityWord(name)) |word| {
        try fmt.appendSlice(g.arena, word);
        try fmt.appendSlice(g.arena, ": ");
    }
    // §9.7.3 Syntax 9-7: `$fatal ( finish_number [, message_argument … ] )`.
    // The finish_number sets the $finish diagnostic level; it is not part of
    // the message, so it must not print. Dropped only when it is not a string,
    // so a (nonconforming but unambiguous) `$fatal("bye")` keeps its text.
    // §9.4.1 a monitor report carries its site key first (`Lower.armMonitor`).
    const mon = isMonitor(name);
    const body = if (mon or (std.mem.eql(u8, name, "$fatal") and args.len > 0 and g.strArg(args, 0) == null))
        args[1..]
    else
        args;
    try buildArgs(g, body, &fmt, &ops);
    // §9.4.1: `$write` is the family member that does NOT end the line.
    if (!std.mem.startsWith(u8, name, "$write")) try fmt.append(g.arena, '\n');

    // A width-padded integer is printed through `zPadInt` because Zig's
    // `{d:>5}` writes `+42` where §9.4.3 (and C, and every other Verilog
    // tool) writes ` 42` — std.fmt spells the sign explicitly once a width
    // makes the field fixed. Padding the DECIMAL TEXT instead reproduces the
    // documented behavior, and the scratch it needs is a stack array in the
    // same block as the print.
    try g.b("zd: {{ ", .{});
    try emitScratch(g, ops.items);
    if (mon) {
        // §9.4.1's mechanism: format into this site's scratch row, then report
        // only when a watched argument VALUE differs from the step this site
        // last reported (`monitorValues`). An overrun formats to the empty
        // string, `emitStringFormat`'s rule.
        try g.b("if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
        try renderPrintArgs(g, ops.items);
        try g.b("}}) catch \"\")) |zt| std.debug.print(\"{{s}}\", .{{zt}}); ", .{});
    } else {
        try g.b("std.debug.print(\"{f}\", .{{", .{std.zig.fmtString(fmt.items)});
        try renderPrintArgs(g, ops.items);
        try g.b("}}); ", .{});
    }
    // §9.7.3: `$fatal` "terminates the simulation with an errorcode" and makes
    // "an implicit call to $finish" — it is the one member of the family whose
    // print is followed by the END OF THE RUN, "without checking whether the
    // iteration would be rejected". The finish_number is Syntax 9-7's literal
    // 0|1|2 and "may be used in an implementation-specific manner"; here it is
    // the process exit status, floored at 1 so a `$fatal` can never exit 0 and
    // read as success to a shell (`vera --run` forwards the status verbatim).
    // `zHalt` is f64-typed so the statements after it — §9.7's legal dead code
    // — still compile; `break :zd` is statically reachable, never taken.
    if (std.mem.eql(u8, name, "$fatal")) {
        const lvl = finishLevel(g, args);
        try g.b("_ = zHalt({d}); ", .{std.math.clamp(lvl, 1, 255)});
    }
    try g.b("break :zd S.con(0.0); }}", .{});
}

/// §9.7.1's diagnostic argument, folded. Syntax 9-5/9-7 make it the literal
/// 0 | 1 | 2, so a fold is the grammar and not an optimisation; anything that
/// does not fold takes 1 — §9.7.1: "One (1) is the default if no argument
/// is supplied."
fn finishLevel(g: *Gen, args: []const Mir.Value) i64 {
    if (args.len == 0) return 1;
    return switch (g.mir.valueDef(g.an.rv(args[0]))) {
        .int_const => |x| x,
        .float_const => |x| std.math.lossyCast(i64, x),
        else => 1,
    };
}

/// §9.7.1 `$finish` / §9.7.2 `$stop` in the printing artifact: the simulation
/// ends HERE, at the call's position among the prints — everything the model
/// said before it is already on stderr, and nothing after it runs.
///
/// Table 9-25 decides the diagnostic: 0 prints nothing, 1 prints "simulation
/// time and location", 2 adds memory/CPU statistics. Level >= 1 prints the
/// accepted time and the module; level 2 prints the same line — ponytail: a
/// testbench artifact keeps no CPU/memory bookkeeping to report, so 2 is 1
/// until a host that measures asks. (§9.7.1's dc-sweep-variable and
/// analog-initial variants of the time field are likewise not distinguished:
/// the artifact reports `inst.abstime`, which is the time the runner set.)
///
/// `$finish` exits 0 — ending the run is its defined behaviour, not a failure
/// (§9.7.1 "the simulator shall exit after the current solution is complete";
/// the display phase runs on the accepted solution, so this IS that point).
/// `$stop` suspends "at a converged time point" and the LRM leaves resumption
/// to the implementation (§9.7.2); ponytail: a batch artifact has no
/// interactive kernel to suspend into, so its implementation of suspension is
/// to print the diagnostic and exit 0 — the upgrade path is a debugger hook in
/// the runner, when something interactive exists to resume from.
pub fn emitSimCtl(g: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
    const level = finishLevel(g, args);
    try g.b("zd: {{ ", .{});
    if (level >= 1) {
        g.uses_inst = true;
        try g.b("std.debug.print(\"{s}: t={{d}} ({f})\\n\", .{{inst.abstime}}); ", .{
            name, std.zig.fmtString(g.mir.name),
        });
    }
    try g.b("_ = zHalt(0); break :zd S.con(0.0); }}", .{});
}

/// §9.5.3 `$swrite`/`$sformat` — "the same as their counterparts", §9.4.1's
/// writers, "except that ... the resulting string shall be written" to a string
/// variable. So the format translation is `emitDisplayTask`'s, verbatim: the
/// operands, the conversions and the argument-list model are all the same
/// clause. The only differences are the SINK (`bufPrint` into this call site's
/// scratch row instead of `std.debug.print`) and the newline, which §9.4.1
/// gives to `$display` and not to the writers.
///
/// The value of the emitted block is the formatted slice, which lowering
/// assigns to the string variable the source named. §3.3 removes NUL bytes
/// only AFTER formatting, so field widths still count the original bytes.
pub fn emitStringFormat(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    try buildArgs(g, args, &fmt, &ops);
    try g.b("zs: {{ ", .{});
    try emitScratch(g, ops.items);
    // An overrun formats to the empty string: §9.5.3 states no truncation rule,
    // and half a number is a worse answer than none. See `zSBuf`'s size note.
    try g.b("break :zs zStringStore(std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
    try renderPrintArgs(g, ops.items);
    try g.b("}}) catch \"\"); }}", .{});
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
    // `$fscanf$real` is the one real-typed §9.5 call whose KERNEL is already
    // f64 — §9.5.4.2 names `real` among the destinations a scan may write, and
    // `zScanR` answers one. Wrapping it in `@floatFromInt` like the integer
    // kernels made the generated device refuse to compile ("expected integer
    // type, found 'f64'"), which is why a real destination never worked.
    const from_int = !std.mem.eql(u8, name, "$fscanf$real");
    // An integer result is latched for the other units — `file_kernels.zFRes`.
    const keep = Analysis.callTy(name) == .int;
    if (wrap) try g.b("S.con(", .{});
    if (wrap and from_int) try g.b("@as(f64, @floatFromInt(", .{});
    if (keep) try g.b("zFKeep({d}, ", .{site});
    try emitFileCallInner(g, name, args, site);
    if (keep) try g.b(")", .{});
    if (wrap and from_int) try g.b("))", .{});
    if (wrap) try g.b(")", .{});
}

fn emitFileCallInner(g: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    const eq = std.mem.eql;
    // ponytail: lowering owns the file-task list, including fclose/fflush.
    if (Lower.isFileOutTask(name)) return emitFileWrite(g, name, args, site);
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
    // §9.5.4.2 the count. The two kernels are composed HERE rather than in
    // `file_kernels.zig`, which cannot call `str_kernels.zScan`: each kernel
    // file has to compile on its own for `kernels.zig`'s test root. Scan the
    // unread window, then consume exactly what the directives matched —
    // `zScan.used`, which is the clause's "the offending input character is
    // left unread" made into a number. `Lower.lowerFileRead` built the
    // operands as (fd, format); the ITEM readers below re-scan the same
    // window, which `zFTake` deliberately leaves latched.
    if (eq(u8, name, "$fscanf")) {
        const fd = if (args.len > 0) args[0] else Mir.Value.zero;
        try g.b("zk{d}: {{ const zw = zFWindow(", .{site});
        try g.renderVal(fd, .int);
        try g.b("); const zr = zScan(zw, ", .{});
        try g.renderVal(if (args.len > 1) args[1] else Mir.Value.f_zero, .str);
        try g.b(", -1); break :zk{d} zFTake(", .{site});
        try g.renderVal(fd, .int);
        return g.b(", zr.n, @intCast(zr.used)); }}", .{});
    }
    // The synthetic readers, all of which take the count first — see
    // `file_kernels.zFLine` for why that operand is there and why it is read.
    if (eq(u8, name, "$fgets$str")) return emitLine(g, args, "zFLine");
    if (eq(u8, name, "$ferror$str")) return emitLine(g, args, "zFErrorStr");
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

/// The first two operands every synthetic reader carries: count, then fd.
inline fn emitLine(g: *Gen, args: []const Mir.Value, comptime kernel: []const u8) Error!void {
    try g.b(kernel ++ "(", .{});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
    try g.b(", ", .{});
    try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
    try g.b(")", .{});
}

/// §9.5.2's five output tasks. The descriptor is `args[0]`; everything after it
/// is the §9.4.1 task this one is named after, so the format translation, the
/// argument-list model and the newline rule are all `emitDisplayTask`'s,
/// applied to the BASE name — `$fwrite` is the one that does not end the line,
/// exactly as `$write` is. No radix-suffixed file spelling exists (§9.5.2
/// Syntax 9-3 lists five names), so the default conversion is always the
/// operand's own.
fn emitFileWrite(g: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    const eq = std.mem.eql;
    // §9.5.1 `$fclose` and §9.5.6 `$fflush` take a descriptor and no text.
    if (eq(u8, name, "$fclose") or eq(u8, name, "$fflush")) {
        try g.b("{s}(", .{if (eq(u8, name, "$fclose")) "zFClose" else "zFFlush"});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // "$fdisplay" → "display", "$fwrite" → "write": the §9.4.1 task §9.5.2 names
    // this one after, with both the `$` and the `f` gone — read for §9.4.1's
    // newline rule (`$write` is the member that does not end the line, and so
    // is `$fwrite`).
    const base = name[2..];
    // §9.4.1 a monitor report carries its site key ahead of the descriptor.
    const mon = isMonitor(name);
    const all = if (mon) args[1..] else args;
    const rest = if (all.len > 0) all[1..] else all;
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    try buildArgs(g, rest, &fmt, &ops);
    if (!std.mem.startsWith(u8, base, "write")) try fmt.append(g.arena, '\n');

    // The text is formatted into this call site's own scratch row and then
    // written, which is `emitStringFormat`'s sink with a descriptor instead of a
    // string variable. An overrun writes nothing rather than half a line: §9.5.2
    // states no truncation rule, same as §9.5.3.
    try g.b("zf: {{ ", .{});
    try emitScratch(g, ops.items);
    // §9.5.2 makes `$fmonitor` "just like" `$monitor` with a descriptor in
    // front, so §9.4.1's change condition travels with it: the record is
    // composed either way, and `zMonitor` decides whether it is written.
    if (mon) try g.b("const zt = ", .{}) else try g.b("break :zf zFPut(", .{});
    if (!mon) {
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", ", .{});
    }
    try g.b("std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
    try renderPrintArgs(g, ops.items);
    try g.b("}}) catch \"\"", .{});
    if (mon) {
        try g.b("; break :zf if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", zt)) |zm| zFPut(", .{});
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", zm) else 0; }}", .{});
    } else try g.b("); }}", .{});
}

/// §9.4.1 what a monitor watches: one u64 per argument — a real's or an
/// integer's bit pattern, a string's hash — for `zMonitor` to compare against
/// the last reported step. `$abstime` and `$realtime` are left out: "with the
/// exception of the $abstime or $realtime system functions", a change in one
/// of them alone is not a change.
fn monitorValues(g: *Gen, ops: []const PrintArg) Error!void {
    try g.b("&[_]u64{{", .{});
    var first = true;
    for (ops) |p| {
        const v = g.an.rv(p.v);
        const def = g.mir.valueDef(v);
        if (def == .inst_result and g.mir.instOp(def.inst_result) == .call) {
            const callee = g.mir.instData(def.inst_result).call.name;
            if (std.mem.eql(u8, callee, "$abstime") or std.mem.eql(u8, callee, "$realtime")) continue;
        }
        if (first) try g.b(" ", .{}) else try g.b(", ", .{});
        first = false;
        switch (g.an.tyOf(v)) {
            .real => {
                try g.b("@as(u64, @bitCast((", .{});
                try g.renderVal(v, .real);
                try g.b(").val()))", .{});
            },
            .int => {
                try g.b("@as(u64, @bitCast(@as(i64, ", .{});
                try g.renderVal(v, .int);
                try g.b(")))", .{});
            },
            .str => {
                try g.b("std.hash.Wyhash.hash(0, ", .{});
                try g.renderVal(v, .str);
                try g.b(")", .{});
            },
        }
    }
    if (first) try g.b("}}", .{}) else try g.b(" }}", .{});
}

/// §9.4.1 `$monitor` and its §9.5.2 file twin — the two members of the family
/// that report only on a CHANGE. Every other member prints unconditionally.
const isMonitor = Lower.isMonitor;

/// The site key `Lower.armMonitor` put first in a monitor's registration and in
/// its report — a literal, so it can key a comptime latch.
fn monitorKey(g: *const Gen, args: []const Mir.Value) i64 {
    return g.mir.valueDef(g.an.rv(args[0])).int_const;
}

/// §9.4.1 the registration half: latch site `k` on (`str_kernels.zMonitorArm`).
pub fn emitMonitorArm(g: *Gen, args: []const Mir.Value) Error!void {
    return g.b("S.con(zMonitorArm({d}))", .{monitorKey(g, args)});
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

/// §9.4.2/§9.4.3 one format string → Zig format text, consuming an operand per
/// conversion. Literal text is copied through with `{`/`}` doubled, because it
/// is about to become a `std.fmt` template.
///
/// Returns how many of `operands` the string's conversions consumed, so the
/// caller (`buildArgs`) can resume the §9.4.1 argument walk right after them —
/// a LATER string argument starts the next format run; it is not this one's
/// operand. A conversion left with no operand at all renders a 0.0 (§9.4.3
/// makes that a pairing violation, which `Lower.checkFormatPairing` diagnoses).
pub fn translateFormat(
    g: *Gen,
    src: []const u8,
    operands: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
) Error!usize {
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
        // §9.4.3 `%[flags][width][.precision]conv` — the C prefix Table 9-23
        // grants. Parsed into numbers here; `appendConv` decides per
        // conversion whether Zig can spell it or a composed field is needed.
        var spec: Spec = .{};
        while (i < src.len) : (i += 1) switch (src[i]) {
            '-' => spec.left = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '0' => spec.zero = true,
            else => break,
        };
        const width_at = i;
        while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
        if (i > width_at)
            spec.width = std.fmt.parseUnsigned(usize, src[width_at..i], 10) catch Spec.max_field;
        if (i < src.len and src[i] == '.') {
            i += 1;
            const prec_at = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            spec.prec = std.fmt.parseUnsigned(usize, src[prec_at..i], 10) catch 0;
        }
        if (i >= src.len) break;
        const conv = src[i];
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
        if (conv == 'm' or conv == 'M' or conv == 'l' or conv == 'L') {
            try fmt.appendSlice(a, g.mir.name);
            continue;
        }
        const operand = if (next < operands.len) operands[next] else Mir.Value.f_zero;
        next += 1;
        try appendConv(g, fmt, ops, operand, conv, spec);
    }
    return @min(next, operands.len);
}

/// The Zig `:[fill][align][width][.precision]` tail, for the conversions whose
/// C and Zig renderings agree (radix on an unsigned, `%f`, `%g`, `%s`, `%c`).
/// Emits nothing when the source gave nothing. `extra_prec` is `%f`'s C
/// default of six decimals, applied only when the source did not say
/// otherwise.
fn appendZigSpec(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, extra_prec: ?[]const u8) Error!void {
    const a = g.arena;
    if (spec.width == 0 and spec.prec == null and extra_prec == null) return;
    var buf: [48]u8 = undefined;
    try fmt.append(a, ':');
    if (spec.width > 0) {
        // Zig's fill/alignment are only meaningful WITH a width.
        if (spec.zero) try fmt.append(a, '0');
        try fmt.append(a, if (spec.left) '<' else '>');
        try fmt.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{spec.width}) catch unreachable);
    }
    if (spec.prec) |p| {
        try fmt.appendSlice(a, std.fmt.bufPrint(&buf, ".{d}", .{p}) catch unreachable);
    } else if (extra_prec) |p| {
        try fmt.appendSlice(a, p);
    }
}

/// `{s}` with the OUTER alignment, for a conversion whose field text is
/// composed in per-op scratch (.cint, .cexp). `full` marks a field that is
/// already exactly its width (a zero-filled integer), which no outer
/// alignment may touch.
fn appendStrField(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, full: bool) Error!void {
    const a = g.arena;
    if (full or spec.width == 0) return fmt.appendSlice(a, "{s}");
    var buf: [48]u8 = undefined;
    try fmt.appendSlice(a, std.fmt.bufPrint(&buf, "{{s:{c}{d}}}", .{
        @as(u8, if (spec.left) '<' else '>'), spec.width,
    }) catch unreachable);
}

/// One conversion: append its `{…}` to `fmt` and its operand to `ops`.
/// `conv == 0` means "the operand's natural form" (§9.4.3 default).
pub fn appendConv(
    g: *Gen,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
    operand: Mir.Value,
    conv_raw: u8,
    spec: Spec,
) Error!void {
    const a = g.arena;
    const v = operand;
    var bits: u7 = 64;
    if (g.mir.valueDef(g.an.rv(v)) == .inst_result) {
        const inst = g.mir.valueDef(g.an.rv(v)).inst_result;
        const data = g.mir.instData(inst);
        if (data == .call and std.mem.eql(u8, data.call.name, "$display$width")) {
            bits = @intCast(g.mir.valueDef(data.call.args[1]).int_const);
        }
    }
    const conv = std.ascii.toLower(conv_raw);
    const ty = g.an.tyOf(g.an.rv(v));
    switch (conv) {
        // §9.4.3 Table 9-23's four real conversions. They "have the full
        // formatting capabilities available in the C language", which is
        // C11 7.21.6.1 and not Zig's float verbs — and `%r`/`%R` is the one
        // row C does not have, §2.6.2's engineering notation. One kernel
        // answers all four; it composes the whole field, so there is no outer
        // alignment to apply. An integer operand converts to real first —
        // Table 9-23 is "for real numbers", and §4.2.1.1 defines the step.
        'e', 'f', 'g', 'r' => {
            try fmt.appendSlice(a, "{s}");
            try ops.append(a, .{ .v = v, .want = .real, .how = .creal, .spec = spec, .conv = conv_raw });
        },
        // §9.4.3 Table 9-22: a radix conversion shows the two's-complement bit
        // pattern of the operand — 1364-2005 §17.1.1.2 sizes the display to
        // the operand's width: 32 for an `integer` (§3.2), which lowering
        // records through `$display$width`, and the 64-bit carrier for an
        // unsized literal (§2.6.1 "at least 32"; see codegen's "an integer
        // literal keeps all 64 bits") — so `%h` of an integer -5 is fffffffb
        // and of the literal -42 is ffffffffffffffd6. Zig's `{x}` on an i64 writes `-2a` instead,
        // hence the u64 bitcast of `.bits`. A float has no bit pattern to show
        // and Zig's `{x}` on an f64 is a hex FLOAT — not what `%h` asks for —
        // so a real rounds first, exactly like §4.2.1.1 does at any other
        // real→integer boundary. Zero-filling an unsigned field has no sign to
        // misplace, so the width/zero spec passes straight through.
        'b', 'o', 'h', 'x' => {
            try fmt.append(a, '{');
            try fmt.append(a, if (conv == 'h') 'x' else conv);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .v = v, .want = .int, .how = .bits, .spec = spec, .bits = bits });
        },
        // §9.4.5 "%s is used to print ASCII codes as characters" and Table
        // 9-22 gives %c the single character: the operand's low byte, whatever
        // type it arrived as — a string operand goes through its §2.7 integer
        // value like the radix conversions above.
        'c' => {
            try fmt.appendSlice(a, "{c");
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .v = v, .want = .int, .how = .chr, .spec = spec });
        },
        's' => {
            if (ty == .int) {
                try appendStrField(g, fmt, spec, false);
            } else {
                try fmt.appendSlice(a, "{s");
                try appendZigSpec(g, fmt, spec, null);
                try fmt.append(a, '}');
            }
            try ops.append(a, .{ .v = v, .want = ty, .how = if (ty == .int) .ascii else .plain, .spec = spec, .bits = bits });
        },
        'd' => {
            // §2.7 makes a string literal an unsigned base-256 integer
            // wherever it is used as an operand, and an EXPLICIT numeric
            // conversion is such a use: `$strobe("%d", "\n")` prints 10.
            // `renderVal(.int)` does the digits, for `%d` and the radix arm
            // above alike.
            const zero_fill = spec.zero and !spec.left and spec.width > 0;
            if (spec.plus or spec.space or zero_fill) {
                // C 7.21.6.1: '+'/' ' put a sign character in the field and
                // '0' packs zeros between the sign and the digits — `+42`,
                // ` 42`, `-0042`. No Zig spec spells any of the three (its
                // `{d:0>5}` writes `00-42`), so the field is composed in
                // scratch — see `renderPrintArg`'s .cint arm.
                try appendStrField(g, fmt, spec, zero_fill);
                try ops.append(a, .{ .v = v, .want = .int, .how = .cint, .spec = spec });
            } else if (spec.width > 0) {
                // A width alone makes std.fmt spell the sign (`{d:>5}` writes
                // `+42`), so the decimal TEXT pads instead, via `zPadInt`.
                try appendStrField(g, fmt, spec, false);
                try ops.append(a, .{ .v = v, .want = .int, .how = .pad, .spec = spec });
            } else {
                try fmt.appendSlice(a, "{d}");
                try ops.append(a, .{ .v = v, .want = .int, .spec = spec });
            }
        },
        else => {
            // The Zig verb, for the conversions VerA does not spell out.
            // `conv == 0` — an operand outside every format run — is §9.4.3's
            // "default decimal format": the value in its own type's natural
            // spelling ({d} minimal-width, not 1364's auto-sized field; see
            // `buildArgs`), and `%s`/the default on a string print the text,
            // which is what every `CHECK` macro's `%s` depends on. `%t`/`%u`/
            // `%z`/`%v` are §9.4.3's timeformat/binary/strength rows, none of
            // which an analog device carries — they render as the value.
            const verb: []const u8 = switch (conv) {
                's' => "s",
                't', 'u', 'z', 'v' => "d",
                else => if (ty == .str) "s" else "d",
            };
            try fmt.append(a, '{');
            try fmt.appendSlice(a, verb);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .v = v, .want = ty, .spec = spec });
        },
    }
}

/// Render one operand of a `std.debug.print`. The `S` scalar is opaque, so a
/// real crosses into the format layer through `.val()`; an integer and a
/// string are already plain Zig values. The .cint/.cexp arms emit labeled
/// block EXPRESSIONS into the argument tuple — their scratch is the `zb{i}`
/// array `emitScratch` declared in the enclosing display block.
pub fn renderPrintArg(g: *Gen, p: PrintArg, i: usize) Error!void {
    switch (p.how) {
        .ascii => {
            // The carrier is i64; mask to the source width before extracting
            // bytes so sign-extension cannot add characters. Only leading
            // zero BYTES vanish.
            // Interior/trailing NUL bytes are data, never string terminators.
            try g.b("zs{d}: {{ std.mem.writeInt(u64, &zb{d}, @as(u{d}, @truncate(@as(u64, @bitCast(@as(i64, ", .{ i, i, p.bits });
            try g.renderVal(p.v, .int);
            try g.b("))))), .big); break :zs{d} std.mem.trimStart(u8, &zb{d}, &.{{0}}); }}", .{ i, i });
        },
        .pad => {
            try g.b("zPadInt(&zb{d}, ", .{i});
            try g.renderVal(p.v, .int);
            try g.b(")", .{});
        },
        .bits => {
            // The pattern at the operand's own width (`PrintArg.bits`): §3.2
            // makes an `integer` 32 bits, so -5 is fffffffb, not sixteen digits.
            if (p.bits < 64) try g.b("@as(u{d}, @truncate(", .{p.bits});
            try g.b("@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))", .{});
            if (p.bits < 64) try g.b("))", .{});
        },
        .chr => {
            try g.b("@as(u8, @truncate(@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))))", .{});
        },
        .cint => {
            // C 7.21.6.1 sign placement. Zero-fill: zeros go AFTER the sign,
            // so the negative branch prints `-` then pads |v| to width-1, and
            // the non-negative branch prints the '+'/' '/nothing the flags ask
            // for then pads to what is left. @abs on an i64 returns u64, so
            // minInt needs no special case. Without zero-fill the field is
            // sign+digits and the OUTER `{s:>W}` does any padding.
            const sign: []const u8 = if (p.spec.plus) "+" else if (p.spec.space) " " else "";
            const w = p.spec.w();
            const zero_fill = p.spec.zero and !p.spec.left and p.spec.width > 0;
            try g.b("zi{d}: {{ const zv: i64 = ", .{i});
            try g.renderVal(p.v, .int);
            if (zero_fill) {
                // @abs in BOTH branches: Zig spells `+42` for a SIGNED int the
                // moment a width fixes the field, and @abs's u64 has no sign
                // for it to spell.
                try g.b("; if (zv < 0) break :zi{d} std.fmt.bufPrint(&zb{d}, \"-{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable", .{ i, i, w - 1 });
                try g.b("; break :zi{d} std.fmt.bufPrint(&zb{d}, \"{s}{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable; }}", .{ i, i, sign, w - sign.len });
            } else {
                try g.b("; break :zi{d} std.fmt.bufPrint(&zb{d}, \"{{s}}{{d}}\", .{{ if (zv < 0) \"\" else \"{s}\", zv }}) catch unreachable; }}", .{ i, i, sign });
            }
        },
        .creal => {
            // C11 7.21.6.1's flag bits, in `str_kernels.zCReal`'s order:
            // 1 '-', 2 '+', 4 ' ', 8 '0'. The kernel composes the whole field
            // — sign, digits and padding — so nothing is left for the format
            // string to align.
            const flags: u8 = (@as(u8, @intFromBool(p.spec.left))) |
                (@as(u8, @intFromBool(p.spec.plus)) << 1) |
                (@as(u8, @intFromBool(p.spec.space)) << 2) |
                (@as(u8, @intFromBool(p.spec.zero)) << 3);
            try g.b("zCReal(&zb{d}, (", .{i});
            try g.renderVal(p.v, .real);
            try g.b(").val(), '{c}', {d}, {d}, {d})", .{
                p.conv,
                flags,
                p.spec.w(),
                if (p.spec.prec) |pr| @as(i64, @intCast(@min(pr, Spec.max_field))) else -1,
            });
        },
        .plain => switch (p.want) {
            .real => {
                try g.b("(", .{});
                try g.renderVal(p.v, .real);
                try g.b(").val()", .{});
            },
            .int => try g.renderVal(p.v, .int),
            .str => try g.renderVal(p.v, .str),
        },
    }
}

// ---------------------------------------------------------------------------
// Tests — the emitted translation, pinned byte-for-byte. The runtime halves
// of the same rules (the actual transcript text) are pinned by
// tests/fixtures/ch09_system_tasks/170_display_argument_runs.va and
// 171_display_c_format_flags.va, which format into a string variable and
// compare it to a literal — text a unit test over an emitter cannot execute.
// ---------------------------------------------------------------------------

const Preprocessor = @import("frontend").Preprocessor;
const Lexer = @import("frontend").Lexer;
const Parser = @import("frontend").Parser;
const proof = @import("ir").proof;
const diag = @import("diag");

/// The pipeline through `cg.generate` with §9.4 display ON, arena-lived — the
/// same stages codegen.zig's private Harness runs, kept local so this file's
/// tests do not reach into another file's test scaffolding.
fn genDisplayText(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    var bag = diag.Bag.init(arena);
    const text = (try Preprocessor.process(arena, src, .{ .bag = &bag })).text;
    const toks = try Lexer.Lexer.tokenize(arena, text);
    var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &bag);
    var file = try p.parseSourceFile();
    file.builtin_modules = Preprocessor.spice_module_count;
    var mir: Mir = .{};
    var low = Lower.init(arena, &mir, &file, text, toks.items(.start), &bag);
    try low.lowerFile();
    const v = try proof.prove(arena, &mir, &low, &bag);
    var fatal = false;
    return (try cg.generate(arena, arena, &mir, &low, v, &fatal, .{ .display = .emit })).text;
}

/// One analog block body → the printing artifact's text.
fn emitBody(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const src = try std.fmt.allocPrint(arena,
        \\module t(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    {s}
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    , .{body});
    return genDisplayText(arena, src);
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "§9.4.1 every string argument opens a format run; output concatenates" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Two runs, each consuming its own operand: `a=1b=2`, with no separator
    // anywhere — the second string is a FORMAT, not the first run's operand.
    const two = try emitBody(a, "$strobe(\"a=%d\", 1, \"b=%d\", 2);");
    try std.testing.expect(has(two, "\"a={d}b={d}\\n\""));

    // A string consumed BY a conversion stays an operand: `%s` takes "x",
    // then "y=%d" opens the next run over 2.
    const eaten = try emitBody(a, "$strobe(\"%s;\", \"x\", \"y=%d\", 2);");
    try std.testing.expect(has(eaten, "\"{s};y={d}\\n\""));

    // An expression BEFORE the first string prints in the §9.4.3 default —
    // the old code dropped it on the floor. In order: `3.5lead 7`.
    const lead = try emitBody(a, "$strobe(3.5, \"lead %d\", 7);");
    try std.testing.expect(has(lead, "\"{d}lead {d}\\n\""));
    try std.testing.expect(has(lead, "S.con(3.5)"));

    // No inserted space before a bare trailing operand: `v:42`, not `v: 42`.
    // §9.4.1's way to write that space is a null argument.
    const bare = try emitBody(a, "$strobe(\"v:\", 42);");
    try std.testing.expect(has(bare, "\"v:{d}\\n\""));
}

test "§9.7.3 $fatal's finish_number is a diagnostic level, not message text" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try emitBody(a, "$fatal(0, \"died %d\", 7);");
    // The 0 is consumed by the skip, not printed by the walk.
    try std.testing.expect(has(out, "\"FATAL: died {d}\\n\""));
    try std.testing.expect(!has(out, "{d}died"));
}

test "§9.4.3 Table 9-23: every real conversion routes through the C kernel" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // All four conversions become one `zCReal` call and one `{s}` — the kernel
    // composes the whole field, so no outer alignment is left to apply.
    const e = try emitBody(a, "$strobe(\"%e\", 1.5);");
    try std.testing.expect(has(e, "zCReal(&zb0, (S.con(1.5)).val(), 'e', 0, 0, -1)"));
    try std.testing.expect(has(e, "\"{s}\\n\""));

    // Width and precision reach the kernel as NUMBERS (C puts the pad inside
    // the field, behind the sign), never as a Zig format tail.
    const wp = try emitBody(a, "$strobe(\"%10.4e\", 1.5);");
    try std.testing.expect(has(wp, "'e', 0, 10, 4)"));
    try std.testing.expect(!has(wp, "{s:>10}"));

    // The conversion letter travels in the CASE the source wrote it: `%E`
    // spells the exponent marker (and INF/NAN) upper case.
    const up = try emitBody(a, "$strobe(\"%E\", 1.5);");
    try std.testing.expect(has(up, "'E', 0, 0, -1)"));

    // The flag bits, in `zCReal`'s order: 1 '-', 2 '+', 4 ' ', 8 '0'.
    const fl = try emitBody(a, "$strobe(\"%+08.1f\", 2.5);");
    try std.testing.expect(has(fl, "'f', 10, 8, 1)"));

    // Table 9-23's `%r` is engineering notation, not a second spelling of
    // `%g` — it reaches the same kernel with its own letter.
    const r = try emitBody(a, "$strobe(\"%r\", 1.5);");
    try std.testing.expect(has(r, "'r', 0, 0, -1)"));
}

test "§9.4.3/C11 7.21.6.1: zCReal is the conversion the device runs" {
    // `str_kernels.zig` is `@embedFile`d into every printing artifact AND
    // imported here, so these ARE the renderings a model gets. Each row is a
    // rule of the clause rather than a sample: the %g style choice on both
    // sides of its window, the sign/zero-fill placement, the tie that
    // separates round-half-to-EVEN from round-half-away, and §2.6.2's
    // mantissa normalisation.
    // Through the `kernels` module door, never by relative path: a kernel file
    // may live in exactly ONE module — see `kernels.zig`'s header.
    const k = @import("kernels").str_kernels;
    var b: [1024]u8 = undefined;
    const rows = .{
        .{ 1234.5678, 'g', @as(u8, 0), @as(usize, 0), @as(i64, -1), "1234.57" },
        .{ 1.0e-5, 'g', 0, 0, -1, "1e-05" }, // exponent below -4 -> %e
        .{ 1.0e8, 'g', 0, 0, -1, "1e+08" }, // exponent at/above P -> %e
        .{ 2.5, 'f', 10, 8, 1, "+00002.5" }, // '+' then the zero fill
        .{ -3.5, 'f', 8, 9, 2, "-00003.50" }, // the pad is BEHIND the sign
        .{ -3.5, 'f', 1, 9, 2, "-3.50    " }, // '-' overrides '0'
        .{ 2.5, 'f', 0, 0, 0, "2" }, // an exact tie goes to the EVEN digit
        .{ 3.5, 'f', 0, 0, 0, "4" }, // ...which round-half-away gets wrong
        .{ 1.5, 'e', 0, 0, -1, "1.500000e+00" },
        .{ 0.0015, 'r', 0, 0, -1, "1.5m" },
        .{ 2.0e-13, 'R', 0, 0, -1, "200f" }, // not "0.2p": the mantissa is >= 1
    };
    inline for (rows) |row| {
        try std.testing.expectEqualStrings(row[5], k.zCReal(&b, row[0], row[1], row[2], row[3], row[4]));
    }
    // C11 7.21.6.1p13 rounds the VALUE, not its shortest decimal: 0.1 is not
    // 0.1, and past 17 digits that is visible.
    try std.testing.expectEqualStrings("0.10000000000000000555", k.zCReal(&b, 0.1, 'f', 0, 0, 20));
}

test "§9.4.1 $monitor reports a step only when the record changed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `$strobe` prints unconditionally; `$monitor` goes through §9.4.1's
    // mechanism, which is the whole difference between the two tasks. The
    // needles are CALL-shaped: the kernel's own text is in both artifacts.
    const s = try emitBody(a, "$strobe(\"v=%d\", 1);");
    try std.testing.expect(has(s, "zd: { std.debug.print("));
    const m = try emitBody(a, "$monitor(\"v=%d\", 1);");
    try std.testing.expect(has(m, "S.con(zMonitorArm(0))")); // the invocation
    try std.testing.expect(has(m, "zd: { if (zMonitor(0, "));
    try std.testing.expect(has(m, ") |zt| std.debug.print(\"{s}\", .{zt});"));
    // §9.5.2 "$fmonitor ... works just like its counterpart": the record is
    // composed, then written only if it changed.
    const f = try emitBody(a, "$fmonitor(1, \"v=%d\", 1);");
    try std.testing.expect(has(f, "break :zf if (zMonitor(0, "));
    try std.testing.expect(has(f, ") |zm| zFPut("));

    // The latch itself, at the boundary the emitted code uses it at.
    const k = @import("kernels").str_kernels;
    // "When a $monitor task is invoked ... the simulator sets up a mechanism":
    // before the statement has run there is no mechanism and nothing reports.
    try std.testing.expect(k.zMonitor(9001, &.{1}, "a\n") == null);
    _ = k.zMonitorArm(9001);
    _ = k.zMonitorArm(9002);
    try std.testing.expectEqualStrings("a\n", k.zMonitor(9001, &.{1}, "a\n").?); // first step: no predecessor
    try std.testing.expect(k.zMonitor(9001, &.{1}, "a\n") == null); // unchanged
    // The watched VALUES decide, not the text: a line that differs only in an
    // exempt `$abstime` (never in `vals`) is not a change.
    try std.testing.expect(k.zMonitor(9001, &.{1}, "t=2 a\n") == null);
    try std.testing.expectEqualStrings("b\n", k.zMonitor(9001, &.{2}, "b\n").?);
    try std.testing.expect(k.zMonitor(9001, &.{2}, "b\n") == null);
    // A DISTINCT site is a distinct latch — two monitors must not mask each
    // other, exactly as two `$sformat` sites must not share a row.
    try std.testing.expectEqualStrings("b\n", k.zMonitor(9002, &.{2}, "b\n").?);
}

test "§9.5.4.2 a scan consumes per DIRECTIVE, and says how much" {
    // `ZScan.used` is what `$fscanf` advances the descriptor by, so these
    // numbers are §9.5.5's `$ftell` answers — see `file_kernels.zFTake`.
    const k = @import("kernels").str_kernels;
    // "The offending input character is left unread": nothing moved, and the
    // return is 0 and not EOF, because the input has not ended.
    const fail = k.zScan("abc\n", "%d", -1);
    try std.testing.expectEqual(@as(i64, 0), fail.n);
    try std.testing.expectEqual(@as(usize, 0), fail.used);
    // "Trailing white space (including newline characters) is left unread
    // unless matched by a directive" — the field is two bytes, not the line.
    const first = k.zScan("12 34\n56\n", "%d", 0);
    try std.testing.expectEqual(@as(i64, 12), first.i);
    try std.testing.expectEqual(@as(usize, 2), first.used);
    // White space in the CONTROL string matches a newline, so one scan can
    // take a field from each of two lines.
    const two = k.zScan("12\n34\n", "%d %d", 1);
    try std.testing.expectEqual(@as(i64, 2), two.n);
    try std.testing.expectEqual(@as(i64, 34), two.i);
    try std.testing.expectEqual(@as(usize, 5), two.used);
    // "If the input ends before the first matching failure or conversion, EOF
    // is returned" — and the white space looked through still counts consumed.
    const eof = k.zScan("\n", "%d", -1);
    try std.testing.expectEqual(@as(i64, -1), eof.n);
    try std.testing.expectEqual(@as(usize, 1), eof.used);
    // §9.5.4.2's `%r`, over §2.6.2 Table 2-1 — both spellings of the 1e3 row,
    // and an optional symbol.
    try std.testing.expectEqual(@as(f64, 2500.0), k.zScan("2.5K", "%r", 0).r);
    try std.testing.expectEqual(@as(f64, 2500.0), k.zScan("2.5k", "%r", 0).r);
    try std.testing.expectEqual(@as(f64, 4.0), k.zScan("4", "%r", 0).r);
    // `%m` "does not read data from the input file or str argument", so the
    // directive after it still sees the whole field.
    const path = k.zScan("42", "%m%d", 1);
    try std.testing.expectEqual(@as(i64, 2), path.n);
    try std.testing.expectEqual(@as(i64, 42), path.i);
}

test "§9.4.3/C: integer sign flags — %05d packs zeros after the sign, %+d prints it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `%05d` of -42 must print `-0042`, not Zig's `00-42`: the negative branch
    // writes the sign first and zero-pads the magnitude to width-1.
    const z = try emitBody(a, "$strobe(\"%05d\", -42);");
    try std.testing.expect(has(z, "\"-{d:0>4}\""));
    try std.testing.expect(has(z, "\"{d:0>5}\""));

    // `%+d` of 7 prints `+7` — the flag used to be parsed and dropped.
    const plus = try emitBody(a, "$strobe(\"%+d\", 7);");
    try std.testing.expect(has(plus, "if (zv < 0) \"\" else \"+\""));

    // A width alone still routes through zPadInt (`  -42`, ` 42`), the
    // documented text-padding detour.
    const pad = try emitBody(a, "$strobe(\"%5d\", -42);");
    try std.testing.expect(has(pad, "zPadInt(&zb0, "));
    try std.testing.expect(has(pad, "\"{s:>5}\\n\""));
}

test "§9.7 simulation control: the run ends at the call, with the pinned status" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // §9.7.3: $fatal prints its message, then exits with the finish_number as
    // the errorcode. The torture fixture 173_fatal_terminates.va proves the
    // run ends with its declared `//! exit 1`; this also pins the level-2 code.
    const fat = try emitBody(a, "$fatal(2, \"died %d\", 7);");
    try std.testing.expect(has(fat, "\"FATAL: died {d}\\n\""));
    try std.testing.expect(has(fat, "_ = zHalt(2); "));
    // ...floored at 1: a $fatal may never exit 0 and read as success to the
    // shell `vera --run` forwards the status to.
    const fat0 = try emitBody(a, "$fatal(0, \"boom\");");
    try std.testing.expect(has(fat0, "_ = zHalt(1); "));
    // $error stays non-fatal: same severity family, no exit at its call site
    // (the kernel text is present in every printing artifact; the CALL is not).
    const err = try emitBody(a, "$error(\"soft\");");
    try std.testing.expect(!has(err, "_ = zHalt"));

    // §9.7.1: the default diagnostic level is 1 — "prints simulation time and
    // location" — and the exit status is 0: ending the run is the task's
    // defined behaviour, not a failure.
    const fin = try emitBody(a, "$finish;");
    try std.testing.expect(has(fin, "\"$finish: t={d} (t)\\n\""));
    try std.testing.expect(has(fin, "_ = zHalt(0); "));
    // Table 9-25 level 0 prints nothing (and still exits).
    const fin0 = try emitBody(a, "$finish(0);");
    try std.testing.expect(!has(fin0, "$finish: t="));
    try std.testing.expect(has(fin0, "_ = zHalt(0); "));
    // §9.7.2 $stop, non-interactive artifact: diagnostic then exit 0.
    const stp = try emitBody(a, "$stop(1);");
    try std.testing.expect(has(stp, "\"$stop: t={d} (t)\\n\""));
    try std.testing.expect(has(stp, "_ = zHalt(0); "));

    // The kernel IS the exit — `std.process.exit`, f64-typed so §9.7's legal
    // dead code after a terminating call still compiles.
    try std.testing.expect(has(fin, "fn zHalt(code: u8) f64 {\n    std.process.exit(code);\n}"));
}

test "§9.4.3 Table 9-22: %h shows the operand's two's-complement bit pattern" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // VerA integers are 64-bit (§2.6.1 — a literal keeps all 64 bits), so
    // `%h` of -42 is ffffffffffffffd6: the u64 bitcast is what stops Zig's
    // `{x}` from writing `-2a` instead. Same treatment for %o and %b.
    const out = try emitBody(a, "$strobe(\"%h %o %b\", -42, -42, -42);");
    try std.testing.expect(has(out, "\"{x} {o} {b}\\n\""));
    try std.testing.expect(has(out, "@as(u64, @bitCast(@as(i64, "));
}

test "§9.4.5 numeric strings preserve source width through every output sink" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try emitBody(a, "$display(\"%s\", 8'shff); $write(\"%S\", 64'h4142434445464748);");
    try std.testing.expect(has(out, "std.mem.writeInt(u64"));
    try std.testing.expect(has(out, "@as(u8, @truncate(@as(u64"));
    try std.testing.expect(has(out, "@as(u64, @truncate(@as(u64"));
    try std.testing.expect(has(out, "std.mem.trimStart(u8"));
}
