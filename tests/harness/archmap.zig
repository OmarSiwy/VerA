//! The `archmap` mode: the two maps of VerA's Zig source, read from the code
//! itself, written where agents read them.
//!
//!   zig build archmap                # docs/UNITS.md and the AGENTS.md block
//!   zig build archmap -- <file.md>   # the block in another file (a test copy)
//!
//! `docs/UNITS.md`: the smallest independently-ownable units. A unit is a
//! strongly connected component of the file-level `@import` graph (relative
//! paths, plus `build.zig` module names mapped to their root file): files that
//! import each other in a cycle cannot change shape apart, and an acyclic edge
//! between two units is a seam. A large unit is split by freezing its hubs, the
//! files every sibling imports. `@import`s inside `\\` string literals
//! (generated device text) and comments are not edges.
//!
//! The architecture map, between `begin` and `end` in AGENTS.md: every Zig file
//! of the compiler, the runtimes and the harness in pipeline order, with its
//! line count, the first two paragraphs of its `//!` header (the leading `//`
//! block for a kernel file, which is embedded into device text and cannot carry
//! `//!`), and its public types with the first sentence of each one's `///`
//! doc. The headers are the source of truth; when an entry reads wrong, fix the
//! file's header and regenerate, never the map.

const std = @import("std");
const options = @import("suite_options");
const harness = @import("../harness.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

pub const begin = "<!-- BEGIN zig build archmap: generated, do not edit by hand -->";
pub const end = "<!-- END zig build archmap -->";

/// Writes `docs/UNITS.md`, then the map between the markers of the file named
/// in `args` (default `AGENTS.md`). Exit 1 when that file has no markers.
pub fn run(init: std.process.Init, args: *Args) !u8 {
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    var root = try Io.Dir.cwd().openDir(io, options.repo_root, .{});
    defer root.close(io);
    var src: Source = .{ .arena = arena, .io = io, .root = root };

    try root.writeFile(io, .{ .sub_path = "docs/UNITS.md", .data = try units(&src) });
    try w.writeAll("docs/UNITS.md written\n");

    const target = args.next() orelse "AGENTS.md";
    const doc = try Io.Dir.cwd().readFileAlloc(io, if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(arena, &.{ options.repo_root, target }), arena, .unlimited);
    const map = try render(&src);
    const at = std.mem.indexOf(u8, doc, begin) orelse return noMarkers(w, target);
    const stop = std.mem.indexOfPos(u8, doc, at + begin.len, end) orelse return noMarkers(w, target);
    const text = try std.mem.concat(arena, u8, &.{ doc[0..at], map, doc[stop + end.len ..] });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(arena, &.{ options.repo_root, target }), .data = text });
    try w.print("{s}: architecture map written\n", .{target});
    return 0;
}

fn noMarkers(w: *Io.Writer, target: []const u8) !u8 {
    try w.print("{s} has no archmap markers: add\n  {s}\n  {s}\n", .{ target, begin, end });
    return 1;
}

/// The repository's files, read once.
const Source = struct {
    arena: Allocator,
    io: Io,
    root: Io.Dir,
    texts: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn text(s: *Source, path: []const u8) ![]const u8 {
        if (s.texts.get(path)) |t| return t;
        const t = try s.root.readFileAlloc(s.io, path, s.arena, .unlimited);
        try s.texts.put(s.arena, path, t);
        return t;
    }

    /// Every `.zig` under each of `deep`, plus those directly in each of `flat`.
    fn zigFiles(s: *Source, deep: []const []const u8, flat: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (deep) |top| {
            var dir = try s.root.openDir(s.io, top, .{ .iterate = true });
            defer dir.close(s.io);
            var walker = try dir.walk(s.arena);
            defer walker.deinit();
            while (try walker.next(s.io)) |e| {
                if (e.kind == .file and std.mem.endsWith(u8, e.path, ".zig"))
                    try out.append(s.arena, try std.mem.concat(s.arena, u8, &.{ top, "/", e.path }));
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
        std.mem.sort([]const u8, out.items, {}, harness.strLess);
        return out.items;
    }
};

/// Python's `len(text.splitlines())` for text whose only line break is `\n`.
fn lineCount(text: []const u8) u32 {
    const n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    return if (text.len != 0 and text[text.len - 1] != '\n') n + 1 else n;
}

// ---------------------------------------------------------------------------
// docs/UNITS.md
// ---------------------------------------------------------------------------

/// Lines one agent owns: smaller units are not split.
const budget = 4000;
const max_hubs = 8;

const Graph = struct {
    files: []const []const u8,
    lines: []u32,
    /// Sorted, deduplicated import targets per file.
    edges: [][]u32,
    /// `build.zig` module names in first-appearance order, each with its last path.
    mods: []const [2][]const u8,
};

fn buildGraph(s: *Source) !Graph {
    const a = s.arena;
    const files = try s.zigFiles(&.{ "lib", "src", "tools" }, &.{"tests"});
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    for (files, 0..) |f, i| try index.put(a, f, @intCast(i));

    var mods: std.ArrayList([2][]const u8) = .empty;
    var rest = try s.text("build.zig");
    const key = ".name = \"";
    while (std.mem.indexOf(u8, rest, key)) |at| {
        rest = rest[at + key.len ..];
        const name_end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const name = rest[0..name_end];
        const mid = "\", .path = \"";
        if (name.len == 0 or !allWord(name) or !std.mem.startsWith(u8, rest[name_end..], mid)) continue;
        const p = rest[name_end + mid.len ..];
        const path_end = std.mem.indexOfScalar(u8, p, '"') orelse break;
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
            var code = l[0 .. std.mem.indexOf(u8, l, "//") orelse l.len];
            const tag = "@import(\"";
            while (std.mem.indexOf(u8, code, tag)) |at| {
                code = code[at + tag.len ..];
                const q = std.mem.indexOfScalar(u8, code, '"') orelse break;
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
fn normPath(a: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
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

/// Tarjan's strongly connected components of the nodes in `in`, following
/// `edges` restricted to them. Each component is sorted (ids are path order).
fn scc(a: Allocator, g: *const Graph, in: []const bool) ![][]u32 {
    const n = g.files.len;
    const unset = std.math.maxInt(u32);
    const idx = try a.alloc(u32, n);
    const low = try a.alloc(u32, n);
    const on = try a.alloc(bool, n);
    @memset(idx, unset);
    @memset(on, false);
    var stack: std.ArrayList(u32) = .empty;
    var out: std.ArrayList([]u32) = .empty;
    const Frame = struct { v: u32, next: usize };
    var work: std.ArrayList(Frame) = .empty;
    var counter: u32 = 0;
    for (0..n) |r| {
        if (!in[r] or idx[r] != unset) continue;
        idx[r] = counter;
        low[r] = counter;
        counter += 1;
        try stack.append(a, @intCast(r));
        on[r] = true;
        try work.append(a, .{ .v = @intCast(r), .next = 0 });
        while (work.items.len != 0) {
            const top = &work.items[work.items.len - 1];
            const v = top.v;
            var pushed = false;
            while (top.next < g.edges[v].len) {
                const x = g.edges[v][top.next];
                top.next += 1;
                if (!in[x]) continue;
                if (idx[x] == unset) {
                    idx[x] = counter;
                    low[x] = counter;
                    counter += 1;
                    try stack.append(a, x);
                    on[x] = true;
                    try work.append(a, .{ .v = x, .next = 0 });
                    pushed = true;
                    break;
                }
                if (on[x]) low[v] = @min(low[v], idx[x]);
            }
            if (pushed) continue;
            _ = work.pop();
            if (work.items.len != 0) {
                const p = work.items[work.items.len - 1].v;
                low[p] = @min(low[p], low[v]);
            }
            if (low[v] == idx[v]) {
                var c: std.ArrayList(u32) = .empty;
                while (true) {
                    const x = stack.pop().?;
                    on[x] = false;
                    try c.append(a, x);
                    if (x == v) break;
                }
                std.mem.sort(u32, c.items, {}, std.sort.asc(u32));
                try out.append(a, c.items);
            }
        }
    }
    return out.items;
}

fn size(g: *const Graph, fs: []const u32) u32 {
    var t: u32 = 0;
    for (fs) |f| t += g.lines[f];
    return t;
}

fn units(s: *Source) ![]const u8 {
    const a = s.arena;
    const g = try buildGraph(s);
    const n = g.files.len;
    const all = try a.alloc(bool, n);
    @memset(all, true);
    const comps = try scc(a, &g, all);
    const uid = try a.alloc(u32, n);
    for (comps, 0..) |c, i| for (c) |f| {
        uid[f] = @intCast(i);
    };

    // deps[i]: the units unit i imports, itself excluded.
    const deps = try a.alloc([]u32, comps.len);
    for (comps, 0..) |c, i| {
        var set: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        for (c) |f| for (g.edges[f]) |t| if (uid[t] != i) try set.put(a, uid[t], {});
        deps[i] = try a.dupe(u32, set.keys());
    }
    // Tarjan emits sinks first, so every dependency's layer is already known.
    const layer = try a.alloc(u32, comps.len);
    for (0..comps.len) |i| {
        var l: u32 = 0;
        for (deps[i]) |d| l = @max(l, layer[d] + 1);
        layer[i] = l;
    }
    const order = try a.alloc(u32, comps.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const ByLayer = struct {
        layer: []const u32,
        comps: [][]u32,
        fn lt(c: @This(), x: u32, y: u32) bool {
            if (c.layer[x] != c.layer[y]) return c.layer[x] < c.layer[y];
            return c.comps[x][0] < c.comps[y][0];
        }
    };
    std.mem.sort(u32, order, ByLayer{ .layer = layer, .comps = comps }, ByLayer.lt);
    const name = try a.alloc([]const u8, comps.len);
    for (order, 0..) |i, k| name[i] = try std.fmt.allocPrint(a, "U{d:0>2}", .{k});
    const users = try a.alloc(std.ArrayList(u32), comps.len);
    @memset(users, .empty);
    for (0..comps.len) |i| for (deps[i]) |d| try users[d].append(a, @intCast(i));

    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var total: u32 = 0;
    for (g.lines) |l| total += l;
    var multi: usize = 0;
    for (comps) |c| multi += @intFromBool(c.len > 1);
    try w.writeAll("# Units\n\n");
    try w.writeAll("Generated by `zig build archmap`; do not edit. Regenerate after any change to\n");
    try w.writeAll("an `@import`. A unit is an import cycle: its files change shape together.\n");
    try w.writeAll("`Uses` are seams. Layer N depends only on layers below N.\n\n");
    try w.print("{d} files, {d} lines, {d} units, {d} of them multi-file.\n\n", .{ n, total, comps.len, multi });
    try w.writeAll("| Unit | Layer | Lines | Files | Uses | Used by |\n|---|---:|---:|---|---|---|\n");
    for (order) |i| {
        try w.print("| {s} | {d} | {d} | `{s}` | ", .{ name[i], layer[i], size(&g, comps[i]), try label(a, &g, comps, uid, @intCast(i)) });
        try names(w, a, name, deps[i]);
        try w.writeAll(" | ");
        try names(w, a, name, users[i].items);
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n## Multi-file units\n\n");
    try w.writeAll("Hubs are the files every sibling imports: freeze them (they are seams),\n");
    try w.writeAll("and each slice below can be owned alone while its `pub` signatures hold.\n");
    try w.writeAll("A `test.zig` slice belongs with the unit's root file (tests move with code).\n");
    for (order) |i| {
        const u = comps[i];
        if (u.len < 2) continue;
        try w.print("\n### {s} `{s}`, {d} lines\n\n", .{ name[i], try label(a, &g, comps, uid, i), size(&g, u) });
        if (size(&g, u) <= budget) {
            for (u) |f| try w.print("- `{s}` {d}\n", .{ g.files[f], g.lines[f] });
            continue;
        }
        const sp = try split(a, &g, u);
        for (sp.hubs) |h| try w.print("- hub `{s}` {d}\n", .{ g.files[h], g.lines[h] });
        for (sp.slices) |p| {
            try w.print("- slice {d}: ", .{size(&g, p)});
            for (p, 0..) |f, k| try w.print("{s}`{s}` {d}", .{ if (k == 0) "" else ", ", g.files[f], g.lines[f] });
            try w.writeAll("\n");
        }
    }

    try w.writeAll("\n## Module seams\n\n");
    try w.writeAll("`build.zig` module edges, with the files on each side that cross them.\n\n");
    // `{path: name}` over the modules in order: a later name wins a shared path.
    for (g.mods) |m| {
        var winner = m[0];
        for (g.mods) |o| if (std.mem.eql(u8, o[1], m[1])) {
            winner = o[0];
        };
        if (!std.mem.eql(u8, winner, m[0])) continue;
        var crossing: std.ArrayList([]const u8) = .empty;
        for (g.files, 0..) |f, i| for (g.edges[i]) |t| {
            if (std.mem.eql(u8, g.files[t], m[1]) and uid[t] != uid[i]) {
                try crossing.append(a, f);
                break;
            }
        };
        if (crossing.items.len == 0) continue;
        try w.print("- `{s}` ({s}) ← {d} files: ", .{ m[0], m[1], crossing.items.len });
        for (crossing.items, 0..) |f, k| try w.print("{s}`{s}`", .{ if (k == 0) "" else ", ", f });
        try w.writeAll("\n");
    }
    return out.written();
}

/// Unit names, space-separated in name order, or `—` for none.
fn names(w: *Io.Writer, a: Allocator, name: []const []const u8, ids: []const u32) !void {
    if (ids.len == 0) return w.writeAll("—");
    const sorted = try a.alloc([]const u8, ids.len);
    for (ids, sorted) |i, *s| s.* = name[i];
    std.mem.sort([]const u8, sorted, {}, harness.strLess);
    for (sorted, 0..) |s, k| try w.print("{s}{s}", .{ if (k == 0) "" else " ", s });
}

/// A unit is named by the file the rest of the program imports most.
fn label(a: Allocator, g: *const Graph, comps: []const []u32, uid: []const u32, i: u32) ![]const u8 {
    const u = comps[i];
    if (u.len == 1) return g.files[u[0]];
    const ext = try a.alloc(u32, g.files.len);
    @memset(ext, 0);
    for (g.files, 0..) |_, f| {
        if (uid[f] == i) continue;
        for (g.edges[f]) |t| if (uid[t] == i) {
            ext[t] += 1;
        };
    }
    var best = u[0];
    for (u[1..]) |f| {
        if (ext[f] > ext[best] or (ext[f] == ext[best] and g.lines[f] > g.lines[best])) best = f;
    }
    return std.fmt.allocPrint(a, "{s} (+{d})", .{ g.files[best], u.len - 1 });
}

/// Peel the most-imported files until the rest falls apart.
fn split(a: Allocator, g: *const Graph, u: []const u32) !struct { hubs: []u32, slices: [][]u32 } {
    const in = try a.alloc(bool, g.files.len);
    @memset(in, false);
    for (u) |f| in[f] = true;
    const indeg = try a.alloc(u32, g.files.len);
    @memset(indeg, 0);
    for (u) |f| for (g.edges[f]) |t| if (in[t]) {
        indeg[t] += 1;
    };
    var hubs: std.ArrayList(u32) = .empty;
    var slices: [][]u32 = &.{};
    while (hubs.items.len < max_hubs) {
        // The largest in-degree; a tie goes to the larger path.
        var h: ?u32 = null;
        for (u) |f| {
            if (!in[f]) continue;
            if (h == null or indeg[f] > indeg[h.?] or (indeg[f] == indeg[h.?] and f > h.?)) h = f;
        }
        try hubs.append(a, h.?);
        in[h.?] = false;
        slices = try scc(a, g, in);
        var biggest: u32 = 0;
        for (slices) |p| biggest = @max(biggest, size(g, p));
        if (biggest <= budget) break;
    }
    const BySize = struct {
        g: *const Graph,
        fn lt(c: @This(), x: []u32, y: []u32) bool {
            const sx = size(c.g, x);
            const sy = size(c.g, y);
            if (sx != sy) return sx > sy;
            return std.mem.lessThan(u32, x, y);
        }
    };
    std.mem.sort([]u32, slices, BySize{ .g = g }, BySize.lt);
    return .{ .hubs = hubs.items, .slices = slices };
}

// ---------------------------------------------------------------------------
// The AGENTS.md architecture map
// ---------------------------------------------------------------------------

/// Pipeline order: a file lands in the first group whose prefix it matches;
/// the order inside a group is the path order.
const groups = [_]struct { title: []const u8, prefixes: []const []const u8 }{
    .{ .title = "Host ABI (`contract` module)", .prefixes = &.{"tools/contract.zig"} },
    .{ .title = "Diagnostics (`diag` module)", .prefixes = &.{ "lib/diag", "lib/diag_code.zig" } },
    .{ .title = "Frontend: tokens, AST, folding (`frontend` module)", .prefixes = &.{
        "lib/frontend/token.zig",  "lib/frontend/lexer.zig",     "lib/frontend/integer.zig",
        "lib/frontend/ast",        "lib/frontend/constfold.zig", "lib/frontend/wreal.zig",
        "lib/frontend/libmap.zig", "lib/frontend/root.zig",
    } },
    .{ .title = "Frontend: preprocessor", .prefixes = &.{ "lib/frontend/preprocessor.zig", "lib/frontend/pp/", "lib/frontend/spice_cards.zig" } },
    .{ .title = "Frontend: parser", .prefixes = &.{"lib/frontend/parser"} },
    .{ .title = "IR: elaboration (`ir` module)", .prefixes = &.{"lib/ir/elaborate"} },
    .{ .title = "IR: lowering", .prefixes = &.{"lib/ir/lower"} },
    .{ .title = "IR: MIR, SSA, analysis, proof", .prefixes = &.{"lib/ir/"} },
    .{ .title = "Runtime kernels (`kernels` module, embedded in devices)", .prefixes = &.{"lib/backend/kernels"} },
    .{ .title = "Backend: codegen (`backend` module)", .prefixes = &.{ "lib/backend/codegen", "lib/backend/cg_" } },
    .{ .title = "Backend: naming, orchestrator, testbench", .prefixes = &.{"lib/backend/"} },
    .{ .title = "Compiler facade (`vera` module)", .prefixes = &.{ "lib/root.zig", "lib/big_arena.zig" } },
    .{ .title = "CLI", .prefixes = &.{ "src/main.zig", "src/cli/" } },
    .{ .title = "Digital simulator and mixed-signal runner (`sim` module)", .prefixes = &.{"src/sim/"} },
    .{ .title = "VPI (`vpi` module)", .prefixes = &.{"src/vpi/"} },
    .{ .title = "Test harness and hosts", .prefixes = &.{ "tests/", "tools/zrunner.zig" } },
};

/// The map, markers included.
fn render(s: *Source) ![]const u8 {
    const a = s.arena;
    const files = try s.zigFiles(&.{ "lib", "src", "tools" }, &.{ "tests", "tests/harness" });
    const placed = try a.alloc(bool, files.len);
    @memset(placed, false);
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s}\n\n", .{begin});
    for (groups) |grp| {
        var any = false;
        for (files, 0..) |f, i| {
            if (placed[i]) continue;
            if (!anyPrefix(f, grp.prefixes)) continue;
            placed[i] = true;
            if (!any) try w.print("#### {s}\n\n", .{grp.title});
            any = true;
            try describe(w, a, f, try s.text(f));
        }
        if (any) try w.writeAll("\n");
    }
    var missing = false;
    for (files, 0..) |f, i| {
        if (placed[i]) continue;
        if (!missing) try w.writeAll("#### Not placed in a group (add a prefix to `groups` in tests/harness/archmap.zig)\n\n");
        missing = true;
        try w.print("- `{s}`\n", .{f});
    }
    if (missing) try w.writeAll("\n");
    try w.writeAll(end);
    return out.written();
}

fn anyPrefix(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, path, p)) return true;
    return false;
}

/// One file's entry: its header and its public types.
fn describe(w: *Io.Writer, a: Allocator, path: []const u8, text: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, l);
    if (text.len == 0 or text[text.len - 1] == '\n') _ = lines.pop();

    // The `//!` header's first two paragraphs. A file embedded into device
    // text (the kernels) cannot carry `//!`, so its leading `//` block stands in.
    const mark: []const u8 = if (lines.items.len != 0 and std.mem.startsWith(u8, lines.items[0], "//!")) "//!" else "//";
    var paras: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList([]const u8) = .empty;
    for (lines.items) |l| {
        if (!std.mem.startsWith(u8, l, mark) or (mark.len == 2 and std.mem.startsWith(u8, l, "///"))) break;
        const t = std.mem.trim(u8, l[mark.len..], " \t\r\x0b\x0c");
        if (t.len != 0) {
            try cur.append(a, t);
        } else if (cur.items.len != 0) {
            try paras.append(a, try std.mem.join(a, " ", cur.items));
            cur = .empty;
        }
        if (paras.items.len == 2) break;
    }
    if (cur.items.len != 0 and paras.items.len < 2) try paras.append(a, try std.mem.join(a, " ", cur.items));
    const header = try std.mem.join(a, " ", paras.items);
    try w.print("- **`{s}`** ({d} lines). {s}\n", .{ path, lineCount(text), if (header.len == 0) "_(no `//!` header)_" else header });

    for (lines.items, 0..) |l, i| {
        const t = typeDecl(l) orelse continue;
        var doc: std.ArrayList([]const u8) = .empty;
        var j = i;
        while (j > 0) {
            j -= 1;
            const d = std.mem.trimStart(u8, lines.items[j], " \t\r\x0b\x0c");
            if (!std.mem.startsWith(u8, d, "///")) break;
            try doc.insert(a, 0, std.mem.trim(u8, d[3..], " \t\r\x0b\x0c"));
        }
        try w.print("  - `{s}`", .{t.name});
        if (!std.mem.eql(u8, t.kind, "struct")) try w.print(" ({s})", .{t.kind});
        if (doc.items.len != 0) try w.print(": {s}", .{try firstSentence(a, try std.mem.join(a, " ", doc.items))});
        try w.writeAll("\n");
    }
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// `pub const Name = struct|enum|union...` or `pub fn Name(...) type`.
fn typeDecl(l: []const u8) ?struct { name: []const u8, kind: []const u8 } {
    if (std.mem.startsWith(u8, l, "pub const ")) {
        const rest = l["pub const ".len..];
        var n: usize = 0;
        while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
        if (n == 0 or std.ascii.isDigit(rest[0]) or !std.mem.startsWith(u8, rest[n..], " = ")) return null;
        const after = rest[n + 3 ..];
        for ([_][]const u8{ "packed struct", "extern struct", "struct", "enum", "union", "extern union" }) |k| {
            if (std.mem.startsWith(u8, after, k) and (after.len == k.len or !isWord(after[k.len])))
                return .{ .name = rest[0..n], .kind = k };
        }
        return null;
    }
    if (std.mem.startsWith(u8, l, "pub fn ")) {
        const rest = l["pub fn ".len..];
        if (rest.len == 0 or !std.ascii.isUpper(rest[0])) return null;
        var n: usize = 1;
        while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
        if (n >= rest.len or rest[n] != '(') return null;
        var from = n + 1;
        while (std.mem.indexOfPos(u8, rest, from, ") type")) |at| {
            const e = at + ") type".len;
            if (e == rest.len or !isWord(rest[e])) return .{ .name = rest[0..n], .kind = "type fn" };
            from = at + 1;
        }
    }
    return null;
}

/// The first sentence of `text` (whitespace collapsed), at most 200 code points.
fn firstSentence(a: Allocator, text: []const u8) ![]const u8 {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    var parts: std.ArrayList([]const u8) = .empty;
    while (words.next()) |x| try parts.append(a, x);
    const t = try std.mem.join(a, " ", parts.items);
    var s = t;
    for (t, 0..) |c, i| {
        if (i >= 1 and c == '.' and (i + 1 == t.len or t[i + 1] == ' ')) {
            s = t[0 .. i + 1];
            break;
        }
    }
    const limit = 200;
    var cps: usize = 0;
    var cut: usize = s.len;
    for (s, 0..) |c, i| {
        if (c & 0xC0 == 0x80) continue;
        if (cps == limit - 1) cut = i;
        cps += 1;
    }
    if (cps <= limit) return s;
    return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, s[0..cut], " "), "…" });
}

test "first sentence: the shortest prefix ending at a full stop" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("One fact.", try firstSentence(a, "One  fact.\n More."));
    try std.testing.expectEqualStrings("Calls `a.b()` here.", try firstSentence(a, "Calls `a.b()` here. Then."));
    try std.testing.expectEqualStrings("no stop", try firstSentence(a, "no stop"));
}

test "a type declaration and its kind" {
    try std.testing.expectEqualStrings("packed struct", typeDecl("pub const Flags = packed struct(u8) {").?.kind);
    try std.testing.expectEqualStrings("type fn", typeDecl("pub fn Of(comptime T: type) type {").?.kind);
    try std.testing.expect(typeDecl("pub const x = structFoo;") == null);
    try std.testing.expect(typeDecl("pub fn of(comptime T: type) type {") == null);
}

test "normPath folds `..` and `.`" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("lib/b.zig", try normPath(arena_state.allocator(), "lib/ir", "../b.zig"));
    try std.testing.expectEqualStrings("lib/ir/c.zig", try normPath(arena_state.allocator(), "lib/ir", "./c.zig"));
}
