//! Testbench build: device.zig and runner text in, one `zig build-exe` (or
//! `build-lib`) out, as the binary's path or the compiler's stderr.

const std = @import("std");
const builtin = @import("builtin");
const tb = @import("../tb.zig");
const orchestrator = @import("../orchestrator.zig");
const Io = tb.Io;
const Allocator = tb.Allocator;

/// How `buildExe` builds and where it writes.
pub const BuildOptions = struct {
    /// Scratch: `device.zig` and `tb.zig` are written here, and the binary
    /// lands here too unless `out_path` says otherwise.
    work_dir: []const u8,
    /// Root of the `contract` module the generated device imports.
    contract: []const u8,
    /// Artifact name: the module name, so the binary is `./<module>`.
    name: []const u8,
    out_path: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    /// `-O` for the testbench. Debug by default: see `buildExe`.
    optimize: std.builtin.OptimizeMode = .Debug,
    /// Null is `Backend.auto(optimize, <this host>)`.
    backend: ?orchestrator.Backend = null,
    /// The runner is `renderMixed`'s: it imports `sim` and `diag`, compiled
    /// from the VerA tree `contract` sits in (`<root>/tools/contract.zig`).
    mixed: bool = false,
    /// Build `renderVpiLib`'s runner as a shared library for a Clause 12
    /// analog host to load, instead of an executable.
    shared_lib: bool = false,
};

/// Outcome of `buildExe`. Either payload is owned by the `gpa` passed to
/// `buildExe`; release it with `deinit`.
pub const BuildResult = union(enum) {
    /// Path of the built binary.
    ok: []const u8,
    /// `zig`'s stderr, verbatim. Generated code that does not compile is an
    /// engine bug, and this is the report.
    failed: []const u8,

    /// Frees the payload; `gpa` must be the allocator `buildExe` was given.
    pub fn deinit(self: BuildResult, gpa: Allocator) void {
        switch (self) {
            .ok, .failed => |p| gpa.free(p),
        }
    }
};

/// Builds device.zig and the runner into one native binary under
/// `opts.work_dir`. A null `device_zig` builds `runner_zig` alone over `sim`
/// and `diag` (an IEEE 1364 design); `opts.mixed` must then be set.
/// Spawns `opts.zig_exe` and blocks until it exits.
///
/// Calls `build-exe` directly: orchestrator.zig's `.so` path serves hot
/// reload, which a build-once testbench does not need. Debug is the default
/// because compile time dominates and safety checks turn a codegen bug into a
/// trap instead of a plausible wrong number.
pub fn buildExe(
    gpa: Allocator,
    io: Io,
    device_zig: ?[]const u8,
    runner_zig: []const u8,
    opts: BuildOptions,
) !BuildResult {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.work_dir);
    var dir = try cwd.openDir(io, opts.work_dir, .{});
    defer dir.close(io);

    // Every argv string lives for this call only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin = if (opts.out_path) |p|
        try gpa.dupe(u8, p)
    else
        try std.fs.path.join(gpa, &.{ opts.work_dir, opts.name });
    errdefer gpa.free(bin);

    std.debug.assert(device_zig != null or opts.mixed);
    const m_root = try bind(arena, io, dir, opts, "tb", "root", runner_zig);

    // `--dep` binds to the NEXT `-M`, and the FIRST `-M` is the root module.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        opts.zig_exe,
        if (opts.shared_lib) "build-lib" else "build-exe",
        try std.fmt.allocPrint(arena, "-femit-bin={s}", .{bin}),
        try std.fmt.allocPrint(arena, "-O{t}", .{opts.optimize}),
        "--cache-dir",
        ".zig-cache",
    });
    try argv.appendSlice(arena, switch (opts.backend orelse orchestrator.Backend.auto(opts.optimize, builtin.cpu.arch)) {
        .self_hosted => &.{ "-fno-llvm", "-fno-lld" },
        .llvm => &.{"-fllvm"},
    });
    // No debug info where there are no safety checks to trace: emitting it
    // is most of an unsafe build's LLVM time.
    if (opts.optimize == .ReleaseFast or opts.optimize == .ReleaseSmall) try argv.append(arena, "-fstrip");
    if (opts.shared_lib) try argv.append(arena, "-dynamic");
    if (device_zig != null) try argv.appendSlice(arena, &.{ "--dep", "device" });
    if (opts.mixed) try argv.appendSlice(arena, &.{ "--dep", "sim", "--dep", "diag" });
    if (device_zig) |text| {
        try argv.appendSlice(arena, &.{ "--dep", "contract", m_root });
        try argv.appendSlice(arena, &.{ "--dep", "contract", try bind(arena, io, dir, opts, "device", "device", text) });
    } else try argv.append(arena, m_root);
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

/// Writes one module's source to `<name>.<suffix>.zig` in `dir` and returns
/// the `-M<binding>=<path>` flag, allocated in `arena`. The name-qualified file
/// keeps two artifacts sharing a work root from overwriting each other.
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
