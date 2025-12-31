//! The conformance harness — everything about running `tests/fixtures/**/*.va`
//! that is NOT about a particular compiler.
//!
//! It exists because the suite stopped being about VerA. A fixture states what
//! the LRM requires, so the same 1102 files are a conformance suite for ANY
//! Verilog-AMS compiler — and "how did compiler X do?" is only a useful
//! question if X and VerA are judged by identical rules. Sharing the judge is
//! the only way to be sure they are:
//!
//!   tests/harness.zig    the format, the verdict algebra, the report  (here)
//!   tests/torture.zig    plugs in VerA — compile, build a testbench, RUN it
//!   tests/external.zig   plugs in any compiler that takes a .va path and
//!                        exits nonzero when it refuses one (OpenVAF, …)
//!
//! WHAT A RUNNER SUPPLIES is one function: given a fixture, did the compiler do
//! what the fixture says it must? That boundary is where the two sides genuinely
//! differ — VerA is called in-process and can run the model, an external
//! compiler is a subprocess that can only accept or refuse — and it is ALL they
//! differ by. Everything downstream of the answer is here, so an xfail cannot
//! mean one thing for VerA and another for OpenVAF.
//!
//! WHAT THIS FILE OWNS, and why each piece is not the runner's business:
//!   - the fixture format: `//! reject` / `//! lrm` / `//! xfail`, parsed by
//!     `vera.tb.parse`, the same parser the fixtures were written against;
//!   - the assertion lint (`checkAssertions`): a want that is not a numeric
//!     literal is a FIXTURE defect, and it is one in every compiler;
//!   - the verdict algebra: xfail inverts a failure into `xfail` and a success
//!     into a hard FAIL, `cannot_run` outranks both, `--strict` fails on
//!     anything that is not a pass;
//!   - the parallel walk, the slot buffering, the tally, `--coverage`.
//!
//! Comparing two runs is `diff`: the walk is sorted, the report names each
//! fixture by path, and only the verdict lines vary. There is deliberately no
//! machine-readable side channel — a second output format is a second thing to
//! keep true, and the text already is one.
//!
//!   zig build torture                     # VerA, every fixture
//!   zig build conformance                 # OpenVAF, every fixture
//!   zig build torture -- ch04             # only paths matching `ch04`
//!   zig build torture -- --strict         # unasserted, cannot-run and xfail FAIL
//!   zig build torture -- --coverage       # every cited LRM section and who cites it
//!   zig build torture -- -j1              # one at a time, streaming; for debugging

const std = @import("std");
const vera = @import("vera");

const Io = std.Io;

/// Everything one fixture needs, all with the same lifetime.
pub const Fixture = struct {
    /// `tests/fixtures/ch04_expressions/01_arithmetic.va`
    path: []const u8,
    /// `01_arithmetic`
    stem: []const u8,
    /// `tests/fixtures/ch04_expressions`
    dir: []const u8,
    /// `ch04_expressions_01_arithmetic` — the scratch directory name.
    ///
    /// NOT the stem: three stems (`analog_event`, `discrete_discipline`,
    /// `multiple_analog_blocks`) appear in more than one chapter, and two
    /// fixtures sharing a scratch directory overwrite each other's output.
    /// Sequentially that is merely wasteful; in parallel it is a race that
    /// decides the verdict.
    slug: []const u8,
};

/// What the compiler under test did with one fixture, in the only vocabulary
/// both sides can speak.
///
/// It is not "accepted / rejected", because that answer alone does not say
/// whether the fixture is satisfied — a `//! reject` fixture wants a refusal and
/// every other fixture wants a compile, and only the runner knows how close its
/// compiler came. So a runner answers the question the harness actually asks —
/// did it do what the fixture says? — and writes the DETAIL to its report
/// writer. The harness may suppress that detail (see `xfail`), so a runner must
/// never print anywhere else.
pub const Result = union(enum) {
    /// Did what the fixture says it must.
    met,
    /// Did not. The reason is already in the report writer.
    unmet,
    /// Compiled and ran and asserted NOTHING. Only a runner whose compiler
    /// actually runs a model can return this; for the rest, a fixture that
    /// compiles has said all it can say.
    unasserted,
    /// The fixture is correct, the compiler is correct, and the HOST still will
    /// not run it. Not a conformance result in either direction, so it is not a
    /// pass and it is not a failure — see the verdict table below. The string is
    /// the short reason, for the summary.
    cannot_run: []const u8,
};

/// One compiler, plugged in.
pub const Compiler = struct {
    /// Names the compiler in the report — `vera`, `openvaf-r`.
    name: []const u8,
    /// Does this compiler RUN a fixture, or only accept or refuse it?
    ///
    /// Accept/reject is the part of a fixture that travels: "must not compile,
    /// per §5.8" is a claim any compiler can be held to. The `ok=1` columns are
    /// not — they need a host that stamps the device and prints a transcript.
    /// Set false and the harness stops asking for what cannot be answered: a
    /// fixture that asserts nothing is not held against the compiler, and the
    /// summary says which of the two questions the numbers answer.
    runs: bool,
    /// Is `//! xfail` a statement about THIS compiler?
    ///
    /// The marker means "the fixture is right and the compiler does not meet it
    /// yet", and a fixture can only carry one such claim — VerA's, since VerA is
    /// what the suite is developed against. Honouring it for anyone else
    /// INVERTS the fixture in both directions: a compiler that fails the rule is
    /// excused as XFAIL, and one that MEETS the rule is failed as an XPASS.
    /// Ignore it instead, and the fixture says exactly what the LRM says.
    owns_xfail: bool,
    /// Passed back to the two callbacks. `*anyopaque` and not a comptime type
    /// parameter so that `run` is one function and not one per runner.
    ctx: *anyopaque,
    /// THE plug. Judge one fixture; write any detail to `w`.
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
    /// Offered every command-line argument before the harness looks at it;
    /// return true to consume one. For the knobs that are genuinely about the
    /// compiler and not about the suite (`--fixture-opt=`, `--cc=`).
    arg: ?*const fn (ctx: *anyopaque, a: []const u8) bool = null,
};

pub const Verdict = enum {
    /// Behaved as the fixture said it would.
    pass,
    /// Did not.
    fail,
    /// Compiled, ran, and asserted NOTHING. Green under a suite that only looks
    /// for a crash, and the reason this harness exists.
    unasserted,
    /// A host limitation, not a conformance result. Distinct from `fail`
    /// because the fixture's author has no move to make.
    refused,
    /// Did not behave as the fixture said — and the fixture said so in advance
    /// with `//! xfail`. The rule is real, this compiler does not meet it yet.
    /// Not a pass either.
    xfail,
};

const Counts = struct {
    passed: usize = 0,
    failed: usize = 0,
    unasserted: usize = 0,
    refused: usize = 0,
    xfail: usize = 0,

    fn add(c: *Counts, v: Verdict) void {
        switch (v) {
            .pass => c.passed += 1,
            .fail => c.failed += 1,
            .unasserted => c.unasserted += 1,
            .refused => c.refused += 1,
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
/// The unit of work is one whole fixture, and fixtures share nothing: separate
/// source, separate scratch directory (`Fixture.slug`), separate output slot. So
/// the only synchronisation needed is which one to take next.
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

/// A runner's whole `main`: hand over the process and the compiler.
pub fn run(init: std.process.Init, fixture_root: []const u8, compiler: Compiler) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var strict = false;
    var coverage = false;
    var filter: ?[]const u8 = null;
    // One thread per core, because a fixture is a whole compilation and that is
    // where the runtime goes. `-j1` is the escape hatch, below.
    var jobs: usize = std.Thread.getCpuCount() catch 1;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (compiler.arg) |take| if (take(compiler.ctx, a)) continue;
        if (std.mem.eql(u8, a, "--strict")) strict = true //
        else if (std.mem.eql(u8, a, "--coverage")) coverage = true //
        else if (numeric(a, "-j") orelse numeric(a, "--jobs=")) |n| jobs = @max(n, 1) //
        else filter = a;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const w = &stderr.interface;

    const fixtures = try collect(arena, io, fixture_root, filter);
    if (fixtures.len == 0) {
        try w.print("{s}: no fixtures under {s}\n", .{ compiler.name, fixture_root });
        try w.flush();
        return 1;
    }

    if (coverage) {
        try reportCoverage(arena, io, fixtures, w);
        try w.flush();
        return 0;
    }

    var counts: Counts = .{};
    if (jobs <= 1) {
        // The sequential path, kept working on purpose: it prints as it goes,
        // which is the only way to see WHICH fixture a run is stuck on.
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
        while (hands < jobs) : (hands += 1) {
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
    return if (counts.failed == 0 and
        !(strict and (counts.unasserted != 0 or counts.refused != 0 or counts.xfail != 0))) 0 else 1;
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
    if (c.refused != 0) try w.print(
        "  {d} CANNOT RUN — a known HOST limitation, not a fixture defect and not a\n" ++
            "  conformance result: each is printed above with its reason. Not counted as\n" ++
            "  a pass, because nothing was proved. Do not edit the fixture to make it\n" ++
            "  run — that changes what it tests. (`--strict` fails on these, so the\n" ++
            "  limitation cannot be quietly carried forever.)\n",
        .{c.refused},
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

/// `--coverage`: every `//! lrm` cite in the run, sorted, with the fixtures
/// citing it.
///
/// It cannot say a clause is UNcited — nothing here has the LRM's table of
/// contents, and inventing one would be a second document to drift. What it
/// does is make the cited set mechanical: greppable, diffable, and countable,
/// which is the check a "we cover chapter 4" claim currently has no way to
/// back up.
fn reportCoverage(arena: std.mem.Allocator, io: Io, fixtures: []const Fixture, w: *Io.Writer) !void {
    const Cite = struct { section: []const u8, path: []const u8 };
    var cites: std.ArrayList(Cite) = .empty;
    var citing: usize = 0;
    for (fixtures) |f| {
        const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));
        // A fixture whose directives do not parse is reported by the run
        // proper; a coverage report is not the place to fail on it.
        const d = vera.tb.parse(arena, source) catch continue;
        if (d.lrm.len != 0) citing += 1;
        for (d.lrm) |s| try cites.append(arena, .{ .section = s, .path = f.path });
    }
    std.mem.sort(Cite, cites.items, {}, struct {
        fn lt(_: void, a: Cite, b: Cite) bool {
            if (std.mem.eql(u8, a.section, b.section)) return std.mem.lessThan(u8, a.path, b.path);
            return sectionLessThan(a.section, b.section);
        }
    }.lt);

    var sections: usize = 0;
    var prev: []const u8 = "";
    for (cites.items) |c| {
        if (!std.mem.eql(u8, c.section, prev)) {
            try w.print("§{s}\n", .{c.section});
            prev = c.section;
            sections += 1;
        }
        try w.print("  {s}\n", .{c.path});
    }
    try w.print("\n{d} LRM section(s) cited by {d} of {d} fixtures\n", .{
        sections, citing, fixtures.len,
    });
}

/// Order cites the way the LRM's contents page does: numerically per component,
/// so §10 follows §9 instead of §1, and chapters come before annexes.
fn sectionLessThan(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = ia.next() orelse return ib.next() != null; // a prefix sorts first
        const pb = ib.next() orelse return false;
        if (std.mem.eql(u8, pa, pb)) continue;
        const na = std.fmt.parseInt(u32, pa, 10) catch null;
        const nb = std.fmt.parseInt(u32, pb, 10) catch null;
        if (na != null and nb != null) return na.? < nb.?;
        if (na != null) return true;
        if (nb != null) return false;
        return std.mem.lessThan(u8, pa, pb);
    }
}

/// Sorted so the run is deterministic (`Dir.walk` order is explicitly undefined)
/// and a failing run is reproducible and diffable. `filter` is a plain substring
/// over the whole path: `zig build torture -- ch04` runs one group.
pub fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, filter: ?[]const u8) ![]const Fixture {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var list: std.ArrayList(Fixture) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".va")) continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.path });
        if (filter) |f| if (std.mem.indexOf(u8, path, f) == null) continue;
        const base = std.fs.path.basename(path);
        const slug = try arena.dupe(u8, entry.path[0 .. entry.path.len - ".va".len]);
        for (slug) |*c| if (c.* == '/' or c.* == '\\') {
            c.* = '_';
        };
        try list.append(arena, .{
            .path = path,
            .stem = base[0 .. base.len - ".va".len],
            .dir = std.fs.path.dirname(path) orelse ".",
            .slug = slug,
        });
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return list.items;
}

// ---------------------------------------------------------------------------
// The verdict algebra — the whole reason both runners share this file
// ---------------------------------------------------------------------------

/// One fixture, from source text to verdict.
///
/// The runner answers `met` / `unmet`; everything that turns that into a verdict
/// is here, so `//! xfail` cannot mean one thing for VerA and another for the
/// compiler it is being compared against.
fn judge(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    compiler: Compiler,
    f: Fixture,
    strict: bool,
    w: *Io.Writer,
) !Verdict {
    const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));

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
        .pass, .unasserted, .refused => {},
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
    // A malformed assertion is the FIXTURE's defect, in every compiler, and no
    // `//! xfail` may launder it: a marker on a fixture whose want is an
    // expression would be carried forever and prove nothing on the day the gap
    // closes. Checked before the fixture costs a compile — and not on a `//!
    // reject` fixture, which is not expected to reach a transcript at all.
    const lint = if (d.reject.len != 0) .ok else checkAssertions(source);
    switch (lint) {
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

    // The runner's detail is buffered, not streamed: for an xfail it is not news
    // — WHAT the compiler does not do belongs on the `//! xfail` line, where it
    // can be triaged without rerunning — and every other verdict emits it
    // verbatim.
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
        // Neither of these is a conformance answer, so neither is touched by the
        // marker: `unasserted` proves nothing, so it cannot show a gap is
        // closed, and `cannot_run` is the HOST's limitation, which outranks the
        // compiler's. Both keep their own report.
        .unasserted => {
            try w.writeAll(aw.written());
            return .unasserted;
        },
        .cannot_run => {
            try w.writeAll(aw.written());
            return .refused;
        },
    }
}

// ---------------------------------------------------------------------------
// The assertion lint — the mechanical half of "restricting and true"
// ---------------------------------------------------------------------------

pub const AssertionCheck = union(enum) {
    /// At least one assertion, and every one of them can fail.
    ok,
    /// No `CHECK` macro anywhere in the source.
    none,
    /// `CHECK("x", expr, expr, tol)` — got and want are textually identical.
    tautology: []const u8,
    /// The want is not a numeric literal, so it may be the compiler's own output.
    computed_want: []const u8,
};

/// Run on RAW source, before the fixture costs a compile.
///
/// TRUE cannot be mechanised — whether `0.479425538604203` really is sin(0.5) is
/// a human's job, once, at review. What CAN be mechanised is the thing that made
/// the deleted snapshots worthless: the want must be a literal a human typed,
/// never an expression the compiler under test evaluates. `CHECK("sin", sin(0.5),
/// sin(0.5), 1e-15)` passes in any compiler, correct or not, and this rejects it.
pub fn checkAssertions(source: []const u8) AssertionCheck {
    var found = false;
    var rest = source;
    while (std.mem.indexOf(u8, rest, "`CHECK")) |at| {
        rest = rest[at..];
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse break;
        const close = matchParen(rest, open) orelse break;
        const site = trimLine(rest[0..@min(close + 1, rest.len)]);

        // `CHECKEQ` is the marked relational form: its want is another
        // expression on purpose, so the literal rule does not apply to it.
        const relational = std.mem.startsWith(u8, rest, "`CHECKEQ");

        var args: [8][]const u8 = undefined;
        const n = splitArgs(rest[open + 1 .. close], &args);
        rest = rest[close + 1 ..];
        // NAME, GOT, WANT[, TOL] — every CHECK* form puts the want third.
        if (n < 3) continue;
        found = true;

        const got = stripParens(std.mem.trim(u8, args[1], " \t\r\n\\"));
        const want = stripParens(std.mem.trim(u8, args[2], " \t\r\n\\"));
        if (std.mem.eql(u8, got, want)) {
            // Two identical LITERALS are a round-trip check on the lexer
            // (`CHECKI("unary minus", -7, -7)`) — weak, but it can fail if a
            // literal is mangled on one side. Two identical EXPRESSIONS cannot
            // fail at all, whatever the compiler does.
            if (!isNumericLiteral(got)) return .{ .tautology = site };
        } else if (!relational and !isNumericLiteral(want)) {
            return .{ .computed_want = site };
        }
    }
    return if (found) .ok else .none;
}

/// Drop redundant outer parentheses, so `(V(a,b))` and `V(a,b)` compare equal.
/// Without this, wrapping one side of an assertion in parens is enough to hide
/// a tautology from the check below — which is exactly how one got written.
fn stripParens(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    while (t.len >= 2 and t[0] == '(' and matchParen(t, 0) == t.len - 1) {
        t = std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
    }
    return t;
}

/// Index of the `)` closing the `(` at `open`, or null if unbalanced. String
/// literals are skipped so a `")"` inside a CHECK's name does not close it.
fn matchParen(s: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    var in_string = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Split on TOP-LEVEL commas only: `CHECKR("atan2(1,1)", atan2(1.0, 1.0), …)`
/// has commas inside both a string and a nested call, and neither separates an
/// argument. Returns the count written.
fn splitArgs(s: []const u8, out: *[8][]const u8) usize {
    var n: usize = 0;
    var depth: usize = 0;
    var in_string = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ',' => if (depth == 0) {
                if (n == out.len) return n;
                out[n] = s[start..i];
                n += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    if (n < out.len and start <= s.len) {
        out[n] = s[start..];
        n += 1;
    }
    return n;
}

/// Is this text a number a human wrote, and nothing else?
///
/// Deliberately strict. A leading sign and a Verilog-A real or integer literal
/// are all that is allowed — no `M_PI`, no `1.0/3.0`, no identifiers. A fixture
/// that wants pi writes its digits, which is what a reviewer checks against the
/// LRM anyway, and which no amount of compiler misbehaviour can change.
fn isNumericLiteral(s: []const u8) bool {
    var t = s;
    if (t.len != 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
    if (t.len == 0) return false;

    var seen_digit = false;
    var seen_dot = false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        switch (t[i]) {
            '0'...'9' => seen_digit = true,
            '_' => {}, // §2.5.1 allows underscores in numbers.
            '.' => {
                if (seen_dot) return false;
                seen_dot = true;
            },
            'e', 'E' => {
                if (!seen_digit) return false;
                // Exponent: an optional sign then digits, to the end.
                var j = i + 1;
                if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
                if (j == t.len) return false;
                while (j < t.len) : (j += 1) switch (t[j]) {
                    '0'...'9', '_' => {},
                    else => return false,
                };
                return true;
            },
            else => return false,
        }
    }
    return seen_digit;
}

/// The macro call as one line, for an error message. A CHECK often spans lines
/// via `\` continuations, and a four-line quote buries the point.
fn trimLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return std.mem.trim(u8, s[0..end], " \t\r\\");
}

test "an assertion whose want is the got cannot fail" {
    try std.testing.expect(checkAssertions(
        \\`CHECK("sin", sin(0.5), sin(0.5), 1e-15);
    ) == .tautology);
    try std.testing.expect(checkAssertions(
        \\`CHECKX("round trip", y, expected_y);
    ) == .computed_want);
    try std.testing.expect(checkAssertions("I(p,n) <+ 1.0;") == .none);
    try std.testing.expect(checkAssertions(
        \\`CHECKR("atan2(1,1)", atan2(1.0, 1.0), 0.7853981633974483, 1e-15);
    ) == .ok);
    // A negative and an exponent are both literals a human typed.
    try std.testing.expect(checkAssertions(
        \\`CHECK("limexp underflow", limexp(-80.0), -1.8048513878454153e-35, 1e-40);
    ) == .ok);
    // Two identical literals round-trip the lexer; two identical expressions
    // cannot fail whatever the compiler does.
    try std.testing.expect(checkAssertions(
        \\`CHECKI("unary minus", -7, -7);
    ) == .ok);
    try std.testing.expect(checkAssertions(
        \\`CHECKI("above threshold?", V(p, n) > vth, (V(p, n) > vth));
    ) == .tautology);
    // The marked relational form may pin two expressions together...
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("branch probe equals the node pair", V(br), V(a, b), 0.0);
    ) == .ok);
    // ...but not to itself.
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("vacuous", V(a, b), V(a, b), 0.0);
    ) == .tautology);
}

test "lrm cites sort like a contents page, not like strings" {
    try std.testing.expect(sectionLessThan("9.4", "10.1")); // not lexicographic
    try std.testing.expect(!sectionLessThan("10.1", "9.4"));
    try std.testing.expect(sectionLessThan("4.5", "4.5.11"));
    try std.testing.expect(sectionLessThan("4.5.2", "4.5.11"));
    try std.testing.expect(sectionLessThan("12", "A.1")); // chapters before annexes
    try std.testing.expect(sectionLessThan("A.1.2", "B"));
    try std.testing.expect(!sectionLessThan("5.8", "5.8"));
}
