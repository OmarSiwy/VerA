//! A walk whose depth the design decides (an expression or statement tree,
//! the instance hierarchy, a recursive task or function) -> run on a thread
//! whose stack is reserved as large as this machine allows, and a check each
//! recursive step makes, so that running out of it is a named refusal
//! instead of a segfault. A stack's pages are committed only as a walk
//! touches them, so the reservation costs nothing a shallow design uses:
//! depth is bounded by memory, not by the default 8 MiB main-thread stack.
//! Used by the digital interpreter, its emitter and a native executable.
const std = @import("std");
const builtin = @import("builtin");

/// The lowest frame address this thread's walks may reach, and the stack
/// it was reserved from (for the diagnostic). 0 until `run` starts the
/// thread, or `exhausted` first runs on a thread VerA did not start.
threadlocal var floor: usize = 0;
threadlocal var reserved: usize = 0;
/// This thread is one `run` started.
threadlocal var inside: bool = false;

/// The stack one step may use between two checks.
const margin = 1 << 20;
/// A thread VerA did not start (a host's, calling a contract device) has an
/// unknown stack: half of the smallest main-thread stack VerA expects
/// (8 MiB on Linux and macOS) below the first check.
const foreign = 4 << 20;
/// The smallest reservation worth a thread; below it the walk runs here.
const least = 64 << 20;
/// Stack bytes asked for per level of `run`'s depth hint.
const per_level = 16 << 10;

/// The stack `run` asks for first: a sixteenth of physical memory, at most
/// 16 GiB, or more when `hint` levels need it, up to all of it. A recursion
/// that never ends touches the whole reservation before `exhausted` refuses
/// it, so this is also what such a design costs. Windows commits a thread's
/// whole stack, and a 32-bit address space has no room: both ask for 256 MiB.
fn largest(hint: usize) usize {
    if (@sizeOf(usize) < 8 or builtin.os.tag == .windows) return 256 << 20; // os: a comptime target test; every target takes one branch
    const total: usize = @intCast(@min(std.process.totalSystemMemory() catch 8 << 30, 1 << 48));
    const want = @max(@min(total / 16, 16 << 30), std.math.mul(usize, hint, per_level) catch total);
    return @max(least, std.mem.alignBackward(usize, @min(want, total), 1 << 20));
}

/// `f(args...)` on a thread with the stack `largest(depth_hint)` (halved
/// until a thread starts), joined before returning; on this thread when it
/// already is one, or when no thread can be started (then `exhausted` gives
/// this thread the foreign budget, so a deep walk is still a refusal and
/// never a crash). `depth_hint` is the deepest nesting the caller measured,
/// 0 when it measured none.
pub fn run(depth_hint: usize, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    if (inside or builtin.single_threaded or builtin.os.tag == .freestanding) return @call(.auto, f, args); // os: a comptime target test; freestanding has no threads
    const Task = struct {
        args: @TypeOf(args),
        size: usize,
        result: R = undefined,
        fn go(t: *@This()) void {
            inside = true;
            reserved = t.size;
            floor = @frameAddress() -| (t.size - 2 * margin);
            t.result = @call(.auto, f, t.args);
        }
    };
    var size = largest(depth_hint);
    while (true) {
        var task: Task = .{ .args = args, .size = size };
        if (std.Thread.spawn(.{ .stack_size = size }, Task.go, .{&task})) |thread| {
            thread.join();
            return task.result;
        } else |_| {
            if (size / 2 < least) return @call(.auto, f, args);
            size /= 2;
        }
    }
}

/// Whether the calling step is within `margin` of the end of its stack.
pub fn exhausted() bool {
    if (builtin.os.tag == .freestanding) return false; // os: a comptime target test; freestanding has no stack to bound
    const at = @frameAddress();
    if (floor == 0) {
        reserved = foreign;
        floor = at -| (foreign - margin);
    }
    return at < floor;
}

/// The refusal past `exhausted`; its argument is `mib()`.
pub const message = "nesting here exhausts the {d} MiB stack VerA reserved for it";

/// The MiB this thread's stack was reserved with.
pub fn mib() usize {
    return reserved >> 20;
}

test "run reserves a stack deeper than the main thread's, and exhausted stops before its end" {
    const Walk = struct {
        // About 1 KiB of frame per level, so 100000 levels need ~100 MiB:
        // more than any default main-thread stack.
        fn down(n: u32) error{Exhausted}!u32 {
            var pad: [1024]u8 = undefined;
            pad[n % pad.len] = @truncate(n);
            std.mem.doNotOptimizeAway(&pad);
            if (exhausted()) return error.Exhausted;
            if (n == 0) return 0;
            return 1 + try down(n - 1);
        }
        fn forever(n: u32) error{Exhausted}!u32 {
            var pad: [1024]u8 = undefined;
            std.mem.doNotOptimizeAway(&pad);
            if (exhausted()) return error.Exhausted;
            return 1 + try forever(n + 1);
        }
        // A thread VerA did not start: `exhausted` gives it the foreign
        // budget, so a walk that never ends is refused within 4 MiB.
        fn host(out: *(error{Exhausted}!u32)) void {
            out.* = forever(0);
        }
    };
    if (builtin.single_threaded or largest(0) < 256 << 20) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 100000), try run(0, Walk.down, .{@as(u32, 100000)}));
    var got: error{Exhausted}!u32 = 0;
    const t = try std.Thread.spawn(.{ .stack_size = 16 << 20 }, Walk.host, .{&got});
    t.join();
    try std.testing.expectError(error.Exhausted, got);
}
