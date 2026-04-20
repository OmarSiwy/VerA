//! Digital event scheduling and the shared-frontend source executor.
pub const digital = @import("digital/root.zig");
pub const time = @import("time.zig");
pub const scheduler = @import("scheduler.zig");
pub const mixed = @import("mixed.zig");
pub const fmt = @import("fmt.zig");

test {
    _ = scheduler;
    _ = time;
    _ = digital;
    _ = mixed;
    _ = fmt;
}
