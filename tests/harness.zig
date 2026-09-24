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
//!   tests/bench.zig      the one binary that owns `main` and drives all three
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
//!     into a hard FAIL, `--strict` fails on anything that is not a pass;
//!   - the parallel walk, the slot buffering, the tally, `--coverage`.
//!
//! Comparing two runs is `diff`: the walk is sorted, the report names each
//! fixture by path, and only the verdict lines vary. There is deliberately no
//! machine-readable side channel — a second output format is a second thing to
//! keep true, and the text already is one.
//!
//!   zig build benchmark                          # VerA, every fixture, timed
//!   zig build benchmark -- --against-openvaf     # the head-to-head
//!   zig build benchmark -- ch04                  # only paths matching `ch04`
//!   zig build benchmark -- --strict              # unasserted and xfail FAIL
//!   zig build benchmark -- --coverage            # LRM clauses cited and uncited
//!   zig build benchmark -- -j1                   # one at a time; for debugging
//!   zig build benchmark -- --fixture-root=tests/pending   # the tree meant to fail

const std = @import("std");
const vera = @import("vera");
/// `fixture_root` and `docs_root`, from `build.zig`. They are the SUITE's and
/// not a runner's: both runners walk the same fixtures and cite the same LRM,
/// so a runner that could disagree about either would be judging a different
/// suite while reporting under the same verdict vocabulary.
const options = @import("suite_options");

const Io = std.Io;

/// Everything one fixture needs, all with the same lifetime.
pub const Fixture = struct {
    /// `tests/fixtures/ch04_expressions/01_arithmetic.va`
    path: []const u8,
    /// `01_arithmetic`
    stem: []const u8,
    /// `tests/fixtures/ch04_expressions`
    dir: []const u8,
    /// The suite root this fixture was collected from — `tests/fixtures`, or
    /// `tests/pending` under `--fixture-root=`. A runner needs it as a second
    /// include dir (`check.vh` lives at the root, not beside the fixture) and
    /// as the scratch namespace, and taking it from the fixture rather than
    /// from `suite_options` is what lets one binary walk either tree.
    root: []const u8,
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
};

/// Every knob the SUITE has, parsed once by `tests/bench.zig` and handed to
/// everything that needs one.
///
/// It is a value and not a per-runner argument callback because there is one
/// run of the suite now and up to three compilers inside it: the VerA plug, the
/// same plug reduced to accept/reject, and the foreign compiler. A filter or a
/// `--fixture-root` that reached one of them and not the others would be a
/// head-to-head over two different fixture sets.
pub const Config = struct {
    /// `tests/pending` is the approved-but-unimplemented tree: the same rules,
    /// fixtures VerA does not meet yet, and a nonzero exit is its expected
    /// state. A run-time path and not a second options module, because one
    /// binary would otherwise need a second copy of itself to walk a second
    /// directory.
    root: []const u8 = options.fixture_root,
    /// A plain substring over the whole path.
    filter: ?[]const u8 = null,
    strict: bool = false,
    coverage: bool = false,
    /// One thread per core, because a fixture is a whole compilation and that
    /// is where the runtime goes. `-j1` is the escape hatch: it prints as it
    /// goes, which is the only way to see WHICH fixture a run is stuck on.
    jobs: usize = 0,
    /// `-Doptimize` builds the RUNNER; this builds the per-fixture testbench
    /// binaries the runner spawns a `zig build-exe` for. Two different
    /// programs, so two different defaults — and Debug is right for the
    /// fixtures, see the fixture-opt note in tests/torture.zig.
    ///
    /// Debug LITERALLY and not through a build option: `-Dfixture-optimize`
    /// could not pass an enum (`addOption` emits its own copy of the type,
    /// which is then a different type from `std.builtin.OptimizeMode` here), so
    /// it went across as the tag name and came back through `stringToEnum`
    /// with an `.?` on the end. Three moving parts for a default nobody moved.
    fixture_opt: std.builtin.OptimizeMode = .Debug,

    pub fn init() Config {
        return .{ .jobs = std.Thread.getCpuCount() catch 1 };
    }
};

/// Consume one argument if it is the suite's; false leaves it to the caller.
/// The unrecognised word is the filter, and that decision stays with
/// `tests/bench.zig` so a typo'd flag of ITS own is not silently a filter.
pub fn takeArg(cfg: *Config, a: []const u8) bool {
    if (std.mem.eql(u8, a, "--strict")) cfg.strict = true //
    else if (std.mem.eql(u8, a, "--coverage")) cfg.coverage = true //
    else if (std.mem.startsWith(u8, a, "--fixture-root=")) cfg.root = a["--fixture-root=".len..] //
    else if (std.mem.startsWith(u8, a, "--fixture-opt=")) {
        const name = a["--fixture-opt=".len..];
        cfg.fixture_opt = std.meta.stringToEnum(std.builtin.OptimizeMode, name) orelse {
            std.debug.print("suite: not an optimize mode: {s}\n", .{name});
            std.process.exit(2);
        };
    } else if (numeric(a, "-j") orelse numeric(a, "--jobs=")) |n| cfg.jobs = @max(n, 1) //
    else return false;
    return true;
}

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
    /// ONE reason only, and that is deliberate. A second used to be admitted — a
    /// fixture whose clause is CONDITIONAL on something false for this tool, so
    /// the requirement never bound it, with Annex E's SPICE-netlist family
    /// (E.1.1: "if a simulator is also able to read SPICE netlists") as the whole
    /// of that set. Those three fixtures pass now: VerA reads `.MODEL` and
    /// `.SUBCKT` cards (lib/frontend/spice_cards.zig), which made the antecedent
    /// true instead of arguing about whom it bound. Nothing else in the suite was
    /// ever in that category, so an xfail here means one thing: a real
    /// requirement this compiler does not meet yet.
    xfail,
};

pub const Counts = struct {
    passed: usize = 0,
    failed: usize = 0,
    unasserted: usize = 0,
    xfail: usize = 0,

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

/// The judged pass: every fixture, this compiler, the report on stderr.
///
/// `tally` receives the counts the summary prints, because the head-to-head
/// table wants them as a row and re-deriving them would be a second place for
/// "how many passed" to be computed.
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
        const ok = try reportCoverage(arena, io, options.docs_root, cfg.root, cfg.filter, fixtures, w);
        try w.flush();
        return if (ok) 0 else 1;
    }

    const strict = cfg.strict;
    var counts: Counts = .{};
    if (cfg.jobs <= 1) {
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

/// `--coverage`: the cited set, the UNCITED set, and the cites that name no
/// clause at all — all three against `docs/*.html`, which is the LRM this suite
/// is written from.
///
/// This used to be the cited half alone, and said so: "it cannot say a clause is
/// UNcited — nothing here has the LRM's table of contents, and inventing one
/// would be a second document to drift." The objection was right and the
/// conclusion was not. `docs/` IS the specification; reading the contents page
/// out of it at run time invents nothing and cannot drift, because there is no
/// second copy to keep true. Without it "the suite is comprehensive" is an
/// opinion — a citation list can only ever be evidence about the questions
/// somebody already thought to ask.
///
/// A cite carries its fixture's declared POLARITY. This is a static inventory:
/// no compilation or execution happens here. Neither a positive citation nor
/// a rejection citation proves the cited rule. In particular, an XFAIL still
/// contributes a citation and a rejection can pin an implementation limitation.
/// Conforming to a clause by only ever refusing it is the
/// failure mode a cited/uncited count cannot see, and it is not hypothetical
/// here — `$simprobe`, the `zi_*` non-zero-tau forms and the whole §9.22 family
/// are diagnosed and never implemented. So the report separates `+` from `-`
/// and names the one-sided clauses.
///
/// A one-sided clause is NOT automatically a gap: a clause that states no error
/// has nothing to reject, and one that only forbids has nothing to run. Which is
/// why this prints the list and does not score it — the judgement is per clause
/// and belongs to whoever reads the LRM sentence.
///
/// The `.c` VPI fixtures cite with the same `//! lrm` lines (`cCites`), with
/// per-line polarity, and count only when `build.zig` runs them: a `.c` that
/// only compiles is listed as `~` and moves no number.
///
/// Returns whether every cite resolved. An unresolved cite is a FIXTURE defect
/// of the same family the format already fails on (a cite that is not a section
/// number), so it is the one thing here that decides an exit code. An uncited or
/// one-sided clause is a work item, not a defect, and does not.
fn reportCoverage(
    arena: std.mem.Allocator,
    io: Io,
    docs_root: []const u8,
    root: []const u8,
    filter: ?[]const u8,
    fixtures: []const Fixture,
    w: *Io.Writer,
) !bool {
    const clauses = try lrmClauses(arena, io, docs_root);
    try w.writeAll(
        "STATIC CITATION INVENTORY — fixtures are not executed by --coverage.\n" ++
            "Both polarities cited does not establish passing tests, valid oracles,\n" ++
            "all rules within a clause, or Verilog-A applicability. XFAIL citations\n" ++
            "and implementation-limit rejections remain in this inventory.\n\n",
    );

    var cites: std.ArrayList(Cite) = .empty;
    var citing: usize = 0;
    for (fixtures) |f| {
        const source = try Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(1 << 20));
        // A fixture whose directives do not parse is reported by the run
        // proper; a coverage report is not the place to fail on it.
        const d = vera.tb.parse(arena, source) catch continue;
        if (d.lrm.len != 0) citing += 1;
        for (d.lrm) |s| try cites.append(arena, .{
            .section = s,
            .path = f.path,
            .side = if (d.reject.len != 0) .neg else .pos,
        });
    }
    const c_files = try cFixtures(arena, io, root, filter);
    var bad_tags: usize = 0;
    for (c_files) |path| {
        const source = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        const before = cites.items.len;
        cCites(arena, &cites, path, source, cFixtureRuns(path)) catch |err| switch (err) {
            error.BadCTag => {
                try w.print("BAD TAG — {s}: a `//!` line that is not `lrm <clause>` or `lrm-reject <clause>`\n", .{path});
                bad_tags += 1;
                continue;
            },
            else => |e| return e,
        };
        for (cites.items[before..]) |c| if (c.side != .compiled) {
            citing += 1;
            break;
        };
    }
    std.mem.sort(Cite, cites.items, {}, struct {
        fn lt(_: void, a: Cite, b: Cite) bool {
            if (std.mem.eql(u8, a.section, b.section)) return std.mem.lessThan(u8, a.path, b.path);
            return sectionLessThan(a.section, b.section);
        }
    }.lt);

    // Declared fixture intent only. Results and rule-level evidence are not
    // inputs to this report, so neither flag can mean a verified obligation.
    const Sides = struct { pos: bool = false, neg: bool = false };
    var cited: std.StringHashMapUnmanaged(Sides) = .empty;
    for (cites.items) |c| {
        // A compile-only `.c` cite is listed, never counted: it is not runtime
        // evidence of either polarity.
        if (c.side == .compiled) continue;
        const g = try cited.getOrPut(arena, c.section);
        if (!g.found_existing) g.value_ptr.* = .{};
        if (c.side == .neg) g.value_ptr.neg = true else g.value_ptr.pos = true;
    }
    var compiled: std.StringHashMapUnmanaged(void) = .empty;
    for (cites.items) |c| if (c.side == .compiled) try compiled.put(arena, c.section, {});

    var prev: []const u8 = "";
    for (cites.items) |c| {
        if (!std.mem.eql(u8, c.section, prev)) {
            try w.print("§{s}\n", .{c.section});
            prev = c.section;
        }
        // `+` declares a positive fixture, `-` declares a rejection fixture,
        // `~` a compile-only `.c` fixture. Show each path so a reviewer can
        // inspect the actual evidence.
        try w.print("  {s} {s}\n", .{ switch (c.side) {
            .pos => "+",
            .neg => "-",
            .compiled => "~",
        }, c.path });
    }

    // The cites that name nothing in the LRM. Sorted with everything else, so
    // this walk is over the same array and only has to skip what resolved.
    var unresolved: usize = 0;
    prev = "";
    for (cites.items) |c| {
        if (clauses.get(c.section) != null) continue;
        if (!std.mem.eql(u8, c.section, prev)) {
            if (unresolved == 0) try w.print(
                "\nUNRESOLVED — a `//! lrm` cite naming no clause in {s}. Either the\n" ++
                    "clause is spelled wrong or it is a table or figure number, which is a\n" ++
                    "different numbering space (Table G.7 lives under clause G.1).\n",
                .{docs_root},
            );
            try w.print("§{s}\n", .{c.section});
            prev = c.section;
            unresolved += 1;
        }
        try w.print("  {s}\n", .{c.path});
    }

    // The three work lists, in one walk of the contents page. Titles are printed
    // because a bare number is not a work item and "§7.8.2" plus "Signal
    // segmentation" is.
    var uncited: std.ArrayList(Clause) = .empty;
    var pos_only: std.ArrayList(Clause) = .empty;
    var neg_only: std.ArrayList(Clause) = .empty;
    var it = clauses.valueIterator();
    while (it.next()) |cl| {
        const s = cited.get(cl.id) orelse {
            try uncited.append(arena, cl.*);
            continue;
        };
        if (s.pos and !s.neg) try pos_only.append(arena, cl.*);
        if (s.neg and !s.pos) try neg_only.append(arena, cl.*);
    }
    const byId = struct {
        fn lt(_: void, a: Clause, b: Clause) bool {
            return sectionLessThan(a.id, b.id);
        }
    }.lt;
    for ([_]*std.ArrayList(Clause){ &uncited, &pos_only, &neg_only }) |l|
        std.mem.sort(Clause, l.items, {}, byId);

    // CLAUSE-AUDIT §5 classifications. A one-way or uncited clause the audit
    // classifies leaves its work list for a fifth bucket, printed with its
    // evidence so a reviewer reads the quote rather than the count. A clause
    // tested both ways stays there: a classification never outranks evidence.
    const classes = try readClassifications(arena, io, root, &clauses, &cited, w);
    var classified: std.ArrayList(Classified) = .empty;
    for ([_]*std.ArrayList(Clause){ &uncited, &pos_only, &neg_only }) |l| {
        var keep: usize = 0;
        for (l.items) |cl| {
            if (classes.map.get(cl.id)) |c| {
                try classified.append(arena, .{ .clause = cl, .row = c });
                continue;
            }
            l.items[keep] = cl;
            keep += 1;
        }
        l.shrinkRetainingCapacity(keep);
    }
    std.mem.sort(Classified, classified.items, {}, struct {
        fn lt(_: void, a: Classified, b: Classified) bool {
            return sectionLessThan(a.clause.id, b.clause.id);
        }
    }.lt);

    if (neg_only.items.len != 0) {
        try w.print(
            "\nREJECTION CITATIONS ONLY — every citing fixture declares `//! reject`.\n" ++
                "Review whether it pins a normative prohibition, an implementation\n" ++
                "choice, or a missing feature. No positive behavior is established.\n",
            .{},
        );
        for (neg_only.items) |cl| try w.print("§{s} {s}  ({s})\n", .{ cl.id, cl.title, cl.file });
    }
    if (pos_only.items.len != 0) {
        try w.print(
            "\nPOSITIVE CITATIONS ONLY — no `//! reject` fixture cites these, so no citation pins\n" ++
                "what the clause rules OUT. A clause that states no error has nothing to\n" ++
                "reject and belongs here; one whose text says `shall not` or `is an\n" ++
                "error` does not.\n",
            .{},
        );
        for (pos_only.items) |cl| try w.print("§{s} {s}  ({s})\n", .{ cl.id, cl.title, cl.file });
    }
    if (uncited.items.len != 0) {
        try w.print("\nUNCITED — no fixture names these at all:\n", .{});
        for (uncited.items) |cl| try w.print("§{s} {s}  ({s}){s}\n", .{
            cl.id,
            cl.title,
            cl.file,
            if (compiled.contains(cl.id)) "  ~ compile-only .c cite" else "",
        });
    }

    if (classified.items.len != 0) {
        try w.print(
            "\nCLASSIFIED — CLAUSE-AUDIT §5: the clause states no obligation an input can\n" ++
                "break, or its obligation is of a kind a fixture may not pin one way. Each\n" ++
                "row is a reviewed claim, not evidence; its quote is in the file named.\n",
            .{},
        );
        for (classified.items) |c| try w.print("§{s} {s}  [{s}]  ({s})\n", .{
            c.clause.id, c.clause.title, @tagName(c.row.kind), c.row.file,
        });
    }

    const n = clauses.count();
    var uncited_classified: usize = 0;
    for (classified.items) |c| {
        if (cited.get(c.clause.id) == null) uncited_classified += 1;
    }
    try w.print(
        "\n{d} of {d} LRM clauses cited, by {d} of {d} fixtures\n" ++
            "  {d} cited both ways · {d} positive citations only · {d} rejection citations only · {d} uncited · {d} classified\n",
        .{
            n - uncited.items.len - uncited_classified,                                                   n,
            citing,                                                                                        fixtures.len + c_files.len,
            n - uncited.items.len - pos_only.items.len - neg_only.items.len - classified.items.len,       pos_only.items.len,
            neg_only.items.len,                                                                            uncited.items.len,
            classified.items.len,
        },
    );
    var compiled_only: usize = 0;
    for (uncited.items) |cl| {
        if (compiled.contains(cl.id)) compiled_only += 1;
    }
    if (compiled_only != 0) try w.print(
        "  {d} of the uncited carry only compile-only `.c` cites (`~`), which are not counted\n",
        .{compiled_only},
    );
    if (unresolved != 0) try w.print("{d} cite(s) resolve to no clause\n", .{unresolved});
    if (bad_tags != 0) try w.print("{d} `.c` fixture(s) carry a malformed tag\n", .{bad_tags});
    if (classes.bad != 0) try w.print("{d} CLAUSES.tsv row(s) rejected\n", .{classes.bad});
    return unresolved == 0 and bad_tags == 0 and classes.bad == 0;
}

/// The CLAUSE-AUDIT §5 kinds a `CLAUSES.tsv` row may name, plus
/// `no_prohibition`: a normative clause whose every sentence is positive, so
/// its positive fixtures are the whole obligation and there is nothing to
/// reject. That one kind is checked against the evidence: it is refused unless
/// a positive fixture cites the clause.
const ClassKind = enum {
    non_normative,
    no_prohibition,
    optional,
    implementation_defined,
    resource_limit,
    unspecified,
};

const ClassRow = struct { kind: ClassKind, file: []const u8 };
const Classified = struct { clause: Clause, row: ClassRow };

/// Read every `CLAUSES.tsv` directly under a fixture directory of `root`.
/// A row is `<clause>\t<kind>\t<evidence>`; `#` starts a comment line. The
/// kind is spelled with hyphens (`non-normative`). A row that names no clause,
/// names an unknown kind, carries no evidence, or claims `no-prohibition` for
/// a clause no positive fixture cites is REJECTED: printed, not counted, and it
/// fails the run the way an unresolved cite does.
fn readClassifications(
    arena: std.mem.Allocator,
    io: Io,
    root: []const u8,
    clauses: *const std.StringHashMapUnmanaged(Clause),
    cited: anytype,
    w: *Io.Writer,
) !struct { map: std.StringHashMapUnmanaged(ClassRow), bad: usize } {
    var map: std.StringHashMapUnmanaged(ClassRow) = .empty;
    var bad: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .map = map, .bad = 0 },
        else => return err,
    };
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.eql(u8, e.basename, "CLAUSES.tsv")) continue;
        try files.append(arena, try std.fs.path.join(arena, &.{ root, e.path }));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (files.items) |path| {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0 or line[0] == '#') continue;
            const why = classifyRow(arena, line, clauses, cited) catch |err| {
                try w.print("BAD CLASSIFICATION — {s}:{d}: {s}\n", .{ path, line_no, @errorName(err) });
                bad += 1;
                continue;
            };
            const g = try map.getOrPut(arena, why.id);
            if (!g.found_existing) g.value_ptr.* = .{ .kind = why.kind, .file = path };
        }
    }
    return .{ .map = map, .bad = bad };
}

fn classifyRow(
    arena: std.mem.Allocator,
    line: []const u8,
    clauses: *const std.StringHashMapUnmanaged(Clause),
    cited: anytype,
) !struct { id: []const u8, kind: ClassKind } {
    var cols = std.mem.splitScalar(u8, line, '\t');
    var id = std.mem.trim(u8, cols.next() orelse return error.MissingClause, " ");
    if (id.len != 0 and std.mem.startsWith(u8, id, "§")) id = id["§".len..];
    if (clauses.get(id) == null) return error.UnknownClause;
    const kind_text = std.mem.trim(u8, cols.next() orelse return error.MissingKind, " ");
    const spelled = try arena.dupe(u8, kind_text);
    std.mem.replaceScalar(u8, spelled, '-', '_');
    const kind = std.meta.stringToEnum(ClassKind, spelled) orelse return error.UnknownKind;
    const evidence = std.mem.trim(u8, cols.rest(), " \t");
    if (evidence.len == 0) return error.MissingEvidence;
    if (kind == .no_prohibition) {
        const s = cited.get(id) orelse return error.NoPositiveFixture;
        if (!s.pos) return error.NoPositiveFixture;
    }
    return .{ .id = id, .kind = kind };
}

/// One `//! lrm` citation and the polarity its fixture declares.
const Cite = struct {
    section: []const u8,
    path: []const u8,
    side: enum { pos, neg, compiled },
};

/// The `.c` VPI fixtures under `root`. `collect` does not walk them: they are
/// C applications, not VerA source, and only `--coverage` reads them.
fn cFixtures(arena: std.mem.Allocator, io: Io, root: []const u8, filter: ?[]const u8) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".c")) continue;
        const path = try std.fs.path.join(arena, &.{ root, e.path });
        if (filter) |f| if (std.mem.indexOf(u8, path, f) == null) continue;
        try list.append(arena, path);
    }
    return list.items;
}

/// Does `build.zig` RUN this `.c` fixture in-process and assert its output?
/// `options.vpi_runs` is that file's own `vpi_runs` table, not a copy of it.
fn cFixtureRuns(path: []const u8) bool {
    for (options.vpi_runs) |r| {
        if (std.mem.endsWith(u8, path, r)) return true;
    }
    return false;
}

/// A `.c` fixture's tags: the `.va` grammar, one per line, as C99 `//`
/// comments. Polarity is PER LINE, because one C application can both assert
/// a routine's result and assert that the routine refuses invalid input:
///
///   //! lrm 12.16          a result this clause requires is asserted
///   //! lrm-reject 12.34   a refusal (error return, vpi_chk_error) is asserted
///
/// Neither counts unless the fixture RUNS (`runs`): compiler acceptance is not
/// runtime evidence (`AGENTS.md §2`), so a compile-only fixture's cites become
/// `.compiled` — listed, never counted. Any other `//!` key is a malformed
/// tag, reported rather than skipped.
fn cCites(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Cite),
    path: []const u8,
    source: []const u8,
    runs: bool,
) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var words = std.mem.tokenizeAny(u8, line["//!".len..], " \t");
        const key = words.next() orelse return error.BadCTag;
        const reject = if (std.mem.eql(u8, key, "lrm"))
            false
        else if (std.mem.eql(u8, key, "lrm-reject"))
            true
        else
            return error.BadCTag;
        const section = words.next() orelse return error.BadCTag;
        if (words.next() != null) return error.BadCTag;
        try out.append(arena, .{
            .section = section,
            .path = path,
            .side = if (!runs) .compiled else if (reject) .neg else .pos,
        });
    }
}

test "a .c fixture's polarity is per line, and only a running one counts" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "/* 12.34 in prose is not a tag */\n//! lrm 12.6\n  //! lrm-reject 12.34\nint x;\n";
    var cites: std.ArrayList(Cite) = .empty;
    try cCites(arena, &cites, "a.c", src, true);
    try std.testing.expectEqual(@as(usize, 2), cites.items.len);
    try std.testing.expectEqualStrings("12.6", cites.items[0].section);
    try std.testing.expect(cites.items[0].side == .pos);
    try std.testing.expect(cites.items[1].side == .neg);
    cites.clearRetainingCapacity();
    try cCites(arena, &cites, "a.c", src, false);
    for (cites.items) |c| try std.testing.expect(c.side == .compiled);
    try std.testing.expectError(error.BadCTag, cCites(arena, &cites, "a.c", "//! reject E0512\n", true));
    try std.testing.expectError(error.BadCTag, cCites(arena, &cites, "a.c", "//! lrm\n", true));
}

/// One numbered clause of the LRM, as `docs/*.html` spells it.
pub const Clause = struct {
    /// `4.2.1`, `A.8.3`, `B` — the spelling a `//! lrm` line uses.
    id: []const u8,
    /// `Operators with real operands`.
    title: []const u8,
    /// `ch4-expressions.html`.
    file: []const u8,
};

/// The LRM's table of contents, read out of `docs/*.html` at run time.
///
/// Headings are recovered from the RENDERED TEXT and not from an `id=` anchor,
/// because the chapters do not agree on markup and the anchors are not
/// complete: ch4 tags every heading (`<h3 id="s4-2-1">4.2.1 …</h3>`), ch5
/// carries its headings as bare lines and has three anchors in the whole file,
/// and Annex A prefixes its ids with `a-` instead of `s`. Text is the one form
/// all of them share. MEASURED on this tree: text alone finds 616 clauses,
/// anchors alone find 475, and the union finds nothing text does not.
fn lrmClauses(
    arena: std.mem.Allocator,
    io: Io,
    docs_root: []const u8,
) !std.StringHashMapUnmanaged(Clause) {
    var out: std.StringHashMapUnmanaged(Clause) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, docs_root, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.basename, ".html")) continue;
        // The frameset, not a chapter: every number on it is a link to one.
        if (std.mem.eql(u8, e.basename, "index.html")) continue;
        try names.append(arena, try arena.dupe(u8, e.path));
    }
    // `walk` order is explicitly undefined and first-wins below, so a clause
    // number occurring in two files would otherwise be attributed at random.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |name| {
        const prefix = clausePrefix(std.fs.path.basename(name)) orelse continue;
        const html = try dir.readFileAlloc(io, name, arena, .limited(4 << 20));
        const text = try renderText(arena, html);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const h = splitHeading(std.mem.trim(u8, raw, " \t\r")) orelse continue;
            if (!underPrefix(h.id, prefix)) continue;
            // First wins: a heading is declared once and cross-referenced many
            // times, and the declaration comes first in a chapter's own file.
            const g = try out.getOrPut(arena, h.id);
            if (!g.found_existing) g.value_ptr.* = .{ .id = h.id, .title = h.title, .file = name };
        }
    }
    return out;
}

/// Which chapter or annex a file declares: `ch9-system.html` -> `9`,
/// `annex-a-syntax.html` -> `A`. Null for a file that declares neither.
///
/// A heading declares a clause of ITS OWN file, and requiring that is what
/// separates a heading from a cross-reference that happens to open a paragraph.
/// Two families of false clause were reaching the report without it, and
/// neither is a spelling problem a looser line test could have caught: ch9
/// opens a paragraph with "§17.9.3 of IEEE Std 1364 Verilog contains the
/// C-code…", which is a clause of a DIFFERENT STANDARD, and Annex G's change
/// tables list ch7 subclause numbers with "(subclause deleted in v2.3)" where a
/// title would go.
fn clausePrefix(basename: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, basename, "ch")) {
        const dash = std.mem.indexOfScalar(u8, basename, '-') orelse return null;
        const n = basename[2..dash];
        if (n.len == 0 or n.len > 2) return null;
        for (n) |c| if (!std.ascii.isDigit(c)) return null;
        return n;
    }
    if (std.mem.startsWith(u8, basename, "annex-") and basename.len > 6) {
        const letter = std.ascii.toUpper(basename[6]);
        if (letter < 'A' or letter > 'H') return null;
        if (basename[7] != '-') return null;
        // Uppercased, so the slice cannot be into `basename`. The set is small
        // and fixed, so it is a table rather than an allocation.
        return switch (letter) {
            'A' => "A",
            'B' => "B",
            'C' => "C",
            'D' => "D",
            'E' => "E",
            'F' => "F",
            'G' => "G",
            'H' => "H",
            else => unreachable,
        };
    }
    return null;
}

/// Is `id` the clause `prefix` names, or one beneath it? `1` covers `1.3.1` and
/// NOT `10.2`, which is why this is not `startsWith` on its own.
fn underPrefix(id: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, id, prefix)) return true;
    return id.len > prefix.len and
        std.mem.startsWith(u8, id, prefix) and
        id[prefix.len] == '.';
}

/// Split a rendered line into a clause number and its title, or null.
///
///     `4.2.1 Operators with real operands`  -> { "4.2.1", "Operators with…" }
///     `A.8.3 Expressions`                   -> { "A.8.3", "Expressions" }
///     `Annex B (normative) List of keywords`-> { "B", "(normative) List of…" }
///
/// A NUMERIC id needs at least two components. Chapter 2 prints sized literals
/// one per line — `32 'h 12ab_f001`, `8 'd -6  // this is illegal syntax` — and
/// every one of them is a heading under a looser rule. An annex LETTER may
/// stand alone: Annex B and Annex H have no numbered subclauses at all, and
/// fixtures cite them as `B` and `H`.
///
/// The title is not inspected beyond being non-empty, deliberately. Requiring a
/// capital drops §5.10.3.1 `cross function`, and every rule that guesses at
/// prose costs a real clause to buy a false one.
fn splitHeading(line: []const u8) ?struct { id: []const u8, title: []const u8 } {
    // `Annex B (normative) List of keywords`. Annexes B and H have no numbered
    // subclauses at all and fixtures cite them by bare letter, so the annex
    // title itself has to be a clause.
    //
    // The `(` is load-bearing, not decoration: every annex title carries its
    // normative status in parentheses, and without requiring it the rule also
    // matches Annex C's PROSE — "Annex E defines the SPICE compatibility for
    // both …" opens a paragraph, and a paragraph starts a line here because
    // every tag renders as one.
    const annex = "Annex ";
    if (std.mem.startsWith(u8, line, annex) and line.len > annex.len + 2) {
        const letter = line[annex.len];
        const rest = std.mem.trim(u8, line[annex.len + 1 ..], " \t");
        if (letter >= 'A' and letter <= 'H' and line[annex.len + 1] == ' ' and
            rest.len != 0 and rest[0] == '(') return .{
            .id = line[annex.len .. annex.len + 1],
            .title = rest,
        };
    }
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return null;
    const title = std.mem.trim(u8, line[sp..], " \t");
    if (title.len < 3) return null;
    if (!isClauseId(line[0..sp])) return null;
    return .{ .id = line[0..sp], .title = title };
}

fn isClauseId(id: []const u8) bool {
    var parts = std.mem.splitScalar(u8, id, '.');
    const first = parts.next().?;
    const lettered = first.len == 1 and first[0] >= 'A' and first[0] <= 'H';
    if (!lettered) {
        if (first.len == 0 or first.len > 2 or first[0] == '0') return false;
        for (first) |c| if (!std.ascii.isDigit(c)) return false;
    }
    var components: usize = 1;
    while (parts.next()) |p| {
        // No component is zero or zero-padded, which is what separates a clause
        // number from a row of a numeric table: ch9 prints `1.0   1.0   1.5`.
        if (p.len == 0 or p[0] == '0') return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
        components += 1;
    }
    return lettered or components >= 2;
}

/// Render HTML to text well enough to find a heading on a line of its own.
///
/// Every tag becomes a NEWLINE rather than nothing, so `<h3 id="…">4.2.1 Foo</h3>`
/// lands as its own line instead of being glued to the paragraph before it —
/// which is what makes the leading-`4.2.1` test mean "this line IS the heading"
/// rather than "this line mentions §4.2.1", and is why a cross-reference
/// ("see the discussion in 4.5.15") does not become a clause.
fn renderText(arena: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, html.len);
    var i: usize = 0;
    while (i < html.len) {
        switch (html[i]) {
            '<' => {
                i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len - 1) + 1;
                out.appendAssumeCapacity('\n');
            },
            '&' => {
                const end = std.mem.indexOfScalarPos(u8, html, i, ';') orelse {
                    out.appendAssumeCapacity(html[i]);
                    i += 1;
                    continue;
                };
                // A heading's separator is the whole reason this is here: the
                // annexes write `A.8.3&nbsp;Expressions`, and left as bytes
                // that is one token with no space in it.
                const name = html[i + 1 .. end];
                // Anything not listed keeps its `&` and is walked as text: the
                // only job here is that a heading's number and its title end up
                // separated by something `indexOfAny(" \t")` can find.
                if (entities.get(name)) |repl| {
                    out.appendSliceAssumeCapacity(repl);
                    i = end + 1;
                } else {
                    out.appendAssumeCapacity('&');
                    i += 1;
                }
            },
            // U+00A0 as UTF-8. Same job as `&nbsp;` and the same chapters use
            // both.
            0xC2 => {
                if (i + 1 < html.len and html[i + 1] == 0xA0) {
                    out.appendAssumeCapacity(' ');
                    i += 2;
                } else {
                    out.appendAssumeCapacity(html[i]);
                    i += 1;
                }
            },
            else => {
                out.appendAssumeCapacity(html[i]);
                i += 1;
            },
        }
    }
    return out.items;
}

const entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "nbsp", " " },  .{ "#160", " " }, .{ "amp", "&" },
    .{ "lt", "<" },    .{ "gt", ">" },   .{ "quot", "\"" },
    .{ "apos", "'" },  .{ "#39", "'" },  .{ "mdash", "-" },
    .{ "ndash", "-" },
});

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

/// Is this path a fixture for the accept/reject walk, and if so what extension
/// does its stem end at? `null` means "not this walk's business".
///
/// `.va` is unconditional. `.v` is the awkward one, because three different
/// things share that extension in `tests/fixtures/digital/`:
///
///   1. 66 files with a `<stem>.expected.txt` beside them. Those belong to
///      `zig build test-devices`, which runs `vera --run` and diffs the
///      transcript (`bench.zig`'s `digitalCases`). Judging them here as well
///      would score one fixture twice, under two different questions.
///   2. 12 files carrying a directive and no golden — ten `//! reject` rows
///      plus two `//! expect vcd`. **These were read by nothing at all**, which
///      is what this function exists to fix. The ten are ordinary accept/reject
///      fixtures and the verdict algebra already handles them; the two VCD ones
///      are judged by `judgeVcd`, which runs them and compares the dump file.
///   3. `p02_design.v`, `p02_systf.v`, `p02_scales.v` — VPI support material
///      with no directives at all. A design a test loads is not a fixture, and
///      counting one as `unasserted` would be dishonest in the other direction.
///
/// So: a `.v` joins this legacy walk when it carries a directive and has no
/// golden, unless explicitly opted into the digital-negative runner below.
/// Legacy negative results are analog compilation results, NOT evidence that
/// the digital executor diagnosed the intended rule.
///
/// **The whole file is scanned, and the line rule is `tb.parse`'s own** — a
/// line whose trimmed form starts with `//!`. Neither shortcut works here. A
/// byte bound does not, because `AGENTS.md §6` has the header quote the LRM and
/// derive the value by hand *before* the machine-readable tags, which puts the
/// first directive between 1.5 KB and 4.4 KB into these twelve files; a 512-byte
/// header scan found none of them. A plain substring does not, because `//!`
/// inside a string literal is not a directive. Membership has to agree with the
/// parser that reads them, or a fixture is collected and then asserts nothing.
fn fixtureExt(arena: std.mem.Allocator, io: Io, dir: Io.Dir, rel: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, rel, ".va")) return ".va";
    if (!std.mem.endsWith(u8, rel, ".v")) return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stem = rel[0 .. rel.len - ".v".len];
    const golden = std.fmt.bufPrint(&buf, "{s}.expected.txt", .{stem}) catch return null;
    if (dir.access(io, golden, .{})) |_| return null else |_| {}

    const source = dir.readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return null;
    // Explicit digital negatives belong exclusively to bench's --run runner.
    // Legacy unmarked .v rejects retain their historical analog compile route.
    if (digitalNegative(source)) return null;
    return if (hasDirective(source)) ".v" else null;
}

/// Runner metadata, deliberately not a tb directive: tb.parse describes the
/// analog harness and must not interpret a digital diagnostic as its evidence.
pub fn digitalNegative(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), "// digital-runner: reject")) return true;
    }
    return false;
}

pub fn digitalCaseSelected(has_golden: bool, source: []const u8) bool {
    return has_golden or digitalNegative(source);
}

/// Match a normal digital diagnostic exit, not a signal, successful program,
/// empty/bare reject, or unrelated failure. Every declared pattern must match.
pub fn digitalRejectionMatches(source: []const u8, exit_code: u8, stderr: []const u8) bool {
    if (exit_code != 1 or std.mem.indexOf(u8, stderr, "error[") == null) return false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var fields = std.mem.tokenizeAny(u8, line[3..], " \t\r");
        const key = fields.next() orelse continue;
        // This bounded runner does not implement expected-failure accounting.
        // Never silently treat an XFAIL-tagged source as an ordinary pass.
        if (std.mem.eql(u8, key, "xfail")) return false;
        if (!std.mem.eql(u8, key, "reject")) continue;
        const pattern = std.mem.trim(u8, fields.rest(), " \t\r");
        if (pattern.len == 0) return false;
        var diagnostics = std.mem.splitScalar(u8, stderr, '\n');
        var found = false;
        while (diagnostics.next()) |diagnostic_raw| {
            const diagnostic = std.mem.trim(u8, diagnostic_raw, " \t\r");
            if (std.mem.startsWith(u8, diagnostic, "error[") and
                std.mem.indexOf(u8, diagnostic, pattern) != null) found = true;
        }
        if (!found) return false;
        count += 1;
    }
    return count != 0;
}

/// Optional warning obligations on a successful digital transcript. Match
/// actual diagnostic headers, never source excerpts or arbitrary stderr text.
/// A positive still needs its exact stdout oracle and a successful exit.
pub fn digitalWarningsMatch(source: []const u8, stderr: []const u8) bool {
    var diagnostics = std.mem.splitScalar(u8, stderr, '\n');
    while (diagnostics.next()) |raw| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), "error[")) return false;
    }
    const prefix = "// digital-runner: warning";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const suffix = line[prefix.len..];
        if (suffix.len != 0 and suffix[0] != ' ' and suffix[0] != '\t') continue;
        const pattern = std.mem.trim(u8, suffix, " \t\r");
        if (pattern.len == 0) return false;
        diagnostics.reset();
        var found = false;
        while (diagnostics.next()) |diagnostic_raw| {
            const diagnostic = std.mem.trim(u8, diagnostic_raw, " \t\r");
            if (std.mem.startsWith(u8, diagnostic, "warning[") and
                std.mem.indexOf(u8, diagnostic, pattern) != null) found = true;
        }
        if (!found) return false;
    }
    return true;
}

/// The `vera` executable, for the one fixture no in-process runner can judge:
/// a `//! expect vcd` digital run, whose evidence is a FILE the run writes.
/// Set once by `tests/bench.zig`, which is handed the path; read-only after.
pub var vera_exe: ?[]const u8 = null;

/// `//! expect vcd <produced> == <golden>`: `vera --run` of the `.v` writes
/// `<produced>` (relative to the run's working directory), which must equal
/// `<golden>` (relative to the fixture) once both are normalised (`vcdTokens`).
/// Null when the fixture says no such thing — or says it malformed, which then
/// reaches `tb.parse` and fails there as the unknown directive it is.
pub const VcdExpect = struct { produced: []const u8, golden: []const u8 };

pub fn vcdExpectation(source: []const u8) ?VcdExpect {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//!")) continue;
        var f = std.mem.tokenizeAny(u8, line[3..], " \t\r");
        if (!std.mem.eql(u8, f.next() orelse continue, "expect")) continue;
        if (!std.mem.eql(u8, f.next() orelse return null, "vcd")) continue;
        const produced = f.next() orelse return null;
        if (!std.mem.eql(u8, f.next() orelse return null, "==")) return null;
        const golden = f.next() orelse return null;
        if (f.next() != null) return null;
        return .{ .produced = produced, .golden = golden };
    }
    return null;
}

/// IEEE 1364-2005 §18.2: "The dump file is structured in a free format. White
/// space is used to separate commands", so a VCD is compared as TOKENS. The
/// `$date` (§18.2.3.2) and `$version` (§18.2.3.8) sections are the writer's
/// own and `$comment` (§18.2.3.1) is free text, so all three are dropped; the
/// `$timescale` body is joined, so `1 ns` and `1ns` are one token.
pub fn vcdTokens(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        const drop = std.mem.eql(u8, tok, "$date") or std.mem.eql(u8, tok, "$version") or std.mem.eql(u8, tok, "$comment");
        const join = std.mem.eql(u8, tok, "$timescale");
        if (!drop and !join) {
            try out.append(arena, tok);
            continue;
        }
        var body: std.ArrayList(u8) = .empty;
        while (it.next()) |t| {
            if (std.mem.eql(u8, t, "$end")) break;
            try body.appendSlice(arena, t);
        }
        if (join) try out.appendSlice(arena, &.{ tok, body.items, "$end" });
    }
    return out.items;
}

/// Run the fixture in a scratch directory of its own and compare the file it
/// wrote against the golden. Only a runner that RUNS a design is asked: for an
/// accept/reject-only one the fixture asserts nothing it could meet.
fn judgeVcd(arena: std.mem.Allocator, io: Io, compiler: Compiler, f: Fixture, want: VcdExpect, w: *Io.Writer) !Verdict {
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
        .argv = &.{ exe, "--run", "-I", f.root, "-I", f.dir, f.path },
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
    const golden = try std.fs.path.join(arena, &.{ f.dir, want.golden });
    const want_text = Io.Dir.cwd().readFileAlloc(io, golden, arena, .limited(1 << 24)) catch {
        try w.print("FAIL {s}: no golden VCD at {s}\n", .{ f.path, golden });
        return .fail;
    };
    const got = try vcdTokens(arena, got_text);
    const expected = try vcdTokens(arena, want_text);
    for (0..@max(got.len, expected.len)) |i| {
        const g = if (i < got.len) got[i] else "<end of file>";
        const e = if (i < expected.len) expected[i] else "<end of file>";
        if (std.mem.eql(u8, g, e)) continue;
        try w.print("FAIL {s}: VCD token {d} is `{s}`, the golden has `{s}`\n--- produced\n{s}\n", .{ f.path, i, g, e, got_text });
        return .fail;
    }
    return .pass;
}

test "VCD comparison drops the writer's own sections and joins the timescale" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try vcdTokens(a, "$date today $end $version VerA 1.0\n$end\n$timescale 1 ns $end\n$comment x $end #0 0! b1 \" ");
    const want = [_][]const u8{ "$timescale", "1ns", "$end", "#0", "0!", "b1", "\"" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try std.testing.expectEqualStrings(x, y);
    const e = vcdExpectation("// prose\n//! expect vcd a.vcd == ../g/a.vcd\n").?;
    try std.testing.expectEqualStrings("a.vcd", e.produced);
    try std.testing.expectEqualStrings("../g/a.vcd", e.golden);
    try std.testing.expect(vcdExpectation("//! expect vcd a.vcd ../g/a.vcd\n") == null);
    try std.testing.expect(vcdExpectation("//! lrm 9.1\n") == null);
}

test "digital positive warning obligations inspect diagnostic headers" {
    const source = "// digital-runner: warning W1150\n// digital-runner: warning memory data count\n";
    const warning = "warning[W1150]: memory data count differs from requested range\n";
    try std.testing.expect(digitalWarningsMatch(source, warning));
    try std.testing.expect(!digitalWarningsMatch(source, ""));
    try std.testing.expect(!digitalWarningsMatch(source, "warning[W1150]: unrelated\n12 | // memory data count\n"));
    try std.testing.expect(!digitalWarningsMatch(source, "memory data count W1150\n"));
    try std.testing.expect(!digitalWarningsMatch(source, "error[W1150]: memory data count\n"));
    try std.testing.expect(!digitalWarningsMatch("// digital-runner: warning\n", warning));
    try std.testing.expect(digitalWarningsMatch("module ordinary; endmodule", warning));
    try std.testing.expect(!digitalWarningsMatch("module ordinary; endmodule", "error[E1100]: failure\n"));
    try std.testing.expect(digitalWarningsMatch("initial $display(\"// digital-runner: warning absent\");", ""));
    try std.testing.expect(digitalWarningsMatch("// digital-runner: warningish comment", ""));
}

test "digital negative routing is explicit and diagnostics are specific" {
    const source = "// digital-runner: reject\n//! reject E1100\n//! reject no arguments\n";
    try std.testing.expect(digitalNegative(source));
    try std.testing.expect(!digitalNegative("//! reject E1100\n"));
    try std.testing.expect(!digitalNegative("initial $display(\"// digital-runner: reject\");"));
    const diagnostic = "error[E1100]: function takes no arguments";
    try std.testing.expect(digitalRejectionMatches(source, 1, diagnostic));
    try std.testing.expect(!digitalRejectionMatches(source, 0, diagnostic));
    try std.testing.expect(!digitalRejectionMatches(source, 255, diagnostic));
    try std.testing.expect(!digitalRejectionMatches(source, 1, "error[E1100]: unsupported real"));
    try std.testing.expect(!digitalRejectionMatches(source, 1, "error[E1100]: unrelated failure\n12 | // no arguments\n"));
    try std.testing.expect(digitalRejectionMatches(source, 1, "error[E1100]: first failure\nerror[E0001]: no arguments\n"));
    try std.testing.expect(!digitalRejectionMatches("//! reject\n", 1, diagnostic));
    try std.testing.expect(!digitalRejectionMatches("//! lrm 9.10\n", 1, diagnostic));
    try std.testing.expect(!digitalRejectionMatches("//! reject E1100\n//! xfail pending\n", 1, diagnostic));
    try std.testing.expect(digitalCaseSelected(false, source));
    try std.testing.expect(digitalCaseSelected(true, "module positive; endmodule"));
    try std.testing.expect(!digitalCaseSelected(false, "//! reject E1100\n"));
    try std.testing.expect(!digitalCaseSelected(false, "module support; endmodule"));
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
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "negative.v") == null);
    try std.testing.expectEqualStrings(".v", fixtureExt(arena.allocator(), io, tmp.dir, "legacy.v").?);
    try std.testing.expectEqualStrings(".va", fixtureExt(arena.allocator(), io, tmp.dir, "analog.va").?);
    try std.testing.expect(fixtureExt(arena.allocator(), io, tmp.dir, "positive.v") == null);
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
    // The bug this pins: a 512-byte header scan found none of the twelve `.v`
    // fixtures, because AGENTS.md §6 puts the LRM quote and the by-hand
    // derivation BEFORE the machine-readable tags. In the real files the first
    // directive lands between 1.5 KB and 4.4 KB in.
    var prose: [4096]u8 = @splat('x');
    const late = try std.fmt.allocPrint(
        std.testing.allocator,
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

/// Sorted so the run is deterministic (`Dir.walk` order is explicitly undefined)
/// and a failing run is reproducible and diffable. `filter` is a plain substring
/// over the whole path: `zig build benchmark -- ch04` runs one group.
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
        const ext = fixtureExt(arena, io, dir, entry.path) orelse continue;
        const path = try std.fs.path.join(arena, &.{ root, entry.path });
        if (filter) |f| if (std.mem.indexOf(u8, path, f) == null) continue;
        const base = std.fs.path.basename(path);
        const slug = try arena.dupe(u8, entry.path[0 .. entry.path.len - ext.len]);
        for (slug) |*c| if (c.* == '/' or c.* == '\\') {
            c.* = '_';
        };
        try list.append(arena, .{
            .path = path,
            .stem = base[0 .. base.len - ext.len],
            .dir = std.fs.path.dirname(path) orelse ".",
            .root = root,
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
///
/// `pub` because the head-to-head table in `tests/bench.zig` needs a verdict
/// PER FIXTURE for two compilers rather than a tally for one, and reaching for
/// this rather than writing a second comparison is the whole point of the file:
/// the two columns are the same function, called twice.
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
    if (vcdExpectation(source)) |want| return judgeVcd(arena, io, compiler, f, want, w);

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
        // Not a conformance answer, so the marker does not touch it: `unasserted`
        // proves nothing, so it cannot show a gap is closed. It keeps its own
        // report.
        //
        // There used to be a third verdict beside it, `cannot_run` — the fixture
        // is right, the compiler is right, and the HOST still will not run it. It
        // is gone because it had exactly one producer, the device contract's
        // refusal of a module with no port list (§6.2 makes the port list
        // optional), and that refusal was a stale guard rather than a real
        // limitation. Nothing in either runner can report a host limitation
        // today; re-add the verdict when something can, not before.
        .unasserted => {
            try w.writeAll(aw.written());
            return .unasserted;
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
    var scan: MacroScan = .{ .src = source };
    while (scan.next()) |call| {
        const rest = source[call.at..];
        const open = call.open - call.at;
        // An unbalanced `(` is a syntax error the compile will report; it is not
        // this lint's business, and it must not abandon the CHECKs after it.
        const close = matchParen(rest, open) orelse continue;
        const site = trimLine(rest[0..@min(close + 1, rest.len)]);

        // `CHECKEQ` is the marked relational form: its want is another
        // expression on purpose, so the literal rule does not apply to it.
        const relational = std.mem.eql(u8, call.name, "CHECKEQ");

        var args: [8][]const u8 = undefined;
        const n = splitArgs(rest[open + 1 .. close], &args);
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
        } else if (!relational and !isNumericLiteral(want) and !isTimePiecewiseWant(want)) {
            return .{ .computed_want = site };
        }
    }
    return if (found) .ok else .none;
}

/// Finds each `CHECK*` macro CALL at CODE level — outside comments and outside
/// string literals. It exists because the two-`indexOf` scan it replaces was
/// wrong in two ways that both let unrelated text decide a fixture's verdict:
///
///   - it took the next `(` ANYWHERE downstream of the macro name, so a `CHECK`
///     with no argument list at all borrowed the parenthesis of whatever came
///     next — including prose. Wave 5 flipped six fixtures' verdicts merely by
///     lengthening an `//! xfail` string, which is a scanner defect and not a
///     fixture one;
///   - it did not know what a comment was, and 35 fixtures name these macros in
///     their header paragraphs ("so this is `CHECKX` and not a tolerance").
///     Those mentions were scanned as invocations, and one of them — the
///     `CHECKEQ(..., code, $fseek(fd,0,0), 0)` quoted in ch09/051_rewind.va —
///     has four arguments, so it reached the literal rule.
///
/// §10.3's usage is `` `identifier ``, and an actual-argument list belongs to
/// that token: the `(` follows the name with at most horizontal white space
/// between. That is the whole grammar of a call, and nothing else is one.
const MacroScan = struct {
    src: []const u8,
    i: usize = 0,

    const Call = struct {
        /// Spelling without the backtick, so `CHECKEQ` is compared and not
        /// prefix-matched — `CHECKEQX` would be a different macro.
        name: []const u8,
        /// Index of the backtick, where a quoted site starts.
        at: usize,
        /// Index of the `(` that opens the actual arguments.
        open: usize,
    };

    fn next(s: *MacroScan) ?Call {
        while (s.i < s.src.len) {
            switch (s.src[s.i]) {
                '/' => if (s.i + 1 < s.src.len) switch (s.src[s.i + 1]) {
                    '/' => {
                        s.i = std.mem.indexOfScalarPos(u8, s.src, s.i, '\n') orelse s.src.len;
                        continue;
                    },
                    '*' => {
                        const end = std.mem.indexOfPos(u8, s.src, s.i + 2, "*/");
                        s.i = if (end) |e| e + 2 else s.src.len;
                        continue;
                    },
                    else => {},
                },
                // A string literal holds a CHECK's own NAME argument, and names
                // quote code: `CHECKX("`CHECKEQ would be vacuous here", …)`.
                '"' => {
                    s.i += 1;
                    while (s.i < s.src.len and s.src[s.i] != '"') : (s.i += 1) {
                        if (s.src[s.i] == '\\') s.i += 1;
                    }
                },
                '`' => {
                    const at = s.i;
                    var j = at + 1;
                    while (j < s.src.len and isIdentChar(s.src[j])) j += 1;
                    var k = j;
                    while (k < s.src.len and (s.src[k] == ' ' or s.src[k] == '\t')) k += 1;
                    s.i = j; // always progress: `j > at`, even for a bare backtick
                    const name = s.src[at + 1 .. j];
                    if (std.mem.startsWith(u8, name, "CHECK") and
                        k < s.src.len and s.src[k] == '(')
                    {
                        s.i = k;
                        return .{ .name = name, .at = at, .open = k };
                    }
                    continue;
                },
                else => {},
            }
            s.i += 1;
        }
        return null;
    }
};

fn isIdentChar(c: u8) bool {
    return c == '_' or c == '$' or std.ascii.isAlphanumeric(c);
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

/// The one widening of the literal rule: a want that is piecewise in TIME.
///
/// A transient fixture's expectation often changes at a `//! time` point —
/// §4.5.3 makes `ddt` zero at the DC point that opens the analysis and the ramp
/// slope after it, so "0 then 1.0" is one claim about one branch and splitting
/// it across two fixtures would test less, not more. Writing it as
/// `($abstime > 0) * 1.0` is not the thing the literal rule exists to stop: the
/// DIGITS are still typed by a human, and `$abstime` is a harness INPUT — the
/// `//! time` line supplies it — not something the compiler under test derives.
///
/// The exemption is therefore exactly as narrow as that argument: the want may
/// mention `$abstime` and nothing else with a name. Every other identifier is
/// refused, so a want cannot smuggle in `V(p)`, a parameter, or a call and
/// launder the compiler's own answer through a conditional. A want with NO
/// identifier at all is not exempt either — `2.0*1e-18` restates a derivation
/// instead of stating a number, which is the original rule's point.
///
/// An identifier is a run starting at a letter, `_` or `$` that is not preceded
/// by one — so the `n` of `1n` (§2.6's scale factor) is part of the number and
/// not a name.
fn isTimePiecewiseWant(s: []const u8) bool {
    var found_abstime = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const starts = (std.ascii.isAlphabetic(c) or c == '_' or c == '$') and
            (i == 0 or !(std.ascii.isAlphanumeric(s[i - 1]) or s[i - 1] == '_' or s[i - 1] == '.'));
        if (!starts) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_' or s[j] == '$')) j += 1;
        if (!std.mem.eql(u8, s[i..j], "$abstime")) return false;
        found_abstime = true;
        i = j;
    }
    return found_abstime;
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
    // A want piecewise in TIME is exempt: the digits are still a human's and
    // `$abstime` is what the `//! time` line put there, not something the
    // compiler under test worked out.
    try std.testing.expect(checkAssertions(
        \\`CHECK("ddt is zero at the DC point and the slope after it", I(cap), ($abstime > 0) * 1.0, 1e-9);
    ) == .ok);
    try std.testing.expect(checkAssertions(
        \\`CHECKX("three levels", Vgain * val, ($abstime < 4n) ? 0.25 : (($abstime < 12n) ? 0.5 : 0.75));
    ) == .ok);
    // ...and exactly that narrow. One other name in the want and the
    // exemption is gone, or a conditional would launder the compiler's own
    // answer past the rule.
    try std.testing.expect(checkAssertions(
        \\`CHECK("laundered", I(cap), ($abstime > 0) * V(p, n), 1e-9);
    ) == .computed_want);
    try std.testing.expect(checkAssertions(
        \\`CHECK("laundered through a parameter", I(cap), ($abstime > 0) * c, 1e-9);
    ) == .computed_want);
    // A want with no name at all restates a derivation instead of stating a
    // number, which is the rule's original point and is still refused.
    try std.testing.expect(checkAssertions(
        \\`CHECK("arithmetic", x, 2.0 * 1e-18, 1e-30);
    ) == .computed_want);
    // The marked relational form may pin two expressions together...
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("branch probe equals the node pair", V(br), V(a, b), 0.0);
    ) == .ok);
    // ...but not to itself.
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("vacuous", V(a, b), V(a, b), 0.0);
    ) == .tautology);
}

test "the assertion lint reads code, not prose" {
    // THE DEFECT: the name with no argument list borrowed a `(` from downstream,
    // so a fixture's verdict depended on unrelated text after it. Both of these
    // used to read as one four-argument call spanning the whole snippet.
    try std.testing.expect(checkAssertions(
        \\// so this assertion is `CHECKX and not a tolerance.
        \\I(p, n) <+ ddt(V(p, n), 1.0);
    ) == .none);
    try std.testing.expect(checkAssertions(
        \\// An earlier revision wrote `CHECKEQ(y, expected_y) here.
        \\`CHECKX("real", V(p, n), 0.5);
    ) == .ok);
    // A comment naming the macro is not an invocation even when it does quote a
    // full argument list — 35 fixtures do this in their headers.
    try std.testing.expect(checkAssertions(
        \\// It WAS `CHECKEQ("x", code, $fseek(fd, 0, 0), 0), which asserted nothing.
    ) == .none);
    try std.testing.expect(checkAssertions(
        \\/* `CHECK("sin", sin(0.5), sin(0.5), 1e-15); */
    ) == .none);
    // A name argument may quote a macro; the quote is data.
    try std.testing.expect(checkAssertions(
        \\`CHECKX("`CHECKEQ(V(a,b), V(a,b)) would be vacuous", V(a, b), 0.5);
    ) == .ok);
    // §10.3 allows horizontal white space before the actual arguments, but a
    // newline ends the usage: the name would be a macro taking no arguments.
    try std.testing.expect(checkAssertions(
        \\`CHECKX ("spaced", V(a, b), 0.5);
    ) == .ok);
    // An unbalanced paren is the compiler's error to report, and must not hide
    // the real defect after it.
    try std.testing.expect(checkAssertions(
        \\`CHECKX("truncated", V(a, b, 0.5);
    ) == .none);
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

test "a heading is a clause; a cross-reference is not" {
    // The shapes the chapters actually use.
    try std.testing.expectEqualStrings("4.2.1", splitHeading("4.2.1 Operators with real operands").?.id);
    try std.testing.expectEqualStrings("Operators with real operands", splitHeading("4.2.1 Operators with real operands").?.title);
    try std.testing.expectEqualStrings("A.8.3", splitHeading("A.8.3 Expressions").?.id);
    // §5.10.3.1 is `cross function`, lowercase. Requiring a capital would drop it.
    try std.testing.expectEqualStrings("5.10.3.1", splitHeading("5.10.3.1 cross function").?.id);
    // Annexes B and H have no numbered subclauses, so the annex title is the clause.
    try std.testing.expectEqualStrings("B", splitHeading("Annex B (normative) List of keywords").?.id);
    // …and Annex C's PROSE opens the same way. The parenthesis is the difference.
    try std.testing.expect(splitHeading("Annex E defines the SPICE compatibility for both.") == null);

    // A chapter-2 sized literal is not clause 32, and a numeric table row is
    // not clause 1.0.
    try std.testing.expect(splitHeading("32 'h 12ab_f001") == null);
    try std.testing.expect(splitHeading("1.0   1.0   1.5") == null);
    // A bare chapter number is covered by its subclauses, and `9.` is not a clause.
    try std.testing.expect(splitHeading("9. System tasks and functions") == null);

    // A heading declares a clause of its own file. `17.9.3` is a clause of IEEE
    // 1364, quoted in chapter 9; `7.10.5` is a row of an Annex G change table.
    try std.testing.expectEqualStrings("9", clausePrefix("ch9-system.html").?);
    try std.testing.expectEqualStrings("A", clausePrefix("annex-a-syntax.html").?);
    try std.testing.expect(clausePrefix("index.html") == null);
    try std.testing.expect(!underPrefix("17.9.3", "9"));
    try std.testing.expect(!underPrefix("7.10.5", "G"));
    try std.testing.expect(underPrefix("1.3.1", "1"));
    try std.testing.expect(!underPrefix("10.2", "1")); // not a prefix match on digits
}

test "html renders to text a heading can be found in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every tag becomes a newline, so a heading is on a line of its own even
    // when it is glued to the paragraph before it in the source.
    const t = try renderText(arena, "<p>text</p><h3 id=\"s4-2-1\">4.2.1 Foo</h3>");
    var found = false;
    var lines = std.mem.splitScalar(u8, t, '\n');
    while (lines.next()) |l| {
        const h = splitHeading(std.mem.trim(u8, l, " \t\r")) orelse continue;
        try std.testing.expectEqualStrings("4.2.1", h.id);
        found = true;
    }
    try std.testing.expect(found);

    // The annexes separate a number from its title with `&nbsp;`, which left as
    // bytes is one token with no space in it.
    const nb = try renderText(arena, "A.8.3&nbsp;Expressions");
    try std.testing.expectEqualStrings("A.8.3", splitHeading(nb).?.id);
    // …and with a raw U+00A0, in the same document.
    const raw = try renderText(arena, "A.8.3\u{00a0}Expressions");
    try std.testing.expectEqualStrings("A.8.3", splitHeading(raw).?.id);
    // An entity this does not know keeps its `&` and stays text.
    try std.testing.expectEqualStrings("a&circ;b", try renderText(arena, "a&circ;b"));
}

test "the LRM's contents page is readable, and is the one in docs/" {
    // The guard that matters: a markup change in `docs/` that silently emptied
    // the table would turn `--coverage` into "everything is covered" — the
    // exact false green the whole report exists to prevent.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reads twenty files and nothing else, so the single-threaded `Io` the rest
    // of the tree reaches for in the same situation is enough here too.
    const io = Io.Threaded.global_single_threaded.io();

    var clauses = try lrmClauses(arena, io, options.docs_root);
    // A floor, not the count: the count is what `--coverage` prints and it must
    // be free to move as `docs/` is corrected. 500 is far below the 611 this
    // tree finds and far above what any partial parse would leave.
    try std.testing.expect(clauses.count() > 500);
    try std.testing.expectEqualStrings(
        "Operators with real operands",
        clauses.get("4.2.1").?.title,
    );
    // Chapter 5 carries its headings as bare lines and has three `id=` anchors
    // in the whole file, which is why this reads text and not anchors.
    try std.testing.expectEqualStrings("cross function", clauses.get("5.10.3.1").?.title);
    // A clause of IEEE 1364 quoted in chapter 9 is not a clause of this LRM.
    try std.testing.expect(clauses.get("17.9.3") == null);
}
