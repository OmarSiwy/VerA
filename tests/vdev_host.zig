//! `.v` contract devices (`rt.Device`, from `vera --emit-zig design.v`)
//! driven the way an analog host drives them: ARPice's operating point,
//! where a converged solve runs `updateState` (reverting an earlier attempt
//! first) and a request is one more iterate; and its transient, which
//! clamps each step to `pendingBreakpoint`, shrinks a step whose crossing ran
//! late to a quarter (never below `state_eps`), and commits what it accepts.
//! The circuits are sources and resistors on the pins, solved by Newton with
//! the device's own partials. The bridges are the defaults: vdd = 5 V,
//! vss = 0, vth = 2.5 V, rout = 1 Ω, trise = tfall = 1 ns.
//!
//! v_inv, a = 5 V, y to ground through 10 kΩ. The device is born with a = x,
//! so y = ~x = x, driven at (vdd + vss)/2 = 2.5 V. The first solve reads
//! a = 5 V > vth: y becomes 0, a flip; the second solve has y driven to 0 V,
//! so y = 0 and nothing moves: 2 iterates. With a = 0 V, y = 1 is 5 V through
//! rout into 10 kΩ: y = 5 · 10k / (10k + 1) V, again after one flip.
//!
//! v_buf, y -> 1 kΩ -> a -> 1 kΩ -> ground. Born at y = x (2.5 V), a = 1.25 V
//! < vth: y becomes 0, a flip; then y = a = 0 V holds: 2 iterates. v_inv in
//! the same loop with 2 kΩ below a has no fixed point: y = 1 gives
//! a = 5 · 2/3 V > vth, which makes y = 0, which gives a = 0 < vth, which
//! makes y = 1. The operating point fails.
//!
//! v_count, each q bit to ground through 10 kΩ. clk starts 0 and toggles
//! every 5 ns, so its rising edges are at 5 + 10(k-1) ns and q is k mod 4 from
//! the k-th. `pendingBreakpoint` names each event, so the host lands on every
//! 5 ns and each moved bit's ramp runs from that landing to 1 ns after it.
//! A step to 15 ns rejected after its event ran leaves 15 ns pending and q at
//! 1; accepted again, q is 2, not 3.
//!
//! v_a2d, a = 0.1 V/ns · t, vth = 0.52 V: a crosses at 5.2 ns, which is tick 5
//! of 1 ns (VAMS §8.4.3.3: the nearest tick). With `ttol` below `state_eps`,
//! the accepted crossing point is within `state_eps` after 5.2 ns, and z,
//! set 1 tick after the edge, is the next event: 6 ns. Under uic (no
//! operating point) a = 1 V from the start: the first sample drives a from x
//! to 1 at tick 0 with no crossing test, so the first step is not shrunk.
const std = @import("std");
const contract = @import("contract");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Link = struct { a: usize, b: usize, g: f64 };

fn Circuit(comptime D: type) type {
    const n = @typeInfo(D.U).@"enum".fields.len;
    const lanes = blk: {
        var l: [n]u8 = undefined;
        for (&l, 0..) |*x, i| x.* = i;
        break :blk l;
    };
    const S = contract.RefFamily(f64, &lanes, .{ .dense = true });
    return struct {
        const Self = @This();
        const Dev = D;
        const Fam = S;
        m: D.Model = .{},
        inst: D.Instance = .{},
        st: D.State = undefined,
        x: [n]f64 = @splat(0),
        /// Per pin, a source's voltage at time t, or null for a free node.
        src: [n]?*const fn (f64) f64 = @splat(null),
        /// Per pin, a conductance to ground.
        g_gnd: [n]f64 = @splat(0),
        links: []const Link = &.{},
        t: f64 = 0,
        /// The last accepted step.
        h: f64 = 0,

        fn pin(comptime name: []const u8) usize {
            return @intFromEnum(@field(D.U, name));
        }

        fn birth(c: *Self) void {
            c.st = D.initState(&c.m, &c.inst);
            _ = D.stateCtl(&c.m, &c.inst, &c.st, .commit);
        }

        /// Newton at `sim` until no unknown moves more than 1e-12 V.
        fn solve(c: *Self, sim: contract.SimState) !void {
            for (0..50) |_| {
                for (c.src, &c.x) |f, *x| if (f) |v| {
                    x.* = v(sim.t);
                };
                const r = D.eval(S, &c.x, &c.m, &c.inst, sim);
                var j: [n][n]f64 = undefined;
                var f: [n]f64 = undefined;
                inline for (0..n) |u| {
                    f[u] = r[u].v;
                    j[u] = r[u].d;
                }
                for (0..n) |u| {
                    f[u] += c.g_gnd[u] * c.x[u];
                    j[u][u] += c.g_gnd[u];
                }
                for (c.links) |l| {
                    const i = l.g * (c.x[l.a] - c.x[l.b]);
                    f[l.a] += i;
                    f[l.b] -= i;
                    j[l.a][l.a] += l.g;
                    j[l.a][l.b] -= l.g;
                    j[l.b][l.b] += l.g;
                    j[l.b][l.a] -= l.g;
                }
                for (c.src, 0..) |v, u| if (v != null) {
                    j[u] = @splat(0);
                    j[u][u] = 1;
                    f[u] = 0;
                };
                const d = gauss(&j, &f);
                var big: f64 = 0;
                for (&c.x, d) |*x, dx| {
                    x.* += dx;
                    big = @max(big, @abs(dx));
                }
                if (big <= 1e-12) return;
            }
            return error.NoConvergence;
        }

        /// Solves `j · d = -f` by elimination with partial pivoting.
        fn gauss(j: *[n][n]f64, f: *[n]f64) [n]f64 {
            for (0..n) |k| {
                var p = k;
                for (k + 1..n) |i| if (@abs(j[i][k]) > @abs(j[p][k])) {
                    p = i;
                };
                std.mem.swap([n]f64, &j[k], &j[p]);
                std.mem.swap(f64, &f[k], &f[p]);
                for (k + 1..n) |i| {
                    const q = j[i][k] / j[k][k];
                    for (k..n) |col| j[i][col] -= q * j[k][col];
                    f[i] -= q * f[k];
                }
            }
            var d: [n]f64 = undefined;
            var k = n;
            while (k > 0) {
                k -= 1;
                var s = -f[k];
                for (k + 1..n) |col| s -= j[k][col] * d[col];
                d[k] = s / j[k][k];
            }
            return d;
        }

        /// The operating point: the iterates it took.
        fn op(c: *Self) !u32 {
            const sim: contract.SimState = .{};
            var ran = false;
            for (1..21) |it| {
                try c.solve(sim);
                if (ran) _ = D.stateCtl(&c.m, &c.inst, &c.st, .revert);
                ran = true;
                if (D.updateState(S, &c.m, &c.inst, c.x, &c.st, sim) == .ok) {
                    _ = D.stateCtl(&c.m, &c.inst, &c.st, .commit);
                    return @intCast(it);
                }
            }
            return error.NoFixedPoint;
        }

        fn at(t: f64) contract.SimState {
            return .{ .t = t, .kind = .tran, .analog_initial = false };
        }

        /// One accepted point: a step of at most `dt_max`, twice the last,
        /// clamped to the next breakpoint.
        fn step(c: *Self, dt_max: f64, eps: f64) !void {
            var dt = if (c.h == 0) dt_max else @min(2 * c.h, dt_max);
            if (D.pendingBreakpoint(&c.inst, c.t)) |bp| dt = @min(dt, bp - c.t);
            while (true) {
                var sim = at(c.t + dt);
                sim.dt = dt;
                try c.solve(sim);
                _ = D.updateState(S, &c.m, &c.inst, c.x, &c.st, sim);
                if (dt > eps and D.stateCtl(&c.m, &c.inst, &c.st, .query)) {
                    _ = D.stateCtl(&c.m, &c.inst, &c.st, .revert);
                    dt = @max(dt / 4, eps);
                    continue;
                }
                _ = D.stateCtl(&c.m, &c.inst, &c.st, .commit);
                c.t += dt;
                c.h = dt;
                return;
            }
        }
    };
}

fn volts(comptime v: f64) *const fn (f64) f64 {
    return struct {
        fn f(_: f64) f64 {
            return v;
        }
    }.f;
}

test "v_inv: the operating point is the digital fixed point after one flip" {
    const C = Circuit(@import("v_inv"));
    for ([2]f64{ 5, 0 }, [2]f64{ 0, 5.0 * 1e4 / (1e4 + 1) }) |a, y| {
        var c: C = .{};
        c.src[C.pin("a")] = if (a == 5) volts(5) else volts(0);
        c.g_gnd[C.pin("y")] = 1e-4;
        c.birth();
        try expectEqual(@as(u32, 2), try c.op());
        try std.testing.expectApproxEqAbs(y, c.x[C.pin("y")], 1e-12);
    }
}

test "v_buf: a fixed point through a divider in 2 iterates; v_inv in the loop has none" {
    const B = Circuit(@import("v_buf"));
    var b: B = .{ .links = &.{.{ .a = B.pin("y"), .b = B.pin("a"), .g = 1e-3 }} };
    b.g_gnd[B.pin("a")] = 1e-3;
    b.birth();
    try expectEqual(@as(u32, 2), try b.op());
    try std.testing.expectApproxEqAbs(0, b.x[B.pin("y")], 1e-12);

    const I = Circuit(@import("v_inv"));
    var i: I = .{ .links = &.{.{ .a = I.pin("y"), .b = I.pin("a"), .g = 1e-3 }} };
    i.g_gnd[I.pin("a")] = 0.5e-3;
    i.birth();
    try std.testing.expectError(error.NoFixedPoint, i.op());
}

test "v_count: the host lands on every edge, the ramps start there, and a rejected edge does not count twice" {
    const C = Circuit(@import("v_count"));
    var c: C = .{};
    c.g_gnd[C.pin("q[1]")] = 1e-4;
    c.g_gnd[C.pin("q[0]")] = 1e-4;
    c.birth();
    try expectEqual(@as(u32, 1), try c.op());
    const dt_max = 1e-9;
    const eps = 5e-5 * dt_max;
    var edges: u32 = 0;
    while (c.t < 42e-9) {
        const edge = 5e-9 + 10e-9 * @as(f64, @floatFromInt(edges));
        if (edges == 1 and C.Dev.pendingBreakpoint(&c.inst, c.t) == edge) {
            // The step onto 15 ns runs its event, and is rejected.
            var sim = C.at(edge);
            sim.dt = edge - c.t;
            try c.solve(sim);
            _ = C.Dev.updateState(C.Fam, &c.m, &c.inst, c.x, &c.st, sim);
            try expectEqual(@as(f64, 5), c.inst.lvl_to[0]);
            _ = C.Dev.stateCtl(&c.m, &c.inst, &c.st, .revert);
            try expectEqual(@as(?f64, edge), C.Dev.pendingBreakpoint(&c.inst, c.t));
            try expectEqual(@as(f64, 0), c.inst.lvl_to[0]);
        }
        try c.step(dt_max, eps);
        if (@abs(c.t - edge) > 1e-20) continue;
        edges += 1;
        const q = edges % 4;
        // Output index 0 is q[1], 1 is q[0] (pin order).
        try expectEqual(@as(f64, if (q & 2 != 0) 5 else 0), c.inst.lvl_to[0]);
        try expectEqual(@as(f64, if (q & 1 != 0) 5 else 0), c.inst.lvl_to[1]);
        // Bit 0 moves at every edge: its ramp is this landing plus trise.
        try expectEqual(c.t, c.inst.lvl_t0[1]);
        try expectEqual(c.t + 1e-9, c.inst.lvl_t1[1]);
        try expectEqual(@as(?f64, c.t + 1e-9), C.Dev.pendingBreakpoint(&c.inst, c.t));
    }
    try expectEqual(@as(u32, 4), edges);
}

test "v_a2d: an edge at 5.2 ns reaches the engine at tick 5" {
    const C = Circuit(@import("v_a2d"));
    var c: C = .{};
    c.src[C.pin("a")] = struct {
        fn f(t: f64) f64 {
            return 0.1e9 * t;
        }
    }.f;
    c.g_gnd[C.pin("y")] = 1e-4;
    c.g_gnd[C.pin("z")] = 1e-4;
    c.m.vth = 0.52;
    c.m.ttol = 1e-15;
    c.birth();
    _ = try c.op();
    const dt_max = 1e-9;
    const eps = 5e-5 * dt_max;
    while (c.inst.lvl_to[0] != 5) try c.step(dt_max, eps);
    try expect(c.t >= 5.2e-9 and c.t - 5.2e-9 <= eps);
    try expectEqual(@as(?f64, 6e-9), C.Dev.pendingBreakpoint(&c.inst, c.t));
    try expectEqual(@as(f64, 0), c.inst.lvl_to[1]);
    while (c.t < 6e-9) try c.step(dt_max, eps);
    try expectEqual(@as(f64, 5), c.inst.lvl_to[1]);
}

test "v_a2d under uic: the first sample is the reference, not a crossing" {
    const C = Circuit(@import("v_a2d"));
    var c: C = .{};
    c.src[C.pin("a")] = volts(1);
    c.g_gnd[C.pin("y")] = 1e-4;
    c.g_gnd[C.pin("z")] = 1e-4;
    c.m.vth = 0.52;
    c.m.ttol = 1e-15;
    c.birth();
    // No operating point: the first transient step is the first sample. It
    // drives a from x to 1 at tick 0 (a rising edge, §9.7.2), so z rises at
    // tick 1, and no crossing is late, so the step is accepted whole.
    try c.step(1e-9, 5e-14);
    try expectEqual(@as(f64, 1e-9), c.t);
    try expectEqual(@as(f64, 5), c.inst.lvl_to[0]);
    try expectEqual(@as(f64, 5), c.inst.lvl_to[1]);
}
