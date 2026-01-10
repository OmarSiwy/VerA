//! The conformance runner for a FOREIGN compiler — anything that takes a `.va`
//! path and exits nonzero when it refuses one.
//!
//!   zig build conformance                       # OpenVAF, every fixture
//!   zig build conformance -- ch04               # only paths matching `ch04`
//!   zig build -Dconformance-cc="vlog-a -c" conformance   # any other compiler
//!
//! It answers ONE question: does the compiler accept what the LRM says must
//! compile and refuse what the LRM says must not? That is all of a fixture that
//! travels. The `ok=` columns do not — they need a host that stamps the device
//! and runs it, which is `zig build torture` and only works for VerA — so this
//! runner declares `runs = false` and the harness stops asking.
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
//! which leaves the fixture bytes untouched, keeps its own line numbers in the
//! compiler's diagnostics, and is skipped entirely for a fixture that declares
//! its OWN natures or disciplines — those would collide with Annex D's, and
//! reporting the collision as non-conformance would be a lie about the fixture.
//!
//! A HANGING COMPILER IS NOT THIS FILE'S PROBLEM, deliberately:
//! `-Dconformance-cc` is a whole command line, so `-Dconformance-cc="timeout 30
//! openvaf-r --dry-run"` is the answer, and there is no timeout knob here to
//! keep in step with it.

const std = @import("std");
const vera = @import("vera");
const harness = @import("harness.zig");
const options = @import("external_options");
/// The two directories the SUITE owns, shared with `harness.zig` and the other
/// runner: which fixtures to walk, and which LRM their `//! lrm` lines cite.
const suite = @import("suite_options");

const Io = std.Io;
const Fixture = harness.Fixture;
const Result = harness.Result;

pub fn main(init: std.process.Init) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();

    var cc: External = .{
        .argv = try splitCommand(arena_state.allocator(), options.cc),
    };
    return harness.run(init, .{
        // The command AS WRITTEN, not `argv[0]`: with `-Dconformance-cc="timeout
        // 30 openvaf-r --dry-run"` the first word is `timeout`, and a report
        // headed `timeout: 779/1150` names the wrong program.
        .name = options.cc,
        .runs = false,
        // `//! xfail` is VerA's debt, and honouring it here would excuse this
        // compiler for VerA's gaps and FAIL it for closing them.
        .owns_xfail = false,
        .ctx = &cc,
        .check = External.check,
    });
}

const External = struct {
    /// The compiler and its fixed flags; the fixture path is appended.
    ///
    /// Set once, from `-Dconformance-cc`, and NOT also from a run-time flag:
    /// the compiler's name goes into the report header, which is built before
    /// the arguments are walked, so a late `--cc=` would relabel nothing.
    argv: []const []const u8,

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
        const self: *External = @ptrCast(@alignCast(ctx));
        const root = try self.wrap(io, arena, f, source);

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, self.argv);
        // Both dirs, so `check.vh` resolves whether the compiler looks beside
        // the wrapper or beside the fixture.
        try argv.appendSlice(arena, &.{ "-I", suite.fixture_root, "-I", f.dir, root });

        const run = try capture(gpa, io, argv.items);
        defer gpa.free(run.output);
        defer gpa.free(run.how);

        const must_reject = d.reject.len != 0;
        // A CRASH IS NOT A DIAGNOSTIC. It exits nonzero like a refusal does, so
        // without this a compiler that segfaults on a `//! reject` fixture scores
        // a pass for it — the one way this runner could report a defect as
        // conformance. Reported unmet in both directions, because "it must not
        // compile" is a claim about the compiler saying so, not about it dying.
        if (run.crashed) {
            try w.print(
                "FAIL {s}: {s} did not survive the file — {s}.\n{s}\n",
                .{ f.path, options.cc, run.how, run.output },
            );
            return .unmet;
        }
        if (run.accepted == !must_reject) return .met;

        if (must_reject) {
            try w.print(
                "FAIL {s}: the LRM says this must not compile, and {s} accepted it.\n",
                .{ f.path, options.cc },
            );
            for (d.reject) |pattern| try w.print("  expected a diagnostic like: \"{s}\"\n", .{pattern});
        } else {
            try w.print("FAIL {s}: must compile, and {s} refused it:\n", .{ f.path, options.cc });
            try w.print("{s}\n", .{run.output});
        }
        return .unmet;
    }

    /// Write the prelude wrapper and return its path — or the fixture's own path
    /// when a prelude would collide with what the fixture declares itself.
    fn wrap(
        self: *External,
        io: Io,
        arena: std.mem.Allocator,
        f: Fixture,
        source: []const u8,
    ) ![]const u8 {
        _ = self;
        // A fixture that defines a nature or a discipline IS the Annex D
        // material; including Annex D on top of it is a redefinition, and the
        // error would be the harness's, not the compiler's.
        if (std.mem.indexOf(u8, source, "\nnature ") != null or
            std.mem.indexOf(u8, source, "\ndiscipline ") != null or
            std.mem.startsWith(u8, source, "nature ") or
            std.mem.startsWith(u8, source, "discipline ")) return f.path;

        const work = try std.fs.path.join(arena, &.{ options.work_root, f.slug });
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, work);
        // `f.path` is already absolute — both roots come from `b.pathFromRoot`
        // — and it has to be, because the include is resolved relative to the
        // WRAPPER, which lives in the scratch tree and not beside the fixture.
        const wrapper = try std.fs.path.join(arena, &.{ work, "wrapped.va" });
        try cwd.writeFile(io, .{
            .sub_path = wrapper,
            .data = try std.fmt.allocPrint(arena,
                \\`include "disciplines.vams"
                \\`include "constants.vams"
                \\`include "{s}"
                \\
            , .{f.path}),
        });
        return wrapper;
    }
};

const Run = struct {
    accepted: bool,
    /// Died rather than answered: a signal, or the exit status `timeout` uses to
    /// report one. See `died`.
    crashed: bool,
    /// `signal 11`, `status 139` — the short form, for the report.
    how: []const u8,
    output: []const u8,
};

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

/// Everything the compiler said, and whether it took the file. stdout and stderr
/// are both piped because a foreign compiler may use either; they are read into
/// one buffer since only a human reads the result.
fn capture(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !Run {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &text);
    var obuf: [1 << 16]u8 = undefined;
    var ebuf: [1 << 16]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &obuf);
    _ = out.interface.streamRemaining(&aw.writer) catch {};
    var err = child.stderr.?.readerStreaming(io, &ebuf);
    _ = err.interface.streamRemaining(&aw.writer) catch {};
    text = aw.toArrayList();

    const term = try child.wait(io);
    var how_buf: [64]u8 = undefined;
    const how = died(term, &how_buf);
    return .{
        .accepted = switch (term) {
            .exited => |c| c == 0,
            else => false,
        },
        .crashed = how != null,
        // The buffer is this frame's, so the caller gets a copy. It is one short
        // line and only on the path where something already went wrong.
        .how = try gpa.dupe(u8, how orelse ""),
        .output = try text.toOwnedSlice(gpa),
    };
}

/// `"timeout 20 openvaf-r --dry-run"` → argv. Whitespace only; a compiler path
/// with a space in it is the one case this does not cover, and has not come up.
fn splitCommand(arena: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
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
