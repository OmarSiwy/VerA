//! The simulators behind `vera --run` and `--emit-exe`: the IEEE 1364 event
//! scheduler and interpreter (`digital`), the native executable's runtime
//! (`rt`), the VAMS §8 mixed-signal coordinator (`mixed`), and the shared
//! time and value formatting.
//!
//! Every declaration here is reached from outside the module: `src/main.zig`,
//! `src/vpi/`, `lib/backend/tb*`, `tests/`, and the Zig text that
//! `lib/backend/orchestrator.zig` and `digital/emit.zig` generate (`sim.rt`,
//! `sim.digital`, `sim.mixed`). The generated text is why a rename here is a
//! golden change, not only a compile error.

/// IEEE 1364-2005 elaboration and the event-driven interpreter (`Run`).
pub const digital = @import("digital/root.zig");
/// Timescale factors and the analog-time-to-tick mapping (§19.8, VAMS §7.3.6.5).
pub const time = @import("time.zig");
/// The region-ordered event queue (IEEE 1364-2005 §11, VAMS §8.5).
pub const scheduler = @import("scheduler.zig");
/// The VAMS §8 coordinator that steps a digital `Run` beside an analog solver.
pub const mixed = @import("mixed.zig");
/// IEEE 1364-2005 §17.1 value and time text, shared by both engines.
pub const fmt = @import("fmt.zig");
/// The runtime an `--emit-exe` executable links: native designs and devices.
pub const rt = @import("rt/root.zig");

test {
    _ = scheduler;
    _ = time;
    _ = digital;
    _ = mixed;
    _ = fmt;
    _ = rt;
}
