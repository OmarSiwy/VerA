const std = @import("std");
const D = @import("device");

const S = struct {
    v: f64,
    pub fn con(v: f64) S {
        return .{ .v = v };
    }
    pub fn val(a: S) f64 {
        return a.v;
    }
    pub fn add(a: S, b: S) S {
        return con(a.v + b.v);
    }
    pub fn sub(a: S, b: S) S {
        return con(a.v - b.v);
    }
    pub fn neg(a: S) S {
        return con(-a.v);
    }
    pub fn scale(a: S, b: f64) S {
        return con(a.v * b);
    }
    pub fn addC(a: S, b: f64) S {
        return con(a.v + b);
    }
    pub fn abs(a: S) S {
        return con(@abs(a.v));
    }
    pub fn div(a: S, b: S) S {
        return con(a.v / b.v);
    }
    pub fn sel(c: S, a: S, b: S) S {
        return if (c.v != 0) a else b;
    }
    pub fn mul(a: S, b: S) S {
        return con(a.v * b.v);
    }
    pub fn lt(a: S, b: S) S {
        return con(if (a.v < b.v) 1 else 0);
    }
    pub fn le(a: S, b: S) S {
        return con(if (a.v <= b.v) 1 else 0);
    }
};

test "first-call tables are per instance and survive rejected trial rollback" {
    const model: D.Model = .{};
    const n = @typeInfo(D.U).@"enum".fields.len;
    const x: [n]S = @splat(S.con(0));
    var a: D.Instance = .{};
    var state = D.initState(&model, &a);
    try std.testing.expectEqual(2, D.eval(S, x, &model, &a, 0)[@intFromEnum(D.U.p)].v);
    _ = D.stateCtl(&model, &a, &state, .commit);
    a.abstime = 1;
    try std.testing.expectEqual(13, D.eval(S, x, &model, &a, 1)[@intFromEnum(D.U.p)].v);
    _ = D.stateCtl(&model, &a, &state, .revert);
    a.abstime = 2;
    try std.testing.expectEqual(13, D.eval(S, x, &model, &a, 2)[@intFromEnum(D.U.p)].v);
    var b: D.Instance = .{};
    var b_state = D.initState(&model, &b);
    const plain: [n]f64 = @splat(0);
    _ = D.seed(&model, &b);
    _ = D.limit(&model, &b, plain, plain);
    _ = D.checkConvergence(&model, &b, plain);
    D.advanceIteration(&model, &b, plain);
    _ = D.updateState(&model, &b, plain, &b_state);
    b.abstime = 2;
    try std.testing.expectEqual(37, D.eval(S, x, &model, &b, 2)[@intFromEnum(D.U.p)].v);
    b.abstime = 3;
    try std.testing.expectEqual(37, D.eval(S, x, &model, &b, 3)[@intFromEnum(D.U.p)].v);
}
