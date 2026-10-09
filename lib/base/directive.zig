//! Positional compiler-directive events: the preprocessor's `Region` lists
//! (an output offset and the value in force from it) and the `timescale
//! operands. The preprocessor writes them (`Preprocessor.Directives`, which
//! aliases these); lowering and the stages after it read them through
//! `Lowered` without importing the frontend (ARCHITECTURE.md Phase 11).
//! Imports only std.
//!
//! LRM clauses this file's code cites: §10.1; IEEE 1364-2005 §19.6, §19.8.

const std = @import("std");

/// A `timescale's two operands, in seconds.
pub const Timescale = struct {
    unit: f64,
    precision: f64,
};

/// One positional directive event: the output offset where its value changed,
/// and the new value.
///
/// §10.1: "The scope of compiler directives extends from the point where it is
/// processed, across all files processed, to the point where another compiler
/// directive supersedes it or the processing completes." So nothing resets at
/// a file boundary, and only another directive (including `resetall, which
/// writes an event like any other) ends a region.
///
/// `at` is an offset into the preprocessed output, the unit every later stage
/// reports in, so it compares directly against a token start.
pub fn Region(comptime T: type) type {
    return struct {
        at: u32,
        value: T,

        /// Returns the value in force at output offset `off`, or `initial` (IEEE
        /// 1364 §19.6's default value) before the first event. O(events).
        /// `events` must be in text-stream order (`at` non-decreasing), as every
        /// list `process` publishes is; of two events at one offset the later
        /// one is in force.
        ///
        /// ponytail: backwards linear scan, one entry per directive occurrence;
        /// `std.sort.upperBound` over `at` if a generated file carries thousands.
        pub fn inForce(events: []const @This(), off: u32, initial: T) T {
            var i = events.len;
            while (i > 0) {
                i -= 1;
                if (events[i].at <= off) return events[i].value;
            }
            return initial;
        }
    };
}

test "Region.inForce agrees with a forward scan on every small event list" {
    // Every list of up to four events whose offsets are drawn from 0..3 in
    // non-decreasing order, queried at every offset 0..4. The reference walks
    // forward and keeps the last event at or before the query.
    const values = [_]u8{ 1, 2, 3, 4 };
    const R = Region(u8);
    var events: [4]R = undefined;
    for (0..events.len + 1) |n| {
        for (0..std.math.pow(usize, 4, n)) |code| {
            var c = code;
            var sorted = true;
            for (0..n) |k| {
                events[k] = .{ .at = @intCast(c % 4), .value = values[k] };
                c /= 4;
                if (k > 0 and events[k].at < events[k - 1].at) sorted = false;
            }
            if (!sorted) continue;
            for (0..5) |off| {
                var want: u8 = 0;
                for (events[0..n]) |e| {
                    if (e.at <= off) want = e.value;
                }
                try std.testing.expectEqual(want, R.inForce(events[0..n], @intCast(off), 0));
            }
        }
    }
}
