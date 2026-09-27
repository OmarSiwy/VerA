//! The diagnostic system: stage events -> one `Bag` of `Entry` rows -> text
//! on a writer, or JSON for a tool.
//!
//! Every stage reports into one collector with one location currency (`Span`,
//! a byte range in the preprocessed text), so diagnostics from different stages
//! sort into source order. A code's severity is its first letter (`E`/`W`).

const std = @import("std");
pub const Allocator = std.mem.Allocator;
const code_table = @import("diag_code.zig");

pub const Code = code_table.Code;
pub const info = code_table.info;

// ---------------------------------------------------------------------------
// Severity and lint levels
// ---------------------------------------------------------------------------

/// How a diagnostic affects the compilation; derived from its code by `severityOf`.
pub const Severity = enum(u8) {
    err,
    warning,

    pub fn word(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
        };
    }
};

/// Returns the severity carried by the code's first letter (`W` = warning,
/// otherwise error), so a code cannot change severity without changing name.
pub fn severityOf(c: Code) Severity {
    return switch (c.name()[0]) {
        'W' => .warning,
        else => .err,
    };
}

/// What the user asked to do with a code, after rustc's lint levels.
pub const Level = enum(u8) {
    /// Do not collect it at all.
    allow,
    /// Collect and report, but do not fail the compilation.
    warn,
    /// Report and fail the compilation.
    deny,
    /// Like `deny`, and a later `--allow`/`--warn` for the same code is
    /// refused rather than silently honoured.
    forbid,
};

/// Per-code level overrides from the command line.
pub const Levels = struct {
    // ponytail: unsorted with a linear scan; consulted once per diagnostic,
    // and the override count is the number of flags a human typed.
    items: std.ArrayList(Entry_) = .empty,

    const Entry_ = struct { code: Code, level: Level };

    pub const empty: Levels = .{};

    pub fn deinit(self: *Levels, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .empty;
    }

    /// `CannotAllowError`: an `E` code asked for below `deny`.
    /// `Forbidden`: the code is already `forbid`.
    pub const SetError = error{ CannotAllowError, Forbidden } || Allocator.Error;

    /// Records the level for `c` from `--allow=`/`--warn=`/`--deny=`/`--forbid=`.
    pub fn set(self: *Levels, gpa: Allocator, c: Code, level: Level) SetError!void {
        if (severityOf(c) == .err and level != .forbid and level != .deny)
            return error.CannotAllowError;
        for (self.items.items) |*it| {
            if (it.code != c) continue;
            if (it.level == .forbid and level != .forbid) return error.Forbidden;
            it.level = level;
            return;
        }
        try self.items.append(gpa, .{ .code = c, .level = level });
    }

    /// Returns the level of `c`: its override, else `deny` for an error and
    /// `warn` for a warning. An error never drops below `deny` (`set` refuses).
    pub fn get(self: *const Levels, c: Code) Level {
        for (self.items.items) |it| {
            if (it.code == c) return it.level;
        }
        return switch (severityOf(c)) {
            .err => .deny,
            .warning => .warn,
        };
    }

    /// Parses and applies `allow=W0650`-style text. Returns false when the text
    /// is not a level directive, so a caller can fall through to other flags.
    pub fn parseFlag(self: *Levels, gpa: Allocator, text: []const u8) SetError!bool {
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse return false;
        const level = std.meta.stringToEnum(Level, text[0..eq]) orelse return false;
        const c = std.meta.stringToEnum(Code, text[eq + 1 ..]) orelse return false;
        try self.set(gpa, c, level);
        return true;
    }
};

// Locations: byte offset to line and column, spans and labels — diag/location.zig
const diag_location = @import("diag/location.zig");
pub const Span = diag_location.Span;
pub const FileId = diag_location.FileId;
pub const Segment = diag_location.Segment;
pub const StripMark = diag_location.StripMark;
pub const LineIndex = diag_location.LineIndex;

// Entries: the wire format and its decoded views — diag/entry.zig
const diag_entry = @import("diag/entry.zig");
pub const Stage = diag_entry.Stage;
pub const Note = diag_entry.Note;
pub const Label = diag_entry.Label;
pub const max_children = diag_entry.max_children;
pub const Entry = diag_entry.Entry;

// The bag: every diagnostic of one compilation, collected, deduplicated and sorted — diag/bag.zig
const diag_bag = @import("diag/bag.zig");
pub const Bag = diag_bag.Bag;
pub const Builder = diag_bag.Builder;
pub const didYouMean = diag_bag.didYouMean;
pub const didYouMeanMap = diag_bag.didYouMeanMap;

// Rendering: the bag as terminal text or JSON — diag/render.zig
const diag_render = @import("diag/render.zig");
pub const renderJson = diag_render.renderJson;
pub const explain = diag_render.explain;
pub const render = diag_render.render;

// Diagnostic self-checks — diag/test.zig
const diag_test = @import("diag/test.zig");

test {
    _ = diag_location;
    _ = diag_entry;
    _ = diag_bag;
    _ = diag_render;
    _ = diag_test;
}
