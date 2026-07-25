//! Testbench build: device.zig and runner text in, one `zig build-exe` (or
//! `build-lib`) out, as the binary's path or the compiler's stderr.

const std = @import("std");
const builtin = @import("builtin");
const orchestrator = @import("../orchestrator.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// How `buildExe` builds and where it writes.
pub const BuildOptions = struct {
    /// Scratch: `device.zig` and `tb.zig` are written here, and the binary
    /// lands here too unless `out_path` says otherwise.
    work_dir: []const u8,
    /// Root of the `contract` module the generated device imports.
    contract: []const u8,
    /// Artifact name: the module name, so the binary is `./<module>` plus the
    /// target's executable extension (`.exe` on Windows).
    name: []const u8,
    /// The binary's path instead of `<work_dir>/<name>`. Copied, never kept.
    out_path: ?[]const u8 = null,
    /// The compiler to spawn; looked up on `PATH` when bare.
    zig_exe: []const u8 = "zig",
    /// `-O` for the testbench. Debug by default: see `buildExe`.
    optimize: std.lang.Optimize = .debug,
    /// Null is `Backend.auto(optimize, <this host>)`.
    backend: ?orchestrator.Backend = null,
    /// The runner is `renderMixed`'s: it imports `sim` and `diag`, compiled
    /// from the VerA tree `contract` sits in (`<root>/tools/contract.zig`).
    mixed: bool = false,
    /// Build `renderVpiLib`'s runner as a shared library for a Clause 12
    /// analog host to load, instead of an executable.
    shared_lib: bool = false,
    /// Keep DWARF in a ReleaseFast/ReleaseSmall build (`orchestrator.strip`).
    debug_info: bool = false,
    /// Overrides `orchestrator.strip` when set. The fixture suite strips its
    /// Debug testbenches: DWARF is 7-26% of a testbench build's compiler
    /// work and the suite reads only the transcript. A safety panic
    /// still prints its message, without the stack trace; rebuild by hand
    /// with `vera --emit-exe` to get one.
    strip: ?bool = null,
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
    var dir = try openWorkDir(io, opts);
    defer dir.close(io);

    // Every argv string lives for this call only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bin = if (opts.out_path) |p| try gpa.dupe(u8, p) else try binPath(gpa, arena, opts);
    errdefer gpa.free(bin);

    std.debug.assert(device_zig != null or opts.mixed);
    const m_root = try bind(arena, io, dir, opts, "tb", "root", runner_zig);

    // `--dep` binds to the NEXT `-M`, and the FIRST `-M` is the root module.
    var argv = try argvHead(arena, opts, if (opts.shared_lib) "build-lib" else "build-exe", bin);
    if (opts.shared_lib) try argv.append(arena, "-dynamic");
    if (device_zig != null) try argv.appendSlice(arena, &.{ "--dep", "device" });
    if (opts.mixed) try argv.appendSlice(arena, &.{ "--dep", "sim", "--dep", "diag" });
    if (device_zig) |text| {
        try argv.appendSlice(arena, &.{ "--dep", "contract", m_root });
        // A `.v` device (`sim.digital.emitDevice`) runs on `sim`'s engine.
        if (opts.mixed) try argv.appendSlice(arena, &.{ "--dep", "sim" });
        try argv.appendSlice(arena, &.{ "--dep", "contract", try bind(arena, io, dir, opts, "device", "device", text) });
    } else try argv.append(arena, m_root);
    try argv.append(arena, try arena.print("-Mcontract={s}", .{opts.contract}));
    if (opts.mixed) {
        // build.zig's `module_specs` rows for these four, spelled for build-exe.
        const root = std.fs.path.dirname(std.fs.path.dirname(opts.contract) orelse ".") orelse ".";
        const src = struct {
            fn m(a: Allocator, r: []const u8, name: []const u8, rel: []const u8) ![]const u8 {
                return a.print("-M{s}={s}", .{ name, try std.fs.path.join(a, &.{ r, rel }) });
            }
        };
        try argv.appendSlice(arena, &.{ "--dep", "contract", "--dep", "diag", "--dep", "frontend", "--dep", "kernels", try src.m(arena, root, "sim", "src/sim/root.zig") });
        try argv.append(arena, try src.m(arena, root, "diag", "lib/diag.zig"));
        try argv.appendSlice(arena, &.{ "--dep", "diag", "--dep", "contract", try src.m(arena, root, "frontend", "lib/frontend/root.zig") });
        try argv.appendSlice(arena, &.{ "--dep", "contract", try src.m(arena, root, "kernels", "lib/backend/kernels.zig") });
    }
    return runZig(gpa, io, argv.items, bin);
}

/// Creates `opts.work_dir` if absent and opens it. The caller closes it.
fn openWorkDir(io: Io, opts: BuildOptions) !Io.Dir {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, opts.work_dir);
    return cwd.openDir(io, opts.work_dir, .{});
}

/// Returns `<work_dir>/<fileStem(name)>` plus the target's executable
/// extension. Caller owns the path and must free it with `gpa`.
fn binPath(gpa: Allocator, arena: Allocator, opts: BuildOptions) ![]const u8 {
    return std.mem.concat(gpa, u8, &.{
        try std.fs.path.join(arena, &.{ opts.work_dir, try orchestrator.fileStem(arena, opts.name) }),
        builtin.target.exeFileExt(),
    });
}

/// Returns the argv every build here opens with: compiler, `verb`, output,
/// `-O`, cache directory, backend, then `-fstrip` when stripping. Allocated in
/// `arena`, as everything later appended to it must be.
fn argvHead(arena: Allocator, opts: BuildOptions, verb: []const u8, bin: []const u8) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        opts.zig_exe,
        verb,
        try arena.print("-femit-bin={s}", .{bin}),
        try arena.print("-O{t}", .{opts.optimize}),
        "--cache-dir",
        ".zig-cache",
    });
    try argv.appendSlice(arena, switch (opts.backend orelse orchestrator.Backend.auto(opts.optimize, builtin.target.cpu.arch)) {
        .self_hosted => &.{ "-fno-llvm", "-fno-lld" },
        .llvm => &.{"-fllvm"},
    });
    // No debug info where there are no safety checks to trace: emitting it
    // is most of an unsafe build's LLVM time.
    if (opts.strip orelse orchestrator.strip(opts.optimize, opts.debug_info)) try argv.append(arena, "-fstrip");
    return argv;
}

/// Runs `argv` to its exit. On success `bin`, which `gpa` owns, becomes the
/// `.ok` payload; on a failed build it is freed and `zig`'s stderr becomes the
/// `.failed` payload. On an error return `bin` is still the caller's.
fn runZig(gpa: Allocator, io: Io, argv: []const []const u8, bin: []const u8) !BuildResult {
    const r = try std.process.run(gpa, io, .{ .argv = argv });
    gpa.free(r.stdout);
    const failed = switch (r.term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (failed) {
        gpa.free(bin);
        return .{ .failed = r.stderr };
    }
    gpa.free(r.stderr);
    return .{ .ok = bin };
}

/// Writes one module's source to `<name>.<suffix>.zig` in `dir` and returns
/// the `-M<binding>=<path>` flag, allocated in `arena`. The name-qualified file
/// keeps two artifacts sharing a work root from overwriting each other.
fn bind(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    opts: BuildOptions,
    suffix: []const u8,
    binding: []const u8,
    text: []const u8,
) ![]const u8 {
    return arena.print("-M{s}={s}", .{ binding, try writeModule(arena, io, dir, opts, suffix, text) });
}

/// `bind`'s file half: writes `<name>.<suffix>.zig` and returns its path.
fn writeModule(arena: Allocator, io: Io, dir: Io.Dir, opts: BuildOptions, suffix: []const u8, text: []const u8) ![]const u8 {
    const file = try arena.print("{s}.{s}.zig", .{ try orchestrator.fileStem(arena, opts.name), suffix });
    try dir.writeFile(io, .{ .sub_path = file, .data = text });
    return std.fs.path.join(arena, &.{ opts.work_dir, file });
}

/// A testbench's module files on disk, as `stage` wrote them.
pub const Staged = struct { root: []const u8, device: []const u8 };

/// Writes the two module files `buildExe` would build for this device and
/// runner, under `opts.work_dir`, without building. Paths live in `arena`.
pub fn stage(arena: Allocator, io: Io, device_zig: []const u8, runner_zig: []const u8, opts: BuildOptions) !Staged {
    var dir = try openWorkDir(io, opts);
    defer dir.close(io);
    return .{
        .root = try writeModule(arena, io, dir, opts, "tb", runner_zig),
        .device = try writeModule(arena, io, dir, opts, "device", device_zig),
    };
}

/// A `buildBatch` binary runs member `i` when its `argv[0]` ends in
/// `batch_argv0 ++ "<i>"`: a symlink of that name stands in for each member's
/// own binary. No runner reads `argv[0]` (its plusargs start at `argv[1]`),
/// so a member's transcript is the one its own binary would print.
pub const batch_argv0 = "vera-batch-";

/// Builds several plain (not `mixed`, not `shared_lib`) staged testbenches
/// into ONE binary at `<opts.work_dir>/<opts.name>`, dispatching on `argv[0]`
/// (`batch_argv0`). A fixture testbench's build is mostly the compiler's fixed
/// cost per invocation (std, start code, the panic handler), which a batch
/// pays once. Measured with a shared warm cache, 8 Debug testbenches:
/// 17.57 Gi built one by one, 3.53 Gi as one batch, transcripts identical.
/// `.failed` names no member: the caller rebuilds them one by one to learn
/// which broke.
pub fn buildBatch(gpa: Allocator, io: Io, members: []const Staged, opts: BuildOptions) !BuildResult {
    std.debug.assert(!opts.mixed and !opts.shared_lib and members.len != 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root: std.ArrayList(u8) = .empty;
    try root.print(arena,
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init.Minimal) void {{
        \\    const argv = init.args.toSlice(std.heap.page_allocator) catch @panic("argv");
        \\    const at = std.mem.lastIndexOf(u8, argv[0], "{s}") orelse @panic("argv[0] names no batch member");
        \\    const i = std.fmt.parseInt(usize, argv[0][at + {d} ..], 10) catch @panic("argv[0] names no batch member");
        \\    switch (i) {{
        \\
    , .{ batch_argv0, batch_argv0.len });
    for (0..members.len) |i| try root.print(arena, "        {d} => @import(\"tb{d}\").main(init),\n", .{ i, i });
    try root.appendSlice(arena, "        else => @panic(\"argv[0] names no batch member\"),\n    }\n}\n");

    var dir = try openWorkDir(io, opts);
    defer dir.close(io);
    const root_path = try writeModule(arena, io, dir, opts, "batch", root.items);
    const bin = try binPath(gpa, arena, opts);
    errdefer gpa.free(bin);

    var argv = try argvHead(arena, opts, "build-exe", bin);
    for (0..members.len) |i| try argv.appendSlice(arena, &.{ "--dep", try arena.print("tb{d}", .{i}) });
    try argv.append(arena, try arena.print("-Mroot={s}", .{root_path}));
    for (members, 0..) |m, i| try argv.appendSlice(arena, &.{
        "--dep",                                        try arena.print("device=dev{d}", .{i}),
        "--dep",                                        "contract",
        try arena.print("-Mtb{d}={s}", .{ i, m.root }), "--dep",
        "contract",                                     try arena.print("-Mdev{d}={s}", .{ i, m.device }),
    });
    try argv.append(arena, try arena.print("-Mcontract={s}", .{opts.contract}));
    return runZig(gpa, io, argv.items, bin);
}
