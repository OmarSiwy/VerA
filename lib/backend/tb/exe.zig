//! Building the executable: device.zig + runner into one `zig build-exe`.
//!
//! In: the device and runner text. Out: a path to the built testbench, or the compiler's error.
//!
//! Cut verbatim from `tb.zig`.

const std = @import("std");
const tb = @import("../tb.zig");
const Io = tb.Io;
const Allocator = tb.Allocator;

// ---------------------------------------------------------------------------
// Building the executable
// ---------------------------------------------------------------------------

pub const BuildOptions = struct {
    /// Scratch: `device.zig` and `tb.zig` are written here, and the binary
    /// lands here too unless `out_path` says otherwise.
    work_dir: []const u8,
    /// Root of the `contract` module the generated device imports.
    contract: []const u8,
    /// Artifact name — the module name, so the binary is `./<module>`.
    name: []const u8,
    out_path: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    /// `-O` for the testbench. Debug by default; see `buildExe` for why that is
    /// not the timid choice.
    optimize: std.builtin.OptimizeMode = .Debug,
    /// The runner is `renderMixed`'s: it imports the digital engine (`sim`) and
    /// `diag`, which are compiled from the VerA source tree the contract sits
    /// in (`<root>/tools/contract.zig`). Only mixed-signal testbenches pay the
    /// extra build; every other one is byte-for-byte the build it always was.
    mixed: bool = false,
};

pub const BuildResult = union(enum) {
    /// Path of the built binary (borrowed from the caller's allocator).
    ok: []const u8,
    /// `zig`'s stderr, verbatim. Generated code that does not compile is an
    /// ENGINE bug, and the only useful report is what the compiler said.
    failed: []const u8,

    pub fn deinit(self: BuildResult, gpa: Allocator) void {
        switch (self) {
            .ok, .failed => |p| gpa.free(p),
        }
    }
};

/// device.zig + runner.zig → one native binary.
///
/// `build-exe` directly rather than through orchestrator.zig: that path exists
/// to produce a hot-reloadable `.so` with a generation counter and an incremental
/// resident compiler, and none of that applies to a testbench that is built once
/// and run once.
///
/// `opts.optimize` defaults to Debug, and NOT because floats would move: Zig has
/// no `-ffast-math`, so float arithmetic is strict IEEE in every optimize mode
/// unless the code itself asks for `@setFloatMode(.optimized)`, which generated
/// devices do not. The two real reasons are that a testbench runs for
/// microseconds and compiles for seconds — so compile time is the whole cost —
/// and that Debug keeps the safety checks on, which turns a codegen bug into a
/// loud trap instead of a plausible wrong number.
pub fn buildExe(
    gpa: Allocator,
    io: Io,
    device_zig: []const u8,
    runner_zig: []const u8,
    opts: BuildOptions,
) !BuildResult {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.work_dir);
    var dir = try cwd.openDir(io, opts.work_dir, .{});
    defer dir.close(io);

    // One arena for the command line. Every element of it is a `-M`, a `-O` or
    // a path join whose lifetime is this call, so a matching `defer free` per
    // string buys nothing over freeing the lot at once.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin = if (opts.out_path) |p|
        try gpa.dupe(u8, p)
    else
        try std.fs.path.join(gpa, &.{ opts.work_dir, opts.name });
    errdefer gpa.free(bin);

    const m_root = try bind(arena, io, dir, opts, "tb", "root", runner_zig);
    const m_dev = try bind(arena, io, dir, opts, "device", "device", device_zig);

    // `--dep` binds to the NEXT `-M`, and the FIRST `-M` is the root module.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        opts.zig_exe,
        "build-exe",
        try std.fmt.allocPrint(arena, "-femit-bin={s}", .{bin}),
        try std.fmt.allocPrint(arena, "-O{t}", .{opts.optimize}),
        "--cache-dir",
        ".zig-cache",
    });
    try argv.appendSlice(arena, &.{ "--dep", "device" });
    if (opts.mixed) try argv.appendSlice(arena, &.{ "--dep", "sim", "--dep", "diag" });
    try argv.appendSlice(arena, &.{ "--dep", "contract", m_root });
    try argv.appendSlice(arena, &.{ "--dep", "contract", m_dev });
    try argv.append(arena, try std.fmt.allocPrint(arena, "-Mcontract={s}", .{opts.contract}));
    if (opts.mixed) {
        // build.zig's `module_specs` rows for these four, spelled for build-exe.
        const root = std.fs.path.dirname(std.fs.path.dirname(opts.contract) orelse ".") orelse ".";
        const src = struct {
            fn m(a: Allocator, r: []const u8, name: []const u8, rel: []const u8) ![]const u8 {
                return std.fmt.allocPrint(a, "-M{s}={s}", .{ name, try std.fs.path.join(a, &.{ r, rel }) });
            }
        };
        try argv.appendSlice(arena, &.{ "--dep", "contract", "--dep", "diag", "--dep", "frontend", "--dep", "kernels", try src.m(arena, root, "sim", "src/sim/root.zig") });
        try argv.append(arena, try src.m(arena, root, "diag", "lib/diag.zig"));
        try argv.appendSlice(arena, &.{ "--dep", "diag", try src.m(arena, root, "frontend", "lib/frontend/root.zig") });
        try argv.append(arena, try src.m(arena, root, "kernels", "lib/backend/kernels.zig"));
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
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

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (failed) {
        gpa.free(bin);
        return .{ .failed = try text.toOwnedSlice(gpa) };
    }
    text.deinit(gpa);
    return .{ .ok = bin };
}

/// Write one module's source into the work directory and return the `-M` that
/// binds it. The file is `<name>.<suffix>.zig` so two hosts sharing a work root
/// cannot overwrite each other's device.
pub fn bind(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    opts: BuildOptions,
    suffix: []const u8,
    binding: []const u8,
    text: []const u8,
) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.{s}.zig", .{ opts.name, suffix });
    try dir.writeFile(io, .{ .sub_path = file, .data = text });
    const path = try std.fs.path.join(arena, &.{ opts.work_dir, file });
    return std.fmt.allocPrint(arena, "-M{s}={s}", .{ binding, path });
}
