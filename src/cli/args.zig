//! `vera`'s argv -> one `Cli` value: what the user typed, flag by flag, in
//! order. `--help` and `--explain` answer here; a malformed flag is refused
//! here with exit status 2. Conflicts between well-formed flags are refused
//! after the whole line is read, by `main`, whatever their order.
//!
//! The flags, their spelling and every message below are user-visible and
//! frozen. Clauses: LRM 3.4 (`--param`), Annex E.2 (`--spice`), IEEE 1364-2005
//! §13.2 and §13.7.1 (`--libmap`, `-L`).

const std = @import("std");
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;
const vera = @import("vera");
const digital = @import("sim").digital;
const diag = vera.diag;
const Io = std.Io;

/// `--optimize=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
/// (`fast`, ...); the flag keeps the names it always took.
const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
    .{ "Debug", .debug },
    .{ "ReleaseSafe", .safe },
    .{ "ReleaseFast", .fast },
    .{ "ReleaseSmall", .small },
});

/// `--help`, and what a command line naming no input prints to stderr.
pub const usage_text =
    \\usage: vera [options] FILE.va
    \\       vera --run|--emit-exe [options] FILE.v [MORE.v ...]
    \\       vera --emit-zig|--check|--emit-so [options] FILE.v [MORE.v ...]
    \\       vera --explain CODE
    \\
    \\  --lint                  frontend only (parse, lower, prove); no codegen
    \\  --emit-zig              generate the device; to stdout unless -o is given
    \\  -o PATH                 write the generated device.zig here
    \\  --expect-module=NAME    fail unless the compiled module is called NAME
    \\  --emit-verilog          a behavioural Verilog module of the .va for digital
    \\                          simulation (same name and ports; -o PATH, else stdout)
    \\  --digital-pins LIST|FILE   ports that are logic: a comma/space-separated
    \\                          list, or a file of names (also `(* vera_pin *)`)
    \\  --power-pins            --emit-verilog: supply pins only under
    \\                          `ifdef USE_POWER_PINS
    \\  --vdd=X                 --emit-verilog: logic-high potential in V (default 1.8)
    \\  --check                 type-check the generated device with zig, running
    \\                          the contract's conformance checks
    \\  --emit-so               build lib<name>.<gen>.so via the orchestrator
    \\  --emit-osdi             build an OSDI 0.4 library (ngspice `pre_osdi`) of a
    \\                          .va: --emit-so under this vera's tools/osdi_dyn.zig,
    \\                          copied to -o PATH (default <module>.osdi); print it
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
    \\  --validate-contract     run the contract's conformance checks (validate,
    \\                          validateHost, checkFamily, Debug su_ok) in the
    \\                          --emit-exe/--run testbench; off by default. A host
    \\                          gets them only by opting in: `pub const
    \\                          vera_validate_contract = true` in its root module
    \\                          (--emit-so: in the --dyn module). The ABI check is
    \\                          always on
    \\  --contract PATH         root of the `contract` module (default: this vera's
    \\                          own, written under the work directory)
    \\  --dyn PATH              root of the `dyn` module (--emit-so)
    \\  --work-dir DIR          scratch + artifact directory (--emit-so)
    \\  --zig PATH              zig executable to drive (default: zig)
    \\  --optimize=MODE         Debug|ReleaseSafe|ReleaseFast|ReleaseSmall (default: exe Debug, so ReleaseFast)
    \\  --zig-backend=auto|llvm|native   auto: native for Debug on x86_64, else llvm
    \\  --debug-info            keep DWARF in a ReleaseFast/ReleaseSmall --emit-so or
    \\                          --emit-exe artifact (default: stripped; same machine
    \\                          code, about half the LLVM time of a large device)
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
    \\  --discipline-resolution=basic|detail
    \\                          LRM 7.4.4's mode for undeclared interconnect
    \\                          (default: basic; detail is Annex F.2.2)
    \\
;

/// One command line, as typed. Every slice borrows from the argv iterator,
/// which must outlive this value; the lists and `levels` are owned and freed
/// by `deinit`. A later flag of the same kind overwrites an earlier one
/// except where a field says otherwise.
pub const Cli = struct {
    levels: diag.Levels = .empty,
    /// `-I`, in order.
    include_dirs: std.ArrayList([]const u8) = .empty,
    /// `--param`, in order. `main` appends the testbench's shape cards after
    /// these, so only `[0..n_typed]` of it is what was typed.
    overrides: std.ArrayList(vera.ParamOverride) = .empty,
    /// The input files; `paths[0]` is the one compiled, the rest are `.v`
    /// library units.
    paths: std.ArrayList([]const u8) = .empty,
    libmaps: std.ArrayList([]const u8) = .empty,
    /// `-L`, in order.
    search: std.ArrayList([]const u8) = .empty,
    emit_zig: bool = false,
    json: bool = false,
    color: enum { auto, always, never } = .auto,
    unknown_bound: ?f64 = null,
    discipline_resolution: vera.DisciplineResolution = .basic,
    std_defs: bool = true,
    language: vera.KeywordSet = if (ams) .vams_2023 else .v1364_2005,
    out_path: ?[]const u8 = null,
    expect_module: ?[]const u8 = null,
    /// `--emit-verilog`; `-o` then names the Verilog file.
    emit_verilog: bool = false,
    /// `--digital-pins`, unparsed: a list or a file (`main` reads it).
    digital_pins: ?[]const u8 = null,
    power_pins: bool = false,
    vdd: f64 = 1.8,
    check: bool = false,
    validate_contract: bool = false,
    emit_so: bool = false,
    /// `--emit-osdi`; `emit_so` is set too, and `-o` names the `.osdi`.
    emit_osdi: bool = false,
    /// `--emit-zig` typed, as opposed to implied by `-o`.
    emit_zig_typed: bool = false,
    /// `--run`; `exe_flag` is set too.
    run_exe: bool = false,
    display: vera.codegen.Display = .drop,
    jac_f32: bool = false,
    jac_f32_host: bool = false,
    // What the user typed, kept apart from the derived state above so
    // conflicting flags are refused by name after the loop, whatever their
    // order.
    lint_flag: bool = false,
    display_drop_flag: bool = false,
    /// The last flag that implies codegen.
    codegen_flag: ?[]const u8 = null,
    /// `--emit-exe` or `--run`, whichever was typed last.
    exe_flag: ?[]const u8 = null,
    /// `--contract`; `main` fills in this vera's own when it needs one.
    contract_path: ?[]const u8 = null,
    dyn_path: ?[]const u8 = null,
    work_dir: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    debug_info: bool = false,
    /// Null: Debug for a testbench, ReleaseFast otherwise (`main`).
    optimize: ?std.lang.Optimize = null,
    /// Null: `Backend.auto`.
    zig_backend: ?vera.orchestrator.Backend = null,
    spice_path: ?[]const u8 = null,
    schedule: digital.emit.Schedule = .static,
    event_budget: u64 = digital.max_events_per_tick,
    logic: digital.emit.Logic = .auto,
    /// `--state=` or `--two-state`, whichever was typed last.
    logic_flag: ?[]const u8 = null,

    /// Frees the lists and the lint levels; `gpa` is the one `parse` was given.
    pub fn deinit(cli: *Cli, gpa: std.mem.Allocator) void {
        cli.levels.deinit(gpa);
        cli.include_dirs.deinit(gpa);
        cli.overrides.deinit(gpa);
        cli.paths.deinit(gpa);
        cli.libmaps.deinit(gpa);
        cli.search.deinit(gpa);
    }
};

/// Reads every argument after argv[0] into `cli`, in order. Returns null to
/// go on, or the process exit code when the line is answered here: 0 after
/// `--help` (usage on `out`) or `--explain CODE` (the explanation on `out`),
/// 2 after a malformed flag (the reason on `err`). Stops at the first such
/// flag, so the rest of the line is never read.
pub fn parse(cli: *Cli, gpa: std.mem.Allocator, args: *std.process.Args.Iterator, out: *Io.Writer, err: *Io.Writer) !?u8 {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage_text);
            return 0;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            const name = args.next() orelse return try missing(err, "--explain", "a code, e.g. --explain W0650");
            const code = std.meta.stringToEnum(diag.Code, name) orelse {
                try err.print("error: unknown diagnostic code `{s}`\n", .{name});
                return 2;
            };
            try diag.explain(code, out, if (cli.color == .never) .off else .on);
            return 0;
        } else if (std.mem.eql(u8, arg, "--lint")) {
            cli.lint_flag = true;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            cli.emit_zig = true;
            cli.emit_zig_typed = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-verilog")) {
            cli.emit_verilog = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--digital-pins")) {
            cli.digital_pins = args.next() orelse return try missing(err, "--digital-pins", "a list of ports or a file");
        } else if (std.mem.eql(u8, arg, "--power-pins")) {
            cli.power_pins = true;
        } else if (std.mem.startsWith(u8, arg, "--vdd=")) {
            cli.vdd = std.fmt.parseFloat(f64, arg["--vdd=".len..]) catch 0;
            if (!(cli.vdd > 0) or !std.math.isFinite(cli.vdd)) {
                try err.print("error: `{s}`: not a positive number\n", .{arg});
                return 2;
            }
        } else if (std.mem.eql(u8, arg, "--check")) {
            cli.check = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-so")) {
            cli.emit_so = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-osdi")) {
            cli.emit_so = true;
            cli.emit_osdi = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-exe") or std.mem.eql(u8, arg, "--run")) {
            // The testbench IS the display output, so asking for one and then
            // dropping the prints would build an artifact with nothing to say.
            cli.run_exe = cli.run_exe or std.mem.eql(u8, arg, "--run");
            cli.display = .emit;
            cli.codegen_flag = arg;
            cli.exe_flag = arg;
        } else if (std.mem.eql(u8, arg, "--display=emit")) {
            cli.display = .emit;
            cli.display_drop_flag = false;
        } else if (std.mem.eql(u8, arg, "--display=drop")) {
            cli.display = .drop;
            cli.display_drop_flag = true;
        } else if (std.mem.eql(u8, arg, "--validate-contract")) {
            cli.validate_contract = true;
        } else if (std.mem.eql(u8, arg, "--jac-f32")) {
            cli.jac_f32 = true;
        } else if (std.mem.eql(u8, arg, "--jac-f32-host")) {
            cli.jac_f32_host = true;
        } else if (std.mem.eql(u8, arg, "--contract")) {
            cli.contract_path = args.next() orelse return try missing(err, "--contract", "a path");
        } else if (std.mem.eql(u8, arg, "--param")) {
            const kv = args.next() orelse return try missing(err, "--param", "NAME=VALUE");
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return try missing(err, "--param", "NAME=VALUE");
            const value = std.fmt.parseFloat(f64, kv[eq + 1 ..]) catch {
                try err.print("error: --param {s}: `{s}` is not a number\n", .{ kv, kv[eq + 1 ..] });
                return 2;
            };
            try cli.overrides.append(gpa, .{ .name = kv[0..eq], .value = value });
        } else if (std.mem.eql(u8, arg, "--dyn")) {
            cli.dyn_path = args.next() orelse return try missing(err, "--dyn", "a path");
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cli.work_dir = args.next() orelse return try missing(err, "--work-dir", "a directory");
        } else if (std.mem.eql(u8, arg, "--debug-info")) {
            cli.debug_info = true;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            cli.zig_exe = args.next() orelse return try missing(err, "--zig", "a path");
        } else if (std.mem.startsWith(u8, arg, "--optimize=")) {
            cli.optimize = optimize_names.get(arg["--optimize=".len..]) orelse {
                try err.print("error: `{s}`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--two-state")) {
            cli.logic = .two;
            cli.logic_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--state=")) {
            const v = arg["--state=".len..];
            cli.logic = if (std.mem.eql(u8, v, "auto")) .auto else if (std.mem.eql(u8, v, "2")) .two else if (std.mem.eql(u8, v, "4")) .four else {
                try err.print("error: `{s}`: not auto|2|4\n", .{arg});
                return 2;
            };
            cli.logic_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--schedule=")) {
            cli.schedule = std.meta.stringToEnum(digital.emit.Schedule, arg["--schedule=".len..]) orelse {
                try err.print("error: `{s}`: not static|fifo\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--event-budget=")) {
            cli.event_budget = std.fmt.parseInt(u64, arg["--event-budget=".len..], 10) catch 0;
            if (cli.event_budget == 0) {
                try err.print("error: `{s}`: not a positive integer\n", .{arg});
                return 2;
            }
        } else if (std.mem.startsWith(u8, arg, "--zig-backend=")) {
            const v = arg["--zig-backend=".len..];
            cli.zig_backend = if (std.mem.eql(u8, v, "auto")) null else if (std.mem.eql(u8, v, "llvm")) .llvm else if (std.mem.eql(u8, v, "native")) .self_hosted else {
                try err.print("error: `{s}`: not auto|llvm|native\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-o")) {
            cli.out_path = args.next() orelse return try missing(err, "-o", "a path");
            cli.emit_zig = true;
            cli.codegen_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--expect-module=")) {
            cli.expect_module = arg["--expect-module=".len..];
        } else if (std.mem.eql(u8, arg, "--spice")) {
            cli.spice_path = args.next() orelse return try missing(err, "--spice", "a path");
        } else if (std.mem.eql(u8, arg, "--libmap")) {
            try cli.libmaps.append(gpa, args.next() orelse return try missing(err, "--libmap", "a library map file"));
        } else if (std.mem.eql(u8, arg, "-L")) {
            try cli.search.append(gpa, args.next() orelse return try missing(err, "-L", "a library name"));
        } else if (std.mem.eql(u8, arg, "-I")) {
            try cli.include_dirs.append(gpa, args.next() orelse return try missing(err, "-I", "a directory"));
        } else if (std.mem.startsWith(u8, arg, "--std=")) {
            cli.language = vera.KeywordSet.fromSpecifier(arg["--std=".len..]) orelse {
                try err.print("error: `{s}`: not a `begin_keywords version specifier\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--no-std-defs")) {
            cli.std_defs = false;
        } else if (std.mem.eql(u8, arg, "--diagnostics=json")) {
            cli.json = true;
        } else if (std.mem.eql(u8, arg, "--diagnostics=text")) {
            cli.json = false;
        } else if (std.mem.eql(u8, arg, "--color=always")) {
            cli.color = .always;
        } else if (std.mem.eql(u8, arg, "--color=never")) {
            cli.color = .never;
        } else if (std.mem.eql(u8, arg, "--color=auto")) {
            cli.color = .auto;
        } else if (std.mem.startsWith(u8, arg, "--discipline-resolution=")) {
            cli.discipline_resolution = std.meta.stringToEnum(vera.DisciplineResolution, arg["--discipline-resolution=".len..]) orelse {
                try err.print("error: `{s}`: not basic|detail\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--unknown-bound=")) {
            cli.unknown_bound = std.fmt.parseFloat(f64, arg["--unknown-bound=".len..]) catch {
                try err.print("error: `{s}` is not a number\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // --allow=X / --warn=X / --deny=X / --forbid=X
            const applied = cli.levels.parseFlag(gpa, arg[2..]) catch |e| switch (e) {
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
        } else try cli.paths.append(gpa, arg);
    }
    return null;
}

/// Prints `error: <flag> needs <what>` on `w`; returns exit status 2.
pub fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) !u8 {
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
}
