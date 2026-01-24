const D = @import("device");

// Test-only scalar carrier: the generated display entry point needs a value
// and constructors, with no derivative lanes or owned storage.
const S = struct {
    v: f64,
    pub fn con(v: f64) S {
        return .{ .v = v };
    }
    pub fn val(a: S) f64 {
        return a.v;
    }
};

pub fn main() void {
    const model: D.Model = .{};
    var inst: D.Instance = .{};
    const n = @typeInfo(D.U).@"enum".fields.len;
    D.display(S, @as([n]S, @splat(S.con(0))), &model, &inst, 0);
}
