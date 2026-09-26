//! `zig build test-1364 -- --coverage`: the IEEE 1364-2005 clause inventory.
//!
//! in:  `tests/fixtures/ieee1364/CLAUSES.tsv` (every heading of the 1364-2005
//!      table of contents, classified) and every `.v` under `ieee1364/`.
//! out: the AMS `--coverage` report's work lists and summary line, over
//!      1364's clauses, plus one row per clause chapter.
//!
//! A static inventory, like its AMS twin in `harness.zig`: nothing is compiled
//! or run here, so a cite says what a fixture claims, not that it passes.
//! A fixture's cites are its `//! inherited IEEE 1364-2005 <clause>...` lines;
//! it is a rejection fixture when it opts into the digital reject runner or
//! carries a `//! reject` line, otherwise a positive one.

const std = @import("std");
const harness = @import("harness.zig");
const options = @import("suite_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Clause = struct {
    id: []const u8,
    title: []const u8,
    /// `null` is an ordinary clause (`-` in the file).
    kind: ?harness.ClassKind,
    pos: bool = false,
    neg: bool = false,
};

/// Per clause chapter (`5`, `17`, `A`): the fixtures in its directory and how
/// its clauses are evidenced.
const Chapter = struct {
    fixtures: usize = 0,
    uncited_fixtures: usize = 0,
    clauses: usize = 0,
    both: usize = 0,
    pos_only: usize = 0,
    neg_only: usize = 0,
    uncited: usize = 0,
    classified: usize = 0,
};

pub fn coverage(init: std.process.Init) !u8 {
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const root = try std.fs.path.join(arena, &.{ options.fixture_root, "ieee1364" });
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    // The clause table, in table-of-contents order.
    var clauses: std.ArrayList(Clause) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var bad: usize = 0;
    {
        const text = try dir.readFileAlloc(io, "CLAUSES.tsv", arena, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            const c = parseRow(arena, line) catch |err| {
                try w.print("BAD CLAUSES.tsv ROW — line {d}: {s}\n", .{ line_no, @errorName(err) });
                bad += 1;
                continue;
            };
            const g = try index.getOrPut(arena, c.id);
            if (g.found_existing) {
                try w.print("BAD CLAUSES.tsv ROW — line {d}: duplicate clause {s}\n", .{ line_no, c.id });
                bad += 1;
                continue;
            }
            g.value_ptr.* = clauses.items.len;
            try clauses.append(arena, c);
        }
    }

    try w.writeAll(
        "STATIC CITATION INVENTORY — IEEE 1364-2005, fixtures under ieee1364/.\n" ++
            "Fixtures are not executed by --coverage; both polarities cited does not\n" ++
            "establish passing tests or every rule within a clause.\n\n",
    );

    var chapters: std.StringArrayHashMapUnmanaged(Chapter) = .empty;
    var fixtures: usize = 0;
    var citing: usize = 0;
    var unresolved: usize = 0;
    var uncited_paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".v")) continue;
        const path = try arena.dupe(u8, e.path);
        const source = try dir.readFileAlloc(io, path, arena, .limited(1 << 20));
        const ch = try chapterOf(&chapters, arena, path);
        fixtures += 1;
        ch.fixtures += 1;
        const neg = harness.digitalNegative(source) or hasReject(source);
        var cites: std.ArrayList([]const u8) = .empty;
        try inheritedCites(arena, source, &cites);
        if (cites.items.len == 0) {
            ch.uncited_fixtures += 1;
            try uncited_paths.append(arena, path);
            continue;
        }
        citing += 1;
        for (cites.items) |id| {
            const i = index.get(id) orelse {
                try w.print("UNRESOLVED — ieee1364/{s} cites §{s}, which CLAUSES.tsv does not list\n", .{ path, id });
                unresolved += 1;
                continue;
            };
            if (neg) clauses.items[i].neg = true else clauses.items[i].pos = true;
        }
    }

    // The same buckets `harness.reportCoverage` prints. A classification moves
    // a one-way or uncited clause out of its work list; two-way evidence wins.
    for (clauses.items) |c| {
        if (c.kind == .no_prohibition and !c.pos) {
            try w.print("BAD CLAUSES.tsv ROW — §{s}: no-prohibition, but no positive fixture cites it\n", .{c.id});
            bad += 1;
        }
    }
    var total: Chapter = .{};
    const headers = [_][]const u8{
        "",
        "\nPOSITIVE CITATIONS ONLY — no rejection fixture cites these:\n",
        "\nREJECTION CITATIONS ONLY — no positive behaviour is established:\n",
        "\nUNCITED — no fixture names these at all:\n",
        "\nCLASSIFIED — CLAUSES.tsv says the clause states no obligation a fixture pins:\n",
    };
    for ([_]Bucket{ .pos_only, .neg_only, .uncited, .classified }) |want| {
        var printed = false;
        for (clauses.items) |c| {
            if (bucketOf(c) != want) continue;
            if (!printed) try w.writeAll(headers[@intFromEnum(want)]);
            printed = true;
            if (want == .classified)
                try w.print("§{s} {s}  [{s}]\n", .{ c.id, c.title, @tagName(c.kind.?) })
            else
                try w.print("§{s} {s}\n", .{ c.id, c.title });
        }
    }
    for (clauses.items) |c| {
        const ch = try chapters.getOrPut(arena, topOf(c.id));
        if (!ch.found_existing) ch.value_ptr.* = .{};
        inline for (.{ ch.value_ptr, &total }) |t| {
            t.clauses += 1;
            switch (bucketOf(c)) {
                .both => t.both += 1,
                .pos_only => t.pos_only += 1,
                .neg_only => t.neg_only += 1,
                .uncited => t.uncited += 1,
                .classified => t.classified += 1,
            }
        }
    }

    if (uncited_paths.items.len != 0) {
        std.mem.sort([]const u8, uncited_paths.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        try w.writeAll("\nFIXTURES CITING NO 1364-2005 CLAUSE — they run, and count for nothing here:\n");
        for (uncited_paths.items) |p| try w.print("  ieee1364/{s}\n", .{p});
    }

    try w.writeAll("\nchapter\tfixtures\tuncited-fixtures\tclauses\tboth\tpos-only\trej-only\tuncited\tclassified\n");
    for (clauses.items) |c| {
        if (std.mem.indexOfScalar(u8, c.id, '.') != null) continue;
        const t = chapters.get(c.id).?;
        try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            c.id, t.fixtures, t.uncited_fixtures, t.clauses, t.both, t.pos_only, t.neg_only, t.uncited, t.classified,
        });
    }

    const n = clauses.items.len;
    var uncited_classified: usize = 0;
    for (clauses.items) |c| {
        if (c.kind != null and !c.pos and !c.neg) uncited_classified += 1;
    }
    try w.print(
        "\n{d} of {d} IEEE 1364-2005 clauses cited, by {d} of {d} fixtures\n" ++
            "  {d} cited both ways · {d} positive citations only · {d} rejection citations only · {d} uncited · {d} classified\n",
        .{
            n - total.uncited - uncited_classified, n,
            citing,                                 fixtures,
            total.both,                             total.pos_only,
            total.neg_only,                         total.uncited,
            total.classified,
        },
    );
    if (unresolved != 0) try w.print("{d} cite(s) resolve to no clause\n", .{unresolved});
    if (bad != 0) try w.print("{d} CLAUSES.tsv row(s) rejected\n", .{bad});
    return if (unresolved == 0 and bad == 0) 0 else 1;
}

const Bucket = enum { both, pos_only, neg_only, uncited, classified };

fn bucketOf(c: Clause) Bucket {
    if (c.pos and c.neg) return .both;
    if (c.kind != null) return .classified;
    if (c.pos) return .pos_only;
    if (c.neg) return .neg_only;
    return .uncited;
}

/// `5.1.14` -> `5`, `A.6.7` -> `A`.
fn topOf(id: []const u8) []const u8 {
    return id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
}

/// The chapter a fixture's directory files it under: `05_expressions/x.v` -> `5`.
fn chapterOf(map: *std.StringArrayHashMapUnmanaged(Chapter), arena: Allocator, path: []const u8) !*Chapter {
    const dir = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse 0];
    var id = dir[0 .. std.mem.indexOfScalar(u8, dir, '_') orelse dir.len];
    id = std.mem.trimStart(u8, id, "0");
    const g = try map.getOrPut(arena, id);
    if (!g.found_existing) g.value_ptr.* = .{};
    return g.value_ptr;
}

fn parseRow(arena: Allocator, line: []const u8) !Clause {
    var cols = std.mem.splitScalar(u8, line, '\t');
    const id = cols.next() orelse return error.MissingClause;
    if (id.len == 0) return error.MissingClause;
    const kind_text = cols.next() orelse return error.MissingKind;
    const title = cols.next() orelse return error.MissingTitle;
    const evidence = std.mem.trim(u8, cols.rest(), " \t");
    if (std.mem.eql(u8, kind_text, "-")) return .{ .id = id, .title = title, .kind = null };
    const spelled = try arena.dupe(u8, kind_text);
    std.mem.replaceScalar(u8, spelled, '-', '_');
    const kind = std.meta.stringToEnum(harness.ClassKind, spelled) orelse return error.UnknownKind;
    if (evidence.len == 0) return error.MissingEvidence;
    return .{ .id = id, .title = title, .kind = kind };
}

fn hasReject(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var words = std.mem.tokenizeAny(u8, line["//!".len..], " \t");
        if (std.mem.eql(u8, words.next() orelse continue, "reject")) return true;
    }
    return false;
}

/// `//! inherited IEEE 1364-2005 17.5.1,17.5.3 (note)` -> `17.5.1`, `17.5.3`.
/// Clauses are the words before a parenthesised note, split on spaces and
/// commas; a word that is not a clause number is returned as-is and so
/// reported unresolved rather than silently dropped.
fn inheritedCites(arena: Allocator, source: []const u8, out: *std.ArrayList([]const u8)) !void {
    const key = "inherited IEEE 1364-2005 ";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        const rest = std.mem.trimStart(u8, line["//!".len..], " \t");
        if (!std.mem.startsWith(u8, rest, key)) continue;
        const list = rest[key.len..];
        var words = std.mem.tokenizeAny(u8, list[0 .. std.mem.indexOfScalar(u8, list, '(') orelse list.len], " ,");
        while (words.next()) |id| try out.append(arena, id);
    }
}

test "inherited cites: lists, commas, and a note that is not a clause" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var got: std.ArrayList([]const u8) = .empty;
    try inheritedCites(arena,
        \\// inherited IEEE 1364-2005 9.9 in prose is not a cite
        \\//! lrm 9.8
        \\//! inherited IEEE 1364-2005 17.5.1,17.5.3
        \\  //! inherited IEEE 1364-2005 12.4.1 5.2.1 (loop generate, 17.1)
    , &got);
    const want = [_][]const u8{ "17.5.1", "17.5.3", "12.4.1", "5.2.1" };
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(hasReject("//! reject E0235\n"));
    try std.testing.expect(!hasReject("// reject E0235\n//! rejected\n"));
}
