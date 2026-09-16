const std = @import("std");
const D = @import("device");
const Default = @import("default_device");

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

var expected: []const u8 = "unexpected panic";
pub const panic = std.debug.FullPanic(expectRuntimeError);
fn expectRuntimeError(message: []const u8, _: ?usize) noreturn {
    if (std.mem.indexOf(u8, message, expected) != null) std.process.exit(0);
    std.debug.print("unexpected panic: {s}\n", .{message});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const case = try std.fmt.parseInt(u8, args.next() orelse return 2, 10);
    var model: D.Model = .{};
    model.mean = 0;
    var inst: D.Instance = .{};
    var volts: f64 = 0;
    var should_fail = false;
    switch (case) {
        0 => should_fail = true, // original unused-result/unused-seed reproducer
        1 => volts = 2,
        2...11 => {
            model.mode = 1 + (case - 2) / 2;
            should_fail = case & 1 != 0;
            volts = if (should_fail) 1 else 0;
        },
        12, 13 => {
            model.mode = if (case == 12) 6 else 7;
            volts = 1.5;
            should_fail = true;
        },
        14 => {
            model.mode = 8;
            should_fail = true;
        },
        15 => model.mode = 9,
        16 => model.mode = 10,
        17 => {
            model.mode = 11;
            should_fail = true;
        },
        18...25 => {
            model.mode = 12 + (case - 18) / 2;
            should_fail = case & 1 != 0;
            volts = if (should_fail) 1 else 0;
        },
        26 => model.mode = 16,
        27 => {
            model.mode = 17;
            model.mean = 2; // replace the declared invalid default before evaluation
        },
        28...31 => {
            model.mode = 18 + (case - 28) / 2;
            should_fail = case & 1 != 0;
            volts = if (should_fail) 1 else 0;
        },
        32, 33 => should_fail = case == 32,
        else => return 2,
    }
    expected = switch (case) {
        12, 29 => "fractional or out-of-range",
        13, 31 => "start shall be smaller than end",
        else => "shall be greater than zero",
    };
    if (!should_fail) expected = "unexpected panic";
    if (case >= 32) {
        var default_model: Default.Model = .{};
        if (case == 33) default_model.mean = 2;
        var default_inst: Default.Instance = .{};
        const size = @typeInfo(Default.U).@"enum".fields.len;
        const values: [size]S = @splat(S.con(0));
        _ = Default.eval(S, values, &default_model, &default_inst, 0);
        return if (should_fail) 1 else 0;
    }
    const n = @typeInfo(D.U).@"enum".fields.len;
    var x: [n]S = @splat(S.con(0));
    x[@intFromEnum(D.U.p)] = S.con(volts);
    const res = D.eval(S, x, &model, &inst, 0);
    if (should_fail or res[@intFromEnum(D.U.p)].v != volts) return 1;
    return 0;
}
