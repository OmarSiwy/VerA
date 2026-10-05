//! Every diagnostic's `.lrm` citation against the clauses that exist: the
//! headings of `specification/*.html` (the Verilog-AMS LRM 2023) and the rows of
//! `tests/fixtures/ieee1364/CLAUSES.tsv` (IEEE 1364-2005, whose PDF is not in
//! git), both read at test time from `repo_options.repo_root` as
//! `exhaustive.zig` reads source. In: `diag.info(c).lrm` for every code. Out:
//! pass, or one line per citation that names no clause.
//!
//! No LRM clause: this checks VerA's own catalogue (#68). E0501 cited a
//! §3.6.1.4 the 2023 LRM does not have (#62); its §3.6.1 has subclauses 1-3.

const std = @import("std");
const Io = std.Io;
const diag = @import("diag");
const repo_root = @import("repo_options").repo_root;

const Clauses = std.StringHashMapUnmanaged(void);

/// `1`, `3.6.1.2`, `A`, `A.1.2`: a number or annex letter, then `.number`s.
fn isClause(s: []const u8) bool {
    if (s.len == 0) return false;
    var parts = std.mem.splitScalar(u8, s, '.');
    const first = parts.first();
    const annex = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!annex and !allDigits(first)) return false;
    while (parts.next()) |p| if (!allDigits(p)) return false;
    return true;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Adds the clause number that opens each `<h1>`..`<h6>`: "3.6.1.2 Attributes",
/// "10. Compiler directives", "Annex A (normative) ...". Keys borrow `html`.
fn addHeadings(gpa: std.mem.Allocator, set: *Clauses, html: []const u8) !void {
    var i: usize = 0;
    while (std.mem.findPos(u8, html, i, "<h")) |at| {
        i = at + 2;
        if (i >= html.len or html[i] < '1' or html[i] > '6') continue;
        const gt = std.mem.findScalarPos(u8, html, i, '>') orelse return;
        var text = html[gt + 1 ..];
        text = text[0 .. std.mem.findScalar(u8, text, '<') orelse text.len];
        if (std.mem.startsWith(u8, text, "Annex ")) text = text["Annex ".len..];
        var tok = text[0 .. std.mem.findScalar(u8, text, ' ') orelse text.len];
        if (std.mem.endsWith(u8, tok, ".")) tok = tok[0 .. tok.len - 1];
        if (isClause(tok)) try set.put(gpa, tok, {});
    }
}

test "every diagnostic cites a clause that exists" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const root = try Io.Dir.cwd().openDir(io, repo_root, .{});
    defer root.close(io);
    var lrm: Clauses = .empty;
    var spec = try root.openDir(io, "specification", .{ .iterate = true });
    defer spec.close(io);
    var it = spec.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".html")) continue;
        try addHeadings(arena, &lrm, try spec.readFileAlloc(io, e.name, arena, .limited(1 << 24)));
    }
    // The heading reader found a deep clause and an annex subclause, so a
    // miss below is the citation's, not the reader's.
    try std.testing.expect(lrm.contains("3.6.1.2") and lrm.contains("A.1.2"));

    var ieee: Clauses = .empty;
    const tsv = try root.readFileAlloc(io, "tests/fixtures/ieee1364/CLAUSES.tsv", arena, .limited(1 << 24));
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        try ieee.put(arena, line[0 .. std.mem.findScalar(u8, line, '\t') orelse line.len], {});
    }

    var missing: usize = 0;
    for (0..@typeInfo(diag.Code).@"enum".field_names.len) |i| {
        const c: diag.Code = @fromBackingInt(@intCast(i));
        const cite = diag.info(c).lrm;
        if (cite.len == 0) continue;
        // `6.3.3 / 3.4.7`: one rule stated in two places.
        var parts = std.mem.splitSequence(u8, cite, " / ");
        while (parts.next()) |p| {
            const ok = if (std.mem.startsWith(u8, p, "IEEE 1364-2005 "))
                ieee.contains(p["IEEE 1364-2005 ".len..])
            else
                lrm.contains(p);
            if (ok) continue;
            std.debug.print("{t} cites `{s}`, which is no clause heading\n", .{ c, p });
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}
