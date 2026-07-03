const D = @import("device");
comptime {
    _ = @import("dyn");
}
export fn vdispatch(s: *anyopaque, pc: u32) callconv(.c) u32 {
    D.zdispatch(@ptrCast(@alignCast(s)), pc) catch return 1;
    return 0;
}
