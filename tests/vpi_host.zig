//! The simulator half of `zig build test-vpi`: a design plus a C application
//! (its `vlog_startup_routines`, LRM §12.33.2) -> the application's exit code.
//! No argument elaborates tests/fixtures/ch11_vpi/vpi_design.va; `<design.va> <app>` runs the
//! analog analyses the app's banner asks for; `<design.v>` runs the digital
//! engine with time and value-change callbacks. Applications are real C against
//! src/vpi/vpi_user.h, so the ABI itself is under test.

const std = @import("std");
const vera = @import("vera");
const vpi = @import("vpi");
const sim = @import("sim");
const host_options = @import("vpi_host_options");

const Io = std.Io;

/// C's `main`, because this file is built ONCE as a static library and linked
/// into one executable per application: the application is the C half, and a
/// Zig executable per fixture would recompile the whole engine per fixture.
export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    // §12.17: the invocation a vpi_get_vlog_info() reports is this one.
    vpi.setInvocation(argc, @ptrCast(@constCast(argv)));
    const code = host(if (argc > 1) std.mem.span(argv[1]) else null, if (argc > 2) std.mem.span(argv[2]) else null) catch |e| {
        std.debug.print("vpi_host: {t}\n", .{e});
        return 1;
    };
    return code;
}

fn host(design: ?[]const u8, app: ?[]const u8) !u8 {
    if (design) |path| return if (std.mem.endsWith(u8, path, ".va")) analogHost(path, app) else digitalHost(path);

    // The design is compiled at `.lint`: P01 models DECLARATIONS, so nothing
    // below stage 5 is needed and no `zig` child has to be spawned to run the
    // acceptance test.
    var res = vera.compileSource(std.heap.page_allocator, @embedFile("fixtures/ch11_vpi/vpi_design.va"), .lint) catch |err| {
        std.debug.print("vpi_host: the design did not compile: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer res.deinit();

    try vpi.open(std.heap.page_allocator, res.lowered);
    defer vpi.close();

    // §12.33.2. Everything the acceptance test asserts happens inside this
    // call, because that is where a VPI application's code runs.
    vpi.runStartupRoutines();
    vpi.callback.endOfCompile();
    return 0;
}

/// An analog design, opened as `vpi.open` models it. When the application's
/// banner asks for analyses, the device is built as a shared library and
/// `vpi.analog_run` walks them. The include path is the design's directory and
/// the one above it, where tests/fixtures keeps `check.vh`.
fn analogHost(path: []const u8, app: ?[]const u8) !u8 {
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
    try vpi.open(gpa, res.lowered);
    defer vpi.close();

    // The analyses the application asks for (`*! analysis` lines in its
    // banner, grammar at `readAnalyses`). None: declarations only.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const analyses = if (app) |c| try readAnalyses(arena, io, c) else &.{};
    var loaded: ?std.DynLib = null;
    defer if (loaded) |*l| l.close();
    if (analyses.len != 0) {
        // Building the library spawns `zig`, which the global single-threaded
        // Io cannot do (no allocator, no environment): a real one, over this
        // process's own environment.
        var threaded: Io.Threaded = .init(gpa, .{
            .environ = .{ .block = .{ .slice = std.mem.span(@as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))) } },
        });
        defer threaded.deinit();
        const lib_path = buildAnalogLib(gpa, arena, threaded.io(), path, std.fs.path.stem(app.?), source, &.{ dir, up }) catch |e| {
            std.debug.print("vpi_host: `{s}` has no analog library: {t}\n", .{ path, e });
            return 1;
        };
        loaded = try std.DynLib.open(lib_path);
        try vpi.analog_run.attach(try bindLib(&loaded.?));
    }
    defer if (loaded != null) vpi.analog_run.detach();

    vpi.runStartupRoutines();
    vpi.callback.endOfCompile();
    if (analyses.len == 0) return 0;
    vpi.callback.startOfSimulation();
    for (analyses) |a| vpi.analog_run.run(a) catch |e| {
        std.debug.print("vpi_host: the {t} analysis of `{s}` failed: {t}\n", .{ a.kind, path, e });
        return 1;
    };
    vpi.callback.endOfSimulation();
    return 0;
}

/// The banner's `*! analysis <op | tran <start> <stop> [<max step>]>`, one
/// per line, run in order. Numbers take SPICE's scale suffixes, as the
/// banners write them (`tran 0 5m`). An `ac` line is refused: no small-signal
/// analysis runs in this process.
fn readAnalyses(arena: std.mem.Allocator, io: Io, c_path: []const u8) ![]const vpi.analog_run.Analysis {
    const text = try Io.Dir.cwd().readFileAlloc(io, c_path, arena, .limited(1 << 20));
    var out: std.ArrayList(vpi.analog_run.Analysis) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "*! analysis")) continue;
        var words = std.mem.tokenizeAny(u8, line["*! analysis".len..], " \t");
        const kind = words.next() orelse return error.BadAnalysis;
        if (std.mem.eql(u8, kind, "op")) {
            try out.append(arena, .{ .kind = .op });
        } else if (std.mem.eql(u8, kind, "tran")) {
            const start = try spiceNumber(words.next() orelse return error.BadAnalysis);
            const stop = try spiceNumber(words.next() orelse return error.BadAnalysis);
            const step = if (words.next()) |w| try spiceNumber(w) else 0;
            try out.append(arena, .{ .kind = .tran, .start = start, .stop = stop, .max_step = step });
        } else return error.UnsupportedAnalysis;
    }
    return out.items;
}

fn spiceNumber(w: []const u8) !f64 {
    const scales = [_]struct { s: []const u8, v: f64 }{
        .{ .s = "meg", .v = 1e6 }, .{ .s = "f", .v = 1e-15 }, .{ .s = "p", .v = 1e-12 },
        .{ .s = "n", .v = 1e-9 },  .{ .s = "u", .v = 1e-6 },  .{ .s = "m", .v = 1e-3 },
        .{ .s = "k", .v = 1e3 },   .{ .s = "g", .v = 1e9 },   .{ .s = "t", .v = 1e12 },
    };
    for (scales) |sc| if (std.ascii.endsWithIgnoreCase(w, sc.s)) {
        return (try std.fmt.parseFloat(f64, w[0 .. w.len - sc.s.len])) * sc.v;
    };
    return std.fmt.parseFloat(f64, w);
}

/// The design's device and the fixed solver as a shared library
/// (`vera.tb.renderVpiLib`), compiled with the §5.6 rows published
/// (`vpi_contribs`) and the display tasks real, into the build's work root.
/// Built under the APPLICATION's name: several applications run one design
/// at once under `zig build`, and two compilers writing one directory race.
fn buildAnalogLib(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, path: []const u8, app_stem: []const u8, source: []const u8, include: []const []const u8) ![]const u8 {
    var bag = vera.diag.Bag.init(arena);
    var res = vera.compileSourceOpts(gpa, source, .build, .{
        .file_name = path,
        .include_dirs = include,
        .display = .emit,
        .vpi_contribs = true,
        .diags = &bag,
    }) catch |e| {
        try vera.diag.render(&bag, stderrWriter(), .{});
        return e;
    };
    defer res.deinit();
    const device = try res.generateDevice();
    if (res.device_has_compile_error) return error.CodegenRefused;
    const stem = std.fs.path.stem(path);
    var d = try vera.tb.parse(arena, source);
    d.validate_contract = true;
    const runner = try vera.tb.renderVpiLib(arena, stem, d);
    const work = try std.fs.path.join(arena, &.{ host_options.work_root, app_stem });
    const out = try arena.print("{s}/lib{s}.so", .{ work, stem });
    const built = try vera.tb.buildExe(gpa, io, device, runner, .{
        .work_dir = work,
        .contract = host_options.contract,
        .name = res.mir.name,
        .out_path = out,
        .zig_exe = host_options.zig_exe,
        .shared_lib = true,
    });
    defer built.deinit(gpa);
    switch (built) {
        .ok => return out,
        .failed => |text| {
            std.debug.print("vpi_host: the analog library for `{s}` did not compile:\n{s}\n", .{ path, text });
            return error.LibraryFailed;
        },
    }
}

fn stderrWriter() *Io.Writer {
    const S = struct {
        var buf: [4096]u8 = undefined;
        var w: ?Io.File.Writer = null;
    };
    if (S.w == null) S.w = Io.File.stderr().writer(Io.Threaded.global_single_threaded.io(), &S.buf);
    return &S.w.?.interface;
}

fn bindLib(l: *std.DynLib) !vpi.analog_run.Lib {
    var out: vpi.analog_run.Lib = undefined;
    const s = @typeInfo(vpi.analog_run.Lib).@"struct";
    inline for (s.field_names, s.field_types) |name, F| {
        @field(out, name) = l.lookup(F, "vera_vpi_" ++ name) orelse return error.MissingSymbol;
    }
    return out;
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
    // §12.33.2 first: IEEE 1364-2005 §26.2.4 allows only the two
    // registration routines there, and elaboration reads the systfs they
    // register (§20.4) and sizes them (§26.1.1).
    vpi.runStartupRoutines();
    var bag = vera.diag.Bag.init(arena);
    const dir = std.fs.path.dirname(path) orelse ".";
    var run = sim.digital.elaborate(arena, source, .{ .file_name = path, .include_dirs = &.{dir}, .io = io, .systf = vpi.systf.hook, .stmt_sites = true }, &bag, out) catch |e| {
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: `{s}` did not elaborate: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try vpi.openDigital(std.heap.page_allocator, &run);
    defer vpi.close();

    // §12.31.4's "end of simulation data structure compilation or build",
    // then time 0.
    vpi.callback.endOfCompile();
    vpi.run.simulate() catch |e| {
        if (vpi.systf.misuse) |name| {
            try out.flush();
            try err.print("vpi_host: `{s}` is registered as a system task and called as a function (IEEE 1364-2005 §20.3)\n", .{name});
            try err.flush();
            return 1;
        }
        try out.flush();
        try vera.diag.render(&bag, err, .{});
        try err.print("vpi_host: the run of `{s}` failed: {t}\n", .{ path, e });
        try err.flush();
        return 1;
    };
    try out.flush();
    return 0;
}
