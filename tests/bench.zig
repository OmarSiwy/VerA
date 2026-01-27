//! The one runner binary and the one suite step, `zig build benchmark`: every
//! fixture through VerA at full depth — compile, build the testbench, run it,
//! judge the `ok=` columns — and time it.
//!
//!   zig build benchmark                         # the suite, timed
//!   zig build benchmark -- ch04                 # only paths matching `ch04`
//!   zig build benchmark -- --strict             # unasserted and xfail FAIL
//!   zig build benchmark -- --fixture-root=tests/pending   # the tree meant to fail
//!   zig build benchmark -- --coverage           # LRM clauses cited and uncited
//!   zig build benchmark -- --against-openvaf    # the head-to-head
//!   zig build benchmark -- --sweep              # the generated size sweep instead
//!   zig build benchmark -Doptimize=ReleaseFast  # the only number that ships
//!
//! THIS WAS FOUR STEPS — `torture`, `torture-pending`, `conformance`,
//! `benchmark` — over one executable with a mode argument. They are one because
//! they were always one measurement of one suite: the same fixtures, the same
//! judge (`tests/harness.zig`), the same `suite_options`. A run that scores VerA
//! and a run that scores OpenVAF and a run that times VerA could each drift into
//! a different fixture set, a different filter or a different verdict algebra
//! while all three still printed a number. Now they cannot: there is one walk.
//! `torture-pending` was that same run with `--fixture-root=tests/pending`, and
//! it is a flag rather than a step because the tree it walks is the only thing
//! that differed.
//!
//! ARGV[1] IS THE `vera` EXECUTABLE, from `run.addArtifactArg(exe)` — which is
//! also what makes the built binary a dependency of the run. The suite itself
//! compiles the engine IN-PROCESS and needs no binary; it is here because the
//! `devices` run of this same executable spawns it, and because the spawn floor
//! the head-to-head reports is measured by spawning it.
//!
//! ---------------------------------------------------------------------------
//! WHAT IS TIMED, AND WHY IT IS NOT THE WHOLE SUITE RUN. The depth pass builds
//! a native testbench per fixture, which is a `zig build-exe` — seconds of the
//! Zig compiler's wall clock that are not VerA's. So the depth pass produces the
//! VERDICTS, and a second, SEQUENTIAL pass produces the TIMES, and the thing it
//! times is one accept/reject compilation: source in, device text out. That is
//! exactly the work a foreign compiler is given, so the two columns are the same
//! question. Two passes, because a parallel run measures the machine's load and
//! a sequential suite run would take an hour.
//!
//! MIN-OF-N. Every source of noise on a shared machine is additive — a preempted
//! run is slower than a clean one and never faster — so the minimum is the
//! closest sample to "what this code costs", where a mean would mostly measure
//! the load average of whoever ran it. The distribution is reported over
//! FIXTURES, which is the variation that is about the compiler.
//!
//! **RELEASEFAST IS THE NUMBER THAT MEANS ANYTHING**, because it is what ships.
//! `zig build benchmark` takes the tree's default `-Doptimize`, which is
//! **Debug**, and Debug is ~8× slower (MEASURED on one tree, same commit:
//! `lint` over the fixture set, 1959.5 ms Debug vs 247.0 ms ReleaseFast). A
//! whole night of figures was once quoted as if it were the shipping number
//! because the output did not say which it was, so the mode is now a `#` line at
//! the head of the report, from `@import("builtin").mode` — the compiled-in
//! truth, not a flag the runner can be lied to about.
//!
//! That label is honest only because `build.zig` gives this module and the
//! `vera` module it imports the SAME `optimize`: `-O` is a per-module flag, so a
//! bench built ReleaseFast against a Debug engine would print `ReleaseFast` over
//! a Debug measurement. Which is also why this step does not silently force
//! ReleaseFast on itself.
//!
//! NOTHING IS ASSERTED INSIDE THE TIMER. The deterministic claims this file owns
//! — that a second `writeTree` writes 0 bytes, and that a generated shape has
//! the `device.text.len`, `mir.defs.len` and `mir.insts.len` the table says —
//! are `test` blocks at the foot of the file, so `zig build test` checks them in
//! milliseconds and a size regression cannot wait for somebody to remember to
//! run the bench. A wall-clock number cannot be asserted at all: it is a
//! property of the machine, not of the compiler.
//!
//! NO MACHINE-READABLE SIDE CHANNEL, for the reason harness.zig gives: a second
//! output format is a second thing to keep true. One TSV-ish table on stdout,
//! one row per fixture in the walk's sorted order, so comparing two runs is
//! `diff` and nothing else. The prose report — which fixture failed and why —
//! stays on stderr where the suite has always written it. There is no committed
//! artifact and no `--bless`: the timings are the machine's and belong to
//! whoever ran it.
//!
//! ---------------------------------------------------------------------------
//! `--sweep` — the generated size sweep, and the reason it is still here. `gen`
//! emits a .va whose size is a parameter, and each of its three axes is swept
//! 1 → 4096 with the other two pinned at 1. A slope is what settles a scope
//! argument: "this scan is O(n²) and n is a netlist" and "this scan is flat to
//! 4096" are the same wall-clock number at n = 8 and opposite conclusions, and
//! only the sweep tells them apart. It is a flag and not the default because the
//! fixtures are the workload the project's scope guarantees exists.
//!
//! FOUR PHASES, ON SEAMS THAT ALREADY EXISTED. The sweep adds no API to the
//! engine and no hook inside it — it calls the same four entry points an
//! embedder calls, in the same order `root.zig`'s pipeline does:
//!
//!   pp        `Preprocessor.process`                          text → text
//!   lint      `vera.compileSourceOpts(gpa, src, .lint, .{})`  text → MIR
//!   codegen   `result.generateDevice()`                       MIR → device.zig
//!   rewrite   `orchestrator.writeTree` a SECOND time          device.zig → 0 bytes
//!
//! EACH ROW IS A PREFIX OF THE NEXT, not a slice of it, because each stage needs
//! the one above it and there is no seam that resumes a compilation from the
//! middle. So a row is "everything up to and including this", and the cost OF a
//! stage is a subtraction the reader does: `lint - pp` is lex+parse+lower+prove,
//! `codegen - lint` is stage 6. Reporting them cumulatively is what keeps the
//! bench free of an engine hook — the alternative is four entry points that
//! exist for no reason but to be timed, which is the API the doctrine deletes.

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const torture = @import("torture.zig");
const external = @import("external.zig");
const options = @import("suite_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    // The `vera` binary, from `run.addArtifactArg(exe)`.
    const vera_exe = args.next() orelse return usage(init.io, "missing the vera executable path");
    // `devices` is the ONE remaining word in argument position 2, and it is not
    // a mode of the benchmark: it is the other run of this executable, the one
    // on `test`, whose cases need the BINARY rather than the engine. Everything
    // else is a benchmark argument, including a bare filter word.
    const first = args.next();
    if (first) |a| if (std.mem.eql(u8, a, "devices")) return devices(init, vera_exe, &args);
    return benchmark(init, vera_exe, first, &args);
}

fn usage(io: Io, why: []const u8) !u8 {
    var buf: [256]u8 = undefined;
    var e = Io.File.stderr().writer(io, &buf);
    try e.interface.print(
        "suite: {s}\nusage: <vera-exe> [devices | benchmark args]\n",
        .{why},
    );
    try e.interface.flush();
    return 2;
}

/// `root.zig` does not re-export `Mir` (wave 12 privatised it, and decision 4
/// says a loud compile error is the desired signal). The type is still
/// reachable through the result that carries it, which is the seam an embedder
/// already has — so this needs no new `pub`.
const Mir = @typeInfo(@FieldType(vera.CompileResult, "mir")).pointer.child;

/// N for the sweep and for the spawn floor, and the estimator is the MIN over
/// it. The min is right because every source of noise on a shared machine is
/// additive — a preempted run is slower than a clean one and never faster — so
/// the minimum is the closest sample to "what this code costs", where a mean
/// would mostly measure the load average of whoever ran it.
const reps = 25;

/// N per FIXTURE, which is smaller for a reason that is about cost and not
/// about statistics: 1323 fixtures times N compilations, and with
/// `--against-openvaf` times N subprocess spawns of a compiler that takes tens
/// of milliseconds. 25 there would be twenty minutes of spawning. The min is
/// still the estimator, and the distribution the report prints is over
/// FIXTURES — 1323 samples of "what a compilation costs" — which is the
/// variation that is about the compiler rather than about the machine.
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
/// shape, in `sweep` order. These are pure functions of the source, so they are
/// the same on every machine and in every optimize mode; a change here is a
/// change in what VerA emits, and it must be explained in the commit that
/// moves it.
///
/// The zero-count shift identity adds 130 bytes to the shared emitted helper;
/// these shapes have unchanged MIR and runtime signatures.
/// MEASURED on this tree, not predicted: the numbers came out of this bench.
const Shape = struct { device: usize, defs: usize, insts: usize };
const expected = std.enums.directEnumArrayDefault(Axis, [sweep.len]Shape, null, 0, .{
    .contrib = .{
        .{ .device = 20758, .defs = 8, .insts = 5 },
        .{ .device = 21116, .defs = 35, .insts = 26 },
        .{ .device = 23859, .defs = 258, .insts = 194 },
        .{ .device = 46224, .defs = 2050, .insts = 1538 },
        .{ .device = 228521, .defs = 16386, .insts = 12290 },
    },
    .vals = .{
        .{ .device = 20758, .defs = 8, .insts = 5 },
        .{ .device = 20940, .defs = 24, .insts = 19 },
        .{ .device = 22396, .defs = 136, .insts = 131 },
        .{ .device = 34044, .defs = 1032, .insts = 1027 },
        .{ .device = 127228, .defs = 8200, .insts = 8195 },
    },
    .inst = .{
        .{ .device = 20758, .defs = 8, .insts = 5 },
        .{ .device = 21962, .defs = 50, .insts = 40 },
        .{ .device = 31810, .defs = 386, .insts = 320 },
        .{ .device = 112306, .defs = 3074, .insts = 2560 },
        .{ .device = 769810, .defs = 24578, .insts = 20480 },
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

/// What one compilation's MIR actually costs in bytes, by column.
///
/// `mir.zig` is a set of `MultiArrayList`s, so a row costs the SUM of its
/// field sizes and not `@sizeOf(Row)` (25 vs 28 for `InstRow`, 9 vs 16 for
/// `ValueRow` — computed by `capacityInBytes` below rather than asserted, so it
/// tracks the struct). The two dedup maps and the interner are excluded on
/// purpose: they are build-time scratch that `deinit` drops, and no proposed
/// layout change touches them. What is counted is exactly the surface an
/// Air-shaped rewrite would move.
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

const Phase = enum { pp, lint, codegen, rewrite };

/// `bytes` is what the phase HANDLED, and it differs per phase because the
/// phases do: preprocessed text out of `pp`, the same text in for `lint`,
/// device text out of `codegen`, and bytes actually hit on disk for `rewrite`
/// — which is the one that is asserted, because it must be 0.
const Sample = struct { min_ns: u64, bytes: u64 };

/// Run `phase` over one generated source and return the bytes it handled.
///
/// `keep` receives the `CompileResult` instead of freeing it, so `measure` can
/// read the clock BEFORE the teardown runs — a compilation arena is one
/// `munmap` but a device text is a `free` of up to a megabyte, and timing it
/// would attribute the allocator's cost to codegen. It must already have
/// capacity for `reps`, because a reallocation inside the timed region would be
/// the very thing it exists to keep out.
///
/// `doNotOptimizeAway` on the two values a release build could otherwise prove
/// unused (`result.mir`, the device length) is what stops it from deleting the
/// work being timed.
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
        const text = try vera.Preprocessor.process(arena.allocator(), source, .{ .bag = &bag });
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

    // The rewrite phase: prime the tree, then write it AGAIN, which is the
    // no-op recompile the whole incremental story rests on. That the second
    // call writes 0 bytes is a deterministic claim, so it is a `test` at the
    // foot of this file and NOT an assert in here — an `expectEqual` under
    // the clock measures itself and fails a timing run for a reason that is
    // not about timing.
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

/// Nanoseconds since `t0` on the monotonic clock. `std.time.Timer` no longer
/// exists on 0.16 (std/time.zig is unit constants and `epoch` now), and
/// `.awake` is the CLOCK_MONOTONIC it wrapped.
fn elapsed(io: Io, t0: Io.Timestamp) u64 {
    const ns = t0.durationTo(.now(io, .awake)).nanoseconds;
    return @intCast(@max(ns, 0));
}

/// The mode the ENGINE was compiled in, and therefore the only thing that makes
/// a `min_ns` mean something. `builtin.mode` is this module's own `-O`, which
/// `build.zig` keeps equal to the `vera` module's; see the header.
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
    var against_openvaf = false;
    var do_sweep = false;
    var a = first;
    while (a) |arg| : (a = args.next()) {
        if (harness.takeArg(&cfg, arg)) continue;
        if (std.mem.eql(u8, arg, "--against-openvaf")) against_openvaf = true //
        else if (std.mem.eql(u8, arg, "--sweep")) do_sweep = true //
        else if (std.mem.startsWith(u8, arg, "-")) {
            var e_buf: [256]u8 = undefined;
            var e = Io.File.stderr().writer(io, &e_buf);
            try e.interface.print("benchmark: unknown flag `{s}`\n", .{arg});
            try e.interface.flush();
            return 2;
        } else cfg.filter = arg;
    }
    // `--fixture-root=tests/pending` is how a human writes it, and a relative
    // root would break the foreign compiler: its prelude wrapper lives in the
    // scratch tree and `\`include`s the fixture from there, where a path
    // relative to the repository root means nothing. Resolved once, here, so
    // both compilers walk the same absolute paths.
    cfg.root = std.fs.path.resolve(arena, &.{cfg.root}) catch cfg.root;

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (do_sweep) return sweepReport(gpa, io, arena, w);

    // Asked ONCE, before the walk: a missing compiler must fail in the first
    // second and not after the depth pass has spent twenty minutes.
    var ov: ?external.Ctx = if (against_openvaf) (try probe(io, arena)) orelse return 2 else null;

    // `--coverage` is a question about the FIXTURES — which LRM clauses they
    // cite — so it compiles nothing and there is nothing to time or compare.
    if (cfg.coverage) return harness.run(init, torture.compiler(&cfg.fixture_opt), cfg, null);

    // THE DEPTH PASS: VerA compiles, builds a testbench, runs it and reads the
    // `ok=` columns. It owns the exit code, because it is the only pass that
    // can fail — a wall clock has no verdict.
    var depth: harness.Counts = .{};
    const code = try harness.run(init, torture.compiler(&cfg.fixture_opt), cfg, &depth);

    try report(gpa, io, arena, w, vera_exe, cfg, depth, if (ov) |*c| c else null);
    return code;
}

/// Is the foreign compiler there at all?
///
/// Spawned once with no file, and only `FileNotFound` and the shell's
/// command-not-found status are read as absence: `external.cc` is a whole
/// command line, so with `timeout 30 openvaf-r …` the process that exists is `timeout`
/// and the one that does not reports itself as exit 127, one level down.
fn probe(io: Io, arena: Allocator) !?external.Ctx {
    const argv = try external.splitCommand(arena, external.cc);
    var e_buf: [1024]u8 = undefined;
    var e = Io.File.stderr().writer(io, &e_buf);

    var missing: ?[]const u8 = null;
    if (std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    })) |spawned| {
        var child = spawned;
        const term: std.process.Child.Term = child.wait(io) catch .{ .exited = 0 };
        switch (term) {
            .exited => |c| if (c == 127) {
                missing = "exit 127 — the command ran but named a program that is not there";
            },
            else => {},
        }
    } else |err| {
        missing = @errorName(err);
    }

    if (missing) |why| {
        try e.interface.print(
            \\benchmark: --against-openvaf cannot run `{s}`: {s}
            \\  That command line is `cc` in tests/external.zig, and it must name a
            \\  Verilog-A compiler on PATH. `nix develop` provides openvaf-r
            \\  (nix/openvaf.nix), or edit it to any compiler that takes a .va path and
            \\  exits nonzero when it refuses one.
            \\  Nothing else is affected: without --against-openvaf this step never
            \\  spawns a foreign compiler.
            \\
        , .{ external.cc, why });
        try e.interface.flush();
        return null;
    }
    return .{ .argv = argv };
}

// ---------------------------------------------------------------------------
// The head-to-head
//
// Published, so it must not flatter either side. Three rules hold it to that:
//
//   1. THE COMPARABLE UNIT. Both compilers are given the same fixture bytes and
//      asked the same question — accept what the LRM says must compile, refuse
//      what it says must not — and both are scored by `harness.judge`, the same
//      function called twice. VerA's `ok=` columns are a question OpenVAF was
//      never asked, so they are printed in a section marked VerA-only and never
//      as a score anyone lost.
//   2. THE SPAWN COST IS NAMED. VerA runs in-process; OpenVAF is a subprocess,
//      and fork+exec+dynamic-link is in its number and in nothing of VerA's. So
//      the floor is measured separately and VerA is reported BOTH ways.
//   3. OUT OF SCOPE IS NOT A FAILURE. OpenVAF is Verilog-A; a large share of
//      these fixtures are Verilog-AMS, which Annex C explicitly keeps out of the
//      subset. Those are `n/a`, counted and reported as such.
// ---------------------------------------------------------------------------

/// Did the compiler do what the fixture says? `n_a` is not a verdict about the
/// compiler at all — see `scopeOf`.
const Agree = enum {
    yes,
    no,
    /// It died instead of answering. Not a refusal, however it exited.
    crash,
    n_a,

    fn text(self: Agree) []const u8 {
        return switch (self) {
            .yes => "1",
            .no => "0",
            .crash => "crash",
            .n_a => "n/a",
        };
    }
};

const Row = struct {
    vera_ns: u64,
    vera_ok: Agree,
    scope: Scope,
    ov_ns: ?u64 = null,
    ov_ok: Agree = .n_a,
};

fn report(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    w: *Io.Writer,
    vera_exe: []const u8,
    cfg: harness.Config,
    depth: harness.Counts,
    ov: ?*external.Ctx,
) !void {
    const fixtures = try harness.collect(arena, io, cfg.root, cfg.filter);
    if (fixtures.len == 0) return;

    // The foreign compiler's own FAIL prose goes where the suite's report has
    // always gone. VerA's accept/reject prose is DISCARDED: the depth pass
    // above already printed a strictly stronger report of the same fixtures,
    // and printing it twice would double every failure.
    var err_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &err_buf);
    const ew = &stderr.interface;
    defer ew.flush() catch {};
    var sink: [256]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&sink);

    const spawn_ns = spawnFloor(io, vera_exe);

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
    if (ov != null) try w.print(
        \\# THE TWO NUMBERS ARE NOT THE SAME KIND OF MEASUREMENT. vera_ns is
        \\#   IN-PROCESS: no fork, no exec, no process start-up, because that is how a
        \\#   simulator embeds VerA. ov_ns is a SUBPROCESS and contains all of it,
        \\#   inseparably — nothing here can subtract a foreign binary's start-up from
        \\#   its own compile.
        \\# START-UP: {d} ns, the min of {d} spawns of the built `vera` binary with no
        \\#   arguments — what THIS engine costs to start as a process on this machine.
        \\#   The speed table adds it to every vera sample as `vera+spawn`, which is
        \\#   what VerA would cost invoked the way {s} is. It is a fact about the vera
        \\#   binary and NOT a floor under ov_ns: a differently linked binary of a
        \\#   different size starts at a different speed, and in a Debug build this
        \\#   number is mostly the size of a 60 MB unoptimized executable.
        \\# ov_out is what the compiler left in its scratch directory. `--dry-run`
        \\#   writes nothing by design, so `-` there means "not emitted", never
        \\#   "emitted nothing".
        \\
    , .{ spawn_ns, reps, external.cc });

    try w.writeAll("fixture\tdemands\tvera_ns\tvera_out\tvera_ok");
    if (ov != null) try w.writeAll("\tscope\tov_ns\tov_out\tov_ok");
    try w.writeAll("\n");

    const rows = try arena.alloc(Row, fixtures.len);
    var per_arena: std.heap.ArenaAllocator = .init(gpa);
    defer per_arena.deinit();

    for (fixtures, rows) |f, *row| {
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
        const vera_ok: Agree = if (try harness.judge(
            gpa,
            io,
            pa,
            torture.acceptRejectCompiler(),
            f,
            false,
            &discard.writer,
        ) == .pass) .yes else .no;

        row.* = .{ .vera_ns = vera_ns, .vera_ok = vera_ok, .scope = scopeOf(source) };

        if (ov) |c| if (row.scope == .va) {
            // The wrapper is written once, before the clock: see `prepare`.
            const job = try external.prepare(io, pa, f, source);
            var ns: u64 = std.math.maxInt(u64);
            for (0..fixture_reps) |_| {
                const t0: Io.Timestamp = .now(io, .awake);
                _ = external.compileOnce(io, pa, c.argv, f, job) catch break;
                ns = @min(ns, elapsed(io, t0));
            }
            // One more spawn than the timing loop, deliberately: the verdict
            // comes from `harness.judge`, the same function that judged VerA, so
            // the two columns cannot drift apart. `Ctx` carries back the two
            // facts the verdict vocabulary has no room for.
            const verdict = try harness.judge(gpa, io, pa, external.compiler(c), f, false, ew);
            if (ns != std.math.maxInt(u64)) row.ov_ns = ns;
            row.ov_ok = if (c.crashed) .crash else if (verdict == .pass) .yes else .no;
        };

        try w.print("{s}\t{s}\t{d}\t", .{
            relative(f.path, cfg.root),
            if (d.reject.len != 0) "refuse" else "compile",
            vera_ns,
        });
        try optional(w, vera_out);
        try w.print("\t{s}", .{vera_ok.text()});
        if (ov) |c| {
            try w.print("\t{t}\t", .{row.scope});
            try optional(w, row.ov_ns);
            try w.writeAll("\t");
            try optional(w, if (row.scope == .va) c.artifact else null);
            try w.print("\t{s}", .{row.ov_ok.text()});
        }
        try w.writeAll("\n");
        try w.flush();
    }

    try summary(w, arena, rows, depth, spawn_ns, ov != null);
}

/// `-` and not `0`: "there is no number" and "the number is zero" are different
/// facts, and a refused fixture emits no device rather than an empty one.
fn optional(w: *Io.Writer, v: anytype) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("-");
}

fn relative(path: []const u8, root: []const u8) []const u8 {
    return path[@min(root.len + 1, path.len)..];
}

fn summary(
    w: *Io.Writer,
    arena: Allocator,
    rows: []const Row,
    depth: harness.Counts,
    spawn_ns: u64,
    against: bool,
) !void {
    var vera_all: std.ArrayList(u64) = .empty;
    var vera_va: std.ArrayList(u64) = .empty;
    var ov_va: std.ArrayList(u64) = .empty;
    var agreed: usize = 0;
    var ov_agreed: usize = 0;
    var ov_disagreed: usize = 0;
    var ov_crashed: usize = 0;
    var ov_na: usize = 0;
    for (rows) |r| {
        try vera_all.append(arena, r.vera_ns);
        if (r.vera_ok == .yes) agreed += 1;
        if (!against) continue;
        switch (r.ov_ok) {
            .n_a => ov_na += 1,
            .crash => ov_crashed += 1,
            .yes => ov_agreed += 1,
            .no => ov_disagreed += 1,
        }
        if (r.scope == .va) {
            try vera_va.append(arena, r.vera_ns);
            if (r.ov_ns) |n| try ov_va.append(arena, n);
        }
    }

    try w.writeAll(
        \\
        \\# SPEED — total and distribution. Only rows with the same `scope` are
        \\#   comparable: the `va` rows are the fixtures both compilers were given.
        \\
    );
    try w.writeAll("scope\tcompiler\tn\ttotal_ns\tp50_ns\tp90_ns\tp99_ns\tmax_ns\n");
    try stats(w, arena, "all", "vera", vera_all.items, 0);
    if (against) {
        try stats(w, arena, "va", "vera", vera_va.items, 0);
        try stats(w, arena, "va", "vera+spawn", vera_va.items, spawn_ns);
        try stats(w, arena, "va", external.cc, ov_va.items, 0);
    }

    if (against) {
        try w.print(
            \\
            \\# AGREEMENT WITH THE FIXTURE — accept what the LRM says must compile,
            \\#   refuse what it says must not. This is the whole of a fixture that
            \\#   travels, and both columns are `harness.judge`: the same code, the same
            \\#   fixtures, the same verdict algebra.
            \\#   `crash` is counted apart from `disagreed` because a compiler that dies
            \\#   on a `//! reject` fixture exits nonzero exactly as a refusal does, and
            \\#   scoring that as conformance is the one way this report could call a
            \\#   defect a pass.
            \\
        , .{});
        try w.writeAll("compiler\tscored\tagreed\tdisagreed\tcrashed\tout_of_scope\n");
        try w.print("vera\t{d}\t{d}\t{d}\t0\t0\n{s}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            rows.len,
            agreed,
            rows.len - agreed,
            external.cc,
            rows.len - ov_na,
            ov_agreed,
            ov_disagreed,
            ov_crashed,
            ov_na,
        });
        try w.print(
            \\
            \\# SCOPE — `ams` means the FIXTURE uses a construct Annex C keeps out of
            \\#   Verilog-A: C.16's keyword list, C.4's `wreal`/`discrete`/
            \\#   `` `default_discipline ``, C.5's `===`/`!==`, C.7's `casex`/`casez` and
            \\#   digital behaviour. {d} of {d} fixtures are that, and they are `n/a` for
            \\#   {s} — the suite's scope, not the compiler's defect.
            \\#   THE CEILING, because it is one: the test is TEXTUAL (identifiers
            \\#   outside comments and strings), so it can only UNDER-count `ams`, and it
            \\#   knows nothing of the foreign compiler's OWN subset — a refusal of an
            \\#   in-scope fixture counts as a disagreement even where the cause is a
            \\#   limitation rather than a conformance defect. Both errors run one way:
            \\#   `disagreed` above is an UPPER bound on non-conformance.
            \\
        , .{ ov_na, rows.len, external.cc });
    }

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
/// caller's, and a second row over the same set would otherwise sort an
/// already-sorted array and call it a distribution.
fn stats(
    w: *Io.Writer,
    arena: Allocator,
    scope: []const u8,
    name: []const u8,
    samples: []const u64,
    add: u64,
) !void {
    if (samples.len == 0) return;
    const s = try arena.dupe(u64, samples);
    var total: u64 = 0;
    for (s) |*x| {
        x.* += add;
        total += x.*;
    }
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    try w.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        scope, name, s.len, total, pct(s, 50), pct(s, 90), pct(s, 99), s[s.len - 1],
    });
}

fn pct(sorted: []const u64, p: usize) u64 {
    return sorted[@min(sorted.len * p / 100, sorted.len - 1)];
}

/// What a SUBPROCESS costs on this machine before it has done any work. The
/// binary spawned is the `vera` this build produced, because it is the one
/// native binary here that is certainly present and certainly exits at once.
///
/// 0 means "could not be measured", and the report says nothing about spawn
/// cost rather than guessing at it.
fn spawnFloor(io: Io, exe: []const u8) u64 {
    var min: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const t0: Io.Timestamp = .now(io, .awake);
        var child = std.process.spawn(io, .{
            .argv = &.{exe},
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return 0;
        _ = child.wait(io) catch return 0;
        min = @min(min, elapsed(io, t0));
    }
    return min;
}

// ---------------------------------------------------------------------------
// Scope — which fixtures a Verilog-A compiler can be held to at all
// ---------------------------------------------------------------------------

const Scope = enum { va, ams };

/// Annex C's list and nothing invented. C.16 names the nine Verilog-AMS
/// keywords Verilog-A does not use; C.4 removes `wreal`, the `discrete` domain
/// and `` `default_discipline ``; C.5 removes `===` and `!==`; C.7 removes
/// `casex`, `casez` and digital behaviour, which is what the event and
/// procedural keywords here are.
///
/// Conservative on purpose: a keyword is listed only where the annex says so,
/// so a fixture that is Verilog-AMS by SEMANTICS with no distinctive keyword
/// scores as in scope and its refusal counts against the foreign compiler. That
/// is the direction the error must run — a scope rule that guessed generously
/// would quietly excuse real non-conformance.
const ams_only = [_][]const u8{
    // C.16
    "connect",    "connectmodule",       "connectrules", "driver_update",
    "endconnectrules", "merged",         "resolveto",    "split",
    "wreal",
    // C.4
    "discrete",   "default_discipline",
    // C.7
    "always",     "initial",             "casex",        "casez",
    "posedge",    "negedge",             "fork",         "join",
    "task",       "endtask",
};

/// Is this fixture inside the Verilog-A subset?
///
/// Read at CODE level — outside comments and outside string literals — because
/// these fixtures are documents: they open with a `//!` header that argues about
/// the clause in prose, and "the connect rules of §7.6" in a paragraph is not a
/// `connect` statement. A plain `indexOf` over the bytes scored 200-odd fixtures
/// out of scope for their own commentary.
fn scopeOf(source: []const u8) Scope {
    var i: usize = 0;
    while (i < source.len) {
        switch (source[i]) {
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    i = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                } else if (i + 1 < source.len and source[i + 1] == '*') {
                    i = if (std.mem.indexOfPos(u8, source, i + 2, "*/")) |e| e + 2 else source.len;
                } else i += 1;
            },
            '"' => {
                i += 1;
                while (i < source.len and source[i] != '"') : (i += 1) {
                    if (source[i] == '\\') i += 1;
                }
                i += 1;
            },
            // C.5: the case equality operators. `!=` and `==` are not them, so
            // the whole three characters have to match.
            '=', '!' => {
                if (std.mem.startsWith(u8, source[i..], "===") or
                    std.mem.startsWith(u8, source[i..], "!==")) return .ams;
                i += 1;
            },
            else => |c| {
                if (!isIdent(c)) {
                    i += 1;
                    continue;
                }
                // The WHOLE identifier, so `wreal_count` is not `wreal`.
                var j = i;
                while (j < source.len and isIdent(source[j])) j += 1;
                const word = source[i..j];
                for (ams_only) |k| if (std.mem.eql(u8, word, k)) return .ams;
                i = j;
            },
        }
    }
    return .va;
}

fn isIdent(c: u8) bool {
    return c == '_' or c == '$' or std.ascii.isAlphanumeric(c);
}

// ---------------------------------------------------------------------------

/// `--sweep`: the generated size sweep, which is about SLOPE and has no fixture
/// and no second compiler in it. See the header.
fn sweepReport(gpa: Allocator, io: Io, arena: Allocator, w: *Io.Writer) !u8 {
    // The footprint table first, and it is a separate pass rather than a column
    // on the timing table: `bytes` there is what a PHASE handled, which is text
    // for three of the four phases, and overloading it would make two different
    // quantities share a heading. One compile per shape, outside every timer.
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
// The `devices` mode — the tests that cannot be a `test` block, because the
// thing under test does not exist until the `vera` BINARY has emitted it.
//
//   - CLI goldens. `vera --run x.v` is a subprocess, so its transcript is
//     compared against a committed file.
//   - Generated devices. `vera --emit-zig` produces a module, a host beside it
//     calls its hooks and reads its state, and `vera.tb.buildExe` — the same
//     spawner the torture suite uses per fixture — links the two.
//
// It lives on the RUNNER side and not in `build.zig` because every one of those
// is a subprocess pipeline, and expressing a pipeline as build-graph artifacts
// costs ten lines of plumbing per case for the privilege of running it in a
// language that cannot read a file. Here it is a table and two loops.
//
//   zig build test                  # all of it
//   zig build test-devices -- rng   # the cases whose name contains `rng`
// ---------------------------------------------------------------------------

/// `vera --run <name>.v` must print `<name>.expected.txt` exactly. IEEE 1364
/// semantics, so `.v` and not `.va`: the shared frontend plus `sim/`, with no
/// analog path at all.
///
/// WALKED, NOT LISTED. `tests/fixtures/digital/` is where the merged `tests/
/// pending` digital rows landed — D03 strengths, D06 delays, D08 gates, D09
/// timing — and they are ~70 files against the four that were here before. A
/// table would be a second register of the same directory, and the one that
/// rots is always the table.
///
/// A `.v` with no `.expected.txt` beside it is not a case. That is how a design
/// a fixture INSTANTIATES (D08's UDP libraries, M04's driver designs) sits in
/// the same directory without being run on its own.
const digital_dir = "digital";

fn devices(init: std.process.Init, vera_exe: []const u8, args: *Args) !u8 {
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

    const cases = try digitalCases(gpa, io);
    defer {
        for (cases) |c| gpa.free(c);
        gpa.free(cases);
    }

    var ran: usize = 0;
    var failed: usize = 0;
    for (cases) |case| {
        if (filter) |f| if (std.mem.indexOf(u8, case, f) == null) continue;
        _ = arena_state.reset(.retain_capacity);
        ran += 1;
        if (!try digitalCase(arena_state.allocator(), io, vera_exe, case, w)) failed += 1;
    }
    if (ran == 0) {
        try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print("devices: {d}/{d} cases behave as they say they do\n", .{ ran - failed, ran });
    return if (failed == 0) 0 else 1;
}

const Captured = struct { stdout: []const u8, stderr: []const u8, exit: u8 };

/// Run a child and take everything it said.
///
/// ponytail: stdout is drained to EOF before stderr, so a child that fills the
/// stderr pipe (64 KiB) while still writing stdout would wedge. Nothing here
/// writes more than a few hundred bytes to either; the upgrade path is a
/// two-thread drain, as `external.zig` would also need.
fn capture(arena: Allocator, io: Io, argv: []const []const u8) !Captured {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var obuf: [1 << 16]u8 = undefined;
    var ebuf: [1 << 16]u8 = undefined;
    var out: Io.Writer.Allocating = .init(arena);
    var err: Io.Writer.Allocating = .init(arena);
    var or_ = child.stdout.?.readerStreaming(io, &obuf);
    _ = or_.interface.streamRemaining(&out.writer) catch {};
    var er = child.stderr.?.readerStreaming(io, &ebuf);
    _ = er.interface.streamRemaining(&err.writer) catch {};
    return .{
        .stdout = out.written(),
        .stderr = err.written(),
        .exit = switch (try child.wait(io)) {
            .exited => |c| c,
            else => 255,
        },
    };
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

/// Every `<name>.v` under `fixture_root/digital/` that has a `<name>.expected.
/// txt` beside it, sorted, so two runs report in the same order.
fn digitalCases(gpa: Allocator, io: Io) ![]const []const u8 {
    const root = try std.fs.path.join(gpa, &.{ options.fixture_root, digital_dir });
    defer gpa.free(root);
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c);
        list.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stem = std.fs.path.stem(entry.name);
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".v")) continue;
        const golden = try std.fmt.allocPrint(gpa, "{s}.expected.txt", .{stem});
        defer gpa.free(golden);
        dir.access(io, golden, .{}) catch continue;
        try list.append(gpa, try gpa.dupe(u8, stem));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return list.toOwnedSlice(gpa);
}

fn digitalCase(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !bool {
    const src = try std.fmt.allocPrint(arena, "{s}/{s}/{s}.v", .{ options.fixture_root, digital_dir, case });
    const want = try Io.Dir.cwd().readFileAlloc(
        io,
        try std.fmt.allocPrint(arena, "{s}/{s}/{s}.expected.txt", .{ options.fixture_root, digital_dir, case }),
        arena,
        .limited(1 << 20),
    );
    const r = try capture(arena, io, &.{ vera_exe, "--run", src });
    if (r.exit != 0) {
        try w.print("FAIL {s}: vera --run exited {d}\n{s}\n", .{ case, r.exit, r.stderr });
        return false;
    }
    return diff(w, case, want, r.stdout);
}


// ---------------------------------------------------------------------------

// orchestrator.zig's claim, and the whole basis of the incremental story:
// writing a tree that is already on disk touches nothing. It is a `test` and
// not an assert inside the timed `rewrite` phase for the reason the header
// gives — an assertion under the clock measures itself.
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

// The two cheap points of every axis, in `zig build test`. The sweep's tail is
// seconds, which is why `benchmark` is not in `test` — but the table above is a
// size regression on the emitted device, and a size regression that is only
// checked when someone remembers to run the bench is not checked.
test "generated shapes emit the expected device and MIR size" {
    for (std.enums.values(Axis)) |axis| {
        for (0..2) |i| _ = try checkShape(std.testing.allocator, axis, i);
    }
}

// The scope rule decides which fixtures a Verilog-A compiler is SCORED on, so
// getting it wrong publishes a wrong number in either direction: a false `ams`
// excuses a real refusal, a false `va` invents one. The prose cases are the
// ones that actually bit — these fixtures argue about their clause in a `//!`
// header, and a byte-wise `indexOf` read the argument as the construct.
test "scope reads Annex C at code level, not in the prose that cites it" {
    try std.testing.expectEqual(Scope.va, scopeOf("I(a,b) <+ V(a,b) / r;"));
    try std.testing.expectEqual(Scope.ams, scopeOf("connectmodule l2e(in, out);"));
    try std.testing.expectEqual(Scope.ams, scopeOf("  wreal w;"));
    try std.testing.expectEqual(Scope.ams, scopeOf("always @(posedge clk) q <= d;"));
    // C.5: `!=` and `==` are Verilog-A's; the three-character forms are not.
    try std.testing.expectEqual(Scope.va, scopeOf("if (a != b && c == d) x = 1;"));
    try std.testing.expectEqual(Scope.ams, scopeOf("if (a === b) x = 1;"));
    // A header paragraph naming the construct is not the construct.
    try std.testing.expectEqual(Scope.va, scopeOf(
        \\//! §7.6 says a connect statement inserts a connectmodule, and wreal
        \\//! nets always resolve — none of which this fixture does.
        \\I(a,b) <+ 1.0;
    ));
    try std.testing.expectEqual(Scope.va, scopeOf("$strobe(\"always initial casex\");"));
    // A keyword is a whole identifier, never a prefix of one.
    try std.testing.expectEqual(Scope.va, scopeOf("real wreal_count, initial_v;"));
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
