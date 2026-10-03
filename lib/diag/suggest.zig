//! Name suggestions: an unknown name and the names in scope -> the nearest
//! one, for the did-you-mean help line of every "unknown name" diagnostic.
//! Pure functions over borrowed strings: no allocation, no bag.

const std = @import("std");

/// Optimal string alignment distance (Damerau-Levenshtein restricted to
/// adjacent transpositions), capped at `limit` so a hopeless pair exits early.
///
/// No allocation: names longer than `cap` are not the ones a typo suggestion
/// helps with.
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    const cap = 64;
    if (a.len > cap or b.len > cap) return limit + 1;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > b.len + limit or b.len > a.len + limit) return limit + 1;

    // `u8` cells: an edit distance never exceeds the longer input (<= cap), so
    // the widest intermediate any `@min` sees is cap + 1.
    var rows: [3][cap + 1]u8 = undefined;
    var prev2: *[cap + 1]u8 = &rows[0];
    var prev: *[cap + 1]u8 = &rows[1];
    var cur: *[cap + 1]u8 = &rows[2];

    for (0..b.len + 1) |j| prev[j] = @intCast(j);

    for (a, 0..) |ca, i| {
        cur[0] = @intCast(i + 1);
        var row_min = cur[0];
        for (b, 0..) |cb, j| {
            const cost: u8 = if (ca == cb) 0 else 1;
            var v = @min(
                @min(cur[j] + 1, prev[j + 1] + 1),
                prev[j] + cost,
            );
            if (i > 0 and j > 0 and ca == b[j - 1] and a[i - 1] == cb)
                v = @min(v, prev2[j - 1] + 1);
            cur[j + 1] = v;
            row_min = @min(row_min, v);
        }
        if (row_min > limit) return limit + 1;
        // `cur` takes over the row nobody reads again, so the three never alias.
        const spent = prev2;
        prev2 = prev;
        prev = cur;
        cur = spent;
    }
    return prev[b.len];
}

/// Returns the candidate nearest to `name`, or null when nothing is close
/// enough. Ties break on the name, lexicographically, so the answer does not
/// depend on candidate order (callers often feed hash-map iterators).
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var n: Nearest = .init(name);
    for (candidates) |c| n.offer(c);
    return n.best;
}

/// `didYouMean` over the keys of any `StringHashMapUnmanaged`, streamed
/// without allocating.
pub fn didYouMeanMap(name: []const u8, map: anytype) ?[]const u8 {
    var n: Nearest = .init(name);
    var it = map.keyIterator();
    while (it.next()) |k| n.offer(k.*);
    return n.best;
}

/// The running minimum of `(editDistance(name, c), c)` under the lexicographic
/// order on that pair. Order-independent by construction, which is what lets the
/// map form above avoid materialising the candidate set.
const Nearest = struct {
    name: []const u8,
    limit: usize,
    best: ?[]const u8 = null,
    best_d: usize,

    fn init(name: []const u8) Nearest {
        // One edit per three characters, and always at least one, so `vd` still
        // suggests `vds` but `a` suggests nothing.
        const limit = @max(@as(usize, 1), name.len / 3);
        return .{ .name = name, .limit = limit, .best_d = limit + 1 };
    }

    fn offer(self: *Nearest, c: []const u8) void {
        if (std.mem.eql(u8, c, self.name)) return;
        const d = editDistance(self.name, c, self.limit);
        if (d > self.limit) return;
        if (self.best == null or d < self.best_d or
            (d == self.best_d and std.mem.lessThan(u8, c, self.best.?)))
        {
            self.best = c;
            self.best_d = d;
        }
    }
};
