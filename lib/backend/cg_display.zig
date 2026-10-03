//! Void display, file-I/O and simulation-control `call`s -> labeled block
//! expressions around `std.debug.print`, `bufPrint` or the file kernels, with
//! §9.4.3 conversions translated into Zig format text.
//! LRM §9.4 (display), §9.5 (file I/O), §9.7 (simulation control).
//! Runs only when `codegen.Display` is `.emit`; under `.drop` no call reaches it.

const std = @import("std");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const VTy = Analysis.VTy;
const diag = @import("diag");

// -------------------------------------------------------- §9.4 display ----
//
// Codegen renders values, not statements, so a display call renders as a
// labeled block expression whose value is the `S.con(0.0)` the dropped form
// produces; the print is its side effect. It is emitted because
// `Lower.finishDisplays` chained it into a live root.

/// Parsed §9.4.3 conversion prefix: `%[flags][width][.precision]conv`. Table
/// 9-23 grants the real conversions "the full formatting capabilities
/// available in the C language", so C11 7.21.6.1 defines each flag; the
/// integer conversions share the grammar. Width and precision are numbers
/// because the composed C-style fields need them as arithmetic.
pub const Spec = struct {
    left: bool = false, // '-' left-justify; C makes it override '0'
    plus: bool = false, // '+' always spell the sign
    space: bool = false, // ' ' a space where the sign would be; '+' wins
    zero: bool = false, // '0' pad with zeros AFTER the sign
    width: usize = 0, // 0 = no width given
    prec: ?usize = null, // null = no precision given

    // The scratch for a composed field is a stack array in the emitted block,
    // so a width or precision above this is refused (E1011) rather than
    // emitted as a huge frame. 4096 matches `str_kernels.zSBuf`'s row and
    // `file_kernels.ZFSlot.line`, so a record this formatter composes is one a
    // §9.5.2 write can emit and a §9.5.4.1 `$fgets` can read back whole.
    const max_field = 4096;
    fn w(self: Spec) usize {
        return self.width;
    }
    fn p(self: Spec, default: usize) usize {
        return self.prec orelse default;
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
    /// `.creal`: the source's conversion letter, case kept, because `%E`/`%G`
    /// print the exponent marker and INF/NAN in upper case.
    conv: u8 = 0,
    /// Original integer width, before SSA and the i64 storage carrier.
    bits: u7 = 64,

    pub const Mode = enum {
        /// Straight through the Zig verb the conversion mapped to.
        plain,
        /// §9.4.3 `%c`: the operand's low byte (Table 9-22 "display as an
        /// ASCII character"), narrowed to the `u8` Zig's `{c}` takes.
        chr,
        /// `%<width>d` with no sign/zero flag: render the decimal TEXT through
        /// `zPadInt` and pad it as a string. See `emitDisplayTask` for why.
        pad,
        /// `%+d` / `% d` / `%0<width>d`: C puts the sign inside the field
        /// (`+42`, ` 42`, `-0042`), which no Zig format spec can spell, so the
        /// field text is composed in per-op scratch and printed as `{s}`.
        cint,
        /// §9.4.3 Table 9-23's real conversions (`%e`, `%f`, `%g`, engineering
        /// `%r`) through `str_kernels.zCReal`, which follows C11 7.21.6.1
        /// (round half to even) where Zig's float verbs do not. The kernel
        /// composes the whole field, sign and padding included.
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

/// §9.4.1's argument-list model, shared by every sink (display, §9.5.2 file
/// writers, §9.5.3 string writers). Every string argument is a format whose
/// conversions consume the expression arguments after it; an expression no
/// format consumed prints in the §9.4.3 default decimal format; nothing
/// inserts separators (a null argument is §9.4.1's space).
///
/// Two deviations from IEEE 1364 §17.1.1.3:
///   - a bare or `%d` integer prints minimal-width rather than auto-sized to
///     20 columns, unless it is an unsigned sized literal whose width lowering
///     records (`decimalWidth`); the radices auto-size at every recorded width;
///   - a bare real prints shortest-round-trip decimal, not `%g`.
fn buildArgs(
    g: *Gen,
    args: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
    site: usize,
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
    // One call's conversions become one Zig format call, and Zig's formatter
    // takes at most 32 arguments (`std.fmt.ArgSetType`). Refused here rather
    // than as a compile error in generated Zig.
    if (ops.items.len > max_format_args)
        return refuse(g, fmt, ops, site, .E1010, "this call formats {d} values; one call formats at most {d}", .{ ops.items.len, max_format_args });
    for (ops.items) |p| if (p.spec.width > Spec.max_field or (p.spec.prec orelse 0) > Spec.max_field)
        return refuse(g, fmt, ops, site, .E1011, "a field width or precision here exceeds {d}", .{Spec.max_field});
}

/// Reports `code` at call `site` and marks the build fatal. The emptied record
/// keeps the rest of the device emittable.
fn refuse(
    g: *Gen,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
    site: usize,
    code: diag.Code,
    comptime msg: []const u8,
    args: anytype,
) Error!void {
    if (g.diags) |bag| try bag.add(.codegen, code, g.lowered.tokenSpan(g.mir.instTok(@fromBackingInt(@intCast(site)))), msg, args);
    g.any_fatal = true;
    if (g.fatal == null) g.fatal = "a display or format call exceeds a formatter limit";
    fmt.clearRetainingCapacity();
    ops.clearRetainingCapacity();
}

/// E1010's bound: the argument count Zig's `std.fmt` accepts in one call.
pub const max_format_args = 32;

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

/// Emits one §9.4.1 display or §9.7.3 severity task as a labeled block that
/// prints to stderr (the transcript; stdout belongs to a host that pipes
/// data). `site` keys `$monitor`'s scratch row. `$fatal` also halts.
pub fn emitDisplayTask(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    // §9.7.3: the severity is the message's whole reason for existing, and a
    // reader cannot recover it from the text.
    if (severityWord(c)) |word| {
        try fmt.appendSlice(g.arena, word);
        try fmt.appendSlice(g.arena, ": ");
    }
    // §9.7.3 Syntax 9-7: `$fatal ( finish_number [, message_argument … ] )`.
    // The finish_number sets the $finish diagnostic level; it is not part of
    // the message, so it must not print. Dropped only when it is not a string,
    // so a (nonconforming but unambiguous) `$fatal("bye")` keeps its text.
    // §9.4.1 a monitor report carries its site key first (`Lower.armMonitor`).
    const mon = c == .@"$monitor";
    const body = if (mon or (c == .@"$fatal" and args.len > 0 and g.strArg(args, 0) == null))
        args[1..]
    else
        args;
    try buildArgs(g, body, &fmt, &ops, site);
    // §9.4.1: `$write` is the family member that does NOT end the line.
    if (endsLine(c)) try fmt.append(g.arena, '\n');

    // A width-padded integer goes through `zPadInt` because Zig's `{d:>5}`
    // writes `+42` where §9.4.3 writes ` 42`; its scratch is a stack array
    // in this block.
    try g.b("zd: {{ ", .{});
    try emitScratch(g, ops.items);
    if (mon) {
        // §9.4.1's mechanism: format into this site's scratch row, then report
        // only when a watched argument VALUE differs from the step this site
        // last reported (`monitorValues`). An overrun is `emitStringFormat`'s
        // E1011.
        try g.b("if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
        try renderPrintArgs(g, ops.items);
        try g.b("}}) catch zSOver())) |zt| std.debug.print(\"{{s}}\", .{{zt}}); ", .{});
    } else {
        try g.b("std.debug.print(\"{f}\", .{{", .{std.zig.fmtString(fmt.items)});
        try renderPrintArgs(g, ops.items);
        try g.b("}}); ", .{});
    }
    // §9.7.3: `$fatal` "terminates the simulation with an errorcode". The
    // finish_number "may be used in an implementation-specific manner"; here
    // it is the exit status, floored at 1 so a `$fatal` never reads as success
    // to a shell. `zHalt` is f64-typed so the dead code after it still
    // compiles; `break :zd` is statically reachable, never taken.
    if (c == .@"$fatal") {
        const lvl = finishLevel(g, args);
        try g.b("_ = zHalt({d}); ", .{std.math.clamp(lvl, 1, 255)});
    }
    try g.b("break :zd S.con(0.0); }}", .{});
}

/// §9.7.1's diagnostic argument, folded. Syntax 9-5/9-7 make it the literal
/// 0 | 1 | 2; anything that does not fold takes the default 1.
fn finishLevel(g: *Gen, args: []const Mir.Value) i64 {
    if (args.len == 0) return 1;
    return switch (g.mir.valueDef(g.an.rv(args[0]))) {
        .int_const => |x| x,
        .float_const => |x| std.math.lossyCast(i64, x),
        .undef, .str_const, .param_ref, .block_param, .inst_result => 1,
    };
}

/// Emits §9.7.1 `$finish` / §9.7.2 `$stop` in the printing artifact: the run
/// ends at the call, after every print before it. Table 9-25 level 0 prints
/// nothing, level >= 1 prints `sim.t` and the module. Both exit 0: the display
/// phase runs on the accepted solution, which is where §9.7.1 exits.
///
/// ponytail: level 2 prints what level 1 does (no CPU/memory bookkeeping), and
/// `$stop` exits because a batch artifact has nothing to suspend into; add a
/// debugger hook in the runner when something interactive can resume.
pub fn emitSimCtl(g: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
    const level = finishLevel(g, args);
    try g.b("zd: {{ ", .{});
    if (level >= 1) {
        g.uses_sim = true;
        try g.b("std.debug.print(\"{s}: t={{d}} ({f})\\n\", .{{sim.t}}); ", .{
            name, std.zig.fmtString(g.mir.name),
        });
    }
    try g.b("_ = zHalt(0); break :zd S.con(0.0); }}", .{});
}

/// Emits §9.5.3 `$swrite`/`$sformat` ("the same as their counterparts ...
/// except that ... the resulting string shall be written"): `emitDisplayTask`'s
/// translation into call site `site`'s scratch row, with no newline. The
/// block's value is the formatted string. §3.3 removes NUL bytes only after
/// formatting, so field widths count the original bytes.
pub fn emitStringFormat(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    try buildArgs(g, args, &fmt, &ops, site);
    try g.b("zs: {{ ", .{});
    try emitScratch(g, ops.items);
    // An overrun ends the run with E1011 (`zSOver`): §9.5.3 states no
    // truncation rule, and an empty or half string is a wrong answer.
    try g.b("break :zs zStringStore(std.fmt.bufPrint(zSBuf({d}), \"{f}\", .{{", .{ site, std.zig.fmtString(fmt.items) });
    try renderPrintArgs(g, ops.items);
    try g.b("}}) catch zSOver()); }}", .{});
}

// ------------------------------------------------------- §9.5 file I/O ----
//
// §9.5.2 defines its five output tasks as the §9.4.1 ones "with one additional
// argument, which is either a multichannel descriptor or a file descriptor", so
// they share this formatter. The descriptor operations have no text but are
// sequenced in the same unit (`codegen.Gen.emitting_display`).

/// Emits one §9.5 call in the display unit. `site` is the call's MIR
/// instruction id, the per-call-site key for its formatted bytes (`zSBuf`).
/// Aborts codegen for a callee `codegen.isFileCall` does not route here.
pub fn emitFileCall(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    // §9.5.1/§9.5.2/§9.5.6: `$fclose`, `$fflush` and the five output tasks are
    // tasks, so `Mir.callee.ty` types them real like every void call, but the
    // kernels return integers. The cast lives here because the value only
    // gives the display chain something to carry (`Lower.sequenceFileCall`).
    const wrap = Mir.callee.ty(c) == .real;
    // `$fscanf$real` is the one real-typed §9.5 call whose kernel (`zScanR`)
    // already returns f64, so it takes no `@floatFromInt`.
    const from_int = c != .@"$fscanf$real";
    // An integer result is latched for the other units (`file_kernels.zFRes`).
    const keep = Mir.callee.ty(c) == .int;
    if (wrap) try g.b("S.con(", .{});
    if (wrap and from_int) try g.b("@as(f64, @floatFromInt(", .{});
    if (keep) try g.b("zFKeep({d}, ", .{site});
    try emitFileCallInner(g, c, args, site);
    if (keep) try g.b(")", .{});
    if (wrap and from_int) try g.b("))", .{});
    if (wrap) try g.b(")", .{});
}

fn emitFileCallInner(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    switch (c) {
        // §9.5.2's five output tasks, and the two descriptor tasks that take no
        // text (`Lower.isFileOutTask`).
        .@"$fdisplay",
        .@"$fwrite",
        .@"$fstrobe",
        .@"$fmonitor",
        .@"$fdebug",
        .@"$fclose",
        .@"$fflush",
        => return emitFileWrite(g, c, args, site),
        // §9.5.1 Syntax 9-2: one argument is a multichannel descriptor, two are a
        // file descriptor. The presence of the type argument IS the discriminator,
        // and it is the only thing that decides which encoding comes back.
        .@"$fopen" => {
            try g.b("zFOpen(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.f_zero, .str);
            try g.b(", ", .{});
            if (args.len > 1) try g.renderVal(args[1], .str) else try g.b("\"\"", .{});
            return g.b(", {s})", .{if (args.len > 1) "false" else "true"});
        },
        // The one-argument descriptor operations, in clause order.
        .@"$fgets", .@"$ftell", .@"$feof", .@"$ferror" => {
            try g.b("{s}(", .{switch (c) {
                .@"$fgets" => "zFGets", // §9.5.4.1: the character count
                .@"$ftell" => "zFTell", // §9.5.5
                .@"$feof" => "zFEof", // §9.5.8
                else => "zFError", // else: `$ferror`, the one left (§9.5.7) — the errno
            }});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        // §9.5.5 `$rewind(fd)` "is equivalent to $fseek (fd,0,0)": the clause's own
        // words, so it is the same kernel with the constants written in.
        .@"$rewind" => {
            try g.b("zFSeek(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            return g.b(", 0, 0)", .{});
        },
        .@"$fseek" => {
            try g.b("zFSeek(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 2) args[2] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        // §9.5.4.2 the count. Composed here because `file_kernels.zig` cannot
        // call `str_kernels.zScan` (each kernel file compiles alone). Scan the
        // unread window, then consume exactly `zScan.used`: "the offending
        // input character is left unread". Operands are (fd, format); the item
        // readers below re-scan the window `zFTake` leaves latched.
        .@"$fscanf" => {
            const fd = if (args.len > 0) args[0] else Mir.Value.zero;
            try g.b("zk{d}: {{ const zw = zFWindow(", .{site});
            try g.renderVal(fd, .int);
            try g.b("); const zr = zScan(zw, ", .{});
            try g.renderVal(if (args.len > 1) args[1] else Mir.Value.f_zero, .str);
            try g.b(", -1); break :zk{d} zFTake(", .{site});
            try g.renderVal(fd, .int);
            return g.b(", zr.n, @intCast(zr.used)); }}", .{});
        },
        // The synthetic readers, all of which take the count first; see
        // `file_kernels.zFLine` for why that operand is there and why it is read.
        .@"$fgets$str" => return emitLine(g, args, "zFLine"),
        .@"$ferror$str" => return emitLine(g, args, "zFErrorStr"),
        // §9.5.4.2's items: the same three flavours `$sscanf` has, over the line the
        // count's read latched. `(count, fd, format, item)`.
        .@"$fscanf$int", .@"$fscanf$real", .@"$fscanf$str" => {
            try g.b("{s}(", .{switch (c) {
                .@"$fscanf$int" => "zScanI",
                .@"$fscanf$real" => "zScanR",
                else => "zScanS", // else: `$fscanf$str`, the one left
            }});
            try emitLine(g, args, "zFLine");
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 2) args[2] else Mir.Value.f_zero, .str);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 3) args[3] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        else => return g.abort(.E1020, "VerA: unhandled §9.5 call `{s}`", .{@tagName(c)}), // else: `emitCall` routes only `callee.isFileCall` here, and every one of those has a prong above
    }
}
/// The first two operands every synthetic reader carries: count, then fd.
inline fn emitLine(g: *Gen, args: []const Mir.Value, comptime kernel: []const u8) Error!void {
    try g.b(kernel ++ "(", .{});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
    try g.b(", ", .{});
    try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
    try g.b(")", .{});
}

/// §9.5.2's five output tasks, plus `$fclose`/`$fflush`. The descriptor is
/// `args[0]`; the rest is formatted as the §9.4.1 task of the same base name
/// (`$fwrite`, like `$write`, does not end the line). Syntax 9-3 has no
/// radix-suffixed spelling, so the default conversion is the operand's own.
fn emitFileWrite(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    // §9.5.1 `$fclose` and §9.5.6 `$fflush` take a descriptor and no text.
    if (c == .@"$fclose" or c == .@"$fflush") {
        try g.b("{s}(", .{if (c == .@"$fclose") "zFClose" else "zFFlush"});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // §9.4.1 a monitor report carries its site key ahead of the descriptor.
    const mon = c == .@"$fmonitor";
    const all = if (mon) args[1..] else args;
    const rest = if (all.len > 0) all[1..] else all;
    var fmt: std.ArrayList(u8) = .empty;
    var ops: std.ArrayList(PrintArg) = .empty;
    try buildArgs(g, rest, &fmt, &ops, site);
    // The §9.4.1 task §9.5.2 names this one after decides the newline:
    // `$write` is the member that does not end the line, and so is `$fwrite`.
    if (endsLine(c)) try fmt.append(g.arena, '\n');

    // The text is formatted into this call site's own scratch row and then
    // written, which is `emitStringFormat`'s sink with a descriptor instead of a
    // string variable. An overrun is E1011, as for §9.5.3.
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
    try g.b("}}) catch zSOver()", .{});
    if (mon) {
        try g.b("; break :zf if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", zt)) |zm| zFPut(", .{});
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", zm) else 0; }}", .{});
    } else try g.b("); }}", .{});
}

/// §9.4.1 what a monitor watches: one u64 per argument (a real's or integer's
/// bit pattern, a string's hash) for `zMonitor` to compare with the last
/// reported step. `$abstime` and `$realtime` are left out, "with the exception
/// of the $abstime or $realtime system functions".
fn monitorValues(g: *Gen, ops: []const PrintArg) Error!void {
    try g.b("&[_]u64{{", .{});
    var first = true;
    for (ops) |p| {
        const v = g.an.rv(p.v);
        const def = g.mir.valueDef(v);
        if (def == .inst_result and g.mir.instOp(def.inst_result) == .call) {
            const callee = g.mir.instData(def.inst_result).call.callee;
            if (callee == .@"$abstime" or callee == .@"$realtime") continue;
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

/// The site key `Lower.armMonitor` put first in a monitor's registration and
/// report: a literal, so it can key a comptime latch.
fn monitorKey(g: *const Gen, args: []const Mir.Value) i64 {
    return g.mir.valueDef(g.an.rv(args[0])).int_const;
}

/// Emits §9.4.1's registration half: arms the monitor latch of the site keyed
/// by `args[0]` (`str_kernels.zMonitorArm`).
pub fn emitMonitorArm(g: *Gen, args: []const Mir.Value) Error!void {
    return g.b("S.con(zMonitorArm({d}))", .{monitorKey(g, args)});
}

/// Returns the §9.7.3 severity prefix of `c`, or null for every other task.
pub fn severityWord(c: Mir.Callee) ?[]const u8 {
    return switch (c) {
        .@"$fatal" => "FATAL",
        .@"$error" => "ERROR",
        .@"$warning" => "WARNING",
        .@"$info" => "INFO",
        else => null, // else: §9.7.3 has exactly these four; every other task prints no severity
    };
}

/// §9.4.1: does the task end its line? `$write` and its radix forms are the
/// members that do not, and §9.5.2's `$fwrite` is named after `$write`.
fn endsLine(c: Mir.Callee) bool {
    return switch (c) {
        .@"$write", .@"$writeb", .@"$writeo", .@"$writeh", .@"$fwrite" => false,
        else => true, // else: every other §9.4.1/§9.5.2 printing task is a `$display`-like one
    };
}

/// Translates one §9.4.2/§9.4.3 format string into `std.fmt` text appended to
/// `fmt` (literal `{`/`}` doubled), appending one `PrintArg` per conversion.
/// Returns how many of `operands` were consumed, so the §9.4.1 walk resumes
/// after them. A conversion with no operand renders 0.0; §9.4.3 makes that a
/// pairing violation, which `Lower.checkFormatPairing` diagnoses.
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
        // §9.4.3 `%[flags][width][.precision]conv`: the C prefix Table 9-23
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
            spec.width = std.fmt.parseUnsigned(usize, src[width_at..i], 10) catch std.math.maxInt(usize);
        if (i < src.len and src[i] == '.') {
            i += 1;
            const prec_at = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            spec.prec = std.fmt.parseUnsigned(usize, src[prec_at..i], 10) catch std.math.maxInt(usize);
        }
        if (i >= src.len) break;
        const conv = src[i];
        i += 1;
        // §9.4.3 `%m` names the enclosing module, and `%l` consumes no operand
        // either: "for each % character (except %m, %% and %l) … a
        // corresponding expression argument shall be supplied". Table 9-22's
        // `%l` is "library.cell"; VerA has no library map, so the library is
        // empty and the cell is the module, the same text `%m` gives.
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
        try fmt.appendSlice(a, std.mem.print(&buf, "{d}", .{spec.width}) catch unreachable);
    }
    if (spec.prec) |p| {
        try fmt.appendSlice(a, std.mem.print(&buf, ".{d}", .{p}) catch unreachable);
    } else if (extra_prec) |p| {
        try fmt.appendSlice(a, p);
    }
}

/// `{s}` with the outer alignment, for a field composed in per-op scratch
/// (`.cint`, `.pad`, `.ascii`). `full` marks a field already exactly its width
/// (a zero-filled integer), which no outer alignment may touch.
fn appendStrField(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, full: bool) Error!void {
    const a = g.arena;
    if (full or spec.width == 0) return fmt.appendSlice(a, "{s}");
    var buf: [48]u8 = undefined;
    try fmt.appendSlice(a, std.mem.print(&buf, "{{s:{c}{d}}}", .{
        @as(u8, if (spec.left) '<' else '>'), spec.width,
    }) catch unreachable);
}

/// Appends one conversion's `{…}` to `fmt` and its operand to `ops`.
/// `conv_raw == 0` means the §9.4.3 default: the operand's natural form.
pub fn appendConv(
    g: *Gen,
    fmt: *std.ArrayList(u8),
    ops: *std.ArrayList(PrintArg),
    operand: Mir.Value,
    conv_raw: u8,
    spec_arg: Spec,
) Error!void {
    const a = g.arena;
    const v = operand;
    var bits: u7 = 64;
    if (g.mir.valueDef(g.an.rv(v)) == .inst_result) {
        const inst = g.mir.valueDef(g.an.rv(v)).inst_result;
        const data = g.mir.instData(inst);
        if (data == .call and data.call.callee == .@"$display$width") {
            bits = @intCast(g.mir.valueDef(data.call.args[1]).int_const);
        }
    }
    const conv = std.ascii.toLower(conv_raw);
    const ty = g.an.tyOf(g.an.rv(v));
    // §9.4.3 a bare operand is "the default decimal format"; lowering records a
    // width on one (`decimalWidth`) only when `%d` would size it.
    if (conv == 0 and ty == .int and bits < 64) return appendConv(g, fmt, ops, operand, 'd', spec_arg);
    // IEEE 1364 §17.1.1.3 automatic sizing, for a width lowering recorded: the
    // radices "always" show leading zeros, a decimal field pads with spaces to
    // the largest value's columns, and `%0h`/`%0d` (the '0' flag with no width)
    // "overrides" both.
    var spec = spec_arg;
    if (bits < 64 and spec.width == 0 and !spec.zero and !spec.left and !spec.plus and !spec.space) {
        const max = (@as(u64, 1) << @intCast(bits)) - 1;
        switch (conv) {
            'h', 'x' => spec = .{ .width = (@as(usize, bits) + 3) / 4, .zero = true },
            'o' => spec = .{ .width = (@as(usize, bits) + 2) / 3, .zero = true },
            'b' => spec = .{ .width = bits, .zero = true },
            'd' => spec = .{ .width = std.math.log10_int(max) + 1 },
            else => {},
        }
    }
    switch (conv) {
        // §9.4.3 Table 9-23's four real conversions "have the full formatting
        // capabilities available in the C language"; `%r` adds §2.6.2's
        // engineering notation. One kernel composes the whole field. An
        // integer operand converts to real first (§4.2.1.1).
        'e', 'f', 'g', 'r' => {
            try fmt.appendSlice(a, "{s}");
            try ops.append(a, .{ .v = v, .want = .real, .how = .creal, .spec = spec, .conv = conv_raw });
        },
        // §9.4.3 Table 9-22: a radix conversion shows the operand's
        // two's-complement bit pattern at its width (IEEE 1364 §17.1.1.2):
        // 32 for an `integer` (§3.2, via `$display$width`), 64 for an unsized
        // literal, so `%h` of integer -5 is fffffffb. `.bits` bitcasts to u64
        // because Zig's `{x}` on an i64 writes `-2a`. A real rounds first
        // (§4.2.1.1). An unsigned field has no sign, so the spec passes through.
        'b', 'o', 'h', 'x' => {
            try fmt.append(a, '{');
            try fmt.append(a, if (conv == 'h') 'x' else conv);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .v = v, .want = .int, .how = .bits, .spec = spec, .bits = bits });
        },
        // Table 9-22 gives %c the single character: the operand's low byte,
        // whatever its type (a string goes through its §2.7 integer value).
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
            // §2.7 makes a string literal an unsigned base-256 integer when
            // used as an operand, so `$strobe("%d", "\n")` prints 10;
            // `renderVal(.int)` does the digits.
            const zero_fill = spec.zero and !spec.left and spec.width > 0;
            if (spec.plus or spec.space or zero_fill) {
                // C 7.21.6.1: '+'/' ' put a sign character in the field and
                // '0' packs zeros between sign and digits (`+42`, ` 42`,
                // `-0042`). Zig's `{d:0>5}` writes `00-42`, so the field is
                // composed in scratch (`renderPrintArg`'s .cint arm).
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
            // The Zig verb for the remaining conversions. `conv == 0` is
            // §9.4.3's "default decimal format" in the value's own type
            // (minimal-width, see `buildArgs`); a string prints its text,
            // which every `CHECK` macro's `%s` depends on. `%t`/`%u`/`%z`/`%v`
            // are rows an analog device has no data for; they print the value.
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

/// Emits operand `i` of a print's argument tuple. A real crosses into the
/// format layer through `.val()`. The `.ascii`/`.cint` arms emit labeled block
/// expressions whose scratch is the `zb{i}` array `emitScratch` declared.
pub fn renderPrintArg(g: *Gen, p: PrintArg, i: usize) Error!void {
    switch (p.how) {
        .ascii => {
            // Mask the i64 carrier to the source width so sign extension adds
            // no characters. Only leading zero bytes vanish; interior and
            // trailing NULs are data.
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
            // C 7.21.6.1 sign placement. Zero-fill: zeros go after the sign,
            // so each branch prints its sign and pads |v| to what is left.
            // @abs on an i64 returns u64, so minInt needs no special case.
            // Without zero-fill the outer `{s:>W}` does any padding.
            const sign: []const u8 = if (p.spec.plus) "+" else if (p.spec.space) " " else "";
            const w = p.spec.w();
            const zero_fill = p.spec.zero and !p.spec.left and p.spec.width > 0;
            try g.b("zi{d}: {{ const zv: i64 = ", .{i});
            try g.renderVal(p.v, .int);
            if (zero_fill) {
                // @abs in both branches: Zig spells `+42` for a signed int
                // once a width fixes the field; a u64 has no sign to spell.
                try g.b("; if (zv < 0) break :zi{d} std.fmt.bufPrint(&zb{d}, \"-{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable", .{ i, i, w - 1 });
                try g.b("; break :zi{d} std.fmt.bufPrint(&zb{d}, \"{s}{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable; }}", .{ i, i, sign, w - sign.len });
            } else {
                try g.b("; break :zi{d} std.fmt.bufPrint(&zb{d}, \"{{s}}{{d}}\", .{{ if (zv < 0) \"\" else \"{s}\", zv }}) catch unreachable; }}", .{ i, i, sign });
            }
        },
        .creal => {
            // C11 7.21.6.1's flag bits, in `str_kernels.zCReal`'s order:
            // 1 '-', 2 '+', 4 ' ', 8 '0'. The kernel composes the whole field.
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
                if (p.spec.prec) |pr| @as(i64, @intCast(pr)) else -1,
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
// Tests: the emitted translation, pinned as text. The printed transcripts are
// pinned by tests/fixtures/ch09_system_tasks/170_display_argument_runs.va and
// 171_display_c_format_flags.va.
// ---------------------------------------------------------------------------

const Harness = @import("codegen/test.zig").Harness;

/// One analog block body → the printing artifact's text, in `arena`.
fn emitBody(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const src = try arena.print(
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
    var h: Harness = undefined;
    try Harness.run(arena, src, &h);
    return h.genDisplay(arena);
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

test "§9.4.1 every string argument opens a format run; output concatenates" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Two runs, each consuming its own operand: `a=1b=2`, with no separator
    // anywhere: the second string is a FORMAT, not the first run's operand.
    const two = try emitBody(a, "$strobe(\"a=%d\", 1, \"b=%d\", 2);");
    try std.testing.expect(has(two, "\"a={d}b={d}\\n\""));

    // A string consumed BY a conversion stays an operand: `%s` takes "x",
    // then "y=%d" opens the next run over 2.
    const eaten = try emitBody(a, "$strobe(\"%s;\", \"x\", \"y=%d\", 2);");
    try std.testing.expect(has(eaten, "\"{s};y={d}\\n\""));

    // An expression before the first string prints in the §9.4.3 default,
    // in order: `3.5lead 7`.
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

    // All four conversions become one `zCReal` call and one `{s}`: the kernel
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
    // `%g`; it reaches the same kernel with its own letter.
    const r = try emitBody(a, "$strobe(\"%r\", 1.5);");
    try std.testing.expect(has(r, "'r', 0, 0, -1)"));
}

test "§9.4.3/C11 7.21.6.1: zCReal is the conversion the device runs" {
    // `str_kernels.zig` is spliced into every printing artifact, so these are
    // the renderings a model gets. Each row is a rule of the clause: the %g
    // style choice on both sides of its window, sign/zero-fill placement, the
    // round-half-to-even tie, and §2.6.2's mantissa normalisation.
    // Imported through the `kernels` module: a file may live in one module.
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
    // A DISTINCT site is a distinct latch: two monitors must not mask each
    // other, exactly as two `$sformat` sites must not share a row.
    try std.testing.expectEqualStrings("b\n", k.zMonitor(9002, &.{2}, "b\n").?);
}

test "§9.5.4.2 a scan consumes per DIRECTIVE, and says how much" {
    // `ZScan.used` is what `$fscanf` advances the descriptor by, so these
    // numbers are §9.5.5's `$ftell` answers (see `file_kernels.zFTake`).
    const k = @import("kernels").str_kernels;
    // "The offending input character is left unread": nothing moved, and the
    // return is 0 and not EOF, because the input has not ended.
    const fail = k.zScan("abc\n", "%d", -1);
    try std.testing.expectEqual(@as(i64, 0), fail.n);
    try std.testing.expectEqual(@as(usize, 0), fail.used);
    // "Trailing white space (including newline characters) is left unread
    // unless matched by a directive": the field is two bytes, not the line.
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
    // is returned", and the white space looked through still counts consumed.
    const eof = k.zScan("\n", "%d", -1);
    try std.testing.expectEqual(@as(i64, -1), eof.n);
    try std.testing.expectEqual(@as(usize, 1), eof.used);
    // §9.5.4.2's `%r`, over §2.6.2 Table 2-1: both spellings of the 1e3 row,
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

    // `%+d` of 7 prints `+7`.
    const plus = try emitBody(a, "$strobe(\"%+d\", 7);");
    try std.testing.expect(has(plus, "if (zv < 0) \"\" else \"+\""));

    // A width alone routes through zPadInt (`  -42`, ` 42`).
    const pad = try emitBody(a, "$strobe(\"%5d\", -42);");
    try std.testing.expect(has(pad, "zPadInt(&zb0, "));
    try std.testing.expect(has(pad, "\"{s:>5}\\n\""));
}

test "§9.7 simulation control: the run ends at the call, with the pinned status" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // §9.7.3: $fatal prints its message, then exits with the finish_number as
    // the errorcode (173_fatal_terminates.va checks the run's exit status).
    const fat = try emitBody(a, "$fatal(2, \"died %d\", 7);");
    try std.testing.expect(has(fat, "\"FATAL: died {d}\\n\""));
    try std.testing.expect(has(fat, "_ = zHalt(2); "));
    // ...floored at 1, so a $fatal never reads as success to a shell.
    const fat0 = try emitBody(a, "$fatal(0, \"boom\");");
    try std.testing.expect(has(fat0, "_ = zHalt(1); "));
    // $error stays non-fatal: same severity family, no exit at its call site
    // (the kernel text is present in every printing artifact; the CALL is not).
    const err = try emitBody(a, "$error(\"soft\");");
    try std.testing.expect(!has(err, "_ = zHalt"));

    // §9.7.1: the default diagnostic level is 1 ("prints simulation time and
    // location"), and the exit status is 0: ending the run is the task's
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

    // The kernel is `std.process.exit`, f64-typed so the legal dead code
    // after a terminating call still compiles.
    try std.testing.expect(has(fin, "fn zHalt(code: u8) f64 {\n    std.process.exit(code);\n}"));
}

test "§9.4.3 Table 9-22: %h shows the operand's two's-complement bit pattern" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // An unsized literal keeps 64 bits (§2.6.1), so `%h` of -42 is
    // ffffffffffffffd6; the u64 bitcast stops Zig's `{x}` writing `-2a`.
    // Same for %o and %b.
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
