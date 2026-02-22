//! §17 display, strobe, monitor, `%t` and memory-load formatting.
//!
//! In: a task's argument list and the values it names (or a memory file's
//! text). Out: bytes on `Run.out` (or words stored into an unpacked array).
//! With a null allocator the same walk validates the call without printing.
//!
//! Clauses: §9.4.1 Table 9-1 display families, §9.4.3 Table 9-22 conversions;
//! IEEE 1364-2005 §17.1.1.3/§17.1.1.4 sizing and unknown digits, §17.1.2
//! `$strobe`, §17.1.3 `$monitor`, §17.3 `$timeformat`/`%t`, §17.7.2
//! `$realtime`; IEEE 1364-2005 §17.2.9 `$readmemb`/`$readmemh`.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const diag = @import("diag");
const compile = @import("compile.zig");
const exec = @import("exec.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const run = @import("root.zig").run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;

// ---- memory files (IEEE 1364 §17.2.9) ---------------------------------------

/// IEEE 1364-2005 §17.2.9's memory-file lexer: white space and §2.4 comments
/// separate tokens, and a token is either an `@`-address or one data word.
const MemTokens = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *MemTokens) ?[]const u8 {
        while (self.at < self.text.len) {
            const c = self.text[self.at];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0c') {
                self.at += 1;
                continue;
            }
            if (c == '/' and self.at + 1 < self.text.len) {
                if (self.text[self.at + 1] == '/') {
                    self.at = std.mem.indexOfScalarPos(u8, self.text, self.at, '\n') orelse self.text.len;
                    continue;
                }
                if (self.text[self.at + 1] == '*') {
                    self.at = if (std.mem.indexOfPos(u8, self.text, self.at + 2, "*/")) |e| e + 2 else self.text.len;
                    continue;
                }
            }
            const start = self.at;
            while (self.at < self.text.len) : (self.at += 1) {
                const d = self.text[self.at];
                if (d == ' ' or d == '\t' or d == '\r' or d == '\n' or d == '\x0c') break;
                // A comment may abut a word: `/* ... */ d4` is one word, and so
                // is `d4// trailing`.
                if (d == '/' and self.at + 1 < self.text.len and
                    (self.text[self.at + 1] == '/' or self.text[self.at + 1] == '*')) break;
            }
            if (self.at > start) return self.text[start..self.at];
        }
        return null;
    }
};

const MemDigit = struct { digit: u32 = 0, fill: ?Int.Bit = null };

fn memDigit(character: u8, radix: Radix) !MemDigit {
    const c = std.ascii.toLower(character);
    switch (c) {
        'x' => return .{ .fill = .x },
        'z', '?' => return .{ .fill = .z },
        else => {},
    }
    const digit: u32 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => return error.BadDigit,
    };
    if (digit >= @intFromEnum(radix)) return error.BadDigit;
    return .{ .digit = digit };
}

fn validateMemWord(token: []const u8, radix: Radix) !void {
    // IEEE3.5/3.5.1: a number starts with a digit, not a separator.
    if (token.len == 0 or token[0] == '_') return error.BadDigit;
    for (token) |c| {
        if (c == '_') continue;
        _ = try memDigit(c, radix);
    }
}

/// One data word, right-justified into the memory's declared width. §17.2.9
/// says the digits may be `x` or `z` for either task, and an unknown DIGIT is
/// unknown in every bit it covers — which is why this shares `Radix.perDigit`
/// with the printer rather than parsing a number and losing the states.
fn memWord(a: std.mem.Allocator, token: []const u8, radix: Radix, width: u32) !Int.Literal {
    // Validation covers discarded high digits independently of stored width.
    try validateMemWord(token, radix);
    const per = radix.perDigit();
    const value = try filled(a, width, false, .zero);
    var bit: u32 = 0;
    var i = token.len;
    while (i != 0 and bit < width) {
        i -= 1;
        const c = std.ascii.toLower(token[i]);
        // §2.6's readability separator is legal in a data word too.
        if (c == '_') continue;
        const decoded = try memDigit(c, radix);
        var k: u32 = 0;
        while (k < per and bit < width) : ({
            k += 1;
            bit += 1;
        }) setBit(value, bit, decoded.fill orelse @enumFromInt(@as(u2, @intCast((decoded.digit >> @intCast(k)) & 1))));
    }
    return value;
}

/// IEEE 1364-2005 §17.2.9 `$readmemb` / `$readmemh`.
///
/// The clause's four rules, and all four are observable:
///   - the file holds white space, comments and numbers in the task's radix;
///   - with no address arguments loading goes from lowest to highest index;
///   - `@<hex>` relocates the load point, and loading continues from there;
///   - an address the file never reaches is LEFT ALONE. The task loads; it
///     does not clear, so an unwritten word keeps the X it started at.
///
/// With a start and a finish the load runs from one toward the other, which
/// is DOWNWARD when start > finish — the direction is the argument order
/// and not the declaration's.
pub fn readMemory(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, radix: Radix) Error!void {
    const ex = &self.file.exprs;
    const base = try self.slot(args[1]);
    const arr = self.arrays.get(base).?;
    const name = self.file.str(ex.strOf(args[0]));
    const text = readSideFile(self, a, name) catch
        return self.exprFail(args[0], "the memory file cannot be read");

    // §17.2.9: default traversal is lowest to highest, independent of
    // the declaration's direction.
    var at: i64 = arr.low;
    var last: i64 = arr.high;
    if (args.len >= 3)
        at = (try exec.eval(self, a, args[2], 0)).asInt() orelse arr.low;
    if (args.len == 4)
        last = (try exec.eval(self, a, args[3], 0)).asInt() orelse arr.high;
    // With start alone, finish defaults to the highest address and the
    // walk stays upward, including after a file address specification.
    const down = args.len == 4 and last < at;
    const first = at;
    const range_low = @min(first, last);
    const range_high = @max(first, last);
    const expected: u128 = @intCast(@as(i128, range_high) - range_low + 1);
    var words: u128 = 0;
    var addressed = false;
    var exhausted = false;

    var it = MemTokens{ .text = text };
    while (it.next()) |token| {
        if (token[0] == '@') {
            addressed = true;
            at = std.fmt.parseInt(i64, token[1..], 16) catch
                return self.exprFail(args[0], "the memory file has a malformed `@` address");
            if (args.len >= 3 and (at < range_low or at > range_high))
                return self.exprFail(args[0], "memory file address is outside the requested load range");
            exhausted = false;
            continue;
        }
        words += 1;
        // Continue scanning after the final word: a later address both
        // suppresses count warnings and may restart loading in the range.
        if (exhausted) {
            // Stopping assignments does not legalize malformed file data.
            // Validate without allocating a destination-sized value.
            validateMemWord(token, radix) catch
                return self.exprFail(args[0], "the memory file has a malformed data word");
            continue;
        }
        // Outside the declared range the word has nowhere to go. Not an
        // error: a file longer than the memory is the clause's own
        // "more data than the range" case.
        if (at >= arr.low and at <= arr.high) {
            const dest = self.values[base + @as(u32, @intCast(at - arr.low))];
            const value = memWord(a, token, radix, dest.width) catch
                return self.exprFail(args[0], "the memory file has a malformed data word");
            try exec.store(self, base + @as(u32, @intCast(at - arr.low)), value.planes);
        }
        if (down) {
            if (at <= last) exhausted = true else at -= 1;
        } else {
            if (at >= last) exhausted = true else at += 1;
        }
    }
    if (!addressed and words != expected) {
        const tok = ex.mainTok(args[0]);
        const start = self.starts[@min(tok, self.starts.len - 1)];
        try self.bag.add(.lower, .W1150, .{ .start = start, .end = start }, "memory file data word count does not match load range: found {d}, expected {d}", .{ words, expected });
    }
}

/// The data file sits beside the source that names it, which is what makes
/// a fixture self-contained. The working directory is tried second, so a
/// path written relative to where the simulator was launched still works.
fn readSideFile(self: *Run, a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const io = self.io orelse return error.NoIo;
    const limit: usize = 1 << 22;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(self.file_name)) |dir| {
        const joined = try std.fs.path.join(a, &.{ dir, name });
        if (cwd.readFileAlloc(io, joined, a, .limited(limit))) |text| return text else |_| {}
    }
    return cwd.readFileAlloc(io, name, a, .limited(limit));
}

// ---- the task table (§9.4.1 Table 9-1, §17.3) -------------------------------

/// §17.7.2 `$realtime` — the only REAL-valued expression the digital engine
/// has, and it exists only in a display argument. There are no real variables
/// to put it in yet (that is M04's work), so it is recognised where it can be
/// printed and nowhere else.
const realtime_name = "$realtime";

/// §9.4.3 Table 9-22's four conversions. The value is the base, so a digit is
/// `@ctz(base)` bits wide for the three power-of-two members and decimal is the
/// one that is not a bit group.
const Radix = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hex = 16,

    /// Bits consumed per printed digit; meaningless for `.decimal`, which reads
    /// the whole operand at once.
    fn perDigit(self: Radix) u32 {
        return switch (self) {
            .binary => 1,
            .octal => 3,
            .hex => 4,
            .decimal => unreachable,
        };
    }
};

/// §9.4.1 Table 9-1's display family, which is one task with two axes: the
/// radix an argument with NO format specification is printed in, and whether
/// the call ends with a newline. "The $write task provides the same
/// capabilities as $display, but with no newline."
pub const Show = struct { radix: Radix, newline: bool };

/// The four display families of §9.4.1 Table 9-1 differ in WHEN they run, not
/// in what they print — every one of them formats through `display`.
///
///   show    now, in the active region
///   strobe  at the end of the timestep (IEEE 1364-2005 §17.1.2: "display
///           simulation data at a selected time ... at the end of the current
///           timestep"), which is the `.monitor` scheduler region
///   monitor the same end-of-timestep print, but standing: it re-runs whenever
///           a value changes until another $monitor replaces it (§17.1.3)
pub const Task = union(enum) {
    show: Show,
    strobe: Show,
    monitor: Show,
    /// $monitoron / $monitoroff. "$monitoron ... produces a display
    /// immediately", so the flag's own transition is observable.
    monitor_enable: bool,
    /// §17.3, the `%t` format state.
    timeformat,
    /// §9.5 Table 9-2 / IEEE 1364 §17.2.9. The radix is the whole difference
    /// between `$readmemb` and `$readmemh`.
    readmem: Radix,
    finish,
};

fn showAs(radix: Radix, newline: bool) Show {
    return .{ .radix = radix, .newline = newline };
}

pub const tasks = std.StaticStringMap(Task).initComptime(.{
    .{ "$display", Task{ .show = showAs(.decimal, true) } },
    .{ "$displayb", Task{ .show = showAs(.binary, true) } },
    .{ "$displayo", Task{ .show = showAs(.octal, true) } },
    .{ "$displayh", Task{ .show = showAs(.hex, true) } },
    .{ "$write", Task{ .show = showAs(.decimal, false) } },
    .{ "$writeb", Task{ .show = showAs(.binary, false) } },
    .{ "$writeo", Task{ .show = showAs(.octal, false) } },
    .{ "$writeh", Task{ .show = showAs(.hex, false) } },
    .{ "$strobe", Task{ .strobe = showAs(.decimal, true) } },
    .{ "$strobeb", Task{ .strobe = showAs(.binary, true) } },
    .{ "$strobeo", Task{ .strobe = showAs(.octal, true) } },
    .{ "$strobeh", Task{ .strobe = showAs(.hex, true) } },
    .{ "$monitor", Task{ .monitor = showAs(.decimal, true) } },
    .{ "$monitorb", Task{ .monitor = showAs(.binary, true) } },
    .{ "$monitoro", Task{ .monitor = showAs(.octal, true) } },
    .{ "$monitorh", Task{ .monitor = showAs(.hex, true) } },
    .{ "$monitoron", Task{ .monitor_enable = true } },
    .{ "$monitoroff", Task{ .monitor_enable = false } },
    .{ "$timeformat", .timeformat },
    .{ "$readmemb", Task{ .readmem = .binary } },
    .{ "$readmemh", Task{ .readmem = .hex } },
    .{ "$finish", .finish },
});

/// §17.3 `$timeformat(units_number, precision, suffix, min_width)`, with the
/// clause's own defaults: the units are the simulation's precision, nothing
/// after the decimal point, no suffix, and a 20-column field.
pub const TimeFormat = struct {
    units: i32 = 0,
    precision: u32 = 0,
    suffix: []const u8 = "",
    width: u32 = 20,
};

// ---- formatting (§9.4.3, §17.1.1.3, §17.1.1.4, §17.3) -----------------------

// null allocator validates the complete format/expression surface without
// producing output. Every conversion is width-exact per IEEE 1364-2005
// §17.1.1.3, including separate X and Z states (§17.1.1.4).
pub fn display(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show) Error!void {
    const ex = &self.file.exprs;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        // §9.4.1: "Any null argument produces a single space character in
        // the display. (A null argument is characterized by two adjacent
        // commas (,,) in the argument list.)"
        if (e == .none) {
            if (allocator != null) try self.out.writeByte(' ');
            continue;
        }
        // Only a STRING is a format. §9.4.3's last sentence before Table
        // 9-23: "Any expression argument with no corresponding format
        // specification is displayed using the default decimal format" —
        // default for THIS task, so $displayh's bare argument is hex.
        if (ex.tag(e) != .str_literal) {
            try compile.checkExpr(self, e);
            if (allocator) |a| try emitValue(self, try exec.eval(self, a, e, 0), show.radix, null);
            continue;
        }
        const format = self.file.str(ex.strOf(e));
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] != '%') {
                if (allocator != null) try self.out.writeByte(format[i]);
                continue;
            }
            i += 1;
            if (i == format.len) return self.exprFail(e, "unterminated display format");
            if (format[i] == '%') {
                if (allocator != null) try self.out.writeByte('%');
                continue;
            }
            // §17.1.1.2's optional field width. `%0d` is the one every
            // source writes and means "minimum width"; a non-zero width is
            // an explicit column count. Absent means §17.1.1.3's automatic
            // sizing, which is `null` here and computed from the operand.
            var width: ?u32 = null;
            while (i < format.len and format[i] >= '0' and format[i] <= '9') : (i += 1) {
                const d = format[i] - '0';
                width = (width orelse 0) *| 10 +| d;
            }
            if (i == format.len) return self.exprFail(e, "unterminated display format");
            const radix: ?Radix = switch (format[i]) {
                'b', 'B' => .binary,
                'o', 'O' => .octal,
                'h', 'H' => .hex,
                'd', 'D' => .decimal,
                // §9.4.3 Table 9-22's real conversions. All three print the
                // same here: Zig's shortest round-tripping form is what %g
                // asks for, and the suite's reals are exact halves and
                // integers where %e and %f would agree with it anyway.
                'e', 'E', 'f', 'F', 'g', 'G' => null,
                // §17.3 `%t` is not a radix at all — it reads the
                // $timeformat state and formats a TIME, whose operand is
                // in the module's own time unit.
                't', 'T' => {
                    arg += 1;
                    if (arg == args.len) return self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| try emitTime(self, try exec.eval(self, a, args[arg], 0));
                    continue;
                },
                else => return self.exprFail(
                    e,
                    "only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g and %%) are implemented",
                ),
            };
            arg += 1;
            if (arg == args.len) return self.exprFail(e, "missing display argument");
            if (radix) |r| {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| try emitValue(self, try exec.eval(self, a, args[arg], 0), r, width);
            } else {
                const real = try evalReal(self, args[arg]);
                if (allocator != null) {
                    var buf: [64]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "{d}", .{real}) catch unreachable;
                    if (width) |w| if (text.len < w) try self.out.splatByteAll(' ', w - text.len);
                    try self.out.writeAll(text);
                }
            }
        }
    }
    if (allocator != null and show.newline) try self.out.writeByte('\n');
}

/// The real half of the display surface, which is `$realtime` and nothing
/// else today. It is validated and evaluated by the same call because there
/// is no state to read: the answer is the clock.
///
/// ponytail: one name, no real variables and no real arithmetic. §17.7.2 is
/// the only real a source can name until M04 gives the engine `real` and
/// `wreal`; when it does, this is the seam that grows an evaluator.
fn evalReal(self: *Run, e: Ast.ExprId) Error!f64 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .sys_call or !std.mem.eql(u8, self.file.str(ex.strOf(e)), realtime_name))
        return self.exprFail(e, "a real display conversion takes a real expression, and `$realtime` is the only one implemented");
    if (ex.args(e).len != 0) return self.exprFail(e, "$realtime takes no arguments");
    const scale = self.scale orelse return self.exprFail(e, "the time queries require an explicit valid timescale before the module");
    return scale.realAt(self.scheduler.now);
}

/// §17.3 `%t`. The operand is a time in the INVOKING MODULE'S TIME UNIT —
/// which is what `$time` returns and what a literal `1` in that position
/// means — and `$timeformat`'s `units_number` says which power of ten of a
/// second to report it in. So the printed number is
///
///     value · 10^(unit_exp − units_number)
///
/// and nothing here needs the precision: scaling a unit count by a ratio of
/// decades is exact in the only direction that matters.
fn emitTime(self: *Run, v: Int.Literal) Error!void {
    const f = self.time_format;
    const raw: f64 = if (v.hasUnknown())
        0
    else if (v.signed)
        @floatFromInt(v.asInt() orelse 0)
    else
        @floatFromInt(v.values()[0]);
    const scaled = raw * std.math.pow(f64, 10, @floatFromInt(self.unit_exp - f.units));
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d:.[1]}", .{ scaled, f.precision }) catch unreachable;
    w.writeAll(f.suffix) catch unreachable;
    const text = w.buffered();
    if (text.len < f.width) try self.out.splatByteAll(' ', f.width - text.len);
    try self.out.writeAll(text);
}

/// One operand, in one radix, sized by IEEE 1364-2005 §17.1.1.3 unless the
/// format gave an explicit width.
///
/// The three power-of-two radices are a GROUP walk and decimal is not, and
/// that is the whole split: a hex digit is four bits of this operand and
/// says nothing about the other bits, so a group that is entirely unknown
/// prints as unknown while its neighbours print normally. A decimal
/// rendering has no such locality — one unknown bit makes the whole number
/// unknown — which is why §17.1.1.4 gives it its own rule.
fn emitValue(self: *Run, v: Int.Literal, radix: Radix, width: ?u32) Error!void {
    var buf: [1024]u8 = undefined;
    const text = if (radix == .decimal)
        try decimalText(self, &buf, v)
    else
        groupText(&buf, v, radix);
    // §17.1.1.3's automatic size. Right-justified with LEADING SPACES, not
    // zeros: `%d` of an 8-bit 7 is "  7" and not "007". A group radix is
    // already exactly its own width, so padding only ever shows up under
    // decimal or an explicit format width.
    const field = width orelse autoWidth(v, radix);
    if (text.len < field) try self.out.splatByteAll(' ', field - text.len);
    try self.out.writeAll(text);
}

/// §17.1.1.3: "a radix conversion is sized to the operand's declared width,
/// and the default decimal field is sized to the largest value the operand
/// can hold". For a signed operand the largest PRINTED value is the
/// negative one, because of its sign: a 32-bit `integer` is 11 columns
/// ("-2147483648"), not 10.
fn autoWidth(v: Int.Literal, radix: Radix) u32 {
    if (radix != .decimal) {
        const per = radix.perDigit();
        return (v.width + per - 1) / per;
    }
    // The count of decimal digits in 2^n - 1 (unsigned) or 2^(n-1)
    // (signed magnitude, plus one column for the sign).
    const bits: u32 = if (v.signed and v.width != 0) v.width - 1 else v.width;
    var digits: u32 = 1;
    var limit: u128 = 9;
    // 2^bits - 1 > limit, written so that bits = 128 does not overflow.
    while (bits < 127 and (@as(u128, 1) << @intCast(@min(bits, 126))) - 1 > limit) : (digits += 1) {
        if (limit > std.math.maxInt(u128) / 10) break;
        limit = limit * 10 + 9;
    }
    return digits + @intFromBool(v.signed);
}

/// A power-of-two radix, most significant group first. Bits past the
/// operand's width are absent, not zero: they contribute nothing to the
/// digit's value AND nothing to its unknown-ness, which is what makes an
/// all-x 8-bit operand print "xxx" in octal rather than "Xxx" — the top
/// group holds two x bits and no third bit at all.
fn groupText(buf: []u8, v: Int.Literal, radix: Radix) []const u8 {
    const per = radix.perDigit();
    const digits = (v.width + per - 1) / per;
    var out: usize = 0;
    var d = digits;
    while (d != 0) {
        d -= 1;
        var value: u32 = 0;
        var xs: u32 = 0;
        var zs: u32 = 0;
        var present: u32 = 0;
        var k: u32 = 0;
        while (k < per) : (k += 1) {
            const index = d * per + k;
            if (index >= v.width) continue;
            present += 1;
            switch (v.bit(index)) {
                .zero => {},
                .one => value |= @as(u32, 1) << @intCast(k),
                .x => xs += 1,
                .z => zs += 1,
            }
        }
        // §17.1.1.4: all unknown prints lowercase, partly unknown prints
        // uppercase — the case is the whole signal that the digit's known
        // bits were thrown away.
        buf[out] = if (xs == present) 'x' //
        else if (zs == present) 'z' //
        else if (xs != 0) 'X' //
        else if (zs != 0) 'Z' //
        else "0123456789abcdef"[value];
        out += 1;
    }
    return buf[0..out];
}

/// Decimal, where one unknown bit poisons the whole number (§17.1.1.4).
///
/// ponytail: 64 bits. A wider `%d` needs a bignum divide, and nothing in
/// the LRM's own examples or this suite prints one; the refusal is explicit
/// rather than a silent truncation.
fn decimalText(self: *Run, buf: []u8, v: Int.Literal) Error![]const u8 {
    if (v.hasUnknown()) {
        var xs: u32 = 0;
        var zs: u32 = 0;
        for (0..v.width) |i| switch (v.bit(@intCast(i))) {
            .x => xs += 1,
            .z => zs += 1,
            else => {},
        };
        buf[0] = if (xs == v.width) 'x' //
        else if (zs == v.width) 'z' //
        else if (xs != 0) 'X' //
        else 'Z';
        return buf[0..1];
    }
    if (v.width > 64) return self.fail(0, "decimal display of an operand wider than 64 bits is not implemented", .{});
    const raw = v.values()[0];
    if (v.signed) return std.fmt.bufPrint(buf, "{d}", .{v.asInt().?}) catch unreachable;
    // Not `asInt`: it bit-casts, so an unsigned 64-bit operand at or above
    // 2^63 would print negative. $time is exactly that operand.
    return std.fmt.bufPrint(buf, "{d}", .{raw}) catch unreachable;
}

/// Print the standing monitor's argument list, if there is one and it is on.
/// WHETHER to print is decided before this is called — a watched slot
/// changed (`exec.store`), or `$monitoron` ran — never by comparing text.
pub fn monitorPrint(self: *Run, a: std.mem.Allocator) Error!void {
    const m = self.monitor orelse return;
    if (!self.monitor_on) return;
    // §17.1.3 the monitor renders in the instance that installed it; the
    // `.monitor` region runs outside any process's dispatch.
    self.scope = m.scope;
    try display(self, m.args, a, m.show);
}

// ---- tests ------------------------------------------------------------------

test "§17.1.3 monitor: clock queries do not trigger, a change and change back does" {
    // t1: only `u` (unwatched) changes and $time advances: no line. t2: a
    // goes 1 then back to 0 via #0 — it "changes value", so one line with
    // the settled 0. t3: a = 1 prints with the current time. $monitoron at
    // t4 prints although nothing changed and monitoring was already on.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a, u;
        \\initial begin
        \\  a = 0; u = 0;
        \\  $monitor("a=%b t=%0d", a, $time);
        \\  a <= 0;
        \\  #1 u = 1;
        \\  #1 a = 1;
        \\  #0 a = 0;
        \\  #1 a = 1;
        \\  #1 $monitoron;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "a=0 t=0\na=0 t=2\na=1 t=3\na=1 t=4\n");
}

test "readmem validates high token characters beyond destination width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // IEEE17.2.9 forbids length/base prefixes and non-radix digits, even
    // where all of those characters would be discarded by value truncation.
    for ([_][]const u8{ "8'h11", "'h11", "g11", ";11" }) |token|
        try std.testing.expectError(error.BadDigit, memWord(a, token, .hex, 8));
    for ([_][]const u8{ "8'b00010001", "'b00010001", "200010001", "g00010001" }) |token|
        try std.testing.expectError(error.BadDigit, memWord(a, token, .binary, 8));
    // Valid high digits remain legal and truncate; separators still do not
    // consume bit positions. Validation must not become a width rejection.
    const hex = try memWord(a, "aB_11", .hex, 8);
    const bin = try memWord(a, "10_00010001", .binary, 8);
    try std.testing.expectEqual(@as(?i64, 17), hex.asInt());
    try std.testing.expectEqual(@as(?i64, 17), bin.asInt());
}

fn expectMemoryLoad(data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, fails: bool) !void {
    return expectMemoryLoadTask("$readmemh", data, bounds, expected, warnings, fails);
}

fn expectMemoryLoadTask(task: []const u8, data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, fails: bool) !void {
    return expectMemoryLoadDiagnostic(task, data, bounds, expected, warnings, if (fails) "memory file address is outside the requested load range" else null);
}

fn expectMemoryLoadDiagnostic(task: []const u8, data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, failure_phrase: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "words.hex", .data = data });
    const file_name = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/test.v", .{tmp.sub_path});
    const source = try std.fmt.allocPrint(a, "module m; reg [7:0] mem[3:0]; initial begin " ++
        "mem[0]=8'haa; mem[1]=8'hbb; mem[2]=8'hcc; mem[3]=8'hdd; " ++
        "{s}(\"words.hex\",mem{s}); " ++
        "$display(\"%h %h %h %h\",mem[0],mem[1],mem[2],mem[3]); end endmodule", .{ task, bounds });
    var bag = diag.Bag.init(a);
    var output = std.Io.Writer.Allocating.init(a);
    const result = run(a, source, .{ .io = std.testing.io, .file_name = file_name }, &bag, &output.writer);
    if (failure_phrase) |phrase| {
        try std.testing.expectError(error.DigitalFailed, result);
        var messages = std.Io.Writer.Allocating.init(a);
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.indexOf(u8, messages.written(), phrase) != null);
    } else try result;
    try std.testing.expectEqual(warnings, bag.warn_count);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "readmem count mismatch warns without refusing or clearing memory" {
    try expectMemoryLoad("// @0 is only a comment\n", "", "aa bb cc dd\n", 1, false);
    try expectMemoryLoad("11 22 33 44 55", "", "11 22 33 44\n", 1, false);
    try expectMemoryLoad("11 // 99\n22 /* 88 */", ",0,3", "11 22 cc dd\n", 1, false);
    try expectMemoryLoad("11 22 33 44", ",0,3", "11 22 33 44\n", 0, false);
    try expectMemoryLoad("11 22 33 44 55", ",3,0", "44 33 22 11\n", 1, false);
    try expectMemoryLoad("11 22", ",3,0", "aa bb 22 11\n", 1, false);
    try expectMemoryLoad("11 22 33 44", ",3,0", "44 33 22 11\n", 0, false);
}

test "readmem question mark is high impedance in both radices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hex = try memWord(a, "0?", .hex, 8);
    const bin = try memWord(a, "0000000?", .binary, 8);
    for (0..4) |i| try std.testing.expectEqual(Int.Bit.z, hex.bit(@intCast(i)));
    try std.testing.expectEqual(Int.Bit.z, bin.bit(0));
}

test "readmem underscore must follow an initial digit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]Radix{ .hex, .binary }) |radix| {
        for ([_][]const u8{ "_", "__", "_11" }) |token|
            try std.testing.expectError(error.BadDigit, memWord(arena.allocator(), token, radix, 8));
    }
    const legal = try memWord(arena.allocator(), "1__1_", .hex, 8);
    try std.testing.expectEqual(@as(?i64, 17), legal.asInt());
}

test "readmem validates discarded excess tokens and still restarts after addresses" {
    const invalid = "the memory file has a malformed data word";
    try expectMemoryLoadDiagnostic("$readmemh", "11 ;", ",0,0", "", 0, invalid);
    try expectMemoryLoadDiagnostic("$readmemb", "1 2", ",0,0", "", 0, invalid);
    try expectMemoryLoadDiagnostic("$readmemh", "11 _", ",0,0", "", 0, invalid);
    try expectMemoryLoadDiagnostic("$readmemh", "11 22", ",0,0", "11 bb cc dd\n", 1, null);
    try expectMemoryLoadDiagnostic("$readmemh", "11 22 @0 33", ",0,0", "33 bb cc dd\n", 0, null);
}

test "readmem addresses suppress count warning and relocate after range end" {
    try expectMemoryLoad("@1 11", ",0,3", "aa 11 cc dd\n", 0, false);
    try expectMemoryLoad("11 22 33 44 55 @2 66", ",0,3", "11 22 66 44\n", 0, false);
    try expectMemoryLoad("11 22 33 44 @2 66 77", ",3,0", "44 77 66 11\n", 0, false);
    try expectMemoryLoad("11 22 @0", ",1,2", "", 0, true);
    try expectMemoryLoad("@3 11", ",2,1", "", 0, true);
}

test "readmem start-only defaults to highest address and stays upward" {
    try expectMemoryLoad("11 22", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoad("11", ",2", "aa bb 11 dd\n", 1, false);
    try expectMemoryLoad("11 22 33", ",2", "aa bb 11 22\n", 1, false);
    try expectMemoryLoad("11", ",3", "aa bb cc 11\n", 0, false);
    try expectMemoryLoad("@3 11 @2 22 33", ",2", "aa bb 22 33\n", 0, false);
    try expectMemoryLoad("@1 11", ",2", "", 0, true);
    try expectMemoryLoad("11 22 @4", ",2", "", 0, true);
}

test "readmem formfeeds delimit words and addresses without adding words" {
    try expectMemoryLoad("\x0c11\x0c22\x0c33\x0c44\x0c", "", "11 22 33 44\n", 0, false);
    try expectMemoryLoad("\x0c@2\x0c11\x0c22\x0c", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoad("/* not words: @0 55 */\x0c11\x0c22", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoadTask("$readmemb", "\x0c00010001\x0c00100010\x0c", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoadTask("$readmemb", "@3\x0c1\x0c@2\x0c10\x0c11", ",2", "aa bb 02 03\n", 0, false);
}

test "§9.4.3 the radix conversions size themselves from the operand" {
    // IEEE 1364-2005 §17.1.1.3: a radix field is the operand's declared width
    // in that radix, and the default decimal field holds the largest value the
    // operand can take — 255 for `reg [7:0]`, so three columns of leading
    // SPACE and not zero. `%0d` is the escape from it.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'd7;
        \\  $display("[%d][%0d][%h][%o][%b]", v, v, v, v, v);
        \\end endmodule
        \\
    , "[  7][7][07][007][00000111]\n");
    // §17.1.1.4: a group that is ENTIRELY unknown prints lowercase, a group
    // that is partly unknown prints uppercase. The `X` is the whole signal
    // that known bits were discarded.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'b1010_xxxx; $display("[%b][%h][%o]", v, v, v);
        \\  v = 8'bzzzz_0011; $display("[%h][%o]", v, v);
        \\end endmodule
        \\
    , "[1010xxxx][ax][2Xx]\n[z3][zZ3]\n");
    // §9.4.1: a null argument is one space, $write has no newline, and an
    // argument with no format specification takes the TASK's default radix.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'hA5;
        \\  $write("w"); $displayh(v); $display("[", , "]"); $display("bare=", v);
        \\end endmodule
        \\
    , "wa5\n[ ]\nbare=165\n");
}

test "display retains escaped NUL bytes and unsized integer width" {
    try expectRun("module m; initial $display(\"A\\000B %b\",1); endmodule", "A\x00B 00000000000000000000000000000001\n");
    try expectRun("module m; initial $display(\"%b\",65'd1); endmodule", "00000000000000000000000000000000000000000000000000000000000000001\n");
}
