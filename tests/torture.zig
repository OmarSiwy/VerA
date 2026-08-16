//! The torture suite — the ONE runner, over every `tests/fixtures/**/*.va`.
//!
//! It replaced four separate runners (`conformance`, `exhaustive`, `sema.sh`,
//! `ledger`) because they disagreed about what a fixture IS. Here a fixture is
//! one `.va` and nothing else is required to read it: the file states its own
//! expected behavior, in one of exactly two forms.
//!
//!   `//! reject <substring>`   must NOT compile, and every substring must
//!                              appear in the resulting diagnostic
//!   anything else              must compile, build a native testbench, RUN,
//!                              and print `ok=1` for every assertion it makes
//!
//! WHY A TRANSCRIPT SNAPSHOT IS NOT AN ORACLE, and what replaces it. The
//! deleted `.expected.zig` files were VerA's own output fed back to it: a wrong
//! answer, once recorded, was frozen as correct forever. So the ASSERTION is not
//! the golden file. It is the `ok=` column the fixture itself computes:
//!
//!     `CHECKR("sin(0.5)", sin(0.5), 0.479425538604203, 1e-15);
//!     -> sin(0.5) got=0.479425538604203 want=0.479425538604203 ok=1
//!
//! The `want` is a NUMERIC LITERAL, derived from the LRM or a reference
//! implementation by a human, and `checkAssertions` below REFUSES a fixture
//! whose want is anything else. That is the mechanical part of "restricting and
//! true": VerA cannot supply its own expectation, because an expression is not
//! a literal. A reviewer checks the digits once; after that a regression turns
//! `ok=1` into `ok=0` and this runner fails.
//!
//! THERE IS NO GOLDEN FILE. Not "there is one and we also assert" — there is
//! none, deliberately. A recorded transcript can only ever say "this is what
//! VerA printed last time", which is the same self-confirming oracle the
//! `.expected.zig` snapshots were, and it makes a diff the reviewer's whole job.
//! Everything a fixture claims now lives in the fixture, so a `.va` is readable
//! and reviewable on its own and there is no second file to drift out of step.
//!
//! A VERDICT IS NOT ALWAYS THE FIXTURE'S FAULT, and conflating the two lies in
//! both directions. Reporting an engine limitation as FAIL buries the real
//! conformance bugs in noise AND blames an author who has no move to make. So
//! `refused` is its own verdict: the fixture is correct, VerA compiled it
//! correctly, and the host still will not run it. It is not a pass, it is
//! printed by name with the reason, and `--strict` fails on it — a limitation
//! that costs nothing to carry is a limitation nobody ever fixes.
//!
//! Deterministic by construction: sorted walk, one binary per fixture, `-ODebug`
//! so no reassociation, every number at fixed precision.
//!
//!   zig build torture                 # every fixture
//!   zig build torture -- ch04         # only paths matching `ch04`
//!   zig build torture -- --strict     # unasserted and refused FAIL instead of warn

const std = @import("std");
const vera = @import("vera");
const options = @import("torture_options");

const Io = std.Io;

/// Everything one fixture needs, all with the same lifetime.
const Fixture = struct {
    /// `tests/fixtures/ch04_expressions/01_arithmetic.va`
    path: []const u8,
    /// `01_arithmetic`
    stem: []const u8,
    /// `tests/fixtures/ch04_expressions`
    dir: []const u8,
};

/// Why a fixture failed to produce a device, in the vocabulary the `//! reject`
/// directives are written in.
const Failure = struct {
    /// `@errorName` of the returned error, or a synthetic name for the two
    /// failure modes that are not Zig errors (see `compileFixture`).
    error_name: []const u8,
    diags: vera.diag.Bag,
    /// Non-null only for `GeneratedCompileError`; owned by `gpa`.
    generated: ?[]const u8 = null,
};

const Attempt = union(enum) { ok, failed: Failure };

const Verdict = enum {
    /// Behaved as the fixture said it would.
    pass,
    /// Did not.
    fail,
    /// Compiled, ran, and asserted NOTHING. Green under the old suites, and the
    /// reason this one exists.
    unasserted,
    /// Compiled, but the engine will not accept the device it produced, so the
    /// fixture never got to state anything. Distinct from `fail` because the
    /// author cannot act on it: see `refusedByContract`.
    refused,
};

/// Does this `zig build-exe` failure mean the ENGINE declined the device, rather
/// than the device being broken?
///
/// Exactly one refusal is known: `contract.validate` demands `num_ports` in
/// `1..|U|`, and a module with no port list — legal, Annex A.1.2 makes the port
/// list optional — lowers to zero terminals. VerA compiled it correctly; there is
/// simply nothing for the host to stamp it into.
///
/// Matched on that one message and no other, because every OTHER way the
/// generated testbench can fail to compile is a real codegen bug that must stay
/// loud. A blanket "build failed => not our problem" would swallow them all.
fn refusedByContract(build_output: []const u8) bool {
    return std.mem.indexOf(u8, build_output, "num_ports must be in 1..|U|") != null;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var strict = false;
    var filter: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--strict")) strict = true else filter = a;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const w = &stderr.interface;

    const fixtures = try collect(arena, io, options.fixture_root, filter);
    if (fixtures.len == 0) {
        try w.print("torture: no fixtures under {s}\n", .{options.fixture_root});
        try w.flush();
        return 1;
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var unasserted: usize = 0;
    var refused: usize = 0;
    for (fixtures) |f| {
        switch (try runFixture(gpa, io, arena, f, strict, w)) {
            .pass => passed += 1,
            .fail => failed += 1,
            .unasserted => unasserted += 1,
            .refused => refused += 1,
        }
        try w.flush();
    }

    try w.print("\ntorture: {d}/{d} fixtures behave as they say they do\n", .{ passed, fixtures.len });
    if (failed != 0) try w.print("  {d} FAILED\n", .{failed});
    if (unasserted != 0) try w.print(
        "  {d} compiled and ran but ASSERT NOTHING — they prove only that VerA did\n" ++
            "  not crash. Give each a `CHECK(\"what this proves\", got, want, tol)`\n" ++
            "  from check.vh with an independently derived want. (`--strict` fails on these.)\n",
        .{unasserted},
    );
    if (refused != 0) try w.print(
        "  {d} CANNOT RUN — a known ENGINE limitation, not a fixture defect: the\n" ++
            "  module declares no ports (legal, Annex A.1.2), so the device has zero\n" ++
            "  terminals and `contract.validate` refuses it with `num_ports must be in\n" ++
            "  1..|U|`. Nothing the fixture says can change that, so it is not counted\n" ++
            "  as a pass. Do not add ports to make it run — that changes what it tests.\n" ++
            "  (`--strict` fails on these, so the limitation cannot be forgotten.)\n",
        .{refused},
    );
    try w.flush();
    return if (failed == 0 and !(strict and (unasserted != 0 or refused != 0))) 0 else 1;
}

/// Sorted so the run is deterministic (`Dir.walk` order is explicitly undefined)
/// and a failing run is reproducible and diffable. `filter` is a plain substring
/// over the whole path: `zig build torture -- ch04` runs one group.
fn collect(arena: std.mem.Allocator, io: Io, root: []const u8, filter: ?[]const u8) ![]const Fixture {
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
        try list.append(arena, .{
            .path = path,
            .stem = base[0 .. base.len - ".va".len],
            .dir = std.fs.path.dirname(path) orelse ".",
        });
    }
    std.mem.sort(Fixture, list.items, {}, struct {
        fn lt(_: void, a: Fixture, b: Fixture) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return list.items;
}

fn runFixture(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
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

    if (d.reject.len != 0) return verifyRejected(gpa, arena, f, source, d.reject, w);
    return verifyRuns(gpa, io, arena, f, source, d, strict, w);
}

// ---------------------------------------------------------------------------
// The reject half: the expected behavior is a diagnostic
// ---------------------------------------------------------------------------

fn verifyRejected(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    patterns: []const []const u8,
    w: *Io.Writer,
) !Verdict {
    _ = arena;
    var attempt = try compileFixture(gpa, f, source);
    defer switch (attempt) {
        .ok => {},
        .failed => |*bad| {
            if (bad.generated) |g| gpa.free(g);
            bad.diags.deinit(gpa);
        },
    };

    const bad = switch (attempt) {
        .ok => {
            try w.print("FAIL {s}: expected a diagnostic, but it compiled cleanly\n", .{f.path});
            return .fail;
        },
        .failed => |bad| bad,
    };

    for (patterns) |pattern| {
        if (!failureContains(bad, pattern)) {
            try w.print("FAIL {s}: diagnostic substring not found: \"{s}\"\n", .{ f.path, pattern });
            try w.print("  error: {s}\n", .{bad.error_name});
            try printDiags(bad, w);
            return .fail;
        }
    }
    return .pass;
}

/// One compilation, collapsed to `ok` or a `Failure`. Two failure modes are not
/// Zig errors and get synthetic names, matching the vocabulary the fixtures use:
///   `DiagnosticsReported`  — compiled, but a stage reported a message.
///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8) !Attempt {
    var diags: vera.diag.Bag = .init(gpa);
    // `.debug` (not `.lint`) so stage 6 runs: some fixtures are rejected by
    // codegen emitting `@compileError`, which `.lint` would never see.
    var result = vera.compileSourceOpts(gpa, source, .debug, .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir, options.fixture_root },
        .diags = &diags,
    }) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .failed = .{ .error_name = @errorName(err), .diags = diags } };
    };
    errdefer result.deinit();

    if (diags.failed()) {
        var r = result;
        r.deinit();
        return .{ .failed = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }

    const generated = result.generateDevice() catch |err| {
        var r = result;
        r.deinit();
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .failed = .{ .error_name = @errorName(err), .diags = diags } };
    };
    if (std.mem.indexOf(u8, generated, "@compileError") != null) {
        // The generated text dies with the arena, so it has to be duped into
        // `gpa` before the result is dropped.
        const owned = try gpa.dupe(u8, generated);
        var r = result;
        r.deinit();
        return .{ .failed = .{
            .error_name = "GeneratedCompileError",
            .diags = diags,
            .generated = owned,
        } };
    }

    result.deinit();
    diags.deinit(gpa);
    return .ok;
}

/// A rejection is described by more than the returned error value: the `//!
/// reject` lines are written in a vocabulary of PHASE labels ("ParseError",
/// "DiagnosticsReported") as well as of error names and message substrings.
/// Each label below is a fact derived from the failure, not an alias invented to
/// make a fixture pass:
///   `DiagnosticsReported` — the failure carries at least one diagnostic.
///   `ParseError`          — every diagnostic came from stage 1/2/3, i.e. the
///                           model never reached lowering.
/// A lowering or proof rejection therefore still fails a fixture that demands
/// `ParseError`; the labels discriminate.
fn failureContains(f: Failure, pattern: []const u8) bool {
    if (asCode(pattern)) |want| {
        for (f.diags.messages()) |mi| {
            if (f.diags.get(mi).code == want) return true;
        }
        return false;
    }
    if (std.mem.indexOf(u8, f.error_name, pattern) != null) return true;
    if (f.generated) |g| if (std.mem.indexOf(u8, g, pattern) != null) return true;

    const diags = f.diags.messages();
    if (diags.len != 0) {
        if (std.mem.eql(u8, pattern, "DiagnosticsReported")) return true;
        if (std.mem.eql(u8, pattern, "ParseError")) {
            for (diags) |mi| switch (f.diags.get(mi).stage) {
                .preprocess, .parse => {},
                .lower, .proof, .codegen => return false,
            };
            return true;
        }
    }
    // Substring match runs over the message AND the catalogue title, because
    // migrating to codes moved a lot of wording out of the message and into
    // `Info.title` — a fixture pinning the old prose still matches.
    var nbuf: [vera.diag.max_children]vera.diag.Note = undefined;
    for (diags) |mi| {
        const d = f.diags.get(mi);
        if (std.mem.indexOf(u8, d.message, pattern) != null) return true;
        if (std.mem.indexOf(u8, d.point, pattern) != null) return true;
        if (std.mem.indexOf(u8, vera.diag.info(d.code).title, pattern) != null) return true;
        for (f.diags.notes(d, &nbuf)) |n| {
            if (std.mem.indexOf(u8, n.text, pattern) != null) return true;
        }
    }
    return false;
}

/// A directive is either a CODE (`E0313`, `W0650`) or a message substring.
///
/// Codes are the preferred form: they are stable, so the prose of a diagnostic
/// can be improved without touching 301 fixtures, and they pin WHICH rule fired
/// rather than how it happened to be worded.
fn asCode(pattern: []const u8) ?vera.diag.Code {
    if (pattern.len != 5) return null;
    if (pattern[0] != 'E' and pattern[0] != 'W') return null;
    for (pattern[1..]) |c| if (c < '0' or c > '9') return null;
    return std.meta.stringToEnum(vera.diag.Code, pattern);
}

fn printDiags(f: Failure, w: *Io.Writer) !void {
    // Render the real thing, so a failing fixture shows exactly what a user
    // would see — snippet, carets, notes and all. Colour is off: this output is
    // read from a log as often as from a terminal.
    var bag = f.diags;
    vera.diag.render(&bag, w, .{ .explain_hint = false, .summary = false }) catch {};
    // A `@compileError` carries the whole reason; without it
    // "GeneratedCompileError" says nothing about WHICH construct codegen refused.
    if (f.generated) |g| {
        var rest = g;
        while (std.mem.indexOf(u8, rest, "@compileError")) |at| {
            const line_end = std.mem.indexOfScalar(u8, rest[at..], '\n') orelse rest.len - at;
            try w.print("  codegen: {s}\n", .{rest[at .. at + line_end]});
            rest = rest[at + line_end ..];
        }
    }
}

// ---------------------------------------------------------------------------
// The run half: the expected behavior is a transcript the model asserts itself
// ---------------------------------------------------------------------------

fn verifyRuns(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    strict: bool,
    w: *Io.Writer,
) !Verdict {
    // Refuse a fixture that cannot fail BEFORE spending a `zig build-exe` on it.
    // A tautology compiles and runs and prints `ok=1` forever.
    switch (checkAssertions(source)) {
        .ok => {},
        .none => {
            if (strict) {
                try w.print(
                    "FAIL {s}: asserts nothing — compiling and running is not an expectation.\n" ++
                        "  Add `CHECK(\"what this proves\", got, want, tol)` from check.vh.\n",
                    .{f.path},
                );
                return .fail;
            }
            // Still built and run below in non-strict mode: "does not crash" is
            // a weak claim but it is not nothing, and it is what these fixtures
            // have always been worth.
        },
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
                    "  An expression lets VerA supply its own expectation, which is how a\n" ++
                    "  wrong answer gets frozen as correct. Write the digits.\n",
                .{ f.path, site },
            );
            return .fail;
        },
    }

    // Stages 1-6 with §9.4 display ON. W0650 is about speed, and every fixture
    // that probes a node trips it; allowing it here keeps the transcript about
    // the model rather than about float modes.
    var diags: vera.diag.Bag = .init(gpa);
    defer diags.deinit(gpa);
    var levels: vera.diag.Levels = .empty;
    defer levels.deinit(gpa);
    try levels.set(gpa, .W0650, .allow);

    var result = vera.compileSourceOpts(gpa, source, .release_fast, .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir, options.fixture_root },
        .diags = &diags,
        .lint = levels,
        .display = .emit,
    }) catch |err| {
        try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
        vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
        return .fail;
    };
    defer result.deinit();

    const device = result.generateDevice() catch |err| {
        try w.print("FAIL {s}: codegen failed: {t}\n", .{ f.path, err });
        return .fail;
    };
    if (result.device_has_compile_error) {
        try w.print("FAIL {s}: codegen refused a construct (@compileError in the device)\n", .{f.path});
        return .fail;
    }

    const runner = try vera.tb.renderRunner(arena, f.stem, d);

    // One work directory per fixture: two fixtures may declare the same module
    // name, and a shared scratch would race them onto one `device.zig`.
    const work = try std.fs.path.join(arena, &.{ options.work_root, f.stem });
    const built = vera.tb.buildExe(gpa, io, device, runner, .{
        .work_dir = work,
        .contract = options.contract,
        .name = result.mir.name,
        .zig_exe = options.zig_exe,
    }) catch |err| {
        try w.print("FAIL {s}: building the testbench: {t}\n", .{ f.path, err });
        return .fail;
    };
    defer built.deinit(gpa);
    const bin = switch (built) {
        .failed => |text| {
            if (refusedByContract(text)) {
                try w.print(
                    "CANNOT RUN {s}: the device contract refuses this module —\n" ++
                        "  no port list (Annex A.1.2), so `num_ports` is 0 and there is nothing\n" ++
                        "  to stamp. VerA compiled it; the engine will not host it.\n",
                    .{f.path},
                );
                return .refused;
            }
            try w.print(
                "FAIL {s}: the generated testbench does not compile — an ENGINE bug:\n{s}\n",
                .{ f.path, text },
            );
            return .fail;
        },
        .ok => |p| p,
    };

    const got = capture(gpa, io, bin) catch |err| {
        try w.print("FAIL {s}: running the testbench: {t}\n", .{ f.path, err });
        return .fail;
    };
    defer gpa.free(got);

    // THE ASSERTION, and the only one there is.
    const tally = countVerdicts(got);
    if (tally.failed != 0) {
        try w.print("FAIL {s}: {d} of {d} assertion(s) reported ok=0:\n", .{
            f.path, tally.failed, tally.total,
        });
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "ok=0") != null) try w.print("    {s}\n", .{line});
        }
        return .fail;
    }

    // A fixture may also report failure in prose — a §9.7.3 severity task, or a
    // computed verdict that is not an `ok=` column.
    if (std.mem.indexOf(u8, got, "FAIL") != null) {
        try w.print("FAIL {s}: the testbench itself reported a failure:\n{s}\n", .{ f.path, got });
        return .fail;
    }

    return if (tally.total == 0) .unasserted else .pass;
}

const Tally = struct { total: usize, failed: usize };

/// Count the `ok=` verdicts a transcript carries. `ok=1` passes, anything else
/// fails — a malformed verdict is not a pass.
fn countVerdicts(text: []const u8) Tally {
    var t: Tally = .{ .total = 0, .failed = 0 };
    var rest = text;
    while (std.mem.indexOf(u8, rest, "ok=")) |at| {
        rest = rest[at + "ok=".len ..];
        t.total += 1;
        if (!std.mem.startsWith(u8, rest, "1")) t.failed += 1;
    }
    return t;
}

const AssertionCheck = union(enum) {
    /// At least one assertion, and every one of them can fail.
    ok,
    /// No `CHECK` macro anywhere in the source.
    none,
    /// `CHECK("x", expr, expr, tol)` — got and want are textually identical.
    tautology: []const u8,
    /// The want is not a numeric literal, so it may be VerA's own output.
    computed_want: []const u8,
};

/// The mechanical half of "restricting and true", run on RAW source before the
/// fixture costs a compile.
///
/// TRUE cannot be mechanised — whether `0.479425538604203` really is sin(0.5) is
/// a human's job, once, at review. What CAN be mechanised is the thing that made
/// the old snapshots worthless: the want must be a literal a human typed, never
/// an expression the compiler under test evaluates. `CHECK("sin", sin(0.5),
/// sin(0.5), 1e-15)` passes in any compiler, correct or not, and this rejects it.
fn checkAssertions(source: []const u8) AssertionCheck {
    var found = false;
    var rest = source;
    while (std.mem.indexOf(u8, rest, "`CHECK")) |at| {
        rest = rest[at..];
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse break;
        const close = matchParen(rest, open) orelse break;
        const site = trimLine(rest[0..@min(close + 1, rest.len)]);

        // `CHECKEQ` is the marked relational form: its want is another VerA
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

/// Run the testbench and return everything it said. stderr, because that is
/// where `std.debug.print` writes — both the model's `$strobe` output and the
/// harness's residual dump, so the interleaving is the program's, not the OS's.
fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8) ![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{bin},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &text);
    _ = reader.interface.streamRemaining(&aw.writer) catch {};
    text = aw.toArrayList();
    // A nonzero status is part of the transcript: `$finish`/`$fatal` and a panic
    // in generated code both show up here, and silently dropping it would let a
    // crashing testbench match a golden that records the output it managed to
    // produce first.
    switch (try child.wait(io)) {
        .exited => |c| if (c != 0) {
            var line: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "<testbench exited with status {d}>\n", .{c}) catch unreachable;
            try text.appendSlice(gpa, s);
        },
        else => try text.appendSlice(gpa, "<testbench did not exit normally>\n"),
    }
    return text.toOwnedSlice(gpa);
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
    // The marked relational form may pin two VerA expressions together...
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("branch probe equals the node pair", V(br), V(a, b), 0.0);
    ) == .ok);
    // ...but not to itself.
    try std.testing.expect(checkAssertions(
        \\`CHECKEQ("vacuous", V(a, b), V(a, b), 0.0);
    ) == .tautology);
}

test "only the contract's refusal is excused; any other build error still fails" {
    try std.testing.expect(refusedByContract(
        \\tools/contract.zig:212:9: error: annex_d_magnetic.device.num_ports must be in 1..|U|
    ));
    // A genuine codegen bug that breaks the testbench must stay loud.
    try std.testing.expect(!refusedByContract(
        \\device.zig:88:5: error: expected type 'f64', found '@TypeOf(null)'
    ));
    try std.testing.expect(!refusedByContract(
        \\tools/contract.zig:206:9: error: ex.U must be a dense enum(u8) with values 0..n-1
    ));
}

test "verdicts are counted, and a malformed one is not a pass" {
    try std.testing.expectEqual(Tally{ .total = 0, .failed = 0 }, countVerdicts("no verdicts here"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 0 }, countVerdicts("a ok=1\nb ok=1\n"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 1 }, countVerdicts("a ok=1\nb ok=0\n"));
    try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts("a ok=\n"));
}
