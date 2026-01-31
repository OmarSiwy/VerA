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
// %g %s %r %m — with the assignment-suppression `*` and the maximum field
// width. What is deliberately NOT here: `%v`/`%z`/`%t` (strength, 4-state and
// timeformat values, none of which an analog device has), and C's `%n`/`%p`.
// lower.zig refuses those at the call (E0813) rather than letting them scan as
// garbage. The OUTPUT side of §9.4.3 Table 9-23 — the C real conversions and
// the engineering `%r` — is `zCReal`, at the bottom of this file.

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
/// `used` is how many BYTES of `src` the scan consumed, which §9.5.4.2 fixes
/// per directive and not per line: "if conversion terminates on a conflicting
/// input character, the offending input character is left unread in the input
/// stream", and "trailing white space (including newline characters) is left
/// unread unless matched by a directive". `$sscanf` has no position to move,
/// so nothing reads it there; `$fscanf` advances the descriptor by exactly
/// this, which is what makes §9.5.5's `$ftell` answer the clause's number and
/// what lets a failed match be retried against the same bytes.
pub const ZScan = struct { n: i64 = 0, i: i64 = 0, r: f64 = 0.0, s: []const u8 = "", used: usize = 0 };

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
    zScanRun(src, fmt, want, &out);
    return out;
}

/// The walk itself, split out only so `out.used` is written on EVERY exit —
/// there are seven, one per matching failure the clause names, and each has to
/// report the position the offending character was left at.
fn zScanRun(src: []const u8, fmt: []const u8, want: i64, out: *ZScan) void {
    var si: usize = 0;
    defer out.used = si;
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
            if (si >= src.len or src[si] != fc) return;
            si += 1;
            fi += 1;
            continue;
        }
        fi += 1;
        if (fi >= fmt.len) return;
        if (fmt[fi] == '%') { // a literal percent, matched not converted
            if (si >= src.len or src[si] != '%') return;
            si += 1;
            fi += 1;
            continue;
        }
        const suppress = fmt[fi] == '*';
        if (suppress) fi += 1;
        var width: usize = 0;
        while (fi < fmt.len and fmt[fi] >= '0' and fmt[fi] <= '9') : (fi += 1)
            width = width * 10 + (fmt[fi] - '0');
        if (fi >= fmt.len) return;
        const conv = fmt[fi];
        fi += 1;
        // §9.5.4.2 "%m Returns the current hierarchical path as a string. Does
        // not read data from the input file or str argument." Handled BEFORE
        // the white-space skip and before the EOF test, because both of those
        // are properties of reading input and this directive does not: a `%m`
        // with nothing left to scan is still an assignment, and the `%d` after
        // it still sees the whole field.
        if (conv == 'm') {
            if (suppress) continue;
            // ponytail: the path answers empty. §9.4.3's display-side `%m` is
            // substituted by the EMITTER (`cg_display` writes `g.mir.name`
            // into the format), and a scan control string is a RUNTIME value,
            // so the kernel has no name to reach for. Nothing in §9.5.4.2
            // fixes the spelling of "the current hierarchical path" either.
            // The upgrade is threading the module name into the scan call the
            // way the display path already has it.
            if (out.n == want) out.s = "";
            out.n += 1;
            continue;
        }
        if (conv != 'c') {
            while (si < src.len and zstd.ascii.isWhitespace(src[si])) si += 1;
        }
        if (si >= src.len) {
            // "This number can be EOF if the input ends before the first
            // matching failure or conversion" — an input that ran out before
            // anything was tried is that case; one that ran out after an
            // assignment just reports the assignments.
            if (!tried and out.n == 0) out.n = -1;
            return;
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
            // "%r Matches a 'real' number in engineering notation, using the
            // scale factors defined in 2.6.2" is the same number followed by
            // one Table 2-1 symbol, so it rides the same arm.
            'f', 'e', 'g', 'r' => {
                var digits: usize = 0;
                if (end < lim and (src[end] == '+' or src[end] == '-')) end += 1;
                while (end < lim and zDigit(src[end], 10) != null) : (end += 1) digits += 1;
                if (end < lim and src[end] == '.') {
                    end += 1;
                    while (end < lim and zDigit(src[end], 10) != null) : (end += 1) digits += 1;
                }
                if (digits == 0) return; // a sign or a dot alone is a matching failure
                if (end < lim and (src[end] == 'e' or src[end] == 'E')) {
                    var k = end + 1;
                    if (k < lim and (src[k] == '+' or src[k] == '-')) k += 1;
                    if (k < lim and zDigit(src[k], 10) != null) {
                        while (k < lim and zDigit(src[k], 10) != null) k += 1;
                        end = k;
                    }
                }
                item.r = zstd.fmt.parseFloat(f64, src[si..end]) catch return;
                // §2.6.2: "No space is permitted between the number and the
                // symbol", so the scale factor is the very next character —
                // and it is OPTIONAL, because a real with an implied factor of
                // 1 is still a real in engineering notation.
                if (conv == 'r' and end < lim) {
                    if (zScaleOf(src[end])) |f| {
                        item.r *= f;
                        end += 1;
                    }
                }
                item.s = src[si..end];
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
                if (digits == 0) return; // matching failure, e.g. "%d" on "hello"
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
            else => return,
        }
        if (end == si) return; // nothing matched
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
    return;
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

// ---- §9.4.3 Table 9-23: the real conversions -------------------------------
//
// §9.4.3 gives the Table 9-23 conversions "the full formatting capabilities
// available in the C language", so C11 7.21.6.1 is the specification for %e,
// %f and %g — the flag/width/precision prefix AND the rounding. Zig's float
// formatter is not that specification, in three separate ways, each of which
// lost a character on the transcript:
//
//   - `{d}` is shortest-round-trip, so `%g` of 1e8 printed `100000000` where
//     both C and Table 9-23's own "whichever format results in the shorter
//     printed output" want `1e+08`;
//   - `{d:.P}`/`{e:.P}` round the SHORTEST decimal rather than the value, so a
//     precision above 17 digits reports zeros C does not;
//   - and that rounding takes a half AWAY from zero, so `%.0f` of 2.5 printed
//     `3` where C11 7.21.6.1p13's "correctly rounded" — in IEEE 754's default
//     roundTiesToEven direction — is 2.
//
// Table 9-23's `%r`/`%R` is the one row C does not have: "display 'real' in
// engineering notation, using the scale factors defined in 2.6.2". §2.6.2
// Table 2-1 is the whole alphabet (T G M K,k m u n p f a) and "engineering
// notation" fixes the split — the exponent is a multiple of three and the
// mantissa lies in [1, 1000), so 2e-13 is `200f` and never `0.2p`.

/// The flag bits `zCReal` takes, in the order `cg_display.Spec` packs them.
const zc_left: u8 = 1; // '-' left-justify; C makes it override '0'
const zc_plus: u8 = 2; // '+' always spell the sign
const zc_space: u8 = 4; // ' ' a space where the sign would be; '+' wins
const zc_zero: u8 = 8; // '0' pad with zeros AFTER the sign

/// The exact decimal expansion of one finite f64.
///
/// Correct rounding is a property of the EXACT value, and every f64 is m·2^e
/// with m < 2^53, so the expansion TERMINATES: 2^-1074 needs 751 significant
/// digits and 2^1023 needs 309, so 800 holds every finite double with room.
/// `value = 0.d[0..n] × 10^dp`, which keeps the point out of the digit array.
//
// ponytail: one digit-array pass per binary exponent, so the worst case (a
// denormal, |e| = 1074) is ~1074 passes over ~800 digits — microseconds, on a
// path that is already writing to a terminal or a file. The upgrade, if a
// model ever formats reals in a loop, is shifting many bits at a time through
// u64 limbs instead of one bit at a time through decimal digits.
const zc_digits = 800;
const ZCDec = struct {
    d: [zc_digits]u8 = @splat(0),
    n: usize = 0,
    dp: i32 = 0,
    neg: bool = false,
};

/// The digit at significant position `i`, or 0 outside the held run — which is
/// what lets the renderers ask for a fractional digit past the end of an exact
/// expansion without a bounds test at every call.
fn zcAt(z: *const ZCDec, i: i32) u8 {
    if (i < 0) return 0;
    const k: usize = @intCast(i);
    return if (k < z.n) z.d[k] else 0;
}

fn zcTrim(z: *ZCDec) void {
    while (z.n > 0 and z.d[z.n - 1] == 0) z.n -= 1;
    if (z.n == 0) z.dp = 0;
}

fn zcMul2(z: *ZCDec) void {
    var carry: u8 = 0;
    var i = z.n;
    while (i > 0) {
        i -= 1;
        const t = z.d[i] * 2 + carry;
        z.d[i] = t % 10;
        carry = t / 10;
    }
    if (carry != 0) { // one new most-significant digit: the run shifts right
        const keep = @min(z.n, zc_digits - 1);
        var j = keep;
        while (j > 0) : (j -= 1) z.d[j] = z.d[j - 1];
        z.d[0] = carry;
        z.n = keep + 1;
        z.dp += 1;
    }
    zcTrim(z);
}

fn zcDiv2(z: *ZCDec) void {
    var rem: u8 = 0;
    var w: usize = 0;
    var i: usize = 0;
    while (i < z.n) : (i += 1) {
        const cur = rem * 10 + z.d[i];
        rem = cur % 2;
        // `zq` and not `q`: this text is embedded at the FILE SCOPE of a
        // device, where `q` is the generated charge function — Zig forbids a
        // local that shadows a declaration, so every name here has to miss the
        // emitter's own (see `naming.zig`).
        const zq = cur / 2;
        // A leading zero quotient digit is not stored; it moves the point.
        if (w == 0 and zq == 0) z.dp -= 1 else {
            z.d[w] = zq;
            w += 1;
        }
    }
    if (rem != 0 and w < zc_digits) { // halving spills exactly one 5
        z.d[w] = 5;
        w += 1;
    }
    z.n = w;
    zcTrim(z);
}

/// §2.6.2 makes a real an IEEE 754 double, so the operand IS the bit pattern
/// and nothing here depends on decimal parsing.
fn zcFrom(z: *ZCDec, v: f64) void {
    z.* = .{};
    z.neg = zstd.math.signbit(v);
    const bits: u64 = @bitCast(v);
    const be: u11 = @truncate(bits >> 52);
    var m: u64 = bits & 0xf_ffff_ffff_ffff;
    var e2: i32 = undefined;
    if (be == 0) {
        e2 = -1074; // subnormal: no implicit leading bit
    } else {
        m |= @as(u64, 1) << 52;
        e2 = @as(i32, be) - 1075;
    }
    if (m == 0) return; // ±0 is the empty digit run
    var tmp: [20]u8 = undefined;
    var k: usize = 0;
    while (m != 0) : (m /= 10) {
        tmp[k] = @intCast(m % 10);
        k += 1;
    }
    var i: usize = 0;
    while (i < k) : (i += 1) z.d[i] = tmp[k - 1 - i];
    z.n = k;
    z.dp = @intCast(k);
    zcTrim(z);
    var j: i32 = 0;
    while (j < e2) : (j += 1) zcMul2(z);
    while (j > e2) : (j -= 1) zcDiv2(z);
}

/// The SHORTEST round-trip decimal of one f64, in the same shape. `%r` wants
/// this and not the exact expansion: the engineering rendering of 0.0015 is
/// `1.5m`, not the 55 digits 0.0015 exactly is.
fn zcShortest(z: *ZCDec, v: f64) void {
    z.* = .{};
    z.neg = zstd.math.signbit(v);
    var tb: [64]u8 = undefined;
    // `[-]d[.ddd]e[-]X` — std's scientific mode, which is Ryu's shortest.
    const t = zstd.fmt.float.render(&tb, v, .{ .mode = .scientific }) catch return;
    var i: usize = 0;
    if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
    var lead: i32 = 0; // digits before the point: always exactly one here
    while (i < t.len and t[i] != 'e') : (i += 1) {
        if (t[i] == '.') continue;
        if (z.n < zc_digits) {
            z.d[z.n] = t[i] - '0';
            z.n += 1;
        }
        if (lead == 0) lead = 1;
    }
    const e10 = if (i < t.len) zstd.fmt.parseInt(i32, t[i + 1 ..], 10) catch 0 else 0;
    z.dp = e10 + lead;
    zcTrim(z);
}

/// Keep `keep` significant digits, C11 7.21.6.1p13 "correctly rounded" in
/// IEEE 754's default direction: ties go to the EVEN last digit, which is what
/// makes %.0f of 2.5 answer 2 and of 3.5 answer 4.
fn zcRound(z: *ZCDec, keep: i32) void {
    if (keep < 0) {
        z.* = .{ .neg = z.neg };
        return;
    }
    const k: usize = @intCast(keep);
    if (k >= z.n) return;
    const first = z.d[k];
    var up = first > 5;
    if (first == 5) {
        var rest = false;
        var i = k + 1;
        while (i < z.n) : (i += 1) if (z.d[i] != 0) {
            rest = true;
            break;
        };
        // An exact tie (nothing but the 5 below) goes to the even candidate;
        // the digit before position 0 is an implicit 0, which is even.
        up = rest or (k > 0 and z.d[k - 1] % 2 == 1);
    }
    z.n = k;
    if (up) {
        var i = k;
        while (i > 0) {
            i -= 1;
            if (z.d[i] != 9) {
                z.d[i] += 1;
                return zcTrim(z);
            }
            z.d[i] = 0;
        }
        z.d[0] = 1; // 999… carried out, or `keep` was 0 and the value rounds up
        z.n = 1;
        z.dp += 1;
        return;
    }
    zcTrim(z);
}

/// A bounded writer over the caller's scratch row. An overrun is dropped
/// rather than wrapped: the emitter sizes the row from the same width and
/// precision this reads, so a short row is a codegen bug, not input.
const ZCOut = struct {
    b: []u8,
    n: usize = 0,
    fn put(self: *ZCOut, c: u8) void {
        if (self.n < self.b.len) {
            self.b[self.n] = c;
            self.n += 1;
        }
    }
    fn str(self: *ZCOut, s: []const u8) void {
        for (s) |c| self.put(c);
    }
};

/// C's %f body: the integer part, then exactly `p` fractional digits.
fn zcFixed(o: *ZCOut, z: *ZCDec, p: usize) void {
    zcRound(z, z.dp + @as(i32, @intCast(p)));
    if (z.dp <= 0) {
        o.put('0');
    } else {
        var i: i32 = 0;
        while (i < z.dp) : (i += 1) o.put('0' + zcAt(z, i));
    }
    if (p == 0) return;
    o.put('.');
    var t: usize = 1;
    while (t <= p) : (t += 1) o.put('0' + zcAt(z, z.dp + @as(i32, @intCast(t)) - 1));
}

/// C's %e body: one digit, `p` fractional digits, then a signed exponent of at
/// least two digits — `1.500000e+00`, which Zig's `{e}` spells `1.5e0`.
///
/// `strip_from` is %g's trailing-zero removal, applied to the MANTISSA before
/// the exponent is appended — stripping the finished text instead would eat
/// the `00` of `e+00`.
fn zcSci(o: *ZCOut, z: *ZCDec, p: usize, upper: bool, strip_from: ?usize) void {
    zcRound(z, @intCast(p + 1));
    const x: i32 = if (z.n == 0) 0 else z.dp - 1;
    o.put('0' + zcAt(z, 0));
    if (p > 0) {
        o.put('.');
        var t: usize = 1;
        while (t <= p) : (t += 1) o.put('0' + zcAt(z, @intCast(t)));
    }
    if (strip_from) |from| zcStrip(o, from);
    o.put(if (upper) 'E' else 'e');
    o.put(if (x < 0) '-' else '+');
    const mag: u32 = @intCast(if (x < 0) -x else x);
    var eb: [8]u8 = undefined;
    const es = zstd.fmt.bufPrint(&eb, "{d}", .{mag}) catch "0";
    if (es.len < 2) o.put('0');
    o.str(es);
}

/// C's %g trailing-zero removal: "trailing zeros are removed from the
/// fractional portion of the result and the decimal-point character is removed
/// if there is no fractional portion remaining". `from` is where the body the
/// rule applies to started, so an exponent appended afterwards is untouched.
fn zcStrip(o: *ZCOut, from: usize) void {
    var dot = false;
    for (o.b[from..o.n]) |c| if (c == '.') {
        dot = true;
        break;
    };
    if (!dot) return;
    while (o.n > from and o.b[o.n - 1] == '0') o.n -= 1;
    if (o.n > from and o.b[o.n - 1] == '.') o.n -= 1;
}

/// §2.6.2 Table 2-1's scale symbol for a power of ten, or 0 for 1e0 — which
/// the table has no row for, so an unscaled mantissa gets no suffix.
/// ponytail: 1e3 is spelled "K, k" and no clause says which an OUTPUT uses;
/// the first spelling in the table is the one emitted.
fn zcScaleSym(g: i32) u8 {
    return switch (g) {
        12 => 'T',
        9 => 'G',
        6 => 'M',
        3 => 'K',
        -3 => 'm',
        -6 => 'u',
        -9 => 'n',
        -12 => 'p',
        -15 => 'f',
        -18 => 'a',
        else => 0,
    };
}

/// §9.4.3 Table 9-23 one real conversion, whole field, C11 7.21.6.1 semantics.
///
/// `conv` is the source's own letter (its case decides `e`/`E` and INF/NAN),
/// `flags` is the `zc_*` bitset, and `prec` is -1 when the source gave no
/// precision field. The WIDTH is applied here rather than by an outer `{s:>W}`
/// because C's '0' flag puts the pad between the sign and the digits — a field
/// of zeros with the sign buried inside is not a number.
pub fn zCReal(buf: []u8, v: f64, conv: u8, flags: u8, width: usize, prec: i64) []const u8 {
    const upper = conv >= 'A' and conv <= 'Z';
    const c = conv | 0x20;
    var o: ZCOut = .{ .b = buf };
    const neg = zstd.math.signbit(v);
    const sgn: u8 = if (neg) '-' else if (flags & zc_plus != 0) '+' else if (flags & zc_space != 0) ' ' else 0;
    // C: an infinity or a NaN takes the sign flags and the width, but never the
    // zero fill — "for a, A, e, E, f, F, g, and G conversions ... the 0 flag is
    // ignored" once the result is not a number.
    var special = false;
    if (zstd.math.isNan(v) or zstd.math.isInf(v)) {
        special = true;
        if (!zstd.math.isNan(v) and sgn != 0) o.put(sgn);
        if (zstd.math.isNan(v)) o.str(if (upper) "NAN" else "nan") else o.str(if (upper) "INF" else "inf");
    } else if (c == 'r') {
        if (sgn != 0) o.put(sgn);
        var z: ZCDec = undefined;
        zcShortest(&z, v);
        // Engineering notation: the exponent is a multiple of three and the
        // mantissa is in [1, 1000), which picks exactly one Table 2-1 symbol.
        const x: i32 = if (z.n == 0) 0 else z.dp - 1;
        var g: i32 = @divFloor(x, 3) * 3;
        g = @min(12, @max(-18, g)); // outside the table the mantissa absorbs it
        z.dp -= g;
        const body = o.n;
        const p: usize = if (prec >= 0)
            @intCast(prec)
        else if (z.n > 0 and z.dp < @as(i32, @intCast(z.n)))
            z.n - @as(usize, @intCast(@max(z.dp, 0)))
        else
            0;
        zcFixed(&o, &z, p);
        if (prec < 0) zcStrip(&o, body);
        const sym = zcScaleSym(g);
        if (sym != 0) o.put(sym);
    } else {
        if (sgn != 0) o.put(sgn);
        var z: ZCDec = undefined;
        zcFrom(&z, v);
        const body = o.n;
        if (c == 'e') {
            zcSci(&o, &z, if (prec < 0) 6 else @intCast(prec), upper, null);
        } else if (c == 'f' or prec >= 0) {
            // §9.4.3's own worked example — "%10.3g sets a minimum field width
            // of 10 with three (3) fractional digits" — reads a %g precision as
            // FRACTIONAL digits where C11 7.21.6.1 reads it as SIGNIFICANT
            // digits. The two cannot both hold; with an explicit precision the
            // clause's printed example is what VerA follows, because a tool
            // that follows the LRM's own example is following the LRM. See
            // tests/fixtures/ch09_system_tasks/s01_01_*.va, which withdraws the
            // explicit-precision rows for exactly this reason.
            zcFixed(&o, &z, if (prec < 0) 6 else @intCast(prec));
        } else {
            // %g with NO precision: there the contradiction cannot arise, and
            // C's rule and Table 9-23's "whichever format results in the
            // shorter printed output" agree on every value.
            const pg: i32 = 6; // C's default precision for %g
            zcRound(&z, pg);
            const x: i32 = if (z.n == 0) 0 else z.dp - 1;
            if (x < -4 or x >= pg) {
                zcSci(&o, &z, @intCast(pg - 1), upper, body);
            } else {
                // C: style f with precision P - 1 - X, then strip.
                zcFixed(&o, &z, @intCast(@max(pg - 1 - x, 0)));
                zcStrip(&o, body);
            }
        }
    }

    if (o.n >= width) return o.b[0..o.n];
    const pad = width - o.n;
    if (flags & zc_left != 0) { // '-' wins over '0' and pads on the right
        while (o.n < width) o.put(' ');
        return o.b[0..width];
    }
    if (width > o.b.len) return o.b[0..o.n];
    const keep: usize = if (flags & zc_zero != 0 and !special and sgn != 0) 1 else 0;
    zstd.mem.copyBackwards(u8, o.b[keep + pad .. width], o.b[keep..o.n]);
    @memset(o.b[keep .. keep + pad], if (flags & zc_zero != 0 and !special) '0' else ' ');
    return o.b[0..width];
}

// ---- §9.4.1 the $monitor mechanism ----------------------------------------

/// §9.4.1, the sentence that separates `$monitor` from `$strobe`:
///
///   "When a $monitor task is invoked with one or more arguments, the simulator
///    sets up a mechanism whereby for each accepted step, IF THE VARIABLE OR AN
///    EXPRESSION IN THE ARGUMENT LIST CHANGES VALUE compared with the last
///    accepted step ... the entire argument list is displayed at the end of the
///    time step as if reported by the $strobe task. If two or more arguments
///    change value at the same time, ONLY ONE DISPLAY IS PRODUCED."
///
/// §9.5.2 carries it verbatim to `$fmonitor`: "the $fstrobe and $fmonitor
/// system tasks work just like their counterparts ... except that they write to
/// files using the file descriptor".
///
/// WHY THE RENDERED LINE IS THE COMPARISON and not a sensitivity list over the
/// arguments. "Only one display is produced that shows the new values" makes
/// the obligation a property of the RECORD, not of any one argument, and the
/// record is the only thing that exists once the format run has consumed the
/// operands — an argument may be an expression with no storage of its own, and
/// two different values may render identically (a `%d` of 2.0 and of 2.4), in
/// which case the clause's own words say the display "shows the new values"
/// and there are none to show. `src/sim/digital.zig`'s `monitorPrint` takes
/// exactly this route for exactly this reason; this is the analog half of the
/// same rule.
///
/// Returns the text when it differs from what this site last reported — which
/// includes the FIRST accepted step, where there is no "last accepted step" to
/// compare against — and null when the step is to be suppressed.
//
// ponytail: one 4096-byte latch per call site, file scope, on `zSBuf`'s terms
// and for `zSBuf`'s reason — the comparison has to outlive the step that made
// it. A record longer than the latch is reported every step rather than
// compared; per-instance latches are the upgrade the day a host runs two
// instances of a model that monitors.
pub fn zMonitor(comptime site: usize, text: []const u8) ?[]const u8 {
    const Last = struct {
        const n = site;
        var b: [4096]u8 = undefined;
        var len: usize = 0;
        var seen: bool = false;
    };
    if (text.len > Last.b.len) return text;
    if (Last.seen and Last.len == text.len and zstd.mem.eql(u8, Last.b[0..text.len], text)) return null;
    @memcpy(Last.b[0..text.len], text);
    Last.len = text.len;
    Last.seen = true;
    return text;
}

/// §3.3 string storage excludes NUL bytes. Compact the completed formatter
/// output in its existing call-site scratch; padding counted the original bytes.
/// ponytail: scalar compaction is bounded by the existing 512-byte formatter;
/// consider mask-based compaction if that ceiling is removed and measured hot.
pub fn zStringStore(bytes: []u8) []const u8 {
    var used: usize = 0;
    for (bytes) |byte| {
        if (byte == 0) continue;
        bytes[used] = byte;
        used += 1;
    }
    return bytes[0..used];
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
// ponytail: 4096 bytes per site, file-scope. Two threads evaluating the SAME
// call site on different instances would interleave; per-instance scratch is
// the upgrade the day a host runs a device's units concurrently. An overrun
// formats to the empty string rather than truncating, because §9.5.3 gives no
// truncation rule to follow.
//
// The row was 512 and that was a LIMIT no clause states: §9.4.3 makes the C
// minimum field width part of the real conversions, so `$fdisplay(fd,
// "%600.2f", …)` is a 601-byte record a conforming tool writes — and the old
// row dropped it entirely (the overrun rule above) rather than truncating it,
// leaving a zero-length file. 4096 is `cg_display.Spec.max_field` and
// `file_kernels.ZFSlot.line`, so what this can compose is what a §9.5.2 write
// can emit and a §9.5.4.1 `$fgets` can read back in one call.
pub fn zSBuf(comptime site: usize) []u8 {
    const Buf = struct {
        const n = site;
        var b: [4096]u8 = undefined;
    };
    return &Buf.b;
}

/// §2.6.2 Table 2-1's scale factor for one symbol, or null when the character
/// is not one. The 1e3 row is spelled "K, k", so a SCANNER takes both — which
/// is why no fixture may pin which of the two an output prints.
fn zScaleOf(c: u8) ?f64 {
    return switch (c) {
        'T' => 1e12,
        'G' => 1e9,
        'M' => 1e6,
        'K', 'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        'a' => 1e-18,
        else => null,
    };
}

/// The value of `c` as a digit in `radix`, or null when it is not one.
fn zDigit(c: u8, radix: u8) ?u8 {
    // ponytail: keep the existing hex-digit ceiling even for a larger radix.
    return zstd.fmt.charToDigit(c, @min(radix, 16)) catch null;
}
