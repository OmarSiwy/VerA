//! `vera`, the command-line driver: argv -> a compiled, linted, generated or
//! run artifact, with the library's diagnostics on stderr. `--run FILE.v` uses
//! `src/sim` instead of the analog pipeline. Options: `cli/args.zig`'s
//! `usage_text`.
//!
//! Exit status: 0 on success (warnings do not fail), 1 on a diagnosed error,
//! 2 on a usage error, including conflicting flags (never last-one-wins).
//!
//! `main` is the spine: read the command line (`cli/args.zig`), refuse the
//! flags that conflict, read the source, then hand it to the `.v` path
//! (`cli/digital.zig`) or to `compileAnalog` below. Flags, streams, exit
//! codes and messages are user-visible and frozen: `--emit-exe` prints the
//! artifact's path on stdout and every diagnostic on stderr.

const std = @import("std");
const builtin = @import("builtin");
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;
const vera = @import("vera");
const diag = vera.diag;
const Io = std.Io;
const args = @import("cli/args.zig");
const digital_cli = @import("cli/digital.zig");

/// Returns the process exit status (see the file header).
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var stderr_buf: [1 << 16]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr.interface;
    defer err.flush() catch {};

    var cli: args.Cli = .{};
    defer cli.deinit(gpa);
    var argv = try init.minimal.args.iterateAllocator(gpa);
    defer argv.deinit();
    _ = argv.skip();
    if (try args.parse(&cli, gpa, &argv, out, err)) |code| return code;

    // A testbench compiles for seconds and runs for microseconds; a `.so` is
    // the host's hot loop.
    const opt = cli.optimize orelse if (cli.exe_flag != null) std.lang.Optimize.debug else .fast;
    const backend = cli.zig_backend orelse vera.orchestrator.Backend.auto(opt, builtin.target.cpu.arch);
    // The self-hosted backend takes `-O` and does not optimise: legal, but a
    // Release build under it is only as fast as Debug minus the safety checks.
    if ((cli.exe_flag != null or cli.emit_so) and backend == .self_hosted and opt != .debug)
        try err.print("warning: --zig-backend=native does not optimise; the {t} artifact is unoptimised\n", .{opt});
    // Conflicting flags are refused by name, whatever order they came in.
    if (cli.exe_flag) |f| if (cli.display_drop_flag) {
        try err.print(
            "error: `{s}` and `--display=drop` conflict: the testbench IS the display " ++
                "output, and `--display=drop` discards every print\n",
            .{f},
        );
        return 2;
    };
    if (cli.validate_contract and cli.exe_flag == null) {
        try err.writeAll("error: `--validate-contract` turns the checks on in an --emit-exe or --run " ++
            "testbench; --check always runs them\n");
        return 2;
    }
    if (cli.lint_flag) if (cli.codegen_flag) |f| {
        try err.print(
            "error: `--lint` and `{s}` conflict: --lint stops after the frontend " ++
                "and `{s}` needs codegen\n",
            .{ f, f },
        );
        return 2;
    };

    if (cli.paths.items.len == 0) {
        try err.writeAll(args.usage_text);
        return 2;
    }
    const in_path = cli.paths.items[0];

    // Digital Verilog uses the shared frontend below. Other language families
    // need their own standard-conforming frontend and remain explicit refusals.
    if (std.mem.eql(u8, std.fs.path.extension(in_path), ".sv")) {
        var sv: diag.Bag = .init(gpa);
        defer sv.deinit(gpa);
        try sv.add(.parse, .E1104, .none, "`{s}` is an IEEE 1800 source", .{in_path});
        try report(&sv, err, cli.json, false);
        return 2;
    }
    for ([_][]const u8{ ".vhd", ".vhdl" }) |ext| {
        if (!std.mem.eql(u8, std.fs.path.extension(in_path), ext)) continue;
        try err.print(
            "error: {s}: this language extension has no enabled compilation path\n",
            .{in_path},
        );
        try err.writeAll(
            "note: use --run FILE.v for the documented digital Verilog execution subset\n",
        );
        return 2;
    }

    const source = Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(max_source_bytes)) catch |e| {
        try readFailed(err, in_path, e);
        return 2;
    };
    defer gpa.free(source);

    // Decided once: `isTty` can fail, and an error path should not re-ask.
    const use_color = switch (cli.color) {
        .always => true,
        .never => false,
        .auto => (stderr.file.isTty(io) catch false),
    };

    const digital_source = std.mem.eql(u8, std.fs.path.extension(in_path), ".v");
    // No --contract: this binary's own tools/contract.zig, written out with the
    // `sim` tree it embeds, so the contract always matches the compiler and the
    // mixed-signal runner finds `sim` beside it.
    var contract_arena: std.heap.ArenaAllocator = .init(gpa);
    defer contract_arena.deinit();
    if (cli.check or cli.emit_so or (cli.exe_flag != null and !(digital_source and cli.run_exe))) {
        if (cli.contract_path) |p| Io.Dir.cwd().access(io, p, .{}) catch |e| {
            try err.print("error: --contract {s}: {t}\n", .{ p, e });
            return 2;
        } else {
            const wd = cli.work_dir orelse ".zig-cache/vera-tb";
            cli.contract_path = simTree(io, contract_arena.allocator(), wd) catch |e| {
                try err.print("error: writing the engine sources under {s} failed: {t}\n", .{ wd, e });
                return 1;
            };
        }
    }
    if (!digital_source) {
        if (cli.paths.items.len > 1) {
            try err.writeAll("error: more than one input file\n");
            return 2;
        }
        if (cli.libmaps.items.len != 0 or cli.search.items.len != 0) {
            try err.writeAll("error: --libmap and -L configure a .v design's libraries\n");
            return 2;
        }
    }
    if (cli.logic_flag) |f| if (!digital_source or cli.run_exe) {
        try err.print("error: {s} builds a .v design's executable; it takes --emit-exe and a .v file\n", .{f});
        return 2;
    };
    if (digital_source) return digital_cli.run(gpa, io, init.environ_map, &cli, source, in_path, opt, backend, use_color, out, err);

    if (!ams) {
        try err.print("error: {s}: this vera is built with -Dlanguage=verilog; it runs .v sources only\n", .{in_path});
        return 2;
    }
    return compileAnalog(gpa, io, &cli, source, in_path, opt, backend, use_color, out, err);
}

/// The Verilog-A half of `main`: `source` through the analog pipeline to the
/// artifact the flags ask for (`--lint` stops after the frontend). Appends
/// the testbench's shape cards to `cli.overrides` after the typed ones.
/// `cli.contract_path` is set whenever `--check`, `--emit-so` or `--emit-exe`
/// was typed. Returns the process exit status.
fn compileAnalog(
    gpa: std.mem.Allocator,
    io: Io,
    cli: *args.Cli,
    source: []const u8,
    in_path: []const u8,
    opt: std.lang.Optimize,
    backend: vera.orchestrator.Backend,
    use_color: bool,
    out: *Io.Writer,
    err: *Io.Writer,
) !u8 {
    const json = cli.json;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    // E.1.1's antecedent, made true from the command line: "if a simulator which
    // supports Verilog-AMS HDL is also able to read SPICE netlists ... certain
    // objects defined in that flavor of SPICE netlist can be referenced from
    // within a Verilog-AMS HDL structural description". Read whole, because
    // `spice_cards.synthesize` works on the text and a `+` continuation makes a
    // card longer than a line.
    const netlist: []const u8 = if (cli.spice_path) |p|
        Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_source_bytes)) catch |e| {
            try readFailed(err, p, e);
            return 2;
        }
    else
        "";
    defer if (cli.spice_path != null) gpa.free(netlist);

    // --emit-exe's `//!` directives, read up front: a `//! param` card value
    // for a SHAPE parameter is a compile-time value (below). The directive
    // tables and the runner text are a web of small slices with one lifetime;
    // an arena is the whole memory management here.
    var tb_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tb_arena.deinit();
    const directives: vera.tb.Directives = if (cli.exe_flag == null) .{} else vera.tb.parse(tb_arena.allocator(), source) catch |e| {
        try err.print("error: {s}: `//!` directive: {t}\n", .{ in_path, e });
        return 2;
    };

    var opts: vera.Options = .{
        .file_name = in_path,
        .include_dirs = cli.include_dirs.items,
        .spice_netlist = netlist,
        .std_defs = cli.std_defs,
        .language = cli.language,
        .diags = &bag,
        .lint = cli.levels,
        .proof = .{ .unknown_bound = cli.unknown_bound },
        .discipline_resolution = cli.discipline_resolution,
        .display = cli.display,
        .jac_f32 = cli.jac_f32,
        .jac_f32_host = cli.jac_f32_host,
        .param_overrides = cli.overrides.items,
    };
    const target: vera.Target = if (cli.codegen_flag == null) .lint else .build;
    var result = vera.compileSourceOpts(gpa, source, target, opts) catch |e| return compileFailed(&bag, err, json, use_color, e);
    defer result.deinit();

    // §3.4 the testbench's card values for shape parameters are compile-time
    // values (`tb.shapeOverrides`); a `--param` of the same name wins.
    const cli_overrides = cli.overrides.items.len;
    for (try vera.tb.shapeOverrides(tb_arena.allocator(), directives, result.lowered)) |card| {
        for (cli.overrides.items) |o| {
            if (std.mem.eql(u8, o.name, card.name)) break;
        } else try cli.overrides.append(gpa, card);
    }
    if (cli.overrides.items.len != cli_overrides) {
        bag.deinit(gpa); // the first pass's; the second says it all again
        bag = .init(gpa);
        opts.param_overrides = cli.overrides.items;
        const again = vera.compileSourceOpts(gpa, source, target, opts) catch |e| return compileFailed(&bag, err, json, use_color, e);
        result.deinit();
        result = again;
    }

    // `--param` names a parameter a card could set: a top-module, non-local,
    // numeric scalar. A misspelling would otherwise compile the default shape.
    for (cli.overrides.items[0..cli_overrides]) |o| {
        for (result.lowered.params.items) |p| {
            if (std.mem.eql(u8, p.name, o.name) and !p.is_local and p.ty != .string) break;
        } else {
            try err.print("error: --param {s}: `{s}` declares no numeric parameter `{s}` that a card may set\n", .{ o.name, result.mir.name, o.name });
            return 2;
        }
    }

    // Warnings on a successful compile, deferred to one call on every exit
    // below: codegen reports too (E0515) and `render` prints the whole bag.
    defer report(&bag, err, json, use_color) catch {};

    if (cli.codegen_flag == null) return 0;

    // The catalogue that consumes the generated file keys devices by the name
    // the BUILD chose, while the netlist dispatch and the generated type name
    // come from the MODULE name. A mismatch silently breaks lookup, so it is
    // caught here rather than three cache steps downstream.
    //
    // NOTE: a vendored file declaring several modules (VBIC ships 4T/5T in one
    // file) trips this — VerA lowers one of them, not necessarily the one
    // the file is named after. A module selector is the fix.
    if (cli.expect_module) |want| {
        if (!std.mem.eql(u8, result.mir.name, want)) {
            try err.print(
                "error: {s}: Verilog-A module is `{s}` but `{s}` was expected — rename one of them\n",
                .{ in_path, result.mir.name, want },
            );
            return 1;
        }
    }

    const device = result.generateDevice() catch |e| {
        try err.print("error: {s}: codegen failed: {t}\n", .{ in_path, e });
        return 1;
    };

    // A fatal generation error is a refusal: writing the file anyway would
    // move the message to whoever compiles it, away from the .va.
    if (result.device_has_compile_error) {
        try err.print(
            "error: {s}: codegen refused a construct; generated output is not usable\n",
            .{in_path},
        );
        return 1;
    }

    // --check: type-check the generated Zig here, where the .va that
    // produced it can still be named. --emit-so runs the same check only
    // after its build fails: the build reports the same errors, and a
    // separate pass before it is pure wall time.
    if (cli.check) {
        if (try typeCheck(gpa, io, err, cli.zig_exe, cli.contract_path.?, device, in_path)) |code| return code;
    }

    // --emit-exe: the same device with real display tasks, driven by a
    // generated runner over the operating points its `//!` lines declare.
    if (cli.exe_flag != null) {
        const wd = cli.work_dir orelse ".zig-cache/vera-tb";
        var dm = directives;
        dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
        dm.op_states = try vera.tb.opStates(tb_arena.allocator(), result.lowered);
        dm.validate_contract = cli.validate_contract;
        try vera.tb.warnGridEvents(&bag, result.lowered, result.mir);
        // Runner diagnostics obey --deny/--forbid before an artifact is
        // built or its simulation starts, just like compiler diagnostics.
        if (bag.failed()) return 1;
        const runner = vera.tb.renderRunner(tb_arena.allocator(), std.fs.path.stem(in_path), dm) catch |e| switch (e) {
            error.TooManyPoints => {
                try err.print("error: {s}: `//!` directive: the sweeps expand to more than {d} points\n", .{ in_path, vera.tb.max_points });
                return 2;
            },
            else => |x| return x,
        };
        const built = vera.tb.buildExe(gpa, io, device, runner, .{
            .work_dir = wd,
            .contract = cli.contract_path.?,
            .name = result.mir.name,
            .out_path = cli.out_path,
            .zig_exe = cli.zig_exe,
            .mixed = dm.mixed != null,
            .optimize = opt,
            .backend = backend,
            .debug_info = cli.debug_info,
        }) catch |e| {
            try err.print("error: {s}: building the testbench failed: {t}\n", .{ in_path, e });
            return 1;
        };
        defer built.deinit(gpa);
        const bin = switch (built) {
            .failed => |text| {
                try err.print(
                    "error: {s}: the generated testbench does not compile — this is an " ++
                        "engine bug, not a problem with the model:\n",
                    .{in_path},
                );
                try err.writeAll(text);
                return 1;
            },
            .ok => |p| p,
        };
        if (!cli.run_exe) {
            try out.print("{s}\n", .{bin});
            try out.flush();
            return 0;
        }
        // --run: the transcript is the point, so inherit both streams and let
        // the testbench's exit status be ours.
        var child = try std.process.spawn(io, .{ .argv = &.{bin} });
        return switch (try child.wait(io)) {
            .exited => |c| c,
            else => 1,
        };
    }

    if (cli.emit_so) {
        const wd = cli.work_dir orelse {
            try err.writeAll("error: --emit-so needs --work-dir DIR\n");
            return 2;
        };
        const dyn = cli.dyn_path orelse {
            try err.writeAll("error: --emit-so needs --dyn PATH\n");
            return 2;
        };
        const modules = [_]vera.orchestrator.Module{
            .{ .name = "contract", .root = cli.contract_path.? },
            .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
        };
        var r = vera.buildArtifact(gpa, io, &result, .{
            .work_dir = wd,
            .name = try vera.orchestrator.fileStem(tb_arena.allocator(), result.mir.name),
            .optimize = opt,
            .backend = backend,
            .modules = &modules,
            .zig_exe = cli.zig_exe,
            .debug_info = cli.debug_info,
        }, 1) catch |e| {
            try err.print("error: {s}: building the device failed: {t}\n", .{ in_path, e });
            return 1;
        };
        defer r.deinit(gpa);
        switch (r) {
            .ok => |a| try out.print("{s}\n", .{a.so_path}),
            .failed => |bundle| {
                // An error typeCheck can see is the device's own (an engine
                // bug), reported against the .va as a check would have.
                if (try typeCheck(gpa, io, err, cli.zig_exe, cli.contract_path.?, device, in_path)) |code| return code;
                try err.print("error: {s}: the generated device did not compile:\n", .{in_path});
                try bundle.renderToWriter(.{}, err);
                return 1;
            },
        }
    }

    if (cli.emit_zig) {
        if (cli.out_path) |p| {
            Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = device }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return 1;
            };
        } else {
            try out.writeAll(device);
        }
    }
    return 0;
}

/// Writes the sources `sim` compiles from (`sim_sources`, embedded at build
/// time) under `dir` and returns the `contract` root among them, the path
/// `tb.buildExe` finds the tree from. Each file lands atomically, so a
/// concurrent `vera` writing the same tree never exposes half a file.
fn simTree(io: Io, arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const root = try std.fs.path.join(arena, &.{ dir, "vera-src" });
    var d = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer d.close(io);
    for (@import("sim_sources").files) |f| {
        var af = try d.createFileAtomic(io, f[0], .{ .make_path = true, .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, f[1]);
        try af.replace(io);
    }
    return std.fs.path.join(arena, &.{ root, "tools", "contract.zig" });
}

/// The compiler cache the prebuilt digital engine lives in, shared by every
/// work directory: `vera-engine` in Zig's global cache directory
/// (`ZIG_GLOBAL_CACHE_DIR`, else `XDG_CACHE_HOME/zig`, else
/// `HOME/.cache/zig`), else the work directory's own cache.
pub fn engineCache(arena: std.mem.Allocator, env: *const std.process.Environ.Map, work_dir: ?[]const u8) ![]const u8 {
    const global = if (env.get("ZIG_GLOBAL_CACHE_DIR")) |d|
        d
    else if (env.get("XDG_CACHE_HOME")) |d|
        try std.fs.path.join(arena, &.{ d, "zig" })
    else if (env.get("HOME")) |d|
        try std.fs.path.join(arena, &.{ d, ".cache", "zig" })
    else
        return std.fs.path.join(arena, &.{ work_dir orelse ".", ".zig-cache" });
    return std.fs.path.join(arena, &.{ global, "vera-engine" });
}

/// Reports a failed compilation's diagnostics and returns exit code 1. The Zig
/// error name is printed only for an undiagnosed failure.
fn compileFailed(bag: *diag.Bag, err: *Io.Writer, json: bool, use_color: bool, e: anyerror) !u8 {
    try report(bag, err, json, use_color);
    switch (e) {
        error.CompileFailed, error.NoModule => {},
        else => try err.print("error: {t}\n", .{e}),
    }
    return 1;
}

/// The largest source file or `--spice` netlist read (E1013).
const max_source_bytes = 64 * 1024 * 1024;

fn readFailed(w: *Io.Writer, path: []const u8, e: anyerror) !void {
    if (e == error.StreamTooLong)
        try w.print("error[E1013]: `{s}` is larger than {d} bytes; see `vera --explain E1013`\n", .{ path, max_source_bytes })
    else
        try w.print("error: cannot read `{s}`: {t}\n", .{ path, e });
}

/// How long one device's `zig build-obj` gets before it is killed. A check
/// takes well under a second per device, so a child past this is wedged, and
/// an unbounded one is a hang the parent build cannot report.
const check_budget_s = 120;

/// Kills `child` once the budget is up. Returns whether it had to; a cancel
/// (the check finished first) short-circuits the sleep and answers false.
fn killAfter(io: Io, child: *std.process.Child, seconds: i64) bool {
    io.sleep(.fromSeconds(seconds), .awake) catch return false;
    child.kill(io);
    return true;
}

/// `typeCheck`'s root: the contract's checks on, over the device.
const check_root =
    \\pub const vera_validate_contract = true;
    \\comptime {
    \\    @import("contract").validate(@import("device"));
    \\}
    \\
;

/// Runs `zig build-obj -fno-emit-bin` over the generated device with the
/// `contract` module. Returns null when it type-checks, else the exit code.
///
/// Proves only that the file parses and its `comptime` blocks hold: analysis
/// is lazy and `contract.validate` is reflection, so a type error inside an
/// `eval`/`q` body exits 0 here.
fn typeCheck(
    gpa: std.mem.Allocator,
    io: Io,
    err: *Io.Writer,
    zig_exe: []const u8,
    contract: []const u8,
    device_zig: []const u8,
    in_path: []const u8,
) !?u8 {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache/vera-check");
    var tmp = try cwd.openDir(io, ".zig-cache/vera-check", .{});
    defer tmp.close(io);

    const stem = std.fs.path.stem(in_path);
    const dev_name = try gpa.print("{s}.device.zig", .{stem});
    defer gpa.free(dev_name);
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device_zig });

    // The device is not the root: the root turns the contract's checks on
    // (`contract.validating`), which `--check` is for.
    const root_name = try gpa.print("{s}.check.zig", .{stem});
    defer gpa.free(root_name);
    try tmp.writeFile(io, .{ .sub_path = root_name, .data = check_root });
    const contract_arg = try gpa.print("-Mcontract={s}", .{contract});
    defer gpa.free(contract_arg);
    const root_arg = try gpa.print("-Mroot=.zig-cache/vera-check/{s}", .{root_name});
    defer gpa.free(root_arg);
    const device_arg = try gpa.print("-Mdevice=.zig-cache/vera-check/{s}", .{dev_name});
    defer gpa.free(device_arg);

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root module —
    // the ordering rule `buildArgv` in lib/backend/orchestrator.zig follows.
    const argv = [_][]const u8{
        zig_exe,       "build-obj",  "-fno-emit-bin",
        "--dep",       "device",     "--dep",
        "contract",    root_arg,     "--dep",
        "contract",    device_arg,   contract_arg,
        "--cache-dir", ".zig-cache",
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    // `concurrent`, not `async`: `async` is permitted to run the watchdog
    // inline on this thread, which would sleep out the whole budget before the
    // child was ever read from. An Io that cannot spare a second thread gets
    // an unbounded wait rather than a wrong one.
    var watchdog = io.concurrent(killAfter, .{ io, &child, check_budget_s }) catch null;

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = reader.interface.streamRemaining(&aw.writer) catch {};

    // Retired BEFORE `wait` reaps, because after the reap this pid belongs to
    // whoever the OS hands it to next and a watchdog still holding it would
    // signal a stranger. `killAfter` reaps what it kills, so the timed-out
    // path must not `wait` again (an assert in Child.wait).
    const timed_out = if (watchdog) |*w| w.cancel(io) else false;
    if (timed_out) {
        try err.print(
            "error: {s}: type check did not finish in {d}s and was killed. " ++
                "The generated Zig is at .zig-cache/vera-check/{s}; run the " ++
                "`zig build-obj` from typeCheck() by hand to see where it sticks.\n",
            .{ in_path, check_budget_s, dev_name },
        );
        return 1;
    }

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (!failed) return null;

    try err.print(
        "error: {s}: codegen produced Zig that does not compile — this is an engine bug, " ++
            "not a problem with the model:\n",
        .{in_path},
    );
    try err.writeAll(aw.writer.buffered());
    return 1;
}

/// Renders `bag` on `w`, as JSON or as text coloured when `color`, and flushes
/// `w`. An empty bag prints nothing. Shared by `cli/digital.zig`.
pub fn report(bag: *diag.Bag, w: *Io.Writer, json: bool, color: bool) !void {
    if (bag.isEmpty()) return;
    if (json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (color) .on else .off });
    }
    try w.flush();
}
