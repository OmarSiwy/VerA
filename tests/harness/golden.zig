//! The `golden` mode: what the compiler SAYS about every fixture, snapshotted,
//! so a refactor can prove it changed nothing (AGENTS.md §4, "Refactor phases
//! keep goldens byte-identical").
//!
//!   zig build golden -- before        # on the pre-change tree
//!   zig build golden -- after         # ... the change ...
//!   zig build golden -- diff          # before vs after; exit 1 on a difference
//!   zig build golden -- diff A B      # two tags, or two snapshot directories
//!
//! A snapshot is `.zig-cache/vera-golden/<tag>/`, one `<path>.txt` per `.va`
//! and `.v` under `tests/fixtures` (`vera --emit-zig` stdout, then a last line
//! `exit=<code>`) and one `<path>.stderr`. stderr is captured apart because the
//! message text is held too, not only the device, and because vera writes the
//! device at file offset 0, so a shared file would lose the warnings.
//!
//! `diff` ignores the repository root: a diagnostic names its fixture by
//! absolute path, so two checkouts differ in exactly that and nothing else.
//!
//! Not a cacheable build step: the build graph cannot see fixture contents, so
//! a cached run would compare nothing (`build.zig`'s note on `test-devices`).

const std = @import("std");
const options = @import("suite_options");
const harness = @import("../harness.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// Dispatches `before`/`after`/any tag to `snapshot`, `diff` to `compare`.
pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const store = try std.fs.path.join(arena, &.{ options.repo_root, ".zig-cache", "vera-golden" });
    const word = args.next() orelse {
        try w.writeAll("usage: zig build golden -- <tag> | diff [<a> <b>]\n");
        return 2;
    };
    if (std.mem.eql(u8, word, "diff")) {
        const a = args.next() orelse "before";
        const b = args.next() orelse "after";
        return compare(arena, io, try snapDir(arena, store, a), try snapDir(arena, store, b), w);
    }
    return snapshot(gpa, io, arena, vera_exe, try std.fs.path.join(arena, &.{ store, word }), w);
}

/// A tag names `.zig-cache/vera-golden/<tag>`; anything with a `/` is a path,
/// so a snapshot from another checkout can be compared.
fn snapDir(arena: Allocator, store: []const u8, arg: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '/') != null) return arg;
    return std.fs.path.join(arena, &.{ store, arg });
}

/// The work list and its cursor: one fixture per take, any number of hands.
const Pool = struct {
    io: Io,
    gpa: Allocator,
    vera: []const u8,
    out: []const u8,
    rels: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),

    fn work(pool: *Pool) void {
        while (true) {
            const k = pool.next.fetchAdd(1, .monotonic);
            if (k >= pool.rels.len) return;
            pool.one(pool.rels[k]) catch {
                _ = pool.failed.fetchAdd(1, .monotonic);
            };
        }
    }

    /// `vera --emit-zig` on one fixture: stdout to `<rel>.txt`, stderr to
    /// `<rel>.stderr`, then `exit=<code>` appended to the `.txt`. The include
    /// path is the shared `tests/fixtures` and the fixture's own directory.
    fn one(pool: *Pool, rel: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(pool.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const io = pool.io;
        const src = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
        const txt = try std.mem.concat(arena, u8, &.{ pool.out, "/", rel, ".txt" });
        const err = try std.mem.concat(arena, u8, &.{ pool.out, "/", rel, ".stderr" });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(txt).?);

        const code: u32 = code: {
            const out_file = try Io.Dir.cwd().createFile(io, txt, .{});
            defer out_file.close(io);
            const err_file = try Io.Dir.cwd().createFile(io, err, .{});
            defer err_file.close(io);
            var child = try std.process.spawn(io, .{
                .argv = &.{
                    pool.vera,                  "--emit-zig",         "--color=never",
                    "-I",                       options.fixture_root, "-I",
                    std.fs.path.dirname(src).?, src,
                },
                .cwd = .{ .path = options.repo_root },
                .stdin = .ignore,
                .stdout = .{ .file = out_file },
                .stderr = .{ .file = err_file },
            });
            // bash's `$?`: the exit code, or 128 + the signal.
            break :code switch (try child.wait(io)) {
                .exited => |c| c,
                .signal, .stopped => |s| 128 + @as(u32, @backingInt(s)),
                .unknown => |u| u,
            };
        };
        const out_file = try Io.Dir.cwd().openFile(io, txt, .{ .mode = .read_write });
        defer out_file.close(io);
        var line: [32]u8 = undefined;
        try out_file.writePositionalAll(io, try std.fmt.bufPrint(&line, "exit={d}\n", .{code}), try out_file.length(io));
    }
};

/// Every `.va` and `.v` under `tests/fixtures`, relative to it.
fn fixtureList(arena: Allocator, io: Io) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, options.fixture_root, .{ .iterate = true });
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.path, ".va") and !std.mem.endsWith(u8, e.path, ".v")) continue;
        try list.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, list.items, {}, harness.strLess);
    return list.items;
}

/// Replaces the snapshot at `out` with a fresh one, one `vera` per CPU.
fn snapshot(gpa: Allocator, io: Io, arena: Allocator, vera_exe: []const u8, out: []const u8, w: *Io.Writer) !u8 {
    Io.Dir.cwd().deleteTree(io, out) catch {};
    try Io.Dir.cwd().createDirPath(io, out);
    // Absolute, because each child runs from the repository root.
    const vera = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, arena);
    var pool: Pool = .{ .io = io, .gpa = gpa, .vera = vera, .out = out, .rels = try fixtureList(arena, io) };
    const jobs = std.Thread.getCpuCount() catch 1;
    var group: Io.Group = .init;
    var hands: usize = 0;
    while (hands < jobs) : (hands += 1) group.concurrent(io, Pool.work, .{&pool}) catch break;
    if (hands == 0) pool.work();
    try group.await(io);
    const failed = pool.failed.load(.monotonic);
    if (failed != 0) {
        try w.print("golden: {d} fixtures could not be snapshotted\n", .{failed});
        return 1;
    }
    try w.print("{d} fixtures snapshotted -> {s}\n", .{ pool.rels.len, out });
    return 0;
}

/// Every file under `root`, relative to it, sorted.
fn fileList(arena: Allocator, io: Io, root: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file) try list.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, list.items, {}, harness.strLess);
    return list.items;
}

/// `diff -r a b` with every `<root>/tests/fixtures/` written `tests/fixtures/`
/// on both sides. Prints one line per file that is missing or differs, then
/// IDENTICAL or the count; exit 1 on any difference.
fn compare(arena: Allocator, io: Io, a: []const u8, b: []const u8, w: *Io.Writer) !u8 {
    const left = try fileList(arena, io, a);
    const right = try fileList(arena, io, b);
    var differ: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        const order: std.math.Order = if (i == left.len) .gt else if (j == right.len) .lt else std.mem.order(u8, left[i], right[j]);
        switch (order) {
            .lt => {
                try w.print("only in {s}: {s}\n", .{ a, left[i] });
                i += 1;
                differ += 1;
            },
            .gt => {
                try w.print("only in {s}: {s}\n", .{ b, right[j] });
                j += 1;
                differ += 1;
            },
            .eq => {
                const x = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ a, left[i] }), arena, .unlimited);
                const y = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ b, right[j] }), arena, .unlimited);
                if (!std.mem.eql(u8, try unrooted(arena, x), try unrooted(arena, y))) {
                    try w.print("differs: {s}\n", .{left[i]});
                    differ += 1;
                }
                i += 1;
                j += 1;
            },
        }
    }
    if (differ == 0) {
        try w.print("IDENTICAL: {d} files\n", .{left.len});
        return 0;
    }
    try w.print("{d} of {d} files differ\n", .{ differ, @max(left.len, right.len) });
    return 1;
}

/// `text` with each absolute path's root cut back to `tests/fixtures`. A
/// path starts after a space, quote, backtick or parenthesis, or at a line
/// start, and must start with `/`. It may name the fixture root itself, as
/// the include-search note does (`searched: <root>/tests/fixtures, ...`).
fn unrooted(arena: Allocator, text: []const u8) ![]const u8 {
    const key = "/tests/fixtures";
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        const end = at + key.len;
        const whole = end == rest.len or std.mem.indexOfScalar(u8, "/ \t\n,;:'\"`)", rest[end]) != null;
        var start = at;
        while (start > 0 and std.mem.indexOfScalar(u8, " \t\n'\"`(", rest[start - 1]) == null) start -= 1;
        if (whole and rest[start] == '/') {
            try out.appendSlice(arena, rest[0..start]);
            try out.appendSlice(arena, key[1..]);
        } else {
            try out.appendSlice(arena, rest[0..end]);
        }
        rest = rest[end..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

test "unrooted: two checkouts' diagnostics compare equal" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = "  --> /home/a/VerA/tests/fixtures/ch02/x.va:3:5\n`/home/a/VerA/tests/fixtures/y.vh`\n";
    const b = "  --> /tmp/wt/b/tests/fixtures/ch02/x.va:3:5\n`/tmp/wt/b/tests/fixtures/y.vh`\n";
    try std.testing.expectEqualStrings(try unrooted(arena, a), try unrooted(arena, b));
    try std.testing.expectEqualStrings("  --> tests/fixtures/ch02/x.va:3:5\n", try unrooted(arena, "  --> /r/tests/fixtures/ch02/x.va:3:5\n"));
    // The include-search note names the root itself, with no slash after it.
    try std.testing.expectEqualStrings(
        "searched: tests/fixtures, tests/fixtures/ch10\n",
        try unrooted(arena, "searched: /a/b/tests/fixtures, /a/b/tests/fixtures/ch10\n"),
    );
    // A longer name is not the fixture root.
    try std.testing.expectEqualStrings("/r/tests/fixtures2/x", try unrooted(arena, "/r/tests/fixtures2/x"));
    // A relative mention is not a root and stays as written.
    try std.testing.expectEqualStrings("see tests/fixtures/a.va", try unrooted(arena, "see tests/fixtures/a.va"));
}
