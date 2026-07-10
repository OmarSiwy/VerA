//! An arena whose large blocks are the backing allocator's own: allocator
//! calls → small ones bumped from a `std.heap.ArenaAllocator`, large ones
//! passed through and remembered so `deinit` frees them with the rest.
//!
//! Why: a plain arena can grow only its latest allocation in place, so every
//! list that doubles on it leaves its previous buffer behind until the arena
//! dies. The compile's big tables (MIR rows, the AST stores, codegen's text
//! buffers) all grow that way, and the dead copies were a third of the
//! compile's resident memory on hisimhv. Passed through, a large buffer grows
//! by the backing allocator's `remap` (an `mremap` for `smp_allocator`, which
//! moves page mappings and copies nothing) and a buffer it gives up is
//! unmapped at once.
//!
//! The split is by length alone: every live block of `large` bytes or more is
//! the backing allocator's, every smaller one the arena's. A resize that would
//! cross the line is refused, so the caller moves the data, and a block never
//! changes sides. Not threadsafe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const BigArena = @This();

/// `smp_allocator`'s largest size class is a 64 KiB slab; from there up it
/// maps pages and remaps them in place, which is the growth this wants.
pub const large = 64 * 1024;

small: std.heap.ArenaAllocator,
child: Allocator,
/// Address → extent of every live large block, for `deinit`. Few entries:
/// one per large table, not per allocation.
blocks: std.AutoHashMapUnmanaged(usize, Block) = .empty,

const Block = struct { len: usize, alignment: Alignment };

pub fn init(child: Allocator) BigArena {
    return .{ .small = .init(child), .child = child };
}

/// Frees every block, large and small.
pub fn deinit(self: *BigArena) void {
    var it = self.blocks.iterator();
    while (it.next()) |e| {
        const p: [*]u8 = @ptrFromInt(e.key_ptr.*);
        self.child.rawFree(p[0..e.value_ptr.len], e.value_ptr.alignment, @returnAddress());
    }
    self.blocks.deinit(self.child);
    self.small.deinit();
    self.* = undefined;
}

pub fn allocator(self: *BigArena) Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn alloc(ctx: *anyopaque, n: usize, a: Alignment, ra: usize) ?[*]u8 {
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if (n < large) return self.small.allocator().rawAlloc(n, a, ra);
    self.blocks.ensureUnusedCapacity(self.child, 1) catch return null;
    const p = self.child.rawAlloc(n, a, ra) orelse return null;
    self.blocks.putAssumeCapacity(@intFromPtr(p), .{ .len = n, .alignment = a });
    return p;
}

fn resize(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if ((m.len < large) != (n < large)) return false;
    if (m.len < large) return self.small.allocator().rawResize(m, a, n, ra);
    if (!self.child.rawResize(m, a, n, ra)) return false;
    self.blocks.getPtr(@intFromPtr(m.ptr)).?.len = n;
    return true;
}

fn remap(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if ((m.len < large) != (n < large)) return null;
    if (m.len < large) return self.small.allocator().rawRemap(m, a, n, ra);
    // Room for the moved key first: after a successful remap the old address
    // is gone, and failing then would lose the block.
    self.blocks.ensureUnusedCapacity(self.child, 1) catch return null;
    const p = self.child.rawRemap(m, a, n, ra) orelse return null;
    _ = self.blocks.remove(@intFromPtr(m.ptr));
    self.blocks.putAssumeCapacity(@intFromPtr(p), .{ .len = n, .alignment = a });
    return p;
}

fn free(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
    const self: *BigArena = @ptrCast(@alignCast(ctx));
    if (m.len < large) return self.small.allocator().rawFree(m, a, ra);
    _ = self.blocks.remove(@intFromPtr(m.ptr));
    self.child.rawFree(m, a, ra);
}

test "big arena: large blocks grow, move and free through the backing allocator" {
    var arena: BigArena = .init(std.testing.allocator);
    defer arena.deinit(); // the testing allocator fails the test on a leak
    const a = arena.allocator();

    var list: std.ArrayList(u32) = .empty;
    for (0..100_000) |i| try list.append(a, @intCast(i)); // crosses `large`
    for (list.items, 0..) |x, i| try std.testing.expectEqual(@as(u32, @intCast(i)), x);
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());

    const kept = try list.toOwnedSlice(a); // shrink of a large block stays large
    try std.testing.expectEqual(@as(u32, 99_999), kept[kept.len - 1]);
    _ = try a.alloc(u8, 10); // small, from the arena
    const big = try a.alloc(u8, large);
    a.free(big); // given back at once
    try std.testing.expectEqual(@as(u32, 1), arena.blocks.count());
    // `kept` and the small block are freed by `deinit`.
}
