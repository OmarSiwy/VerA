//! Build orchestration: device.zig in, a generation-versioned lib<name>.so plus
//! its layout hash out (§8.3 device-side ABI). VerA produces the artifact; the
//! host owns dlopen, dlclose and state reset, and a fresh path per generation
//! gives it a fresh inode. Builds run `zig build-lib --listen=-` (the compiler
//! server protocol; the 0.16 build runner has no `--listen`), either resident
//! and `-fincremental` or cold (`compileRelease`). No build.zig is generated.

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
/// absolute. Strings are borrowed and must outlive the `ResidentChild`.
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
/// borrowed and must outlive any `ResidentChild` built from them.
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
    /// `pub fn exportDevice(comptime D: type, comptime name: []const u8) void`.
    /// Order is hashed into `layout_hash` and fixes argv order.
    modules: []const Module,
    zig_exe: []const u8 = "zig",
};

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
/// host's C ABI. It depends only on `name`, so rebuilds never dirty it.
fn shimSource(gpa: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\// GENERATED BY VerA — DO NOT EDIT.
        \\comptime {{
        \\    @import("dyn").exportDevice(@import("device"), "{s}");
        \\}}
        \\
    , .{name});
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

    const shim = try shimSource(gpa, o.name);
    defer gpa.free(shim);
    if (try writeIfChanged(io, gpa, dir, "shim.zig", shim)) writes += 1;

    if (device.names.len == 0) {
        // `Output.single`: no split.
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

/// Returns `zig build-lib --listen=- ... -Mroot=shim.zig -Mdevice=... -M<support>...`
/// allocated in `arena`, in `o.modules` order. As in
/// `std.Build.Step.Compile.getZigArgs`, each `--dep` applies to the next `-M`.
fn buildArgv(arena: Allocator, o: Options) ![]const []const u8 {
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

    switch (o.backend) {
        // The only backend that patches in place, so the only one where
        // `-fincremental` pays.
        .self_hosted => try a.appendSlice(arena, &.{ "-fno-llvm", "-fno-lld", "-fincremental" }),
        .llvm => try a.append(arena, "-fllvm"),
    }

    // root = shim.zig: imports `device` plus every support module.
    for (o.modules) |m| try a.appendSlice(arena, &.{ "--dep", m.name });
    try a.appendSlice(arena, &.{
        "--dep",
        "device",
        try std.fmt.allocPrint(arena, "-Mroot={s}", .{
            try std.fs.path.join(arena, &.{ o.work_dir, "shim.zig" }),
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

/// A long-lived `zig build-lib --listen=-` child. Spawn once per
/// optimize/backend pair and reuse it across edits: its incremental state
/// lives only in the child's memory, so killing it loses that state.
pub const ResidentChild = struct {
    io: Io,
    opts: Options,
    /// Owns argv and every string in it.
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    child: std.process.Child,
    /// Backing store for `stdout`; owned by `arena`.
    stdout_buf: []u8,
    stdout: Io.File.Reader,
    layout_hash: u64,

    /// Steady-state stdout buffer; larger message bodies go through `readAlloc`.
    const buf_len = 64 * 1024;

    /// Spawns the child. The first build is cold; later `rebuild`s reuse the
    /// warm state. `o` and every string it points at must outlive the result.
    /// Fails with `error.CompilerGone` if `o.zig_exe` cannot be spawned.
    pub fn spawn(gpa: Allocator, io: Io, o: Options) !ResidentChild {
        var self: ResidentChild = .{
            .io = io,
            .opts = o,
            .arena = .init(gpa),
            .argv = &.{},
            .child = undefined,
            .stdout_buf = &.{},
            .stdout = undefined,
            .layout_hash = layoutHash(o),
        };
        errdefer self.arena.deinit();

        const arena = self.arena.allocator();
        self.argv = try buildArgv(arena, o);
        self.stdout_buf = try arena.alloc(u8, buf_len);

        try self.start();
        return self;
    }

    /// Launches the compiler; also valid after the child has died.
    fn start(self: *ResidentChild) !void {
        self.child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Compiler panics reach the terminal, and an unread stderr pipe
            // cannot fill and deadlock the update loop.
            .stderr = .inherit,
        }) catch return error.CompilerGone;
        self.stdout = self.child.stdout.?.readerStreaming(self.io, self.stdout_buf);
    }

    fn stop(self: *ResidentChild) void {
        if (self.child.stdin) |stdin| {
            self.send(.exit) catch {};
            stdin.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {
            self.child.kill(self.io);
        };
    }

    /// Asks the child to exit, reaps it and frees the argv.
    pub fn deinit(self: *ResidentChild) void {
        self.stop();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Writes `device` into the tree (`writeTree`), asks the child for one
    /// update and returns the result, which the caller owns. Builds happen
    /// only here; nothing watches the filesystem. A compile error keeps the
    /// child alive, since its warm state stays valid.
    pub fn rebuild(
        self: *ResidentChild,
        gpa: Allocator,
        device: codegen.Output,
        generation: u32,
    ) !Result {
        _ = try writeTree(self.io, gpa, self.opts, device);
        return self.update(gpa, generation) catch |err| switch (err) {
            // ponytail: zig 0.16.0's resident compiler can crash on a later
            // `update` after inputs change; respawn and rebuild cold, as
            // std.Build.Step.evalZigProcess does. Delete this arm once the
            // compiler survives repeated updates.
            error.CompilerGone => blk: {
                self.stop();
                try self.start();
                break :blk try self.update(gpa, generation);
            },
            else => err,
        };
    }

    fn send(self: *ResidentChild, tag: ClientMsg.Tag) !void {
        const stdin = self.child.stdin orelse return error.CompilerGone;
        var w = stdin.writer(self.io, &.{});
        w.interface.writeStruct(ClientMsg.Header{ .tag = tag, .bytes_len = 0 }, .little) catch
            return error.CompilerGone;
    }

    /// Runs one request/response round of the compiler server protocol. An
    /// `error_bundle` message, possibly empty, ends the update.
    fn update(self: *ResidentChild, gpa: Allocator, generation: u32) !Result {
        try self.send(.update);

        const r = &self.stdout.interface;
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

        const d = digest orelse return error.NoArtifact;
        return .{ .ok = .{
            .so_path = try self.publish(gpa, d, generation),
            .layout_hash = self.layout_hash,
            .generation = generation,
            .cache_hit = cache_hit,
        } };
    }

    /// Copies the cache output to a generation-stamped path so the host
    /// dlopens a fresh inode; a hardlink would share the cache entry's inode.
    /// Caller owns the returned path.
    fn publish(
        self: *ResidentChild,
        gpa: Allocator,
        digest: Cache.BinDigest,
        generation: u32,
    ) ![]u8 {
        const t = &builtin.target;
        const lib_name = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
            t.libPrefix(), self.opts.name, t.dynamicLibSuffix(),
        });
        defer gpa.free(lib_name);

        const src = try std.fs.path.join(gpa, &.{
            self.opts.work_dir, ".zig-cache", "o", &Cache.binToHex(digest), lib_name,
        });
        defer gpa.free(src);

        const dst = try std.fmt.allocPrint(gpa, "{s}{c}{s}{s}.{d}{s}", .{
            self.opts.work_dir, std.fs.path.sep, t.libPrefix(),
            self.opts.name,     generation,      t.dynamicLibSuffix(),
        });
        errdefer gpa.free(dst);

        const cwd: Io.Dir = .cwd();
        cwd.copyFile(src, cwd, dst, self.io, .{}) catch return error.NoArtifact;
        return dst;
    }
};

/// Builds once, cold, with a child that is reaped before returning. Caller
/// owns the `Result`.
pub fn compileRelease(
    gpa: Allocator,
    io: Io,
    o: Options,
    device: codegen.Output,
    generation: u32,
) !Result {
    var child = try ResidentChild.spawn(gpa, io, o);
    defer child.deinit();
    return child.rebuild(gpa, device, generation);
}

test "Backend.auto is self-hosted only for Debug on x86_64" {
    try std.testing.expectEqual(Backend.self_hosted, Backend.auto(.Debug, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.ReleaseFast, .x86_64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.Debug, .aarch64));
    try std.testing.expectEqual(Backend.llvm, Backend.auto(.Debug, .nvptx64));
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

test "resident child builds, versions and rebuilds a device" {
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

    var child = ResidentChild.spawn(gpa, io, o) catch |err| switch (err) {
        // No `zig` on PATH in this environment: nothing to assert.
        error.CompilerGone => return error.SkipZigTest,
        else => return err,
    };
    defer child.deinit();

    const dev_v1 =
        \\const contract = @import("contract");
        \\pub fn eval(x: f64) callconv(.c) f64 { return x * contract.k; }
        \\
    ;
    var r1 = try child.rebuild(gpa, .single(dev_v1), 1);
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
    var r2 = try child.rebuild(gpa, .single(dev_v2), 2);
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

    // A broken unit is reported as diagnostics, and the child survives it.
    var r3 = try child.rebuild(gpa, .single("pub fn eval() void { @compileError(\"boom\"); }\n"), 3);
    defer r3.deinit(gpa);
    try std.testing.expect(r3 == .failed);

    var r4 = try child.rebuild(gpa, .single(dev_v2), 4);
    defer r4.deinit(gpa);
    try std.testing.expect(r4 == .ok);

    // The split form compiles: `device.zig` and the unit files import each
    // other, which is legal Zig.
    var r5 = try child.rebuild(gpa, splitOutput(&.{ "unit_a", "unit_b" }), 5);
    defer r5.deinit(gpa);
    switch (r5) {
        .failed => |b| {
            b.renderToStderr(io, .{}, .off) catch {};
            return error.UnexpectedBuildFailure;
        },
        .ok => |a| try std.testing.expect(std.mem.endsWith(u8, a.so_path, "libtestdev.5.so")),
    }
}
