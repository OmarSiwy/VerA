//! §12.24–§12.28 — `vpi_printf` and the multichannel descriptor family.
//!
//! "Channel 1 is stdout, channel 2 is stderr, and channel 3 is the current log
//! file" (§12.27), bit N-1 of an mcd names channel N, and §12.24/§12.26 make
//! the first three predefined and unclosable. So a user file is channel 4 or
//! above, and `vpi_mcd_open` hands out the lowest free one.
//!
//! THERE IS NO PRODUCT LOG FILE. VerA writes its transcript to stdout and
//! nowhere else, so channel 3 is a channel that exists — it can be named,
//! printed to and refused a close — and discards what it is given. `vpi_printf`
//! ("to both stdout and the current product log file") is therefore stdout.
//!
//! FORMATTING is C's `printf` (§12.27/§12.28 "the same format as the C
//! fprintf() routine"), done here over `@cVaArg` rather than handed to libc: the
//! `vpi` module is linked into binaries that do not link libc, and a `va_list`
//! is the one thing a C variadic cannot be re-read without.

const std = @import("std");
const root = @import("root.zig");

const Io = std.Io;

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

// ---------------------------------------------------------------------------
// The channels
// ---------------------------------------------------------------------------

/// Channels 4..32: the 29 an mcd has room for above the three predefined ones.
const first_user = 3; // index of channel 4
const channel_count = 32;

const Channel = struct {
    file: Io.File,
    /// NUL-terminated, owned by `gpa`.
    name: [:0]u8,
};

var channels: [channel_count]?Channel = @splat(null);
const gpa = std.heap.smp_allocator;

/// §12.25's buffer: "This routine shall overwrite the returned value on
/// subsequent calls."
var name_buf: [root.name_buf_len]u8 = undefined;

/// §12.26 "shall open a file for writing and return a corresponding
/// multichannel descriptor number ... shall return a zero (0) on error. If the
/// file is already opened, vpi_mcd_open() shall return the descriptor number."
export fn vpi_mcd_open(file: [*c]const u8) c_uint {
    root.clearError();
    if (file == null) {
        root.fail("BADNAME", "vpi_mcd_open: the file name is NULL", .{});
        return 0;
    }
    const want = std.mem.span(file);
    for (channels[first_user..], first_user..) |c, i| {
        if (c) |ch| if (std.mem.eql(u8, ch.name, want)) return bit(i);
    }
    const free = for (channels[first_user..], first_user..) |c, i| {
        if (c == null) break i;
    } else {
        root.fail("NOCHANNEL", "vpi_mcd_open: all 29 user channels are open", .{});
        return 0;
    };
    const f = Io.Dir.cwd().createFile(io(), want, .{}) catch |e| {
        root.fail("NOOPEN", "vpi_mcd_open: cannot open `{s}`: {t}", .{ want, e });
        return 0;
    };
    const name = gpa.dupeZ(u8, want) catch {
        f.close(io());
        root.fail("NOMEM", "vpi_mcd_open: out of memory", .{});
        return 0;
    };
    channels[free] = .{ .file = f, .name = name };
    return bit(free);
}

fn bit(i: usize) c_uint {
    return @as(c_uint, 1) << @intCast(i);
}

/// §12.24 "On success this routine returns a zero (0); on error it returns the
/// mcd value of the unclosed channels." The predefined three "can not be
/// closed", and a channel that is not open cannot be closed either — both come
/// back in the return value, and both are an error.
export fn vpi_mcd_close(mcd: c_uint) c_uint {
    root.clearError();
    var unclosed: c_uint = 0;
    for (0..channel_count) |i| {
        if (mcd & bit(i) == 0) continue;
        if (i < first_user) {
            unclosed |= bit(i);
            continue;
        }
        const ch = channels[i] orelse {
            unclosed |= bit(i);
            continue;
        };
        ch.file.close(io());
        gpa.free(ch.name);
        channels[i] = null;
    }
    if (unclosed != 0) root.fail("NOCLOSE", "vpi_mcd_close: channels 0x{x} are predefined or not open", .{unclosed});
    return unclosed;
}

/// §12.25 "the name of a file represented by a single-channel descriptor ...
/// On error, the routine shall return NULL."
export fn vpi_mcd_name(cd: c_uint) [*c]u8 {
    root.clearError();
    if (cd == 0 or cd & (cd - 1) != 0) {
        root.fail("BADMCD", "vpi_mcd_name: 0x{x} is not a single-channel descriptor", .{cd});
        return null;
    }
    const i = @ctz(cd);
    const s: []const u8 = switch (i) {
        0 => "stdout",
        1 => "stderr",
        2 => "log",
        else => if (channels[i]) |ch| ch.name else {
            root.fail("BADMCD", "vpi_mcd_name: channel {d} is not open", .{i + 1});
            return null;
        },
    };
    const n = @min(s.len, name_buf.len - 1);
    @memcpy(name_buf[0..n], s[0..n]);
    name_buf[n] = 0;
    return &name_buf;
}

/// §12.28 "shall write to both stdout and the current product log file ...
/// shall return the number of characters printed or EOF if an error occurred."
export fn vpi_printf(format: [*c]const u8, ...) callconv(.c) c_int {
    root.clearError();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return emit(1, format, &ap);
}

/// §12.27. The return is the number of characters in ONE expansion, however
/// many channels receive it: "the number of characters printed" is a property
/// of the format and its arguments, and a count multiplied by the channel set
/// would change with a bit of the mcd that has nothing to do with the text.
export fn vpi_mcd_printf(mcd: c_uint, format: [*c]const u8, ...) callconv(.c) c_int {
    root.clearError();
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return emit(mcd, format, &ap);
}

const EOF: c_int = -1;

fn emit(mcd: c_uint, format: [*c]const u8, ap: *std.builtin.VaList) c_int {
    if (format == null) {
        root.fail("BADFORMAT", "vpi_printf: the format is NULL", .{});
        return EOF;
    }
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (!cformat(&out.writer, format, ap)) {
        root.fail("NOMEM", "vpi_printf: out of memory", .{});
        return EOF;
    }
    const text = out.written();
    for (0..channel_count) |i| {
        if (mcd & bit(i) == 0) continue;
        const file: Io.File = switch (i) {
            0 => .stdout(),
            1 => .stderr(),
            2 => continue, // no product log file; see the file header
            else => if (channels[i]) |ch| ch.file else {
                root.fail("BADMCD", "vpi_mcd_printf: channel {d} is not open", .{i + 1});
                return EOF;
            },
        };
        file.writeStreamingAll(io(), text) catch {
            root.fail("NOWRITE", "vpi_mcd_printf: write to channel {d} failed", .{i + 1});
            return EOF;
        };
    }
    return std.math.cast(c_int, text.len) orelse std.math.maxInt(c_int);
}

// ---------------------------------------------------------------------------
// C11 7.21.6.1, over a va_list
// ---------------------------------------------------------------------------

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,
};

const Length = enum { none, hh, h, l, ll, j, z, t, L };

/// Expand `fmt` against `ap`. A conversion C leaves undefined (an unknown
/// letter, a truncated spec) is copied through as written and consumes no
/// argument — the least wrong thing to do with a format nobody can read.
/// `%n` is not supported: it writes through an application pointer, and a
/// logging routine that stores into memory is a hazard this one does not take.
///
/// C calling convention because `@cVaArg` is only legal in one; false when the
/// writer failed (out of memory).
pub fn cformat(w: *Io.Writer, format: [*:0]const u8, ap: *std.builtin.VaList) callconv(.c) bool {
    expand(w, std.mem.span(format), ap) catch return false;
    return true;
}

inline fn expand(w: *Io.Writer, fmt: []const u8, ap: *std.builtin.VaList) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            const end = std.mem.indexOfScalarPos(u8, fmt, i, '%') orelse fmt.len;
            try w.writeAll(fmt[i..end]);
            i = end;
            continue;
        }
        const start = i;
        i += 1;
        var s: Spec = .{};
        while (i < fmt.len) : (i += 1) switch (fmt[i]) {
            '-' => s.left = true,
            '+' => s.plus = true,
            ' ' => s.space = true,
            '#' => s.alt = true,
            '0' => s.zero = true,
            else => break,
        };
        if (i < fmt.len and fmt[i] == '*') {
            i += 1;
            const v = @cVaArg(ap, c_int);
            if (v < 0) s.left = true;
            s.width = @abs(v);
        } else while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            s.width = s.width *| 10 +| (fmt[i] - '0');
        }
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                i += 1;
                const v = @cVaArg(ap, c_int);
                s.prec = if (v < 0) null else @intCast(v);
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p *| 10 +| (fmt[i] - '0');
                s.prec = p;
            }
        }
        var len: Length = .none;
        if (i < fmt.len) switch (fmt[i]) {
            'h' => {
                i += 1;
                len = .h;
                if (i < fmt.len and fmt[i] == 'h') {
                    i += 1;
                    len = .hh;
                }
            },
            'l' => {
                i += 1;
                len = .l;
                if (i < fmt.len and fmt[i] == 'l') {
                    i += 1;
                    len = .ll;
                }
            },
            'j' => {
                i += 1;
                len = .j;
            },
            'z' => {
                i += 1;
                len = .z;
            },
            't' => {
                i += 1;
                len = .t;
            },
            'L' => {
                i += 1;
                len = .L;
            },
            else => {},
        };
        if (i >= fmt.len) {
            try w.writeAll(fmt[start..]);
            break;
        }
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            '%' => try w.writeByte('%'),
            'd', 'i' => {
                const v: i128 = switch (len) {
                    .none, .h, .hh => blk: {
                        const x = @cVaArg(ap, c_int);
                        break :blk switch (len) {
                            .h => @as(i16, @truncate(x)),
                            .hh => @as(i8, @truncate(x)),
                            else => x,
                        };
                    },
                    .l => @cVaArg(ap, c_long),
                    .ll, .L => @cVaArg(ap, c_longlong),
                    .j => @cVaArg(ap, i64),
                    .z, .t => @cVaArg(ap, isize),
                };
                try integer(w, s, @intCast(@abs(v)), v < 0, 10, false);
            },
            'u', 'x', 'X', 'o' => {
                const v: u64 = switch (len) {
                    .none, .h, .hh => blk: {
                        const x: c_uint = @bitCast(@cVaArg(ap, c_int));
                        break :blk switch (len) {
                            .h => @as(u16, @truncate(x)),
                            .hh => @as(u8, @truncate(x)),
                            else => x,
                        };
                    },
                    .l => @cVaArg(ap, c_ulong),
                    .ll, .L => @cVaArg(ap, c_ulonglong),
                    .j => @cVaArg(ap, u64),
                    .z, .t => @cVaArg(ap, usize),
                };
                const base: u8 = switch (conv) {
                    'o' => 8,
                    'u' => 10,
                    else => 16,
                };
                try integer(w, s, v, false, base, conv == 'X');
            },
            'c' => {
                const b: u8 = @truncate(@as(c_uint, @bitCast(@cVaArg(ap, c_int))));
                try padded(w, s, &.{b});
            },
            's' => {
                const p = @cVaArg(ap, ?[*:0]const u8);
                var text: []const u8 = if (p) |q| std.mem.span(q) else "(null)";
                if (s.prec) |pr| text = text[0..@min(pr, text.len)];
                try padded(w, s, text);
            },
            'p' => {
                const p = @cVaArg(ap, usize);
                var buf: [2 + 16]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "0x{x}", .{p}) catch unreachable;
                try padded(w, s, text);
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                // ponytail: `long double` cannot be read from a va_list by this
                // compiler on SysV. Its size is not an f64's, so every later
                // argument would be misread: the rest of the format goes out
                // verbatim instead. `%L` in a VPI log line is the ceiling.
                if (len == .L) return w.writeAll(fmt[start..]);
                try real(w, s, @cVaArg(ap, f64), conv);
            },
            'n' => _ = @cVaArg(ap, ?*anyopaque),
            else => try w.writeAll(fmt[start..i]),
        }
    }
}

/// `text` in a field of `s.width`, space-padded on the side `-` selects.
fn padded(w: *Io.Writer, s: Spec, text: []const u8) Io.Writer.Error!void {
    const pad = s.width -| text.len;
    if (!s.left) try w.splatByteAll(' ', pad);
    try w.writeAll(text);
    if (s.left) try w.splatByteAll(' ', pad);
}

/// A sign or prefix, zeros, then digits, laid into the field. C's '0' flag
/// puts its padding BETWEEN the prefix and the digits, and is ignored when a
/// precision is given or the field is left-justified.
fn field(w: *Io.Writer, s: Spec, prefix: []const u8, zeros: usize, digits: []const u8, zero_ok: bool) Io.Writer.Error!void {
    const body = prefix.len + zeros + digits.len;
    const pad = s.width -| body;
    const zero_fill = s.zero and !s.left and zero_ok;
    if (!s.left and !zero_fill) try w.splatByteAll(' ', pad);
    try w.writeAll(prefix);
    if (zero_fill) try w.splatByteAll('0', pad);
    try w.splatByteAll('0', zeros);
    try w.writeAll(digits);
    if (s.left) try w.splatByteAll(' ', pad);
}

fn integer(w: *Io.Writer, s: Spec, mag: u64, neg: bool, base: u8, upper: bool) Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    var digits: []const u8 = buf[0..std.fmt.printInt(&buf, mag, base, if (upper) .upper else .lower, .{})];
    // "The result of converting a zero value with a precision of zero is no
    // characters."
    if (mag == 0 and s.prec != null and s.prec.? == 0) digits = "";
    var zeros: usize = if (s.prec) |p| p -| digits.len else 0;
    var prefix_buf: [2]u8 = undefined;
    var prefix: []const u8 = "";
    if (neg) prefix = "-" else if (base == 10 and s.plus) prefix = "+" else if (base == 10 and s.space) prefix = " ";
    if (s.alt and base == 8 and zeros == 0 and (digits.len == 0 or digits[0] != '0')) zeros = 1;
    if (s.alt and base == 16 and mag != 0) {
        prefix_buf = .{ '0', if (upper) 'X' else 'x' };
        prefix = &prefix_buf;
    }
    try field(w, s, prefix, zeros, digits, s.prec == null);
}

/// %e %f %g, C11 7.21.6.1 semantics over Zig's shortest-round-trip digits.
///
/// ponytail: rounding is of the SHORTEST decimal that round-trips, not of the
/// exact binary value, so a tie like `%.2f` of 0.125 (exactly representable)
/// can land on the other side of glibc's answer. That costs a last digit on a
/// logging routine; exact binary-to-decimal is the upgrade if an application
/// ever depends on it.
fn real(w: *Io.Writer, s: Spec, v: f64, conv: u8) Io.Writer.Error!void {
    const upper = std.ascii.isUpper(conv);
    const neg = std.math.signbit(v);
    const sign: []const u8 = if (neg) "-" else if (s.plus) "+" else if (s.space) " " else "";
    if (std.math.isNan(v) or std.math.isInf(v)) {
        const word = if (std.math.isNan(v)) (if (upper) "NAN" else "nan") else (if (upper) "INF" else "inf");
        return field(w, s, sign, 0, word, false);
    }
    const a = @abs(v);
    const p: usize = s.prec orelse 6;
    var buf: [512]u8 = undefined;
    const body: []const u8 = switch (conv | 0x20) {
        'f' => fixed(&buf, a, p, s.alt),
        'e' => sci(&buf, a, p, upper, s.alt),
        else => blk: {
            // C: P = p, or 1 if p is 0. X = the exponent %e would print. Style
            // f with precision P-1-X if P > X >= -4, else style e with P-1;
            // then trailing zeros go unless '#'.
            const pg: usize = if (p == 0) 1 else p;
            const x = exponentAfterRounding(a, pg - 1);
            const out = if (x >= -4 and x < @as(i32, @intCast(pg)))
                fixed(&buf, a, @intCast(@as(i32, @intCast(pg)) - 1 - x), s.alt)
            else
                sci(&buf, a, pg - 1, upper, s.alt);
            break :blk if (s.alt) out else stripZeros(out);
        },
    };
    try field(w, s, sign, 0, body, true);
}

/// The decimal exponent of `a` printed as %e with `p` fraction digits — which
/// can be one more than `a`'s own when rounding carries (9.99 at p=1 is 1.0e1).
fn exponentAfterRounding(a: f64, p: usize) i32 {
    var buf: [64]u8 = undefined;
    const r = std.fmt.float.render(&buf, a, .{ .mode = .scientific, .precision = p }) catch return 0;
    const e = std.mem.indexOfScalar(u8, r, 'e') orelse return 0;
    return std.fmt.parseInt(i32, r[e + 1 ..], 10) catch 0;
}

fn fixed(buf: []u8, a: f64, p: usize, alt: bool) []const u8 {
    const r = std.fmt.float.render(buf, a, .{ .mode = .decimal, .precision = @min(p, 300) }) catch return "?";
    if (p == 0 and alt) {
        buf[r.len] = '.';
        return buf[0 .. r.len + 1];
    }
    return r;
}

/// Zig renders `1.5e3`; C wants `1.500000e+03` — at least two exponent digits
/// and an explicit sign.
fn sci(buf: []u8, a: f64, p: usize, upper: bool, alt: bool) []const u8 {
    var tmp: [64]u8 = undefined;
    const r = std.fmt.float.render(&tmp, a, .{ .mode = .scientific, .precision = @min(p, 40) }) catch return "?";
    const e = std.mem.indexOfScalar(u8, r, 'e') orelse return "?";
    const x = std.fmt.parseInt(i32, r[e + 1 ..], 10) catch 0;
    const mant = r[0..e];
    const dot = if (p == 0 and alt) "." else "";
    return std.fmt.bufPrint(buf, "{s}{s}{c}{c}{d:0>2}", .{
        mant, dot, @as(u8, if (upper) 'E' else 'e'), @as(u8, if (x < 0) '-' else '+'), @abs(x),
    }) catch "?";
}

/// %g's "trailing zeros are removed from the fractional portion of the result
/// and the decimal-point character is removed if there is no fractional
/// portion remaining", applied to the mantissa of an e-style result too.
fn stripZeros(s: []const u8) []const u8 {
    const e = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
    if (std.mem.indexOfScalar(u8, s[0..e], '.') == null) return s;
    var end = e;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    if (e == s.len) return s[0..end];
    // Close the gap in place: the exponent follows the kept mantissa.
    const m = @constCast(s);
    std.mem.copyForwards(u8, m[end..], s[e..]);
    return s[0 .. end + (s.len - e)];
}

// ---------------------------------------------------------------------------
// Tests. The C-side check — that the header's prototypes and these exports
// agree, and that the channels hit the disk — is tests/fixtures/ch11_vpi/
// p02_09_printf_mcd.c, run by `zig build test-vpi`.
// ---------------------------------------------------------------------------

/// Calls `cformat` the way a C caller would: through a variadic.
fn formatted(buf: [*]u8, fmt: [*:0]const u8, ...) callconv(.c) usize {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var w: Io.Writer = .fixed(buf[0..128]);
    if (!cformat(&w, fmt, &ap)) return 0;
    return w.end;
}

fn expectFormat(want: []const u8, got_len: usize, buf: []const u8) !void {
    try std.testing.expectEqualStrings(want, buf[0..got_len]);
}

test "C conversions: integers, flags, widths and precisions" {
    var b: [128]u8 = undefined;
    try expectFormat("p02 printf 7 ok\n", formatted(&b, "p02 printf %d %s\n", @as(c_int, 7), @as([*:0]const u8, "ok")), &b);
    try expectFormat("[   -42][-42   ][-0042][+42]", formatted(&b, "[%6d][%-6d][%05d][%+d]", @as(c_int, -42), @as(c_int, -42), @as(c_int, -42), @as(c_int, 42)), &b);
    try expectFormat("ff 0XFF 017 0x1f", formatted(&b, "%x %#X %#o %#x", @as(c_uint, 255), @as(c_uint, 255), @as(c_uint, 15), @as(c_uint, 31)), &b);
    try expectFormat("4294967295 18446744073709551615", formatted(&b, "%u %llu", @as(c_uint, 0xffffffff), @as(c_ulonglong, std.math.maxInt(u64))), &b);
    try expectFormat("[ab][   xyz][c]%", formatted(&b, "[%.2s][%*s][%c]%%", @as([*:0]const u8, "abc"), @as(c_int, 6), @as([*:0]const u8, "xyz"), @as(c_int, 'c')), &b);
    try expectFormat("[00007][]", formatted(&b, "[%.5d][%.0d]", @as(c_int, 7), @as(c_int, 0)), &b);
}

test "C conversions: reals" {
    var b: [128]u8 = undefined;
    try expectFormat("3.500000 1.500000e+03 2.5E-07", formatted(&b, "%f %e %.1E", @as(f64, 3.5), @as(f64, 1500.0), @as(f64, 2.5e-7)), &b);
    // %g: style f inside [1e-4, 1e6), style e outside, trailing zeros stripped.
    try expectFormat("0.0001 100000 1e+06 1e-05 0.5", formatted(&b, "%g %g %g %g %g", @as(f64, 1e-4), @as(f64, 1e5), @as(f64, 1e6), @as(f64, 1e-5), @as(f64, 0.5)), &b);
    try expectFormat("[  -1.25][-001.25][inf]", formatted(&b, "[%7.2f][%07.2f][%f]", @as(f64, -1.25), @as(f64, -1.25), std.math.inf(f64)), &b);
    try expectFormat("3.14159", formatted(&b, "%g", @as(f64, 3.14159265)), &b);
}

test "§12.24–§12.26: channel numbering, reopen, and the three predefined channels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Channel files are created relative to the cwd, so the test names an
    // absolute path inside its own temporary directory.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io(), &path_buf)];
    const a_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/a.log", .{dir}, 0);
    defer std.testing.allocator.free(a_path);

    try std.testing.expectEqual(@as(c_uint, 0x7), vpi_mcd_close(0x7));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    const a = vpi_mcd_open(a_path.ptr);
    try std.testing.expectEqual(@as(c_uint, 8), a);
    try std.testing.expectEqual(a, vpi_mcd_open(a_path.ptr));
    try std.testing.expectEqualStrings(a_path, std.mem.span(vpi_mcd_name(a)));
    try std.testing.expectEqualStrings("stdout", std.mem.span(vpi_mcd_name(1)));
    // Not a single channel.
    try std.testing.expect(vpi_mcd_name(a | 1) == null);

    try std.testing.expectEqual(@as(c_int, 6), vpi_mcd_printf(a | 4, "alpha\n"));
    try std.testing.expectEqual(@as(c_uint, 0), vpi_mcd_close(a));
    try std.testing.expectEqual(a, vpi_mcd_close(a));
    try std.testing.expect(vpi_mcd_name(a) == null);
    // Writing to a closed channel is an error, and so says EOF.
    try std.testing.expectEqual(EOF, vpi_mcd_printf(a, "x"));

    var got: [16]u8 = undefined;
    const text = try tmp.dir.readFile(io(), "a.log", &got);
    try std.testing.expectEqualStrings("alpha\n", text);
}
