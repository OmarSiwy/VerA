//! §4.5 analog operators, §5.10.3 monitored events and §9.17 kernel control:
//! the operator set. The callee → `OpKind` mapping is `callee.opKind`; the
//! backend's per-operator rows (`Instance` fields, `dt`, `enable`) are
//! `backend/codegen/op_zig.zig`, a table total over this enum.

/// Every operator that owns per-instance state or a monitored event.
/// `naming.enumerateUnits` gives each occurrence of one a unit; `.none` is the
/// answer for every other `call` callee.
///
/// §4.5.13 `limexp` and §4.5.14 `ddx` are not here: they are pure functions of
/// their argument, so they own no state and get no unit.
pub const OpKind = enum {
    none,
    idt_hold, // §4.5.4 assert
    idtmod, // §4.5.5
    absdelay, // §4.5.7
    transition, // §4.5.8
    slew, // §4.5.9
    last_crossing, // §4.5.10
    laplace, // §4.5.11
    zi, // §4.5.12
    cross, // §5.10.3
    above, // §5.10.3
    timer, // §5.10.3
    bound_step, // §9.17.2
    discontinuity, // §9.17.1
};

/// Returns whether `updateState` must advance this operator. True for every
/// kind but `.none`, including the §9.17 tasks, whose unit is evaluated there
/// even though their fields are unconditional.
pub fn hasState(k: OpKind) bool {
    return k != .none;
}

/// Returns whether the operator's small-signal response depends on frequency:
/// §4.5.7 `absdelay` is e^(−jω·td), §4.5.11 `laplace_*` is H(jω) and §4.5.12
/// `zi_*` is H(e^(jωT)). Every other operator is flat in ω (§4.5.8
/// `transition` is unity, §4.5.9 `slew` 1 or 0) or has no small-signal path.
pub fn acDynamic(k: OpKind) bool {
    return switch (k) {
        .absdelay, .laplace, .zi => true,
        .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => false,
    };
}
