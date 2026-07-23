//! Levels: a code -> how hard it fails. In: `--allow=`/`--warn=`/`--deny=`/
//! `--forbid=` flags. Out: the `Level` `Builder.emit` consults for every
//! diagnostic, and the `Severity` a kept one renders with.

const std = @import("std");
const diag = @import("../diag.zig");
const Allocator = std.mem.Allocator;
const Code = diag.Code;

/// How a kept diagnostic affects the compilation: an `err` fails it. Comes
/// from the code's first letter (`severityOf`) unless `--deny` promotes it.
pub const Severity = enum(u8) {
    err,
    warning,

    /// The rendered word, also the JSON `level` value.
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

/// Per-code level overrides from the command line. Configuration: the caller
/// owns it, copies it into `Bag.levels`, and frees it with `deinit`;
/// `Bag.deinit` never does.
pub const Levels = struct {
    // ponytail: unsorted with a linear scan; consulted once per diagnostic,
    // and the override count is the number of flags a human typed.
    items: std.ArrayList(Entry_) = .empty,

    const Entry_ = struct { code: Code, level: Level };

    pub const empty: Levels = .{};

    /// Frees the override list, allocated in `gpa` by `set`.
    pub fn deinit(self: *Levels, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .empty;
    }

    /// `CannotAllowError`: an `E` code asked for below `deny`.
    /// `Forbidden`: the code is already `forbid`.
    pub const SetError = error{ CannotAllowError, Forbidden } || Allocator.Error;

    /// Records the level for `c` from `--allow=`/`--warn=`/`--deny=`/`--forbid=`.
    /// A later call for the same code overrides an earlier one, except over
    /// `forbid`. Allocates in `gpa` only for a code not yet overridden.
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
