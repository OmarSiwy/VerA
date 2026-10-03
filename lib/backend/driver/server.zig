//! One `zig ... --listen=-` child and the compiler server protocol over its
//! stdin/stdout (`std.zig.Server`): spawn, request updates, read each
//! update's reply, reap. The protocol is the compiler's and is frozen.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Cache = std.Build.Cache;
const ClientMsg = std.zig.Client.Message;
const ServerMsg = std.zig.Server.Message;

/// One `zig ... --listen=-` child: the compiler server protocol over its
/// stdin/stdout. Must not move after `spawn`: `out.interface` is the reader.
pub const Server = struct {
    child: std.process.Child,
    out: Io.File.Reader,

    /// Starts `argv` with piped stdin and stdout and inherited stderr. The
    /// 64 KiB read buffer is allocated in `arena`, which must outlive `close`.
    /// Fails with `error.CompilerGone` when the child cannot be spawned.
    pub fn spawn(s: *Server, io: Io, arena: Allocator, argv: []const []const u8) !void {
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
    pub fn close(s: *Server, io: Io) void {
        if (s.child.stdin) |stdin| {
            send(io, &s.child, .exit) catch {};
            stdin.close(io);
            s.child.stdin = null;
        }
        _ = s.child.wait(io) catch s.child.kill(io);
    }

    pub const Update = union(enum) {
        ok: struct { digest: Cache.BinDigest, cache_hit: bool },
        failed: std.zig.ErrorBundle,
    };

    /// Reads one update's reply: an `error_bundle` message, possibly empty,
    /// ends it. A failed bundle is owned by `gpa`.
    pub fn wait(s: *Server, gpa: Allocator) !Update {
        const r = &s.out.interface;
        var digest: ?Cache.BinDigest = null;
        var cache_hit = false;
        while (true) {
            const header = r.takeStruct(ServerMsg.Header, .little) catch return error.CompilerGone;
            const body = r.readAllocAll(gpa, header.bytes_len) catch |err| switch (err) {
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

/// Sends one header-only message (`update` or `exit`). Fails with
/// `error.CompilerGone` once the child's stdin is closed or broken.
pub fn send(io: Io, child: *std.process.Child, tag: ClientMsg.Tag) !void {
    const stdin = child.stdin orelse return error.CompilerGone;
    var w = stdin.writer(io, &.{});
    w.interface.writeStruct(ClientMsg.Header{ .tag = tag, .bytes_len = 0 }, .little) catch
        return error.CompilerGone;
}
