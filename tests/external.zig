//! The FOREIGN compiler, plugged into the same harness — anything that takes a
//! `.va` path and exits nonzero when it refuses one.
//!
//! NOT AN ENTRY POINT. `tests/bench.zig` owns `main` and the only step; this
//! file is a value it imports, reached by `zig build benchmark --
//! --against-openvaf` and pointed at the compiler named by `cc` below.
//!
//! It answers ONE question: does the compiler accept what the LRM says must
//! compile and refuse what the LRM says must not? That is all of a fixture that
//! travels. The `ok=` columns do not — they need a host that stamps the device
//! and runs it, which only works for VerA — so this plug declares `runs =
//! false`, the harness stops asking, and the report prints those columns in a
//! section marked VerA-only rather than as a score this compiler lost.
//!
//! ACCEPT/REJECT IS A WEAKER TEST THAN THE `//! reject` LINES ASK FOR, on
//! purpose. A reject directive names a substring of VerA's diagnostic, often a
//! code like `E0313`; no other compiler will ever print that, and demanding it
//! would score every foreign compiler zero for a reason that says nothing about
//! conformance. So here a `//! reject` fixture passes if the compiler refused it
//! AT ALL. The claim it makes is the LRM's — "§5.8 says this must not compile" —
//! and it is the same claim VerA is held to, minus the wording.
//!
//! IT IS NOT THE FIXTURE'S FAULT THAT ANOTHER COMPILER NEEDS A PRELUDE. VerA
//! knows the Annex D disciplines and constants without being told; OpenVAF (and
//! the LRM, strictly) wants them included. Rather than edit 1102 fixtures for
//! one consumer, each is compiled through a generated wrapper:
//!
//!     `include "disciplines.vams"
//!     `include "constants.vams"
//!     `include "<the fixture, by absolute path>"
//!
//! which leaves the fixture bytes untouched and keeps its own line numbers in
//! the compiler's diagnostics. The two prelude lines are dropped for a fixture
//! that declares its OWN natures or disciplines — those would collide with
//! Annex D's, and reporting the collision as non-conformance would be a lie
//! about the fixture. The wrapper itself is never dropped: a compiler that
//! emits an object writes it beside its input, and that must not be
//! `tests/fixtures`.
//!
//! A HANGING COMPILER IS NOT THIS FILE'S PROBLEM, deliberately: `cc` is a whole
//! command line, so `"timeout 30 openvaf-r --dry-run"` is the answer, and there
//! is no timeout knob here to keep in step with it.

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("suite_options");

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

/// The Verilog-A compiler `benchmark -- --against-openvaf` runs beside VerA.
///
/// A CONSTANT and not a build option: it was `-Dopenvaf`, which meant a string
/// plumbed from `build.zig` through the options module to be read in two files,
/// for a value that changes when someone is benchmarking against a different
/// compiler — one edit, right here. A whole command line, so a wrapper (`nice`,
/// `timeout`) goes in front of it.
pub const cc = "openvaf-r --dry-run";

/// The compiler's command line, plus the out-parameters of the LAST `check`.
///
/// The head-to-head table wants two facts the `Result` vocabulary cannot carry
/// — did it CRASH, and how many bytes did it emit — and inventing two more
/// `Result` variants for them would push a foreign compiler's implementation
/// detail into the verdict algebra both compilers are judged by. So they come
/// back here instead, read by `tests/bench.zig` immediately after the `judge`
/// call that filled them. Single-threaded by construction: the head-to-head
/// pass is sequential, because a wall clock measured against a loaded machine
/// is not a measurement.
pub const Ctx = struct {
    argv: []const []const u8,
    crashed: bool = false,
    /// Bytes the compiler left in the fixture's scratch directory, or null if
    /// it wrote nothing there. `--dry-run` always writes nothing, by design.
    artifact: ?u64 = null,
};

pub fn compiler(ctx: *Ctx) harness.Compiler {
    return .{
        // The command AS WRITTEN, not `argv[0]`: with `cc = "timeout 30
        // openvaf-r --dry-run"` the first word is `timeout`, and a report
        // headed `timeout: 779/1150` names the wrong program.
        .name = cc,
        .runs = false,
        // `//! xfail` is VerA's debt, and honouring it here would excuse this
        // compiler for VerA's gaps and FAIL it for closing them.
        .owns_xfail = false,
        .ctx = ctx,
        .check = check,
    };
}

/// What one foreign compilation did, in the terms the report has columns for.
pub const Outcome = struct {
    accepted: bool,
    /// It died instead of answering — see `died`.
    crashed: bool,
    how: []const u8 = "",
    /// Everything it said on either stream, arena-owned.
    said: []const u8 = "",
};

/// The scratch directory and the wrapper path for one fixture.
///
/// Split out of `compileOnce` so that the `mkdir` and the wrapper write happen
/// ONCE and OUTSIDE the timing loop: they are the harness's cost, and charging
/// a foreign compiler for a file this suite wrote would be a thumb on the scale
/// in the published direction.
pub const Job = struct { work: []const u8, root: []const u8 };

pub fn prepare(io: Io, arena: std.mem.Allocator, f: Fixture, source: []const u8) !Job {
    const work = try std.fs.path.join(arena, &.{ options.work_root, "openvaf", f.slug });
    return .{ .work = work, .root = try wrap(io, arena, work, f, source) };
}

/// ONE compilation: spawn the compiler on the wrapped fixture and read the
/// verdict off its exit status. Shared by `check` — which turns it into the
/// harness's `Result` — and by the head-to-head's timing loop, so the thing
/// being timed is the thing being scored and not a second spelling of it.
pub fn compileOnce(
    io: Io,
    arena: std.mem.Allocator,
    argv_prefix: []const []const u8,
    f: Fixture,
    job: Job,
) !Outcome {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, argv_prefix);
    // Both dirs, so `check.vh` resolves whether the compiler looks beside
    // the wrapper or beside the fixture.
    try argv.appendSlice(arena, &.{ "-I", f.root, "-I", f.dir, job.root });

    // stdout and stderr share one report buffer; a foreign compiler may use either.
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var aw: Io.Writer.Allocating = .init(arena);
    var obuf: [1 << 16]u8 = undefined;
    var ebuf: [1 << 16]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &obuf);
    _ = out.interface.streamRemaining(&aw.writer) catch {};
    var err = child.stderr.?.readerStreaming(io, &ebuf);
    _ = err.interface.streamRemaining(&aw.writer) catch {};
    const term = try child.wait(io);

    const how_buf = try arena.alloc(u8, 64);
    if (died(term, how_buf)) |how| return .{
        .accepted = false,
        .crashed = true,
        .how = how,
        .said = aw.written(),
    };
    return .{
        .accepted = switch (term) {
            .exited => |c| c == 0,
            else => false,
        },
        .crashed = false,
        .said = aw.written(),
    };
}

fn check(
    ctx: *anyopaque,
    _: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    f: Fixture,
    source: []const u8,
    d: vera.tb.Directives,
    w: *Io.Writer,
) anyerror!Result {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    const job = try prepare(io, arena, f, source);
    const r = try compileOnce(io, arena, c.argv, f, job);
    c.crashed = r.crashed;
    // Sized HERE and not inside `compileOnce`: a `stat` per file is the
    // harness's cost, and the head-to-head calls `compileOnce` under a clock.
    c.artifact = if (r.crashed) null else emitted(io, job.work);

    // A CRASH IS NOT A DIAGNOSTIC. It exits nonzero like a refusal does, so
    // without this a compiler that segfaults on a `//! reject` fixture scores
    // a pass for it — the one way this runner could report a defect as
    // conformance. Reported unmet in both directions, because "it must not
    // compile" is a claim about the compiler saying so, not about it dying.
    if (r.crashed) {
        try w.print(
            "FAIL {s}: {s} did not survive the file — {s}.\n{s}\n",
            .{ f.path, cc, r.how, r.said },
        );
        return .unmet;
    }

    const must_reject = d.reject.len != 0;
    if (r.accepted == !must_reject) return .met;

    if (must_reject) {
        try w.print(
            "FAIL {s}: the LRM says this must not compile, and {s} accepted it.\n",
            .{ f.path, cc },
        );
        for (d.reject) |pattern| try w.print("  expected a diagnostic like: \"{s}\"\n", .{pattern});
    } else {
        try w.print("FAIL {s}: must compile, and {s} refused it:\n", .{ f.path, cc });
        try w.print("{s}\n", .{r.said});
    }
    return .unmet;
}

/// Write the wrapper and return its path. The Annex D prelude is skipped for a
/// fixture that declares its OWN natures or disciplines, but the WRAPPER is not:
/// a compiler that emits an object writes it beside its input, and pointing it
/// at the fixture itself would leave build artifacts inside `tests/fixtures`.
fn wrap(
    io: Io,
    arena: std.mem.Allocator,
    work: []const u8,
    f: Fixture,
    source: []const u8,
) ![]const u8 {
    // A fixture that defines a nature or a discipline IS the Annex D
    // material; including Annex D on top of it is a redefinition, and the
    // error would be the harness's, not the compiler's.
    const collides = std.mem.indexOf(u8, source, "\nnature ") != null or
        std.mem.indexOf(u8, source, "\ndiscipline ") != null or
        std.mem.startsWith(u8, source, "nature ") or
        std.mem.startsWith(u8, source, "discipline ");

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, work);
    // `f.path` is absolute — `tests/bench.zig` resolves the fixture root before
    // the walk — and it has to be, because the include is resolved relative to
    // the WRAPPER, which lives in the scratch tree and not beside the fixture.
    const wrapper = try std.fs.path.join(arena, &.{ work, "wrapped.va" });
    try cwd.writeFile(io, .{
        .sub_path = wrapper,
        .data = try std.fmt.allocPrint(arena, "{s}`include \"{s}\"\n", .{
            if (collides) "" else "`include \"disciplines.vams\"\n`include \"constants.vams\"\n",
            f.path,
        }),
    });
    return wrapper;
}

/// Bytes the compiler left in `work` besides the wrapper — its emitted
/// artifact, when it emits one. Null rather than 0 for "it wrote nothing",
/// because those are different facts and only the first means the artifact
/// column has no number to print.
fn emitted(io: Io, work: []const u8) ?u64 {
    var dir = Io.Dir.cwd().openDir(io, work, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var total: u64 = 0;
    var any = false;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (std.mem.eql(u8, e.name, "wrapped.va")) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        total += st.size;
        any = true;
    }
    return if (any) total else null;
}

/// Did the compiler die instead of answering?
///
/// A signal is unambiguous. An exit STATUS has to be guessed at, because the
/// crash usually reaches us through `timeout`, which reports its child's death
/// as `128 + signal` and its own patience running out as `124` — so those are
/// the codes read as death here. The ceiling is that a compiler which
/// deliberately exits 124+ to mean "rejected" would be misread; none does, and
/// the alternative is to trust an exit code that a segfault also produces.
fn died(term: std.process.Child.Term, buf: []u8) ?[]const u8 {
    return switch (term) {
        .exited => |c| if (c == 124)
            std.fmt.bufPrint(buf, "timed out", .{}) catch "timed out"
        else if (c >= 128)
            std.fmt.bufPrint(buf, "exit status {d}, i.e. signal {d}", .{ c, c - 128 }) catch "killed"
        else
            null,
        .signal => |s| std.fmt.bufPrint(buf, "signal {d}", .{s}) catch "killed",
        else => std.fmt.bufPrint(buf, "{t}", .{term}) catch "killed",
    };
}

/// `"timeout 20 openvaf-r --dry-run"` → argv. Whitespace only; a compiler path
/// with a space in it is the one case this does not cover, and has not come up.
pub fn splitCommand(arena: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |word| try list.append(arena, word);
    if (list.items.len == 0) return error.EmptyCompilerCommand;
    return list.items;
}

test "a command line is an argv" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const argv = try splitCommand(arena_state.allocator(), "  openvaf-r   --dry-run ");
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("openvaf-r", argv[0]);
    try std.testing.expectEqualStrings("--dry-run", argv[1]);
    try std.testing.expectError(error.EmptyCompilerCommand, splitCommand(arena_state.allocator(), "   "));
}
