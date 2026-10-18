//! The `golden` mode: what the compiler SAYS about every fixture, snapshotted,
//! so a refactor can prove it changed nothing.
//!
//!   zig build golden -- before        # on the pre-change tree
//!   zig build golden -- after         # ... the change ...
//!   zig build golden -- diff          # before vs after; exit 1 on a difference
//!   zig build golden -- diff A B      # two tags, or two snapshot directories
//!
//! A snapshot is `.zig-cache/vera-golden/<tag>/`, per `.va` and `.v` under
//! `tests/fixtures`:
//!
//!   <path>.txt           `vera --emit-zig` stdout, then a last line `exit=<code>`
//!   <path>.stderr        its stderr: the message text is held too, and vera
//!                        writes the device at offset 0, so one file would
//!                        lose the warnings
//!   <path>.runner.txt    a `.va` with a `//!` line: the testbench runner
//!                        `tb.renderRunner` gives `--emit-exe` (`runner`)
//!   <path>.so/...        a `.va`: the tree `--emit-so` writes before `zig`
//!                        runs, `shim.zig` and the split device (`soTree`)
//!   <path>.program.txt   a `.v`: the executable root `--emit-exe` builds
//!                        (`digital.program`)
//!
//! The last three are made in-process through `vera`'s and `sim`'s API, not by
//! spawning. A kind that fails is `error=<name>` in its own file (a `.so` tree
//! is then `<path>.so.error.txt`), so it hides no other kind.
//!
//! Every file is written with the checkout's root cut out (`unrooted`): the
//! fixture's absolute path reaches diagnostics, device and program text
//! (`$fopen`, `$readmem`, the fallback's `file_name`), so two worktrees'
//! snapshots are equal byte for byte. `diff` cuts it again, for snapshots an
//! older tree wrote.
//!
//! Not a cacheable build step: the build graph cannot see fixture contents, so
//! a cached run would compare nothing (`build.zig`'s note on `test-devices`).

const std = @import("std");
const options = @import("suite_options");
const harness = @import("../harness.zig");
const vera = @import("vera");
const digital = @import("sim").digital;
/// The native emitter (lib/digital/).
const native = @import("digital");

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
    if (std.mem.findScalar(u8, arg, '/') != null) return arg;
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

    /// One fixture's files (the header lists them): `vera --emit-zig`, then
    /// the in-process kinds. The include path is the shared `tests/fixtures`
    /// and the fixture's own directory. Only an I/O failure of the snapshot
    /// itself is returned; a kind's own failure is its `error=` file.
    fn one(pool: *Pool, rel: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(pool.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const io = pool.io;
        const src = try std.fs.path.join(arena, &.{ options.fixture_root, rel });
        const base = try std.mem.concat(arena, u8, &.{ pool.out, "/", rel });
        const txt = try std.mem.concat(arena, u8, &.{ base, ".txt" });
        const err = try std.mem.concat(arena, u8, &.{ base, ".stderr" });
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(txt).?);
        const includes: []const []const u8 = &.{ options.fixture_root, std.fs.path.dirname(src).? };

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
        try save(io, arena, txt, try arena.print("{s}exit={d}\n", .{ try readAll(io, arena, txt), code }));
        try save(io, arena, err, try readAll(io, arena, err));

        const source = try readAll(io, arena, src);
        if (std.mem.endsWith(u8, rel, ".v")) {
            const text = program(arena, io, src, includes, source) catch |e| try arena.print("error={t}\n", .{e});
            return save(io, arena, try std.mem.concat(arena, u8, &.{ base, ".program.txt" }), text);
        }
        if (harness.hasDirective(source)) {
            const text = runner(pool.gpa, arena, src, includes, source) catch |e| try arena.print("error={t}\n", .{e});
            try save(io, arena, try std.mem.concat(arena, u8, &.{ base, ".runner.txt" }), text);
        }
        const so = try std.mem.concat(arena, u8, &.{ base, ".so" });
        if (soTree(pool.gpa, io, arena, src, includes, source, so)) |_| {
            for (try fileList(arena, io, so)) |p| {
                const path = try std.fs.path.join(arena, &.{ so, p });
                try save(io, arena, path, try readAll(io, arena, path));
            }
        } else |e| try save(io, arena, try std.mem.concat(arena, u8, &.{ so, ".error.txt" }), try arena.print("error={t}\n", .{e}));
    }
};

fn readAll(io: Io, arena: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
}

/// Writes `text` to `path` with the checkout's root cut out (`unrooted`).
fn save(io: Io, arena: Allocator, path: []const u8, text: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try unrooted(arena, text) });
}

/// The runner `vera --emit-exe` renders for a `//!` fixture, from the inputs
/// the fixture suite gives it (`torture.zig`'s `runAndCheck`): display on, the
/// directives' SPICE text and discipline resolution, the shape cards compiled
/// in, the contract checks on.
fn runner(gpa: Allocator, arena: Allocator, src: []const u8, includes: []const []const u8, source: []const u8) ![]const u8 {
    const d = try vera.tb.parse(arena, source);
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var opts: vera.Options = .{
        .file_name = src,
        .include_dirs = includes,
        .diags = &bag,
        .display = if (d.display_record) .record else .emit,
        .spice_netlist = d.spice,
        .spice_path = src,
        .discipline_resolution = d.discipline_resolution,
    };
    var result = try vera.compileSourceOpts(gpa, source, .build, opts);
    defer result.deinit();
    // §3.4 a shape card is a compile-time value: compile again, as vera does.
    opts.param_overrides = try vera.tb.shapeOverrides(arena, d, result.lowered);
    if (opts.param_overrides.len != 0) {
        bag.deinit(gpa);
        bag = .init(gpa);
        const again = try vera.compileSourceOpts(gpa, source, .build, opts);
        result.deinit();
        result = again;
    }
    var dm = d;
    dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
    dm.op_states = try vera.tb.opStates(arena, result.lowered);
    dm.mem_bytes = vera.tb.memBytes(result.lowered);
    dm.validate_contract = true;
    return vera.tb.renderRunner(arena, std.fs.path.stem(src), dm);
}

/// The tree `vera --emit-so` writes for a `.va` device before `zig` runs
/// (`orchestrator.writeTree`): `shim.zig`, and the split `device.zig`, `h.zig`
/// and `u/*.zig`. A split LLVM build's part and chunk shims and the engine
/// root are written only beside a `zig` child; `zigbuild/shim.zig`'s whole-file
/// tests pin those.
fn soTree(gpa: Allocator, io: Io, arena: Allocator, src: []const u8, includes: []const []const u8, source: []const u8, dir: []const u8) !void {
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    // `.record` is `vera`'s default display (`args.Cli`), not `Options`'.
    var result = try vera.compileSourceOpts(gpa, source, .build, .{ .file_name = src, .include_dirs = includes, .diags = &bag, .display = .record });
    defer result.deinit();
    const device = try result.generateOutput();
    if (result.device_has_compile_error) return error.CodegenRefused;
    _ = try vera.orchestrator.writeTree(io, gpa, .{
        .work_dir = dir,
        .name = try vera.orchestrator.fileStem(arena, result.mir.name),
        .optimize = .fast,
        .backend = .llvm,
        .modules = &.{},
    }, device);
}

/// The executable root `vera --emit-exe` builds for a `.v` design with default
/// flags (`src/cli/digital.zig`'s `emitDigital`): native, or the interpreter
/// fallback, whose reason is in its header.
fn program(arena: Allocator, io: Io, src: []const u8, includes: []const []const u8, source: []const u8) ![]const u8 {
    var bag: vera.diag.Bag = .init(arena);
    const opts: digital.Options = .{ .file_name = src, .include_dirs = includes, .io = io };
    var sink: Io.Writer.Discarding = .init(&.{});
    var r = try digital.elaborate(arena, source, opts, &bag, &sink.writer);
    if (bag.failed()) return error.DigitalFailed;
    const prog = try native.program(arena, &r, .{
        .source = source,
        .file_name = opts.file_name,
        .include_dirs = opts.include_dirs,
        .language = opts.language,
        .lib = opts.lib,
        .more = opts.more,
        .search = opts.search,
    }, .static, .auto);
    return prog.text;
}

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
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, arena);
    var pool: Pool = .{ .io = io, .gpa = gpa, .vera = exe, .out = out, .rels = try fixtureList(arena, io) };
    // The suite's default, not one per core: 32 concurrent `vera` runs and
    // their device builds exhausted the host's memory (harness.defaultJobs).
    const jobs = harness.defaultJobs();
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
    while (std.mem.find(u8, rest, key)) |at| {
        const end = at + key.len;
        const whole = end == rest.len or std.mem.findScalar(u8, "/ \t\n,;:'\"`)", rest[end]) != null;
        var start = at;
        while (start > 0 and std.mem.findScalar(u8, " \t\n'\"`(", rest[start - 1]) == null) start -= 1;
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
