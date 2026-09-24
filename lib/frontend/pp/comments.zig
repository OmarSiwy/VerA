//! §2.4 comments: `//` and `/* */` removed, newlines kept.
//!
//! In: source bytes. Out: the same bytes with comments blanked and a mark table mapping the
//! stripped text back to source offsets for diagnostics.
//!
//! LRM clauses this file's code cites: §2.2, §2.4, §2.7, §2.8.1.
//!
//! Cut verbatim from `preprocessor.zig`.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const diag = @import("diag");
const Error = Preprocessor.Error;
const Pp = Preprocessor.Pp;
const findStop = Preprocessor.findStop;
const stringStop = Preprocessor.stringStop;
const isSpace = Preprocessor.isSpace;

// ---------------------------------------------------------------------------
// §2.4 comments
// ---------------------------------------------------------------------------

pub const Stripped = struct { text: []const u8, marks: []const diag.StripMark };

/// Replace `//`- and `/* */`-comments with nothing, keeping every newline they
/// contained so line numbers survive. String literals (§2.7) are opaque.
/// Block comments do NOT nest (§2.4) — `/* a /* b */` ends at the first `*/`.
///
/// Also returns one `diag.StripMark` per comment collapsed — the stripped→
/// original offset map the renderer needs to put a caret on the line the user
/// WROTE. LINES already agree between the two texts (that is the newline
/// contract above); what a comment shifts is every COLUMN after it, and every
/// absolute offset below it, in ways only the stripper knows.
pub fn stripComments(pp: *Pp, src: []const u8) Error!Stripped {
    // Fast path: most sources shrink, none grow.
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, src.len);
    var marks: std.ArrayList(diag.StripMark) = .empty;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            const start = i;
            // §2.7: an unterminated literal is the lexer's error to report; stop
            // at the newline so the rest of the file still preprocesses.
            i = stringStop(src, i);
            if (i < src.len and src[i] == '"') i += 1;
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1 escaped identifier (or a `define line continuation):
            // opaque up to the next whitespace, so `//` inside cannot start a
            // comment.
            const start = i;
            i += 1;
            while (i < src.len and !isSpace(src[i])) i += 1;
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            // §2.4: to the end of the line. `indexOfScalarPos` IS vectorized in
            // the stdlib (`std/mem.zig:1241`), unlike the set-valued `findAnyPos`.
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            // The output stood still while the input advanced: from here the
            // two run in lockstep again, which is exactly one mark.
            try marks.append(pp.arena, .{ .out = @intCast(out.items.len), .src = @intCast(i) });
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            // Offsets here index `src`, which runFile registered before this
            // call precisely so this span resolves.
            if (i + 1 >= src.len) return pp.fail(pp.spanAt(start, start + 2), .E0102, "", .{});
            // §2.2: "spaces and newlines shall not be syntactically significant
            // other than being token separators", and the same list makes a
            // comment one of the seven lexical tokens — so a comment SEPARATES
            // the tokens around it. Re-emitting only the newlines is enough for
            // a multi-line comment and silently WELDS a single-line one:
            // `1/*c*/2` used to lex as the integer 12 and `<` `/*c*/` `=` as the
            // operator `<=`, both with no diagnostic. One byte of whitespace
            // fixes both, and it always fits: the comment it replaces is at
            // least the four bytes of `/**/`.
            const lines = std.mem.count(u8, src[start..i], "\n");
            if (lines == 0) {
                out.appendAssumeCapacity(' ');
            } else {
                out.appendNTimesAssumeCapacity('\n', lines);
            }
            i += 2;
            // After the replacement bytes, so the lockstep run the mark opens
            // starts at the first byte AFTER the comment on both sides.
            try marks.append(pp.arena, .{ .out = @intCast(out.items.len), .src = @intCast(i) });
            continue;
        }
        // Ordinary text: copy the whole run up to the next byte the branches
        // above care about, in one `appendSlice`. Same chain-outside /
        // scan-inside split as `scan`.
        //
        // `src[i]` is neither `"` nor `\` — both `continue` above — but it CAN
        // be a `/` that starts neither comment: at end of file, or before an
        // ordinary byte. That is the `end == i` case, and stepping one byte is
        // cheaper than teaching the stop set to exclude it.
        const end = findStop(src, i, "\"\\/");
        if (end == i) {
            out.appendAssumeCapacity(c);
            i += 1;
        } else {
            out.appendSliceAssumeCapacity(src[i..end]);
            i = end;
        }
    }
    return .{ .text = out.items, .marks = marks.items };
}
