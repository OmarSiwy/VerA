//! `vera`, the command-line driver: argv -> a compiled, linted, generated or
//! run artifact, with the library's diagnostics on stderr. `--run FILE.v` uses
//! `src/sim` instead of the analog pipeline. Options: `usage_text`.
//!
//! Exit status: 0 on success (warnings do not fail), 1 on a diagnosed error,
//! 2 on a usage error, including conflicting flags (never last-one-wins).

const std = @import("std");
const builtin = @import("builtin");
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;
const vera = @import("vera");
const digital = @import("sim").digital;
const diag = vera.diag;
const Io = std.Io;

const usage_text =
    \\usage: vera [options] FILE.va
    \\       vera --run|--emit-exe [options] FILE.v [MORE.v ...]
    \\       vera --emit-zig|--check|--emit-so [options] FILE.v [MORE.v ...]
    \\       vera --explain CODE
    \\
    \\  --lint                  frontend only (parse, lower, prove); no codegen
    \\  --emit-zig              generate the device; to stdout unless -o is given
    \\  -o PATH                 write the generated device.zig here
    \\  --expect-module=NAME    fail unless the compiled module is called NAME
    \\  --check                 type-check the generated device with zig
    \\  --emit-so               build lib<name>.<gen>.so via the orchestrator
    \\  --emit-exe              build a runnable Verilog-A testbench,
    \\                          or a .v design's executable; print its path
    \\                          (--emit-zig, --check and --emit-so of a .v build its
    \\                          top module as a contract device, 4-state, E1103)
    \\  --schedule=static|fifo  a .v executable's order of same-time events:
    \\                          combinational logic levelized (static, the
    \\                          default; IEEE 1364 §11.4.1), or the interpreter's
    \\  --state=auto|2|4        a .v executable's logic: 4-state until no live x
    \\                          or z is left, then 2-state, printing what 4-state
    \\                          prints (auto, the default); every x or z is 0,
    \\                          NOT IEEE 1364 4-state logic (2, E1101); 4-state
    \\  --two-state             --state=2
    \\  --event-budget=N        a .v design's events at one time step before a
    \\                          zero-delay loop is refused (default 10000000)
    \\  --run                   run a .v initial-process program, or an analog testbench
    \\  --libmap FILE           read an IEEE 1364 §13.2 library map (repeatable, read
    \\                          in order); each .v file compiles into the library
    \\                          whose file_path_spec matches it, else `work`
    \\  -L LIB                  search LIB for an instance's cell (repeatable, in
    \\                          order; IEEE 1364 §13.7.1); default: map order, then work
    \\  --display=drop|emit     ch9 display tasks: void (device) or printed (exe)
    \\  --jac-f32               mark the device as tolerating an f32 Jacobian
    \\  --jac-f32-host          ...and ask the host to use it on its CPU path
    \\  --contract PATH         root of the `contract` module (default: this vera's
    \\                          own, written under the work directory)
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

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var libmaps: std.ArrayList([]const u8) = .empty;
    defer libmaps.deinit(gpa);
    var search: std.ArrayList([]const u8) = .empty;
    defer search.deinit(gpa);
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
    // What the user typed, kept apart from the derived state above so
    // conflicting flags are refused by name after the loop, whatever their
    // order.
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
    var schedule: digital.emit.Schedule = .static;
    var event_budget: u64 = digital.max_events_per_tick;
    var logic: digital.emit.Logic = .auto;
    var logic_flag: ?[]const u8 = null;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
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
        } else if (std.mem.eql(u8, arg, "--two-state")) {
            logic = .two;
            logic_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--state=")) {
            const v = arg["--state=".len..];
            logic = if (std.mem.eql(u8, v, "auto")) .auto else if (std.mem.eql(u8, v, "2")) .two else if (std.mem.eql(u8, v, "4")) .four else {
                try err.print("error: `{s}`: not auto|2|4\n", .{arg});
                return 2;
            };
            logic_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--schedule=")) {
            schedule = std.meta.stringToEnum(digital.emit.Schedule, arg["--schedule=".len..]) orelse {
                try err.print("error: `{s}`: not static|fifo\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--event-budget=")) {
            event_budget = std.fmt.parseInt(u64, arg["--event-budget=".len..], 10) catch 0;
            if (event_budget == 0) {
                try err.print("error: `{s}`: not a positive integer\n", .{arg});
                return 2;
            }
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
        } else if (std.mem.eql(u8, arg, "--libmap")) {
            try libmaps.append(gpa, args.next() orelse return missing(err, "--libmap", "a library map file"));
        } else if (std.mem.eql(u8, arg, "-L")) {
            try search.append(gpa, args.next() orelse return missing(err, "-L", "a library name"));
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
        } else try paths.append(gpa, arg);
    }

    // A testbench compiles for seconds and runs for microseconds; a `.so` is
    // the host's hot loop.
    const opt = optimize orelse if (exe_flag != null) std.builtin.OptimizeMode.Debug else .ReleaseFast;
    const backend = zig_backend orelse vera.orchestrator.Backend.auto(opt, builtin.cpu.arch);
    // The self-hosted backend takes `-O` and does not optimise: legal, but a
    // Release build under it is only as fast as Debug minus the safety checks.
    if ((exe_flag != null or emit_so) and backend == .self_hosted and opt != .Debug)
        try err.print("warning: --zig-backend=native does not optimise; the {t} artifact is unoptimised\n", .{opt});
    // Conflicting flags are refused by name, whatever order they came in.
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

    if (paths.items.len == 0) {
        try err.writeAll(usage_text);
        return 2;
    }
    const in_path = paths.items[0];

    // Digital Verilog uses the shared frontend below. Other language families
    // need their own standard-conforming frontend and remain explicit refusals.
    if (std.mem.eql(u8, std.fs.path.extension(in_path), ".sv")) {
        var sv: diag.Bag = .init(gpa);
        defer sv.deinit(gpa);
        try sv.add(.parse, .E1104, .none, "`{s}` is an IEEE 1800 source", .{in_path});
        try report(&sv, err, json, false);
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

    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    // Decided once: `isTty` can fail, and an error path should not re-ask.
    const use_color = switch (color) {
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
    if (check or emit_so or (exe_flag != null and !(digital_source and run_exe))) {
        if (contract_path) |p| Io.Dir.cwd().access(io, p, .{}) catch |e| {
            try err.print("error: --contract {s}: {t}\n", .{ p, e });
            return 2;
        } else {
            const wd = work_dir orelse ".zig-cache/vera-tb";
            contract_path = simTree(io, contract_arena.allocator(), wd) catch |e| {
                try err.print("error: writing the engine sources under {s} failed: {t}\n", .{ wd, e });
                return 1;
            };
        }
    }
    if (!digital_source) {
        if (paths.items.len > 1) {
            try err.writeAll("error: more than one input file\n");
            return 2;
        }
        if (libmaps.items.len != 0 or search.items.len != 0) {
            try err.writeAll("error: --libmap and -L configure a .v design's libraries\n");
            return 2;
        }
    }
    if (logic_flag) |f| if (!digital_source or run_exe) {
        try err.print("error: {s} builds a .v design's executable; it takes --emit-exe and a .v file\n", .{f});
        return 2;
    };
    if (digital_source) {
        const device = emit_zig or check or emit_so;
        if ((exe_flag == null) == !device or lint_flag or (out_path != null and !emit_zig)) {
            try err.writeAll("error: digital .v source takes --run or --emit-exe, or --emit-zig, --check or --emit-so for a contract device\n");
            return 2;
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var digital_bag = diag.Bag.init(arena.allocator());
        digital_bag.levels = levels;
        var opts: digital.Options = .{ .file_name = in_path, .include_dirs = include_dirs.items, .io = io, .language = language, .event_budget = event_budget };
        if (!try libraries(arena.allocator(), io, paths.items, libmaps.items, search.items, &opts, err, json, use_color)) return 1;
        if (device) return emitDevice(gpa, io, arena.allocator(), &digital_bag, source, opts, schedule, if (logic_flag != null) logic else .four, .{
            .zig = emit_zig,
            .check = check,
            .so = emit_so,
            .out_path = out_path,
            .contract = contract_path,
            .dyn = dyn_path,
            .work_dir = work_dir,
            .zig_exe = zig_exe,
            .optimize = opt,
            .backend = backend,
        }, out, err, json, use_color);
        const wd = work_dir orelse ".zig-cache/vera-tb";
        if (!run_exe) return emitDigital(gpa, io, arena.allocator(), &digital_bag, source, opts, .{
            .work_dir = wd,
            .contract = contract_path.?,
            .name = std.fs.path.stem(in_path),
            .zig_exe = zig_exe,
            .mixed = true,
            .optimize = opt,
            .backend = backend,
        }, schedule, logic, out, err, json, use_color);
        digital.run(arena.allocator(), source, opts, &digital_bag, out) catch |e| {
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
        Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_source_bytes)) catch |e| {
            try readFailed(err, p, e);
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

    // Warnings on a successful compile, deferred to one call on every exit
    // below: codegen reports too (E0515) and `render` prints the whole bag.
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
    // produced it can still be named.
    if (check or emit_so) {
        if (try typeCheck(gpa, io, err, zig_exe, contract_path.?, device, in_path)) |code| return code;
    }

    // --emit-exe: the same device with real display tasks, driven by a
    // generated runner over the operating points its `//!` lines declare.
    if (exe_flag != null) {
        const wd = work_dir orelse ".zig-cache/vera-tb";
        var dm = directives;
        dm.mixed = vera.tb.mixedPlan(result.lowered, result.mir);
        dm.op_states = try vera.tb.opStates(tb_arena.allocator(), result.lowered);
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
            .contract = contract_path.?,
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
            .name = try vera.orchestrator.fileStem(tb_arena.allocator(), result.mir.name),
            .optimize = opt,
            .backend = backend,
            .modules = &modules,
            .zig_exe = zig_exe,
        }, 1) catch |e| {
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

/// `vera --emit-exe design.v`: elaborate here, so a design the engine refuses
/// is refused now with `vera --run`'s diagnostics; then build the executable
/// `digital.emit` writes and print its path. A design that is not native says
/// so on stderr and embeds the interpreter.
fn emitDigital(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    bag: *diag.Bag,
    source: []const u8,
    opts: digital.Options,
    build: vera.tb.BuildOptions,
    schedule: digital.emit.Schedule,
    logic: digital.emit.Logic,
    out: *Io.Writer,
    err: *Io.Writer,
    json: bool,
    use_color: bool,
) !u8 {
    var sink: Io.Writer.Discarding = .init(&.{});
    var r = digital.elaborate(arena, source, opts, bag, &sink.writer) catch |e| {
        try report(bag, err, json, use_color);
        if (e != error.DigitalFailed) try err.print("error: digital elaboration failed: {t}\n", .{e});
        return 1;
    };
    try report(bag, err, json, use_color);
    const prog = try digital.emit.program(arena, &r, .{
        .source = source,
        .file_name = opts.file_name,
        .include_dirs = opts.include_dirs,
        .language = opts.language,
        .lib = opts.lib,
        .more = opts.more,
        .search = opts.search,
    }, schedule, logic);
    if (prog.fallback) |why| {
        if (logic == .two) {
            try bag.add(.lower, .E1101, .{ .start = 0, .end = 0 }, "--two-state needs a native design in which no x or z carries meaning: {s}", .{why});
            try report(bag, err, json, use_color);
            return 1;
        }
        try err.print("note: {s}: not native ({s})\n", .{ opts.file_name, why });
    }
    if (logic == .two) try err.writeAll("note: --two-state is not IEEE 1364 §3.2/§4.1 4-state simulation; output differs wherever an x or z would have arisen\n");
    if (logic == .auto and prog.fallback == null) if (prog.four) |k| {
        try err.print("note: {s}: 4-state: {s}", .{ opts.file_name, k.why });
        if (k.tok) |t| {
            const loc = r.bag.locate(.{ .start = r.starts[t], .end = r.starts[t] }, null);
            const text = r.bag.fileText(loc.file);
            const line = 1 + std.mem.count(u8, text[0..@min(loc.offset, text.len)], "\n");
            try err.print(" ({s}:{d})", .{ r.bag.fileName(loc.file), line });
        }
        try err.writeAll("\n");
    } else try err.print("note: {s}: 2-state once a time step begins with no live x or z; 4-state until then\n", .{opts.file_name});
    const built = vera.tb.buildExe(gpa, io, null, prog.text, build) catch |e| {
        try err.print("error: {s}: building the executable failed: {t}\n", .{ opts.file_name, e });
        return 1;
    };
    defer built.deinit(gpa);
    switch (built) {
        .failed => |text| {
            try err.print("error: {s}: the generated executable does not compile — this is an engine bug:\n", .{opts.file_name});
            try err.writeAll(text);
            return 1;
        },
        .ok => |p| try out.print("{s}\n", .{p}),
    }
    return 0;
}

/// What `emitDevice` builds, and with what.
const DeviceFlags = struct {
    zig: bool,
    check: bool,
    so: bool,
    out_path: ?[]const u8,
    contract: ?[]const u8,
    dyn: ?[]const u8,
    work_dir: ?[]const u8,
    zig_exe: []const u8,
    optimize: std.builtin.OptimizeMode,
    backend: vera.orchestrator.Backend,
};

/// `vera --emit-zig|--check|--emit-so design.v`: the top module as a contract
/// device (`digital.emitDevice`). `--check` builds it beside a root that
/// validates it and calls every hook; `--emit-so` builds it over the VerA
/// tree `--contract` sits in.
fn emitDevice(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    bag: *diag.Bag,
    source: []const u8,
    opts: digital.Options,
    schedule: digital.emit.Schedule,
    logic: digital.emit.Logic,
    f: DeviceFlags,
    out: *Io.Writer,
    err: *Io.Writer,
    json: bool,
    use_color: bool,
) !u8 {
    if (logic != .four) {
        try bag.add(.lower, .E1103, .none, "a contract device is 4-state: {s}", .{if (logic == .auto)
            "--state=auto reruns the design from time 0 when an x or z returns, and a host owns the device's time"
        else
            "--state=2 would make its logic depend on the host program's root module"});
        try report(bag, err, json, use_color);
        return 1;
    }
    const dev = digital.emitDevice(arena, source, opts, schedule, bag) catch |e| {
        try report(bag, err, json, use_color);
        if (e != error.DigitalFailed) try err.print("error: {s}: emitting the device failed: {t}\n", .{ opts.file_name, e });
        return 1;
    };
    try report(bag, err, json, use_color);
    if (f.check) {
        const built = vera.tb.buildExe(gpa, io, dev.zig, device_check, .{
            .work_dir = ".zig-cache/vera-check",
            .contract = f.contract.?,
            .name = dev.name,
            .zig_exe = f.zig_exe,
            .mixed = true,
        }) catch |e| {
            try err.print("error: {s}: checking the device failed: {t}\n", .{ opts.file_name, e });
            return 1;
        };
        defer built.deinit(gpa);
        if (built == .failed) {
            try err.print("error: {s}: the generated device does not compile — this is an engine bug:\n", .{opts.file_name});
            try err.writeAll(built.failed);
            return 1;
        }
    }
    if (f.so) {
        const wd = f.work_dir orelse return missing(err, "--emit-so", "--work-dir DIR");
        const dyn = f.dyn orelse return missing(err, "--emit-so", "--dyn PATH");
        const tree = std.fs.path.dirname(std.fs.path.dirname(f.contract.?) orelse ".") orelse ".";
        const at = struct {
            fn path(a: std.mem.Allocator, r: []const u8, rel: []const u8) ![]const u8 {
                return std.fs.path.join(a, &.{ r, rel });
            }
        };
        // build.zig's `module_specs` rows for `sim` and what it imports.
        const modules = [_]vera.orchestrator.Module{
            .{ .name = "contract", .root = f.contract.? },
            .{ .name = "dyn", .root = dyn, .deps = &.{"contract"} },
            .{ .name = "sim", .root = try at.path(arena, tree, "src/sim/root.zig"), .deps = &.{ "contract", "diag", "frontend", "kernels" } },
            .{ .name = "diag", .root = try at.path(arena, tree, "lib/diag.zig") },
            .{ .name = "frontend", .root = try at.path(arena, tree, "lib/frontend/root.zig"), .deps = &.{"diag"} },
            .{ .name = "kernels", .root = try at.path(arena, tree, "lib/backend/kernels.zig") },
        };
        var r = vera.orchestrator.compileRelease(gpa, io, .{
            .work_dir = wd,
            .name = dev.name,
            .optimize = f.optimize,
            .backend = f.backend,
            .modules = &modules,
            .zig_exe = f.zig_exe,
        }, .{ .text = dev.zig }, 1) catch |e| {
            try err.print("error: {s}: building the device failed: {t}\n", .{ opts.file_name, e });
            return 1;
        };
        defer r.deinit(gpa);
        switch (r) {
            .ok => |a| try out.print("{s}\n", .{a.so_path}),
            .failed => |b| {
                try err.print("error: {s}: the generated device did not compile:\n", .{opts.file_name});
                try b.renderToWriter(.{}, err);
                return 1;
            },
        }
    }
    if (f.zig) {
        if (f.out_path) |p| {
            Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = dev.zig }) catch |e| {
                try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
                return 1;
            };
        } else try out.writeAll(dev.zig);
    }
    try out.flush();
    return 0;
}

/// `--check`'s root beside a `.v` device: the contract's checks, and every
/// hook called once so each body is compiled.
const device_check =
    \\const contract = @import("contract");
    \\const D = @import("device");
    \\const n_u = @typeInfo(D.U).@"enum".fields.len;
    \\const S = contract.RefFamily(f64, &(.{contract.no_lane} ** n_u), .{ .dense = true });
    \\comptime {
    \\    contract.validate(D);
    \\    contract.validateHost(struct {}, D);
    \\}
    \\pub fn main() void {
    \\    const m: D.Model = .{};
    \\    var inst: D.Instance = .{};
    \\    var st = D.initState(&m, &inst);
    \\    const x: [n_u]f64 = @splat(0);
    \\    _ = D.eval(S, &x, &m, &inst, .{});
    \\    _ = D.updateState(S, &m, &inst, x, &st, .{});
    \\    _ = D.stateCtl(&m, &inst, &st, .commit);
    \\    _ = D.pendingBreakpoint(&inst, 0);
    \\}
    \\
;

/// IEEE 1364-2005 §13.2 reads the library maps, then fills `opts` with each
/// file after the first and the library every file maps into, and the
/// §13.5.1/§13.7.1 search order. False when it reported a refusal.
fn libraries(
    arena: std.mem.Allocator,
    io: Io,
    paths: []const []const u8,
    libmaps: []const []const u8,
    search: []const []const u8,
    opts: *digital.Options,
    err: *Io.Writer,
    json: bool,
    use_color: bool,
) !bool {
    var bag = diag.Bag.init(arena);
    const map = vera.libmap.load(arena, io, &bag, libmaps) catch |e| switch (e) {
        error.MapFailed => {
            try report(&bag, err, json, use_color);
            return false;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const libs = try arena.alloc([]const u8, paths.len);
    for (paths, libs) |p, *lib| {
        const real = Io.Dir.cwd().realPathFileAlloc(io, p, arena) catch |e| {
            try err.print("error: cannot read `{s}`: {t}\n", .{ p, e });
            return false;
        };
        lib.* = switch (map.libraryOf(real)) {
            .lib => |l| l,
            .ambiguous => |two| {
                try bag.add(.parse, .E0244, .none, "`{s}` matches file path specifications of libraries `{s}` and `{s}` (IEEE 1364-2005 §13.2.1.1)", .{ p, two[0], two[1] });
                try report(&bag, err, json, use_color);
                return false;
            },
        };
    }
    for (search) |l| if (map.declares(l) == null and !std.mem.eql(u8, l, "work")) {
        try bag.add(.parse, .E0244, .none, "-L {s}: no library map declares library `{s}` (IEEE 1364-2005 §13.7.1)", .{ l, l });
        try report(&bag, err, json, use_color);
        return false;
    };
    const more = try arena.alloc(digital.Unit, paths.len - 1);
    for (paths[1..], libs[1..], more) |p, l, *u| u.* = .{
        .name = p,
        .text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024 * 1024)) catch |e| {
            try err.print("error: cannot read `{s}`: {t}\n", .{ p, e });
            return false;
        },
        .lib = l,
    };
    opts.lib = libs[0];
    opts.more = more;
    // ponytail: A.1.1's -incdir lists join the include path of every file,
    // not only their library's; per-library paths need `digital.Unit` to
    // carry its own.
    if (map.incdirs.len != 0) opts.include_dirs = try std.mem.concat(arena, []const u8, &.{ opts.include_dirs, map.incdirs });
    opts.search = if (search.len != 0) search else try map.order(arena);
    try report(&bag, err, json, use_color);
    return true;
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

fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) !u8 {
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
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
    const dev_name = try std.fmt.allocPrint(gpa, "{s}.device.zig", .{stem});
    defer gpa.free(dev_name);
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device_zig });

    const contract_arg = try std.fmt.allocPrint(gpa, "-Mcontract={s}", .{contract});
    defer gpa.free(contract_arg);
    const root_arg = try std.fmt.allocPrint(gpa, "-Mroot=.zig-cache/vera-check/{s}", .{dev_name});
    defer gpa.free(root_arg);

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root module —
    // the ordering rule `buildArgv` in lib/backend/orchestrator.zig follows.
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

fn report(bag: *diag.Bag, w: *Io.Writer, json: bool, color: bool) !void {
    if (bag.isEmpty()) return;
    if (json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (color) .on else .off });
    }
    try w.flush();
}
