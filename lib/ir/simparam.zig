//! §9.15 simulation parameters: a `$simparam` name in, its compile-time value,
//! its host `Model` field, or "answered at run time" out. Lowering diagnoses
//! and records with these; `Lowered.simparamValue` and codegen answer with the
//! same rows, so a name is never both unknown and answered. Here, not in
//! `lower/sysfunc.zig`, so code after lowering reads them from `ir`.
//!
//! LRM clauses this file's code cites: §9.15.

const std = @import("std");
const Timescale = @import("base").Timescale;
const Lowered = @import("lowered.zig");

/// Returns the compile-time value of a §9.15 Table 9-27 simulation parameter, or
/// null for "param_name is not known" (E0811 in `lowerSysCall` without a fallback).
/// Codegen reads the same table, so a name is never both unknown and answered.
/// Table 9-27 applies to simulators "if they support the parameter", so rows VerA
/// cannot answer (`gdev`, `simulatorVersion`) stay unknown; run-time rows are in
/// `simparamIsRuntime`. Takes the `timescale` in force alone so `Lowered` can answer after
/// `Lower` is gone.
pub fn simparamValueIn(timescale: ?Timescale, name: []const u8) ?f64 {
    const eq = std.mem.eql;
    // The two rows that come from the source; unknown when no `timescale was given.
    if (eq(u8, name, "timeUnit")) return if (timescale) |t| t.unit else null;
    if (eq(u8, name, "timePrecision")) return if (timescale) |t| t.precision else null;
    // `gmin` and `sourceScaleFactor` are host fields: a host steps both
    // (gmin stepping, source-stepping homotopy, Table 9-27's own rows), so
    // these are only the defaults of `Model.gmin__`/`source_scale__`.
    if (eq(u8, name, "gmin")) return 1e-12;
    // Table 9-27 gives `tnom` in degrees Celsius. 27 is only the default: `tnom`
    // is also a `simparamHostField`, so codegen reads the host's Model field and
    // uses this number as that field's initializer.
    if (eq(u8, name, "tnom")) return 27.0;
    // Not in Table 9-27, which §9.15 allows ("There is no fixed list"): SPICE's
    // `.options` Newton tolerances, host fields like `tnom`, defaulting to
    // SPICE's values.
    if (eq(u8, name, "reltol")) return 1e-3;
    if (eq(u8, name, "abstol")) return 1e-12;
    if (eq(u8, name, "vntol")) return 1e-6;
    // Geometry scaling is applied when the card is built, so 1.0 is the true
    // answer for `scale` and `shrink`, not a stand-in.
    if (eq(u8, name, "scale") or eq(u8, name, "shrink") or eq(u8, name, "sourceScaleFactor")) return 1.0;
    return null;
}

/// Reports whether `name` is a §9.15 simulation parameter the device answers at run
/// time from `SimState`: the Newton iteration counter, which the host advances once
/// per evaluated iteration (`advanceIteration`), and `dt`, not in Table 9-27, the
/// host's step since the last accepted point (0 in a static solve), returned as
/// the host's f64 so a model can reproduce the host's own `t - dt` bit for bit.
pub fn simparamIsRuntime(name: []const u8) bool {
    return std.mem.eql(u8, name, "iteration") or std.mem.eql(u8, name, "dt");
}

/// The §9.15 simulation parameters whose value is the host's, in `Model` field
/// order: the name, its reserved `Model` field (written before `derive()`), and
/// the `uses` flag that emits the field. Each is SPICE's `.options` entry of that
/// name, `sourceScaleFactor` the source-stepping factor; `tnom` (degrees Celsius) is the temperature a model card without its own
/// `TNOM` was extracted at. The `__` suffix cannot collide: `names.sanitize`
/// escapes a trailing `_` and every `__` run in an identifier.
pub const host_simparams = [_]struct { name: []const u8, field: []const u8, use: Lowered.Kernel }{
    .{ .name = "tnom", .field = "nom_temp__", .use = .host_tnom },
    .{ .name = "reltol", .field = "reltol__", .use = .host_reltol },
    .{ .name = "abstol", .field = "abstol__", .use = .host_abstol },
    .{ .name = "vntol", .field = "vntol__", .use = .host_vntol },
    .{ .name = "gmin", .field = "gmin__", .use = .host_gmin },
    .{ .name = "sourceScaleFactor", .field = "source_scale__", .use = .host_source_scale },
};

/// Returns the reserved `Model` field of a `host_simparams` name, or null for a
/// compile-time constant.
pub fn simparamHostField(name: []const u8) ?[]const u8 {
    for (host_simparams) |h| if (std.mem.eql(u8, h.name, name)) return h.field;
    return null;
}

test simparamValueIn {
    // No `timescale: §9.15's two source rows are unknown.
    const d: ?Timescale = null;
    try std.testing.expectEqual(@as(?f64, null), simparamValueIn(d, "timeUnit"));
    try std.testing.expectEqual(@as(?f64, null), simparamValueIn(d, "timePrecision"));
    try std.testing.expectEqual(@as(?f64, 1e-12), simparamValueIn(d, "gmin"));
    try std.testing.expectEqual(@as(?f64, 27.0), simparamValueIn(d, "tnom"));
    try std.testing.expectEqual(@as(?f64, 1.0), simparamValueIn(d, "shrink"));
    // Table 9-27 applies "if they support the parameter"; VerA does not.
    try std.testing.expectEqual(@as(?f64, null), simparamValueIn(d, "gdev"));
}

test simparamHostField {
    try std.testing.expectEqualStrings("nom_temp__", simparamHostField("tnom").?);
    try std.testing.expectEqualStrings("source_scale__", simparamHostField("sourceScaleFactor").?);
    try std.testing.expect(simparamHostField("timeUnit") == null);
    // Every row's field ends `__`, the suffix `names.sanitize` never emits.
    for (host_simparams) |h| try std.testing.expect(std.mem.endsWith(u8, h.field, "__"));
}

test simparamIsRuntime {
    try std.testing.expect(simparamIsRuntime("iteration"));
    try std.testing.expect(simparamIsRuntime("dt"));
    try std.testing.expect(!simparamIsRuntime("gmin"));
}
