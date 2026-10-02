//! Batched-instance evalQ bench host: W operating points per evalQ call with
//! `batch_family.Family(W)`, against the scalar sparse family on the same
//! points. Both loops pack/unpack like a host would: gather W instances'
//! unknowns into the lane vectors, scatter every residual, charge and
//! Jacobian entry back per instance.
const std = @import("std");
const contract = @import("contract");
const BF = @import("batch_family.zig");
const W = @import("cfg").W;

pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    const A = Api(D);
    @export(&A.bench_setup, .{ .name = "bench_setup" });
    @export(&A.bench_scalar, .{ .name = "bench_scalar" });
    @export(&A.bench_batch, .{ .name = "bench_batch" });
    @export(&A.bench_w, .{ .name = "bench_w" });
    @export(&A.bench_check, .{ .name = "bench_check" });
    @export(&A.bench_groups, .{ .name = "bench_groups" });
}

fn Api(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const lanes = blk: {
            var a: [n]u8 = undefined;
            for (&a, 0..) |*v, i| v.* = @intCast(i);
            break :blk a;
        };
        const S = contract.RefFamily(f64, &lanes, .{ .dense = false });
        const B = BF.Family(W, &lanes);
        const Vv = contract.RefFamily(f64, &(.{contract.no_lane} ** n), .{ .dense = true });
        const per = 2 * n * (n + 1); // residual + charge rows, value + n partials

        var g_model: D.Model = .{};
        var g_inst: D.Instance = .{};
        var g_sim: contract.SimState = .{ .kind = .tran, .t = 1e-9, .dt = 1e-12, .analog_initial = false, .iteration = 3 };
        const NB = 64;
        /// Bias k: the dyn_rt host's points, and W consecutive ones per batch
        /// (`coherent`: every point of a batch takes the same branch path when
        /// the device steers, because they are equal; see `bench_check`).
        const biases: [NB][n]f64 = blk: {
            @setEvalBranchQuota(10_000_000);
            var b: [NB][n]f64 = undefined;
            for (&b, 0..) |*r, k| for (r, 0..) |*v, u| {
                v.* = 0.05 * @as(f64, @floatFromInt((k * 7 + u * 13) % 23)) - 0.1;
            };
            break :blk b;
        };
        var g_out: [W][per]f64 = undefined;

        fn bench_w() callconv(.c) u32 {
            return W;
        }
        fn bench_setup() callconv(.c) void {
            g_model = .{};
            g_inst = .{};
            if (@hasDecl(D, "derive")) D.derive(Vv, &g_model);
            if (@hasDecl(D, "setup")) D.setup(Vv, &g_model, &g_inst);
        }

        fn writeS(rows: anytype, out: *[per]f64, comptime first: usize) void {
            inline for (rows, 0..) |v, row| {
                out[(first + row) * (n + 1)] = v.val();
                inline for (0..n) |col| out[(first + row) * (n + 1) + 1 + col] = v.ddxAt(col);
            }
        }
        fn writeB(rows: anytype, comptime first: usize) void {
            @setEvalBranchQuota(1_000_000);
            inline for (rows, 0..) |v, row| {
                inline for (0..W) |w| {
                    g_out[w][(first + row) * (n + 1)] = v.v[w];
                    inline for (0..n) |col| g_out[w][(first + row) * (n + 1) + 1 + col] = v.ddxAtPoint(col, w);
                }
            }
        }

        fn evalScalar(x: *const [n]f64, out: *[per]f64) void {
            const both = D.evalQ(S, x, &g_model, &g_inst, g_sim);
            writeS(both.res, out, 0);
            writeS(both.q, out, n);
        }
        fn evalBatch(pts: *const [W][n]f64) void {
            var x: [n]B.V = undefined;
            inline for (0..n) |u| inline for (0..W) |w| {
                x[u][w] = pts[w][u];
            };
            const both = D.evalQ(B, &x, &g_model, &g_inst, g_sim);
            writeB(both.res, 0);
            writeB(both.q, n);
        }

        /// `iters` instances, one evalQ each (W calls per batch of W).
        fn bench_scalar(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) @call(.never_inline, evalScalar, .{ &biases[i % NB], &g_out[i % W] });
        }
        /// `iters` instances, W per evalQ call, W distinct bias points per
        /// batch. A device that steers follows point 0's branches in every
        /// lane (`batch_family`), so this is the coherent-branch cost.
        fn bench_batch(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = biases[(i + w) % NB];
                @call(.never_inline, evalBatch, .{&pts});
            }
        }
        /// Branch coherence over the 64 bias points in batches of W
        /// consecutive ones: how many batched evaluations a correct batched
        /// host needs (one per group of points that take the same path,
        /// found by steering on the first unanswered point and keeping the
        /// points whose outputs then equal their scalar ones), summed over
        /// the batches. NB / W means fully coherent; NB means no sharing.
        fn bench_groups() callconv(.c) u64 {
            var runs: u64 = 0;
            var b: usize = 0;
            while (b + W <= NB) : (b += W) {
                var pts: [W][n]f64 = undefined;
                var ref: [W][per]f64 = undefined;
                inline for (0..W) |w| {
                    pts[w] = biases[b + w];
                    @memset(&ref[w], 0);
                    evalScalar(&biases[b + w], &ref[w]);
                }
                var done = [_]bool{false} ** W;
                while (std.mem.indexOfScalar(bool, &done, false)) |first| {
                    BF.leader = first;
                    for (&g_out) |*o| @memset(o, 0);
                    evalBatch(&pts);
                    runs += 1;
                    for (0..W) |w| if (!done[w]) {
                        var same = true;
                        for (ref[w], g_out[w]) |x, y| {
                            if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y)) and !(x != x and y != y)) same = false;
                        }
                        if (same) done[w] = true;
                    };
                    done[first] = true; // its own path, even if NaN-noisy
                }
            }
            BF.leader = 0;
            return runs;
        }
        /// Number of batched outputs differing in bits from the scalar ones
        /// over all bias points (coherent batches): 0 means the batch family
        /// computes what the scalar one does.
        fn bench_check() callconv(.c) u64 {
            var bad: u64 = 0;
            for (0..NB) |k| {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = biases[k];
                for (&g_out) |*o| @memset(o, 0);
                evalBatch(&pts);
                var ref: [per]f64 = @splat(0);
                evalScalar(&biases[k], &ref);
                for (0..W) |w| for (ref, g_out[w], 0..) |a, b, j| {
                    if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(b)) and !(a != a and b != b)) {
                        if (bad < 4) std.debug.print("k={d} w={d} j={d} scalar={e} batch={e}\n", .{ k, w, j, a, b });
                        bad += 1;
                    }
                };
            }
            return bad;
        }
    };
}
