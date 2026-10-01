//! VerA as a harness `Compiler` for `zig build benchmark`: fixture -> verdict.
//! `//! reject` must refuse with every substring in the diagnostic; `//! warn`
//! must compile with each substring in a warning; anything else must compile,
//! build a native testbench, run, and print `ok=1` for every assertion. The
//! `want` of an assertion is a hand-derived literal, so VerA never supplies its
//! own expectation and no golden transcript exists.

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("suite_options");
/// The suite's fixture root and LRM directory, shared with `harness.zig`.
const suite = options;

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

/// VerA at full depth: compile, build a testbench, run it, read the `ok=`
/// columns. `cfg` is borrowed for its `fixture_opt`/`fixture_backend` and must
/// outlive the returned plug.
pub fn compiler(cfg: *harness.Config) harness.Compiler {
    return .{
        .name = "vera",
        .runs = true,
        .owns_xfail = true,
        .ctx = cfg,
        .check = check,
    };
}

/// VerA held to what a foreign compiler is held to (accept or refuse only), so
/// the head-to-head's agreement column asks both sides the same question.
pub fn acceptRejectCompiler() harness.Compiler {
    return .{
        .name = "vera",
        .runs = false,
        // `//! xfail` marks debt against the full claim; a fixture that compiles
        // and then computes a wrong number is met here and would XPASS.
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

/// One accept/reject compilation, the unit the head-to-head times: returns the
/// emitted device's size, or null when VerA refused. No testbench is built, so
/// no `zig build-exe` time lands in VerA's number.
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
    const cfg: *const harness.Config = @ptrCast(@alignCast(ctx));
    if (d.reject.len != 0) return verifyRejected(gpa, f, source, d, w);
    return runAndCheck(gpa, io, arena, cfg, f, source, d, w);
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

/// What one compilation did. `accepted` carries the device's size, not its
/// text: nothing downstream reads the text.
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
    // `.build` (not `.lint`) so stage 6 runs: some fixtures are rejected by
    // codegen emitting `@compileError`, which `.lint` would never see.
    var result = vera.compileSourceOpts(gpa, source, .build, .{
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

/// Whether the failure matches a `//! reject` pattern: a code, an error name,
/// `@compileError` text, a diagnostic substring, or a phase label derived from
/// the failure:
///   `DiagnosticsReported`  the failure carries at least one diagnostic.
///   `ParseError`           every diagnostic came from preprocess or parse.
fn failureContains(f: Failure, pattern: []const u8) bool {
    if (asCode(pattern) != null) {
        for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
        return false;
    }
    if (std.mem.indexOf(u8, f.error_name, pattern) != null) return true;
    if (f.generated) |g| if (std.mem.indexOf(u8, g, pattern) != null) return true;

    if (!f.diags.isEmpty()) {
        if (std.mem.eql(u8, pattern, "DiagnosticsReported")) return true;
        if (std.mem.eql(u8, pattern, "ParseError")) {
            for (0..f.diags.count()) |i| switch (f.diags.at(i).stage) {
                .preprocess, .parse => {},
                .lower, .proof, .codegen => return false,
            };
            return true;
        }
    }
    for (0..f.diags.count()) |i| if (diagSays(&f.diags, i, pattern)) return true;
    return false;
}

/// Does diagnostic `i` say `pattern`: its code when `pattern` is one, else a
/// substring of its message, point, catalogue title or a note.
fn diagSays(bag: *const vera.diag.Bag, i: usize, pattern: []const u8) bool {
    const d = bag.at(i);
    if (asCode(pattern)) |want| return d.code == want;
    // The title too: much wording lives in `Info.title`, not the message.
    if (std.mem.indexOf(u8, d.message, pattern) != null) return true;
    if (std.mem.indexOf(u8, d.point, pattern) != null) return true;
    if (std.mem.indexOf(u8, vera.diag.info(d.code).title, pattern) != null) return true;
    var nbuf: [vera.diag.max_children]vera.diag.Note = undefined;
    for (bag.notes(d, &nbuf)) |n| {
        if (std.mem.indexOf(u8, n.text, pattern) != null) return true;
    }
    return false;
}

/// `//! warn`: every pattern names a warning in `bag`. `//! nowarn`: `bag`
/// holds no warning. Detail goes to `w` on a miss.
fn warningsMet(bag: *vera.diag.Bag, f: Fixture, d: vera.tb.Directives, w: *Io.Writer) !bool {
    for (d.warn) |pattern| {
        for (0..bag.count()) |i| {
            if (bag.at(i).severity == .warning and diagSays(bag, i, pattern)) break;
        } else {
            try w.print("FAIL {s}: no warning matches: \"{s}\"\n", .{ f.path, pattern });
            vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
            return false;
        }
    }
    if (d.nowarn and bag.count() != 0) {
        try w.print("FAIL {s}: `//! nowarn`, and the compile warned:\n", .{f.path});
        vera.diag.render(bag, w, .{ .explain_hint = false, .summary = false }) catch {};
        return false;
    }
    return true;
}

/// A directive is either a CODE (`E0313`, `W0650`) or a message substring.
///
/// Codes are preferred: they are stable and pin which rule fired.
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
    cfg: *const harness.Config,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    w: *Io.Writer,
) !Result {
    // Stages 1-6 with §9.4 display ON. W0650 is about speed, and every fixture
    // that probes a node trips it; allowing it here keeps the transcript about
    // the model rather than about float modes — unless a `//! warn` names it.
    var diags: vera.diag.Bag = .init(gpa);
    defer diags.deinit(gpa);
    var levels: vera.diag.Levels = .empty;
    defer levels.deinit(gpa);
    for (d.warn) |p| {
        if (std.mem.eql(u8, p, "W0650")) break;
    } else try levels.set(gpa, .W0650, .allow);

    var opts: vera.Options = .{
        .file_name = f.path,
        .include_dirs = &.{ f.dir, f.root },
        .diags = &diags,
        .lint = levels,
        .display = .emit,
        .spice_netlist = d.spice,
    };
    var result = vera.compileSourceOpts(gpa, source, .build, opts) catch |err| {
        try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
        vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
        return .unmet;
    };
    defer result.deinit();
    // §3.4 a `//! param` card value for a shape parameter is a compile-time
    // value: compile again for it, as `vera --emit-exe` does.
    opts.param_overrides = try vera.tb.shapeOverrides(arena, d, result.lowered);
    if (opts.param_overrides.len != 0) {
        diags.deinit(gpa);
        diags = .init(gpa);
        const again = vera.compileSourceOpts(gpa, source, .build, opts) catch |err| {
            try w.print("FAIL {s}: did not compile: {t}\n", .{ f.path, err });
            vera.diag.render(&diags, w, .{ .explain_hint = false, .summary = false }) catch {};
            return .unmet;
        };
        result.deinit();
        result = again;
    }

    const device = result.generateDevice() catch |err| {
        try w.print("FAIL {s}: codegen failed: {t}\n", .{ f.path, err });
        return .unmet;
    };
    if (result.device_has_compile_error) {
        try w.print("FAIL {s}: codegen refused a construct (generated output is not usable)\n", .{f.path});
        return .unmet;
    }
    // An LLVM intrinsic link-fails under `--zig-backend=native`.
    if (std.mem.indexOf(u8, device, "extern fn @\"llvm.") != null) {
        try w.print("FAIL {s}: the device declares an `llvm.*` intrinsic; it cannot build under the self-hosted backend\n", .{f.path});
        return .unmet;
    }
    try vera.tb.warnGridEvents(&diags, result.lowered, result.mir);
    if (!try warningsMet(&diags, f, d, w)) return .unmet;

    // VAMS §7: a module with a discrete half gets the mixed-signal runner.
    var dm = d;
    dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
    dm.op_states = try vera.tb.opStates(arena, result.lowered);
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
        .optimize = cfg.fixture_opt,
        .backend = cfg.fixture_backend,
        .strip = true,
    }) catch |err| {
        try w.print("FAIL {s}: building the testbench: {t}\n", .{ f.path, err });
        return .unmet;
    };
    defer built.deinit(gpa);
    const bin = switch (built) {
        // Every testbench build failure is an engine bug; there is no excused
        // case. Make a failure impossible before adding an excuse for it.
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

/// Runs the testbench and returns its stderr, where both `$strobe` output and
/// the residual dump go, in program order. Caller frees with `gpa`.
///
/// The child runs in its own work directory, so §9.5 file I/O resolves in a
/// per-fixture namespace rather than the repository root. `bin` is
/// `<work>/<name>`, so from inside `work` it is `./<name>`.
fn capture(gpa: std.mem.Allocator, io: Io, bin: []const u8, work: []const u8, expected_exit: u8, plusargs: []const []const u8) ![]const u8 {
    var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv0 = try std.fmt.bufPrint(&argv0_buf, "./{s}", .{std.fs.path.basename(bin)});
    const argv = try gpa.alloc([]const u8, 1 + plusargs.len);
    defer gpa.free(argv);
    argv[0] = argv0;
    @memcpy(argv[1..], plusargs);
    const r = try std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = work } });
    gpa.free(r.stdout);
    var text: std.ArrayList(u8) = .fromOwnedSlice(r.stderr);
    errdefer text.deinit(gpa);
    // Exit status is part of the oracle, even when earlier assertions passed.
    // Fatal-task fixtures opt into their expected status with `//! exit`.
    switch (r.term) {
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
    const missing = try runAndCheck(gpa, std.testing.io, arena, &.{}, fixture, source, .{ .expected_checks = 2 }, &report.writer);
    try std.testing.expect(missing == .unmet);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "observed 1 assertion(s), expected exactly 2") != null);
    const complete = try runAndCheck(gpa, std.testing.io, arena, &.{}, fixture, source, .{ .expected_checks = 1 }, &report.writer);
    try std.testing.expect(complete == .met);
    const duplicated = try runAndCheck(gpa, std.testing.io, arena, &.{}, fixture, source, .{
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
    const unexpected = try runAndCheck(gpa, std.testing.io, arena, &.{}, fixture, source, .{}, &report.writer);
    try std.testing.expect(unexpected == .unmet);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "exit 1, expected 0") != null);
    const expected = try runAndCheck(gpa, std.testing.io, arena, &.{}, fixture, source, .{ .expected_exit = 1 }, &report.writer);
    try std.testing.expect(expected == .met);
}

test {
    _ = harness;
}
