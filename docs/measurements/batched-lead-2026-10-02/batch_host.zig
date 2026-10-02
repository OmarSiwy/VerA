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
    @export(&A.bench_check_mixed, .{ .name = "bench_check_mixed" });
    @export(&A.bench_check_hist, .{ .name = "bench_check_hist" });
    @export(&A.bench_hist_distinct, .{ .name = "bench_hist_distinct" });
    @export(&A.bench_check_sims, .{ .name = "bench_check_sims" });
    @export(&A.bench_coherent, .{ .name = "bench_coherent" });
    @export(&A.bench_set_points, .{ .name = "bench_set_points" });
    @export(&A.bench_param, .{ .name = "bench_param" });
    @export(&A.bench_resetup, .{ .name = "bench_resetup" });
    @export(&A.bench_signatures, .{ .name = "bench_signatures" });
    @export(&A.bench_sig_loop, .{ .name = "bench_sig_loop" });
    @export(&A.bench_set_runs, .{ .name = "bench_set_runs" });
    @export(&A.bench_set_check, .{ .name = "bench_set_check" });
    @export(&A.bench_coherent_batches, .{ .name = "bench_coherent_batches" });
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
        /// The instance of each lane: W distinct copies of `g_inst` for the
        /// timing runs, so the batch reads W instances as a host's would.
        var g_insts: [W]D.Instance = undefined;
        var g_lane: [W]*const D.Instance = undefined;
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
            if (@hasDecl(D, "setup")) D.setup(Vv, &g_model);
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&g_model, &g_inst);
            for (&g_insts, &g_lane) |*gi, *gl| {
                gi.* = g_inst;
                gl.* = gi;
            }
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
            evalScalarI(x, &g_inst, out);
        }
        fn evalScalarI(x: *const [n]f64, inst: *const D.Instance, out: *[per]f64) void {
            const both = @call(.always_inline, D.evalQ, .{ S, x, &g_model, inst, g_sim });
            writeS(both.res, out, 0);
            writeS(both.q, out, n);
        }
        fn evalBatch(pts: *const [W][n]f64) void {
            var x: [n]B.V = undefined;
            inline for (0..n) |u| inline for (0..W) |w| {
                x[u][w] = pts[w][u];
            };
            inline for (0..W) |w| B.Core_.insts[w] = g_lane[w];
            const both = @call(.always_inline, D.evalQ, .{ B, &x, &g_model, g_lane[0], g_sim });
            writeB(both.res, 0);
            writeB(both.q, n);
        }

        /// `iters` instances, one evalQ each (W calls per batch of W).
        fn bench_scalar(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) @call(.never_inline, evalScalarI, .{ &biases[i % NB], &g_insts[i % W], &g_out[i % W] });
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
        /// `iters` instances, W per call, each batch W copies of one point:
        /// every point takes the same branches (one run per call).
        fn bench_coherent(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = biases[(i / W) % NB];
                @call(.never_inline, evalBatch, .{&pts});
            }
        }
        // ---- a host-supplied point set (realistic bias from a circuit) ----
        var g_pts: []f64 = &.{};
        var g_sig: []u16 = &.{};
        fn bench_set_points(p: [*]const f64, count: usize) callconv(.c) void {
            const a = std.heap.page_allocator;
            if (g_pts.len != 0) a.free(g_pts);
            if (g_sig.len != count) {
                if (g_sig.len != 0) a.free(g_sig);
                g_sig = a.alloc(u16, count) catch unreachable;
                @memset(g_sig, 0);
            }
            g_pts = a.alloc(f64, count * n) catch unreachable;
            @memcpy(g_pts, p[0 .. count * n]);
        }
        fn point(k: usize) *const [n]f64 {
            return g_pts[k * n ..][0..n];
        }
        /// Sets a `Model` field by name (a model card value); false when none.
        fn bench_param(name: [*]const u8, len: usize, v: f64) callconv(.c) bool {
            @setEvalBranchQuota(1_000_000);
            const s = name[0..len];
            inline for (std.meta.fields(D.Model)) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, s)) {
                    switch (@typeInfo(f.type)) {
                        .float => @field(g_model, f.name) = v,
                        .int => @field(g_model, f.name) = std.math.lossyCast(f.type, @round(v)),
                        else => return false,
                    }
                    return true;
                }
            }
            return false;
        }
        /// Re-runs `derive`/`setup` on the current model (after `bench_param`).
        fn bench_resetup() callconv(.c) void {
            g_inst = .{};
            if (@hasDecl(D, "derive")) D.derive(Vv, &g_model);
            if (@hasDecl(D, "setup")) D.setup(Vv, &g_model);
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&g_model, &g_inst);
        }
        /// Signatures of every set point into `g_sig`; returns how many
        /// distinct ones there are.
        fn bench_signatures() callconv(.c) u64 {
            const count = g_sig.len;
            var seen = std.StaticBitSet(1 << 16).initEmpty();
            for (0..count) |k| {
                g_sig[k] = contract.region(D, point(k), &g_model, &g_inst, g_sim);
                seen.set(g_sig[k]);
            }
            return seen.count();
        }
        /// `iters` signatures (timing): one `contract.region` per instance.
        fn bench_sig_loop(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            var acc: u16 = 0;
            while (i < iters) : (i += 1) acc +%= @call(.never_inline, contract.region, .{ D, &biases[i % NB], &g_model, &g_inst, g_sim });
            std.mem.doNotOptimizeAway(acc);
        }
        /// Device runs for the set in batches of W: `grouped` sorts the
        /// points by signature first (a host's bucketing), else set order.
        fn bench_set_runs(grouped: bool) callconv(.c) u64 {
            const count = g_sig.len;
            const a = std.heap.page_allocator;
            const order = a.alloc(u32, count) catch unreachable;
            defer a.free(order);
            for (order, 0..) |*o, k| o.* = @intCast(k);
            if (grouped) std.mem.sort(u32, order, {}, struct {
                fn lt(_: void, x: u32, y: u32) bool {
                    return g_sig[x] < g_sig[y] or (g_sig[x] == g_sig[y] and x < y);
                }
            }.lt);
            B.runs = 0;
            var b: usize = 0;
            while (b + W <= count) : (b += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = point(order[b + w]).*;
                const r0 = B.runs;
                evalBatch(&pts);
                if (B.runs - r0 == 1) g_coherent += 1;
            }
            return B.runs;
        }
        var g_coherent: u64 = 0;
        fn bench_coherent_batches() callconv(.c) u64 {
            defer g_coherent = 0;
            return g_coherent;
        }
        /// Bit mismatches of the batched set (grouped) against scalar.
        fn bench_set_check() callconv(.c) u64 {
            var bad: u64 = 0;
            var b: usize = 0;
            while (b + W <= g_sig.len) : (b += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = point(b + w).*;
                evalBatch(&pts);
                if (comptime @import("cfg").SIG) {
                    const rg = B.Core_.lead.regions();
                    for (0..W) |w| if (rg[w] != contract.region(D, point(b + w), &g_model, &g_inst, g_sim)) {
                        bad += 1;
                    };
                }
                for (0..W) |w| {
                    var ref: [per]f64 = @splat(0);
                    evalScalar(point(b + w), &ref);
                    for (ref, g_out[w]) |x, y| {
                        if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y)) and !(x != x and y != y)) bad += 1;
                    }
                }
            }
            return bad;
        }
        /// Device runs per batched call over the 64 points in batches of W
        /// consecutive ones (`Family.runs`): NB / W runs means no batch
        /// diverged.
        fn bench_groups() callconv(.c) u64 {
            B.runs = 0;
            var b: usize = 0;
            while (b + W <= NB) : (b += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = biases[b + w];
                evalBatch(&pts);
            }
            return B.runs;
        }
        /// Number of batched outputs differing in bits from the scalar ones
        /// with W DISTINCT points per batch: the lead protocol's guarantee.
        /// `bench_check_mixed` under each analysis state a model branches on:
        /// static, transient Newton iteration 1 and 3, the initial step.
        fn bench_check_sims() callconv(.c) u64 {
            const keep = g_sim;
            defer g_sim = keep;
            const sims = [_]contract.SimState{
                .{ .kind = .dc, .analog_initial = false, .iteration = 1 },
                .{ .kind = .dc, .analog_initial = false, .iteration = 4 },
                .{ .kind = .tran, .t = 1e-9, .dt = 1e-12, .analog_initial = false, .iteration = 1 },
                .{ .kind = .tran, .t = 1e-9, .dt = 1e-12, .analog_initial = false, .iteration = 3 },
                .{ .kind = .tran, .t = 0, .dt = 1e-12, .initial_step = true, .analog_initial = false, .iteration = 1 },
            };
            var bad: u64 = 0;
            for (sims) |sm| {
                g_sim = sm;
                bad += bench_check_mixed();
            }
            return bad;
        }
        /// Per-lane instance state: W instances each driven through its own
        /// transient history (updateState + stateCtl commit at 6 accepted
        /// points of different bias), so their latches and held values
        /// differ; then every mixed batch, its lanes on those W instances,
        /// against each instance's scalar evalQ, bit for bit, and every instance byte-identical
        /// after the batched call (updateState stays per instance).
        /// Lane w's instance after its own transient history, then every
        /// real and integer field moved apart per lane (as the testbench's
        /// batch check does), so held values and latches surely differ.
        fn histInst(w: usize) D.Instance {
            var h = g_inst;
            var s = if (@hasDecl(D, "initState")) D.initState(&g_model, &h) else {};
            if (@hasDecl(D, "updateState")) for (0..6) |k| {
                var sm = g_sim;
                sm.t = 1e-12 * @as(f64, @floatFromInt(k + 1));
                _ = D.updateState(Vv, &g_model, &h, biases[(w * 11 + k * 5) % NB], &s, sm);
                if (@hasDecl(D, "stateCtl")) _ = D.stateCtl(&g_model, &h, &s, .commit);
            };
            const kf: f64 = @floatFromInt(w);
            if (w > 0) inline for (@typeInfo(D.Instance).@"struct".fields) |fl| {
                if (fl.type == f64) {
                    const v = @field(h, fl.name);
                    if (std.math.isFinite(v)) @field(h, fl.name) = v * (1.0 + 0.25 * kf) + 0.125 * kf;
                } else if (fl.type == i64) {
                    @field(h, fl.name) +%= @intCast(w);
                }
            };
            return h;
        }
        fn bench_check_hist() callconv(.c) u64 {
            var hist: [W]D.Instance = undefined;
            for (&hist, 0..) |*h, w| h.* = histInst(w);
            const snap = hist;
            var bad: u64 = 0;
            const keep = g_lane;
            defer g_lane = keep;
            for (0..W) |w| g_lane[w] = &hist[w];
            var b: usize = 0;
            while (b + W <= NB) : (b += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = biases[b + w];
                for (&g_out) |*o| @memset(o, 0);
                evalBatch(&pts);
                for (0..W) |w| {
                    var ref: [per]f64 = @splat(0);
                    evalScalarI(&biases[b + w], &hist[w], &ref);
                    for (ref, g_out[w]) |x, y| {
                        if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y)) and !(x != x and y != y)) bad += 1;
                    }
                    // The batched call reads instances, never writes them.
                    if (!std.mem.eql(u8, std.mem.asBytes(&hist[w]), std.mem.asBytes(&snap[w]))) bad += 1;
                }
            }
            return bad;
        }
        /// Whether the W history instances' latches and held values differ
        /// (the test above is only a test if they do): count of lanes whose
        /// instance bytes differ from lane 0's.
        fn bench_hist_distinct() callconv(.c) u64 {
            var hist: [W]D.Instance = undefined;
            var d: u64 = 0;
            for (&hist, 0..) |*h, w| {
                h.* = histInst(w);
                if (w > 0 and !std.mem.eql(u8, std.mem.asBytes(h), std.mem.asBytes(&hist[0]))) d += 1;
            }
            return d;
        }
        fn bench_check_mixed() callconv(.c) u64 {
            var bad: u64 = 0;
            var b: usize = 0;
            while (b + W <= NB) : (b += W) {
                var pts: [W][n]f64 = undefined;
                inline for (0..W) |w| pts[w] = biases[b + w];
                for (&g_out) |*o| @memset(o, 0);
                evalBatch(&pts);
                if (comptime @import("cfg").SIG) {
                    const rg = B.Core_.lead.regions();
                    for (0..W) |w| if (rg[w] != contract.region(D, &biases[b + w], &g_model, &g_inst, g_sim)) {
                        bad += 1;
                    };
                }
                for (0..W) |w| {
                    var ref: [per]f64 = @splat(0);
                    evalScalar(&biases[b + w], &ref);
                    for (ref, g_out[w]) |x, y| {
                        if (@as(u64, @bitCast(x)) != @as(u64, @bitCast(y)) and !(x != x and y != y)) bad += 1;
                    }
                }
            }
            return bad;
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
