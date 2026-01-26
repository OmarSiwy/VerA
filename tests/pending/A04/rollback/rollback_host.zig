//! A04 — §4.5 stateful operators across a REJECTED TIMESTEP.
//!
//! WHY THIS IS NOT A `.va` FIXTURE. A rejected step is a sequence of host
//! calls, not a waveform: the driver evaluates a trial point, writes the
//! operators' accepted-step state, then decides the local error is too large,
//! REVERTS, and re-solves the same interval with a smaller dt. The `//!`
//! directive language walks `//! time` forward and calls `updateState` once per
//! entry, so it cannot express the revert at all. tests/limiter_host.zig
//! already established the pattern for exactly this problem on §4.5.15's
//! limiting state ("limiter state advances by generation and reverts a
//! rejected attempt") and tests/table_snapshot_host.zig for §9.21's snapshot;
//! this is their §4.5.2-§4.5.4 counterpart.
//!
//! WHAT THE LRM REQUIRES. §4.5.4 Table 4-18 defines idt() as ∫t0..t x(τ)dτ + c
//! over the interval [t0, t] — an integral over the ACCEPTED solution, and the
//! accepted solution at t = 1ns is a property of the circuit, not of how many
//! trial points the integrator discarded on the way there. §4.5.15 says the
//! same from the other side: "It is important to ensure that all analog
//! operators are evaluated every iteration of a simulation to ensure that the
//! internal state is maintained ... These restrictions help prevent usage which
//! could cause the internal state to be corrupted or become out-of-date."
//!
//! So the requirement this file encodes is: after a trial step to t = 2ns is
//! REJECTED and the step re-taken to t = 1ns, every §4.5 operator shall read
//! exactly what it would have read had the 2ns attempt never happened.
//!
//! THE HAND DERIVATION. The integrand is the constant 1e9, so the integral
//! gains exactly 1.0 per nanosecond, and V(p) is driven to t/1ns volts so
//! ddt(V(p,n)) is exactly 1e9 V/s on every interval.
//!
//!   step            t      dt     idt      ddt     why
//!   dc              0       0     0.0      0.0     §4.5.4 ic, §4.5.3 "In DC
//!                                                  analysis, ddt() returns
//!                                                  zero (0)"
//!   trial (reject)  2ns   2ns     2.0      1e9     1e9 · 2ns = 2.0
//!   REVERT           -      -       -        -     accepted state is the dc one
//!   retry (accept)  1ns   1ns     1.0      1e9     1e9 · 1ns = 1.0, NOT 2.0
//!                                                  and NOT 0.0
//!   next  (accept)  2ns   1ns     2.0      1e9     1.0 + 1e9 · 1ns
//!
//! The last row is what makes this a test rather than a tautology: the run
//! reaches t = 2ns twice, once on a discarded attempt and once for real, and
//! the integral there is 2.0 both times. An implementation whose history is
//! path-dependent reads a different number the second time.
//!
//! WHAT FAILS TODAY, AND WHY IT IS TWO DEFECTS.
//!
//!  1. `Gen.emitsStateCtl` is false for a module whose only state is §4.5
//!     operator history — it is true only for cross/above FSM latches, path
//!     latches, `$limit` slots and `newton_iteration`. So this device exports
//!     no `stateCtl` at all and there is no revert to call. The first
//!     assertion below is that the hook exists.
//!
//!     The host has already been told this device is safe to update
//!     speculatively: ARPice's `eval.zig` routes `updateState` to the
//!     per-iteration `update_state` hook rather than the accepted-step
//!     `commit_state` one unless the Instance carries an `__absdelay__` field,
//!     on the stated grounds that "`stateCtl` reverts it". For an idt/ddt
//!     device nothing does.
//!
//!  2. Even given the hook, `Gen.emitStateCtl`'s `.revert` arm restores only
//!     the held FSM variables, the cross/above histories, `limiter_previous`
//!     and `newton_iteration`. `<n>__acc` (idt/idtmod), `<n>__prev` (ddt, slew,
//!     last_crossing), `<n>__from`/`<n>__t0` (transition), `<n>__u`/`<n>__y`
//!     (laplace/zi) and `<n>__t`/`<n>__v`/`<n>__head` (absdelay) are not in it,
//!     and neither is `State.t_prev`.
//!
//!     The second omission is the sharp one. `updateState` ends with
//!     `state.t_prev = inst.abstime`, and the next call computes
//!     `dt = inst.abstime - state.t_prev`. After a rejected attempt at 2ns has
//!     written t_prev = 2ns, the retry at 1ns computes dt = -1ns, and
//!     `zIdtAcc`'s `if (dt <= 0.0) return ic` reads that as a STATIC ANALYSIS
//!     and throws the whole integral away. The accepted answer at 1ns comes out
//!     0.0 where the clause requires 1.0 — not a small error, a reset.
//!
//! HOW TO RUN IT (captured, not typed — this is the command that works):
//!
//!     ./zig-out/bin/vera --emit-zig -I tests/fixtures \
//!       tests/pending/A04/rollback/a04_rollback_ops.va -o /tmp/a04_rollback.zig
//!     zig test --dep device -Mroot=tests/pending/A04/rollback/rollback_host.zig \
//!              --dep contract -Mdevice=/tmp/a04_rollback.zig \
//!              -Mcontract=tools/contract.zig
//!
//! The `--dep` flags are POSITIONAL: each one attaches to the NEXT `-M`. The
//! emitted device does `@import("contract")` itself, so `contract` has to be a
//! dependency of the `device` module, not only of `root`. Writing both `--dep`
//! flags before `-Mroot` — as an earlier revision of this header and of
//! SPEC.md did — gives `root` two dependencies and `device` none, and the
//! build dies with
//!
//!     /tmp/a04_rollback.zig:7:26: error: no module named 'contract'
//!                                 available within module 'device'
//!
//! before either test runs.
//!
//! Wiring (build.zig, modelled on the `limiter_host` block at build.zig:168):
//!
//!     const a04_gen = b.addRunArtifact(exe);
//!     a04_gen.addArgs(&.{ "--emit-zig", "-I" });
//!     a04_gen.addDirectoryArg(b.path("tests/fixtures"));
//!     a04_gen.addFileArg(b.path("tests/pending/A04/rollback/a04_rollback_ops.va"));
//!     a04_gen.addArg("-o");
//!     const a04_src = a04_gen.addOutputFileArg("a04_rollback.zig");
//!     // … same module/test wiring as limiter_mod / limiter_test …
//!     b.step("test-a04-rollback", "§4.5 operator state across a rejected step")

const std = @import("std");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".fields.len;

/// The plain-real solver scalar, copied from tests/table_snapshot_host.zig: a
/// host driving a device directly supplies its own `S`, and this one carries no
/// derivative because nothing here asks for a Jacobian.
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
    pub fn minC(a: S, b: f64) S {
        return con(@min(a.v, b));
    }
    pub fn maxC(a: S, b: f64) S {
        return con(@max(a.v, b));
    }
};

/// The residual row an operator's contribution lands in, divided back out by
/// the 1e-3 scale the .va applies, so the assertions read in the operator's own
/// units.
fn read(model: *const D.Model, inst: *D.Instance, x: [n_u]S, u: D.U) f64 {
    return D.eval(S, x, model, inst, inst.abstime)[@intFromEnum(u)].v / 1.0e-3;
}

/// Drive the unknowns the way the .va's ramp asks: V(p) = t/1ns volts.
fn bias(t_ns: f64) [n_u]S {
    var x: [n_u]S = @splat(S.con(0.0));
    x[@intFromEnum(D.U.p)] = S.con(t_ns);
    return x;
}

fn real(x: [n_u]S) [n_u]f64 {
    var out: [n_u]f64 = undefined;
    for (x, 0..) |v, i| out[i] = v.v;
    return out;
}

/// The missing revert hook, behind a shim INSTEAD OF an early `return` at the
/// top of each test.
///
/// The obvious spelling — `if (!@hasDecl(D, "stateCtl")) return error…;` as the
/// first statement of the test — is comptime-true today, so Zig folds it and
/// never analyses the rest of the function body. Every `D.initState`,
/// `D.updateState`, `D.eval` call and every `D.Instance`/`D.Model` field below
/// it would then be type-checked for the FIRST time on the day someone
/// implements the hook, which is the worst possible day to discover the driver
/// does not compile. Pushing the guard into a shim keeps both test bodies live:
/// they are compiled and executed today, right up to the first revert, and the
/// only thing that stays unanalysed is the single `D.stateCtl` call.
fn stateCtl(model: *const D.Model, inst: *D.Instance, state: anytype, op: anytype) !void {
    if (!@hasDecl(D, "stateCtl")) return error.NoRevertHookForAnalogOperatorState;
    _ = D.stateCtl(model, inst, state, op);
}

test "§4.5.4 the integral at an accepted time does not depend on rejected attempts" {
    // Defect 1: a device whose only state is §4.5 operator history exports no
    // revert hook, so a host has nothing to call when it throws a step away.
    // The guard is in `stateCtl` above rather than here, so that everything up
    // to the first commit below is compiled and run today.

    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);

    // ---- the operating point -------------------------------------------
    inst.abstime = 0.0;
    inst.dt = 0.0;
    const x0 = bias(0.0);
    // §4.5.4 "When used in DC or IC analyses, idt() returns the initial
    // condition (ic) if specified" — 0.0 here.
    try std.testing.expectApproxEqAbs(0.0, read(&model, &inst, x0, .p), 1e-12);
    // §4.5.3 "In DC analysis, ddt() returns zero (0)."
    try std.testing.expectApproxEqAbs(0.0, read(&model, &inst, x0, .q), 1e-12);
    _ = D.updateState(&model, &inst, real(x0), &state);
    try stateCtl(&model, &inst, &state, .commit);

    // ---- a trial step to 2ns that the driver will reject ----------------
    inst.abstime = 2.0e-9;
    inst.dt = 2.0e-9;
    const x2 = bias(2.0);
    // 1e9 integrated over 2ns is exactly 2.0; the derivative of a 1 V/ns ramp
    // is exactly 1e9 V/s.
    try std.testing.expectApproxEqAbs(2.0, read(&model, &inst, x2, .p), 1e-9);
    try std.testing.expectApproxEqAbs(1.0e9, read(&model, &inst, x2, .q), 1.0);
    _ = D.updateState(&model, &inst, real(x2), &state);

    // ---- REJECTED. The driver reverts and halves the step. --------------
    try stateCtl(&model, &inst, &state, .revert);

    inst.abstime = 1.0e-9;
    inst.dt = 1.0e-9;
    const x1 = bias(1.0);
    // THE ASSERTION OF THIS FILE. ∫0..1ns 1e9 dτ = 1.0. Not 2.0 (state left
    // over from the discarded attempt) and not 0.0 (what a negative dt makes
    // `zIdtAcc` return once `state.t_prev` has been advanced to 2ns and never
    // put back).
    try std.testing.expectApproxEqAbs(1.0, read(&model, &inst, x1, .p), 1e-9);
    try std.testing.expectApproxEqAbs(1.0e9, read(&model, &inst, x1, .q), 1.0);
    _ = D.updateState(&model, &inst, real(x1), &state);
    try stateCtl(&model, &inst, &state, .commit);

    // ---- and the run reaches 2ns for real ------------------------------
    inst.abstime = 2.0e-9;
    inst.dt = 1.0e-9;
    // Same time, same circuit, different path to it: 1.0 + 1e9·1ns = 2.0, the
    // identical number the rejected attempt produced.
    try std.testing.expectApproxEqAbs(2.0, read(&model, &inst, x2, .p), 1e-9);
    try std.testing.expectApproxEqAbs(1.0e9, read(&model, &inst, x2, .q), 1.0);
}

test "§4.5.15 a revert leaves no half-advanced operator history behind" {
    // The structural half of the same rule, and the one that catches a partial
    // fix: a revert must restore the device state exactly, so a driver that
    // rejects several times in a row cannot accumulate a drift no single value
    // comparison would show. tests/limiter_host.zig asserts this same shape for
    // the limiter state (`expectEqualDeep(accepted, inst)`).

    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);

    inst.abstime = 0.0;
    inst.dt = 0.0;
    _ = D.updateState(&model, &inst, real(bias(0.0)), &state);
    try stateCtl(&model, &inst, &state, .commit);
    const accepted = inst;
    const accepted_state = state;

    for ([_]f64{ 8.0, 4.0, 2.0 }) |t_ns| { // three rejected attempts, shrinking
        inst.abstime = t_ns * 1.0e-9;
        inst.dt = t_ns * 1.0e-9;
        _ = D.updateState(&model, &inst, real(bias(t_ns)), &state);
        try stateCtl(&model, &inst, &state, .revert);
        // `abstime`/`dt` are HOST-owned (contract `set_sim_state`), not device
        // state, so they are put back by hand before the comparison; every
        // other field of Instance belongs to the device and must be restored
        // by the revert itself.
        inst.abstime = 0.0;
        inst.dt = 0.0;
        try std.testing.expectEqualDeep(accepted, inst);
        // `State` carries `t_prev`, which is what `dt` is measured against — a
        // revert that leaves it pointing at a discarded trial time makes the
        // next attempt's dt negative, which every §4.5 kernel reads as "static
        // analysis".
        try std.testing.expectEqualDeep(accepted_state, state);
    }
}
