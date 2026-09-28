//! The string intern table: identifier and string text in, dense `StrId`s
//! out, assigned in insertion order so the same input gives the same ids.
//! LRM §2.7 strings, §2.8 identifiers. The AST and the MIR each hold one
//! (`SourceFile.strings`, `Mir.strings`); a `StrId` means something only
//! against the table that issued it. Imports only std.

const std = @import("std");

/// Handle into the string intern table. LRM §2.8 identifiers, §2.7 strings.
pub const StrId = enum(u32) { none = std.math.maxInt(u32), _ };

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
    /// The text of each id, indexed by `StrId`.
    strings: std.ArrayList([]const u8) = .empty,
    /// The set of ids, hashed by their text. The key is the 4-byte id, not
    /// the 16-byte slice `strings` already holds: 5 bytes a slot instead of
    /// 21 (3,640 names in 8,192 slots on psp103, in both the AST's table and
    /// the MIR's).
    map: std.HashMapUnmanaged(StrId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    /// Hashes an id by its text, for the map's own rehashing.
    const IdContext = struct {
        strings: []const []const u8,
        pub fn hash(c: IdContext, id: StrId) u64 {
            return std.hash_map.hashString(c.strings[@backingInt(id)]);
        }
        pub fn eql(_: IdContext, a: StrId, b: StrId) bool {
            return a == b;
        }
    };

    /// Looks a text up among the ids without interning it.
    const TextAdapter = struct {
        strings: []const []const u8,
        pub fn hash(_: TextAdapter, s: []const u8) u64 {
            return std.hash_map.hashString(s);
        }
        pub fn eql(a: TextAdapter, s: []const u8, id: StrId) bool {
            return std.mem.eql(u8, s, a.strings[@backingInt(id)]);
        }
    };

    pub const empty: StringInterner = .{};

    /// Frees both tables; the interned slices are borrowed and left alone.
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
        // Room for the text first, so a failed append can never leave the
        // map holding an id with no string.
        try self.strings.ensureUnusedCapacity(gpa, 1);
        const items = self.strings.items;
        const gop = try self.map.getOrPutContextAdapted(gpa, s, TextAdapter{ .strings = items }, .{ .strings = items });
        if (gop.found_existing) return gop.key_ptr.*;
        std.debug.assert(items.len < std.math.maxInt(u32));
        const id: StrId = @fromBackingInt(@intCast(items.len));
        gop.key_ptr.* = id;
        self.strings.appendAssumeCapacity(s);
        return id;
    }

    /// Returns the string for `id`; asserts `id != .none`.
    pub fn get(self: *const StringInterner, id: StrId) []const u8 {
        std.debug.assert(id != .none);
        return self.strings.items[@backingInt(id)];
    }

    /// Returns the id for `s` without inserting it.
    pub fn find(self: *const StringInterner, s: []const u8) ?StrId {
        return self.map.getKeyAdapted(s, TextAdapter{ .strings = self.strings.items });
    }

    /// Returns a copy whose tables are `gpa`'s; the interned slices stay
    /// borrowed. Caller owns the copy and frees it with `deinit(gpa)`.
    pub fn clone(self: *const StringInterner, gpa: std.mem.Allocator) !StringInterner {
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
