//! The torture suite — VerA plugged into the conformance harness.
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
//! has, is actually evaluated. That is the depth `zig build conformance` cannot
//! reach against a foreign compiler, and the reason both steps exist.
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
//!   zig build torture                     # every fixture
//!   zig build torture -- ch04             # only paths matching `ch04`
//!   zig build torture -- --strict         # unasserted, refused and xfail FAIL instead of warn
//!   zig build torture -- --coverage       # LRM clauses cited, one-sided and uncited
//!   zig build torture -- -j1              # one at a time, streaming; the debugging path
//!   zig build torture -- --fixture-opt=ReleaseFast

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("torture_options");
/// The two directories the SUITE owns, shared with `harness.zig` and the other
/// runner: which fixtures to walk, and which LRM their `//! lrm` lines cite.
const suite = @import("suite_options");

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

pub fn main(init: std.process.Init) !u8 {
    var vera_runner: Vera = .{
        .fixture_opt = std.meta.stringToEnum(std.builtin.OptimizeMode, options.fixture_optimize).?,
    };
    return harness.run(init, .{
        .name = "vera",
        .runs = true,
        .owns_xfail = true,
        .ctx = &vera_runner,
        .check = Vera.check,
        .arg = Vera.arg,
    });
}

/// The VerA plug. Its only state is the knob the harness knows nothing about.
const Vera = struct {
    /// `-Doptimize` builds the RUNNER; this builds the per-fixture testbench
    /// binaries the runner spawns a `zig build-exe` for. Two different programs,
    /// so two different knobs.
    fixture_opt: std.builtin.OptimizeMode,

    fn arg(ctx: *anyopaque, a: []const u8) bool {
        const self: *Vera = @ptrCast(@alignCast(ctx));
        if (!std.mem.startsWith(u8, a, "--fixture-opt=")) return false;
        const name = a["--fixture-opt=".len..];
        self.fixture_opt = std.meta.stringToEnum(std.builtin.OptimizeMode, name) orelse {
            std.debug.print("torture: not an optimize mode: {s}\n", .{name});
            std.process.exit(1);
        };
        return true;
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
        const self: *Vera = @ptrCast(@alignCast(ctx));
        if (d.reject.len != 0) return verifyRejected(gpa, f, source, d, w);
        return runAndCheck(gpa, io, arena, self.fixture_opt, f, source, d, w);
    }
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
    var attempt = try compileFixture(gpa, f, source, d);
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
            return .unmet;
        },
        .failed => |bad| bad,
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

/// One compilation, collapsed to `ok` or a `Failure`. Two failure modes are not
/// Zig errors and get synthetic names, matching the vocabulary the fixtures use:
///   `DiagnosticsReported`  — compiled, but a stage reported a message.
///   `GeneratedCompileError` — codegen deliberately emitted `@compileError`.
fn compileFixture(gpa: std.mem.Allocator, f: Fixture, source: []const u8, d: vera.tb.Directives) !Attempt {
    var diags: vera.diag.Bag = .init(gpa);
    // `.debug` (not `.lint`) so stage 6 runs: some fixtures are rejected by
    // codegen emitting `@compileError`, which `.lint` would never see.
    var result = vera.compileSourceOpts(gpa, source, .debug, .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir, suite.fixture_root },
        .diags = &diags,
        // Annex E.2: the fixture's `//! spice` cards, read as a netlist.
        .spice_netlist = d.spice,
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
    // ponytail: stdlib digit classification; the E/W + four-digit format stays fixed.
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
        .include_dirs = &.{ f.dir, suite.fixture_root },
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
        try w.print("FAIL {s}: codegen refused a construct (@compileError in the device)\n", .{f.path});
        return .unmet;
    }

    const runner = try vera.tb.renderRunner(arena, f.stem, d);

    // One work directory per fixture, keyed on the whole relative path: two
    // fixtures may declare the same module name AND share a file name, and a
    // shared scratch would race them onto one `device.zig`.
    const work = try std.fs.path.join(arena, &.{ options.work_root, f.slug });
    const built = vera.tb.buildExe(gpa, io, device, runner, .{
        .work_dir = work,
        .contract = options.contract,
        .name = result.mir.name,
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

    const got = capture(gpa, io, bin, work) catch |err| {
        try w.print("FAIL {s}: running the testbench: {t}\n", .{ f.path, err });
        return .unmet;
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
        if (!std.mem.startsWith(u8, rest, "1")) t.failed += 1;
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
fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8, work: []const u8) ![]const u8 {
    var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv0 = try std.fmt.bufPrint(&argv0_buf, "./{s}", .{std.fs.path.basename(bin)});
    var child = try std.process.spawn(io, .{
        .argv = &.{argv0},
        .cwd = .{ .path = work },
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

test "verdicts are counted, and a malformed one is not a pass" {
    try std.testing.expectEqual(Tally{ .total = 0, .failed = 0 }, countVerdicts("no verdicts here"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 0 }, countVerdicts("a ok=1\nb ok=1\n"));
    try std.testing.expectEqual(Tally{ .total = 2, .failed = 1 }, countVerdicts("a ok=1\nb ok=0\n"));
    try std.testing.expectEqual(Tally{ .total = 1, .failed = 1 }, countVerdicts("a ok=\n"));
}

test {
    _ = harness;
}
