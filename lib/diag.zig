//! Class 0 — the diagnostic system: collection, lint levels, provenance, and
//! rendering.
//!
//! Transformation: (stage events) → one `Bag` of `Entry` rows → bytes on a
//! writer, or JSON for a tool.
//!
//! WHY ONE BAG. Before this file every stage owned its own diagnostic struct,
//! its own cap, its own allocator and its own idea of what a source location
//! is (a line, a byte, a token index, a MIR instruction). Five collectors meant
//! five conversion sites in the driver, five chances to drop a location, and no
//! way to sort a parser error and a proof error into source order. There is now
//! ONE collector, one currency (`Span`, a byte range in the preprocessed text),
//! and one renderer.
//!
//! DOD
//!   - TWO POOLS, `string_bytes` and `extra`, exactly as the Zig compiler
//!     stores its own errors (std/zig/ErrorBundle.zig). A diagnostic is a run
//!     of `u32` words in `extra` — its labels and notes trailing it in the
//!     same run — plus NUL-terminated text in `string_bytes`. No per-entry
//!     allocation, no side tables, no pointers to fix up.
//!
//!     WHY THAT FORMAT AND NOT A NICER ONE OF OUR OWN: orchestrator.zig
//!     already receives a real `std.zig.ErrorBundle` from the resident `zig`
//!     child, describing errors in the GENERATED Zig (see `Result.failed`).
//!     Keeping a second, incompatible shape for errors in the Verilog-A meant
//!     two representations of one concept and two ways to serialise them. One
//!     format, one renderer, and a bag is now `{[]u8, []u32}` — memcpy-able
//!     down that same pipe with no bespoke encoding.
//!   - Diagnostics are COLD by construction (capped at 64 per run, written
//!     once, read once). So this file optimises for one thing only: never
//!     paying anything on the path where no diagnostic is produced. The line
//!     index, the dedupe set and the sort all happen lazily, after the first
//!     entry exists.
//!   - Everything the stages allocate lives in the compilation arena. The one
//!     gpa copy happens in `detach`, at the API boundary, because a failed
//!     compilation frees its arena on the way out — and with the pools that
//!     copy is three `appendSlice`s instead of a walk over every string.
//!
//! SEVERITY comes from the code's first letter (`E`/`W`) — see diag_code.zig.
//! There is no second table to desynchronise.

const std = @import("std");
pub const Allocator = std.mem.Allocator;
const code_table = @import("diag_code.zig");

pub const Code = code_table.Code;
pub const info = code_table.info;

// ---------------------------------------------------------------------------
// Severity and lint levels
// ---------------------------------------------------------------------------

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

/// Severity is a property of the CODE, read from its first letter. A code
/// cannot change severity without changing its name, which is the point.
pub fn severityOf(c: Code) Severity {
    return switch (c.name()[0]) {
        'W' => .warning,
        else => .err,
    };
}

/// What the user asked us to do with a code. Mirrors rustc's lint levels.
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

/// Per-code level overrides from the command line. A sorted-by-nothing array
/// with a linear scan: this is consulted once per diagnostic on a path that is
/// already cold, and the override count is the number of flags a human typed.
pub const Levels = struct {
    items: std.ArrayList(Entry_) = .empty,

    const Entry_ = struct { code: Code, level: Level };

    pub const empty: Levels = .{};

    pub fn deinit(self: *Levels, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .empty;
    }

    pub const SetError = error{ CannotAllowError, Forbidden } || Allocator.Error;

    /// Apply `--allow=X` / `--warn=X` / `--deny=X` / `--forbid=X`.
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

    /// Default level of a code with no override. Errors are `deny` and stay there:
    /// `--allow` on an `E` code is refused by `set`, because an error is a
    /// statement about the program, not about our taste.
    pub fn get(self: *const Levels, c: Code) Level {
        for (self.items.items) |it| {
            if (it.code == c) return it.level;
        }
        return switch (severityOf(c)) {
            .err => .deny,
            .warning => .warn,
        };
    }

    /// Parse `allow=W0650` / `deny=W0650`. Returns false if the text is not a
    /// level directive at all, so a caller can fall through to other flags.
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
