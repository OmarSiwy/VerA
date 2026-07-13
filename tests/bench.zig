//! The suite runner behind `zig build benchmark`, `test-devices`, `test-1364`,
//! `test-vpi-fixtures` and `test-spice`: fixtures -> verdicts on stderr and a
//! timing table on stdout (one row per fixture, walk order, so two runs diff).
//!
//! Benchmark verdicts come from a depth pass (compile, build and run the
//! testbench); times come from a separate sequential accept/reject pass.

const std = @import("std");
const vera = @import("vera");
const stdpp = @import("stdpp");
const harness = @import("harness.zig");
const torture = @import("torture.zig");
const ieee1364 = @import("ieee1364.zig");
const options = @import("suite_options");

const Io = std.Io;

// Zig collects `test` blocks only from the root file and what its tests
// reference, so the sibling runners' tests run only through this block.
test {
    _ = harness;
    _ = torture;
    _ = ieee1364;
}
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// Entry point. argv[1] is the `vera` executable (`run.addArtifactArg`), which
/// `devices` spawns. Then either a
/// mode word (`devices`, `ieee1364`, `vpi`, `spice`) or benchmark arguments:
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
        if (std.mem.eql(u8, a, "devices")) return devices(init, vera_exe, &args, &digital_dirs);
        if (std.mem.eql(u8, a, ieee1364_dir)) return devices(init, vera_exe, &args, &.{ieee1364_dir});
        if (std.mem.eql(u8, a, "vpi")) return vpiFixtures(init, &args);
        if (std.mem.eql(u8, a, "spice")) return spiceDecks(init, vera_exe, &args);
    }
    return benchmark(init, vera_exe, first, &args);
}

fn usage(io: Io, why: []const u8) !u8 {
    var buf: [256]u8 = undefined;
    var e = Io.File.stderr().writer(io, &buf);
    try e.interface.print(
        "suite: {s}\nusage: <vera-exe> [devices | ieee1364 | vpi | spice | benchmark args]\n",
        .{why},
    );
    try e.interface.flush();
    return 2;
}

/// `root.zig` does not export `Mir`; the type is reached through the result
/// that carries it, the seam an embedder already has.
const Mir = @typeInfo(@FieldType(vera.CompileResult, "mir")).pointer.child;

/// N for the sweep and for the spawn floor; the estimator is the min over it.
/// Noise on a shared machine only ever adds time, so the min is the closest
/// sample to the code's cost, where a mean measures the machine's load.
const reps = 25;

/// N per fixture, smaller than `reps` because every fixture is timed. The min
/// is still the estimator; the report's distribution is over fixtures, the
/// variation that is about the compiler.
const fixture_reps = 5;

/// The sweep. Powers of eight, so a doubling and a squaring are visibly
/// different shapes across four steps rather than two.
const sweep = [_]u32{ 1, 8, 64, 512, 4096 };

/// The generated cases. Each pins the other two axes at 1, so a bend in one
/// column is attributable to one axis.
const Axis = enum { contrib, vals, inst };

// ---------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------

/// Emit a .va with `n_contrib` contributions, `n_vals` chained reals and
/// `n_inst` instances. Everything is LIVE: the value chain terminates in the
/// contributions and the contributions terminate in the top module's ports, so
/// nothing here measures the speed at which VerA deletes dead code.
fn gen(w: *Io.Writer, n_contrib: u32, n_vals: u32, n_inst: u32) Io.Writer.Error!void {
    try w.writeAll(
        \\module bench_leaf(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  parameter real gain = 1.0;
        \\  analog begin
        \\
    );
    for (0..n_vals) |i| try w.print("    real v{d};\n", .{i});
    try w.writeAll("    v0 = V(a, b) * gain;\n");
    for (1..n_vals) |i| try w.print("    v{d} = v{d} * 1.5 + 0.25;\n", .{ i, i - 1 });
    for (0..n_contrib) |i| try w.print(
        "    I(a, b) <+ gain * v{d} * {d}.0;\n",
        .{ n_vals - 1, i + 1 },
    );
    try w.writeAll(
        \\  end
        \\endmodule
        \\
        \\module bench_top(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\
    );
    for (0..n_inst) |i| try w.print("  bench_leaf i{d}(p, n);\n", .{i});
    try w.writeAll("endmodule\n");
}

fn genSource(gpa: Allocator, axis: Axis, n: u32) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try gen(
        &aw.writer,
        if (axis == .contrib) n else 1,
        if (axis == .vals) n else 1,
        if (axis == .inst) n else 1,
    );
    return aw.toOwnedSlice();
}

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
        .{ .device = 31021, .defs = 8, .insts = 5 },
        .{ .device = 31376, .defs = 35, .insts = 26 },
        .{ .device = 34119, .defs = 258, .insts = 194 },
        .{ .device = 56522, .defs = 2050, .insts = 1538 },
        .{ .device = 239102, .defs = 16386, .insts = 12290 },
    },
    .vals = .{
        .{ .device = 31021, .defs = 8, .insts = 5 },
        .{ .device = 31203, .defs = 24, .insts = 19 },
        .{ .device = 32659, .defs = 136, .insts = 131 },
        .{ .device = 44364, .defs = 1032, .insts = 1027 },
        .{ .device = 138125, .defs = 8200, .insts = 8195 },
    },
    .inst = .{
        .{ .device = 31021, .defs = 8, .insts = 5 },
        .{ .device = 32225, .defs = 50, .insts = 40 },
        .{ .device = 42073, .defs = 386, .insts = 320 },
        .{ .device = 122607, .defs = 3074, .insts = 2560 },
        .{ .device = 780392, .defs = 24578, .insts = 20480 },
    },
});

/// Compile one generated shape and hold it to `expected`. Shared by the bench
/// run (every point of the sweep) and by the unit test below (the two cheap
/// points), so the assertion has exactly one spelling.
fn checkShape(gpa: Allocator, axis: Axis, i: usize) !Footprint {
    const src = try genSource(gpa, axis, sweep[i]);
    defer gpa.free(src);

    var result = try vera.compileSourceOpts(gpa, src, .lint, .{});
    defer result.deinit();
    const device = try result.generateDevice();

    const want = expected[@intFromEnum(axis)][i];
    try std.testing.expectEqual(want.defs, result.mir.defs.len);
    try std.testing.expectEqual(want.insts, result.mir.insts.len);
    try std.testing.expectEqual(want.device, device.len);
    return .of(result.mir);
}

// ---------------------------------------------------------------------------
// The MIR footprint — the other half of a size regression
// ---------------------------------------------------------------------------

/// What one compilation's MIR costs in bytes, by column. A `MultiArrayList` row
/// costs the sum of its field sizes, not `@sizeOf(Row)`. The dedup maps and the
/// interner are excluded: they are build-time scratch that `deinit` drops.
const Footprint = struct {
    insts: u64 = 0,
    defs: u64 = 0,
    blocks: u64 = 0,
    extra: u64 = 0,

    // ponytail: ask the SoA container for its row size; this still excludes spare capacity.
    const inst_b: u64 = std.MultiArrayList(Mir.InstRow).capacityInBytes(1);
    const def_b: u64 = std.MultiArrayList(Mir.ValueRow).capacityInBytes(1) + @sizeOf(Mir.Value); // + alias slot
    const block_b: u64 = std.MultiArrayList(Mir.BlockRow).capacityInBytes(1);

    fn of(m: *const Mir) Footprint {
        return .{
            .insts = m.insts.len,
            .defs = m.defs.len,
            .blocks = m.blocks.len,
            .extra = m.extra.items.len,
        };
    }

    fn bytes(self: Footprint) u64 {
        return self.insts * inst_b + self.defs * def_b +
            self.blocks * block_b + self.extra * @sizeOf(u32);
    }
};

fn emitFootprint(w: *Io.Writer, case: []const u8, n: u32, f: Footprint) !void {
    try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        case, n, f.insts, f.defs, f.blocks, f.extra, f.bytes(),
    });
}

// ---------------------------------------------------------------------------
// The phases
// ---------------------------------------------------------------------------

/// The sweep's phases, each a prefix of the next (there is no seam that resumes
/// a compilation midway), so a stage's own cost is a subtraction: `lint - pp`
/// is lex+parse+lower+prove, `codegen - lint` is codegen.
///   pp        `Preprocessor.process`                          text -> text
///   lint      `vera.compileSourceOpts(gpa, src, .lint, .{})`  text -> MIR
///   codegen   `result.generateDevice()`                       MIR -> device.zig
///   rewrite   `orchestrator.writeTree` a second time          device.zig -> 0 bytes
const Phase = enum { pp, lint, codegen, rewrite };

/// `bytes` is what the phase handled: preprocessed text out of `pp`, the same
/// text in for `lint`, device text out of `codegen`, bytes written to disk for
/// `rewrite` (asserted 0 by a test, not here).
const Sample = struct { min_ns: u64, bytes: u64 };

/// Run `phase` over one generated source and return the bytes it handled.
///
/// `keep` receives the `CompileResult` instead of freeing it, so the clock is
/// read before teardown. Precondition: `keep` already has capacity for `reps`,
/// so no reallocation lands inside the timed region.
fn runPhase(
    gpa: Allocator,
    io: Io,
    phase: Phase,
    source: []const u8,
    work_dir: []const u8,
    keep: *std.ArrayList(vera.CompileResult),
) !u64 {
    if (phase == .pp) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var bag = vera.diag.Bag.init(arena.allocator());
        const text = (try vera.Preprocessor.process(arena.allocator(), source, .{ .bag = &bag })).text;
        std.mem.doNotOptimizeAway(text.len);
        return text.len;
    }

    keep.appendAssumeCapacity(try vera.compileSourceOpts(gpa, source, .lint, .{}));
    const result = &keep.items[keep.items.len - 1];

    std.mem.doNotOptimizeAway(result.mir);
    if (phase == .lint) return result.source.len;

    const device = try result.generateDevice();
    std.mem.doNotOptimizeAway(device.len);
    if (phase == .codegen) return device.len;

    // Prime the tree, then write it again: the no-op recompile. That it writes
    // 0 bytes is a `test` at the foot of the file; an assert under the clock
    // would time itself.
    _ = try rewrite(io, gpa, result.device, work_dir);
    return rewrite(io, gpa, result.device, work_dir);
}

/// One `orchestrator.writeTree`, returning how many bytes it actually put on
/// disk. Shared by the timed phase and by the test that pins the second call to
/// zero, so the claim and the measurement are the same code path.
fn rewrite(io: Io, gpa: Allocator, device: anytype, work_dir: []const u8) !usize {
    return vera.orchestrator.writeTree(io, gpa, .{
        .work_dir = work_dir,
        .name = "bench",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &.{},
    }, device);
}

fn measure(
    gpa: Allocator,
    io: Io,
    phase: Phase,
    source: []const u8,
    work_dir: []const u8,
) !Sample {
    var kept: std.ArrayList(vera.CompileResult) = .empty;
    defer {
        for (kept.items) |*r| r.deinit();
        kept.deinit(gpa);
    }
    try kept.ensureTotalCapacity(gpa, reps);

    var min: u64 = std.math.maxInt(u64);
    var bytes: u64 = 0;
    for (0..reps) |_| {
        const t0: Io.Timestamp = .now(io, .awake);
        bytes = try runPhase(gpa, io, phase, source, work_dir, &kept);
        min = @min(min, elapsed(io, t0));
    }
    return .{ .min_ns = min, .bytes = bytes };
}

/// Nanoseconds since `t0` on the monotonic (`.awake`) clock.
fn elapsed(io: Io, t0: Io.Timestamp) u64 {
    const ns = t0.durationTo(.now(io, .awake)).nanoseconds;
    return @intCast(@max(ns, 0));
}

/// The mode the engine was compiled in, printed on every row because only a
/// ReleaseFast time is the shipping number (Debug is several times slower).
/// `builtin.mode` is this module's `-O`, which `build.zig` keeps equal to the
/// `vera` module's.
const mode = @tagName(@import("builtin").mode);

fn emit(w: *Io.Writer, case: []const u8, n: u32, phase: Phase, s: Sample) !void {
    try w.print("{s}\t{s}\t{d}\t{t}\t{d}\t{d}\n", .{ mode, case, n, phase, s.min_ns, s.bytes });
}

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
    cfg.root = std.fs.path.resolve(arena, &.{cfg.root}) catch cfg.root;

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (do_sweep) return sweepReport(gpa, io, arena, w);

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
    if (@import("builtin").mode != .ReleaseFast) try w.print(
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
    var all = stdpp.of(s);
    const total = all.sumWrapping(u64);
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    try w.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        scope, name, s.len, total, pct(s, 50), pct(s, 90), pct(s, 99), s[s.len - 1],
    });
}

fn pct(sorted: []const u64, p: usize) u64 {
    return sorted[@min(sorted.len * p / 100, sorted.len - 1)];
}

// ---------------------------------------------------------------------------

/// `--sweep`: each axis of `gen` swept over `sweep` with the others at 1. The
/// slope is the point: an O(n^2) scan and a flat one can cost the same at n = 8.
fn sweepReport(gpa: Allocator, io: Io, arena: Allocator, w: *Io.Writer) !u8 {
    // The footprint table is its own pass, one compile per shape outside every
    // timer: the timing table's `bytes` is a different quantity.
    try w.writeAll("case\tn\tinsts\tdefs\tblocks\textra\tmir_bytes\n");
    for (std.enums.values(Axis)) |axis| {
        for (sweep, 0..) |n, i| try emitFootprint(w, @tagName(axis), n, try checkShape(gpa, axis, i));
    }
    try w.flush();

    try w.writeAll("\nmode\tcase\tn\tphase\tmin_ns\tbytes\n");
    if (@import("builtin").mode != .ReleaseFast) try w.print(
        "# {s}: NOT the shipping number (~8x slow). Re-run with -Doptimize=ReleaseFast.\n",
        .{mode},
    );
    for (std.enums.values(Axis)) |axis| {
        for (sweep) |n| {
            const src = try genSource(arena, axis, n);
            for (std.enums.values(Phase)) |p| {
                const s = try measure(gpa, io, p, src, options.work_root ++ "/benchmark/gen");
                try emit(w, @tagName(axis), n, p, s);
            }
            try w.flush();
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The `devices` mode: `vera --run x.v` transcripts against committed goldens,
// which need the `vera` binary and so cannot be `test` blocks.
//
//   zig build test-devices          # all of it
//   zig build test-devices -- rng   # the cases whose name contains `rng`
// ---------------------------------------------------------------------------

/// `vera --run <name>.v` must print `<name>.expected.txt` exactly. IEEE 1364
/// semantics, so `.v` and not `.va`: the shared frontend plus `sim/`, with no
/// analog path at all.
///
/// Walked recursively, not listed: `tests/fixtures/ieee1364/<NN_clause>/` (IEEE
/// 1364-2005, one directory per clause) and `tests/fixtures/digital/`
/// (digital-context Verilog-AMS rules such as wreal and the `--std` boundary).
///
/// A `.v` is a case when it has `.expected.txt` or `// digital-runner: reject`;
/// a support design with neither (a UDP library a fixture instantiates) is not.
const digital_dirs = [_][]const u8{ "digital", ieee1364_dir };
const ieee1364_dir = "ieee1364";

fn devices(init: std.process.Init, vera_exe: []const u8, args: *Args, dirs: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var filter: ?[]const u8 = null;
    var native: ?[]const []const u8 = null;
    var snapshot = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--coverage")) return ieee1364.coverage(init);
        if (std.mem.eql(u8, a, "--native") or std.mem.eql(u8, a, "--native=fifo")) {
            native = &.{"--schedule=fifo"};
            continue;
        }
        if (std.mem.eql(u8, a, "--native=static")) {
            native = &.{"--schedule=static"};
            continue;
        }
        if (std.mem.eql(u8, a, "--native=four")) {
            native = &.{ "--schedule=fifo", "--state=4" };
            continue;
        }
        if (std.mem.eql(u8, a, "--native=two-state")) {
            native = &.{"--two-state"};
            continue;
        }
        if (std.mem.eql(u8, a, "--native=snapshot") or std.mem.eql(u8, a, "--snapshot")) {
            snapshot = true;
            if (native == null or a.len == "--native=snapshot".len) native = &.{"--schedule=fifo"};
            continue;
        }
        if (std.mem.eql(u8, a, "--fuzz")) {
            const n = std.fmt.parseInt(u32, args.next() orelse "", 10) catch return usage(init.io, "--fuzz takes a count");
            return fuzz(init, vera_exe, n);
        }
        filter = a;
    }

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const cases = try digitalCases(gpa, io, dirs, native != null);
    defer {
        for (cases) |c| gpa.free(c);
        gpa.free(cases);
    }
    // A case that writes a file (§17.2.1 `$fopen` for writing, §18's dump)
    // writes it relative to the working directory, which must not be the
    // repository: every case runs in the suite's scratch tree instead. The
    // fixture paths are absolute already; the executable is made so.
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, gpa);
    defer gpa.free(exe);
    const scratch = options.work_root ++ "/devices";
    try Io.Dir.cwd().createDirPath(io, scratch);
    var scratch_dir = try Io.Dir.cwd().openDir(io, scratch, .{});
    defer scratch_dir.close(io);
    try std.process.setCurrentDir(io, scratch_dir);

    if (native) |flags| return nativeDevices(gpa, io, exe, flags, snapshot, cases, filter, w);

    var ran: usize = 0;
    var failed: usize = 0;
    var xfailed: usize = 0;
    for (cases) |case| {
        if (filter) |f| if (std.mem.indexOf(u8, case, f) == null) continue;
        _ = arena_state.reset(.retain_capacity);
        ran += 1;
        switch (try digitalVerdict(arena_state.allocator(), io, exe, case, w)) {
            .pass => {},
            .fail => failed += 1,
            .xfail => xfailed += 1,
        }
    }
    if (ran == 0) {
        try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print("devices: {d}/{d} cases behave as they say they do", .{ ran - failed - xfailed, ran });
    if (xfailed != 0) try w.print(", {d} XFAIL (a known gap, not a pass)", .{xfailed});
    try w.writeAll("\n");
    return if (failed == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// The `vpi` mode: every `.c` fixture under `vpi_dirs`, compiled (not linked or
// run) against src/vpi/vpi_user.h, so the ABI the LRM describes is checked by
// a C compiler. The fixtures that run are `build.zig`'s `vpi_runs`.
//
//   zig build test-vpi-fixtures           # all of them
//   zig build test-vpi-fixtures -- p03    # the ones whose name contains p03
// ---------------------------------------------------------------------------

/// Directories holding `.c` fixtures. Some groups share a header beside them
/// (`p02_check.h`, `p03_vpi_analog.h`), so the fixture's own directory goes on
/// the include path as well as `src/vpi`.
const vpi_dirs = [_][]const u8{ "ch11_vpi", "ch12_vpi_routines", "ieee_pli" };

fn vpiFixtures(init: std.process.Init, args: *Args) !u8 {
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

    // One object path, reused: the loop is sequential and nothing reads it.
    const work = options.work_root ++ "/vpi-fixtures";
    Io.Dir.cwd().createDirPath(io, work) catch {};
    const obj = try std.fs.path.join(arena_state.allocator(), &.{ work, "fixture.o" });
    const vpi_include = options.vpi_include;

    var ran: usize = 0;
    var failed: usize = 0;
    for (vpi_dirs) |sub| {
        const dir_path = try std.fs.path.join(gpa, &.{ options.fixture_root, sub });
        defer gpa.free(dir_path);
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        // Sorted, so a failing run is reproducible and its name list diffs.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
            try names.append(gpa, try arena_state.allocator().dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, harness.strLess);

        for (names.items) |name| {
            if (filter) |f| if (std.mem.indexOf(u8, name, f) == null) continue;
            ran += 1;
            const pa = arena_state.allocator();
            const src = try std.fs.path.join(pa, &.{ dir_path, name });
            // `-c -o`, not `-fsyntax-only`: `zig cc` passes its own `-c`, which
            // `-fsyntax-only` leaves unused, and `-Werror` fails every fixture on
            // that warning. The flags are `vpi_app.c`'s, so no fixture passes
            // here that the acceptance test's flags would refuse.
            const r = capture(pa, io, &.{
                options.zig_exe, "cc",     "-std=c99", "-Wall", "-Werror",
                "-c",            "-o",     obj,        "-I",    vpi_include,
                "-I",            dir_path, src,
            }) catch |e| {
                try w.print("FAIL {s}: could not run the C compiler: {s}\n", .{ name, @errorName(e) });
                failed += 1;
                continue;
            };
            if (r.exit == 0) continue;
            failed += 1;
            // One line of the compiler's words; the full log would bury the census.
            const first = std.mem.trim(u8, firstErrorLine(r.stderr), " \t\r");
            try w.print("FAIL {s}: {s}\n", .{ name, first });
        }
    }

    if (ran == 0) {
        try w.print("vpi: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print("vpi: {d}/{d} fixtures compile against src/vpi/vpi_user.h\n", .{ ran - failed, ran });
    return if (failed == 0) 0 else 1;
}

/// The compiler's first `error:` line, or its first line if it never said one.
fn firstErrorLine(stderr: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |l| if (std.mem.indexOf(u8, l, "error:") != null) return l;
    var again = std.mem.splitScalar(u8, stderr, '\n');
    return again.next() orelse "";
}

test "the first error line is the compiler's, not the last line of a log" {
    const log =
        \\p02_01.c:77:24: note: expanded from here
        \\p02_01.c:77:24: error: unknown type name 'p_cb_data'
        \\p02_01.c:93:14: error: use of undeclared identifier 'vpiBinStrVal'
        \\1 error generated.
    ;
    try std.testing.expectEqualStrings(
        "p02_01.c:77:24: error: unknown type name 'p_cb_data'",
        firstErrorLine(log),
    );
    // A compiler that failed without the word `error:` still has to report
    // something, or a FAIL row would be a bare name.
    try std.testing.expectEqualStrings("cc: killed", firstErrorLine("cc: killed\n"));
    try std.testing.expectEqualStrings("", firstErrorLine(""));
}

// ---------------------------------------------------------------------------
// The `spice` mode: each `.sp` deck (a SPICE netlist with `.hdl "model.va"`
// cards and an `.expected.json` analytic oracle). The simulator that runs them
// is not in this repository, so this checks the half it owns: the oracle
// exists, every `.hdl` model resolves (`resolveModel`), and each compiles.
//
//   zig build test-spice            # all of them
//   zig build test-spice -- a10     # the decks whose name contains a10
// ---------------------------------------------------------------------------

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

fn spiceDecks(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
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
        const oracle = try std.fmt.allocPrint(pa, "{s}.expected.json", .{stem});
        if (Io.Dir.cwd().access(io, oracle, .{})) |_| {} else |_| {
            try w.print("FAIL {s}: no .expected.json beside it\n", .{name});
            bad = true;
        }

        // 2. Every model the deck names, one `.hdl "<path>"` per line.
        const source = try Io.Dir.cwd().readFileAlloc(io, path, pa, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, source, '\n');
        var models: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, ".hdl")) continue;
            const open = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const rest = line[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const ref = rest[0..close];
            models += 1;

            const model = (try resolveModel(pa, io, dir_path, ref)) orelse {
                try w.print("FAIL {s}: .hdl \"{s}\" resolves to no file\n", .{ name, ref });
                bad = true;
                continue;
            };
            // 3. VerA's own half: the model has to compile. `--check` and both
            //    include dirs, per AGENTS.md §6 — `check.vh` is at the suite
            //    root and the model's siblings are beside it.
            const r = capture(pa, io, &.{
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
        if (models == 0) {
            try w.print("FAIL {s}: no .hdl card, so the deck names no model\n", .{name});
            bad = true;
        }
        if (bad) failed += 1;
    }

    if (ran == 0) {
        try w.print("spice: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print(
        \\spice: {d}/{d} decks are paired with an oracle and name models that compile
        \\spice: NOT executed — a deck needs a circuit simulator to link the device and
        \\spice:   turn the Newton loop. That is ARPice (ROADMAP.md §6), which is not in
        \\spice:   this repository, so no release here can run one.
        \\
    , .{ ran - failed, ran });
    return if (failed == 0) 0 else 1;
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

const Captured = struct { stdout: []const u8, stderr: []const u8, exit: u8 };

/// Run a child and take everything it said.
fn capture(arena: Allocator, io: Io, argv: []const []const u8) !Captured {
    return captureIn(arena, io, argv, null);
}

/// `capture` with the child's working directory at `cwd`.
fn captureIn(arena: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8) !Captured {
    const r = try std.process.run(arena, io, .{ .argv = argv, .cwd = if (cwd) |p| .{ .path = p } else .inherit });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit = switch (r.term) {
        .exited => |c| c,
        else => 255,
    } };
}

/// A transcript that differs is reported as the whole of both sides: these are
/// tens of bytes, and "line 3 differs" sends the reader to the file anyway.
fn diff(w: *Io.Writer, what: []const u8, want: []const u8, got: []const u8) !bool {
    if (std.mem.eql(u8, want, got)) return true;
    try w.print("FAIL {s}: transcript differs\n  want: {f}\n  got:  {f}\n", .{
        what,
        std.ascii.hexEscape(want, .lower),
        std.ascii.hexEscape(got, .lower),
    });
    return false;
}

/// Digital transcript cases and explicitly opted-in diagnostic cases, sorted
/// so two runs report in the same order. Support files are not cases.
/// Case names are fixture-root-relative stems, `ieee1364/05_expressions/control`.
/// `vcd`: also the `//! expect vcd` fixtures, whose `--run` the .va suite
/// judges (`harness.judgeVcd`) and whose executable `--native` does.
fn digitalCases(gpa: Allocator, io: Io, dirs: []const []const u8, vcd: bool) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c);
        list.deinit(gpa);
    }
    for (dirs) |sub| {
        const root = try std.fs.path.join(gpa, &.{ options.fixture_root, sub });
        defer gpa.free(root);
        var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".v")) continue;
            const stem = entry.path[0 .. entry.path.len - ".v".len];
            const golden = try std.fmt.allocPrint(gpa, "{s}.expected.txt", .{stem});
            defer gpa.free(golden);
            const has_golden = if (dir.access(io, golden, .{})) |_| true else |_| false;
            const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20));
            defer gpa.free(source);
            const dumps = vcd and !has_golden and harness.vcdExpectation(source) != null;
            if (!dumps and !harness.digitalCaseSelected(has_golden, source)) continue;
            try list.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, stem }));
        }
    }
    std.mem.sort([]const u8, list.items, {}, harness.strLess);
    return list.toOwnedSlice(gpa);
}

/// `digitalCase` under `//! xfail`, with the .va suite's algebra
/// (`harness.judge`): an unmet xfail case is XFAIL and does not fail the run;
/// a met one is an XPASS FAIL, so a marker cannot outlive its limitation.
fn digitalVerdict(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !enum { pass, fail, xfail } {
    const src = try std.fmt.allocPrint(arena, "{s}/{s}.v", .{ options.fixture_root, case });
    const xfail = harness.digitalXfail(try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20))) orelse
        return if (try digitalCase(arena, io, vera_exe, case, w)) .pass else .fail;
    if (xfail.len == 0) {
        try w.print("FAIL {s}: `//! xfail` names no reason\n", .{case});
        return .fail;
    }
    var detail: Io.Writer.Allocating = .init(arena);
    if (try digitalCase(arena, io, vera_exe, case, &detail.writer)) {
        try w.print("FAIL {s}: XPASS — marked `//! xfail`, but VerA now does what the fixture says.\n" ++
            "  Delete the `//! xfail` line.\n", .{case});
        return .fail;
    }
    try w.print("XFAIL {s}: known: {s}\n", .{ case, xfail });
    return .xfail;
}

fn digitalCase(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !bool {
    const src = try std.fmt.allocPrint(arena, "{s}/{s}.v", .{ options.fixture_root, case });
    const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{ vera_exe, "--run", src }, try harness.digitalArgs(arena, source, std.fs.path.dirname(src).?) });
    if (harness.digitalNegative(source)) {
        const golden = try std.fmt.allocPrint(arena, "{s}/{s}.expected.txt", .{ options.fixture_root, case });
        if (Io.Dir.cwd().access(io, golden, .{})) |_| {
            try w.print("FAIL {s}: digital reject also has a positive transcript\n", .{case});
            return false;
        } else |_| {}
        const r = try capture(arena, io, argv);
        if (!harness.digitalRejectionMatches(source, r.exit, r.stderr)) {
            try w.print("FAIL {s}: digital rejection mismatch (exit {d})\n{s}\n", .{ case, r.exit, r.stderr });
            return false;
        }
        return true;
    }
    const want = try Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(arena, "{s}/{s}.expected.txt", .{ options.fixture_root, case }),
        arena,
        .limited(1 << 20),
    );
    const r = try capture(arena, io, argv);
    if (r.exit != 0) {
        try w.print("FAIL {s}: vera --run exited {d}\n{s}\n", .{ case, r.exit, r.stderr });
        return false;
    }
    if (!harness.digitalWarningsMatch(source, r.stderr)) {
        try w.print("FAIL {s}: successful digital run has missing warning evidence or error diagnostics\n{s}\n", .{ case, r.stderr });
        return false;
    }
    return diff(w, case, want, r.stdout);
}

// ---------------------------------------------------------------------------
// `--native`: the same cases through `vera --emit-exe` and the executable it
// builds. The golden `--run` matches is the oracle, so matching it is matching
// the interpreter and neither engine runs twice. Every case is also one of
// three name lists — `NATIVE`, `FALLBACK <reason>` (the executable embeds the
// interpreter, `rt.interpret`) or `FAIL` — so native coverage is diffed by
// name, and a fallback that hides a regression shows up as a moved name.
// A `// native-required` fixture makes that fallback a FAIL in native modes.
// The forced two-state report keeps its separate x/z refusal policy below.
//
//   zig build test-1364 -- --native            # all of IEEE 1364
//   zig build test-1364 -- --native=static     # combinational logic levelized
//   zig build test-devices -- --native d04     # the cases whose name has d04
//   zig build test-1364 -- --native=two-state  # a report, not a gate: see below
//   zig build test-1364 -- --native=snapshot   # every tick run twice (below)
//
// `--snapshot` (after any `--native=`) runs each executable with
// `--vera-snapshot`: at every tick boundary its state is saved, the tick run
// quietly, the state restored and the tick run again (`rt/snapshot.zig`).
// The transcript must still be the golden.
//
// `--two-state` makes every x or z 0, so its transcript is not the golden.
// A case passes when each line that differs shows an x or z digit in the
// golden; FALLBACK is then every case `--two-state` refuses (E1101).
// ---------------------------------------------------------------------------

const NativeJob = struct {
    gpa: Allocator,
    io: Io,
    vera_exe: []const u8,
    flags: []const []const u8,
    snapshot: bool,
    cases: []const []const u8,
    slots: []NativeSlot,
    next: std.atomic.Value(usize) = .init(0),

    fn work(job: *NativeJob) void {
        var arena_state: std.heap.ArenaAllocator = .init(job.gpa);
        defer arena_state.deinit();
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.cases.len) return;
            _ = arena_state.reset(.retain_capacity);
            var aw: Io.Writer.Allocating = .init(job.gpa);
            const v = nativeVerdict(arena_state.allocator(), job.io, job.vera_exe, job.flags, job.snapshot, job.cases[i], &aw.writer) catch |e| blk: {
                aw.writer.print("FAIL {s}: the runner itself failed: {t}\n", .{ job.cases[i], e }) catch {};
                break :blk NativeVerdict{ .pass = false, .fallback = null };
            };
            var list = aw.toArrayList();
            // The reason is in the arena the next case resets.
            var kept = v;
            if (v.fallback) |why| kept.fallback = job.gpa.dupe(u8, why) catch "?";
            job.slots[i] = .{ .verdict = kept, .output = list.toOwnedSlice(job.gpa) catch "" };
        }
    }
};

/// `fallback` is the executable's reason for embedding the interpreter;
/// `refused` is a case the shared elaboration rejected, so no executable
/// was built at all; `xfail` is an unmet `//! xfail` case, which does not
/// fail the run.
/// `state` is what a `--state=auto` executable ran (`rt.auto`'s
/// `--vera-state` line): 4-state throughout, 2-state after a 4-state
/// start, or that and then a 4-state rerun.
const NativeVerdict = struct { pass: bool, fallback: ?[]const u8, refused: bool = false, xfail: bool = false, state: RunState = .four };
const RunState = enum { four, two, rerun };

/// `nativeCase` under `//! xfail`, with `digitalVerdict`'s algebra.
fn nativeVerdict(arena: Allocator, io: Io, vera_exe: []const u8, flags: []const []const u8, snapshot: bool, case: []const u8, w: *Io.Writer) !NativeVerdict {
    const src = try std.fmt.allocPrint(arena, "{s}/{s}.v", .{ options.fixture_root, case });
    const xfail = harness.digitalXfail(try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20))) orelse
        return nativeCase(arena, io, vera_exe, flags, snapshot, case, w);
    if (xfail.len == 0) {
        try w.print("FAIL {s}: `//! xfail` names no reason\n", .{case});
        return .{ .pass = false, .fallback = null };
    }
    var detail: Io.Writer.Allocating = .init(arena);
    var v = try nativeCase(arena, io, vera_exe, flags, snapshot, case, &detail.writer);
    if (v.pass) {
        try w.print("FAIL {s}: XPASS — marked `//! xfail`, but VerA now does what the fixture says.\n" ++
            "  Delete the `//! xfail` line.\n", .{case});
        v.pass = false;
        return v;
    }
    try w.print("XFAIL {s}: known: {s}\n", .{ case, xfail });
    v.xfail = true;
    return v;
}
const NativeSlot = struct { verdict: NativeVerdict = .{ .pass = false, .fallback = null }, output: []const u8 = "" };

fn nativeDevices(gpa: Allocator, io: Io, exe: []const u8, flags: []const []const u8, snapshot: bool, all: []const []const u8, filter: ?[]const u8, w: *Io.Writer) !u8 {
    var picked: std.ArrayList([]const u8) = .empty;
    defer picked.deinit(gpa);
    for (all) |c| if (filter == null or std.mem.indexOf(u8, c, filter.?) != null) try picked.append(gpa, c);
    if (picked.items.len == 0) {
        try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    const slots = try gpa.alloc(NativeSlot, picked.items.len);
    defer gpa.free(slots);
    @memset(slots, .{});
    var job: NativeJob = .{ .gpa = gpa, .io = io, .vera_exe = exe, .flags = flags, .snapshot = snapshot, .cases = picked.items, .slots = slots };
    var group: Io.Group = .init;
    const jobs = harness.defaultJobs();
    var hands: usize = 0;
    while (hands < jobs) : (hands += 1) group.concurrent(io, NativeJob.work, .{&job}) catch break;
    if (hands == 0) job.work();
    try group.await(io);

    var failed: usize = 0;
    var xfailed: usize = 0;
    var fell: usize = 0;
    var refused: usize = 0;
    var twos: usize = 0;
    var reruns: usize = 0;
    for (picked.items, slots) |case, s| {
        try w.writeAll(s.output);
        switch (s.verdict.state) {
            .four => {},
            .two => twos += 1,
            .rerun => reruns += 1,
        }
        if (s.verdict.state != .four) try w.print("AUTO2 {s}\n", .{case});
        if (s.verdict.state == .rerun) try w.print("RERUN {s}\n", .{case});
        if (s.verdict.xfail) {
            xfailed += 1;
        } else if (!s.verdict.pass) failed += 1;
        if (s.verdict.refused) {
            refused += 1;
        } else if (s.verdict.fallback) |why| {
            fell += 1;
            try w.print("FALLBACK {s}: {s}\n", .{ case, why });
        } else if (s.verdict.pass) try w.print("NATIVE {s}\n", .{case});
    }
    try w.print(
        "devices --native: {d}/{d} cases behave as they say they do; {d} native, " ++
            "{d} through the embedded interpreter, {d} refused before any executable",
        .{ picked.items.len - failed - xfailed, picked.items.len, picked.items.len - fell - refused, fell, refused },
    );
    if (xfailed != 0) try w.print("; {d} XFAIL (a known gap, not a pass)", .{xfailed});
    try w.print("; --state=auto turned 2-state in {d} (AUTO2), of which {d} reran 4-state (RERUN)\n", .{ twos + reruns, reruns });
    for (slots) |s| {
        gpa.free(s.output);
        if (s.verdict.fallback) |why| gpa.free(why);
    }
    return if (failed == 0) 0 else 1;
}

/// `digitalCase` through the executable. A rejection may come from `vera
/// --emit-exe` (the shared elaboration) or from the executable at run time;
/// either way its stderr is judged, the build's and the run's together.
fn nativeCase(arena: Allocator, io: Io, vera_exe: []const u8, flags: []const []const u8, snapshot: bool, case: []const u8, w: *Io.Writer) !NativeVerdict {
    const src = try std.fmt.allocPrint(arena, "{s}/{s}.v", .{ options.fixture_root, case });
    const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
    const work = try std.fmt.allocPrint(arena, "native/{s}", .{case});
    try Io.Dir.cwd().createDirPath(io, work);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ vera_exe, "--emit-exe", "--work-dir", work });
    try argv.appendSlice(arena, flags);
    try argv.append(arena, src);
    try argv.appendSlice(arena, try harness.digitalArgs(arena, source, std.fs.path.dirname(src).?));
    const built = try capture(arena, io, argv.items);
    const two_state = std.mem.eql(u8, flags[0], "--two-state");
    const fallback: ?[]const u8 = if (std.mem.indexOf(u8, built.stderr, "not native (")) |at| blk: {
        const rest = built.stderr[at + "not native (".len ..];
        break :blk rest[0 .. std.mem.indexOf(u8, rest, ")\n") orelse rest.len];
    } else null;
    const negative = harness.digitalNegative(source);
    if (two_state and built.exit != 0) if (std.mem.indexOf(u8, built.stderr, "carries meaning: ")) |at| {
        const rest = built.stderr[at + "carries meaning: ".len ..];
        return .{ .pass = true, .fallback = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len] };
    };
    if (built.exit != 0) {
        if (negative and harness.digitalRejectionMatches(source, built.exit, built.stderr)) return .{ .pass = true, .fallback = null, .refused = true };
        try w.print("FAIL {s}: vera --emit-exe exited {d}\n{s}\n", .{ case, built.exit, built.stderr });
        return .{ .pass = false, .fallback = fallback };
    }
    if (!two_state and nativeRequired(source)) if (fallback) |why| {
        try w.print("FAIL {s}: `// native-required` forbids interpreter fallback: {s}\n", .{ case, why });
        return .{ .pass = false, .fallback = fallback };
    };
    const bin = try Io.Dir.cwd().realPathFileAlloc(io, std.mem.trimEnd(u8, built.stdout, "\n"), arena);
    var ran = try captureIn(arena, io, if (snapshot) &.{ bin, "--vera-state", "--vera-snapshot" } else &.{ bin, "--vera-state" }, work);
    if (std.mem.indexOf(u8, ran.stderr, "vera-snapshot: ")) |at| {
        const end = std.mem.indexOfScalarPos(u8, ran.stderr, at, '\n') orelse ran.stderr.len;
        ran.stderr = try std.mem.concat(arena, u8, &.{ ran.stderr[0..at], ran.stderr[@min(end + 1, ran.stderr.len)..] });
    }
    var state: RunState = .four;
    if (std.mem.indexOf(u8, ran.stderr, "vera-state: ")) |at| {
        const end = std.mem.indexOfScalarPos(u8, ran.stderr, at, '\n') orelse ran.stderr.len;
        const line = ran.stderr[at..end];
        state = if (std.mem.indexOf(u8, line, "rerun") != null) .rerun else if (std.mem.indexOf(u8, line, "2-state") != null) .two else .four;
        ran.stderr = try std.mem.concat(arena, u8, &.{ ran.stderr[0..at], ran.stderr[@min(end + 1, ran.stderr.len)..] });
    }
    // `// native-state: 2|4|rerun` pins what the default `--state=auto` runs.
    if (flags.len == 1 and !two_state) if (pinnedState(source)) |want| if (want != state) {
        try w.print("FAIL {s}: `--state=auto` ran {t}, the fixture pins {t}\n", .{ case, state, want });
        return .{ .pass = false, .fallback = fallback, .state = state };
    };
    const stderr = try std.mem.concat(arena, u8, &.{ built.stderr, ran.stderr });
    if (negative) {
        if (harness.digitalRejectionMatches(source, ran.exit, stderr)) return .{ .pass = true, .fallback = fallback, .state = state };
        try w.print("FAIL {s}: digital rejection mismatch (exit {d})\n{s}\n", .{ case, ran.exit, stderr });
        return .{ .pass = false, .fallback = fallback, .state = state };
    }
    if (ran.exit != 0) {
        try w.print("FAIL {s}: the executable exited {d}\n{s}\n", .{ case, ran.exit, stderr });
        return .{ .pass = false, .fallback = fallback, .state = state };
    }
    if (!harness.digitalWarningsMatch(source, stderr)) {
        try w.print("FAIL {s}: successful digital run has missing warning evidence or error diagnostics\n{s}\n", .{ case, stderr });
        return .{ .pass = false, .fallback = fallback, .state = state };
    }
    if (harness.vcdExpectation(source)) |v| return .{ .pass = try vcdDiff(arena, io, w, case, work, v, two_state), .fallback = fallback, .state = state };
    const want = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/{s}.expected.txt", .{ options.fixture_root, case }), arena, .limited(1 << 20));
    if (two_state) return .{ .pass = try twoStateDiff(w, case, want, ran.stdout), .fallback = fallback, .state = state };
    return .{ .pass = try diff(w, case, want, ran.stdout), .fallback = fallback, .state = state };
}

/// A compiled-runtime regression may require native emission as well as its
/// transcript. This promise applies to normal native modes, not the separate
/// `--two-state` report which deliberately changes x/z semantics.
fn nativeRequired(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "// native-required")) return true;
    return false;
}

/// A fixture's `// native-state:` line, if it has one.
fn pinnedState(source: []const u8) ?RunState {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const word = if (std.mem.startsWith(u8, line, "// native-state: ")) line["// native-state: ".len..] else continue;
        if (std.mem.eql(u8, word, "2")) return .two;
        if (std.mem.eql(u8, word, "4")) return .four;
        if (std.mem.eql(u8, word, "rerun")) return .rerun;
    }
    return null;
}

/// A `//! expect vcd` case: the file the executable wrote in `work` against
/// the golden beside the fixture, both normalised (`harness.vcdTokens`).
/// Under `--two-state` a token may differ where the golden's shows an x or z
/// digit, `twoStateDiff`'s rule.
fn vcdDiff(arena: Allocator, io: Io, w: *Io.Writer, case: []const u8, work: []const u8, v: harness.VcdExpect, two_state: bool) !bool {
    const got_text = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ work, v.produced }), arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: the executable wrote no `{s}`\n", .{ case, v.produced });
        return false;
    };
    const dir = std.fs.path.dirname(try std.fmt.allocPrint(arena, "{s}/{s}.v", .{ options.fixture_root, case })).?;
    const want_text = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, v.golden }), arena, .limited(1 << 24));
    const got = try harness.vcdTokens(arena, got_text);
    const want = try harness.vcdTokens(arena, want_text);
    for (0..@max(got.len, want.len)) |i| {
        const g = if (i < got.len) got[i] else "<end of file>";
        const e = if (i < want.len) want[i] else "<end of file>";
        if (std.mem.eql(u8, g, e)) continue;
        if (two_state and std.mem.indexOfAny(u8, e, "xXzZ") != null) continue;
        try w.print("FAIL {s}: VCD token {d} is `{s}`, the golden has `{s}`\n", .{ case, i, g, e });
        return false;
    }
    return true;
}

/// `--native=two-state`'s judgement: every line of `got` that differs from
/// `want` (line by line) differs where `want` shows an x or z digit.
fn twoStateDiff(w: *Io.Writer, case: []const u8, want: []const u8, got: []const u8) !bool {
    var wl = std.mem.splitScalar(u8, want, '\n');
    var gl = std.mem.splitScalar(u8, got, '\n');
    var differ: u32 = 0;
    var line: u32 = 1;
    while (true) : (line += 1) {
        const a = wl.next();
        const b = gl.next();
        if (a == null and b == null) break;
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
        differ += 1;
        if (a != null and hasXz(a.?)) continue;
        try w.print("FAIL {s}: line {d} differs with no x or z in the golden\n  want: {s}\n  got:  {s}\n", .{ case, line, a orelse "(none)", b orelse "(none)" });
        return false;
    }
    if (differ != 0) try w.print("XZ {s}: {d} line(s) differ, each where the golden shows x or z\n", .{ case, differ });
    return true;
}

/// A value token of `line` holds an x or z digit: a run of hex digits,
/// `_`, x and z with at least one x or z (§17.1.1.3).
fn hasXz(line: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \t=:,;()[]{}'\"/");
    while (it.next()) |t| {
        var xz = false;
        for (t) |c| switch (c) {
            'x', 'X', 'z', 'Z' => xz = true,
            '0'...'9', 'a'...'f', 'A'...'F', '_' => {},
            else => break,
        } else if (xz) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// `--fuzz N`: N random expressions, each printed by `vera --run` and by the
// native executable of the same source; the two transcripts must be equal
// and the executable must be native. The fixtures pin the §5.5 context
// rules at the points someone thought of; this is the check on the rule
// being implemented twice (`exec.evalContext`, `emit_expr.value`).
//
//   zig build test-devices -- --fuzz 2000
// ---------------------------------------------------------------------------

const FuzzVar = struct { width: u32, signed: bool };
const fuzz_widths = [_]u32{ 1, 2, 3, 7, 8, 13, 16, 31, 32, 33, 48, 63, 64, 65, 100, 128, 129 };
const fuzz_vars = 12;
const fuzz_per_file = 400;

fn fuzz(init: std.process.Init, vera_exe: []const u8, count: u32) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, gpa);
    defer gpa.free(exe);
    const work = options.work_root ++ "/fuzz";
    try Io.Dir.cwd().createDirPath(io, work);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed_1364);
    const rand = prng.random();
    var done: u32 = 0;
    var file: u32 = 0;
    var failed = false;
    var twos: u32 = 0;
    var reruns: u32 = 0;
    while (done < count) : (file += 1) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        const n = @min(fuzz_per_file, count - done);
        const late = file % 2 == 1;
        const src = try fuzzSource(a, rand, n, late);
        const path = try std.fmt.allocPrint(a, "{s}/fuzz{d}.v", .{ work, file });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
        const want = try capture(a, io, &.{ exe, "--run", path });
        const built = try capture(a, io, &.{ exe, "--emit-exe", "--work-dir", work, path });
        if (want.exit != 0 or built.exit != 0) {
            try w.print("FAIL {s}: --run exited {d}, --emit-exe exited {d}\n{s}{s}\n", .{ path, want.exit, built.exit, want.stderr, built.stderr });
            return 1;
        }
        if (std.mem.indexOf(u8, built.stderr, "not native (") != null) {
            try w.print("FAIL {s}: not native\n{s}\n", .{ path, built.stderr });
            return 1;
        }
        if (late and std.mem.indexOf(u8, built.stderr, "4-state: ") != null) {
            try w.print("FAIL {s}: known operands, yet `--state=auto` built it 4-state\n{s}\n", .{ path, built.stderr });
            return 1;
        }
        const got = try capture(a, io, &.{ std.mem.trimEnd(u8, built.stdout, "\n"), "--vera-state" });
        if (std.mem.indexOf(u8, got.stderr, "rerun") != null) reruns += 1 else if (std.mem.indexOf(u8, got.stderr, "2-state") != null) twos += 1;
        if (!std.mem.eql(u8, want.stdout, got.stdout)) {
            failed = true;
            var wl = std.mem.splitScalar(u8, want.stdout, '\n');
            var gl = std.mem.splitScalar(u8, got.stdout, '\n');
            while (wl.next()) |x| {
                const y = gl.next() orelse "";
                if (!std.mem.eql(u8, x, y)) try w.print("FAIL {s}: --run `{s}`, native `{s}`\n", .{ path, x, y });
            }
        }
        done += n;
    }
    try w.print("fuzz: {d} expressions in {d} files, native {s} --run; --state=auto ran 2-state in {d} files, of which it reran {d} 4-state\n", .{ count, file, if (failed) "DIFFERS from" else "equals", twos + reruns, reruns });
    return if (failed) 1 else 0;
}

/// One design: `fuzz_vars` random four-state operands, then `n` lines, each
/// one random expression printed self-determined or through an assignment
/// to a random-width target (so its context width and signedness vary).
/// `late`: every operand and literal known, and the lines one tick after
/// them, so `--state=auto` computes them in its 2-state phase, where an x
/// an operator makes is printed as 4-state prints it and storing one reruns
/// the design 4-state.
fn fuzzSource(a: Allocator, rand: std.Random, n: u32, late: bool) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const o = &out.writer;
    var vars: [fuzz_vars]FuzzVar = undefined;
    try o.writeAll("module fuzz;\n");
    for (&vars, 0..) |*v, i| {
        v.* = .{ .width = fuzz_widths[rand.uintLessThan(usize, fuzz_widths.len)], .signed = rand.boolean() };
        try o.print("  reg {s}[{d}:0] v{d};\n", .{ if (v.signed) "signed " else "", v.width - 1, i });
    }
    try o.writeAll("  reg [7:0] mem [2:5];\n");
    for (fuzz_widths, 0..) |tw, i| try o.print("  reg {s}[{d}:0] t{d};\n", .{ if (i % 2 == 0) "signed " else "", tw - 1, i });
    try o.writeAll("  initial begin\n");
    // Half the operands fully known, or arithmetic would almost always see
    // an x and never reach its known-value path.
    for (vars, 0..) |v, i| try o.print("    v{d} = {f};\n", .{ i, FuzzBits{ .rand = rand, .width = v.width, .known = late or i % 2 == 0 } });
    for (2..6) |i| try o.print("    mem[{d}] = {f};\n", .{ i, FuzzBits{ .rand = rand, .width = 8, .known = late } });
    if (late) {
        for (fuzz_widths, 0..) |_, i| try o.print("    t{d} = 0;\n", .{i});
        try o.writeAll("    #1;\n");
    }
    for (0..n) |line| {
        var g: FuzzGen = .{ .rand = rand, .vars = &vars, .out = o, .known = late };
        // `%d` of more than 64 bits is refused by both engines alike, so it
        // is asked of an expression only when its width is at most 64. A
        // late design stores only in its last tenth: storing an x ends the
        // 2-state phase for every line after it.
        if (rand.boolean() or (late and line < n - n / 10)) {
            var e: Io.Writer.Allocating = .init(a);
            g.out = &e.writer;
            const ew = try g.expr(3);
            try o.print("    $display(\"%b {s}\", {s}, {s});\n", .{ if (ew <= 64 and rand.boolean()) "%d" else "%h", e.written(), e.written() });
        } else {
            const t = rand.uintLessThan(usize, fuzz_widths.len);
            try o.print("    t{d} = ", .{t});
            _ = try g.expr(3);
            try o.print(";\n    $display(\"%b {s}\", t{d}, t{d});\n", .{ if (fuzz_widths[t] <= 64) "%d" else "%h", t, t });
        }
    }
    try o.writeAll("  end\nendmodule\n");
    return out.written();
}

/// A sized binary literal of `width` random bits, mostly known.
const FuzzBits = struct {
    rand: std.Random,
    width: u32,
    known: bool = false,
    pub fn format(self: FuzzBits, o: *Io.Writer) Io.Writer.Error!void {
        try o.print("{d}'b", .{self.width});
        for (0..self.width) |_| try o.writeByte(if (!self.known and self.rand.uintLessThan(u8, 8) == 0) "xz"[self.rand.uintLessThan(u8, 2)] else "01"[self.rand.uintLessThan(u8, 2)]);
    }
};

/// Random expressions over one- and multi-word operands, every one of which
/// the native executable takes.
const FuzzGen = struct {
    rand: std.Random,
    vars: []const FuzzVar,
    out: *Io.Writer,
    /// No x or z literal.
    known: bool = false,

    /// Writes one expression; returns its self-determined width.
    fn expr(g: *FuzzGen, depth: u32) Io.Writer.Error!u32 {
        const o = g.out;
        const r = g.rand;
        if (depth == 0 or r.uintLessThan(u8, 5) == 0) return g.leaf();
        switch (r.uintLessThan(u8, 12)) {
            0 => {
                try o.writeAll(([_][]const u8{ "-", "~", "!", "&", "|", "^", "~&", "~^", "+" })[r.uintLessThan(usize, 9)]);
                try o.writeByte('(');
                const wa = try g.expr(depth - 1);
                try o.writeByte(')');
                return wa;
            },
            1, 2, 3 => {
                try o.writeByte('(');
                const wa = try g.expr(depth - 1);
                try o.writeAll(([_][]const u8{ " + ", " - ", " * ", " / ", " % ", " & ", " | ", " ^ ", " ~^ " })[r.uintLessThan(usize, 9)]);
                const wb = try g.expr(depth - 1);
                try o.writeByte(')');
                return @max(wa, wb);
            },
            4 => {
                try o.writeByte('(');
                _ = try g.expr(depth - 1);
                try o.writeAll(([_][]const u8{ " == ", " != ", " === ", " !== ", " < ", " <= ", " > ", " >= ", " && ", " || " })[r.uintLessThan(usize, 10)]);
                _ = try g.expr(depth - 1);
                try o.writeByte(')');
                return 1;
            },
            5 => {
                try o.writeByte('(');
                const wa = try g.expr(depth - 1);
                try o.writeAll(([_][]const u8{ " << ", " >> ", " <<< ", " >>> ", " ** " })[r.uintLessThan(usize, 5)]);
                if (r.boolean()) try o.print("{d}", .{r.uintLessThan(u32, 70)}) else _ = try g.expr(depth - 1);
                try o.writeByte(')');
                return wa;
            },
            6 => {
                try o.writeByte('(');
                _ = try g.expr(depth - 1);
                try o.writeAll(" ? ");
                const wa = try g.expr(depth - 1);
                try o.writeAll(" : ");
                const wb = try g.expr(depth - 1);
                try o.writeByte(')');
                return @max(wa, wb);
            },
            7 => {
                const i = r.uintLessThan(usize, g.vars.len);
                const j = r.uintLessThan(usize, g.vars.len);
                try o.print("{{v{d}, v{d}}}", .{ i, j });
                return g.vars[i].width + g.vars[j].width;
            },
            8 => {
                const i = r.uintLessThan(usize, g.vars.len);
                const n = 1 + r.uintLessThan(u32, 4);
                try o.print("{{{d}{{v{d}}}}}", .{ n, i });
                return n * g.vars[i].width;
            },
            9 => {
                try o.writeAll(if (r.boolean()) "$signed(" else "$unsigned(");
                const wa = try g.expr(depth - 1);
                try o.writeByte(')');
                return wa;
            },
            10 => {
                const i = r.uintLessThan(usize, g.vars.len);
                const vw = g.vars[i].width;
                if (r.boolean()) {
                    try o.print("v{d}[", .{i});
                    try g.index();
                    try o.writeByte(']');
                    return 1;
                }
                const lo = r.uintLessThan(u32, vw);
                const hi = lo + r.uintLessThan(u32, vw - lo);
                try o.print("v{d}[{d}:{d}]", .{ i, hi, lo });
                return hi - lo + 1;
            },
            else => {
                try o.writeAll("mem[");
                try g.index();
                try o.writeByte(']');
                return 8;
            },
        }
    }

    /// A leaf of at most 64 bits: the engine refuses a wider index.
    fn index(g: *FuzzGen) Io.Writer.Error!void {
        while (true) {
            const cut = g.out.end;
            if (try g.leaf() <= 64) return;
            g.out.end = cut;
        }
    }

    fn leaf(g: *FuzzGen) Io.Writer.Error!u32 {
        const o = g.out;
        const r = g.rand;
        switch (r.uintLessThan(u8, 6)) {
            0 => {
                try o.print("{d}", .{r.uintLessThan(u32, 300)});
                return 32;
            },
            1 => {
                if (g.known) try o.writeAll(([_][]const u8{ "'b1", "-4'sd3", "'sd7", "'h5a" })[r.uintLessThan(usize, 4)]) else try o.writeAll(([_][]const u8{ "'bx", "'bz", "'hx1", "'b1", "-4'sd3", "4'sb1x01", "'sd7", "3'bz0x" })[r.uintLessThan(usize, 8)]);
                return 32;
            },
            else => {
                const i = r.uintLessThan(usize, g.vars.len);
                try o.print("v{d}", .{i});
                return g.vars[i].width;
            },
        }
    }
};

// orchestrator.zig's claim: writing a tree already on disk touches nothing.
test "a second writeTree writes no bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const src = try genSource(gpa, .contrib, 1);
    defer gpa.free(src);
    var result = try vera.compileSourceOpts(gpa, src, .lint, .{});
    defer result.deinit();
    _ = try result.generateDevice();

    const work = options.work_root ++ "/benchmark/rewrite-selftest";
    _ = try rewrite(io, gpa, result.device, work);
    try std.testing.expectEqual(@as(usize, 0), try rewrite(io, gpa, result.device, work));
}

// Every point of every axis, in `zig build test`, so a size regression in the
// emitted device fails the gate. The n = 4096 points are also the renderer's
// stack-depth check.
test "generated shapes emit the expected device and MIR size" {
    for (std.enums.values(Axis)) |axis| {
        for (0..5) |i| _ = try checkShape(std.testing.allocator, axis, i);
    }
}

test "gen emits every axis it is asked for" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try gen(&aw.writer, 3, 2, 4);
    const text = aw.written();

    // The axes are independent: asking for 3 contributions must not also change
    // how many instances or values come out.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "I(a, b) <+"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "    real v"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, "  bench_leaf i"));
    // The chain terminates in the contribution, so nothing generated is dead.
    try std.testing.expect(std.mem.indexOf(u8, text, "gain * v1 * 1.0;") != null);
}
