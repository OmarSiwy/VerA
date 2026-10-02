//! Build orchestration: device.zig in, a generation-versioned lib<name>.so plus
//! its layout hash out (§8.3 device-side ABI). VerA produces the artifact; the
//! host owns dlopen, dlclose and state reset, and a fresh path per generation
//! gives it a fresh inode. Each build is one cold `zig build-lib --listen=-`
//! child (the compiler server protocol; the 0.16 build runner has no
//! `--listen`), or for a large LLVM device one `zig build-obj` child per
//! `Part` in parallel plus a linking `build-lib`, all reaped before
//! `compileRelease` returns. No build.zig is generated.

const std = @import("std");
const builtin = @import("builtin");
const codegen = @import("codegen.zig");
const naming = @import("naming.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const ClientMsg = std.zig.Client.Message;
const ServerMsg = std.zig.Server.Message;

/// Which Zig code generator builds the artifact, independent of the optimize
/// mode. `.self_hosted` does not optimise and has no nvptx/amdgcn target.
pub const Backend = enum {
    self_hosted,
    llvm,

    /// Returns `.self_hosted` for Debug on x86_64, where build time dominates,
    /// and `.llvm` otherwise.
    pub fn auto(optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch) Backend {
        return if (optimize == .Debug and arch == .x86_64) .self_hosted else .llvm;
    }
};

/// One support module on the compiler command line. `name` is the `@import`
/// string; `root` is its root source file, relative to the process cwd or
/// absolute. Strings are borrowed and must outlive the build.
pub const Module = struct {
    name: []const u8,
    root: []const u8,
    /// Names of other entries in `Options.modules` this one imports.
    deps: []const []const u8 = &.{},
};

/// A module name as a file-name stem: the name itself when it is short and
/// plain, else its plain prefix and a hash. §2.8 identifiers run to at least
/// 1024 characters and §2.8.1 escaped ones hold any printable byte, neither of
/// which a file system takes as a name.
pub fn fileStem(a: Allocator, name: []const u8) ![]const u8 {
    const plain = for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break false;
    } else true;
    if (plain and name.len <= 128) return name;
    var n: usize = 0;
    while (n < @min(name.len, 64) and (std.ascii.isAlphanumeric(name[n]) or name[n] == '_')) n += 1;
    return std.fmt.allocPrint(a, "{s}-{x:0>16}", .{ name[0..n], std.hash.Wyhash.hash(0, name) });
}

/// Everything the layout hash pins, plus where to put things. Strings are
/// borrowed and must outlive the build.
pub const Options = struct {
    /// VerA-owned directory: generated device.zig + shim.zig, the compiler
    /// cache, and the versioned artifacts. Created if absent.
    work_dir: []const u8,
    /// Device name. Artifact is `<work_dir>/lib<name>.<generation>.so`.
    name: []const u8,
    /// Independent of `backend`; `Backend.auto` is the usual pairing.
    optimize: std.builtin.OptimizeMode,
    backend: Backend,
    /// Support modules. Must contain `contract` (device.zig imports it) and
    /// `dyn`, whose root exposes
    /// `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`,
    /// and may expose `exportDevicePart` for a split build (`contract.DevicePart`).
    /// Order is hashed into `layout_hash` and fixes argv order.
    modules: []const Module,
    zig_exe: []const u8 = "zig",
    /// Keep DWARF in a ReleaseFast/ReleaseSmall build. Off by default: debug
    /// information is about half of a large device's LLVM time, and the
    /// machine code is the same with or without it. Debug and ReleaseSafe
    /// always keep it (their safety panics print stack traces). Not hashed:
    /// it changes no type layout.
    debug_info: bool = false,
    /// Build as one object per `Part`, in parallel, then link (`splits`).
    /// Null: only an LLVM build of at least `split_min_bytes` of device text.
    split: ?bool = null,
    /// A `.v` device's prebuilt engine object (`buildEngine`): linked in,
    /// and the shim declares `vera_prebuilt_engine`. Not hashed: the host's
    /// ABI is the same either way.
    engine: ?[]const u8 = null,
};

/// Whether a native build passes `-fstrip`: optimized without safety checks,
/// unless the caller asked for debug information. `tb.buildExe` follows the
/// same rule.
pub fn strip(optimize: std.builtin.OptimizeMode, debug_info: bool) bool {
    return !debug_info and (optimize == .ReleaseFast or optimize == .ReleaseSmall);
}

/// A built shared library.
pub const Artifact = struct {
    /// `<work_dir>/lib<name>.<generation>.so`, a fresh inode for the host to
    /// dlopen. Owned by the build's `gpa`; freed by `Result.deinit`.
    so_path: []const u8,
    /// `layoutHash` of the build options. The host rejects a `.so` whose
    /// hash differs (§8.3 device ABI).
    layout_hash: u64,
    generation: u32,
    /// True when the compiler reused cached output instead of producing new code.
    cache_hit: bool = false,
};

/// A build outcome. Both payloads are owned by the caller's `gpa`.
pub const Result = union(enum) {
    ok: Artifact,
    failed: std.zig.ErrorBundle,

    /// Frees the payload and invalidates `self`.
    pub fn deinit(self: *Result, gpa: Allocator) void {
        switch (self.*) {
            .ok => |a| gpa.free(a.so_path),
            .failed => |*b| b.deinit(gpa),
        }
        self.* = undefined;
    }
};

/// Returns a hash of the compiler version, optimize mode, backend and module
/// graph (in order), all of which change type layouts across the dyn ABI.
/// `work_dir` and `name` do not affect it. The host compares it with the
/// `.so`'s `arp_layout_hash` before use.
pub fn layoutHash(o: Options) u64 {
    var h: std.hash.Wyhash = .init(0xfa57_0af0_1a40_07);
    h.update(builtin.zig_version_string);
    h.update(&.{0});
    h.update(@tagName(o.optimize));
    h.update(&.{0});
    h.update(@tagName(o.backend));
    h.update(&.{0});
    for (o.modules) |m| {
        h.update(m.name);
        h.update(&.{0});
        h.update(m.root);
        h.update(&.{0});
        for (m.deps) |d| {
            h.update(d);
            h.update(&.{0});
        }
        h.update(&.{1});
    }
    return h.final();
}

/// Returns the dyn-ABI export shim, which re-exports the device under the
/// host's C ABI. It depends only on `name` and whether `engine` is linked,
/// so rebuilds never dirty it.
fn shimSource(gpa: Allocator, name: []const u8, engine: bool) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{s}comptime {{
        \\    @import("dyn").exportDevice(@import("device"), "{s}");
        \\}}
        \\
    , .{ rootDecls(engine), name });
}

/// The shim's root declarations: the `dyn` host's opt-in to the contract's
/// conformance checks, forwarded because the shim, not `dyn`, is the root
/// `contract.validating` reads; and, with `engine`, the one that makes
/// `sim`'s runtime call the linked engine object (`rt.prebuilt`).
fn rootDecls(engine: bool) []const u8 {
    const validate =
        "pub const vera_validate_contract = @hasDecl(@import(\"dyn\"), \"vera_validate_contract\") and " ++
        "@import(\"dyn\").vera_validate_contract;\n";
    return if (engine) validate ++ "pub const vera_prebuilt_engine = {};\n" else validate;
}

/// Writes `data` only if it differs from the file on disk and returns whether
/// it wrote. `zig` keys its ZIR cache on inode, size and mtime, so rewriting
/// an identical file would force AstGen to run again.
fn writeIfChanged(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    sub_path: []const u8,
    data: []const u8,
) !bool {
    if (dir.readFileAlloc(io, sub_path, gpa, .limited(data.len + 1))) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    return true;
}

/// Writes `<work_dir>/{shim.zig, device.zig, h.zig, u/<key>.zig ...}` and
/// returns how many files changed on disk; an unchanged device writes 0.
/// A split `device` gets one file per emitted unit (`zig`'s cache unit is the
/// file) and `device.zig` imports them by their stable names; a single
/// `device` is written as `device.zig` alone. Deletes `u/*.zig` files no
/// longer emitted. Creates `work_dir` if absent.
pub fn writeTree(io: Io, gpa: Allocator, o: Options, device: codegen.Output) !usize {
    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, o.work_dir);
    var dir = try cwd.openDir(io, o.work_dir, .{});
    defer dir.close(io);

    var writes: usize = 0;

    const shim = try shimSource(gpa, o.name, o.engine != null);
    defer gpa.free(shim);
    if (try writeIfChanged(io, gpa, dir, "shim.zig", shim)) writes += 1;

    if (device.names.len == 0) {
        // No `names`: the un-split form, one `device.zig` and no `u/`.
        if (try writeIfChanged(io, gpa, dir, "device.zig", device.text)) writes += 1;
        return writes;
    }

    if (try writeIfChanged(io, gpa, dir, "h.zig", device.helpers)) writes += 1;

    try dir.createDirPath(io, unit_dir);
    var udir = try dir.openDir(io, unit_dir, .{ .iterate = true });
    defer udir.close(io);

    var path_buf: [naming.max_name_len + 8]u8 = undefined;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    for (device.names, device.unit_lo, device.unit_fn, device.unit_hi) |name, lo, fn_at, hi| {
        body.clearRetainingCapacity();
        try body.appendSlice(gpa, device.prelude);
        // `pub ` goes in here, not in the emission: `device.text` is also the
        // stand-alone `--emit-zig` form, where `contract.rejectStrayPubDecls`
        // allows only contract-recognized names to be public.
        try body.appendSlice(gpa, device.text[lo..fn_at]);
        if (!std.mem.startsWith(u8, device.text[fn_at..], "pub ")) try body.appendSlice(gpa, "pub ");
        try body.appendSlice(gpa, device.text[fn_at..hi]);
        const p = try std.fmt.bufPrint(&path_buf, "{s}.zig", .{name});
        if (try writeIfChanged(io, gpa, udir, p, body.items)) writes += 1;
    }

    // device.zig = prologue ++ one import per unit ++ dispatcher tail. The
    // ranges tile (`codegen.Output`'s invariant), so those three pieces are the
    // whole file.
    body.clearRetainingCapacity();
    try body.appendSlice(gpa, device.text[0..device.unit_lo[0]]);
    for (device.names) |name| {
        try body.print(gpa, "const {0s} = @import(\"{1s}/{0s}.zig\").{0s};\n", .{ name, unit_dir });
    }
    try body.appendSlice(gpa, "\n");
    try body.appendSlice(gpa, device.text[device.unit_hi[device.unit_hi.len - 1]..]);
    if (try writeIfChanged(io, gpa, dir, "device.zig", body.items)) writes += 1;

    writes += try pruneUnits(io, gpa, udir, device.names);
    return writes;
}

const unit_dir = "u";

/// Deletes each `u/*.zig` whose key is not in `names` and returns the count.
/// A stale file would keep feeding `zig` a declaration nothing imports.
// ponytail: O(files × units) membership scan. A module has ~100 units and the
// directory has ~100 entries; switch to a StringHashMap of the names if a model
// ever shows up with thousands.
fn pruneUnits(io: Io, gpa: Allocator, udir: Io.Dir, names: []const []const u8) !usize {
    var stale: std.ArrayList([]const u8) = .empty;
    defer {
        for (stale.items) |s| gpa.free(s);
        stale.deinit(gpa);
    }

    // Collect first, delete after: mutating a directory while iterating it is
    // unspecified on every filesystem this runs on.
    var it = udir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        // ponytail: membership is decided by the first match; keep the small-list scan.
        const live = for (names) |n| {
            if (std.mem.eql(u8, n, stem)) break true;
        } else false;
        if (!live) try stale.append(gpa, try gpa.dupe(u8, entry.name));
    }
    for (stale.items) |s| try udir.deleteFile(io, s);
    return stale.items.len;
}

/// The pieces a large LLVM device build is split into: one `zig build-obj`
/// process each, run in parallel, then linked into the library. LLVM emits one
/// module on one thread, so this is the only way a device build uses more
/// than one core. `contract.DevicePart` spells the same tags for the host
/// (`tests/test_all.zig` holds them equal).
pub const Part = enum { setup, state, eval };

/// Emitted device text from which `Options.split = null` splits an LLVM
/// build into `Part`s. Measured 2026-10-01 (stripped, slots grouped): the
/// split leaves eval's instructions per call unchanged but moves code, and
/// that layout shift was neutral to favourable on bsim4va (818 KB), psp103
/// (1.4 MB) and coupled_ltra (5.8 MB) yet cost txl (590 KB) +47% eval cycles
/// at identical instructions; the threshold sits between them. Each extra
/// process also costs fixed std/process work, so mos1 (125 KB) gains nothing.
pub const split_min_bytes: usize = 768 * 1024;

/// Whether `compileRelease` builds `device` as `Part`s.
pub fn splits(o: Options, device: codegen.Output) bool {
    return o.split orelse (o.backend == .llvm and device.text.len >= split_min_bytes);
}

/// The root of one part's object: the host's `exportDevicePart` for that
/// part, or, for a host without one, its `exportDevice` in the setup object
/// and nothing in the others.
fn partShimSource(arena: Allocator, name: []const u8, part: Part, engine: bool) ![]u8 {
    return if (part == .setup) std.fmt.allocPrint(arena,
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{1s}comptime {{
        \\    const dyn = @import("dyn");
        \\    if (@hasDecl(dyn, "exportDevicePart"))
        \\        dyn.exportDevicePart(@import("device"), "{0s}", .setup)
        \\    else
        \\        dyn.exportDevice(@import("device"), "{0s}");
        \\}}
        \\
    , .{ name, rootDecls(engine) }) else std.fmt.allocPrint(arena,
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\{s}comptime {{
        \\    const dyn = @import("dyn");
        \\    if (@hasDecl(dyn, "exportDevicePart")) dyn.exportDevicePart(@import("device"), "{s}", .{t});
        \\}}
        \\
    , .{ rootDecls(engine), name, part });
}

/// Returns `zig build-lib --listen=- ... -Mroot=shim.zig -Mdevice=... -M<support>...`
/// allocated in `arena`, in `o.modules` order, or for a `part` the
/// `zig build-obj` of `shim_<part>.zig` into `<name>_<part>.o`. As in
/// `std.Build.Step.Compile.getZigArgs`, each `--dep` applies to the next `-M`.
fn buildArgv(arena: Allocator, o: Options, part: ?Part) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;

    try a.appendSlice(arena, &.{
        o.zig_exe,
        if (part == null) "build-lib" else "build-obj",
        "--listen=-",
        // An object linked into a shared library must be position independent.
        if (part == null) "-dynamic" else "-fPIC",
        try std.fmt.allocPrint(arena, "-O{s}", .{@tagName(o.optimize)}),
        "--name",
        if (part) |p| try std.fmt.allocPrint(arena, "{s}_{t}", .{ o.name, p }) else o.name,
        "--cache-dir",
        try std.fs.path.join(arena, &.{ o.work_dir, ".zig-cache" }),
    });

    switch (o.backend) {
        // The only backend that patches in place, so the only one where
        // `-fincremental` pays.
        .self_hosted => try a.appendSlice(arena, &.{ "-fno-llvm", "-fno-lld", "-fincremental" }),
        .llvm => try a.append(arena, "-fllvm"),
    }
    if (strip(o.optimize, o.debug_info)) try a.append(arena, "-fstrip");
    if (part == null) if (o.engine) |e| try a.append(arena, e);

    // root = shim.zig: imports `device` plus every support module.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.appendSlice(arena, &.{
        "--dep",
        "device",
        try std.fmt.allocPrint(arena, "-Mroot={s}", .{
            try std.fs.path.join(arena, &.{ o.work_dir, if (part) |p| try shimName(arena, p) else "shim.zig" }),
        }),
    });

    // device.zig imports `contract`.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.append(arena, try std.fmt.allocPrint(arena, "-Mdevice={s}", .{
        try std.fs.path.join(arena, &.{ o.work_dir, "device.zig" }),
    }));

    for (o.modules) |m| {
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try std.fmt.allocPrint(arena, "-M{s}={s}", .{ m.name, m.root }));
    }

    return a.items;
}

fn shimName(arena: Allocator, part: Part) ![]const u8 {
    return std.fmt.allocPrint(arena, "shim_{t}.zig", .{part});
}

/// `zig build-lib --listen=- -dynamic` over the parts' objects. The link
/// takes `-O` and `-fstrip` for the compiler_rt it adds.
fn linkArgv(arena: Allocator, o: Options, objs: []const []const u8) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(arena, &.{
        o.zig_exe,
        "build-lib",
        "--listen=-",
        "-dynamic",
        try std.fmt.allocPrint(arena, "-O{s}", .{@tagName(o.optimize)}),
        "--name",
        o.name,
        "--cache-dir",
        try std.fs.path.join(arena, &.{ o.work_dir, ".zig-cache" }),
    });
    if (strip(o.optimize, o.debug_info)) try a.append(arena, "-fstrip");
    try a.appendSlice(arena, objs);
    if (o.engine) |e| try a.append(arena, e);
    return a.items;
}

/// The root of the engine object: `sim`'s runtime, with no root options
/// (a device's shim declares none).
const engine_root =
    \\// GENERATED BY VerA — DO NOT EDIT.
    \\comptime {
    \\    @import("sim").rt.engine.exportAll();
    \\}
    \\
;

/// The prebuilt engine object, or the compiler's report.
pub const EngineResult = union(enum) {
    /// The object's path in `cache_dir`, owned by `gpa`.
    ok: []u8,
    failed: std.zig.ErrorBundle,

    pub fn deinit(self: *EngineResult, gpa: Allocator) void {
        switch (self.*) {
            .ok => |p| gpa.free(p),
            .failed => |*b| b.deinit(gpa),
        }
        self.* = undefined;
    }
};

/// Builds `sim`'s design-independent runtime (`rt/engine.zig`) as a
/// position-independent object for `Options.engine`, with `o`'s compiler,
/// optimize mode, backend, `-fstrip` and modules (`dyn` aside), under
/// `cache_dir`. Every device built with the same of each shares one object:
/// the compiler's own cache keys it on its version, the target and CPU, every
/// flag, and the path and content of every source file reached, and answers
/// an unchanged build from the cache. A stale object cannot be linked: the
/// engine's symbol names carry its layout hash (`engine.tag`).
pub fn buildEngine(gpa: Allocator, io: Io, o: Options, cache_dir: []const u8) !EngineResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, cache_dir);
    // Named by its content, so it is written once and never changes.
    const name = comptime std.fmt.comptimePrint("vera_engine_{x:0>16}.zig", .{std.hash.Wyhash.hash(0, engine_root)});
    const root = try std.fs.path.join(arena, &.{ cache_dir, name });
    cwd.access(io, root, .{}) catch {
        // Atomic: a concurrent `vera` never reads half the file.
        var af = try cwd.createFileAtomic(io, root, .{ .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, engine_root);
        try af.replace(io);
    };

    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(arena, &.{
        o.zig_exe,
        "build-obj",
        "--listen=-",
        "-fPIC",
        try std.fmt.allocPrint(arena, "-O{s}", .{@tagName(o.optimize)}),
        "--name",
        "vera_engine",
        "--cache-dir",
        cache_dir,
    });
    try a.appendSlice(arena, switch (o.backend) {
        .self_hosted => &.{ "-fno-llvm", "-fno-lld" },
        .llvm => &.{"-fllvm"},
    });
    if (strip(o.optimize, o.debug_info)) try a.append(arena, "-fstrip");
    try a.appendSlice(arena, &.{ "--dep", "sim", try std.fmt.allocPrint(arena, "-Mroot={s}", .{root}) });
    for (o.modules) |m| if (!std.mem.eql(u8, m.name, "dyn")) {
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try std.fmt.allocPrint(arena, "-M{s}={s}", .{ m.name, m.root }));
    };

    var s: Server = undefined;
    try s.spawn(io, arena, a.items);
    defer s.close(io);
    try send(io, &s.child, .update);
    return switch (try s.wait(gpa)) {
        .failed => |b| .{ .failed = b },
        .ok => |u| .{ .ok = try std.fs.path.join(gpa, &.{
            cache_dir, "o", &Cache.binToHex(u.digest), "vera_engine" ++ comptime builtin.target.ofmt.fileExt(builtin.target.cpu.arch),
        }) },
    };
}

/// One `zig ... --listen=-` child: the compiler server protocol over its
/// stdin/stdout. Must not move after `spawn`: `out.interface` is the reader.
const Server = struct {
    child: std.process.Child,
    out: Io.File.Reader,

    fn spawn(s: *Server, io: Io, arena: Allocator, argv: []const []const u8) !void {
        s.child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Compiler panics reach the terminal, and an unread stderr pipe
            // cannot fill and deadlock the update loop.
            .stderr = .inherit,
        }) catch return error.CompilerGone;
        // Steady-state buffer; larger message bodies go through `readAlloc`.
        s.out = s.child.stdout.?.readerStreaming(io, try arena.alloc(u8, 64 * 1024));
    }

    /// Asks for an exit and reaps the child.
    fn close(s: *Server, io: Io) void {
        if (s.child.stdin) |stdin| {
            send(io, &s.child, .exit) catch {};
            stdin.close(io);
            s.child.stdin = null;
        }
        _ = s.child.wait(io) catch s.child.kill(io);
    }

    const Update = union(enum) {
        ok: struct { digest: Cache.BinDigest, cache_hit: bool },
        failed: std.zig.ErrorBundle,
    };

    /// Reads one update's reply: an `error_bundle` message, possibly empty,
    /// ends it. A failed bundle is owned by `gpa`.
    fn wait(s: *Server, gpa: Allocator) !Update {
        const r = &s.out.interface;
        var digest: ?Cache.BinDigest = null;
        var cache_hit = false;
        while (true) {
            const header = r.takeStruct(ServerMsg.Header, .little) catch return error.CompilerGone;
            const body = r.readAlloc(gpa, header.bytes_len) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.CompilerGone,
            };
            defer gpa.free(body);

            switch (header.tag) {
                .zig_version => if (!std.mem.eql(u8, builtin.zig_version_string, body))
                    return error.ProtocolMismatch,
                .emit_digest => {
                    if (body.len < @sizeOf(ServerMsg.EmitDigest) + Cache.bin_digest_len)
                        return error.ProtocolMismatch;
                    const eh: *align(1) const ServerMsg.EmitDigest = @ptrCast(body.ptr);
                    cache_hit = eh.flags.cache_hit;
                    digest = body[@sizeOf(ServerMsg.EmitDigest)..][0..Cache.bin_digest_len].*;
                },
                .error_bundle => {
                    var bundle = try std.zig.Server.allocErrorBundle(gpa, body);
                    if (bundle.errorMessageCount() > 0) return .{ .failed = bundle };
                    bundle.deinit(gpa);
                    break;
                },
                // file_system_inputs, time_report, test_*: nothing here uses them.
                else => {},
            }
        }
        return .{ .ok = .{ .digest = digest orelse return error.NoArtifact, .cache_hit = cache_hit } };
    }
};

/// Builds once, cold: spawns `zig build-lib --listen=-`, writes `device` into
/// the tree (`writeTree`), runs one update and reaps the child. A device
/// `splits` is instead built as one `zig build-obj` per `Part`, in parallel,
/// and linked. Caller owns the `Result`. Fails with `error.CompilerGone` if
/// `o.zig_exe` cannot be spawned or dies mid-update, `error.ProtocolMismatch`
/// on a compiler other than the one VerA was built with.
pub fn compileRelease(
    gpa: Allocator,
    io: Io,
    o: Options,
    device: codegen.Output,
    generation: u32,
) !Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = comptime std.enums.values(Part);
    const split = splits(o, device);

    // Spawned before the tree is written, so the compilers start up while
    // VerA writes.
    var servers: [parts.len]Server = undefined;
    var started: usize = 0;
    defer for (servers[0..started]) |*s| s.close(io);
    for (if (split) parts else parts[0..1], 0..) |p, i| {
        try servers[i].spawn(io, arena, try buildArgv(arena, o, if (split) p else null));
        started += 1;
    }

    _ = try writeTree(io, gpa, o, device);
    if (split) {
        var dir = try Io.Dir.cwd().openDir(io, o.work_dir, .{});
        defer dir.close(io);
        for (parts) |p| {
            const text = try partShimSource(arena, o.name, p, o.engine != null);
            _ = try writeIfChanged(io, gpa, dir, try shimName(arena, p), text);
        }
    }
    // Every update is sent before any reply is read: the parts compile at once.
    for (servers[0..started]) |*s| try send(io, &s.child, .update);

    if (!split) return switch (try servers[0].wait(gpa)) {
        .failed => |b| .{ .failed = b },
        .ok => |u| .{ .ok = .{
            .so_path = try publish(io, gpa, o, u.digest, generation),
            .layout_hash = layoutHash(o),
            .generation = generation,
            .cache_hit = u.cache_hit,
        } },
    };

    // Each part analyses the whole device, so a device error arrives up to
    // three times; the first part's report is the one returned.
    var objs: [parts.len][]const u8 = undefined;
    var failed: ?std.zig.ErrorBundle = null;
    errdefer if (failed) |*b| b.deinit(gpa);
    var cache_hit = true;
    for (&servers, parts, &objs) |*s, p, *obj| switch (try s.wait(gpa)) {
        .failed => |b| if (failed == null) {
            failed = b;
        } else {
            var extra = b;
            extra.deinit(gpa);
        },
        .ok => |u| {
            cache_hit = cache_hit and u.cache_hit;
            const t = &builtin.target;
            obj.* = try std.fs.path.join(arena, &.{
                o.work_dir,                                                                              ".zig-cache", "o", &Cache.binToHex(u.digest),
                try std.fmt.allocPrint(arena, "{s}_{t}{s}", .{ o.name, p, t.ofmt.fileExt(t.cpu.arch) }),
            });
        },
    };
    if (failed) |b| {
        failed = null;
        return .{ .failed = b };
    }

    var link: Server = undefined;
    try link.spawn(io, arena, try linkArgv(arena, o, &objs));
    defer link.close(io);
    try send(io, &link.child, .update);
    return switch (try link.wait(gpa)) {
        .failed => |b| .{ .failed = b },
        .ok => |u| .{ .ok = .{
            .so_path = try publish(io, gpa, o, u.digest, generation),
            .layout_hash = layoutHash(o),
            .generation = generation,
            .cache_hit = cache_hit and u.cache_hit,
        } },
    };
}

fn send(io: Io, child: *std.process.Child, tag: ClientMsg.Tag) !void {
    const stdin = child.stdin orelse return error.CompilerGone;
    var w = stdin.writer(io, &.{});
    w.interface.writeStruct(ClientMsg.Header{ .tag = tag, .bytes_len = 0 }, .little) catch
        return error.CompilerGone;
}

/// Copies the cache output to a generation-stamped path so the host dlopens a
/// fresh inode; a hardlink would share the cache entry's inode. Caller owns
/// the returned path.
fn publish(io: Io, gpa: Allocator, o: Options, digest: Cache.BinDigest, generation: u32) ![]u8 {
    const t = &builtin.target;
    const lib_name = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        t.libPrefix(), o.name, t.dynamicLibSuffix(),
    });
    defer gpa.free(lib_name);

    const src = try std.fs.path.join(gpa, &.{
        o.work_dir, ".zig-cache", "o", &Cache.binToHex(digest), lib_name,
    });
    defer gpa.free(src);

    const dst = try std.fmt.allocPrint(gpa, "{s}{c}{s}{s}.{d}{s}", .{
        o.work_dir, std.fs.path.sep, t.libPrefix(),
        o.name,     generation,      t.dynamicLibSuffix(),
    });
    errdefer gpa.free(dst);

    const cwd: Io.Dir = .cwd();
    cwd.copyFile(src, cwd, dst, io, .{}) catch return error.NoArtifact;
    return dst;
}

test "Backend.auto is self-hosted only for Debug on x86_64" {
    try std.testing.expectEqual(Backend.self_hosted, Backend.auto(.Debug, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.ReleaseFast, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.Debug, .aarch64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.Debug, .nvptx64));
}

test "an optimized build strips unless debug information is asked for" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Case = struct { optimize: std.builtin.OptimizeMode, debug_info: bool, strip: bool };
    for ([_]Case{
        .{ .optimize = .ReleaseFast, .debug_info = false, .strip = true },
        .{ .optimize = .ReleaseSmall, .debug_info = false, .strip = true },
        .{ .optimize = .ReleaseFast, .debug_info = true, .strip = false },
        .{ .optimize = .ReleaseSafe, .debug_info = false, .strip = false },
        .{ .optimize = .Debug, .debug_info = false, .strip = false },
    }) |c| {
        const argv = try buildArgv(arena.allocator(), .{
            .work_dir = "w",
            .name = "dev",
            .optimize = c.optimize,
            .backend = .llvm,
            .modules = &.{},
            .debug_info = c.debug_info,
        }, null);
        const has = for (argv) |a| {
            if (std.mem.eql(u8, a, "-fstrip")) break true;
        } else false;
        try std.testing.expectEqual(c.strip, has);
    }
}

test "layoutHash pins optimize, backend and the module graph" {
    const mods = [_]Module{
        .{ .name = "contract", .root = "c.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };
    const base: Options = .{
        .work_dir = "w",
        .name = "dev",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &mods,
    };

    try std.testing.expectEqual(layoutHash(base), layoutHash(base));

    var o = base;
    o.optimize = .ReleaseFast;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    o = base;
    o.backend = .llvm;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    const other = [_]Module{
        .{ .name = "contract", .root = "OTHER.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };
    o = base;
    o.modules = &other;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    // Order is part of the graph identity.
    const swapped = [_]Module{ mods[1], mods[0] };
    o = base;
    o.modules = &swapped;
    try std.testing.expect(layoutHash(o) != layoutHash(base));

    // `work_dir` and `name` are placement, not ABI.
    o = base;
    o.work_dir = "elsewhere";
    o.name = "other";
    try std.testing.expectEqual(layoutHash(base), layoutHash(o));
}

/// A two-unit device in the shape `codegen.generate` produces: prologue, two
/// tiling unit ranges, dispatcher tail.
const split_prologue =
    \\const contract = @import("contract");
    \\pub const k2: f64 = 2.0;
    \\
;
const split_unit_a =
    \\fn unit_a(y: f64) f64 {
    \\    return y * k2;
    \\}
    \\
;
const split_unit_b =
    \\fn unit_b(y: f64) f64 {
    \\    return y + k2;
    \\}
    \\
;
const split_tail =
    \\pub fn eval(x: f64) callconv(.c) f64 {
    \\    return unit_a(x) + unit_b(x);
    \\}
    \\
;
const split_text = split_prologue ++ split_unit_a ++ split_unit_b ++ split_tail;
const split_prelude = "const dev = @import(\"../device.zig\");\nconst k2 = dev.k2;\n";

fn splitOutput(names: []const []const u8) codegen.Output {
    return .{
        .text = split_text,
        .names = names,
        .unit_lo = &.{
            split_prologue.len,
            split_prologue.len + split_unit_a.len,
        },
        .unit_fn = &.{
            split_prologue.len,
            split_prologue.len + split_unit_a.len,
        },
        .unit_hi = &.{
            split_prologue.len + split_unit_a.len,
            split_prologue.len + split_unit_a.len + split_unit_b.len,
        },
        .prelude = split_prelude,
        .helpers = "pub const k3: f64 = 3.0;\n",
    };
}

test "writeTree splits per unit, and a no-op regeneration writes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    const o: Options = .{
        .work_dir = work,
        .name = "testdev",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &.{},
    };

    const both = [_][]const u8{ "unit_a", "unit_b" };
    // shim + h.zig + 2 units + device.zig
    try std.testing.expectEqual(@as(usize, 5), try writeTree(io, gpa, o, splitOutput(&both)));

    // Regenerating an unchanged device touches nothing on disk.
    try std.testing.expectEqual(@as(usize, 0), try writeTree(io, gpa, o, splitOutput(&both)));

    // The unit file is prelude ++ exactly its slice of the emission.
    const a = try tmp.dir.readFileAlloc(io, "u/unit_a.zig", gpa, .limited(4096));
    defer gpa.free(a);
    try std.testing.expectEqualStrings(split_prelude ++ "pub " ++ split_unit_a, a);

    // device.zig is prologue ++ imports ++ tail; the unit bodies are elsewhere.
    const dev = try tmp.dir.readFileAlloc(io, "device.zig", gpa, .limited(4096));
    defer gpa.free(dev);
    try std.testing.expect(std.mem.startsWith(u8, dev, split_prologue));
    try std.testing.expect(std.mem.endsWith(u8, dev, split_tail));
    try std.testing.expect(std.mem.indexOf(u8, dev, "const unit_a = @import(\"u/unit_a.zig\").unit_a;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dev, "return y * k2;") == null);

    // A vanished unit takes its file with it: device.zig plus the delete.
    // `u/unit_a.zig` is unchanged, so it is not rewritten.
    const shrunk: codegen.Output = .{
        .text = split_prologue ++ split_unit_a ++ split_tail,
        .names = &.{"unit_a"},
        .unit_lo = &.{split_prologue.len},
        .unit_fn = &.{split_prologue.len},
        .unit_hi = &.{split_prologue.len + split_unit_a.len},
        .prelude = split_prelude,
        .helpers = "pub const k3: f64 = 3.0;\n",
    };
    try std.testing.expectEqual(@as(usize, 2), try writeTree(io, gpa, o, shrunk));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u/unit_b.zig", .{}));
}

test "compileRelease builds and versions a device" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    // Minimal stand-ins for the host's modules. `dyn`'s only obligation is the
    // `exportDevice` signature the shim calls.
    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data = "pub const k: f64 = 2.0;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dyn.zig", .data =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    });

    const mods = [_]Module{
        .{ .name = "contract", .root = try std.fs.path.join(gpa, &.{ work, "contract.zig" }) },
        .{ .name = "dyn", .root = try std.fs.path.join(gpa, &.{ work, "dyn.zig" }) },
    };
    defer for (mods) |m| gpa.free(m.root);

    const o: Options = .{
        .work_dir = work,
        .name = "testdev",
        .optimize = .Debug,
        .backend = .self_hosted,
        .modules = &mods,
    };

    const dev_v1 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    var r1 = compileRelease(gpa, io, o, .{ .text = dev_v1 }, 1) catch |err| switch (err) {
        // No `zig` on PATH in this environment: nothing to assert.
        error.CompilerGone => return error.SkipZigTest,
        else => return err,
    };
    defer r1.deinit(gpa);
    switch (r1) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| {
            try std.testing.expectEqual(@as(u32, 1), a.generation);
            try std.testing.expectEqual(layoutHash(o), a.layout_hash);
            try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.1.so"));
            _ = try Io.Dir.cwd().statFile(io, a.so_path, .{});
        },
    }

    // A changed unit rebuilds to a fresh inode under a new generation.
    const dev_v2 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k + 1.0; }
        \\
    ;
    var r2 = try compileRelease(gpa, io, o, .{ .text = dev_v2 }, 2);
    defer r2.deinit(gpa);
    switch (r2) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| {
            try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.2.so"));
            _ = try Io.Dir.cwd().statFile(io, a.so_path, .{});
        },
    }

    // A broken unit is reported as diagnostics.
    var r3 = try compileRelease(gpa, io, o, .{ .text = "pub fn eval() void { @compileError(\"boom\"); }\n" }, 3);
    defer r3.deinit(gpa);
    try std.testing.expect(r3 == .failed);

    // The split form compiles: `device.zig` and the unit files import each
    // other, which is legal Zig.
    var r5 = try compileRelease(gpa, io, o, splitOutput(&.{ "unit_a", "unit_b" }), 5);
    defer r5.deinit(gpa);
    switch (r5) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.5.so")),
    }
}

test "buildEngine reuses its object only while every key component is unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    const cache = try std.fs.path.join(gpa, &.{ work, "engine-cache" });
    defer gpa.free(cache);

    // A stand-in `sim` whose engine reads a constant from a second file.
    try tmp.dir.writeFile(io, .{ .sub_path = "sim.zig", .data =
        \\pub const rt = struct {
        \\    pub const engine = struct {
        \\        pub fn exportAll() void {
        \\            @export(&k, .{ .name = "vera_rt_test_k" });
        \\        }
        \\        fn k() callconv(.c) u32 {
        \\            return @import("k.zig").k;
        \\        }
        \\    };
        \\};
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 1;\n" });
    const mods = [_]Module{
        .{ .name = "dyn", .root = "never-read.zig" },
        .{ .name = "sim", .root = try std.fs.path.join(gpa, &.{ work, "sim.zig" }) },
    };
    defer gpa.free(mods[1].root);
    var o: Options = .{ .work_dir = work, .name = "unused", .optimize = .Debug, .backend = .self_hosted, .modules = &mods };

    const Build = struct {
        fn path(o_: Options, cache_: []const u8) ![]u8 {
            var r = try buildEngine(gpa, io, o_, cache_);
            switch (r) {
                .failed => |b| {
                    b.renderToStderr(io, .{}, .off) catch {};
                    r.deinit(gpa);
                    return error.UnexpectedBuildFailure;
                },
                .ok => |p| return p,
            }
        }
    };
    const first = Build.path(o, cache) catch |err| switch (err) {
        // No `zig` on PATH in this environment: nothing to assert.
        error.CompilerGone => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(first);

    // Unchanged: the same object.
    const again = try Build.path(o, cache);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(first, again);

    // A changed source file, a changed optimize mode, a changed backend:
    // each a different object.
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 2;\n" });
    const edited = try Build.path(o, cache);
    defer gpa.free(edited);
    try std.testing.expect(!std.mem.eql(u8, first, edited));

    o.optimize = .ReleaseSmall;
    o.backend = .llvm;
    const small = try Build.path(o, cache);
    defer gpa.free(small);
    try std.testing.expect(!std.mem.eql(u8, edited, small));

    // ... and the change undone finds the first object again.
    o.optimize = .Debug;
    o.backend = .self_hosted;
    try tmp.dir.writeFile(io, .{ .sub_path = "k.zig", .data = "pub const k: u32 = 1;\n" });
    const back = try Build.path(o, cache);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(first, back);
}

test "a split build links one object per part into a library that runs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data = "pub const k: f64 = 2.0;\n" });
    // A host with `exportDevicePart` exports each symbol from one part: the
    // library resolves both only if every part was compiled and linked.
    try tmp.dir.writeFile(io, .{ .sub_path = "parts.zig", .data =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = .{ D, name };
        \\    @compileError("a split build calls exportDevicePart");
        \\}
        \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
        \\    _ = name;
        \\    if (part == .setup) @export(&D.k, .{ .name = "arp_k" });
        \\    if (part == .eval) @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    });
    // One without it is built whole in the setup object.
    try tmp.dir.writeFile(io, .{ .sub_path = "whole.zig", .data =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.k, .{ .name = "arp_k" });
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    });
    const dev =
        \\const contract = @import("contract");
        \\pub fn k() callconv(.c) f64 { return contract.k; }
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;

    for ([_][]const u8{ "parts.zig", "whole.zig" }, 1..) |dyn, gen| {
        const mods = [_]Module{
            .{ .name = "contract", .root = try std.fs.path.join(gpa, &.{ work, "contract.zig" }) },
            .{ .name = "dyn", .root = try std.fs.path.join(gpa, &.{ work, dyn }) },
        };
        defer for (mods) |m| gpa.free(m.root);
        const o: Options = .{
            .work_dir = work,
            .name = "splitdev",
            .optimize = .ReleaseFast,
            .backend = .llvm,
            .modules = &mods,
            .split = true,
        };
        try std.testing.expect(splits(o, .{ .text = dev }));
        var r = compileRelease(gpa, io, o, .{ .text = dev }, @intCast(gen)) catch |err| switch (err) {
            error.CompilerGone => return error.SkipZigTest,
            else => return err,
        };
        defer r.deinit(gpa);
        const so = switch (r) {
            .failed => |b| {
                b.renderToStderr(io, .{}, .off) catch {};
                return error.UnexpectedBuildFailure;
            },
            .ok => |a| a.so_path,
        };
        var lib = try std.DynLib.open(so);
        defer lib.close();
        const k = lib.lookup(*const fn () callconv(.c) f64, "arp_k") orelse return error.MissingSymbol;
        const eval = lib.lookup(*const fn (f64) callconv(.c) f64, "arp_eval") orelse return error.MissingSymbol;
        try std.testing.expectEqual(@as(f64, 2.0), k());
        try std.testing.expectEqual(@as(f64, 6.0), eval(3.0));
    }

    // The default splits only a large LLVM build.
    const base: Options = .{ .work_dir = work, .name = "d", .optimize = .ReleaseFast, .backend = .llvm, .modules = &.{} };
    try std.testing.expect(!splits(base, .{ .text = dev }));
    const big = try gpa.alloc(u8, split_min_bytes);
    defer gpa.free(big);
    try std.testing.expect(splits(base, .{ .text = big }));
    var native = base;
    native.backend = .self_hosted;
    try std.testing.expect(!splits(native, .{ .text = big }));
}
