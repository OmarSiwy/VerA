//! Digital event scheduling and the shared-frontend source executor.
pub const digital = @import("digital/root.zig");
pub const time = @import("time.zig");
pub const scheduler = @import("scheduler.zig");

test {
    _ = scheduler;
    _ = time;
    _ = digital;
}
