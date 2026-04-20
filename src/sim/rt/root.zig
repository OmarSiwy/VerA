//! The runtime a `vera --emit-exe design.v` executable links.
//!
//! In: the emitted design (`digital/emit.zig`). Out: its IEEE 1364 §17
//! transcript on stdout, exit 0; or a diagnostic on stderr, exit 1.
//!
//! `interpret` is the executable of a design `digital/plan.zig` did not make
//! native: the embedded source through the interpreter, exactly `vera --run`.
const std = @import("std");
const diag = @import("diag");
const digital = @import("../digital/root.zig");

/// `vera --run` of `source` inside the executable: its transcript on stdout,
/// its diagnostics on stderr, and `vera --run`'s exit status. The names in
/// `opts` resolve against the working directory the executable runs in.
pub fn interpret(init: std.process.Init, opts: digital.Options, source: []const u8) u8 {
    const io = init.io;
    var out_buf: [1 << 16]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [1 << 12]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    defer stderr.interface.flush() catch {};
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    var run_opts = opts;
    run_opts.io = io;
    const code: u8 = if (digital.run(arena, source, run_opts, &bag, &stdout.interface)) 0 else |e| blk: {
        if (e != error.DigitalFailed) stderr.interface.print("error: digital execution failed: {t}\n", .{e}) catch {};
        break :blk 1;
    };
    stdout.interface.flush() catch return 1;
    if (!bag.isEmpty()) diag.render(&bag, &stderr.interface, .{}) catch {};
    return code;
}
