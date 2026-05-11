//! A foreign Verilog-A compiler as a harness `Compiler`, for `zig build
//! benchmark -- --against-openvaf`: fixture -> accepted or refused.
//!
//! Only accept/refuse travels between compilers: `ok=` columns need VerA's host
//! (`runs = false`), and a `//! reject` fixture passes on any refusal, since no
//! other compiler prints VerA's codes. `tests/bench.zig` owns `main`.

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("suite_options");

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

/// The command line `benchmark -- --against-openvaf` runs beside VerA. A whole
/// command line, so a wrapper (`nice`, `timeout 30`) goes in front; this file
/// has no timeout of its own.
pub const cc = "openvaf-r --dry-run";

/// Out-parameters of the LAST `check`: facts the head-to-head table wants that
/// `Result` does not carry (a crash, the artifact size). Read by
/// `tests/bench.zig` right after the `judge` call that filled them; not
/// thread-safe, and the head-to-head pass is sequential.
pub const Ctx = struct {
    argv: []const []const u8,
    crashed: bool = false,
    /// Bytes the compiler left in the fixture's scratch directory, or null if
    /// it wrote nothing there. `--dry-run` always writes nothing, by design.
    artifact: ?u64 = null,
};

/// Returns the harness plug for `cc`; each `check` overwrites `ctx`.
pub fn compiler(ctx: *Ctx) harness.Compiler {
    return .{
        // The command as written, not `argv[0]`, which may be `timeout`.
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

/// The scratch directory and the wrapper path for one fixture. Made once by
/// `prepare`, outside the head-to-head timing loop, so the harness's file
/// writes are not charged to the foreign compiler.
pub const Job = struct { work: []const u8, root: []const u8 };

/// Creates the fixture's scratch directory under the work root and writes its
/// wrapper there (see `wrap`). Paths are `arena`-owned.
pub fn prepare(io: Io, arena: std.mem.Allocator, f: Fixture, source: []const u8) !Job {
    const work = try std.fs.path.join(arena, &.{ options.work_root, "openvaf", f.slug });
    return .{ .work = work, .root = try wrap(io, arena, work, f, source) };
}

/// Spawns the compiler once on the wrapped fixture and reads the verdict off
/// its exit status. Both `check` and the head-to-head timing loop call it, so
/// the thing timed is the thing scored.
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

    // A crash is not a refusal: it exits nonzero too, and would otherwise pass
    // a `//! reject` fixture. Reported unmet in both directions.
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

/// Writes the wrapper and returns its path: the Annex D prelude
/// (`disciplines.vams`, `constants.vams`), which VerA knows unasked and other
/// compilers need included, then an `include of the fixture by absolute path,
/// keeping the fixture's bytes and line numbers. The prelude is skipped for a
/// fixture that declares its own natures or disciplines. The wrapper itself is
/// always used, so an emitted object lands in scratch, not `tests/fixtures`.
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

/// Splits `"timeout 20 openvaf-r --dry-run"` into argv on whitespace; a path
/// containing a space is not supported. The list is `arena`-owned and its
/// words borrow `cmd`; a blank command is `EmptyCompilerCommand`.
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
