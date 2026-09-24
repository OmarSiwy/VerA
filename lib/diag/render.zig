//! Rendering: the bag as terminal text or JSON.
//!
//! In: the bag and the source map. Out: human-readable text with source excerpts, or one
//! JSON object per diagnostic.
//!
//! Cut verbatim from `diag.zig`.

const std = @import("std");
const diag = @import("../diag.zig");
const diag_bag = @import("bag.zig");
const diag_entry = @import("entry.zig");
const diag_location = @import("location.zig");
const Allocator = diag.Allocator;
const Code = diag.Code;
const info = diag.info;
const Severity = diag.Severity;

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// SGR escapes, or all-empty when colour is off. Keeping the "off" palette as
/// a full struct of empty strings means the renderer has exactly ONE code path:
/// there is no `if (color)` anywhere below, so the coloured and plain outputs
/// cannot drift apart.
pub const Palette = struct {
    reset: []const u8 = "",
    bold: []const u8 = "",
    err: []const u8 = "",
    warn: []const u8 = "",
    gutter: []const u8 = "",
    note: []const u8 = "",
    help: []const u8 = "",
    good: []const u8 = "",

    pub const off: Palette = .{};

    pub const on: Palette = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .err = "\x1b[1;31m", // bold red
        .warn = "\x1b[1;33m", // bold yellow
        .gutter = "\x1b[1;34m", // bold blue
        .note = "\x1b[1;36m", // bold cyan
        .help = "\x1b[1;36m",
        .good = "\x1b[1;32m", // bold green — suggested insertions
    };

    fn forSeverity(self: Palette, s: Severity) []const u8 {
        return switch (s) {
            .err => self.err,
            .warning => self.warn,
        };
    }
};

pub const RenderOptions = struct {
    palette: Palette = .off,
    /// Draw the source snippet with carets. Off gives one `file:line:col:`
    /// line per diagnostic, which is what an editor's error parser wants.
    snippets: bool = true,
    /// Print `= help: run --explain EXXXX` after the first diagnostic carrying
    /// each code.
    explain_hint: bool = true,
    /// Print the `N errors, M warnings emitted` trailer.
    summary: bool = true,
};

/// Tabs are expanded to this many spaces before a snippet is drawn, so a caret
/// lands under the character it means. (rustc does the same.)
pub const tab_width = 4;

pub fn displayCol(line: []const u8, byte_col: u32) u32 {
    var col: u32 = 0;
    const upto = @min(byte_col, line.len);
    for (line[0..upto]) |c| {
        // A UTF-8 continuation byte (0b10xxxxxx) is part of the codepoint the
        // lead byte already counted, not a column of its own — counting BYTES
        // pushed the caret one column right per extra byte of every `µ`, `Ω`,
        // `°`. Counting lead bytes IS `std.unicode`'s codepoint count, minus
        // the error path invalid input must not take here. (Codepoints, not
        // grapheme clusters or wcwidth: same approximation rustc makes.)
        if (c & 0xC0 == 0x80) continue;
        col += if (c == '\t') tab_width else 1;
    }
    return col;
}

pub fn writeExpanded(w: *std.Io.Writer, line: []const u8) !void {
    for (line) |c| {
        if (c == '\t') try w.splatByteAll(' ', tab_width) else try w.writeByte(c);
    }
}

/// One span, resolved all the way to something printable.
pub const Placed = struct {
    file: diag_location.FileId,
    /// 1-based line in the ORIGINAL file.
    line: u32,
    col: u32,
    /// Display width of the underline, at least 1.
    width: u32,
    text: []const u8,
    primary: bool,
};

/// Renders `bag` to `w`. Entries are sorted into source order first, so the
/// output of a run is stable regardless of which stage found what.
pub fn render(bag: *diag_bag.Bag, w: *std.Io.Writer, opts: RenderOptions) !void {
    if (bag.list.items.len == 0 and bag.suppressed == 0) return;
    bag.sort();

    const p = opts.palette;

    // Rendering scratch (line indices, the per-entry placed list, the
    // seen-codes set) is freed here rather than left on `bag.arena`: after
    // `detach` that arena IS the caller's gpa, so leaving it would leak on
    // every render of a detached bag.
    var scratch_state = std.heap.ArenaAllocator.init(bag.arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    // Line indices are built lazily, once per file that actually appears in a
    // diagnostic. A 60-file include tree with one error touches one index.
    const n_files = @max(bag.files.items.len, 1);
    const indices = try scratch.alloc(?diag_location.LineIndex, n_files);
    @memset(indices, null);

    var explained: std.AutoHashMapUnmanaged(Code, void) = .empty;

    for (bag.messages()) |mi| {
        try renderOne(bag, scratch, w, opts, bag.get(mi), indices, &explained);
    }

    if (bag.suppressed != 0) {
        try w.print("{s}{s}:{s} {d} further diagnostic(s) not shown (limit {d})\n", .{
            p.warn, "warning", p.reset, bag.suppressed, diag_bag.max_entries,
        });
    }
    if (opts.summary and (bag.err_count != 0 or bag.warn_count != 0)) {
        if (bag.err_count != 0) {
            try w.print("{s}error{s}: could not compile due to {d} previous error(s)", .{
                p.err, p.reset, bag.err_count,
            });
            if (bag.warn_count != 0) try w.print("; {d} warning(s) emitted", .{bag.warn_count});
            try w.writeByte('\n');
        } else {
            try w.print("{s}warning{s}: {d} warning(s) emitted\n", .{
                p.warn, p.reset, bag.warn_count,
            });
        }
    }
}

/// Indexes `sourceText` — the ORIGINAL file — because everything the renderer
/// derives from an index (line text, columns) is shown to the user, and what
/// the user recognises is what the user wrote. Offsets go through
/// `toSourceOffset` before they meet one of these.
pub fn lineIndexFor(bag: *diag_bag.Bag, scratch: Allocator, indices: []?diag_location.LineIndex, file: diag_location.FileId) !diag_location.LineIndex {
    const i = @min(@intFromEnum(file), indices.len - 1);
    if (indices[i]) |idx| return idx;
    const idx = try diag_location.LineIndex.build(scratch, bag.sourceText(file));
    indices[i] = idx;
    return idx;
}

/// Line number a human should see: the prelude is prepended to the root file's
/// text but is nobody's source, so its newlines come back off.
pub fn userLine(bag: *const diag_bag.Bag, file: diag_location.FileId, line: u32) u32 {
    if (file != .root) return line;
    return line -| bag.map.prelude_lines;
}

pub fn place(
    bag: *diag_bag.Bag,
    scratch: Allocator,
    indices: []?diag_location.LineIndex,
    span: diag_location.Span,
    file: ?diag_location.FileId,
    text: []const u8,
    primary: bool,
) !?Placed {
    if (span.isNone()) return null;
    const r = bag.locate(span, file);
    const idx = try lineIndexFor(bag, scratch, indices, r.file);
    const file_text = bag.sourceText(r.file);
    if (file_text.len == 0) return null;

    // `r.offset` is in span currency — the comment-STRIPPED text. Everything
    // from here down is measured in the ORIGINAL file: the line shown must be
    // the one the user wrote, and its columns only agree with the stripped
    // ones on lines no comment precedes a token on. Both ends map, so a span
    // that straddles a stripped comment widens to cover it rather than
    // underlining the wrong bytes.
    const src_off = bag.toSourceOffset(r.file, r.offset);
    const src_end = @max(src_off, bag.toSourceOffset(r.file, r.offset + span.len()));
    const loc = idx.loc(src_off);
    const line_text = idx.lineText(file_text, loc.line);
    const start_col = displayCol(line_text, loc.col - 1);

    // A span that runs past the end of its line is clamped: an underline may
    // not wrap, and the first line is the informative one.
    const line_end = src_off + @as(u32, @intCast(line_text.len)) - (loc.col - 1);
    const clamped = @min(src_end, line_end);
    const end_col = displayCol(line_text, clamped - src_off + (loc.col - 1));

    return .{
        .file = r.file,
        .line = loc.line,
        .col = start_col,
        .width = @max(@as(u32, 1), end_col -| start_col),
        .text = text,
        .primary = primary,
    };
}

pub fn renderOne(
    bag: *diag_bag.Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    opts: RenderOptions,
    e: diag_entry.Entry,
    indices: []?diag_location.LineIndex,
    explained: *std.AutoHashMapUnmanaged(Code, void),
) !void {
    const p = opts.palette;
    const sev = p.forSeverity(e.severity);
    const meta = info(e.code);

    // --- headline: `error[E0313]: unknown variable` -------------------------
    try w.print("{s}{s}[{s}]{s}{s}: {s}{s}", .{
        sev,    e.severity.word(), e.code.name(), p.reset,
        p.bold, meta.title,        p.reset,
    });
    if (e.message.len != 0) try w.print(": {s}", .{e.message});
    try w.writeByte('\n');

    const primary = try place(bag, scratch, indices, e.span, e.file, e.point, true);

    // --- location: `  --> file.va:12:5` -------------------------------------
    var width: u32 = 1;
    if (primary) |pr| {
        const shown = userLine(bag, pr.file, pr.line);
        width = digits(shown);
        try w.print("{s}{s}-->{s} {s}:{d}:{d}\n", .{
            spaces(width), p.gutter, p.reset, bag.fileName(pr.file), shown, pr.col + 1,
        });
    }

    if (opts.snippets and primary != null) {
        // One primary plus at most `max_children` labels — the same comptime cap
        // `Bag.labels` decodes into a caller array for, enforced by `Builder`'s
        // inline `[max_children]LabelRec`. A bound that is a constant is a stack
        // array, not an `ArrayList`: this used to be one arena allocation per
        // rendered diagnostic for at most five elements.
        var pbuf: [diag_entry.max_children + 1]Placed = undefined;
        pbuf[0] = primary.?;
        var n: usize = 1;
        var lbuf: [diag_entry.max_children]diag_entry.Label = undefined;
        for (bag.labels(e, &lbuf)) |l| {
            if (try place(bag, scratch, indices, l.span, e.file, l.text, false)) |q| {
                pbuf[n] = q;
                n += 1;
            }
        }
        const placed = pbuf[0..n];
        // Widen the gutter to the largest line number that will be printed.
        for (placed) |q| width = @max(width, digits(userLine(bag, q.file, q.line)));
        try renderSnippet(bag, scratch, w, opts, indices, placed, e.severity, width);
    }

    // --- the rule this diagnostic enforces ----------------------------------
    if (meta.lrm.len != 0) {
        try w.print("{s}{s} ={s} {s}note{s}: LRM {s}{s}\n", .{
            spaces(width),       p.gutter, p.reset, p.note, p.reset,
            annexWord(meta.lrm), meta.lrm,
        });
    }

    // --- notes, helps, suggestions ------------------------------------------
    var nbuf: [diag_entry.max_children]diag_entry.Note = undefined;
    for (bag.notes(e, &nbuf)) |n| {
        const word = switch (n.kind) {
            .note => "note",
            .help => "help",
        };
        const colour = switch (n.kind) {
            .note => p.note,
            .help => p.help,
        };
        try w.print("{s}{s} ={s} {s}{s}{s}: {s}\n", .{
            spaces(width), p.gutter, p.reset, colour, word, p.reset, n.text,
        });
        if (n.fix) |fix| try renderFix(bag, scratch, w, opts, indices, fix, e.file, width);
    }

    // --- `--explain` hint, once per code ------------------------------------
    if (opts.explain_hint) {
        const gop = try explained.getOrPut(scratch, e.code);
        if (!gop.found_existing) {
            try w.print("{s}{s} ={s} {s}help{s}: run `vera --explain {s}` for a detailed explanation\n", .{
                spaces(width), p.gutter, p.reset, p.help, p.reset, e.code.name(),
            });
        }
    }
    try w.writeByte('\n');
}

/// The ` 12 | source text` / `    | ^^^ label` block. Placed spans are grouped
/// by line; a gap between printed lines becomes `...`, like rustc.
pub fn renderSnippet(
    bag: *diag_bag.Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    opts: RenderOptions,
    indices: []?diag_location.LineIndex,
    placed: []Placed,
    sev: Severity,
    width: u32,
) !void {
    const p = opts.palette;
    std.mem.sort(Placed, placed, {}, struct {
        fn f(_: void, a: Placed, b: Placed) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.f);

    try w.print("{s}{s} |{s}\n", .{ spaces(width), p.gutter, p.reset });

    var i: usize = 0;
    var prev_line: u32 = 0;
    while (i < placed.len) {
        const line = placed[i].line;
        const file = placed[i].file;
        var j = i;
        while (j < placed.len and placed[j].line == line and placed[j].file == file) j += 1;

        if (prev_line != 0 and line > prev_line + 1) try w.print("{s}...{s}\n", .{ p.gutter, p.reset });
        prev_line = line;

        const idx = try lineIndexFor(bag, scratch, indices, file);
        const text = idx.lineText(bag.sourceText(file), line);
        const shown = userLine(bag, file, line);

        try w.print("{s}{d}{s} |{s} ", .{ p.gutter, shown, spaces(width -| digits(shown)), p.reset });
        try writeExpanded(w, text);
        try w.writeByte('\n');

        // One underline row per span on this line, deepest column last so the
        // labels stack instead of overlapping.
        // ponytail: each of at most five rows needs only its span, no row index.
        for (placed[i..j]) |q| {
            try w.print("{s}{s} |{s} ", .{ spaces(width), p.gutter, p.reset });
            try w.splatByteAll(' ', q.col);
            const colour = if (q.primary) p.forSeverity(sev) else p.gutter;
            const mark: u8 = if (q.primary) '^' else '-';
            try w.print("{s}", .{colour});
            try w.splatByteAll(mark, q.width);
            if (q.text.len != 0) try w.print(" {s}", .{q.text});
            try w.print("{s}\n", .{p.reset});
        }
        i = j;
    }
    try w.print("{s}{s} |{s}\n", .{ spaces(width), p.gutter, p.reset });
}

/// Show a machine-applicable rewrite as the patched line, with `+` under an
/// insertion and `~` under a replacement.
pub fn renderFix(
    bag: *diag_bag.Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    opts: RenderOptions,
    indices: []?diag_location.LineIndex,
    fix: diag_entry.Fix,
    file: ?diag_location.FileId,
    width: u32,
) !void {
    const p = opts.palette;
    const r = bag.locate(fix.span, file);
    const file_text = bag.sourceText(r.file);
    if (file_text.len == 0) return;
    const idx = try lineIndexFor(bag, scratch, indices, r.file);
    // Same strip-map step as `place`: the patched line drawn is the ORIGINAL,
    // so the cut points must be measured in it.
    const src_off = bag.toSourceOffset(r.file, r.offset);
    const src_end = @max(src_off, bag.toSourceOffset(r.file, r.offset + fix.span.len()));
    const loc = idx.loc(src_off);
    const line = idx.lineText(file_text, loc.line);
    const shown = userLine(bag, r.file, loc.line);

    const cut = @min(loc.col - 1, line.len);
    const cut_end = @min(cut + (src_end - src_off), line.len);

    try w.print("{s}{s} |{s}\n", .{ spaces(width), p.gutter, p.reset });
    try w.print("{s}{d}{s} |{s} ", .{ p.gutter, shown, spaces(width -| digits(shown)), p.reset });
    try writeExpanded(w, line[0..cut]);
    try w.print("{s}{s}{s}", .{ p.good, fix.replacement, p.reset });
    try writeExpanded(w, line[cut_end..]);
    try w.writeByte('\n');

    try w.print("{s}{s} |{s} ", .{ spaces(width), p.gutter, p.reset });
    try w.splatByteAll(' ', displayCol(line, @intCast(cut)));
    try w.print("{s}", .{p.good});
    // `+` when nothing was removed, `~` when text was replaced.
    try w.splatByteAll(
        if (fix.span.len() == 0) '+' else '~',
        @max(@as(usize, 1), fix.replacement.len),
    );
    try w.print("{s}\n", .{p.reset});
}

/// `"annex "` when a citation names one, `""` when it is a clause number.
///
/// The LRM numbers its clauses (`5.6.1`) and letters its annexes (`A.6.4`,
/// `C`), so a bare `LRM C` reads as a typo where `LRM annex C` reads as a
/// pointer. One test on the first byte; the citations are the fixed set in
/// `diag_code.zig` and every one of them starts with either a digit or an
/// annex letter.
pub fn annexWord(lrm: []const u8) []const u8 {
    return if (lrm.len != 0 and lrm[0] >= 'A' and lrm[0] <= 'H') "annex " else "";
}

pub fn digits(n: u32) u32 {
    var v = n;
    var d: u32 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

pub const spaces_pad = " " ** 24;

pub fn spaces(n: u32) []const u8 {
    return spaces_pad[0..@min(n, spaces_pad.len)];
}

/// `--explain EXXXX`. Wraps `Info.explain`'s pre-wrapped paragraphs verbatim —
/// they are authored at 76 columns in diag_code.zig.
pub fn explain(c: Code, w: *std.Io.Writer, palette: Palette) !void {
    const meta = info(c);
    try w.print("{s}{s}{s}: {s}{s}{s}\n", .{
        palette.bold, c.name(), palette.reset, palette.bold, meta.title, palette.reset,
    });
    if (meta.lrm.len != 0)
        try w.print("{s}LRM {s}{s}{s}\n", .{
            palette.note, annexWord(meta.lrm), meta.lrm, palette.reset,
        });
    try w.print("\n{s}\n", .{meta.explain});
}

/// One JSON object per line (JSON Lines), because that is what a build system
/// wants to stream. Shape is deliberately close to rustc's `--message-format
/// json` so existing editor plumbing can consume it.
pub fn renderJson(bag: *diag_bag.Bag, w: *std.Io.Writer) !void {
    bag.sort();
    var scratch_state = std.heap.ArenaAllocator.init(bag.arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const n_files = @max(bag.files.items.len, 1);
    const indices = try scratch.alloc(?diag_location.LineIndex, n_files);
    @memset(indices, null);

    for (bag.messages()) |mi| {
        const e = bag.get(mi);
        const meta = info(e.code);
        try w.writeAll("{\"code\":\"");
        try w.writeAll(e.code.name());
        try w.print("\",\"level\":\"{s}\",\"stage\":\"{s}\",\"lrm\":\"{s}\",\"title\":", .{
            e.severity.word(), @tagName(e.stage), meta.lrm,
        });
        try writeJsonString(w, meta.title);
        try w.writeAll(",\"message\":");
        try writeJsonString(w, e.message);

        try w.writeAll(",\"span\":");
        try writeJsonSpan(bag, scratch, w, indices, e.span, e.file);

        try w.writeAll(",\"labels\":[");
        var lbuf: [diag_entry.max_children]diag_entry.Label = undefined;
        for (bag.labels(e, &lbuf), 0..) |l, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"text\":");
            try writeJsonString(w, l.text);
            try w.writeAll(",\"span\":");
            try writeJsonSpan(bag, scratch, w, indices, l.span, e.file);
            try w.writeByte('}');
        }

        try w.writeAll("],\"notes\":[");
        var nbuf: [diag_entry.max_children]diag_entry.Note = undefined;
        for (bag.notes(e, &nbuf), 0..) |n, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("{{\"kind\":\"{s}\",\"text\":", .{@tagName(n.kind)});
            try writeJsonString(w, n.text);
            if (n.fix) |fx| {
                try w.writeAll(",\"fix\":{\"replacement\":");
                try writeJsonString(w, fx.replacement);
                try w.writeAll(",\"span\":");
                try writeJsonSpan(bag, scratch, w, indices, fx.span, e.file);
                try w.writeByte('}');
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}\n");
    }
}

pub fn writeJsonSpan(
    bag: *diag_bag.Bag,
    scratch: Allocator,
    w: *std.Io.Writer,
    indices: []?diag_location.LineIndex,
    span: diag_location.Span,
    file: ?diag_location.FileId,
) !void {
    if (span.isNone()) {
        try w.writeAll("null");
        return;
    }
    const r = bag.locate(span, file);
    const idx = try lineIndexFor(bag, scratch, indices, r.file);
    // line/col are reported in the ORIGINAL file (strip-mapped, like the
    // human renderer); byte_start/byte_end stay in span currency.
    const loc = idx.loc(bag.toSourceOffset(r.file, r.offset));
    try w.writeAll("{\"file\":");
    try writeJsonString(w, bag.fileName(r.file));
    try w.print(",\"line\":{d},\"col\":{d},\"byte_start\":{d},\"byte_end\":{d}}}", .{
        userLine(bag, r.file, loc.line), loc.col, span.start, span.end,
    });
}

pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
