const std = @import("std");
const D = @import("device");

test "limiter state advances by generation and reverts a rejected attempt" {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);
    var x: [@typeInfo(D.U).@"enum".fields.len]f64 = @splat(0.0);
    x[@intFromEnum(D.U.p)] = 5.0;

    try std.testing.expect(!D.checkConvergence(&model, &inst, x));
    D.advanceIteration(&model, &inst, x);
    try std.testing.expectEqual(2, inst.newton_iteration);
    try std.testing.expectApproxEqAbs(0.7, inst.limiter_previous[0], 1e-12);
    try std.testing.expect(!D.checkConvergence(&model, &inst, x));
    D.advanceIteration(&model, &inst, x);
    try std.testing.expectEqual(3, inst.newton_iteration);
    try std.testing.expectApproxEqAbs(1.7, inst.limiter_previous[0], 1e-12);

    try std.testing.expect(!D.stateCtl(&model, &inst, &state, .query));
    _ = D.stateCtl(&model, &inst, &state, .commit);
    const accepted = inst;
    try std.testing.expect(!D.checkConvergence(&model, &inst, x));
    D.advanceIteration(&model, &inst, x);
    try std.testing.expect(!D.checkConvergence(&model, &inst, x));
    D.advanceIteration(&model, &inst, x);
    _ = D.stateCtl(&model, &inst, &state, .revert);
    try std.testing.expectEqualDeep(accepted, inst);
    for (0..8) |_| {
        if (D.checkConvergence(&model, &inst, x)) break;
        D.advanceIteration(&model, &inst, x);
    } else return error.LimiterDidNotConverge;
    try std.testing.expectApproxEqAbs(4.7, inst.limiter_previous[0], 1e-12);
    const iteration = inst.newton_iteration;
    _ = D.stateCtl(&model, &inst, &state, .commit);
    try std.testing.expectEqual(iteration, inst.newton_iteration);
    try std.testing.expect(D.checkConvergence(&model, &inst, x));
    D.beginSolve(&inst);
    try std.testing.expectEqual(1, inst.newton_iteration);
    try std.testing.expect(!D.checkConvergence(&model, &inst, x));
}
