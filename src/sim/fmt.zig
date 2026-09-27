//! An operand's planes, width and signedness, radix and field width (or a
//! time and the `$timeformat` state) -> its IEEE 1364-2005 §17.1 text.
//! The interpreter (`digital/display.zig`) and a native executable (`rt/`)
//! both print through these, so the two cannot disagree about a digit.
//! Clauses: VAMS §9.4.3 Table 9-22; IEEE 1364-2005 §17.1.1.3, §17.1.1.4,
//! §17.1.1.7, §17.3, §19.8.
const std = @import("std");
const Int = @import("frontend").Integer;

/// §9.4.3 Table 9-22's four conversions. The value is the base, so a digit is
/// `@ctz(base)` bits wide for the three power-of-two members and decimal is the
/// one that is not a bit group.
pub const Radix = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hex = 16,

    /// Bits consumed per printed digit; meaningless for `.decimal`, which reads
    /// the whole operand at once.
    pub fn perDigit(self: Radix) u32 {
        return switch (self) {
            .binary => 1,
            .octal => 3,
            .hex => 4,
            .decimal => unreachable,
        };
    }
};

/// §17.3 `$timeformat(units_number, precision, suffix, min_width)`, with the
/// clause's own defaults: the units are the simulation's precision, nothing
/// after the decimal point, no suffix, and a 20-column field.
pub const TimeFormat = struct {
    units: i32 = 0,
    precision: u32 = 0,
    suffix: []const u8 = "",
    width: u32 = 20,
};

/// A `%d` of an operand wider than 64 bits (see `decimalText`).
pub const Error = error{TooWide} || std.Io.Writer.Error;

/// Byte `n` of `v` counting from the least significant, unknown bits read as 0.
pub fn byteAt(v: Int.Literal, n: u32) u8 {
    var c: u8 = 0;
    for (0..8) |k| {
        const at = n * 8 + @as(u32, @intCast(k));
        if (at < v.width and v.bit(at) == .one) c |= @as(u8, 1) << @intCast(k);
    }
    return c;
}

/// §17.1.1.7: "each 8 bits representing a single character ... right-
/// justified so that the rightmost bit of the value is the least significant
/// bit of the last character", and "leading zeros are never printed".
/// ponytail: 1024 characters; a wider operand prints its low 1024.
pub fn asciiText(buf: *[1024]u8, v: Int.Literal) []const u8 {
    const bytes = @min((v.width + 7) / 8, buf.len);
    var out: usize = 0;
    var n = bytes;
    while (n != 0) {
        n -= 1;
        const c = byteAt(v, n);
        if (c == 0 and out == 0) continue;
        buf[out] = c;
        out += 1;
    }
    return buf[0..out];
}

/// §17.1.1.7 `%s` (`char` false) or `%c`, right-justified in `width` columns.
pub fn text(out: *std.Io.Writer, v: Int.Literal, char: bool, width: ?u32) std.Io.Writer.Error!void {
    var buf: [1024]u8 = undefined;
    const t = if (char) blk: {
        buf[0] = byteAt(v, 0);
        break :blk buf[0..1];
    } else asciiText(&buf, v);
    if (width) |w| if (t.len < w) try out.splatByteAll(' ', w - t.len);
    try out.writeAll(t);
}

/// §17.3 `%t`. The operand is a time in the invoking module's time unit
/// (what `$time` returns, and what a literal `1` there means), and
/// `$timeformat`'s `units_number` says which power of ten of a second to
/// report it in. So the printed number is
///
///     value · 10^(unit_exp − units_number)
///
/// and nothing here needs the precision: scaling a unit count by a ratio of
/// decades is exact in the only direction that matters.
pub fn time(out: *std.Io.Writer, v: Int.Literal, f: TimeFormat, unit_exp: i32) std.Io.Writer.Error!void {
    const raw: f64 = if (v.hasUnknown())
        0
    else if (v.signed)
        @floatFromInt(v.asInt() orelse 0)
    else
        @floatFromInt(v.values()[0]);
    const scaled = raw * std.math.pow(f64, 10, @floatFromInt(unit_exp - f.units));
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d:.[1]}", .{ scaled, f.precision }) catch unreachable;
    w.writeAll(f.suffix) catch unreachable;
    const t = w.buffered();
    if (t.len < f.width) try out.splatByteAll(' ', f.width - t.len);
    try out.writeAll(t);
}

/// 10^e seconds in §19.8's spelling: 1, 10 or 100 of s, ms, us, ns, ps, fs.
pub fn decade(out: *std.Io.Writer, e: i32) std.Io.Writer.Error!void {
    const k = @divFloor(e, 3);
    const units = [_][]const u8{ "fs", "ps", "ns", "us", "ms", "s" };
    const mantissa: u32 = std.math.pow(u32, 10, @intCast(e - 3 * k));
    try out.print("{d}{s}", .{ mantissa, units[@intCast(k + 5)] });
}

/// One operand, in one radix, sized by IEEE 1364-2005 §17.1.1.3 unless the
/// format gave an explicit width.
///
/// The three power-of-two radices are a GROUP walk and decimal is not, and
/// that is the whole split: a hex digit is four bits of this operand and
/// says nothing about the other bits, so a group that is entirely unknown
/// prints as unknown while its neighbours print normally. A decimal
/// rendering has no such locality (one unknown bit makes the whole number
/// unknown), which is why §17.1.1.4 gives it its own rule.
pub fn value(out: *std.Io.Writer, v: Int.Literal, radix: Radix, width: ?u32) Error!void {
    var buf: [1024]u8 = undefined;
    const t = if (radix == .decimal)
        try decimalText(&buf, v)
    else
        groupText(&buf, v, radix);
    // §17.1.1.3's automatic size. Right-justified with leading spaces, not
    // zeros: `%d` of an 8-bit 7 is "  7" and not "007". A group radix is
    // already exactly its own width, so padding only ever shows up under
    // decimal or an explicit format width.
    const field = width orelse autoWidth(v, radix);
    if (t.len < field) try out.splatByteAll(' ', field - t.len);
    try out.writeAll(t);
}

/// §17.1.1.3: "a radix conversion is sized to the operand's declared width,
/// and the default decimal field is sized to the largest value the operand
/// can hold". For a signed operand the largest printed value is the
/// negative one, because of its sign: a 32-bit `integer` is 11 columns
/// ("-2147483648"), not 10.
pub fn autoWidth(v: Int.Literal, radix: Radix) u32 {
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
/// digit's value and nothing to its unknown-ness, which is what makes an
/// all-x 8-bit operand print "xxx" in octal rather than "Xxx": the top
/// group holds two x bits and no third bit at all.
pub fn groupText(buf: []u8, v: Int.Literal, radix: Radix) []const u8 {
    const per = radix.perDigit();
    const digits = (v.width + per - 1) / per;
    var out: usize = 0;
    var d = digits;
    while (d != 0) {
        d -= 1;
        var val: u32 = 0;
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
                .one => val |= @as(u32, 1) << @intCast(k),
                .x => xs += 1,
                .z => zs += 1,
            }
        }
        // §17.1.1.4: all unknown prints lowercase, partly unknown prints
        // uppercase; the case is the only sign that the digit's known bits
        // were thrown away.
        buf[out] = if (xs == present) 'x' //
            else if (zs == present) 'z' //
            else if (xs != 0) 'X' //
            else if (zs != 0) 'Z' //
            else "0123456789abcdef"[val];
        out += 1;
    }
    return buf[0..out];
}

/// Decimal, where one unknown bit poisons the whole number (§17.1.1.4).
/// Returns error.TooWide for a known operand wider than 64 bits.
pub fn decimalText(buf: []u8, v: Int.Literal) error{TooWide}![]const u8 {
    // ponytail: 64 bits, refused rather than truncated; a bignum divide if
    // a wider `%d` is ever printed.
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
    if (v.width > 64) return error.TooWide;
    const raw = v.values()[0];
    if (v.signed) return std.fmt.bufPrint(buf, "{d}", .{v.asInt().?}) catch unreachable;
    // Not `asInt`: it bit-casts, so an unsigned 64-bit operand at or above
    // 2^63 would print negative. $time is exactly that operand.
    return std.fmt.bufPrint(buf, "{d}", .{raw}) catch unreachable;
}
