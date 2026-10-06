//! A `--dyn` module: `vera --emit-so` compiles it with the generated device
//! and calls `exportDevice(D, name)` once, at compile time. Whatever it
//! exports is the shared library's interface; here, one C-ABI function.
const std = @import("std");
const contract = @import("contract");

/// The shim `vera --emit-so` generates forwards this to the root module, so
/// the contract's conformance checks run on this build.
pub const vera_validate_contract = true;
/// What this host promises the device: it calls `setup` before `eval`.
pub const calls_setup = true;

pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    _ = name;
    contract.validateHost(@This(), D);
    @export(&Export(D).residual, .{ .name = "device_residual" });
}

fn Export(comptime D: type) type {
    return struct {
        const n = contract.nU(D);
        const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{ .dense = true });
        const Val = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .dense = true });

        /// The residual `f` and Jacobian `j` (row-major) at `x`, for the
        /// default card, as a DC operating point.
        fn residual(x: *const [n]f64, f: *[n]f64, j: *[n][n]f64) callconv(.c) void {
            var model: D.Model = .{};
            D.setup(Val.Of(0), &model);
            const inst: D.Instance = .{};
            const rows: [n]S.Of(0) = D.eval(S, x, &model, &inst, .{});
            for (rows, 0..) |row, r| {
                f[r] = row.v;
                j[r] = row.d;
            }
        }
    };
}
