//! Every stage boundary is handled EXHAUSTIVELY, or says why it is not.
//!
//! Each stage of the pipeline (tokens → AST → MIR → device) drops what the next
//! does not need. A `switch` over the previous stage's enum is where that choice
//! is made, and `else =>` is where it is made silently: a variant added to
//! `Ast.ExprTag` tomorrow compiles straight into every `else` that already
//! exists, and nothing asks whether that walker should have seen it. The audit
//! that motivated this found a dozen such arms giving wrong answers today.
//!
//! Zig already errors on a non-exhaustive switch WITHOUT `else`. This test
//! closes the other half: a switch whose enum-literal prongs all name one
//! BOUNDARY enum may not carry `else =>` unless the else line says
//! `// else: <reason>`. It reads the real source with `std.zig.Ast`, because
//! grep cannot tell which enum a switch is over and a label-set match can.
//!
//! RATCHET. The sites that existed when this landed are in `exhaustive.list`,
//! keyed by (file, enclosing function, enum) and never by line, so a file split
//! does not churn it. The test fails on a site that is NOT listed, and on a
//! listed site that is gone. The list can only shrink. Names, not counts
//! (AGENTS.md rule 3): a count can stand still while the membership moves.

const std = @import("std");
const Io = std.Io;
const ZigAst = std.zig.Ast;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const op = @import("ir").op;
const repo_root = @import("repo_options").repo_root;

/// The boundary enums, read from the real types so the registry cannot drift.
/// A switch is attributed to the FIRST entry whose fields cover all its prong
/// labels. `token.Tag` is deliberately absent: its `else` arms are the grammar's
/// loud "not this production", and its real losses are token-skipping loops
/// this rule would not see anyway.
const registry = [_]struct { name: []const u8, fields: []const []const u8 }{
    .{ .name = "Ast.ExprTag", .fields = std.meta.fieldNames(Ast.ExprTag) },
    .{ .name = "Ast.Stmt", .fields = std.meta.fieldNames(Ast.Stmt) },
    .{ .name = "Ast.BinaryOp", .fields = std.meta.fieldNames(Ast.BinaryOp) },
    .{ .name = "Ast.UnaryOp", .fields = std.meta.fieldNames(Ast.UnaryOp) },
    .{ .name = "Ast.NetKind", .fields = std.meta.fieldNames(Ast.NetKind) },
    .{ .name = "Ast.GateKind", .fields = std.meta.fieldNames(Ast.GateKind) },
    .{ .name = "Ast.Direction", .fields = std.meta.fieldNames(Ast.Direction) },
    .{ .name = "Ast.Type", .fields = std.meta.fieldNames(Ast.Type) },
    .{ .name = "Mir.Opcode", .fields = std.meta.fieldNames(Mir.Opcode) },
    .{ .name = "Mir.OpClass", .fields = std.meta.fieldNames(Mir.OpClass) },
    .{ .name = "Mir.DefKind", .fields = std.meta.fieldNames(Mir.DefKind) },
    .{ .name = "op.OpKind", .fields = std.meta.fieldNames(op.OpKind) },
    // Last: its `ddt`/`cross`/… overlap OpKind, which keeps those switches.
    .{ .name = "Mir.Callee", .fields = std.meta.fieldNames(Mir.Callee) },
};

const listed = @embedFile("exhaustive.list");

fn has(fields: []const []const u8, s: []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f, s)) return true;
    return false;
}

const Site = struct { key: []const u8, where: []const u8 };

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every unannotated `else` on a boundary enum in one file, outside `test`
/// blocks, as `path fn enum` keys.
fn scan(arena: std.mem.Allocator, path: []const u8, src: [:0]const u8, out: *std.ArrayList(Site)) !void {
    var tree = try ZigAst.parse(arena, src, .zig);
    if (tree.errors.len != 0) {
        std.debug.print("{s}: does not parse\n", .{path});
        return error.ParseFailed;
    }
    // Enclosing scopes as token spans; the innermost fn names the site.
    const Span = struct { first: u32, last: u32, name: ?[]const u8 };
    var spans: std.ArrayList(Span) = .empty;
    for (0..tree.nodes.len) |i| {
        const n: ZigAst.Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(n)) {
            .fn_decl => {
                var buf: [1]ZigAst.Node.Index = undefined;
                const tok = tree.fullFnProto(&buf, n).?.name_token orelse continue;
                try spans.append(arena, .{ .first = tree.firstToken(n), .last = tree.lastToken(n), .name = tree.tokenSlice(tok) });
            },
            .test_decl => try spans.append(arena, .{ .first = tree.firstToken(n), .last = tree.lastToken(n), .name = null }),
            else => {}, // else: only fn and test scopes name a site
        }
    }
    for (0..tree.nodes.len) |i| {
        const sw = tree.fullSwitch(@enumFromInt(i)) orelse continue;
        var else_tok: ?ZigAst.TokenIndex = null;
        var labels: std.ArrayList([]const u8) = .empty;
        for (sw.ast.cases) |c| {
            const case = tree.fullSwitchCase(c).?;
            if (case.ast.values.len == 0) else_tok = case.ast.arrow_token;
            for (case.ast.values) |v| if (tree.nodeTag(v) == .enum_literal)
                try labels.append(arena, tree.tokenSlice(tree.nodeMainToken(v)));
        }
        const et = else_tok orelse continue;
        if (labels.items.len == 0) continue;
        const hit = for (registry) |r| {
            const all = for (labels.items) |l| {
                if (!has(r.fields, l)) break false;
            } else true;
            if (all) break r.name;
        } else continue;
        const loc = tree.tokenLocation(0, et);
        if (std.mem.indexOf(u8, src[loc.line_start..loc.line_end], "// else:") != null) continue;

        var in_test = false;
        var best: ?Span = null;
        for (spans.items) |s| {
            if (et < s.first or et > s.last) continue;
            if (s.name == null) in_test = true;
            if (s.name != null and (best == null or s.last - s.first < best.?.last - best.?.first)) best = s;
        }
        if (in_test) continue;
        const fn_name = if (best) |b| b.name.? else "-";
        try out.append(arena, .{
            .key = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ path, fn_name, hit }),
            .where = try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, loc.line + 1 }),
        });
    }
}

test "every `else` over a boundary enum is written out, annotated, or listed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var found: std.ArrayList(Site) = .empty;
    for ([_][]const u8{ "lib", "src" }) |sub| {
        const abs = try std.fs.path.join(arena, &.{ repo_root, sub });
        var dir = try Io.Dir.cwd().openDir(io, abs, .{ .iterate = true });
        defer dir.close(io);
        var w = try dir.walk(arena);
        while (try w.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
            const src = try dir.readFileAllocOptions(io, e.path, arena, .limited(1 << 24), .of(u8), 0);
            try scan(arena, try std.fs.path.join(arena, &.{ sub, e.path }), src, &found);
        }
    }
    std.mem.sort(Site, found.items, {}, struct {
        fn lt(_: void, a: Site, b: Site) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);

    var want: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |l| if (!std.mem.startsWith(u8, l, "//")) try want.append(arena, l);
    std.mem.sort([]const u8, want.items, {}, lessThan);

    // Multiset difference over two sorted lists.
    var new: usize = 0;
    var stale: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < found.items.len or j < want.items.len) {
        const ord: std.math.Order = if (i == found.items.len) .gt else if (j == want.items.len) .lt else std.mem.order(u8, found.items[i].key, want.items[j]);
        switch (ord) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                std.debug.print(
                    "{s}: NEW `else =>` over {s}\n    key: {s}\n    fix: write the prongs out so the compiler checks them, " ++
                        "or put `// else: <reason>` on the else line\n",
                    .{ found.items[i].where, found.items[i].key[std.mem.lastIndexOfScalar(u8, found.items[i].key, ' ').? + 1 ..], found.items[i].key },
                );
                new += 1;
                i += 1;
            },
            .gt => {
                std.debug.print(
                    "tests/exhaustive.list: STALE entry `{s}`: that site no longer has an unannotated `else`\n" ++
                        "    fix: delete this line from tests/exhaustive.list (the ratchet only shrinks)\n",
                    .{want.items[j]},
                );
                stale += 1;
                j += 1;
            },
        }
    }
    if (new + stale != 0) {
        std.debug.print("exhaustive guard: {d} new, {d} stale ({d} found, {d} listed)\n", .{ new, stale, found.items.len, want.items.len });
        return error.ExhaustiveGuard;
    }
}
