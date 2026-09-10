// §9.5.3 / §9.5.4.2 string formatting and scanning kernels — EMITTED VERBATIM
// into every device that calls `$sformat`/`$swrite`/`$sscanf` (`codegen.str_txt`
// is `@embedFile` of this file) and `@import`ed by codegen.zig's tests. One
// source, so the conversions the tests check are the conversions the device
// runs.
//
// WHY THE SCANNER RE-PARSES. `$sscanf(str, fmt, a, b)` assigns to two variables
// and returns a count, but a unit body is an SSA expression tree: a value is
// what a call RETURNS, and there is no out-parameter to write through. So
// lowering turns one source call into one `zScanN` (the count) plus one
// `zScan{I,R,S}` per output argument, each naming the item it wants by index,
// and every one of them re-runs the same pure scan over the same two strings.
// A conversion of a handful of characters is cheaper than the machinery an
// out-parameter would need in the emitter, and nothing observes the difference:
// the scan has no state and no side effects.
//
// SCOPE. The conversion codes are §9.5.4.2's own list — %d %o %h %x %b %c %f %e
// %g %s — with the assignment-suppression `*` and the maximum field width. What
// is deliberately NOT here: `%v`/`%z`/`%t` (strength, 4-state and timeformat
// values, none of which an analog device has), and C's `%n`/`%p`. lower.zig
// refuses those at the call (E0813) rather than letting them scan as garbage.

// `std` is spelled `zstd` HERE because this text is embedded VERBATIM into
// device.zig and h.zig, both of which already declare `const std` in their own
// header — a second `const std` at the same file scope is a redeclaration. The
// alias also lets codegen.zig's tests `@import` this file directly, which is the
// whole reason the kernels live in a real Zig file (see filter_kernels.zig).
const zstd = @import("std");

/// One scan. `n` is §9.5.4.2's return — the number of items "successfully
/// matched and assigned", -1 (EOF) when the input ends before any conversion —
/// and the other three fields carry the value of the ONE item the caller asked
/// for, in all three types, because the destination's type is the caller's
/// business and a `%d` may legally land in a `real` variable (§4.2.1.1).
pub const ZScan = struct { n: i64 = 0, i: i64 = 0, r: f64 = 0.0, s: []const u8 = "" };

/// §9.5.4.2 `$sscanf`. `want` is the index of the assigned item whose value is
/// reported; -1 asks for the count alone.
///
/// The control string is walked once. §9.5.4.2: "An input field is defined as a
/// string of nonspace characters; it extends to the next inappropriate character
/// or until the maximum field width, if one is specified, is exhausted", and
/// "for all descriptors except the character c, white space leading an input
/// field is ignored".
pub fn zScan(src: []const u8, fmt: []const u8, want: i64) ZScan {
    var out: ZScan = .{};
    var si: usize = 0;
    var fi: usize = 0;
    var tried = false; // has any conversion started with input still available?
    while (fi < fmt.len) {
        const fc = fmt[fi];
        // Whitespace in the control string matches any run of whitespace,
        // including none.
        if (zstd.ascii.isWhitespace(fc)) {
            fi += 1;
            while (si < src.len and zstd.ascii.isWhitespace(src[si])) si += 1;
            continue;
        }
        if (fc != '%') { // ordinary character: it must be there
            if (si >= src.len or src[si] != fc) return out;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return out;
        if (fmt[fi] == '%') { // a literal percent, matched not converted
            if (si >= src.len or src[si] != '%') return out;
            si += 1;
            fi += 1;
            continue;
        }
        const suppress = fmt[fi] == '*';
        if (suppress) fi += 1;
        var width: usize = 0;
        while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') : (fi += 1)
            width = width * 10 + (fmt[fi] - '0');
        if (fi >= fmt.len) return out;
        const conv = fmt[fi];
        fi += 1;
        if (conv != 'c') {
            while (si < src.len and zstd.ascii.isWhitespace(src[si])) si += 1;
        }
        if (si >= src.len) {
            // "This number can be EOF if the input ends before the first
            // matching failure or conversion" — an input that ran out before
            // anything was tried is that case; one that ran out after an
            // assignment just reports the assignments.
            if (!tried and out.n == 0) out.n = -1;
            return out;
        }
        tried = true;
        const lim = if (width == 0) src.len else @min(src.len, si + width);
        var item: ZScan = .{};
        var end = si;
        switch (conv) {
            // §9.5.4.2 "%c Matches a single character. The normal skip over
            // white space is suppressed" — a width takes that many characters.
            'c' => {
                end = @min(lim, si + @max(width, 1));
                item.i = src[si];
                item.r = @floatFromInt(item.i);
                item.s = src[si..end];
            },
            // "%s Matches a string, which is a sequence of nonwhite space
            // characters." The int/real views are the §2.7 base-256 reading a
            // string operand has everywhere else, which nothing needs but which
            // costs one loop.
            's' => {
                while (end < lim and !zstd.ascii.isWhitespace(src[end])) end += 1;
                item.s = src[si..end];
                for (item.s) |ch| item.i = item.i *% 256 +% ch;
                item.r = @floatFromInt(item.i);
            },
            // "%f, %e, or %g Matches a floating point number" — the C shape:
            // sign, digits, fraction, exponent. Parsed with the standard
            // library on the matched slice so the rounding is the one every
            // other real literal in the device gets.
            'f', 'e', 'g' => {
                var digits: usize = 0;
                if (end < lim and (src[end] == '+' or src[end] == '-')) end += 1;
                while (end < lim and zDigit(src[end], 10) != null) : (end += 1) digits += 1;
                if (end < lim and src[end] == '.') {
                    end += 1;
                    while (end < lim and zDigit(src[end], 10) != null) : (end += 1) digits += 1;
                }
                if (digits == 0) return out; // a sign or a dot alone is a matching failure
                if (end < lim and (src[end] == 'e' or src[end] == 'E')) {
                    var k = end + 1;
                    if (k < lim and (src[k] == '+' or src[k] == '-')) k += 1;
                    if (k < lim and zDigit(src[k], 10) != null) {
                        while (k < lim and zDigit(src[k], 10) != null) k += 1;
                        end = k;
                    }
                }
                item.s = src[si..end];
                item.r = zstd.fmt.parseFloat(f64, item.s) catch return out;
                // Saturating (`lossyCast`), like every other real→int cast the
                // device performs: this text ships in ReleaseFast artifacts,
                // where an unguarded `@intFromFloat` of "1e300" is UB. The
                // hand-rolled range check this replaces answered 0 out of
                // range, which was one more arbitrary rule than needed.
                item.i = zstd.math.lossyCast(i64, @trunc(item.r));
            },
            // The four radix codes. "%d Matches an optionally signed decimal
            // number, consisting of the optional sign from the set + or -,
            // followed by a sequence of characters from the set
            // 0,1,2,3,4,5,6,7,8,9, and _" — the underscore is a §2.6.1 digit
            // separator and is skipped, not converted, in every radix.
            'd', 'o', 'b', 'h', 'x' => {
                const radix: u8 = switch (conv) {
                    'b' => 2,
                    'o' => 8,
                    'h', 'x' => 16,
                    else => 10,
                };
                var neg = false;
                if (end < lim and (src[end] == '+' or src[end] == '-')) {
                    neg = src[end] == '-';
                    end += 1;
                }
                var digits: usize = 0;
                var acc: i64 = 0;
                while (end < lim) : (end += 1) {
                    if (src[end] == '_') continue;
                    const d = zDigit(src[end], radix) orelse break;
                    acc = acc *% radix +% d;
                    digits += 1;
                }
                if (digits == 0) return out; // matching failure, e.g. "%d" on "hello"
                item.i = if (neg) -acc else acc;
                item.r = @floatFromInt(item.i);
                item.s = src[si..end];
            },
            // NOT unreachable: `lower.checkScanFormat` only runs when the
            // format argument CONST-FOLDS to a string, so a format held in a
            // string variable or built at run time arrives here unchecked.
            // §9.5.4.2 makes an invalid conversion character "implementation
            // dependent"; the choice here is to stop the scan, which reports
            // the items assigned so far rather than counting one that was
            // never converted.
            else => return out,
        }
        if (end == si) return out; // nothing matched
        si = end;
        if (suppress) continue; // "matched and assigned": consumed, not counted
        // ponytail: count is the next assigned index; EOF is set only on return.
        if (out.n == want) {
            out.i = item.i;
            out.r = item.r;
            out.s = item.s;
        }
        out.n += 1;
    }
    return out;
}

/// §9.5.4.2's return value on its own.
pub fn zScanN(src: []const u8, fmt: []const u8) i64 {
    return zScan(src, fmt, -1).n;
}

/// Item `k`, in the destination variable's declared type (§3.2). An item the
/// scan never reached reads as zero — see the ceiling note in `codegen.emitSysCall`.
pub fn zScanI(src: []const u8, fmt: []const u8, k: i64) i64 {
    return zScan(src, fmt, k).i;
}

pub fn zScanR(src: []const u8, fmt: []const u8, k: i64) f64 {
    return zScan(src, fmt, k).r;
}

pub fn zScanS(src: []const u8, fmt: []const u8, k: i64) []const u8 {
    return zScan(src, fmt, k).s;
}

/// Scratch for ONE `$sformat`/`$swrite` call site, keyed by the site's MIR
/// instruction id. The formatted bytes have to outlive the expression that
/// produced them — a string slot is a `[]const u8` and the writer is a
/// subexpression — so the storage cannot be a local in the emitted block.
///
/// A distinct `site` instantiates a distinct `Buf`, and therefore a distinct
/// array: that is what keeps two `$sformat` calls in one module from writing
/// over each other, which §9.5.3 requires (each names its own string variable).
///
// ponytail: 512 bytes per site, file-scope. Two threads evaluating the SAME
// call site on different instances would interleave; per-instance scratch is
// the upgrade the day a host runs a device's units concurrently. An overrun
// formats to the empty string rather than truncating, because §9.5.3 gives no
// truncation rule to follow.
pub fn zSBuf(comptime site: usize) []u8 {
    const Buf = struct {
        const n = site;
        var b: [512]u8 = undefined;
    };
    return &Buf.b;
}

/// The value of `c` as a digit in `radix`, or null when it is not one.
fn zDigit(c: u8, radix: u8) ?u8 {
    // ponytail: keep the existing hex-digit ceiling even for a larger radix.
    return zstd.fmt.charToDigit(c, @min(radix, 16)) catch null;
}
