//! Operating point: the first rung of ESPice's Newton ladder, plain Newton
//! from the SPICE cold start.
//!
//! Copied from OmarSiwy/ESPice src/analysis/dc/op.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d: `solve`, `coldStart` and the
//! plain rung of `solveLadder` (`newtonRun` with no gmin and INITFIX on a
//! cold start). Adapted: one device (`circuit.Circuit`), no `.nodeset`/`.ic`
//! holds. Not taken: the later rungs (gmin stepping, source stepping, JFNK,
//! OPtran) and the floating-node check; a deck that needs one fails with
//! `error.NoOperatingPoint` rather than settling somewhere else.
const std = @import("std");
const contract = @import("contract");
const converger = @import("converger.zig");

/// Zeroes `x`, then applies the device's §9.17.3 cold-start seeds (SPICE
/// MODEINITJCT) so the first iteration linearizes there instead of at 0.
pub fn coldStart(ckt: anytype, x: []f64) void {
    @memset(x, 0);
    const D = @TypeOf(ckt.*).Device;
    if (!@hasDecl(D, "seed")) return;
    const C = @TypeOf(ckt.*);
    for (D.seed(C.Val, ckt.model, ckt.inst, ckt.sim), x) |s, *xi| if (s) |v| {
        xi.* = v;
    };
}

/// Plain Newton (`hook.assemble` is one eval, the matrix G).
pub const EvalHook = struct {
    pub fn assemble(_: EvalHook, ckt: anytype, x: []const f64, t: f64) void {
        ckt.eval(x, t);
    }
    pub fn vals(_: EvalHook, ckt: anytype) []f64 {
        return &ckt.g_vals;
    }
};

/// Solves the operating point into `x` from a cold start, as a static
/// analysis of `kind` (`.dc`, or `.ic` for a transient's own: §4.6.1), and
/// on convergence commits the device state. `initial_step` holds for this
/// solve only (§5.10.2), so every later eval at this point does not re-latch.
pub fn solve(ckt: anytype, ws: anytype, x: []f64, kind: contract.AnalysisKind) !converger.Result {
    ckt.setSimState(.{ .kind = kind, .initial_step = true });
    coldStart(ckt, x);
    const r = converger.newton(ckt, ws, x, 0, .{ .init_fix = true }, EvalHook{}) catch |e| switch (e) {
        error.Singular => return error.NoOperatingPoint,
    };
    if (!r.converged) return error.NoOperatingPoint;
    _ = ckt.stateCtl(.commit);
    ckt.setSimState(.{ .kind = kind, .analog_initial = false });
    return r;
}
