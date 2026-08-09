//! The `spice` mode: each `.sp` deck (a SPICE netlist with `.hdl "model.va"`
//! cards and an `.expected.json` analytic oracle) -> PASS, FAIL or NOT RUN.
//! First the half every deck needs: the oracle exists, every `.hdl` model
//! resolves (`resolveModel`) and compiles. Then the deck is EXECUTED on VerA's
//! own testbench solver when it can be: `translate` turns the netlist into a
//! Verilog-AMS top module (Annex E primitives for R and V cards, the `.hdl`
//! modules for N cards) with a `//! tran` or `//! onoise` line, `vera
//! --emit-exe` builds it (`tb/runner_text.zig` `deck_body`), and `grade`
//! holds its rows to the oracle's own values and tolerances. A deck that needs
//! a card or analysis the runner does not have is NOT RUN, and the line says
//! what is missing; it is never graded as a pass.
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

/// The `spice` mode: checks, then runs, each `.sp` deck matching the filter in
/// `args`, printing one PASS/FAIL/NOT RUN line per deck and a census to
/// stderr. Exit 1 on any FAIL or when nothing matched; NOT RUN is not a FAIL.
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
    var passed: usize = 0;
    var not_run: usize = 0;
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
        const oracle_path = try pa.print("{s}.expected.json", .{stem});
        const oracle = Io.Dir.cwd().readFileAlloc(io, oracle_path, pa, .limited(1 << 20)) catch blk: {
            try w.print("FAIL {s}: no .expected.json beside it\n", .{name});
            bad = true;
            break :blk "";
        };

        // 2. Every model the deck names, one `.hdl "<path>"` per line.
        const source = try Io.Dir.cwd().readFileAlloc(io, path, pa, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, source, '\n');
        var models: std.ArrayList([]const u8) = .empty;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, ".hdl")) continue;
            const open = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const rest = line[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const ref = rest[0..close];

            const model = (try resolveModel(pa, io, dir_path, ref)) orelse {
                try w.print("FAIL {s}: .hdl \"{s}\" resolves to no file\n", .{ name, ref });
                bad = true;
                continue;
            };
            try models.append(pa, model);
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
        if (models.items.len == 0 and !bad) {
            try w.print("FAIL {s}: no .hdl card, so the deck names no model\n", .{name});
            bad = true;
        }
        if (bad) {
            failed += 1;
            continue;
        }

        // 4. Execute it, when the runner has everything the deck asks for.
        const deck = switch (try translate(pa, source, models.items)) {
            .missing => |why| {
                try w.print("NOT RUN {s}: {s}\n", .{ name, why });
                not_run += 1;
                continue;
            },
            .deck => |d| d,
        };
        const verdict = try execute(pa, io, vera_exe, std.fs.path.basename(stem), dir_path, deck, oracle);
        switch (verdict) {
            .pass => |what| {
                try w.print("PASS {s}: {s}\n", .{ name, what });
                passed += 1;
            },
            .fail => |why| {
                try w.print("FAIL {s}: {s}\n", .{ name, why });
                failed += 1;
            },
        }
    }

    if (ran == 0) {
        try w.print("spice: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print(
        \\spice: {d}/{d} decks executed on VerA's testbench solver and match their oracle;
        \\spice:   {d} NOT RUN (compile-only, the line says what is missing); {d} FAIL
        \\
    , .{ passed, ran, not_run, failed });
    return if (failed == 0) 0 else 1;
}

/// A deck as the runner can execute it: the top module's source, and what the
/// oracle's columns are called in the runner's rows.
const Deck = struct {
    /// `tran` or `noise`, as the oracle's `analysis` names it.
    analysis: []const u8,
    va: []const u8,
};

const Translated = union(enum) {
    deck: Deck,
    /// The card or option the runner has no implementation of.
    missing: []const u8,
};

/// Returns `netlist` as a Verilog-AMS top module, or what of it the runner
/// cannot execute. Reads exactly these cards, and NOT RUN for anything else:
///
///   Nname n1 n2 ... module    an instance of a `.hdl` module
///   Rname a b value           Annex E `resistor`
///   Vname a b [DC] v [AC m]   Annex E `vsine` held at v (AC: a short in .noise)
///   Vname a b PWL(t v ...)    Annex E `vpwl`
///   .tran tstep tstop         `//! tran` (runner_text `runTran`)
///   .noise v(out) src lin n f1 f2   `//! onoise` (runner_text `runNoise`)
///
/// SPICE is case-insensitive, so the deck is lower-cased first (`.hdl` paths
/// are already resolved into `models`). Node `0` is ground.
fn translate(arena: Allocator, netlist: []const u8, models: []const []const u8) !Translated {
    const lower = try std.ascii.allocLowerString(arena, netlist);
    var nets: std.ArrayList([]const u8) = .empty;
    var insts: std.ArrayList(u8) = .empty;
    var directives: std.ArrayList(u8) = .empty;
    var analysis: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, lower, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '*') continue;
        if (line[0] == '+') return .{ .missing = "a `+` continuation card" };
        var it = std.mem.tokenizeAny(u8, line, " \t(),");
        const card = it.next().?;
        if (std.mem.eql(u8, card, ".hdl") or std.mem.eql(u8, card, ".end")) continue;
        if (std.mem.eql(u8, card, ".tran")) {
            const tstep = spiceNumber(it.next() orelse "") orelse return .{ .missing = "a .tran card without tstep" };
            const tstop = spiceNumber(it.next() orelse "") orelse return .{ .missing = "a .tran card without tstop" };
            if (it.next() != null) return .{ .missing = ".tran tstart/tmax/uic: the runner steps from 0 with SPICE's default ceiling" };
            if (analysis != null) return .{ .missing = "a second analysis card" };
            analysis = "tran";
            try directives.print(arena, "//! analysis tran\n//! tran {e}, {e}\n", .{ tstep, tstop });
            continue;
        }
        if (std.mem.eql(u8, card, ".noise")) {
            const out = it.next() orelse "";
            const node = it.next() orelse "";
            if (!std.mem.eql(u8, out, "v")) return .{ .missing = ".noise with an output that is not v(node)" };
            _ = it.next(); // the input source: it names inoise, which no oracle here reads
            const sweep = it.next() orelse "";
            if (!std.mem.eql(u8, sweep, "lin")) return .{ .missing = try arena.print(".noise {s} sweep (only lin is read)", .{sweep}) };
            const n = std.fmt.parseInt(usize, it.next() orelse "", 10) catch return .{ .missing = ".noise lin without a point count" };
            const f1 = spiceNumber(it.next() orelse "") orelse return .{ .missing = ".noise without fstart" };
            const f2 = spiceNumber(it.next() orelse "") orelse return .{ .missing = ".noise without fstop" };
            if (n == 0 or it.next() != null) return .{ .missing = ".noise with a node pair or extra fields" };
            if (analysis != null) return .{ .missing = "a second analysis card" };
            analysis = "noise";
            try directives.print(arena, "//! analysis noise\n//! onoise V({s}) =", .{try net(arena, &nets, node)});
            for (0..n) |k| {
                // SPICE's lin sweep: n points, both ends included.
                const f = if (n == 1) f1 else f1 + (f2 - f1) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
                try directives.print(arena, "{s} {e}", .{ if (k == 0) "" else ",", f });
            }
            try directives.append(arena, '\n');
            continue;
        }
        if (card[0] == '.') return .{ .missing = try arena.print("the {s} card", .{card}) };

        switch (card[0]) {
            'n' => {
                var ports: std.ArrayList([]const u8) = .empty;
                while (it.next()) |t| try ports.append(arena, t);
                if (ports.items.len < 2) return .{ .missing = try arena.print("an N card without a module: {s}", .{line}) };
                const module = ports.pop().?;
                try insts.print(arena, "  {s} {s}(", .{ module, card });
                for (ports.items, 0..) |p, i| try insts.print(arena, "{s}{s}", .{ if (i == 0) "" else ", ", try net(arena, &nets, p) });
                try insts.appendSlice(arena, ");\n");
            },
            'r' => {
                const a = try net(arena, &nets, it.next() orelse return .{ .missing = "an R card without nodes" });
                const b = try net(arena, &nets, it.next() orelse return .{ .missing = "an R card without nodes" });
                const r = spiceNumber(it.next() orelse "") orelse return .{ .missing = "an R card whose value is not a number" };
                if (it.next() != null) return .{ .missing = "an R card with parameters" };
                try insts.print(arena, "  resistor #(.r({e})) {s}({s}, {s});\n", .{ r, card, a, b });
            },
            'v' => {
                const a = try net(arena, &nets, it.next() orelse return .{ .missing = "a V card without nodes" });
                const b = try net(arena, &nets, it.next() orelse return .{ .missing = "a V card without nodes" });
                var dc: f64 = 0;
                var pwl: std.ArrayList(f64) = .empty;
                while (it.next()) |t| {
                    if (std.mem.eql(u8, t, "dc")) {
                        dc = spiceNumber(it.next() orelse "") orelse return .{ .missing = "a V card's DC value" };
                    } else if (std.mem.eql(u8, t, "ac")) {
                        // A small-signal stimulus. `.noise`'s output spectrum does
                        // not read it and `.ac` is not run, so only its magnitude
                        // is consumed; a phase would follow it.
                        _ = spiceNumber(it.next() orelse "") orelse return .{ .missing = "a V card's AC magnitude" };
                    } else if (std.mem.eql(u8, t, "pwl")) {
                        while (it.next()) |p| try pwl.append(arena, spiceNumber(p) orelse return .{ .missing = "a PWL value that is not a number" });
                    } else if (spiceNumber(t)) |v| {
                        dc = v;
                    } else return .{ .missing = try arena.print("the V card source `{s}`", .{t}) };
                }
                if (pwl.items.len != 0) {
                    if (pwl.items.len < 4 or pwl.items.len % 2 != 0) return .{ .missing = "a PWL with fewer than two points" };
                    // SPICE's operating point is the waveform at t = 0.
                    try insts.print(arena, "  vpwl #(.dc({e}), .nwave({d}), .wave('{{", .{ pwl.items[1], pwl.items.len });
                    for (pwl.items, 0..) |v, i| try insts.print(arena, "{s}{e}", .{ if (i == 0) "" else ", ", v });
                    try insts.print(arena, "}})) {s}({s}, {s});\n", .{ card, a, b });
                } else {
                    try insts.print(arena, "  vsine #(.dc({e}), .offset({e}), .ampl(0.0)) {s}({s}, {s});\n", .{ dc, dc, card, a, b });
                }
            },
            else => return .{ .missing = try arena.print("the {c} device card ({s})", .{ std.ascii.toUpper(card[0]), card }) },
        }
    }
    const a = analysis orelse return .{ .missing = "no .tran or .noise card" };

    var va: std.ArrayList(u8) = .empty;
    for (models) |m| try va.print(arena, "`include \"{s}\"\n", .{std.fs.path.basename(m)});
    // Every node is solved for: the deck's sources fix what is fixed.
    try va.print(arena, "{s}//! solve\nmodule spice_deck;\n  ground gnd;\n", .{directives.items});
    if (nets.items.len != 0) {
        try va.appendSlice(arena, "  electrical ");
        for (nets.items, 0..) |n, i| try va.print(arena, "{s}{s}", .{ if (i == 0) "" else ", ", n });
        try va.appendSlice(arena, ";\n");
    }
    try va.print(arena, "{s}endmodule\n", .{insts.items});
    return .{ .deck = .{ .analysis = a, .va = va.items } };
}

/// The Verilog-AMS net for SPICE node `node`, declared once in `nets`: `0` is
/// ground, a node that is not an identifier (`1`) is `n_1`.
fn net(arena: Allocator, nets: *std.ArrayList([]const u8), node: []const u8) ![]const u8 {
    if (std.mem.eql(u8, node, "0")) return "gnd";
    const id = if (std.ascii.isAlphabetic(node[0]) or node[0] == '_') node else try arena.print("n_{s}", .{node});
    for (nets.items) |n| if (std.mem.eql(u8, n, id)) return id;
    try nets.append(arena, id);
    return id;
}

/// A SPICE number: digits with an optional scale suffix (`1k`, `1meg`, `1m`);
/// trailing letters after the suffix are units and ignored, as SPICE does.
fn spiceNumber(tok: []const u8) ?f64 {
    var end: usize = 0;
    while (end < tok.len and (std.ascii.isDigit(tok[end]) or tok[end] == '.' or tok[end] == '-' or tok[end] == '+' or
        ((tok[end] == 'e') and end + 1 < tok.len and (std.ascii.isDigit(tok[end + 1]) or tok[end + 1] == '-' or tok[end + 1] == '+')))) : (end += 1)
    {}
    if (end == 0) return null;
    const v = std.fmt.parseFloat(f64, tok[0..end]) catch return null;
    const rest = tok[end..];
    const scale: f64 = if (std.mem.startsWith(u8, rest, "meg")) 1e6 else if (rest.len == 0) 1 else switch (rest[0]) {
        't' => 1e12,
        'g' => 1e9,
        'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        else => 1,
    };
    return v * scale;
}

const Verdict = union(enum) {
    /// What was checked.
    pass: []const u8,
    fail: []const u8,
};

/// Builds `deck` with `vera --emit-exe`, runs it, and grades its rows against
/// `oracle_text`.
fn execute(arena: Allocator, io: Io, vera_exe: []const u8, stem: []const u8, dir_path: []const u8, deck: Deck, oracle_text: []const u8) !Verdict {
    const work = try std.fs.path.join(arena, &.{ options.work_root, "spice", stem });
    try Io.Dir.cwd().createDirPath(io, work);
    const top = try std.fs.path.join(arena, &.{ work, try arena.print("{s}.va", .{stem}) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = top, .data = deck.va });
    const built = try child.capture(arena, io, &.{
        vera_exe,             "--emit-exe",    "--validate-contract", "--contract", options.contract,
        "--zig",              options.zig_exe, "--work-dir",          work,         "-I",
        options.fixture_root, "-I",            dir_path,              top,
    });
    if (built.exit != 0) return .{ .fail = try arena.print("the deck's top module ({s}) does not build:\n{s}", .{ top, built.stderr }) };
    const exe = std.mem.trimEnd(u8, built.stdout, "\n");
    const r = try child.capture(arena, io, &.{exe});
    if (r.exit != 0) return .{ .fail = try arena.print("the runner exited {d}:\n{s}", .{ r.exit, r.stderr }) };
    return grade(arena, deck, r.stderr, oracle_text);
}

/// The runner's rows: one axis value (t or f) and one value per column.
const Table = struct {
    axis: []const f64,
    names: []const []const u8,
    cols: []const []const f64,

    fn column(t: Table, name: []const u8) ?[]const f64 {
        for (t.names, t.cols) |n, c| if (std.mem.eql(u8, n, name)) return c;
        return null;
    }
};

/// Collects the `tran t=... u=v ...` or `noise f=... onoise=v` rows; every
/// other line (the models' own `$strobe`s) is not the deck's output.
fn parseRows(arena: Allocator, out: []const u8, prefix: []const u8) !Table {
    var axis: std.ArrayList(f64) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var cols: std.ArrayList(std.ArrayList(f64)) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix) or line.len <= prefix.len or line[prefix.len] != ' ') continue;
        var it = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
        var k: usize = 0;
        while (it.next()) |kv| : (k += 1) {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadRow;
            const v = try std.fmt.parseFloat(f64, kv[eq + 1 ..]);
            if (k == 0) {
                try axis.append(arena, v);
                continue;
            }
            if (axis.items.len == 1) {
                try names.append(arena, kv[0..eq]);
                try cols.append(arena, .empty);
            }
            if (k - 1 >= cols.items.len) return error.BadRow;
            try cols.items[k - 1].append(arena, v);
        }
    }
    const flat = try arena.alloc([]const f64, cols.items.len);
    for (cols.items, flat) |c, *f| f.* = c.items;
    return .{ .axis = axis.items, .names = names.items, .cols = flat };
}

fn num(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn fieldNum(v: std.json.Value, key: []const u8, default: f64) f64 {
    return num(field(v, key) orelse return default) orelse default;
}

fn numbers(arena: Allocator, v: ?std.json.Value) ![]const f64 {
    const arr = (v orelse return error.BadOracle);
    if (arr != .array) return error.BadOracle;
    const out = try arena.alloc(f64, arr.array.items.len);
    for (arr.array.items, out) |e, *o| o.* = num(e) orelse return error.BadOracle;
    return out;
}

/// `|got - want| <= atol + rtol*|want|`, the oracle's tolerance.
fn within(got: f64, want: f64, rtol: f64, atol: f64) bool {
    return @abs(got - want) <= atol + rtol * @abs(want);
}

/// The runner's column for an oracle column: `v(node)` is that node's
/// unknown, `onoise_spectrum` the noise row's `onoise`.
fn columnOf(t: Table, name: []const u8) ?[]const f64 {
    if (std.mem.eql(u8, name, "onoise_spectrum")) return t.column("onoise");
    if (std.mem.startsWith(u8, name, "v(") and std.mem.endsWith(u8, name, ")")) return t.column(name[2 .. name.len - 1]);
    return null;
}

/// Linear interpolation of `col` over `axis` at `a`, inside the run only.
fn sampleAt(axis: []const f64, col: []const f64, a: f64) ?f64 {
    if (axis.len == 0 or a < axis[0] or a > axis[axis.len - 1]) return null;
    for (axis[1..], 1..) |hi, i| if (a <= hi) {
        const lo = axis[i - 1];
        if (hi == lo) return col[i];
        return col[i - 1] + (col[i] - col[i - 1]) * (a - lo) / (hi - lo);
    };
    return col[col.len - 1];
}

/// Holds the runner's rows to the oracle. Reads `analysis`, `expect.status`,
/// `expect.plots` (`match` `exact`: the same rows, or `samples`: each column
/// interpolated at the axis values), `expect.checks` (`selected_values`: a row
/// at exactly each coordinate) and `finite_values_required`. Anything else in
/// `expect` it does not know is a FAIL, never a skip.
fn grade(arena: Allocator, deck: Deck, out: []const u8, oracle_text: []const u8) !Verdict {
    const oracle = std.json.parseFromSliceLeaky(std.json.Value, arena, oracle_text, .{}) catch
        return .{ .fail = "the oracle is not JSON" };
    const want_analysis = field(oracle, "analysis") orelse return .{ .fail = "the oracle names no analysis" };
    if (want_analysis != .string or !std.mem.eql(u8, want_analysis.string, deck.analysis))
        return .{ .fail = try arena.print("the oracle is a {s} analysis and the deck runs {s}", .{ if (want_analysis == .string) want_analysis.string else "?", deck.analysis }) };
    const expect = field(oracle, "expect") orelse return .{ .fail = "the oracle has no expect" };
    var it = expect.object.iterator();
    while (it.next()) |e| {
        const known = [_][]const u8{ "status", "plots", "checks", "finite_values_required", "all_requested_analyses_must_complete" };
        for (known) |k| {
            if (std.mem.eql(u8, k, e.key_ptr.*)) break;
        } else return .{ .fail = try arena.print("the oracle's expect.{s} is not graded by this harness", .{e.key_ptr.*}) };
    }
    if (field(expect, "status")) |s| if (s != .string or !std.mem.eql(u8, s.string, "success"))
        return .{ .fail = "the oracle expects a status other than success" };

    const t = parseRows(arena, out, deck.analysis) catch return .{ .fail = try arena.print("the runner printed a malformed row:\n{s}", .{out}) };
    if (t.axis.len == 0) return .{ .fail = try arena.print("the runner printed no {s} rows:\n{s}", .{ deck.analysis, out }) };
    if (field(expect, "finite_values_required")) |f| if (f == .bool and f.bool) {
        for (t.cols) |c| for (c) |v| if (!std.math.isFinite(v)) return .{ .fail = "a value is not finite" };
    };

    var checked: usize = 0;
    if (field(expect, "plots")) |plots| for (plots.array.items) |p| {
        const match = (field(p, "match") orelse return .{ .fail = "a plot without match" }).string;
        const ax = field(p, "axis") orelse return .{ .fail = "a plot without axis" };
        const want_axis = try numbers(arena, field(ax, "values"));
        const exact = std.mem.eql(u8, match, "exact");
        if (!exact and !std.mem.eql(u8, match, "samples")) return .{ .fail = try arena.print("plot match `{s}` is not graded", .{match}) };
        if (exact) {
            const rc = fieldNum(p, "row_count", @floatFromInt(want_axis.len));
            if (t.axis.len != want_axis.len or rc != @as(f64, @floatFromInt(t.axis.len)))
                return .{ .fail = try arena.print("{d} rows, the oracle wants {d}", .{ t.axis.len, want_axis.len }) };
            for (t.axis, want_axis) |g, wv| if (!within(g, wv, fieldNum(ax, "rtol", 0), fieldNum(ax, "atol", 0)))
                return .{ .fail = try arena.print("axis value {e}, the oracle wants {e}", .{ g, wv }) };
        }
        const columns = field(p, "columns") orelse return .{ .fail = "a plot without columns" };
        var ci = columns.object.iterator();
        while (ci.next()) |c| {
            const col = columnOf(t, c.key_ptr.*) orelse return .{ .fail = try arena.print("the runner has no column for `{s}`", .{c.key_ptr.*}) };
            const want = try numbers(arena, field(c.value_ptr.*, "values"));
            if (want.len != want_axis.len) return .{ .fail = "an oracle column's length differs from its axis" };
            const rtol = fieldNum(c.value_ptr.*, "rtol", 0);
            const atol = fieldNum(c.value_ptr.*, "atol", 0);
            for (want_axis, want, 0..) |a, wv, i| {
                const g = if (exact) col[i] else sampleAt(t.axis, col, a) orelse
                    return .{ .fail = try arena.print("{s} at {e} is outside the run", .{ c.key_ptr.*, a }) };
                if (!within(g, wv, rtol, atol))
                    return .{ .fail = try arena.print("{s} at {e} = {e}, the oracle wants {e} (rtol {e}, atol {e})", .{ c.key_ptr.*, a, g, wv, rtol, atol }) };
                checked += 1;
            }
        }
    };
    if (field(expect, "checks")) |checks| for (checks.array.items) |ck| {
        const kind = (field(ck, "kind") orelse return .{ .fail = "a check without kind" }).string;
        if (!std.mem.eql(u8, kind, "selected_values")) return .{ .fail = try arena.print("check kind `{s}` is not graded", .{kind}) };
        // ponytail: `period` folds a coordinate into one period of a periodic
        // run. Every deck's period exceeds its run, so it is not applied.
        const cname = (field(ck, "column") orelse return .{ .fail = "a check without column" }).string;
        const col = columnOf(t, cname) orelse return .{ .fail = try arena.print("the runner has no column for `{s}`", .{cname}) };
        const coords = try numbers(arena, field(ck, "coordinates"));
        const want = try numbers(arena, field(ck, "values"));
        if (coords.len != want.len) return .{ .fail = "a check's coordinates and values differ in length" };
        for (coords, want) |cv, wv| {
            // The coordinate itself must be an accepted point: interpolation
            // across it would hide a missing timepoint.
            const i = std.mem.indexOfScalar(f64, t.axis, cv) orelse
                return .{ .fail = try arena.print("MissingCoordinate: no accepted point at {e}", .{cv}) };
            if (!within(col[i], wv, fieldNum(ck, "rtol", 0), fieldNum(ck, "atol", 0)))
                return .{ .fail = try arena.print("{s} at {e} = {e}, the oracle wants {e}", .{ cname, cv, col[i], wv }) };
            checked += 1;
        }
    };
    if (checked == 0) return .{ .fail = "the oracle states no value, so nothing was graded" };
    return .{ .pass = try arena.print("{s}, {d} values within the oracle over {d} rows", .{ deck.analysis, checked, t.axis.len }) };
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

test "spiceNumber reads SPICE scale suffixes" {
    try std.testing.expectEqual(@as(?f64, 1e3), spiceNumber("1k"));
    try std.testing.expectEqual(@as(?f64, 2e6), spiceNumber("2meg"));
    try std.testing.expectEqual(@as(?f64, 1e-3), spiceNumber("1m"));
    try std.testing.expectEqual(@as(?f64, 1e-4), spiceNumber("1e-4"));
    try std.testing.expectEqual(@as(?f64, 90000), spiceNumber("90000"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("pwl"));
}

test "a deck with a card the runner lacks is NOT RUN, naming it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try translate(arena.allocator(), "Q1 c b e qmod\n.tran 1 2\n", &.{});
    try std.testing.expectEqualStrings("the Q device card (q1)", r.missing);
    const ok = try translate(arena.allocator(), "R1 a 0 1k\nV1 a 0 PWL(0 0 1m 1)\n.tran 1e-4 1e-3\n", &.{});
    try std.testing.expect(std.mem.indexOf(u8, ok.deck.va, "resistor #(.r(1e3)) r1(a, gnd);") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok.deck.va, "//! tran 1e-4, 1e-3") != null);
}
