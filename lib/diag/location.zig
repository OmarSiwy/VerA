//! Locations: byte offset to line and column, spans and labels.
//!
//! In: a source buffer and byte offsets. Out: line/column positions and the spans a
//! diagnostic points at.
//!
//! LRM clauses this file's code cites: §2.4.
//!
//! Cut verbatim from `diag.zig`. Functions take `self: *diag` and are called
//! directly, `diag_location.f(self, ...)`; `diag.zig` aliases only what other modules call.

const std = @import("std");
const diag = @import("../diag.zig");
const Allocator = diag.Allocator;

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

/// A byte range in the PREPROCESSED text — the one currency every stage
/// reports in. `SourceMap` turns it back into a file, line and column.
///
/// `end == start` is a legal zero-width span: the renderer draws a single caret
/// there, and a `Fix` uses it to mean "insert here, delete nothing".
pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub const none: Span = .{ .start = 0, .end = 0 };

    pub fn at(start: u32) Span {
        return .{ .start = start, .end = start };
    }

    pub fn len(self: Span) u32 {
        return self.end -| self.start;
    }

    pub fn isNone(self: Span) bool {
        return self.start == 0 and self.end == 0;
    }
};

/// 1-based, because humans and every editor count that way.
pub const Loc = struct { line: u32 = 0, col: u32 = 0 };

pub const FileId = enum(u16) {
    /// The top-level compilation unit.
    root = 0,
    _,
};

/// How a run of the preprocessed text came to exist. The preprocessor appends
/// one of these every time the ORIGIN of the output changes — entering an
/// `include, starting a macro expansion, or returning from either.
///
/// DOD: sorted by `out_start` by construction (the preprocessor only ever
/// appends), so lookup is a binary search with no sort step.
pub const Segment = struct {
    /// First byte of the preprocessed text this segment explains.
    out_start: u32,
    /// Corresponding byte in `file`'s ORIGINAL text. Meaningless for `.macro`,
    /// where the bytes came from a macro body rather than from a file run.
    in_start: u32,
    file: FileId,
    kind: enum(u8) { verbatim, macro },
    /// Index of the enclosing segment, or `no_parent`. Walking this chain
    /// produces rustc's "in this expansion of `FOO`" note stack.
    parent: u32 = no_parent,
    /// Macro name, for `.macro` segments. Borrowed from the arena.
    macro: []const u8 = "",

    pub const no_parent: u32 = std.math.maxInt(u32);
};

pub const File = struct {
    name: []const u8,
    /// The text SPANS INDEX: comment-STRIPPED once the preprocessor has run
    /// (`Bag.setStrippedText`), the registered text until then. Newline count
    /// matches the original — the preprocessor's line contract — so LINES read
    /// off this text are true of both.
    text: []const u8,
    /// ORIGINAL text, before comment stripping; empty when `text` IS the
    /// original. Snippets are cut from here, so what the user sees is what the
    /// user wrote — a span's COLUMN goes through `to_src` first, because the
    /// two texts drift apart wherever a comment preceded a token on its line.
    raw: []const u8 = "",
    /// Stripped offset → original offset, one mark per comment collapsed. See
    /// `StripMark`.
    to_src: []const StripMark = &.{},
};

/// One point where comment stripping (preprocessor §2.4) made the stripped
/// text SHORTER than the original: from `out` up to the next mark the two
/// advance in lockstep, so original offset = `src + (stripped offset − out)`.
/// Before the first mark the mapping is identity. Sorted by `out` by
/// construction — the stripper appends left to right — so lookup is the same
/// binary search `SourceMap.resolve` runs.
pub const StripMark = struct { out: u32, src: u32 };

/// An EMPTY map is legal and means "the preprocessed text is the source": every
/// offset resolves to `root` unchanged. That is exactly right for the unit
/// tests and for `compilePreprocessed`, and it means no stage needs a null
/// check.
pub const SourceMap = struct {
    segs: []const Segment = &.{},
    /// Newlines contributed by the annex-D prelude, which is prepended to the
    /// text but is not part of anyone's source. Subtracted from every reported
    /// line of `root`.
    prelude_lines: u32 = 0,

    pub const empty: SourceMap = .{};

    pub const Resolved = struct {
        file: FileId,
        offset: u32,
        /// Index into `segs`, or `Segment.no_parent` when the map is empty.
        seg: u32,
    };

    pub fn resolve(self: *const SourceMap, off: u32) Resolved {
        if (self.segs.len == 0)
            return .{ .file = .root, .offset = off, .seg = Segment.no_parent };

        // Last segment with out_start <= off.
        var lo: usize = 0;
        var hi: usize = self.segs.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.segs[mid].out_start <= off) lo = mid else hi = mid;
        }
        const s = self.segs[lo];
        // Inside a macro expansion the output offset has no counterpart in any
        // file; the honest answer is the macro's INVOCATION site, which is what
        // the nearest enclosing verbatim segment records.
        if (s.kind == .macro) {
            var p = s.parent;
            while (p != Segment.no_parent) {
                const q = self.segs[p];
                if (q.kind == .verbatim)
                    return .{ .file = q.file, .offset = q.in_start, .seg = @intCast(lo) };
                p = q.parent;
            }
            return .{ .file = s.file, .offset = s.in_start, .seg = @intCast(lo) };
        }
        return .{
            .file = s.file,
            .offset = s.in_start + (off - s.out_start),
            .seg = @intCast(lo),
        };
    }
};

/// Byte offset → line, by binary search over precomputed line starts.
///
/// Built ONCE per rendered file, only when there is something to render. The
/// old code re-scanned the whole source from byte 0 for every diagnostic, from
/// three different call sites.
pub const LineIndex = struct {
    starts: []const u32,

    pub fn build(arena: Allocator, text: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        // ponytail: reuse stdlib byte search; batch offsets if indexing profiles hot.
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |i| {
            pos = i + 1;
            try starts.append(arena, @intCast(pos));
        }
        return .{ .starts = try starts.toOwnedSlice(arena) };
    }

    /// 1-based line and column of `off`.
    pub fn loc(self: LineIndex, off: u32) Loc {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= off) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .col = off - self.starts[lo] + 1 };
    }

    /// The text of `line` (1-based), without its newline.
    pub fn lineText(self: LineIndex, text: []const u8, line: u32) []const u8 {
        if (line == 0 or line > self.starts.len) return "";
        const start = self.starts[line - 1];
        const end = if (line < self.starts.len) self.starts[line] else @as(u32, @intCast(text.len));
        var slice = text[@min(start, text.len)..@min(end, text.len)];
        if (slice.len > 0 and slice[slice.len - 1] == '\n') slice = slice[0 .. slice.len - 1];
        if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
        return slice;
    }
};
