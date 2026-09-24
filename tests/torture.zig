//! VerA plugged into the conformance harness — the torture suite.
//!
//! NOT AN ENTRY POINT. `tests/bench.zig` owns `main` and the only step,
//! `benchmark`; this file is a value it imports: one `harness.Compiler`, plus
//! the accept/reject-only reduction of the same compiler that the head-to-head
//! against OpenVAF needs (see `acceptRejectCompiler`).
//!
//! `tests/harness.zig` owns the fixture format, the verdict algebra and the
//! report; this file owns the one thing that is VerA's alone: what it MEANS for
//! VerA to do what a fixture says.
//!
//!   `//! reject <substring>`   must NOT compile, and every substring must
//!                              appear in the resulting diagnostic
//!   anything else              must compile, build a native testbench, RUN,
//!                              and print `ok=1` for every assertion it makes
//!
//! The second half is why VerA is the runner with `runs = true`. An external
//! compiler can be held to accept-or-refuse and no more; VerA is called
//! in-process, its device is handed to `zig build-exe`, and the resulting binary
//! is executed — so the `ok=` column, which is the only assertion this suite
//! has, is actually evaluated. That is the depth `--against-openvaf` cannot
//! reach, and the reason the report has a VerA-ONLY section: the `ok=` columns
//! are not a score the other compiler lost, they are a question it was never
//! asked.
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
//! implementation by a human, and the harness's `checkAssertions` REFUSES a
//! fixture whose want is anything else. That is the mechanical part of
//! "restricting and true": VerA cannot supply its own expectation, because an
//! expression is not a literal.
//!
//! THERE IS NO GOLDEN FILE. Not "there is one and we also assert" — there is
//! none, deliberately. A recorded transcript can only ever say "this is what
//! VerA printed last time", which is the same self-confirming oracle the
//! `.expected.zig` snapshots were, and it makes a diff the reviewer's whole job.
//! Everything a fixture claims now lives in the fixture, so a `.va` is readable
//! and reviewable on its own and there is no second file to drift out of step.
//!
//! FIXTURE BINARIES ARE BUILT `-ODebug`, and not out of timidity about floats:
//! Zig has no `-ffast-math`, so float arithmetic is strict IEEE in every
//! optimize mode unless the code asks for `@setFloatMode(.optimized)`, which a
//! generated device does not. The reasons are that a testbench compiles for
//! seconds and runs for microseconds — compile time IS the run time, and
//! ReleaseFast would make the whole suite slower, not faster — and that Debug
//! keeps the safety checks on, so a codegen bug traps loudly instead of
//! producing a plausible wrong number. `--fixture-opt=ReleaseFast` exists to
//! ask the separate, real question "does this still pass under optimization?",
//! deliberately and not by default.
//!
//!   zig build benchmark                   # every fixture
//!   zig build benchmark -- ch04           # only paths matching `ch04`
//!   zig build benchmark -- --strict       # unasserted, refused and xfail FAIL
//!   zig build benchmark -- --coverage     # LRM clauses cited, one-sided, uncited
//!   zig build benchmark -- -j1            # one at a time, streaming; for debugging
//!   zig build benchmark -- --fixture-opt=ReleaseFast
//!   zig build benchmark -- --fixture-root=tests/pending   # the tree meant to fail

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("suite_options");
/// The two directories the SUITE owns, shared with `harness.zig` and the other
/// runner: which fixtures to walk, and which LRM their `//! lrm` lines cite.
const suite = options;

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

/// VerA at full depth: compile, build a testbench, run it, read the `ok=`
/// columns. `fixture_opt` is borrowed — it lives in the caller's `Config`.
pub fn compiler(fixture_opt: *std.builtin.OptimizeMode) harness.Compiler {
    return .{
        .name = "vera",
        .runs = true,
        .owns_xfail = true,
        .ctx = fixture_opt,
        .check = check,
    };
}

/// VerA held to exactly what a foreign compiler can be held to: did it accept
/// what the LRM says must compile and refuse what it says must not?
///
/// This exists so the head-to-head's agreement column is the SAME question for
/// both sides. Scoring VerA with the plug above instead would compare a
/// compile-build-run verdict against an accept-or-refuse one and print the
/// difference as if it were about the compilers. It is a strictly weaker claim
/// than `compiler` makes, and the report says so where it prints it.
pub fn acceptRejectCompiler() harness.Compiler {
    return .{
        .name = "vera",
        .runs = false,
        // `//! xfail` is VerA's debt, but it is debt against the FULL claim —
        // a fixture VerA compiles and then gets a wrong number from is unmet
        // there and met here, and honouring the marker would turn that into an
        // XPASS failure of a run that is not asking the question.
        .owns_xfail = false,
        .ctx = &no_ctx,
        .check = checkAcceptReject,
    };
}

var no_ctx: u8 = 0;

fn checkAcceptReject(
    _: *anyopaque,
    gpa: std.mem.Allocator,
    _: Io,
    _: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    w: *Io.Writer,
) anyerror!Result {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    const must_reject = d.reject.len != 0;
    if ((outcome == .accepted) == !must_reject) return .met;
    if (must_reject) {
        try w.print("FAIL {s}: the LRM says this must not compile, and vera accepted it.\n", .{f.path});
    } else {
        try w.print("FAIL {s}: must compile, and vera refused it: {s}\n", .{ f.path, outcome.refused.error_name });
    }
    return .unmet;
}

/// ONE accept/reject compilation, which is the unit the head-to-head times:
/// source in, emitted device size out, or null when VerA refused it. Exactly
/// the work `--against-openvaf` gives the other compiler and no more — no
/// testbench is built and nothing is run, because nothing can be on that side.
///
/// It is this and not `check` because the `ok=` half costs a `zig build-exe`
/// per fixture, which would put the Zig compiler's wall clock inside a number
/// labelled as VerA's.
pub fn compileOnce(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: vera.tb.Directives) !?usize {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    return switch (outcome) {
        .accepted => |n| n,
        .refused => null,
    };
}

fn check(
    ctx: *anyopaque,
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    w: *Io.Writer,
) anyerror!Result {
    const fixture_opt: *std.builtin.OptimizeMode = @ptrCast(@alignCast(ctx));
    if (d.reject.len != 0) return verifyRejected(gpa, f, source, d, w);
    return runAndCheck(gpa, io, arena, fixture_opt.*, f, source, d, w);
}

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

/// What one compilation did. `accepted` carries the emitted device's SIZE and
/// not its text: the reject half never looks at it, and the head-to-head wants
/// a number, so holding a megabyte of Zig alive past the compilation would only
/// be there to be freed.
const Outcome = union(enum) {
    accepted: usize,
    refused: Failure,

    fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .accepted => {},
            .refused => |*bad| {
                if (bad.generated) |g| gpa.free(g);
                bad.diags.deinit(gpa);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// The reject half: the expected behavior is a diagnostic
// ---------------------------------------------------------------------------

fn verifyRejected(
    gpa: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    w: *Io.Writer,
) !Result {
    var outcome = try compileFixture(gpa, f, source, d);
    defer outcome.deinit(gpa);
    const bad = switch (outcome) {
        .accepted => {
            try w.print("FAIL {s}: expected a diagnostic, but it compiled cleanly\n", .{f.path});
            return .unmet;
        },
        .refused => |b| b,
    };

    for (d.reject) |pattern| {
        if (!failureContains(bad, pattern)) {
            try w.print("FAIL {s}: diagnostic substring not found: \"{s}\"\n", .{ f.path, pattern });
            try w.print("  error: {s}\n", .{bad.error_name});
            try printDiags(bad, w);
            return .unmet;
        }
    }
    return .met;
}

/// One compilation. Two failure modes are not Zig errors and get synthetic
/// names, matching the vocabulary the fixtures use:
///   `DiagnosticsReported`  — compiled, but a stage reported a message.
///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: vera.tb.Directives) !Outcome {
    var diags: vera.diag.Bag = .init(gpa);
    // `.debug` (not `.lint`) so stage 6 runs: some fixtures are rejected by
    // codegen emitting `@compileError`, which `.lint` would never see.
    var result = vera.compileSourceOpts(gpa, source, .debug, .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir, f.root },
        .diags = &diags,
        // Annex E.2: the fixture's `//! spice` cards, read as a netlist.
        .spice_netlist = d.spice,
    }) catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
    };
    defer result.deinit();

    if (diags.failed()) {
        return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }

    const generated = result.generateDevice() catch |err| {
        if (err == error.OutOfMemory) {
            diags.deinit(gpa);
            return error.OutOfMemory;
        }
        return .{ .refused = .{ .error_name = @errorName(err), .diags = diags } };
    };
    if (diags.failed()) {
        return .{ .refused = .{ .error_name = "DiagnosticsReported", .diags = diags } };
    }
    if (result.device_has_compile_error or std.mem.indexOf(u8, generated, "@compileError") != null) {
        // Transfer the GPA-owned text before dropping the compilation.
        result.device.text = "";
        return .{ .refused = .{
            .error_name = "GeneratedCompileError",
            .diags = diags,
            .generated = generated,
        } };
    }

    diags.deinit(gpa);
    return .{ .accepted = generated.len };
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
    for (pattern[1..]) |c| if (!std.ascii.isDigit(c)) return null;
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

fn runAndCheck(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    fixture_opt: std.builtin.OptimizeMode,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    w: *Io.Writer,
) !Result {
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
        .include_dirs = &.{ f.dir, f.root },
        .diags = &diags,
        .lint = levels,
        .display = .emit,
        .spice_netlist = d.spice,
    }) catch |err| {
        try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
        vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
        return .unmet;
    };
    defer result.deinit();

    const device = result.generateDevice() catch |err| {
        try w.print("FAIL {s}: codegen failed: {t}\n", .{ f.path, err });
        return .unmet;
    };
    if (result.device_has_compile_error) {
        try w.print("FAIL {s}: codegen refused a construct (generated output is not usable)\n", .{f.path});
        return .unmet;
    }

    // VAMS §7: a module with a discrete half gets the mixed-signal runner.
    var dm = d;
    dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
    const runner = try vera.tb.renderRunner(arena, f.stem, dm);

    // One work directory per fixture, keyed on the whole relative path: two
    // fixtures may declare the same module name AND share a file name, and a
    // shared scratch would race them onto one `device.zig`.
    const work = try std.fs.path.join(arena, &.{
        options.work_root,
        "torture",
        std.fs.path.basename(f.root),
        f.slug,
    });
    const built = vera.tb.buildExe(gpa, io, device, runner, .{
        .work_dir = work,
        .contract = options.contract,
        .name = result.mir.name,
        .mixed = dm.mixed != null,
        .zig_exe = options.zig_exe,
        .optimize = fixture_opt,
    }) catch |err| {
        try w.print("FAIL {s}: building the testbench: {t}\n", .{ f.path, err });
        return .unmet;
    };
    defer built.deinit(gpa);
    const bin = switch (built) {
        // EVERY build failure is a bug, with no excused case. There used to be
        // one: `contract.validate` refused `num_ports == 0`, so the legal portless
        // module of §6.2 compiled and then had nowhere to run, which is what the
        // harness's `cannot_run` verdict was built for. The guard was stale rather
        // than right — the testbench has had a Newton solve since wave 4, and a
        // device with zero terminals and one internal node has a residual it can
        // solve — so relaxing it deleted the only known refusal along with the
        // pattern match that excused it. Do not add the excuse back for a message
        // you have not first tried to make impossible.
        .failed => |text| {
            try w.print(
                "FAIL {s}: the generated testbench does not compile — an ENGINE bug:\n{s}\n",
                .{ f.path, text },
            );
            return .unmet;
        },
        .ok => |p| p,
    };

    const got = capture(gpa, io, bin, work, d.expected_exit, d.plusargs) catch |err| {
        try w.print("FAIL {s}: running the testbench: {t}\n", .{ f.path, err });
        return .unmet;
    };
    defer gpa.free(got);

    // THE ASSERTION, and the only one there is.
    const tally = countVerdicts(got);
    if (d.expected_checks) |expected| {
        if (tally.total != expected) {
            try w.print("FAIL {s}: observed {d} assertion(s), expected exactly {d}\n", .{
                f.path, tally.total, expected,
            });
            return .unmet;
        }
    }
    if (tally.failed != 0) {
        try w.print("FAIL {s}: {d} of {d} assertion(s) reported ok=0:\n", .{
            f.path, tally.failed, tally.total,
        });
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "ok=0") != null) try w.print("    {s}\n", .{line});
        }
        return .unmet;
    }

    // A fixture may also report failure in prose — a §9.7.3 severity task, or a
    // computed verdict that is not an `ok=` column.
    if (std.mem.indexOf(u8, got, "FAIL") != null) {
        try w.print("FAIL {s}: the testbench itself reported a failure:\n{s}\n", .{ f.path, got });
        return .unmet;
    }

    if (tally.total == 0) {
        try w.print(
            "{s}: compiled and ran, but asserted nothing.\n",
            .{f.path},
        );
        return .unasserted;
    }
    return .met;
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
        const is_one = rest.len != 0 and rest[0] == '1' and
            (rest.len == 1 or std.ascii.isWhitespace(rest[1]));
        if (!is_one) t.failed += 1;
    }
    return t;
}

/// Run the testbench and return everything it said. stderr, because that is
/// where `std.debug.print` writes — both the model's `$strobe` output and the
/// harness's residual dump, so the interleaving is the program's, not the OS's.
///
/// The child runs IN its own work directory, which is what makes §9.5 testable.
/// A fixture that opens a file opens it relative to the process cwd, so with an
/// inherited cwd every §9.5 fixture wrote into the repository root and shared one
/// namespace with the other 1149 — and the rules those fixtures pin are about
/// exactly that namespace: `ch09_047_missing.dat` "is a name no fixture in this
/// directory ever creates", and 052's Table 9-24 type "a" append would otherwise
/// grow the same file on every run forever. One directory per fixture makes both
/// claims hold by construction rather than by everyone remembering to.
///
/// `bin` is `<work>/<name>`, so from inside `work` it is `./<name>`.
fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8, work: []const u8, expected_exit: u8, plusargs: []const []const u8) ![]const u8 {
    var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv0 = try std.fmt.bufPrint(&argv0_buf, "./{s}", .{std.fs.path.basename(bin)});
    const argv = try gpa.alloc([]const u8, 1 + plusargs.len);
    defer gpa.free(argv);
    argv[0] = argv0;
    @memcpy(argv[1..], plusargs);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = work },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var aw: Io.Writer.Allocating = .init(gpa);
    _ = reader.interface.streamRemaining(&aw.writer) catch {};
    var text = aw.toArrayList();
    errdefer text.deinit(gpa);
    // Exit status is part of the oracle, even when earlier assertions passed.
    // Fatal-task fixtures opt into their expected status with `//! exit`.
    switch (try child.wait(io)) {
        .exited => |c| if (c != expected_exit) {
            var line: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "FAIL: <testbench exit {d}, expected {d}>\n", .{ c, expected_exit }) catch unreachable;
            try text.appendSlice(gpa, s);
        },
        else => try text.appendSlice(gpa, "FAIL: <testbench did not exit normally>\n"),
    }
    return text.toOwnedSlice(gpa);
}

test "capture forwards runtime argv without expansion and preserves order" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // Independent POSIX argv probe, not a generated model: the model's current
    // plusarg stub cannot distinguish missing runner plumbing from its own bug.
    // Only this fixed script is interpreted; fixture bytes stay positional
    // arguments, quoted by the probe and never inserted into its source.
    const got = try capture(std.testing.allocator, std.testing.io, "/bin/sh", "/bin", 0, &.{
        "-c",      "for arg do printf '%s\\n' \"$arg\" >&2; done", "argv-probe",
        "+gain=7", "+gain=8",                                      "+gain=7",
        "+empty=", "+literal=$HOME;*",                             "+literal=$(printf_EXPANDED)",
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "+gain=7\n+gain=8\n+gain=7\n+empty=\n+literal=$HOME;*\n+literal=$(printf_EXPANDED)\n",
        got,
    );
    const absent = try capture(std.testing.allocator, std.testing.io, "/bin/sh", "/bin", 0, &.{});
    defer std.testing.allocator.free(absent);
    try std.testing.expectEqualStrings("", absent);
}

test "verdicts are counted, and a malformed one is not a pass" {
    try std.testing.expectEqual(Tally{ .total = 0, .failed = 0 }, countVerdicts("no verdicts here"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 0 }, countVerdicts("a ok=1\nb ok=1\n"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 1 }, countVerdicts("a ok=1\nb ok=0\n"));
    try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts("a ok=\n"));
    try std.testing.expectEqual(Tally{ .total = 1, .failed = 0 }, countVerdicts("a ok=1"));
    for ([_][]const u8{ "ok=10", "ok=1garbage", "ok=1.0", "ok=-1", "ok=" }) |bad| {
        try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts(bad));
    }
}

test "declared check count rejects missing and duplicated observations" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    const source =
        \\module check_count_oracle(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog $strobe("single observation ok=1");
        \\endmodule
    ;
    const fixture: Fixture = .{
        .path = "check_count_oracle.va",
        .stem = "check_count_oracle",
        .dir = suite.fixture_root,
        .root = suite.fixture_root,
        .slug = "harness_check_count_selftest",
    };
    const missing = try runAndCheck(gpa, std.testing.io, arena, .Debug, fixture, source, .{ .expected_checks = 2 }, &report.writer);
    try std.testing.expect(missing == .unmet);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "observed 1 assertion(s), expected exactly 2") != null);
    const complete = try runAndCheck(gpa, std.testing.io, arena, .Debug, fixture, source, .{ .expected_checks = 1 }, &report.writer);
    try std.testing.expect(complete == .met);
    const duplicated = try runAndCheck(gpa, std.testing.io, arena, .Debug, fixture, source, .{
        .expected_checks = 1,
        .times = &.{ 0.0, 1e-9 },
    }, &report.writer);
    try std.testing.expect(duplicated == .unmet);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "observed 2 assertion(s), expected exactly 1") != null);
}

test "a fatal exit after a passing assertion must be explicitly expected" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    const source =
        \\module exit_oracle(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $strobe("before fatal got=1 want=1 ok=1");
        \\    $fatal(1, "intentional exit");
        \\  end
        \\endmodule
    ;
    const fixture: Fixture = .{
        .path = "exit_oracle.va",
        .stem = "exit_oracle",
        .dir = suite.fixture_root,
        .root = suite.fixture_root,
        .slug = "harness_exit_status_selftest",
    };
    const unexpected = try runAndCheck(gpa, std.testing.io, arena, .Debug, fixture, source, .{}, &report.writer);
    try std.testing.expect(unexpected == .unmet);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "exit 1, expected 0") != null);
    const expected = try runAndCheck(gpa, std.testing.io, arena, .Debug, fixture, source, .{ .expected_exit = 1 }, &report.writer);
    try std.testing.expect(expected == .met);
}

test {
    _ = harness;
}
