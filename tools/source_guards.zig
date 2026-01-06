//! Source-tree guards: two greps over `src/`, run by `zig build test-contract`.
//! No LRM section — this checks the repo's own doctrine, not Verilog-AMS.
//!
//! Both guards exist because the same defect shipped repeatedly and neither the
//! compiler nor the fixture suite can see it:
//!
//!   (a) A CITATION THAT DOES NOT RESOLVE. `tools/contract.zig`'s header records
//!       four revisions burned by exactly this, and wave 12 found ~18 more sites
//!       pointing at `03-codegen.html` / `02-incremental.html` /
//!       `05-build-artifact.html` — three files `git log --all` shows were never
//!       in this tree. A pointer to a file nobody can open reads as evidence
//!       that an argument was written down somewhere. Here it is a defect.
//!
//!   (b) AN ORPHAN IN `src/backend/`. `eval_batch.zig` was 702 lines reachable
//!       by nothing but its own test. Deleting it once is a cleanup; this guard
//!       is what makes it unrepeatable.
//!
//! WHY NOT IN `tools/contract.zig`, whose step this joins: that file is compiled
//! INTO every generated device, so it may not import a build-options module and
//! may not depend on a source tree existing at all. It also deliberately cites
//! three paths that do not resolve — the register of its own burned revisions —
//! which guard (a) would have to special-case. Both files, one step.
//!
//! WHY `src/` AND NOT `tools/`: same reason. Widen the scan the day `tools/`
//! stops being the place where dead pointers are quoted as history.

const std = @import("std");
const opts = @import("guard_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Characters a cited path may be spelled with. Anything else ends the token,
/// which is what lets a citation sit inside prose, backticks or parentheses.
fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-';
}

/// Every `.zig` under `src/`, as repo-root-relative paths. Sorted, so a failing
/// run prints the same list twice — `Dir.walk` order is explicitly undefined.
///
/// Heap, not a stack array: the file count is a directory walk, so there is no
/// compile-time bound to spend (standing rule 0's first exception).
fn srcFiles(arena: Allocator, io: Io) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, opts.src_root, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try list.append(arena, try std.fs.path.join(arena, &.{ "src", entry.path }));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return list.items;
}

fn read(arena: Allocator, io: Io, rel: []const u8) ![]const u8 {
    const abs = try std.fs.path.join(arena, &.{ opts.repo_root, rel });
    return Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(8 << 20));
}

fn resolves(arena: Allocator, io: Io, rel: []const u8) bool {
    const abs = std.fs.path.join(arena, &.{ opts.repo_root, rel }) catch return false;
    Io.Dir.cwd().access(io, abs, .{}) catch return false;
    return true;
}

/// Repo-root-relative path of `target` as `@import`ed from the file at `from`.
fn importPath(arena: Allocator, from: []const u8, target: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(from) orelse ".";
    // `resolve` against a fake absolute root collapses `..` for us; strip the
    // leading `/` to get back to a repo-relative path.
    const abs = try std.fs.path.resolve(arena, &.{ "/", dir, target });
    return abs[1..];
}

// ---------------------------------------------------------------------------
// (a) every cited path resolves on disk
// ---------------------------------------------------------------------------

// A citation must carry its directory: `docs/ch5-analog.html`, not
// `ch5-analog.html`. That is the form that can be checked, and the bare form is
// exactly what the three phantom design docs were written in.
test "every .html and tests/*.zig citation under src/ resolves on disk" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var bad: usize = 0;
    for (try srcFiles(arena, io)) |rel| {
        const text = try read(arena, io, rel);

        // `.html`: scan BACKWARD from the extension, so `#hoisting` anchors and
        // any `(`/backtick in front of the path fall away on their own.
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, ".html")) |hit| {
            i = hit + ".html".len;
            var start = hit;
            while (start > 0 and isPathChar(text[start - 1])) start -= 1;
            const cite = text[start..i];
            if (resolves(arena, io, cite)) continue;
            std.debug.print("{s}: cites `{s}`, which is not on disk\n", .{ rel, cite });
            bad += 1;
        }

        // `tests/…zig`: scan FORWARD, since the interesting prefix is literal.
        i = 0;
        while (std.mem.indexOfPos(u8, text, i, "tests/")) |hit| {
            var end = hit;
            while (end < text.len and isPathChar(text[end])) end += 1;
            i = end;
            const cite = text[hit..end];
            if (!std.mem.endsWith(u8, cite, ".zig")) continue;
            if (resolves(arena, io, cite)) continue;
            std.debug.print("{s}: cites `{s}`, which is not on disk\n", .{ rel, cite });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (b) no orphan in src/backend/
// ---------------------------------------------------------------------------

/// Reachability, not "is imported somewhere": a file imported only by another
/// unreachable file is still an orphan, and that is the shape a half-deleted
/// module leaves behind.
///
/// TWO roots, because there are two: `src/root.zig` is the engine module and
/// `src/cli.zig` is the binary's, and the binary imports the engine rather than
/// the other way round.
fn reachable(arena: Allocator, io: Io) !std.StringHashMapUnmanaged(void) {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var work: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "src/root.zig", "src/cli.zig" }) |root| {
        try seen.put(arena, root, {});
        try work.append(arena, root);
    }

    while (work.pop()) |rel| {
        const text = try read(arena, io, rel);
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, "@import(\"")) |hit| {
            const from = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, text, from, '"') orelse break;
            i = end + 1;
            const target = text[from..end];
            // `std`, `builtin`, `contract`, `build_options`, … are module names,
            // not paths, and none of them can be an orphan of ours.
            if (!std.mem.endsWith(u8, target, ".zig")) continue;
            const next = try importPath(arena, rel, target);
            // codegen.zig and orchestrator.zig hold `@import("…zig")` inside the
            // text they EMIT (`u/<unit>.zig` importing `../h.zig`), which names
            // a file in the device work tree, not in this repo. A real import
            // that does not resolve is already a compile error, so `zig build
            // test` owns that case and skipping here loses nothing.
            if (!resolves(arena, io, next)) continue;
            if ((try seen.getOrPut(arena, next)).found_existing) continue;
            try work.append(arena, next);
        }
    }
    return seen;
}

/// The allowlist is `src/root.zig`'s orphan register, in the header block that
/// already documents why a file can sit outside the import graph. One line per
/// exception, `//! ORPHAN: <path under src/> — <why>`; empty today, because the
/// six kernel files are all `@import`ed by a codegen test as well as
/// `@embedFile`d by the emitter.
fn orphanRegister(arena: Allocator, io: Io) ![]const []const u8 {
    const text = try read(arena, io, "src/root.zig");
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "//! ORPHAN:") orelse continue;
        const rest = std.mem.trimStart(u8, line[at + "//! ORPHAN:".len ..], " ");
        var end: usize = 0;
        while (end < rest.len and isPathChar(rest[end])) end += 1;
        if (end == 0) continue;
        try list.append(arena, try std.fs.path.join(arena, &.{ "src", rest[0..end] }));
    }
    return list.items;
}

test "every src/backend/*.zig is reachable from src/root.zig or registered" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const seen = try reachable(arena, io);
    const register = try orphanRegister(arena, io);

    var bad: usize = 0;
    for (try srcFiles(arena, io)) |rel| {
        if (!std.mem.startsWith(u8, rel, "src/backend/")) continue;
        if (seen.contains(rel)) continue;
        if (for (register) |allowed| {
            if (std.mem.eql(u8, allowed, rel)) break true;
        } else false) continue;
        std.debug.print(
            "{s}: nothing reaches it from src/root.zig or src/cli.zig. Wire it in," ++
                " delete it, or add `//! ORPHAN: {s} — <why>` to src/root.zig.\n",
            .{ rel, rel["src/".len..] },
        );
        bad += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}
