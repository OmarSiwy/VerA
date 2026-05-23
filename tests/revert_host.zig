//! §4.5 device-held history across a REJECTED time step: `stateCtl(.revert)`
//! leaves every operator, §5.10 held variable and §9.13.1 internal seed as the
//! last accepted point left it. A discarded attempt is not an instant of the
//! waveform, so the run that rejects shall read, row for row and bit for bit,
//! what the run that never tried the step reads.
//!
//! The device is tests/revert_ops.va, one construct per output row. Both runs
//! accept the same points; the rejecting one also tries 4ns with V(a) = -1
//! after the 1ns point, twice, reverting each time. That attempt moves every
//! row's history: it crosses 0.5 falling (cross, last_crossing), leaves
//! `above` below its threshold before a retry above it, passes timer and
//! sampling instants, steps the filters, integrators and ramps, pushes a delay
//! sample, and draws from the seed. `zig build test` emits the device and runs
//! this file.

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".fields.len;

/// The reference family with no lanes: nothing here asks for a Jacobian.
const S = contract.RefFamily(f64, &(.{contract.no_lane} ** n_u), .{ .dense = true });

/// (t, V(a)) at each accepted point, and the attempt rejected after the second.
const points = [_][2]f64{ .{ 0, 0 }, .{ 1e-9, 1 }, .{ 2e-9, 1 }, .{ 3e-9, 0 }, .{ 4e-9, 1 } };
const trial = [2]f64{ 4e-9, -1 };

const Run = struct {
    /// Each accepted point's residual, read before its `updateState`.
    r: [points.len][n_u]f64 = undefined,
    inst: D.Instance = .{},
    state: D.State = .{},
    /// The device at the 1ns point, and again after the last revert.
    accepted: struct { D.Instance, D.State } = undefined,
    reverted: struct { D.Instance, D.State } = undefined,
};

fn run(rejects: usize) Run {
    const model: D.Model = .{};
    var out: Run = .{};
    out.state = D.initState(&model, &out.inst);
    var t_prev: f64 = 0;
    for (points, 0..) |p, k| {
        if (k == 2) {
            out.accepted = .{ out.inst, out.state };
            for (0..rejects) |_| {
                _ = D.updateState(S, &model, &out.inst, bias(trial[1]), &out.state, simAt(trial[0], t_prev, false));
                _ = D.stateCtl(&model, &out.inst, &out.state, .revert);
            }
            out.reverted = .{ out.inst, out.state };
        }
        const sim = simAt(p[0], t_prev, k == 0);
        const x = bias(p[1]);
        const r: [n_u]S = D.eval(S, &x, &model, &out.inst, sim);
        for (r, 0..) |v, i| out.r[k][i] = v.v;
        _ = D.updateState(S, &model, &out.inst, x, &out.state, sim);
        _ = D.stateCtl(&model, &out.inst, &out.state, .commit);
        t_prev = p[0];
    }
    return out;
}

fn simAt(t: f64, t_prev: f64, dc: bool) contract.SimState {
    return .{ .t = t, .dt = t - t_prev, .kind = if (dc) .dc else .tran, .initial_step = dc, .analog_initial = dc };
}

fn bias(a: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@intFromEnum(D.U.a)] = a;
    return x;
}

fn expectRow(row: D.U) !void {
    const want = run(0);
    const got = run(2);
    for (want.r, got.r) |w, g| try std.testing.expectEqual(w[@intFromEnum(row)], g[@intFromEnum(row)]);
}

test "§4.5.8 transition" {
    try expectRow(.o_tr);
}
test "§4.5.7 absdelay" {
    try expectRow(.o_ad);
}
test "§4.5.9 slew" {
    try expectRow(.o_sl);
}
test "§4.5.11 laplace" {
    try expectRow(.o_lp);
}
test "§4.5.12 zi" {
    try expectRow(.o_zi);
}
test "§4.5.10 last_crossing" {
    try expectRow(.o_lc);
}
test "§5.10.3.1 cross-held variable" {
    try expectRow(.o_cr);
}
test "§5.10.3.2 above-held variable" {
    try expectRow(.o_ab);
}
test "§5.10.3.3 timer-held variable" {
    try expectRow(.o_tm);
}
test "§4.5.5 idtmod" {
    try expectRow(.o_im);
}
test "§9.13.1 $arandom internal seed" {
    try expectRow(.o_rn);
}
test "§4.5 a revert leaves no field of Instance or State behind" {
    const want = run(0);
    const got = run(2);
    try std.testing.expectEqualDeep(got.accepted, got.reverted);
    try std.testing.expectEqualDeep(want.inst, got.inst);
    try std.testing.expectEqualDeep(want.state, got.state);
}
