//! `vera` — the command-line driver, and the one place `lib/` and `src/` meet.
//!
//! The compiler is a library — `lib/`, taken here as the `vera` module — and
//! this is the thin shell that makes its diagnostics reachable from a terminal.
//! `--run FILE.v` is the other half: `src/sim`, which shares the library's
//! frontend and diagnostic vocabulary and none of its pipeline.
//!
//! It exists because the diagnostics themselves
//! advertise it: every rendered message ends with "run `vera --explain
//! EXXXX`", and `--allow=`/`--deny=` are the documented way to tune the
//! finiteness warning (W0650).
//!
//! usage:
//!   vera [options] FILE.va      compile (or lint) one Verilog-A source
//!   vera --explain CODE         print the catalogue entry for a code
//!
//! It is also the BUILD-TIME generator: `--emit-zig -o OUT.zig` is what a
//! dependent build step runs once per `models/NAME.va`, which is why the
//! module-name check and the `@compileError` gate live here rather than in a
//! separate wrapper tool.
//!
//! options: `usage_text` below is the one list (`vera --help` prints it).
//!
//! exit status: 0 on success (warnings do not fail), 1 on a diagnosed error,
//! 2 on a usage error. Conflicting flags are usage errors, not last-one-wins:
//! `--lint` with any codegen mode (`--emit-zig`/`-o`/`--check`/`--emit-so`/
//! `--emit-exe`/`--run`), and `--emit-exe`/`--run` with `--display=drop` —
//! a testbench exists to print, so dropping its prints is a contradiction.

const std = @import("std");
const builtin = @import("builtin");
/// `-Dlanguage=ams`. False is an IEEE 1364-2005 tool: every path past the
/// digital one is comptime-dead, so the analog backend is never compiled in.
const ams = @import("build_options").ams;
const vera = @import("vera");
const digital = @import("sim").digital;
const diag = vera.diag;
const Io = std.Io;

const usage_text =
    \\usage: vera [options] FILE.va
    \\       vera --explain CODE
    \\
    \\  --lint                  frontend only (parse, lower, prove); no codegen
    \\  --emit-zig              generate the device; to stdout unless -o is given
    \\  -o PATH                 write the generated device.zig here
    \\  --expect-module=NAME    fail unless the compiled module is called NAME
    \\  --check                 type-check the generated device with zig
    \\  --emit-so               build lib<name>.<gen>.so via the orchestrator
    \\  --emit-exe              build a runnable Verilog-A testbench; print its path
    \\  --run                   run a .v initial-process program, or an analog testbench
    \\  --display=drop|emit     ch9 display tasks: void (device) or printed (exe)
    \\  --jac-f32               mark the device as tolerating an f32 Jacobian
    \\  --jac-f32-host          ...and ask the host to use it on its CPU path
    \\  --contract PATH         root of the `contract` module
    \\  --dyn PATH              root of the `dyn` module (--emit-so)
    \\  --work-dir DIR          scratch + artifact directory (--emit-so)
    \\  --zig PATH              zig executable to drive (default: zig)
    \\  --optimize=MODE         Debug|ReleaseSafe|ReleaseFast|ReleaseSmall (default: exe Debug, so ReleaseFast)
    \\  --zig-backend=auto|llvm|native   auto: native for Debug on x86_64, else llvm
    \\  -I DIR                  add an `include search directory
    \\  --param NAME=VALUE      compile with the top module's parameter NAME set
    \\                          to VALUE (LRM 3.4). A parameter that sizes an
    \\                          array, vector or replication, or bounds a genvar
    \\                          loop or selects a generate arm, is fixed at VALUE and
    \\                          the device refuses a card that moves it
    \\                          (`checkShape`); any other stays a card value
    \\  --spice PATH            read a SPICE netlist alongside the source; Annex
    \\                          E.2's .MODEL and .SUBCKT cards in it become
    \\                          module definitions the .va can instantiate
    \\  --no-std-defs           do not prepend the annex D prelude
    \\  --std=SPEC              source language, a `begin_keywords specifier:
    \\                          1364-1995|1364-2001|1364-2005|VAMS-2.3|VAMS-2023
    \\                          (default; 1364-2005 under -Dlanguage=verilog).
    \\                          A 1364 language frees every AMS keyword as an
    \\                          identifier and refuses AMS constructs (E0242)
    \\  --diagnostics=text|json how to report (default: text)
    \\  --color=auto|always|never
    \\  --allow/--warn/--deny/--forbid=CODE   per-code lint level
    \\  --unknown-bound=X       solver compliance limit (see --explain W0650)
    \\
;

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

    var levels: diag.Levels = .empty;
    defer levels.deinit(gpa);

    var include_dirs: std.ArrayList([]const u8) = .empty;
    defer include_dirs.deinit(gpa);

    var overrides: std.ArrayList(vera.ParamOverride) = .empty;
    defer overrides.deinit(gpa);

    var path: ?[]const u8 = null;
    var emit_zig = false;
    var json = false;
    var color: enum { auto, always, never } = .auto;
    var unknown_bound: ?f64 = null;
    var std_defs = true;
    var language: vera.KeywordSet = if (ams) .vams_2023 else .v1364_2005;
    var out_path: ?[]const u8 = null;
    var expect_module: ?[]const u8 = null;
    var check = false;
    var emit_so = false;
    var run_exe = false;
    var display: vera.codegen.Display = .drop;
    var jac_f32 = false;
    var jac_f32_host = false;
    // What the user actually TYPED, kept apart from the derived state above so
    // conflicting spellings can be refused by name after the loop — argument
    // order must not decide silently (`--emit-exe --display=drop` used to
    // build a testbench whose model prints were all dropped, exit 0).
    var lint_flag = false;
    var display_drop_flag = false;
    var codegen_flag: ?[]const u8 = null; // the last flag that implies codegen
    var exe_flag: ?[]const u8 = null; // --emit-exe or --run, whichever was typed
    var contract_path: ?[]const u8 = null;
    var dyn_path: ?[]const u8 = null;
    var work_dir: ?[]const u8 = null;
    var zig_exe: []const u8 = "zig";
    var optimize: ?std.builtin.OptimizeMode = null;
    var zig_backend: ?vera.orchestrator.Backend = null; // null: `Backend.auto`
    var spice_path: ?[]const u8 = null;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage_text);
            return 0;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            const name = args.next() orelse return missing(err, "--explain", "a code, e.g. --explain W0650");
            const code = std.meta.stringToEnum(diag.Code, name) orelse {
                try err.print("error: unknown diagnostic code `{s}`\n", .{name});
                return 2;
            };
            try diag.explain(code, out, if (color == .never) .off else .on);
            return 0;
        } else if (std.mem.eql(u8, arg, "--lint")) {
            lint_flag = true;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            emit_zig = true;
            codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
            codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-so")) {
            emit_so = true;
            codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-exe") or std.mem.eql(u8, arg, "--run")) {
            // The testbench IS the display output, so asking for one and then
            // dropping the prints would build an artifact with nothing to say.
            run_exe = run_exe or std.mem.eql(u8, arg, "--run");
            display = .emit;
            codegen_flag = arg;
            exe_flag = arg;
        } else if (std.mem.eql(u8, arg, "--display=emit")) {
            display = .emit;
            display_drop_flag = false;
        } else if (std.mem.eql(u8, arg, "--display=drop")) {
            display = .drop;
            display_drop_flag = true;
        } else if (std.mem.eql(u8, arg, "--jac-f32")) {
            jac_f32 = true;
        } else if (std.mem.eql(u8, arg, "--jac-f32-host")) {
            jac_f32_host = true;
        } else if (std.mem.eql(u8, arg, "--contract")) {
            contract_path = args.next() orelse return missing(err, "--contract", "a path");
        } else if (std.mem.eql(u8, arg, "--param")) {
            const kv = args.next() orelse return missing(err, "--param", "NAME=VALUE");
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return missing(err, "--param", "NAME=VALUE");
            const value = std.fmt.parseFloat(f64, kv[eq + 1 ..]) catch {
                try err.print("error: --param {s}: `{s}` is not a number\n", .{ kv, kv[eq + 1 ..] });
                return 2;
            };
            try overrides.append(gpa, .{ .name = kv[0..eq], .value = value });
        } else if (std.mem.eql(u8, arg, "--dyn")) {
            dyn_path = args.next() orelse return missing(err, "--dyn", "a path");
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            work_dir = args.next() orelse return missing(err, "--work-dir", "a directory");
        } else if (std.mem.eql(u8, arg, "--zig")) {
            zig_exe = args.next() orelse return missing(err, "--zig", "a path");
        } else if (std.mem.startsWith(u8, arg, "--optimize=")) {
            optimize = std.meta.stringToEnum(std.builtin.OptimizeMode, arg["--optimize=".len..]) orelse {
                try err.print("error: `{s}`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--zig-backend=")) {
            const v = arg["--zig-backend=".len..];
            zig_backend = if (std.mem.eql(u8, v, "auto")) null else if (std.mem.eql(u8, v, "llvm")) .llvm else if (std.mem.eql(u8, v, "native")) .self_hosted else {
                try err.print("error: `{s}`: not auto|llvm|native\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse return missing(err, "-o", "a path");
            emit_zig = true;
            codegen_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--expect-module=")) {
            expect_module = arg["--expect-module=".len..];
        } else if (std.mem.eql(u8, arg, "--spice")) {
            spice_path = args.next() orelse return missing(err, "--spice", "a path");
        } else if (std.mem.eql(u8, arg, "-I")) {
            try include_dirs.append(gpa, args.next() orelse return missing(err, "-I", "a directory"));
        } else if (std.mem.startsWith(u8, arg, "--std=")) {
            language = vera.KeywordSet.fromSpecifier(arg["--std=".len..]) orelse {
                try err.print("error: `{s}`: not a `begin_keywords version specifier\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--no-std-defs")) {
            std_defs = false;
        } else if (std.mem.eql(u8, arg, "--diagnostics=json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--diagnostics=text")) {
            json = false;
        } else if (std.mem.eql(u8, arg, "--color=always")) {
            color = .always;
        } else if (std.mem.eql(u8, arg, "--color=never")) {
            color = .never;
        } else if (std.mem.eql(u8, arg, "--color=auto")) {
            color = .auto;
        } else if (std.mem.startsWith(u8, arg, "--unknown-bound=")) {
            unknown_bound = std.fmt.parseFloat(f64, arg["--unknown-bound=".len..]) catch {
                try err.print("error: `{s}` is not a number\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // --allow=X / --warn=X / --deny=X / --forbid=X
            const applied = levels.parseFlag(gpa, arg[2..]) catch |e| switch (e) {
                error.CannotAllowError => {
                    try err.print(
                        "error: `{s}`: an error code cannot be allowed or warned away — " ++
                            "it is a statement about the program, not a preference\n",
                        .{arg},
                    );
                    return 2;
                },
                error.Forbidden => {
                    try err.print("error: `{s}`: this code was already --forbid'd\n", .{arg});
                    return 2;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (!applied) {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            }
        } else if (path == null) {
            path = arg;
        } else {
            try err.writeAll("error: more than one input file\n");
            return 2;
        }
    }

    // Conflicting flags are refused by NAME, whatever order they came in.
    // Without this the last one silently won: `--emit-exe --display=drop`
    // built a testbench with every model print discarded and exited 0, and
    // `--emit-zig --lint` left `emit_zig` set while the pipeline stopped
    // before codegen, so the "generated device" step read a lint result.
    // A testbench compiles for seconds and runs for microseconds; a `.so` is
    // the host's hot loop.
    const opt = optimize orelse if (exe_flag != null) std.builtin.OptimizeMode.Debug else .ReleaseFast;
    const backend = zig_backend orelse vera.orchestrator.Backend.auto(opt, builtin.cpu.arch);
    // The self-hosted backend takes `-O` and does not optimise: legal, but a
    // Release build under it is only as fast as Debug minus the safety checks.
    if ((exe_flag != null or emit_so) and backend == .self_hosted and opt != .Debug)
        try err.print("warning: --zig-backend=native does not optimise; the {t} artifact is unoptimised\n", .{opt});
    if (exe_flag) |f| if (display_drop_flag) {
        try err.print(
            "error: `{s}` and `--display=drop` conflict: the testbench IS the display " ++
                "output, and `--display=drop` discards every print\n",
            .{f},
        );
        return 2;
    };
    if (lint_flag) if (codegen_flag) |f| {
        try err.print(
            "error: `--lint` and `{s}` conflict: --lint stops after the frontend " ++
                "and `{s}` needs codegen\n",
            .{ f, f },
        );
        return 2;
    };

    const in_path = path orelse {
        try err.writeAll(usage_text);
        return 2;
    };

    // Digital Verilog uses the shared frontend below. Other language families
    // need their own standard-conforming frontend and remain explicit refusals.
    for ([_][]const u8{ ".sv", ".vhd", ".vhdl" }) |ext| {
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

    const source = Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(64 * 1024 * 1024)) catch |e| {
        try err.print("error: cannot read `{s}`: {t}\n", .{ in_path, e });
        return 2;
    };
    defer gpa.free(source);

    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    // Decided once: `isTty` can fail, and re-asking it on three error paths is
    // three more things that can go wrong while reporting an error.
    const use_color = switch (color) {
        .always => true,
        .never => false,
        .auto => (stderr.file.isTty(io) catch false),
    };

    if (std.mem.eql(u8, std.fs.path.extension(in_path), ".v")) {
        if (!run_exe or lint_flag or emit_zig or check or emit_so or out_path != null) {
            try err.writeAll("error: digital .v source currently requires --run; artifact generation is not implemented\n");
            return 2;
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var digital_bag = diag.Bag.init(arena.allocator());
        digital_bag.levels = levels;
        digital.run(arena.allocator(), source, .{ .file_name = in_path, .include_dirs = include_dirs.items, .io = io, .language = language }, &digital_bag, out) catch |e| {
            try report(&digital_bag, err, json, use_color);
            if (e != error.DigitalFailed) try err.print("error: digital execution failed: {t}\n", .{e});
            return 1;
        };
        try report(&digital_bag, err, json, use_color);
        return 0;
    }

    if (!ams) {
        try err.print("error: {s}: this vera is built with -Dlanguage=verilog; it runs .v sources only\n", .{in_path});
        return 2;
    }

    // E.1.1's antecedent, made true from the command line: "if a simulator which
    // supports Verilog-AMS HDL is also able to read SPICE netlists ... certain
    // objects defined in that flavor of SPICE netlist can be referenced from
    // within a Verilog-AMS HDL structural description". Read whole, because
    // `spice_cards.synthesize` works on the text and a `+` continuation makes a
    // card longer than a line.
    const netlist: []const u8 = if (spice_path) |p|
        Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 * 1024 * 1024)) catch |e| {
            try err.print("error: cannot read `{s}`: {t}\n", .{ p, e });
            return 2;
        }
    else
        "";
    defer if (spice_path != null) gpa.free(netlist);

    // --emit-exe's `//!` directives, read up front: a `//! param` card value
    // for a SHAPE parameter is a compile-time value (below). The directive
    // tables and the runner text are a web of small slices with one lifetime;
    // an arena is the whole memory management here.
    var tb_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tb_arena.deinit();
    const directives: vera.tb.Directives = if (exe_flag == null) .{} else vera.tb.parse(tb_arena.allocator(), source) catch |e| {
        try err.print("error: {s}: `//!` directive: {t}\n", .{ in_path, e });
        return 2;
    };

    var opts: vera.Options = .{
        .file_name = in_path,
        .include_dirs = include_dirs.items,
        .spice_netlist = netlist,
        .std_defs = std_defs,
        .language = language,
        .diags = &bag,
        .lint = levels,
        .proof = .{ .unknown_bound = unknown_bound },
        .display = display,
        .jac_f32 = jac_f32,
        .jac_f32_host = jac_f32_host,
        .param_overrides = overrides.items,
    };
    const target: vera.Target = if (codegen_flag == null) .lint else .build;
    var result = vera.compileSourceOpts(gpa, source, target, opts) catch |e| return compileFailed(&bag, err, json, use_color, e);
    defer result.deinit();

    // §3.4 the testbench's card values for shape parameters are compile-time
    // values (`tb.shapeOverrides`); a `--param` of the same name wins.
    const cli_overrides = overrides.items.len;
    for (try vera.tb.shapeOverrides(tb_arena.allocator(), directives, result.lowered)) |card| {
        for (overrides.items) |o| {
            if (std.mem.eql(u8, o.name, card.name)) break;
        } else try overrides.append(gpa, card);
    }
    if (overrides.items.len != cli_overrides) {
        bag.deinit(gpa); // the first pass's; the second says it all again
        bag = .init(gpa);
        opts.param_overrides = overrides.items;
        const again = vera.compileSourceOpts(gpa, source, target, opts) catch |e| return compileFailed(&bag, err, json, use_color, e);
        result.deinit();
        result = again;
    }

    // `--param` names a parameter a card could set: a top-module, non-local,
    // numeric scalar. A misspelling would otherwise compile the default shape.
    for (overrides.items[0..cli_overrides]) |o| {
        for (result.lowered.params.items) |p| {
            if (std.mem.eql(u8, p.name, o.name) and !p.is_local and p.ty != .string) break;
        } else {
            try err.print("error: --param {s}: `{s}` declares no numeric parameter `{s}` that a card may set\n", .{ o.name, result.mir.name, o.name });
            return 2;
        }
    }

    // Diagnostics on a SUCCESSFUL compile — W0650 is the reason this path
    // exists. DEFERRED, because codegen is a diagnostic-producing stage too
    // (E0515: a §4.5 control argument that does not resolve is reported at the
    // `.va` line, not pasted into the generated Zig as an `@compileError`), and
    // `render` prints the whole bag — so there is exactly one call for every
    // exit below rather than one per return path.
    defer report(&bag, err, json, use_color) catch {};

    if (codegen_flag == null) return 0;

    // The catalogue that consumes the generated file keys devices by the name
    // the BUILD chose, while the netlist dispatch and the generated type name
    // come from the MODULE name. A mismatch silently breaks lookup, so it is
    // caught here rather than three cache steps downstream.
    //
    // NOTE: a vendored file declaring several modules (VBIC ships 4T/5T in one
    // file) trips this — VerA lowers one of them, not necessarily the one
    // the file is named after. A module selector is the fix.
    if (expect_module) |want| {
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

    // A fatal generation error is a refusal by codegen. Writing the file
    // anyway defers the real message to whoever compiles it, by which point it
    // no longer names the .va that caused it.
    if (result.device_has_compile_error) {
        try err.print(
            "error: {s}: codegen refused a construct; generated output is not usable\n",
            .{in_path},
        );
        return 1;
    }

    // --check: prove the generated Zig actually compiles, HERE, where the .va
    // that produced it is still in hand. Without this a codegen bug surfaces
    // as an error inside generated code in a build cache directory, with
    // nothing pointing back at the source model.
    if (check or emit_so) {
        const contract = contract_path orelse {
            try err.writeAll(
                "error: --check and --emit-so need --contract PATH (the root of the " ++
                    "`contract` module the generated device imports)\n",
            );
            return 2;
        };
        if (try typeCheck(gpa, io, err, zig_exe, contract, device, in_path)) |code| return code;
    }

    // --emit-exe: the OTHER artifact. Same frontend, same device.zig; what
    // changes is that the display tasks are real and a generated runner drives
    // the module over the operating points its `//!` lines declare.
    if (exe_flag != null) {
        const contract = contract_path orelse {
            try err.writeAll(
                "error: --emit-exe needs --contract PATH (the root of the `contract` " ++
                    "module the generated device imports)\n",
            );
            return 2;
        };
        const wd = work_dir orelse ".zig-cache/vera-tb";
        var dm = directives;
        dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
        const runner = try vera.tb.renderRunner(tb_arena.allocator(), std.fs.path.stem(in_path), dm);
        const built = vera.tb.buildExe(gpa, io, device, runner, .{
            .work_dir = wd,
            .contract = contract,
            .name = result.mir.name,
            .out_path = out_path,
            .zig_exe = zig_exe,
            .mixed = dm.mixed != null,
            .optimize = opt,
            .backend = backend,
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
        if (!run_exe) {
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

    if (emit_so) {
        const wd = work_dir orelse {
            try err.writeAll("error: --emit-so needs --work-dir DIR\n");
            return 2;
        };
        const dyn = dyn_path orelse {
            try err.writeAll("error: --emit-so needs --dyn PATH\n");
            return 2;
        };
        const modules = [_]vera.orchestrator.Module{
            .{ .name = "contract", .root = contract_path.? },
            .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
        };
        var r = vera.buildArtifact(gpa, io, &result, .{
            .work_dir = wd,
            .name = result.mir.name,
            .optimize = opt,
            .backend = backend,
            .modules = &modules,
            .zig_exe = zig_exe,
        }, 1, null) catch |e| {
            try err.print("error: {s}: building the device failed: {t}\n", .{ in_path, e });
            return 1;
        };
        defer r.deinit(gpa);
        switch (r) {
            .ok => |a| try out.print("{s}\n", .{a.so_path}),
            .failed => |bundle| {
                try err.print("error: {s}: the generated device did not compile:\n", .{in_path});
                try bundle.renderToWriter(.{}, err);
                return 1;
            },
        }
    }

    if (emit_zig) {
        if (out_path) |p| {
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

/// A compilation that failed: its diagnostics, then exit 1. A diagnosed
/// failure has already said everything useful; the Zig error name would only
/// add noise.
fn compileFailed(bag: *diag.Bag, err: *Io.Writer, json: bool, use_color: bool, e: anyerror) !u8 {
    try report(bag, err, json, use_color);
    switch (e) {
        error.CompileFailed, error.NoModule => {},
        else => try err.print("error: {t}\n", .{e}),
    }
    return 1;
}

fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) !u8 {
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
}

/// How long one device's `zig build-obj` gets before it is killed.
///
/// Three orders of magnitude of slack: the check costs 0.03–0.28 s per device
/// and the whole 39-device ARPice catalog runs in about five seconds
/// (measured 2026-09-10, cold and warm cache alike). Nothing that trips 120 s
/// is slow — it is wedged. This bound exists because three of these were once
/// found at 99% CPU for 82 minutes with the parent `zig build` waiting on them
/// and not one line of diagnostic anywhere; an unbounded child is a hang the
/// build cannot report, whatever the cause turns out to be.
const check_budget_s = 120;

/// Kills `child` once the budget is up. Returns whether it had to — a cancel
/// (the check finished first) short-circuits the sleep and answers false.
fn killAfter(io: Io, child: *std.process.Child, seconds: i64) bool {
    io.sleep(.fromSeconds(seconds), .awake) catch return false;
    child.kill(io);
    return true;
}

/// Run `zig build-obj` over the generated device with the `contract` module on
/// the command line. Returns null when it type-checks, or the exit code to use.
///
/// `build-obj`, not `build-lib`: this only has to prove the code is valid, and
/// object emission skips linking entirely.
///
/// NOTE: this proves the FILE parses and its two `comptime` blocks hold, and
/// nothing more. `-fno-emit-bin` analyses lazily and `contract.validate` is
/// pure reflection — it says so itself, "a generic return cannot be checked
/// without instantiating" — so no `eval`/`q` body is ever reached and a type
/// error inside one exits 0 here. See docs/perf/veracheck-hang-2026-09-10.md
/// in ARPice for the measurement and the fix.
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
    const dev_name = try std.fmt.allocPrint(gpa, "{s}.device.zig", .{stem});
    defer gpa.free(dev_name);
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device_zig });

    const contract_arg = try std.fmt.allocPrint(gpa, "-Mcontract={s}", .{contract});
    defer gpa.free(contract_arg);
    const root_arg = try std.fmt.allocPrint(gpa, "-Mroot=.zig-cache/vera-check/{s}", .{dev_name});
    defer gpa.free(root_arg);

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root module —
    // same ordering rule buildArgv() in orchestrator.zig follows.
    const argv = [_][]const u8{
        zig_exe,      "build-obj",   "-fno-emit-bin",
        "--dep",      "contract",    root_arg,
        contract_arg, "--cache-dir", ".zig-cache",
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
    // the old unbounded wait rather than a wrong one.
    var watchdog = io.concurrent(killAfter, .{ io, &child, check_budget_s }) catch null;

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = reader.interface.streamRemaining(&aw.writer) catch {};

    // Retired BEFORE `wait` reaps, because after the reap this pid belongs to
    // whoever the OS hands it to next and a watchdog still holding it would
    // signal a stranger. `killAfter` reaps what it kills, so the timed-out
    // path must not `wait` again — that is an assert in Child.wait.
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

fn report(bag: *diag.Bag, w: *Io.Writer, json: bool, color: bool) !void {
    if (bag.isEmpty()) return;
    if (json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (color) .on else .off });
    }
    try w.flush();
}
