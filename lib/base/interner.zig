//! The string intern table: identifier and string text in, dense `StrId`s
//! out, assigned in insertion order so the same input gives the same ids.
//! LRM §2.7 strings, §2.8 identifiers. The AST and the MIR each hold one
//! (`SourceFile.strings`, `Mir.strings`); a `StrId` means something only
//! against the table that issued it. A table may continue another (`base`,
//! elaboration's overlay of the parse): its ids start
//! after the base's, so an id keeps its number. Imports only std.

const std = @import("std");

/// Handle into the string intern table. LRM §2.8 identifiers, §2.7 strings.
pub const StrId = enum(u32) { none = std.math.maxInt(u32), _ };
comptime {
    // `map`'s 5-byte slot (below) is this id plus the metadata byte.
    std.debug.assert(@sizeOf(StrId) == 4);
}

/// Identifier and string intern table. Ids are assigned in insertion order, so
/// they are deterministic for a given token stream.
///
/// The MIR embeds the same type (`Mir.strings`, `Mir.StrId`). A StrId is only
/// meaningful against the table it came from; lowering carries a name across
/// with `mir.internString(gpa, file.str(id))`.
///
/// Stored slices are borrowed (source substrings or parser arena copies) and
/// never freed here; they must outlive the table.
pub const StringInterner = struct {
    /// The table this one continues, which it never writes: the base's ids
    /// are this table's first `base.len()`, and a text the base holds keeps
    /// its id. Null for a table of its own. Set only by `continuing`.
    base: ?*const StringInterner = null,
    /// The text of each id this table added, indexed by `StrId` minus the
    /// base's `len()`.
    strings: std.ArrayList([]const u8) = .empty,
    /// The set of ids, hashed by their text. The key is the 4-byte id, not
    /// the 16-byte slice `strings` already holds: 5 bytes a slot instead of
    /// 21 (3,640 names in 8,192 slots on psp103, in both the AST's table and
    /// the MIR's).
    map: std.HashMapUnmanaged(StrId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    /// Hashes an id by its text, for the map's own rehashing. `off` is the
    /// base's `len()`: the map holds only this table's own ids.
    const IdContext = struct {
        strings: []const []const u8,
        off: u32 = 0,
        pub fn hash(c: IdContext, id: StrId) u64 {
            return std.hash_map.hashString(c.strings[@backingInt(id) - c.off]);
        }
        pub fn eql(_: IdContext, a: StrId, b: StrId) bool {
            return a == b;
        }
    };

    /// Looks a text up among the ids without interning it.
    const TextAdapter = struct {
        strings: []const []const u8,
        off: u32 = 0,
        pub fn hash(_: TextAdapter, s: []const u8) u64 {
            return std.hash_map.hashString(s);
        }
        pub fn eql(a: TextAdapter, s: []const u8, id: StrId) bool {
            return std.mem.eql(u8, s, a.strings[@backingInt(id) - a.off]);
        }
    };

    pub const empty: StringInterner = .{};

    /// Returns an empty table that continues `base`: `base`'s ids read
    /// through it, and its own start at `base.len()`. `base` must outlive
    /// it and must not grow while it lives. Asserts `base` continues none.
    pub fn continuing(base: *const StringInterner) StringInterner {
        std.debug.assert(base.base == null);
        return .{ .base = base };
    }

    /// Returns how many ids the table holds, the base's included.
    pub fn len(self: *const StringInterner) u32 {
        return self.off() + @as(u32, @intCast(self.strings.items.len));
    }

    /// The base's id count: where this table's own ids start.
    fn off(self: *const StringInterner) u32 {
        const b = self.base orelse return 0;
        return @intCast(b.strings.items.len);
    }

    /// Frees both tables, never the base's; the interned slices are borrowed
    /// and left alone.
    pub fn deinit(self: *StringInterner, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.map.deinit(gpa);
        self.* = .empty;
    }

    /// Returns the id for `s`, adding it if new. `s` is borrowed and must
    /// outlive the table. On OOM the table is unchanged.
    /// Invalidates slices of `strings.items` when it adds.
    /// Asserts the table holds fewer than `maxInt(u32)` strings (that value
    /// is `StrId.none`).
    pub fn intern(self: *StringInterner, gpa: std.mem.Allocator, s: []const u8) !StrId {
        if (self.base) |b| if (b.find(s)) |id| return id;
        // Room for the text first, so a failed append can never leave the
        // map holding an id with no string.
        try self.strings.ensureUnusedCapacity(gpa, 1);
        const items = self.strings.items;
        const o = self.off();
        const gop = try self.map.getOrPutContextAdapted(gpa, s, TextAdapter{ .strings = items, .off = o }, .{ .strings = items, .off = o });
        if (gop.found_existing) return gop.key_ptr.*;
        std.debug.assert(o + items.len < std.math.maxInt(u32));
        const id: StrId = @fromBackingInt(@intCast(o + items.len));
        gop.key_ptr.* = id;
        self.strings.appendAssumeCapacity(s);
        return id;
    }

    /// Returns the string for `id`; asserts `id != .none`.
    pub fn get(self: *const StringInterner, id: StrId) []const u8 {
        std.debug.assert(id != .none);
        const o = self.off();
        if (@backingInt(id) < o) return self.base.?.get(id);
        return self.strings.items[@backingInt(id) - o];
    }

    /// Returns the id for `s` without inserting it.
    pub fn find(self: *const StringInterner, s: []const u8) ?StrId {
        if (self.base) |b| if (b.find(s)) |id| return id;
        return self.map.getKeyAdapted(s, TextAdapter{ .strings = self.strings.items, .off = self.off() });
    }

    /// Returns a copy whose tables are `gpa`'s; the interned slices stay
    /// borrowed. Caller owns the copy and frees it with `deinit(gpa)`.
    /// Asserts the table continues none.
    pub fn clone(self: *const StringInterner, gpa: std.mem.Allocator) !StringInterner {
        std.debug.assert(self.base == null);
        var strings = try self.strings.clone(gpa);
        errdefer strings.deinit(gpa);
        return .{ .strings = strings, .map = try self.map.cloneContext(gpa, IdContext{ .strings = self.strings.items }) };
    }

    /// Returns whether `id` names `s`; false for `.none`.
    pub fn eql(self: *const StringInterner, id: StrId, s: []const u8) bool {
        return id != .none and std.mem.eql(u8, self.get(id), s);
    }
};

const testing = std.testing;

test "StringInterner: dense ids in insertion order; find never inserts" {
    const gpa = testing.allocator;
    var t: StringInterner = .empty;
    defer t.deinit(gpa);
    const a = try t.intern(gpa, "a");
    const b = try t.intern(gpa, "b");
    try testing.expectEqual(@as(u32, 0), @backingInt(a));
    try testing.expectEqual(@as(u32, 1), @backingInt(b));
    try testing.expectEqual(a, try t.intern(gpa, "a"));
    try testing.expectEqual(@as(?StrId, null), t.find("c"));
    try testing.expectEqual(@as(usize, 2), t.strings.items.len);
    try testing.expectEqual(b, t.find("b").?);
    // The key is the text, not the slice: equal bytes elsewhere are the same id.
    const elsewhere: []const u8 = "ab"[1..];
    try testing.expectEqual(b, try t.intern(gpa, elsewhere));
    try testing.expect(t.eql(a, "a"));
    try testing.expect(!t.eql(a, "b"));
    try testing.expect(!t.eql(.none, ""));
    // The empty string is a name like any other.
    const e = try t.intern(gpa, "");
    try testing.expectEqual(@as(u32, 2), @backingInt(e));
    try testing.expectEqualStrings("", t.get(e));
}

test "StringInterner: ids survive the map's rehashes, and a clone grows alone" {
    const gpa = testing.allocator;
    var names: [300][8]u8 = undefined;
    var t: StringInterner = .empty;
    defer t.deinit(gpa);
    for (&names, 0..) |*n, i| {
        _ = std.mem.print(n, "n{d:0>7}", .{i}) catch unreachable;
        try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(try t.intern(gpa, n)));
    }
    for (&names, 0..) |*n, i| try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(t.find(n).?));

    var c = try t.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual(@as(u32, 300), @backingInt(try c.intern(gpa, "only-in-clone")));
    try testing.expectEqual(@as(?StrId, null), t.find("only-in-clone"));
    try testing.expectEqual(@as(usize, 300), t.strings.items.len);
    for (&names, 0..) |*n, i| try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(c.find(n).?));
}

test "StringInterner.continuing: the base's ids keep their numbers, new ones follow" {
    const gpa = testing.allocator;
    var base: StringInterner = .empty;
    defer base.deinit(gpa);
    const a = try base.intern(gpa, "a");
    const b = try base.intern(gpa, "b");
    var over: StringInterner = .continuing(&base);
    defer over.deinit(gpa);
    // A text the base holds is the base's id, and nothing is added.
    try testing.expectEqual(b, try over.intern(gpa, "b"));
    try testing.expectEqual(@as(u32, 2), over.len());
    const c = try over.intern(gpa, "c");
    try testing.expectEqual(c, try over.intern(gpa, "c"));
    try testing.expectEqualStrings("a", over.get(a));
    try testing.expectEqualStrings("c", over.get(c));
    try testing.expectEqual(a, over.find("a").?);
    try testing.expectEqual(c, over.find("c").?);
    try testing.expect(over.eql(c, "c"));
    // The base never grows.
    try testing.expectEqual(@as(?StrId, null), base.find("c"));
    try testing.expectEqual(@as(u32, 2), base.len());
    // The ids one table gives the same texts in the same order (the oracle).
    var one: StringInterner = .empty;
    defer one.deinit(gpa);
    for ([_][]const u8{ "a", "b", "b", "c" }) |t| _ = try one.intern(gpa, t);
    try testing.expectEqual(one.find("c").?, c);
}

fn internSome(gpa: std.mem.Allocator) !void {
    var names: [40][4]u8 = undefined;
    var t: StringInterner = .empty;
    defer t.deinit(gpa);
    for (&names, 0..) |*n, i| {
        _ = std.mem.print(n, "s{d:0>3}", .{i}) catch unreachable;
        const before = t.strings.items.len;
        const id = t.intern(gpa, n) catch |err| {
            // No id without its string, and no string without its id.
            try testing.expectEqual(before, t.strings.items.len);
            try testing.expectEqual(@as(u32, @intCast(before)), t.map.count());
            try testing.expectEqual(@as(?StrId, null), t.find(n));
            return err;
        };
        try testing.expectEqual(@as(u32, @intCast(i)), @backingInt(id));
    }
}

test "StringInterner.intern leaves the table unchanged on OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, internSome, .{});
}

fn cloneAndOverlay(gpa: std.mem.Allocator) !void {
    var t: StringInterner = .empty;
    defer t.deinit(gpa);
    for ([_][]const u8{ "a", "b", "c" }) |s| _ = try t.intern(gpa, s);
    var c = try t.clone(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual(t.find("c"), c.find("c"));
    // An overlay's failed add leaves its own rows and the base unchanged.
    var over: StringInterner = .continuing(&t);
    defer over.deinit(gpa);
    for ([_][]const u8{ "b", "d", "e", "d" }) |s| {
        const before = over.len();
        _ = over.intern(gpa, s) catch |err| {
            try testing.expectEqual(before, over.len());
            try testing.expectEqual(@as(u32, before - t.len()), over.map.count());
            try testing.expectEqual(@as(?StrId, null), over.find(s));
            return err;
        };
    }
    try testing.expectEqual(@as(u32, 5), over.len());
    try testing.expectEqual(@as(u32, 3), t.len());
}

test "StringInterner.clone and an overlay's intern leak nothing and stay consistent on OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, cloneAndOverlay, .{});
}
