//! Opening a dynamic library: a `--emit-so` artifact (path → `DynLib`), for
//! the tests and test hosts that load one. VerA itself never loads a library;
//! the host does (`orchestrator.zig`).
//!
//! The one file in lib/ and src/ that calls an OS directly
//! (`tests/exhaustive.zig` allowlists it): Zig 0.17's `std.DynLib` has no
//! Windows loader, so Windows goes through the ntdll loader that std itself
//! uses (`std.Io.Threaded`). Every other target is `std.DynLib`.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const DynLib = if (builtin.os.tag == .windows) Windows else std.DynLib;

const Windows = struct {
    handle: windows.PVOID,

    pub const Error = error{ BadPathName, FileNotFound };

    /// Trusts the file, as `std.DynLib.open` does. A relative `path` is taken
    /// against the cwd, as on POSIX, not against the DLL search order.
    pub fn open(path: []const u8) Error!Windows {
        var rel: [windows.PATH_MAX_WIDE:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&rel, path) catch return error.BadPathName;
        rel[n] = 0;
        var full: [windows.PATH_MAX_WIDE]u16 = undefined;
        const bytes = windows.ntdll.RtlGetFullPathName_U(&rel, @sizeOf(@TypeOf(full)), &full, null);
        if (bytes == 0 or bytes >= @sizeOf(@TypeOf(full))) return error.BadPathName;
        var handle: windows.PVOID = undefined;
        return switch (windows.ntdll.LdrLoadDll(null, null, &.init(full[0 .. bytes / 2]), &handle)) {
            .SUCCESS => .{ .handle = handle },
            else => error.FileNotFound,
        };
    }

    pub fn close(self: *Windows) void {
        _ = windows.ntdll.LdrUnloadDll(self.handle);
    }

    pub fn lookup(self: *Windows, comptime T: type, name: [:0]const u8) ?T {
        var p: windows.PVOID = undefined;
        return switch (windows.ntdll.LdrGetProcedureAddress(self.handle, &.init(name), 0, &p)) {
            .SUCCESS => @ptrCast(@alignCast(p)),
            else => null,
        };
    }
};
