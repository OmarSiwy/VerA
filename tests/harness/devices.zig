//! The `devices` mode: `vera --run x.v` transcripts against committed goldens,
//! which need the `vera` binary and so cannot be `test` blocks.
//!
//!   zig build test-devices          # all of it
//!   zig build test-devices -- rng   # the cases whose name contains `rng`
//!
//! Cases come from `tests/fixtures/digital/` and `tests/fixtures/ieee1364/`,
//! sorted, so a FAIL name list diffs between two runs. `--native` hands the
//! same cases to `native.zig`, `--fuzz` goes to `fuzz.zig`, and `--coverage`
//! to `../ieee1364.zig`.

const std = @import("std");
const options = @import("suite_options");
const harness = @import("../harness.zig");
const bench = @import("../bench.zig");
const ieee1364 = @import("../ieee1364.zig");
const native = @import("native.zig");
const fuzz = @import("fuzz.zig");
const digital = @import("digital.zig");
const child = @import("child.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args.Iterator;

/// `vera --run <name>.v` must print `<name>.expected.txt` exactly. IEEE 1364
/// semantics, so `.v` and not `.va`: the shared frontend plus `sim/`, with no
/// analog path at all.
///
/// Walked recursively, not listed: `tests/fixtures/ieee1364/<NN_clause>/` (IEEE
/// 1364-2005, one directory per clause) and `tests/fixtures/digital/`
/// (digital-context Verilog-AMS rules such as wreal and the `--std` boundary).
///
/// A `.v` is a case when it has `.expected.txt` or `// digital-runner: reject`;
/// a support design with neither (a UDP library a fixture instantiates) is not.
pub const digital_dirs = [_][]const u8{ "digital", ieee1364_dir };
pub const ieee1364_dir = "ieee1364";

/// The `devices` and `ieee1364` modes over the cases under `dirs`: the
/// verdicts and a census on stderr, exit 1 on any FAIL or when nothing
/// matched. Changes this process's working directory to the suite's scratch
/// tree before any case runs.
pub fn run(init: std.process.Init, vera_exe: []const u8, args: *Args, dirs: []const []const u8) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var filter: ?[]const u8 = null;
    var native_flags: ?[]const []const u8 = null;
    var snapshot = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--coverage")) return ieee1364.coverage(init);
        if (std.mem.eql(u8, a, "--native") or std.mem.eql(u8, a, "--native=fifo")) {
            native_flags = &.{"--schedule=fifo"};
            continue;
        }
        if (std.mem.eql(u8, a, "--native=static")) {
            native_flags = &.{"--schedule=static"};
            continue;
        }
        if (std.mem.eql(u8, a, "--native=four")) {
            native_flags = &.{ "--schedule=fifo", "--state=4" };
            continue;
        }
        if (std.mem.eql(u8, a, "--native=two-state")) {
            native_flags = &.{"--two-state"};
            continue;
        }
        if (std.mem.eql(u8, a, "--native=snapshot") or std.mem.eql(u8, a, "--snapshot")) {
            snapshot = true;
            if (native_flags == null or a.len == "--native=snapshot".len) native_flags = &.{"--schedule=fifo"};
            continue;
        }
        if (std.mem.eql(u8, a, "--fuzz")) {
            const n = std.fmt.parseInt(u32, args.next() orelse "", 10) catch return bench.usage(init.io, "--fuzz takes a count");
            return fuzz.run(init, vera_exe, n);
        }
        filter = a;
    }

    var buf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};

    const cases = try digitalCases(gpa, io, dirs, native_flags != null);
    defer {
        for (cases) |c| gpa.free(c);
        gpa.free(cases);
    }
    // A case that writes a file (§17.2.1 `$fopen` for writing, §18's dump)
    // writes it relative to the working directory, which must not be the
    // repository: every case runs in the suite's scratch tree instead. The
    // fixture paths are absolute already; the executable is made so.
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, vera_exe, gpa);
    defer gpa.free(exe);
    const scratch = options.work_root ++ "/devices";
    try Io.Dir.cwd().createDirPath(io, scratch);
    var scratch_dir = try Io.Dir.cwd().openDir(io, scratch, .{});
    defer scratch_dir.close(io);
    try std.process.setCurrentDir(io, scratch_dir);

    if (native_flags) |flags| return native.run(gpa, io, exe, flags, snapshot, cases, filter, w);

    var ran: usize = 0;
    var failed: usize = 0;
    var xfailed: usize = 0;
    for (cases) |case| {
        if (filter) |f| if (std.mem.indexOf(u8, case, f) == null) continue;
        _ = arena_state.reset(.retain_capacity);
        ran += 1;
        switch (try digitalVerdict(arena_state.allocator(), io, exe, case, w)) {
            .pass => {},
            .fail => failed += 1,
            .xfail => xfailed += 1,
        }
    }
    if (ran == 0) {
        try w.print("devices: nothing matched `{s}`\n", .{filter orelse ""});
        return 1;
    }
    try w.print("devices: {d}/{d} cases behave as they say they do", .{ ran - failed - xfailed, ran });
    if (xfailed != 0) try w.print(", {d} XFAIL (a known gap, not a pass)", .{xfailed});
    try w.writeAll("\n");
    return if (failed == 0) 0 else 1;
}

/// A transcript that differs is reported as the whole of both sides: these are
/// tens of bytes, and "line 3 differs" sends the reader to the file anyway.
pub fn diff(w: *Io.Writer, what: []const u8, want: []const u8, got: []const u8) !bool {
    if (std.mem.eql(u8, want, got)) return true;
    try w.print("FAIL {s}: transcript differs\n  want: {f}\n  got:  {f}\n", .{
        what,
        std.ascii.hexEscape(want, .lower),
        std.ascii.hexEscape(got, .lower),
    });
    return false;
}

/// Digital transcript cases and explicitly opted-in diagnostic cases, sorted
/// so two runs report in the same order. Support files are not cases.
/// Case names are fixture-root-relative stems, `ieee1364/05_expressions/control`.
/// `vcd`: also the `//! expect vcd` fixtures, whose `--run` the .va suite
/// judges (`harness.judgeVcd`) and whose executable `--native` does.
fn digitalCases(gpa: Allocator, io: Io, dirs: []const []const u8, vcd: bool) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c);
        list.deinit(gpa);
    }
    for (dirs) |sub| {
        const root = try std.fs.path.join(gpa, &.{ options.fixture_root, sub });
        defer gpa.free(root);
        var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".v")) continue;
            const stem = entry.path[0 .. entry.path.len - ".v".len];
            const golden = try gpa.print("{s}.expected.txt", .{stem});
            defer gpa.free(golden);
            const has_golden = if (dir.access(io, golden, .{})) |_| true else |_| false;
            const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20));
            defer gpa.free(source);
            const dumps = vcd and !has_golden and digital.vcdExpectation(source) != null;
            if (!dumps and !digital.caseSelected(has_golden, source)) continue;
            try list.append(gpa, try gpa.print("{s}/{s}", .{ sub, stem }));
        }
    }
    std.mem.sort([]const u8, list.items, {}, harness.strLess);
    return list.toOwnedSlice(gpa);
}

/// `digitalCase` under `//! xfail`, with the .va suite's algebra
/// (`harness.judge`): an unmet xfail case is XFAIL and does not fail the run;
/// a met one is an XPASS FAIL, so a marker cannot outlive its limitation.
fn digitalVerdict(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !enum { pass, fail, xfail } {
    const src = try arena.print("{s}/{s}.v", .{ options.fixture_root, case });
    const xfail = digital.xfailReason(try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20))) orelse
        return if (try digitalCase(arena, io, vera_exe, case, w)) .pass else .fail;
    if (xfail.len == 0) {
        try w.print("FAIL {s}: `//! xfail` names no reason\n", .{case});
        return .fail;
    }
    var detail: Io.Writer.Allocating = .init(arena);
    if (try digitalCase(arena, io, vera_exe, case, &detail.writer)) {
        try w.print("FAIL {s}: XPASS — marked `//! xfail`, but VerA now does what the fixture says.\n" ++
            "  Delete the `//! xfail` line.\n", .{case});
        return .fail;
    }
    try w.print("XFAIL {s}: known: {s}\n", .{ case, xfail });
    return .xfail;
}

fn digitalCase(arena: Allocator, io: Io, vera_exe: []const u8, case: []const u8, w: *Io.Writer) !bool {
    const src = try arena.print("{s}/{s}.v", .{ options.fixture_root, case });
    const source = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{ vera_exe, "--run", src }, try digital.runnerArgs(arena, source, std.fs.path.dirname(src).?) });
    if (digital.negative(source)) {
        const golden = try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case });
        if (Io.Dir.cwd().access(io, golden, .{})) |_| {
            try w.print("FAIL {s}: digital reject also has a positive transcript\n", .{case});
            return false;
        } else |_| {}
        const r = try child.capture(arena, io, argv);
        if (!digital.rejectionMatches(source, r.exit, r.stderr)) {
            try w.print("FAIL {s}: digital rejection mismatch (exit {d})\n{s}\n", .{ case, r.exit, r.stderr });
            return false;
        }
        return true;
    }
    const want = try Io.Dir.cwd().readFileAlloc(
        io,
        try arena.print("{s}/{s}.expected.txt", .{ options.fixture_root, case }),
        arena,
        .limited(1 << 20),
    );
    const r = try child.capture(arena, io, argv);
    if (r.exit != 0) {
        try w.print("FAIL {s}: vera --run exited {d}\n{s}\n", .{ case, r.exit, r.stderr });
        return false;
    }
    if (!digital.warningsMatch(source, r.stderr)) {
        try w.print("FAIL {s}: successful digital run has missing warning evidence or error diagnostics\n{s}\n", .{ case, r.stderr });
        return false;
    }
    return diff(w, case, want, r.stdout);
}
