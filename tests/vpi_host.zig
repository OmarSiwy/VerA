//! The simulator half of `zig build test-vpi`.
//!
//! LRM §12.33.2 puts the application's entry point in `vlog_startup_routines`,
//! an array "provided with a VPI-compliant product" whose entries "shall be
//! added by the user" — so a VPI application is not a program with a `main`, it
//! is a table of functions a simulator calls. This file is the simulator side
//! of that arrangement, reduced to the three steps that matter for P01:
//!
//!   1. elaborate a design (tests/vpi_design.va, through the ordinary engine),
//!   2. install it as the VPI object model,
//!   3. call `vlog_startup_routines`.
//!
//! Step 3 is where tests/vpi_app.c runs. It is a real C translation unit
//! compiled against src/vpi/vpi_user.h and linked against the `export fn`s in
//! src/vpi/root.zig, which is the only way the ABI — the constant VALUES, the
//! parameter types, the `char *` lifetimes — is under test at all. A Zig test
//! calling the same functions checks that VerA agrees with itself.
//!
//! The application reports by EXIT CODE: `vpi_app.c` prints a census line and
//! calls `exit(1)` at its first failed check. `zig build` asserts both the code
//! and the line, so a startup table that silently never ran is a failure rather
//! than a pass.

const std = @import("std");
const vera = @import("vera");
const vpi = @import("vpi");

pub fn main() !void {
    // The design is compiled at `.lint`: P01 models DECLARATIONS, so nothing
    // below stage 5 is needed and no `zig` child has to be spawned to run the
    // acceptance test.
    var res = vera.compileSource(std.heap.page_allocator, @embedFile("vpi_design.va"), .lint) catch |err| {
        std.debug.print("vpi_host: the design did not compile: {s}\n", .{@errorName(err)});
        return err;
    };
    defer res.deinit();

    try vpi.open(std.heap.page_allocator, res.lower);
    defer vpi.close();

    // §12.33.2. Everything the acceptance test asserts happens inside this
    // call, because that is where a VPI application's code runs.
    vpi.runStartupRoutines();
}
