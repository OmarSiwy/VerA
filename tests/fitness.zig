//! Fitness test: the `module_specs` rows (`repo_options`) and the lib/ and
//! src/ sources -> a failure for every breach of ARCHITECTURE.md §3's fitness
//! rules R1-R7 that its allowlist does not name.
//!
//! Each allowlist holds today's violations, and each row names the phase that
//! deletes it. A row whose violation is gone fails too, and so does a count
//! that fell below its row, so an allowlist only shrinks: when a phase lands,
//! it deletes or lowers its rows in the same commit. The rules are read from
//! text, like `exhaustive.zig`'s guards: R1 from the rows, R2 from the file
//! `@import` graph (`import_graph.zig`), R3-R7 from production lines, that is
//! outside top-level `test` blocks and `test.zig` files, with `//` comment
//! lines skipped. R5 and R6 also read `\\` lines, the emitted text.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = @import("frontend").Ast;
const repo = @import("repo_options");
const import_graph = @import("import_graph.zig");

/// build.zig's `Role`, which `repo_options` carries as tag names.
const Role = enum { runtime, leaf, compiler, backend, tool };

/// One allowed file and how many sites it holds, and the phase that deletes
/// them (empty for an R7 ceiling, which has no deleting phase).
const Row = struct { path: []const u8, n: u32, phase: []const u8 = "" };

const Count = struct { path: []const u8, n: u32 };

fn openSource(arena: Allocator) !import_graph.Source {
    const io = std.testing.io;
    return .{ .arena = arena, .io = io, .root = try Io.Dir.cwd().openDir(io, repo.repo_root, .{}) };
}

fn isTestDecl(l: []const u8) bool {
    if (!std.mem.startsWith(u8, l, "test ") or l.len == 5) return false;
    const c = l[5];
    return c == '"' or c == '{' or c == '_' or std.ascii.isAlphabetic(c);
}

/// The production lines of `src`: outside top-level `test` blocks (zig fmt
/// closes one with `}` in column 0), comment lines skipped, `\\` text lines
/// kept only when `keep_text`.
fn production(arena: Allocator, src: []const u8, keep_text: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var in_test = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| {
        if (in_test) {
            if (std.mem.eql(u8, l, "}")) in_test = false;
            continue;
        }
        if (isTestDecl(l)) {
            in_test = !std.mem.endsWith(u8, std.mem.trimEnd(u8, l, " \t\r"), "}");
            continue;
        }
        const t = std.mem.trimStart(u8, l, " \t");
        if (std.mem.startsWith(u8, t, "\\\\")) {
            if (keep_text) try out.append(arena, l);
            continue;
        }
        if (std.mem.startsWith(u8, t, "//")) continue;
        try out.append(arena, l);
    }
    return out.items;
}

/// Per file of `files` (`test.zig` files aside), the production lines `rule.hit`
/// accepts; files with none are left out.
fn measure(s: *import_graph.Source, files: []const []const u8, keep_text: bool, rule: anytype) ![]const Count {
    var out: std.ArrayList(Count) = .empty;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, "/test.zig")) continue;
        var n: u32 = 0;
        for (try production(s.arena, try s.text(f), keep_text)) |l| n += @intFromBool(rule.hit(l));
        if (n != 0) try out.append(s.arena, .{ .path = f, .n = n });
    }
    return out.items;
}

/// Every mismatch between `got` and `rows`, printed; returns how many.
fn ratchet(rule: []const u8, got: []const Count, rows: []const Row) usize {
    var bad: usize = 0;
    for (got) |c| {
        for (rows) |r| {
            if (std.mem.eql(u8, r.path, c.path)) break;
        } else {
            std.debug.print("{s}: {s}: {d} new site(s)\n", .{ rule, c.path, c.n });
            bad += 1;
        }
    }
    for (rows) |r| {
        const n = for (got) |c| {
            if (std.mem.eql(u8, r.path, c.path)) break c.n;
        } else 0;
        if (n == r.n) continue;
        bad += 1;
        if (n == 0) {
            std.debug.print("{s}: {s}: no site left: delete its row ({s})\n", .{ rule, r.path, r.phase });
        } else if (n > r.n) {
            std.debug.print("{s}: {s}: {d} sites, its row allows {d}\n", .{ rule, r.path, n, r.n });
        } else {
            std.debug.print("{s}: {s}: {d} sites: lower its row from {d} to {d}\n", .{ rule, r.path, n, r.n, n });
        }
    }
    return bad;
}

fn filesUnder(s: *import_graph.Source) ![]const []const u8 {
    return s.zigFiles(&.{ "lib", "src" }, &.{});
}

fn keepIf(arena: Allocator, files: []const []const u8, comptime pred: fn ([]const u8) bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |f| if (pred(f)) try out.append(arena, f);
    return out.items;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ---------------------------------------------------------------------------
// R1: a runtime row's closure contains no compiler row.
// ---------------------------------------------------------------------------

const r1_allow = [_]struct { from: []const u8, to: []const u8, phase: []const u8 }{
    .{ .from = "sim", .to = "diag", .phase = "B4" },
    .{ .from = "sim", .to = "frontend", .phase = "B4" },
};

test "R1: a runtime row's closure contains no compiler row" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = repo.module_names;
    try std.testing.expectEqual(names.len, repo.module_roles.len);
    try std.testing.expectEqual(names.len, repo.module_imports.len);

    const roles = try a.alloc(Role, names.len);
    for (repo.module_roles, roles) |tag, *r| r.* = std.meta.stringToEnum(Role, tag) orelse return error.UnknownRole;
    var used: [r1_allow.len]bool = @splat(false);
    var bad: usize = 0;
    // A `leaf` imports only std (ARCHITECTURE.md §1).
    for (names, roles, repo.module_imports) |name, role, imports| if (role == .leaf and imports.len != 0) {
        std.debug.print("R1: leaf `{s}` imports `{s}`\n", .{ name, imports });
        bad += 1;
    };
    const in = try a.alloc(bool, names.len);
    var stack: std.ArrayList(usize) = .empty;
    for (names, roles, 0..) |from, role, i| {
        if (role != .runtime) continue;
        @memset(in, false);
        try stack.append(a, i);
        while (stack.pop()) |m| {
            if (in[m]) continue;
            in[m] = true;
            var deps = std.mem.tokenizeScalar(u8, repo.module_imports[m], ' ');
            while (deps.next()) |d| {
                const j = for (names, 0..) |n, k| {
                    if (std.mem.eql(u8, n, d)) break k;
                } else return error.UnknownImport;
                try stack.append(a, j);
            }
        }
        for (names, roles, in) |to, r, reached| {
            if (!reached or r != .compiler) continue;
            for (r1_allow, &used) |row, *u| {
                if (std.mem.eql(u8, row.from, from) and std.mem.eql(u8, row.to, to)) {
                    u.* = true;
                    break;
                }
            } else {
                std.debug.print("R1: runtime `{s}` reaches compiler `{s}`\n", .{ from, to });
                bad += 1;
            }
        }
    }
    for (r1_allow, used) |row, u| if (!u) {
        std.debug.print("R1: `{s}` no longer reaches `{s}`: delete its row ({s})\n", .{ row.from, row.to, row.phase });
        bad += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// R2: backend closures are pairwise disjoint. Until Phase 8 there is one
// `backend` row, so the check is file-level: the closure of lib/backend/tb/**
// reaches no file of codegen (codegen.zig, codegen/**, cg_*.zig). An
// allowlisted edge is cut from the walk.
// ---------------------------------------------------------------------------

// Empty since Phase 8 moved naming.zig to lib/ir/names.zig, whose tests
// build their own fixture.
const r2_allow = [_]struct { from: []const u8, to: []const u8, phase: []const u8 }{};

fn isCodegen(p: []const u8) bool {
    return std.mem.eql(u8, p, "lib/backend/codegen.zig") or
        std.mem.startsWith(u8, p, "lib/backend/codegen/") or
        std.mem.startsWith(u8, p, "lib/backend/cg_");
}

fn indexOf(g: *const import_graph.Graph, path: []const u8) ?u32 {
    for (g.files, 0..) |f, i| if (std.mem.eql(u8, f, path)) return @intCast(i);
    return null;
}

/// The codegen file the tb/ closure reaches with every `r2_allow` edge but
/// `keep` cut, printing the chain that reaches it; null when none is reached.
fn tbReach(a: Allocator, g: *const import_graph.Graph, keep: ?usize, print: bool) !?u32 {
    const none = std.math.maxInt(u32);
    const parent = try a.alloc(u32, g.files.len);
    @memset(parent, none);
    var queue: std.ArrayList(u32) = .empty;
    for (g.files, 0..) |f, i| if (std.mem.startsWith(u8, f, "lib/backend/tb/")) {
        parent[i] = @intCast(i);
        try queue.append(a, @intCast(i));
    };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v = queue.items[head];
        next: for (g.edges[v]) |t| {
            if (parent[t] != none) continue;
            for (r2_allow, 0..) |row, k| {
                if (keep) |kept| if (kept == k) continue;
                if (std.mem.eql(u8, g.files[v], row.from) and std.mem.eql(u8, g.files[t], row.to)) continue :next;
            }
            parent[t] = v;
            if (isCodegen(g.files[t])) {
                if (print) {
                    std.debug.print("R2: lib/backend/tb/ reaches {s}:", .{g.files[t]});
                    var x = t;
                    while (parent[x] != x) : (x = parent[x]) std.debug.print(" <- {s}", .{g.files[parent[x]]});
                    std.debug.print("\n", .{});
                }
                return t;
            }
            try queue.append(a, t);
        }
    }
    return null;
}

test "R2: the testbench closure reaches no codegen file" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try openSource(a);
    defer s.root.close(s.io);
    const g = try import_graph.buildGraph(&s);

    var bad: usize = 0;
    if (try tbReach(a, &g, null, true) != null) bad += 1;
    for (r2_allow, 0..) |row, k| {
        const f = indexOf(&g, row.from);
        const t = indexOf(&g, row.to);
        const has_edge = f != null and t != null and std.mem.findScalar(u32, g.edges[f.?], t.?) != null;
        if (has_edge and try tbReach(a, &g, k, false) != null) continue;
        std.debug.print("R2: {s} -> {s} no longer reaches codegen: delete its row ({s})\n", .{ row.from, row.to, row.phase });
        bad += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// R3: no Ast writes outside lib/frontend. A write is a call to one of the
// Ast's appenders (`exprs.add*`, `addStmt`, `seqBlockMut`, `seedFrom`), or an
// assignment to a `SourceFile` field other than the interner (interning is
// allowed) through a receiver spelled `...file`.
// ---------------------------------------------------------------------------

const r3_rows = [_]Row{
    .{ .path = "lib/elab/elaborate.zig", .n = 1, .phase = "Phase 12" },
    .{ .path = "lib/elab/elaborate/clone.zig", .n = 9, .phase = "Phase 12" },
    .{ .path = "lib/elab/elaborate/fixture.zig", .n = 1, .phase = "Phase 12" },
    .{ .path = "lib/elab/elaborate/insert.zig", .n = 1, .phase = "Phase 12" },
    .{ .path = "lib/elab/elaborate/instance.zig", .n = 2, .phase = "Phase 12" },
    .{ .path = "lib/elab/elaborate/names.zig", .n = 3, .phase = "Phase 12" },
    .{ .path = "lib/elab/hier_param.zig", .n = 1, .phase = "Phase 12" },
    // The lowering test harness's `builtin_modules`.
    .{ .path = "lib/analog/lower.zig", .n = 1, .phase = "Phase 12" },
    // The spine sets the five fields the parser leaves to its caller.
    .{ .path = "lib/root.zig", .n = 5, .phase = "Phase 12" },
    .{ .path = "src/sim/digital/root.zig", .n = 1, .phase = "Phase 12" },
};

const AstWrite = struct {
    const fields = @typeInfo(Ast.SourceFile).@"struct".field_names;
    fn hit(_: AstWrite, l: []const u8) bool {
        for ([_][]const u8{ "exprs.add", ".addStmt(", ".seqBlockMut(", ".seedFrom(" }) |t|
            if (std.mem.find(u8, l, t) != null) return true;
        inline for (fields) |f| {
            if (comptime std.mem.eql(u8, f, "strings")) continue;
            const k = "." ++ f ++ " = ";
            var from: usize = 0;
            while (std.mem.findPos(u8, l, from, k)) |i| : (from = i + 1)
                if (std.mem.endsWith(u8, l[0..i], "file")) return true;
        }
        return false;
    }
};

fn outsideFrontend(p: []const u8) bool {
    return !std.mem.startsWith(u8, p, "lib/frontend/");
}

test "R3: no Ast writes outside lib/frontend" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try openSource(a);
    defer s.root.close(s.io);
    const files = try keepIf(a, try filesUnder(&s), outsideFrontend);
    try std.testing.expectEqual(@as(usize, 0), ratchet("R3", try measure(&s, files, false, AstWrite{}), &r3_rows));
}

// ---------------------------------------------------------------------------
// R4: no `*Lowered` mutated outside lowering (lib/analog/lower.zig, lib/analog/lower/).
// A mutation needs a mutable `*Lowered` across an interface: a `pub`
// declaration line or a struct field typed `*Lowered`. A private helper
// handed its own local (verify.zig's self-test sample) is not one.
// ---------------------------------------------------------------------------

// Empty since Phase 6: `prove.setup.pruneHeld` returns a held-row mask and
// lowering's `dropHeld` applies it.
const r4_rows = [_]Row{};

const LoweredMut = struct {
    fn hit(_: LoweredMut, l: []const u8) bool {
        const i = std.mem.find(u8, l, "*Lowered") orelse return false;
        const e = i + "*Lowered".len;
        if (e < l.len and isWord(l[e])) return false;
        const t = std.mem.trimStart(u8, l, " \t");
        if (std.mem.startsWith(u8, t, "pub ")) return true;
        // A field: `name: *Lowered`.
        if (t.len == 0 or !(std.ascii.isLower(t[0]) or t[0] == '_')) return false;
        var n: usize = 1;
        while (n < t.len and (std.ascii.isLower(t[n]) or std.ascii.isDigit(t[n]) or t[n] == '_')) n += 1;
        return std.mem.startsWith(u8, t[n..], ": *Lowered");
    }
};

fn outsideLowering(p: []const u8) bool {
    return !std.mem.eql(u8, p, "lib/analog/lower.zig") and !std.mem.startsWith(u8, p, "lib/analog/lower/");
}

test "R4: no *Lowered mutated outside lowering" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try openSource(a);
    defer s.root.close(s.io);
    const files = try keepIf(a, try filesUnder(&s), outsideLowering);
    try std.testing.expectEqual(@as(usize, 0), ratchet("R4", try measure(&s, files, false, LoweredMut{}), &r4_rows));
}

// ---------------------------------------------------------------------------
// R5: each of the `__xz`/`__w{d}`/`__1b`/`__held__` literals has one owner:
// the one file whose production lines (emitted text included) spell it,
// lib/ir/names.zig, whose spellers lowering, codegen and the testbench call.
// ---------------------------------------------------------------------------

const r5_owners = [_]struct { lit: []const u8, owner: []const u8 }{
    .{ .lit = "__xz", .owner = "lib/ir/names.zig" },
    .{ .lit = "__w{", .owner = "lib/ir/names.zig" },
    .{ .lit = "__1b", .owner = "lib/ir/names.zig" },
    .{ .lit = "__held__", .owner = "lib/ir/names.zig" },
};

/// Empty since Phase 8 replaced each second speller with a call to the one
/// speller.
const r5_allow = [_]struct { lit: []const u8, path: []const u8, phase: []const u8 }{};

const Spells = struct {
    lit: []const u8,
    fn hit(self: Spells, l: []const u8) bool {
        return std.mem.find(u8, l, self.lit) != null;
    }
};

test "R5: each name-spelling literal has one owner" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try openSource(a);
    defer s.root.close(s.io);
    const files = try filesUnder(&s);
    var bad: usize = 0;
    for (r5_owners) |o| {
        const got = try measure(&s, files, true, Spells{ .lit = o.lit });
        var owner_spells = false;
        for (got) |c| {
            if (std.mem.eql(u8, c.path, o.owner)) {
                owner_spells = true;
                continue;
            }
            for (r5_allow) |r| {
                if (std.mem.eql(u8, r.lit, o.lit) and std.mem.eql(u8, r.path, c.path)) break;
            } else {
                std.debug.print("R5: {s} spells `{s}`, which {s} owns\n", .{ c.path, o.lit, o.owner });
                bad += 1;
            }
        }
        if (!owner_spells) {
            std.debug.print("R5: the owner {s} no longer spells `{s}`: name its new owner\n", .{ o.owner, o.lit });
            bad += 1;
        }
        for (r5_allow) |r| {
            if (!std.mem.eql(u8, r.lit, o.lit)) continue;
            for (got) |c| {
                if (std.mem.eql(u8, r.path, c.path)) break;
            } else {
                std.debug.print("R5: {s} no longer spells `{s}`: delete its row ({s})\n", .{ r.path, r.lit, r.phase });
                bad += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// R6: no emitted `std.debug.print`/`process.exit` in device-emitting files
// (codegen.zig, codegen/**, cg_*.zig, and lib/kernels/*_kernels.zig, whose
// source is device text; the module's other files are host Zig). Matched as `debug.print(` and `process.exit(`, since a kernel names
// `std` through its own alias (`zstd`, `zhs`, ...).
// ---------------------------------------------------------------------------

const r6_rows = [_]Row{
    .{ .path = "lib/backend/cg_display.zig", .n = 3, .phase = "B2" },
    .{ .path = "lib/backend/codegen/kernel_text.zig", .n = 5, .phase = "B2" },
    .{ .path = "lib/backend/codegen/render.zig", .n = 1, .phase = "B2" },
    .{ .path = "lib/kernels/file_kernels.zig", .n = 4, .phase = "B2" },
    .{ .path = "lib/kernels/hist_kernels.zig", .n = 1, .phase = "B2" },
    .{ .path = "lib/kernels/rng_kernels.zig", .n = 2, .phase = "B2" },
    .{ .path = "lib/kernels/str_kernels.zig", .n = 5, .phase = "B2" },
    .{ .path = "lib/kernels/table_kernels.zig", .n = 6, .phase = "B2" },
};

const PrintsOrExits = struct {
    fn hit(_: PrintsOrExits, l: []const u8) bool {
        return std.mem.find(u8, l, "debug.print(") != null or std.mem.find(u8, l, "process.exit(") != null;
    }
};

fn emitsDevice(p: []const u8) bool {
    return isCodegen(p) or (std.mem.startsWith(u8, p, "lib/kernels/") and std.mem.endsWith(u8, p, "_kernels.zig"));
}

test "R6: no emitted print or exit in device-emitting files" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try openSource(a);
    defer s.root.close(s.io);
    const files = try keepIf(a, try filesUnder(&s), emitsDevice);
    try std.testing.expectEqual(@as(usize, 0), ratchet("R6", try measure(&s, files, true, PrintsOrExits{}), &r6_rows));
}

// ---------------------------------------------------------------------------
// R7: a per-file ceiling on `std.mem.eql(u8` in lib/ and src/; a line
// carrying `// str: <LRM data>` does not count. The ceilings are the counts
// measured on 2026-10-17 (integrate/production-pass at e0c92073); a file
// whose count falls lowers its row in the same commit.
// ---------------------------------------------------------------------------

const r7_rows = [_]Row{
    .{ .path = "lib/analog/lower/analog_op.zig", .n = 27 },
    .{ .path = "lib/analog/lower/constfold.zig", .n = 7 },
    .{ .path = "lib/analog/lower/context.zig", .n = 7 },
    .{ .path = "lib/analog/lower/contrib.zig", .n = 12 },
    .{ .path = "lib/analog/lower/control.zig", .n = 5 },
    .{ .path = "lib/analog/lower/discipline.zig", .n = 10 },
    .{ .path = "lib/analog/lower/event.zig", .n = 12 },
    .{ .path = "lib/analog/lower/expr.zig", .n = 5 },
    .{ .path = "lib/analog/lower/func.zig", .n = 4 },
    .{ .path = "lib/analog/lower/hier_name.zig", .n = 4 },
    .{ .path = "lib/analog/lower/limit.zig", .n = 1 },
    .{ .path = "lib/analog/lower/param.zig", .n = 10 },
    .{ .path = "lib/analog/lower/stmt.zig", .n = 3 },
    .{ .path = "lib/analog/lower/sysfunc.zig", .n = 38 },
    .{ .path = "lib/analog/lower/systask.zig", .n = 10 },
    .{ .path = "lib/analog/lower/var.zig", .n = 5 },
    .{ .path = "lib/analog/lower/wide.zig", .n = 1 },
    .{ .path = "lib/backend/beh_verilog.zig", .n = 4 },
    .{ .path = "lib/backend/cg_filters.zig", .n = 1 },
    .{ .path = "lib/backend/codegen/call.zig", .n = 12 },
    .{ .path = "lib/backend/codegen/cfg.zig", .n = 1 },
    .{ .path = "lib/backend/codegen/file.zig", .n = 1 },
    .{ .path = "lib/backend/codegen/instance.zig", .n = 2 },
    .{ .path = "lib/backend/codegen/plan/names.zig", .n = 2 },
    .{ .path = "lib/backend/codegen/setup.zig", .n = 2 },
    .{ .path = "lib/backend/codegen/setup_chunk.zig", .n = 6 },
    .{ .path = "lib/backend/codegen/unit.zig", .n = 1 },
    .{ .path = "lib/backend/tb/directive.zig", .n = 31 },
    .{ .path = "lib/backend/tb/runner.zig", .n = 9 },
    .{ .path = "lib/base/interner.zig", .n = 2 },
    .{ .path = "lib/diag/suggest.zig", .n = 1 },
    .{ .path = "lib/digital/emit.zig", .n = 2 },
    .{ .path = "lib/elab/discipline_rules.zig", .n = 1 },
    .{ .path = "lib/elab/dist.zig", .n = 1 },
    .{ .path = "lib/elab/elaborate/clone.zig", .n = 12 },
    .{ .path = "lib/elab/elaborate/fixture.zig", .n = 3 },
    .{ .path = "lib/elab/elaborate/names.zig", .n = 11 },
    .{ .path = "lib/elab/elaborate/override.zig", .n = 7 },
    .{ .path = "lib/elab/elaborate/paramset.zig", .n = 3 },
    .{ .path = "lib/elab/elaborate/resolve.zig", .n = 2 },
    .{ .path = "lib/frontend/ast_decl.zig", .n = 1 },
    .{ .path = "lib/frontend/constfold.zig", .n = 9 },
    .{ .path = "lib/frontend/lexer.zig", .n = 5 },
    .{ .path = "lib/frontend/libmap.zig", .n = 15 },
    .{ .path = "lib/frontend/parser.zig", .n = 3 },
    .{ .path = "lib/frontend/parser/expr.zig", .n = 1 },
    .{ .path = "lib/frontend/parser/hier.zig", .n = 1 },
    .{ .path = "lib/frontend/parser/module.zig", .n = 6 },
    .{ .path = "lib/frontend/parser/paramset.zig", .n = 1 },
    .{ .path = "lib/frontend/parser/source.zig", .n = 4 },
    .{ .path = "lib/frontend/parser/specify.zig", .n = 11 },
    .{ .path = "lib/frontend/parser/stmt.zig", .n = 1 },
    .{ .path = "lib/frontend/pp/directive.zig", .n = 8 },
    .{ .path = "lib/frontend/pp/macro.zig", .n = 4 },
    .{ .path = "lib/frontend/spice_cards.zig", .n = 31 },
    .{ .path = "lib/frontend/token.zig", .n = 3 },
    .{ .path = "lib/ir/callee.zig", .n = 1 },
    .{ .path = "lib/ir/names.zig", .n = 1 },
    .{ .path = "lib/ir/simparam.zig", .n = 2 },
    .{ .path = "lib/prove/setup.zig", .n = 1 },
    .{ .path = "lib/root.zig", .n = 3 },
    .{ .path = "lib/zigbuild/exe.zig", .n = 1 },
    .{ .path = "lib/zigbuild/orchestrator.zig", .n = 3 },
    .{ .path = "lib/zigbuild/server.zig", .n = 1 },
    .{ .path = "src/cli/args.zig", .n = 39 },
    .{ .path = "src/cli/digital.zig", .n = 1 },
    .{ .path = "src/cli/lsp.zig", .n = 4 },
    .{ .path = "src/main.zig", .n = 3 },
    .{ .path = "src/sim/digital/compile.zig", .n = 3 },
    .{ .path = "src/sim/digital/elab.zig", .n = 13 },
    .{ .path = "src/sim/digital/evcd.zig", .n = 3 },
    .{ .path = "src/sim/digital/root.zig", .n = 1 },
    .{ .path = "src/sim/digital/system.zig", .n = 3 },
    .{ .path = "src/sim/rt/root.zig", .n = 1 },
    .{ .path = "src/sim/spice/circuit.zig", .n = 1 },
    .{ .path = "src/vpi/analog.zig", .n = 1 },
    .{ .path = "src/vpi/attributes.zig", .n = 5 },
    .{ .path = "src/vpi/code.zig", .n = 1 },
    .{ .path = "src/vpi/iterate.zig", .n = 1 },
    .{ .path = "src/vpi/model.zig", .n = 1 },
    .{ .path = "src/vpi/model/analog.zig", .n = 2 },
    .{ .path = "src/vpi/model/digital.zig", .n = 3 },
    .{ .path = "src/vpi/print.zig", .n = 1 },
    .{ .path = "src/vpi/systf.zig", .n = 2 },
};

const StrEql = struct {
    fn hit(_: StrEql, l: []const u8) bool {
        return std.mem.find(u8, l, "std.mem.eql(u8") != null and std.mem.find(u8, l, "// str:") == null;
    }
};

test "R7: string compares stay under their per-file ceilings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = try openSource(a);
    defer s.root.close(s.io);
    try std.testing.expectEqual(@as(usize, 0), ratchet("R7", try measure(&s, try filesUnder(&s), false, StrEql{}), &r7_rows));
}

// ---------------------------------------------------------------------------
// The scanners see what they are for.
// ---------------------------------------------------------------------------

test "production lines skip test blocks and comments, and keep text on request" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\const a = 1;
        \\// a comment
        \\test "t" {
        \\    const b = 2;
        \\}
        \\test {}
        \\    \\emitted
        \\const c = 3;
    ;
    const plain = try production(a, src, false);
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    try std.testing.expectEqualStrings("const c = 3;", plain[1]);
    try std.testing.expectEqual(@as(usize, 3), (try production(a, src, true)).len);
}

test "the rule predicates see what they are for" {
    try std.testing.expect((AstWrite{}).hit("    const id = try self.ctx.file.exprs.add(a, n);"));
    try std.testing.expect((AstWrite{}).hit("    file.builtin_modules = n;"));
    try std.testing.expect(!(AstWrite{}).hit("    t.udps = udps;"));
    try std.testing.expect(!(AstWrite{}).hit("    file.strings = s;"));
    try std.testing.expect((LoweredMut{}).hit("pub fn f(lowered: *Lowered) void {"));
    try std.testing.expect((LoweredMut{}).hit("    lowered: *Lowered,"));
    try std.testing.expect(!(LoweredMut{}).hit("pub fn f(lowered: *const Lowered) void {"));
    try std.testing.expect(!(LoweredMut{}).hit("fn f(lw: *Lowered) void {"));
    try std.testing.expect((PrintsOrExits{}).hit("    zstd.process.exit(1);"));
    try std.testing.expect((StrEql{}).hit("if (std.mem.eql(u8, a, b)) {"));
    try std.testing.expect(!(StrEql{}).hit("if (std.mem.eql(u8, a, \"dt\")) { // str: $simparam name"));
}
