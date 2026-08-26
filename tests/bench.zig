//! The suite runner behind `zig build benchmark`, `test-devices`, `test-1364`,
//! `test-vpi-fixtures` and `test-spice`: fixtures -> verdicts on stderr and a
//! timing table on stdout (one row per fixture, walk order, so two runs diff).
//!
//! Benchmark verdicts come from a depth pass (compile, build and run the
//! testbench); times come from a separate sequential accept/reject pass.
//!
//! `main` dispatches on the mode word; each mode is one file under `harness/`:
//!   (none)       this file: `benchmark`, the depth pass and the timing table
//!   `--sweep`    `harness/sweep.zig`, the generated size sweep
//!   `devices`    `harness/devices.zig` (`--native`: `native.zig`, `--fuzz`:
//!   `ieee1364`     `fuzz.zig`, `--coverage`: `ieee1364.zig`)
//!   `vpi`        `harness/c_fixtures.zig`
//!   `spice`      `harness/spice_decks.zig`
//!   `golden`     `harness/golden.zig`, the before/after snapshot of what vera says
//!   `archmap`    `harness/archmap.zig`, specification/UNITS.md and the AGENTS.md map
//!   `canary`     `harness/canary.zig`, the wrong-on-purpose fixtures the judge must FAIL
//!
//! `tools/conformance.py` parses the `pass fail unasserted xfail` row this
//! file prints: that row's text is frozen.

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const torture = @import("torture.zig");
const ieee1364 = @import("ieee1364.zig");
const size_sweep = @import("harness/sweep.zig");
const devices = @import("harness/devices.zig");
const c_fixtures = @import("harness/c_fixtures.zig");
const spice_decks = @import("harness/spice_decks.zig");
const golden = @import("harness/golden.zig");
const archmap = @import("harness/archmap.zig");
const canary = @import("harness/canary.zig");

const Io = std.Io;

// Zig collects `test` blocks only from the root file and what its tests
// reference, so the sibling runners' tests run only through this block.
test {
    _ = harness;
    _ = torture;
    _ = ieee1364;
    _ = size_sweep;
    _ = devices;
    _ = c_fixtures;
    _ = spice_decks;
    _ = golden;
    _ = archmap;
    _ = canary;
    _ = @import("harness/native.zig");
    _ = @import("harness/fuzz.zig");
    _ = @import("harness/child.zig");
}
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// Entry point. argv[1] is the `vera` executable (`run.addArtifactArg2`), which
/// `devices` spawns. Then either a
/// mode word (`devices`, `ieee1364`, `vpi`, `spice`, `golden`, `archmap`) or
/// benchmark arguments:
///
///   zig build benchmark                         # the suite, timed
///   zig build benchmark -- ch04                 # only paths matching `ch04`
///   zig build benchmark -- --strict             # unasserted and xfail FAIL
///   zig build benchmark -- --fixture-root=tests/pending   # the tree meant to fail
///   zig build benchmark -- --coverage           # LRM clauses cited and uncited
///   zig build benchmark -- --sweep              # the generated size sweep instead
///   zig build benchmark -Doptimize=ReleaseFast  # the timing that ships
///
/// Returns the process exit code.
pub fn main(init: std.process.Init) !u8 {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    // The `vera` binary, from `run.addArtifactArg(exe)`.
    const vera_exe = args.next() orelse return usage(init.io, "missing the vera executable path");
    // The other runs of this executable, matched exactly: any other word,
    // including a bare filter, is a benchmark argument.
    const first = args.next();
    if (first) |a| {
        if (std.mem.eql(u8, a, "devices")) return devices.run(init, vera_exe, &args, &devices.digital_dirs);
        if (std.mem.eql(u8, a, devices.ieee1364_dir)) return devices.run(init, vera_exe, &args, &.{devices.ieee1364_dir});
        if (std.mem.eql(u8, a, "vpi")) return c_fixtures.run(init, &args);
        if (std.mem.eql(u8, a, "spice")) return spice_decks.run(init, vera_exe, &args);
        if (std.mem.eql(u8, a, "golden")) return golden.run(init, vera_exe, &args);
        if (std.mem.eql(u8, a, "archmap")) return archmap.run(init, &args);
        if (std.mem.eql(u8, a, "canary")) return canary.run(init);
    }
    return benchmark(init, vera_exe, first, &args);
}

/// Prints `why` and the usage line to stderr; returns exit code 2.
pub fn usage(io: Io, why: []const u8) !u8 {
    var buf: [256]u8 = undefined;
    var e = Io.File.stderr().writer(io, &buf);
    try e.interface.print(
        "suite: {s}\nusage: <vera-exe> [devices | ieee1364 | vpi | spice | benchmark args]\n",
        .{why},
    );
    try e.interface.flush();
    return 2;
}

/// N per fixture, smaller than `harness/sweep.zig`'s `reps` because every fixture is timed. The min
/// is still the estimator; the report's distribution is over fixtures, the
/// variation that is about the compiler.
const fixture_reps = 5;

/// Nanoseconds since `t0` on the monotonic (`.awake`) clock.
pub fn elapsed(io: Io, t0: Io.Timestamp) u64 {
    const ns = t0.durationTo(.now(io, .awake)).nanoseconds;
    return @intCast(@max(ns, 0));
}

/// The mode the engine was compiled in, printed on every row because only a
/// ReleaseFast time is the shipping number (Debug is several times slower).
/// `builtin.mode` is this module's `-O`, which `build.zig` keeps equal to the
/// `vera` module's.
pub const mode = @tagName(@import("builtin").mode);

// ---------------------------------------------------------------------------
// The assertions — the half of this file that can fail
// ---------------------------------------------------------------------------

/// `device.text.len`, `mir.defs.len` and `mir.insts.len` for every generated
/// shape, in `sweep` order, measured by this bench. Pure functions of the
/// source, so the same on every machine and optimize mode: a change here is a
/// change in what VerA emits, and the commit that moves it explains it.
const Shape = struct { device: usize, defs: usize, insts: usize };
const expected = std.enums.directEnumArrayDefault(Axis, [sweep.len]Shape, null, 0, .{
    .contrib = .{
        .{ .device = 33174, .defs = 8, .insts = 5 },
        .{ .device = 33529, .defs = 35, .insts = 26 },
        .{ .device = 36272, .defs = 258, .insts = 194 },
        .{ .device = 58675, .defs = 2050, .insts = 1538 },
        .{ .device = 241255, .defs = 16386, .insts = 12290 },
    },
    .vals = .{
        .{ .device = 33174, .defs = 8, .insts = 5 },
        .{ .device = 33356, .defs = 24, .insts = 19 },
        .{ .device = 34812, .defs = 136, .insts = 131 },
        .{ .device = 46517, .defs = 1032, .insts = 1027 },
        .{ .device = 140278, .defs = 8200, .insts = 8195 },
    },
    // Parallel instances share one (p, n) row; the MIR also carries each
    // instance's share of it (`lower_contrib.unitAccum`), dead in the device.
    .inst = .{
        .{ .device = 33174, .defs = 8, .insts = 5 },
        .{ .device = 34378, .defs = 57, .insts = 47 },
        .{ .device = 44226, .defs = 449, .insts = 383 },
        .{ .device = 124760, .defs = 3585, .insts = 3071 },
        .{ .device = 782545, .defs = 28673, .insts = 24575 },
    },
});

/// `expected`, for `harness/sweep.zig`, which asserts it. The table stays in
/// this file so the change that moves a generated device's size edits it here.
pub const expected_sizes = expected;
const sweep = size_sweep.sweep;
const Axis = size_sweep.Axis;

// ---------------------------------------------------------------------------
// The step
// ---------------------------------------------------------------------------

fn benchmark(init: std.process.Init, vera_exe: []const u8, first: ?[]const u8, args: *Args) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `harness.takeArg` owns every knob the SUITE has, and takes them first, so
    // that a filter word cannot shadow one. What is left is this step's own.
    var cfg: harness.Config = .init();
    harness.vera_exe = vera_exe; // `//! expect vcd` runs it
    var do_sweep = false;
    var a = first;
    while (a) |arg| : (a = args.next()) {
        if (harness.takeArg(&cfg, arg)) continue;
        if (std.mem.eql(u8, arg, "--sweep")) do_sweep = true //
        else if (std.mem.startsWith(u8, arg, "-")) {
            var e_buf: [256]u8 = undefined;
            var e = Io.File.stderr().writer(io, &e_buf);
            try e.interface.print("benchmark: unknown flag `{s}`\n", .{arg});
            try e.interface.flush();
            return 2;
        } else cfg.filter = arg;
    }
    // `--fixture-root=tests/pending` is how a human writes it; resolved once,
    // so every FAIL line names an absolute path.
    cfg.root = std.fs.path.resolveAlloc(arena, &.{cfg.root}) catch cfg.root;

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (do_sweep) return size_sweep.report(gpa, io, arena, w);

    // `--coverage` is a question about the FIXTURES — which LRM clauses they
    // cite — so it compiles nothing and there is nothing to time or compare.
    var tctx: torture.Ctx = .{ .cfg = &cfg };
    defer tctx.deinit(gpa);
    if (cfg.coverage) return harness.run(init, torture.compiler(&tctx), cfg, null);

    // THE DEPTH PASS: VerA compiles, builds a testbench, runs it and reads the
    // `ok=` columns. It owns the exit code, because it is the only pass that
    // can fail — a wall clock has no verdict.
    var depth: harness.Counts = .{};
    const code = try harness.run(init, torture.compiler(&tctx), cfg, &depth);

    try report(gpa, io, arena, w, cfg, depth);
    return code;
}

// ---------------------------------------------------------------------------
// The timing table. VerA's accept/refuse verdict is `harness.judge`'s; its
// `ok=` columns print in the depth pass.
// ---------------------------------------------------------------------------

fn report(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    w: *Io.Writer,
    cfg: harness.Config,
    depth: harness.Counts,
) !void {
    const fixtures = try harness.collect(arena, io, cfg.root, cfg.filter);
    if (fixtures.len == 0) return;

    // VerA's accept/reject prose is discarded: the depth pass already printed
    // a stronger report of the same fixtures.
    var sink: [256]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&sink);

    try w.print(
        \\# VerA benchmark — engine built {s}, min of {d} runs per fixture, sequential.
        \\# The timed unit is ONE accept/reject compilation: source in, device text out.
        \\# The testbench build and run that decide the verdicts are NOT in these
        \\# numbers — that is `zig build-exe`, whose wall clock is not VerA's.
        \\
    , .{ mode, fixture_reps });
    if (@import("builtin").mode != .fast) try w.print(
        "# {s}: NOT the shipping number (~8x slow). Re-run with -Doptimize=ReleaseFast.\n",
        .{mode},
    );
    try w.writeAll("fixture\tdemands\tvera_ns\tvera_out\tvera_ok\n");

    const times = try arena.alloc(u64, fixtures.len);
    var per_arena: std.heap.ArenaAllocator = .init(gpa);
    defer per_arena.deinit();

    for (fixtures, times) |f, *time| {
        _ = per_arena.reset(.retain_capacity);
        const pa = per_arena.allocator();
        const source = try Io.Dir.cwd().readFileAlloc(io, f.path, pa, .limited(1 << 20));
        // A fixture whose directives do not parse is FAILED by `judge` below,
        // which is where that defect belongs; here it just times as one.
        const d = vera.tb.parse(pa, source) catch vera.tb.Directives{};

        var vera_ns: u64 = std.math.maxInt(u64);
        var vera_out: ?usize = null;
        for (0..fixture_reps) |_| {
            const t0: Io.Timestamp = .now(io, .awake);
            vera_out = torture.compileOnce(gpa, f, source, d) catch null;
            vera_ns = @min(vera_ns, elapsed(io, t0));
        }
        const vera_ok = try harness.judge(
            gpa,
            io,
            pa,
            torture.acceptRejectCompiler(),
            f,
            false,
            &discard.writer,
        ) == .pass;
        time.* = vera_ns;

        try w.print("{s}\t{s}\t{d}\t", .{
            relative(f.path, cfg.root),
            if (d.reject.len != 0) "refuse" else "compile",
            vera_ns,
        });
        try optional(w, vera_out);
        try w.print("\t{d}\n", .{@intFromBool(vera_ok)});
        try w.flush();
    }

    try summary(w, arena, times, depth);
}

/// `-` and not `0`: "there is no number" and "the number is zero" are different
/// facts, and a refused fixture emits no device rather than an empty one.
fn optional(w: *Io.Writer, v: anytype) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("-");
}

fn relative(path: []const u8, root: []const u8) []const u8 {
    return path[@min(root.len + 1, path.len)..];
}

fn summary(w: *Io.Writer, arena: Allocator, times: []const u64, depth: harness.Counts) !void {
    try w.writeAll(
        \\
        \\# SPEED — total and distribution.
        \\
    );
    try w.writeAll("scope\tcompiler\tn\ttotal_ns\tp50_ns\tp90_ns\tp99_ns\tmax_ns\n");
    try stats(w, arena, "all", "vera", times);

    try w.writeAll(
        \\
        \\# VERA ONLY — the `ok=` assertions, and the depth no foreign compiler is
        \\#   measured at. Only VerA's testbench is built and run, so these are a
        \\#   question an accept/reject-only compiler was never asked and never a score
        \\#   it lost. A fixture passes here only if every `ok=` column its own
        \\#   transcript printed came out 1 — the compile and the refusal columns above
        \\#   are a strictly weaker claim than this one.
        \\
    );
    try w.writeAll("pass\tfail\tunasserted\txfail\n");
    try w.print("{d}\t{d}\t{d}\t{d}\n", .{
        depth.passed,
        depth.failed,
        depth.unasserted,
        depth.xfail,
    });
}

/// One speed row. The samples are COPIED before sorting: they are also the
/// caller's.
fn stats(w: *Io.Writer, arena: Allocator, scope: []const u8, name: []const u8, samples: []const u64) !void {
    if (samples.len == 0) return;
    const s = try arena.dupe(u64, samples);
    var total: u64 = 0;
    for (s) |v| total +%= v;
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    try w.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        scope, name, s.len, total, pct(s, 50), pct(s, 90), pct(s, 99), s[s.len - 1],
    });
}

fn pct(sorted: []const u64, p: usize) u64 {
    return sorted[@min(sorted.len * p / 100, sorted.len - 1)];
}
