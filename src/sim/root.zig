//! The simulators behind `vera --run` and `--emit-exe`: the IEEE 1364 event
//! scheduler and interpreter (`digital`), the native executable's runtime
//! (`rt`), the VAMS §8 mixed-signal coordinator (`mixed`), and the shared
//! time and value formatting.
pub const digital = @import("digital/root.zig");
pub const time = @import("time.zig");
pub const scheduler = @import("scheduler.zig");
pub const mixed = @import("mixed.zig");
pub const fmt = @import("fmt.zig");
pub const rt = @import("rt/root.zig");

test {
    _ = scheduler;
    _ = time;
    _ = digital;
    _ = mixed;
    _ = fmt;
    _ = rt;
}
