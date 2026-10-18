//! The file-level `@import` graph of VerA's Zig source: the repository's
//! `.zig` files -> one row per file with its line count and its sorted import
//! targets. An edge is a relative `@import("x.zig")` or a `build.zig` module
//! name (read from the `module_specs` rows' `.name`/`.path` text) mapped to its
//! root file. `@import`s inside `\\` string literals (generated device text)
//! and comments are not edges.
//!
//! Read by `fitness.zig`.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The repository's files, read once.
pub const Source = struct {
    arena: Allocator,
    io: Io,
    root: Io.Dir,
    texts: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// `path`'s bytes, read on the first ask and kept: arena-owned, valid
    /// while `arena` is.
    pub fn text(s: *Source, path: []const u8) ![]const u8 {
        if (s.texts.get(path)) |t| return t;
        const t = try s.root.readFileAlloc(s.io, path, s.arena, .unlimited);
        try s.texts.put(s.arena, path, t);
        return t;
    }

    /// Every `.zig` under each of `deep`, plus those directly in each of `flat`.
    pub fn zigFiles(s: *Source, deep: []const []const u8, flat: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (deep) |top| {
            var dir = try s.root.openDir(s.io, top, .{ .iterate = true });
            defer dir.close(s.io);
            var walker = try dir.walk(s.arena);
            defer walker.deinit();
            while (try walker.next(s.io)) |e| {
                if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
                const p = try std.mem.concat(s.arena, u8, &.{ top, "/", e.path });
                // `/` whatever the host's separator, so paths match `normPath`'s.
                std.mem.replaceScalar(u8, p, '\\', '/');
                try out.append(s.arena, p);
            }
        }
        for (flat) |top| {
            var dir = s.root.openDir(s.io, top, .{ .iterate = true }) catch continue;
            defer dir.close(s.io);
            var it = dir.iterate();
            while (try it.next(s.io)) |e| {
                if (e.kind == .file and std.mem.endsWith(u8, e.name, ".zig"))
                    try out.append(s.arena, try std.mem.concat(s.arena, u8, &.{ top, "/", e.name }));
            }
        }
        std.mem.sort([]const u8, out.items, {}, strLess);
        return out.items;
    }
};

/// Python's `len(text.splitlines())` for text whose only line break is `\n`.
pub fn lineCount(text: []const u8) u32 {
    const n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    return if (text.len != 0 and text[text.len - 1] != '\n') n + 1 else n;
}

/// One row per file, in path order; an edge is an index into `files`.
pub const Graph = struct {
    files: []const []const u8,
    lines: []u32,
    /// Sorted, deduplicated import targets per file.
    edges: [][]u32,
    /// `build.zig` module names in first-appearance order, each with its last path.
    mods: []const [2][]const u8,
};

/// The graph over every `.zig` under lib/, src/ and tools/ and directly in
/// tests/, allocated in `s.arena`.
pub fn buildGraph(s: *Source) !Graph {
    const a = s.arena;
    const files = try s.zigFiles(&.{ "lib", "src", "tools" }, &.{"tests"});
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    for (files, 0..) |f, i| try index.put(a, f, @intCast(i));

    var mods: std.ArrayList([2][]const u8) = .empty;
    var rest = try s.text("build.zig");
    const key = ".name = \"";
    while (std.mem.find(u8, rest, key)) |at| {
        rest = rest[at + key.len ..];
        const name_end = std.mem.findScalar(u8, rest, '"') orelse break;
        const name = rest[0..name_end];
        const mid = "\", .path = \"";
        if (name.len == 0 or !allWord(name) or !std.mem.startsWith(u8, rest[name_end..], mid)) continue;
        const p = rest[name_end + mid.len ..];
        const path_end = std.mem.findScalar(u8, p, '"') orelse break;
        if (path_end == 0) continue;
        for (mods.items) |*m| {
            if (std.mem.eql(u8, m[0], name)) {
                m[1] = p[0..path_end];
                break;
            }
        } else try mods.append(a, .{ name, p[0..path_end] });
    }

    const lines = try a.alloc(u32, files.len);
    const edges = try a.alloc([]u32, files.len);
    for (files, 0..) |f, i| {
        const text = try s.text(f);
        lines[i] = lineCount(text);
        var set: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            const trimmed = std.mem.trimStart(u8, l, " \t\r\x0b\x0c");
            if (std.mem.startsWith(u8, trimmed, "\\\\")) continue;
            var code = l[0 .. std.mem.find(u8, l, "//") orelse l.len];
            const tag = "@import(\"";
            while (std.mem.find(u8, code, tag)) |at| {
                code = code[at + tag.len ..];
                const q = std.mem.findScalar(u8, code, '"') orelse break;
                if (q == 0 or q + 1 >= code.len or code[q + 1] != ')') continue;
                const m = code[0..q];
                if (std.mem.endsWith(u8, m, ".zig")) {
                    const t = try normPath(a, std.fs.path.dirname(f) orelse ".", m);
                    if (index.get(t)) |j| try set.put(a, j, {});
                } else for (mods.items) |mod| {
                    if (std.mem.eql(u8, mod[0], m)) {
                        if (index.get(mod[1])) |j| try set.put(a, j, {});
                        break;
                    }
                }
            }
        }
        const e = try a.dupe(u32, set.keys());
        std.mem.sort(u32, e, {}, std.sort.asc(u32));
        edges[i] = e;
    }
    return .{ .files = files, .lines = lines, .edges = edges, .mods = mods.items };
}

fn allWord(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// `os.path.normpath(os.path.join(dir, rel))` for relative POSIX paths.
pub fn normPath(a: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ dir, rel }) |piece| {
        var it = std.mem.splitScalar(u8, piece, '/');
        while (it.next()) |p| {
            if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
            if (std.mem.eql(u8, p, "..") and parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else try parts.append(a, p);
        }
    }
    return std.mem.join(a, "/", parts.items);
}

test "normPath folds `..` and `.`" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("lib/b.zig", try normPath(arena_state.allocator(), "lib/ir", "../b.zig"));
    try std.testing.expectEqualStrings("lib/ir/c.zig", try normPath(arena_state.allocator(), "lib/ir", "./c.zig"));
}
