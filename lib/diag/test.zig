//! Diagnostic self-checks.
//!
//! Run on std.testing.allocator.
//!
//! Cut verbatim from `diag.zig`.

const std = @import("std");
const diag = @import("../diag.zig");
const diag_bag = @import("bag.zig");
const diag_entry = @import("entry.zig");
const diag_location = @import("location.zig");
const diag_render = @import("render.zig");
const Severity = diag.Severity;
const Level = diag.Level;
const Levels = diag.Levels;

test "edit distance and suggestion" {
    try std.testing.expectEqual(@as(usize, 0), diag_bag.editDistance("abc", "abc", 4));
    try std.testing.expectEqual(@as(usize, 1), diag_bag.editDistance("abc", "abd", 4));
    // Transposition is one edit, not two.
    try std.testing.expectEqual(@as(usize, 1), diag_bag.editDistance("abc", "acb", 4));
    try std.testing.expect(diag_bag.editDistance("abc", "zzzzzz", 2) > 2);

    // The `u8` rows, at the widest input `cap` admits: 64 characters against 64
    // different ones is distance 64, the saturating case, and the whole proof a
    // byte holds every cell. One character more and the guard fires first.
    const wide_a = "a" ** 64;
    const wide_b = "b" ** 64;
    try std.testing.expectEqual(@as(usize, 64), diag_bag.editDistance(wide_a, wide_b, 64));
    try std.testing.expectEqual(@as(usize, 0), diag_bag.editDistance(wide_a, wide_a, 64));
    try std.testing.expect(diag_bag.editDistance("a" ** 65, wide_b, 64) > 64);

    const cands = [_][]const u8{ "vds", "vgs", "temp" };
    try std.testing.expectEqualStrings("vds", diag_bag.didYouMean("vdss", &cands).?);
    try std.testing.expect(diag_bag.didYouMean("completely_different", &cands) == null);
}

test "suggestion ties break lexicographically, not by input order" {
    // "vas" is one edit from both. Whichever order the candidates arrive in,
    // the answer must be the same.
    const a = [_][]const u8{ "vbs", "vas_" };
    const b = [_][]const u8{ "vas_", "vbs" };
    try std.testing.expectEqualStrings(diag_bag.didYouMean("vas", &a).?, diag_bag.didYouMean("vas", &b).?);
}

test "lint levels" {
    const gpa = std.testing.allocator;
    var levels: Levels = .empty;
    defer levels.deinit(gpa);

    try std.testing.expectEqual(Level.warn, levels.get(.W0650));
    try std.testing.expectEqual(Level.deny, levels.get(.E0601));

    try levels.set(gpa, .W0650, .allow);
    try std.testing.expectEqual(Level.allow, levels.get(.W0650));

    // An error cannot be allowed away.
    try std.testing.expectError(error.CannotAllowError, levels.set(gpa, .E0601, .allow));

    // forbid is a one-way door.
    try levels.set(gpa, .W0651, .forbid);
    try std.testing.expectError(error.Forbidden, levels.set(gpa, .W0651, .allow));

    try std.testing.expect(try levels.parseFlag(gpa, "deny=W0650"));
    try std.testing.expectEqual(Level.deny, levels.get(.W0650));
    try std.testing.expect(!try levels.parseFlag(gpa, "not-a-flag"));
}

test "bag: dedupe, cap, level promotion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag_bag.Bag.init(arena_state.allocator());

    try bag.add(.lower, .E0313, .{ .start = 10, .end = 13 }, "unknown variable {s}", .{"vd"});
    // Same code, same start ⇒ deduped.
    try bag.add(.lower, .E0313, .{ .start = 10, .end = 13 }, "unknown variable {s}", .{"vd"});
    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqual(@as(u32, 1), bag.deduped);
    try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    try std.testing.expect(bag.failed());

    // A warning does not fail the compilation.
    try bag.add(.proof, .W0650, .{ .start = 20, .end = 24 }, "", .{});
    try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    try std.testing.expectEqual(@as(u32, 1), bag.err_count);

    // ...until it is denied.
    try bag.levels.set(arena_state.allocator(), .W0650, .deny);
    try bag.add(.proof, .W0650, .{ .start = 30, .end = 34 }, "", .{});
    try std.testing.expectEqual(@as(u32, 2), bag.err_count);

    // ...or allowed, in which case it is not collected at all.
    try bag.levels.set(arena_state.allocator(), .W0650, .allow);
    const before = bag.count();
    try bag.add(.proof, .W0650, .{ .start = 40, .end = 44 }, "", .{});
    try std.testing.expectEqual(before, bag.count());
}

test "bag: cap counts what it drops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag_bag.Bag.init(arena_state.allocator());

    for (0..diag_bag.max_entries + 10) |i| {
        try bag.add(.lower, .E0313, .{ .start = @intCast(i * 4), .end = @intCast(i * 4 + 2) }, "x", .{});
    }
    try std.testing.expectEqual(@as(usize, diag_bag.max_entries), bag.count());
    try std.testing.expectEqual(@as(u32, 10), bag.suppressed);
}

test "bag: the flat records survive a round trip, in order, through a sort" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bag = diag_bag.Bag.init(arena_state.allocator());

    // Emitted out of source order, so `sort` has something to do and the
    // handles have to stay valid across it.
    var b = bag.build(.lower, .E0313, .{ .start = 50, .end = 52 });
    b.msg("second", .{});
    b.label(.{ .start = 51, .end = 53 }, "one", .{});
    b.label(.{ .start = 54, .end = 55 }, "two", .{});
    // An EMPTY replacement is a deletion, not "no fix": the two must not
    // collapse, which is the whole reason `String` 0 is reserved.
    b.suggest(.{ .span = .{ .start = 50, .end = 52 }, .replacement = "" }, "drop it", .{});
    b.note("plain", .{});
    try b.emit();

    try bag.add(.parse, .E0207, .{ .start = 10, .end = 12 }, "first", .{});
    bag.sort();

    try std.testing.expectEqualStrings("first", bag.at(0).message);

    const e = bag.at(1);
    try std.testing.expectEqualStrings("second", e.message);
    // No `point` was set: `String` 0 decodes to the empty string.
    try std.testing.expectEqualStrings("", e.point);
    try std.testing.expectEqual(diag_entry.Stage.lower, e.stage);
    try std.testing.expectEqual(Severity.err, e.severity);
    try std.testing.expectEqual(@as(u32, 50), e.span.start);
    try std.testing.expect(e.file == null);

    var lbuf: [diag_entry.max_children]diag_entry.Label = undefined;
    const ls = bag.labels(e, &lbuf);
    try std.testing.expectEqual(@as(usize, 2), ls.len);
    try std.testing.expectEqualStrings("one", ls[0].text);
    try std.testing.expectEqualStrings("two", ls[1].text);
    try std.testing.expectEqual(@as(u32, 55), ls[1].span.end);

    var nbuf: [diag_entry.max_children]diag_entry.Note = undefined;
    const ns = bag.notes(e, &nbuf);
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    try std.testing.expectEqual(diag_entry.Note.Kind.help, ns[0].kind);
    try std.testing.expectEqualStrings("", ns[0].fix.?.replacement);
    try std.testing.expectEqual(@as(u32, 52), ns[0].fix.?.span.end);
    try std.testing.expectEqual(diag_entry.Note.Kind.note, ns[1].kind);
    try std.testing.expect(ns[1].fix == null);
}

test "line index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "aaa\nbbbb\n\nccc";
    const idx = try diag_location.LineIndex.build(arena_state.allocator(), text);

    try std.testing.expectEqual(diag_location.Loc{ .line = 1, .col = 1 }, idx.loc(0));
    try std.testing.expectEqual(diag_location.Loc{ .line = 1, .col = 3 }, idx.loc(2));
    try std.testing.expectEqual(diag_location.Loc{ .line = 2, .col = 1 }, idx.loc(4));
    try std.testing.expectEqual(diag_location.Loc{ .line = 4, .col = 2 }, idx.loc(11));
    try std.testing.expectEqualStrings("bbbb", idx.lineText(text, 2));
    try std.testing.expectEqualStrings("", idx.lineText(text, 3));
    try std.testing.expectEqualStrings("ccc", idx.lineText(text, 4));
}

/// Renders a bag to an arena-owned string. Test helper, and the shape a host
/// that wants the text rather than a writer would use.
pub fn renderToString(bag: *diag_bag.Bag, opts: diag_render.RenderOptions) ![]const u8 {
    // ponytail: the arena owns the result; transfer ownership only if it must outlive it.
    var aw: std.Io.Writer.Allocating = .init(bag.arena);
    try diag_render.render(bag, &aw.writer, opts);
    return aw.writer.buffered();
}

test "render: full diagnostic with label, note, suggestion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module r(a, b);
        \\  parameter real k = 1.0;
        \\  analog I(a, b) <+ V(a, b) / k;
        \\endmodule
        \\
    ;
    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("res.va", src, 0);

    const k_decl = @as(u32, @intCast(std.mem.indexOf(u8, src, "k = 1.0").?));
    const divisor = @as(u32, @intCast(std.mem.lastIndexOfScalar(u8, src, 'k').?));

    var b = bag.build(.proof, .E0601, .{ .start = divisor, .end = divisor + 1 });
    b.msg("divisor is parameter `k`", .{});
    b.point("divisor", .{});
    b.label(.{ .start = k_decl, .end = k_decl + 1 }, "`k` is unconstrained: (-inf, inf)", .{});
    b.suggest(
        .{ .span = diag_location.Span.at(k_decl + 7), .replacement = " from (0:inf)" },
        "constrain the parameter so zero is excluded",
        .{},
    );
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });

    // Headline carries severity, code and the catalogue title.
    try std.testing.expect(std.mem.startsWith(u8, out, "error[E0601]: divisor cannot be proven non-zero: divisor is parameter `k`\n"));
    // Location resolves to the right line and column.
    try std.testing.expect(std.mem.indexOf(u8, out, "--> res.va:3:31\n") != null);
    // Both the primary caret and the secondary label are drawn.
    try std.testing.expect(std.mem.indexOf(u8, out, "^ divisor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- `k` is unconstrained") != null);
    // The LRM citation comes from the code table, not from the message.
    try std.testing.expect(std.mem.indexOf(u8, out, "= note: LRM 4.2.4") != null);
    // The suggestion renders as a patched line plus an insertion ruler.
    try std.testing.expect(std.mem.indexOf(u8, out, "= help: constrain the parameter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "parameter real k = 1.0 from (0:inf);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+++++++++++++") != null);
    // Lines 2 and 3 are adjacent, so nothing is elided.
    try std.testing.expect(std.mem.indexOf(u8, out, "...") == null);
}

test "render: a gap between labelled lines is elided" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\parameter real k = 1.0;
        \\real filler_a;
        \\real filler_b;
        \\analog I(a, b) <+ V(a, b) / k;
        \\
    ;
    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("gap.va", src, 0);
    const k_decl = @as(u32, @intCast(std.mem.indexOf(u8, src, "k = 1.0").?));
    const divisor = @as(u32, @intCast(std.mem.lastIndexOfScalar(u8, src, 'k').?));

    var b = bag.build(.proof, .E0601, .{ .start = divisor, .end = divisor + 1 });
    b.label(.{ .start = k_decl, .end = k_decl + 1 }, "declared here", .{});
    try b.emit();

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Lines 1 and 4 are shown; 2 and 3 collapse to `...`.
    try std.testing.expect(std.mem.indexOf(u8, out, "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "filler_a") == null);
}

test "render: colour is opt-in and structural" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("x.va", "analog begin\n  x = 1;\nend\n", 0);
    try bag.add(.lower, .E0313, .{ .start = 15, .end = 16 }, "no variable `x`", .{});
    try bag.add(.proof, .W0650, .{ .start = 15, .end = 16 }, "", .{});

    const plain = try renderToString(&bag, .{});
    try std.testing.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);

    var bag2 = diag_bag.Bag.init(arena);
    try bag2.setSingleFile("x.va", "analog begin\n  x = 1;\nend\n", 0);
    try bag2.add(.lower, .E0313, .{ .start = 15, .end = 16 }, "no variable `x`", .{});
    try bag2.add(.proof, .W0650, .{ .start = 15, .end = 16 }, "", .{});
    const coloured = try renderToString(&bag2, .{ .palette = .on });

    // Error red and warning yellow are distinct, and both appear.
    try std.testing.expect(std.mem.indexOf(u8, coloured, "\x1b[1;31merror[E0601") == null);
    try std.testing.expect(std.mem.indexOf(u8, coloured, "\x1b[1;31merror[E0313]") != null);
    try std.testing.expect(std.mem.indexOf(u8, coloured, "\x1b[1;33mwarning[W0650]") != null);
    // A warning alone does not fail the compilation.
    try std.testing.expectEqual(@as(u32, 1), bag2.err_count);
    try std.testing.expectEqual(@as(u32, 1), bag2.warn_count);
}

test "render: tabs expand so carets line up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "module m;\n\t\tbadtok\nendmodule\n";
    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("t.va", src, 0);
    const at = @as(u32, @intCast(std.mem.indexOf(u8, src, "badtok").?));
    try bag.add(.parse, .E0207, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Two tabs become eight spaces in the source line AND in the caret row, so
    // the six carets sit under the six characters of `badtok`.
    try std.testing.expect(std.mem.indexOf(u8, out, "|         badtok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "|         ^^^^^^") != null);
    // The reported column is the display column, not the byte column.
    try std.testing.expect(std.mem.indexOf(u8, out, "t.va:2:9") != null);
}

test "render: multi-byte UTF-8 counts codepoints, not bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Eight two-byte µ before the token: sixteen BYTES, eight columns. A
    // byte-counting `displayCol` drew the caret eight columns too far right.
    const src = "µµµµµµµµbadtok\n";
    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("u.va", src, 0);
    const at = @as(u32, @intCast(std.mem.indexOf(u8, src, "badtok").?));
    try bag.add(.parse, .E0207, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    try std.testing.expect(std.mem.indexOf(u8, out, "| µµµµµµµµbadtok") != null);
    // Eight spaces of caret indent — one per µ — exactly as the tab test's
    // eight-space indent above, and the reported column is 9, not 17.
    try std.testing.expect(std.mem.indexOf(u8, out, "|         ^^^^^^") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "u.va:1:9") != null);
}

test "strip marks map span offsets back into the original text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = diag_bag.Bag.init(arena);
    // Original: `abc /* c */ def` — the preprocessor strips to `abc   def`
    // (block comment → one space, `stripComments`) and leaves one mark: from
    // stripped offset 5 on, original = 11 + (stripped − 5). Before the first
    // mark: identity.
    _ = try bag.addFile("m.va", "abc /* c */ def\n");
    bag.setStrippedText(.root, "abc   def\n", &.{.{ .out = 5, .src = 11 }});

    try std.testing.expectEqualStrings("abc   def\n", bag.fileText(.root));
    try std.testing.expectEqualStrings("abc /* c */ def\n", bag.sourceText(.root));
    try std.testing.expectEqual(@as(u32, 0), bag.toSourceOffset(.root, 0)); // 'a'
    try std.testing.expectEqual(@as(u32, 3), bag.toSourceOffset(.root, 3)); // pre-mark space
    try std.testing.expectEqual(@as(u32, 12), bag.toSourceOffset(.root, 6)); // 'd'
    try std.testing.expectEqual(@as(u32, 15), bag.toSourceOffset(.root, 9)); // '\n'
    // A file registered without stripping maps as identity.
    const other = try bag.addFile("p.va", "xyz\n");
    try std.testing.expectEqual(@as(u32, 2), bag.toSourceOffset(other, 2));
    try std.testing.expectEqualStrings("xyz\n", bag.sourceText(other));
}

test "render: json is one object per line and escapes properly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("j.va", "analog x;\n", 0);
    var b = bag.build(.lower, .E0313, .{ .start = 7, .end = 8 });
    b.msg("quote \" and \\ and newline", .{});
    b.help("try `y`", .{});
    try b.emit();

    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    try diag_render.renderJson(&bag, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":\"E0313\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\" and \\\\ and") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"line\":1,\"col\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"help\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

test "render: prelude lines are subtracted from reported line numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two lines of annex-D prelude, then the user's first line.
    const src = "// prelude\n// prelude\nmodule m; endmodule\n";
    var bag = diag_bag.Bag.init(arena);
    try bag.setSingleFile("u.va", src, 2);
    const at = @as(u32, @intCast(std.mem.indexOf(u8, src, "module").?));
    try bag.add(.parse, .E0205, .{ .start = at, .end = at + 6 }, "", .{});

    const out = try renderToString(&bag, .{ .explain_hint = false, .summary = false });
    // Physical line 3, user line 1.
    try std.testing.expect(std.mem.indexOf(u8, out, "u.va:1:1") != null);
}

test "explain prints the catalogue entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena_state.allocator(), &buf);
    try diag_render.explain(.W0650, &aw.writer, .off);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "W0650: unit is not provably finite"));
    try std.testing.expect(std.mem.indexOf(u8, out, "@setFloatMode(.optimized)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--allow=W0650") != null);
}

test "detach survives the compilation arena, and deinit is leak-free" {
    const gpa = std.testing.allocator;
    var bag: diag_bag.Bag = undefined;

    // Everything below is allocated from an arena that dies before we render,
    // which is exactly the failed-compilation shape.
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        bag = diag_bag.Bag.init(arena);
        const src = "module m;\n  analog x = 1;\nendmodule\n";
        try bag.setSingleFile("owned.va", src, 0);

        // Offset 19 is the `x` in `analog x = 1;`.
        var b = bag.build(.lower, .E0313, .{ .start = 19, .end = 20 });
        b.msg("`{s}`", .{"x"});
        b.point("not declared", .{});
        b.label(.{ .start = 12, .end = 18 }, "in this block", .{});
        b.suggest(.{ .span = diag_location.Span.at(12), .replacement = "real x; " }, "declare it", .{});
        try b.emit();

        try bag.detach(gpa);
    }
    defer bag.deinit(gpa);

    // The arena is gone. Rendering must still work off gpa-owned bytes.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = aw.toArrayList();
    try diag_render.render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "error[E0313]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "owned.va:2:10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^ not declared") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- in this block") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "real x; analog x = 1;") != null);
}

test "detach on a clean bag allocates nothing" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    var bag = diag_bag.Bag.init(arena_state.allocator());
    try bag.setSingleFile("clean.va", "module m; endmodule\n", 0);
    try bag.detach(gpa);
    arena_state.deinit();
    defer bag.deinit(gpa);
    try std.testing.expect(bag.isEmpty());
    try std.testing.expect(!bag.failed());
}

test "source map resolves includes and macro expansions" {
    const segs = [_]diag_location.Segment{
        .{ .out_start = 0, .in_start = 0, .file = .root, .kind = .verbatim },
        .{ .out_start = 5, .in_start = 0, .file = @enumFromInt(1), .kind = .verbatim },
        .{ .out_start = 10, .in_start = 5, .file = .root, .kind = .verbatim },
        .{ .out_start = 14, .in_start = 0, .file = .root, .kind = .macro, .parent = 2, .macro = "FOO" },
    };
    const map: diag_location.SourceMap = .{ .segs = &segs };

    const a = map.resolve(2);
    try std.testing.expectEqual(diag_location.FileId.root, a.file);
    try std.testing.expectEqual(@as(u32, 2), a.offset);

    const b = map.resolve(6);
    try std.testing.expectEqual(@as(diag_location.FileId, @enumFromInt(1)), b.file);
    try std.testing.expectEqual(@as(u32, 1), b.offset);

    // Inside an expansion: report the invocation site, not a phantom offset.
    const c = map.resolve(16);
    try std.testing.expectEqual(diag_location.FileId.root, c.file);
    try std.testing.expectEqual(@as(u32, 5), c.offset);
    try std.testing.expectEqualStrings("FOO", segs[c.seg].macro);

    // An empty map is the identity.
    const none: diag_location.SourceMap = .empty;
    try std.testing.expectEqual(@as(u32, 99), none.resolve(99).offset);
}
