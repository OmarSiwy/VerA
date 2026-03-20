//! `deriv_reads` and `jac_const`: which derivative lanes `eval`/`q` read, and
//! the exact constant partials of every column they do not.
//!
//! PURE (ARCHITECTURE.md §2): the emitter ACCUMULATES the evidence while it
//! writes — every `x[u]` `renderValueRef` spells, every `.ddxAt(u)`, every
//! dispatcher row's constant coefficients (`lin`) — and `plan` turns that
//! evidence into the two tables. `dispatch.emitDerivReads` only formats them.
//!
//! Why the derivation is sound is argued at `emitDerivReads`; this is the
//! arithmetic half of it, cut from there verbatim.

const std = @import("std");

/// One constant partial: `g` of `eval`, `c` of `q`, at (row, col). Absent is 0.
pub const Entry = struct { row: u32, col: u32, g: f64, c: f64 };

pub const JacConst = struct {
    /// The emitted `deriv_reads`: every lane `eval`/`q` may read.
    mask: u64,
    /// Sorted by (row, col); only columns outside `mask`, only nonzero pairs.
    entries: []Entry,
};

/// `lin[react][row * n_u + col]` is the exact coefficient of `x[col]` in
/// `res[row]` as far as the stamps are linear. `ddx_reads` and `limit`'s
/// writes are ORed into the mask for `contract`'s rules. Null above 64
/// unknowns, where neither decl is emitted and the defaults — every lane, no
/// table — are correct.
pub fn plan(
    arena: std.mem.Allocator,
    n_u: u32,
    deriv_reads: u64,
    ddx_reads: u64,
    limit_writes: u64,
    lin: [2][]const f64,
) std.mem.Allocator.Error!?JacConst {
    if (n_u > 64) return null;
    const mask = deriv_reads | ddx_reads | limit_writes;
    const n = n_u;
    var out: std.ArrayList(Entry) = .empty;
    for (0..n) |r| for (0..n) |c| {
        if ((mask >> @intCast(c)) & 1 != 0) continue;
        const g = lin[0][r * n + c];
        const q = lin[1][r * n + c];
        if (g == 0 and q == 0) continue;
        try out.append(arena, .{ .row = @intCast(r), .col = @intCast(c), .g = g, .c = q });
    };
    return .{ .mask = mask, .entries = out.items };
}

test "a column any lane reads leaves the table; the rest are listed in (row, col) order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A 2-unknown resistor stamp, 1/R = 0.5, plus a capacitor on q's (1,1).
    const g = [_]f64{ 0.5, -0.5, -0.5, 0.5 };
    const q = [_]f64{ 0, 0, 0, 1e-12 };

    const none = (try plan(arena.allocator(), 2, 0, 0, 0, .{ &g, &q })).?;
    try std.testing.expectEqual(@as(u64, 0), none.mask);
    try std.testing.expectEqualSlices(Entry, &.{
        .{ .row = 0, .col = 0, .g = 0.5, .c = 0 },
        .{ .row = 0, .col = 1, .g = -0.5, .c = 0 },
        .{ .row = 1, .col = 0, .g = -0.5, .c = 0 },
        .{ .row = 1, .col = 1, .g = 0.5, .c = 1e-12 },
    }, none.entries);

    // A `ddx` of unknown 1 puts its lane back: its column is no longer constant.
    const ddx = (try plan(arena.allocator(), 2, 0, 0b10, 0, .{ &g, &q })).?;
    try std.testing.expectEqual(@as(u64, 0b10), ddx.mask);
    try std.testing.expectEqual(@as(usize, 2), ddx.entries.len);
    try std.testing.expectEqual(@as(?JacConst, null), try plan(arena.allocator(), 65, 0, 0, 0, .{ &g, &q }));
}
