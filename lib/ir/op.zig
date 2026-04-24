//! §4.5 analog operators, §5.10.3 monitored events and §9.17 kernel control:
//! the operator set. The callee → `OpKind` mapping is `callee.opKind`; the
//! backend's per-operator rows (`Instance` fields, `dt`, `enable`) are
//! `backend/codegen/op_zig.zig`, a table total over this enum.

/// Every operator that owns per-instance state or a monitored event.
/// `naming.enumerateUnits` gives each occurrence of one a unit; `.none` is the
/// answer for every other `call` callee.
///
/// §4.5.13 `limexp` and §4.5.14 `ddx` are NOT here and must not be added: they
/// are pure functions of their argument, so they own no state and get no unit
/// (`naming.isStatefulAnalogOp` is the other half of that rule).
pub const OpKind = enum {
    none,
    ddt, // §4.5.3
    idt, // §4.5.4
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

/// Does this operator need `updateState` to advance anything? Everything that
/// reaches `OpKind` other than `.none` does, including the §9.17 tasks — their
/// unit is evaluated there even though their fields are unconditional.
pub fn hasState(k: OpKind) bool {
    return k != .none;
}
