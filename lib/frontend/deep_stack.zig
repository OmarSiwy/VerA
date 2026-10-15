//! Deep stacks: a recursive walk and the nesting depth it will reach in, the
//! walk's result out, computed on a thread whose stack is reserved for that
//! depth. Source nesting (parentheses, operator chains, `begin` blocks,
//! else-if chains, macro arguments, include files) is therefore bounded by
//! memory and the OS thread limit, not by the calling thread's stack (8 MiB
//! on Linux and macOS main threads; an embedder's thread may have less).
//! No LRM clause bounds nesting.
//!
//! The reservation is `base_bytes + depth_hint * bytes_per_level`, rounded
//! up to 64 KiB (a multiple of every page size VerA targets: 4 KiB, 16 KiB
//! on Apple silicon, and Windows' 64 KiB allocation granularity).
//! `bytes_per_level` covers the deepest walk per level of the parser's
//! nesting count (`Parser.deepest`), measured on x86_64-linux (2026-10-15)
//! as the stack high-water mark over the depth, through `vera --lint` and
//! `--emit-zig`, at 4,000 to 100,000 levels of a sum chain, parentheses,
//! unary minus, a `?:` chain, nested `begin`, nested `if`, an else-if chain
//! and nested concatenation. Worst per level, Debug: 7.2 KB (the sum chain,
//! lowering's `context.zig` walk), then 3.9 KB (else-if and nested `if`,
//! `lowerStmt`), 2.6 KB (`?:`, `lowerTernary`); the parser's own segments
//! peaked at 5.8 KB (nested `begin`). ReleaseFast: 2.7 KB (sum), 1.4 KB
//! (else-if), 0.9 KB (`?:`). The 16 KiB and 8 KiB below leave at least 2x.
//!
//! The parser and preprocessor run on segments: every `segment_levels`
//! levels the next level gets a fresh `run` while its parent thread waits,
//! so depth costs one blocked thread per segment. At the parser's 4,096
//! levels per segment (an 80 MiB reservation in Debug, 48 MiB in release),
//! 100,000 levels is 25 threads; macOS's default of 2,048 threads per
//! process (kern.num_taskthreads) allows about 8 million levels, and Linux's
//! threads-max (tens of thousands or more) further still.
//!
//! How `std.Thread.spawn`'s `stack_size` behaves per target (Zig 0.17):
//! - Linux without libc: one anonymous `mmap` of the whole size plus a guard
//!   page, `mprotect`ed read/write; pages are committed only as the walk
//!   touches them. Under the default overcommit heuristic a size past RAM +
//!   swap fails with `OutOfMemory`.
//! - Linux with libc, macOS: `pthread_attr_setstacksize`, then libc maps the
//!   stack the same lazy way. macOS refuses a size that is not a page
//!   multiple (Zig asserts on it), hence the 64 KiB rounding.
//! - Windows: `NtCreateThreadEx` with the size as the stack's initial
//!   commit, after a lossy cast to u32. So Windows charges the whole size
//!   against the commit limit (pagefile, not RAM, until touched) and cannot
//!   take 4 GiB or more: `bytesFor` refuses that size instead of letting the
//!   cast shrink it.
//! - Single-threaded builds cannot spawn: the walk runs on the caller's stack.
//!
//! A reservation or spawn that fails is `error.DeepStackUnavailable`; the
//! caller names the depth in its own diagnostic (E0241 in the parser and
//! later stages, E0119 in the preprocessor).

const std = @import("std");
const builtin = @import("builtin");

/// The one failure `run` adds to the walk's own error set: the stack for the
/// requested depth could not be reserved, or the thread not started.
pub const Error = error{DeepStackUnavailable};

/// Stack bytes per nesting level, for the deepest walk measured (see the
/// header). Debug frames are several times release frames.
pub const bytes_per_level: usize = switch (builtin.mode) {
    .Debug => 16 * 1024,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => 8 * 1024,
};

/// Stack every run gets before any nesting: twice the 8 MiB main-thread
/// stack the pipeline ran on before, for walks whose frames do not grow with
/// nesting (codegen's buffers, the prover).
pub const base_bytes: usize = 16 << 20;

/// Depth `run` leaves on the caller's stack: 512 levels of the Debug worst
/// case is 3.7 MB, half the 1,024 levels every caller's stack held while the
/// parser capped nesting there.
pub const in_place_levels: usize = 512;

/// The largest stack one thread can be given on this target.
const platform_max: usize = if (builtin.os.tag == .windows) // os: a comptime constant; every target builds both arms
    std.math.maxInt(u32) & ~@as(usize, granule - 1)
else
    std.math.maxInt(usize) & ~@as(usize, granule - 1);

const granule: usize = 64 * 1024;

/// The stack `run` reserves for `depth` levels, or null when that size
/// overflows or passes what this target can give one thread.
pub fn bytesFor(depth: usize) ?usize {
    const levels = std.math.mul(usize, depth, bytes_per_level) catch return null;
    const raw = std.math.add(usize, levels, base_bytes + granule - 1) catch return null;
    const size = raw & ~(granule - 1);
    return if (size > platform_max) null else size;
}

/// `func`'s return type with `Error` added to its error set.
pub fn Result(comptime Func: type) type {
    const R = @typeInfo(Func).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || Error)!eu.payload,
        else => Error!R,
    };
}

/// Test hook: while set (test builds only), `run` refuses every call as an
/// unreservable stack would, so a caller's diagnostic for it can be tested.
pub var refuse_for_test: bool = false;

/// Calls `func` with `args` on a fresh thread whose stack holds `depth_hint`
/// nesting levels (`bytesFor`) and returns its result; the calling thread
/// waits. A hint of at most `in_place_levels` calls `func` directly.
/// `depth_hint` counts levels of the walk `bytes_per_level` was measured on; a walk with larger frames per level scales its hint.
/// `func` may touch the caller's state: the caller is blocked until it
/// returns, and the join orders every write before the caller reads.
pub fn run(depth_hint: usize, comptime func: anytype, args: anytype) Result(@TypeOf(func)) {
    if (builtin.single_threaded) return @call(.auto, func, args);
    if (builtin.is_test and refuse_for_test) return error.DeepStackUnavailable;
    // Shallow walks stay on the caller's stack: a thread costs a spawn, cold
    // stack pages and, on a hybrid CPU, maybe a slower core (measured: 1 ms
    // and up to 8% of a `vera --lint` of a compact model when every compile
    // spawned one).
    if (depth_hint <= in_place_levels) return @call(.auto, func, args);
    const size = bytesFor(depth_hint) orelse return error.DeepStackUnavailable;
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const Call = struct {
        fn entry(out: *R, a: @TypeOf(args)) void {
            out.* = @call(.auto, func, a);
        }
    };
    var out: R = undefined;
    const thread = std.Thread.spawn(.{ .stack_size = size }, Call.entry, .{ &out, args }) catch
        return error.DeepStackUnavailable;
    thread.join();
    return out;
}

/// Recurses `n` levels with a frame of about 1 KiB each, then returns `n`.
fn recurse(n: usize) error{Odd}!usize {
    var pad: [1024]u8 = undefined;
    pad[n % pad.len] = @truncate(n);
    std.mem.doNotOptimizeAway(&pad);
    if (n == 0) return 0;
    return 1 + try recurse(n - 1);
}

fn failing(x: u32) error{Odd}!u32 {
    return if (x % 2 == 1) error.Odd else x;
}

fn plain(x: u32) u32 {
    return x + 1;
}

test "run: a recursion far past the calling thread's stack" {
    // 30,000 levels of 1 KiB frames is about 30 MiB: past the 8 MiB main
    // stack and past `base_bytes`, so the levels' share is what holds it.
    try std.testing.expectEqual(@as(usize, 30_000), try run(30_000, recurse, .{30_000}));
}

test "run: the walk's own errors and plain results pass through" {
    for ([_]usize{ 1, in_place_levels + 1 }) |hint| {
        try std.testing.expectError(error.Odd, run(hint, failing, .{3}));
        try std.testing.expectEqual(@as(u32, 4), try run(hint, failing, .{4}));
        try std.testing.expectEqual(@as(u32, 8), try run(hint, plain, .{7}));
    }
}

test "run: a depth no stack can hold is DeepStackUnavailable, not a crash" {
    if (builtin.single_threaded) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?usize, null), bytesFor(std.math.maxInt(usize)));
    try std.testing.expectError(error.DeepStackUnavailable, run(std.math.maxInt(usize), plain, .{1}));
    try std.testing.expectError(error.DeepStackUnavailable, run(std.math.maxInt(usize) / bytes_per_level, failing, .{2}));
}

test "bytesFor: base plus levels, rounded to 64 KiB" {
    try std.testing.expectEqual(@as(?usize, base_bytes), bytesFor(0));
    const one = bytesFor(1).?;
    try std.testing.expect(one >= base_bytes + bytes_per_level and one % granule == 0);
}
