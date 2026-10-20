//! Fitness test: the `module_specs` rows (`repo_options`) and the lib/ and
//! src/ sources -> a failure for every breach of the fitness
//! rules R1-R7 that its allowlist does not name.
//!
//! Each allowlist holds today's violations, and each row names the phase that
//! deletes it. A row whose violation is gone fails too, and so does a count
//! that fell below its row, so an allowlist only shrinks: when a phase lands,
//! it deletes or lowers its rows in the same commit. The rules are read from
//! text, like `exhaustive.zig`'s guards: R1 and R2 from the rows, R3-R7
//! from production lines (files listed by `import_graph.zig`), that is
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
/// them (empty for a ceiling with no deleting phase: R7's, and R3's
/// overlay-writing elaboration rows).
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
// R2: no backend row's closure contains another backend row.
// Both are read from the rows: an edge the build does not have cannot be
// written, since `defineModules` hands a module only its row's imports.
// ---------------------------------------------------------------------------

/// A row that may reach another, and the phase that deletes the allowance.
const Reach = struct { from: []const u8, to: []const u8, phase: []const u8 };

const r1_allow = [_]Reach{
    .{ .from = "sim", .to = "diag", .phase = "B4" },
    .{ .from = "sim", .to = "frontend", .phase = "B4" },
};

/// Empty since Phase 8 split `backend` into `device`, `verilog` and `exe`:
/// no backend reaches another (the testbench reads a device only through
/// its text and the contract).
const r2_allow = [_]Reach{};

/// The rows' roles, from the tag names `repo_options` carries.
fn rowRoles(a: Allocator) ![]Role {
    const names = repo.module_names;
    try std.testing.expectEqual(names.len, repo.module_roles.len);
    try std.testing.expectEqual(names.len, repo.module_imports.len);
    const roles = try a.alloc(Role, names.len);
    for (repo.module_roles, roles) |tag, *r| r.* = std.meta.stringToEnum(Role, tag) orelse return error.UnknownRole;
    return roles;
}

/// Every `to`-role row the closure of a `from`-role row reaches (the row
/// itself aside) that `allow` does not name, printed under `rule`, plus every
/// `allow` row that no longer reaches; returns how many.
fn reachBreaches(a: Allocator, rule: []const u8, from_role: Role, to_role: Role, allow: []const Reach) !usize {
    const names = repo.module_names;
    const roles = try rowRoles(a);
    const used = try a.alloc(bool, allow.len);
    @memset(used, false);
    var bad: usize = 0;
    const in = try a.alloc(bool, names.len);
    var stack: std.ArrayList(usize) = .empty;
    for (names, roles, 0..) |from, role, i| {
        if (role != from_role) continue;
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
        for (names, roles, in, 0..) |to, r, reached, j| {
            if (!reached or r != to_role or j == i) continue;
            for (allow, used) |row, *u| {
                if (std.mem.eql(u8, row.from, from) and std.mem.eql(u8, row.to, to)) {
                    u.* = true;
                    break;
                }
            } else {
                std.debug.print("{s}: {t} `{s}` reaches {t} `{s}`\n", .{ rule, from_role, from, to_role, to });
                bad += 1;
            }
        }
    }
    for (allow, used) |row, u| if (!u) {
        std.debug.print("{s}: `{s}` no longer reaches `{s}`: delete its row ({s})\n", .{ rule, row.from, row.to, row.phase });
        bad += 1;
    };
    return bad;
}

test "R1: a runtime row's closure contains no compiler row" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bad: usize = 0;
    // A `leaf` imports only std.
    for (repo.module_names, try rowRoles(a), repo.module_imports) |name, role, imports| if (role == .leaf and imports.len != 0) {
        std.debug.print("R1: leaf `{s}` imports `{s}`\n", .{ name, imports });
        bad += 1;
    };
    bad += try reachBreaches(a, "R1", .runtime, .compiler, &r1_allow);
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "R2: no backend row's closure contains another backend row" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(usize, 0), try reachBreaches(arena_state.allocator(), "R2", .backend, .backend, &r2_allow));
}

// ---------------------------------------------------------------------------
// R3: no Ast writes outside lib/frontend. A write is a call to one of the
// Ast's appenders (`exprs.add*`, `addStmt`, `seqBlockMut`, `seedFrom`), or an
// assignment to a `SourceFile` field other than the interner (interning is
// allowed) through a receiver spelled `...file`.
// ---------------------------------------------------------------------------

// Since Phase 12 every row below writes an overlay of the parse
// (`Ast.SourceFile.overlay`), never the parse; the text cannot tell the two
// apart. The rows are ceilings with no deleting phase (decided 2026-10-18):
// a count may only fall, and a new elaboration write outside them fails.
const r3_rows = [_]Row{
    .{ .path = "lib/elab/elaborate.zig", .n = 1 },
    .{ .path = "lib/elab/elaborate/clone.zig", .n = 9 },
    .{ .path = "lib/elab/elaborate/insert.zig", .n = 1 },
    // 2 -> 3 (2026-10-19): §6.2.2's expression actual on a digital input
    // port is a synthesized net driven by `assign`, whose target is a new
    // identifier row; no existing helper mints a bare identifier.
    .{ .path = "lib/elab/elaborate/instance.zig", .n = 3 },
    .{ .path = "lib/elab/elaborate/names.zig", .n = 3 },
    .{ .path = "lib/elab/hier_param.zig", .n = 1 },
    .{ .path = "src/sim/digital/root.zig", .n = 1 },
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
// (lib/device/**, and lib/kernels/*_kernels.zig, whose
// source is device text; the module's other files are host Zig). Matched as `debug.print(` and `process.exit(`, since a kernel names
// `std` through its own alias (`zstd`, `zhs`, ...).
// ---------------------------------------------------------------------------

const r6_rows = [_]Row{
    .{ .path = "lib/device/cg_display.zig", .n = 3, .phase = "B2" },
    .{ .path = "lib/device/codegen/kernel_text.zig", .n = 5, .phase = "B2" },
    .{ .path = "lib/device/codegen/render.zig", .n = 1, .phase = "B2" },
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
    return std.mem.startsWith(u8, p, "lib/device/") or (std.mem.startsWith(u8, p, "lib/kernels/") and std.mem.endsWith(u8, p, "_kernels.zig"));
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
    .{ .path = "lib/analog/lower/systask.zig", .n = 8 },
    .{ .path = "lib/analog/lower/var.zig", .n = 5 },
    .{ .path = "lib/analog/lower/wide.zig", .n = 1 },
    .{ .path = "lib/base/interner.zig", .n = 2 },
    .{ .path = "lib/device/cg_filters.zig", .n = 1 },
    .{ .path = "lib/device/codegen/call.zig", .n = 12 },
    .{ .path = "lib/device/codegen/cfg.zig", .n = 1 },
    .{ .path = "lib/device/codegen/file.zig", .n = 1 },
    .{ .path = "lib/device/codegen/instance.zig", .n = 2 },
    .{ .path = "lib/device/codegen/plan/names.zig", .n = 2 },
    .{ .path = "lib/device/codegen/setup.zig", .n = 2 },
    .{ .path = "lib/device/codegen/setup_chunk.zig", .n = 6 },
    .{ .path = "lib/device/codegen/unit.zig", .n = 1 },
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
    .{ .path = "lib/exe/tb/directive.zig", .n = 31 },
    .{ .path = "lib/exe/tb/runner.zig", .n = 9 },
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
    .{ .path = "lib/verilog/beh_verilog.zig", .n = 4 },
    .{ .path = "lib/zigbuild/exe.zig", .n = 1 },
    .{ .path = "lib/zigbuild/orchestrator.zig", .n = 3 },
    .{ .path = "lib/zigbuild/server.zig", .n = 1 },
    .{ .path = "src/cli/args.zig", .n = 40 }, // +1: `--version` (2026-10-18)
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
