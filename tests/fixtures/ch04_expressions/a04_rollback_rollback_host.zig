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
//! this is their §4.5 operator-history counterpart.
//!
//! The subject is `slew` (a04_rollback_a04_rollback_ops.va), an operator that
//! keeps its history in the device. idt and ddt keep none: they are host
//! unknowns (§4.5.2), whose history the host's integrator owns and reverts.
//!
//! WHAT THE LRM REQUIRES. §4.5.9 bounds the output's rate of change over the
//! ACCEPTED waveform, and the accepted output at t = 1ns is a property of the
//! circuit, not of how many trial points were discarded on the way there.
//! §4.5.15 says the same from the other side: "It is important to ensure that
//! all analog operators are evaluated every iteration of a simulation to ensure
//! that the internal state is maintained ... These restrictions help prevent
//! usage which could cause the internal state to be corrupted or become
//! out-of-date."
//!
//! So the requirement this file encodes is: after a trial step to t = 2ns is
//! REJECTED and the step re-taken to t = 1ns, every §4.5 operator shall read
//! exactly what it would have read had the 2ns attempt never happened.
//!
//! THE HAND DERIVATION. V(p) is driven to t/1ns volts, twice the 0.5 V/ns
//! limit, so the output rises exactly 0.5 per nanosecond from its last
//! accepted value.
//!
//!   step            t      dt     slew    why
//!   dc              0       0     0.0     §4.5.9 "In DC analysis, slew()
//!                                         simply passes the value of the
//!                                         destination to its output"
//!   trial (reject)  2ns   2ns     1.0     0 + 0.5e9 · 2ns
//!   REVERT           -      -       -     accepted state is the dc one
//!   retry (accept)  1ns   1ns     0.5     0 + 0.5e9 · 1ns, NOT 1.0 (the
//!                                         discarded attempt's output, which
//!                                         the input 1.0 does not clamp)
//!   next  (accept)  2ns   1ns     1.0     0.5 + 0.5e9 · 1ns
//!
//! The last row is what makes this a test rather than a tautology: the run
//! reaches t = 2ns twice, once on a discarded attempt and once for real, and
//! the output there is 1.0 both times. An implementation whose history is
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
//!  2. Even given the hook, `Gen.emitStateCtl`'s `.revert` arm restores only
//!     the held FSM variables, the cross/above histories, `limiter_previous`,
//!     `newton_iteration` and `<n>__off` (idt's assert latch,
//!     a04_idt_hold_revert_host.zig). `<n>__prev` (slew, last_crossing),
//!     `<n>__from`/`<n>__t0` (transition), `<n>__u`/`<n>__y` (laplace/zi) and
//!     `<n>__t`/`<n>__v`/`<n>__head` (absdelay) are not in it, and neither is
//!     `State.t_prev`.
//!
//!     The second omission is the sharp one. `updateState` ends with
//!     `state.t_prev = sim.t`, and a kernel that measures dt against it after
//!     a rejected attempt at 2ns has written t_prev = 2ns computes a negative
//!     step on the retry at 1ns.
//!
//! HOW TO RUN IT (captured, not typed — this is the command that works):
//!
//!     ./zig-out/bin/vera --emit-zig -I tests/fixtures \
//!       tests/fixtures/ch04_expressions/a04_rollback_a04_rollback_ops.va \
//!       -o /tmp/a04_rollback.zig
//!     zig test --dep device --dep contract \
//!              -Mroot=tests/fixtures/ch04_expressions/a04_rollback_rollback_host.zig \
//!              --dep contract -Mdevice=/tmp/a04_rollback.zig \
//!              -Mcontract=tools/contract.zig
//!
//! The `--dep` flags are POSITIONAL: each one attaches to the NEXT `-M`. This
//! file and the emitted device both `@import("contract")`, so `contract` has
//! to be a dependency of `root` AND of `device`. Leave either out and the
//! build dies with "no module named 'contract' available within module ..."
//! before either test runs.

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".fields.len;

/// The reference family with no lanes: nothing here asks for a Jacobian.
const S = contract.RefFamily(f64, &(.{contract.no_lane} ** n_u), .{ .dense = true });

/// The slew output, read from row `p` and divided back out by the 1e-3 scale
/// the .va applies.
fn read(model: *const D.Model, inst: *D.Instance, x: [n_u]f64, sim: contract.SimState) f64 {
    const r: [n_u]S = D.eval(S, &x, model, inst, sim);
    return r[@intFromEnum(D.U.p)].v / 1.0e-3;
}

/// Drive the unknowns the way the .va's ramp asks: V(p) = t/1ns volts.
fn bias(t_ns: f64) [n_u]f64 {
    var x: [n_u]f64 = @splat(0.0);
    x[@intFromEnum(D.U.p)] = t_ns;
    return x;
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

test "§4.5.9 the output at an accepted time does not depend on rejected attempts" {
    // Defect 1: a device whose only state is §4.5 operator history exports no
    // revert hook, so a host has nothing to call when it throws a step away.
    // The guard is in `stateCtl` above rather than here, so that everything up
    // to the first commit below is compiled and run today.

    const model: D.Model = .{};
    var inst: D.Instance = .{};
    var state = D.initState(&model, &inst);
    var sim: contract.SimState = .{};

    // ---- the operating point -------------------------------------------
    sim.t = 0.0;
    sim.dt = 0.0;
    const x0 = bias(0.0);
    // §4.5.9 "In DC analysis, slew() simply passes the value of the
    // destination to its output" — V(p,n) = 0 here.
    try std.testing.expectApproxEqAbs(0.0, read(&model, &inst, x0, sim), 1e-12);
    _ = D.updateState(S, &model, &inst, x0, &state, sim);
    try stateCtl(&model, &inst, &state, .commit);

    // ---- a trial step to 2ns that the driver will reject ----------------
    sim.t = 2.0e-9;
    sim.dt = 2.0e-9;
    const x2 = bias(2.0);
    // 0.5 V/ns over 2ns is 1.0, under the input's 2.0.
    try std.testing.expectApproxEqAbs(1.0, read(&model, &inst, x2, sim), 1e-9);
    _ = D.updateState(S, &model, &inst, x2, &state, sim);

    // ---- REJECTED. The driver reverts and halves the step. --------------
    try stateCtl(&model, &inst, &state, .revert);

    sim.t = 1.0e-9;
    sim.dt = 1.0e-9;
    const x1 = bias(1.0);
    // THE ASSERTION OF THIS FILE. 0 + 0.5 V/ns · 1ns = 0.5. Not 1.0, which is
    // what history left over from the discarded attempt reads (the input 1.0
    // does not clamp it).
    try std.testing.expectApproxEqAbs(0.5, read(&model, &inst, x1, sim), 1e-9);
    _ = D.updateState(S, &model, &inst, x1, &state, sim);
    try stateCtl(&model, &inst, &state, .commit);

    // ---- and the run reaches 2ns for real ------------------------------
    sim.t = 2.0e-9;
    sim.dt = 1.0e-9;
    // Same time, same circuit, different path to it: 0.5 + 0.5 = 1.0, the
    // identical number the rejected attempt produced.
    try std.testing.expectApproxEqAbs(1.0, read(&model, &inst, x2, sim), 1e-9);
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
    var sim: contract.SimState = .{};

    sim.t = 0.0;
    sim.dt = 0.0;
    _ = D.updateState(S, &model, &inst, bias(0.0), &state, sim);
    try stateCtl(&model, &inst, &state, .commit);
    const accepted = inst;
    const accepted_state = state;

    for ([_]f64{ 8.0, 4.0, 2.0 }) |t_ns| { // three rejected attempts, shrinking
        sim.t = t_ns * 1.0e-9;
        sim.dt = t_ns * 1.0e-9;
        _ = D.updateState(S, &model, &inst, bias(t_ns), &state, sim);
        try stateCtl(&model, &inst, &state, .revert);
        // Every field of Instance belongs to the device and must be restored
        // by the revert itself; time lives in the host's `SimState`.
        try std.testing.expectEqualDeep(accepted, inst);
        // `State` carries `t_prev`, which is what `dt` is measured against — a
        // revert that leaves it pointing at a discarded trial time makes the
        // next attempt's dt negative.
        try std.testing.expectEqualDeep(accepted_state, state);
    }
}
