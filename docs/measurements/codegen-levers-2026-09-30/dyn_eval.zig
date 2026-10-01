//! Build-speed host: all generated-device lifecycle entry points -> CPU/GPU
//! artifact. Residual, charge and sparse f64 Jacobians are materialized.
//! No simulation, timing loop or accuracy checker is linked into this artifact.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");

pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    const A = Api(D);
    @export(&A.device_eval, .{ .name = "device_eval" });
    if (@import("builtin").mode != .Debug or true) {
        @export(&A.bench_setup, .{ .name = "bench_setup" });
        @export(&A.bench_loop, .{ .name = "bench_loop" });
        @export(&A.bench_hash, .{ .name = "bench_hash" });
        @export(&A.bench_nu, .{ .name = "bench_nu" });
        if (A.ARP) {
            @export(&A.bench_loop_eval, .{ .name = "bench_loop_eval" });
            @export(&A.bench_loop_q, .{ .name = "bench_loop_q" });
        }
    }
}

fn Api(comptime D: type) type {
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
            const ext = @extern(*const fn (*D.Model, *D.Instance, f64) callconv(cc) void, .{ .name = "device_setup" });
            ext(&g_model, &g_inst, 300.15);
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
        const arp_on = false;
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
