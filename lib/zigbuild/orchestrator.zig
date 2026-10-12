//! Build orchestration: device.zig in, a generation-versioned lib<name>.so plus
//! its layout hash out (§8.3 device-side ABI). VerA produces the artifact; the
//! host owns dlopen, dlclose and state reset, and a fresh path per generation
//! gives it a fresh inode. Each build is one cold `zig build-lib --listen=-`
//! child (the compiler server protocol; the build runner's `--listen` serves
//! the build server protocol instead), or for a large LLVM device one
//! `zig build-obj` child per
//! `Part` in parallel plus a linking `build-lib`, all reaped before
//! `compileRelease` returns. No build.zig is generated.
//!
//! `compileRelease` is the spine: spawn the children, `writeTree`, write the
//! shims, send every update, collect, link, `publish`. The text written beside
//! the device is `shim.zig`'s and the child protocol `server.zig`'s; this file
//! owns the build policy (options, argv, split, layout hash), the on-disk tree
//! and `Output`, the device text it takes, which codegen produces.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const shim = @import("shim.zig");
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const send = server_mod.send;
const assert = std.debug.assert;

/// Which Zig code generator builds the artifact, independent of the optimize
/// mode. `.self_hosted` does not optimise and has no nvptx/amdgcn target.
pub const Backend = enum {
    self_hosted,
    llvm,

    /// Returns `.self_hosted` for Debug on x86_64, where build time dominates,
    /// and `.llvm` otherwise.
    pub fn auto(optimize: std.lang.Optimize, arch: std.Target.Cpu.Arch) Backend {
        return if (optimize == .debug and arch == .x86_64) .self_hosted else .llvm;
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
/// which a file system takes as a name. A hashed stem always holds a `-`,
/// which no plain name does, so the two forms never collide. Returns `name`
/// itself (borrowed) when it is kept, else a stem allocated in `a`.
pub fn fileStem(a: Allocator, name: []const u8) ![]const u8 {
    const plain = for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break false;
    } else true;
    if (plain and name.len <= 128) return name;
    var n: usize = 0;
    while (n < @min(name.len, 64) and (std.ascii.isAlphanumeric(name[n]) or name[n] == '_')) n += 1;
    assert(n <= 64);
    assert(n <= name.len);
    const stem = try a.print("{s}-{x:0>16}", .{ name[0..n], std.hash.Wyhash.hash(0, name) });
    // The plain prefix, the `-` no plain name holds, 16 hex digits of a u64.
    assert(stem.len == n + 1 + 16);
    assert(stem[n] == '-');
    return stem;
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
    optimize: std.lang.Optimize,
    backend: Backend,
    /// Support modules. Must contain `contract` (device.zig imports it) and
    /// `dyn`, whose root exposes
    /// `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`,
    /// and may expose `exportDevicePart` for a split build (`contract.DevicePart`).
    /// Order is hashed into `layout_hash` and fixes argv order.
    modules: []const Module,
    /// The compiler to spawn, looked up on `PATH` when bare. It must be the
    /// Zig VerA was built with, or the build fails with `error.ProtocolMismatch`.
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
pub fn strip(optimize: std.lang.Optimize, debug_info: bool) bool {
    return !debug_info and (optimize == .fast or optimize == .small);
}

/// A built shared library.
pub const Artifact = struct {
    /// `<work_dir>/lib<name>.<generation>.so`, a fresh inode for the host to
    /// dlopen. Owned by the build's `gpa`; freed by `Result.deinit`.
    so_path: []const u8,
    /// `layoutHash` of the build options. The host rejects a `.so` whose
    /// hash differs (§8.3 device ABI).
    layout_hash: u64,
    /// The `generation` the build was asked for, the number in `so_path`.
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
fn layoutHash(o: Options) u64 {
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
    assert(sub_path.len > 0);
    if (dir.readFileAlloc(io, sub_path, gpa, .limited(data.len + 1))) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    return true;
}

/// The generated device, plus the ranges that let `writeTree` write it as
/// one file per unit declaration. Zig caches ZIR per file keyed on inode, size
/// and mtime, so an unchanged unit's file is left untouched and skips AstGen.
/// `text` stays the single contiguous emission that `--emit-zig` writes
/// verbatim; the split is a view over it. Codegen produces it
/// (`codegen.generate`).
///
/// Invariant: the ranges tile. `unit_lo[i] == unit_hi[i-1]`, so
/// `text[0..unit_lo[0]]` is the prologue and `text[unit_hi[n-1]..]` is the
/// dispatcher tail.
pub const Output = struct {
    /// The whole device. Gpa-owned (see `codegen.generate`).
    text: []const u8,
    /// One entry per emitted top-level unit declaration, in emission order.
    /// `names[i]` is both the declaration name and the file stem, so the file
    /// set changes exactly when `ir/names.zig`'s keys do. Arena-owned.
    names: []const []const u8 = &.{},
    /// Offset in `text` where each unit's declaration starts.
    unit_lo: []const u32 = &.{},
    /// Offset of the declaration keyword inside `text`. The writer splices
    /// `pub ` here; see `Gen.emitUnit` for why `text` cannot carry it itself.
    unit_fn: []const u32 = &.{},
    /// Offset in `text` just past each unit's declaration.
    unit_hi: []const u32 = &.{},
    /// File-scope prologue every `u/<key>.zig` needs. A unit file is a
    /// separate Zig file and Zig has no textual include, so nothing
    /// `device.zig` declares is in its scope. Arena-owned; empty when `names` is.
    prelude: []const u8 = "",
    /// `h.zig`: the §4.3/§4.5 helper kernels, public, for the unit files to
    /// alias. device.zig keeps a private copy inline because `text` must stay
    /// a valid stand-alone device and `contract.rejectStrayPubDecls` forbids
    /// publishing them there. Arena-owned; empty when `names` is.
    helpers: []const u8 = "",
    /// How many chunks `setup` was emitted as (`setup_chunks.n`); 0 when it
    /// is one function. A split build compiles each in its own object.
    setup_chunks: u32 = 0,
};

/// Writes `<work_dir>/{shim.zig, device.zig, h.zig, u/<key>.zig ...}` and
/// returns how many files changed on disk; an unchanged device writes 0.
/// A split `device` gets one file per emitted unit (`zig`'s cache unit is the
/// file) and `device.zig` imports them by their stable names; a single
/// `device` is written as `device.zig` alone. Deletes `u/*.zig` files no
/// longer emitted. Creates `work_dir` if absent. Asserts that a split
/// `device` keeps `Output`'s invariant: one row per unit in every
/// column, and ranges that tile `text` in order.
pub fn writeTree(io: Io, gpa: Allocator, o: Options, device: Output) !usize {
    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, o.work_dir);
    var dir = try cwd.openDir(io, o.work_dir, .{});
    defer dir.close(io);

    var writes: usize = 0;

    const shim_text = try shim.device(gpa, o.name, o.engine != null);
    defer gpa.free(shim_text);
    if (try writeIfChanged(io, gpa, dir, "shim.zig", shim_text)) writes += 1;

    if (device.names.len == 0) {
        // No `names`: the un-split form, one `device.zig` and no `u/`.
        assert(device.unit_lo.len == 0);
        assert(device.unit_hi.len == 0);
        if (try writeIfChanged(io, gpa, dir, "device.zig", device.text)) writes += 1;
        return writes;
    }

    if (try writeIfChanged(io, gpa, dir, "h.zig", device.helpers)) writes += 1;

    try dir.createDirPath(io, unit_dir);
    var udir = try dir.openDir(io, unit_dir, .{ .iterate = true });
    defer udir.close(io);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    assert(device.unit_lo.len == device.names.len);
    assert(device.unit_fn.len == device.names.len);
    assert(device.unit_hi.len == device.names.len);
    for (device.names, device.unit_lo, device.unit_fn, device.unit_hi, 0..) |name, lo, fn_at, hi, i| {
        assert(name.len > 0);
        assert(lo <= fn_at);
        assert(fn_at < hi);
        assert(hi <= device.text.len);
        if (i > 0) assert(lo == device.unit_hi[i - 1]);
        body.clearRetainingCapacity();
        try body.appendSlice(gpa, device.prelude);
        // `pub ` goes in here, not in the emission: `device.text` is also the
        // stand-alone `--emit-zig` form, where `contract.rejectStrayPubDecls`
        // allows only contract-recognized names to be public.
        try body.appendSlice(gpa, device.text[lo..fn_at]);
        if (!std.mem.startsWith(u8, device.text[fn_at..], "pub ")) try body.appendSlice(gpa, "pub ");
        try body.appendSlice(gpa, device.text[fn_at..hi]);
        const p = try gpa.print("{s}.zig", .{name});
        defer gpa.free(p);
        if (try writeIfChanged(io, gpa, udir, p, body.items)) writes += 1;
    }

    // device.zig = prologue ++ one import per unit ++ dispatcher tail. The
    // ranges tile (`Output`'s invariant), so those three pieces are the
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
/// than one core. The host's own enum (`contract.DevicePart`), so the tags
/// the shims write are the ones its `exportDevicePart` takes.
pub const Part = @import("contract").DevicePart;

/// Emitted device text from which `Options.split = null` splits an LLVM
/// build into `Part`s. Measured 2026-10-01 (stripped, slots grouped): the
/// split leaves eval's instructions per call unchanged but moves code, and
/// that layout shift was neutral to favourable on bsim4va (818 KB), psp103
/// (1.4 MB) and coupled_ltra (5.8 MB) yet cost txl (590 KB) +47% eval cycles
/// at identical instructions; the threshold sits between them. Each extra
/// process also costs fixed std/process work, so mos1 (125 KB) gains nothing.
const split_min_bytes: usize = 768 * 1024;

/// Whether `compileRelease` builds `device` as `Part`s.
pub fn splits(o: Options, device: Output) bool {
    return o.split orelse (o.backend == .llvm and device.text.len >= split_min_bytes);
}

/// Returns `zig build-lib --listen=- ... -Mroot=shim.zig -Mdevice=... -M<support>...`
/// allocated in `arena`, in `o.modules` order, or for a `part` the
/// `zig build-obj` of `shim_<piece>.zig` into `<name>_<piece>.o`, `piece`
/// a `Part` or a setup chunk (`pieceNames`). As in
/// `std.Build.Step.Compile.getZigArgs`, each `--dep` applies to the next `-M`.
fn buildArgv(arena: Allocator, o: Options, part: ?[]const u8) ![]const []const u8 {
    if (part) |p| assert(p.len > 0);
    var a: std.ArrayList([]const u8) = .empty;

    try a.appendSlice(arena, &.{
        o.zig_exe,
        if (part == null) "build-lib" else "build-obj",
        "--listen=-",
        // An object linked into a shared library must be position independent.
        if (part == null) "-dynamic" else "-fPIC",
        try arena.print("-O{s}", .{@tagName(o.optimize)}),
        "--name",
        if (part) |p| try arena.print("{s}_{s}", .{ o.name, p }) else o.name,
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
        try arena.print("-Mroot={s}", .{
            try std.fs.path.join(arena, &.{ o.work_dir, if (part) |p| try shim.fileName(arena, p) else "shim.zig" }),
        }),
    });

    // device.zig imports `contract`.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.append(arena, try arena.print("-Mdevice={s}", .{
        try std.fs.path.join(arena, &.{ o.work_dir, "device.zig" }),
    }));

    for (o.modules) |m| {
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try arena.print("-M{s}={s}", .{ m.name, m.root }));
    }

    // The program, its subcommand and `--listen=-` lead: `Server` speaks to it.
    assert(a.items.len >= 3);
    assert(a.items[0].ptr == o.zig_exe.ptr);
    return a.items;
}

/// The pieces of a split build: the `Part`s, then `setup`'s chunks as
/// `setup<k>`. Arena-owned.
fn pieceNames(arena: Allocator, chunks: u32) ![]const []const u8 {
    const parts = comptime std.enums.values(Part);
    const names = try arena.alloc([]const u8, parts.len + chunks);
    for (names[0..parts.len], parts) |*n, p| n.* = @tagName(p);
    for (names[parts.len..], 0..) |*n, k| n.* = try arena.print("setup{d}", .{k});
    assert(names.len == parts.len + chunks);
    return names;
}

/// `zig build-lib --listen=- -dynamic` over the parts' objects. The link
/// takes `-O` and `-fstrip` for the compiler_rt it adds.
fn linkArgv(arena: Allocator, o: Options, objs: []const []const u8) ![]const []const u8 {
    assert(objs.len > 0);
    const head = [_][]const u8{
        o.zig_exe,
        "build-lib",
        "--listen=-",
        "-dynamic",
        // No Zig root module brings start.zig's `_DllMainCRTStartup`, which
        // a Windows DLL otherwise needs as its entry point.
        "-fno-entry",
        try arena.print("-O{s}", .{@tagName(o.optimize)}),
        "--name",
        o.name,
        "--cache-dir",
        try std.fs.path.join(arena, &.{ o.work_dir, ".zig-cache" }),
    };
    const stripped = strip(o.optimize, o.debug_info);
    var a: std.ArrayList([]const u8) = try .initCapacity(arena, head.len + @intFromBool(stripped) + objs.len + @intFromBool(o.engine != null));
    a.appendSliceAssumeCapacity(&head);
    if (stripped) a.appendAssumeCapacity("-fstrip");
    a.appendSliceAssumeCapacity(objs);
    if (o.engine) |e| a.appendAssumeCapacity(e);
    std.debug.assert(a.items.len == a.capacity);
    return a.items;
}

/// The prebuilt engine object, or the compiler's report.
const EngineResult = union(enum) {
    /// The object's path in `cache_dir`, owned by `gpa`.
    ok: []u8,
    failed: std.zig.ErrorBundle,

    /// Frees the payload with the `gpa` `buildEngine` was given and
    /// invalidates `self`.
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
/// engine's symbol names carry its layout hash (`engine.tag`). Caller owns
/// the result and frees it with `EngineResult.deinit` and `gpa`. Fails as
/// `compileRelease` does.
pub fn buildEngine(gpa: Allocator, io: Io, o: Options, cache_dir: []const u8) !EngineResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd: Io.Dir = .cwd();
    try cwd.createDirPath(io, cache_dir);
    // Named by its content, so it is written once and never changes.
    const name = comptime std.fmt.comptimePrint("vera_engine_{x:0>16}.zig", .{std.hash.Wyhash.hash(0, shim.engine_root)});
    const root = try std.fs.path.join(arena, &.{ cache_dir, name });
    cwd.access(io, root, .{}) catch {
        // Atomic: a concurrent `vera` never reads half the file.
        var af = try cwd.createFileAtomic(io, root, .{ .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, shim.engine_root);
        try af.replace(io);
    };

    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(arena, &.{
        o.zig_exe,
        "build-obj",
        "--listen=-",
        "-fPIC",
        try arena.print("-O{s}", .{@tagName(o.optimize)}),
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
    try a.appendSlice(arena, &.{ "--dep", "sim", try arena.print("-Mroot={s}", .{root}) });
    for (o.modules) |m| if (!std.mem.eql(u8, m.name, "dyn")) {
        for (m.deps) |d| try a.appendSlice(arena, &.{ "--dep", d });
        try a.append(arena, try arena.print("-M{s}={s}", .{ m.name, m.root }));
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
    device: Output,
    generation: u32,
) !Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = comptime std.enums.values(Part);
    const split = splits(o, device);
    const pieces = try pieceNames(arena, if (split) device.setup_chunks else 0);
    if (!split) assert(pieces.len == parts.len);

    // Spawned before the tree is written, so the compilers start up while
    // VerA writes.
    const servers = try arena.alloc(Server, if (split) pieces.len else 1);
    assert(servers.len <= pieces.len);
    if (split) assert(servers.len == pieces.len);
    var started: usize = 0;
    defer for (servers[0..started]) |*s| s.close(io);
    for (servers, pieces[0..servers.len]) |*s, p| {
        try s.spawn(io, arena, try buildArgv(arena, o, if (split) p else null));
        started += 1;
    }
    assert(started == servers.len);

    _ = try writeTree(io, gpa, o, device);
    if (split) {
        var dir = try Io.Dir.cwd().openDir(io, o.work_dir, .{});
        defer dir.close(io);
        for (pieces, 0..) |p, i| {
            if (i >= parts.len) assert(i - parts.len < device.setup_chunks);
            const text = if (i < parts.len)
                try shim.part(arena, o.name, parts[i], o.engine != null, device.setup_chunks != 0)
            else
                try shim.chunk(arena, @intCast(i - parts.len), o.engine != null);
            _ = try writeIfChanged(io, gpa, dir, try shim.fileName(arena, p), text);
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

    // Each piece analyses the whole device, so a device error arrives once
    // per piece; the first piece's report is the one returned.
    const objs = try arena.alloc([]const u8, pieces.len);
    var failed: ?std.zig.ErrorBundle = null;
    errdefer if (failed) |*b| b.deinit(gpa);
    var cache_hit = true;
    for (servers, pieces, objs) |*s, p, *obj| switch (try s.wait(gpa)) {
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
                o.work_dir,                                                                ".zig-cache", "o", &Cache.binToHex(u.digest),
                try arena.print("{s}_{s}{s}", .{ o.name, p, t.ofmt.fileExt(t.cpu.arch) }),
            });
        },
    };
    if (failed) |b| {
        failed = null;
        return .{ .failed = b };
    }

    // One object per `Part` at least (`pieceNames`); `linkArgv` itself
    // only formats, and its test links two.
    assert(objs.len >= std.enums.values(Part).len);
    var link: Server = undefined;
    try link.spawn(io, arena, try linkArgv(arena, o, objs));
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

/// `name` as `publish` names this target's library: `testdev.1` is
/// `libtestdev.1.so` on Linux and `testdev.1.dll` on Windows.
fn testLib(comptime name: []const u8) []const u8 {
    const t = &builtin.target;
    return comptime t.libPrefix() ++ name ++ t.dynamicLibSuffix();
}

/// Copies the cache output to a generation-stamped path so the host dlopens a
/// fresh inode; a hardlink would share the cache entry's inode. Caller owns
/// the returned path.
fn publish(io: Io, gpa: Allocator, o: Options, digest: Cache.BinDigest, generation: u32) ![]u8 {
    const t = &builtin.target;
    const lib_name = try gpa.print("{s}{s}{s}", .{
        t.libPrefix(), o.name, t.dynamicLibSuffix(),
    });
    defer gpa.free(lib_name);

    const src = try std.fs.path.join(gpa, &.{
        o.work_dir, ".zig-cache", "o", &Cache.binToHex(digest), lib_name,
    });
    defer gpa.free(src);

    const dst = try gpa.print("{s}{c}{s}{s}.{d}{s}", .{
        o.work_dir, std.fs.path.sep, t.libPrefix(),
        o.name,     generation,      t.dynamicLibSuffix(),
    });
    errdefer gpa.free(dst);

    const cwd: Io.Dir = .cwd();
    cwd.copyFile(src, cwd, dst, io, .{}) catch return error.NoArtifact;
    return dst;
}

test "Backend.auto is self-hosted only for Debug on x86_64" {
    try std.testing.expectEqual(Backend.self_hosted, Backend.auto(.debug, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.fast, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .aarch64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.debug, .nvptx64));
}

test "an optimized build strips unless debug information is asked for" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Case = struct { optimize: std.lang.Optimize, debug_info: bool, strip: bool };
    for ([_]Case{
        .{ .optimize = .fast, .debug_info = false, .strip = true },
        .{ .optimize = .small, .debug_info = false, .strip = true },
        .{ .optimize = .fast, .debug_info = true, .strip = false },
        .{ .optimize = .safe, .debug_info = false, .strip = false },
        .{ .optimize = .debug, .debug_info = false, .strip = false },
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
        .optimize = .debug,
        .backend = .self_hosted,
        .modules = &mods,
    };

    try std.testing.expectEqual(layoutHash(base), layoutHash(base));

    var o = base;
    o.optimize = .fast;
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

fn splitOutput(names: []const []const u8) Output {
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
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    const o: Options = .{
        .work_dir = work,
        .name = "testdev",
        .optimize = .debug,
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
    try std.testing.expect(std.mem.find(u8, dev, "const unit_a = @import(\"u/unit_a.zig\").unit_a;\n") != null);
    try std.testing.expect(std.mem.find(u8, dev, "return y * k2;") == null);

    // A vanished unit takes its file with it: device.zig plus the delete.
    // `u/unit_a.zig` is unchanged, so it is not rewritten.
    const shrunk: Output = .{
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
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
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
        .optimize = .debug,
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
            try std.testing.expect(std.mem.endsWith(u8, a.so_path, testLib("testdev.1")));
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
            try std.testing.expect(std.mem.endsWith(u8, a.so_path, testLib("testdev.2")));
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
        .ok => |a| try std.testing.expect(std.mem.endsWith(u8, a.so_path, testLib("testdev.5"))),
    }
}

test "buildEngine reuses its object only while every key component is unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
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
    var o: Options = .{ .work_dir = work, .name = "unused", .optimize = .debug, .backend = .self_hosted, .modules = &mods };

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

    o.optimize = .small;
    o.backend = .llvm;
    const small = try Build.path(o, cache);
    defer gpa.free(small);
    try std.testing.expect(!std.mem.eql(u8, edited, small));

    // ... and the change undone finds the first object again.
    o.optimize = .debug;
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
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
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
            .optimize = .fast,
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
        var lib = try @import("dynlib").DynLib.open(so);
        defer lib.close();
        const k = lib.lookup(*const fn () callconv(.c) f64, "arp_k") orelse return error.MissingSymbol;
        const eval = lib.lookup(*const fn (f64) callconv(.c) f64, "arp_eval") orelse return error.MissingSymbol;
        try std.testing.expectEqual(@as(f64, 2.0), k());
        try std.testing.expectEqual(@as(f64, 6.0), eval(3.0));
    }

    // The default splits only a large LLVM build.
    const base: Options = .{ .work_dir = work, .name = "d", .optimize = .fast, .backend = .llvm, .modules = &.{} };
    try std.testing.expect(!splits(base, .{ .text = dev }));
    const big = try gpa.alloc(u8, split_min_bytes);
    defer gpa.free(big);
    try std.testing.expect(splits(base, .{ .text = big }));
    var native = base;
    native.backend = .self_hosted;
    try std.testing.expect(!splits(native, .{ .text = big }));
}

test "Backend.auto keeps LLVM for every optimized mode" {
    for ([_]std.lang.Optimize{ .safe, .fast, .small }) |m|
        try std.testing.expectEqual(Backend.llvm, Backend.auto(m, .x86_64));
}

test strip {
    // Only fast and small drop safety, and only they strip; debug_info vetoes.
    for (std.enums.values(std.lang.Optimize)) |m| {
        try std.testing.expect(!strip(m, true));
        try std.testing.expectEqual(m == .fast or m == .small, strip(m, false));
    }
}

test fileStem {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A short plain name is itself, not a copy.
    const plain: []const u8 = "nmos_1";
    try std.testing.expect((try fileStem(a, plain)).ptr == plain.ptr);
    const max: [128]u8 = @splat('a');
    try std.testing.expectEqualStrings(&max, try fileStem(a, &max));

    // One byte longer: its first 64 bytes, `-`, 16 hex digits.
    const over: [129]u8 = @splat('a');
    const s = try fileStem(a, &over);
    try std.testing.expectEqual(@as(usize, 64 + 1 + 16), s.len);
    try std.testing.expectEqualStrings(over[0..64], s[0..64]);
    try std.testing.expectEqual(@as(u8, '-'), s[64]);
    for (s[65..]) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));

    // Not plain: the plain prefix, so `a.b` and `a,b` share `a-` and differ
    // only in the hash; a name with no plain prefix starts at the `-`.
    const dot = try fileStem(a, "a.b");
    const comma = try fileStem(a, "a,b");
    try std.testing.expectEqual(@as(usize, 1 + 1 + 16), dot.len);
    try std.testing.expect(std.mem.startsWith(u8, dot, "a-"));
    try std.testing.expect(!std.mem.eql(u8, dot, comma));
    try std.testing.expectEqualStrings(dot, try fileStem(a, "a.b"));
    try std.testing.expectEqual(@as(usize, 17), (try fileStem(a, ".x")).len);

    // A hashed stem has a `-`; a kept one cannot.
    try std.testing.expect(std.mem.findScalar(u8, try fileStem(a, plain), '-') == null);
    try std.testing.expect(std.mem.findScalar(u8, dot, '-') != null);
}

test "layoutHash: dependencies count, field boundaries count, placement does not" {
    const base_mods = [_]Module{
        .{ .name = "contract", .root = "c.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };
    const base: Options = .{ .work_dir = "w", .name = "dev", .optimize = .debug, .backend = .llvm, .modules = &base_mods };
    const h = layoutHash(base);

    // A dropped dependency is a different graph.
    const no_dep = [_]Module{ base_mods[0], .{ .name = "dyn", .root = "d.zig" } };
    var o = base;
    o.modules = &no_dep;
    try std.testing.expect(layoutHash(o) != h);

    // The same bytes split differently between name and root, or between a
    // dependency and the next module, are different graphs.
    const ab_c = [_]Module{.{ .name = "ab", .root = "c" }};
    const a_bc = [_]Module{.{ .name = "a", .root = "bc" }};
    o.modules = &ab_c;
    const h_ab_c = layoutHash(o);
    o.modules = &a_bc;
    try std.testing.expect(layoutHash(o) != h_ab_c);
    const dep_b = [_]Module{.{ .name = "a", .root = "r", .deps = &.{"b"} }};
    const then_b = [_]Module{ .{ .name = "a", .root = "r" }, .{ .name = "b", .root = "" } };
    o.modules = &dep_b;
    const h_dep_b = layoutHash(o);
    o.modules = &then_b;
    try std.testing.expect(layoutHash(o) != h_dep_b);

    // `Options` documents these as unhashed: none changes a type layout.
    o = base;
    o.zig_exe = "/opt/zig/zig";
    o.debug_info = true;
    o.split = true;
    o.engine = "vera_engine.o";
    try std.testing.expectEqual(h, layoutHash(o));
}

test "splits: an explicit choice wins over the size rule" {
    const tiny: Output = .{ .text = "x" };
    var o: Options = .{ .work_dir = "w", .name = "d", .optimize = .fast, .backend = .self_hosted, .modules = &.{}, .split = true };
    try std.testing.expect(splits(o, tiny));
    o.backend = .llvm;
    o.split = false;
    const huge = try std.testing.allocator.alloc(u8, split_min_bytes);
    defer std.testing.allocator.free(huge);
    try std.testing.expect(!splits(o, .{ .text = huge }));
    // One byte under the threshold stays whole.
    o.split = null;
    try std.testing.expect(!splits(o, .{ .text = huge[1..] }));
}

/// Fails unless `got` is `want`, element by element.
fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    for (want, 0..) |w, i| {
        if (i >= got.len) return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(w, got[i]);
    }
    try std.testing.expectEqual(want.len, got.len);
}

const sep = std.fs.path.sep_str;

test buildArgv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]Module{
        .{ .name = "contract", .root = "c.zig" },
        .{ .name = "dyn", .root = "d.zig", .deps = &.{"contract"} },
    };

    // The whole library: every support module is a dependency of the root
    // and of the device, and each `--dep` applies to the `-M` after it.
    const whole = [_][]const u8{
        "zig",
        "build-lib",
        "--listen=-",
        "-dynamic",
        "-Ofast",
        "--name",
        "dev",
        "--cache-dir",
        "w" ++ sep ++ ".zig-cache",
        "-fllvm",
        "-fstrip",
        "eng.o",
        "--dep",
        "contract",
        "--dep",
        "dyn",
        "--dep",
        "device",
        "-Mroot=w" ++ sep ++ "shim.zig",
        "--dep",
        "contract",
        "--dep",
        "dyn",
        "-Mdevice=w" ++ sep ++ "device.zig",
        "-Mcontract=c.zig",
        "--dep",
        "contract",
        "-Mdyn=d.zig",
    };
    try expectArgv(&whole, try buildArgv(a, .{
        .work_dir = "w",
        .name = "dev",
        .optimize = .fast,
        .backend = .llvm,
        .modules = &mods,
        .engine = "eng.o",
    }, null));

    // One part: an object, position independent, named for its piece, rooted
    // at its own shim, with no engine (only the link takes it). Self-hosted
    // adds `-fincremental`; Debug keeps its symbols.
    const piece = [_][]const u8{
        "zig",
        "build-obj",
        "--listen=-",
        "-fPIC",
        "-Odebug",
        "--name",
        "dev_setup",
        "--cache-dir",
        "w" ++ sep ++ ".zig-cache",
        "-fno-llvm",
        "-fno-lld",
        "-fincremental",
        "--dep",
        "device",
        "-Mroot=w" ++ sep ++ "shim_setup.zig",
        "-Mdevice=w" ++ sep ++ "device.zig",
    };
    try expectArgv(&piece, try buildArgv(a, .{
        .work_dir = "w",
        .name = "dev",
        .optimize = .debug,
        .backend = .self_hosted,
        .modules = &.{},
        .engine = "eng.o",
    }, "setup"));
}

test linkArgv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const o: Options = .{ .work_dir = "w", .name = "dev", .optimize = .small, .backend = .llvm, .modules = &.{}, .engine = "eng.o" };
    const want = [_][]const u8{
        "zig",
        "build-lib",
        "--listen=-",
        "-dynamic",
        "-fno-entry",
        "-Osmall",
        "--name",
        "dev",
        "--cache-dir",
        "w" ++ sep ++ ".zig-cache",
        "-fstrip",
        "a.o",
        "b.o",
        "eng.o",
    };
    try expectArgv(&want, try linkArgv(arena.allocator(), o, &.{ "a.o", "b.o" }));
}

test pieceNames {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try expectArgv(&.{ "setup", "state", "eval" }, try pieceNames(arena.allocator(), 0));
    try expectArgv(&.{ "setup", "state", "eval", "setup0", "setup1" }, try pieceNames(arena.allocator(), 2));
}

test "writeTree writes an un-split device alone, and rewrites only what changed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    var o: Options = .{ .work_dir = work, .name = "testdev", .optimize = .debug, .backend = .self_hosted, .modules = &.{} };

    // shim.zig + device.zig, then nothing.
    try std.testing.expectEqual(@as(usize, 2), try writeTree(io, gpa, o, .{ .text = "abcdef" }));
    try std.testing.expectEqual(@as(usize, 0), try writeTree(io, gpa, o, .{ .text = "abcdef" }));

    // A text that is a prefix of the file on disk is still a change.
    try std.testing.expectEqual(@as(usize, 1), try writeTree(io, gpa, o, .{ .text = "abc" }));
    const dev = try tmp.dir.readFileAlloc(io, "device.zig", gpa, .limited(64));
    defer gpa.free(dev);
    try std.testing.expectEqualStrings("abc", dev);

    // Linking an engine changes the shim alone.
    o.engine = "eng.o";
    try std.testing.expectEqual(@as(usize, 1), try writeTree(io, gpa, o, .{ .text = "abc" }));
    const shim_text = try tmp.dir.readFileAlloc(io, "shim.zig", gpa, .limited(4096));
    defer gpa.free(shim_text);
    try std.testing.expect(std.mem.find(u8, shim_text, "vera_prebuilt_engine") != null);

    // No split, so no helpers file and no unit directory.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "h.zig", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u", .{}));
}

test "writeTree keeps a unit's doc comment and an existing `pub`, and prunes only stale .zig files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);
    const o: Options = .{ .work_dir = work, .name = "testdev", .optimize = .debug, .backend = .self_hosted, .modules = &.{} };

    // unit_a: a doc comment before `fn` (lo < fn); unit_b: already `pub`.
    const doc = "/// a\n";
    const fn_a = "fn unit_a(y: f64) f64 {\n    return y;\n}\n";
    const pub_b = "pub fn unit_b(y: f64) f64 {\n    return y;\n}\n";
    const lo_b = split_prologue.len + doc.len + fn_a.len;
    const out: Output = .{
        .text = split_prologue ++ doc ++ fn_a ++ pub_b ++ split_tail,
        .names = &.{ "unit_a", "unit_b" },
        .unit_lo = &.{ split_prologue.len, lo_b },
        .unit_fn = &.{ split_prologue.len + doc.len, lo_b },
        .unit_hi = &.{ lo_b, lo_b + pub_b.len },
        .prelude = split_prelude,
    };
    try std.testing.expectEqual(@as(usize, 5), try writeTree(io, gpa, o, out));

    const a = try tmp.dir.readFileAlloc(io, "u/unit_a.zig", gpa, .limited(4096));
    defer gpa.free(a);
    try std.testing.expectEqualStrings(split_prelude ++ doc ++ "pub " ++ fn_a, a);
    const b = try tmp.dir.readFileAlloc(io, "u/unit_b.zig", gpa, .limited(4096));
    defer gpa.free(b);
    try std.testing.expectEqualStrings(split_prelude ++ pub_b, b);

    // A stale unit goes; a file that is not `.zig`, and a directory, stay.
    try tmp.dir.writeFile(io, .{ .sub_path = "u/old.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "u/notes.txt", .data = "" });
    try tmp.dir.createDirPath(io, "u/dir.zig");
    try std.testing.expectEqual(@as(usize, 1), try writeTree(io, gpa, o, out));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "u/old.zig", .{}));
    _ = try tmp.dir.statFile(io, "u/notes.txt", .{});
    _ = try tmp.dir.statFile(io, "u/dir.zig", .{});
}

test "a split build that fails returns one report and leaks the others' none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gpa.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(work);

    try tmp.dir.writeFile(io, .{ .sub_path = "contract.zig", .data = "pub const k: f64 = 2.0;\n" });
    // Every part reaches `eval`, so every piece fails and two reports are
    // dropped (`std.testing.allocator` sees a leak if one is not freed).
    try tmp.dir.writeFile(io, .{ .sub_path = "dyn.zig", .data =
        \\pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
        \\    _ = name;
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\pub fn exportDevicePart(comptime D: type, comptime name: []const u8, comptime part: @TypeOf(.setup)) void {
        \\    _ = .{ name, part };
        \\    @export(&D.eval, .{ .name = "arp_eval" });
        \\}
        \\
    });
    const mods = [_]Module{
        .{ .name = "contract", .root = try std.fs.path.join(gpa, &.{ work, "contract.zig" }) },
        .{ .name = "dyn", .root = try std.fs.path.join(gpa, &.{ work, "dyn.zig" }) },
    };
    defer for (mods) |m| gpa.free(m.root);
    const o: Options = .{ .work_dir = work, .name = "faildev", .optimize = .fast, .backend = .llvm, .modules = &mods, .split = true };
    const dev = "pub fn eval() callconv(.c) void { @compileError(\"boom\"); }\n";
    var r = compileRelease(gpa, io, o, .{ .text = dev }, 1) catch |err| switch (err) {
        error.CompilerGone => return error.SkipZigTest,
        else => return err,
    };
    defer r.deinit(gpa);
    try std.testing.expect(r == .failed);
    try std.testing.expect(r.failed.errorMessageCount() > 0);
}
