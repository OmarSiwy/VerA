//! The float MODE of the generated device: which `@setFloatMode` each body
//! compiles in, and whether the host may carry the derivative half of `S` in
//! single precision.
//!
//! PURE: verdicts and options in, a mode out. `lanes.zig` is the other half of
//! the concern — which selects run branchless and when a lane-parallel `S` is
//! exact — and `Float` below is the emit-time state both halves share.
//!
//! LRM clauses this file's code cites: §4.3.

const std = @import("std");
const proof = @import("ir").proof;
const Job = @import("../plan/jobs.zig").Job;

/// The float state `Gen` carries while it writes.
pub const Float = struct {
    /// Float mode of the body CURRENTLY being emitted is `.strict`. That is
    /// the eager `sel` licence — see `renderInst`'s select case and
    /// `lanes.eagerSafe`. Set by `emitUnit` and the common-core emitter,
    /// false-by-default so any other emission path keeps the lazy form.
    strict: bool = false,
    /// True once any residual/charge unit steered on an x-dependent value
    /// through a scalar — see `lanes.pinLanes`. A device that finishes with
    /// this still false gets `pub const lane_clean = true;`: instantiating
    /// eval/q with a LANE-PARALLEL S (one operating point per lane) is then
    /// exact per lane, which the testbench's batch differential check
    /// asserts. Display units never set it — they are not part of the
    /// residual.
    pinned: bool = false,
    /// `Options.jac_f32`/`jac_f32_host` — which single-precision-Jacobian
    /// decls the device emits. A hardware knob: it stays.
    jac: Jac = .off,
};

/// The f32 Jacobian permission, as one value: the two options are a flag-bag
/// with one invalid state (`jac_f32_host` without `jac_f32`), which
/// `Jac.of` normalises the way `generate` always did — host implies permit.
pub const Jac = enum {
    /// f64 derivatives only.
    off,
    /// `pub const jac_f32 = true`: a host MAY carry the derivative half in f32.
    permit,
    /// `jac_f32_host` too: the host should take it on its CPU path as well.
    host,

    pub fn of(jac_f32: bool, jac_f32_host: bool) Jac {
        if (jac_f32_host) return .host;
        return if (jac_f32) .permit else .off;
    }
};

/// The prover's float mode for unit `i`.
pub fn unitMode(unit_modes: []const proof.FloatMode, i: usize) proof.FloatMode {
    // proof.zig rates the CONTRIBUTION units only (proof.unitCount ==
    // lower.contributions.len); an analog-operator unit is not covered, so
    // it takes the safe side.
    if (i >= unit_modes.len) return .strict;
    return unit_modes[i];
}

/// §4.3: the mode the ONE shared core compiles in — the STRICTEST mode of
/// every job it serves. `proof.FloatMode.strictest` explains why the join has
/// to absorb `.strict`. The §9.4 display job is not served by the core.
pub fn coreMode(jobs: []const Job) proof.FloatMode {
    var mode: proof.FloatMode = .optimized;
    for (jobs) |job| {
        if (job.kind == .display) continue;
        mode = .strictest(mode, job.mode);
    }
    return mode;
}

test "the core is strict if any served job is; the f32 knob normalises host ⇒ permit" {
    const j = struct {
        fn of(kind: Job.Kind, mode: proof.FloatMode) Job {
            return .{ .kind = kind, .target = .f_zero, .mode = mode, .comment = "" };
        }
    }.of;
    try std.testing.expectEqual(proof.FloatMode.optimized, coreMode(&.{ j(.resist, .optimized), j(.display, .strict) }));
    try std.testing.expectEqual(proof.FloatMode.strict, coreMode(&.{ j(.resist, .optimized), j(.held, .strict) }));
    try std.testing.expectEqual(proof.FloatMode.strict, unitMode(&.{.optimized}, 1));
    try std.testing.expectEqual(Jac.host, Jac.of(false, true));
    try std.testing.expectEqual(Jac.permit, Jac.of(true, false));
    try std.testing.expectEqual(Jac.off, Jac.of(false, false));
}
