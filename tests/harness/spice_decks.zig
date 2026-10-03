//! The `spice` mode: each `.sp` deck (a SPICE netlist with `.hdl "model.va"`
//! cards and an `.expected.json` analytic oracle). The simulator that runs them
//! is not in this repository, so this checks the half it owns: the oracle
//! exists, every `.hdl` model resolves (`resolveModel`), and each compiles.
//!
//!   zig build test-spice            # all of them
//!   zig build test-spice -- a10     # the decks whose name contains a10

const std = @import("std");
const options = @import("suite_options");
const harness = @import("../harness.zig");
const child = @import("child.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// Where a `.hdl` reference is. The literal relative path first; else the
/// flattened name the fixture tree actually uses (`/` replaced by `_`, e.g.
/// `a06_ntab.assets/a06_ntab_lin.va` filed as
/// `a06_noisetables_a06_ntab.assets_a06_ntab_lin.va`), matched as a suffix of
/// exactly one file in the deck's directory. Two matches are unresolved.
fn resolveModel(arena: Allocator, io: Io, dir_path: []const u8, ref: []const u8) !?[]const u8 {
    const literal = try std.fs.path.join(arena, &.{ dir_path, ref });
    if (Io.Dir.cwd().access(io, literal, .{})) |_| return literal else |_| {}

    const flat = try arena.dupe(u8, ref);
    std.mem.replaceScalar(u8, flat, '/', '_');
    std.mem.replaceScalar(u8, flat, '\\', '_');

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var hit: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, flat)) continue;
        if (hit != null) return null; // ambiguous: two files claim one reference
        hit = try std.fs.path.join(arena, &.{ dir_path, entry.name });
    }
    return hit;
}

/// The `spice` mode: checks each `.sp` deck matching the filter in `args` and
/// prints its FAIL lines and a census to stderr. Exit 1 on any FAIL or when
/// nothing matched.
pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var filter: ?[]const u8 = null;
    while (args.next()) |a| filter = a;

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    var decks: std.ArrayList([]const u8) = .empty;
    defer decks.deinit(gpa);
    {
        var root = try Io.Dir.cwd().openDir(io, options.fixture_root, .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walk(arena_state.allocator());
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".sp")) continue;
            try decks.append(gpa, try arena_state.allocator().dupe(u8, entry.path));
        }
    }
    std.mem.sort([]const u8, decks.items, {}, harness.strLess);

    var ran: usize = 0;
    var failed: usize = 0;
    for (decks.items) |rel| {
        if (filter) |f| if (std.mem.indexOf(u8, rel, f) == null) continue;
        ran += 1;
        const pa = arena_state.allocator();
        const path = try std.fs.path.join(pa, &.{ options.fixture_root, rel });
        const dir_path = std.fs.path.dirname(path) orelse ".";
        const name = std.fs.path.basename(rel);
        var bad = false;

        // 1. The oracle. A deck with no `.expected.json` states no result, so
        //    no simulator could grade it and it is not a fixture yet.
        const stem = path[0 .. path.len - ".sp".len];
        const oracle = try pa.print("{s}.expected.json", .{stem});
        if (Io.Dir.cwd().access(io, oracle, .{})) |_| {} else |_| {
            try w.print("FAIL {s}: no .expected.json beside it\n", .{name});
            bad = true;
        }

        // 2. Every model the deck names, one `.hdl "<path>"` per line.
        const source = try Io.Dir.cwd().readFileAlloc(io, path, pa, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, source, '\n');
        var models: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, ".hdl")) continue;
            const open = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const rest = line[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const ref = rest[0..close];
            models += 1;

            const model = (try resolveModel(pa, io, dir_path, ref)) orelse {
                try w.print("FAIL {s}: .hdl \"{s}\" resolves to no file\n", .{ name, ref });
                bad = true;
                continue;
            };
            // 3. VerA's own half: the model has to compile. `--check` and both
            //    include dirs, per AGENTS.md §6 — `check.vh` is at the suite
            //    root and the model's siblings are beside it.
            const r = child.capture(pa, io, &.{
                vera_exe, "--check",            "--contract", options.contract,
                "-I",     options.fixture_root, "-I",         dir_path,
                model,
            }) catch |e| {
                try w.print("FAIL {s}: could not run vera: {s}\n", .{ name, @errorName(e) });
                bad = true;
                continue;
            };
            if (r.exit != 0) {
                try w.print("FAIL {s}: model {s} does not compile\n{s}", .{
                    name, std.fs.path.basename(model), r.stderr,
                });
                bad = true;
            }
        }
        if (models == 0) {
            try w.print("FAIL {s}: no .hdl card, so the deck names no model\n", .{name});
            bad = true;
        }
        if (bad) failed += 1;
    }

    if (ran == 0) {
        try w.print("spice: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print(
        \\spice: {d}/{d} decks are paired with an oracle and name models that compile
        \\spice: NOT executed — a deck needs a circuit simulator to link the device and
        \\spice:   turn the Newton loop. That is ARPice (ROADMAP.md §6), which is not in
        \\spice:   this repository, so no release here can run one.
        \\
    , .{ ran - failed, ran });
    return if (failed == 0) 0 else 1;
}

test "a flattened .assets reference is a suffix of the committed name" {
    // The decks say `.hdl "a10_host.assets/a10_vsine.va"` but the tree is
    // flattened. Only the pure slug half is pinned here; the census covers the
    // filesystem half.
    const ref = "a10_host.assets/a10_vsine.va";
    var flat: [64]u8 = undefined;
    @memcpy(flat[0..ref.len], ref);
    std.mem.replaceScalar(u8, flat[0..ref.len], '/', '_');
    try std.testing.expectEqualStrings("a10_host.assets_a10_vsine.va", flat[0..ref.len]);

    // Flattening also prefixes the directories above, which is why the match is
    // a SUFFIX and not an equality.
    try std.testing.expect(std.mem.endsWith(
        u8,
        "a06_noisetables_a06_ntab.assets_a06_ntab_lin.va",
        "a06_ntab.assets_a06_ntab_lin.va",
    ));
    // ...and why it is not a substring: that would let a model match a deck it
    // has nothing to do with.
    try std.testing.expect(!std.mem.endsWith(
        u8,
        "a06_ntab.assets_a06_ntab_lin_UNRELATED.va",
        "a06_ntab.assets_a06_ntab_lin.va",
    ));
}
