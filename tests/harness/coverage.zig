//! `zig build benchmark -- --coverage`: the collected fixtures' `//! lrm`
//! cites, the `.c` VPI fixtures' cites, every `CLAUSES.tsv` row, and the LRM's
//! table of contents read out of `specification/*.html` -> the static citation
//! inventory on stderr (measure C). Nothing is compiled or run.
//!
//! The report's lines are parsed by `tools/conformance.py`: the
//! `<n> of <m> LRM clauses cited` tally and its polarity row are frozen text.
//!
//! Clauses: `specification/CLAUSE-AUDIT.md` §5 (the classification kinds) and §5.7
//! (`not_supported`, IEEE 1364-only).

const std = @import("std");
const vera = @import("vera");
const options = @import("suite_options");
const harness = @import("../harness.zig");

const Io = std.Io;
const Fixture = harness.Fixture;
const strLess = harness.strLess;

/// `--coverage`: the cited clauses, the uncited ones, and cites that name no
/// clause, all against the table of contents read from `specification/*.html`.
///
/// A static inventory: nothing is compiled or run, so a cite proves nothing
/// (an XFAIL still cites). Each cite carries its fixture's declared polarity,
/// and the report separates `+` from `-` and lists one-sided clauses, because
/// refusing a construct is not implementing it. One-sided is listed, not
/// scored: a clause that states no error has nothing to reject.
///
/// The `.c` VPI fixtures cite with the same `//! lrm` lines (`cCites`), with
/// per-line polarity, and count only when `build.zig` runs them: a `.c` that
/// only compiles is listed as `~` and moves no number.
///
/// Returns whether every cite resolved; an unresolved cite is a fixture defect.
/// Uncited and one-sided clauses are work items and do not affect the result.
pub fn report(
    arena: std.mem.Allocator,
    io: Io,
    docs_root: []const u8,
    root: []const u8,
    filter: ?[]const u8,
    fixtures: []const Fixture,
    w: *Io.Writer,
) !bool {
    const clauses = try lrmClauses(arena, io, docs_root);
    try w.writeAll(
        "STATIC CITATION INVENTORY — fixtures are not executed by --coverage.\n" ++
            "Both polarities cited does not establish passing tests, valid oracles,\n" ++
            "all rules within a clause, or Verilog-A applicability. XFAIL citations\n" ++
            "and implementation-limit rejections remain in this inventory.\n\n",
    );

    var cites: std.ArrayList(Cite) = .empty;
    var citing: usize = 0;
    for (fixtures) |f| {
        const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));
        // A fixture whose directives do not parse is reported by the run
        // proper; a coverage report is not the place to fail on it.
        const d = vera.tb.parse(arena, source) catch continue;
        var cited = false;
        for (d.lrm) |s| {
            // A sentence cite (`5.6.1.3:2`) is the requirement ledger's
            // (`conformance.py metric`), not this
            // clause inventory's: only a bare clause cite counts here.
            if (std.mem.indexOfScalar(u8, s, ':') != null) continue;
            cited = true;
            try cites.append(arena, .{
                .section = s,
                .path = f.path,
                .side = if (d.reject.len != 0 or d.reject_run.len != 0) .neg else .pos,
            });
        }
        if (cited) citing += 1;
    }
    const c_files = try cFixtures(arena, io, root, filter);
    var bad_tags: usize = 0;
    for (c_files) |path| {
        const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const before = cites.items.len;
        cCites(arena, &cites, path, source, cFixtureRuns(path)) catch |err| switch (err) {
            error.BadCTag => {
                try w.print("BAD TAG — {s}: a `//!` line that is not `lrm <clause>` or `lrm-reject <clause>`\n", .{path});
                bad_tags += 1;
                continue;
            },
            else => |e| return e,
        };
        for (cites.items[before..]) |c| if (c.side != .compiled) {
            citing += 1;
            break;
        };
    }
    std.mem.sort(Cite, cites.items, {}, struct {
        fn lt(_: void, a: Cite, b: Cite) bool {
            if (std.mem.eql(u8, a.section, b.section)) return std.mem.lessThan(u8, a.path, b.path);
            return sectionLessThan(a.section, b.section);
        }
    }.lt);

    // Declared fixture intent only. Results and rule-level evidence are not
    // inputs to this report, so neither flag can mean a verified obligation.
    const Sides = struct { pos: bool = false, neg: bool = false };
    var cited: std.StringHashMapUnmanaged(Sides) = .empty;
    for (cites.items) |c| {
        // A compile-only `.c` cite is listed, never counted: it is not runtime
        // evidence of either polarity.
        if (c.side == .compiled) continue;
        const g = try cited.getOrPut(arena, c.section);
        if (!g.found_existing) g.value_ptr.* = .{};
        if (c.side == .neg) g.value_ptr.neg = true else g.value_ptr.pos = true;
    }
    var compiled: std.StringHashMapUnmanaged(void) = .empty;
    for (cites.items) |c| if (c.side == .compiled) try compiled.put(arena, c.section, {});

    var prev: []const u8 = "";
    for (cites.items) |c| {
        if (!std.mem.eql(u8, c.section, prev)) {
            try w.print("§{s}\n", .{c.section});
            prev = c.section;
        }
        // `+` declares a positive fixture, `-` declares a rejection fixture,
        // `~` a compile-only `.c` fixture. Show each path so a reviewer can
        // inspect the actual evidence.
        try w.print("  {s} {s}\n", .{ switch (c.side) {
            .pos => "+",
            .neg => "-",
            .compiled => "~",
        }, c.path });
    }

    // The cites that name nothing in the LRM. Sorted with everything else, so
    // this walk is over the same array and only has to skip what resolved.
    var unresolved: usize = 0;
    prev = "";
    for (cites.items) |c| {
        if (clauses.get(c.section) != null) continue;
        if (!std.mem.eql(u8, c.section, prev)) {
            if (unresolved == 0) try w.print(
                "\nUNRESOLVED — a `//! lrm` cite naming no clause in {s}. Either the\n" ++
                    "clause is spelled wrong or it is a table or figure number, which is a\n" ++
                    "different numbering space (Table G.7 lives under clause G.1).\n",
                .{docs_root},
            );
            try w.print("§{s}\n", .{c.section});
            prev = c.section;
            unresolved += 1;
        }
        try w.print("  {s}\n", .{c.path});
    }

    // The three work lists, in one walk of the contents page. Titles are printed
    // because a bare number is not a work item and "§7.8.2" plus "Signal
    // segmentation" is.
    var uncited: std.ArrayList(Clause) = .empty;
    var pos_only: std.ArrayList(Clause) = .empty;
    var neg_only: std.ArrayList(Clause) = .empty;
    var it = clauses.valueIterator();
    while (it.next()) |cl| {
        const s = cited.get(cl.id) orelse {
            try uncited.append(arena, cl.*);
            continue;
        };
        if (s.pos and !s.neg) try pos_only.append(arena, cl.*);
        if (s.neg and !s.pos) try neg_only.append(arena, cl.*);
    }
    const byId = struct {
        fn lt(_: void, a: Clause, b: Clause) bool {
            return sectionLessThan(a.id, b.id);
        }
    }.lt;
    for ([_]*std.ArrayList(Clause){ &uncited, &pos_only, &neg_only }) |l|
        std.mem.sort(Clause, l.items, {}, byId);

    // CLAUSE-AUDIT §5 classifications. A one-way or uncited clause the audit
    // classifies leaves its work list for a fifth bucket, printed with its
    // evidence so a reviewer reads the quote rather than the count. A clause
    // tested both ways stays there: a classification never outranks evidence.
    const classes = try readClassifications(arena, io, root, &clauses, &cited, w);
    var classified: std.ArrayList(Classified) = .empty;
    for ([_]*std.ArrayList(Clause){ &uncited, &pos_only, &neg_only }) |l| {
        var keep: usize = 0;
        for (l.items) |cl| {
            if (classes.map.get(cl.id)) |c| {
                try classified.append(arena, .{ .clause = cl, .row = c });
                continue;
            }
            l.items[keep] = cl;
            keep += 1;
        }
        l.shrinkRetainingCapacity(keep);
    }
    std.mem.sort(Classified, classified.items, {}, struct {
        fn lt(_: void, a: Classified, b: Classified) bool {
            return sectionLessThan(a.clause.id, b.clause.id);
        }
    }.lt);

    if (neg_only.items.len != 0) {
        try w.print(
            "\nREJECTION CITATIONS ONLY — every citing fixture declares `//! reject`.\n" ++
                "Review whether it pins a normative prohibition, an implementation\n" ++
                "choice, or a missing feature. No positive behavior is established.\n",
            .{},
        );
        for (neg_only.items) |cl| try w.print("§{s} {s}  ({s})\n", .{ cl.id, cl.title, cl.file });
    }
    if (pos_only.items.len != 0) {
        try w.print(
            "\nPOSITIVE CITATIONS ONLY — no `//! reject` fixture cites these, so no citation pins\n" ++
                "what the clause rules OUT. A clause that states no error has nothing to\n" ++
                "reject and belongs here; one whose text says `shall not` or `is an\n" ++
                "error` does not.\n",
            .{},
        );
        for (pos_only.items) |cl| try w.print("§{s} {s}  ({s})\n", .{ cl.id, cl.title, cl.file });
    }
    if (uncited.items.len != 0) {
        try w.print("\nUNCITED — no fixture names these at all:\n", .{});
        for (uncited.items) |cl| try w.print("§{s} {s}  ({s}){s}\n", .{
            cl.id,
            cl.title,
            cl.file,
            if (compiled.contains(cl.id)) "  ~ compile-only .c cite" else "",
        });
    }

    if (classified.items.len != 0) {
        try w.print(
            "\nCLASSIFIED — CLAUSE-AUDIT §5: the clause states no obligation an input can\n" ++
                "break, or its obligation is of a kind a fixture may not pin one way. Each\n" ++
                "row is a reviewed claim, not evidence; its quote is in the file named.\n",
            .{},
        );
        for (classified.items) |c| try w.print("§{s} {s}  [{s}]  ({s})\n", .{
            c.clause.id, c.clause.title, @tagName(c.row.kind), c.row.file,
        });
    }

    const n = clauses.count();
    var uncited_classified: usize = 0;
    for (classified.items) |c| {
        if (cited.get(c.clause.id) == null) uncited_classified += 1;
    }
    try w.print(
        "\n{d} of {d} LRM clauses cited, by {d} of {d} fixtures\n" ++
            "  {d} cited both ways · {d} positive citations only · {d} rejection citations only · {d} uncited · {d} classified\n",
        .{
            n - uncited.items.len - uncited_classified,                                             n,
            citing,                                                                                 fixtures.len + c_files.len,
            n - uncited.items.len - pos_only.items.len - neg_only.items.len - classified.items.len, pos_only.items.len,
            neg_only.items.len,                                                                     uncited.items.len,
            classified.items.len,
        },
    );
    var compiled_only: usize = 0;
    for (uncited.items) |cl| {
        if (compiled.contains(cl.id)) compiled_only += 1;
    }
    if (compiled_only != 0) try w.print(
        "  {d} of the uncited carry only compile-only `.c` cites (`~`), which are not counted\n",
        .{compiled_only},
    );
    if (unresolved != 0) try w.print("{d} cite(s) resolve to no clause\n", .{unresolved});
    if (bad_tags != 0) try w.print("{d} `.c` fixture(s) carry a malformed tag\n", .{bad_tags});
    if (classes.bad != 0) try w.print("{d} CLAUSES.tsv row(s) rejected\n", .{classes.bad});
    return unresolved == 0 and bad_tags == 0 and classes.bad == 0;
}

/// The CLAUSE-AUDIT §5 kinds a `CLAUSES.tsv` row may name, plus
/// `no_prohibition`: a normative clause whose every sentence is positive, so
/// its positive fixtures are the whole obligation and there is nothing to
/// reject. That one kind is checked against the evidence: it is refused unless
/// a positive fixture cites the clause.
///
/// `not_supported` (CLAUSE-AUDIT §5.7) is IEEE 1364-only: a clause
/// `CLAUSE-AUDIT.md` §5.7 puts out of scope, which VerA refuses or warns about by
/// name. An AMS `CLAUSES.tsv` row naming it is rejected.
pub const ClassKind = enum {
    non_normative,
    no_prohibition,
    optional,
    implementation_defined,
    resource_limit,
    unspecified,
    not_supported,
};

const ClassRow = struct { kind: ClassKind, file: []const u8 };
const Classified = struct { clause: Clause, row: ClassRow };

/// Read every `CLAUSES.tsv` directly under a fixture directory of `root`.
/// A row is `<clause>\t<kind>\t<evidence>`; `#` starts a comment line. The
/// kind is spelled with hyphens (`non-normative`). A row that names no clause,
/// names an unknown kind, carries no evidence, or claims `no-prohibition` for
/// a clause no positive fixture cites is REJECTED: printed, not counted, and it
/// fails the run the way an unresolved cite does.
fn readClassifications(
    arena: std.mem.Allocator,
    io: Io,
    root: []const u8,
    clauses: *const std.StringHashMapUnmanaged(Clause),
    cited: anytype,
    w: *Io.Writer,
) !struct { map: std.StringHashMapUnmanaged(ClassRow), bad: usize } {
    var map: std.StringHashMapUnmanaged(ClassRow) = .empty;
    var bad: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .map = map, .bad = 0 },
        else => return err,
    };
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.eql(u8, e.basename, "CLAUSES.tsv")) continue;
        // Numbered in IEEE 1364-2005, not this LRM: `tests/ieee1364.zig` reads it.
        if (std.mem.startsWith(u8, e.path, "ieee1364" ++ std.fs.path.sep_str)) continue;
        try files.append(arena, try std.fs.path.join(arena, &.{ root, e.path }));
    }
    std.mem.sort([]const u8, files.items, {}, strLess);
    for (files.items) |path| {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0 or line[0] == '#') continue;
            const why = classifyRow(arena, line, clauses, cited) catch |err| {
                try w.print("BAD CLASSIFICATION — {s}:{d}: {s}\n", .{ path, line_no, @errorName(err) });
                bad += 1;
                continue;
            };
            const g = try map.getOrPut(arena, why.id);
            if (!g.found_existing) g.value_ptr.* = .{ .kind = why.kind, .file = path };
        }
    }
    return .{ .map = map, .bad = bad };
}

fn classifyRow(
    arena: std.mem.Allocator,
    line: []const u8,
    clauses: *const std.StringHashMapUnmanaged(Clause),
    cited: anytype,
) !struct { id: []const u8, kind: ClassKind } {
    var cols = std.mem.splitScalar(u8, line, '\t');
    var id = std.mem.trim(u8, cols.next() orelse return error.MissingClause, " ");
    if (id.len != 0 and std.mem.startsWith(u8, id, "§")) id = id["§".len..];
    if (clauses.get(id) == null) return error.UnknownClause;
    const kind_text = std.mem.trim(u8, cols.next() orelse return error.MissingKind, " ");
    const spelled = try arena.dupe(u8, kind_text);
    std.mem.replaceScalar(u8, spelled, '-', '_');
    const kind = std.meta.stringToEnum(ClassKind, spelled) orelse return error.UnknownKind;
    if (kind == .not_supported) return error.NotSupportedIsIeee1364Only;
    const evidence = std.mem.trim(u8, cols.rest(), " \t");
    if (evidence.len == 0) return error.MissingEvidence;
    if (kind == .no_prohibition) {
        const s = cited.get(id) orelse return error.NoPositiveFixture;
        if (!s.pos) return error.NoPositiveFixture;
    }
    return .{ .id = id, .kind = kind };
}

/// One `//! lrm` citation and the polarity its fixture declares.
const Cite = struct {
    section: []const u8,
    path: []const u8,
    side: enum { pos, neg, compiled },
};

/// The `.c` VPI fixtures under `root`. `collect` does not walk them: they are
/// C applications, not VerA source, and only `--coverage` reads them.
fn cFixtures(arena: std.mem.Allocator, io: Io, root: []const u8, filter: ?[]const u8) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".c")) continue;
        const path = try std.fs.path.join(arena, &.{ root, e.path });
        if (filter) |f| if (std.mem.indexOf(u8, path, f) == null) continue;
        try list.append(arena, path);
    }
    return list.items;
}

/// Does `build.zig` RUN this `.c` fixture in-process and assert its output?
/// `options.vpi_runs` is that file's own `vpi_runs` table, not a copy of it.
fn cFixtureRuns(path: []const u8) bool {
    for (options.vpi_runs) |r| {
        if (std.mem.endsWith(u8, path, r)) return true;
    }
    return false;
}

/// A `.c` fixture's tags: the `.va` grammar, one per line, as C99 `//`
/// comments. Polarity is PER LINE, because one C application can both assert
/// a routine's result and assert that the routine refuses invalid input:
///
///   //! lrm 12.16          a result this clause requires is asserted
///   //! lrm-reject 12.34   a refusal (error return, vpi_chk_error) is asserted
///
/// Neither counts unless the fixture runs (`runs`): a compile-only fixture's
/// cites become `.compiled`, listed and never counted. `inherited` and
/// `inherited-reject` cite IEEE 1364-2005 and are `tests/ieee1364.zig`'s, so
/// they are skipped here. Any other `//!` key is a malformed tag, reported
/// rather than skipped.
fn cCites(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Cite),
    path: []const u8,
    source: []const u8,
    runs: bool,
) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var words = std.mem.tokenizeAny(u8, line["//!".len..], " \t");
        const key = words.next() orelse return error.BadCTag;
        if (std.mem.eql(u8, key, "inherited") or std.mem.eql(u8, key, "inherited-reject")) continue;
        const reject = if (std.mem.eql(u8, key, "lrm"))
            false
        else if (std.mem.eql(u8, key, "lrm-reject"))
            true
        else
            return error.BadCTag;
        const section = words.next() orelse return error.BadCTag;
        if (words.next() != null) return error.BadCTag;
        // A sentence cite is the ledger's, as in `report`.
        if (std.mem.indexOfScalar(u8, section, ':') != null) continue;
        try out.append(arena, .{
            .section = section,
            .path = path,
            .side = if (!runs) .compiled else if (reject) .neg else .pos,
        });
    }
}

test "a .c fixture's polarity is per line, and only a running one counts" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "/* 12.34 in prose is not a tag */\n//! lrm 12.6\n  //! lrm-reject 12.34\n" ++
        "//! inherited IEEE 1364-2005 27.14\n//! inherited-reject IEEE 1364-2005 27.14\n" ++
        "//! lrm 12.16:3\nint x;\n"; // a sentence cite is the ledger's, not counted here
    var cites: std.ArrayList(Cite) = .empty;
    try cCites(arena, &cites, "a.c", src, true);
    try std.testing.expectEqual(@as(usize, 2), cites.items.len);
    try std.testing.expectEqualStrings("12.6", cites.items[0].section);
    try std.testing.expect(cites.items[0].side == .pos);
    try std.testing.expect(cites.items[1].side == .neg);
    cites.clearRetainingCapacity();
    try cCites(arena, &cites, "a.c", src, false);
    for (cites.items) |c| try std.testing.expect(c.side == .compiled);
    try std.testing.expectError(error.BadCTag, cCites(arena, &cites, "a.c", "//! reject E0512\n", true));
    try std.testing.expectError(error.BadCTag, cCites(arena, &cites, "a.c", "//! lrm\n", true));
}

/// One numbered clause of the LRM, as `specification/*.html` spells it.
pub const Clause = struct {
    /// `4.2.1`, `A.8.3`, `B` — the spelling a `//! lrm` line uses.
    id: []const u8,
    /// `Operators with real operands`.
    title: []const u8,
    /// `ch4-expressions.html`.
    file: []const u8,
};

/// The LRM's table of contents, read out of `specification/*.html` at run time.
///
/// Headings are recovered from the rendered text, not `id=` anchors: the
/// chapters disagree on markup and the anchors are incomplete, while text finds
/// every clause the anchors do.
fn lrmClauses(
    arena: std.mem.Allocator,
    io: Io,
    docs_root: []const u8,
) !std.StringHashMapUnmanaged(Clause) {
    var out: std.StringHashMapUnmanaged(Clause) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, docs_root, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.basename, ".html")) continue;
        // The frameset, not a chapter: every number on it is a link to one.
        if (std.mem.eql(u8, e.basename, "index.html")) continue;
        try names.append(arena, try arena.dupe(u8, e.path));
    }
    // `walk` order is explicitly undefined and first-wins below, so a clause
    // number occurring in two files would otherwise be attributed at random.
    std.mem.sort([]const u8, names.items, {}, strLess);

    for (names.items) |name| {
        const prefix = clausePrefix(std.fs.path.basename(name)) orelse continue;
        const html = try dir.readFileAlloc(io, name, arena, .limited(4 << 20));
        const text = try renderText(arena, html);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const h = splitHeading(std.mem.trim(u8, raw, " \t\r")) orelse continue;
            if (!underPrefix(h.id, prefix)) continue;
            // First wins: a heading is declared once and cross-referenced many
            // times, and the declaration comes first in a chapter's own file.
            const g = try out.getOrPut(arena, h.id);
            if (!g.found_existing) g.value_ptr.* = .{ .id = h.id, .title = h.title, .file = name };
        }
    }
    return out;
}

/// Which chapter or annex a file declares: `ch9-system.html` -> `9`,
/// `annex-a-syntax.html` -> `A`. Null for a file that declares neither.
///
/// A heading declares a clause of its own file; requiring that rejects
/// cross-references that open a paragraph (ch9 cites IEEE 1364 §17.9.3; Annex
/// G's change tables list ch7 subclauses).
fn clausePrefix(basename: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, basename, "ch")) {
        const dash = std.mem.indexOfScalar(u8, basename, '-') orelse return null;
        const n = basename[2..dash];
        if (n.len == 0 or n.len > 2) return null;
        for (n) |c| if (!std.ascii.isDigit(c)) return null;
        return n;
    }
    if (std.mem.startsWith(u8, basename, "annex-") and basename.len > 6) {
        const letter = std.ascii.toUpper(basename[6]);
        if (letter < 'A' or letter > 'H') return null;
        if (basename[7] != '-') return null;
        // Uppercased, so the slice cannot be into `basename`: it is into a
        // static table instead of an allocation.
        return "ABCDEFGH"[letter - 'A' ..][0..1];
    }
    return null;
}

/// Is `id` the clause `prefix` names, or one beneath it? `1` covers `1.3.1` and
/// NOT `10.2`, which is why this is not `startsWith` on its own.
fn underPrefix(id: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, id, prefix)) return true;
    return id.len > prefix.len and
        std.mem.startsWith(u8, id, prefix) and
        id[prefix.len] == '.';
}

/// Split a rendered line into a clause number and its title, or null.
///
///     `4.2.1 Operators with real operands`  -> { "4.2.1", "Operators with…" }
///     `A.8.3 Expressions`                   -> { "A.8.3", "Expressions" }
///     `Annex B (normative) List of keywords`-> { "B", "(normative) List of…" }
///
/// A NUMERIC id needs at least two components. Chapter 2 prints sized literals
/// one per line — `32 'h 12ab_f001`, `8 'd -6  // this is illegal syntax` — and
/// every one of them is a heading under a looser rule. An annex LETTER may
/// stand alone: Annex B and Annex H have no numbered subclauses at all, and
/// fixtures cite them as `B` and `H`.
///
/// The title is not inspected beyond being non-empty, deliberately. Requiring a
/// capital drops §5.10.3.1 `cross function`, and every rule that guesses at
/// prose costs a real clause to buy a false one.
fn splitHeading(line: []const u8) ?struct { id: []const u8, title: []const u8 } {
    // `Annex B (normative) List of keywords`. Annexes B and H have no numbered
    // subclauses at all and fixtures cite them by bare letter, so the annex
    // title itself has to be a clause.
    //
    // The `(` is load-bearing, not decoration: every annex title carries its
    // normative status in parentheses, and without requiring it the rule also
    // matches Annex C's PROSE — "Annex E defines the SPICE compatibility for
    // both …" opens a paragraph, and a paragraph starts a line here because
    // every tag renders as one.
    const annex = "Annex ";
    if (std.mem.startsWith(u8, line, annex) and line.len > annex.len + 2) {
        const letter = line[annex.len];
        const rest = std.mem.trim(u8, line[annex.len + 1 ..], " \t");
        if (letter >= 'A' and letter <= 'H' and line[annex.len + 1] == ' ' and
            rest.len != 0 and rest[0] == '(') return .{
            .id = line[annex.len .. annex.len + 1],
            .title = rest,
        };
    }
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return null;
    const title = std.mem.trim(u8, line[sp..], " \t");
    if (title.len < 3) return null;
    if (!isClauseId(line[0..sp])) return null;
    return .{ .id = line[0..sp], .title = title };
}

fn isClauseId(id: []const u8) bool {
    var parts = std.mem.splitScalar(u8, id, '.');
    const first = parts.next().?;
    const lettered = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!lettered) {
        if (first.len == 0 or first.len > 2 or first[0] == '0') return false;
        for (first) |c| if (!std.ascii.isDigit(c)) return false;
    }
    var components: usize = 1;
    while (parts.next()) |p| {
        // No component is zero or zero-padded, which is what separates a clause
        // number from a row of a numeric table: ch9 prints `1.0   1.0   1.5`.
        if (p.len == 0 or p[0] == '0') return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
        components += 1;
    }
    return lettered or components >= 2;
}

/// Render HTML to text well enough to find a heading on a line of its own.
///
/// Every tag becomes a NEWLINE rather than nothing, so `<h3 id="…">4.2.1 Foo</h3>`
/// lands as its own line instead of being glued to the paragraph before it —
/// which is what makes the leading-`4.2.1` test mean "this line IS the heading"
/// rather than "this line mentions §4.2.1", and is why a cross-reference
/// ("see the discussion in 4.5.15") does not become a clause.
fn renderText(arena: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, html.len);
    var i: usize = 0;
    while (i < html.len) {
        switch (html[i]) {
            '<' => {
                i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len - 1) + 1;
                out.appendAssumeCapacity('\n');
            },
            '&' => {
                const end = std.mem.indexOfScalarPos(u8, html, i, ';') orelse {
                    out.appendAssumeCapacity(html[i]);
                    i += 1;
                    continue;
                };
                // A heading's separator is the whole reason this is here: the
                // annexes write `A.8.3&nbsp;Expressions`, and left as bytes
                // that is one token with no space in it.
                const name = html[i + 1 .. end];
                // Anything not listed keeps its `&` and is walked as text: the
                // only job here is that a heading's number and its title end up
                // separated by something `indexOfAny(" \t")` can find.
                if (entities.get(name)) |repl| {
                    out.appendSliceAssumeCapacity(repl);
                    i = end + 1;
                } else {
                    out.appendAssumeCapacity('&');
                    i += 1;
                }
            },
            // U+00A0 as UTF-8. Same job as `&nbsp;` and the same chapters use
            // both.
            0xC2 => {
                if (i + 1 < html.len and html[i + 1] == 0xA0) {
                    out.appendAssumeCapacity(' ');
                    i += 2;
                } else {
                    out.appendAssumeCapacity(html[i]);
                    i += 1;
                }
            },
            else => {
                out.appendAssumeCapacity(html[i]);
                i += 1;
            },
        }
    }
    return out.items;
}

const entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "nbsp", " " },  .{ "#160", " " }, .{ "amp", "&" },
    .{ "lt", "<" },    .{ "gt", ">" },   .{ "quot", "\"" },
    .{ "apos", "'" },  .{ "#39", "'" },  .{ "mdash", "-" },
    .{ "ndash", "-" },
});

/// Order cites the way the LRM's contents page does: numerically per component,
/// so §10 follows §9 instead of §1, and chapters come before annexes.
fn sectionLessThan(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = ia.next() orelse return ib.next() != null; // a prefix sorts first
        const pb = ib.next() orelse return false;
        if (std.mem.eql(u8, pa, pb)) continue;
        const na = std.fmt.parseInt(u32, pa, 10) catch null;
        const nb = std.fmt.parseInt(u32, pb, 10) catch null;
        if (na != null and nb != null) return na.? < nb.?;
        if (na != null) return true;
        if (nb != null) return false;
        return std.mem.lessThan(u8, pa, pb);
    }
}

test "lrm cites sort like a contents page, not like strings" {
    try std.testing.expect(sectionLessThan("9.4", "10.1")); // not lexicographic
    try std.testing.expect(!sectionLessThan("10.1", "9.4"));
    try std.testing.expect(sectionLessThan("4.5", "4.5.11"));
    try std.testing.expect(sectionLessThan("4.5.2", "4.5.11"));
    try std.testing.expect(sectionLessThan("12", "A.1")); // chapters before annexes
    try std.testing.expect(sectionLessThan("A.1.2", "B"));
    try std.testing.expect(!sectionLessThan("5.8", "5.8"));
}

test "a heading is a clause; a cross-reference is not" {
    // The shapes the chapters actually use.
    try std.testing.expectEqualStrings("4.2.1", splitHeading("4.2.1 Operators with real operands").?.id);
    try std.testing.expectEqualStrings("Operators with real operands", splitHeading("4.2.1 Operators with real operands").?.title);
    try std.testing.expectEqualStrings("A.8.3", splitHeading("A.8.3 Expressions").?.id);
    // §5.10.3.1 is `cross function`, lowercase. Requiring a capital would drop it.
    try std.testing.expectEqualStrings("5.10.3.1", splitHeading("5.10.3.1 cross function").?.id);
    // Annexes B and H have no numbered subclauses, so the annex title is the clause.
    try std.testing.expectEqualStrings("B", splitHeading("Annex B (normative) List of keywords").?.id);
    // …and Annex C's PROSE opens the same way. The parenthesis is the difference.
    try std.testing.expect(splitHeading("Annex E defines the SPICE compatibility for both.") == null);

    // A chapter-2 sized literal is not clause 32, and a numeric table row is
    // not clause 1.0.
    try std.testing.expect(splitHeading("32 'h 12ab_f001") == null);
    try std.testing.expect(splitHeading("1.0   1.0   1.5") == null);
    // A bare chapter number is covered by its subclauses, and `9.` is not a clause.
    try std.testing.expect(splitHeading("9. System tasks and functions") == null);

    // A heading declares a clause of its own file. `17.9.3` is a clause of IEEE
    // 1364, quoted in chapter 9; `7.10.5` is a row of an Annex G change table.
    try std.testing.expectEqualStrings("9", clausePrefix("ch9-system.html").?);
    try std.testing.expectEqualStrings("A", clausePrefix("annex-a-syntax.html").?);
    try std.testing.expect(clausePrefix("index.html") == null);
    try std.testing.expect(!underPrefix("17.9.3", "9"));
    try std.testing.expect(!underPrefix("7.10.5", "G"));
    try std.testing.expect(underPrefix("1.3.1", "1"));
    try std.testing.expect(!underPrefix("10.2", "1")); // not a prefix match on digits
}

test "html renders to text a heading can be found in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every tag becomes a newline, so a heading is on a line of its own even
    // when it is glued to the paragraph before it in the source.
    const t = try renderText(arena, "<p>text</p><h3 id=\"s4-2-1\">4.2.1 Foo</h3>");
    var found = false;
    var lines = std.mem.splitScalar(u8, t, '\n');
    while (lines.next()) |l| {
        const h = splitHeading(std.mem.trim(u8, l, " \t\r")) orelse continue;
        try std.testing.expectEqualStrings("4.2.1", h.id);
        found = true;
    }
    try std.testing.expect(found);

    // The annexes separate a number from its title with `&nbsp;`, which left as
    // bytes is one token with no space in it.
    const nb = try renderText(arena, "A.8.3&nbsp;Expressions");
    try std.testing.expectEqualStrings("A.8.3", splitHeading(nb).?.id);
    // …and with a raw U+00A0, in the same document.
    const raw = try renderText(arena, "A.8.3\u{00a0}Expressions");
    try std.testing.expectEqualStrings("A.8.3", splitHeading(raw).?.id);
    // An entity this does not know keeps its `&` and stays text.
    try std.testing.expectEqualStrings("a&circ;b", try renderText(arena, "a&circ;b"));
}

test "the LRM's contents page is readable, and is the one in docs/" {
    // The guard that matters: a markup change in `docs/` that silently emptied
    // the table would turn `--coverage` into "everything is covered" — the
    // exact false green the whole report exists to prevent.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reads twenty files and nothing else, so the single-threaded `Io` the rest
    // of the tree reaches for in the same situation is enough here too.
    const io = Io.Threaded.global_single_threaded.io();

    var clauses = try lrmClauses(arena, io, options.docs_root);
    // A floor, not the count: the count is what `--coverage` prints and it must
    // be free to move as `docs/` is corrected. 500 is far below the 611 this
    // tree finds and far above what any partial parse would leave.
    try std.testing.expect(clauses.count() > 500);
    try std.testing.expectEqualStrings(
        "Operators with real operands",
        clauses.get("4.2.1").?.title,
    );
    // Chapter 5 carries its headings as bare lines and has three `id=` anchors
    // in the whole file, which is why this reads text and not anchors.
    try std.testing.expectEqualStrings("cross function", clauses.get("5.10.3.1").?.title);
    // A clause of IEEE 1364 quoted in chapter 9 is not a clause of this LRM.
    try std.testing.expect(clauses.get("17.9.3") == null);
}
