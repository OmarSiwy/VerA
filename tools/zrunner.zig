//! zrunner: the test runner for every module's test artifact (`zig build
//! test`); runs the tests and prints a per-module report to stdout. Set
//! `CLICOLOR_FORCE` for colour when the build captures the output.

const std = @import("std");
const builtin = @import("builtin");
const TestFn = std.lang.TestFn;

/// Every test artifact runs `contract`'s conformance checks (opt-in
/// elsewhere, `contract.validating`), so a contract regression fails CI.
pub const vera_validate_contract = true;

/// A test named `xfail(<reason>): ...` states a behaviour the code does not
/// have yet (specification/TESTING.md §4.4): it must fail, and passing is an XPASS
/// failure, so the marker cannot outlive the gap. A leak is never excused.
const xfail_prefix = "xfail(";

/// Seeded inputs `fuzz` adds to each fuzz test's corpus in a plain run.
const fuzz_runs = 256;
/// The longest seeded input, in bytes.
const fuzz_max_len = 4096;
var fuzz_calls: u64 = 0;

/// `std.testing.fuzz` resolves to this (`@import("root").fuzz`). A plain test
/// run is not coverage-guided, so it replays the corpus, the empty input and
/// `fuzz_runs` seeded random inputs: a property test with `Smith` as the
/// generator. Deterministic: the seed is the call's ordinal, so a failure
/// replays, and the failing input is printed in hex. Coverage-guided runs use
/// `zig build fuzz --fuzz`, which takes the stock runner.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *std.testing.Smith) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| try fuzzOne(context, testOne, input);
    try fuzzOne(context, testOne, "");
    var prng: std.Random.DefaultPrng = .init(0x5eed_f022 +% fuzz_calls);
    fuzz_calls += 1;
    var buf: [fuzz_max_len]u8 = undefined;
    for (0..fuzz_runs) |_| {
        const input = buf[0..prng.random().uintAtMost(usize, fuzz_max_len)];
        prng.random().bytes(input);
        try fuzzOne(context, testOne, input);
    }
}

fn fuzzOne(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *std.testing.Smith) anyerror!void,
    input: []const u8,
) anyerror!void {
    var smith: std.testing.Smith = .{ .in = input };
    testOne(context, &smith) catch |err| {
        std.debug.print("fuzz: input of {d} bytes failed with {t}: {x}\n", .{ input.len, err, input });
        return err;
    };
}

/// Runs this artifact's tests (`run`). Its own allocations are leak-checked:
/// a leak in the runner itself is `unreachable`.
pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) unreachable;

    var threaded: std.Io.Threaded = .init(gpa.allocator(), .{ .environ = init.environ });
    defer threaded.deinit();

    var args = try init.args.iterateAllocator(gpa.allocator());
    defer args.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const process_name = args.next() orelse unreachable;

    var io_buffer: [2048]u8 = undefined;
    var reporter: FileReporter = try .init(&threaded, std.Io.File.stdout(), &io_buffer);
    try run(&arena, threaded.io(), init.environ, process_name, &reporter);
}

/// Runs every test of `builtin.test_functions` in order and writes the report
/// to `reporter`. Exits the process with status 1 when a test failed or
/// leaked, and returns only when every test passed or was skipped. Results
/// and stack traces live in `arena`.
pub fn run(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    environ: std.process.Environ,
    process_name: []const u8,
    reporter: *FileReporter,
) !void {
    const tests: []const TestFn = builtin.test_functions;

    var report = Report{
        .process_name = process_name,
        .test_results = try arena.allocator().alloc(TestResult, tests.len),
    };

    try reporter.writeTitle(report.process_name, tests.len);
    try runTests(arena, io, environ, tests, &report);
    try writeTestResults(arena, reporter, report);
    try reporter.writeSummary(
        report.passed_count,
        report.failed_count,
        report.skipped_count,
        report.xfail_count,
        report.total_duration,
        report.is_mem_leak,
    );
    if (report.failed_count != 0 or report.is_mem_leak) std.process.exit(1);
}

fn runTests(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    environ: std.process.Environ,
    tests: []const TestFn,
    report: *Report,
) !void {
    if (tests.len == 0) return;

    const total_start = std.Io.Clock.Timestamp.now(io, .awake);
    for (tests, 0..) |test_fn, idx| {
        const t = Test.wrap(test_fn);

        // Run tests:
        report.test_results[idx] = try t.run(arena, io, environ);

        switch (report.test_results[idx]) {
            .passed => {
                report.passed_count += 1;
            },
            .failed => {
                report.failed_count += 1;
            },
            .skipped => {
                report.skipped_count += 1;
            },
            .xfailed => {
                report.xfail_count += 1;
            },
        }
        report.is_mem_leak = report.is_mem_leak or report.test_results[idx].isMemoryLeak();
    }
    const total_end = std.Io.Clock.Timestamp.now(io, .awake);
    report.total_duration = total_start.durationTo(total_end).raw;
}

fn writeTestResults(
    arena: *std.heap.ArenaAllocator,
    reporter: *FileReporter,
    report: Report,
) !void {
    const alloc = arena.allocator();
    var grouped_tests: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TestResult)) = .empty;
    for (report.test_results) |test_result| {
        const gop = try grouped_tests.getOrPut(alloc, test_result.@"test"().namespace);
        if (gop.found_existing) {
            try gop.value_ptr.append(alloc, test_result);
        } else {
            gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, test_result);
        }
    }

    var itr = grouped_tests.iterator();
    while (itr.next()) |group| {
        try reporter.writeNamespace(group.key_ptr.*);
        for (group.value_ptr.items) |test_result| {
            try reporter.writeTestName(test_result.@"test"().name);
            try reporter.writeTestResult(test_result);
        }
    }
}

/// One test and the namespace it was declared in.
const Test = struct {
    /// The part after `.test.`/`.decltest.`; borrows `test_fn.name`.
    name: []const u8 = undefined,
    /// The part before it, the namespace the report groups by.
    namespace: []const u8 = undefined,
    test_fn: TestFn,

    /// Splits `test_fn.name` at `.test.` or `.decltest.`; both halves borrow it.
    pub fn wrap(test_fn: TestFn) Test {
        var instance: Test = .{ .test_fn = test_fn };
        // Split a full name of a test in two parts:
        //  1. a namespace of the test;
        //  2. a name of the test.
        //
        // Possible templates of full test name are expected:
        //  - "<namespace>.test.<test name>"
        //  - "<namespace>.decltest.<test name>"
        const names = if (std.mem.indexOf(u8, test_fn.name, ".test.")) |idx|
            .{ test_fn.name[0..idx], test_fn.name[idx + 6 ..] }
        else if (std.mem.indexOf(u8, test_fn.name, ".decltest.")) |idx|
            .{ test_fn.name[0..idx], test_fn.name[idx + 10 ..] }
        else
            .{ "", test_fn.name };
        instance.namespace = names[0];
        instance.name = names[1];
        return instance;
    }

    /// Runs the test and returns its result; `error.SkipZigTest` reports as skipped.
    fn run(
        self: Test,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        environ: std.process.Environ,
    ) !TestResult {
        var test_result: TestResult = undefined;
        // As the stock 0.17 test runner sets it up.
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        std.testing.io_instance = .init(std.testing.allocator, .{ .environ = environ });

        const start = std.Io.Clock.Timestamp.now(io, .awake);
        // Try to run the test:
        const result = self.test_fn.func();
        const end = std.Io.Clock.Timestamp.now(io, .awake);
        const duration = start.durationTo(end).raw;

        // Cleanup
        std.testing.io_instance.deinit();
        const is_mem_leak: bool = std.testing.allocator_instance.deinit() != 0;

        const xfail = std.mem.startsWith(u8, self.name, xfail_prefix);
        if (result) |_| {
            test_result = if (xfail) .{ .failed = .{
                .@"test" = self,
                .duration = duration,
                .is_mem_leak = is_mem_leak,
                .err = error.XPass,
                .stack_trace = "  XPASS: marked xfail, and it passes. The gap is closed: drop the `xfail(...)` prefix.\n",
            } } else .{
                .passed = .{ .@"test" = self, .duration = duration, .is_mem_leak = is_mem_leak },
            };
        } else |err| switch (err) {
            error.SkipZigTest => {
                test_result = TestResult{ .skipped = self };
            },
            else => if (xfail) {
                test_result = .{ .xfailed = .{ .@"test" = self, .is_mem_leak = is_mem_leak } };
            } else {
                var str: []u8 = &.{};
                if (@errorReturnTrace()) |trace| {
                    var stack_trace_writer = std.Io.Writer.Allocating.init(arena.allocator());
                    try std.debug.writeErrorReturnTrace(
                        trace,
                        .{ .writer = &stack_trace_writer.writer, .mode = .no_color },
                    );
                    str = stack_trace_writer.written();
                }
                test_result = TestResult{
                    .failed = .{
                        .@"test" = self,
                        .duration = duration,
                        .is_mem_leak = is_mem_leak,
                        .err = err,
                        .stack_trace = str,
                    },
                };
            },
        }
        return test_result;
    }
};

/// The outcome of one test.
pub const TestResult = union(enum) {
    passed: struct { @"test": Test, duration: Duration, is_mem_leak: bool },
    failed: struct { @"test": Test, duration: Duration, err: anyerror, stack_trace: []const u8, is_mem_leak: bool },
    skipped: Test,
    /// An `xfail(...)` test that failed, as it says it does.
    xfailed: struct { @"test": Test, is_mem_leak: bool },

    /// The test this result is for, whatever its outcome.
    pub fn @"test"(self: TestResult) Test {
        return switch (self) {
            .passed => |result| result.@"test",
            .failed => |result| result.@"test",
            .skipped => |t| t,
            .xfailed => |result| result.@"test",
        };
    }

    /// Whether `std.testing.allocator` reported a leak; a skipped test never does.
    pub fn isMemoryLeak(self: TestResult) bool {
        return switch (self) {
            .passed => |result| result.is_mem_leak,
            .failed => |result| result.is_mem_leak,
            .skipped => false,
            .xfailed => |result| result.is_mem_leak,
        };
    }
};

/// The outcome of every test in one artifact.
const Report = struct {
    process_name: []const u8,
    test_results: []TestResult,
    // `u16`: counts per artifact; one module already has more than 255 tests.
    passed_count: u16 = 0,
    failed_count: u16 = 0,
    skipped_count: u16 = 0,
    xfail_count: u16 = 0,
    total_duration: Duration = .zero,
    is_mem_leak: bool = false,
};

const Duration = std.Io.Duration;

/// Writes the test report to a file, optionally coloured.
const FileReporter = struct {
    const Color = std.Io.Terminal.Color;

    const colors = .{
        .title = Color.cyan,
        .process_name = Color.yellow,
        .no_tests = Color.dim,
        .namespace = Color.cyan,
        .test_name = Color.cyan,
        .summary = Color.cyan,
        .passed = Color.green,
        .failed = Color.red,
        .skipped = Color.yellow,
        .xfail = Color.yellow,
        .memory_leak = Color.magenta,
    };

    const border = &@as([65]u8, @splat('='));

    file_writer: std.Io.File.Writer,
    mode: std.Io.Terminal.Mode,

    /// Colour follows `NO_COLOR`, `CLICOLOR_FORCE` and whether `file` is a
    /// terminal. `buffer` must outlive the reporter.
    pub fn init(threaded: *std.Io.Threaded, file: std.Io.File, buffer: []u8) !FileReporter {
        const NO_COLOR = threaded.environ.exist.NO_COLOR;
        const CLICOLOR_FORCE = threaded.environ.exist.CLICOLOR_FORCE;
        const mode = try std.Io.Terminal.Mode.detect(threaded.io(), file, NO_COLOR, CLICOLOR_FORCE);
        return .{ .file_writer = file.writer(threaded.io(), buffer), .mode = mode };
    }

    fn terminal(self: *FileReporter) std.Io.Terminal {
        return .{ .writer = &self.file_writer.interface, .mode = self.mode };
    }

    /// Writes the banner and flushes, so it prints before any test's own output.
    pub fn writeTitle(
        self: *FileReporter,
        process_name: []const u8,
        tests_count: usize,
    ) anyerror!void {
        // move to the next line and cleanup output settings:
        _ = try self.file_writer.interface.write("\r\n\x1b[0K");
        try self.colorizeLine(colors.title, "{s}", .{border});

        if (tests_count == 0) {
            try self.colorizeLine(colors.no_tests, "No one test was found in {s}", .{process_name});
            return;
        }
        try self.colorize(colors.title, "Run ", .{});
        try self.colorizeLine(colors.process_name, "{s}", .{process_name});
        // to print the title before any output from tests
        try self.file_writer.interface.flush();
    }

    /// One line naming the group the next tests belong to.
    pub fn writeNamespace(self: *FileReporter, namespace: []const u8) anyerror!void {
        try self.colorizeLine(colors.namespace, "{s}", .{namespace});
    }

    /// ` - <name> `, the line `writeTestResult` finishes.
    pub fn writeTestName(self: *FileReporter, test_name: []const u8) anyerror!void {
        try self.colorize(colors.test_name, " - {s} ", .{test_name});
    }

    /// Finishes the line; a failure appends its error-return trace.
    pub fn writeTestResult(self: *FileReporter, test_result: TestResult) anyerror!void {
        switch (test_result) {
            .passed => |result| {
                try self.colorize(
                    colors.passed,
                    " PASSED in {f}",
                    .{result.duration},
                );
            },
            .failed => |result| {
                try self.colorize(
                    colors.failed,
                    " FAILED in {f}: {s}",
                    .{ result.duration, @errorName(result.err) },
                );
            },
            .skipped => {
                try self.colorize(colors.skipped, " SKIPPED", .{});
            },
            .xfailed => {
                try self.colorize(colors.xfail, " XFAIL", .{});
            },
        }
        if (test_result.isMemoryLeak()) {
            try self.colorizeLine(colors.memory_leak, " MEMORY LEAK", .{});
        } else {
            try self.file_writer.interface.writeByte('\n');
        }
        if (test_result == .failed) {
            try self.file_writer.interface.writeAll(test_result.failed.stack_trace);
        }
    }

    /// The totals line, then a flush. Prints nothing for an artifact with no tests.
    pub fn writeSummary(
        self: *FileReporter,
        passed: u16,
        failed: u16,
        skipped: u16,
        xfail: u16,
        total_duration: Duration,
        is_mem_leak: bool,
    ) anyerror!void {
        if (passed + skipped + failed + xfail == 0 and !is_mem_leak)
            return;

        try self.colorize(
            colors.summary,
            border ++ "\nTotal {d} tests were run in {f}: ",
            .{ passed + failed + skipped + xfail, total_duration },
        );
        if (passed > 0)
            try self.colorize(colors.passed, "{d} passed; ", .{passed});
        if (failed > 0)
            try self.colorize(colors.failed, "{d} failed; ", .{failed});
        if (skipped > 0)
            try self.colorize(colors.skipped, "{d} skipped;", .{skipped});
        if (xfail > 0)
            try self.colorize(colors.xfail, " {d} xfail;", .{xfail});
        if (is_mem_leak)
            try self.colorize(colors.memory_leak, " MEMORY LEAK", .{});

        // move to the next line and cleanup output settings:
        _ = try self.file_writer.interface.write("\r\n\x1b[0K");
        try self.file_writer.interface.flush();
    }

    fn colorizeLine(
        self: *FileReporter,
        color: Color,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.colorize(color, format, args);
        try self.file_writer.interface.writeByte('\n');
    }

    fn colorize(
        self: *FileReporter,
        color: Color,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        const t = self.terminal();
        try t.setColor(color);
        try self.file_writer.interface.print(format, args);
        try t.setColor(.reset);
    }
};
