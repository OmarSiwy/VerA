//! Device-runtime bench host (from codegen-levers-2026-09-30/dyn_bench.zig):
//! the --emit-so entry points plus timing loops for evalQ (sparse f64 duals),
//! eval(S), q(V), updateState(V) and a transient-like step (3 evalQ + 1
//! updateState + stateCtl(.commit) at an advancing $abstime), and FNV hashes
//! of every output.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");

pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    const A = Api(D, name);
    @export(&A.device_eval, .{ .name = "device_eval" });
    @export(&A.device_setup, .{ .name = "device_setup" });
    @export(&A.device_init, .{ .name = "device_init" });
    @export(&A.device_update, .{ .name = "device_update" });
    @export(&A.device_control, .{ .name = "device_control" });
    @export(&A.device_breakpoint, .{ .name = "device_breakpoint" });
    if (@import("builtin").mode != .Debug or true) {
        @export(&A.bench_setup, .{ .name = "bench_setup" });
        @export(&A.bench_loop, .{ .name = "bench_loop" });
        @export(&A.bench_hash, .{ .name = "bench_hash" });
        @export(&A.bench_nu, .{ .name = "bench_nu" });
        if (A.ARP) {
            @export(&A.bench_loop_eval, .{ .name = "bench_loop_eval" });
            @export(&A.bench_loop_q, .{ .name = "bench_loop_q" });
        }
        @export(&A.bench_loop_tran, .{ .name = "bench_loop_tran" });
        @export(&A.bench_loop_update, .{ .name = "bench_loop_update" });
        @export(&A.bench_hash_tran, .{ .name = "bench_hash_tran" });
    }
}

fn Api(comptime D: type, comptime name: []const u8) type {
    return struct {
        const n = contract.nU(D);
        const gpu = builtin.cpu.arch == .nvptx64 or builtin.cpu.arch == .amdgcn;
        const cc: std.builtin.CallingConvention = if (gpu) .kernel else .c;
        const lanes = blk: {
            var a: [n]u8 = undefined;
            for (&a, 0..) |*v, i| v.* = @intCast(i);
            break :blk a;
        };
        const S = contract.RefFamily(f64, &lanes, .{ .dense = false });
        const V = contract.RefFamily(f64, &(.{contract.no_lane} ** n), .{ .dense = true });
        const State = if (@hasDecl(D, "State")) D.State else u8;

        fn device_eval(x: *const [n]f64, model: *const D.Model, inst: *D.Instance, out: [*]f64, sim: *const contract.SimState) callconv(cc) void {
            if (@hasDecl(D, "evalQ")) {
                const both = D.evalQ(S, x, model, inst, sim.*);
                write(both.res, out, 0);
                write(both.q, out, n);
            } else {
                write(D.eval(S, x, model, inst, sim.*), out, 0);
                if (@hasDecl(D, "q")) write(D.q(S, x, model, inst, sim.*), out, n);
            }
        }

        fn write(rows: anytype, out: [*]f64, comptime first: usize) void {
            inline for (rows, 0..) |v, row| {
                out[(first + row) * (n + 1)] = v.val();
                inline for (0..n) |col| out[(first + row) * (n + 1) + 1 + col] = v.ddxAt(col);
            }
        }

        fn device_setup(model: *D.Model, inst: *D.Instance, temperature: f64) callconv(cc) void {
            if (@hasField(D.Instance, "temperature")) inst.temperature = temperature;
            if (@hasDecl(D, "derive")) D.derive(V, model);
            if (@hasDecl(D, "setup")) D.setup(V, model, inst);
        }

        fn device_init(model: *const D.Model, inst: *D.Instance, state: *State) callconv(cc) void {
            if (@hasDecl(D, "initState")) state.* = D.initState(model, inst) else state.* = 0;
        }

        fn device_update(x: *const [n]f64, model: *const D.Model, inst: *D.Instance, state: *State, sim: *const contract.SimState, result: *u32, reject_at: *f64) callconv(cc) void {
            if (@hasDecl(D, "updateState")) {
                const update = D.updateState(V, model, inst, x.*, state, sim.*);
                result.* = @intFromEnum(update);
                reject_at.* = switch (update) {
                    .ok => 0,
                    .request_reject_at => |t| t,
                };
            } else result.* = 0;
        }

        fn device_control(model: *const D.Model, inst: *D.Instance, state: *State, op: u8, result: *u32) callconv(cc) void {
            result.* = if (@hasDecl(D, "stateCtl")) @intFromBool(D.stateCtl(model, inst, state, @enumFromInt(op % 3))) else 0;
        }

        fn device_breakpoint(inst: *const D.Instance, t: f64, out: *f64) callconv(cc) void {
            out.* = if (@hasDecl(D, "pendingBreakpoint")) D.pendingBreakpoint(inst, t) orelse std.math.inf(f64) else std.math.inf(f64);
        }

        // ---- bench additions (scratch, codegen-levers study) ----
        const NB = 64;
        var g_model: D.Model = .{};
        var g_inst: D.Instance = .{};
        var g_out: [2 * n * (n + 1)]f64 = undefined;
        var g_sim: contract.SimState = .{ .kind = .tran, .t = 1e-9, .dt = 1e-12, .analog_initial = false, .iteration = 3 };
        fn bias(k: usize) [n]f64 {
            var x: [n]f64 = undefined;
            for (&x, 0..) |*v, u| v.* = 0.05 * @as(f64, @floatFromInt((k * 7 + u * 13) % 23)) - 0.1;
            return x;
        }
        const biases: [NB][n]f64 = blk: {
            @setEvalBranchQuota(10_000_000);
            var b: [NB][n]f64 = undefined;
            for (&b, 0..) |*r, k| r.* = bias(k);
            break :blk b;
        };
        fn bench_nu() callconv(.c) u32 {
            return n;
        }
        fn bench_setup() callconv(.c) void {
            g_model = .{};
            g_inst = .{};
            params(&g_model);
            device_setup(&g_model, &g_inst, 300.15);
        }
        fn bench_loop(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) {
                @call(.never_inline, device_eval, .{ &biases[i % NB], &g_model, &g_inst, &g_out, &g_sim });
            }
        }
        fn mix(h: u64, v: f64) u64 {
            return (h ^ @as(u64, @bitCast(v))) *% 0x100000001b3 +% 0x9e3779b97f4a7c15;
        }
        fn bench_hash() callconv(.c) u64 {
            var h: u64 = 0xcbf29ce484222325;
            for (0..NB) |k| {
                @memset(&g_out, 0);
                @call(.never_inline, device_eval, .{ &biases[k], &g_model, &g_inst, &g_out, &g_sim });
                for (g_out) |v| h = mix(h, v);
                if (ARP) {
                    const e = @call(.never_inline, evalS, .{&biases[k]});
                    for (e) |v| h = mix(h, v);
                    const qv = @call(.never_inline, qV, .{&biases[k]});
                    for (qv) |v| h = mix(h, v);
                }
            }
            return h;
        }
        const ARP = arp_on;
        const arp_on = @hasDecl(D, "eval");

        /// A scalarized parameter-array element: `r[2]` is the field `rZ5b2Z5d`.
        fn set(m: *D.Model, comptime base: []const u8, comptime i: usize, v: anytype) void {
            const f = &@field(m, std.fmt.comptimePrint("{s}Z5b{d}Z5d", .{ base, i }));
            f.* = if (@TypeOf(f.*) == f64) v else @intCast(v);
        }

        /// Workload cards (ARPice tests/pending/X01 txl_tran_matched_step,
        /// cpl_op_dc_decoupled's cmod, a 13-op bsource tape); every other
        /// device keeps its defaults.
        fn params(m: *D.Model) void {
            if (comptime std.mem.eql(u8, name, "txl")) {
                m.r = 1e-6;
                m.l = 250e-9;
                m.c = 100e-12;
                m.len = 2;
            } else if (comptime std.mem.eql(u8, name, "coupled_ltra")) {
                set(m, "r", 0, 2);
                set(m, "r", 2, 2);
                set(m, "l", 0, 250e-9);
                set(m, "l", 1, 150e-9);
                set(m, "l", 2, 250e-9);
                set(m, "c", 0, 100e-12);
                set(m, "c", 1, -60e-12);
                set(m, "c", 2, 100e-12);
                m.length = 3;
            } else if (comptime std.mem.eql(u8, name, "bsource")) {
                // y = c0*c1 + exp(c0 - c1) - 2*c2 + sin(c3): 13 ops, depth 3.
                const ops = [_][3]i64{
                    .{ 1, 0, 0 }, .{ 1, 1, 0 },  .{ 7, 0, 0 }, .{ 2, 0, 1 }, .{ 25, 0, 0 },
                    .{ 5, 0, 0 }, .{ 0, 0, 0 },  .{ 1, 2, 0 }, .{ 7, 0, 0 }, .{ 6, 0, 0 },
                    .{ 1, 3, 0 }, .{ 28, 0, 0 }, .{ 5, 0, 0 },
                };
                m.n_ops = ops.len;
                inline for (ops, 0..) |o, k| {
                    set(m, "op_code", k, o[0]);
                    set(m, "op_a", k, o[1]);
                    set(m, "op_b", k, o[2]);
                }
                set(m, "consts", 0, 2.0);
            }
        }

        // ---- transient-like timeline: step k at t = (k mod period)*dt, 3
        // Newton evaluations then one accepted updateState; re-initialised
        // every `period` steps so history-bounded work stays stationary. ----
        const period = 512;
        const tdt = 20e-12;
        var g_state: State = undefined;
        var g_k: u64 = 0;
        fn tranX(k: u64) [n]f64 {
            var x: [n]f64 = undefined;
            const ph: f64 = @floatFromInt(k % 37);
            for (&x, 0..) |*v, u| v.* = 0.01 * @sin(0.3 * ph + @as(f64, @floatFromInt(u))) + 0.002 * @as(f64, @floatFromInt(u));
            return x;
        }
        fn tranSim(k: u64, it: u32) contract.SimState {
            const j = k % period;
            return .{ .kind = .tran, .t = @as(f64, @floatFromInt(j)) * tdt, .dt = tdt, .initial_step = j == 0, .analog_initial = j == 0, .iteration = it };
        }
        fn tranReset() void {
            device_init(&g_model, &g_inst, &g_state);
        }
        fn tranStep(k: u64, h: ?*u64) void {
            if (k % period == 0) tranReset();
            const x = tranX(k);
            var it: u32 = 1;
            while (it <= 3) : (it += 1) {
                const sim = tranSim(k, it);
                @call(.never_inline, device_eval, .{ &x, &g_model, &g_inst, &g_out, &sim });
                if (h) |hp| for (g_out) |v| {
                    hp.* = mix(hp.*, v);
                };
            }
            const sim = tranSim(k, 4);
            var res: u32 = 0;
            var rej: f64 = 0;
            @call(.never_inline, device_update, .{ &x, &g_model, &g_inst, &g_state, &sim, &res, &rej });
            if (h) |hp| hp.* = mix(hp.*, rej + @as(f64, @floatFromInt(res)));
            // The accepted point: a host latches it (stateCtl(.commit)).
            var cr: u32 = 0;
            @call(.never_inline, device_control, .{ &g_model, &g_inst, &g_state, 1, &cr });
        }
        fn bench_loop_tran(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) {
                tranStep(g_k, null);
                g_k += 1;
            }
        }
        fn bench_loop_update(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) {
                if (g_k % period == 0) tranReset();
                const x = tranX(g_k);
                const sim = tranSim(g_k, 4);
                var res: u32 = 0;
                var rej: f64 = 0;
                @call(.never_inline, device_update, .{ &x, &g_model, &g_inst, &g_state, &sim, &res, &rej });
                g_k += 1;
            }
        }
        fn bench_hash_tran() callconv(.c) u64 {
            var h: u64 = 0xcbf29ce484222325;
            g_k = 0;
            for (0..2 * period + 50) |k| tranStep(k, &h);
            g_k = 0;
            return h;
        }
        fn evalS(x: *const [n]f64) [n * (n + 1)]f64 {
            var o: [n * (n + 1)]f64 = undefined;
            write(D.eval(S, x, &g_model, &g_inst, g_sim), &o, 0);
            return o;
        }
        fn qV(x: *const [n]f64) [n]f64 {
            var o: [n]f64 = @splat(0);
            if (@hasDecl(D, "q")) {
                const qs = D.q(V, x, &g_model, &g_inst, g_sim);
                inline for (qs, 0..) |v, i| if (i < n) {
                    o[i] = v.val();
                };
            }
            return o;
        }
        fn bench_loop_eval(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) {
                const o = @call(.never_inline, evalS, .{&biases[i % NB]});
                g_out[0] = o[0];
            }
        }
        fn bench_loop_q(iters: u64) callconv(.c) void {
            var i: u64 = 0;
            while (i < iters) : (i += 1) {
                const o = @call(.never_inline, qV, .{&biases[i % NB]});
                g_out[0] = o[0];
            }
        }

        comptime {
            contract.validate(D);
        }
    };
}
