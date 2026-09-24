//! The simulator half of `zig build test-vpi`.
//!
//! LRM §12.33.2 puts the application's entry point in `vlog_startup_routines`,
//! an array "provided with a VPI-compliant product" whose entries "shall be
//! added by the user" — so a VPI application is not a program with a `main`, it
//! is a table of functions a simulator calls. This file is the simulator side
//! of that arrangement, in two shapes:
//!
//!   no argument     the P01 object-model test: elaborate tests/vpi_design.va
//!                   through the ordinary (analog) engine, install it, call
//!                   `vlog_startup_routines` and §12.31.4's cbEndOfCompile.
//!   <design.v>      a C fixture paired with a DIGITAL design: elaborate it on
//!                   `src/sim`'s engine, install it, call the startup table,
//!                   fire cbEndOfCompile, then RUN it — `vpi.run.simulate`,
//!                   the loop the time and value-change callbacks fire from —
//!                   and write the design's own transcript to stdout.
//!
//! Every application is a real C translation unit compiled against
//! src/vpi/vpi_user.h and linked against the `export fn`s in src/vpi, which is
//! the only way the ABI — the constant VALUES, the parameter types, the
//! `char *` lifetimes — is under test at all. A Zig test calling the same
//! functions checks that VerA agrees with itself.
//!
//! The application reports by EXIT CODE and a census line, and `zig build`
//! asserts both, so a startup table that silently never ran is a failure
//! rather than a pass.

const std = @import("std");
const vera = @import("vera");
const vpi = @import("vpi");
const sim = @import("sim");

const Io = std.Io;

/// C's `main`, because this file is built ONCE as a static library and linked
/// into one executable per application: the application is the C half, and a
/// Zig executable per fixture would recompile the whole engine per fixture.
export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    const code = host(if (argc > 1) std.mem.span(argv[1]) else null) catch |e| {
        std.debug.print("vpi_host: {t}\n", .{e});
        return 1;
    };
    return code;
}

fn host(design: ?[]const u8) !u8 {
    if (design) |path| return if (std.mem.endsWith(u8, path, ".va")) analogHost(path) else digitalHost(path);

    // The design is compiled at `.lint`: P01 models DECLARATIONS, so nothing
    // below stage 5 is needed and no `zig` child has to be spawned to run the
    // acceptance test.
    var res = vera.compileSource(std.heap.page_allocator, @embedFile("vpi_design.va"), .lint) catch |err| {
        std.debug.print("vpi_host: the design did not compile: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer res.deinit();

    try vpi.open(std.heap.page_allocator, res.lower);
    defer vpi.close();

    // §12.33.2. Everything the acceptance test asserts happens inside this
    // call, because that is where a VPI application's code runs.
    vpi.runStartupRoutines();
    vpi.callback.endOfCompile();
    return 0;
}

/// An analog design, modelled as `vpi.open` models it: declarations and
/// folded parameters, no run — the device that would run it is compiled for
/// a host process this is not. Its include path is the design's directory and
/// the one above it, which is where tests/fixtures keeps `check.vh`.
fn analogHost(path: []const u8) !u8 {
    const io = Io.Threaded.global_single_threaded.io();
    const gpa = std.heap.page_allocator;
    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(source);
    const dir = std.fs.path.dirname(path) orelse ".";
    const up = std.fs.path.dirname(dir) orelse ".";
    var res = vera.compileSourceOpts(gpa, source, .lint, .{ .file_name = path, .include_dirs = &.{ dir, up } }) catch |e| {
        std.debug.print("vpi_host: `{s}` did not compile: {t}\n", .{ path, e });
        return 1;
    };
    defer res.deinit();
    try vpi.open(gpa, res.lower);
    defer vpi.close();
    vpi.runStartupRoutines();
    vpi.callback.endOfCompile();
    return 0;
}

fn digitalHost(path: []const u8) !u8 {
    const io = Io.Threaded.global_single_threaded.io();
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ebuf: [4096]u8 = undefined;
    var ew = Io.File.stderr().writer(io, &ebuf);
    const err = &ew.interface;
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| {
        try err.print("vpi_host: cannot read `{s}`: {t}\n", .{ path, e });
        try err.flush();
        return 2;
    };
    var bag = vera.diag.Bag.init(arena);
    const dir = std.fs.path.dirname(path) orelse ".";
    var run = sim.digital.elaborate(arena, source, .{ .file_name = path, .include_dirs = &.{dir}, .io = io }, &bag, out) catch |e| {
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: `{s}` did not elaborate: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try vpi.openDigital(std.heap.page_allocator, &run);
    defer vpi.close();

    // §12.33.2, then §12.31.4's "end of simulation data structure compilation
    // or build", then time 0.
    vpi.runStartupRoutines();
    vpi.callback.endOfCompile();
    vpi.run.simulate() catch |e| {
        try out.flush();
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: the run of `{s}` failed: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try out.flush();
    return 0;
}
