//! `deriv_reads` and `jac_const`: the evidence the emitter accumulates while
//! writing (every `x[u]` and `.ddxAt(u)` it spells, every dispatcher row's
//! constant coefficients) -> which derivative lanes `eval`/`q` read, and the
//! exact constant partials of every column they do not. Soundness is argued
//! at `dispatch.emitDerivReads`, which formats the result.

const std = @import("std");

/// One constant partial: `g` of `eval`, `c` of `q`, at (row, col). Absent is 0.
/// `when` is a GUARDED entry's collapse pair (`plan/topology.zig`
/// `cpairs` index): it holds only while that pair's retention flag is set
/// and the host has not collapsed it (`contract.JacWhen`).
pub const Entry = struct { row: u32, col: u32, g: f64, c: f64, when: ?u32 = null };

/// The two emitted tables.
pub const JacConst = struct {
    /// The emitted `deriv_reads`: every lane `eval`/`q` may read.
    mask: u64,
    /// Sorted by (row, col); only columns outside `mask`, only nonzero pairs.
    entries: []Entry,
};

/// Returns the emitted `deriv_reads` mask and the constant-partial table, or
/// null above 64 unknowns (neither decl is emitted and the defaults, every
/// lane and no table, are correct). `entries` is owned by `arena`.
///
/// `lin[react][row * n_u + col]` is the exact coefficient of `x[col]` in
/// `res[row]` as far as the stamps are linear. `guarded` are the stamps that
/// hold only under a collapse guard, one entry per (row, col, pair).
/// `ddx_reads` and `limit`'s writes are ORed into the mask for `contract`'s
/// rules. A (row, col) the table would have to state twice (unguarded and
/// guarded, or under two guards) keeps its lane instead: `contract` wants
/// (row, col) unique.
pub fn plan(
    arena: std.mem.Allocator,
    n_u: u32,
    deriv_reads: u64,
    ddx_reads: u64,
    limit_writes: u64,
    lin: [2][]const f64,
    guarded: []const Entry,
) std.mem.Allocator.Error!?JacConst {
    if (n_u > 64) return null;
    var mask = deriv_reads | ddx_reads | limit_writes;
    const n = n_u;
    for (guarded, 0..) |e, k| {
        const clash = lin[0][e.row * n + e.col] != 0 or lin[1][e.row * n + e.col] != 0 or
            for (guarded[0..k]) |p| {
                if (p.row == e.row and p.col == e.col) break true;
            } else false;
        if (clash) mask |= @as(u64, 1) << @intCast(e.col);
    }
    var out: std.ArrayList(Entry) = .empty;
    for (0..n) |r| for (0..n) |c| {
        if ((mask >> @intCast(c)) & 1 != 0) continue;
        const g = lin[0][r * n + c];
        const q = lin[1][r * n + c];
        if (g != 0 or q != 0) {
            try out.append(arena, .{ .row = @intCast(r), .col = @intCast(c), .g = g, .c = q });
            continue;
        }
        for (guarded) |e| {
            if (e.row == r and e.col == c and (e.g != 0 or e.c != 0)) try out.append(arena, e);
        }
    };
    return .{ .mask = mask, .entries = out.items };
}

test "a column any lane reads leaves the table; the rest are listed in (row, col) order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A 2-unknown resistor stamp, 1/R = 0.5, plus a capacitor on q's (1,1).
    const g = [_]f64{ 0.5, -0.5, -0.5, 0.5 };
    const q = [_]f64{ 0, 0, 0, 1e-12 };

    const none = (try plan(arena.allocator(), 2, 0, 0, 0, .{ &g, &q }, &.{})).?;
    try std.testing.expectEqual(@as(u64, 0), none.mask);
    try std.testing.expectEqualSlices(Entry, &.{
        .{ .row = 0, .col = 0, .g = 0.5, .c = 0 },
        .{ .row = 0, .col = 1, .g = -0.5, .c = 0 },
        .{ .row = 1, .col = 0, .g = -0.5, .c = 0 },
        .{ .row = 1, .col = 1, .g = 0.5, .c = 1e-12 },
    }, none.entries);

    // A `ddx` of unknown 1 puts its lane back: its column is no longer constant.
    const ddx = (try plan(arena.allocator(), 2, 0, 0b10, 0, .{ &g, &q }, &.{})).?;
    try std.testing.expectEqual(@as(u64, 0b10), ddx.mask);
    try std.testing.expectEqual(@as(usize, 2), ddx.entries.len);
    try std.testing.expectEqual(@as(?JacConst, null), try plan(arena.allocator(), 65, 0, 0, 0, .{ &g, &q }, &.{}));
}

test "a guarded stamp is listed with its guard; one that clashes puts its column back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Unknowns a, b, and the flow `ib` of a collapsible a–b short: the ±1
    // KCL stamps of ib exist only under pair 0's guard.
    const z: [9]f64 = @splat(0);
    const gd = [_]Entry{
        .{ .row = 0, .col = 2, .g = 1, .c = 0, .when = 0 },
        .{ .row = 1, .col = 2, .g = -1, .c = 0, .when = 0 },
    };
    const j = (try plan(arena.allocator(), 3, 0b011, 0, 0, .{ &z, &z }, &gd)).?;
    try std.testing.expectEqual(@as(u64, 0b011), j.mask);
    try std.testing.expectEqualSlices(Entry, &gd, j.entries);
    // An unguarded stamp at the same (row, col): the column keeps its lane.
    var g1 = z;
    g1[0 * 3 + 2] = 1;
    const c = (try plan(arena.allocator(), 3, 0b011, 0, 0, .{ &g1, &z }, &gd)).?;
    try std.testing.expectEqual(@as(u64, 0b111), c.mask);
    try std.testing.expectEqual(@as(usize, 0), c.entries.len);
}
