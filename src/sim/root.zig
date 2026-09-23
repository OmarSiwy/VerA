//! Digital event scheduling and the shared-frontend source executor.
pub const digital = @import("digital/root.zig");
pub const time = @import("time.zig");
pub const scheduler = @import("scheduler.zig");
pub const Scheduler = scheduler.Scheduler;
pub const Region = scheduler.Region;
pub const FutureKind = scheduler.FutureKind;
pub const Time = scheduler.Time;
pub const Handle = scheduler.Handle;
pub const Event = scheduler.Event;

test {
    _ = scheduler;
    _ = time;
    _ = digital;
}
