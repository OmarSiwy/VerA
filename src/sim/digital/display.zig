//! §17 display, strobe, monitor, `%t` and memory-load formatting: a task's
//! arguments and the values they name (or a memory file's text) in; bytes on
//! `Run.out` (or words stored into an unpacked array) out. With a null
//! allocator the same walk validates the call without printing.
//! Clauses: §9.4.1 Table 9-1, §9.4.3 Table 9-22; IEEE 1364-2005 §17.1.1.3,
//! §17.1.1.4, §17.1.2, §17.1.3, §17.2.9, §17.3, §17.7.2.
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
const Signal = @import("net.zig").Signal;
const netPull = @import("net.zig").netPull;
/// §9.4.3 Table 9-23's C conversion, the one the analog devices run.
const zCReal = @import("kernels").str_kernels.zCReal;
const system = @import("system.zig");
const fmt = @import("../fmt.zig");

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
/// says the digits may be `x` or `z` for either task, and an unknown digit is
/// unknown in every bit it covers, so this shares `Radix.perDigit` with the
/// printer rather than parsing a number and losing the states.
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

/// IEEE 1364-2005 §17.2.9 `$readmemb` / `$readmemh` over a memory file's
/// text: each `next` is one word to store, in file order. The one load walk
/// the interpreter and a native executable share.
///
/// The clause's rules:
///   - the file holds white space, comments and numbers in the task's radix;
///   - with no address arguments loading goes from lowest to highest index;
///   - `@<hex>` relocates the load point, and loading continues from there;
///   - an address the file never reaches is left alone: an unwritten word
///     keeps the x it started at.
///
/// With a start and a finish the load runs from one toward the other,
/// downward when start > finish: the direction is the argument order, not
/// the declaration's.
pub const MemLoad = struct {
    it: MemTokens,
    radix: Radix,
    /// Every element's width, and the array's declared index range.
    width: u32,
    low: i64,
    high: i64,
    at: i64,
    last: i64,
    down: bool,
    /// A start argument was given: a file address must lie in the range.
    bounded: bool,
    range_low: i64,
    range_high: i64,
    words: u128 = 0,
    addressed: bool = false,
    exhausted: bool = false,

    /// One word: element `index` (from the lowest declared address) takes
    /// `value`, `width` bits wide.
    pub const Word = struct { index: u32, value: Int.Literal };

    pub const Failure = error{ BadAddress, AddressOutOfRange, BadWord } || std.mem.Allocator.Error;

    /// `given` is how many of the start and finish arguments the call has;
    /// `start`/`finish` are their values, null where x or z.
    pub fn init(text: []const u8, radix: Radix, width: u32, low: i64, high: i64, given: u2, start: ?i64, finish: ?i64) MemLoad {
        // §17.2.9: default traversal is lowest to highest, independent of
        // the declaration's direction.
        const at = if (given >= 1) start orelse low else low;
        const last = if (given == 2) finish orelse high else high;
        // With start alone, finish defaults to the highest address and the
        // walk stays upward, including after a file address specification.
        return .{
            .it = .{ .text = text },
            .radix = radix,
            .width = width,
            .low = low,
            .high = high,
            .at = at,
            .last = last,
            .down = given == 2 and last < at,
            .bounded = given >= 1,
            .range_low = @min(at, last),
            .range_high = @max(at, last),
        };
    }

    /// The next word to store, or null at the end of the file. A word
    /// outside the declared range is dropped.
    pub fn next(self: *MemLoad, a: std.mem.Allocator) Failure!?Word {
        while (self.it.next()) |token| {
            if (token[0] == '@') {
                self.addressed = true;
                self.at = std.fmt.parseInt(i64, token[1..], 16) catch return error.BadAddress;
                if (self.bounded and (self.at < self.range_low or self.at > self.range_high)) return error.AddressOutOfRange;
                self.exhausted = false;
                continue;
            }
            self.words += 1;
            // Continue scanning after the final word: a later address both
            // suppresses count warnings and may restart loading in the range.
            if (self.exhausted) {
                // Stopping assignments does not legalize malformed file data.
                // Validate without allocating a destination-sized value.
                validateMemWord(token, self.radix) catch return error.BadWord;
                continue;
            }
            const at = self.at;
            if (self.down) {
                if (self.at <= self.last) self.exhausted = true else self.at -= 1;
            } else {
                if (self.at >= self.last) self.exhausted = true else self.at += 1;
            }
            // Outside the declared range the word has nowhere to go. Not an
            // error: a file longer than the memory is the clause's own
            // "more data than the range" case.
            if (at < self.low or at > self.high) continue;
            // `filled` fails only for want of memory.
            const value = memWord(a, token, self.radix, self.width) catch |e|
                return if (e == error.BadDigit) error.BadWord else error.OutOfMemory;
            return .{ .index = @intCast(at - self.low), .value = value };
        }
        return null;
    }

    /// Once `next` returned null: the words found and the range expected
    /// when they differ with no address in the file, which §17.2.9 says
    /// warrants a warning (W1150).
    pub fn mismatch(self: *const MemLoad) ?struct { found: u128, expected: u128 } {
        const expected: u128 = @intCast(@as(i128, self.range_high) - self.range_low + 1);
        if (self.addressed or self.words == expected) return null;
        return .{ .found = self.words, .expected = expected };
    }

    /// The diagnostic text of `e`, shared by both engines.
    pub fn message(e: Failure) []const u8 {
        return switch (e) {
            error.BadAddress => "the memory file has a malformed `@` address",
            error.AddressOutOfRange => "memory file address is outside the requested load range",
            error.BadWord => "the memory file has a malformed data word",
            error.OutOfMemory => "out of memory",
        };
    }

    /// The W1150 text; the arguments are `found` then `expected`.
    pub const mismatch_text = "memory file data word count does not match load range: found {d}, expected {d}";
};

/// The interpreter's `$readmemb` / `$readmemh` (`MemLoad`).
pub fn readMemory(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, radix: Radix) Error!void {
    const ex = &self.file.exprs;
    const base = try self.slot(args[1]);
    const arr = self.arrays.get(base).?;
    const name = self.file.str(ex.strOf(args[0]));
    const text = readSideFile(self, a, name) catch |e| return if (e == error.StreamTooLong)
        self.exprFail(args[0], too_large)
    else
        self.exprFail(args[0], "the memory file cannot be read");
    const start = if (args.len >= 3) (try exec.eval(self, a, args[2], 0)).asInt() else null;
    const finish = if (args.len == 4) (try exec.eval(self, a, args[3], 0)).asInt() else null;
    var load: MemLoad = .init(text, radix, self.values[base].width, arr.low, arr.high, @intCast(args.len - 2), start, finish);
    while (load.next(a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |f| return self.fail(ex.mainTok(args[0]), "{s}", .{MemLoad.message(f)}),
    }) |w| try exec.store(self, base + w.index, w.value.planes);
    if (load.mismatch()) |m| {
        const tok = ex.mainTok(args[0]);
        const at = self.starts[@min(tok, self.starts.len - 1)];
        try self.bag.add(.lower, .W1150, .{ .start = at, .end = at }, MemLoad.mismatch_text, .{ m.found, m.expected });
    }
}

/// The data file sits beside the source that names it, which is what makes
/// a fixture self-contained. The working directory is tried second, so a
/// path written relative to where the simulator was launched still works.
pub fn readSideFile(self: *Run, a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return sideFile(self.io orelse return error.NoIo, a, self.file_name, name);
}

/// `sideFile`'s cap. IEEE 1364-2005 §17.2.9 bounds no memory file.
pub const side_file_limit: usize = 1 << 22;
/// The refusal past `side_file_limit`, which `sideFile` reports as
/// `error.StreamTooLong`.
pub const too_large = std.fmt.comptimePrint("the memory file is larger than the {d} bytes VerA reads", .{side_file_limit});

/// `readSideFile` for the source `file_name`.
pub fn sideFile(io: std.Io, a: std.mem.Allocator, file_name: []const u8, name: []const u8) ![]const u8 {
    const limit = side_file_limit;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(file_name)) |dir| {
        const joined = try std.fs.path.join(a, &.{ dir, name });
        if (cwd.readFileAlloc(io, joined, a, .limited(limit))) |text| return text else |e| if (e == error.StreamTooLong) return e;
    }
    return cwd.readFileAlloc(io, name, a, .limited(limit));
}

// ---- the task table (§9.4.1 Table 9-1, §17.3) -------------------------------

const Radix = fmt.Radix;

/// §9.4.1 Table 9-1's display family, which is one task with two axes: the
/// radix an argument with no format specification is printed in, and whether
/// the call ends with a newline. "The $write task provides the same
/// capabilities as $display, but with no newline."
pub const Show = struct { radix: Radix, newline: bool };

/// The display families of §9.4.1 Table 9-1 differ in when they run, not in
/// what they print: every one formats through `display`.
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
    /// §17.6 the four queue tasks.
    queue: system.QueueOp,
    /// §17.5 the sixteen PLA tasks.
    pla: system.Pla,
    /// §17.2.7 `$fclose`.
    fclose,
    /// §17.2.6 `$fflush`: every write is already in its file
    /// (`file_kernels.zFFlush`), so it only reads its argument.
    fflush,
    /// §17.2.2 `$fdisplay`/`$fwrite`: `show` to a descriptor.
    fshow: Show,
    /// §17.2.3 `$swrite`: `show` into the first argument, a variable.
    sshow: Show,
    /// §17.2.3 `$sformat`: `sformat`'s text into the first argument.
    sformat,
    /// §17.3.1 `$printtimescale`.
    printtimescale,
    /// §18.1 the value change dump tasks.
    dump: @import("vcd.zig").Op,
    /// §18.3 the extended value change dump tasks.
    ports: @import("evcd.zig").Op,
    /// IEEE 1364-2005 §20.3 a PLI application's task (`Run.systf`).
    user,
};

fn showAs(radix: Radix, newline: bool) Show {
    return .{ .radix = radix, .newline = newline };
}

const TaskRow = struct { []const u8, Task };

/// Every system task this module runs, by name.
pub const tasks = std.StaticStringMap(Task).initComptime(@as([]const TaskRow, &.{
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
    .{ "$q_initialize", Task{ .queue = .initialize } },
    .{ "$q_add", Task{ .queue = .add } },
    .{ "$q_remove", Task{ .queue = .remove } },
    .{ "$q_exam", Task{ .queue = .exam } },
    .{ "$fclose", .fclose },
    .{ "$fflush", .fflush },
    .{ "$fdisplay", Task{ .fshow = showAs(.decimal, true) } },
    .{ "$fdisplayb", Task{ .fshow = showAs(.binary, true) } },
    .{ "$fdisplayo", Task{ .fshow = showAs(.octal, true) } },
    .{ "$fdisplayh", Task{ .fshow = showAs(.hex, true) } },
    .{ "$fwrite", Task{ .fshow = showAs(.decimal, false) } },
    .{ "$fwriteb", Task{ .fshow = showAs(.binary, false) } },
    .{ "$fwriteo", Task{ .fshow = showAs(.octal, false) } },
    .{ "$fwriteh", Task{ .fshow = showAs(.hex, false) } },
    .{ "$swrite", Task{ .sshow = showAs(.decimal, false) } },
    .{ "$swriteb", Task{ .sshow = showAs(.binary, false) } },
    .{ "$swriteo", Task{ .sshow = showAs(.octal, false) } },
    .{ "$swriteh", Task{ .sshow = showAs(.hex, false) } },
    .{ "$sformat", .sformat },
    .{ "$printtimescale", .printtimescale },
    .{ "$dumpfile", Task{ .dump = .file } },
    .{ "$dumpvars", Task{ .dump = .vars } },
    .{ "$dumpoff", Task{ .dump = .off } },
    .{ "$dumpon", Task{ .dump = .on } },
    .{ "$dumpall", Task{ .dump = .all } },
    .{ "$dumplimit", Task{ .dump = .limit } },
    .{ "$dumpflush", Task{ .dump = .flush } },
}) ++ pla_rows);

const pla_rows: []const TaskRow = blk: {
    var rows: [system.pla_tasks.len]TaskRow = undefined;
    for (system.pla_tasks, &rows) |t, *row| row.* = .{ t[0], Task{ .pla = t[1] } };
    const out = rows;
    break :blk &out;
};

pub const TimeFormat = fmt.TimeFormat;

// ---- formatting (§9.4.3, §17.1.1.3, §17.1.1.4, §17.3) -----------------------

/// Prints `args` as §9.4.1's display tasks do, onto `Run.out`; with a null
/// `allocator` it only validates the call. Every conversion is width-exact
/// (IEEE 1364-2005 §17.1.1.3), x and z apart (§17.1.1.4).
pub fn display(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show) Error!void {
    return walk(self, args, allocator, show, false);
}

/// §17.2.3 `$sformat`'s text of `args` (after its variable): "always
/// interprets its second argument, and only its second argument as a format
/// string", which "can be a static string ... or can be a reg variable whose
/// content is interpreted as the format string". Specifiers and arguments
/// that do not pair up at run time warn (W1153) and the task continues.
pub fn sformat(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator) Error!void {
    return walk(self, args, allocator, .{ .radix = .decimal, .newline = false }, true);
}

/// The W1153 text.
pub const sformat_mismatch = "$sformat: the format's specifiers and the arguments after it do not pair up";

fn sformatMismatch(self: *Run, e: Ast.ExprId) Error!void {
    const at = self.starts[@min(self.file.exprs.mainTok(e), self.starts.len - 1)];
    try self.bag.add(.lower, .W1153, .{ .start = at, .end = at }, sformat_mismatch, .{});
}

/// The widest field width or precision a format gives (E1011).
pub const max_field = 4096;
/// One real conversion's text: the longest %f of an f64 is a sign, 309
/// integer digits and the point, then `max_field` fractional digits; a field
/// width is padded outside it.
pub const real_buf = 512 + max_field;

fn walk(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show, only_first: bool) Error!void {
    const ex = &self.file.exprs;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (only_first and arg != 0) {
            // Arguments left over once the format is used up.
            for (args[arg..]) |rest| if (rest != .none) try compile.checkExpr(self, rest);
            if (allocator != null) try sformatMismatch(self, e);
            return;
        }
        // §9.4.1: "Any null argument produces a single space character in
        // the display. (A null argument is characterized by two adjacent
        // commas (,,) in the argument list.)"
        if (e == .none) {
            if (allocator != null) try self.out.writeByte(' ');
            continue;
        }
        // A format held in a variable is known only when the task runs.
        const dynamic = only_first and ex.tag(e) != .str_literal;
        // Only a string is a format. §9.4.3's last sentence before Table
        // 9-23: "Any expression argument with no corresponding format
        // specification is displayed using the default decimal format",
        // the default of this task, so $displayh's bare argument is hex.
        if (ex.tag(e) != .str_literal and !dynamic) {
            try compile.checkExpr(self, e);
            if (allocator) |a| try emitValue(self, try exec.eval(self, a, e, 0), show.radix, null);
            continue;
        }
        if (dynamic and allocator == null) {
            for (args) |x| if (x != .none) try compile.checkExpr(self, x);
            return;
        }
        const format = if (dynamic) (try system.text(allocator.?, try exec.eval(self, allocator.?, e, 0))) orelse "" else self.file.str(ex.strOf(e));
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] != '%') {
                if (allocator != null) try self.out.writeByte(format[i]);
                continue;
            }
            i += 1;
            if (i == format.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "unterminated display format");
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
            // §17.1.1.2: a real conversion takes C's `.precision` too.
            var precision: i64 = -1;
            if (i < format.len and format[i] == '.') {
                i += 1;
                precision = 0;
                while (i < format.len and format[i] >= '0' and format[i] <= '9') : (i += 1)
                    precision = precision *| 10 +| (format[i] - '0');
            }
            if (i == format.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "unterminated display format");
            // The analog side's bound (E1011): a field is composed whole.
            if ((width orelse 0) > max_field or precision > max_field)
                return self.failWith(.E1011, ex.mainTok(e), "a field width or precision here exceeds {d}", .{max_field});
            const radix: ?Radix = switch (format[i]) {
                'b', 'B' => .binary,
                'o', 'O' => .octal,
                'h', 'H' => .hex,
                'd', 'D' => .decimal,
                // §9.4.3 Table 9-23's real conversions, which "have the full
                // formatting capabilities available in the C language".
                // §9.4.7 adds a fourth row here: "the %r (or %R) format
                // specifier may be used on real expressions in the digital
                // context", engineering notation, `zCReal`'s 'r'.
                'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R' => null,
                // §17.3 `%t` is no radix: it reads the $timeformat state
                // and formats a time, whose operand is in the module's own
                // time unit.
                't', 'T' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| try emitTime(self, try exec.eval(self, a, args[arg], 0), width);
                    continue;
                },
                // §17.1.1.6 `%m` and §13.6 `%l` consume no argument: they
                // print where the display is, not a value.
                'm', 'M' => {
                    if (allocator != null) try emitScope(self);
                    continue;
                },
                'l', 'L' => {
                    const def = self.scope_info.items[self.scope].def;
                    if (allocator != null) try self.out.print("{s}.{s}", .{ self.file.str(self.def_lib[def]), self.file.str(self.file.modules[def].name) });
                    continue;
                },
                // §17.1.1.5 `%v`: "the strength of scalar nets".
                'v', 'V' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (compile.typeOf(self, args[arg]).width != 1) return self.exprFail(args[arg], "§17.1.1.5: %v takes a scalar net reference");
                    const net = if (ex.tag(args[arg]) == .ident) self.net_of.get(try self.slot(args[arg])) else null;
                    // The resolution keeps a net's `signal` only when read.
                    if (net) |n| self.nets[n].strength_read = true;
                    if (allocator) |a| {
                        const n = if (net) |k| self.nets[k] else null;
                        const sig: Signal = if (n == null)
                            .of((try exec.eval(self, a, args[arg], 0)).bit(0), .strong, .strong)
                        else if (n.?.drivers.len == 0) netPull(n.?.kind) else n.?.signal[0];
                        try strength(self.out, sig);
                    }
                    continue;
                },
                // §17.1.1.7 `%s` (the operand as 8-bit ASCII codes) and
                // `%c` (its low eight bits as one character).
                's', 'S', 'c', 'C' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| try fmt.text(self.out, try exec.eval(self, a, args[arg], 0), format[i] == 'c' or format[i] == 'C', width);
                    continue;
                },
                else => return self.exprFail(
                    e,
                    "only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g, §9.4.7 %r and %%) and %c %s %m %l %t %v are implemented",
                ),
            };
            arg += 1;
            if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
            if (radix) |r| {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| try emitValue(self, try exec.eval(self, a, args[arg], 0), r, width);
            } else {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| {
                    const real = try exec.evalReal(self, a, args[arg]);
                    var buf: [real_buf]u8 = undefined;
                    const text = zCReal(&buf, real, format[i], 0, 0, precision);
                    if (width) |w| if (text.len < w) try self.out.splatByteAll(' ', w - text.len);
                    try self.out.writeAll(text);
                }
            }
        }
    }
    if (allocator != null and show.newline) try self.out.writeByte('\n');
}

/// §17.1.1.6 `%m`: the hierarchical name of the scope the display runs in,
/// the instance path from the root, then every §5.3.2 named block around the
/// running instruction, outermost first.
pub fn emitScope(self: *Run) Error!void {
    try emitPath(self, self.scope);
    // The named blocks enclosing `pc` in this scope nest, so each is one
    // statement level deeper than the last: printed shallowest first, with no
    // bound on how many.
    var last: i32 = -1;
    while (true) {
        var next: ?struct { depth: u16, name: Ast.StrId } = null;
        var it = self.blocks.iterator();
        while (it.next()) |b| {
            if (b.key_ptr.scope != self.scope or self.pc < b.value_ptr.start or self.pc >= b.value_ptr.end) continue;
            const d = b.value_ptr.depth;
            if (d > last and (next == null or d < next.?.depth)) next = .{ .depth = d, .name = b.key_ptr.str };
        }
        const b = next orelse break;
        try self.out.print(".{s}", .{self.file.str(b.name)});
        last = b.depth;
    }
}

/// Scope `s`'s hierarchical name, root first.
fn emitPath(self: *Run, s: u32) Error!void {
    const info = self.scope_info.items[s];
    if (info.parent != s and s != 0) {
        try emitPath(self, info.parent);
        try self.out.writeByte('.');
    }
    try self.out.writeAll(self.file.str(info.name));
    // §12.4.1 one iteration of a loop generate is `name[value]`.
    if (info.index) |i| try self.out.print("[{d}]", .{i});
}

/// §17.1.1.5 `%v` of the §7.10 signal `s`: a Table 17-5 mnemonic and the
/// Table 17-4 value (0 1 X Z L H), or, where a 0 or 1 spans a range of
/// strengths, its maximum and minimum levels as digits, and for an X whose
/// sides differ, its 0 and 1 levels ("35X").
pub fn strength(out: *std.Io.Writer, s: Signal) std.Io.Writer.Error!void {
    const names = [_][]const u8{ "Hi", "Sm", "Me", "We", "La", "Pu", "St", "Su" };
    const lo: u8 = @abs(s.lo);
    const hi: u8 = @abs(s.hi);
    if (s.lo == 0 and s.hi == 0) return out.writeAll("HiZ");
    if (s.lo >= 0 and s.hi > 0 and s.lo != 0) return if (lo == hi) out.print("{s}1", .{names[hi]}) else out.print("{d}{d}1", .{ hi, lo });
    if (s.hi <= 0 and s.lo < 0 and s.hi != 0) return if (lo == hi) out.print("{s}0", .{names[lo]}) else out.print("{d}{d}0", .{ lo, hi });
    if (s.lo == 0) return out.print("{s}H", .{names[hi]});
    if (s.hi == 0) return out.print("{s}L", .{names[lo]});
    return if (lo == hi) out.print("{s}X", .{names[lo]}) else out.print("{d}{d}X", .{ lo, hi });
}

/// `%t`; a field width in the format (`%0t`: none) replaces §17.3.2's
/// minimum field width.
fn emitTime(self: *Run, v: Int.Literal, width: ?u32) Error!void {
    var f = self.time_format;
    if (width) |w| f.width = w;
    try fmt.time(self.out, v, f, self.timeOf(self.scope).unit_exp);
}

/// IEEE 1364-2005 §17.3.1 `$printtimescale`: "the time unit and precision of
/// the module that is the current scope", or with an argument "of the module
/// passed to it", in the clause's format `Time scale of (name) is unit /
/// precision`. The name is the current module's, or the argument as written.
pub fn printTimescale(self: *Run, args: []const Ast.ExprId) Error!void {
    const scope = if (args.len == 1) try timescaleScope(self, args[0]) else self.scope;
    const mt = self.timeOf(scope);
    const prec_exp = mt.unit_exp - @as(i32, std.math.log10_int(@as(u64, mt.scale.local_per_unit)));
    try self.out.writeAll("Time scale of (");
    if (args.len == 0) try self.out.writeAll(self.file.str(self.file.modules[self.scope_info.items[self.scope].def].name)) else {
        const ex = &self.file.exprs;
        const parts: []const Ast.StrId = if (ex.tag(args[0]) == .ident) &.{ex.strOf(args[0])} else ex.nameParts(args[0]);
        for (parts, 0..) |p, i| try self.out.print("{s}{s}", .{ if (i == 0) "" else ".", self.file.str(p) });
    }
    try self.out.writeAll(") is ");
    try fmt.decade(self.out, mt.unit_exp);
    try self.out.writeAll(" / ");
    try fmt.decade(self.out, prec_exp);
    try self.out.writeByte('\n');
}

/// §17.3.1 the module instance `$printtimescale`'s argument names.
pub fn timescaleScope(self: *Run, e: Ast.ExprId) Error!u32 {
    return switch (try @import("vcd.zig").target(self, e)) {
        .scope => |sc| sc,
        .slot => self.exprFail(e, "§17.3.1: $printtimescale names a module instance"),
    };
}

fn emitValue(self: *Run, v: Int.Literal, radix: Radix, width: ?u32) Error!void {
    fmt.value(self.out, v, radix, width) catch |e| return switch (e) {
        error.TooWide => self.fail(0, "decimal display of an operand wider than 64 bits is not implemented", .{}),
        error.WriteFailed => error.WriteFailed,
    };
}

/// Prints the standing monitor's argument list, if there is one and it is
/// on. The caller decides whether to print (a watched slot changed in
/// `exec.store`, or `$monitoron` ran), never by comparing text.
pub fn monitorPrint(self: *Run, a: std.mem.Allocator) Error!void {
    const m = self.monitor orelse return;
    if (!self.monitor_on) return;
    // §17.1.3 the monitor renders in the instance that installed it; the
    // `.monitor` region runs outside any process's dispatch.
    self.scope = m.scope;
    self.pc = m.pc;
    try display(self, m.args, a, m.show);
}

// ---- tests ------------------------------------------------------------------

test "§17.1.3 monitor: clock queries do not trigger, a change and change back does" {
    // t1: only `u` (unwatched) changes and $time advances: no line. t2: a
    // goes 1 then back to 0 via #0: it "changes value", so one line with
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
    // operand can take: 255 for `reg [7:0]`, so three columns of leading
    // space, not zero. `%0d` is the escape from it.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'd7;
        \\  $display("[%d][%0d][%h][%o][%b]", v, v, v, v, v);
        \\end endmodule
        \\
    , "[  7][7][07][007][00000111]\n");
    // §17.1.1.4: a group that is entirely unknown prints lowercase, a group
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
    // argument with no format specification takes the task's default radix.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'hA5;
        \\  $write("w"); $displayh(v); $display("[", , "]"); $display("bare=", v);
        \\end endmodule
        \\
    , "wa5\n[ ]\nbare=165\n");
}

test "§17.2.3 $sformat/$swrite fill a reg with the text, §17.3.1 $printtimescale" {
    try expectRun(
        \\`timescale 10us/100ns
        \\module m; reg [8*6:1] s; initial begin
        \\  #3 $sformat(s, "t=%0d", $time); $display("[%s]", s);
        \\  $swriteh(s, 8'hab, "!"); $display("[%s]", s);
        \\  $sformat(s, "%s-long", "too"); $display("[%s]", s);
        \\  $printtimescale;
        \\end endmodule
        \\
    , "[t=3]\n[ab!]\n[o-long]\nTime scale of (m) is 10us / 100ns\n");
}

test "display retains escaped NUL bytes and unsized integer width" {
    try expectRun("module m; initial $display(\"A\\000B %b\",1); endmodule", "A\x00B 00000000000000000000000000000001\n");
    try expectRun("module m; initial $display(\"%b\",65'd1); endmodule", "00000000000000000000000000000000000000000000000000000000000000001\n");
}
