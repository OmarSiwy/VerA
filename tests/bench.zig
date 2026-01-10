//! The instrument. Every performance claim about VerA is graded here.
//!
//! Before this file existed, two waves shipped speedup numbers (6.9×, 28.2%)
//! measured against a synthetic that no longer exists, and nothing in the tree
//! could refute either. So the rule is now mechanical: no performance claim
//! lands in a commit message, a comment or TODO.md that this step cannot print.
//!
//! FOUR PHASES, ON SEAMS THAT ALREADY EXISTED. The bench adds no API to the
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
//!
//! A CURVE, NEVER A SINGLE NUMBER. `gen` emits a .va whose size is a parameter,
//! and each of its three axes is swept 1 → 4096 with the other two pinned at 1.
//! A slope is what settles a scope argument: "this scan is O(n²) and n is a
//! netlist" and "this scan is flat to 4096" are the same wall-clock number at
//! n = 8 and opposite conclusions, and only the sweep tells them apart. The
//! 1164 fixtures run as a fourth case because they are the only workload the
//! project's scope actually guarantees exists.
//!
//! **RELEASEFAST IS THE NUMBER THAT MEANS ANYTHING**, because it is what ships.
//! `zig build bench` takes the tree's default `-Doptimize`, which is **Debug**,
//! and Debug is ~8× slower (MEASURED on one tree, same commit, `-- fixtures`:
//! `lint` 1959.5 ms Debug vs 247.0 ms ReleaseFast). A whole night of wave-8/14
//! figures was quoted as if it were the shipping number because the TSV did not
//! say which it was. So the mode is now COLUMN 1 of the timing table, from
//! `@import("builtin").mode` — the compiled-in truth, not a flag the runner can
//! be lied to about — and a run that is not ReleaseFast says so again in a `#`
//! line. Column 1 is constant within a run and does not disturb the sort.
//!
//! That label is honest only because `build.zig` gives `bench_mod` and the
//! `vera` module it imports the SAME `optimize`: `-O` is a per-module flag
//! (std.Build.Module emits one per module), so a bench built ReleaseFast against
//! a Debug engine would print `ReleaseFast` over a Debug measurement. Which is
//! also why this step does not silently force ReleaseFast on itself — see the
//! comment on the `bench` step in build.zig.
//!
//!   zig build bench -Doptimize=ReleaseFast    # the number that ships
//!   zig build bench                           # Debug: ~8× slower, a lower bound
//!
//! IT CAN FAIL, which is the difference between an instrument and a decoration.
//! A step that asserts nothing prevents nothing, and a wall-clock number cannot
//! be asserted — it is a property of the machine, not of the compiler. So the
//! DETERMINISTIC quantities produced by the same pass are `expect`ed:
//!
//!   - the second `writeTree` returns 0 (orchestrator.zig:202-206's claim, and
//!     the whole basis of the incremental story, made falsifiable);
//!   - `device.text.len`, `mir.defs.len` and `mir.insts.len` per generated
//!     shape, against the table below.
//!
//! Neither can drift with the machine, so `zig build bench` doubles as a
//! size-regression test — and `expected` moving is a diff a reviewer must sign,
//! which is the point.
//!
//! NO MACHINE-READABLE SIDE CHANNEL, for the reason harness.zig:31-34 gives:
//! a second output format is a second thing to keep true. The output is one TSV
//! line per (mode, case, n, phase) on stdout — preceded by one line per (case,
//! n) of MIR FOOTPRINT, which is a different quantity and so gets its own
//! heading rather than a second meaning for `bytes` — sorted by construction, so
//! comparing two runs is `diff` and nothing else. The footprint table carries NO
//! mode column on purpose: those numbers are pure functions of the source and
//! identical in every mode, so a column there would make `diff` report a
//! difference where there is none. There is no committed artifact and no
//! `--bless`: the timings are the machine's and belong to whoever ran it.
//!
//! N = 25 is what makes the fixture batch the expensive half: 1164 compilations
//! times 25 is four of the five minutes a full ReleaseFast run costs (Debug is
//! several times that), and the sweep on its own is under one. So the batch has
//! a filter, and it is the reason for it — `-- gen` is the one to run while
//! iterating on a slope.
//!
//!   zig build bench -Doptimize=ReleaseFast              # both; ~5 min
//!   zig build bench -Doptimize=ReleaseFast -- gen       # the sweep only; ~50 s
//!   zig build bench -Doptimize=ReleaseFast -- fixtures  # the 1164 as one batch

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("bench_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `root.zig` does not re-export `Mir` (wave 12 privatised it, and decision 4
/// says a loud compile error is the desired signal). The type is still
/// reachable through the result that carries it, which is the seam an embedder
/// already has — so this needs no new `pub`.
const Mir = @typeInfo(@FieldType(vera.CompileResult, "mir")).pointer.child;

/// N, and the estimator is the MIN over it. The min is right here because every
/// source of noise on a shared machine is additive — a preempted run is slower
/// than a clean one and never faster — so the minimum is the closest sample to
/// "what this code costs", where a mean would mostly measure the load average of
/// whoever ran it.
///
/// The clock is `Io.Timestamp.now(io, .awake)`: `std.time.Timer` no longer
/// exists on 0.16 (std/time.zig is unit constants and `epoch` now), and
/// `.awake` is the CLOCK_MONOTONIC it wrapped.
const reps = 25;

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
/// MEASURED on this tree, not predicted: the numbers came out of this bench.
const Shape = struct { device: usize, defs: usize, insts: usize };
const expected = std.enums.directEnumArrayDefault(Axis, [sweep.len]Shape, null, 0, .{
    .contrib = .{
        .{ .device = 11559, .defs = 8, .insts = 5 },
        .{ .device = 12141, .defs = 35, .insts = 26 },
        .{ .device = 16786, .defs = 258, .insts = 194 },
        .{ .device = 55209, .defs = 2050, .insts = 1538 },
        .{ .device = 372724, .defs = 16386, .insts = 12290 },
    },
    .vals = .{
        .{ .device = 11559, .defs = 8, .insts = 5 },
        .{ .device = 11818, .defs = 24, .insts = 19 },
        .{ .device = 13890, .defs = 136, .insts = 131 },
        .{ .device = 30466, .defs = 1032, .insts = 1027 },
        .{ .device = 163074, .defs = 8200, .insts = 8195 },
    },
    .inst = .{
        .{ .device = 11559, .defs = 8, .insts = 5 },
        .{ .device = 13022, .defs = 50, .insts = 40 },
        .{ .device = 25050, .defs = 386, .insts = 320 },
        .{ .device = 123842, .defs = 3074, .insts = 2560 },
        .{ .device = 934482, .defs = 24578, .insts = 20480 },
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
/// `ValueRow` — measured by `soaBytes` below rather than asserted, so it
/// tracks the struct). The two dedup maps and the interner are excluded on
/// purpose: they are build-time scratch that `deinit` drops, and no proposed
/// layout change touches them. What is counted is exactly the surface an
/// Air-shaped rewrite would move.
const Footprint = struct {
    insts: u64 = 0,
    defs: u64 = 0,
    blocks: u64 = 0,
    extra: u64 = 0,

    /// Bytes a `MultiArrayList(T)` spends per element: the sum of the field
    /// sizes, which is what `capacityInBytes` multiplies by.
    fn soaBytes(comptime T: type) u64 {
        comptime var n: u64 = 0;
        inline for (std.meta.fields(T)) |f| n += @sizeOf(f.type);
        return n;
    }

    const inst_b = soaBytes(Mir.InstRow);
    const def_b = soaBytes(Mir.ValueRow) + @sizeOf(Mir.Value); // + alias slot
    const block_b = soaBytes(Mir.BlockRow);

    fn of(m: *const Mir) Footprint {
        return .{
            .insts = m.insts.len,
            .defs = m.defs.len,
            .blocks = m.blocks.len,
            .extra = m.extra.items.len,
        };
    }

    fn add(self: *Footprint, o: Footprint) void {
        self.insts += o.insts;
        self.defs += o.defs;
        self.blocks += o.blocks;
        self.extra += o.extra;
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

/// One compilation input: the source and the include path it needs. A fixture
/// carries its own directory (`check.vh` lives next to it); a generated source
/// needs neither.
const Input = struct {
    source: []const u8,
    dir: ?[]const u8 = null,

    fn opts(self: Input, dirs: *[2][]const u8) vera.Options {
        const d = self.dir orelse return .{};
        dirs.* = .{ d, options.fixture_root };
        return .{ .include_dirs = dirs };
    }
};

/// Run `phase` over every input once and return the bytes it handled.
///
/// `keep`, when supplied, receives every `CompileResult` instead of freeing it,
/// so `measure` can read the clock BEFORE the teardown runs — a compilation
/// arena is one `munmap` but a device text is a `free` of up to a megabyte, and
/// timing it would attribute the allocator's cost to codegen. It must already
/// have capacity for `inputs.len`, because a reallocation inside the timed
/// region would be the very thing it exists to keep out.
///
/// The batch case passes `null` and eats the teardown, deliberately: 1164
/// simultaneously live compilation arenas cost more in page faults and RSS than
/// the teardown they would remove, which is a bigger measurement error than the
/// one being avoided. The sweep — where the headline slopes come from — is one
/// input, so it always gets the honest form.
///
/// `doNotOptimizeAway` on the two values a release build could otherwise prove
/// unused (`result.mir`, the device length) is what stops it from deleting the
/// work being timed.
///
/// Errors are SWALLOWED, not propagated: 418 of the 1164 fixtures conform by
/// being refused, and a refusal costs real time in exactly the phases this
/// measures. Skipping them would bias the batch towards the code that compiles.
fn runPhase(
    gpa: Allocator,
    io: Io,
    phase: Phase,
    inputs: []const Input,
    work_dir: []const u8,
    keep: ?*std.ArrayList(vera.CompileResult),
) !u64 {
    var bytes: u64 = 0;
    for (inputs) |in| {
        var dirs: [2][]const u8 = undefined;
        const o = in.opts(&dirs);

        if (phase == .pp) {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var bag = vera.diag.Bag.init(arena.allocator());
            const text = vera.Preprocessor.process(arena.allocator(), in.source, .{
                .include_dirs = o.include_dirs,
                .std_defs = o.std_defs,
                .bag = &bag,
            }) catch continue;
            std.mem.doNotOptimizeAway(text.len);
            bytes += text.len;
            continue;
        }

        var owned = vera.compileSourceOpts(gpa, in.source, .lint, o) catch continue;
        var result = &owned;
        if (keep) |k| {
            k.appendAssumeCapacity(owned);
            result = &k.items[k.items.len - 1];
        }
        defer if (keep == null) result.deinit();

        std.mem.doNotOptimizeAway(result.mir);
        if (phase == .lint) {
            bytes += result.source.len;
            continue;
        }

        const device = result.generateDevice() catch continue;
        std.mem.doNotOptimizeAway(device.len);
        if (phase == .codegen) {
            bytes += device.len;
            continue;
        }

        // The rewrite phase: prime the tree, then write it AGAIN, which is the
        // no-op recompile the whole incremental story rests on. The second call
        // must return a write count of 0 — that is orchestrator.zig:202-206's
        // claim, and it is why the byte column for this phase is 0.
        const o_orch: vera.orchestrator.Options = .{
            .work_dir = work_dir,
            .name = "bench",
            .optimize = .Debug,
            .backend = .self_hosted,
            .modules = &.{},
        };
        _ = try vera.orchestrator.writeTree(io, gpa, o_orch, result.device);
        const writes = try vera.orchestrator.writeTree(io, gpa, o_orch, result.device);
        try std.testing.expectEqual(@as(usize, 0), writes);
    }
    return bytes;
}

fn measure(
    gpa: Allocator,
    io: Io,
    phase: Phase,
    inputs: []const Input,
    work_dir: []const u8,
) !Sample {
    // See `runPhase`: only the one-input sweep holds its results past the clock.
    var kept: std.ArrayList(vera.CompileResult) = .empty;
    defer {
        for (kept.items) |*r| r.deinit();
        kept.deinit(gpa);
    }
    const keep: ?*std.ArrayList(vera.CompileResult) = if (inputs.len == 1) &kept else null;
    if (keep) |k| try k.ensureTotalCapacity(gpa, reps);

    var min: u64 = std.math.maxInt(u64);
    var bytes: u64 = 0;
    for (0..reps) |_| {
        const t0: Io.Timestamp = .now(io, .awake);
        bytes = try runPhase(gpa, io, phase, inputs, work_dir, keep);
        const ns = t0.durationTo(.now(io, .awake)).nanoseconds;
        min = @min(min, @as(u64, @intCast(@max(ns, 0))));
    }
    return .{ .min_ns = min, .bytes = bytes };
}

/// The mode the ENGINE was compiled in, and therefore the only thing that makes
/// a `min_ns` mean something. `builtin.mode` is this module's own `-O`, which
/// `build.zig` keeps equal to the `vera` module's; see the header.
const mode = @tagName(@import("builtin").mode);

fn emit(w: *Io.Writer, case: []const u8, n: u32, phase: Phase, s: Sample) !void {
    try w.print("{s}\t{s}\t{d}\t{t}\t{d}\t{d}\n", .{ mode, case, n, phase, s.min_ns, s.bytes });
}

// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var do_gen = true;
    var do_fixtures = true;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "gen")) do_fixtures = false //
        else if (std.mem.eql(u8, a, "fixtures")) do_gen = false //
        else {
            var e_buf: [256]u8 = undefined;
            var e = Io.File.stderr().writer(io, &e_buf);
            try e.interface.print("bench: unknown argument `{s}`\n", .{a});
            try e.interface.flush();
            return 2;
        }
    }

    var out_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    // The footprint table first, and it is a separate pass rather than a column
    // on the timing table: `bytes` there is what a PHASE handled, which is text
    // for three of the four phases, and overloading it would make two different
    // quantities share a heading. One compile per shape, outside every timer.
    try w.writeAll("case\tn\tinsts\tdefs\tblocks\textra\tmir_bytes\n");
    if (do_gen) for (std.enums.values(Axis)) |axis| {
        for (sweep, 0..) |n, i| {
            try emitFootprint(w, @tagName(axis), n, try checkShape(gpa, axis, i));
        }
    };

    // Read every fixture ONCE, outside every timer: the batch case measures the
    // compiler on 1164 small files, not the page cache.
    var fixture_inputs: []Input = &.{};
    if (do_fixtures) {
        const fixtures = try harness.collect(arena, io, options.fixture_root, null);
        fixture_inputs = try arena.alloc(Input, fixtures.len);
        for (fixtures, fixture_inputs) |f, *in| in.* = .{
            .source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20)),
            .dir = f.dir,
        };
        var total: Footprint = .{};
        var max_bytes: u64 = 0;
        for (fixture_inputs) |in| {
            var dirs: [2][]const u8 = undefined;
            var r = vera.compileSourceOpts(gpa, in.source, .lint, in.opts(&dirs)) catch continue;
            defer r.deinit();
            const f: Footprint = .of(r.mir);
            total.add(f);
            max_bytes = @max(max_bytes, f.bytes());
        }
        try emitFootprint(w, "fixtures", @intCast(fixture_inputs.len), total);
        try w.print("# largest single fixture MIR: {d} bytes\n", .{max_bytes});
    }
    try w.flush();

    try w.writeAll("\nmode\tcase\tn\tphase\tmin_ns\tbytes\n");
    if (@import("builtin").mode != .ReleaseFast) try w.print(
        "# {s}: NOT the shipping number (~8x slow). Re-run with -Doptimize=ReleaseFast.\n",
        .{mode},
    );

    if (do_gen) {
        for (std.enums.values(Axis)) |axis| {
            for (sweep) |n| {
                const src = try genSource(arena, axis, n);
                const inputs = [_]Input{.{ .source = src }};
                const work = try std.fmt.allocPrint(arena, "{s}/gen", .{options.work_root});
                for (std.enums.values(Phase)) |p| {
                    try emit(w, @tagName(axis), n, p, try measure(gpa, io, p, &inputs, work));
                }
                try w.flush();
            }
        }
    }

    if (do_fixtures) {
        const work = try std.fmt.allocPrint(arena, "{s}/fixtures", .{options.work_root});
        for (std.enums.values(Phase)) |p| {
            const s = try measure(gpa, io, p, fixture_inputs, work);
            try emit(w, "fixtures", @intCast(fixture_inputs.len), p, s);
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------

// The two cheap points of every axis, in `zig build test`. The sweep's tail is
// seconds, which is why `bench` is not in `test` — but the table above is a
// size regression on the emitted device, and a size regression that is only
// checked when someone remembers to run `bench` is not checked.
test "generated shapes emit the expected device and MIR size" {
    for (std.enums.values(Axis)) |axis| {
        for (0..2) |i| _ = try checkShape(std.testing.allocator, axis, i);
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
