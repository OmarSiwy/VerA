//! lib/frontend/'s byte scans, one `export fn` each, so a later edit that
//! makes one scalar again shows in the assembly. In: the text as a C-ABI
//! pointer and a length, and the start index; out: the index the scan in
//! its source file returns. No LRM clause: these check VerA's own lexer and
//! preprocessor.
//!
//! Counts are asm_probe.py's `vector` column on x86_64_v3, ReleaseFast; the
//! per-byte loop each one replaced has none.
//!
//! expect: ident_end vector>=12 (21; lexer.identEnd)
//! expect: find_stop vector>=8 (10; preprocessor.findStop over `scan_stops`)
const std = @import("std");

/// lexer.identEnd: the first byte at or after `i` that is not a §2.8
/// identifier character.
export fn ident_end(p: [*]const u8, n: usize, i: usize) usize {
    const s = p[0..n];
    var k = i;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (k + lanes <= s.len) : (k += lanes) {
            const b: V = s[k..][0..lanes].*;
            const letter: Mask = @bitCast((b | @as(V, @splat(0x20))) -% @as(V, @splat('a')) < @as(V, @splat(26)));
            const digit: Mask = @bitCast(b -% @as(V, @splat('0')) < @as(V, @splat(10)));
            const under: Mask = @bitCast(b == @as(V, @splat('_')));
            const dollar: Mask = @bitCast(b == @as(V, @splat('$')));
            const out = ~(letter | digit | under | dollar);
            if (out != 0) return k + @ctz(out);
        }
    }
    while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_' or s[k] == '$')) k += 1;
    return k;
}

/// preprocessor.findStop with `scan_stops`: the first `"`, `\` or '`' at or
/// after `i`.
export fn find_stop(p: [*]const u8, n: usize, i: usize) usize {
    const text = p[0..n];
    const stops = "\"\\`";
    var k = i;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (k + lanes <= text.len) : (k += lanes) {
            const block: V = text[k..][0..lanes].*;
            var hit: Mask = 0;
            inline for (stops) |stop| hit |= @as(Mask, @bitCast(block == @as(V, @splat(stop))));
            if (hit != 0) return k + @ctz(hit);
        }
    }
    while (k < text.len) : (k += 1) {
        inline for (stops) |stop| if (text[k] == stop) return k;
    }
    return k;
}
