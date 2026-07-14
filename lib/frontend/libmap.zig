//! IEEE 1364-2005 §13.2 library map files -> a `Map`: every library's file
//! path specifications in declaration order, and the library a source file is
//! compiled into.
//!
//! IEEE 1364-2005 clauses cited: §13.2.1, §13.2.1.1, §13.2.2, §13.2.3, §13.5.1.

const std = @import("std");
const diag = @import("diag");
const Io = std.Io;

/// §13.2.1.1's resolution order, most specific first: a specification that
/// ends with an explicit filename, a wildcarded filename, or a directory.
pub const Class = enum(u2) { file, wildcard, directory };

/// One `file_path_spec`, resolved against its map file's directory.
pub const Spec = struct {
    /// Absolute, `.` and `..` resolved; `?`, `*` and `...` still wildcards.
    /// A directory specification ends in `/*` (§13.2.1: "Identical to /*").
    pattern: []const u8,
    class: Class,
};

pub const Library = struct { name: []const u8, specs: []const Spec };

/// Where §13.2.1.1 puts a source file.
pub const Placement = union(enum) {
    lib: []const u8,
    /// Two libraries whose best matching specifications tie: an error.
    ambiguous: [2][]const u8,
};

pub const Map = struct {
    /// In declaration order, map files in the order given; a name declared
    /// twice is one library holding both declarations' specifications.
    libraries: []const Library = &.{},
    /// A.1.1's `-incdir` lists, every library's, in declaration order, each
    /// resolved against its map file's directory.
    incdirs: []const []const u8 = &.{},

    /// §13.2.1.1 the library `file` (absolute) maps into: the one whose
    /// specification matches it most specifically, else `work` (§13.2.1).
    pub fn libraryOf(map: Map, file: []const u8) Placement {
        var best: ?Class = null;
        var lib: []const u8 = "work";
        var tie: ?[]const u8 = null;
        for (map.libraries) |l| {
            var got: ?Class = null;
            for (l.specs) |s| if (matches(s.pattern, file)) {
                if (got == null or @backingInt(s.class) < @backingInt(got.?)) got = s.class;
            };
            const c = got orelse continue;
            if (best == null or @backingInt(c) < @backingInt(best.?)) {
                best = c;
                lib = l.name;
                tie = null;
            } else if (c == best.? and tie == null) tie = l.name;
        }
        if (tie) |t| return .{ .ambiguous = .{ lib, t } };
        return .{ .lib = lib };
    }

    /// §13.5.1 the search order with no configuration: "the library
    /// declaration order in the library map file", then `work` when no map
    /// declares it.
    pub fn order(map: Map, arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (map.libraries) |l| try out.append(arena, l.name);
        if (map.declares("work") == null) try out.append(arena, "work");
        return out.items;
    }

    pub fn declares(map: Map, name: []const u8) ?usize {
        for (map.libraries, 0..) |l, i| if (std.mem.eql(u8, l.name, name)) return i;
        return null;
    }
};

pub const Error = error{ MapFailed, OutOfMemory };

/// Reads the map files at `paths`, in order (§13.2.1: "If multiple map files
/// are specified, then they shall be read in the order in which they are
/// specified"). A refusal is E0244 in `bag`, whose files it registers, and
/// `error.MapFailed`.
pub fn load(arena: std.mem.Allocator, io: Io, bag: *diag.Bag, paths: []const []const u8) Error!Map {
    var l: Loader = .{ .arena = arena, .io = io, .bag = bag };
    for (paths) |p| try l.read(p, null, 0);
    const out = try arena.alloc(Library, l.libs.items.len);
    for (l.libs.items, out) |b, *o| o.* = .{ .name = b.name, .specs = b.specs.items };
    return .{ .libraries = out, .incdirs = l.incdirs.items };
}

const Loader = struct {
    arena: std.mem.Allocator,
    io: Io,
    bag: *diag.Bag,
    libs: std.ArrayList(struct { name: []const u8, specs: std.ArrayList(Spec) = .empty }) = .empty,
    incdirs: std.ArrayList([]const u8) = .empty,

    /// `at` is the `include` that names `path`, for the diagnostic when the
    /// file cannot be read.
    fn read(l: *Loader, path: []const u8, at: ?Site, depth: u8) Error!void {
        const text = Io.Dir.cwd().readFileAlloc(l.io, path, l.arena, .limited(1 << 24)) catch |e|
            return l.fail(at, "cannot read library map `{s}`: {t}", .{ path, e });
        const real = Io.Dir.cwd().realPathFileAlloc(l.io, path, l.arena) catch |e|
            return l.fail(at, "cannot resolve library map `{s}`: {t}", .{ path, e });
        const dir = std.fs.path.dirname(real) orelse "/";
        const file = try l.bag.addFile(path, text);
        var t: Tokens = .{ .text = text };
        while (t.next()) |kw| {
            const here: Site = .{ .file = file, .tok = kw };
            if (std.mem.eql(u8, kw.text, "include")) {
                // §13.2.2: "as though the contents of the included map file
                // appear in place of the include command", and a relative
                // path is "relative to the location of the file that contains
                // the file path".
                const spec = t.next() orelse return l.fail(here, "`include` names no file_path_spec", .{});
                if (isPunct(spec.text)) return l.fail(.{ .file = file, .tok = spec }, "`include` names no file_path_spec", .{});
                try l.expectSemicolon(&t, file, spec);
                if (depth == 32) return l.fail(here, "library map `include` nested deeper than 32", .{});
                try l.read(try std.fs.path.resolveAllocPosix(l.arena, &.{ dir, unquote(spec.text) }), .{ .file = file, .tok = spec }, depth + 1);
            } else if (std.mem.eql(u8, kw.text, "library")) {
                const name = t.next() orelse return l.fail(here, "`library` names no library", .{});
                if (!isIdentifier(name.text)) return l.fail(.{ .file = file, .tok = name }, "`{s}` is not a library_identifier", .{name.text});
                const lib = for (l.libs.items) |*b| {
                    if (std.mem.eql(u8, b.name, name.text)) break b;
                } else blk: {
                    try l.libs.append(l.arena, .{ .name = name.text });
                    break :blk &l.libs.items[l.libs.items.len - 1];
                };
                var prev = name;
                while (true) {
                    const spec = t.next() orelse return l.fail(.{ .file = file, .tok = prev }, "a library declaration ends with `;`", .{});
                    if (isPunct(spec.text)) return l.fail(.{ .file = file, .tok = spec }, "`library {s}` needs a file_path_spec here (Syntax 13-2), found `{s}`", .{ name.text, spec.text });
                    try lib.specs.append(l.arena, try resolveSpec(l.arena, dir, unquote(spec.text)));
                    const sep = t.next() orelse return l.fail(.{ .file = file, .tok = spec }, "a library declaration ends with `;`", .{});
                    if (std.mem.eql(u8, sep.text, ";")) break;
                    // A.1.1 `[ -incdir file_path_spec { , file_path_spec } ] ;`
                    if (std.mem.eql(u8, sep.text, "-incdir")) {
                        var prev_tok = sep;
                        while (true) {
                            const d = t.next() orelse return l.fail(.{ .file = file, .tok = prev_tok }, "a library declaration ends with `;`", .{});
                            if (isPunct(d.text)) return l.fail(.{ .file = file, .tok = d }, "`-incdir` needs a file_path_spec here (Syntax 13-2), found `{s}`", .{d.text});
                            try l.incdirs.append(l.arena, try std.fs.path.resolveAllocPosix(l.arena, &.{ dir, unquote(d.text) }));
                            const next = t.next() orelse return l.fail(.{ .file = file, .tok = d }, "a library declaration ends with `;`", .{});
                            if (std.mem.eql(u8, next.text, ";")) break;
                            if (!std.mem.eql(u8, next.text, ",")) return l.fail(.{ .file = file, .tok = next }, "found `{s}`: -incdir file_path_specs are separated by `,` and end with `;`", .{next.text});
                            prev_tok = next;
                        }
                        break;
                    }
                    if (!std.mem.eql(u8, sep.text, ",")) return l.fail(.{ .file = file, .tok = sep }, "found `{s}`: file_path_specs are separated by `,` and end with `;`", .{sep.text});
                    prev = sep;
                }
            } else return l.fail(here, "found `{s}`: a library map holds `library` and `include` statements only (IEEE 1364-2005 §13.2.2)", .{kw.text});
        }
    }

    fn expectSemicolon(l: *Loader, t: *Tokens, file: diag.FileId, after: Token) Error!void {
        const semi = t.next() orelse return l.fail(.{ .file = file, .tok = after }, "an `include` statement ends with `;`", .{});
        if (!std.mem.eql(u8, semi.text, ";")) return l.fail(.{ .file = file, .tok = semi }, "found `{s}`: an `include` statement ends with `;`", .{semi.text});
    }

    fn fail(l: *Loader, at: ?Site, comptime fmt: []const u8, args: anytype) Error {
        const span: diag.Span = if (at) |s| .{ .start = s.tok.start, .end = s.tok.start + @as(u32, @intCast(s.tok.text.len)) } else .none;
        var b = l.bag.build(.parse, .E0244, span);
        if (at) |s| b.inFile(s.file);
        b.msg(fmt, args);
        try b.emit();
        return error.MapFailed;
    }
};

const Site = struct { file: diag.FileId, tok: Token };
const Token = struct { text: []const u8, start: u32 };

/// Words of map text: a quoted string, `,`, `;`, or a run of anything else
/// up to whitespace, `,` or `;`. A comment starts only where a word could, so
/// the `/*` inside `lib/*.v` is part of the path.
const Tokens = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(t: *Tokens) ?Token {
        const s = t.text;
        while (t.pos < s.len) {
            if (std.ascii.isWhitespace(s[t.pos])) {
                t.pos += 1;
            } else if (std.mem.startsWith(u8, s[t.pos..], "//")) {
                t.pos = std.mem.indexOfScalarPos(u8, s, t.pos, '\n') orelse s.len;
            } else if (std.mem.startsWith(u8, s[t.pos..], "/*")) {
                t.pos = if (std.mem.indexOfPos(u8, s, t.pos + 2, "*/")) |e| e + 2 else s.len;
            } else break;
        }
        if (t.pos == s.len) return null;
        const start = t.pos;
        if (s[t.pos] == '"') {
            t.pos = if (std.mem.indexOfScalarPos(u8, s, t.pos + 1, '"')) |e| e + 1 else s.len;
        } else if (isPunct(s[t.pos .. t.pos + 1])) {
            t.pos += 1;
        } else while (t.pos < s.len and !std.ascii.isWhitespace(s[t.pos]) and s[t.pos] != ',' and s[t.pos] != ';') t.pos += 1;
        return .{ .text = s[start..t.pos], .start = @intCast(start) };
    }
};

fn isPunct(w: []const u8) bool {
    return std.mem.eql(u8, w, ",") or std.mem.eql(u8, w, ";");
}

fn isIdentifier(w: []const u8) bool {
    if (w.len == 0 or !(std.ascii.isAlphabetic(w[0]) or w[0] == '_')) return false;
    for (w) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return false;
    return true;
}

fn unquote(w: []const u8) []const u8 {
    return if (w.len >= 2 and w[0] == '"' and w[w.len - 1] == '"') w[1 .. w.len - 1] else w;
}

/// §13.2.1 "Paths that do not begin with / are relative to the directory in
/// which the current lib.map file is located"; "Paths that end in / shall
/// include all files in the specified directory. Identical to /*."
pub fn resolveSpec(arena: std.mem.Allocator, dir: []const u8, raw: []const u8) error{OutOfMemory}!Spec {
    const base = std.fs.path.basenamePosix(raw);
    const class: Class = if (std.mem.endsWith(u8, raw, "/"))
        .directory
    else if (std.mem.indexOfAny(u8, base, "*?") != null or std.mem.eql(u8, base, "..."))
        .wildcard
    else
        .file;
    const path = try std.fs.path.resolveAllocPosix(arena, &.{ dir, raw });
    return .{ .pattern = if (class == .directory) try std.mem.concat(arena, u8, &.{ path, "/*" }) else path, .class = class };
}

/// Does `file` match `pattern`, both absolute? §13.2.1's wildcards: `?` one
/// character, `*` any run within one name, `...` any number of directories.
pub fn matches(pattern: []const u8, file: []const u8) bool {
    return segments(std.mem.trimStart(u8, pattern, "/"), std.mem.trimStart(u8, file, "/"));
}

fn segments(p: []const u8, f: []const u8) bool {
    if (p.len == 0) return f.len == 0;
    const p_end = std.mem.indexOfScalar(u8, p, '/') orelse p.len;
    const p_rest = if (p_end == p.len) "" else p[p_end + 1 ..];
    if (std.mem.eql(u8, p[0..p_end], "...")) {
        var rest = f;
        while (true) {
            if (segments(p_rest, rest)) return true;
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
            rest = rest[slash + 1 ..];
        }
    }
    if (f.len == 0) return false;
    const f_end = std.mem.indexOfScalar(u8, f, '/') orelse f.len;
    return glob(p[0..p_end], f[0..f_end]) and segments(p_rest, if (f_end == f.len) "" else f[f_end + 1 ..]);
}

fn glob(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) if (glob(p[1..], s[i..])) return true;
        return false;
    }
    if (s.len == 0) return false;
    return (p[0] == '?' or p[0] == s[0]) and glob(p[1..], s[1..]);
}

const testing = std.testing;

test "§13.7.2 file path specification examples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = [_][]const u8{ "/proj/lib1/rtl/a.v", "/proj/lib2/gates/a.v", "/proj/lib1/rtl/b.v", "/proj/lib2/gates/b.v" };
    const cases = [_]struct { dir: []const u8, spec: []const u8, want: [4]bool }{
        .{ .dir = "/proj", .spec = "/proj/lib*/*/a.v", .want = .{ true, true, false, false } },
        .{ .dir = "/proj", .spec = ".../a.v", .want = .{ true, true, false, false } },
        .{ .dir = "/proj", .spec = "/proj/.../b.v", .want = .{ false, false, true, true } },
        .{ .dir = "/proj", .spec = ".../rtl/*.v", .want = .{ true, false, true, false } },
        .{ .dir = "/proj/lib1", .spec = "../lib2/gates/*.v", .want = .{ false, true, false, true } },
        .{ .dir = "/proj/lib1", .spec = "./rtl/?.v", .want = .{ true, false, true, false } },
        .{ .dir = "/proj/lib1", .spec = "./rtl/", .want = .{ true, false, true, false } },
    };
    for (cases) |c| {
        const s = try resolveSpec(a, c.dir, c.spec);
        for (files, c.want) |f, w| try testing.expectEqual(w, matches(s.pattern, f));
    }
    // §13.2.1: "The paths ./*.v and *.v are identical".
    try testing.expectEqualStrings((try resolveSpec(a, "/d", "./*.v")).pattern, (try resolveSpec(a, "/d", "*.v")).pattern);
}

test "§13.7.3 resolving multiple path specifications" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = "/proj/tb";
    const map: Map = .{ .libraries = &.{
        .{ .name = "lib1", .specs = &.{try resolveSpec(a, dir, "/proj/lib1/foo*.v")} },
        .{ .name = "lib2", .specs = &.{try resolveSpec(a, dir, "/proj/lib1/foo.v")} },
        .{ .name = "lib3", .specs = &.{try resolveSpec(a, dir, "../lib1/")} },
        .{ .name = "lib4", .specs = &.{try resolveSpec(a, dir, "/proj/lib1/*ver.v")} },
    } };
    try testing.expectEqualStrings("lib1", map.libraryOf("/proj/lib1/foobar.v").lib);
    try testing.expectEqualStrings("lib2", map.libraryOf("/proj/lib1/foo.v").lib);
    try testing.expectEqualStrings("lib3", map.libraryOf("/proj/lib1/bar.v").lib);
    try testing.expectEqualStrings("lib4", map.libraryOf("/proj/lib1/barver.v").lib);
    const tie = map.libraryOf("/proj/lib1/foover.v").ambiguous;
    try testing.expectEqualStrings("lib1", tie[0]);
    try testing.expectEqualStrings("lib4", tie[1]);
    // §13.2.1: "Any file ... that does not match any library's
    // file_path_spec shall by default be compiled into a library named work."
    try testing.expectEqualStrings("work", map.libraryOf("/proj/tb/top.v").lib);
    // A directory specification is not recursive.
    try testing.expectEqualStrings("work", map.libraryOf("/proj/lib1/sub/bar.v").lib);
}
