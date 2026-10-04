//! The conformance harness: `tests/fixtures/**/*.va` and a plugged-in
//! `Compiler` -> one verdict per fixture and a report. Everything that is not
//! about a particular compiler lives here: the fixture walk (`collect`), the
//! verdict algebra (`judge`, `decide`) and the parallel run (`run`, the
//! spine). Plugs: `torture.zig`'s full compiler (runs the model) and its
//! accept/refuse-only one. `bench.zig` owns `main`.
//!
//! Sub-files under `harness/`, each a table of free functions:
//!   `lint.zig`      the assertion lint `decide` runs before compiling
//!   `coverage.zig`  `--coverage`, the static citation inventory
//!   `digital.zig`   the `.v` runner metadata both digital runners read
//! The other runners import the sub-file they need directly.
//!
//! The verdict algebra is frozen behaviour (AGENTS.md §2, §6): an `ok=1`
//! transcript is `met` only through the compiler plug, `//! xfail` turns
//! `unmet` into XFAIL and `met` into an XPASS FAIL, and `--strict` fails
//! unasserted and XFAIL fixtures.

const std = @import("std");
const vera = @import("vera");
/// `fixture_root` and `docs_root`, from `build.zig`; shared by every runner so
/// all compilers are judged on the same fixtures against the same LRM.
const options = @import("suite_options");
const lint = @import("harness/lint.zig");
const coverage = @import("harness/coverage.zig");
const digital = @import("harness/digital.zig");

const Io = std.Io;
/// `--fixture-opt=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
/// (`fast`, ...); the flag keeps the names it always took.
const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
    .{ "Debug", .debug },
    .{ "ReleaseSafe", .safe },
    .{ "ReleaseFast", .fast },
    .{ "ReleaseSmall", .small },
});

/// `std.mem.sort` order for strings: bytewise.
pub fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Everything one fixture needs, all with the same lifetime (the arena
/// `collect` was given). One row per collected fixture; the stem and the
/// directory are slices of `path`, derived rather than stored.
pub const Fixture = struct {
    /// `tests/fixtures/ch04_expressions/01_arithmetic.va`; ends in `.va` or `.v`.
    path: []const u8,
    /// The suite root this fixture was collected from (`tests/fixtures`, or
    /// `tests/pending` under `--fixture-root=`): the second include dir, since
    /// `check.vh` lives there, and the scratch namespace.
    root: []const u8,
    /// `ch04_expressions_01_arithmetic` — the scratch directory name.
    ///
    /// Not the stem: stems repeat across chapters, and fixtures sharing a
    /// scratch directory race in parallel.
    slug: []const u8,

    /// `01_arithmetic`: the file name without its `.va` or `.v`.
    pub fn stem(f: Fixture) []const u8 {
        const base = std.fs.path.basename(f.path);
        const ext: usize = if (std.mem.endsWith(u8, base, ".va")) ".va".len else ".v".len;
        return base[0 .. base.len - ext];
    }

    /// `tests/fixtures/ch04_expressions`, the first include dir.
    pub fn dir(f: Fixture) []const u8 {
        return std.fs.path.dirname(f.path) orelse ".";
    }
};

// Budget: three slices. `stem` and `dir` are slices of `path`, so storing
// them cost 32 B a row for nothing.
comptime {
    std.debug.assert(@sizeOf(Fixture) == 48);
}

/// What the compiler under test did with one fixture, in the only vocabulary
/// both sides can speak.
///
/// The question is "did it do what the fixture says?", not accepted/rejected.
/// A runner writes its detail only to the report writer, which the harness may
/// suppress (for an xfail).
pub const Result = union(enum) {
    /// Did what the fixture says it must.
    met,
    /// Did not. The reason is already in the report writer.
    unmet,
    /// Compiled and ran and asserted NOTHING. Only a runner whose compiler
    /// actually runs a model can return this; for the rest, a fixture that
    /// compiles has said all it can say.
    unasserted,
};

/// One compiler, plugged in.
pub const Compiler = struct {
    /// Names the compiler in the report.
    name: []const u8,
    /// Whether this compiler runs a fixture or only accepts or refuses it. When
    /// false, an unasserted fixture is not held against it and the summary says
    /// no `ok=` column was checked.
    runs: bool,
    /// Whether `//! xfail` describes this compiler. Markers record VerA's gaps;
    /// honouring them for another compiler would excuse its failures and fail
    /// its passes as XPASS.
    owns_xfail: bool,
    /// Passed back to `check`; type-erased so `run` is one function.
    ctx: *anyopaque,
    /// Judges one fixture; writes any detail to `w` and nowhere else.
    check: *const fn (
        ctx: *anyopaque,
        gpa: std.mem.Allocator,
        io: Io,
        arena: std.mem.Allocator,
        f: Fixture,
        source: []const u8,
        d: vera.tb.Directives,
        w: *Io.Writer,
    ) anyerror!Result,
    /// Runs once over the whole fixture list before any `check`, on `jobs`
    /// workers: work `check` can share across fixtures (VerA builds its
    /// testbenches in batches here). Null: nothing to share.
    prepare: ?*const fn (ctx: *anyopaque, gpa: std.mem.Allocator, io: Io, fixtures: []const Fixture, jobs: usize) anyerror!void = null,
};

/// Every suite knob, parsed once by `tests/bench.zig` and shared by all the
/// compilers in a run, so a head-to-head never walks two fixture sets.
pub const Config = struct {
    /// The fixture tree to walk. `tests/pending` holds approved fixtures VerA
    /// does not meet yet; a nonzero exit is its expected state.
    root: []const u8 = options.fixture_root,
    /// A plain substring over the whole path.
    filter: ?[]const u8 = null,
    strict: bool = false,
    coverage: bool = false,
    /// Worker threads, default one per core. `-j1` prints as it goes, which
    /// shows the fixture a run is stuck on.
    jobs: usize = 0,
    /// Optimize mode of the per-fixture testbench binaries (`-Doptimize` builds
    /// the runner). Debug: a testbench compiles for seconds and runs for
    /// microseconds, and safety checks make a codegen bug trap instead of
    /// printing a plausible wrong number. Zig floats are strict IEEE in every
    /// mode, so `--fixture-opt=ReleaseFast` asks only about optimization.
    fixture_opt: std.lang.Optimize = .debug,
    /// `--fixture-backend=llvm|native`; null is `Backend.auto(fixture_opt, <host>)`.
    fixture_backend: ?vera.orchestrator.Backend = null,
    /// `--no-batch` builds every fixture testbench alone (`Compiler.prepare`
    /// is skipped): the escape hatch, and the baseline a batched run is
    /// compared against.
    batch: bool = true,

    /// Returns the defaults, with `jobs` from `defaultJobs`.
    pub fn init() Config {
        return .{ .jobs = defaultJobs() };
    }
};

/// Concurrent fixture builds by default: the CPU count, capped at one per
/// `job_ram` of physical memory. Each job is a Zig compile (measured
/// 2026-10-01: the strict suite peaked at 16.2 GB with 32 jobs, ~0.5 GB each,
/// larger devices more), and a CPU-sized fan-out on a 32-thread, 31 GB host
/// beside other builds exhausted RAM and froze the machine (zram swap lives
/// in RAM, so nothing was OOM-killed). `-j` still overrides.
pub fn defaultJobs() usize {
    const cpus = std.Thread.getCpuCount() catch 1;
    const ram = std.process.totalSystemMemory() catch return cpus;
    return @max(1, @min(cpus, ram / job_ram));
}

/// RAM budgeted per concurrent fixture build: 4x the measured mean, for the
/// large devices and the other processes on the host.
const job_ram: u64 = 2 << 30;

/// Consumes one argument if it is the suite's; false leaves it to the caller,
/// which decides whether it is a filter. Exits 2 on a malformed value.
pub fn takeArg(cfg: *Config, a: []const u8) bool {
    if (std.mem.eql(u8, a, "--strict")) cfg.strict = true //
    else if (std.mem.eql(u8, a, "--no-batch")) cfg.batch = false //
    else if (std.mem.eql(u8, a, "--coverage")) cfg.coverage = true //
    else if (std.mem.startsWith(u8, a, "--fixture-root=")) cfg.root = a["--fixture-root=".len..] //
    else if (std.mem.startsWith(u8, a, "--fixture-opt=")) {
        const name = a["--fixture-opt=".len..];
        cfg.fixture_opt = optimize_names.get(name) orelse {
            std.debug.print("suite: not an optimize mode: {s}\n", .{name});
            std.process.exit(2);
        };
    } else if (std.mem.startsWith(u8, a, "--fixture-backend=")) {
        const name = a["--fixture-backend=".len..];
        cfg.fixture_backend = if (std.mem.eql(u8, name, "llvm")) .llvm else if (std.mem.eql(u8, name, "native")) .self_hosted else {
            std.debug.print("suite: not llvm|native: {s}\n", .{name});
            std.process.exit(2);
        };
    } else if (numeric(a, "-j") orelse numeric(a, "--jobs=")) |n| cfg.jobs = @max(n, 1) //
    else return false;
    return true;
}

/// A fixture's outcome after the verdict algebra.
pub const Verdict = enum {
    /// Behaved as the fixture said it would.
    pass,
    /// Did not.
    fail,
    /// Compiled, ran, and asserted NOTHING. Green under a suite that only looks
    /// for a crash, and the reason this harness exists.
    unasserted,
    /// Did not behave as the fixture said — and the fixture said so in advance
    /// with `//! xfail`. The rule is real, this compiler does not meet it yet.
    /// Not a pass either.
    ///
    /// This is the only meaning an xfail has.
    xfail,
};

/// Tally of verdicts over one run.
pub const Counts = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    unasserted: u32 = 0,
    xfail: u32 = 0,

    fn add(c: *Counts, v: Verdict) void {
        switch (v) {
            .pass => c.passed += 1,
            .fail => c.failed += 1,
            .unasserted => c.unasserted += 1,
            .xfail => c.xfail += 1,
        }
    }
};

/// One fixture's whole report, held rather than printed.
const Slot = struct {
    verdict: Verdict = .pass,
    /// Everything the fixture printed, owned by `gpa`. Held as ONE block so a
    /// FAIL keeps its diagnostics, its LRM cites and its transcript together
    /// instead of being shredded across whatever else finished at the time.
    output: []const u8 = "",
};

/// The work queue, shared by every worker.
///
/// Fixtures share nothing (source, scratch directory, output slot), so the only
/// synchronisation is which one to take next.
const Job = struct {
    gpa: std.mem.Allocator,
    io: Io,
    compiler: Compiler,
    fixtures: []const Fixture,
    slots: []Slot,
    strict: bool,
    next: std.atomic.Value(usize) = .init(0),

    fn work(job: *Job) void {
        // Per-worker, and reset per fixture: an arena is not threadsafe, and
        // the shared one the sequential path uses would grow to the whole run.
        var arena_state: std.heap.ArenaAllocator = .init(job.gpa);
        defer arena_state.deinit();

        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.fixtures.len) return;
            _ = arena_state.reset(.retain_capacity);
            const f = job.fixtures[i];

            var aw: Io.Writer.Allocating = .init(job.gpa);
            const verdict = judge(
                job.gpa,
                job.io,
                arena_state.allocator(),
                job.compiler,
                f,
                job.strict,
                &aw.writer,
            ) catch |err| blk: {
                aw.writer.print("FAIL {s}: the runner itself failed: {t}\n", .{ f.path, err }) catch {};
                break :blk .fail;
            };
            var list = aw.toArrayList();
            job.slots[i] = .{
                .verdict = verdict,
                .output = list.toOwnedSlice(job.gpa) catch "",
            };
        }
    }
};

/// `-j8`, `--jobs=8`. Null when `a` is not that flag at all.
fn numeric(a: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, a, prefix)) return null;
    return std.fmt.parseInt(usize, a[prefix.len..], 10) catch null;
}

/// The judged pass: every fixture through this compiler, the report on stderr.
/// `tally` receives the counts the summary prints, for the head-to-head table.
pub fn run(
    init: std.process.Init,
    compiler: Compiler,
    cfg: Config,
    tally: ?*Counts,
) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const w = &stderr.interface;

    const fixtures = try collect(arena, io, cfg.root, cfg.filter);
    if (fixtures.len == 0) {
        try w.print("{s}: no fixtures under {s}\n", .{ compiler.name, cfg.root });
        try w.flush();
        return 1;
    }

    if (cfg.coverage) {
        const ok = try coverage.report(arena, io, options.docs_root, cfg.root, cfg.filter, fixtures, w);
        try w.flush();
        return if (ok) 0 else 1;
    }

    if (compiler.prepare) |prepare| if (cfg.batch) try prepare(compiler.ctx, gpa, io, fixtures, @max(cfg.jobs, 1));

    const strict = cfg.strict;
    var counts: Counts = .{};
    if (cfg.jobs <= 1) {
        // Sequential: prints as it goes, showing the fixture a run is stuck on.
        for (fixtures) |f| {
            counts.add(try judge(gpa, io, arena, compiler, f, strict, w));
            try w.flush();
        }
    } else {
        const slots = try arena.alloc(Slot, fixtures.len);
        var job: Job = .{
            .gpa = gpa,
            .io = io,
            .compiler = compiler,
            .fixtures = fixtures,
            .slots = slots,
            .strict = strict,
        };
        var group: Io.Group = .init;
        var hands: usize = 0;
        while (hands < cfg.jobs) : (hands += 1) {
            // A narrower pool than asked for is fine — the queue does not care
            // how many hands take from it. None at all is not, so this thread
            // does the work itself.
            group.concurrent(io, Job.work, .{&job}) catch break;
        }
        if (hands == 0) job.work();
        try group.await(io);

        // Emit in SLOT order, i.e. the sorted walk, whatever order the pool
        // finished in. This is the whole reason the workers buffer.
        for (slots) |s| {
            counts.add(s.verdict);
            try w.writeAll(s.output);
            gpa.free(s.output);
        }
        try w.flush();
    }

    try summarize(compiler, counts, fixtures.len, w);
    try w.flush();
    if (tally) |t| t.* = counts;
    return if (counts.failed == 0 and
        !(strict and (counts.unasserted != 0 or counts.xfail != 0))) 0 else 1;
}

fn summarize(compiler: Compiler, c: Counts, total: usize, w: *Io.Writer) !void {
    try w.print("\n{s}: {d}/{d} fixtures behave as they say they do", .{ compiler.name, c.passed, total });
    // Say which question the number answers. A compiler that only accepts or
    // refuses has not checked a single `ok=` column, and a bare score would
    // read as if it had.
    if (!compiler.runs) try w.print(
        "\n  ACCEPT/REJECT ONLY: {s} is not run against the fixtures' own assertions,\n" ++
            "  so a `pass` here means it compiled what must compile and refused what must\n" ++
            "  be refused — not that any computed value was checked.",
        .{compiler.name},
    );
    try w.print("\n", .{});
    if (c.failed != 0) try w.print("  {d} FAILED\n", .{c.failed});
    if (c.unasserted != 0) try w.print(
        "  {d} compiled and ran but ASSERT NOTHING — they prove only that {s} did\n" ++
            "  not crash. Give each a `CHECK(\"what this proves\", got, want, tol)`\n" ++
            "  from check.vh with an independently derived want. (`--strict` fails on these.)\n",
        .{ c.unasserted, compiler.name },
    );
    if (c.xfail != 0) try w.print(
        "  {d} XFAIL — the fixture is right and {s} is not: it states a real LRM\n" ++
            "  requirement that {s} is known not to meet yet, and said so on its\n" ++
            "  `//! xfail` line (printed with the reason above). Not a pass — nothing\n" ++
            "  was proved. The day it starts meeting it the run FAILs with an XPASS,\n" ++
            "  so the marker cannot outlive the limitation and quietly hide a\n" ++
            "  regression. (`--strict` fails on these.)\n",
        .{ c.xfail, compiler.name, compiler.name },
    );
}

/// Every fixture under `root`, sorted by path so the run is deterministic
/// (`Dir.walk` order is explicitly undefined) and a failing run is
/// reproducible and diffable. `filter` is a plain substring over the whole
/// path: `zig build benchmark -- ch04` runs one group. The rows and their
/// strings live in `arena`; a missing `root` is an empty list.
pub fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, filter: ?[]const u8) ![]const Fixture {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    // `fixtureExt` reads each `.va` and golden-less `.v` whole to look for a directive.
    // Those reads are dead once it answers, so they go to a scratch arena
    // reset per file instead of living in `arena` for the whole run.
    var scratch: std.heap.ArenaAllocator = .init(arena);
    var list: std.ArrayList(Fixture) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        _ = scratch.reset(.retain_capacity);
        const ext = fixtureExt(scratch.allocator(), io, dir, entry.path) orelse continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.path });
        if (filter) |f| if (std.mem.indexOf(u8, path, f) == null) continue;
        const slug = try arena.dupe(u8, entry.path[0 .. entry.path.len - ext.len]);
        std.mem.replaceScalar(u8, slug, '/', '_');
        std.mem.replaceScalar(u8, slug, '\\', '_');
        try list.append(arena, .{ .path = path, .root = root, .slug = slug });
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return list.items;
}

/// Is this path a fixture for the accept/reject walk, and if so what extension
/// does its stem end at? `null` means "not this walk's business".
///
/// `.va` is a fixture when it carries a directive: a `.va` with none is a
/// design a host test loads (`build.zig`'s `host_tests`, the VPI walk's
/// `vpi_design.va`), the same rule as item 3 below. `.v` is the awkward one,
/// because three different things share that extension in
/// `tests/fixtures/{ieee1364,digital}/`:
///
///   1. Files with a `<stem>.expected.txt` beside them belong to `zig build
///      test-devices` (`harness/devices.zig`'s `digitalCases`), not here.
///   2. Files with a directive and no golden are judged here: `//! reject`
///      rows by the usual algebra, `//! expect vcd` rows by `judgeVcd`.
///   3. Files with no directive (VPI support designs such as `p02_design.v`)
///      are not fixtures.
///
/// So: a `.v` joins this legacy walk when it carries a directive and has no
/// golden, unless explicitly opted into the digital-negative runner below.
/// Legacy negative results are analog compilation results, NOT evidence that
/// the digital executor diagnosed the intended rule.
///
/// The whole file is scanned with `tb.parse`'s line rule (see `hasDirective`).
fn fixtureExt(arena: std.mem.Allocator, io: Io, dir: Io.Dir, rel: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, rel, ".va")) {
        const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
        return if (hasDirective(source)) ".va" else null;
    }
    if (!std.mem.endsWith(u8, rel, ".v")) return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stem = rel[0 .. rel.len - ".v".len];
    const golden = std.mem.print(&buf, "{s}.expected.txt", .{stem}) catch return null;
    if (dir.access(io, golden, .{})) |_| return null else |_| {}

    const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
    // Explicit digital negatives belong to bench's `--run` runner; unmarked
    // `.v` rejects take the analog compile route.
    if (digital.negative(source)) return null;
    return if (hasDirective(source)) ".v" else null;
}

/// Does this source carry a `//!` directive? `tb.parse`'s own line rule, and it
/// must stay that rule: this decides whether a file is collected and `tb.parse`
/// decides whether it asserts anything, so a disagreement collects a fixture
/// that then reports nothing.
fn hasDirective(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "//!")) return true;
    }
    return false;
}

test "a directive is found after the hand-derivation, not just in a header" {
    // Directives follow the header's LRM quote and derivation, often kilobytes
    // into the file, so the whole file must be scanned.
    var prose: [4096]u8 = @splat('x');
    const late = try std.testing.allocator.print(
        "// {s}\n//! reject E0205\n",
        .{prose[0..]},
    );
    defer std.testing.allocator.free(late);
    try std.testing.expect(hasDirective(late));

    try std.testing.expect(hasDirective("//! reject E0205\n"));
    try std.testing.expect(hasDirective("  \t //! lrm 9.4.1\r\n"));

    // A design a test loads is not a fixture: no directive, no collection.
    try std.testing.expect(!hasDirective("module m; endmodule\n"));
    try std.testing.expect(!hasDirective(""));

    // `//!` has to START the trimmed line. A plain substring search would take
    // this string literal for a directive and collect a file that asserts
    // nothing.
    try std.testing.expect(!hasDirective("initial $display(\"//! reject\");\n"));
}

// ---------------------------------------------------------------------------
// The verdict algebra — the whole reason both runners share this file
// ---------------------------------------------------------------------------

/// One fixture, from source text to verdict. The runner answers met/unmet;
/// the rest (xfail, strict, the assertion lint) is here, so every compiler is
/// judged alike. The head-to-head in `tests/bench.zig` calls it per fixture.
pub fn judge(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    compiler: Compiler,
    f: Fixture,
    strict: bool,
    w: *Io.Writer,
) !Verdict {
    const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));

    // A §18 dump fixture's evidence is the file its run writes, which no
    // `tb` directive describes; it is judged before `tb.parse` for that reason.
    if (digital.vcdExpectation(source)) |want| return judgeVcd(arena, io, compiler, f, want, w);

    // The `//!` lines are read from the RAW source: the preprocessor deletes
    // comments (§2.4), so after compilation they are gone.
    const d = vera.tb.parse(arena, source) catch |err| {
        try w.print("FAIL {s}: `//!` directive: {t}\n", .{ f.path, err });
        return .fail;
    };

    const verdict = try decide(gpa, io, arena, compiler, f, source, d, strict, w);

    // A verdict that names only the file makes the reader go and find the rule.
    // If the fixture said which clause it pins, say it here — for an xfail too,
    // where the cite IS the requirement being carried unmet.
    switch (verdict) {
        .fail, .xfail => if (d.lrm.len != 0) {
            try w.print("  LRM", .{});
            for (d.lrm) |section| try w.print(" §{s}", .{section});
            try w.print("\n", .{});
        },
        .pass, .unasserted => {},
    }
    return verdict;
}

fn decide(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    compiler: Compiler,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    strict: bool,
    w: *Io.Writer,
) !Verdict {
    // A malformed assertion is the fixture's defect in every compiler, and no
    // `//! xfail` excuses it. Checked before compiling; not on a `//! reject`
    // fixture, which never reaches a transcript.
    const finding = if (d.reject.len != 0) .ok else lint.checkAssertions(source);
    switch (finding) {
        .ok => {},
        .none => if (compiler.runs and strict) {
            try w.print(
                "FAIL {s}: asserts nothing — compiling and running is not an expectation.\n" ++
                    "  Add `CHECK(\"what this proves\", got, want, tol)` from check.vh.\n",
                .{f.path},
            );
            return .fail;
        },
        // Still compiled below in non-strict mode: "does not crash" is a weak
        // claim but it is not nothing, and for an accept/reject-only compiler it
        // is the ONLY claim there was ever going to be.
        .tautology => |site| {
            try w.print(
                "FAIL {s}: assertion cannot fail — got and want are the same expression:\n" ++
                    "    {s}\n" ++
                    "  The want must be a NUMERIC LITERAL a human derived from the LRM.\n",
                .{ f.path, site },
            );
            return .fail;
        },
        .computed_want => |site| {
            try w.print(
                "FAIL {s}: want is an expression, not a literal:\n" ++
                    "    {s}\n" ++
                    "  An expression lets the compiler supply its own expectation, which is\n" ++
                    "  how a wrong answer gets frozen as correct. Write the digits.\n",
                .{ f.path, site },
            );
            return .fail;
        },
    }

    // Buffered: an xfail suppresses it (its reason is on the `//! xfail`
    // line); every other verdict emits it verbatim.
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const result = try compiler.check(compiler.ctx, gpa, io, arena, f, source, d, &aw.writer);
    const xfail = if (compiler.owns_xfail) d.xfail else null;

    switch (result) {
        .met => {
            // Green, and the fixture said it would not be: the gap is closed.
            // A hard FAIL, not a quiet pass — a marker that outlives its
            // limitation silences the next regression at that rule.
            if (xfail != null) {
                try w.print(
                    "FAIL {s}: XPASS — marked `//! xfail`, but {s} now does exactly what the\n" ++
                        "  fixture says it must. Delete the `//! xfail` line: the limitation is\n" ++
                        "  fixed, and a marker outliving it hides the next regression.\n",
                    .{ f.path, compiler.name },
                );
                return .fail;
            }
            return .pass;
        },
        .unmet => {
            if (xfail) |why| {
                try w.print("XFAIL {s}: known: {s}\n", .{ f.path, why });
                return .xfail;
            }
            try w.writeAll(aw.written());
            return .fail;
        },
        // Not a conformance answer, so the xfail marker does not touch it:
        // `unasserted` proves nothing and cannot show a gap is closed.
        .unasserted => {
            try w.writeAll(aw.written());
            return .unasserted;
        },
    }
}

/// The `vera` executable, for the one fixture no in-process runner can judge:
/// a `//! expect vcd` digital run, whose evidence is a FILE the run writes.
/// Set once by `tests/bench.zig`, which is handed the path; read-only after.
pub var vera_exe: ?[]const u8 = null;

/// Run the fixture in a scratch directory of its own and compare the file it
/// wrote against the golden. Only a runner that RUNS a design is asked: for an
/// accept/reject-only one the fixture asserts nothing it could meet.
fn judgeVcd(arena: std.mem.Allocator, io: Io, compiler: Compiler, f: Fixture, want: digital.VcdExpect, w: *Io.Writer) !Verdict {
    if (!compiler.runs) return .unasserted;
    const given = vera_exe orelse {
        try w.print("FAIL {s}: `//! expect vcd` needs the vera executable, and none was given\n", .{f.path});
        return .fail;
    };
    // Absolute, because the run's working directory is not this one.
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, given, arena);
    const dir = try std.fs.path.join(arena, &.{ options.work_root, "vcd", f.slug });
    try Io.Dir.cwd().createDirPath(io, dir);
    const produced = try std.fs.path.join(arena, &.{ dir, want.produced });
    Io.Dir.cwd().deleteFile(io, produced) catch {};
    const r = try std.process.run(arena, io, .{
        .argv = &.{ exe, "--run", "-I", f.root, "-I", f.dir(), f.path },
        .cwd = .{ .path = dir },
    });
    if (r.term != .exited or r.term.exited != 0) {
        try w.print("FAIL {s}: vera --run did not succeed ({any})\n{s}", .{ f.path, r.term, r.stderr });
        return .fail;
    }
    const got_text = Io.Dir.cwd().readFileAlloc(io, produced, arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: the run wrote no `{s}`\n", .{ f.path, want.produced });
        return .fail;
    };
    const golden = try std.fs.path.join(arena, &.{ f.dir(), want.golden });
    const want_text = Io.Dir.cwd().readFileAlloc(io, golden, arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: no golden VCD at {s}\n", .{ f.path, golden });
        return .fail;
    };
    const got = try digital.vcdTokens(arena, got_text);
    const expected = try digital.vcdTokens(arena, want_text);
    for (0..@max(got.len, expected.len)) |i| {
        const g = if (i < got.len) got[i] else "<end of file>";
        const e = if (i < expected.len) expected[i] else "<end of file>";
        if (std.mem.eql(u8, g, e)) continue;
        try w.print("FAIL {s}: VCD token {d} is `{s}`, the golden has `{s}`\n--- produced\n{s}\n", .{ f.path, i, g, e, got_text });
        return .fail;
    }
    return .pass;
}

test "digital opt-in is excluded from analog fixture collection" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const marked = "// digital-runner: reject\n//! reject no arguments\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "negative.v", .data = marked });
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.v", .data = "//! reject E0205\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "analog.va", .data = marked });
    try tmp.dir.writeFile(io, .{ .sub_path = "positive.v", .data = "//! lrm 9.10\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "positive.expected.txt", .data = "ok\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "host_design.va", .data = "module m; endmodule\n" });
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "negative.v") == null);
    try std.testing.expectEqualStrings(".v", fixtureExt(arena.allocator(), io, tmp.dir, "legacy.v").?);
    try std.testing.expectEqualStrings(".va", fixtureExt(arena.allocator(), io, tmp.dir, "analog.va").?);
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "positive.v") == null);
    // A `.va` a host test loads carries no directive and is not collected.
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "host_design.va") == null);
}

// The sub-files hold their own tests; Zig collects them only through a reference.
test {
    _ = lint;
    _ = coverage;
    _ = digital;
}
